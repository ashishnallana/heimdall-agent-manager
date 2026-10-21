import { createSlice, PayloadAction } from '@reduxjs/toolkit';

// Transient, ephemeral agent-activity state that powers the push-only "activity
// bubbles" shown above the chat composer (see AgentActivityBubbles in P3). This
// slice is deliberately DECOUPLED from RTK Query: `agent_action` events are
// fire-and-forget presence signals, so routing them here must NEVER invalidate or
// refetch a cache. The state is bounded (last few actions per instance) and is
// reset with the rest of the client state on user switch via the root reducer's
// `priorUserClientStateCleared` handling (store.ts), so it needs no explicit
// clear-on-logout reducer.

// Ring buffer: keep only the last N actions per instance (enough to replay recent
// activity when the user opens that instance's conversation).
export const AGENT_ACTIVITY_RING_CAP = 4;
// Replay window: on focus/open we replay buffered actions newer than this; older
// buffered actions are dropped (never replayed).
export const AGENT_ACTIVITY_REPLAY_WINDOW_MS = 5 * 60_000;

export type AgentActionItem = {
  // Stable React key; unique across replayed + live bubbles for the same instance.
  id: string;
  // Machine kind (e.g. 'task_comment') — optional icon/telemetry, never shown raw.
  action: string;
  // Human-readable, id-free summary composed by the hub (already clipped).
  summary: string;
  // Hub unix-ms timestamp; used for the replay window and ordering.
  ts: number;
};

type AgentActivityState = {
  // Per-instance ring buffer (cap AGENT_ACTIVITY_RING_CAP), oldest-first.
  byInstance: Record<string, AgentActionItem[]>;
  // Per-instance most-recent action time; feeds the working-indicator decoupling
  // in P4 (dots animate while now - lastActionAt is within a short window).
  lastActionAt: Record<string, number>;
  // Per-instance set of action ids that have ALREADY been surfaced on screen,
  // mapped to the time they were shown. This outlives the component (it survives
  // conversation switches and remounts within the session) so an action shown
  // once is never replayed again — the ring buffer keeps items for the 5-min
  // replay window, but this set records which of them the user has actually seen.
  // Reset with the rest of the slice on user switch (priorUserClientStateCleared).
  shownByInstance: Record<string, Record<string, number>>;
  // Monotonic counter so concurrent same-ts actions still get unique ids.
  seq: number;
};

const initialState: AgentActivityState = {
  byInstance: {},
  lastActionAt: {},
  shownByInstance: {},
  seq: 0,
};

export type AgentActionReceivedPayload = {
  instanceId: string;
  action: string;
  summary: string;
  ts: number;
};

const agentActivitySlice = createSlice({
  name: 'agentActivity',
  initialState,
  reducers: {
    // Append one agent action to the acting instance's ring buffer and bump its
    // lastActionAt. Ignores malformed events (no instance/summary). The visible
    // 4s per-bubble lifetime is owned by the component, not this slice — here we
    // only retain enough history to replay on open.
    agentActionReceived(state, action: PayloadAction<AgentActionReceivedPayload>) {
      const instanceId = String(action.payload?.instanceId || '');
      const summary = String(action.payload?.summary || '');
      if (!instanceId || !summary) return;
      const ts = Number(action.payload?.ts) || Date.now();
      state.seq += 1;
      const item: AgentActionItem = {
        id: `${instanceId}:${ts}:${state.seq}`,
        action: String(action.payload?.action || ''),
        summary,
        ts,
      };
      const buffer = state.byInstance[instanceId] || (state.byInstance[instanceId] = []);
      buffer.push(item);
      // Trim oldest so the buffer never exceeds the ring cap.
      if (buffer.length > AGENT_ACTIVITY_RING_CAP) {
        buffer.splice(0, buffer.length - AGENT_ACTIVITY_RING_CAP);
      }
      state.lastActionAt[instanceId] = Math.max(Number(state.lastActionAt[instanceId] || 0), ts);
    },
    // Mark one action as surfaced (actually shown on screen) for an instance so it
    // is never replayed again. Idempotent: re-marking an id just refreshes its
    // timestamp. Called at the moment a bubble appears (not when it is merely
    // scheduled), so items staged during replay but never shown stay replayable.
    // Prunes entries older than the replay window on insert to bound the set.
    agentActionSurfaced(state, action: PayloadAction<{ instanceId: string; id: string; ts?: number }>) {
      const instanceId = String(action.payload?.instanceId || '');
      const id = String(action.payload?.id || '');
      if (!instanceId || !id) return;
      const ts = Number(action.payload?.ts) || Date.now();
      const shown = state.shownByInstance[instanceId] || (state.shownByInstance[instanceId] = {});
      // Prune ids older than the replay window relative to this event; anything
      // beyond the window can no longer be replayed, so we needn't remember it.
      const cutoff = ts - AGENT_ACTIVITY_REPLAY_WINDOW_MS;
      for (const key of Object.keys(shown)) {
        if (shown[key] < cutoff) delete shown[key];
      }
      shown[id] = ts;
    },
    // Drop an instance's buffered activity (e.g. when it is stopped/removed).
    agentActivityInstanceCleared(state, action: PayloadAction<string>) {
      const instanceId = String(action.payload || '');
      if (!instanceId) return;
      delete state.byInstance[instanceId];
      delete state.lastActionAt[instanceId];
      delete state.shownByInstance[instanceId];
    },
  },
});

// selectReplayableActions returns the buffered actions still within the replay
// window (< AGENT_ACTIVITY_REPLAY_WINDOW_MS old), oldest-first — the exact set the
// bubble row replays (staggered) when the user opens/focuses the conversation.
// Already-surfaced ids (from `shownIds`) are excluded so an action shown once is
// never replayed again. `shownIds` is optional and defaults to none, preserving
// the original behavior for callers/tests that don't track surfaced state.
// Pure so the component (P3) and the unit tests share one implementation.
export function selectReplayableActions(
  buffer: AgentActionItem[] | undefined,
  now: number,
  shownIds?: Record<string, number>,
): AgentActionItem[] {
  if (!buffer || buffer.length === 0) return [];
  return buffer
    .filter((item) => now - Number(item?.ts || 0) < AGENT_ACTIVITY_REPLAY_WINDOW_MS)
    .filter((item) => !shownIds || !Object.prototype.hasOwnProperty.call(shownIds, String(item?.id || '')))
    .slice()
    .sort((left, right) => Number(left?.ts || 0) - Number(right?.ts || 0));
}

// Stable empty reference so selectors don't churn renders for instances with no
// buffered activity.
const EMPTY_BUFFER: AgentActionItem[] = [];

// Stable empty reference for the shown-id map (same churn-avoidance rationale).
const EMPTY_SHOWN: Record<string, number> = {};

export const selectAgentActivityBuffer = (state: any, instanceId: string): AgentActionItem[] =>
  state?.agentActivity?.byInstance?.[instanceId] || EMPTY_BUFFER;

// selectAgentShownIds returns the map of action-id → shown-time for an instance
// (ids already surfaced on screen). Feeds selectReplayableActions so re-opening a
// conversation never re-shows a bubble the user has already seen.
export const selectAgentShownIds = (state: any, instanceId: string): Record<string, number> =>
  state?.agentActivity?.shownByInstance?.[instanceId] || EMPTY_SHOWN;

export const { agentActionReceived, agentActionSurfaced, agentActivityInstanceCleared } =
  agentActivitySlice.actions;
export default agentActivitySlice.reducer;
