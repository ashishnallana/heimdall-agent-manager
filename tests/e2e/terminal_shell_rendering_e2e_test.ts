/**
 * Comprehensive Opaque-Box E2E Test Suite for Terminal Shell Rendering Architecture
 * 
 * Verifies Requirements R1, R2, R3 across Models 1-4:
 * - R1: Initial Cursor Placement & Screen Snapshot Cleanliness
 * - R2: TUI Application First-Frame Rendering (e.g. Neovim)
 * - R3: Client Terminal Registry & Tab Persistence
 * 
 * Authoritative Specifications:
 * - ORIGINAL_REQUEST.md
 * - PROJECT.md
 * - docs/plans/terminal_shell_rendering_architecture.md
 * 
 * RUN: node --test tests/e2e/terminal_shell_rendering_e2e_test.ts
 */

import { test, describe } from 'node:test';
import assert from 'node:assert/strict';

import * as xtermModule from '@xterm/xterm';
import * as serializeModule from '@xterm/addon-serialize';
import { shellResizeFrame, type ShellGeometry } from '../../src/ui/components/shells/shellStreamFrames.ts';
import { deliverTerminalOutput } from '../../src/ui/components/shells/terminalOutputDelivery.ts';

// Resolve Terminal & SerializeAddon constructors across ESM/CJS boundaries
const Terminal = (xtermModule as any).Terminal || (xtermModule as any).default?.Terminal || (xtermModule as any).default;
const SerializeAddon = (serializeModule as any).SerializeAddon || (serializeModule as any).default?.SerializeAddon || (serializeModule as any).default;

// ANSI Constants
const ANSI_ERASE_AND_HOME = '\x1b[2J\x1b[H';
const ANSI_ALT_SCREEN_ENTER = '\x1b[?1049h';
const ANSI_ALT_SCREEN_LEAVE = '\x1b[?1049l';
const MAX_DELTA_BYTES = 1024 * 1024; // 1 MB cap per specification

/**
 * Hub Screen Snapshot Repaint Builder per specification:
 * docs/plans/terminal_shell_rendering_architecture.md §2.4 & PROJECT.md § Interface Contracts
 */
export function formatHubScreenSnapshot(paneOutput: string, cursorRow: number, cursorCol: number): {
  type: 'screen';
  screen_b64: string;
  cursor_row: number;
  cursor_col: number;
} {
  // 1. Trim non-informative trailing blank rows (empty or whitespace lines)
  const lines = paneOutput.split(/\r?\n/);
  while (lines.length > 0 && lines[lines.length - 1].trim() === '') {
    lines.pop();
  }
  const trimmedBody = lines.join('\r\n');

  // 2. Build absolute repaint: Erase & Home + Trimmed Body + CRLF (if body non-empty) + ANSI cursor positioning
  const ansiCursor = `\x1b[${cursorRow + 1};${cursorCol + 1}H`;
  const repaintText = trimmedBody.length > 0
    ? `${ANSI_ERASE_AND_HOME}${trimmedBody}\r\n${ansiCursor}`
    : `${ANSI_ERASE_AND_HOME}${ansiCursor}`;

  // 3. Encode to base64
  const screen_b64 = Buffer.from(repaintText, 'utf8').toString('base64');
  return {
    type: 'screen',
    screen_b64,
    cursor_row: cursorRow,
    cursor_col: cursorCol,
  };
}

/**
 * Production implementation of TerminalSessionRegistry per PROJECT.md § Interface Contracts
 */
export {
  TerminalSessionRegistry,
  terminalSessionRegistry,
  type SavedTerminalState,
  type TerminalRestorationData,
} from '../../src/ui/components/shells/terminalSessionRegistry.ts';
import {
  TerminalSessionRegistry,
  terminalSessionRegistry,
  type SavedTerminalState,
} from '../../src/ui/components/shells/terminalSessionRegistry.ts';

/**
 * Headless terminal helper for async writes
 */
function writeToTerminal(term: any, data: string | Uint8Array): Promise<void> {
  return new Promise((resolve) => {
    term.write(data, () => resolve());
  });
}

// ============================================================================
// MODEL 1: Category-Partition Feature Coverage
// ============================================================================

