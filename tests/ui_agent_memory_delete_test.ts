// Agent delete is offered only when nothing refers to the agent, and the usage
// body is read defensively (agents.ts normalizeAgentUsage, agentModel.ts).
// Memory delete always states that it is permanent (memoryModel.ts).
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_agent_memory_delete_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

const { normalizeAgentUsage } = await import('../src/ui/api/endpoints/agents.ts');
const { agentUsageSummary, deleteConfirmBody } = await import('../src/ui/components/agents/agentModel.ts');
const { MEMORY_DELETE_CONFIRM_BODY } = await import('../src/ui/components/memory/memoryModel.ts');

const ZERO = { instances: 0, conversations: 0, messages: 0, artifacts: 0, chains: 0, tasks: 0, memories: 0, actions: 0, workflows: 0 };

test('an unused agent is deletable', () => {
  const result = normalizeAgentUsage({ deletable: true, usage: { ...ZERO } });
  assert.equal(result.deletable, true);
  assert.deepEqual(result.usage, ZERO);
});

test('any reference makes an agent not deletable, whatever the flag says', () => {
  assert.equal(normalizeAgentUsage({ deletable: true, usage: { ...ZERO, tasks: 1 } }).deletable, false);
  assert.equal(normalizeAgentUsage({ deletable: false, usage: ZERO }).deletable, false);
});

test('a missing or malformed body never offers Delete', () => {
  for (const raw of [null, undefined, {}, { deletable: 'true', usage: ZERO }]) {
    assert.equal(normalizeAgentUsage(raw).deletable, false, JSON.stringify(raw));
  }
  const odd = normalizeAgentUsage({ deletable: true, usage: { instances: -3, chains: 'x', tasks: 2.7 } });
  assert.equal(odd.usage.instances, 0);
  assert.equal(odd.usage.chains, 0);
  assert.equal(odd.usage.tasks, 2);
  assert.equal(odd.deletable, false);
});

test('the usage summary lists non-zero counts in the hub order', () => {
  assert.equal(agentUsageSummary(ZERO), '');
  assert.equal(agentUsageSummary(null), '');
  assert.equal(agentUsageSummary({ ...ZERO, tasks: 3, instances: 1, memories: 1 }), '1 instance, 3 tasks, 1 memory');
});

test('both confirms say the delete is permanent', () => {
  assert.match(deleteConfirmBody('Reviewer'), /"Reviewer"/);
  assert.match(deleteConfirmBody('Reviewer'), /can't be undone/);
  assert.match(MEMORY_DELETE_CONFIRM_BODY, /permanently/);
  assert.match(MEMORY_DELETE_CONFIRM_BODY, /archive it instead/);
});
