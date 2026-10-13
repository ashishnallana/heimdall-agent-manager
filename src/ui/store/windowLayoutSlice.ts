import { createSelector, createSlice, type PayloadAction } from '@reduxjs/toolkit';
import {
  calculatePaneLayouts,
  closePaneInTree,
  createPaneTreeState,
  equalizeTreeRatios,
  getContentPaneIds,
  movePaneInTree,
  PaneTreeState,
  resizeSplitInTree,
  SplitDirection,
  SplitInputDirection,
  splitPaneInTree,
  swapPanesInTree,
  toggleMaximizePaneInTree,
} from '../tiling';

export const NEW_WINDOW_PANE_ID = '_new';

export interface WindowPaneValue {
  kind: 'conversation' | 'new';
  agentInstanceId: string; // '_new' when kind === 'new'
  chainId?: string | null;
  projectId?: string | null;
  focusMessageId?: string;
  title?: string;
}

export interface WindowLayoutState {
  tree: PaneTreeState<WindowPaneValue>;
  pendingDropTarget: { paneId: string; direction: SplitDirection } | null;
}

export function createInitialWindowTree(
  initialPaneId = 'window-pane-1',
): PaneTreeState<WindowPaneValue> {
  return createPaneTreeState<WindowPaneValue>(
    {
      kind: 'new',
      agentInstanceId: NEW_WINDOW_PANE_ID,
    },
    initialPaneId,
  );
}

const initialState: WindowLayoutState = {
  tree: createInitialWindowTree(),
  pendingDropTarget: null,
};

function findWindowPaneByAgentInstanceId(
  tree: PaneTreeState<WindowPaneValue>,
  agentInstanceId: string,
): string | undefined {
  if (!agentInstanceId || agentInstanceId === NEW_WINDOW_PANE_ID) {
    return undefined;
  }
  const contentIds = getContentPaneIds(tree);
  for (const paneId of contentIds) {
    const pane = tree.panes[paneId];
    if (
      pane &&
      pane.kind === 'content' &&
      pane.value.kind === 'conversation' &&
      pane.value.agentInstanceId === agentInstanceId
    ) {
      return paneId;
    }
  }
  return undefined;
}

