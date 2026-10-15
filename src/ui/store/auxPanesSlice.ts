import { createSelector, createSlice, type PayloadAction } from '@reduxjs/toolkit';
import { getContentPaneIds, type PaneTreeState } from '../tiling';
import {
  FILES_TAB_ID,
  NEW_TAB_ID,
  OVERVIEW_TAB_ID,
  auxTabId,
  createAuxTab,
  decodeAuxTabId,
  isAuxContent,
  isFixedAuxTabId,
  normalizeAuxContent,
  type AuxContent,
  type AuxTab,
} from './auxTabId';
import {
  NEW_PANE_AGENT_ID,
  isShellPaneId,
  selectMainTree,
  type MainPaneValue,
} from './workspaceLayoutSlice';

/**
 * Aux dock content (Jetski `auxPaneV2` equivalent).
 *
 * ONE tab strip per agent (`agentPanes[agentInstanceId]`), no splits inside the
 * aux. The dock always shows the FOCUSED Main pane's agent strip, in single and
 * split view alike (Jetski `/c/A+B?focused=A` -> conversationPanes[focused]).
 * See {@link resolveAuxTreeId}.
 */

export type AuxTreeId = { kind: 'agent'; agentInstanceId: string };

export interface AuxTabbedPane {
  tabs: AuxTab[];
  /** A tab id in `tabs`, a fixed id (derived tab), or `NEW_TAB_ID`. */
  activeTabId?: string;
  /** Aux open/closed, per tree (Jetski `isPaneOpen`). */
  isPaneOpen?: boolean;
}

export interface AuxPanesState {
  agentPanes: Record<string, AuxTabbedPane>;
}

const initialState: AuxPanesState = {
  agentPanes: {},
};

/**
 * Jetski `useTreeId`: in split view `useCascadeIdParam()` is the FOCUSED
 * conversation, so the aux tree is always the focused Main pane's agent
 * (`{kind:'cascadeId', cascadeId: focused}`), single or split. A focused
 * new-chat picker has no aux.
 */
export function resolveAuxTreeId(tree: PaneTreeState<MainPaneValue>): AuxTreeId | null {
  let pane = tree.panes[tree.focusedPaneId];
  if (pane?.kind !== 'content') {
    const first = getContentPaneIds(tree)[0];
    pane = first ? tree.panes[first] : undefined;
  }
  if (pane?.kind !== 'content') return null;
  const agentInstanceId = pane.value.agentInstanceId;
  if (!agentInstanceId || agentInstanceId === NEW_PANE_AGENT_ID) return null;
  // A focused shell pane has no agent context, so no aux dock.
  if (isShellPaneId(agentInstanceId)) return null;
  return { kind: 'agent', agentInstanceId };
}

export function auxTreeKey(treeId: AuxTreeId | null | undefined): string {
  return treeId ? `agent:${treeId.agentInstanceId}` : '';
}

/**
 * Jetski `createDefaultPaneState()`: no stored tabs, the fixed overview tab
 * active. In Heimdall the overview is the Chain Overview, or Files for an agent
 * that has no chain.
 */
export function createDefaultAuxPane(hasChain: boolean): AuxTabbedPane {
  return { tabs: [], activeTabId: hasChain ? OVERVIEW_TAB_ID : FILES_TAB_ID };
}

export function getAuxPane(
  state: AuxPanesState,
  treeId: AuxTreeId | null | undefined,
): AuxTabbedPane | undefined {
  if (!treeId) return undefined;
  return state.agentPanes[treeId.agentInstanceId];
}

function setAuxPane(state: AuxPanesState, treeId: AuxTreeId, pane: AuxTabbedPane): void {
  state.agentPanes[treeId.agentInstanceId] = pane;
}

function ensurePane(
  state: AuxPanesState,
  treeId: AuxTreeId,
  hasChain: boolean | undefined,
): AuxTabbedPane {
  const existing = getAuxPane(state, treeId);
  if (existing) {
    // A strip created before its agent's chain membership was known (focus
    // carry-over) is seeded on first ensure.
    if (existing.activeTabId === undefined && existing.tabs.length === 0 && hasChain !== undefined) {
      existing.activeTabId = createDefaultAuxPane(hasChain).activeTabId;
    }
    return existing;
  }
  setAuxPane(state, treeId, createDefaultAuxPane(hasChain !== false));
  return getAuxPane(state, treeId)!;
}

