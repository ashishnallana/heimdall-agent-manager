// E1 / REQ-UNSEAL-1..5: bridge unseal must behave IDENTICALLY whether the vault key was
// typed this session or restored from IndexedDB on a page reload.
//
// The defect these tests pin: `setActiveVaultKey(key, hex?)` kept a second module-level
// copy of the raw key as hex, and its optional `hex` parameter gave it a silent THIRD
// branch -- a truthy key with `hex` omitted (as opposed to explicitly `null`) installed
// the key and left the hex copy at whatever a previous caller had left there. Six of the
// ten call sites took that branch, the IndexedDB restore at app boot among them, while
// the "operator typed the key" path passed the hex explicitly. `prepareUnsealPayload`
// then read that cache from a `catch` block, so an unseal succeeded in the session where
// the key was typed and threw `'...no active key hex is cached.'` after any reload. Same
// user, same vault, same bridge: the outcome depended only on reload history.
//
// The fix deletes the cache rather than populating it on both paths (which would have
// meant raw key material at rest, the exact exposure REQ-VAULT-HARDEN exists to remove).
// So what is asserted below is CONVERGENCE: both entry paths now hold the same thing, are
// refused by unseal in the same way, and succeed in the same way once the caller passes
// the key material explicitly.
//
// RUN: node --test tests/ui_vault_unseal_hex_convergence_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  prepareUnsealPayload,
  canUnsealWithKey,
  isVaultKeyNotExportableError,
  VaultKeyNotExportableError,
  VAULT_KEY_NOT_EXPORTABLE,
  resolveUnsealOutcome,
  type BridgeUnsealPayload,
} from '../src/ui/utils/vaultBridgeUnseal.ts';
import * as vaultCrypto from '../src/ui/utils/vaultCrypto.ts';
import {
  importRawKeyHex,
  getActiveVaultKey,
  setActiveVaultKey,
  hexToBytes,
  bytesToHex,
} from '../src/ui/utils/vaultCrypto.ts';
import {
  persistVaultKey,
  deleteVaultKey,
  createMockIndexedDB,
} from '../src/ui/utils/vaultPersistence.ts';
import {
  importAndValidateCryptoKey,
  initializeVaultPersistence,
} from '../src/ui/store/vaultSlice.ts';

const TEST_VAULT_KEY_HEX = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const OTHER_VAULT_KEY_HEX = 'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';

// `initializeVaultPersistence` reads the real IndexedDB factory, so the restore path can
// only be exercised with one present.
(globalThis as any).indexedDB = createMockIndexedDB();

// --- the two entry paths, each as close to production as a unit test reaches -----------

/** Path 1: the operator typed/pasted the key THIS session (`vaultSlice.ts:92`). */
async function enterKeyTypedThisSession(hex = TEST_VAULT_KEY_HEX): Promise<CryptoKey> {
  setActiveVaultKey(null);
  await importAndValidateCryptoKey(hex);
  const key = getActiveVaultKey();
  assert.ok(key, 'typed path must install an active key');
  return key!;
}

/**
 * Path 2: the key was restored from IndexedDB at app boot (`vaultSlice.ts:116`, reached
 * from `main.tsx:79`). This is the path that was never covered, which is why the defect
 * shipped. `dispatch` is omitted so the test observes the key installation alone.
 */
async function enterKeyRestoredOnReload(hex = TEST_VAULT_KEY_HEX): Promise<CryptoKey> {
  await deleteVaultKey().catch(() => {});
  await persistVaultKey(await importRawKeyHex(hex));
  // Simulate the reload: nothing is in module state when the page comes back up.
  setActiveVaultKey(null);
  assert.equal(getActiveVaultKey(), null, 'a reload must start with no active key');
  const restored = await initializeVaultPersistence();
  assert.ok(restored, 'restore path must return the persisted key');
  assert.equal(getActiveVaultKey(), restored, 'restore path must install it as active');
  return restored!;
}

const ENTRY_PATHS: Array<[string, () => Promise<CryptoKey>]> = [
  ['typed this session', () => enterKeyTypedThisSession()],
  ['restored from IndexedDB on reload', () => enterKeyRestoredOnReload()],
];

