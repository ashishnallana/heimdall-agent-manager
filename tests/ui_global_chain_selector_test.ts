import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { prepareChainSelectorItems, sortChainSelectorItems } from '../src/ui/components/chains/taskChainSelectorLogic.ts';

function item(chainId: string, updatedAt?: string, extra: any = {}) {
  return { chainId, title: `Match ${chainId}`, rawTitle: `Match ${chainId}`, status: 'completed', projectId: 'p1', projectName: 'One', updatedAt, ...extra };
}
function group(projectId: string, chains: any[]) {
  return { projectId, projectName: projectId === 'p1' ? 'One' : 'Two', chains, chainTotal: chains.length, hasMore: false, nextCursor: '' };
}
function wireGroups(groups: any[]) {
  return groups.map((g) => ({
    project_id: g.projectId, project_name: g.projectName,
    chains: g.chains.map((c: any) => ({
      chain_id: c.chainId, title: c.title, status: c.status, project_id: g.projectId,
      updated_at: c.updatedAt, coordinator_agent_instance_id: c.coordinatorAgentInstanceId || '',
    })),
  }));
}
function hit(chainId: string, updatedAt = '2026-01-01', project_id = 'p2') {
  return { chain_id: chainId, title: `Match ${chainId}`, description: '', status: 'completed', project_id, updated_at: updatedAt };
}
function deferred<T = any>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((r) => { resolve = r; });
  return { promise, resolve };
}
function json(body: any, status = 200) {
  return { ok: status < 400, status, headers: { get: () => 'application/json' }, text: async () => JSON.stringify(body), json: async () => body } as any;
}

test('recency sort is immutable, deterministic for ties/invalid dates, compares instants and never pins current', () => {
  const rows = [
    item('invalid-z', 'bad'), item('tie-b', '2026-01-02T01:00:00+01:00'),
    item('missing-a'), item('tie-a', '2026-01-02T00:00:00Z'), item('newest', '2026-01-03'),
    item('old-current', '1960-01-01', { isCurrent: true }), item('invalid-a', 'NaN'),
  ];
  rows.forEach(Object.freeze);
  Object.freeze(rows);
  assert.deepEqual(sortChainSelectorItems(rows).map((c) => c.chainId),
    ['newest', 'tie-a', 'tie-b', 'old-current', 'invalid-a', 'invalid-z', 'missing-a']);
  assert.equal(rows[0].chainId, 'invalid-z');
});

test('cache-only and duplicate metadata retain the newest valid timestamp without changing API/cache inputs', () => {
  const groups = [group('p1', [
    item('bad-preview', 'bad'), item('new-preview', '2026-04-01'),
    item('new-cache', '2026-01-01'), item('missing-preview', undefined),
  ])];
  const cache: any = Object.fromEntries([
    ['cache-only', '2026-05-01'], ['bad-preview', '2026-03-01'],
    ['new-preview', '2026-02-01'], ['new-cache', '2026-06-01'], ['missing-preview', '2026-02-01'],
  ].map(([id, updatedAt]) => [id, { id, type: 'chain', rawTitle: id, decryptedTitle: id, updatedAt }]));
  const before = JSON.stringify({ groups, cache });
  const prepared = prepareChainSelectorItems(groups, cache);
  assert.deepEqual(sortChainSelectorItems(prepared).map((c) => c.chainId),
    ['new-cache', 'cache-only', 'new-preview', 'bad-preview', 'missing-preview']);
  assert.equal(prepared.find((c) => c.chainId === 'bad-preview')!.updatedAt, '2026-03-01');
  assert.equal(JSON.stringify({ groups, cache }), before);
});

