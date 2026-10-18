//! ham-pty-host: a standalone PTY host + VT screen model spike.
//!
//! Modules:
//!   * [`vt`]      — VT parser + screen grid (REQ PTYH-1).
//!   * [`host`]    — spawn a child under a PTY and maintain the live screen (PTYH-1).
//!   * [`proto`]   — framed attach/detach wire protocol (PTYH-2).
//!   * [`server`]  — unix-socket host server, multi-client fan-out (PTYH-2).
//!   * [`client`]  — raw-mode `attach` client (PTYH-2).
//!   * [`termios`] — local terminal raw mode + winsize FFI (PTYH-2).
//!   * [`ipc`]     — AF_UNIX listener/stream for Unix and Windows.
//!   * [`debug_tui`] — pure state machine for the in-app debug TUI (PTYH-3).
//!   * [`debug_ui`]  — ratatui/crossterm runtime for the debug TUI (PTYH-3).
//!   * [`dproto`]  — instance-scoped multi-agent daemon protocol (HOST-1).
//!   * [`daemon`]  — per-machine daemon: agent registry + spawn/close/restart/list (HOST-1).
//!   * [`detect`]  — pure config-driven startup detector + activity hash (HOST-2).
//!   * [`dashboard_tui`] — pure multi-agent dashboard state machine (HOST-3).
//!   * [`dclient`]  — single-agent raw-passthrough attach over the daemon (HOST-4).

pub mod client;
pub mod daemon;
pub mod dashboard_tui;
pub mod dclient;
pub mod dashboard_ui;
pub mod debug_tui;
pub mod debug_ui;
pub mod detect;
pub mod dproto;
pub mod host;
pub mod ipc;
#[cfg(windows)]
mod job;
pub mod proto;
pub mod selector;
pub mod server;
pub mod socket_path;
pub mod termios;
pub mod vt;

pub use daemon::{Daemon, DaemonServer};
pub use detect::{Detector, StartupDetectionConfig, StartupOutcome};
pub use dproto::{AgentInfo, CtlMsg, CtlReply, Shell, ShellInfo, SpawnRequest};
pub use host::{PtyHost, SpawnConfig};
pub use proto::{ClientMsg, HostMsg, NamedKey, ScreenSnapshot};
pub use selector::{SelectorAction, SelectorItem, SelectorState};
pub use server::HostServer;
pub use vt::{Capture, Cell, Color, Screen, VtEngine};

