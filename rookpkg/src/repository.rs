//! Repository management for rookpkg
//!
//! Handles remote package repositories, metadata synchronization, and mirror support.
//!
//! ## Repository Structure
//!
//! A repository is a directory (local or remote) containing:
//! - `repo.toml` - Repository metadata (name, description, signing key)
//! - `packages.json` - Package index (all available packages)
//! - `packages.json.sig` - Signature of the package index
//! - `packages/` - Directory containing .rookpkg files
//!
//! ## Repository Format
//!
//! repo.toml:
//! ```toml
//! [repository]
//! name = "rookery-core"
//! description = "Core packages for Rookery OS"
//! version = 1
//!
//! [signing]
//! fingerprint = "HYBRID:SHA256:..."
//! public_key = "path/to/key.pub or inline base64"
//!
//! [[mirrors]]
//! url = "https://packages.rookery.org/core"
//! priority = 1
//! ```

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::config::Config;
use crate::signing::{self, HybridSignature, LoadedPublicKey};

/// Repository metadata from repo.toml
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RepoMetadata {
    /// Repository information
    pub repository: RepositoryInfo,
    /// Signing configuration
    pub signing: RepoSigningInfo,
    /// Mirror list
    #[serde(default)]
    pub mirrors: Vec<Mirror>,
}

/// Basic repository information
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RepositoryInfo {
    /// Repository name (e.g., "rookery-core")
    pub name: String,
    /// Human-readable description
    pub description: String,
    /// Repository format version
    #[serde(default = "default_version")]
    pub version: u32,
    /// Last update timestamp
    #[serde(default)]
    pub updated: Option<DateTime<Utc>>,
}

fn default_version() -> u32 {
    1
}

/// Repository signing configuration
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RepoSigningInfo {
    /// Fingerprint of the signing key
    pub fingerprint: String,
    /// Public key (path or inline base64)
    #[serde(default)]
    pub public_key: Option<String>,
}

/// A repository mirror
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Mirror {
    /// Mirror URL
    pub url: String,
    /// Priority (lower = higher priority)
    #[serde(default = "default_priority")]
    pub priority: u32,
    /// Geographic region (optional, for geo-selection)
    #[serde(default)]
    pub region: Option<String>,
    /// Is this mirror currently enabled?
    #[serde(default = "default_true")]
    pub enabled: bool,
}

fn default_priority() -> u32 {
    100
}

fn default_true() -> bool {
    true
}

/// Package entry in the repository index
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PackageEntry {
    /// Package name
    pub name: String,
    /// Package version
    pub version: String,
    /// Release number
    #[serde(default = "default_release")]
    pub release: u32,
    /// Package description
    pub description: String,
    /// Package architecture (e.g., "x86_64", "noarch")
    #[serde(default = "default_arch")]
    pub arch: String,
    /// Size of the package file in bytes
    pub size: u64,
    /// SHA256 checksum of the package file
    pub sha256: String,
    /// Relative path to the package file
    pub filename: String,
    /// Runtime dependencies
    #[serde(default)]
    pub depends: Vec<String>,
    /// Build dependencies (for source packages)
    #[serde(default)]
    pub build_depends: Vec<String>,
    /// Packages this provides (virtual packages)
    #[serde(default)]
    pub provides: Vec<String>,
    /// Packages this conflicts with
    #[serde(default)]
    pub conflicts: Vec<String>,
    /// Packages this replaces
    #[serde(default)]
    pub replaces: Vec<String>,
    /// Package license
    #[serde(default)]
    pub license: Option<String>,
    /// Package homepage
    #[serde(default)]
    pub homepage: Option<String>,
    /// Package maintainer
    #[serde(default)]
    pub maintainer: Option<String>,
    /// Build date
    #[serde(default)]
    pub build_date: Option<DateTime<Utc>>,
}

fn default_release() -> u32 {
    1
}

fn default_arch() -> String {
    "x86_64".to_string()
}

/// Package index (packages.json)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PackageIndex {
    /// Index format version
    pub version: u32,
    /// When the index was generated
    pub generated: DateTime<Utc>,
    /// Repository name
    pub repository: String,
    /// Package count
    pub count: usize,
    /// All packages in the repository
    pub packages: Vec<PackageEntry>,
}

impl PackageIndex {
    /// Create a new empty package index
    pub fn new(repository: &str) -> Self {
        Self {
            version: 1,
            generated: Utc::now(),
            repository: repository.to_string(),
            count: 0,
            packages: Vec::new(),
        }
    }

    /// Add a package to the index
    pub fn add_package(&mut self, entry: PackageEntry) {
        self.packages.push(entry);
        self.count = self.packages.len();
        self.generated = Utc::now();
    }

