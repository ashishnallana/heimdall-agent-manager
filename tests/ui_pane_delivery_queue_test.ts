import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as xtermModule from '@xterm/xterm';
import {
  PaneDeliveryQueue,
  normalizeSnapshotBytes,
  repaintCapturedScreen,
  splitPaneInput,
} from '../src/ui/components/shells/paneDeliveryQueue.ts';
import { decryptShellStreamPayload } from '../src/ui/components/shells/useShellStream.ts';
import { sealPtyPayload } from '../src/ui/components/shells/ptyWire.ts';
import { bytesToBase64 } from '../src/ui/utils/vaultCrypto.ts';
import { keyringFromHex } from './helpers/vaultTestKeyring.ts';

const Terminal = (xtermModule as any).Terminal ?? (xtermModule as any).default.Terminal;
const key = await keyringFromHex('0123456789abcdef'.repeat(4));
const SESSION = 'shs_pane_test';
// Bridge output frames: PTY v2, `out` direction, epoch 1.
const encryptShellStreamPayload = async (value: string) =>
  bytesToBase64(await sealPtyPayload(new TextEncoder().encode(value), key.keys.get(1)!, 1, SESSION, 'out'));
const text = (value: string) => new TextEncoder().encode(value);
const write = (term: any, bytes: Uint8Array): Promise<void> => new Promise(resolve => term.write(bytes, resolve));

test('encrypted output, capture repaint and following plaintext render in wire order', async () => {
  const term = new Terminal({ cols: 80, rows: 24, convertEol: false });
  const queue = new PaneDeliveryQueue(() => assert.fail('queue unexpectedly failed'));
  const oldOutput = await encryptShellStreamPayload('obsolete\r\n');
  const capture = await encryptShellStreamPayload('hub α\nbridge β\n\n');
  queue.enqueue(oldOutput.length * 2, async () => {
    await new Promise(resolve => setTimeout(resolve, 20));
    await write(term, (await decryptShellStreamPayload(oldOutput, key, SESSION))!);
  });
  queue.enqueue(capture.length * 2, async () => {
    const bytes = (await decryptShellStreamPayload(capture, key, SESSION))!;
    await write(term, repaintCapturedScreen(bytes, 1, 8));
  });
  queue.enqueue(20, async () => { await write(term, text(' live')); });
  await queue.whenIdle();
  assert.equal(term.buffer.active.getLine(0).translateToString(true), 'hub α');
  assert.equal(term.buffer.active.getLine(1).translateToString(true), 'bridge β live');
  assert.equal(queue.queuedBytes, 0);
  term.dispose();
});

test('overflow discards queued work and invokes reconnect once', async () => {
  let release!: () => void;
  let recoveries = 0;
  const delivered: string[] = [];
  const queue = new PaneDeliveryQueue(() => recoveries++, 32);
  queue.enqueue(16, async () => { await new Promise<void>(resolve => { release = resolve; }); });
  queue.enqueue(16, async () => { delivered.push('obsolete'); });
  assert.equal(queue.enqueue(1, async () => {}), false);
  assert.equal(queue.enqueue(1, async () => {}), false);
  assert.equal(recoveries, 1);
  assert.equal(queue.queuedBytes, 16, 'in-flight data remains accounted until completion');
  release();
  await queue.whenIdle();
  assert.deepEqual(delivered, []);
  assert.equal(queue.queuedBytes, 0);
  const fresh = new PaneDeliveryQueue(() => assert.fail('fresh queue failed'));
  fresh.enqueue(4, async () => { delivered.push('fresh snapshot'); });
  await fresh.whenIdle();
  assert.deepEqual(delivered, ['fresh snapshot']);
});

test('chunked repaint preserves Unicode and ANSI colors', async () => {
  const term = new Terminal({ cols: 80, rows: 24, convertEol: false });
  const bytes = repaintCapturedScreen(text('\x1b[32mgreen λ\x1b[0m\nnext row'), 1, 8);
  const queue = new PaneDeliveryQueue(() => assert.fail('queue failed'));
  // Split inside a UTF-8 character and inside ANSI sequences, as the wire may do.
  for (let offset = 0; offset < bytes.length; offset += 3) {
    const part = bytes.slice(offset, offset + 3);
    queue.enqueue(part.length, () => write(term, part));
  }
  await queue.whenIdle();
  assert.equal(term.buffer.active.getLine(0).translateToString(true), 'green λ');
  assert.equal(term.buffer.active.getLine(1).translateToString(true), 'next row');
  term.dispose();
});

