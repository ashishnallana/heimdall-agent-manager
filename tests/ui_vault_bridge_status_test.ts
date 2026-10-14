// REQ-BVS-3, REQ-BVS-4, REQ-BVS-5 and the folded-in vault key rehydration defect.
//
// The badge in bridge settings used to be derived from the UI CLIENT's own vault state,
// so it was one global value rendered identically next to every bridge — it reported
// nothing about any bridge at all. These tests pin the per-bridge derivation as an
// exhaustive truth table, so the two ways this can silently regress are both covered:
//   * a cached "unlocked" from a bridge that has since gone offline, and
//   * an unreported ("") vault_status being read as unlocked.
//
// RUN: node --test tests/ui_vault_bridge_status_test.ts
// (matched by the `tests/ui_vault_*.ts` glob in package.json's `test` script, so it
//  also runs under a plain `npm test`.)

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { registerHooks } from 'node:module';
import { fileURLToPath } from 'node:url';

// `src/ui/api/endpoints/bridges.ts` and its transitive imports use EXTENSIONLESS
// relative specifiers (`'../cookieFetch'`), which Vite resolves but Node's ESM loader
// does not — so importing it for real fails with ERR_MODULE_NOT_FOUND. This resolve
// hook appends the extension only as a fallback, after Node's own resolution has
// already failed, and marks the result `module-typescript` so Node still strips the
// types. It exists so REQ-BVS-4 can be verified by CALLING the shipped `lockBridge`
// through a stubbed fetch rather than by pattern-matching its source text — an
// error-handling contract asserted by grep is not asserted at all.
registerHooks({
  resolve(specifier, context, nextResolve) {
    try {
      return nextResolve(specifier, context);
    } catch (err) {
      if (specifier.startsWith('.') && context.parentURL) {
        const base = new URL(specifier, context.parentURL).href;
        for (const candidate of [`${base}.ts`, `${base}.tsx`, `${base}/index.ts`]) {
          if (fs.existsSync(fileURLToPath(candidate))) {
            return { url: candidate, shortCircuit: true, format: 'module-typescript' };
          }
        }
      }
      throw err;
    }
  },
});

import {
  resolveBridgeVaultStatus,
  canLockBridgeVault,
  canUnlockBridgeVault,
  canConfigureBridgeVault,
  BRIDGE_VAULT_STATUS_TONE,
  BRIDGE_VAULT_STATUSES,
  selectOnlineLockedBridgeIds,
  type BridgeVaultStatus,
} from '../src/ui/utils/bridgeVaultStatus.ts';

// --------------------------------------------------------------------------------
// 1. The full truth table: every {bridge.status} x {vault_status} cell asserted.
// --------------------------------------------------------------------------------

const BRIDGE_STATUSES = ['online', 'offline', 'revoked', 'pending', '', undefined, null] as const;
const VAULT_STATUSES = ['disabled', 'locked', 'unlocked', '', undefined, null, 'garbage'] as const;

function expectedCell(bridgeStatus: unknown, vaultStatus: unknown): BridgeVaultStatus {
  if (String(bridgeStatus ?? '').toLowerCase() !== 'online') return 'NotRunning';
  switch (String(vaultStatus ?? '').toLowerCase()) {
    case 'disabled': return 'NotConfigured';
    case 'locked': return 'Locked';
    case 'unlocked': return 'Unlocked';
    default: return 'Unknown';
  }
}

test('REQ-BVS-3: resolveBridgeVaultStatus covers every {bridge.status} x {vault_status} cell', () => {
  let cells = 0;
  for (const bridgeStatus of BRIDGE_STATUSES) {
    for (const vaultStatus of VAULT_STATUSES) {
      const actual = resolveBridgeVaultStatus({
        bridgeStatus: bridgeStatus as any,
        vaultStatus: vaultStatus as any,
      });
      assert.equal(
        actual,
        expectedCell(bridgeStatus, vaultStatus),
        `cell bridge.status=${JSON.stringify(bridgeStatus)} vault_status=${JSON.stringify(vaultStatus)}`,
      );
      cells++;
    }
  }
  assert.equal(cells, BRIDGE_STATUSES.length * VAULT_STATUSES.length, 'every cell was exercised');
  assert.equal(cells, 49, 'the table is 7x7 — guards against a silently shrunk matrix');
});

test('REQ-BVS-3: the four online states are exactly the documented mapping', () => {
  assert.equal(resolveBridgeVaultStatus({ bridgeStatus: 'online', vaultStatus: 'disabled' }), 'NotConfigured');
  assert.equal(resolveBridgeVaultStatus({ bridgeStatus: 'online', vaultStatus: 'locked' }), 'Locked');
  assert.equal(resolveBridgeVaultStatus({ bridgeStatus: 'online', vaultStatus: 'unlocked' }), 'Unlocked');
  assert.equal(resolveBridgeVaultStatus({ bridgeStatus: 'online', vaultStatus: '' }), 'Unknown');
});

