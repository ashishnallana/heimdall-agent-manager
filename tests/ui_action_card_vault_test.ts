// Action cards never surface vault ciphertext: the in-chat card's approve/reject feedback,
// the Cards/Action-items toasts and op labels resolve sealed card fields to plaintext or a
// safe fallback (screenshot art_18dffed611afa51c: `[Action Approved] Action crd_… (vault:v2:…)`).
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_action_card_vault_test.ts

import { keyringFromHex } from './helpers/vaultTestKeyring.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { encryptVaultText } from '../src/ui/utils/vaultCrypto.ts';
import { resolveCardTitle } from '../src/ui/utils/vaultCardOps.ts';
import { buildActionFeedback } from '../src/ui/components/chat/actionFeedback.ts';
import { formatOpLabel } from '../src/ui/api/endpoints/cards.ts';

const KEY_HEX = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const OTHER_KEY_HEX = 'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';
const ARMOR = 'vault:v2:';

test('armored card title resolves to plaintext with the vault key', async () => {
  const key = await keyringFromHex(KEY_HEX);
  const title = await encryptVaultText('Apply project description', key);
  assert.ok(title.startsWith(ARMOR));
  assert.equal(await resolveCardTitle(title, 'untitled', key), 'Apply project description');
});

test('locked or wrong-key vault falls back, never returns ciphertext', async () => {
  const key = await keyringFromHex(KEY_HEX);
  const other = await keyringFromHex(OTHER_KEY_HEX);
  const title = await encryptVaultText('secret plan', key);
  assert.equal(await resolveCardTitle(title, 'untitled', null), 'untitled');
  assert.equal(await resolveCardTitle(title, 'untitled', other), 'untitled');
});

test('plain and missing titles', async () => {
  assert.equal(await resolveCardTitle('Plain title', 'untitled', null), 'Plain title');
  assert.equal(await resolveCardTitle('', 'untitled', null), 'untitled');
  assert.equal(await resolveCardTitle(undefined, 'untitled', null), 'untitled');
});

test('approve/reject feedback carries the card id and decrypted title, no ciphertext', async () => {
  const key = await keyringFromHex(KEY_HEX);
  const sealed = await encryptVaultText('Apply project description', key);
  const approved = buildActionFeedback('approved', 'crd_1', await resolveCardTitle(sealed, 'untitled', key));
  assert.equal(approved, '[Action Approved] Action crd_1 (Apply project description) was approved by user');
  const rejected = buildActionFeedback('rejected', 'crd_1', await resolveCardTitle(sealed, 'untitled', null), '  too broad ');
  assert.equal(rejected, '[Action Rejected] Action crd_1 (untitled) was rejected by user: too broad');
  for (const body of [approved, rejected]) assert.ok(!body.includes(ARMOR), body);
});

test('op labels mask vault tokens and can omit record ids', async () => {
  const key = await keyringFromHex(KEY_HEX);
  const sealed = await encryptVaultText('Secret memory', key);
  const create = formatOpLabel({ op: 'memory.create', args: { title: sealed, type: 'fact' } } as any);
  assert.ok(!create.includes(ARMOR), create);
  const labelled = formatOpLabel({ op: 'project.update', label: `Rename to ${sealed}` } as any);
  assert.ok(!labelled.includes(ARMOR), labelled);

  const op = { op: 'memory.approve', args: { memory_id: 'mem_123' } } as any;
  assert.equal(formatOpLabel(op), 'Approve memory proposal mem_123');
  assert.equal(formatOpLabel(op, { withIds: false }), 'Approve memory proposal');
  assert.equal(formatOpLabel({ op: 'memory.update', args: { memory_id: 'mem_1' } } as any, { withIds: false }), 'Update memory');
});
