#!/usr/bin/env bash
# ==============================================================================
# lib/store.sh - System package store for bubbleOS generation composition
#
# ULPM remains the package engine: this module only verifies, imports and
# indexes system LPK payloads. Generation creation and activation stay in the
# bubbleOS core (bubble/lib/generation.sh).
#
# Store layout (default /var/lib/bubbleos/store):
#
#   objects/<sha256>/
#       package.lpk       sealed package, kept for verification/reinstall
#       manifest.json     canonical JSON manifest
#       meta.json         storage metadata (source, import time)
#       payload/          files overlaid onto a generation
#   packages/<id>/<version> -> ../../objects/<sha256>
#
# Objects are content-addressed, so importing the same package twice is a
# no-op and a generation can pin the exact bytes it was composed from.
# ==============================================================================

_ulpm_store_root() {
    printf '%s\n' "${ULPM_SYSTEM_STORE:-/var/lib/bubbleos/store}"
}

_ulpm_store_require_tools() {
    check_dependencies sha256sum unsquashfs jq find sort awk || return 1
}

_ulpm_store_valid_id() {
    local id="${1:-}"
    [[ -n "$id" && ${#id} -le 128 ]] || return 1
    [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
    [[ "$id" != *..* ]]
}

_ulpm_store_valid_version() {
    local version="${1:-}"
    [[ -n "$version" && ${#version} -le 64 ]] || return 1
    [[ "$version" =~ ^[A-Za-z0-9.+_:~-]+$ ]] || return 1
    [[ "$version" != "." && "$version" != ".." ]]
}

_ulpm_store_digest() {
    local file="$1"
    sha256sum -- "$file" | awk '{print $1}'
}

_ulpm_store_object_dir() {
    local digest="$1"
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s/objects/%s\n' "$(_ulpm_store_root)" "$digest"
}

_ulpm_store_package_link() {
    local id="$1" version="$2"
    _ulpm_store_valid_id "$id" || return 1
    _ulpm_store_valid_version "$version" || return 1
    printf '%s/packages/%s/%s\n' "$(_ulpm_store_root)" "$id" "$version"
}

# Prints the newest stored version for an ID.
_ulpm_store_latest_version() {
    local id="$1" dir
    _ulpm_store_valid_id "$id" || return 1
    dir="$(_ulpm_store_root)/packages/$id"
    [[ -d "$dir" && ! -L "$dir" ]] || return 1
    find "$dir" -mindepth 1 -maxdepth 1 -type l -printf '%f\n' 2>/dev/null |
        LC_ALL=C sort -V |
        tail -n1
}

# Resolves <id> or <id=version> to the store object path and prints:
#   id<TAB>version<TAB>digest<TAB>object
_ulpm_store_resolve() {
    local selector="${1:-}" id version link digest object
    [[ -n "$selector" ]] || return 1

    if [[ "$selector" == *=* ]]; then
        id="${selector%%=*}"
        version="${selector#*=}"
    else
        id="$selector"
        version="$(_ulpm_store_latest_version "$id")" || return 1
    fi
    _ulpm_store_valid_id "$id" || return 1
    _ulpm_store_valid_version "$version" || return 1

    link="$(_ulpm_store_package_link "$id" "$version")" || return 1
    [[ -L "$link" ]] || return 1
    digest="$(basename -- "$(readlink -- "$link")")" || return 1
    _ulpm_store_object_dir "$digest" >/dev/null || return 1
    object="$(_ulpm_store_object_dir "$digest")"
    [[ -f "$object/manifest.json" && -d "$object/payload" ]] || return 1

    printf '%s\t%s\t%s\t%s\n' "$id" "$version" "$digest" "$object"
}

_ulpm_store_payload_is_system() {
    local root="$1"
    [[ -d "$root/etc" || -d "$root/usr" || -d "$root/bin" || -d "$root/sbin" ]]
}

_ulpm_store_validate_payload() {
    local payload="$1" special
    [[ -d "$payload" ]] || {
        error "Package payload is missing."
        return 1
    }
    [[ -n "$(find "$payload" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] || {
        error "Package payload is empty."
        return 1
    }
    special="$(find "$payload" \( -type b -o -type c -o -type p -o -type s \) -print -quit 2>/dev/null || true)"
    [[ -z "$special" ]] || {
        error "Package payload contains an unsupported special file: ${special#"$payload"/}"
        return 1
    }
    return 0
}

# Copies a flat pre-structured payload (files at the archive root next to
# meta/) into an object payload directory, excluding the manifest directory.
_ulpm_store_copy_flat_payload() {
    local source="$1" destination="$2" entry
    shopt -s dotglob nullglob
    for entry in "$source"/*; do
        [[ "${entry##*/}" == "meta" ]] && continue
        cp -a -- "$entry" "$destination/" || {
            shopt -u dotglob nullglob
            return 1
        }
    done
    shopt -u dotglob nullglob
    return 0
}

_ulpm_store_link_object() {
    local id="$1" version="$2" digest="$3" replace="$4"
    local root pkg_dir link target current
    root="$(_ulpm_store_root)"
    pkg_dir="$root/packages/$id"

    [[ ! -L "$pkg_dir" ]] || {
        error "Refusing a symlinked store package directory: $pkg_dir"
        return 1
    }
    install -d -m 0755 "$pkg_dir" || return 1

    link="$pkg_dir/$version"
    target="../../objects/$digest"
    if [[ -L "$link" ]]; then
        current="$(readlink -- "$link" 2>/dev/null || true)"
        if [[ "$current" == "$target" ]]; then
            return 0
        fi
        if [[ "$replace" != "1" ]]; then
            error "Package $id $version is already stored from a different digest (use --replace)."
            return 1
        fi
        rm -f -- "$link" || return 1
    elif [[ -e "$link" ]]; then
        error "Store package path is not a symlink: $link"
        return 1
    fi

    ln -s -- "$target" "$link" || return 1
    return 0
}

# Prints every digest pinned by a generation package lock. Generation locks
# are authoritative: an object referenced by a retained generation must
# survive even when its store link was removed. A lock that cannot be parsed
# aborts the scan so GC never guesses.
_ulpm_store_generation_digests() {
    local root gen lock digest
    root="${ULPM_GENERATIONS_DIR:-/var/lib/bubbleos/rootfs/generations}"
    [[ -e "$root" ]] || return 0
    [[ -d "$root" ]] || {
        error "Generation directory is not a directory: $root"
        return 1
    }

    while IFS= read -r gen; do
        [[ "$(basename -- "$gen")" =~ ^[0-9]{6}$ ]] || continue
        lock="$gen/etc/bubbleos/packages.json"
        [[ -e "$lock" || -L "$lock" ]] || continue
        if [[ ! -f "$lock" || -L "$lock" ]]; then
            error "Refusing a non-regular generation package lock: $lock"
            return 1
        fi
        if ! jq -e 'type == "object" and ((.packages // []) | type == "array")' \
            "$lock" >/dev/null 2>&1; then
            error "Cannot parse generation package lock: $lock"
            return 1
        fi
        while IFS= read -r digest; do
            [[ -n "$digest" ]] || continue
            if [[ ! "$digest" =~ ^[0-9a-f]{64}$ ]]; then
                error "Invalid package digest in generation lock: $lock"
                return 1
            fi
            printf '%s\n' "$digest"
        done < <(jq -r '.packages[]? | .digest // empty' "$lock")
    done < <(find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null |
        LC_ALL=C sort)
}

_ulpm_store_gc_object() {
    local digest="$1" references="${2:-}" root link referenced=0
    root="$(_ulpm_store_root)"
    if [[ -n "$references" ]] &&
        grep -Fxq -- "$digest" "$references" 2>/dev/null; then
        return 1
    fi
    while IFS= read -r link; do
        [[ -n "$link" ]] || continue
        if [[ "$(basename -- "$(readlink -- "$link" 2>/dev/null || true)")" == "$digest" ]]; then
            referenced=1
            break
        fi
    done < <(find "$root/packages" -type l 2>/dev/null)
    (( referenced == 0 )) || return 1
    rm -rf -- "$root/objects/$digest"
    return 0
}

cmd_store_add() {
    local replace=0 source="" root stage extract payload payload_mode object object_final
    local manifest_raw id version pkg_type pkg_arch digest link

    while (( $# )); do
        case "$1" in
            --replace)
                replace=1
                shift
                ;;
            --)
                shift
                break
                ;;
            -*)
                error "Unknown store add option: $1"
                return 2
                ;;
            *)
                break
                ;;
        esac
    done
    source="${1:-}"
    [[ -n "$source" ]] || {
        error "Usage: ulpm store add [--replace] <package.lpk>"
        return 2
    }
    [[ -f "$source" && -r "$source" && ! -L "$source" ]] || {
        error "Package not found or unreadable: $source"
        return 1
    }

    _ulpm_store_require_tools || return 1
    check_package_signature "$source" || return 1

    manifest_raw="$(read_package_manifest "$source")" || {
        error "Package manifest not found in $source."
        return 1
    }
    jq -e 'type == "object"' <<< "$manifest_raw" >/dev/null 2>&1 || {
        error "Invalid package manifest JSON."
        return 1
    }

    id="$(jq -r '.id // empty' <<< "$manifest_raw")"
    version="$(jq -r '.version // "1.0.0"' <<< "$manifest_raw")"
    pkg_type="$(jq -r '.type // .kind // empty' <<< "$manifest_raw")"
    pkg_arch="$(jq -r '.arch // "all"' <<< "$manifest_raw")"
    _ulpm_store_valid_id "$id" || {
        error "Invalid or missing system package ID: ${id:-<empty>}"
        return 1
    }
    _ulpm_store_valid_version "$version" || {
        error "Invalid package version: ${version:-<empty>}"
        return 1
    }
    is_arch_compatible "$pkg_arch" || {
        error "Package architecture '$pkg_arch' is not compatible with this system."
        return 1
    }

    digest="$(_ulpm_store_digest "$source")" || return 1
    root="$(_ulpm_store_root)"
    [[ "$root" == /* ]] || {
        error "The system store path must be absolute: $root"
        return 1
    }
    object_final="$root/objects/$digest"

    if [[ -f "$object_final/manifest.json" && -d "$object_final/payload" ]]; then
        info "Package already stored: $id $version (sha256:$digest)"
    else
        install -d -m 0755 "$root/tmp" "$root/objects" "$root/packages" || return 1
        stage="$(mktemp -d "$root/tmp/add.XXXXXX")" || return 1
        extract="$stage/extract"

        if ! unsquashfs -f -no-progress -d "$extract" "$source" >/dev/null 2>&1; then
            rm -rf -- "$stage"
            error "Failed to extract package payload: $source"
            return 1
        fi

        if [[ -d "$extract/root" ]] &&
            _ulpm_store_payload_is_system "$extract/root"; then
            payload="$extract/root"
            payload_mode="root"
        elif _ulpm_store_payload_is_system "$extract"; then
            payload="$extract"
            payload_mode="flat"
        elif [[ -d "$extract/root" ]]; then
            payload="$extract/root"
            payload_mode="root"
        else
            rm -rf -- "$stage"
            error "Package has no payload directory: $source"
            return 1
        fi

        case "$pkg_type" in
            rootfs|os|distro|system) ;;
            "")
                _ulpm_store_payload_is_system "$payload" || {
                    rm -rf -- "$stage"
                    error "Package is not a system package (manifest type is missing)."
                    return 1
                }
                ;;
            *)
                rm -rf -- "$stage"
                error "Package type '$pkg_type' is not a system package."
                return 1
                ;;
        esac
        _ulpm_store_payload_is_system "$payload" || {
            rm -rf -- "$stage"
            error "Package payload does not contain a system tree (etc/, usr/, bin/ or sbin/)."
            return 1
        }
        _ulpm_store_validate_payload "$payload" || {
            rm -rf -- "$stage"
            return 1
        }

        object="$stage/object"
        install -d -m 0755 "$object/payload" || {
            rm -rf -- "$stage"
            return 1
        }
        if [[ "$payload_mode" == "flat" ]]; then
            _ulpm_store_copy_flat_payload "$payload" "$object/payload" || {
                rm -rf -- "$stage"
                error "Failed to stage the package payload."
                return 1
            }
        else
            cp -a -- "$payload/." "$object/payload/" || {
                rm -rf -- "$stage"
                error "Failed to stage the package payload."
                return 1
            }
        fi

        jq -S '.' <<< "$manifest_raw" > "$object/manifest.json" || {
            rm -rf -- "$stage"
            error "Failed to write the stored package manifest."
            return 1
        }
        cp -- "$source" "$object/package.lpk" || {
            rm -rf -- "$stage"
            error "Failed to retain the sealed package."
            return 1
        }
        jq -n \
            --arg id "$id" \
            --arg version "$version" \
            --arg type "$pkg_type" \
            --arg arch "$pkg_arch" \
            --arg digest "$digest" \
            --arg source "$source" \
            --arg imported_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{
                id: $id,
                version: $version,
                type: $type,
                arch: $arch,
                digest: ("sha256:" + $digest),
                source: $source,
                imported_at: $imported_at
            }' > "$object/meta.json" || {
            rm -rf -- "$stage"
            error "Failed to write the store metadata."
            return 1
        }
        (
            cd "$object/payload" &&
                find . -mindepth 1 -printf '%y\t%m\t%s\t%P\n' |
                LC_ALL=C sort
        ) > "$object/files.tsv" || {
            rm -rf -- "$stage"
            error "Failed to index the package payload."
            return 1
        }

        if [[ -e "$object_final" ]]; then
            rm -rf -- "$stage"
            error "Incomplete store object exists: $object_final (remove it and retry)"
            return 1
        fi
        mv -- "$object" "$object_final" || {
            rm -rf -- "$stage"
            error "Failed to commit the store object."
            return 1
        }
        rm -rf -- "$stage"
        sync
        info "Stored system package $id $version (sha256:$digest)"
    fi

    _ulpm_store_link_object "$id" "$version" "$digest" "$replace" || return 1
    sync
    info "Package $id $version is available in the system store."
    return 0
}

cmd_store_list() {
    local root link id version digest object pkg_type count=0
    root="$(_ulpm_store_root)"
    [[ -d "$root/packages" ]] || {
        info "System store is empty: $root"
        return 0
    }

    printf '%-34s %-16s %-8s %s\n' "PACKAGE" "VERSION" "TYPE" "DIGEST"
    while IFS= read -r link; do
        [[ -n "$link" ]] || continue
        id="$(basename -- "$(dirname -- "$link")")"
        version="$(basename -- "$link")"
        digest="$(basename -- "$(readlink -- "$link" 2>/dev/null || true)")"
        object="$root/objects/$digest"
        [[ -f "$object/manifest.json" ]] || continue
        pkg_type="$(jq -r '.type // .kind // "unknown"' "$object/manifest.json" 2>/dev/null || printf 'unknown')"
        printf '%-34s %-16s %-8s %s\n' "$id" "$version" "$pkg_type" "$digest"
        count=$((count + 1))
    done < <(find "$root/packages" -mindepth 2 -maxdepth 2 -type l 2>/dev/null | LC_ALL=C sort)

    (( count > 0 )) || info "System store is empty: $root"
    return 0
}

cmd_store_show() {
    local selector="${1:-}" resolved id version digest object
    [[ -n "$selector" ]] || {
        error "Usage: ulpm store show <id|id=version>"
        return 2
    }
    resolved="$(_ulpm_store_resolve "$selector")" || {
        error "Package not found in the system store: $selector"
        return 1
    }
    IFS=$'\t' read -r id version digest object <<< "$resolved"
    jq -S '.' "$object/manifest.json"
    return 0
}

cmd_store_remove() {
    local selector="" gc=0 id version link count=0
    while (( $# )); do
        case "$1" in
            --gc)
                gc=1
                shift
                ;;
            --)
                shift
                break
                ;;
            -*)
                error "Unknown store remove option: $1"
                return 2
                ;;
            *)
                if [[ -n "$selector" ]]; then
                    error "Usage: ulpm store remove [--gc] <id|id=version>"
                    return 2
                fi
                selector="$1"
                shift
                ;;
        esac
    done
    [[ -n "$selector" ]] || {
        error "Usage: ulpm store remove [--gc] <id|id=version>"
        return 2
    }

    if [[ "$selector" == *=* ]]; then
        id="${selector%%=*}"
        version="${selector#*=}"
        _ulpm_store_valid_id "$id" || { error "Invalid package ID: $id"; return 1; }
        _ulpm_store_valid_version "$version" || { error "Invalid package version: $version"; return 1; }
        link="$(_ulpm_store_package_link "$id" "$version")" || return 1
        if [[ ! -L "$link" ]]; then
            error "Package not found in the system store: $selector"
            return 1
        fi
        rm -f -- "$link" || return 1
        info "Removed store package $id $version"
        count=1
    else
        id="$selector"
        _ulpm_store_valid_id "$id" || { error "Invalid package ID: $id"; return 1; }
        local dir
        dir="$(_ulpm_store_root)/packages/$id"
        [[ -d "$dir" && ! -L "$dir" ]] || {
            error "Package not found in the system store: $id"
            return 1
        }
        while IFS= read -r link; do
            [[ -n "$link" ]] || continue
            version="$(basename -- "$link")"
            rm -f -- "$link" || return 1
            info "Removed store package $id $version"
            count=$((count + 1))
        done < <(find "$dir" -mindepth 1 -maxdepth 1 -type l 2>/dev/null | LC_ALL=C sort)
        rmdir -- "$dir" 2>/dev/null || true
    fi

    (( count > 0 )) || {
        error "Package not found in the system store: $selector"
        return 1
    }
    if (( gc )); then
        cmd_store_gc
    fi
    sync
    return 0
}

cmd_store_gc() {
    local root object digest removed=0 references
    root="$(_ulpm_store_root)"
    [[ -d "$root/objects" ]] || return 0

    references="$(mktemp "${TMPDIR:-/tmp}/ulpm-store-gc.XXXXXX")" || return 1
    if ! _ulpm_store_generation_digests > "$references"; then
        rm -f -- "$references"
        error "Refusing to garbage-collect store objects: generation locks are unreadable."
        return 1
    fi

    while IFS= read -r object; do
        [[ -n "$object" ]] || continue
        digest="$(basename -- "$object")"
        if _ulpm_store_gc_object "$digest" "$references"; then
            removed=$((removed + 1))
        fi
    done < <(find "$root/objects" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    rm -f -- "$references"
    info "Garbage-collected $removed unreferenced object(s)."
    return 0
}

# Checks that a closed set of store packages is present and that every
# dependency is both requested and version-compatible. Selectors use
# <id>=<version>; a bare <id> selects the newest stored version.
cmd_store_verify() {
    local -a req_ids=() req_versions=()
    local selector id version resolved digest object
    local -a deps=()
    local i index index2 count item norm dep_id spec dep_version found
    local split op wanted

    (( $# > 0 )) || {
        info "No packages requested."
        return 0
    }

    for selector in "$@"; do
        resolved="$(_ulpm_store_resolve "$selector")" || {
            error "Package not found in the system store: $selector"
            return 1
        }
        IFS=$'\t' read -r id version digest object <<< "$resolved"
        req_ids+=("$id")
        req_versions+=("$version")
    done

    for ((i = 0; i < ${#req_ids[@]}; i++)); do
        id="${req_ids[$i]}"
        version="${req_versions[$i]}"
        resolved="$(_ulpm_store_resolve "$id=$version")" || {
            error "Package disappeared from the system store: $id $version"
            return 1
        }
        IFS=$'\t' read -r _ _ _ object <<< "$resolved"

        deps=()
        while IFS= read -r item; do
            deps+=("$item")
        done < <(jq -c '.dependencies // [] | .[]' "$object/manifest.json")
        count=${#deps[@]}
        for ((index = 0; index < count; index++)); do
            item="${deps[$index]}"
            norm="$(_deps_normalize_item "$item")" || {
                error "Invalid dependency declaration in $id: $item"
                return 1
            }
            dep_id="${norm%%$'\t'*}"
            spec="${norm#*$'\t'}"
            dep_version=""
            found=0
            for ((index2 = 0; index2 < ${#req_ids[@]}; index2++)); do
                if [[ "${req_ids[$index2]}" == "$dep_id" ]]; then
                    dep_version="${req_versions[$index2]}"
                    found=1
                    break
                fi
            done
            if (( found == 0 )); then
                error "Missing dependency: $dep_id${spec:+ ($spec)} is not part of the requested set."
                return 1
            fi
            if [[ -n "$spec" ]]; then
                split="$(_deps_split_spec "$spec")"
                op="${split%%$'\t'*}"
                wanted="${split#*$'\t'}"
                if ! _deps_compare "$dep_version" "$op" "$wanted"; then
                    error "Dependency version mismatch: $dep_id (requested=$dep_version, required=$spec)"
                    return 1
                fi
            fi
        done
    done

    info "Dependency set is closed and version-compatible (${#req_ids[@]} package(s))."
    return 0
}

cmd_store() {
    local action="${1:-list}"
    [[ $# -gt 0 ]] && shift
    case "$action" in
        add)
            cmd_store_add "$@"
            ;;
        list|ls)
            cmd_store_list "$@"
            ;;
        show|info)
            cmd_store_show "$@"
            ;;
        remove|rm)
            cmd_store_remove "$@"
            ;;
        gc)
            cmd_store_gc "$@"
            ;;
        verify)
            cmd_store_verify "$@"
            ;;
        help|-h|--help)
            cat <<'STORE_HELP'
Usage: ulpm store <command> [options]

Commands:
  add [--replace] <package.lpk>  Verify, extract and index a system LPK
  list                           List packages available in the system store
  show <id|id=version>           Print a stored package manifest
  remove [--gc] <id|id=version>  Remove store links (objects are kept by default)
  gc                             Delete unreferenced store objects
  verify <id=version>...         Check a closed, dependency-complete package set

The system store defaults to /var/lib/bubbleos/store and can be overridden
with ULPM_SYSTEM_STORE. Objects pinned by generation package locks under
ULPM_GENERATIONS_DIR (default /var/lib/bubbleos/rootfs/generations) are kept
regardless of store links. Generation composition is handled by `bubble`.
STORE_HELP
            ;;
        *)
            error "Unknown store command: $action"
            return 2
            ;;
    esac
}
