// REQ-FS-ENC-4: Unit Tests for Web UI projectFs Zero-Knowledge Vault Encryption & Decryption
// Verifies transparent client-side decryption for file reads and search matches,
// and client-side encryption for file writes and batch file writes.
//
// RUN: node --test tests/ui_project_fs_vault_test.ts

import { keyringFromHex } from './helpers/vaultTestKeyring.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
// Imported FIRST: registers the module resolve hook that lets node load
// src/ui/api/endpoints/projectFs.ts, whose relative imports are extensionless.
import {
  installFetchCapture,
  installWindowShim,
  makeVaultStore,
  unlockVault,
  lockVaultFully,
  clearActiveKey,
} from './helpers/vaultEndpointHarness.ts';
import {
  isVaultArmored,
  encryptVaultText,
  decryptVaultText,
  getActiveVaultKey,
  VAULT_ARMOR_PREFIX,
} from '../src/ui/utils/vaultContent.ts';
import { openFsWriteContent } from '../src/ui/utils/vaultCrypto.ts';
import vaultReducer, {
  keyringInstalled,
  keyringCleared,
  selectIsVaultUnlocked,
} from '../src/ui/store/vaultSlice.ts';

const TEST_KEY_HEX_RAW = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const TEST_KEY_HEX = await keyringFromHex(TEST_KEY_HEX_RAW);
const DIFFERENT_KEY_HEX_RAW = 'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';
const DIFFERENT_KEY_HEX = await keyringFromHex(DIFFERENT_KEY_HEX_RAW);

// -----------------------------------------------------------------------------
// REAL-ENDPOINT wire verification
// -----------------------------------------------------------------------------
// REQ-RAWKEY-A8: these sections used to RE-IMPLEMENT each queryFn's transform
// inside the test body -- reading a fake `state.vault.rawVaultKeyHex` that no
// production code can reach -- and then assert on their own copy. Such a test
// cannot fail when projectFs.ts is broken, and that is the exact shape that let
// the P0 (plaintext on the wire) survive review. They now dispatch the REAL
// endpoints through a REAL store with a stubbed fetch and assert on the ACTUAL
// WIRE PAYLOAD / the value the endpoint actually returns to the caller.
//
// The key is supplied the production way by `unlockVault()`: a non-extractable
// CryptoKey in the module-level active-key slot, never hex in Redux state.

const cap = installFetchCapture();
installWindowShim();

const projectFs = await import('../src/ui/api/endpoints/projectFs.ts');
const { endpoints } = projectFs.projectFsApi;

/** Fresh store + fetch log per test; every test leaves the vault locked. */
async function freshStore(): Promise<any> {
  cap.reset();
  const store = await makeVaultStore();
  await clearActiveKey();
  return store;
}

/** Dispatch a query, bypassing the RTK Query cache so each test really runs. */
async function runQuery(store: any, thunk: any): Promise<any> {
  const res = await store.dispatch(thunk);
  assert.ok(!res?.error, `query returned an error: ${JSON.stringify(res?.error)}`);
  return res.data;
}

const READ_ARGS = (path: string) => ({ projectId: 'proj_test', path });
const q = { subscribe: false, forceRefetch: true };

// ---- Section 2: readProjectFile decryption ----------------------------------

test('readProjectFile: transparently decrypts vault:v2:e1: content when the vault is unlocked', async () => {
  const secretFileText = 'DATABASE_URL="postgres://admin:supersecret@db:5432/main"\nJWT_SECRET="xyz-token"';
  const armoredCiphertext = await encryptVaultText(secretFileText, TEST_KEY_HEX);
  assert.ok(isVaultArmored(armoredCiphertext), 'fixture ciphertext must start with vault:v2:e1:');

  const store = await freshStore();
  await unlockVault(store, TEST_KEY_HEX_RAW);
  cap.setNextResponse({ ok: true, path: 'secrets/.env', content: armoredCiphertext });

  const data = await runQuery(store, endpoints.readProjectFile.initiate(READ_ARGS('secrets/.env'), q));

  assert.equal(data.content, secretFileText, 'armored file content must reach the caller as plaintext');
  await lockVaultFully(store);
});

test('readProjectFile: leaves content armored when the vault is locked', async () => {
  const armoredCiphertext = await encryptVaultText('SUPER_SECRET_TOKEN=abc12345', TEST_KEY_HEX);

  const store = await freshStore();
  // Locked: no active key, and the slice never unlocked.
  cap.setNextResponse({ ok: true, path: 'locked/.env', content: armoredCiphertext });

  const data = await runQuery(store, endpoints.readProjectFile.initiate(READ_ARGS('locked/.env'), q));

  assert.equal(data.content, armoredCiphertext, 'armored content must stay armored while locked');
  await lockVaultFully(store);
});

