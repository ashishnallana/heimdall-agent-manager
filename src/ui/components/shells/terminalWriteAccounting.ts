export type TerminalWriteKind = 'live' | 'replay';

export interface MutableCounter {
  current: number;
}

/**
 * Accounts for an asynchronous xterm write and returns its completion callback.
 *
 * Only saved-state restoration is a replay. Live PTY bytes can contain terminal
 * queries (for example Neovim's OSC 11 + DSR probe), whose xterm-generated reply
 * must be forwarded while `term.write` is still processing the chunk.
 */
export function beginTerminalWrite(
  kind: TerminalWriteKind,
  pendingWrites: MutableCounter,
  pendingReplays: MutableCounter
): () => void {
  pendingWrites.current += 1;
  if (kind === 'replay') pendingReplays.current += 1;

  return () => {
    pendingWrites.current = Math.max(0, pendingWrites.current - 1);
    if (kind === 'replay') {
      pendingReplays.current = Math.max(0, pendingReplays.current - 1);
    }
  };
}

export function shouldForwardTerminalData(pendingReplays: MutableCounter): boolean {
  return pendingReplays.current === 0;
}