    /// Find a package by name
    pub fn find_package(&self, name: &str) -> Option<&PackageEntry> {
        self.packages.iter().find(|p| p.name == name)
    }

    /// Find all versions of a package
    pub fn find_all_versions(&self, name: &str) -> Vec<&PackageEntry> {
        self.packages.iter().filter(|p| p.name == name).collect()
    }

    /// Search packages by name or description
    pub fn search(&self, query: &str) -> Vec<&PackageEntry> {
        let query_lower = query.to_lowercase();
        self.packages
            .iter()
            .filter(|p| {
                p.name.to_lowercase().contains(&query_lower)
                    || p.description.to_lowercase().contains(&query_lower)
            })
            .collect()
    }
}

/// A configured repository
pub struct Repository {
    /// Repository name
    pub name: String,
    /// Repository URL (base URL)
    pub url: String,
    /// Whether this repository is enabled
    pub enabled: bool,
    /// Repository priority (lower = higher priority)
    pub priority: u32,
    /// Local cache directory
    pub cache_dir: PathBuf,
    /// Cached repository metadata
    pub metadata: Option<RepoMetadata>,
    /// Cached package index
    pub index: Option<PackageIndex>,
    /// Repository public key
    pub public_key: Option<LoadedPublicKey>,
}

impl Repository {
    /// Create a new repository from config
    pub fn from_config(
        name: &str,
        url: &str,
        priority: u32,
        enabled: bool,
        cache_base: &Path,
    ) -> Self {
        let cache_dir = cache_base.join("repos").join(name);
        Self {
            name: name.to_string(),
            url: url.to_string(),
            enabled,
            priority,
            cache_dir,
            metadata: None,
            index: None,
            public_key: None,
        }
    }

    /// Check if the repository has cached metadata
    pub fn has_cache(&self) -> bool {
        self.cache_dir.join("repo.toml").exists()
            && self.cache_dir.join("packages.json").exists()
    }

    /// Load cached metadata
    pub fn load_cache(&mut self) -> Result<()> {
        let repo_path = self.cache_dir.join("repo.toml");
        let index_path = self.cache_dir.join("packages.json");

        if repo_path.exists() {
            let content = fs::read_to_string(&repo_path)?;
            self.metadata = Some(toml::from_str(&content)?);
        }

        if index_path.exists() {
            let content = fs::read_to_string(&index_path)?;
            self.index = Some(serde_json::from_str(&content)?);
        }

        Ok(())
    }

    /// Save metadata to cache
    pub fn save_cache(&self) -> Result<()> {
        fs::create_dir_all(&self.cache_dir)?;

        if let Some(ref metadata) = self.metadata {
            let content = toml::to_string_pretty(metadata)?;
            fs::write(self.cache_dir.join("repo.toml"), content)?;
        }

        if let Some(ref index) = self.index {
            let content = serde_json::to_string_pretty(index)?;
            fs::write(self.cache_dir.join("packages.json"), content)?;
        }

        Ok(())
    }

    /// Get the URL for a specific file in the repository
    pub fn file_url(&self, path: &str) -> String {
        format!("{}/{}", self.url.trim_end_matches('/'), path)
    }

    /// Get the URL for the repository metadata
    pub fn metadata_url(&self) -> String {
        self.file_url("repo.toml")
    }

    /// Get the URL for the package index
    pub fn index_url(&self) -> String {
        self.file_url("packages.json")
    }

    /// Get the URL for the package index signature
    pub fn index_sig_url(&self) -> String {
        self.file_url("packages.json.sig")
    }

    /// Get the URL for a package file
    pub fn package_url(&self, entry: &PackageEntry) -> String {
        self.file_url(&entry.filename)
    }
}

/// Repository manager handles all configured repositories
pub struct RepoManager {
    /// Configured repositories
    repos: Vec<Repository>,
    /// HTTP client for fetching
    client: reqwest::blocking::Client,
    /// Cache base directory
    cache_dir: PathBuf,
}

impl RepoManager {
    /// Create a new repository manager from config
    pub fn new(config: &Config) -> Result<Self> {
        let client = reqwest::blocking::Client::builder()
            .timeout(std::time::Duration::from_secs(30))
            .build()?;

        let cache_dir = config.paths.cache_dir.clone();

        let mut repos = Vec::new();
        for repo_config in &config.repositories {
            let repo = Repository::from_config(
                &repo_config.name,
                &repo_config.url,
                repo_config.priority,
                repo_config.enabled,
                &cache_dir,
            );
            repos.push(repo);
        }

        // Sort by priority
        repos.sort_by_key(|r| r.priority);

        Ok(Self {
            repos,
            client,
            cache_dir,
        })
    }

