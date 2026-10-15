/** Ordered, byte-bounded delivery shared by shell and agent panes. */
export const PANE_DELIVERY_MAX_BYTES = 4 * 1024 * 1024;
export const PANE_DELIVERY_MAX_FRAMES = 256;

export class PaneDeliveryQueue {
  private pending: Array<{ bytes: number; run: () => Promise<void> }> = [];
  private bytes = 0;
  private running = false;
  private stopped = false;
  private idle: Array<() => void> = [];

  private readonly onFailure: () => void;
  private readonly maxBytes: number;

  constructor(onFailure: () => void, maxBytes = PANE_DELIVERY_MAX_BYTES) {
    this.onFailure = onFailure;
    this.maxBytes = maxBytes;
  }

  enqueue(bytes: number, run: () => Promise<void>): boolean {
    if (this.stopped) return false;
    if (!Number.isSafeInteger(bytes) || bytes < 0 || bytes > this.maxBytes - this.bytes || this.pending.length >= PANE_DELIVERY_MAX_FRAMES) {
      this.cancel();
      this.onFailure();
      return false;
    }
    this.bytes += bytes;
    this.pending.push({ bytes, run });
    if (!this.running) void this.drain();
    return true;
  }

  cancel(): void {
    this.stopped = true;
    for (const item of this.pending) this.bytes -= item.bytes;
    this.pending = [];
  }

  whenIdle(): Promise<void> {
    return this.running ? new Promise(resolve => this.idle.push(resolve)) : Promise.resolve();
  }

  get queuedBytes(): number { return this.bytes; }

  private async drain(): Promise<void> {
    this.running = true;
    while (!this.stopped && this.pending.length) {
      const item = this.pending.shift()!;
      try { await item.run(); }
      catch { this.cancel(); this.onFailure(); }
      finally { this.bytes -= item.bytes; }
    }
    this.running = false;
    for (const resolve of this.idle) resolve();
    this.idle = [];
  }
}

/**
 * REQ-PTY-NET-7: one `term.write` per animation frame.
 *
 * xterm parses per write and the pane re-layouts per parse; a bursty TUI (7-8 redraws/s,
 * spinner frames, coalesced bridge frames landing back-to-back) used to be one write per
 * wire frame. The batcher concatenates everything that arrives within one animation frame
 * and hands the consumer ONE string. Two rules keep it correct:
 *   - a text that BEGINS an absolute repaint (snapshot/screen) always starts a new write:
 *     the consumer's replay gate recognises a repaint by the write's leading bytes
 *     (ShellTerminalPane writeStreamBytes), so it must never be buried mid-batch;
 *   - PANE_WRITE_BATCH_MAX_CHARS bounds the batch so a hidden tab (where rAF does not
 *     fire) cannot grow it without limit; above it the flush is forced.
 * Scheduling is injectable; the default is requestAnimationFrame when present (browser),
 * else setTimeout(0) (tests, Electron main).
 */
export const PANE_WRITE_BATCH_MAX_CHARS = 512 * 1024;

export type PaneWriteSchedule = (flush: () => void) => void;

const defaultWriteSchedule: PaneWriteSchedule = (flush) => {
  if (typeof requestAnimationFrame === 'function') requestAnimationFrame(() => flush());
  else setTimeout(flush, 0);
};

export class PaneWriteBatcher {
  private pending = '';
  private scheduled = false;
  private readonly write: (text: string) => void;
  private readonly schedule: PaneWriteSchedule;
  private readonly maxChars: number;

  constructor(write: (text: string) => void, schedule: PaneWriteSchedule = defaultWriteSchedule, maxChars = PANE_WRITE_BATCH_MAX_CHARS) {
    this.write = write;
    this.schedule = schedule;
    this.maxChars = maxChars;
  }

  /** Queue text; `startsRepaint` forces the pending batch out first so the repaint leads its own write. */
  push(text: string, startsRepaint = false): void {
    if (text.length === 0) return;
    if (startsRepaint && this.pending.length > 0) this.flush();
    this.pending += text;
    if (this.pending.length >= this.maxChars) { this.flush(); return; }
    if (!this.scheduled) {
      this.scheduled = true;
      this.schedule(() => this.flush());
    }
  }

  /** Write everything pending now (also what the scheduled frame calls). */
  flush(): void {
    this.scheduled = false;
    if (this.pending.length === 0) return;
    const text = this.pending;
    this.pending = '';
    this.write(text);
  }

  /** Drop pending text without writing (the socket it came from is gone). */
  reset(): void {
    this.pending = '';
    this.scheduled = false;
  }

  get pendingLength(): number { return this.pending.length; }
}

