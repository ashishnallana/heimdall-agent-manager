// Hub-blind pairing on the TS side, pinned by the shared `pairing` vectors (the Odin
// twin is test_pairing_vectors in src/lib/vault/vault_test.odin).
//
// RUN: node --test tests/ui_vault_pairing_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  derivePairKeys,
  generatePairCode,
  normalizePairCode,
  pairApproveMac,
  pairBridgePayload,
  pairCodeSymbols,
  pairKeyMac,
  verifyPairApproveMac,
  verifyPairKeyMac,
} from '../src/ui/utils/vaultPairing.ts';

const here = path.dirname(fileURLToPath(import.meta.url));
const v = JSON.parse(fs.readFileSync(path.join(here, 'fixtures/vault_v2_vectors.json'), 'utf8')).pairing;

test('pairing vectors: code, lookup, key_mac, pair_mac', async () => {
  assert.equal(normalizePairCode(v.code_typed), v.code);
  for (const bad of v.invalid_codes) assert.equal(pairCodeSymbols(bad), null, bad);
  const keys = await derivePairKeys(v.code_typed);
  assert.equal(keys.lookup, v.lookup);
  assert.equal(await pairKeyMac(keys, 'browser', v.browser_register_statement), v.browser_key_mac);
  const payload = pairBridgePayload(v.bridge_identity_public_key, v.bridge_ecdh_public_key, v.bridge_code_challenge);
  assert.equal(await pairKeyMac(keys, 'bridge', payload), v.bridge_key_mac);
  assert.ok(await verifyPairKeyMac(keys, 'bridge', payload, v.bridge_key_mac));
  assert.equal(await pairApproveMac(keys, v.approval_statement, v.root_sign_pub), v.approve_mac);
  assert.ok(await verifyPairApproveMac(keys, v.approval_statement, v.root_sign_pub, v.approve_mac));
});

test('pairing MACs bind kind, keys, root and code', async () => {
  const keys = await derivePairKeys(v.code);
  // The hub swapped the device's register statement (other keys): approver refuses.
  assert.equal(await verifyPairKeyMac(keys, 'browser', v.browser_register_statement.replace('type=register', 'type=registe'), v.browser_key_mac), false);
  // A browser key_mac never passes as a bridge one.
  assert.equal(await verifyPairKeyMac(keys, 'bridge', v.browser_register_statement, v.browser_key_mac), false);
  // A substituted root fails, as does a code the user never typed.
  assert.equal(await verifyPairApproveMac(keys, v.approval_statement, v.bridge_identity_public_key, v.approve_mac), false);
  const other = await derivePairKeys('AAAA-AAAA-AAAA');
  assert.equal(await verifyPairApproveMac(other, v.approval_statement, v.root_sign_pub, v.approve_mac), false);
  assert.equal(await verifyPairApproveMac(keys, v.approval_statement, v.root_sign_pub, ''), false);
  const fresh = generatePairCode();
  assert.match(fresh, /^[A-Z2-7]{4}-[A-Z2-7]{4}-[A-Z2-7]{4}$/);
});
