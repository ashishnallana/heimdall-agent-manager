// Tool activity messages (REQ-EXT-CONV-1/2 UI): the bridge's per-turn
// `tool_activity` message model (calls, nested subagent groups, counts, the
// omitted tail from the 4KB cap), the silent realtime frame, and source checks
// for the compact renderer and its wiring.
//
// RUN: node --test tests/ui_extension_tool_activity_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

import {
  isToolActivityMessage,
  normalizeToolActivityCall,
  parseToolActivity,
  toolActivityBadge,
  toolActivityCallDuration,
  toolActivityCallFile,
  toolActivityHeadline,
  toolActivityOmittedLabel,
  toolActivitySubagentLabel,
} from '../src/ui/components/extension/toolActivityModel.ts';
import { isAgentStartMessage } from '../src/ui/components/chat/transcriptGrouping.ts';
import { notificationForWsEvent } from '../src/ui/api/notificationMapper.ts';

const read = (rel: string) => fs.readFileSync(fileURLToPath(new URL(rel, import.meta.url)), 'utf8');

// The shape the bridge renders (src/bridge/extension_tool_aggregator.odin).
const META = {
  v: 1,
  reason: 'idle',
  final: true,
  turn_started_at: '2026-10-22T06:00:00Z',
  turn_ended_at: '2026-10-22T06:05:00Z',
  counts: { total: 6, ok: 4, error: 1, running: 1, edits: 2, files_edited: 2, commands: 1, reads: 1, searches: 1, other: 0, subagents: 1, omitted: 1, by_tool: { Edit: 2, Bash: 1, Grep: 1, Read: 1 } },
  calls: [
    { tool: 'Edit', summary: '/w/a.odin', status: 'ok', duration_ms: 12, use_id: 'tu_1', file_path: '/w/a.odin' },
    { tool: 'Bash', summary: 'odin build src/bridge', status: 'error', duration_ms: 2400, use_id: 'tu_2' },
    { tool: 'Read', summary: '/w/README.md', status: 'ok', duration_ms: 3, file_path: '/w/README.md' },
  ],
  subagents: [
    { agent_id: 'sub-1', agent_type: 'Explore', description: 'Find callers', status: 'done', counts: { total: 3, error: 0, running: 1 },
      calls: [
        { tool: 'Grep', summary: 'proc_x', status: 'ok', duration_ms: 40 },
        { tool: 'Write', summary: '/w/b.odin', status: 'running', duration_ms: 0, file_path: '/w/b.odin' },
      ] },
  ],
};

test('parseToolActivity normalises calls, nested subagent groups and counts', () => {
  const a = parseToolActivity(META);
  assert.equal(a.reason, 'idle');
  assert.equal(a.final, true);
  assert.equal(a.turnStartedAt, '2026-10-22T06:00:00Z');
  assert.equal(a.turnEndedAt, '2026-10-22T06:05:00Z');
  assert.equal(a.calls.length, 3);
  assert.deepEqual(a.calls[1], { tool: 'Bash', summary: 'odin build src/bridge', status: 'error', durationMs: 2400, useId: 'tu_2', filePath: '', subagentId: '' });
  assert.equal(a.subagents.length, 1);
  const g = a.subagents[0];
  assert.equal(g.agentId, 'sub-1');
  assert.equal(g.status, 'done');
  assert.equal(g.total, 3);
  assert.equal(g.calls.length, 2);
  assert.equal(g.calls[1].status, 'running');
  assert.equal(a.counts.total, 6);
  assert.equal(a.counts.error, 1);
  assert.equal(a.counts.filesEdited, 2);
  assert.equal(a.counts.subagents, 1);
  assert.equal(a.counts.omitted, 1);
  // by_tool sorted by count, then name.
  assert.deepEqual(a.counts.byTool.map((e) => e.tool), ['Edit', 'Bash', 'Grep', 'Read']);
});

