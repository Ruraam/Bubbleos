# BubbleOS Theme Engine — Architecture & Implementation Plan

**Status:** design baseline (not implemented)  
**Target:** BubbleOS desktop, BubbleWM integration, and native Bubble applications  
**Branch:** `feature/bubble-theme-engine`

## 1. Product direction

BubbleOS uses one coherent visual system with two complementary layers:

- **Material You-inspired dynamic color:** derive a semantic color scheme from the active wallpaper, with explicit user overrides and accessible contrast.
- **Cyberpunk Glass visual language:** dark/translucent surfaces, restrained neon accents, subtle borders, depth, blur and optional glow.

The wallpaper supplies the palette; it must not dictate layout, readability, or contrast. Cyberpunk effects are a presentation layer over semantic theme tokens, not hard-coded colors scattered through applications.

This is a BubbleOS-native system. It must not require GNOME, KDE, GTK, or a specific compositor to exist. Export adapters may target toolkits later.

## 2. Current repository audit

At the time of this design pass, the default branch contains:

- A working BubbleOS system/core CLI under `bubble/`.
- A Debian-derived bootstrap and systemd-based target userspace.
- ULPM/LPK integration and package-category placeholders.
- Documentation for boot, generations and system architecture.

The repository tree does **not** currently contain a desktop toolkit, wallpaper manager, theme engine, appearance settings application, or theme IPC implementation. Therefore this work starts with a clean, separately scoped subsystem. It must not pretend that desktop components already consume theme settings.

BubbleWM lives in its own repository and should remain independently usable. Integration will happen through a documented, versioned interface rather than by coupling the compositor to BubbleOS internals.

## 3. Component boundaries

### BubbleThemeEngine

Owns deterministic theme generation:

- Read the selected wallpaper and detect changes.
- Extract representative colors.
- Generate tonal palettes and semantic roles.
- Resolve light/dark/system modes and user overrides.
- Validate contrast and provide safe fallback palettes.
- Publish a versioned theme document.

It should initially be a reusable library plus a small diagnostic CLI. A long-running daemon is only justified when wallpaper watching and live theme distribution are implemented.

### BubbleThemeService

Owns the active per-user theme state and distribution:

- Track the active wallpaper and theme profile.
- Expose read/apply/preview/reset operations.
- Notify clients when the theme revision changes.
- Persist user preferences in XDG configuration directories.
- Keep generated/cache data under XDG cache directories.

The service must run unprivileged in the logged-in user's session. No root daemon is needed for appearance settings.

### BubbleAppearance

A future settings application that edits profiles and previews changes. It is a client of the service, not the owner of theme generation.

### BubbleGlass / compositor integration

Glass effects are not equivalent to alpha transparency. Correct backdrop blur requires compositor support and a controlled rendering path. BubbleWM should expose capabilities and effect settings; applications must gracefully fall back to translucent solid surfaces when blur is unavailable or disabled.

## 4. Theme pipeline

1. Wallpaper selection supplies a local file path and a change event.
2. Validate file type, size and decode limits before processing.
3. Downsample for analysis; do not keep a full-resolution image in memory.
4. Extract and rank candidate colors, avoiding near-neutral or low-information palettes when possible.
5. Generate tonal palettes and semantic roles.
6. Apply user-selected mode, accent policy, saturation and contrast preferences.
7. Validate text/icon contrast; adjust roles when required.
8. Write an atomic, versioned theme document.
9. Notify subscribers; clients update without restarting where supported.

Generation must be deterministic for the same image and settings. A failed decode must preserve the last known-good theme.

## 5. Semantic token model

Applications consume semantic roles, never wallpaper RGB values directly.

The initial schema should include:

- `primary`, `on_primary`, `primary_container`, `on_primary_container`
- `secondary`, `on_secondary`, `secondary_container`, `on_secondary_container`
- `tertiary`, `on_tertiary`, `tertiary_container`, `on_tertiary_container`
- `background`, `on_background`
- `surface`, `on_surface`, `surface_variant`, `on_surface_variant`
- `surface_elevated`, `surface_overlay`, `outline`, `outline_variant`
- `error`, `on_error`, `success`, `warning`, `info`
- Glass tokens: `glass_tint`, `glass_opacity`, `glass_border`, `glass_highlight`, `glass_shadow`
- Accent tokens: `neon_cyan`, `neon_magenta`, `neon_violet`, `neon_lime`

Neon colors are optional accents for highlights, focus, active states and visualization. They must not replace semantic foreground/background roles or be used for long body text.

The theme document must carry a schema version, revision, generation timestamp, source identifier (not the entire wallpaper), mode, palette source and capability-independent semantic values.

## 6. Appearance preferences

Initial user preference model:

- Color source: wallpaper / built-in palette / custom accent.
- Color mode: system / dark / light.
- Dynamic palette: enabled / disabled.
- Palette personality: balanced / vivid / muted.
- Glass: enabled / disabled.
- Blur: off / low / medium / high (subject to compositor capabilities).
- Glass opacity and border intensity.
- Neon accent intensity.
- Animation and glow intensity.
- Contrast preference and reduced-transparency mode.
- Per-display wallpaper support as a later capability.