type Reply = { hits?: any[]; stale?: boolean; status?: number; corrupt?: boolean };
async function fixture(options: {
  groups?: any[]; currentChainId?: string; workspace?: boolean; projectId?: string;
  respond?: (request: any) => Reply | Promise<Reply>;
}, run: (ctx: any) => Promise<void>) {
  const { JSDOM } = await import('jsdom');
  const dom = new JSDOM('<!doctype html><html><body><div id="root"></div></body></html>', {
    url: `http://localhost/${options.workspace ? '#/conversations/a+b?focused=a' : '#/home'}`,
  });
  const saved = new Map<string, PropertyDescriptor | undefined>();
  const install = (name: string, value: any) => {
    saved.set(name, Object.getOwnPropertyDescriptor(globalThis, name));
    Object.defineProperty(globalThis, name, { value, configurable: true, writable: true });
  };
  const scrolls: string[] = [];
  dom.window.HTMLElement.prototype.scrollIntoView = function () { scrolls.push(this.getAttribute('data-chain-id') || ''); };
  dom.window.HTMLElement.prototype.scrollTo = () => {};
  dom.window.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} } as any);
  class RO { observe() {} unobserve() {} disconnect() {} }
  dom.window.ResizeObserver = RO as any;
  dom.window.requestAnimationFrame = (cb: any) => setTimeout(() => cb(Date.now()), 0) as any;
  dom.window.cancelAnimationFrame = (id: any) => clearTimeout(id);
  install('window', dom.window);
  install('document', dom.window.document);
  install('navigator', dom.window.navigator);
  install('HTMLElement', dom.window.HTMLElement);
  install('localStorage', dom.window.localStorage);
  install('sessionStorage', dom.window.sessionStorage);
  install('ResizeObserver', RO);
  install('requestAnimationFrame', dom.window.requestAnimationFrame);
  install('cancelAnimationFrame', dom.window.cancelAnimationFrame);
  install('IS_REACT_ACT_ENVIRONMENT', true);

  const { configureStore } = await import('@reduxjs/toolkit');
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const { default: vault, keyringInstalled } = await import('../src/ui/store/vaultSlice.ts');
  const { default: workspaceLayout } = await import('../src/ui/store/workspaceLayoutSlice.ts');
  const { default: auxPanes } = await import('../src/ui/store/auxPanesSlice.ts');
  const { default: workspaceChrome } = await import('../src/ui/store/workspaceChromeSlice.ts');
  const { default: searchTitle } = await import('../src/ui/store/searchTitleSlice.ts');
  const { setActiveVaultKey } = await import('../src/ui/utils/vaultCrypto.ts');
  const { keyringFromHex } = await import('./helpers/vaultTestKeyring.ts');
  const { deriveTaskChainSearchKey, setActiveTaskChainSearchKey } = await import('../src/ui/utils/taskChainSearchKey.ts');
  const { openTaskChainSearch, sealTaskChainSearch, taskChainSearchAad } = await import('../src/ui/utils/taskChainSearch.ts');
  // All crypto is disposable fixture material; no live key/session/endpoint is used.
  const keyHex = '42'.repeat(32);
  setActiveVaultKey(await keyringFromHex(keyHex));
  const searchKey = await deriveTaskChainSearchKey(keyHex, 1);
  setActiveTaskChainSearchKey(searchKey);
  const store = configureStore({
    reducer: {
      vault, workspaceLayout, auxPanes, workspaceChrome, searchTitle,
      chat: (s: any = { session: { daemonUrl: 'http://127.0.0.1:7777', clientToken: 'fixture' } }) => s,
      [heimdallApi.reducerPath]: heimdallApi.reducer,
    },
    middleware: (g: any) => g({ serializableCheck: false, immutableCheck: false }).concat(heimdallApi.middleware),
  });
  store.dispatch(keyringInstalled({ currentEpoch: 1 }));
  const groups = options.groups ?? [
    group('p1', [item('old', '2026-01-01', { coordinatorAgentInstanceId: 'a' }), item('new', '2026-03-01', { coordinatorAgentInstanceId: 'coord-new' })]),
    group('p2', [item('middle', '2026-02-01', { coordinatorAgentInstanceId: 'coord-middle' })]),
  ];
  const requests: any[] = [];
  const projectId = options.projectId ?? 'p1';
  const details: string[] = [];
  install('fetch', async (input: any, init: any = {}) => {
    const url = String(input?.url ?? input);
    if (url.endsWith('/task-chains/search/relay')) {
      const wire = JSON.parse(init.body);
      const request = await openTaskChainSearch<any>(wire.envelope, searchKey,
        taskChainSearchAad('fixture-owner', wire.bridge_id, wire.request_id, 'request', wire.expires_at_ms, 1));
      requests.push(request);
      const reply = await (options.respond?.(request) ?? { hits: [] });
      if (reply.status) return json({ error: { code: 'bridge_offline' } }, reply.status);
      const envelope = reply.corrupt ? 'invalid' : await sealTaskChainSearch({
        request_id: wire.request_id, bridge_id: wire.bridge_id, indexed_revision: 1,
        stale: Boolean(reply.stale), hits: reply.hits ?? [],
      }, searchKey, taskChainSearchAad('fixture-owner', wire.bridge_id, wire.request_id, 'response', wire.expires_at_ms, 1));
      return json({ data: { ok: true, envelope } });
    }
    if (/\/bridges(\?|$)/.test(url)) return json({ bridges: [{
      bridge_id: 'fixture-bridge', status: 'online', vault_status: 'unlocked', task_chain_search_ready: true,
    }] });
    const instance = url.match(/\/agent-instances\/([^/?]+)$/);
    if (instance) return json({ data: { agent_instance_id: instance[1], project_id: projectId } });
    const conv = url.match(/\/chats\/by-instance\/([^/?]+)/);
    if (conv) {
      const id = decodeURIComponent(conv[1]);
      return json({ data: { conversation_id: `conv-${id}`, agent_instance_id: id,
        chain_id: id === 'a' ? 'old' : 'other', project_id: projectId, title: `Agent ${id}` } });
    }
    if (/\/projects\/[^/?]+/.test(url)) return json({ data: { project_id: projectId, name: 'Pane project One' } });
    const detail = url.match(/\/task-chains\/([^/?]+)(\?|$)/);
    if (detail) {
      const id = decodeURIComponent(detail[1]);
      details.push(id);
      const c = groups.flatMap((g) => g.chains).find((c) => c.chainId === id);
      return json({ data: {
        chain_id: id, title: c?.title || id, coordinator_agent_instance_id: c?.coordinatorAgentInstanceId || '',
        members: id === 'remote-detail' ? [{ agent_instance_id: 'coord-detail', role: 'coordinator' }] : [], tasks: [],
      } });
    }
    if (/\/task-chains(\?|$)/.test(url)) return json({ groups: wireGroups(groups) });
    if (/\/(agents|agent-instances|templates)(\?|$)/.test(url)) return json({ data: [] });
    return json({ data: {} });
  });
  const { createRoot } = await import('react-dom/client');
  const { act } = await import('react');
  const { Provider } = await import('react-redux');
  const { AuthUserProvider } = await import('../src/ui/components/auth/AuthUserContext.tsx');
  const { TaskChainSelectorModal } = await import('../src/ui/components/chains/TaskChainSelectorModal.tsx');
  const root = createRoot(dom.window.document.getElementById('root')!);
  const selections: any[] = [];
  const routes: string[] = [];
  let closes = 0;
  const render = async (props: any = {}) => {
    let child;
    if (options.workspace) {
      const { Workspace } = await import('../src/ui/components/mainWorkspace/Workspace.tsx');
      const { ShortcutProvider } = await import('../src/ui/services/shortcuts/ShortcutContext.tsx');
      child = React.createElement(ShortcutProvider, {}, React.createElement(Workspace));
    } else {
      child = React.createElement(TaskChainSelectorModal, {
        open: true, onClose: () => { closes++; }, currentChainId: options.currentChainId,
        onSelectChain: (c) => selections.push(c), ...props,
      });
    }
    await act(async () => {
      root.render(React.createElement(Provider, { store },
        React.createElement(AuthUserProvider, { value: { user_id: 'fixture-owner' } }, child)));
    });
  };
  const doc = dom.window.document;
  const el = (id: string) => doc.querySelector(`[data-debug-id="${id}"]`) as any;
  const wait = async (predicate: () => boolean, label = 'condition') => {
    const deadline = Date.now() + 4000;
    while (!predicate()) {
      if (Date.now() > deadline) throw new Error(`Timed out: ${label}`);
      await act(async () => { await new Promise((r) => setTimeout(r, 20)); });
    }
  };
  const tick = async (ms = 40) => { await act(async () => { await new Promise((r) => setTimeout(r, ms)); }); };
  const click = async (node: any) => { assert.ok(node, 'click target exists'); await act(async () => { node.click(); }); };
  const input = () => el('task-chain-selector-search-input');
  const type = async (value: string) => {
    await act(async () => {
      Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, 'value')!.set!.call(input(), value);
      input().dispatchEvent(new dom.window.Event('input', { bubbles: true }));
    });
  };
  const press = async (key: string, extra: any = {}) => {
    await act(async () => { input().dispatchEvent(new dom.window.KeyboardEvent('keydown', { key, bubbles: true, ...extra })); });
  };
  const ids = () => Array.from(doc.querySelectorAll('[data-chain-id]')).map((e: any) => e.getAttribute('data-chain-id'));
  const active = () => doc.querySelector('[role="option"][aria-selected="true"]')?.getAttribute('data-chain-id');
  try {
    await render();
    await run({ dom, doc, el, wait, tick, click, type, press, ids, active, input, render,
      store, requests, groups, details, selections, routes, scrolls, closes: () => closes });
  } finally {
    await act(async () => {
      root.unmount();
      store.dispatch(heimdallApi.util.resetApiState());
    });
    setActiveVaultKey(null);
    setActiveTaskChainSearchKey(null);
    await new Promise((r) => setTimeout(r, 20));
    dom.window.close();
    for (const [name, descriptor] of saved) {
      if (descriptor) Object.defineProperty(globalThis, name, descriptor);
      else if (name === 'requestAnimationFrame') {
        // UI animation cleanup can run a tick after unmount (same convention as pane tests).
        (globalThis as any)[name] = (cb: any) => setTimeout(() => cb(Date.now()), 0);
      } else if (name === 'cancelAnimationFrame') {
        (globalThis as any)[name] = (id: any) => clearTimeout(id);
      } else delete (globalThis as any)[name];
    }
  }
}

