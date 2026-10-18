//! REQ HOST-4: single-agent `attach --instance <id>` — raw passthrough to ONE
//! daemon agent, no sidebar, for dropping into a tmux pane and tiling manually.
//!
//! This is the daemon (dproto) analogue of the single-host [`crate::client`]:
//! it `Attach{instance}`es, streams that instance's `Output` to stdout, forwards
//! stdin as `Input{instance}`, tracks SIGWINCH -> `Resize{instance}` so the
//! contained process reflows to the pane, and **detaches on Ctrl-\ without
//! killing the child**. Async events for OTHER instances (or control replies)
//! are ignored so multiple single-agent panes can share one daemon.
//!
//! Fullscreen Selector Overlay (Ctrl-Space):
//! When attached, pressing Ctrl-Space enters the fullscreen selector overlay.
//! The overlay switches into the terminal's alternate screen buffer (`ESC[?1049h`),
//! draws a fuzzy-searchable list of all registered agents (name, dir, runtime, etc.)
//! rendered via ratatui, and on exit switches back (`ESC[?1049l`).
//! The underlying screen content and colors remain completely uncorrupted.
//! Selecting an agent performs `Detach{old}` + `Attach{new}` + `Resize`.

use std::io::Write;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use ratatui::layout::{Constraint, Direction, Layout};

use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, List, ListItem, Paragraph};
use ratatui::Terminal;

use crate::client::AttachOutcome;
use crate::dashboard_tui::Key;
use crate::dproto::{self, AgentInfo, CtlMsg, CtlReply};
use crate::selector::{SelectorAction, SelectorItem, SelectorState};
use crate::ipc::UnixStream;
use crate::termios::{current_winsize, read_stdin_timeout, take_resize, watch_resize, RawGuard};

/// Byte that triggers a clean detach (Ctrl-\, aka FS / 0x1c).
const DETACH_BYTE: u8 = 0x1c;

/// Byte that triggers the agent selector overlay (Ctrl-Space / NUL / 0x00).
const SELECTOR_BYTE: u8 = 0x00;

/// Byte that triggers tmux-like prefix command navigation (Ctrl-b / 0x02).
const PREFIX_BYTE: u8 = 0x02;

/// Actions emitted by the Ctrl-b prefix state machine.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PrefixAction {
    /// Raw bytes to forward directly to the child PTY.
    Passthrough(Vec<u8>),
    /// Switch to the next agent in the list ((idx + 1) % len).
    NextAgent,
    /// Switch to the previous agent in the list ((idx + len - 1) % len).
    PrevAgent,
    /// Open the alternate-buffer agent selector overlay (Ctrl-Space).
    OpenSelector,
    /// Detach cleanly from the host/daemon (Ctrl-\).
    Detach,
}

/// Internal state of the Ctrl-b prefix state machine.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PrefixState {
    Idle,
    PrefixPending(Instant),
}

/// Prefix state machine handling Ctrl-b navigation and raw terminal passthrough.
pub struct PrefixStateMachine {
    state: PrefixState,
    timeout: Duration,
}

impl Default for PrefixStateMachine {
    fn default() -> Self {
        Self::new()
    }
}

impl PrefixStateMachine {
    pub const PREFIX_BYTE: u8 = PREFIX_BYTE;
    pub const DETACH_BYTE: u8 = DETACH_BYTE;
    pub const SELECTOR_BYTE: u8 = SELECTOR_BYTE;
    pub const DEFAULT_TIMEOUT: Duration = Duration::from_millis(1000);

    pub fn new() -> Self {
        Self {
            state: PrefixState::Idle,
            timeout: Self::DEFAULT_TIMEOUT,
        }
    }

    pub fn with_timeout(timeout: Duration) -> Self {
        Self {
            state: PrefixState::Idle,
            timeout,
        }
    }

    pub fn state(&self) -> PrefixState {
        self.state
    }

    pub fn time_until_timeout(&self, now: Instant) -> Option<Duration> {
        match self.state {
            PrefixState::Idle => None,
            PrefixState::PrefixPending(start) => {
                let elapsed = now.saturating_duration_since(start);
                Some(self.timeout.saturating_sub(elapsed))
            }
        }
    }

    pub fn check_timeout(&mut self, now: Instant) -> Vec<PrefixAction> {
        if let PrefixState::PrefixPending(start) = self.state {
            if now.saturating_duration_since(start) >= self.timeout {
                self.state = PrefixState::Idle;
                return vec![PrefixAction::Passthrough(vec![Self::PREFIX_BYTE])];
            }
        }
        Vec::new()
    }

