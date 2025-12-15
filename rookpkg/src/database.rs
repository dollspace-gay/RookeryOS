//! SQLite database for package tracking

use std::path::Path;

use anyhow::{Context, Result};
use rusqlite::{Connection, params};

use crate::package::{InstalledPackage, PackageFile, Dependency, DependencyType};

/// Package database
pub struct Database {
    conn: Connection,
}

impl Database {
    /// Open or create the database
    pub fn open(path: &Path) -> Result<Self> {
        // Create parent directory if needed
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }

        let conn = Connection::open(path)
            .with_context(|| format!("Failed to open database: {}", path.display()))?;

        let db = Self { conn };
        db.initialize()?;
        Ok(db)
    }

    /// Open an in-memory database (for testing)
    pub fn open_in_memory() -> Result<Self> {
        let conn = Connection::open_in_memory()?;
        let db = Self { conn };
        db.initialize()?;
        Ok(db)
    }

    /// Initialize the database schema
    fn initialize(&self) -> Result<()> {
        self.conn.execute_batch(
            r#"
            -- Installed packages
            CREATE TABLE IF NOT EXISTS packages (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL UNIQUE,
                version TEXT NOT NULL,
                release INTEGER NOT NULL,
                install_date INTEGER NOT NULL,
                size_bytes INTEGER NOT NULL,
                checksum TEXT NOT NULL,
                spec_file TEXT NOT NULL
            );

            -- Installed files (for conflict detection and removal)
            CREATE TABLE IF NOT EXISTS files (
                id INTEGER PRIMARY KEY,
                package_id INTEGER NOT NULL,
                path TEXT NOT NULL UNIQUE,
                mode INTEGER NOT NULL,
                owner TEXT NOT NULL,
                "group" TEXT NOT NULL,
                size_bytes INTEGER NOT NULL,
                checksum TEXT NOT NULL,
                is_config INTEGER NOT NULL DEFAULT 0,
                FOREIGN KEY (package_id) REFERENCES packages(id) ON DELETE CASCADE
            );

            -- Package dependencies
            CREATE TABLE IF NOT EXISTS dependencies (
                id INTEGER PRIMARY KEY,
                package_id INTEGER NOT NULL,
                depends_on TEXT NOT NULL,
                constraint_spec TEXT NOT NULL,
                dep_type TEXT NOT NULL,
                FOREIGN KEY (package_id) REFERENCES packages(id) ON DELETE CASCADE
            );

            -- Available packages (repository metadata)
            CREATE TABLE IF NOT EXISTS available_packages (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                version TEXT NOT NULL,
                release INTEGER NOT NULL,
                summary TEXT NOT NULL,
                download_url TEXT NOT NULL,
                checksum TEXT NOT NULL,
                last_updated INTEGER NOT NULL,
                UNIQUE(name, version, release)
            );

            -- Trusted signing keys
            CREATE TABLE IF NOT EXISTS trusted_keys (
                id INTEGER PRIMARY KEY,
                fingerprint TEXT NOT NULL UNIQUE,
                public_key TEXT NOT NULL,
                trust_level TEXT NOT NULL,
                name TEXT NOT NULL,
                email TEXT NOT NULL,
                added_date INTEGER NOT NULL,
                added_by TEXT NOT NULL,
                notes TEXT
            );

            -- Revoked keys
            CREATE TABLE IF NOT EXISTS revoked_keys (
                id INTEGER PRIMARY KEY,
                fingerprint TEXT NOT NULL UNIQUE,
                revoked_date INTEGER NOT NULL,
                reason TEXT NOT NULL,
                revoked_by TEXT NOT NULL
            );

            -- Create indices
            CREATE INDEX IF NOT EXISTS idx_files_path ON files(path);
            CREATE INDEX IF NOT EXISTS idx_files_package ON files(package_id);
            CREATE INDEX IF NOT EXISTS idx_deps_package ON dependencies(package_id);
            CREATE INDEX IF NOT EXISTS idx_deps_name ON dependencies(depends_on);
            CREATE INDEX IF NOT EXISTS idx_available_name ON available_packages(name);
            "#,
        )?;

        Ok(())
    }

    /// Add an installed package to the database
    pub fn add_package(&self, pkg: &InstalledPackage) -> Result<i64> {
        self.conn.execute(
            r#"
            INSERT INTO packages (name, version, release, install_date, size_bytes, checksum, spec_file)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            "#,
            params![
                pkg.name,
                pkg.version,
                pkg.release,
                pkg.install_date,
                pkg.size_bytes,
                pkg.checksum,
                pkg.spec,
            ],
        )?;

        Ok(self.conn.last_insert_rowid())
    }

    /// Remove a package from the database
    pub fn remove_package(&self, name: &str) -> Result<bool> {
        let rows = self.conn.execute(
            "DELETE FROM packages WHERE name = ?1",
            params![name],
        )?;

        Ok(rows > 0)
    }

    /// Get an installed package by name
    pub fn get_package(&self, name: &str) -> Result<Option<InstalledPackage>> {
        let mut stmt = self.conn.prepare(
            "SELECT name, version, release, install_date, size_bytes, checksum, spec_file
             FROM packages WHERE name = ?1"
        )?;

        let mut rows = stmt.query(params![name])?;

        if let Some(row) = rows.next()? {
            Ok(Some(InstalledPackage {
                name: row.get(0)?,
                version: row.get(1)?,
                release: row.get(2)?,
                install_date: row.get(3)?,
                size_bytes: row.get(4)?,
                checksum: row.get(5)?,
                spec: row.get(6)?,
            }))
        } else {
            Ok(None)
        }
    }

    /// List all installed packages
    pub fn list_packages(&self) -> Result<Vec<InstalledPackage>> {
        let mut stmt = self.conn.prepare(
            "SELECT name, version, release, install_date, size_bytes, checksum, spec_file
             FROM packages ORDER BY name"
        )?;

        let rows = stmt.query_map([], |row| {
            Ok(InstalledPackage {
                name: row.get(0)?,
                version: row.get(1)?,
                release: row.get(2)?,
                install_date: row.get(3)?,
                size_bytes: row.get(4)?,
                checksum: row.get(5)?,
                spec: row.get(6)?,
            })
        })?;

        rows.collect::<Result<Vec<_>, _>>()
            .context("Failed to list packages")
    }

    /// Add a file to a package
    pub fn add_file(&self, package_id: i64, file: &PackageFile) -> Result<()> {
        self.conn.execute(
            r#"
            INSERT INTO files (package_id, path, mode, owner, "group", size_bytes, checksum, is_config)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            "#,
            params![
                package_id,
                file.path,
                file.mode,
                file.owner,
                file.group,
                file.size_bytes,
                file.checksum,
                file.is_config,
            ],
        )?;

        Ok(())
    }

    /// Get all files for a package
    pub fn get_files(&self, package_name: &str) -> Result<Vec<PackageFile>> {
        let mut stmt = self.conn.prepare(
            r#"
            SELECT f.path, f.mode, f.owner, f."group", f.size_bytes, f.checksum, f.is_config
            FROM files f
            JOIN packages p ON f.package_id = p.id
            WHERE p.name = ?1
            ORDER BY f.path
            "#
        )?;

        let rows = stmt.query_map(params![package_name], |row| {
            Ok(PackageFile {
                path: row.get(0)?,
                mode: row.get(1)?,
                owner: row.get(2)?,
                group: row.get(3)?,
                size_bytes: row.get(4)?,
                checksum: row.get(5)?,
                is_config: row.get(6)?,
            })
        })?;

        rows.collect::<Result<Vec<_>, _>>()
            .context("Failed to get files")
    }

    /// Check if a file path is owned by any package
    pub fn file_owner(&self, path: &str) -> Result<Option<String>> {
        let mut stmt = self.conn.prepare(
            r#"
            SELECT p.name
            FROM files f
            JOIN packages p ON f.package_id = p.id
            WHERE f.path = ?1
            "#
        )?;

        let mut rows = stmt.query(params![path])?;

        if let Some(row) = rows.next()? {
            Ok(Some(row.get(0)?))
        } else {
            Ok(None)
        }
    }

    /// Add a dependency
    pub fn add_dependency(&self, dep: &Dependency) -> Result<()> {
        self.conn.execute(
            r#"
            INSERT INTO dependencies (package_id, depends_on, constraint_spec, dep_type)
            VALUES (?1, ?2, ?3, ?4)
            "#,
            params![
                dep.package_id,
                dep.depends_on,
                dep.constraint,
                dep.dep_type.to_string(),
            ],
        )?;

        Ok(())
    }

    /// Get dependencies for a package
    pub fn get_dependencies(&self, package_name: &str) -> Result<Vec<Dependency>> {
        let mut stmt = self.conn.prepare(
            r#"
            SELECT d.package_id, d.depends_on, d.constraint_spec, d.dep_type
            FROM dependencies d
            JOIN packages p ON d.package_id = p.id
            WHERE p.name = ?1
            "#
        )?;

        let rows = stmt.query_map(params![package_name], |row| {
            let dep_type_str: String = row.get(3)?;
            Ok(Dependency {
                package_id: row.get(0)?,
                depends_on: row.get(1)?,
                constraint: row.get(2)?,
                dep_type: dep_type_str.parse().unwrap_or(DependencyType::Runtime),
            })
        })?;

        rows.collect::<Result<Vec<_>, _>>()
            .context("Failed to get dependencies")
    }

    /// Get reverse dependencies (packages that depend on this one)
    pub fn get_reverse_dependencies(&self, package_name: &str) -> Result<Vec<String>> {
        let mut stmt = self.conn.prepare(
            r#"
            SELECT DISTINCT p.name
            FROM dependencies d
            JOIN packages p ON d.package_id = p.id
            WHERE d.depends_on = ?1
            "#
        )?;

        let rows = stmt.query_map(params![package_name], |row| row.get(0))?;

        rows.collect::<Result<Vec<_>, _>>()
            .context("Failed to get reverse dependencies")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_database_create() {
        let db = Database::open_in_memory().unwrap();
        assert!(db.list_packages().unwrap().is_empty());
    }

    #[test]
    fn test_add_and_get_package() {
        let db = Database::open_in_memory().unwrap();

        let pkg = InstalledPackage {
            name: "test-pkg".to_string(),
            version: "1.0.0".to_string(),
            release: 1,
            install_date: 1234567890,
            size_bytes: 1024,
            checksum: "abc123".to_string(),
            spec: "test spec".to_string(),
        };

        db.add_package(&pkg).unwrap();

        let retrieved = db.get_package("test-pkg").unwrap().unwrap();
        assert_eq!(retrieved.name, "test-pkg");
        assert_eq!(retrieved.version, "1.0.0");
    }
}