const windowLayoutSlice = createSlice({
  name: 'windowLayout',
  initialState,
  reducers: {
    setFocusedWindowPane(state, action: PayloadAction<string>) {
      const paneId = action.payload;
      if (state.tree.panes[paneId]?.kind === 'content') {
        state.tree.focusedPaneId = paneId;
      }
    },

    splitWindowPane(
      state,
      action: PayloadAction<{
        targetPaneId?: string;
        direction: SplitInputDirection;
        agentInstanceId?: string;
        chainId?: string | null;
        projectId?: string | null;
        focusMessageId?: string;
        title?: string;
        newPaneId?: string;
      }>,
    ) {
      const {
        targetPaneId,
        direction,
        agentInstanceId,
        chainId,
        projectId,
        focusMessageId,
        title,
        newPaneId,
      } = action.payload;

      const resolvedAgentId = agentInstanceId || NEW_WINDOW_PANE_ID;

      // If splitting with a specific conversation that is already open in a pane, focus it instead of duplicating
      if (resolvedAgentId !== NEW_WINDOW_PANE_ID) {
        const existingPaneId = findWindowPaneByAgentInstanceId(
          state.tree,
          resolvedAgentId,
        );
        if (existingPaneId) {
          const existingPane = state.tree.panes[existingPaneId];
          if (existingPane && existingPane.kind === 'content') {
            if (chainId !== undefined) existingPane.value.chainId = chainId;
            if (projectId !== undefined) existingPane.value.projectId = projectId;
            if (focusMessageId !== undefined) {
              existingPane.value.focusMessageId = focusMessageId;
            }
            if (title !== undefined) existingPane.value.title = title;
          }
          state.tree.focusedPaneId = existingPaneId;
          return;
        }
      }

      const paneIdToSplit =
        targetPaneId && state.tree.panes[targetPaneId]?.kind === 'content'
          ? targetPaneId
          : state.tree.focusedPaneId;

      const newValue: WindowPaneValue =
        resolvedAgentId === NEW_WINDOW_PANE_ID
          ? {
              kind: 'new',
              agentInstanceId: NEW_WINDOW_PANE_ID,
            }
          : {
              kind: 'conversation',
              agentInstanceId: resolvedAgentId,
              chainId: chainId ?? null,
              projectId: projectId ?? null,
              focusMessageId,
              title,
            };

      splitPaneInTree(
        state.tree,
        paneIdToSplit,
        direction,
        newValue,
        newPaneId,
      );
    },

    closeWindowPane(state, action: PayloadAction<string>) {
      const paneId = action.payload;
      const targetPane = state.tree.panes[paneId];
      if (!targetPane || targetPane.kind !== 'content') {
        return;
      }

      const contentIds = getContentPaneIds(state.tree);
      if (contentIds.length <= 1) {
        // Reset sole pane to '_new'
        const onlyId = contentIds[0] || 'window-pane-1';
        state.tree = createInitialWindowTree(onlyId);
        return;
      }

      const isEmpty = closePaneInTree(state.tree, paneId);
      if (isEmpty || getContentPaneIds(state.tree).length === 0) {
        state.tree = createInitialWindowTree();
      }
    },

    assignWindowPaneConversation(
      state,
      action: PayloadAction<{
        paneId?: string;
        agentInstanceId: string;
        chainId?: string | null;
        projectId?: string | null;
        focusMessageId?: string;
        title?: string;
      }>,
    ) {
      const {
        paneId,
        agentInstanceId,
        chainId,
        projectId,
        focusMessageId,
        title,
      } = action.payload;

      const targetId =
        paneId && state.tree.panes[paneId]?.kind === 'content'
          ? paneId
          : state.tree.panes[state.tree.focusedPaneId]?.kind === 'content'
            ? state.tree.focusedPaneId
            : getContentPaneIds(state.tree)[0];

      if (!targetId) {
        return;
      }

      const targetPane = state.tree.panes[targetId];
      if (!targetPane || targetPane.kind !== 'content') {
        return;
      }

      if (!agentInstanceId || agentInstanceId === NEW_WINDOW_PANE_ID) {
        targetPane.value = {
          kind: 'new',
          agentInstanceId: NEW_WINDOW_PANE_ID,
        };
      } else {
        targetPane.value = {
          kind: 'conversation',
          agentInstanceId,
          chainId: chainId ?? targetPane.value.chainId ?? null,
          projectId: projectId ?? targetPane.value.projectId ?? null,
          focusMessageId,
          title: title ?? targetPane.value.title,
        };
      }
      state.tree.focusedPaneId = targetId;
    },

    syncRouteConversationToWindowLayout(
      state,
      action: PayloadAction<{
        agentInstanceId: string;
        chainId?: string | null;
        projectId?: string | null;
        focusMessageId?: string;
        title?: string;
      }>,
    ) {
      const {
        agentInstanceId,
        chainId,
        projectId,
        focusMessageId,
        title,
      } = action.payload;

      if (!agentInstanceId || agentInstanceId === NEW_WINDOW_PANE_ID) {
        return;
      }

      // 1. If already open in a window pane, focus it and update optional metadata
      const existingPaneId = findWindowPaneByAgentInstanceId(
        state.tree,
        agentInstanceId,
      );
      if (existingPaneId) {
        const existingPane = state.tree.panes[existingPaneId];
        if (existingPane && existingPane.kind === 'content') {
          if (chainId !== undefined) existingPane.value.chainId = chainId;
          if (projectId !== undefined) existingPane.value.projectId = projectId;
          if (focusMessageId !== undefined) {
            existingPane.value.focusMessageId = focusMessageId;
          }
          if (title !== undefined) existingPane.value.title = title;
        }
        state.tree.focusedPaneId = existingPaneId;
        return;
      }

      // 2. Otherwise assign to the focused pane (or first content pane)
      const targetId =
        state.tree.panes[state.tree.focusedPaneId]?.kind === 'content'
          ? state.tree.focusedPaneId
          : getContentPaneIds(state.tree)[0];

      if (!targetId) {
        state.tree = createPaneTreeState<WindowPaneValue>(
          {
            kind: 'conversation',
            agentInstanceId,
            chainId: chainId ?? null,
            projectId: projectId ?? null,
            focusMessageId,
            title,
          },
          'window-pane-1',
        );
        return;
      }

      const targetPane = state.tree.panes[targetId];
      if (targetPane && targetPane.kind === 'content') {
        targetPane.value = {
          kind: 'conversation',
          agentInstanceId,
          chainId: chainId ?? null,
          projectId: projectId ?? null,
          focusMessageId,
          title,
        };
        state.tree.focusedPaneId = targetId;
      }
    },

    moveWindowPane(
      state,
      action: PayloadAction<{
        sourcePaneId: string;
        targetPaneId: string;
        direction: SplitInputDirection;
      }>,
    ) {
      const { sourcePaneId, targetPaneId, direction } = action.payload;
      movePaneInTree(state.tree, sourcePaneId, targetPaneId, direction);
      state.pendingDropTarget = null;
    },

    swapWindowPanes(
      state,
      action: PayloadAction<{
        paneIdA: string;
        paneIdB: string;
      }>,
    ) {
      swapPanesInTree(state.tree, action.payload.paneIdA, action.payload.paneIdB);
    },

    resizeWindowSplit(
      state,
      action: PayloadAction<{
        splitPaneId: string;
        ratio: number;
      }>,
    ) {
      resizeSplitInTree(
        state.tree,
        action.payload.splitPaneId,
        action.payload.ratio,
      );
    },

    equalizeWindowPanes(state) {
      equalizeTreeRatios(state.tree);
    },

    toggleMaximizeWindowPane(
      state,
      action: PayloadAction<string | undefined>,
    ) {
      toggleMaximizePaneInTree(state.tree, action.payload);
    },

    setWindowPendingDropTarget(
      state,
      action: PayloadAction<{
        paneId: string;
        direction: SplitDirection;
      } | null>,
    ) {
      state.pendingDropTarget = action.payload;
    },

    hydrateWindowLayout(
      state,
      action: PayloadAction<PaneTreeState<WindowPaneValue>>,
    ) {
      const tree = action.payload;
      if (
        !tree ||
        typeof tree !== 'object' ||
        Array.isArray(tree) ||
        typeof tree.rootPaneId !== 'string' ||
        !tree.panes ||
        typeof tree.panes !== 'object' ||
        Array.isArray(tree.panes) ||
        !tree.panes[tree.rootPaneId]
      ) {
        return;
      }

      const sanitizedPanes: PaneTreeState<WindowPaneValue>['panes'] = {};
      for (const [paneId, pane] of Object.entries(tree.panes)) {
        if (!pane || typeof pane !== 'object') continue;
        if (pane.kind === 'split') {
          if (
            typeof pane.leftChildId !== 'string' ||
            !pane.leftChildId ||
            typeof pane.rightChildId !== 'string' ||
            !pane.rightChildId
          ) {
            continue;
          }
          sanitizedPanes[paneId] = {
            kind: 'split',
            axis: pane.axis === 'vertical' ? 'vertical' : 'horizontal',
            leftChildId: pane.leftChildId,
            rightChildId: pane.rightChildId,
            ratio:
              typeof pane.ratio === 'number' &&
              Number.isFinite(pane.ratio) &&
              !Number.isNaN(pane.ratio)
                ? Math.max(5, Math.min(95, pane.ratio))
                : 50,
          };
        } else if (pane.kind === 'content') {
          const rawVal =
            pane.value && typeof pane.value === 'object'
              ? pane.value
              : undefined;
          const rawAgentId =
            typeof rawVal?.agentInstanceId === 'string'
              ? rawVal.agentInstanceId.trim()
              : '';
          const isConversation =
            rawVal?.kind === 'conversation' &&
            rawAgentId.length > 0 &&
            rawAgentId !== NEW_WINDOW_PANE_ID;

          sanitizedPanes[paneId] = {
            kind: 'content',
            value: isConversation
              ? {
                  kind: 'conversation',
                  agentInstanceId: rawAgentId,
                  chainId:
                    typeof rawVal?.chainId === 'string' ? rawVal.chainId : null,
                  projectId:
                    typeof rawVal?.projectId === 'string'
                      ? rawVal.projectId
                      : null,
                  focusMessageId:
                    typeof rawVal?.focusMessageId === 'string'
                      ? rawVal.focusMessageId
                      : undefined,
                  title:
                    typeof rawVal?.title === 'string'
                      ? rawVal.title
                      : undefined,
                }
              : {
                  kind: 'new',
                  agentInstanceId: NEW_WINDOW_PANE_ID,
                },
          };
        }
      }

      if (!sanitizedPanes[tree.rootPaneId]) {
        return;
      }

      // Prune unreachable nodes not visited from rootPaneId
      const reachablePanes: PaneTreeState<WindowPaneValue>['panes'] = {};
      const visited = new Set<string>();
      const visit = (id: string) => {
        if (!id || visited.has(id)) return;
        const node = sanitizedPanes[id];
        if (!node) return;
        visited.add(id);
        reachablePanes[id] = node;
        if (node.kind === 'split') {
          visit(node.leftChildId);
          visit(node.rightChildId);
        }
      };
      visit(tree.rootPaneId);

      const candidateTree: PaneTreeState<WindowPaneValue> = {
        rootPaneId: tree.rootPaneId,
        panes: reachablePanes,
        focusedPaneId: tree.focusedPaneId,
        maximizedPaneId: tree.maximizedPaneId ?? null,
      };

      const { contentLayouts } = calculatePaneLayouts(candidateTree);
      if (contentLayouts.length === 0) {
        return;
      }

      const contentIds = contentLayouts.map((l) => l.paneId);
      const focusedId =
        candidateTree.focusedPaneId &&
        candidateTree.panes[candidateTree.focusedPaneId]?.kind === 'content'
          ? candidateTree.focusedPaneId
          : contentIds[0];
      const maximizedId =
        contentIds.length > 1 &&
        candidateTree.maximizedPaneId &&
        candidateTree.panes[candidateTree.maximizedPaneId]?.kind === 'content'
          ? candidateTree.maximizedPaneId
          : null;

      state.tree = {
        ...candidateTree,
        focusedPaneId: focusedId,
        maximizedPaneId: maximizedId,
      };
      state.pendingDropTarget = null;
    },

    resetWindowLayout(state) {
      state.tree = createInitialWindowTree();
      state.pendingDropTarget = null;
    },
  },
});

