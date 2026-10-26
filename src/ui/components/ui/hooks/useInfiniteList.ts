/**
 * useInfiniteList — keyset-paged infinite scrolling, with the list conventions built in.
 * ------------------------------------------------------------------
 * Purpose: REQ-UI-6's infinite scroll for every resource list, implemented once.
 * Heimdall's list endpoints are KEYSET paged — `limit` + `cursor` in, `{next_cursor,
 * has_more}` out, and **no total count** — so numbered pages and "N of M" are not
 * expressible and are not offered here.
 *
 * NOT for: offset pagination (use `Pagination`), or a list small enough to load whole.
 *
 * Layer: hook. Product-agnostic: it knows nothing about any resource. The cursor
 * COLUMN is per resource (memories key on `updated_at`, agents/projects on
 * `created_at`), so this hook never reads a date field itself — the caller supplies
 * `getCursorValue` if it wants change detection, and the cursor string is otherwise
 * opaque and passed straight back to `fetchPage`.
 *
 * What it carries, so no caller re-implements it:
 *   - **Sentinel paging.** `sentinelRef` is a callback ref for an element at the list
 *     foot; an `IntersectionObserver` calls `loadMore()` when it comes into view.
 *   - **De-duplication by id before append.** A keyset window can repeat a row when
 *     the sort column changes mid-scroll; a repeat is never rendered twice.
 *   - **Hold-position refresh.** `refresh()` probes page one WITHOUT touching the
 *     rendered rows and reports `pendingCount` — the "N new or updated" pill. Nothing
 *     re-sorts under the user. `applyPending()` is the only thing that re-fetches.
 *   - **Act in place.** `patchItem(id, next)` updates a row the user just mutated where
 *     it already sits; it never jumps to the top. Pass the server's returned row so the
 *     next probe sees it as unchanged.
 *   - **Capped scroll restoration.** `restoreToId(id)` re-pages from page one looking
 *     for a remembered row, stopping at whichever comes first: `pageCap` pages (5) or
 *     `rowCap` rows (250). Not found → the pages stay loaded, `restoreNotice` goes true
 *     and the caller lands the user at the top with a one-line note.
 *
 * Why a cap: with a mutable sort column the remembered row may have moved or left the
 * filter entirely, so an uncapped search would page the whole table and still miss.
 */
import { useCallback, useEffect, useRef, useState } from 'react';

/** One page as the list endpoints return it. Field names mirror the API. */
export interface InfiniteListPage<T> {
  items: T[];
  /** Cursor for the NEXT page. Opaque — passed straight back to `fetchPage`. */
  next_cursor: string;
  has_more: boolean;
}

export interface InfiniteListFetchArgs {
  /** `''` for the first page, else the previous page's `next_cursor`. */
  cursor: string;
  /** Aborted when the list resets (filters changed, unmounted, restore started). */
  signal: AbortSignal;
}

/** Lifecycle of the FIRST page. Paging state is reported separately. */
export type InfiniteListStatus = 'idle' | 'loading' | 'ready' | 'error';

/** Outcome of `restoreToId`. `aborted` = the fetch failed or the list reset under it. */
export type RestoreOutcome = 'found' | 'not-found' | 'aborted';

/** Appendix A: restoration is capped at 5 pages / 250 rows. */
const DEFAULT_PAGE_CAP = 5;
const DEFAULT_ROW_CAP = 250;

export interface UseInfiniteListOptions<T> {
  /** Fetches one page. Must honour `signal` and return the API's own shape. */
  fetchPage: (args: InfiniteListFetchArgs) => Promise<InfiniteListPage<T>>;
  /** Stable identity of a row. Used for de-duplication, patching and restoration. */
  getItemId: (item: T) => string;
  /**
   * The row's value in the resource's cursor column (`updated_at`, `created_at`, …).
   * Optional, and read ONLY to tell "this row changed" from "this row is the same"
   * when probing for `pendingCount`. Omit it and a probe counts only NEW ids.
   */
  getCursorValue?: (item: T) => string;
  /**
   * Changing this resets the list and re-fetches from page one — the tab, filters and
   * query belong here. Same value = same list, so a re-render never re-fetches.
   */
  resetKey?: string;
  /** When false the list neither fetches nor observes. Default `true`. */
  enabled?: boolean;
  /** Max pages `restoreToId` will walk. Default 5. */
  pageCap?: number;
  /** Max rows `restoreToId` will accumulate. Default 250. */
  rowCap?: number;
  /**
   * How far below the viewport the sentinel triggers the next page. A prefetch
   * distance for the observer, not a style value. Default `'200px'`.
   */
  rootMargin?: string;
  /** Scroll container for the sentinel. Default: the document viewport. */
  root?: Element | null;
}

