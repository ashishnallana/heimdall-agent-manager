//! REQ HOST-1: Multi-agent daemon wire protocol.
//!
//! This is the instance-scoped control + data protocol spoken by the per-machine
//! daemon ([`crate::daemon`]). It generalizes the single-agent PTYH-2 protocol
//! ([`crate::proto`]): **every data-plane frame carries an `instance` id**, and
//! there is an explicit control plane (`Spawn` / `Close` / `Restart` / `List`).
//!
//! The framing is identical to PTYH-2 — a `u32` big-endian length prefix followed
//! by a tagged payload — so the two protocols can share [`crate::proto::read_frame`].
//! We deliberately keep the two message sets in separate enums so the legacy
//! single-agent server keeps working unchanged while the daemon layer lands.
//!
//! ## client -> daemon ([`CtlMsg`])
//!
//! | tag  | name    | purpose                                                    |
//! |------|---------|------------------------------------------------------------|
//! | 0x20 | Spawn   | register + launch a new agent under an instance id         |
//! | 0x21 | Close   | SIGTERM->wait->SIGKILL the instance, then unregister        |
//! | 0x22 | Restart | re-spawn the instance from its remembered spec             |
//! | 0x23 | List    | enumerate all registered agents                            |
//! | 0x30 | Attach  | subscribe this client to an instance's output stream       |
//! | 0x31 | Input   | raw bytes -> instance stdin                                 |
//! | 0x32 | Key     | named key -> instance stdin                                |
//! | 0x33 | Resize  | resize an instance's PTY + VT model                        |
//! | 0x34 | Capture | request a one-shot screen snapshot for an instance         |
//! | 0x35 | Detach  | unsubscribe this client from an instance (child survives)  |
//! | 0x36 | Ping    | liveness check                                             |
//! | 0x37 | Shutdown| stop all agents and terminate the daemon process           |
//! | 0x38 | WatchEvents | subscribe to host-level events (heartbeat + lifecycle) |
//! | 0x39 | Signal  | POSIX signal to a shell's process group                    |
//!
//! ## daemon -> client ([`CtlReply`])
//!
//! | tag  | name        | purpose                                              |
//! |------|-------------|------------------------------------------------------|
//! | 0xA0 | Spawned     | ack Spawn with the child pid                          |
//! | 0xA1 | Closed      | ack Close                                             |
//! | 0xA2 | Restarted   | ack Restart with the new child pid                   |
//! | 0xA3 | AgentList   | response to List                                     |
//! | 0xA4 | Output      | raw PTY bytes for an instance                         |
//! | 0xA5 | Screen      | screen snapshot for an instance                      |
//! | 0xA6 | ChildExited | an instance's child exited (event)                   |
//! | 0xA7 | Pong        | ping reply                                           |
//! | 0xA8 | Error       | an operation failed (instance + message)             |
//! | 0xAC | ShuttingDown| ack Shutdown; daemon is terminating                  |
//! | 0xAD | HostHeartbeat| periodic host liveness digest (roster + alive)      |
//! | 0xAE | StreamReady | stream attached and ready to accept input/output     |
//! | 0xAF | StreamClosed| stream closed (child exited or teardown)             |
//! | 0xB0 | AlreadyExited| Signal target had already exited (instance + code)  |
//! | 0x3A | StartupInput | launch-fenced, idempotent startup instruction       |
//! | 0xB1 | StartupInputDone | startup bytes written (instance + pid + key)   |

use std::io::{self, Read, Write};

use crate::proto::{read_frame, NamedKey, ScreenSnapshot};

/// Everything the daemon needs to (re-)spawn an agent. The daemon stores this so
/// `Restart` re-spawns the exact same command without the caller re-plumbing it.
// serde_json::Value is PartialEq but not Eq (f64 NaN), so Eq is not derived here.
#[derive(Clone, Debug, PartialEq, Default)]
pub struct SpawnRequest {
    /// Agent-instance id (the registry key). Required + unique.
    pub instance: String,
    /// Program + args to exec. `argv[0]` is the program.
    pub argv: Vec<String>,
    /// Working directory for the child, if any.
    pub cwd: Option<String>,
    /// Extra environment merged over the daemon's filtered env.
    pub env: Vec<(String, String)>,
    /// Opaque startup-detection config (JSON). Stored verbatim in HOST-1; parsed
    /// by the per-agent detector in HOST-2.
    pub detect: Option<String>,
    pub rows: u16,
    pub cols: u16,
    /// Human-readable agent display name (e.g. "default-agent #20").
    pub display_name: Option<String>,
    /// Session kind: "run" | "shell" | "server".
    ///
    /// PURE PASSTHROUGH. The daemon never branches on this value — the only use of the
    /// field in the whole Rust tree is the `put_opt_str` that re-serializes it — so
    /// nothing about PTY-vs-pipe behaviour depends on it. Kept as a free-form
    /// `Option<String>` rather than an enum for exactly that reason: the hub owns the
    /// vocabulary and validates it, and this side must not acquire a second opinion that
    /// could drift. The spellings above are documentation of what the hub currently sends,
    /// not a contract enforced here.
    pub kind: Option<String>,
    /// Human label for the session.
    pub label: Option<String>,
    /// Opaque metadata bag (arbitrary JSON).
    pub meta: Option<serde_json::Value>,
    /// Absolute path to tee output file; None = no tee.
    pub tee_path: Option<String>,
    /// Maximum lifetime of the child process in seconds. `None` means no
    /// deadline. A restart starts a fresh timeout from the new child spawn.
    pub timeout_seconds: Option<u64>,
}

impl SpawnRequest {
    pub fn instance_id(&self) -> &str {
        &self.instance
    }

    pub fn shell_id(&self) -> &str {
        &self.instance
    }
}

/// A row in the `List` response: one registered agent's live state.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentInfo {
    pub instance_id: String,
    pub program: String,
    pub pid: i32,
    pub alive: bool,
    pub exit_code: Option<i32>,
    pub rows: u16,
    pub cols: u16,
    /// Unix epoch seconds when the current child was spawned.
    pub started_at: u64,
    /// Unix epoch seconds of the last output activity.
    pub last_activity: u64,
    /// Human-readable agent display name (e.g. "default-agent #20").
    pub display_name: Option<String>,
}

impl AgentInfo {
    pub fn instance_id(&self) -> &str {
        &self.instance_id
    }

    pub fn shell_id(&self) -> &str {
        &self.instance_id
    }
}

