import { createSlice, type PayloadAction } from '@reduxjs/toolkit';

// Ephemeral mounted-view data only. Never persist or reconstruct from Activity/chat.
export const LIVE_MEMBER_CAP = 256;
export type ToolSummary = {
  call_id: string; source: 'provider' | 'shell'; tool_name: string;
  summary: string; summary_truncated: boolean;
};
export type LiveCall = ToolSummary & { shell_session_id: string; started_at_ms: number };
export type LiveCompletion = ToolSummary & {
  duration_ms: number; completed_at_ms: number; status: string;
};
export type LiveSnapshot = {
  type: 'tool_activity_live'; instance_id: string; agent_id: string;
  display_name: string; chain_id: string; bridge_id: string; epoch: string;
  run_count: number; generation: number; revision: number; active: LiveCall[];
  completed_since_last: LiveCompletion[]; availability: 'ready';
};
export type LiveMember = {
  snapshot: LiveSnapshot | null; availability: 'loading' | 'ready' | 'unavailable';
  // Transport evidence, not producer timestamps: only incremental deliveries
  // may introduce a completed-only row. Unclassified snapshots are baselines.
  delivery?: { baseline: boolean; refresh: boolean };
  // Identities only, scoped to this mounted member's epoch/generation. Record
  // baseline/refresh identities even when React coalesces their snapshots.
  completedIdentities?: string[];
};
export type CompletionDelivery = {
  sequence: number; instanceId: string; epoch: string; generation: number;
  displayName: string; call: LiveCompletion; fresh: boolean;
};
type CompletionObserver = { ids: string[]; sequence: number; pending: CompletionDelivery[] };
export type ToolActivityState = {
  members: Record<string, LiveMember>; capacityExceeded: boolean;
  completionObservers: Record<string, CompletionObserver>;
};
const initialState: ToolActivityState = { members: {}, capacityExceeded: false, completionObservers: {} };
const text = (v: unknown, max: number): v is string => typeof v === 'string' && v.length <= max;
const count = (v: unknown): v is number => Number.isSafeInteger(v) && Number(v) >= 0;
export const validInstanceId = (v: unknown): v is string =>
  text(v, 64) && /^inst_[A-Za-z0-9_-]+$/.test(v);
