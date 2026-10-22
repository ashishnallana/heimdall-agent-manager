//! REQ PTYH-1: Host core — spawn a child under a PTY and maintain a live VT
//! screen model from its output.
//!
//! `PtyHost` owns:
//!   * the platform PTY pair (via `portable-pty`),
//!   * the child process,
//!   * a reader thread pumping PTY bytes into a shared `VtEngine`,
//!   * a writer handle for sending input to the child.
//!
//! The screen model is shared behind a `Mutex` so callers (and, in later tasks,
//! socket clients / the TUI) can `capture()` at any time and write input.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use anyhow::{Context, Result};
use portable_pty::{CommandBuilder, NativePtySystem, PtySize, PtySystem};

use crate::vt::{Capture, VtEngine};

/// Environment we hand to the child. We start from a filtered copy of our own
/// env and force interactive-terminal defaults (REQ PTYH-1).
fn build_child_env() -> HashMap<String, String> {
    // Variables that would confuse an interactive child or leak host tooling.
    const DROP: &[&str] = &[
        "TERM",         // we set our own
        "TERM_PROGRAM",
        "TERM_PROGRAM_VERSION",
        "COLUMNS",
        "LINES",
        "TMUX",
        "TMUX_PANE",
        "STY",          // screen
        "NO_COLOR",     // service/automation preference; interactive panes support color
    ];
    let mut env: HashMap<String, String> = std::env::vars()
        .filter(|(k, _)| !DROP.contains(&k.as_str()))
        .collect();
    env.insert("TERM".into(), "xterm-256color".into());
    // Signal to well-behaved programs that they're on a color-capable terminal.
    env.entry("COLORTERM".into()).or_insert_with(|| "truecolor".into());
    env
}

/// Configuration for spawning a child under the host.
#[derive(Clone, Debug)]
pub struct SpawnConfig {
    pub program: String,
    pub args: Vec<String>,
    pub rows: u16,
    pub cols: u16,
    /// If true and the program is a shell, launch it as a login shell.
    pub login_shell: bool,
    pub cwd: Option<String>,
    /// Extra environment variables merged over the filtered base env. Used by
    /// the multi-agent daemon (HOST-1) to inject HEIMDALL_* per instance.
    pub extra_env: Vec<(String, String)>,
}

impl SpawnConfig {
    pub fn new(program: impl Into<String>, args: Vec<String>) -> Self {
        SpawnConfig {
            program: program.into(),
            args,
            rows: 24,
            cols: 80,
            login_shell: true,
            cwd: None,
            extra_env: Vec::new(),
        }
    }
}

/// Handle to a running PTY-hosted child + its live screen model.
pub struct PtyHost {
    engine: Arc<Mutex<VtEngine>>,
    /// PTY master write half and the master itself. Each holds its own
    /// `/dev/ptmx` fd; both become `None` once [`PtyHost::release_pty`] frees
    /// them after the child exits (REQ-PTY-1).
    writer: Arc<Mutex<Option<Box<dyn Write + Send>>>>,
    master: Option<Box<dyn portable_pty::MasterPty + Send>>,
    killer: Arc<Mutex<Box<dyn portable_pty::ChildKiller + Send + Sync>>>,
    child_alive: Arc<AtomicBool>,
    exit_code: Arc<AtomicI32>,
    pid: i32,
    reader_thread: Option<JoinHandle<()>>,
    wait_thread: Option<JoinHandle<()>>,
    /// Broadcast raw PTY output chunks to interested consumers (sockets/TUI).
    output_rx: Option<Receiver<Vec<u8>>>,
    size: (u16, u16),
}

