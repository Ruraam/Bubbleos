#!/usr/bin/env bash
# shellcheck shell=bash
# bubbleOS signed system repositories, dependency resolution and upgrades
#
# ULPM remains responsible for repository transport, Ed25519 index checks and
# LPK verification. This module adds the system policy on top: the persistent
# system ULPM environment, system-package filtering, a dependency resolver that
# starts from a generation package lock, and the update/upgrade workflows.

BUBBLEOS_ULPM_CONFIG_DIR="${BUBBLEOS_ULPM_CONFIG_DIR:-${BUBBLEOS_STATE_DIR}/ulpm}"
BUBBLEOS_ULPM_CACHE_DIR="${BUBBLEOS_ULPM_CACHE_DIR:-${BUBBLEOS_CACHE_DIR}/ulpm}"

# Run ULPM with the persistent system configuration. Repository keys, pinned
# publisher keys, trusted LPK keys and cached indexes live below /var, so they
# survive generation composition and rollback.
bubble_ulpm_system() {
    local ulpm="${BUBBLEOS_ULPM_DIR}/bin/ulpm"
    [[ -x "$ulpm" ]] || {
        printf 'bubble: ULPM is not available at %s\n' "$ulpm" >&2
        return 1
    }
    ULPM_CONFIG_HOME="$BUBBLEOS_ULPM_CONFIG_DIR" \
        ULPM_CACHE_HOME="$BUBBLEOS_ULPM_CACHE_DIR" \
        ULPM_STATE_HOME="$BUBBLEOS_ULPM_CONFIG_DIR/state" \
        ULPM_DATA_HOME="$BUBBLEOS_ULPM_CONFIG_DIR/data" \
        ULPM_GENERATIONS_DIR="${ULPM_GENERATIONS_DIR:-$BUBBLEOS_GENERATIONS_DIR}" \
        "$ulpm" "$@"
}

bubble_repo_require() {
    bubble_require_root || return 1
    command -v jq >/dev/null 2>&1 || {
        printf 'bubble: jq is required for signed repositories\n' >&2
        return 1
    }
    command -v sha256sum >/dev/null 2>&1 || {
        printf 'bubble: sha256sum is required for signed repositories\n' >&2
        return 1
    }
    [[ -x "${BUBBLEOS_ULPM_DIR}/bin/ulpm" ]] || {
        printf 'bubble: ULPM is not available at %s\n' \
            "${BUBBLEOS_ULPM_DIR}/bin/ulpm" >&2
        return 1
    }
    mkdir -p -- "$BUBBLEOS_ULPM_CONFIG_DIR" "$BUBBLEOS_ULPM_CACHE_DIR" || {
        printf 'bubble: cannot create the system ULPM directories\n' >&2
        return 1
    }
}

# ------------------------------------------------------------------------------
# Repository command surface
# ------------------------------------------------------------------------------

bubble_repo_update() {
    bubble_repo_require || return 1
    bubble_ulpm_system repo update
}

bubble_repo_packages_json() {
    bubble_repo_require || return 1
    bubble_ulpm_system repo packages --json "$@"
}

bubble_repo_search() {
    local all=0 no_update=0 query=""
    while (( $# )); do
        case "$1" in
            --all)
                all=1
                shift
                ;;
            --no-update)
                no_update=1
                shift
                ;;
            -*)
                printf 'bubble: unknown repo search option: %s\n' "$1" >&2
                return 2
                ;;
            *)
                if [[ -n "$query" ]]; then
                    query+=" $1"
                else
                    query="$1"
                fi
                shift
                ;;
        esac
    done
    [[ -n "$query" ]] || {
        printf 'bubble: repo search requires a query\n' >&2
        return 2
    }

    if (( no_update == 0 )); then
        bubble_repo_update || {
            printf 'bubble: repository refresh failed; searching verified cached indexes\n' >&2
        }
    fi

    local catalog matches count
    if (( all )); then
        catalog="$(bubble_repo_catalog_all_json)" || return 1
    else
        catalog="$(bubble_repo_catalog_json)" || return 1
    fi
    matches="$(jq -c --arg q "$query" '
        map(select(
            ((.id + " " + .name + " " + (.description // ""))
              | ascii_downcase | contains($q | ascii_downcase))
        ))
    ' <<< "$catalog")" || return 1
    count="$(jq 'length' <<< "$matches")"
    if (( count == 0 )); then
        printf 'No matching system packages found.\n'
        return 0
    fi
    printf '%-34s %-14s %-8s %-14s %s\n' \
        "PACKAGE" "VERSION" "TYPE" "REPOSITORY" "DESCRIPTION"
    jq -r '
        .[] | [.id, .version, (.type // "app"), .repository,
               (.description // "")] | @tsv
    ' <<< "$matches" |
        while IFS=$'\t' read -r p_id p_version p_type p_repo p_desc; do
            printf '%-34s %-14s %-8s %-14s %s\n' \
                "$p_id" "$p_version" "$p_type" "$p_repo" "$p_desc"
        done
}

bubble_repo_packages_command() {
    local json=0 repo=""
    while (( $# )); do
        case "$1" in
            --json)
                json=1
                shift
                ;;
            --repo)
                [[ $# -ge 2 ]] || {
                    printf 'bubble: repo packages --repo requires a name\n' >&2
                    return 2
                }
                repo="$2"
                shift 2
                ;;
            --repo=*)
                repo="${1#*=}"
                shift
                ;;
            -*)
                printf 'bubble: unknown repo packages option: %s\n' "$1" >&2
                return 2
                ;;
            *)
                printf 'bubble: unexpected repo packages argument: %s\n' "$1" >&2
                return 2
                ;;
        esac
    done

    local data
    if [[ -n "$repo" ]]; then
        data="$(bubble_ulpm_system repo packages --json --repo "$repo")" || return 1
    else
        data="$(bubble_ulpm_system repo packages --json)" || return 1
    fi
    if (( json )); then
        printf '%s\n' "$data"
        return 0
    fi
    if [[ "$(jq 'length' <<< "$data")" -eq 0 ]]; then
        printf 'No packages in verified repositories.\n'
        return 0
    fi
    printf '%-16s %-34s %-12s %-8s %-8s\n' \
        "REPOSITORY" "PACKAGE" "VERSION" "ARCH" "TYPE"
    jq -r '
        .[] | [.repository, .id, .version, .arch, (.type // "app")] | @tsv
    ' <<< "$data" |
        while IFS=$'\t' read -r p_repo p_id p_version p_arch p_type; do
            printf '%-16s %-34s %-12s %-8s %-8s\n' \
                "$p_repo" "$p_id" "$p_version" "$p_arch" "$p_type"
        done
}

bubble_repo_command() {
    local action="${1:-list}"
    (( $# > 0 )) && shift
    case "$action" in
        list)
            bubble_repo_require || return 1
            bubble_ulpm_system repo list
            ;;
        add|remove|rm|enable|disable|verify|index|create-index|update|refresh)
            bubble_repo_require || return 1
            bubble_ulpm_system repo "$action" "$@"
            ;;
        packages|list-packages)
            bubble_repo_require || return 1
            bubble_repo_packages_command "$@"
            ;;
        search)
            bubble_repo_require || return 1
            bubble_repo_search "$@"
            ;;
        help|-h|--help)
            bubble_repo_usage
            ;;
        *)
            printf 'bubble: unknown repo command: %s\n' "$action" >&2
            bubble_repo_usage >&2
            return 2
            ;;
    esac
}

