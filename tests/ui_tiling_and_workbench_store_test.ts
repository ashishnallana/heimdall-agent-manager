import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { createRoot } from 'react-dom/client';
import { act } from 'react';
import { JSDOM } from 'jsdom';

import {
  createPaneTreeState,
  toAxis,
  isFirstChild,
  getPaneLocation,
  splitPaneInTree,
  split,
  closePaneInTree,
  closePane,
  movePaneInTree,
  movePane,
  swapPanesInTree,
  swapPanes,
  resizeSplitInTree,
  resizeSplit,
  equalizeTreeRatios,
  equalizePanes,
  toggleMaximizePaneInTree,
  toggleMaximizePane,
  getContentPaneIds,
  toStructureOnly,
  calculatePaneLayouts,
  getSplitDirection,
  getOverlayPosition,
  resolvePaneTarget,
  TilingContainer,
} from '../src/ui/tiling/index.ts';

import windowLayoutReducer, {
  NEW_WINDOW_PANE_ID,
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
  selectWindowLayoutTree,
  selectFocusedWindowPaneId,
  selectFocusedWindowPane,
  selectWindowMaximizedPaneId,
  selectWindowPendingDropTarget,
  selectOpenWindowConversationIds,
} from '../src/ui/store/windowLayoutSlice.ts';

import {
  NEW_TAB_ID,
  WORKBENCH_SURFACE_KINDS,
  WORKBENCH_SURFACE_REGISTRY,
  buildWorkbenchTabId,
  parseWorkbenchTabId,
  createWorkbenchTabState,
  resolveLegacyPanelToSurfaceKind,
} from '../src/ui/store/workbenchTabId.ts';

import workbenchReducer, {
  ensureWorkspaceInitialized,
  setActiveWorkspaceKey,
  setFocusedWorkbenchPane,
  splitWorkbenchPane,
  closeWorkbenchPane,
  moveWorkbenchPane,
  swapWorkbenchPanes,
  resizeWorkbenchSplit,
  equalizeWorkbenchPanes,
  toggleMaximizeWorkbenchPane,
  openNewTabView,
  openOrFocusWorkbenchTab,
  replaceNewTabWithSurface,
  setActiveWorkbenchTab,
  closeWorkbenchTab,
  reorderWorkbenchTabs,
  moveWorkbenchTabToPane,
  splitWorkbenchPaneWithTab,
  updateWorkbenchTabParams,
  replaceWorkbenchTab,
  openPreviewInWorkbench,
  setWorkbenchPendingDropTarget,
  hydrateWorkspaceWorkbench,
  selectWorkspaceWorkbench,
  selectWorkspaceWorkbenchTree,
  selectFocusedWorkbenchPaneId,
  selectFocusedWorkbenchPane,
  selectWorkbenchMaximizedPaneId,
  selectWorkbenchPendingDropTarget,
  selectAllWorkspaceTabs,
} from '../src/ui/store/workbenchSlice.ts';

import {
  readWindowLayoutState,
  writeWindowLayoutState,
  readWorkbenchWorkspaceState,
  writeWorkbenchWorkspaceState,
  resolveWorkbenchWorkspaceKey,
  getComposerDraftKey,
  readComposerDraft,
  writeComposerDraft,
} from '../src/ui/utils/clientPersistence.ts';

test('M1 Tiling Engine: createPaneTreeState, toAxis, isFirstChild, and ID-preserving splitPaneInTree', () => {
  assert.equal(toAxis('top'), 'vertical');
  assert.equal(toAxis('bottom'), 'vertical');
  assert.equal(toAxis('vertical'), 'vertical');
  assert.equal(toAxis('left'), 'horizontal');
  assert.equal(toAxis('right'), 'horizontal');
  assert.equal(toAxis('horizontal'), 'horizontal');

  assert.equal(isFirstChild('top'), true);
  assert.equal(isFirstChild('left'), true);
  assert.equal(isFirstChild('bottom'), false);
  assert.equal(isFirstChild('right'), false);

  const tree = createPaneTreeState({ label: 'initial' }, 'pane-1');
  assert.equal(tree.rootPaneId, 'pane-1');
  assert.equal(tree.focusedPaneId, 'pane-1');
  assert.deepEqual(getContentPaneIds(tree), ['pane-1']);

  const { parentId, newChildId } = splitPaneInTree(
    tree,
    'pane-1',
    'right',
    { label: 'second' },
    'pane-2',
  );
  // pane-1 MUST preserve its exact ID and entry in tree.panes
  assert.ok(tree.panes['pane-1'], 'Original pane-1 must remain in tree.panes');
  assert.equal(tree.panes['pane-1'].kind, 'content');
  assert.equal(newChildId, 'pane-2');
  assert.equal(tree.rootPaneId, parentId);
  assert.equal(tree.focusedPaneId, 'pane-2');

  const rootSplit = tree.panes[parentId];
  assert.equal(rootSplit.kind, 'split');
  if (rootSplit.kind === 'split') {
    assert.equal(rootSplit.axis, 'horizontal');
    assert.equal(rootSplit.leftChildId, 'pane-1');
    assert.equal(rootSplit.rightChildId, 'pane-2');
    assert.equal(rootSplit.ratio, 50);
  }

  assert.deepEqual(getPaneLocation(tree, 'pane-1'), {
    parentId,
    side: 'left',
  });
  assert.deepEqual(getPaneLocation(tree, 'pane-2'), {
    parentId,
    side: 'right',
  });
});