test('rendered selector is flat, newest first locally/filtering; current selection uses visual index and Enter', async () => {
  await fixture({ currentChainId: 'old' }, async (c) => {
    await c.wait(() => c.ids().length === 3, 'loaded rows');
    assert.deepEqual(c.ids(), ['new', 'middle', 'old']);
    assert.equal(c.doc.querySelector('[role="group"]'), null);
    assert.equal(c.doc.querySelector('[data-debug-id^="chain-selector-group-"]'), null);
    assert.equal(c.active(), 'old');
    assert.ok(c.el('chain-selector-item-old').querySelector('[data-debug-id="chain-current-badge"]'));
    assert.equal(c.input().getAttribute('aria-activedescendant'), 'task-chain-option-2');
    assert.equal(c.el('chain-selector-item-old').getAttribute('data-chain-index'), '2');
    await c.press('ArrowUp');
    assert.equal(c.active(), 'middle');
    await c.press('Enter');
    await c.wait(() => c.selections.length === 1);
    assert.deepEqual(c.selections[0], { chainId: 'middle', coordinatorAgentInstanceId: 'coord-middle' });
    assert.equal(c.closes(), 1);
    await c.type('m'); // Below remote threshold: exercise local search.
    assert.deepEqual(c.ids(), ['new', 'middle', 'old']);
    assert.equal(c.active(), 'new');
  });
});

