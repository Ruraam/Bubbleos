#!/usr/bin/env bash
# shellcheck shell=bash
# bubbleOS generation management (Btrfs subvolumes)

bubble_generation_path() {
    printf '%s/%s\n' "$BUBBLEOS_GENERATIONS_DIR" "$1"
}

bubble_generation_exists() {
    [[ "${1:-}" =~ ^[0-9]{6}$ ]] || return 1
    [[ -d "$(bubble_generation_path "$1")" ]]
}

bubble_generation_link_target() {
    local link="$1" target name
    [[ -L "$link" ]] || return 1
    target="$(readlink -- "$link" 2>/dev/null)" || return 1
    target="${target#./}"
    name="${target##*/}"
    [[ "$name" =~ ^[0-9]{6}$ ]] || return 1
    printf '%s\n' "$name"
}

bubble_generation_current() {
    if [[ -x "$BUBBLEOS_RUST_PATHS_BIN" ]]; then
        bubble_rust_paths generation-current
        return $?
    fi
    local gen
    gen="$(bubble_generation_link_target "$BUBBLEOS_CURRENT_LINK")" || return 1
    [[ -d "$(bubble_generation_path "$gen")" ]] || return 1
    printf '%s\n' "$gen"
}

bubble_generation_previous() {
    if [[ -x "$BUBBLEOS_RUST_PATHS_BIN" ]]; then
        bubble_rust_paths generation-previous
        return $?
    fi
    local gen
    gen="$(bubble_generation_link_target "$BUBBLEOS_PREVIOUS_LINK")" || return 1
    [[ -d "$(bubble_generation_path "$gen")" ]] || return 1
    printf '%s\n' "$gen"
}

