//! Package types and operations

use serde::{Deserialize, Serialize};

/// An installed package
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InstalledPackage {
    /// Package name
    pub name: String,

    /// Version string
    pub version: String,

    /// Release number
    pub release: u32,

    /// Installation timestamp (Unix epoch)
    pub install_date: i64,

    /// Size in bytes
    pub size_bytes: u64,

    /// SHA256 checksum of the package file
    pub checksum: String,

    /// Original spec file content
    pub spec: String,
}

/// An available package from a repository
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AvailablePackage {
    /// Package name
    pub name: String,

    /// Version string
    pub version: String,

    /// Release number
    pub release: u32,

    /// Short summary
    pub summary: String,

    /// Download URL
    pub download_url: String,

    /// SHA256 checksum
    pub checksum: String,

    /// Last update timestamp
    pub last_updated: i64,
}

/// A file owned by a package
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PackageFile {
    /// File path
    pub path: String,

    /// File mode (permissions)
    pub mode: u32,

    /// Owner name
    pub owner: String,

    /// Group name
    pub group: String,

    /// Size in bytes
    pub size_bytes: u64,

    /// SHA256 checksum
    pub checksum: String,

    /// Is this a config file (preserved on upgrade)?
    pub is_config: bool,
}

/// A dependency relationship
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Dependency {
    /// Package that has this dependency
    pub package_id: i64,

    /// Name of the dependency
    pub depends_on: String,

    /// Version constraint (e.g., ">= 1.0", "= 2.0")
    pub constraint: String,

    /// Type of dependency
    pub dep_type: DependencyType,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum DependencyType {
    Runtime,
    Build,
    Optional,
}

impl std::fmt::Display for DependencyType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DependencyType::Runtime => write!(f, "runtime"),
            DependencyType::Build => write!(f, "build"),
            DependencyType::Optional => write!(f, "optional"),
        }
    }
}

impl std::str::FromStr for DependencyType {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.to_lowercase().as_str() {
            "runtime" => Ok(DependencyType::Runtime),
            "build" => Ok(DependencyType::Build),
            "optional" => Ok(DependencyType::Optional),
            _ => Err(format!("Unknown dependency type: {}", s)),
        }
    }
}

impl InstalledPackage {
    /// Get the full version string
    pub fn full_version(&self) -> String {
        format!("{}-{}", self.version, self.release)
    }
}

impl AvailablePackage {
    /// Get the full version string
    pub fn full_version(&self) -> String {
        format!("{}-{}", self.version, self.release)
    }
}
