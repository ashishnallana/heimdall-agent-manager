//! REQ HOST-1: Per-machine multi-agent PTY daemon.
//!
//! Generalizes the single-pane [`crate::server::HostServer`] into a daemon that
//! manages **N agents keyed by agent-instance-id**. Each agent is an independent
//! [`PtyHost`] (own PTY, child, VT model). The daemon exposes:
//!
//!   * a **control plane** — `spawn` / `close` / `restart` / `list`, and
//!   * a **data plane** — per-instance `attach` / `input` / `key` / `resize` /
//!     `capture`, plus `ChildExited` events.
//!
//! The daemon remembers each agent's [`SpawnRequest`] so `restart` re-spawns the
//! exact same command (argv/cwd/env/detect) under the same instance id without
//! the caller re-plumbing anything.
//!
//! This module is transport-agnostic: [`Daemon`] is a plain in-process API
//! (directly unit-tested), and [`serve`] wraps it on a unix socket speaking
//! [`crate::dproto`]. HOST-2 hangs the per-agent startup detector off the pump
//! thread; HOST-3/4 attach TUIs are just [`crate::dproto`] clients.

use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, Context, Result};

use crate::detect::{screen_hash, DetectAction, Detector, StartupDetectionConfig, StartupOutcome};
use crate::dproto::{self, AgentInfo, CtlMsg, CtlReply, HostHeartbeatAgent, SignalRequest, SpawnRequest};
use crate::host::{PtyHost, SpawnConfig};
use crate::ipc::{UnixListener, UnixStream};
use crate::proto::ScreenSnapshot;

pub use crate::dproto::{Shell, ShellInfo};

/// How long `close`/`restart` wait for a graceful SIGTERM exit before SIGKILL.
const TERM_GRACE: Duration = Duration::from_millis(750);

/// Cadence of the host-level liveness digest ([`Daemon::broadcast_heartbeat`]).
/// Chosen well below the bridge's BRIDGE_WRAPPER_STALE_MS (90s) so several missed
/// ticks never falsely reap a live-but-idle agent. `ChildExited` is the instant
/// death path; this is only the silent-failure/idle backstop.
const HOST_HEARTBEAT_INTERVAL: Duration = Duration::from_secs(30);

/// REQ-PTY-1: how long a finished session's exit watcher waits for the PTY
/// reader to drain the child's last output before closing the master fds.
const PTY_DRAIN_GRACE: Duration = Duration::from_millis(500);

/// REQ-PTY-1: finished sessions stay registered as tombstones (pid, exit code,
/// final screen; no fds) so late `list`/`capture`/`signal` still answer. At most
/// this many are kept, oldest-exited evicted first...
const TOMBSTONE_MAX: usize = 512;
/// ...and none is kept longer than this after its child exited.
const TOMBSTONE_TTL: Duration = Duration::from_secs(60 * 60);

/// REQ-PTY-3: pause before the next `accept` after fd exhaustion, so the accept
/// loop neither spins nor dies while fds are being released.
const ACCEPT_EMFILE_BACKOFF: Duration = Duration::from_millis(100);

/// REQ-PTY-3: the daemon raises its RLIMIT_NOFILE soft limit to the hard limit,
/// capped here.
#[cfg(unix)]
const NOFILE_TARGET: libc::rlim_t = 65536;

/// CRT resolution constants for unattached agents (REQ-CRT-1).
pub const CRT_COLS: u16 = 80;
pub const CRT_ROWS: u16 = 25;

/// Maximum tee log file size before rotation (50 MiB).
const TEE_MAX_BYTES: u64 = 50 * 1024 * 1024;

/// Writes PTY output chunks to a tee file, rotating at [`TEE_MAX_BYTES`].
///
/// Rotation renames `path` → `path.1` (overwriting any prior rotation) then
/// creates a fresh empty file at `path`.  Only one rotation file is kept.
struct TeeWriter {
    file: std::fs::File,
    path: String,
    /// Running total of bytes written to the current `file`.
    written: u64,
}

impl TeeWriter {
    /// Open (or create) `path` in append mode. Returns `None` on I/O error.
    ///
    /// The parent directory is created first: on a fresh install the first
    /// session's tee path pointed into a directory nobody had made yet, so
    /// `openat` returned ENOENT and that session's saved output was lost
    /// (only later sessions, whose directory existed by then, were kept).
    fn open(path: &str) -> Option<Self> {
        if let Some(parent) = std::path::Path::new(path).parent() {
            if !parent.as_os_str().is_empty() {
                if let Err(e) = std::fs::create_dir_all(parent) {
                    eprintln!("[ham-pty-host] tee directory {} could not be created: {e}", parent.display());
                }
            }
        }
        let file = match std::fs::OpenOptions::new().create(true).append(true).open(path) {
            Ok(f) => f,
            Err(e) => {
                eprintln!("[ham-pty-host] tee open failed for {path}: {e}; output will not be saved");
                return None;
            }
        };
        let written = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
        Some(TeeWriter { file, path: path.to_string(), written })
    }

    fn write_chunk(&mut self, data: &[u8]) {
        let _ = self.file.write_all(data);
        self.written += data.len() as u64;
        if self.written >= TEE_MAX_BYTES {
            self.rotate();
        }
    }

    fn rotate(&mut self) {
        let rotated = format!("{}.1", self.path);
        let _ = std::fs::rename(&self.path, &rotated);
        match std::fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(&self.path)
        {
            Ok(f) => {
                self.file = f;
                self.written = 0;
            }
            Err(e) => {
                eprintln!("[ham-pty-host] tee rotate failed for {}: {e}", self.path);
            }
        }
    }
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn now_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// Result of [`Daemon::signal`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SignalOutcome {
    /// `killpg` succeeded.
    Delivered,
    /// The child had already exited with this code; nothing was signalled.
    AlreadyExited(i32),
}

