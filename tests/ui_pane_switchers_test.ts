import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import React from 'react';
import { blurInactiveMainPaneFocus } from '../src/ui/components/mainWorkspace/paneFocus.ts';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

// Agents: a/a2 (chain-1), b (chain-2), coord-3 (coordinator of chain-3), chain-4 has no coordinator.
// chain-5 / chain-6 are coordinated by two instances of ONE durable agent (agt_shared),
// and chain-6's coordinator can be replaced (coord-6x -> coord-6y) via COORDINATORS.
const COORDINATORS: Record<string, string> = { 'chain-5': 'coord-5x', 'chain-6': 'coord-6x' };
const REPLACED: Record<string, string[]> = {};
const CONVERSATIONS: Record<string, any> = {
  'coord-5x': { conversation_id: 'conv-5x', agent_id: 'agt_shared', agent_instance_id: 'coord-5x', chain_id: 'chain-5', project_id: 'p1', title: 'Shared on Five' },
  'coord-6x': { conversation_id: 'conv-6x', agent_id: 'agt_shared', agent_instance_id: 'coord-6x', chain_id: 'chain-6', project_id: 'p1', title: 'Shared on Six' },
  'coord-6y': { conversation_id: 'conv-6y', agent_id: 'agt_shared', agent_instance_id: 'coord-6y', chain_id: 'chain-6', project_id: 'p1', title: 'Replacement on Six' },
  a: { conversation_id: 'conv-a', agent_instance_id: 'a', chain_id: 'chain-1', project_id: 'p1', title: 'Agent A' },
  a2: { conversation_id: 'conv-a2', agent_instance_id: 'a2', chain_id: 'chain-1', project_id: 'p1', title: 'Agent A2' },
  b: { conversation_id: 'conv-b', agent_instance_id: 'b', chain_id: 'chain-2', project_id: 'p1', title: 'Agent B' },
  'coord-3': { conversation_id: 'conv-c3', agent_instance_id: 'coord-3', chain_id: 'chain-3', project_id: 'p1', title: 'Coord 3' },
};
const CHAIN_MEMBERS: Record<string, any[]> = {
  'chain-1': [
    { chain_id: 'chain-1', agent_instance_id: 'a', display_name: 'Agent A', role: 'coordinator' },
    { chain_id: 'chain-1', agent_instance_id: 'a2', display_name: 'Agent A2', role: 'worker' },
  ],
  'chain-2': [
    { chain_id: 'chain-2', agent_instance_id: 'b', display_name: 'Agent B', role: 'coordinator' },
  ],
};
const GROUPS = [
  {
    project_id: 'p1',
    project_name: 'Proj',
    chains: [
      { chain_id: 'chain-2', title: 'Chain Two', status: 'active', coordinator_agent_instance_id: 'b', project_id: 'p1' },
      { chain_id: 'chain-3', title: 'Chain Three', status: 'active', coordinator_agent_instance_id: 'coord-3', project_id: 'p1' },
      { chain_id: 'chain-4', title: 'Chain Four', status: 'active', coordinator_agent_instance_id: '', project_id: 'p1' },
      { chain_id: 'chain-5', title: 'Chain Five', status: 'active', coordinator_agent_instance_id: 'coord-5x', project_id: 'p1' },
      { chain_id: 'chain-6', title: 'Chain Six', status: 'active', coordinator_agent_instance_id: 'coord-6x', project_id: 'p1' },
    ],
  },
];

function json(body: any, ok = true) {
  return {
    ok,
    status: ok ? 200 : 404,
    headers: { get: () => 'application/json' },
    text: async () => JSON.stringify(body),
    json: async () => body,
  } as any;
}

async function withDom<T>(hash: string, fn: (dom: any) => Promise<T>): Promise<T> {
  const { JSDOM } = await import('jsdom');
  const dom = new JSDOM('<!DOCTYPE html><html><body><div id="root"></div></body></html>', {
    url: `http://localhost/${hash}`,
  });
  (dom.window.HTMLElement.prototype as any).scrollTo = () => {};
  (dom.window.HTMLElement.prototype as any).scrollIntoView = () => {};
  const prev = {
    window: (globalThis as any).window,
    document: (globalThis as any).document,
    HTMLElement: (globalThis as any).HTMLElement,
    navigator: (globalThis as any).navigator,
    fetch: (globalThis as any).fetch,
    localStorage: (globalThis as any).localStorage,
  };
  (globalThis as any).window = dom.window;
  (globalThis as any).document = dom.window.document;
  (globalThis as any).HTMLElement = dom.window.HTMLElement;
  (globalThis as any).localStorage = dom.window.localStorage;
  Object.defineProperty(globalThis, 'navigator', { value: dom.window.navigator, configurable: true });
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  class RO { observe() {} unobserve() {} disconnect() {} }
  const prevEnv = [(globalThis as any).ResizeObserver, (globalThis as any).requestAnimationFrame, (globalThis as any).cancelAnimationFrame];
  (globalThis as any).ResizeObserver = RO;
  (globalThis as any).requestAnimationFrame = (cb: any) => setTimeout(() => cb(Date.now()), 0) as any;
  (globalThis as any).cancelAnimationFrame = (id: any) => clearTimeout(id);
  (dom.window as any).requestAnimationFrame = (globalThis as any).requestAnimationFrame;
  (dom.window as any).cancelAnimationFrame = (globalThis as any).cancelAnimationFrame;
  (dom.window as any).matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} });
  (globalThis as any).fetch = async (input: any) => {
    const url = String(input?.url ?? input);
    const byInstance = url.match(/\/chats\/by-instance\/([^/?]+)/);
    if (byInstance) {
      const conv = CONVERSATIONS[decodeURIComponent(byInstance[1])];
      return conv ? json({ data: conv }) : json({ error: 'nope' }, false);
    }
    if (/\/agent-instances(\?|$)/.test(url)) return json({ data: [] });
    if (/\/agents(\?|$)/.test(url)) return json({ data: [] });
    if (/\/bridges(\?|$)/.test(url)) return json({ data: [] });
    if (/\/task-chains\/[^/?]+\/fleets(\?|$)/.test(url)) return json({ data: [] });
    const chainConversation = url.match(/\/task-chains\/([^/?]+)\/conversation(?:\?|$)/);
    if (chainConversation) {
      const chainId = decodeURIComponent(chainConversation[1]);
      const summary = GROUPS.flatMap((group) => group.chains).find((chain) => chain.chain_id === chainId);
      const coordinator = COORDINATORS[chainId] || summary?.coordinator_agent_instance_id || (chainId === 'chain-1' ? 'a' : '');
      return json({ data: {
        chain_id: chainId,
        title: summary?.title || (chainId === 'chain-1' ? 'Chain One' : chainId),
        coordinator_agent_instance_id: coordinator,
        conversation_id: CONVERSATIONS[coordinator]?.conversation_id || '',
        replaced_coordinator_instance_ids: REPLACED[chainId] || [],
      } });
    }
    const chainDetail = url.match(/\/task-chains\/([^/?]+)(?:\?|$)/);
    if (chainDetail) {
      const chainId = decodeURIComponent(chainDetail[1]);
      const summary = GROUPS.flatMap((group) => group.chains).find((chain) => chain.chain_id === chainId);
      return json({ data: {
        ...(summary || {}),
        chain_id: chainId,
        title: summary?.title || (chainId === 'chain-1' ? 'Chain One' : chainId),
        coordinator_agent_instance_id: summary?.coordinator_agent_instance_id || (chainId === 'chain-1' ? 'a' : ''),
        members: CHAIN_MEMBERS[chainId] || [],
        tasks: [],
      } });
    }
    if (/\/task-chains(\?|$)/.test(url)) return json({ groups: GROUPS });
    if (/\/templates(\?|$)/.test(url)) return json({ data: [] });
    return json({ data: {} });
  };
  try {
    return await fn(dom);
  } finally {
    dom.window.close();
    (globalThis as any).window = prev.window;
    (globalThis as any).document = prev.document;
    (globalThis as any).HTMLElement = prev.HTMLElement;
    (globalThis as any).localStorage = prev.localStorage;
    Object.defineProperty(globalThis, 'navigator', { value: prev.navigator, configurable: true });
    (globalThis as any).fetch = prev.fetch;
    (globalThis as any).ResizeObserver = prevEnv[0];
    // A few UI dependencies schedule cleanup one tick after React unmounts.
    // Keep safe timer-backed fallbacks when Node did not provide RAF globals,
    // so that late cleanup cannot call an already-restored undefined function.
    (globalThis as any).requestAnimationFrame = prevEnv[1]
      ?? ((cb: any) => setTimeout(() => cb(Date.now()), 0) as any);
    (globalThis as any).cancelAnimationFrame = prevEnv[2]
      ?? ((id: any) => clearTimeout(id));
  }
}

