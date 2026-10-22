// Activity timeline (REQ-EXT-SUB-2, REQ-EXT-FILE-1 UI): tool calls in order,
// subagents grouped under the parent conversation with their own tool calls and
// files, the "Files edited" list, and the unified-diff parser feeding the shared
// diff viewer. Source checks cover the aux tab wiring.
//
// RUN: node --test tests/ui_extension_timeline_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

import {
  buildActivityTimeline,
  diffLineStats,
  formatDuration,
  latestDiffEdit,
  mergeExtensionEvents,
  normalizeExtensionEvents,
  normalizeFileSummaries,
  normalizeSubagentSummaries,
  parseUnifiedDiff,
  type TimelineSubagentGroup,
  type TimelineToolCall,
} from '../src/ui/components/extension/extensionTimelineModel.ts';

const t = (s: number) => new Date(Date.parse('2026-10-22T07:00:00Z') + s * 1000).toISOString();

function ev(seq: number, event: string, extra: Record<string, any> = {}) {
  return { seq, event, ts: t(seq), session_id: 'sess', agent: { id: extra.agent_id || '', type: extra.agent_type || '' },
    tool_name: extra.tool_name || '', tool_use_id: extra.tool_use_id || '', file_path: extra.file_path || '',
    created_at: t(seq), payload: extra.payload || {} };
}

const DIFF = '--- a/src/a.ts\n+++ b/src/a.ts\n@@ -1,2 +1,2 @@\n line\n-old\n+new\n';

const RAW = { events: [
  ev(1, 'tool.start', { tool_name: 'Read', tool_use_id: 'tu1', payload: { input: { file_path: '/r/README.md' } } }),
  ev(2, 'tool.end', { tool_name: 'Read', tool_use_id: 'tu1' }),
  ev(3, 'tool.start', { tool_name: 'Agent', tool_use_id: 'tu2', payload: { input: { description: 'Explore code' } } }),
  ev(4, 'subagent.start', { agent_id: 'sa1', agent_type: 'Explore', payload: { description: 'Explore code' } }),
  ev(5, 'tool.start', { agent_id: 'sa1', tool_name: 'Bash', tool_use_id: 'tu3', payload: { input: { command: 'ls -la\nmore' } } }),
  ev(6, 'tool.end', { agent_id: 'sa1', tool_name: 'Bash', tool_use_id: 'tu3', payload: { response: { is_error: true } } }),
  ev(7, 'file.edit', { agent_id: 'sa1', tool_name: 'Edit', file_path: 'src/a.ts', payload: { diff: DIFF } }),
  ev(8, 'subagent.stop', { agent_id: 'sa1', agent_type: 'Explore' }),
  ev(9, 'tool.end', { tool_name: 'Agent', tool_use_id: 'tu2' }),
  ev(10, 'file.edit', { tool_name: 'Write', file_path: 'src/b.ts', payload: { diff: '+x', diff_truncated: true } }),
  ev(11, 'subagent.start', { agent_id: 'sa2', agent_type: 'general-purpose' }),
  ev(12, 'tool.start', { tool_name: 'Edit', tool_use_id: 'tu4', payload: { input: { file_path: 'src/a.ts' } } }),
  ev(13, 'file.edit', { tool_name: 'Edit', file_path: 'src/a.ts', payload: { diff: DIFF } }),
] };

test('normalisation reads agent ids and drops malformed rows', () => {
  const evs = normalizeExtensionEvents({ events: [...RAW.events, { seq: 0, event: 'x' }, { seq: 99 }] });
  assert.equal(evs.length, RAW.events.length);
  assert.equal(evs[3].agent_id, 'sa1');
  assert.equal(evs[3].agent_type, 'Explore');
});

test('merge dedupes by seq and keeps ascending order', () => {
  const evs = normalizeExtensionEvents(RAW);
  const merged = mergeExtensionEvents(evs.slice(0, 5), [...evs.slice(3, 8), evs[0]]);
  assert.deepEqual(merged.map((e) => e.seq), [1, 2, 3, 4, 5, 6, 7, 8]);
});

