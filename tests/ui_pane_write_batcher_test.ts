// REQ-PTY-NET-7: rAF-batched term.write and the replay gate.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_pane_write_batcher_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import * as xtermModule from '@xterm/xterm';

import { PaneWriteBatcher, isPaneRepaintStart } from '../src/ui/components/shells/paneDeliveryQueue.ts';

const Terminal = (xtermModule as any).Terminal ?? (xtermModule as any).default.Terminal;

test('frames arriving within one animation frame become ONE write, in order', () => {
  const writes: string[] = [];
  const frames: Array<() => void> = [];
  const b = new PaneWriteBatcher((t) => writes.push(t), (flush) => frames.push(flush));
  b.push('a');
  b.push('b');
  b.push('c');
  assert.deepEqual(writes, []);
  assert.equal(frames.length, 1, 'one flush scheduled per frame');
  frames[0]();
  assert.deepEqual(writes, ['abc']);
  b.push('d');
  frames[1]();
  assert.deepEqual(writes, ['abc', 'd']);
});

test('a repaint always leads its own write so the replay gate can see it', () => {
  const writes: string[] = [];
  const frames: Array<() => void> = [];
  const b = new PaneWriteBatcher((t) => writes.push(t), (flush) => frames.push(flush));
  b.push('live output');
  b.push('\x1b[2J\x1b[Hrepaint', true);
  b.push(' more');
  assert.deepEqual(writes, ['live output'], 'pending output flushed BEFORE the repaint');
  for (const f of frames.splice(0)) f();
  assert.deepEqual(writes, ['live output', '\x1b[2J\x1b[Hrepaint more']);
  assert.ok(isPaneRepaintStart(writes[1]));
  assert.ok(!isPaneRepaintStart(writes[0]));
});

test('the batch is bounded and reset drops pending text', () => {
  const writes: string[] = [];
  const b = new PaneWriteBatcher((t) => writes.push(t), () => { /* never fires: hidden tab */ }, 10);
  b.push('12345');
  b.push('67890');
  assert.deepEqual(writes, ['1234567890'], 'reaching the cap forces the write even without a frame');
  b.push('x');
  b.reset();
  b.flush();
  assert.deepEqual(writes, ['1234567890']);
});

test('replay gate: xterm query replies during a repaint write are not sent as input', async () => {
  const term = new Terminal({ cols: 80, rows: 24, convertEol: false });
  let pendingReplays = 0;
  const sent: string[] = [];
  term.onData((data: string) => { if (pendingReplays > 0) return; sent.push(data); });
  const write = (text: string) => new Promise<void>((resolve) => {
    const repaint = isPaneRepaintStart(text);
    if (repaint) pendingReplays += 1;
    term.write(text, () => { if (repaint) pendingReplays = Math.max(0, pendingReplays - 1); resolve(); });
  });
  // A captured screen can contain a DA query (\x1b[c) or DSR (\x1b[6n): xterm answers them.
  await write('\x1b[2J\x1b[Hscreen\x1b[c\x1b[6n');
  assert.deepEqual(sent, [], 'auto-replies inside a repaint are suppressed');
  await write('\x1b[c');
  assert.ok(sent.length >= 1 && sent[0].startsWith('\x1b[?'), 'a live DA query still gets its reply');
  term.dispose();
});

test('both panes carry the replay gate (source contract)', () => {
  for (const file of ['src/ui/components/shells/ShellTerminalPane.tsx', 'src/ui/components/chat/AgentPaneComposerPanel.tsx']) {
    const src = fs.readFileSync(file, 'utf8');
    assert.match(src, /pendingReplaysRef\.current > 0\) return;/, `${file}: onData is gated while a repaint is pending`);
  }
  for (const file of ['src/ui/components/shells/useShellStream.ts', 'src/ui/components/chat/useAgentStream.ts']) {
    const src = fs.readFileSync(file, 'utf8');
    assert.match(src, /new PaneWriteBatcher\(/, `${file}: output goes through the write batcher`);
    assert.match(src, /writeBatcher\.push\(text, startsRepaint\)/, `${file}: a repaint starts its own write`);
  }
});