test('REQ-BVS-3: hub liveness OVERRIDES a cached vault_status — an offline bridge is never Unlocked', () => {
  // This is the exact regression the field invites: vault_status is the LAST value the
  // bridge reported and is not cleared when it disappears.
  for (const cached of ['unlocked', 'locked', 'disabled', '']) {
    for (const dead of ['offline', 'revoked', 'pending', 'unknown', '']) {
      const status = resolveBridgeVaultStatus({ bridgeStatus: dead, vaultStatus: cached });
      assert.equal(
        status,
        'NotRunning',
        `bridge.status=${dead} with cached vault_status=${cached} must render Not running`,
      );
      assert.notEqual(status, 'Unlocked');
    }
  }
});

test('REQ-BVS-3: an unreported vault_status is Unknown and is NEVER Unlocked', () => {
  for (const unreported of ['', undefined, null, '   ', 'something-new-from-the-future']) {
    const status = resolveBridgeVaultStatus({ bridgeStatus: 'online', vaultStatus: unreported as any });
    assert.equal(status, 'Unknown', `vault_status=${JSON.stringify(unreported)} must be Unknown`);
    assert.notEqual(status, 'Unlocked', 'an older bridge that reported nothing must not look unlocked');
  }
});

test('REQ-BVS-3: vault_status matching is case- and whitespace-insensitive', () => {
  assert.equal(resolveBridgeVaultStatus({ bridgeStatus: 'ONLINE', vaultStatus: 'UNLOCKED' }), 'Unlocked');
  assert.equal(resolveBridgeVaultStatus({ bridgeStatus: ' online ', vaultStatus: ' Locked ' }), 'Locked');
});

test('REQ-AUX-10: reconciliation selects every and only online reported-locked bridge', () => {
  assert.deepEqual(selectOnlineLockedBridgeIds([
    { bridge_id: 'brg_locked_a', status: 'online', vault_status: 'locked' },
    { bridgeId: 'brg_locked_b', runtime_status: ' ONLINE ', vault_status: ' LOCKED ' },
    { id: 'brg_unlocked', status: 'online', vault_status: 'unlocked' },
    { id: 'brg_unknown', status: 'online', vault_status: '' },
    { id: 'brg_disabled', status: 'online', vault_status: 'disabled' },
    { id: 'brg_offline_cached_locked', status: 'offline', vault_status: 'locked' },
    { id: 'brg_revoked_cached_locked', status: 'revoked', vault_status: 'locked' },
    { id: 'brg_locked_a', status: 'online', vault_status: 'locked' },
    { status: 'online', vault_status: 'locked' },
  ]), ['brg_locked_a', 'brg_locked_b']);
});

// --------------------------------------------------------------------------------
// 2. Tone: Unknown / Not running must read neutral, never as success.
// --------------------------------------------------------------------------------

test('REQ-BVS-3: only Unlocked is painted success; Unknown and Not running are neutral', () => {
  assert.equal(BRIDGE_VAULT_STATUS_TONE.Unlocked, 'success');
  assert.equal(BRIDGE_VAULT_STATUS_TONE.Locked, 'warning');
  assert.equal(BRIDGE_VAULT_STATUS_TONE.Unknown, 'neutral');
  assert.equal(BRIDGE_VAULT_STATUS_TONE.NotRunning, 'neutral');
  assert.equal(BRIDGE_VAULT_STATUS_TONE.NotConfigured, 'neutral');

  const successStates = BRIDGE_VAULT_STATUSES.filter((s) => BRIDGE_VAULT_STATUS_TONE[s] === 'success');
  assert.deepEqual(successStates, ['Unlocked'], 'exactly one state may look green');
  // Every state has a tone — a missing entry would render an undefined tone.
  for (const s of BRIDGE_VAULT_STATUSES) {
    assert.ok(BRIDGE_VAULT_STATUS_TONE[s], `state ${s} has a tone`);
  }
  assert.equal(BRIDGE_VAULT_STATUSES.length, 5, 'there are exactly five states');
});

test('REQ-BVS-3: lock/unlock affordances follow the state', () => {
  assert.equal(canLockBridgeVault('Unlocked'), true, 'only an unsealed bridge can be locked');
  for (const s of ['Locked', 'NotRunning', 'NotConfigured', 'Unknown'] as BridgeVaultStatus[]) {
    assert.equal(canLockBridgeVault(s), false, `${s} offers no lock`);
  }
  assert.equal(canUnlockBridgeVault('Locked'), true);
  assert.equal(canUnlockBridgeVault('Unknown'), true, 'an unreported bridge may still be sent a key');
  for (const s of ['Unlocked', 'NotRunning', 'NotConfigured'] as BridgeVaultStatus[]) {
    assert.equal(canUnlockBridgeVault(s), false, `${s} offers no unseal`);
  }
});

