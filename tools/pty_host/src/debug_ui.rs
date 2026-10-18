//! REQ PTYH-3: the ratatui/crossterm terminal runtime for the debug TUI.
//!
//! This module is the thin I/O shell around the pure state machine in
//! [`crate::debug_tui`]: it owns the alternate screen, translates crossterm
//! key events into [`debug_tui::Key`], drives a background socket reader that
//! feeds Screen/ChildExited frames into the app, and renders the split layout.

use crate::ipc::UnixStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context, Result};
use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyModifiers};
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, List, ListItem, Paragraph, Wrap};
use ratatui::Terminal;

use crate::debug_tui::{
    AppState, Field, Focus, Key, NAMED_KEY_CHOICES,
};
use crate::proto::{self, ClientMsg, HostMsg};

/// Run the debug TUI attached to the host at `socket_path`.
pub fn run(socket_path: &std::path::Path) -> Result<()> {
    let stream = UnixStream::connect(socket_path)
        .with_context(|| format!("connect to host socket {socket_path:?}"))?;
    let mut write_stream = stream.try_clone().context("clone socket")?;
    let read_stream = stream;

    // Background reader: host -> app frames.
    let (frame_tx, frame_rx) = mpsc::channel::<HostMsg>();
    let reader_done = Arc::new(AtomicBool::new(false));
    {
        let reader_done = Arc::clone(&reader_done);
        let mut rs = read_stream;
        std::thread::spawn(move || loop {
            match proto::read_host_msg(&mut rs) {
                Ok(Some(msg)) => {
                    let stop = matches!(msg, HostMsg::ChildExited(_));
                    if frame_tx.send(msg).is_err() || stop {
                        break;
                    }
                }
                Ok(None) | Err(_) => {
                    reader_done.store(true, Ordering::SeqCst);
                    break;
                }
            }
        });
    }

    // Attach + prime an initial capture.
    proto::write_client_msg(&mut write_stream, &ClientMsg::Attach)?;
    proto::write_client_msg(&mut write_stream, &ClientMsg::Capture)?;

    let mut app = AppState::default();
    let write_stream = Arc::new(Mutex::new(write_stream));

    // ---- terminal setup (alternate screen + raw mode) ------------------
    let mut term = setup_terminal().context("setup terminal")?;
    let res = event_loop(&mut term, &mut app, &frame_rx, &write_stream, &reader_done);
    restore_terminal(&mut term).ok();
    res
}

type Backend = ratatui::backend::CrosstermBackend<std::io::Stdout>;

fn setup_terminal() -> Result<Terminal<Backend>> {
    crossterm::terminal::enable_raw_mode()?;
    let mut stdout = std::io::stdout();
    crossterm::execute!(
        stdout,
        crossterm::terminal::EnterAlternateScreen,
        crossterm::event::EnableMouseCapture
    )?;
    let backend = ratatui::backend::CrosstermBackend::new(stdout);
    Ok(Terminal::new(backend)?)
}

fn restore_terminal(term: &mut Terminal<Backend>) -> Result<()> {
    crossterm::terminal::disable_raw_mode()?;
    crossterm::execute!(
        term.backend_mut(),
        crossterm::terminal::LeaveAlternateScreen,
        crossterm::event::DisableMouseCapture
    )?;
    term.show_cursor()?;
    Ok(())
}

