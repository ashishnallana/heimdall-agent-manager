import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { configureStore } from '@reduxjs/toolkit';

import { getContentPaneIds } from '../src/ui/tiling/index.ts';
import workspaceLayoutReducer, {
  NEW_PANE_AGENT_ID,
  assignMainPaneAgent,
  closeMainPane,
  createInitialMainTree,
  findPaneByAgent,
  moveMainPane,
  setLayoutFromUrl,
  buildDefaultSplitTree,
  resizeMainSplit,
  sanitizeMainTree,
  selectFocusedMainAgentId,
  selectMainAgentIds,
  selectMainPaneIds,
  setFocusedMainPane,
  splitMainPane,
  toggleMaximizeMainPane,
} from '../src/ui/store/workspaceLayoutSlice.ts';
import workspaceChromeReducer, {
  AUX_MAX_WIDTH,
  AUX_MIN_WIDTH,
  hydrateWorkspaceChrome,
  selectAuxWidth,
  setAuxWidth,
  toggleAuxMaximized,
} from '../src/ui/store/workspaceChromeSlice.ts';

function makeStore() {
  return configureStore({
    reducer: { workspaceLayout: workspaceLayoutReducer, workspaceChrome: workspaceChromeReducer },
  });
}

function tree(store: ReturnType<typeof makeStore>) {
  return store.getState().workspaceLayout.tree;
}

function agentOf(store: ReturnType<typeof makeStore>, paneId: string): string | undefined {
  const pane = tree(store).panes[paneId];
  return pane?.kind === 'content' ? pane.value.agentInstanceId : undefined;
}

test('workspace layout starts as ONE new-chat picker leaf', () => {
  const store = makeStore();
  const ids = selectMainPaneIds(store.getState());
  assert.deepEqual(ids, ['pane-1']);
  assert.equal(agentOf(store, 'pane-1'), NEW_PANE_AGENT_ID);
  assert.equal(selectFocusedMainAgentId(store.getState()), NEW_PANE_AGENT_ID);
  assert.deepEqual(selectMainAgentIds(store.getState()), []);
});

test('setLayoutFromUrl: same set -> focus only; one-id swap -> in place; 1 id -> single; N ids -> saved or default', () => {
  const store = makeStore();
  store.dispatch(setLayoutFromUrl({ ids: ['a'] }));
  assert.equal(agentOf(store, 'pane-1'), 'a');

  // N ids without saved geometry: nested horizontal default.
  store.dispatch(setLayoutFromUrl({ ids: ['a', 'b', 'c'], focusedId: 'b' }));
  assert.deepEqual(selectMainAgentIds(store.getState()), ['a', 'b', 'c']);
  assert.equal(selectFocusedMainAgentId(store.getState()), 'b');
  const root = tree(store).panes[tree(store).rootPaneId];
  assert.equal(root.kind === 'split' && root.axis, 'horizontal');
  assert.ok(root.kind === 'split' && Math.abs(root.ratio - 100 / 3) < 0.01);

  // Same set (any order) -> only focus changes, geometry untouched.
  const before = JSON.stringify(tree(store).panes);
  store.dispatch(setLayoutFromUrl({ ids: ['c', 'a', 'b'], focusedId: 'c' }));
  assert.equal(JSON.stringify(tree(store).panes), before);
  assert.equal(selectFocusedMainAgentId(store.getState()), 'c');

  // Exactly one id swapped -> replaced in place, pane ids/geometry preserved.
  const bPane = findPaneByAgent(tree(store), 'b')!;
  store.dispatch(setLayoutFromUrl({ ids: ['a', 'x', 'c'], focusedId: 'x' }));
  assert.equal(agentOf(store, bPane), 'x');
  assert.equal(tree(store).focusedPaneId, bPane);

  // Saved geometry for the exact set is restored.
  const saved = buildDefaultSplitTree(['p', 'q']);
  (saved.panes['split-1'] as any).axis = 'vertical';
  store.dispatch(setLayoutFromUrl({ ids: ['q', 'p'], focusedId: 'q', savedLayout: saved }));
  const restored = tree(store).panes[tree(store).rootPaneId];
  assert.equal(restored.kind === 'split' && restored.axis, 'vertical');
  assert.equal(selectFocusedMainAgentId(store.getState()), 'q');

  // Multiple '_new' placeholders are distinct panes.
  store.dispatch(setLayoutFromUrl({ ids: ['a', NEW_PANE_AGENT_ID, NEW_PANE_AGENT_ID] }));
  assert.equal(getContentPaneIds(tree(store)).length, 3);
  store.dispatch(setLayoutFromUrl({ ids: [] }));
  assert.equal(getContentPaneIds(tree(store)).length, 3, 'empty id list is ignored');
});