test('M1 Tiling Engine: ID-preserving movePaneInTree, swapPanesInTree, resizeSplitInTree, equalize, maximize, and closePane', () => {
  const tree = createPaneTreeState('A', 'pane-a');
  const split1 = split(tree, 'pane-a', 'right', 'B', 'pane-b');
  const split2 = split(tree, 'pane-b', 'bottom', 'C', 'pane-c');

  assert.deepEqual(getContentPaneIds(tree), ['pane-a', 'pane-b', 'pane-c']);

  // Move pane-c to the top of pane-a; both pane-c and pane-a must preserve their exact IDs!
  const moved = movePane(tree, 'pane-c', 'pane-a', 'top');
  assert.equal(moved, true);
  assert.ok(tree.panes['pane-a'], 'pane-a ID preserved');
  assert.ok(tree.panes['pane-b'], 'pane-b ID preserved');
  assert.ok(tree.panes['pane-c'], 'pane-c ID preserved');
  assert.deepEqual(getContentPaneIds(tree), ['pane-c', 'pane-a', 'pane-b']);

  // Swap pane-c and pane-b
  const swapped = swapPanes(tree, 'pane-c', 'pane-b');
  assert.equal(swapped, true);
  assert.deepEqual(getContentPaneIds(tree), ['pane-b', 'pane-a', 'pane-c']);

  // Resize split with clamping [5, 95] and NaN handling
  resizeSplit(tree, split1.parentId, 120);
  const splitNode = tree.panes[split1.parentId];
  assert.equal(splitNode.kind, 'split');
  if (splitNode.kind === 'split') {
    assert.equal(splitNode.ratio, 95);
  }
  resizeSplitInTree(tree, split1.parentId, -10);
  if (splitNode.kind === 'split') {
    assert.equal(splitNode.ratio, 5);
  }
  resizeSplitInTree(tree, split1.parentId, Number.NaN);
  if (splitNode.kind === 'split') {
    assert.equal(splitNode.ratio, 5, 'NaN should be ignored');
  }

  equalizePanes(tree);
  if (splitNode.kind === 'split') {
    assert.equal(splitNode.ratio, 50);
  }

  // Maximize and restore
  toggleMaximizePane(tree, 'pane-b');
  assert.equal(tree.maximizedPaneId, 'pane-b');
  toggleMaximizePaneInTree(tree, 'pane-b');
  assert.equal(tree.maximizedPaneId, null);

  // Maximize pane-b then close it -> maximizedPaneId cleared and focusedPaneId updated
  toggleMaximizePane(tree, 'pane-b');
  assert.equal(tree.maximizedPaneId, 'pane-b');
  // Test closePane with (id, state) overload
  const emptyAfterCloseB = closePane('pane-b', tree);
  assert.equal(emptyAfterCloseB, false);
  assert.equal(tree.maximizedPaneId, null);
  assert.notEqual(tree.focusedPaneId, 'pane-b');
  assert.deepEqual(getContentPaneIds(tree), ['pane-a', 'pane-c']);

  // Test closePane with (state, id) overload
  const emptyAfterCloseA = closePane(tree, 'pane-a');
  assert.equal(emptyAfterCloseA, false);
  assert.deepEqual(getContentPaneIds(tree), ['pane-c']);
  assert.equal(tree.rootPaneId, 'pane-c');

  // Closing the last pane returns true
  const emptyAfterCloseC = closePaneInTree(tree, 'pane-c');
  assert.equal(emptyAfterCloseC, true);
});

test('M1 Tiling Engine: calculatePaneLayouts and toStructureOnly', () => {
  const tree = createPaneTreeState({ count: 1 }, 'pane-1');
  const { parentId: hSplitId } = splitPaneInTree(
    tree,
    'pane-1',
    'right',
    { count: 2 },
    'pane-2',
  );
  resizeSplitInTree(tree, hSplitId, 40);
  splitPaneInTree(tree, 'pane-2', 'bottom', { count: 3 }, 'pane-3');

  const structure = toStructureOnly(tree);
  assert.equal(
    (structure.panes['pane-1'] as any).value,
    undefined,
    'toStructureOnly strips leaf values',
  );

  const { contentLayouts, splitterLayouts } = calculatePaneLayouts(structure);
  assert.equal(contentLayouts.length, 3);
  assert.equal(splitterLayouts.length, 2);

  const l1 = contentLayouts.find((l) => l.paneId === 'pane-1')!;
  const l2 = contentLayouts.find((l) => l.paneId === 'pane-2')!;
  const l3 = contentLayouts.find((l) => l.paneId === 'pane-3')!;

  assert.equal(l1.left, 0);
  assert.equal(l1.top, 0);
  assert.equal(l1.width, 40);
  assert.equal(l1.height, 100);
  assert.equal(l1.isRightmostOfRow, false);
  assert.equal(l1.isBottommostOfColumn, true);

  assert.equal(l2.left, 40);
  assert.equal(l2.top, 0);
  assert.equal(l2.width, 60);
  assert.equal(l2.height, 50);
  assert.equal(l2.isRightmostOfRow, true);
  assert.equal(l2.isBottommostOfColumn, false);

  assert.equal(l3.left, 40);
  assert.equal(l3.top, 50);
  assert.equal(l3.width, 60);
  assert.equal(l3.height, 50);
  assert.equal(l3.isRightmostOfRow, true);
  assert.equal(l3.isBottommostOfColumn, true);
});

test('M1 Tiling Engine: dragUtils getSplitDirection, getOverlayPosition, and resolvePaneTarget', () => {
  const rect = { left: 100, top: 200, width: 400, height: 200 };

  assert.equal(getSplitDirection(rect, { x: 120, y: 300 }), 'left');
  assert.equal(getSplitDirection(rect, { x: 480, y: 300 }), 'right');
  assert.equal(getSplitDirection(rect, { x: 300, y: 210 }), 'top');
  assert.equal(getSplitDirection(rect, { x: 300, y: 390 }), 'bottom');

  assert.deepEqual(getOverlayPosition(rect, 'top'), {
    top: 0,
    left: 0,
    width: 400,
    height: 100,
  });
  assert.deepEqual(getOverlayPosition(rect, 'bottom'), {
    top: 100,
    left: 0,
    width: 400,
    height: 100,
  });
  assert.deepEqual(getOverlayPosition(rect, 'left'), {
    top: 0,
    left: 0,
    width: 200,
    height: 200,
  });
  assert.deepEqual(getOverlayPosition(rect, 'right'), {
    top: 0,
    left: 200,
    width: 200,
    height: 200,
  });
});

