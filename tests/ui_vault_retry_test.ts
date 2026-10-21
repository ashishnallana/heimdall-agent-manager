// Device-vault registration under auth failures (services/deviceVault). A refused
// signed status check (401, or 403/404 for a device the directory lists) must surface
// an error instead of registering again and replacing the pending pairing code; a
// failed registration must leave no orphan code. Legitimate first registration (the
// hub's 403 for an unknown signer) and reuse of a live pending code still work.
// Hermetic: fake hub, memory device store.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_vault_retry_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { FakeHub, USER, hubApi, newBrowser, recorder } from './helpers/vaultDirectoryFixture.ts';

const dv = await import('../src/ui/services/deviceVault.ts');
const ident = await import('../src/ui/utils/deviceIdentity.ts');
const { ApiError } = await import('../src/ui/api/cookieFetch.ts');

const STATUS = 'deviceVault/deviceVaultStatusChanged';
const FAILED = 'deviceVault/deviceVaultFailed';

/**
 * A hub with a root device and a vault API whose self check and register POST a test
 * can break. `selfError` (when set) is thrown by /devices/self; unknown devices get the
 * real hub's 403. `registerError` is thrown by /devices/register.
 */
async function setup() {
  const hub = new FakeHub();
  await hub.genesis(await newBrowser());
  const kv = ident.memoryDeviceStore();
  const base = hubApi(hub);
  const state = { selfError: null as Error | null, registerError: null as Error | null, registerResult: null as ((r: any) => any) | null, registers: 0 };
  dv.configureDeviceVault({
    kv, bridges: null, pollIntervalMs: 1e9,
    api: hubApi(hub, {
      fetchVaultSelf: async (signed: any) => {
        if (state.selfError) throw state.selfError;
        const self = await base.fetchVaultSelf(signed);
        if (!self) throw new ApiError("signing device is not in this account's directory", 403, 'forbidden');
        return self;
      },
      postVaultRegister: async (...args: any[]) => {
        state.registers++;
        if (state.registerError) throw state.registerError;
        const res = await base.postVaultRegister(...args);
        return state.registerResult ? state.registerResult(res) : res;
      },
    }),
  });
  const rec = recorder();
  dv.stopDeviceVault();
  return { hub, kv, rec, state, boot: () => dv.bootDeviceVault(USER, rec.dispatch) };
}

test('first registration: an unknown device (hub 403) registers once and stores its code', async () => {
  const { kv, rec, state, boot } = await setup();
  await boot();
  assert.equal(state.registers, 1);
  const shown = rec.last(STATUS);
  assert.equal(shown.status, 'pending-approval');
  assert.equal((await kv.get(`pending:${USER}`) as any).code, shown.userCode);
  dv.stopDeviceVault();
});

test('pending reuse: a pending device shows its stored code without registering again', async () => {
  const { kv, rec, state, boot } = await setup();
  await boot();
  const code = rec.last(STATUS).userCode;
  await dv.refreshDeviceVault('poll');
  await dv.refreshDeviceVault('poll');
  assert.equal(state.registers, 1);
  assert.equal(rec.last(STATUS).status, 'pending-approval');
  assert.equal(rec.last(STATUS).userCode, code);
  assert.equal((await kv.get(`pending:${USER}`) as any).code, code);
  dv.stopDeviceVault();
});

for (const [status, msg] of [[401, 'device request signature required'], [403, 'csrf_rejected'], [404, 'not found']] as const) {
  test(`pending device: a ${status} status check does not re-register or replace the code`, async () => {
    const { kv, rec, state, boot } = await setup();
    await boot();
    const before = await kv.get(`pending:${USER}`);
    const identity = await ident.loadDeviceIdentity(kv, USER);
    state.selfError = new ApiError(msg, status, 'unauthenticated');
    for (let i = 0; i < 3; i++) await dv.refreshDeviceVault('poll');
    assert.equal(state.registers, 1, 'no further registration');
    assert.deepEqual(await kv.get(`pending:${USER}`), before, 'pending code kept');
    assert.equal((await ident.loadDeviceIdentity(kv, USER))!.deviceId, identity!.deviceId, 'identity kept');
    const failed = rec.last(FAILED);
    assert.equal(failed.code, 'device_auth_failed');
    assert.match(failed.message, new RegExp(`HTTP ${status}`));
    assert.match(failed.message, /X-Heimdall-Device-\*/);
    // Once the hub accepts the signature again, the kept code is shown.
    state.selfError = null;
    await dv.refreshDeviceVault('retry');
    assert.equal(rec.last(STATUS).status, 'pending-approval');
    assert.equal(rec.last(STATUS).userCode, (before as any).code);
    assert.equal(state.registers, 1);
    dv.stopDeviceVault();
  });
}

test('fresh device: a 401 status check never registers', async () => {
  const { kv, rec, state, boot } = await setup();
  state.selfError = new ApiError('device request signature required', 401, 'unauthenticated');
  await boot();
  await dv.refreshDeviceVault('retry');
  assert.equal(state.registers, 0);
  assert.equal(await kv.get(`pending:${USER}`), undefined);
  assert.equal(rec.last(FAILED).code, 'device_auth_failed');
  dv.stopDeviceVault();
});

for (const [name, err] of [
  ['rate-limited', new ApiError('too many registrations; retry shortly', 429, 'rate_limited')],
  ['refused', new ApiError('csrf_rejected', 403, 'forbidden')],
] as const) {
  test(`fresh device: a ${name} registration leaves no orphan pending code`, async () => {
    const { kv, rec, state, boot } = await setup();
    state.registerError = err;
    await boot();
    assert.equal(state.registers, 1);
    assert.equal(await kv.get(`pending:${USER}`), undefined, 'no orphan code');
    assert.ok(rec.last(FAILED), 'the failure is surfaced');
    assert.ok(!rec.actions.some((a) => a.type === STATUS && a.payload.status === 'pending-approval'));
    dv.stopDeviceVault();
  });
}

test('a registration the hub answers for another device or fingerprint stores no code', async () => {
  const { kv, rec, state, boot } = await setup();
  state.registerResult = (r) => ({ ...r, fingerprint: 'ffff ffff' });
  await boot();
  assert.equal(await kv.get(`pending:${USER}`), undefined);
  assert.match(rec.last(FAILED).message, /different device id or fingerprint/);
  dv.stopDeviceVault();
});

test('new code request: a failed registration keeps the existing pending code', async () => {
  const { kv, rec, state, boot } = await setup();
  await boot();
  const before = await kv.get(`pending:${USER}`);
  state.registerError = new ApiError('too many registrations; retry shortly', 429, 'rate_limited');
  await assert.rejects(dv.requestNewDeviceCode(), /too many registrations/);
  assert.deepEqual(await kv.get(`pending:${USER}`), before, 'old code kept');
  // And a successful new request replaces it.
  state.registerError = null;
  await dv.requestNewDeviceCode();
  const after = await kv.get(`pending:${USER}`) as any;
  assert.notEqual(after.code, (before as any).code);
  assert.equal(rec.last(STATUS).userCode, after.code);
  dv.stopDeviceVault();
});
