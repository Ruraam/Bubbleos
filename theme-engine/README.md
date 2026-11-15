# BubbleThemeEngine

Standalone Rust library and diagnostic CLI for generating BubbleOS semantic themes from local wallpapers.

## Build

Requires Rust 1.75 or newer.

```sh
cd theme-engine
cargo test --all-targets
cargo build --release
```

## Usage

```sh
cargo run --release -- generate \
  --wallpaper /path/to/wallpaper.jpg \
  --mode dark \
  --personality balanced \
  --output /tmp/bubble-theme.json
```

Without `--output`, the JSON document is written to stdout.

Export its semantic roles as a Waybar GTK CSS stylesheet while retaining the base layout and selectors:

```sh
bubble-theme export-waybar \\
  --theme /tmp/bubble-theme.json \\
  --base-style /usr/share/bubbleos/desktop/waybar/style.css \\
  --output /tmp/bubble-theme-waybar.css
```

## Initial scope

- Local image analysis only; no network access or wallpaper upload.
- Bounded input file size, decoded dimensions and downsampled analysis.
- Deterministic five-cluster OKLab analysis with chroma-aware subject selection.
- Semantic palette generation with balanced, vivid and muted accent personalities.
- Dark and light modes, balanced/vivid/muted palette personalities.
- WCAG contrast calculation and readable foreground selection.
- Versioned JSON output and a GTK CSS color-token adapter for Waybar.
- Independent of GTK, Qt and BubbleWM; the CLI does not run a daemon.

The engine does not watch wallpaper changes, manage preferences, run a daemon, or apply compositor effects. Those belong to later milestones.
