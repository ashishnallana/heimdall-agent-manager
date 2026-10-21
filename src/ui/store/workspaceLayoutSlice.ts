import { createSelector, createSlice, type PayloadAction } from '@reduxjs/toolkit';
import {
  calculatePaneLayouts,
  closePaneInTree,
  createPaneTreeState,
  equalizeTreeRatios,
  getContentPaneIds,
  getPaneLocation,
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
 * The split tree of agent chats for `/conversations/<id1>+<id2>?focused=<id>`.
 * The URL is the source of truth for the OPEN PANE SET (see
 * utils/conversationUrl.ts): `setLayoutFromUrl` reconciles the tree from it and
 * in-app edits are written back to the URL. Leaves hold ONLY an agent instance
 * id, or `'_new'` for the new-chat picker. Split geometry is remembered per id
 * set as a split group (store/splitGroups.ts), never globally or per chain.
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

export type LauncherIntent = 'agent' | 'shell';

export interface MainPaneValue {
  agentInstanceId: string; // NEW_PANE_AGENT_ID for the new-chat picker
  /** One-shot presentation hint for a shortcut-created picker pane. */
  launchIntent?: LauncherIntent;
}

export interface WorkspaceLayoutState {
  tree: PaneTreeState<MainPaneValue>;
}

export type FocusedPaneResize = 'narrower' | 'wider' | 'shorter' | 'taller';

export const INITIAL_MAIN_PANE_ID = 'pane-1';

export function createInitialMainTree(
  agentInstanceId: string = NEW_PANE_AGENT_ID,
  paneId = INITIAL_MAIN_PANE_ID,
  launchIntent?: LauncherIntent,
): PaneTreeState<MainPaneValue> {
  return createPaneTreeState<MainPaneValue>(
    launchIntent && agentInstanceId === NEW_PANE_AGENT_ID
      ? { agentInstanceId, launchIntent }
      : { agentInstanceId },
    paneId,
  );
}

const initialState: WorkspaceLayoutState = {
  tree: createInitialMainTree(),
};

function normalizeAgentId(id: unknown): string {
  const s = typeof id === 'string' ? id.trim() : '';
  return s || NEW_PANE_AGENT_ID;
}

/** Any real pane occupant (agent conversation or shell), i.e. not the picker. */
export function isRealAgentId(id: string | null | undefined): id is string {
  return Boolean(id && id !== NEW_PANE_AGENT_ID);
}

/**
 * A Main pane can hold an interactive shell instead of an agent. Shell session ids
 * are minted as `sh_…` by the hub, so the pane value's id alone tells the kinds
 * apart (the URL model stays `#/conversations/<id>+<id>`).
 */
export const SHELL_PANE_ID_PREFIX = 'sh_';

export function isShellPaneId(id: string | null | undefined): id is string {
  return Boolean(id && id.startsWith(SHELL_PANE_ID_PREFIX));
}

/** A real agent conversation pane (not the picker, not a shell). */
export function isAgentPaneId(id: string | null | undefined): id is string {
  return isRealAgentId(id) && !isShellPaneId(id);
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

function nearestResizeSplit(
  tree: PaneTreeState<MainPaneValue>,
  paneId: string,
  axis: 'horizontal' | 'vertical',
): { splitPaneId: string; side: 'left' | 'right'; ratio: number } | undefined {
  let childId = paneId;
  while (childId !== tree.rootPaneId) {
    const location = getPaneLocation(tree, childId);
    if (!location) return undefined;
    const parent = tree.panes[location.parentId];
    if (parent?.kind === 'split' && parent.axis === axis) {
      return { splitPaneId: location.parentId, side: location.side, ratio: parent.ratio };
    }
    childId = location.parentId;
  }
  return undefined;
}

export function canResizeFocusedMainPane(
  tree: PaneTreeState<MainPaneValue>,
  change: FocusedPaneResize,
): boolean {
  const horizontal = change === 'narrower' || change === 'wider';
  return Boolean(nearestResizeSplit(tree, tree.focusedPaneId, horizontal ? 'horizontal' : 'vertical'));
}

function setPaneAgent(
  tree: PaneTreeState<MainPaneValue>,
  paneId: string,
  agentInstanceId: string,
  launchIntent?: LauncherIntent,
): void {
  const pane = tree.panes[paneId];
  if (pane?.kind === 'content') {
    pane.value = launchIntent && agentInstanceId === NEW_PANE_AGENT_ID
      ? { agentInstanceId, launchIntent }
      : { agentInstanceId };
  }
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
        launchIntent?: LauncherIntent;
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
      const value: MainPaneValue =
        action.payload.launchIntent && agentInstanceId === NEW_PANE_AGENT_ID
          ? { agentInstanceId, launchIntent: action.payload.launchIntent }
          : { agentInstanceId };
      splitPaneInTree(state.tree, target, direction, value, newPaneId);
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
      action: PayloadAction<{
        paneId?: string;
        agentInstanceId: string;
        launchIntent?: LauncherIntent;
      }>,
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
      setPaneAgent(state.tree, target, agentInstanceId, action.payload.launchIntent);
      state.tree.focusedPaneId = target;
    },

    /**
     * URL -> layout (Jetski `setLayoutFromUrl`):
     * - same id set: only the focused pane changes (order is reconciled back
     *   into the URL by the Redux->URL sync);
     * - same count with exactly one id swapped: that pane's agent is replaced
     *   in place (geometry preserved);
     * - one id: a single pane;
     * - N ids: the saved geometry for that exact set, else a default nested
     *   horizontal split.
     */
    setLayoutFromUrl(
      state,
      action: PayloadAction<{
        ids: string[];
        focusedId?: string;
        savedLayout?: PaneTreeState<MainPaneValue> | null;
      }>,
    ) {
      const ids = (action.payload.ids || []).map(normalizeAgentId);
      if (ids.length === 0) return;
      const { focusedId } = action.payload;
      const tree = state.tree;
      const paneIds = getContentPaneIds(tree);
      const currentIds = paneIds.map((id) => {
        const pane = tree.panes[id];
        return pane?.kind === 'content' ? pane.value.agentInstanceId : NEW_PANE_AGENT_ID;
      });
      const focusPaneFor = (agentId: string | undefined) => {
        if (!agentId) return;
        const focusedPane = tree.panes[tree.focusedPaneId];
        if (focusedPane?.kind === 'content' && focusedPane.value.agentInstanceId === agentId) return;
        const idx = currentIds.indexOf(agentId);
        if (idx >= 0) tree.focusedPaneId = paneIds[idx];
      };
      const sameSet =
        currentIds.length === ids.length && [...currentIds].sort().join('+') === [...ids].sort().join('+');
      if (sameSet) {
        focusPaneFor(focusedId);
        return;
      }
      const nextSet = new Set(ids);
      const curSet = new Set(currentIds);
      const removed = currentIds.filter((id) => !nextSet.has(id));
      const added = ids.filter((id) => !curSet.has(id));
      if (currentIds.length === ids.length && removed.length === 1 && added.length === 1) {
        const idx = currentIds.indexOf(removed[0]);
        setPaneAgent(tree, paneIds[idx], added[0]);
        if (!focusedId || focusedId === added[0]) tree.focusedPaneId = paneIds[idx];
        else {
          currentIds[idx] = added[0];
          focusPaneFor(focusedId);
        }
        return;
      }
      if (ids.length === 1) {
        state.tree = createInitialMainTree(ids[0]);
        return;
      }
      const saved = action.payload.savedLayout ? sanitizeMainTree(action.payload.savedLayout) : null;
      state.tree = saved ?? buildDefaultSplitTree(ids);
      const leafIds = getContentPaneIds(state.tree);
      const focusIdx = leafIds.findIndex((pid) => {
        const pane = state.tree.panes[pid];
        return pane?.kind === 'content' && pane.value.agentInstanceId === focusedId;
      });
      if (focusIdx >= 0) state.tree.focusedPaneId = leafIds[focusIdx];
      state.tree.maximizedPaneId = null;
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

    /** Resize the focused subtree by five percentage points in its nearest matching split. */
    resizeFocusedMainPane(state, action: PayloadAction<FocusedPaneResize>) {
      const change = action.payload;
      const horizontal = change === 'narrower' || change === 'wider';
      const target = nearestResizeSplit(
        state.tree,
        state.tree.focusedPaneId,
        horizontal ? 'horizontal' : 'vertical',
      );
      if (!target) return;
      const growing = change === 'wider' || change === 'taller';
      const ratioDelta = (growing ? 5 : -5) * (target.side === 'left' ? 1 : -1);
      resizeSplitInTree(state.tree, target.splitPaneId, target.ratio + ratioDelta);
    },

    equalizeMainPanes(state) {
      equalizeTreeRatios(state.tree);
    },

    toggleMaximizeMainPane(state, action: PayloadAction<string | undefined>) {
      toggleMaximizePaneInTree(state.tree, action.payload);
    },

    resetWorkspaceLayout(state) {
      state.tree = createInitialMainTree();
    },
  },
});

