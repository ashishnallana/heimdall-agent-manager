// REQ-PTY-NET-3: input coalescing within one macrotask.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_pty_input_coalescer_test.ts

import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { createInputCoalescer } from '../src/ui/components/shells/ptyInputCoalescer.ts';

test('onData chunks within one macrotask leave as ONE send, in order', () => {
  const sent: string[] = [];
  const scheduled: Array<() => void> = [];
  const c = createInputCoalescer((chunk) => sent.push(chunk), (flush) => scheduled.push(flush));

  c.push('l');
  c.push('s');
  c.push(' -la\r');
  assert.deepEqual(sent, [], 'nothing leaves before the task ends');
  assert.equal(scheduled.length, 1, 'exactly one flush is scheduled per burst');
  assert.equal(c.pendingLength, 7);

  scheduled[0]();
  assert.deepEqual(sent, ['ls -la\r']);
  assert.equal(c.pendingLength, 0);

  // A later keystroke starts a new burst with its own flush.
  c.push('x');
  assert.equal(scheduled.length, 2);
  scheduled[1]();
  assert.deepEqual(sent, ['ls -la\r', 'x']);
});

test('a flush splits at the 8 KiB input budget without breaking a surrogate pair', () => {
  const sent: string[] = [];
  const scheduled: Array<() => void> = [];
  const c = createInputCoalescer((chunk) => sent.push(chunk), (flush) => scheduled.push(flush));
  const paste = 'a'.repeat(8191) + '😀' + 'b'.repeat(100);
  c.push(paste);
  scheduled[0]();
  assert.equal(sent.length, 2);
  assert.equal(sent.join(''), paste);
  assert.ok(sent[0].length <= 8192 && !/[\ud800-\udbff]$/.test(sent[0]), 'first chunk ends on a whole code point');
});

test('empty pushes schedule nothing; reset drops pending input', () => {
  const sent: string[] = [];
  const scheduled: Array<() => void> = [];
  const c = createInputCoalescer((chunk) => sent.push(chunk), (flush) => scheduled.push(flush));
  c.push('');
  assert.equal(scheduled.length, 0);
  c.push('abc');
  c.reset();
  scheduled[0]();
  assert.deepEqual(sent, [], 'reset input is never sent (the socket it was for is gone)');
});

test('the default schedule is a macrotask (setTimeout 0): a second push in the same tick merges', async () => {
  const sent: string[] = [];
  const c = createInputCoalescer((chunk) => sent.push(chunk));
  c.push('a');
  await Promise.resolve(); // a microtask boundary must NOT flush
  c.push('b');
  assert.deepEqual(sent, []);
  await new Promise((resolve) => setTimeout(resolve, 5));
  assert.deepEqual(sent, ['ab']);
});
