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
  homeChainsFromFlatList,
  homeChainPage,
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

type Fixture = {
  chains?: any[];
  projects?: any[];
  requests?: string[];
  fetch?: (url: string, init: any) => any;
};

function jsonResponse(body: any, status = 200): any {
  return { ok: status < 400, status, headers: { get: () => 'application/json' }, text: async () => JSON.stringify(body), json: async () => body };
}

async function withDom<T>(hash: string, fn: (dom: any) => Promise<T>, fixture: Fixture = {}): Promise<T> {
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
  (globalThis as any).fetch = async (input: any, init: any) => {
    const url = String(input?.url ?? input);
    fixture.requests?.push(url);
    const custom = await fixture.fetch?.(url, init);
    if (custom !== undefined) return custom;
    const detail = url.match(/\/task-chains\/([^/?]+)$/);
    const body = /\/task-chains\?flat=1$/.test(url)
      ? { data: fixture.chains ?? GROUPS.flatMap((g) => g.chains.map((c) => ({ ...c, project_name: g.project_name }))) }
      : /\/task-chains(\?|$)/.test(url)
        ? { groups: GROUPS }
        : detail
          ? { data: DETAILS[decodeURIComponent(detail[1])] || { chain_id: detail[1], members: [] } }
          : /\/projects(\?|$)/.test(url)
            ? { data: fixture.projects || [] }
            : { data: [] };
    return jsonResponse(body);
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
  const { vaultCacheInvalidationMiddleware } = await import('../src/ui/api/vaultCacheInvalidation.ts');
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
    middleware: (g: any) => g({ serializableCheck: false, immutableCheck: false }).concat(vaultCacheInvalidationMiddleware, heimdallApi.middleware),
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
      // REQ-TV2-7: the chain is addressed by chain, not by its coordinator instance.
      assert.equal(layout.findPaneByAgent(store.getState().workspaceLayout.tree, 'chain:chain-3'), newPane, 'chain target put into the new pane');
      assert.deepEqual(layout.selectMainAgentIds(store.getState()), ['a', 'chain:chain-3']);
      assert.equal(dom.window.location.hash, '#/conversations/a+chain:chain-3?focused=chain:chain-3');
    } finally {
      await act(async () => root.unmount());
      store.dispatch(heimdallApi.util.resetApiState());
    }
  });
});

test('home page (route): search bar + last chains, flat; a row opens the chain-addressed coordinator conversation', async () => {
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
      assert.equal(dom.window.location.hash, '#/conversations/chain:chain-3');
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
      assert.equal(dom.window.location.hash, '#/conversations/chain:chain-4', 'opens the chain conversation, not the chain page');
    } finally {
      await act(async () => root.unmount());
      store.dispatch(heimdallApi.util.resetApiState());
    }
  });
});

// Interleaved projects include nine chains each in p1/p2 and eight Unassigned.
// The grouped preview really omits rows: using it cannot pass traversal.
function manyChains(count = 26) {
  return Array.from({ length: count }, (_, i) => ({
    chain_id: `browse-${String(i).padStart(2, '0')}`,
    title: `Browse ${i}`,
    project_id: ['p1', 'p2', ''][i % 3],
    project_name: ['One', 'Two', ''][i % 3],
    status: i === 23 ? 'completed' : 'active',
    coordinator_agent_instance_id: `coordinator-${i}`,
    updated_at: new Date(Date.UTC(2026, 9, 26, 0, 0, 0) - i * 60_000).toISOString(),
  }));
}

test('full-list adapter: deterministic dates/ties, newest duplicate, archive rules, completed, no mutation', () => {
  const input = [
    chain('z', 'invalid'), chain('b', '2026-01-01'), chain('a', '2026-01-01'),
    chain('missing', ''), chain('old', '1960-01-01'),
    chain('b', '2025-01-01', { title: 'Older duplicate' }),
    chain('archived', '2027-01-01', { status: 'Archived' }),
    chain('flagged', '2027-01-01', { archived: true }),
    chain('project-archived', '2027-01-01', { projectId: 'gone' }),
    chain('completed', '2026-01-02', { status: 'completed' }),
  ];
  const before = structuredClone(input);
  input.forEach(Object.freeze);
  Object.freeze(input);
  const rows = homeChainsFromFlatList(input, new Set(['gone']));
  assert.deepEqual(rows.map((c) => c.chainId), ['completed', 'a', 'b', 'old', 'missing', 'z']);
  assert.equal(rows.find((c) => c.chainId === 'b')?.title, 'Title b');
  assert.deepEqual(input, before);
  assert.deepEqual(homeChainsFromFlatList(undefined), []);
});