/**
 * Default geometry for N panes: nested binary horizontal splits with equal
 * widths (pane-1 | (pane-2 | (pane-3 ...))).
 */
export function buildDefaultSplitTree(ids: string[]): PaneTreeState<MainPaneValue> {
  const panes: PaneTreeState<MainPaneValue>['panes'] = {};
  const build = (start: number): string => {
    const paneId = `pane-${start + 1}`;
    panes[paneId] = { kind: 'content', value: { agentInstanceId: ids[start] } };
    const remaining = ids.length - start;
    if (remaining === 1) return paneId;
    const splitId = `split-${start + 1}`;
    const right = build(start + 1);
    panes[splitId] = {
      kind: 'split',
      axis: 'horizontal',
      leftChildId: paneId,
      rightChildId: right,
      ratio: 100 / remaining,
    };
    return splitId;
  };
  const rootPaneId = build(0);
  return { rootPaneId, panes, focusedPaneId: 'pane-1', maximizedPaneId: null };
}

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
      const launchIntent =
        agentInstanceId === NEW_PANE_AGENT_ID &&
        (node.value?.launchIntent === 'agent' || node.value?.launchIntent === 'shell')
          ? node.value.launchIntent
          : undefined;
      panes[id] = {
        kind: 'content',
        value: launchIntent ? { agentInstanceId, launchIntent } : { agentInstanceId },
      };
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
  setLayoutFromUrl,
  moveMainPane,
  swapMainPanes,
  resizeMainSplit,
  resizeFocusedMainPane,
  equalizeMainPanes,
  toggleMaximizeMainPane,
  resetWorkspaceLayout,
} = workspaceLayoutSlice.actions;

function extract(state: any): WorkspaceLayoutState {
  if (state?.workspaceLayout?.tree) return state.workspaceLayout as WorkspaceLayoutState;
  if (state?.tree?.panes) return state as WorkspaceLayoutState;
  return initialState;
}

export const selectMainTree = (state: any): PaneTreeState<MainPaneValue> => extract(state).tree;

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

/** Leaf agent ids in tree order INCLUDING `_new` pickers (the URL pane set). */
export const selectMainLeafIds = createSelector([selectMainTree], (tree): string[] =>
  getContentPaneIds(tree).map((paneId) => {
    const pane = tree.panes[paneId];
    return pane?.kind === 'content' ? pane.value.agentInstanceId : NEW_PANE_AGENT_ID;
  }),
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
