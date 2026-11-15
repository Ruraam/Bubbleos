use bubble_theme_engine::{
    generate_from_path, ColorMode, PalettePersonality, ThemeDocument, ThemeOptions,
};
use std::{
    error::Error,
    fs, io,
    path::{Path, PathBuf},
};

fn usage() {
    eprintln!(
        "Usage:\n  bubble-theme generate --wallpaper <FILE> [--output <FILE>] [--mode dark|light] [--personality balanced|vivid|muted]\n  bubble-theme export-waybar --theme <JSON> --base-style <CSS> [--output <CSS>]\n\nGenerate writes a versioned BubbleOS theme JSON document. export-waybar maps its semantic colors to GTK CSS and keeps the base stylesheet rules."
    );
}

fn main() {
    if let Err(error) = run() {
        eprintln!("bubble-theme: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn Error>> {
    let mut args = std::env::args().skip(1);
    let Some(command) = args.next() else {
        usage();
        return Err("missing command".into());
    };

    match command.as_str() {
        "--help" | "-h" => {
            usage();
            Ok(())
        }
        "generate" => run_generate(args),
        "export-waybar" => run_export_waybar(args),
        unknown => {
            usage();
            Err(format!("unknown command: {unknown}").into())
        }
    }
}

fn run_generate(args: impl Iterator<Item = String>) -> Result<(), Box<dyn Error>> {
    let mut args = args;
    let mut wallpaper: Option<PathBuf> = None;
    let mut output: Option<PathBuf> = None;
    let mut options = ThemeOptions::default();
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--wallpaper" => {
                wallpaper = Some(args.next().ok_or("--wallpaper requires a path")?.into())
            }
            "--output" => output = Some(args.next().ok_or("--output requires a path")?.into()),
            "--mode" => {
                options.mode = match args.next().as_deref() {
                    Some("dark") => ColorMode::Dark,
                    Some("light") => ColorMode::Light,
                    _ => return Err("--mode must be dark or light".into()),
                };
            }
            "--personality" => {
                options.personality = match args.next().as_deref() {
                    Some("balanced") => PalettePersonality::Balanced,
                    Some("vivid") => PalettePersonality::Vivid,
                    Some("muted") => PalettePersonality::Muted,
                    _ => return Err("--personality must be balanced, vivid or muted".into()),
                };
            }
            "--help" | "-h" => {
                usage();
                return Ok(());
            }
            unknown => return Err(format!("unknown argument: {unknown}").into()),
        }
    }

    let wallpaper = wallpaper.ok_or("--wallpaper is required")?;
    let theme = generate_from_path(&wallpaper, &options)?;
    let json = serde_json::to_string_pretty(&theme)?;
    write_or_print(output, &format!("{json}\n"), "json")
}

fn run_export_waybar(args: impl Iterator<Item = String>) -> Result<(), Box<dyn Error>> {
    let mut args = args;
    let mut theme_path: Option<PathBuf> = None;
    let mut base_style_path: Option<PathBuf> = None;
    let mut output: Option<PathBuf> = None;

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--theme" => theme_path = Some(args.next().ok_or("--theme requires a path")?.into()),
            "--base-style" => {
                base_style_path = Some(args.next().ok_or("--base-style requires a path")?.into())
            }
            "--output" => output = Some(args.next().ok_or("--output requires a path")?.into()),
            "--help" | "-h" => {
                usage();
                return Ok(());
            }
            unknown => return Err(format!("unknown argument: {unknown}").into()),
        }
    }

    let theme_path = theme_path.ok_or("--theme is required")?;
    let base_style_path = base_style_path.ok_or("--base-style is required")?;
    let theme: ThemeDocument = serde_json::from_str(&fs::read_to_string(theme_path)?)?;
    let base_style = fs::read_to_string(base_style_path)?;
    let css = waybar_css(&theme, &base_style)?;
    write_or_print(output, &css, "css")
}

fn waybar_css(theme: &ThemeDocument, base_style: &str) -> Result<String, Box<dyn Error>> {
    let colors = [
        ("ink", theme.colors.background.as_str()),
        ("navy", theme.colors.surface.as_str()),
        ("slate", theme.colors.surface_variant.as_str()),
        ("surface", theme.colors.surface_elevated.as_str()),
        ("text", theme.colors.on_surface.as_str()),
        ("muted", theme.colors.on_surface_variant.as_str()),
        ("cyan", theme.colors.neon_cyan.as_str()),
        ("sky", theme.colors.primary.as_str()),
        ("blue", theme.colors.secondary.as_str()),
        ("indigo", theme.colors.tertiary.as_str()),
        ("warn", theme.colors.warning.as_str()),
        ("crit", theme.colors.error.as_str()),
        ("good", theme.colors.success.as_str()),
        ("dim", theme.colors.outline_variant.as_str()),
    ];

    let mut css = String::new();
    for (name, color) in colors {
        if !is_hex_color(color) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("theme color for {name} is not a six-digit hex value"),
            )
            .into());
        }
        css.push_str(&format!("@define-color {name} {color};\n"));
    }
    css.push('\n');

    for line in base_style.lines() {
        if !line.trim_start().starts_with("@define-color ") {
            css.push_str(line);
            css.push('\n');
        }
    }
    Ok(css)
}

fn is_hex_color(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 7 && bytes[0] == b'#' && bytes[1..].iter().all(u8::is_ascii_hexdigit)
}

fn write_or_print(
    output: Option<PathBuf>,
    content: &str,
    extension: &str,
) -> Result<(), Box<dyn Error>> {
    if let Some(path) = output {
        let parent = path
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
            .unwrap_or(Path::new("."));
        fs::create_dir_all(parent)?;
        let temp = path.with_extension(format!("{extension}.tmp"));
        fs::write(&temp, content)?;
        fs::rename(temp, path)?;
    } else {
        print!("{content}");
    }
    Ok(())
}
