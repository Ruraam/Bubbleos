#!/usr/bin/env bash
# shellcheck shell=bash
# bubbleOS system bootstrap and boot integration

bubble_system_bootstrap() {
    bubble_require_root || return 1
    bubble_init_paths

    # This runs inside the build chroot, before the Btrfs subvolume layout
    # exists. Real generation 000001 is created by build/build-image.sh.
    printf 'bubbleOS rootfs template initialized at %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$BUBBLEOS_STATE_DIR/bootstrap"
    printf 'Initialized bubbleOS state template\n'
}

bubble_ulpm_version() {
    local entry="${BUBBLEOS_ULPM_DIR}/bin/ulpm" value
    [[ -r "$entry" ]] || return 1
    value="$(sed -n 's/^export ULPM_VERSION="\(.*\)"$/\1/p' "$entry" | head -n1)"
    [[ -n "$value" ]] || return 1
    printf '%s\n' "$value"
}

bubble_lpk_format_version() {
    local entry="${BUBBLEOS_ULPM_DIR}/bin/ulpm" value
    [[ -r "$entry" ]] || return 1
    value="$(sed -n 's/^export ULPM_FORMAT_VERSION="\(.*\)"$/\1/p' "$entry" | head -n1)"
    [[ -n "$value" ]] || return 1
    printf '%s\n' "$value"
}

bubble_system_init() {
    local version
    if [[ -x /usr/bin/systemctl ]]; then
        version="$(systemctl --version 2>/dev/null | awk 'NR == 1 {print $2}')"
        printf 'systemd %s\n' "${version:-unknown}"
    elif [[ -x /sbin/init ]]; then
        printf 'development init\n'
    else
        printf 'unknown\n'
    fi
}

bubble_system_root_subvol() {
    local options
    options="$(findmnt -no OPTIONS / 2>/dev/null || true)"
    printf '%s\n' "$options" |
        tr ',' '\n' |
        sed -n 's|^subvol=/*||p' |
        head -n1
}

bubble_system_root_fstype() {
    findmnt -no FSTYPE / 2>/dev/null || true
}

bubble_system_boot() {
    bubble_require_root || return 1
    bubble_init_paths

    local generation selected mounted kernel root root_subvol root_fstype
    selected="$(bubble_generation_current 2>/dev/null || true)"
    generation="$selected"
    mounted="$(sed -n 's/^GENERATION=//p' /etc/bubbleos/generation 2>/dev/null | head -n1)"
    [[ -z "$mounted" ]] || generation="$mounted"
    kernel="$(uname -r)"
    root="$(awk '$2 == "/" {print $1; exit}' /proc/mounts)"
    : "${root:=unknown}"
    root_subvol="$(bubble_system_root_subvol)"
    root_fstype="$(bubble_system_root_fstype)"

    if [[ -z "$generation" ]]; then
        printf 'bubbleOS: no active generation, boot continues without activation\n' >&2
        return 1
    fi
    if [[ -n "$selected" && -n "$mounted" && "$selected" != "$mounted" ]]; then
        printf 'bubbleOS: warning: current selects %s but generation %s is mounted\n' \
            "$selected" "$mounted" >&2
    fi

    printf '%s\n' "$generation" > "$BUBBLEOS_RUN_DIR/current-generation"
    if [[ -n "$selected" ]]; then
        printf '%s\n' "$selected" > "$BUBBLEOS_RUN_DIR/selected-generation"
    fi
    mkdir -p "$BUBBLEOS_STATE_DIR/boot"
    cat > "$BUBBLEOS_STATE_DIR/boot/last" <<BOOT
GENERATION=$generation
SELECTED_GENERATION=$selected
KERNEL=$kernel
ROOT=$root
ROOT_SUBVOL=$root_subvol
ROOT_FSTYPE=$root_fstype
BOOTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BOOT

    printf 'bubbleOS boot: generation %s, root %s (%s, subvol %s)\n' \
        "$generation" "$root" "${root_fstype:-unknown}" "${root_subvol:-unknown}"
}

bubble_system_status() {
    local current="none" previous="none" boot="not booted" init root_fstype root_subvol snapshots
    current="$(bubble_generation_current 2>/dev/null || printf 'none')"
    previous="$(bubble_generation_previous 2>/dev/null || printf 'none')"
    if [[ -r "$BUBBLEOS_RUN_DIR/current-generation" ]]; then
        boot="$(< "$BUBBLEOS_RUN_DIR/current-generation")"
    fi
    init="$(bubble_system_init)"
    root_fstype="$(bubble_system_root_fstype)"
    : "${root_fstype:=unknown}"
    root_subvol="$(bubble_system_root_subvol)"
    : "${root_subvol:=unknown}"
    if mountpoint -q "$BUBBLEOS_SNAPSHOTS_DIR"; then
        snapshots="mounted"
    else
        snapshots="not mounted"
    fi

    cat <<STATUS
${BUBBLEOS_NAME}

Version:             ${BUBBLEOS_VERSION}
Status:              ${BUBBLEOS_CHANNEL}
State directory:     ${BUBBLEOS_STATE_DIR}
Rootfs container:    ${BUBBLEOS_ROOTFS_MOUNT}
Current generation:  ${current}
Previous generation: ${previous}
Boot generation:     ${boot}
Root filesystem:     ${root_fstype}
Root subvolume:      ${root_subvol}
Snapshots:           ${BUBBLEOS_SNAPSHOTS_DIR} (${snapshots})
Init:                ${init}
Architecture:        $(uname -m)
Kernel:              $(uname -r)
ULPM Engine:         $(bubble_ulpm_version 2>/dev/null || printf 'unknown')
LPK Format:          $(bubble_lpk_format_version 2>/dev/null || printf 'unknown')
STATUS
}
