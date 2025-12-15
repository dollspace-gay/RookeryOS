//! Atomic installation transactions
//!
//! Ensures package installations, removals, and upgrades are atomic.
//! Uses a journal-based approach to allow rollback on failure.

use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};

use crate::archive::PackageArchiveReader;
use crate::database::Database;
use crate::package::{InstalledPackage, PackageFile};

/// Transaction state
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TransactionState {
    /// Transaction has been created but not started
    Pending,
    /// Transaction is in progress
    InProgress,
    /// Transaction completed successfully
    Completed,
    /// Transaction failed and was rolled back
    RolledBack,
    /// Transaction failed and rollback also failed (manual intervention needed)
    Failed,
}

/// A single operation within a transaction
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum Operation {
    /// Install a new package
    Install {
        package: String,
        version: String,
        archive_path: PathBuf,
    },
    /// Remove an existing package
    Remove {
        package: String,
    },
    /// Upgrade a package (remove old, install new)
    Upgrade {
        package: String,
        old_version: String,
        new_version: String,
        archive_path: PathBuf,
    },
}

impl Operation {
    pub fn package_name(&self) -> &str {
        match self {
            Operation::Install { package, .. } => package,
            Operation::Remove { package } => package,
            Operation::Upgrade { package, .. } => package,
        }
    }
}

/// Journal entry for tracking file operations
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum JournalEntry {
    /// A file was created
    FileCreated { path: PathBuf },
    /// A file was removed (with backup path)
    FileRemoved { path: PathBuf, backup: PathBuf },
    /// A file was modified (with backup path)
    FileModified { path: PathBuf, backup: PathBuf },
    /// A directory was created
    DirCreated { path: PathBuf },
    /// Database entry was added
    DbPackageAdded { package: String },
    /// Database entry was removed (with backup data)
    DbPackageRemoved { package: String, backup_data: String },
}

/// An atomic transaction for package operations
pub struct Transaction {
    /// Unique transaction ID
    id: String,
    /// Current state
    state: TransactionState,
    /// Operations to perform
    operations: Vec<Operation>,
    /// Journal of completed actions (for rollback)
    journal: Vec<JournalEntry>,
    /// Root filesystem path
    root: PathBuf,
    /// Transaction directory (for backups and journal)
    tx_dir: PathBuf,
    /// Database connection
    db: Database,
}

impl Transaction {
    /// Create a new transaction
    pub fn new(root: &Path, db: Database) -> Result<Self> {
        let id = format!("{}", chrono::Utc::now().format("%Y%m%d%H%M%S%f"));
        let tx_dir = root.join("var/lib/rookpkg/transactions").join(&id);
        fs::create_dir_all(&tx_dir)?;

        let tx = Self {
            id,
            state: TransactionState::Pending,
            operations: Vec::new(),
            journal: Vec::new(),
            root: root.to_path_buf(),
            tx_dir,
            db,
        };

        tx.save_state()?;
        Ok(tx)
    }

    /// Resume an incomplete transaction
    pub fn resume(root: &Path, tx_id: &str, db: Database) -> Result<Self> {
        let tx_dir = root.join("var/lib/rookpkg/transactions").join(tx_id);
        if !tx_dir.exists() {
            bail!("Transaction {} not found", tx_id);
        }

        let state_file = tx_dir.join("state.toml");
        let state_content = fs::read_to_string(&state_file)?;
        let state: TransactionState = toml::from_str(&state_content)?;

        let ops_file = tx_dir.join("operations.toml");
        let operations: Vec<Operation> = if ops_file.exists() {
            let ops_content = fs::read_to_string(&ops_file)?;
            toml::from_str(&ops_content)?
        } else {
            Vec::new()
        };

        let journal_file = tx_dir.join("journal.toml");
        let journal: Vec<JournalEntry> = if journal_file.exists() {
            let journal_content = fs::read_to_string(&journal_file)?;
            toml::from_str(&journal_content)?
        } else {
            Vec::new()
        };

        Ok(Self {
            id: tx_id.to_string(),
            state,
            operations,
            journal,
            root: root.to_path_buf(),
            tx_dir,
            db,
        })
    }

    /// Add an install operation
    pub fn install(&mut self, package: &str, version: &str, archive_path: &Path) -> &mut Self {
        self.operations.push(Operation::Install {
            package: package.to_string(),
            version: version.to_string(),
            archive_path: archive_path.to_path_buf(),
        });
        self
    }