bubble_generation_next() {
    local last=0 d n
    shopt -s nullglob
    for d in "$BUBBLEOS_GENERATIONS_DIR"/*; do
        [[ -d "$d" ]] || continue
        n="$(basename -- "$d")"
        [[ "$n" =~ ^[0-9]{6}$ ]] || continue
        (( 10#$n > last )) && last=$((10#$n))
    done
    printf '%06d\n' "$((last + 1))"
}

bubble_generation_write_metadata() {
    local gen="$1" description="${2:-}" file dir
    [[ -n "$description" ]] || description="bubbleOS generation $gen"
    description="${description//$'\n'/ }"
    dir="$(bubble_generation_path "$gen")"
    file="$dir/etc/bubbleos/generation"
    [[ ! -L "$dir/etc" && ! -L "$dir/etc/bubbleos" ]] || {
        printf 'bubble: refusing to write metadata through a symlink in %s\n' \
            "$dir" >&2
        return 1
    }
    install -d -m 0755 "$(dirname -- "$file")"
    cat > "$file" <<METADATA
GENERATION=$gen
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DESCRIPTION=$description
METADATA
    chmod 0644 "$file"
    chown root:root "$file"
}

bubble_snapshot_destination() {
    local dir="$1" base="$2" candidate n=1
    candidate="$dir/$base"
    while [[ -e "$candidate" ]]; do
        n=$((n + 1))
        candidate="$dir/${base}-${n}"
    done
    printf '%s\n' "$candidate"
}

bubble_snapshot_valid_name() {
    case "${1:-}" in
        ""|.|..|.*|*[!A-Za-z0-9._-]*) return 1 ;;
    esac
    return 0
}

bubble_snapshot_pending_path() {
    printf '%s/var-restore.request\n' "$BUBBLEOS_SNAPSHOTS_DIR"
}

bubble_snapshot_pending_from_file() {
    local marker="$1" line
    [[ -r "$marker" ]] || return 1
    while IFS= read -r line; do
        case "$line" in
            SNAPSHOT=*)
                line="${line#SNAPSHOT=}"
                bubble_snapshot_valid_name "$line" || return 1
                printf '%s\n' "$line"
                return 0
                ;;
        esac
    done < "$marker"
    return 1
}

bubble_snapshot_pending() {
    bubble_snapshot_pending_from_file "$(bubble_snapshot_pending_path)"
}

bubble_snapshot_prune() {
    local keep="${BUBBLEOS_SNAPSHOT_KEEP:-10}" dry_run=0
    local category dir name path ro pending count keep_start index
    local -a entries=()

    while (( $# )); do
        case "$1" in
            --keep)
                if (( $# < 2 )); then
                    printf 'bubble: snapshots prune --keep requires a number\n' >&2
                    return 2
                fi
                keep="$2"
                shift 2
                ;;
            --keep=*)
                keep="${1#*=}"
                shift
                ;;
            --dry-run|-n)
                dry_run=1
                shift
                ;;
            *)
                printf 'bubble: unknown snapshots prune option: %s\n' "$1" >&2
                return 2
                ;;
        esac
    done

    [[ "$keep" =~ ^[0-9]+$ ]] || {
        printf 'bubble: --keep must be a non-negative integer\n' >&2
        return 2
    }

    bubble_require_root || return 1
    bubble_require_snapshots_layout || return 1

    pending="$(bubble_snapshot_pending 2>/dev/null || true)"

    for category in rootfs var; do
        dir="$BUBBLEOS_SNAPSHOTS_DIR/$category"
        [[ -d "$dir" ]] || continue

        entries=()
        while IFS= read -r name; do
            entries+=("$name")
        done < <(
            find "$dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' |
                grep -v -- '-initial$' |
                LC_ALL=C sort
        )

        count=${#entries[@]}
        (( count > keep )) || continue
        keep_start=$(( count - keep ))

        for (( index = 0; index < count; index++ )); do
            name="${entries[$index]}"
            (( index >= keep_start )) && continue
            if [[ "$category" == "var" && "$name" == "$pending" ]]; then
                printf 'bubble: keeping pending restore point %s\n' "$name" >&2
                continue
            fi

            path="$dir/$name"
            ro="$(btrfs property get -ts "$path" ro 2>/dev/null || true)"
            if [[ "$ro" != "ro=true" ]]; then
                printf 'bubble: skipping %s/%s (not read-only)\n' \
                    "$category" "$name" >&2
                continue
            fi

            if (( dry_run )); then
                printf 'would delete %s/%s\n' "$category" "$name"
            elif btrfs subvolume delete "$path" >/dev/null 2>&1; then
                printf 'deleted %s/%s\n' "$category" "$name"
            else
                printf 'bubble: failed to delete %s/%s\n' \
                    "$category" "$name" >&2
            fi
        done
    done
}

bubble_var_restore_schedule() {
    local name="${1:-}" dir marker temporary from
    if [[ -z "$name" ]]; then
        printf 'bubble: snapshots restore requires a /var snapshot name\n' >&2
        return 2
    fi
    name="${name#var/}"
    if ! bubble_snapshot_valid_name "$name"; then
        printf 'bubble: invalid snapshot name: %s\n' "$name" >&2
        return 2
    fi

    bubble_require_root || return 1
    bubble_require_snapshots_layout || return 1

    dir="$BUBBLEOS_SNAPSHOTS_DIR/var"
    [[ -d "$dir/$name" ]] || {
        printf 'bubble: /var snapshot does not exist: %s\n' "$name" >&2
        return 1
    }
    [[ "$(btrfs property get -ts "$dir/$name" ro 2>/dev/null || true)" == "ro=true" ]] || {
        printf 'bubble: %s is not a read-only snapshot\n' "$name" >&2
        return 1
    }

    from="$(bubble_generation_current 2>/dev/null || printf 'unknown')"
    marker="$(bubble_snapshot_pending_path)"
    temporary="${marker}.tmp-$$"
    {
        printf 'SNAPSHOT=%s\n' "$name"
        printf 'REQUESTED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'REQUESTED_FROM=%s\n' "$from"
    } > "$temporary"
    chmod 0600 "$temporary"
    sync
    if ! mv -f "$temporary" "$marker"; then
        rm -f "$temporary"
        printf 'bubble: failed to write the restore request\n' >&2
        return 1
    fi
    sync
    printf 'bubble: /var restore from %s scheduled for the next boot\n' "$name"
}

_bubble_var_restore_swap() {
    local top="$1" marker snapshot snapshot_path safety stale stamp
    marker="$top/@snapshots/var-restore.request"
    [[ -f "$marker" ]] || return 0

    snapshot="$(bubble_snapshot_pending_from_file "$marker")" || {
        printf 'bubbleOS: invalid /var restore request; removing it\n' >&2
        rm -f "$marker"
        return 1
    }
    snapshot_path="$top/@snapshots/var/$snapshot"
    if [[ ! -d "$snapshot_path" ]]; then
        printf 'bubbleOS: /var snapshot %s is missing; restore cancelled\n' \
            "$snapshot" >&2
        rm -f "$marker"
        return 1
    fi
    if [[ "$(btrfs property get -ts "$snapshot_path" ro 2>/dev/null || true)" != "ro=true" ]]; then
        printf 'bubbleOS: %s is not a read-only snapshot; restore cancelled\n' \
            "$snapshot" >&2
        rm -f "$marker"
        return 1
    fi

    # Complete an interrupted swap from a previous boot before starting again.
    if [[ ! -d "$top/@var" && -d "$top/@var.restore" ]]; then
        if mv "$top/@var.restore" "$top/@var"; then
            rm -f "$marker"
            sync
            printf 'bubbleOS: completed an interrupted /var restore\n'
            return 0
        fi
        printf 'bubbleOS: cannot complete the interrupted /var restore\n' >&2
        return 1
    fi
    if [[ ! -d "$top/@var" ]]; then
        printf 'bubbleOS: @var is missing; restore cancelled\n' >&2
        rm -f "$marker"
        return 1
    fi
    if [[ -e "$top/@var.restore" ]]; then
        if ! btrfs subvolume delete "$top/@var.restore" >/dev/null 2>&1; then
            printf 'bubbleOS: stale @var.restore cannot be removed\n' >&2
            return 1
        fi
    fi

    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    safety="$(bubble_snapshot_destination "$top/@snapshots/var" "${stamp}-pre-restore")"
    if ! btrfs subvolume snapshot -r "$top/@var" "$safety" >/dev/null; then
        printf 'bubbleOS: cannot snapshot the current /var before restore\n' >&2
        return 1
    fi
    if ! btrfs subvolume snapshot "$snapshot_path" "$top/@var.restore" >/dev/null; then
        printf 'bubbleOS: cannot create a writable copy of %s\n' "$snapshot" >&2
        return 1
    fi

    stale="$(bubble_snapshot_destination "$top" "@var.pre-restore-${stamp}")"
    if ! mv "$top/@var" "$stale"; then
        printf 'bubbleOS: cannot move the current @var aside\n' >&2
        return 1
    fi
    if ! mv "$top/@var.restore" "$top/@var"; then
        mv "$stale" "$top/@var" 2>/dev/null || true
        printf 'bubbleOS: cannot install the restored @var\n' >&2
        return 1
    fi

    btrfs subvolume delete "$stale" >/dev/null 2>&1 ||
        printf 'bubbleOS: warning: could not delete %s\n' "${stale##*/}" >&2
    rm -f "$marker"
    sync
    printf 'bubbleOS: restored /var from %s (safety snapshot %s)\n' \
        "$snapshot" "${safety##*/}"
}

