import { calculatePaneLayouts } from '../tiling/calculatePaneLayout';

export const APP_STORAGE_PREFIXES = ['odin.', 'heimdall.', 'heimdall:'] as const;
export const LAST_SEEN_USER_ID_KEY = 'heimdall.lastSeenUserId';

function storageKeys(storage: Storage): string[] {
  const keys: string[] = [];
  for (let index = 0; index < storage.length; index += 1) {
    const key = storage.key(index);
    if (key) keys.push(key);
  }
  return keys;
}

export function isAppOwnedStorageKey(key: string): boolean {
  return APP_STORAGE_PREFIXES.some((prefix) => key.startsWith(prefix));
}

export function removeAppOwnedClientStorage() {
  if (typeof window === 'undefined') return;
  for (const storage of [window.localStorage, window.sessionStorage]) {
    try {
      for (const key of storageKeys(storage)) {
        if (isAppOwnedStorageKey(key)) storage.removeItem(key);
      }
    } catch {
      // Best-effort cleanup: storage can be unavailable in hardened contexts.
    }
  }
}

export function readLastSeenUserId(): string {
  if (typeof window === 'undefined') return '';
  try { return window.localStorage.getItem(LAST_SEEN_USER_ID_KEY) || ''; } catch { return ''; }
}

export function writeLastSeenUserId(userId: string) {
  if (typeof window === 'undefined' || !userId) return;
  try { window.localStorage.setItem(LAST_SEEN_USER_ID_KEY, userId); } catch { /* ignore */ }
}

export function userScopedStorageKey(baseKey: string, userId = readLastSeenUserId()): string {
  const safeUserId = encodeURIComponent(userId || 'anonymous');
  const safeBase = baseKey.replace(/[^a-zA-Z0-9._:-]+/g, '_');
  return `heimdall.user.${safeUserId}.${safeBase}`;
}

export function readChainOverviewCollapsedState(agentInstanceId?: string): Record<string, boolean> {
  if (typeof window === 'undefined') return {};
  try {
    const key = 'heimdall:chainOverview:collapsed:' + (agentInstanceId || 'default');
    const raw = window.localStorage.getItem(key);
    if (!raw) return {};
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
      return parsed as Record<string, boolean>;
    }
    return {};
  } catch {
    return {};
  }
}

export function writeChainOverviewCollapsedState(state: Record<string, boolean>, agentInstanceId?: string): void {
  if (typeof window === 'undefined') return;
  try {
    const key = 'heimdall:chainOverview:collapsed:' + (agentInstanceId || 'default');
    window.localStorage.setItem(key, JSON.stringify(state));
  } catch {
    /* ignore */
  }
}

// --- Sidebar Chain Filter (REQ-CHAIN-UI-SIDEBAR-1) --------------------------
export const SIDEBAR_CHAIN_FILTER_KEY = 'heimdall:sidebar-chain-filter';
export type SidebarChainFilter = 'all' | 'active';

export function isSidebarChainFilter(val: unknown): val is SidebarChainFilter {
  return val === 'all' || val === 'active';
}

export function readSidebarChainFilter(): SidebarChainFilter {
  if (typeof window === 'undefined') return 'all';
  try {
    const raw = window.localStorage.getItem(SIDEBAR_CHAIN_FILTER_KEY);
    if (raw === 'active' || raw === 'active-only') return 'active';
    return 'all';
  } catch {
    return 'all';
  }
}

export function writeSidebarChainFilter(filter: SidebarChainFilter): void {
  if (typeof window === 'undefined') return;
  try {
    window.localStorage.setItem(SIDEBAR_CHAIN_FILTER_KEY, filter);
  } catch {
    /* ignore */
  }
}

export type ChainStatusLike = {
  chainId?: string;
  status?: string;
  archived?: boolean;
  projectId?: string;
};

export function filterSidebarChains<T extends ChainStatusLike>(
  chains: T[],
  filter: SidebarChainFilter,
  archivedProjectIds?: Set<string>,
): T[] {
  return chains.filter((c) => {
    if (c.status === 'archived' || Boolean(c.archived)) return false;
    if (c.projectId && archivedProjectIds && archivedProjectIds.has(c.projectId)) return false;
    if (filter === 'active' && c.status !== 'active') return false;
    return true;
  });
}

// --- Level 1 Window Layout Persistence (R2) ---------------------------------
export const WINDOW_LAYOUT_STORAGE_KEY = 'heimdall:window-layout:v1';

