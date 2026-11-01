import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import React, { act } from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { configureStore } from '@reduxjs/toolkit';

const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
await import('../src/ui/api/endpoints/bridgeSupport.ts');
const { default: SetupWizardPage } = await import('../src/ui/components/setup/SetupWizardPage.tsx');
const session = await import('../src/ui/bridge/desktopBridgeSession.ts');

test('profile visibility defaults to own profiles and resets on an account switch', async () => {
  const { default: Inventory } = await import('../src/ui/components/settings/BridgeProfileInventory.tsx');
  const dom = new JSDOM('<div id="root"></div>');
  const saved = new Map<string, PropertyDescriptor | undefined>();
  for (const [key, value] of Object.entries({ window: dom.window, document: dom.window.document,
    HTMLElement: dom.window.HTMLElement, Node: dom.window.Node, IS_REACT_ACT_ENVIRONMENT: true })) {
    saved.set(key, Object.getOwnPropertyDescriptor(globalThis, key));
    Object.defineProperty(globalThis, key, { value, writable: true, configurable: true });
  }
  const root = createRoot(dom.window.document.getElementById('root')!);
  const profiles: any[] = [
    { profile: 'p1', service: 's1', enrolled: true, bridge_id: 'brg_a' },
    { profile: 'p2', service: 's2', enrolled: true, bridge_id: 'brg_b' },
    { profile: 'available', service: 's3', enrolled: false },
  ];
  const query = (id: string) => dom.window.document.querySelector(`[data-debug-id="${id}"]`);
  const render = async (accountBridgeIds: string[]) => {
    await act(async () => root.render(React.createElement(Inventory, { profiles, accountBridgeIds, debugId: 'inventory' })));
  };
  try {
    await render(['brg_a']);
    assert.ok(query('inventory-p1'));
    assert.equal(query('inventory-p2'), null);
    assert.equal(query('inventory-available'), null);
    assert.equal(query('inventory-show-others')?.getAttribute('aria-checked'), 'false');
    await act(async () => query('inventory-show-others')!.dispatchEvent(new dom.window.MouseEvent('click', { bubbles: true })));
    assert.ok(query('inventory-p2'));
    assert.ok(query('inventory-available'));
    await render(['brg_b']);
    assert.ok(query('inventory-p2'));
    assert.equal(query('inventory-p1'), null, 'the previous account visibility choice does not carry over');
    assert.equal(query('inventory-available'), null);
    assert.equal(query('inventory-show-others')?.getAttribute('aria-checked'), 'false');
    await render(['brg_a']);
    assert.ok(query('inventory-p1'));
    assert.equal(query('inventory-p2'), null, 'returning to the first account also starts with its own profiles');
    assert.equal(query('inventory-show-others')?.getAttribute('aria-checked'), 'false');
  } finally {
    await act(async () => root.unmount());
    dom.window.close();
    for (const [key, descriptor] of saved) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor); else delete (globalThis as any)[key];
    }
  }
});