/// A row in the shell listing: one registered shell's live state.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct ShellInfo {
    pub shell_id: String,
    pub program: String,
    pub pid: i32,
    pub alive: bool,
    pub exit_code: Option<i32>,
    pub rows: u16,
    pub cols: u16,
    /// Unix epoch seconds when the current child was spawned.
    pub started_at: u64,
    /// Unix epoch seconds of the last output activity.
    pub last_activity: u64,
    /// Human-readable display name (e.g. "default-agent #20").
    pub display_name: Option<String>,
    /// TCP port bound by this shell session; None when unknown (Phase 1: always None).
    pub bound_port: Option<u16>,
}

impl ShellInfo {
    pub fn shell_id(&self) -> &str {
        &self.shell_id
    }

    /// Backward-compatible instance_id accessor.
    pub fn instance_id(&self) -> &str {
        &self.shell_id
    }
}

/// A registered shell session entity in ham-pty-host.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Shell {
    pub shell_id: String,
    pub program: String,
    pub pid: i32,
    pub alive: bool,
    pub exit_code: Option<i32>,
    pub rows: u16,
    pub cols: u16,
    /// Unix epoch seconds when the current child was spawned.
    pub started_at: u64,
    /// Unix epoch seconds of the last output activity.
    pub last_activity: u64,
    /// Human-readable display name (e.g. "default-agent #20").
    pub display_name: Option<String>,
    /// TCP port bound by this shell session; None when unknown (Phase 1: always None).
    pub bound_port: Option<u16>,
}

impl Shell {
    pub fn shell_id(&self) -> &str {
        &self.shell_id
    }

    /// Backward-compatible instance_id accessor.
    pub fn instance_id(&self) -> &str {
        &self.shell_id
    }

    pub fn info(&self) -> ShellInfo {
        ShellInfo {
            shell_id: self.shell_id.clone(),
            program: self.program.clone(),
            pid: self.pid,
            alive: self.alive,
            exit_code: self.exit_code,
            rows: self.rows,
            cols: self.cols,
            started_at: self.started_at,
            last_activity: self.last_activity,
            display_name: self.display_name.clone(),
            bound_port: self.bound_port,
        }
    }
}

impl From<Shell> for ShellInfo {
    fn from(s: Shell) -> Self {
        s.info()
    }
}

impl From<ShellInfo> for Shell {
    fn from(info: ShellInfo) -> Self {
        Self {
            shell_id: info.shell_id,
            program: info.program,
            pid: info.pid,
            alive: info.alive,
            exit_code: info.exit_code,
            rows: info.rows,
            cols: info.cols,
            started_at: info.started_at,
            last_activity: info.last_activity,
            display_name: info.display_name,
            bound_port: info.bound_port,
        }
    }
}

impl From<AgentInfo> for ShellInfo {
    fn from(a: AgentInfo) -> Self {
        Self {
            shell_id: a.instance_id,
            program: a.program,
            pid: a.pid,
            alive: a.alive,
            exit_code: a.exit_code,
            rows: a.rows,
            cols: a.cols,
            started_at: a.started_at,
            last_activity: a.last_activity,
            display_name: a.display_name,
            bound_port: None,
        }
    }
}

impl From<ShellInfo> for AgentInfo {
    fn from(s: ShellInfo) -> Self {
        Self {
            instance_id: s.shell_id,
            program: s.program,
            pid: s.pid,
            alive: s.alive,
            exit_code: s.exit_code,
            rows: s.rows,
            cols: s.cols,
            started_at: s.started_at,
            last_activity: s.last_activity,
            display_name: s.display_name,
        }
    }
}

impl From<AgentInfo> for Shell {
    fn from(a: AgentInfo) -> Self {
        ShellInfo::from(a).into()
    }
}

impl From<Shell> for AgentInfo {
    fn from(s: Shell) -> Self {
        s.info().into()
    }
}

/// Signal request: send a POSIX signal to a shell's process group.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SignalRequest {
    pub shell_id: String,
    /// POSIX signal number (e.g. 15=SIGTERM, 2=SIGINT, 9=SIGKILL).
    pub signal: u8,
}

/// client -> daemon.
// SpawnRequest contains serde_json::Value (not Eq), so Eq is not derived.
#[derive(Clone, Debug, PartialEq)]
pub enum CtlMsg {
    // control plane
    Spawn(SpawnRequest),
    Close { instance: String },
    Restart { instance: String },
    List,
    // data plane (instance-scoped)
    Attach { instance: String },
    Input { instance: String, data: Vec<u8> },
    /// REQ-START-3: exactly one startup instruction per child. A repeated request
    /// returns its receipt; a different launch key/pid is rejected before input.
    StartupInput { instance: String, pid: i32, launch_key: String, data: Vec<u8> },
    Key { instance: String, key: NamedKey },
    Resize { instance: String, rows: u16, cols: u16 },
    Capture { instance: String },
    Detach { instance: String },
    Ping,
    /// Subscribe this connection to host-level async events (HostHeartbeat plus
    /// the per-instance lifecycle signals ChildExited / ScreenChanged /
    /// StartupReady / StartupBlocked) WITHOUT attaching to any instance's raw
    /// Output. The bridge's single long-lived event connection sends this once so
    /// it receives liveness/lifecycle for ALL agents; one-shot control
    /// connections do NOT send it and thus keep clean request/reply streams.
    WatchEvents,
    /// Stop every agent and terminate the daemon process (HOST-1 `stop`).
    Shutdown,
    /// Send a POSIX signal to a shell's process group (tag 0x39).
    Signal(SignalRequest),
}