export function readWindowLayoutState<T = any>(): T | null {
  if (typeof window === 'undefined') return null;
  try {
    const raw = window.localStorage.getItem(WINDOW_LAYOUT_STORAGE_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw);
    if (
      parsed &&
      typeof parsed === 'object' &&
      !Array.isArray(parsed) &&
      typeof parsed.rootPaneId === 'string' &&
      parsed.panes &&
      typeof parsed.panes === 'object' &&
      !Array.isArray(parsed.panes) &&
      Boolean(parsed.panes[parsed.rootPaneId]) &&
      calculatePaneLayouts(parsed).contentLayouts.length > 0
    ) {
      return parsed as T;
    }
    return null;
  } catch {
    return null;
  }
}

export function writeWindowLayoutState(tree: unknown): void {
  if (typeof window === 'undefined') return;
  try {
    if (!tree) {
      window.localStorage.removeItem(WINDOW_LAYOUT_STORAGE_KEY);
      return;
    }
    window.localStorage.setItem(WINDOW_LAYOUT_STORAGE_KEY, JSON.stringify(tree));
  } catch {
    /* ignore */
  }
}

// --- Level 2 Per-Conversation Workbench Persistence (R3) --------------------
export const WORKBENCH_LAYOUT_STORAGE_PREFIX = 'heimdall:workbench-layout:v1:';

export function resolveWorkbenchWorkspaceKey(params: {
  chainId?: string | null;
  agentInstanceId?: string | null;
  workspaceKey?: string | null;
}): string {
  if (params.workspaceKey && params.workspaceKey.trim().length > 0) {
    return params.workspaceKey.trim();
  }
  if (params.chainId && params.chainId.trim().length > 0) {
    return `chain:${params.chainId.trim()}`;
  }
  if (params.agentInstanceId && params.agentInstanceId.trim().length > 0) {
    return `agent:${params.agentInstanceId.trim()}`;
  }
  return 'default';
}

export function getWorkbenchWorkspaceStorageKey(workspaceKey: string): string {
  return `${WORKBENCH_LAYOUT_STORAGE_PREFIX}${workspaceKey || 'default'}`;
}

export function readWorkbenchWorkspaceState<T = any>(
  workspaceKey: string,
): T | null {
  if (typeof window === 'undefined' || !workspaceKey) return null;
  try {
    const raw = window.localStorage.getItem(
      getWorkbenchWorkspaceStorageKey(workspaceKey),
    );
    if (!raw) return null;
    const parsed = JSON.parse(raw);
    if (
      parsed &&
      typeof parsed === 'object' &&
      !Array.isArray(parsed) &&
      typeof parsed.rootPaneId === 'string' &&
      parsed.panes &&
      typeof parsed.panes === 'object' &&
      !Array.isArray(parsed.panes) &&
      Boolean(parsed.panes[parsed.rootPaneId]) &&
      calculatePaneLayouts(parsed).contentLayouts.length > 0
    ) {
      return parsed as T;
    }
    return null;
  } catch {
    return null;
  }
}

export function writeWorkbenchWorkspaceState(
  workspaceKey: string,
  tree: unknown,
): void {
  if (typeof window === 'undefined' || !workspaceKey) return;
  try {
    const storageKey = getWorkbenchWorkspaceStorageKey(workspaceKey);
    if (!tree) {
      window.localStorage.removeItem(storageKey);
      return;
    }
    window.localStorage.setItem(storageKey, JSON.stringify(tree));
  } catch {
    /* ignore */
  }
}

// --- Per-Instance Composer Draft Persistence (R3.1) -------------------------
export const COMPOSER_DRAFT_KEY_PREFIX = 'heimdall:composer:draft:';

export function getComposerDraftKey(agentInstanceId: string): string {
  return `${COMPOSER_DRAFT_KEY_PREFIX}${agentInstanceId || 'default'}`;
}

export function readComposerDraft(agentInstanceId: string): string {
  if (typeof window === 'undefined' || !agentInstanceId) return '';
  try {
    return window.localStorage.getItem(getComposerDraftKey(agentInstanceId)) || '';
  } catch {
    return '';
  }
}

export function writeComposerDraft(
  agentInstanceId: string,
  draft: string,
): void {
  if (typeof window === 'undefined' || !agentInstanceId) return;
  try {
    const key = getComposerDraftKey(agentInstanceId);
    if (!draft) {
      window.localStorage.removeItem(key);
    } else {
      window.localStorage.setItem(key, draft);
    }
  } catch {
    /* ignore */
  }
}