test('parent tool calls are in order and paired start/end', () => {
  const tl = buildActivityTimeline(normalizeExtensionEvents(RAW));
  const parent = tl.entries.filter((e) => e.kind === 'tool') as TimelineToolCall[];
  assert.deepEqual(parent.map((c) => c.toolName), ['Read', 'Agent', 'Edit']);
  assert.equal(parent[0].status, 'done');
  assert.equal(parent[0].summary, '/r/README.md');
  assert.equal(parent[0].durationMs, 1000);
  assert.equal(parent[2].status, 'running');
  assert.equal(tl.toolCallCount, 4);
});

test('subagents nest under the parent with their own tool calls and files', () => {
  const tl = buildActivityTimeline(normalizeExtensionEvents(RAW));
  assert.deepEqual(tl.entries.map((e) => `${e.kind}:${e.seq}`), ['tool:1', 'tool:3', 'subagent:4', 'subagent:11', 'tool:12']);
  const sa1 = tl.subagents[0] as TimelineSubagentGroup;
  assert.equal(sa1.agentType, 'Explore');
  assert.equal(sa1.description, 'Explore code');
  assert.equal(sa1.status, 'done');
  assert.equal(sa1.durationMs, 4000);
  assert.equal(formatDuration(sa1.durationMs), '4s');
  assert.deepEqual(sa1.toolCalls.map((c) => [c.toolName, c.status, c.summary]), [['Bash', 'failed', 'ls -la']]);
  assert.deepEqual(sa1.files.map((f) => f.filePath), ['src/a.ts']);
  const sa2 = tl.subagents[1];
  assert.equal(sa2.status, 'running');
  assert.equal(sa2.durationMs, null);
  assert.equal(tl.runningSubagents, 1);
});

test('files edited: newest first with every editing agent and the latest diff', () => {
  const tl = buildActivityTimeline(normalizeExtensionEvents(RAW));
  assert.deepEqual(tl.files.map((f) => [f.filePath, f.editCount]), [['src/a.ts', 2], ['src/b.ts', 1]]);
  assert.deepEqual(tl.files[0].agentIds, ['sa1', '']);
  assert.equal(latestDiffEdit(tl.files[0])?.seq, 13);
  assert.equal(tl.files[1].edits[0].diffTruncated, true);
});

test('tool calls from an unseen subagent create its group; orphan ends show as done', () => {
  const tl = buildActivityTimeline(normalizeExtensionEvents({ events: [
    ev(20, 'tool.end', { tool_name: 'Grep', tool_use_id: 'gone' }),
    ev(21, 'tool.start', { agent_id: 'sa9', tool_name: 'Read', tool_use_id: 'r9' }),
  ] }));
  assert.equal(tl.entries[0].kind, 'tool');
  assert.equal((tl.entries[0] as TimelineToolCall).status, 'done');
  assert.equal(tl.subagents[0].agentId, 'sa9');
  assert.equal(tl.subagents[0].toolCalls.length, 1);
});

test('hub rollups fill trimmed subagents, status and file counts', () => {
  const tl = buildActivityTimeline(
    normalizeExtensionEvents({ events: [ev(30, 'subagent.start', { agent_id: 'sa1', agent_type: 'Explore' })] }),
    normalizeSubagentSummaries({ subagents: [
      { agent_id: 'sa1', agent_type: 'Explore', description: 'Look around', status: 'done', started_at: t(30), stopped_at: t(90), event_count: 3 },
      { agent_id: 'old', agent_type: 'Plan', description: 'Earlier plan', status: 'done', started_at: t(1), stopped_at: t(5), event_count: 9 },
    ] }),
    normalizeFileSummaries({ files: [{ file_path: 'x.go', edit_count: 4, last_seq: 7, last_at: t(7), agent_ids: ['old'] }] }),
  );
  assert.deepEqual(tl.subagents.map((g) => [g.agentId, g.status, g.description]), [['old', 'done', 'Earlier plan'], ['sa1', 'done', 'Look around']]);
  assert.equal(tl.subagents[1].durationMs, 60_000);
  assert.deepEqual(tl.files.map((f) => [f.filePath, f.editCount, f.edits.length]), [['x.go', 4, 0]]);
});

