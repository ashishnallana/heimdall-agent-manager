#!/usr/bin/env node
// Deterministic generator for tests/fixtures/vault_v2_vectors.json.
//
// Every value is derived from fixed seeds, so re-running this script reproduces the
// committed file byte for byte (`--check` exits non-zero when it does not). ECDSA
// signatures use RFC 6979 deterministic nonces, implemented here with BigInt because
// node:crypto only offers randomized ECDSA. Every signature is cross-checked against
// node:crypto before it is written, and the Odin suite re-signs with core:crypto/ecdsa
// (deterministic mode) and compares the bytes.
//
// The formats are specified in docs/plans/passwordless-vault.md §1. Consumers:
//   - tests/ui_vault_v2_envelope_test.ts, tests/ui_vault_keyring_test.ts (TS / WebCrypto)
//   - src/lib/vault/vault_test.odin (Odin, via #load)
//
// Usage: node tools/vault_vectors/gen_vault_v2_vectors.mjs [--check]

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const outPath = path.resolve(here, '../../tests/fixtures/vault_v2_vectors.json');

// ── deterministic byte sources ────────────────────────────────────────────────
const seeded = (label, n) => {
  const out = Buffer.alloc(n);
  let off = 0;
  for (let ctr = 0; off < n; ctr += 1) {
    const block = crypto.createHash('sha256').update(`heimdall-vault-v2-vectors|${label}|${ctr}`).digest();
    block.copy(out, off, 0, Math.min(32, n - off));
    off += 32;
  }
  return out;
};
const hex = (b) => Buffer.from(b).toString('hex');
const b64 = (b) => Buffer.from(b).toString('base64');
const utf8 = (s) => Buffer.from(s, 'utf8');
const sha256 = (b) => crypto.createHash('sha256').update(b).digest();
const hmac256 = (key, msg) => crypto.createHmac('sha256', key).update(msg).digest();
const hkdf = (ikm, salt, info, len = 32) => Buffer.from(crypto.hkdfSync('sha256', ikm, salt, info, len));

const gcmSeal = (key, iv, aad, plaintext) => {
  const c = crypto.createCipheriv('aes-256-gcm', key, iv);
  if (aad) c.setAAD(aad);
  const ct = Buffer.concat([c.update(plaintext), c.final()]);
  return { ct, tag: c.getAuthTag() };
};

// ── P-256 with BigInt (only what signing and public-key derivation need) ─────
const P = 0xffffffff00000001000000000000000000000000ffffffffffffffffffffffffn;
const N = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551n;
const A = P - 3n;
const G = [
  0x6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296n,
  0x4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5n,
];
const mod = (a, m) => ((a % m) + m) % m;
const inv = (a, m) => {
  let [r0, r1, s0, s1] = [mod(a, m), m, 1n, 0n];
  while (r1 !== 0n) {
    const q = r0 / r1;
    [r0, r1] = [r1, r0 - q * r1];
    [s0, s1] = [s1, s0 - q * s1];
  }
  if (r0 !== 1n) throw new Error('not invertible');
  return mod(s0, m);
};
const ptAdd = (p1, p2) => {
  if (p1 === null) return p2;
  if (p2 === null) return p1;
  const [x1, y1] = p1;
  const [x2, y2] = p2;
  if (x1 === x2 && mod(y1 + y2, P) === 0n) return null;
  const l = x1 === x2 && y1 === y2
    ? mod((3n * x1 * x1 + A) * inv(2n * y1, P), P)
    : mod((y2 - y1) * inv(x2 - x1, P), P);
  const x3 = mod(l * l - x1 - x2, P);
  return [x3, mod(l * (x1 - x3) - y1, P)];
};
const ptMul = (k, pt) => {
  let acc = null;
  let add = pt;
  for (let e = k; e > 0n; e >>= 1n) {
    if (e & 1n) acc = ptAdd(acc, add);
    add = ptAdd(add, add);
  }
  return acc;
};
const toBig = (b) => BigInt(`0x${hex(b) || '0'}`);
const fromBig = (x, len = 32) => Buffer.from(x.toString(16).padStart(len * 2, '0'), 'hex');
const pubRaw = (d) => {
  const [x, y] = ptMul(d, G);
  return Buffer.concat([Buffer.from([4]), fromBig(x), fromBig(y)]);
};
// A private scalar in [1, n-1] from a seed label.
const scalar = (label) => {
  for (let i = 0; ; i += 1) {
    const d = toBig(seeded(`${label}#${i}`, 32));
    if (d > 0n && d < N) return d;
  }
};

// RFC 6979 §3.2 with HMAC-SHA256, qlen = 256.
const signRfc6979 = (d, msg) => {
  const h1 = sha256(msg);
  const x = fromBig(d);
  const h1o = fromBig(mod(toBig(h1), N));
  let V = Buffer.alloc(32, 1);
  let K = Buffer.alloc(32, 0);
  K = hmac256(K, Buffer.concat([V, Buffer.from([0]), x, h1o]));
  V = hmac256(K, V);
  K = hmac256(K, Buffer.concat([V, Buffer.from([1]), x, h1o]));
  V = hmac256(K, V);
  const z = mod(toBig(h1), N);
  for (;;) {
    V = hmac256(K, V);
    const k = toBig(V);
    if (k >= 1n && k < N) {
      const r = mod(ptMul(k, G)[0], N);
      if (r !== 0n) {
        const s = mod(inv(k, N) * (z + r * d), N);
        if (s !== 0n) return Buffer.concat([fromBig(r), fromBig(s)]);
      }
    }
    K = hmac256(K, Buffer.concat([V, Buffer.from([0])]));
    V = hmac256(K, V);
  }
};

