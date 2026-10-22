// Activity timeline for one agent conversation (REQ-EXT-SUB-2, REQ-EXT-FILE-1 UI).
// Pure logic, no React and no fetch (tests/ui_extension_timeline_test.ts).
//
// Input is the hub's stored ham.ext.v1 events for an instance
//   GET /api/v1/agent-instances/{id}/extension/events?after_seq=&limit=
//   → {events:[{seq, event, ts, session_id, agent:{id,type}, tool_name,
//               tool_use_id, file_path, created_at, payload}], next_after_seq}
// optionally merged with the hub's rollups
//   GET .../extension/subagents → {subagents:[{agent_id, agent_type, description,
//                                              status, started_at, stopped_at, event_count}]}
//   GET .../extension/files     → {files:[{file_path, edit_count, last_seq, last_at, agent_ids}]}
//
// Events with an empty agent.id belong to the parent conversation; a non-empty
// agent.id is a subagent the parent spawned. The timeline is the parent's flow
// in seq order, with each subagent as one collapsible group placed where it
// started and holding its own tool calls and file edits.

export interface ExtensionEvent {
  seq: number;
  event: string;
  ts: string;
  session_id: string;
  agent_id: string;
  agent_type: string;
  tool_name: string;
  tool_use_id: string;
  file_path: string;
  created_at: string;
  payload: Record<string, any>;
}

export interface SubagentSummary {
  agent_id: string;
  agent_type: string;
  description: string;
  status: string;
  started_at: string;
  stopped_at: string;
  event_count: number;
}

export interface FileSummary {
  file_path: string;
  edit_count: number;
  last_seq: number;
  last_at: string;
  agent_ids: string[];
}

function str(value: unknown): string {
  return typeof value === 'string' ? value : value == null ? '' : String(value);
}

function num(value: unknown): number {
  const n = Number(value);
  return Number.isFinite(n) ? n : 0;
}

function obj(value: unknown): Record<string, any> {
  return value && typeof value === 'object' && !Array.isArray(value) ? (value as Record<string, any>) : {};
}

export function normalizeExtensionEvent(raw: any): ExtensionEvent | null {
  if (!raw || typeof raw !== 'object') return null;
  const seq = num(raw.seq);
  const event = str(raw.event);
  if (!seq || !event) return null;
  const agent = obj(raw.agent);
  return {
    seq,
    event,
    ts: str(raw.ts),
    session_id: str(raw.session_id),
    agent_id: str(agent.id ?? raw.agent_id),
    agent_type: str(agent.type ?? raw.agent_type),
    tool_name: str(raw.tool_name),
    tool_use_id: str(raw.tool_use_id),
    file_path: str(raw.file_path),
    created_at: str(raw.created_at),
    payload: obj(raw.payload),
  };
}

export function normalizeExtensionEvents(raw: any): ExtensionEvent[] {
  const rows = Array.isArray(raw) ? raw : Array.isArray(raw?.events) ? raw.events : [];
  return rows.map(normalizeExtensionEvent).filter(Boolean) as ExtensionEvent[];
}

export function normalizeSubagentSummaries(raw: any): SubagentSummary[] {
  const rows = Array.isArray(raw) ? raw : Array.isArray(raw?.subagents) ? raw.subagents : [];
  return rows
    .filter((r: any) => r && str(r.agent_id))
    .map((r: any) => ({
      agent_id: str(r.agent_id),
      agent_type: str(r.agent_type),
      description: str(r.description),
      status: str(r.status),
      started_at: str(r.started_at),
      stopped_at: str(r.stopped_at),
      event_count: num(r.event_count),
    }));
}

export function normalizeFileSummaries(raw: any): FileSummary[] {
  const rows = Array.isArray(raw) ? raw : Array.isArray(raw?.files) ? raw.files : [];
  return rows
    .filter((r: any) => r && str(r.file_path))
    .map((r: any) => ({
      file_path: str(r.file_path),
      edit_count: num(r.edit_count),
      last_seq: num(r.last_seq),
      last_at: str(r.last_at),
      agent_ids: Array.isArray(r.agent_ids) ? r.agent_ids.map(str).filter(Boolean) : [],
    }));
}

