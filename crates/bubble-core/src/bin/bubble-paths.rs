//! Small command-line adapter for the BubbleOS Rust core.
//!
//! The legacy Bash entry point can delegate path initialization and layout
//! preflight checks to this binary when it is installed. It remains optional
//! in source checkouts so an incomplete build never breaks the old path.

use bubble_core::{require_root, BubblePaths};
use std::error::Error;
use std::ffi::OsString;
use std::process;

const USAGE: &str = "Usage: bubble-paths <require-root|init|require-generation|require-snapshots>";

fn run(command: &str) -> Result<(), Box<dyn Error>> {
    let paths = BubblePaths::from_env();

    match command {
        "require-root" => require_root()?,
        "init" => paths.initialize()?,
        "require-generation" => paths.require_generation_layout()?,
        "require-snapshots" => paths.require_snapshots_layout()?,
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

    if args.next().is_some() {
        eprintln!("{USAGE}");
        process::exit(2);
    }

    if let Err(error) = run(&command) {
        eprintln!("{error}");
        process::exit(1);
    }
}
