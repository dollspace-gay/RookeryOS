//! List command implementation

use anyhow::Result;
use colored::Colorize;

use crate::config::Config;

pub fn run(available: bool, filter: Option<&str>, _config: &Config) -> Result<()> {
    if available {
        println!("{}", "Available packages:".bold());
        println!("  (no repositories configured yet)");
    } else {
        println!("{}", "Installed packages:".bold());
        println!("  (no packages installed yet)");
    }

    if let Some(f) = filter {
        println!("  Filter: {}", f.cyan());
    }

    Ok(())
}
