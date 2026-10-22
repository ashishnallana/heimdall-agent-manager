// Tool activity messages (REQ-EXT-CONV-1/2 UI).
//
// The bridge aggregates an agent's tool calls per turn into compact
// conversation messages with message_type "tool_activity" (see
// src/bridge/extension_tool_aggregator.odin). Their metadata is:
//
//   { v, reason, final, turn_started_at, turn_ended_at,
//     counts: {total, ok, error, running, edits, files_edited, commands, reads,
//              searches, other, subagents, omitted, by_tool?},
//     omitted_subagents?,
//     calls: [{tool, summary, status, duration_ms, use_id?, file_path?, subagent_id?}],
//     subagents: [{agent_id, agent_type, description, status, counts, calls: [...]}] }
//
// The metadata is capped at ~4KB, so `calls` may be a prefix of what ran —
// counts.omitted says how many records were dropped; the full detail lives in
// the Activity timeline. This module is pure: it normalises defensively so an
// older or partial payload still renders.

import { formatDuration } from './extensionTimelineModel.ts';

export const TOOL_ACTIVITY_MESSAGE_TYPE = 'tool_activity';

export type ToolActivityStatus = 'ok' | 'error' | 'running' | 'completed';

export interface ToolActivityCall {
  tool: string;
  summary: string;
  status: ToolActivityStatus;
  durationMs: number | null;
  useId: string;
  filePath: string;
  subagentId: string;
}

export interface ToolActivitySubagent {
  agentId: string;
  agentType: string;
  description: string;
  status: 'done' | 'running';
  total: number;
  errors: number;
  calls: ToolActivityCall[];
}

export interface ToolActivityCounts {
  total: number;
  ok: number;
  completed: number;
  error: number;
  running: number;
  edits: number;
  filesEdited: number;
  commands: number;
  reads: number;
  searches: number;
  other: number;
  subagents: number;
  omitted: number;
  byTool: Array<{ tool: string; count: number }>;
}

export interface ToolActivity {
  reason: string;
  final: boolean;
  turnStartedAt: string;
  turnEndedAt: string;
  counts: ToolActivityCounts;
  omittedSubagents: number;
  calls: ToolActivityCall[];
  subagents: ToolActivitySubagent[];
}

const obj = (v: unknown): Record<string, any> => (v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, any>) : {});
const str = (v: unknown): string => (typeof v === 'string' ? v : typeof v === 'number' ? String(v) : '');
const int = (v: unknown): number => {
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : 0;
};

export function isToolActivityMessage(message: { messageType?: string } | null | undefined): boolean {
  return message?.messageType === TOOL_ACTIVITY_MESSAGE_TYPE;
}

function normalizeStatus(v: unknown): ToolActivityStatus {
  const s = str(v);
  return s === 'error' || s === 'running' || s === 'completed' ? s : 'ok';
}

export function normalizeToolActivityCall(raw: unknown): ToolActivityCall | null {
  const r = obj(raw);
  const tool = str(r.tool).trim();
  if (!tool) return null;
  const duration = Number(r.duration_ms);
  return {
    tool,
    summary: str(r.summary).trim() || tool,
    status: normalizeStatus(r.status),
    durationMs: Number.isFinite(duration) && duration >= 0 && r.duration_ms !== undefined ? duration : null,
    useId: str(r.use_id),
    filePath: str(r.file_path),
    subagentId: str(r.subagent_id),
  };
}

function normalizeCalls(raw: unknown): ToolActivityCall[] {
  if (!Array.isArray(raw)) return [];
  return raw.map(normalizeToolActivityCall).filter((c): c is ToolActivityCall => c !== null);
}

