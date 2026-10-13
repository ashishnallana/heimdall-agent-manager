//! REQ PTYH-1: VT screen model.
//!
//! A minimal-but-faithful terminal screen grid driven by the `vte` parser.
//! We maintain a grid of styled cells + a cursor, and interpret the common
//! subset of control sequences that interactive programs emit: text, cursor
//! movement, erase-in-line / erase-in-display, and SGR (colors / bold).
//!
//! The point of the spike is that `capture()` reflects *rendered* screen state
//! (what a user would see) rather than the raw byte stream.

use vte::{Params, Parser, Perform};

/// A single on-screen color. `Default` means "use the terminal default".
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Color {
    Default,
    /// 0-15 ANSI, 16-255 xterm-256 palette.
    Indexed(u8),
    Rgb(u8, u8, u8),
}

impl Default for Color {
    fn default() -> Self {
        Color::Default
    }
}

/// A single grid cell: the glyph plus its rendition attributes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Cell {
    pub c: char,
    pub fg: Color,
    pub bg: Color,
    pub bold: bool,
    pub dim: bool,
    pub italic: bool,
    pub underline: bool,
    pub inverse: bool,
}

impl Default for Cell {
    fn default() -> Self {
        Cell {
            c: ' ',
            fg: Color::Default,
            bg: Color::Default,
            bold: false,
            dim: false,
            italic: false,
            underline: false,
            inverse: false,
        }
    }
}

/// A snapshot of the screen for `capture()` / the wire protocol.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Capture {
    pub rows: usize,
    pub cols: usize,
    /// One rendered string per row (trailing blanks trimmed).
    pub lines: Vec<String>,
    /// Full styled grid (row-major, rows*cols cells) for fidelity checks.
    pub cells: Vec<Cell>,
    pub cursor_row: usize,
    pub cursor_col: usize,
}

impl Capture {
    /// Convenience: the styled cell at (row, col), if in bounds.
    pub fn cell_at(&self, row: usize, col: usize) -> Option<Cell> {
        if row < self.rows && col < self.cols {
            self.cells.get(row * self.cols + col).copied()
        } else {
            None
        }
    }
}

/// The terminal screen model. Implements `vte::Perform` so the `Parser` can
/// drive it directly.
pub struct Screen {
    rows: usize,
    cols: usize,
    grid: Vec<Cell>,
    primary_grid: Vec<Cell>,
    alt_screen: bool,
    cursor_row: usize,
    cursor_col: usize,
    // Pending rendition applied to freshly printed cells.
    cur_fg: Color,
    cur_bg: Color,
    cur_bold: bool,
    cur_dim: bool,
    cur_italic: bool,
    cur_underline: bool,
    cur_inverse: bool,
    // DECSC / DECRC saved cursor.
    saved_cursor: Option<(usize, usize)>,
    // Saved primary cursor for ?1049 / ?1048.
    primary_saved_cursor: Option<(usize, usize)>,
    // Cursor visibility (?25h / ?25l).
    cursor_hidden: bool,
    // DECSTBM scroll region (0-based inclusive row indices).
    scroll_top: usize,
    scroll_bottom: usize,
    // DECOM origin mode (?6h / ?6l).
    origin_mode: bool,
    // Last printed character for CSI b (REP).
    last_char: Option<char>,
    // Deferred wrap: after writing the last column we stay put until the next
    // printable char, matching real terminal "auto-wrap" behavior.
    wrap_pending: bool,
}

impl Screen {
    pub fn new(rows: usize, cols: usize) -> Self {
        let rows = rows.max(1);
        let cols = cols.max(1);
        Screen {
            rows,
            cols,
            grid: vec![Cell::default(); rows * cols],
            primary_grid: vec![Cell::default(); rows * cols],
            alt_screen: false,
            cursor_row: 0,
            cursor_col: 0,
            cur_fg: Color::Default,
            cur_bg: Color::Default,
            cur_bold: false,
            cur_dim: false,
            cur_italic: false,
            cur_underline: false,
            cur_inverse: false,
            saved_cursor: None,
            primary_saved_cursor: None,
            cursor_hidden: false,
            scroll_top: 0,
            scroll_bottom: rows - 1,
            origin_mode: false,
            last_char: None,
            wrap_pending: false,
        }
    }

    pub fn size(&self) -> (usize, usize) {
        (self.rows, self.cols)
    }

    pub fn is_alt_screen(&self) -> bool {
        self.alt_screen
    }

    pub fn is_cursor_hidden(&self) -> bool {
        self.cursor_hidden
    }

    /// Resize the grid, preserving overlapping content (top-left anchored).
    pub fn resize(&mut self, rows: usize, cols: usize) {
        let rows = rows.max(1);
        let cols = cols.max(1);
        if rows == self.rows && cols == self.cols {
            return;
        }
        let mut new_grid = vec![Cell::default(); rows * cols];
        let mut new_primary = vec![Cell::default(); rows * cols];
        for r in 0..rows.min(self.rows) {
            for c in 0..cols.min(self.cols) {
                new_grid[r * cols + c] = self.grid[r * self.cols + c];
                new_primary[r * cols + c] = self.primary_grid[r * self.cols + c];
            }
        }
        self.grid = new_grid;
        self.primary_grid = new_primary;
        self.rows = rows;
        self.cols = cols;
        self.cursor_row = self.cursor_row.min(rows - 1);
        self.cursor_col = self.cursor_col.min(cols - 1);
        if let Some((r, c)) = self.primary_saved_cursor {
            self.primary_saved_cursor = Some((r.min(rows - 1), c.min(cols - 1)));
        }
        self.scroll_top = 0;
        self.scroll_bottom = rows - 1;
        self.wrap_pending = false;
    }

