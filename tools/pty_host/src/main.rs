//! ham-pty-host CLI entrypoint.
//!
//! `--socket` is a single command-level (global) flag shared by every
//! subcommand; the canonical form places it BEFORE the subcommand:
//!
//!     ham-pty-host --socket <path> <subcommand> [--sub-options]
//!
//! It is also `global`, so the legacy `ham-pty-host <subcommand> --socket <path>`
//! form still works. When omitted it defaults to the main bridge's socket.
//!
//! Subcommands:
//!   * `run`    — spawn a program under a PTY + host it on a unix socket (PTYH-1/2).
//!   * `attach` — attach to a running host, raw-mode passthrough (PTYH-2).
//!   * `daemon` — run the multi-agent per-machine daemon (HOST-1).
//!   * `spawn`/`close`/`restart`/`list` — control-plane clients for the daemon (HOST-1).
//!   * `capture` — one-shot rendered screen snapshot of an agent (HOST-1/2).
//!   * `stop`   — stop a running daemon: terminate all agents and exit (HOST-1).
//!
//! `attach --debug` renders the in-app ratatui debug TUI (PTYH-3).

use ham_pty_host::ipc::UnixStream;

use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};

use ham_pty_host::client::{attach, AttachOutcome};
use ham_pty_host::daemon;
use ham_pty_host::dproto::{self, CtlMsg, CtlReply, SpawnRequest};
use ham_pty_host::server::HostServer;
use ham_pty_host::SpawnConfig;

#[derive(Parser)]
#[command(
    name = "ham-pty-host",
    about = "PTY host + attach/detach + debug TUI spike (PTYH-1..5)"
)]
struct Cli {
    /// Unix socket path of the host/daemon. This is a command-level flag: pass it
    /// BEFORE the subcommand, e.g. `ham-pty-host --socket <path> attach`. It is
    /// also `global`, so it still works after the subcommand for back-compat.
    /// Defaults to the main bridge's socket (see `default_socket`); override with
    /// --socket or HAM_LOCAL_RUN_DIR / HAM_LOCAL_ENDPOINT_PORT / HAM_DAEMON_ID.
    #[arg(long, global = true, default_value_t = default_socket())]
    socket: String,

    #[command(subcommand)]
    command: Command,
}

/// Default daemon socket path, mirroring how the bridge derives it
/// (`pty_host_socket_path` / `pty_host_bridge_identity` in
/// `src/bridge/pty_host_client.odin`):
///
///     <local_run_dir>/pty-host.sock when a directory component is <identity>;
///     otherwise <local_run_dir>/pty-host-<identity>.sock
///     identity = daemon_id (if set & != "local-daemon")
///              | port-<local_endpoint_port>
///              | default
///
/// With no overrides this resolves to the configured main bridge's socket
/// (run_dir=/tmp/heimdall-bridge-local, local_endpoint_port=49334):
///
///     /tmp/heimdall-bridge-local/pty-host-port-49334.sock
///
/// Generated paths over 103 bytes use /tmp/heimdall-<uid>/<path-hash>.sock.
///
/// On Windows the default run_dir is %LOCALAPPDATA%\heimdall\run (else
/// %TEMP%\heimdall\run), which also holds the hashed fallback paths.
///
/// Env overrides (match the bridge's `--local-run-dir` / `--local-endpoint-port`
/// / `--daemon-id`): HAM_LOCAL_RUN_DIR, HAM_LOCAL_ENDPOINT_PORT, HAM_DAEMON_ID.
fn default_socket() -> String {
    let run_dir = std::env::var("HAM_LOCAL_RUN_DIR")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(default_run_dir);
    let run_dir = run_dir.trim_end_matches(SEPARATORS);

    let daemon_id = std::env::var("HAM_DAEMON_ID")
        .ok()
        .map(|s| s.trim().to_string())
        .unwrap_or_default();
    let port = std::env::var("HAM_LOCAL_ENDPOINT_PORT")
        .ok()
        .and_then(|s| s.trim().parse::<u16>().ok())
        .unwrap_or(49334);

    let identity = if !daemon_id.is_empty() && daemon_id != "local-daemon" {
        // bridge_runtime_safe_part: keep [A-Za-z0-9_-@.], others -> '_'.
        daemon_id
            .chars()
            .map(|c| match c {
                'a'..='z' | 'A'..='Z' | '0'..='9' | '_' | '-' | '@' | '.' => c,
                _ => '_',
            })
            .collect::<String>()
    } else if port != 0 {
        format!("port-{port}")
    } else {
        "default".to_string()
    };

    let sep = std::path::MAIN_SEPARATOR;
    let path = if run_dir.split(SEPARATORS).any(|part| part == identity) {
        format!("{run_dir}{sep}pty-host.sock")
    } else {
        format!("{run_dir}{sep}pty-host-{identity}.sock")
    };
    ham_pty_host::socket_path::bounded_default(&path)
}