test('Main pane focus changes blur only controls owned by the old pane', async () => {
  await withDom('#/conversations/a+b?focused=a', async (dom) => {
    const doc = dom.window.document;
    doc.body.insertAdjacentHTML('beforeend', `
      <section data-main-pane-id="pane-a"><textarea id="old-pane-input"></textarea></section>
      <section data-main-pane-id="pane-b"><input id="new-pane-input" /></section>
      <input id="outside-workspace" />
    `);
    const oldPaneInput = doc.getElementById('old-pane-input') as HTMLTextAreaElement;
    const newPaneInput = doc.getElementById('new-pane-input') as HTMLInputElement;
    const outsideWorkspace = doc.getElementById('outside-workspace') as HTMLInputElement;

    oldPaneInput.focus();
    assert.equal(doc.activeElement, oldPaneInput);
    assert.equal(blurInactiveMainPaneFocus('pane-b', doc), true);
    assert.notEqual(doc.activeElement, oldPaneInput);

    newPaneInput.focus();
    assert.equal(blurInactiveMainPaneFocus('pane-b', doc), false);
    assert.equal(doc.activeElement, newPaneInput);

    outsideWorkspace.focus();
    assert.equal(blurInactiveMainPaneFocus('pane-a', doc), false);
    assert.equal(doc.activeElement, outsideWorkspace);
  });

  const workspace = fs.readFileSync(
    path.join(REPO_ROOT, 'src/ui/components/mainWorkspace/Workspace.tsx'),
    'utf8',
  );
  assert.match(
    workspace,
    /useEffect\(\(\) => \{\s*blurInactiveMainPaneFocus\(tree\.focusedPaneId\);\s*\}, \[tree\.focusedPaneId\]\);/,
  );
});

async function makeStore() {
  const { configureStore } = await import('@reduxjs/toolkit');
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const { default: vaultReducer } = await import('../src/ui/store/vaultSlice.ts');
  const { default: workspaceLayout } = await import('../src/ui/store/workspaceLayoutSlice.ts');
  const { default: auxPanes } = await import('../src/ui/store/auxPanesSlice.ts');
  const { default: workspaceChrome } = await import('../src/ui/store/workspaceChromeSlice.ts');
  const { default: searchTitle } = await import('../src/ui/store/searchTitleSlice.ts');
  return configureStore({
    reducer: {
      searchTitle,
      vault: vaultReducer,
      workspaceLayout,
      auxPanes,
      workspaceChrome,
      chat: (s: any = { session: { daemonUrl: 'http://127.0.0.1:7777', clientToken: 'tok_test' } }) => s,
      [heimdallApi.reducerPath]: heimdallApi.reducer,
    },
    middleware: (g: any) => g({ serializableCheck: false, immutableCheck: false }).concat(heimdallApi.middleware),
  });
}

async function waitFor(predicate: () => boolean, act: any, ms = 2000) {
  const start = Date.now();
  while (!predicate()) {
    if (Date.now() - start > ms) throw new Error('waitFor timed out');
    await act(async () => {
      await new Promise((r) => setTimeout(r, 25));
    });
  }
}