/** Parses a tool_activity message's metadata (object or JSON string). */
export function parseToolActivity(metadata: unknown): ToolActivity {
  let m: Record<string, any> = {};
  if (typeof metadata === 'string') {
    try { m = obj(JSON.parse(metadata)); } catch { m = {}; }
  } else {
    m = obj(metadata);
  }
  const calls = normalizeCalls(m.calls);
  const subagents: ToolActivitySubagent[] = (Array.isArray(m.subagents) ? m.subagents : []).map((raw: unknown) => {
    const g = obj(raw);
    const groupCalls = normalizeCalls(g.calls);
    const c = obj(g.counts);
    return {
      agentId: str(g.agent_id),
      agentType: str(g.agent_type),
      description: str(g.description),
      status: str(g.status) === 'running' ? 'running' : 'done',
      total: int(c.total) || groupCalls.length,
      errors: int(c.error) || groupCalls.filter((x) => x.status === 'error').length,
      calls: groupCalls,
    } as ToolActivitySubagent;
  });
  const c = obj(m.counts);
  const listed = calls.length + subagents.reduce((n, g) => n + g.calls.length, 0);
  const byTool = Object.entries(obj(c.by_tool))
    .map(([tool, count]) => ({ tool, count: int(count) }))
    .filter((e) => e.count > 0)
    .sort((a, b) => b.count - a.count || a.tool.localeCompare(b.tool));
  const all = [...calls, ...subagents.flatMap((g) => g.calls)];
  return {
    reason: str(m.reason),
    final: m.final === true,
    turnStartedAt: str(m.turn_started_at),
    turnEndedAt: str(m.turn_ended_at),
    counts: {
      total: Math.max(int(c.total), listed),
      completed: int(c.completed) || all.filter((x) => x.status === 'completed').length,
      ok: int(c.ok) || all.filter((x) => x.status === 'ok').length,
      error: int(c.error) || all.filter((x) => x.status === 'error').length,
      running: int(c.running) || all.filter((x) => x.status === 'running').length,
      edits: int(c.edits),
      filesEdited: int(c.files_edited),
      commands: int(c.commands),
      reads: int(c.reads),
      searches: int(c.searches),
      other: int(c.other),
      subagents: Math.max(int(c.subagents), subagents.length),
      omitted: int(c.omitted),
      byTool,
    },
    omittedSubagents: int(m.omitted_subagents),
    calls,
    subagents,
  };
}

/** The collapsed one-liner: the hub body, else a count. */
export function toolActivityHeadline(body: string, activity: ToolActivity): string {
  const text = String(body || '').replace(/\s+/g, ' ').trim();
  if (text) return text;
  const n = activity.counts.total;
  return `${n} tool call${n === 1 ? '' : 's'}`;
}

/** Short trailing badge for the collapsed row, e.g. "12 calls · 1 failed". */
export function toolActivityBadge(activity: ToolActivity): string {
  const n = activity.counts.total;
  const parts = [`${n} call${n === 1 ? '' : 's'}`];
  if (activity.counts.error > 0) parts.push(`${activity.counts.error} failed`);
  return parts.join(' · ');
}

/** Line under the expanded list when the 4KB cap dropped records. */
export function toolActivityOmittedLabel(activity: ToolActivity): string {
  const n = activity.counts.omitted;
  const s = activity.omittedSubagents;
  if (n <= 0 && s <= 0) return '';
  const parts: string[] = [];
  if (n > 0) parts.push(`${n} more call${n === 1 ? '' : 's'}`);
  if (s > 0) parts.push(`${s} more subagent${s === 1 ? '' : 's'}`);
  return `+ ${parts.join(' and ')} — see the Activity timeline`;
}

export function toolActivityCallDuration(call: ToolActivityCall): string {
  if (call.status === 'running') return 'running';
  return formatDuration(call.durationMs);
}

/** Label for a nested subagent group header. */
export function toolActivitySubagentLabel(group: ToolActivitySubagent): string {
  const type = group.agentType || 'Subagent';
  return group.description ? `${type} · ${group.description}` : type;
}

// Tools whose file path has a recorded diff (mirrors the bridge's edit bucket in
// tool_agg_category). Reads also carry a path, but there is no diff to open.
const EDIT_TOOLS = new Set(['edit', 'multiedit', 'write', 'notebookedit', 'apply_patch', 'write_file', 'replace', 'str_replace_editor', 'create_file']);

/** The file whose diff a click opens, or '' when the call has none. */
export function toolActivityCallFile(call: ToolActivityCall): string {
  if (!EDIT_TOOLS.has(call.tool.toLowerCase())) return '';
  return call.filePath.trim();
}

/**
 * Headline and badge for a clubbed run of consecutive tool_activity messages:
 * "Ran 9 commands" (every tool call counts), badge "1 failed" only on failures.
 */
export function toolActivityGroupSummary(metadatas: unknown[]): { headline: string; badge: string } {
  let total = 0;
  let errors = 0;
  for (const metadata of metadatas) {
    const { counts } = parseToolActivity(metadata);
    total += counts.total;
    errors += counts.error;
  }
  return {
    headline: `Ran ${total} command${total === 1 ? '' : 's'}`,
    badge: errors > 0 ? `${errors} failed` : '',
  };
}