    /// Get all enabled repositories
    pub fn enabled_repos(&self) -> impl Iterator<Item = &Repository> {
        self.repos.iter().filter(|r| r.enabled)
    }

    /// Get a repository by name
    pub fn get_repo(&self, name: &str) -> Option<&Repository> {
        self.repos.iter().find(|r| r.name == name)
    }

    /// Get a mutable repository by name
    pub fn get_repo_mut(&mut self, name: &str) -> Option<&mut Repository> {
        self.repos.iter_mut().find(|r| r.name == name)
    }

    /// Update all enabled repositories
    pub fn update_all(&mut self, config: &Config) -> Result<UpdateResult> {
        let mut result = UpdateResult::default();

        // Collect indices of enabled repos to avoid borrow issues
        let enabled_indices: Vec<usize> = self
            .repos
            .iter()
            .enumerate()
            .filter(|(_, r)| r.enabled)
            .map(|(i, _)| i)
            .collect();

        for idx in enabled_indices {
            let repo_name = self.repos[idx].name.clone();
            match self.update_repo_by_index(idx, config) {
                Ok(updated) => {
                    if updated {
                        result.updated.push(repo_name);
                    } else {
                        result.unchanged.push(repo_name);
                    }
                }
                Err(e) => {
                    result.failed.push((repo_name, e.to_string()));
                }
            }
        }

        Ok(result)
    }

    /// Update a repository by index
    fn update_repo_by_index(&mut self, idx: usize, config: &Config) -> Result<bool> {
        let repo = &self.repos[idx];
        let name = repo.name.clone();
        let metadata_url = repo.metadata_url();
        let index_url = repo.index_url();
        let sig_url = repo.index_sig_url();

        tracing::info!("Updating repository: {}", name);

        // Fetch repository metadata
        let metadata_response = self.client.get(&metadata_url).send()?;

        if !metadata_response.status().is_success() {
            bail!(
                "Failed to fetch repository metadata: HTTP {}",
                metadata_response.status()
            );
        }

        let metadata_content = metadata_response.text()?;
        let metadata: RepoMetadata = toml::from_str(&metadata_content)?;

        // Fetch package index
        let index_response = self.client.get(&index_url).send()?;

        if !index_response.status().is_success() {
            bail!(
                "Failed to fetch package index: HTTP {}",
                index_response.status()
            );
        }

        let index_content = index_response.text()?;

        // Fetch and verify signature
        let sig_response = self.client.get(&sig_url).send()?;

        let public_key = if sig_response.status().is_success() {
            let sig_content = sig_response.text()?;
            let signature: HybridSignature = serde_json::from_str(&sig_content)?;

            // Find the public key
            let public_key = self.find_repo_key(&metadata.signing.fingerprint, config)?;

            // Verify the signature
            signing::verify_signature(&public_key, index_content.as_bytes(), &signature)
                .context("Package index signature verification failed")?;

            tracing::info!("Package index signature verified");
            Some(public_key)
        } else if !config.signing.allow_untrusted {
            bail!("Package index signature not found and untrusted repositories are not allowed");
        } else {
            tracing::warn!("Package index signature not found, proceeding without verification");
            None
        };

        // Parse the index
        let index: PackageIndex = serde_json::from_str(&index_content)?;

        // Check if anything changed
        let repo = &self.repos[idx];
        let changed = repo
            .index
            .as_ref()
            .map(|i| i.generated != index.generated)
            .unwrap_or(true);

        // Update repo state
        let repo = &mut self.repos[idx];
        repo.metadata = Some(metadata);
        repo.index = Some(index);
        repo.public_key = public_key;

        // Save to cache
        repo.save_cache()?;

        Ok(changed)
    }

    /// Find a repository signing key
    fn find_repo_key(&self, fingerprint: &str, config: &Config) -> Result<LoadedPublicKey> {
        // Search in master keys
        let master_dir = &config.signing.master_keys_dir;
        if let Some(key) = self.search_key_in_dir(master_dir, fingerprint)? {
            return Ok(key);
        }

        // Search in packager keys
        let packager_dir = &config.signing.packager_keys_dir;
        if let Some(key) = self.search_key_in_dir(packager_dir, fingerprint)? {
            return Ok(key);
        }

        bail!(
            "Repository signing key not found: {}\n\
            Add the repository's public key with: rookpkg keytrust <key.pub>",
            fingerprint
        );
    }