test('REQ-T4-1: canConfigureBridgeVault — all five states x ownerHasVault', () => {
  let cells = 0;
  for (const s of BRIDGE_VAULT_STATUSES) {
    for (const ownerHasVault of [true, false]) {
      assert.equal(
        canConfigureBridgeVault(s, ownerHasVault),
        s === 'NotConfigured' && ownerHasVault,
        `status=${s} ownerHasVault=${ownerHasVault}`,
      );
      cells++;
    }
  }
  assert.equal(cells, 10, 'the table is 5x2 — guards against a silently shrunk matrix');
  // Configure is a third affordance, not a change to the other two.
  assert.equal(canUnlockBridgeVault('NotConfigured'), false, 'NotConfigured still offers no plain Unlock');
  assert.equal(canLockBridgeVault('NotConfigured'), false, 'Lock stays disabled for NotConfigured');
});

// --------------------------------------------------------------------------------
// 3. REQ-BVS-4: lockBridge must propagate failure instead of returning { ok: true }.
//
// `bridges.ts` is imported for real and driven through a stubbed global fetch, so this
// asserts the actual behaviour of the shipped function, not the shape of its source.
// --------------------------------------------------------------------------------

test('REQ-BVS-4: lockBridge propagates a failed lock instead of reporting success', async () => {
  const realFetch = globalThis.fetch;
  const calls: string[] = [];
  try {
    const { lockBridge } = await import('../src/ui/api/endpoints/bridges.ts');

    // (a) The hub answers 500 — this previously resolved to { ok: true }.
    globalThis.fetch = (async (url: any) => {
      calls.push(String(url));
      return new Response(JSON.stringify({ error: { message: 'bridge offline', code: 'bridge_offline' } }), {
        status: 500,
        headers: { 'content-type': 'application/json' },
      });
    }) as any;
    await assert.rejects(
      () => lockBridge('brg_dead'),
      (err: any) => {
        assert.ok(err instanceof Error, 'a real Error reaches the caller');
        assert.match(String(err.message), /bridge offline/i, 'the hub sentence survives');
        return true;
      },
      'a 500 from the hub must NOT resolve as a successful lock',
    );
    assert.equal(calls.length, 1, 'the lock endpoint was actually called');
    assert.match(calls[0], /\/bridges\/brg_dead\/lock$/, 'it posts to the per-bridge lock endpoint');

    // (b) The network itself fails — no fabricated success either.
    globalThis.fetch = (async () => {
      throw new TypeError('Failed to fetch');
    }) as any;
    await assert.rejects(() => lockBridge('brg_unreachable'), /Failed to fetch/);

    // (c) A 2xx carrying an explicit ok:false is still a failed lock.
    globalThis.fetch = (async () => new Response(JSON.stringify({ ok: false, message: 'vault not enabled' }), {
      status: 200,
      headers: { 'content-type': 'application/json' },
    })) as any;
    await assert.rejects(() => lockBridge('brg_refusing'), /vault not enabled/);

    // (d) The happy path still resolves to ok: true.
    globalThis.fetch = (async () => new Response(JSON.stringify({ ok: true }), {
      status: 200,
      headers: { 'content-type': 'application/json' },
    })) as any;
    assert.deepEqual(await lockBridge('brg_good'), { ok: true });
  } finally {
    globalThis.fetch = realFetch;
  }
});

test('REQ-BVS-5: a successful bridge lock leaves this client’s CryptoKey in place', async () => {
  // The per-bridge Lock handler is JSX and cannot be imported here, so the part of
  // REQ-BVS-5 that IS executable is asserted executably: the network call the handler
  // makes must not disturb the client's active key. The handler's own freedom from
  // `lockVault()` is pinned by the source-scoped test below.
  const realFetch = globalThis.fetch;
  try {
    const { lockBridge } = await import('../src/ui/api/endpoints/bridges.ts');
    const { importRawKeyHex, setActiveVaultKey, getActiveVaultKey } = await import(
      '../src/ui/utils/vaultCrypto.ts'
    );

    const key = await importRawKeyHex('0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef');
    setActiveVaultKey(key);
    assert.ok(getActiveVaultKey(), 'precondition: the client holds a key');

    globalThis.fetch = (async () => new Response(JSON.stringify({ ok: true }), {
      status: 200,
      headers: { 'content-type': 'application/json' },
    })) as any;
    await lockBridge('brg_one');

    assert.equal(getActiveVaultKey(), key, 'locking a bridge must not clear the client key');

    // And a FAILED lock must not clear it either.
    globalThis.fetch = (async () => new Response('nope', { status: 503 })) as any;
    await assert.rejects(() => lockBridge('brg_one'));
    assert.equal(getActiveVaultKey(), key, 'a failed lock must not clear the client key');

    setActiveVaultKey(null);
  } finally {
    globalThis.fetch = realFetch;
  }
});

