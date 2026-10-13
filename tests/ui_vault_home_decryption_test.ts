// REQ-VAULT-HOME-CHAINS, REQ-VAULT-HOME-ACTIONS, REQ-VAULT-CARDS-PANEL, REQ-VAULT-PINNED-SIDEBAR, REQ-VAULT-TASKCHAINS-PAGE
// Comprehensive Vault decryption unit test suite covering Home page, Action cards, Task chains,
// and Sidebar pinned avatars.
//
// RUN: node --test tests/ui_vault_home_decryption_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  isVaultArmored,
  containsVaultArmored,
  encryptVaultText,
  decryptVaultText,
  decryptEmbeddedVaultTokens,
} from '../src/ui/utils/vaultContent.ts';
import {
  chainAvatarInitials,
  resolveCollapsedPinnedChainAvatar,
} from '../src/ui/components/chains/chainInitials.ts';
import {
  resolveDecryptedMarkdownContent,
} from '../src/ui/components/vault/vaultTextHelper.ts';

const TEST_KEY_HEX = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

// -----------------------------------------------------------------------------
// Section 2: chainAvatarInitials Unit Tests
// -----------------------------------------------------------------------------

test('chainAvatarInitials returns "TC" (and never "VA") for vault-armored strings', async () => {
  const titles = [
    'Refactor Authentication Protocol',
    'Vault Zero Knowledge Architecture',
    'Secret Project #42',
    'Vanguard Operation Alpha',
  ];

  for (const plain of titles) {
    const armored = await encryptVaultText(plain, TEST_KEY_HEX);
    assert.ok(isVaultArmored(armored), `Encrypted title must be vault armored: ${armored}`);

    const initials = chainAvatarInitials(armored);
    assert.equal(
      initials,
      'TC',
      `Initials for vault armored string must be "TC", got: "${initials}"`,
    );
    assert.notEqual(
      initials,
      'VA',
      'Initials for vault armored string must NEVER be "VA"',
    );
  }
});

test('chainAvatarInitials correctly extracts initials from human-readable plaintext', () => {
  // Two or more words -> first letters of first two words
  assert.equal(chainAvatarInitials('Payment Gateway'), 'PG');
  assert.equal(chainAvatarInitials('refactor auth service'), 'RA');
  assert.equal(chainAvatarInitials('Heimdall Hub Rewrite v2'), 'HH');

  // Single word -> first two letters uppercase
  assert.equal(chainAvatarInitials('Vanguard'), 'VA');
  assert.equal(chainAvatarInitials('Core'), 'CO');
  assert.equal(chainAvatarInitials('single'), 'SI');

  // Single character -> 1 letter uppercase
  assert.equal(chainAvatarInitials('x'), 'X');

  // Empty or whitespace -> "TC"
  assert.equal(chainAvatarInitials(''), 'TC');
  assert.equal(chainAvatarInitials('   '), 'TC');
  assert.equal(chainAvatarInitials(null as any), 'TC');
  assert.equal(chainAvatarInitials(undefined as any), 'TC');
});

// -----------------------------------------------------------------------------
// Section 3: CollapsedPinnedChainItem Avatar Logic Unit Tests
// -----------------------------------------------------------------------------

test('resolveCollapsedPinnedChainAvatar computes initials from decrypted title when unlocked and shows lock icon when locked', async () => {
  const rawTitle = 'Zero Knowledge Vault Integration';
  const armoredTitle = await encryptVaultText(rawTitle, TEST_KEY_HEX);

  // Scenario 1: Vault unlocked -> decrypts to "Zero Knowledge Vault Integration"
  const unlockedAvatar = resolveCollapsedPinnedChainAvatar(
    armoredTitle,
    rawTitle,
    false, // isLocked = false
  );
  assert.equal(unlockedAvatar.isLocked, false);
  assert.equal(unlockedAvatar.initials, 'ZK', 'Must compute initials from decrypted text');
  assert.equal(unlockedAvatar.tooltip, rawTitle, 'Tooltip must show decrypted title');

  // Scenario 2: Vault locked -> armored text is locked
  const lockedAvatar = resolveCollapsedPinnedChainAvatar(
    armoredTitle,
    '[🔒 Encrypted]',
    true, // isLocked = true
  );
  assert.equal(lockedAvatar.isLocked, true);
  assert.equal(lockedAvatar.initials, '🔒', 'Must display lock icon 🔒 when locked');
  assert.equal(lockedAvatar.tooltip, '[🔒 Encrypted]', 'Tooltip must show encrypted placeholder when locked');

  // Scenario 3: Plain unencrypted chain -> passthrough
  const plainTitle = 'Infrastructure Setup';
  const plainAvatar = resolveCollapsedPinnedChainAvatar(
    plainTitle,
    plainTitle,
    false,
  );
  assert.equal(plainAvatar.isLocked, false);
  assert.equal(plainAvatar.initials, 'IS');
  assert.equal(plainAvatar.tooltip, plainTitle);
});

