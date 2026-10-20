import { createAsyncThunk, createSlice } from '@reduxjs/toolkit';
import * as daemonApi from '../api/daemonApi';
import { storeKnownAgents } from '../api/agentCatalog';
import { agentsApi } from '../api/endpoints/agents';
import { chatEndpoints } from '../api/endpoints/chats';

const DEFAULT_DAEMON_URL = 'http://127.0.0.1:49322';
const DEFAULT_USER_ID = '';
const DAEMON_PROFILES_KEY = 'odin.daemonProfiles';
export const GUIDE_AGENT_ID = 'guide@heimdall';
const CHAT_OPTIMISTIC_GRACE_MS = 30_000;

function getStoredValue(key: string, fallback: string): string {
  try {
    return window.localStorage.getItem(key) || fallback;
  } catch {
    return fallback;
  }
}

function setStoredValue(key: string, value: string): void {
  try {
    window.localStorage.setItem(key, value);
  } catch {
    // Local storage is only a convenience for this UI session.
  }
}

function normalizeDaemonUrl(value: string): string {
  return (value || '').trim().replace(/\/$/, '');
}

function daemonLabelForUrl(url: string): string {
  try {
    const parsed = new URL(url);
    return parsed.host || url;
  } catch {
    return url;
  }
}

function normalizeDaemonProfiles(items: any[], activeUrl: string) {
  const byUrl: Record<string, any> = {};
  for (const item of items || []) {
    const url = normalizeDaemonUrl(item?.url || item?.daemonUrl || '');
    if (!url) continue;
    byUrl[url] = { label: String(item?.label || daemonLabelForUrl(url)), url };
  }
  if (activeUrl && !byUrl[activeUrl]) byUrl[activeUrl] = { label: daemonLabelForUrl(activeUrl), url: activeUrl };
  if (!byUrl[DEFAULT_DAEMON_URL]) byUrl[DEFAULT_DAEMON_URL] = { label: 'Local daemon', url: DEFAULT_DAEMON_URL };
  return Object.values(byUrl).sort((left: any, right: any) => (left.label || '').localeCompare(right.label || ''));
}

function loadDaemonProfiles(activeUrl: string) {
  try {
    return normalizeDaemonProfiles(JSON.parse(window.localStorage.getItem(DAEMON_PROFILES_KEY) || '[]'), activeUrl);
  } catch {
    return normalizeDaemonProfiles([], activeUrl);
  }
}

function storeDaemonProfiles(profiles: any[]) {
  try {
    window.localStorage.setItem(DAEMON_PROFILES_KEY, JSON.stringify(profiles));
  } catch {
    // Local daemon profiles are a UI convenience.
  }
}

