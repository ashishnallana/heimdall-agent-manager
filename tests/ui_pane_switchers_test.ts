import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import React from 'react';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

// Agents: a (chain-1), b (chain-2), coord-3 (coordinator of chain-3), chain-4 has no coordinator.
const CONVERSATIONS: Record<string, any> = {
  a: { conversation_id: 'conv-a', agent_instance_id: 'a', chain_id: 'chain-1', project_id: 'p1', title: 'Agent A' },
  b: { conversation_id: 'conv-b', agent_instance_id: 'b', chain_id: 'chain-2', project_id: 'p1', title: 'Agent B' },
  'coord-3': { conversation_id: 'conv-c3', agent_instance_id: 'coord-3', chain_id: 'chain-3', project_id: 'p1', title: 'Coord 3' },
};
const GROUPS = [
  {
    project_id: 'p1',
    project_name: 'Proj',
    chains: [
      { chain_id: 'chain-2', title: 'Chain Two', status: 'active', coordinator_agent_instance_id: 'b', project_id: 'p1' },
      { chain_id: 'chain-3', title: 'Chain Three', status: 'active', coordinator_agent_instance_id: 'coord-3', project_id: 'p1' },
      { chain_id: 'chain-4', title: 'Chain Four', status: 'active', coordinator_agent_instance_id: '', project_id: 'p1' },
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
  (dom.window as any).matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} });
  (globalThis as any).fetch = async (input: any) => {
    const url = String(input?.url ?? input);
    const byInstance = url.match(/\/chats\/by-instance\/([^/?]+)/);
    if (byInstance) {
      const conv = CONVERSATIONS[decodeURIComponent(byInstance[1])];
      return conv ? json({ data: conv }) : json({ error: 'nope' }, false);
    }
    if (/\/task-chains(\?|$)/.test(url)) return json({ groups: GROUPS });
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
    [(globalThis as any).ResizeObserver, (globalThis as any).requestAnimationFrame, (globalThis as any).cancelAnimationFrame] = prevEnv;
  }
}

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
        root.render(React.createElement(Provider, { store }, React.createElement(Workspace, {})));
        await new Promise((r) => setTimeout(r, 40));
      });
      assert.deepEqual(layout.selectMainAgentIds(store.getState()), ['a', 'b']);
      const aPane = paneOf('a')!;
      const bPane = paneOf('b')!;
      // Breadcrumbs are per pane.
      await waitFor(() => Boolean(frame(bPane)?.querySelector('[data-debug-id="conversation-chain-agent-switcher-btn"]')), act);
      assert.match(frame(aPane).textContent || '', /Agent A/);
      assert.match(frame(bPane).textContent || '', /Agent B/);

      // 1. Pick chain-3 in pane A -> A's pane now shows coord-3, in place.
      await openChainSelector(aPane);
      await pickChain('chain-3');
      assert.equal(paneOf('coord-3'), aPane, 'swapped in place (same pane id)');
      assert.deepEqual(layout.selectMainAgentIds(store.getState()), ['coord-3', 'b']);
      assert.equal(layout.selectFocusedMainAgentId(store.getState()), 'coord-3');
      assert.equal(dom.window.location.hash, '#/conversations/coord-3+b?focused=coord-3', 'URL pane set replaced, not collapsed');
      assert.deepEqual(selectCurrentAuxTreeId(store.getState()), { kind: 'agent', agentInstanceId: 'coord-3' });
      assert.deepEqual(readGroupIndex(), [['coord-3', 'b']], 'old agent evicted from the group, new one added');

      // 2. Picking a chain whose coordinator is already in the split focuses that pane.
      await openChainSelector(aPane);
      await pickChain('chain-2');
      assert.deepEqual(layout.selectMainAgentIds(store.getState()), ['coord-3', 'b'], 'no duplicate');
      assert.equal(layout.selectFocusedMainAgentId(store.getState()), 'b');
      assert.equal(dom.window.location.hash, '#/conversations/coord-3+b?focused=b');

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