test('split in all 4 directions, focus, resize, maximize and move preserve pane ids', () => {
  const store = makeStore();
  store.dispatch(setLayoutFromUrl({ ids: ['a'] }));
  for (const direction of ['right', 'bottom', 'left', 'top'] as const) {
    store.dispatch(splitMainPane({ targetPaneId: 'pane-1', direction }));
  }
  const ids = getContentPaneIds(tree(store));
  assert.equal(ids.length, 5);
  assert.ok(ids.includes('pane-1'), 'the split source keeps its id');

  store.dispatch(setFocusedMainPane('pane-1'));
  assert.equal(tree(store).focusedPaneId, 'pane-1');
  store.dispatch(setFocusedMainPane('does-not-exist'));
  assert.equal(tree(store).focusedPaneId, 'pane-1');

  const splitId = Object.entries(tree(store).panes).find(([, p]) => p.kind === 'split')![0];
  store.dispatch(resizeMainSplit({ splitPaneId: splitId, ratio: 200 }));
  const split = tree(store).panes[splitId];
  assert.equal(split.kind === 'split' && split.ratio, 95);

  store.dispatch(toggleMaximizeMainPane('pane-1'));
  assert.equal(tree(store).maximizedPaneId, 'pane-1');
  store.dispatch(toggleMaximizeMainPane('pane-1'));
  assert.equal(tree(store).maximizedPaneId, null);

  const other = ids.find((id) => id !== 'pane-1')!;
  store.dispatch(moveMainPane({ sourcePaneId: other, targetPaneId: 'pane-1', direction: 'left' }));
  assert.deepEqual(new Set(getContentPaneIds(tree(store))), new Set(ids));
});

test('splitting WITH an agent that is already open focuses it instead of duplicating', () => {
  const store = makeStore();
  store.dispatch(setLayoutFromUrl({ ids: ['a'] }));
  store.dispatch(splitMainPane({ targetPaneId: 'pane-1', direction: 'right', agentInstanceId: 'b' }));
  const before = getContentPaneIds(tree(store));
  store.dispatch(setFocusedMainPane('pane-1'));
  store.dispatch(splitMainPane({ targetPaneId: 'pane-1', direction: 'down' as any, agentInstanceId: 'b' }));
  assert.deepEqual(getContentPaneIds(tree(store)), before);
  assert.equal(selectFocusedMainAgentId(store.getState()), 'b');
});

test('assignMainPaneAgent fills a picker; picking an already-open agent focuses it and drops the picker', () => {
  const store = makeStore();
  store.dispatch(setLayoutFromUrl({ ids: ['a'] }));
  store.dispatch(splitMainPane({ targetPaneId: 'pane-1', direction: 'right' }));
  const picker = getContentPaneIds(tree(store)).find((id) => id !== 'pane-1')!;

  store.dispatch(assignMainPaneAgent({ paneId: picker, agentInstanceId: 'b' }));
  assert.equal(agentOf(store, picker), 'b');
  assert.equal(tree(store).focusedPaneId, picker);

  // Agent switcher in pane-1 to 'b' (already open) -> focus b, pane-1 keeps 'a'.
  store.dispatch(assignMainPaneAgent({ paneId: 'pane-1', agentInstanceId: 'b' }));
  assert.equal(agentOf(store, 'pane-1'), 'a');
  assert.equal(tree(store).focusedPaneId, picker);

  // A fresh picker selecting an open agent collapses away.
  store.dispatch(splitMainPane({ targetPaneId: 'pane-1', direction: 'bottom' }));
  const picker2 = tree(store).focusedPaneId;
  assert.equal(agentOf(store, picker2), NEW_PANE_AGENT_ID);
  store.dispatch(assignMainPaneAgent({ paneId: picker2, agentInstanceId: 'a' }));
  assert.equal(getContentPaneIds(tree(store)).length, 2);
  assert.equal(tree(store).focusedPaneId, 'pane-1');
  assert.equal(findPaneByAgent(tree(store), 'a'), 'pane-1');
});

