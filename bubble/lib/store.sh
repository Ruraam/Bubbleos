#!/usr/bin/env bash
# shellcheck shell=bash
# bubbleOS system package store helpers
#
# ULPM owns package verification and extraction (ulpm store). The bubbleOS
# core resolves store objects and composes them into generations.

bubble_store_ulpm() {
    local ulpm="${BUBBLEOS_ULPM_DIR}/bin/ulpm"
    [[ -x "$ulpm" ]] || {
        printf 'bubble: ULPM is not available at %s\n' "$ulpm" >&2
        return 1
    }
    ULPM_GENERATIONS_DIR="${ULPM_GENERATIONS_DIR:-$BUBBLEOS_GENERATIONS_DIR}" \
        "$ulpm" store "$@"
}

# Import and inspect packages with the persistent system ULPM environment.
# Repository payloads are signed by publisher keys stored there, so they must
# be verified against the system trust store rather than the caller's HOME.
bubble_store_ulpm_system() {
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
        "$ulpm" store "$@"
}

bubble_store_require() {
    command -v jq >/dev/null 2>&1 || {
        printf 'bubble: jq is required for the package store\n' >&2
        return 1
    }
    command -v sha256sum >/dev/null 2>&1 || {
        printf 'bubble: sha256sum is required for the package store\n' >&2
        return 1
    }
    [[ -d "$BUBBLEOS_STORE_DIR" ]] || {
        printf 'bubble: system store is missing: %s\n' "$BUBBLEOS_STORE_DIR" >&2
        return 1
    }
}

bubble_store_object_dir() {
    local digest="${1:-}"
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s/%s\n' "$BUBBLEOS_STORE_OBJECTS_DIR" "$digest"
}

bubble_store_object_manifest() {
    local digest="${1:-}" object
    object="$(bubble_store_object_dir "$digest")" || return 1
    [[ -f "$object/manifest.json" ]] || return 1
    printf '%s/manifest.json\n' "$object"
}

bubble_store_latest_version() {
    local id="${1:-}" dir
    [[ -n "$id" && "$id" != */* && "$id" != *..* ]] || return 1
    dir="$BUBBLEOS_STORE_PACKAGES_DIR/$id"
    [[ -d "$dir" && ! -L "$dir" ]] || return 1
    find "$dir" -mindepth 1 -maxdepth 1 -type l -printf '%f\n' 2>/dev/null |
        LC_ALL=C sort -V |
        tail -n1
}

# bubble_store_info_for_id <id|id=version>
# Prints: id<TAB>version<TAB>type<TAB>name<TAB>digest
bubble_store_info_for_id() {
    local selector="${1:-}" id version link digest object
    [[ -n "$selector" ]] || return 1
    if [[ "$selector" == *=* ]]; then
        id="${selector%%=*}"
        version="${selector#*=}"
    else
        id="$selector"
        version="$(bubble_store_latest_version "$id")" || {
            printf 'bubble: package is not in the system store: %s\n' "$id" >&2
            return 1
        }
    fi
    [[ -n "$id" && "$id" != */* && "$id" != *..* ]] || {
        printf 'bubble: invalid package id: %s\n' "$id" >&2
        return 1
    }
    [[ -n "$version" && "$version" != */* ]] || {
        printf 'bubble: invalid package version: %s\n' "$version" >&2
        return 1
    }

    link="$BUBBLEOS_STORE_PACKAGES_DIR/$id/$version"
    [[ -L "$link" ]] || {
        printf 'bubble: package is not in the system store: %s %s\n' \
            "$id" "$version" >&2
        return 1
    }
    digest="$(basename -- "$(readlink -- "$link")")" || return 1
    object="$(bubble_store_object_dir "$digest")" || {
        printf 'bubble: invalid store object for %s %s\n' "$id" "$version" >&2
        return 1
    }
    [[ -f "$object/manifest.json" && -d "$object/payload" ]] || {
        printf 'bubble: store object is incomplete: %s\n' "$object" >&2
        return 1
    }

    jq -r --arg digest "$digest" '
        [.id, .version, (.type // .kind // "system"), (.name // .id), $digest] |
        @tsv
    ' "$object/manifest.json"
}

# bubble_store_info_for_file <package.lpk>
# Prints the same fields after the package has been imported.
bubble_store_info_for_file() {
    local file="${1:-}" digest object
    [[ -f "$file" && -r "$file" && ! -L "$file" ]] || return 1
    digest="$(sha256sum -- "$file" | awk '{print $1}')" || return 1
    object="$(bubble_store_object_dir "$digest")" || return 1
    [[ -f "$object/manifest.json" && -d "$object/payload" ]] || {
        printf 'bubble: package was not imported into the store: %s\n' "$file" >&2
        return 1
    }
    jq -r --arg digest "$digest" '
        [.id, .version, (.type // .kind // "system"), (.name // .id), $digest] |
        @tsv
    ' "$object/manifest.json"
}
