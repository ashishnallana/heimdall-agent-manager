import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { Icon, StatusDot, useInfiniteList } from '@ui';
import { fetchSidebarTaskChainPage, type ChainListItem } from '../../api/endpoints/tasks';
import { subscribeTaskChainCreation, taskChainCreationRevision } from '../../api/taskChainCreationEvents';
import { selectSearchChains } from '../../store/searchTitleSlice';
import { selectIsVaultUnlocked } from '../../store/vaultSlice';
import { buildRouteHash } from '../../utils/appLocation';
import { chainConversationRoute } from '../../utils/paneTarget';
import { navigateToHash } from '../../utils/conversationUrl';
import { resolveChainConversationAgent } from '../../utils/chainConversation';
import { searchTaskChainsEncrypted, taskChainSearchErrorMessage } from '../../utils/taskChainSearch';
import { useAuthUser } from '../auth/AuthUserContext';
import { chainStatusDot } from '../ui/patterns/commandPaletteLogic';
import { VaultText } from '../vault/VaultText';
import {
  filterHomeChains, homeChainsFromFlatList, homeChainsFromSearchHits,
  HOME_RECENT_CHAIN_LIMIT, HOME_REMOTE_SEARCH_MIN_CHARS, type HomeChainItem,
} from '../home/homeChainSearchLogic';

export interface SidebarTaskChainsProps {
  scrollRoot: HTMLElement | null;
  active: boolean;
  currentPath: string;
  onNavigate?: () => void;
  onChainsChange?: (chains: ChainListItem[]) => void;
}

/** One list inside the navigation scroller. No timer, focus/reconnect fetch,
 * RTK subscription, or per-row task fetch: only initial load, paging, retry and
 * the successful-creation signal can fetch a list page.
 */
