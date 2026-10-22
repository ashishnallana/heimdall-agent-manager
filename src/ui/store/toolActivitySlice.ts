import { createSlice, type PayloadAction } from '@reduxjs/toolkit';

// Mounted-view state only: never persist or reconstruct from chat/Activity.
export const LIVE_MEMBER_CAP = 256;
export type LiveCall = {
  call_id: string; source: 'provider' | 'shell'; tool_name: string;
  shell_session_id: string; started_at_ms: number;
};
export type LiveSnapshot = {
  type: 'tool_activity_live'; instance_id: string; agent_id: string;
  display_name: string; chain_id: string; bridge_id: string; epoch: string;
  generation: number; revision: number; active: LiveCall[];
  last_completion: { duration_ms: number } | null; availability: 'ready';
};
export type LiveMember = {
  instance_id: string; agent_id: string; display_name: string;
  snapshot: LiveSnapshot | null; availability: 'ready' | 'offline';
};
export type LiveScope = {
  instanceId: string; chainId: string; refs: number; requestId: string;
  loading: boolean; error: string; members: Record<string, LiveMember>;
  pending: Record<string, LiveSnapshot | null>; overflow: boolean;
  unavailable: Record<string, boolean>;
};
export type ToolActivityState = {
  connected: boolean; refresh: number; scopes: Record<string, LiveScope>;
};
const initialState: ToolActivityState = { connected: false, refresh: 0, scopes: {} };
export const liveScopeKey = (instanceId: string, chainId = '') =>
  chainId ? 'chain:' + chainId : 'instance:' + instanceId;

function decimalCompare(a: string, b: string): number {
  a = a.replace(/^0+/, '') || '0';
  b = b.replace(/^0+/, '') || '0';
  return a.length === b.length ? (a < b ? -1 : a > b ? 1 : 0) : a.length - b.length;
}
export function newerSnapshot(next: LiveSnapshot, prior?: LiveSnapshot | null): boolean {
  if (!prior) return true;
  const epoch = decimalCompare(next.epoch, prior.epoch);
  return epoch > 0 || (epoch === 0 && next.generation >= prior.generation && next.revision > prior.revision);
}