function newClientInstanceId(): string {
  const suffix = globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(16).slice(2)}`;
  return `heimdall-${suffix}`;
}

function createClientInstanceId() {
  const existing = getStoredValue('odin.clientInstanceId', '');
  if (existing) return existing;
  const clientInstanceId = newClientInstanceId();
  setStoredValue('odin.clientInstanceId', clientInstanceId);
  return clientInstanceId;
}

function extractMessageArtifactIds(message: any): string[] | undefined {
  const seen = new Set<string>();
  const out: string[] = [];
  const push = (value: any) => {
    const raw = typeof value === 'object' && value !== null
      ? String(value.artifact_id || value.artifactId || value.id || '')
      : String(value || '');
    const id = raw.replace(/^artifact:\/\//i, '').trim();
    if (!id || seen.has(id)) return;
    seen.add(id);
    out.push(id);
  };
  const direct = message?.artifact_ids ?? message?.artifactIds;
  if (Array.isArray(direct)) direct.forEach(push);
  const json = message?.artifact_ids_json ?? message?.artifactIdsJson;
  if (typeof json === 'string' && json.trim()) {
    try {
      const parsed = JSON.parse(json);
      if (Array.isArray(parsed)) parsed.forEach(push);
    } catch (_err) {}
  } else if (Array.isArray(json)) {
    json.forEach(push);
  }
  const body = String(message?.body || '');
  const re = /artifact:\/\/([A-Za-z0-9._:-]+)/g;
  let match: RegExpExecArray | null;
  while ((match = re.exec(body)) !== null) push(match[1]);
  return out.length ? out : undefined;
}

function mapMessage(message: any) {
  const createdUnixMs = Number(message.created_unix_ms ?? message.createdUnixMs ?? 0) || (message.created_at || message.createdAt ? Date.parse(message.created_at || message.createdAt) : 0) || 0;
  const createdTime = createdUnixMs ? new Date(createdUnixMs).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : '';
  const deliveredUnixMs = Number(message.delivered_unix_ms ?? message.deliveredUnixMs ?? 0) || (message.delivered_at || message.deliveredAt ? Date.parse(message.delivered_at || message.deliveredAt) : 0) || 0;
  const readUnixMs = Number(message.read_unix_ms ?? message.readUnixMs ?? 0) || (message.read_at || message.readAt ? Date.parse(message.read_at || message.readAt) : 0) || 0;
  const deliveryFailedUnixMs = Number(message.delivery_failed_unix_ms ?? message.deliveryFailedUnixMs ?? 0) || (message.delivery_failed_at || message.deliveryFailedAt ? Date.parse(message.delivery_failed_at || message.deliveryFailedAt) : 0) || 0;
  return {
    id: message.message_id ?? message.id,
    author: message.direction === 'user_to_agent' || message.author === 'user' ? 'user' : 'agent',
    body: message.body,
    timestamp: createdTime || message.timestamp || '',
    createdUnixMs,
    deliveredAt: deliveredUnixMs > 0 ? new Date(deliveredUnixMs).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : (message.deliveredAt || ''),
    deliveredUnixMs,
    readAt: readUnixMs > 0 ? new Date(readUnixMs).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : (message.readAt || ''),
    readUnixMs,
    deliveryFailedAt: deliveryFailedUnixMs > 0 ? new Date(deliveryFailedUnixMs).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : (message.deliveryFailedAt || ''),
    deliveryFailedUnixMs,
    deliveryError: message.delivery_error ?? message.deliveryError ?? '',
    interrupt: !!message.interrupt,
    artifactIds: extractMessageArtifactIds(message),
    sending: Boolean(message.sending),
    optimistic: Boolean(message.optimistic),
    error: Boolean(message.error),
  };
}

function mergeMessage(existing: any, incoming: any) {
  const deliveredUnixMs = Math.max(Number(existing.deliveredUnixMs || 0), Number(incoming.deliveredUnixMs || 0));
  const readUnixMs = Math.max(Number(existing.readUnixMs || 0), Number(incoming.readUnixMs || 0));
  const deliveryFailedUnixMs = Math.max(Number(existing.deliveryFailedUnixMs || 0), Number(incoming.deliveryFailedUnixMs || 0));
  const merged = { ...existing, ...incoming, deliveredUnixMs, readUnixMs, deliveryFailedUnixMs };
  return {
    ...merged,
    body: incoming.body ?? existing.body,
    timestamp: incoming.timestamp || existing.timestamp,
    deliveredAt: deliveredUnixMs > 0 ? new Date(deliveredUnixMs).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : (incoming.deliveredAt || existing.deliveredAt || ''),
    readAt: readUnixMs > 0 ? new Date(readUnixMs).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : (incoming.readAt || existing.readAt || ''),
    deliveryFailedAt: deliveryFailedUnixMs > 0 ? new Date(deliveryFailedUnixMs).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : (incoming.deliveryFailedAt || existing.deliveryFailedAt || ''),
    sending: false,
    optimistic: false,
    error: deliveryFailedUnixMs > 0 ? false : (existing.error && !incoming.id ? existing.error : false),
  };
}

function patchMessageStatus(messages: any[], status: any) {
  const messageId = String(status.messageId || status.message_id || '');
  const readUnixMs = Number(status.readUnixMs ?? status.read_unix_ms ?? 0);
  const deliveredUnixMs = Number(status.deliveredUnixMs ?? status.delivered_unix_ms ?? 0);
  const deliveryFailedUnixMs = Number(status.deliveryFailedUnixMs ?? status.delivery_failed_unix_ms ?? 0);
  const deliveryError = String(status.deliveryError ?? status.delivery_error ?? '');
  for (const message of messages || []) {
    const matchesId = messageId && String(message.id || '') === messageId;
    const matchesReadWatermark = !messageId && readUnixMs > 0 && message.author === 'user' && Number(message.createdUnixMs || 0) <= readUnixMs;
    if (!matchesId && !matchesReadWatermark) continue;
    if (deliveredUnixMs > 0 && deliveredUnixMs > Number(message.deliveredUnixMs || 0)) {
      message.deliveredUnixMs = deliveredUnixMs;
      message.deliveredAt = new Date(deliveredUnixMs).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    }
    if (readUnixMs > 0 && readUnixMs > Number(message.readUnixMs || 0)) {
      message.readUnixMs = readUnixMs;
      message.readAt = new Date(readUnixMs).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    }
    if (deliveryFailedUnixMs > 0 && deliveryFailedUnixMs > Number(message.deliveryFailedUnixMs || 0)) {
      message.deliveryFailedUnixMs = deliveryFailedUnixMs;
      message.deliveryFailedAt = new Date(deliveryFailedUnixMs).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
      message.deliveryError = deliveryError || message.deliveryError || 'delivery failed';
    }
    message.sending = false;
    message.optimistic = false;
  }
}

function isRecentOptimisticMessage(message: any): boolean {
  if (!message) return false;
  const marker = Boolean(message.sending || message.optimistic || String(message.id || '').startsWith('local_'));
  if (!marker) return false;
  const at = Number(message.deliveredUnixMs || message.createdUnixMs || 0);
  return Boolean(message.sending) || !at || Date.now() - at < CHAT_OPTIMISTIC_GRACE_MS;
}

function mergeMessages(existingMessages: any[], incomingMessages: any[]) {
  const result = [...existingMessages];
  for (const incoming of incomingMessages) {
    const byId = result.findIndex((m: any) => m.id === incoming.id);
    if (byId >= 0) {
      result[byId] = mergeMessage(result[byId], incoming);
      continue;
    }
    const optimisticIndex = incoming.author === 'user'
      ? result.findIndex((m: any) => m.author === 'user' && m.body === incoming.body && (m.sending || m.optimistic || String(m.id).startsWith('local_')))
      : -1;
    if (optimisticIndex >= 0) {
      result[optimisticIndex] = mergeMessage(result[optimisticIndex], incoming);
    } else {
      result.push(incoming);
    }
  }
  return result;
}

function applyReceivedChatPage(state: any, payload: any) {
  const { agentId: payloadAgentId, messages, nextCursor, isAppend, markedRead } = payload || {};
  if (!payloadAgentId) return;
  if (!state.chats[payloadAgentId]) {
    state.chats[payloadAgentId] = [];
  }
  if (isAppend) {
    state.chats[payloadAgentId] = mergeMessages(messages || [], state.chats[payloadAgentId]);
  } else {
    const optimistic = state.chats[payloadAgentId].filter(isRecentOptimisticMessage);
    const unmatchedOptimistic = optimistic.filter((local: any) => !(messages || []).some((server: any) => server.id === local.id || (server.author === local.author && server.body === local.body)));
    state.chats[payloadAgentId] = [...(messages || []), ...unmatchedOptimistic];
  }
  state.chatsCursor[payloadAgentId] = Number(nextCursor || 0);
  state.chatsHasMore[payloadAgentId] = Number(nextCursor || 0) > 0;

  if (markedRead && state.conversationSummaryById?.[payloadAgentId]) {
    state.conversationSummaryById[payloadAgentId].unreadCount = 0;
  }
}

export const registerSession = createAsyncThunk('chat/registerSession', async (_, { getState }) => {
  const { session } = (getState() as any).chat;
  return daemonApi.registerUserClient(session);
});

// TODO(rtkq-migration owner=task-19f69e242e4): compatibility wrapper for non-hook call sites. Conversation summaries are owned by chatEndpoints.listConversationSummaries as the recurring cache authority.
export const refreshConversationSummaries = createAsyncThunk('chat/refreshConversationSummaries', async (_, { dispatch }) => {
  return await (dispatch as any)(chatEndpoints.endpoints.listConversationSummaries.initiate(undefined, { subscribe: false })).unwrap();
});

export const refreshAgents = createAsyncThunk('chat/refreshAgents', async (_, { dispatch }) => {
  return await (dispatch as any)(agentsApi.endpoints.listAgents.initiate(undefined, { subscribe: false, forceRefetch: true })).unwrap();
});

// TODO(rtkq-migration owner=task-19f69e242e4): compatibility wrapper for remaining direct-chat component callers. Live conversation caching/dedupe belongs to chatEndpoints.fetchDirectChat/fetchDirectChatPage.
export const fetchSelectedChat = createAsyncThunk(
  'chat/fetchSelectedChat',
  async (payload: { agentId?: string; limit?: number; cursor?: number } | string | undefined, { dispatch, getState }) => {
    const state = (getState() as any).chat;
    const { session, selectedAgentId } = state;

    let agentInstanceId = selectedAgentId;
    let limit = 50;
    let cursor = 0;

    if (typeof payload === 'string') {
      agentInstanceId = payload;
    } else if (payload && typeof payload === 'object') {
      agentInstanceId = payload.agentId || selectedAgentId;
      if (payload.limit !== undefined) limit = payload.limit;
      if (payload.cursor !== undefined) cursor = payload.cursor;
    }

    if (!agentInstanceId || !session.clientToken) return { agentId: agentInstanceId, messages: [], nextCursor: 0, isAppend: false, markedRead: false };

    const result = cursor > 0
      ? await (dispatch as any)(chatEndpoints.endpoints.fetchDirectChatPage.initiate({ agentInstanceId, cursor, limit }, { subscribe: false })).unwrap()
      : await (dispatch as any)(chatEndpoints.endpoints.fetchDirectChat.initiate({ agentInstanceId, limit }, { subscribe: false })).unwrap();

    return {
      agentId: agentInstanceId,
      messages: result.messages || [],
      nextCursor: result.nextCursor || 0,
      isAppend: cursor > 0,
      markedRead: cursor === 0,
    };
  },
  {
    condition: (payload, { getState }) => {
      const state = (getState() as any).chat;
      const agentId = getAgentIdFromPayload(payload, state.selectedAgentId);
      if (!agentId) return false;
      if (state.fetchingChatsByAgentId?.[agentId]) {
        return false;
      }
      const isSelected = agentId === state.selectedAgentId;
      const isCached = Boolean(state.chats?.[agentId]);
      const hasExplicitAgentId = typeof payload === 'string' || Boolean(payload && typeof payload === 'object' && payload.agentId);
      if (!hasExplicitAgentId && !isSelected && !isCached) {
        return false;
      }
    }
  }
);

export const sendMessageToSelectedAgent = createAsyncThunk(
  'chat/sendMessageToSelectedAgent',
  async (payload: { agentId?: string; body: string; tempId: string; interrupt?: boolean; artifactIds?: string[] }, { dispatch, getState }) => {
    const { selectedAgentId } = (getState() as any).chat;
    const agentInstanceId = payload.agentId || selectedAgentId;
    const res = await (dispatch as any)(chatEndpoints.endpoints.sendAgentMessage.initiate({
      agentInstanceId,
      body: payload.body,
      tempId: payload.tempId,
      interrupt: payload.interrupt,
      artifactIds: payload.artifactIds,
    })).unwrap();
    return { messageId: res.messageId, agentId: agentInstanceId };
  }
);

// TODO(rtkq-migration owner=task-19f69e242e4): compatibility wrapper for remaining guide-chat component callers. Live guide chat caching/dedupe belongs to chatEndpoints.fetchGuideChat/fetchGuideChatPage.
export const fetchGuideChat = createAsyncThunk('chat/fetchGuideChat', async (payload: { cursor?: number; limit?: number } | void | undefined, { dispatch, getState }) => {
  const { session } = (getState() as any).chat;
  const cursor = typeof payload === 'object' && payload?.cursor !== undefined ? payload.cursor : 0;
  const limit = typeof payload === 'object' && payload?.limit !== undefined ? payload.limit : 80;
  if (!session.clientToken) return { agentId: GUIDE_AGENT_ID, messages: [], nextCursor: 0, markedRead: false, isAppend: false };
  const result = cursor > 0
    ? await (dispatch as any)(chatEndpoints.endpoints.fetchGuideChatPage.initiate({ cursor, limit }, { subscribe: false })).unwrap()
    : await (dispatch as any)(chatEndpoints.endpoints.fetchGuideChat.initiate({ limit }, { subscribe: false })).unwrap();
  return { agentId: GUIDE_AGENT_ID, messages: result.messages || [], nextCursor: result.nextCursor || 0, markedRead: cursor === 0, isAppend: cursor > 0 };
});

export const sendGuideMessage = createAsyncThunk('chat/sendGuideMessage', async (payload: { body: string; tempId: string; interrupt?: boolean }, { dispatch }) => {
  const res = await (dispatch as any)(chatEndpoints.endpoints.sendGuideMessage.initiate({
    body: payload.body,
    tempId: payload.tempId,
    interrupt: payload.interrupt,
  })).unwrap();
  return { messageId: res.messageId };
});

function getAgentIdFromPayload(payload: any, selectedAgentId: string): string {
  if (typeof payload === 'string') return payload;
  if (payload && typeof payload === 'object') return payload.agentId || selectedAgentId;
  return selectedAgentId;
}

const odinDaemonUrl = typeof window !== 'undefined' ? (window as any).odinApi?.daemonUrl : undefined;
const initialDaemonUrl = normalizeDaemonUrl(odinDaemonUrl || getStoredValue('odin.daemonUrl', DEFAULT_DAEMON_URL)) || DEFAULT_DAEMON_URL;

const initialState = {
  daemonProfiles: loadDaemonProfiles(initialDaemonUrl),
  session: {
    daemonUrl: initialDaemonUrl,
    userId: getStoredValue('odin.userId', DEFAULT_USER_ID),
    userDisplayName: getStoredValue('odin.userDisplayName', ''),
    clientInstanceId: createClientInstanceId(),
    clientToken: getStoredValue('odin.clientToken', ''),
    connected: false,
    status: 'idle',
    wsStatus: 'idle',
    wsConnected: false,
    lastChatEvent: null,
    error: '',
  },
  selectedAgentId: '',
  // Daemon-authoritative conversation summaries keyed by agent_instance_id:
  // { title, lastMessageUnixMs, projectId, agentId, unreadCount }. Populated from
  // list_chats on explicit triggers only; the sidebar uses these for ordering +
  // titles instead of locally-loaded messages.
  conversationSummaryById: {} as Record<string, any>,
  chats: {},
  chatsCursor: {} as Record<string, number>,   // Track cursor per agent (identity)
  chatsHasMore: {} as Record<string, boolean>,  // Track if there are more messages per agent
  sending: false,
  guidePanelOpen: false,
  guideSending: false,
  testRuns: [] as any[],
  fetchingChatsByAgentId: {} as Record<string, boolean>,
  activeView: 'chat' as 'chat' | 'settings' | 'tasks' | 'memory' | 'memoryAudit' | 'projects' | 'agents' | 'startAgent',
};

const chatSlice = createSlice({
  name: 'chat',
  initialState,
  reducers: {
    selectAgent(state, action) {
      state.selectedAgentId = action.payload;
    },
    setView(state, action) {
      state.activeView = action.payload || 'chat';
    },
    openGuidePanel(state) {
      state.guidePanelOpen = true;
    },
    closeGuidePanel(state) {
      state.guidePanelOpen = false;
    },
    toggleGuidePanel(state) {
      state.guidePanelOpen = !state.guidePanelOpen;
    },
    clearUserClientState(state, action) {
      const userId = String(action.payload?.userId || '');
      state.daemonProfiles = [];
      state.session.userId = userId;
      state.session.userDisplayName = '';
      state.session.clientInstanceId = '';
      state.session.clientToken = '';
      state.session.connected = false;
      state.session.status = 'idle';
      state.session.wsStatus = 'idle';
      state.session.wsConnected = false;
      state.session.lastChatEvent = null;
      state.session.error = '';
      state.selectedAgentId = '';
      state.conversationSummaryById = {};
      state.chats = {};
      state.chatsCursor = {};
      state.chatsHasMore = {};
      state.sending = false;
      state.guidePanelOpen = false;
      state.guideSending = false;
      state.testRuns = [];
      state.fetchingChatsByAgentId = {};
      state.activeView = 'chat';
    },

    setDaemonUrl(state, action) {
      const daemonUrl = normalizeDaemonUrl(action.payload) || DEFAULT_DAEMON_URL;
      state.session.daemonUrl = daemonUrl;
      setStoredValue('odin.daemonUrl', daemonUrl);
    },
    addDaemonProfile(state, action) {
      const daemonUrl = normalizeDaemonUrl(action.payload?.daemonUrl || action.payload?.url || '');
      if (!daemonUrl) return;
      const profile = { label: String(action.payload?.label || daemonLabelForUrl(daemonUrl)), url: daemonUrl };
      state.daemonProfiles = normalizeDaemonProfiles([...state.daemonProfiles, profile], daemonUrl);
      storeDaemonProfiles(state.daemonProfiles);
    },
    renameDaemonProfile(state, action) {
      const daemonUrl = normalizeDaemonUrl(action.payload?.daemonUrl || action.payload?.url || '');
      const label = String(action.payload?.label || '').trim();
      if (!daemonUrl || !label) return;
      state.daemonProfiles = state.daemonProfiles.map((profile: any) => (
        normalizeDaemonUrl(profile?.url || '') === daemonUrl ? { ...profile, label } : profile
      ));
      state.daemonProfiles = normalizeDaemonProfiles(state.daemonProfiles, state.session.daemonUrl);
      storeDaemonProfiles(state.daemonProfiles);
    },
    removeDaemonProfile(state, action) {
      const daemonUrl = normalizeDaemonUrl(action.payload?.daemonUrl || action.payload?.url || action.payload || '');
      if (!daemonUrl) return;
      if (daemonUrl === state.session.daemonUrl) return; // never delete the active profile
      state.daemonProfiles = state.daemonProfiles.filter((profile: any) => normalizeDaemonUrl(profile?.url || '') !== daemonUrl);
      state.daemonProfiles = normalizeDaemonProfiles(state.daemonProfiles, state.session.daemonUrl);
      storeDaemonProfiles(state.daemonProfiles);
    },
    updateSessionConfig(state, action) {
      const daemonUrl = normalizeDaemonUrl(action.payload.daemonUrl) || DEFAULT_DAEMON_URL;
      const userId = action.payload.userId?.trim() || DEFAULT_USER_ID;
      const daemonChanged = daemonUrl !== state.session.daemonUrl;
      const userChanged = userId !== state.session.userId;
      state.session.daemonUrl = daemonUrl;
      state.session.userId = userId;
      state.session.connected = false;
      state.session.status = 'idle';
      state.session.wsConnected = false;
      state.session.wsStatus = 'idle';
      state.session.error = '';
      if (daemonChanged || userChanged) {
        state.session.clientInstanceId = newClientInstanceId();
        state.session.clientToken = '';
        state.session.lastChatEvent = null;
        state.chats = {};
        state.chatsCursor = {};
        state.chatsHasMore = {};
        state.fetchingChatsByAgentId = {};
        state.selectedAgentId = '';
        state.testRuns = [];
        setStoredValue('odin.clientInstanceId', state.session.clientInstanceId);
        setStoredValue('odin.clientToken', '');
        storeKnownAgents([]);
      }
      state.daemonProfiles = normalizeDaemonProfiles(state.daemonProfiles, daemonUrl);
      storeDaemonProfiles(state.daemonProfiles);
      setStoredValue('odin.daemonUrl', daemonUrl);
      setStoredValue('odin.userId', userId);
    },
    userWsConnecting(state) {
      state.session.wsStatus = 'connecting';
      state.session.wsConnected = false;
      if (state.session.error === 'User WebSocket connection error' || state.session.error === 'User WebSocket disconnected') {
        state.session.error = '';
      }
    },
    userWsConnected(state) {
      state.session.wsStatus = 'connected';
      state.session.wsConnected = true;
      if (state.session.error === 'User WebSocket connection error' || state.session.error === 'User WebSocket disconnected') {
        state.session.error = '';
      }
    },
    userWsDisconnected(state) {
      state.session.wsStatus = 'reconnecting';
      state.session.wsConnected = false;
    },
    userWsError(state, action) {
      state.session.wsStatus = 'error';
      state.session.wsConnected = false;
      state.session.error = action.payload || 'User WebSocket disconnected';
    },
    chatEventReceived(state, action) {
      state.session.lastChatEvent = action.payload;
    },
    testStartReceived(state, action) {
      const run = action.payload;
      const idx = state.testRuns.findIndex((r: any) => r.testRunId === run.test_run_id);
      const mapped = {
        testRunId: run.test_run_id,
        provider: run.provider,
        model: run.model,
        resolvedModel: run.resolved_model,
        status: 'starting',
        startedUnixMs: run.started_unix_ms,
      };
      if (idx >= 0) state.testRuns[idx] = { ...state.testRuns[idx], ...mapped };
      else state.testRuns.unshift(mapped);
    },
    testDoneReceived(state, action) {
      const run = action.payload;
      const idx = state.testRuns.findIndex((r: any) => r.testRunId === run.test_run_id);
      const update = {
        testRunId: run.test_run_id,
        provider: run.provider,
        model: run.model,
        resolvedModel: run.resolved_model,
        status: run.status,
        reason: run.reason,
        elapsedMs: run.elapsed_ms,
        paneTail: run.pane_tail,
        completedUnixMs: run.completed_unix_ms,
      };
      if (idx >= 0) state.testRuns[idx] = { ...state.testRuns[idx], ...update };
      else state.testRuns.unshift(update);
    },
    setTestRuns(state, action) {
      state.testRuns = (action.payload ?? []).map((r: any) => ({
        testRunId: r.test_run_id,
        provider: r.provider,
        model: r.model,
        resolvedModel: r.resolved_model,
        status: r.status,
        reason: r.reason,
        elapsedMs: r.elapsed_ms,
        paneTail: r.pane_tail,
        startedUnixMs: r.started_unix_ms,
        completedUnixMs: r.completed_unix_ms,
      }));
    },
    appendMessage(state, action) {
      const { agentId, message } = action.payload;
      if (!state.chats[agentId]) {
        state.chats[agentId] = [];
      }
      state.chats[agentId] = mergeMessages(state.chats[agentId], [mapMessage(message)]);
    },
    patchChatMessageStatus(state, action) {
      const agentId = action.payload?.agentId || action.payload?.agent_instance_id || '';
      if (!agentId || !state.chats[agentId]) return;
      patchMessageStatus(state.chats[agentId], action.payload || {});
    },
    receiveChatPage(state, action) {
      applyReceivedChatPage(state, action.payload);
    },
  },
  extraReducers: (builder) => {
    builder
      .addCase(registerSession.pending, (state) => {
        state.session.status = 'connecting';
        state.session.error = '';
      })
      .addCase(registerSession.fulfilled, (state, action) => {
        state.session.status = 'connected';
        state.session.connected = true;
        state.session.wsStatus = 'idle';
        state.session.userId = action.payload.user_id;
        state.session.clientInstanceId = action.payload.client_instance_id;
        state.session.clientToken = action.payload.client_token;
        setStoredValue('odin.userId', action.payload.user_id);
        setStoredValue('odin.clientInstanceId', action.payload.client_instance_id);
        setStoredValue('odin.clientToken', action.payload.client_token);
      })
      .addCase(registerSession.rejected, (state, action) => {
        state.session.status = 'error';
        state.session.connected = false;
        state.session.wsStatus = 'error';
        state.session.error = action.error.message || 'Failed to register user client';
      })
      .addCase(refreshConversationSummaries.fulfilled, (state: any, action) => {
        state.conversationSummaryById = action.payload || {};
      })
      .addCase(refreshAgents.fulfilled, (state, action) => {
        const agents = action.payload?.agents || [];
        if (!state.selectedAgentId || !agents.some((agent: any) => agent.id === state.selectedAgentId)) {
          state.selectedAgentId = agents[0]?.id ?? '';
        }
      })
      .addCase(refreshAgents.rejected, (state, action) => {
        state.session.error = action.error.message || 'Failed to load agents';
      })
      .addCase(fetchSelectedChat.pending, (state: any, action) => {
        const agentId = getAgentIdFromPayload(action.meta.arg, state.selectedAgentId);
        if (agentId) {
          state.fetchingChatsByAgentId[agentId] = true;
        }
      })
      .addCase(fetchSelectedChat.fulfilled, (state: any, action) => {
        const agentId = getAgentIdFromPayload(action.meta.arg, state.selectedAgentId);
        if (agentId) {
          state.fetchingChatsByAgentId[agentId] = false;
        }
        applyReceivedChatPage(state, action.payload);
      })
      .addCase(fetchSelectedChat.rejected, (state: any, action) => {
        const agentId = getAgentIdFromPayload(action.meta.arg, state.selectedAgentId);
        if (agentId) {
          state.fetchingChatsByAgentId[agentId] = false;
        }
        state.session.error = action.error.message || 'Failed to fetch chat';
      })
      .addCase(fetchGuideChat.pending, (state: any) => {
        state.fetchingChatsByAgentId[GUIDE_AGENT_ID] = true;
      })
      .addCase(fetchGuideChat.fulfilled, (state: any, action) => {
        state.fetchingChatsByAgentId[GUIDE_AGENT_ID] = false;
        applyReceivedChatPage(state, action.payload);
      })
      .addCase(fetchGuideChat.rejected, (state: any, action) => {
        state.fetchingChatsByAgentId[GUIDE_AGENT_ID] = false;
        state.session.error = action.error.message || 'Failed to fetch guide chat';
      })
      .addCase(sendGuideMessage.pending, (state: any, action) => {
        state.guideSending = true;
        state.session.error = '';
        const { body, tempId } = action.meta.arg;
        if (!state.chats[GUIDE_AGENT_ID]) state.chats[GUIDE_AGENT_ID] = [];
        state.chats[GUIDE_AGENT_ID].push({
          id: tempId,
          author: 'user',
          body,
          timestamp: new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }),
          sending: true,
          readUnixMs: 0,
          deliveredUnixMs: 0,
          createdUnixMs: Date.now(),
          optimistic: true,
        });
      })
      .addCase(sendGuideMessage.fulfilled, (state: any, action) => {
        state.guideSending = false;
        const { tempId } = action.meta.arg;
        const { messageId } = action.payload;
        const msg = (state.chats[GUIDE_AGENT_ID] || []).find((m: any) => m.id === tempId);
        if (msg) {
          msg.id = messageId;
          msg.sending = false;
          msg.deliveredUnixMs = Date.now();
          msg.optimistic = true;
        }
      })
      .addCase(sendGuideMessage.rejected, (state: any, action) => {
        state.guideSending = false;
        const { tempId } = action.meta.arg;
        const msg = (state.chats[GUIDE_AGENT_ID] || []).find((m: any) => m.id === tempId);
        if (msg) {
          msg.sending = false;
          msg.error = true;
        }
        state.session.error = action.error.message || 'Failed to send guide message';
      })
      .addCase(sendMessageToSelectedAgent.pending, (state: any, action) => {
        state.sending = true;
        state.session.error = '';
        const { body, tempId, agentId: explicitAgentId, artifactIds } = action.meta.arg;
        const agentId = explicitAgentId || state.selectedAgentId;
        if (agentId && tempId) {
          if (!state.chats[agentId]) {
            state.chats[agentId] = [];
          }
          state.chats[agentId].push({
            id: tempId,
            author: 'user',
            body,
            timestamp: new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }),
            sending: true,
            readUnixMs: 0,
            deliveredUnixMs: 0,
            createdUnixMs: Date.now(),
            optimistic: true,
            artifactIds,
          });
        }
      })
      .addCase(sendMessageToSelectedAgent.fulfilled, (state: any, action) => {
        state.sending = false;
        const { tempId, agentId: explicitAgentId } = action.meta.arg;
        const agentId = action.payload.agentId || explicitAgentId || state.selectedAgentId;
        const { messageId } = action.payload;
        if (agentId && tempId && state.chats[agentId]) {
          const msg = state.chats[agentId].find((m: any) => m.id === tempId);
          if (msg) {
            msg.id = messageId;
            msg.sending = false;
            msg.deliveredUnixMs = Date.now();
            msg.optimistic = true;
          }
        }
      })
      .addCase(sendMessageToSelectedAgent.rejected, (state: any, action) => {
        state.sending = false;
        const { tempId, agentId: explicitAgentId } = action.meta.arg;
        const agentId = explicitAgentId || state.selectedAgentId;
        if (agentId && tempId && state.chats[agentId]) {
          const msg = state.chats[agentId].find((m: any) => m.id === tempId);
          if (msg) {
            msg.sending = false;
            msg.error = true;
          }
        }
        state.session.error = action.error.message || 'Failed to send message';
      });
  },
});

export const { selectAgent, setView, setDaemonUrl, addDaemonProfile, renameDaemonProfile, removeDaemonProfile, updateSessionConfig, clearUserClientState, userWsConnecting, userWsConnected, userWsDisconnected, userWsError, chatEventReceived, testStartReceived, testDoneReceived, setTestRuns, appendMessage, patchChatMessageStatus, receiveChatPage, openGuidePanel, closeGuidePanel, toggleGuidePanel } = chatSlice.actions;
export default chatSlice.reducer;