for (const total of [0, 1, 10, 11, 20]) {
  test(`page helper boundaries: ${total} chains`, () => {
    const rows = homeChainsFromFlatList(manyChains(total).map((c) => chain(c.chain_id, c.updated_at)));
    const count = Math.ceil(total / 10);
    const first = homeChainPage(rows, -99);
    const last = homeChainPage(rows, 99);
    assert.equal(first.pageIndex, 0);
    assert.equal(first.hasPrevious, false);
    assert.equal(first.hasNext, total > 10);
    assert.equal(first.rows.length, Math.min(total, 10));
    assert.equal(first.pageCount, count);
    assert.equal(last.pageIndex, Math.max(0, count - 1));
    assert.equal(last.hasNext, false);
    assert.equal(last.rows.length, total ? ((total - 1) % 10) + 1 : 0);
    assert.deepEqual(homeChainPage(rows, NaN), first);
  });
}

async function withList(
  fixture: Fixture,
  fn: (ctx: any) => Promise<void>,
  options: { panes?: number; userId?: string; setup?: (store: any) => Promise<void> } = {},
) {
  await withDom('#/home', async (dom) => {
    const { createRoot } = await import('react-dom/client');
    const { act } = await import('react');
    const { Provider } = await import('react-redux');
    const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
    const { tasksApi } = await import('../src/ui/api/endpoints/tasks.ts');
    const { HomeChainSearch } = await import('../src/ui/components/home/HomeChainSearch.tsx');
    const { AuthUserProvider } = await import('../src/ui/components/auth/AuthUserContext.tsx');
    const store = await makeStore();
    if (options.setup) await options.setup(store);
    const root = createRoot(dom.window.document.getElementById('root')!);
    const opened: string[][] = Array.from({ length: options.panes || 1 }, () => []);
    const render = async (userId: string | null = options.userId || null) => {
      await act(async () => {
        root.render(React.createElement(
          Provider, { store },
          React.createElement(AuthUserProvider, { value: userId ? { user_id: userId } : null },
            ...opened.map((ids, i) => React.createElement(HomeChainSearch, { key: i, onOpenAgent: (id: string) => ids.push(id) }))),
        ));
      });
    };
    const section = (i = 0) => dom.window.document.querySelectorAll('[data-debug-id="home-chain-search"]')[i];
    const el = (id: string, i = 0) => section(i)?.querySelector(`[data-debug-id="${id}"]`) as any;
    const ids = (i = 0) => Array.from(section(i).querySelectorAll('[data-debug-id^="home-chain-row-"]'))
      .map((e: any) => e.getAttribute('data-debug-id').slice('home-chain-row-'.length));
    const click = async (id: string, i = 0) => {
      assert.ok(el(id, i), `missing control ${id}`);
      await act(async () => { el(id, i).click(); });
    };
    const query = async (value: string, i = 0) => {
      const input = el('home-chain-search-input', i);
      await act(async () => {
        Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, 'value')!.set!.call(input, value);
        input.dispatchEvent(new dom.window.Event('input', { bubbles: true }));
      });
    };
    const refresh = async () => {
      await act(async () => { store.dispatch(heimdallApi.util.invalidateTags([{ type: 'ChainList', id: 'ALL' }])); });
    };
    try {
      await render();
      const remount = async () => {
        await act(async () => { root.render(null); });
        await render();
      };
      await fn({ dom, act, store, tasksApi, heimdallApi, section, el, ids, click, query, refresh, opened, render, remount });
    } finally {
      await act(async () => root.unmount());
      store.dispatch(heimdallApi.util.resetApiState());
    }
  }, fixture);
}

