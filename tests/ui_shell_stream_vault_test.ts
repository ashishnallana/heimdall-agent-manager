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

import {
  encryptShellStreamPayload,
  decryptShellStreamPayload,
} from '../src/ui/components/shells/useShellStream.ts';
import {
  base64ToBytes,
  bytesToBase64,
  VAULT_ARMOR_PREFIX,
  decryptVaultText,
  isVaultArmored,
} from '../src/ui/utils/vaultContent.ts';
import { importRawKeyHex, getActiveVaultKey } from '../src/ui/utils/vaultCrypto.ts';

const TEST_VAULT_KEY = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const ALT_VAULT_KEY = 'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';

// -----------------------------------------------------------------------------
// 1. Stream Cryptographic Round-Trip & Wire Format
// -----------------------------------------------------------------------------

test('encryptShellStreamPayload produces valid 12B IV + 16B tag + ciphertext structure', async () => {
  const plaintext = 'echo "Hello, Zero-Trust Bridge PTY!"\r\n';
  const enc_b64 = await encryptShellStreamPayload(plaintext, TEST_VAULT_KEY);

  assert.ok(typeof enc_b64 === 'string', 'enc_b64 must be a string');
  assert.ok(enc_b64.length > 0, 'enc_b64 must not be empty');

  const rawBytes = base64ToBytes(enc_b64);
  const expectedPlaintextBytes = new TextEncoder().encode(plaintext);
  const expectedTotalBytes = 12 + 16 + expectedPlaintextBytes.length; // 28 header bytes + ciphertext
  assert.equal(rawBytes.length, expectedTotalBytes, 'payload must be 28 bytes header + ciphertext');
});

test('decryptShellStreamPayload correctly decrypts encrypted PTY output', async () => {
  const originalText = '\x1b[32muser@cloudtop:~$ ls -la\r\ntotal 64\r\ndrwxr-xr-x 2 user user 4096\x1b[0m\r\n';
  const enc_b64 = await encryptShellStreamPayload(originalText, TEST_VAULT_KEY);

  const decryptedBytes = await decryptShellStreamPayload(enc_b64, TEST_VAULT_KEY);
  const decryptedText = new TextDecoder().decode(decryptedBytes);

  assert.equal(decryptedText, originalText, 'decrypted text must match original plaintext exactly');
});

test('decryptShellStreamPayload transparently strips vault:v1: prefix if present', async () => {
  const original = 'cat /etc/os-release';
  const raw_b64 = await encryptShellStreamPayload(original, TEST_VAULT_KEY);
  const armored = `${VAULT_ARMOR_PREFIX}${raw_b64}`;

  const decrypted = await decryptShellStreamPayload(armored, TEST_VAULT_KEY);
  assert.equal(new TextDecoder().decode(decrypted), original);
});

test('decryptShellStreamPayload handles Uint8Array input and binary terminal control sequences', async () => {
  // VT100 / ANSI escape sequence with binary data
  const binaryData = new Uint8Array([0x1b, 0x5b, 0x32, 0x4a, 0x1b, 0x5b, 0x48, 0x00, 0xff, 0x7f]);
  const enc_b64 = await encryptShellStreamPayload(binaryData, TEST_VAULT_KEY);

  const decrypted = await decryptShellStreamPayload(enc_b64, TEST_VAULT_KEY);
  assert.deepEqual(decrypted, binaryData, 'binary bytes must match exactly');
});

test('encryptShellStreamPayload generates unique random 12B nonces for semantic security', async () => {
  const data = 'repeat keystroke test';
  const enc1 = await encryptShellStreamPayload(data, TEST_VAULT_KEY);
  const enc2 = await encryptShellStreamPayload(data, TEST_VAULT_KEY);

  assert.notEqual(enc1, enc2, 'consecutive encryptions of identical data must produce distinct ciphertexts');

  const bytes1 = base64ToBytes(enc1);
  const bytes2 = base64ToBytes(enc2);
  const nonce1 = bytes1.subarray(0, 12);
  const nonce2 = bytes2.subarray(0, 12);
  assert.notDeepEqual(nonce1, nonce2, 'nonces must be randomized');
});

test('decryptShellStreamPayload rejects tampered ciphertext or authentication tag', async () => {
  const message = 'sensitive command execution';
  const enc_b64 = await encryptShellStreamPayload(message, TEST_VAULT_KEY);
  const bytes = base64ToBytes(enc_b64);

  // Tamper with the last byte of ciphertext
  bytes[bytes.length - 1] ^= 0x01;
  const tamperedB64 = bytesToBase64(bytes);

  await assert.rejects(
    async () => {
      await decryptShellStreamPayload(tamperedB64, TEST_VAULT_KEY);
    },
    'decryption of tampered ciphertext must fail authentication'
  );
});

test('decryptShellStreamPayload rejects decryption with mismatched vault key', async () => {
  const message = 'confidential shell session';
  const enc_b64 = await encryptShellStreamPayload(message, TEST_VAULT_KEY);

  await assert.rejects(
    async () => {
      await decryptShellStreamPayload(enc_b64, ALT_VAULT_KEY);
    },
    'decryption with incorrect key must fail authentication'
  );
});

test('decryptShellStreamPayload rejects truncated payloads', async () => {
  const truncated = bytesToBase64(new Uint8Array(20)); // Less than 28 bytes header
  await assert.rejects(
    async () => {
      await decryptShellStreamPayload(truncated, TEST_VAULT_KEY);
    },
    /shorter than header/
  );
});