/// Poll `pred` every 10ms until it holds or `timeout` elapses.
fn wait_until(pred: impl Fn() -> bool, timeout: Duration) -> bool {
    let start = Instant::now();
    while start.elapsed() < timeout {
        if pred() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    pred()
}

/// REQ-PTY-1: bound the finished-session tombstones in `agents`: drop those
/// that exited more than `ttl` ago, then the oldest-exited beyond `max`. Live
/// agents are never touched. Dropping a tombstone frees no fds (the exit
/// watcher already released them), only its spec and VT model.
fn prune_tombstones(agents: &mut HashMap<String, Agent>, max: usize, ttl: Duration) {
    let cutoff = now_millis().saturating_sub(ttl.as_millis() as u64);
    let mut exited: Vec<(u64, String)> = agents
        .iter()
        .filter_map(|(id, a)| match a.exited_at.load(Ordering::SeqCst) {
            0 => None,
            at => Some((at, id.clone())),
        })
        .collect();
    exited.sort();
    let over = exited.len().saturating_sub(max);
    for (i, (at, id)) in exited.into_iter().enumerate() {
        if i < over || at < cutoff {
            agents.remove(&id);
        }
    }
}

/// One registered agent: its PTY host + the spec we remember for restart.
struct Agent {
    spec: SpawnRequest,
    host: Arc<Mutex<PtyHost>>,
    alive: Arc<AtomicBool>,
    pid: i32,
    started_at: u64,
    last_activity: Arc<AtomicU64>,
    /// Unix ms at which the exit watcher released this agent's PTY after its
    /// child exited (making it a tombstone); 0 while it is live.
    exited_at: Arc<AtomicU64>,
    /// Set on close/restart so this agent's background threads stop.
    stop: Arc<AtomicBool>,
    pump: Option<JoinHandle<()>>,
    exit_watch: Option<JoinHandle<()>>,
    /// HOST-2: per-agent startup detector + activity-signal thread (only present
    /// when the spec carried a `detect` config).
    detector: Option<JoinHandle<()>>,
    startup_input: StartupInputState,
}

#[derive(Default)]
struct StartupInputState {
    bytes: Option<Vec<u8>>,
    written: usize,
    delivered: bool,
}

impl Agent {
    fn info(&self) -> AgentInfo {
        let alive = self.alive.load(Ordering::SeqCst);
        let exit_code = if alive {
            None
        } else {
            self.host.lock().unwrap().exit_code()
        };
        let (rows, cols) = self.host.lock().unwrap().size();
        AgentInfo {
            instance_id: self.spec.instance.clone(),
            program: self.spec.argv.first().cloned().unwrap_or_default(),
            pid: self.pid,
            alive,
            exit_code,
            rows,
            cols,
            started_at: self.started_at,
            last_activity: self.last_activity.load(Ordering::SeqCst),
            display_name: self.spec.display_name.clone(),
        }
    }

    fn shell_info(&self) -> ShellInfo {
        self.info().into()
    }

    fn shell(&self) -> Shell {
        self.shell_info().into()
    }

    /// Stop the child (SIGTERM -> grace -> SIGKILL) and join background threads.
    fn shutdown(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if self.alive.load(Ordering::SeqCst) {
            self.host.lock().unwrap().terminate();
            let dead = self
                .host
                .lock()
                .unwrap()
                .wait_timeout(TERM_GRACE)
                .is_some();
            if !dead {
                self.host.lock().unwrap().kill();
            }
        }
        // ConPTY only EOFs the reader (ending the pump) once the pseudoconsole
        // is closed, which a dead child alone does not do.
        #[cfg(windows)]
        {
            let mut host = self.host.lock().unwrap();
            host.wait_timeout(TERM_GRACE);
            host.release_pty();
        }
        if let Some(t) = self.pump.take() {
            let _ = t.join();
        }
        if let Some(t) = self.exit_watch.take() {
            let _ = t.join();
        }
        if let Some(t) = self.detector.take() {
            let _ = t.join();
        }
    }
}

// Reply queues are byte-bounded and never block the shared PTY pump. On overflow
// shut down that client; its next attach obtains a complete current screen.
const REPLY_QUEUE_BYTES: usize = 1024 * 1024;
const REPLY_QUEUE_FRAMES: usize = 256;
struct ReplyBudget { bytes: usize, frames: usize, failed: bool }
#[derive(Clone)]
struct ReplySink {
    tx: std::sync::mpsc::Sender<QueuedReply>,
    budget: Arc<Mutex<ReplyBudget>>,
    socket: Option<Arc<UnixStream>>,
}
struct QueuedReply { bytes: Vec<u8>, budget: Arc<Mutex<ReplyBudget>> }
impl Drop for QueuedReply {
    fn drop(&mut self) {
        let mut b = self.budget.lock().unwrap();
        b.bytes -= self.bytes.len();
        b.frames -= 1;
    }
}
fn reply_channel(socket: Option<UnixStream>) -> (ReplySink, Receiver<QueuedReply>) {
    let (tx, rx) = std::sync::mpsc::channel();
    (ReplySink { tx, budget: Arc::new(Mutex::new(ReplyBudget { bytes: 0, frames: 0, failed: false })), socket: socket.map(Arc::new) }, rx)
}
impl ReplySink {
    fn send(&self, reply: CtlReply) -> Result<(), ()> {
        let bytes = reply.encode();
        let mut b = self.budget.lock().unwrap();
        if b.failed { return Err(()); }
        if bytes.len() > REPLY_QUEUE_BYTES.saturating_sub(b.bytes) || b.frames >= REPLY_QUEUE_FRAMES {
            b.failed = true;
            if let Some(socket) = &self.socket { let _ = socket.shutdown(std::net::Shutdown::Both); }
            eprintln!("ham-pty-host: disconnecting slow consumer queued_bytes={}", b.bytes);
            return Err(());
        }
        b.bytes += bytes.len(); b.frames += 1;
        drop(b);
        self.tx.send(QueuedReply { bytes, budget: Arc::clone(&self.budget) }).map_err(|_| ())
    }
}

/// A connected client's event sink + the set of instances it has attached to.
struct Subscriber {
    tx: ReplySink,
    instances: HashSet<String>,
}

type Registry = Arc<Mutex<HashMap<String, Agent>>>;
type Subscribers = Arc<Mutex<HashMap<u64, Subscriber>>>;

/// A registered connection's event sink, before/independent of any Attach.
type Sinks = Arc<Mutex<HashMap<u64, ReplySink>>>;

/// Connections that sent WatchEvents: they receive host-level async events
/// (HostHeartbeat + lifecycle: ChildExited/ScreenChanged/StartupReady/
/// StartupBlocked) for ALL agents without attaching to any instance's Output.
type Watchers = Arc<Mutex<HashMap<u64, ReplySink>>>;

/// The per-machine multi-agent daemon.
#[derive(Clone)]
pub struct Daemon {
    agents: Registry,
    /// Clients that have Attached and are receiving instance-scoped Output.
    subs: Subscribers,
    /// All connected clients' sinks (HOST-5): a sink here is NOT subscribed to
    /// any events until the client Attaches or WatchEvents; control-only clients
    /// live here only, so they never receive async event frames.
    sinks: Sinks,
    /// Connections subscribed to host-level events via WatchEvents. Lifecycle +
    /// heartbeat frames go here (not to all sinks), so one-shot control
    /// connections keep clean request/reply streams (HOST-5).
    watchers: Watchers,
}

impl Default for Daemon {
    fn default() -> Self {
        Self::new()
    }
}

impl Daemon {
    pub fn new() -> Self {
        Daemon {
            agents: Arc::new(Mutex::new(HashMap::new())),
            subs: Arc::new(Mutex::new(HashMap::new())),
            sinks: Arc::new(Mutex::new(HashMap::new())),
            watchers: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// Number of currently-registered agents.
    pub fn agent_count(&self) -> usize {
        self.agents.lock().unwrap().len()
    }

    /// Register + launch a new agent. Errors if `instance` is empty, `argv` is
    /// empty, or the instance id is already registered.
    pub fn spawn(&self, spec: SpawnRequest) -> Result<i32> {
        if spec.instance.is_empty() {
            return Err(anyhow!("spawn: empty instance id"));
        }
        if spec.argv.is_empty() {
            return Err(anyhow!("spawn: empty argv"));
        }
        if spec.timeout_seconds == Some(0) {
            return Err(anyhow!("spawn: timeout_seconds must be greater than zero"));
        }
        {
            let agents = self.agents.lock().unwrap();
            if agents.contains_key(&spec.instance) {
                return Err(anyhow!("spawn: instance {} already exists", spec.instance));
            }
        }
        let agent = self.build_agent(spec)?;
        let pid = agent.pid;
        let instance = agent.spec.instance.clone();
        let mut agents = self.agents.lock().unwrap();
        agents.insert(instance, agent);
        prune_tombstones(&mut agents, TOMBSTONE_MAX, TOMBSTONE_TTL);
        Ok(pid)
    }

    /// Build + start an [`Agent`] (PTY spawn + pump + exit watcher) from a spec.
    fn build_agent(&self, spec: SpawnRequest) -> Result<Agent> {
        let rows = if spec.rows == 0 { CRT_ROWS } else { spec.rows };
        let cols = if spec.cols == 0 { CRT_COLS } else { spec.cols };
        let program = spec.argv[0].clone();
        let args = spec.argv[1..].to_vec();
        let config = SpawnConfig {
            program,
            args,
            rows,
            cols,
            // The daemon manages explicit agent commands (e.g. `claude`, a
            // wrapper, a shell the caller chose) — NOT login shells. Forcing a
            // login shell (`-l`) is both semantically wrong here and
            // environment-sensitive: a login `sh` re-sources /etc/profile +
            // ~/.profile, which on some machines mutates the injected env,
            // prints banners, or redraws the screen. That made an env-var
            // assertion pass on one machine and fail on another. The caller
            // controls login behavior explicitly via argv (e.g. `-- /bin/zsh -l`).
            login_shell: false,
            cwd: spec.cwd.clone(),
            extra_env: spec.env.clone(),
        };
        let mut host = PtyHost::spawn(config)
            .with_context(|| format!("spawn agent {}", spec.instance))?;
        let pid = host.pid();
        let alive = host.alive_flag();
        let output_rx = host.take_output_rx().expect("fresh host has output rx");
        let last_activity = Arc::new(AtomicU64::new(now_secs()));
        let stop = Arc::new(AtomicBool::new(false));
        let host = Arc::new(Mutex::new(host));

        let instance = spec.instance.clone();
        // REQ-PTY-3: a thread that cannot be created fails this spawn (child
        // killed, threads already started told to stop) instead of panicking.
        let abort = |what: &str, e: std::io::Error| {
            stop.store(true, Ordering::SeqCst);
            host.lock().unwrap().kill();
            anyhow!("spawn agent {instance}: start {what} thread: {e}")
        };

        // Pump thread: fan raw output out to subscribers of this instance and
        // stamp last-activity. Ends when the PTY closes (child exit) — the
        // reader thread drops the sender so `recv` returns Err.
        let pump = {
            let subs = Arc::clone(&self.subs);
            let last_activity = Arc::clone(&last_activity);
            let instance = instance.clone();
            let tee_path = spec.tee_path.clone();
            std::thread::Builder::new()
                .spawn(move || {
                    pump_output(output_rx, subs, instance, last_activity, tee_path);
                })
                .map_err(|e| abort("pump", e))?
        };

        // Exit watcher: when the child dies, broadcast ChildExited to every event
        // WATCHER (connections that sent WatchEvents), not all sinks: ChildExited
        // is a bridge-level lifecycle signal the event subscriber must always get
        // even though it never Attaches, but one-shot control connections must NOT
        // see it interleaved with their reply (HOST-5). Watchers get it without any
        // per-instance Output flood.
        let exited_at = Arc::new(AtomicU64::new(0));
        let exit_watch = {
            let agents = Arc::clone(&self.agents);
            let watchers = Arc::clone(&self.watchers);
            let subs = Arc::clone(&self.subs);
            let exited_at = Arc::clone(&exited_at);
            let alive = Arc::clone(&alive);
            let stop = Arc::clone(&stop);
            let host = Arc::clone(&host);
            let instance = instance.clone();
            let timeout = spec.timeout_seconds.map(Duration::from_secs);
            std::thread::Builder::new().spawn(move || {
                let started = Instant::now();
                let mut timeout_fired = false;
                while alive.load(Ordering::SeqCst) {
                    if stop.load(Ordering::SeqCst) {
                        return;
                    }
                    if !timeout_fired && timeout.is_some_and(|limit| started.elapsed() >= limit) {
                        timeout_fired = true;
                        host.lock().unwrap().terminate();
                        let dead = host.lock().unwrap().wait_timeout(TERM_GRACE).is_some();
                        if !dead {
                            host.lock().unwrap().kill();
                        }
                    }
                    std::thread::sleep(Duration::from_millis(30));
                }
                // Suppress the event if we're tearing this agent down (close/
                // restart already accounts for the lifecycle).
                if stop.load(Ordering::SeqCst) {
                    return;
                }
                // REQ-PTY-1: the child is gone, so close this session's PTY
                // master fds now (once the reader has drained its last output)
                // instead of holding them until a `close` that may never come.
                // The host lock is not held across the drain wait.
                let drain_deadline = Instant::now() + PTY_DRAIN_GRACE;
                while !host.lock().unwrap().reader_done() && Instant::now() < drain_deadline {
                    std::thread::sleep(Duration::from_millis(5));
                }
                host.lock().unwrap().release_pty();
                exited_at.store(now_millis(), Ordering::SeqCst);
                prune_tombstones(&mut agents.lock().unwrap(), TOMBSTONE_MAX, TOMBSTONE_TTL);

                let code = host.lock().unwrap().exit_code().unwrap_or(-1);
                broadcast_all_sinks(
                    &watchers,
                    &CtlReply::ChildExited {
                        instance: instance.clone(),
                        code,
                    },
                );
                // REQ-STREAM-EVENT-2: Emit StreamClosed to attached stream subscribers
                broadcast_instance_subs(
                    &subs,
                    &instance,
                    &CtlReply::StreamClosed {
                        instance: instance.clone(),
                        code: Some(code),
                    },
                );
            })
            .map_err(|e| abort("exit watcher", e))?
        };

        // HOST-2: per-agent startup detector + activity (ScreenChanged) signal.
        // Only spun up when the spec carried a detect config. It ticks every
        // capture_interval_ms, captures the VT text, dispatches auto-enter keys
        // to the child, and broadcasts StartupReady/StartupBlocked + a
        // ScreenChanged dirty signal on content change. It stops on
        // stop/child-exit and is re-plumbed on restart (build_agent runs again).
        let detector = {
            let cfg = StartupDetectionConfig::from_json(spec.detect.as_deref().unwrap_or(""));
            // Always run the loop (even when disabled/absent) so we still emit
            // the ScreenChanged activity signal; the Detector short-circuits
            // startup to Ready immediately when disabled.
            let watchers = Arc::clone(&self.watchers);
            let alive = Arc::clone(&alive);
            let stop = Arc::clone(&stop);
            let host = Arc::clone(&host);
            let instance = instance.clone();
            Some(
                std::thread::Builder::new()
                    .spawn(move || {
                        run_detector(cfg, host, watchers, instance, alive, stop);
                    })
                    .map_err(|e| abort("detector", e))?,
            )
        };

        Ok(Agent {
            spec,
            host,
            alive,
            pid,
            started_at: now_secs(),
            last_activity,
            exited_at,
            stop,
            pump: Some(pump),
            exit_watch: Some(exit_watch),
            detector,
            startup_input: StartupInputState::default(),
        })
    }

    /// SIGTERM -> wait -> SIGKILL the instance, then unregister it.
    pub fn close(&self, instance: &str) -> Result<()> {
        broadcast_instance_subs(
            &self.subs,
            instance,
            &CtlReply::StreamClosed {
                instance: instance.to_string(),
                code: None,
            },
        );
        let mut agent = self
            .agents
            .lock()
            .unwrap()
            .remove(instance)
            .ok_or_else(|| anyhow!("close: no such instance {instance}"))?;
        agent.shutdown();
        Ok(())
    }

    /// Re-spawn `instance` from its remembered spec under the same id. The child
    /// is torn down first; background threads are re-plumbed automatically.
    /// Returns the new child pid.
    pub fn restart(&self, instance: &str) -> Result<i32> {
        // Take the existing agent out, remember its spec, tear it down.
        let mut old = self
            .agents
            .lock()
            .unwrap()
            .remove(instance)
            .ok_or_else(|| anyhow!("restart: no such instance {instance}"))?;
        let spec = old.spec.clone();
        broadcast_instance_subs(
            &self.subs,
            instance,
            &CtlReply::StreamClosed {
                instance: instance.to_string(),
                code: None,
            },
        );
        old.shutdown();

        // Re-spawn the same spec + re-register under the same id.
        let agent = self.build_agent(spec)?;
        let pid = agent.pid;
        self.agents
            .lock()
            .unwrap()
            .insert(instance.to_string(), agent);
        Ok(pid)
    }

    /// Enumerate all registered agents (order unspecified).
    pub fn list(&self) -> Vec<AgentInfo> {
        self.agents
            .lock()
            .unwrap()
            .values()
            .map(|a| a.info())
            .collect()
    }

    /// Whether `shell_id` exists in the daemon.
    pub fn has_shell(&self, shell_id: &str) -> bool {
        self.agents.lock().unwrap().contains_key(shell_id)
    }

    /// Look up a shell by its shell_id (for agents, shell_id == agent_instance_id).
    pub fn shell(&self, shell_id: &str) -> Option<Shell> {
        self.agents.lock().unwrap().get(shell_id).map(|a| a.shell())
    }

    /// Enumerate all registered shells.
    pub fn list_shells(&self) -> Vec<ShellInfo> {
        self.agents
            .lock()
            .unwrap()
            .values()
            .map(|a| a.shell_info())
            .collect()
    }

    /// Whether `instance` (or `shell_id`) exists and its child is alive.
    pub fn is_alive(&self, instance: &str) -> bool {
        self.agents
            .lock()
            .unwrap()
            .get(instance)
            .map(|a| a.alive.load(Ordering::SeqCst))
            .unwrap_or(false)
    }

    /// Send POSIX signal `signum` to the process group of `shell_id` via `killpg`
    /// (Windows: mapped onto the session's ConPTY/job, see [`PtyHost::signal`]).
    ///
    /// Returns [`SignalOutcome::AlreadyExited`] when the child has already
    /// exited (REQ-PTY-1); a reaped pid is never signalled, since its process
    /// group id may since have been reused. `Err` if the instance is unknown or
    /// `killpg` fails on a live child.
    pub fn signal(&self, shell_id: &str, signum: u8) -> Result<SignalOutcome> {
        let (pid, alive, host) = {
            let agents = self.agents.lock().unwrap();
            let a = agents
                .get(shell_id)
                .ok_or_else(|| anyhow!("signal: no such instance {shell_id}"))?;
            (a.pid, Arc::clone(&a.alive), Arc::clone(&a.host))
        };
        let exited = || SignalOutcome::AlreadyExited(self.exit_code(shell_id).unwrap_or(-1));
        if !alive.load(Ordering::SeqCst) {
            return Ok(exited());
        }
        #[cfg(unix)]
        {
            let _ = host;
            let ret = unsafe { libc::killpg(pid as libc::pid_t, signum as libc::c_int) };
            if ret == 0 {
                return Ok(SignalOutcome::Delivered);
            }
            let err = std::io::Error::last_os_error();
            // ESRCH while still flagged alive: the child exited but its wait
            // thread has not recorded it yet. Give it a moment to catch up.
            if err.raw_os_error() == Some(libc::ESRCH)
                && wait_until(|| !alive.load(Ordering::SeqCst), Duration::from_millis(500))
            {
                return Ok(exited());
            }
            Err(anyhow!("killpg({pid}, {signum}) failed: {err}"))
        }
        #[cfg(windows)]
        {
            let _ = pid;
            let res = host.lock().unwrap().signal(signum);
            match res {
                Ok(()) => Ok(SignalOutcome::Delivered),
                // The child exited before the signal landed (see ESRCH above).
                Err(_) if wait_until(|| !alive.load(Ordering::SeqCst), Duration::from_millis(500)) => {
                    Ok(exited())
                }
                Err(e) => Err(e),
            }
        }
    }

    /// Exit code of `instance` (or `shell_id`) if it exists and has exited.
    pub fn exit_code(&self, instance: &str) -> Option<i32> {
        let agents = self.agents.lock().unwrap();
        let a = agents.get(instance)?;
        if a.alive.load(Ordering::SeqCst) {
            None
        } else {
            a.host.lock().unwrap().exit_code()
        }
    }

    /// Write raw bytes to an instance/shell stdin.
    pub fn write_input(&self, shell_id: &str, bytes: &[u8]) -> Result<()> {
        let agents = self.agents.lock().unwrap();
        let a = agents
            .get(shell_id)
            .ok_or_else(|| anyhow!("input: no such instance {shell_id}"))?;
        let res = a.host.lock().unwrap().write_input(bytes);
        res
    }

    /// One launch-fenced startup instruction. The receipt and partial byte
    /// progress live with the child, so lost replies/concurrent retries are safe.
    /// Close/restart drops the receipt; both pid and launch key fence old work.
    pub fn write_startup_input(&self, instance: &str, pid: i32, launch_key: &str, bytes: &[u8]) -> Result<()> {
        if launch_key.is_empty() || bytes.is_empty() || bytes.len() > 4096 {
            return Err(anyhow!("startup input: invalid key or instruction size"));
        }
        let mut agents = self.agents.lock().unwrap();
        let a = agents.get_mut(instance).ok_or_else(|| anyhow!("startup input: no such instance"))?;
        let expected_key = a.spec.env.iter().rev().find(|(k, _)| k == "HEIMDALL_STARTUP_KEY").map(|(_, v)| v.as_str());
        if a.pid != pid || expected_key != Some(launch_key) || a.stop.load(Ordering::SeqCst) || !a.alive.load(Ordering::SeqCst) {
            return Err(anyhow!("startup input: stale or inactive launch"));
        }
        let state = &mut a.startup_input;
        if let Some(original) = &state.bytes {
            if original != bytes {
                return Err(anyhow!("startup input: instruction differs from first attempt"));
            }
        } else {
            state.bytes = Some(bytes.to_vec());
        }
        if state.delivered {
            return Ok(());
        }
        a.host.lock().unwrap().write_startup_input(bytes, &mut state.written)?;
        state.delivered = true;
        Ok(())
    }

    /// Resize an instance/shell's PTY + VT model.
    pub fn resize(&self, shell_id: &str, rows: u16, cols: u16) -> Result<()> {
        let agents = self.agents.lock().unwrap();
        let a = agents
            .get(shell_id)
            .ok_or_else(|| anyhow!("resize: no such instance {shell_id}"))?;
        let res = a.host.lock().unwrap().resize(rows, cols);
        res
    }

    /// Snapshot an instance/shell's current screen.
    pub fn capture(&self, shell_id: &str) -> Option<ScreenSnapshot> {
        let agents = self.agents.lock().unwrap();
        let a = agents.get(shell_id)?;
        let cap = a.host.lock().unwrap().capture();
        Some(ScreenSnapshot {
            rows: cap.rows as u16,
            cols: cap.cols as u16,
            cursor_row: cap.cursor_row as u16,
            cursor_col: cap.cursor_col as u16,
            lines: cap.lines,
        })
    }

    /// Deliver input to a shell by shell_id.
    pub fn shell_input(&self, shell_id: &str, bytes: &[u8]) -> Result<()> {
        self.write_input(shell_id, bytes)
    }

    /// Resize a shell by shell_id.
    pub fn shell_resize(&self, shell_id: &str, rows: u16, cols: u16) -> Result<()> {
        self.resize(shell_id, rows, cols)
    }

    /// Capture a shell's screen by shell_id.
    pub fn shell_capture(&self, shell_id: &str) -> Option<ScreenSnapshot> {
        self.capture(shell_id)
    }

    /// Attach to a shell by shell_id.
    pub fn shell_attach(&self, id: u64, shell_id: &str) -> Result<ScreenSnapshot> {
        self.attach(id, shell_id)
    }

    /// Detach from a shell by shell_id.
    pub fn shell_detach(&self, id: u64, shell_id: &str) {
        self.detach(id, shell_id)
    }

    // ---- subscription plumbing (used by the socket server) --------------
    //
    // HOST-5: a connection is NOT auto-subscribed. Control-only clients
    // (spawn/close/restart/list) never enter the `subs` map, so async events
    // (Output/ScreenChanged/StartupReady/StartupBlocked/ChildExited) — which
    // are delivered ONLY through `subs` — can never be interleaved with a
    // control reply. A subscription is created lazily on the first `Attach` and
    // torn down when the client detaches from its last instance (or drops).

    /// Remember a client's event sink so it can be (re)subscribed on Attach.
    /// Idempotent; does NOT by itself cause any events to be delivered.
    fn register_sink(&self, id: u64, tx: ReplySink) {
        self.sinks.lock().unwrap().insert(id, tx);
    }

    /// Subscribe connection `id` to host-level events (WatchEvents). Puts its sink
    /// into `watchers` so it receives HostHeartbeat + lifecycle frames for all
    /// agents without attaching to any instance's Output.
    fn watch_events(&self, id: u64) {
        let tx = match self.sinks.lock().unwrap().get(&id).cloned() {
            Some(tx) => tx,
            None => return,
        };
        self.watchers.lock().unwrap().insert(id, tx);
    }

    /// Drop a client entirely: its sink, any active subscription, and its event
    /// watch. For any instances it was attached to that now have 0 remaining
    /// attached subscribers, automatically resizes them to CRT resolution (80x25).
    pub fn unsubscribe(&self, id: u64) {
        let unattached_instances: Vec<String> = {
            let mut subs = self.subs.lock().unwrap();
            if let Some(sub) = subs.remove(&id) {
                sub.instances
                    .into_iter()
                    .filter(|inst| !subs.values().any(|s| s.instances.contains(inst)))
                    .collect()
            } else {
                Vec::new()
            }
        };
        self.sinks.lock().unwrap().remove(&id);
        self.watchers.lock().unwrap().remove(&id);

        for instance in unattached_instances {
            let _ = self.resize(&instance, CRT_ROWS, CRT_COLS);
        }
    }

    /// Attach client `id` to a shell's output stream. Creates the client's
    /// subscription on first attach. Returns the current screen so the client
    /// renders live state immediately. Does not affect the child. Errors if the
    /// shell/instance does not exist.
    pub fn attach(&self, id: u64, shell_id: &str) -> Result<ScreenSnapshot> {
        let snap = self
            .capture(shell_id)
            .ok_or_else(|| anyhow!("attach: no such instance {shell_id}"))?;
        // Look up the sink before locking subs to avoid a lock-ordering hazard.
        let tx = self
            .sinks
            .lock()
            .unwrap()
            .get(&id)
            .cloned()
            .ok_or_else(|| anyhow!("attach: connection {id} has no registered sink"))?;
        // Ensure initial CtlReply::Screen catchup snapshot is queued on the client sink
        // BEFORE the instance is added to subs, guaranteeing FIFO delivery before any Output chunk.
        let _ = tx.send(CtlReply::Screen {
            instance: shell_id.to_string(),
            screen: snap.clone(),
        });
        // REQ-STREAM-EVENT-2: Emit StreamReady immediately following attach screen snapshot.
        let _ = tx.send(CtlReply::StreamReady {
            instance: shell_id.to_string(),
        });
        let mut subs = self.subs.lock().unwrap();
        let sub = subs.entry(id).or_insert_with(|| Subscriber {
            tx,
            instances: HashSet::new(),
        });
        sub.instances.insert(shell_id.to_string());
        Ok(snap)
    }

    /// Detach client `id` from a shell. When it has no shells/instances left the
    /// whole subscription is removed so it stops receiving ALL events (returns
    /// to control-only status). If no remaining subscribers are attached to
    /// `shell_id`, automatically resizes it to CRT resolution (80x25).
    pub fn detach(&self, id: u64, shell_id: &str) {
        let should_resize = {
            let mut subs = self.subs.lock().unwrap();
            let mut removed = false;
            if let Some(sub) = subs.get_mut(&id) {
                removed = sub.instances.remove(shell_id);
                if sub.instances.is_empty() {
                    subs.remove(&id);
                }
            }
            removed && !subs.values().any(|sub| sub.instances.contains(shell_id))
        };
        if should_resize {
            let _ = self.resize(shell_id, CRT_ROWS, CRT_COLS);
        }
    }

    /// Broadcast one host-level liveness digest to every connected client: the
    /// full agent roster with each child's current alive flag. This is the
    /// periodic backstop that lets the bridge refresh per-instance last_seen from
    /// a single pushed frame instead of polling `List`; `ChildExited` remains the
    /// instant authoritative death signal.
    pub fn broadcast_heartbeat(&self) {
        let agents: Vec<HostHeartbeatAgent> = self
            .agents
            .lock()
            .unwrap()
            .iter()
            .map(|(id, a)| HostHeartbeatAgent {
                instance_id: id.clone(),
                alive: a.alive.load(Ordering::SeqCst),
            })
            .collect();
        let reply = CtlReply::HostHeartbeat {
            ts_unix_ms: now_millis(),
            agents,
        };
        // Deliver to event WATCHERS (connections that sent WatchEvents), not all
        // sinks: the heartbeat is a host-level liveness digest the bridge's event
        // subscriber must always get without attaching, but one-shot control
        // connections must keep clean request/reply streams (HOST-5). The bridge's
        // long-lived event connection sends WatchEvents once and thus receives it.
        broadcast_all_sinks(&self.watchers, &reply);
    }

    /// Stop all agents + drop all subscribers. Idempotent.
    pub fn shutdown(&self) {
        let ids: Vec<String> = self.agents.lock().unwrap().keys().cloned().collect();
        for id in ids {
            let _ = self.close(&id);
        }
        self.subs.lock().unwrap().clear();
        self.sinks.lock().unwrap().clear();
    }
}

/// Pump one agent's raw PTY output to its subscribers + stamp activity.
/// When `tee_path` is `Some`, also writes every chunk to that file, rotating
/// at [`TEE_MAX_BYTES`].
fn pump_output(
    output_rx: Receiver<Vec<u8>>,
    subs: Subscribers,
    instance: String,
    last_activity: Arc<AtomicU64>,
    tee_path: Option<String>,
) {
    let mut tee: Option<TeeWriter> = tee_path.as_deref().and_then(TeeWriter::open);
    while let Ok(chunk) = output_rx.recv() {
        last_activity.store(now_secs(), Ordering::SeqCst);
        let mut dead_subscribers = Vec::new();
        let map = subs.lock().unwrap();
        for (&id, sub) in map.iter() {
            if sub.instances.contains(&instance) {
                if sub.tx.send(CtlReply::Output {
                    instance: instance.clone(),
                    data: chunk.clone(),
                }).is_err() {
                    dead_subscribers.push(id);
                }
            }
        }
        drop(map);
        if !dead_subscribers.is_empty() {
            let mut map = subs.lock().unwrap();
            for id in dead_subscribers {
                map.remove(&id);
            }
        }
        if let Some(ref mut t) = tee {
            t.write_chunk(&chunk);
        }
    }
}

/// Broadcast to EVERY connected client (all registered sinks), regardless of
/// whether they have Attached to an instance. Used for host-level frames like
/// HostHeartbeat that are not scoped to a particular agent, so a control/event
/// client that never Attached still receives them.
fn broadcast_all_sinks(sinks: &Sinks, reply: &CtlReply) {
    let map = sinks.lock().unwrap();
    for tx in map.values() {
        let _ = tx.send(reply.clone());
    }
}

/// REQ-STREAM-EVENT-2: Broadcast to every subscriber attached to `instance`.
fn broadcast_instance_subs(subs: &Subscribers, instance: &str, reply: &CtlReply) {
    let map = subs.lock().unwrap();
    for sub in map.values() {
        if sub.instances.contains(instance) {
            let _ = sub.tx.send(reply.clone());
        }
    }
}

/// HOST-2: per-agent startup-detection + activity loop. Runs on its own thread
/// for the life of one child. Ticks every `capture_interval_ms`:
///   1. captures the rendered screen text,
///   2. emits `ScreenChanged{hash}` when the content hash changes (activity
///      signal; spinner masking is bridge-side),
///   3. feeds the text to the [`Detector`]; performs `SendKeys` against the
///      child and broadcasts `StartupReady`/`StartupBlocked` on `Finished`.
/// After the detector finishes it keeps emitting the activity signal until the
/// child exits or the agent is stopped.
fn run_detector(
    cfg: StartupDetectionConfig,
    host: Arc<Mutex<PtyHost>>,
    watchers: Watchers,
    instance: String,
    alive: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
) {
    let interval = Duration::from_millis(cfg.interval_ms().max(1) as u64);
    // Only surface startup events when detection is actually enabled. When it is
    // absent/disabled we still run the loop for the ScreenChanged activity
    // signal (the bridge wants activity for every agent) but stay silent on
    // startup so a no-detect agent doesn't emit a spurious StartupReady.
    let emit_startup = cfg.enabled;
    let start = Instant::now();
    let mut detector = Detector::new(cfg, 0);
    let mut last_hash: Option<u64> = None;

    loop {
        if stop.load(Ordering::SeqCst) || !alive.load(Ordering::SeqCst) {
            return;
        }

        // Render the current screen to a single text blob for matching/hashing.
        let text = {
            let cap = host.lock().unwrap().capture();
            cap.lines.join("\n")
        };

        // Activity (ScreenChanged) dirty signal on content change.
        let h = screen_hash(&text);
        if last_hash != Some(h) {
            last_hash = Some(h);
            broadcast_all_sinks(
                &watchers,
                &CtlReply::ScreenChanged {
                    instance: instance.clone(),
                    hash: h,
                },
            );
        }

        // Drive the startup detector (no-op once finished).
        if !detector.is_done() {
            let now_ms = start.elapsed().as_millis() as i64;
            for action in detector.step(&text, now_ms) {
                match action {
                    DetectAction::SendKeys(keys) => {
                        let h = host.lock().unwrap();
                        for k in keys {
                            let _ = h.write_input(k.to_bytes());
                        }
                    }
                    DetectAction::Finished(outcome) => {
                        if emit_startup {
                            let reply = match outcome {
                                StartupOutcome::Ready => CtlReply::StartupReady {
                                    instance: instance.clone(),
                                },
                                StartupOutcome::Blocked {
                                    reason_code,
                                    safe_diagnostic,
                                } => CtlReply::StartupBlocked {
                                    instance: instance.clone(),
                                    reason_code,
                                    safe_diagnostic,
                                },
                            };
                            broadcast_all_sinks(&watchers, &reply);
                        }
                    }
                }
            }
        }

        std::thread::sleep(interval);
    }
}

// ---- socket server ------------------------------------------------------

/// A running daemon bound to a unix socket, speaking [`crate::dproto`].
pub struct DaemonServer {
    socket_path: std::path::PathBuf,
    /// REQ-PTY-2: exclusive flock on `<socket>.lock`, held for the server's
    /// lifetime so no second daemon can take over this socket.
    _lock: std::fs::File,
    daemon: Daemon,
    shutdown: Arc<AtomicBool>,
    accept: Option<JoinHandle<()>>,
    heartbeat: Option<JoinHandle<()>>,
}

impl DaemonServer {
    /// Bind `socket_path` and start accepting control/data clients. The daemon
    /// starts with no agents; clients drive it via `Spawn`.
    ///
    /// REQ-PTY-2: fails, leaving the socket alone, if another daemon owns it
    /// (see [`claim_socket`]).
    pub fn start(socket_path: impl Into<std::path::PathBuf>) -> Result<Self> {
        let socket_path = socket_path.into();
        crate::socket_path::prepare(&socket_path)?;
        let lock = claim_socket(&socket_path)?;
        let listener = UnixListener::bind(&socket_path)
            .with_context(|| format!("bind {socket_path:?}"))?;
        let daemon = Daemon::new();
        let shutdown = Arc::new(AtomicBool::new(false));

        let accept = {
            let daemon = daemon.clone();
            let shutdown = Arc::clone(&shutdown);
            std::thread::spawn(move || accept_loop(listener, daemon, shutdown))
        };

        // Host-level liveness digest ticker: broadcasts the agent roster + alive
        // flags every HOST_HEARTBEAT_INTERVAL so the bridge refreshes last_seen
        // without polling. Wakes frequently to observe the shutdown flag promptly.
        let heartbeat = {
            let daemon = daemon.clone();
            let shutdown = Arc::clone(&shutdown);
            std::thread::spawn(move || heartbeat_loop(daemon, shutdown))
        };

        Ok(DaemonServer {
            socket_path,
            _lock: lock,
            daemon,
            shutdown,
            accept: Some(accept),
            heartbeat: Some(heartbeat),
        })
    }

    pub fn socket_path(&self) -> &std::path::Path {
        &self.socket_path
    }

    /// Handle to the underlying daemon (for tests / diagnostics).
    pub fn daemon(&self) -> &Daemon {
        &self.daemon
    }

    /// Signal shutdown: stop all agents, unblock the accept loop, join it.
    pub fn shutdown(&mut self) {
        self.shutdown.store(true, Ordering::SeqCst);
        self.daemon.shutdown();
        let _ = UnixStream::connect(&self.socket_path);
        if let Some(t) = self.accept.take() {
            let _ = t.join();
        }
        if let Some(t) = self.heartbeat.take() {
            let _ = t.join();
        }
        let _ = std::fs::remove_file(&self.socket_path);
    }
}

/// Periodic host-liveness broadcaster. Sleeps in short slices so a shutdown is
/// observed within ~250ms rather than up to a full interval.
fn heartbeat_loop(daemon: Daemon, shutdown: Arc<AtomicBool>) {
    let mut elapsed = Duration::ZERO;
    let slice = Duration::from_millis(250);
    while !shutdown.load(Ordering::SeqCst) {
        std::thread::sleep(slice);
        elapsed += slice;
        if elapsed >= HOST_HEARTBEAT_INTERVAL {
            elapsed = Duration::ZERO;
            if shutdown.load(Ordering::SeqCst) {
                break;
            }
            daemon.broadcast_heartbeat();
        }
    }
}

impl Drop for DaemonServer {
    fn drop(&mut self) {
        if !self.shutdown.load(Ordering::SeqCst) {
            self.shutdown.store(true, Ordering::SeqCst);
            self.daemon.shutdown();
            let _ = std::fs::remove_file(&self.socket_path);
        }
    }
}

static NEXT_CLIENT_ID: AtomicU64 = AtomicU64::new(1);

/// REQ-PTY-2: take ownership of `socket_path` for this process.
///
/// Takes an exclusive, non-blocking flock on `<socket>.lock` (returned; the
/// lock lasts as long as the file stays open). If another process holds it, or
/// something accepts connections on the socket (a daemon that predates the
/// lock), this fails without touching the socket. Only a stale socket file
/// (no lock holder, connect refused) is removed so the caller can bind.
fn claim_socket(socket_path: &std::path::Path) -> Result<std::fs::File> {
    let mut lock_path = socket_path.as_os_str().to_owned();
    lock_path.push(".lock");
    let lock = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(&lock_path)
        .with_context(|| format!("open daemon lock {lock_path:?}"))?;
    #[cfg(unix)]
    {
        use std::os::unix::io::AsRawFd;
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            let err = std::io::Error::last_os_error();
            if err.raw_os_error() == Some(libc::EWOULDBLOCK) {
                return Err(anyhow!(
                    "another ham-pty-host daemon owns {socket_path:?} (lock {lock_path:?} is held)"
                ));
            }
            return Err(anyhow!("flock {lock_path:?}: {err}"));
        }
    }
    // Windows: an exclusive LockFileEx on the same file.
    #[cfg(windows)]
    match lock.try_lock() {
        Ok(()) => {}
        Err(std::fs::TryLockError::WouldBlock) => {
            return Err(anyhow!(
                "another ham-pty-host daemon owns {socket_path:?} (lock {lock_path:?} is held)"
            ));
        }
        Err(std::fs::TryLockError::Error(err)) => {
            return Err(anyhow!("lock {lock_path:?}: {err}"));
        }
    }
    if UnixStream::connect(socket_path).is_ok() {
        return Err(anyhow!(
            "another process is accepting connections on {socket_path:?}; refusing to replace it"
        ));
    }
    match std::fs::remove_file(socket_path) {
        Ok(()) => eprintln!("[ham-pty-host] removed stale socket {}", socket_path.display()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(anyhow!("remove stale socket {socket_path:?}: {e}")),
    }
    Ok(lock)
}

/// REQ-PTY-3: raise this process's RLIMIT_NOFILE soft limit to its hard limit,
/// capped at [`NOFILE_TARGET`]; never lowers it. Returns the resulting soft limit.
/// Unix only: Windows has no per-process handle limit to raise.
#[cfg(unix)]
pub fn raise_nofile_limit() -> std::io::Result<libc::rlim_t> {
    let mut lim = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
    if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut lim) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    let target = lim.rlim_max.min(NOFILE_TARGET);
    if target > lim.rlim_cur {
        lim.rlim_cur = target;
        if unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &lim) } != 0 {
            return Err(std::io::Error::last_os_error());
        }
    }
    Ok(lim.rlim_cur)
}