    fn idx(&self, row: usize, col: usize) -> usize {
        row * self.cols + col
    }

    fn blank_cell(&self) -> Cell {
        // Erased cells keep the current background color (Background Color Erase / BCE).
        Cell {
            bg: self.cur_bg,
            ..Cell::default()
        }
    }

    fn scroll_up_region(&mut self, top: usize, bottom: usize, count: usize) {
        let top = top.min(self.rows - 1);
        let bottom = bottom.min(self.rows - 1);
        if top > bottom || count == 0 {
            return;
        }
        let region_rows = bottom - top + 1;
        let n = count.min(region_rows);
        if n < region_rows {
            let src_start = (top + n) * self.cols;
            let src_end = (bottom + 1) * self.cols;
            let dst_start = top * self.cols;
            self.grid.copy_within(src_start..src_end, dst_start);
        }
        let clear_start = (bottom + 1 - n) * self.cols;
        let clear_end = (bottom + 1) * self.cols;
        self.erase_cells(clear_start, clear_end);
    }

    fn scroll_down_region(&mut self, top: usize, bottom: usize, count: usize) {
        let top = top.min(self.rows - 1);
        let bottom = bottom.min(self.rows - 1);
        if top > bottom || count == 0 {
            return;
        }
        let region_rows = bottom - top + 1;
        let n = count.min(region_rows);
        if n < region_rows {
            let src_start = top * self.cols;
            let src_end = (bottom + 1 - n) * self.cols;
            let dst_start = (top + n) * self.cols;
            self.grid.copy_within(src_start..src_end, dst_start);
        }
        let clear_start = top * self.cols;
        let clear_end = (top + n) * self.cols;
        self.erase_cells(clear_start, clear_end);
    }

    fn line_feed(&mut self) {
        if self.cursor_row == self.scroll_bottom {
            self.scroll_up_region(self.scroll_top, self.scroll_bottom, 1);
        } else if self.cursor_row + 1 < self.rows {
            self.cursor_row += 1;
        }
    }

    fn put_char(&mut self, c: char) {
        if self.wrap_pending {
            self.cursor_col = 0;
            self.line_feed();
            self.wrap_pending = false;
        }
        let i = self.idx(self.cursor_row, self.cursor_col);
        self.grid[i] = Cell {
            c,
            fg: self.cur_fg,
            bg: self.cur_bg,
            bold: self.cur_bold,
            dim: self.cur_dim,
            italic: self.cur_italic,
            underline: self.cur_underline,
            inverse: self.cur_inverse,
        };
        self.last_char = Some(c);
        if self.cursor_col + 1 >= self.cols {
            // Defer the wrap until the next printable character.
            self.wrap_pending = true;
        } else {
            self.cursor_col += 1;
        }
    }

    fn clamp_cursor(&mut self) {
        self.cursor_row = self.cursor_row.min(self.rows - 1);
        self.cursor_col = self.cursor_col.min(self.cols - 1);
    }

    fn erase_cells(&mut self, from: usize, to: usize) {
        let blank = self.blank_cell();
        for i in from..to.min(self.grid.len()) {
            self.grid[i] = blank;
        }
    }

