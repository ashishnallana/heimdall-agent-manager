// REQ-PTY-NET-5: visibility gating of pane sockets.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_pane_visibility_gate_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { PANE_HIDDEN_PAUSE_MS, createVisibilityGate } from '../src/ui/components/shells/paneVisibilityGate.ts';

function fakeClock() {
  const timers = new Map<number, { fn: () => void; at: number }>();
  let now = 0;
  let next = 1;
  return {
    setTimeout: (fn: () => void, ms: number) => { const id = next++; timers.set(id, { fn, at: now + ms }); return id; },
    clearTimeout: (h: unknown) => { timers.delete(h as number); },
    advance(ms: number) {
      now += ms;
      for (const [id, t] of [...timers.entries()].sort((a, b) => a[1].at - b[1].at)) {
        if (t.at <= now) { timers.delete(id); t.fn(); }
      }
    },
    get pending() { return timers.size; },
  };
}

test('a hidden pane is paused only after the grace, and resumes immediately on visible', () => {
  const clock = fakeClock();
  let hidden = false;
  const events: string[] = [];
  const gate = createVisibilityGate({
    isHidden: () => hidden,
    onPause: () => events.push('pause'),
    onResume: () => events.push('resume'),
    setTimeout: clock.setTimeout,
    clearTimeout: clock.clearTimeout,
  });

  hidden = true;
  gate.notify();
  clock.advance(PANE_HIDDEN_PAUSE_MS - 1);
  assert.deepEqual(events, [], 'nothing happens inside the grace');
  assert.equal(gate.paused, false);
  clock.advance(1);
  assert.deepEqual(events, ['pause']);
  assert.equal(gate.paused, true);

  hidden = false;
  gate.notify();
  assert.deepEqual(events, ['pause', 'resume'], 'resume is immediate, no timer');
  assert.equal(gate.paused, false);
});

test('a quick tab flick (hidden -> visible inside the grace) costs nothing', () => {
  const clock = fakeClock();
  let hidden = true;
  const events: string[] = [];
  const gate = createVisibilityGate({
    isHidden: () => hidden,
    onPause: () => events.push('pause'),
    onResume: () => events.push('resume'),
    pauseAfterMs: 100,
    setTimeout: clock.setTimeout,
    clearTimeout: clock.clearTimeout,
  });
  gate.notify();
  clock.advance(50);
  hidden = false;
  gate.notify();
  clock.advance(1000);
  assert.deepEqual(events, [], 'no pause, so no resume either');
  assert.equal(clock.pending, 0, 'the pending pause was cancelled');
});

test('redundant notifications do not stack timers; dispose cancels everything', () => {
  const clock = fakeClock();
  let hidden = true;
  const events: string[] = [];
  const gate = createVisibilityGate({
    isHidden: () => hidden,
    onPause: () => events.push('pause'),
    onResume: () => events.push('resume'),
    pauseAfterMs: 100,
    setTimeout: clock.setTimeout,
    clearTimeout: clock.clearTimeout,
  });
  gate.notify();
  gate.notify();
  gate.notify();
  assert.equal(clock.pending, 1);
  gate.dispose();
  clock.advance(1000);
  assert.deepEqual(events, []);
  hidden = false;
  gate.notify();
  assert.deepEqual(events, [], 'a disposed gate never calls back');
});

test('the hook refuses connect() while hidden-paused (source contract)', async () => {
  const fs = await import('node:fs');
  for (const file of ['src/ui/components/shells/useShellStream.ts', 'src/ui/components/chat/useAgentStream.ts']) {
    const src = fs.readFileSync(file, 'utf8');
    assert.match(src, /hiddenPausedRef\.current\) return;/, `${file}: connect() must bail while hidden-paused`);
    assert.match(src, /createVisibilityGate\(/, `${file}: installs the visibility gate`);
    assert.match(src, /stoppedRef\.current = true;\s*closeSocket\(\);/, `${file}: an unmounted pane closes its socket`);
  }
});
