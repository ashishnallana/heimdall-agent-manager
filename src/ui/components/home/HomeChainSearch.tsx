import React, { useEffect, useMemo, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { Icon, StatusDot } from '@ui';
import { useFetchTaskChainGroupsQuery } from '../../api/endpoints/tasks';
import { selectSearchChains } from '../../store/searchTitleSlice';
import { selectIsVaultUnlocked } from '../../store/vaultSlice';
import { buildRouteHash } from '../../utils/appLocation';
import { buildConversationHash, navigateToHash } from '../../utils/conversationUrl';
import { resolveChainConversationAgent } from '../../utils/chainConversation';
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
  flattenRecentChains,
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
  onOpenAgent?: (agentInstanceId: string) => void;
}

/**
 * Home view task chains: a search bar plus the last 10 task chains, flat (not
 * grouped). Typing searches the unlocked Bridges (encrypted task-chain search)
 * and falls back to the loaded list when Bridge search is unavailable.
 */
export function HomeChainSearch({ onOpenAgent }: HomeChainSearchProps) {
  const { data, isLoading } = useFetchTaskChainGroupsQuery();
  const archivedProjectIds = useArchivedProjectIds();
  const decryptedTitles = useSelector(selectSearchChains) as Record<string, { decryptedTitle?: string }>;
  const isVaultUnlocked = useSelector(selectIsVaultUnlocked);
  const authUser = useAuthUser();
  const dispatch = useDispatch();
  const [query, setQuery] = useState('');
  const [remote, setRemote] = useState<HomeChainItem[] | null>(null);
  const [remoteState, setRemoteState] = useState<'idle' | 'searching' | 'stale' | 'error'>('idle');
  const [remoteError, setRemoteError] = useState('');

  const loaded = useMemo(() => flattenRecentChains(data?.groups, archivedProjectIds), [data, archivedProjectIds]);
  const trimmed = query.trim();

  useEffect(() => {
    if (!isVaultUnlocked || trimmed.length < HOME_REMOTE_SEARCH_MIN_CHARS || !authUser?.user_id) {
      setRemote(null);
      setRemoteState('idle');
      return;
    }
    let canceled = false;
    setRemote(null);
    setRemoteError('');
    const timer = setTimeout(() => {
      setRemoteState('searching');
      searchTaskChainsEncrypted(trimmed, authUser.user_id!, { limit: HOME_RECENT_CHAIN_LIMIT })
        .then((response) => {
          if (canceled) return;
          setRemote(homeChainsFromSearchHits(response.hits, loaded));
          setRemoteState(response.stale ? 'stale' : 'idle');
        })
        .catch((error) => {
          if (canceled) return;
          setRemote(null);
          setRemoteState('error');
          setRemoteError(taskChainSearchErrorMessage(error));
        });
    }, 150);
    return () => {
      canceled = true;
      clearTimeout(timer);
    };
  }, [authUser?.user_id, isVaultUnlocked, loaded, trimmed]);

  const rows = remote ?? filterHomeChains(loaded, trimmed, decryptedTitles);

  // A chain opens as its coordinator's conversation (resolved from the chain
  // detail when the list row lacks it); only a chain without any coordinator
  // falls back to the chain page.
  const open = async (chain: HomeChainItem) => {
    const coordinator = await resolveChainConversationAgent(dispatch, chain.chainId, chain.coordinatorAgentInstanceId);
    if (coordinator) {
      if (onOpenAgent) onOpenAgent(coordinator);
      else navigateToHash(buildConversationHash([coordinator]));
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
          onChange={(e) => setQuery(e.target.value)}
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
      <ul data-debug-id="home-chain-list" className="divide-y divide-subtle overflow-hidden rounded-2xl border border-subtle bg-surface">
        {isLoading && loaded.length === 0 ? (
          <li className="px-4 py-6 text-center text-sm text-muted">Loading task chains…</li>
        ) : rows.length === 0 ? (
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
    </section>
  );
}

export default HomeChainSearch;
