// Permission approval card (REQ-EXT-PERM-1, UI). Pure logic, no React and no
// fetch (tests/ui_extension_permission_test.ts).
//
// The hub stores one row per provider permission prompt the extension relayed:
//   GET  /api/v1/agent-instances/{id}/permission-requests?status=pending
//   GET  /api/v1/permission-requests?status=pending
//   POST /api/v1/permission-requests/{id}/decision {decision: allow|deny}
// and announces every change as resource_changed(agent_instance, <id>,
// 'permission_requests', {action: created|decided|closed, permission_request}).
// The bridge waits up to expires_at; after that the provider shows its own TUI
// prompt, so an expired card can no longer be answered here.

export type PermissionStatus = 'pending' | 'allowed' | 'denied' | 'expired' | 'cancelled';
export type PermissionDecision = 'allow' | 'deny';

export interface PermissionRequest {
  id: string;
  instance_id: string;
  chain_id: string;
  agent_id: string;
  provider: string;
  tool_name: string;
  tool_use_id: string;
  status: PermissionStatus;
  decided_by: string;
  message: string;
  created_at: string;
  expires_at: string;
  decided_at: string;
  input: Record<string, any>;
  permission_suggestions: any[];
}

const STATUSES: readonly PermissionStatus[] = ['pending', 'allowed', 'denied', 'expired', 'cancelled'];

function str(value: unknown): string {
  return typeof value === 'string' ? value : value == null ? '' : String(value);
}

export function normalizePermissionRequest(raw: any): PermissionRequest | null {
  if (!raw || typeof raw !== 'object') return null;
  const id = str(raw.id);
  if (!id) return null;
  return {
    id,
    instance_id: str(raw.instance_id),
    chain_id: str(raw.chain_id),
    agent_id: str(raw.agent_id),
    provider: str(raw.provider),
    tool_name: str(raw.tool_name),
    tool_use_id: str(raw.tool_use_id),
    status: STATUSES.includes(raw.status) ? raw.status : 'pending',
    decided_by: str(raw.decided_by),
    message: str(raw.message),
    created_at: str(raw.created_at),
    expires_at: str(raw.expires_at),
    decided_at: str(raw.decided_at),
    input: raw.input && typeof raw.input === 'object' && !Array.isArray(raw.input) ? raw.input : {},
    permission_suggestions: Array.isArray(raw.permission_suggestions) ? raw.permission_suggestions : [],
  };
}

export function normalizePermissionRequests(raw: any): PermissionRequest[] {
  const rows = Array.isArray(raw) ? raw : Array.isArray(raw?.permission_requests) ? raw.permission_requests : [];
  return sortRequests(rows.map(normalizePermissionRequest).filter(Boolean) as PermissionRequest[]);
}

function sortRequests(rows: PermissionRequest[]): PermissionRequest[] {
  return [...rows].sort((a, b) => (a.created_at < b.created_at ? -1 : a.created_at > b.created_at ? 1 : a.id.localeCompare(b.id)));
}

// ---------------------------------------------------------------------------
// Input summary: what the agent wants to do, in one line plus an optional diff.

export interface PermissionDiff {
  filePath: string;
  original: string;
  modified: string;
  /** True for Write (whole-file content, original unknown). */
  wholeFile: boolean;
}

export interface PermissionInputSummary {
  /** 'command' | 'file' | 'url' | 'pattern' | 'other' — decides the icon/mono styling. */
  kind: 'command' | 'file' | 'url' | 'pattern' | 'other';
  text: string;
  /** Extra one-liner (e.g. the Bash description), '' when none. */
  detail: string;
  diff: PermissionDiff | null;
}

const MAX_SUMMARY = 400;

function clip(text: string, max = MAX_SUMMARY): string {
  return text.length > max ? `${text.slice(0, max - 1)}…` : text;
}

export function summarizePermissionInput(toolName: string, input: Record<string, any>): PermissionInputSummary {
  const tool = String(toolName || '');
  const inp = input || {};
  const filePath = str(inp.file_path || inp.notebook_path);
  if (typeof inp.command === 'string' && inp.command) {
    return { kind: 'command', text: clip(inp.command), detail: str(inp.description), diff: null };
  }
  if (filePath) {
    let diff: PermissionDiff | null = null;
    if (typeof inp.old_string === 'string' || typeof inp.new_string === 'string') {
      diff = { filePath, original: str(inp.old_string), modified: str(inp.new_string), wholeFile: false };
    } else if (Array.isArray(inp.edits) && inp.edits.length) {
      diff = {
        filePath,
        original: inp.edits.map((e: any) => str(e?.old_string)).join('\n…\n'),
        modified: inp.edits.map((e: any) => str(e?.new_string)).join('\n…\n'),
        wholeFile: false,
      };
    } else if (typeof inp.content === 'string') {
      diff = { filePath, original: '', modified: inp.content, wholeFile: true };
    } else if (typeof inp.new_source === 'string') {
      diff = { filePath, original: '', modified: inp.new_source, wholeFile: true };
    }
    return { kind: 'file', text: filePath, detail: '', diff };
  }
  if (typeof inp.url === 'string' && inp.url) {
    return { kind: 'url', text: clip(inp.url), detail: str(inp.prompt) ? clip(str(inp.prompt), 160) : '', diff: null };
  }
  if (typeof inp.pattern === 'string' && inp.pattern) {
    return { kind: 'pattern', text: clip(inp.pattern), detail: str(inp.path), diff: null };
  }
  const keys = Object.keys(inp);
  if (keys.length === 0) return { kind: 'other', text: tool ? `${tool} (no input)` : 'No input', detail: '', diff: null };
  let text = '';
  try {
    text = JSON.stringify(inp);
  } catch {
    text = keys.join(', ');
  }
  return { kind: 'other', text: clip(text), detail: '', diff: null };
}