fn event_loop(
    term: &mut Terminal<Backend>,
    app: &mut AppState,
    frame_rx: &Receiver<HostMsg>,
    write_stream: &Arc<Mutex<UnixStream>>,
    reader_done: &Arc<AtomicBool>,
) -> Result<()> {
    let mut last_capture = std::time::Instant::now();
    loop {
        // Drain any host frames into app state.
        while let Ok(msg) = frame_rx.try_recv() {
            match msg {
                HostMsg::Screen(s) => app.latest = Some(s),
                HostMsg::Output(_) => { /* left pane uses Screen frames */ }
                HostMsg::ChildExited(code) => {
                    app.child_exit = Some(code);
                    app.status = format!("child exited ({code}) — press any key to quit");
                }
                HostMsg::Pong => {}
            }
        }

        term.draw(|f| draw(f, app))?;

        // Periodically request a fresh Screen so the left pane stays live.
        if last_capture.elapsed() >= Duration::from_millis(120) {
            if let Ok(mut w) = write_stream.lock() {
                let _ = proto::write_client_msg(&mut *w, &ClientMsg::Capture);
            }
            last_capture = std::time::Instant::now();
        }

        // Poll for a key with a short timeout so we keep refreshing.
        if event::poll(Duration::from_millis(60))? {
            if let Event::Key(ke) = event::read()? {
                if ke.kind == crossterm::event::KeyEventKind::Press
                    || ke.kind == crossterm::event::KeyEventKind::Repeat
                {
                    if let Some(key) = translate_key(ke) {
                        // If the child already exited, any key quits.
                        if app.child_exit.is_some() {
                            app.should_quit = true;
                        } else {
                            let outcome = app.handle_key(key);
                            if let Ok(mut w) = write_stream.lock() {
                                for m in &outcome.messages {
                                    let _ = proto::write_client_msg(&mut *w, m);
                                }
                            }
                        }
                    }
                }
            }
        }

        if app.should_quit {
            break;
        }
        if reader_done.load(Ordering::SeqCst) && app.child_exit.is_none() {
            app.status = "disconnected from host".into();
            // Draw one last frame then exit.
            term.draw(|f| draw(f, app))?;
            std::thread::sleep(Duration::from_millis(300));
            break;
        }
    }
    Ok(())
}

/// Translate a crossterm key event into our abstract [`Key`].
fn translate_key(ke: KeyEvent) -> Option<Key> {
    // Global shortcuts.
    match ke.code {
        KeyCode::F(2) => return Some(Key::ToggleFocus),
        KeyCode::F(10) => return Some(Key::Quit),
        _ => {}
    }
    let ctrl = ke.modifiers.contains(KeyModifiers::CONTROL);
    Some(match ke.code {
        KeyCode::Char(c) if ctrl => Key::Ctrl(c),
        KeyCode::Char(c) => Key::Char(c),
        KeyCode::Enter => Key::Enter,
        KeyCode::Esc => Key::Esc,
        KeyCode::Tab => Key::Tab,
        KeyCode::BackTab => Key::BackTab,
        KeyCode::Backspace => Key::Backspace,
        KeyCode::Up => Key::Up,
        KeyCode::Down => Key::Down,
        KeyCode::Left => Key::Left,
        KeyCode::Right => Key::Right,
        KeyCode::Home => Key::Home,
        KeyCode::End => Key::End,
        KeyCode::Delete => Key::Delete,
        KeyCode::PageUp => Key::PageUp,
        KeyCode::PageDown => Key::PageDown,
        _ => Key::Other,
    })
}

// ---- rendering ----------------------------------------------------------

fn draw(f: &mut ratatui::Frame, app: &AppState) {
    let size = f.area();
    // Top banner + body.
    let vert = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(1), Constraint::Min(0), Constraint::Length(1)])
        .split(size);
    draw_banner(f, vert[0], app);
    draw_status(f, vert[2], app);

    // Body: left pane | right sidebar.
    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(65), Constraint::Percentage(35)])
        .split(vert[1]);
    draw_pane(f, cols[0], app);
    draw_sidebar(f, cols[1], app);
}

fn draw_banner(f: &mut ratatui::Frame, area: Rect, app: &AppState) {
    let focus = match app.focus {
        Focus::Pane => "PANE",
        Focus::Sidebar => "SIDEBAR",
    };
    let banner = Line::from(vec![
        Span::styled(
            " ham-pty-host ",
            Style::default()
                .fg(Color::Black)
                .bg(Color::Cyan)
                .add_modifier(Modifier::BOLD),
        ),
        Span::raw(" debug TUI · focus: "),
        Span::styled(
            focus,
            Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD),
        ),
        Span::raw("  [F2] toggle focus  [F10] detach+quit"),
    ]);
    f.render_widget(Paragraph::new(banner), area);
}

fn draw_status(f: &mut ratatui::Frame, area: Rect, app: &AppState) {
    let style = if app.child_exit.is_some() {
        Style::default().fg(Color::Red).add_modifier(Modifier::BOLD)
    } else {
        Style::default().fg(Color::DarkGray)
    };
    f.render_widget(Paragraph::new(Line::from(Span::styled(app.status.clone(), style))), area);
}

fn draw_pane(f: &mut ratatui::Frame, area: Rect, app: &AppState) {
    let focused = app.focus == Focus::Pane;
    let block = Block::default()
        .borders(Borders::ALL)
        .title(" live pane (VT model) ")
        .border_style(border_style(focused));

    let text: Vec<Line> = match &app.latest {
        Some(s) => s
            .lines
            .iter()
            .map(|l| Line::from(l.clone()))
            .collect(),
        None => vec![Line::from(Span::styled(
            "waiting for first Screen frame…",
            Style::default().fg(Color::DarkGray),
        ))],
    };
    f.render_widget(Paragraph::new(text).block(block), area);
}