/// Path separators accepted in HAM_LOCAL_RUN_DIR.
#[cfg(unix)]
const SEPARATORS: &[char] = &['/'];
#[cfg(windows)]
const SEPARATORS: &[char] = &['/', '\\'];

#[cfg(unix)]
fn default_run_dir() -> String {
    "/tmp/heimdall-bridge-local".to_string()
}

#[cfg(windows)]
fn default_run_dir() -> String {
    ham_pty_host::socket_path::fallback_dir()
}

#[derive(Subcommand)]
enum Command {
    /// Spawn a program under a PTY and host it on a unix socket.
    Run {
        /// Terminal rows.
        #[arg(long, default_value_t = 24)]
        rows: u16,
        /// Terminal cols.
        #[arg(long, default_value_t = 80)]
        cols: u16,
        /// Disable login-shell (`-l`) behavior for shells.
        #[arg(long)]
        no_login: bool,
        /// Program to run, followed by its arguments.
        #[arg(required = true, trailing_var_arg = true)]
        argv: Vec<String>,
    },
    /// Attach to a running host/daemon over its unix socket.
    ///
    /// Modes:
    ///   * `--socket <daemon>` (no `--instance`, no `--debug`) -> HOST-3 multi
    ///     agent DASHBOARD: agent sidebar + selected agent's live pane.
    ///   * `--socket <host> --debug` -> PTYH-3 single-host split debug TUI.
    ///   * otherwise -> PTYH-2 raw passthrough against a single host.
    Attach {
        /// Render the in-app split-screen debug TUI (single-host, PTYH-3).
        #[arg(long)]
        debug: bool,
        /// Attach to a specific daemon agent by instance id (HOST-4). Absent =>
        /// the multi-agent dashboard (HOST-3).
        #[arg(long)]
        instance: Option<String>,
    },
    /// Run the multi-agent per-machine daemon (HOST-1). Manages N agents keyed
    /// by instance id; clients drive it with spawn/close/restart/list.
    Daemon {},
    /// Register + launch an agent on a running daemon (HOST-1).
    Spawn {
        /// Agent-instance id (registry key).
        #[arg(long)]
        instance: String,
        /// Working directory for the child.
        #[arg(long)]
        cwd: Option<String>,
        /// Extra env var(s), repeatable: --env KEY=VALUE.
        #[arg(long = "env", value_name = "KEY=VALUE")]
        env: Vec<String>,
        /// Startup-detection config as JSON (stored verbatim; parsed in HOST-2).
        #[arg(long)]
        detect: Option<String>,
        /// Maximum child lifetime in seconds. Omit for no timeout.
        #[arg(long, value_parser = clap::value_parser!(u64).range(1..))]
        timeout_seconds: Option<u64>,
        /// Human-readable agent display name.
        #[arg(long)]
        display_name: Option<String>,
        #[arg(long, default_value_t = 24)]
        rows: u16,
        #[arg(long, default_value_t = 80)]
        cols: u16,
        /// Program to run, followed by its arguments.
        #[arg(required = true, trailing_var_arg = true)]
        argv: Vec<String>,
    },
    /// Close (SIGTERM->SIGKILL) + unregister an agent on the daemon (HOST-1).
    Close {
        #[arg(long)]
        instance: String,
    },
    /// Restart an agent from its remembered spec (HOST-1).
    Restart {
        #[arg(long)]
        instance: String,
    },
    /// List all agents registered on the daemon (HOST-1).
    List {},
    /// Capture a one-shot rendered screen snapshot of an agent (HOST-1/2).
    ///
    /// Prints the current VT grid (what the pane looks like now), not the raw
    /// output stream. This is a control-only op: it does not attach, so it never
    /// affects the child or the event stream.
    Capture {
        #[arg(long)]
        instance: String,
        /// Emit the snapshot as JSON (rows/cols/cursor + lines) instead of the
        /// plain rendered text.
        #[arg(long)]
        json: bool,
    },
    /// Stop a running daemon/host: terminate all its agents and exit the daemon
    /// process (HOST-1).
    Stop {},
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    // `--socket` is a single command-level (global) flag shared by every
    // subcommand, so it is resolved once here rather than per-variant.
    let socket = cli.socket;
    ham_pty_host::socket_path::validate(std::path::Path::new(&socket))?;
    match cli.command {
        Command::Run {
            rows,
            cols,
            no_login,
            argv,
        } => run(socket, rows, cols, !no_login, argv),
        Command::Attach { debug, instance } => run_attach(socket, debug, instance),
        Command::Daemon {} => daemon::serve(socket),
        Command::Spawn {
            instance,
            cwd,
            env,
            detect,
            timeout_seconds,
            display_name,
            rows,
            cols,
            argv,
        } => ctl_spawn(
            socket,
            instance,
            cwd,
            env,
            detect,
            timeout_seconds,
            display_name,
            rows,
            cols,
            argv,
        ),
        Command::Close { instance } => ctl_close(socket, instance),
        Command::Restart { instance } => ctl_restart(socket, instance),
        Command::List {} => ctl_list(socket),
        Command::Capture { instance, json } => ctl_capture(socket, instance, json),
        Command::Stop {} => ctl_stop(socket),
    }
}

