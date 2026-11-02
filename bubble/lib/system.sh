#!/usr/bin/env bash
# shellcheck shell=bash
# bubbleOS system bootstrap helpers

bubble_system_bootstrap() {
    bubble_require_root || return 1
    bubble_init_paths

    if [[ ! -L "$BUBBLEOS_CURRENT_LINK" ]]; then
        local gen
        gen="$(bubble_generation_create)"
        printf '%s\n' 'bubbleOS bootstrap generation' > \
            "${BUBBLEOS_GENERATIONS_DIR}/${gen}/metadata/description"
        bubble_generation_activate "$gen"
        printf 'Initialized generation %s\n' "$gen"
    else
        printf 'bubbleOS is already initialized (generation %s)\n' \
            "$(bubble_generation_current)"
    fi
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

bubble_system_boot() {
    bubble_require_root || return 1
    bubble_init_paths

    local generation kernel root
    generation="$(bubble_generation_current 2>/dev/null || true)"
    kernel="$(uname -r)"
    root="$(awk '$2 == "/" {print $1; exit}' /proc/mounts)"
    : "${root:=unknown}"

    if [[ -z "$generation" ]]; then
        printf 'bubbleOS: no active generation, boot continues without activation\n' >&2
        return 1
    fi

    printf '%s\n' "$generation" > "$BUBBLEOS_RUN_DIR/current-generation"
    mkdir -p "$BUBBLEOS_STATE_DIR/boot"
    cat > "$BUBBLEOS_STATE_DIR/boot/last" <<BOOT
GENERATION=$generation
KERNEL=$kernel
ROOT=$root
BOOTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BOOT

    printf 'bubbleOS boot: generation %s, kernel %s, root %s\n' \
        "$generation" "$kernel" "$root"
}

bubble_system_status() {
    local current="none" previous="none" boot="not booted" init
    current="$(bubble_generation_current 2>/dev/null || printf 'none')"
    previous="$(bubble_generation_previous 2>/dev/null || printf 'none')"
    if [[ -r "$BUBBLEOS_RUN_DIR/current-generation" ]]; then
        boot="$(< "$BUBBLEOS_RUN_DIR/current-generation")"
    fi
    init="$(bubble_system_init)"

    cat <<STATUS
${BUBBLEOS_NAME}

Version:             ${BUBBLEOS_VERSION}
Status:              ${BUBBLEOS_CHANNEL}
State directory:     ${BUBBLEOS_STATE_DIR}
Current generation:  ${current}
Previous generation: ${previous}
Boot generation:     ${boot}
Init:                ${init}
Architecture:        $(uname -m)
Kernel:              $(uname -r)
ULPM Engine:         $(bubble_ulpm_version 2>/dev/null || printf 'unknown')
LPK Format:          $(bubble_lpk_format_version 2>/dev/null || printf 'unknown')
STATUS
}