/// daemon -> client.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CtlReply {
    StartupInputDone { instance: String, pid: i32, launch_key: String },
    Spawned { instance: String, pid: i32 },
    Closed { instance: String },
    Restarted { instance: String, pid: i32 },
    AgentList(Vec<AgentInfo>),
    Output { instance: String, data: Vec<u8> },
    Screen { instance: String, screen: ScreenSnapshot },
    ChildExited { instance: String, code: i32 },
    Pong,
    Error { instance: String, message: String },
    /// HOST-2: startup detection succeeded (no blocked pattern within probe).
    StartupReady { instance: String },
    /// HOST-2: startup detection blocked (login/quota/error prompt, or unknown
    /// with startup_unknown_is_blocked). Carries the sanitized reason.
    StartupBlocked {
        instance: String,
        reason_code: String,
        safe_diagnostic: String,
    },
    /// HOST-2: content-change (activity) dirty signal. `hash` is a cheap content
    /// hash of the rendered screen; the bridge classifies activity from the
    /// change stream without polling (spinner masking is bridge-side).
    ScreenChanged { instance: String, hash: u64 },
    /// Periodic host-level liveness digest broadcast to every connected client
    /// on a fixed cadence. It carries the full agent roster with each child's
    /// alive flag so the bridge can refresh per-instance last_seen from a SINGLE
    /// pushed frame instead of polling `List`. `ChildExited` remains the instant,
    /// authoritative death signal; this digest is only the silent-failure/idle
    /// liveness backstop.
    HostHeartbeat { ts_unix_ms: u64, agents: Vec<HostHeartbeatAgent> },
    /// Ack for [`CtlMsg::Shutdown`]: the daemon accepted the request and is
    /// terminating (all agents stopped). The socket closes right after.
    ShuttingDown,
    /// REQ-STREAM-EVENT-2: stream attached and ready to accept input/output.
    StreamReady { instance: String },
    /// REQ-STREAM-EVENT-2: stream closed (child exited or teardown).
    StreamClosed { instance: String, code: Option<i32> },
    /// REQ-PTY-1: reply to [`CtlMsg::Signal`] when the target's child has
    /// already exited (its tombstone is still registered). Distinct from
    /// `Error` so the caller can finalize the session with `code` instead of
    /// treating the refused signal as a failure. The daemon never signals a
    /// reaped pid, since its process group id may have been reused.
    AlreadyExited { instance: String, code: i32 },
}

/// One agent's liveness entry inside a [`CtlReply::HostHeartbeat`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HostHeartbeatAgent {
    pub instance_id: String,
    pub alive: bool,
}

// ---- tags ---------------------------------------------------------------

const T_SPAWN: u8 = 0x20;
const T_CLOSE: u8 = 0x21;
const T_RESTART: u8 = 0x22;
const T_LIST: u8 = 0x23;
const T_ATTACH: u8 = 0x30;
const T_INPUT: u8 = 0x31;
const T_KEY: u8 = 0x32;
const T_RESIZE: u8 = 0x33;
const T_CAPTURE: u8 = 0x34;
const T_DETACH: u8 = 0x35;
const T_PING: u8 = 0x36;
const T_SHUTDOWN: u8 = 0x37;
const T_WATCH_EVENTS: u8 = 0x38;
const T_SIGNAL: u8 = 0x39;
const T_STARTUP_INPUT: u8 = 0x3A;

const T_SPAWNED: u8 = 0xA0;
const T_CLOSED: u8 = 0xA1;
const T_RESTARTED: u8 = 0xA2;
const T_AGENTLIST: u8 = 0xA3;
const T_OUTPUT: u8 = 0xA4;
const T_SCREEN: u8 = 0xA5;
const T_EXITED: u8 = 0xA6;
const T_PONG: u8 = 0xA7;
const T_ERROR: u8 = 0xA8;
const T_STARTUP_READY: u8 = 0xA9;
const T_STARTUP_BLOCKED: u8 = 0xAA;
const T_SCREEN_CHANGED: u8 = 0xAB;
const T_SHUTTING_DOWN: u8 = 0xAC;
const T_HOST_HEARTBEAT: u8 = 0xAD;
pub const T_STREAM_READY: u8 = 0xAE;
pub const T_STREAM_CLOSED: u8 = 0xAF;
pub const T_ALREADY_EXITED: u8 = 0xB0;
const T_STARTUP_INPUT_DONE: u8 = 0xB1;

// ---- primitive codecs ---------------------------------------------------

fn put_str(p: &mut Vec<u8>, s: &str) {
    let b = s.as_bytes();
    p.extend_from_slice(&(b.len() as u32).to_be_bytes());
    p.extend_from_slice(b);
}

fn get_str(rest: &[u8], off: &mut usize) -> io::Result<String> {
    if *off + 4 > rest.len() {
        return Err(bad("string len truncated"));
    }
    let len = u32::from_be_bytes([rest[*off], rest[*off + 1], rest[*off + 2], rest[*off + 3]])
        as usize;
    *off += 4;
    if *off + len > rest.len() {
        return Err(bad("string body truncated"));
    }
    let s = String::from_utf8_lossy(&rest[*off..*off + len]).into_owned();
    *off += len;
    Ok(s)
}

fn put_opt_str(p: &mut Vec<u8>, s: &Option<String>) {
    match s {
        Some(v) => {
            p.push(1);
            put_str(p, v);
        }
        None => p.push(0),
    }
}

fn get_opt_str(rest: &[u8], off: &mut usize) -> io::Result<Option<String>> {
    let present = *rest.get(*off).ok_or_else(|| bad("opt-str tag missing"))?;
    *off += 1;
    match present {
        0 => Ok(None),
        1 => Ok(Some(get_str(rest, off)?)),
        _ => Err(bad("bad opt-str tag")),
    }
}

fn put_opt_u64(p: &mut Vec<u8>, v: Option<u64>) {
    match v {
        Some(value) => {
            p.push(1);
            put_u64(p, value);
        }
        None => p.push(0),
    }
}

fn get_opt_u64(rest: &[u8], off: &mut usize) -> io::Result<Option<u64>> {
    let present = *rest.get(*off).ok_or_else(|| bad("opt-u64 tag missing"))?;
    *off += 1;
    match present {
        0 => Ok(None),
        1 => Ok(Some(get_u64(rest, off)?)),
        _ => Err(bad("bad opt-u64 tag")),
    }
}

fn put_u16(p: &mut Vec<u8>, v: u16) {
    p.extend_from_slice(&v.to_be_bytes());
}

fn get_u16(rest: &[u8], off: &mut usize) -> io::Result<u16> {
    if *off + 2 > rest.len() {
        return Err(bad("u16 truncated"));
    }
    let v = u16::from_be_bytes([rest[*off], rest[*off + 1]]);
    *off += 2;
    Ok(v)
}

fn put_i32(p: &mut Vec<u8>, v: i32) {
    p.extend_from_slice(&v.to_be_bytes());
}

fn get_i32(rest: &[u8], off: &mut usize) -> io::Result<i32> {
    if *off + 4 > rest.len() {
        return Err(bad("i32 truncated"));
    }
    let v = i32::from_be_bytes([rest[*off], rest[*off + 1], rest[*off + 2], rest[*off + 3]]);
    *off += 4;
    Ok(v)
}

fn put_u64(p: &mut Vec<u8>, v: u64) {
    p.extend_from_slice(&v.to_be_bytes());
}

fn get_u64(rest: &[u8], off: &mut usize) -> io::Result<u64> {
    if *off + 8 > rest.len() {
        return Err(bad("u64 truncated"));
    }
    let mut b = [0u8; 8];
    b.copy_from_slice(&rest[*off..*off + 8]);
    *off += 8;
    Ok(u64::from_be_bytes(b))
}