// ---- daemon control-plane clients (HOST-1) -----------------------------

fn connect(socket: &str) -> Result<UnixStream> {
    UnixStream::connect(socket)
        .with_context(|| format!("connect to daemon socket {socket} (is `daemon` running?)"))
}

/// Send one control message + await the next reply frame.
fn request(socket: &str, msg: &CtlMsg) -> Result<CtlReply> {
    let mut stream = connect(socket)?;
    dproto::write_ctl_msg(&mut stream, msg).context("send control msg")?;
    stream
        .set_read_timeout(Some(std::time::Duration::from_secs(10)))
        .ok();
    // Skip async Output/ChildExited frames; wait for a control reply.
    loop {
        match dproto::read_ctl_reply(&mut stream)? {
            Some(CtlReply::Output { .. }) | Some(CtlReply::ChildExited { .. }) => continue,
            Some(reply) => return Ok(reply),
            None => bail!("daemon closed the connection without replying"),
        }
    }
}

fn parse_env(pairs: Vec<String>) -> Result<Vec<(String, String)>> {
    pairs
        .into_iter()
        .map(|kv| {
            let (k, v) = kv
                .split_once('=')
                .ok_or_else(|| anyhow::anyhow!("--env expects KEY=VALUE, got {kv:?}"))?;
            Ok((k.to_string(), v.to_string()))
        })
        .collect()
}

#[allow(clippy::too_many_arguments)]
fn ctl_spawn(
    socket: String,
    instance: String,
    cwd: Option<String>,
    env: Vec<String>,
    detect: Option<String>,
    timeout_seconds: Option<u64>,
    display_name: Option<String>,
    rows: u16,
    cols: u16,
    argv: Vec<String>,
) -> Result<()> {
    let req = SpawnRequest {
        instance: instance.clone(),
        argv,
        cwd,
        env: parse_env(env)?,
        detect,
        rows,
        cols,
        display_name,
        kind: None,
        label: None,
        meta: None,
        tee_path: None,
        timeout_seconds,
    };
    match request(&socket, &CtlMsg::Spawn(req))? {
        CtlReply::Spawned { instance, pid } => {
            println!("spawned {instance} (pid {pid})");
            Ok(())
        }
        CtlReply::Error { message, .. } => bail!("spawn failed: {message}"),
        other => bail!("unexpected reply: {other:?}"),
    }
}

fn ctl_close(socket: String, instance: String) -> Result<()> {
    match request(&socket, &CtlMsg::Close { instance })? {
        CtlReply::Closed { instance } => {
            println!("closed {instance}");
            Ok(())
        }
        CtlReply::Error { message, .. } => bail!("close failed: {message}"),
        other => bail!("unexpected reply: {other:?}"),
    }
}

fn ctl_stop(socket: String) -> Result<()> {
    // If the socket file is gone there's nothing to stop; treat that as success
    // so `stop` is idempotent (e.g. re-run after the daemon already exited).
    if !std::path::Path::new(&socket).exists() {
        println!("no daemon at {socket} (already stopped)");
        return Ok(());
    }
    match request(&socket, &CtlMsg::Shutdown) {
        Ok(CtlReply::ShuttingDown) => {
            println!("stopped daemon at {socket}");
            Ok(())
        }
        Ok(CtlReply::Error { message, .. }) => bail!("stop failed: {message}"),
        Ok(other) => bail!("unexpected reply: {other:?}"),
        // The daemon may drop the connection the instant it tears down, so a
        // clean EOF right after we sent Shutdown is an expected success race.
        Err(_) if !std::path::Path::new(&socket).exists() => {
            println!("stopped daemon at {socket}");
            Ok(())
        }
        Err(e) => Err(e),
    }
}