const encoder = new TextEncoder();
function summary(raw: any): ToolSummary | null {
  if (!text(raw?.call_id, 2048) || !raw.call_id ||
      !['provider', 'shell'].includes(raw.source) || !text(raw.tool_name, 96) ||
      !text(raw.summary, 512) || encoder.encode(raw.summary).length > 512 ||
      typeof raw.summary_truncated !== 'boolean') return null;
  return { call_id: raw.call_id, source: raw.source, tool_name: raw.tool_name,
    summary: raw.summary, summary_truncated: raw.summary_truncated };
}
// Validate bounds before retaining display fields; drop all arbitrary args/results.
export function parseLiveSnapshot(raw: any): LiveSnapshot | null {
  if (raw?.type !== 'tool_activity_live' || !validInstanceId(raw.instance_id) ||
      !text(raw.agent_id, 64) || !text(raw.chain_id, 64) || !text(raw.bridge_id, 64) ||
      !text(raw.display_name, 256) || !text(raw.epoch, 24) || !/^[0-9]+$/.test(raw.epoch) ||
      !count(raw.run_count) || !count(raw.generation) || raw.generation < 1 || !count(raw.revision) ||
      raw.availability !== 'ready' || !Array.isArray(raw.active) || raw.active.length > 32 ||
      !Array.isArray(raw.completed_since_last) || raw.completed_since_last.length > 32) return null;
  const active: LiveCall[] = [], completed: LiveCompletion[] = [];
  for (const call of raw.active) {
    const item = summary(call);
    if (!item || active.some((v) => v.call_id === item.call_id) ||
        !text(call.shell_session_id, 64) || !count(call.started_at_ms)) return null;
    active.push({ ...item, shell_session_id: call.shell_session_id, started_at_ms: call.started_at_ms });
  }
  for (const call of raw.completed_since_last) {
    const item = summary(call);
    if (!item || completed.some((v) => v.call_id === item.call_id) ||
        !count(call.duration_ms) || !count(call.completed_at_ms) || !text(call.status, 64)) return null;
    completed.push({ ...item, duration_ms: call.duration_ms,
      completed_at_ms: call.completed_at_ms, status: call.status });
  }
  return { type: 'tool_activity_live', instance_id: raw.instance_id, agent_id: raw.agent_id,
    display_name: raw.display_name, chain_id: raw.chain_id, bridge_id: raw.bridge_id,
    epoch: raw.epoch, run_count: raw.run_count, generation: raw.generation, revision: raw.revision,
    active, completed_since_last: completed, availability: 'ready' };
}
export type ToolOrder = Pick<LiveSnapshot, 'epoch' | 'generation' | 'revision'>;
export function compareToolOrder(next: ToolOrder, prior: ToolOrder): number {
  const a = next.epoch.replace(/^0+/, '') || '0', b = prior.epoch.replace(/^0+/, '') || '0';
  return a.length - b.length || (a < b ? -1 : a > b ? 1 : 0) ||
    next.generation - prior.generation || next.revision - prior.revision;
}
const slice = createSlice({
  name: 'toolActivity', initialState,
  reducers: {
    toolCompletionObserverOpened(state, action: PayloadAction<{ key: string; ids: string[] }>) {
      state.completionObservers[action.payload.key] = { ids: action.payload.ids, sequence: 0, pending: [] };
    },
    toolCompletionObserverClosed(state, action: PayloadAction<string>) {
      delete state.completionObservers[action.payload];
    },
    toolCompletionsObserved(state, action: PayloadAction<{ key: string; through: number }>) {
      const observer = state.completionObservers[action.payload.key];
      if (observer) observer.pending = observer.pending.filter((item) => item.sequence > action.payload.through);
    },
    toolMembersSelected(state, action: PayloadAction<string[]>) {
      state.capacityExceeded = false;
      const members: Record<string, LiveMember> = {};
      for (const id of action.payload) members[id] = state.members[id] ||
        { snapshot: null, availability: 'loading' };
      state.members = members;
      for (const observer of Object.values(state.completionObservers))
        observer.pending = observer.pending.filter((item) => Boolean(members[item.instanceId]));
    },
    toolCapacityExceeded(state) {
      state.members = {}; state.capacityExceeded = true;
      for (const observer of Object.values(state.completionObservers)) observer.pending = [];
    },
    toolStateReceived: {
      prepare(snapshot: LiveSnapshot, delivery = { baseline: true, refresh: false }) {
        return { payload: snapshot, meta: delivery };
      },
      reducer(state, action: PayloadAction<LiveSnapshot, string, { baseline: boolean; refresh: boolean }>) {
        const id = action.payload.instance_id;
        if (!state.members[id]) return;
        const delivery = action.meta || { baseline: true, refresh: false };
        const snapshot = action.payload;
        const prior = state.members[id];
        const known = new Set(prior.snapshot?.epoch === snapshot.epoch && prior.snapshot.generation === snapshot.generation
          ? prior.completedIdentities : []);
        const identity = (call: LiveCompletion) => JSON.stringify([call.source, call.call_id]);
        const fresh = new Set(snapshot.completed_since_last.filter((call) => !known.has(identity(call))).map(identity));
        for (const call of snapshot.completed_since_last) known.add(identity(call));
        state.members[id] = { snapshot, availability: 'ready', delivery, completedIdentities: [...known] };
        for (const observer of Object.values(state.completionObservers)) {
          // Pending deliveries survive later transient snapshots until each view
          // has rendered them, then its acknowledgement drops the content. This
          // prevents React batching from swallowing a fast completion entirely.
          observer.pending = observer.pending.filter((item) => item.instanceId !== id ||
            (item.epoch === snapshot.epoch && item.generation === snapshot.generation));
          if (!observer.ids.includes(id) || delivery.baseline || delivery.refresh) continue;
          for (const call of snapshot.completed_since_last) observer.pending.push({
            sequence: ++observer.sequence, instanceId: id, epoch: snapshot.epoch,
            generation: snapshot.generation, displayName: snapshot.display_name, call, fresh: fresh.has(identity(call)),
          });
        }
      },
    },
    toolMembersUnavailable(state, action: PayloadAction<string[]>) {
      for (const id of action.payload) if (state.members[id])
        state.members[id] = { snapshot: null, availability: 'unavailable' };
      for (const observer of Object.values(state.completionObservers))
        observer.pending = observer.pending.filter((item) => !action.payload.includes(item.instanceId));
    },
  },
});
export const { toolMembersSelected, toolStateReceived, toolMembersUnavailable, toolCapacityExceeded,
  toolCompletionObserverOpened, toolCompletionObserverClosed, toolCompletionsObserved } = slice.actions;
export default slice.reducer;
