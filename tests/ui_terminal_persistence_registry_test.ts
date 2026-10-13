/**
 * Unit & Integration Test Suite for Terminal Session Registry & Tab Persistence
 * Milestone M3: Frontend Terminal Registry & Tab Persistence
 * 
 * Verifies Requirements R3 per ORIGINAL_REQUEST.md, PROJECT.md, and explorer_m3_3/handoff.md:
 * - Suite 1: TerminalSessionRegistry Contract & Lifecycle Management
 * - Suite 2: Delta Buffering & Destructive Read Restoration Semantics
 * - Suite 3: 1MB Delta Buffer Threshold & Pruning Boundaries
 * - Suite 4: @xterm/addon-serialize Round-Trip Fidelity & Terminal Reconstruction
 * - Suite 5: Concurrent Multi-Session Isolation & Memory Hygiene
 * - Suite 6: React Component Integration & Contract Enforcement
 * 
 * RUN: node --test tests/ui_terminal_persistence_registry_test.ts
 */

import { test, describe } from 'node:test';
import assert from 'node:assert/strict';

import * as xtermModule from '@xterm/xterm';
import {
  TerminalSessionRegistry,
  terminalSessionRegistry,
  MAX_DELTA_BYTES,
  SerializeAddon,
} from '../src/ui/components/shells/terminalSessionRegistry.ts';

// Resolve Terminal across ESM/CJS boundaries
const Terminal = (xtermModule as any).Terminal || (xtermModule as any).default?.Terminal || (xtermModule as any).default;

function writeToTerminal(term: any, data: string | Uint8Array): Promise<void> {
  return new Promise((resolve) => {
    term.write(data, () => resolve());
  });
}

describe('Suite 1: TerminalSessionRegistry Contract & Lifecycle Management', () => {
  test('Test 1.1: Uninitialized query returns undefined / null', () => {
    const registry = new TerminalSessionRegistry();
    assert.equal(registry.get('non-existent'), undefined);
    assert.equal(registry.getSessionState('non-existent'), undefined);
    assert.equal(registry.consumeRestorationData('non-existent'), null);
    assert.equal(registry.hasSessionState('non-existent'), false);
  });

  test('Test 1.2: Active session registration and tracking', () => {
    const registry = new TerminalSessionRegistry();
    registry.registerActiveSession('s1');
    assert.equal(registry.isSessionActive('s1'), true);
    assert.equal(registry.isActive('s1'), true);

    registry.unregisterActiveSession('s1');
    assert.equal(registry.isSessionActive('s1'), false);
    assert.equal(registry.isActive('s1'), false);
  });

  test('Test 1.3: Snapshot capture preserves dimensions, viewport, and marks isSized', () => {
    const registry = new TerminalSessionRegistry();
    registry.saveSnapshot('s1', 'snap-content-test', 42, 120, 35);

    const saved = registry.get('s1');
    assert.ok(saved, 'saved state must exist');
    assert.equal(saved.sessionId, 's1');
    assert.equal(saved.snapshot, 'snap-content-test');
    assert.equal(saved.savedViewportY, 42);
    assert.equal(saved.scrollOffset, 42);
    assert.equal(saved.cols, 120);
    assert.equal(saved.rows, 35);
    assert.equal(saved.isSized, true);
    assert.equal(registry.hasSessionState('s1'), true);
  });

  test('Test 1.4: Idempotent snapshot update preserves queued deltas', () => {
    const registry = new TerminalSessionRegistry();
    registry.saveSnapshot('s1', 'first-snap', 10, 80, 24);
    registry.appendDelta('s1', new TextEncoder().encode('buffered delta\r\n'));

    // Update snapshot with new dimensions/viewport
    registry.saveSnapshot('s1', 'second-snap', 25, 100, 30);
    const updated = registry.get('s1')!;
    assert.equal(updated.snapshot, 'second-snap');
    assert.equal(updated.savedViewportY, 25);
    assert.equal(updated.cols, 100);
    assert.equal(updated.rows, 30);
    assert.equal(updated.deltaChunks.length, 1);
    assert.equal(new TextDecoder().decode(updated.deltaChunks[0]), 'buffered delta\r\n');
  });

  test('Test 1.5: Explicit closeSession performs complete eviction', () => {
    const registry = new TerminalSessionRegistry();
    registry.registerActiveSession('s1');
    registry.saveSnapshot('s1', 'snap', 0, 80, 24);
    registry.appendDelta('s1', new TextEncoder().encode('delta'));

    registry.closeSession('s1');
    assert.equal(registry.get('s1'), undefined);
    assert.equal(registry.consumeRestorationData('s1'), null);
    assert.equal(registry.isSessionActive('s1'), false);
    assert.equal(registry.hasSessionState('s1'), false);
  });

  test('Test 1.6: clearAll purges all sessions and active registrations, and saveSessionState safely catches unattached SerializeAddon errors', () => {
    const registry = new TerminalSessionRegistry();
    registry.registerActiveSession('s1');
    registry.registerActiveSession('s2');
    registry.saveSnapshot('s1', 'snap1', 0, 80, 24);
    registry.saveSnapshot('s2', 'snap2', 5, 100, 30);

    // Calling saveSessionState with a registered but unattached SerializeAddon catches serialize() error and saves empty snapshot + dimensions
    const unattachedAddon = new SerializeAddon();
    registry.registerSerializeAddon('s3', unattachedAddon);
    const fakeTerm = { buffer: { active: { viewportY: 12 } }, cols: 90, rows: 25 } as any;
    registry.saveSessionState('s3', fakeTerm);
    assert.equal(registry.get('s3')?.snapshot, '');
    assert.equal(registry.get('s3')?.savedViewportY, 12);
    assert.equal(registry.get('s3')?.cols, 90);
    assert.equal(registry.get('s3')?.rows, 25);
    registry.unregisterSerializeAddon('s3');

    registry.clearAll();
    assert.equal(registry.get('s1'), undefined);
    assert.equal(registry.get('s2'), undefined);
    assert.equal(registry.get('s3'), undefined);
    assert.equal(registry.isSessionActive('s1'), false);
    assert.equal(registry.isSessionActive('s2'), false);
  });
});

