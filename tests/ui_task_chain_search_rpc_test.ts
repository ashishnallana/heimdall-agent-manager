import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  deriveTaskChainSearchKey,
  firstValidWithSingleHedge,
  openTaskChainSearch,
  sealTaskChainSearch,
  taskChainSearchAad,
  taskChainSearchErrorMessage,
  taskChainSearchRequiresReauthentication,
} from '../src/ui/utils/taskChainSearch.ts';
import { searchTaskChainsEncrypted } from '../src/ui/utils/taskChainSearch.ts';
import {
  setActiveVaultKey,
  getActiveTaskChainSearchKey,
} from '../src/ui/store/vaultSlice.ts';
import { importRawKeyHex } from '../src/ui/utils/vaultCrypto.ts';
import { beginTaskChainSearchKeyDerivation } from '../src/ui/utils/taskChainSearchKey.ts';

const KEY_A = '11'.repeat(32);
const KEY_B = '22'.repeat(32);
const OWNER = 'usr_search';
const BRIDGE = 'brg_primary';
const REQUEST = 'req_search';
const EXPIRES = 1_900_000_000_000;

test('task-chain search envelope round-trips and uses fresh nonces', async () => {
  const key = await deriveTaskChainSearchKey(KEY_A);
  const associated = taskChainSearchAad(OWNER, BRIDGE, REQUEST, 'request', EXPIRES);
  const payload = { request_id: REQUEST, query: 'encrypted search', limit: 20 };
  const first = await sealTaskChainSearch(payload, key, associated);
  const second = await sealTaskChainSearch(payload, key, associated);
  assert.notEqual(first, second);
  assert.deepEqual(await openTaskChainSearch(first, key, associated), payload);
});

test('task-chain search maps every protocol error to a user-facing state', () => {
  const expected: Record<string, RegExp> = {
    bridge_offline: /online/,
    vault_locked: /Unlock/,
    vault_search_reauthentication_required: /Re-enter your vault password once/,
    search_not_ready: /preparing/,
    search_stale: /stale/,
    deadline_exceeded: /timed out/,
    invalid_envelope: /rejected/,
    query_too_short: /two characters/,
    limit_exceeded: /limit/,
  };
  for (const [code, message] of Object.entries(expected)) {
    assert.match(taskChainSearchErrorMessage({ code }), message);
  }
  assert.equal(taskChainSearchRequiresReauthentication({ code: 'vault_search_reauthentication_required' }), true);
  assert.equal(taskChainSearchRequiresReauthentication({ code: 'vault_locked' }), false);
});

test('task-chain search distinguishes a restored legacy session from a locked vault', async () => {
  setActiveVaultKey(await importRawKeyHex(KEY_A));
  assert.equal(getActiveTaskChainSearchKey(), null);
  await assert.rejects(
    () => searchTaskChainsEncrypted('legacy session', OWNER),
    (error: any) => error?.code === 'vault_search_reauthentication_required',
  );
  setActiveVaultKey(null);
  await assert.rejects(
    () => searchTaskChainsEncrypted('locked vault', OWNER),
    (error: any) => error?.code === 'vault_locked',
  );
});

test('task-chain search maps a pending key derivation failure to reauthentication', async () => {
  setActiveVaultKey(await importRawKeyHex(KEY_A));
  const failedDerivation = beginTaskChainSearchKeyDerivation('invalid');
  void failedDerivation.catch(() => {});
  await assert.rejects(
    () => searchTaskChainsEncrypted('derivation failure', OWNER),
    (error: any) => error?.code === 'vault_search_reauthentication_required',
  );
  setActiveVaultKey(null);
});

test('task-chain search starts at most one hedge and keeps fast primary single-target', async () => {
  let backupCalls = 0;
  const fast = await firstValidWithSingleHedge(
    async () => 'primary',
    async () => { backupCalls += 1; return 'backup'; },
    20,
    100,
  );
  assert.equal(fast, 'primary');
  await new Promise((resolve) => setTimeout(resolve, 30));
  assert.equal(backupCalls, 0);

  const hedged = await firstValidWithSingleHedge(
    () => new Promise((resolve) => setTimeout(() => resolve('slow-primary'), 80)),
    async () => { backupCalls += 1; return 'backup'; },
    5,
    100,
  );
  assert.equal(hedged, 'backup');
  assert.equal(backupCalls, 1);
});

test('task-chain search hedge enforces a hard deadline', async () => {
  const never = () => new Promise<string>(() => {});
  await assert.rejects(
    () => firstValidWithSingleHedge(never, never, 2, 10),
    (error: any) => error?.code === 'deadline_exceeded',
  );
});

test('task-chain search envelope rejects wrong key and every AAD binding mismatch', async () => {
  const key = await deriveTaskChainSearchKey(KEY_A);
  const wrongKey = await deriveTaskChainSearchKey(KEY_B);
  const associated = taskChainSearchAad(OWNER, BRIDGE, REQUEST, 'request', EXPIRES);
  const envelope = await sealTaskChainSearch({ request_id: REQUEST, query: 'needle' }, key, associated);
  const invalidAad = [
    taskChainSearchAad('usr_other', BRIDGE, REQUEST, 'request', EXPIRES),
    taskChainSearchAad(OWNER, 'brg_other', REQUEST, 'request', EXPIRES),
    taskChainSearchAad(OWNER, BRIDGE, 'req_other', 'request', EXPIRES),
    taskChainSearchAad(OWNER, BRIDGE, REQUEST, 'response', EXPIRES),
    taskChainSearchAad(OWNER, BRIDGE, REQUEST, 'request', EXPIRES + 1),
  ];
  await assert.rejects(() => openTaskChainSearch(envelope, wrongKey, associated), /Invalid encrypted search response/);
  for (const candidate of invalidAad) {
    await assert.rejects(() => openTaskChainSearch(envelope, key, candidate), /Invalid encrypted search response/);
  }
});

test('task-chain search envelope rejects malformed wire data', async () => {
  const key = await deriveTaskChainSearchKey(KEY_A);
  const associated = taskChainSearchAad(OWNER, BRIDGE, REQUEST, 'response', EXPIRES);
  await assert.rejects(() => openTaskChainSearch('vault:v1:not-search', key, associated), /Invalid encrypted search response/);
  await assert.rejects(() => openTaskChainSearch('search:v1:AA==', key, associated), /Invalid encrypted search response/);
});
