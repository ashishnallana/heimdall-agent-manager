// Conversation regressions for retired persisted tool rows and current live tools.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { isAgentStartMessage } from '../src/ui/components/chat/transcriptGrouping.ts';
import { notificationForWsEvent } from '../src/ui/api/notificationMapper.ts';

const read = (rel: string) => fs.readFileSync(fileURLToPath(new URL(rel, import.meta.url)), 'utf8');

test('tool_activity is not an agent-start notice and its realtime frame never notifies', () => {
  const msg = { messageId: 'm1', messageType: 'tool_activity', body: 'Spawned 1 subagent · ran 2 commands', isUser: false } as any;
  // A body containing "started"/"ready" must not be sniffed as a start notice.
  assert.equal(isAgentStartMessage({ ...msg, body: 'Started 1 subagent · read 2 files (ready)' }), false);
  // The hub frame: fetch hint, direction tool_activity, no body preview.
  const frame = { type: 'chat_event', event: 'chat_updated', direction: 'tool_activity', agent_instance_id: 'inst_1', conversation_id: 'chat_1',
    message_id: 'm1', message_type: 'tool_activity', fetch_required: true, fetch_kind: 'chat_message', fetch_id: 'm1' };
  assert.equal(notificationForWsEvent(frame), null);
});

test('legacy tool transcript rows stay hidden without altering the raw server page', async () => {
  const { groupTranscriptMessages } = await import('../src/ui/components/chat/transcriptGrouping.ts');
  const rows = [
    { key: 'm1', messageId: 'm1', messageType: 'text', body: 'hello' },
    { key: 't1', messageId: 't1', messageType: 'tool_activity', body: '' },
    { key: 't2', messageId: 't2', messageType: 'tool_activity_group', body: '' },
    { key: 's1', messageId: 's1', messageType: 'shell_run', body: '' },
  ] as any;
  assert.deepEqual(groupTranscriptMessages(rows).map((m: any) => m.messageId), ['m1']);
  assert.equal(rows.length, 4, 'raw server page must stay intact');
});

test('conversation uses volatile live tools instead of persisted activity rows', () => {
  const pane = read('../src/ui/components/workbench/AgentChatPane.tsx');
  assert.match(pane, /<LiveToolActivity/);
  assert.doesNotMatch(pane, /<ToolActivityRow|<ToolActivityGroup|<PinnedShellRuns|useConversationRuns/);
});