test('parseToolActivity accepts a JSON string and tolerates partial or junk payloads', () => {
  const fromString = parseToolActivity(JSON.stringify(META));
  assert.equal(fromString.calls.length, 3);
  const junk = parseToolActivity('not json');
  assert.equal(junk.calls.length, 0);
  assert.equal(junk.counts.total, 0);
  // Missing counts are derived from the listed calls.
  const partial = parseToolActivity({ calls: [{ tool: 'Bash', summary: 'ls', status: 'error' }, { tool: '' }, { summary: 'no tool' }, { tool: 'Read' }] });
  assert.equal(partial.calls.length, 2);
  assert.equal(partial.calls[1].summary, 'Read'); // summary falls back to the tool
  assert.equal(partial.calls[1].durationMs, null);
  assert.equal(partial.counts.total, 2);
  assert.equal(partial.counts.error, 1);
  assert.equal(partial.counts.ok, 1);
  assert.equal(normalizeToolActivityCall(null), null);
  assert.equal(normalizeToolActivityCall({ tool: 'X', status: 'weird' })?.status, 'ok');
});

test('collapsed one-liner: hub body first, count badge, omitted tail label', () => {
  const a = parseToolActivity(META);
  assert.equal(toolActivityHeadline('Edited 2 files  ·  ran 1 command', a), 'Edited 2 files · ran 1 command');
  assert.equal(toolActivityHeadline('', a), '6 tool calls');
  assert.equal(toolActivityHeadline('', parseToolActivity({ calls: [{ tool: 'Bash' }] })), '1 tool call');
  assert.equal(toolActivityBadge(a), '6 calls · 1 failed');
  assert.equal(toolActivityBadge(parseToolActivity({ counts: { total: 1 } })), '1 call');
  assert.equal(toolActivityOmittedLabel(a), '+ 1 more call — see the Activity timeline');
  assert.equal(toolActivityOmittedLabel(parseToolActivity({ counts: { omitted: 4 }, omitted_subagents: 2 })), '+ 4 more calls and 2 more subagents — see the Activity timeline');
  assert.equal(toolActivityOmittedLabel(parseToolActivity({})), '');
});

test('call rows: duration, subagent labels, and only edits link to the diff viewer', () => {
  const a = parseToolActivity(META);
  assert.equal(toolActivityCallDuration(a.calls[0]), '12ms');
  assert.equal(toolActivityCallDuration(a.calls[1]), '2s');
  assert.equal(toolActivityCallDuration(a.subagents[0].calls[1]), 'running');
  assert.equal(toolActivitySubagentLabel(a.subagents[0]), 'Explore · Find callers');
  assert.equal(toolActivitySubagentLabel({ ...a.subagents[0], agentType: '', description: '' }), 'Subagent');
  assert.equal(toolActivityCallFile(a.calls[0]), '/w/a.odin'); // Edit
  assert.equal(toolActivityCallFile(a.subagents[0].calls[1]), '/w/b.odin'); // Write
  assert.equal(toolActivityCallFile(a.calls[2]), ''); // Read: path but no diff
  assert.equal(toolActivityCallFile(a.calls[1]), '');
});

test('tool_activity is not an agent-start notice and its realtime frame never notifies', () => {
  const msg = { messageId: 'm1', messageType: 'tool_activity', body: 'Spawned 1 subagent · ran 2 commands', isUser: false } as any;
  assert.equal(isToolActivityMessage(msg), true);
  assert.equal(isToolActivityMessage({ messageType: 'text' }), false);
  // A body containing "started"/"ready" must not be sniffed as a start notice.
  assert.equal(isAgentStartMessage({ ...msg, body: 'Started 1 subagent · read 2 files (ready)' }), false);
  // The hub frame: fetch hint, direction tool_activity, no body preview.
  const frame = { type: 'chat_event', event: 'chat_updated', direction: 'tool_activity', agent_instance_id: 'inst_1', conversation_id: 'chat_1',
    message_id: 'm1', message_type: 'tool_activity', fetch_required: true, fetch_kind: 'chat_message', fetch_id: 'm1' };
  assert.equal(notificationForWsEvent(frame), null);
});

