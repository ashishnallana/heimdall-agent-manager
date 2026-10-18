// WHY THIS FILE EXISTS (A10 / REQ-CACHE-1)
//
// Two defects, both about the lock/unlock STATE TRANSITION rather than about any
// single unlock call site.
//
// 1. Every vault-bearing endpoint decrypts inside its `queryFn`, gated on
//    `state.vault.isUnlocked && getActiveVaultKey()`. That gate is evaluated once,
//    at FETCH time, so a list fetched while locked is cached ARMORED and nothing
//    revisits it. `vaultCacheInvalidationMiddleware` is the single choke point that
//    drops the cache when the flag crosses the boundary -- in BOTH directions, so
//    decrypted plaintext does not outlive the key either.
//
// 2. `importLocalKey.prepare` lacked the bare-CryptoKey branch that
//    `setVaultUnlocked.prepare` has, so a bare key was destroyed by `prepare`
//    before the reducer could install it, while `isUnlocked` still flipped true.
//
// Assertions are BEHAVIORAL: the middleware is driven with real actions and its
// dispatches observed, and the installed key is proved by a real WebCrypto
// round-trip. No source-text matching (that is what A8 removed).
//
// NOTE the distinction from `ui_vault_unlock_race_test.ts`: that file dispatches
// `importLocalKey({ key, rememberSession })` -- the OBJECT form, which hit the
// working object branch. The defect below is the BARE `importLocalKey(key)` form.

import { keyringFromHex, asKeyring } from './helpers/vaultTestKeyring.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  vaultSlice,
  importLocalKey,
  setVaultUnlocked,
  lockVault,
  getActiveVaultKey,
  setActiveVaultKey,
} from '../src/ui/store/vaultSlice.ts';
import { vaultCacheInvalidationMiddleware } from '../src/ui/api/vaultCacheInvalidation.ts';
import { heimdallApi } from '../src/ui/api/heimdallApi.ts';
import { encryptVaultText, VAULT_MASK_PLACEHOLDER, containsVaultArmored, maskVaultArmored } from '../src/ui/utils/vaultContent.ts';

const TEST_KEY_HEX_RAW = '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';
const TEST_KEY_HEX = await keyringFromHex(TEST_KEY_HEX_RAW);
const RESET_TYPE = heimdallApi.util.resetApiState().type;

function hexToBytes(hex: string): Uint8Array {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  return out;
}

function importTestKey(): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    'raw', hexToBytes(TEST_KEY_HEX_RAW), { name: 'AES-GCM' }, false, ['encrypt', 'decrypt'],
  );
}

/** Drives the middleware over a scripted `isUnlocked` sequence and records what it
 *  dispatched. `states` supplies the value `getState()` returns on each successive
 *  call, which is how a before/after transition is simulated without a real store. */
function runMiddleware(states: boolean[]) {
  const dispatched: any[] = [];
  let i = 0;
  const store = {
    getState: () => ({ vault: { isUnlocked: states[Math.min(i++, states.length - 1)] } }),
    dispatch: (a: any) => { dispatched.push(a); return a; },
  };
  const invoke = vaultCacheInvalidationMiddleware(store as any)((a: any) => a);
  return { invoke, dispatched };
}

test('REQ-CACHE-1: the locked->unlocked transition resets the API cache', () => {
  const { invoke, dispatched } = runMiddleware([false, true]);
  invoke({ type: 'vault/setVaultUnlocked' });
  assert.equal(dispatched.length, 1, 'exactly one reset should be dispatched');
  assert.equal(dispatched[0].type, RESET_TYPE, 'must be resetApiState, so armored cache entries are refetched');
});

test('REQ-CACHE-1 criterion 3: the unlocked->locked transition ALSO resets, so plaintext does not outlive the key', () => {
  const { invoke, dispatched } = runMiddleware([true, false]);
  invoke(lockVault());
  assert.equal(dispatched.length, 1, 'lock must purge too, not merely invalidate');
  assert.equal(dispatched[0].type, RESET_TYPE);
});

test('REQ-CACHE-1: a NON-transition dispatches nothing -- no refetch storm', () => {
  for (const [label, states] of [
    ['already unlocked', [true, true]],
    ['already locked', [false, false]],
  ] as [string, boolean[]][]) {
    const { invoke, dispatched } = runMiddleware(states);
    invoke({ type: 'some/unrelatedAction' });
    assert.equal(dispatched.length, 0, `${label}: must not reset when the flag did not move`);
  }
});

test('REQ-CACHE-1: the choke point is keyed on STATE, so an unknown future unlock site is covered too', () => {
  // The point of the middleware: it never names an action type, so a dispatch site
  // that does not exist yet is covered the moment it moves the flag.
  const { invoke, dispatched } = runMiddleware([false, true]);
  invoke({ type: 'some/futureFeatureNobodyHasWrittenYet' });
  assert.equal(dispatched.length, 1, 'an unrecognised action that moves the flag must still reset');
  assert.equal(dispatched[0].type, RESET_TYPE);
});

