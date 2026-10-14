import { createSelector, createSlice, type PayloadAction } from '@reduxjs/toolkit';
import {
  calculatePaneLayouts,
  closePaneInTree,
  createPaneTreeState,
  equalizeTreeRatios,
  getContentPaneIds,
  movePaneInTree,
  resizeSplitInTree,
  splitPaneInTree,
  swapPanesInTree,
  toggleMaximizePaneInTree,
  type PaneTreeState,
  type SplitInputDirection,
} from '../tiling';

/**
 * Main workspace layout (Jetski `multiConvoLayout` equivalent).
 *
 * ONE global split tree of agent chats for `/conversations/:agentInstanceId`.
 * Leaves hold ONLY an agent instance id, or `'_new'` for the new-chat picker.
 *
 * Node shape: we reuse Heimdall's binary `tiling/*` tree (`PaneTreeState`) rather
 * than Jetski's N-ary `{children, weights}` node. Every N-ary layout Jetski can
 * build from split right/down/left/up is expressible as nested binary splits, and
 * the binary engine already owns rendering, sash resizing, ID-preserving moves
 * and drag-to-split. The behaviors (dedupe, focus, URL sync) mirror Jetski.
 *
 * Invariant (dedupe): an agent appears in at most one leaf. Opening an agent
 * that is already open focuses its pane.
 */

export const NEW_PANE_AGENT_ID = '_new';

export interface MainPaneValue {
  agentInstanceId: string; // NEW_PANE_AGENT_ID for the new-chat picker
}

export interface WorkspaceLayoutState {
  tree: PaneTreeState<MainPaneValue>;
}

export const INITIAL_MAIN_PANE_ID = 'pane-1';

export function createInitialMainTree(
  agentInstanceId: string = NEW_PANE_AGENT_ID,
  paneId = INITIAL_MAIN_PANE_ID,
): PaneTreeState<MainPaneValue> {
  return createPaneTreeState<MainPaneValue>({ agentInstanceId }, paneId);
}

const initialState: WorkspaceLayoutState = {
  tree: createInitialMainTree(),
};

function normalizeAgentId(id: unknown): string {
  const s = typeof id === 'string' ? id.trim() : '';
  return s || NEW_PANE_AGENT_ID;
}

export function isRealAgentId(id: string | null | undefined): id is string {
  return Boolean(id && id !== NEW_PANE_AGENT_ID);
}

export function findPaneByAgent(
  tree: PaneTreeState<MainPaneValue>,
  agentInstanceId: string,
): string | undefined {
  if (!isRealAgentId(agentInstanceId)) return undefined;
  for (const paneId of getContentPaneIds(tree)) {
    const pane = tree.panes[paneId];
    if (pane?.kind === 'content' && pane.value.agentInstanceId === agentInstanceId) {
      return paneId;
    }
  }
  return undefined;
}

function resolveTargetPaneId(
  tree: PaneTreeState<MainPaneValue>,
  requested?: string,
): string | undefined {
  if (requested && tree.panes[requested]?.kind === 'content') return requested;
  if (tree.panes[tree.focusedPaneId]?.kind === 'content') return tree.focusedPaneId;
  return getContentPaneIds(tree)[0];
}

function setPaneAgent(
  tree: PaneTreeState<MainPaneValue>,
  paneId: string,
  agentInstanceId: string,
): void {
  const pane = tree.panes[paneId];
  if (pane?.kind === 'content') pane.value = { agentInstanceId };
}

/**
 * Removes `paneId` from a multi-pane tree. A sole pane resets to the picker.
 */
function closePaneOrReset(state: WorkspaceLayoutState, paneId: string): void {
  const ids = getContentPaneIds(state.tree);
  if (ids.length <= 1) {
    state.tree = createInitialMainTree(NEW_PANE_AGENT_ID, ids[0] || INITIAL_MAIN_PANE_ID);
    return;
  }
  const empty = closePaneInTree(state.tree, paneId);
  if (empty || getContentPaneIds(state.tree).length === 0) {
    state.tree = createInitialMainTree();
  }
}

