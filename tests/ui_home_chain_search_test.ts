import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import React from 'react';

import { coordinatorFromChainDetail } from '../src/ui/utils/chainConversation.ts';
import {
  HOME_RECENT_CHAIN_LIMIT,
  filterHomeChains,
  flattenRecentChains,
  homeChainsFromSearchHits,
} from '../src/ui/components/home/homeChainSearchLogic.ts';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

function chain(id: string, updatedAt: string, extra: Record<string, unknown> = {}) {
  return {
    chainId: id,
    title: `Title ${id}`,
    status: 'active',
    updatedAt,
    coordinatorAgentInstanceId: `coord-${id}`,
    projectId: '',
    ...extra,
  } as any;
}

test('home chains: flat (ungrouped), newest first, archived excluded, capped at 10', () => {
  const groups = [
    { projectId: 'p1', projectName: 'One', chains: [chain('a', '2026-01-01'), chain('b', '2026-03-01')] },
    { projectId: 'p2', projectName: 'Two', chains: [chain('c', '2026-02-01'), chain('d', '2026-04-01', { status: 'archived' })] },
    { projectId: 'p3', projectName: 'Archived project', chains: [chain('e', '2026-05-01')] },
  ] as any;
  const flat = flattenRecentChains(groups, new Set(['p3']));
  assert.deepEqual(flat.map((c) => c.chainId), ['b', 'c', 'a']);
  assert.equal(flat[0].projectName, 'One');
  assert.equal(flat[0].coordinatorAgentInstanceId, 'coord-b');

  const many = Array.from({ length: 15 }, (_, i) => chain(`x${i}`, `2026-01-${String(i + 1).padStart(2, '0')}`));
  const top = filterHomeChains(flattenRecentChains([{ projectId: 'p', projectName: 'P', chains: many }] as any), '');
  assert.equal(top.length, HOME_RECENT_CHAIN_LIMIT);
  assert.equal(top[0].chainId, 'x14');
});

test('home chain local search is vault-safe and matches decrypted titles, ids and project names', () => {
  const items = flattenRecentChains([
    {
      projectId: 'p1',
      projectName: 'Apollo',
      chains: [chain('c1', '2026-01-02', { title: 'vault:v2:7e57000000000001:e1:abcdef' }), chain('c2', '2026-01-01', { title: 'Release train' })],
    },
  ] as any);
  assert.deepEqual(filterHomeChains(items, 'vault').map((c) => c.chainId), []);
  assert.deepEqual(filterHomeChains(items, 'secret', { c1: { decryptedTitle: 'Secret plan' } }).map((c) => c.chainId), ['c1']);
  assert.deepEqual(filterHomeChains(items, 'release').map((c) => c.chainId), ['c2']);
  assert.deepEqual(filterHomeChains(items, 'apollo').map((c) => c.chainId), ['c1', 'c2']);
  assert.deepEqual(filterHomeChains(items, 'c2').map((c) => c.chainId), ['c2']);
});

test('bridge search hits get the coordinator and project name from the loaded list', () => {
  const loaded = flattenRecentChains([{ projectId: 'p1', projectName: 'One', chains: [chain('a', '2026-01-01')] }] as any);
  const rows = homeChainsFromSearchHits(
    [
      { chain_id: 'a', project_id: 'p1', status: 'active', updated_at: '2026-01-05', title: 'Alpha', description: '' },
      { chain_id: 'zz', project_id: 'p1', status: 'completed', updated_at: '', title: 'Unknown', description: '' },
    ],
    loaded,
  );
  assert.equal(rows[0].coordinatorAgentInstanceId, 'coord-a');
  assert.equal(rows[0].title, 'Alpha');
  assert.equal(rows[1].coordinatorAgentInstanceId, undefined);
  assert.equal(rows[1].projectName, 'One');
});

const GROUPS = [
  {
    project_id: 'p1',
    project_name: 'Proj',
    chains: [
      { chain_id: 'chain-3', title: 'Chain Three', status: 'active', coordinator_agent_instance_id: 'coord-3', project_id: 'p1', updated_at: '2026-10-10T00:00:00Z' },
      { chain_id: 'chain-4', title: 'Chain Four', status: 'active', coordinator_agent_instance_id: '', project_id: 'p1', updated_at: '2026-10-09T00:00:00Z' },
    ],
  },
];

// chain-4's list row has no coordinator; the canonical one is its member with role 'coordinator'.
const DETAILS: Record<string, any> = {
  'chain-4': {
    chain_id: 'chain-4',
    title: 'Chain Four',
    coordinator_agent_instance_id: '',
    members: [
      { chain_id: 'chain-4', agent_instance_id: 'worker-4', role: 'worker' },
      { chain_id: 'chain-4', agent_instance_id: 'coord-4', role: 'coordinator' },
    ],
  },
};

