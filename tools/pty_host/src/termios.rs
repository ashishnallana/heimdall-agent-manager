//! Local-terminal control for the `attach` clients (REQ PTYH-2): raw mode, the
//! current window size, resize notification and a timed stdin read. All the
//! OS FFI lives here: termios + SIGWINCH on Unix, the console API on Windows.

pub use imp::{current_winsize, read_stdin_timeout, watch_resize, RawGuard};

use std::sync::atomic::{AtomicBool, Ordering};

/// Set when the local terminal was resized; drained by [`take_resize`].
static RESIZED: AtomicBool = AtomicBool::new(false);

/// Whether the terminal was resized since the last call (after
/// [`watch_resize`] has been installed).
pub fn take_resize() -> bool {
    RESIZED.swap(false, Ordering::SeqCst)
}

#[cfg(unix)]
mod imp {
    use std::os::unix::io::RawFd;
    use std::sync::atomic::Ordering;

    use anyhow::{Context, Result};

    const STDIN_FD: RawFd = 0;

    /// RAII guard that puts the terminal in raw mode and restores it on drop.
    pub struct RawGuard {
        fd: RawFd,
        original: libc::termios,
        restored: bool,
    }

    impl RawGuard {
        /// Enable raw mode on stdin. Restores automatically when the guard drops.
        pub fn enable() -> Result<RawGuard> {
            unsafe {
                let mut original: libc::termios = std::mem::zeroed();
                if libc::tcgetattr(STDIN_FD, &mut original) != 0 {
                    return Err(std::io::Error::last_os_error())
                        .context("tcgetattr (not a tty?)");
                }
                let mut raw = original;
                libc::cfmakeraw(&mut raw);
                if libc::tcsetattr(STDIN_FD, libc::TCSANOW, &raw) != 0 {
                    return Err(std::io::Error::last_os_error()).context("tcsetattr raw");
                }
                Ok(RawGuard {
                    fd: STDIN_FD,
                    original,
                    restored: false,
                })
            }
        }

        pub fn restore(&mut self) {
            if !self.restored {
                unsafe {
                    libc::tcsetattr(self.fd, libc::TCSANOW, &self.original);
                }
                self.restored = true;
            }
        }
    }

    impl Drop for RawGuard {
        fn drop(&mut self) {
            self.restore();
        }
    }

    /// The current terminal window size as (rows, cols), if stdout is a tty.
    pub fn current_winsize() -> Option<(u16, u16)> {
        unsafe {
            let mut ws: libc::winsize = std::mem::zeroed();
            if libc::ioctl(libc::STDOUT_FILENO, libc::TIOCGWINSZ, &mut ws) == 0 && ws.ws_row > 0 {
                Some((ws.ws_row, ws.ws_col))
            } else {
                None
            }
        }
    }

    extern "C" fn sigwinch_handler(_sig: i32) {
        super::RESIZED.store(true, Ordering::SeqCst);
    }

    /// Start flagging terminal resizes (SIGWINCH) for [`super::take_resize`].
    pub fn watch_resize() {
        unsafe {
            libc::signal(libc::SIGWINCH, sigwinch_handler as *const () as usize);
        }
    }

    /// Wait up to `timeout_ms` for stdin to become readable, then read once.
    /// `Ok(None)` = nothing to read yet; `Ok(Some(0))` = EOF.
    pub fn read_stdin_timeout(buf: &mut [u8], timeout_ms: i32) -> std::io::Result<Option<usize>> {
        let mut pfd = libc::pollfd {
            fd: libc::STDIN_FILENO,
            events: libc::POLLIN,
            revents: 0,
        };
        let res = unsafe { libc::poll(&mut pfd, 1, timeout_ms) };
        if res <= 0 || (pfd.revents & libc::POLLIN) == 0 {
            return Ok(None);
        }
        match unsafe { libc::read(libc::STDIN_FILENO, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) } {
            n if n >= 0 => Ok(Some(n as usize)),
            _ => Err(std::io::Error::last_os_error()),
        }
    }
}

#[cfg(windows)]
mod imp {
    use std::io::Read;
    use std::sync::atomic::Ordering;
    use std::time::Duration;

    use anyhow::{Context, Result};
    use windows_sys::Win32::Foundation::{HANDLE, WAIT_OBJECT_0};
    use windows_sys::Win32::System::Console::{
        GetConsoleMode, GetStdHandle, PeekConsoleInputW, ReadConsoleInputW, SetConsoleMode,
        CONSOLE_MODE, DISABLE_NEWLINE_AUTO_RETURN, ENABLE_PROCESSED_OUTPUT,
        ENABLE_VIRTUAL_TERMINAL_INPUT, ENABLE_VIRTUAL_TERMINAL_PROCESSING, INPUT_RECORD,
        KEY_EVENT, STD_INPUT_HANDLE, STD_OUTPUT_HANDLE,
    };
    use windows_sys::Win32::System::Threading::WaitForSingleObject;