    /// Add a remove operation
    pub fn remove(&mut self, package: &str) -> &mut Self {
        self.operations.push(Operation::Remove {
            package: package.to_string(),
        });
        self
    }

    /// Add an upgrade operation
    pub fn upgrade(
        &mut self,
        package: &str,
        old_version: &str,
        new_version: &str,
        archive_path: &Path,
    ) -> &mut Self {
        self.operations.push(Operation::Upgrade {
            package: package.to_string(),
            old_version: old_version.to_string(),
            new_version: new_version.to_string(),
            archive_path: archive_path.to_path_buf(),
        });
        self
    }

    /// Execute the transaction
    pub fn execute(&mut self) -> Result<()> {
        if self.state != TransactionState::Pending {
            bail!("Transaction already executed (state: {:?})", self.state);
        }

        self.state = TransactionState::InProgress;
        self.save_state()?;

        // Execute each operation
        for i in 0..self.operations.len() {
            let op = self.operations[i].clone();
            if let Err(e) = self.execute_operation(&op) {
                tracing::error!("Operation failed: {}", e);
                if let Err(rollback_err) = self.rollback() {
                    tracing::error!("Rollback failed: {}", rollback_err);
                    self.state = TransactionState::Failed;
                    self.save_state()?;
                    bail!(
                        "Transaction failed and rollback failed: {} (rollback: {})",
                        e,
                        rollback_err
                    );
                }
                self.state = TransactionState::RolledBack;
                self.save_state()?;
                bail!("Transaction rolled back due to: {}", e);
            }
        }

        self.state = TransactionState::Completed;
        self.save_state()?;
        self.cleanup()?;

        Ok(())
    }

    /// Execute a single operation
    fn execute_operation(&mut self, op: &Operation) -> Result<()> {
        match op {
            Operation::Install {
                package,
                version,
                archive_path,
            } => {
                tracing::info!("Installing {} {}", package, version);
                self.do_install(archive_path)?;
            }
            Operation::Remove { package } => {
                tracing::info!("Removing {}", package);
                self.do_remove(package)?;
            }
            Operation::Upgrade {
                package,
                old_version,
                new_version,
                archive_path,
            } => {
                tracing::info!("Upgrading {} {} -> {}", package, old_version, new_version);
                self.do_remove(package)?;
                self.do_install(archive_path)?;
            }
        }
        Ok(())
    }

    /// Perform package installation
    fn do_install(&mut self, archive_path: &Path) -> Result<()> {
        let reader = PackageArchiveReader::open(archive_path)?;
        let info = reader.read_info()?;
        let files = reader.read_files()?;

        // Create backup directory for this package
        let backup_dir = self.tx_dir.join("backup").join(&info.name);
        fs::create_dir_all(&backup_dir)?;

        // Extract files
        let extract_dir = self.tx_dir.join("extract").join(&info.name);
        reader.extract_data(&extract_dir)?;

        // Install files to root
        for file_entry in &files {
            let src = extract_dir.join(file_entry.path.trim_start_matches('/'));
            let dest = self.root.join(file_entry.path.trim_start_matches('/'));

            // Backup existing file if it exists
            if dest.exists() {
                let backup = backup_dir.join(file_entry.path.trim_start_matches('/'));
                if let Some(parent) = backup.parent() {
                    fs::create_dir_all(parent)?;
                }
                fs::copy(&dest, &backup)?;
                self.journal.push(JournalEntry::FileModified {
                    path: dest.clone(),
                    backup,
                });
            }

            // Create parent directories
            if let Some(parent) = dest.parent() {
                if !parent.exists() {
                    fs::create_dir_all(parent)?;
                    self.journal.push(JournalEntry::DirCreated {
                        path: parent.to_path_buf(),
                    });
                }
            }

            // Copy file
            if src.is_dir() {
                if !dest.exists() {
                    fs::create_dir_all(&dest)?;
                    self.journal.push(JournalEntry::DirCreated { path: dest });
                }
            } else if src.exists() {
                fs::copy(&src, &dest).with_context(|| {
                    format!("Failed to copy {} to {}", src.display(), dest.display())
                })?;
                self.journal.push(JournalEntry::FileCreated { path: dest });
            }
        }

        // Add to database
        let pkg = InstalledPackage {
            name: info.name.clone(),
            version: info.version.clone(),
            release: info.release,
            install_date: chrono::Utc::now().timestamp(),
            size_bytes: info.installed_size,
            checksum: String::new(), // TODO: compute package checksum
            spec: String::new(), // TODO: store original spec
        };
        let pkg_id = self.db.add_package(&pkg)?;
        self.journal.push(JournalEntry::DbPackageAdded {
            package: info.name.clone(),
        });

        // Add files to database
        for file_entry in &files {
            let pkg_file = PackageFile {
                path: file_entry.path.clone(),
                mode: file_entry.mode,
                owner: "root".to_string(),
                group: "root".to_string(),
                size_bytes: file_entry.size,
                checksum: file_entry.sha256.clone(),
                is_config: file_entry.is_config,
            };
            self.db.add_file(pkg_id, &pkg_file)?;
        }

        self.save_journal()?;
        Ok(())
    }

