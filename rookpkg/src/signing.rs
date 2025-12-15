//! Cryptographic signing for packages
//!
//! Uses Ed25519 signatures via ed25519-dalek.
//! All packages MUST be signed - this is non-negotiable.

use std::fs;
use std::path::Path;

use anyhow::{bail, Context, Result};
use base64::prelude::*;
use ed25519_dalek::{SigningKey, VerifyingKey, Signature, Signer, Verifier};
use rand::rngs::OsRng;
use sha2::{Sha256, Digest};
use zeroize::Zeroizing;

use crate::config::Config;

/// A loaded signing key with its metadata
pub struct LoadedSigningKey {
    pub key: SigningKey,
    pub fingerprint: String,
    pub name: String,
    pub email: String,
}

/// Generate a new Ed25519 signing key pair
pub fn generate_key(name: &str, email: &str, output_dir: &Path) -> Result<(SigningKey, String)> {
    // Generate key pair
    let mut csprng = OsRng;
    let signing_key = SigningKey::generate(&mut csprng);
    let verifying_key = signing_key.verifying_key();

    // Calculate fingerprint
    let fingerprint = calculate_fingerprint(&verifying_key);

    // Create output directory
    fs::create_dir_all(output_dir)
        .with_context(|| format!("Failed to create key directory: {}", output_dir.display()))?;

    // Save secret key (with secure permissions)
    let secret_path = output_dir.join("signing-key.secret");
    let secret_content = format!(
        r#"# rookery-secretkey-version: 1.0
# WARNING: Keep this file secure! Mode should be 0600.
type = "ed25519"
purpose = "packager"
fingerprint = "{fingerprint}"
secret-key = "{secret_key}"

[identity]
name = "{name}"
email = "{email}"

[metadata]
created = "{timestamp}"
"#,
        fingerprint = fingerprint,
        secret_key = BASE64_STANDARD.encode(signing_key.to_bytes()),
        name = name,
        email = email,
        timestamp = chrono::Utc::now().to_rfc3339(),
    );

    // Write with secure permissions
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&secret_path)?;
        std::io::Write::write_all(&mut file, secret_content.as_bytes())?;
    }

    #[cfg(not(unix))]
    {
        fs::write(&secret_path, &secret_content)?;
    }

    // Save public key
    let public_path = output_dir.join("signing-key.pub");
    let public_content = format!(
        r#"# rookery-pubkey-version: 1.0
type = "ed25519"
purpose = "packager"
fingerprint = "{fingerprint}"
key = "{public_key}"

[identity]
name = "{name}"
email = "{email}"

[metadata]
created = "{timestamp}"
"#,
        fingerprint = fingerprint,
        public_key = BASE64_STANDARD.encode(verifying_key.to_bytes()),
        name = name,
        email = email,
        timestamp = chrono::Utc::now().to_rfc3339(),
    );
    fs::write(&public_path, &public_content)?;

    Ok((signing_key, fingerprint))
}

/// Load an existing signing key from the config-specified location
pub fn load_signing_key(config: &Config) -> Result<LoadedSigningKey> {
    let key_path = &config.signing.user_signing_key;

    if !key_path.exists() {
        bail!("Signing key not found at: {}", key_path.display());
    }

    // Check permissions on Unix
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let metadata = fs::metadata(key_path)?;
        let mode = metadata.mode() & 0o777;
        if mode != 0o600 {
            bail!(
                "Signing key has insecure permissions: {:o} (expected 0600). Fix with: chmod 600 {}",
                mode,
                key_path.display()
            );
        }
    }

    // Read and parse key file
    let content = Zeroizing::new(fs::read_to_string(key_path)?);
    let parsed: toml::Value = toml::from_str(&content)?;

    let secret_key_b64 = parsed
        .get("secret-key")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow::anyhow!("Missing secret-key in key file"))?;

    let secret_bytes = BASE64_STANDARD.decode(secret_key_b64)?;
    if secret_bytes.len() != 32 {
        bail!("Invalid secret key length");
    }

    let mut key_bytes = [0u8; 32];
    key_bytes.copy_from_slice(&secret_bytes);
    let signing_key = SigningKey::from_bytes(&key_bytes);

    // Zeroize the temporary key bytes
    key_bytes.iter_mut().for_each(|b| *b = 0);

    let fingerprint = parsed
        .get("fingerprint")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    let identity = parsed.get("identity");
    let name = identity
        .and_then(|i| i.get("name"))
        .and_then(|v| v.as_str())
        .unwrap_or("Unknown")
        .to_string();
    let email = identity
        .and_then(|i| i.get("email"))
        .and_then(|v| v.as_str())
        .unwrap_or("unknown@example.org")
        .to_string();

    // Verify key works by signing and verifying a test message
    let test_msg = b"rookery-signing-test";
    let signature = signing_key.sign(test_msg);
    signing_key
        .verifying_key()
        .verify(test_msg, &signature)
        .map_err(|_| anyhow::anyhow!("Signing key verification failed"))?;

    Ok(LoadedSigningKey {
        key: signing_key,
        fingerprint,
        name,
        email,
    })
}

/// Calculate the fingerprint of a verifying (public) key
pub fn calculate_fingerprint(key: &VerifyingKey) -> String {
    let hash = Sha256::digest(key.as_bytes());
    format!("ED25519:SHA256:{}", hex::encode(&hash[..16]))
}

/// Get the fingerprint of a signing key
pub fn get_fingerprint(key: &LoadedSigningKey) -> &str {
    &key.fingerprint
}

/// Sign a message and return the signature
pub fn sign_message(key: &SigningKey, message: &[u8]) -> Signature {
    key.sign(message)
}

/// Verify a signature against a message
pub fn verify_signature(
    public_key: &VerifyingKey,
    message: &[u8],
    signature: &Signature,
) -> Result<()> {
    public_key
        .verify(message, signature)
        .map_err(|_| anyhow::anyhow!("Signature verification failed"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn test_key_generation() {
        let dir = tempdir().unwrap();
        let (key, fingerprint) = generate_key("Test User", "test@example.org", dir.path()).unwrap();

        assert!(fingerprint.starts_with("ED25519:SHA256:"));
        assert!(dir.path().join("signing-key.secret").exists());
        assert!(dir.path().join("signing-key.pub").exists());

        // Test signing
        let message = b"test message";
        let signature = key.sign(message);
        key.verifying_key().verify(message, &signature).unwrap();
    }
}
