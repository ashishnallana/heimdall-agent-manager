//! REQ PTYH-2: `attach` client.
//!
//! Connects to a host's unix socket, puts the local terminal into raw mode,
//! streams `Output` to stdout, forwards stdin as `Input`, honors SIGWINCH by
//! sending `Resize`, and detaches on Ctrl-\ WITHOUT killing the child. When the
//! host reports `ChildExited`, the client restores the terminal and exits with
//! the child's code.

use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::Arc;

use anyhow::{Context, Result};

use crate::ipc::UnixStream;
use crate::proto::{self, ClientMsg, HostMsg};
use crate::termios::{current_winsize, take_resize, watch_resize, RawGuard};

/// Byte that triggers a clean detach (Ctrl-\, aka FS / 0x1c).
const DETACH_BYTE: u8 = 0x1c;

/// Outcome of an attach session.
#[derive(Debug, PartialEq, Eq)]
pub enum AttachOutcome {
    Detached,
    ChildExited(i32),
    Disconnected,
}

/// Attach to the host at `socket_path`, driving the local terminal until the
/// user detaches (Ctrl-\) or the child exits.
pub fn attach(socket_path: &std::path::Path) -> Result<AttachOutcome> {
    let stream = UnixStream::connect(socket_path)
        .with_context(|| format!("connect to host socket {socket_path:?}"))?;
    let mut write_stream = stream.try_clone().context("clone socket")?;
    let mut read_stream = stream;

    // Put the local terminal in raw mode so keystrokes pass through untouched.
    let _raw = RawGuard::enable().context("enable raw mode")?;

    // Send Attach + initial Resize to match our window.
    proto::write_client_msg(&mut write_stream, &ClientMsg::Attach)?;
    if let Some((rows, cols)) = current_winsize() {
        proto::write_client_msg(&mut write_stream, &ClientMsg::Resize { rows, cols })?;
    }

    let detached = Arc::new(AtomicBool::new(false));
    let child_exit = Arc::new(AtomicI32::new(i32::MIN));
    let done = Arc::new(AtomicBool::new(false));

    // SIGWINCH -> Resize. We poll a flag set by the resize watcher.
    watch_resize();

    // Reader thread: host -> stdout / handle control frames.
    let reader = {
        let child_exit = Arc::clone(&child_exit);
        let done = Arc::clone(&done);
        std::thread::spawn(move || {
            let mut out = std::io::stdout();
            loop {
                match proto::read_host_msg(&mut read_stream) {
                    Ok(Some(HostMsg::Output(bytes))) => {
                        let _ = out.write_all(&bytes);
                        let _ = out.flush();
                    }
                    Ok(Some(HostMsg::Screen(_))) => {
                        // In raw passthrough we rely on Output; Screen frames are
                        // used by the debug TUI (PTYH-3). Ignore here.
                    }
                    Ok(Some(HostMsg::ChildExited(code))) => {
                        child_exit.store(code, Ordering::SeqCst);
                        done.store(true, Ordering::SeqCst);
                        break;
                    }
                    Ok(Some(HostMsg::Pong)) => {}
                    Ok(None) | Err(_) => {
                        done.store(true, Ordering::SeqCst);
                        break;
                    }
                }
            }
        })
    };

    // Main loop: stdin -> Input, watch for detach + SIGWINCH + child exit.
    let mut stdin = std::io::stdin();
    let mut buf = [0u8; 4096];
    // Non-blocking-ish stdin via short read timeout is not portable; instead we
    // read in a dedicated thread and forward through a channel.
    let (in_tx, in_rx) = std::sync::mpsc::channel::<Vec<u8>>();
    {
        let done = Arc::clone(&done);
        std::thread::spawn(move || loop {
            if done.load(Ordering::SeqCst) {
                break;
            }
            match stdin.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    if in_tx.send(buf[..n].to_vec()).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        });
    }

    let outcome = loop {
        if done.load(Ordering::SeqCst) {
            let code = child_exit.load(Ordering::SeqCst);
            if code != i32::MIN {
                break AttachOutcome::ChildExited(code);
            }
            break AttachOutcome::Disconnected;
        }
        // Handle a pending resize.
        if take_resize() {
            if let Some((rows, cols)) = current_winsize() {
                let _ = proto::write_client_msg(
                    &mut write_stream,
                    &ClientMsg::Resize { rows, cols },
                );
            }
        }
        match in_rx.recv_timeout(std::time::Duration::from_millis(100)) {
            Ok(chunk) => {
                if let Some(pos) = chunk.iter().position(|&b| b == DETACH_BYTE) {
                    // Forward anything before the detach byte, then detach.
                    if pos > 0 {
                        let _ = proto::write_client_msg(
                            &mut write_stream,
                            &ClientMsg::Input(chunk[..pos].to_vec()),
                        );
                    }
                    let _ = proto::write_client_msg(&mut write_stream, &ClientMsg::Detach);
                    detached.store(true, Ordering::SeqCst);
                    break AttachOutcome::Detached;
                }
                let _ = proto::write_client_msg(&mut write_stream, &ClientMsg::Input(chunk));
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                if done.load(Ordering::SeqCst) {
                    let code = child_exit.load(Ordering::SeqCst);
                    if code != i32::MIN {
                        break AttachOutcome::ChildExited(code);
                    }
                }
                break AttachOutcome::Disconnected;
            }
        }
    };

    done.store(true, Ordering::SeqCst);
    let _ = reader.join();
    // RawGuard restores the terminal on drop.
    Ok(outcome)
}
