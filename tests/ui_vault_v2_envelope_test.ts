// Shared v2 vectors (tests/fixtures/vault_v2_vectors.json) on the TS side: content
// envelope, PTY v2, search key v2, plus the security-critical envelope negatives.
// The Odin twin is src/lib/vault/vault_test.odin.
//
// RUN: node --test tests/ui_vault_v2_envelope_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  decryptVaultText,
  encryptVaultText,
  sealVaultEnvelope,
  parseVaultEnvelope,
  findVaultTokens,
  replaceVaultTokens,
  containsVaultArmored,
  VAULT_LOCKED_MARKER,
  VAULT_OTHER_VAULT_MARKER,
  VAULT_TOKEN_RE,
  fsWriteAad,
  sealFsWriteContent,
  openFsWriteContent,
} from '../src/ui/utils/vaultCrypto.ts';
import { importKeyring, keyFor, vaultIdFor, type VaultKeyring } from '../src/ui/utils/vaultKeyring.ts';
import { decryptEmbeddedVaultTokens } from '../src/ui/utils/vaultContent.ts';
import { decryptPtyPayload, derivePtySubkey, ptyAad, ptyBaseKeyFor, ptyNonce, sealPtyPayload, PtyOutputReplayGuard, PtyReplayError } from '../src/ui/components/shells/ptyWire.ts';
import { deriveTaskChainSearchKey } from '../src/ui/utils/taskChainSearchKey.ts';
import { openTaskChainSearch, sealTaskChainSearch, taskChainSearchAad } from '../src/ui/utils/taskChainSearch.ts';

const V = JSON.parse(fs.readFileSync(path.resolve(path.dirname(fileURLToPath(import.meta.url)), 'fixtures/vault_v2_vectors.json'), 'utf8'));
const hex = (s: string) => Uint8Array.from(Buffer.from(s, 'hex'));
const toHex = (b: Uint8Array) => Buffer.from(b).toString('hex');

async function vectorKeyring(): Promise<VaultKeyring> {
  return importKeyring(hex(V.keyring.hex));
}

test('envelope vectors decrypt, and resealing with the fixed nonce reproduces the token', async () => {
  const kr = await vectorKeyring();
  for (const c of V.envelope.cases) {
    assert.equal(await decryptVaultText(c.token, kr), c.plaintext, c.name);
    const resealed = await sealVaultEnvelope(new TextEncoder().encode(c.plaintext), keyFor(kr, c.epoch)!, kr.vaultId, c.epoch, hex(c.nonce));
    assert.equal(resealed, c.token, c.name);
  }
  assert.equal(new RegExp(V.envelope.token_regex).source, VAULT_TOKEN_RE.source);
  assert.equal(kr.vaultId, V.envelope.vault_id);
  assert.equal(await vaultIdFor(V.keyring.root_sign_pub), V.keyring.vault_id, 'vault id = SHA-256(root_sign_pub)[:8]');
});

test('encryption uses the current epoch and round-trips across epochs 1 and 2', async () => {
  const kr = await vectorKeyring();
  const tok = await encryptVaultText('cross-epoch', kr);
  assert.ok(tok.startsWith(`vault:v2:${V.envelope.vault_id}:e2:`));
  assert.equal(await decryptVaultText(tok, kr), 'cross-epoch');
  assert.equal(await decryptVaultText(V.envelope.cases[0].token, kr), V.envelope.cases[0].plaintext);
});

test('envelope negatives: tamper fails, unknown epoch is locked, malformed is rejected, v1 is opaque', async () => {
  const kr = await vectorKeyring();
  for (const c of V.envelope.negative) {
    switch (c.kind) {
      case 'auth':
        await assert.rejects(decryptVaultText(c.token, kr), c.name);
        break;
      case 'unknown_epoch':
        assert.equal(await decryptVaultText(c.token, kr), VAULT_LOCKED_MARKER, c.name);
        break;
      case 'other_vault':
        // Content of a previous (reset) vault: a distinct marker, never tried with these keys.
        assert.equal(await decryptVaultText(c.token, kr), VAULT_OTHER_VAULT_MARKER, c.name);
        break;
      case 'malformed':
        await assert.rejects(decryptVaultText(c.token, kr), c.name);
        break;
      case 'not_armored':
        assert.equal(await decryptVaultText(c.token, kr), c.token, c.name);
        assert.equal(containsVaultArmored(c.token), false, c.name);
        break;
      default:
        assert.fail(`unhandled kind ${c.kind}`);
    }
  }
  const big = `vault:v2:${V.envelope.vault_id}:e1:${'A'.repeat(Math.floor((V.envelope.max_payload_bytes + 2) / 3) * 4 + 4)}`;
  assert.throws(() => parseVaultEnvelope(big), /too large/);
});