test('rendered full endpoint: 26 interleaved owned chains traverse 10/10/6 and reverse once each beyond grouped cap', async () => {
  const chains = manyChains();
  const requests: string[] = [];
  const capped = ['p1', 'p2', ''].map((p) => ({ project_id: p, chains: chains.filter((c) => c.project_id === p).slice(0, 5) }));
  await withList({
    chains: [...chains].reverse(), requests,
    fetch: (url) => /\/task-chains$/.test(url) ? jsonResponse({ groups: capped }) : undefined,
  }, async ({ el, ids, click, act, opened, dom }) => {
    await waitFor(() => ids().length === 10, act);
    const expected = chains.map((c) => c.chain_id);
    assert.deepEqual(ids(), expected.slice(0, 10));
    assert.equal(el('home-chain-prev-btn').disabled, true);
    assert.equal(el('home-chain-next-btn').disabled, false);
    assert.equal(el('home-chain-page-status').textContent, 'Page 1 of 3');
    assert.equal(el('home-chain-page-status').getAttribute('aria-live'), 'polite');
    assert.equal(el('home-chain-list').getAttribute('aria-label'), 'Task chains');
    const seen = [...ids()];
    const next = el('home-chain-next-btn');
    let listScrolls = 0;
    el('home-chain-list').getBoundingClientRect = () => ({ top: -10 });
    el('home-chain-list').scrollIntoView = () => { listScrolls++; };
    next.focus();
    await click('home-chain-next-btn');
    assert.equal(dom.window.document.activeElement, next, 'page changes preserve activated control focus');
    assert.equal(listScrolls, 1, 'scroll only the list when its new rows are above the viewport');
    el('home-chain-list').getBoundingClientRect = () => ({ top: 0 });
    assert.deepEqual(ids(), expected.slice(10, 20));
    seen.push(...ids());
    assert.ok(ids().some((id: string) => !capped.some((g) => g.chains.some((c) => c.chain_id === id))), 'beyond-preview rows are reachable');
    await click('home-chain-next-btn');
    assert.deepEqual(ids(), expected.slice(20));
    seen.push(...ids());
    assert.equal(el('home-chain-page-status').textContent, 'Page 3 of 3');
    assert.equal(el('home-chain-next-btn').disabled, true);
    await click('home-chain-next-btn');
    assert.deepEqual(ids(), expected.slice(20));
    assert.deepEqual(seen, expected);
    assert.equal(new Set(seen).size, 26);
    await click('home-chain-prev-btn');
    assert.deepEqual(ids(), expected.slice(10, 20));
    await click('home-chain-prev-btn');
    assert.deepEqual(ids(), expected.slice(0, 10));
    await click('home-chain-prev-btn');
    assert.deepEqual(ids(), expected.slice(0, 10));
    assert.deepEqual(opened, [[]], 'paging never opens a chain');
    assert.equal(listScrolls, 1, 'visible list changes never scroll the page');
    assert.equal(requests.filter((u) => /\/task-chains\?flat=1$/.test(u)).length, 1, 'page changes use a shared local snapshot');
    assert.equal(requests.filter((u) => /\/task-chains$/.test(u)).length, 0, 'Home never loads capped grouped previews');
    for (const button of ['home-chain-prev-btn', 'home-chain-next-btn']) {
      assert.match(el(button).className, /min-h-11/, '44px touch target');
    }
  });
});

for (const total of [0, 1, 10, 11, 20]) {
  test(`rendered browse bounds and completion for ${total} chains`, async () => {
    await withList({ chains: manyChains(total) }, async ({ ids, el, act, click }) => {
      await waitFor(() => el('home-chain-page-status')?.textContent === `Page ${total ? 1 : 0} of ${Math.ceil(total / 10)}`, act);
      assert.equal(ids().length, Math.min(10, total));
      assert.equal(el('home-chain-prev-btn').disabled, true);
      assert.equal(el('home-chain-next-btn').disabled, total <= 10);
      if (total > 10) {
        await click('home-chain-next-btn');
        assert.equal(ids().length, total - 10);
        assert.equal(el('home-chain-next-btn').disabled, true);
        await click('home-chain-prev-btn');
        assert.equal(ids().length, 10);
      }
      assert.equal(Boolean(el('home-chain-empty')), total === 0);
    });
  });
}