const spkiFromRaw = (raw) => crypto.createPublicKey({
  key: Buffer.concat([Buffer.from('3059301306072a8648ce3d020106082a8648ce3d030107034200', 'hex'), raw]),
  format: 'der',
  type: 'spki',
});
const verifyNode = (raw, msg, sig) => crypto.verify('sha256', msg, { key: spkiFromRaw(raw), dsaEncoding: 'ieee-p1363' }, sig);
const signChecked = (d, msg) => {
  const sig = signRfc6979(d, msg);
  if (!verifyNode(pubRaw(d), msg, sig)) throw new Error('self-check: RFC 6979 signature did not verify');
  return sig;
};
const ecdhShared = (d, peerRaw) => {
  const e = crypto.createECDH('prime256v1');
  e.setPrivateKey(fromBig(d));
  return e.computeSecret(peerRaw);
};

// ── formats ───────────────────────────────────────────────────────────────────
const u16be = (n) => { const b = Buffer.alloc(2); b.writeUInt16BE(n); return b; };
const u32be = (n) => { const b = Buffer.alloc(4); b.writeUInt32BE(n); return b; };

const keyringBytes = (userId, currentEpoch, entries) => Buffer.concat([
  Buffer.from('HKR1', 'ascii'),
  u16be(utf8(userId).length), utf8(userId),
  u32be(currentEpoch),
  u16be(entries.length),
  ...entries.flatMap(([epoch, key]) => [u32be(epoch), key]),
]);

const envelopeAad = (epoch) => utf8(`heimdall-vault-v2|e${epoch}`);
const envelopeToken = (epoch, key, nonce, plaintext) => {
  const { ct, tag } = gcmSeal(key, nonce, envelopeAad(epoch), plaintext);
  return `vault:v2:e${epoch}:${b64(Buffer.concat([nonce, tag, ct]))}`;
};

const STATEMENT_FIELDS = [
  'type', 'user_id', 'seq', 'prev_hash', 'issuer_device_id', 'issued_at_ms',
  'subject_device_id', 'subject_kind', 'subject_sign_pub', 'subject_ecdh_pub',
  'subject_sign_alg', 'subject_wrap_alg', 'subject_label_b64', 'epoch', 'epoch_commit', 'wrap_sha256',
];
const statementCanonical = (fields) => ['heimdall-vault-statement/v2',
  ...STATEMENT_FIELDS.map((k) => `${k}=${fields[k] ?? ''}`)].join('\n');

const epochCommit = (key, userId, epoch) => hmac256(key, utf8(`heimdall-epoch-commit|${userId}|${epoch}`));

const SIGN_ALG = 'ecdsa-p256-sha256';
const WRAP_ALG = 'ecdh-p256-hkdf-sha256-aes256gcm';
// Signature objects are serialized with this exact key order and no whitespace.
const sigObject = (sig) => `{"alg":"${SIGN_ALG}","sig":"${hex(sig)}"}`;
const wrapCanonicalJson = (w) => `{"v":1,"alg":${JSON.stringify(w.alg)},"recipient_device_id":${JSON.stringify(w.recipient_device_id)},"directory_version":${w.directory_version},"current_epoch":${w.current_epoch},"ephemeral_public_key":${JSON.stringify(w.ephemeral_public_key)},"iv":${JSON.stringify(w.iv)},"ciphertext":${JSON.stringify(w.ciphertext)},"wrapped_by_device_id":${JSON.stringify(w.wrapped_by_device_id)}}`;

// PTY v2: per-stream subkey HKDF(epoch key, salt16, "heimdall-pty-v2|<sid>|<dir>"),
// nonce = u32be(0) | u64be(counter), frame = u32be epoch | salt16 | nonce | tag | ct.
// Input AAD binds the counter and the receiving bridge's unseal boot_id:
// "heimdall-pty-v2|e<epoch>|<sid>|in|<counter>|<boot_id>".
const ptyAad = (epoch, sessionId, dir, counter, bootId) => utf8(dir === 'in'
  ? `heimdall-pty-v2|e${epoch}|${sessionId}|in|${counter}|${bootId}`
  : `heimdall-pty-v2|e${epoch}|${sessionId}|out`);
const ptySubkey = (epochKey, salt, sessionId, dir) => hkdf(epochKey, salt, utf8(`heimdall-pty-v2|${sessionId}|${dir}`));
const ptyNonce = (counter) => { const n = Buffer.alloc(12); n.writeBigUInt64BE(BigInt(counter), 4); return n; };
const ptyFrame = (epoch, epochKey, salt, counter, sessionId, dir, plaintext, bootId) => {
  const nonce = ptyNonce(counter);
  const { ct, tag } = gcmSeal(ptySubkey(epochKey, salt, sessionId, dir), nonce, ptyAad(epoch, sessionId, dir, counter, bootId), plaintext);
  return Buffer.concat([u32be(epoch), salt, nonce, tag, ct]);
};

const SEARCH_DOMAIN = 'heimdall/task-chain-search-rpc/v2';
const searchKey = (epochKey, epoch) => hkdf(epochKey, utf8(SEARCH_DOMAIN), utf8(`${SEARCH_DOMAIN}|e${epoch}`));
const searchAad = (owner, bridge, req, dir, expires, epoch) => utf8(`${SEARCH_DOMAIN}|${owner}|${bridge}|${req}|${dir}|${expires}|e${epoch}`);

