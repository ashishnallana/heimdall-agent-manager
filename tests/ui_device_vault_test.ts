// Device vault orchestration safety (src/ui/services/deviceVault.ts): hermetic, with a
// memory device store and a fake vault API. No hub, no IndexedDB.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_device_vault_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

const dv = await import('../src/ui/services/deviceVault.ts');
const ident = await import('../src/ui/utils/deviceIdentity.ts');

const USER = 'alice';

type Fake = Record<string, (...args: any[]) => Promise<any>>;

function fakeApi(overrides: Fake): any {
  const refuse = async () => { throw new Error('unexpected API call in test'); };
  return new Proxy(overrides, { get: (t, k: string) => t[k] ?? refuse });
}

function recorder(opts: { throwOn?: string } = {}) {
  const actions: Array<{ type: string; payload?: any }> = [];
  const dispatch = (a: any) => {
    if (opts.throwOn && a?.type === opts.throwOn) throw new Error('dispatch failed');
    actions.push(a);
    return a;
  };
  const last = (type: string) => [...actions].reverse().find((a) => a.type === type)?.payload;
  return { actions, dispatch, last };
}

test('L2: a rejected refresh does not leave the coalesced follow-up stuck', async () => {
  let fetches = 0;
  const kv = ident.memoryDeviceStore();
  // A non-transport error makes runRefresh dispatch deviceVaultFailed; a dispatch that
  // throws there makes the refresh promise REJECT (the case the follow-up must survive).
  dv.configureDeviceVault({ kv, api: fakeApi({ fetchVaultDirectory: async () => { fetches += 1; throw new Error('boom'); } }) });
  const rec = recorder({ throwOn: 'deviceVault/deviceVaultFailed' });
  dv.stopDeviceVault();
  const boot = dv.bootDeviceVault(USER, rec.dispatch);
  const coalesced = dv.refreshDeviceVault('burst');
  await assert.rejects(boot);
  await assert.rejects(coalesced);
  const before = fetches;
  // A later burst must schedule a fresh follow-up again (old code returned the stale one).
  const a = dv.refreshDeviceVault('a');
  const b = dv.refreshDeviceVault('b');
  await Promise.allSettled([a, b]);
  assert.equal(fetches - before, 2, 'the run and its coalesced follow-up both fetched');
  dv.stopDeviceVault();
});
