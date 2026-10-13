interface TerminalPaneContainer {
  clientWidth: number;
  clientHeight: number;
}

interface TerminalPaneTerminal {
  cols: number;
  rows: number;
  resize: (cols: number, rows: number) => void;
  focus: () => void;
}

interface TerminalPaneFitAddon {
  fit: () => void;
}

interface TerminalPaneActivationCallbacks {
  markSized: () => void;
  sendResize: (rows: number, cols: number) => void;
  flushPendingOutput: () => void;
}

/**
 * Sizes a terminal after its keep-alive wrapper becomes visible.
 *
 * A pane first mounted under `display: none` has no measurable geometry. Its stream bytes are
 * intentionally buffered until this function can fit against positive dimensions, publish the
 * PTY geometry, and drain those bytes into xterm in that order.
 */
export function activateVisibleTerminal(
  container: TerminalPaneContainer,
  fitAddon: TerminalPaneFitAddon,
  terminal: TerminalPaneTerminal,
  callbacks: TerminalPaneActivationCallbacks
): boolean {
  if (container.clientWidth <= 0 || container.clientHeight <= 0) return false;

  fitAddon.fit();
  const cols = Math.max(terminal.cols, 40);
  const rows = Math.max(terminal.rows, 1);
  terminal.resize(cols, rows);
  callbacks.markSized();
  callbacks.sendResize(rows, cols);
  callbacks.flushPendingOutput();
  terminal.focus();
  return true;
}
