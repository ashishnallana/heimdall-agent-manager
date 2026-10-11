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

// --------------------------------------------------------------------------------
// 4. REQ-BVS-5 and the rehydration wiring, asserted against the source of the two
//    .tsx / bootstrap files the test runner cannot import (JSX is not type-stripped).
// --------------------------------------------------------------------------------

test('REQ-BVS-5: the per-bridge Lock handler does not touch this client’s vault', async () => {
  const fs = await import('node:fs');
  const path = await import('node:path');
  const src = fs.readFileSync(path.resolve('src/ui/components/settings/BridgeSettingsPanel.tsx'), 'utf8');

  const start = src.indexOf('const handleBridgeLock');
  assert.ok(start > 0, 'handleBridgeLock exists');
  const end = src.indexOf('const handleBridgeUnlock', start);
  assert.ok(end > start, 'handleBridgeUnlock follows it');
  const body = src.slice(start, end);

  assert.ok(body.includes('lockBridge(bridgeId)'), 'it locks the one bridge it was given');
  assert.ok(!body.includes('lockVault'), 'it must NEVER dispatch lockVault() — REQ-BVS-5');
  assert.ok(!body.includes('setActiveVaultKey'), 'it must not clear the active CryptoKey');
  assert.ok(!body.includes('lockAllConnectedBridges'), 'it must not fan out to other bridges');

  // The badge is per bridge and sourced from the bridge, not from the client.
  assert.ok(src.includes('resolveBridgeVaultStatus'), 'the badge uses the per-bridge derivation');
  assert.ok(src.includes('vaultStatus: bridge?.vault_status'), 'it reads the bridge-reported vault_status');
  const rowsStart = src.indexOf('bridgeRows.map');
  const rowsEnd = src.indexOf('{unsealSuccessMsg ?', rowsStart);
  assert.ok(rowsStart > 0 && rowsEnd > rowsStart, 'the per-bridge row list renders');
  const rows = src.slice(rowsStart, rowsEnd);
  assert.ok(!rows.includes('selectIsVaultUnlocked'), 'a row never derives its badge from the client vault');
  assert.ok(rows.includes('BRIDGE_VAULT_STATUS_TONE[status]'), 'the row tone comes from the per-bridge state');
});