test('agent-chat project A searches globally, keeps project B after remote completion and Enter replaces the originating pane', async () => {
  const pending = deferred<Reply>();
  await fixture({ workspace: true, respond: () => pending.promise }, async (c) => {
    const layout = await import('../src/ui/store/workspaceLayoutSlice.ts');
    await c.wait(() => Boolean(c.el('conversation-thread-title')), 'agent breadcrumb');
    const originalPane = layout.findPaneByAgent(c.store.getState().workspaceLayout.tree, 'a')!;
    const frame = c.el(`main-pane-frame-${originalPane}`);
    await c.wait(() => /Pane project One|p1/.test(frame.textContent || ''), 'caller project A context');
    await c.click(frame.querySelector('[data-debug-id="conversation-thread-title"]'));
    await c.wait(() => c.ids().length === 3);
    await c.type('match');
    await c.wait(() => c.requests.length === 1, 'encrypted relay request');
    assert.equal(c.requests[0].project_id, '', 'pane project must never restrict encrypted search');
    assert.equal(c.requests[0].limit, 40);
    assert.ok(c.ids().includes('middle'), 'project B present before remote completion');
    await c.tick();
    pending.resolve({ hits: [hit('old', '2026-01-01', 'p1'), hit('middle', '2026-02-01'), hit('new', '2026-03-01', 'p1')] });
    await c.wait(() => !c.el('task-chain-search-state'), 'remote settled');
    assert.deepEqual(c.ids(), ['new', 'middle', 'old'], 'flat interleaved remote recency replaces relevance order');
    assert.equal(c.doc.querySelector('[role="group"]'), null);
    await c.press('ArrowDown');
    assert.equal(c.active(), 'middle');
    await c.press('Enter');
    await c.wait(() => layout.findPaneByAgent(c.store.getState().workspaceLayout.tree, 'coord-middle') === originalPane);
    assert.deepEqual(layout.selectMainAgentIds(c.store.getState()), ['coord-middle', 'b']);
    assert.equal(c.dom.window.location.hash, '#/conversations/coord-middle+b?focused=coord-middle');
  });
});

