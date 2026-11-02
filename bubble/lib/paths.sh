#!/usr/bin/env bash
# shellcheck shell=bash
# bubbleOS system paths

: "${BUBBLEOS_NAME:=bubbleOS}"
: "${BUBBLEOS_VERSION:=0.0.1-dev}"
: "${BUBBLEOS_STATE_DIR:=/var/lib/bubbleos}"
: "${BUBBLEOS_CONFIG_DIR:=/etc/bubbleos}"
: "${BUBBLEOS_CACHE_DIR:=/var/cache/bubbleos}"
: "${BUBBLEOS_RUN_DIR:=/run/bubbleos}"
: "${BUBBLEOS_CHANNEL:=development}"
: "${BUBBLEOS_ULPM_DIR:=/opt/bubbleos/ulpm}"
: "${BUBBLEOS_GENERATIONS_DIR:=${BUBBLEOS_STATE_DIR}/generations}"
: "${BUBBLEOS_CURRENT_LINK:=${BUBBLEOS_STATE_DIR}/current}"
: "${BUBBLEOS_PREVIOUS_LINK:=${BUBBLEOS_STATE_DIR}/previous}"

bubble_require_root() {
    if (( EUID != 0 )); then
        printf 'bubble: this operation requires root privileges\n' >&2
        return 1
    fi
}

bubble_init_paths() {
    mkdir -p \
        "$BUBBLEOS_STATE_DIR" \
        "$BUBBLEOS_GENERATIONS_DIR" \
        "${BUBBLEOS_STATE_DIR}/transactions" \
        "${BUBBLEOS_STATE_DIR}/store" \
        "${BUBBLEOS_STATE_DIR}/wal" \
        "$BUBBLEOS_CONFIG_DIR" \
        "$BUBBLEOS_CACHE_DIR" \
        "$BUBBLEOS_RUN_DIR"
}
