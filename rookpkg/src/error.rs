//! Error types for rookpkg

use thiserror::Error;

/// Main error type for rookpkg operations
#[derive(Error, Debug)]
pub enum RookpkgError {
    #[error("Package not found: {0}")]
    PackageNotFound(String),

    #[error("Dependency resolution failed: {0}")]
    DependencyResolution(String),

    #[error("Invalid spec file: {0}")]
    InvalidSpec(String),

    #[error("Signing key not found")]
    SigningKeyNotFound,

    #[error("Signing key has insecure permissions: {0:o} (expected 0600)")]
    InsecureKeyPermissions(u32),

    #[error("Package signature verification failed: {0}")]
    SignatureVerificationFailed(String),

    #[error("Untrusted package signer: {0}")]
    UntrustedSigner(String),

    #[error("Build failed: {0}")]
    BuildFailed(String),

    #[error("Download failed: {0}")]
    DownloadFailed(String),

    #[error("Checksum mismatch: expected {expected}, got {actual}")]
    ChecksumMismatch { expected: String, actual: String },

    #[error("File conflict: {path} is owned by {owner}")]
    FileConflict { path: String, owner: String },

    #[error("Database error: {0}")]
    Database(String),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Configuration error: {0}")]
    Config(String),
}

/// Result type alias for rookpkg operations
pub type Result<T> = std::result::Result<T, RookpkgError>;
