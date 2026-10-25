import { heimdallApi } from '../heimdallApi';
import { apiUrl, cookieJsonFetch } from '../cookieFetch';
import { decryptProjectList } from '../../utils/vaultProjects';
import { decryptConversationRecord } from '../../utils/vaultChats';
import { getActiveVaultKey } from '../../utils/vaultContent';

// UI-14: cookie-authenticated sidebar data for the live shell. The shell serves
// the rewrite with the Hub session cookie, so these use `credentials: 'include'`
// (same auth session as `/api/v1/me`) — not the legacy per-client token session.
// Server state lives in RTK Query; WS events invalidate the tags below so the
// sidebar's unread badges refresh through the single user-WS invalidation path.

export type SidebarConversationLastMessage = {
  messageId: string;
  direction: string;
  rawDirection: string;
  bodyPreview: string;
  createdAt: string;
  createdUnixMs: number;
  messageType: string;
  messageStatus: string;
  sender: {
    displayName: string;
    agentId: string;
    agentInstanceId: string;
  };
};

export type SidebarConversationParticipant = {
  role: string;
  displayName: string;
  agentId?: string;
  agentInstanceId?: string;
};

export type SidebarConversation = {
  conversationId: string;
  agentId: string;
  agentInstanceId: string;
  agentName?: string;
  projectId: string;
  title: string;
  unreadCount: number;
  updatedAt: string;
  lastMessageAt: string;
  lastMessagePreview: string;
  lastMessageDirection: string;
  lastMessageUnixMs: number;
  lastMessage?: SidebarConversationLastMessage | null;
  participants?: SidebarConversationParticipant[];
  bridgeId?: string;
  runtimeStatus?: string;
  // H13: activity_status of the agent instance, so the sidebar dot animates ONLY
  // when the agent is actually working (not merely live-idle).
  activityStatus?: string;
};

export type ConversationInboxPage = {
  conversations: SidebarConversation[];
  nextCursor: string;
  hasMore: boolean;
};

export type SidebarProject = {
  projectId: string;
  name: string;
  isDefaultConversations?: boolean;
};

function asNumber(value: any): number {
  const parsed = Number(value ?? 0);
  return Number.isFinite(parsed) ? parsed : 0;
}