test('per-pane agent switcher swaps THAT pane in place (deduped) and the URL/groups follow', async () => {
  await withDom('#/conversations/a+b?focused=b', async (dom) => {
    const { createRoot } = await import('react-dom/client');
    const { act } = await import('react');
    const { Provider } = await import('react-redux');
    const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
    const layout = await import('../src/ui/store/workspaceLayoutSlice.ts');
    const { readGroupIndex } = await import('../src/ui/store/splitGroups.ts');
    const { Workspace } = await import('../src/ui/components/mainWorkspace/Workspace.tsx');

    const store = await makeStore();
    const root = createRoot(dom.window.document.getElementById('root')!);
    const settle = () => new Promise((r) => setTimeout(r, 40));
    try {
      await act(async () => {
        root.render(React.createElement(Provider, { store }, React.createElement(Workspace, {})));
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

test('header switchers are wired to the pane (no route navigation for coordinators / chain members)', () => {
  const chat = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/workbench/AgentChatPane.tsx'), 'utf8');
  const agentOption = chat.slice(chat.indexOf('conversation-chain-agent-option-'), chat.indexOf('conversation-chain-agent-option-') + 1200);
  assert.match(agentOption, /onSwitchAgent\(member\.agentInstanceId, member\.title\)/);
  assert.match(chat, /onSelectChain=\{\s*onSwitchAgent/);
  const modal = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/chains/TaskChainSelectorModal.tsx'), 'utf8');
  assert.match(modal, /if \(onSelectChain\) \{\s*onSelectChain\(/);
});

test('exactly ONE side-panel toggle, top-right in the workspace top bar, never inside a pane or the aux dock', async () => {
  await withDom('#/conversations/a+b?focused=a', async (dom) => {
    const { createRoot } = await import('react-dom/client');
    const { act } = await import('react');
    const { Provider } = await import('react-redux');
    const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
    const layout = await import('../src/ui/store/workspaceLayoutSlice.ts');
    const { Workspace } = await import('../src/ui/components/mainWorkspace/Workspace.tsx');
    const store = await makeStore();
    const doc = dom.window.document;
    const root = createRoot(doc.getElementById('root')!);
    try {
      await act(async () => {
        root.render(React.createElement(Provider, { store }, React.createElement(Workspace, { leading: React.createElement('span', { 'data-debug-id': 'lead' }) })));
        await new Promise((r) => setTimeout(r, 40));
      });
      await waitFor(() => doc.querySelectorAll('[data-debug-id="conversation-chain-agent-switcher-btn"]').length === 2, act);
      // Two chat headers, but no per-pane toggles.
      assert.equal(doc.querySelectorAll('[data-debug-id="conversation-right-panel-toggle-btn"]').length, 0);
      const toggles = doc.querySelectorAll('[data-debug-id="workspace-aux-toggle"]');
      assert.equal(toggles.length, 1);
      const bar = doc.querySelector('[data-debug-id="workspace-top-bar"]')!;
      assert.ok(bar.contains(toggles[0]));
      assert.ok(bar.querySelector('[data-debug-id="lead"]'), 'hidden-sidebar control shares the bar (left)');
      assert.equal(bar.lastElementChild, toggles[0], 'the toggle is the right-most control');

      await act(async () => {
        (toggles[0] as any).click();
        await new Promise((r) => setTimeout(r, 40));
      });
      const dock = doc.querySelector('[data-debug-id="aux-dock"]')!;
      assert.ok(dock, 'toggle opens the side panel');
      assert.equal(dock.getAttribute('data-aux-tree'), 'agent:a', 'for the focused pane');
      // In-flow layout: the bar is a sibling above the Main/aux row, so nothing overlaps it.
      assert.equal(bar.contains(dock), false);
      assert.equal(dock.parentElement, doc.querySelector('[data-debug-id="workspace-main"]')!.parentElement);
      assert.equal(bar.parentElement, dock.parentElement!.parentElement);
      assert.equal(doc.querySelectorAll('[data-debug-id="workspace-aux-toggle"]').length, 1, 'still one toggle with the dock open');
      assert.equal(doc.querySelector('[data-debug-id^="aux-close-dock-btn-"]'), null, 'no second close control on desktop');

      // A focused new-chat pane has no side panel: the toggle is disabled.
      await act(async () => {
        store.dispatch(layout.splitMainPane({ targetPaneId: layout.findPaneByAgent(store.getState().workspaceLayout.tree, 'a')!, direction: 'right' }));
        await new Promise((r) => setTimeout(r, 40));
      });
      assert.equal((doc.querySelector('[data-debug-id="workspace-aux-toggle"]') as any).disabled, true);
    } finally {
      await act(async () => root.unmount());
      store.dispatch(heimdallApi.util.resetApiState());
    }
  });
});
