// Device gate (components/devices/DeviceVaultScreens.tsx; plan §2 P3 "A pending
// device cannot reach decrypted UI"). Only a device whose keyring is installed
// ('ready') renders the app; every other state renders its gate screen INSTEAD, and
// a parked device (pending / revoked / not yet known to the hub) is redirected to
// #/device/enroll whatever deep link it opened. Hermetic: fake hub, memory store.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_vault_device_gate_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { REPO_ROOT } from './helpers/vaultEndpointHarness.ts';
import { FakeHub, USER, hubApi, newBrowser } from './helpers/vaultDirectoryFixture.ts';

const React = (await import('react')).default;
const { renderToStaticMarkup } = await import('react-dom/server');
const { Provider } = await import('react-redux');
const { configureStore } = await import('@reduxjs/toolkit');
const screens = await import('../src/ui/components/devices/DeviceVaultScreens.tsx');
const deviceVaultReducer = (await import('../src/ui/store/deviceVaultSlice.ts')).default;
const { initialDeviceVaultState } = await import('../src/ui/store/deviceVaultSlice.ts');
const dv = await import('../src/ui/services/deviceVault.ts');
const ident = await import('../src/ui/utils/deviceIdentity.ts');

const APP = React.createElement('div', { 'data-debug-id': 'decrypted-app' }, 'secret chat');

/** A window with a hash route and a recording history.replaceState. */
function withWindow(hash: string, fn: (w: any) => void) {
  const prev = (globalThis as any).window;
  const w: any = { location: { hash } };
  w.history = { state: null, replaceState: (_s: unknown, _t: string, url: string) => { w.location.hash = url; } };
  (globalThis as any).window = w;
  try { fn(w); } finally { (globalThis as any).window = prev; }
}

function renderGate(state: any): string {
  const store = configureStore({ reducer: { deviceVault: deviceVaultReducer }, preloadedState: { deviceVault: state } });
  return renderToStaticMarkup(React.createElement(Provider, { store }, React.createElement(screens.DeviceVaultGate, null, APP)));
}

const NOT_READY = ['unsupported', 'initializing', 'genesis', 'pending-approval', 'other-account', 'revoked', 'reset-scheduled', 'error'] as const;

test('only a ready device renders the app; every other state renders a gate screen instead', () => {
  for (const status of NOT_READY) {
    withWindow('#/conversations/conv_1', () => {
      const html = renderGate({ ...initialDeviceVaultState, status, userCode: 'ABCD-EFGH-JKLM', otherAccounts: ['usr_other'] });
      assert.doesNotMatch(html, /decrypted-app|secret chat/, `${status} must not render decrypted UI`);
    });
  }
  withWindow('#/conversations/conv_1', () => {
    assert.match(renderGate({ ...initialDeviceVaultState, status: 'ready' }), /decrypted-app/);
  });
});

test('an IndexedDB backing-store failure explains the locked-profile case; other errors do not', () => {
  withWindow('#/', () => {
    const locked = renderGate({ ...initialDeviceVaultState, status: 'error', errorMessage: 'Internal error opening backing store for indexedDB.open.' });
    assert.match(locked, /device-vault-storage-locked-hint/);
    assert.match(locked, /quit every copy/);
    const other = renderGate({ ...initialDeviceVaultState, status: 'error', errorMessage: 'directory fetch failed' });
    assert.doesNotMatch(other, /device-vault-storage-locked-hint/);
  });
});

test('pending, revoked, other-account and reset-scheduled devices are parked on #/device/enroll', () => {
  for (const status of ['pending-approval', 'revoked', 'other-account', 'reset-scheduled']) {
    withWindow('#/conversations/conv_1?msg=m1', (w) => {
      screens.syncGateRoute(status);
      assert.equal(w.location.hash, `#${screens.DEVICE_ENROLL_ROUTE}`, status);
    });
  }
  // A ready device leaves the enroll route for Home, and keeps any other route.
  withWindow(`#${screens.DEVICE_ENROLL_ROUTE}`, (w) => { screens.syncGateRoute('ready'); assert.equal(w.location.hash, '#/home'); });
  withWindow('#/conversations/conv_1', (w) => { screens.syncGateRoute('ready'); assert.equal(w.location.hash, '#/conversations/conv_1'); });
});

test('a browser the hub does not know yet registers, is parked and never renders the app', async () => {
  const hub = new FakeHub();
  await hub.genesis(await newBrowser());
  const kv = ident.memoryDeviceStore();
  dv.configureDeviceVault({ kv, bridges: null, pollIntervalMs: 1e9, api: hubApi(hub) });
  const store = configureStore({ reducer: { deviceVault: deviceVaultReducer } });
  dv.stopDeviceVault();
  await dv.bootDeviceVault(USER, store.dispatch as any);
  const state = store.getState().deviceVault;
  assert.equal(state.status, 'pending-approval');
  assert.ok(hub.rows.get(state.deviceId)?.status === 'pending', 'registered as pending');
  withWindow('#/conversations/conv_1', (w) => {
    const html = renderToStaticMarkup(React.createElement(Provider, { store }, React.createElement(screens.DeviceVaultGate, null, APP)));
    assert.equal(w.location.hash, '#/device/enroll');
    assert.doesNotMatch(html, /decrypted-app/);
    assert.match(html, /device-waiting-screen/);
    assert.match(html, new RegExp(state.userCode), 'the waiting screen shows the pairing code');
  });
  dv.stopDeviceVault();
});

test('the whole authenticated shell sits behind the gate', () => {
  const source = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/shell/AppShell.tsx'), 'utf8');
  assert.match(source, /<DeviceVaultGate>\s*<AuthenticatedShell\b[^>]*\/>\s*<\/DeviceVaultGate>/);
});
