// The agent activity row shows an action like a tool call: a verb from the hub's
// agent_action kind plus whatever the hub's summary adds (agentActionLabels.ts).
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_agent_action_labels_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

const { agentActionLine } = await import('../src/ui/components/chat/agentActionLabels.ts');

test('known kinds get a verb; the summary adds only what the verb does not say', () => {
  assert.deepEqual(agentActionLine('chat_read', 'read 2 messages'), { verb: 'Reading messages', detail: '' });
  assert.deepEqual(agentActionLine('task_show', 'opened a task'), { verb: 'Reading task', detail: '' });
  assert.deepEqual(agentActionLine('task_comment', 'commented: Signed key verification is in'), { verb: 'Commenting on task', detail: 'Signed key verification is in' });
  assert.deepEqual(agentActionLine('task_create', 'created task "Wire the redirect"'), { verb: 'Creating task', detail: 'Wire the redirect' });
  assert.deepEqual(agentActionLine('memory_show', 'opened memory “Vault wraps”'), { verb: 'Opening memory', detail: 'Vault wraps' });
});

test('unknown kinds fall back to the hub summary', () => {
  assert.deepEqual(agentActionLine('something_new', 'did a new thing'), { verb: 'did a new thing', detail: '' });
  assert.deepEqual(agentActionLine('', ''), { verb: 'Working', detail: '' });
});