fn put_screen(p: &mut Vec<u8>, s: &ScreenSnapshot) {
    put_u16(p, s.rows);
    put_u16(p, s.cols);
    put_u16(p, s.cursor_row);
    put_u16(p, s.cursor_col);
    put_u16(p, s.lines.len() as u16);
    for line in &s.lines {
        put_str(p, line);
    }
}

fn get_screen(rest: &[u8], off: &mut usize) -> io::Result<ScreenSnapshot> {
    let rows = get_u16(rest, off)?;
    let cols = get_u16(rest, off)?;
    let cursor_row = get_u16(rest, off)?;
    let cursor_col = get_u16(rest, off)?;
    let n = get_u16(rest, off)? as usize;
    let mut lines = Vec::with_capacity(n);
    for _ in 0..n {
        lines.push(get_str(rest, off)?);
    }
    Ok(ScreenSnapshot {
        rows,
        cols,
        cursor_row,
        cursor_col,
        lines,
    })
}

// ---- CtlMsg codec -------------------------------------------------------

impl CtlMsg {
    pub fn shell_id(&self) -> Option<&str> {
        match self {
            CtlMsg::Spawn(req) => Some(&req.instance),
            CtlMsg::Close { instance } => Some(instance),
            CtlMsg::Restart { instance } => Some(instance),
            CtlMsg::Attach { instance } => Some(instance),
            CtlMsg::Input { instance, .. } => Some(instance),
            CtlMsg::StartupInput { instance, .. } => Some(instance),
            CtlMsg::Key { instance, .. } => Some(instance),
            CtlMsg::Resize { instance, .. } => Some(instance),
            CtlMsg::Capture { instance } => Some(instance),
            CtlMsg::Detach { instance } => Some(instance),
            CtlMsg::Signal(req) => Some(&req.shell_id),
            _ => None,
        }
    }

    pub fn instance_id(&self) -> Option<&str> {
        self.shell_id()
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut p = Vec::new();
        match self {
            CtlMsg::Spawn(req) => {
                p.push(T_SPAWN);
                put_str(&mut p, &req.instance);
                put_u16(&mut p, req.argv.len() as u16);
                for a in &req.argv {
                    put_str(&mut p, a);
                }
                put_opt_str(&mut p, &req.cwd);
                put_u16(&mut p, req.env.len() as u16);
                for (k, v) in &req.env {
                    put_str(&mut p, k);
                    put_str(&mut p, v);
                }
                put_opt_str(&mut p, &req.detect);
                put_u16(&mut p, req.rows);
                put_u16(&mut p, req.cols);
                put_opt_str(&mut p, &req.display_name);
                // Backward-compat appended fields (absent on old clients → None).
                put_opt_str(&mut p, &req.kind);
                put_opt_str(&mut p, &req.label);
                let meta_str = req.meta.as_ref().map(|v| v.to_string());
                put_opt_str(&mut p, &meta_str);
                put_opt_str(&mut p, &req.tee_path);
                put_opt_u64(&mut p, req.timeout_seconds);
            }
            CtlMsg::Close { instance } => {
                p.push(T_CLOSE);
                put_str(&mut p, instance);
            }
            CtlMsg::Restart { instance } => {
                p.push(T_RESTART);
                put_str(&mut p, instance);
            }
            CtlMsg::List => p.push(T_LIST),
            CtlMsg::Attach { instance } => {
                p.push(T_ATTACH);
                put_str(&mut p, instance);
            }
            CtlMsg::Input { instance, data } => {
                p.push(T_INPUT);
                put_str(&mut p, instance);
                p.extend_from_slice(data);
            }
            CtlMsg::StartupInput { instance, pid, launch_key, data } => {
                p.push(T_STARTUP_INPUT);
                put_str(&mut p, instance);
                put_i32(&mut p, *pid);
                put_str(&mut p, launch_key);
                p.extend_from_slice(data);
            }
            CtlMsg::Key { instance, key } => {
                p.push(T_KEY);
                put_str(&mut p, instance);
                p.push(*key as u8);
            }
            CtlMsg::Resize { instance, rows, cols } => {
                p.push(T_RESIZE);
                put_str(&mut p, instance);
                put_u16(&mut p, *rows);
                put_u16(&mut p, *cols);
            }
            CtlMsg::Capture { instance } => {
                p.push(T_CAPTURE);
                put_str(&mut p, instance);
            }
            CtlMsg::Detach { instance } => {
                p.push(T_DETACH);
                put_str(&mut p, instance);
            }
            CtlMsg::Ping => p.push(T_PING),
            CtlMsg::WatchEvents => p.push(T_WATCH_EVENTS),
            CtlMsg::Shutdown => p.push(T_SHUTDOWN),
            CtlMsg::Signal(req) => {
                p.push(T_SIGNAL);
                put_str(&mut p, &req.shell_id);
                p.push(req.signal);
            }
        }
        frame(&p)
    }

