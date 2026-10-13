interface ResizeTimers {
  setTimeout: (callback: () => void, delayMs: number) => ReturnType<typeof setTimeout>;
  clearTimeout: (timer: ReturnType<typeof setTimeout>) => void;
}

export function createTerminalResizeDispatcher(
  dispatch: (rows: number, cols: number) => void,
  delayMs = 100,
  timers: ResizeTimers = {
    setTimeout: (callback, delay) => setTimeout(callback, delay),
    clearTimeout: (timer) => clearTimeout(timer),
  }
) {
  let timer: ReturnType<typeof setTimeout> | undefined;
  let pending: { rows: number; cols: number } | undefined;

  const cancel = () => {
    if (timer !== undefined) timers.clearTimeout(timer);
    timer = undefined;
  };

  const flush = () => {
    cancel();
    if (!pending) return;
    const next = pending;
    pending = undefined;
    dispatch(next.rows, next.cols);
  };

  return {
    schedule(rows: number, cols: number) {
      pending = { rows, cols };
      cancel();
      timer = timers.setTimeout(flush, delayMs);
    },
    cancel() {
      cancel();
      pending = undefined;
    },
  };
}