test('unscoped standalone picker sorts remote rows; click resolves missing coordinator and routes fall back correctly', async () => {
  await fixture({ respond: () => ({ hits: [hit('no-coord', '2026-01-01'), hit('remote-detail', '2026-04-01')] }) }, async (c) => {
    await c.wait(() => c.ids().length === 3);
    await c.type('match');
    await c.wait(() => c.ids()[0] === 'remote-detail');
    assert.equal(c.requests[0].project_id, '');
    await c.render({ onSelectChain: undefined, onNavigate: (route: string) => c.routes.push(route) });
    await c.click(c.el('chain-selector-item-remote-detail'));
    await c.wait(() => c.routes.length === 1);
    assert.equal(c.routes[0], '/conversations/coord-detail');
    assert.ok(c.details.includes('remote-detail'));
    await c.render({ onSelectChain: undefined, onNavigate: undefined });
    await c.click(c.el('chain-selector-item-no-coord'));
    await c.wait(() => c.dom.window.location.hash === '#/chains/no-coord');
  });
});

test('rendered search preserves stale notice, true empty and visible transport/decrypt failures with local fallback', async () => {
  await fixture({ respond: (request) => {
    if (request.query === 'stale') return { stale: true, hits: [hit('stale-result')] };
    if (request.query === 'ma') return { hits: [] };
    if (request.query === 'match transport') return { status: 503 };
    return { corrupt: true };
  } }, async (c) => {
    await c.wait(() => c.ids().length === 3);
    await c.type('stale');
    await c.wait(() => c.ids()[0] === 'stale-result');
    assert.match(c.el('task-chain-search-state').textContent, /stale/);
    await c.type('ma');
    assert.deepEqual(c.ids(), ['new', 'middle', 'old'], 'local matches exist before remote empty');
    await c.wait(() => c.requests.length === 2 && !c.el('task-chain-search-state'));
    assert.deepEqual(c.ids(), []);
    assert.ok(c.el('task-chain-selector-empty'), 'real remote empty is not merged with local matches');
    await c.type('match transport');
    await c.wait(() => /online/.test(c.el('task-chain-search-state')?.textContent || ''));
    assert.deepEqual(c.ids(), [], 'fallback respects the actual local query');
    await c.type('match');
    await c.wait(() => /rejected/.test(c.el('task-chain-search-state')?.textContent || ''));
    assert.deepEqual(c.ids(), ['new', 'middle', 'old'], 'decrypt failure shows local matches with visible error');
  });
});

test('late successes/errors and a closed modal cannot overwrite a newer query or reopened picker', async () => {
  const old = deferred<Reply>();
  const failure = deferred<Reply>();
  const closed = deferred<Reply>();
  await fixture({ respond: (request) => request.query === 'old' ? old.promise
    : request.query === 'failure' ? failure.promise
    : request.query === 'closed' ? closed.promise : { hits: [hit('latest')] } }, async (c) => {
    await c.wait(() => c.ids().length === 3);
    await c.type('old');
    await c.wait(() => c.requests.length === 1);
    await c.type('latest');
    await c.wait(() => c.ids()[0] === 'latest');
    old.resolve({ hits: [hit('obsolete')] });
    await c.tick();
    assert.deepEqual(c.ids(), ['latest']);
    await c.type('failure');
    await c.wait(() => c.requests.length === 3);
    await c.type('latest');
    await c.wait(() => c.ids()[0] === 'latest');
    failure.resolve({ status: 503 });
    await c.tick();
    assert.deepEqual(c.ids(), ['latest']);
    assert.equal(c.el('task-chain-search-state'), null);
    await c.type('closed');
    await c.wait(() => c.requests.length === 5);
    await c.render({ open: false });
    closed.resolve({ hits: [hit('obsolete-closed')] });
    await c.tick();
    assert.equal(c.el('task-chain-selector-modal'), null);
    await c.render();
    await c.wait(() => c.ids().length === 3);
    assert.deepEqual(c.ids(), ['new', 'middle', 'old']);
    assert.equal(c.input().value, '');
  });
});

