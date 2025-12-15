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
                self.do_upgrade(package, archive_path)?;
            }
        }
        Ok(())
    }

    /// Perform package installation
    fn do_install(&mut self, archive_path: &Path) -> Result<()> {
        let reader = PackageArchiveReader::open(archive_path)?;
        let info = reader.read_info()?;
        let files = reader.read_files()?;
        let scripts = reader.read_scripts()?;

        // Run pre_install script if present
        if let Some(ref scripts) = scripts {
            if !scripts.pre_install.is_empty() {
                tracing::info!("Running pre_install script for {}", info.name);
                self.run_script(&info.name, "pre_install", &scripts.pre_install)?;
            }
        }

        // Check for file conflicts with other packages
        for file_entry in &files {
            if let Some(owner) = self.db.file_owner(&file_entry.path)? {
                if owner != info.name {
                    bail!(
                        "File conflict: {} is already owned by package '{}'",
                        file_entry.path,
                        owner
                    );
                }
            }
        }

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

        // Add dependencies to database
        for (dep_name, constraint) in &info.depends {
            let dep = crate::package::Dependency {
                package_id: pkg_id,
                depends_on: dep_name.clone(),
                constraint: constraint.clone(),
                dep_type: crate::package::DependencyType::Runtime,
            };
            self.db.add_dependency(&dep)?;
        }

        // Save scripts for later use (removal, upgrade)
        if let Some(ref scripts) = scripts {
            self.save_package_scripts(&info.name, scripts)?;
        }

        // Run post_install script if present
        if let Some(ref scripts) = scripts {
            if !scripts.post_install.is_empty() {
                tracing::info!("Running post_install script for {}", info.name);
                self.run_script(&info.name, "post_install", &scripts.post_install)?;
            }
        }

        self.save_journal()?;
        Ok(())
    }

    /// Save package scripts to persistent storage for removal/upgrade
    fn save_package_scripts(&self, package: &str, scripts: &crate::archive::InstallScripts) -> Result<()> {
        let scripts_dir = self.root.join("var/lib/rookpkg/scripts").join(package);
        fs::create_dir_all(&scripts_dir)?;

        // Save each script explicitly - verbose style to ensure all are handled
        if !scripts.pre_install.is_empty() {
            fs::write(scripts_dir.join("pre_install.sh"), &scripts.pre_install)?;
        }

        if !scripts.post_install.is_empty() {
            fs::write(scripts_dir.join("post_install.sh"), &scripts.post_install)?;
        }

        if !scripts.pre_remove.is_empty() {
            fs::write(scripts_dir.join("pre_remove.sh"), &scripts.pre_remove)?;
        }

        if !scripts.post_remove.is_empty() {
            fs::write(scripts_dir.join("post_remove.sh"), &scripts.post_remove)?;
        }

        if !scripts.pre_upgrade.is_empty() {
            fs::write(scripts_dir.join("pre_upgrade.sh"), &scripts.pre_upgrade)?;
        }

        if !scripts.post_upgrade.is_empty() {
            fs::write(scripts_dir.join("post_upgrade.sh"), &scripts.post_upgrade)?;
        }

        Ok(())
    }

    /// Load a saved script for a package
    fn load_package_script(&self, package: &str, script_name: &str) -> Option<String> {
        let script_path = self.root
            .join("var/lib/rookpkg/scripts")
            .join(package)
            .join(format!("{}.sh", script_name));

        fs::read_to_string(&script_path).ok()
    }

    /// Remove saved scripts for a package
    fn remove_package_scripts(&self, package: &str) -> Result<()> {
        let scripts_dir = self.root.join("var/lib/rookpkg/scripts").join(package);
        if scripts_dir.exists() {
            fs::remove_dir_all(&scripts_dir)?;
        }
        Ok(())
    }

    /// Perform package upgrade
    fn do_upgrade(&mut self, package: &str, archive_path: &Path) -> Result<()> {
        // Load pre_upgrade script from existing installation
        let pre_upgrade_script = self.load_package_script(package, "pre_upgrade");

        // Run pre_upgrade script if present (from OLD package)
        if let Some(ref script) = pre_upgrade_script {
            if !script.is_empty() {
                tracing::info!("Running pre_upgrade script for {}", package);
                self.run_script(package, "pre_upgrade", script)?;
            }
        }

        // Get the new package's scripts before removal
        let reader = PackageArchiveReader::open(archive_path)?;
        let new_scripts = reader.read_scripts()?;

        // Remove old package (but don't run pre_remove/post_remove - we run upgrade scripts instead)
        self.do_remove_for_upgrade(package)?;

        // Install new package (but don't run pre_install/post_install - we run upgrade scripts instead)
        self.do_install_for_upgrade(archive_path)?;

        // Run post_upgrade script if present (from NEW package)
        if let Some(ref scripts) = new_scripts {
            if !scripts.post_upgrade.is_empty() {
                tracing::info!("Running post_upgrade script for {}", package);
                self.run_script(package, "post_upgrade", &scripts.post_upgrade)?;
            }
        }

        Ok(())
    }

    /// Remove package for upgrade (skips pre_remove/post_remove scripts)
    fn do_remove_for_upgrade(&mut self, package: &str) -> Result<()> {
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

        // Remove saved scripts (new ones will be saved during install)
        self.remove_package_scripts(package)?;

        self.save_journal()?;
        Ok(())
    }

    /// Install package for upgrade (skips pre_install/post_install scripts)
    fn do_install_for_upgrade(&mut self, archive_path: &Path) -> Result<()> {
        let reader = PackageArchiveReader::open(archive_path)?;
        let info = reader.read_info()?;
        let files = reader.read_files()?;
        let scripts = reader.read_scripts()?;

        // Check for file conflicts with other packages
        for file_entry in &files {
            if let Some(owner) = self.db.file_owner(&file_entry.path)? {
                if owner != info.name {
                    bail!(
                        "File conflict: {} is already owned by package '{}'",
                        file_entry.path,
                        owner
                    );
                }
            }
        }

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
            checksum: String::new(),
            spec: String::new(),
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

        // Add dependencies to database
        for (dep_name, constraint) in &info.depends {
            let dep = crate::package::Dependency {
                package_id: pkg_id,
                depends_on: dep_name.clone(),
                constraint: constraint.clone(),
                dep_type: crate::package::DependencyType::Runtime,
            };
            self.db.add_dependency(&dep)?;
        }

        // Save scripts for later use (removal, upgrade)
        if let Some(ref scripts) = scripts {
            self.save_package_scripts(&info.name, scripts)?;
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

        // Run pre_remove script if present
        if let Some(script) = self.load_package_script(package, "pre_remove") {
            if !script.is_empty() {
                tracing::info!("Running pre_remove script for {}", package);
                self.run_script(package, "pre_remove", &script)?;
            }
        }

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

        // Run post_remove script if present
        if let Some(script) = self.load_package_script(package, "post_remove") {
            if !script.is_empty() {
                tracing::info!("Running post_remove script for {}", package);
                self.run_script(package, "post_remove", &script)?;
            }
        }

        // Remove saved scripts
        self.remove_package_scripts(package)?;

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

    /// Run an install script
    fn run_script(&self, package: &str, script_name: &str, script_content: &str) -> Result<()> {
        use std::io::Write;
        use std::process::Command;

        if script_content.trim().is_empty() {
            return Ok(());
        }

        // Create a temporary script file
        let script_dir = self.tx_dir.join("scripts").join(package);
        fs::create_dir_all(&script_dir)?;

        let script_path = script_dir.join(format!("{}.sh", script_name));
        let mut script_file = fs::File::create(&script_path)?;

        // Write script with proper shebang
        writeln!(script_file, "#!/bin/bash")?;
        writeln!(script_file, "set -e")?;
        writeln!(script_file, "# {} script for {}", script_name, package)?;
        writeln!(script_file)?;
        write!(script_file, "{}", script_content)?;
        writeln!(script_file)?;

        drop(script_file);

        // Make executable
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = fs::metadata(&script_path)?.permissions();
            perms.set_mode(0o755);
            fs::set_permissions(&script_path, perms)?;
        }

        // Execute the script
        let output = Command::new("/bin/bash")
            .arg(&script_path)
            .current_dir(&self.root)
            .env("ROOKPKG_ROOT", &self.root)
            .env("ROOKPKG_PACKAGE", package)
            .env("ROOKPKG_SCRIPT", script_name)
            .output()
            .with_context(|| format!("Failed to execute {} script for {}", script_name, package))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            let stdout = String::from_utf8_lossy(&output.stdout);
            tracing::error!("{} script failed for {}", script_name, package);
            tracing::error!("stdout: {}", stdout);
            tracing::error!("stderr: {}", stderr);
            bail!(
                "{} script failed for {}: {}",
                script_name,
                package,
                stderr.lines().next().unwrap_or("unknown error")
            );
        }

        tracing::info!("{} script completed successfully for {}", script_name, package);
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

    #[test]
    fn test_transaction_builder() {
        use tempfile::tempdir;

        let temp_dir = tempdir().unwrap();
        let root = temp_dir.path();

        // Create a TransactionBuilder and queue operations
        let builder = TransactionBuilder::new(root);

        // Add some operations using the builder pattern
        let archive = root.join("test.rookpkg");
        let builder = builder
            .install("foo", "1.0.0", &archive)
            .install("bar", "2.0.0", &archive)
            .remove("baz")
            .upgrade("qux", "1.0.0", "2.0.0", &archive);

        // Verify operations are queued (we can't execute without real db/archives)
        assert_eq!(builder.operations.len(), 4);

        // Test operation names
        assert_eq!(builder.operations[0].package_name(), "foo");
        assert_eq!(builder.operations[1].package_name(), "bar");
        assert_eq!(builder.operations[2].package_name(), "baz");
        assert_eq!(builder.operations[3].package_name(), "qux");
    }
}