function normalizeSidebarConversation(raw: any): SidebarConversation {
  const conversationId = String(raw?.conversation_id || raw?.conversationId || raw?.id || '');
  const agentInstanceId = String(raw?.agent_instance_id || raw?.agentInstanceId || raw?.instance_id || '');
  const agentId = String(raw?.agent_id || raw?.agentId || raw?.agent || 'unknown-agent');
  const projectId = String(raw?.project_id || raw?.projectId || 'default-conversations');
  const bridgeId = String(raw?.bridge_id || raw?.bridgeId || '').trim() || undefined;
  const runtimeStatus = String(raw?.runtime_status || raw?.runtimeStatus || raw?.status || '').trim() || undefined;
  const activityStatus = String(raw?.activity_status || raw?.activityStatus || '').trim() || undefined;
  const lastMessageRaw = raw?.last_message || raw?.lastMessage || null;
  const lastMessagePreview = String(lastMessageRaw?.body_preview || lastMessageRaw?.bodyPreview || raw?.last_message_preview || raw?.lastMessagePreview || '');
  const lastMessageAt = String(lastMessageRaw?.created_at || lastMessageRaw?.createdAt || raw?.last_message_at || raw?.lastMessageAt || raw?.updated_at || raw?.updatedAt || '');
  const lastMessageDirection = String(lastMessageRaw?.direction || raw?.last_message_direction || raw?.lastMessageDirection || '').trim();
  const rawLastMessageUnixMs = lastMessageRaw?.created_unix_ms ?? lastMessageRaw?.createdUnixMs ?? raw?.last_message_unix_ms ?? raw?.lastMessageUnixMs;
  const lastMessageUnixMs = asNumber(rawLastMessageUnixMs || Date.parse(lastMessageAt) || 0);
  const lastMessage = lastMessageRaw || lastMessagePreview || lastMessageDirection ? {
    messageId: String(lastMessageRaw?.message_id || lastMessageRaw?.messageId || ''),
    direction: lastMessageDirection,
    rawDirection: String(lastMessageRaw?.raw_direction || lastMessageRaw?.rawDirection || raw?.last_message_direction || raw?.lastMessageDirection || ''),
    bodyPreview: lastMessagePreview,
    createdAt: lastMessageAt,
    createdUnixMs: lastMessageUnixMs,
    messageType: String(lastMessageRaw?.message_type || lastMessageRaw?.messageType || 'text'),
    messageStatus: String(lastMessageRaw?.message_status || lastMessageRaw?.messageStatus || 'complete'),
    sender: {
      displayName: String(lastMessageRaw?.sender?.display_name || lastMessageRaw?.sender?.displayName || ''),
      agentId: String(lastMessageRaw?.sender?.agent_id || lastMessageRaw?.sender?.agentId || ''),
      agentInstanceId: String(lastMessageRaw?.sender?.agent_instance_id || lastMessageRaw?.sender?.agentInstanceId || ''),
    },
  } : null;
  const participants = Array.isArray(raw?.participants) ? raw.participants.map((p: any) => ({
    role: String(p?.role || ''),
    displayName: String(p?.display_name || p?.displayName || p?.name || ''),
    agentId: String(p?.agent_id || p?.agentId || '') || undefined,
    agentInstanceId: String(p?.agent_instance_id || p?.agentInstanceId || '') || undefined,
  })) : undefined;
  return {
    conversationId,
    agentId: agentId || 'unknown-agent',
    agentInstanceId,
    agentName: String(raw?.agent_display_name || raw?.agentDisplayName || raw?.agent_name || raw?.agentName || '').trim() || undefined,
    projectId: projectId || 'default-conversations',
    title: String(raw?.title || lastMessagePreview || agentInstanceId || conversationId || 'Untitled session'),
    unreadCount: asNumber(raw?.unread_count ?? raw?.unreadCount),
    updatedAt: String(raw?.updated_at || raw?.updatedAt || lastMessageAt || ''),
    lastMessageAt,
    lastMessagePreview,
    lastMessageDirection,
    lastMessageUnixMs,
    lastMessage,
    participants,
    bridgeId,
    runtimeStatus,
    activityStatus,
  };
}

function normalizeSidebarProject(raw: any): SidebarProject {
  const name = String(raw?.name || raw?.title || 'Untitled project');
  const projectId = String(raw?.project_id || raw?.projectId || raw?.id || '');
  const isDefaultConversations = raw?.is_default_conversations === true || raw?.isDefaultConversations === true || projectId === 'default-conversations';
  return { projectId: projectId || (isDefaultConversations ? 'default-conversations' : name), name, isDefaultConversations };
}

function extractListPayload(payload: any, collectionKeys: string[] = []): any[] {
  if (Array.isArray(payload)) return payload;
  if (Array.isArray(payload?.data)) return payload.data;

  const candidates = [payload?.data, payload].filter(Boolean);
  const keys = [...collectionKeys, 'items', 'rows', 'results'];
  for (const source of candidates) {
    for (const key of keys) {
      const value = source?.[key];
      if (Array.isArray(value)) return value;
    }
  }
  return [];
}

async function fetchCookieList(path: string, collectionKeys: string[] = []): Promise<any[]> {
  const payload = await cookieJsonFetch(path);
  return extractListPayload(payload, collectionKeys);
}

async function fetchCookiePage(path: string, collectionKeys: string[] = []): Promise<{ rows: any[]; page: any }> {
  const response = await fetch(apiUrl(path), { credentials: 'include' });
  if (!response.ok) {
    let msg = `Request failed (${response.status})`;
    try {
      const text = await response.text();
      const body = JSON.parse(text);
      msg = String(body?.error?.message || body?.message || msg);
    } catch (_err) {}
    throw new Error(msg);
  }
  const body = await response.json();
  return { rows: extractListPayload(body, collectionKeys), page: body?.page || body?.data?.page || {} };
}

