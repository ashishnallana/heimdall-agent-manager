// REQ-PTY-NET-2: binary pty viewer frames on the browser side.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_pty_wire_test.ts

import { keyringFromHex } from './helpers/vaultTestKeyring.ts';
import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as xtermModule from '@xterm/xterm';

import {
  PTY_WIRE_FLAG_CURSOR,
  PTY_WIRE_FLAG_ENCRYPTED,
  PTY_WIRE_FLAG_SNAPSHOT,
  PTY_WIRE_KIND_INPUT,
  PTY_WIRE_KIND_OUTPUT,
  PTY_WIRE_KIND_SCREEN,
  PtyTextDecoder,
  decodePtyViewerFrame,
  decryptPtyPayload,
  encodePtyViewerFrame,
  encryptPtyPayload,
} from '../src/ui/components/shells/ptyWire.ts';
import { normalizeSnapshotText, repaintCapturedScreenText } from '../src/ui/components/shells/paneDeliveryQueue.ts';
import { importRawKeyHex } from '../src/ui/utils/vaultCrypto.ts';

const Terminal = (xtermModule as any).Terminal ?? (xtermModule as any).default.Terminal;
const enc = new TextEncoder();

test('decodePtyViewerFrame parses kind, flags, cursor block and payload view', () => {
  const plain = decodePtyViewerFrame(new Uint8Array([PTY_WIRE_KIND_OUTPUT, 0, 0x68, 0x69]));
  assert.ok(plain);
  assert.equal(plain!.kind, PTY_WIRE_KIND_OUTPUT);
  assert.equal(plain!.snapshot, false);
  assert.equal(plain!.encrypted, false);
  assert.equal(plain!.cursorRow, -1);
  assert.deepEqual(Array.from(plain!.payload), [0x68, 0x69]);

  // SCREEN | SNAPSHOT | ENCRYPTED | CURSOR with row 3, col 258.
  const withCursor = decodePtyViewerFrame(new Uint8Array([
    PTY_WIRE_KIND_SCREEN, PTY_WIRE_FLAG_SNAPSHOT | PTY_WIRE_FLAG_ENCRYPTED | PTY_WIRE_FLAG_CURSOR,
    0x00, 0x03, 0x01, 0x02, 0xaa, 0xbb,
  ]));
  assert.ok(withCursor);
  assert.equal(withCursor!.snapshot, true);
  assert.equal(withCursor!.encrypted, true);
  assert.equal(withCursor!.cursorRow, 3);
  assert.equal(withCursor!.cursorCol, 258);
  assert.deepEqual(Array.from(withCursor!.payload), [0xaa, 0xbb]);

  // Too short for its own header.
  assert.equal(decodePtyViewerFrame(new Uint8Array([1])), null);
  assert.equal(decodePtyViewerFrame(new Uint8Array([PTY_WIRE_KIND_SCREEN, PTY_WIRE_FLAG_CURSOR, 0, 0])), null);
  // ArrayBuffer input (what a WebSocket with binaryType=arraybuffer delivers).
  const fromBuffer = decodePtyViewerFrame(new Uint8Array([PTY_WIRE_KIND_OUTPUT, PTY_WIRE_FLAG_SNAPSHOT, 0x41]).buffer);
  assert.equal(fromBuffer!.snapshot, true);
});

test('encodePtyViewerFrame round-trips an input frame', () => {
  const frame = encodePtyViewerFrame(PTY_WIRE_KIND_INPUT, PTY_WIRE_FLAG_ENCRYPTED, new Uint8Array([1, 2, 3]));
  assert.deepEqual(Array.from(frame), [PTY_WIRE_KIND_INPUT, PTY_WIRE_FLAG_ENCRYPTED, 1, 2, 3]);
  const back = decodePtyViewerFrame(frame);
  assert.equal(back!.kind, PTY_WIRE_KIND_INPUT);
  assert.equal(back!.encrypted, true);
  assert.deepEqual(Array.from(back!.payload), [1, 2, 3]);
});

