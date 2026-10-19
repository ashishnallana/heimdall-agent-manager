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

// ── M2: "no directory" never silently re-roots ──────────────────────────────

const PINS = { root_device_id: 'dev_root', root_sign_pub: '04' + 'a1'.repeat(64), head_seq: 3, head_hash: 'ab'.repeat(32), max_epoch: 1 };

function trackingStore() {
  const inner = ident.memoryDeviceStore();
  const puts: string[] = [];
  return {
    puts,
    get: (k: string) => inner.get(k),
    put: async (k: string, v: unknown) => { puts.push(k); await inner.put(k, v); },
    delete: (k: string) => inner.delete(k),
  };
}

async function missingVaultSetup(observed: { requested_at: string; due_at: string; head_seq: number } | null) {
  const kv = trackingStore();
  await ident.advancePins(kv, USER, PINS);
  const identity = await ident.createDeviceIdentity(kv, USER);
  if (observed) await ident.recordObservedReset(kv, USER, observed);
  const state = { dir: null as unknown, genesisPosted: 0 };
  dv.configureDeviceVault({
    kv,
    api: fakeApi({
      fetchVaultDirectory: async () => {
        if (state.genesisPosted) throw new TypeError('offline after genesis (test)');
        return state.dir;
      },
      postVaultGenesis: async () => { state.genesisPosted += 1; return { directory_version: 1, current_epoch: 1 }; },
    }),
  });
  const rec = recorder();
  dv.stopDeviceVault();
  await dv.bootDeviceVault(USER, rec.dispatch);
  return { kv, identity, state, rec };
}

test('M2: a vanished vault without a recorded due reset needs the typed phrase and archives', async () => {
  const { kv, identity, state, rec } = await missingVaultSetup(null);
  const failed = rec.last('deviceVault/deviceVaultFailed');
  const phrase = await dv.startOverPhraseFor(PINS);
  assert.equal(failed.code, 'vault_missing');
  assert.match(failed.message, /server may be misbehaving/);
  assert.equal(failed.startOverPhrase, phrase);
  assert.match(phrase, /^[0-9a-f]{4} RESET$/);

  await assert.rejects(dv.startOverAfterReset(''), /exactly/);
  await assert.rejects(dv.startOverAfterReset('0000 RESET'), /exactly/);
  assert.deepEqual(await ident.loadPins(kv, USER), PINS, 'pins untouched after a wrong phrase');
  assert.equal(state.genesisPosted, 0);

  await dv.startOverAfterReset(phrase.toLowerCase());
  const archiveKey = kv.puts.find((k) => k.startsWith(`archived:${USER}:`));
  assert.ok(archiveKey, 'old state archived');
  const archived = await kv.get(archiveKey!) as any;
  assert.deepEqual(archived.pins, PINS);
  assert.equal(archived.identity.signPub, identity.signPub);
  assert.equal(state.genesisPosted, 1, 'a new vault was started');
  dv.stopDeviceVault();
});

test('M2: a recorded verified reset whose due time passed offers start-over without a phrase', async () => {
  const { kv, state, rec } = await missingVaultSetup({ requested_at: '2026-01-01T00:00:00Z', due_at: '2026-01-04T00:00:00Z', head_seq: 3 });
  assert.equal(rec.last('deviceVault/deviceVaultFailed').code, 'vault_reset');
  await dv.startOverAfterReset();
  assert.ok(kv.puts.some((k) => k.startsWith(`archived:${USER}:`)));
  assert.equal(state.genesisPosted, 1);
  dv.stopDeviceVault();
});

test('M2: a recorded reset not yet due is still "vault missing"; a returning directory blocks start-over', async () => {
  const future = new Date(Date.now() + 86_400_000).toISOString();
  const { kv, state, rec } = await missingVaultSetup({ requested_at: new Date().toISOString(), due_at: future, head_seq: 3 });
  assert.equal(rec.last('deviceVault/deviceVaultFailed').code, 'vault_missing');
  state.dir = { version: 3 };
  await assert.rejects(dv.startOverAfterReset(await dv.startOverPhraseFor(PINS)), /back/);
  assert.ok(!kv.puts.some((k) => k.startsWith('archived:')), 'nothing archived');
  assert.deepEqual(await ident.loadPins(kv, USER), PINS);
  dv.stopDeviceVault();
});