test('rendered lifecycle: loading, initial failure/Retry, background error retain, title refresh, reorder/shrink/archive reset', async () => {
  const fixture: Fixture = { chains: manyChains(), projects: [{ project_id: 'gone', name: 'Gone', state: 'archived' }] };
  let resolve: (value: any) => void = () => {};
  fixture.fetch = (url) => /\/task-chains\?flat=1$/.test(url) ? new Promise((r) => { resolve = r; }) : undefined;
  await withList(fixture, async ({ el, ids, act, click, refresh, section }) => {
    assert.match(section().textContent, /Loading task chains/);
    assert.equal(el('home-chain-next-btn').disabled, true);
    assert.equal(el('home-chain-prev-btn').disabled, true);
    assert.equal(el('home-chain-empty'), null);
    await act(async () => { resolve(jsonResponse({ error: { message: 'offline' } }, 503)); });
    await waitFor(() => Boolean(el('home-chain-retry-btn')), act);
    assert.match(section().textContent, /Could not load task chains/);
    assert.equal(el('home-chain-page-status'), null, 'failure must not claim exhausted empty data');
    assert.equal(el('home-chain-empty'), null);
    fixture.fetch = undefined;
    await click('home-chain-retry-btn');
    await waitFor(() => ids().length === 10, act);
    await click('home-chain-next-btn');
    const page2 = ids();
    fixture.fetch = (url) => /\/task-chains\?flat=1$/.test(url) ? new Promise((r) => { resolve = r; }) : undefined;
    await refresh();
    assert.deepEqual(ids(), page2, 'refresh retains prior snapshot while pending');
    await waitFor(() => el('home-chain-list').getAttribute('aria-busy') === 'true', act);
    await act(async () => { resolve(jsonResponse({}, 503)); });
    await waitFor(() => Boolean(el('home-chain-retry-btn')), act);
    assert.deepEqual(ids(), page2);
    assert.equal(el('home-chain-page-status').textContent, 'Page 2 of 3');
    assert.match(section().textContent, /Showing the previous list/);
    fixture.fetch = undefined;
    fixture.chains = fixture.chains!.map((c) => ({ ...c, title: 'Renamed ' + c.chain_id }));
    await click('home-chain-retry-btn');
    await waitFor(() => section().textContent.includes('Renamed browse-10'), act);
    assert.deepEqual(ids(), page2, 'title-only updates preserve page');
    fixture.chains = fixture.chains!.map((c) => c.chain_id === 'browse-25' ? { ...c, updated_at: '2027-01-01' } : c);
    await refresh();
    await waitFor(() => ids()[0] === 'browse-25', act);
    assert.equal(el('home-chain-page-status').textContent, 'Page 1 of 3');
    await click('home-chain-next-btn');
    await click('home-chain-next-btn');
    fixture.chains = fixture.chains!.slice(0, 6);
    await refresh();
    await waitFor(() => el('home-chain-page-status').textContent === 'Page 1 of 1', act);
    assert.equal(ids().length, 6);
    assert.equal(el('home-chain-next-btn').disabled, true);
    fixture.chains = [
      ...manyChains(11),
      { ...manyChains(1)[0], chain_id: 'archived-chain', status: 'archived', updated_at: '2028-01-01' },
      { ...manyChains(1)[0], chain_id: 'archived-project-chain', project_id: 'gone', updated_at: '2028-01-01' },
    ];
    await refresh();
    await waitFor(() => el('home-chain-page-status')?.textContent === 'Page 1 of 2', act);
    assert.equal(ids().includes('archived-chain'), false);
    assert.equal(ids().includes('archived-project-chain'), false);
  });
});