fn ctl_restart(socket: String, instance: String) -> Result<()> {
    match request(&socket, &CtlMsg::Restart { instance })? {
        CtlReply::Restarted { instance, pid } => {
            println!("restarted {instance} (pid {pid})");
            Ok(())
        }
        CtlReply::Error { message, .. } => bail!("restart failed: {message}"),
        other => bail!("unexpected reply: {other:?}"),
    }
}

fn ctl_list(socket: String) -> Result<()> {
    match request(&socket, &CtlMsg::List)? {
        CtlReply::AgentList(agents) => {
            if agents.is_empty() {
                println!("(no agents)");
            }
            for a in agents {
                let state = if a.alive {
                    "alive".to_string()
                } else {
                    format!("exited({})", a.exit_code.unwrap_or(-1))
                };
                let label = a
                    .display_name
                    .as_deref()
                    .map(|d| format!(" ({d})"))
                    .unwrap_or_default();
                println!(
                    "{:<24} pid={:<7} {:<12} {}x{} {}{}",
                    a.instance_id, a.pid, state, a.rows, a.cols, a.program, label
                );
            }
            Ok(())
        }
        other => bail!("unexpected reply: {other:?}"),
    }
}

fn ctl_capture(socket: String, instance: String, json: bool) -> Result<()> {
    match request(&socket, &CtlMsg::Capture { instance: instance.clone() })? {
        CtlReply::Screen { screen, .. } => {
            if json {
                // Hand-rolled JSON (no serde dep): rows/cols/cursor + lines.
                let mut out = String::new();
                out.push_str(&format!(
                    "{{\"instance\":{},\"rows\":{},\"cols\":{},\"cursor_row\":{},\"cursor_col\":{},\"lines\":[",
                    json_str(&instance),
                    screen.rows,
                    screen.cols,
                    screen.cursor_row,
                    screen.cursor_col,
                ));
                for (i, line) in screen.lines.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    out.push_str(&json_str(line));
                }
                out.push_str("]}");
                println!("{out}");
            } else {
                for line in &screen.lines {
                    println!("{line}");
                }
            }
            Ok(())
        }
        CtlReply::Error { message, .. } => bail!("capture failed: {message}"),
        other => bail!("unexpected reply: {other:?}"),
    }
}

/// Minimal JSON string escaper for the `capture --json` output.
fn json_str(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn run(
    socket: String,
    rows: u16,
    cols: u16,
    login: bool,
    argv: Vec<String>,
) -> Result<()> {
    let program = argv[0].clone();
    let args = argv[1..].to_vec();
    let config = SpawnConfig {
        program,
        args,
        rows,
        cols,
        login_shell: login,
        cwd: None,
        extra_env: Vec::new(),
    };
    let mut server = HostServer::start(&socket, config)?;
    eprintln!(
        "[ham-pty-host] listening on {} (attach with: ham-pty-host attach --socket {})",
        socket, socket
    );
    let code = server.wait();
    server.shutdown();
    eprintln!("[ham-pty-host] child exited with code {code}");
    std::process::exit(code);
}

fn run_attach(socket: String, debug: bool, instance: Option<String>) -> Result<()> {
    let path = std::path::PathBuf::from(&socket);
    if !path.exists() {
        bail!("socket {socket} does not exist (is the host/daemon running?)");
    }
    // REQ-PTY-1: no --instance + no --debug => alternate buffer interactive
    // agent selector overlay. Selecting an agent attaches directly in raw
    // passthrough mode; cancelling (Esc or Ctrl-C) exits cleanly with code 0.
    let instance = if instance.is_none() && !debug {
        match ham_pty_host::dclient::select_instance(&path)? {
            Some(inst) => Some(inst),
            None => return Ok(()),
        }
    } else {
        instance
    };
    if debug {
        // PTYH-3: in-app ratatui split-screen debug TUI.
        ham_pty_host::debug_ui::run(&path)?;
        eprintln!("[ham-pty-host] debug TUI exited (child still running unless it exited)");
        return Ok(());
    }
    // HOST-4: --instance => single-agent raw passthrough against the daemon,
    // no sidebar (for tiling one agent per tmux pane). Ctrl-\ detaches.
    let outcome = match &instance {
        Some(id) => ham_pty_host::dclient::attach_instance(&path, id)?,
        None => attach(&path)?,
    };
    match outcome {
        AttachOutcome::Detached => {
            eprintln!("[ham-pty-host] detached (child still running)");
            Ok(())
        }
        AttachOutcome::ChildExited(code) => {
            eprintln!("[ham-pty-host] child exited with code {code}");
            std::process::exit(code);
        }
        AttachOutcome::Disconnected => {
            eprintln!("[ham-pty-host] disconnected from host/agent");
            Ok(())
        }
    }
}