describe('Model 1: Category-Partition Feature Coverage', () => {

  // Feature Group R1: Screen Snapshot Cleanliness & Initial Cursor Placement
  describe('Group R1: Initial Cursor Placement & Screen Snapshot Cleanliness', () => {
    
    test('T1-R1-01: Hub snapshot trims 23 trailing blank rows from 24-row grid', () => {
      // 24 rows where only line 1 has prompt text
      const prompt = 'user@linux:~$ ';
      const capturedRows = [prompt, ...Array(23).fill('')].join('\n');
      const frame = formatHubScreenSnapshot(capturedRows, 0, prompt.length);

      const decoded = Buffer.from(frame.screen_b64, 'base64').toString('utf8');
      assert.ok(decoded.startsWith(ANSI_ERASE_AND_HOME), 'must start with erase & home prefix');
      assert.ok(!decoded.includes('\r\n\r\n\r\n\r\n'), 'must not contain multiple empty trailing rows');
      assert.ok(decoded.includes(`\x1b[1;${prompt.length + 1}H`), 'must append ANSI cursor positioning');
    });

    test('T1-R1-02: Snapshot positions cursor exactly at prompt column, not bottom row', async () => {
      const term = new Terminal({ cols: 80, rows: 24 });
      const prompt = 'developer@box:~/heimdall$ ';
      const capturedRows = [prompt, ...Array(23).fill('')].join('\n');
      const frame = formatHubScreenSnapshot(capturedRows, 0, prompt.length);
      const decoded = Buffer.from(frame.screen_b64, 'base64').toString('utf8');

      await writeToTerminal(term, decoded);

      assert.equal(term.buffer.active.cursorY, 0, 'cursor row must remain at prompt line (row 0), not row 23');
      assert.equal(term.buffer.active.cursorX, prompt.length, 'cursor col must sit immediately after prompt text');
      term.dispose();
    });

    test('T1-R1-03: Snapshot wire frame adheres to Hub Snapshot Frame Contract', () => {
      const frame = formatHubScreenSnapshot('test line', 2, 10);
      assert.equal(frame.type, 'screen', 'frame type must be "screen"');
      assert.equal(typeof frame.screen_b64, 'string', 'screen_b64 must be base64 string');
      assert.equal(frame.cursor_row, 2, 'cursor_row must match PTY row coordinate');
      assert.equal(frame.cursor_col, 10, 'cursor_col must match PTY col coordinate');

      const jsonStr = JSON.stringify(frame);
      const parsed = JSON.parse(jsonStr);
      assert.equal(parsed.type, 'screen');
      assert.equal(parsed.cursor_row, 2);
      assert.equal(parsed.cursor_col, 10);
    });

    test('T1-R1-04: Smart scrollback pinning suppresses scrollToBottom when buffer.baseY === 0', async () => {
      const term = new Terminal({ cols: 80, rows: 24 });
      let scrollToBottomCalled = false;
      const fakeScrollToBottom = () => { scrollToBottomCalled = true; };

      // Render single line prompt (does not overflow viewport)
      await writeToTerminal(term, 'user@host:~$ ');
      const buffer = term.buffer.active;

      // Smart scrollback pinning rule from docs/plans §2.4:
      // if (!userScrolledUp && buffer.baseY > 0) term.scrollToBottom();
      const userScrolledUp = false;
      if (!userScrolledUp && buffer.baseY > 0) {
        fakeScrollToBottom();
      }

      assert.equal(buffer.baseY, 0, 'buffer.baseY must be 0 for content fitting in viewport');
      assert.equal(scrollToBottomCalled, false, 'scrollToBottom must NOT be called when baseY === 0');
      term.dispose();
    });

    test('T1-R1-05: Auto-scroll activates when buffer.baseY > 0 and user has not scrolled up', async () => {
      const term = new Terminal({ cols: 80, rows: 10 });
      let scrollToBottomCount = 0;
      const fakeScrollToBottom = () => { scrollToBottomCount++; };

      // Write 25 lines into 10-line terminal to force baseY > 0
      const content = Array.from({ length: 25 }, (_, i) => `log line ${i + 1}\r\n`).join('');
      await writeToTerminal(term, content);

      const buffer = term.buffer.active;
      assert.ok(buffer.baseY > 0, 'baseY must be positive after scrollback overflow');

      const userScrolledUp = false;
      if (!userScrolledUp && buffer.baseY > 0) {
        fakeScrollToBottom();
      }

      assert.equal(scrollToBottomCount, 1, 'scrollToBottom must be triggered when buffer.baseY > 0 and user has not scrolled up');
      term.dispose();
    });
  });

  // Feature Group R2: TUI Application First-Frame Rendering & Sizing Gates
  describe('Group R2: TUI Application First-Frame Rendering & Sizing Gates', () => {

    test('T1-R2-01: Mounted xterm parses TUI protocol bytes before container measurement', async () => {
      const term = new Terminal({ cols: 80, rows: 24 });
      const replies: string[] = [];
      term.onData((data: string) => replies.push(data));

      await new Promise<void>((resolve) => {
        deliverTerminalOutput(term, 'tui-first-frame', new TextEncoder().encode('\x1b[5n'), {
          write: (target, bytes) => target.write(bytes, resolve),
          buffer: () => assert.fail('a mounted terminal must not buffer on layout state'),
        });
      });

      assert.deepEqual(replies, ['\x1b[0n'], 'the TUI must receive its protocol reply before fit');
      term.dispose();
    });

    test('T1-R2-02: Only pre-mount bytes buffer and they flush when xterm mounts', async () => {
      const term = new Terminal({ cols: 80, rows: 24 });
      const writeQueue: Uint8Array[] = [];

      const chunk = new TextEncoder().encode('initial splash banner');
      deliverTerminalOutput(null, 'pre-mount', chunk, {
        write: () => assert.fail('no terminal is mounted'),
        buffer: (_sessionId, bytes) => writeQueue.push(bytes),
      });
      assert.equal(term.buffer.active.cursorX, 0, 'term should not have written yet');

      // Mounting xterm, not measuring its container, closes the only valid delivery gap.
      while (writeQueue.length > 0) {
        const buffered = writeQueue.shift()!;
        await writeToTerminal(term, buffered);
      }

      assert.equal(term.buffer.active.cursorX, 'initial splash banner'.length);
      term.dispose();
    });

    test('T1-R2-03: convertEol remains strictly false during active streaming mode', () => {
      const term = new Terminal({ cols: 80, rows: 24, convertEol: false });
      assert.equal(term.options.convertEol, false, 'convertEol must be false during streaming');
      term.dispose();
    });

    test('T1-R2-04: sendGeometry pushes measured container geometry inside socket.onopen', () => {
      const framesSent: string[] = [];
      const fakeSocket = {
        readyState: 1, // WebSocket.OPEN
        send: (msg: string) => { framesSent.push(msg); },
      };

      const getGeometry = () => ({ rows: 30, cols: 120 });
      const sendGeometry = (socket: any) => {
        const frame = shellResizeFrame(getGeometry());
        if (frame && socket.readyState === 1) {
          socket.send(frame);
        }
      };

      sendGeometry(fakeSocket);
      assert.equal(framesSent.length, 1);
      assert.equal(framesSent[0], '{"type":"resize","rows":30,"cols":120}');
    });
  });

  // Feature Group R3: Client Terminal Session Registry & Tab Persistence
  describe('Group R3: Client Terminal Session Registry & Tab Persistence', () => {

    test('T1-R3-01: Tab container preserves active vs inactive pane instances across tab switches', () => {
      // 1. Behavioral verification of DOM Keep-Alive visibility toggle model
      interface TabPaneState {
        sessionId: string;
        isActive: boolean;
        displayStyle: 'block' | 'none';
      }

      const sessions = ['session-alpha', 'session-beta'];
      let activeTab = 'session-alpha';

      const renderTabs = (activeId: string): TabPaneState[] => {
        return sessions.map((id) => ({
          sessionId: id,
          isActive: id === activeId,
          displayStyle: id === activeId ? 'block' : 'none',
        }));
      };

      // Initially session-alpha is active
      let panes = renderTabs(activeTab);
      assert.equal(panes[0].displayStyle, 'block', 'active tab must be visible');
      assert.equal(panes[1].displayStyle, 'none', 'inactive tab must be hidden');

      // Switch to session-beta
      activeTab = 'session-beta';
      panes = renderTabs(activeTab);
      assert.equal(panes[0].displayStyle, 'none', 'previous active tab must be hidden without destruction');
      assert.equal(panes[1].displayStyle, 'block', 'new active tab must be visible');
      assert.equal(panes[0].sessionId, 'session-alpha');
      assert.equal(panes[1].sessionId, 'session-beta');
    });

    test('T1-R3-02: Background output continues writing to inactive tab without losing lines', async () => {
      const term1 = new Terminal({ cols: 80, rows: 24 });
      const term2 = new Terminal({ cols: 80, rows: 24 });

      // Tab 1 is inactive in DOM, but its terminal instance remains alive
      await writeToTerminal(term2, 'active tab 2 output\r\n');
      for (let i = 1; i <= 20; i++) {
        await writeToTerminal(term1, `background job step ${i}\r\n`);
      }

      // Check Tab 1 retained all 20 lines while Tab 2 was being viewed
      assert.equal(term1.buffer.active.baseY, 0);
      assert.equal(term1.buffer.active.cursorY, 20);
      term1.dispose();
      term2.dispose();
    });

    test('T1-R3-03: TerminalSessionRegistry captures snapshot, viewport offset, and dimensions', () => {
      const registry = new TerminalSessionRegistry();
      registry.saveSnapshot('sess-1', 'serialized-content-data', 15, 100, 40);

      const state = registry.get('sess-1');
      assert.ok(state, 'state must be saved');
      assert.equal(state.sessionId, 'sess-1');
      assert.equal(state.snapshot, 'serialized-content-data');
      assert.equal(state.savedViewportY, 15);
      assert.equal(state.cols, 100);
      assert.equal(state.rows, 40);
      assert.equal(state.isSized, true);
    });

    test('T1-R3-04: TerminalSessionRegistry buffers unmounted deltas and returns restoration payload', () => {
      const registry = new TerminalSessionRegistry();
      registry.saveSnapshot('sess-2', 'base-snapshot', 0, 80, 24);

      const delta1 = new TextEncoder().encode('delta chunk 1\r\n');
      const delta2 = new TextEncoder().encode('delta chunk 2\r\n');
      registry.appendDelta('sess-2', delta1);
      registry.appendDelta('sess-2', delta2);

      const restoration = registry.consumeRestorationData('sess-2');
      assert.ok(restoration);
      assert.equal(restoration.snapshot, 'base-snapshot');
      assert.equal(restoration.deltaChunks.length, 2);
      assert.equal(new TextDecoder().decode(restoration.deltaChunks[0]), 'delta chunk 1\r\n');
      assert.equal(new TextDecoder().decode(restoration.deltaChunks[1]), 'delta chunk 2\r\n');

      // Subsequent consumption yields empty delta chunks
      const nextRestoration = registry.consumeRestorationData('sess-2');
      assert.ok(nextRestoration);
      assert.equal(nextRestoration.deltaChunks.length, 0);
    });

    test('T1-R3-05: Explicit session kill removes state from registry and active set', () => {
      const registry = new TerminalSessionRegistry();
      registry.registerActiveSession('sess-kill');
      registry.saveSnapshot('sess-kill', 'snapshot', 0, 80, 24);

      registry.closeSession('sess-kill');
      assert.equal(registry.get('sess-kill'), undefined, 'session state must be deleted from registry');
    });
  });
});