// ── build ─────────────────────────────────────────────────────────────────────
const USER_ID = 'usr_0123456789abcdef';
const K1 = seeded('epoch-key-1', 32);
const K2 = seeded('epoch-key-2', 32);

const flip = (buf, i) => { const c = Buffer.from(buf); c[i] ^= 0x01; return c; };
const tokenPayload = (tok) => Buffer.from(tok.slice(tok.lastIndexOf(':') + 1), 'base64');
const tokenWith = (epochStr, payload) => `vault:v2:e${epochStr}:${b64(payload)}`;

const envCases = [
  { name: 'epoch1_ascii', epoch: 1, plaintext: 'hello vault v2' },
  { name: 'epoch2_unicode', epoch: 2, plaintext: 'naïve – 日本語 – 🔐' },
  { name: 'epoch1_empty', epoch: 1, plaintext: '' },
].map((c) => {
  const nonce = seeded(`envelope-nonce-${c.name}`, 12);
  const key = c.epoch === 1 ? K1 : K2;
  return { ...c, nonce: hex(nonce), aad: `heimdall-vault-v2|e${c.epoch}`, token: envelopeToken(c.epoch, key, nonce, utf8(c.plaintext)) };
});

const base = envCases[0].token;
const basePayload = tokenPayload(base);
// Same plaintext sealed under K1 but labelled epoch 2 in the AAD: proves the AAD binds the
// epoch even when the key would match.
const k1AsE2 = (() => {
  const nonce = seeded('envelope-nonce-k1-as-e2', 12);
  const { ct, tag } = gcmSeal(K1, nonce, envelopeAad(2), utf8('hello vault v2'));
  return Buffer.concat([nonce, tag, ct]);
})();

const envNegative = [
  // Structurally valid, authentication must fail.
  { name: 'flipped_nonce', kind: 'auth', token: tokenWith('1', flip(basePayload, 0)) },
  { name: 'flipped_tag', kind: 'auth', token: tokenWith('1', flip(basePayload, 12)) },
  { name: 'flipped_ciphertext', kind: 'auth', token: tokenWith('1', flip(basePayload, 28)) },
  { name: 'epoch_header_changed_1_to_2', kind: 'auth', token: tokenWith('2', basePayload) },
  { name: 'aad_epoch_mismatch_key1_header1', kind: 'auth', token: tokenWith('1', k1AsE2) },
  // Unknown epoch: locked marker, never an exception.
  { name: 'unknown_epoch_3', kind: 'unknown_epoch', token: tokenWith('3', basePayload) },
  { name: 'unknown_epoch_max', kind: 'unknown_epoch', token: tokenWith('4294967295', basePayload) },
  // Malformed: rejected before any key lookup.
  { name: 'epoch_zero', kind: 'malformed', token: tokenWith('0', basePayload) },
  { name: 'epoch_leading_zero', kind: 'malformed', token: tokenWith('01', basePayload) },
  { name: 'epoch_overflow', kind: 'malformed', token: tokenWith('4294967296', basePayload) },
  { name: 'epoch_missing', kind: 'malformed', token: `vault:v2:e:${b64(basePayload)}` },
  { name: 'truncated_payload_27_bytes', kind: 'malformed', token: tokenWith('1', basePayload.subarray(0, 27)) },
  { name: 'bad_base64_char', kind: 'malformed', token: `vault:v2:e1:${b64(basePayload).replace(/^./, '*')}` },
  { name: 'bad_base64_length', kind: 'malformed', token: `vault:v2:e1:${b64(basePayload).replace(/=+$/, '').slice(0, -1)}` },
  { name: 'bad_base64_noncanonical_bits', kind: 'malformed', token: `vault:v2:e1:${(() => { const s = b64(Buffer.concat([basePayload, Buffer.from([0xff])])); return s.slice(0, -3) + 'B=='.slice(0, 3); })()}` },
  { name: 'base64url_alphabet', kind: 'malformed', token: `vault:v2:e1:${b64(basePayload).replace(/\+/g, '-').replace(/\//g, '_')}-_` },
  { name: 'trailing_garbage', kind: 'malformed', token: `${base} ` },
  { name: 'v1_token', kind: 'not_armored', token: `vault:v1:${b64(basePayload)}` },
  { name: 'enc_v1_token', kind: 'not_armored', token: `ENC:v1:${b64(basePayload)}` },
];

const kr = keyringBytes(USER_ID, 2, [[1, K1], [2, K2]]);
const krSingle = keyringBytes(USER_ID, 1, [[1, K1]]);
const many = (n) => Array.from({ length: n }, (_, i) => [i + 1, seeded(`many-${i + 1}`, 32)]);
const kr64 = keyringBytes('u'.repeat(64), 64, many(64));
const keyringNegative = [
  { name: 'wrong_magic', hex: hex(Buffer.concat([Buffer.from('HKR2'), kr.subarray(4)])) },
  { name: 'empty_user_id', hex: hex(keyringBytes('', 1, [[1, K1]])) },
  { name: 'user_id_too_long', hex: hex(keyringBytes('u'.repeat(65), 1, [[1, K1]])) },
  { name: 'user_id_bad_chars', hex: hex(keyringBytes('usr 1', 1, [[1, K1]])) },
  { name: 'zero_entries', hex: hex(keyringBytes(USER_ID, 1, [])) },
  { name: 'sixty_five_entries', hex: hex(keyringBytes(USER_ID, 65, many(65))) },
  { name: 'duplicate_epoch', hex: hex(keyringBytes(USER_ID, 1, [[1, K1], [1, K2]])) },
  { name: 'unsorted_epochs', hex: hex(keyringBytes(USER_ID, 2, [[2, K2], [1, K1]])) },
  { name: 'epoch_zero_entry', hex: hex(keyringBytes(USER_ID, 1, [[0, K2], [1, K1]])) },
  { name: 'current_epoch_not_latest', hex: hex(keyringBytes(USER_ID, 1, [[1, K1], [2, K2]])) },
  { name: 'current_epoch_absent', hex: hex(keyringBytes(USER_ID, 3, [[1, K1], [2, K2]])) },
  { name: 'truncated', hex: hex(kr.subarray(0, kr.length - 1)) },
  { name: 'trailing_byte', hex: hex(Buffer.concat([kr, Buffer.from([0])])) },
  { name: 'different_user_id', hex: hex(keyringBytes('usr_someone_else', 2, [[1, K1], [2, K2]])), expected_user_id: USER_ID },
];

