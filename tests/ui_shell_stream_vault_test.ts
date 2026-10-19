// REQ-SHELL-ENC-5: Automated unit and contract tests for client-side PTY stream decryption and input encryption
// Validates transparent AES-256-GCM decryption of enc_b64 stream frames, keystroke encryption,
// locked vault graceful fallback, and bridge wire-format compatibility.
//
// RUN: node --test tests/ui_shell_stream_vault_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
// Imported FIRST: this registers the module resolve hook that lets node load
// src/ui/api/endpoints/*.ts, whose relative imports are extensionless.
import {
  installFetchCapture,
  installWindowShim,
  makeVaultStore,
  unlockVault,
  lockVaultFully,
  clearActiveKey,
} from './helpers/vaultEndpointHarness.ts';

import { decryptShellStreamPayload } from '../src/ui/components/shells/useShellStream.ts';
import { setPtyBridgeBootId } from '../src/ui/components/shells/ptyWire.ts';

const TEST_BRIDGE_BOOT_ID = '00112233445566778899aabbccddeeff';
import { decryptVaultText, isVaultArmored } from '../src/ui/utils/vaultContent.ts';
import { getActiveVaultKey } from '../src/ui/utils/vaultCrypto.ts';

const TEST_VAULT_KEY_RAW = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

// -----------------------------------------------------------------------------
// 3b. REQ-SHELL-ENC-8 / REQ-FIX-ENC-1 / REQ-RAWKEY-A8: createShell through the REAL endpoint.
//
// These replace five tests that COPIED createShell's queryFn into the test body and
// then asserted on their own copy. That shape cannot fail when the endpoint is broken:
// it is exactly how artifact names and chain titles went to the wire in PLAINTEXT while
// the suite stayed green. So the real mutation is dispatched through a real store with a
// stubbed fetch, and every assertion is on the CAPTURED REQUEST BODY.
//
// The key is supplied the production way -- a non-extractable CryptoKey in the active-key
// slot -- never by injecting hex into mock Redux state, which no production read reaches.
// -----------------------------------------------------------------------------

installWindowShim();
const shellFetch = installFetchCapture();
const { shellsApi } = await import('../src/ui/api/endpoints/shells.ts');

const CREATE_SHELL_OK = { data: { session: { session_id: 'sh_test', kind: 'shell' } } };

/** Dispatch the real createShell mutation and return the body that hit the wire. */
async function captureCreateShell(store: any, args: Record<string, any>) {
  shellFetch.reset();
  shellFetch.setNextResponse(CREATE_SHELL_OK);
  const res: any = await store.dispatch(
    shellsApi.endpoints.createShell.initiate({ bridgeId: 'brg_test', ...args } as any),
  );
  assert.ok(!res?.error, `createShell returned an error: ${JSON.stringify(res?.error)}`);
  return shellFetch.find((r) => r.method === 'POST' && /\/bridges\/brg_test\/shells$/.test(r.url)).body;
}