// ---------------------------------------------------------------------------
// Card view: phase, countdown and whether Allow / Deny are live.

export interface PermissionCardView {
  phase: PermissionStatus;
  /** Whole seconds left before the bridge stops waiting (0 once expired / closed). */
  secondsLeft: number;
  /** "4:59", '' when not pending. */
  countdown: string;
  canDecide: boolean;
  statusLabel: string;
}

export function parseTimeMs(value: string): number {
  if (!value) return NaN;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? ms : NaN;
}

export function formatCountdown(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  const m = Math.floor(s / 60);
  return `${m}:${String(s % 60).padStart(2, '0')}`;
}

export function permissionCardView(req: PermissionRequest, nowMs: number): PermissionCardView {
  if (req.status !== 'pending') {
    const labels: Record<PermissionStatus, string> = {
      pending: 'Waiting for approval',
      allowed: req.decided_by ? `Allowed by ${req.decided_by}` : 'Allowed',
      denied: req.decided_by ? `Denied by ${req.decided_by}` : 'Denied',
      expired: 'Expired — answer in the agent terminal',
      cancelled: 'Cancelled',
    };
    return { phase: req.status, secondsLeft: 0, countdown: '', canDecide: false, statusLabel: labels[req.status] };
  }
  const expiresMs = parseTimeMs(req.expires_at);
  if (!Number.isFinite(expiresMs)) {
    return { phase: 'pending', secondsLeft: 0, countdown: '', canDecide: true, statusLabel: 'Waiting for approval' };
  }
  const secondsLeft = Math.max(0, Math.ceil((expiresMs - nowMs) / 1000));
  if (secondsLeft <= 0) {
    return { phase: 'expired', secondsLeft: 0, countdown: '', canDecide: false, statusLabel: 'Expired — answer in the agent terminal' };
  }
  return {
    phase: 'pending',
    secondsLeft,
    countdown: formatCountdown(secondsLeft),
    canDecide: true,
    statusLabel: 'Waiting for approval',
  };
}

// ---------------------------------------------------------------------------
// Reducer: one list of requests kept live from fetches, realtime frames and the
// card's own Allow / Deny round trip.

export interface PermissionCardsState {
  requests: PermissionRequest[];
  /** request id → decision being submitted. */
  submitting: Record<string, PermissionDecision>;
  /** request id → last submit error. */
  errors: Record<string, string>;
}

export type PermissionCardsAction =
  | { type: 'loaded'; requests: PermissionRequest[]; nowMs?: number }
  | { type: 'realtime'; action: string; request: PermissionRequest }
  | { type: 'decision_started'; id: string; decision: PermissionDecision }
  | { type: 'decision_succeeded'; id: string; request: PermissionRequest | null; decision: PermissionDecision; nowMs?: number }
  | { type: 'decision_failed'; id: string; error: string; request?: PermissionRequest | null }
  | { type: 'dismissed'; id: string }
  | { type: 'pruned'; nowMs: number; keepClosedMs?: number };

/** How long a closed (or timed-out) card stays up so its outcome is visible. */
export const PERMISSION_KEEP_CLOSED_MS = 8000;

export const initialPermissionCardsState: PermissionCardsState = { requests: [], submitting: {}, errors: {} };

function omit<T>(record: Record<string, T>, key: string): Record<string, T> {
  if (!(key in record)) return record;
  const next = { ...record };
  delete next[key];
  return next;
}

/**
 * Merges one request into a list. A closed request never reopens: a stale
 * 'created' frame or a refetch that raced a decision cannot flip it back to
 * pending.
 */
export function upsertPermissionRequest(list: PermissionRequest[], incoming: PermissionRequest): PermissionRequest[] {
  const idx = list.findIndex((r) => r.id === incoming.id);
  if (idx < 0) return sortRequests([...list, incoming]);
  const current = list[idx];
  if (current.status !== 'pending' && incoming.status === 'pending') return list;
  const next = [...list];
  next[idx] = { ...current, ...incoming };
  return next;
}