/// True for the accept/clone errors that mean "out of fds or kernel memory":
/// the daemon backs off and keeps going rather than spinning.
fn is_resource_exhaustion(e: &std::io::Error) -> bool {
    #[cfg(unix)]
    return matches!(
        e.raw_os_error(),
        Some(libc::EMFILE | libc::ENFILE | libc::ENOBUFS | libc::ENOMEM)
    );
    // WSAEMFILE, WSAENOBUFS, ERROR_NOT_ENOUGH_MEMORY, ERROR_OUTOFMEMORY.
    #[cfg(windows)]
    return matches!(e.raw_os_error(), Some(10024 | 10055 | 8 | 14));
}

fn accept_loop(listener: UnixListener, daemon: Daemon, shutdown: Arc<AtomicBool>) {
    for stream in listener.incoming() {
        if shutdown.load(Ordering::SeqCst) {
            break;
        }
        let stream = match stream {
            Ok(s) => s,
            Err(e) => {
                // REQ-PTY-3: a failed accept never ends the loop. On fd
                // exhaustion, back off so the fds held by finishing clients
                // and sessions can be released.
                eprintln!("[ham-pty-host] accept failed: {e}");
                if is_resource_exhaustion(&e) {
                    std::thread::sleep(ACCEPT_EMFILE_BACKOFF);
                }
                continue;
            }
        };
        let id = NEXT_CLIENT_ID.fetch_add(1, Ordering::SeqCst);
        handle_client(id, stream, daemon.clone(), Arc::clone(&shutdown));
    }
}

