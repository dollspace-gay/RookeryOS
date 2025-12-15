//! Install command implementation

use anyhow::{bail, Result};
use colored::Colorize;

use crate::config::Config;
use crate::repository::RepoManager;

pub fn run(packages: &[String], dry_run: bool, config: &Config) -> Result<()> {
    if dry_run {
        println!("{}", "Dry run mode - no changes will be made".yellow());
        println!();
    }

    println!("{}", "Loading repository data...".cyan());

    // Initialize repository manager and load cached metadata
    let manager = RepoManager::new(config)?;

    // Check if we have any repos
    if config.repositories.is_empty() {
        println!();
        println!("{}", "No repositories configured.".yellow());
        println!("Run {} to add repositories.", "rookpkg update".bold());
        return Ok(());
    }

    println!("{}", "Resolving packages...".cyan());
    println!();

    // Find each requested package
    let mut to_install = Vec::new();
    let mut not_found = Vec::new();

    for package_name in packages {
        match manager.find_package(package_name) {
            Some(result) => {
                println!(
                    "  {} {}-{} {} {}",
                    "✓".green(),
                    result.package.name.bold(),
                    result.package.version,
                    "from".dimmed(),
                    result.repository.cyan()
                );
                to_install.push((result.package, result.repository));
            }
            None => {
                println!("  {} {} {}", "✗".red(), package_name.bold(), "(not found)".red());
                not_found.push(package_name.clone());
            }
        }
    }

    println!();

    if !not_found.is_empty() {
        println!(
            "{} {} package(s) not found:",
            "Error:".red().bold(),
            not_found.len()
        );
        for name in &not_found {
            println!("  - {}", name);
        }
        println!();
        println!("Try {} to refresh package lists.", "rookpkg update".bold());
        bail!("Some packages not found");
    }

    if to_install.is_empty() {
        println!("{}", "Nothing to install.".yellow());
        return Ok(());
    }

    // Calculate total download size
    let total_size: u64 = to_install.iter().map(|(p, _)| p.size).sum();
    println!(
        "Total download size: {}",
        format_size(total_size).cyan()
    );
    println!();

    if dry_run {
        println!("{}", "Dry run complete - no packages downloaded.".yellow());
        return Ok(());
    }

    // Download packages
    println!("{}", "Downloading packages...".cyan());
    println!();

    for (package, repo_name) in &to_install {
        print!(
            "  {} {}-{}...",
            "↓".cyan(),
            package.name,
            package.version
        );

        // Check if already cached
        if manager.is_package_cached(package) {
            println!(" {} (cached)", "✓".green());
            continue;
        }

        match manager.download_package(package, repo_name) {
            Ok(path) => {
                println!(
                    " {} ({})",
                    "✓".green(),
                    path.file_name()
                        .map(|s| s.to_string_lossy().to_string())
                        .unwrap_or_default()
                );
            }
            Err(e) => {
                println!(" {}", "✗".red());
                bail!("Failed to download {}: {}", package.name, e);
            }
        }
    }

    println!();
    println!("{}", "Packages downloaded successfully.".green());
    println!();

    // TODO: Actually install the packages (extract, run scripts, update database)
    println!("{}", "Note: Package installation (extraction + registration) not yet implemented.".yellow());
    println!("Downloaded packages are cached in: {}", manager.package_cache_dir().display());

    Ok(())
}

/// Format bytes as human-readable size
fn format_size(bytes: u64) -> String {
    const KB: u64 = 1024;
    const MB: u64 = KB * 1024;
    const GB: u64 = MB * 1024;

    if bytes >= GB {
        format!("{:.2} GB", bytes as f64 / GB as f64)
    } else if bytes >= MB {
        format!("{:.2} MB", bytes as f64 / MB as f64)
    } else if bytes >= KB {
        format!("{:.2} KB", bytes as f64 / KB as f64)
    } else {
        format!("{} B", bytes)
    }
}