export interface UseInfiniteList<T> {
  /** The loaded rows, in server order, de-duplicated by id. */
  items: T[];
  /** First-page lifecycle. `error` means there is nothing to show. */
  status: InfiniteListStatus;
  /** The first-page failure, when `status === 'error'`. */
  error: unknown;
  /**
   * A failure while paging. The loaded rows are KEPT — render a retry strip at the
   * list foot rather than replacing the list.
   */
  pagingError: unknown;
  /** True while the first page is in flight (render skeleton rows). */
  isLoadingInitial: boolean;
  /** True while a subsequent page is in flight (render a short foot skeleton). */
  isPaging: boolean;
  /** Whether the server says more rows exist. */
  hasMore: boolean;
  /** Rows loaded so far — the honest denominator for "of the N loaded". */
  loadedCount: number;
  /** Pages fetched since the last reset. */
  pagesLoaded: number;
  /** Callback ref for the sentinel element at the list foot. */
  sentinelRef: (node: Element | null) => void;
  /** Fetch the next page. Safe to call redundantly; no-ops when it cannot. */
  loadMore: () => void;
  /** Discard everything and re-fetch from page one. */
  reload: () => void;
  /** Probe page one without disturbing the rendered rows; updates `pendingCount`. */
  refresh: () => void;
  /** How many rows are new or changed since the last probe — the "N new or updated" pill. */
  pendingCount: number;
  /** Apply the pill: re-fetch from page one. The only thing that re-sorts the list. */
  applyPending: () => void;
  /** Update one row where it sits. No reorder, no re-fetch. */
  patchItem: (id: string, next: T | ((prev: T) => T)) => void;
  /** Re-page from page one looking for a remembered row, capped. */
  restoreToId: (id: string) => Promise<RestoreOutcome>;
  /** True when the last restore ran out of cap — show the "couldn't find where you were" note. */
  restoreNotice: boolean;
  /** Dismiss that note (the caller does this on the next scroll). */
  dismissRestoreNotice: () => void;
}

/** Appends `incoming` to `base`, dropping ids already present. Preserves server order. */
function appendDeduped<T>(base: T[], incoming: T[], getItemId: (item: T) => string): T[] {
  const seen = new Set(base.map(getItemId));
  const out = base.slice();
  for (const item of incoming) {
    const id = getItemId(item);
    if (seen.has(id)) continue;
    seen.add(id);
    out.push(item);
  }
  return out;
}

