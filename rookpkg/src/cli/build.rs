//! Build command implementation

use std::path::Path;

use anyhow::{bail, Result};
use colored::Colorize;

use crate::config::Config;
use crate::signing;
use crate::spec::PackageSpec;

pub fn run(
    spec_path: &Path,
    install: bool,
    output: Option<&Path>,
    config: &Config,
) -> Result<()> {
    // CRITICAL: Check for signing key FIRST
    println!("{}", "Checking signing key...".cyan());

    let signing_key = match signing::load_signing_key(config) {
        Ok(key) => {
            println!(
                "  {} Signing key found: {}",
                "✓".green(),
                signing::get_fingerprint(&key).dimmed()
            );
            key
        }
        Err(e) => {
            eprintln!();
            eprintln!("{}", "❌ FATAL: No signing key found!".red().bold());
            eprintln!();
            eprintln!("Package building requires a cryptographic signing key.");
            eprintln!("This ensures package authenticity and prevents tampering.");
            eprintln!();
            eprintln!("To create a signing key:");
            eprintln!(
                "  {} --name \"Your Name\" --email \"you@example.org\"",
                "rookpkg keygen".cyan()
            );
            eprintln!();
            eprintln!("For more information:");
            eprintln!("  rookpkg keygen --help");
            eprintln!();
            bail!("Signing key required: {}", e);
        }
    };

    // Parse spec file
    println!("{}", "Parsing spec file...".cyan());

    if !spec_path.exists() {
        bail!("Spec file not found: {}", spec_path.display());
    }

    let spec = PackageSpec::from_file(spec_path)?;
    println!(
        "  {} {}-{}-{}",
        "✓".green(),
        spec.package.name.bold(),
        spec.package.version,
        spec.package.release
    );

    // TODO: Download and verify sources
    println!("{}", "Downloading sources...".cyan());
    println!("  (not yet implemented)");

    // TODO: Execute build phases
    println!("{}", "Building package...".cyan());
    println!("  (not yet implemented)");

    // TODO: Create package archive
    println!("{}", "Creating package archive...".cyan());
    println!("  (not yet implemented)");

    // TODO: Sign package
    println!("{}", "Signing package...".cyan());
    println!(
        "  Would sign with key: {}",
        signing::get_fingerprint(&signing_key).dimmed()
    );

    let output_dir = output.unwrap_or(Path::new("."));
    let package_name = format!(
        "{}-{}-{}.rookpkg",
        spec.package.name, spec.package.version, spec.package.release
    );
    println!();
    println!(
        "{} {}",
        "Output:".bold(),
        output_dir.join(&package_name).display()
    );

    if install {
        println!();
        println!("{}", "Installing built package...".cyan());
        println!("  (not yet implemented)");
    }

    Ok(())
}