describe('Suite 2: Delta Buffering & Destructive Read Restoration Semantics', () => {
  test('Test 2.1: Buffering on cold session (delta arrival before snapshot)', () => {
    const registry = new TerminalSessionRegistry();
    const chunk = new TextEncoder().encode('cold delta output\r\n');
    registry.appendDelta('cold-sess', chunk);

    const state = registry.get('cold-sess');
    assert.ok(state, 'state must be initialized on delta append');
    assert.equal(state.snapshot, '');
    assert.equal(state.isSized, false);
    assert.equal(state.deltaChunks.length, 1);
    assert.equal(state.totalDeltaBytes, chunk.byteLength);
  });

  test('Test 2.2: FIFO chunk ordering preservation', () => {
    const registry = new TerminalSessionRegistry();
    const c1 = new TextEncoder().encode('chunk 1\r\n');
    const c2 = new TextEncoder().encode('chunk 2\r\n');
    const c3 = new TextEncoder().encode('chunk 3\r\n');

    registry.appendDelta('order-sess', c1);
    registry.appendDelta('order-sess', c2);
    registry.appendDelta('order-sess', c3);

    const restoration = registry.consumeRestorationData('order-sess')!;
    assert.ok(restoration);
    assert.equal(restoration.deltaChunks.length, 3);
    assert.equal(new TextDecoder().decode(restoration.deltaChunks[0]), 'chunk 1\r\n');
    assert.equal(new TextDecoder().decode(restoration.deltaChunks[1]), 'chunk 2\r\n');
    assert.equal(new TextDecoder().decode(restoration.deltaChunks[2]), 'chunk 3\r\n');
  });

  test('Test 2.3: Zero-byte chunk rejection', () => {
    const registry = new TerminalSessionRegistry();
    registry.saveSnapshot('empty-chunk-sess', 'snap', 0, 80, 24);

    registry.appendDelta('empty-chunk-sess', new Uint8Array(0));
    registry.bufferSessionDelta('empty-chunk-sess', '');
    const state = registry.get('empty-chunk-sess')!;
    assert.equal(state.deltaChunks.length, 0);
    assert.equal(state.totalDeltaBytes, 0);
  });

  test('Test 2.4: Destructive read semantics for deltaChunks', () => {
    const registry = new TerminalSessionRegistry();
    registry.saveSnapshot('destruct-sess', 'base-snapshot', 7, 80, 24);
    registry.appendDelta('destruct-sess', new TextEncoder().encode('chunk A'));
    registry.appendDelta('destruct-sess', new TextEncoder().encode('chunk B'));

    // First consumption returns snapshot and drained deltas
    const first = registry.consumeRestorationData('destruct-sess')!;
    assert.ok(first);
    assert.equal(first.snapshot, 'base-snapshot');
    assert.equal(first.savedViewportY, 7);
    assert.equal(first.deltaChunks.length, 2);

    // Second consumption preserves base snapshot and viewport but returns empty deltas
    const second = registry.consumeRestorationData('destruct-sess')!;
    assert.ok(second);
    assert.equal(second.snapshot, 'base-snapshot');
    assert.equal(second.savedViewportY, 7);
    assert.equal(second.deltaChunks.length, 0);
  });
});