    fn decode_payload(p: &[u8]) -> io::Result<CtlMsg> {
        let tag = *p.first().ok_or_else(|| bad("empty payload"))?;
        let rest = &p[1..];
        let mut off = 0usize;
        Ok(match tag {
            T_SPAWN => {
                let instance = get_str(rest, &mut off)?;
                let n = get_u16(rest, &mut off)? as usize;
                let mut argv = Vec::with_capacity(n);
                for _ in 0..n {
                    argv.push(get_str(rest, &mut off)?);
                }
                let cwd = get_opt_str(rest, &mut off)?;
                let ne = get_u16(rest, &mut off)? as usize;
                let mut env = Vec::with_capacity(ne);
                for _ in 0..ne {
                    let k = get_str(rest, &mut off)?;
                    let v = get_str(rest, &mut off)?;
                    env.push((k, v));
                }
                let detect = get_opt_str(rest, &mut off)?;
                let rows = get_u16(rest, &mut off)?;
                let cols = get_u16(rest, &mut off)?;
                let display_name = get_opt_str(rest, &mut off)?;
                // Optional shell metadata precedes the required timeout option.
                let kind = if off < rest.len() { get_opt_str(rest, &mut off)? } else { None };
                let label = if off < rest.len() { get_opt_str(rest, &mut off)? } else { None };
                let meta_str = if off < rest.len() { get_opt_str(rest, &mut off)? } else { None };
                let meta = meta_str.and_then(|s| serde_json::from_str(&s).ok());
                let tee_path = if off < rest.len() { get_opt_str(rest, &mut off)? } else { None };
                let timeout_seconds = get_opt_u64(rest, &mut off)?;
                CtlMsg::Spawn(SpawnRequest {
                    instance,
                    argv,
                    cwd,
                    env,
                    detect,
                    rows,
                    cols,
                    display_name,
                    kind,
                    label,
                    meta,
                    tee_path,
                    timeout_seconds,
                })
            }
            T_CLOSE => CtlMsg::Close {
                instance: get_str(rest, &mut off)?,
            },
            T_RESTART => CtlMsg::Restart {
                instance: get_str(rest, &mut off)?,
            },
            T_LIST => CtlMsg::List,
            T_ATTACH => CtlMsg::Attach {
                instance: get_str(rest, &mut off)?,
            },
            T_INPUT => {
                let instance = get_str(rest, &mut off)?;
                CtlMsg::Input {
                    instance,
                    data: rest[off..].to_vec(),
                }
            }
            T_STARTUP_INPUT => {
                let instance = get_str(rest, &mut off)?;
                let pid = get_i32(rest, &mut off)?;
                let launch_key = get_str(rest, &mut off)?;
                CtlMsg::StartupInput { instance, pid, launch_key, data: rest[off..].to_vec() }
            }
            T_KEY => {
                let instance = get_str(rest, &mut off)?;
                let code = *rest.get(off).ok_or_else(|| bad("key missing code"))?;
                CtlMsg::Key {
                    instance,
                    key: NamedKey::from_u8(code).ok_or_else(|| bad("bad key code"))?,
                }
            }
            T_RESIZE => {
                let instance = get_str(rest, &mut off)?;
                let rows = get_u16(rest, &mut off)?;
                let cols = get_u16(rest, &mut off)?;
                CtlMsg::Resize { instance, rows, cols }
            }
            T_CAPTURE => CtlMsg::Capture {
                instance: get_str(rest, &mut off)?,
            },
            T_DETACH => CtlMsg::Detach {
                instance: get_str(rest, &mut off)?,
            },
            T_PING => CtlMsg::Ping,
            T_WATCH_EVENTS => CtlMsg::WatchEvents,
            T_SHUTDOWN => CtlMsg::Shutdown,
            T_SIGNAL => {
                let shell_id = get_str(rest, &mut off)?;
                let signal = *rest.get(off).ok_or_else(|| bad("signal byte missing"))?;
                CtlMsg::Signal(SignalRequest { shell_id, signal })
            }
            _ => return Err(bad("unknown ctl tag")),
        })
    }
}

// ---- CtlReply codec -----------------------------------------------------

impl CtlReply {
    pub fn shell_id(&self) -> Option<&str> {
        match self {
            CtlReply::Spawned { instance, .. } => Some(instance),
            CtlReply::Closed { instance } => Some(instance),
            CtlReply::Restarted { instance, .. } => Some(instance),
            CtlReply::Output { instance, .. } => Some(instance),
            CtlReply::Screen { instance, .. } => Some(instance),
            CtlReply::ChildExited { instance, .. } => Some(instance),
            CtlReply::Error { instance, .. } => Some(instance),
            CtlReply::StartupReady { instance } => Some(instance),
            CtlReply::StartupBlocked { instance, .. } => Some(instance),
            CtlReply::ScreenChanged { instance, .. } => Some(instance),
            CtlReply::StreamReady { instance } => Some(instance),
            CtlReply::StreamClosed { instance, .. } => Some(instance),
            CtlReply::AlreadyExited { instance, .. } => Some(instance),
            CtlReply::StartupInputDone { instance, .. } => Some(instance),
            _ => None,
        }
    }

    pub fn instance_id(&self) -> Option<&str> {
        self.shell_id()
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut p = Vec::new();
        match self {
            CtlReply::StartupInputDone { instance, pid, launch_key } => {
                p.push(T_STARTUP_INPUT_DONE);
                put_str(&mut p, instance);
                put_i32(&mut p, *pid);
                put_str(&mut p, launch_key);
            }
            CtlReply::Spawned { instance, pid } => {
                p.push(T_SPAWNED);
                put_str(&mut p, instance);
                put_i32(&mut p, *pid);
            }
            CtlReply::Closed { instance } => {
                p.push(T_CLOSED);
                put_str(&mut p, instance);
            }
            CtlReply::Restarted { instance, pid } => {
                p.push(T_RESTARTED);
                put_str(&mut p, instance);
                put_i32(&mut p, *pid);
            }
            CtlReply::AgentList(agents) => {
                p.push(T_AGENTLIST);
                put_u16(&mut p, agents.len() as u16);
                for a in agents {
                    put_str(&mut p, &a.instance_id);
                    put_str(&mut p, &a.program);
                    put_i32(&mut p, a.pid);
                    p.push(a.alive as u8);
                    match a.exit_code {
                        Some(c) => {
                            p.push(1);
                            put_i32(&mut p, c);
                        }
                        None => p.push(0),
                    }
                    put_u16(&mut p, a.rows);
                    put_u16(&mut p, a.cols);
                    put_u64(&mut p, a.started_at);
                    put_u64(&mut p, a.last_activity);
                    put_opt_str(&mut p, &a.display_name);
                }
            }
            CtlReply::Output { instance, data } => {
                p.push(T_OUTPUT);
                put_str(&mut p, instance);
                p.extend_from_slice(data);
            }
            CtlReply::Screen { instance, screen } => {
                p.push(T_SCREEN);
                put_str(&mut p, instance);
                put_screen(&mut p, screen);
            }
            CtlReply::ChildExited { instance, code } => {
                p.push(T_EXITED);
                put_str(&mut p, instance);
                put_i32(&mut p, *code);
            }
            CtlReply::Pong => p.push(T_PONG),
            CtlReply::Error { instance, message } => {
                p.push(T_ERROR);
                put_str(&mut p, instance);
                put_str(&mut p, message);
            }
            CtlReply::StartupReady { instance } => {
                p.push(T_STARTUP_READY);
                put_str(&mut p, instance);
            }
            CtlReply::StartupBlocked {
                instance,
                reason_code,
                safe_diagnostic,
            } => {
                p.push(T_STARTUP_BLOCKED);
                put_str(&mut p, instance);
                put_str(&mut p, reason_code);
                put_str(&mut p, safe_diagnostic);
            }
            CtlReply::ScreenChanged { instance, hash } => {
                p.push(T_SCREEN_CHANGED);
                put_str(&mut p, instance);
                put_u64(&mut p, *hash);
            }
            CtlReply::HostHeartbeat { ts_unix_ms, agents } => {
                p.push(T_HOST_HEARTBEAT);
                put_u64(&mut p, *ts_unix_ms);
                put_u16(&mut p, agents.len() as u16);
                for a in agents {
                    put_str(&mut p, &a.instance_id);
                    p.push(a.alive as u8);
                }
            }
            CtlReply::ShuttingDown => p.push(T_SHUTTING_DOWN),
            CtlReply::StreamReady { instance } => {
                p.push(T_STREAM_READY);
                put_str(&mut p, instance);
            }
            CtlReply::StreamClosed { instance, code } => {
                p.push(T_STREAM_CLOSED);
                put_str(&mut p, instance);
                match code {
                    Some(c) => {
                        p.push(1);
                        put_i32(&mut p, *c);
                    }
                    None => p.push(0),
                }
            }
            CtlReply::AlreadyExited { instance, code } => {
                p.push(T_ALREADY_EXITED);
                put_str(&mut p, instance);
                put_i32(&mut p, *code);
            }
        }
        frame(&p)
    }