test('per-pane chain switcher swaps THAT pane to the chain coordinator in place (URL, focus, aux, groups follow)', async () => {
  await withDom('#/conversations/a+b?focused=a', async (dom) => {
    const { createRoot } = await import('react-dom/client');
    const { act } = await import('react');
    const { Provider } = await import('react-redux');
    const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
    const layout = await import('../src/ui/store/workspaceLayoutSlice.ts');
    const { selectCurrentAuxTreeId } = await import('../src/ui/store/auxPanesSlice.ts');
    const { readGroupIndex } = await import('../src/ui/store/splitGroups.ts');
    const { Workspace } = await import('../src/ui/components/mainWorkspace/Workspace.tsx');
    const { ShortcutProvider } = await import('../src/ui/services/shortcuts/ShortcutContext.tsx');

    const store = await makeStore();
    const doc = dom.window.document;
    const root = createRoot(doc.getElementById('root')!);
    const paneOf = (agent: string) => layout.findPaneByAgent(store.getState().workspaceLayout.tree, agent);
    const frame = (paneId: string) => doc.querySelector(`[data-debug-id="main-pane-frame-${paneId}"]`)!;
    const openChainSelector = async (paneId: string) => {
      await waitFor(() => Boolean(frame(paneId)?.querySelector('[data-debug-id="conversation-thread-title"]')), act);
      await act(async () => {
        (frame(paneId).querySelector('[data-debug-id="conversation-thread-title"]') as any).click();
      });
    };
    const pickChain = async (chainId: string) => {
      await waitFor(() => Boolean(doc.querySelector(`[data-debug-id="chain-selector-item-${chainId}"]`)), act);
      await act(async () => {
        (doc.querySelector(`[data-debug-id="chain-selector-item-${chainId}"]`) as any).click();
        await new Promise((r) => setTimeout(r, 40));
      });
    };
    try {
      await act(async () => {
        root.render(React.createElement(
          Provider,
          { store },
          React.createElement(ShortcutProvider, {}, React.createElement(Workspace, {})),
        ));
        await new Promise((r) => setTimeout(r, 40));
      });
      assert.deepEqual(layout.selectMainAgentIds(store.getState()), ['a', 'b']);
      const aPane = paneOf('a')!;
      const bPane = paneOf('b')!;
      // Breadcrumbs are per pane.
      await waitFor(() => Boolean(frame(bPane)?.querySelector('[data-debug-id="conversation-chain-agent-switcher-btn"]')), act);
      assert.match(frame(aPane).textContent || '', /Agent A/);
      assert.match(frame(bPane).textContent || '', /Agent B/);

      // 1. Pick chain-3 in pane A -> A's pane now targets chain:chain-3 (showing
      //    coord-3), in place; pane B is untouched (REQ-TV2-7).
      await openChainSelector(aPane);
      await pickChain('chain-3');
      assert.equal(paneOf('chain:chain-3'), aPane, 'swapped in place (same pane id)');
      assert.deepEqual(layout.selectMainAgentIds(store.getState()), ['chain:chain-3', 'b']);
      assert.equal(layout.selectFocusedMainAgentId(store.getState()), 'chain:chain-3');
      assert.equal(dom.window.location.hash, '#/conversations/chain:chain-3+b?focused=chain:chain-3', 'URL pane set replaced, not collapsed');
      assert.deepEqual(selectCurrentAuxTreeId(store.getState()), { kind: 'chain', chainId: 'chain-3' });
      assert.deepEqual(readGroupIndex(), [['chain:chain-3', 'b']], 'old target evicted from the group, new one added');
      // The breadcrumb names the addressed chain.
      await waitFor(() => /Chain Three/.test(frame(aPane)?.querySelector('[data-debug-id="conversation-thread-title"]')?.textContent || ''), act);

      // 2. Picking chain-2 in pane A retargets pane A only, even though pane B
      //    holds chain-2's coordinator by instance: one leaf per TARGET.
      await openChainSelector(aPane);
      await pickChain('chain-2');
      assert.deepEqual(layout.selectMainAgentIds(store.getState()), ['chain:chain-2', 'b'], 'pane B never changes');
      assert.equal(paneOf('b'), bPane);
      assert.equal(layout.selectFocusedMainAgentId(store.getState()), 'chain:chain-2');
      // Picking the same chain from pane B focuses the pane that already targets it.
      await openChainSelector(bPane);
      await pickChain('chain-2');
      assert.deepEqual(layout.selectMainAgentIds(store.getState()), ['chain:chain-2', 'b'], 'no duplicate target');
      assert.equal(layout.selectFocusedMainAgentId(store.getState()), 'chain:chain-2');
      assert.equal(dom.window.location.hash, '#/conversations/chain:chain-2+b?focused=chain:chain-2');

      // 3. A chain without a coordinator keeps the fallback navigation to /chains/<id>.
      await openChainSelector(bPane);
      await pickChain('chain-4');
      assert.equal(dom.window.location.hash, '#/chains/chain-4');
    } finally {
      await act(async () => root.unmount());
      store.dispatch(heimdallApi.util.resetApiState());
    }
  });
});

test('task-chain chords replace the focused pane or open the selection right/below', async () => {
  const scenarios = [
    { keys: ['s', 'o', 't'], placement: 'replace', axis: null },
    { keys: ['s', 'o', 't', 'v'], placement: 'right', axis: 'horizontal' },
    { keys: ['s', 'o', 't', 'h'], placement: 'bottom', axis: 'vertical' },
  ] as const;

  for (const scenario of scenarios) {
    await withDom('#/conversations/a?focused=a', async (dom) => {
      const { createRoot } = await import('react-dom/client');
      const { act } = await import('react');
      const { Provider } = await import('react-redux');
      const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
      const layout = await import('../src/ui/store/workspaceLayoutSlice.ts');
      const { Workspace } = await import('../src/ui/components/mainWorkspace/Workspace.tsx');
      const { ShortcutProvider } = await import('../src/ui/services/shortcuts/ShortcutContext.tsx');

      const store = await makeStore();
      const doc = dom.window.document;
      const root = createRoot(doc.getElementById('root')!);
      const originalPane = () => layout.findPaneByAgent(store.getState().workspaceLayout.tree, 'a');
      try {
        await act(async () => {
          root.render(React.createElement(
            Provider,
            { store },
            React.createElement(ShortcutProvider, {}, React.createElement(Workspace, {})),
          ));
          await new Promise((resolve) => setTimeout(resolve, 40));
        });
        const paneId = originalPane()!;

        await act(async () => {
          for (const key of scenario.keys) {
            dom.window.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key, bubbles: true }));
          }
          if (scenario.placement === 'replace') {
            dom.window.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
          }
        });
        await waitFor(
          () => Boolean(doc.querySelector('[data-debug-id="chain-selector-item-chain-3"]')),
          act,
        );
        await act(async () => {
          (doc.querySelector('[data-debug-id="chain-selector-item-chain-3"]') as HTMLElement).click();
          await new Promise((resolve) => setTimeout(resolve, 40));
        });

        const tree = layout.selectMainTree(store.getState());
        if (scenario.placement === 'replace') {
          assert.deepEqual(layout.selectMainAgentIds(store.getState()), ['chain:chain-3']);
          assert.equal(layout.findPaneByAgent(tree, 'chain:chain-3'), paneId, 'replacement keeps the focused pane id');
        } else {
          assert.deepEqual(layout.selectMainAgentIds(store.getState()), ['a', 'chain:chain-3']);
          const rootPane = tree.panes[tree.rootPaneId];
          assert.equal(rootPane.kind === 'split' && rootPane.axis, scenario.axis);
        }
      } finally {
        await act(async () => root.unmount());
        store.dispatch(heimdallApi.util.resetApiState());
      }
    });
  }
});