test('progressive rows follow recency, expose current beyond 80, and wrap-up/down keyboard indices remain rendered', async () => {
  const many = Array.from({ length: 125 }, (_, i) => item(`row-${String(i).padStart(3, '0')}`, new Date(Date.UTC(2026, 0, i + 1)).toISOString()));
  await fixture({ groups: [group('p1', many)], currentChainId: 'row-000' }, async (c) => {
    await c.wait(() => c.ids().length === 125);
    assert.equal(c.ids()[0], 'row-124');
    assert.equal(c.active(), 'row-000', 'current is focused without pinning above newer chains');
    assert.ok(c.scrolls.includes('row-000'));
  });
  await fixture({ groups: [group('p1', many)] }, async (c) => {
    await c.wait(() => c.ids().length === 80);
    assert.equal(c.ids()[79], 'row-045');
    await c.press('ArrowUp');
    assert.equal(c.active(), 'row-000', 'wrapping up exposes the last visual option');
    assert.equal(c.ids().length, 125);
    assert.equal(c.input().getAttribute('aria-activedescendant'), 'task-chain-option-124');
    await c.press('n', { ctrlKey: true });
    assert.equal(c.active(), 'row-124');
    for (let i = 0; i < 80; i++) await c.press('ArrowDown');
    assert.equal(c.active(), 'row-044');
    await c.press('Enter');
    await c.wait(() => c.selections.length === 1);
    assert.equal(c.selections[0].chainId, 'row-044');
  });
});

test('scrolling grows the same flat sorted window', async () => {
  const many = Array.from({ length: 100 }, (_, i) => item(`scroll-${i}`, new Date(Date.UTC(2026, 0, i + 1)).toISOString()));
  await fixture({ groups: [group('p1', many)] }, async (c) => {
    await c.wait(() => c.ids().length === 80);
    const { act } = await import('react');
    await act(async () => c.el('task-chain-selector-list').dispatchEvent(new c.dom.window.Event('scroll', { bubbles: true })));
    assert.equal(c.ids().length, 100);
    assert.equal(c.ids()[99], 'scroll-0');
  });
});


test('agent-chat without project context still searches all projects', async () => {
  await fixture({ workspace: true, projectId: '', respond: () => ({ hits: [hit('middle')] }) }, async (c) => {
    await c.wait(() => Boolean(c.el('conversation-thread-title')));
    await c.click(c.el('conversation-thread-title'));
    await c.type('match');
    await c.wait(() => c.requests.length === 1 && c.ids().length === 1);
    assert.equal(c.requests[0].project_id, '');
    assert.deepEqual(c.ids(), ['middle']);
  });
});

test('rendered cache recency, equal instants and invalid timestamps follow the same visual/index order', async () => {
  await fixture({ groups: [group('p1', [item('tie-b', '2026-01-02T01:00:00+01:00'), item('invalid', 'bad')]),
    group('p2', [item('tie-a', '2026-01-02T00:00:00Z'), item('missing')])] }, async (c) => {
    await c.wait(() => c.ids().length === 4);
    const { upsertChainTitle } = await import('../src/ui/store/searchTitleSlice.ts');
    const { act } = await import('react');
    await act(async () => {
      c.store.dispatch(upsertChainTitle({ id: 'cache-only', rawTitle: 'Match cached', updatedAt: '2026-04-01' }));
      c.store.dispatch(upsertChainTitle({ id: 'invalid', rawTitle: 'Match invalid', updatedAt: '2026-03-01' }));
    });
    assert.deepEqual(c.ids(), ['cache-only', 'invalid', 'tie-a', 'tie-b', 'missing']);
    for (let i = 0; i < 5; i++) {
      const row = c.el(`chain-selector-item-${c.ids()[i]}`);
      assert.equal(row.id, `task-chain-option-${i}`);
      assert.equal(row.getAttribute('data-chain-index'), String(i));
    }
  });
});

test('debounce cancels superseded queries before dispatching any encrypted relay', async () => {
  await fixture({ respond: () => ({ hits: [hit('final')] }) }, async (c) => {
    await c.wait(() => c.ids().length === 3);
    await c.type('first');
    await c.type('second');
    await c.type('final');
    await c.wait(() => c.ids()[0] === 'final');
    assert.deepEqual(c.requests.map((r: any) => r.query), ['final']);
  });
});
