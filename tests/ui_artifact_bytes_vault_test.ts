// REQ-BUNDLE-4: binary artifacts (html-bundle ZIPs, images) must open byte-for-byte.
// decryptVaultText routes plaintext through TextDecoder, which replaces invalid UTF-8
// with U+FFFD; decryptVaultBytes must not.
//
// RUN: node --test tests/ui_artifact_bytes_vault_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { importKeyring, serializeKeyringBytes } from '../src/ui/utils/vaultKeyring.ts';
import { decryptVaultBytes, decryptVaultText, encryptVaultBytes, encryptVaultText } from '../src/ui/utils/vaultContent.ts';
import { keyringFromHex } from './helpers/vaultTestKeyring.ts';

const fixture = JSON.parse(readFileSync(new URL('./fixtures/artifact_binary_vault_v2.json', import.meta.url), 'utf8'));

async function fixtureKeyring() {
  const key = Uint8Array.from(Buffer.from(fixture.key_hex, 'hex'));
  return importKeyring(serializeKeyringBytes({ userId: fixture.user_id, vaultId: fixture.vault_id, currentEpoch: fixture.epoch, entries: [{ epoch: fixture.epoch, key }] }));
}

test('decryptVaultBytes opens a ham-ctl sealed binary file byte-for-byte', async () => {
  const opened = await decryptVaultBytes(fixture.armored, await fixtureKeyring());
  assert.equal(opened.status, 'ok');
  assert.ok(opened.status === 'ok');
  assert.equal(Buffer.from(opened.bytes).toString('hex'), fixture.plaintext_hex);
});

test('the text path is lossy for the same payload, which is why binary content needs the byte path', async () => {
  const text = await decryptVaultText(fixture.armored, await fixtureKeyring());
  assert.notEqual(Buffer.from(new TextEncoder().encode(text)).toString('hex'), fixture.plaintext_hex);
});

test('decryptVaultBytes reports unarmored, locked and other-vault content without throwing', async () => {
  const kr = await keyringFromHex('0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef');
  assert.deepEqual(await decryptVaultBytes('plain text', kr), { status: 'not_armored' });
  assert.deepEqual(await decryptVaultBytes(fixture.armored, kr), { status: 'other_vault' });
  const otherEpoch = fixture.armored.replace(':e1:', ':e9:');
  assert.deepEqual(await decryptVaultBytes(otherEpoch, await fixtureKeyring()), { status: 'locked' });
});

test('decryptVaultBytes rejects a token that does not authenticate', async () => {
  const kr = await keyringFromHex('0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef');
  const armored = await encryptVaultText('hello', kr);
  const tampered = armored.slice(0, -4) + (armored.endsWith('AAAA') ? 'BBBB' : 'AAAA');
  await assert.rejects(decryptVaultBytes(tampered, kr));
});

test('decryptVaultText keeps its text contract for UTF-8 content', async () => {
  const kr = await keyringFromHex('0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef');
  const armored = await encryptVaultText('héllo — ✓', kr);
  assert.equal(await decryptVaultText(armored, kr), 'héllo — ✓');
  const opened = await decryptVaultBytes(armored, kr);
  assert.ok(opened.status === 'ok');
  assert.equal(new TextDecoder().decode(opened.bytes), 'héllo — ✓');
});

// REQ-ART-2: the UI seals an uploaded html-bundle ZIP as bytes, so the viewer's Download
// returns exactly the uploaded archive, up to the 15 MB (15 MiB) artifact limit.
test('encryptVaultBytes round-trips a binary ZIP byte-for-byte, including at the 15 MiB limit', async () => {
  const kr = await keyringFromHex('0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef');
  const zipLike = Uint8Array.from([0x50, 0x4b, 0x03, 0x04, 0xff, 0xfe, 0x00, 0x80, 0xc3, 0x28]);
  const armored = await encryptVaultBytes(zipLike, kr);
  const opened = await decryptVaultBytes(armored, kr);
  assert.ok(opened.status === 'ok');
  assert.deepEqual([...opened.bytes], [...zipLike]);
  assert.deepEqual([...zipLike.subarray(0, 4)], [0x50, 0x4b, 0x03, 0x04], 'caller keeps its plaintext');

  const big = new Uint8Array(15 * 1024 * 1024);
  for (let i = 0; i < big.length; i += 1) big[i] = (i * 131 + 7) & 0xff;
  const bigOpened = await decryptVaultBytes(await encryptVaultBytes(big, kr), kr);
  assert.ok(bigOpened.status === 'ok');
  assert.equal(bigOpened.bytes.length, 15_728_640);
  assert.ok(Buffer.from(bigOpened.bytes).equals(Buffer.from(big)));
});
