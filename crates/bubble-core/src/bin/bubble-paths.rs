//! Small command-line adapter for the BubbleOS Rust core.
//!
//! The legacy Bash entry point can delegate path initialization and layout
//! preflight checks to this binary when it is installed. It remains optional
//! in source checkouts so an incomplete build never breaks the old path.

use bubble_core::{generations, require_root, system, BubblePaths};
use std::error::Error;
use std::ffi::{OsStr, OsString};
use std::process;

const USAGE: &str = "Usage: bubble-paths <require-root|init|require-generation|require-snapshots|system-init|root-subvol|root-fstype|ulpm-version|lpk-format-version|generation-current|generation-previous|generation-list|generation-next|generation-exists <number>|status>";

fn run(command: &str, argument: Option<&OsStr>) -> Result<(), Box<dyn Error>> {
    let paths = BubblePaths::from_env();

    if command == "generation-exists" {
        let generation = argument.and_then(OsStr::to_str).ok_or_else(|| {
            std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "generation-exists requires a six-digit generation number",
            )
        })?;
        if paths.generation_exists(generation) {
            return Ok(());
        }
        return Err(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            format!("generation {generation} does not exist"),
        )
        .into());
    }

    if argument.is_some() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "this command does not accept an argument",
        )
        .into());
    }

    match command {
        "require-root" => require_root()?,
        "init" => paths.initialize()?,
        "require-generation" => paths.require_generation_layout()?,
        "require-snapshots" => paths.require_snapshots_layout()?,
        "system-init" => println!("{}", system::system_init_label()),
        "root-subvol" => println!("{}", system::root_subvolume()),
        "root-fstype" => println!("{}", system::root_filesystem_type()),
        "ulpm-version" => println!(
            "{}",
            system::ulpm_version(&paths).ok_or_else(|| {
                std::io::Error::new(std::io::ErrorKind::NotFound, "ULPM version is unavailable")
            })?
        ),
        "lpk-format-version" => println!(
            "{}",
            system::lpk_format_version(&paths).ok_or_else(|| {
                std::io::Error::new(
                    std::io::ErrorKind::NotFound,
                    "LPK format version is unavailable",
                )
            })?
        ),
        "generation-current" => println!(
            "{}",
            paths.current_generation().ok_or_else(|| {
                std::io::Error::new(
                    std::io::ErrorKind::NotFound,
                    "current generation is unavailable",
                )
            })?
        ),
        "generation-previous" => println!(
            "{}",
            paths.previous_generation().ok_or_else(|| {
                std::io::Error::new(
                    std::io::ErrorKind::NotFound,
                    "previous generation is unavailable",
                )
            })?
        ),
        "generation-list" => {
            for generation in paths.generation_list()? {
                println!("{generation}");
            }
        }
        "generation-next" => println!("{}", paths.generation_next()?),
        "status" => print!("{}", system::status_report(&paths)),
        _ => {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                format!("unknown command: {command}"),
            )
            .into());
        }
    }

    Ok(())
}

fn main() {
    let mut args = std::env::args_os();
    let _program: Option<OsString> = args.next();
    let command = match args.next().and_then(|value| value.into_string().ok()) {
        Some(command) => command,
        None => {
            eprintln!("{USAGE}");
            process::exit(2);
        }
    };

    let argument = args.next();

    if args.next().is_some() {
        eprintln!("{USAGE}");
        process::exit(2);
    }

    if command != "generation-exists" && argument.is_some() {
        eprintln!("{USAGE}");
        process::exit(2);
    }

    if let Err(error) = run(&command, argument.as_deref()) {
        eprintln!("{error}");
        process::exit(1);
    }
}
