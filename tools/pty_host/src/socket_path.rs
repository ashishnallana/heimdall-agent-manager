//! Portable generated Unix socket paths. Mirrors bridge/unix_socket_path.odin.
//!
//! Unix falls back to `/tmp/heimdall-<uid>/` (mode 0700). Windows has no uid:
//! it falls back to `%LOCALAPPDATA%\heimdall\run\` (else `%TEMP%\heimdall\run\`),
//! which is already private to the user through the profile's inherited ACL.
use anyhow::{bail, Result};
use std::path::Path;

pub const MAX_BYTES: usize = 103;

fn hashed(path: &str, dir: &str) -> String {
    let mut hash = 14695981039346656037u64;
    for byte in path.bytes() {
        hash = (hash ^ u64::from(byte)).wrapping_mul(1099511628211);
    }
    format!("{dir}{}{hash:016x}.sock", std::path::MAIN_SEPARATOR)
}

#[cfg(unix)]
pub fn bounded(path: &str, uid: u32) -> String {
    if path.len() <= MAX_BYTES {
        return path.to_owned();
    }
    hashed(path, &format!("/tmp/heimdall-{uid}"))
}

/// The per-user directory for generated socket paths (see module docs).
pub fn fallback_dir() -> String {
    #[cfg(unix)]
    {
        format!("/tmp/heimdall-{}", unsafe { libc::geteuid() })
    }
    #[cfg(windows)]
    {
        let base = std::env::var("LOCALAPPDATA")
            .ok()
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| std::env::temp_dir().to_string_lossy().into_owned());
        format!("{}\\heimdall\\run", base.trim_end_matches(['\\', '/']))
    }
}

/// `path` if it fits [`MAX_BYTES`], else a hashed name in [`fallback_dir`].
pub fn bounded_default(path: &str) -> String {
    #[cfg(unix)]
    {
        bounded(path, unsafe { libc::geteuid() })
    }
    #[cfg(windows)]
    {
        if path.len() <= MAX_BYTES {
            return path.to_owned();
        }
        hashed(path, &fallback_dir())
    }
}

pub fn validate(path: &Path) -> Result<()> {
    let bytes = path.as_os_str().as_encoded_bytes();
    if bytes.is_empty() || bytes.contains(&0) || bytes.len() > MAX_BYTES {
        bail!("Unix socket path must be nonempty, contain no NUL, and fit {MAX_BYTES} bytes (got {}): {}", bytes.len(), path.display());
    }
    Ok(())
}

#[cfg(unix)]
pub fn prepare(path: &Path) -> Result<()> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    validate(path)?;
    let uid = unsafe { libc::geteuid() };
    let fallback = fallback_dir();
    if path.parent() == Some(Path::new(&fallback)) {
        use std::os::unix::fs::DirBuilderExt;
        match std::fs::DirBuilder::new().mode(0o700).create(&fallback) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(e.into()),
        }
        let metadata = std::fs::symlink_metadata(&fallback)?;
        if !metadata.is_dir() || metadata.uid() != uid {
            bail!("Unix socket directory must be owned by the current user: {fallback}");
        }
        std::fs::set_permissions(&fallback, std::fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

/// Windows: create the fallback directory (also the default run dir) if the
/// socket lives there. No chmod: the user profile's ACL already keeps it private.
#[cfg(windows)]
pub fn prepare(path: &Path) -> Result<()> {
    validate(path)?;
    let fallback = fallback_dir();
    if path.parent() == Some(Path::new(&fallback)) {
        std::fs::create_dir_all(&fallback)?;
        if !std::fs::symlink_metadata(&fallback)?.is_dir() {
            bail!("Unix socket directory is not a directory: {fallback}");
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(unix)]
    #[test]
    fn portable_byte_limit_and_isolation() {
        assert_eq!(bounded(&"a".repeat(103), 1000), "a".repeat(103));
        assert_eq!(
            bounded(&"a".repeat(104), 1000),
            "/tmp/heimdall-1000/ddf64bd8caea7ded.sock"
        );
        let long = format!("/{}/bridge.sock", "a".repeat(150));
        let short = bounded(&long, 1000);
        assert!(short.len() <= MAX_BYTES);
        assert_eq!(short, bounded(&long, 1000));
        assert_ne!(
            short,
            bounded(&long.replace("bridge.sock", "pty-host.sock"), 1000)
        );
        assert_ne!(short, bounded(&long, 1001));
        assert!(bounded(&"é".repeat(52), 1000).starts_with("/tmp/heimdall-1000/"));
        assert!(validate(Path::new(&"a".repeat(104))).is_err());
    }

    #[cfg(windows)]
    #[test]
    fn windows_fallback_is_hashed_into_the_run_dir() {
        assert_eq!(bounded_default(&"a".repeat(103)), "a".repeat(103));
        let short = bounded_default(&"a".repeat(104));
        assert_eq!(short, format!("{}\\ddf64bd8caea7ded.sock", fallback_dir()));
        assert!(short.len() <= MAX_BYTES, "{short}");
        assert!(validate(Path::new(&"a".repeat(104))).is_err());
    }
}