test('M1 TilingContainer DOM: preserves leaf mount identity across splits/moves/maximize and guards iframe pointerEvents on sash drag', async () => {
  const dom = new JSDOM('<!DOCTYPE html><html><body><div id="root"></div></body></html>');
  const prevWindow = (globalThis as any).window;
  const prevDocument = (globalThis as any).document;
  const prevHTMLElement = (globalThis as any).HTMLElement;
  (globalThis as any).window = dom.window;
  (globalThis as any).document = dom.window.document;
  (globalThis as any).HTMLElement = dom.window.HTMLElement;
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;

  try {
    const container = dom.window.document.getElementById('root')!;
    const root = createRoot(container);

    const mountCounts: Record<string, number> = {};
    const unmountCounts: Record<string, number> = {};

    function LeafProbe({ paneId, label }: { paneId: string; label: string }) {
      React.useEffect(() => {
        mountCounts[paneId] = (mountCounts[paneId] || 0) + 1;
        return () => {
          unmountCounts[paneId] = (unmountCounts[paneId] || 0) + 1;
        };
      }, [paneId]);
      return React.createElement(
        'div',
        { 'data-testid': `leaf-${paneId}` },
        label,
        paneId === 'pane-1' ? React.createElement('iframe', { id: 'preview-frame' }) : null,
      );
    }

    let tree = createPaneTreeState({ label: 'One' }, 'pane-1');

    await act(async () => {
      root.render(
        React.createElement(TilingContainer, {
          treeState: tree,
          renderPane: ({ paneId, value }: any) =>
            React.createElement(LeafProbe, { paneId, label: value.label }),
        }),
      );
    });

    assert.equal(mountCounts['pane-1'], 1);
    assert.equal(unmountCounts['pane-1'] || 0, 0);

    // Split pane-1 -> pane-1 MUST NOT unmount
    tree = structuredClone(tree);
    splitPaneInTree(tree, 'pane-1', 'right', { label: 'Two' }, 'pane-2');

    await act(async () => {
      root.render(
        React.createElement(TilingContainer, {
          treeState: tree,
          renderPane: ({ paneId, value }: any) =>
            React.createElement(LeafProbe, { paneId, label: value.label }),
        }),
      );
    });

    assert.equal(mountCounts['pane-1'], 1, 'pane-1 must not remount when split');
    assert.equal(unmountCounts['pane-1'] || 0, 0, 'pane-1 must not unmount when split');
    assert.equal(mountCounts['pane-2'], 1);

    // Maximize pane-2 -> pane-1 MUST stay mounted in DOM with visibility: hidden
    tree = structuredClone(tree);
    toggleMaximizePaneInTree(tree, 'pane-2');

    await act(async () => {
      root.render(
        React.createElement(TilingContainer, {
          treeState: tree,
          renderPane: ({ paneId, value }: any) =>
            React.createElement(LeafProbe, { paneId, label: value.label }),
        }),
      );
    });

    const pane1El = container.querySelector('[data-pane-id="pane-1"]') as HTMLElement;
    const pane2El = container.querySelector('[data-pane-id="pane-2"]') as HTMLElement;
    assert.ok(pane1El, 'Non-maximized pane-1 remains in DOM');
    assert.equal(pane1El.style.visibility, 'hidden');
    assert.equal(pane1El.style.pointerEvents, 'none');
    assert.equal(pane2El.getAttribute('data-pane-maximized'), 'true');
    assert.equal(pane2El.style.width, '100%');
    assert.equal(pane2El.style.height, '100%');
    assert.equal(unmountCounts['pane-1'] || 0, 0, 'pane-1 never unmounted during maximize');

    // Restore from maximize and test sash drag iframe pointerEvents guard
    tree = structuredClone(tree);
    toggleMaximizePaneInTree(tree, 'pane-2');
    await act(async () => {
      root.render(
        React.createElement(TilingContainer, {
          treeState: tree,
          renderPane: ({ paneId, value }: any) =>
            React.createElement(LeafProbe, { paneId, label: value.label }),
        }),
      );
    });

    const splitterEl = container.querySelector('[data-splitter-id]') as HTMLElement;
    const iframeEl = container.querySelector('#preview-frame') as HTMLElement;
    assert.ok(splitterEl, 'Splitter sash rendered');
    assert.ok(iframeEl, 'Preview iframe rendered');

    await act(async () => {
      splitterEl.dispatchEvent(
        new dom.window.MouseEvent('mousedown', { bubbles: true, cancelable: true }),
      );
    });
    assert.equal(
      iframeEl.style.pointerEvents,
      'none',
      'Iframe pointerEvents disabled during sash drag',
    );

    await act(async () => {
      dom.window.dispatchEvent(new dom.window.MouseEvent('mouseup', { bubbles: true }));
    });
    assert.equal(
      iframeEl.style.pointerEvents,
      '',
      'Iframe pointerEvents restored on mouseup',
    );

    await act(async () => {
      root.unmount();
    });
  } finally {
    (globalThis as any).window = prevWindow;
    (globalThis as any).document = prevDocument;
    (globalThis as any).HTMLElement = prevHTMLElement;
  }
});

