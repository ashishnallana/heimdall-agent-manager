import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';

const json = (body: any, status = 200) => ({
  ok: status < 400, status, headers: { get: () => 'application/json' },
  text: async () => JSON.stringify(body), json: async () => body,
});
const chain = (id: string, extra = {}) => ({
  chain_id: id, title: `Title ${id}`, status: 'active', project_id: '',
  updated_at: '2026-10-01T00:00:00Z', coordinator_agent_instance_id: 'coord', ...extra,
});
const page = (rows: any[], next: string | null = null) => json({ data: rows, page: { next_cursor: next, has_more: Boolean(next) } });
const deferred = () => {
  let resolve!: (value: any) => void;
  const promise = new Promise<any>(r => { resolve = r; });
  return { resolve, promise };
};

async function fixture(run: (f: any) => Promise<void>, reply: (url: URL, init: any) => any) {
  const { JSDOM } = await import('jsdom');
  const dom = new JSDOM('<!doctype html><div id="root"></div>', { url: 'http://localhost/#/home' });
  const names = ['window', 'document', 'HTMLElement', 'localStorage', 'navigator', 'fetch', 'IntersectionObserver', 'requestAnimationFrame', 'cancelAnimationFrame'];
  const prior = new Map(names.map(name => [name, Object.getOwnPropertyDescriptor(globalThis, name)]));
  for (const name of ['window', 'document', 'HTMLElement', 'localStorage', 'navigator']) {
    Object.defineProperty(globalThis, name, { configurable: true, writable: true, value: name === 'window' ? dom.window : (dom.window as any)[name] });
  }
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  const observers: any[] = [];
  class IO {
    target: any; disconnected = false; callback: any; options: any;
    constructor(callback: any, options: any) { this.callback = callback; this.options = options; observers.push(this); }
    observe(target: any) { this.target = target; }
    disconnect() { this.disconnected = true; }
    unobserve() {}
    fire() { this.callback([{ isIntersecting: true, target: this.target }]); }
  }
  (globalThis as any).IntersectionObserver = IO;
  (globalThis as any).requestAnimationFrame = (cb: any) => setTimeout(cb, 0);
  (globalThis as any).cancelAnimationFrame = clearTimeout;
  const requests: URL[] = [];
  (globalThis as any).fetch = (input: any, init: any = {}) => {
    const url = new URL(String(input?.url ?? input), 'http://localhost');
    requests.push(url);
    return Promise.resolve(reply(url, init));
  };
  const { createRoot } = await import('react-dom/client');
  const { act } = await import('react');
  const { Provider } = await import('react-redux');
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const { SidebarTaskChains } = await import('../src/ui/components/shell/SidebarTaskChains.tsx');
  const { AuthUserProvider } = await import('../src/ui/components/auth/AuthUserContext.tsx');
  const { configureStore } = await import('@reduxjs/toolkit');
  const vault = (await import('../src/ui/store/vaultSlice.ts')).default;
  const searchTitle = (await import('../src/ui/store/searchTitleSlice.ts')).default;
  const store = configureStore({
    reducer: { vault, searchTitle, [heimdallApi.reducerPath]: heimdallApi.reducer },
    middleware: g => g({ serializableCheck: false }).concat(heimdallApi.middleware),
  });
  const root = createRoot(dom.window.document.getElementById('root')!);
  const scrollRoot = dom.window.document.createElement('div');
  dom.window.document.body.append(scrollRoot);
  let props = { scrollRoot, active: true, currentPath: '/home', onNavigate: () => {} };
  const render = async (next = {}) => {
    props = { ...props, ...next };
    await act(async () => root.render(React.createElement(Provider, { store },
      React.createElement(AuthUserProvider, { value: { user_id: 'sidebar-test-owner' } },
        React.createElement(SidebarTaskChains, props)))));
  };
  const wait = async (predicate: () => boolean) => {
    for (let i = 0; i < 100; i++) {
      if (predicate()) return;
      await act(async () => { await new Promise(r => setTimeout(r, 5)); });
    }
    throw Error('condition timed out');
  };
  const doc = dom.window.document;
  const rows = () => Array.from(doc.querySelectorAll('[data-debug-id^="sidebar-chain-row-"]')).map((el: any) => el.getAttribute('data-debug-id').slice('sidebar-chain-row-'.length));
  const observer = () => observers.filter(o => o.target && !o.disconnected).at(-1);
  const fire = async () => { await act(async () => observer()?.fire()); };
  const click = async (id: string) => { await act(async () => (doc.querySelector(`[data-debug-id="${id}"]`) as any).click()); };
  try { await run({ dom, doc, store, act, render, wait, rows, observer, fire, click, requests, scrollRoot }); }
  finally {
    await act(async () => { root.unmount(); store.dispatch(heimdallApi.util.resetApiState()); });
    dom.window.close();
    for (const name of names) { const descriptor = prior.get(name); if (descriptor) Object.defineProperty(globalThis, name, descriptor); else delete (globalThis as any)[name]; }
  }
}