bubble_var_restore_apply() {
    local top root_source root_majmin result
    bubble_require_root || return 1
    command -v btrfs >/dev/null 2>&1 || {
        printf 'bubble: the btrfs command is unavailable\n' >&2
        return 1
    }
    command -v findmnt >/dev/null 2>&1 || {
        printf 'bubble: the findmnt command is unavailable\n' >&2
        return 1
    }

    if mountpoint -q /var; then
        printf 'bubble: /var is already mounted; restore skipped\n' >&2
        return 1
    fi

    root_source="$(findmnt -no SOURCE -T / 2>/dev/null || true)"
    root_source="${root_source%%\[*}"
    if [[ ! -b "$root_source" ]]; then
        root_majmin="$(findmnt -no MAJ:MIN -T / 2>/dev/null || true)"
        if [[ -n "$root_majmin" && -b "/dev/block/$root_majmin" ]]; then
            root_source="/dev/block/$root_majmin"
        fi
    fi
    if [[ ! -b "$root_source" ]]; then
        printf 'bubble: cannot determine the root block device\n' >&2
        return 1
    fi

    top="${BUBBLEOS_RUN_DIR}/var-restore"
    install -d -m 0700 "$top"
    if mountpoint -q "$top"; then
        umount "$top" 2>/dev/null || true
    fi
    if ! mount -t btrfs -o rw,subvolid=5 "$root_source" "$top"; then
        printf 'bubble: cannot mount the Btrfs top-level for /var restore\n' >&2
        return 1
    fi

    result=0
    _bubble_var_restore_swap "$top" || result=$?
    umount "$top" 2>/dev/null || true
    return "$result"
}

bubble_snapshot_generation() {
    local gen="$1" label="$2" base dest
    base="$(date -u +%Y%m%dT%H%M%SZ)-${gen}-${label}"
    install -d -m 0755 "$BUBBLEOS_SNAPSHOTS_DIR/rootfs"
    dest="$(bubble_snapshot_destination "$BUBBLEOS_SNAPSHOTS_DIR/rootfs" "$base")"
    btrfs subvolume snapshot -r "$(bubble_generation_path "$gen")" "$dest" >/dev/null
    printf '%s\n' "$dest"
}

bubble_snapshot_var() {
    local label="$1" base dest
    mountpoint -q /var || {
        printf 'bubble: /var is not a mount point; cannot snapshot it\n' >&2
        return 1
    }
    btrfs subvolume show /var >/dev/null 2>&1 || {
        printf 'bubble: /var is not a Btrfs subvolume; cannot snapshot it\n' >&2
        return 1
    }
    base="$(date -u +%Y%m%dT%H%M%SZ)-${label}"
    install -d -m 0755 "$BUBBLEOS_SNAPSHOTS_DIR/var"
    dest="$(bubble_snapshot_destination "$BUBBLEOS_SNAPSHOTS_DIR/var" "$base")"
    btrfs subvolume snapshot -r /var "$dest" >/dev/null
    printf '%s\n' "$dest"
}

