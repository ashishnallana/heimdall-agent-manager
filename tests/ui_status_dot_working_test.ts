import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isAgentWorking } from '../src/ui/components/shell/agentWorking.ts';

test('isAgentWorking predicate distinguishes live working agents from idle or non-live agents', () => {
  assert.equal(isAgentWorking('live', 'active'), true, 'live+active => working');
  assert.equal(isAgentWorking('live', 'busy'), true, 'live+busy => working');
  assert.equal(isAgentWorking('live', 'working'), true, 'live+working => working');
  assert.equal(isAgentWorking('live', 'ACTIVE'), true, 'case-insensitive');

  assert.equal(isAgentWorking('live', 'idle'), false, 'live+idle => static, not working');
  assert.equal(isAgentWorking('live', ''), false, 'live+empty => static');
  assert.equal(isAgentWorking('live', undefined), false, 'live+undefined => static');

  assert.equal(isAgentWorking('starting', 'active'), false, 'starting is not working');
  assert.equal(isAgentWorking('stopped', 'active'), false, 'stopped is not working (stale activity ignored)');
  assert.equal(isAgentWorking('', 'active'), false, 'unknown state is not working');
});