/**
 * isPaneRepaintStart: does this write BEGIN an absolute repaint (erase-screen+home or an
 * alt-screen switch)? Used by the replay gates in both panes to suppress xterm's query
 * replies while the repaint is parsed. Accepts text or bytes.
 */
export function isPaneRepaintStart(data: string | Uint8Array): boolean {
  if (typeof data === 'string') return data.startsWith('\x1b[2J') || data.startsWith('\x1b[?1');
  return data.length >= 4 && data[0] === 0x1b && data[1] === 0x5b &&
    ((data[2] === 0x32 && data[3] === 0x4a) || (data[2] === 0x3f && data[3] === 0x31));
}

const ALT_HIDDEN_PREFIX = '\x1b[?1049h\x1b[?25l';
const ALT_PREFIX = '\x1b[?1049h';
const REPAINT_PREFIX = '\x1b[2J\x1b[H';

/**
 * Format a captured grid (already decoded to text) as an absolute repaint. REQ-PTY-NET-2:
 * the hooks decode frames through ONE streaming UTF-8 decoder per connection and hand text
 * on, so these helpers work on strings; the *Bytes variants below remain for callers that
 * still hold raw bytes (tests, the polled path).
 */
export function repaintCapturedScreenText(text: string, row = -1, col = -1): string {
  const lines = text.split(/\r?\n/);
  while (lines.length && lines[lines.length - 1].trim() === '') lines.pop();
  const body = lines.join('\r\n');
  const cursor = row >= 0 && col >= 0 ? `\x1b[${row + 1};${col + 1}H` : '';
  if (body.startsWith(ALT_HIDDEN_PREFIX)) {
    return `${ALT_HIDDEN_PREFIX}${REPAINT_PREFIX}${body.slice(ALT_HIDDEN_PREFIX.length)}${cursor}`;
  }
  if (body.startsWith(ALT_PREFIX)) {
    return `${ALT_PREFIX}${REPAINT_PREFIX}${body.slice(ALT_PREFIX.length)}${cursor}`;
  }
  return `${REPAINT_PREFIX}${body}${cursor}`;
}

/** Format an opaque captured grid after the UI decrypts it. */
export function repaintCapturedScreen(bytes: Uint8Array, row = -1, col = -1): Uint8Array {
  return new TextEncoder().encode(repaintCapturedScreenText(new TextDecoder().decode(bytes), row, col));
}

/**
 * Ensure bridge 0->1 catch-up snapshot frames (`is_snapshot: true`) carry an idempotent
 * erase-screen + cursor-home prefix so they repaint in place instead of appending duplicate
 * lines at the current cursor position and polluting scrollback.
 */
export function normalizeSnapshotText(decoded: string): string {
  if (
    decoded.startsWith(REPAINT_PREFIX) ||
    decoded.startsWith(`${ALT_PREFIX}${REPAINT_PREFIX}`) ||
    decoded.startsWith(`${ALT_HIDDEN_PREFIX}${REPAINT_PREFIX}`)
  ) {
    return decoded;
  }
  if (decoded.startsWith(ALT_HIDDEN_PREFIX)) {
    return `${ALT_HIDDEN_PREFIX}${REPAINT_PREFIX}${decoded.slice(ALT_HIDDEN_PREFIX.length)}`;
  }
  if (decoded.startsWith(ALT_PREFIX)) {
    return `${ALT_PREFIX}${REPAINT_PREFIX}${decoded.slice(ALT_PREFIX.length)}`;
  }
  return `${REPAINT_PREFIX}${decoded}`;
}

export function normalizeSnapshotBytes(bytes: Uint8Array): Uint8Array {
  const decoded = new TextDecoder().decode(bytes);
  const normalized = normalizeSnapshotText(decoded);
  return normalized === decoded ? bytes : new TextEncoder().encode(normalized);
}

/** Keep pasted input inside the Hub's frame budget without splitting a surrogate pair. */
export function splitPaneInput(data: string, maxCodeUnits = 8192): string[] {
  if (!Number.isSafeInteger(maxCodeUnits) || maxCodeUnits < 2) throw new RangeError('input chunk size must be at least two code units');
  const parts: string[] = [];
  for (let offset = 0; offset < data.length;) {
    let end = Math.min(offset + maxCodeUnits, data.length);
    const before = data.charCodeAt(end - 1);
    const after = data.charCodeAt(end);
    if (end < data.length && before >= 0xd800 && before <= 0xdbff && after >= 0xdc00 && after <= 0xdfff) end--;
    parts.push(data.slice(offset, end));
    offset = end;
  }
  return parts;
}