/// Serve one client on its own reader + writer threads. REQ-PTY-3: never
/// panics; if the per-client fds or threads cannot be created, the client is
/// dropped (logged) and the accept loop carries on.
fn handle_client(id: u64, stream: UnixStream, daemon: Daemon, shutdown: Arc<AtomicBool>) {
    let drop_client = |what: &str, e: std::io::Error| {
        eprintln!("[ham-pty-host] dropping client {id}: {what}: {e}");
        if is_resource_exhaustion(&e) {
            std::thread::sleep(ACCEPT_EMFILE_BACKOFF);
        }
    };
    let shutdown_handle = match stream.try_clone() {
        Ok(s) => s,
        Err(e) => return drop_client("clone client shutdown handle", e),
    };
    let mut write_stream = match stream.try_clone() {
        Ok(s) => s,
        Err(e) => return drop_client("clone client write stream", e),
    };
    let (tx, rx) = reply_channel(Some(shutdown_handle));
    // HOST-5: register the sink but do NOT subscribe to events. Async events
    // only flow to clients that later Attach; a control-only client stays out
    // of the `subs` map entirely and thus never sees an event frame.
    daemon.register_sink(id, tx.clone());
    let mut read_stream = stream;

    let daemon_writer = daemon.clone();
    // Writer thread: drain this client's reply queue to the socket.
    let writer = std::thread::Builder::new().spawn(move || {
        let _ = write_stream.set_write_timeout(Some(Duration::from_secs(5)));
        while let Ok(frame) = rx.recv() {
            if std::io::Write::write_all(&mut write_stream, &frame.bytes).is_err() {
                let _ = write_stream.shutdown(std::net::Shutdown::Both);
                daemon_writer.unsubscribe(id);
                break;
            }
        }
    });
    if let Err(e) = writer {
        daemon.unsubscribe(id);
        return drop_client("spawn writer thread", e);
    }

    // Reader thread: decode control/data messages + act on them.
    let daemon_reader = daemon.clone();
    let reader = std::thread::Builder::new().spawn(move || {
        loop {
            match dproto::read_ctl_msg(&mut read_stream) {
                Ok(Some(msg)) => handle_ctl(&daemon_reader, id, msg, &tx),
                Ok(None) | Err(_) => break,
            }
            if shutdown.load(Ordering::SeqCst) {
                break;
            }
        }
        daemon_reader.unsubscribe(id);
    });
    if let Err(e) = reader {
        // Dropping the sink ends the writer thread; the moved stream closes.
        daemon.unsubscribe(id);
        drop_client("spawn reader thread", e);
    }
}

fn handle_ctl(daemon: &Daemon, id: u64, msg: CtlMsg, tx: &ReplySink) {
    match msg {
        CtlMsg::Spawn(req) => {
            let instance = req.instance.clone();
            match daemon.spawn(req) {
                Ok(pid) => {
                    let _ = tx.send(CtlReply::Spawned { instance, pid });
                }
                Err(e) => {
                    let _ = tx.send(CtlReply::Error {
                        instance,
                        message: format!("{e:#}"),
                    });
                }
            }
        }
        CtlMsg::Close { instance } => match daemon.close(&instance) {
            Ok(()) => {
                let _ = tx.send(CtlReply::Closed { instance });
            }
            Err(e) => {
                let _ = tx.send(CtlReply::Error {
                    instance,
                    message: format!("{e:#}"),
                });
            }
        },
        CtlMsg::Restart { instance } => match daemon.restart(&instance) {
            Ok(pid) => {
                let _ = tx.send(CtlReply::Restarted { instance, pid });
            }
            Err(e) => {
                let _ = tx.send(CtlReply::Error {
                    instance,
                    message: format!("{e:#}"),
                });
            }
        },
        CtlMsg::List => {
            let _ = tx.send(CtlReply::AgentList(daemon.list()));
        }
        CtlMsg::Attach { instance } => {
            if let Err(e) = daemon.attach(id, &instance) {
                let _ = tx.send(CtlReply::Error {
                    instance,
                    message: format!("{e:#}"),
                });
            }
        }
        CtlMsg::Input { instance, data } => {
            if let Err(e) = daemon.write_input(&instance, &data) {
                let _ = tx.send(CtlReply::Error {
                    instance,
                    message: format!("{e:#}"),
                });
            }
        }
        CtlMsg::StartupInput { instance, pid, launch_key, data } => {
            let reply = match daemon.write_startup_input(&instance, pid, &launch_key, &data) {
                Ok(()) => CtlReply::StartupInputDone { instance, pid, launch_key },
                Err(e) => CtlReply::Error { instance, message: format!("{e:#}") },
            };
            let _ = tx.send(reply);
        }
        CtlMsg::Key { instance, key } => {
            if let Err(e) = daemon.write_input(&instance, key.to_bytes()) {
                let _ = tx.send(CtlReply::Error {
                    instance,
                    message: format!("{e:#}"),
                });
            }
        }
        CtlMsg::Resize { instance, rows, cols } => {
            if let Err(e) = daemon.resize(&instance, rows, cols) {
                let _ = tx.send(CtlReply::Error {
                    instance,
                    message: format!("{e:#}"),
                });
            }
        }
        CtlMsg::Capture { instance } => match daemon.capture(&instance) {
            Some(screen) => {
                let _ = tx.send(CtlReply::Screen { instance, screen });
            }
            None => {
                let _ = tx.send(CtlReply::Error {
                    instance,
                    message: "capture: no such instance".into(),
                });
            }
        },
        CtlMsg::Detach { instance } => daemon.detach(id, &instance),
        CtlMsg::WatchEvents => daemon.watch_events(id),
        CtlMsg::Ping => {
            let _ = tx.send(CtlReply::Pong);
        }
        CtlMsg::Shutdown => {
            // Ack first so the client learns the daemon accepted the request,
            // then flip the stop flag. The `serve` loop observes it and tears
            // down every agent via `server.shutdown()`; the accept loop and
            // this client's socket close right after.
            let _ = tx.send(CtlReply::ShuttingDown);
            STOP_REQUESTED.store(true, Ordering::SeqCst);
        }
        CtlMsg::Signal(SignalRequest { shell_id, signal }) => {
            match daemon.signal(&shell_id, signal) {
                Ok(SignalOutcome::Delivered) => {
                    let _ = tx.send(CtlReply::Closed { instance: shell_id });
                }
                Ok(SignalOutcome::AlreadyExited(code)) => {
                    let _ = tx.send(CtlReply::AlreadyExited { instance: shell_id, code });
                }
                Err(e) => {
                    let _ = tx.send(CtlReply::Error {
                        instance: shell_id,
                        message: format!("{e:#}"),
                    });
                }
            }
        }
    }
}

/// Bind + run a daemon on `socket_path` until the child of the process is
/// signalled. Convenience entrypoint used by `main`. Blocks forever (until
/// Ctrl-C), serving clients.
pub fn serve(socket_path: impl Into<std::path::PathBuf>) -> Result<()> {
    #[cfg(unix)]
    match raise_nofile_limit() {
        Ok(n) => eprintln!("[ham-pty-host] RLIMIT_NOFILE soft limit {n}"),
        Err(e) => eprintln!("[ham-pty-host] could not raise RLIMIT_NOFILE: {e}"),
    }
    let mut server = DaemonServer::start(socket_path)?;
    eprintln!(
        "[ham-pty-host] daemon listening on {}",
        server.socket_path().display()
    );
    // Install a SIGINT/SIGTERM (Windows: console Ctrl-C/Break/close) handler
    // that flips a flag; park until then.
    install_stop_handler();
    while !STOP_REQUESTED.load(Ordering::SeqCst) {
        std::thread::sleep(Duration::from_millis(200));
    }
    server.shutdown();
    Ok(())
}

static STOP_REQUESTED: AtomicBool = AtomicBool::new(false);

#[cfg(unix)]
extern "C" fn stop_handler(_sig: i32) {
    STOP_REQUESTED.store(true, Ordering::SeqCst);
}

#[cfg(unix)]
fn install_stop_handler() {
    unsafe {
        libc::signal(libc::SIGINT, stop_handler as *const () as usize);
        libc::signal(libc::SIGTERM, stop_handler as *const () as usize);
    }
}

#[cfg(windows)]
unsafe extern "system" fn stop_handler(ctrl_type: u32) -> windows_sys::core::BOOL {
    STOP_REQUESTED.store(true, Ordering::SeqCst);
    // Close/logoff/shutdown end the process as soon as this returns: give
    // `serve` a moment to tear the agents down first.
    if ctrl_type >= windows_sys::Win32::System::Console::CTRL_CLOSE_EVENT {
        std::thread::sleep(Duration::from_secs(3));
    }
    1
}