// Statement + signature.
const issuerD = scalar('statement-issuer');
const subjectSignD = scalar('statement-subject-sign');
const subjectEcdhD = scalar('statement-subject-ecdh');
const stFields = {
  type: 'approve',
  user_id: USER_ID,
  seq: '7',
  prev_hash: hex(sha256(utf8('statement-prev'))),
  issuer_device_id: `dev_${hex(sha256(pubRaw(issuerD))).slice(0, 32)}`,
  issued_at_ms: '1760000000000',
  subject_device_id: `dev_${hex(sha256(pubRaw(subjectSignD))).slice(0, 32)}`,
  subject_kind: 'browser',
  subject_sign_pub: hex(pubRaw(subjectSignD)),
  subject_ecdh_pub: hex(pubRaw(subjectEcdhD)),
  subject_sign_alg: SIGN_ALG,
  subject_wrap_alg: WRAP_ALG,
  subject_label_b64: Buffer.from('Laptop – Firefox').toString('base64url'),
  epoch: '2',
  epoch_commit: hex(epochCommit(K2, USER_ID, 2)),
  wrap_sha256: '',
};
const stCanonical = statementCanonical(stFields);
const stSig = signChecked(issuerD, utf8(stCanonical));
const stInvalid = [
  { name: 'value_with_space', field: 'user_id', value: 'usr 1' },
  { name: 'value_with_newline', field: 'issuer_device_id', value: 'dev_a\ntype=revoke' },
  { name: 'value_with_equals', field: 'subject_label_b64', value: 'TGFwdG9w==' },
  { name: 'unknown_type', field: 'type', value: 'promote' },
  { name: 'removed_epoch_type', field: 'type', value: 'epoch' },
  { name: 'unknown_kind', field: 'subject_kind', value: 'phone' },
  { name: 'unknown_sign_alg', field: 'subject_sign_alg', value: 'webauthn-es256' },
  { name: 'unknown_wrap_alg', field: 'subject_wrap_alg', value: 'webauthn-prf-hkdf-sha256-aes256gcm' },
];

// Bridge unseal-key statement.
const bridgeIdentityD = scalar('bridge-identity');
const bridgeEcdhD = scalar('bridge-ecdh-ephemeral');
const bridgeId = 'brg_00112233445566778899aabbccddeeff';
const bootId = hex(seeded('bridge-boot-id', 16));
const unsealKeyCanonical = `heimdall-bridge-unseal-key/v1\n${bridgeId}\n${hex(pubRaw(bridgeEcdhD))}\n${bootId}`;
const unsealKeySig = signChecked(bridgeIdentityD, utf8(unsealKeyCanonical));
const otherIdentityD = scalar('bridge-identity-other');

