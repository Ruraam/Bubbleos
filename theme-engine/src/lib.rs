//! BubbleOS wallpaper-driven semantic theme generation.
//!
//! This crate is deliberately independent of any toolkit or compositor. It
//! turns a local image into a stable, versioned set of semantic color tokens.

use image::{DynamicImage, GenericImageView, ImageReader, Limits};
use serde::{Deserialize, Serialize};
use std::path::Path;
use thiserror::Error;

pub const SCHEMA_VERSION: u32 = 1;
const ANALYSIS_EDGE: u32 = 128;
const MAX_IMAGE_EDGE: u32 = 16_384;
const MAX_IMAGE_BYTES: u64 = 64 * 1024 * 1024;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ColorMode {
    Dark,
    Light,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum PalettePersonality {
    Balanced,
    Vivid,
    Muted,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ThemeOptions {
    pub mode: ColorMode,
    pub personality: PalettePersonality,
    /// Minimum WCAG contrast ratio for ordinary text.
    pub contrast_target: f32,
}

impl Default for ThemeOptions {
    fn default() -> Self {
        Self {
            mode: ColorMode::Dark,
            personality: PalettePersonality::Balanced,
            contrast_target: 4.5,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ThemeColors {
    pub primary: String,
    pub on_primary: String,
    pub primary_container: String,
    pub on_primary_container: String,
    pub secondary: String,
    pub on_secondary: String,
    pub secondary_container: String,
    pub on_secondary_container: String,
    pub tertiary: String,
    pub on_tertiary: String,
    pub tertiary_container: String,
    pub on_tertiary_container: String,
    pub background: String,
    pub on_background: String,
    pub surface: String,
    pub on_surface: String,
    pub surface_variant: String,
    pub on_surface_variant: String,
    pub surface_elevated: String,
    pub surface_overlay: String,
    pub outline: String,
    pub outline_variant: String,
    pub error: String,
    pub on_error: String,
    pub success: String,
    pub warning: String,
    pub info: String,
    pub glass_tint: String,
    pub glass_opacity: f32,
    pub glass_border: String,
    pub glass_highlight: String,
    pub glass_shadow: String,
    pub neon_cyan: String,
    pub neon_magenta: String,
    pub neon_violet: String,
    pub neon_lime: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ThemeDocument {
    pub schema_version: u32,
    pub revision: u64,
    pub generated_at_unix: u64,
    pub source: ThemeSource,
    pub mode: ColorMode,
    pub personality: PalettePersonality,
    pub contrast_target: f32,
    pub colors: ThemeColors,
    pub diagnostics: ThemeDiagnostics,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ThemeSource {
    pub kind: String,
    pub file_name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ThemeDiagnostics {
    pub sampled_pixels: usize,
    pub dominant_color: String,
    pub achieved_text_contrast: f32,
}

#[derive(Debug, Error)]
pub enum ThemeError {
    #[error("cannot read wallpaper: {0}")]
    Io(#[from] std::io::Error),
    #[error("unsupported or invalid image: {0}")]
    Image(#[from] image::ImageError),
    #[error("wallpaper file exceeds the 64 MiB input limit")]
    FileTooLarge,
    #[error("image dimensions exceed the configured 16384 px edge limit")]
    ImageTooLarge,
    #[error("contrast target must be between 4.5 and 7.0")]
    InvalidContrastTarget,
    #[error("image contains no usable color samples")]
    NoColorSamples,
}

/// Generate a theme from a local wallpaper path.
pub fn generate_from_path(
    path: impl AsRef<Path>,
    options: &ThemeOptions,
) -> Result<ThemeDocument, ThemeError> {
    validate_options(options)?;
    let path = path.as_ref();
    let metadata = std::fs::metadata(path)?;
    if metadata.len() > MAX_IMAGE_BYTES {
        return Err(ThemeError::FileTooLarge);
    }

    let mut limits = Limits::default();
    limits.max_image_width = Some(MAX_IMAGE_EDGE);
    limits.max_image_height = Some(MAX_IMAGE_EDGE);
    limits.max_alloc = Some(256 * 1024 * 1024);
    let mut reader = ImageReader::open(path)?.with_guessed_format()?;
    reader.limits(limits);
    let image = reader.decode()?;

    generate_from_image(
        &image,
        options,
        path.file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("wallpaper"),
    )
}

/// Generate a deterministic theme from an already decoded image.
pub fn generate_from_image(
    image: &DynamicImage,
    options: &ThemeOptions,
    source_name: &str,
) -> Result<ThemeDocument, ThemeError> {
    validate_options(options)?;
    let (width, height) = image.dimensions();
    if width > MAX_IMAGE_EDGE || height > MAX_IMAGE_EDGE {
        return Err(ThemeError::ImageTooLarge);
    }

    let sample = image.thumbnail(ANALYSIS_EDGE, ANALYSIS_EDGE).to_rgb8();
    let pixels: Vec<(u8, u8, u8)> = sample
        .pixels()
        .map(|pixel| (pixel[0], pixel[1], pixel[2]))
        .collect();
    let sampled_pixels = pixels.len();
    let dominant = dominant_color(&pixels).ok_or(ThemeError::NoColorSamples)?;
    let mut base = Hsl::from_rgb(dominant);
    if base.s < 0.08 {
        // A grayscale wallpaper has no hue to preserve; use a calm cyan-blue
        // seed rather than letting floating-point hue noise pick an accent.
        base.h = 195.0;
        base.s = 0.52;
    } else {
        base.s = match options.personality {
            PalettePersonality::Balanced => base.s.clamp(0.42, 0.72),
            PalettePersonality::Vivid => base.s.clamp(0.68, 0.92),
            PalettePersonality::Muted => base.s.clamp(0.24, 0.48),
        };
    }

    let colors = build_colors(base, options);
    let achieved = contrast_ratio(
        parse_hex(&colors.on_surface).expect("generated hex color"),
        parse_hex(&colors.surface).expect("generated hex color"),
    );

    Ok(ThemeDocument {
        schema_version: SCHEMA_VERSION,
        revision: 1,
        generated_at_unix: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs(),
        source: ThemeSource {
            kind: "wallpaper".into(),
            file_name: source_name.to_owned(),
        },
        mode: options.mode,
        personality: options.personality,
        contrast_target: options.contrast_target,
        colors,
        diagnostics: ThemeDiagnostics {
            sampled_pixels,
            dominant_color: hex(dominant),
            achieved_text_contrast: achieved,
        },
    })
}

/// Deterministic, bounded k-means clustering in RGB space. Farthest-point
/// seeding avoids random initialization and keeps output stable across runs.
fn dominant_color(pixels: &[(u8, u8, u8)]) -> Option<(u8, u8, u8)> {
    const CLUSTERS: usize = 5;
    const ITERATIONS: usize = 8;

    if pixels.is_empty() {
        return None;
    }

    let to_f32 = |(r, g, b): (u8, u8, u8)| [r as f32, g as f32, b as f32];
    let distance = |a: [f32; 3], b: [f32; 3]| {
        (a[0] - b[0]).powi(2) + (a[1] - b[1]).powi(2) + (a[2] - b[2]).powi(2)
    };
    let points: Vec<[f32; 3]> = pixels.iter().copied().map(to_f32).collect();

    // Start from the most chromatic sample, then repeatedly choose the point
    // farthest from its nearest existing center.
    let first = pixels
        .iter()
        .enumerate()
        .max_by(|(ia, a), (ib, b)| {
            let sa = Hsl::from_rgb(**a).s;
            let sb = Hsl::from_rgb(**b).s;
            sa.total_cmp(&sb).then_with(|| ib.cmp(ia))
        })?
        .0;
    let mut centers = vec![points[first]];

    while centers.len() < CLUSTERS.min(points.len()) {
        let next = points
            .iter()
            .enumerate()
            .map(|(index, point)| {
                let nearest = centers
                    .iter()
                    .map(|center| distance(*point, *center))
                    .fold(f32::INFINITY, f32::min);
                (index, nearest)
            })
            .max_by(|(ia, da), (ib, db)| da.total_cmp(db).then_with(|| ib.cmp(ia)))?
            .0;
        if centers
            .iter()
            .any(|center| distance(*center, points[next]) == 0.0)
        {
            break;
        }
        centers.push(points[next]);
    }

    let mut counts = vec![0usize; centers.len()];
    for _ in 0..ITERATIONS {
        let mut sums = vec![[0.0f64; 3]; centers.len()];
        counts.fill(0);
        for point in &points {
            let nearest = centers
                .iter()
                .enumerate()
                .min_by(|(ia, a), (ib, b)| {
                    distance(*point, **a)
                        .total_cmp(&distance(*point, **b))
                        .then_with(|| ia.cmp(ib))
                })?
                .0;
            counts[nearest] += 1;
            sums[nearest][0] += point[0] as f64;
            sums[nearest][1] += point[1] as f64;
            sums[nearest][2] += point[2] as f64;
        }
        for (index, count) in counts.iter().copied().enumerate() {
            if count > 0 {
                centers[index] = [
                    (sums[index][0] / count as f64) as f32,
                    (sums[index][1] / count as f64) as f32,
                    (sums[index][2] / count as f64) as f32,
                ];
            }
        }
    }

    // Favor clusters with both meaningful coverage and chroma: a large neutral
    // sky or white border should not automatically erase a colorful subject.
    let best = centers
        .iter()
        .enumerate()
        .filter(|(index, _)| counts[*index] > 0)
        .map(|(index, center)| {
            let rgb = (
                center[0].round().clamp(0.0, 255.0) as u8,
                center[1].round().clamp(0.0, 255.0) as u8,
                center[2].round().clamp(0.0, 255.0) as u8,
            );
            let saturation = Hsl::from_rgb(rgb).s;
            let score = counts[index] as f32 * (0.08 + saturation * 1.6);
            (rgb, score, index)
        })
        .max_by(|a, b| a.1.total_cmp(&b.1).then_with(|| b.2.cmp(&a.2)))?;
    Some(best.0)
}

fn validate_options(options: &ThemeOptions) -> Result<(), ThemeError> {
    if !(4.5..=7.0).contains(&options.contrast_target) {
        return Err(ThemeError::InvalidContrastTarget);
    }
    Ok(())
}

#[derive(Clone, Copy)]
struct Hsl {
    h: f32,
    s: f32,
    l: f32,
}

impl Hsl {
    fn from_rgb((r, g, b): (u8, u8, u8)) -> Self {
        let r = r as f32 / 255.0;
        let g = g as f32 / 255.0;
        let b = b as f32 / 255.0;
        let max = r.max(g).max(b);
        let min = r.min(g).min(b);
        let delta = max - min;
        let l = (max + min) / 2.0;
        if delta == 0.0 {
            return Self { h: 0.0, s: 0.0, l };
        }
        let s = delta / (1.0 - (2.0 * l - 1.0).abs());
        let h = if max == r {
            60.0 * (((g - b) / delta) % 6.0)
        } else if max == g {
            60.0 * ((b - r) / delta + 2.0)
        } else {
            60.0 * ((r - g) / delta + 4.0)
        };
        Self {
            h: h.rem_euclid(360.0),
            s,
            l,
        }
    }

    fn rgb(self) -> (u8, u8, u8) {
        let c = (1.0 - (2.0 * self.l - 1.0).abs()) * self.s;
        let x = c * (1.0 - ((self.h / 60.0).rem_euclid(2.0) - 1.0).abs());
        let m = self.l - c / 2.0;
        let (r, g, b) = match self.h.rem_euclid(360.0) as u32 {
            0..=59 => (c, x, 0.0),
            60..=119 => (x, c, 0.0),
            120..=179 => (0.0, c, x),
            180..=239 => (0.0, x, c),
            240..=299 => (x, 0.0, c),
            _ => (c, 0.0, x),
        };
        (
            ((r + m) * 255.0).round().clamp(0.0, 255.0) as u8,
            ((g + m) * 255.0).round().clamp(0.0, 255.0) as u8,
            ((b + m) * 255.0).round().clamp(0.0, 255.0) as u8,
        )
    }
}

fn build_colors(base: Hsl, options: &ThemeOptions) -> ThemeColors {
    let dark = options.mode == ColorMode::Dark;
    let primary = tone(base, if dark { 0.78 } else { 0.40 });
    let primary_container = tone(base, if dark { 0.30 } else { 0.88 });
    let secondary_hsl = Hsl {
        h: base.h + 36.0,
        s: (base.s * 0.72).clamp(0.25, 0.68),
        l: base.l,
    };
    let tertiary_hsl = Hsl {
        h: base.h + 300.0,
        s: (base.s * 0.82).clamp(0.30, 0.78),
        l: base.l,
    };
    let secondary = tone(secondary_hsl, if dark { 0.76 } else { 0.42 });
    let secondary_container = tone(secondary_hsl, if dark { 0.28 } else { 0.90 });
    let tertiary = tone(tertiary_hsl, if dark { 0.78 } else { 0.40 });
    let tertiary_container = tone(tertiary_hsl, if dark { 0.31 } else { 0.89 });

    let background = if dark { (12, 14, 22) } else { (248, 247, 252) };
    let surface = if dark { (20, 23, 34) } else { (255, 255, 255) };
    let surface_variant = if dark { (39, 43, 58) } else { (231, 229, 239) };
    let on_background = readable_foreground(background, options.contrast_target);
    let on_surface = readable_foreground(surface, options.contrast_target);
    let on_surface_variant = readable_foreground(surface_variant, options.contrast_target);
    let on_primary = readable_foreground(primary, options.contrast_target);
    let on_primary_container = readable_foreground(primary_container, options.contrast_target);
    let on_secondary = readable_foreground(secondary, options.contrast_target);
    let on_secondary_container = readable_foreground(secondary_container, options.contrast_target);
    let on_tertiary = readable_foreground(tertiary, options.contrast_target);
    let on_tertiary_container = readable_foreground(tertiary_container, options.contrast_target);
    let error = (186, 26, 26);
    let success = (46, 160, 105);
    let warning = (210, 143, 25);
    let info = (50, 130, 210);

    ThemeColors {
        primary: hex(primary),
        on_primary: hex(on_primary),
        primary_container: hex(primary_container),
        on_primary_container: hex(on_primary_container),
        secondary: hex(secondary),
        on_secondary: hex(on_secondary),
        secondary_container: hex(secondary_container),
        on_secondary_container: hex(on_secondary_container),
        tertiary: hex(tertiary),
        on_tertiary: hex(on_tertiary),
        tertiary_container: hex(tertiary_container),
        on_tertiary_container: hex(on_tertiary_container),
        background: hex(background),
        on_background: hex(on_background),
        surface: hex(surface),
        on_surface: hex(on_surface),
        surface_variant: hex(surface_variant),
        on_surface_variant: hex(on_surface_variant),
        surface_elevated: hex(if dark { (29, 33, 47) } else { (255, 255, 255) }),
        surface_overlay: hex(if dark { (34, 39, 55) } else { (242, 240, 248) }),
        outline: hex(if dark {
            (143, 147, 164)
        } else {
            (104, 101, 117)
        }),
        outline_variant: hex(if dark { (67, 71, 88) } else { (198, 195, 208) }),
        error: hex(error),
        on_error: hex(readable_foreground(error, options.contrast_target)),
        success: hex(success),
        warning: hex(warning),
        info: hex(info),
        glass_tint: hex(if dark { primary_container } else { primary }),
        glass_opacity: if dark { 0.78 } else { 0.86 },
        glass_border: hex(if dark {
            (95, 105, 133)
        } else {
            (180, 176, 199)
        }),
        glass_highlight: hex(if dark {
            (185, 205, 255)
        } else {
            (255, 255, 255)
        }),
        glass_shadow: hex((0, 0, 0)),
        neon_cyan: hex((45, 225, 235)),
        neon_magenta: hex((245, 65, 190)),
        neon_violet: hex((165, 95, 255)),
        neon_lime: hex((180, 245, 70)),
    }
}

fn tone(mut color: Hsl, lightness: f32) -> (u8, u8, u8) {
    color.l = lightness;
    color.rgb()
}

fn readable_foreground(background: (u8, u8, u8), target: f32) -> (u8, u8, u8) {
    let black = (0, 0, 0);
    let white = (255, 255, 255);
    let black_ratio = contrast_ratio(black, background);
    let white_ratio = contrast_ratio(white, background);
    if black_ratio >= target && black_ratio >= white_ratio {
        black
    } else if white_ratio >= target {
        white
    } else if black_ratio >= white_ratio {
        black
    } else {
        white
    }
}

fn luminance((r, g, b): (u8, u8, u8)) -> f32 {
    fn channel(v: u8) -> f32 {
        let c = v as f32 / 255.0;
        if c <= 0.04045 {
            c / 12.92
        } else {
            ((c + 0.055) / 1.055).powf(2.4)
        }
    }
    0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
}

pub fn contrast_ratio(a: (u8, u8, u8), b: (u8, u8, u8)) -> f32 {
    let la = luminance(a);
    let lb = luminance(b);
    (la.max(lb) + 0.05) / (la.min(lb) + 0.05)
}

fn hex((r, g, b): (u8, u8, u8)) -> String {
    format!("#{r:02X}{g:02X}{b:02X}")
}

fn parse_hex(value: &str) -> Option<(u8, u8, u8)> {
    let value = value.strip_prefix('#')?;
    if value.len() != 6 {
        return None;
    }
    Some((
        u8::from_str_radix(&value[0..2], 16).ok()?,
        u8::from_str_radix(&value[2..4], 16).ok()?,
        u8::from_str_radix(&value[4..6], 16).ok()?,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{Rgb, RgbImage};

    fn sample_image(color: [u8; 3]) -> DynamicImage {
        DynamicImage::ImageRgb8(RgbImage::from_pixel(32, 32, Rgb(color)))
    }

    #[test]
    fn generation_is_deterministic_except_timestamp() {
        let image = sample_image([30, 180, 220]);
        let a = generate_from_image(&image, &ThemeOptions::default(), "test.png").unwrap();
        let b = generate_from_image(&image, &ThemeOptions::default(), "test.png").unwrap();
        assert_eq!(a.colors, b.colors);
        assert_eq!(a.diagnostics.dominant_color, b.diagnostics.dominant_color);
    }

    #[test]
    fn semantic_text_colors_meet_contrast_target() {
        for mode in [ColorMode::Dark, ColorMode::Light] {
            let options = ThemeOptions {
                mode,
                ..ThemeOptions::default()
            };
            let theme =
                generate_from_image(&sample_image([220, 40, 120]), &options, "wall.png").unwrap();
            let pairs = [
                (&theme.colors.on_background, &theme.colors.background),
                (&theme.colors.on_surface, &theme.colors.surface),
                (
                    &theme.colors.on_surface_variant,
                    &theme.colors.surface_variant,
                ),
                (&theme.colors.on_primary, &theme.colors.primary),
                (&theme.colors.on_secondary, &theme.colors.secondary),
                (&theme.colors.on_tertiary, &theme.colors.tertiary),
            ];
            for (foreground, background) in pairs {
                assert!(
                    contrast_ratio(
                        parse_hex(foreground).unwrap(),
                        parse_hex(background).unwrap()
                    ) >= options.contrast_target
                );
            }
        }
    }

    #[test]
    fn clustered_palette_prefers_a_colorful_subject_over_neutral_background() {
        let mut image = RgbImage::from_pixel(64, 64, Rgb([245, 245, 245]));
        for y in 16..48 {
            for x in 16..48 {
                image.put_pixel(x, y, Rgb([20, 190, 210]));
            }
        }
        let theme = generate_from_image(
            &DynamicImage::ImageRgb8(image),
            &ThemeOptions::default(),
            "subject.png",
        )
        .unwrap();
        assert_ne!(theme.diagnostics.dominant_color, "#F4F4F4");
        assert!(Hsl::from_rgb(parse_hex(&theme.diagnostics.dominant_color).unwrap()).s > 0.5);
    }

    #[test]
    fn palette_personality_changes_accent_saturation() {
        let image = sample_image([30, 80, 220]);
        let balanced = generate_from_image(&image, &ThemeOptions::default(), "wall.png").unwrap();
        let vivid = generate_from_image(
            &image,
            &ThemeOptions {
                personality: PalettePersonality::Vivid,
                ..ThemeOptions::default()
            },
            "wall.png",
        )
        .unwrap();
        let muted = generate_from_image(
            &image,
            &ThemeOptions {
                personality: PalettePersonality::Muted,
                ..ThemeOptions::default()
            },
            "wall.png",
        )
        .unwrap();
        let saturation =
            |theme: &ThemeDocument| Hsl::from_rgb(parse_hex(&theme.colors.primary).unwrap()).s;
        assert!(saturation(&vivid) > saturation(&balanced));
        assert!(saturation(&balanced) > saturation(&muted));
    }

    #[test]
    fn invalid_contrast_target_is_rejected() {
        let options = ThemeOptions {
            contrast_target: 3.0,
            ..ThemeOptions::default()
        };
        assert!(matches!(
            generate_from_image(&sample_image([10, 20, 30]), &options, "wall.png"),
            Err(ThemeError::InvalidContrastTarget)
        ));
    }

    #[test]
    fn monochrome_wallpaper_still_produces_a_chromatic_accent() {
        let theme = generate_from_image(
            &sample_image([128, 128, 128]),
            &ThemeOptions::default(),
            "gray.png",
        )
        .unwrap();
        assert_ne!(theme.colors.primary, "#808080");
    }

    #[test]
    fn output_has_a_versioned_schema() {
        let theme = generate_from_image(
            &sample_image([50, 100, 200]),
            &ThemeOptions::default(),
            "wall.png",
        )
        .unwrap();
        let json = serde_json::to_value(theme).unwrap();
        assert_eq!(json["schema_version"], SCHEMA_VERSION);
        assert!(json["colors"]["neon_cyan"].is_string());
    }
}
