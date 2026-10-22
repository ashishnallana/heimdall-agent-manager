// Agent blockers (REQ-EXT-BLK-1..5, UI). Pure logic, no React and no fetch
// (tests/ui_extension_blockers_test.ts).
//
// The hub keeps what blocks an agent instance IN MEMORY only (nothing is
// persisted) and rebuilds it from bridge snapshots:
//   GET  /api/v1/agent-instances/{id}/blockers
//        -> {agent_instance_id, revision, blockers:[{blocker_id, kind, provider,
//            tool_name, summary, input, agent_id, created_at, expires_at}]}
//   POST /api/v1/agent-instances/{id}/blockers/{blocker_id}/resolve {decision}
// Every change is announced as resource_changed(agent_instance, <id>,
// 'agent_blockers_changed', {agent_instance_id, revision, count}); the client
// refetches the list. kind 'permission' can be answered here until expires_at
// (then the provider shows its own TUI prompt); kind 'terminal_prompt' comes
// from screen detection and can only be answered in the agent terminal.
import { formatCountdown, parseTimeMs } from './permissionCardModel';

export type BlockerKind = 'permission' | 'terminal_prompt';
export type BlockerDecision = 'allow' | 'deny';

export interface AgentBlocker {
  blocker_id: string;
  kind: BlockerKind;
  provider: string;
  tool_name: string;
  summary: string;
  input: Record<string, any>;
  agent_id: string;
  created_at: string;
  expires_at: string;
}

export interface AgentBlockersSnapshot {
  agent_instance_id: string;
  revision: number;
  blockers: AgentBlocker[];
}

/** The realtime change name on resource_changed(agent_instance). */
export const AGENT_BLOCKERS_CHANGE = 'agent_blockers_changed';

function str(value: unknown): string {
  return typeof value === 'string' ? value : value == null ? '' : String(value);
}

function num(value: unknown): number {
  const n = typeof value === 'number' ? value : Number(value);
  return Number.isFinite(n) ? n : 0;
}

export function normalizeBlocker(raw: any): AgentBlocker | null {
  if (!raw || typeof raw !== 'object') return null;
  const blocker_id = str(raw.blocker_id);
  if (!blocker_id) return null;
  const kind: BlockerKind = raw.kind === 'terminal_prompt' ? 'terminal_prompt' : raw.kind === 'permission' ? 'permission' : ('' as any);
  if (!kind) return null;
  return {
    blocker_id,
    kind,
    provider: str(raw.provider),
    tool_name: str(raw.tool_name),
    summary: str(raw.summary),
    input: raw.input && typeof raw.input === 'object' && !Array.isArray(raw.input) ? raw.input : {},
    agent_id: str(raw.agent_id),
    created_at: str(raw.created_at),
    expires_at: kind === 'permission' ? str(raw.expires_at) : '',
  };
}

export function normalizeBlockersSnapshot(raw: any, instanceId = ''): AgentBlockersSnapshot {
  const rows = Array.isArray(raw?.blockers) ? raw.blockers : [];
  const blockers = (rows.map(normalizeBlocker).filter(Boolean) as AgentBlocker[]).sort((a, b) =>
    a.created_at < b.created_at ? -1 : a.created_at > b.created_at ? 1 : a.blocker_id.localeCompare(b.blocker_id),
  );
  return { agent_instance_id: str(raw?.agent_instance_id) || instanceId, revision: num(raw?.revision), blockers };
}

/** Reads a resource_changed(agent_instance, 'agent_blockers_changed') summary. */
export function blockersRealtimeFromSummary(summary: any, instanceId = ''): { agent_instance_id: string; revision: number; count: number } | null {
  if (!summary || typeof summary !== 'object') return null;
  const id = str(summary.agent_instance_id) || instanceId;
  if (!id) return null;
  return { agent_instance_id: id, revision: num(summary.revision), count: Math.max(0, num(summary.count)) };
}

// ---------------------------------------------------------------------------
// Instance status gates.

/** Blockers only exist while the agent process does; anything else clears the list. */
export function instanceCanBeBlocked(runtimeStatus: string): boolean {
  const s = String(runtimeStatus || '').toLowerCase();
  return s === 'running' || s === 'starting' || s === 'blocked';
}

/** Allow / Deny are offered only while the instance is running. */
export function instanceCanDecide(runtimeStatus: string): boolean {
  return String(runtimeStatus || '').toLowerCase() === 'running';
}

// ---------------------------------------------------------------------------
// Card view.

export interface BlockerCardView {
  /** 'pending' while answerable here, 'expired' after the hook deadline, 'terminal' for a screen prompt. */
  phase: 'pending' | 'expired' | 'terminal';
  secondsLeft: number;
  /** "4:59", '' when there is no deadline. */
  countdown: string;
  canDecide: boolean;
  statusLabel: string;
}