    fn decode_payload(p: &[u8]) -> io::Result<CtlReply> {
        let tag = *p.first().ok_or_else(|| bad("empty payload"))?;
        let rest = &p[1..];
        let mut off = 0usize;
        Ok(match tag {
            T_SPAWNED => {
                let instance = get_str(rest, &mut off)?;
                CtlReply::Spawned {
                    instance,
                    pid: get_i32(rest, &mut off)?,
                }
            }
            T_CLOSED => CtlReply::Closed {
                instance: get_str(rest, &mut off)?,
            },
            T_RESTARTED => {
                let instance = get_str(rest, &mut off)?;
                CtlReply::Restarted {
                    instance,
                    pid: get_i32(rest, &mut off)?,
                }
            }
            T_AGENTLIST => {
                let n = get_u16(rest, &mut off)? as usize;
                let mut agents = Vec::with_capacity(n);
                for _ in 0..n {
                    let instance_id = get_str(rest, &mut off)?;
                    let program = get_str(rest, &mut off)?;
                    let pid = get_i32(rest, &mut off)?;
                    let alive = *rest.get(off).ok_or_else(|| bad("alive missing"))? != 0;
                    off += 1;
                    let has_code = *rest.get(off).ok_or_else(|| bad("exit tag missing"))?;
                    off += 1;
                    let exit_code = if has_code == 1 {
                        Some(get_i32(rest, &mut off)?)
                    } else {
                        None
                    };
                    let rows = get_u16(rest, &mut off)?;
                    let cols = get_u16(rest, &mut off)?;
                    let started_at = get_u64(rest, &mut off)?;
                    let last_activity = get_u64(rest, &mut off)?;
                    let display_name = get_opt_str(rest, &mut off)?;
                    agents.push(AgentInfo {
                        instance_id,
                        program,
                        pid,
                        alive,
                        exit_code,
                        rows,
                        cols,
                        started_at,
                        last_activity,
                        display_name,
                    });
                }
                CtlReply::AgentList(agents)
            }
            T_OUTPUT => {
                let instance = get_str(rest, &mut off)?;
                CtlReply::Output {
                    instance,
                    data: rest[off..].to_vec(),
                }
            }
            T_SCREEN => {
                let instance = get_str(rest, &mut off)?;
                CtlReply::Screen {
                    instance,
                    screen: get_screen(rest, &mut off)?,
                }
            }
            T_EXITED => {
                let instance = get_str(rest, &mut off)?;
                CtlReply::ChildExited {
                    instance,
                    code: get_i32(rest, &mut off)?,
                }
            }
            T_PONG => CtlReply::Pong,
            T_ERROR => {
                let instance = get_str(rest, &mut off)?;
                CtlReply::Error {
                    instance,
                    message: get_str(rest, &mut off)?,
                }
            }
            T_SHUTTING_DOWN => CtlReply::ShuttingDown,
            T_STARTUP_READY => CtlReply::StartupReady {
                instance: get_str(rest, &mut off)?,
            },
            T_STARTUP_BLOCKED => {
                let instance = get_str(rest, &mut off)?;
                let reason_code = get_str(rest, &mut off)?;
                let safe_diagnostic = get_str(rest, &mut off)?;
                CtlReply::StartupBlocked {
                    instance,
                    reason_code,
                    safe_diagnostic,
                }
            }
            T_SCREEN_CHANGED => {
                let instance = get_str(rest, &mut off)?;
                CtlReply::ScreenChanged {
                    instance,
                    hash: get_u64(rest, &mut off)?,
                }
            }
            T_HOST_HEARTBEAT => {
                let ts_unix_ms = get_u64(rest, &mut off)?;
                let n = get_u16(rest, &mut off)? as usize;
                let mut agents = Vec::with_capacity(n);
                for _ in 0..n {
                    let instance_id = get_str(rest, &mut off)?;
                    let alive = *rest.get(off).ok_or_else(|| bad("host heartbeat: short alive"))? != 0;
                    off += 1;
                    agents.push(HostHeartbeatAgent { instance_id, alive });
                }
                CtlReply::HostHeartbeat { ts_unix_ms, agents }
            }
            T_STREAM_READY => {
                let instance = get_str(rest, &mut off)?;
                CtlReply::StreamReady { instance }
            }
            T_STREAM_CLOSED => {
                let instance = get_str(rest, &mut off)?;
                let has_code = *rest.get(off).ok_or_else(|| bad("stream closed: code flag missing"))?;
                off += 1;
                let code = if has_code == 1 {
                    Some(get_i32(rest, &mut off)?)
                } else {
                    None
                };
                CtlReply::StreamClosed { instance, code }
            }
            T_ALREADY_EXITED => {
                let instance = get_str(rest, &mut off)?;
                CtlReply::AlreadyExited {
                    instance,
                    code: get_i32(rest, &mut off)?,
                }
            }
            T_STARTUP_INPUT_DONE => CtlReply::StartupInputDone {
                instance: get_str(rest, &mut off)?,
                pid: get_i32(rest, &mut off)?,
                launch_key: get_str(rest, &mut off)?,
            },
            _ => return Err(bad("unknown reply tag")),
        })
    }
}

// ---- framing + IO -------------------------------------------------------

fn frame(payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(4 + payload.len());
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    out.extend_from_slice(payload);
    out
}

fn bad(msg: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, msg)
}