const workspaceLayoutSlice = createSlice({
  name: 'workspaceLayout',
  initialState,
  reducers: {
    setFocusedMainPane(state, action: PayloadAction<string>) {
      if (state.tree.panes[action.payload]?.kind === 'content') {
        state.tree.focusedPaneId = action.payload;
      }
    },

    /**
     * Splits a pane. Without an agent the new leaf is the `'_new'` picker.
     * With an agent that is already open, focuses it instead (dedupe).
     */
    splitMainPane(
      state,
      action: PayloadAction<{
        targetPaneId?: string;
        direction: SplitInputDirection;
        agentInstanceId?: string;
        newPaneId?: string;
      }>,
    ) {
      const { targetPaneId, direction, newPaneId } = action.payload;
      const agentInstanceId = normalizeAgentId(action.payload.agentInstanceId);
      const existing = findPaneByAgent(state.tree, agentInstanceId);
      if (existing) {
        state.tree.focusedPaneId = existing;
        return;
      }
      const target = resolveTargetPaneId(state.tree, targetPaneId);
      if (!target) return;
      splitPaneInTree(state.tree, target, direction, { agentInstanceId }, newPaneId);
    },

    closeMainPane(state, action: PayloadAction<string>) {
      if (state.tree.panes[action.payload]?.kind !== 'content') return;
      closePaneOrReset(state, action.payload);
    },

    /**
     * Puts an agent into a pane (picker selection, agent switcher). If the agent
     * is already open in ANOTHER pane, that pane is focused instead; a picker
     * pane that triggered the open is then closed so no empty leaf lingers.
     */
    assignMainPaneAgent(
      state,
      action: PayloadAction<{ paneId?: string; agentInstanceId: string }>,
    ) {
      const target = resolveTargetPaneId(state.tree, action.payload.paneId);
      if (!target) return;
      const agentInstanceId = normalizeAgentId(action.payload.agentInstanceId);
      const existing = findPaneByAgent(state.tree, agentInstanceId);
      if (existing && existing !== target) {
        const targetPane = state.tree.panes[target];
        const targetIsPicker =
          targetPane?.kind === 'content' &&
          targetPane.value.agentInstanceId === NEW_PANE_AGENT_ID;
        if (targetIsPicker && getContentPaneIds(state.tree).length > 1) {
          closePaneInTree(state.tree, target);
        }
        state.tree.focusedPaneId = existing;
        return;
      }
      setPaneAgent(state.tree, target, agentInstanceId);
      state.tree.focusedPaneId = target;
    },

    /**
     * Route sync / "Full View": focuses the agent's pane if it is open,
     * otherwise replaces the focused pane's agent.
     */
    navigateMainToAgent(state, action: PayloadAction<string>) {
      const agentInstanceId = normalizeAgentId(action.payload);
      if (!isRealAgentId(agentInstanceId)) return;
      const existing = findPaneByAgent(state.tree, agentInstanceId);
      if (existing) {
        state.tree.focusedPaneId = existing;
        return;
      }
      const target = resolveTargetPaneId(state.tree);
      if (!target) {
        state.tree = createInitialMainTree(agentInstanceId);
        return;
      }
      setPaneAgent(state.tree, target, agentInstanceId);
      state.tree.focusedPaneId = target;
    },

    moveMainPane(
      state,
      action: PayloadAction<{
        sourcePaneId: string;
        targetPaneId: string;
        direction: SplitInputDirection;
      }>,
    ) {
      const { sourcePaneId, targetPaneId, direction } = action.payload;
      movePaneInTree(state.tree, sourcePaneId, targetPaneId, direction);
    },

    swapMainPanes(state, action: PayloadAction<{ paneIdA: string; paneIdB: string }>) {
      swapPanesInTree(state.tree, action.payload.paneIdA, action.payload.paneIdB);
    },

    resizeMainSplit(state, action: PayloadAction<{ splitPaneId: string; ratio: number }>) {
      resizeSplitInTree(state.tree, action.payload.splitPaneId, action.payload.ratio);
    },

    equalizeMainPanes(state) {
      equalizeTreeRatios(state.tree);
    },

    toggleMaximizeMainPane(state, action: PayloadAction<string | undefined>) {
      toggleMaximizePaneInTree(state.tree, action.payload);
    },

    hydrateWorkspaceLayout(state, action: PayloadAction<unknown>) {
      const tree = sanitizeMainTree(action.payload);
      if (tree) state.tree = tree;
    },

    resetWorkspaceLayout(state) {
      state.tree = createInitialMainTree();
    },
  },
});

/**
 * Validates a persisted tree: drops malformed nodes, prunes unreachable ones,
 * repairs focus/maximize and enforces the agent dedupe invariant (later
 * duplicates become pickers).
 */