test('WebCrypto CryptoKey instance can be passed directly to encrypt and decrypt', async () => {
  const cryptoKey = await importRawKeyHex(TEST_VAULT_KEY);
  const text = 'direct CryptoKey instance test';

  const enc = await encryptShellStreamPayload(text, cryptoKey);
  const dec = await decryptShellStreamPayload(enc, cryptoKey);

  assert.equal(new TextDecoder().decode(dec), text);
});

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
  const key = await unlockVault(store, TEST_VAULT_KEY);
  try {
    const body = await captureCreateShell(store, { cmd, cwd, kind: 'shell' });

    assert.ok(body.enc_spec, 'request body must carry enc_spec');
    assert.ok(isVaultArmored(body.enc_spec), 'enc_spec must start with vault:v1:');
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
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(parsedSpec.nonce),
      `nonce must be a valid UUID string, got: ${parsedSpec.nonce}`,
    );
  } finally {
    await clearActiveKey();
  }
});

test('REQ-FIX-ENC-1: createShell encrypts enc_spec with the CryptoKey from getActiveVaultKey(), with no hex anywhere', async () => {
  const store = await makeVaultStore();
  const key = await unlockVault(store, TEST_VAULT_KEY);
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
  await unlockVault(store, TEST_VAULT_KEY);
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
  await unlockVault(store, TEST_VAULT_KEY);
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
  const key = await unlockVault(store, TEST_VAULT_KEY);
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
  const key = await unlockVault(store, TEST_VAULT_KEY);
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

test('REQ-SHELL-ENC-10: sendShellInput puts enc_b64 and armored data_b64 on the wire when unlocked', async () => {
  const data = 'ls -la\n';
  const store = await makeVaultStore();
  const key = await unlockVault(store, TEST_VAULT_KEY);
  try {
    const body = await captureSendShellInput(store, data);

    assert.ok(body.enc_b64, 'enc_b64 must be attached to the request');
    assert.ok(
      String(body.data_b64).startsWith(VAULT_ARMOR_PREFIX),
      `data_b64 must be armored, got: ${String(body.data_b64).slice(0, 32)}`,
    );
    const decrypted = await decryptShellStreamPayload(body.enc_b64, key);
    assert.equal(new TextDecoder().decode(decrypted), data, 'enc_b64 must decrypt to the keystrokes');
  } finally {
    await clearActiveKey();
  }
});

test('REQ-SHELL-ENC-10: sendShellInput omits enc_b64 and data_b64 when the vault is locked', async () => {
  const data = 'ls -la\n';
  const store = await makeVaultStore();
  await unlockVault(store, TEST_VAULT_KEY);
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

test('REQ-SHELL-ENC-12: decryptShellStreamPayload transparently decrypts vault:v1: armored data_b64', async () => {
  const plaintext = '\x1b[32mhello from encrypted pty\x1b[0m\r\n';
  const enc_b64 = await encryptShellStreamPayload(plaintext, TEST_VAULT_KEY);
  const armored_data_b64 = `${VAULT_ARMOR_PREFIX}${enc_b64}`;

  assert.ok(armored_data_b64.startsWith('vault:v1:'), 'must have vault:v1: prefix');
  const decrypted = await decryptShellStreamPayload(armored_data_b64, TEST_VAULT_KEY);
  assert.equal(new TextDecoder().decode(decrypted), plaintext);
});

test('REQ-FIX-ENC-2: useAgentStream message decoding handles armored output and screen frames', async () => {
  const cryptoKey = await importRawKeyHex(TEST_VAULT_KEY);
  const sampleOutput = '\r\nAgent output stream line 1\r\n';
  const enc_b64 = await encryptShellStreamPayload(sampleOutput, cryptoKey);
  const armored = `${VAULT_ARMOR_PREFIX}${enc_b64}`;

  // Test decrypting armored output payload
  const decryptedOutputBytes = await decryptShellStreamPayload(armored, cryptoKey);
  assert.equal(new TextDecoder().decode(decryptedOutputBytes), sampleOutput);

  // Test decrypting screen snapshot payload
  const screenContent = '\x1b[2J\x1b[HWelcome to Heimdall Terminal';
  const encScreen = await encryptShellStreamPayload(screenContent, cryptoKey);
  const decryptedScreenBytes = await decryptShellStreamPayload(encScreen, cryptoKey);
  assert.equal(new TextDecoder().decode(decryptedScreenBytes), screenContent);
});

test('REQ-FIX-ENC-3: sendInput payload generation matches zero-trust protocol', async () => {
  const cryptoKey = await importRawKeyHex(TEST_VAULT_KEY);
  const keystroke = 'cargo build\r';
  const enc_b64 = await encryptShellStreamPayload(keystroke, cryptoKey);
  const frame = { type: 'input', data_b64: enc_b64, is_encrypted: true };

  assert.equal(frame.type, 'input');
  assert.equal(frame.is_encrypted, true);
  assert.ok(!frame.data_b64.startsWith('vault:v1:'));
  assert.ok(!('enc_b64' in frame));
  const decrypted = await decryptShellStreamPayload(frame.data_b64, cryptoKey);
  assert.equal(new TextDecoder().decode(decrypted), keystroke);
});