/**
 * Merges a fetched page into what we already hold: dedupes by seq and keeps
 * ascending order, so realtime refetches with after_seq simply append.
 */
export function mergeExtensionEvents(current: ExtensionEvent[], incoming: ExtensionEvent[]): ExtensionEvent[] {
  if (incoming.length === 0) return current;
  const bySeq = new Map<number, ExtensionEvent>();
  for (const e of current) bySeq.set(e.seq, e);
  for (const e of incoming) bySeq.set(e.seq, e);
  return [...bySeq.values()].sort((a, b) => a.seq - b.seq);
}

// ---------------------------------------------------------------------------
// Timeline model

export type ToolCallStatus = 'running' | 'done' | 'failed' | 'completed';

export interface TimelineToolCall {
  kind: 'tool';
  /** tool_use_id, or `seq:<n>` for an unpaired event. */
  id: string;
  seq: number;
  agentId: string;
  toolName: string;
  status: ToolCallStatus;
  summary: string;
  startedAt: string;
  endedAt: string;
  durationMs: number | null;
  /** Never ended before its agent stopped (e.g. a denied permission emits no tool.end). */
  interrupted?: boolean;
}

export interface TimelineFileEdit {
  seq: number;
  agentId: string;
  filePath: string;
  toolName: string;
  diff: string;
  diffTruncated: boolean;
  partial?: boolean;
  diffUnavailableReason?: string;
  oldPath?: string;
  at: string;
}

export type SubagentStatus = 'running' | 'done';

export interface TimelineSubagentGroup {
  kind: 'subagent';
  id: string;
  seq: number;
  agentId: string;
  agentType: string;
  description: string;
  status: SubagentStatus;
  startedAt: string;
  stoppedAt: string;
  durationMs: number | null;
  /** tool_use_id of the parent's Agent/Task call that launched it, if known. */
  launchToolUseId: string;
  toolCalls: TimelineToolCall[];
  files: TimelineFileEntry[];
}

export interface TimelineNotice {
  kind: 'notice';
  id: string;
  seq: number;
  event: string;
  text: string;
  at: string;
}

export type TimelineEntry = TimelineToolCall | TimelineSubagentGroup | TimelineNotice;

export interface TimelineFileEntry {
  filePath: string;
  editCount: number;
  lastSeq: number;
  lastAt: string;
  agentIds: string[];
  /** Edits in seq order (only those whose events we hold). */
  edits: TimelineFileEdit[];
}

export interface ActivityTimeline {
  entries: TimelineEntry[];
  subagents: TimelineSubagentGroup[];
  /** Every file edited in the conversation, newest edit first. */
  files: TimelineFileEntry[];
  toolCallCount: number;
  runningSubagents: number;
}

function eventTime(e: ExtensionEvent): string {
  return e.ts || e.created_at;
}

export function durationMs(start: string, end: string): number | null {
  const a = Date.parse(start);
  const b = Date.parse(end);
  if (!Number.isFinite(a) || !Number.isFinite(b) || b < a) return null;
  return b - a;
}

