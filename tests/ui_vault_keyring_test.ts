// Shared v2 vectors on the TS side: HKR1 keyring, canonical statements and signature
// objects, algorithm allowlists, keyring wraps and bridge unseal v2 (including the
// signed-ephemeral-key gate). The Odin twin is src/lib/vault/vault_test.odin.
//
// RUN: node --test tests/ui_vault_keyring_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { importKeyring, parseKeyringBytes, serializeKeyringBytes } from '../src/ui/utils/vaultKeyring.ts';
import {
  SIGN_ALG_ECDSA_P256_SHA256,
  bridgeUnsealKeyCanonical,
  epochCommit,
  kindPolicy,
  openKeyringWrap,
  signAlgFromId,
  statementCanonical,
  verifySignature,
  wrapAlgFromId,
  wrapCanonicalJson,
  wrapSha256,
  type KeyringWrap,
  type Statement,
} from '../src/ui/utils/vaultStatements.ts';
import { buildUnsealAad, prepareUnsealPayload, type BridgeUnsealTarget } from '../src/ui/utils/vaultBridgeUnseal.ts';

const V = JSON.parse(fs.readFileSync(path.resolve(path.dirname(fileURLToPath(import.meta.url)), 'fixtures/vault_v2_vectors.json'), 'utf8'));
const hex = (s: string) => Uint8Array.from(Buffer.from(s, 'hex'));
const toHex = (b: Uint8Array) => Buffer.from(b).toString('hex');
const b64u = (b: Uint8Array) => Buffer.from(b).toString('base64url');
const utf8 = new TextEncoder();

/** Import a raw P-256 scalar (+ its public point) as a WebCrypto private key via JWK. */
async function importP256Private(dHex: string, pubHex: string, name: 'ECDH' | 'ECDSA'): Promise<CryptoKey> {
  const pub = hex(pubHex);
  return crypto.subtle.importKey(
    'jwk',
    { kty: 'EC', crv: 'P-256', d: b64u(hex(dHex)), x: b64u(pub.subarray(1, 33)), y: b64u(pub.subarray(33, 65)), ext: true },
    { name, namedCurve: 'P-256' },
    false,
    name === 'ECDH' ? ['deriveBits'] : ['sign'],
  );
}

test('keyring vector parses, serializes identically and imports non-extractable keys', async () => {
  const k = V.keyring;
  const parsed = parseKeyringBytes(hex(k.hex), k.user_id);
  assert.equal(parsed.userId, k.user_id);
  assert.equal(parsed.currentEpoch, k.current_epoch);
  assert.deepEqual(parsed.entries.map((e) => [e.epoch, toHex(e.key)]), k.entries.map((e: any) => [e.epoch, e.key]));
  assert.equal(toHex(serializeKeyringBytes(parsed)), k.hex);
  assert.equal(parseKeyringBytes(hex(k.max_64_hex)).entries.length, 64);
  const bytes = hex(k.hex);
  const kr = await importKeyring(bytes);
  assert.ok(bytes.every((b) => b === 0), 'import zeroes the input bytes');
  assert.equal(kr.keys.get(2)!.extractable, false);
});

test('keyring negatives are rejected', () => {
  for (const c of V.keyring.negative) {
    assert.throws(() => parseKeyringBytes(hex(c.hex), c.expected_user_id), /Invalid vault keyring/, c.name);
  }
});

test('statement canonical bytes and signature vector; tampering and bad values fail', async () => {
  const s = V.statement;
  const canonical = statementCanonical(s.fields as Statement);
  assert.equal(canonical, s.canonical);
  assert.equal(await verifySignature(SIGN_ALG_ECDSA_P256_SHA256, s.issuer_public_key, utf8.encode(canonical), s.signature_object), true);
  assert.equal(await verifySignature(SIGN_ALG_ECDSA_P256_SHA256, s.issuer_public_key, utf8.encode(`${canonical}x`), s.signature_object), false);
  for (const bad of s.invalid_signature_objects) {
    assert.equal(await verifySignature(SIGN_ALG_ECDSA_P256_SHA256, s.issuer_public_key, utf8.encode(canonical), bad), false, bad);
  }
  for (const c of s.invalid_values) {
    assert.throws(() => statementCanonical({ ...s.fields, [c.field]: c.value }), c.name);
  }
  const ec = V.epoch_commit;
  assert.equal(toHex(await epochCommit(hex(ec.key), ec.user_id, ec.epoch)), ec.commit);
});

test('unknown algorithm ids are rejected by every allowlist and dispatch', async () => {
  const a = V.algorithms;
  for (const id of a.sign) assert.ok(signAlgFromId(id));
  for (const id of a.wrap) assert.ok(wrapAlgFromId(id));
  const s = V.statement;
  for (const id of a.unknown_sign) {
    assert.equal(signAlgFromId(id), null);
    assert.equal(await verifySignature(id, s.issuer_public_key, utf8.encode(s.canonical), s.signature_object), false);
  }
  const w = V.wrap;
  const recipient = await importP256Private(w.recipient_ecdh_private_key, w.recipient_ecdh_public_key, 'ECDH');
  for (const id of a.unknown_wrap) {
    assert.equal(wrapAlgFromId(id), null);
    const bad: KeyringWrap = { ...w.json, alg: id };
    assert.throws(() => wrapCanonicalJson(bad));
    await assert.rejects(openKeyringWrap(bad, w.user_id, recipient), /unknown wrap alg/);
  }
  assert.equal(kindPolicy('browser').canApprove, true);
  assert.equal(kindPolicy('recovery').canApprove, true);
  assert.equal(kindPolicy('bridge').canApprove, false);
  assert.equal(kindPolicy('passkey').canApprove, false);
});

