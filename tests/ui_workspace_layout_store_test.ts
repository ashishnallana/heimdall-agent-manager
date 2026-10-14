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
  hydrateWorkspaceLayout,
  moveMainPane,
  navigateMainToAgent,
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

test('navigateMainToAgent replaces the focused pane agent, or focuses an open agent (dedupe)', () => {
  const store = makeStore();
  store.dispatch(navigateMainToAgent('agent-a'));
  assert.equal(agentOf(store, 'pane-1'), 'agent-a');

  store.dispatch(splitMainPane({ targetPaneId: 'pane-1', direction: 'right' }));
  const [, right] = getContentPaneIds(tree(store));
  assert.equal(agentOf(store, right), NEW_PANE_AGENT_ID, 'split without agent creates a picker');
  assert.equal(tree(store).focusedPaneId, right, 'the new pane is focused');

  // Navigating to an agent NOT in Main replaces the focused pane's agent.
  store.dispatch(navigateMainToAgent('agent-b'));
  assert.equal(agentOf(store, right), 'agent-b');
  assert.equal(agentOf(store, 'pane-1'), 'agent-a');

  // Navigating to an agent already open focuses its pane, nothing is duplicated.
  store.dispatch(navigateMainToAgent('agent-a'));
  assert.equal(tree(store).focusedPaneId, 'pane-1');
  assert.deepEqual(selectMainAgentIds(store.getState()), ['agent-a', 'agent-b']);
  assert.equal(selectFocusedMainAgentId(store.getState()), 'agent-a');

  // Ignores the picker sentinel / empty ids.
  store.dispatch(navigateMainToAgent(NEW_PANE_AGENT_ID));
  store.dispatch(navigateMainToAgent(''));
  assert.deepEqual(selectMainAgentIds(store.getState()), ['agent-a', 'agent-b']);
});

test('split in all 4 directions, focus, resize, maximize and move preserve pane ids', () => {
  const store = makeStore();
  store.dispatch(navigateMainToAgent('a'));
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
  store.dispatch(navigateMainToAgent('a'));
  store.dispatch(splitMainPane({ targetPaneId: 'pane-1', direction: 'right', agentInstanceId: 'b' }));
  const before = getContentPaneIds(tree(store));
  store.dispatch(setFocusedMainPane('pane-1'));
  store.dispatch(splitMainPane({ targetPaneId: 'pane-1', direction: 'down' as any, agentInstanceId: 'b' }));
  assert.deepEqual(getContentPaneIds(tree(store)), before);
  assert.equal(selectFocusedMainAgentId(store.getState()), 'b');
});

test('assignMainPaneAgent fills a picker; picking an already-open agent focuses it and drops the picker', () => {
  const store = makeStore();
  store.dispatch(navigateMainToAgent('a'));
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
  store.dispatch(navigateMainToAgent('a'));
  store.dispatch(splitMainPane({ targetPaneId: 'pane-1', direction: 'right', agentInstanceId: 'b' }));
  const bPane = findPaneByAgent(tree(store), 'b')!;
  store.dispatch(closeMainPane(bPane));
  assert.deepEqual(getContentPaneIds(tree(store)), ['pane-1']);
  assert.equal(tree(store).focusedPaneId, 'pane-1');
  store.dispatch(closeMainPane('pane-1'));
  assert.deepEqual(getContentPaneIds(tree(store)), ['pane-1']);
  assert.equal(agentOf(store, 'pane-1'), NEW_PANE_AGENT_ID);
});

test('hydrate sanitizes persisted trees and enforces the dedupe invariant', () => {
  const store = makeStore();
  store.dispatch(
    hydrateWorkspaceLayout({
      rootPaneId: 'split-1',
      focusedPaneId: 'ghost',
      maximizedPaneId: 'pane-2',
      panes: {
        'split-1': { kind: 'split', axis: 'horizontal', leftChildId: 'pane-1', rightChildId: 'pane-2', ratio: 'x' },
        'pane-1': { kind: 'content', value: { agentInstanceId: 'dup' } },
        'pane-2': { kind: 'content', value: { agentInstanceId: 'dup' } },
        orphan: { kind: 'content', value: { agentInstanceId: 'zzz' } },
      },
    }),
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
  // Invalid payloads leave the state untouched.
  store.dispatch(hydrateWorkspaceLayout({ bogus: true }));
  assert.equal(tree(store).rootPaneId, 'split-1');
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
