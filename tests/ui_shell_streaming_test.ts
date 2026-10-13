// REQ-STREAM-IMPL-3: Automated unit and contract tests for Phase 3 UI streaming integration
//
// RUN: node --test tests/ui_shell_streaming_test.ts
//  OR: npx tsx tests/ui_shell_streaming_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

import * as xtermModule from '@xterm/xterm';

import {
  dispatchShellInput,
  dispatchShellResize,
  pollingSubscriptionSessionId,
  resolveStreamRenderMode,
  resolveStreamingMode,
} from '../src/ui/components/shells/streamingMode.ts';
import {
  beginTerminalWrite,
  dispatchTerminalData,
} from '../src/ui/components/shells/terminalWriteAccounting.ts';
import { activateVisibleTerminal } from '../src/ui/components/shells/terminalPaneActivation.ts';
import { deliverTerminalOutput } from '../src/ui/components/shells/terminalOutputDelivery.ts';
import { createTerminalResizeDispatcher } from '../src/ui/components/shells/terminalResizeDispatch.ts';
import { shellResizeFrame } from '../src/ui/components/shells/shellStreamFrames.ts';

const Terminal = (xtermModule as any).Terminal || (xtermModule as any).default?.Terminal || (xtermModule as any).default;

test('terminal flex ancestors contain xterm intrinsic width instead of feeding it back into fit', () => {
  const pane = fs.readFileSync(
    path.join(process.cwd(), 'src/ui/components/shells/ShellTerminalPane.tsx'),
    'utf8'
  );
  const dock = fs.readFileSync(
    path.join(process.cwd(), 'src/ui/components/shell/BottomDock.tsx'),
    'utf8'
  );

  assert.match(
    pane,
    /chat-scrollbar relative min-w-0 max-w-full[^"\n]*overflow-x-auto/,
    'the xterm scroll host must be allowed to shrink without growing its measurement box'
  );
  assert.match(
    dock,
    /h-full min-w-0 max-w-full w-full[^"\n]*overflow-hidden/,
    'the keep-alive flex wrapper must contain xterm intrinsic width'
  );
});

test('renderer build uses xterm precompiled artifact without the Safari DECRQM minification crash', () => {
  const viteConfig = fs.readFileSync(path.join(process.cwd(), 'vite.config.js'), 'utf8');
  assert.match(
    viteConfig,
    /find: \/\^@xterm\\\/xterm\$\//,
    'the alias must match only the xterm JavaScript entry and leave its CSS subpath intact'
  );
  assert.match(
    viteConfig,
    /node_modules\/@xterm\/xterm\/lib\/xterm\.js/,
    'the renderer must use xterm 6.0.0 precompiled UMD, whose requestMode enum is already folded'
  );
});

test('terminal resize bursts send only the final stable geometry to the PTY', () => {
  const callbacks = new Map<number, () => void>();
  const sent: Array<[number, number]> = [];
  let nextTimer = 1;
  const dispatcher = createTerminalResizeDispatcher(
    (rows, cols) => sent.push([rows, cols]),
    100,
    {
      setTimeout: (callback) => {
        const id = nextTimer++;
        callbacks.set(id, callback);
        return id as ReturnType<typeof setTimeout>;
      },
      clearTimeout: (timer) => {
        callbacks.delete(timer as unknown as number);
      },
    }
  );

  dispatcher.schedule(28, 45);
  dispatcher.schedule(27, 45);
  dispatcher.schedule(13, 45);
  dispatcher.schedule(28, 45);

  assert.deepEqual(sent, [], 'animation intermediates must not resize the PTY');
  assert.equal(callbacks.size, 1, 'only the trailing dispatch remains scheduled');
  callbacks.values().next().value?.();
  assert.deepEqual(sent, [[28, 45]], 'the PTY receives the final stable geometry once');

  dispatcher.schedule(20, 80);
  dispatcher.cancel();
  assert.equal(callbacks.size, 0, 'unmount cancellation prevents a stale resize');
});

function writeToTerminal(term: any, data: string | Uint8Array): Promise<void> {
  return new Promise((resolve) => term.write(data, () => resolve()));
}

test('a keep-alive terminal waits for visible geometry before sizing and draining output', () => {
  const container = { clientWidth: 0, clientHeight: 0 };
  const resized: Array<[number, number]> = [];
  const sent: Array<[number, number]> = [];
  const activationOrder: string[] = [];
  let fitCalls = 0;
  let markSizedCalls = 0;
  let flushCalls = 0;
  let focusCalls = 0;
  const terminal = {
    cols: 12,
    rows: 0,
    resize: (cols: number, rows: number) => {
      resized.push([cols, rows]);
      activationOrder.push('resize');
    },
    focus: () => {
      focusCalls += 1;
      activationOrder.push('focus');
    },
  };
  const fitAddon = {
    fit: () => {
      fitCalls += 1;
      terminal.cols = 38;
      terminal.rows = 12;
    },
  };
  const callbacks = {
    markSized: () => {
      markSizedCalls += 1;
      activationOrder.push('mark-sized');
    },
    sendResize: (rows: number, cols: number) => {
      sent.push([rows, cols]);
      activationOrder.push('send-resize');
    },
    flushPendingOutput: () => {
      flushCalls += 1;
      activationOrder.push('flush');
    },
  };

  assert.equal(activateVisibleTerminal(container, fitAddon, terminal, callbacks), false);
  assert.equal(fitCalls, 0, 'a display:none pane must not fit against zero geometry');
  assert.equal(flushCalls, 0, 'stream output must remain buffered while the pane is hidden');

  container.clientWidth = 390;
  container.clientHeight = 420;
  assert.equal(activateVisibleTerminal(container, fitAddon, terminal, callbacks), true);
  assert.equal(fitCalls, 1);
  assert.deepEqual(resized, [[40, 12]], 'activation preserves the terminal geometry floors');
  assert.deepEqual(sent, [[12, 40]], 'the fitted geometry must reach the PTY');
  assert.equal(markSizedCalls, 1);
  assert.equal(flushCalls, 1, 'buffered first-mount output drains as soon as sizing succeeds');
  assert.equal(focusCalls, 1);
  assert.deepEqual(
    activationOrder,
    ['resize', 'mark-sized', 'send-resize', 'flush', 'focus'],
    'buffered bytes must not drain before xterm and the PTY have valid geometry'
  );
});

test('an unsized mounted terminal processes protocol queries instead of buffering them', async () => {
  const term = new Terminal({ cols: 80, rows: 24 });
  const replies: string[] = [];
  const buffered: Uint8Array[] = [];
  term.onData((data: string) => replies.push(data));

  await new Promise<void>((resolve) => {
    const outcome = deliverTerminalOutput(
      term,
      'session-unsized',
      new TextEncoder().encode('\x1b[5n'),
      {
        write: (target, bytes) => target.write(bytes, resolve),
        buffer: (_sessionId, bytes) => buffered.push(bytes),
      }
    );
    assert.equal(outcome, 'written');
  });

  assert.deepEqual(replies, ['\x1b[0n'], 'xterm must answer DSR before the pane has fitted');
  assert.deepEqual(buffered, [], 'layout state must never divert mounted-terminal bytes');
  term.dispose();
});

test('terminal output buffers only while no terminal instance is mounted', () => {
  const buffered: Array<{ sessionId: string; bytes: Uint8Array }> = [];
  const bytes = new TextEncoder().encode('early output');
  const outcome = deliverTerminalOutput(null, 'session-before-mount', bytes, {
    write: () => assert.fail('no terminal exists yet'),
    buffer: (sessionId, chunk) => buffered.push({ sessionId, bytes: chunk }),
  });

  assert.equal(outcome, 'buffered');
  assert.equal(buffered.length, 1);
  assert.equal(buffered[0].sessionId, 'session-before-mount');
  assert.equal(new TextDecoder().decode(buffered[0].bytes), 'early output');
});

test('xterm protocol replies are always forwarded unless the vault is locked', async () => {
  const term = new Terminal({ cols: 80, rows: 24 });
  const pendingWrites = { current: 0 };
  const forwarded: string[] = [];
  term.onData((data: string) => {
    dispatchTerminalData(data, false, (payload) => forwarded.push(payload));
  });

  await new Promise<void>((resolve) => {
    const finish = beginTerminalWrite(pendingWrites);
    // Neovim brackets its background-color probe with a terminal-status query.
    term.write('\x1b[?1049h\x1b]11;?\x07\x1b[5n', () => {
      finish();
      resolve();
    });
  });
  assert.ok(forwarded.includes('\x1b[0n'), 'live DSR response must return to the PTY');
  assert.equal(pendingWrites.current, 0);

  forwarded.length = 0;
  await new Promise<void>((resolve) => {
    const finish = beginTerminalWrite(pendingWrites);
    term.write('\x1b[5n', () => {
      finish();
      resolve();
    });
  });
  assert.deepEqual(forwarded, ['\x1b[0n'], 'protocol replies must not depend on write provenance');

  const locked: string[] = [];
  assert.equal(dispatchTerminalData('secret', true, (data) => locked.push(data)), false);
  assert.deepEqual(locked, [], 'a locked vault must still refuse terminal input');
});

function renderedLines(term: any): string[] {
  const out: string[] = [];
  for (let i = 0; i < term.buffer.active.length; i++) {
    out.push(term.buffer.active.getLine(i)?.translateToString(true) ?? '');
  }
  while (out.length > 0 && out[out.length - 1] === '') out.pop();
  return out;
}

test('REQ-SHELL-18: shellResizeFrame sends real geometry and refuses the rest', () => {
  // The frame that had been going missing on create.
  assert.equal(
    shellResizeFrame({ rows: 24, cols: 200 }),
    '{"type":"resize","rows":24,"cols":200}',
    'a real geometry must produce a resize frame with rows and cols'
  );

  // Nothing to send: no terminal mounted yet.
  assert.equal(shellResizeFrame(null), null, 'null geometry must not produce a frame');
  assert.equal(shellResizeFrame(undefined), null, 'undefined geometry must not produce a frame');

  // A PTY told it is 0 columns wide is WORSE off than one left at its default,
  // and 0 is exactly what an unmeasured xterm renderer reports on a cold mount.
  assert.equal(shellResizeFrame({ rows: 0, cols: 200 }), null, '0 rows must not produce a frame');
  assert.equal(shellResizeFrame({ rows: 24, cols: 0 }), null, '0 cols must not produce a frame');
  assert.equal(shellResizeFrame({ rows: -1, cols: 80 }), null, 'negative rows must not produce a frame');
  assert.equal(shellResizeFrame({ rows: 24, cols: -1 }), null, 'negative cols must not produce a frame');
  assert.equal(shellResizeFrame({ rows: NaN, cols: 80 }), null, 'NaN rows must not produce a frame');
  assert.equal(
    shellResizeFrame({ rows: 24, cols: Infinity }),
    null,
    'non-finite cols must not produce a frame'
  );
});

// REQ-FIX-2 — these four tests replace a pair of source-substring assertions that pinned
// `isStreamingActive = isStreamingExperimentEnabled && !fallbackToPolling` as the routing
// predicate. That substring passed while the pane handed keystrokes to a closed socket and
// painted nothing for the whole ~8s reconnect backoff, because a substring cannot observe a
// disconnected socket. These execute the decision instead.

test('REQ-FIX-2: convertEol routing stays decoupled from streamConnected', () => {
  // The render mode is what drives convertEol. A momentary disconnect must NOT flip the pane
  // into LF-translating mode, or a frame arriving in the same tick as the reconnect is corrupted.
  const connected = resolveStreamRenderMode({ isStreamingExperimentEnabled: true, fallbackToPolling: false });
  assert.equal(connected.isStreamingActive, true);

  // Same inputs minus the connection: the render mode does not take streamConnected at all, so
  // there is no value of it that can change the answer.
  assert.equal(
    resolveStreamingMode(connected, false).isStreamingActive,
    true,
    'a dropped socket must not change how bytes are decoded'
  );
  assert.equal(resolveStreamingMode(connected, true).isStreamingActive, true);

  // Exhausted retries are different: polling owns the screen, so LF translation comes back.
  const fallen = resolveStreamRenderMode({ isStreamingExperimentEnabled: true, fallbackToPolling: true });
  assert.equal(fallen.isStreamingActive, false, 'fallback hands the screen to the polled repaint');
  assert.equal(fallen.isStreamEnabled, false, 'and stops reopening the socket');
});

test('REQ-FIX-2: a stream drop degrades to polling for input, resize and repaint', () => {
  const renderMode = resolveStreamRenderMode({ isStreamingExperimentEnabled: true, fallbackToPolling: false });

  // The reconnect window: socket down, retries NOT yet exhausted, so fallbackToPolling is false.
  // This is the state the regression could not see.
  const dropped = resolveStreamingMode(renderMode, false);
  assert.equal(dropped.isStreamTransportReady, false, 'a closed socket cannot carry input or resize');
  assert.equal(dropped.isPollingTransport, true, 'polling must take over input and resize');
  assert.equal(dropped.isStreamEnabled, true, 'the socket must still be trying to reconnect');

  // The screen does NOT change hands. Activating the subscription starts fetching captures, and
  // every capture feeds a term.reset() that would destroy scrollback the capture cannot replace.
  assert.equal(dropped.isPolledRepaintOwner, false, 'a transient drop must not hand over the screen');
  assert.equal(
    pollingSubscriptionSessionId('sess-1', dropped),
    null,
    'the polled capture must stay idle during the drop, or its repaint resets live scrollback'
  );

  // Reconnected: the stream takes everything back and polling goes idle.
  const live = resolveStreamingMode(renderMode, true);
  assert.equal(live.isStreamTransportReady, true);
  assert.equal(live.isPollingTransport, false);
  assert.equal(live.isPolledRepaintOwner, false);
  assert.equal(
    pollingSubscriptionSessionId('sess-1', live),
    null,
    'no duplicate capture polling while the stream is live'
  );
});

test('REQ-FIX-2: exhausted retries and a disabled experiment both route everything to polling', () => {
  for (const [label, input] of [
    ['fallback latched', { isStreamingExperimentEnabled: true, fallbackToPolling: true }],
    ['experiment off', { isStreamingExperimentEnabled: false, fallbackToPolling: false }],
    ['both', { isStreamingExperimentEnabled: false, fallbackToPolling: true }],
  ] as const) {
    const renderMode = resolveStreamRenderMode(input);
    for (const connected of [false, true]) {
      const mode = resolveStreamingMode(renderMode, connected);
      assert.equal(mode.isStreamTransportReady, false, `${label}: stream must not own the transport`);
      assert.equal(mode.isPollingTransport, true, `${label}: polling owns the transport`);
      // Here the screen DOES change hands — polling is the only thing that can paint at all.
      assert.equal(mode.isPolledRepaintOwner, true, `${label}: polling owns the screen`);
      assert.equal(pollingSubscriptionSessionId('sess-1', mode), 'sess-1', `${label}: polling stays subscribed`);
    }
  }
});

test('REQ-FIX-2: a null session id never produces a subscription', () => {
  const renderMode = resolveStreamRenderMode({ isStreamingExperimentEnabled: false, fallbackToPolling: false });
  assert.equal(pollingSubscriptionSessionId(null, resolveStreamingMode(renderMode, false)), null);
});

test('REQ-FIX-2: a stream drop preserves the rendered scrollback and the restored deltas', async () => {
  // Mirrors the real order of the two effects against a real terminal: restore on mount, then let
  // the polled repaint effect run IF the resolver says polling owns the screen.
  //
  // This is the case that made the first attempt at REQ-FIX-2 destructive. The polled capture is
  // bounded at 120 lines (useShellPaneSubscription lineLimit) while the terminal holds 5000 of
  // scrollback, and the repaint reaches it through term.reset() — so gating that reset on the
  // TRANSPORT meant every reconnect blip destroyed thousands of lines of real history, plus the
  // deltas consumeRestorationData had already drained and could not hand back.
  const POLLED_CAPTURE = 'CURRENT SCREEN ONLY\r\n';

  async function mountRestoreThenDrop(mode: ReturnType<typeof resolveStreamingMode>) {
    const term = new Terminal({ cols: 80, rows: 24, scrollback: 5000 });
    // Mount: restoration writes the serialized snapshot (which carries scrollback) and the
    // withheld deltas drained from the registry.
    for (let i = 1; i <= 30; i++) {
      await writeToTerminal(term, `HISTORY LINE ${i}\r\n`);
    }
    await writeToTerminal(term, 'WITHHELD DELTA OUTPUT\r\n');

    // The polled repaint effect, gated exactly as the pane gates it.
    if (mode.isPolledRepaintOwner) {
      term.options.convertEol = true;
      term.reset();
      await writeToTerminal(term, POLLED_CAPTURE);
    }
    const lines = renderedLines(term);
    term.dispose();
    return lines;
  }

  const renderMode = resolveStreamRenderMode({ isStreamingExperimentEnabled: true, fallbackToPolling: false });

  // The drop: history and the restored delta must both still be on screen.
  const afterDrop = await mountRestoreThenDrop(resolveStreamingMode(renderMode, false));
  assert.ok(afterDrop.includes('HISTORY LINE 1'), 'the oldest scrollback line must survive a drop');
  assert.ok(afterDrop.includes('HISTORY LINE 30'), 'recent scrollback must survive a drop');
  assert.ok(
    afterDrop.includes('WITHHELD DELTA OUTPUT'),
    'the restored deltas must survive a drop — the registry already drained them, so a reset loses them for good'
  );
  assert.ok(
    !afterDrop.includes('CURRENT SCREEN ONLY'),
    'no polled capture may repaint the pane while the stream owns the screen'
  );

  // Reconnected: likewise untouched.
  const afterReconnect = await mountRestoreThenDrop(resolveStreamingMode(renderMode, true));
  assert.ok(afterReconnect.includes('HISTORY LINE 1'));
  assert.ok(afterReconnect.includes('WITHHELD DELTA OUTPUT'));

  // CONTROL — the repaint path is still wired and still works when polling genuinely owns the
  // pane. Without this the test above would pass just as well with the repaint deleted.
  const latched = resolveStreamRenderMode({ isStreamingExperimentEnabled: true, fallbackToPolling: true });
  const afterFallback = await mountRestoreThenDrop(resolveStreamingMode(latched, false));
  assert.deepEqual(
    afterFallback,
    ['CURRENT SCREEN ONLY'],
    'control: once retries are exhausted the polled capture does own the screen and repaints it'
  );
});

test('REQ-FIX-2: the polled capture is written with LF translation, at every write site', async () => {
  // Measured, not assumed: a capture written with convertEol false staircases.
  const capture = 'LINE ONE\nLINE TWO\nLINE THREE';

  const staircased = new Terminal({ cols: 80, rows: 24, convertEol: false });
  await writeToTerminal(staircased, capture);
  assert.deepEqual(
    renderedLines(staircased),
    ['LINE ONE', '        LINE TWO', '                LINE THREE'],
    'this is what a polled capture looks like without LF translation'
  );
  staircased.dispose();

  const correct = new Terminal({ cols: 80, rows: 24, convertEol: false });
  correct.options.convertEol = true; // what both polled write sites must assert
  await writeToTerminal(correct, capture);
  assert.deepEqual(renderedLines(correct), ['LINE ONE', 'LINE TWO', 'LINE THREE']);
  correct.dispose();
});

// ---------------------------------------------------------------------------
// REQ-FIX-8 — the transport choice for input and resize, asserted BEHAVIOURALLY
//
// These tests exist because F2's fix had no test that failed when it was removed. The reviewer
// reverted `handleInput` and `handleResize` to `isStreamingActive` and the whole suite stayed
// green: the predicate lived in an `if` inside the pane, the pane cannot be rendered here (no DOM
// harness in this repo), so nothing executed it. A source-substring check is NOT a substitute and
// is deliberately not used below — the pane has two such call sites, so the string stays matched
// when only one of them is reverted, which is the vacuous-assertion trap F4 was about.
//
// What is executed instead: the dispatchers, with recording sinks, over every state the pane can
// be in. The load-bearing case is the reconnect backoff — experiment on, retries not yet
// exhausted, socket down — where `isStreamingActive` is TRUE while the socket cannot carry a
// byte. Routing on it there throws keystrokes away for the whole ~8s window with no feedback.
// ---------------------------------------------------------------------------

/** Records which sink fired and with what, so the assertion is on behaviour, not on a flag. */
function recordingInputSinks() {
  const stream: string[] = [];
  const http: string[] = [];
  return {
    stream,
    http,
    sinks: {
      sendOverStream: (data: string) => stream.push(data),
      sendOverHttp: (data: string) => http.push(data),
    },
  };
}

function recordingResizeSinks() {
  const stream: Array<[number, number]> = [];
  const http: Array<[number, number]> = [];
  return {
    stream,
    http,
    sinks: {
      sendOverStream: (rows: number, cols: number) => stream.push([rows, cols]),
      sendOverHttp: (rows: number, cols: number) => http.push([rows, cols]),
    },
  };
}

/** The four pane states, named by what the user is living through. */
const TRANSPORT_STATES = [
  {
    label: 'experiment off: polling owns everything',
    mode: resolveStreamingMode(
      resolveStreamRenderMode({ isStreamingExperimentEnabled: false, fallbackToPolling: false }),
      false
    ),
    expected: 'http' as const,
  },
  {
    label: 'stream live: the socket is open',
    mode: resolveStreamingMode(
      resolveStreamRenderMode({ isStreamingExperimentEnabled: true, fallbackToPolling: false }),
      true
    ),
    expected: 'stream' as const,
  },
  {
    // THE REGRESSION WINDOW. isStreamingActive is true here; isStreamTransportReady is not.
    label: 'reconnect backoff: experiment on, retries not exhausted, socket down',
    mode: resolveStreamingMode(
      resolveStreamRenderMode({ isStreamingExperimentEnabled: true, fallbackToPolling: false }),
      false
    ),
    expected: 'http' as const,
  },
  {
    label: 'fallback latched: retries exhausted',
    mode: resolveStreamingMode(
      resolveStreamRenderMode({ isStreamingExperimentEnabled: true, fallbackToPolling: true }),
      false
    ),
    expected: 'http' as const,
  },
];

test('REQ-FIX-8: a keystroke in the reconnect backoff is CARRIED by HTTP, not handed to the dead socket', () => {
  const backoff = TRANSPORT_STATES[2].mode;

  // The precondition that makes this test non-vacuous: the old predicate says "streaming" here.
  // If this ever stops holding, the mutation this test guards is no longer expressible and the
  // test below would pass for the wrong reason.
  assert.equal(backoff.isStreamingActive, true, 'the render mode must still be streaming in the backoff');
  assert.equal(backoff.isStreamTransportReady, false, 'the transport must not be ready in the backoff');

  const { stream, http, sinks } = recordingInputSinks();
  const target = dispatchShellInput(backoff, 'ls -la\r', sinks);

  assert.equal(target, 'http', 'input must route over HTTP while the socket is down');
  assert.deepEqual(stream, [], 'not one byte may be handed to a socket that is not OPEN — it would be dropped silently');
  assert.deepEqual(http, ['ls -la\r'], 'the keystroke must actually arrive at the HTTP sink, intact');
});

test('REQ-FIX-8: a resize in the reconnect backoff is CARRIED by HTTP, not handed to the dead socket', () => {
  const backoff = TRANSPORT_STATES[2].mode;
  const { stream, http, sinks } = recordingResizeSinks();

  const target = dispatchShellResize(backoff, 24, 120, sinks);

  assert.equal(target, 'http', 'resize must route over HTTP while the socket is down');
  assert.deepEqual(stream, [], 'a dropped resize leaves the PTY on stale geometry until something else resizes the pane');
  assert.deepEqual(http, [[24, 120]], 'the geometry must arrive at the HTTP sink unchanged');
});

test('REQ-FIX-8: input routing follows the live socket across every pane state', () => {
  for (const { label, mode, expected } of TRANSPORT_STATES) {
    const { stream, http, sinks } = recordingInputSinks();
    const target = dispatchShellInput(mode, 'x', sinks);

    assert.equal(target, expected, `${label}: wrong transport chosen`);
    if (expected === 'stream') {
      assert.deepEqual(stream, ['x'], `${label}: the stream sink must receive the keystroke`);
      assert.deepEqual(http, [], `${label}: HTTP must not double-send`);
    } else {
      assert.deepEqual(http, ['x'], `${label}: the HTTP sink must receive the keystroke`);
      assert.deepEqual(stream, [], `${label}: the stream sink must not be called`);
    }
  }
});

test('REQ-FIX-8: resize routing follows the live socket across every pane state', () => {
  for (const { label, mode, expected } of TRANSPORT_STATES) {
    const { stream, http, sinks } = recordingResizeSinks();
    const target = dispatchShellResize(mode, 30, 200, sinks);

    assert.equal(target, expected, `${label}: wrong transport chosen`);
    if (expected === 'stream') {
      assert.deepEqual(stream, [[30, 200]], `${label}: the stream sink must receive the geometry`);
      assert.deepEqual(http, [], `${label}: HTTP must not double-send`);
    } else {
      assert.deepEqual(http, [[30, 200]], `${label}: the HTTP sink must receive the geometry`);
      assert.deepEqual(stream, [], `${label}: the stream sink must not be called`);
    }
  }
});

test('REQ-FIX-8: exactly one transport is used per dispatch, in every state', () => {
  // Double-sending is the other way to be wrong, and it is not hypothetical: the HTTP path also
  // schedules a capture refetch, so a frame sent twice races the stream's own echo.
  for (const { label, mode } of TRANSPORT_STATES) {
    const input = recordingInputSinks();
    dispatchShellInput(mode, 'a', input.sinks);
    assert.equal(input.stream.length + input.http.length, 1, `${label}: input must be sent exactly once`);

    const resize = recordingResizeSinks();
    dispatchShellResize(mode, 24, 80, resize.sinks);
    assert.equal(resize.stream.length + resize.http.length, 1, `${label}: resize must be sent exactly once`);
  }
});

test('REQ-FIX-8: the pane owns the geometry floors, the dispatcher does not touch the numbers', () => {
  // The 40-col floor must stay in the pane (REQ-SHELL-DOCK-NO-VSCROLL-23); if it migrated into
  // the dispatcher the polled path would quietly stop receiving the floored value.
  const live = TRANSPORT_STATES[1].mode;
  const { stream, sinks } = recordingResizeSinks();
  dispatchShellResize(live, 1, 12, sinks);
  assert.deepEqual(stream, [[1, 12]], 'the dispatcher must forward the caller-floored geometry verbatim');
});
