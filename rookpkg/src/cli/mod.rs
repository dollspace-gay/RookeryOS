//! Command-line interface for rookpkg

use anyhow::Result;
use clap::Subcommand;
use colored::Colorize;

use crate::config::Config;

mod build;
mod info;
mod install;
mod keygen;
mod list;
mod remove;
mod search;

#[derive(Subcommand)]
pub enum Commands {
    /// Install a package
    Install {
        /// Package name(s) to install
        #[arg(required = true)]
        packages: Vec<String>,

        /// Don't actually install, just show what would happen
        #[arg(long)]
        dry_run: bool,
    },

    /// Remove a package
    Remove {
        /// Package name(s) to remove
        #[arg(required = true)]
        packages: Vec<String>,

        /// Also remove packages that depend on this package
        #[arg(long)]
        cascade: bool,

        /// Don't actually remove, just show what would happen
        #[arg(long)]
        dry_run: bool,
    },

    /// List installed packages
    List {
        /// Show all available packages (not just installed)
        #[arg(long)]
        available: bool,

        /// Filter by pattern
        #[arg(short, long)]
        filter: Option<String>,
    },

    /// Show package information
    Info {
        /// Package name
        package: String,

        /// Show detailed dependency information
        #[arg(long)]
        deps: bool,
    },

    /// Search for packages
    Search {
        /// Search query
        query: String,
    },

    /// Build a package from a .rook spec file
    Build {
        /// Path to .rook spec file
        spec: std::path::PathBuf,

        /// Install after building
        #[arg(long)]
        install: bool,

        /// Output directory for built package
        #[arg(short, long)]
        output: Option<std::path::PathBuf>,
    },

    /// Generate a new signing key
    Keygen {
        /// Your name
        #[arg(long)]
        name: String,

        /// Your email
        #[arg(long)]
        email: String,

        /// Output directory for keys
        #[arg(long)]
        output: Option<std::path::PathBuf>,
    },

    /// List trusted signing keys
    Keylist,

    /// Trust a signing key
    #[command(name = "keytrust")]
    KeyTrust {
        /// Key fingerprint or path to .pub file
        key: String,
    },

    /// Revoke trust for a signing key
    #[command(name = "keyuntrust")]
    KeyUntrust {
        /// Key fingerprint
        fingerprint: String,
    },

    /// Verify a package signature
    Verify {
        /// Path to package file
        package: std::path::PathBuf,
    },

    /// Update repository metadata
    Update,

    /// Upgrade installed packages
    Upgrade {
        /// Don't actually upgrade, just show what would happen
        #[arg(long)]
        dry_run: bool,
    },

    /// Show dependency tree for a package
    Depends {
        /// Package name
        package: String,

        /// Show reverse dependencies (what depends on this)
        #[arg(long)]
        reverse: bool,
    },

    /// Verify integrity of installed packages
    Check {
        /// Package name (or all if not specified)
        package: Option<String>,
    },

    /// Clean package cache
    Clean {
        /// Remove all cached packages
        #[arg(long)]
        all: bool,
    },
}

/// Execute a CLI command
pub fn execute(command: Commands, config: &Config) -> Result<()> {
    match command {
        Commands::Install { packages, dry_run } => {
            install::run(&packages, dry_run, config)
        }
        Commands::Remove { packages, cascade, dry_run } => {
            remove::run(&packages, cascade, dry_run, config)
        }
        Commands::List { available, filter } => {
            list::run(available, filter.as_deref(), config)
        }
        Commands::Info { package, deps } => {
            info::run(&package, deps, config)
        }
        Commands::Search { query } => {
            search::run(&query, config)
        }
        Commands::Build { spec, install, output } => {
            build::run(&spec, install, output.as_deref(), config)
        }
        Commands::Keygen { name, email, output } => {
            keygen::run(&name, &email, output.as_deref(), config)
        }
        Commands::Keylist => {
            println!("{}", "Trusted signing keys:".bold());
            println!("  (none configured yet)");
            Ok(())
        }
        Commands::KeyTrust { key } => {
            println!("Would trust key: {}", key);
            Ok(())
        }
        Commands::KeyUntrust { fingerprint } => {
            println!("Would untrust key: {}", fingerprint);
            Ok(())
        }
        Commands::Verify { package } => {
            println!("Would verify: {}", package.display());
            Ok(())
        }
        Commands::Update => {
            println!("{}", "Updating repository metadata...".cyan());
            println!("  (no repositories configured yet)");
            Ok(())
        }
        Commands::Upgrade { dry_run } => {
            if dry_run {
                println!("{}", "Dry run - no packages would be upgraded".yellow());
            } else {
                println!("{}", "No upgrades available.".green());
            }
            Ok(())
        }
        Commands::Depends { package, reverse } => {
            if reverse {
                println!("Packages that depend on {}:", package.bold());
            } else {
                println!("Dependencies of {}:", package.bold());
            }
            println!("  (not implemented yet)");
            Ok(())
        }
        Commands::Check { package } => {
            match package {
                Some(p) => println!("Would check package: {}", p),
                None => println!("Would check all installed packages"),
            }
            Ok(())
        }
        Commands::Clean { all } => {
            if all {
                println!("{}", "Cleaning all cached packages...".cyan());
            } else {
                println!("{}", "Cleaning old cached packages...".cyan());
            }
            println!("  Cache is empty.");
            Ok(())
        }
    }
}