test('REQ-SHELL-ENC-8: createShell puts an armored enc_spec with cmd, cwd, timestamp and nonce on the wire when unlocked', async () => {
  const cmd = 'npm run dev';
  const cwd = '/home/user/project';
  const startTime = Date.now();

  const store = await makeVaultStore();
  const key = await unlockVault(store, TEST_VAULT_KEY_RAW);
  try {
    const body = await captureCreateShell(store, { cmd, cwd, kind: 'shell' });

    assert.ok(body.enc_spec, 'request body must carry enc_spec');
    assert.ok(isVaultArmored(body.enc_spec), 'enc_spec must start with vault:v2:e1:');
    // NOTE ON SCOPE -- enc_spec is INTEGRITY/AUTHORIZATION, not confidentiality.
    // cmd and cwd deliberately ALSO travel in plaintext: the hub persists them
    // (shell_session_rest_handlers.odin:163-164) so sessions can be listed and
    // labelled, while the bridge ignores those fields and takes the authoritative
    // cmd/cwd from the decrypted spec, rejecting any request whose enc_spec is
    // missing, unarmored, undecryptable or outside a 60s replay window
    // (hub_runtime_client.odin:3361-3394). domain/bridge.odin:42-45 names this guard
    // the authoritative authorization check. So assert what the mechanism promises:
    // the ciphertext is real and independent of the plaintext copy.
    assert.notEqual(body.enc_spec, cmd, 'enc_spec must be ciphertext, not the bare command');
    assert.ok(!body.enc_spec.includes(cmd), 'the enc_spec ciphertext must not embed the plaintext command');

    const parsedSpec = JSON.parse(await decryptVaultText(body.enc_spec, key));
    assert.equal(parsedSpec.cmd, cmd, 'decrypted spec cmd must match input cmd');
    assert.equal(parsedSpec.cwd, cwd, 'decrypted spec cwd must match input cwd');
    assert.ok(typeof parsedSpec.timestamp === 'number', 'timestamp must be a number');
    assert.ok(parsedSpec.timestamp >= startTime && parsedSpec.timestamp <= Date.now(), 'timestamp must be current');
    assert.ok(
      /^[0-9a-f]{32}$/.test(parsedSpec.nonce),
      `nonce must be 16 CSPRNG bytes as hex, got: ${parsedSpec.nonce}`,
    );
  } finally {
    await clearActiveKey();
  }
});

test('REQ-FIX-ENC-1: createShell encrypts enc_spec with the CryptoKey from getActiveVaultKey(), with no hex anywhere', async () => {
  const store = await makeVaultStore();
  const key = await unlockVault(store, TEST_VAULT_KEY_RAW);
  try {
    // The production unlock path stores ONLY a non-extractable CryptoKey. Prove the
    // endpoint encrypts from that, with no hex key reachable from state.
    assert.ok(getActiveVaultKey() instanceof Object, 'an active CryptoKey must be present');
    assert.equal((store.getState() as any).vault.rawVaultKeyHex, undefined,
      'no hex key may exist in Redux state -- the endpoint must not need one');

    const body = await captureCreateShell(store, { cmd: 'cargo test', cwd: '/workspace', kind: 'run' });
    assert.ok(isVaultArmored(body.enc_spec), 'enc_spec must be armored');
    const parsed = JSON.parse(await decryptVaultText(body.enc_spec, key));
    assert.equal(parsed.cmd, 'cargo test');
    assert.equal(parsed.cwd, '/workspace');
  } finally {
    await clearActiveKey();
  }
});

test('REQ-SHELL-ENC-8: createShell omits enc_spec and sends plaintext when the vault is locked', async () => {
  const store = await makeVaultStore();
  await unlockVault(store, TEST_VAULT_KEY_RAW);
  await lockVaultFully(store);
  try {
    assert.equal(getActiveVaultKey(), null, 'precondition: locking clears the active key');
    const body = await captureCreateShell(store, { cmd: 'ls -la', cwd: '/tmp', kind: 'run' });

    assert.strictEqual(body.enc_spec, undefined, 'enc_spec must be omitted when the vault is locked');
    assert.equal(body.cmd, 'ls -la', 'cmd must pass through in plaintext');
    assert.equal(body.cwd, '/tmp', 'cwd must pass through in plaintext');
  } finally {
    await clearActiveKey();
  }
});

test('REQ-SHELL-ENC-8: createShell omits enc_spec when no key is active even though state says unlocked', async () => {
  const store = await makeVaultStore();
  await unlockVault(store, TEST_VAULT_KEY_RAW);
  // The failure mode this guards: Redux still flags unlocked, but the key is gone (a
  // reload, or a lock that did not propagate). Encryption must be skipped, not attempted.
  await clearActiveKey();
  try {
    assert.equal(getActiveVaultKey(), null, 'precondition: no active key');
    const body = await captureCreateShell(store, { cmd: 'cat /etc/hosts', cwd: '/', kind: 'run' });
    assert.strictEqual(body.enc_spec, undefined, 'enc_spec must be omitted when no key is active');
    assert.equal(body.cmd, 'cat /etc/hosts');
  } finally {
    await clearActiveKey();
  }
});