test('sidebar pages share the nav root, fill through exhaustion, dedupe rows and in-flight requests', async () => {
  const pending = deferred();
  await fixture(async f => {
    await f.render();
    await f.wait(() => f.rows().length === 2);
    assert.equal(f.observer().options.root, f.scrollRoot);
    assert.equal(f.requests.length, 1);
    assert.equal(f.requests[0].searchParams.get('flat'), '1');
    assert.equal(f.requests[0].searchParams.get('limit'), '20');
    await f.fire();
    await f.act(async () => { f.observer()?.fire(); f.observer()?.fire(); });
    assert.equal(f.requests.length, 2);
    await f.act(async () => pending.resolve(page([chain('b'), chain('c')], 'cursor-2')));
    await f.wait(() => f.rows().length === 3);
    assert.deepEqual(f.rows(), ['a', 'b', 'c']);
    await f.fire(); // reattached even while the foot stays visible: viewport fill
    await f.wait(() => f.rows().length === 4);
    assert.deepEqual(f.rows(), ['a', 'b', 'c', 'd']);
    assert.equal(f.observer(), undefined);
    await f.fire();
    assert.equal(f.requests.length, 3);
    assert.deepEqual(f.requests.map((u: URL) => u.searchParams.get('cursor')), [null, 'cursor-1', 'cursor-2']);
    await f.render({ active: false }); await f.render({ active: true });
    assert.equal(f.requests.length, 3, 'collapse/reopen does not reset the list');
  }, url => {
    const cursor = url.searchParams.get('cursor');
    if (!cursor) return page([chain('a'), chain('b')], 'cursor-1');
    if (cursor === 'cursor-1') return pending.promise;
    return page([chain('d')]);
  });
});

test('loading, initial error/explicit retry, paging error retention and exhaustion/empty are distinct', async () => {
  const pending = deferred(); let attempt = 0; let failPage = true;
  await fixture(async f => {
    await f.render();
    assert.match(f.doc.body.textContent, /Loading task chains/);
    await f.act(async () => pending.resolve(json({ error: { message: 'fail' } }, 503)));
    await f.wait(() => Boolean(f.doc.querySelector('[data-debug-id="sidebar-chain-retry"]')));
    assert.equal(f.doc.querySelector('[data-debug-id="sidebar-chain-empty"]'), null);
    assert.equal(f.observer(), undefined);
    await f.click('sidebar-chain-retry');
    await f.wait(() => f.rows().length === 1);
    await f.fire();
    await f.wait(() => /Could not load more/.test(f.doc.body.textContent));
    assert.deepEqual(f.rows(), ['a']);
    assert.equal(f.observer(), undefined, 'paging failure waits for explicit retry');
    failPage = false;
    await f.click('sidebar-chain-retry');
    await f.wait(() => f.rows().length === 2);
    assert.deepEqual(f.rows(), ['a', 'b']);
  }, url => {
    if (!url.searchParams.get('cursor')) return ++attempt === 1 ? pending.promise : page([chain('a')], 'next');
    return failPage ? json({ error: { message: 'fail page' } }, 503) : page([chain('b')]);
  });
  await fixture(async f => {
    await f.render();
    await f.wait(() => Boolean(f.doc.querySelector('[data-debug-id="sidebar-chain-empty"]')));
    assert.match(f.doc.body.textContent, /No task chains yet/);
    assert.equal(f.requests.length, 1);
    assert.equal(f.observer(), undefined);
  }, () => page([]));
});

test('creation refresh cancels paging, drops late old pages and dedupes local/WS echoes; unrelated events do not fetch', async () => {
  const pending = deferred(); let initial = 0;
  await fixture(async f => {
    const { announceTaskChainCreated } = await import('../src/ui/api/taskChainCreationEvents.ts');
    const { handleUserWsEvent, resetQueuedInvalidations } = await import('../src/ui/api/wsInvalidation.ts');
    const { tasksApi } = await import('../src/ui/api/endpoints/tasks.ts');
    await f.render();
    await f.wait(() => f.rows().length === 1);
    await f.fire();
    const signal = pendingSignal!;
    await f.act(async () => announceTaskChainCreated('chain-fresh-from-creation'));
    await f.wait(() => f.rows().includes('new'));
    assert.equal(signal.aborted, true);
    await f.act(async () => pending.resolve(page([chain('late-old')])));
    assert.deepEqual(f.rows(), ['new']);
    const n = f.requests.length;
    await f.act(async () => {
      handleUserWsEvent(f.store.dispatch, { type: 'resource_changed', resource: 'task_chain', resource_id: 'chain-fresh-from-creation', change: 'created' });
      handleUserWsEvent(f.store.dispatch, { type: 'resource_changed', resource: 'task_chain', resource_id: 'new', change: 'updated' });
      f.store.dispatch(tasksApi.util.invalidateTags(['ChainList', 'Chain']));
    });
    assert.equal(f.requests.length, n);
    assert.equal(f.requests.some((u: URL) => /\/tasks/.test(u.pathname)), false, 'no per-row tasks request');
    resetQueuedInvalidations();
  }, (url, init) => {
    if (url.searchParams.get('cursor')) { pendingSignal = init.signal; return pending.promise; }
    return ++initial === 1 ? page([chain('old')], 'next') : page([chain('new')]);
  });
});
let pendingSignal: AbortSignal | undefined;

