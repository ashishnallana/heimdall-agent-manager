import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { configureStore } from '@reduxjs/toolkit';

import {
  FILES_TAB_ID,
  NEW_TAB_ID,
  OVERVIEW_TAB_ID,
  auxTabId,
  auxTabTitle,
  createAuxTab,
  decodeAuxTabId,
  isAuxContent,
  resolveLegacyPanelToAuxContent,
  type AuxContent,
} from '../src/ui/store/auxTabId.ts';
import auxPanesReducer, {
  carryAuxPaneOpenOnFocus,
  closeAuxTab,
  createDefaultAuxPane,
  ensureAuxPane,
  hydrateAuxPanes,
  moveAuxTab,
  openAuxNewTab,
  openAuxTab,
  openPreviewInAux,
  rekeyAuxTab,
  resolveActiveAuxTab,
  resolveAuxTreeId,
  sanitizeAuxPanesState,
  selectAuxPane,
  selectCurrentAuxTreeId,
  setActiveAuxTab,
  setAuxPaneOpen,
  toggleAuxPane,
  updateAuxTabContent,
  visibleAuxTabs,
  type AuxTreeId,
} from '../src/ui/store/auxPanesSlice.ts';
import { isAuxContentAllowed, chainParticipantIdsFromMembers } from '../src/ui/store/auxTabGuards.ts';
import workspaceLayoutReducer, {
  navigateMainToAgent,
  setFocusedMainPane,
  splitMainPane,
  closeMainPane,
  findPaneByAgent,
} from '../src/ui/store/workspaceLayoutSlice.ts';

function makeStore() {
  return configureStore({
    reducer: { workspaceLayout: workspaceLayoutReducer, auxPanes: auxPanesReducer },
  });
}

const A: AuxTreeId = { kind: 'agent', agentInstanceId: 'agent-a' };
const B: AuxTreeId = { kind: 'agent', agentInstanceId: 'agent-b' };

test('tab codec: content-derived ids round-trip and ignore transient params', () => {
  const cases: Array<[AuxContent, string]> = [
    [{ type: 'chainOverview' }, 'overview'],
    [{ type: 'files', path: '/x/y.ts' }, 'files'],
    [{ type: 'vcs', filePath: 'a.ts' }, 'vcs'],
    [{ type: 'tasks', taskId: 't1' }, 'tasks'],
    [{ type: 'shell', sessionId: 'sess-1' }, 'shell__sess-1'],
    [{ type: 'shell', sessionId: '' }, 'shell__new'],
    [{ type: 'agentPty', agentInstanceId: 'inst-1' }, 'pty__inst-1'],
    [{ type: 'preview', sessionId: 'srv', port: 5173 }, 'preview__srv:5173'],
    [{ type: 'preview', sessionId: 'srv' }, 'preview__srv'],
    [{ type: 'subagentChat', agentInstanceId: 'child' }, 'subagent_convo__child'],
  ];
  for (const [content, id] of cases) {
    assert.equal(auxTabId(content), id);
    const decoded = decodeAuxTabId(id)!;
    assert.equal(decoded.type, content.type);
    assert.equal(auxTabId(decoded), id, `decode(${id}) must re-encode to the same id`);
  }
  assert.equal(decodeAuxTabId(NEW_TAB_ID), null);
  assert.equal(decodeAuxTabId('agentChat__x'), null, 'chats are never aux tabs');
  assert.equal(decodeAuxTabId('pty__'), null);
  assert.equal(isAuxContent({ type: 'agentPty' }), false);
  assert.equal(isAuxContent({ type: 'files' }), true);
  assert.equal(createAuxTab({ type: 'preview', sessionId: ' s ', port: 80, path: '//a' }).content.type, 'preview');
  assert.equal(auxTabTitle({ content: { type: 'preview', sessionId: 's', port: 80 } }), 'Preview :80');
  assert.deepEqual(resolveLegacyPanelToAuxContent('chain'), { type: 'chainOverview' });
  assert.deepEqual(resolveLegacyPanelToAuxContent('tasks', { taskId: 't' }), { type: 'tasks', taskId: 't' });
  assert.equal(resolveLegacyPanelToAuxContent('chat'), null);
});