test('REQ-SHELL-ENC-8: createShell defaults omitted cmd and cwd to empty strings in the encrypted spec', async () => {
  const store = await makeVaultStore();
  const key = await unlockVault(store, TEST_VAULT_KEY_RAW);
  try {
    const body = await captureCreateShell(store, { kind: 'shell' });
    assert.ok(body.enc_spec, 'enc_spec must be present');
    const parsedSpec = JSON.parse(await decryptVaultText(body.enc_spec, key));
    assert.strictEqual(parsedSpec.cmd, '', 'omitted cmd must default to empty string');
    assert.strictEqual(parsedSpec.cwd, '', 'omitted cwd must default to empty string');
  } finally {
    await clearActiveKey();
  }
});

test('REQ-SHELL-ENC-8: two identical createShell calls produce distinct ciphertexts and distinct nonces', async () => {
  const store = await makeVaultStore();
  const key = await unlockVault(store, TEST_VAULT_KEY_RAW);
  try {
    const args = { cmd: 'test', cwd: '/dir', kind: 'run' as const };
    const first = await captureCreateShell(store, args);
    const second = await captureCreateShell(store, args);

    assert.notEqual(first.enc_spec, second.enc_spec, 'identical input must not yield identical ciphertext');
    const p1 = JSON.parse(await decryptVaultText(first.enc_spec, key));
    const p2 = JSON.parse(await decryptVaultText(second.enc_spec, key));
    assert.notEqual(p1.nonce, p2.nonce, 'each spec must carry a fresh nonce');
  } finally {
    await clearActiveKey();
  }
});

// -----------------------------------------------------------------------------
// 4. REQ-SHELL-ENC-10: sendShellInput Vault Encryption in shells.ts
// -----------------------------------------------------------------------------

/** Dispatch the real sendShellInput mutation and return the body that hit the wire. */
async function captureSendShellInput(store: any, data: string) {
  shellFetch.reset();
  shellFetch.setNextResponse({ data: { ok: true } });
  const res: any = await store.dispatch(
    shellsApi.endpoints.sendShellInput.initiate({ sessionId: 'sh_test', data } as any),
  );
  assert.ok(!res?.error, `sendShellInput returned an error: ${JSON.stringify(res?.error)}`);
  return shellFetch.find((r) => r.method === 'POST' && /\/shells\/sh_test\/input$/.test(r.url)).body;
}

test('REQ-SHELL-ENC-10: sendShellInput puts a PTY v2 enc_b64 and NO plaintext on the wire when unlocked', async () => {
  const data = 'ls -la\n';
  const store = await makeVaultStore();
  const key = await unlockVault(store, TEST_VAULT_KEY_RAW);
  // The stream's ready frame announced the bridge's unseal boot id.
  setPtyBridgeBootId('sh_test', TEST_BRIDGE_BOOT_ID);
  try {
    const body = await captureSendShellInput(store, data);

    assert.ok(body.enc_b64, 'enc_b64 must be attached to the request');
    assert.equal(body.data, '', 'plaintext keystrokes must not travel next to the ciphertext');
    assert.strictEqual(body.data_b64, undefined, 'the v1 armored data_b64 is gone');
    const decrypted = await decryptShellStreamPayload(body.enc_b64, key, 'sh_test', 'in', TEST_BRIDGE_BOOT_ID);
    assert.equal(new TextDecoder().decode(decrypted!), data, 'enc_b64 must decrypt to the keystrokes');
  } finally {
    await clearActiveKey();
  }
});

test('REQ-SHELL-ENC-10: sendShellInput omits enc_b64 and data_b64 when the vault is locked', async () => {
  const data = 'ls -la\n';
  const store = await makeVaultStore();
  await unlockVault(store, TEST_VAULT_KEY_RAW);
  await lockVaultFully(store);
  try {
    const body = await captureSendShellInput(store, data);
    assert.strictEqual(body.enc_b64, undefined, 'enc_b64 must not be set when the vault is locked');
    assert.strictEqual(body.data_b64, undefined, 'data_b64 must not be set when the vault is locked');
    assert.equal(body.data, data, 'the plaintext input still has to reach the bridge');
  } finally {
    await clearActiveKey();
  }
});