export function useInfiniteList<T>(options: UseInfiniteListOptions<T>): UseInfiniteList<T> {
  const {
    resetKey = '',
    enabled = true,
    pageCap = DEFAULT_PAGE_CAP,
    rowCap = DEFAULT_ROW_CAP,
    rootMargin = '200px',
    root = null,
  } = options;

  const [items, setItems] = useState<T[]>([]);
  const [status, setStatus] = useState<InfiniteListStatus>('idle');
  const [error, setError] = useState<unknown>(null);
  const [pagingError, setPagingError] = useState<unknown>(null);
  const [isPaging, setIsPaging] = useState(false);
  const [hasMore, setHasMore] = useState(false);
  const [pagesLoaded, setPagesLoaded] = useState(0);
  const [pendingCount, setPendingCount] = useState(0);
  const [restoreNotice, setRestoreNotice] = useState(false);

  // The callbacks are read through refs so an inline `fetchPage={...}` (the normal
  // call-site shape) does not re-run the load effect on every render.
  const fetchPageRef = useRef(options.fetchPage);
  fetchPageRef.current = options.fetchPage;
  const getItemIdRef = useRef(options.getItemId);
  getItemIdRef.current = options.getItemId;
  const getCursorValueRef = useRef(options.getCursorValue);
  getCursorValueRef.current = options.getCursorValue;

  // Live mirrors of state, for the async paths that must read the CURRENT value.
  const itemsRef = useRef<T[]>(items);
  itemsRef.current = items;
  const statusRef = useRef<InfiniteListStatus>(status);
  statusRef.current = status;
  const hasMoreRef = useRef(hasMore);
  hasMoreRef.current = hasMore;

  const cursorRef = useRef('');
  const pagingRef = useRef(false);
  // Monotonic run id: any result from a superseded run is dropped on arrival.
  const runRef = useRef(0);
  const abortRef = useRef<AbortController | null>(null);
  const mountedRef = useRef(true);

  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
      abortRef.current?.abort();
    };
  }, []);

  /** Supersede every in-flight request and start a new run. */
  const beginRun = useCallback(() => {
    abortRef.current?.abort();
    const controller = new AbortController();
    abortRef.current = controller;
    runRef.current += 1;
    return { run: runRef.current, signal: controller.signal };
  }, []);

  const commit = useCallback((next: T[], cursor: string, more: boolean, pages: number) => {
    cursorRef.current = cursor;
    setItems(next);
    setHasMore(more);
    setPagesLoaded(pages);
  }, []);

  const loadFirstPage = useCallback(async () => {
    const { run, signal } = beginRun();
    setStatus('loading');
    setError(null);
    setPagingError(null);
    setPendingCount(0);
    setRestoreNotice(false);
    // A page that was in flight has just been superseded; its `finally` is guarded on
    // the run id and will not clear this, so the reset path must.
    pagingRef.current = false;
    setIsPaging(false);
    try {
      const page = await fetchPageRef.current({ cursor: '', signal });
      if (run !== runRef.current || !mountedRef.current) return;
      commit(appendDeduped<T>([], page.items, getItemIdRef.current), page.next_cursor, page.has_more, 1);
      setStatus('ready');
    } catch (err) {
      if (signal.aborted || run !== runRef.current || !mountedRef.current) return;
      setError(err);
      setStatus('error');
    }
  }, [beginRun, commit]);

  const reload = useCallback(() => {
    if (!enabled) return;
    void loadFirstPage();
  }, [enabled, loadFirstPage]);

  const pagesLoadedRef = useRef(pagesLoaded);
  pagesLoadedRef.current = pagesLoaded;

  const loadMore = useCallback(() => {
    if (!enabled) return;
    if (pagingRef.current) return;
    if (statusRef.current !== 'ready') return;
    if (!hasMoreRef.current) return;

    const run = runRef.current;
    const signal = abortRef.current?.signal;
    if (!signal) return;

    pagingRef.current = true;
    setIsPaging(true);
    setPagingError(null);

    void (async () => {
      try {
        const page = await fetchPageRef.current({ cursor: cursorRef.current, signal });
        if (run !== runRef.current || !mountedRef.current) return;
        commit(
          appendDeduped(itemsRef.current, page.items, getItemIdRef.current),
          page.next_cursor,
          page.has_more,
          pagesLoadedRef.current + 1,
        );
      } catch (err) {
        if (signal.aborted || run !== runRef.current || !mountedRef.current) return;
        // The loaded rows survive a paging failure — scrolling never destroys them.
        setPagingError(err);
      } finally {
        if (run === runRef.current) {
          pagingRef.current = false;
          if (mountedRef.current) setIsPaging(false);
        }
      }
    })();
  }, [commit, enabled]);

  const loadMoreRef = useRef(loadMore);
  loadMoreRef.current = loadMore;

  /**
   * Probe page one and count what is new or changed, WITHOUT touching the rendered
   * rows. A failed probe is swallowed: a background check must never turn a working
   * list into an error state.
   */
  const refresh = useCallback(() => {
    if (!enabled) return;
    if (statusRef.current !== 'ready') return;
    const controller = new AbortController();
    void (async () => {
      try {
        const page = await fetchPageRef.current({ cursor: '', signal: controller.signal });
        if (!mountedRef.current) return;
        const getItemId = getItemIdRef.current;
        const getCursorValue = getCursorValueRef.current;
        const loaded = new Map(itemsRef.current.map((item) => [getItemId(item), item] as const));
        let count = 0;
        for (const item of page.items) {
          const existing = loaded.get(getItemId(item));
          if (!existing) {
            count += 1;
          } else if (getCursorValue && getCursorValue(item) !== getCursorValue(existing)) {
            count += 1;
          }
        }
        setPendingCount(count);
      } catch {
        /* A probe never disturbs the list. */
      }
    })();
  }, [enabled]);

  const applyPending = useCallback(() => {
    setPendingCount(0);
    reload();
  }, [reload]);

  const patchItem = useCallback((id: string, next: T | ((prev: T) => T)) => {
    setItems((prev) => {
      const getItemId = getItemIdRef.current;
      let changed = false;
      const out = prev.map((item) => {
        if (getItemId(item) !== id) return item;
        changed = true;
        return typeof next === 'function' ? (next as (prev: T) => T)(item) : next;
      });
      return changed ? out : prev;
    });
  }, []);

  const restoreToId = useCallback(
    async (id: string): Promise<RestoreOutcome> => {
      if (!enabled) return 'aborted';
      const { run, signal } = beginRun();
      setStatus('loading');
      setError(null);
      setPagingError(null);
      setPendingCount(0);
      setRestoreNotice(false);
      pagingRef.current = false;
      setIsPaging(false);

      const getItemId = getItemIdRef.current;
      let acc: T[] = [];
      let cursor = '';
      let more = true;
      let pages = 0;
      let found = false;

      try {
        while (more && pages < pageCap && acc.length < rowCap) {
          const page = await fetchPageRef.current({ cursor, signal });
          if (run !== runRef.current || !mountedRef.current) return 'aborted';
          pages += 1;
          acc = appendDeduped(acc, page.items, getItemId);
          cursor = page.next_cursor;
          more = page.has_more;
          if (acc.some((item) => getItemId(item) === id)) {
            found = true;
            break;
          }
        }
        commit(acc, cursor, more, pages);
        setStatus('ready');
        // Not found within the cap, or found but no longer in this tab/filter (which
        // reads the same way — it simply is not in the result): land at the top and
        // say so. Silently landing somewhere else is more disorienting than a line.
        if (!found) setRestoreNotice(true);
        return found ? 'found' : 'not-found';
      } catch (err) {
        if (signal.aborted || run !== runRef.current || !mountedRef.current) return 'aborted';
        setError(err);
        setStatus('error');
        return 'aborted';
      }
    },
    [beginRun, commit, enabled, pageCap, rowCap],
  );

  const dismissRestoreNotice = useCallback(() => setRestoreNotice(false), []);

  // Reset + first fetch. `resetKey` is the tab/filters/query identity.
  useEffect(() => {
    if (!enabled) {
      abortRef.current?.abort();
      runRef.current += 1;
      return;
    }
    void loadFirstPage();
  }, [enabled, resetKey, loadFirstPage]);

  // Sentinel. A callback ref so the observer attaches the moment the element exists
  // (and re-attaches if the list swaps its foot element between states).
  const observerRef = useRef<IntersectionObserver | null>(null);
  useEffect(() => () => observerRef.current?.disconnect(), []);

  const sentinelRef = useCallback(
    (node: Element | null) => {
      observerRef.current?.disconnect();
      observerRef.current = null;
      if (!node || typeof IntersectionObserver === 'undefined') return;
      const observer = new IntersectionObserver(
        (entries) => {
          if (entries.some((entry) => entry.isIntersecting)) loadMoreRef.current();
        },
        { root, rootMargin },
      );
      observer.observe(node);
      observerRef.current = observer;
    },
    [root, rootMargin],
  );

  return {
    items,
    status,
    error,
    pagingError,
    isLoadingInitial: status === 'loading',
    isPaging,
    hasMore,
    loadedCount: items.length,
    pagesLoaded,
    sentinelRef,
    loadMore,
    reload,
    refresh,
    pendingCount,
    applyPending,
    patchItem,
    restoreToId,
    restoreNotice,
    dismissRestoreNotice,
  };
}

export default useInfiniteList;