test('tree selection rule: the aux always shows the FOCUSED Main pane agent strip (single or split)', () => {
  const store = makeStore();
  assert.equal(selectCurrentAuxTreeId(store.getState()), null, 'a lone picker has no aux');

  store.dispatch(navigateMainToAgent('agent-a'));
  assert.deepEqual(selectCurrentAuxTreeId(store.getState()), A);

  // Switching the agent in a pane switches the aux tree.
  store.dispatch(navigateMainToAgent('agent-b'));
  assert.deepEqual(selectCurrentAuxTreeId(store.getState()), B);

  // Split view: the aux follows focus (Jetski /c/A+B?focused=A).
  store.dispatch(splitMainPane({ targetPaneId: 'pane-1', direction: 'right', agentInstanceId: 'agent-a' }));
  assert.deepEqual(selectCurrentAuxTreeId(store.getState()), A, 'the new focused pane drives the aux');
  const t = store.getState().workspaceLayout.tree;
  store.dispatch(setFocusedMainPane(findPaneByAgent(t, 'agent-b')!));
  assert.deepEqual(selectCurrentAuxTreeId(store.getState()), B);
  store.dispatch(setFocusedMainPane(findPaneByAgent(t, 'agent-a')!));
  assert.deepEqual(selectCurrentAuxTreeId(store.getState()), A);

  // A focused picker pane has no aux.
  store.dispatch(splitMainPane({ targetPaneId: findPaneByAgent(t, 'agent-a')!, direction: 'bottom' }));
  assert.equal(selectCurrentAuxTreeId(store.getState()), null);

  store.dispatch(closeMainPane(store.getState().workspaceLayout.tree.focusedPaneId));
  assert.ok(selectCurrentAuxTreeId(store.getState()));
  assert.deepEqual(
    resolveAuxTreeId({ rootPaneId: 'p', focusedPaneId: 'p', panes: { p: { kind: 'content', value: { agentInstanceId: 'x' } } } }),
    { kind: 'agent', agentInstanceId: 'x' },
  );
});

test('focus change within a split carries the dock open state to the newly focused strip (Jetski RouteToReduxSync)', () => {
  const store = makeStore();
  store.dispatch(setAuxPaneOpen({ treeId: A, open: true, hasChain: true }));
  // Target strip does not exist yet: created open, seeded once its chain is known.
  store.dispatch(carryAuxPaneOpenOnFocus({ from: A, to: B }));
  let b = selectAuxPane(store.getState(), B)!;
  assert.equal(b.isPaneOpen, true);
  assert.equal(b.activeTabId, undefined);
  store.dispatch(ensureAuxPane({ treeId: B, hasChain: false }));
  b = selectAuxPane(store.getState(), B)!;
  assert.equal(b.activeTabId, FILES_TAB_ID, 'deferred seeding uses the real chain membership');
  // Closing on B then focusing A closes A too.
  store.dispatch(setAuxPaneOpen({ treeId: B, open: false }));
  store.dispatch(carryAuxPaneOpenOnFocus({ from: B, to: A }));
  assert.equal(selectAuxPane(store.getState(), A)!.isPaneOpen, false);
  // Same agent is a no-op.
  store.dispatch(carryAuxPaneOpenOnFocus({ from: A, to: A }));
  assert.equal(selectAuxPane(store.getState(), A)!.isPaneOpen, false);
});

test('seeding mirrors Jetski createDefaultPaneState: no tabs, fixed overview active (Files without a chain)', () => {
  assert.deepEqual(createDefaultAuxPane(true), { tabs: [], activeTabId: OVERVIEW_TAB_ID });
  assert.deepEqual(createDefaultAuxPane(false), { tabs: [], activeTabId: FILES_TAB_ID });

  const store = makeStore();
  store.dispatch(ensureAuxPane({ treeId: A, hasChain: true }));
  store.dispatch(ensureAuxPane({ treeId: B, hasChain: false }));
  const a = selectAuxPane(store.getState(), A)!;
  assert.deepEqual(a.tabs, []);
  assert.equal(resolveActiveAuxTab(a)!.content.type, 'chainOverview');
  assert.deepEqual(visibleAuxTabs(a).map((t) => t.id), ['overview'], 'derived overview tab is shown');
  assert.equal(resolveActiveAuxTab(selectAuxPane(store.getState(), B))!.content.type, 'files');
  store.dispatch(openAuxTab({ treeId: A, content: { type: 'vcs' } }));
  // ensure is idempotent
  store.dispatch(ensureAuxPane({ treeId: A, hasChain: false }));
  assert.equal(selectAuxPane(store.getState(), A)!.tabs.length, 2);
});