test('renderer and wiring: compact row, no card chrome, file click opens the Activity diff', () => {
  const pane = read('../src/ui/components/workbench/AgentChatPane.tsx');
  assert.match(pane, /message\.messageType === 'tool_activity'\) \{\s*return \(\s*<ToolActivityRow/);
  assert.match(pane, /onOpenFile=\{\(filePath\) => openAux\(\{ type: 'activity', filePath \}\)\}/);
  const list = read('../src/ui/components/chat/ChatMessageList.tsx');
  assert.match(list, /hideCardChrome = isDivider \|\| isClubbedGroup \|\| message\.messageType === 'tool_activity'/);
  const row = read('../src/ui/components/extension/ToolActivityRow.tsx');
  assert.match(row, /aria-expanded=\{open\}/);
  assert.match(row, /conversation-tool-activity-\$\{messageId\}/);
  const tabs = read('../src/ui/store/auxTabId.ts');
  assert.match(tabs, /type: 'activity';\s*\/\*\*[^*]*\*\/\s*filePath\?: string \| null;/);
  const content = read('../src/ui/components/auxiliary/AuxTabContent.tsx');
  assert.match(content, /openFilePath=\{c\.filePath \|\| null\}/);
  const panel = read('../src/ui/components/extension/ActivityTimelinePanel.tsx');
  assert.match(panel, /setView\('files'\);\s*setOpenFile\(openFilePath\);\s*onFileOpened\?\.\(\);/);
});

test('consecutive tool_activity messages club into one group; the trailing one stays out', async () => {
  const { groupTranscriptMessages } = await import('../src/ui/components/chat/transcriptGrouping.ts');
  const mk = (id: string, messageType: string, body = '') => ({
    key: id, messageId: id, body, isUser: false, createdUnixMs: Number(id.replace(/\D/g, '')) || 1,
    deliveredUnixMs: 0, readUnixMs: 0, deliveryFailedUnixMs: 0, deliveryError: '', sending: false,
    authorLabel: '', messageType, messageStatus: 'complete', metadata: {},
  });
  // Live turn: three tool rows end the transcript -> first two clubbed, newest stays out.
  const live = groupTranscriptMessages([mk('m1', 'text', 'hi'), mk('t2', 'tool_activity'), mk('t3', 'tool_activity'), mk('t4', 'tool_activity')] as any);
  assert.deepEqual(live.map((m: any) => m.messageType), ['text', 'tool_activity_group', 'tool_activity']);
  assert.deepEqual(live[1].metadata.clubbedActivities.map((m: any) => m.messageId), ['t2', 't3']);
  assert.equal(live[2].messageId, 't4');
  // A message follows: the newest tool row folds into the group.
  const settled = groupTranscriptMessages([mk('t2', 'tool_activity'), mk('t3', 'tool_activity'), mk('t4', 'tool_activity'), mk('m5', 'text', 'done')] as any);
  assert.deepEqual(settled.map((m: any) => m.messageType), ['tool_activity_group', 'text']);
  assert.equal(settled[0].metadata.count, 3);
  // A single tool row (trailing or not) is never wrapped.
  assert.deepEqual(groupTranscriptMessages([mk('t1', 'tool_activity'), mk('m2', 'text')] as any).map((m: any) => m.messageType), ['tool_activity', 'text']);
  assert.deepEqual(groupTranscriptMessages([mk('t1', 'tool_activity'), mk('t2', 'tool_activity')] as any).map((m: any) => m.messageType), ['tool_activity', 'tool_activity']);
});

test('tool activity group reads "Ran X commands" with failures only when present', async () => {
  const { toolActivityGroupSummary } = await import('../src/ui/components/extension/toolActivityModel.ts');
  const s = toolActivityGroupSummary([
    { counts: { total: 3, ok: 3, commands: 2, files_edited: 1 } },
    { counts: { total: 2, ok: 1, error: 1, commands: 1 } },
  ]);
  assert.equal(s.headline, 'Ran 5 commands');
  assert.equal(s.badge, '1 failed');
  assert.deepEqual(toolActivityGroupSummary([{ counts: { total: 1, ok: 1 } }]), { headline: 'Ran 1 command', badge: '' });
});

test('conversation renders tool_activity_group without card chrome', () => {
  const pane = read('../src/ui/components/workbench/AgentChatPane.tsx');
  assert.match(pane, /messageType === 'tool_activity_group'/);
  assert.match(pane, /<ToolActivityGroup/);
  const list = read('../src/ui/components/chat/ChatMessageList.tsx');
  assert.match(list, /tool_activity_group/);
});

test('tool activity rows use text, not the zap icon', () => {
  const row = read('../src/ui/components/extension/ToolActivityRow.tsx');
  assert.doesNotMatch(row, /name="zap"/);
});
