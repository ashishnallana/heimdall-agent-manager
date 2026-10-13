export interface MutableCounter {
  current: number;
}

/**
 * Accounts for an asynchronous xterm write and returns its completion callback.
 */
export function beginTerminalWrite(
  pendingWrites: MutableCounter
): () => void {
  pendingWrites.current += 1;

  return () => {
    pendingWrites.current = Math.max(0, pendingWrites.current - 1);
  };
}

/**
 * Forwards both user keystrokes and xterm-generated protocol replies. Serialized
 * screen restoration contains paint state, not live terminal queries; filtering
 * `onData` during writes can discard required OSC/DSR replies and stall TUIs.
 */
export function dispatchTerminalData(
  data: string,
  vaultLocked: boolean,
  send: (data: string) => void
): boolean {
  if (vaultLocked) return false;
  send(data);
  return true;
}