test('embedded tokens: decrypted, unknown epoch locked, v1 and bare prefix kept', async () => {
  const kr = await vectorKeyring();
  const emb = V.envelope.embedded;
  const expected = emb.decrypted_with_locked_marker_LOCKED.replace('LOCKED', VAULT_LOCKED_MARKER).replace('OTHER', VAULT_OTHER_VAULT_MARKER);
  assert.equal(await decryptEmbeddedVaultTokens(emb.text, kr), expected);
  assert.equal(findVaultTokens(emb.text).length, 4);
  assert.ok(!containsVaultArmored(replaceVaultTokens(emb.text)));
});

test('PTY v2 vectors: per-stream subkey, counter nonce, AAD binding (session, direction, epoch, salt, counter)', async () => {
  const kr = await vectorKeyring();
  for (const c of V.pty.cases) {
    assert.equal(new TextDecoder().decode(ptyAad(c.epoch, c.session_id, c.direction, c.counter, c.boot_id)), c.aad);
    assert.equal(toHex(ptyNonce(c.counter)), c.nonce);
    const base = (await ptyBaseKeyFor(kr, c.epoch))!;
    assert.ok(base);
    // The subkey itself is non-extractable; pin it by sealing under it with the vector nonce.
    const subkey = await derivePtySubkey(base, hex(c.salt), c.session_id, c.direction);
    assert.equal(subkey.extractable, false);
    const frame = await sealPtyPayload(hex(c.plaintext_hex), base, c.epoch, c.session_id, c.direction, hex(c.salt), c.counter, c.boot_id);
    assert.equal(toHex(frame), c.frame_hex);
    assert.equal(toHex((await decryptPtyPayload(frame, kr, c.session_id, c.direction, c.boot_id))!), c.plaintext_hex);
    await assert.rejects(decryptPtyPayload(frame, kr, 'shs_other', c.direction, c.boot_id));
    await assert.rejects(decryptPtyPayload(frame, kr, c.session_id, c.direction === 'out' ? 'in' : 'out', c.boot_id ?? 'b00t'));
    const swapped = Uint8Array.from(frame);
    swapped[3] ^= 0x03; // epoch 1 <-> 2
    await assert.rejects(decryptPtyPayload(swapped, kr, c.session_id, c.direction, c.boot_id));
    const resalted = Uint8Array.from(frame);
    resalted[4] ^= 0x01;
    await assert.rejects(decryptPtyPayload(resalted, kr, c.session_id, c.direction, c.boot_id));
    const recounted = Uint8Array.from(frame);
    recounted[4 + 16 + 11] ^= 0x02;
    await assert.rejects(decryptPtyPayload(recounted, kr, c.session_id, c.direction, c.boot_id));
    if (c.direction === 'in') {
      await assert.rejects(decryptPtyPayload(frame, kr, c.session_id, 'in', 'ffeeddccbbaa99887766554433221100'));
      await assert.rejects(decryptPtyPayload(frame, kr, c.session_id, 'in'));
    }
  }
  const unknown = Uint8Array.from(hex(V.pty.cases[0].frame_hex));
  unknown[3] = 9;
  assert.equal(await decryptPtyPayload(unknown, kr, V.pty.cases[0].session_id), null);
  // L4: AAD components outside the id grammar fail closed.
  assert.throws(() => ptyAad(1, 'sh|in|9', 'out'));
  assert.throws(() => ptyAad(1, '', 'out'));
  assert.throws(() => ptyAad(1, 'sh_ok', 'in'));
  assert.throws(() => ptyAad(1, 'sh_ok', 'in', 1));
  assert.throws(() => ptyAad(1, 'sh_ok', 'in', 1, 'b|x'));
  assert.throws(() => taskChainSearchAad('usr|x', 'brg', 'req', 'request', 1, 1));
  assert.throws(() => taskChainSearchAad('usr', 'brg', '', 'request', 1, 1));
});