    /// Snapshot the current screen state.
    pub fn capture(&self) -> Capture {
        use std::fmt::Write;
        let mut lines = Vec::with_capacity(self.rows);
        for r in 0..self.rows {
            let mut end_col = self.cols;
            while end_col > 0 {
                let cell = self.grid[self.idx(r, end_col - 1)];
                if cell.c != ' ' || cell.bg != Color::Default || cell.inverse || cell.underline {
                    break;
                }
                end_col -= 1;
            }

            let mut line = String::with_capacity(self.cols);
            let mut active_fg = Color::Default;
            let mut active_bg = Color::Default;
            let mut active_bold = false;
            let mut active_dim = false;
            let mut active_italic = false;
            let mut active_underline = false;
            let mut active_inverse = false;

            for c in 0..end_col {
                let cell = self.grid[self.idx(r, c)];
                let cell_is_default = cell.fg == Color::Default
                    && cell.bg == Color::Default
                    && !cell.bold
                    && !cell.dim
                    && !cell.italic
                    && !cell.underline
                    && !cell.inverse;
                let active_has_attr = active_fg != Color::Default
                    || active_bg != Color::Default
                    || active_bold
                    || active_dim
                    || active_italic
                    || active_underline
                    || active_inverse;
                if cell_is_default {
                    if active_has_attr {
                        line.push_str("\x1b[0m");
                        active_fg = Color::Default;
                        active_bg = Color::Default;
                        active_bold = false;
                        active_dim = false;
                        active_italic = false;
                        active_underline = false;
                        active_inverse = false;
                    }
                } else {
                    if (!cell.bold && active_bold) || (!cell.dim && active_dim) {
                        line.push_str("\x1b[22m");
                        active_bold = false;
                        active_dim = false;
                    }
                    if cell.bold && !active_bold {
                        line.push_str("\x1b[1m");
                        active_bold = true;
                    }
                    if cell.dim && !active_dim {
                        line.push_str("\x1b[2m");
                        active_dim = true;
                    }
                    if cell.italic != active_italic {
                        line.push_str(if cell.italic { "\x1b[3m" } else { "\x1b[23m" });
                        active_italic = cell.italic;
                    }
                    if cell.underline != active_underline {
                        line.push_str(if cell.underline { "\x1b[4m" } else { "\x1b[24m" });
                        active_underline = cell.underline;
                    }
                    if cell.inverse != active_inverse {
                        line.push_str(if cell.inverse { "\x1b[7m" } else { "\x1b[27m" });
                        active_inverse = cell.inverse;
                    }
                    if cell.fg != active_fg {
                        match cell.fg {
                            Color::Default => line.push_str("\x1b[39m"),
                            Color::Indexed(n) if n < 8 => {
                                let _ = write!(line, "\x1b[{}m", 30 + n);
                            }
                            Color::Indexed(n) if n < 16 => {
                                let _ = write!(line, "\x1b[{}m", 90 + (n - 8));
                            }
                            Color::Indexed(n) => {
                                let _ = write!(line, "\x1b[38;5;{}m", n);
                            }
                            Color::Rgb(r, g, b) => {
                                let _ = write!(line, "\x1b[38;2;{};{};{}m", r, g, b);
                            }
                        }
                        active_fg = cell.fg;
                    }
                    if cell.bg != active_bg {
                        match cell.bg {
                            Color::Default => line.push_str("\x1b[49m"),
                            Color::Indexed(n) if n < 8 => {
                                let _ = write!(line, "\x1b[{}m", 40 + n);
                            }
                            Color::Indexed(n) if n < 16 => {
                                let _ = write!(line, "\x1b[{}m", 100 + (n - 8));
                            }
                            Color::Indexed(n) => {
                                let _ = write!(line, "\x1b[48;5;{}m", n);
                            }
                            Color::Rgb(r, g, b) => {
                                let _ = write!(line, "\x1b[48;2;{};{};{}m", r, g, b);
                            }
                        }
                        active_bg = cell.bg;
                    }
                }
                line.push(cell.c);
            }
            if active_fg != Color::Default
                || active_bg != Color::Default
                || active_bold
                || active_dim
                || active_italic
                || active_underline
                || active_inverse
            {
                line.push_str("\x1b[0m");
            }
            lines.push(line);
        }
        if self.alt_screen && !lines.is_empty() {
            let prefix = if self.cursor_hidden {
                "\x1b[?1049h\x1b[?25l"
            } else {
                "\x1b[?1049h"
            };
            lines[0].insert_str(0, prefix);
        }
        Capture {
            rows: self.rows,
            cols: self.cols,
            lines,
            cells: self.grid.clone(),
            cursor_row: self.cursor_row,
            cursor_col: self.cursor_col,
        }
    }

    // ---- SGR (colors / attributes) -------------------------------------

    fn apply_sgr(&mut self, params: &Params) {
        let groups: Vec<&[u16]> = params.iter().collect();
        if groups.is_empty() {
            self.reset_sgr();
            return;
        }
        let mut i = 0;
        while i < groups.len() {
            let group = groups[i];
            let code = group.first().copied().unwrap_or(0);
            match code {
                0 => self.reset_sgr(),
                1 => self.cur_bold = true,
                2 => self.cur_dim = true,
                3 => self.cur_italic = true,
                4 => {
                    if group.get(1) == Some(&0) {
                        self.cur_underline = false;
                    } else {
                        self.cur_underline = true;
                    }
                }
                7 => self.cur_inverse = true,
                22 => {
                    self.cur_bold = false;
                    self.cur_dim = false;
                }
                23 => self.cur_italic = false,
                24 => self.cur_underline = false,
                27 => self.cur_inverse = false,
                30..=37 => self.cur_fg = Color::Indexed((code - 30) as u8),
                39 => self.cur_fg = Color::Default,
                40..=47 => self.cur_bg = Color::Indexed((code - 40) as u8),
                49 => self.cur_bg = Color::Default,
                90..=97 => self.cur_fg = Color::Indexed((code - 90 + 8) as u8),
                100..=107 => self.cur_bg = Color::Indexed((code - 100 + 8) as u8),
                38 | 48 => {
                    let is_fg = code == 38;
                    if group.len() >= 3 {
                        if let Some(color) = parse_subparam_color(group) {
                            if is_fg {
                                self.cur_fg = color;
                            } else {
                                self.cur_bg = color;
                            }
                            i += 1;
                            continue;
                        }
                    }
                    let flat: Vec<u16> = groups[i..]
                        .iter()
                        .map(|p| p.first().copied().unwrap_or(0))
                        .collect();
                    if let Some((color, adv)) = parse_extended_color(&flat) {
                        if is_fg {
                            self.cur_fg = color;
                        } else {
                            self.cur_bg = color;
                        }
                        i += adv;
                        continue;
                    }
                }
                _ => {}
            }
            i += 1;
        }
    }

    fn reset_sgr(&mut self) {
        self.cur_fg = Color::Default;
        self.cur_bg = Color::Default;
        self.cur_bold = false;
        self.cur_dim = false;
        self.cur_italic = false;
        self.cur_underline = false;
        self.cur_inverse = false;
    }