export const sidebarApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    // Conversations list for the sidebar tree. Tagged so the user-WS chat-event
    // path can invalidate it and refresh unread badges.
    listSidebarConversations: build.query<SidebarConversation[], { limit?: number; activeOnly?: boolean } | void>({
      queryFn: async (arg, api) => {
        try {
          const limit = (arg && typeof arg === 'object' && arg.limit) || 30;
          const activeOnly = Boolean(arg && typeof arg === 'object' && arg.activeOnly);
          // ?active=true asks the hub to return only conversations whose bound
          // agent instance is in a live runtime state (running agents only).
          const rows = await fetchCookieList(`/chats?limit=${limit}${activeOnly ? '&active=true' : ''}`, ['conversations', 'chats']);
          let conversations = rows.map(normalizeSidebarConversation).filter((c) => c.conversationId);
          const state: any = api?.getState?.();
          const activeKey = getActiveVaultKey();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          if (isUnlocked && activeKey) {
            conversations = await Promise.all(conversations.map((c) => decryptConversationRecord(c, activeKey)));
          }
          return { data: conversations };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error || 'Request failed') } as any };
        }
      },
      providesTags: (result) => [
        { type: 'SidebarConversations' as const, id: 'ALL' },
        ...(result || []).map((c) => ({ type: 'SidebarConversations' as const, id: c.conversationId })),
      ],
    }),
    listConversationInbox: build.query<ConversationInboxPage, { limit?: number; cursor?: string } | void>({
      queryFn: async (arg, api) => {
        try {
          const limit = (arg && typeof arg === 'object' && arg.limit) || 50;
          const cursor = (arg && typeof arg === 'object' && arg.cursor) || '';
          const params = new URLSearchParams({
            limit: String(limit),
            include: 'last_message,participants',
            sort: '-last_message_at',
          });
          if (cursor) params.set('cursor', cursor);
          const { rows, page } = await fetchCookiePage(`/chats?${params.toString()}`, ['conversations', 'chats']);
          let conversations = rows.map(normalizeSidebarConversation).filter((c) => c.conversationId);
          const state: any = api?.getState?.();
          const activeKey = getActiveVaultKey();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          if (isUnlocked && activeKey) {
            conversations = await Promise.all(conversations.map((c) => decryptConversationRecord(c, activeKey)));
          }
          return { data: { conversations, nextCursor: String(page?.next_cursor ?? page?.nextCursor ?? ''), hasMore: Boolean(page?.has_more ?? page?.hasMore ?? conversations.length >= limit) } };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error || 'Request failed') } as any };
        }
      },
      providesTags: (result) => [
        { type: 'SidebarConversations' as const, id: 'ALL' },
        ...(result?.conversations || []).map((c) => ({ type: 'SidebarConversations' as const, id: c.conversationId })),
      ],
    }),
    listSidebarProjects: build.query<SidebarProject[], { limit?: number } | void>({
      queryFn: async (arg, api) => {
        try {
          const limit = (arg && typeof arg === 'object' && arg.limit) || 100;
          const rows = await fetchCookieList(`/projects?limit=${limit}`, ['projects']);
          const rawProjects = rows.map(normalizeSidebarProject);
          const state: any = api?.getState?.();
          const activeKey = getActiveVaultKey();
          const isUnlocked = Boolean(state?.vault?.isUnlocked);
          const projects = (isUnlocked && activeKey)
            ? await decryptProjectList(rawProjects, activeKey)
            : rawProjects;
          return { data: projects };
        } catch (error: any) {
          return { error: { status: 'CUSTOM_ERROR', error: String(error?.message || error || 'Request failed') } as any };
        }
      },
      providesTags: [{ type: 'SidebarProjects' as const, id: 'ALL' }],
    }),
  }),
});

export const {
  useListSidebarConversationsQuery,
  useListConversationInboxQuery,
  useLazyListConversationInboxQuery,
  useListSidebarProjectsQuery,
} = sidebarApi;
