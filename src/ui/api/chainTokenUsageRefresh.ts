/**
 * Chain token-usage refresh pacing (T14: the token reporting feature must not
 * add needless hub calls).
 *
 * The chain overview's token card (T10) is an aggregate the hub computes, so an
 * instance's token event cannot patch it in place. Instead of one
 * GET /task-chains/{id}/token-usage per event, refreshes are:
 *   - only for chains whose card is mounted (viewed); an event for any other
 *     chain just marks it stale, and it refreshes once when it is shown again;
 *   - throttled per chain: at most one per CHAIN_TOKEN_USAGE_REFRESH_MS, the
 *     first at once and the rest folded into one trailing refresh at the end of
 *     the window (so the card still converges on the latest numbers).
 *
 * The module holds no store reference: callers pass the invalidate callback.
 */

export const CHAIN_TOKEN_USAGE_REFRESH_MS = 15_000;

type Invalidate = (chainId: string) => void;

interface RefreshWindow {
  last: number;
  timer: ReturnType<typeof setTimeout> | null;
}

const viewers = new Map<string, number>();
const staleChains = new Set<string>();
const windows = new Map<string, RefreshWindow>();

export function isChainTokenUsageViewed(chainId: string): boolean {
  return (viewers.get(chainId) || 0) > 0;
}

/**
 * Registers a mounted token card for chainId. Returns whether events were
 * dropped while nobody was viewing it (the caller refreshes once) and the
 * release callback for unmount.
 */
export function retainChainTokenUsageView(chainId: string): { stale: boolean; release: () => void } {
  if (!chainId) return { stale: false, release: () => {} };
  viewers.set(chainId, (viewers.get(chainId) || 0) + 1);
  const stale = staleChains.delete(chainId);
  let released = false;
  return {
    stale,
    release: () => {
      if (released) return;
      released = true;
      const left = (viewers.get(chainId) || 0) - 1;
      if (left > 0) { viewers.set(chainId, left); return; }
      viewers.delete(chainId);
      // A trailing refresh nobody will see becomes a stale mark instead.
      const w = windows.get(chainId);
      if (w?.timer) {
        clearTimeout(w.timer);
        w.timer = null;
        staleChains.add(chainId);
      }
    },
  };
}

/**
 * Asks for chainId's token usage to be refreshed after a token change. Calls
 * invalidate now, later (one trailing call per window), or not at all (chain
 * not viewed: marked stale).
 */
export function requestChainTokenUsageRefresh(chainId: string, invalidate: Invalidate, now: number = Date.now()): void {
  if (!chainId) return;
  if (!isChainTokenUsageViewed(chainId)) { staleChains.add(chainId); return; }
  const w = windows.get(chainId) || { last: Number.NEGATIVE_INFINITY, timer: null };
  windows.set(chainId, w);
  if (w.timer) return; // a trailing refresh is already scheduled
  const wait = w.last + CHAIN_TOKEN_USAGE_REFRESH_MS - now;
  if (wait <= 0) {
    w.last = now;
    invalidate(chainId);
    return;
  }
  w.timer = setTimeout(() => {
    w.timer = null;
    if (!isChainTokenUsageViewed(chainId)) { staleChains.add(chainId); return; }
    w.last = Date.now();
    invalidate(chainId);
  }, wait);
}

/** Test/reset hook: forgets viewers, stale marks and pending timers. */
export function resetChainTokenUsageRefresh(): void {
  for (const w of windows.values()) if (w.timer) clearTimeout(w.timer);
  windows.clear();
  viewers.clear();
  staleChains.clear();
}
