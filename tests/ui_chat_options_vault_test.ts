// Quick-reply option chips must not render beside a still-encrypted message body:
// the options are not part of the ciphertext, so showing them leaks plaintext while
// the vault is locked.
//
// RUN: node --test tests/ui_chat_options_vault_test.ts

import { keyringFromHex } from './helpers/vaultTestKeyring.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { importRawKeyHex, encryptVaultText } from '../src/ui/utils/vaultCrypto.ts';
import { visibleMessageOptions } from '../src/ui/components/chat/types.ts';

const TEST_KEY_HEX_RAW = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const TEST_KEY_HEX = await keyringFromHex(TEST_KEY_HEX_RAW);
const metadata = { options: ['Accept all', 'I will answer inline'] };

test('plaintext message shows its options without a vault key', () => {
  assert.deepEqual(visibleMessageOptions({ body: 'Pick one', metadata }, false), metadata.options);
});

test('armored message hides its options while the vault is locked', async () => {
  const key = await keyringFromHex(TEST_KEY_HEX_RAW);
  const body = await encryptVaultText('Pick one', key);
  assert.deepEqual(visibleMessageOptions({ body, metadata }, false), []);
});

test('embedded vault token hides options while the vault is locked', async () => {
  const key = await keyringFromHex(TEST_KEY_HEX_RAW);
  const token = await encryptVaultText('secret', key);
  assert.deepEqual(visibleMessageOptions({ body: `See ${token}`, metadata }, false), []);
});

test('armored message shows its options once the vault is unlocked', async () => {
  const key = await keyringFromHex(TEST_KEY_HEX_RAW);
  const body = await encryptVaultText('Pick one', key);
  assert.deepEqual(visibleMessageOptions({ body, metadata }, true), metadata.options);
});

test('armored options are dropped while the vault is locked', async () => {
  const key = await keyringFromHex(TEST_KEY_HEX_RAW);
  const armored = await encryptVaultText('Hidden choice', key);
  const meta = { options: ['Visible', armored] };
  assert.deepEqual(visibleMessageOptions({ body: 'Pick one', metadata: meta }, false), ['Visible']);
});