describe('Suite 3: 1MB Delta Buffer Threshold & Pruning Boundaries', () => {
  test('Test 3.1: Exact 1MB boundary (1,048,576 bytes) retention', () => {
    const registry = new TerminalSessionRegistry();
    registry.saveSnapshot('bound-sess', '', 0, 80, 24);

    const halfMb = 512 * 1024;
    const chunk1 = new Uint8Array(halfMb).fill(65);
    const chunk2 = new Uint8Array(halfMb).fill(66);

    registry.appendDelta('bound-sess', chunk1);
    registry.appendDelta('bound-sess', chunk2);

    const state = registry.get('bound-sess')!;
    assert.equal(state.totalDeltaBytes, 1024 * 1024);
    assert.equal(state.deltaChunks.length, 2);
  });

  test('Test 3.2: Multi-chunk FIFO pruning exceeding 1MB', () => {
    const registry = new TerminalSessionRegistry();
    registry.saveSnapshot('prune-sess', '', 0, 80, 24);

    const halfMb = 512 * 1024;
    const chunk1 = new Uint8Array(halfMb).fill(65);
    const chunk2 = new Uint8Array(halfMb).fill(66);
    const chunk3 = new Uint8Array(halfMb).fill(67);

    registry.appendDelta('prune-sess', chunk1);
    registry.appendDelta('prune-sess', chunk2);
    registry.appendDelta('prune-sess', chunk3);

    const state = registry.get('prune-sess')!;
    assert.equal(state.totalDeltaBytes, 1024 * 1024);
    assert.equal(state.deltaChunks.length, 2);
    assert.equal(state.deltaChunks[0][0], 66, 'oldest chunk1 must be pruned');
    assert.equal(state.deltaChunks[1][0], 67, 'newest chunk3 must be retained');
  });

  test('Test 3.3: Single chunk exceeding 1MB (2MB single chunk)', () => {
    const registry = new TerminalSessionRegistry();
    const hugeChunk = new Uint8Array(2 * 1024 * 1024).fill(88); // 2 MB

    registry.appendDelta('huge-sess', hugeChunk);
    const state = registry.get('huge-sess')!;
    assert.ok(state.totalDeltaBytes <= MAX_DELTA_BYTES, `total bytes must not exceed MAX_DELTA_BYTES`);
    assert.equal(state.totalDeltaBytes, MAX_DELTA_BYTES);
    assert.equal(state.deltaChunks.length, 1);
    assert.equal(state.deltaChunks[0].byteLength, MAX_DELTA_BYTES);
  });

  test('Test 3.4: High-frequency granular delta stream (5,000 x 256-byte chunks)', () => {
    const registry = new TerminalSessionRegistry();
    const chunkSize = 256;
    const chunkCount = 5000;

    for (let i = 0; i < chunkCount; i++) {
      const chunk = new Uint8Array(chunkSize).fill(i % 256);
      registry.appendDelta('hf-sess', chunk);
    }

    const state = registry.get('hf-sess')!;
    assert.ok(state.totalDeltaBytes <= MAX_DELTA_BYTES, `total bytes (${state.totalDeltaBytes}) must be <= ${MAX_DELTA_BYTES}`);
    assert.equal(state.totalDeltaBytes, 4096 * chunkSize); // 1,048,576 bytes
    assert.equal(state.deltaChunks.length, 4096);
  });

  test('Test 3.5: Byte-level measurement accuracy', () => {
    const registry = new TerminalSessionRegistry();
    registry.bufferSessionDelta('acc-sess', 'Hello, World!'); // 13 bytes in UTF-8
    const state = registry.get('acc-sess')!;
    assert.equal(state.totalDeltaBytes, 13);
  });
});

