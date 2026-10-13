export interface ResizeDispatchTimers {
  setTimeout: (callback: () => void, delayMs: number) => ReturnType<typeof setTimeout>;
  clearTimeout: (timer: ReturnType<typeof setTimeout>) => void;
}

export interface TerminalResizeDispatcher {
  schedule: (rows: number, cols: number) => void;
  flush: () => void;
  cancel: () => void;
}

/**
 * Coalesce a burst of renderer geometry changes into one PTY resize.
 *
 * CSS dock transitions and mobile viewport animations can produce a new terminal row count on
 * every frame. Sending every intermediate count makes full-screen programs redraw on every frame,
 * which can outpace xterm's parser and delay terminal-protocol replies. The renderer may still fit
 * immediately; only the remote PTY notification waits for stable geometry.
 */
export function createTerminalResizeDispatcher(
  dispatch: (rows: number, cols: number) => void,
  delayMs = 100,
  timers: ResizeDispatchTimers = {
    setTimeout: (callback, delay) => setTimeout(callback, delay),
    clearTimeout: (timer) => clearTimeout(timer),
  }
): TerminalResizeDispatcher {
  let timer: ReturnType<typeof setTimeout> | undefined;
  let pending: { rows: number; cols: number } | undefined;

  const cancelTimer = () => {
    if (timer !== undefined) {
      timers.clearTimeout(timer);
      timer = undefined;
    }
  };

  const flush = () => {
    cancelTimer();
    if (!pending) return;
    const next = pending;
    pending = undefined;
    dispatch(next.rows, next.cols);
  };

  return {
    schedule: (rows, cols) => {
      pending = { rows, cols };
      cancelTimer();
      timer = timers.setTimeout(flush, delayMs);
    },
    flush,
    cancel: () => {
      cancelTimer();
      pending = undefined;
    },
  };
}