test('M1 Level 1 Store: windowLayoutSlice actions, deduplication, ID-preserving move, and selectors', () => {
  let state = windowLayoutReducer(undefined, { type: '@@init' });
  const initialPaneId = selectFocusedWindowPaneId(state);
  assert.equal(selectFocusedWindowPane(state)?.kind, 'new');
  assert.equal(selectFocusedWindowPane(state)?.agentInstanceId, NEW_WINDOW_PANE_ID);

  // Sync route conversation into initial pane
  state = windowLayoutReducer(
    state,
    syncRouteConversationToWindowLayout({
      agentInstanceId: 'inst-coord-1',
      chainId: 'chain-1',
      title: 'Coordinator 1',
    }),
  );
  assert.equal(selectFocusedWindowPane(state)?.kind, 'conversation');
  assert.equal(selectFocusedWindowPane(state)?.agentInstanceId, 'inst-coord-1');
  assert.deepEqual(selectOpenWindowConversationIds(state), ['inst-coord-1']);

  // Split window pane -> creates new pane with kind: 'new'
  state = windowLayoutReducer(
    state,
    splitWindowPane({
      direction: 'right',
      newPaneId: 'window-pane-2',
    }),
  );
  assert.equal(selectFocusedWindowPaneId(state), 'window-pane-2');
  assert.equal(selectFocusedWindowPane(state)?.kind, 'new');
  assert.equal(selectFocusedWindowPane(state)?.agentInstanceId, NEW_WINDOW_PANE_ID);

  // Assign conversation to second window pane
  state = windowLayoutReducer(
    state,
    assignWindowPaneConversation({
      paneId: 'window-pane-2',
      agentInstanceId: 'inst-worker-2',
      chainId: 'chain-1',
    }),
  );
  assert.deepEqual(selectOpenWindowConversationIds(state), [
    'inst-coord-1',
    'inst-worker-2',
  ]);

  // Splitting with an already-open conversation focuses the existing pane instead of duplicating
  state = windowLayoutReducer(
    state,
    splitWindowPane({
      direction: 'bottom',
      agentInstanceId: 'inst-coord-1',
    }),
  );
  assert.equal(selectFocusedWindowPaneId(state), initialPaneId);
  assert.equal(getContentPaneIds(selectWindowLayoutTree(state)).length, 2);

  // Move window pane preserves both pane IDs
  state = windowLayoutReducer(
    state,
    moveWindowPane({
      sourcePaneId: 'window-pane-2',
      targetPaneId: initialPaneId,
      direction: 'top',
    }),
  );
  assert.deepEqual(getContentPaneIds(selectWindowLayoutTree(state)), [
    'window-pane-2',
    initialPaneId,
  ]);

  // Swap, resize, equalize, maximize, pending drop target
  state = windowLayoutReducer(
    state,
    swapWindowPanes({ paneIdA: 'window-pane-2', paneIdB: initialPaneId }),
  );
  assert.deepEqual(getContentPaneIds(selectWindowLayoutTree(state)), [
    initialPaneId,
    'window-pane-2',
  ]);

  const splitId = selectWindowLayoutTree(state).rootPaneId;
  state = windowLayoutReducer(
    state,
    resizeWindowSplit({ splitPaneId: splitId, ratio: 70 }),
  );
  assert.equal((selectWindowLayoutTree(state).panes[splitId] as any).ratio, 70);

  state = windowLayoutReducer(state, equalizeWindowPanes());
  assert.equal((selectWindowLayoutTree(state).panes[splitId] as any).ratio, 50);

  state = windowLayoutReducer(state, toggleMaximizeWindowPane('window-pane-2'));
  assert.equal(selectWindowMaximizedPaneId(state), 'window-pane-2');

  state = windowLayoutReducer(
    state,
    setWindowPendingDropTarget({ paneId: initialPaneId, direction: 'left' }),
  );
  assert.deepEqual(selectWindowPendingDropTarget(state), {
    paneId: initialPaneId,
    direction: 'left',
  });

  // Close window-pane-2 -> clears maximize and focuses remaining pane
  state = windowLayoutReducer(state, closeWindowPane('window-pane-2'));
  assert.equal(selectWindowMaximizedPaneId(state), null);
  assert.equal(selectFocusedWindowPaneId(state), initialPaneId);

  // Hydrate & reset
  const snapshot = selectWindowLayoutTree(state);
  state = windowLayoutReducer(state, resetWindowLayout());
  assert.equal(selectFocusedWindowPane(state)?.kind, 'new');
  state = windowLayoutReducer(state, hydrateWindowLayout(snapshot));
  assert.equal(selectFocusedWindowPane(state)?.agentInstanceId, 'inst-coord-1');
});