    pub fn feed_byte(&mut self, b: u8, now: Instant) -> Vec<PrefixAction> {
        let mut actions = Vec::new();
        if let PrefixState::PrefixPending(start) = self.state {
            if now.saturating_duration_since(start) >= self.timeout {
                self.state = PrefixState::Idle;
                actions.push(PrefixAction::Passthrough(vec![Self::PREFIX_BYTE]));
            }
        }

        match self.state {
            PrefixState::Idle => {
                match b {
                    Self::DETACH_BYTE => actions.push(PrefixAction::Detach),
                    Self::SELECTOR_BYTE => actions.push(PrefixAction::OpenSelector),
                    Self::PREFIX_BYTE => self.state = PrefixState::PrefixPending(now),
                    _ => actions.push(PrefixAction::Passthrough(vec![b])),
                }
            }
            PrefixState::PrefixPending(_) => {
                self.state = PrefixState::Idle;
                match b {
                    b'n' | 0x0e => actions.push(PrefixAction::NextAgent),
                    b'p' | 0x10 => actions.push(PrefixAction::PrevAgent),
                    Self::PREFIX_BYTE => {
                        actions.push(PrefixAction::Passthrough(vec![Self::PREFIX_BYTE]));
                    }
                    Self::DETACH_BYTE => {
                        actions.push(PrefixAction::Passthrough(vec![Self::PREFIX_BYTE]));
                        actions.push(PrefixAction::Detach);
                    }
                    Self::SELECTOR_BYTE => {
                        actions.push(PrefixAction::Passthrough(vec![Self::PREFIX_BYTE]));
                        actions.push(PrefixAction::OpenSelector);
                    }
                    _ => {
                        actions.push(PrefixAction::Passthrough(vec![Self::PREFIX_BYTE, b]));
                    }
                }
            }
        }
        actions
    }

    pub fn feed_chunk(&mut self, chunk: &[u8], now: Instant) -> Vec<PrefixAction> {
        let mut actions = Vec::new();
        for &b in chunk {
            actions.extend(self.feed_byte(b, now));
        }
        Self::coalesce_actions(actions)
    }

    pub fn coalesce_actions(actions: Vec<PrefixAction>) -> Vec<PrefixAction> {
        let mut result = Vec::new();
        for action in actions {
            match action {
                PrefixAction::Passthrough(data) => {
                    if let Some(PrefixAction::Passthrough(ref mut prev_data)) = result.last_mut() {
                        prev_data.extend(data);
                    } else {
                        result.push(PrefixAction::Passthrough(data));
                    }
                }
                other => result.push(other),
            }
        }
        result
    }
}

/// Cycle through registered agents in `agent_list` relative to `current_instance`.
///
/// If `forward` is true: (current_idx + 1) % len.
/// If `forward` is false: (current_idx + len - 1) % len.
/// Returns `None` if `agent_list` is empty.
pub fn cycle_agent(
    agent_list: &[AgentInfo],
    current_instance: &str,
    forward: bool,
) -> Option<String> {
    if agent_list.is_empty() {
        return None;
    }
    let len = agent_list.len();
    let current_idx = agent_list
        .iter()
        .position(|a| a.instance_id == current_instance)
        .unwrap_or(0);
    let next_idx = if forward {
        (current_idx + 1) % len
    } else {
        (current_idx + len - 1) % len
    };
    Some(agent_list[next_idx].instance_id.clone())
}

/// Switch the active PTY subscription from `old_inst` to `new_inst`.
///
/// Detaches `old_inst`, attaches `new_inst`, and performs a micro-resize
/// nudge (cols - 1 then cols) to ensure the child process receives a winsize
/// delta and forces a full redraw.
/// If `old_inst == new_inst`, it only performs the micro-resize nudge.
pub fn switch_agent(
    ws: &mut UnixStream,
    old_inst: &str,
    new_inst: &str,
) -> Result<()> {
    if old_inst != new_inst {
        let _ = dproto::write_ctl_msg(ws, &CtlMsg::Detach { instance: old_inst.to_string() });
        let _ = dproto::write_ctl_msg(ws, &CtlMsg::Attach { instance: new_inst.to_string() });
    }
    if let Some((rows, cols)) = current_winsize() {
        let _ = dproto::write_ctl_msg(
            ws,
            &CtlMsg::Resize {
                instance: new_inst.to_string(),
                rows,
                cols: cols.saturating_sub(1),
            },
        );
        std::thread::sleep(Duration::from_millis(20));
        let _ = dproto::write_ctl_msg(
            ws,
            &CtlMsg::Resize {
                instance: new_inst.to_string(),
                rows,
                cols,
            },
        );
    }
    Ok(())
}

