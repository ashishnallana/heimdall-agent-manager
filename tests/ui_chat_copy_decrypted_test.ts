// REQ-4: the chat message copy button copies decrypted text, never vault ciphertext.
//
// RUN: node --test tests/ui_chat_copy_decrypted_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { importRawKeyHex, encryptVaultText } from '../src/ui/utils/vaultCrypto.ts';
import { resolveCopyableVaultText, VAULT_MASK_PLACEHOLDER } from '../src/ui/utils/vaultContent.ts';

const TEST_KEY_HEX = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const OTHER_KEY_HEX = 'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';

test('armored body copies as plaintext when the vault is unlocked', async () => {
  const key = await importRawKeyHex(TEST_KEY_HEX);
  const body = await encryptVaultText('hello **world**', key);
  assert.ok(body.startsWith('vault:v1:'));
  assert.equal(await resolveCopyableVaultText(body, key), 'hello **world**');
});

test('embedded vault tokens are decrypted in place', async () => {
  const key = await importRawKeyHex(TEST_KEY_HEX);
  const token = await encryptVaultText('secret title', key);
  const body = `Task ${token} is done`;
  assert.equal(await resolveCopyableVaultText(body, key), 'Task secret title is done');
});

test('locked vault copies placeholders, never ciphertext', async () => {
  const key = await importRawKeyHex(TEST_KEY_HEX);
  const armored = await encryptVaultText('top secret', key);
  const embedded = `see ${armored} here`;
  for (const body of [armored, embedded]) {
    const out = await resolveCopyableVaultText(body, null);
    assert.ok(!out.includes('vault:v1:'), `ciphertext leaked: ${out}`);
    assert.ok(out.includes(VAULT_MASK_PLACEHOLDER));
  }
});

test('wrong key copies placeholders, never ciphertext', async () => {
  const key = await importRawKeyHex(TEST_KEY_HEX);
  const other = await importRawKeyHex(OTHER_KEY_HEX);
  const armored = await encryptVaultText('top secret', key);
  for (const body of [armored, `x ${armored} y`]) {
    const out = await resolveCopyableVaultText(body, other);
    assert.ok(!out.includes('vault:v1:'), `ciphertext leaked: ${out}`);
    assert.ok(out.includes(VAULT_MASK_PLACEHOLDER));
  }
});

test('plain messages copy unchanged', async () => {
  const key = await importRawKeyHex(TEST_KEY_HEX);
  assert.equal(await resolveCopyableVaultText('just text', key), 'just text');
  assert.equal(await resolveCopyableVaultText('just text', null), 'just text');
});