// Pick only live display data; never retain args, outputs or completion details.
export function parseLiveSnapshot(raw: any): LiveSnapshot | null {
  const text = (v: unknown, max: number) => typeof v === 'string' && v.length <= max;
  const id = (v: unknown) => text(v, 64);
  const count = (v: unknown) => Number.isSafeInteger(v) && Number(v) >= 0;
  if (raw?.type !== 'tool_activity_live' || !id(raw.instance_id) || !raw.instance_id ||
      !id(raw.agent_id) || !id(raw.chain_id) || !id(raw.bridge_id) ||
      !text(raw.display_name, 256) || !text(raw.epoch, 24) || !/^[0-9]+$/.test(raw.epoch) ||
      !count(raw.generation) || !count(raw.revision) ||
      !Array.isArray(raw.active) || raw.active.length > 32) return null;
  const active: LiveCall[] = [];
  const seen = new Set<string>();
  for (const call of raw.active) {
    if (!text(call?.call_id, 2048) || !call.call_id || seen.has(call.call_id) ||
        !['provider', 'shell'].includes(call.source) || !text(call.tool_name, 96) ||
        !id(call.shell_session_id) || !count(call.started_at_ms)) return null;
    seen.add(call.call_id);
    active.push({ call_id: call.call_id, source: call.source, tool_name: call.tool_name,
      shell_session_id: call.shell_session_id, started_at_ms: call.started_at_ms });
  }
  const duration = raw.last_completion?.duration_ms;
  if (raw.last_completion != null && !count(duration)) return null;
  return { type: 'tool_activity_live', instance_id: raw.instance_id, agent_id: raw.agent_id,
    display_name: raw.display_name, chain_id: raw.chain_id, bridge_id: raw.bridge_id,
    epoch: raw.epoch, generation: raw.generation, revision: raw.revision, active,
    last_completion: raw.last_completion == null ? null : { duration_ms: duration },
    availability: 'ready' };
}
function invalidate(scope: LiveScope) {
  scope.requestId = '';
  scope.loading = true;
  scope.error = '';
  scope.members = {};
  scope.pending = {};
  scope.unavailable = {};
  scope.overflow = false;
}
const slice = createSlice({
  name: 'toolActivity', initialState,
  reducers: {
    liveScopeMounted(state, action: PayloadAction<{ instanceId: string; chainId: string }>) {
      const { instanceId, chainId } = action.payload;
      const key = liveScopeKey(instanceId, chainId);
      if (state.scopes[key]) { state.scopes[key].refs++; return; }
      state.scopes[key] = { instanceId, chainId, refs: 1, requestId: '', loading: true,
        error: '', members: {}, pending: {}, unavailable: {}, overflow: false };
    },
    liveScopeUnmounted(state, action: PayloadAction<string>) {
      const scope = state.scopes[action.payload];
      if (scope && --scope.refs === 0) delete state.scopes[action.payload];
    },
    liveStreamReady(state) {
      state.connected = true;
      state.refresh++;
      Object.values(state.scopes).forEach(invalidate);
    },
    liveStreamDisconnected(state) {
      state.connected = false;
      state.refresh++;
      Object.values(state.scopes).forEach(invalidate);
    },
    liveResyncRequested(state) {
      state.refresh++;
      Object.values(state.scopes).forEach(invalidate);
    },
    liveSnapshotStarted(state, action: PayloadAction<{ key: string; requestId: string }>) {
      const scope = state.scopes[action.payload.key];
      if (!scope || !state.connected) return;
      scope.requestId = action.payload.requestId;
      scope.loading = true;
      scope.error = '';
    },
    liveSnapshotLoaded(state, action: PayloadAction<{ key: string; requestId: string; members: LiveMember[] }>) {
      const scope = state.scopes[action.payload.key];
      if (!state.connected || !scope || scope.requestId !== action.payload.requestId) return;
      scope.loading = false;
      if (scope.overflow) {
        scope.members = {}; scope.pending = {}; scope.error = 'Live snapshot buffer full';
        return;
      }
      const members: Record<string, LiveMember> = {};
      for (const member of action.payload.members) {
        const id = member.instance_id;
        const pending = scope.pending[id];
        let snapshot = member.snapshot;
        if (member.availability === 'ready' && pending && newerSnapshot(pending, snapshot)) snapshot = pending;
        if (member.availability === 'offline') scope.unavailable[id] = true;
        if (scope.unavailable[id]) snapshot = null;
        members[id] = { ...member, snapshot, availability: snapshot ? 'ready' : 'offline' };
      }
      scope.members = members;
      scope.pending = {};
    },
    liveSnapshotFailed(state, action: PayloadAction<{ key: string; requestId: string; error: string }>) {
      const scope = state.scopes[action.payload.key];
      if (!scope || scope.requestId !== action.payload.requestId) return;
      scope.members = {}; scope.pending = {}; scope.loading = false;
      scope.error = action.payload.error;
    },
    liveFrameReceived(state, action: PayloadAction<LiveSnapshot>) {
      if (!state.connected) return;
      const snapshot = action.payload, id = snapshot.instance_id;
      for (const scope of Object.values(state.scopes)) {
        if (scope.unavailable[id]) continue;
        if (scope.loading) {
          // Buffer latest-only until the authoritative roster is complete.
          if (!scope.chainId && scope.instanceId !== id) continue;
          if (!scope.pending[id] && Object.keys(scope.pending).length >= LIVE_MEMBER_CAP) {
            scope.overflow = true; continue;
          }
          if (newerSnapshot(snapshot, scope.pending[id])) scope.pending[id] = snapshot;
          continue;
        }
        const member = scope.members[id];
        if (member && newerSnapshot(snapshot, member.snapshot)) {
          member.snapshot = snapshot; member.availability = 'ready';
        }
      }
    },
    liveInstanceUnavailable(state, action: PayloadAction<string>) {
      for (const scope of Object.values(state.scopes)) {
        const id = action.payload;
        if (!scope.members[id] && !scope.pending[id] && scope.instanceId !== id &&
            !(scope.chainId && scope.loading)) continue;
        if (!scope.unavailable[id] && Object.keys(scope.unavailable).length >= LIVE_MEMBER_CAP) {
          scope.overflow = true; continue;
        }
        scope.unavailable[id] = true;
        delete scope.pending[id];
        if (scope.members[id]) {
          scope.members[id].snapshot = null; scope.members[id].availability = 'offline';
        }
      }
    },
  },
});
export const { liveScopeMounted, liveScopeUnmounted, liveStreamReady, liveStreamDisconnected,
  liveResyncRequested, liveSnapshotStarted, liveSnapshotLoaded, liveSnapshotFailed,
  liveFrameReceived, liveInstanceUnavailable } = slice.actions;
export default slice.reducer;