test('Home instances share one request but own independent pages; rapid clicks clamp and remount starts first', async () => {
  const requests: string[] = [];
  await withList({ chains: manyChains(), requests }, async ({ el, ids, act, click, query, remount }) => {
    await waitFor(() => ids(1).length === 10, act);
    await click('home-chain-next-btn', 0);
    assert.equal(el('home-chain-page-status', 0).textContent, 'Page 2 of 3');
    assert.equal(el('home-chain-page-status', 1).textContent, 'Page 1 of 3');
    await act(async () => { for (let i = 0; i < 8; i++) el('home-chain-next-btn', 0).click(); });
    assert.equal(el('home-chain-page-status', 0).textContent, 'Page 3 of 3');
    assert.equal(ids(0).length, 6);
    await query('browse');
    assert.equal(el('home-chain-next-btn'), null, 'search hides the browse controls');
    await query('');
    assert.equal(el('home-chain-page-status').textContent, 'Page 1 of 3');
    assert.equal(el('home-chain-page-status', 1).textContent, 'Page 1 of 3');
    await click('home-chain-next-btn');
    await remount();
    await waitFor(() => ids().length === 10, act);
    assert.equal(el('home-chain-page-status').textContent, 'Page 1 of 3');
    assert.equal(requests.filter((u) => /\/task-chains\?flat=1$/.test(u)).length, 1);
  }, { panes: 2 });
});

test('later-page rows retain list coordinator, detail fallback, invoking-pane callback, and chain route fallback', async () => {
  const chains = manyChains();
  chains[21].coordinator_agent_instance_id = '';
  chains[22].coordinator_agent_instance_id = '';
  await withList({
    chains,
    fetch: (url) => url.endsWith('/task-chains/browse-21') ? jsonResponse({ data: {
      chain_id: 'browse-21', members: [{ agent_instance_id: 'resolved-21', role: 'coordinator' }],
    } }) : undefined,
  }, async ({ ids, act, el, click, opened, dom }) => {
    await waitFor(() => ids(1).length === 10, act);
    await click('home-chain-next-btn', 1);
    await click('home-chain-next-btn', 1);
    await click('home-chain-row-browse-20', 1);
    // Each row opens its chain target (REQ-TV2-7); the coordinator only decides
    // between the conversation and the chain page.
    assert.deepEqual(opened, [[], ['chain:browse-20']]);
    await click('home-chain-row-browse-21', 1);
    await waitFor(() => opened[1].length === 2, act);
    assert.deepEqual(opened, [[], ['chain:browse-20', 'chain:browse-21']]);
    await click('home-chain-row-browse-22', 1);
    await waitFor(() => dom.window.location.hash === '#/chains/browse-22', act);
    assert.deepEqual(opened[0], []);
    assert.equal(el('home-chain-page-status', 0).textContent, 'Page 1 of 3');
  }, { panes: 2 });
});

test('Home endpoint validates successful shapes instead of caching malformed lists as empty success', async () => {
  for (const body of [{ groups: GROUPS }, {}, { chains: {} }, [null], [{ title: 'missing id' }], [{ chain_id: 4 }]]) {
    await withDom('#/home', async () => {
      const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
      const { tasksApi } = await import('../src/ui/api/endpoints/tasks.ts');
      const store = await makeStore();
      const request = store.dispatch(tasksApi.endpoints.fetchHomeTaskChains.initiate());
      try {
        const result = await request;
        assert.equal(result.isError, true, JSON.stringify(body));
        assert.equal(result.data, undefined);
        assert.match(String((result.error as any)?.error), /Invalid task chain list response/);
      } finally {
        request.unsubscribe();
        store.dispatch(heimdallApi.util.resetApiState());
      }
    }, { fetch: (url) => url.endsWith('/task-chains?flat=1') ? jsonResponse({ data: body }) : undefined });
  }
});