test('M1 Level 2 Tab Codec & Store: workbenchTabId and workbenchSlice full lifecycle', () => {
  assert.equal(NEW_TAB_ID, 'newTab__empty');
  assert.equal(WORKBENCH_SURFACE_KINDS.length, 8);
  for (const kind of WORKBENCH_SURFACE_KINDS) {
    assert.ok(WORKBENCH_SURFACE_REGISTRY[kind], `Registry entry for ${kind}`);
  }

  // Verify canonical ID codec for all 8 surface kinds
  assert.equal(
    buildWorkbenchTabId({ kind: 'agentChat', agentInstanceId: 'inst-1' }),
    'agentChat__inst-1',
  );
  assert.equal(
    buildWorkbenchTabId({ kind: 'agentPty', agentInstanceId: 'inst-1' }),
    'agentPty__inst-1',
  );
  assert.equal(
    buildWorkbenchTabId({ kind: 'shell', sessionId: 'sess-9' }),
    'shell__sess-9',
  );
  assert.equal(
    buildWorkbenchTabId({ kind: 'preview', sessionId: 'srv-1' }),
    'preview__srv-1',
  );
  assert.equal(buildWorkbenchTabId({ kind: 'files' }), 'files');
  assert.equal(buildWorkbenchTabId({ kind: 'vcs' }), 'vcs');
  assert.equal(buildWorkbenchTabId({ kind: 'chainOverview' }), 'chainOverview');
  assert.equal(buildWorkbenchTabId({ kind: 'tasks' }), 'tasks');

  assert.deepEqual(parseWorkbenchTabId('agentChat__inst-1'), {
    kind: 'agentChat',
    targetId: 'inst-1',
    agentInstanceId: 'inst-1',
  });
  assert.deepEqual(parseWorkbenchTabId('agentPty__inst-2'), {
    kind: 'agentPty',
    targetId: 'inst-2',
    agentInstanceId: 'inst-2',
  });
  assert.deepEqual(parseWorkbenchTabId('shell__sess-9'), {
    kind: 'shell',
    targetId: 'sess-9',
    sessionId: 'sess-9',
  });
  assert.deepEqual(parseWorkbenchTabId('preview__srv-1'), {
    kind: 'preview',
    targetId: 'srv-1',
    sessionId: 'srv-1',
  });
  assert.deepEqual(parseWorkbenchTabId('files'), {
    kind: 'files',
    targetId: undefined,
  });
  assert.equal(parseWorkbenchTabId(NEW_TAB_ID), null);

  assert.equal(resolveLegacyPanelToSurfaceKind('rundir'), 'files');
  assert.equal(resolveLegacyPanelToSurfaceKind('chain'), 'chainOverview');
  assert.equal(resolveLegacyPanelToSurfaceKind('vcs'), 'vcs');
  assert.equal(resolveLegacyPanelToSurfaceKind('tasks'), 'tasks');
  assert.equal(resolveLegacyPanelToSurfaceKind('shells'), 'shell');

  // Workbench slice lifecycle
  const wsKey = 'chain:chain-alpha';
  let state = workbenchReducer(
    undefined,
    ensureWorkspaceInitialized({
      workspaceKey: wsKey,
      defaultAgentInstanceId: 'coord-1',
      defaultTitle: 'Coordinator',
    }),
  );

  const initialPane = selectFocusedWorkbenchPane(state, wsKey)!;
  assert.equal(initialPane.tabs.length, 1);
  assert.equal(initialPane.tabs[0].id, 'agentChat__coord-1');
  assert.equal(initialPane.activeTabId, 'agentChat__coord-1');

  // Clicking '+' (openNewTabView) sets activeTabId = NEW_TAB_ID while preserving existing tabs
  state = workbenchReducer(
    state,
    openNewTabView({ workspaceKey: wsKey, paneId: 'pane-1' }),
  );
  assert.equal(selectFocusedWorkbenchPane(state, wsKey)?.activeTabId, NEW_TAB_ID);
  assert.equal(selectFocusedWorkbenchPane(state, wsKey)?.tabs.length, 1);

  // Selecting a second agentChat in the launcher replaces NEW_TAB_ID as activeTabId in-place
  state = workbenchReducer(
    state,
    openOrFocusWorkbenchTab({
      workspaceKey: wsKey,
      paneId: 'pane-1',
      tab: {
        kind: 'agentChat',
        agentInstanceId: 'worker-1',
        title: 'Worker 1 Chat',
      },
    }),
  );
  assert.equal(
    selectFocusedWorkbenchPane(state, wsKey)?.activeTabId,
    'agentChat__worker-1',
  );
  assert.equal(selectFocusedWorkbenchPane(state, wsKey)?.tabs.length, 2);

  // Splitting a Level 2 pane creates a new pane with { tabs: [], activeTabId: NEW_TAB_ID }
  state = workbenchReducer(
    state,
    splitWorkbenchPane({
      workspaceKey: wsKey,
      targetPaneId: 'pane-1',
      direction: 'right',
      newPaneId: 'pane-2',
    }),
  );
  assert.equal(selectFocusedWorkbenchPaneId(state, wsKey), 'pane-2');
  assert.deepEqual(selectFocusedWorkbenchPane(state, wsKey), {
    tabs: [],
    activeTabId: NEW_TAB_ID,
  });

  // Replace NEW_TAB_ID in pane-2 with agentPty
  state = workbenchReducer(
    state,
    replaceNewTabWithSurface({
      workspaceKey: wsKey,
      paneId: 'pane-2',
      tab: {
        kind: 'agentPty',
        agentInstanceId: 'worker-1',
        title: 'Worker 1 PTY',
      },
    }),
  );
  assert.equal(
    selectFocusedWorkbenchPane(state, wsKey)?.activeTabId,
    'agentPty__worker-1',
  );

  // Open a second agentPty in pane-2 to verify multiple simultaneous agentPty tabs
  state = workbenchReducer(
    state,
    openOrFocusWorkbenchTab({
      workspaceKey: wsKey,
      paneId: 'pane-2',
      tab: {
        kind: 'agentPty',
        agentInstanceId: 'coord-1',
        title: 'Coordinator PTY',
      },
    }),
  );
  assert.equal(selectFocusedWorkbenchPane(state, wsKey)?.tabs.length, 2);

  // Reorder tabs in pane-2
  state = workbenchReducer(
    state,
    reorderWorkbenchTabs({
      workspaceKey: wsKey,
      paneId: 'pane-2',
      orderedTabIds: ['agentPty__coord-1', 'agentPty__worker-1'],
    }),
  );
  assert.deepEqual(
    selectFocusedWorkbenchPane(state, wsKey)?.tabs.map((t) => t.id),
    ['agentPty__coord-1', 'agentPty__worker-1'],
  );

  // Move tab from pane-1 to pane-2
  state = workbenchReducer(
    state,
    moveWorkbenchTabToPane({
      workspaceKey: wsKey,
      sourcePaneId: 'pane-1',
      targetPaneId: 'pane-2',
      tabId: 'agentChat__worker-1',
      targetIndex: 1,
    }),
  );
  const treeAfterMoveTab = selectWorkspaceWorkbenchTree(state, wsKey)!;
  assert.deepEqual(
    (treeAfterMoveTab.panes['pane-1'] as any).value.tabs.map((t: any) => t.id),
    ['agentChat__coord-1'],
  );
  assert.deepEqual(
    (treeAfterMoveTab.panes['pane-2'] as any).value.tabs.map((t: any) => t.id),
    ['agentPty__coord-1', 'agentChat__worker-1', 'agentPty__worker-1'],
  );

  // Split pane with dragged tab (splitWorkbenchPaneWithTab)
  state = workbenchReducer(
    state,
    splitWorkbenchPaneWithTab({
      workspaceKey: wsKey,
      sourcePaneId: 'pane-2',
      targetPaneId: 'pane-2',
      tabId: 'agentPty__worker-1',
      direction: 'bottom',
    }),
  );
  assert.equal(
    getContentPaneIds(selectWorkspaceWorkbenchTree(state, wsKey)!).length,
    3,
  );

  // openPreviewInWorkbench opens preview tab and normalizes leading slash on currentPath
  state = workbenchReducer(
    state,
    openPreviewInWorkbench({
      workspaceKey: wsKey,
      paneId: 'pane-2',
      sessionId: 'srv-3000',
      label: 'Vite Dev Server',
      port: 5173,
      currentPath: '/dashboard/index.html',
    }),
  );
  const allTabs = selectAllWorkspaceTabs(state, wsKey);
  const previewTab = allTabs.find((t) => t.id === 'preview__srv-3000')!;
  assert.ok(previewTab);
  assert.equal(previewTab.port, 5173);
  assert.equal(previewTab.currentPath, 'dashboard/index.html');

  // updateWorkbenchTabParams updates currentPath
  state = workbenchReducer(
    state,
    updateWorkbenchTabParams({
      workspaceKey: wsKey,
      tabId: 'preview__srv-3000',
      patch: { currentPath: '/settings' },
    }),
  );
  assert.equal(
    selectAllWorkspaceTabs(state, wsKey).find((t) => t.id === 'preview__srv-3000')
      ?.currentPath,
    'settings',
  );
});

