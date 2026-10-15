import { splitPaneInput } from './paneDeliveryQueue.ts';

/**
 * REQ-PTY-NET-3: coalesce terminal input within one macrotask before it goes on the wire.
 *
 * xterm fires `onData` once per key event (and once per IME commit / paste), and each call
 * used to become its own WebSocket frame, hub command and bridge frame. Key-repeat and
 * bracketed paste deliver many `onData` calls inside one turn of the event loop; folding
 * them into a single send costs no observable latency (nothing can leave before the task
 * ends anyway) and removes a frame per character on the three hops behind it.
 *
 * The flush still honours the hub's per-frame input budget via splitPaneInput, which never
 * splits a surrogate pair.
 */
export interface InputCoalescer {
  /** Queue input; the first call in a task schedules the flush. */
  push(data: string): void;
  /** Send everything queued now (also what the scheduled flush calls). */
  flush(): void;
  /** Drop anything queued without sending — used when the socket goes away. */
  reset(): void;
  readonly pendingLength: number;
}

export type InputCoalescerSchedule = (flush: () => void) => void;

const defaultSchedule: InputCoalescerSchedule = (flush) => { setTimeout(flush, 0); };

export function createInputCoalescer(
  send: (chunk: string) => void,
  schedule: InputCoalescerSchedule = defaultSchedule,
  maxCodeUnits = 8192,
): InputCoalescer {
  let pending = '';
  let scheduled = false;
  const flush = () => {
    scheduled = false;
    if (pending.length === 0) return;
    const data = pending;
    pending = '';
    for (const part of splitPaneInput(data, maxCodeUnits)) send(part);
  };
  return {
    push(data: string) {
      if (data.length === 0) return;
      pending += data;
      if (!scheduled) {
        scheduled = true;
        schedule(flush);
      }
    },
    flush,
    reset() {
      pending = '';
      scheduled = false;
    },
    get pendingLength() { return pending.length; },
  };
}