    fn handle_dec_private_mode(&mut self, params: &Params, set: bool) {
        for p in params.iter() {
            let mode = p.first().copied().unwrap_or(0);
            match mode {
                47 | 1047 => {
                    if set {
                        if !self.alt_screen {
                            std::mem::swap(&mut self.primary_grid, &mut self.grid);
                            self.alt_screen = true;
                        }
                        self.grid.fill(Cell::default());
                    } else if self.alt_screen {
                        std::mem::swap(&mut self.primary_grid, &mut self.grid);
                        self.alt_screen = false;
                    }
                    self.scroll_top = 0;
                    self.scroll_bottom = self.rows - 1;
                    self.wrap_pending = false;
                }
                1048 => {
                    if set {
                        self.primary_saved_cursor = Some((self.cursor_row, self.cursor_col));
                    } else if let Some((r, c)) = self.primary_saved_cursor {
                        self.cursor_row = r.min(self.rows - 1);
                        self.cursor_col = c.min(self.cols - 1);
                        self.wrap_pending = false;
                    }
                }
                1049 => {
                    if set {
                        self.primary_saved_cursor = Some((self.cursor_row, self.cursor_col));
                        if !self.alt_screen {
                            std::mem::swap(&mut self.primary_grid, &mut self.grid);
                            self.alt_screen = true;
                        }
                        self.grid.fill(Cell::default());
                        self.cursor_row = 0;
                        self.cursor_col = 0;
                        self.scroll_top = 0;
                        self.scroll_bottom = self.rows - 1;
                        self.origin_mode = false;
                        self.wrap_pending = false;
                    } else {
                        if self.alt_screen {
                            std::mem::swap(&mut self.primary_grid, &mut self.grid);
                            self.alt_screen = false;
                        }
                        if let Some((r, c)) = self.primary_saved_cursor {
                            self.cursor_row = r.min(self.rows - 1);
                            self.cursor_col = c.min(self.cols - 1);
                        }
                        self.scroll_top = 0;
                        self.scroll_bottom = self.rows - 1;
                        self.origin_mode = false;
                        self.wrap_pending = false;
                    }
                }
                25 => {
                    self.cursor_hidden = !set;
                }
                6 => {
                    self.origin_mode = set;
                    self.cursor_row = if set { self.scroll_top } else { 0 };
                    self.cursor_col = 0;
                    self.wrap_pending = false;
                }
                _ => {}
            }
        }
    }
}

/// Parse colon-separated subparameters `38:5:n` or `38:2:r:g:b` or `38:2:cs:r:g:b`.
fn parse_subparam_color(group: &[u16]) -> Option<Color> {
    match group.get(1) {
        Some(5) => Some(Color::Indexed(*group.get(2)? as u8)),
        Some(2) => {
            if group.len() >= 6 {
                Some(Color::Rgb(
                    group[group.len() - 3] as u8,
                    group[group.len() - 2] as u8,
                    group[group.len() - 1] as u8,
                ))
            } else {
                Some(Color::Rgb(
                    *group.get(2)? as u8,
                    *group.get(3)? as u8,
                    *group.get(4)? as u8,
                ))
            }
        }
        _ => None,
    }
}

/// Parse a `38;5;n` (indexed) or `38;2;r;g;b` (truecolor) run.
/// Returns (color, number-of-params-consumed).
fn parse_extended_color(seq: &[u16]) -> Option<(Color, usize)> {
    match seq.get(1) {
        Some(5) => {
            let n = *seq.get(2)? as u8;
            Some((Color::Indexed(n), 3))
        }
        Some(2) => {
            let r = *seq.get(2)? as u8;
            let g = *seq.get(3)? as u8;
            let b = *seq.get(4)? as u8;
            Some((Color::Rgb(r, g, b), 5))
        }
        _ => None,
    }
}

fn first(params: &Params, default: u16) -> u16 {
    let v = params.iter().next().and_then(|p| p.first().copied()).unwrap_or(0);
    if v == 0 { default } else { v }
}

fn nth(params: &Params, n: usize, default: u16) -> u16 {
    let v = params.iter().nth(n).and_then(|p| p.first().copied()).unwrap_or(0);
    if v == 0 { default } else { v }
}

impl Perform for Screen {
    fn print(&mut self, c: char) {
        self.put_char(c);
    }

    fn execute(&mut self, byte: u8) {
        match byte {
            b'\n' | 0x0b | 0x0c => {
                self.wrap_pending = false;
                self.line_feed();
            }
            b'\r' => {
                self.wrap_pending = false;
                self.cursor_col = 0;
            }
            b'\t' => {
                self.wrap_pending = false;
                let next = ((self.cursor_col / 8) + 1) * 8;
                self.cursor_col = next.min(self.cols - 1);
            }
            0x08 => {
                // backspace
                self.wrap_pending = false;
                if self.cursor_col > 0 {
                    self.cursor_col -= 1;
                }
            }
            _ => {}
        }
    }