test('large pasted input is bounded and preserves Unicode at chunk boundaries', () => {
  const original = 'x'.repeat(8191) + '😀' + 'λ'.repeat(80000);
  const parts = splitPaneInput(original);
  assert.equal(parts.join(''), original);
  for (const part of parts) {
    assert.ok(part.length <= 8192);
    assert.ok(Buffer.byteLength(part, 'utf8') < 32 * 1024);
    assert.equal(new TextDecoder().decode(new TextEncoder().encode(part)), part);
  }
});

test('test_repaintCapturedScreen_full_height_tui_does_not_scroll_top_row_off_screen', async () => {
  // Arrange: 24-row Neovim-style full-height TUI screen where row 0 is line 1 and row 23 is status bar
  const term = new Terminal({ cols: 80, rows: 24, convertEol: false });
  const rows = Array.from({ length: 24 }, (_, i) =>
    i === 0 ? '1   fn main() {' : i === 23 ? '-- NORMAL --                                            1,1           All' : `~`
  );

  // Act: format and write captured screen
  const payload = repaintCapturedScreen(text(rows.join('\n')), 0, 4);
  await write(term, payload);

  // Assert: row 0 is still intact (not scrolled off by a trailing CRLF) and baseY is 0
  assert.equal(term.buffer.active.baseY, 0);
  assert.equal(term.buffer.active.getLine(0).translateToString(true), '1   fn main() {');
  assert.equal(
    term.buffer.active.getLine(23).translateToString(true),
    '-- NORMAL --                                            1,1           All'
  );
  assert.equal(term.buffer.active.cursorY, 0);
  assert.equal(term.buffer.active.cursorX, 4);
  term.dispose();
});

test('test_repaintCapturedScreen_alt_buffer_switches_before_erase_and_restores_primary_on_exit', async () => {
  // Arrange: primary buffer has shell history
  const term = new Terminal({ cols: 80, rows: 24, convertEol: false });
  await write(term, text('user@host:~$ nvim file.rs\r\n'));
  assert.equal(term.buffer.active.type, 'normal');

  // Act 1: receive an alternate-screen snapshot (\x1b[?1049h prefix from vt.rs)
  const altCapture = repaintCapturedScreen(
    text('\x1b[?1049h\x1b[?25l1   pub struct Screen {\n~\n-- NORMAL --'),
    0,
    4
  );
  await write(term, altCapture);

  // Assert 1: xterm is in alternate buffer with TUI rendered
  assert.equal(term.buffer.active.type, 'alternate');
  assert.equal(term.buffer.active.getLine(0).translateToString(true), '1   pub struct Screen {');
  assert.equal(term.buffer.active.getLine(2).translateToString(true), '-- NORMAL --');

  // Act 2: exit Neovim (\x1b[?1049l)
  await write(term, text('\x1b[?1049l\x1b[?25h'));

  // Assert 2: xterm returns to normal buffer and original shell prompt was NOT erased by \x1b[2J
  assert.equal(term.buffer.active.type, 'normal');
  assert.equal(term.buffer.active.getLine(0).translateToString(true), 'user@host:~$ nvim file.rs');
  term.dispose();
});

test('test_normalizeSnapshotBytes_makes_bridge_snapshot_idempotent_without_scrollback_duplication', async () => {
  const term = new Terminal({ cols: 80, rows: 4, convertEol: false });
  const rawBridgeSnapshot = text('row1\r\nrow2\r\nrow3\r\nrow4\x1b[4;5H');

  // Act: write normalized bridge catch-up snapshot twice
  await write(term, normalizeSnapshotBytes(rawBridgeSnapshot));
  await write(term, normalizeSnapshotBytes(rawBridgeSnapshot));

  // Assert: baseY stays 0 (no duplicate lines pushed into scrollback)
  assert.equal(term.buffer.active.baseY, 0);
  assert.equal(term.buffer.active.getLine(0).translateToString(true), 'row1');
  assert.equal(term.buffer.active.getLine(3).translateToString(true), 'row4');
  term.dispose();
});