test('Home endpoint decrypts through installed keyring, purges on lock/unlock, and discards late prior-session replies', async () => {
  const { unlockVault, clearActiveKey } = await import('./helpers/vaultEndpointHarness.ts');
  const { encryptVaultText } = await import('../src/ui/utils/vaultCrypto.ts');
  const { keyringCleared } = await import('../src/ui/store/vaultSlice.ts');
  const fixture: Fixture = { chains: manyChains(1) };
  await withDom('#/home', async () => {
    const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
    const { tasksApi } = await import('../src/ui/api/endpoints/tasks.ts');
    const store = await makeStore();
    const keyring = await unlockVault(store, '41'.repeat(32));
    fixture.chains![0].title = await encryptVaultText('Private Home title', keyring);
    fixture.chains![0].project_name = await encryptVaultText('Private project', keyring);
    const endpoint = tasksApi.endpoints.fetchHomeTaskChains;
    let request = store.dispatch(endpoint.initiate());
    try {
      let result = await request;
      assert.equal(result.data?.chains[0].title, 'Private Home title');
      assert.equal(result.data?.chains[0].projectName, 'Private project');
      request.unsubscribe();
      store.dispatch(keyringCleared());
      await clearActiveKey();
      assert.equal(endpoint.select()(store.getState()).data, undefined, 'lock resets decrypted cache immediately');
      request = store.dispatch(endpoint.initiate());
      result = await request;
      assert.match(result.data?.chains[0].title || '', /^vault:v2:/, 'locked fetch keeps ciphertext');
      request.unsubscribe();
      await unlockVault(store, '41'.repeat(32));
      assert.equal(endpoint.select()(store.getState()).data, undefined, 'unlock invalidates armored cache');
      request = store.dispatch(endpoint.initiate());
      result = await request;
      assert.equal(result.data?.chains[0].title, 'Private Home title');
      request.unsubscribe();
      store.dispatch(heimdallApi.util.resetApiState());
      let release: (value: any) => void = () => {};
      fixture.fetch = (url) => url.endsWith('/task-chains?flat=1') ? new Promise((r) => { release = r; }) : undefined;
      request = store.dispatch(endpoint.initiate());
      // Allow the queryFn to reach the controlled transport.
      await new Promise((r) => setTimeout(r, 0));
      store.dispatch(heimdallApi.util.resetApiState()); // AppShell prior-owner/session boundary.
      release(jsonResponse({ data: fixture.chains }));
      await request;
      assert.equal(endpoint.select()(store.getState()).data, undefined, 'old completion cannot repopulate reset cache');
      assert.deepEqual(store.getState()[heimdallApi.reducerPath].queries, {});
    } finally {
      request.unsubscribe();
      store.dispatch(keyringCleared());
      store.dispatch(heimdallApi.util.resetApiState());
      await clearActiveKey();
    }
  }, fixture);
});