export function sanitizeMainTree(raw: unknown): PaneTreeState<MainPaneValue> | null {
  const tree = raw as PaneTreeState<MainPaneValue> | null;
  if (
    !tree ||
    typeof tree !== 'object' ||
    Array.isArray(tree) ||
    typeof tree.rootPaneId !== 'string' ||
    !tree.panes ||
    typeof tree.panes !== 'object' ||
    Array.isArray(tree.panes)
  ) {
    return null;
  }
  const panes: PaneTreeState<MainPaneValue>['panes'] = {};
  const seenAgents = new Set<string>();
  const visit = (id: string, depth: number) => {
    if (!id || panes[id] || depth > 64) return;
    const node = (tree.panes as Record<string, any>)[id];
    if (!node || typeof node !== 'object') return;
    if (node.kind === 'split') {
      if (typeof node.leftChildId !== 'string' || typeof node.rightChildId !== 'string') return;
      const ratio =
        typeof node.ratio === 'number' && Number.isFinite(node.ratio)
          ? Math.max(5, Math.min(95, node.ratio))
          : 50;
      panes[id] = {
        kind: 'split',
        axis: node.axis === 'vertical' ? 'vertical' : 'horizontal',
        leftChildId: node.leftChildId,
        rightChildId: node.rightChildId,
        ratio,
      };
      visit(node.leftChildId, depth + 1);
      visit(node.rightChildId, depth + 1);
    } else if (node.kind === 'content') {
      let agentInstanceId = normalizeAgentId(node.value?.agentInstanceId);
      if (isRealAgentId(agentInstanceId)) {
        if (seenAgents.has(agentInstanceId)) agentInstanceId = NEW_PANE_AGENT_ID;
        else seenAgents.add(agentInstanceId);
      }
      panes[id] = { kind: 'content', value: { agentInstanceId } };
    }
  };
  visit(tree.rootPaneId, 0);
  // A split whose child failed validation is unusable.
  for (const [id, node] of Object.entries(panes)) {
    if (node.kind === 'split' && (!panes[node.leftChildId] || !panes[node.rightChildId])) {
      return null;
    }
    void id;
  }
  if (!panes[tree.rootPaneId]) return null;
  const candidate: PaneTreeState<MainPaneValue> = {
    rootPaneId: tree.rootPaneId,
    panes,
    focusedPaneId: tree.focusedPaneId,
    maximizedPaneId: tree.maximizedPaneId ?? null,
  };
  const ids = calculatePaneLayouts(candidate).contentLayouts.map((l) => l.paneId);
  if (ids.length === 0) return null;
  if (candidate.panes[candidate.focusedPaneId]?.kind !== 'content') {
    candidate.focusedPaneId = ids[0];
  }
  if (
    ids.length <= 1 ||
    !candidate.maximizedPaneId ||
    candidate.panes[candidate.maximizedPaneId]?.kind !== 'content'
  ) {
    candidate.maximizedPaneId = null;
  }
  return candidate;
}

export const {
  setFocusedMainPane,
  splitMainPane,
  closeMainPane,
  assignMainPaneAgent,
  navigateMainToAgent,
  moveMainPane,
  swapMainPanes,
  resizeMainSplit,
  equalizeMainPanes,
  toggleMaximizeMainPane,
  hydrateWorkspaceLayout,
  resetWorkspaceLayout,
} = workspaceLayoutSlice.actions;

function extract(state: any): WorkspaceLayoutState {
  if (state?.workspaceLayout?.tree) return state.workspaceLayout as WorkspaceLayoutState;
  if (state?.tree?.panes) return state as WorkspaceLayoutState;
  return initialState;
}

export const selectMainTree = (state: any): PaneTreeState<MainPaneValue> => extract(state).tree;

export const selectFocusedMainPaneId = (state: any): string => extract(state).tree.focusedPaneId;

export const selectFocusedMainAgentId = (state: any): string => {
  const tree = extract(state).tree;
  const focused = tree.panes[tree.focusedPaneId];
  if (focused?.kind === 'content') return focused.value.agentInstanceId;
  const first = getContentPaneIds(tree)[0];
  const pane = first ? tree.panes[first] : undefined;
  return pane?.kind === 'content' ? pane.value.agentInstanceId : NEW_PANE_AGENT_ID;
};

export const selectMainPaneIds = createSelector([selectMainTree], (tree) =>
  getContentPaneIds(tree),
);

/** Agents currently open in Main (in tree order, no pickers). */
export const selectMainAgentIds = createSelector([selectMainTree], (tree): string[] => {
  const ids: string[] = [];
  for (const paneId of getContentPaneIds(tree)) {
    const pane = tree.panes[paneId];
    if (pane?.kind === 'content' && isRealAgentId(pane.value.agentInstanceId)) {
      ids.push(pane.value.agentInstanceId);
    }
  }
  return ids;
});

export default workspaceLayoutSlice.reducer;