    fn csi_dispatch(&mut self, params: &Params, intermediates: &[u8], _ignore: bool, action: char) {
        if intermediates == b"?" {
            match action {
                'h' => self.handle_dec_private_mode(params, true),
                'l' => self.handle_dec_private_mode(params, false),
                _ => {}
            }
            return;
        }
        if !intermediates.is_empty() {
            return;
        }
        match action {
            'A' => {
                let n = first(params, 1) as usize;
                if self.cursor_row >= self.scroll_top {
                    self.cursor_row = self.cursor_row.saturating_sub(n).max(self.scroll_top);
                } else {
                    self.cursor_row = self.cursor_row.saturating_sub(n);
                }
                self.wrap_pending = false;
            }
            'B' => {
                let n = first(params, 1) as usize;
                if self.cursor_row <= self.scroll_bottom {
                    self.cursor_row = (self.cursor_row + n).min(self.scroll_bottom);
                } else {
                    self.cursor_row = (self.cursor_row + n).min(self.rows - 1);
                }
                self.wrap_pending = false;
            }
            'C' => {
                let n = first(params, 1) as usize;
                self.cursor_col = (self.cursor_col + n).min(self.cols - 1);
                self.wrap_pending = false;
            }
            'D' => {
                let n = first(params, 1) as usize;
                self.cursor_col = self.cursor_col.saturating_sub(n);
                self.wrap_pending = false;
            }
            'E' => {
                let n = first(params, 1) as usize;
                self.cursor_row = (self.cursor_row + n).min(self.rows - 1);
                self.cursor_col = 0;
                self.wrap_pending = false;
            }
            'F' => {
                let n = first(params, 1) as usize;
                self.cursor_row = self.cursor_row.saturating_sub(n);
                self.cursor_col = 0;
                self.wrap_pending = false;
            }
            'G' | '`' => {
                let col = first(params, 1) as usize;
                self.cursor_col = col.saturating_sub(1).min(self.cols - 1);
                self.wrap_pending = false;
            }
            'd' => {
                let row = first(params, 1) as usize;
                self.cursor_row = row.saturating_sub(1).min(self.rows - 1);
                self.wrap_pending = false;
            }
            'H' | 'f' => {
                let row = first(params, 1) as usize;
                let col = nth(params, 1, 1) as usize;
                let base_row = if self.origin_mode { self.scroll_top } else { 0 };
                let max_row = if self.origin_mode { self.scroll_bottom } else { self.rows - 1 };
                self.cursor_row = (base_row + row.saturating_sub(1)).min(max_row);
                self.cursor_col = col.saturating_sub(1).min(self.cols - 1);
                self.wrap_pending = false;
            }
            'J' => {
                // Erase in Display.
                let mode = params.iter().next().and_then(|p| p.first().copied()).unwrap_or(0);
                let cur = self.idx(self.cursor_row, self.cursor_col);
                match mode {
                    0 => self.erase_cells(cur, self.grid.len()),
                    1 => self.erase_cells(0, cur + 1),
                    2 | 3 => {
                        let len = self.grid.len();
                        self.erase_cells(0, len);
                    }
                    _ => {}
                }
                self.wrap_pending = false;
            }
            'K' => {
                // Erase in Line.
                let mode = params.iter().next().and_then(|p| p.first().copied()).unwrap_or(0);
                let row_start = self.idx(self.cursor_row, 0);
                let cur = self.idx(self.cursor_row, self.cursor_col);
                let row_end = row_start + self.cols;
                match mode {
                    0 => self.erase_cells(cur, row_end),
                    1 => self.erase_cells(row_start, cur + 1),
                    2 => self.erase_cells(row_start, row_end),
                    _ => {}
                }
                self.wrap_pending = false;
            }
            'X' => {
                // Erase Character (ECH).
                let n = first(params, 1) as usize;
                let start = self.idx(self.cursor_row, self.cursor_col);
                let end = self.idx(self.cursor_row, (self.cursor_col + n).min(self.cols));
                self.erase_cells(start, end);
                self.wrap_pending = false;
            }
            'L' => {
                // Insert Lines (IL).
                let n = first(params, 1) as usize;
                if self.cursor_row >= self.scroll_top && self.cursor_row <= self.scroll_bottom {
                    self.scroll_down_region(self.cursor_row, self.scroll_bottom, n);
                }
                self.cursor_col = 0;
                self.wrap_pending = false;
            }
            'M' => {
                // Delete Lines (DL).
                let n = first(params, 1) as usize;
                if self.cursor_row >= self.scroll_top && self.cursor_row <= self.scroll_bottom {
                    self.scroll_up_region(self.cursor_row, self.scroll_bottom, n);
                }
                self.cursor_col = 0;
                self.wrap_pending = false;
            }
            'S' => {
                // Scroll Up (SU).
                let n = first(params, 1) as usize;
                self.scroll_up_region(self.scroll_top, self.scroll_bottom, n);
                self.wrap_pending = false;
            }
            'T' => {
                // Scroll Down (SD).
                let n = first(params, 1) as usize;
                self.scroll_down_region(self.scroll_top, self.scroll_bottom, n);
                self.wrap_pending = false;
            }
            '@' => {
                // Insert Character (ICH).
                let n = first(params, 1) as usize;
                let row_start = self.idx(self.cursor_row, 0);
                let row_end = row_start + self.cols;
                let cur = self.idx(self.cursor_row, self.cursor_col);
                let shift = n.min(self.cols - self.cursor_col);
                if cur + shift < row_end {
                    self.grid.copy_within(cur..(row_end - shift), cur + shift);
                }
                self.erase_cells(cur, cur + shift);
                self.wrap_pending = false;
            }
            'P' => {
                // Delete Character (DCH).
                let n = first(params, 1) as usize;
                let row_start = self.idx(self.cursor_row, 0);
                let row_end = row_start + self.cols;
                let cur = self.idx(self.cursor_row, self.cursor_col);
                let shift = n.min(self.cols - self.cursor_col);
                if cur + shift < row_end {
                    self.grid.copy_within((cur + shift)..row_end, cur);
                }
                self.erase_cells(row_end - shift, row_end);
                self.wrap_pending = false;
            }
            'b' => {
                // Repeat preceding graphic character (REP).
                let n = first(params, 1) as usize;
                if let Some(ch) = self.last_char {
                    for _ in 0..n {
                        self.put_char(ch);
                    }
                }
            }
            'r' => {
                // Set Top and Bottom Margins (DECSTBM).
                let top = first(params, 1) as usize;
                let bottom = nth(params, 1, self.rows as u16) as usize;
                let t = top.saturating_sub(1).min(self.rows - 1);
                let b = bottom.saturating_sub(1).min(self.rows - 1);
                if t < b {
                    self.scroll_top = t;
                    self.scroll_bottom = b;
                } else {
                    self.scroll_top = 0;
                    self.scroll_bottom = self.rows - 1;
                }
                self.cursor_row = if self.origin_mode { self.scroll_top } else { 0 };
                self.cursor_col = 0;
                self.wrap_pending = false;
            }
            'm' => self.apply_sgr(params),
            's' => self.saved_cursor = Some((self.cursor_row, self.cursor_col)),
            'u' => {
                if let Some((r, c)) = self.saved_cursor {
                    self.cursor_row = r;
                    self.cursor_col = c;
                    self.clamp_cursor();
                    self.wrap_pending = false;
                }
            }
            _ => {}
        }
    }