test('the vault CryptoKey is rehydrated exactly once at startup from main.tsx', async () => {
  const fs = await import('node:fs');
  const path = await import('node:path');
  const src = fs.readFileSync(path.resolve('src/ui/main.tsx'), 'utf8');

  assert.ok(
    src.includes("import { initializeVaultPersistence } from './store/vaultSlice'"),
    'main.tsx imports the rehydration function',
  );
  const calls = src.match(/initializeVaultPersistence\(/g) || [];
  assert.equal(calls.length, 1, 'it is invoked exactly once');
  assert.ok(src.includes('initializeVaultPersistence(store.dispatch)'), 'it is given the store dispatch');
  assert.ok(
    src.includes('__heimdallVaultRehydrationStarted'),
    'the call is behind a guard so a re-evaluation cannot run it twice',
  );
  // It must sit at module scope, before the React tree is mounted — not inside a
  // component, where StrictMode would double-invoke it.
  assert.ok(
    src.indexOf('initializeVaultPersistence(store.dispatch)') < src.indexOf('ReactDOM.createRoot'),
    'rehydration starts before the app is mounted',
  );
});

// --------------------------------------------------------------------------------
// 5. REQ-T4-2/REQ-T4-3: the per-bridge "Configure encryption" button.
// --------------------------------------------------------------------------------

function readPanelSource(): string {
  return fs.readFileSync('src/ui/components/settings/BridgeSettingsPanel.tsx', 'utf8');
}

test('REQ-T4-1: ownerHasVault is the same expression that configures the client vault', () => {
  const src = readPanelSource();
  assert.ok(
    src.includes('const ownerHasVault = Boolean(isConfigured || vaultEnvelope?.encrypted_vault_key);'),
    'ownerHasVault mirrors the client-configured expression',
  );
  assert.ok(src.includes('isConfigured: ownerHasVault,'), 'clientVaultStatus is derived from the same value');
});

test('REQ-T4-2: a row renders "Configure encryption" exactly when canConfigureBridgeVault is true', () => {
  const src = readPanelSource();
  const rowsStart = src.indexOf('bridgeRows.map');
  const rowsEnd = src.indexOf('{unsealSuccessMsg ?', rowsStart);
  const rows = src.slice(rowsStart, rowsEnd);

  assert.ok(
    rows.includes('const configureAllowed = canConfigureBridgeVault(status, ownerHasVault);'),
    'the row gate is the pure helper with the owner-vault input',
  );
  // The button lives in the TRUE branch of `configureAllowed ? ... : ...`, and the
  // plain Unlock in the false branch — so it can appear for no other state.
  const branch = rows.indexOf('{configureAllowed ? (');
  const elseBranch = rows.indexOf(') : (', branch);
  assert.ok(branch > 0 && elseBranch > branch, 'Configure / Unlock are the two arms of one ternary');
  const configureArm = rows.slice(branch, elseBranch);
  const unlockArm = rows.slice(elseBranch, rows.indexOf('\n                  )}', elseBranch));
  assert.ok(configureArm.includes('Configure encryption'), 'the true arm is the Configure button');
  assert.ok(configureArm.includes('data-debug-id={`bridge-row-configure-btn-${id}`}'), 'it carries the per-bridge debug id');
  assert.ok(configureArm.includes('variant="primary"'), 'it is the primary action');
  assert.ok(configureArm.includes('handleBridgeConfigure(id)'), 'it runs the configure path');
  assert.ok(!unlockArm.includes('Configure encryption'), 'the Unlock arm never shows Configure');
  assert.ok(unlockArm.includes('handleBridgeUnlock(id)'), 'the false arm is the existing Unlock');
  assert.equal((src.match(/Configure encryption/g) || []).length, 2, 'one description sentence + one button label');

  // Row description for the configurable case.
  assert.ok(
    src.includes(
      'Encryption is enabled for your account but this bridge has no key yet. Configure it to encrypt files and terminal streams on this machine.',
    ),
  );
  assert.ok(rows.includes('BRIDGE_VAULT_CONFIGURABLE_DESCRIPTION'), 'the row uses it when configurable');

  // Lock is untouched: still gated purely by canLockBridgeVault (false for NotConfigured).
  assert.ok(rows.includes('disabled={Boolean(busy) || !canLockBridgeVault(status)}'));
  // "Enable Encryption" remains a client-Disabled-only control.
  const enable = src.indexOf('Enable Encryption');
  const enableGuard = src.lastIndexOf("{clientVaultStatus === 'Disabled' && (", enable);
  assert.ok(enableGuard > 0 && src.slice(enableGuard, enable).split('<Button').length === 2,
    'Enable Encryption is rendered only under clientVaultStatus === Disabled');
});

test('REQ-T4-2/REQ-T4-3: Configure reuses the Unlock path, or the ONE master-password prompt scoped to the bridge', () => {
  const src = readPanelSource();
  const start = src.indexOf('const handleBridgeConfigure');
  const end = src.indexOf('const handleUnlockClick', start);
  assert.ok(start > 0 && end > start, 'handleBridgeConfigure exists');
  const body = src.slice(start, end);
  assert.ok(body.includes('promptForUnsealKey(bridgeId)'), 'a locked client opens the prompt for THIS bridge');
  assert.ok(!body.includes('promptForUnsealKey(null)'), 'it never widens to every bridge');
  assert.ok(body.includes('handleBridgeUnlock(bridgeId)'), 'with a key in hand it is exactly the row Unlock');
  assert.ok(!body.includes('unsealBridgeE2EE'), 'no second unseal implementation');
  assert.ok(!body.includes('lockVault'), 'configuring a bridge never locks this client');
  // No second key-entry surface: the master-password modal is still the only one.
  assert.equal((src.match(/type="password"/g) || []).length, 1, 'exactly one password input');
});
