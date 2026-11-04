import { useEffect, useState } from 'react';

/**
 * The ticket views' tick. Their live values are minutes ("14m left", "12m ago"),
 * and every tick re-renders the whole board or ticket, so a slow tick is enough.
 */
export const TICKET_CLOCK_MS = 30_000;

/**
 * A local clock for countdowns and "12m ago" labels (ticket board spec, Live
 * updates rules): live values are derived from timestamps on this tick, never
 * by refetching. One timer per subscriber; it stops while the page is hidden.
 */
export function useTicketClock(intervalMs = TICKET_CLOCK_MS): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    let id: ReturnType<typeof setInterval> | null = null;
    const start = () => {
      if (id === null) id = setInterval(() => setNow(Date.now()), intervalMs);
    };
    const stop = () => {
      if (id !== null) clearInterval(id);
      id = null;
    };
    const onVisibility = () => {
      if (typeof document !== 'undefined' && document.hidden) stop();
      else {
        setNow(Date.now());
        start();
      }
    };
    start();
    if (typeof document !== 'undefined') document.addEventListener('visibilitychange', onVisibility);
    return () => {
      stop();
      if (typeof document !== 'undefined') document.removeEventListener('visibilitychange', onVisibility);
    };
  }, [intervalMs]);
  return now;
}

/** True when the user asked for reduced motion; follows changes to the setting. */
export function usePrefersReducedMotion(): boolean {
  const query = '(prefers-reduced-motion: reduce)';
  const [reduced, setReduced] = useState(() => typeof window !== 'undefined' && typeof window.matchMedia === 'function' && window.matchMedia(query).matches);
  useEffect(() => {
    if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return;
    const mql = window.matchMedia(query);
    const onChange = () => setReduced(mql.matches);
    mql.addEventListener?.('change', onChange);
    return () => mql.removeEventListener?.('change', onChange);
  }, []);
  return reduced;
}
