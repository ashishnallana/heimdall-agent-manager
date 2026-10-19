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

// ── L1: hint revocations are retried until the verified log shows them revoked ─

test('L1: an attempted hint is retried after backoff and dropped only once no longer trusted', () => {
  const T0 = 1_000_000_000;
  const trusted = new Set(['b1', 'b2']);
  // Never attempted: picked.
  assert.equal(dv.planHintRevocation(['b1'], trusted, {}, T0).target, 'b1');
  // Attempted just now (revoke may have failed): not retried before the backoff...
  const once = { b1: { attempts: 1, lastAt: T0 } };
  assert.equal(dv.planHintRevocation(['b1'], trusted, once, T0 + 1000).target, null);
  // ...but retried after it (the old code marked it handled forever).
  assert.equal(dv.planHintRevocation(['b1'], trusted, once, T0 + dv.hintBackoffMs(1)).target, 'b1');
  // Backoff grows and is capped.
  assert.ok(dv.hintBackoffMs(3) > dv.hintBackoffMs(1));
  assert.equal(dv.hintBackoffMs(50), dv.HINT_RETRY_MAX_MS);
  // Another hinted id is not blocked by one in backoff.
  assert.equal(dv.planHintRevocation(['b1', 'b2'], trusted, once, T0 + 1000).target, 'b2');
  // Handled = the verified log no longer trusts it: its record is dropped.
  const plan = dv.planHintRevocation([], new Set(['b2']), { ...once, b2: { attempts: 2, lastAt: T0 } }, T0);
  assert.deepEqual(Object.keys(plan.attempts), ['b2']);
});

// ── M1: stale-head freshness guard ──────────────────────────────────────────

test('M1: an old head seen after a long offline gap is stale until it advances', () => {
  const DAY = 86_400_000;
  const T0 = 1_700_000_000_000;
  const h = { seq: 5, hash: 'aa'.repeat(32) };
  const first = dv.evaluateHeadFreshness(null, h, T0);
  assert.equal(first.stale, false);
  // Online daily for 8 days, head unchanged: not stale (no offline gap).
  let rec = first;
  for (let i = 1; i <= 8; i++) rec = dv.evaluateHeadFreshness(rec, h, T0 + i * DAY - 1000);
  assert.equal(rec.stale, false);
  // Offline for 2 days, head 10 days old: stale...
  rec = dv.evaluateHeadFreshness(rec, h, T0 + 10 * DAY);
  assert.equal(rec.stale, true);
  // ...and it stays stale on later (frequent) fetches of the same head...
  rec = dv.evaluateHeadFreshness(rec, h, T0 + 10 * DAY + 1000);
  assert.equal(rec.stale, true);
  // ...until the head advances.
  rec = dv.evaluateHeadFreshness(rec, { seq: 6, hash: 'bb'.repeat(32) }, T0 + 10 * DAY + 2000);
  assert.equal(rec.stale, false);
  // A long offline gap with a RECENT head is not stale.
  const recent = dv.evaluateHeadFreshness(null, h, T0);
  assert.equal(dv.evaluateHeadFreshness(recent, h, T0 + 3 * DAY).stale, false);
  assert.ok(dv.STALE_HEAD_MS > dv.OFFLINE_GAP_MS);
});

// ── revoke confirmation lists the devices the target approved ───────────────

test('revoke confirm lists devices the target approved (revocations do not cascade)', async () => {
  const React = (await import('react')).default;
  const { renderToStaticMarkup } = await import('react-dom/server');
  const { DevicesList } = await import('../src/ui/components/settings/DevicesPanel.tsx');
  const row = {
    deviceId: 'dev_lap', kind: 'browser', label: 'Laptop', fingerprint: 'f00d', status: 'approved' as const,
    approvedByLabel: '(account root)', lastSeenAt: '', addedAt: '', approvedDeviceLabels: ['Phone', 'build-box'],
    leavesSingleApprover: false, retiredHint: false, bridgeId: '', isCurrent: false, canRevoke: true,
    revokeBlockedReason: '', canDeny: false, canSendKey: false,
  };
  const html = renderToStaticMarkup(React.createElement(DevicesList, { rows: [row], confirmRevokeId: 'dev_lap' }));
  assert.match(html, /settings-device-revoke-approved-dev_lap/);
  assert.match(html, /Phone, build-box/);
  assert.match(html, /does NOT revoke them/);
  const none = renderToStaticMarkup(React.createElement(DevicesList, { rows: [{ ...row, approvedDeviceLabels: [] }], confirmRevokeId: 'dev_lap' }));
  assert.doesNotMatch(none, /settings-device-revoke-approved-/);
});

// ── unreadable (malformed / older-format) local device data ────────────────

for (const which of ['pins', 'identity'] as const) {
  test(`malformed ${which}: fail closed with a typed-confirmation reset that archives and re-registers`, async () => {
    const kv = trackingStore();
    if (which === 'pins') {
      await kv.put(`identity:${USER}`, { v: 0, legacy: true });
      await kv.put(`pins:${USER}`, { version: 7, root: 'old-format' });
    } else {
      await kv.put(`identity:${USER}`, { v: 0, legacy: true });
    }
    let registered = 0;
    dv.configureDeviceVault({
      kv,
      hubOrigin: () => 'https://hub.example.test:443',
      api: fakeApi({
        fetchVaultDirectory: async () => ({ version: 4 }),
        fetchVaultSelf: async () => null,
        postVaultRegister: async () => {
          registered += 1;
          const id = await ident.loadDeviceIdentity(kv, USER);
          return { device_id: id!.deviceId, fingerprint: id!.fingerprint, user_code: 'ABCD-EFGH', code_expires_at: new Date(Date.now() + 600_000).toISOString() };
        },
      }),
    });
    const rec = recorder();
    dv.stopDeviceVault();
    await dv.bootDeviceVault(USER, rec.dispatch);
    const failed = rec.last('deviceVault/deviceVaultFailed');
    assert.equal(failed.code, 'device_state_malformed');
    assert.equal(failed.startOverPhrase, dv.RESET_DEVICE_DATA_PHRASE);
    assert.equal(registered, 0, 'nothing used while unreadable');

    await assert.rejects(dv.resetBrowserDeviceData('reset'), /exactly/);
    assert.ok(!kv.puts.some((k) => k.startsWith('archived:')));

    await dv.resetBrowserDeviceData(' reset  this browser ');
    const archiveKey = kv.puts.find((k) => k.startsWith(`archived:${USER}:`));
    const archived = await kv.get(archiveKey!) as any;
    assert.deepEqual(archived.identity, { v: 0, legacy: true });
    if (which === 'pins') assert.deepEqual(archived.pins, { version: 7, root: 'old-format' });
    assert.equal(registered, 1, 'registered as a fresh device');
    assert.equal(rec.last('deviceVault/deviceVaultStatusChanged').status, 'pending-approval');
    // Readable data is never reset through this path.
    await assert.rejects(dv.resetBrowserDeviceData(dv.RESET_DEVICE_DATA_PHRASE), /readable/);
    dv.stopDeviceVault();
  });
}