    /// Perform package removal
    fn do_remove(&mut self, package: &str) -> Result<()> {
        // Get package info from database
        let pkg = self.db.get_package(package)?;
        if pkg.is_none() {
            bail!("Package {} is not installed", package);
        }
        let pkg = pkg.unwrap();

        // Create backup
        let backup_dir = self.tx_dir.join("backup").join(package);
        fs::create_dir_all(&backup_dir)?;

        // Backup package data
        let backup_data = toml::to_string(&pkg)?;
        self.journal.push(JournalEntry::DbPackageRemoved {
            package: package.to_string(),
            backup_data,
        });

        // Get files to remove
        let files = self.db.get_files(package)?;
        let mut dirs_to_check: HashSet<PathBuf> = HashSet::new();

        // Remove files (in reverse order to handle nested paths)
        let mut file_paths: Vec<_> = files.iter().map(|f| f.path.clone()).collect();
        file_paths.sort();
        file_paths.reverse();

        for path in file_paths {
            let full_path = self.root.join(path.trim_start_matches('/'));

            if full_path.is_file() {
                // Backup the file
                let backup = backup_dir.join(path.trim_start_matches('/'));
                if let Some(parent) = backup.parent() {
                    fs::create_dir_all(parent)?;
                }
                fs::copy(&full_path, &backup)?;

                // Remove the file
                fs::remove_file(&full_path)?;
                self.journal.push(JournalEntry::FileRemoved {
                    path: full_path.clone(),
                    backup,
                });

                // Track parent directory for cleanup
                if let Some(parent) = full_path.parent() {
                    dirs_to_check.insert(parent.to_path_buf());
                }
            }
        }

        // Remove empty directories (be careful not to remove important system dirs)
        let protected_dirs: HashSet<PathBuf> = [
            "/", "/bin", "/etc", "/lib", "/lib64", "/opt", "/root", "/sbin",
            "/usr", "/usr/bin", "/usr/lib", "/usr/lib64", "/usr/sbin",
            "/usr/share", "/usr/include", "/var", "/var/lib", "/var/log",
        ]
        .iter()
        .map(|p| self.root.join(p.trim_start_matches('/')))
        .collect();

        let mut dirs_vec: Vec<_> = dirs_to_check.into_iter().collect();
        dirs_vec.sort();
        dirs_vec.reverse();

        for dir in dirs_vec {
            if !protected_dirs.contains(&dir) && dir.is_dir() {
                if fs::read_dir(&dir)?.next().is_none() {
                    fs::remove_dir(&dir).ok();
                }
            }
        }

        // Remove from database
        self.db.remove_package(package)?;

        self.save_journal()?;
        Ok(())
    }

    /// Rollback the transaction
    fn rollback(&mut self) -> Result<()> {
        tracing::warn!("Rolling back transaction {}", self.id);

        // Process journal entries in reverse order
        for entry in self.journal.iter().rev() {
            match entry {
                JournalEntry::FileCreated { path } => {
                    if path.exists() {
                        fs::remove_file(path).ok();
                    }
                }
                JournalEntry::FileRemoved { path, backup } => {
                    if backup.exists() {
                        if let Some(parent) = path.parent() {
                            fs::create_dir_all(parent).ok();
                        }
                        fs::copy(backup, path).ok();
                    }
                }
                JournalEntry::FileModified { path, backup } => {
                    if backup.exists() {
                        fs::copy(backup, path).ok();
                    }
                }
                JournalEntry::DirCreated { path } => {
                    // Only remove if empty
                    if path.is_dir() {
                        fs::remove_dir(path).ok();
                    }
                }
                JournalEntry::DbPackageAdded { package } => {
                    self.db.remove_package(package).ok();
                }
                JournalEntry::DbPackageRemoved {
                    package: _,
                    backup_data,
                } => {
                    if let Ok(pkg) = toml::from_str::<InstalledPackage>(backup_data) {
                        self.db.add_package(&pkg).ok();
                    }
                }
            }
        }

        Ok(())
    }