test('closeMainPane removes a pane in a split and resets the sole pane to the picker', () => {
  const store = makeStore();
  store.dispatch(setLayoutFromUrl({ ids: ['a'] }));
  store.dispatch(splitMainPane({ targetPaneId: 'pane-1', direction: 'right', agentInstanceId: 'b' }));
  const bPane = findPaneByAgent(tree(store), 'b')!;
  store.dispatch(closeMainPane(bPane));
  assert.deepEqual(getContentPaneIds(tree(store)), ['pane-1']);
  assert.equal(tree(store).focusedPaneId, 'pane-1');
  store.dispatch(closeMainPane('pane-1'));
  assert.deepEqual(getContentPaneIds(tree(store)), ['pane-1']);
  assert.equal(agentOf(store, 'pane-1'), NEW_PANE_AGENT_ID);
});

test('sanitizeMainTree validates saved geometry and enforces the dedupe invariant', () => {
  const store = makeStore();
  store.dispatch(
    setLayoutFromUrl({ ids: ['dup', '_new'], savedLayout: {
      rootPaneId: 'split-1',
      focusedPaneId: 'ghost',
      maximizedPaneId: 'pane-2',
      panes: {
        'split-1': { kind: 'split', axis: 'horizontal', leftChildId: 'pane-1', rightChildId: 'pane-2', ratio: 'x' },
        'pane-1': { kind: 'content', value: { agentInstanceId: 'dup' } },
        'pane-2': { kind: 'content', value: { agentInstanceId: 'dup' } },
        orphan: { kind: 'content', value: { agentInstanceId: 'zzz' } },
      },
    } as any }),
  );
  const t = tree(store);
  assert.equal(t.focusedPaneId, 'pane-1');
  assert.equal(agentOf(store, 'pane-1'), 'dup');
  assert.equal(agentOf(store, 'pane-2'), NEW_PANE_AGENT_ID, 'duplicate agent becomes a picker');
  assert.equal(t.panes.orphan, undefined, 'unreachable nodes are pruned');
  const split = t.panes['split-1'];
  assert.equal(split.kind === 'split' && split.ratio, 50);

  assert.equal(sanitizeMainTree(null), null);
  assert.equal(sanitizeMainTree({ rootPaneId: 'x', panes: [] }), null);
  assert.equal(
    sanitizeMainTree({
      rootPaneId: 's',
      panes: { s: { kind: 'split', axis: 'vertical', leftChildId: 'a', rightChildId: 'missing' }, a: { kind: 'content', value: {} } },
    }),
    null,
  );
  assert.deepEqual(createInitialMainTree('q').panes['pane-1'], { kind: 'content', value: { agentInstanceId: 'q' } });
});

test('workspace chrome: aux width is clamped and persisted, maximize is session-only', () => {
  const store = makeStore();
  assert.equal(selectAuxWidth(store.getState()), null);
  store.dispatch(setAuxWidth(10));
  assert.equal(selectAuxWidth(store.getState()), AUX_MIN_WIDTH);
  store.dispatch(setAuxWidth(99999));
  assert.equal(selectAuxWidth(store.getState()), AUX_MAX_WIDTH);
  store.dispatch(toggleAuxMaximized());
  assert.equal(store.getState().workspaceChrome.isAuxMaximized, true);
  store.dispatch(hydrateWorkspaceChrome({ auxWidth: 640, isAuxMaximized: false }));
  assert.equal(selectAuxWidth(store.getState()), 640);
  assert.equal(store.getState().workspaceChrome.isAuxMaximized, true, 'hydrate does not touch session-only maximize');
});