export const {
  setFocusedWindowPane,
  splitWindowPane,
  closeWindowPane,
  assignWindowPaneConversation,
  syncRouteConversationToWindowLayout,
  moveWindowPane,
  swapWindowPanes,
  resizeWindowSplit,
  equalizeWindowPanes,
  toggleMaximizeWindowPane,
  setWindowPendingDropTarget,
  hydrateWindowLayout,
  resetWindowLayout,
} = windowLayoutSlice.actions;

function extractWindowLayoutSlice(state: any): WindowLayoutState {
  if (state && state.windowLayout && state.windowLayout.tree) {
    return state.windowLayout as WindowLayoutState;
  }
  if (state && state.tree && state.tree.panes) {
    return state as WindowLayoutState;
  }
  return initialState;
}

export const selectWindowLayoutTree = (
  state: any,
): PaneTreeState<WindowPaneValue> => extractWindowLayoutSlice(state).tree;

export const selectFocusedWindowPaneId = (state: any): string =>
  extractWindowLayoutSlice(state).tree.focusedPaneId;

export const selectFocusedWindowPane = (
  state: any,
): WindowPaneValue | undefined => {
  const tree = extractWindowLayoutSlice(state).tree;
  const focused = tree.panes[tree.focusedPaneId];
  if (focused && focused.kind === 'content') {
    return focused.value;
  }
  const firstId = getContentPaneIds(tree)[0];
  const first = firstId ? tree.panes[firstId] : undefined;
  return first && first.kind === 'content' ? first.value : undefined;
};

export const selectWindowMaximizedPaneId = (state: any): string | null =>
  extractWindowLayoutSlice(state).tree.maximizedPaneId ?? null;

export const selectWindowPendingDropTarget = (
  state: any,
): { paneId: string; direction: SplitDirection } | null =>
  extractWindowLayoutSlice(state).pendingDropTarget ?? null;

export const selectOpenWindowConversationIds = createSelector(
  [selectWindowLayoutTree],
  (tree): string[] => {
    const ids: string[] = [];
    for (const paneId of getContentPaneIds(tree)) {
      const pane = tree.panes[paneId];
      if (
        pane &&
        pane.kind === 'content' &&
        pane.value.kind === 'conversation' &&
        pane.value.agentInstanceId &&
        pane.value.agentInstanceId !== NEW_WINDOW_PANE_ID &&
        !ids.includes(pane.value.agentInstanceId)
      ) {
        ids.push(pane.value.agentInstanceId);
      }
    }
    return ids;
  },
);

export default windowLayoutSlice.reducer;