    fn esc_dispatch(&mut self, _intermediates: &[u8], _ignore: bool, byte: u8) {
        match byte {
            b'7' => self.saved_cursor = Some((self.cursor_row, self.cursor_col)),
            b'8' => {
                if let Some((r, c)) = self.saved_cursor {
                    self.cursor_row = r;
                    self.cursor_col = c;
                    self.clamp_cursor();
                    self.wrap_pending = false;
                }
            }
            b'c' => {
                // RIS - full reset.
                self.reset_sgr();
                self.alt_screen = false;
                self.grid.fill(Cell::default());
                self.primary_grid.fill(Cell::default());
                self.cursor_row = 0;
                self.cursor_col = 0;
                self.saved_cursor = None;
                self.primary_saved_cursor = None;
                self.cursor_hidden = false;
                self.scroll_top = 0;
                self.scroll_bottom = self.rows - 1;
                self.origin_mode = false;
                self.last_char = None;
                self.wrap_pending = false;
            }
            b'D' => self.line_feed(),
            b'E' => {
                self.wrap_pending = false;
                self.cursor_col = 0;
                self.line_feed();
            }
            b'M' => {
                // Reverse index.
                if self.cursor_row == self.scroll_top {
                    self.scroll_down_region(self.scroll_top, self.scroll_bottom, 1);
                } else if self.cursor_row > 0 {
                    self.cursor_row -= 1;
                }
                self.wrap_pending = false;
            }
            _ => {}
        }
    }

    // DCS / OSC are ignored for the spike (title-setting etc. don't affect grid).
    fn hook(&mut self, _params: &Params, _intermediates: &[u8], _ignore: bool, _action: char) {}
    fn put(&mut self, _byte: u8) {}
    fn unhook(&mut self) {}
    fn osc_dispatch(&mut self, _params: &[&[u8]], _bell_terminated: bool) {}
}

/// A VT engine: owns the `vte::Parser` + a `Screen`, feeding bytes in.
pub struct VtEngine {
    parser: Parser,
    pub screen: Screen,
}

impl VtEngine {
    pub fn new(rows: usize, cols: usize) -> Self {
        VtEngine {
            parser: Parser::new(),
            screen: Screen::new(rows, cols),
        }
    }

    /// Feed raw PTY bytes through the parser into the screen model.
    pub fn feed(&mut self, bytes: &[u8]) {
        self.parser.advance(&mut self.screen, bytes);
    }

    pub fn capture(&self) -> Capture {
        self.screen.capture()
    }