test('openAuxTab dedupes by content-derived id, materializes the seeded overview and opens the dock', () => {
  const store = makeStore();
  store.dispatch(openAuxTab({ treeId: A, content: { type: 'shell', sessionId: 's1' }, hasChain: true }));
  let pane = selectAuxPane(store.getState(), A)!;
  assert.deepEqual(pane.tabs.map((t) => t.id), ['overview', 'shell__s1']);
  assert.equal(pane.activeTabId, 'shell__s1');
  assert.equal(pane.isPaneOpen, true);

  store.dispatch(openAuxTab({ treeId: A, content: { type: 'files', path: 'src/a.ts' } }));
  store.dispatch(openAuxTab({ treeId: A, content: { type: 'files', path: 'src/b.ts' } }));
  pane = selectAuxPane(store.getState(), A)!;
  assert.deepEqual(pane.tabs.map((t) => t.id), ['overview', 'shell__s1', 'files']);
  const files = pane.tabs.find((t) => t.id === 'files')!;
  assert.equal(files.content.type === 'files' && files.content.path, 'src/b.ts', 're-open merges params');

  store.dispatch(setActiveAuxTab({ treeId: A, tabId: 'shell__s1' }));
  store.dispatch(openAuxTab({ treeId: A, content: { type: 'shell', sessionId: 's1' } }));
  pane = selectAuxPane(store.getState(), A)!;
  assert.equal(pane.tabs.length, 3);
  assert.equal(pane.activeTabId, 'shell__s1');
});

test('tab lifecycle: select, new-tab launcher, close neighbours, reorder, params, rekey', () => {
  const store = makeStore();
  store.dispatch(ensureAuxPane({ treeId: A, hasChain: true }));
  store.dispatch(openAuxNewTab({ treeId: A }));
  let pane = selectAuxPane(store.getState(), A)!;
  assert.equal(pane.activeTabId, NEW_TAB_ID);
  assert.deepEqual(pane.tabs.map((t) => t.id), ['overview'], 'derived overview materialized before the launcher');

  store.dispatch(openAuxTab({ treeId: A, content: { type: 'agentPty', agentInstanceId: 'agent-a' } }));
  store.dispatch(openAuxTab({ treeId: A, content: { type: 'shell', sessionId: 'new' } }));
  store.dispatch(openAuxTab({ treeId: A, content: { type: 'vcs' } }));
  pane = selectAuxPane(store.getState(), A)!;
  assert.deepEqual(pane.tabs.map((t) => t.id), ['overview', 'pty__agent-a', 'shell__new', 'vcs']);

  store.dispatch(moveAuxTab({ treeId: A, tabId: 'vcs', toIndex: 0 }));
  assert.deepEqual(selectAuxPane(store.getState(), A)!.tabs.map((t) => t.id), ['vcs', 'overview', 'pty__agent-a', 'shell__new']);

  // Provisional shell rekeyed once bound -> another new shell can coexist.
  store.dispatch(rekeyAuxTab({ treeId: A, tabId: 'shell__new', content: { type: 'shell', sessionId: 's9' } }));
  pane = selectAuxPane(store.getState(), A)!;
  assert.deepEqual(pane.tabs.map((t) => t.id), ['vcs', 'overview', 'pty__agent-a', 'shell__s9']);
  store.dispatch(openAuxTab({ treeId: A, content: { type: 'shell', sessionId: 'new' } }));
  assert.equal(selectAuxPane(store.getState(), A)!.tabs.length, 5);
  // Rekey onto an existing id dedupes.
  store.dispatch(rekeyAuxTab({ treeId: A, tabId: 'shell__new', content: { type: 'shell', sessionId: 's9' } }));
  pane = selectAuxPane(store.getState(), A)!;
  assert.equal(pane.tabs.filter((t) => t.id.startsWith('shell__')).length, 1);
  assert.equal(pane.activeTabId, 'shell__s9');

  store.dispatch(updateAuxTabContent({ treeId: A, tabId: 'vcs', patch: { filePath: 'x.ts' } }));
  const vcs = selectAuxPane(store.getState(), A)!.tabs.find((t) => t.id === 'vcs')!;
  assert.equal(vcs.content.type === 'vcs' && vcs.content.filePath, 'x.ts');
  // identity-changing patches are rejected
  store.dispatch(updateAuxTabContent({ treeId: A, tabId: 'pty__agent-a', patch: { agentInstanceId: 'other' } as any }));
  assert.ok(selectAuxPane(store.getState(), A)!.tabs.some((t) => t.id === 'pty__agent-a'));

  // Close the active tab -> its right neighbour (or left) becomes active.
  store.dispatch(setActiveAuxTab({ treeId: A, tabId: 'overview' }));
  store.dispatch(closeAuxTab({ treeId: A, tabId: 'overview' }));
  assert.equal(selectAuxPane(store.getState(), A)!.activeTabId, 'pty__agent-a');
  for (const t of [...selectAuxPane(store.getState(), A)!.tabs]) {
    store.dispatch(closeAuxTab({ treeId: A, tabId: t.id }));
  }
  pane = selectAuxPane(store.getState(), A)!;
  assert.deepEqual(pane.tabs, []);
  assert.equal(pane.activeTabId, NEW_TAB_ID, 'closing every tab shows the launcher');
});