test('keyring wrap vector: canonical JSON, sha256, unwrap; AAD binds recipient/version/user', async () => {
  const w = V.wrap;
  const wrap: KeyringWrap = w.json;
  assert.equal(wrapCanonicalJson(wrap), w.canonical_json);
  assert.equal(await wrapSha256(wrap), w.wrap_sha256);
  const recipient = await importP256Private(w.recipient_ecdh_private_key, w.recipient_ecdh_public_key, 'ECDH');
  const parsed = await openKeyringWrap(wrap, w.user_id, recipient);
  assert.equal(toHex(serializeKeyringBytes(parsed)), w.keyring_hex);
  await assert.rejects(openKeyringWrap({ ...wrap, directory_version: wrap.directory_version + 1 }, w.user_id, recipient));
  await assert.rejects(openKeyringWrap({ ...wrap, recipient_device_id: 'dev_other' }, w.user_id, recipient));
  await assert.rejects(openKeyringWrap(wrap, 'usr_other', recipient));
});

function vectorTarget(overrides: Partial<BridgeUnsealTarget> = {}): BridgeUnsealTarget {
  const b = V.bridge_unseal_key;
  return {
    bridgeId: b.bridge_id,
    publicKey: b.ecdh_public_key,
    bootId: b.boot_id,
    unsealKeySignature: JSON.parse(b.signature_object),
    identityPublicKey: b.identity_public_key,
    ...overrides,
  };
}

test('bridge unseal-key statement vector', async () => {
  const b = V.bridge_unseal_key;
  assert.equal(bridgeUnsealKeyCanonical(b.bridge_id, b.ecdh_public_key, b.boot_id), b.canonical);
  assert.equal(await verifySignature(SIGN_ALG_ECDSA_P256_SHA256, b.identity_public_key, utf8.encode(b.canonical), b.signature_object), true);
});

test('unseal v2 vector: fixed inputs reproduce ciphertext and tag', async () => {
  const u = V.unseal_v2;
  assert.equal(new TextDecoder().decode(buildUnsealAad(u.bridge_id, u.timestamp, u.nonce, u.current_epoch)), u.aad);
  const clientPrivate = await importP256Private(u.client_private_key, u.client_public_key, 'ECDH');
  const clientPublic = await crypto.subtle.importKey('raw', hex(u.client_public_key), { name: 'ECDH', namedCurve: 'P-256' }, true, []);
  const bytes = hex(u.keyring_hex);
  const payload = await prepareUnsealPayload(vectorTarget(), bytes, V.bridge_chain.proof as any, {
    timestamp: u.timestamp,
    nonce: u.nonce,
    iv: hex(u.iv),
    clientKeyPair: { privateKey: clientPrivate, publicKey: clientPublic },
  });
  assert.ok(bytes.every((x) => x === 0), 'keyring bytes are zeroed');
  assert.equal(payload.ciphertext, u.ciphertext);
  assert.equal(payload.tag, u.tag);
  assert.equal(payload.client_public_key, u.client_public_key);
  assert.equal(payload.format, 'keyring-v1');
  assert.equal(payload.current_epoch, 2);
  assert.deepEqual(payload.unseal_key_signature, JSON.parse(V.bridge_unseal_key.signature_object));
  assert.equal(payload.bridge_identity_public_key, V.bridge_unseal_key.identity_public_key);
});

test('unseal refuses an unsigned, wrongly signed or mismatched ephemeral key', async () => {
  const b = V.bridge_unseal_key;
  const cases: Array<[string, Partial<BridgeUnsealTarget>]> = [
    ['unsigned', { unsealKeySignature: '' }],
    ['signed by another identity', { unsealKeySignature: b.other_identity_signature_object }],
    ['identity key mismatch', { identityPublicKey: b.other_identity_public_key }],
    ['different ephemeral key', { publicKey: V.unseal_v2.client_public_key }],
    ['different boot id', { bootId: '00'.repeat(16) }],
    ['different bridge id', { bridgeId: 'brg_other' }],
    ['unknown identity alg', { identitySignAlg: 'webauthn-es256' }],
  ];
  for (const [name, override] of cases) {
    const bytes = hex(V.keyring.hex);
    await assert.rejects(prepareUnsealPayload(vectorTarget(override), bytes), /refused|Invalid bridge public key/, name);
    assert.ok(bytes.every((x) => x === 0), `${name}: keyring bytes zeroed even on refusal`);
  }
  // A raw 32-byte key is not a keyring.
  await assert.rejects(prepareUnsealPayload(vectorTarget(), hex(V.epoch_keys['1']), V.bridge_chain.proof as any), /Invalid vault keyring/);
});