test('rendered encrypted search: page-three reset, opaque limit10 unscoped RPC, relevance/stale/error/local shielding, late query/owner/lock replies', async () => {
  const { unlockVault, clearActiveKey } = await import('./helpers/vaultEndpointHarness.ts');
  const { keyringCleared } = await import('../src/ui/store/vaultSlice.ts');
  const { deriveTaskChainSearchKey, setActiveTaskChainSearchKey } = await import('../src/ui/utils/taskChainSearchKey.ts');
  const { openTaskChainSearch, sealTaskChainSearch, taskChainSearchAad } = await import('../src/ui/utils/taskChainSearch.ts');
  const key = await deriveTaskChainSearchKey('52'.repeat(32), 1);
  const pending: { owner: string; plain: any; release: (hits?: any[], stale?: boolean, error?: boolean) => Promise<void> }[] = [];
  let owner = 'user-home-1';
  const fixture: Fixture = {
    chains: [
      ...manyChains(),
      { ...manyChains(1)[0], chain_id: 'armored-only', title: JSON.parse(fs.readFileSync(path.join(REPO_ROOT, 'tests/fixtures/vault_v2_vectors.json'), 'utf8')).envelope.cases[0].token, project_name: '', updated_at: '' },
    ],
    fetch: async (url, init) => {
      if (url.endsWith('/bridges')) return jsonResponse({ bridges: [{
        bridge_id: 'bridge-home', status: 'online', vault_status: 'unlocked', task_chain_search_ready: true,
      }] });
      if (!url.endsWith('/task-chains/search/relay')) return undefined;
      const wire = JSON.parse(init.body);
      assert.deepEqual(Object.keys(wire).sort(), ['bridge_id', 'envelope', 'expires_at_ms', 'request_id']);
      assert.equal(init.credentials, 'include');
      assert.match(wire.envelope, /^search:v2:e1:/);
      const aad = (direction: 'request' | 'response') => taskChainSearchAad(owner, wire.bridge_id, wire.request_id, direction, wire.expires_at_ms, 1);
      const plain = await openTaskChainSearch<any>(wire.envelope, key, aad('request'));
      assert.equal(plain.limit, 10);
      assert.equal(plain.project_id, '', 'Home search never inherits a project');
      assert.equal(plain.status, '');
      const responseAad = aad('response'); // Capture the issuing owner across a later switch.
      return new Promise((resolve) => {
        pending.push({ owner, plain, release: async (hits = [], stale = false, error = false) => {
          if (error) { resolve(jsonResponse({ error: { code: 'bridge_offline', message: 'offline' } }, 409)); return; }
          const envelope = await sealTaskChainSearch({
            request_id: wire.request_id, bridge_id: wire.bridge_id, indexed_revision: 3, stale, hits,
          }, key, responseAad);
          resolve(jsonResponse({ data: { ok: true, envelope } }));
        } });
      });
    },
  };
  const hit = (id: string, updated = '') => ({ chain_id: id, title: 'Remote ' + id, project_id: '', status: 'active', updated_at: updated, description: '' });
  try {
    await withList(fixture, async ({ el, ids, query, click, act, render, store, heimdallApi, section }) => {
      await waitFor(() => ids().length === 10, act);
      await click('home-chain-next-btn');
      await click('home-chain-next-btn');
      await query('br');
      assert.equal(el('home-chain-next-btn'), null);
      await waitFor(() => pending.length === 1, act);
      assert.equal(pending[0].plain.query, 'br');
      await query('');
      assert.equal(el('home-chain-page-status').textContent, 'Page 1 of 3');
      await click('home-chain-next-btn');
      await act(async () => { await pending[0].release([hit('old-query')]); });
      assert.equal(el('home-chain-page-status').textContent, 'Page 2 of 3');
      assert.equal(ids().includes('old-query'), false);
      await query('ranked');
      await waitFor(() => pending.length === 2, act);
      await act(async () => { await pending[1].release([hit('browse-25', '2020-01-01'), hit('browse-00', '2030-01-01')], true); });
      await waitFor(() => ids()[0] === 'browse-25', act);
      assert.deepEqual(ids(), ['browse-25', 'browse-00'], 'remote relevance is preserved rather than sorted by time');
      assert.match(el('home-chain-search-state').textContent, /stale/);
      await query('Browse 24');
      await waitFor(() => pending.length === 3, act);
      await act(async () => { await pending[2].release([], false, true); });
      await waitFor(() => el('home-chain-search-state')?.textContent.includes('online'), act);
      assert.deepEqual(ids(), ['browse-24'], 'remote failure uses full-list local fallback beyond preview');
      await query(fixture.chains![26].title.split(':').slice(0, 3).join(':'));
      assert.deepEqual(ids(), [], 'raw armor never locally matches');
      await waitFor(() => pending.length === 4, act);
      await query('x'); // Cancel the pending response, single-character search makes no remote call.
      await act(async () => { await pending[3].release([hit('old-armor')]); });
      assert.equal(el('home-chain-search-state'), null);
      await act(async () => { await new Promise((r) => setTimeout(r, 180)); });
      assert.equal(pending.length, 4);
      await query('owner');
      await waitFor(() => pending.length === 5, act);
      owner = 'user-home-2';
      await act(async () => { store.dispatch(heimdallApi.util.resetApiState()); });
      await render(owner); // Mirrors AppShell reset before changing the auth context.
      await act(async () => { await pending[4].release([hit('prior-owner')]); });
      assert.equal(ids().includes('prior-owner'), false);
      await waitFor(() => pending.length === 6, act);
      assert.equal(pending[5].owner, owner);
      await act(async () => {
        store.dispatch(keyringCleared());
        await clearActiveKey();
        setActiveTaskChainSearchKey(null);
      });
      await act(async () => { await pending[5].release([hit('prior-lock')]); });
      assert.equal(ids().includes('prior-lock'), false);
      assert.equal(el('home-chain-search-state'), null);
      assert.equal(section().textContent.includes('Remote prior-'), false);
      await act(async () => {
        await unlockVault(store, '52'.repeat(32));
        setActiveTaskChainSearchKey(key);
      });
      await query('logout');
      await waitFor(() => pending.length === 7, act);
      await render(null); // Logout: discard the pending authenticated search.
      await act(async () => { await pending[6].release([hit('prior-logout')]); });
      assert.equal(ids().includes('prior-logout'), false);
      assert.equal(el('home-chain-search-state'), null);
      await query('');
      assert.equal(el('home-chain-page-status').textContent, 'Page 1 of 3');
    }, {
      userId: owner,
      setup: async (store) => {
        await unlockVault(store, '52'.repeat(32));
        setActiveTaskChainSearchKey(key);
      },
    });
  } finally {
    setActiveTaskChainSearchKey(null);
    await clearActiveKey();
  }
});