/**
 * The tab the strip shows as active: a stored tab, or the derived fixed tab
 * (e.g. the seeded overview) when the active id is fixed but not stored.
 */
export function resolveActiveAuxTab(pane: AuxTabbedPane | undefined): AuxTab | null {
  if (!pane || !pane.activeTabId || pane.activeTabId === NEW_TAB_ID) return null;
  const stored = pane.tabs.find((t) => t.id === pane.activeTabId);
  if (stored) return stored;
  if (isFixedAuxTabId(pane.activeTabId)) {
    const content = decodeAuxTabId(pane.activeTabId);
    return content ? { id: pane.activeTabId, content } : null;
  }
  return null;
}

/** Tabs to render in the strip: stored tabs plus a derived active fixed tab. */
export function visibleAuxTabs(pane: AuxTabbedPane | undefined): AuxTab[] {
  if (!pane) return [];
  const active = resolveActiveAuxTab(pane);
  if (active && !pane.tabs.some((t) => t.id === active.id)) {
    return [active, ...pane.tabs];
  }
  return pane.tabs;
}

/**
 * A derived (seeded) fixed tab becomes a real stored tab once the user opens
 * something else, so it does not vanish from the strip.
 */
function materializeActive(pane: AuxTabbedPane): void {
  const active = resolveActiveAuxTab(pane);
  if (active && !pane.tabs.some((t) => t.id === active.id)) {
    pane.tabs.unshift(active);
  }
}

function upsertTab(pane: AuxTabbedPane, content: AuxContent, title?: string): AuxTab {
  const tab = createAuxTab(content, title);
  const idx = pane.tabs.findIndex((t) => t.id === tab.id);
  if (idx >= 0) {
    const prev = pane.tabs[idx];
    const merged: AuxTab = {
      id: prev.id,
      content: { ...prev.content, ...tab.content } as AuxContent,
      ...(tab.title || prev.title ? { title: tab.title || prev.title } : {}),
    };
    pane.tabs[idx] = merged;
    pane.activeTabId = merged.id;
    return merged;
  }
  materializeActive(pane);
  pane.tabs.push(tab);
  pane.activeTabId = tab.id;
  return tab;
}

