//! Key generation command implementation

use std::path::Path;

use anyhow::Result;
use colored::Colorize;

use crate::config::Config;
use crate::signing;

pub fn run(name: &str, email: &str, output: Option<&Path>, config: &Config) -> Result<()> {
    println!("{}", "Generating Ed25519 signing key...".cyan());
    println!();

    let output_dir = output.unwrap_or_else(|| config.signing_key_dir());

    let (signing_key, fingerprint) = signing::generate_key(name, email, output_dir)?;

    println!("{}", "✓ Key generated successfully!".green().bold());
    println!();
    println!("  {}: {}", "Fingerprint".bold(), fingerprint);
    println!(
        "  {}: {}",
        "Public key".bold(),
        output_dir.join("signing-key.pub").display()
    );
    println!(
        "  {}: {}",
        "Secret key".bold(),
        output_dir.join("signing-key.secret").display()
    );
    println!();
    println!("{}", "⚠️  IMPORTANT:".yellow().bold());
    println!("  This key is NOT trusted by default!");
    println!("  To sign official packages, submit your public key to the");
    println!("  Rookery OS maintainers for signing.");
    println!();
    println!("{}", "✓ You can now build and sign packages locally.".green());

    // Return the key so we don't get an unused warning
    drop(signing_key);

    Ok(())
}