    pub fn resize(&mut self, rows: usize, cols: usize) {
        self.screen.resize(rows, cols);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn feed(engine: &mut VtEngine, s: &str) {
        engine.feed(s.as_bytes());
    }

    #[test]
    fn plain_text_renders_not_raw_bytes() {
        let mut e = VtEngine::new(4, 20);
        feed(&mut e, "hello world");
        let cap = e.capture();
        assert_eq!(cap.lines[0], "hello world");
        assert_eq!(cap.cursor_row, 0);
        assert_eq!(cap.cursor_col, 11);
    }

    #[test]
    fn newline_and_carriage_return() {
        let mut e = VtEngine::new(4, 20);
        feed(&mut e, "line1\r\nline2");
        let cap = e.capture();
        assert_eq!(cap.lines[0], "line1");
        assert_eq!(cap.lines[1], "line2");
    }

    #[test]
    fn cursor_move_and_overwrite() {
        let mut e = VtEngine::new(4, 20);
        feed(&mut e, "XXXXX");
        // Move cursor to column 1 (1-based) and overwrite.
        feed(&mut e, "\x1b[1G");
        feed(&mut e, "ab");
        let cap = e.capture();
        assert_eq!(cap.lines[0], "abXXX");
    }

    #[test]
    fn absolute_cursor_position() {
        let mut e = VtEngine::new(5, 20);
        feed(&mut e, "\x1b[3;5Hhi");
        let cap = e.capture();
        // row 3 (index 2), col 5 (index 4)
        assert_eq!(cap.lines[2], "    hi");
        assert_eq!(cap.cursor_row, 2);
        assert_eq!(cap.cursor_col, 6);
    }

    #[test]
    fn erase_line_and_display() {
        let mut e = VtEngine::new(3, 10);
        feed(&mut e, "abcdefghij");
        feed(&mut e, "\r\nsecond");
        // Move to home, erase entire display.
        feed(&mut e, "\x1b[H\x1b[2J");
        let cap = e.capture();
        assert_eq!(cap.lines[0], "");
        assert_eq!(cap.lines[1], "");
    }

    #[test]
    fn erase_to_end_of_line() {
        let mut e = VtEngine::new(2, 10);
        feed(&mut e, "abcdefgh");
        feed(&mut e, "\x1b[1;4H"); // col 4 (index 3)
        feed(&mut e, "\x1b[0K");
        let cap = e.capture();
        assert_eq!(cap.lines[0], "abc");
    }

    #[test]
    fn ansi_color_is_captured_as_rendition_not_text() {
        let mut e = VtEngine::new(2, 20);
        // Red foreground, bold, then a char, then reset.
        feed(&mut e, "\x1b[1;31mR\x1b[0mx");
        let cap = e.capture();
        // Screen capture preserves ANSI SGR sequences.
        assert_eq!(cap.lines[0], "\x1b[1m\x1b[31mR\x1b[0mx");
        let red = cap.cell_at(0, 0).unwrap();
        assert_eq!(red.c, 'R');
        assert_eq!(red.fg, Color::Indexed(1));
        assert!(red.bold);
        let plain = cap.cell_at(0, 1).unwrap();
        assert_eq!(plain.c, 'x');
        assert_eq!(plain.fg, Color::Default);
        assert!(!plain.bold);
    }

    #[test]
    fn capture_preserves_ansi_colors_and_bold() {
        let mut e = VtEngine::new(2, 40);
        feed(&mut e, "\x1b[31mred\x1b[0m \x1b[1mbold\x1b[0m \x1b[32mgreen\x1b[0m");
        let cap = e.capture();
        assert_eq!(cap.lines[0], "\x1b[31mred\x1b[0m \x1b[1mbold\x1b[0m \x1b[32mgreen\x1b[0m");
    }

    #[test]
    fn capture_preserves_truecolor_and_256_color() {
        let mut e = VtEngine::new(2, 40);
        feed(&mut e, "\x1b[38;2;10;20;30mRGB\x1b[0m \x1b[38;5;123m256\x1b[0m");
        let cap = e.capture();
        assert_eq!(cap.lines[0], "\x1b[38;2;10;20;30mRGB\x1b[0m \x1b[38;5;123m256\x1b[0m");
    }

    #[test]
    fn capture_preserves_background_color() {
        let mut e = VtEngine::new(2, 20);
        feed(&mut e, "\x1b[42mgreenbg\x1b[0m");
        let cap = e.capture();
        assert_eq!(cap.lines[0], "\x1b[42mgreenbg\x1b[0m");
    }

    #[test]
    fn capture_resets_attributes_at_end_of_line() {
        let mut e = VtEngine::new(2, 20);
        feed(&mut e, "\x1b[34mblue");
        let cap = e.capture();
        assert_eq!(cap.lines[0], "\x1b[34mblue\x1b[0m");
    }

    #[test]
    fn truecolor_and_256_color() {
        let mut e = VtEngine::new(1, 10);
        feed(&mut e, "\x1b[38;2;10;20;30mA");
        feed(&mut e, "\x1b[38;5;123mB");
        let cap = e.capture();
        assert_eq!(cap.cell_at(0, 0).unwrap().fg, Color::Rgb(10, 20, 30));
        assert_eq!(cap.cell_at(0, 1).unwrap().fg, Color::Indexed(123));
    }

    #[test]
    fn scrolling_when_output_exceeds_rows() {
        let mut e = VtEngine::new(2, 10);
        feed(&mut e, "a\r\nb\r\nc");
        let cap = e.capture();
        // First line scrolled off; b then c remain.
        assert_eq!(cap.lines[0], "b");
        assert_eq!(cap.lines[1], "c");
    }

    #[test]
    fn autowrap_at_last_column() {
        let mut e = VtEngine::new(3, 3);
        feed(&mut e, "abcd");
        let cap = e.capture();
        assert_eq!(cap.lines[0], "abc");
        assert_eq!(cap.lines[1], "d");
    }

    #[test]
    fn resize_preserves_content() {
        let mut e = VtEngine::new(3, 10);
        feed(&mut e, "hello");
        e.resize(5, 20);
        let cap = e.capture();
        assert_eq!(cap.lines[0], "hello");
        assert_eq!(cap.rows, 5);
        assert_eq!(cap.cols, 20);
    }

    #[test]
    fn test_alternate_screen_1049_preserves_and_restores_primary_grid_and_cursor() {
        // Arrange: write shell prompt on primary screen
        let mut e = VtEngine::new(4, 20);
        feed(&mut e, "user@host:~$ nvim\r\nsecond line");
        assert!(!e.screen.is_alt_screen());

        // Act: enter alternate screen (?1049h), draw Neovim TUI, then exit (?1049l)
        feed(&mut e, "\x1b[?1049h\x1b[?25l\x1b[1;1H~                   \x1b[4;1H-- NORMAL --");
        let alt_cap = e.capture();
        assert!(e.screen.is_alt_screen());
        assert!(e.screen.is_cursor_hidden());
        assert_eq!(alt_cap.lines[0], "\x1b[?1049h\x1b[?25l~");
        assert_eq!(alt_cap.lines[3], "-- NORMAL --");

        feed(&mut e, "\x1b[?1049l\x1b[?25h");
        let restored = e.capture();

        // Assert: primary buffer and cursor are restored without alternate screen prefix
        assert!(!e.screen.is_alt_screen());
        assert!(!e.screen.is_cursor_hidden());
        assert_eq!(restored.lines[0], "user@host:~$ nvim");
        assert_eq!(restored.lines[1], "second line");
        assert_eq!(restored.lines[3], "");
        assert_eq!(restored.cursor_row, 1);
        assert_eq!(restored.cursor_col, 11);
    }

    #[test]
    fn test_decstbm_scroll_region_scrolls_only_within_margins() {
        // Arrange: 5 rows, header on row 1, status bar on row 5, scroll region rows 2..4
        let mut e = VtEngine::new(5, 15);
        feed(&mut e, "\x1b[1;1HHEADER");
        feed(&mut e, "\x1b[2;1Hline A");
        feed(&mut e, "\x1b[3;1Hline B");
        feed(&mut e, "\x1b[4;1Hline C");
        feed(&mut e, "\x1b[5;1HSTATUS BAR");

        // Act: set scroll region 2..4 (\x1b[2;4r), move to row 4, and newline
        feed(&mut e, "\x1b[2;4r\x1b[4;1H\r\nline D");
        let cap = e.capture();

        // Assert: HEADER and STATUS BAR stay fixed while rows 2..4 scroll up
        assert_eq!(cap.lines[0], "HEADER");
        assert_eq!(cap.lines[1], "line B");
        assert_eq!(cap.lines[2], "line C");
        assert_eq!(cap.lines[3], "line D");
        assert_eq!(cap.lines[4], "STATUS BAR");
    }

    #[test]
    fn test_neovim_editing_sequences_ech_il_dl_ich_dch_rep() {
        let mut e = VtEngine::new(4, 12);
        // ECH (\x1b[3X) erases 3 chars in place without moving cursor
        feed(&mut e, "abcdefgh\x1b[1;3H\x1b[3X");
        assert_eq!(e.capture().lines[0], "ab   fgh");

        // DCH (\x1b[2P) deletes 2 chars and shifts left; ICH (\x1b[2@) inserts 2 blanks
        feed(&mut e, "\x1b[1;3H\x1b[3P\x1b[1;3H\x1b[1@Z");
        assert_eq!(e.capture().lines[0], "abZfgh");

        // REP (\x1b[3b) repeats last printed char ('Z') 3 more times, overwriting 'fgh'
        feed(&mut e, "\x1b[3b");
        assert_eq!(e.capture().lines[0], "abZZZZ");

        // IL (\x1b[1L) on row 1 pushes row 1 down to row 2
        feed(&mut e, "\x1b[1;1H\x1b[1Ltop");
        let cap = e.capture();
        assert_eq!(cap.lines[0], "top");
        assert_eq!(cap.lines[1], "abZZZZ");
    }

    #[test]
    fn test_sgr_inverse_underline_italic_dim_and_bce_background_erase() {
        let mut e = VtEngine::new(3, 10);
        // Statusline with reverse video (\x1b[7m) including trailing spaces
        feed(&mut e, "\x1b[7m STATUS   \x1b[0m");
        // Line 2 with italic + underline
        feed(&mut e, "\r\n\x1b[3;4mcode\x1b[0m");
        // Line 3 with BCE (background color 44 blue + Erase in Line \x1b[2K)
        feed(&mut e, "\r\n\x1b[44m\x1b[2K\x1b[0m");

        let cap = e.capture();
        assert_eq!(cap.lines[0], "\x1b[7m STATUS   \x1b[0m");
        assert_eq!(cap.lines[1], "\x1b[3m\x1b[4mcode\x1b[0m");
        assert_eq!(cap.lines[2], "\x1b[44m          \x1b[0m");
    }

    #[test]
    fn test_csi_private_intermediates_do_not_corrupt_sgr() {
        let mut e = VtEngine::new(2, 10);
        // Neovim emits \x1b[>4;2m (modifyOtherKeys) and \x1b[2 q (cursor shape)
        feed(&mut e, "\x1b[>4;2m\x1b[2 qplain");
        let cap = e.capture();
        assert_eq!(cap.lines[0], "plain");
    }
}
