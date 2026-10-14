import type { ChainProjectGroup } from '../../api/endpoints/tasks';
import type { TaskChainSearchHit } from '../../utils/taskChainSearch';
import { isVaultArmored } from '../../utils/vaultContent';

/** A flat (ungrouped) recent task chain row on the home view. */
export interface HomeChainItem {
  chainId: string;
  title: string;
  status: string;
  projectId: string;
  projectName: string;
  updatedAt: string;
  coordinatorAgentInstanceId?: string;
}

export const HOME_RECENT_CHAIN_LIMIT = 10;
export const HOME_REMOTE_SEARCH_MIN_CHARS = 2;

function time(value: string): number {
  const t = new Date(value || '').getTime();
  return Number.isFinite(t) ? t : 0;
}

/**
 * All non-archived chains across every project, flattened (no grouping) and
 * sorted most-recently-updated first.
 */
export function flattenRecentChains(
  groups: ChainProjectGroup[] | undefined,
  archivedProjectIds: ReadonlySet<string> = new Set(),
): HomeChainItem[] {
  const out: HomeChainItem[] = [];
  for (const g of groups || []) {
    if (g.projectId && archivedProjectIds.has(g.projectId)) continue;
    for (const c of g.chains || []) {
      const projectId = c.projectId || g.projectId || '';
      if (projectId && archivedProjectIds.has(projectId)) continue;
      const status = String(c.status || '').toLowerCase();
      if (status === 'archived' || (c as any).archived) continue;
      out.push({
        chainId: c.chainId,
        title: c.title || '',
        status,
        projectId,
        projectName: c.projectName || g.projectName || '',
        updatedAt: c.updatedAt || '',
        coordinatorAgentInstanceId: c.coordinatorAgentInstanceId || undefined,
      });
    }
  }
  return out.sort((a, b) => time(b.updatedAt) - time(a.updatedAt));
}

/**
 * Local search over loaded chains (vault-safe: armored titles / project names
 * never match; a decrypted title from the title cache does).
 */
export function filterHomeChains(
  chains: HomeChainItem[],
  query: string,
  decryptedTitles: Record<string, { decryptedTitle?: string } | undefined> = {},
  limit = HOME_RECENT_CHAIN_LIMIT,
): HomeChainItem[] {
  const q = query.trim().toLowerCase();
  const matches = q
    ? chains.filter((c) => {
        const title = decryptedTitles[c.chainId]?.decryptedTitle || c.title || '';
        if (title && !isVaultArmored(title) && title.toLowerCase().includes(q)) return true;
        if (c.chainId.toLowerCase().includes(q)) return true;
        return Boolean(c.projectName && !isVaultArmored(c.projectName) && c.projectName.toLowerCase().includes(q));
      })
    : chains;
  return matches.slice(0, limit);
}

/**
 * Bridge search hits -> home rows. Hits carry no coordinator, so it (and the
 * project name) is filled in from the loaded chain list when known.
 */
export function homeChainsFromSearchHits(
  hits: TaskChainSearchHit[],
  loaded: HomeChainItem[],
  limit = HOME_RECENT_CHAIN_LIMIT,
): HomeChainItem[] {
  const byId = new Map(loaded.map((c) => [c.chainId, c]));
  const projectNames = new Map(loaded.map((c) => [c.projectId, c.projectName]));
  return hits.slice(0, limit).map((hit) => {
    const known = byId.get(hit.chain_id);
    return {
      chainId: hit.chain_id,
      title: hit.title || known?.title || '',
      status: String(hit.status || known?.status || '').toLowerCase(),
      projectId: hit.project_id || known?.projectId || '',
      projectName: known?.projectName || projectNames.get(hit.project_id) || '',
      updatedAt: hit.updated_at || known?.updatedAt || '',
      coordinatorAgentInstanceId: known?.coordinatorAgentInstanceId,
    };
  });
}