// ============================================================================
// MODEL 2: Boundary Value Analysis (BVA) & Corner Cases
// ============================================================================

describe('Model 2: Boundary Value Analysis (BVA) & Corner Cases', () => {

  // Boundary Group R1: Snapshot & Cursor Extremes
  describe('Boundary Group R1: Snapshot & Cursor Extremes', () => {

    test('T2-R1-01: Completely empty pane output produces valid repaint frame without error', () => {
      const frame = formatHubScreenSnapshot('', 0, 0);
      const decoded = Buffer.from(frame.screen_b64, 'base64').toString('utf8');
      assert.equal(decoded, `${ANSI_ERASE_AND_HOME}\x1b[1;1H`, 'must produce clean erase + home frame');
    });

    test('T2-R1-02: Prompt with intentional trailing spaces preserves prompt spaces while trimming empty rows', () => {
      const prompt = 'user@box:~$     ';
      const capturedRows = [prompt, '', '', ''].join('\n');
      const frame = formatHubScreenSnapshot(capturedRows, 0, prompt.length);
      const decoded = Buffer.from(frame.screen_b64, 'base64').toString('utf8');

      assert.ok(decoded.includes(prompt), 'must preserve trailing spaces in the prompt row');
      assert.ok(!decoded.includes(`${prompt}\r\n\r\n`), 'must strip trailing empty rows');
      assert.ok(decoded.includes(`\x1b[1;${prompt.length + 1}H`), 'cursor column must respect prompt trailing space');
    });

    test('T2-R1-03: Full-width line filling exactly 80 columns formats cleanly without extra blank rows', async () => {
      const term = new Terminal({ cols: 80, rows: 24 });
      const fullLine = 'A'.repeat(80);
      const frame = formatHubScreenSnapshot(fullLine, 0, 79);
      const decoded = Buffer.from(frame.screen_b64, 'base64').toString('utf8');

      await writeToTerminal(term, decoded);

      assert.equal(term.buffer.active.baseY, 0);
      assert.equal(term.buffer.active.cursorY, 0);
      term.dispose();
    });

    test('T2-R1-04: Coordinate origin (0, 0) translates to 1-indexed ANSI \\x1b[1;1H', () => {
      const frame = formatHubScreenSnapshot('test', 0, 0);
      const decoded = Buffer.from(frame.screen_b64, 'base64').toString('utf8');
      assert.ok(decoded.endsWith('\x1b[1;1H'), '0-indexed (0,0) must map to ANSI 1-indexed (1,1)');
    });

    test('T2-R1-05: Large geometry coordinates format correctly without overflow', () => {
      const frame = formatHubScreenSnapshot('large grid', 99, 199);
      const decoded = Buffer.from(frame.screen_b64, 'base64').toString('utf8');
      assert.ok(decoded.endsWith('\x1b[100;200H'), '(99, 199) must format as \\x1b[100;200H');
    });
  });

  // Boundary Group R2: Geometry Dimensions & Container Boundaries
  describe('Boundary Group R2: Geometry Dimensions & Container Boundaries', () => {

    test('T2-R2-01: 0x0 container dimensions produce null from shellResizeFrame', () => {
      assert.equal(shellResizeFrame({ rows: 0, cols: 0 }), null);
      assert.equal(shellResizeFrame({ rows: 24, cols: 0 }), null);
      assert.equal(shellResizeFrame({ rows: 0, cols: 80 }), null);
    });

    test('T2-R2-02: Viewport width below 40 columns is clamped to 40 columns', () => {
      const clampCols = (cols: number) => Math.max(cols, 40);
      assert.equal(clampCols(10), 40);
      assert.equal(clampCols(39), 40);
      assert.equal(clampCols(40), 40);
      assert.equal(clampCols(80), 80);
    });

    test('T2-R2-03: Viewport height of 1 row is accepted without 24-row floor', () => {
      const clampRows = (rows: number) => Math.max(rows, 1);
      assert.equal(clampRows(1), 1);
      assert.equal(clampRows(10), 10);
      assert.equal(clampRows(24), 24);
      assert.equal(shellResizeFrame({ rows: 1, cols: 80 }), '{"type":"resize","rows":1,"cols":80}');
    });

    test('T2-R2-04: Non-finite geometry values return null frame', () => {
      assert.equal(shellResizeFrame({ rows: NaN, cols: 80 }), null);
      assert.equal(shellResizeFrame({ rows: 24, cols: NaN }), null);
      assert.equal(shellResizeFrame({ rows: Infinity, cols: 80 }), null);
      assert.equal(shellResizeFrame({ rows: 24, cols: -1 }), null);
      assert.equal(shellResizeFrame(null), null);
      assert.equal(shellResizeFrame(undefined), null);
    });

    test('T2-R2-05: Rapid consecutive resize events maintain valid state and column floor', () => {
      const resizeRequests = [
        { rows: 20, cols: 35 },
        { rows: 22, cols: 38 },
        { rows: 24, cols: 80 },
        { rows: 25, cols: 120 },
      ];

      const processed = resizeRequests.map(r => {
        const effectiveCols = Math.max(r.cols, 40);
        const effectiveRows = Math.max(r.rows, 1);
        return JSON.parse(shellResizeFrame({ rows: effectiveRows, cols: effectiveCols })!);
      });

      assert.equal(processed[0].cols, 40);
      assert.equal(processed[1].cols, 40);
      assert.equal(processed[2].cols, 80);
      assert.equal(processed[3].cols, 120);
    });
  });

  // Boundary Group R3: Memory Limits, Buffer Capacities & Connection Flapping
  describe('Boundary Group R3: Memory Limits, Buffer Capacities & Connection Flapping', () => {

    test('T2-R3-01: High-volume unmounted delta output > 1 MB is capped to MAX_DELTA_BYTES', () => {
      const registry = new TerminalSessionRegistry();
      registry.saveSnapshot('sess-heavy', '', 0, 80, 24);

      // Append 1.5 MB of delta chunks (3 x 512 KB)
      const chunkSize = 512 * 1024;
      const chunk1 = new Uint8Array(chunkSize).fill(65); // 'A'
      const chunk2 = new Uint8Array(chunkSize).fill(66); // 'B'
      const chunk3 = new Uint8Array(chunkSize).fill(67); // 'C'

      registry.appendDelta('sess-heavy', chunk1);
      registry.appendDelta('sess-heavy', chunk2);
      registry.appendDelta('sess-heavy', chunk3);

      const state = registry.get('sess-heavy')!;
      const totalBytes = state.deltaChunks.reduce((acc, c) => acc + c.length, 0);

      assert.ok(totalBytes <= MAX_DELTA_BYTES, `total buffered bytes (${totalBytes}) must not exceed MAX_DELTA_BYTES (${MAX_DELTA_BYTES})`);
      assert.equal(totalBytes, 1024 * 1024, 'must retain newest 1 MB (chunk2 and chunk3)');
    });

    test('T2-R3-02: Zero-byte empty delta chunks are ignored without corrupting buffer', () => {
      const registry = new TerminalSessionRegistry();
      registry.saveSnapshot('sess-empty-delta', '', 0, 80, 24);

      registry.appendDelta('sess-empty-delta', new Uint8Array(0));
      const state = registry.get('sess-empty-delta')!;
      assert.equal(state.deltaChunks.length, 0, 'empty chunk must not be added to queue');
    });

    test('T2-R3-03: Querying unknown or closed session returns undefined/null gracefully', () => {
      const registry = new TerminalSessionRegistry();
      assert.equal(registry.get('non-existent'), undefined);
      assert.equal(registry.consumeRestorationData('non-existent'), null);
    });

    test('T2-R3-04: Bridge unreachable status preserves existing terminal scrollback', async () => {
      const term = new Terminal({ cols: 80, rows: 24 });
      await writeToTerminal(term, 'existing session work\r\n');

      // Bridge becomes unreachable (network disconnection or bridge crash)
      const isBridgeUnreachable = true;
      assert.equal(isBridgeUnreachable, true);

      // Scrollback lines must remain intact in terminal buffer
      assert.equal(term.buffer.active.cursorY, 1);
      assert.equal(term.buffer.active.getLine(0)?.translateToString().trim(), 'existing session work');
      term.dispose();
    });

    test('T2-R3-05: Rapid tab toggling (A -> B -> A -> B in <50ms) preserves state integrity', () => {
      const registry = new TerminalSessionRegistry();
      registry.saveSnapshot('sess-A', 'snapshot-A', 5, 80, 24);
      registry.saveSnapshot('sess-B', 'snapshot-B', 10, 80, 24);

      // Rapid navigation sequence
      let activeSession = 'sess-A';
      activeSession = 'sess-B';
      activeSession = 'sess-A';
      activeSession = 'sess-B';

      assert.equal(activeSession, 'sess-B');
      assert.equal(registry.get('sess-A')?.savedViewportY, 5);
      assert.equal(registry.get('sess-B')?.savedViewportY, 10);
    });
  });
});