test('project archive eligibility refresh resets page without changing chain snapshot or refetching it', async () => {
  const fixture: Fixture = { chains: manyChains(), projects: [], requests: [] };
  await withList(fixture, async ({ ids, el, act, click, store, heimdallApi }) => {
    await waitFor(() => ids().length === 10, act);
    await click('home-chain-next-btn');
    fixture.projects = [{ project_id: 'p1', name: 'One', state: 'archived' }];
    await act(async () => { store.dispatch(heimdallApi.util.invalidateTags([{ type: 'Projects', id: 'LIST' }])); });
    await waitFor(() => el('home-chain-page-status').textContent === 'Page 1 of 2', act);
    const expected = fixture.chains!.filter((c) => c.project_id !== 'p1').map((c) => c.chain_id);
    assert.deepEqual(ids(), expected.slice(0, 10));
    await click('home-chain-next-btn');
    assert.deepEqual(ids(), expected.slice(10));
    assert.equal(el('home-chain-next-btn').disabled, true);
    assert.equal(fixture.requests!.filter((u) => /\/task-chains\?flat=1$/.test(u)).length, 1);
  });
});

test('new Main pane later-page coordinator replaces that pane and preserves its sibling', async () => {
  const chains = manyChains();
  await withDom('#/conversations/a+_new?focused=_new', async (dom) => {
    const { createRoot } = await import('react-dom/client');
    const { act } = await import('react');
    const { Provider } = await import('react-redux');
    const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
    const layout = await import('../src/ui/store/workspaceLayoutSlice.ts');
    const { Workspace } = await import('../src/ui/components/mainWorkspace/Workspace.tsx');
    const { ShortcutProvider } = await import('../src/ui/services/shortcuts/ShortcutContext.tsx');
    const store = await makeStore();
    const root = createRoot(dom.window.document.getElementById('root')!);
    try {
      await act(async () => {
        root.render(React.createElement(Provider, { store },
          React.createElement(ShortcutProvider, {}, React.createElement(Workspace, {}))));
      });
      const sibling = layout.findPaneByAgent(store.getState().workspaceLayout.tree, 'a');
      const target = sibling === 'pane-1' ? 'pane-2' : 'pane-1';
      const frame = () => dom.window.document.querySelector(`[data-debug-id="main-pane-frame-${target}"]`)!;
      const el = (id: string) => frame()?.querySelector(`[data-debug-id="${id}"]`) as any;
      await waitFor(() => Boolean(el('home-chain-row-browse-00')), act);
      await act(async () => { el('home-chain-next-btn').click(); });
      await act(async () => { el('home-chain-next-btn').click(); });
      assert.ok(el('home-chain-row-browse-20'));
      await act(async () => { el('home-chain-row-browse-20').click(); });
      await waitFor(() => layout.findPaneByAgent(store.getState().workspaceLayout.tree, 'chain:browse-20') === target, act);
      assert.equal(layout.findPaneByAgent(store.getState().workspaceLayout.tree, 'a'), sibling);
      assert.equal(dom.window.location.hash, '#/conversations/a+chain:browse-20?focused=chain:browse-20');
    } finally {
      await act(async () => root.unmount());
      store.dispatch(heimdallApi.util.resetApiState());
    }
  }, { chains });
});