    /// Save transaction state to disk
    fn save_state(&self) -> Result<()> {
        let state_file = self.tx_dir.join("state.toml");
        let content = toml::to_string(&self.state)?;
        fs::write(&state_file, content)?;

        let ops_file = self.tx_dir.join("operations.toml");
        let ops_content = toml::to_string(&self.operations)?;
        fs::write(&ops_file, ops_content)?;

        Ok(())
    }

    /// Save journal to disk
    fn save_journal(&self) -> Result<()> {
        let journal_file = self.tx_dir.join("journal.toml");
        let content = toml::to_string(&self.journal)?;
        fs::write(&journal_file, content)?;
        Ok(())
    }

    /// Clean up transaction files after success
    fn cleanup(&self) -> Result<()> {
        fs::remove_dir_all(&self.tx_dir).ok();
        Ok(())
    }

    /// Get transaction ID
    pub fn id(&self) -> &str {
        &self.id
    }

    /// Get transaction state
    pub fn state(&self) -> TransactionState {
        self.state
    }

    /// List pending transactions
    pub fn list_pending(root: &Path) -> Result<Vec<String>> {
        let tx_dir = root.join("var/lib/rookpkg/transactions");
        if !tx_dir.exists() {
            return Ok(Vec::new());
        }

        let mut pending = Vec::new();
        for entry in fs::read_dir(&tx_dir)? {
            let entry = entry?;
            if entry.file_type()?.is_dir() {
                let state_file = entry.path().join("state.toml");
                if state_file.exists() {
                    let content = fs::read_to_string(&state_file)?;
                    if let Ok(state) = toml::from_str::<TransactionState>(&content) {
                        if state == TransactionState::InProgress {
                            pending.push(entry.file_name().to_string_lossy().to_string());
                        }
                    }
                }
            }
        }

        Ok(pending)
    }
}

/// Transaction builder for convenient transaction creation
pub struct TransactionBuilder {
    root: PathBuf,
    operations: Vec<Operation>,
}

impl TransactionBuilder {
    /// Create a new transaction builder
    pub fn new(root: &Path) -> Self {
        Self {
            root: root.to_path_buf(),
            operations: Vec::new(),
        }
    }

    /// Add an install operation
    pub fn install(mut self, package: &str, version: &str, archive: &Path) -> Self {
        self.operations.push(Operation::Install {
            package: package.to_string(),
            version: version.to_string(),
            archive_path: archive.to_path_buf(),
        });
        self
    }

    /// Add a remove operation
    pub fn remove(mut self, package: &str) -> Self {
        self.operations.push(Operation::Remove {
            package: package.to_string(),
        });
        self
    }

    /// Add an upgrade operation
    pub fn upgrade(mut self, package: &str, old_ver: &str, new_ver: &str, archive: &Path) -> Self {
        self.operations.push(Operation::Upgrade {
            package: package.to_string(),
            old_version: old_ver.to_string(),
            new_version: new_ver.to_string(),
            archive_path: archive.to_path_buf(),
        });
        self
    }

    /// Build and execute the transaction
    pub fn execute(self, db: Database) -> Result<()> {
        let mut tx = Transaction::new(&self.root, db)?;
        for op in self.operations {
            match op {
                Operation::Install {
                    package,
                    version,
                    archive_path,
                } => {
                    tx.install(&package, &version, &archive_path);
                }
                Operation::Remove { package } => {
                    tx.remove(&package);
                }
                Operation::Upgrade {
                    package,
                    old_version,
                    new_version,
                    archive_path,
                } => {
                    tx.upgrade(&package, &old_version, &new_version, &archive_path);
                }
            }
        }
        tx.execute()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_operation_package_name() {
        let install = Operation::Install {
            package: "foo".to_string(),
            version: "1.0".to_string(),
            archive_path: PathBuf::from("/tmp/foo.rookpkg"),
        };
        assert_eq!(install.package_name(), "foo");

        let remove = Operation::Remove {
            package: "bar".to_string(),
        };
        assert_eq!(remove.package_name(), "bar");
    }

    #[test]
    fn test_transaction_state_serialization() {
        let state = TransactionState::InProgress;
        let serialized = toml::to_string(&state).unwrap();
        let deserialized: TransactionState = toml::from_str(&serialized).unwrap();
        assert_eq!(state, deserialized);
    }
}