const auxPanesSlice = createSlice({
  name: 'auxPanes',
  initialState,
  reducers: {
    /** Creates the tree's strip with Jetski default seeding if it does not exist. */
    ensureAuxPane(state, action: PayloadAction<{ treeId: AuxTreeId; hasChain?: boolean }>) {
      ensurePane(state, action.payload.treeId, action.payload.hasChain);
    },

    /**
     * Opens (or focuses) a tab. The id is content-derived, so opening the same
     * thing twice focuses the existing tab (dedupe). Opens the dock.
     */
    openAuxTab(
      state,
      action: PayloadAction<{
        treeId: AuxTreeId;
        content: AuxContent;
        title?: string;
        hasChain?: boolean;
        /** Defaults to true: opening a tab reveals the dock. */
        openPane?: boolean;
      }>,
    ) {
      const { treeId, content, title, hasChain, openPane = true } = action.payload;
      if (!isAuxContent(content)) return;
      const pane = ensurePane(state, treeId, hasChain);
      upsertTab(pane, content, title);
      if (openPane) pane.isPaneOpen = true;
    },

    setActiveAuxTab(state, action: PayloadAction<{ treeId: AuxTreeId; tabId: string }>) {
      const pane = getAuxPane(state, action.payload.treeId);
      if (!pane) return;
      const { tabId } = action.payload;
      if (tabId === NEW_TAB_ID) {
        materializeActive(pane);
        pane.activeTabId = NEW_TAB_ID;
        return;
      }
      if (pane.tabs.some((t) => t.id === tabId) || tabId === pane.activeTabId) {
        pane.activeTabId = tabId;
        return;
      }
      if (isFixedAuxTabId(tabId)) {
        const content = decodeAuxTabId(tabId);
        if (content) upsertTab(pane, content);
      }
    },

    openAuxNewTab(state, action: PayloadAction<{ treeId: AuxTreeId; hasChain?: boolean }>) {
      const pane = ensurePane(state, action.payload.treeId, action.payload.hasChain);
      materializeActive(pane);
      pane.activeTabId = NEW_TAB_ID;
      pane.isPaneOpen = true;
    },

    closeAuxTab(state, action: PayloadAction<{ treeId: AuxTreeId; tabId: string }>) {
      const pane = getAuxPane(state, action.payload.treeId);
      if (!pane) return;
      const { tabId } = action.payload;
      if (tabId === NEW_TAB_ID) {
        if (pane.activeTabId === NEW_TAB_ID) {
          pane.activeTabId = pane.tabs[pane.tabs.length - 1]?.id ?? NEW_TAB_ID;
        }
        return;
      }
      const idx = pane.tabs.findIndex((t) => t.id === tabId);
      if (idx < 0) {
        // Closing a derived (unstored) active fixed tab.
        if (pane.activeTabId === tabId) {
          pane.activeTabId = pane.tabs[pane.tabs.length - 1]?.id ?? NEW_TAB_ID;
        }
        return;
      }
      const wasActive = pane.activeTabId === tabId;
      pane.tabs.splice(idx, 1);
      if (wasActive) {
        const next = pane.tabs[idx] ?? pane.tabs[idx - 1];
        pane.activeTabId = next ? next.id : NEW_TAB_ID;
      }
    },

    moveAuxTab(
      state,
      action: PayloadAction<{ treeId: AuxTreeId; tabId: string; toIndex: number }>,
    ) {
      const pane = getAuxPane(state, action.payload.treeId);
      if (!pane) return;
      materializeActive(pane);
      const from = pane.tabs.findIndex((t) => t.id === action.payload.tabId);
      if (from < 0) return;
      const to = Math.max(0, Math.min(pane.tabs.length - 1, Math.floor(action.payload.toIndex)));
      if (from === to) return;
      const [moved] = pane.tabs.splice(from, 1);
      pane.tabs.splice(to, 0, moved);
    },

    /** Patches transient content params of a tab without changing its identity. */
    updateAuxTabContent(
      state,
      action: PayloadAction<{
        treeId: AuxTreeId;
        tabId: string;
        patch: Partial<AuxContent> & Record<string, unknown>;
        title?: string;
      }>,
    ) {
      const pane = getAuxPane(state, action.payload.treeId);
      const tab = pane?.tabs.find((t) => t.id === action.payload.tabId);
      if (!tab) return;
      const next = normalizeAuxContent({
        ...tab.content,
        ...action.payload.patch,
        type: tab.content.type,
      } as AuxContent);
      if (auxTabId(next) !== tab.id) return; // identity changes go through rekeyAuxTab
      tab.content = next;
      if (action.payload.title) tab.title = action.payload.title;
    },

    /**
     * Transforms a tab in place (same strip slot, new id + content), e.g. a
     * provisional `shell__new` tab once its session is bound. If the target id
     * already exists the source closes and the existing tab is focused.
     */
    rekeyAuxTab(
      state,
      action: PayloadAction<{
        treeId: AuxTreeId;
        tabId: string;
        content: AuxContent;
        title?: string;
      }>,
    ) {
      const pane = getAuxPane(state, action.payload.treeId);
      if (!pane || !isAuxContent(action.payload.content)) return;
      const idx = pane.tabs.findIndex((t) => t.id === action.payload.tabId);
      if (idx < 0) return;
      const nextTab = createAuxTab(action.payload.content, action.payload.title ?? pane.tabs[idx].title);
      const existingIdx = pane.tabs.findIndex((t) => t.id === nextTab.id);
      if (existingIdx >= 0 && existingIdx !== idx) {
        pane.tabs.splice(idx, 1);
      } else {
        pane.tabs[idx] = nextTab;
      }
      if (pane.activeTabId === action.payload.tabId || existingIdx >= 0) {
        pane.activeTabId = nextTab.id;
      }
    },

    setAuxPaneOpen(
      state,
      action: PayloadAction<{ treeId: AuxTreeId; open: boolean; hasChain?: boolean }>,
    ) {
      const pane = ensurePane(state, action.payload.treeId, action.payload.hasChain);
      pane.isPaneOpen = action.payload.open;
    },

    toggleAuxPane(state, action: PayloadAction<{ treeId: AuxTreeId; hasChain?: boolean }>) {
      const pane = ensurePane(state, action.payload.treeId, action.payload.hasChain);
      pane.isPaneOpen = !pane.isPaneOpen;
    },

    /**
     * Jetski RouteToReduxSync: when focus moves between panes of a split, the
     * newly focused agent's strip takes over the previously focused strip's
     * open/closed state (so the dock doesn't flicker shut or pop open).
     */
    carryAuxPaneOpenOnFocus(
      state,
      action: PayloadAction<{ from: AuxTreeId; to: AuxTreeId }>,
    ) {
      const { from, to } = action.payload;
      if (from.agentInstanceId === to.agentInstanceId) return;
      const wasOpen = Boolean(getAuxPane(state, from)?.isPaneOpen);
      const target = getAuxPane(state, to);
      if (Boolean(target?.isPaneOpen) === wasOpen) return;
      if (target) {
        target.isPaneOpen = wasOpen;
      } else {
        // Seeding waits for the agent's chain membership (see ensureAuxPane).
        setAuxPane(state, to, { tabs: [], isPaneOpen: wasOpen });
      }
    },

    hydrateAuxPanes(_state, action: PayloadAction<unknown>) {
      return sanitizeAuxPanesState(action.payload);
    },

    resetAuxPanes() {
      return initialState;
    },
  },
});