test('PtyTextDecoder keeps a multi-byte character split across two frames whole', () => {
  const decoder = new PtyTextDecoder();
  const bytes = enc.encode('a λ b 😀 c'); // λ = 2 bytes, 😀 = 4 bytes
  // Cut inside λ and inside 😀.
  const lambdaStart = 2;
  const emojiStart = bytes.indexOf(0xf0);
  const parts = [
    bytes.subarray(0, lambdaStart + 1),
    bytes.subarray(lambdaStart + 1, emojiStart + 2),
    bytes.subarray(emojiStart + 2),
  ];
  const out = parts.map(p => decoder.decode(p)).join('');
  assert.equal(out, 'a λ b 😀 c');
  assert.ok(!out.includes('\ufffd'));

  // A fresh TextDecoder per frame would have produced replacement characters — that is the
  // bug this class exists to prevent.
  const naive = parts.map(p => new TextDecoder().decode(p)).join('');
  assert.ok(naive.includes('\ufffd'));

  // reset() drops a pending partial so a new absolute repaint starts clean.
  decoder.decode(bytes.subarray(lambdaStart, lambdaStart + 1));
  decoder.reset();
  assert.equal(decoder.decode(enc.encode('\x1b[2J\x1b[Hfresh')), '\x1b[2J\x1b[Hfresh');
});

test('decryptPtyPayload opens a v2 payload (epoch | nonce | tag | ct) bound to session and direction', async () => {
  const kr = await keyringFromHex('0123456789abcdef'.repeat(4));
  const sealed = await encryptPtyPayload(enc.encode('secret λ'), kr, 'shs_1');
  assert.equal(sealed.length, 4 + 12 + 16 + enc.encode('secret λ').length);
  const plain = await decryptPtyPayload(sealed, kr, 'shs_1', 'in');
  assert.equal(new TextDecoder().decode(plain!), 'secret λ');
  await assert.rejects(decryptPtyPayload(sealed, kr, 'shs_1', 'out'));
  await assert.rejects(decryptPtyPayload(sealed, kr, 'shs_2', 'in'));
  await assert.rejects(decryptPtyPayload(sealed.subarray(0, 20), kr, 'shs_1', 'in'));
  sealed[sealed.length - 1] ^= 0x01;
  await assert.rejects(decryptPtyPayload(sealed, kr, 'shs_1', 'in'));
});

test('snapshot text helpers produce absolute repaints without a byte round-trip', async () => {
  assert.equal(normalizeSnapshotText('hello'), '\x1b[2J\x1b[Hhello');
  assert.equal(normalizeSnapshotText('\x1b[2J\x1b[Hhello'), '\x1b[2J\x1b[Hhello');
  assert.equal(normalizeSnapshotText('\x1b[?1049hvim'), '\x1b[?1049h\x1b[2J\x1b[Hvim');
  assert.equal(repaintCapturedScreenText('hub α\nbridge β\n\n', 1, 8), '\x1b[2J\x1b[Hhub α\r\nbridge β\x1b[2;9H');

  const term = new Terminal({ cols: 80, rows: 24, convertEol: false });
  const decoder = new PtyTextDecoder();
  const capture = enc.encode('\x1b[2J\x1b[Hrow λ one\r\nrow β two');
  // Chunked at a byte boundary inside λ, like a 32 KiB screen cut can be.
  const cut = capture.indexOf(0xce) + 1;
  const write = (t: string) => new Promise<void>(resolve => term.write(t, resolve));
  await write(decoder.decode(capture.subarray(0, cut)));
  await write(decoder.decode(capture.subarray(cut)));
  assert.equal(term.buffer.active.getLine(0).translateToString(true), 'row λ one');
  assert.equal(term.buffer.active.getLine(1).translateToString(true), 'row β two');
  term.dispose();
});
