// REQ-RAWKEY-A7 / REQ-RAWKEY-A7b -- behavioral regression guard for the vault unlock race
// and for the "no raw key material in Redux" invariant.
//
// WHY THIS FILE EXISTS. Both unlock reducers (`setVaultUnlocked` and `importLocalKey`) accept
// either a CryptoKey or a legacy hex string. A reducer is synchronous but
// `crypto.subtle.importKey` is not, so the hex branch can only install the key in a `.then()`
// -- one tick AFTER it has already flipped `isUnlocked` to true. Any effect gated on
// `isUnlocked` that reads the key inside itself can therefore run in that window, find no key,
// render nothing decrypted, and never re-fire, because `isUnlocked` does not change again.
// `selectActiveVaultKey` cannot rescue such a consumer: it ignores state and calls
// `getActiveVaultKey()` directly, so it is NOT a reactive selector and components cannot
// subscribe to key arrival through it. The fix therefore lives at the call sites, which now
// await `importRawKeyHex` and dispatch the resulting CryptoKey.
//
// Each "fixed path" test below is paired with a test proving the LEGACY hex branch still
// exhibits the race. Those pairs are deliberate: an assertion that passes after a fix proves
// nothing unless it would have failed before it, and the shared working tree forbids reverting
// production files to demonstrate that. The legacy branch is the pre-fix shape, still reachable
// by action creators, so it serves as the live counterfactual.
//
// RUN: node --test tests/ui_vault_unlock_race_test.ts

import test from 'node:test';
import assert from 'node:assert/strict';

import vaultReducer, {
  setVaultUnlocked,
  importLocalKey,
  lockVault,
  selectRawVaultKeyHex,
} from '../src/ui/store/vaultSlice.ts';
import {
  getActiveVaultKey,
  setActiveVaultKey,
  generateVaultKey,
  exportRawKeyHex,
  importRawKeyHex,
} from '../src/ui/utils/vaultCrypto.ts';

// -----------------------------------------------------------------------------
// 1. setVaultUnlocked -- the master-password / recovery / VaultPanel-hex path
// -----------------------------------------------------------------------------

test('A7b: setVaultUnlocked with a CryptoKey installs the key SYNCHRONOUSLY (no race window)', async () => {
  setActiveVaultKey(null);
  assert.equal(getActiveVaultKey(), null, 'precondition: no active key');

  const vaultKey = await generateVaultKey();
  let state = vaultReducer(undefined, { type: '@@INIT' });

  // The shape both direct-hex call sites now dispatch. No await, no tick: observe immediately.
  state = vaultReducer(state, setVaultUnlocked(vaultKey));

  assert.equal(state.isUnlocked, true, 'isUnlocked must be true');
  assert.notEqual(
    getActiveVaultKey(),
    null,
    'THE REGRESSION ASSERTION: the key must already be installed in the same tick',
  );
  assert.equal(state.isUnlocked && getActiveVaultKey() === null, false, 'no race window');
});

test('A7b: setVaultUnlocked legacy hex branch DOES still race -- proving the pair above is load-bearing', async () => {
  setActiveVaultKey(null);
  const vaultKey = await generateVaultKey();
  const rawHex = await exportRawKeyHex(vaultKey);

  let state = vaultReducer(undefined, { type: '@@INIT' });
  state = vaultReducer(state, setVaultUnlocked({ rawVaultKeyHex: rawHex }));

  // Exactly the defect A7b was filed for, on the branch production no longer dispatches.
  assert.equal(state.isUnlocked, true, 'isUnlocked flips synchronously...');
  assert.equal(getActiveVaultKey(), null, '...while the key is STILL NULL in this tick (the race)');

  await new Promise((r) => setTimeout(r, 0));
  assert.notEqual(getActiveVaultKey(), null, 'the key only lands a tick later');
});

// -----------------------------------------------------------------------------
// 2. importLocalKey -- the pasted-hex onboarding path (a genuine user path)
// -----------------------------------------------------------------------------

test('A7b: importLocalKey with a CryptoKey installs it SYNCHRONOUSLY', async () => {
  setActiveVaultKey(null);
  const vaultKey = await generateVaultKey();
  const key = await importRawKeyHex(await exportRawKeyHex(vaultKey));

  let state = vaultReducer(undefined, { type: '@@INIT' });
  state = vaultReducer(state, importLocalKey({ key, rememberSession: false }));

  assert.equal(state.isUnlocked, true, 'isUnlocked must be true');
  assert.notEqual(getActiveVaultKey(), null, 'REGRESSION ASSERTION: key installed in the same tick');
  assert.equal((state as any).rawVaultKeyHex, undefined, 'no raw key in state');
});

test('A7b: importLocalKey legacy hex branch still races -- retained for back-compat, no longer dispatched', async () => {
  setActiveVaultKey(null);
  const vaultKey = await generateVaultKey();
  const rawHex = await exportRawKeyHex(vaultKey);

  let state = vaultReducer(undefined, { type: '@@INIT' });
  state = vaultReducer(state, importLocalKey(rawHex, true));

  assert.equal(state.isUnlocked, true, 'isUnlocked flips synchronously...');
  assert.equal(getActiveVaultKey(), null, '...key still null this tick (why the call site now awaits)');
  await new Promise((r) => setTimeout(r, 0));
  assert.notEqual(getActiveVaultKey(), null, 'key lands a tick later');
});

// -----------------------------------------------------------------------------
// 3. REQ-RAWKEY-A7 -- no raw key material reaches Redux on ANY unlock path
// -----------------------------------------------------------------------------

test('A7: no raw key material reaches Redux state on ANY unlock path', async () => {
  const vaultKey = await generateVaultKey();
  const rawHex = await exportRawKeyHex(vaultKey);

  const paths: Array<[string, any]> = [
    ['CryptoKey (master password / recovery / hex import)', setVaultUnlocked(vaultKey)],
    ['keyed payload', setVaultUnlocked({ key: vaultKey, rememberSession: true })],
    ['legacy hex payload', setVaultUnlocked({ rawVaultKeyHex: rawHex })],
    ['importLocalKey hex', importLocalKey(rawHex, false)],
  ];

  for (const [label, action] of paths) {
    let state = vaultReducer(undefined, { type: '@@INIT' });
    state = vaultReducer(state, action);

    assert.equal(state.isUnlocked, true, `${label}: unlocks`);
    assert.equal((state as any).rawVaultKeyHex, undefined, `${label}: no rawVaultKeyHex field in state`);
    assert.equal(selectRawVaultKeyHex({ vault: state }), null, `${label}: deprecated shim selector returns null`);

    // Nothing in a devtools snapshot of the slice may carry the key material.
    assert.equal(JSON.stringify(state).includes(rawHex), false, `${label}: hex absent from serialized state`);
    assert.deepEqual(
      Object.keys(state).sort(),
      ['isConfigured', 'isUnlockModalOpen', 'isUnlocked'],
      `${label}: exact state shape -- a new key here would be a leak regression`,
    );

    state = vaultReducer(state, lockVault());
    assert.equal(state.isUnlocked, false, `${label}: locks`);
  }
});

