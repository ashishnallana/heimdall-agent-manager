//! REQ PTYH-2: unix-socket server side of the PTY host.
//!
//! The server owns a [`PtyHost`] and accepts multiple attach clients over a unix
//! domain socket. It fans out raw child output to every attached client and
//! multiplexes their input back into the single PTY.
//!
//! Key behaviors (per PTYH-2):
//!   * Dropping / detaching a client does NOT kill the child.
//!   * A later attach reconnects and drives the same live child.
//!   * When the child exits, the host broadcasts `ChildExited` and shuts down.

use std::collections::HashMap;
use std::io::Write;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use anyhow::{Context, Result};

use crate::host::{PtyHost, SpawnConfig};
use crate::ipc::{UnixListener, UnixStream};
use crate::proto::{
    self, ClientMsg, HostMsg, ScreenSnapshot,
};
use crate::vt::VtEngine;

/// Set of connected client output sinks, keyed by client id.
type ClientMap = Arc<Mutex<HashMap<u64, Sender<HostMsg>>>>;

/// A running host bound to a unix socket.
pub struct HostServer {
    socket_path: std::path::PathBuf,
    clients: ClientMap,
    shutdown: Arc<AtomicBool>,
    threads: Vec<JoinHandle<()>>,
    host: Arc<Mutex<PtyHost>>,
    engine: Arc<Mutex<VtEngine>>,
    alive: Arc<AtomicBool>,
    killer: Arc<Mutex<Box<dyn portable_pty::ChildKiller + Send + Sync>>>,
}

impl HostServer {
    /// Spawn the child and bind the unix socket, then start the accept +
    /// fan-out loops. Returns once the server is listening.
    pub fn start(socket_path: impl Into<std::path::PathBuf>, config: SpawnConfig) -> Result<Self> {
        let socket_path = socket_path.into();
        crate::socket_path::prepare(&socket_path)?;
        // Remove any stale socket.
        let _ = std::fs::remove_file(&socket_path);

        let mut host = PtyHost::spawn(config).context("spawn under PTY")?;
        let engine = host.engine();
        let output_rx = host.take_output_rx().expect("output rx");
        let alive = host.alive_flag();
        let killer = host.killer();
        let host = Arc::new(Mutex::new(host));

        let listener =
            UnixListener::bind(&socket_path).with_context(|| format!("bind {socket_path:?}"))?;

        let clients: ClientMap = Arc::new(Mutex::new(HashMap::new()));
        let shutdown = Arc::new(AtomicBool::new(false));
        let mut threads = Vec::new();

        // Fan-out thread: raw PTY output -> every attached client as Output.
        threads.push(spawn_fanout(output_rx, Arc::clone(&clients)));

        // Child-exit watcher: when the child dies, broadcast ChildExited + stop.
        threads.push(spawn_exit_watcher(
            Arc::clone(&alive),
            Arc::clone(&host),
            Arc::clone(&clients),
            Arc::clone(&shutdown),
            socket_path.clone(),
        ));

        // Accept loop.
        threads.push(spawn_accept_loop(
            listener,
            Arc::clone(&clients),
            Arc::clone(&host),
            Arc::clone(&engine),
            Arc::clone(&shutdown),
        ));

        Ok(HostServer {
            socket_path,
            clients,
            shutdown,
            threads,
            host,
            engine,
            alive,
            killer,
        })
    }

    pub fn socket_path(&self) -> &std::path::Path {
        &self.socket_path
    }

    pub fn is_child_alive(&self) -> bool {
        self.alive.load(Ordering::SeqCst)
    }

    pub fn client_count(&self) -> usize {
        self.clients.lock().unwrap().len()
    }

    /// Snapshot the current screen (for tests / diagnostics).
    pub fn capture_snapshot(&self) -> ScreenSnapshot {
        capture_snapshot(&self.engine)
    }

    /// Block until the child exits, returning its exit code.
    pub fn wait(&self) -> i32 {
        loop {
            if !self.alive.load(Ordering::SeqCst) {
                let code = self.host.lock().unwrap().exit_code().unwrap_or(-1);
                return code;
            }
            std::thread::sleep(std::time::Duration::from_millis(30));
        }
    }

