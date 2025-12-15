//! Search command implementation

use anyhow::Result;
use colored::Colorize;

use crate::config::Config;
use crate::database::Database;
use crate::repository::RepoManager;

pub fn run(query: &str, config: &Config) -> Result<()> {
    println!("{} '{}'", "Searching for:".cyan(), query.bold());
    println!();

    let mut found_any = false;

    // Search installed packages
    let db_path = &config.database.path;
    if db_path.exists() {
        let db = Database::open(db_path)?;
        let installed = db.list_packages()?;

        let query_lower = query.to_lowercase();
        let matches: Vec<_> = installed
            .iter()
            .filter(|p| p.name.to_lowercase().contains(&query_lower))
            .collect();

        if !matches.is_empty() {
            println!("{}", "Installed packages:".bold());
            for pkg in &matches {
                println!(
                    "  {} {}-{} {}",
                    "✓".green(),
                    pkg.name.bold(),
                    pkg.full_version(),
                    "[installed]".green()
                );
            }
            println!();
            found_any = true;
        }
    }

    // Search available packages
    if config.repositories.is_empty() {
        if !found_any {
            println!("  {}", "No repositories configured.".yellow());
            println!();
            println!("Run {} to add repositories.", "rookpkg update".bold());
        }
        return Ok(());
    }

    let mut manager = RepoManager::new(config)?;
    manager.load_caches()?;

    // Use RepoManager::search for efficient cross-repository search
    let search_results = manager.search(query);

    // Convert to our format (package, repo_name)
    let mut available_matches: Vec<_> = search_results
        .into_iter()
        .map(|r| (r.package, r.repository))
        .collect();

    // Sort by name
    available_matches.sort_by(|a, b| a.0.name.cmp(&b.0.name));

    // Get list of installed package names for comparison
    let installed_names: Vec<String> = if db_path.exists() {
        let db = Database::open(db_path)?;
        db.list_packages()?.into_iter().map(|p| p.name).collect()
    } else {
        Vec::new()
    };

    // Filter out already-shown installed packages and display
    let not_installed: Vec<_> = available_matches
        .iter()
        .filter(|(p, _)| !installed_names.contains(&p.name))
        .collect();

    if !not_installed.is_empty() {
        println!("{}", "Available packages:".bold());

        // Calculate column widths
        let max_name = not_installed
            .iter()
            .map(|(p, _)| p.name.len())
            .max()
            .unwrap_or(0);

        for (pkg, repo) in &not_installed {
            let version = format!("{}-{}", pkg.version, pkg.release);
            let desc = truncate(&pkg.description, 50);

            println!(
                "  {:<width$}  {:>10}  {}  {}",
                pkg.name.bold(),
                version.dimmed(),
                format!("[{}]", repo).cyan(),
                desc.dimmed(),
                width = max_name,
            );
        }
        println!();
        found_any = true;
    }

    if !found_any {
        println!("  {}", "No packages found.".dimmed());
        println!();
        println!(
            "  Try {} to refresh package lists.",
            "rookpkg update".bold()
        );
    } else {
        let total = available_matches.len();
        println!(
            "  {} package(s) found matching '{}'",
            total.to_string().green(),
            query
        );
    }

    Ok(())
}

fn truncate(s: &str, max_len: usize) -> String {
    if s.len() <= max_len {
        s.to_string()
    } else {
        format!("{}...", &s[..max_len - 3])
    }
}