    /// Search for a key in a directory
    fn search_key_in_dir(
        &self,
        dir: &Path,
        fingerprint: &str,
    ) -> Result<Option<LoadedPublicKey>> {
        if !dir.exists() {
            return Ok(None);
        }

        for entry in fs::read_dir(dir)? {
            let entry = entry?;
            let path = entry.path();
            if path.extension().map(|e| e == "pub").unwrap_or(false) {
                if let Ok(key) = signing::load_public_key(&path) {
                    if key.fingerprint == fingerprint
                        || key.fingerprint.ends_with(fingerprint)
                        || fingerprint.ends_with(&key.fingerprint)
                    {
                        return Ok(Some(key));
                    }
                }
            }
        }

        Ok(None)
    }

    /// Search for packages across all enabled repositories
    pub fn search(&self, query: &str) -> Vec<SearchResult> {
        let mut results = Vec::new();

        for repo in self.enabled_repos() {
            if let Some(ref index) = repo.index {
                for entry in index.search(query) {
                    results.push(SearchResult {
                        repository: repo.name.clone(),
                        package: entry.clone(),
                    });
                }
            }
        }

        // Sort by name, then by repository priority
        results.sort_by(|a, b| {
            a.package
                .name
                .cmp(&b.package.name)
                .then_with(|| a.repository.cmp(&b.repository))
        });

        results
    }

    /// Find a package by name across all enabled repositories
    pub fn find_package(&self, name: &str) -> Option<SearchResult> {
        for repo in self.enabled_repos() {
            if let Some(ref index) = repo.index {
                if let Some(entry) = index.find_package(name) {
                    return Some(SearchResult {
                        repository: repo.name.clone(),
                        package: entry.clone(),
                    });
                }
            }
        }
        None
    }

    /// Load cached data for all repositories
    pub fn load_caches(&mut self) -> Result<()> {
        for repo in &mut self.repos {
            if repo.has_cache() {
                let _ = repo.load_cache(); // Ignore errors, just use what we can
            }
        }
        Ok(())
    }
}

/// Result of a repository update operation
#[derive(Debug, Default)]
pub struct UpdateResult {
    /// Repositories that were updated
    pub updated: Vec<String>,
    /// Repositories that were unchanged
    pub unchanged: Vec<String>,
    /// Repositories that failed to update
    pub failed: Vec<(String, String)>,
}

impl UpdateResult {
    /// Check if all updates succeeded
    pub fn all_success(&self) -> bool {
        self.failed.is_empty()
    }

    /// Get total number of repositories processed
    pub fn total(&self) -> usize {
        self.updated.len() + self.unchanged.len() + self.failed.len()
    }
}

/// A search result from repository search
#[derive(Debug, Clone)]
pub struct SearchResult {
    /// Repository the package was found in
    pub repository: String,
    /// Package entry
    pub package: PackageEntry,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_package_index_search() {
        let mut index = PackageIndex::new("test");

        index.add_package(PackageEntry {
            name: "bash".to_string(),
            version: "5.2".to_string(),
            release: 1,
            description: "The GNU Bourne Again shell".to_string(),
            arch: "x86_64".to_string(),
            size: 1234567,
            sha256: "abc123".to_string(),
            filename: "packages/bash-5.2-1.x86_64.rookpkg".to_string(),
            depends: vec!["glibc".to_string()],
            build_depends: vec![],
            provides: vec!["sh".to_string()],
            conflicts: vec![],
            replaces: vec![],
            license: Some("GPL-3.0".to_string()),
            homepage: Some("https://www.gnu.org/software/bash/".to_string()),
            maintainer: Some("Rookery Maintainers".to_string()),
            build_date: Some(Utc::now()),
        });

        index.add_package(PackageEntry {
            name: "zsh".to_string(),
            version: "5.9".to_string(),
            release: 1,
            description: "The Z shell".to_string(),
            arch: "x86_64".to_string(),
            size: 2345678,
            sha256: "def456".to_string(),
            filename: "packages/zsh-5.9-1.x86_64.rookpkg".to_string(),
            depends: vec!["glibc".to_string()],
            build_depends: vec![],
            provides: vec!["sh".to_string()],
            conflicts: vec![],
            replaces: vec![],
            license: Some("MIT".to_string()),
            homepage: Some("https://www.zsh.org/".to_string()),
            maintainer: Some("Rookery Maintainers".to_string()),
            build_date: Some(Utc::now()),
        });

        // Search by name
        let results = index.search("bash");
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].name, "bash");

        // Search by description
        let results = index.search("shell");
        assert_eq!(results.len(), 2);

        // Find specific package
        let pkg = index.find_package("zsh");
        assert!(pkg.is_some());
        assert_eq!(pkg.unwrap().version, "5.9");
    }
}