    /// Signal shutdown + join threads.
    ///
    /// Kills the child first so the PTY closes: that unblocks the reader thread
    /// (EOF) which drops the raw-output sender, letting the fan-out thread's
    /// `recv()` return so the join can complete. Without the kill, an
    /// interactive child (e.g. a live shell) would keep the PTY open forever.
    pub fn shutdown(&mut self) {
        self.shutdown.store(true, Ordering::SeqCst);
        if self.alive.load(Ordering::SeqCst) {
            let _ = self.killer.lock().unwrap().kill();
        }
        // ConPTY only EOFs the reader once the pseudoconsole is closed, which a
        // dead child alone does not do.
        #[cfg(windows)]
        {
            let mut host = self.host.lock().unwrap();
            host.wait_timeout(std::time::Duration::from_secs(2));
            host.release_pty();
        }
        // Poke the accept loop by connecting once.
        let _ = UnixStream::connect(&self.socket_path);
        for t in self.threads.drain(..) {
            let _ = t.join();
        }
        let _ = std::fs::remove_file(&self.socket_path);
    }
}

impl Drop for HostServer {
    fn drop(&mut self) {
        if !self.shutdown.load(Ordering::SeqCst) {
            self.shutdown.store(true, Ordering::SeqCst);
            let _ = std::fs::remove_file(&self.socket_path);
        }
    }
}

fn capture_snapshot(engine: &Arc<Mutex<VtEngine>>) -> ScreenSnapshot {
    let cap = engine.lock().unwrap().capture();
    ScreenSnapshot {
        rows: cap.rows as u16,
        cols: cap.cols as u16,
        cursor_row: cap.cursor_row as u16,
        cursor_col: cap.cursor_col as u16,
        lines: cap.lines,
    }
}

fn spawn_fanout(output_rx: Receiver<Vec<u8>>, clients: ClientMap) -> JoinHandle<()> {
    std::thread::spawn(move || {
        while let Ok(chunk) = output_rx.recv() {
            let map = clients.lock().unwrap();
            for tx in map.values() {
                let _ = tx.send(HostMsg::Output(chunk.clone()));
            }
        }
    })
}

fn spawn_exit_watcher(
    alive: Arc<AtomicBool>,
    host: Arc<Mutex<PtyHost>>,
    clients: ClientMap,
    shutdown: Arc<AtomicBool>,
    socket_path: std::path::PathBuf,
) -> JoinHandle<()> {
    std::thread::spawn(move || {
        while alive.load(Ordering::SeqCst) {
            if shutdown.load(Ordering::SeqCst) {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(30));
        }
        // Child exited: broadcast to all clients, then request shutdown.
        let code = host.lock().unwrap().exit_code().unwrap_or(-1);
        {
            let map = clients.lock().unwrap();
            for tx in map.values() {
                let _ = tx.send(HostMsg::ChildExited(code));
            }
        }
        // Give writers a moment to flush the exit frame.
        std::thread::sleep(std::time::Duration::from_millis(50));
        shutdown.store(true, Ordering::SeqCst);
        // Poke accept loop so it notices shutdown.
        let _ = UnixStream::connect(&socket_path);
    })
}

fn spawn_accept_loop(
    listener: UnixListener,
    clients: ClientMap,
    host: Arc<Mutex<PtyHost>>,
    engine: Arc<Mutex<VtEngine>>,
    shutdown: Arc<AtomicBool>,
) -> JoinHandle<()> {
    static NEXT_ID: AtomicU64 = AtomicU64::new(1);
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            if shutdown.load(Ordering::SeqCst) {
                break;
            }
            let stream = match stream {
                Ok(s) => s,
                Err(_) => continue,
            };
            let id = NEXT_ID.fetch_add(1, Ordering::SeqCst);
            handle_client(
                id,
                stream,
                Arc::clone(&clients),
                Arc::clone(&host),
                Arc::clone(&engine),
                Arc::clone(&shutdown),
            );
        }
    })
}

/// Set up per-client reader + writer threads.
fn handle_client(
    id: u64,
    stream: UnixStream,
    clients: ClientMap,
    host: Arc<Mutex<PtyHost>>,
    engine: Arc<Mutex<VtEngine>>,
    shutdown: Arc<AtomicBool>,
) {
    let (tx, rx) = std::sync::mpsc::channel::<HostMsg>();
    clients.lock().unwrap().insert(id, tx.clone());

    let mut write_stream = match stream.try_clone() {
        Ok(s) => s,
        Err(_) => {
            clients.lock().unwrap().remove(&id);
            return;
        }
    };
    let mut read_stream = stream;

    // Writer thread: drain this client's queue to the socket.
    let writer_clients = Arc::clone(&clients);
    std::thread::spawn(move || {
        while let Ok(msg) = rx.recv() {
            let is_exit = matches!(msg, HostMsg::ChildExited(_));
            if proto::write_host_msg(&mut write_stream, &msg).is_err() {
                break;
            }
            if is_exit {
                let _ = write_stream.flush();
                break;
            }
        }
        writer_clients.lock().unwrap().remove(&id);
    });

    // Reader thread: decode client messages + act on them.
    std::thread::spawn(move || {
        loop {
            match proto::read_client_msg(&mut read_stream) {
                Ok(Some(msg)) => {
                    if handle_msg(msg, &host, &engine, &tx).is_break() {
                        break;
                    }
                }
                Ok(None) => break, // client dropped
                Err(_) => break,
            }
            if shutdown.load(Ordering::SeqCst) {
                break;
            }
        }
        // Detach/drop: remove the sink; child stays alive.
        clients.lock().unwrap().remove(&id);
    });
}

