import { noteLocalMessageSent, conversationOptionsRevision, expireConversationOptions } from '../conversationMessageEvents';
import * as daemonApi from '../daemonApi';
import { apiUrl, cookieJsonFetch, cookieMutation, customQueryError, errorFromResponse } from '../cookieFetch';
import { heimdallApi, withSessionQuery } from '../heimdallApi';
import { isVaultArmored, encryptVaultText, getActiveVaultKey } from '../../utils/vaultContent';
import { decryptConversationRecord } from '../../utils/vaultChats';
import type { QuestionSubmission } from '../../components/chat/multiQuestion';

const GUIDE_AGENT_ID = 'guide@heimdall';

type ChatMessage = {
  id: string;
  author: 'user' | 'agent';
  body: string;
  timestamp: string;
  createdUnixMs: number;
  deliveredAt: string;
  deliveredUnixMs: number;
  readAt: string;
  readUnixMs: number;
  deliveryFailedAt: string;
  deliveryFailedUnixMs: number;
  deliveryError: string;
  interrupt: boolean;
  artifactIds?: string[];
  messageType?: string;
  messageStatus?: string;
  metadata?: any;
  sending?: boolean;
  optimistic?: boolean;
  error?: boolean;
};

function timeLabel(unixMs: number): string {
  return unixMs > 0 ? new Date(unixMs).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : '';
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

function parseMessageMetadata(message: any): any {
  const raw = message?.metadata ?? message?.metadata_json ?? message?.metadataJson;
  if (!raw) return {};
  if (typeof raw === 'object') return raw;
  try { return JSON.parse(String(raw)); } catch (_err) { return {}; }
}

function mapMessage(message: any): ChatMessage {
  const createdUnixMs = Number(message.created_unix_ms ?? message.createdUnixMs ?? 0) || (message.created_at || message.createdAt ? Date.parse(message.created_at || message.createdAt) : 0) || 0;
  const deliveredUnixMs = Number(message.delivered_unix_ms ?? message.deliveredUnixMs ?? 0) || (message.delivered_at || message.deliveredAt ? Date.parse(message.delivered_at || message.deliveredAt) : 0) || 0;
  const readUnixMs = Number(message.read_unix_ms ?? message.readUnixMs ?? 0) || (message.read_at || message.readAt ? Date.parse(message.read_at || message.readAt) : 0) || 0;
  const deliveryFailedUnixMs = Number(message.delivery_failed_unix_ms ?? message.deliveryFailedUnixMs ?? 0) || (message.delivery_failed_at || message.deliveryFailedAt ? Date.parse(message.delivery_failed_at || message.deliveryFailedAt) : 0) || 0;
  return {
    id: String(message.message_id ?? message.id ?? ''),
    author: message.direction === 'user_to_agent' || message.author === 'user' ? 'user' : 'agent',
    body: String(message.body || ''),
    timestamp: timeLabel(createdUnixMs) || String(message.timestamp || ''),
    createdUnixMs,
    deliveredAt: timeLabel(deliveredUnixMs) || String(message.deliveredAt || ''),
    deliveredUnixMs,
    readAt: timeLabel(readUnixMs) || String(message.readAt || ''),
    readUnixMs,
    deliveryFailedAt: timeLabel(deliveryFailedUnixMs) || String(message.deliveryFailedAt || ''),
    deliveryFailedUnixMs,
    deliveryError: String(message.delivery_error ?? message.deliveryError ?? ''),
    interrupt: Boolean(message.interrupt),
    artifactIds: extractMessageArtifactIds(message),
    messageType: String(message.message_type ?? message.messageType ?? 'text'),
    messageStatus: String(message.message_status ?? message.messageStatus ?? 'complete'),
    metadata: parseMessageMetadata(message),
    sending: Boolean(message.sending),
    optimistic: Boolean(message.optimistic),
    error: Boolean(message.error),
  };
}

function normalizeChatPage(agentInstanceId: string, data: any, isAppend = false) {
  return {
    agentId: agentInstanceId,
    messages: (data?.messages || []).map(mapMessage).reverse(),
    nextCursor: Number(data?.next_cursor || data?.nextCursor || 0),
    hasMore: Number(data?.next_cursor || data?.nextCursor || 0) > 0,
    isAppend,
  };
}

function normalizeConversationSummaries(data: any) {
  const byId: Record<string, any> = {};
  for (const row of data?.chats || []) {
    const id = String(row.agent_instance_id || row.agentInstanceId || '');
    if (!id) continue;
    byId[id] = {
      agentInstanceId: id,
      agentId: String(row.agent_id || row.agentId || ''),
      projectId: String(row.project_id || row.projectId || ''),
      title: String(row.title || ''),
      lastMessageUnixMs: Number(row.last_message_unix_ms || row.lastMessageUnixMs || 0),
      unreadCount: Number(row.unread_count || row.unreadCount || 0),
    };
  }
  return byId;
}

function optimisticMessage(id: string, body: string, artifactIds?: string[]): ChatMessage {
  const now = Date.now();
  return {
    id,
    author: 'user',
    body,
    timestamp: timeLabel(now),
    createdUnixMs: now,
    deliveredAt: '',
    deliveredUnixMs: 0,
    readAt: '',
    readUnixMs: 0,
    deliveryFailedAt: '',
    deliveryFailedUnixMs: 0,
    deliveryError: '',
    interrupt: false,
    artifactIds,
    sending: true,
    optimistic: true,
    error: false,
  };
}

function upsertMessage(messages: ChatMessage[], next: ChatMessage) {
  let index = messages.findIndex((message) => message.id === next.id);
  if (index < 0 && next.author === 'user') {
    index = messages.findIndex((message) => message.author === 'user' && message.body === next.body && (message.sending || message.optimistic || String(message.id || '').startsWith('local_')));
  }
  if (index >= 0) {
    const current = messages[index];
    messages[index] = {
      ...current,
      ...next,
      deliveredUnixMs: Math.max(Number(current.deliveredUnixMs || 0), Number(next.deliveredUnixMs || 0)),
      readUnixMs: Math.max(Number(current.readUnixMs || 0), Number(next.readUnixMs || 0)),
      deliveryFailedUnixMs: Math.max(Number(current.deliveryFailedUnixMs || 0), Number(next.deliveryFailedUnixMs || 0)),
      sending: false,
      optimistic: false,
    };
    return;
  }
  messages.push(next);
}

function mergeOlderMessages(existing: ChatMessage[], older: ChatMessage[]) {
  const byId = new Map<string, ChatMessage>();
  for (const message of [...older, ...existing]) {
    byId.set(message.id || `${message.createdUnixMs}-${message.body}`, message);
  }
  return Array.from(byId.values()).sort((left, right) => Number(left.createdUnixMs || 0) - Number(right.createdUnixMs || 0));
}

function patchConversationSummary(draft: any, agentInstanceId: string, body: string) {
  if (!draft) return;
  const summaries = draft.summaries || draft;
  const now = Date.now();
  const existing = summaries[agentInstanceId] || { agentInstanceId, agentId: '', projectId: '', title: '' };
  summaries[agentInstanceId] = {
    ...existing,
    lastMessageUnixMs: now,
    unreadCount: 0,
  };
  if (!existing.title && body.trim()) {
    summaries[agentInstanceId].title = body.trim().slice(0, 80);
  }
}

function hydrateChatPage(dispatch: any, payload: { agentId: string; messages: ChatMessage[]; nextCursor: number; isAppend: boolean; markedRead: boolean }) {
  dispatch({ type: 'chat/receiveChatPage', payload });
}

function appendChatMessage(dispatch: any, agentId: string, rawMessage: any) {
  if (!agentId || !rawMessage) return;
  dispatch({ type: 'chat/appendMessage', payload: { agentId, message: rawMessage } });
}

function guideChatArgs() {
  return { limit: 80 };
}

export const chatEndpoints = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    createLaunchConversation: build.mutation<any, { agentId: string; projectId?: string; bridgeId?: string; provider?: string; providerProfile?: string; model?: string; body: string; artifactIds?: string[] }>({
      queryFn: async ({ agentId, projectId, bridgeId, provider, providerProfile, model, body, artifactIds = [] }, api) => {
        try {
          const state: any = api.getState();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const activeKey = getActiveVaultKey();
          let encBody = body;
          if (isUnlocked && activeKey && encBody && !isVaultArmored(encBody)) {
            encBody = await encryptVaultText(encBody, activeKey);
          }
          const payload: any = { agent_id: agentId, initial_message: { body: encBody }, artifact_ids: artifactIds };
          if (projectId) payload.project_id = projectId;
          if (bridgeId) payload.bridge_id = bridgeId;
          if (provider) payload.provider = provider;
          if (providerProfile) payload.provider_profile = providerProfile;
          if (model) payload.model = model;
          const conversation = await cookieMutation('/chats', 'POST', payload);
          let instance: any = {};
          if (conversation?.agent_instance_id) {
            try { instance = await cookieJsonFetch(`/agent-instances/${encodeURIComponent(String(conversation.agent_instance_id))}`); } catch (_err) { instance = {}; }
          }
          return { data: { conversation, instance } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_result, _error, { agentId }) => [
        { type: 'SidebarConversations' as const, id: 'ALL' },
        { type: 'ConversationSummaries' as const, id: 'LIST' },
        // Not Agents:LIST: starting a conversation launches an instance but changes no
        // agent identity, and LIST is provided only by listAgentIdentities.
        { type: 'AgentInstances' as const, id: agentId },
      ],
    }),
    // Cookie-auth conversation thread endpoints (hub-native, /api/v1/chats/{id}).
    // Unlike fetchDirectChat/sendAgentMessage (legacy clientToken path), these use
    // the cookie session the rewrite shell runs on, keyed by conversation_id.
    // Resolve one conversation. Prefer the O(1) by-instance endpoint
    // (GET /chats/by-instance/{agent_instance_id}) so a conversation page's 10s
    // poll no longer fetches the entire /chats list just to .find() one row.
    // agentInstanceId is read from the URL (the page syncs it into the query
    // string); when it is unavailable (deep link by conversation id only) we fall
    // back to the list scan for correctness.
    fetchConversation: build.query<any, { conversationId: string; agentInstanceId?: string }>({
      queryFn: async ({ conversationId, agentInstanceId }, api) => {
        if (!conversationId && !agentInstanceId) return { data: { conversation: null } };
        try {
          let conversation: any = null;
          const instanceId = String(agentInstanceId || '').trim();
          if (instanceId) {
            const res = await cookieJsonFetch(`/chats/by-instance/${encodeURIComponent(instanceId)}`);
            conversation = res?.data ?? res ?? null;
          }
          if (!conversation || !String(conversation?.conversation_id || conversation?.conversationId || '')) {
            const list = await cookieJsonFetch('/chats');
            const rows = Array.isArray(list) ? list : (list?.data || list?.conversations || []);
            conversation = rows.find((c: any) => String(c?.conversation_id || c?.conversationId) === conversationId) || null;
          }
          const state: any = api?.getState?.();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const activeKey = getActiveVaultKey();
          if (isUnlocked && activeKey && conversation) {
            conversation = await decryptConversationRecord(conversation, activeKey);
          }
          return { data: { conversation } };
        } catch (error: any) {
          return { error: customQueryError(error) as any };
        }
      },
      // A lookup by instance passes conversationId '' and only learns the real id from
      // the result. Tag the resolved id too, or invalidations keyed on it (rename,
      // reconfiguration settling) never reach this entry.
      providesTags: (result, _e, { conversationId }) => {
        const resolvedId = String(result?.conversation?.conversation_id || result?.conversation?.conversationId || '');
        return [...new Set([conversationId, resolvedId].filter(Boolean))]
          .map((id) => ({ type: 'ConversationSummaries' as const, id }));
      },
      // Cache conversation metadata across switches so the header/runtime chip
      // render instantly on remount; refetchOnMountOrArgChange still refreshes it.
      keepUnusedDataFor: 300,
    }),
    fetchConversationMessages: build.query<any, { conversationId: string; limit?: number; cursor?: string }>({
      queryFn: async ({ conversationId, limit = 30, cursor = '' }) => {
        if (!conversationId) return { data: { messages: [], nextCursor: '', hasMore: false } };
        try {
          // Reconnect/refresh can reveal messages whose WS event was missed. A new
          // canonical read also retires hints retained in previously loaded pages.
          if (!cursor) expireConversationOptions(conversationId);
          const optionsRevision = conversationOptionsRevision(conversationId);
          const params = new URLSearchParams({ limit: String(limit) });
          if (cursor) params.set('cursor', cursor);
          const res = await fetch(apiUrl(`/chats/${encodeURIComponent(conversationId)}/messages?${params.toString()}`), { credentials: 'include' });
          // ApiError keeps the HTTP status and hub code, so a 404/401 is terminal below.
          if (!res.ok) throw await errorFromResponse(res);
          const body = await res.json();
          const rows = Array.isArray(body) ? body : (Array.isArray(body?.data) ? body.data : (body?.messages || []));
          const page = body?.page || {};
          const nextCursor = String(page.next_cursor ?? page.nextCursor ?? body?.next_cursor ?? body?.nextCursor ?? '');
          const hasMore = Boolean(page.has_more ?? page.hasMore ?? body?.has_more ?? body?.hasMore ?? false);
          return { data: { messages: rows.map((row: any) => ({ ...row, optionsRevision })), nextCursor, hasMore } };
        } catch (error: any) {
          return { error: customQueryError(error) as any };
        }
      },
      // Only the newest page (no cursor) carries Chat:<conversation>, which a new
      // message invalidates. Older pages never gain messages; their read receipts are
      // patched from messages_read, so they must not refetch on every new message.
      providesTags: (_r, _e, { conversationId, cursor }) => [
        { type: 'Chat' as const, id: cursor ? `${conversationId}@${cursor}` : conversationId },
      ],
      // Keep recently-viewed threads cached longer than the 30s global default so
      // switching back to a conversation renders instantly (the page remounts per
      // conversationId). WS/`Chat` tag invalidation still refreshes on new messages.
      keepUnusedDataFor: 300,
    }),
    updateConversationTitle: build.mutation<any, { conversationId: string; title: string }>({
      queryFn: async ({ conversationId, title }, api) => {
        if (!conversationId || !title.trim()) return { error: { status: 'CUSTOM_ERROR', error: 'Missing conversation or title' } as any };
        try {
          const state: any = api.getState();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const activeKey = getActiveVaultKey();
          let encTitle = title.trim();
          if (isUnlocked && activeKey && encTitle && !isVaultArmored(encTitle)) {
            encTitle = await encryptVaultText(encTitle, activeKey);
          }
          const data = await cookieMutation(`/chats/${encodeURIComponent(conversationId)}`, 'PATCH', { title: encTitle });
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_r, _e, { conversationId }) => [
        { type: 'ConversationSummaries' as const, id: conversationId },
        { type: 'SidebarConversations' as const, id: 'ALL' },
      ],
    }),
    requestPaneCapture: build.mutation<any, { conversationId: string; width?: number; settleMs?: number; lineLimit?: number }>({
      queryFn: async ({ conversationId, width = 80, settleMs = 3000, lineLimit = 120 }) => {
        if (!conversationId) return { error: { status: 'CUSTOM_ERROR', error: 'Missing conversation' } as any };
        try {
          const data = await cookieMutation(`/chats/${encodeURIComponent(conversationId)}/pane-capture`, 'POST', { width, settle_ms: settleMs, line_limit: lineLimit });
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_r, _e, { conversationId }) => [
        { type: 'Chat' as const, id: conversationId },
        { type: 'ConversationSummaries' as const, id: conversationId },
        { type: 'SidebarConversations' as const, id: 'ALL' },
      ],
    }),
    sendConversationMessage: build.mutation<any, { conversationId: string; body: string; artifactIds?: string[]; quoteTarget?: { chainId: string; coordinatorAgentInstanceId: string; epoch: number } }>({
      queryFn: async ({ conversationId, body, artifactIds = [], quoteTarget }, api) => {
        if (!conversationId || !body.trim()) return { error: { status: 'CUSTOM_ERROR', error: 'Missing conversation or body' } as any };
        try {
          const state: any = api.getState();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const activeKey = getActiveVaultKey();
          if (quoteTarget && (!isUnlocked || !activeKey || state.composerContext?.epoch !== quoteTarget.epoch)) throw new Error('Unlock Vault and add the quote again.');
          let encBody = body;
          if (isUnlocked && activeKey && encBody && !isVaultArmored(encBody)) {
            encBody = await encryptVaultText(encBody, activeKey);
          }
          if (quoteTarget) {
            const target = await cookieJsonFetch('/task-chains/' + encodeURIComponent(quoteTarget.chainId) + '/conversation');
            if (String(target?.conversation_id || target?.conversationId || '') !== conversationId ||
                String(target?.coordinator_agent_instance_id || target?.coordinatorAgentInstanceId || '') !== quoteTarget.coordinatorAgentInstanceId) {
              throw new Error('The coordinator changed. Refresh its composer and retry.');
            }
            const latest: any = api.getState();
            if (!latest.vault?.isUnlocked || getActiveVaultKey() !== activeKey || latest.composerContext?.epoch !== quoteTarget.epoch) throw new Error('Vault state changed. Add the quote again.');
          }
          const data = await cookieMutation(`/chats/${encodeURIComponent(conversationId)}/messages`, 'POST', { body: encBody, artifact_ids: artifactIds });
          expireConversationOptions(conversationId);
          // invalidatesTags below refreshes this tab; skip the hub's echo of the same id.
          noteLocalMessageSent(String(data?.message_id || data?.message?.message_id || data?.data?.message_id || ''));
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_r, _e, { conversationId }) => [
        { type: 'Chat' as const, id: conversationId },
        { type: 'ConversationSummaries' as const, id: conversationId },
        { type: 'SidebarConversations' as const, id: 'ALL' },
      ],
    }),
    answerConversationQuestions: build.mutation<any, { conversationId: string; sourceMessageId: string; submission: QuestionSubmission }>({
      queryFn: async ({ conversationId, sourceMessageId, submission }, api) => {
        try {
          const activeKey = getActiveVaultKey();
          if (!(api.getState() as any)?.vault?.isUnlocked || !activeKey) throw new Error('Unlock Vault to send answers.');
          const payload = {
            ...submission,
            body: await encryptVaultText(submission.body, activeKey),
            answers: await Promise.all(submission.answers.map(async (answer) => ({
              ...answer,
              ...(answer.custom_text !== undefined ? { custom_text: await encryptVaultText(answer.custom_text, activeKey) } : {}),
            }))),
          };
          const data = await cookieMutation(`/chats/${encodeURIComponent(conversationId)}/messages/${encodeURIComponent(sourceMessageId)}/answers`, 'POST', payload);
          expireConversationOptions(conversationId);
          noteLocalMessageSent(String(data?.message?.message_id || ''));
          return { data };
        } catch (error) { return { error: customQueryError(error) as any }; }
      },
      invalidatesTags: (_r, _e, { conversationId }) => [
        { type: 'Chat' as const, id: conversationId },
        { type: 'ConversationSummaries' as const, id: conversationId },
        { type: 'SidebarConversations' as const, id: 'ALL' },
      ],
    }),
    markConversationRead: build.mutation<any, { conversationId: string }>({
      queryFn: async ({ conversationId }) => {
        if (!conversationId) return { data: {} };
        try {
          const data = await cookieMutation(`/chats/${encodeURIComponent(conversationId)}/read`, 'POST');
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      invalidatesTags: (_r, _e, { conversationId }) => [
        { type: 'ConversationSummaries' as const, id: conversationId },
        { type: 'SidebarConversations' as const, id: 'ALL' },
      ],
    }),
    listConversationSummaries: build.query<any, { limit?: number; cursor?: string } | void>({
      queryFn: withSessionQuery(async (arg, { session }) => {
        if (!session?.clientToken) return { summaries: {}, nextCursor: '', hasMore: false };
        const args = (arg && typeof arg === 'object') ? arg : {};
        const limit = args.limit ?? 10000;
        const cursor = args.cursor ?? '';
        const data = await daemonApi.listConversations({
          daemonUrl: session.daemonUrl,
          clientInstanceId: session.clientInstanceId,
          clientToken: session.clientToken,
          limit,
          cursor,
        });
        const summaries = normalizeConversationSummaries(data);
        return {
          summaries,
          nextCursor: data.next_cursor || '',
          hasMore: Boolean(data.has_more),
        };
      }),
      providesTags: (result, _error, arg) => [
        { type: 'ConversationSummaries' as const, id: JSON.stringify(arg || {}) },
        ...Object.keys(result?.summaries || {}).map((id) => ({ type: 'Chat' as const, id })),
      ],
    }),
    fetchConversationSummariesPage: build.query<any, { limit: number; cursor: string }>({
      queryFn: withSessionQuery(async ({ limit, cursor }, { session }) => {
        if (!session?.clientToken) return { summaries: {}, nextCursor: '', hasMore: false };
        const data = await daemonApi.listConversations({
          daemonUrl: session.daemonUrl,
          clientInstanceId: session.clientInstanceId,
          clientToken: session.clientToken,
          limit,
          cursor,
        });
        const summaries = normalizeConversationSummaries(data);
        return {
          summaries,
          nextCursor: data.next_cursor || '',
          hasMore: Boolean(data.has_more),
        };
      }),
      async onQueryStarted(arg, { dispatch, queryFulfilled }) {
        try {
          const { data } = await queryFulfilled;
          const baseArgs = undefined;
          dispatch(
            chatEndpoints.util.updateQueryData('listConversationSummaries', baseArgs, (draft: any) => {
              if (!draft) return;
              draft.summaries = { ...(draft.summaries || {}), ...data.summaries };
              draft.nextCursor = data.nextCursor;
              draft.hasMore = data.hasMore;
            })
          );
        } catch (_error) {
          // noop
        }
      },
    }),
    fetchDirectChat: build.query<any, { agentInstanceId: string; limit?: number }>({
      queryFn: withSessionQuery(async ({ agentInstanceId, limit = 50 }, { session, state }) => {
        if (!session?.clientToken || !agentInstanceId) return normalizeChatPage(agentInstanceId, null, false);
        const selectedAgentId = state?.chat?.selectedAgentId || '';
        if (selectedAgentId === agentInstanceId) {
          await daemonApi.markChatRead({
            daemonUrl: session.daemonUrl,
            clientInstanceId: session.clientInstanceId,
            clientToken: session.clientToken,
            agentInstanceId,
          }).catch(() => undefined);
        }
        const data = await daemonApi.fetchChat({
          daemonUrl: session.daemonUrl,
          clientToken: session.clientToken,
          agentInstanceId,
          limit,
          cursor: 0,
        });
        return normalizeChatPage(agentInstanceId, data, false);
      }),
      providesTags: (_result, _error, { agentInstanceId }) => [{ type: 'Chat', id: agentInstanceId }],
      async onQueryStarted({ agentInstanceId }, { dispatch, queryFulfilled }) {
        try {
          const { data } = await queryFulfilled;
          hydrateChatPage(dispatch, {
            agentId: agentInstanceId,
            messages: data?.messages || [],
            nextCursor: Number(data?.nextCursor || 0),
            isAppend: false,
            markedRead: true,
          });
          dispatch(chatEndpoints.util.updateQueryData('listConversationSummaries', undefined, (draft: any) => {
            const summaries = draft?.summaries || draft;
            if (summaries?.[agentInstanceId]) summaries[agentInstanceId].unreadCount = 0;
          }));
        } catch (_error) {
          // noop
        }
      },
    }),
    fetchDirectChatPage: build.query<any, { agentInstanceId: string; cursor: number; limit?: number }>({
      queryFn: withSessionQuery(async ({ agentInstanceId, cursor, limit = 50 }, { session }) => {
        if (!session?.clientToken || !agentInstanceId) return normalizeChatPage(agentInstanceId, null, true);
        const data = await daemonApi.fetchChat({
          daemonUrl: session.daemonUrl,
          clientToken: session.clientToken,
          agentInstanceId,
          limit,
          cursor,
        });
        return normalizeChatPage(agentInstanceId, data, true);
      }),
      async onQueryStarted({ agentInstanceId, limit = 50 }, { dispatch, queryFulfilled }) {
        try {
          const { data } = await queryFulfilled;
          hydrateChatPage(dispatch, {
            agentId: agentInstanceId,
            messages: data?.messages || [],
            nextCursor: Number(data?.nextCursor || 0),
            isAppend: true,
            markedRead: false,
          });
          dispatch(chatEndpoints.util.updateQueryData('fetchDirectChat', { agentInstanceId, limit }, (draft: any) => {
            if (!draft) return;
            draft.messages = mergeOlderMessages(draft.messages || [], data?.messages || []);
            draft.nextCursor = Number(data?.nextCursor || 0);
            draft.hasMore = Boolean(data?.hasMore);
          }));
        } catch (_error) {
          // noop
        }
      },
    }),
    fetchGuideChat: build.query<any, { limit?: number } | void>({
      queryFn: withSessionQuery(async (arg, { session }) => {
        const limit = typeof arg === 'object' && arg?.limit !== undefined ? arg.limit : 80;
        if (!session?.clientToken) return normalizeChatPage(GUIDE_AGENT_ID, null, false);
        await daemonApi.markChatRead({
          daemonUrl: session.daemonUrl,
          clientInstanceId: session.clientInstanceId,
          clientToken: session.clientToken,
          agentInstanceId: GUIDE_AGENT_ID,
        }).catch(() => undefined);
        const data = await daemonApi.fetchChat({
          daemonUrl: session.daemonUrl,
          clientToken: session.clientToken,
          agentInstanceId: GUIDE_AGENT_ID,
          limit,
          cursor: 0,
        });
        return normalizeChatPage(GUIDE_AGENT_ID, data, false);
      }),
      providesTags: [{ type: 'GuideChat', id: GUIDE_AGENT_ID }],
      async onQueryStarted(_arg, { dispatch, queryFulfilled }) {
        try {
          const { data } = await queryFulfilled;
          hydrateChatPage(dispatch, {
            agentId: GUIDE_AGENT_ID,
            messages: data?.messages || [],
            nextCursor: Number(data?.nextCursor || 0),
            isAppend: false,
            markedRead: true,
          });
          dispatch(chatEndpoints.util.updateQueryData('listConversationSummaries', undefined, (draft: any) => {
            const summaries = draft?.summaries || draft;
            if (summaries?.[GUIDE_AGENT_ID]) summaries[GUIDE_AGENT_ID].unreadCount = 0;
          }));
        } catch (_error) {
          // noop
        }
      },
    }),
    fetchGuideChatPage: build.query<any, { cursor: number; limit?: number }>({
      queryFn: withSessionQuery(async ({ cursor, limit = 80 }, { session }) => {
        if (!session?.clientToken) return normalizeChatPage(GUIDE_AGENT_ID, null, true);
        const data = await daemonApi.fetchChat({
          daemonUrl: session.daemonUrl,
          clientToken: session.clientToken,
          agentInstanceId: GUIDE_AGENT_ID,
          limit,
          cursor,
        });
        return normalizeChatPage(GUIDE_AGENT_ID, data, true);
      }),
      async onQueryStarted({ limit = 80 }, { dispatch, queryFulfilled }) {
        try {
          const { data } = await queryFulfilled;
          hydrateChatPage(dispatch, {
            agentId: GUIDE_AGENT_ID,
            messages: data?.messages || [],
            nextCursor: Number(data?.nextCursor || 0),
            isAppend: true,
            markedRead: false,
          });
          dispatch(chatEndpoints.util.updateQueryData('fetchGuideChat', { limit }, (draft: any) => {
            if (!draft) return;
            draft.messages = mergeOlderMessages(draft.messages || [], data?.messages || []);
            draft.nextCursor = Number(data?.nextCursor || 0);
            draft.hasMore = Boolean(data?.hasMore);
          }));
        } catch (_error) {
          // noop
        }
      },
    }),
    fetchChatMessage: build.query<any, { messageId: string }>({
      queryFn: withSessionQuery(async ({ messageId }, { session }) => {
        if (!session?.clientToken || !messageId) return { message: null };
        const data = await daemonApi.fetchChatMessage({
          daemonUrl: session.daemonUrl,
          clientToken: session.clientToken,
          messageId,
        });
        const raw = data?.message || null;
        return {
          message: raw ? mapMessage(raw) : null,
          rawMessage: raw,
          agentInstanceId: String(raw?.agent_instance_id || raw?.agentInstanceId || ''),
          chainId: String(raw?.chain_id || raw?.chainId || ''),
        };
      }),
      async onQueryStarted(_arg, { dispatch, queryFulfilled }) {
        try {
          const { data } = await queryFulfilled;
          const agentInstanceId = String(data?.agentInstanceId || '');
          const message = data?.message;
          const rawMessage = data?.rawMessage;
          if (!agentInstanceId || !message || !rawMessage) return;
          if (agentInstanceId === GUIDE_AGENT_ID) {
            dispatch(chatEndpoints.util.updateQueryData('fetchGuideChat', guideChatArgs(), (draft: any) => {
              if (!draft) return;
              upsertMessage(draft.messages || (draft.messages = []), message);
            }));
          } else {
            dispatch(chatEndpoints.util.updateQueryData('fetchDirectChat', { agentInstanceId, limit: 50 }, (draft: any) => {
              if (!draft) return;
              upsertMessage(draft.messages || (draft.messages = []), message);
            }));
          }
          // tool_activity rows are written silently (no preview or last-message bump on
          // the server), so the sidebar summary must not jump on every flush either.
          if (message.messageType !== 'tool_activity') {
            dispatch(chatEndpoints.util.updateQueryData('listConversationSummaries', undefined, (draft: any) => patchConversationSummary(draft, agentInstanceId, String(rawMessage.body || ''))));
          }
          appendChatMessage(dispatch, agentInstanceId, rawMessage);
        } catch (_error) {
          // noop
        }
      },
    }),
    markChatRead: build.mutation<any, { agentInstanceId: string }>({
      queryFn: withSessionQuery(async ({ agentInstanceId }, { session }) => {
        if (!session?.clientToken || !agentInstanceId) return { ok: false, agentInstanceId };
        await daemonApi.markChatRead({
          daemonUrl: session.daemonUrl,
          clientInstanceId: session.clientInstanceId,
          clientToken: session.clientToken,
          agentInstanceId,
        });
        return { ok: true, agentInstanceId };
      }),
      async onQueryStarted({ agentInstanceId }, { dispatch, queryFulfilled }) {
        try {
          await queryFulfilled;
          dispatch(chatEndpoints.util.updateQueryData('listConversationSummaries', undefined, (draft: any) => {
            const summaries = draft?.summaries || draft;
            if (summaries?.[agentInstanceId]) summaries[agentInstanceId].unreadCount = 0;
          }));
        } catch (_error) {
          // noop
        }
      },
    }),
    sendAgentMessage: build.mutation<any, { agentInstanceId: string; body: string; tempId: string; interrupt?: boolean; artifactIds?: string[] }>({
      queryFn: withSessionQuery(async ({ agentInstanceId, body, interrupt, artifactIds }, { session, state }) => {
        const isUnlocked = Boolean(state?.vault?.isUnlocked);
        const activeKey = getActiveVaultKey();
        let encBody = body;
        if (isUnlocked && activeKey && encBody && !isVaultArmored(encBody)) {
          encBody = await encryptVaultText(encBody, activeKey);
        }
        const res = await daemonApi.sendToAgent({
          daemonUrl: session.daemonUrl,
          clientInstanceId: session.clientInstanceId,
          clientToken: session.clientToken,
          agentInstanceId,
          body: encBody,
          interrupt,
          artifactIds,
        });
        return { messageId: String(res.message_id || ''), agentInstanceId };
      }),
      async onQueryStarted({ agentInstanceId, body, tempId, artifactIds }, { dispatch, queryFulfilled }) {
        const optimistic = optimisticMessage(tempId, body, artifactIds);
        const patch = dispatch(chatEndpoints.util.updateQueryData('fetchDirectChat', { agentInstanceId, limit: 50 }, (draft: any) => {
          if (!draft) return;
          upsertMessage(draft.messages || (draft.messages = []), optimistic);
        }));
        const summaryPatch = dispatch(chatEndpoints.util.updateQueryData('listConversationSummaries', undefined, (draft: any) => patchConversationSummary(draft, agentInstanceId, body)));
        try {
          const { data } = await queryFulfilled;
          dispatch(chatEndpoints.util.updateQueryData('fetchDirectChat', { agentInstanceId, limit: 50 }, (draft: any) => {
            const message = (draft?.messages || []).find((entry: any) => entry.id === tempId);
            if (!message) return;
            message.id = data?.messageId || message.id;
            message.sending = false;
            message.optimistic = true;
            message.deliveredUnixMs = Date.now();
            message.deliveryFailedUnixMs = 0;
            message.deliveryError = '';
          }));
        } catch (_error) {
          patch.undo();
          summaryPatch.undo();
        }
      },
    }),
    sendGuideMessage: build.mutation<any, { body: string; tempId: string; interrupt?: boolean }>({
      queryFn: withSessionQuery(async ({ body, interrupt }, { session, state }) => {
        const isUnlocked = Boolean(state?.vault?.isUnlocked);
        const activeKey = getActiveVaultKey();
        let encBody = body;
        if (isUnlocked && activeKey && encBody && !isVaultArmored(encBody)) {
          encBody = await encryptVaultText(encBody, activeKey);
        }
        const res = await daemonApi.sendToAgent({
          daemonUrl: session.daemonUrl,
          clientInstanceId: session.clientInstanceId,
          clientToken: session.clientToken,
          agentInstanceId: GUIDE_AGENT_ID,
          body: encBody,
          interrupt,
        });
        return { messageId: String(res.message_id || '') };
      }),
      async onQueryStarted({ body, tempId }, { dispatch, queryFulfilled }) {
        const optimistic = optimisticMessage(tempId, body);
        const patch = dispatch(chatEndpoints.util.updateQueryData('fetchGuideChat', { limit: 80 }, (draft: any) => {
          if (!draft) return;
          upsertMessage(draft.messages || (draft.messages = []), optimistic);
        }));
        const summaryPatch = dispatch(chatEndpoints.util.updateQueryData('listConversationSummaries', undefined, (draft: any) => patchConversationSummary(draft, GUIDE_AGENT_ID, body)));
        try {
          const { data } = await queryFulfilled;
          dispatch(chatEndpoints.util.updateQueryData('fetchGuideChat', { limit: 80 }, (draft: any) => {
            const message = (draft?.messages || []).find((entry: any) => entry.id === tempId);
            if (!message) return;
            message.id = data?.messageId || message.id;
            message.sending = false;
            message.optimistic = true;
            message.deliveredUnixMs = Date.now();
            message.deliveryFailedUnixMs = 0;
            message.deliveryError = '';
          }));
        } catch (_error) {
          patch.undo();
          summaryPatch.undo();
        }
      },
    }),
    listAllChatConversations: build.query<any, { limit?: number } | void>({
      queryFn: async (arg, api) => {
        try {
          const limit = typeof arg === 'object' && arg !== null && typeof arg.limit === 'number' ? arg.limit : 200;
          const raw = await cookieJsonFetch(`/chats?limit=${encodeURIComponent(limit)}`);
          let data = raw?.data ?? raw;
          const state: any = api?.getState?.();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const activeKey = getActiveVaultKey();
          if (isUnlocked && activeKey && Array.isArray(data)) {
            data = await Promise.all(data.map((c) => decryptConversationRecord(c, activeKey)));
          }
          return { data };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error) } as any };
        }
      },
      providesTags: [{ type: 'ConversationSummaries' as const, id: 'ALL' }],
    }),
  }),
  overrideExisting: false,
});

export const {
  useCreateLaunchConversationMutation,
  useFetchConversationQuery,
  useFetchConversationMessagesQuery,
  useLazyFetchConversationMessagesQuery,
  useUpdateConversationTitleMutation,
  useRequestPaneCaptureMutation,
  useSendConversationMessageMutation,
  useAnswerConversationQuestionsMutation,
  useMarkConversationReadMutation,
} = chatEndpoints;

export {
  encryptChatFields,
  decryptChatMessage,
  decryptChatMessages,
  encryptConversationFields,
  decryptConversationRecord,
  decryptConversationList,
} from '../../utils/vaultChats';