describe('Suite 3b: REQ-FIX-7 — truncation never resumes replay mid-stream', () => {
  const enc = new TextEncoder();

  /** A real serialized snapshot to restore on top of, so these are full restoration paths. */
  async function makeSnapshot(text: string): Promise<string> {
    const term = new Terminal({ cols: 80, rows: 24 });
    const addon = new SerializeAddon();
    term.loadAddon(addon);
    await writeToTerminal(term, text);
    const snapshot = addon.serialize();
    term.dispose();
    return snapshot;
  }

  /** Every line of the rendered screen, trailing blanks dropped. */
  function renderedLines(term: any): string[] {
    const out: string[] = [];
    for (let i = 0; i < term.buffer.active.length; i++) {
      out.push(term.buffer.active.getLine(i)?.translateToString(true) ?? '');
    }
    while (out.length > 0 && out[out.length - 1] === '') out.pop();
    return out;
  }

  async function renderAll(snapshot: string, chunks: Uint8Array[]): Promise<string[]> {
    const term = new Terminal({ cols: 80, rows: 24 });
    await writeToTerminal(term, snapshot);
    for (const chunk of chunks) {
      await writeToTerminal(term, chunk);
    }
    const lines = renderedLines(term);
    term.dispose();
    return lines;
  }

  test('Test 3b.1: FIFO prune across a multi-byte character destroys the glyph, so the replay is refused', async () => {
    const registry = new TerminalSessionRegistry();
    const sid = 'cut-utf8-sess';
    const snapshot = await makeSnapshot('CLEAN BASE LINE\r\n');
    registry.saveSnapshot(sid, snapshot, 0, 80, 24);

    // '→' is E2 86 92. Chunk 1 ends on its LEAD byte; chunk 2 opens with the two continuation
    // bytes, so a prune of chunk 1 leaves the replay starting mid-code-point.
    const chunk1 = new Uint8Array(MAX_DELTA_BYTES - 1).fill(0x41); // 'A' filler
    chunk1[chunk1.length - 1] = 0xe2;
    const chunk2 = new Uint8Array([0x86, 0x92, ...enc.encode('ARROW ABOVE\r\n')]);

    registry.appendDelta(sid, chunk1);
    registry.appendDelta(sid, chunk2);

    const state = registry.get(sid)!;
    assert.ok(state.totalDeltaBytes <= MAX_DELTA_BYTES, 'cap must still bound memory');
    assert.equal(state.truncated, true, 'dropping chunk 1 must mark the state truncated');

    // What the pre-fix code replayed: the retained remainder, verbatim.
    const retained = state.deltaBuffer.map((c) => new Uint8Array(c));
    const naive = await renderAll(snapshot, retained);
    assert.ok(
      !naive.join('\n').includes('→'),
      'control: the cut must have destroyed the multi-byte character — otherwise this test ' +
        'is not exercising a mid-code-point cut at all'
    );
    assert.deepEqual(
      naive,
      ['CLEAN BASE LINE', 'ARROW ABOVE'],
      'control: the pre-fix replay renders the remainder with the glyph silently missing'
    );

    // What the fix replays: nothing. The snapshot is the only thing with a known stream state.
    const restoration = registry.consumeRestorationData(sid)!;
    assert.equal(restoration.truncated, true, 'restoration must report the truncation');
    assert.equal(restoration.deltaChunks.length, 0, 'a truncated buffer must not be replayed');

    const restored = await renderAll(restoration.snapshot, restoration.deltaChunks);
    assert.deepEqual(
      restored,
      ['CLEAN BASE LINE'],
      'the restored screen must be the clean snapshot, with no partial-character residue'
    );
  });

  test('Test 3b.2: FIFO prune across a split CSI would print control bytes as text, so the replay is refused', async () => {
    const registry = new TerminalSessionRegistry();
    const sid = 'cut-csi-sess';
    const snapshot = await makeSnapshot('CLEAN BASE LINE\r\n');
    registry.saveSnapshot(sid, snapshot, 0, 80, 24);

    // Chunk 1 ends mid-CSI, on '\x1b[3'; chunk 2 carries its tail, '1m' plus text.
    const csiHead = enc.encode('\x1b[3');
    const chunk1 = new Uint8Array(MAX_DELTA_BYTES - csiHead.length).fill(0x41);
    chunk1.set(csiHead, chunk1.length - csiHead.length);
    const chunk2 = enc.encode('1mRED ALERT\r\n');

    registry.appendDelta(sid, chunk1);
    registry.appendDelta(sid, chunk2);

    const state = registry.get(sid)!;
    assert.ok(state.totalDeltaBytes <= MAX_DELTA_BYTES, 'cap must still bound memory');
    assert.equal(state.truncated, true, 'dropping chunk 1 must mark the state truncated');

    const retained = state.deltaBuffer.map((c) => new Uint8Array(c));
    const naive = await renderAll(snapshot, retained);
    assert.ok(
      naive.join('\n').includes('1mRED ALERT'),
      'control: the orphaned CSI tail must render as literal text — this is the garbled screen ' +
        'the cap used to produce once a backgrounded tab got busy enough to prune'
    );

    const restoration = registry.consumeRestorationData(sid)!;
    assert.equal(restoration.truncated, true, 'restoration must report the truncation');
    assert.equal(restoration.deltaChunks.length, 0, 'a truncated buffer must not be replayed');

    const restored = await renderAll(restoration.snapshot, restoration.deltaChunks);
    assert.ok(
      !restored.join('\n').includes('1mRED'),
      'the restored screen must not contain the orphaned escape payload as text'
    );
    assert.deepEqual(restored, ['CLEAN BASE LINE'], 'the clean snapshot is what gets restored');
  });

  test('Test 3b.3: the tail-slice vector (single chunk over the cap) is truncated the same way', async () => {
    const registry = new TerminalSessionRegistry();
    const sid = 'slice-sess';
    const snapshot = await makeSnapshot('CLEAN BASE LINE\r\n');
    registry.saveSnapshot(sid, snapshot, 0, 80, 24);

    // One oversized chunk: bufferSessionDelta keeps its tail, cutting at an arbitrary offset.
    const oversized = new Uint8Array(MAX_DELTA_BYTES + 16).fill(0x41);
    oversized.set(enc.encode('\x1b[31m'), MAX_DELTA_BYTES + 11);
    registry.appendDelta(sid, oversized);

    const state = registry.get(sid)!;
    assert.equal(state.totalDeltaBytes, MAX_DELTA_BYTES, 'the slice still enforces the cap');
    assert.equal(state.truncated, true, 'slicing a chunk drops bytes and must mark truncated');

    const restoration = registry.consumeRestorationData(sid)!;
    assert.equal(restoration.truncated, true);
    assert.equal(restoration.deltaChunks.length, 0);
    assert.deepEqual(await renderAll(restoration.snapshot, restoration.deltaChunks), ['CLEAN BASE LINE']);
  });

  test('Test 3b.4: an UNtruncated buffer still replays in full, and a drain re-anchors the stream', async () => {
    const registry = new TerminalSessionRegistry();
    const sid = 'intact-sess';
    const snapshot = await makeSnapshot('CLEAN BASE LINE\r\n');
    registry.saveSnapshot(sid, snapshot, 0, 80, 24);

    // Exactly at the cap: nothing is dropped, so the replay must be complete — the fix must not
    // degrade into "never replay anything".
    const tail = enc.encode('\r\nINTACT \u2192 TAIL\r\n');
    const half = MAX_DELTA_BYTES / 2;
    registry.appendDelta(sid, new Uint8Array(half).fill(0x41));
    registry.appendDelta(sid, new Uint8Array(half - tail.byteLength).fill(0x41));
    registry.appendDelta(sid, tail);

    assert.equal(
      registry.get(sid)!.totalDeltaBytes,
      MAX_DELTA_BYTES,
      'this test is only meaningful if it lands exactly ON the cap without crossing it'
    );

    const state = registry.get(sid)!;
    assert.equal(state.truncated, false, 'nothing was dropped, so nothing is truncated');

    const restoration = registry.consumeRestorationData(sid)!;
    assert.equal(restoration.truncated, false);
    assert.equal(restoration.deltaChunks.length, 3, 'all three chunks must be replayed');
    const restored = await renderAll(restoration.snapshot, restoration.deltaChunks);
    assert.ok(
      restored.some((l) => l.includes('INTACT → TAIL')),
      'an intact multi-byte character must survive the round trip verbatim'
    );

    // The drain re-anchors: bytes buffered afterwards are contiguous again and replay normally.
    assert.equal(registry.get(sid)!.truncated, false);
    registry.appendDelta(sid, enc.encode('POST DRAIN\r\n'));
    const second = registry.consumeRestorationData(sid)!;
    assert.equal(second.truncated, false);
    assert.equal(new TextDecoder().decode(second.deltaChunks[0]), 'POST DRAIN\r\n');
  });

  test('Test 3b.5: a truncation survives an intervening snapshot save', () => {
    const registry = new TerminalSessionRegistry();
    const sid = 'persist-trunc-sess';

    registry.appendDelta(sid, new Uint8Array(MAX_DELTA_BYTES).fill(0x41));
    registry.appendDelta(sid, new Uint8Array(32).fill(0x42));
    assert.equal(registry.get(sid)!.truncated, true);

    // An unmount snapshot must not launder away an overflow that already happened.
    registry.saveSnapshot(sid, 'snap-after-overflow', 0, 80, 24);
    assert.equal(registry.get(sid)!.truncated, true, 'saveSnapshot must preserve the flag');

    const restoration = registry.consumeRestorationData(sid)!;
    assert.equal(restoration.truncated, true);
    assert.equal(restoration.deltaChunks.length, 0);
    assert.equal(restoration.snapshot, 'snap-after-overflow');
  });
});