async function withDom<T>(hash: string, fn: (dom: any) => Promise<T>): Promise<T> {
  const { JSDOM } = await import('jsdom');
  const dom = new JSDOM('<!DOCTYPE html><html><body><div id="root"></div></body></html>', { url: `http://localhost/${hash}` });
  (dom.window.HTMLElement.prototype as any).scrollTo = () => {};
  (dom.window.HTMLElement.prototype as any).scrollIntoView = () => {};
  (dom.window as any).matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} });
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
  const prevRO = (globalThis as any).ResizeObserver;
  class RO { observe() {} unobserve() {} disconnect() {} }
  (globalThis as any).ResizeObserver = RO;
  (dom.window as any).ResizeObserver = RO;
  const prevRaf = [(globalThis as any).requestAnimationFrame, (globalThis as any).cancelAnimationFrame];
  (globalThis as any).requestAnimationFrame = (cb: any) => setTimeout(() => cb(Date.now()), 0) as any;
  (globalThis as any).cancelAnimationFrame = (id: any) => clearTimeout(id);
  (globalThis as any).fetch = async (input: any) => {
    const url = String(input?.url ?? input);
    const detail = url.match(/\/task-chains\/([^/?]+)$/);
    const body = /\/task-chains(\?|$)/.test(url)
      ? { groups: GROUPS }
      : detail
        ? { data: DETAILS[decodeURIComponent(detail[1])] || { chain_id: detail[1], members: [] } }
        : { data: [] };
    return { ok: true, status: 200, headers: { get: () => 'application/json' }, text: async () => JSON.stringify(body), json: async () => body } as any;
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
    (globalThis as any).ResizeObserver = prevRO;
    (globalThis as any).requestAnimationFrame = prevRaf[0];
    (globalThis as any).cancelAnimationFrame = prevRaf[1];
  }
}

async function makeStore() {
  const { configureStore } = await import('@reduxjs/toolkit');
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const { default: vault } = await import('../src/ui/store/vaultSlice.ts');
  const { default: workspaceLayout } = await import('../src/ui/store/workspaceLayoutSlice.ts');
  const { default: auxPanes } = await import('../src/ui/store/auxPanesSlice.ts');
  const { default: workspaceChrome } = await import('../src/ui/store/workspaceChromeSlice.ts');
  const { default: searchTitle } = await import('../src/ui/store/searchTitleSlice.ts');
  return configureStore({
    reducer: {
      vault,
      workspaceLayout,
      auxPanes,
      workspaceChrome,
      searchTitle,
      chat: (s: any = { session: { daemonUrl: 'http://127.0.0.1:7777', clientToken: 'tok_test' } }) => s,
      [heimdallApi.reducerPath]: heimdallApi.reducer,
    },
    middleware: (g: any) => g({ serializableCheck: false, immutableCheck: false }).concat(heimdallApi.middleware),
  });
}

async function waitFor(predicate: () => boolean, act: any, ms = 3000) {
  const start = Date.now();
  while (!predicate()) {
    if (Date.now() - start > ms) throw new Error('waitFor timed out');
    await act(async () => {
      await new Promise((r) => setTimeout(r, 25));
    });
  }
}

test('a new Main pane renders the home view; picking a recent task chain fills THAT pane', async () => {
  await withDom('#/conversations/a+_new?focused=_new', async (dom) => {
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
      const newPane = layout.findPaneByAgent(store.getState().workspaceLayout.tree, 'a') === 'pane-1' ? 'pane-2' : 'pane-1';
      const frame = () => doc.querySelector(`[data-debug-id="main-pane-frame-${newPane}"]`)!;
      assert.ok(frame().querySelector('[data-debug-id="home-page-pane"]'), 'the _new pane shows the home view');
      assert.ok(frame().querySelector('[data-debug-id="new-convo-composer-shell"]'), 'with the new-conversation composer');
      assert.ok(frame().querySelector('[data-debug-id="home-chain-search-input"]'), 'and the task chain search bar');
      assert.equal(frame().querySelector('[data-debug-id="home-section-buttons"]'), null, 'global home sections are omitted in a pane');

      await waitFor(() => Boolean(frame().querySelector('[data-debug-id="home-chain-row-chain-3"]')), act);
      await act(async () => {
        (frame().querySelector('[data-debug-id="home-chain-row-chain-3"]') as any).click();
        await new Promise((r) => setTimeout(r, 40));
      });
      assert.equal(layout.findPaneByAgent(store.getState().workspaceLayout.tree, 'coord-3'), newPane, 'coordinator put into the new pane');
      assert.deepEqual(layout.selectMainAgentIds(store.getState()), ['a', 'coord-3']);
      assert.equal(dom.window.location.hash, '#/conversations/a+coord-3?focused=coord-3');
    } finally {
      await act(async () => root.unmount());
      store.dispatch(heimdallApi.util.resetApiState());
    }
  });
});