bubble_generation_create() {
    local from="" description="" gen source dest
    while (( $# )); do
        case "$1" in
            --from)
                if (( $# < 2 )); then
                    printf 'bubble: --from requires a generation number\n' >&2
                    return 2
                fi
                from="$2"
                shift 2
                ;;
            --from=*)
                from="${1#*=}"
                shift
                ;;
            --description)
                if (( $# < 2 )); then
                    printf 'bubble: --description requires a value\n' >&2
                    return 2
                fi
                description="$2"
                shift 2
                ;;
            --description=*)
                description="${1#*=}"
                shift
                ;;
            *)
                printf 'bubble: unknown generation create option: %s\n' "$1" >&2
                return 2
                ;;
        esac
    done

    bubble_require_root || return 1
    bubble_require_generation_layout || return 1

    if [[ -z "$from" ]]; then
        from="$(bubble_generation_current)" || {
            printf 'bubble: no active generation to clone\n' >&2
            return 1
        }
    fi
    bubble_generation_exists "$from" || {
        printf 'bubble: generation %s does not exist\n' "$from" >&2
        return 1
    }

    gen="$(bubble_generation_next)"
    source="$(bubble_generation_path "$from")"
    dest="$(bubble_generation_path "$gen")"
    [[ ! -e "$dest" ]] || {
        printf 'bubble: generation path already exists: %s\n' "$dest" >&2
        return 1
    }

    btrfs subvolume snapshot "$source" "$dest" >/dev/null || {
        printf 'bubble: failed to snapshot generation %s\n' "$from" >&2
        return 1
    }
    bubble_generation_write_metadata "$gen" "$description"
    printf '%s\n' "$gen"
}

bubble_generation_activate() {
    local gen="${1:-}" current
    if [[ -z "$gen" ]]; then
        printf 'bubble: generation activate requires a generation number\n' >&2
        return 2
    fi

    bubble_require_root || return 1
    bubble_require_generation_layout || return 1
    bubble_generation_exists "$gen" || {
        printf 'bubble: generation %s does not exist\n' "$gen" >&2
        return 1
    }

    current="$(bubble_generation_current 2>/dev/null || true)"
    if [[ "$current" == "$gen" ]]; then
        printf 'bubble: generation %s is already active\n' "$gen" >&2
        return 0
    fi

    if [[ "${BUBBLEOS_SKIP_SNAPSHOTS:-0}" != "1" ]]; then
        bubble_require_snapshots_layout || return 1
        if [[ -n "$current" ]]; then
            bubble_snapshot_generation "$current" "before-${gen}" >/dev/null || return 1
        fi
        bubble_snapshot_var "before-${gen}" >/dev/null || return 1
    fi

    if [[ -n "$current" ]]; then
        ln -sfn "generations/$current" "$BUBBLEOS_PREVIOUS_LINK"
    else
        rm -f "$BUBBLEOS_PREVIOUS_LINK"
    fi
    ln -sfn "generations/$gen" "$BUBBLEOS_CURRENT_LINK"
    sync

    if [[ "${BUBBLEOS_SKIP_SNAPSHOTS:-0}" != "1" ]]; then
        bubble_snapshot_prune --keep "${BUBBLEOS_SNAPSHOT_KEEP:-10}" >/dev/null 2>&1 ||
            printf 'bubble: warning: automatic snapshot pruning failed\n' >&2
    fi

    printf 'bubble: generation %s is selected for the next boot\n' "$gen" >&2
}

bubble_generation_list() {
    local d
    shopt -s nullglob
    for d in "$BUBBLEOS_GENERATIONS_DIR"/*; do
        [[ -d "$d" ]] || continue
        basename -- "$d"
    done | sort -n
}

bubble_snapshot_list() {
    [[ -d "$BUBBLEOS_SNAPSHOTS_DIR" ]] || return 1
    find "$BUBBLEOS_SNAPSHOTS_DIR" -mindepth 2 -maxdepth 2 -type d -printf '%P\n' 2>/dev/null |
        sort
}

# ------------------------------------------------------------------------------
# Store-backed generation composition
# ------------------------------------------------------------------------------

bubble_generation_lock_path() {
    printf '%s/etc/bubbleos/packages.json\n' "$(bubble_generation_path "$1")"
}

bubble_generation_lock_json() {
    local gen="${1:-}" file
    [[ -n "$gen" ]] || return 1
    bubble_generation_exists "$gen" || return 1
    file="$(bubble_generation_lock_path "$gen")"
    if [[ -f "$file" ]]; then
        jq -e 'type == "object" and ((.packages // []) | type == "array")' \
            "$file" >/dev/null 2>&1 || {
            printf 'bubble: invalid package lock in generation %s: %s\n' \
                "$gen" "$file" >&2
            return 1
        }
        jq -S '.' "$file"
    else
        jq -n --arg base "$gen" \
            '{format: 1, base_generation: $base, packages: []}'
    fi
}

bubble_generation_base() {
    local gen="${1:-}" lock
    lock="$(bubble_generation_lock_json "$gen")" || return 1
    jq -r --arg gen "$gen" '.base_generation // $gen' <<< "$lock"
}

bubble_generation_package_lines() {
    local gen="${1:-}" lock
    lock="$(bubble_generation_lock_json "$gen")" || return 1
    jq -r '
        .packages | sort_by(.id)[] |
        [.id, .version, (.type // "system"), (.digest // "")] | @tsv
    ' <<< "$lock"
}

bubble_package_lock_add() {
    local lock="$1" id="$2" version="$3" digest="$4" type="$5" name="$6"
    jq --arg id "$id" --arg version "$version" --arg digest "$digest" \
        --arg type "$type" --arg name "$name" '
        .format = (.format // 1) |
        .packages = (
            ((.packages // []) | map(select(.id != $id))) +
            [{id: $id, version: $version, digest: $digest, type: $type, name: $name}]
        ) |
        .packages |= sort_by(.id)
    ' <<< "$lock"
}

bubble_package_lock_remove() {
    local lock="$1" id="$2"
    jq --arg id "$id" '
        .format = (.format // 1) |
        .packages = ((.packages // []) | map(select(.id != $id)))
    ' <<< "$lock"
}

bubble_package_lock_verify() {
    local lock="$1"
    local -a selectors=()
    mapfile -t selectors < <(
        jq -r '.packages[]? | "\(.id)=\(.version)"' <<< "$lock" |
            LC_ALL=C sort
    )
    (( ${#selectors[@]} > 0 )) || return 0
    bubble_store_ulpm verify "${selectors[@]}" >&2
}

# bubble_generation_compose_from <source-gen> <lock-json> <description> <activate>
#
# Builds a new generation from the source's base generation and overlays every
# package pinned in the lock. The base generation is always package-free, so
# upgrading or removing a package cannot leave stale files behind. Prints the
# new generation number on stdout; progress goes to stderr.
bubble_generation_compose_from() {
    local source="${1:-}" lock="${2:-}" description="${3:-}" activate="${4:-0}"
    local base base_lock base_packages gen dest object manifest id version digest type
    local count lock_tmp

    [[ -n "$source" && -n "$lock" ]] || return 1
    bubble_generation_exists "$source" || {
        printf 'bubble: generation %s does not exist\n' "$source" >&2
        return 1
    }
    jq -e 'type == "object" and ((.packages // []) | type == "array")' \
        <<< "$lock" >/dev/null 2>&1 || {
        printf 'bubble: invalid package set\n' >&2
        return 1
    }

    base="$(jq -r '.base_generation // empty' <<< "$lock")"
    [[ -n "$base" ]] || base="$source"
    bubble_generation_exists "$base" || {
        printf 'bubble: base generation %s does not exist\n' "$base" >&2
        return 1
    }
    base_lock="$(bubble_generation_lock_json "$base")" || return 1
    base_packages="$(jq '.packages | length' <<< "$base_lock")"
    if (( base_packages > 0 )); then
        printf 'bubble: base generation %s already contains store packages\n' \
            "$base" >&2
        return 1
    fi

    gen="$(bubble_generation_next)"
    dest="$(bubble_generation_path "$gen")"

    printf 'bubble: composing generation %s from base %s\n' "$gen" "$base" >&2
    if ! btrfs subvolume snapshot "$(bubble_generation_path "$base")" "$dest" \
        >/dev/null; then
        printf 'bubble: cannot snapshot base generation %s\n' "$base" >&2
        return 1
    fi

    while IFS=$'\t' read -r id version digest type; do
        [[ -n "$id" ]] || continue
        case "$type" in
            ""|rootfs|os|distro|system) ;;
            *)
                printf 'bubble: package %s is not a system package (type %s)\n' \
                    "$id" "$type" >&2
                btrfs subvolume delete "$dest" >/dev/null 2>&1 || true
                return 1
                ;;
        esac
        object="$(bubble_store_object_dir "$digest")" || {
            printf 'bubble: invalid digest for package %s\n' "$id" >&2
            btrfs subvolume delete "$dest" >/dev/null 2>&1 || true
            return 1
        }
        manifest="$object/manifest.json"
        [[ -f "$manifest" && -d "$object/payload" ]] || {
            printf 'bubble: store object missing for %s %s (%s)\n' \
                "$id" "$version" "$digest" >&2
            btrfs subvolume delete "$dest" >/dev/null 2>&1 || true
            return 1
        }
        if [[ "$(jq -r '.id // empty' "$manifest")" != "$id" ]] ||
            [[ "$(jq -r '.version // empty' "$manifest")" != "$version" ]]; then
            printf 'bubble: store object does not match %s %s\n' \
                "$id" "$version" >&2
            btrfs subvolume delete "$dest" >/dev/null 2>&1 || true
            return 1
        fi
        printf 'bubble: applying %s %s\n' "$id" "$version" >&2
        if ! cp -a --reflink=auto -- "$object/payload/." "$dest/"; then
            printf 'bubble: cannot apply package %s %s\n' "$id" "$version" >&2
            btrfs subvolume delete "$dest" >/dev/null 2>&1 || true
            return 1
        fi
    done < <(
        jq -r '
            .packages | sort_by(.id)[] |
            [.id, .version, (.digest // ""), (.type // "system")] | @tsv
        ' <<< "$lock"
    )

    lock_tmp="$dest/etc/bubbleos/.packages.json.$$"
    if [[ -L "$dest/etc" || -L "$dest/etc/bubbleos" ]]; then
        printf 'bubble: refusing to write the package lock through a symlink\n' >&2
        btrfs subvolume delete "$dest" >/dev/null 2>&1 || true
        return 1
    fi
    install -d -m 0755 "$dest/etc/bubbleos" || {
        btrfs subvolume delete "$dest" >/dev/null 2>&1 || true
        return 1
    }
    if ! jq -S --arg base "$base" '
        .format = (.format // 1) |
        .base_generation = $base |
        .packages = ((.packages // []) | sort_by(.id))
    ' <<< "$lock" > "$lock_tmp"; then
        rm -f -- "$lock_tmp"
        btrfs subvolume delete "$dest" >/dev/null 2>&1 || true
        return 1
    fi
    chmod 0644 "$lock_tmp" && chown root:root "$lock_tmp" &&
        mv -f -- "$lock_tmp" "$dest/etc/bubbleos/packages.json" || {
        rm -f -- "$lock_tmp"
        btrfs subvolume delete "$dest" >/dev/null 2>&1 || true
        return 1
    }

    count="$(jq '.packages | length' <<< "$lock")"
    if [[ -z "$description" ]]; then
        if (( count > 0 )); then
            description="bubbleOS generation $gen ($count package(s))"
        else
            description="bubbleOS generation $gen"
        fi
    fi
    bubble_generation_write_metadata "$gen" "$description" || {
        printf 'bubble: cannot write metadata for generation %s\n' "$gen" >&2
        btrfs subvolume delete "$dest" >/dev/null 2>&1 || true
        return 1
    }

    if [[ ! -f "$dest/etc/os-release" ]] ||
        { [[ ! -x "$dest/usr/bin/sh" && ! -x "$dest/bin/sh" ]]; }; then
        printf 'bubble: composed generation %s is not bootable\n' "$gen" >&2
        btrfs subvolume delete "$dest" >/dev/null 2>&1 || true
        return 1
    fi
    if [[ ! -s "$dest$BUBBLEOS_BOOT_ASSETS_DIR/vmlinuz" ]] ||
        [[ ! -s "$dest$BUBBLEOS_BOOT_ASSETS_DIR/initramfs.cpio.gz" ]]; then
        printf 'bubble: generation %s has no boot assets\n' "$gen" >&2
        btrfs subvolume delete "$dest" >/dev/null 2>&1 || true
        return 1
    fi
    bubble_generation_lock_json "$gen" >/dev/null || {
        printf 'bubble: generation %s has an invalid package lock\n' "$gen" >&2
        btrfs subvolume delete "$dest" >/dev/null 2>&1 || true
        return 1
    }

    if [[ "$activate" == "1" ]]; then
        bubble_generation_activate "$gen" || return 1
    fi
    printf '%s\n' "$gen"
}

bubble_generation_install() {
    local from="" activate=1 description="" target info
    local id version type name digest source lock
    local -a targets=()

    while (( $# )); do
        case "$1" in
            --from)
                [[ $# -ge 2 ]] || {
                    printf 'bubble: --from requires a generation\n' >&2
                    return 2
                }
                from="$2"
                shift 2
                ;;
            --from=*)
                from="${1#*=}"
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
            --description)
                [[ $# -ge 2 ]] || {
                    printf 'bubble: --description requires a value\n' >&2
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
                printf 'bubble: unknown install option: %s\n' "$1" >&2
                return 2
                ;;
            *)
                targets+=("$1")
                shift
                ;;
        esac
    done

    (( ${#targets[@]} > 0 )) || {
        printf 'bubble: install requires at least one package or LPK\n' >&2
        return 2
    }
    bubble_require_root || return 1
    bubble_require_generation_layout || return 1
    bubble_store_require || return 1

    source="${from:-$(bubble_generation_current)}" || {
        printf 'bubble: no active generation to extend\n' >&2
        return 1
    }
    bubble_generation_exists "$source" || {
        printf 'bubble: generation %s does not exist\n' "$source" >&2
        return 1
    }
    lock="$(bubble_generation_lock_json "$source")" || return 1

    local -a repo_targets=()
    for target in "${targets[@]}"; do
        if [[ -f "$target" ]]; then
            bubble_store_ulpm add "$target" >&2 || return 1
            info="$(bubble_store_info_for_file "$target")" || return 1
        elif info="$(bubble_store_info_for_id "$target" 2>/dev/null)"; then
            :
        else
            # Not a local payload and not already stored: resolve it against
            # the verified system repositories with its dependencies.
            repo_targets+=("$target")
            continue
        fi
        IFS=$'\t' read -r id version type name digest <<< "$info"
        [[ -n "$id" && -n "$version" && -n "$digest" ]] || {
            printf 'bubble: cannot resolve package metadata for %s\n' \
                "$target" >&2
            return 1
        }
        case "$type" in
            ""|rootfs|os|distro|system) ;;
            *)
                printf 'bubble: %s is not a system package (type %s)\n' \
                    "$id" "$type" >&2
                return 1
                ;;
        esac
        lock="$(bubble_package_lock_add \
            "$lock" "$id" "$version" "$digest" "$type" "$name")" || return 1
    done

    if (( ${#repo_targets[@]} > 0 )); then
        local plan
        plan="$(bubble_resolve_plan "$source" install --lock "$lock" \
            "${repo_targets[@]}")" || return 1
        bubble_repo_apply_plan "$source" "$plan" "$description" "$activate"
        return
    fi

    bubble_package_lock_verify "$lock" || return 1
    bubble_generation_compose_from \
        "$source" "$lock" "$description" "$activate"
}

bubble_generation_remove() {
    local from="" activate=1 description="" id="" lock source
    while (( $# )); do
        case "$1" in
            --from)
                [[ $# -ge 2 ]] || {
                    printf 'bubble: --from requires a generation\n' >&2
                    return 2
                }
                from="$2"
                shift 2
                ;;
            --from=*)
                from="${1#*=}"
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
            --description)
                [[ $# -ge 2 ]] || {
                    printf 'bubble: --description requires a value\n' >&2
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
                break
                ;;
            -*)
                printf 'bubble: unknown remove option: %s\n' "$1" >&2
                return 2
                ;;
            *)
                if [[ -n "$id" ]]; then
                    printf 'bubble: remove accepts one package id\n' >&2
                    return 2
                fi
                id="$1"
                shift
                ;;
        esac
    done

    [[ -n "$id" ]] || {
        printf 'bubble: remove requires a package id\n' >&2
        return 2
    }
    bubble_require_root || return 1
    bubble_require_generation_layout || return 1
    bubble_store_require || return 1

    source="${from:-$(bubble_generation_current)}" || {
        printf 'bubble: no active generation to modify\n' >&2
        return 1
    }
    bubble_generation_exists "$source" || {
        printf 'bubble: generation %s does not exist\n' "$source" >&2
        return 1
    }
    lock="$(bubble_generation_lock_json "$source")" || return 1
    if ! jq -e --arg id "$id" \
        '.packages[]? | select(.id == $id)' <<< "$lock" >/dev/null; then
        printf 'bubble: package %s is not installed in generation %s\n' \
            "$id" "$source" >&2
        return 1
    fi
    lock="$(bubble_package_lock_remove "$lock" "$id")" || return 1
    bubble_package_lock_verify "$lock" || return 1
    bubble_generation_compose_from \
        "$source" "$lock" "$description" "$activate"
}

# ------------------------------------------------------------------------------
# Generation lifecycle: deletion and pruning
# ------------------------------------------------------------------------------

bubble_generation_running() {
    local gen
    gen="$(sed -n 's/^GENERATION=//p' /etc/bubbleos/generation 2>/dev/null |
        head -n1)"
    [[ "$gen" =~ ^[0-9]{6}$ ]] || return 1
    printf '%s\n' "$gen"
}

# bubble_generation_lock_referrers <gen>
#
# Prints the generations whose package lock names <gen> as its composition
# base. Fails if a lock exists but cannot be parsed: deleting a base without
# knowing every user would break future recompositions.
bubble_generation_lock_referrers() {
    local base="${1:-}" gen file
    [[ -n "$base" ]] || return 1
    while IFS= read -r gen; do
        [[ "$gen" =~ ^[0-9]{6}$ ]] || continue
        [[ "$gen" == "$base" ]] && continue
        file="$(bubble_generation_lock_path "$gen")"
        [[ -e "$file" || -L "$file" ]] || continue
        if [[ ! -f "$file" || -L "$file" ]]; then
            printf 'bubble: invalid package lock in generation %s: %s\n' \
                "$gen" "$file" >&2
            return 2
        fi
        if ! jq -e 'type == "object" and ((.packages // []) | type == "array")' \
            "$file" >/dev/null 2>&1; then
            printf 'bubble: cannot parse the package lock of generation %s\n' \
                "$gen" >&2
            return 2
        fi
        if jq -e --arg base "$base" '.base_generation == $base' "$file" \
            >/dev/null 2>&1; then
            printf '%s\n' "$gen"
        fi
    done < <(bubble_generation_list)
}

# bubble_generation_delete <gen>
#
# Deletes a generation subvolume. The current, previous and running
# generations are never removable, and neither is a generation used as the
# composition base of another generation lock.
bubble_generation_delete() {
    local gen="${1:-}" path current previous running refs
    local -a reasons=()
    local item joined

    if [[ -z "$gen" ]]; then
        printf 'bubble: generation delete requires a generation number\n' >&2
        return 2
    fi
    if [[ ! "$gen" =~ ^[0-9]{6}$ ]]; then
        printf 'bubble: invalid generation number: %s\n' "$gen" >&2
        return 2
    fi

    bubble_require_root || return 1
    bubble_require_generation_layout || return 1
    bubble_generation_exists "$gen" || {
        printf 'bubble: generation %s does not exist\n' "$gen" >&2
        return 1
    }
    command -v jq >/dev/null 2>&1 || {
        printf 'bubble: jq is required to check generation references\n' >&2
        return 1
    }

    path="$(bubble_generation_path "$gen")"
    if [[ -L "$path" ]]; then
        printf 'bubble: refusing to delete a symlinked generation: %s\n' \
            "$path" >&2
        return 1
    fi

    current="$(bubble_generation_current 2>/dev/null || true)"
    previous="$(bubble_generation_previous 2>/dev/null || true)"
    running="$(bubble_generation_running 2>/dev/null || true)"

    [[ "$gen" != "$current" ]] || reasons+=("the current generation")
    [[ "$gen" != "$previous" ]] || reasons+=("the previous generation")
    [[ "$gen" != "$running" ]] || reasons+=("the running generation")

    refs="$(bubble_generation_lock_referrers "$gen")" || return 1
    if [[ -n "$refs" ]]; then
        reasons+=("the base generation of ${refs//$'\n'/, }")
    fi

    if (( ${#reasons[@]} > 0 )); then
        joined=""
        for item in "${reasons[@]}"; do
            joined+="${joined:+; }$item"
        done
        printf 'bubble: refusing to delete generation %s: it is %s\n' \
            "$gen" "$joined" >&2
        return 1
    fi

    if ! btrfs subvolume delete "$path" >/dev/null; then
        printf 'bubble: failed to delete generation %s\n' "$gen" >&2
        return 1
    fi
    sync
    printf 'Deleted generation %s\n' "$gen"
}

# bubble_generation_prune [--keep N] [--dry-run]
#
# Keeps the newest N generations, plus the current, previous and running
# generations and every generation used as a composition base by a survivor.
# Base references are closed transitively before anything is deleted.
bubble_generation_prune() {
    local keep=3 dry_run=0
    local -a all=()
    local -A keep_set=()
    local gen path base current previous running start index changed
    local lock_json removed=0 failed=0

    while (( $# )); do
        case "$1" in
            --keep)
                if (( $# < 2 )); then
                    printf 'bubble: generation prune --keep requires a number\n' >&2
                    return 2
                fi
                keep="$2"
                shift 2
                ;;
            --keep=*)
                keep="${1#*=}"
                shift
                ;;
            --dry-run|-n)
                dry_run=1
                shift
                ;;
            *)
                printf 'bubble: unknown generation prune option: %s\n' "$1" >&2
                return 2
                ;;
        esac
    done

    [[ "$keep" =~ ^[0-9]+$ ]] || {
        printf 'bubble: --keep must be a non-negative integer\n' >&2
        return 2
    }

    bubble_require_root || return 1
    bubble_require_generation_layout || return 1
    command -v jq >/dev/null 2>&1 || {
        printf 'bubble: jq is required to check generation references\n' >&2
        return 1
    }

    while IFS= read -r gen; do
        [[ "$gen" =~ ^[0-9]{6}$ ]] || continue
        all+=("$gen")
    done < <(bubble_generation_list)

    (( ${#all[@]} > 0 )) || {
        printf 'No generations to prune.\n'
        return 0
    }

    start=$(( ${#all[@]} - keep ))
    (( start >= 0 )) || start=0
    for (( index = start; index < ${#all[@]}; index++ )); do
        keep_set["${all[$index]}"]=1
    done

    current="$(bubble_generation_current 2>/dev/null || true)"
    previous="$(bubble_generation_previous 2>/dev/null || true)"
    running="$(bubble_generation_running 2>/dev/null || true)"
    [[ -z "$current" ]] || keep_set["$current"]=1
    [[ -z "$previous" ]] || keep_set["$previous"]=1
    [[ -z "$running" ]] || keep_set["$running"]=1

    changed=1
    while (( changed )); do
        changed=0
        for gen in "${all[@]}"; do
            [[ -n "${keep_set[$gen]:-}" ]] || continue
            lock_json="$(bubble_generation_lock_json "$gen")" || {
                printf 'bubble: cannot read the package lock of generation %s; refusing to prune\n' \
                    "$gen" >&2
                return 1
            }
            base="$(jq -r '.base_generation // empty' <<< "$lock_json")" || {
                printf 'bubble: cannot read the package lock of generation %s; refusing to prune\n' \
                    "$gen" >&2
                return 1
            }
            [[ -n "$base" ]] || continue
            if [[ -z "${keep_set[$base]:-}" ]]; then
                keep_set["$base"]=1
                changed=1
            fi
        done
    done

    for gen in "${all[@]}"; do
        [[ -n "${keep_set[$gen]:-}" ]] && continue
        path="$(bubble_generation_path "$gen")"
        if [[ -L "$path" ]]; then
            printf 'bubble: skipping symlinked generation: %s\n' "$path" >&2
            failed=1
            continue
        fi
        if (( dry_run )); then
            printf 'would delete generation %s\n' "$gen"
            continue
        fi
        if btrfs subvolume delete "$path" >/dev/null 2>&1; then
            printf 'Deleted generation %s\n' "$gen"
            removed=$((removed + 1))
        else
            printf 'bubble: failed to delete generation %s\n' "$gen" >&2
            failed=1
        fi
    done

    if (( dry_run )); then
        return 0
    fi
    (( removed == 0 )) || sync
    if (( removed == 0 && failed == 0 )); then
        printf 'No generations to prune.\n'
    fi
    (( failed == 0 ))
}

bubble_generation_compose() {
    local from="" activate=0 description="" source lock
    while (( $# )); do
        case "$1" in
            --from)
                [[ $# -ge 2 ]] || {
                    printf 'bubble: --from requires a generation\n' >&2
                    return 2
                }
                from="$2"
                shift 2
                ;;
            --from=*)
                from="${1#*=}"
                shift
                ;;
            --activate)
                activate=1
                shift
                ;;
            --description)
                [[ $# -ge 2 ]] || {
                    printf 'bubble: --description requires a value\n' >&2
                    return 2
                }
                description="$2"
                shift 2
                ;;
            --description=*)
                description="${1#*=}"
                shift
                ;;
            *)
                printf 'bubble: unknown compose option: %s\n' "$1" >&2
                return 2
                ;;
        esac
    done

    bubble_require_root || return 1
    bubble_require_generation_layout || return 1
    bubble_store_require || return 1
    source="${from:-$(bubble_generation_current)}" || {
        printf 'bubble: no active generation to compose\n' >&2
        return 1
    }
    bubble_generation_exists "$source" || {
        printf 'bubble: generation %s does not exist\n' "$source" >&2
        return 1
    }
    lock="$(bubble_generation_lock_json "$source")" || return 1
    bubble_package_lock_verify "$lock" || return 1
    bubble_generation_compose_from \
        "$source" "$lock" "$description" "$activate"
}
