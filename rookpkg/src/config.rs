//! Configuration management for rookpkg

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

/// Main configuration structure
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    /// Database configuration
    #[serde(default)]
    pub database: DatabaseConfig,

    /// Signing configuration
    #[serde(default)]
    pub signing: SigningConfig,

    /// Repository configuration
    #[serde(default)]
    pub repositories: Vec<RepositoryConfig>,

    /// Build configuration
    #[serde(default)]
    pub build: BuildConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DatabaseConfig {
    /// Path to the SQLite database
    pub path: PathBuf,
}

impl Default for DatabaseConfig {
    fn default() -> Self {
        Self {
            path: PathBuf::from("/var/lib/rookpkg/db.sqlite"),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SigningConfig {
    /// Require signatures on all packages (cannot be disabled)
    #[serde(default = "default_true")]
    pub require_signatures: bool,

    /// Allow packages signed by untrusted keys
    #[serde(default)]
    pub allow_untrusted: bool,

    /// Directory for master signing keys
    pub master_keys_dir: PathBuf,

    /// Directory for packager signing keys
    pub packager_keys_dir: PathBuf,

    /// Path to user's signing key
    pub user_signing_key: PathBuf,

    /// Allowed signature algorithms
    #[serde(default = "default_algorithms")]
    pub allowed_algorithms: Vec<String>,
}

fn default_true() -> bool {
    true
}

fn default_algorithms() -> Vec<String> {
    vec!["ed25519".to_string()]
}

impl Default for SigningConfig {
    fn default() -> Self {
        let config_dir = directories::ProjectDirs::from("org", "rookery", "rookpkg")
            .map(|d| d.config_dir().to_path_buf())
            .unwrap_or_else(|| PathBuf::from("~/.config/rookpkg"));

        Self {
            require_signatures: true,
            allow_untrusted: false,
            master_keys_dir: PathBuf::from("/etc/rookpkg/keys/master"),
            packager_keys_dir: PathBuf::from("/etc/rookpkg/keys/packagers"),
            user_signing_key: config_dir.join("signing-key.secret"),
            allowed_algorithms: default_algorithms(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RepositoryConfig {
    /// Repository name
    pub name: String,

    /// Repository URL
    pub url: String,

    /// Whether this repository is enabled
    #[serde(default = "default_true")]
    pub enabled: bool,

    /// Priority (lower = higher priority)
    #[serde(default = "default_priority")]
    pub priority: u32,
}

fn default_priority() -> u32 {
    100
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BuildConfig {
    /// Build directory
    pub build_dir: PathBuf,

    /// Cache directory for downloaded sources
    pub cache_dir: PathBuf,

    /// Number of parallel jobs for make
    #[serde(default = "default_jobs")]
    pub jobs: u32,
}

fn default_jobs() -> u32 {
    num_cpus()
}

fn num_cpus() -> u32 {
    std::thread::available_parallelism()
        .map(|p| p.get() as u32)
        .unwrap_or(4)
}

impl Default for BuildConfig {
    fn default() -> Self {
        Self {
            build_dir: PathBuf::from("/var/lib/rookpkg/build"),
            cache_dir: PathBuf::from("/var/lib/rookpkg/cache"),
            jobs: default_jobs(),
        }
    }
}

impl Default for Config {
    fn default() -> Self {
        Self {
            database: DatabaseConfig::default(),
            signing: SigningConfig::default(),
            repositories: vec![],
            build: BuildConfig::default(),
        }
    }
}

impl Config {
    /// Load configuration from file, or use defaults
    pub fn load(path: Option<&Path>) -> Result<Self> {
        let config_path = path
            .map(PathBuf::from)
            .or_else(|| {
                // Try system config
                let system_config = PathBuf::from("/etc/rookpkg/rookpkg.conf");
                if system_config.exists() {
                    return Some(system_config);
                }

                // Try user config
                directories::ProjectDirs::from("org", "rookery", "rookpkg")
                    .map(|d| d.config_dir().join("rookpkg.conf"))
                    .filter(|p| p.exists())
            });

        match config_path {
            Some(path) => {
                let content = std::fs::read_to_string(&path)
                    .with_context(|| format!("Failed to read config: {}", path.display()))?;
                toml::from_str(&content)
                    .with_context(|| format!("Failed to parse config: {}", path.display()))
            }
            None => Ok(Config::default()),
        }
    }

    /// Get the directory for signing keys
    pub fn signing_key_dir(&self) -> &Path {
        self.signing
            .user_signing_key
            .parent()
            .unwrap_or(Path::new("."))
    }
}