for (const scenario of ['empty', 'named', 'other-account', 'own-default'] as const) {
  test(`setup profile discovery and selection: ${scenario}`, async () => {
    session.resetDesktopBridgeSessionForTests();
    const hub = 'https://hub.example.test';
    const dom = new JSDOM('<div id="root"></div>', { url: hub, pretendToBeVisual: true });
    dom.window.HTMLElement.prototype.scrollIntoView = () => {};
    const saved = new Map<string, PropertyDescriptor | undefined>();
    for (const [key, value] of Object.entries({ window: dom.window, document: dom.window.document,
      HTMLElement: dom.window.HTMLElement, Node: dom.window.Node, IS_REACT_ACT_ENVIRONMENT: true,
      CSS: { escape: (value: string) => value.replace(/[^a-zA-Z0-9_-]/g, (ch) => `\\${ch}`) },
      requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window), cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window) })) {
      saved.set(key, Object.getOwnPropertyDescriptor(globalThis, key));
      Object.defineProperty(globalThis, key, { value, writable: true, configurable: true });
    }
    const profiles: any[] = scenario === 'empty' ? [] : [{ installed: true, supported: true, hub,
      profile: scenario === 'named' ? 'personal' : scenario === 'other-account' ? 'p1' : '',
      service: 'test-service', enrolled: scenario !== 'named', bridge_id: scenario === 'named' ? '' : 'brg_a', state: 'connected', error: '' }];
    const runs: any[] = [];
    let listener: (event: any) => void = () => {};
    const manager: any = {
      getConfig: async () => ({ ok: true, supported: true, hubUrl: hub, bundledVersion: '' }),
      setHubUrl: async () => ({ ok: true }), list: async () => ({ ok: true, profiles }),
      getStatus: async () => profiles[0], cancel: async () => ({ ok: true }), openLog: async () => ({ ok: true }),
      run: async (kind: string, target: any, options: any) => { runs.push({ kind, target, options }); return { ok: true }; },
      onEvent: (fn: any) => { listener = fn; return () => {}; },
    };
    (dom.window as any).odinApi = { bridgeManager: manager };
    const store = configureStore({ reducer: { [heimdallApi.reducerPath]: heimdallApi.reducer },
      middleware: (gdm) => gdm().concat(heimdallApi.middleware), enhancers: (gde) => gde({ autoBatch: false }) });
    await store.dispatch(heimdallApi.util.upsertQueryData('listBridges', undefined,
      { bridges: scenario === 'own-default' ? [{ bridge_id: 'brg_a', label: 'My computer' }] : [] }));
    const root = createRoot(dom.window.document.getElementById('root')!);
    const query = (id: string) => dom.window.document.querySelector(`[data-debug-id="${id}"]`) as HTMLElement | null;
    const click = async (id: string) => {
      assert.ok(query(id), `${id} exists`);
      await act(async () => { query(id)!.dispatchEvent(new dom.window.MouseEvent('click', { bubbles: true })); });
    };
    try {
      await act(async () => { root.render(React.createElement(Provider, { store, children: React.createElement(SetupWizardPage, { userId: 'user2' }) })); });
      await act(async () => { await new Promise((resolve) => setTimeout(resolve, 0)); });
      if (scenario === 'own-default') {
        assert.equal(query('setup-machine-profile')?.textContent, 'Default (unnamed)');
        assert.equal(query('setup-install-btn'), null);
        return;
      }
      if (scenario === 'empty') assert.match(query('setup-detected-profiles-empty')?.textContent || '', /No Bridge profiles installed/);
      if (scenario === 'other-account') {
        assert.equal(query('setup-detected-profiles-p1'), null, 'other accounts are hidden by default');
        assert.match(query('setup-detected-profiles-account-empty')?.textContent || '', /No Bridge profiles linked to your account/);
        await click('setup-detected-profiles-show-others');
        assert.match(query('setup-detected-profiles-p1')?.textContent || '', /p1.*Not linked to this account/);
        await click('setup-detected-profiles-show-others');
        assert.equal(query('setup-detected-profiles-p1'), null);
        assert.equal(query('setup-machine-card'), null);
      }
      const select = query('setup-profile-select');
      assert.ok(select);
      if (scenario === 'empty') {
        await click('setup-profile-select');
        const create = [...dom.window.document.querySelectorAll('[role="option"]')].find((o) => o.textContent?.includes('Create a named profile'));
        assert.ok(create);
        await act(async () => { create.dispatchEvent(new dom.window.MouseEvent('click', { bubbles: true })); });
        assert.ok(query('setup-profile-name-input'), 'a new profile has a named input');
        assert.equal((query('setup-install-btn') as HTMLButtonElement).disabled, true, 'an empty custom name cannot start setup');
        await click('setup-profile-select');
        const defaultOption = [...dom.window.document.querySelectorAll('[role="option"]')].find((o) => o.textContent === 'Default (unnamed)');
        assert.ok(defaultOption);
        await act(async () => { defaultOption.dispatchEvent(new dom.window.MouseEvent('click', { bubbles: true })); });
      }
      if (scenario === 'named') {
        await click('setup-profile-select');
        const option = [...dom.window.document.querySelectorAll('[role="option"]')].find((o) => o.textContent === 'personal');
        assert.ok(option);
        await act(async () => { option.dispatchEvent(new dom.window.MouseEvent('click', { bubbles: true })); });
      }
      const expectedProfile = scenario === 'named' ? 'personal' : '';
      await click('setup-install-btn');
      assert.deepEqual(runs[0], { kind: 'setup', target: { hub, profile: expectedProfile }, options: { separateAccount: true, inAppApproval: true } });
      await act(async () => { listener({ type: 'error', message: 'service failed', step: 'service' }); });
      await click('setup-install-retry-btn');
      assert.deepEqual(runs[1], runs[0], 'retry keeps the selected profile and account isolation');
    } finally {
      await act(async () => root.unmount());
      store.dispatch(heimdallApi.util.resetApiState());
      session.resetDesktopBridgeSessionForTests();
      dom.window.close();
      for (const [key, descriptor] of saved) {
        if (descriptor) Object.defineProperty(globalThis, key, descriptor); else delete (globalThis as any)[key];
      }
    }
  });
}