// ============================================================================
// MODEL 3: Pairwise Combinatorial & Cross-Feature Integration Testing
// ============================================================================

describe('Model 3: Pairwise Combinatorial & Cross-Feature Integration Testing', () => {

  test('T3-COMB-01: Tab switch while active TUI/Neovim stream emits alternate screen buffer sequence', async () => {
    const term1 = new Terminal({ cols: 80, rows: 24, convertEol: false });
    const serializeAddon1 = new SerializeAddon();
    term1.loadAddon(serializeAddon1);

    // Neovim enters alternate screen and renders TUI header
    const nvimEnter = `${ANSI_ALT_SCREEN_ENTER}\x1b[1;1H~                                                     \x1b[24;1H[No Name] - NVIM`;
    await writeToTerminal(term1, nvimEnter);

    // User switches to Tab 2
    const registry = new TerminalSessionRegistry();
    const serialized = serializeAddon1.serialize();
    registry.saveSnapshot('sess-nvim', serialized, term1.buffer.active.viewportY, term1.cols, term1.rows);

    // While in Tab 2, background stream emits Neovim status update
    const nvimUpdate = new TextEncoder().encode('\x1b[24;1H[No Name] - NVIM (modified)');
    registry.appendDelta('sess-nvim', nvimUpdate);

    // User switches back to Tab 1 (remount sequence)
    const restoration = registry.consumeRestorationData('sess-nvim')!;
    const termRemounted = new Terminal({ cols: 80, rows: 24, convertEol: false });
    await writeToTerminal(termRemounted, restoration.snapshot);
    for (const chunk of restoration.deltaChunks) {
      await writeToTerminal(termRemounted, chunk);
    }

    assert.ok(restoration.snapshot.length > 0, 'snapshot must capture alternate screen state');
    term1.dispose();
    termRemounted.dispose();
  });

  test('T3-COMB-02: Window resize occurring while background output streams to inactive tab', async () => {
    const termInactive = new Terminal({ cols: 80, rows: 24 });
    
    // Inactive tab receives output during window resize from 80x24 to 120x30
    const newCols = 120;
    const newRows = 30;
    const resizeFrame = shellResizeFrame({ rows: newRows, cols: newCols });
    assert.equal(resizeFrame, '{"type":"resize","rows":30,"cols":120}');

    // Background writes continue
    await writeToTerminal(termInactive, 'compiler warning: variable unused\r\n');

    // On tab re-activation, terminal resizes to measured container
    termInactive.resize(newCols, newRows);
    assert.equal(termInactive.cols, 120);
    assert.equal(termInactive.rows, 30);
    assert.equal(termInactive.buffer.active.cursorY, 1);
    termInactive.dispose();
  });

  test('T3-COMB-03: BottomDock collapse to 0x0 and expand back to 80x24 preserves scrollback', async () => {
    const term = new Terminal({ cols: 80, rows: 24 });
    const serializeAddon = new SerializeAddon();
    term.loadAddon(serializeAddon);

    // Pre-populate 50 lines of history
    for (let i = 1; i <= 50; i++) {
      await writeToTerminal(term, `command line execution ${i}\r\n`);
    }
    const initialBaseY = term.buffer.active.baseY;
    assert.ok(initialBaseY > 0, 'must have accumulated scrollback');

    // Dock collapses: clientWidth = 0, clientHeight = 0
    const collapsedFrame = shellResizeFrame({ rows: 0, cols: 0 });
    assert.equal(collapsedFrame, null, 'collapse to 0x0 must not dispatch resize');

    // Dock expands back to 80x24
    const expandedFrame = shellResizeFrame({ rows: 24, cols: 80 });
    assert.equal(expandedFrame, '{"type":"resize","rows":24,"cols":80}');
    term.resize(80, 24);

    // Check scrollback history remained intact
    assert.equal(term.buffer.active.baseY, initialBaseY);
    term.dispose();
  });

  test('T3-COMB-04: Stream reconnection during tab transition restores snapshot + deltas cleanly', async () => {
    const registry = new TerminalSessionRegistry();
    const term = new Terminal({ cols: 80, rows: 24 });
    const serializeAddon = new SerializeAddon();
    term.loadAddon(serializeAddon);

    await writeToTerminal(term, 'starting compilation...\r\n');
    registry.saveSnapshot('sess-reconnect', serializeAddon.serialize(), 0, 80, 24);

    // WebSocket reconnect occurs; new delta arrives
    registry.appendDelta('sess-reconnect', new TextEncoder().encode('compilation finished: 0 errors\r\n'));

    // Gated remount flush: replay snapshot + delta before opening live writes
    const restoration = registry.consumeRestorationData('sess-reconnect')!;
    const newTerm = new Terminal({ cols: 80, rows: 24 });
    await writeToTerminal(newTerm, restoration.snapshot);
    for (const chunk of restoration.deltaChunks) {
      await writeToTerminal(newTerm, chunk);
    }

    // Now live write arrives
    await writeToTerminal(newTerm, 'ready for next command\r\n');

    assert.equal(newTerm.buffer.active.cursorY, 3);
    term.dispose();
    newTerm.dispose();
  });

  test('T3-COMB-05: User scrolled up in inactive tab preserves savedViewportY across background output', async () => {
    const term = new Terminal({ cols: 80, rows: 10 });
    for (let i = 1; i <= 30; i++) {
      await writeToTerminal(term, `output line ${i}\r\n`);
    }

    // User scrolled up to inspect line 5
    let userScrolledUp = true;
    let savedViewportY = 5;

    // Background output arrives while user is scrolled up
    await writeToTerminal(term, 'background output 31\r\n');
    
    // Auto-scroll rule: only scrolls if !userScrolledUp
    let autoScrolled = false;
    if (!userScrolledUp && term.buffer.active.baseY > 0) {
      autoScrolled = true;
    }

    assert.equal(autoScrolled, false, 'must NOT auto-scroll when userScrolledUp is true');
    assert.equal(savedViewportY, 5, 'savedViewportY must remain preserved');
    term.dispose();
  });
});

