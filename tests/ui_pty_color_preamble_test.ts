// REQ-PTY-COLOR-1: OSC default colours survive a repaint; a repaint without a preamble
// returns the pane to the theme defaults.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_pty_color_preamble_test.ts
//
// Without a DOM xterm has no ThemeService, so the cheapest observable of the colours it
// applies is the input handler's `onColor` event — the very event the ThemeService consumes
// (type 1 = SET, 2 = RESTORE; index 256 fg, 257 bg, 258 cursor, <256 palette).

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import * as xtermModule from '@xterm/xterm';

import {
  PTY_COLOR_RESET,
  isPaneRepaintStart,
  normalizeSnapshotText,
  repaintCapturedScreenText,
  splitPtyColorPreamble,
} from '../src/ui/components/shells/paneDeliveryQueue.ts';

const Terminal = (xtermModule as any).Terminal ?? (xtermModule as any).default.Terminal;

/** Mirror of what ThemeService does with onColor: track the applied colours. */
function observeColors(term: any) {
  const state = { bg: null as number[] | null, fg: null as number[] | null, cursor: null as number[] | null, palette: new Map<number, number[]>() };
  term._core._inputHandler.onColor((events: Array<{ type: number; index?: number; color?: number[] }>) => {
    for (const e of events) {
      if (e.type === 1) {
        if (e.index === 256) state.fg = e.color!; else if (e.index === 257) state.bg = e.color!;
        else if (e.index === 258) state.cursor = e.color!; else state.palette.set(e.index!, e.color!);
      } else if (e.type === 2) {
        if (e.index === undefined) state.palette.clear();
        else if (e.index === 256) state.fg = null; else if (e.index === 257) state.bg = null;
        else if (e.index === 258) state.cursor = null; else state.palette.delete(e.index);
      }
    }
  });
  return state;
}
const write = (term: any, text: string) => new Promise<void>((resolve) => term.write(text, resolve));

test('splitPtyColorPreamble separates the colour OSCs and nothing else', () => {
  const pre = '\x1b]4;1;rgb:ff/00/00\x07\x1b]11;#1e1e2e\x1b\\';
  const r = splitPtyColorPreamble(pre + '\x1b[?1049h\x1b[2J\x1b[Hvim');
  assert.equal(r.preamble, pre);
  assert.equal(r.rest, '\x1b[?1049h\x1b[2J\x1b[Hvim');
  assert.deepEqual(splitPtyColorPreamble('\x1b]0;title\x07x'), { preamble: '', rest: '\x1b]0;title\x07x' });
  assert.deepEqual(splitPtyColorPreamble('plain'), { preamble: '', rest: 'plain' });
  // Repaint helpers keep the preamble FIRST and still recognise the alt prefix behind it.
  assert.equal(normalizeSnapshotText(pre + '\x1b[?1049h\x1b[2J\x1b[Hvim'), pre + '\x1b[?1049h\x1b[2J\x1b[Hvim');
  assert.equal(normalizeSnapshotText(pre + 'prompt$ '), pre + '\x1b[2J\x1b[Hprompt$ ');
  assert.equal(repaintCapturedScreenText(pre + 'a\nb\n\n', 1, 1), pre + '\x1b[2J\x1b[Ha\r\nb\x1b[2;2H');
  // The replay gate sees through the reset + preamble.
  assert.ok(isPaneRepaintStart(PTY_COLOR_RESET + pre + '\x1b[2J\x1b[H'));
  assert.ok(isPaneRepaintStart(pre + '\x1b[?1049h'));
  assert.ok(!isPaneRepaintStart(pre + 'live'));
});

test('a live OSC 11 is kept by a repaint with a preamble and cleared by one without', async () => {
  const term = new Terminal({ cols: 40, rows: 5, convertEol: false });
  const colors = observeColors(term);
  let pendingReplays = 0;
  const sent: string[] = [];
  term.onData((d: string) => { if (pendingReplays > 0) return; sent.push(d); });
  const writeGated = async (text: string) => {
    const repaint = isPaneRepaintStart(text);
    if (repaint) pendingReplays += 1;
    await write(term, text);
    if (repaint) pendingReplays -= 1;
  };

  // 1. The program on the bridge machine sets its background live.
  await write(term, '\x1b]11;rgb:1e/1e/2e\x07\x1b]4;1;#ff0000\x07hello');
  assert.deepEqual(colors.bg, [30, 30, 46]);
  assert.deepEqual(colors.palette.get(1), [255, 0, 0]);

  // 2. Reconnect: the hook writes the reset, then the capture WITH its preamble (what the
  //    pty-host now emits). The background comes back exactly, the palette too.
  const capture = '\x1b]4;1;#ff0000\x07\x1b]11;rgb:1e/1e/2e\x07hello\x1b[1;6H';
  await writeGated(PTY_COLOR_RESET + normalizeSnapshotText(capture) + '\x1b[c');
  assert.deepEqual(colors.bg, [30, 30, 46], 'bg re-applied by the preamble');
  assert.deepEqual(colors.palette.get(1), [255, 0, 0]);
  assert.deepEqual(sent, [], 'DA reply inside the repaint is suppressed by the replay gate');
  assert.equal(term.buffer.active.getLine(0).translateToString(true), 'hello');

  // 3. A later repaint WITHOUT a preamble (the session reset its colours / a new session)
  //    returns to the theme defaults instead of keeping stale colours.
  await writeGated(PTY_COLOR_RESET + normalizeSnapshotText('fresh prompt$ '));
  assert.equal(colors.bg, null, 'background back to the theme default');
  assert.equal(colors.palette.size, 0, 'palette back to the theme default');
  assert.equal(term.buffer.active.getLine(0).translateToString(true).trimEnd(), 'fresh prompt$');
  term.dispose();
});

test('both stream hooks write the colour reset at the start of a repaint (source contract)', () => {
  for (const file of ['src/ui/components/shells/useShellStream.ts', 'src/ui/components/chat/useAgentStream.ts']) {
    const src = fs.readFileSync(file, 'utf8');
    assert.match(src, /if \(startsRepaint\) text = PTY_COLOR_RESET \+ text;/, `${file}: repaint starts from theme defaults`);
  }
});