use std::ops::ControlFlow;

fn handle_msg(
    msg: ClientMsg,
    host: &Arc<Mutex<PtyHost>>,
    engine: &Arc<Mutex<VtEngine>>,
    tx: &Sender<HostMsg>,
) -> ControlFlow<()> {
    match msg {
        ClientMsg::Attach => {
            // On attach, immediately send the current screen so a re-attached
            // client sees live state without waiting for new output.
            let snap = capture_snapshot(engine);
            let _ = tx.send(HostMsg::Screen(snap));
            ControlFlow::Continue(())
        }
        ClientMsg::Input(bytes) => {
            let _ = host.lock().unwrap().write_input(&bytes);
            ControlFlow::Continue(())
        }
        ClientMsg::Key(k) => {
            let _ = host.lock().unwrap().write_input(k.to_bytes());
            ControlFlow::Continue(())
        }
        ClientMsg::Resize { rows, cols } => {
            let _ = host.lock().unwrap().resize(rows, cols);
            ControlFlow::Continue(())
        }
        ClientMsg::Capture => {
            let snap = capture_snapshot(engine);
            let _ = tx.send(HostMsg::Screen(snap));
            ControlFlow::Continue(())
        }
        ClientMsg::Ping => {
            let _ = tx.send(HostMsg::Pong);
            ControlFlow::Continue(())
        }
        ClientMsg::Detach => ControlFlow::Break(()),
    }
}