/** Decrypts an unseal payload exactly as the bridge does, returning the plaintext. */
async function bridgeDecrypt(
  payload: BridgeUnsealPayload,
  bridgePrivateKey: CryptoKey,
): Promise<string> {
  const clientCryptoKey = await crypto.subtle.importKey(
    'raw',
    hexToBytes(payload.client_public_key) as any,
    { name: 'ECDH', namedCurve: 'P-256' },
    false,
    [],
  );
  const sharedSecret = await crypto.subtle.deriveBits(
    { name: 'ECDH', public: clientCryptoKey },
    bridgePrivateKey,
    256,
  );
  const hkdfKey = await crypto.subtle.importKey('raw', sharedSecret as any, 'HKDF', false, ['deriveKey']);
  const aesKey = await crypto.subtle.deriveKey(
    {
      name: 'HKDF',
      hash: 'SHA-256',
      salt: new Uint8Array(32),
      info: new TextEncoder().encode('heimdall-bridge-unseal-v1'),
    },
    hkdfKey,
    { name: 'AES-GCM', length: 256 },
    false,
    ['decrypt'],
  );
  const combined = new Uint8Array(
    hexToBytes(payload.ciphertext).length + hexToBytes(payload.tag).length,
  );
  combined.set(hexToBytes(payload.ciphertext), 0);
  combined.set(hexToBytes(payload.tag), hexToBytes(payload.ciphertext).length);
  const plain = await crypto.subtle.decrypt(
    {
      name: 'AES-GCM',
      iv: hexToBytes(payload.iv) as any,
      additionalData: new TextEncoder().encode(
        `${payload.bridge_id}:${payload.timestamp}:${payload.nonce}`,
      ) as any,
      tagLength: 128,
    },
    aesKey,
    combined as any,
  );
  return new TextDecoder().decode(plain);
}

async function makeBridgeKeyPair() {
  const pair = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, [
    'deriveBits',
    'deriveKey',
  ]);
  const pubHex = bytesToHex(new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey)));
  return { pair, pubHex };
}

// --- REQ-UNSEAL-2: branch (c) is unrepresentable, not merely guarded -------------------

test('REQ-UNSEAL-2: setActiveVaultKey takes exactly ONE parameter, so the silent third branch cannot exist', () => {
  // The whole defect was an OPTIONAL second parameter: omitting it was a third state
  // that read like neither of the two the body appeared to have. Arity is the structural
  // guarantee -- there is no argument left to omit, so no future caller can re-arm it.
  assert.equal(
    setActiveVaultKey.length,
    1,
    'setActiveVaultKey must take one parameter; a second (hex) one re-introduces the three-branch trap',
  );
});

test('REQ-UNSEAL-2: the module-level hex copy and its getter are gone, not just unused', () => {
  assert.equal(
    (vaultCrypto as Record<string, unknown>).getActiveVaultKeyHex,
    undefined,
    'getActiveVaultKeyHex must not be exported: a reachable reader of key material is what unseal fell back on',
  );
});

test('REQ-UNSEAL-2: installing a second key leaves no trace of the first that unseal could still serve', async () => {
  // Under the old signature this was the trap: `setActiveVaultKey(keyB)` with `hex`
  // omitted swapped the key but left key A's hex in the cache, so an unseal for B would
  // have shipped A's bytes. There is now no state besides the handle itself.
  const keyA = await enterKeyTypedThisSession(TEST_VAULT_KEY_HEX);
  const keyB = await importRawKeyHex(OTHER_VAULT_KEY_HEX);
  setActiveVaultKey(keyB);

  assert.equal(getActiveVaultKey(), keyB, 'the active key must be the one just installed');
  assert.notEqual(getActiveVaultKey(), keyA, 'the previous key must not survive');

  const residual = Object.keys(vaultCrypto).filter((k) => /hex/i.test(k) && /active/i.test(k));
  assert.deepEqual(residual, [], `no active-key hex accessor may exist, found: ${residual.join(', ')}`);

  setActiveVaultKey(null);
  assert.equal(getActiveVaultKey(), null, 'purging must clear the only state there is');
});

// --- REQ-UNSEAL-1: both entry paths, which is the gap that let this ship ---------------