export function permissionCardsReducer(state: PermissionCardsState, action: PermissionCardsAction): PermissionCardsState {
  switch (action.type) {
    case 'loaded': {
      let requests: PermissionRequest[] = [];
      for (const r of action.requests) {
        // The RTK caches keep closed requests the realtime patch upserted;
        // ones whose outcome has already been shown are not brought back.
        if (r.status !== 'pending' && action.nowMs != null && !permissionCardLive(r, action.nowMs)) continue;
        requests = upsertPermissionRequest(requests, r);
      }
      // Keep closed cards we already show (so the outcome stays visible), and
      // never let a fetch that raced a decision reopen one.
      for (const r of state.requests) {
        if (r.status !== 'pending') requests = upsertPermissionRequest(requests, r);
      }
      // A pending request we had that the server no longer lists as pending has
      // been closed elsewhere; the realtime frame will carry its outcome.
      return { ...state, requests };
    }
    case 'realtime': {
      const requests = upsertPermissionRequest(state.requests, action.request);
      const closed = action.request.status !== 'pending';
      return {
        requests,
        submitting: closed ? omit(state.submitting, action.request.id) : state.submitting,
        errors: closed ? omit(state.errors, action.request.id) : state.errors,
      };
    }
    case 'decision_started':
      return {
        ...state,
        submitting: { ...state.submitting, [action.id]: action.decision },
        errors: omit(state.errors, action.id),
      };
    case 'decision_succeeded': {
      const fallback = state.requests.find((r) => r.id === action.id);
      // Without the server's copy, stamp the close time locally so the card
      // still leaves after the keep window.
      const decidedAt = fallback?.decided_at || (action.nowMs != null ? new Date(action.nowMs).toISOString() : '');
      const resolved = action.request
        ?? (fallback ? { ...fallback, status: (action.decision === 'allow' ? 'allowed' : 'denied') as PermissionStatus, decided_at: decidedAt } : null);
      return {
        requests: resolved ? upsertPermissionRequest(state.requests, resolved) : state.requests,
        submitting: omit(state.submitting, action.id),
        errors: omit(state.errors, action.id),
      };
    }
    case 'decision_failed':
      return {
        requests: action.request ? upsertPermissionRequest(state.requests, action.request) : state.requests,
        submitting: omit(state.submitting, action.id),
        errors: { ...state.errors, [action.id]: action.error || 'Could not send the decision.' },
      };
    case 'dismissed':
      return {
        requests: state.requests.filter((r) => r.id !== action.id),
        submitting: omit(state.submitting, action.id),
        errors: omit(state.errors, action.id),
      };
    case 'pruned': {
      // Drops cards whose outcome has been shown long enough, so the list (and
      // the countdown ticker) does not live on after the last prompt.
      const keep = action.keepClosedMs ?? PERMISSION_KEEP_CLOSED_MS;
      const requests = state.requests.filter((r) => state.submitting[r.id] || permissionCardLive(r, action.nowMs, keep));
      if (requests.length === state.requests.length) return state;
      const ids = new Set(requests.map((r) => r.id));
      const only = <T,>(record: Record<string, T>) => Object.fromEntries(Object.entries(record).filter(([id]) => ids.has(id)));
      return { requests, submitting: only(state.submitting), errors: only(state.errors) };
    }
    default:
      return state;
  }
}

/**
 * When a card stops being actionable: decided_at for a closed request,
 * expires_at for one still pending (its countdown runs out there). NaN when
 * neither is known.
 */
export function permissionCardEndMs(r: PermissionRequest): number {
  if (r.status === 'pending') {
    const expires = parseTimeMs(r.expires_at);
    return Number.isFinite(expires) ? expires : Infinity;
  }
  return parseTimeMs(r.decided_at || r.expires_at);
}

/** Whether a card still deserves to be shown at nowMs (pending, or recently ended). */
export function permissionCardLive(r: PermissionRequest, nowMs: number, keepClosedMs = PERMISSION_KEEP_CLOSED_MS): boolean {
  const end = permissionCardEndMs(r);
  return Number.isFinite(end) ? nowMs - end < keepClosedMs : end === Infinity;
}

/**
 * Requests worth a card: pending ones (until shortly after they expire),
 * anything being submitted, and closed ones for keepClosedMs. An error alone
 * does not keep a closed card up.
 */
export function visiblePermissionRequests(state: PermissionCardsState, nowMs: number, keepClosedMs = PERMISSION_KEEP_CLOSED_MS): PermissionRequest[] {
  return state.requests.filter((r) => Boolean(state.submitting[r.id]) || permissionCardLive(r, nowMs, keepClosedMs));
}

/** Reads a resource_changed(agent_instance, 'permission_requests') summary. */
export function permissionRealtimeFromSummary(summary: any): { action: string; request: PermissionRequest } | null {
  const request = normalizePermissionRequest(summary?.permission_request);
  if (!request) return null;
  return { action: str(summary?.action), request };
}