// Bridge chain proof (plan §1 "Bridge keyring authentication"; the unseal payload's
// `chain_proof`, built by src/ui/utils/vaultDirectoryVerify.ts buildBridgeChainProof).
// Directory log: seq 1 genesis root A (epoch 1); 2 A approves browser B; 3 B approves
// the bridge (identity = the bridge_unseal_key vector's key); 4 A approves C; 5 A
// revokes C -> epoch 2. Both epoch carriers are by the root (issuer_chain []), the
// bridge approver is B (subject_approval.issuer_chain [B]).
const deviceIdOf = (signRaw) => `dev_${hex(sha256(signRaw)).slice(0, 32)}`;
const chainDevice = (name, kind, label) => {
  const signD = scalar(`chain-${name}-sign`);
  const ecdhD = kind === 'bridge' ? null : scalar(`chain-${name}-ecdh`);
  return { kind, label, signD, sign_pub: hex(pubRaw(signD)), ecdh_pub: ecdhD ? hex(pubRaw(ecdhD)) : '', device_id: deviceIdOf(pubRaw(signD)) };
};
const chainA = chainDevice('root-a', 'browser', 'Desk Firefox');
const chainB = chainDevice('browser-b', 'browser', 'Laptop Chrome');
const chainC = chainDevice('browser-c', 'browser', 'Old phone');
const chainBridge = { kind: 'bridge', label: 'build-box', signD: bridgeIdentityD, sign_pub: hex(pubRaw(bridgeIdentityD)), ecdh_pub: '', device_id: deviceIdOf(pubRaw(bridgeIdentityD)) };
const subjectFields = (d) => ({
  subject_device_id: d.device_id, subject_kind: d.kind, subject_sign_pub: d.sign_pub, subject_ecdh_pub: d.ecdh_pub,
  subject_sign_alg: SIGN_ALG, subject_wrap_alg: d.kind === 'bridge' ? '' : WRAP_ALG,
  subject_label_b64: Buffer.from(d.label, 'utf8').toString('base64url'),
});
const signedStatement = (issuer, fields) => {
  const statement = statementCanonical({ user_id: USER_ID, issuer_device_id: issuer.device_id, ...fields });
  return { statement, signature: sigObject(signChecked(issuer.signD, utf8(statement))) };
};
const commit1 = hex(epochCommit(K1, USER_ID, 1));
const commit2 = hex(epochCommit(K2, USER_ID, 2));
// The signed directory log: seq = the version each op creates, prev_hash = SHA-256 of
// the previous op's canonical statement bytes (genesis: empty).
const logEntryHash = (statement) => hex(sha256(utf8(statement)));
const chainLog = [];
const logOp = (issuer, fields) => {
  const prev = chainLog.length ? chainLog[chainLog.length - 1].hash : '';
  const s = signedStatement(issuer, { seq: String(chainLog.length + 1), prev_hash: prev, ...fields });
  chainLog.push({ seq: chainLog.length + 1, statement: s.statement, signature: s.signature, hash: logEntryHash(s.statement) });
  return s;
};
const chGenesis = logOp(chainA, { type: 'genesis', issued_at_ms: '1760000000000', ...subjectFields(chainA), epoch: '1', epoch_commit: commit1 });
const chApproveB = logOp(chainA, { type: 'approve', issued_at_ms: '1760000001000', ...subjectFields(chainB), epoch: '1', epoch_commit: commit1, wrap_sha256: hex(seeded('chain-wrap-b', 32)) });
const chApproveBridge = logOp(chainB, { type: 'approve', issued_at_ms: '1760000002000', ...subjectFields(chainBridge), epoch: '1', epoch_commit: commit1 });
const chApproveC = logOp(chainA, { type: 'approve', issued_at_ms: '1760000003000', ...subjectFields(chainC), epoch: '1', epoch_commit: commit1, wrap_sha256: hex(seeded('chain-wrap-c', 32)) });
// Revoke C: one statement names the revoked subject AND introduces epoch 2.
const chRevokeC = logOp(chainA, { type: 'revoke', issued_at_ms: '1760000004000', ...subjectFields(chainC), epoch: '2', epoch_commit: commit2 });
// Negative-test material (NOT in the log): a standalone rotate to epoch 2 signed by B.
const chEpoch2ByB = signedStatement(chainB, { type: 'rotate', seq: '6', prev_hash: chainLog[4].hash, issued_at_ms: '1760000005000', epoch: '2', epoch_commit: commit2 });
const chainLink = (d, approval) => ({
  device_id: d.device_id, kind: d.kind, sign_alg: SIGN_ALG, sign_public_key: d.sign_pub,
  approval_statement: approval.statement, approval_signature: approval.signature,
});
// Member order matches buildBridgeChainProof; signatures are signature-object JSON text.
const chainProof = {
  v: 2,
  user_id: USER_ID,
  root_device_id: chainA.device_id,
  root_sign_alg: SIGN_ALG,
  root_sign_pub: chainA.sign_pub,
  genesis: { statement: chGenesis.statement, signature: chGenesis.signature },
  epochs: [
    { epoch: 1, statement: chGenesis.statement, signature: chGenesis.signature, issuer_chain: [] },
    { epoch: 2, statement: chRevokeC.statement, signature: chRevokeC.signature, issuer_chain: [] },
  ],
  subject_approval: { statement: chApproveBridge.statement, signature: chApproveBridge.signature, issuer_chain: [chainLink(chainB, chApproveB)] },
};
const accountFingerprint = (() => { const h = hex(sha256(pubRaw(chainA.signD)).subarray(0, 8)); return `${h.slice(0, 4)} ${h.slice(4, 8)} ${h.slice(8, 12)} ${h.slice(12, 16)}`; })();

// Unseal v2.
const clientD = scalar('unseal-client-ephemeral');
const unsealShared = ecdhShared(clientD, pubRaw(bridgeEcdhD));
if (!unsealShared.equals(ecdhShared(bridgeEcdhD, pubRaw(clientD)))) throw new Error('ECDH self-check failed');
const unsealKey = hkdf(unsealShared, Buffer.alloc(32), utf8('heimdall-bridge-unseal-v2'));
const unsealTs = 1760000000123;
const unsealNonce = hex(seeded('unseal-nonce', 16));
const unsealAad = `heimdall-bridge-unseal-v2|${bridgeId}|${unsealTs}|${unsealNonce}|2`;
const unsealIv = seeded('unseal-iv', 12);
const unsealSealed = gcmSeal(unsealKey, unsealIv, utf8(unsealAad), kr);

// Keyring wrap.
const recipientD = scalar('wrap-recipient-ecdh');
const wrapEphD = scalar('wrap-ephemeral');
const recipientDeviceId = `dev_${hex(sha256(pubRaw(scalar('wrap-recipient-sign')))).slice(0, 32)}`;
const wrapAad = `heimdall-keyring-wrap-v1|${USER_ID}|${recipientDeviceId}|7|2`;
const wrapKey = hkdf(ecdhShared(wrapEphD, pubRaw(recipientD)), Buffer.alloc(32), utf8('heimdall-keyring-wrap-v1'));
const wrapIv = seeded('wrap-iv', 12);
const wrapSealed = gcmSeal(wrapKey, wrapIv, utf8(wrapAad), kr);
const wrapObj = {
  alg: WRAP_ALG,
  recipient_device_id: recipientDeviceId,
  directory_version: 7,
  current_epoch: 2,
  ephemeral_public_key: hex(pubRaw(wrapEphD)),
  iv: hex(wrapIv),
  ciphertext: hex(Buffer.concat([wrapSealed.ct, wrapSealed.tag])),
  wrapped_by_device_id: stFields.issuer_device_id,
};
const wrapCanonical = wrapCanonicalJson(wrapObj);