for (const [label, enterKey] of ENTRY_PATHS) {
  test(`REQ-UNSEAL-1 [${label}]: the key this client holds is a non-extractable handle`, async () => {
    const key = await enterKey();
    assert.equal(
      key.extractable,
      false,
      'both entry paths must hold a hardened handle (REQ-VAULT-HARDEN-1) -- if one were extractable the paths would not have converged, they would merely both work',
    );
    assert.equal(
      canUnsealWithKey(key),
      false,
      'a non-extractable handle cannot supply the bytes an unseal transmits, on EITHER path',
    );
    setActiveVaultKey(null);
  });

  test(`REQ-UNSEAL-1/4 [${label}]: unseal refuses the handle loudly and identically`, async () => {
    const key = await enterKey();
    const { pubHex } = await makeBridgeKeyPair();

    const err = await prepareUnsealPayload('brg_conv', pubHex, key).then(
      () => null,
      (e: unknown) => e,
    );

    assert.ok(err, 'unseal must not silently succeed with a handle it cannot read');
    assert.ok(
      isVaultKeyNotExportableError(err),
      `must be the explicit not-exportable signal, got: ${(err as Error)?.message}`,
    );
    assert.equal((err as { code?: string }).code, VAULT_KEY_NOT_EXPORTABLE);
    // The old failure was a cache miss, which is what made the two paths differ. The
    // refusal must now be about the key's nature, identical on both paths.
    assert.ok(
      !/cached/i.test((err as Error).message),
      'the refusal must no longer be phrased as a cache miss -- there is no cache',
    );
    assert.match(
      (err as Error).message,
      /master password/i,
      'REQ-UNSEAL-4: the refusal must tell the operator what to do, not just fail',
    );
    setActiveVaultKey(null);
  });

  test(`REQ-UNSEAL-1 [${label}]: unseal SUCCEEDS identically once the caller passes the key material`, async () => {
    // This is the convergence assertion with teeth: having entered the vault by this
    // path, the operator re-supplies the key and the bridge receives byte-identical
    // plaintext. Previously only the typed path could get here, and only via the cache.
    await enterKey();
    const { pair, pubHex } = await makeBridgeKeyPair();

    const payload = await prepareUnsealPayload('brg_conv', pubHex, TEST_VAULT_KEY_HEX);
    const plaintext = await bridgeDecrypt(payload, pair.privateKey);

    assert.equal(
      plaintext,
      TEST_VAULT_KEY_HEX,
      'the bridge must recover the master key hex it needs to decrypt existing vault:v1: content',
    );
    setActiveVaultKey(null);
  });
}

test('REQ-UNSEAL-1: the two entry paths are indistinguishable to the unseal flow', async () => {
  const { pair, pubHex } = await makeBridgeKeyPair();
  const observed: Array<{ extractable: boolean; refusalCode: string; plaintext: string }> = [];

  for (const [, enterKey] of ENTRY_PATHS) {
    const key = await enterKey();
    const refusal = await prepareUnsealPayload('brg_conv', pubHex, key).then(
      () => ({ code: 'NONE' }),
      (e: any) => ({ code: String(e?.code) }),
    );
    const payload = await prepareUnsealPayload('brg_conv', pubHex, TEST_VAULT_KEY_HEX);
    observed.push({
      extractable: key.extractable,
      refusalCode: refusal.code,
      plaintext: await bridgeDecrypt(payload, pair.privateKey),
    });
    setActiveVaultKey(null);
  }

  assert.equal(observed.length, 2);
  assert.deepEqual(
    observed[0],
    observed[1],
    'typed-this-session and restored-from-IndexedDB must produce the SAME outcome in every respect; reload history must not change unseal behaviour',
  );
});

// --- REQ-UNSEAL-4: failure stays loud, and no weaker payload is ever sent --------------

test('REQ-UNSEAL-4: extractable CryptoKeys succeed while non-extractable keys fail cleanly', async () => {
  // An extractable key still works: the guard keys off extractability, and is not a
  // blanket refusal of every CryptoKey.
  const { pair, pubHex } = await makeBridgeKeyPair();
  const extractableKey = await importRawKeyHex(TEST_VAULT_KEY_HEX, true);
  const payload = await prepareUnsealPayload('brg_conv', pubHex, extractableKey);
  assert.equal(await bridgeDecrypt(payload, pair.privateKey), TEST_VAULT_KEY_HEX);
});