test('unified diff parsing feeds the diff viewer hunks', () => {
  const hunks = parseUnifiedDiff(DIFF);
  assert.equal(hunks.length, 1);
  assert.deepEqual(hunks[0].lines, [{ op: ' ', text: 'line' }, { op: '-', text: 'old' }, { op: '+', text: 'new' }]);
  assert.deepEqual(diffLineStats(DIFF), { added: 1, removed: 1 });
  assert.deepEqual(parseUnifiedDiff('+a\n-b').map((h) => h.lines.length), [2]);
  assert.deepEqual(parseUnifiedDiff(''), []);
});

const root = fileURLToPath(new URL('..', import.meta.url));
const read = (p: string) => fs.readFileSync(`${root}/${p}`, 'utf8');

test('timeline is an aux tab that reuses the shared diff viewer', () => {
  const tabs = read('src/ui/store/auxTabId.ts');
  assert.match(tabs, /'activity'/);
  assert.match(read('src/ui/components/auxiliary/AuxTabContent.tsx'), /<ActivityTimelinePanel/);
  assert.match(read('src/ui/components/extension/ActivityTimelinePanel.tsx'), /MonacoDiffViewer/);
});

// Shapes exactly as T4's Claude adapter emits them (src/ctl/extension/claude.odin):
// subagent hooks carry no description; the parent's Agent tool.start has
// payload.description/subagent_type and its tool.end names payload.subagent_id.
test('T4 shapes: subagent description comes from the parent Agent call it links to', () => {
  const events = normalizeExtensionEvents([
    ev(1, 'tool.start', { tool_name: 'Agent', tool_use_id: 'toolu_a', payload: { description: 'Find auth code', subagent_type: 'Explore', run_in_background: false } }),
    ev(2, 'subagent.start', { agent_id: 'ag1', agent_type: 'Explore' }),
    ev(3, 'tool.start', { agent_id: 'ag1', agent_type: 'Explore', tool_name: 'Grep', tool_use_id: 'toolu_g' }),
    ev(4, 'tool.end', { agent_id: 'ag1', agent_type: 'Explore', tool_name: 'Grep', tool_use_id: 'toolu_g', payload: { status: 'ok' } }),
    ev(5, 'subagent.stop', { agent_id: 'ag1', agent_type: 'Explore' }),
    ev(6, 'tool.end', { tool_name: 'Agent', tool_use_id: 'toolu_a', payload: { status: 'ok', subagent_id: 'ag1', subagent_status: 'completed', description: 'Find auth code' } }),
    // A background launch: its tool.end (async) arrives before the subagent starts.
    ev(7, 'tool.start', { tool_name: 'Agent', tool_use_id: 'toolu_b', payload: { description: 'Run tests', subagent_type: 'general-purpose', run_in_background: true } }),
    ev(8, 'tool.end', { tool_name: 'Agent', tool_use_id: 'toolu_b', payload: { status: 'ok', subagent_id: 'ag2', subagent_status: 'async_launched' } }),
    ev(9, 'subagent.start', { agent_id: 'ag2', agent_type: 'general-purpose' }),
  ]);
  const tl = buildActivityTimeline(events);
  assert.deepEqual(tl.subagents.map((g) => [g.agentId, g.description, g.launchToolUseId]), [
    ['ag1', 'Find auth code', 'toolu_a'],
    ['ag2', 'Run tests', 'toolu_b'],
  ]);
  // The launching Agent rows fold into their groups, which sit where they were launched.
  assert.deepEqual(tl.entries.map((e) => e.id), ['subagent:ag1', 'subagent:ag2']);
  assert.equal(tl.subagents[0].seq, 1);
  assert.equal(tl.subagents[0].toolCalls[0].status, 'done');
  assert.equal(tl.subagents[1].status, 'running');
});