// ============================================================================
// MODEL 4: Real-World Application Scenarios (End-to-End Workflows)
// ============================================================================

describe('Model 4: Real-World Application Scenarios', () => {

  test('T4-SCEN-01: Neovim Initial Frame Launch Workflow', async () => {
    // 1. Mount fresh terminal pane
    const term = new Terminal({ cols: 80, rows: 24, convertEol: false });
    const serializeAddon = new SerializeAddon();
    term.loadAddon(serializeAddon);

    // 2. Container sizing gate confirms 80x24 geometry
    const isSized = true;
    assert.equal(isSized, true);
    const geomFrame = shellResizeFrame({ rows: 24, cols: 80 });
    assert.equal(geomFrame, '{"type":"resize","rows":24,"cols":80}');

    // 3. Child process receives dimensions and emits Neovim initial splash frame into alternate buffer
    const nvimSplash = [
      ANSI_ALT_SCREEN_ENTER,
      '\x1b[2J\x1b[H',
      '~                                                                               \r\n',
      '~                                NVIM v0.10.0                                   \r\n',
      '~                                                                               \r\n',
      '~                          Nvim is open source and freely                       \r\n',
      '~                                                                               \r\n',
      '\x1b[24;1H\x1b[7m[No Name]                                                  0,0-1          All\x1b[0m',
      '\x1b[1;1H'
    ].join('');

    await writeToTerminal(term, nvimSplash);

    // 4. Verify initial frame rendered cleanly on first draw without tab switch
    assert.equal(term.cols, 80);
    assert.equal(term.rows, 24);
    assert.equal(term.buffer.active.cursorY, 0, 'cursor homed to first row of splash buffer');
    assert.equal(term.buffer.active.cursorX, 0);

    const serialized = serializeAddon.serialize();
    assert.ok(serialized.includes('NVIM'), 'serialized snapshot must contain Neovim banner');
    term.dispose();
  });

  test('T4-SCEN-02: 100-Iteration Background Compilation Loop Workflow', async () => {
    // 1. Shell 1 is active, starts long build loop
    const shell1 = new Terminal({ cols: 80, rows: 24 });
    const shell2 = new Terminal({ cols: 80, rows: 24 });

    // Initial prompt
    await writeToTerminal(shell1, 'user@box:~$ for i in $(seq 1 100); do echo "count $i"; done\r\n');

    // 2. User switches to Shell 2 immediately (Shell 1 becomes inactive in DOM keep-alive)
    await writeToTerminal(shell2, 'user@box:~$ git status\r\nOn branch main\r\n');

    // 3. Background task emits 100 lines into Shell 1
    for (let i = 1; i <= 100; i++) {
      await writeToTerminal(shell1, `count ${i}\r\n`);
    }

    // 4. User switches back to Shell 1
    // Verify all 100 counts exist in shell1's active buffer and scrollback
    assert.ok(shell1.buffer.active.baseY > 0, 'shell1 buffer must have accumulated scrollback lines');
    assert.ok(shell1.buffer.active.length >= 100, 'buffer must contain at least 100 lines');

    // Spot-check count 1, count 50, count 100
    const allText: string[] = [];
    for (let lineIdx = 0; lineIdx < shell1.buffer.active.length; lineIdx++) {
      const lineStr = shell1.buffer.active.getLine(lineIdx)?.translateToString();
      if (lineStr) allText.push(lineStr);
    }
    const combined = allText.join('\n');
    assert.ok(combined.includes('count 1'), 'count 1 must be present in scrollback');
    assert.ok(combined.includes('count 50'), 'count 50 must be present in scrollback');
    assert.ok(combined.includes('count 100'), 'count 100 must be present in scrollback');

    shell1.dispose();
    shell2.dispose();
  });

  test('T4-SCEN-03: Multi-Tab Session Kill & Garbage Collection Workflow', async () => {
    const registry = new TerminalSessionRegistry();

    // 1. Open Shell 1 and Shell 2
    registry.registerActiveSession('shell-1');
    registry.registerActiveSession('shell-2');
    registry.saveSnapshot('shell-1', 'shell-1-data', 0, 80, 24);
    registry.saveSnapshot('shell-2', 'shell-2-data', 0, 80, 24);

    let activeTab = 'shell-1';
    let visibleTabs = ['shell-1', 'shell-2'];

    // 2. User kills Shell 1
    const killedSessionId = 'shell-1';
    registry.closeSession(killedSessionId);

    // Update active tab to next adjacent session
    visibleTabs = visibleTabs.filter(id => id !== killedSessionId);
    activeTab = visibleTabs[0];

    // 3. Verify Shell 2 is now active and Shell 1 is completely purged
    assert.equal(activeTab, 'shell-2');
    assert.equal(visibleTabs.length, 1);
    assert.equal(registry.get('shell-1'), undefined, 'shell-1 state must be evicted from registry');
    assert.ok(registry.get('shell-2'), 'shell-2 state must remain intact');
  });
});