fn draw_sidebar(f: &mut ratatui::Frame, area: Rect, app: &AppState) {
    let focused = app.focus == Focus::Sidebar;
    let outer = Block::default()
        .borders(Borders::ALL)
        .title(" debug sidebar ")
        .border_style(border_style(focused));
    let inner = outer.inner(area);
    f.render_widget(outer, area);

    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3), // send keys
            Constraint::Length(NAMED_KEY_CHOICES.len() as u16 + 2), // named keys
            Constraint::Length(3), // resize
            Constraint::Min(4),    // captures
        ])
        .split(inner);

    draw_send_keys(f, rows[0], app);
    draw_named_keys(f, rows[1], app);
    draw_resize(f, rows[2], app);
    draw_captures(f, rows[3], app);
}

fn draw_send_keys(f: &mut ratatui::Frame, area: Rect, app: &AppState) {
    let active = app.focus == Focus::Sidebar && app.field == Field::SendKeys;
    let block = Block::default()
        .borders(Borders::ALL)
        .title(" Send Keys (Enter=send) ")
        .border_style(field_style(active));
    let shown = if active {
        format!("{}\u{2588}", app.send_buf) // block cursor
    } else {
        app.send_buf.clone()
    };
    f.render_widget(Paragraph::new(shown).block(block), area);
}

fn draw_named_keys(f: &mut ratatui::Frame, area: Rect, app: &AppState) {
    let active = app.focus == Focus::Sidebar && app.field == Field::NamedKeys;
    let items: Vec<ListItem> = NAMED_KEY_CHOICES
        .iter()
        .enumerate()
        .map(|(i, (_, label))| {
            let selected = i == app.named_sel;
            let marker = if selected { "▶ " } else { "  " };
            let style = if selected && active {
                Style::default().fg(Color::Black).bg(Color::Yellow)
            } else if selected {
                Style::default().add_modifier(Modifier::BOLD)
            } else {
                Style::default()
            };
            ListItem::new(Line::from(Span::styled(format!("{marker}{label}"), style)))
        })
        .collect();
    let block = Block::default()
        .borders(Borders::ALL)
        .title(" Named Key (↑↓, Enter) ")
        .border_style(field_style(active));
    f.render_widget(List::new(items).block(block), area);
}

fn draw_resize(f: &mut ratatui::Frame, area: Rect, app: &AppState) {
    let active = app.focus == Focus::Sidebar && app.field == Field::Resize;
    let block = Block::default()
        .borders(Borders::ALL)
        .title(" Resize ROWSxCOLS ")
        .border_style(field_style(active));
    let shown = if active {
        format!("{}\u{2588}", app.resize_buf)
    } else if app.resize_buf.is_empty() {
        "e.g. 40x120".to_string()
    } else {
        app.resize_buf.clone()
    };
    f.render_widget(Paragraph::new(shown).block(block), area);
}

fn draw_captures(f: &mut ratatui::Frame, area: Rect, app: &AppState) {
    let active = app.focus == Focus::Sidebar && app.field == Field::Capture;
    let block = Block::default()
        .borders(Borders::ALL)
        .title(" Capture (Enter=snapshot) ")
        .border_style(field_style(active));
    let mut lines: Vec<Line> = Vec::new();
    if app.captures.is_empty() {
        lines.push(Line::from(Span::styled(
            "no captures yet",
            Style::default().fg(Color::DarkGray),
        )));
    } else {
        for (i, c) in app.captures.iter().enumerate().rev().take(8) {
            lines.push(Line::from(format!(
                "#{}: {}x{} cur({},{}) {}ln",
                i + 1,
                c.rows,
                c.cols,
                c.cursor_row,
                c.cursor_col,
                c.nonblank_lines
            )));
        }
    }
    f.render_widget(Paragraph::new(lines).block(block).wrap(Wrap { trim: true }), area);
}

fn border_style(focused: bool) -> Style {
    if focused {
        Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD)
    } else {
        Style::default().fg(Color::DarkGray)
    }
}

fn field_style(active: bool) -> Style {
    if active {
        Style::default().fg(Color::Yellow)
    } else {
        Style::default().fg(Color::DarkGray)
    }
}