#[cfg(windows)]
fn install_stop_handler() {
    unsafe {
        windows_sys::Win32::System::Console::SetConsoleCtrlHandler(Some(stop_handler), 1);
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn slow_reply_sink_is_byte_bounded_and_does_not_block_other_clients() {
        let (slow, slow_rx) = super::reply_channel(None);
        let (healthy, healthy_rx) = super::reply_channel(None);
        let output = super::CtlReply::Output { instance: "pane".into(), data: vec![b'x'; 64 * 1024] };
        for _ in 0..32 { let _ = slow.send(output.clone()); }
        assert!(slow.budget.lock().unwrap().failed);
        assert!(slow.budget.lock().unwrap().bytes <= super::REPLY_QUEUE_BYTES);
        assert!(healthy.send(super::CtlReply::Pong).is_ok());
        drop(healthy_rx.recv().unwrap());
        assert_eq!(healthy.budget.lock().unwrap().bytes, 0);
        drop(slow_rx);
        assert_eq!(slow.budget.lock().unwrap().bytes, 0);
    }

    #[test]
    fn reply_overflow_wakes_its_socket_reader() {
        let (server, mut client) = UnixStream::pair().unwrap();
        let (sink, _rx) = super::reply_channel(Some(server));
        let huge = super::CtlReply::Output { instance: "pane".into(), data: vec![0; super::REPLY_QUEUE_BYTES] };
        assert!(sink.send(huge).is_err());
        client.set_read_timeout(Some(std::time::Duration::from_secs(1))).unwrap();
        let mut byte = [0];
        assert_eq!(std::io::Read::read(&mut client, &mut byte).unwrap(), 0);
    }

    use super::*;
    use crate::host::tests::{pty_available, resolve, shell};

    macro_rules! require_pty {
        () => {{
            if !pty_available() {
                eprintln!("[skip] no PTY available in this environment");
                return;
            }
        }};
    }

    fn wait_for<F: Fn() -> bool>(pred: F, timeout: Duration) -> bool {
        let start = std::time::Instant::now();
        while start.elapsed() < timeout {
            if pred() {
                return true;
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        pred()
    }

    fn sh_spec(instance: &str, sh: &str) -> SpawnRequest {
        SpawnRequest {
            instance: instance.into(),
            argv: vec![sh.into()],
            cwd: None,
            env: vec![],
            detect: None,
            rows: 20,
            cols: 60,
            display_name: None,
            kind: None,
            label: None,
            meta: None,
            tee_path: None,
            timeout_seconds: None,
        }
    }

    #[test]
    fn startup_input_lost_ack_concurrent_retries_and_relaunch_are_safe() {
        require_pty!();
        let Some(sh) = shell() else { return };
        let sock = tmp_socket("startup_input");
        let mut server = DaemonServer::start(&sock).unwrap();
        let d = server.daemon();
        let mut spec = sh_spec("startup", &sh);
        spec.argv = vec![sh, "-c".into(), "stty -echo; printf 'STARTUP_READY\\n'; while IFS= read -r line; do printf 'GOT:%s\\n' \"$line\"; done".into()];
        spec.env.push(("HEIMDALL_STARTUP_KEY".into(), "launch-1".into()));
        let pid = d.spawn(spec).unwrap();
        assert!(capture_contains(d, "startup", "STARTUP_READY", Duration::from_secs(3)));
        let msg = CtlMsg::StartupInput { instance: "startup".into(), pid, launch_key: "launch-1".into(), data: b"only-once\n".to_vec() };
        // Drop the connection without reading its ack, then repeat on fresh ones.
        let mut lost = UnixStream::connect(&sock).unwrap();
        dproto::write_ctl_msg(&mut lost, &msg).unwrap();
        drop(lost);
        assert!(capture_contains(d, "startup", "GOT:only-once", Duration::from_secs(3)));
        let mut workers = Vec::new();
        for _ in 0..4 {
            let sock = sock.clone();
            let msg = msg.clone();
            workers.push(std::thread::spawn(move || {
                let mut stream = UnixStream::connect(sock).unwrap();
                dproto::write_ctl_msg(&mut stream, &msg).unwrap();
                let reply = await_reply(&mut stream, |_| true, Duration::from_secs(3));
                assert!(matches!(reply, Some(CtlReply::StartupInputDone { pid: p, .. }) if p == pid), "{reply:?}");
            }));
        }
        for worker in workers { worker.join().unwrap(); }
        assert!(d.write_startup_input("startup", pid + 1, "launch-1", b"only-once\n").is_err());
        assert!(d.write_startup_input("startup", pid, "stale", b"only-once\n").is_err());
        assert!(d.write_startup_input("startup", pid, "launch-1", b"changed\n").is_err());
        assert!(d.write_startup_input("missing", pid, "launch-1", b"x\n").is_err());
        d.write_input("startup", b"barrier\n").unwrap();
        assert!(capture_contains(d, "startup", "GOT:barrier", Duration::from_secs(3)));
        let screen = d.capture("startup").unwrap().lines.join("\n");
        assert_eq!(screen.matches("GOT:only-once").count(), 1, "{screen}");
        let replacement = d.restart("startup").unwrap();
        assert!(d.write_startup_input("startup", pid, "launch-1", b"only-once\n").is_err(), "old pid cannot target replacement");
        assert!(capture_contains(d, "startup", "STARTUP_READY", Duration::from_secs(3)));
        d.write_startup_input("startup", replacement, "launch-1", b"new-launch\n").unwrap();
        assert!(capture_contains(d, "startup", "GOT:new-launch", Duration::from_secs(3)));
        d.signal("startup", 9).unwrap();
        assert!(wait_for(|| find(&d.list(), "startup").is_some_and(|info| !info.alive), Duration::from_secs(3)));
        assert!(d.write_startup_input("startup", replacement, "launch-1", b"new-launch\n").is_err(), "exited child cannot receive startup input");
        d.close("startup").unwrap();
        assert!(d.write_startup_input("startup", replacement, "launch-1", b"new-launch\n").is_err());
        server.shutdown();
    }

    fn find(list: &[AgentInfo], instance: &str) -> Option<AgentInfo> {
        list.iter().find(|a| a.instance_id == instance).cloned()
    }

    fn capture_contains(d: &Daemon, instance: &str, needle: &str, timeout: Duration) -> bool {
        let start = std::time::Instant::now();
        while start.elapsed() < timeout {
            if let Some(s) = d.capture(instance) {
                if s.lines.iter().any(|l| l.contains(needle)) {
                    return true;
                }
            }
            std::thread::sleep(Duration::from_millis(30));
        }
        false
    }

    /// Deterministically drive a freshly-spawned shell: RE-SEND `input` on a
    /// retry loop until `needle` shows up in the capture (or timeout). A single
    /// write after a fixed sleep races the child becoming ready to read on a
    /// slow/loaded machine (the shell may still be sourcing rc files, or the
    /// re-spawned PTY reader may not be plumbed yet); re-sending removes that
    /// race without assuming any timing. Sending `echo ...` more than once is
    /// harmless — it just prints again.
    fn drive_until(d: &Daemon, instance: &str, input: &[u8], needle: &str, timeout: Duration) -> bool {
        let start = std::time::Instant::now();
        while start.elapsed() < timeout {
            if d.write_input(instance, input).is_err() {
                return false;
            }
            let deadline = std::time::Instant::now() + Duration::from_millis(250);
            while std::time::Instant::now() < deadline {
                if let Some(s) = d.capture(instance) {
                    if s.lines.iter().any(|l| l.contains(needle)) {
                        return true;
                    }
                }
                std::thread::sleep(Duration::from_millis(25));
            }
        }
        false
    }

    #[test]
    fn spawn_two_agents_drive_each_independently() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => {
                eprintln!("[skip] no shell");
                return;
            }
        };
        let d = Daemon::new();
        d.spawn(sh_spec("a", &sh)).unwrap();
        d.spawn(sh_spec("b", &sh)).unwrap();
        assert_eq!(d.agent_count(), 2);

        // Drive each independently (retry-until-ready, no fixed-sleep race).
        assert!(drive_until(&d, "a", b"echo AAA111\n", "AAA111", Duration::from_secs(5)));
        assert!(drive_until(&d, "b", b"echo BBB222\n", "BBB222", Duration::from_secs(5)));
        // Cross-check isolation: a's screen must not contain b's marker.
        let a = d.capture("a").unwrap();
        assert!(!a.lines.iter().any(|l| l.contains("BBB222")));

        d.shutdown();
    }

    #[test]
    fn close_one_leaves_the_other() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let d = Daemon::new();
        d.spawn(sh_spec("keep", &sh)).unwrap();
        d.spawn(sh_spec("drop", &sh)).unwrap();
        std::thread::sleep(Duration::from_millis(200));

        d.close("drop").unwrap();
        assert_eq!(d.agent_count(), 1);
        assert!(find(&d.list(), "drop").is_none());
        // Survivor still drivable (retry-until-ready).
        assert!(d.is_alive("keep"));
        assert!(drive_until(&d, "keep", b"echo STILL_HERE\n", "STILL_HERE", Duration::from_secs(5)));

        d.shutdown();
    }

    #[test]
    fn spawn_timeout_terminates_child_but_default_has_no_deadline() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let d = Daemon::new();

        let mut timed = sh_spec("timed", &sh);
        timed.argv = vec![sh.clone(), "-c".into(), "while :; do sleep 1; done".into()];
        timed.timeout_seconds = Some(1);
        d.spawn(timed).unwrap();

        let mut unlimited = sh_spec("unlimited", &sh);
        unlimited.argv = vec![sh, "-c".into(), "while :; do sleep 1; done".into()];
        d.spawn(unlimited).unwrap();

        assert!(
            wait_for(|| !d.is_alive("timed"), Duration::from_secs(3)),
            "timed child was still alive after its deadline"
        );
        assert!(d.is_alive("unlimited"), "omitted timeout must leave the child running");

        d.shutdown();
    }

    #[test]
    fn spawn_rejects_zero_timeout() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let d = Daemon::new();
        let mut spec = sh_spec("zero-timeout", &sh);
        spec.timeout_seconds = Some(0);
        assert!(d.spawn(spec).is_err(), "zero timeout was accepted");
    }

    /// REQ HOST-1 (env plumbing, deterministic): spawn a ONE-SHOT, NON-LOGIN,
    /// non-interactive `sh -c 'echo MARK:$MARKER_ENV'` with extra_env and assert
    /// the captured output shows the value. This removes interactive-shell,
    /// login-shell (`-l` profile sourcing), and input-timing variables entirely
    /// — if this passes, extra_env genuinely reaches the child's environment.
    /// (Requested by review to disambiguate env plumbing from shell init.)
    #[test]
    fn extra_env_reaches_child_oneshot() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let d = Daemon::new();
        d.spawn(SpawnRequest {
            instance: "envp".into(),
            argv: vec![sh, "-c".into(), "echo MARK:$MARKER_ENV; sleep 2".into()],
            cwd: None,
            env: vec![("MARKER_ENV".into(), "xyzzy".into())],
            detect: None,
            rows: 10,
            cols: 40,
            display_name: None,
                ..Default::default()
        })
        .unwrap();
        assert!(
            capture_contains(&d, "envp", "MARK:xyzzy", Duration::from_secs(5)),
            "extra_env did not reach the child (one-shot non-login sh)"
        );
        d.shutdown();
    }

    #[test]
    fn restart_reuses_spec_and_same_id() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let d = Daemon::new();
        // DETERMINISTIC design: the agent's argv itself emits the env marker at
        // startup, then blocks. So every (re)spawn from the remembered spec
        // re-prints `BOOT:xyzzy` with NO interactive input, NO login-shell
        // profile sourcing, and NO input-timing race — the only variables the
        // reviewer flagged. This asserts BOTH that restart reuses the exact
        // spec (same argv/cwd/env) AND that extra_env survives the restart.
        let spec = SpawnRequest {
            instance: "r".into(),
            argv: vec![
                sh.clone(),
                "-c".into(),
                // Print marker once at boot, then stay alive (read blocks).
                "echo BOOT:$MARKER_ENV; while :; do sleep 1; done".into(),
            ],
            cwd: None,
            env: vec![("MARKER_ENV".into(), "xyzzy".into())],
            detect: None,
            rows: 20,
            cols: 60,
            display_name: None,
                ..Default::default()
        };
        d.spawn(spec).unwrap();
        // Marker must appear on the ORIGINAL child (env applied on first spawn).
        assert!(
            capture_contains(&d, "r", "BOOT:xyzzy", Duration::from_secs(5)),
            "env not applied on initial spawn"
        );
        let pid1 = find(&d.list(), "r").unwrap().pid;

        let pid2 = d.restart("r").unwrap();
        // Same id still registered, new child pid, still alive.
        assert_eq!(d.agent_count(), 1);
        assert!(find(&d.list(), "r").is_some());
        assert_ne!(pid1, pid2, "restart should spawn a new child");

        // The re-spawned child (from the remembered spec) re-prints the marker.
        // Its fresh VT model starts blank, so seeing BOOT:xyzzy again proves the
        // remembered argv+env were re-applied on restart.
        assert!(
            capture_contains(&d, "r", "BOOT:xyzzy", Duration::from_secs(5)),
            "remembered spec/env did not survive restart"
        );

        d.shutdown();
    }

    #[test]
    fn list_reflects_state_including_exit() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let d = Daemon::new();
        d.spawn(sh_spec("live", &sh)).unwrap();
        // A short-lived agent that exits on its own.
        let tru = resolve("true").or_else(|| resolve("/usr/bin/true"));
        if let Some(tru) = tru {
            d.spawn(SpawnRequest {
                instance: "dead".into(),
                argv: vec![tru],
                cwd: None,
                env: vec![],
                detect: None,
                rows: 10,
                cols: 40,
                display_name: None,
                        ..Default::default()
            })
            .unwrap();
        }
        std::thread::sleep(Duration::from_millis(300));

        let live = find(&d.list(), "live").unwrap();
        assert!(live.alive);
        assert!(live.pid > 0);
        assert_eq!(live.exit_code, None);
        assert_eq!(live.program, sh);

        if find(&d.list(), "dead").is_some() {
            assert!(
                wait_for(|| !d.is_alive("dead"), Duration::from_secs(3)),
                "short-lived agent never exited"
            );
            let dead = find(&d.list(), "dead").unwrap();
            assert!(!dead.alive);
            assert_eq!(dead.exit_code, Some(0));
        }

        d.shutdown();
    }

    #[test]
    fn spawn_rejects_duplicate_and_empty() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let d = Daemon::new();
        d.spawn(sh_spec("dup", &sh)).unwrap();
        assert!(d.spawn(sh_spec("dup", &sh)).is_err(), "duplicate id allowed");
        assert!(
            d.spawn(sh_spec("", &sh)).is_err(),
            "empty instance id allowed"
        );
        let mut noargv = sh_spec("noargv", &sh);
        noargv.argv.clear();
        assert!(d.spawn(noargv).is_err(), "empty argv allowed");
        d.shutdown();
    }

    #[test]
    fn control_ops_on_missing_instance_error() {
        let d = Daemon::new();
        assert!(d.close("nope").is_err());
        assert!(d.restart("nope").is_err());
        assert!(d.write_input("nope", b"x").is_err());
        assert!(d.capture("nope").is_none());
        assert!(!d.is_alive("nope"));
        assert!(d.list().is_empty());
    }

    // ---- socket-level (dproto) end-to-end -------------------------------

    fn tmp_socket(name: &str) -> std::path::PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "ham-daemon-{}-{}-{}.sock",
            name,
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        p
    }

    /// Read frames until a reply matching `pred` (skipping others), or timeout.
    fn await_reply(
        stream: &mut UnixStream,
        pred: impl Fn(&CtlReply) -> bool,
        timeout: Duration,
    ) -> Option<CtlReply> {
        stream
            .set_read_timeout(Some(Duration::from_millis(200)))
            .unwrap();
        let start = std::time::Instant::now();
        while start.elapsed() < timeout {
            match dproto::read_ctl_reply(stream) {
                Ok(Some(r)) => {
                    if pred(&r) {
                        return Some(r);
                    }
                }
                Ok(None) => return None,
                Err(ref e)
                    if e.kind() == std::io::ErrorKind::WouldBlock
                        || e.kind() == std::io::ErrorKind::TimedOut => {}
                Err(_) => return None,
            }
        }
        None
    }

    #[test]
    fn shutdown_acks_and_flips_stop_flag() {
        // No PTY needed: Shutdown is a pure control-plane op. Reset the process
        // global first so a prior test/run can't leave it set.
        STOP_REQUESTED.store(false, Ordering::SeqCst);
        let sock = tmp_socket("shutdown");
        let server = DaemonServer::start(&sock).unwrap();
        std::thread::sleep(Duration::from_millis(150));

        let mut c = UnixStream::connect(&sock).unwrap();
        dproto::write_ctl_msg(&mut c, &CtlMsg::Shutdown).unwrap();

        // We get the ShuttingDown ack...
        let ack = await_reply(&mut c, |r| matches!(r, CtlReply::ShuttingDown), Duration::from_secs(2));
        assert!(matches!(ack, Some(CtlReply::ShuttingDown)), "expected ShuttingDown ack, got {ack:?}");
        // ...and the daemon's serve-loop stop flag is now set.
        assert!(STOP_REQUESTED.load(Ordering::SeqCst), "Shutdown must flip STOP_REQUESTED");

        drop(server);
        STOP_REQUESTED.store(false, Ordering::SeqCst);
    }

    #[test]
    fn socket_spawn_list_close_over_dproto() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let sock = tmp_socket("e2e");
        let mut server = DaemonServer::start(&sock).unwrap();
        std::thread::sleep(Duration::from_millis(150));

        let mut c = UnixStream::connect(&sock).unwrap();
        // Spawn two agents.
        for inst in ["one", "two"] {
            dproto::write_ctl_msg(
                &mut c,
                &CtlMsg::Spawn(SpawnRequest {
                    instance: inst.into(),
                    argv: vec![sh.clone()],
                    cwd: None,
                    env: vec![],
                    detect: None,
                    rows: 20,
                    cols: 60,
                    display_name: None,
                                ..Default::default()
                }),
            )
            .unwrap();
            let got = await_reply(
                &mut c,
                |r| matches!(r, CtlReply::Spawned { instance, .. } if instance == inst),
                Duration::from_secs(3),
            );
            assert!(got.is_some(), "no Spawned ack for {inst}");
        }
        assert_eq!(server.daemon().agent_count(), 2);

        // List shows both.
        dproto::write_ctl_msg(&mut c, &CtlMsg::List).unwrap();
        let list = await_reply(
            &mut c,
            |r| matches!(r, CtlReply::AgentList(_)),
            Duration::from_secs(3),
        );
        match list {
            Some(CtlReply::AgentList(agents)) => assert_eq!(agents.len(), 2),
            _ => panic!("no AgentList reply"),
        }

        // Attach + drive "one"; capture reflects it. Re-send input + re-request
        // capture on a loop so a slow/loaded machine can't lose the single
        // write before the shell is ready (mirrors drive_until, over the wire).
        dproto::write_ctl_msg(&mut c, &CtlMsg::Attach { instance: "one".into() }).unwrap();
        let mut sock_ok = false;
        let start = std::time::Instant::now();
        while start.elapsed() < Duration::from_secs(6) {
            dproto::write_ctl_msg(
                &mut c,
                &CtlMsg::Input {
                    instance: "one".into(),
                    data: b"echo SOCK_OK\n".to_vec(),
                },
            )
            .unwrap();
            std::thread::sleep(Duration::from_millis(200));
            dproto::write_ctl_msg(&mut c, &CtlMsg::Capture { instance: "one".into() }).unwrap();
            if await_reply(
                &mut c,
                |r| matches!(r, CtlReply::Screen { screen, .. } if screen.lines.iter().any(|l| l.contains("SOCK_OK"))),
                Duration::from_millis(500),
            )
            .is_some()
            {
                sock_ok = true;
                break;
            }
        }
        assert!(sock_ok, "capture never showed SOCK_OK");

        // Close "one" leaves "two".
        dproto::write_ctl_msg(&mut c, &CtlMsg::Close { instance: "one".into() }).unwrap();
        let closed = await_reply(
            &mut c,
            |r| matches!(r, CtlReply::Closed { instance } if instance == "one"),
            Duration::from_secs(3),
        );
        assert!(closed.is_some(), "no Closed ack");
        assert!(
            wait_for(|| server.daemon().agent_count() == 1, Duration::from_secs(2)),
            "close did not unregister"
        );
        assert!(server.daemon().is_alive("two"));

        server.shutdown();
    }

    #[test]
    fn socket_spawn_duplicate_returns_error_reply() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let sock = tmp_socket("dup");
        let mut server = DaemonServer::start(&sock).unwrap();
        std::thread::sleep(Duration::from_millis(150));
        let mut c = UnixStream::connect(&sock).unwrap();
        let spec = CtlMsg::Spawn(SpawnRequest {
            instance: "x".into(),
            argv: vec![sh.clone()],
            cwd: None,
            env: vec![],
            detect: None,
            rows: 20,
            cols: 60,
            display_name: None,
                ..Default::default()
        });
        dproto::write_ctl_msg(&mut c, &spec).unwrap();
        assert!(await_reply(
            &mut c,
            |r| matches!(r, CtlReply::Spawned { .. }),
            Duration::from_secs(3)
        )
        .is_some());
        dproto::write_ctl_msg(&mut c, &spec).unwrap();
        let err = await_reply(
            &mut c,
            |r| matches!(r, CtlReply::Error { .. }),
            Duration::from_secs(3),
        );
        assert!(matches!(err, Some(CtlReply::Error { .. })), "expected Error reply");
        server.shutdown();
    }

    // ---- HOST-4: single-agent attach isolation (real PTY) ----------------

    /// The single-agent `attach --instance <id>` client (src/dclient.rs) relies
    /// on the daemon delivering ONLY the attached instance's `Output`. Spawn two
    /// agents, attach to just one, drive both, and assert every `Output` frame
    /// we receive is for the attached instance (never the other). Also proves
    /// the child survives `Detach`.
    #[test]
    fn socket_attach_one_instance_isolates_output() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let sock = tmp_socket("h4iso");
        let mut server = DaemonServer::start(&sock).unwrap();
        std::thread::sleep(Duration::from_millis(150));

        // Spawn both agents via the daemon handle (drive_until needs it).
        let d = server.daemon();
        d.spawn(sh_spec("solo", &sh)).unwrap();
        d.spawn(sh_spec("other", &sh)).unwrap();

        // A wire client that attaches to ONLY "solo".
        let mut c = UnixStream::connect(&sock).unwrap();
        c.set_read_timeout(Some(Duration::from_millis(200))).ok();
        dproto::write_ctl_msg(&mut c, &CtlMsg::Attach { instance: "solo".into() }).unwrap();
        // The Attach ack is a Screen for "solo".
        assert!(
            await_reply(
                &mut c,
                |r| matches!(r, CtlReply::Screen { instance, .. } if instance == "solo"),
                Duration::from_secs(3),
            )
            .is_some(),
            "no Screen ack for solo attach"
        );

        // Drive BOTH agents so each produces output.
        assert!(drive_until(d, "solo", b"echo SOLO_OUT\n", "SOLO_OUT", Duration::from_secs(6)));
        assert!(drive_until(d, "other", b"echo OTHER_OUT\n", "OTHER_OUT", Duration::from_secs(6)));

        // Collect Output frames for ~1s; every one must be for "solo", and we
        // must actually see solo's marker stream through.
        let mut saw_solo = false;
        let start = std::time::Instant::now();
        while start.elapsed() < Duration::from_secs(2) {
            match dproto::read_ctl_reply(&mut c) {
                Ok(Some(CtlReply::Output { instance, data })) => {
                    assert_eq!(instance, "solo", "leaked output from another instance");
                    if String::from_utf8_lossy(&data).contains("SOLO_OUT") {
                        saw_solo = true;
                    }
                }
                Ok(Some(_)) => {} // Screen/ScreenChanged for solo etc. — fine.
                Ok(None) => break,
                Err(ref e)
                    if e.kind() == std::io::ErrorKind::WouldBlock
                        || e.kind() == std::io::ErrorKind::TimedOut => {}
                Err(_) => break,
            }
        }
        assert!(saw_solo, "never received solo's live output while attached");

        // Detach solo; the child must survive.
        dproto::write_ctl_msg(&mut c, &CtlMsg::Detach { instance: "solo".into() }).unwrap();
        assert!(
            wait_for(|| server.daemon().is_alive("solo"), Duration::from_secs(1)),
            "solo child must survive detach"
        );
        assert!(server.daemon().is_alive("other"));

        server.shutdown();
    }

    // ---- HOST-5: control/event stream separation (real PTY) --------------

    /// Read the NEXT control reply on a control-only connection, mirroring the
    /// CLI's `request()`: async event frames (Output/ChildExited/ScreenChanged/
    /// StartupReady/StartupBlocked) must NEVER reach a client that did not
    /// Attach, so encountering one here is a hard failure (the bug this task
    /// fixes). Screen is only produced in reply to Attach/Capture, so it is
    /// also unexpected on a control-only op.
    fn ctl_reply_strict(c: &mut UnixStream, timeout: Duration) -> CtlReply {
        let start = std::time::Instant::now();
        while start.elapsed() < timeout {
            match dproto::read_ctl_reply(c) {
                Ok(Some(
                    ev @ (CtlReply::Output { .. }
                    | CtlReply::ChildExited { .. }
                    | CtlReply::ScreenChanged { .. }
                    | CtlReply::StartupReady { .. }
                    | CtlReply::StartupBlocked { .. }),
                )) => {
                    panic!("control-only connection received async event: {ev:?}");
                }
                Ok(Some(reply)) => return reply,
                Ok(None) => panic!("daemon closed connection without replying"),
                Err(ref e)
                    if e.kind() == std::io::ErrorKind::WouldBlock
                        || e.kind() == std::io::ErrorKind::TimedOut => {}
                Err(e) => panic!("read error: {e}"),
            }
        }
        panic!("timed out waiting for control reply");
    }

    /// ACCEPTANCE (HOST-5): with an agent ACTIVELY producing output, a
    /// control-only client must be able to run list/restart/close repeatedly
    /// with no "unexpected reply" — i.e. it only ever sees its command's reply,
    /// never an async event frame. Before the fix this failed within a couple
    /// iterations because every connection was auto-subscribed and events were
    /// broadcast to all connections.
    #[test]
    fn control_only_client_never_sees_async_events_under_busy_agent() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let sock = tmp_socket("h5ctl");
        let mut server = DaemonServer::start(&sock).unwrap();
        std::thread::sleep(Duration::from_millis(150));

        // A busy agent that spews output continuously (drives ScreenChanged +
        // Output constantly). Runs a tight echo loop like the task's repro.
        let d = server.daemon();
        d.spawn(SpawnRequest {
            instance: "busy".into(),
            argv: vec![
                sh.clone(),
                "-c".into(),
                "i=0; while :; do echo tick $i; i=$((i+1)); done".into(),
            ],
            cwd: None,
            env: vec![],
            detect: None,
            rows: 20,
            cols: 60,
            display_name: None,
                ..Default::default()
        })
        .unwrap();

        // A SECOND agent used as the restart/close target so the busy one keeps
        // streaming throughout (close removes an agent; we want sustained load).
        // We restart/close/re-spawn "victim" each round while "busy" spews.
        let timeout = Duration::from_secs(4);
        for round in 0..8 {
            // Fresh control-only connection each round (like the CLI's one-shot
            // `request()`), plus one long-lived connection tested below.
            let mut c = UnixStream::connect(&sock).unwrap();
            c.set_read_timeout(Some(Duration::from_millis(100))).ok();

            // list
            dproto::write_ctl_msg(&mut c, &CtlMsg::List).unwrap();
            match ctl_reply_strict(&mut c, timeout) {
                CtlReply::AgentList(_) => {}
                other => panic!("round {round}: list got {other:?}"),
            }

            // spawn a victim, then restart it, then close it — all control ops
            // that must return exactly their own reply despite busy's output.
            let vic = format!("victim{round}");
            dproto::write_ctl_msg(
                &mut c,
                &CtlMsg::Spawn(sh_spec(&vic, &sh)),
            )
            .unwrap();
            match ctl_reply_strict(&mut c, timeout) {
                CtlReply::Spawned { instance, .. } if instance == vic => {}
                other => panic!("round {round}: spawn got {other:?}"),
            }

            dproto::write_ctl_msg(&mut c, &CtlMsg::Restart { instance: vic.clone() }).unwrap();
            match ctl_reply_strict(&mut c, timeout) {
                CtlReply::Restarted { instance, .. } if instance == vic => {}
                other => panic!("round {round}: restart got {other:?}"),
            }

            dproto::write_ctl_msg(&mut c, &CtlMsg::Close { instance: vic.clone() }).unwrap();
            match ctl_reply_strict(&mut c, timeout) {
                CtlReply::Closed { instance } if instance == vic => {}
                other => panic!("round {round}: close got {other:?}"),
            }
        }

        // Also prove a SINGLE long-lived control connection stays clean across
        // many ops (the CLI can reuse a socket).
        let mut c = UnixStream::connect(&sock).unwrap();
        c.set_read_timeout(Some(Duration::from_millis(100))).ok();
        for _ in 0..10 {
            dproto::write_ctl_msg(&mut c, &CtlMsg::List).unwrap();
            match ctl_reply_strict(&mut c, timeout) {
                CtlReply::AgentList(_) => {}
                other => panic!("long-lived list got {other:?}"),
            }
        }

        // The busy agent is still alive and was never disturbed.
        assert!(server.daemon().is_alive("busy"));
        server.shutdown();
    }

    // ---- HOST-2: detector integration over the daemon (real PTY) ---------

    /// A blocked pattern in the child's output must produce a StartupBlocked
    /// event carrying the sanitized reason. The agent argv prints the blocked
    /// text itself, so no interactive input or timing is involved.
    #[test]
    fn detector_emits_startup_blocked_on_pattern() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let sock = tmp_socket("blocked");
        let mut server = DaemonServer::start(&sock).unwrap();
        std::thread::sleep(Duration::from_millis(150));
        let mut c = UnixStream::connect(&sock).unwrap();

        let detect = r#"{
            "enabled": true,
            "startup_probe_seconds": 10,
            "capture_interval_ms": 100,
            "blocked_patterns": ["LOGIN_REQUIRED_MARK"],
            "sanitized_reason_mapping": ["login=Provider login required"]
        }"#;
        dproto::write_ctl_msg(
            &mut c,
            &CtlMsg::Spawn(SpawnRequest {
                instance: "b".into(),
                argv: vec![
                    sh.clone(),
                    "-c".into(),
                    "echo LOGIN_REQUIRED_MARK; while :; do sleep 1; done".into(),
                ],
                cwd: None,
                env: vec![],
                detect: Some(detect.into()),
                rows: 20,
                cols: 60,
                display_name: None,
                        ..Default::default()
            }),
        )
        .unwrap();
        // Lifecycle/activity events flow to WatchEvents subscribers now.
        dproto::write_ctl_msg(&mut c, &CtlMsg::WatchEvents).unwrap();
        dproto::write_ctl_msg(&mut c, &CtlMsg::Attach { instance: "b".into() }).unwrap();

        let ev = await_reply(
            &mut c,
            |r| matches!(r, CtlReply::StartupBlocked { instance, .. } if instance == "b"),
            Duration::from_secs(6),
        );
        match ev {
            Some(CtlReply::StartupBlocked {
                reason_code,
                safe_diagnostic,
                ..
            }) => {
                assert!(reason_code.starts_with("blocked_0"), "reason: {reason_code}");
                assert_eq!(safe_diagnostic, "Provider login required");
            }
            other => panic!("expected StartupBlocked, got {other:?}"),
        }
        server.shutdown();
    }

    /// Auto-enter: when the child prints a pattern, the detector sends the
    /// configured pre-keys+Enter to the child. We prove the keys ARRIVE by
    /// having the shell `read` a line after printing the prompt and echo a
    /// confirmation once it receives the Enter the detector sends.
    #[test]
    fn detector_auto_enter_sends_keys_to_child() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let sock = tmp_socket("autoenter");
        let mut server = DaemonServer::start(&sock).unwrap();
        std::thread::sleep(Duration::from_millis(150));
        let mut c = UnixStream::connect(&sock).unwrap();

        // Print the prompt, then block on `read`; when the detector sends Enter
        // the read completes and we print AUTO_ENTER_OK.
        let detect = r#"{
            "enabled": true,
            "startup_probe_seconds": 10,
            "capture_interval_ms": 100,
            "auto_enter_patterns": ["TRUST_PROMPT_MARK"],
            "auto_enter_pre_keys": [""]
        }"#;
        dproto::write_ctl_msg(
            &mut c,
            &CtlMsg::Spawn(SpawnRequest {
                instance: "ae".into(),
                argv: vec![
                    sh.clone(),
                    "-c".into(),
                    "echo TRUST_PROMPT_MARK; read _x; echo AUTO_ENTER_OK; while :; do sleep 1; done".into(),
                ],
                cwd: None,
                env: vec![],
                detect: Some(detect.into()),
                rows: 20,
                cols: 60,
                display_name: None,
                        ..Default::default()
            }),
        )
        .unwrap();
        assert!(await_reply(&mut c, |r| matches!(r, CtlReply::Spawned { .. }), Duration::from_secs(3)).is_some());

        // Attach + poll the capture until AUTO_ENTER_OK appears, proving the
        // detector's Enter reached the child's `read`.
        dproto::write_ctl_msg(&mut c, &CtlMsg::Attach { instance: "ae".into() }).unwrap();
        let mut ok = false;
        let start = std::time::Instant::now();
        while start.elapsed() < Duration::from_secs(6) {
            dproto::write_ctl_msg(&mut c, &CtlMsg::Capture { instance: "ae".into() }).unwrap();
            if await_reply(
                &mut c,
                |r| matches!(r, CtlReply::Screen { screen, .. } if screen.lines.iter().any(|l| l.contains("AUTO_ENTER_OK"))),
                Duration::from_millis(400),
            )
            .is_some()
            {
                ok = true;
                break;
            }
        }
        assert!(ok, "auto-enter Enter never reached the child (no AUTO_ENTER_OK)");
        server.shutdown();
    }

    /// A clean startup (no blocked/auto-enter patterns, unknown allowed) must
    /// eventually emit StartupReady after the probe window.
    #[test]
    fn detector_emits_startup_ready_on_timeout() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let sock = tmp_socket("ready");
        let mut server = DaemonServer::start(&sock).unwrap();
        std::thread::sleep(Duration::from_millis(150));
        let mut c = UnixStream::connect(&sock).unwrap();

        // 1s probe window, nothing matches → Ready.
        let detect = r#"{"enabled": true, "startup_probe_seconds": 1, "capture_interval_ms": 100}"#;
        dproto::write_ctl_msg(
            &mut c,
            &CtlMsg::Spawn(SpawnRequest {
                instance: "r".into(),
                argv: vec![sh.clone()],
                cwd: None,
                env: vec![],
                detect: Some(detect.into()),
                rows: 20,
                cols: 60,
                display_name: None,
                        ..Default::default()
            }),
        )
        .unwrap();
        // Lifecycle/activity events flow to WatchEvents subscribers now.
        dproto::write_ctl_msg(&mut c, &CtlMsg::WatchEvents).unwrap();
        dproto::write_ctl_msg(&mut c, &CtlMsg::Attach { instance: "r".into() }).unwrap();

        let ev = await_reply(
            &mut c,
            |r| matches!(r, CtlReply::StartupReady { instance } if instance == "r"),
            Duration::from_secs(5),
        );
        assert!(ev.is_some(), "never received StartupReady");
        server.shutdown();
    }

    /// ScreenChanged fires when the child's rendered content changes. We spawn a
    /// shell, then drive it to print new text and assert we observe at least two
    /// distinct ScreenChanged hashes.
    #[test]
    fn detector_emits_screen_changed_on_content_change() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let sock = tmp_socket("changed");
        let mut server = DaemonServer::start(&sock).unwrap();
        std::thread::sleep(Duration::from_millis(150));
        let mut c = UnixStream::connect(&sock).unwrap();

        // detect present so the loop runs; no patterns so it just emits activity.
        let detect = r#"{"enabled": true, "capture_interval_ms": 100}"#;
        dproto::write_ctl_msg(
            &mut c,
            &CtlMsg::Spawn(SpawnRequest {
                instance: "ch".into(),
                argv: vec![sh.clone()],
                cwd: None,
                env: vec![],
                detect: Some(detect.into()),
                rows: 20,
                cols: 60,
                display_name: None,
                        ..Default::default()
            }),
        )
        .unwrap();
        assert!(await_reply(&mut c, |r| matches!(r, CtlReply::Spawned { .. }), Duration::from_secs(3)).is_some());
        // Lifecycle/activity events flow to WatchEvents subscribers now.
        dproto::write_ctl_msg(&mut c, &CtlMsg::WatchEvents).unwrap();
        dproto::write_ctl_msg(&mut c, &CtlMsg::Attach { instance: "ch".into() }).unwrap();

        // Collect ScreenChanged hashes while driving new content on a retry loop.
        let mut hashes = std::collections::HashSet::new();
        let start = std::time::Instant::now();
        let mut n = 0u32;
        c.set_read_timeout(Some(Duration::from_millis(150))).unwrap();
        while start.elapsed() < Duration::from_secs(6) && hashes.len() < 2 {
            n += 1;
            dproto::write_ctl_msg(
                &mut c,
                &CtlMsg::Input {
                    instance: "ch".into(),
                    data: format!("echo CHANGE_{n}\n").into_bytes(),
                },
            )
            .unwrap();
            let until = std::time::Instant::now() + Duration::from_millis(400);
            while std::time::Instant::now() < until {
                match dproto::read_ctl_reply(&mut c) {
                    Ok(Some(CtlReply::ScreenChanged { hash, .. })) => {
                        hashes.insert(hash);
                    }
                    Ok(Some(_)) => {}
                    Ok(None) => break,
                    Err(ref e)
                        if e.kind() == std::io::ErrorKind::WouldBlock
                            || e.kind() == std::io::ErrorKind::TimedOut => {}
                    Err(_) => break,
                }
            }
        }
        assert!(
            hashes.len() >= 2,
            "expected >=2 distinct ScreenChanged hashes, got {}",
            hashes.len()
        );
        server.shutdown();
    }

    #[test]
    fn default_crt_resolution_on_zero_rows_cols() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let d = Daemon::new();
        d.spawn(SpawnRequest {
            instance: "crt_default".into(),
            argv: vec![sh],
            cwd: None,
            env: vec![],
            detect: None,
            rows: 0,
            cols: 0,
            display_name: None,
                ..Default::default()
        })
        .unwrap();

        let snap = d.capture("crt_default").unwrap();
        assert_eq!(snap.rows, CRT_ROWS);
        assert_eq!(snap.cols, CRT_COLS);

        let info = find(&d.list(), "crt_default").unwrap();
        assert_eq!(info.rows, CRT_ROWS);
        assert_eq!(info.cols, CRT_COLS);

        d.shutdown();
    }

    #[test]
    fn detach_resizes_unattached_instance_to_crt() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let d = Daemon::new();
        d.spawn(SpawnRequest {
            instance: "inst1".into(),
            argv: vec![sh],
            cwd: None,
            env: vec![],
            detect: None,
            rows: 20,
            cols: 60,
            display_name: None,
                ..Default::default()
        })
        .unwrap();

        let (tx1, _rx1) = reply_channel(None);
        let (tx2, _rx2) = reply_channel(None);
        d.register_sink(1, tx1);
        d.register_sink(2, tx2);

        // Attach both client 1 and client 2.
        d.attach(1, "inst1").unwrap();
        d.attach(2, "inst1").unwrap();

        // Dynamically resize while both are attached.
        d.resize("inst1", 40, 100).unwrap();
        assert_eq!(d.capture("inst1").unwrap().rows, 40);
        assert_eq!(d.capture("inst1").unwrap().cols, 100);

        // Client 1 detaches; client 2 is still attached -> should NOT resize to CRT.
        d.detach(1, "inst1");
        assert_eq!(d.capture("inst1").unwrap().rows, 40);
        assert_eq!(d.capture("inst1").unwrap().cols, 100);

        // Client 2 detaches; 0 subscribers remain -> automatically resizes to CRT (25, 80).
        d.detach(2, "inst1");
        assert_eq!(d.capture("inst1").unwrap().rows, CRT_ROWS);
        assert_eq!(d.capture("inst1").unwrap().cols, CRT_COLS);

        d.shutdown();
    }

    #[test]
    fn unsubscribe_resizes_unattached_instances_to_crt() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let d = Daemon::new();
        d.spawn(SpawnRequest {
            instance: "inst_unsub".into(),
            argv: vec![sh],
            cwd: None,
            env: vec![],
            detect: None,
            rows: 20,
            cols: 60,
            display_name: None,
                ..Default::default()
        })
        .unwrap();

        let (tx1, _rx1) = reply_channel(None);
        let (tx2, _rx2) = reply_channel(None);
        d.register_sink(1, tx1);
        d.register_sink(2, tx2);

        // Attach client 1 and client 2.
        d.attach(1, "inst_unsub").unwrap();
        d.attach(2, "inst_unsub").unwrap();

        d.resize("inst_unsub", 50, 120).unwrap();
        assert_eq!(d.capture("inst_unsub").unwrap().rows, 50);
        assert_eq!(d.capture("inst_unsub").unwrap().cols, 120);

        // Client 1 disconnects/unsubscribes; client 2 is still attached -> no resize.
        d.unsubscribe(1);
        assert_eq!(d.capture("inst_unsub").unwrap().rows, 50);
        assert_eq!(d.capture("inst_unsub").unwrap().cols, 120);

        // Client 2 disconnects/unsubscribes; 0 subscribers remain -> auto-resized to CRT (25, 80).
        d.unsubscribe(2);
        assert_eq!(d.capture("inst_unsub").unwrap().rows, CRT_ROWS);
        assert_eq!(d.capture("inst_unsub").unwrap().cols, CRT_COLS);

        d.shutdown();
    }

    #[test]
    fn unattached_agent_starts_at_80x25_and_detach_resizes_back_to_80x25() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let d = Daemon::new();
        // Unattached agent starts at 80x25
        d.spawn(SpawnRequest {
            instance: "inst_crt_detach".into(),
            argv: vec![sh],
            cwd: None,
            env: vec![],
            detect: None,
            rows: 0,
            cols: 0,
            display_name: None,
                ..Default::default()
        })
        .unwrap();

        assert_eq!(d.capture("inst_crt_detach").unwrap().rows, CRT_ROWS);
        assert_eq!(d.capture("inst_crt_detach").unwrap().cols, CRT_COLS);

        let (tx, _rx) = reply_channel(None);
        d.register_sink(1, tx);

        // Attaching at 40x120
        d.attach(1, "inst_crt_detach").unwrap();
        d.resize("inst_crt_detach", 40, 120).unwrap();
        assert_eq!(d.capture("inst_crt_detach").unwrap().rows, 40);
        assert_eq!(d.capture("inst_crt_detach").unwrap().cols, 120);

        // Detaching automatically resizes the instance back to 80x25
        d.detach(1, "inst_crt_detach");
        assert_eq!(d.capture("inst_crt_detach").unwrap().rows, CRT_ROWS);
        assert_eq!(d.capture("inst_crt_detach").unwrap().cols, CRT_COLS);

        d.shutdown();
    }

    #[test]
    fn daemon_shell_registration_lookup_input_resize_and_listing() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let d = Daemon::new();
        assert!(!d.has_shell("sh_test_1"));
        assert!(d.shell("sh_test_1").is_none());

        let pid = d
            .spawn(SpawnRequest {
                instance: "sh_test_1".into(),
                argv: vec![sh, "-c".into(), "while :; do sleep 1; done".into()],
                cwd: None,
                env: vec![],
                detect: None,
                rows: 25,
                cols: 80,
                display_name: Some("test-shell".into()),
                ..Default::default()
            })
            .unwrap();

        assert!(d.has_shell("sh_test_1"));
        let s = d.shell("sh_test_1").expect("shell should exist");
        assert_eq!(s.shell_id(), "sh_test_1");
        assert_eq!(s.instance_id(), "sh_test_1");
        assert_eq!(s.pid, pid);
        assert!(s.alive);
        assert_eq!(s.rows, 25);
        assert_eq!(s.cols, 80);
        assert_eq!(s.display_name.as_deref(), Some("test-shell"));

        let shells = d.list_shells();
        assert_eq!(shells.len(), 1);
        assert_eq!(shells[0].shell_id(), "sh_test_1");
        assert_eq!(shells[0].instance_id(), "sh_test_1");
        assert_eq!(shells[0].display_name.as_deref(), Some("test-shell"));

        // Resize by shell_id using both resize and shell_resize
        d.shell_resize("sh_test_1", 30, 100).unwrap();
        let cap = d.shell_capture("sh_test_1").unwrap();
        assert_eq!(cap.rows, 30);
        assert_eq!(cap.cols, 100);

        d.resize("sh_test_1", 35, 110).unwrap();
        let cap2 = d.capture("sh_test_1").unwrap();
        assert_eq!(cap2.rows, 35);
        assert_eq!(cap2.cols, 110);

        // Input by shell_id
        d.shell_input("sh_test_1", b"echo hello\n").unwrap();
        d.write_input("sh_test_1", b"echo world\n").unwrap();

        // Attach / detach by shell_id
        let (tx, _rx) = reply_channel(None);
        d.register_sink(10, tx);
        let screen = d.shell_attach(10, "sh_test_1").unwrap();
        assert_eq!(screen.rows, 35);
        assert_eq!(screen.cols, 110);

        d.shell_detach(10, "sh_test_1");

        d.shutdown();
    }

    #[test]
    fn attach_delivers_screen_snapshot_before_subsequent_output() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let sock = tmp_socket("att_fifo");
        let mut server = DaemonServer::start(&sock).unwrap();
        std::thread::sleep(Duration::from_millis(150));

        let d = server.daemon();
        d.spawn(SpawnRequest {
            instance: "fifo_inst".into(),
            argv: vec![
                sh.clone(),
                "-c".into(),
                "echo INITIAL_LINE; sleep 0.2; echo SUBSEQUENT_LINE; while :; do sleep 1; done".into(),
            ],
            cwd: None,
            env: vec![],
            detect: None,
            rows: 25,
            cols: 80,
            display_name: None,
            ..Default::default()
        })
        .unwrap();

        // Wait until initial output is reflected in capture
        let start = std::time::Instant::now();
        while start.elapsed() < Duration::from_secs(3) {
            if let Some(snap) = d.capture("fifo_inst") {
                if snap.lines.iter().any(|l| l.contains("INITIAL_LINE")) {
                    break;
                }
            }
            std::thread::sleep(Duration::from_millis(50));
        }

        let mut c = UnixStream::connect(&sock).unwrap();
        c.set_read_timeout(Some(Duration::from_millis(500))).ok();
        dproto::write_ctl_msg(&mut c, &CtlMsg::Attach { instance: "fifo_inst".into() }).unwrap();

        // The very FIRST reply frame MUST be CtlReply::Screen
        let first_reply = match dproto::read_ctl_reply(&mut c) {
            Ok(Some(r)) => r,
            other => panic!("expected reply, got {other:?}"),
        };
        match first_reply {
            CtlReply::Screen { instance, screen } => {
                assert_eq!(instance, "fifo_inst");
                assert!(screen.lines.iter().any(|l| l.contains("INITIAL_LINE")), "initial snapshot missing INITIAL_LINE");
            }
            other => panic!("first frame must be CtlReply::Screen, got {other:?}"),
        }

        // The second reply frame immediately following Screen MUST be CtlReply::StreamReady (REQ-STREAM-EVENT-2)
        let second_reply = match dproto::read_ctl_reply(&mut c) {
            Ok(Some(r)) => r,
            other => panic!("expected StreamReady reply, got {other:?}"),
        };
        match second_reply {
            CtlReply::StreamReady { instance } => {
                assert_eq!(instance, "fifo_inst");
            }
            other => panic!("second frame must be CtlReply::StreamReady, got {other:?}"),
        }

        // Subsequent frames should be Output containing SUBSEQUENT_LINE
        let mut saw_subsequent = false;
        let start = std::time::Instant::now();
        while start.elapsed() < Duration::from_secs(4) {
            match dproto::read_ctl_reply(&mut c) {
                Ok(Some(CtlReply::Output { instance, data })) => {
                    assert_eq!(instance, "fifo_inst");
                    if String::from_utf8_lossy(&data).contains("SUBSEQUENT_LINE") {
                        saw_subsequent = true;
                        break;
                    }
                }
                Ok(Some(_)) => {}
                Ok(None) => break,
                Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock || e.kind() == std::io::ErrorKind::TimedOut => {}
                Err(_) => break,
            }
        }
        assert!(saw_subsequent, "never received subsequent output after screen snapshot");
        server.shutdown();
    }

    #[test]
    fn test_stream_lifecycle_events_ready_and_closed() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let sock = tmp_socket("lifecycle_events");
        let mut server = DaemonServer::start(&sock).unwrap();
        std::thread::sleep(Duration::from_millis(150));

        let d = server.daemon();
        d.spawn(SpawnRequest {
            instance: "lifecycle_exit".into(),
            argv: vec![sh.clone(), "-c".into(), "sleep 0.15; echo lifecycle_ok; exit 0".into()],
            cwd: None,
            env: vec![],
            detect: None,
            rows: 24,
            cols: 80,
            display_name: None,
            ..Default::default()
        })
        .unwrap();

        let mut c = UnixStream::connect(&sock).unwrap();
        c.set_read_timeout(Some(Duration::from_millis(500))).ok();
        dproto::write_ctl_msg(&mut c, &CtlMsg::Attach { instance: "lifecycle_exit".into() }).unwrap();

        // 1. Initial Screen snapshot
        let frame1 = dproto::read_ctl_reply(&mut c).unwrap().expect("expected Screen reply");
        assert!(matches!(frame1, CtlReply::Screen { ref instance, .. } if instance == "lifecycle_exit"));

        // 2. StreamReady immediately following Screen
        let frame2 = dproto::read_ctl_reply(&mut c).unwrap().expect("expected StreamReady reply");
        match frame2 {
            CtlReply::StreamReady { instance } => assert_eq!(instance, "lifecycle_exit"),
            other => panic!("expected StreamReady, got {other:?}"),
        }

        // 3. Child exits with code 0 -> StreamClosed received with code Some(0)
        let closed = await_reply(
            &mut c,
            |r| matches!(r, CtlReply::StreamClosed { instance, code } if instance == "lifecycle_exit" && code == &Some(0)),
            Duration::from_secs(5),
        );
        assert!(closed.is_some(), "never received StreamClosed with exit code 0 on child exit");

        // 4. Test explicit close teardown sends StreamClosed with None
        d.spawn(SpawnRequest {
            instance: "lifecycle_teardown".into(),
            argv: vec![sh.clone(), "-c".into(), "sleep 60".into()],
            cwd: None,
            env: vec![],
            detect: None,
            rows: 24,
            cols: 80,
            display_name: None,
            ..Default::default()
        })
        .unwrap();

        let mut c2 = UnixStream::connect(&sock).unwrap();
        c2.set_read_timeout(Some(Duration::from_millis(500))).ok();
        dproto::write_ctl_msg(&mut c2, &CtlMsg::Attach { instance: "lifecycle_teardown".into() }).unwrap();

        let f1 = dproto::read_ctl_reply(&mut c2).unwrap().expect("expected Screen");
        assert!(matches!(f1, CtlReply::Screen { .. }));
        let f2 = dproto::read_ctl_reply(&mut c2).unwrap().expect("expected StreamReady");
        assert!(matches!(f2, CtlReply::StreamReady { .. }));

        // Explicit close
        d.close("lifecycle_teardown").unwrap();

        let teardown_closed = await_reply(
            &mut c2,
            |r| matches!(r, CtlReply::StreamClosed { instance, code } if instance == "lifecycle_teardown" && code == &None),
            Duration::from_secs(3),
        );
        assert!(teardown_closed.is_some(), "never received StreamClosed with None on explicit close");

        server.shutdown();
    }

    #[test]
    fn broken_socket_writer_auto_unsubscribes_and_resizes() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let sock = tmp_socket("broken_sock");
        let mut server = DaemonServer::start(&sock).unwrap();
        std::thread::sleep(Duration::from_millis(150));

        let d = server.daemon();
        d.spawn(SpawnRequest {
            instance: "inst_pipe".into(),
            argv: vec![
                sh.clone(),
                "-c".into(),
                "while :; do echo flood; sleep 0.05; done".into(),
            ],
            cwd: None,
            env: vec![],
            detect: None,
            rows: 30,
            cols: 100,
            display_name: None,
            ..Default::default()
        })
        .unwrap();

        // Connect, attach, and resize
        {
            let mut c = UnixStream::connect(&sock).unwrap();
            dproto::write_ctl_msg(&mut c, &CtlMsg::Attach { instance: "inst_pipe".into() }).unwrap();
            dproto::write_ctl_msg(&mut c, &CtlMsg::Resize { instance: "inst_pipe".into(), rows: 40, cols: 120 }).unwrap();
            // Wait for initial screen
            let _ = dproto::read_ctl_reply(&mut c);
            assert_eq!(d.capture("inst_pipe").unwrap().rows, 40);
            // Drop client stream abruptly (simulating broken pipe/disconnect)
        }

        // Once the broken socket write fails, the writer thread auto-unsubscribes and resizes back to CRT (80x25)
        let mut resized_back = false;
        let start = std::time::Instant::now();
        while start.elapsed() < Duration::from_secs(5) {
            if let Some(snap) = d.capture("inst_pipe") {
                if snap.rows == CRT_ROWS && snap.cols == CRT_COLS {
                    resized_back = true;
                    break;
                }
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        assert!(resized_back, "instance was not auto-resized back to CRT after client drop");
        server.shutdown();
    }

    #[test]
    fn test_streaming_attach_resize_auto_enter_investigation() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let sock = tmp_socket("investigate_ae");
        let mut server = DaemonServer::start(&sock).unwrap();
        std::thread::sleep(Duration::from_millis(150));

        let mut conn_events = UnixStream::connect(&sock).unwrap();
        dproto::write_ctl_msg(&mut conn_events, &CtlMsg::WatchEvents).unwrap();

        let prompt = "Please confirm: Do you trust the authors of this repository and want to proceed? [Yes/no]";
        let detect = format!(
            r#"{{
                "enabled": true,
                "startup_probe_seconds": 10,
                "capture_interval_ms": 100,
                "auto_enter_patterns": ["{}"],
                "auto_enter_pre_keys": [""]
            }}"#,
            prompt
        );

        dproto::write_ctl_msg(
            &mut conn_events,
            &CtlMsg::Spawn(SpawnRequest {
                instance: "inv_ae".into(),
                argv: vec![
                    sh.clone(),
                    "-c".into(),
                    format!("sleep 0.1; echo '{}'; read -r line; echo \"DISMISSED:$line\"; while :; do sleep 1; done", prompt),
                ],
                cwd: None,
                env: vec![],
                detect: Some(detect),
                rows: 25,
                cols: 80,
                display_name: None,
                ..Default::default()
            }),
        )
        .unwrap();

        assert!(await_reply(&mut conn_events, |r| matches!(r, CtlReply::Spawned { .. }), Duration::from_secs(3)).is_some());

        // Connect dedicated streaming worker socket
        let mut conn_stream = UnixStream::connect(&sock).unwrap();
        dproto::write_ctl_msg(&mut conn_stream, &CtlMsg::Attach { instance: "inv_ae".into() }).unwrap();
        let _ = dproto::read_ctl_reply(&mut conn_stream);

        // Wait for prompt to print and wrap at 80 cols FIRST
        std::thread::sleep(Duration::from_millis(250));

        // Immediate resize from UI: 120 cols from UI!
        dproto::write_ctl_msg(&mut conn_stream, &CtlMsg::Resize {
            instance: "inv_ae".into(),
            rows: 30,
            cols: 120,
        }).unwrap();

        let mut dismissed = false;
        let start = std::time::Instant::now();
        while start.elapsed() < Duration::from_secs(6) {
            dproto::write_ctl_msg(&mut conn_stream, &CtlMsg::Capture { instance: "inv_ae".into() }).unwrap();
            if let Some(CtlReply::Screen { screen, .. }) = await_reply(
                &mut conn_stream,
                |r| matches!(r, CtlReply::Screen { .. }),
                Duration::from_millis(300),
            ) {
                let full = screen.lines.join("\n");
                eprintln!("[TEST DEBUG] Screen full text:\n{}", full);
                if full.contains("DISMISSED") {
                    dismissed = true;
                    break;
                }
            }
        }
        assert!(dismissed, "Auto-enter failed to dismiss prompt under streaming attach + resize");
        server.shutdown();
    }

    #[test]
    fn test_streaming_attach_resize_startup_blocked() {
        require_pty!();
        let sh = match shell() {
            Some(s) => s,
            None => return,
        };
        let sock = tmp_socket("investigate_blocked");
        let mut server = DaemonServer::start(&sock).unwrap();
        std::thread::sleep(Duration::from_millis(150));

        let mut conn_events = UnixStream::connect(&sock).unwrap();
        dproto::write_ctl_msg(&mut conn_events, &CtlMsg::WatchEvents).unwrap();

        let prompt = "Please authenticate: Provider interactive authentication is required before starting. [Sign in]";
        let detect = format!(
            r#"{{
                "enabled": true,
                "startup_probe_seconds": 10,
                "capture_interval_ms": 100,
                "blocked_patterns": ["{}"],
                "sanitized_reason_mapping": ["auth=Provider authentication required"]
            }}"#,
            prompt
        );

        dproto::write_ctl_msg(
            &mut conn_events,
            &CtlMsg::Spawn(SpawnRequest {
                instance: "inv_block".into(),
                argv: vec![
                    sh.clone(),
                    "-c".into(),
                    format!("sleep 0.1; echo '{}'; while :; do sleep 1; done", prompt),
                ],
                cwd: None,
                env: vec![],
                detect: Some(detect),
                rows: 25,
                cols: 80,
                display_name: None,
                ..Default::default()
            }),
        )
        .unwrap();

        assert!(await_reply(&mut conn_events, |r| matches!(r, CtlReply::Spawned { .. }), Duration::from_secs(3)).is_some());

        // Connect dedicated streaming worker socket
        let mut conn_stream = UnixStream::connect(&sock).unwrap();
        dproto::write_ctl_msg(&mut conn_stream, &CtlMsg::Attach { instance: "inv_block".into() }).unwrap();
        let _ = dproto::read_ctl_reply(&mut conn_stream);

        // Wait for prompt to print and wrap at 80 cols FIRST
        std::thread::sleep(Duration::from_millis(250));

        // Immediate resize from UI: 120 cols
        dproto::write_ctl_msg(&mut conn_stream, &CtlMsg::Resize {
            instance: "inv_block".into(),
            rows: 30,
            cols: 120,
        }).unwrap();

        // Await StartupBlocked on WatchEvents connection
        let reply = await_reply(
            &mut conn_events,
            |r| matches!(r, CtlReply::StartupBlocked { .. }),
            Duration::from_secs(5),
        );

        match reply {
            Some(CtlReply::StartupBlocked { instance, reason_code, safe_diagnostic }) => {
                assert_eq!(instance, "inv_block");
                assert_eq!(reason_code, "blocked_0Please_authenticate_Provider_interactive_authentication_is_required_before_starting_Sign_in");
                assert_eq!(safe_diagnostic, "Provider authentication required");
            }
            other => panic!("expected StartupBlocked on WatchEvents, got {other:?}"),
        }

        server.shutdown();
    }

    // ---- REQ-PTY-1/2/3: fd lifecycle, socket ownership, fd exhaustion ----

    /// Env var naming the `child_*` scenario a re-executed test binary runs.
    const CHILD_SCENARIO_ENV: &str = "HAM_PTY_HOST_TEST_CHILD";

    /// Run the `#[ignore]`d test `name` in a fresh copy of this test binary.
    /// Scenarios that count or exhaust the process's fds need a process of
    /// their own: other tests running in parallel here open PTYs too.
    fn run_child_scenario(name: &str) {
        let out = std::process::Command::new(std::env::current_exe().unwrap())
            .args([&format!("daemon::tests::{name}"), "--exact", "--ignored", "--nocapture", "--test-threads=1"])
            .env(CHILD_SCENARIO_ENV, name)
            .output()
            .unwrap();
        let text = format!(
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        assert!(
            out.status.success() && text.contains("1 passed"),
            "child scenario {name} failed:\n{text}"
        );
    }

    /// True when this process is the re-executed child for scenario `name`.
    fn is_child_scenario(name: &str) -> bool {
        std::env::var(CHILD_SCENARIO_ENV).as_deref() == Ok(name)
    }

    fn true_spec(instance: &str, prog: &str) -> SpawnRequest {
        SpawnRequest { argv: vec![prog.into()], ..sh_spec(instance, prog) }
    }

    /// This process's open fds that are PTY masters.
    fn ptmx_fds() -> usize {
        std::fs::read_dir("/proc/self/fd")
            .unwrap()
            .filter_map(|e| std::fs::read_link(e.ok()?.path()).ok())
            .filter(|t| t.to_str().is_some_and(|t| t.ends_with("ptmx")))
            .count()
    }

    fn ping(sock: &std::path::Path) -> bool {
        let Ok(mut c) = UnixStream::connect(sock) else { return false };
        if dproto::write_ctl_msg(&mut c, &CtlMsg::Ping).is_err() {
            return false;
        }
        await_reply(&mut c, |r| matches!(r, CtlReply::Pong), Duration::from_secs(2)).is_some()
    }

    /// Open /dev/null until the fd table is full; the caller drops some to
    /// leave an exact number free.
    #[cfg(unix)]
    fn fill_fd_table() -> Vec<std::fs::File> {
        let mut fill = Vec::new();
        loop {
            match std::fs::File::open("/dev/null") {
                Ok(f) => fill.push(f),
                Err(e) => {
                    assert_eq!(e.raw_os_error(), Some(libc::EMFILE), "unexpected open error {e}");
                    return fill;
                }
            }
        }
    }

    #[test]
    fn finished_runs_release_their_ptys() {
        require_pty!();
        run_child_scenario("child_finished_runs_release_their_ptys");
    }

    #[test]
    #[ignore = "run in a fresh process by finished_runs_release_their_ptys"]
    fn child_finished_runs_release_their_ptys() {
        if !is_child_scenario("child_finished_runs_release_their_ptys") {
            return;
        }
        let prog = resolve("true").expect("`true` on PATH");
        let sock = tmp_socket("ptmx");
        let mut server = DaemonServer::start(&sock).unwrap();
        let d = server.daemon().clone();
        let before = ptmx_fds();

        for i in 0..50 {
            d.spawn(true_spec(&format!("run{i}"), &prog)).unwrap();
        }
        assert!(
            wait_for(|| d.list().iter().all(|a| !a.alive), Duration::from_secs(30)),
            "runs did not finish"
        );
        let released = wait_for(|| ptmx_fds() <= before + 2, Duration::from_secs(10));
        assert!(released, "ptmx fds before={before} after 50 finished runs={}", ptmx_fds());
        // The finished runs are still listed (as tombstones), just without fds.
        assert_eq!(d.list().len(), 50);
        server.shutdown();
    }

    #[test]
    fn second_daemon_cannot_take_over_a_live_socket() {
        require_pty!();
        let sh = shell().expect("a POSIX shell");
        let sock = tmp_socket("owner");
        let mut first = DaemonServer::start(&sock).unwrap();
        first.daemon().spawn(sh_spec("owned", &sh)).unwrap();

        let err = DaemonServer::start(&sock).err().expect("second daemon must not start");
        assert!(format!("{err:#}").contains("another ham-pty-host daemon owns"), "{err:#}");

        // The socket still reaches the FIRST daemon: it answers and lists its agent.
        assert!(ping(&sock), "first daemon stopped answering ping");
        let mut c = UnixStream::connect(&sock).unwrap();
        dproto::write_ctl_msg(&mut c, &CtlMsg::List).unwrap();
        let list = await_reply(&mut c, |r| matches!(r, CtlReply::AgentList(_)), Duration::from_secs(2));
        match list {
            Some(CtlReply::AgentList(l)) => assert!(find(&l, "owned").is_some(), "{l:?}"),
            other => panic!("expected AgentList, got {other:?}"),
        }
        first.shutdown();
    }

    #[test]
    fn daemon_start_refuses_a_lockless_live_listener_but_replaces_a_stale_socket() {
        // A daemon from before the lock existed holds no flock: the connect
        // probe must still protect its socket.
        let sock = tmp_socket("legacy");
        let legacy = UnixListener::bind(&sock).unwrap();
        let err = DaemonServer::start(&sock).err().expect("must not replace a live listener");
        assert!(format!("{err:#}").contains("accepting connections"), "{err:#}");
        assert!(sock.exists());

        // Once nothing listens, the leftover socket file is stale and replaced.
        drop(legacy);
        let mut server = DaemonServer::start(&sock).expect("stale socket is replaced");
        assert!(ping(&sock));
        server.shutdown();
    }

    #[cfg(unix)]
    #[test]
    fn daemon_keeps_serving_after_fd_exhaustion() {
        require_pty!();
        run_child_scenario("child_daemon_keeps_serving_after_fd_exhaustion");
    }

    #[cfg(unix)]
    #[test]
    #[ignore = "run in a fresh process by daemon_keeps_serving_after_fd_exhaustion"]
    fn child_daemon_keeps_serving_after_fd_exhaustion() {
        if !is_child_scenario("child_daemon_keeps_serving_after_fd_exhaustion") {
            return;
        }
        let prog = resolve("true").expect("`true` on PATH");
        let sock = tmp_socket("emfile");
        let mut server = DaemonServer::start(&sock).unwrap();
        // A small fd table keeps filling it fast.
        let mut lim = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
        assert_eq!(unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut lim) }, 0);
        lim.rlim_cur = lim.rlim_cur.min(256);
        assert_eq!(unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &lim) }, 0);
        assert!(ping(&sock));

        // A client connects while only `free` fds are left; it takes one, so
        // the daemon's accept + two try_clones get `free - 1`. Every split
        // (accept fails / a clone fails / all succeed) must leave it serving.
        for free in 1..=4 {
            let mut fill = fill_fd_table();
            fill.truncate(fill.len() - free);
            let client = UnixStream::connect(&sock);
            std::thread::sleep(Duration::from_millis(300));
            drop(client);
            drop(fill);
            assert!(
                wait_for(|| ping(&sock), Duration::from_secs(3)),
                "daemon stopped serving after a client arrived with {free} fd(s) free"
            );
        }

        // A spawn that fails for lack of fds reports the OS error to the caller.
        let mut c = UnixStream::connect(&sock).unwrap();
        let fill = fill_fd_table();
        dproto::write_ctl_msg(&mut c, &CtlMsg::Spawn(true_spec("starved", &prog))).unwrap();
        let reply = await_reply(&mut c, |r| matches!(r, CtlReply::Error { .. }), Duration::from_secs(3));
        drop(fill);
        match reply {
            Some(CtlReply::Error { message, .. }) => {
                assert!(message.contains("Too many open files"), "spawn error lacks the OS error: {message}")
            }
            other => panic!("expected spawn Error, got {other:?}"),
        }
        assert!(ping(&sock));
        server.shutdown();
    }

    #[test]
    fn finished_session_is_a_tombstone_for_list_capture_and_signal() {
        require_pty!();
        let prog = resolve("true").expect("`true` on PATH");
        let sock = tmp_socket("tomb");
        let mut server = DaemonServer::start(&sock).unwrap();
        let d = server.daemon().clone();
        d.spawn(true_spec("done", &prog)).unwrap();
        let tombstoned = || {
            d.agents.lock().unwrap().get("done").is_some_and(|a| a.exited_at.load(Ordering::SeqCst) != 0)
        };
        assert!(wait_for(tombstoned, Duration::from_secs(5)), "run never became a tombstone");
        assert!(d.agents.lock().unwrap()["done"].host.lock().unwrap().pty_released());

        let info = find(&d.list(), "done").expect("tombstone is listed");
        assert!(!info.alive);
        assert_eq!(info.exit_code, Some(0));
        assert!(d.capture("done").is_some(), "tombstone still answers capture");
        assert!(d.write_input("done", b"x").is_err());
        assert_eq!(d.signal("done", 15).unwrap(), SignalOutcome::AlreadyExited(0));

        // Over the wire the refused signal is a distinct, parseable reply.
        let mut c = UnixStream::connect(&sock).unwrap();
        dproto::write_ctl_msg(&mut c, &CtlMsg::Signal(SignalRequest { shell_id: "done".into(), signal: 15 })).unwrap();
        let reply = await_reply(&mut c, |r| r.shell_id() == Some("done"), Duration::from_secs(2));
        assert_eq!(reply, Some(CtlReply::AlreadyExited { instance: "done".into(), code: 0 }));

        // close still clears a tombstone.
        d.close("done").unwrap();
        assert!(find(&d.list(), "done").is_none());
        server.shutdown();
    }

    #[test]
    fn tombstones_are_bounded_by_count_and_age() {
        require_pty!();
        let prog = resolve("true").expect("`true` on PATH");
        let sh = shell().expect("a POSIX shell");
        let d = Daemon::new();
        for id in ["t1", "t2", "t3"] {
            d.spawn(true_spec(id, &prog)).unwrap();
        }
        d.spawn(sh_spec("live", &sh)).unwrap();
        let all_tombstoned = || {
            let agents = d.agents.lock().unwrap();
            ["t1", "t2", "t3"].iter().all(|id| agents[*id].exited_at.load(Ordering::SeqCst) != 0)
        };
        assert!(wait_for(all_tombstoned, Duration::from_secs(5)));

        let now = now_millis();
        let mut agents = d.agents.lock().unwrap();
        for (id, age_ms) in [("t1", 3), ("t2", 2), ("t3", 1)] {
            agents[id].exited_at.store(now - age_ms, Ordering::SeqCst);
        }
        prune_tombstones(&mut agents, 1, TOMBSTONE_TTL);
        let mut left: Vec<&String> = agents.keys().collect();
        left.sort();
        assert_eq!(left, ["live", "t3"], "count bound keeps the newest tombstone and every live agent");

        agents["t3"].exited_at.store(now - 2 * 60 * 60 * 1000, Ordering::SeqCst);
        prune_tombstones(&mut agents, TOMBSTONE_MAX, TOMBSTONE_TTL);
        assert_eq!(agents.keys().collect::<Vec<_>>(), ["live"], "age bound expires old tombstones");
        drop(agents);
        d.shutdown();
    }
}
