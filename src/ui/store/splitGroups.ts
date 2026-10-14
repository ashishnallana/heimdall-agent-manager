import type { PaneTreeState } from '../tiling';
import { getContentPaneIds } from '../tiling';
import { NEW_PANE_AGENT_ID, sanitizeMainTree, type MainPaneValue } from './workspaceLayoutSlice';

/**
 * Split groups (Jetski `layoutGroupIndex.ts` + `layoutStorage.ts`).
 *
 * Every Main layout with >= 2 real agents is remembered as a GROUP:
 * - a global index (agent -> group; an agent is in at most one group),
 * - pane geometry keyed by the SORTED id set.
 * Forming a new set evicts every intersecting group (and its geometry);
 * groups left with <= 1 real agent are dropped. A single view is never
 * recorded, it only evicts groups containing that agent.
 */

export const SPLIT_GROUP_INDEX_STORAGE_KEY = 'heimdall:split-groups:v1';
export const SPLIT_LAYOUT_STORAGE_PREFIX = 'heimdall:split-layout:v1:';

export function isRealId(id: string): boolean {
  return Boolean(id) && id !== NEW_PANE_AGENT_ID;
}

export function hasRealAgents(group: string[]): boolean {
  return group.some(isRealId);
}

export function sortedKey(ids: string[]): string {
  return [...ids].sort().join('+');
}

/** Groups intersecting activeIds but not equal to it. */
export function getGroupsToEvict(groups: string[][], activeIds: string[]): string[][] {
  const realIds = activeIds.filter(isRealId);
  if (realIds.length === 0) return [];
  const target = sortedKey(realIds);
  return groups.filter((g) => sortedKey(g) !== target && g.some((id) => realIds.includes(id)));
}

/** Strips an agent from all groups; drops groups left with <= 1 real agent. */
export function evictAgentFromGroups(
  groups: string[][],
  agentInstanceId: string,
): { nextGroups: string[][]; staleGroups: string[][] } {
  const staleGroups = groups.filter((g) => g.includes(agentInstanceId));
  const nextGroups = groups
    .map((g) => g.filter((id) => id !== agentInstanceId))
    .filter((g) => g.filter(isRealId).length > 1);
  return { nextGroups, staleGroups };
}

/** Records activeIds as a group (evicting intersecting groups); singletons only evict. */
export function computeUpdatedGroups(prevGroups: string[][], activeIds: string[]): string[][] {
  const realIds = activeIds.filter(isRealId);
  if (realIds.length === 0) return prevGroups;
  const target = sortedKey(realIds);
  const evict = new Set(getGroupsToEvict(prevGroups, realIds).map(sortedKey));
  const next = prevGroups.filter((g) => !evict.has(sortedKey(g)));
  if (realIds.length > 1 && !next.some((g) => sortedKey(g) === target)) {
    next.push(realIds);
  }
  return next.filter((g) => g.length > 1 && hasRealAgents(g));
}

export function filterValidGroups(groups: unknown): string[][] {
  if (!Array.isArray(groups)) return [];
  return groups
    .filter((g): g is string[] => Array.isArray(g) && g.every((id) => typeof id === 'string'))
    .filter((g) => g.filter(isRealId).length > 1);
}

/** The saved group (> 1 members) containing an agent, if any. */
export function findGroupForAgent(groups: string[][], agentInstanceId: string): string[] | undefined {
  return groups.find((g) => g.length > 1 && g.includes(agentInstanceId));
}

// ---- Storage --------------------------------------------------------------

function storage(): Storage | null {
  try {
    return typeof window !== 'undefined' && window.localStorage ? window.localStorage : null;
  } catch {
    return null;
  }
}

export function readGroupIndex(): string[][] {
  const s = storage();
  if (!s) return [];
  try {
    return filterValidGroups(JSON.parse(s.getItem(SPLIT_GROUP_INDEX_STORAGE_KEY) || '[]'));
  } catch {
    return [];
  }
}

export function writeGroupIndex(groups: string[][]): void {
  storage()?.setItem(SPLIT_GROUP_INDEX_STORAGE_KEY, JSON.stringify(groups));
}

/** Geometry key: all leaf ids (incl. `_new`), sorted. */
export function getLayoutStorageKey(ids: string[]): string {
  return `${SPLIT_LAYOUT_STORAGE_PREFIX}${sortedKey(ids)}`;
}

export function leafAgentIds(tree: PaneTreeState<MainPaneValue>): string[] {
  return getContentPaneIds(tree).map((paneId) => {
    const pane = tree.panes[paneId];
    return pane?.kind === 'content' ? pane.value.agentInstanceId : NEW_PANE_AGENT_ID;
  });
}

export function saveLayoutGeometry(tree: PaneTreeState<MainPaneValue>): void {
  const ids = leafAgentIds(tree);
  if (ids.filter(isRealId).length === 0) return;
  try {
    storage()?.setItem(getLayoutStorageKey(ids), JSON.stringify(tree));
  } catch {
    /* ignore */
  }
}

export function deleteLayoutGeometry(ids: string[]): void {
  try {
    storage()?.removeItem(getLayoutStorageKey(ids));
  } catch {
    /* ignore */
  }
}

/** Saved geometry for EXACTLY this id set, or null. */
export function loadSavedLayout(ids: string[]): PaneTreeState<MainPaneValue> | null {
  const s = storage();
  if (!s || ids.length < 2) return null;
  try {
    const raw = s.getItem(getLayoutStorageKey(ids));
    if (!raw) return null;
    const tree = sanitizeMainTree(JSON.parse(raw));
    if (!tree) return null;
    return sortedKey(leafAgentIds(tree)) === sortedKey(ids) ? tree : null;
  } catch {
    return null;
  }
}

/**
 * Persistence step run on every Main layout change (Jetski
 * layoutPersistenceMiddleware): save geometry; when the active id set changed,
 * evict intersecting groups' geometry and update the group index. Returns the
 * new active key to pass back next time.
 */
export function persistSplitLayout(
  tree: PaneTreeState<MainPaneValue>,
  prevActiveKey: string | null,
): string {
  saveLayoutGeometry(tree);
  const activeIds = leafAgentIds(tree);
  const currentKey = sortedKey(activeIds);
  if (activeIds.length > 0 && currentKey !== prevActiveKey) {
    const groups = readGroupIndex();
    for (const evicted of getGroupsToEvict(groups, activeIds)) {
      deleteLayoutGeometry(evicted);
    }
    writeGroupIndex(computeUpdatedGroups(groups, activeIds));
  }
  return currentKey;
}

/**
 * Where "open this agent" goes (sidebar/search/chain selector/Full View/links):
 * its saved split group focused on it, else its single view.
 */
export function resolveOpenAgentIds(
  agentInstanceId: string,
  groups: string[][] = readGroupIndex(),
): { ids: string[]; focusedId: string } {
  const group = findGroupForAgent(groups, agentInstanceId);
  return group && group.length > 1
    ? { ids: group, focusedId: agentInstanceId }
    : { ids: [agentInstanceId], focusedId: agentInstanceId };
}