test('readProjectFile: leaves content armored when no key is active even though state says unlocked', async () => {
  // The A7 race shape: Redux still flags unlocked (a reload, or a lock that did
  // not propagate) but the CryptoKey slot is empty. The gate must follow the KEY,
  // not the flag -- the old `isUnlocked && rawVaultKeyHex` form could not express
  // this at all, because its second operand was dead on every branch.
  const armoredCiphertext = await encryptVaultText('SUPER_SECRET_TOKEN=abc12345', TEST_KEY_HEX);

  const store = await freshStore();
  await unlockVault(store, TEST_KEY_HEX_RAW);
  await clearActiveKey();
  assert.equal(getActiveVaultKey(), null, 'precondition: no active CryptoKey');
  assert.equal(selectIsVaultUnlocked(store.getState()), true, 'precondition: slice still says unlocked');
  cap.setNextResponse({ ok: true, path: 'nokey/.env', content: armoredCiphertext });

  const data = await runQuery(store, endpoints.readProjectFile.initiate(READ_ARGS('nokey/.env'), q));

  assert.equal(data.content, armoredCiphertext, 'no key means no decryption, regardless of the flag');
  await lockVaultFully(store);
});

test('readProjectFile: leaves content armored when decryption fails (wrong key) rather than throwing', async () => {
  const armoredCiphertext = await encryptVaultText('CONFIDENTIAL_NOTE', TEST_KEY_HEX);

  const store = await freshStore();
  await unlockVault(store, DIFFERENT_KEY_HEX_RAW);
  cap.setNextResponse({ ok: true, path: 'wrongkey/.env', content: armoredCiphertext });

  const data = await runQuery(store, endpoints.readProjectFile.initiate(READ_ARGS('wrongkey/.env'), q));

  assert.equal(data.content, armoredCiphertext, 'a failed decrypt must leave the armor intact, not crash the query');
  await lockVaultFully(store);
});

test('readProjectFile: leaves unarmored plain text untouched when unlocked', async () => {
  const plainText = '# Public README\nThis is a standard repository.';

  const store = await freshStore();
  await unlockVault(store, TEST_KEY_HEX_RAW);
  cap.setNextResponse({ ok: true, path: 'README.md', content: plainText });

  const data = await runQuery(store, endpoints.readProjectFile.initiate(READ_ARGS('README.md'), q));

  assert.equal(data.content, plainText, 'plain unarmored text must pass through untouched');
  await lockVaultFully(store);
});

// ---- Section 3/4: file writes are sealed for the bridge and the path (N4) ----

test('writeProjectFile: seals content for the target bridge and exact path', async () => {
  const plainContent = 'AWS_SECRET_ACCESS_KEY="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"';

  const store = await freshStore();
  await unlockVault(store, TEST_KEY_HEX_RAW);
  cap.reset();
  cap.setNextResponse({ ok: true });

  const res = await store.dispatch(
    endpoints.writeProjectFile.initiate({ projectId: 'proj_test', bridgeId: 'brg_test', path: 'secrets/prod.env', content: plainContent }),
  );
  assert.ok(!res?.error, `writeProjectFile errored: ${JSON.stringify(res?.error)}`);

  const wire = cap.find((r) => r.method === 'PUT' && /\/fs\/file/.test(r.url));
  assert.ok(isVaultArmored(wire.body.content), 'wire content must be armored');
  assert.ok(!String(wire.body.content).includes('wJalrXUtnFEMI'), 'plaintext secret must NOT appear on the wire');
  assert.equal(wire.body.path, 'secrets/prod.env', 'the path is metadata and stays plaintext');
  assert.equal(await openFsWriteContent(wire.body.content, 'brg_test', 'secrets/prod.env', TEST_KEY_HEX), plainContent);
  await assert.rejects(openFsWriteContent(wire.body.content, 'brg_test', 'secrets/other.env', TEST_KEY_HEX), 'bound to the path');
  await assert.rejects(openFsWriteContent(wire.body.content, 'brg_other', 'secrets/prod.env', TEST_KEY_HEX), 'bound to the bridge');
  await assert.rejects(decryptVaultText(wire.body.content, TEST_KEY_HEX), 'not a content envelope');
  await lockVaultFully(store);
});

test('writeProjectFile: refuses without a key or a bridge id and sends nothing', async () => {
  const store = await freshStore();
  cap.reset();
  const locked = await store.dispatch(
    endpoints.writeProjectFile.initiate({ projectId: 'proj_test', bridgeId: 'brg_test', path: 'src/a.ts', content: 'const a = 1;' }),
  );
  assert.ok(locked?.error, 'a locked vault refuses the write');
  await unlockVault(store, TEST_KEY_HEX_RAW);
  const noBridge = await store.dispatch(
    endpoints.writeProjectFile.initiate({ projectId: 'proj_test', path: 'src/a.ts', content: 'const a = 1;' }),
  );
  assert.ok(noBridge?.error, 'a write without a bridge id is refused');
  assert.equal(cap.requests.filter((r) => r.method === 'PUT').length, 0, 'nothing reaches the hub');
  await lockVaultFully(store);
});