describe('Suite 4: @xterm/addon-serialize Round-Trip Fidelity & Terminal Reconstruction', () => {
  test('Test 4.1: Plain text scrollback round-trip', async () => {
    const term1 = new Terminal({ cols: 80, rows: 24 });
    const addon1 = new SerializeAddon();
    term1.loadAddon(addon1);

    for (let i = 1; i <= 50; i++) {
      await writeToTerminal(term1, `scrollback line ${i}\r\n`);
    }

    const serialized = addon1.serialize();
    const registry = new TerminalSessionRegistry();
    registry.saveSnapshot('sess-scroll', serialized, term1.buffer.active.viewportY, term1.cols, term1.rows);

    const restored = registry.consumeRestorationData('sess-scroll')!;
    const term2 = new Terminal({ cols: 80, rows: 24 });
    await writeToTerminal(term2, restored.snapshot);

    assert.equal(term2.buffer.active.baseY, term1.buffer.active.baseY);
    assert.equal(
      term2.buffer.active.getLine(0)?.translateToString(true),
      term1.buffer.active.getLine(0)?.translateToString(true)
    );

    term1.dispose();
    term2.dispose();
  });

  test('Test 4.2: ANSI styles & 24-bit TrueColor fidelity', async () => {
    const term1 = new Terminal({ cols: 80, rows: 24 });
    const addon1 = new SerializeAddon();
    term1.loadAddon(addon1);

    await writeToTerminal(term1, '\x1b[1;31mBold Red\x1b[0m \x1b[38;2;255;100;50mTrueColor\x1b[0m\r\n');
    const serialized = addon1.serialize();

    const term2 = new Terminal({ cols: 80, rows: 24 });
    await writeToTerminal(term2, serialized);

    const line = term2.buffer.active.getLine(0)?.translateToString(true);
    assert.ok(line?.includes('Bold Red TrueColor'));

    term1.dispose();
    term2.dispose();
  });

  test('Test 4.3: Alternate screen buffer (Neovim / TUI) round-trip', async () => {
    const term1 = new Terminal({ cols: 80, rows: 24 });
    const addon1 = new SerializeAddon();
    term1.loadAddon(addon1);

    // Enter alternate buffer and write content
    await writeToTerminal(term1, '\x1b[?1049h\x1b[H=== NEOVIM BUFFER ===\x1b[24;1H[STATUS BAR]');
    const serialized = addon1.serialize();

    const term2 = new Terminal({ cols: 80, rows: 24 });
    await writeToTerminal(term2, serialized);

    const firstLine = term2.buffer.active.getLine(0)?.translateToString(true);
    assert.ok(firstLine?.includes('=== NEOVIM BUFFER ==='));

    term1.dispose();
    term2.dispose();
  });

  test('Test 4.4: Snapshot + Delta sequential replay', async () => {
    const term1 = new Terminal({ cols: 80, rows: 24 });
    const addon1 = new SerializeAddon();
    term1.loadAddon(addon1);

    await writeToTerminal(term1, 'Base Initial Output\r\n');
    const snap = addon1.serialize();

    const registry = new TerminalSessionRegistry();
    registry.saveSnapshot('seq-sess', snap, 0, 80, 24);
    registry.appendDelta('seq-sess', new TextEncoder().encode('Delta Line 1\r\n'));
    registry.appendDelta('seq-sess', new TextEncoder().encode('Delta Line 2\r\n'));

    const restoration = registry.consumeRestorationData('seq-sess')!;
    const term2 = new Terminal({ cols: 80, rows: 24 });
    await writeToTerminal(term2, restoration.snapshot);
    for (const chunk of restoration.deltaChunks) {
      await writeToTerminal(term2, chunk);
    }

    const line0 = term2.buffer.active.getLine(0)?.translateToString(true);
    const line1 = term2.buffer.active.getLine(1)?.translateToString(true);
    const line2 = term2.buffer.active.getLine(2)?.translateToString(true);

    assert.equal(line0, 'Base Initial Output');
    assert.equal(line1, 'Delta Line 1');
    assert.equal(line2, 'Delta Line 2');

    term1.dispose();
    term2.dispose();
  });
});

