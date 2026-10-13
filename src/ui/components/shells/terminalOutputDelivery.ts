export interface TerminalOutputDeliverySinks<TTerminal> {
  write: (terminal: TTerminal, bytes: Uint8Array) => void;
  buffer: (sessionId: string, bytes: Uint8Array) => void;
}

/**
 * Delivers PTY bytes to the terminal parser whenever it exists.
 *
 * Layout readiness must never gate this path. Full-screen applications issue terminal queries
 * during startup and xterm can only answer after parsing those bytes; buffering them until a fit
 * creates a protocol deadlock when the dock is still animating from zero height. Buffering is
 * reserved for the one real delivery gap: no terminal instance is mounted yet.
 */
export function deliverTerminalOutput<TTerminal>(
  terminal: TTerminal | null,
  sessionId: string | null,
  bytes: Uint8Array,
  sinks: TerminalOutputDeliverySinks<TTerminal>
): 'written' | 'buffered' | 'dropped' {
  if (terminal) {
    sinks.write(terminal, bytes);
    return 'written';
  }
  if (sessionId) {
    sinks.buffer(sessionId, bytes);
    return 'buffered';
  }
  return 'dropped';
}
