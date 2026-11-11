#!/usr/bin/env bash
# ==============================================================================
# bubbleOS - prune runtime data that is not used by the image
# ==============================================================================
# Keeps the configured desktop theme/cursor, French and English translations,
# firmware, kernel modules and recovery tools.  Removes the unused icon and
# cursor variants pulled in by the Debian theme packages, other translations,
# man/info pages when no reader is installed, gprofng and non-French GTK emoji
# data.
#
# Usage:
#   sudo build/prune-rootfs.sh [ROOTFS]
#   sudo DRY_RUN=1 build/prune-rootfs.sh [ROOTFS]
# ==============================================================================
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ROOTFS="${1:-${ROOTFS:-$ROOT/out/rootfs}}"
DRY_RUN="${DRY_RUN:-0}"

log() { printf '[bubbleOS] %s\n' "$*"; }
die() { printf '[bubbleOS] ERROR: %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] ||
    die "Run this script as root (or via sudo)."
[[ -n "$ROOTFS" && "$ROOTFS" != "/" ]] ||
    die "Refusing to prune '$ROOTFS'"
[[ -d "$ROOTFS" ]] || die "RootFS not found: $ROOTFS"
[[ -f "$ROOTFS/etc/os-release" && -f "$ROOTFS/etc/bubbleos/desktop.conf" ]] ||
    die "Not a bubbleOS RootFS: $ROOTFS"

removed_bytes=0

config_value() {
    local key="$1" default="$2" value
    value="$(sed -n "s/^${key}=//p" "$ROOTFS/etc/bubbleos/desktop.conf" |
        tail -n 1)"
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"
    printf '%s' "${value:-$default}"
}

remove_path() {
    local path="$1" reason="$2" size
    [[ -e "$path" || -L "$path" ]] || return 0

    size="$(du -s --block-size=1 -- "$path" 2>/dev/null | cut -f1)"
    size="${size:-0}"
    removed_bytes=$((removed_bytes + size))

    if [[ "$DRY_RUN" == "1" ]]; then
        log "would remove $(numfmt --to=iec --suffix=B "$size")  ${path#"$ROOTFS"} ($reason)"
    else
        log "removing $(numfmt --to=iec --suffix=B "$size")  ${path#"$ROOTFS"} ($reason)"
        rm -rf --one-file-system -- "$path"
    fi
}

icon_theme="$(config_value DESKTOP_ICON_THEME Papirus-Dark)"
cursor_theme="$(config_value DESKTOP_CURSOR_THEME Bibata-Modern-Ice)"

for name in "$icon_theme" "$cursor_theme"; do
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] ||
        die "invalid desktop theme name: $name"
done

log "Keeping icon theme '$icon_theme' and cursor theme '$cursor_theme'"

# ------------------------------------------------------------------------------
# Icon and cursor themes
# ------------------------------------------------------------------------------
icons_dir="$ROOTFS/usr/share/icons"
if [[ -d "$icons_dir" ]]; then
    shopt -s nullglob
    for theme_dir in "$icons_dir"/*; do
        [[ -d "$theme_dir" ]] || continue
        theme="$(basename "$theme_dir")"
        case "$theme" in
            Adwaita|hicolor|default|"$icon_theme"|"$cursor_theme")
                continue
                ;;
        esac
        remove_path "$theme_dir" "unused icon/cursor theme"
    done
    shopt -u nullglob
fi

# ------------------------------------------------------------------------------
# Translations
# ------------------------------------------------------------------------------
locales_dir="$ROOTFS/usr/share/locale"
if [[ -d "$locales_dir" ]]; then
    while IFS= read -r -d '' locale_dir; do
        locale="$(basename "$locale_dir")"
        case "$locale" in
            fr|fr_*|fr@*|en|en_*|en@*)
                continue
                ;;
        esac
        remove_path "$locale_dir" "unused translation"
    done < <(find "$locales_dir" -mindepth 1 -maxdepth 1 -type d -print0)
fi

# ------------------------------------------------------------------------------
# Manual and info pages
# ------------------------------------------------------------------------------
if [[ ! -x "$ROOTFS/usr/bin/man" ]]; then
    remove_path "$ROOTFS/usr/share/man" "no man reader installed"
fi
if [[ ! -x "$ROOTFS/usr/bin/info" ]]; then
    remove_path "$ROOTFS/usr/share/info" "no info reader installed"
fi

# ------------------------------------------------------------------------------
# GTK emoji picker translations (the font and default data stay)
# ------------------------------------------------------------------------------
for version in 3.0 4.0; do
    emoji_dir="$ROOTFS/usr/share/gtk-$version/emoji"
    [[ -d "$emoji_dir" ]] || continue
    while IFS= read -r -d '' emoji_file; do
        remove_path "$emoji_file" "unused GTK emoji translation"
    done < <(find "$emoji_dir" -mindepth 1 -maxdepth 1 -type f \
        ! -name 'fr.gresource' -print0)
done

# ------------------------------------------------------------------------------
# Profiling tooling from binutils (readelf and ar stay for ULPM)
# ------------------------------------------------------------------------------
shopt -s nullglob
gprofng_paths=(
    "$ROOTFS/usr/lib/x86_64-linux-gnu/gprofng"
    "$ROOTFS"/usr/lib/x86_64-linux-gnu/libgprofng.so*
    "$ROOTFS"/usr/bin/gprofng*
    "$ROOTFS/etc/gprofng.rc"
)
shopt -u nullglob
for path in "${gprofng_paths[@]}"; do
    remove_path "$path" "gprofng profiling tooling"
done

if [[ "$DRY_RUN" == "1" ]]; then
    log "dry run: $(numfmt --to=iec --suffix=B "$removed_bytes") would be removed"
else
    log "pruned $(numfmt --to=iec --suffix=B "$removed_bytes") from $ROOTFS"
fi