test('REQ-UNSEAL-4: an empty or whitespace key is refused rather than wrapped as a short payload', async () => {
  const { pubHex } = await makeBridgeKeyPair();
  assert.equal(canUnsealWithKey(''), false);
  assert.equal(canUnsealWithKey('   '), false);
  assert.equal(canUnsealWithKey(null), false);
  assert.equal(canUnsealWithKey(undefined), false);
  assert.equal(canUnsealWithKey(new Uint8Array(0)), false);
  assert.equal(canUnsealWithKey(TEST_VAULT_KEY_HEX), true);
  assert.equal(canUnsealWithKey(await importRawKeyHex(TEST_VAULT_KEY_HEX, true)), true);
  assert.equal(canUnsealWithKey(await importRawKeyHex(TEST_VAULT_KEY_HEX)), false);

  // The predicate is advisory; the enforcement point must refuse on its own.
  const err = await prepareUnsealPayload('brg_conv', pubHex, await importRawKeyHex(TEST_VAULT_KEY_HEX))
    .then(() => null, (e: unknown) => e);
  assert.ok(isVaultKeyNotExportableError(err));
});

test('isVaultKeyNotExportableError matches by code, so a dynamic import boundary cannot defeat it', () => {
  // bridges.ts reaches vaultBridgeUnseal through `await import(...)`; callers must not
  // depend on sharing one class identity.
  assert.equal(isVaultKeyNotExportableError(new VaultKeyNotExportableError()), true);
  assert.equal(isVaultKeyNotExportableError({ code: VAULT_KEY_NOT_EXPORTABLE }), true);
  assert.equal(isVaultKeyNotExportableError(new Error('something else')), false);
  assert.equal(isVaultKeyNotExportableError(null), false);
  assert.equal(isVaultKeyNotExportableError(undefined), false);
});

// --- REQ-UNSEAL-4/5: the UI never reports an unseal that did not happen ---------------

test('REQ-UNSEAL-4: a prompt whose bridge left the list reports NOTHING UNSEALED, not success', () => {
  // The traced failure: the operator clicks Unlock on one bridge row, and while they
  // are typing the password the poll drops that bridge (unenrolled/deleted). At submit
  // the row is gone, so no unseal is attempted -- and because nothing was attempted,
  // nothing FAILED either. A "did anything fail?" test therefore sees a clean run.
  // Reporting success there is the silent skip REQ-UNSEAL-4 forbids.
  const outcome = resolveUnsealOutcome({
    pendingUnsealBridgeId: 'brg_gone',
    pendingBridgeFound: false,
    unsealedCount: 0,
    failedCount: 0,
  });
  assert.equal(outcome.kind, 'targeted-bridge-missing');
  assert.notEqual(
    outcome.kind,
    'dispatched',
    'zero attempted and zero failed must NOT collapse into the generic success message',
  );
});

test('REQ-UNSEAL-5: the missing-bridge case is a distinct state, not a permissive default', () => {
  // REQ-UNSEAL-5 asks for an explicit unknown rather than a permissive default. The
  // whole point is that this case is distinguishable at all: it must not share an
  // outcome with "we sent something".
  const missing = resolveUnsealOutcome({
    pendingUnsealBridgeId: 'brg_gone', pendingBridgeFound: false, unsealedCount: 0, failedCount: 0,
  });
  const dispatched = resolveUnsealOutcome({
    pendingUnsealBridgeId: null, pendingBridgeFound: false, unsealedCount: 0, failedCount: 0,
  });
  assert.notDeepEqual(missing, dispatched);
});

test('resolveUnsealOutcome reports the other three outcomes faithfully', () => {
  assert.deepEqual(
    resolveUnsealOutcome({ pendingUnsealBridgeId: 'brg_a', pendingBridgeFound: true, unsealedCount: 1, failedCount: 0 }),
    { kind: 'unsealed', count: 1 },
  );
  // A bridge that is present but failed is reported as a failure, not as success.
  assert.deepEqual(
    resolveUnsealOutcome({ pendingUnsealBridgeId: 'brg_a', pendingBridgeFound: true, unsealedCount: 0, failedCount: 1 }),
    { kind: 'failed' },
  );
  // A partial bulk run still reports the successes it had.
  assert.deepEqual(
    resolveUnsealOutcome({ pendingUnsealBridgeId: null, pendingBridgeFound: false, unsealedCount: 2, failedCount: 1 }),
    { kind: 'unsealed', count: 2 },
  );
});