describe('Suite 5: Concurrent Multi-Session Isolation & Memory Hygiene', () => {
  test('Test 5.1: Multi-session concurrent writes isolation', () => {
    const registry = new TerminalSessionRegistry();
    registry.saveSnapshot('sess-A', 'snapA', 0, 80, 24);
    registry.saveSnapshot('sess-B', 'snapB', 0, 80, 24);
    registry.saveSnapshot('sess-C', 'snapC', 0, 80, 24);

    registry.appendDelta('sess-A', new TextEncoder().encode('dA1'));
    registry.appendDelta('sess-B', new TextEncoder().encode('dB1'));
    registry.appendDelta('sess-C', new TextEncoder().encode('dC1'));

    const rA = registry.consumeRestorationData('sess-A')!;
    const rB = registry.consumeRestorationData('sess-B')!;
    const rC = registry.consumeRestorationData('sess-C')!;

    assert.equal(rA.snapshot, 'snapA');
    assert.equal(new TextDecoder().decode(rA.deltaChunks[0]), 'dA1');

    assert.equal(rB.snapshot, 'snapB');
    assert.equal(new TextDecoder().decode(rB.deltaChunks[0]), 'dB1');

    assert.equal(rC.snapshot, 'snapC');
    assert.equal(new TextDecoder().decode(rC.deltaChunks[0]), 'dC1');
  });

  test('Test 5.2: Shared buffer mutation protection (defensive isolation)', () => {
    const registry = new TerminalSessionRegistry();
    const mutable = new Uint8Array([1, 2, 3, 4]);

    registry.appendDelta('mut-sess', mutable);
    mutable[0] = 99; // mutate original

    const restoration = registry.consumeRestorationData('mut-sess')!;
    assert.equal(restoration.deltaChunks[0][0], 1, 'mutating original array must not corrupt buffered delta');
  });

  test('Test 5.3: Selective termination isolation', () => {
    const registry = new TerminalSessionRegistry();
    registry.saveSnapshot('keep1', 'snap1', 0, 80, 24);
    registry.saveSnapshot('killMe', 'snapKill', 0, 80, 24);
    registry.saveSnapshot('keep2', 'snap2', 0, 80, 24);

    registry.closeSession('killMe');
    assert.equal(registry.get('killMe'), undefined);
    assert.ok(registry.get('keep1'));
    assert.ok(registry.get('keep2'));
  });

  test('Test 5.4: Singleton instance verification', () => {
    assert.ok(terminalSessionRegistry instanceof TerminalSessionRegistry);
    terminalSessionRegistry.saveSnapshot('singleton-test', 'snap', 0, 80, 24);
    assert.ok(terminalSessionRegistry.get('singleton-test'));
    terminalSessionRegistry.closeSession('singleton-test');
    assert.equal(terminalSessionRegistry.get('singleton-test'), undefined);
  });
});

describe('Suite 6: Module Exports Contract', () => {
  test('Test 6.1: Module exports contract', () => {
    assert.ok(typeof TerminalSessionRegistry === 'function');
    assert.ok(typeof terminalSessionRegistry === 'object');
    assert.equal(MAX_DELTA_BYTES, 1024 * 1024);
    assert.ok(typeof SerializeAddon === 'function');
  });
});