export function SidebarTaskChains({ scrollRoot, active, currentPath, onNavigate, onChainsChange }: SidebarTaskChainsProps) {
  const dispatch = useDispatch();
  const creationRevision = useSyncExternalStore(subscribeTaskChainCreation, taskChainCreationRevision);
  const seenCursors = useRef(new Set<string>());
  const fetchPage = useCallback(async ({ cursor, signal }: { cursor: string; signal: AbortSignal }) => {
    if (!cursor) seenCursors.current.clear();
    const page = await fetchSidebarTaskChainPage({ cursor, signal });
    signal.throwIfAborted();
    // Reject a cyclic cursor rather than issuing repeated automatic requests.
    if (page.has_more && seenCursors.current.has(page.next_cursor)) {
      throw new Error('Task chain pagination did not advance');
    }
    seenCursors.current.add(cursor);
    return page;
  }, []);
  const list = useInfiniteList<ChainListItem>({
    fetchPage,
    getItemId: chain => chain.chainId,
    resetKey: String(creationRevision),
    root: scrollRoot,
    rootMargin: '120px',
  });
  useEffect(() => { onChainsChange?.(list.items); }, [list.items, onChainsChange]);
  const loaded = useMemo(() => homeChainsFromFlatList(list.items), [list.items]);
  const titles = useSelector(selectSearchChains) as Record<string, { decryptedTitle?: string }>;
  const unlocked = useSelector(selectIsVaultUnlocked);
  const user = useAuthUser();
  const [query, setQuery] = useState('');
  const trimmed = query.trim();
  const searchKey = JSON.stringify([user?.user_id, unlocked, trimmed]);
  const [remote, setRemote] = useState<{
    key: string; rows: HomeChainItem[] | null; state: 'searching' | 'stale' | 'error' | 'idle'; error?: string;
  } | null>(null);
  useEffect(() => {
    if (!unlocked || trimmed.length < HOME_REMOTE_SEARCH_MIN_CHARS || !user?.user_id) {
      setRemote(null);
      return;
    }
    let cancelled = false;
    setRemote(null);
    const timer = setTimeout(() => {
      setRemote({ key: searchKey, rows: null, state: 'searching' });
      searchTaskChainsEncrypted(trimmed, user.user_id!, { limit: HOME_RECENT_CHAIN_LIMIT })
        .then(response => {
          if (!cancelled) setRemote({
            key: searchKey, rows: homeChainsFromSearchHits(response.hits, loaded),
            state: response.stale ? 'stale' : 'idle',
          });
        })
        .catch(error => {
          if (!cancelled) setRemote({ key: searchKey, rows: null, state: 'error', error: taskChainSearchErrorMessage(error) });
        });
    }, 150);
    return () => { cancelled = true; clearTimeout(timer); };
  }, [searchKey, trimmed, unlocked, user?.user_id, loaded]);
  const activeRemote = unlocked && remote?.key === searchKey ? remote : null;
  const rows = trimmed ? activeRemote?.rows ?? filterHomeChains(loaded, trimmed, titles, Infinity) : loaded;
  const canPage = active && !trimmed && list.status === 'ready' && list.hasMore && !list.isPaging && !list.pagingError;
  // Reattach after each page: if the sentinel is still visible, IntersectionObserver
  // emits its initial entry again. This fills tall viewports and short/duplicate pages.
  const sentinelRef = useCallback((node: HTMLDivElement | null) => {
    list.sentinelRef(canPage ? node : null);
  }, [list.sentinelRef, canPage, list.pagesLoaded]);

  const open = async (event: React.MouseEvent<HTMLAnchorElement>, chain: HomeChainItem) => {
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    const coordinator = await resolveChainConversationAgent(dispatch, chain.chainId, chain.coordinatorAgentInstanceId);
    navigateToHash(buildRouteHash(coordinator ? chainConversationRoute(chain.chainId) : `/chains/${encodeURIComponent(chain.chainId)}`, ''));
    onNavigate?.();
  };
  return (
    <section aria-label="Task chains" data-debug-id="sidebar-task-chains" className="mt-4 min-w-0 border-t border-subtle pt-3">
      <h2 className="mb-2 px-2.5 text-xs font-semibold text-muted">Task chains</h2>
      <div className="relative mb-2">
        <Icon name="search" size={14} className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-muted" />
        <input type="search" aria-label="Search task chains" placeholder="Search task chains…"
          data-debug-id="sidebar-chain-search" value={query} onChange={event => setQuery(event.target.value)}
          className="min-h-11 w-full min-w-0 rounded-xl border border-subtle bg-surface pl-9 pr-3 text-base text-primary placeholder:text-muted focus:border-accent focus:outline-none sm:text-sm" />
      </div>
      {activeRemote && activeRemote.state !== 'idle' ? (
        <p role="status" className="px-2.5 py-2 text-xs text-muted">
          {activeRemote.state === 'searching' ? 'Searching unlocked Bridges…' : activeRemote.state === 'stale' ? 'Results may be stale.' : activeRemote.error}
        </p>
      ) : null}
      <ul aria-label="Task chains" aria-busy={list.isLoadingInitial || list.isPaging} className="space-y-0.5">
        {(list.status === 'loading' || list.status === 'idle') && !list.items.length ? (
          <li role="status" className="px-2.5 py-3 text-sm text-muted">Loading task chains…</li>
        ) : list.status === 'error' && !list.items.length ? null : rows.length === 0 ? (
          <li data-debug-id="sidebar-chain-empty" className="px-2.5 py-3 text-sm text-muted">
            {trimmed ? 'No matching task chains.' : 'No task chains yet.'}
          </li>
        ) : rows.map(chain => (
          <li key={chain.chainId}>
            <a href={buildRouteHash(chainConversationRoute(chain.chainId), '')}
              onClick={event => void open(event, chain)}
              data-debug-id={`sidebar-chain-row-${chain.chainId}`}
              aria-current={currentPath === chainConversationRoute(chain.chainId) ? 'page' : undefined}
              title="Open coordinator conversation"
              className={`flex min-h-11 min-w-0 items-center gap-2 rounded-xl px-2.5 py-2 hover:bg-neutral-soft ${currentPath === chainConversationRoute(chain.chainId) ? 'bg-neutral-soft font-semibold' : ''}`}>
              <StatusDot size="sm" {...chainStatusDot(chain.status)} label={chain.status || 'unknown'} />
              <span className="min-w-0 flex-1">
                <span className="block truncate text-[13px] font-medium text-primary">
                  <VaultText value={titles[chain.chainId]?.decryptedTitle || chain.title} fallback={chain.chainId} />
                </span>
                {chain.projectName ? <span className="block truncate text-xs text-muted"><VaultText value={chain.projectName} /></span> : null}
              </span>
            </a>
          </li>
        ))}
      </ul>
      {list.status === 'error' || list.pagingError ? (
        <div role="status" className="px-2.5 py-2 text-xs text-muted">
          <p>{list.pagingError ? 'Could not load more task chains.' : 'Could not load task chains.'}</p>
          <button type="button" data-debug-id="sidebar-chain-retry" onClick={list.pagingError ? list.loadMore : list.reload}
            className="min-h-11 rounded-xl px-3 text-sm text-accent hover:bg-neutral-soft">Retry</button>
        </div>
      ) : null}
      {list.isLoadingInitial && list.items.length > 0 ? <p role="status" className="px-2.5 py-3 text-xs text-muted">Refreshing task chains…</p> : null}
      {list.isPaging ? <p role="status" className="px-2.5 py-3 text-xs text-muted">Loading more task chains…</p> : null}
      <div ref={sentinelRef} data-debug-id="sidebar-chain-sentinel" aria-hidden="true" className="h-px" />
    </section>
  );
}