    /// RAII guard that puts the console in raw VT mode and restores it on drop.
    /// Input: no line editing/echo/Ctrl-C processing, keys arrive as VT bytes.
    /// Output: the child's VT sequences are interpreted, not printed.
    pub struct RawGuard {
        stdin: HANDLE,
        stdout: HANDLE,
        in_mode: CONSOLE_MODE,
        out_mode: Option<CONSOLE_MODE>,
        restored: bool,
    }

    impl RawGuard {
        /// Enable raw mode on the console. Restores automatically when the guard drops.
        pub fn enable() -> Result<RawGuard> {
            unsafe {
                let stdin = GetStdHandle(STD_INPUT_HANDLE);
                let stdout = GetStdHandle(STD_OUTPUT_HANDLE);
                let mut in_mode: CONSOLE_MODE = 0;
                if GetConsoleMode(stdin, &mut in_mode) == 0 {
                    return Err(std::io::Error::last_os_error())
                        .context("GetConsoleMode (not a console?)");
                }
                if SetConsoleMode(stdin, ENABLE_VIRTUAL_TERMINAL_INPUT) == 0 {
                    return Err(std::io::Error::last_os_error()).context("SetConsoleMode raw");
                }
                let mut out_mode: CONSOLE_MODE = 0;
                let out_mode = if GetConsoleMode(stdout, &mut out_mode) != 0 {
                    SetConsoleMode(
                        stdout,
                        out_mode
                            | ENABLE_PROCESSED_OUTPUT
                            | ENABLE_VIRTUAL_TERMINAL_PROCESSING
                            | DISABLE_NEWLINE_AUTO_RETURN,
                    );
                    Some(out_mode)
                } else {
                    None
                };
                Ok(RawGuard {
                    stdin,
                    stdout,
                    in_mode,
                    out_mode,
                    restored: false,
                })
            }
        }

        pub fn restore(&mut self) {
            if !self.restored {
                unsafe {
                    SetConsoleMode(self.stdin, self.in_mode);
                    if let Some(mode) = self.out_mode {
                        SetConsoleMode(self.stdout, mode);
                    }
                }
                self.restored = true;
            }
        }
    }

    impl Drop for RawGuard {
        fn drop(&mut self) {
            self.restore();
        }
    }

    /// The current console window size as (rows, cols), if there is a console.
    pub fn current_winsize() -> Option<(u16, u16)> {
        match crossterm::terminal::size() {
            Ok((cols, rows)) if rows > 0 => Some((rows, cols)),
            _ => None,
        }
    }

    /// Start flagging console resizes for [`super::take_resize`]. Windows has
    /// no SIGWINCH, so a background thread polls the window size.
    pub fn watch_resize() {
        static STARTED: std::sync::Once = std::sync::Once::new();
        STARTED.call_once(|| {
            std::thread::spawn(|| {
                let mut last = current_winsize();
                loop {
                    std::thread::sleep(Duration::from_millis(200));
                    let now = current_winsize();
                    if now != last {
                        last = now;
                        super::RESIZED.store(true, Ordering::SeqCst);
                    }
                }
            });
        });
    }

    /// Wait up to `timeout_ms` for console input that yields bytes, then read
    /// once. `Ok(None)` = nothing to read yet; `Ok(Some(0))` = EOF. Input
    /// records that produce no bytes (key-up, focus, mouse) are discarded so a
    /// read never blocks on them. A redirected stdin is read directly.
    /// `buf` should be at least 8 KiB so reads bypass std's stdin buffer
    /// (bytes left there would not wake the console handle).
    pub fn read_stdin_timeout(buf: &mut [u8], timeout_ms: i32) -> std::io::Result<Option<usize>> {
        unsafe {
            let stdin = GetStdHandle(STD_INPUT_HANDLE);
            let mut mode: CONSOLE_MODE = 0;
            if GetConsoleMode(stdin, &mut mode) != 0 {
                if WaitForSingleObject(stdin, timeout_ms.max(0) as u32) != WAIT_OBJECT_0 {
                    return Ok(None);
                }
                let mut records: [INPUT_RECORD; 64] = std::mem::zeroed();
                let mut n = 0u32;
                if PeekConsoleInputW(stdin, records.as_mut_ptr(), records.len() as u32, &mut n) == 0 {
                    return Err(std::io::Error::last_os_error());
                }
                let has_text = records[..n as usize].iter().any(|r| {
                    r.EventType == KEY_EVENT as u16
                        && r.Event.KeyEvent.bKeyDown != 0
                        && r.Event.KeyEvent.uChar.UnicodeChar != 0
                });
                if !has_text {
                    // Drop the byte-less records so the handle stops signalling.
                    ReadConsoleInputW(stdin, records.as_mut_ptr(), n, &mut n);
                    return Ok(None);
                }
            }
        }
        std::io::stdin().read(buf).map(Some)
    }
}