// PTY v2.
const ptySession = 'shs_0011223344556677';
const ptyOutSalt = seeded('pty-out-salt', 16);
const ptyInSalt = seeded('pty-in-salt', 16);
const ptyBootId = hex(seeded('pty-boot-id', 16));
const ptyCases = [
  { direction: 'out', epoch: 2, key: K2, salt: ptyOutSalt, counter: 5, plaintext: utf8('\x1b[32mok\x1b[0m\r\n') },
  { direction: 'in', epoch: 2, key: K2, salt: ptyInSalt, counter: 1760000000000001, plaintext: utf8('ls -la\r') },
  { direction: 'out', epoch: 1, key: K1, salt: ptyOutSalt, counter: 1, plaintext: utf8('') },
].map((c) => ({
  direction: c.direction,
  epoch: c.epoch,
  session_id: ptySession,
  salt: hex(c.salt),
  counter: c.counter,
  subkey: hex(ptySubkey(c.key, c.salt, ptySession, c.direction)),
  nonce: hex(ptyNonce(c.counter)),
  ...(c.direction === 'in' ? { boot_id: ptyBootId } : {}),
  plaintext_hex: hex(c.plaintext),
  aad: ptyAad(c.epoch, ptySession, c.direction, c.counter, ptyBootId).toString('utf8'),
  frame_hex: hex(ptyFrame(c.epoch, c.key, c.salt, c.counter, ptySession, c.direction, c.plaintext, ptyBootId)),
}));

// Search key v2 + one RPC envelope.
const sk2 = searchKey(K2, 2);
const searchNonce = seeded('search-nonce', 12);
const searchPlain = '{"request_id":"req_1","query":"deploy","project_id":"","status":"","limit":10}';
const searchAadStr = searchAad(USER_ID, bridgeId, 'req_1', 'request', 1760000005000, 2).toString('utf8');
const searchSealed = gcmSeal(sk2, searchNonce, utf8(searchAadStr), utf8(searchPlain));

// File write v2 (finding N4): v2 token format under the epoch key with AAD
// "heimdall-fs-write-v2|e<epoch>|<bridge_id>|<hex sha256(path)>".
const fsWritePath = 'src/main.ts';
const fsWriteNonce = seeded('fs-write-nonce', 12);
const fsWritePlain = 'export const x = 1;';
const fsWriteAad = `heimdall-fs-write-v2|e2|${bridgeId}|${hex(sha256(utf8(fsWritePath)))}`;
const fsWriteSealed = gcmSeal(K2, fsWriteNonce, utf8(fsWriteAad), utf8(fsWritePlain));

