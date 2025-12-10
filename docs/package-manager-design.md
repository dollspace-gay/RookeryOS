# Rookery Package Manager Design Document

**Project Name:** `rookpkg` (Rookery Package Manager)
**Language:** Rust
**Target:** Rookery OS (LFS 12.4 + systemd + grsecurity)

## Table of Contents

1. [Overview](#overview)
2. [Dependency Resolution](#dependency-resolution)
3. [Package Specification Format](#package-specification-format)
4. [Package Signing and Trust Model](#package-signing-and-trust-model)
5. [Package Database](#package-database)
6. [Build System Integration](#build-system-integration)
7. [Implementation Roadmap](#implementation-roadmap)

---

## Overview

The Rookery Package Manager (`rookpkg`) is designed to provide a lightweight, reliable package management system for Rookery OS. Built in Rust for safety and performance, it handles package installation, dependency resolution, and system state management.

### Design Goals

- **Safety-First**: Leverage Rust's memory safety guarantees
- **Reproducible**: Builds should be deterministic and traceable
- **Transparent**: Clear error messages and dependency explanations
- **Minimal**: No unnecessary complexity or features
- **Community-Friendly**: Easy for Corvids to contribute packages

---

## Dependency Resolution

### Algorithm Options

#### 1. PubGrub (Recommended)

**PubGrub** is a modern version solving algorithm originally created for Dart's pub package manager, with excellent Rust support via the `pubgrub-rs` crate.

**Advantages:**
- Human-readable error messages explaining why dependencies cannot be resolved
- Returns the full derivation tree when no solution exists
- Well-maintained Rust implementation with Cargo team involvement
- Efficient conflict-driven clause learning (CDCL)
- Used by modern package managers (uv, Cargo experiments)

**Implementation:**
```rust
use pubgrub::{resolve, OfflineDependencyProvider};

// Define your dependency provider
struct RookeryDependencyProvider {
    // Package database access
}

impl DependencyProvider for RookeryDependencyProvider {
    // Implement required methods
}

// Resolve dependencies
let solution = resolve(&dependency_provider, package, version)?;
```

**Resources:**
- [PubGrub GitHub](https://github.com/pubgrub-rs/pubgrub)
- [PubGrub Documentation](https://pubgrub-rs.github.io/pubgrub/pubgrub/)
- [Cargo PubGrub Integration Goal](https://rust-lang.github.io/rust-project-goals/2024h2/pubgrub-in-cargo.html)

#### 2. libsolv (Alternative)

**libsolv** is a mature SAT solver used by openSUSE, Mamba, and other major package managers.

**Advantages:**
- Battle-tested in production package managers
- Very fast for large dependency graphs
- Supports complex constraints and conflict resolution

**Disadvantages:**
- C library requiring FFI bindings
- Less idiomatic Rust integration
- More complex to integrate than pure Rust solutions

**Resources:**
- [libsolv GitHub](https://github.com/openSUSE/libsolv)
- [Mamba Package Resolution](https://mamba.readthedocs.io/en/latest/advanced_usage/package_resolution.html)

#### 3. Custom Cargo-style Resolver

Cargo uses a heuristic-based resolver optimized for common cases rather than guaranteeing optimal solutions.

**Characteristics:**
- Prefers highest available versions
- Reuses versions where possible (reduces build times)
- Backtracks on conflicts
- Uses ConflictCache to avoid repeated failures
- 50% faster in Cargo 2.0

**Resources:**
- [Cargo Dependency Resolution](https://doc.rust-lang.org/cargo/reference/resolver.html)
- [Resolver Algorithm Deep Dive](https://ochagavia.nl/blog/the-magic-of-dependency-resolution/)

### Recommendation: PubGrub

For Rookery OS, **PubGrub** is the best choice because:
1. Pure Rust implementation (no FFI complexity)
2. Excellent error messages (important for community contributors)
3. Modern, actively maintained
4. Good performance for typical LFS/BLFS package counts (~500-1000 packages)

---

## Package Specification Format

### Design Inspiration

The spec format draws inspiration from RPM spec files, which have proven reliable for decades, but simplified for Rookery OS's needs.

### Rookery Spec File Format (`.rook`)

```toml
# rookery-spec-version: 1.0
# This declares the spec format version for future compatibility

[package]
name = "coreutils"
version = "9.4"
release = 1
summary = "GNU core utilities"
description = """
The GNU Core Utilities are the basic file, shell and text manipulation
utilities of the GNU operating system. These are the core utilities which
are expected to exist on every operating system.
"""
license = "GPLv3+"
url = "https://www.gnu.org/software/coreutils/"
maintainer = "corvid@example.org"

# Categories help with organization and discovery
categories = ["system", "base"]

# Source archives and patches
[sources]
# Source0 is the primary tarball
source0 = { url = "http://corvidae.social/lfs/12.4/coreutils-9.4.tar.xz", sha256 = "..." }
# Additional sources (documentation, supplementary files, etc.)
source1 = { url = "http://example.org/coreutils-i18n.patch", sha256 = "..." }

# Patches to apply during %prep
[patches]
patch0 = { file = "coreutils-i18n.patch", strip = 1 }

# Build-time dependencies
[build-depends]
gcc = ">= 13.2.0"
make = ">= 4.4"
glibc = ">= 2.39"

# Runtime dependencies
[depends]
glibc = ">= 2.39"
bash = ">= 5.2"

# Optional dependencies (features)
[optional-depends]
# Format: package = ["feature1", "feature2"]
acl = ["extended-attributes"]
libcap = ["capabilities"]

# Environment variables for build
[environment]
MAKEFLAGS = "-j4"
FORCE_UNSAFE_CONFIGURE = "1"

# Build instructions
[build]
# Preparation phase (unpack, patch, setup)
prep = """
#!/bin/bash
set -euo pipefail

# Extract source
tar -xf $SOURCE0

# Apply patches
cd coreutils-9.4
patch -Np1 -i $PATCH0
"""

# Configure phase
configure = """
#!/bin/bash
set -euo pipefail

cd coreutils-9.4
autoreconf -fiv
./configure --prefix=/usr \
            --enable-no-install-program=kill,uptime
"""

# Build phase
build = """
#!/bin/bash
set -euo pipefail

cd coreutils-9.4
make
"""

# Test phase (optional but recommended)
check = """
#!/bin/bash
set -euo pipefail

cd coreutils-9.4
make NON_ROOT_USERNAME=tester check-root
groupadd -g 102 dummy -U tester || true
chown -R tester . || true
su tester -c "PATH=$PATH make -k check" || true
groupdel dummy || true
"""

# Install phase
install = """
#!/bin/bash
set -euo pipefail

cd coreutils-9.4
make DESTDIR=$ROOKPKG_DESTDIR install

# Move programs to correct locations
mv -v $ROOKPKG_DESTDIR/usr/bin/chroot $ROOKPKG_DESTDIR/usr/sbin
mkdir -pv $ROOKPKG_DESTDIR/usr/share/man/man8
mv -v $ROOKPKG_DESTDIR/usr/share/man/man1/chroot.1 \
      $ROOKPKG_DESTDIR/usr/share/man/man8/chroot.8
sed -i 's/"1"/"8"/' $ROOKPKG_DESTDIR/usr/share/man/man8/chroot.8
"""

# Files to include in the package
[files]
# Patterns for files to include
include = [
    "/usr/bin/*",
    "/usr/sbin/chroot",
    "/usr/share/man/man1/*",
    "/usr/share/man/man8/chroot.8",
    "/usr/share/info/coreutils.info",
]

# Files to explicitly exclude
exclude = [
    "/usr/bin/kill",
    "/usr/bin/uptime",
]

# File ownership and permissions
[[files.config]]
path = "/usr/bin/su"
mode = "4755"
owner = "root"
group = "root"

# Configuration files (preserved during upgrades)
[config-files]
# These files won't be overwritten if modified by user
preserve = []

# Post-installation scripts
[scripts]
# Run after package installation
post-install = """
#!/bin/bash
# Update info directory
if [ -x /usr/bin/install-info ]; then
    install-info /usr/share/info/coreutils.info /usr/share/info/dir
fi
"""

# Run before package removal
pre-remove = """
#!/bin/bash
if [ -x /usr/bin/install-info ]; then
    install-info --delete /usr/share/info/coreutils.info /usr/share/info/dir
fi
"""

# Run after package removal
post-remove = """
#!/bin/bash
# Cleanup if needed
"""

# Run before package upgrade
pre-upgrade = """
#!/bin/bash
# Backup configs, etc.
"""

# Run after package upgrade
post-upgrade = """
#!/bin/bash
# Restore configs, restart services, etc.
"""

# Changelog
[[changelog]]
date = "2024-12-10"
version = "9.4-1"
author = "corvid@example.org"
changes = [
    "Initial package for Rookery OS",
    "Added i18n patch for better international support",
]

# Metadata for package discovery and organization
[metadata]
# Keywords for searching
keywords = ["core", "utilities", "shell", "files", "text"]

# Package maturity
stability = "stable"  # alpha, beta, stable, deprecated

# Security considerations
[security]
# Enable grsecurity features if available
grsec-compatible = true

# Known CVEs fixed in this version
fixed-cves = []
```

### Simplified Format for Basic Packages

For simpler packages without complex requirements:

```toml
[package]
name = "hello"
version = "2.12"
release = 1
summary = "GNU Hello World program"
license = "GPLv3+"

[sources]
source0 = { url = "http://corvidae.social/lfs/12.4/hello-2.12.tar.gz", sha256 = "..." }

[depends]
glibc = ">= 2.39"

[build]
configure = "./configure --prefix=/usr"
build = "make"
install = "make DESTDIR=$ROOKPKG_DESTDIR install"

[files]
include = ["/usr/bin/hello", "/usr/share/man/man1/hello.1"]
```

### Variable Substitution

The following variables are available in build scripts:

- `$SOURCE0`, `$SOURCE1`, etc. - Paths to source files
- `$PATCH0`, `$PATCH1`, etc. - Paths to patch files
- `$ROOKPKG_DESTDIR` - Installation staging directory
- `$ROOKPKG_BUILDDIR` - Temporary build directory
- `$PACKAGE_NAME` - Package name
- `$PACKAGE_VERSION` - Package version
- `$PACKAGE_RELEASE` - Release number
- `$MAKEFLAGS` - Make parallelization flags

---

## Package Signing and Trust Model

### Security Philosophy

**All packages MUST be cryptographically signed.** The Rookery Package Manager enforces a strict "no signature, no build" policy. This is non-negotiable and cannot be disabled.

### Design Principles

1. **Mandatory Signing**: Package building is impossible without valid signing keys
2. **Chain of Trust**: All packages trace back to trusted maintainer keys
3. **Transparent Verification**: Users can inspect and verify all signatures
4. **Key Revocation**: Compromised keys can be revoked system-wide
5. **Offline Capable**: Signature verification works without network access

### Cryptographic Backend

Use **Ed25519** signatures via the `ed25519-dalek` Rust crate:

**Why Ed25519:**
- Fast signing and verification (10-100x faster than RSA)
- Small signatures (64 bytes) and keys (32 bytes)
- Immune to timing attacks by design
- No complex parameter choices (unlike RSA key sizes)
- Modern, well-audited implementation
- Used by Signal, OpenSSH, age encryption

**Alternative Consideration:** Minisign (libsodium-based, simpler than GPG)

### Key Management

#### Key Types

1. **Master Keys** - Held by Rookery OS maintainers
   - Signs official repository metadata
   - Signs trusted packager keys
   - Kept offline (cold storage)
   - Location: `/etc/rookpkg/keys/master/`

2. **Packager Keys** - Individual package maintainers
   - Signs individual packages
   - Must be signed by a master key
   - Location: `/etc/rookpkg/keys/packagers/`

3. **Build Keys** - Local machine signing
   - For personal/development builds
   - Not trusted by default (requires manual trust)
   - Location: `~/.config/rookpkg/signing-key.secret`

#### Key File Format

**Public Key** (`.pub`):
```toml
# rookery-pubkey-version: 1.0
type = "ed25519"
purpose = "packager"  # or "master" or "build"
fingerprint = "ED25519:SHA256:abc123...def789"
key = "base64encodedpublickey=="

[identity]
name = "Corvid Maintainer"
email = "corvid@rookery.social"
keyserver = "https://keys.rookery.social"

[metadata]
created = 2024-12-10T12:00:00Z
expires = 2026-12-10T12:00:00Z  # Optional expiration

# For packager keys: signature from master key
[signature]
signed-by = "ED25519:SHA256:masterkey..."
signature = "base64encodedsignature=="
timestamp = 2024-12-10T12:00:00Z
```

**Secret Key** (`signing-key.secret`):
```toml
# rookery-secretkey-version: 1.0
# WARNING: Keep this file secure! Mode should be 0600.
type = "ed25519"
purpose = "packager"
fingerprint = "ED25519:SHA256:abc123...def789"
secret-key = "base64encodedsecretkey=="

[identity]
name = "Corvid Maintainer"
email = "corvid@rookery.social"

[metadata]
created = 2024-12-10T12:00:00Z
```

### Key Generation

#### Initial Setup (Fresh System)

```bash
# Generate a new signing key
rookpkg keygen --name "Corvid Maintainer" --email "corvid@rookery.social"

# Output:
# Generated new Ed25519 signing key
# Fingerprint: ED25519:SHA256:abc123...def789
# Public key:  ~/.config/rookpkg/signing-key.pub
# Secret key:  ~/.config/rookpkg/signing-key.secret (mode 0600)
#
# ⚠️  IMPORTANT: This key is NOT trusted by default!
# To sign official packages, submit your public key to the
# Rookery OS maintainers for signing at:
# https://github.com/rookery-os/keys
#
# ✓ You can now build and sign packages locally.
```

#### Key Generation Workflow

```rust
// Simplified key generation logic
fn generate_signing_key(name: &str, email: &str) -> Result<SigningKey> {
    let mut csprng = OsRng;
    let signing_key = SigningKey::generate(&mut csprng);
    let verifying_key = signing_key.verifying_key();

    let fingerprint = format!(
        "ED25519:SHA256:{}",
        hex::encode(Sha256::digest(verifying_key.as_bytes()))
    );

    // Save keys with restrictive permissions
    save_secret_key(&signing_key, 0o600)?;
    save_public_key(&verifying_key, 0o644)?;

    Ok(signing_key)
}
```

### Build-Time Signing Enforcement

#### Pre-Build Key Check

**CRITICAL**: Before any build starts, `rookpkg` MUST verify signing keys exist:

```rust
fn verify_signing_keys_or_abort() -> Result<SigningKey> {
    let secret_key_path = get_secret_key_path()?;

    // Check if secret key exists
    if !secret_key_path.exists() {
        eprintln!("❌ FATAL: No signing key found!");
        eprintln!();
        eprintln!("Package building requires a signing key.");
        eprintln!("Generate one with: rookpkg keygen");
        eprintln!();
        eprintln!("See documentation: rookpkg help keygen");
        std::process::exit(1);
    }

    // Check file permissions (must be 0600)
    let metadata = std::fs::metadata(&secret_key_path)?;
    let mode = metadata.permissions().mode() & 0o777;

    if mode != 0o600 {
        eprintln!("❌ FATAL: Signing key has insecure permissions!");
        eprintln!();
        eprintln!("Secret key file: {}", secret_key_path.display());
        eprintln!("Current mode: {:o}", mode);
        eprintln!("Required mode: 0600");
        eprintln!();
        eprintln!("Fix with: chmod 600 {}", secret_key_path.display());
        std::process::exit(1);
    }

    // Load and verify the key
    let signing_key = load_signing_key(&secret_key_path)?;

    // Test that the key works
    let test_message = b"rookery-os-signing-test";
    let signature = signing_key.sign(test_message);
    signing_key.verifying_key().verify(test_message, &signature)?;

    println!("✓ Signing key verified: {}", get_key_fingerprint(&signing_key));
    Ok(signing_key)
}

fn build_package(spec: &PackageSpec) -> Result<()> {
    // FIRST THING: Verify signing keys
    let signing_key = verify_signing_keys_or_abort()?;

    // Now proceed with build...
    println!("Building package: {}", spec.name);
    // ... build logic ...

    // Sign the package
    sign_package(&package, &signing_key)?;

    Ok(())
}
```

#### Build Flow with Signing

```
┌─────────────────────────────────┐
│  rookpkg build package.rook     │
└────────────┬────────────────────┘
             │
             ▼
┌─────────────────────────────────┐
│ Check for signing key           │
│ ~/.config/rookpkg/              │
│   signing-key.secret            │
└────────────┬────────────────────┘
             │
             ├─ NOT FOUND ──────► ❌ EXIT: "Run rookpkg keygen"
             │
             ├─ WRONG PERMS ────► ❌ EXIT: "chmod 600 key"
             │
             ▼ FOUND & VALID
┌─────────────────────────────────┐
│ Parse package spec              │
│ Resolve dependencies            │
│ Download sources                │
│ Verify source checksums         │
└────────────┬────────────────────┘
             │
             ▼
┌─────────────────────────────────┐
│ Execute build phases:           │
│  - prep                         │
│  - configure                    │
│  - build                        │
│  - check                        │
│  - install (to DESTDIR)         │
└────────────┬────────────────────┘
             │
             ▼
┌─────────────────────────────────┐
│ Create package archive          │
│  - .PKGINFO (metadata)          │
│  - .FILES (file list)           │
│  - .INSTALL (scripts)           │
│  - data.tar.zst (files)         │
└────────────┬────────────────────┘
             │
             ▼
┌─────────────────────────────────┐
│ Generate package manifest       │
│  - Hash all package components  │
│  - Include build metadata       │
│  - Timestamp creation           │
└────────────┬────────────────────┘
             │
             ▼
┌─────────────────────────────────┐
│ Sign package with Ed25519       │
│  - Sign manifest hash           │
│  - Include signer fingerprint   │
│  - Create .SIGNATURE file       │
└────────────┬────────────────────┘
             │
             ▼
┌─────────────────────────────────┐
│ Add signature to package:       │
│ package.rookpkg + .SIGNATURE    │
└────────────┬────────────────────┘
             │
             ▼
        ✓ COMPLETE
```

### Package Signature Format

Each `.rookpkg` file includes a `.SIGNATURE` file:

```toml
# rookery-signature-version: 1.0

[signature]
type = "ed25519"
algorithm = "Ed25519"
signature = "base64encodedsignature=="
signed-at = 2024-12-10T15:30:00Z

[signer]
fingerprint = "ED25519:SHA256:abc123...def789"
name = "Corvid Maintainer"
email = "corvid@rookery.social"
key-url = "https://keys.rookery.social/corvid.pub"

[signed-data]
# What was signed
manifest-hash = "sha256:def456..."
manifest-hash-algorithm = "SHA256"

# Package metadata included in signature
package = "coreutils"
version = "9.4"
release = 1
arch = "x86_64"

# Files included in the signature
[signed-data.files]
".PKGINFO" = "sha256:abc123..."
".FILES" = "sha256:def456..."
".INSTALL" = "sha256:ghi789..."
"data.tar.zst" = "sha256:jkl012..."
```

### Signature Verification

#### Installation-Time Verification

```rust
fn install_package(package_path: &Path) -> Result<()> {
    // Load package
    let package = load_package(package_path)?;

    // Extract and verify signature
    let signature = extract_signature(&package)?;

    // Check if signer key is trusted
    let signer_key = get_trusted_key(&signature.signer_fingerprint)?;

    if signer_key.is_none() {
        eprintln!("❌ FATAL: Package signed by untrusted key!");
        eprintln!();
        eprintln!("Signer: {}", signature.signer_name);
        eprintln!("Fingerprint: {}", signature.signer_fingerprint);
        eprintln!();
        eprintln!("This package cannot be installed.");
        eprintln!("To trust this key: rookpkg trust {}", signature.signer_fingerprint);
        return Err(Error::UntrustedPackage);
    }

    // Verify signature
    verify_package_signature(&package, &signature, &signer_key.unwrap())?;

    println!("✓ Signature valid: {}", signature.signer_name);

    // Proceed with installation...
    Ok(())
}
```

#### Trust Levels

1. **System Trusted** - Signed by Rookery OS master key
   - Default repositories
   - Can install without prompts

2. **User Trusted** - Manually trusted by user
   - Third-party repositories
   - Personal builds shared between machines
   - Prompt on first install: "Trust this key? [y/N]"

3. **Untrusted** - Unknown key
   - Cannot install (hard block)
   - Must explicitly trust first

### Key Distribution

#### Official Rookery OS Keys

Distributed with base system installation:
```
/etc/rookpkg/keys/master/
└── rookery-master-2024.pub

/etc/rookpkg/keys/packagers/
├── corvid-alice.pub
├── corvid-bob.pub
└── corvid-charlie.pub
```

#### Trust Database

```sql
-- Trusted signing keys
CREATE TABLE trusted_keys (
    id INTEGER PRIMARY KEY,
    fingerprint TEXT NOT NULL UNIQUE,
    public_key TEXT NOT NULL,
    trust_level TEXT NOT NULL,  -- 'system', 'user', 'revoked'
    name TEXT NOT NULL,
    email TEXT NOT NULL,
    added_date INTEGER NOT NULL,
    added_by TEXT NOT NULL,  -- 'system' or 'user'
    notes TEXT
);

-- Key revocations
CREATE TABLE revoked_keys (
    id INTEGER PRIMARY KEY,
    fingerprint TEXT NOT NULL,
    revoked_date INTEGER NOT NULL,
    reason TEXT NOT NULL,
    revoked_by TEXT NOT NULL  -- Master key fingerprint
);
```

#### Key Revocation

```bash
# Revoke a compromised key (requires master key)
rookpkg keyrevoke ED25519:SHA256:abc123...def789 \
    --reason "Key compromised on 2024-12-10" \
    --sign-with master-key

# Check for revoked keys
rookpkg keycheck

# Update trusted keys from keyserver
rookpkg keyupdate
```

### CLI Commands

```bash
# Key Management
rookpkg keygen                    # Generate new signing key
rookpkg keylist                   # List trusted keys
rookpkg keyshow <fingerprint>     # Show key details
rookpkg keytrust <fingerprint>    # Trust a key manually
rookpkg keyuntrust <fingerprint>  # Remove trust
rookpkg keyrevoke <fingerprint>   # Revoke key (master only)
rookpkg keyexport                 # Export public key
rookpkg keyimport <file>          # Import public key

# Signature Verification
rookpkg verify <package>          # Verify package signature
rookpkg checksig <package>        # Detailed signature info

# Building (requires signing key)
rookpkg build <spec>              # Build and sign package
rookpkg sign <package>            # Sign existing package
```

### Configuration

`/etc/rookpkg/rookpkg.conf`:

```toml
[signing]
# Signature verification strictness
require-signatures = true  # Cannot be disabled
allow-untrusted = false    # Require trusted signatures

# Key paths
master-keys-dir = "/etc/rookpkg/keys/master"
packager-keys-dir = "/etc/rookpkg/keys/packagers"
user-signing-key = "~/.config/rookpkg/signing-key.secret"

# Signature algorithms (future-proofing)
allowed-algorithms = ["ed25519"]
minimum-key-size = 256  # bits

[keyserver]
# Where to fetch updated keys
enabled = true
url = "https://keys.rookery.social"
update-interval = 86400  # 24 hours
```

### Error Messages

Clear, actionable error messages for signing issues:

```
❌ FATAL: No signing key found!

Package building requires a cryptographic signing key.
This ensures package authenticity and prevents tampering.

To create a signing key:
  rookpkg keygen --name "Your Name" --email "you@example.org"

For more information:
  rookpkg help keygen
  https://docs.rookery.social/packaging/signing
```

```
❌ FATAL: Package signature verification failed!

Package: coreutils-9.4-1.rookpkg
Signer: unknown@suspicious.com
Fingerprint: ED25519:SHA256:bad123...

This package is signed by an untrusted key and cannot be installed.

If you trust this package source:
  rookpkg keytrust ED25519:SHA256:bad123...

⚠️  WARNING: Only trust keys from verified sources!
```

```
❌ FATAL: Package signature is invalid!

The package signature does not match the package contents.
This indicates tampering or corruption.

Package: coreutils-9.4-1.rookpkg
Expected hash: sha256:abc123...
Actual hash: sha256:def456...

DO NOT INSTALL THIS PACKAGE.
```

### Security Considerations

1. **Key Storage**
   - Secret keys stored with 0600 permissions (owner-only)
   - Keys stored in memory only during signing operations
   - Memory zeroed after use (using `zeroize` crate)

2. **Side-Channel Resistance**
   - Ed25519 is timing-attack resistant by design
   - No key material in log files
   - No key fingerprints in error messages (except verification failures)

3. **Compromise Recovery**
   - Key revocation mechanism with master key override
   - Per-package signature timestamps enable rollback detection
   - Audit log of all signature verifications

4. **Build Environment**
   - Signing keys never enter build containers
   - Packages signed on host after build completes
   - Build process cannot access signing keys

### Dependencies

```toml
[dependencies]
# Ed25519 signatures
ed25519-dalek = "2.1"
signature = "2.2"

# Cryptographic hashing
sha2 = "0.10"
blake3 = "1.5"

# Secure memory handling
zeroize = "1.7"

# Time handling
chrono = "0.4"

# Encoding
base64 = "0.21"
hex = "0.4"
```

---

## Package Database

### Database Structure

Use SQLite for the package database (`/var/lib/rookpkg/db.sqlite`):

```sql
-- Installed packages
CREATE TABLE packages (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    version TEXT NOT NULL,
    release INTEGER NOT NULL,
    install_date INTEGER NOT NULL,
    size_bytes INTEGER NOT NULL,
    checksum TEXT NOT NULL,
    spec_file TEXT NOT NULL  -- Full spec file content
);

-- Installed files (for conflict detection and removal)
CREATE TABLE files (
    id INTEGER PRIMARY KEY,
    package_id INTEGER NOT NULL,
    path TEXT NOT NULL,
    mode INTEGER NOT NULL,
    owner TEXT NOT NULL,
    group TEXT NOT NULL,
    size_bytes INTEGER NOT NULL,
    checksum TEXT NOT NULL,
    is_config BOOLEAN NOT NULL DEFAULT 0,
    FOREIGN KEY (package_id) REFERENCES packages(id) ON DELETE CASCADE
);

-- Package dependencies
CREATE TABLE dependencies (
    id INTEGER PRIMARY KEY,
    package_id INTEGER NOT NULL,
    depends_on TEXT NOT NULL,  -- Package name
    constraint TEXT NOT NULL,  -- ">= 1.0", "= 2.0", etc.
    dep_type TEXT NOT NULL,    -- "runtime", "build", "optional"
    FOREIGN KEY (package_id) REFERENCES packages(id) ON DELETE CASCADE
);

-- Available packages (repository metadata)
CREATE TABLE available_packages (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    version TEXT NOT NULL,
    release INTEGER NOT NULL,
    summary TEXT NOT NULL,
    download_url TEXT NOT NULL,
    checksum TEXT NOT NULL,
    spec_checksum TEXT NOT NULL,
    last_updated INTEGER NOT NULL
);

-- Create indices for fast lookups
CREATE INDEX idx_files_path ON files(path);
CREATE INDEX idx_files_package ON files(package_id);
CREATE INDEX idx_deps_package ON dependencies(package_id);
CREATE INDEX idx_deps_name ON dependencies(depends_on);
CREATE INDEX idx_available_name ON available_packages(name);
```

### File Layout

```
/var/lib/rookpkg/
├── db.sqlite           # Package database
├── cache/              # Downloaded packages
├── build/              # Temporary build directory
├── installed/          # Installed package metadata
└── repos/              # Repository definitions

/etc/rookpkg/
├── rookpkg.conf        # Main configuration
└── repos.d/            # Repository configurations
    ├── rookery-base.repo
    └── rookery-blfs.repo
```

---

## Build System Integration

### Building from Source

```bash
# Build a package from .rook spec
rookpkg build package.rook

# Build and install
rookpkg build --install package.rook

# Build with specific features
rookpkg build --features extended-attributes,capabilities package.rook
```

### Building Binary Packages

Rookery packages are distributed as compressed tarballs with metadata:

```
coreutils-9.4-1.rookpkg
├── .PKGINFO          # Package metadata (TOML)
├── .INSTALL          # Install/remove scripts
├── .FILES            # List of files with checksums
└── data.tar.zst      # Compressed file tree
```

The `.PKGINFO` format:

```toml
name = "coreutils"
version = "9.4"
release = 1
builddate = 1702234567
size = 14567890
arch = "x86_64"
packager = "corvid@example.org"

[checksums]
type = "sha256"
pkginfo = "..."
install = "..."
files = "..."
data = "..."
```

---

## Implementation Roadmap

### Phase 1: Core Infrastructure (MVP)

1. **Spec File Parser**
   - TOML parsing with validation
   - Variable substitution engine
   - Dependency constraint parsing

2. **Dependency Resolver**
   - Integrate pubgrub-rs
   - Implement RookeryDependencyProvider
   - Basic constraint solving

3. **Package Database**
   - SQLite initialization
   - CRUD operations for packages
   - File tracking

4. **Basic CLI**
   ```bash
   rookpkg install <package>
   rookpkg remove <package>
   rookpkg list
   rookpkg info <package>
   ```

### Phase 2: Build System

1. **Source Building**
   - Download and verify sources
   - Execute build phases (prep, configure, build, install)
   - Sandbox builds (user namespaces)

2. **Binary Package Creation**
   - Pack installed files into .rookpkg
   - Generate metadata
   - Sign packages (GPG)

3. **Package Installation**
   - Extract .rookpkg files
   - File conflict detection
   - Transaction support (atomic installs)

### Phase 3: Repository Support

1. **Repository Management**
   - Fetch repository metadata
   - Sync package lists
   - Mirror support

2. **Remote Package Installation**
   - Download from repositories
   - Verify signatures
   - Cache management

### Phase 4: Advanced Features

1. **Dependency Resolution Enhancements**
   - Optional dependencies
   - Feature flags
   - Conflict resolution

2. **System Management**
   - Upgrade all packages
   - Downgrade support
   - Orphan detection
   - Automatic dependency cleanup

3. **Build Optimization**
   - Parallel builds
   - ccache integration
   - Distributed builds

4. **Security**
   - Package signing
   - Repository trust chains
   - Vulnerability tracking

---

## Example CLI Usage

```bash
# Search for packages
rookpkg search coreutils

# Show package information
rookpkg info coreutils

# Install a package
rookpkg install coreutils

# Remove a package
rookpkg remove coreutils

# List installed packages
rookpkg list --installed

# Check for updates
rookpkg update

# Upgrade all packages
rookpkg upgrade

# Build from source
rookpkg build coreutils.rook

# Show dependency tree
rookpkg depends coreutils

# Verify installed packages
rookpkg verify

# Clean cache
rookpkg clean
```

---

## Technical Stack

### Core Dependencies

```toml
[dependencies]
# Command-line interface
clap = { version = "4", features = ["derive"] }

# Configuration and spec parsing
toml = "0.8"
serde = { version = "1", features = ["derive"] }

# Dependency resolution
pubgrub = "0.2"

# Database
rusqlite = { version = "0.31", features = ["bundled"] }

# Archive handling
tar = "0.4"
flate2 = "1.0"
zstd = "0.13"

# Hashing and verification
sha2 = "0.10"
blake3 = "1.5"

# HTTP downloads
reqwest = { version = "0.11", features = ["blocking"] }

# Logging
tracing = "0.1"
tracing-subscriber = "0.3"

# Error handling
anyhow = "1.0"
thiserror = "1.0"

# Parallel processing
rayon = "1.8"

# Progress bars
indicatif = "0.17"
```

---

## References

### Dependency Resolution
- [Cargo Dependency Resolution](https://doc.rust-lang.org/cargo/reference/resolver.html)
- [PubGrub Implementation](https://github.com/pubgrub-rs/pubgrub)
- [PubGrub Documentation](https://pubgrub-rs.github.io/pubgrub/pubgrub/)
- [The Magic of Dependency Resolution](https://ochagavia.nl/blog/the-magic-of-dependency-resolution/)
- [libsolv SAT Solver](https://github.com/openSUSE/libsolv)
- [Mamba Package Resolution](https://mamba.readthedocs.io/en/latest/advanced_usage/package_resolution.html)

### Package Management
- [RPM Spec File Format](https://rpm-software-management.github.io/rpm/manual/spec.html)
- [RPM Packaging Guide](https://rpm-packaging-guide.github.io/)
- [Arch Linux PKGBUILD](https://wiki.archlinux.org/title/PKGBUILD)
- [Gentoo Ebuilds](https://devmanual.gentoo.org/ebuild-writing/)

### Rust Ecosystem
- [Cargo 2.0 Guide](https://markaicode.com/cargo-2-0-complete-guide/)
- [UV: Rust-powered Python Package Manager](https://dev.to/aleksei_aleinikov/uv-is-the-fastest-python-package-manager-of-2025-and-its-written-in-rust-kkf)

---

## Notes for Corvids

This design document is a living document. As we build `rookpkg`, we'll refine these specifications based on real-world usage with Rookery OS.

The focus is on simplicity and safety - we're building a tool for our community, not trying to compete with mainstream distros. If a feature doesn't serve the Friendly Society of Corvids, we don't need it.

**Contributions welcome!** See `CONTRIBUTING.md` for guidelines on proposing package specs and code contributions.

---

*For the Corvids, by the Corvids.*
*Caw caw!* 🐦‍⬛
