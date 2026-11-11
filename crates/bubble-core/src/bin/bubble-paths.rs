//! Small command-line adapter for the BubbleOS Rust core.
//!
//! The legacy Bash entry point can delegate path initialization and layout
//! preflight checks to this binary when it is installed. It remains optional
//! in source checkouts so an incomplete build never breaks the old path.

use bubble_core::{bootloader, require_root, system, BubblePaths};
use std::error::Error;
use std::ffi::{OsStr, OsString};
use std::path::Path;
use std::process;

const USAGE: &str = "Usage: bubble-paths <require-root|init|require-generation|require-snapshots|system-init|root-subvol|root-fstype|ulpm-version|lpk-format-version|generation-current|generation-previous|generation-running|generation-list|generation-next|generation-exists <number>|snapshot-valid-name <name>|snapshot-pending-from-file <path>|snapshot-pending-path|snapshot-pending|snapshot-list|bootloader-root-uuid|bootloader-render <generations-dir> <root-uuid> <current> <previous>|status>";

fn run(command: &str, arguments: &[OsString]) -> Result<(), Box<dyn Error>> {
    let argument = arguments.first().map(OsString::as_os_str);
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

    if command == "snapshot-valid-name" {
        let name = argument.and_then(OsStr::to_str).ok_or_else(|| {
            std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "snapshot-valid-name requires a name",
            )
        })?;
        if bubble_core::snapshots::snapshot_valid_name(name) {
            return Ok(());
        }
        return Err(
            std::io::Error::new(std::io::ErrorKind::InvalidInput, "invalid snapshot name").into(),
        );
    }

    if command == "snapshot-pending-from-file" {
        let marker = argument.and_then(OsStr::to_str).ok_or_else(|| {
            std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "snapshot-pending-from-file requires a marker path",
            )
        })?;
        if let Some(snapshot) = paths.snapshot_pending_from_file(Path::new(marker)) {
            println!("{snapshot}");
            return Ok(());
        }
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "no valid pending snapshot in marker",
        )
        .into());
    }

    if argument.is_some() && command != "bootloader-render" {
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
        "generation-running" => println!(
            "{}",
            bubble_core::generations::running_generation().ok_or_else(|| {
                std::io::Error::new(
                    std::io::ErrorKind::NotFound,
                    "running generation is unavailable",
                )
            })?
        ),
        "generation-list" => {
            for generation in paths.generation_list()? {
                println!("{generation}");
            }
        }
        "generation-next" => println!("{}", paths.generation_next()?),
        "snapshot-pending-path" => println!("{}", paths.snapshot_pending_path().display()),
        "snapshot-pending" => println!(
            "{}",
            paths.snapshot_pending().ok_or_else(|| {
                std::io::Error::new(std::io::ErrorKind::NotFound, "no valid pending snapshot")
            })?
        ),
        "snapshot-list" => {
            for snapshot in paths.snapshot_list()? {
                println!("{snapshot}");
            }
        }
        "bootloader-root-uuid" => println!(
            "{}",
            bootloader::root_uuid(&paths.rootfs_mount).ok_or_else(|| {
                std::io::Error::new(
                    std::io::ErrorKind::NotFound,
                    "cannot determine the RootFS UUID",
                )
            })?
        ),
        "bootloader-render" => {
            let values = arguments
                .iter()
                .map(|value| value.to_str())
                .collect::<Option<Vec<_>>>()
                .ok_or_else(|| {
                    std::io::Error::new(
                        std::io::ErrorKind::InvalidInput,
                        "bootloader arguments must be valid UTF-8",
                    )
                })?;
            let rendered = bootloader::render_config(
                Path::new(values[0]),
                values[1],
                values[2],
                values[3],
                &bootloader::LimineRenderOptions::default(),
            );
            print!("{rendered}");
        }
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
    let arguments: Vec<OsString> = args.collect();

    let expected_arguments = match command.as_str() {
        "generation-exists" | "snapshot-valid-name" | "snapshot-pending-from-file" => 1,
        "bootloader-render" => 4,
        _ => 0,
    };
    if arguments.len() != expected_arguments {
        eprintln!("{USAGE}");
        process::exit(2);
    }

    if let Err(error) = run(&command, &arguments) {
        eprintln!("{error}");
        process::exit(1);
    }
}