test('shell session binding rekeys the provisional tab so another new shell can coexist', () => {
  const workspaceKey = 'chain:shell-rekey';
  let state = workbenchReducer(
    undefined,
    ensureWorkspaceInitialized({
      workspaceKey,
      defaultAgentInstanceId: 'coord-1',
      defaultTitle: 'Coordinator',
    }),
  );

  state = workbenchReducer(
    state,
    openOrFocusWorkbenchTab({
      workspaceKey,
      paneId: 'pane-1',
      tab: { kind: 'shell', sessionId: 'new', title: 'Shell' },
    }),
  );
  assert.equal(selectFocusedWorkbenchPane(state, workspaceKey)?.activeTabId, 'shell__new');

  state = workbenchReducer(
    state,
    replaceWorkbenchTab({
      workspaceKey,
      paneId: 'pane-1',
      tabId: 'shell__new',
      tab: { kind: 'shell', sessionId: 'srv-running', title: 'Shell' },
    }),
  );
  assert.equal(
    selectFocusedWorkbenchPane(state, workspaceKey)?.activeTabId,
    'shell__srv-running',
  );
  assert.equal(
    selectAllWorkspaceTabs(state, workspaceKey).some((tab) => tab.id === 'shell__new'),
    false,
  );

  state = workbenchReducer(
    state,
    openNewTabView({ workspaceKey, paneId: 'pane-1' }),
  );
  state = workbenchReducer(
    state,
    replaceNewTabWithSurface({
      workspaceKey,
      paneId: 'pane-1',
      tab: { kind: 'shell', sessionId: 'new', title: 'Shell' },
    }),
  );

  const shellTabIds = selectAllWorkspaceTabs(state, workspaceKey)
    .filter((tab) => tab.kind === 'shell')
    .map((tab) => tab.id);
  assert.deepEqual(shellTabIds, ['shell__srv-running', 'shell__new']);
  assert.equal(selectFocusedWorkbenchPane(state, workspaceKey)?.activeTabId, 'shell__new');
});

test('M1 Persistence Helpers: windowLayout, workbenchWorkspace, and per-instance composer drafts', () => {
  const storage = new Map<string, string>();
  const prevWindow = (globalThis as any).window;
  (globalThis as any).window = {
    localStorage: {
      getItem: (k: string) => (storage.has(k) ? storage.get(k)! : null),
      setItem: (k: string, v: string) => storage.set(k, v),
      removeItem: (k: string) => storage.delete(k),
    },
  };

  try {
    assert.equal(
      resolveWorkbenchWorkspaceKey({ chainId: 'c-1', agentInstanceId: 'a-1' }),
      'chain:c-1',
    );
    assert.equal(
      resolveWorkbenchWorkspaceKey({ chainId: null, agentInstanceId: 'a-1' }),
      'agent:a-1',
    );

    const winTree = createPaneTreeState(
      { kind: 'conversation', agentInstanceId: 'a-1' },
      'window-pane-1',
    );
    writeWindowLayoutState(winTree);
    const loadedWinTree = readWindowLayoutState();
    assert.deepEqual(loadedWinTree, winTree);

    const wbTree = createPaneTreeState(
      {
        tabs: [createWorkbenchTabState({ kind: 'files' })],
        activeTabId: 'files',
      },
      'pane-1',
    );
    writeWorkbenchWorkspaceState('chain:c-1', wbTree);
    const loadedWbTree = readWorkbenchWorkspaceState('chain:c-1');
    assert.deepEqual(loadedWbTree, wbTree);

    assert.equal(getComposerDraftKey('inst-42'), 'heimdall:composer:draft:inst-42');
    writeComposerDraft('inst-42', 'hello coordinator');
    writeComposerDraft('inst-99', 'hello worker');
    assert.equal(readComposerDraft('inst-42'), 'hello coordinator');
    assert.equal(readComposerDraft('inst-99'), 'hello worker');
    writeComposerDraft('inst-42', '');
    assert.equal(readComposerDraft('inst-42'), '');
  } finally {
    (globalThis as any).window = prevWindow;
  }
});