Defaults should be restrained: dark surfaces, wallpaper-derived primary color, subtle cyan/violet/magenta accents, modest opacity and no excessive glow.

## 7. Glass rendering contract

The theme service publishes desired effect tokens; it does not claim that every client can render them.

The compositor advertises capabilities such as:

- backdrop blur available;
- blur radius range;
- per-surface opacity;
- shadow/effect support;
- reduced-effects mode.

If blur is unavailable, use an opaque or translucent surface with a border and tonal separation. Never make text contrast depend on blur being active.

Performance policy must account for low-end and older GPUs: disable expensive blur/glow by default on constrained hardware, allow the user to force effects, and provide a global reduced-effects switch. Avoid full-screen blur passes when a local clipped region is sufficient.

## 8. IPC and persistence

Use a versioned, per-user interface. Prefer the existing desktop session bus if the desktop stack already guarantees it; otherwise use a private Unix socket with strict ownership and permissions. Do not introduce a privileged system service.

Minimum operations:

- `GetTheme`
- `GetPreferences`
- `SetPreferences`
- `PreviewTheme`
- `ApplyPreview`
- `CancelPreview`
- `ResetTheme`
- `GetCapabilities`

Notifications include a monotonically increasing revision. Clients must tolerate unknown optional fields and unsupported schema minor versions.

Suggested paths:

- Preferences: `$XDG_CONFIG_HOME/bubbleos/appearance/`
- Active generated theme: `$XDG_CACHE_HOME/bubbleos/theme/`
- Runtime IPC: `$XDG_RUNTIME_DIR/bubbleos/`

Writes must be atomic (temporary file + fsync + rename), validate before activation, and preserve the last known-good theme.

## 9. Toolkit and compositor adapters

The canonical theme is toolkit-neutral JSON. Future adapters may generate:

- GTK CSS / GTK settings;
- Qt palette and QSS;
- BubbleWM decoration and panel tokens;
- BubbleOS-native application tokens;
- command-line output for scripts and diagnostics.

Adapters are consumers, not sources of truth. They must not independently extract wallpaper colors.

BubbleWM remains a separate project. Its integration should be an optional client of the documented theme protocol, with capability negotiation and a safe default palette when BubbleOS services are absent.

## 10. Security, privacy and robustness

- Process only local wallpaper files selected by the user or trusted desktop settings.
- Do not upload wallpapers or send image contents to external services.
- Enforce image dimensions, pixel-count and decode-memory limits.
- Treat malformed preferences and theme documents as untrusted input.
- Never execute commands or load code from theme files.
- Avoid following arbitrary symlinks outside the selected wallpaper path where feasible.
- Do not fail the desktop session if the theme service crashes.
- Keep a built-in high-contrast fallback and allow manual reset from a CLI.

## 11. Test strategy

Unit tests:

- palette generation determinism;
- neutral, monochrome, saturated and dark wallpapers;
- malformed and unsupported images;
- extreme dimensions and decode failures;
- light/dark semantic role mapping;
- contrast validation;
- preference validation and migration;
- atomic persistence and recovery from truncated files;
- unknown optional fields and schema compatibility.

Integration tests:

- wallpaper change -> new revision;
- service restart -> last known-good theme restored;
- client reconnect -> current theme received;
- preview -> apply/cancel;
- compositor without blur -> correct fallback;
- missing service -> BubbleWM and applications retain usable defaults.

Visual acceptance:

- bright, dark, monochrome and highly saturated wallpapers;
- light and dark modes;
- low-resolution displays;
- reduced-transparency and high-contrast modes;
- low-end GPU performance.

## 12. Implementation milestones

1. **Theme schema and palette engine** — standalone library, fixtures and tests.
2. **Theme CLI** — inspect wallpaper, generate preview tokens, validate schema.
3. **Theme service** — per-user persistence, notifications and preview lifecycle.
4. **BubbleAppearance** — user-facing settings and live preview.
5. **BubbleWM adapter** — wallpaper-derived decoration/panel tokens and effect capability negotiation.
6. **Glass rendering** — compositor-side blur/effects, with graceful fallback.
7. **Toolkit adapters** — GTK/Qt/native app integration.
8. **Packaging** — ULPM/LPK packages and BubbleOS image integration.

## 13. Non-goals for the first milestone

- Replacing BubbleWM or merging its source into BubbleOS.
- Implementing a full compositor blur engine inside the theme service.
- Forcing GTK or Qt as the only application toolkit.
- Depending on a cloud color extraction service.
- Adding a theme daemon that runs as root.
- Enabling blur/glow by default without performance and accessibility tests.

## 14. Definition of done for milestone 1

- A standalone theme library can generate deterministic semantic tokens from local wallpaper fixtures.
- Invalid images cannot destroy the current theme.
- Light/dark palettes meet the project's documented contrast targets.
- The schema is versioned and documented.
- Unit tests cover palette, fallback and preference behavior.
- No changes are made to boot, initramfs, generation activation or ULPM runtime paths.
