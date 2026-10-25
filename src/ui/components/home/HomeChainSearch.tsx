import React, { useEffect, useMemo, useRef, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { Icon, StatusDot } from '@ui';
import { useFetchHomeTaskChainsQuery } from '../../api/endpoints/tasks';
import { selectSearchChains } from '../../store/searchTitleSlice';
import { selectIsVaultUnlocked } from '../../store/vaultSlice';
import { buildRouteHash } from '../../utils/appLocation';
import { buildConversationHash, navigateToHash } from '../../utils/conversationUrl';
import { resolveChainConversationAgent } from '../../utils/chainConversation';
import { chainTargetId } from '../../utils/paneTarget';
import {
  searchTaskChainsEncrypted,
  taskChainSearchErrorMessage,
} from '../../utils/taskChainSearch';
import { useAuthUser } from '../auth/AuthUserContext';
import { useArchivedProjectIds } from '../projects/projectModel';
import { chainStatusDot } from '../ui/patterns/commandPaletteLogic';
import { VaultText } from '../vault/VaultText';
import {
  HOME_RECENT_CHAIN_LIMIT,
  HOME_REMOTE_SEARCH_MIN_CHARS,
  filterHomeChains,
  homeChainsFromFlatList,
  homeChainPage,
  homeChainsFromSearchHits,
  type HomeChainItem,
} from './homeChainSearchLogic';

function relativeTime(value: string): string {
  const t = new Date(value || '').getTime();
  if (!Number.isFinite(t) || t <= 0) return '';
  const min = Math.floor((Date.now() - t) / 60000);
  if (min < 1) return 'just now';
  if (min < 60) return `${min}m ago`;
  const h = Math.floor(min / 60);
  if (h < 24) return `${h}h ago`;
  const d = Math.floor(h / 24);
  if (d < 7) return `${d}d ago`;
  return new Date(t).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}

export interface HomeChainSearchProps {
  /**
   * Opens the chain's coordinator. Defaults to navigating to it (its saved
   * split group if it has one, else its single view). A Main new-chat pane
   * passes a handler that puts the coordinator into THAT pane.
   */
  /** Opens a pane target (an agent instance id or `chain:<id>`) in the hosting pane. */
  onOpenAgent?: (agentInstanceId: string) => void;
}

/**
 * Home view task chains: a search bar and ten-row pages of all owned chains.
 * Typing searches the unlocked Bridges (encrypted task-chain search)
 * and falls back to the loaded list when Bridge search is unavailable.
 */
export function HomeChainSearch({ onOpenAgent }: HomeChainSearchProps) {
  const { data, isLoading, isFetching, isError, refetch } = useFetchHomeTaskChainsQuery();
  const archivedProjectIds = useArchivedProjectIds();
  const decryptedTitles = useSelector(selectSearchChains) as Record<string, { decryptedTitle?: string }>;
  const isVaultUnlocked = useSelector(selectIsVaultUnlocked);
  const authUser = useAuthUser();
  const dispatch = useDispatch();
  const [query, setQuery] = useState('');
  const [remote, setRemote] = useState<{
    key: string;
    rows: HomeChainItem[] | null;
    state: 'idle' | 'searching' | 'stale' | 'error';
    error: string;
  } | null>(null);

  // Keep the full stable snapshot separate from the browse slice: page clicks
  // must not restart encrypted search or change its relevance ordering.
  const loaded = useMemo(() => homeChainsFromFlatList(data?.chains, archivedProjectIds), [data, archivedProjectIds]);
  const trimmed = query.trim();
  const searchKey = JSON.stringify([authUser?.user_id, isVaultUnlocked, trimmed]);
  const snapshot = JSON.stringify([authUser?.user_id, isVaultUnlocked, query, loaded.map((c) => c.chainId)]);
  const [browse, setBrowse] = useState({ snapshot, index: 0 });
  const page = homeChainPage(loaded, browse.snapshot === snapshot ? browse.index : 0);
  const listRef = useRef<HTMLUListElement>(null);
  const scrollRequested = useRef(false);
  const changePage = (delta: number) => {
    scrollRequested.current = true;
    setBrowse((old) => ({
      snapshot,
      index: Math.max(0, Math.min(page.pageCount - 1, (old.snapshot === snapshot ? old.index : 0) + delta)),
    }));
  };
  useEffect(() => {
    if (!scrollRequested.current) return;
    scrollRequested.current = false;
    const list = listRef.current;
    if (list && list.getBoundingClientRect().top < 0) {
      list.scrollIntoView({ block: 'start', behavior: 'smooth' });
    }
  }, [page.pageIndex]);
  useEffect(() => {
    setBrowse((old) => old.snapshot === snapshot ? old : { snapshot, index: 0 });
  }, [snapshot]);

  useEffect(() => {
    if (!isVaultUnlocked || trimmed.length < HOME_REMOTE_SEARCH_MIN_CHARS || !authUser?.user_id) {
      setRemote(null);
      return;
    }
    let canceled = false;
    setRemote(null);
    const timer = setTimeout(() => {
      setRemote({ key: searchKey, rows: null, state: 'searching', error: '' });
      searchTaskChainsEncrypted(trimmed, authUser.user_id!, { limit: HOME_RECENT_CHAIN_LIMIT })
        .then((response) => {
          if (canceled) return;
          setRemote({
            key: searchKey,
            rows: homeChainsFromSearchHits(response.hits, loaded),
            state: response.stale ? 'stale' : 'idle',
            error: '',
          });
        })
        .catch((error) => {
          if (canceled) return;
          setRemote({ key: searchKey, rows: null, state: 'error', error: taskChainSearchErrorMessage(error) });
        });
    }, 150);
    return () => {
      canceled = true;
      clearTimeout(timer);
    };
  }, [authUser?.user_id, isVaultUnlocked, loaded, trimmed, searchKey]);

  // Gate synchronously as well as canceling the effect so an old owner/query's
  // reply cannot appear for even one render during a reset.
  const activeRemote = isVaultUnlocked && trimmed.length >= HOME_REMOTE_SEARCH_MIN_CHARS && remote?.key === searchKey ? remote : null;
  const rows = trimmed ? (activeRemote?.rows ?? filterHomeChains(loaded, trimmed, decryptedTitles)) : page.rows;
  const remoteState = activeRemote?.state || 'idle';
  const remoteError = activeRemote?.error || '';

  // A chain opens as its chain-addressed coordinator conversation
  // (`chain:<id>`, REQ-TV2-7); whether it has a coordinator is resolved from the
  // chain detail when the list row lacks it. Only a chain without any
  // coordinator falls back to the chain page.
  const open = async (chain: HomeChainItem) => {
    const coordinator = await resolveChainConversationAgent(dispatch, chain.chainId, chain.coordinatorAgentInstanceId);
    if (coordinator) {
      const target = chainTargetId(chain.chainId);
      if (onOpenAgent) onOpenAgent(target);
      else navigateToHash(buildConversationHash([target]));
      return;
    }
    navigateToHash(buildRouteHash(`/chains/${encodeURIComponent(chain.chainId)}`, ''));
  };

  return (
    <section data-debug-id="home-chain-search" aria-label="Task chains" className="w-full space-y-2">
      <div className="relative">
        <Icon name="search" size={15} className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-muted" />
        <input
          type="search"
          data-debug-id="home-chain-search-input"
          value={query}
          onChange={(e) => {
            setQuery(e.target.value);
            setBrowse({ snapshot: '', index: 0 });
          }}
          placeholder="Search task chains…"
          aria-label="Search task chains"
          className="min-h-11 w-full rounded-2xl border border-subtle bg-surface pl-9 pr-3 text-base text-primary placeholder:text-muted focus:border-accent focus:outline-none sm:text-sm"
        />
      </div>
      {trimmed.length >= HOME_REMOTE_SEARCH_MIN_CHARS && remoteState !== 'idle' ? (
        <p data-debug-id="home-chain-search-state" className="px-1 text-xs text-faint">
          {remoteState === 'searching'
            ? 'Searching unlocked Bridges…'
            : remoteState === 'stale'
              ? 'Results may be stale.'
              : remoteError}
        </p>
      ) : null}
      {isError ? (
        <div role="status" className="flex flex-wrap items-center gap-2 px-1 text-sm text-muted">
          <span>{data ? 'Could not refresh task chains. Showing the previous list.' : 'Could not load task chains.'}</span>
          <button
            type="button"
            data-debug-id="home-chain-retry-btn"
            disabled={isFetching}
            onClick={() => void refetch()}
            className="min-h-11 rounded-xl px-3 text-accent hover:bg-neutral-soft disabled:opacity-50"
          >Retry</button>
        </div>
      ) : null}
      <ul ref={listRef} aria-label="Task chains" aria-busy={isFetching} data-debug-id="home-chain-list" className="divide-y divide-subtle overflow-hidden rounded-2xl border border-subtle bg-surface">
        {isLoading && !data ? (
          <li className="px-4 py-6 text-center text-sm text-muted">Loading task chains…</li>
        ) : isError && !data ? null : rows.length === 0 ? (
          <li data-debug-id="home-chain-empty" className="px-4 py-6 text-center text-sm text-muted">
            {trimmed ? 'No matching task chains.' : 'No task chains yet.'}
          </li>
        ) : (
          rows.map((chain) => (
            <li key={chain.chainId}>
              <button
                type="button"
                data-debug-id={`home-chain-row-${chain.chainId}`}
                onClick={() => void open(chain)}
                title={chain.coordinatorAgentInstanceId ? 'Open coordinator conversation' : 'Open task chain'}
                className="flex w-full min-w-0 items-center gap-3 px-4 py-2.5 text-left hover:bg-neutral-soft"
              >
                <StatusDot size="sm" {...chainStatusDot(chain.status)} label={chain.status || "unknown"} />
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-sm font-medium text-primary">
                    <VaultText value={decryptedTitles[chain.chainId]?.decryptedTitle || chain.title} fallback={chain.chainId} as="span" />
                  </span>
                  {chain.projectName ? (
                    <span className="block truncate text-xs text-muted">
                      <VaultText value={chain.projectName} fallback="" as="span" />
                    </span>
                  ) : null}
                </span>
                <span className="shrink-0 text-xs text-faint">{relativeTime(chain.updatedAt)}</span>
              </button>
            </li>
          ))
        )}
      </ul>
      {!trimmed && (data || isLoading) ? (
        <nav aria-label="Task chain pages" className="flex min-w-0 flex-wrap items-center justify-between gap-2">
          <button
            type="button"
            data-debug-id="home-chain-prev-btn"
            disabled={!data || !page.hasPrevious}
            onClick={() => changePage(-1)}
            className="min-h-11 rounded-xl border border-subtle px-3 text-sm hover:bg-neutral-soft disabled:opacity-50"
          >Previous</button>
          <span data-debug-id="home-chain-page-status" role="status" aria-live="polite" aria-atomic="true" className="text-xs text-muted">
            {isLoading && !data ? 'Loading…' : `Page ${page.pageCount ? page.pageIndex + 1 : 0} of ${page.pageCount}`}
          </span>
          <button
            type="button"
            data-debug-id="home-chain-next-btn"
            disabled={!data || !page.hasNext}
            onClick={() => changePage(1)}
            className="min-h-11 rounded-xl border border-subtle px-3 text-sm hover:bg-neutral-soft disabled:opacity-50"
          >Next</button>
        </nav>
      ) : null}
    </section>
  );
}

export default HomeChainSearch;