// -----------------------------------------------------------------------------
// Section 4: DecryptedMarkdown Unit Tests
// -----------------------------------------------------------------------------

test('DecryptedMarkdown properly decrypts pure armored markdown when unlocked', async () => {
  const secretMarkdown = `### Sensitive Operational Procedure
1. Step One: Connect to isolated gateway.
2. Step Two: Verify SHA256 checksum \`abcdef123456\`.
`;

  const armored = await encryptVaultText(secretMarkdown, TEST_KEY_HEX);
  assert.ok(isVaultArmored(armored));

  // When unlocked
  const unlocked = await resolveDecryptedMarkdownContent(armored, TEST_KEY_HEX, true);
  assert.equal(unlocked.isLocked, false);
  assert.equal(unlocked.text, secretMarkdown, 'Must decrypt cleanly back to markdown source');

  // When locked
  const locked = await resolveDecryptedMarkdownContent(armored, null, false);
  assert.equal(locked.isLocked, true);
  assert.equal(locked.text, '[🔒 Encrypted]', 'Must mask armored markdown when locked');
});

test('DecryptedMarkdown properly decrypts embedded vault tokens before markdown rendering', async () => {
  const tokenA = await encryptVaultText('super-secret-db-pass', TEST_KEY_HEX);
  const tokenB = await encryptVaultText('prod-api-key-999', TEST_KEY_HEX);

  const markdownWithTokens = `## Configuration Summary
- Database Password: \`${tokenA}\`
- API Key: \`${tokenB}\`
- Public Note: Visible to everyone.
`;

  // 1. Unlocked resolution -> tokens replaced with plaintext
  const unlocked = await resolveDecryptedMarkdownContent(markdownWithTokens, TEST_KEY_HEX, true);
  assert.equal(unlocked.isLocked, false);
  assert.ok(
    unlocked.text.includes('Database Password: `super-secret-db-pass`'),
    'Token A must be decrypted in markdown',
  );
  assert.ok(
    unlocked.text.includes('API Key: `prod-api-key-999`'),
    'Token B must be decrypted in markdown',
  );
  assert.ok(
    unlocked.text.includes('Public Note: Visible to everyone.'),
    'Unencrypted text must be preserved',
  );
  assert.ok(!unlocked.text.includes('vault:v1:'), 'No raw vault ciphertext should remain');

  // 2. Locked resolution -> tokens masked with [🔒 Encrypted]
  const locked = await resolveDecryptedMarkdownContent(markdownWithTokens, null, false);
  assert.equal(locked.isLocked, true);
  assert.ok(
    locked.text.includes('Database Password: `[🔒 Encrypted]`'),
    'Token A must be shielded with [🔒 Encrypted] when locked',
  );
  assert.ok(
    locked.text.includes('API Key: `[🔒 Encrypted]`'),
    'Token B must be shielded with [🔒 Encrypted] when locked',
  );
  assert.ok(!locked.text.includes('vault:v1:'), 'Ciphertext must be completely shielded');
});

test('DecryptedMarkdown passes through plain markdown unchanged', async () => {
  const plain = '# Normal Markdown\n\nNo encryption used here.';
  const res = await resolveDecryptedMarkdownContent(plain, null, false);
  assert.equal(res.isLocked, false);
  assert.equal(res.text, plain);
});