function sanitizePane(raw: any): AuxTabbedPane | null {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const seen = new Set<string>();
  const tabs: AuxTab[] = [];
  for (const t of Array.isArray(raw.tabs) ? raw.tabs : []) {
    if (!t || typeof t !== 'object' || !isAuxContent(t.content)) continue;
    const tab = createAuxTab(t.content, typeof t.title === 'string' ? t.title : undefined);
    if (tab.id === NEW_TAB_ID || seen.has(tab.id)) continue;
    seen.add(tab.id);
    tabs.push(tab);
  }
  const rawActive = typeof raw.activeTabId === 'string' ? raw.activeTabId : undefined;
  const activeTabId =
    rawActive === NEW_TAB_ID || (rawActive && (seen.has(rawActive) || isFixedAuxTabId(rawActive)))
      ? rawActive
      : tabs[0]?.id ?? NEW_TAB_ID;
  const pane: AuxTabbedPane = { tabs, activeTabId };
  if (raw.isPaneOpen === true) pane.isPaneOpen = true;
  return pane;
}

export function sanitizeAuxPanesState(raw: unknown): AuxPanesState {
  const out: AuxPanesState = { agentPanes: {} };
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return out;
  const r = raw as any;
  if (r.agentPanes && typeof r.agentPanes === 'object' && !Array.isArray(r.agentPanes)) {
    for (const [agentId, pane] of Object.entries(r.agentPanes)) {
      if (!agentId || agentId === NEW_PANE_AGENT_ID || isShellPaneId(agentId)) continue;
      const clean = sanitizePane(pane);
      if (clean) out.agentPanes[agentId] = clean;
    }
  }
  return out;
}

export const {
  ensureAuxPane,
  openAuxTab,
  setActiveAuxTab,
  openAuxNewTab,
  closeAuxTab,
  moveAuxTab,
  updateAuxTabContent,
  rekeyAuxTab,
  setAuxPaneOpen,
  toggleAuxPane,
  carryAuxPaneOpenOnFocus,
  hydrateAuxPanes,
  resetAuxPanes,
} = auxPanesSlice.actions;

function extract(state: any): AuxPanesState {
  if (state?.auxPanes?.agentPanes) return state.auxPanes as AuxPanesState;
  if (state?.agentPanes) return state as AuxPanesState;
  return initialState;
}

export const selectAuxPanesState = (state: any): AuxPanesState => extract(state);

/** The tree the aux dock shows right now (derived from the Main layout). */
export const selectCurrentAuxTreeId = createSelector([selectMainTree], (tree) =>
  resolveAuxTreeId(tree),
);

export const selectAuxPane = (
  state: any,
  treeId: AuxTreeId | null | undefined,
): AuxTabbedPane | undefined => getAuxPane(extract(state), treeId);

/**
 * Thunk for surfaces outside the workspace (shell list / detail pages): opens a
 * preview tab in whichever aux tree is current. No-op without a tree.
 */
export function openPreviewInAux(params: {
  sessionId: string;
  label?: string;
  port?: number;
  path?: string;
}) {
  return (dispatch: (action: any) => any, getState: () => any) => {
    if (!params.sessionId) return;
    const treeId = selectCurrentAuxTreeId(getState());
    if (!treeId) return;
    dispatch(
      openAuxTab({
        treeId,
        content: {
          type: 'preview',
          sessionId: params.sessionId,
          port: params.port,
          ...(params.path !== undefined ? { path: params.path } : {}),
        },
        title: params.label,
      }),
    );
  };
}

export default auxPanesSlice.reducer;
