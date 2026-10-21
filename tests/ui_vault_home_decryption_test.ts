// REQ-VAULT-HOME-CHAINS, REQ-VAULT-HOME-ACTIONS, REQ-VAULT-CARDS-PANEL, REQ-VAULT-PINNED-SIDEBAR, REQ-VAULT-TASKCHAINS-PAGE
// Comprehensive Vault decryption unit test suite covering Home page, Action cards, Task chains,
// and Sidebar pinned avatars.
//
// RUN: node --test tests/ui_vault_home_decryption_test.ts

import { keyringFromHex } from './helpers/vaultTestKeyring.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  isVaultArmored,
  containsVaultArmored,
  encryptVaultText,
  decryptVaultText,
  decryptEmbeddedVaultTokens,
  maskVaultArmored,
  VAULT_MASK_PLACEHOLDER,
} from '../src/ui/utils/vaultContent.ts';

const TEST_KEY_HEX_RAW = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const TEST_KEY_HEX = await keyringFromHex(TEST_KEY_HEX_RAW);

// -----------------------------------------------------------------------------
// Section 4: DecryptedMarkdown Unit Tests
//
// <DecryptedMarkdown> renders useDecryptedText(source): decryptVaultText for a fully
// armored source, decryptEmbeddedVaultTokens for embedded tokens, and
// maskVaultArmored while locked. These tests pin those primitives.
// -----------------------------------------------------------------------------

test('DecryptedMarkdown properly decrypts pure armored markdown when unlocked', async () => {
  const secretMarkdown = `### Sensitive Operational Procedure
1. Step One: Connect to isolated gateway.
2. Step Two: Verify SHA256 checksum \`abcdef123456\`.
`;

  const armored = await encryptVaultText(secretMarkdown, TEST_KEY_HEX);
  assert.ok(isVaultArmored(armored));

  // When unlocked
  const unlocked = await decryptVaultText(armored, TEST_KEY_HEX);
  assert.equal(unlocked, secretMarkdown, 'Must decrypt cleanly back to markdown source');

  // When locked
  const locked = maskVaultArmored(armored);
  assert.equal(locked, VAULT_MASK_PLACEHOLDER, 'Must mask armored markdown when locked');
});

test('DecryptedMarkdown properly decrypts embedded vault tokens before markdown rendering', async () => {
  const tokenA = await encryptVaultText('super-secret-db-pass', TEST_KEY_HEX);
  const tokenB = await encryptVaultText('prod-api-key-999', TEST_KEY_HEX);

  const markdownWithTokens = `## Configuration Summary
- Database Password: \`${tokenA}\`
- API Key: \`${tokenB}\`
- Public Note: Visible to everyone.
`;
  assert.ok(!isVaultArmored(markdownWithTokens) && containsVaultArmored(markdownWithTokens));

  // 1. Unlocked -> tokens replaced with plaintext
  const unlocked = await decryptEmbeddedVaultTokens(markdownWithTokens, TEST_KEY_HEX);
  assert.ok(
    unlocked.includes('Database Password: `super-secret-db-pass`'),
    'Token A must be decrypted in markdown',
  );
  assert.ok(
    unlocked.includes('API Key: `prod-api-key-999`'),
    'Token B must be decrypted in markdown',
  );
  assert.ok(
    unlocked.includes('Public Note: Visible to everyone.'),
    'Unencrypted text must be preserved',
  );
  assert.ok(!unlocked.includes('vault:v2:7e57000000000001:e1:'), 'No raw vault ciphertext should remain');

  // 2. Locked -> tokens masked
  const locked = maskVaultArmored(markdownWithTokens);
  assert.ok(
    locked.includes(`Database Password: \`${VAULT_MASK_PLACEHOLDER}\``),
    'Token A must be shielded when locked',
  );
  assert.ok(
    locked.includes(`API Key: \`${VAULT_MASK_PLACEHOLDER}\``),
    'Token B must be shielded when locked',
  );
  assert.ok(!locked.includes('vault:v2:7e57000000000001:e1:'), 'Ciphertext must be completely shielded');
});

test('DecryptedMarkdown passes through plain markdown unchanged', async () => {
  const plain = '# Normal Markdown\n\nNo encryption used here.';
  assert.equal(containsVaultArmored(plain), false);
  assert.equal(maskVaultArmored(plain), plain);
});