export function formatDuration(ms: number | null): string {
  if (ms == null) return '';
  if (ms < 1000) return `${ms}ms`;
  const s = Math.round(ms / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ${s % 60}s`;
  return `${Math.floor(m / 60)}h ${m % 60}m`;
}

/** One-line description of a tool call from what the extension put in payload. */
export function toolCallSummary(payload: Record<string, any>): string {
  const input = obj(payload.input);
  const src = Object.keys(input).length ? input : payload;
  const pick = (k: string) => (typeof src[k] === 'string' ? src[k] : '');
  const text = str(payload.summary) || pick('command') || pick('file_path') || pick('notebook_path')
    || pick('pattern') || pick('url') || pick('query') || pick('description') || pick('prompt');
  const line = text.split('\n')[0];
  return line.length > 160 ? `${line.slice(0, 159)}…` : line;
}

function toolFailed(payload: Record<string, any>): boolean {
  // PostToolUseFailure arrives as {status:'error', error?, is_interrupt?}; the
  // error text is omitted when empty, so status alone must mark the failure.
  if (payload.status === 'error' || payload.is_interrupt === true) return true;
  if (payload.error || payload.is_error === true || payload.success === false) return true;
  const response = obj(payload.response);
  return response.is_error === true || response.success === false;
}

function subagentDescription(payload: Record<string, any>): string {
  const input = obj(payload.input);
  return str(payload.description) || str(input.description) || str(payload.prompt).split('\n')[0];
}

/**
 * The parent's tool calls that launch a subagent. Subagent hooks carry no
 * description and no tool_use_id; the description and subagent_type live on
 * this call's tool.start, and its tool.end names the subagent (subagent_id).
 */
function isSubagentLaunch(e: ExtensionEvent): boolean {
  if (e.agent_id) return false;
  if (e.tool_name === 'Agent' || e.tool_name === 'Task') return true;
  return Boolean(str(e.payload.subagent_type) || str(e.payload.subagent_id));
}

interface SubagentLaunch {
  call: TimelineToolCall;
  subagentType: string;
  description: string;
  /** Set once a tool.end names the subagent, or a fallback claims it. */
  agentId: string;
}

const NOTICE_TEXT: Record<string, (e: ExtensionEvent) => string> = {
  'permission.request': (e) => `Asked permission for ${e.tool_name || 'a tool'}`,
  notification: (e) => str(e.payload.message) || str(e.payload.type) || 'Notification',
  session: (e) => (e.session_id ? `Session ${e.session_id.slice(0, 8)}` : 'Session started'),
};

/**
 * Builds the timeline from stored events plus the optional hub rollups (which
 * cover subagents and files whose events were trimmed by retention).
 */
export function buildActivityTimeline(
  events: ExtensionEvent[],
  subagentSummaries: SubagentSummary[] = [],
  fileSummaries: FileSummary[] = [],
): ActivityTimeline {
  const sorted = [...events].sort((a, b) => a.seq - b.seq);
  const parentEntries: TimelineEntry[] = [];
  const groups = new Map<string, TimelineSubagentGroup>();
  const toolsByUseId = new Map<string, TimelineToolCall>();
  const launches: SubagentLaunch[] = [];
  const launchByUseId = new Map<string, SubagentLaunch>();
  const filesByAgent = new Map<string, Map<string, TimelineFileEntry>>();
  const allFiles = new Map<string, TimelineFileEntry>();
  let toolCallCount = 0;

  const groupFor = (e: ExtensionEvent): TimelineSubagentGroup => {
    let g = groups.get(e.agent_id);
    if (!g) {
      g = {
        kind: 'subagent',
        id: `subagent:${e.agent_id}`,
        seq: e.seq,
        agentId: e.agent_id,
        agentType: e.agent_type,
        description: '',
        status: 'running',
        startedAt: eventTime(e),
        stoppedAt: '',
        durationMs: null,
        launchToolUseId: '',
        toolCalls: [],
        files: [],
      };
      groups.set(e.agent_id, g);
      parentEntries.push(g);
    }
    if (!g.agentType && e.agent_type) g.agentType = e.agent_type;
    return g;
  };

  const toolsInOrder: TimelineToolCall[] = [];
  const pushTool = (call: TimelineToolCall) => {
    toolsInOrder.push(call);
    toolCallCount += 1;
    if (call.agentId) groupFor({ agent_id: call.agentId, seq: call.seq, agent_type: '', ts: call.startedAt } as ExtensionEvent).toolCalls.push(call);
    else parentEntries.push(call);
  };

  const fileEntry = (map: Map<string, TimelineFileEntry>, path: string): TimelineFileEntry => {
    let f = map.get(path);
    if (!f) {
      f = { filePath: path, editCount: 0, lastSeq: 0, lastAt: '', agentIds: [], edits: [] };
      map.set(path, f);
    }
    return f;
  };

  const addEdit = (entry: TimelineFileEntry, edit: TimelineFileEdit) => {
    entry.edits.push(edit);
    entry.editCount += 1;
    if (edit.seq >= entry.lastSeq) {
      entry.lastSeq = edit.seq;
      entry.lastAt = edit.at;
    }
    const aid = edit.agentId || '';
    if (!entry.agentIds.includes(aid)) entry.agentIds.push(aid);
  };

  // A call that never got tool.end cannot still be running once its agent
  // stopped (main agent: activity idle = the provider's Stop; a subagent: its
  // subagent.stop). A denied permission is the common case: no PostToolUse.
  const interruptOpenCalls = (agentId: string, at: string) => {
    for (const call of toolsInOrder) {
      if (call.status !== 'running' || (call.agentId || '') !== agentId) continue;
      call.status = 'failed';
      call.interrupted = true;
      call.endedAt = at;
      call.durationMs = durationMs(call.startedAt, at);
    }
  };

  for (const e of sorted) {
    switch (e.event) {
      case 'activity': {
        if (!e.agent_id && str(e.payload.state) === 'idle') interruptOpenCalls('', eventTime(e));
        break;
      }
      case 'subagent.start': {
        if (!e.agent_id) break;
        const g = groupFor(e);
        g.seq = Math.min(g.seq, e.seq);
        g.startedAt = eventTime(e) || g.startedAt;
        g.description = g.description || subagentDescription(e.payload);
        break;
      }
      case 'subagent.stop': {
        if (!e.agent_id) break;
        interruptOpenCalls(e.agent_id, eventTime(e));
        const g = groupFor(e);
        g.status = 'done';
        g.stoppedAt = eventTime(e);
        g.description = g.description || subagentDescription(e.payload);
        break;
      }
      case 'tool.start': {
        const call: TimelineToolCall = {
          kind: 'tool',
          id: e.tool_use_id || `seq:${e.seq}`,
          seq: e.seq,
          agentId: e.agent_id,
          toolName: e.tool_name || 'tool',
          status: 'running',
          summary: toolCallSummary(e.payload),
          startedAt: eventTime(e),
          endedAt: '',
          durationMs: null,
        };
        if (e.tool_use_id) toolsByUseId.set(e.tool_use_id, call);
        if (isSubagentLaunch(e)) {
          const launch = { call, subagentType: str(e.payload.subagent_type), description: subagentDescription(e.payload), agentId: '' };
          launches.push(launch);
          if (e.tool_use_id) launchByUseId.set(e.tool_use_id, launch);
        }
        pushTool(call);
        break;
      }
      case 'tool.end': {
        const existing = e.tool_use_id ? toolsByUseId.get(e.tool_use_id) : undefined;
        const subagentId = e.agent_id ? '' : str(e.payload.subagent_id);
        const launch = e.tool_use_id ? launchByUseId.get(e.tool_use_id) : undefined;
        if (launch && subagentId) {
          launch.agentId = subagentId;
          launch.description = launch.description || subagentDescription(e.payload);
        }
        if (existing) {
          existing.status = toolFailed(e.payload) ? 'failed' : e.payload.status === 'completed' || e.payload.outcome === 'unknown' ? 'completed' : 'done';
          existing.endedAt = eventTime(e);
          existing.durationMs = durationMs(existing.startedAt, existing.endedAt);
          if (!existing.summary) existing.summary = toolCallSummary(e.payload);
        } else {
          // Its start was trimmed (or never sent): show the call as finished.
          const call: TimelineToolCall = {
            kind: 'tool',
            id: e.tool_use_id || `seq:${e.seq}`,
            seq: e.seq,
            agentId: e.agent_id,
            toolName: e.tool_name || 'tool',
            status: toolFailed(e.payload) ? 'failed' : e.payload.status === 'completed' || e.payload.outcome === 'unknown' ? 'completed' : 'done',
            summary: toolCallSummary(e.payload),
            startedAt: '',
            endedAt: eventTime(e),
            durationMs: null,
          };
          // The end alone still names the subagent it launched.
          if (subagentId) launches.push({ call, subagentType: '', description: subagentDescription(e.payload), agentId: subagentId });
          pushTool(call);
        }
        break;
      }
      case 'file.edit': {
        const path = e.file_path || str(e.payload.file_path);
        if (!path) break;
        const edit: TimelineFileEdit = {
          seq: e.seq,
          agentId: e.agent_id,
          filePath: path,
          toolName: e.tool_name,
          diff: str(e.payload.diff),
          diffTruncated: e.payload.diff_truncated === true,
          partial: e.payload.partial === true,
          diffUnavailableReason: str(e.payload.diff_unavailable_reason),
          oldPath: str(e.payload.old_path),
          at: eventTime(e),
        };
        addEdit(fileEntry(allFiles, path), edit);
        if (e.agent_id) {
          groupFor(e);
          let m = filesByAgent.get(e.agent_id);
          if (!m) {
            m = new Map();
            filesByAgent.set(e.agent_id, m);
          }
          addEdit(fileEntry(m, path), edit);
        }
        break;
      }
      case 'permission.request':
      case 'notification':
      case 'session': {
        if (e.agent_id) break;
        parentEntries.push({ kind: 'notice', id: `notice:${e.seq}`, seq: e.seq, event: e.event, text: NOTICE_TEXT[e.event](e), at: eventTime(e) });
        break;
      }
      default:
        break;
    }
  }

  // Rollups: fill in what retention trimmed and the hub's authoritative status.
  for (const s of subagentSummaries) {
    let g = groups.get(s.agent_id);
    if (!g) {
      g = {
        kind: 'subagent',
        id: `subagent:${s.agent_id}`,
        seq: 0,
        agentId: s.agent_id,
        agentType: s.agent_type,
        description: s.description,
        status: 'running',
        startedAt: s.started_at,
        stoppedAt: '',
        durationMs: null,
        launchToolUseId: '',
        toolCalls: [],
        files: [],
      };
      groups.set(s.agent_id, g);
      parentEntries.push(g);
    }
    g.agentType = g.agentType || s.agent_type;
    g.description = g.description || s.description;
    g.startedAt = g.startedAt || s.started_at;
    if (s.stopped_at || s.status === 'done' || s.status === 'stopped') {
      g.status = 'done';
      g.stoppedAt = g.stoppedAt || s.stopped_at;
    }
  }
  for (const f of fileSummaries) {
    const entry = fileEntry(allFiles, f.file_path);
    entry.editCount = Math.max(entry.editCount, f.edit_count);
    if (f.last_seq > entry.lastSeq) {
      entry.lastSeq = f.last_seq;
      entry.lastAt = f.last_at;
    }
    for (const aid of f.agent_ids) if (!entry.agentIds.includes(aid)) entry.agentIds.push(aid);
  }

  // Link each subagent to the parent call that launched it: first by the
  // subagent_id its tool.end reported, then (a foreground subagent's launch
  // only ends when the subagent does) by the oldest still-running unclaimed
  // launch of the same subagent_type that precedes it. The linked call folds
  // into the group instead of showing as a separate parent row.
  const linked = new Map<string, SubagentLaunch>();
  for (const l of launches) if (l.agentId && groups.has(l.agentId) && !linked.has(l.agentId)) linked.set(l.agentId, l);
  const ordered = [...groups.values()].sort((a, b) => a.seq - b.seq);
  for (const g of ordered) {
    if (linked.has(g.agentId)) continue;
    for (const l of launches) {
      if (l.agentId || l.call.status !== 'running' || l.call.seq > g.seq) continue;
      if (l.subagentType !== g.agentType) continue;
      l.agentId = g.agentId;
      linked.set(g.agentId, l);
      break;
    }
  }
  const folded = new Set<TimelineToolCall>();
  for (const [agentId, l] of linked) {
    const g = groups.get(agentId) as TimelineSubagentGroup;
    g.description = g.description || l.description || l.call.summary;
    g.agentType = g.agentType || l.subagentType;
    g.launchToolUseId = l.call.id.startsWith('seq:') ? '' : l.call.id;
    if (l.call.seq > 0 && (g.seq === 0 || l.call.seq < g.seq)) g.seq = l.call.seq;
    folded.add(l.call);
  }

  for (const g of groups.values()) {
    g.durationMs = g.status === 'done' ? durationMs(g.startedAt, g.stoppedAt) : null;
    g.files = sortFiles([...(filesByAgent.get(g.agentId)?.values() || [])]);
  }

  const entries = parentEntries.filter((e) => !(e.kind === 'tool' && folded.has(e))).sort((a, b) => a.seq - b.seq);
  const subagents = entries.filter((e): e is TimelineSubagentGroup => e.kind === 'subagent');
  return {
    entries,
    subagents,
    files: sortFiles([...allFiles.values()]),
    toolCallCount,
    runningSubagents: subagents.filter((g) => g.status === 'running').length,
  };
}

function sortFiles(files: TimelineFileEntry[]): TimelineFileEntry[] {
  return files.sort((a, b) => b.lastSeq - a.lastSeq || a.filePath.localeCompare(b.filePath));
}

/** Newest edit of a file that carries a diff, or null. */
export function latestDiffEdit(file: TimelineFileEntry): TimelineFileEdit | null {
  for (let i = file.edits.length - 1; i >= 0; i -= 1) if (file.edits[i].diff) return file.edits[i];
  return null;
}

// ---------------------------------------------------------------------------
// Unified diff → hunks for the shared MonacoDiffViewer.

export interface DiffHunkLine { op: string; text: string }
export interface DiffHunk { old_start: number; old_len: number; new_start: number; new_len: number; lines: DiffHunkLine[] }

/**
 * Parses a unified diff (the bridge's per-edit diff) into hunks. Text without
 * any @@ header is treated as one hunk of +/-/space prefixed lines.
 */
export function parseUnifiedDiff(diff: string): DiffHunk[] {
  const hunks: DiffHunk[] = [];
  let current: DiffHunk | null = null;
  for (const raw of String(diff || '').split('\n')) {
    const header = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/.exec(raw);
    if (header) {
      current = {
        old_start: Number(header[1]),
        old_len: header[2] === undefined ? 1 : Number(header[2]),
        new_start: Number(header[3]),
        new_len: header[4] === undefined ? 1 : Number(header[4]),
        lines: [],
      };
      hunks.push(current);
      continue;
    }
    if (raw.startsWith('--- ') || raw.startsWith('+++ ') || raw.startsWith('diff ') || raw.startsWith('index ') || raw.startsWith('\\')) continue;
    const op = raw[0];
    if (op !== '+' && op !== '-' && op !== ' ') continue;
    if (!current) {
      current = { old_start: 1, old_len: 0, new_start: 1, new_len: 0, lines: [] };
      hunks.push(current);
    }
    current.lines.push({ op, text: raw.slice(1) });
  }
  return hunks;
}

export function diffLineStats(diff: string): { added: number; removed: number } {
  let added = 0;
  let removed = 0;
  for (const h of parseUnifiedDiff(diff)) {
    for (const l of h.lines) {
      if (l.op === '+') added += 1;
      else if (l.op === '-') removed += 1;
    }
  }
  return { added, removed };
}

/** File name for compact rows (full path stays in the title attribute). */
export function fileBaseName(path: string): string {
  const parts = String(path || '').split(/[\\/]/);
  return parts[parts.length - 1] || path;
}
