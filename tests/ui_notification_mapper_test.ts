import { test } from 'node:test';
import assert from 'node:assert/strict';

test('notificationForWsEvent maps curated notify events and excludes receipts/invalidations', async () => {
  const { notificationForWsEvent } = await import('../src/ui/api/notificationMapper.ts');

// --- Curated NOTIFY cases -------------------------------------------------

// (a) chat message directed to the user from an agent => notify, routes to the
// conversation deep-link, coalesces per conversation.
{
  const plan = notificationForWsEvent({
    type: 'chat_event',
    direction: 'agent_to_user',
    agent_instance_id: 'inst_abc',
    conversation_id: 'conv_1',
    message: { direction: 'agent_to_user', body: 'Deployment finished successfully.' },
  });
  assert.ok(plan, 'agent_to_user chat message should notify');
  assert.equal(plan!.category, 'chat');
  assert.equal(plan!.route, '/conversations/inst_abc', 'routes to instance-id conversation deep-link');
  assert.equal(plan!.tag, 'heimdall:chat:conv_1', 'coalesces per conversation');
  assert.equal(plan!.title, 'New message');
  assert.match(plan!.body, /Deployment finished/);
  assert.deepEqual(
    plan!.conversationKeys, ['conv_1', 'inst_abc'],
    'conversationKeys carry conversation_id + agent_instance_id for open-thread suppression',
  );
}

// (a2) hub metadata-only new-message shape: top-level direction + body_preview
// and NO nested `message` object => still notifies using the preview text.
{
  const plan = notificationForWsEvent({
    type: 'chat_event',
    event: 'chat_updated',
    direction: 'agent_to_user',
    agent_instance_id: 'inst_abc',
    conversation_id: 'conv_1',
    message_id: 'msg_1',
    message_type: 'text',
    body_preview: 'Second preview test message that is short enough.',
    fetch_required: true,
  });
  assert.ok(plan, 'agent_to_user preview event should notify');
  assert.equal(plan!.category, 'chat');
  assert.equal(plan!.route, '/conversations/inst_abc');
  assert.equal(plan!.title, 'New message');
  assert.match(plan!.body, /Second preview test message/);
}

// (a3) bodyless + preview-less chat_event (pure invalidation hint) => skip.
{
  const plan = notificationForWsEvent({
    type: 'chat_event',
    event: 'chat_updated',
    direction: 'agent_to_user',
    conversation_id: 'conv_1',
    message_id: 'msg_1',
    fetch_required: true,
  });
  assert.equal(plan, null, 'bodyless preview-less chat_event must not notify');
}

// (b) nudge => title reflects nudge, still routes to conversation.
{
  const plan = notificationForWsEvent({
    type: 'chat_event',
    direction: 'agent_to_user',
    agent_instance_id: 'inst_abc',
    conversation_id: 'conv_1',
    message: { direction: 'agent_to_user', body: 'Please review.', message_type: 'nudge' },
  });
  assert.ok(plan, 'nudge should notify');
  assert.equal(plan!.title, 'Nudge');
  assert.equal(plan!.route, '/conversations/inst_abc');
}

// (b2) mention via metadata flag.
{
  const plan = notificationForWsEvent({
    type: 'chat_event',
    direction: 'agent_to_user',
    conversation_id: 'conv_9',
    message: { direction: 'agent_to_user', body: 'hey @you look here', metadata: { mention: true } },
  });
  assert.ok(plan, 'mention should notify');
  assert.equal(plan!.title, 'You were mentioned');
}

// (b3) route is the instance-id conversation deep-link (routing is instance-id-only).
{
  const plan = notificationForWsEvent({
    type: 'chat_event',
    direction: 'agent_to_user',
    agent_instance_id: 'inst_xyz',
    message: { direction: 'agent_to_user', body: 'hello' },
  });
  assert.ok(plan);
  assert.equal(plan!.route, '/conversations/inst_xyz');
}

// (c) chat_approval (needs attention) => notify, routes to conversation/chain.
{
  const plan = notificationForWsEvent({
    type: 'chat_approval',
    event: 'chat_approval_created',
    approval: { chain_id: 'chain_1', agent_instance_id: 'inst_a', kind: 'question', body: 'Proceed with delete?' },
  });
  assert.ok(plan, 'chat_approval_created should notify');
  assert.equal(plan!.category, 'attention');
  assert.equal(plan!.route, '/conversations/inst_a');
  assert.match(plan!.body, /Proceed with delete/);
  assert.equal(plan!.tag, 'heimdall:attention:approval:chain_1');
}

// (c2) multi_question approval => distinct title.
{
  const plan = notificationForWsEvent({
    type: 'chat_approval',
    event: 'chat_approval_created',
    approval: { chain_id: 'chain_2', kind: 'multi_question', title: 'A few questions' },
  });
  assert.ok(plan);
  assert.equal(plan!.title, 'Agent needs answers');
}

// (d) merge_decision_pending => notify, routes to chain.
{
  const plan = notificationForWsEvent({
    type: 'merge_decision_pending',
    chain_id: 'chain_7',
    summary: 'Fast-forward available',
  });
  assert.ok(plan, 'merge_decision_pending should notify');
  assert.equal(plan!.category, 'attention');
  assert.equal(plan!.route, '/chains/chain_7');
  assert.equal(plan!.tag, 'heimdall:attention:merge:chain_7');
}

// --- EXCLUDED (never notify) cases ---------------------------------------

// Status-only receipts must never notify.
for (const direction of ['read', 'delivered', 'delivery_failed']) {
  const plan = notificationForWsEvent({ type: 'chat_event', direction, agent_instance_id: 'inst_a', message_id: 'm1' });
  assert.equal(plan, null, `chat_event ${direction} receipt must not notify`);
}

// chat_event without an inline message (invalidation hint) => skip.
assert.equal(
  notificationForWsEvent({ type: 'chat_event', agent_instance_id: 'inst_a', fetch_required: true }),
  null,
  'chat_event without inline message must not notify',
);

// user_to_agent (the user's own message) => skip.
assert.equal(
  notificationForWsEvent({ type: 'chat_event', direction: 'user_to_agent', message: { direction: 'user_to_agent', body: 'hi' } }),
  null,
  'user_to_agent message must not notify',
);

// Empty body => skip.
assert.equal(
  notificationForWsEvent({ type: 'chat_event', direction: 'agent_to_user', message: { direction: 'agent_to_user', body: '  ' } }),
  null,
  'empty message body must not notify',
);

// chat_approval non-creation (answered/dismissed) => skip.
assert.equal(
  notificationForWsEvent({ type: 'chat_approval', event: 'chat_approval_dismissed', approval: { chain_id: 'c' } }),
  null,
  'chat_approval dismissal must not notify',
);

// Generic invalidations / lifecycle / memory / task / audit => never notify.
for (const type of [
  'resource_changed',
  'agent_update',
  'agent_lifecycle_changed',
  'agent_runtime_changed',
  'memory_event',
  'audit_start',
  'audit_end',
  'task_event',
]) {
  assert.equal(notificationForWsEvent({ type }), null, `${type} must not notify`);
}

// Unknown/undefined types => skip gracefully.
assert.equal(notificationForWsEvent({ type: 'totally_unknown' }), null);
assert.equal(notificationForWsEvent({}), null);
assert.equal(notificationForWsEvent(null as any), null);
});