test('M1 Regression Suite: auto-collapse empty source split panes, hydrate sanitization, split-node close guards, and paneAttributeName', async () => {
  // 1. moveWorkbenchTabToPane auto-collapses empty split pane
  let wb = workbenchReducer(
    undefined,
    ensureWorkspaceInitialized({
      workspaceKey: 'ws1',
      defaultAgentInstanceId: 'inst-1',
    }),
  );
  const p1 = wb.workspaces['ws1'].tree.rootPaneId;
  wb = workbenchReducer(
    wb,
    openOrFocusWorkbenchTab({
      workspaceKey: 'ws1',
      paneId: p1,
      tab: { kind: 'files', title: 'Files' },
    }),
  );
  wb = workbenchReducer(
    wb,
    splitWorkbenchPaneWithTab({
      workspaceKey: 'ws1',
      sourcePaneId: p1,
      targetPaneId: p1,
      tabId: 'files',
      direction: 'right',
    }),
  );
  const p2 = getContentPaneIds(wb.workspaces['ws1'].tree).find(
    (id) => id !== p1,
  )!;
  wb = workbenchReducer(
    wb,
    moveWorkbenchTabToPane({
      workspaceKey: 'ws1',
      sourcePaneId: p2,
      targetPaneId: p1,
      tabId: 'files',
    }),
  );
  assert.deepEqual(
    getContentPaneIds(wb.workspaces['ws1'].tree),
    [p1],
    'Empty source split pane p2 should auto-collapse',
  );
  assert.equal(wb.workspaces['ws1'].tree.focusedPaneId, p1);

  // 2. splitWorkbenchPaneWithTab auto-collapses empty source split pane
  let wb2 = workbenchReducer(
    undefined,
    ensureWorkspaceInitialized({
      workspaceKey: 'ws2',
      defaultAgentInstanceId: 'inst-1',
    }),
  );
  const p2_1 = wb2.workspaces['ws2'].tree.rootPaneId;
  wb2 = workbenchReducer(
    wb2,
    openOrFocusWorkbenchTab({
      workspaceKey: 'ws2',
      paneId: p2_1,
      tab: { kind: 'files', title: 'Files' },
      splitDirection: 'right',
    }),
  );
  const p2_2 = wb2.workspaces['ws2'].tree.focusedPaneId;
  wb2 = workbenchReducer(
    wb2,
    splitWorkbenchPaneWithTab({
      workspaceKey: 'ws2',
      sourcePaneId: p2_2,
      targetPaneId: p2_1,
      tabId: 'files',
      direction: 'bottom',
    }),
  );
  assert.equal(
    getContentPaneIds(wb2.workspaces['ws2'].tree).length,
    2,
    'Empty source pane p2_2 should auto-collapse after splitting target pane',
  );

  // 3. hydrateWindowLayout rejects/sanitizes broken split & null content value & prunes unreachable nodes
  let win = windowLayoutReducer(
    undefined,
    syncRouteConversationToWindowLayout({ agentInstanceId: 'inst-1' }),
  );
  const corruptedWinTree: any = {
    rootPaneId: 'split-1',
    focusedPaneId: 'pane-orphan',
    panes: {
      'split-1': {
        kind: 'split',
        axis: 'horizontal',
        leftChildId: 'missing-L',
        rightChildId: 'missing-R',
        ratio: -500,
      },
      'pane-orphan': { kind: 'content', value: null },
    },
  };
  win = windowLayoutReducer(win, hydrateWindowLayout(corruptedWinTree));
  assert.ok(calculatePaneLayouts(win.tree).contentLayouts.length > 0);
  assert.doesNotThrow(() => selectOpenWindowConversationIds(win));

  // Verify hydrateWindowLayout sanitizes null content value and clamps ratio on reachable nodes while pruning orphans
  const sanitizableWinTree: any = {
    rootPaneId: 'split-root',
    focusedPaneId: 'pane-orphan',
    panes: {
      'split-root': {
        kind: 'split',
        axis: 'invalid-axis',
        leftChildId: 'win-1',
        rightChildId: 'win-2',
        ratio: -250,
      },
      'win-1': { kind: 'content', value: null },
      'win-2': {
        kind: 'content',
        value: { kind: 'conversation', agentInstanceId: '  inst-clean  ' },
      },
      'pane-orphan': {
        kind: 'content',
        value: { kind: 'conversation', agentInstanceId: 'inst-orphan' },
      },
    },
  };
  const winSanitized = windowLayoutReducer(
    win,
    hydrateWindowLayout(sanitizableWinTree),
  );
  assert.equal((winSanitized.tree.panes['split-root'] as any).ratio, 5);
  assert.equal((winSanitized.tree.panes['split-root'] as any).axis, 'horizontal');
  assert.equal(winSanitized.tree.panes['pane-orphan'], undefined);
  assert.deepEqual(selectOpenWindowConversationIds(winSanitized), ['inst-clean']);

  // 4. hydrateWorkspaceWorkbench handles non-string tab fields, invalid kind, and broken root split without crashing
  assert.doesNotThrow(() => {
    const wbCorrupt = workbenchReducer(
      undefined,
      hydrateWorkspaceWorkbench({
        workspaceKey: 'ws-corrupt',
        tree: {
          rootPaneId: 'p1',
          focusedPaneId: 'p1',
          panes: {
            p1: {
              kind: 'content',
              value: {
                tabs: [
                  { id: 123 as any, kind: 'InvalidKind' as any, title: 456 as any },
                  {
                    kind: 'agentChat',
                    agentInstanceId: 789 as any,
                    title: null as any,
                  },
                ],
                activeTabId: '123',
              },
            },
          },
        },
      }),
    );
    const tabs = selectAllWorkspaceTabs(wbCorrupt, 'ws-corrupt');
    assert.equal(tabs.length, 1);
    assert.equal(tabs[0].kind, 'agentChat');
  });

  // 5. closeWindowPane, closeWorkbenchPane, and closePaneInTree ignore split node IDs
  let winSplit = windowLayoutReducer(
    undefined,
    syncRouteConversationToWindowLayout({ agentInstanceId: 'inst-1' }),
  );
  winSplit = windowLayoutReducer(
    winSplit,
    splitWindowPane({ direction: 'right', agentInstanceId: 'inst-2' }),
  );
  const rootSplitId = winSplit.tree.rootPaneId;
  winSplit = windowLayoutReducer(winSplit, closeWindowPane(rootSplitId));
  assert.equal(
    getContentPaneIds(winSplit.tree).length,
    2,
    'closeWindowPane must ignore split node IDs',
  );

  const wbRootSplitId = wb2.workspaces['ws2'].tree.rootPaneId;
  wb2 = workbenchReducer(
    wb2,
    closeWorkbenchPane({ workspaceKey: 'ws2', paneId: wbRootSplitId }),
  );
  assert.equal(
    getContentPaneIds(wb2.workspaces['ws2'].tree).length,
    2,
    'closeWorkbenchPane must ignore split node IDs',
  );

  // 6. readWindowLayoutState & readWorkbenchWorkspaceState reject array/empty panes
  const storage = new Map<string, string>();
  const prevWindow = (globalThis as any).window;
  (globalThis as any).window = {
    localStorage: {
      getItem: (k: string) => storage.get(k) ?? null,
      setItem: (k: string, v: string) => storage.set(k, v),
      removeItem: (k: string) => storage.delete(k),
    },
  };
  try {
    storage.set(
      'heimdall:window-layout:v1',
      JSON.stringify({ rootPaneId: 'p1', panes: [] }),
    );
    assert.equal(readWindowLayoutState(), null);
    storage.set(
      'heimdall:workbench-layout:v1:ws1',
      JSON.stringify({ rootPaneId: 'p1', panes: {} }),
    );
    assert.equal(readWorkbenchWorkspaceState('ws1'), null);
  } finally {
    (globalThis as any).window = prevWindow;
  }

  // 7. TilingContainer honors paneAttributeName alongside data-pane-id
  const dom = new JSDOM('<!DOCTYPE html><html><body><div id="root"></div></body></html>');
  const prevWin = (globalThis as any).window;
  const prevDoc = (globalThis as any).document;
  const prevElem = (globalThis as any).HTMLElement;
  (globalThis as any).window = dom.window;
  (globalThis as any).document = dom.window.document;
  (globalThis as any).HTMLElement = dom.window.HTMLElement;
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  try {
    const container = dom.window.document.getElementById('root')!;
    const root = createRoot(container);
    const tree = createPaneTreeState({ label: 'Win' }, 'window-pane-1');
    await act(async () => {
      root.render(
        React.createElement(TilingContainer, {
          treeState: tree,
          paneAttributeName: 'data-window-pane-id',
          renderPane: ({ paneId }: any) => React.createElement('span', null, paneId),
        }),
      );
    });
    const el = container.querySelector('[data-window-pane-id="window-pane-1"]');
    assert.ok(el, 'Custom paneAttributeName rendered on leaf wrapper');
    assert.equal(el?.getAttribute('data-pane-id'), 'window-pane-1');
    await act(async () => {
      root.unmount();
    });
  } finally {
    (globalThis as any).window = prevWin;
    (globalThis as any).document = prevDoc;
    (globalThis as any).HTMLElement = prevElem;
  }
});