/// Convenience used by main + tests: write a single client message to a stream.
pub fn send(stream: &mut UnixStream, msg: &ClientMsg) -> Result<()> {
    proto::write_client_msg(stream, msg).context("send client msg")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::proto::read_host_msg;
    use std::time::Duration;

    fn tmp_socket(name: &str) -> std::path::PathBuf {
        let mut p = std::env::temp_dir();
        let uniq = format!(
            "ham-pty-{}-{}-{}.sock",
            name,
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        );
        p.push(uniq);
        p
    }

    fn sh_config(sh: &str, rows: u16, cols: u16) -> SpawnConfig {
        SpawnConfig {
            program: sh.to_string(),
            args: vec![],
            rows,
            cols,
            login_shell: false,
            cwd: None,
            extra_env: Vec::new(),
        }
    }

    /// Resolve a POSIX shell + a usable PTY, or skip the test in a minimal
    /// sandbox (the nix build sandbox has no /bin/sh and no /dev/ptmx).
    /// See host::tests::resolve / pty_available.
    macro_rules! require_shell {
        () => {{
            if !crate::host::tests::pty_available() {
                eprintln!("[skip] no PTY available in this environment");
                return;
            }
            match crate::host::tests::shell() {
                Some(sh) => sh,
                None => {
                    eprintln!("[skip] no POSIX shell available in this environment");
                    return;
                }
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

    /// Read frames until a Screen whose lines contain `needle`, or timeout.
    fn await_screen_contains(
        stream: &mut UnixStream,
        needle: &str,
        timeout: Duration,
    ) -> bool {
        stream
            .set_read_timeout(Some(Duration::from_millis(200)))
            .unwrap();
        let start = std::time::Instant::now();
        while start.elapsed() < timeout {
            match read_host_msg(stream) {
                Ok(Some(HostMsg::Screen(s))) => {
                    if s.lines.iter().any(|l| l.contains(needle)) {
                        return true;
                    }
                }
                Ok(Some(_)) => {}
                Ok(None) => return false,
                Err(ref e)
                    if e.kind() == std::io::ErrorKind::WouldBlock
                        || e.kind() == std::io::ErrorKind::TimedOut => {}
                Err(_) => return false,
            }
        }
        false
    }

    #[test]
    fn input_then_capture_shows_output() {
        let sh = require_shell!();
        let sock = tmp_socket("cap");
        let mut server = HostServer::start(&sock, sh_config(&sh, 20, 60)).unwrap();
        std::thread::sleep(Duration::from_millis(300));

        let mut c = UnixStream::connect(&sock).unwrap();
        send(&mut c, &ClientMsg::Attach).unwrap();
        send(&mut c, &ClientMsg::Input(b"echo hi\n".to_vec())).unwrap();
        std::thread::sleep(Duration::from_millis(400));
        send(&mut c, &ClientMsg::Capture).unwrap();

        assert!(
            await_screen_contains(&mut c, "hi", Duration::from_secs(3)),
            "capture never showed 'hi'"
        );
        server.shutdown();
    }

    #[test]
    fn dropping_client_leaves_child_alive_and_reattach_drives_it() {
        let sh = require_shell!();
        let sock = tmp_socket("reattach");
        let mut server = HostServer::start(&sock, sh_config(&sh, 20, 60)).unwrap();
        std::thread::sleep(Duration::from_millis(300));

        // First client attaches, then drops (simulating detach via disconnect).
        {
            let mut c1 = UnixStream::connect(&sock).unwrap();
            send(&mut c1, &ClientMsg::Attach).unwrap();
            send(&mut c1, &ClientMsg::Input(b"echo first\n".to_vec())).unwrap();
            std::thread::sleep(Duration::from_millis(300));
            // c1 dropped at end of scope.
        }
        assert!(
            wait_for(|| server.client_count() == 0, Duration::from_secs(2)),
            "client not cleaned up after drop"
        );
        // Child must still be alive.
        assert!(server.is_child_alive(), "child died when client dropped");

        // Second client attaches + drives the same child.
        let mut c2 = UnixStream::connect(&sock).unwrap();
        send(&mut c2, &ClientMsg::Attach).unwrap();
        send(&mut c2, &ClientMsg::Input(b"echo second\n".to_vec())).unwrap();
        std::thread::sleep(Duration::from_millis(400));
        send(&mut c2, &ClientMsg::Capture).unwrap();
        assert!(
            await_screen_contains(&mut c2, "second", Duration::from_secs(3)),
            "re-attached client could not drive child"
        );
        server.shutdown();
    }

    #[test]
    fn child_exit_broadcasts_and_shuts_down() {
        let sh = require_shell!();
        let sock = tmp_socket("exit");
        let mut server = HostServer::start(&sock, sh_config(&sh, 20, 60)).unwrap();
        std::thread::sleep(Duration::from_millis(300));

        let mut c = UnixStream::connect(&sock).unwrap();
        send(&mut c, &ClientMsg::Attach).unwrap();
        send(&mut c, &ClientMsg::Input(b"exit 7\n".to_vec())).unwrap();

        // Expect a ChildExited(7) frame.
        c.set_read_timeout(Some(Duration::from_millis(200))).unwrap();
        let start = std::time::Instant::now();
        let mut got = None;
        while start.elapsed() < Duration::from_secs(4) {
            match read_host_msg(&mut c) {
                Ok(Some(HostMsg::ChildExited(code))) => {
                    got = Some(code);
                    break;
                }
                Ok(Some(_)) => {}
                Ok(None) => break,
                Err(ref e)
                    if e.kind() == std::io::ErrorKind::WouldBlock
                        || e.kind() == std::io::ErrorKind::TimedOut => {}
                Err(_) => break,
            }
        }
        assert_eq!(got, Some(7), "did not receive ChildExited(7)");
        assert!(
            wait_for(|| !server.is_child_alive(), Duration::from_secs(2)),
            "server still reports child alive"
        );
        server.shutdown();
    }

    #[test]
    fn ping_pong() {
        let sh = require_shell!();
        let sock = tmp_socket("ping");
        let mut server = HostServer::start(&sock, sh_config(&sh, 10, 40)).unwrap();
        std::thread::sleep(Duration::from_millis(200));
        let mut c = UnixStream::connect(&sock).unwrap();
        send(&mut c, &ClientMsg::Ping).unwrap();
        c.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        let msg = read_host_msg(&mut c).unwrap();
        assert_eq!(msg, Some(HostMsg::Pong));
        server.shutdown();
    }

    #[test]
    fn multiple_clients_receive_same_output() {
        let sh = require_shell!();
        let sock = tmp_socket("multi");
        let mut server = HostServer::start(&sock, sh_config(&sh, 20, 60)).unwrap();
        std::thread::sleep(Duration::from_millis(300));

        let mut a = UnixStream::connect(&sock).unwrap();
        let mut b = UnixStream::connect(&sock).unwrap();
        send(&mut a, &ClientMsg::Attach).unwrap();
        send(&mut b, &ClientMsg::Attach).unwrap();
        std::thread::sleep(Duration::from_millis(150));
        send(&mut a, &ClientMsg::Input(b"echo shared\n".to_vec())).unwrap();
        std::thread::sleep(Duration::from_millis(300));
        send(&mut a, &ClientMsg::Capture).unwrap();
        send(&mut b, &ClientMsg::Capture).unwrap();

        assert!(await_screen_contains(&mut a, "shared", Duration::from_secs(3)));
        assert!(await_screen_contains(&mut b, "shared", Duration::from_secs(3)));
        server.shutdown();
    }
}
