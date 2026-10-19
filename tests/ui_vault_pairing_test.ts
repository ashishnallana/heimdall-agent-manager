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
  generatePairSalt,
  isPairSalt,
  normalizePairCode,
  pairApproveMac,
  pairBridgePayload,
  pairCodeSymbols,
  pairHubOrigin,
  pairKeyMac,
  pairStretchSalt,
  PAIR_STRETCH_ITERATIONS,
  verifyPairApproveMac,
  verifyPairKeyMac,
  type PairContext,
} from '../src/ui/utils/vaultPairing.ts';

const here = path.dirname(fileURLToPath(import.meta.url));
const v = JSON.parse(fs.readFileSync(path.join(here, 'fixtures/vault_v2_vectors.json'), 'utf8')).pairing;
const browserCtx: PairContext = { kind: 'browser', userId: v.browser.user_id, hubOrigin: v.hub_origin, pairSalt: v.browser.pair_salt };
const bridgeCtx: PairContext = { kind: 'bridge', userId: '', hubOrigin: v.hub_origin, pairSalt: v.bridge.pair_salt };

test('pairing vectors: code, stretch, lookup, key_mac, pair_mac', async () => {
  assert.equal(PAIR_STRETCH_ITERATIONS, v.iterations);
  assert.equal(normalizePairCode(v.code_typed), v.code);
  for (const bad of v.invalid_codes) assert.equal(pairCodeSymbols(bad), null, bad);
  for (const c of v.invalid_contexts) {
    assert.throws(() => pairStretchSalt({ kind: c.kind, userId: c.user_id, hubOrigin: c.hub_origin, pairSalt: c.pair_salt }), JSON.stringify(c));
  }
  assert.equal(pairStretchSalt(browserCtx), v.browser.stretch_salt);
  assert.equal(pairStretchSalt(bridgeCtx), v.bridge.stretch_salt);
  const b = await derivePairKeys(v.code_typed, browserCtx);
  assert.equal(b.lookup, v.browser.lookup);
  assert.equal(await pairKeyMac(b, 'browser', v.browser.register_statement), v.browser.key_mac);
  const r = await derivePairKeys(v.code, bridgeCtx);
  assert.equal(r.lookup, v.bridge.lookup);
  const payload = pairBridgePayload(v.bridge.identity_public_key, v.bridge.ecdh_public_key, v.bridge.code_challenge);
  assert.equal(await pairKeyMac(r, 'bridge', payload), v.bridge.key_mac);
  assert.ok(await verifyPairKeyMac(r, 'bridge', payload, v.bridge.key_mac));
  assert.equal(await pairApproveMac(r, v.bridge.approval_statement, v.bridge.root_sign_pub), v.bridge.approve_mac);
  assert.ok(await verifyPairApproveMac(r, v.bridge.approval_statement, v.bridge.root_sign_pub, v.bridge.approve_mac));
});

test('pairing MACs bind kind, keys, root, salt, origin and code', async () => {
  const r = await derivePairKeys(v.code, bridgeCtx);
  const payload = pairBridgePayload(v.bridge.identity_public_key, v.bridge.ecdh_public_key, v.bridge.code_challenge);
  // The hub swapped the bridge's keys: approver refuses. A bridge key_mac never passes as a browser one.
  assert.equal(await verifyPairKeyMac(r, 'bridge', payload.replace(v.bridge.code_challenge, 'other-challenge'), v.bridge.key_mac), false);
  assert.equal(await verifyPairKeyMac(r, 'browser', payload, v.bridge.key_mac), false);
  // A substituted root fails, as does a code the user never typed, another salt or another hub.
  assert.equal(await verifyPairApproveMac(r, v.bridge.approval_statement, v.bridge.identity_public_key, v.bridge.approve_mac), false);
  assert.equal(await verifyPairApproveMac(r, v.bridge.approval_statement, v.bridge.root_sign_pub, ''), false);
  for (const [code, ctx] of [
    ['AAAA-AAAA-AAAA-AA', bridgeCtx],
    [v.code, { ...bridgeCtx, pairSalt: v.browser.pair_salt }],
    [v.code, { ...bridgeCtx, hubOrigin: 'https://other-hub.example.test:443' }],
  ] as const) {
    const other = await derivePairKeys(code, ctx);
    assert.equal(await verifyPairApproveMac(other, v.bridge.approval_statement, v.bridge.root_sign_pub, v.bridge.approve_mac), false);
  }
  assert.match(generatePairCode(), /^[A-Z2-7]{4}-[A-Z2-7]{4}-[A-Z2-7]{4}-[A-Z2-7]{2}$/);
  assert.ok(isPairSalt(generatePairSalt()));
});

test('pairing hub origin is canonical (ham-bridge computes the same from --hub)', () => {
  assert.equal(pairHubOrigin('https://Hub.Example.TEST/'), 'https://hub.example.test:443');
  assert.equal(pairHubOrigin('https://hub.example.test.:8443/api/v1/'), 'https://hub.example.test:8443');
  assert.equal(pairHubOrigin('http://127.0.0.1:8080/x'), 'http://127.0.0.1:8080');
  assert.equal(pairHubOrigin('http://localhost'), 'http://localhost:80');
  assert.equal(pairHubOrigin('http://[::1]:9/'), 'http://[::1]:9');
  assert.throws(() => pairHubOrigin('ftp://hub.example.test/'));
});
