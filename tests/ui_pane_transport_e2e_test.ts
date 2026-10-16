import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { connect } from 'node:net';
import * as xtermModule from '@xterm/xterm';
import { PaneDeliveryQueue, normalizeSnapshotText, repaintCapturedScreenText } from '../src/ui/components/shells/paneDeliveryQueue.ts';
import { encryptShellStreamPayload } from '../src/ui/components/shells/useShellStream.ts';
import { PTY_WIRE_KIND_SCREEN, PtyTextDecoder, decodePtyViewerFrame, decryptPtyPayload } from '../src/ui/components/shells/ptyWire.ts';
import { importRawKeyHex } from '../src/ui/utils/vaultCrypto.ts';

// Run through scripts/test-pane-transport.sh, which builds the production fixture.
const fixture = process.env.HEIMDALL_PANE_TEST_SERVER;
const Terminal = (xtermModule as any).Terminal ?? (xtermModule as any).default.Terminal;
const key = '0123456789abcdef'.repeat(4);

test('production Hub queue and capture frames render through UI crypto and xterm', { skip: !fixture, timeout: 20000 }, async () => {
  const server = spawn(fixture!, [], { stdio: ['ignore', 'pipe', 'pipe'] });
  let logs = '';
  server.stderr.on('data', chunk => { logs += chunk; });
  const port = await new Promise<number>((resolve, reject) => {
    let output = '';
    server.stdout.on('data', chunk => {
      output += chunk;
      const match = /PANE_TEST_PORT=(\d+)/.exec(output);
      if (match) resolve(Number(match[1]));
    });
    server.once('error', reject);
    server.once('exit', code => { if (code) reject(new Error(`fixture failed: ${logs}`)); });
  });
  const socket = connect(port, '127.0.0.1');
  const term = new Terminal({ cols: 80, rows: 24, convertEol: false });
  let pending = Buffer.alloc(0);
  let frames = 0;
  let finish!: () => void;
  let fail!: (error: Error) => void;
  const completed = new Promise<void>((resolve, reject) => { finish = resolve; fail = reject; });
  const queue = new PaneDeliveryQueue(() => fail(new Error('UI delivery failed')));
  socket.on('error', fail);
  // The receive path mirrors useShellStream: binary frames are pty bytes decoded through ONE
  // streaming UTF-8 decoder; text frames are JSON control (REQ-PTY-NET-2).
  const cryptoKey = await importRawKeyHex(key);
  const textDecoder = new PtyTextDecoder();
  let previousWasSnapshot = false;
  socket.on('data', chunk => {
    pending = Buffer.concat([pending, chunk]);
    while (pending.length >= 2) {
      const opcode = pending[0] & 0x0f;
      let size = pending[1] & 0x7f;
      let header = 2;
      if (size === 126) { if (pending.length < 4) break; size = pending.readUInt16BE(2); header = 4; }
      else if (size === 127) { if (pending.length < 10) break; size = Number(pending.readBigUInt64BE(2)); header = 10; }
      if (pending.length < header + size) break;
      const body = pending.subarray(header, header + size);
      pending = pending.subarray(header + size);
      if (opcode === 0x1) {
        const message = JSON.parse(body.toString());
        if (message.type === 'ready') { void queue.whenIdle().then(finish); continue; }
        fail(new Error(`unexpected text frame ${body.toString()}`));
        return;
      }
      try {
        assert.equal(opcode, 0x2, 'pty bytes travel as binary frames');
      } catch (error) { fail(error as Error); return; }
      const frame = decodePtyViewerFrame(new Uint8Array(body.buffer, body.byteOffset, body.byteLength));
      if (!frame) { fail(new Error('malformed pty frame')); return; }
      frames++;
      queue.enqueue(size * 2, async () => {
        const bytes = frame.encrypted ? await decryptPtyPayload(frame.payload, cryptoKey) : frame.payload;
        const startsRepaint = frame.snapshot && !previousWasSnapshot;
        previousWasSnapshot = frame.snapshot;
        if (startsRepaint) textDecoder.reset();
        let text = textDecoder.decode(bytes);
        if (frame.kind === PTY_WIRE_KIND_SCREEN && frame.encrypted) text = repaintCapturedScreenText(text, frame.cursorRow, frame.cursorCol);
        else if (frame.kind !== PTY_WIRE_KIND_SCREEN && frame.snapshot && startsRepaint) text = normalizeSnapshotText(text);
        await new Promise<void>(resolve => term.write(text, resolve));
      });
    }
  });
  try {
    const old = await encryptShellStreamPayload('old output\r\n', key);
    const encryptedCapture = await encryptShellStreamPayload('hub α\nbridge β\n\n', key);
    const commands = [
      // Exercise real plaintext snapshot chunking before the encrypted capture.
      { type: 'capture', output: 'x'.repeat(70000), cursor_row: 0, cursor_col: 0 },
      { type: 'output', data_b64: old, is_encrypted: true },
      { type: 'capture', output: `vault:v1:${encryptedCapture}`, cursor_row: 1, cursor_col: 8 },
      { type: 'output', data_b64: Buffer.from(' live').toString('base64'), is_encrypted: false },
      { type: 'done' },
    ];
    socket.write(commands.map(command => JSON.stringify(command)).join('\n') + '\n');
    await completed;
    assert.ok(frames >= 5, 'plaintext capture must span multiple wire frames');
    assert.equal(term.buffer.active.getLine(term.buffer.active.baseY).translateToString(true), 'hub α');
    assert.equal(term.buffer.active.getLine(term.buffer.active.baseY + 1).translateToString(true), 'bridge β live');
    socket.write('quit\n');
  } finally {
    queue.cancel();
    socket.destroy();
    term.dispose();
    server.kill();
  }
});
