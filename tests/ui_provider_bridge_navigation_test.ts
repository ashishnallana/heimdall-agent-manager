import { test } from 'node:test';
import assert from 'node:assert/strict';
import React, { act } from 'react';
import { JSDOM } from 'jsdom';
import { Provider } from 'react-redux';
import { createRoot } from 'react-dom/client';
import { makeVaultStore, unlockVault, lockVaultFully } from './helpers/vaultEndpointHarness.ts';

const { ProvidersPanel } = await import('../src/ui/components/settings/ProvidersPanel.tsx');
const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');

test('provider overview navigates between bridge lists without implicitly selecting a bridge', async () => {
  const dom = new JSDOM('<!doctype html><div id="root"></div>', {
    url: 'http://localhost/#/settings/providers', pretendToBeVisual: true,
  });
  const replacements = {
    window: dom.window, document: dom.window.document, HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element, Node: dom.window.Node, MutationObserver: dom.window.MutationObserver,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window), IS_REACT_ACT_ENVIRONMENT: true,
    requestAnimationFrame: (callback: any) => setTimeout(callback, 0), cancelAnimationFrame: clearTimeout,
  };
  const old = Object.fromEntries(Object.keys(replacements).map((key) => [key, (globalThis as any)[key]]));
  Object.assign(globalThis, replacements);
  const store = await makeVaultStore();
  await unlockVault(store, '11'.repeat(32));
  const previousFetch = globalThis.fetch;
  const calls: string[] = [];
  const bridges = [
    { bridge_id: 'bridge_a', label: 'Riverwood', machine_hostname: 'riverwood', status: 'online', vault_status: 'unlocked' },
    { bridge_id: 'bridge_b', label: 'Laptop', machine_hostname: 'laptop', status: 'offline', vault_status: 'sealed' },
    { bridge_id: 'bridge_c', label: 'Locked', status: 'online', vault_status: 'locked' },
    { bridge_id: 'bridge_revoked', status: 'revoked' },
  ];
  const providers = [
    { provider: 'claude', profile_id: 'claude', display_name: 'Claude Code', enabled: true, state: 'present', catalog_state: 'active', models: [] },
    { provider: 'codex', profile_id: 'codex', display_name: 'Codex', enabled: false, state: 'absent', catalog_state: 'active', models: [] },
  ];
  let failBridges = false;
  let listedBridges = bridges;
  globalThis.fetch = async (url: any, init: any = {}) => {
    calls.push((init.method || 'GET') + ' ' + url);
    assert.equal(init.method || 'GET', 'GET', 'overview and navigation never mutate provider state');
    if (String(url).endsWith('/bridges') && failBridges) return new Response('{"error":{"message":"Temporary failure"}}', { status: 503 });
    const body = String(url).endsWith('/bridges') ? { bridges: listedBridges }
      : String(url).endsWith('/provider-profiles') ? { profiles: providers }
      : { providers };
    return new Response(JSON.stringify({ data: body }), { headers: { 'content-type': 'application/json' } });
  };
  const root = createRoot(dom.window.document.getElementById('root')!);
  const q = (id: string) => dom.window.document.querySelector(`[data-debug-id="${id}"]`) as HTMLElement;
  const tick = () => new Promise((resolve) => setTimeout(resolve, 35));
  const navigate = async (hash: string) => {
    await act(async () => { dom.window.location.hash = hash; await tick(); });
    await act(tick);
  };
  try {
    await act(async () => { root.render(React.createElement(Provider, { store }, React.createElement(ProvidersPanel))); await tick(); });
    await act(tick);
    assert.ok(q('providers-bridge-overview'), dom.window.document.body.textContent || 'empty');
    assert.equal(q('provider-profiles'), null);
    assert.equal(q('providers-bridge-bridge_revoked'), null);
    assert.match(q('providers-bridge-bridge_a').textContent!, /Claude Code/);
    assert.match(q('providers-bridge-bridge_a').textContent!, /1 not installed/);
    assert.match(q('providers-bridge-bridge_b').textContent!, /Offline/);
    assert.equal(q('providers-bridge-bridge_a').getAttribute('href'), '#/settings/providers/bridge_a');

    await act(async () => { q('providers-bridge-bridge_a').click(); await tick(); });
    await act(tick);
    assert.ok(q('profiles-list'));
    assert.ok(q('profile-select-claude'));
    assert.equal((q('profile-add') as HTMLButtonElement).disabled, false);
    assert.match(dom.window.document.querySelector('h1')!.textContent!, /Riverwood/);
    assert.equal(q('providers-bridge-overview'), null);

    await navigate('#/settings/providers/bridge_b');
    assert.match(dom.window.document.querySelector('h1')!.textContent!, /Laptop/);
    assert.ok(q('profile-locked'));
    assert.equal((q('profile-add') as HTMLButtonElement).disabled, true);
    assert.equal((q('profile-select-claude') as HTMLButtonElement).disabled, true);
    await navigate('#/settings/providers/bridge_c');
    assert.ok(q('profile-locked'));
    assert.equal((q('profiles-refresh') as HTMLButtonElement).disabled, true);

    await act(async () => { q('providers-all-bridges').click(); await tick(); });
    await act(tick);
    assert.ok(q('providers-bridge-overview'));
    await navigate('#/settings/providers?bridge=bridge_a');
    assert.ok(q('profile-select-claude'), 'legacy bridge bookmark remains supported');
    await navigate('#/settings/providers/missing');
    assert.match(dom.window.document.body.textContent!, /no longer available/);
    assert.equal(q('provider-profiles'), null, 'missing bridge must never fall back to a different bridge');
    await navigate('#/settings/providers');
    failBridges = true;
    await act(async () => { store.dispatch(heimdallApi.util.invalidateTags([{ type: 'Bridges', id: 'LIST' }])); await tick(); });
    await act(tick);
    assert.ok(q('providers-retry'), 'bridge list error provides a retry');
    failBridges = false;
    await act(async () => { q('providers-retry').click(); await tick(); });
    await act(tick);
    assert.ok(q('providers-bridge-overview'), 'retry recovers the overview');
    listedBridges = [];
    await act(async () => { store.dispatch(heimdallApi.util.invalidateTags([{ type: 'Bridges', id: 'LIST' }])); await tick(); });
    await act(tick);
    assert.match(dom.window.document.body.textContent!, /Enroll a bridge/);
    assert.equal(q('provider-profiles'), null);
    assert.ok(calls.length > 0);
  } finally {
    await act(async () => { root.unmount(); store.dispatch(heimdallApi.util.resetApiState()); });
    await lockVaultFully(store);
    // RTK Query schedules cache subscription cleanup after unmount.
    await act(async () => { await new Promise((resolve) => setTimeout(resolve, 600)); });
    globalThis.fetch = previousFetch;
    Object.assign(globalThis, old);
    dom.window.close();
  }
});
