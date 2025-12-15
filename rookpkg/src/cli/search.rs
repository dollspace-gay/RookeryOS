//! Search command implementation

use anyhow::Result;
use colored::Colorize;

use crate::config::Config;

pub fn run(query: &str, _config: &Config) -> Result<()> {
    println!("{} '{}'", "Searching for:".cyan(), query.bold());
    println!();
    println!("  No packages found.");
    println!("  (Repository search not yet implemented)");

    Ok(())
}