export function blockerCardView(blocker: AgentBlocker, nowMs: number, runtimeStatus = 'running'): BlockerCardView {
  if (blocker.kind === 'terminal_prompt') {
    return { phase: 'terminal', secondsLeft: 0, countdown: '', canDecide: false, statusLabel: 'Waiting for input in the terminal' };
  }
  const live = instanceCanDecide(runtimeStatus);
  const expiresMs = parseTimeMs(blocker.expires_at);
  if (!Number.isFinite(expiresMs)) {
    return { phase: 'pending', secondsLeft: 0, countdown: '', canDecide: live, statusLabel: 'Waiting for approval' };
  }
  const secondsLeft = Math.max(0, Math.ceil((expiresMs - nowMs) / 1000));
  if (secondsLeft <= 0) {
    return { phase: 'expired', secondsLeft: 0, countdown: '', canDecide: false, statusLabel: 'Expired — answer in the agent terminal' };
  }
  return { phase: 'pending', secondsLeft, countdown: formatCountdown(secondsLeft), canDecide: live, statusLabel: 'Waiting for approval' };
}

// ---------------------------------------------------------------------------
// Reducer: the instance's blocker list kept live from fetches, realtime frames
// and the card's own Allow / Deny round trip.

export interface BlockersState {
  instanceId: string;
  /** Revision of the snapshot shown (0 = none yet). */
  revision: number;
  blockers: AgentBlocker[];
  /** blocker id → decision being submitted. */
  submitting: Record<string, BlockerDecision>;
  /** blocker id → last submit error. */
  errors: Record<string, string>;
  /** Blockers answered here, hidden until a snapshot newer than resolvedAt[id] drops them. */
  resolved: Record<string, number>;
}

export type BlockersAction =
  | { type: 'loaded'; snapshot: AgentBlockersSnapshot }
  | { type: 'decision_started'; id: string; decision: BlockerDecision }
  | { type: 'decision_succeeded'; id: string }
  | { type: 'decision_failed'; id: string; error: string }
  | { type: 'instance_stopped' };

export function initialBlockersState(instanceId = ''): BlockersState {
  return { instanceId, revision: 0, blockers: [], submitting: {}, errors: {}, resolved: {} };
}

function omit<T>(record: Record<string, T>, key: string): Record<string, T> {
  if (!(key in record)) return record;
  const next = { ...record };
  delete next[key];
  return next;
}

function keepKeys<T>(record: Record<string, T>, keep: (key: string) => boolean): Record<string, T> {
  let changed = false;
  const next: Record<string, T> = {};
  for (const [k, v] of Object.entries(record)) {
    if (keep(k)) next[k] = v;
    else changed = true;
  }
  return changed ? next : record;
}

export function blockersReducer(state: BlockersState, action: BlockersAction): BlockersState {
  switch (action.type) {
    case 'loaded': {
      const snap = action.snapshot;
      if (state.instanceId && snap.agent_instance_id && snap.agent_instance_id !== state.instanceId) return state;
      // Revisions only grow on a bridge; an older snapshot (a slow fetch that
      // raced a newer one) never replaces what is shown. 0 = unknown, accepted.
      if (snap.revision > 0 && state.revision > 0 && snap.revision < state.revision) return state;
      const ids = new Set(snap.blockers.map((b) => b.blocker_id));
      return {
        ...state,
        revision: snap.revision || state.revision,
        blockers: snap.blockers,
        submitting: keepKeys(state.submitting, (id) => ids.has(id)),
        errors: keepKeys(state.errors, (id) => ids.has(id)),
        // A blocker answered here stays hidden while the hub still lists it
        // (the bridge snapshot lags the decision); once gone, forget it.
        resolved: keepKeys(state.resolved, (id) => ids.has(id)),
      };
    }
    case 'decision_started':
      return { ...state, submitting: { ...state.submitting, [action.id]: action.decision }, errors: omit(state.errors, action.id) };
    case 'decision_succeeded':
      return {
        ...state,
        submitting: omit(state.submitting, action.id),
        errors: omit(state.errors, action.id),
        resolved: { ...state.resolved, [action.id]: state.revision },
      };
    case 'decision_failed':
      return {
        ...state,
        submitting: omit(state.submitting, action.id),
        errors: { ...state.errors, [action.id]: action.error || 'Could not send the decision.' },
      };
    case 'instance_stopped':
      return { ...initialBlockersState(state.instanceId), revision: state.revision };
    default:
      return state;
  }
}

/** Blockers worth a card: everything the hub lists except ones answered here. */
export function visibleBlockers(state: BlockersState): AgentBlocker[] {
  return state.blockers.filter((b) => !(b.blocker_id in state.resolved));
}

/**
 * Whether a realtime frame means the cached list is stale: a newer revision or
 * a count that differs from what is shown.
 */
export function blockersNeedRefetch(state: Pick<BlockersState, 'revision' | 'blockers'>, frame: { revision: number; count: number }): boolean {
  if (frame.revision > state.revision) return true;
  return frame.count !== state.blockers.length;
}