// Hub-blind pairing (plan §1 "Pairing"): code S -> lookup / K_mac; key_mac over the
// browser register statement or the bridge's identity|ecdh|challenge; pair_mac over
// the approval statement, the root key and the head the approval creates.
// Pairing stretch (the pairing-code stretch, not the password-era KDF):
// K = PBKDF2-HMAC-SHA256(S, "heimdall-pair/v2|<kind>|<user_id>|<hub_origin>|<pair_salt>").
const PAIR_CODE = 'K7QX-M2PA-ZD4H-R5';
const PAIR_ITERATIONS = 1_000_000;
const PAIR_HUB_ORIGIN = 'https://hub.example.test:443';
const pairStretchSalt = (kind, userId, salt) => `heimdall-pair/v2|${kind}|${userId}|${PAIR_HUB_ORIGIN}|${salt}`;
const pairStretch = (saltText) => crypto.pbkdf2Sync(utf8(PAIR_CODE.replace(/-/g, '')), utf8(saltText), PAIR_ITERATIONS, 32, 'sha256');
const pairKeysOf = (k) => ({ lookup: hkdf(k, Buffer.alloc(32), utf8('heimdall-pair/v2|lookup')), mac: hkdf(k, Buffer.alloc(32), utf8('heimdall-pair/v2|mac')) });
const pairBrowserSalt = hex(seeded('pair-salt-browser', 16));
const pairBridgeSalt = hex(seeded('pair-salt-bridge', 16));
const pairBrowserStretchSalt = pairStretchSalt('browser', USER_ID, pairBrowserSalt);
const pairBridgeStretchSalt = pairStretchSalt('bridge', '', pairBridgeSalt);
const pairBrowserK = pairStretch(pairBrowserStretchSalt);
const pairBridgeK = pairStretch(pairBridgeStretchSalt);
const pairBrowser = pairKeysOf(pairBrowserK);
const pairBridge = pairKeysOf(pairBridgeK);
const pairRegister = statementCanonical({
  type: 'register', user_id: USER_ID, seq: '', prev_hash: '', issuer_device_id: chainB.device_id, issued_at_ms: '1760000000500',
  ...subjectFields(chainB), epoch: '', epoch_commit: '', wrap_sha256: '',
});
const pairChallenge = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';
const pairBridgePayload = `${chainBridge.sign_pub}|${hex(pubRaw(bridgeEcdhD))}|${pairChallenge}`;
const pairApproveMac = hmac256(pairBridge.mac, utf8(`heimdall-pair-approve/v1|${chApproveBridge.statement}|${chainA.sign_pub}|${logEntryHash(chApproveBridge.statement)}`));
const vectors = {
  description: 'Generated by tools/vault_vectors/gen_vault_v2_vectors.mjs. Do not edit by hand; regenerate and commit.',
  version: 1,
  user_id: USER_ID,
  epoch_keys: { 1: hex(K1), 2: hex(K2) },
  envelope: {
    prefix: 'vault:v2:',
    token_regex: 'vault:v2:e[1-9][0-9]{0,9}:[A-Za-z0-9+/]+={0,2}',
    max_payload_bytes: 64 * 1024 * 1024,
    cases: envCases,
    negative: envNegative,
    embedded: {
      text: `before ${envCases[0].token} middle ${envCases[1].token}. v1 stays vault:v1:${b64(basePayload)} unknown ${tokenWith('9', basePayload)} bare vault:v2: end`,
      decrypted_with_locked_marker_LOCKED: `before ${envCases[0].plaintext} middle ${envCases[1].plaintext}. v1 stays vault:v1:${b64(basePayload)} unknown LOCKED bare vault:v2: end`,
    },
  },
  keyring: {
    user_id: USER_ID,
    current_epoch: 2,
    entries: [{ epoch: 1, key: hex(K1) }, { epoch: 2, key: hex(K2) }],
    hex: hex(kr),
    single_epoch_hex: hex(krSingle),
    max_64_hex: hex(kr64),
    max_64_len: kr64.length,
    negative: keyringNegative,
  },
  algorithms: { sign: [SIGN_ALG], wrap: [WRAP_ALG], unknown_sign: ['webauthn-es256', 'ecdsa-p384-sha384', ''], unknown_wrap: ['webauthn-prf-hkdf-sha256-aes256gcm', 'x25519', ''] },
  epoch_commit: { user_id: USER_ID, epoch: 2, key: hex(K2), message: `heimdall-epoch-commit|${USER_ID}|2`, commit: hex(epochCommit(K2, USER_ID, 2)) },
  statement: {
    fields: stFields,
    canonical: stCanonical,
    issuer_private_key: hex(fromBig(issuerD)),
    issuer_public_key: hex(pubRaw(issuerD)),
    signature: hex(stSig),
    signature_object: sigObject(stSig),
    // Signature objects that must be rejected before any verification is attempted.
    invalid_signature_objects: [
      `{"alg":"webauthn-es256","sig":"${hex(stSig)}"}`,
      `{"alg":"ECDSA-P256-SHA256","sig":"${hex(stSig)}"}`,
      `{"sig":"${hex(stSig)}"}`,
      `{"alg":"${SIGN_ALG}"}`,
      `{"alg":"${SIGN_ALG}","sig":"${hex(stSig).slice(0, 126)}"}`,
      `{"alg":"${SIGN_ALG}","sig":"${hex(stSig).toUpperCase()}"}`,
      `"${hex(stSig)}"`,
    ],
    invalid_values: stInvalid,
  },
  bridge_unseal_key: {
    bridge_id: bridgeId,
    ecdh_public_key: hex(pubRaw(bridgeEcdhD)),
    boot_id: bootId,
    canonical: unsealKeyCanonical,
    identity_private_key: hex(fromBig(bridgeIdentityD)),
    identity_public_key: hex(pubRaw(bridgeIdentityD)),
    signature: hex(unsealKeySig),
    signature_object: sigObject(unsealKeySig),
    other_identity_public_key: hex(pubRaw(otherIdentityD)),
    other_identity_signature: hex(signChecked(otherIdentityD, utf8(unsealKeyCanonical))),
    other_identity_signature_object: sigObject(signChecked(otherIdentityD, utf8(unsealKeyCanonical))),
  },
  unseal_v2: {
    bridge_id: bridgeId,
    bridge_ecdh_private_key: hex(fromBig(bridgeEcdhD)),
    bridge_ecdh_public_key: hex(pubRaw(bridgeEcdhD)),
    client_private_key: hex(fromBig(clientD)),
    client_public_key: hex(pubRaw(clientD)),
    hkdf_info: 'heimdall-bridge-unseal-v2',
    aes_key: hex(unsealKey),
    timestamp: unsealTs,
    nonce: unsealNonce,
    current_epoch: 2,
    aad: unsealAad,
    iv: hex(unsealIv),
    keyring_hex: hex(kr),
    tag: hex(unsealSealed.tag),
    ciphertext: hex(unsealSealed.ct),
  },
  pairing: {
    code: PAIR_CODE,
    code_typed: ' k7qx m2pa-zd4h r5 ',
    iterations: PAIR_ITERATIONS,
    hub_origin: PAIR_HUB_ORIGIN,
    browser: {
      user_id: USER_ID,
      pair_salt: pairBrowserSalt,
      stretch_salt: pairBrowserStretchSalt,
      stretched_key: hex(pairBrowserK),
      lookup: hex(pairBrowser.lookup),
      mac_key: hex(pairBrowser.mac),
      register_statement: pairRegister,
      key_mac: hex(hmac256(pairBrowser.mac, utf8(`heimdall-pair-key/v1|browser|${pairRegister}`))),
    },
    bridge: {
      pair_salt: pairBridgeSalt,
      stretch_salt: pairBridgeStretchSalt,
      stretched_key: hex(pairBridgeK),
      lookup: hex(pairBridge.lookup),
      mac_key: hex(pairBridge.mac),
      identity_public_key: chainBridge.sign_pub,
      ecdh_public_key: hex(pubRaw(bridgeEcdhD)),
      code_challenge: pairChallenge,
      key_mac: hex(hmac256(pairBridge.mac, utf8(`heimdall-pair-key/v1|bridge|${pairBridgePayload}`))),
      approval_statement: chApproveBridge.statement,
      root_sign_pub: chainA.sign_pub,
      head_hash: logEntryHash(chApproveBridge.statement),
      approve_mac: hex(pairApproveMac),
    },
    invalid_codes: ['K7QX-M2PA-ZD4H-R', 'K7QX-M2PA-ZD4H-R5A', 'K7QX-M2PA-ZD4H-R0', 'K7QX_M2PA_ZD4H_R5', 'K7QX-M2PA-ZD4H-R\u0131', 'K7QX-M2PA-ZD4H-\u017f5', ''],
    // Each is rejected by pair_stretch_salt / pairStretchSalt (fail closed).
    invalid_contexts: [
      { kind: 'browser', user_id: '', hub_origin: PAIR_HUB_ORIGIN, pair_salt: pairBrowserSalt },
      { kind: 'browser', user_id: 'usr|x', hub_origin: PAIR_HUB_ORIGIN, pair_salt: pairBrowserSalt },
      { kind: 'bridge', user_id: USER_ID, hub_origin: PAIR_HUB_ORIGIN, pair_salt: pairBridgeSalt },
      { kind: 'electron', user_id: '', hub_origin: PAIR_HUB_ORIGIN, pair_salt: pairBridgeSalt },
      { kind: 'bridge', user_id: '', hub_origin: 'https://hub.example.test', pair_salt: pairBridgeSalt },
      { kind: 'bridge', user_id: '', hub_origin: 'https://hub.example.test:0443', pair_salt: pairBridgeSalt },
      { kind: 'bridge', user_id: '', hub_origin: 'https://hub.example.test:65536', pair_salt: pairBridgeSalt },
      { kind: 'bridge', user_id: '', hub_origin: 'https://hub.example.test.:443', pair_salt: pairBridgeSalt },
      { kind: 'bridge', user_id: '', hub_origin: 'https://Hub.example.test:443', pair_salt: pairBridgeSalt },
      { kind: 'bridge', user_id: '', hub_origin: 'https://hub.example.test:443/api', pair_salt: pairBridgeSalt },
      { kind: 'bridge', user_id: '', hub_origin: 'ftp://hub.example.test:21', pair_salt: pairBridgeSalt },
      { kind: 'bridge', user_id: '', hub_origin: PAIR_HUB_ORIGIN, pair_salt: pairBridgeSalt.slice(2) },
      { kind: 'bridge', user_id: '', hub_origin: PAIR_HUB_ORIGIN, pair_salt: pairBridgeSalt.toUpperCase() },
    ],
  },
  bridge_chain: {
    user_id: USER_ID,
    current_epoch: 2,
    keyring_hex: hex(kr),
    bridge_identity_public_key: chainBridge.sign_pub,
    bridge_device_id: chainBridge.device_id,
    account_fingerprint: accountFingerprint,
    proof: chainProof,
    proof_json: JSON.stringify(chainProof),
    // Validly signed but wrong for this proof (negative tests).
    epoch2_by_b: chEpoch2ByB,
    approve_c_link: chainLink(chainC, chApproveC),
    // The full directory log the proof was cut from (TS/Odin log verification vectors).
    log: chainLog,
    head_hash: chainLog[chainLog.length - 1].hash,
    // Test-only keys, so the Odin suite can sign extra negative statements.
    private_keys: { root_a: hex(fromBig(chainA.signD)), browser_b: hex(fromBig(chainB.signD)) },
  },
  wrap: {
    user_id: USER_ID,
    recipient_ecdh_private_key: hex(fromBig(recipientD)),
    recipient_ecdh_public_key: hex(pubRaw(recipientD)),
    ephemeral_private_key: hex(fromBig(wrapEphD)),
    hkdf_info: 'heimdall-keyring-wrap-v1',
    aad: wrapAad,
    keyring_hex: hex(kr),
    json: wrapObj,
    canonical_json: wrapCanonical,
    wrap_sha256: hex(sha256(utf8(wrapCanonical))),
  },
  pty: { cases: ptyCases },
  fs_write: {
    epoch: 2,
    bridge_id: bridgeId,
    path: fsWritePath,
    aad: fsWriteAad,
    nonce: hex(fsWriteNonce),
    plaintext: fsWritePlain,
    token: `vault:v2:e2:${b64(Buffer.concat([fsWriteNonce, fsWriteSealed.tag, fsWriteSealed.ct]))}`,
  },
  search: {
    domain: SEARCH_DOMAIN,
    epoch: 2,
    epoch_key: hex(K2),
    salt: SEARCH_DOMAIN,
    info: `${SEARCH_DOMAIN}|e2`,
    derived_key: hex(sk2),
    rpc: {
      owner_user_id: USER_ID,
      bridge_id: bridgeId,
      request_id: 'req_1',
      direction: 'request',
      expires_at_ms: 1760000005000,
      aad: searchAadStr,
      nonce: hex(searchNonce),
      plaintext: searchPlain,
      envelope: `search:v2:e2:${b64(Buffer.concat([searchNonce, searchSealed.tag, searchSealed.ct]))}`,
    },
  },
};

const text = `${JSON.stringify(vectors, null, 2)}\n`;
if (process.argv.includes('--check')) {
  const existing = fs.existsSync(outPath) ? fs.readFileSync(outPath, 'utf8') : '';
  if (existing !== text) {
    console.error(`${outPath} is stale; re-run without --check`);
    process.exit(1);
  }
  console.log('vault_v2_vectors.json is up to date');
} else {
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, text);
  console.log(`wrote ${outPath} (${text.length} bytes)`);
}
