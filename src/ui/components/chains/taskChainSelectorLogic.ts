import type { ChainProjectGroup } from '../../api/endpoints/tasks';
import type { SearchItem } from '../../store/searchTitleSlice';
import { isVaultArmored } from '../../utils/vaultContent.ts';

export const INITIAL_VISIBLE_COUNT = 80;

export interface ChainSelectorItem {
  chainId: string;
  title: string;
  rawTitle: string;
  status: string;
  projectId: string;
  projectName: string;
  coordinatorAgentInstanceId?: string;
  taskCount?: number;
  completedTaskCount?: number;
  updatedAt?: string;
  isCurrent?: boolean;
}

export function prepareChainSelectorItems(
  groups: ChainProjectGroup[],
  searchChains: Record<string, SearchItem> = {},
  currentChainId?: string,
): ChainSelectorItem[] {
  const map = new Map<string, ChainSelectorItem>();

  for (const g of groups) {
    const pId = g.projectId || '';
    const pName = g.projectName || '';
    for (const ch of g.chains || []) {
      const id = ch.chainId;
      if (!id) continue;
      const searchItem = searchChains[id];
      const rawTitle = searchItem?.rawTitle || ch.title || '';
      const title = searchItem?.decryptedTitle || ch.title || 'Untitled chain';
      map.set(id, {
        chainId: id,
        title,
        rawTitle,
        status: searchItem?.status || ch.status || '',
        projectId: ch.projectId || pId,
        projectName: ch.projectName || pName,
        coordinatorAgentInstanceId: ch.coordinatorAgentInstanceId,
        taskCount: ch.taskCount,
        completedTaskCount: ch.completedTaskCount,
        updatedAt: latestUpdatedAt(ch.updatedAt, searchItem?.updatedAt),
        isCurrent: Boolean(currentChainId && id === currentChainId),
      });
    }
  }

  for (const item of Object.values(searchChains)) {
    if (item.type !== 'chain' || !item.id) continue;
    const id = item.id;
    if (!map.has(id)) {
      const rawTitle = item.rawTitle || '';
      const title = item.decryptedTitle || rawTitle || 'Untitled chain';
      map.set(id, {
        chainId: id,
        title,
        rawTitle,
        status: item.status || '',
        projectId: item.projectId || '',
        projectName: '',
        updatedAt: item.updatedAt,
        isCurrent: Boolean(currentChainId && id === currentChainId),
      });
    } else {
      const existing = map.get(id)!;
      if (item.decryptedTitle && !isVaultArmored(item.decryptedTitle)) {
        existing.title = item.decryptedTitle;
      }
    }
  }

  return Array.from(map.values());
}

export function filterTaskChains(
  items: ChainSelectorItem[],
  query: string,
): ChainSelectorItem[] {
  const q = query.trim().toLowerCase();
  if (!q) return items;

  return items.filter((item) => {
    // Zero-Knowledge Armor Shield:
    // If the title is armored (e.g. vault:v2:...), never match query against raw ciphertext.
    const titleMatches =
      !isVaultArmored(item.title) &&
      item.title.toLowerCase().includes(q);

    const projectMatches =
      Boolean(item.projectName) &&
      !isVaultArmored(item.projectName) &&
      item.projectName.toLowerCase().includes(q);

    const idMatches =
      Boolean(item.chainId) &&
      item.chainId.toLowerCase().includes(q);

    return titleMatches || projectMatches || idMatches;
  });
}

export function findInitialActiveIndex(
  items: ChainSelectorItem[],
  currentChainId?: string,
): number {
  if (!currentChainId || items.length === 0) return 0;
  const idx = items.findIndex((c) => c.chainId === currentChainId);
  return idx >= 0 ? idx : 0;
}

export function navigateIndex(
  currentIndex: number,
  total: number,
  direction: 'up' | 'down',
): number {
  if (total <= 0) return 0;
  if (direction === 'down') {
    return currentIndex < total - 1 ? currentIndex + 1 : 0;
  }
  return currentIndex > 0 ? currentIndex - 1 : total - 1;
}

type SelectionKeyEvent = Pick<KeyboardEvent, 'altKey' | 'ctrlKey' | 'key' | 'metaKey'>;

/** Maps arrows and Vim-style Ctrl-N/Ctrl-P to list-selection movement. */
export function selectionDirectionForEvent(event: SelectionKeyEvent): 'up' | 'down' | null {
  if (event.metaKey || event.altKey) return null;
  if (event.key === 'ArrowDown') return 'down';
  if (event.key === 'ArrowUp') return 'up';
  if (!event.ctrlKey) return null;
  const key = event.key.toLowerCase();
  if (key === 'n') return 'down';
  if (key === 'p') return 'up';
  return null;
}

/** Newest available metadata wins; a missing/invalid preview must not lose cache recency. */
function latestUpdatedAt(preview?: string, cached?: string): string | undefined {
  const previewTime = updatedAtTime(preview);
  const cachedTime = updatedAtTime(cached);
  return cachedTime > previewTime ? cached : preview;
}

function updatedAtTime(value?: string): number {
  const parsed = value ? Date.parse(value) : NaN;
  return Number.isFinite(parsed) ? parsed : -Infinity;
}

/** Sort displayed matches only: the remote search still returns bounded relevance-ranked hits. */
export function sortChainSelectorItems(items: readonly ChainSelectorItem[]): ChainSelectorItem[] {
  return [...items].sort((a, b) => {
    const aTime = updatedAtTime(a.updatedAt);
    const bTime = updatedAtTime(b.updatedAt);
    if (aTime !== bTime) return aTime > bTime ? -1 : 1;
    return a.chainId < b.chainId ? -1 : a.chainId > b.chainId ? 1 : 0;
  });
}