test('isPaneOpen is per tree and previous agent strips are retained', () => {
  const store = makeStore();
  store.dispatch(toggleAuxPane({ treeId: A, hasChain: true }));
  store.dispatch(openAuxTab({ treeId: A, content: { type: 'vcs' } }));
  assert.equal(selectAuxPane(store.getState(), A)!.isPaneOpen, true);
  assert.equal(selectAuxPane(store.getState(), B), undefined);
  store.dispatch(ensureAuxPane({ treeId: B, hasChain: true }));
  assert.ok(!selectAuxPane(store.getState(), B)!.isPaneOpen, 'B starts closed');
  store.dispatch(setAuxPaneOpen({ treeId: B, open: true }));
  store.dispatch(toggleAuxPane({ treeId: A }));
  assert.equal(selectAuxPane(store.getState(), A)!.isPaneOpen, false);
  assert.equal(selectAuxPane(store.getState(), B)!.isPaneOpen, true);
  assert.deepEqual(selectAuxPane(store.getState(), A)!.tabs.map((t) => t.id), ['overview', 'vcs'], 'A strip retained');
});

test('hydrate sanitizes persisted aux strips (drops bad tabs, duplicates, smuggled NEW_TAB_ID)', () => {
  const clean = sanitizeAuxPanesState({
    agentPanes: {
      a: {
        tabs: [
          { id: 'whatever', content: { type: 'shell', sessionId: 's1' } },
          { id: 'dup', content: { type: 'shell', sessionId: 's1' } },
          { id: NEW_TAB_ID, content: { type: 'bogus' } },
          { content: { type: 'agentPty' } },
        ],
        activeTabId: 'gone',
        isPaneOpen: true,
      },
      _new: { tabs: [] },
    },
    multiPane: { tabs: [], activeTabId: 'overview' },
    b: 1,
  } as any);
  assert.deepEqual(clean.agentPanes.a.tabs.map((t) => t.id), ['shell__s1'], 'ids are re-derived from content');
  assert.equal(clean.agentPanes.a.activeTabId, 'shell__s1');
  assert.equal(clean.agentPanes.a.isPaneOpen, true);
  assert.equal(clean.agentPanes._new, undefined);
  assert.equal((clean as any).multiPane, undefined, 'the old shared split strip is dropped');
  const store = makeStore();
  store.dispatch(hydrateAuxPanes({ agentPanes: [] }));
  assert.deepEqual(store.getState().auxPanes, { agentPanes: {} });
});

