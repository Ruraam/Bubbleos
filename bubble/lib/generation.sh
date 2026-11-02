#!/usr/bin/env bash
# shellcheck shell=bash
# bubbleOS generation management (initial scaffold)

bubble_generation_exists() {
    [[ -d "${BUBBLEOS_GENERATIONS_DIR}/${1}" ]]
}

bubble_generation_current() {
    [[ -L "$BUBBLEOS_CURRENT_LINK" ]] || return 1
    basename "$(readlink -f "$BUBBLEOS_CURRENT_LINK")"
}

bubble_generation_previous() {
    [[ -L "$BUBBLEOS_PREVIOUS_LINK" ]] || return 1
    basename "$(readlink -f "$BUBBLEOS_PREVIOUS_LINK")"
}

bubble_generation_next() {
    local last=0 d n
    shopt -s nullglob
    for d in "$BUBBLEOS_GENERATIONS_DIR"/*; do
        [[ -d "$d" ]] || continue
        n="$(basename "$d")"
        [[ "$n" =~ ^[0-9]+$ ]] || continue
        (( 10#$n > last )) && last=$((10#$n))
    done
    printf '%06d\n' "$((last + 1))"
}

bubble_generation_create() {
    local gen
    gen="$(bubble_generation_next)"
    mkdir -p "${BUBBLEOS_GENERATIONS_DIR}/${gen}"/{root,metadata}
    printf '%s\n' "$gen"
}

bubble_generation_activate() {
    local gen="$1" current_target
    bubble_generation_exists "$gen" || {
        printf 'bubble: generation %s does not exist\n' "$gen" >&2
        return 1
    }

    if [[ -L "$BUBBLEOS_CURRENT_LINK" ]]; then
        current_target="$(readlink -f "$BUBBLEOS_CURRENT_LINK")"
        ln -sfn "$current_target" "$BUBBLEOS_PREVIOUS_LINK"
    fi

    ln -sfn "${BUBBLEOS_GENERATIONS_DIR}/${gen}" "$BUBBLEOS_CURRENT_LINK"
}

bubble_generation_list() {
    local d
    shopt -s nullglob
    for d in "$BUBBLEOS_GENERATIONS_DIR"/*; do
        [[ -d "$d" ]] || continue
        basename "$d"
    done | sort -n
}