test('malformed or cyclic cursor is a retryable error, never automatic looping', async () => {
  await fixture(async f => {
    await f.render(); await f.wait(() => f.rows().length === 1);
    await f.fire();
    await f.wait(() => Boolean(f.doc.querySelector('[data-debug-id="sidebar-chain-retry"]')));
    assert.deepEqual(f.rows(), ['a']);
    assert.equal(f.requests.length, 2);
    assert.equal(f.observer(), undefined);
  }, url => !url.searchParams.get('cursor') ? page([chain('a')], 'same') : page([chain('b')], 'same'));
});

test('rows retain chain-addressed links, coordinator detail fallback and locked-title shielding', async () => {
  let navigated = 0;
  await fixture(async f => {
    await f.render({ onNavigate: () => { navigated++; } });
    await f.wait(() => f.rows().length === 3);
    assert.doesNotMatch(f.doc.body.textContent, /vault:v2|ciphertext/);
    assert.equal(f.doc.querySelector('[data-debug-id="sidebar-chain-row-a"]').getAttribute('href'), '#/conversations/chain:a');
    await f.click('sidebar-chain-row-a');
    assert.equal(f.dom.window.location.hash, '#/conversations/chain:a');
    await f.click('sidebar-chain-row-b');
    assert.equal(f.dom.window.location.hash, '#/conversations/chain:b');
    await f.click('sidebar-chain-row-c');
    assert.equal(f.dom.window.location.hash, '#/chains/c');
    assert.equal(navigated, 3, 'mobile drawer closes after selecting a chain');
    assert.equal(f.requests.filter((u: URL) => u.pathname === '/api/v1/task-chains').length, 1);
  }, url => {
    if (url.pathname.endsWith('/task-chains/b')) return json({ data: { chain_id: 'b', members: [{ role: 'coordinator', agent_instance_id: 'coord-b' }] } });
    if (url.pathname.endsWith('/task-chains/c')) return json({ data: { chain_id: 'c', members: [] } });
    return page([chain('a', { title: 'vault:v2:7e57000000000001:e1:ciphertext' }), chain('b', { coordinator_agent_instance_id: '' }), chain('c', { coordinator_agent_instance_id: '' })]);
  });
});

test('the real create mutation refreshes once on success, ignores failure and coalesces its WS echo', async () => {
  let initial = 0; let failCreate = false;
  await fixture(async f => {
    const { tasksApi } = await import('../src/ui/api/endpoints/tasks.ts');
    const { handleUserWsEvent, resetQueuedInvalidations } = await import('../src/ui/api/wsInvalidation.ts');
    await f.render(); await f.wait(() => f.rows().includes('before-create'));
    await f.act(async () => {
      await f.store.dispatch(tasksApi.endpoints.createTaskChain.initiate({ title: 'Created chain' })).unwrap();
    });
    await f.wait(() => f.rows().includes('after-create'));
    const listCount = () => f.requests.filter((u: URL) => u.searchParams.get('flat') === '1').length;
    assert.equal(listCount(), 2);
    await f.act(async () => handleUserWsEvent(f.store.dispatch, {
      type: 'resource_changed', resource: 'task_chain', resource_id: 'real-created-chain', change: 'created',
    }));
    assert.equal(listCount(), 2, 'success plus its WS echo cause one refresh');
    failCreate = true;
    await f.act(async () => { await f.store.dispatch(tasksApi.endpoints.createTaskChain.initiate({ title: 'Failed chain' })); });
    assert.equal(listCount(), 2, 'a failed creation cannot refresh');
    await f.act(async () => handleUserWsEvent(f.store.dispatch, {
      type: 'resource_changed', resource: 'task_chain', resource_id: 'remote-created-chain', change: 'created',
    }));
    await f.wait(() => listCount() === 3);
    resetQueuedInvalidations();
  }, (url, init) => {
    if (init.method === 'POST') return failCreate ? json({ error: { message: 'creation failed' } }, 503) : json({ data: { chain_id: 'real-created-chain' } });
    return ++initial === 1 ? page([chain('before-create')]) : page([chain('after-create')]);
  });
});