fn spawn_stdin_reader(
    done: Arc<AtomicBool>,
    in_tx: std::sync::mpsc::Sender<Vec<u8>>,
) -> std::thread::JoinHandle<()> {
    std::thread::spawn(move || {
        // 8 KiB: on Windows a smaller read would leave bytes in std's stdin buffer.
        let mut buf = [0u8; 8192];
        while !done.load(Ordering::SeqCst) {
            match read_stdin_timeout(&mut buf, 50) {
                Ok(Some(0)) => break, // EOF
                Ok(Some(n)) => {
                    if in_tx.send(buf[..n].to_vec()).is_err() {
                        break;
                    }
                }
                _ => {}
            }
        }
    })
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Connect to the daemon socket at `socket_path`, fetch registered agents, and
/// run the fullscreen alternate-buffer agent selector overlay.
///
/// Returns `Some(instance_id)` if an agent was selected, or `None` if cancelled
/// (e.g. Esc or Ctrl-C).
pub fn select_instance(socket_path: &std::path::Path) -> Result<Option<String>> {
    let stream = UnixStream::connect(socket_path)
        .with_context(|| format!("connect to daemon socket {socket_path:?}"))?;
    let write_stream = stream.try_clone().context("clone socket")?;
    let read_stream = stream;

    // Raw mode so keystrokes pass through untouched to the selector.
    let _raw = RawGuard::enable().context("enable raw mode")?;

    let current_inst_arc = Arc::new(Mutex::new(String::new()));
    let write_stream = Arc::new(Mutex::new(write_stream));
    let done = Arc::new(AtomicBool::new(false));
    let agent_list = Arc::new(Mutex::new(Vec::<AgentInfo>::new()));

    // Request initial agent list
    {
        let mut ws = write_stream.lock().unwrap();
        dproto::write_ctl_msg(&mut *ws, &CtlMsg::List)?;
    }

    // Spawn background reader thread to receive daemon replies (AgentList)
    let reader = {
        let done = Arc::clone(&done);
        let agent_list = Arc::clone(&agent_list);
        let mut read_stream = read_stream;
        std::thread::spawn(move || {
            loop {
                if done.load(Ordering::SeqCst) {
                    break;
                }
                match dproto::read_ctl_reply(&mut read_stream) {
                    Ok(Some(CtlReply::AgentList(list))) => {
                        *agent_list.lock().unwrap() = list;
                    }
                    Ok(Some(_)) => {}
                    Ok(None) | Err(_) => {
                        done.store(true, Ordering::SeqCst);
                        break;
                    }
                }
            }
        })
    };

    // Stdin reader thread -> channel using poll for prompt shutdown on exit
    let (in_tx, in_rx) = std::sync::mpsc::channel::<Vec<u8>>();
    let stdin_reader = spawn_stdin_reader(Arc::clone(&done), in_tx);

    // Give daemon up to 50ms to deliver initial AgentList before drawing
    let start = Instant::now();
    while start.elapsed() < Duration::from_millis(50) {
        if !agent_list.lock().unwrap().is_empty() || done.load(Ordering::SeqCst) {
            break;
        }
        std::thread::sleep(Duration::from_millis(5));
    }

    let chosen = run_selector_overlay(
        &in_rx,
        &done,
        &agent_list,
        &current_inst_arc,
        &write_stream,
    );

    done.store(true, Ordering::SeqCst);
    let _ = write_stream.lock().unwrap().shutdown(std::net::Shutdown::Both);
    let _ = stdin_reader.join();
    let _ = reader.join();

    Ok(chosen)
}

/// Attach to a single daemon agent `instance` at `socket_path`, driving the
/// local terminal until the user detaches (Ctrl-\) or the child exits.
pub fn attach_instance(socket_path: &std::path::Path, instance: &str) -> Result<AttachOutcome> {
    let stream = UnixStream::connect(socket_path)
        .with_context(|| format!("connect to daemon socket {socket_path:?}"))?;
    let write_stream = stream.try_clone().context("clone socket")?;
    let read_stream = stream;

    // Raw mode so keystrokes pass through untouched.
    let _raw = RawGuard::enable().context("enable raw mode")?;

    let current_instance = instance.to_string();
    let current_inst_arc = Arc::new(Mutex::new(current_instance.clone()));
    let write_stream = Arc::new(Mutex::new(write_stream));

    // Attach + initial Resize to match our window (with micro-nudge for instant full redraw).
    {
        let mut ws = write_stream.lock().unwrap();
        dproto::write_ctl_msg(&mut *ws, &CtlMsg::Attach { instance: current_instance.clone() })?;
        if let Some((rows, cols)) = current_winsize() {
            let _ = dproto::write_ctl_msg(
                &mut *ws,
                &CtlMsg::Resize {
                    instance: current_instance.clone(),
                    rows,
                    cols: cols.saturating_sub(1),
                },
            );
            std::thread::sleep(Duration::from_millis(20));
            let _ = dproto::write_ctl_msg(
                &mut *ws,
                &CtlMsg::Resize {
                    instance: current_instance.clone(),
                    rows,
                    cols,
                },
            );
        }
        // Send initial CtlMsg::List so agent_list is populated immediately
        dproto::write_ctl_msg(&mut *ws, &CtlMsg::List)?;
    }

    let child_exit = Arc::new(AtomicI32::new(i32::MIN));
    let done = Arc::new(AtomicBool::new(false));
    let agent_list = Arc::new(Mutex::new(Vec::<AgentInfo>::new()));
    let in_selector = Arc::new(AtomicBool::new(false));

    watch_resize();

    // Reader thread: daemon -> stdout / handle control frames.
    let reader = {
        let child_exit = Arc::clone(&child_exit);
        let done = Arc::clone(&done);
        let current_inst_arc = Arc::clone(&current_inst_arc);
        let agent_list = Arc::clone(&agent_list);
        let in_selector = Arc::clone(&in_selector);
        let mut read_stream = read_stream;
        std::thread::spawn(move || {
            let mut out = std::io::stdout();
            loop {
                match dproto::read_ctl_reply(&mut read_stream) {
                    Ok(Some(CtlReply::Output { instance, data })) => {
                        let cur = current_inst_arc.lock().unwrap().clone();
                        // Only pass through output when matching the currently attached agent
                        // and not currently suppressed by the selector overlay.
                        if instance == cur && !in_selector.load(Ordering::SeqCst) {
                            let _ = out.write_all(&data);
                            let _ = out.flush();
                        }
                    }
                    Ok(Some(CtlReply::ChildExited { instance, code })) => {
                        let cur = current_inst_arc.lock().unwrap().clone();
                        if instance == cur {
                            child_exit.store(code, Ordering::SeqCst);
                            done.store(true, Ordering::SeqCst);
                            break;
                        }
                    }
                    Ok(Some(CtlReply::AgentList(list))) => {
                        *agent_list.lock().unwrap() = list;
                    }
                    Ok(Some(_)) => {}
                    Ok(None) | Err(_) => {
                        done.store(true, Ordering::SeqCst);
                        break;
                    }
                }
            }
        })
    };

    // stdin reader thread -> channel (portable non-blocking).
    let (in_tx, in_rx) = std::sync::mpsc::channel::<Vec<u8>>();
    let stdin_reader = spawn_stdin_reader(Arc::clone(&done), in_tx);

    let mut prefix_sm = PrefixStateMachine::new();

    let outcome = loop {
        if done.load(Ordering::SeqCst) {
            let code = child_exit.load(Ordering::SeqCst);
            if code != i32::MIN {
                break AttachOutcome::ChildExited(code);
            }
            break AttachOutcome::Disconnected;
        }

        // Pending resize from SIGWINCH.
        if take_resize() {
            if let Some((rows, cols)) = current_winsize() {
                let inst = current_inst_arc.lock().unwrap().clone();
                let mut ws = write_stream.lock().unwrap();
                let _ = dproto::write_ctl_msg(
                    &mut *ws,
                    &CtlMsg::Resize {
                        instance: inst,
                        rows,
                        cols,
                    },
                );
            }
        }

        // Check if prefix key timed out (1000ms)
        let timeout_actions = prefix_sm.check_timeout(Instant::now());
        for action in timeout_actions {
            if let PrefixAction::Passthrough(data) = action {
                let inst = current_inst_arc.lock().unwrap().clone();
                let mut ws = write_stream.lock().unwrap();
                let _ = dproto::write_ctl_msg(
                    &mut *ws,
                    &CtlMsg::Input {
                        instance: inst,
                        data,
                    },
                );
            }
        }

        let recv_wait = match prefix_sm.time_until_timeout(Instant::now()) {
            Some(rem) => rem.min(Duration::from_millis(50)),
            None => Duration::from_millis(50),
        };

        match in_rx.recv_timeout(recv_wait) {
            Ok(chunk) => {
                let actions = prefix_sm.feed_chunk(&chunk, Instant::now());
                let mut should_detach = false;

                for action in actions {
                    match action {
                        PrefixAction::Passthrough(data) => {
                            let inst = current_inst_arc.lock().unwrap().clone();
                            let mut ws = write_stream.lock().unwrap();
                            let _ = dproto::write_ctl_msg(
                                &mut *ws,
                                &CtlMsg::Input {
                                    instance: inst,
                                    data,
                                },
                            );
                        }
                        PrefixAction::NextAgent => {
                            let list = agent_list.lock().unwrap().clone();
                            let cur = current_inst_arc.lock().unwrap().clone();
                            if let Some(next_inst) = cycle_agent(&list, &cur, true) {
                                if next_inst != cur {
                                    let mut ws = write_stream.lock().unwrap();
                                    let _ = switch_agent(&mut *ws, &cur, &next_inst);
                                    *current_inst_arc.lock().unwrap() = next_inst;
                                }
                            }
                        }
                        PrefixAction::PrevAgent => {
                            let list = agent_list.lock().unwrap().clone();
                            let cur = current_inst_arc.lock().unwrap().clone();
                            if let Some(prev_inst) = cycle_agent(&list, &cur, false) {
                                if prev_inst != cur {
                                    let mut ws = write_stream.lock().unwrap();
                                    let _ = switch_agent(&mut *ws, &cur, &prev_inst);
                                    *current_inst_arc.lock().unwrap() = prev_inst;
                                }
                            }
                        }
                        PrefixAction::OpenSelector => {
                            // Request fresh agent list
                            {
                                let mut ws = write_stream.lock().unwrap();
                                let _ = dproto::write_ctl_msg(&mut *ws, &CtlMsg::List);
                            }

                            // Enter alternate screen overlay
                            in_selector.store(true, Ordering::SeqCst);
                            let switch_target = run_selector_overlay(
                                &in_rx,
                                &done,
                                &agent_list,
                                &current_inst_arc,
                                &write_stream,
                            );
                            in_selector.store(false, Ordering::SeqCst);

                            let old_inst = current_inst_arc.lock().unwrap().clone();
                            if let Some(new_inst) = switch_target {
                                let mut ws = write_stream.lock().unwrap();
                                let _ = switch_agent(&mut *ws, &old_inst, &new_inst);
                                if new_inst != old_inst {
                                    *current_inst_arc.lock().unwrap() = new_inst;
                                }
                            } else {
                                // Cancelled: restore primary screen and nudge resize
                                let mut ws = write_stream.lock().unwrap();
                                let _ = switch_agent(&mut *ws, &old_inst, &old_inst);
                            }
                        }
                        PrefixAction::Detach => {
                            let inst = current_inst_arc.lock().unwrap().clone();
                            let mut ws = write_stream.lock().unwrap();
                            let _ = dproto::write_ctl_msg(&mut *ws, &CtlMsg::Detach { instance: inst });
                            should_detach = true;
                            break;
                        }
                    }
                }

                if should_detach {
                    break AttachOutcome::Detached;
                }
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
    let _ = write_stream.lock().unwrap().shutdown(std::net::Shutdown::Both);
    let _ = stdin_reader.join();
    let _ = reader.join();
    Ok(outcome)
}

/// Run the interactive fullscreen agent selector overlay on the alternate screen buffer.
/// Returns `Some(target_instance_id)` if an agent was chosen, or `None` if cancelled.
fn run_selector_overlay(
    in_rx: &std::sync::mpsc::Receiver<Vec<u8>>,
    done: &Arc<AtomicBool>,
    agent_list: &Arc<Mutex<Vec<AgentInfo>>>,
    current_inst_arc: &Arc<Mutex<String>>,
    write_stream: &Arc<Mutex<UnixStream>>,
) -> Option<String> {
    let current_inst = current_inst_arc.lock().unwrap().clone();
    let initial_items = to_selector_items(&agent_list.lock().unwrap());
    let mut state = SelectorState::new(current_inst, initial_items);

    // 1. Enter alternate screen buffer (ESC[?1049h)
    let mut stdout = std::io::stdout();
    let _ = crossterm::execute!(stdout, crossterm::terminal::EnterAlternateScreen);
    let _ = stdout.flush();

    let backend = ratatui::backend::CrosstermBackend::new(stdout);
    let mut terminal = match Terminal::new(backend) {
        Ok(t) => t,
        Err(_) => {
            let mut out = std::io::stdout();
            let _ = crossterm::execute!(out, crossterm::terminal::LeaveAlternateScreen);
            let _ = out.flush();
            return None;
        }
    };

    let mut last_list_poll = std::time::Instant::now();
    let mut chosen_instance: Option<String> = None;

    loop {
        if done.load(Ordering::SeqCst) {
            break;
        }

        // Periodically refresh agent list while selector is open
        if last_list_poll.elapsed() >= Duration::from_millis(500) {
            if let Ok(mut ws) = write_stream.lock() {
                let _ = dproto::write_ctl_msg(&mut *ws, &CtlMsg::List);
            }
            last_list_poll = std::time::Instant::now();
        }

        // Update items from background reader
        {
            let list = agent_list.lock().unwrap();
            let items = to_selector_items(&list);
            state.set_items(items);
        }

        let _ = terminal.draw(|f| draw_selector(f, &mut state));

        match in_rx.recv_timeout(Duration::from_millis(50)) {
            Ok(chunk) => {
                let keys = parse_keys_from_bytes(&chunk);
                let mut should_exit = false;
                for key in keys {
                    match state.handle_key(key) {
                        SelectorAction::None => {}
                        SelectorAction::Cancel => {
                            chosen_instance = None;
                            should_exit = true;
                            break;
                        }
                        SelectorAction::Switch(target) => {
                            chosen_instance = Some(target);
                            should_exit = true;
                            break;
                        }
                        SelectorAction::Kill(instance) => {
                            if let Ok(mut ws) = write_stream.lock() {
                                let _ = dproto::write_ctl_msg(&mut *ws, &CtlMsg::Close { instance });
                                let _ = dproto::write_ctl_msg(&mut *ws, &CtlMsg::List);
                            }
                        }
                        SelectorAction::Restart(instance) => {
                            if let Ok(mut ws) = write_stream.lock() {
                                let _ = dproto::write_ctl_msg(&mut *ws, &CtlMsg::Restart { instance });
                                let _ = dproto::write_ctl_msg(&mut *ws, &CtlMsg::List);
                            }
                        }
                    }
                }
                if should_exit {
                    break;
                }
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }

    // 2. Exit alternate screen buffer (ESC[?1049l)
    let _ = crossterm::execute!(
        terminal.backend_mut(),
        crossterm::terminal::LeaveAlternateScreen
    );
    let _ = terminal.show_cursor();
    let _ = terminal.backend_mut().flush();

    chosen_instance
}

fn to_selector_items(list: &[AgentInfo]) -> Vec<SelectorItem> {
    let now = now_secs();
    list.iter()
        .map(|a| {
            let runtime = if a.started_at > 0 && now >= a.started_at {
                now - a.started_at
            } else {
                0
            };
            let cwd = resolve_instance_cwd(&a.instance_id);
            SelectorItem {
                instance_id: a.instance_id.clone(),
                program: a.program.clone(),
                cwd,
                runtime_secs: runtime,
                pid: a.pid,
                alive: a.alive,
                last_activity_secs: a.last_activity,
                display_name: a.display_name.clone(),
            }
        })
        .collect()
}

/// Helper to inspect the working directory or project for an instance from bootstrap.
fn resolve_instance_cwd(instance_id: &str) -> Option<String> {
    let base = format!("/tmp/heimdall-bridge-local/instances/{instance_id}/AGENTS.md");
    if let Ok(content) = std::fs::read_to_string(&base) {
        for line in content.lines() {
            let trimmed = line.trim();
            if trimmed.starts_with("- Path:") {
                let p = trimmed.trim_start_matches("- Path:").trim();
                if !p.is_empty() {
                    return Some(p.to_string());
                }
            }
        }
    }
    None
}

/// Render the fullscreen agent selector TUI.
fn draw_selector(f: &mut ratatui::Frame, state: &mut SelectorState) {
    let size = f.area();
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3), // Search bar
            Constraint::Min(0),    // Agents list
            Constraint::Length(1), // Footer status / shortcuts
        ])
        .split(size);

    // Search bar
    let search_block = Block::default()
        .borders(Borders::ALL)
        .title(" Switch Agent (Ctrl-Space) · Fuzzy Filter ")
        .border_style(Style::default().fg(Color::Cyan));
    let search_text = format!("🔍 {}", state.query);
    let search_p = Paragraph::new(Line::from(Span::styled(
        search_text,
        Style::default().fg(Color::White).add_modifier(Modifier::BOLD),
    )))
    .block(search_block);
    f.render_widget(search_p, chunks[0]);

    // Agents list
    let total = state.filtered_indices.len();
    let list_title = format!(" Agents ({}/{}) ", total, state.all_items.len());
    let list_block = Block::default()
        .borders(Borders::ALL)
        .title(list_title)
        .border_style(Style::default().fg(Color::White));
    let inner = list_block.inner(chunks[1]);
    f.render_widget(list_block, chunks[1]);

    let height = inner.height as usize;
    let scroll = state.ensure_visible(height);
    let now = now_secs();

    let list_items: Vec<ListItem> = state
        .filtered_indices
        .iter()
        .skip(scroll)
        .take(height)
        .enumerate()
        .map(|(rel_idx, &actual_idx)| {
            let item = &state.all_items[actual_idx];
            let is_selected = (scroll + rel_idx) == state.selected;
            let is_current = item.instance_id == state.current_instance;

            let marker = if is_selected {
                "▶ "
            } else if is_current {
                "• "
            } else {
                "  "
            };

            let dot = if item.alive { "●" } else { "○" };
            let dot_style = if item.alive {
                Style::default().fg(Color::Green)
            } else {
                Style::default().fg(Color::DarkGray)
            };

            let cwd_str = item.cwd.as_deref().unwrap_or("-");
            let runtime_str = item.format_runtime();
            let activity_str = item.format_activity(now);

            let primary_label = match &item.display_name {
                Some(d) if !d.trim().is_empty() => d.as_str(),
                _ => &item.instance_id,
            };

            let row_spans = vec![
                Span::styled(marker, Style::default().add_modifier(Modifier::BOLD)),
                Span::styled(dot, dot_style),
                Span::raw(" "),
                Span::styled(
                    format!("{:<28}", primary_label),
                    Style::default().add_modifier(Modifier::BOLD),
                ),
                Span::styled(format!("{:<10} ", item.program), Style::default().fg(Color::Yellow)),
                Span::styled(format!("dir: {:<24} ", cwd_str), Style::default().fg(Color::Cyan)),
                Span::styled(format!("up: {:<8} ", runtime_str), Style::default().fg(Color::Magenta)),
                Span::styled(format!("activity: {:<12}", activity_str), Style::default().fg(Color::DarkGray)),
            ];

            let row_style = if is_selected {
                Style::default().fg(Color::Black).bg(Color::Cyan)
            } else if is_current {
                Style::default().fg(Color::White).add_modifier(Modifier::BOLD)
            } else if item.alive {
                Style::default().fg(Color::Gray)
            } else {
                Style::default().fg(Color::DarkGray)
            };

            ListItem::new(Line::from(row_spans)).style(row_style)
        })
        .collect();

    f.render_widget(List::new(list_items), inner);

    // Footer
    let footer_text = Line::from(vec![
        Span::styled(" [Enter] ", Style::default().fg(Color::Black).bg(Color::Cyan).add_modifier(Modifier::BOLD)),
        Span::raw(" Switch  "),
        Span::styled(" [Ctrl-X] ", Style::default().fg(Color::Black).bg(Color::Red).add_modifier(Modifier::BOLD)),
        Span::raw(" Kill  "),
        Span::styled(" [Ctrl-R] ", Style::default().fg(Color::Black).bg(Color::Yellow).add_modifier(Modifier::BOLD)),
        Span::raw(" Restart  "),
        Span::styled(" [↑/↓] ", Style::default().fg(Color::Black).bg(Color::White)),
        Span::raw(" Select  "),
        Span::styled(" [Esc/Ctrl-C] ", Style::default().fg(Color::Black).bg(Color::White)),
        Span::raw(" Cancel  "),
        Span::styled(" [Ctrl-U] ", Style::default().fg(Color::Black).bg(Color::White)),
        Span::raw(" Clear search"),
    ]);
    f.render_widget(Paragraph::new(footer_text), chunks[2]);
}

/// Parse raw terminal input bytes into [`Key`] events for the selector.
fn parse_keys_from_bytes(bytes: &[u8]) -> Vec<Key> {
    let mut keys = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        if b == 0x1b {
            // Escape sequences
            if i + 1 >= bytes.len() {
                keys.push(Key::Esc);
                i += 1;
                continue;
            }
            if bytes[i + 1] == b'[' {
                if i + 2 < bytes.len() {
                    match bytes[i + 2] {
                        b'A' => {
                            keys.push(Key::Up);
                            i += 3;
                            continue;
                        }
                        b'B' => {
                            keys.push(Key::Down);
                            i += 3;
                            continue;
                        }
                        b'C' => {
                            keys.push(Key::Right);
                            i += 3;
                            continue;
                        }
                        b'D' => {
                            keys.push(Key::Left);
                            i += 3;
                            continue;
                        }
                        b'H' => {
                            keys.push(Key::Home);
                            i += 3;
                            continue;
                        }
                        b'F' => {
                            keys.push(Key::End);
                            i += 3;
                            continue;
                        }
                        b'3' if i + 3 < bytes.len() && bytes[i + 3] == b'~' => {
                            keys.push(Key::Delete);
                            i += 4;
                            continue;
                        }
                        b'5' if i + 3 < bytes.len() && bytes[i + 3] == b'~' => {
                            keys.push(Key::PageUp);
                            i += 4;
                            continue;
                        }
                        b'6' if i + 3 < bytes.len() && bytes[i + 3] == b'~' => {
                            keys.push(Key::PageDown);
                            i += 4;
                            continue;
                        }
                        _ => {}
                    }
                }
            }
            keys.push(Key::Esc);
            i += 1;
            continue;
        }

        match b {
            0x00 => keys.push(Key::Ctrl(' ')),
            0x03 => keys.push(Key::Ctrl('c')),
            0x08 | 0x7f => keys.push(Key::Backspace),
            0x09 => keys.push(Key::Tab),
            0x0d | 0x0a => keys.push(Key::Enter),
            0x12 => keys.push(Key::Ctrl('r')),
            0x15 => keys.push(Key::Ctrl('u')),
            0x17 => keys.push(Key::Ctrl('w')),
            0x18 => keys.push(Key::Ctrl('x')),
            b if b >= 0x20 && b <= 0x7e => keys.push(Key::Char(b as char)),
            _ => keys.push(Key::Other),
        }
        i += 1;
    }
    keys
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    fn make_agent(id: &str) -> AgentInfo {
        AgentInfo {
            instance_id: id.to_string(),
            program: "bash".to_string(),
            pid: 1000,
            alive: true,
            exit_code: None,
            rows: 24,
            cols: 80,
            started_at: 0,
            last_activity: 0,
            display_name: None,
        }
    }

    #[test]
    fn test_prefix_state_machine_passthrough_normal_keys() {
        let mut sm = PrefixStateMachine::new();
        let now = Instant::now();
        let actions = sm.feed_chunk(b"hello world", now);
        assert_eq!(actions, vec![PrefixAction::Passthrough(b"hello world".to_vec())]);
        assert_eq!(sm.state(), PrefixState::Idle);
    }

    #[test]
    fn test_prefix_state_machine_ctrl_b_n_cycles_next() {
        let mut sm = PrefixStateMachine::new();
        let now = Instant::now();
        // b'n'
        let actions = sm.feed_chunk(&[0x02, b'n'], now);
        assert_eq!(actions, vec![PrefixAction::NextAgent]);
        assert_eq!(sm.state(), PrefixState::Idle);

        // Ctrl-n (0x0e)
        let actions2 = sm.feed_chunk(&[0x02, 0x0e], now);
        assert_eq!(actions2, vec![PrefixAction::NextAgent]);
        assert_eq!(sm.state(), PrefixState::Idle);
    }

    #[test]
    fn test_prefix_state_machine_ctrl_b_p_cycles_prev() {
        let mut sm = PrefixStateMachine::new();
        let now = Instant::now();
        // b'p'
        let actions = sm.feed_chunk(&[0x02, b'p'], now);
        assert_eq!(actions, vec![PrefixAction::PrevAgent]);
        assert_eq!(sm.state(), PrefixState::Idle);

        // Ctrl-p (0x10)
        let actions2 = sm.feed_chunk(&[0x02, 0x10], now);
        assert_eq!(actions2, vec![PrefixAction::PrevAgent]);
        assert_eq!(sm.state(), PrefixState::Idle);
    }

    #[test]
    fn test_prefix_state_machine_ctrl_b_ctrl_b_literal() {
        let mut sm = PrefixStateMachine::new();
        let now = Instant::now();
        // Ctrl-b followed by Ctrl-b: literal 0x02 to child PTY
        let actions = sm.feed_chunk(&[0x02, 0x02], now);
        assert_eq!(actions, vec![PrefixAction::Passthrough(vec![0x02])]);
        assert_eq!(sm.state(), PrefixState::Idle);
    }

    #[test]
    fn test_prefix_state_machine_ctrl_b_other_byte() {
        let mut sm = PrefixStateMachine::new();
        let now = Instant::now();
        // Ctrl-b followed by another byte (e.g. b'x'): forwards [0x02, b'x']
        let actions = sm.feed_chunk(&[0x02, b'x'], now);
        assert_eq!(actions, vec![PrefixAction::Passthrough(vec![0x02, b'x'])]);
        assert_eq!(sm.state(), PrefixState::Idle);
    }

    #[test]
    fn test_prefix_state_machine_timeout() {
        let mut sm = PrefixStateMachine::new();
        let t0 = Instant::now();
        let actions1 = sm.feed_chunk(&[0x02], t0);
        assert!(actions1.is_empty());
        assert!(matches!(sm.state(), PrefixState::PrefixPending(_)));

        // Not yet timed out
        let actions2 = sm.check_timeout(t0 + Duration::from_millis(500));
        assert!(actions2.is_empty());
        assert!(matches!(sm.state(), PrefixState::PrefixPending(_)));

        // Timed out at 1000ms
        let actions3 = sm.check_timeout(t0 + Duration::from_millis(1000));
        assert_eq!(actions3, vec![PrefixAction::Passthrough(vec![0x02])]);
        assert_eq!(sm.state(), PrefixState::Idle);

        // Subsequent byte is normal passthrough
        let actions4 = sm.feed_chunk(b"a", t0 + Duration::from_millis(1100));
        assert_eq!(actions4, vec![PrefixAction::Passthrough(b"a".to_vec())]);
    }

    #[test]
    fn test_prefix_state_machine_timeout_on_next_feed() {
        let mut sm = PrefixStateMachine::new();
        let t0 = Instant::now();
        let actions1 = sm.feed_chunk(&[0x02], t0);
        assert!(actions1.is_empty());

        // Feeding next byte after 1500ms without explicit check_timeout
        let actions2 = sm.feed_chunk(b"k", t0 + Duration::from_millis(1500));
        assert_eq!(actions2, vec![PrefixAction::Passthrough(vec![0x02, b'k'])]);
        assert_eq!(sm.state(), PrefixState::Idle);
    }

    #[test]
    fn test_prefix_state_machine_ctrl_backslash_detach() {
        let mut sm = PrefixStateMachine::new();
        let now = Instant::now();
        let actions = sm.feed_chunk(&[0x1c], now);
        assert_eq!(actions, vec![PrefixAction::Detach]);

        // Ctrl-b followed by Ctrl-\: forward [0x02] then Detach
        let actions2 = sm.feed_chunk(&[0x02, 0x1c], now);
        assert_eq!(actions2, vec![PrefixAction::Passthrough(vec![0x02]), PrefixAction::Detach]);
    }

    #[test]
    fn test_prefix_state_machine_ctrl_space_selector() {
        let mut sm = PrefixStateMachine::new();
        let now = Instant::now();
        let actions = sm.feed_chunk(&[0x00], now);
        assert_eq!(actions, vec![PrefixAction::OpenSelector]);

        // Ctrl-b followed by Ctrl-Space: forward [0x02] then OpenSelector
        let actions2 = sm.feed_chunk(&[0x02, 0x00], now);
        assert_eq!(actions2, vec![PrefixAction::Passthrough(vec![0x02]), PrefixAction::OpenSelector]);
    }

    #[test]
    fn test_prefix_state_machine_interleaved_chunk() {
        let mut sm = PrefixStateMachine::new();
        let now = Instant::now();
        let chunk = vec![b'a', b'b', 0x02, b'n', b'c'];
        let actions = sm.feed_chunk(&chunk, now);
        assert_eq!(
            actions,
            vec![
                PrefixAction::Passthrough(vec![b'a', b'b']),
                PrefixAction::NextAgent,
                PrefixAction::Passthrough(vec![b'c']),
            ]
        );
    }

    #[test]
    fn test_cycle_agent_empty_and_single() {
        assert_eq!(cycle_agent(&[], "any", true), None);
        assert_eq!(cycle_agent(&[], "any", false), None);

        let list = vec![make_agent("inst-1")];
        assert_eq!(cycle_agent(&list, "inst-1", true), Some("inst-1".to_string()));
        assert_eq!(cycle_agent(&list, "inst-1", false), Some("inst-1".to_string()));
        assert_eq!(cycle_agent(&list, "unknown", true), Some("inst-1".to_string()));
    }

    #[test]
    fn test_cycle_agent_multiple_forward_and_backward() {
        let list = vec![
            make_agent("inst-1"),
            make_agent("inst-2"),
            make_agent("inst-3"),
        ];

        // Forward cycling with wraparound
        assert_eq!(cycle_agent(&list, "inst-1", true), Some("inst-2".to_string()));
        assert_eq!(cycle_agent(&list, "inst-2", true), Some("inst-3".to_string()));
        assert_eq!(cycle_agent(&list, "inst-3", true), Some("inst-1".to_string()));

        // Backward cycling with wraparound
        assert_eq!(cycle_agent(&list, "inst-1", false), Some("inst-3".to_string()));
        assert_eq!(cycle_agent(&list, "inst-3", false), Some("inst-2".to_string()));
        assert_eq!(cycle_agent(&list, "inst-2", false), Some("inst-1".to_string()));

        // Unknown instance defaults to index 0, then cycles
        assert_eq!(cycle_agent(&list, "nonexistent", true), Some("inst-2".to_string()));
        assert_eq!(cycle_agent(&list, "nonexistent", false), Some("inst-3".to_string()));
    }

    #[test]
    fn test_parse_keys_from_bytes_ctrl_x_and_r() {
        // 0x18 is Ctrl-x, 0x12 is Ctrl-r
        let keys = parse_keys_from_bytes(&[0x18, 0x12, 0x00, 0x03, 0x0d, 0x1b]);
        assert_eq!(
            keys,
            vec![
                Key::Ctrl('x'),
                Key::Ctrl('r'),
                Key::Ctrl(' '),
                Key::Ctrl('c'),
                Key::Enter,
                Key::Esc,
            ]
        );
    }
}