test('batchWriteProjectFiles: seals every file for its own path', async () => {
  const files = [
    { path: 'secrets/prod.env', content: 'DB_PASS=xyz789' },
    { path: 'src/main.ts', content: 'console.log("hello");' },
  ];

  const store = await freshStore();
  await unlockVault(store, TEST_KEY_HEX_RAW);
  cap.reset();
  cap.setNextResponse({ ok: true });

  const res = await store.dispatch(endpoints.batchWriteProjectFiles.initiate({ projectId: 'proj_test', bridgeId: 'brg_test', files }));
  assert.ok(!res?.error, `batchWriteProjectFiles errored: ${JSON.stringify(res?.error)}`);

  const wire = cap.find((r) => r.method === 'PUT' && /\/fs\/files/.test(r.url));
  assert.equal(wire.body.files.length, 2);
  for (let i = 0; i < files.length; i++) {
    const sent = wire.body.files[i];
    assert.equal(sent.path, files[i].path);
    assert.equal(await openFsWriteContent(sent.content, 'brg_test', files[i].path, TEST_KEY_HEX), files[i].content);
  }
  await lockVaultFully(store);
});

// ---- Section 5: searchProjectFiles grep match decryption --------------------

const SECRET_LINE_1 = 'const API_SECRET = "sk_live_999";';
const SECRET_LINE_2 = 'export const DB_PASS = "admin_super_secret";';
const PUBLIC_LINE = 'const PUBLIC_VAR = 42;';

async function searchFixtureMatches(): Promise<any[]> {
  const armored1 = await encryptVaultText(SECRET_LINE_1, TEST_KEY_HEX);
  const armored2 = await encryptVaultText(SECRET_LINE_2, TEST_KEY_HEX);
  return [
    // both fields armored
    { path: 'src/config.ts', line_number: 10, column: 1, match_start: 0, match_end: 15, line: armored1, line_content: armored1 },
    // only `line` present -- the endpoint must mirror it into line_content
    { path: 'src/db.ts', line_number: 25, column: 1, match_start: 0, match_end: 20, line: armored2 },
    // unarmored, must pass through
    { path: 'src/public.ts', line_number: 5, column: 1, match_start: 0, match_end: 10, line: PUBLIC_LINE, line_content: PUBLIC_LINE },
  ];
}

test('searchProjectFiles: decrypts armored line and line_content in grep matches when unlocked', async () => {
  const store = await freshStore();
  await unlockVault(store, TEST_KEY_HEX_RAW);
  cap.setNextResponse({ matches: await searchFixtureMatches() });

  const data = await runQuery(
    store,
    endpoints.searchProjectFiles.initiate({ projectId: 'proj_test', query: 'SECRET' }, q),
  );

  assert.equal(data.matches.length, 3);
  assert.equal(data.matches[0].line, SECRET_LINE_1);
  assert.equal(data.matches[0].line_content, SECRET_LINE_1);
  // `line` only on the wire: decrypted AND mirrored into line_content.
  assert.equal(data.matches[1].line, SECRET_LINE_2);
  assert.equal(data.matches[1].line_content, SECRET_LINE_2, 'line_content must be mirrored from the decrypted line');
  assert.equal(data.matches[2].line, PUBLIC_LINE, 'unarmored matches pass through untouched');
  assert.equal(data.matches[2].line_content, PUBLIC_LINE);
  await lockVaultFully(store);
});

test('searchProjectFiles: leaves grep matches armored when the vault is locked', async () => {
  const fixture = await searchFixtureMatches();
  const store = await freshStore();
  cap.setNextResponse({ matches: fixture });

  const data = await runQuery(
    store,
    endpoints.searchProjectFiles.initiate({ projectId: 'proj_test', query: 'SECRET', path: 'locked' }, q),
  );

  assert.equal(data.matches[0].line, fixture[0].line, 'armored match text must stay armored while locked');
  assert.ok(isVaultArmored(data.matches[0].line_content));
  assert.ok(!String(data.matches[0].line).includes('sk_live_999'), 'a locked vault must not reveal the secret line');
  await lockVaultFully(store);
});

// -----------------------------------------------------------------------------
// Section 6: Redux vaultSlice state integration
// -----------------------------------------------------------------------------

test('vaultSlice tracks keyring installed / purged and holds no key material', () => {
  let state = vaultReducer(undefined, { type: '@@INIT' });
  assert.strictEqual(selectIsVaultUnlocked({ vault: state }), false);
  state = vaultReducer(state, keyringInstalled({ currentEpoch: 1 }));
  assert.strictEqual(selectIsVaultUnlocked({ vault: state }), true);
  assert.deepStrictEqual(Object.keys(state).sort(), ['currentEpoch', 'isUnlocked']);
  state = vaultReducer(state, keyringCleared());
  assert.strictEqual(selectIsVaultUnlocked({ vault: state }), false);
});