test('home page (route): search bar + last chains, flat; a row opens the coordinator conversation', async () => {
  await withDom('#/home', async (dom) => {
    const { createRoot } = await import('react-dom/client');
    const { act } = await import('react');
    const { Provider } = await import('react-redux');
    const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
    const { HomePage } = await import('../src/ui/components/home/HomePage.tsx');
    const store = await makeStore();
    const doc = dom.window.document;
    const root = createRoot(doc.getElementById('root')!);
    try {
      await act(async () => {
        root.render(React.createElement(Provider, { store }, React.createElement(HomePage, {})));
        await new Promise((r) => setTimeout(r, 40));
      });
      assert.ok(doc.querySelector('[data-debug-id="home-chain-search-input"]'));
      assert.equal(doc.querySelector('[data-debug-id="home-tab-chains"]'), null, 'the Recent tasks tab is replaced');
      assert.ok(doc.querySelector('[data-debug-id="home-tab-issues"]'));
      await waitFor(() => Boolean(doc.querySelector('[data-debug-id="home-chain-row-chain-4"]')), act);
      const rows = Array.from(doc.querySelectorAll('[data-debug-id^="home-chain-row-"]')).map((el: any) => el.getAttribute('data-debug-id'));
      assert.deepEqual(rows, ['home-chain-row-chain-3', 'home-chain-row-chain-4'], 'newest first, no project grouping headers');
      await act(async () => {
        (doc.querySelector('[data-debug-id="home-chain-row-chain-3"]') as any).click();
      });
      assert.equal(dom.window.location.hash, '#/conversations/coord-3');
      // Local search filters the list.
      const input = doc.querySelector('[data-debug-id="home-chain-search-input"]') as any;
      await act(async () => {
        const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, 'value')!.set!;
        setter.call(input, 'four');
        input.dispatchEvent(new dom.window.Event('input', { bubbles: true }));
        await new Promise((r) => setTimeout(r, 20));
      });
      assert.deepEqual(
        Array.from(doc.querySelectorAll('[data-debug-id^="home-chain-row-"]')).map((el: any) => el.getAttribute('data-debug-id')),
        ['home-chain-row-chain-4'],
      );
    } finally {
      await act(async () => root.unmount());
      store.dispatch(heimdallApi.util.resetApiState());
    }
  });
});

test('launching from a pane fills that pane instead of navigating', () => {
  const page = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/chat/NewConversationPage.tsx'), 'utf8');
  assert.match(page, /if \(onLaunched\) onLaunched\(id\);\s*else window\.location\.hash/);
  const home = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/home/HomePage.tsx'), 'utf8');
  assert.match(home, /<NewConversationPage embedded launchIntent=\{pane\.launchIntent\} onLaunched=\{pane\.onOpenAgent\}/);
  const ws = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/mainWorkspace/Workspace.tsx'), 'utf8');
  assert.match(ws, /onOpenAgent: \(agentInstanceId\) =>\s*dispatch\(assignMainPaneAgent\(\{ paneId, agentInstanceId \}\)\)/);
});

test('coordinatorFromChainDetail: column first, else the member with role coordinator', () => {
  assert.equal(coordinatorFromChainDetail({ coordinatorAgentInstanceId: 'c1', members: [] }), 'c1');
  assert.equal(
    coordinatorFromChainDetail({ coordinatorAgentInstanceId: '', members: [{ agentInstanceId: 'w', role: 'worker' }, { agentInstanceId: 'k', role: 'Coordinator' }] }),
    'k',
  );
  assert.equal(coordinatorFromChainDetail({ members: [{ agentInstanceId: 'w', role: 'worker' }] }), '');
  assert.equal(coordinatorFromChainDetail(null), '');
});

test('a recent chain whose list row lacks the coordinator still opens its conversation (resolved from chain detail)', async () => {
  await withDom('#/home', async (dom) => {
    const { createRoot } = await import('react-dom/client');
    const { act } = await import('react');
    const { Provider } = await import('react-redux');
    const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
    const { HomePage } = await import('../src/ui/components/home/HomePage.tsx');
    const store = await makeStore();
    const doc = dom.window.document;
    const root = createRoot(doc.getElementById('root')!);
    try {
      await act(async () => {
        root.render(React.createElement(Provider, { store }, React.createElement(HomePage, {})));
        await new Promise((r) => setTimeout(r, 40));
      });
      await waitFor(() => Boolean(doc.querySelector('[data-debug-id="home-chain-row-chain-4"]')), act);
      await act(async () => {
        (doc.querySelector('[data-debug-id="home-chain-row-chain-4"]') as any).click();
        await new Promise((r) => setTimeout(r, 60));
      });
      assert.equal(dom.window.location.hash, '#/conversations/coord-4', 'opens the coordinator conversation, not the chain page');
    } finally {
      await act(async () => root.unmount());
      store.dispatch(heimdallApi.util.resetApiState());
    }
  });
});