test('M2 Regression Suite: WorkbenchPaneView renders NEW_TAB_ID launcher and New Tab pill after openNewTabView and splitWorkbenchPane while keeping existing tabs mounted with hidden', async () => {
  await import('./helpers/vaultEndpointHarness.ts');
  const { renderToStaticMarkup } = await import('react-dom/server');
  const { Provider } = await import('react-redux');
  const { makeVaultStore } = await import('./helpers/vaultEndpointHarness.ts');
  const { WorkbenchPaneView } = await import(
    '../src/ui/components/workbench/WorkbenchPaneView.tsx'
  );

  const store = await makeVaultStore();
  let wbState = workbenchReducer(
    undefined,
    ensureWorkspaceInitialized({
      workspaceKey: 'ws-test',
      defaultAgentInstanceId: 'inst-1',
      defaultTitle: 'Coord',
    }),
  );
  wbState = workbenchReducer(
    wbState,
    openNewTabView({ workspaceKey: 'ws-test', paneId: 'pane-1' }),
  );
  const pane1 = wbState.workspaces['ws-test'].tree.panes['pane-1'];

  const html1 = renderToStaticMarkup(
    React.createElement(
      Provider,
      { store },
      React.createElement(WorkbenchPaneView, {
        paneId: 'pane-1',
        pane: (pane1 as any).value,
        workspaceKey: 'ws-test',
        primaryAgentInstanceId: 'inst-1',
        isFocused: true,
        isMaximized: false,
        isSinglePane: true,
        onFocusPane: () => {},
        onSelectTab: () => {},
        onCloseTab: () => {},
        onOpenNewTab: () => {},
        onReplaceNewTab: () => {},
        onOpenOrFocusTab: () => {},
        onUpdateTabParams: () => {},
        onSplitPane: () => {},
        onToggleMaximize: () => {},
        onClosePane: () => {},
      }),
    ),
  );
  assert.ok(
    html1.includes('workbench-new-tab-launcher-pane-1'),
    'Launcher must render when activeTabId === NEW_TAB_ID after openNewTabView',
  );
  assert.ok(
    html1.includes('workbench-tab-newTab__empty'),
    'Tab strip must render New Tab pill when activeTabId === NEW_TAB_ID',
  );
  assert.ok(
    html1.includes('workbench-tab-close-newTab__empty'),
    'Tab strip must render close button on New Tab pill when tabs.length > 0',
  );
  assert.ok(
    html1.includes('data-debug-id="workbench-tab-panel-agentChat__inst-1" aria-hidden="true" class="hidden"'),
    'Existing mounted tab panel must remain in the DOM with class="hidden" while NEW_TAB_ID launcher is active',
  );

  wbState = workbenchReducer(
    wbState,
    splitWorkbenchPane({
      workspaceKey: 'ws-test',
      targetPaneId: 'pane-1',
      direction: 'right',
      newPaneId: 'pane-2',
    }),
  );
  const pane2 = wbState.workspaces['ws-test'].tree.panes['pane-2'];
  const html2 = renderToStaticMarkup(
    React.createElement(
      Provider,
      { store },
      React.createElement(WorkbenchPaneView, {
        paneId: 'pane-2',
        pane: (pane2 as any).value,
        workspaceKey: 'ws-test',
        primaryAgentInstanceId: 'inst-1',
        isFocused: true,
        isMaximized: false,
        isSinglePane: false,
        onFocusPane: () => {},
        onSelectTab: () => {},
        onCloseTab: () => {},
        onOpenNewTab: () => {},
        onReplaceNewTab: () => {},
        onOpenOrFocusTab: () => {},
        onUpdateTabParams: () => {},
        onSplitPane: () => {},
        onToggleMaximize: () => {},
        onClosePane: () => {},
      }),
    ),
  );
  assert.ok(
    html2.includes('workbench-new-tab-launcher-pane-2'),
    'Launcher must render in newly split empty pane',
  );
  assert.ok(
    html2.includes('workbench-tab-newTab__empty'),
    'Tab strip must render New Tab pill in newly split empty pane',
  );
});