test('auxiliary content chords toggle Tasks, Chat overview, and the focused agent PTY', async () => {
  await withDom('#/conversations/a?focused=a', async (dom) => {
    const { createRoot } = await import('react-dom/client');
    const { act } = await import('react');
    const { Provider } = await import('react-redux');
    const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
    const { selectAuxPane, selectAuxOpen } = await import('../src/ui/store/auxPanesSlice.ts');
    const { Workspace } = await import('../src/ui/components/mainWorkspace/Workspace.tsx');
    const { ChordHud } = await import('../src/ui/components/shortcuts/ChordHud.tsx');
    const { ShortcutProvider } = await import('../src/ui/services/shortcuts/ShortcutContext.tsx');

    const store = await makeStore();
    const doc = dom.window.document;
    const root = createRoot(doc.getElementById('root')!);
    const treeId = { kind: 'agent' as const, agentInstanceId: 'a' };
    const press = async (...keys: string[]) => {
      await act(async () => {
        for (const key of keys) {
          dom.window.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key, bubbles: true }));
        }
        await new Promise((resolve) => setTimeout(resolve, 40));
      });
    };
    try {
      await act(async () => {
        root.render(React.createElement(
          Provider,
          { store },
          React.createElement(
            ShortcutProvider,
            {},
            React.createElement(React.Fragment, {}, React.createElement(Workspace, {}), React.createElement(ChordHud)),
          ),
        ));
        await new Promise((resolve) => setTimeout(resolve, 40));
      });
      await waitFor(
        () => Boolean(doc.querySelector('[data-debug-id="conversation-thread-title"]')),
        act,
      );
      await waitFor(
        () => selectAuxPane(store.getState(), treeId)?.activeTabId === 'overview',
        act,
      );

      await press('s', 'a');
      let hud = doc.querySelector('[data-debug-id="shortcut-chord-hud"]');
      assert.match(hud?.textContent || '', /Tasks/);
      assert.match(hud?.textContent || '', /Chat overview/);
      assert.match(hud?.textContent || '', /Agent PTY/);
      assert.match(hud?.textContent || '', /esc close/i);
      assert.match(hud?.textContent || '', /enter run current/i);
      assert.equal(hud?.classList.contains('hidden'), false, 'helper is rendered on mobile widths');
      await act(async () => {
        await new Promise((resolve) => setTimeout(resolve, 1_300));
      });
      hud = doc.querySelector('[data-debug-id="shortcut-chord-hud"]');
      assert.ok(hud, 'helper remains visible beyond the former 1200ms timeout');
      await press('t');
      assert.equal(selectAuxPane(store.getState(), treeId)?.activeTabId, 'tasks');
      assert.equal(selectAuxOpen(store.getState()), true);

      await press('s', 'a');
      assert.ok(doc.querySelector('[data-debug-id="shortcut-chord-hud"]'));
      await press('Escape');
      assert.equal(doc.querySelector('[data-debug-id="shortcut-chord-hud"]'), null, 'Escape dismisses the helper');

      await press('s', 'a', 't');
      assert.equal(selectAuxOpen(store.getState()), false, 'same active target closes the dock');

      await press('s', 'a', 'c');
      assert.equal(selectAuxPane(store.getState(), treeId)?.activeTabId, 'overview');
      assert.equal(selectAuxOpen(store.getState()), true);

      // The HUD assertion above verifies that the focused-agent PTY action is
      // registered and enabled. Avoid opening it here: xterm requires browser
      // canvas APIs that jsdom intentionally does not implement.
    } finally {
      await act(async () => root.unmount());
      store.dispatch(heimdallApi.util.resetApiState());
    }
  });
});

test('per-pane agent switcher swaps THAT pane in place (deduped) and the URL/groups follow', async () => {
  await withDom('#/conversations/a+b?focused=b', async (dom) => {
    const { createRoot } = await import('react-dom/client');
    const { act } = await import('react');
    const { Provider } = await import('react-redux');
    const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
    const layout = await import('../src/ui/store/workspaceLayoutSlice.ts');
    const { readGroupIndex } = await import('../src/ui/store/splitGroups.ts');
    const { Workspace } = await import('../src/ui/components/mainWorkspace/Workspace.tsx');
    const { ShortcutProvider } = await import('../src/ui/services/shortcuts/ShortcutContext.tsx');

    const store = await makeStore();
    const root = createRoot(dom.window.document.getElementById('root')!);
    const settle = () => new Promise((r) => setTimeout(r, 40));
    try {
      await act(async () => {
        root.render(React.createElement(
          Provider,
          { store },
          React.createElement(ShortcutProvider, {}, React.createElement(Workspace, {})),
        ));
        await settle();
      });
      const aPane = layout.findPaneByAgent(store.getState().workspaceLayout.tree, 'a')!;
      // What AgentChatPane's onSwitchAgent dispatches for pane A.
      await act(async () => {
        store.dispatch(layout.assignMainPaneAgent({ paneId: aPane, agentInstanceId: 'a2' }));
        await settle();
      });
      assert.equal(layout.findPaneByAgent(store.getState().workspaceLayout.tree, 'a2'), aPane);
      assert.equal(layout.selectFocusedMainAgentId(store.getState()), 'a2');
      assert.equal(dom.window.location.hash, '#/conversations/a2+b?focused=a2');
      assert.deepEqual(readGroupIndex(), [['a2', 'b']]);
      // Switching pane A to an agent already in the split focuses it instead.
      await act(async () => {
        store.dispatch(layout.assignMainPaneAgent({ paneId: aPane, agentInstanceId: 'b' }));
        await settle();
      });
      assert.deepEqual(layout.selectMainAgentIds(store.getState()), ['a2', 'b']);
      assert.equal(dom.window.location.hash, '#/conversations/a2+b?focused=b');
    } finally {
      await act(async () => root.unmount());
      store.dispatch(heimdallApi.util.resetApiState());
    }
  });
});

