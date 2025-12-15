//! Key management CLI commands

use std::fs;
use std::path::Path;

use anyhow::{bail, Context, Result};
use colored::Colorize;

use crate::config::Config;
use crate::signing::{self, TrustLevel};

/// List all trusted signing keys
pub fn list_keys(config: &Config) -> Result<()> {
    println!("{}", "Trusted signing keys:".bold());
    println!();

    let mut found_keys = false;

    // List master keys
    let master_dir = &config.signing.master_keys_dir;
    if master_dir.exists() {
        for entry in fs::read_dir(master_dir)
            .with_context(|| format!("Failed to read master keys dir: {}", master_dir.display()))?
        {
            let entry = entry?;
            let path = entry.path();
            if path.extension().map(|e| e == "pub").unwrap_or(false) {
                match signing::load_public_key(&path) {
                    Ok(key) => {
                        found_keys = true;
                        print_key_info(&key, "master");
                    }
                    Err(e) => {
                        eprintln!("  {} {} - {}", "!".yellow(), path.display(), e);
                    }
                }
            }
        }
    }

    // List packager keys
    let packager_dir = &config.signing.packager_keys_dir;
    if packager_dir.exists() {
        for entry in fs::read_dir(packager_dir)
            .with_context(|| format!("Failed to read packager keys dir: {}", packager_dir.display()))?
        {
            let entry = entry?;
            let path = entry.path();
            if path.extension().map(|e| e == "pub").unwrap_or(false) {
                match signing::load_public_key(&path) {
                    Ok(key) => {
                        found_keys = true;
                        print_key_info(&key, "packager");
                    }
                    Err(e) => {
                        eprintln!("  {} {} - {}", "!".yellow(), path.display(), e);
                    }
                }
            }
        }
    }

    if !found_keys {
        println!("  {}", "(no trusted keys found)".dimmed());
        println!();
        println!("{}", "Hint:".cyan().bold());
        println!("  To trust a key, use: rookpkg keytrust <key-file.pub>");
        println!("  Master keys are stored in: {}", master_dir.display());
        println!("  Packager keys are stored in: {}", packager_dir.display());
    }

    Ok(())
}

/// Print information about a key
fn print_key_info(key: &signing::LoadedPublicKey, key_type: &str) {
    let trust_color = match key.trust_level {
        TrustLevel::Ultimate => "ultimate".green(),
        TrustLevel::Full => "full".cyan(),
        TrustLevel::Marginal => "marginal".yellow(),
        TrustLevel::Unknown => "unknown".red(),
    };

    let algo_color = if key.algorithm == signing::KeyAlgorithm::Hybrid {
        format!("{} {}", key.algorithm, "(quantum-resistant)".cyan())
    } else {
        format!("{} {}", key.algorithm, "(legacy)".yellow())
    };

    println!("  {} [{}]", key.fingerprint.bold(), key_type.dimmed());
    println!("    {} <{}>", key.name, key.email);
    println!("    Algorithm: {}", algo_color);
    println!("    Trust: {}", trust_color);
    println!();
}

/// Trust a signing key
pub fn trust_key(key_source: &str, config: &Config) -> Result<()> {
    let key_path = Path::new(key_source);

    // Check if it's a file path or a fingerprint
    if key_path.exists() {
        trust_key_from_file(key_path, config)
    } else if key_source.starts_with("HYBRID:") || key_source.starts_with("ED25519:") {
        bail!(
            "Trusting keys by fingerprint is not supported yet.\n\
            Please provide a path to the .pub key file."
        );
    } else {
        bail!(
            "Key not found: {}\n\
            Provide a path to a .pub key file.",
            key_source
        );
    }
}

/// Trust a key from a file
fn trust_key_from_file(path: &Path, config: &Config) -> Result<()> {
    // Load and validate the key
    let key = signing::load_public_key(path)
        .with_context(|| format!("Failed to load public key: {}", path.display()))?;

    println!("{}", "Key information:".bold());
    println!("  Fingerprint: {}", key.fingerprint.cyan());
    println!("  Name: {}", key.name);
    println!("  Email: {}", key.email);
    println!("  Algorithm: {}", key.algorithm);
    println!();

    // Determine destination
    let dest_dir = &config.signing.packager_keys_dir;
    fs::create_dir_all(dest_dir)
        .with_context(|| format!("Failed to create keys directory: {}", dest_dir.display()))?;

    // Create a safe filename from the fingerprint
    let safe_fingerprint = key.fingerprint.replace([':', '/'], "-");
    let dest_path = dest_dir.join(format!("{}.pub", safe_fingerprint));

    if dest_path.exists() {
        println!("{} Key is already trusted.", "!".yellow());
        return Ok(());
    }

    // Copy the key file
    fs::copy(path, &dest_path)
        .with_context(|| format!("Failed to copy key to: {}", dest_path.display()))?;

    println!(
        "{} Key trusted and saved to: {}",
        "✓".green(),
        dest_path.display()
    );

    if key.algorithm != signing::KeyAlgorithm::Hybrid {
        println!();
        println!("{}", "Warning:".yellow().bold());
        println!(
            "  This is a legacy Ed25519-only key. It does NOT provide\n  \
            post-quantum security. Consider requesting the key owner\n  \
            regenerate their key with hybrid Ed25519 + ML-DSA-65."
        );
    }

    Ok(())
}

/// Untrust a signing key
pub fn untrust_key(fingerprint: &str, config: &Config) -> Result<()> {
    let mut found = false;

    // Search in packager keys
    let packager_dir = &config.signing.packager_keys_dir;
    if packager_dir.exists() {
        found |= remove_key_by_fingerprint(packager_dir, fingerprint)?;
    }

    // Also allow removing from master keys (with warning)
    let master_dir = &config.signing.master_keys_dir;
    if master_dir.exists() {
        if contains_key_by_fingerprint(master_dir, fingerprint)? {
            println!(
                "{} This is a master key. Removing it may break system packages.",
                "Warning:".yellow().bold()
            );
            found |= remove_key_by_fingerprint(master_dir, fingerprint)?;
        }
    }

    if found {
        println!("{} Key {} has been untrusted.", "✓".green(), fingerprint);
        Ok(())
    } else {
        bail!("Key not found: {}", fingerprint);
    }
}

/// Check if a directory contains a key with the given fingerprint
fn contains_key_by_fingerprint(dir: &Path, fingerprint: &str) -> Result<bool> {
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        if path.extension().map(|e| e == "pub").unwrap_or(false) {
            if let Ok(key) = signing::load_public_key(&path) {
                if key.fingerprint == fingerprint
                    || key.fingerprint.ends_with(fingerprint)
                    || fingerprint.ends_with(&key.fingerprint)
                {
                    return Ok(true);
                }
            }
        }
    }
    Ok(false)
}

/// Remove a key by fingerprint from a directory
fn remove_key_by_fingerprint(dir: &Path, fingerprint: &str) -> Result<bool> {
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        if path.extension().map(|e| e == "pub").unwrap_or(false) {
            if let Ok(key) = signing::load_public_key(&path) {
                if key.fingerprint == fingerprint
                    || key.fingerprint.ends_with(fingerprint)
                    || fingerprint.ends_with(&key.fingerprint)
                {
                    fs::remove_file(&path)
                        .with_context(|| format!("Failed to remove key: {}", path.display()))?;
                    return Ok(true);
                }
            }
        }
    }
    Ok(false)
}