test('T4 shapes: a running foreground subagent borrows the pending launch of its type', () => {
  const events = normalizeExtensionEvents([
    ev(1, 'tool.start', { tool_name: 'Agent', tool_use_id: 'toolu_p', payload: { description: 'Plan the change', subagent_type: 'Plan' } }),
    ev(2, 'tool.start', { tool_name: 'Agent', tool_use_id: 'toolu_e', payload: { description: 'Look around', subagent_type: 'Explore' } }),
    ev(3, 'subagent.start', { agent_id: 'ag_e', agent_type: 'Explore' }),
    ev(4, 'subagent.start', { agent_id: 'ag_p', agent_type: 'Plan' }),
    // A failed earlier launch of the same type must not be claimed.
    ev(5, 'tool.start', { tool_name: 'Agent', tool_use_id: 'toolu_x', payload: { description: 'Broken', subagent_type: 'Explore' } }),
    ev(6, 'tool.end', { tool_name: 'Agent', tool_use_id: 'toolu_x', payload: { status: 'error' } }),
    ev(7, 'subagent.start', { agent_id: 'ag_late', agent_type: 'Explore' }),
  ]);
  const tl = buildActivityTimeline(events);
  const byId = Object.fromEntries(tl.subagents.map((g) => [g.agentId, g]));
  assert.equal(byId.ag_e.description, 'Look around');
  assert.equal(byId.ag_p.description, 'Plan the change');
  assert.equal(byId.ag_late.description, '', 'no running launch left for it');
  const parentTools = tl.entries.filter((e): e is TimelineToolCall => e.kind === 'tool');
  assert.deepEqual(parentTools.map((c) => [c.id, c.status]), [['toolu_x', 'failed']]);
});

test('T4 shapes: PostToolUseFailure without error text still reads as failed', () => {
  const events = normalizeExtensionEvents([
    ev(1, 'tool.start', { tool_name: 'Bash', tool_use_id: 'b1' }),
    ev(2, 'tool.end', { tool_name: 'Bash', tool_use_id: 'b1', payload: { status: 'error' } }),
    ev(3, 'tool.start', { tool_name: 'Bash', tool_use_id: 'b2' }),
    ev(4, 'tool.end', { tool_name: 'Bash', tool_use_id: 'b2', payload: { status: 'error', is_interrupt: true } }),
    ev(5, 'tool.start', { tool_name: 'Read', tool_use_id: 'r1' }),
    ev(6, 'tool.end', { tool_name: 'Read', tool_use_id: 'r1', payload: { status: 'ok', duration_ms: 3 } }),
  ]);
  const calls = buildActivityTimeline(events).entries as TimelineToolCall[];
  assert.deepEqual(calls.map((c) => c.status), ['failed', 'failed', 'done']);
});

test('a call with no tool.end (denied permission) is interrupted when its agent stops, not left running', () => {
  const evs = normalizeExtensionEvents({ events: [
    ev(1, 'tool.start', { tool_name: 'Bash', tool_use_id: 'd1', payload: { input: { command: 'rm -rf build' } } }),
    ev(2, 'permission.request', { tool_name: 'Bash' }),
    ev(3, 'subagent.start', { agent_id: 'sa1', agent_type: 'Explore' }),
    ev(4, 'tool.start', { agent_id: 'sa1', tool_name: 'Bash', tool_use_id: 'd2', payload: { input: { command: 'curl x' } } }),
    ev(5, 'subagent.stop', { agent_id: 'sa1', agent_type: 'Explore' }),
  ] });
  // Before the main agent's Stop: the subagent's call is closed, the main one still runs.
  let tl = buildActivityTimeline(evs);
  const mainCall = () => tl.entries.find((x: any) => x.kind === 'tool' && x.id === 'd1') as TimelineToolCall;
  assert.equal(mainCall().status, 'running');
  const sub = tl.entries.find((x: any) => x.kind === 'subagent') as TimelineSubagentGroup;
  assert.equal(sub.toolCalls[0].status, 'failed');
  assert.equal(sub.toolCalls[0].interrupted, true);
  // The main agent's Stop (activity idle) closes it too.
  tl = buildActivityTimeline([...evs, ...normalizeExtensionEvents({ events: [ev(6, 'activity', { payload: { state: 'idle', reason: 'stop' } })] })]);
  assert.equal(mainCall().status, 'failed');
  assert.equal(mainCall().interrupted, true);
  assert.equal(mainCall().endedAt, t(6));
});