test('s o a opens only the focused pane same-chain agent switcher and reuses in-place switching', async () => {
  await withDom('#/conversations/a+b?focused=b', async (dom) => {
    const { createRoot } = await import('react-dom/client');
    const { act } = await import('react');
    const { Provider } = await import('react-redux');
    const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
    const layout = await import('../src/ui/store/workspaceLayoutSlice.ts');
    const { Workspace } = await import('../src/ui/components/mainWorkspace/Workspace.tsx');
    const { ChordHud } = await import('../src/ui/components/shortcuts/ChordHud.tsx');
    const { ShortcutProvider } = await import('../src/ui/services/shortcuts/ShortcutContext.tsx');

    const store = await makeStore();
    const doc = dom.window.document;
    const root = createRoot(doc.getElementById('root')!);
    const settle = () => new Promise((resolve) => setTimeout(resolve, 40));
    const press = async (...keys: string[]) => {
      await act(async () => {
        for (const key of keys) {
          dom.window.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key, bubbles: true }));
        }
        await settle();
      });
    };

    try {
      await act(async () => {
        root.render(React.createElement(
          Provider,
          { store },
          React.createElement(
            ShortcutProvider,
            {},
            React.createElement(React.Fragment, {}, React.createElement(Workspace, {}), React.createElement(ChordHud)),
          ),
        ));
        await settle();
      });
      await waitFor(
        () => doc.querySelectorAll('[data-debug-id="conversation-chain-agent-switcher-btn"]').length === 2,
        act,
      );
      await waitFor(() => Object.values(
        (store.getState() as any)[heimdallApi.reducerPath].queries,
      ).filter((query: any) => (
        query.endpointName === 'fetchTaskChainDetail' && query.status === 'fulfilled'
      )).length === 2, act);
      await act(async () => settle());

      // Pane B starts focused, so its registration must win even though pane A
      // registered the same sequence first.
      await press('s', 'o');
      assert.match(doc.querySelector('[data-debug-id="shortcut-chord-hud"]')?.textContent || '', /Agents in this task chain/);
      await press('a');
      await waitFor(() => Boolean(doc.querySelector('[data-debug-id="conversation-chain-agent-option-b"]')), act);
      assert.equal(doc.querySelector('[data-debug-id="conversation-chain-agent-option-a"]'), null);
      assert.equal(doc.querySelector('[data-debug-id="conversation-chain-agent-option-a2"]'), null);

      // Selecting the current agent closes the modal without changing layout.
      await act(async () => {
        (doc.querySelector('[data-debug-id="conversation-chain-agent-option-b"]') as HTMLElement).click();
        await settle();
      });
      assert.deepEqual(layout.selectMainAgentIds(store.getState()), ['a', 'b']);

      // Focus pane A, reopen through the chord, and select its other chain member.
      const aPane = layout.findPaneByAgent(store.getState().workspaceLayout.tree, 'a')!;
      await act(async () => {
        store.dispatch(layout.setFocusedMainPane(aPane));
        await settle();
      });
      await press('s', 'o', 'a');
      await waitFor(() => Boolean(doc.querySelector('[data-debug-id="conversation-chain-agent-option-a2"]')), act);
      assert.ok(doc.querySelector('[data-debug-id="conversation-chain-agent-option-a"]'));
      assert.equal(doc.querySelector('[data-debug-id="conversation-chain-agent-option-b"]'), null);
      await act(async () => {
        (doc.querySelector('[data-debug-id="conversation-chain-agent-option-a2"]') as HTMLElement).click();
        await settle();
      });
      assert.deepEqual(layout.selectMainAgentIds(store.getState()), ['a2', 'b']);
      assert.equal(layout.findPaneByAgent(store.getState().workspaceLayout.tree, 'a2'), aPane);
      assert.equal(layout.selectFocusedMainAgentId(store.getState()), 'a2');
      assert.equal(dom.window.location.hash, '#/conversations/a2+b?focused=a2');
    } finally {
      await act(async () => root.unmount());
      store.dispatch(heimdallApi.util.resetApiState());
    }
  });
});