test('fs write vector: vault-, bridge-, project-root- and path-bound AAD', async () => {
  const f = V.fs_write;
  const kr = await vectorKeyring();
  assert.equal(new TextDecoder().decode(await fsWriteAad(kr.vaultId, f.epoch, f.bridge_id, f.root, f.path)), f.aad);
  assert.equal(await sealFsWriteContent(f.plaintext, f.bridge_id, f.root, f.path, kr, hex(f.nonce)), f.token);
  assert.equal(await openFsWriteContent(f.token, f.bridge_id, f.root, f.path, kr), f.plaintext);
  await assert.rejects(openFsWriteContent(f.token, f.bridge_id, f.root, 'src/other.ts', kr));
  await assert.rejects(openFsWriteContent(f.token, f.bridge_id, '/home/dev/projects/other', f.path, kr), 'another project root');
  await assert.rejects(decryptVaultText(f.token, kr));
});

test('PTY output replay guard: strictly increasing counter per salt; a new salt starts fresh only after it authenticates', async () => {
  const kr = await vectorKeyring();
  const c = V.pty.cases.find((x: any) => x.direction === 'out' && x.epoch === 2);
  const base = (await ptyBaseKeyFor(kr, c.epoch))!;
  const seal = (counter: number, salt = hex(c.salt)) => sealPtyPayload(new Uint8Array([1]), base, c.epoch, c.session_id, 'out', salt, counter);
  const guard = new PtyOutputReplayGuard();
  const f5 = await seal(5);
  assert.ok(await decryptPtyPayload(f5, kr, c.session_id, 'out', undefined, guard));
  await assert.rejects(decryptPtyPayload(f5, kr, c.session_id, 'out', undefined, guard), PtyReplayError, 'a replay is dropped');
  await assert.rejects(decryptPtyPayload(await seal(4), kr, c.session_id, 'out', undefined, guard), PtyReplayError, 'a reorder is dropped');
  assert.ok(await decryptPtyPayload(await seal(6), kr, c.session_id, 'out', undefined, guard));
  const otherSalt = new Uint8Array(16).fill(7);
  assert.ok(await decryptPtyPayload(await seal(1, otherSalt), kr, c.session_id, 'out', undefined, guard), 'a new salt starts fresh');
  const forged = Uint8Array.from(await seal(1, new Uint8Array(16).fill(9)));
  forged[forged.length - 1] ^= 1;
  await assert.rejects(decryptPtyPayload(forged, kr, c.session_id, 'out', undefined, guard));
  assert.ok(!(await decryptPtyPayload(await seal(2, new Uint8Array(16).fill(9)), kr, c.session_id, 'out', undefined, guard).then(() => false, () => true)), 'a forged frame did not register its salt');
});

test('search key v2 vector and epoch-bound RPC envelope', async () => {
  const sv = V.search;
  const sk = await deriveTaskChainSearchKey(hex(sv.epoch_key), sv.epoch);
  const r = sv.rpc;
  const aad = taskChainSearchAad(r.owner_user_id, r.bridge_id, r.request_id, r.direction, r.expires_at_ms, sv.epoch);
  assert.equal(new TextDecoder().decode(aad), r.aad);
  assert.equal(await sealTaskChainSearch(r.plaintext, sk, aad, hex(r.nonce)), r.envelope);
  assert.deepEqual(await openTaskChainSearch(r.envelope, sk, aad), JSON.parse(r.plaintext));
  const otherEpoch = await deriveTaskChainSearchKey(hex(sv.epoch_key), 1);
  await assert.rejects(openTaskChainSearch(r.envelope, otherEpoch, aad), /Invalid encrypted search response/);
  await assert.rejects(openTaskChainSearch(r.envelope.replace(':e2:', ':e1:'), sk, aad), /Invalid encrypted search response/);
});

test('chat pane capture: sealed body decrypts, and fails closed to the locked marker', async () => {
  const { decryptPaneCaptureBody } = await import('../src/ui/utils/vaultChats.ts');
  const kr = await vectorKeyring();
  const token = await encryptVaultText('pane line 1\npane line 2', kr);
  assert.equal(await decryptPaneCaptureBody(token, kr), 'pane line 1\npane line 2');
  assert.equal(await decryptPaneCaptureBody('plain capture', kr), 'plain capture');
  const tampered = token.slice(0, -4) + (token.endsWith('AAAA') ? 'BBBB' : 'AAAA');
  assert.equal(await decryptPaneCaptureBody(tampered, kr), VAULT_LOCKED_MARKER);
  const other = await importKeyring(hex(V.keyring.single_epoch_hex));
  const otherToken = await encryptVaultText('x', kr);
  const lockedOut = await decryptPaneCaptureBody(otherToken, Object.freeze({ userId: other.userId, vaultId: other.vaultId, currentEpoch: 1, keys: new Map() }) as any);
  assert.equal(lockedOut, VAULT_LOCKED_MARKER);
});
