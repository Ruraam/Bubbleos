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
    local gen
    gen="$(bubble_generation_link_target "$BUBBLEOS_CURRENT_LINK")" || return 1
    [[ -d "$(bubble_generation_path "$gen")" ]] || return 1
    printf '%s\n' "$gen"
}

bubble_generation_previous() {
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