test('header switchers are wired to the pane (no route navigation for coordinators / chain members)', () => {
  const chat = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/workbench/AgentChatPane.tsx'), 'utf8');
  const agentOption = chat.slice(chat.indexOf('conversation-chain-agent-option-'), chat.indexOf('conversation-chain-agent-option-') + 1200);
  assert.match(agentOption, /onSwitchAgent\(memberTarget, member\.title\)/);
  // The coordinator member is addressed by chain (REQ-TV2-7).
  assert.match(agentOption, /member\.isCoordinator && chainId \? chainTargetId\(chainId\) : member\.agentInstanceId/);
  assert.match(chat, /onSelectChain=\{\s*onSwitchAgent/);
  const modal = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/chains/TaskChainSelectorModal.tsx'), 'utf8');
  assert.match(modal, /if \(onSelectChain\) \{\s*onSelectChain\(/);
});

test('fixed top-right cluster: one side-panel toggle (+ update badge) stays top-right with the dock open; content reserves its space', async () => {
  await withDom('#/conversations/a+b?focused=a', async (dom) => {
    const { createRoot } = await import('react-dom/client');
    const { act } = await import('react');
    const { Provider } = await import('react-redux');
    const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
    const layout = await import('../src/ui/store/workspaceLayoutSlice.ts');
    const { Workspace } = await import('../src/ui/components/mainWorkspace/Workspace.tsx');
    const { ShortcutProvider } = await import('../src/ui/services/shortcuts/ShortcutContext.tsx');
    const store = await makeStore();
    const doc = dom.window.document;
    const root = createRoot(doc.getElementById('root')!);
    const el = (id: string) => React.createElement('span', { 'data-debug-id': id });
    try {
      await act(async () => {
        root.render(
          React.createElement(
            Provider,
            { store },
            React.createElement(ShortcutProvider, {}, React.createElement(Workspace, {
              leading: el('left-spacer'),
              leadingWidth: 84,
              trailing: el('update-badge'),
            })),
          ),
        );
        await new Promise((r) => setTimeout(r, 40));
      });
      await waitFor(() => doc.querySelectorAll('[data-debug-id="conversation-chain-agent-switcher-btn"]').length === 2, act);
      const tree = store.getState().workspaceLayout.tree;
      const aFrame = doc.querySelector(`[data-debug-id="main-pane-frame-${layout.findPaneByAgent(tree, 'a')}"]`)!; // left
      const bFrame = doc.querySelector(`[data-debug-id="main-pane-frame-${layout.findPaneByAgent(tree, 'b')}"]`)!; // right
      assert.equal(doc.querySelector('[data-debug-id="workspace-top-bar"]'), null, 'no extra header bar');
      const cluster = doc.querySelector('[data-debug-id="workspace-top-right-cluster"]')!;
      const toggles = doc.querySelectorAll('[data-debug-id="workspace-aux-toggle"]');
      assert.equal(toggles.length, 1, 'exactly one side-panel toggle');
      assert.ok(cluster.contains(toggles[0]));
      assert.equal(cluster.lastElementChild, toggles[0], 'toggle is right-most');
      assert.ok(cluster.querySelector('[data-debug-id="update-badge"]'), 'update badge sits in the top-right cluster, left of the toggle');
      assert.equal(doc.querySelectorAll('[data-debug-id="conversation-right-panel-toggle-btn"]').length, 0);
      // The top-left pane reserves the fixed top-left cluster; the top-right pane reserves the top-right cluster.
      assert.ok(aFrame.querySelector('[data-debug-id="conversation-header-leading"] [data-debug-id="left-spacer"]'));
      assert.ok(bFrame.querySelector('[data-debug-id="conversation-thread-header"] [data-debug-id="workspace-top-right-spacer"]'));
      assert.equal(aFrame.querySelector('[data-debug-id="workspace-top-right-spacer"]'), null);

      await act(async () => {
        (toggles[0] as any).click();
        await new Promise((r) => setTimeout(r, 60));
      });
      await waitFor(() => doc.querySelector('[data-debug-id="aux-dock"]')?.getAttribute('data-aux-shown') === 'true', act);
      const dock = doc.querySelector('[data-debug-id="aux-dock"]')!;
      assert.ok(dock, 'toggle opens the side panel');
      assert.equal(dock.getAttribute('data-aux-tree'), 'agent:a', 'for the focused pane');
      assert.equal(dock.getAttribute('data-aux-shown'), 'true', 'slid open');
      // Still ONE toggle, still in the fixed top-right cluster (not in Main, not in the dock).
      assert.equal(doc.querySelectorAll('[data-debug-id="workspace-aux-toggle"]').length, 1);
      assert.ok(cluster.contains(doc.querySelector('[data-debug-id="workspace-aux-toggle"]')));
      assert.equal(dock.contains(cluster), false);
      // Now the aux tab strip reserves the cluster; the top-right Main pane no longer does.
      const strip = dock.querySelector('[data-debug-id^="aux-tab-strip-"]') as any;
      assert.ok(parseFloat(strip.style.paddingRight) > 0, 'aux strip reserves the top-right cluster');
      assert.equal(strip.style.paddingLeft, '', 'restored aux does not reserve the shell cluster');
      assert.equal(bFrame.querySelector('[data-debug-id="workspace-top-right-spacer"]'), null);
      assert.equal(doc.querySelector('[data-debug-id^="aux-close-dock-btn-"]'), null, 'no second close control on desktop');

      await act(async () => {
        (doc.querySelector('[data-debug-id^="aux-maximize-btn-"]') as any).click();
        await new Promise((r) => setTimeout(r, 20));
      });
      assert.equal(parseFloat(strip.style.paddingLeft), 84, 'maximized aux reserves the fixed top-left cluster');
      assert.ok(doc.querySelector('[data-debug-id="workspace-main"]')!.className.includes('hidden'));
      assert.ok(parseFloat(strip.style.paddingRight) > 0, 'maximized aux still reserves the top-right cluster');

      await act(async () => {
        (doc.querySelector('[data-debug-id^="aux-maximize-btn-"]') as any).click();
        await new Promise((r) => setTimeout(r, 20));
      });
      assert.equal(strip.style.paddingLeft, '', 'restoring aux removes the top-left reservation');

      // Close animates: the dock slides shut, then unmounts.
      await act(async () => {
        (doc.querySelector('[data-debug-id="workspace-aux-toggle"]') as any).click();
        await new Promise((r) => setTimeout(r, 20));
      });
      assert.equal(doc.querySelector('[data-debug-id="aux-dock"]')!.getAttribute('data-aux-shown'), 'false', 'sliding closed');
      await act(async () => {
        await new Promise((r) => setTimeout(r, 250));
      });
      assert.equal(doc.querySelector('[data-debug-id="aux-dock"]'), null, 'unmounted after the animation');

      // A focused new-chat pane has no side panel: the toggle is disabled.
      await act(async () => {
        store.dispatch(layout.splitMainPane({ targetPaneId: layout.findPaneByAgent(store.getState().workspaceLayout.tree, 'b')!, direction: 'right' }));
        await new Promise((r) => setTimeout(r, 40));
      });
      const t = doc.querySelectorAll('[data-debug-id="workspace-aux-toggle"]');
      assert.equal(t.length, 1);
      assert.equal((t[0] as any).disabled, true);
      // New panes animate in.
      assert.ok(doc.querySelector(`[data-debug-id="main-pane-frame-${store.getState().workspaceLayout.tree.focusedPaneId}"]`)!.className.includes('heimdall-pane-enter'));
    } finally {
      await act(async () => root.unmount());
      store.dispatch(heimdallApi.util.resetApiState());
    }
  });
});

test('split view: only the FOCUSED pane shows a close ✕; it closes that pane and the URL follows', async () => {
  await withDom('#/conversations/a+b?focused=b', async (dom) => {
    const { createRoot } = await import('react-dom/client');
    const { act } = await import('react');
    const { Provider } = await import('react-redux');
    const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
    const layout = await import('../src/ui/store/workspaceLayoutSlice.ts');
    const { Workspace } = await import('../src/ui/components/mainWorkspace/Workspace.tsx');
    const { ShortcutProvider } = await import('../src/ui/services/shortcuts/ShortcutContext.tsx');
    const store = await makeStore();
    const doc = dom.window.document;
    const root = createRoot(doc.getElementById('root')!);
    try {
      await act(async () => {
        root.render(React.createElement(
          Provider,
          { store },
          React.createElement(ShortcutProvider, {}, React.createElement(Workspace, {})),
        ));
        await new Promise((r) => setTimeout(r, 40));
      });
      await waitFor(() => doc.querySelectorAll('[data-debug-id="conversation-chain-agent-switcher-btn"]').length === 2, act);
      const bPane = layout.findPaneByAgent(store.getState().workspaceLayout.tree, 'b')!;
      const closes = doc.querySelectorAll('[data-debug-id="conversation-close-pane-btn"]');
      assert.equal(closes.length, 1, 'one ✕, on the focused pane only');
      assert.ok(doc.querySelector(`[data-debug-id="main-pane-frame-${bPane}"]`)!.contains(closes[0]));
      await act(async () => {
        (closes[0] as any).click();
        await new Promise((r) => setTimeout(r, 20));
      });
      assert.equal(doc.querySelector(`[data-debug-id="main-pane-frame-${bPane}"]`)!.getAttribute('data-main-pane-closing'), 'true', 'pane animates out first');
      await act(async () => {
        await new Promise((r) => setTimeout(r, 250));
      });
      assert.deepEqual(layout.selectMainAgentIds(store.getState()), ['a']);
      assert.equal(dom.window.location.hash, '#/conversations/a');
      assert.equal(doc.querySelectorAll('[data-debug-id="conversation-close-pane-btn"]').length, 0, 'no ✕ in single view');
    } finally {
      await act(async () => root.unmount());
      store.dispatch(heimdallApi.util.resetApiState());
    }
  });
});

test('workspace chords split, cycle, maximize, close, and remain shielded while typing', async () => {
  await withDom('#/conversations/a?focused=a', async (dom) => {
    const { createRoot } = await import('react-dom/client');
    const { act } = await import('react');
    const { Provider } = await import('react-redux');
    const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
    const layout = await import('../src/ui/store/workspaceLayoutSlice.ts');
    const { Workspace } = await import('../src/ui/components/mainWorkspace/Workspace.tsx');
    const { ShortcutProvider } = await import('../src/ui/services/shortcuts/ShortcutContext.tsx');
    const store = await makeStore();
    const root = createRoot(dom.window.document.getElementById('root')!);
    const settle = (ms = 50) => new Promise((resolve) => setTimeout(resolve, ms));
    const pressSequence = async (keys: readonly string[], target: EventTarget = dom.window) => {
      await act(async () => {
        for (const key of keys) {
          target.dispatchEvent(new dom.window.KeyboardEvent('keydown', { key, bubbles: true }));
        }
        await settle();
      });
    };
    const pressChord = (first: string, second: string, target: EventTarget = dom.window) => (
      pressSequence([first, second], target)
    );

    try {
      await act(async () => {
        root.render(React.createElement(
          Provider,
          { store },
          React.createElement(ShortcutProvider, {}, React.createElement(Workspace, {})),
        ));
        await settle();
      });

      await pressSequence(['s', 'n', 'c', 'v']);
      assert.equal(layout.selectMainPaneIds(store.getState()).length, 2, 's n c v splits right into the launcher');

      await pressSequence(['s', 'n', 'c', 'h']);
      assert.equal(layout.selectMainPaneIds(store.getState()).length, 3, 's n c h splits down into the launcher');

      const paneIds = layout.selectMainPaneIds(store.getState());
      const [leftPane, topRightPane, bottomRightPane] = paneIds;
      await pressChord('s', 'k');
      assert.equal(layout.selectMainTree(store.getState()).focusedPaneId, topRightPane, 's k focuses the pane above');
      await pressChord('s', 'h');
      assert.equal(layout.selectMainTree(store.getState()).focusedPaneId, leftPane, 's h focuses the pane left');
      await pressChord('s', 'l');
      assert.equal(layout.selectMainTree(store.getState()).focusedPaneId, topRightPane, 's l focuses the nearest pane right');
      await pressChord('s', 'j');
      assert.equal(layout.selectMainTree(store.getState()).focusedPaneId, bottomRightPane, 's j focuses the pane below');

      await waitFor(() => Boolean(dom.window.document.querySelector('[data-debug-id="new-convo-composer-input"]')), act);
      await pressChord('s', 'i');
      assert.equal(
        dom.window.document.activeElement?.getAttribute('data-debug-id'),
        'new-convo-composer-input',
        's i focuses the active pane input',
      );
      const composerInput = dom.window.document.activeElement as HTMLElement;
      await pressChord('s', 'm', composerInput);
      assert.equal(layout.selectMainTree(store.getState()).maximizedPaneId, null, 'typing shield blocks pane chords');
      await act(async () => {
        composerInput.dispatchEvent(new dom.window.KeyboardEvent('keydown', {
          key: 'Alt',
          altKey: true,
          ctrlKey: true,
          bubbles: true,
        }));
        await settle();
      });
      await pressChord('s', 'm', composerInput);
      assert.equal(
        layout.selectMainTree(store.getState()).maximizedPaneId,
        bottomRightPane,
        'Ctrl+Alt routes the next input chord through the manager',
      );
      await act(async () => (dom.window.document.activeElement as HTMLElement)?.blur());
      await pressChord('s', 'm');
      assert.equal(layout.selectMainTree(store.getState()).maximizedPaneId, null);

      await pressChord('s', 'h');
      assert.equal(layout.selectMainTree(store.getState()).focusedPaneId, leftPane);

      const workspace = dom.window.document.querySelector('[data-debug-id="workspace"]')!;
      const auxWasOpen = workspace.getAttribute('data-aux-open');
      await pressSequence(['s', 'a', 'Enter']);
      assert.notEqual(workspace.getAttribute('data-aux-open'), auxWasOpen, 's a toggles the focused agent aux pane');

      const beforeCycle = layout.selectMainTree(store.getState());
      const expectedNext = paneIds[(paneIds.indexOf(beforeCycle.focusedPaneId) + 1) % paneIds.length];
      await pressChord('s', 'w');
      assert.equal(layout.selectMainTree(store.getState()).focusedPaneId, expectedNext, 's w focuses next pane');

      await pressChord('s', 'm');
      assert.equal(layout.selectMainTree(store.getState()).maximizedPaneId, expectedNext, 's m maximizes focus');
      await pressChord('s', 'm');
      assert.equal(layout.selectMainTree(store.getState()).maximizedPaneId, null, 's m restores layout');

      await pressChord('s', 'x');
      await act(async () => settle(250));
      assert.equal(layout.selectMainPaneIds(store.getState()).length, 2, 's x closes focus in a split');
      await pressChord('s', 'x');
      await act(async () => settle(250));
      assert.equal(layout.selectMainPaneIds(store.getState()).length, 1);
      await pressChord('s', 'x');
      await act(async () => settle(250));
      assert.equal(layout.selectMainPaneIds(store.getState()).length, 1, 's x leaves the sole pane intact');
      await pressSequence(['s', 'n', 'c', 'Enter']);
      assert.equal(
        layout.selectFocusedMainAgentId(store.getState()),
        layout.NEW_PANE_AGENT_ID,
        's n c Enter replaces the focused pane with the new-conversation launcher',
      );

    } finally {
      await act(async () => root.unmount());
      store.dispatch(heimdallApi.util.resetApiState());
    }
  });
});

test('inside the aux dock, agent links open the agent chat as an aux tab instead of navigating Main', async () => {
  await withDom('#/conversations/a', async (dom) => {
    const { createRoot } = await import('react-dom/client');
    const { act } = await import('react');
    const { Provider } = await import('react-redux');
    const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
    const { InstanceIdLink } = await import('../src/ui/components/taskchain/TaskChainOverview.tsx');
    const { OpenAgentChatContext } = await import('../src/ui/components/auxiliary/openAgentChatContext.tsx');
    const store = await makeStore();
    const doc = dom.window.document;
    const root = createRoot(doc.getElementById('root')!);
    const opened: string[] = [];
    try {
      await act(async () => {
        root.render(
          React.createElement(
            Provider,
            { store },
            React.createElement(
              OpenAgentChatContext.Provider,
              { value: (id: string) => { opened.push(id); return true; } },
              React.createElement(InstanceIdLink, { instanceId: 'child-1', displayName: 'Child' }),
            ),
          ),
        );
      });
      await act(async () => {
        (doc.querySelector('[data-debug-id="taskchain-instance-link-child-1"]') as any).click();
      });
      assert.deepEqual(opened, ['child-1']);
      assert.equal(dom.window.location.hash, '#/conversations/a', 'Main is not navigated');
    } finally {
      await act(async () => root.unmount());
      store.dispatch(heimdallApi.util.resetApiState());
    }
  });
  const content = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/auxiliary/AuxTabContent.tsx'), 'utf8');
  assert.match(content, /onOpenTab\(\{ type: 'subagentChat', agentInstanceId \}, title\)/);
  assert.match(content, /onOpenAgentChat=\{\(agentInstanceId, title\) => \{\s*openAgentChat\(agentInstanceId, title\);/);
  assert.match(content, /<OpenAgentChatContext\.Provider value=\{openAgentChat\}>/);
});

// REQ-TV2-7 acceptance: two chains coordinated by the SAME durable agent
// (agt_shared) open side by side and each keeps its own chain context through
// focus switching, coordinator replacement, reload/workspace restore, a copied
// deep link in a new tab and hash navigation; a legacy link to the replaced
// coordinator still opens and offers the chain-addressed conversation.
test('two chain panes with the same durable coordinator agent keep their own chain context', async () => {
  const deepLink = '#/conversations/chain:chain-5+chain:chain-6?focused=chain:chain-5';
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const layout = await import('../src/ui/store/workspaceLayoutSlice.ts');
  const { selectCurrentAuxTreeId } = await import('../src/ui/store/auxPanesSlice.ts');
  const { readGroupIndex } = await import('../src/ui/store/splitGroups.ts');
  const { Workspace } = await import('../src/ui/components/mainWorkspace/Workspace.tsx');
  const { ShortcutProvider } = await import('../src/ui/services/shortcuts/ShortcutContext.tsx');
  const { createRoot } = await import('react-dom/client');
  const { act } = await import('react');
  const { Provider } = await import('react-redux');

  const mount = async (dom: any) => {
    const store = await makeStore();
    const root = createRoot(dom.window.document.getElementById('root')!);
    await act(async () => {
      root.render(React.createElement(Provider, { store },
        React.createElement(ShortcutProvider, {}, React.createElement(Workspace, {}))));
      await new Promise((r) => setTimeout(r, 40));
    });
    const doc = dom.window.document;
    const paneOf = (target: string) => layout.findPaneByAgent(store.getState().workspaceLayout.tree, target)!;
    const frame = (target: string) => doc.querySelector(`[data-debug-id="main-pane-frame-${paneOf(target)}"]`) as any;
    const coordinatorIn = (target: string) =>
      frame(target)?.querySelector('[data-coordinator-instance-id]')?.getAttribute('data-coordinator-instance-id') || '';
    const crumb = (target: string) =>
      frame(target)?.querySelector('[data-debug-id="conversation-thread-title"]')?.textContent || '';
    const unmount = async () => {
      await act(async () => root.unmount());
      store.dispatch(heimdallApi.util.resetApiState());
    };
    return { store, doc, paneOf, frame, coordinatorIn, crumb, unmount };
  };

  COORDINATORS['chain-6'] = 'coord-6x';
  delete REPLACED['chain-6'];
  try {
    await withDom(deepLink, async (dom) => {
      let ui = await mount(dom);
      try {
        // Both panes open, each resolved to ITS chain's coordinator, breadcrumbs per chain.
        assert.deepEqual(layout.selectMainAgentIds(ui.store.getState()), ['chain:chain-5', 'chain:chain-6']);
        await waitFor(() => ui.coordinatorIn('chain:chain-5') === 'coord-5x' && ui.coordinatorIn('chain:chain-6') === 'coord-6x', act);
        await waitFor(() => /Chain Five/.test(ui.crumb('chain:chain-5')) && /Chain Six/.test(ui.crumb('chain:chain-6')), act);
        assert.deepEqual(selectCurrentAuxTreeId(ui.store.getState()), { kind: 'chain', chainId: 'chain-5' });

        // Focus switching selects which pane's dock shows; it never retargets a pane.
        await act(async () => {
          ui.store.dispatch(layout.setFocusedMainPane(ui.paneOf('chain:chain-6')));
          await new Promise((r) => setTimeout(r, 40));
        });
        assert.deepEqual(selectCurrentAuxTreeId(ui.store.getState()), { kind: 'chain', chainId: 'chain-6' });
        assert.deepEqual(layout.selectMainAgentIds(ui.store.getState()), ['chain:chain-5', 'chain:chain-6']);
        assert.equal(dom.window.location.hash, '#/conversations/chain:chain-5+chain:chain-6?focused=chain:chain-6');
        assert.equal(ui.coordinatorIn('chain:chain-5'), 'coord-5x');

        // Replacing chain-6's coordinator re-resolves pane B only; the URL is unchanged.
        COORDINATORS['chain-6'] = 'coord-6y';
        REPLACED['chain-6'] = ['coord-6x'];
        await act(async () => {
          ui.store.dispatch(heimdallApi.util.invalidateTags([{ type: 'Chain', id: 'chain-6' }]));
        });
        await waitFor(() => ui.coordinatorIn('chain:chain-6') === 'coord-6y', act);
        assert.equal(ui.coordinatorIn('chain:chain-5'), 'coord-5x');
        assert.equal(dom.window.location.hash, '#/conversations/chain:chain-5+chain:chain-6?focused=chain:chain-6');
        assert.deepEqual(readGroupIndex(), [['chain:chain-5', 'chain:chain-6']]);

        // Hash navigation (as back/forward does): a single chain-6 link restores the saved group.
        await act(async () => {
          dom.window.location.hash = '#/conversations/chain:chain-6';
          await new Promise((r) => setTimeout(r, 60));
        });
        await waitFor(() => dom.window.location.hash === '#/conversations/chain:chain-5+chain:chain-6?focused=chain:chain-6', act);

        // Reload (fresh store, same URL + storage) restores the same targets.
        await ui.unmount();
        ui = await mount(dom);
        assert.deepEqual(layout.selectMainAgentIds(ui.store.getState()), ['chain:chain-5', 'chain:chain-6']);
        assert.equal(layout.selectFocusedMainAgentId(ui.store.getState()), 'chain:chain-6');
        await waitFor(() => ui.coordinatorIn('chain:chain-6') === 'coord-6y' && ui.coordinatorIn('chain:chain-5') === 'coord-5x', act);
      } finally {
        await ui.unmount();
      }
    });

    // A copied deep link in a new tab (no shared storage) opens the same chain panes.
    await withDom(deepLink, async (dom) => {
      const ui = await mount(dom);
      try {
        assert.deepEqual(layout.selectMainAgentIds(ui.store.getState()), ['chain:chain-5', 'chain:chain-6']);
        await waitFor(() => ui.coordinatorIn('chain:chain-5') === 'coord-5x' && ui.coordinatorIn('chain:chain-6') === 'coord-6y', act);
      } finally {
        await ui.unmount();
      }
    });

    // The legacy link to the replaced coordinator still opens, and offers the chain URL.
    await withDom('#/conversations/coord-6x', async (dom) => {
      const ui = await mount(dom);
      try {
        assert.deepEqual(layout.selectMainAgentIds(ui.store.getState()), ['coord-6x']);
        const banner = () => ui.frame('coord-6x')?.querySelector('[data-debug-id="conversation-open-chain-coordinator-btn"]');
        await waitFor(() => Boolean(banner()), act);
        await act(async () => {
          banner().click();
          await new Promise((r) => setTimeout(r, 40));
        });
        assert.deepEqual(layout.selectMainAgentIds(ui.store.getState()), ['chain:chain-6']);
        assert.equal(dom.window.location.hash, '#/conversations/chain:chain-6');
      } finally {
        await ui.unmount();
      }
    });

    // A legacy link to a CURRENT coordinator gets no banner.
    await withDom('#/conversations/coord-5x', async (dom) => {
      const ui = await mount(dom);
      try {
        await waitFor(() => Boolean(ui.frame('coord-5x')?.querySelector('[data-debug-id="conversation-thread-title"]')), act);
        await new Promise((r) => setTimeout(r, 100));
        assert.equal(ui.frame('coord-5x').querySelector('[data-debug-id="conversation-replaced-coordinator"]'), null);
      } finally {
        await ui.unmount();
      }
    });
  } finally {
    COORDINATORS['chain-6'] = 'coord-6x';
    delete REPLACED['chain-6'];
  }
});
