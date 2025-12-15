//! Install command implementation

use std::collections::HashMap;
use std::path::Path;

use anyhow::{bail, Result};
use colored::Colorize;
use pubgrub::range::Range;
use pubgrub::solver::resolve;
use pubgrub::version::SemanticVersion;

use crate::config::Config;
use crate::database::Database;
use crate::repository::{PackageEntry, RepoManager, SignatureStatus, VerifiedPackage};
use crate::resolver::{parse_constraint, Package, RookeryDependencyProvider};
use crate::signing::TrustLevel;
use crate::transaction::TransactionBuilder;

pub fn run(packages: &[String], dry_run: bool, config: &Config) -> Result<()> {
    if dry_run {
        println!("{}", "Dry run mode - no changes will be made".yellow());
        println!();
    }

    println!("{}", "Loading repository data...".cyan());

    // Initialize repository manager and load cached metadata
    let mut manager = RepoManager::new(config)?;

    // Check if we have any repos
    if config.repositories.is_empty() {
        println!();
        println!("{}", "No repositories configured.".yellow());
        println!("Run {} to add repositories.", "rookpkg update".bold());
        return Ok(());
    }

    // Load caches and show repo status
    manager.load_caches()?;

    // Show repo status using get_repo
    for repo_config in &config.repositories {
        if let Some(repo) = manager.get_repo(&repo_config.name) {
            let pkg_count = repo.index.as_ref().map(|i| i.count).unwrap_or(0);
            tracing::debug!(
                "Repository '{}': {} packages loaded from {}",
                repo.name,
                pkg_count,
                manager.package_cache_dir().display()
            );
        }
    }

    println!("{}", "Resolving dependencies...".cyan());
    println!();

    // Build dependency provider from repository data
    let mut provider = RookeryDependencyProvider::new();
    let mut package_map: HashMap<String, (PackageEntry, String)> = HashMap::new();

    // Add all available packages to the provider
    for repo in manager.enabled_repos() {
        if let Some(ref index) = repo.index {
            for pkg in &index.packages {
                // Parse version
                let version = parse_version(&pkg.version);

                // Parse dependencies
                let mut deps = HashMap::new();
                for dep_str in &pkg.depends {
                    // Format: "name" or "name >= 1.0"
                    let (dep_name, constraint) = parse_dep_string(dep_str);
                    if let Ok(range) = parse_constraint(&constraint) {
                        deps.insert(dep_name.to_string(), range);
                    }
                }

                provider.add_package(&pkg.name, version, deps);
                package_map.insert(pkg.name.clone(), (pkg.clone(), repo.name.clone()));
            }
        }
    }

    // Find each requested package first
    let mut not_found = Vec::new();
    let mut root_packages = Vec::new();

    for package_name in packages {
        if package_map.contains_key(package_name) {
            root_packages.push(package_name.clone());
        } else {
            println!("  {} {} {}", "✗".red(), package_name.bold(), "(not found)".red());
            not_found.push(package_name.clone());
        }
    }

    if !not_found.is_empty() {
        println!();
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

    if root_packages.is_empty() {
        println!("{}", "Nothing to install.".yellow());
        return Ok(());
    }

    // Resolve dependencies using PubGrub
    println!("  Resolving dependency tree...");

    // Create a virtual root package that depends on all requested packages
    let mut root_deps: HashMap<String, Range<SemanticVersion>> = HashMap::new();
    for pkg_name in &root_packages {
        root_deps.insert(pkg_name.clone(), Range::any());
    }
    provider.add_package("__root__", SemanticVersion::new(1, 0, 0), root_deps);

    let solution = match resolve(&provider, Package("__root__".to_string()), SemanticVersion::new(1, 0, 0)) {
        Ok(sol) => sol,
        Err(e) => {
            println!();
            println!("{}", "Dependency resolution failed:".red().bold());
            println!("  {}", e);
            bail!("Could not resolve dependencies");
        }
    };

    // Build install list from solution (excluding virtual root)
    let mut to_install: Vec<(PackageEntry, String)> = Vec::new();
    for (pkg, _version) in &solution {
        if pkg.0 != "__root__" {
            if let Some((entry, repo)) = package_map.get(&pkg.0) {
                to_install.push((entry.clone(), repo.clone()));
            }
        }
    }

    // Show resolved packages
    let requested_set: std::collections::HashSet<_> = root_packages.iter().collect();
    for (pkg, repo) in &to_install {
        let is_dep = !requested_set.contains(&pkg.name);
        if is_dep {
            println!(
                "  {} {}-{} {} {} {}",
                "✓".green(),
                pkg.name.bold(),
                pkg.version,
                "from".dimmed(),
                repo.cyan(),
                "(dependency)".dimmed()
            );
        } else {
            println!(
                "  {} {}-{} {} {}",
                "✓".green(),
                pkg.name.bold(),
                pkg.version,
                "from".dimmed(),
                repo.cyan()
            );
        }
    }

    println!();

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

    // Pre-download all packages to cache (batch download)
    // This uses download_packages for efficient parallel fetching
    tracing::debug!("Pre-downloading {} packages to cache", to_install.len());
    let download_list: Vec<(PackageEntry, String)> = to_install.clone();
    let _downloaded_paths = manager.download_packages(&download_list)?;

    // Download and verify packages
    println!("{}", "Downloading and verifying packages...".cyan());
    println!();

    let mut verified_packages: Vec<VerifiedPackage> = Vec::new();

    for (package, repo_name) in &to_install {
        // Check if package is already cached
        let cached_status = if manager.is_package_cached(package) {
            if let Some(cached_path) = manager.get_cached_package(package) {
                tracing::debug!("Package {} found in cache: {}", package.name, cached_path.display());
                "(cached)"
            } else {
                ""
            }
        } else {
            ""
        };

        print!(
            "  {} {}-{} {}... ",
            "↓".cyan(),
            package.name,
            package.version,
            cached_status.dimmed()
        );

        match manager.download_and_verify_package(package, repo_name, config) {
            Ok(verified) => {
                // Show download and verification result
                // Only Verified status can reach here - unsigned/unknown/invalid all bail
                if let SignatureStatus::Verified { signer, trust_level, .. } = &verified.signature_status {
                    let trust_color = match trust_level {
                        TrustLevel::Ultimate => "ultimate".green(),
                        TrustLevel::Full => "full".green(),
                        TrustLevel::Marginal => "marginal".yellow(),
                        TrustLevel::Unknown => "unknown".red(),
                    };
                    println!("{} [signed by {} ({})]", "✓".green(), signer.cyan(), trust_color);
                }

                verified_packages.push(verified);
            }
            Err(e) => {
                println!("{}", "✗".red());
                bail!("Failed to download/verify {}: {}", package.name, e);
            }
        }
    }

    println!();

    // Summary
    let verified_count = verified_packages.iter().filter(|p| p.is_verified()).count();
    let trusted_count = verified_packages.iter().filter(|p| p.is_trusted()).count();

    if verified_count == verified_packages.len() {
        println!(
            "{} All {} package(s) have valid signatures",
            "✓".green().bold(),
            verified_count
        );
        if trusted_count == verified_packages.len() {
            println!("  All signatures from trusted keys");
        }
    } else {
        let unsigned_count = verified_packages.len() - verified_count;
        println!(
            "{} {} of {} package(s) verified, {} unsigned/unknown",
            "!".yellow().bold(),
            verified_count,
            verified_packages.len(),
            unsigned_count
        );
    }

    println!();

    // Install packages using transaction
    println!("{}", "Installing packages...".cyan());
    println!();

    // Open or create database
    let db_path = &config.database.path;
    let db = Database::open(db_path)?;

    // Check for already installed packages
    let mut already_installed = Vec::new();
    for verified in &verified_packages {
        if let Ok(Some(existing)) = db.get_package(&verified.package.name) {
            already_installed.push((verified.package.name.clone(), existing.version.clone()));
        }
    }

    // Filter out already installed packages
    let packages_to_install: Vec<_> = verified_packages
        .into_iter()
        .filter(|v| !already_installed.iter().any(|(n, _)| n == &v.package.name))
        .collect();

    if !already_installed.is_empty() {
        println!("{}", "Some packages are already installed:".yellow());
        for (name, version) in &already_installed {
            println!("  {} {} ({})", "!".yellow(), name.bold(), version);
        }
        println!();
        println!("Use {} to update existing packages.", "rookpkg upgrade".bold());
        println!();
    }

    if packages_to_install.is_empty() {
        println!("{}", "Nothing new to install.".yellow());
        return Ok(());
    }

    // Use TransactionBuilder for cleaner API
    let root = Path::new("/");
    let mut builder = TransactionBuilder::new(root);

    for verified in &packages_to_install {
        let version = format!("{}-{}", verified.package.version, verified.package.release);
        builder = builder.install(&verified.package.name, &version, &verified.path);
    }

    // Re-open database for transaction execution
    let db = Database::open(db_path)?;

    match builder.execute(db) {
        Ok(()) => {
            println!(
                "{} {} package(s) installed successfully",
                "✓".green().bold(),
                packages_to_install.len()
            );
        }
        Err(e) => {
            println!(
                "{} Installation failed: {}",
                "✗".red().bold(),
                e
            );
            bail!("Installation transaction failed: {}", e);
        }
    }

    println!();
    println!("{}", "Installation complete!".green());

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

/// Parse a version string to SemanticVersion
fn parse_version(s: &str) -> SemanticVersion {
    let parts: Vec<&str> = s.split('.').collect();

    let major: u32 = parts
        .first()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);

    let minor: u32 = parts.get(1).and_then(|s| s.parse().ok()).unwrap_or(0);

    let patch: u32 = parts.get(2).and_then(|s| s.parse().ok()).unwrap_or(0);

    SemanticVersion::new(major, minor, patch)
}

/// Parse a dependency string like "name" or "name >= 1.0"
fn parse_dep_string(dep: &str) -> (&str, String) {
    // Try to find an operator
    for op in &[">=", "<=", "==", "!=", ">", "<", "="] {
        if let Some(pos) = dep.find(op) {
            let name = dep[..pos].trim();
            let constraint = dep[pos..].trim();
            return (name, constraint.to_string());
        }
    }
    // No operator found - name only, any version
    (dep.trim(), "*".to_string())
}