impl PtyHost {
    /// Spawn `config.program` under a fresh PTY.
    pub fn spawn(config: SpawnConfig) -> Result<Self> {
        let pty_system = NativePtySystem::default();
        let pair = pty_system
            .openpty(PtySize {
                rows: config.rows,
                cols: config.cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .context("openpty failed")?;

        let mut cmd = CommandBuilder::new(&config.program);
        // CommandBuilder otherwise inherits even variables removed by our filter.
        cmd.env_clear();
        // Login shell: many shells treat argv[0] starting with '-' as login.
        let is_shellish = config.program.ends_with("sh");
        if config.login_shell && is_shellish && config.args.is_empty() {
            cmd.arg("-l");
        }
        for a in &config.args {
            cmd.arg(a);
        }
        for (k, v) in build_child_env() {
            cmd.env(k, v);
        }
        // Per-instance overrides win over the filtered base env (HOST-1).
        for (k, v) in &config.extra_env {
            cmd.env(k, v);
        }
        if let Some(cwd) = &config.cwd {
            cmd.cwd(cwd);
        }

        let mut child = pair
            .slave
            .spawn_command(cmd)
            .context("failed to spawn child under PTY")?;
        let pid = child.process_id().map(|p| p as i32).unwrap_or(-1);
        let killer = child.clone_killer();
        // Windows: the session's tree lives in a job, killed as one (HOST-1).
        #[cfg(windows)]
        let killer = crate::job::job_killer(&*child, killer);
        // Slave is owned by the child now; drop our handle so EOF propagates.
        drop(pair.slave);

        let engine = Arc::new(Mutex::new(VtEngine::new(
            config.rows as usize,
            config.cols as usize,
        )));
        let writer = pair
            .master
            .take_writer()
            .context("failed to take PTY writer")?;
        let writer = Arc::new(Mutex::new(Some(writer)));
        let mut reader = pair
            .master
            .try_clone_reader()
            .context("failed to clone PTY reader")?;

        let child_alive = Arc::new(AtomicBool::new(true));
        let exit_code = Arc::new(AtomicI32::new(-1));
        let (output_tx, output_rx) = mpsc::sync_channel::<Vec<u8>>(64);

        // Reader thread: pump PTY bytes into the VT engine + broadcast raw bytes.
        // A thread that cannot be created kills the child and fails the spawn
        // rather than panicking the caller (REQ-PTY-3).
        let reader_thread = {
            let engine = Arc::clone(&engine);
            #[cfg(windows)]
            let writer = Arc::clone(&writer);
            std::thread::Builder::new().spawn(move || {
                // ConPTY opens with a cursor-position request (DSR, `ESC[6n`)
                // and holds all output until it is answered.
                #[cfg(windows)]
                let mut dsr_answered = false;
                let mut buf = [0u8; 8192];
                loop {
                    match reader.read(&mut buf) {
                        Ok(0) => break, // EOF: child closed the PTY
                        Ok(n) => {
                            {
                                let mut eng = engine.lock().unwrap();
                                eng.feed(&buf[..n]);
                                #[cfg(windows)]
                                if !dsr_answered && buf[..n].windows(4).any(|w| w == b"\x1b[6n") {
                                    dsr_answered = true;
                                    let cap = eng.capture();
                                    let reply = format!("\x1b[{};{}R", cap.cursor_row + 1, cap.cursor_col + 1);
                                    if let Some(w) = writer.lock().unwrap().as_mut() {
                                        let _ = w.write_all(reply.as_bytes());
                                        let _ = w.flush();
                                    }
                                }
                            }
                            // Best-effort broadcast; ignore if no consumer.
                            if output_tx.send(buf[..n].to_vec()).is_err() { break; }
                        }
                        Err(e) => {
                            if e.kind() == std::io::ErrorKind::Interrupted {
                                continue;
                            }
                            break;
                        }
                    }
                }
            })
        };
        let reader_thread = match reader_thread {
            Ok(t) => t,
            Err(e) => {
                let _ = killer.clone_killer().kill();
                return Err(e).context("failed to start PTY reader thread");
            }
        };

        // Wait thread: reap the child + record its exit status.
        let wait_thread = {
            let child_alive = Arc::clone(&child_alive);
            let exit_code = Arc::clone(&exit_code);
            std::thread::Builder::new().spawn(move || {
                if let Ok(status) = child.wait() {
                    exit_code.store(status.exit_code() as i32, Ordering::SeqCst);
                }
                child_alive.store(false, Ordering::SeqCst);
            })
        };
        let wait_thread = match wait_thread {
            Ok(t) => t,
            Err(e) => {
                let _ = killer.clone_killer().kill();
                return Err(e).context("failed to start child wait thread");
            }
        };

        Ok(PtyHost {
            engine,
            writer,
            master: Some(pair.master),
            killer: Arc::new(Mutex::new(killer)),
            child_alive,
            exit_code,
            pid,
            reader_thread: Some(reader_thread),
            wait_thread: Some(wait_thread),
            output_rx: Some(output_rx),
            size: (config.rows, config.cols),
        })
    }

    /// Send raw bytes to the child's stdin (via the PTY).
    pub fn write_input(&self, bytes: &[u8]) -> Result<()> {
        let mut guard = self.writer.lock().unwrap();
        let w = guard
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("write to PTY failed: session has exited"))?;
        w.write_all(bytes).context("write to PTY failed")?;
        w.flush().ok();
        Ok(())
    }

    /// Startup input keeps byte progress across retries. `Write::write` reports
    /// the bytes accepted before an error, so resuming never retypes a prefix.
    pub fn write_startup_input(&self, bytes: &[u8], written: &mut usize) -> Result<()> {
        let mut guard = self.writer.lock().unwrap();
        let w = guard.as_mut().ok_or_else(|| anyhow::anyhow!("startup input: session has exited"))?;
        write_startup_remaining(w, bytes, written).context("startup input: PTY write failed")
    }

    /// Snapshot the current rendered screen.
    pub fn capture(&self) -> Capture {
        self.engine.lock().unwrap().capture()
    }

    /// Shared engine handle (used by socket server / TUI in later tasks).
    pub fn engine(&self) -> Arc<Mutex<VtEngine>> {
        Arc::clone(&self.engine)
    }

    /// Take the raw-output receiver (single consumer). Later tasks fan this out.
    pub fn take_output_rx(&mut self) -> Option<Receiver<Vec<u8>>> {
        self.output_rx.take()
    }

    /// Resize the PTY window + the VT model together (REQ PTYH-1 winsize).
    /// After [`PtyHost::release_pty`] only the VT model is resized.
    pub fn resize(&mut self, rows: u16, cols: u16) -> Result<()> {
        if let Some(master) = &self.master {
            master
                .resize(PtySize {
                    rows,
                    cols,
                    pixel_width: 0,
                    pixel_height: 0,
                })
                .context("PTY resize failed")?;
        }
        self.engine
            .lock()
            .unwrap()
            .resize(rows as usize, cols as usize);
        self.size = (rows, cols);
        Ok(())
    }

    pub fn size(&self) -> (u16, u16) {
        self.size
    }

    pub fn is_alive(&self) -> bool {
        self.child_alive.load(Ordering::SeqCst)
    }

    /// OS process id of the child (or -1 if unknown).
    pub fn pid(&self) -> i32 {
        self.pid
    }

    /// Send SIGTERM to the child for a graceful shutdown (HOST-1 close path).
    /// Falls back to no-op if the pid is unknown. The hard SIGKILL fallback is
    /// [`PtyHost::kill`]. Windows has no SIGTERM: the session's job is killed.
    pub fn terminate(&self) {
        #[cfg(unix)]
        if self.pid > 0 {
            unsafe {
                libc::kill(self.pid, libc::SIGTERM);
            }
        }
        #[cfg(windows)]
        self.kill();
    }

    /// Windows stand-in for `killpg(pid, signum)` (HOST-1 `Signal`): SIGINT
    /// writes Ctrl-C (0x03) into the ConPTY input; SIGHUP/SIGKILL/SIGTERM kill
    /// the session's job (the whole tree); 0 only probes. Others are refused.
    #[cfg(windows)]
    pub fn signal(&self, signum: u8) -> Result<()> {
        const SIGHUP: u8 = 1;
        const SIGINT: u8 = 2;
        const SIGKILL: u8 = 9;
        const SIGTERM: u8 = 15;
        match signum {
            0 => Ok(()),
            SIGINT => self.write_input(&[0x03]),
            SIGHUP | SIGKILL | SIGTERM => {
                self.killer.lock().unwrap().kill().context("terminate job")
            }
            _ => Err(anyhow::anyhow!("signal {signum} is not supported on Windows")),
        }
    }

    /// Forcibly terminate the child (SIGKILL). Used for host shutdown so the
    /// PTY closes and the reader/fan-out threads can exit. No-op if already
    /// dead. Safe to call from any thread via the shared killer handle.
    pub fn kill(&self) {
        let _ = self.killer.lock().unwrap().kill();
    }

    /// Shared killer handle for shutting the child down from another thread.
    pub fn killer(&self) -> Arc<Mutex<Box<dyn portable_pty::ChildKiller + Send + Sync>>> {
        Arc::clone(&self.killer)
    }

    /// Exit code if the child has exited, else `None`.
    pub fn exit_code(&self) -> Option<i32> {
        if self.is_alive() {
            None
        } else {
            Some(self.exit_code.load(Ordering::SeqCst))
        }
    }

    /// REQ-PTY-1: close this host's PTY master fds once the child has exited.
    ///
    /// The reader thread holds its own fd (closed at EOF), so a straggler that
    /// still has the slave open only keeps that one fd, never these two. Callers
    /// wait for [`PtyHost::reader_done`] first so the child's last output is
    /// already in the VT model. Afterwards `capture` keeps answering from the VT
    /// model while `write_input` errors. No-op while the child is alive;
    /// idempotent.
    pub fn release_pty(&mut self) {
        if self.is_alive() {
            return;
        }
        self.writer.lock().unwrap().take();
        self.master.take();
    }

    /// Whether the reader thread has hit EOF (all child output is consumed).
    pub fn reader_done(&self) -> bool {
        self.reader_thread.as_ref().map_or(true, |t| t.is_finished())
    }

    /// Whether [`PtyHost::release_pty`] has closed the master fds.
    pub fn pty_released(&self) -> bool {
        self.master.is_none()
    }

    pub fn alive_flag(&self) -> Arc<AtomicBool> {
        Arc::clone(&self.child_alive)
    }

    /// Shared exit-code cell (used by the daemon's per-agent exit watcher).
    pub fn exit_code_arc(&self) -> Arc<AtomicI32> {
        Arc::clone(&self.exit_code)
    }

    /// Block until the child exits, then join background threads.
    pub fn wait(&mut self) -> i32 {
        if let Some(t) = self.wait_thread.take() {
            let _ = t.join();
        }
        if let Some(t) = self.reader_thread.take() {
            let _ = t.join();
        }
        self.exit_code.load(Ordering::SeqCst)
    }

    /// Block until the child exits or `timeout` elapses. Returns exit code if it
    /// exited. Used by tests + graceful shutdown.
    pub fn wait_timeout(&self, timeout: std::time::Duration) -> Option<i32> {
        let start = std::time::Instant::now();
        while start.elapsed() < timeout {
            if !self.is_alive() {
                return Some(self.exit_code.load(Ordering::SeqCst));
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        None
    }
}

fn write_startup_remaining<W: std::io::Write + ?Sized>(writer: &mut W, bytes: &[u8], written: &mut usize) -> std::io::Result<()> {
    if *written > bytes.len() {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidInput, "invalid startup input progress"));
    }
    while *written < bytes.len() {
        match writer.write(&bytes[*written..]) {
            Ok(0) => return Err(std::io::ErrorKind::WriteZero.into()),
            Ok(n) => *written += n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    // A failed flush can be retried too, without writing the bytes again.
    writer.flush()
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn startup_input_resumes_partial_write_and_failed_flush() {
        struct Flaky { bytes: Vec<u8>, fail_write: bool, fail_flush: bool }
        impl std::io::Write for Flaky {
            fn write(&mut self, data: &[u8]) -> std::io::Result<usize> {
                if self.bytes.len() == 3 && self.fail_write {
                    self.fail_write = false;
                    return Err(std::io::ErrorKind::BrokenPipe.into());
                }
                let n = if self.bytes.is_empty() { 3.min(data.len()) } else { data.len() };
                self.bytes.extend_from_slice(&data[..n]);
                Ok(n)
            }
            fn flush(&mut self) -> std::io::Result<()> {
                if self.fail_flush {
                    self.fail_flush = false;
                    return Err(std::io::ErrorKind::Interrupted.into());
                }
                Ok(())
            }
        }
        let bytes = b"startup command\r";
        let mut writer = Flaky { bytes: vec![], fail_write: true, fail_flush: true };
        let mut written = 0;
        assert!(write_startup_remaining(&mut writer, bytes, &mut written).is_err());
        assert_eq!(written, 3);
        assert!(write_startup_remaining(&mut writer, bytes, &mut written).is_err());
        assert_eq!(written, bytes.len());
        write_startup_remaining(&mut writer, bytes, &mut written).unwrap();
        assert_eq!(writer.bytes, bytes, "retry must never retype an accepted prefix");
    }

    #[test]
    fn startup_input_zero_write_keeps_progress_retryable() {
        struct Zero;
        impl std::io::Write for Zero {
            fn write(&mut self, _: &[u8]) -> std::io::Result<usize> { Ok(0) }
            fn flush(&mut self) -> std::io::Result<()> { Ok(()) }
        }
        let mut written = 0;
        assert_eq!(write_startup_remaining(&mut Zero, b"x", &mut written).unwrap_err().kind(), std::io::ErrorKind::WriteZero);
        assert_eq!(written, 0);
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

    /// Resolve a program by absolute path or via $PATH. Returns None if it
    /// cannot be found, so tests can skip in a minimal sandbox (e.g. the nix
    /// build sandbox, which has no /bin/sh). Keeps `cargo test` green both
    /// locally and hermetically (PTYH-4).
    pub(crate) fn resolve(prog: &str) -> Option<String> {
        if prog.contains('/') {
            return if std::path::Path::new(prog).exists() {
                Some(prog.to_string())
            } else {
                None
            };
        }
        for dir in std::env::var("PATH").unwrap_or_default().split(':') {
            if dir.is_empty() {
                continue;
            }
            let cand = std::path::Path::new(dir).join(prog);
            if cand.exists() {
                return cand.to_str().map(|s| s.to_string());
            }
        }
        None
    }

    /// Resolve a POSIX shell for tests, or None to skip.
    pub(crate) fn shell() -> Option<String> {
        resolve("sh").or_else(|| resolve("/bin/sh")).or_else(|| resolve("bash"))
    }

    /// True if this environment can actually spawn a child under a PTY. The nix
    /// build sandbox has no /dev/pts, so even when openpty() half-succeeds the
    /// fork/exec into the slave fails; PTY-dependent tests skip when this is
    /// false (they still run locally + in CI where a real PTY exists). We probe
    /// with a real end-to-end spawn of `true` so the check matches production.
    pub(crate) fn pty_available() -> bool {
        let prog = match resolve("true").or_else(|| resolve("/usr/bin/true")) {
            Some(p) => p,
            None => return false,
        };
        PtyHost::spawn(SpawnConfig {
            program: prog,
            args: vec![],
            rows: 24,
            cols: 80,
            login_shell: false,
            cwd: None,
            extra_env: Vec::new(),
        })
        .is_ok()
    }

    macro_rules! skip_if_none {
        ($opt:expr, $name:literal) => {
            match $opt {
                Some(v) => v,
                None => {
                    eprintln!("[skip] {} unavailable in this environment", $name);
                    return;
                }
            }
        };
    }

    #[test]
    fn spawn_echo_and_capture_rendered_output() {
        if !pty_available() {
            eprintln!("[skip] no PTY available in this environment");
            return;
        }
        // `echo hi` should render "hi" in the grid, not raw bytes.
        let echo = skip_if_none!(resolve("echo").or_else(|| resolve("/bin/echo")), "echo");
        let host = PtyHost::spawn(SpawnConfig {
            program: echo,
            args: vec!["hi".into()],
            rows: 10,
            cols: 40,
            login_shell: false,
            cwd: None,
            extra_env: Vec::new(),
        })
        .unwrap();
        host.wait_timeout(Duration::from_secs(5));
        // Give the reader a moment to drain final bytes.
        wait_for(|| host.capture().lines[0].contains("hi"), Duration::from_secs(2));
        let cap = host.capture();
        assert!(
            cap.lines.iter().any(|l| l.contains("hi")),
            "expected 'hi' in capture, got: {:?}",
            cap.lines
        );
        assert_eq!(host.exit_code(), Some(0));
    }

    #[test]
    fn write_input_to_shell_is_reflected_in_capture() {
        if !pty_available() {
            eprintln!("[skip] no PTY available in this environment");
            return;
        }
        let sh = skip_if_none!(shell(), "sh");
        let host = PtyHost::spawn(SpawnConfig {
            program: sh,
            args: vec![],
            rows: 20,
            cols: 60,
            login_shell: false,
            cwd: None,
            extra_env: Vec::new(),
        })
        .unwrap();
        // Let the shell come up.
        std::thread::sleep(Duration::from_millis(300));
        host.write_input(b"echo marker123\n").unwrap();
        let ok = wait_for(
            || {
                host.capture()
                    .lines
                    .iter()
                    .any(|l| l.contains("marker123"))
            },
            Duration::from_secs(3),
        );
        assert!(ok, "capture did not reflect echoed marker: {:?}", host.capture().lines);
        // Child should still be alive (interactive shell).
        assert!(host.is_alive());
        host.write_input(b"exit\n").unwrap();
        host.wait_timeout(Duration::from_secs(3));
    }

    #[test]
    fn interactive_child_drops_inherited_no_color_but_allows_explicit_override() {
        if !pty_available() {
            return;
        }
        let sh = skip_if_none!(shell(), "sh");
        for (extra_env, expected) in [
            (Vec::new(), "color-default=unset"),
            (vec![("NO_COLOR".into(), "1".into())], "color-default=1"),
        ] {
            let mut config = SpawnConfig::new(
                sh.clone(),
                vec!["-c".into(), "printf 'color-default=%s' \"${NO_COLOR-unset}\"".into()],
            );
            config.login_shell = false;
            config.extra_env = extra_env;
            let host = PtyHost::spawn(config).unwrap();
            assert!(wait_for(
                || host.capture().lines.iter().any(|line| line.contains(expected)),
                Duration::from_secs(3),
            ), "child environment did not match {expected}: {:?}", host.capture().lines);
        }
    }

    #[test]
    fn color_output_records_rendition() {
        if !pty_available() {
            eprintln!("[skip] no PTY available in this environment");
            return;
        }
        // printf a red 'R' then reset; capture must record fg color on the cell.
        let sh = skip_if_none!(shell(), "sh");
        let host = PtyHost::spawn(SpawnConfig {
            program: sh,
            args: vec!["-c".into(), "printf '\\033[31mR\\033[0m'".into()],
            rows: 5,
            cols: 20,
            login_shell: false,
            cwd: None,
            extra_env: Vec::new(),
        })
        .unwrap();
        host.wait_timeout(Duration::from_secs(5));
        wait_for(|| host.capture().lines[0].contains('R'), Duration::from_secs(2));
        let cap = host.capture();
        let cell = cap.cell_at(0, 0).unwrap();
        assert_eq!(cell.c, 'R');
        assert_eq!(cell.fg, crate::vt::Color::Indexed(1));
    }

    #[test]
    fn resize_updates_model() {
        if !pty_available() {
            eprintln!("[skip] no PTY available in this environment");
            return;
        }
        let sh = skip_if_none!(shell(), "sh");
        let mut host = PtyHost::spawn(SpawnConfig {
            program: sh,
            args: vec![],
            rows: 24,
            cols: 80,
            login_shell: false,
            cwd: None,
            extra_env: Vec::new(),
        })
        .unwrap();
        std::thread::sleep(Duration::from_millis(200));
        host.resize(30, 100).unwrap();
        let cap = host.capture();
        assert_eq!(cap.rows, 30);
        assert_eq!(cap.cols, 100);
        host.write_input(b"exit\n").unwrap();
        host.wait_timeout(Duration::from_secs(3));
    }
}
