//! Repository update command

use anyhow::Result;
use colored::Colorize;

use crate::config::Config;
use crate::repository::RepoManager;

/// Run the update command
pub fn run(config: &Config) -> Result<()> {
    println!("{}", "Updating repository metadata...".cyan());
    println!();

    if config.repositories.is_empty() {
        println!("  {}", "No repositories configured.".yellow());
        println!();
        println!("{}", "To add a repository, edit /etc/rookpkg/rookpkg.conf:".dimmed());
        println!();
        println!("  [[repositories]]");
        println!("  name = \"rookery-core\"");
        println!("  url = \"https://packages.rookery.org/core\"");
        println!("  enabled = true");
        println!("  priority = 100");
        println!();
        return Ok(());
    }

    let mut manager = RepoManager::new(config)?;

    // Load existing cache
    manager.load_caches()?;

    // Update all repositories
    let result = manager.update_all(config)?;

    println!();

    // Report results
    for name in &result.updated {
        println!("  {} {} {}", "✓".green(), name.bold(), "(updated)".green());
    }

    for name in &result.unchanged {
        println!("  {} {} {}", "✓".cyan(), name.bold(), "(up to date)".dimmed());
    }

    for (name, error) in &result.failed {
        println!("  {} {} - {}", "✗".red(), name.bold(), error.red());
    }

    println!();

    if result.all_success() {
        let total_packages: usize = manager
            .enabled_repos()
            .filter_map(|r| r.index.as_ref())
            .map(|i| i.count)
            .sum();

        println!(
            "{} {} repositories updated, {} packages available",
            "✓".green(),
            result.total(),
            total_packages
        );
    } else {
        println!(
            "{} {} repositories failed to update",
            "!".yellow(),
            result.failed.len()
        );
    }

    Ok(())
}