test('A10: importLocalKey(bare CryptoKey) installs the key, not just the isUnlocked flag', async () => {
  setActiveVaultKey(null);
  const key = await importTestKey();

  const action = importLocalKey(key);

  // REGRESSION ASSERTION: pre-fix, `prepare` read `.key` off the CryptoKey and
  // returned undefined, destroying the key before the reducer ran.
  assert.ok(action.payload, 'prepare must not return an empty payload for a bare key');
  assert.ok((action.payload as any).key, 'prepare must not DROP the CryptoKey');

  const state = vaultSlice.reducer(undefined as any, action);
  assert.equal(state.isUnlocked, true, 'isUnlocked flips');
  const installed = getActiveVaultKey()?.keys.get(1) ?? null;
  assert.notEqual(installed, null, 'a store that claims unlocked must hold a usable key');

  // Behavioral proof over real WebCrypto: the installed handle actually decrypts.
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, installed as CryptoKey, new TextEncoder().encode('ping'));
  const pt = await crypto.subtle.decrypt({ name: 'AES-GCM', iv }, installed as CryptoKey, ct);
  assert.equal(new TextDecoder().decode(pt), 'ping', 'the installed key must really decrypt');
});

test('A10: isUnlocked is never true with no key installed, on EITHER bare-key unlock path', async () => {
  for (const [label, make] of [
    ['importLocalKey', (k: CryptoKey) => importLocalKey(k)],
    ['setVaultUnlocked', (k: CryptoKey) => setVaultUnlocked(k)],
  ] as [string, (k: CryptoKey) => any][]) {
    setActiveVaultKey(null);
    const key = await importTestKey();
    const state = vaultSlice.reducer(undefined as any, make(key));
    assert.equal(state.isUnlocked, true, `${label}: unlocks`);
    assert.notEqual(getActiveVaultKey(), null, `${label}: and a key is actually installed in the same tick`);
  }
});

test('A10: no raw key material is left in vault state by the bare-key path', async () => {
  setActiveVaultKey(null);
  const key = await importTestKey();
  const state = vaultSlice.reducer(undefined as any, importLocalKey(key));
  assert.equal(JSON.stringify(state).includes(TEST_KEY_HEX), false, 'hex must not appear in serialized state');
  assert.equal((state as any).rawVaultKeyHex, undefined, 'no rawVaultKeyHex field');
});

// ---------------------------------------------------------------------------
// The catalog bypass (iss_18db4fc560653555). Two independent scope catalogs map
// armored project names into plain strings -- option lists, aria-labels and a
// search haystack -- where a React decrypt hook cannot reach. Both mask at the
// catalog, so every consumer is covered by one line each:
//   useMemoryScopeCatalog  (ScopeField.tsx)      -> 5 consumers
//   useActionCatalog       (actionCatalog.ts)    -> 5 consumers
// These tests pin the MASKING RULE the two catalogs share. The hooks themselves
// are React and cannot be rendered here (see the file header on .tsx loading).

test('REQ-CACHE-1: a real armored project name masks rather than reaching a plain string', async () => {
  const key = await importTestKey();
  const armored = await encryptVaultText('Classified Project', asKeyring(key));

  // Precondition: a genuinely armored value, not a hand-written lookalike.
  assert.ok(containsVaultArmored(armored), 'fixture must really be armored');
  assert.ok(armored.startsWith('vault:v2:e1:'));

  const masked = containsVaultArmored(armored) ? maskVaultArmored(armored) : armored;

  assert.equal(masked, VAULT_MASK_PLACEHOLDER, 'armored name must degrade to the placeholder');
  assert.equal(masked.includes('vault:v2:e1:'), false, 'no ciphertext may survive into the label');
  assert.equal(masked.includes('Classified Project'), false, 'and no plaintext either, while locked');
});

test('REQ-CACHE-1: masking is a no-op on an unarmored name, so unlocked labels are untouched', () => {
  for (const plain of ['heimdall-hub', 'Unnamed project', 'proj_18c6879e443756f1', '']) {
    const masked = containsVaultArmored(plain) ? maskVaultArmored(plain) : plain;
    assert.equal(masked, plain, `"${plain}" must pass through unchanged`);
  }
});

test('REQ-CACHE-1: the masked label is what feeds the search haystack, so armored text is not searchable', async () => {
  const key = await importTestKey();
  const armored = await encryptVaultText('Classified Project', asKeyring(key));
  const id = 'proj_18c6879e443756f1';

  // Mirrors actionCatalog.ts:151 -- `keywords` derives from the SAME masked label,
  // which is why fixing the label closes the ActionListPage searchableText leak.
  const label = containsVaultArmored(armored) ? maskVaultArmored(armored) : armored;
  const keywords = [id, label].filter(Boolean).join(' ');

  assert.equal(keywords.includes('vault:v2:e1:'), false, 'armored text must not enter the keyword index');
  assert.ok(keywords.includes(id), 'the id stays searchable, so a row is still findable while locked');
});