bubble_repo_usage() {
    cat <<'REPO_USAGE'
Usage: bubble repo <command> [options]

Commands:
  list                            List configured repositories
  add <name> <url> <key.pub>      Add and verify a signed repository
  remove <name>                   Remove a repository and its cached index
  enable|disable <name>           Enable or disable an existing repository
  update [name]                   Refresh and verify cached indexes
  verify [name]                   Verify cached indexes against pinned keys
  packages [--repo <name>] [--json]
                                  List packages from verified indexes
  search [--all] <query>          Search system packages in verified indexes
  index <dir> <private-key>       Build and sign a deterministic index

Only Ed25519-signed indexes whose key matches the pinned fingerprint are
accepted. Repository state is persistent under /var/lib/bubbleos/ulpm.
REPO_USAGE
}

bubble_trust() {
    bubble_repo_require || return 1
    bubble_ulpm_system trust "$@"
}

# ------------------------------------------------------------------------------
# Version and architecture helpers
# ------------------------------------------------------------------------------

bubble_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'amd64\n' ;;
        aarch64|arm64) printf 'arm64\n' ;;
        armv7l|armv7|armhf) printf 'armhf\n' ;;
        i386|i686) printf 'i386\n' ;;
        *) uname -m ;;
    esac
}

# Returns 0 when equal, 1 when the first version is greater and 2 when it is
# lower. This mirrors ULPM's pure-Bash semantic version comparison.
bubble_version_compare() {
    local v1="${1:-0}" v2="${2:-0}"
    [[ "$v1" == "$v2" ]] && return 0
    v1="${v1#*:}"
    v2="${v2#*:}"

    if command -v dpkg >/dev/null 2>&1; then
        if dpkg --compare-versions "$v1" eq "$v2"; then return 0; fi
        if dpkg --compare-versions "$v1" gt "$v2"; then return 1; fi
        return 2
    fi

    local -a parts1=() parts2=()
    IFS='.-+' read -r -a parts1 <<< "$v1"
    IFS='.-+' read -r -a parts2 <<< "$v2"

    local max="${#parts1[@]}"
    (( ${#parts2[@]} > max )) && max="${#parts2[@]}"
    local i p1 p2 n1 n2
    for (( i = 0; i < max; i++ )); do
        p1="${parts1[i]:-0}"
        p2="${parts2[i]:-0}"
        [[ "$p1" == "$p2" ]] && continue
        if [[ "$p1" =~ ^[0-9]+$ && "$p2" =~ ^[0-9]+$ ]]; then
            n1="${p1//[^0-9]/}"
            n2="${p2//[^0-9]/}"
            if (( ${#n1} > ${#n2} )); then
                return 1
            elif (( ${#n1} < ${#n2} )); then
                return 2
            fi
            if [[ "$n1" > "$n2" ]]; then
                return 1
            elif [[ "$n1" < "$n2" ]]; then
                return 2
            fi
            continue
        fi
        if [[ "$p1" > "$p2" ]]; then
            return 1
        fi
        return 2
    done
    return 0
}

bubble_version_matches() {
    local version="$1" constraint="${2:-}"
    [[ -z "$constraint" || "$constraint" == "all" || "$constraint" == "*" ]] &&
        return 0

    local op wanted cmp=0
    if [[ "$constraint" =~ ^([>=<]+)(.*)$ ]]; then
        op="${BASH_REMATCH[1]}"
        wanted="${BASH_REMATCH[2]}"
    else
        op="="
        wanted="$constraint"
    fi
    bubble_version_compare "$version" "$wanted" || cmp=$?
    case "$op" in
        "="|"==") (( cmp == 0 )) ;;
        ">=")     (( cmp == 0 || cmp == 1 )) ;;
        "<=")     (( cmp == 0 || cmp == 2 )) ;;
        ">")      (( cmp == 1 )) ;;
        "<")      (( cmp == 2 )) ;;
        *)        return 1 ;;
    esac
}

bubble_repo_catalog_json() {
    local data host_arch
    data="$(bubble_ulpm_system repo packages --json)" || return 1
    jq -e 'type == "array"' <<< "$data" >/dev/null 2>&1 || {
        printf 'bubble: invalid package catalogue from ULPM\n' >&2
        return 1
    }
    host_arch="$(bubble_arch)"
    jq -c --arg arch "$host_arch" '
        map(select(
            ((.type // "app") | test("^(rootfs|os|distro|system)$")) and
            (.arch == $arch or .arch == "all" or .arch == "any" or
             ($arch == "amd64" and (.arch == "x86_64" or .arch == "x86-64")) or
             ($arch == "arm64" and (.arch == "aarch64" or .arch == "arm-64")) or
             ($arch == "armhf" and (.arch == "armv7l" or .arch == "armv7")))
        )) | sort_by(.id, .version, .repository)
    ' <<< "$data"
}

# Every verified package for the host architecture, including application
# packages. Used by `bubble repo search --all` for repository discovery.
bubble_repo_catalog_all_json() {
    local data host_arch
    data="$(bubble_ulpm_system repo packages --json)" || return 1
    jq -e 'type == "array"' <<< "$data" >/dev/null 2>&1 || {
        printf 'bubble: invalid package catalogue from ULPM\n' >&2
        return 1
    }
    host_arch="$(bubble_arch)"
    jq -c --arg arch "$host_arch" '
        map(select(
            (.arch == $arch or .arch == "all" or .arch == "any" or
             ($arch == "amd64" and (.arch == "x86_64" or .arch == "x86-64")) or
             ($arch == "arm64" and (.arch == "aarch64" or .arch == "arm-64")) or
             ($arch == "armhf" and (.arch == "armv7l" or .arch == "armv7")))
        )) | sort_by(.id, .version, .repository)
    ' <<< "$data"
}

# ------------------------------------------------------------------------------
# System dependency resolver
#
# The resolver starts from a generation lock (or an intermediate lock built by
# `bubble install`), keeps every installed package unless a newer version is
# requested, resolves repository dependencies and rejects unclosed sets. It
# iterates constraints to a fixed point so version constraints introduced by a
# dependency upgrade are applied to the whole set before anything is composed.
# ------------------------------------------------------------------------------

_bubble_resolve_installed='{}'
_bubble_resolve_catalog='[]'
_bubble_resolve_plan='[]'
declare -gA _bubble_resolve_root_constraint=()
declare -gA _bubble_resolve_root_mode=()
declare -gA _bubble_resolve_constraints=()
declare -gA _bubble_resolve_extra=()
declare -gA _bubble_resolve_decisions=()
declare -gA _bubble_resolve_expanded=()

_bubble_resolve_add_constraint() {
    local id="$1" constraint="$2"
    [[ -n "$id" && -n "$constraint" ]] || return 0
    local current="${_bubble_resolve_constraints[$id]:-}"
    if [[ -z "$current" ]]; then
        _bubble_resolve_constraints["$id"]="$constraint"
    elif ! grep -Fxq -- "$constraint" <<< "$current"; then
        _bubble_resolve_constraints["$id"]="${current}"$'\n'"${constraint}"
    fi
}

_bubble_resolve_add_extra() {
    local id="$1" constraint="$2"
    [[ -n "$id" && -n "$constraint" ]] || return 0
    local current="${_bubble_resolve_extra[$id]:-}"
    if [[ -z "$current" ]]; then
        _bubble_resolve_extra["$id"]="$constraint"
    elif ! grep -Fxq -- "$constraint" <<< "$current"; then
        _bubble_resolve_extra["$id"]="${current}"$'\n'"${constraint}"
    fi
}

_bubble_resolve_add_root_constraint() {
    local id="$1" constraint="$2"
    [[ -n "$id" && -n "$constraint" ]] || return 0
    local current="${_bubble_resolve_root_constraint[$id]:-}"
    if [[ -z "$current" ]]; then
        _bubble_resolve_root_constraint["$id"]="$constraint"
    elif ! grep -Fxq -- "$constraint" <<< "$current"; then
        _bubble_resolve_root_constraint["$id"]="${current}"$'\n'"${constraint}"
    fi
}

_bubble_resolve_constraints_ok() {
    local version="$1" constraints="$2" constraint
    [[ -n "$constraints" ]] || return 0
    while IFS= read -r constraint; do
        [[ -n "$constraint" ]] || continue
        bubble_version_matches "$version" "$constraint" || return 1
    done <<< "$constraints"
    return 0
}

_bubble_resolve_normalize_dep() {
    local item="$1" id="" spec=""
    if [[ "$item" == '"'* ]]; then
        item="$(jq -r '.' <<< "$item")" || return 1
        if [[ "$item" =~ ^([A-Za-z0-9_][A-Za-z0-9._-]*)(>=|<=|==|=|>|<)([A-Za-z0-9.+_~:-]+)$ ]]; then
            id="${BASH_REMATCH[1]}"
            spec="${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
        elif [[ "$item" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]; then
            id="$item"
        else
            return 1
        fi
    else
        id="$(jq -r '.id // empty' <<< "$item")" || return 1
        spec="$(jq -r '.version // empty' <<< "$item")" || return 1
        if [[ "$spec" =~ ^(>=|<=|==|=|>|<)(.+)$ ]]; then
            spec="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
        elif [[ -n "$spec" ]]; then
            spec="=$spec"
        fi
    fi
    [[ "$id" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ && "$id" != *..* ]] ||
        return 1
    printf '%s\t%s\n' "$id" "$spec"
}

# Prints the installed package map from a lock. The map records the store
# digest and the manifest dependencies so the resolver can validate a closed
# set without downloading anything.
bubble_resolve_load_installed() {
    local source="${1:-}" lock_json="${2:-}" lock pkg id version digest
    local pkg_type name deps manifest record
    if [[ -n "$lock_json" ]]; then
        lock="$lock_json"
    else
        lock="$(bubble_generation_lock_json "$source")" || return 1
    fi
    _bubble_resolve_installed='{}'

    while IFS= read -r pkg; do
        [[ -n "$pkg" ]] || continue
        IFS=$'\t' read -r id version digest pkg_type name <<< "$(
            jq -r '[.id, .version, (.digest // ""),
                    (.type // "system"), (.name // .id)] | @tsv' <<< "$pkg"
        )"
        [[ -n "$id" && -n "$version" ]] || {
            printf 'bubble: invalid package entry in generation %s\n' \
                "$source" >&2
            return 1
        }
        if [[ -n "$digest" ]]; then
            manifest="$(bubble_store_object_manifest "$digest" 2>/dev/null)" || {
                printf 'bubble: missing store object %s for package %s\n' \
                    "$digest" "$id" >&2
                return 1
            }
            deps="$(jq -c '.dependencies // []' "$manifest")" || return 1
        else
            deps='[]'
        fi
        record="$(jq -cn \
            --arg id "$id" --arg version "$version" --arg digest "$digest" \
            --arg type "$pkg_type" --arg name "$name" \
            --argjson deps "$deps" '
            {id: $id, version: $version, digest: $digest, type: $type,
             name: $name, source: "store", dependencies: $deps}
        ')" || return 1
        _bubble_resolve_installed="$(
            jq -c --arg id "$id" --argjson record "$record" \
                '.[$id] = $record' <<< "$_bubble_resolve_installed"
        )" || return 1
    done < <(jq -c '.packages[]?' <<< "$lock")
    return 0
}

# Picks the highest repository candidate for <id> that satisfies every
# constraint. With require_newer=1 only versions strictly newer than
# installed_version are considered (used by `bubble upgrade`).
_bubble_resolve_pick_candidate() {
    local id="$1" constraints="$2" require_newer="${3:-0}"
    local installed_version="${4:-}" candidates count i record version
    local repository best_record="" best_version="" cmp=0
    candidates="$(jq -c --arg id "$id" \
        '[.[] | select(.id == $id)]' <<< "$_bubble_resolve_catalog")" ||
        return 1
    count="$(jq 'length' <<< "$candidates")"

    for (( i = 0; i < count; i++ )); do
        record="$(jq -c ".[$i]" <<< "$candidates")" || return 1
        version="$(jq -r '.version' <<< "$record")" || return 1
        _bubble_resolve_constraints_ok "$version" "$constraints" || continue

        if (( require_newer )) && [[ -n "$installed_version" ]]; then
            cmp=0
            bubble_version_compare "$version" "$installed_version" || cmp=$?
            (( cmp == 1 )) || continue
        fi

        if [[ -z "$best_record" ]]; then
            best_record="$record"
            best_version="$version"
            continue
        fi
        cmp=0
        bubble_version_compare "$version" "$best_version" || cmp=$?
        if (( cmp == 1 )); then
            best_record="$record"
            best_version="$version"
        elif (( cmp == 0 )); then
            repository="$(jq -r '.repository' <<< "$record")"
            local best_repository
            best_repository="$(jq -r '.repository' <<< "$best_record")"
            if [[ "$repository" < "$best_repository" ]]; then
                best_record="$record"
            fi
        fi
    done

    [[ -n "$best_record" ]] || return 1
    jq -c '
        {id, name, version, type: (.type // "system"),
         digest: .sha256, source: "repo", repository, base_url,
         file, sha256, dependencies: (.dependencies // [])}
    ' <<< "$best_record"
}

_bubble_resolve_build_plan() {
    local id out='[]'
    for id in "${!_bubble_resolve_decisions[@]}"; do
        out="$(jq -c --argjson record "${_bubble_resolve_decisions[$id]}" \
            '. + [$record]' <<< "$out")" || return 1
    done
    jq -cS 'sort_by(.id)' <<< "$out"
}

# bubble_resolve_plan <source-gen> <install|upgrade> [--lock <json>] [target...]
#
# Prints the resolved package set as JSON. In install mode target package IDs
# are added; in upgrade mode every installed package (or the selected targets)
# is moved to the newest repository version that satisfies the constraints.
bubble_resolve_plan() {
    local source="${1:-}" mode="${2:-}"
    shift 2 || true
    [[ -n "$source" && ( "$mode" == "install" || "$mode" == "upgrade" ) ]] || {
        printf 'bubble: resolver requires a source generation and a mode\n' >&2
        return 2
    }

    local base_lock=""
    if [[ "${1:-}" == "--lock" ]]; then
        [[ $# -ge 2 ]] || {
            printf 'bubble: resolver --lock requires a package lock\n' >&2
            return 2
        }
        base_lock="$2"
        shift 2
    fi
    local -a targets=("$@")
    (( ${#targets[@]} > 0 )) || [[ "$mode" == "upgrade" ]] || {
        printf 'bubble: resolver requires at least one package\n' >&2
        return 2
    }

    bubble_resolve_load_installed "$source" "$base_lock" || return 1
    _bubble_resolve_catalog="$(bubble_repo_catalog_json)" || return 1

    _bubble_resolve_root_constraint=()
    _bubble_resolve_root_mode=()
    _bubble_resolve_extra=()
    local -a roots=()

    if [[ "$mode" == "upgrade" && ${#targets[@]} -eq 0 ]]; then
        mapfile -t targets < <(jq -r 'keys[]' <<< "$_bubble_resolve_installed")
        if (( ${#targets[@]} == 0 )); then
            _bubble_resolve_plan='[]'
            printf '%s\n' "$_bubble_resolve_plan"
            return 0
        fi
    fi

    local target id op wanted constraint root_mode
    for target in "${targets[@]}"; do
        id=""
        op=""
        wanted=""
        if [[ "$target" =~ ^([A-Za-z0-9_][A-Za-z0-9._-]*)(>=|<=|==|=|>|<)([A-Za-z0-9.+_~:-]+)$ ]]; then
            id="${BASH_REMATCH[1]}"
            op="${BASH_REMATCH[2]}"
            wanted="${BASH_REMATCH[3]}"
            [[ "$op" == "==" ]] && op="="
        elif [[ "$target" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]; then
            id="$target"
        else
            printf 'bubble: invalid package selector: %s\n' "$target" >&2
            return 2
        fi
        constraint="${op:+${op}${wanted}}"

        if [[ "$mode" == "upgrade" ]]; then
            if ! jq -e --arg id "$id" 'has($id)' \
                <<< "$_bubble_resolve_installed" >/dev/null 2>&1; then
                printf 'bubble: package %s is not installed\n' "$id" >&2
                return 1
            fi
            if [[ -n "$op" ]]; then
                root_mode="pinned"
            else
                root_mode="upgrade"
            fi
        else
            if [[ -n "$op" ]]; then
                root_mode="pinned"
            else
                root_mode="latest"
            fi
        fi

        roots+=("$id")
        _bubble_resolve_root_mode["$id"]="$root_mode"
        _bubble_resolve_add_root_constraint "$id" "$constraint"
    done

    local pass=0 max_passes=50 previous_plan='' plan invalid iterations
    while (( pass < max_passes )); do
        pass=$((pass + 1))
        _bubble_resolve_constraints=()
        _bubble_resolve_decisions=()
        _bubble_resolve_expanded=()

        local root
        for root in "${roots[@]}"; do
            _bubble_resolve_add_constraint \
                "$root" "${_bubble_resolve_root_constraint[$root]:-}"
        done

        local extra_id
        for extra_id in "${!_bubble_resolve_extra[@]}"; do
            while IFS= read -r constraint; do
                [[ -n "$constraint" ]] || continue
                _bubble_resolve_add_constraint "$extra_id" "$constraint"
            done <<< "${_bubble_resolve_extra[$extra_id]}"
        done

        local installed_id
        while IFS= read -r installed_id; do
            _bubble_resolve_decisions["$installed_id"]="$(
                jq -c --arg id "$installed_id" '.[$id]' \
                    <<< "$_bubble_resolve_installed"
            )"
        done < <(jq -r 'keys[]' <<< "$_bubble_resolve_installed")

        local -a queue=("${roots[@]}")
        for extra_id in "${!_bubble_resolve_extra[@]}"; do
            queue+=("$extra_id")
        done

        local qindex=0 current selected candidate current_version dep norm
        local dep_id dep_spec
        iterations=0
        while (( qindex < ${#queue[@]} )); do
            id="${queue[$qindex]}"
            qindex=$((qindex + 1))
            iterations=$((iterations + 1))
            if (( iterations > 10000 )); then
                printf 'bubble: dependency resolution did not terminate\n' >&2
                return 1
            fi

            current="${_bubble_resolve_decisions[$id]:-}"
            current_version=""
            [[ -z "$current" ]] ||
                current_version="$(jq -r '.version' <<< "$current")"
            root_mode="${_bubble_resolve_root_mode[$id]:-dependency}"
            constraint="${_bubble_resolve_constraints[$id]:-}"
            selected=""

            case "$root_mode" in
                dependency|pinned)
                    if [[ -n "$current" ]] &&
                        _bubble_resolve_constraints_ok \
                            "$current_version" "$constraint"; then
                        selected="$current"
                    fi
                    ;;
                upgrade)
                    if [[ -n "$current" ]] &&
                        _bubble_resolve_constraints_ok \
                            "$current_version" "$constraint"; then
                        if candidate="$(
                            _bubble_resolve_pick_candidate \
                                "$id" "$constraint" 1 "$current_version"
                        )"; then
                            selected="$candidate"
                        else
                            selected="$current"
                        fi
                    fi
                    ;;
                latest)
                    if candidate="$(
                        _bubble_resolve_pick_candidate \
                            "$id" "$constraint" 0 ""
                    )"; then
                        selected="$candidate"
                    elif [[ -n "$current" ]] &&
                        _bubble_resolve_constraints_ok \
                            "$current_version" "$constraint"; then
                        selected="$current"
                    fi
                    ;;
            esac

            if [[ -z "$selected" ]]; then
                if candidate="$(
                    _bubble_resolve_pick_candidate "$id" "$constraint" 0 ""
                )"; then
                    selected="$candidate"
                elif [[ -n "$current" ]] &&
                    _bubble_resolve_constraints_ok \
                        "$current_version" "$constraint"; then
                    selected="$current"
                else
                    printf 'bubble: package %s%s is not available in a verified system repository\n' \
                        "$id" "${constraint:+ (${constraint//$'\n'/, })}" >&2
                    return 1
                fi
            fi

            _bubble_resolve_decisions["$id"]="$selected"

            local expand_key
            expand_key="$id|$(jq -r '.version + "|" + (.digest // .sha256 // "")' <<< "$selected")"
            [[ -z "${_bubble_resolve_expanded[$expand_key]:-}" ]] || continue
            _bubble_resolve_expanded["$expand_key"]=1

            while IFS= read -r dep; do
                [[ -n "$dep" ]] || continue
                norm="$(_bubble_resolve_normalize_dep "$dep")" || {
                    printf 'bubble: invalid dependency %s for %s\n' \
                        "$dep" "$id" >&2
                    return 1
                }
                dep_id="${norm%%$'\t'*}"
                dep_spec="${norm#*$'\t'}"
                _bubble_resolve_add_constraint "$dep_id" "$dep_spec"
                queue+=("$dep_id")
            done < <(jq -c '.dependencies[]?' <<< "$selected")
        done

        invalid=0
        local decision_id record dependency_id dependency_record
        local dependency_version
        for decision_id in "${!_bubble_resolve_decisions[@]}"; do
            record="${_bubble_resolve_decisions[$decision_id]}"
            while IFS= read -r dep; do
                [[ -n "$dep" ]] || continue
                norm="$(_bubble_resolve_normalize_dep "$dep")" || {
                    printf 'bubble: invalid dependency %s for %s\n' \
                        "$dep" "$decision_id" >&2
                    return 1
                }
                dependency_id="${norm%%$'\t'*}"
                dep_spec="${norm#*$'\t'}"
                dependency_record="${_bubble_resolve_decisions[$dependency_id]:-}"
                if [[ -z "$dependency_record" ]]; then
                    _bubble_resolve_add_constraint "$dependency_id" "$dep_spec"
                    invalid=1
                    continue
                fi
                dependency_version="$(
                    jq -r '.version' <<< "$dependency_record"
                )"
                if ! _bubble_resolve_constraints_ok \
                    "$dependency_version" "$dep_spec"; then
                    _bubble_resolve_add_constraint "$dependency_id" "$dep_spec"
                    invalid=1
                fi
            done < <(jq -c '.dependencies[]?' <<< "$record")
        done

        plan="$(_bubble_resolve_build_plan)" || return 1
        if (( invalid == 0 )) && [[ "$plan" == "$previous_plan" ]]; then
            _bubble_resolve_plan="$plan"
            printf '%s\n' "$plan"
            return 0
        fi
        previous_plan="$plan"

        _bubble_resolve_extra=()
        for decision_id in "${!_bubble_resolve_decisions[@]}"; do
            record="${_bubble_resolve_decisions[$decision_id]}"
            while IFS= read -r dep; do
                [[ -n "$dep" ]] || continue
                norm="$(_bubble_resolve_normalize_dep "$dep")" || {
                    printf 'bubble: invalid dependency %s for %s\n' \
                        "$dep" "$decision_id" >&2
                    return 1
                }
                dependency_id="${norm%%$'\t'*}"
                dep_spec="${norm#*$'\t'}"
                _bubble_resolve_add_extra "$dependency_id" "$dep_spec"
            done < <(jq -c '.dependencies[]?' <<< "$record")
        done
    done

    printf 'bubble: dependency resolution did not converge\n' >&2
    return 1
}

# Returns the subset of a plan that differs from the installed map.
bubble_resolve_changes() {
    local plan="$1"
    jq -c --argjson plan "$plan" --argjson installed "$_bubble_resolve_installed" '
        [
          $plan[] as $package |
          ($installed[$package.id] // null) as $current |
          select($current == null or
                 $current.version != $package.version or
                 $current.digest != $package.digest) |
          $package
        ] | sort_by(.id)
    ' <<< 'null'
}

bubble_resolve_describe_changes() {
    local changes="$1"
    jq -r --argjson installed "$_bubble_resolve_installed" '
        .[] as $package |
        ($installed[$package.id] // null) as $current |
        if $current == null then
            "  \($package.id) (new) -> \($package.version) [\($package.repository // "store")]"
        else
            "  \($package.id) \($current.version) -> \($package.version) [\($package.repository // "store")]"
        end
    ' <<< "$changes"
}

# ------------------------------------------------------------------------------
# Payload download and generation composition
# ------------------------------------------------------------------------------

bubble_repo_download() {
    local base="${1:-}" file="${2:-}" dest="${3:-}" expected="${4:-}"
    local got
    [[ -n "$base" && -n "$file" && -n "$dest" ]] || return 1
    [[ "$file" =~ ^[A-Za-z0-9._+-]+\.lpk$ && "$file" != *..* ]] || {
        printf 'bubble: unsafe repository payload name: %s\n' "$file" >&2
        return 1
    }
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || {
        printf 'bubble: invalid payload digest for %s\n' "$file" >&2
        return 1
    }

    if [[ "$base" == file://* ]]; then
        base="${base#file://}"
    fi
    case "$base" in
        /*)
            cp -f -- "${base%/}/$file" "$dest" 2>/dev/null || {
                printf 'bubble: cannot read repository payload: %s\n' \
                    "${base%/}/$file" >&2
                return 1
            }
            ;;
        https://*|http://*)
            command -v curl >/dev/null 2>&1 || {
                printf 'bubble: curl is required for HTTPS repositories\n' >&2
                return 1
            }
            curl -fsSL --connect-timeout 15 --max-time 300 --retry 2 \
                "${base%/}/$file" -o "$dest" || {
                printf 'bubble: download failed: %s/%s\n' "${base%/}" "$file" >&2
                return 1
            }
            ;;
        *)
            printf 'bubble: unsupported repository URL: %s\n' "$base" >&2
            return 1
            ;;
    esac

    got="$(sha256sum -- "$dest" | awk '{print $1}')" || return 1
    if [[ "$got" != "$expected" ]]; then
        rm -f -- "$dest"
        printf 'bubble: SHA-256 mismatch for %s (expected %s, got %s)\n' \
            "$file" "$expected" "$got" >&2
        return 1
    fi
}

# bubble_repo_apply_plan <source-gen> <plan-json> <description> <activate>
#
# Downloads and verifies every repository payload, imports them into the
# system store with the system trust store, rebuilds the generation lock and
# composes exactly one new generation. No generation is created if any
# download, signature, digest or dependency check fails.
bubble_repo_apply_plan() {
    local source="${1:-}" plan="${2:-}" description="${3:-}" activate="${4:-1}"
    local tmpdir record source_kind id version digest pkg_type name base file sha
    local path info got_id got_version got_digest lock gen

    bubble_repo_require || return 1
    bubble_require_generation_layout || return 1
    bubble_store_require || return 1
    mkdir -p -- "$BUBBLEOS_ULPM_CACHE_DIR" || return 1
    tmpdir="$(mktemp -d "$BUBBLEOS_ULPM_CACHE_DIR/downloads.XXXXXX")" || {
        printf 'bubble: cannot create a download staging directory\n' >&2
        return 1
    }

    while IFS= read -r record; do
        [[ -n "$record" ]] || continue
        source_kind="$(jq -r '.source' <<< "$record")"
        [[ "$source_kind" == "repo" ]] || continue
        IFS=$'\t' read -r id version digest pkg_type name base file sha <<< "$(
            jq -r '[.id, .version, .digest, .type, .name,
                    .base_url, .file, .sha256] | @tsv' <<< "$record"
        )"
        path="$tmpdir/$sha.lpk"
        bubble_repo_download "$base" "$file" "$path" "$sha" || {
            rm -rf -- "$tmpdir"
            return 1
        }
        if [[ "$digest" != "$sha" ]]; then
            printf 'bubble: inconsistent digest for %s %s\n' \
                "$id" "$version" >&2
            rm -rf -- "$tmpdir"
            return 1
        fi
    done < <(jq -c '.[]' <<< "$plan")

    while IFS= read -r record; do
        [[ -n "$record" ]] || continue
        source_kind="$(jq -r '.source' <<< "$record")"
        [[ "$source_kind" == "repo" ]] || continue
        IFS=$'\t' read -r id version digest pkg_type name base file sha <<< "$(
            jq -r '[.id, .version, .digest, .type, .name,
                    .base_url, .file, .sha256] | @tsv' <<< "$record"
        )"
        path="$tmpdir/$sha.lpk"
        bubble_store_ulpm_system add "$path" >&2 || {
            rm -rf -- "$tmpdir"
            return 1
        }
        info="$(bubble_store_info_for_file "$path")" || {
            rm -rf -- "$tmpdir"
            return 1
        }
        IFS=$'\t' read -r got_id got_version _ _ got_digest <<< "$info"
        if [[ "$got_id" != "$id" || "$got_version" != "$version" ||
            "$got_digest" != "$digest" ]]; then
            printf 'bubble: repository package metadata mismatch for %s %s\n' \
                "$id" "$version" >&2
            rm -rf -- "$tmpdir"
            return 1
        fi
    done < <(jq -c '.[]' <<< "$plan")

    while IFS= read -r record; do
        [[ -n "$record" ]] || continue
        source_kind="$(jq -r '.source' <<< "$record")"
        [[ "$source_kind" == "store" ]] || continue
        IFS=$'\t' read -r id version digest pkg_type name <<< "$(
            jq -r '[.id, .version, .digest, .type, .name] | @tsv' <<< "$record"
        )"
        info="$(bubble_store_info_for_id "$id=$version" 2>/dev/null)" || {
            printf 'bubble: stored package disappeared: %s %s\n' \
                "$id" "$version" >&2
            rm -rf -- "$tmpdir"
            return 1
        }
        IFS=$'\t' read -r got_id got_version _ _ got_digest <<< "$info"
        if [[ "$got_id" != "$id" || "$got_version" != "$version" ||
            "$got_digest" != "$digest" ]]; then
            printf 'bubble: stored package metadata mismatch for %s %s\n' \
                "$id" "$version" >&2
            rm -rf -- "$tmpdir"
            return 1
        fi
    done < <(jq -c '.[]' <<< "$plan")

    lock="$(bubble_generation_lock_json "$source")" || {
        rm -rf -- "$tmpdir"
        return 1
    }
    lock="$(jq '.packages = []' <<< "$lock")" || {
        rm -rf -- "$tmpdir"
        return 1
    }
    while IFS= read -r record; do
        [[ -n "$record" ]] || continue
        IFS=$'\t' read -r id version digest pkg_type name <<< "$(
            jq -r '[.id, .version, .digest, (.type // "system"),
                    (.name // .id)] | @tsv' <<< "$record"
        )"
        lock="$(bubble_package_lock_add \
            "$lock" "$id" "$version" "$digest" "$pkg_type" "$name")" || {
            rm -rf -- "$tmpdir"
            return 1
        }
    done < <(jq -c '.[]' <<< "$plan")

    if ! bubble_package_lock_verify "$lock"; then
        rm -rf -- "$tmpdir"
        return 1
    fi

    gen="$(bubble_generation_compose_from \
        "$source" "$lock" "$description" "$activate")" || {
        rm -rf -- "$tmpdir"
        return 1
    }
    rm -rf -- "$tmpdir"
    printf '%s\n' "$gen"
}

# ------------------------------------------------------------------------------
# update / upgrade
# ------------------------------------------------------------------------------

bubble_update() {
    local refresh=1 json=0
    while (( $# )); do
        case "$1" in
            --no-refresh)
                refresh=0
                shift
                ;;
            --json)
                json=1
                shift
                ;;
            help|-h|--help)
                cat <<'UPDATE_HELP'
Usage: bubble update [--no-refresh] [--json]

Refreshes the signed repository indexes, verifies every pinned Ed25519 key
and lists the system packages that can be upgraded. Nothing is composed.
UPDATE_HELP
                return 0
                ;;
            *)
                printf 'bubble: unknown update option: %s\n' "$1" >&2
                return 2
                ;;
        esac
    done

    bubble_repo_require || return 1
    bubble_require_generation_layout || return 1
    bubble_store_require || return 1
    if (( refresh )); then
        bubble_repo_update || {
            printf 'bubble: refusing to list updates from unverified repositories\n' >&2
            return 1
        }
    fi

    local source plan changes count
    source="$(bubble_generation_current)" || {
        printf 'bubble: no current generation\n' >&2
        return 1
    }
    bubble_resolve_load_installed "$source" || return 1
    plan="$(bubble_resolve_plan "$source" upgrade)" || return 1
    changes="$(bubble_resolve_changes "$plan")" || return 1
    count="$(jq 'length' <<< "$changes")"

    if (( json )); then
        printf '%s\n' "$changes"
        return 0
    fi
    if (( count == 0 )); then
        printf 'System is up to date.\n'
        return 0
    fi
    printf 'Available updates (%s):\n' "$count"
    bubble_resolve_describe_changes "$changes"
    printf "Run 'bubble upgrade' to compose them into a new generation.\n"
}

bubble_upgrade() {
    local refresh=1 activate=1 dry_run=0 description="" from=""
    local -a targets=()
    while (( $# )); do
        case "$1" in
            --from)
                [[ $# -ge 2 ]] || {
                    printf 'bubble: upgrade --from requires a generation\n' >&2
                    return 2
                }
                from="$2"
                shift 2
                ;;
            --from=*)
                from="${1#*=}"
                shift
                ;;
            --no-refresh)
                refresh=0
                shift
                ;;
            --no-activate)
                activate=0
                shift
                ;;
            --activate)
                activate=1
                shift
                ;;
            --dry-run|-n)
                dry_run=1
                shift
                ;;
            --description)
                [[ $# -ge 2 ]] || {
                    printf 'bubble: upgrade --description requires a value\n' >&2
                    return 2
                }
                description="$2"
                shift 2
                ;;
            --description=*)
                description="${1#*=}"
                shift
                ;;
            --)
                shift
                targets+=("$@")
                break
                ;;
            -*)
                printf 'bubble: unknown upgrade option: %s\n' "$1" >&2
                return 2
                ;;
            *)
                targets+=("$1")
                shift
                ;;
        esac
    done

    bubble_repo_require || return 1
    bubble_require_generation_layout || return 1
    bubble_store_require || return 1

    local source plan changes count gen
    source="${from:-$(bubble_generation_current)}" || {
        printf 'bubble: no current generation\n' >&2
        return 1
    }
    if (( refresh )); then
        bubble_repo_update || {
            printf 'bubble: refusing to upgrade from unverified repositories\n' >&2
            return 1
        }
    fi

    bubble_resolve_load_installed "$source" || return 1
    plan="$(bubble_resolve_plan "$source" upgrade "${targets[@]}")" ||
        return 1
    changes="$(bubble_resolve_changes "$plan")" || return 1
    count="$(jq 'length' <<< "$changes")"

    if (( count == 0 )); then
        printf 'All system packages are up to date.\n'
        return 0
    fi

    printf 'Packages to upgrade (%s):\n' "$count"
    bubble_resolve_describe_changes "$changes"
    if (( dry_run )); then
        printf 'Dry run: no generation created.\n'
        return 0
    fi

    description="${description:-Upgrade system packages}"
    gen="$(bubble_repo_apply_plan \
        "$source" "$plan" "$description" "$activate")" || return 1
    if [[ "$(bubble_generation_current 2>/dev/null || true)" == "$gen" ]]; then
        printf 'Upgraded %s package(s) in generation %s; activated (reboot required)\n' \
            "$count" "$gen"
    else
        printf 'Upgraded %s package(s) in generation %s (not activated)\n' \
            "$count" "$gen"
    fi
}
