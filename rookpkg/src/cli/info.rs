//! Info command implementation

use anyhow::Result;
use colored::Colorize;

use crate::config::Config;

pub fn run(package: &str, deps: bool, _config: &Config) -> Result<()> {
    println!("{}: {}", "Package".bold(), package.cyan());
    println!();
    println!("  Package not found in database.");
    println!("  (Database not yet implemented)");

    if deps {
        println!();
        println!("{}", "Dependencies:".bold());
        println!("  (not available)");
    }

    Ok(())
}