/// Read + decode one [`CtlMsg`]. `Ok(None)` on clean EOF.
pub fn read_ctl_msg<R: Read>(r: &mut R) -> io::Result<Option<CtlMsg>> {
    match read_frame(r)? {
        Some(p) => Ok(Some(CtlMsg::decode_payload(&p)?)),
        None => Ok(None),
    }
}

/// Read + decode one [`CtlReply`]. `Ok(None)` on clean EOF.
pub fn read_ctl_reply<R: Read>(r: &mut R) -> io::Result<Option<CtlReply>> {
    match read_frame(r)? {
        Some(p) => Ok(Some(CtlReply::decode_payload(&p)?)),
        None => Ok(None),
    }
}

/// Write a client control message to `w`.
pub fn write_ctl_msg<W: Write>(w: &mut W, msg: &CtlMsg) -> io::Result<()> {
    w.write_all(&msg.encode())?;
    w.flush()
}

/// Write a daemon reply to `w`.
pub fn write_ctl_reply<W: Write>(w: &mut W, reply: &CtlReply) -> io::Result<()> {
    w.write_all(&reply.encode())?;
    w.flush()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn startup_input_wire_roundtrips_and_truncation_is_rejected() {
        let msg = CtlMsg::StartupInput { instance: "inst".into(), pid: 42, launch_key: "launch".into(), data: b"confirm\r".to_vec() };
        round_msg(msg.clone());
        round_reply(CtlReply::StartupInputDone { instance: "inst".into(), pid: 42, launch_key: "launch".into() });
        let encoded = msg.encode();
        assert_eq!(encoded[4], 0x3A);
        // Fixed prefix ends after the launch key; missing fields fail parsing.
        let payload = &encoded[4..];
        let prefix_len = payload.len() - b"confirm\r".len();
        for n in 0..prefix_len {
            assert!(CtlMsg::decode_payload(&payload[..n]).is_err());
        }
    }

    fn round_msg(m: CtlMsg) {
        let bytes = m.encode();
        let mut cur = Cursor::new(bytes);
        let got = read_ctl_msg(&mut cur).unwrap().unwrap();
        assert_eq!(got, m);
    }

    fn round_reply(m: CtlReply) {
        let bytes = m.encode();
        let mut cur = Cursor::new(bytes);
        let got = read_ctl_reply(&mut cur).unwrap().unwrap();
        assert_eq!(got, m);
    }

    #[test]
    fn spawn_request_roundtrips_full() {
        round_msg(CtlMsg::Spawn(SpawnRequest {
            instance: "inst_abc".into(),
            argv: vec!["/bin/zsh".into(), "-l".into()],
            cwd: Some("/work/dir".into()),
            env: vec![
                ("HEIMDALL_AGENT_TOKEN".into(), "hlat_x".into()),
                ("FOO".into(), "bar".into()),
            ],
            detect: Some("{\"auto_enter_patterns\":[\"❯\"]}".into()),
            rows: 40,
            cols: 120,
            display_name: Some("default-agent #20".into()),
            kind: Some("run".into()),
            label: Some("my-worker".into()),
            meta: Some(serde_json::json!({"project": "acme", "priority": 1})),
            tee_path: Some("/var/log/agent_abc.log".into()),
            timeout_seconds: Some(120),
        }));
    }

    #[test]
    fn spawn_request_roundtrips_minimal() {
        round_msg(CtlMsg::Spawn(SpawnRequest {
            instance: "i".into(),
            argv: vec!["true".into()],
            cwd: None,
            env: vec![],
            detect: None,
            rows: 24,
            cols: 80,
            display_name: None,
            kind: None,
            label: None,
            meta: None,
            tee_path: None,
            timeout_seconds: None,
        }));
    }

    #[test]
    fn spawn_request_with_all_optional_fields_absent_roundtrips() {
        let request = CtlMsg::Spawn(SpawnRequest {
            instance: "old".into(),
            argv: vec!["sh".into()],
            cwd: None,
            env: vec![],
            detect: None,
            rows: 24,
            cols: 80,
            display_name: None,
            kind: None,
            label: None,
            meta: None,
            tee_path: None,
            timeout_seconds: None,
        });
        let bytes = request.encode();
        let mut cur = std::io::Cursor::new(bytes);
        let decoded = read_ctl_msg(&mut cur).unwrap().unwrap();
        assert_eq!(decoded, request);
    }

    #[test]
    fn control_msgs_roundtrip() {
        round_msg(CtlMsg::Close { instance: "a".into() });
        round_msg(CtlMsg::Restart { instance: "a".into() });
        round_msg(CtlMsg::List);
        round_msg(CtlMsg::Ping);
        round_msg(CtlMsg::WatchEvents);
        round_msg(CtlMsg::Shutdown);
    }

    #[test]
    fn signal_msg_roundtrips() {
        round_msg(CtlMsg::Signal(SignalRequest { shell_id: "sh_1".into(), signal: 15 }));
        round_msg(CtlMsg::Signal(SignalRequest { shell_id: "sh_2".into(), signal: 9 }));
        round_msg(CtlMsg::Signal(SignalRequest { shell_id: "sh_3".into(), signal: 2 }));
        // shell_id accessor
        let msg = CtlMsg::Signal(SignalRequest { shell_id: "target".into(), signal: 15 });
        assert_eq!(msg.shell_id(), Some("target"));
        assert_eq!(msg.instance_id(), Some("target"));
    }

    #[test]
    fn data_plane_msgs_roundtrip() {
        round_msg(CtlMsg::Attach { instance: "a".into() });
        round_msg(CtlMsg::Input {
            instance: "a".into(),
            data: b"echo hi\n".to_vec(),
        });
        round_msg(CtlMsg::Key {
            instance: "a".into(),
            key: NamedKey::Enter,
        });
        round_msg(CtlMsg::Resize {
            instance: "a".into(),
            rows: 50,
            cols: 200,
        });
        round_msg(CtlMsg::Capture { instance: "a".into() });
        round_msg(CtlMsg::Detach { instance: "a".into() });
    }

    #[test]
    fn replies_roundtrip() {
        round_reply(CtlReply::Spawned {
            instance: "a".into(),
            pid: 4242,
        });
        round_reply(CtlReply::Closed { instance: "a".into() });
        round_reply(CtlReply::Restarted {
            instance: "a".into(),
            pid: 99,
        });
        round_reply(CtlReply::Output {
            instance: "a".into(),
            data: b"\x1b[31mred".to_vec(),
        });
        round_reply(CtlReply::ChildExited {
            instance: "a".into(),
            code: 137,
        });
        round_reply(CtlReply::Pong);
        round_reply(CtlReply::Error {
            instance: "a".into(),
            message: "no such instance".into(),
        });
        round_reply(CtlReply::StartupReady { instance: "a".into() });
        round_reply(CtlReply::StartupBlocked {
            instance: "a".into(),
            reason_code: "blocked_0Login_required".into(),
            safe_diagnostic: "Provider login required".into(),
        });
        round_reply(CtlReply::ScreenChanged {
            instance: "a".into(),
            hash: 0xdead_beef_cafe_1234,
        });
        round_reply(CtlReply::HostHeartbeat {
            ts_unix_ms: 1_788_549_000_123,
            agents: vec![
                HostHeartbeatAgent { instance_id: "inst_a".into(), alive: true },
                HostHeartbeatAgent { instance_id: "inst_b".into(), alive: false },
            ],
        });
        round_reply(CtlReply::HostHeartbeat { ts_unix_ms: 0, agents: vec![] });
        round_reply(CtlReply::ShuttingDown);
        round_reply(CtlReply::StreamReady { instance: "sh_ready".into() });
        round_reply(CtlReply::StreamClosed { instance: "sh_closed".into(), code: Some(0) });
        round_reply(CtlReply::StreamClosed { instance: "sh_closed_nocode".into(), code: None });
        round_reply(CtlReply::AlreadyExited { instance: "sh_done".into(), code: 0 });
        round_reply(CtlReply::AlreadyExited { instance: "sh_killed".into(), code: -1 });
    }

    #[test]
    fn agent_list_roundtrips_with_mixed_state() {
        round_reply(CtlReply::AgentList(vec![
            AgentInfo {
                instance_id: "inst_1".into(),
                program: "/bin/zsh".into(),
                pid: 111,
                alive: true,
                exit_code: None,
                rows: 24,
                cols: 80,
                started_at: 1_700_000_000,
                last_activity: 1_700_000_050,
                display_name: Some("default-agent #20".into()),
            },
            AgentInfo {
                instance_id: "inst_2".into(),
                program: "claude".into(),
                pid: 222,
                alive: false,
                exit_code: Some(0),
                rows: 40,
                cols: 120,
                started_at: 1_700_000_100,
                last_activity: 1_700_000_100,
                display_name: None,
            },
        ]));
        round_reply(CtlReply::AgentList(vec![]));
    }

    #[test]
    fn screen_reply_roundtrips() {
        round_reply(CtlReply::Screen {
            instance: "a".into(),
            screen: ScreenSnapshot {
                rows: 3,
                cols: 10,
                cursor_row: 1,
                cursor_col: 2,
                lines: vec!["hello".into(), "".into(), "world".into()],
            },
        });
    }

    #[test]
    fn multiple_frames_in_stream() {
        let mut buf = Vec::new();
        buf.extend_from_slice(&CtlMsg::List.encode());
        buf.extend_from_slice(&CtlMsg::Attach { instance: "x".into() }.encode());
        buf.extend_from_slice(&CtlMsg::Ping.encode());
        let mut cur = Cursor::new(buf);
        assert_eq!(read_ctl_msg(&mut cur).unwrap().unwrap(), CtlMsg::List);
        assert_eq!(
            read_ctl_msg(&mut cur).unwrap().unwrap(),
            CtlMsg::Attach { instance: "x".into() }
        );
        assert_eq!(read_ctl_msg(&mut cur).unwrap().unwrap(), CtlMsg::Ping);
        assert!(read_ctl_msg(&mut cur).unwrap().is_none());
    }

    #[test]
    fn shell_and_shell_info_accessors_and_conversions() {
        let shell = Shell {
            shell_id: "shell_123".into(),
            program: "/bin/bash".into(),
            pid: 456,
            alive: true,
            exit_code: None,
            rows: 25,
            cols: 80,
            started_at: 1_700_000_000,
            last_activity: 1_700_000_010,
            display_name: Some("test shell".into()),
            bound_port: None,
        };

        assert_eq!(shell.shell_id(), "shell_123");
        assert_eq!(shell.instance_id(), "shell_123");

        let info = shell.info();
        assert_eq!(info.shell_id(), "shell_123");
        assert_eq!(info.instance_id(), "shell_123");
        assert_eq!(info.program, "/bin/bash");
        assert_eq!(info.pid, 456);
        assert!(info.alive);
        assert_eq!(info.rows, 25);
        assert_eq!(info.cols, 80);

        // Conversion roundtrips
        let from_info: Shell = info.clone().into();
        assert_eq!(from_info, shell);

        let agent_info: AgentInfo = info.clone().into();
        assert_eq!(agent_info.instance_id(), "shell_123");
        assert_eq!(agent_info.shell_id(), "shell_123");

        let back_to_shell_info: ShellInfo = agent_info.clone().into();
        assert_eq!(back_to_shell_info, info);

        let back_to_shell: Shell = agent_info.into();
        assert_eq!(back_to_shell, shell);
    }

    #[test]
    fn ctl_msg_and_reply_shell_id_accessors() {
        let msg = CtlMsg::Input {
            instance: "sh_abc".into(),
            data: b"ls\n".to_vec(),
        };
        assert_eq!(msg.shell_id(), Some("sh_abc"));
        assert_eq!(msg.instance_id(), Some("sh_abc"));

        let resize_msg = CtlMsg::Resize {
            instance: "sh_def".into(),
            rows: 30,
            cols: 100,
        };
        assert_eq!(resize_msg.shell_id(), Some("sh_def"));
        assert_eq!(resize_msg.instance_id(), Some("sh_def"));

        let ping_msg = CtlMsg::Ping;
        assert_eq!(ping_msg.shell_id(), None);

        let reply = CtlReply::Spawned {
            instance: "sh_1".into(),
            pid: 999,
        };
        assert_eq!(reply.shell_id(), Some("sh_1"));
        assert_eq!(reply.instance_id(), Some("sh_1"));

        let err_reply = CtlReply::Error {
            instance: "sh_err".into(),
            message: "failed".into(),
        };
        assert_eq!(err_reply.shell_id(), Some("sh_err"));
        assert_eq!(err_reply.instance_id(), Some("sh_err"));

        let ready_reply = CtlReply::StreamReady { instance: "sh_ready".into() };
        assert_eq!(ready_reply.shell_id(), Some("sh_ready"));
        assert_eq!(ready_reply.instance_id(), Some("sh_ready"));

        let closed_reply = CtlReply::StreamClosed { instance: "sh_closed".into(), code: Some(1) };
        assert_eq!(closed_reply.shell_id(), Some("sh_closed"));
        assert_eq!(closed_reply.instance_id(), Some("sh_closed"));
    }
}
