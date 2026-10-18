//! Local IPC transport: one `UnixListener`/`UnixStream` pair for every OS.
//!
//! Unix uses `std::os::unix::net`. Windows uses AF_UNIX over Winsock (built
//! into Windows 10 1803+), so the daemon, its clients and the Odin bridge all
//! dial the same `.sock` path on every platform.

#[cfg(unix)]
pub use std::os::unix::net::{UnixListener, UnixStream};

#[cfg(windows)]
pub use uds_windows::{UnixListener, UnixStream};