test('openPreviewInAux targets the current tree and is a no-op without one', () => {
  const store = makeStore();
  store.dispatch(openPreviewInAux({ sessionId: 's', port: 3000 }) as any);
  assert.deepEqual(store.getState().auxPanes.agentPanes, {});
  store.dispatch(navigateMainToAgent('agent-a'));
  store.dispatch(openPreviewInAux({ sessionId: 's', port: 3000, label: 'web' }) as any);
  const pane = selectAuxPane(store.getState(), A)!;
  assert.equal(pane.activeTabId, 'preview__s:3000');
  assert.equal(pane.tabs.find((t) => t.id === 'preview__s:3000')!.title, 'web');
});

test('sub-agent chat tabs are limited to participants of the owning agent chain', () => {
  const participants = chainParticipantIdsFromMembers([
    { agentInstanceId: 'owner' },
    { agent_instance_id: 'child-1' },
    { agentInstanceId: '' },
  ]);
  assert.deepEqual([...participants].sort(), ['child-1', 'owner']);
  const ctx = { ownerAgentId: 'owner', chainId: 'c1', participantIds: participants };
  assert.equal(isAuxContentAllowed({ type: 'subagentChat', agentInstanceId: 'child-1' }, ctx), true);
  assert.equal(isAuxContentAllowed({ type: 'subagentChat', agentInstanceId: 'stranger' }, ctx), false);
  assert.equal(isAuxContentAllowed({ type: 'subagentChat', agentInstanceId: 'owner' }, ctx), false, 'owner is already in Main');
  assert.equal(isAuxContentAllowed({ type: 'subagentChat', agentInstanceId: 'child-1' }, { ...ctx, chainId: '' }), false);
  assert.equal(isAuxContentAllowed({ type: 'subagentChat', agentInstanceId: 'child-1' }, { ...ctx, participantIds: null }), false);
  // PTY keeps the pre-existing chain-participant guard.
  assert.equal(isAuxContentAllowed({ type: 'agentPty', agentInstanceId: 'stranger' }, ctx), false);
  assert.equal(isAuxContentAllowed({ type: 'agentPty', agentInstanceId: 'child-1' }, ctx), true);
  assert.equal(isAuxContentAllowed({ type: 'agentPty', agentInstanceId: 'x' }, { ...ctx, participantIds: new Set() }), true);
  assert.equal(isAuxContentAllowed({ type: 'agentPty', agentInstanceId: 'x' }, { ownerAgentId: 'owner' }), false);
  assert.equal(isAuxContentAllowed({ type: 'agentPty', agentInstanceId: 'owner' }, { ownerAgentId: 'owner' }), true);
  assert.equal(isAuxContentAllowed({ type: 'files' }, {}), true);
});

test('multiple interactive shell tabs coexist: each "New shell" opens its own tab, rekeyed to its own session', async () => {
  const { newShellTabContent, isProvisionalShellSessionId } = await import('../src/ui/store/auxTabId.ts');
  const store = makeStore();
  const first = newShellTabContent();
  const second = newShellTabContent();
  assert.notEqual(auxTabId(first), auxTabId(second), 'provisional shell tabs never dedupe into one');
  assert.ok(first.type === 'shell' && isProvisionalShellSessionId(first.sessionId));
  assert.equal(isProvisionalShellSessionId('sess-1'), false);
  store.dispatch(openAuxTab({ treeId: A, content: first, hasChain: false }));
  store.dispatch(openAuxTab({ treeId: A, content: second }));
  store.dispatch(openAuxTab({ treeId: A, content: newShellTabContent() }));
  let shells = selectAuxPane(store.getState(), A)!.tabs.filter((t) => t.content.type === 'shell');
  assert.equal(shells.length, 3);
  // Each tab binds to its own interactive session; none switches sessions in place.
  store.dispatch(rekeyAuxTab({ treeId: A, tabId: auxTabId(first), content: { type: 'shell', sessionId: 's-1' } }));
  store.dispatch(rekeyAuxTab({ treeId: A, tabId: auxTabId(second), content: { type: 'shell', sessionId: 's-2' } }));
  shells = selectAuxPane(store.getState(), A)!.tabs.filter((t) => t.content.type === 'shell');
  assert.deepEqual(shells.map((t) => t.id).slice(0, 2), ['shell__s-1', 'shell__s-2']);
  assert.equal(auxTabTitle(shells[2]), 'Shell');
});
