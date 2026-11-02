import { announceTaskChainCreated } from './taskChainCreationEvents';
import { heimdallApi, HEIMDALL_TAG_TYPES } from './heimdallApi';
import { tasksApi } from './endpoints/tasks';
import { normalizeChain, workspaceApi } from './endpoints/workspace';
import { chatEndpoints } from './endpoints/chats';
import { agentsApi, patchAgentCachesFromWs } from './endpoints/agents';
import { agentsLiveApi } from './endpoints/agentsLive';
import { sidebarApi } from './endpoints/sidebar';
import { shellListMayContain, shellListTagId, shellsApi, type ShellSessionFacts } from './endpoints/shells';
import {
  announceConversationMessagesRead,
  applyReadReceiptToDraft,
  consumeLocalMessageEcho,
  expireConversationOptions,
} from './conversationMessageEvents';
import { patchMemoryCachesFromWs } from './endpoints/memory';
import { bridgeSupportApi } from './endpoints/bridgeSupport';
import { AGENT_BLOCKERS_CHANGE } from '../components/extension/blockersModel';
import { upsertTaskInList, upsertTaskLogEvent } from './taskCache';
import { attentionEventReceived } from '../store/attentionSlice';
import { announcePaneVaultLocked } from '../utils/vaultLockedError';
import { runMcpWorker } from '../services/mcpWorker';
import { GUIDE_AGENT_ID, appendMessage, chatEventReceived, patchChatMessageStatus } from '../store/chatSlice';
import { wsChainViewRefreshRequested } from '../store/chainViewSlice';
import { wsRefreshRequested } from '../store/homeSlice';
import { auditEndedReceived, auditStartedReceived, memoryEventReceived } from '../store/memorySlice';
import { taskEventReceived } from '../store/taskSlice';
import { shellSessionEventReceived } from '../store/shellSlice';
import { agentActionReceived } from '../store/agentActivitySlice';
import { fireNotificationForWsEvent } from '../services/notificationService';
import { upsertChainTitle, upsertConversationTitle } from '../store/searchTitleSlice';
import { isVaultArmored, decryptVaultText, getActiveVaultKey } from '../utils/vaultContent';
import { handleVaultDirectoryEvent } from '../services/deviceVaultEvents';
import { clearDirtyMarks, deferIfHidden } from './paneDeferral';

// Focus context read at WS-event time (populated by the shell from the live
// route). Only focusedChainId is consumed — it lets a resource/chat/agent event
// for the chain the user is currently viewing trigger an extra chain-view
// refresh. Other former fields (selectedAgentId, visibleChatAgentId,
// focusedCoordinatorAgentInstanceId, guidePanelOpen) were never populated and had
// no live consumer, so they were removed; foreground notification suppression now
// derives the open conversation from the route hash inside notificationService.
type WsCtx = {
  focusedChainId?: string;
};

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function normalizeTask(task: any) {
  // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
  const result: any = {
    id: task.task_id,
    taskId: task.task_id,
    chainId: task.chain_id || '',
    title: task.title || '',
    priority: task.priority || 'normal',
    status: task.status || 'pending',
    assigneeAgentInstanceId: task.assignee_agent_instance_id || '',
    reviewerAgentInstanceId: task.reviewer_agent_instance_id || '',
    coordinatorAgentInstanceId: task.coordinator_agent_instance_id || '',
    dependsOn: task.depends_on || '',
    createdBy: task.created_by || '',
    createdAtUnixMs: Number(task.created_at_unix_ms || 0),
    updatedAtUnixMs: Number(task.updated_at_unix_ms || 0),
    notActionableReason: task.not_actionable_reason || '',
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    votes: (task.votes || []).map((vote: any) => ({
      reviewerAgentInstanceId: vote.reviewer_agent_instance_id,
      approved: Boolean(vote.approved),
      comment: vote.comment || '',
    })),
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    participants: (task.participants || []).map((participant: any) => ({
      agentInstanceId: participant.agent_instance_id,
      role: participant.role,
    })),
    unresolvedCommentCount: Number(task.unresolved_comment_count || 0),
    commentIds: task.comment_ids || [],
  };
  if (task.description !== undefined) {
    result.description = task.description;
  }
  if (task.acceptance_criteria !== undefined) {
    result.acceptanceCriteria = task.acceptance_criteria;
  }
  return result;
}

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function normalizeTaskLogEvent(event: any) {
  return {
    eventId: event.event_id || '',
    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
    kind: event.kind || event.event || '',
    taskId: event.task_id || '',
    chainId: event.chain_id || '',
    status: event.status || '',
    body: event.body || '',
    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
    authorAgentInstanceId: event.author_agent_instance_id || event.changed_by || '',
    createdUnixMs: Number(event.created_unix_ms || 0),
    commentId: event.comment_id || '',
  };
}

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
  sending?: boolean;
  optimistic?: boolean;
  error?: boolean;
};

function timeLabel(unixMs: number) {
  return unixMs > 0 ? new Date(unixMs).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : '';
}

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function normalizeChatMessage(message: any): ChatMessage {
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const createdUnixMs = Number(message.created_unix_ms ?? message.createdUnixMs ?? 0);
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const deliveredUnixMs = Number(message.delivered_unix_ms ?? message.deliveredUnixMs ?? 0);
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const readUnixMs = Number(message.read_unix_ms ?? message.readUnixMs ?? 0);
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const deliveryFailedUnixMs = Number(message.delivery_failed_unix_ms ?? message.deliveryFailedUnixMs ?? 0);
  return {
    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
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
    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
    deliveryError: String(message.delivery_error ?? message.deliveryError ?? ''),
    interrupt: Boolean(message.interrupt),
    sending: Boolean(message.sending),
    optimistic: Boolean(message.optimistic),
    error: Boolean(message.error),
  };
}

function upsertChatMessage(messages: ChatMessage[], next: ChatMessage) {
  const index = messages.findIndex((message) => message.id === next.id);
  if (index >= 0) {
    messages[index] = { ...messages[index], ...next };
    return;
  }
  messages.push(next);
  messages.sort((left, right) => Number(left.createdUnixMs || 0) - Number(right.createdUnixMs || 0));
}

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function patchConversationSummary(draft: any, agentInstanceId: string, payload: any) {
  if (!draft || !agentInstanceId) return;
  const summaries = draft.summaries || draft;
  const message = payload?.message || {};
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const createdUnixMs = Number(message.created_unix_ms ?? message.createdUnixMs ?? Date.now());
  const existing = summaries[agentInstanceId] || { agentInstanceId, agentId: '', projectId: '', title: '' };
  summaries[agentInstanceId] = {
    ...existing,
    lastMessageUnixMs: Math.max(Number(existing.lastMessageUnixMs || 0), createdUnixMs),
    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
    unreadCount: Number(payload?.unread_count ?? existing.unreadCount ?? 0),
  };
  if (!existing.title && String(message.body || '').trim()) {
    summaries[agentInstanceId].title = String(message.body || '').trim().slice(0, 80);
  }
}

function directChatArgs(agentInstanceId: string) {
  return { agentInstanceId, limit: 50 };
}

function guideChatArgs() {
  return { limit: 80 };
}

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function applyChatMessageToCaches(dispatch: any, message: ChatMessage, rawMessage: any, agentId: string, _chainId: string, _ctx: WsCtx) {
  if (agentId === GUIDE_AGENT_ID) {
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    dispatch(chatEndpoints.util.updateQueryData('fetchGuideChat', guideChatArgs(), (draft: any) => {
      if (!draft) return;
      upsertChatMessage(draft.messages || (draft.messages = []), message);
    }));
  } else if (agentId) {
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    dispatch(chatEndpoints.util.updateQueryData('fetchDirectChat', directChatArgs(agentId), (draft: any) => {
      if (!draft) return;
      upsertChatMessage(draft.messages || (draft.messages = []), message);
    }));
  }
  if (agentId) {
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    dispatch(chatEndpoints.util.updateQueryData('listConversationSummaries', undefined, (draft: any) => patchConversationSummary(draft, agentId, { message: rawMessage })));
    dispatch(appendMessage({ agentId, message: rawMessage }));
  }
}

type InFlightTaskEntry = {
  inFlight: boolean;
  pending: boolean;
};

const inFlightTasks = new Map<string, InFlightTaskEntry>();

// Directly patches a task into RTK Query caches (fetchTask, fetchChainTaskDetail,
// fetchTaskChainDetail, and fetchChainTasks) so the sidebar task chain overview and
// thread page progress update in real time without a manual page refresh.
export function patchTaskInChainCaches(dispatch: any, normalizedTask: any, explicitChainId?: string) {
  if (!normalizedTask?.taskId && !normalizedTask?.id) return;
  const taskId = String(normalizedTask.taskId || normalizedTask.id);
  const chainId = String(explicitChainId || normalizedTask.chainId || '');

  // 1. Update fetchTask query
  dispatch(tasksApi.util.upsertQueryData('fetchTask', { taskId }, { task: normalizedTask }));

  if (chainId) {
    // 2. Update fetchChainTaskDetail query (used when task detail/description is expanded)
    dispatch(tasksApi.util.upsertQueryData('fetchChainTaskDetail', { chainId, taskId }, { task: normalizedTask }));

    // 3. Patch fetchTaskChainDetail query (used by TaskChainOverview in the sidebar and thread page)
    dispatch(tasksApi.util.updateQueryData('fetchTaskChainDetail', { chainId }, (draft: any) => {
      if (!draft?.chain) return;
      const list = draft.chain.tasks || (draft.chain.tasks = []);
      const idx = list.findIndex((t: any) => String(t.taskId || t.id) === taskId);
      if (idx >= 0) {
        list[idx] = { ...list[idx], ...normalizedTask };
      } else {
        list.push(normalizedTask);
      }
    }));

    // 4. Patch fetchChainTasks query
    dispatch(tasksApi.util.updateQueryData('fetchChainTasks', { chainId }, (draft: any) => {
      if (!draft) return;
      upsertTaskInList(draft.tasks || (draft.tasks = []), normalizedTask);
    }));
  }
}

// Auto-loads the single corresponding task from the server with in-flight deduplication
// and coalescing. If multiple WS events arrive for the same task in rapid succession,
// exactly one request is in-flight at a time, followed by at most one pending re-fetch.
export function autoLoadTaskFromWs(dispatch: any, chainId: string, taskId: string): void {
  if (!taskId) return;
  const key = `${chainId || ''}:${taskId}`;
  const existing = inFlightTasks.get(key);
  if (existing?.inFlight) {
    existing.pending = true;
    return;
  }
  inFlightTasks.set(key, { inFlight: true, pending: false });

  const executeFetch = () => {
    const fetchAction = chainId
      ? tasksApi.endpoints.fetchChainTaskDetail.initiate({ chainId, taskId }, { subscribe: false, forceRefetch: true })
      : tasksApi.endpoints.fetchTask.initiate({ taskId }, { subscribe: false, forceRefetch: true });

    dispatch(fetchAction)
      .unwrap()
      .then((data: any) => {
        const rawTask = data?.task;
        if (!rawTask) return;
        const normalized = rawTask.taskId ? rawTask : normalizeTask(rawTask);
        patchTaskInChainCaches(dispatch, normalized, chainId);
      })
      .catch((_err: any) => {
        /* silent catch: network failure or task was deleted */
      })
      .finally(() => {
        const entry = inFlightTasks.get(key);
        if (entry?.pending) {
          entry.pending = false;
          executeFetch();
        } else {
          inFlightTasks.delete(key);
        }
      });
  };

  executeFetch();
}

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function handleTaskEvent(dispatch: any, payload: any) {
  dispatch(taskEventReceived(payload));
  if (payload.chain) {
    const chain = normalizeChain(payload.chain);
    if (chain.chainId) {
      dispatch(workspaceApi.util.upsertQueryData('fetchChain', { chainId: chain.chainId }, { chain }));
      // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
      dispatch(workspaceApi.util.updateQueryData('listChains', undefined, (draft: any) => {
        const rows = draft?.chains || (draft.chains = []);
        // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
        const index = rows.findIndex((item: any) => item.chainId === chain.chainId);
        if (index >= 0) rows[index] = { ...rows[index], ...chain };
        else rows.unshift(chain);
      }));
    }
  }

  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const taskId = String(payload.task_id || payload.task?.task_id || '');
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const chainId = String(payload.chain_id || payload.chain?.chain_id || payload.task?.chain_id || '');
  dispatch(wsRefreshRequested(`task_event:${chainId || taskId || 'unknown'}`));

  if (payload.task && taskId) {
    patchTaskInChainCaches(dispatch, normalizeTask(payload.task), chainId);
  } else if (taskId) {
    autoLoadTaskFromWs(dispatch, chainId, taskId);
  }

  // Chain-level list count invalidation only. Do NOT invalidate { type: 'Chain', id: chainId }
  // or { type: 'ChainTasks', id: chainId } to prevent reloading all tasks in the chain.
  dispatch(heimdallApi.util.invalidateTags([{ type: 'ChainList', id: 'ALL' }]));
  if (taskId) {
    dispatch(heimdallApi.util.invalidateTags([{ type: 'TaskLog', id: taskId }]));
  }

  if (taskId) {
    const eventRecord = normalizeTaskLogEvent(payload);
    const patchLog = (args: { taskId: string; limit?: number }) => {
      // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
      dispatch(tasksApi.util.updateQueryData('fetchTaskLog', args, (draft: any) => {
        if (!draft) return;
        const events = draft.events || (draft.events = []);
        const inserted = upsertTaskLogEvent(events, eventRecord);
        if (inserted) draft.total = Number(draft.total || 0) + 1;
      }));
    };
    patchLog({ taskId });
    patchLog({ taskId, limit: 50 });
    dispatch(heimdallApi.util.invalidateTags([
      { type: 'Task', id: taskId },
      { type: 'TaskLog', id: taskId },
      { type: 'TaskComments', id: taskId },
    ]));
  }
}

function dispatchSearchTitleUpsert(
  dispatch: any,
  item: {
    id: string;
    type: 'chain' | 'conversation';
    rawTitle: string;
    decryptedTitle?: string;
    projectId?: string;
    status?: string;
    updatedAt?: string;
  },
) {
  if (!item.id || !item.rawTitle) return;
  const isChain = item.type === 'chain';
  const actionCreator = isChain ? upsertChainTitle : upsertConversationTitle;

  const decryptedTitle = item.decryptedTitle ?? item.rawTitle;
  dispatch(
    actionCreator({
      ...item,
      decryptedTitle,
    }),
  );

  if (isVaultArmored(item.rawTitle)) {
    const activeKey = getActiveVaultKey();
    if (activeKey) {
      decryptVaultText(item.rawTitle, activeKey)
        .then((decrypted) => {
          if (decrypted && decrypted !== item.rawTitle) {
            dispatch(
              actionCreator({
                ...item,
                decryptedTitle: decrypted,
              }),
            );
          }
        })
        .catch(() => {});
    }
  }
}


// ---- Burst coalescing -------------------------------------------------------------
// One logical change often reaches us as several frames (a send: message_created plus
// the mutation's own invalidation; a restart: several status transitions). Targeted
// invalidations are queued per tag key and flushed once per window, so a burst on the
// same key costs at most one refetch per mounted query. Distinct keys (different
// conversations, facets, runs) never merge.
export const INVALIDATION_COALESCE_MS = 150;
type QueuedTag = { tag: { type: string; id: string }; unconditional: boolean; echoGuards: Set<string> };
const queuedTags = new Map<string, QueuedTag>();
let queuedDispatch: any = null;
let queuedTimer: ReturnType<typeof setTimeout> | null = null;

// echoGuard: the tag is dropped at flush time when the guard is a message this tab sent
// (its mutation already invalidated the same tags). The hub publishes before it returns
// the POST response, so the echo can arrive before the tab learns its own message id.
function queueInvalidation(dispatch: any, tags: Array<{ type: string; id: string }>, echoGuard = ''): void {
  for (const tag of tags) {
    if (!tag.id) continue;
    const key = `${tag.type}\u0000${tag.id}`;
    const entry = queuedTags.get(key) || { tag, unconditional: false, echoGuards: new Set<string>() };
    if (echoGuard) entry.echoGuards.add(echoGuard);
    else entry.unconditional = true;
    queuedTags.set(key, entry);
  }
  queuedDispatch = dispatch;
  if (queuedTimer) return;
  queuedTimer = setTimeout(flushQueuedInvalidations, INVALIDATION_COALESCE_MS);
}

export function flushQueuedInvalidations(): void {
  if (queuedTimer) clearTimeout(queuedTimer);
  queuedTimer = null;
  const dispatch = queuedDispatch;
  const entries = [...queuedTags.values()];
  queuedTags.clear();
  if (!dispatch || entries.length === 0) return;
  const echoes = new Map<string, boolean>();
  const isEcho = (id: string) => {
    if (!echoes.has(id)) echoes.set(id, consumeLocalMessageEcho(id));
    return Boolean(echoes.get(id));
  };
  // The deferral records which requests predate the mark, so it reads the store now.
  const state = readState(dispatch);
  const tags = entries
    .filter((entry) => entry.unconditional || [...entry.echoGuards].some((id) => !isEcho(id)))
    .map((entry) => entry.tag)
    // A conversation whose panes are all hidden refetches once when one is shown.
    .filter((tag) => !deferIfHidden(tag, state));
  if (tags.length > 0) dispatch(heimdallApi.util.invalidateTags(tags as any));
}

// The store state via a thunk; undefined when the dispatch is not a thunk-capable store.
function readState(dispatch: any): unknown {
  let state: unknown;
  dispatch((_d: any, getState: () => unknown) => {
    state = getState();
  });
  return state;
}

export function hasQueuedInvalidations(): boolean {
  return queuedTags.size > 0 || queuedTimer !== null;
}

// Tests and teardown: drop anything queued without dispatching it.
export function resetQueuedInvalidations(): void {
  if (queuedTimer) clearTimeout(queuedTimer);
  queuedTimer = null;
  queuedTags.clear();
  queuedDispatch = null;
}

// An API reset (user switch, vault lock/unlock: every resetApiState) ends the previous
// cache owner's state: queued tags and their timer, and hidden-pane dirty marks. Mounted
// queries refetch from scratch after a reset, so nothing is lost. Keeps the marks from
// carrying one owner's conversation ids into the next session.
export const paneDeferralResetMiddleware = () => (next: (action: unknown) => unknown) => (action: unknown) => {
  if (heimdallApi.util.resetApiState.match(action as any)) {
    resetQueuedInvalidations();
    clearDirtyMarks();
  }
  return next(action);
};

// The sidebar lists are a bounded page ordered by last_message_at (/chats?limit=30, the
// inbox's first page). A row tag reaches only lists that already hold the row; a message
// in a conversation outside one of them must still move it to the top, so that list is
// refetched as a whole (SidebarConversations:ALL). Older inbox pages do not decide this:
// a new message lands on the first page.
function sidebarTagForMessage(state: any, conversationId: string): { type: string; id: string } {
  const lists: Array<Array<{ conversationId?: string }>> = [];
  for (const arg of sidebarApi.util.selectCachedArgsForQuery(state, 'listSidebarConversations') as any[]) {
    const rows = sidebarApi.endpoints.listSidebarConversations.select(arg)(state)?.data;
    if (Array.isArray(rows)) lists.push(rows);
  }
  for (const arg of sidebarApi.util.selectCachedArgsForQuery(state, 'listConversationInbox') as any[]) {
    if (arg && (arg as any).cursor) continue;
    const page = sidebarApi.endpoints.listConversationInbox.select(arg)(state)?.data;
    if (Array.isArray(page?.conversations)) lists.push(page.conversations);
  }
  const everywhere = lists.every((rows) => rows.some((row) => row?.conversationId === conversationId));
  return { type: 'SidebarConversations', id: everywhere ? conversationId : 'ALL' };
}

function queueMessageInvalidation(dispatch: any, conversationId: string, extra: Array<{ type: string; id: string }>, echoGuard = ''): void {
  dispatch((_d: any, getState: () => any) => {
    const sidebarTag = conversationId ? sidebarTagForMessage(getState(), conversationId) : { type: 'SidebarConversations', id: 'ALL' };
    queueInvalidation(dispatch, [...extra, sidebarTag], echoGuard);
  });
}

// messages_read: patch every loaded RTK page of the conversation (newest and older
// cursors) and tell the pane, which keeps older pages in state. unread_count is the
// committed value, so the sidebar rows are patched rather than refetched.
function applyMessagesRead(dispatch: any, payload: any, conversationId: string): void {
  const receipt = {
    conversationId,
    messageIds: Array.isArray(payload.message_ids) ? payload.message_ids.map(String) : [],
    readAt: String(payload.read_at || ''),
  };
  dispatch((d: any, getState: () => any) => {
    const state = getState();
    for (const arg of chatEndpoints.util.selectCachedArgsForQuery(state, 'fetchConversationMessages') as any[]) {
      if (String(arg?.conversationId || '') !== conversationId) continue;
      d(chatEndpoints.util.updateQueryData('fetchConversationMessages', arg, (draft: any) => applyReadReceiptToDraft(draft?.messages, receipt)));
    }
    if (payload.unread_count === undefined) return;
    const unread = Number(payload.unread_count || 0);
    for (const arg of sidebarApi.util.selectCachedArgsForQuery(state, 'listSidebarConversations') as any[]) {
      d(sidebarApi.util.updateQueryData('listSidebarConversations', arg, (draft: any) => {
        for (const row of Array.isArray(draft) ? draft : []) if (row?.conversationId === conversationId) row.unreadCount = unread;
      }));
    }
  });
  announceConversationMessagesRead(receipt);
}

// Legacy daemon caches (fetchDirectChat/fetchGuideChat/listConversationSummaries and the
// chat slice). Not mounted by the cookie shell; kept patched for the legacy client path.
// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function applyLegacyStatusPatch(dispatch: any, payload: any, agentId: string): void {
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const readUnixMs = Number(payload.read_unix_ms || payload.readUnixMs || 0) || (payload.read_at ? Date.parse(payload.read_at) : 0) || 0;
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const deliveredUnixMs = Number(payload.delivered_unix_ms || payload.deliveredUnixMs || 0) || (payload.delivered_at ? Date.parse(payload.delivered_at) : 0) || 0;
  const messageIds: string[] = Array.isArray(payload.message_ids) ? payload.message_ids.map(String) : (payload.message_id ? [String(payload.message_id)] : []);
  const statusPatch = {
    agentId,
    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
    messageId: String(payload.message_id || (messageIds.length === 1 ? messageIds[0] : '')),
    deliveredUnixMs,
    readUnixMs,
    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
    deliveryFailedUnixMs: Number(payload.delivery_failed_unix_ms || payload.deliveryFailedUnixMs || 0),
    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
    deliveryError: String(payload.delivery_error || payload.deliveryError || ''),
  };
  dispatch(patchChatMessageStatus(statusPatch));
  // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
  const patchCache = (draft: any) => {
    if (!draft?.messages) return;
    const messageId = statusPatch.messageId;
    const idSet = new Set(messageIds);
    for (const message of draft.messages) {
      const mid = String(message.id || '');
      const matchesId = (messageId && mid === messageId) || (idSet.size > 0 && idSet.has(mid));
      const matchesReadWatermark = !messageId && idSet.size === 0 && statusPatch.readUnixMs > 0 && message.author === 'user' && Number(message.createdUnixMs || 0) <= statusPatch.readUnixMs;
      if (!matchesId && !matchesReadWatermark) continue;
      if (statusPatch.deliveredUnixMs > 0) message.deliveredUnixMs = Math.max(Number(message.deliveredUnixMs || 0), statusPatch.deliveredUnixMs);
      if (statusPatch.readUnixMs > 0) message.readUnixMs = Math.max(Number(message.readUnixMs || 0), statusPatch.readUnixMs);
      if (statusPatch.deliveryFailedUnixMs > 0) message.deliveryFailedUnixMs = Math.max(Number(message.deliveryFailedUnixMs || 0), statusPatch.deliveryFailedUnixMs);
      if (statusPatch.deliveryError) message.deliveryError = statusPatch.deliveryError;
      message.sending = false;
      message.optimistic = false;
    }
  };
  if (agentId === GUIDE_AGENT_ID) dispatch(chatEndpoints.util.updateQueryData('fetchGuideChat', guideChatArgs(), patchCache));
  else dispatch(chatEndpoints.util.updateQueryData('fetchDirectChat', directChatArgs(agentId), patchCache));
  // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
  dispatch(chatEndpoints.util.updateQueryData('listConversationSummaries', undefined, (draft: any) => {
    const summaries = draft?.summaries || draft;
    if (summaries?.[agentId] && payload.unread_count !== undefined) {
      summaries[agentId].unreadCount = Number(payload.unread_count || 0);
    }
  }));
  if (statusPatch.messageId && !statusPatch.deliveredUnixMs && !statusPatch.readUnixMs && !statusPatch.deliveryFailedUnixMs) {
    dispatch(chatEndpoints.endpoints.fetchChatMessage.initiate({ messageId: statusPatch.messageId }, { subscribe: false, forceRefetch: true })).unwrap().catch(() => undefined);
  }
}

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function handleChatEvent(dispatch: any, payload: any, ctx: WsCtx) {
  dispatch(chatEventReceived(payload));
  const agentId = String(payload.agent_instance_id || '');
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const conversationId = String(payload.conversation_id || payload.conversationId || '');
  const chatTitle = String(
    payload.title ||
    payload.conversation_title ||
    payload.conversationTitle ||
    payload.summary?.title ||
    payload.message?.conversation_title ||
    ''
  );
  if (chatTitle && (conversationId || agentId)) {
    dispatchSearchTitleUpsert(dispatch, {
      id: conversationId || agentId,
      type: 'conversation',
      rawTitle: chatTitle,
      projectId: payload.project_id || payload.projectId || undefined,
      updatedAt: payload.updated_at || payload.updatedAt || undefined,
    });
  }
  const eventChainId = String(payload.chain_id || '');
  const focusedChainId = String(ctx.focusedChainId || '');
  const hasInlineMessage = Boolean(payload.message);
  const message = hasInlineMessage ? normalizeChatMessage(payload.message) : null;
  const direction = String(payload.direction || payload.message?.direction || '');
  const isStatusOnlyEvent = !message && (direction === 'read' || direction === 'delivered' || direction === 'delivery_failed' || payload.event === 'messages_read');

  dispatch(wsRefreshRequested(`chat_event:${agentId || payload.message_id || 'unknown'}`));
  // Cookie shell (the only mounted consumer): caches are keyed by conversation id.
  // messages_read patches in place; a new message refetches only that conversation's
  // newest page and the sidebar rows, never /agents/live or the conversation header.
  if (conversationId && payload.event === 'messages_read') {
    applyMessagesRead(dispatch, payload, conversationId);
    if (agentId) applyLegacyStatusPatch(dispatch, payload, agentId);
    return;
  }
  if (conversationId && !message && payload.fetch_required && String(payload.fetch_kind || '') === 'chat_message') {
    if (!isStatusOnlyEvent && direction !== 'agent_to_agent') expireConversationOptions(conversationId);
    const messageId = String(payload.fetch_id || payload.message_id || '');
    queueMessageInvalidation(dispatch, conversationId, [{ type: 'Chat', id: conversationId }], messageId);
    if (eventChainId) dispatch(wsChainViewRefreshRequested(`chat_event:${focusedChainId || eventChainId}:${messageId}`));
    return;
  }
  if (isStatusOnlyEvent) {
    if (agentId) applyLegacyStatusPatch(dispatch, payload, agentId);
    return;
  }
  if (conversationId && direction !== 'agent_to_agent') expireConversationOptions(conversationId);
  if (!message && payload.fetch_required && String(payload.fetch_kind || '') === 'chat_message') {
    // TODO(FIX): Replace loose fallback chain with canonical typed schema property
    const messageId = String(payload.fetch_id || payload.message_id || '');
    if (conversationId) dispatch(heimdallApi.util.invalidateTags([{ type: 'Chat', id: conversationId }, { type: 'ConversationSummaries', id: conversationId }]));
    if (messageId) {
      dispatch(chatEndpoints.endpoints.fetchChatMessage.initiate({ messageId }, { subscribe: false })).unwrap().catch(() => undefined);
    }
    return;
  }
  if (eventChainId) {
    dispatch(wsChainViewRefreshRequested(`chat_event:${focusedChainId || eventChainId}:${payload.message_id || ''}`));
  }

  if (message && agentId) {
    applyChatMessageToCaches(dispatch, message, payload.message, agentId, eventChainId, ctx);
  }

  if (!message) {
    if (agentId === GUIDE_AGENT_ID) {
      dispatch(heimdallApi.util.invalidateTags([{ type: 'GuideChat', id: GUIDE_AGENT_ID }]));
    } else if (agentId) {
      dispatch(heimdallApi.util.invalidateTags([{ type: 'Chat', id: agentId }]));
    }
    if (conversationId) dispatch(heimdallApi.util.invalidateTags([{ type: 'Chat', id: conversationId }, { type: 'ConversationSummaries', id: conversationId }]));
    dispatch(heimdallApi.util.invalidateTags([{ type: 'ConversationSummaries', id: 'ALL' }]));
  }
  // UI-14: a legacy inline chat event can still change the sidebar's unread badges.
  // Scoped to the conversation row when every loaded sidebar list holds it.
  queueMessageInvalidation(dispatch, conversationId, []);
}

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function handleMemoryEvent(dispatch: any, payload: any) {
  dispatch(memoryEventReceived(payload));
  patchMemoryCachesFromWs(dispatch, payload);
}

function handleCardEvent(dispatch: any, payload: any) {
  const cardId = String(payload?.card_id || payload?.id || payload?.record?.card_id || '');
  if (cardId) {
    dispatch(heimdallApi.util.invalidateTags([
      { type: 'Card', id: cardId },
      { type: 'Cards', id: 'LIST' },
    ]));
  } else {
    dispatch(heimdallApi.util.invalidateTags([{ type: 'Cards', id: 'LIST' }]));
  }
}

// Ephemeral agent-activity bubble event (P1 wire contract:
// { type:'agent_action', instance_id, action, summary, ts }). Routed ONLY to the
// transient agentActivity slice — it MUST NOT touch any RTK Query cache (no
// invalidateTags/updateQueryData) and never triggers a refetch. Fire-and-forget
// presence signal; buffered per-instance so it can replay when the user opens
// that conversation (see AgentActivityBubbles, P3).
// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function handleAgentActionEvent(dispatch: any, payload: any) {
  const instanceId = String(payload?.instance_id || '');
  const summary = String(payload?.summary || '');
  if (!instanceId || !summary) return;
  dispatch(agentActionReceived({
    instanceId,
    action: String(payload?.action || ''),
    summary,
    ts: Number(payload?.ts) || Date.now(),
  }));
}

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function handleMergeDecisionPending(dispatch: any, payload: any, ctx: WsCtx) {
  const chainId = String(payload.chain_id || '');
  if (chainId && ctx.focusedChainId === chainId) {
    dispatch(wsChainViewRefreshRequested(`merge_decision_pending:${chainId}`));
  }
  if (chainId) {
    dispatch(heimdallApi.util.invalidateTags([
      { type: 'Workspace', id: chainId },
      { type: 'WorkspaceDiff', id: `${chainId}:` },
    ]));
  }
  dispatch(attentionEventReceived());
}

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
function handleAgentEvent(dispatch: any, payload: any, ctx: WsCtx) {
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const agentId = String(payload.target_agent_instance_id || payload.agent_instance_id || payload.agent?.agent_instance_id || payload.record?.agent_instance_id || '');
  patchAgentCachesFromWs(dispatch, payload);
  dispatch(wsRefreshRequested(`${payload.type}:${agentId}`));
  if (ctx.focusedChainId) {
    dispatch(wsChainViewRefreshRequested(`${payload.type}:${agentId}`));
  }
}

// UI-BE-7: the hub's event bus (src/hub/service/events/event_bus.odin) emits a
// single generic envelope `{ type: 'resource_changed', resource, resource_id,
// change, summary }` for every durable resource mutation, rather than the
// legacy per-domain `task_event`/`agent_update` types. This is the ONLY event
// shape the rewrite hub sends, so task/chain views only update live if we handle
// it here. We invalidate the smallest RTK Query tags for the changed resource;
// RTK Query refetches only entries with an active subscriber, so this scopes the
// refetch to whatever the UI is currently showing.
// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
/**
 * Repaint everything that reads a shell session, from one event.
 *
 * Two kinds of tag, because several consumers cache a session and REQ-SHELL-6 §6
 * leaves no poller to catch whichever one is missed:
 *   ShellSession:<id>        the detail view, the run indicator and the log viewer
 *   ShellSessions:q:<path>   each mounted `listShells` entry that may hold the session
 *
 * One run is three frames (shell_session_started, resource_changed "running",
 * shell_session_exited) and every tab mounts several list keys (status bar, aux
 * launcher, one run list per conversation shown). Invalidating `ShellSessions:LIST`
 * per frame refetched every key three times per run. Instead the frame names only the
 * cached lists `shellListMayContain` cannot rule out — a run never reaches a chain or
 * bridge list, and another agent's run never reaches this agent's run list — and the
 * tags go through the same burst window as every other targeted invalidation, so a
 * quick start/running/exit costs one refetch per list. Whenever the session or the
 * cached lists cannot be read, the frame falls back to `ShellSessions:LIST`.
 *
 * `facts` are what the frame itself states: shell_session_started carries kind and
 * chain_id (omitted when empty, _shell_session_started_event_json), the REQ-2 change
 * frame carries chain_id; shell_session_exited carries neither. The scope columns of a
 * session never change, so a row already in any cache supplies the rest.
 */
function invalidateShellSession(dispatch: any, sessionId: string, facts: ShellSessionFacts = {}): void {
  const tags: Array<{ type: string; id: string }> = [];
  if (sessionId) tags.push({ type: 'ShellSession', id: sessionId });
  const lists = sessionId ? shellListTagsFor(readState(dispatch), sessionId, facts) : null;
  if (lists) tags.push(...lists);
  else tags.push({ type: 'ShellSessions', id: 'LIST' });
  queueInvalidation(dispatch, tags);
  // ...and tick the non-RTK consumers. The Shells list page pages through
  // `useInfiniteList` with its own fetch promise, so no tag above can reach it; see
  // shellSlice.ts for why that page needs a separate signal rather than a poller.
  dispatch(shellSessionEventReceived({ sessionId }));
}

// The per-entry tags of the cached lists that may hold the session; null when the
// cache cannot be read, which means "refetch them all".
function shellListTagsFor(state: any, sessionId: string, facts: ShellSessionFacts): Array<{ type: string; id: string }> | null {
  if (!state?.[heimdallApi.reducerPath]) return null;
  try {
    const args = shellsApi.util.selectCachedArgsForQuery(state, 'listShells') as any[];
    const known: ShellSessionFacts = { ...facts };
    const rows: any[] = [shellsApi.endpoints.getShellSession.select({ sessionId })(state)?.data];
    for (const arg of args) rows.push(...(shellsApi.endpoints.listShells.select(arg)(state)?.data?.sessions ?? []));
    const row = rows.find((r) => r?.session_id === sessionId);
    if (row) {
      for (const key of ['kind', 'bridge_id', 'project_id', 'chain_id', 'agent_instance_id'] as const) {
        if (typeof row[key] === 'string') (known as Record<string, string>)[key] = row[key];
      }
    }
    return args
      .filter((arg) => shellListMayContain(arg || {}, known))
      .map((arg) => ({ type: 'ShellSessions', id: shellListTagId(arg || {}) }));
  } catch {
    return null;
  }
}

// A frame's own statement of a field, or undefined when the frame does not carry it.
function stated(payload: any, key: string): string | undefined {
  return payload && typeof payload[key] === 'string' ? payload[key] : undefined;
}

// agent_instance/<created|status_changed|config_changed|current_task_changed> carry the
// COMPLETE instance summary (publish_instance_changed, resource_events.odin). Fields
// present in it are patched in place, guarded by updated_at so a late frame never
// overwrites a newer fetch. Patched fields are the ones the summary owns; anything else
// on the cached row (project, agent, timestamps the summary lacks) is left as fetched.
const INSTANCE_SUMMARY_FIELDS = [
  'runtime_status', 'startup_status', 'activity_status', 'display_name', 'bridge_id',
  'provider', 'model', 'configuration_revision', 'run_count', 'started_at',
  'current_task_id', 'current_task_role', 'chain_id', 'updated_at',
] as const;

function isNewerOrEqual(next: unknown, current: unknown): boolean {
  const a = String(next || '');
  const b = String(current || '');
  return !a || !b || a >= b;
}

// Returns false when the frame is older than the cached instance (nothing is patched).
function patchInstanceCachesFromSummary(dispatch: any, instanceId: string, summary: any): boolean {
  let stale = false;
  let errorStale = false;
  dispatch(agentsApi.util.updateQueryData('fetchAgentInstance', { instanceId }, (draft: any) => {
    const instance = draft?.instance;
    if (!instance) return;
    if (!isNewerOrEqual(summary.updated_at, instance.updated_at)) { stale = true; return; }
    // The summary does not carry last_error, so it is never patched or cleared here. A
    // runtime transition into failure (or out of a state that holds an error) changes
    // it, and the failure notice needs the reason: refetch that one instance.
    const nextStatus = summary.runtime_status === undefined ? undefined : String(summary.runtime_status || '');
    if (nextStatus !== undefined && nextStatus !== String(instance.runtime_status || '') && (nextStatus === 'failed' || instance.last_error)) {
      errorStale = true;
    }
    for (const field of INSTANCE_SUMMARY_FIELDS) {
      if (summary[field] !== undefined) instance[field] = summary[field];
    }
  }));
  // The sidebar rows and live tree carry no updated_at; the cached instance is the
  // version reference for them too.
  if (stale) return false;
  if (errorStale) queueInvalidation(dispatch, [{ type: 'AgentInstances', id: instanceId }]);
  dispatch((d: any, getState: () => any) => {
    const state = getState();
    for (const arg of sidebarApi.util.selectCachedArgsForQuery(state, 'listSidebarConversations') as any[]) {
      d(sidebarApi.util.updateQueryData('listSidebarConversations', arg, (draft: any) => {
        for (const row of Array.isArray(draft) ? draft : []) {
          if (row?.agentInstanceId !== instanceId) continue;
          if (summary.runtime_status !== undefined) row.runtimeStatus = String(summary.runtime_status || '') || undefined;
          if (summary.activity_status !== undefined) row.activityStatus = String(summary.activity_status || '') || undefined;
          if (summary.bridge_id !== undefined) row.bridgeId = String(summary.bridge_id || '') || undefined;
        }
      }));
    }
  });
  // /agents/live lists only chains with a live agent and those chains' live agents, so a
  // runtime_status change can add or remove rows: that refetches (coalesced). Activity
  // and display name are patched in place.
  let liveTreeStale = false;
  dispatch(agentsLiveApi.util.updateQueryData('getAgentsLive', undefined, (draft: any) => {
    let found = false;
    for (const project of Array.isArray(draft) ? draft : []) {
      for (const chain of project?.chains || []) {
        for (const agent of [...(chain?.liveAgents || []), ...(chain?.members || [])]) {
          if (agent?.agentInstanceId !== instanceId) continue;
          found = true;
          if (summary.runtime_status !== undefined && String(summary.runtime_status || '') !== agent.runtimeStatus) liveTreeStale = true;
          if (summary.activity_status !== undefined && 'activityStatus' in agent) agent.activityStatus = String(summary.activity_status || '');
          if (summary.display_name) agent.displayName = String(summary.display_name);
        }
      }
    }
    if (!found && summary.chain_id && summary.runtime_status !== undefined) liveTreeStale = true;
  }));
  if (liveTreeStale) queueInvalidation(dispatch, [{ type: 'AgentsLive', id: 'ALL' }]);
  return true;
}

function handleInstanceChanged(dispatch: any, payload: any, ctx: WsCtx, instanceId: string, change: string, summary: any): void {
  if (instanceId && !patchInstanceCachesFromSummary(dispatch, instanceId, summary)) return;
  // Membership/placement of the live tree changes on create, current task (is_live,
  // role) and config (bridge); plain status is already patched above.
  if (change === 'created' || change === 'current_task_changed' || change === 'config_changed') {
    queueInvalidation(dispatch, [{ type: 'AgentsLive', id: 'ALL' }]);
  }
  if (change === 'created') {
    queueInvalidation(dispatch, [{ type: 'AgentInstances', id: 'LIST' }, { type: 'SidebarConversations', id: 'ALL' }]);
  }
  // Legacy caches + the "identity missing from the catalogue" check (agents.ts).
  handleAgentEvent(dispatch, { ...payload, type: 'agent_update', agent_instance_id: instanceId, summary }, ctx);
}

/**
 * Provider extension frames on an agent instance (REQ-EXT-BLK-1, REQ-EXT-SUB-2):
 *   'agent_blockers_changed' {agent_instance_id, revision, count}
 * Permission cards refetch current transient state while a conversation is watched.
 * Returns false for other changes so the generic agent path handles them.
 */
function handleAgentInstanceExtensionChange(dispatch: any, instanceId: string, change: string, summary: any): boolean {
  if (change === AGENT_BLOCKERS_CHANGE) {
    const id = instanceId || String(summary?.agent_instance_id || '');
    if (id) queueInvalidation(dispatch, [{ type: 'AgentBlockers', id }]);
    return true;
  }
  return false;
}

function handleResourceChanged(dispatch: any, payload: any, ctx: WsCtx) {
  const resource = String(payload.resource || '');
  const resourceId = String(payload.resource_id || '');
  const summary = payload.summary || {};
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const chainId = String(summary.chain_id || (resource === 'task_chain' ? resourceId : '') || '');
  // TODO(FIX): Replace loose fallback chain with canonical typed schema property
  const taskId = String(summary.task_id || (resource === 'task' ? resourceId : '') || '');
  dispatch(wsRefreshRequested(`resource_changed:${resource}:${resourceId}`));

  switch (resource) {
    case 'task': {
      const change = String(payload.change || '');
      // A facet write names (task, attempt, kind): refetch that facet only, not the
      // task, its log or the chain lists.
      if (change === 'facet_changed' && taskId) {
        const attemptNo = Number(summary.attempt_no || 0);
        const kind = String(summary.kind || '');
        queueInvalidation(dispatch, attemptNo && kind
          ? [{ type: 'TaskFacet', id: `${taskId}:${attemptNo}:${kind}` }]
          : [{ type: 'Task', id: taskId }]);
        return;
      }
      // Auto-load the specific updated task with in-flight deduplication and patch caches:
      if (taskId) {
        autoLoadTaskFromWs(dispatch, chainId, taskId);
      }

      // Granular tag invalidation: invalidate Task, TaskLog, TaskComments for taskId,
      // ChainList ('ALL') for chain-level task count rollups, and PINNED_LIST + GROUPED_LIST
      // so sidebar chain attention badges and rollups clear dynamically without full refresh.
      const tags: any[] = [
        { type: 'ChainList', id: 'ALL' },
        { type: 'Chain', id: 'PINNED_LIST' },
        { type: 'Chain', id: 'GROUPED_LIST' },
      ];
      // Workflow run views show their tasks' states.
      if (chainId) tags.push({ type: 'WorkflowRuns', id: chainId });
      if (taskId) {
        tags.push({ type: 'Task', id: taskId });
        tags.push({ type: 'TaskLog', id: taskId });
        tags.push({ type: 'TaskComments', id: taskId });
      }
      dispatch(heimdallApi.util.invalidateTags(tags));
      if (chainId && ctx.focusedChainId === chainId) {
        dispatch(wsChainViewRefreshRequested(`resource_changed:task:${taskId || resourceId}`));
      }
      return;
    }
    case 'task_chain': {
      if (payload.change === 'created') announceTaskChainCreated(chainId);
      // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
      const tags: any[] = [
        { type: 'ChainList', id: 'ALL' },
      ];
      if (chainId) {
        tags.push(
          { type: 'Chain', id: chainId },
          { type: 'ChainTasks', id: chainId },
        );
      }
      // Queued with the workflow tags below so one chain change refetches each mounted
      // chain/run view once (the run list is also tagged Chain:<id>).
      queueInvalidation(dispatch, tags);
      // Chain membership/coordinator/title feed the live tree; workflow_* changes carry
      // workflow_run_id and reach the run views.
      const chainChange = String(payload.change || '');
      if (!/^(summary_updated|work_|proposal_|workflow_)/.test(chainChange)) {
        queueInvalidation(dispatch, [{ type: 'AgentsLive', id: 'ALL' }]);
      }
      if (chainChange.startsWith('workflow_') && chainId) {
        const runId = String(summary.workflow_run_id || '');
        queueInvalidation(dispatch, [{ type: 'WorkflowRuns', id: chainId }, ...(runId ? [{ type: 'WorkflowRuns', id: runId }] : [])]);
      }
      if (chainId && ctx.focusedChainId === chainId) {
        dispatch(wsChainViewRefreshRequested(`resource_changed:task_chain:${chainId}`));
      }
      const rawTitle = String(
        summary.title ||
        payload.title ||
        summary.raw_title ||
        summary.rawTitle ||
        payload.change?.title ||
        ''
      );
      if (rawTitle && chainId) {
        dispatchSearchTitleUpsert(dispatch, {
          id: chainId,
          type: 'chain',
          rawTitle,
          projectId: summary.project_id || payload.project_id || undefined,
          status: summary.status || payload.status || undefined,
          updatedAt: summary.updated_at || payload.updated_at || undefined,
        });
      }
      return;
    }
    case 'conversation': {
      // created: a new sidebar row (list-level); updated: title/metadata of one row and
      // its header. Neither changes the message pages.
      const change = String(payload.change || '');
      queueInvalidation(dispatch, [
        { type: 'ConversationSummaries', id: resourceId },
        { type: 'SidebarConversations', id: change === 'created' ? 'ALL' : resourceId },
      ]);
      const rawTitle = String(
        summary.title ||
        payload.title ||
        summary.raw_title ||
        summary.rawTitle ||
        payload.change?.title ||
        ''
      );
      if (rawTitle && resourceId) {
        dispatchSearchTitleUpsert(dispatch, {
          id: resourceId,
          type: 'conversation',
          rawTitle,
          projectId: summary.project_id || payload.project_id || undefined,
          updatedAt: summary.updated_at || payload.updated_at || undefined,
        });
      }
      return;
    }
    // REQ-SHELL-6 §6. The convergence path reports adopt/correct as a GENERIC
    // resource_changed (shell_session_inventory.odin:427) rather than as an exit,
    // because those are not exits — see the comment at that call site. Without this
    // case the payload fell through to `default: return` below and the correction was
    // silently dropped, which is precisely the class of update the deleted pollers
    // were papering over.
    case 'shell_session':
      invalidateShellSession(dispatch, resourceId, { chain_id: stated(payload, 'chain_id') });
      return;
    case 'agent_instance':
      if (handleAgentInstanceExtensionChange(dispatch, resourceId, String(payload.change || ''), summary)) return;
      handleInstanceChanged(dispatch, payload, ctx, resourceId, String(payload.change || ''), summary);
      return;
    case 'agent_instance_reconfiguration':
      // resource_id is the INSTANCE id. Every phase advance is announced, so the
      // operation view needs no client poll; settling invalidates the instance,
      // header and messages (listInstanceReconfigurations.onQueryStarted).
      queueInvalidation(dispatch, [{ type: 'InstanceReconfigurations', id: resourceId }]);
      return;
    case 'workflow_run': {
      queueInvalidation(dispatch, [
        { type: 'WorkflowRuns', id: resourceId },
        ...(chainId ? [{ type: 'WorkflowRuns', id: chainId }] : []),
      ]);
      if (chainId && ctx.focusedChainId === chainId) {
        dispatch(wsChainViewRefreshRequested(`resource_changed:workflow_run:${resourceId}`));
      }
      return;
    }
    case 'agent_id':
    case 'agent': {
      // Reuse the agent patch/refresh path; patchAgentCachesFromWs tolerates the
      // resource_changed shape (reads agent_instance_id/record fields defensively).
      // Forward the summary (runtime/startup/activity) so the caches can be patched
      // IN PLACE without refetching the whole /agents list on every status change.
      handleAgentEvent(dispatch, { ...payload, type: 'agent_update', agent_instance_id: resourceId, summary }, ctx);
      return;
    }
    case 'vault_devices':
    case 'vault_directory': {
      // Passwordless vault: never carries a code. Re-verify the directory; a new
      // pending device raises a toast / attention entry on approved devices.
      handleVaultDirectoryEvent(dispatch, resource, resourceId, String(payload.change || ''));
      return;
    }
    case 'bridge': {
      // Patch the mounted bridge list from the event's summary first.
      let patched = false;
      dispatch(bridgeSupportApi.util.updateQueryData('listBridges', undefined, (draft: any) => {
        const rows = Array.isArray(draft?.bridges) ? draft.bridges : [];
        const bridge = rows.find((row: any) => String(row?.bridge_id || row?.id || '') === resourceId);
        if (bridge) { Object.assign(bridge, summary); patched = true; }
      }));
      const change = String(payload.change || '');
      // update_progress (a burst per update) and vault_status_changed carry every
      // field they change, so a patched row needs no refetch. status_changed also
      // moves fields the summary lacks (runtime_connected, last_seen_at), and
      // enrollment changes add or remove rows, so those refetch the (cheap, plain) list.
      if (patched && (change === 'update_progress' || change === 'vault_status_changed')) return;
      const tags: any[] = [
        { type: 'Bridges', id: 'LIST' },
        { type: 'Bridges', id: resourceId },
      ];
      // Provider discovery/enable announce provider_status_changed/capabilities_changed;
      // a bridge coming online may also have rediscovered them. Only mounted
      // provider-status entries for THIS bridge refetch.
      if (change === 'provider_status_changed' || change === 'capabilities_changed') {
        queueInvalidation(dispatch, [{ type: 'BridgeProviders', id: resourceId }]);
        return;
      }
      if (change === 'status_changed' && String(summary?.status || '').toLowerCase() === 'online') {
        tags.push({ type: 'BridgeProviders', id: resourceId });
      }
      dispatch(heimdallApi.util.invalidateTags(tags));
      return;
    }
    default:
      return;
  }
}

// The user WebSocket is fire-and-forget fanout with no per-client replay: any
// event emitted while we were disconnected is lost. After the socket re-opens we
// therefore invalidate every RTK Query tag so the cache re-fetches whatever the
// UI is currently showing. RTK Query only refetches entries that still have an
// active subscriber, so this is scoped to mounted queries (not a blanket reload)
// and dedupes concurrent invalidations. Call this ONLY on a genuine reconnect,
// not the first connect (initial mounts already fetch their data).
// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
// Every tag type is included, catalogues too: templates, workflow definitions, LSP
// configs and experiments can be edited from another tab, device or the CLI while this
// socket was down, and nothing else would tell a mounted picker. Only mounted queries
// refetch, so an unmounted catalogue costs nothing.
export function resyncAfterReconnect(dispatch: any) {
  // Anything queued is superseded by the full invalidation below.
  resetQueuedInvalidations();
  dispatch(heimdallApi.util.invalidateTags([...HEIMDALL_TAG_TYPES]));
  // Non-RTK consumers: the paged shells list and the chain view refresh on their own
  // signals, which no tag reaches. The conversation pane re-anchors its older pages
  // when the refetched newest page no longer overlaps them (AgentChatPane).
  dispatch(shellSessionEventReceived({ sessionId: '' }));
  dispatch(wsChainViewRefreshRequested('user_ws_resync'));
}

// Attention deck: attention_changed is an invalidation hint only ({kinds}, no
// counts). One user action can still produce a few hints (e.g. a reply sends the
// message and marks it read, which may straddle the hub's 500ms window), so a
// burst is coalesced here into ONE invalidation. Only the query on screen has a
// subscriber -- the bar summary, or the open deck -- so that is one request; RTK
// defers an invalidation that lands mid-fetch until the fetch settles.
export const ATTENTION_REFETCH_COALESCE_MS = 300;
let attentionRefetchTimer: ReturnType<typeof setTimeout> | null = null;

function scheduleAttentionRefetch(dispatch: any) {
  if (attentionRefetchTimer) return;
  attentionRefetchTimer = setTimeout(() => {
    attentionRefetchTimer = null;
    dispatch(heimdallApi.util.invalidateTags([{ type: 'Attention', id: 'ALL' }]));
  }, ATTENTION_REFETCH_COALESCE_MS);
}

// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
export function handleUserWsEvent(dispatch: any, payload: any, ctx: WsCtx = {}) {
  // Native (OS) notifications: fire from this single funnel for the curated
  // event set, gated to open-but-unfocused tabs. Implemented as a thunk so the
  // side-effectful service can read live settings via getState without a
  // circular store import. Never throws into the invalidation path.
  try {
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    dispatch((_dispatch: any, getState: any) => {
      try {
        fireNotificationForWsEvent(getState, payload);
      } catch (_err) {
        /* notifications must never break cache invalidation */
      }
    });
  } catch (_err) {
    /* ignore */
  }

  switch (payload?.type) {
    case 'task_event':
      handleTaskEvent(dispatch, payload);
      return;
    case 'chat_event':
      handleChatEvent(dispatch, payload, ctx);
      return;
    case 'chat_approval':
      dispatch(attentionEventReceived());
      return;
    case 'attention_changed':
      scheduleAttentionRefetch(dispatch);
      return;
    case 'memory_event':
      handleMemoryEvent(dispatch, payload);
      return;
    case 'card_event':
    case 'card_created':
    case 'card_updated':
    case 'card_discarded':
    case 'card_accepted':
    case 'card_rejected':
      handleCardEvent(dispatch, payload);
      return;
    case 'agent_action':
      handleAgentActionEvent(dispatch, payload);
      return;
    case 'audit_start':
      dispatch(auditStartedReceived(payload));
      return;
    case 'audit_end':
      dispatch(auditEndedReceived(payload));
      return;
    case 'merge_decision_pending':
      handleMergeDecisionPending(dispatch, payload, ctx);
      return;
    case 'agent_update':
    case 'agent_lifecycle_changed':
    case 'agent_runtime_changed':
      handleAgentEvent(dispatch, payload, ctx);
      return;
    case 'mcp_worker_available':
      void runMcpWorker();
      return;
    case 'resource_changed':
      handleResourceChanged(dispatch, payload, ctx);
      return;
    // REQ-SHELL-6 §6 — the shell UI is driven by PUSH, with no poller anywhere behind
    // it, so these two cases are the only thing that repaints a status now.
    //
    // `shell_session_exited` is what the hub actually emits when a session reaches a
    // terminal status (shell_session_service.odin:1342). `shell_status` was the type
    // this switch used to handle and NOTHING on the user bus has ever produced it: the
    // only `shell_status` frame in the hub is written by shell_session_broadcast_status
    // (shell_session_service.odin:240), which fans out to the per-session STREAM
    // sockets, not to this bus. It is kept as a co-case rather than deleted so that a
    // client attached to both channels behaves identically on either frame.
    // `shell_session_started` is the CREATION counterpart, and without it the push
    // model had no way to learn a session exists until it exited. A foreground run was
    // invisible for its entire life and then appeared already-finished, which also meant
    // the live-only controls — the spinner and the Background toggle — could never be
    // reached, since they render only while a run is live and foreground.
    case 'shell_session_started':
    case 'shell_status':
    case 'shell_session_exited':
      invalidateShellSession(dispatch, String(payload?.session_id || ''), payload?.type === 'shell_session_started'
        // The started frame omits chain_id when it is empty, so its absence is a fact.
        ? { kind: stated(payload, 'kind') as ShellSessionFacts['kind'], chain_id: stated(payload, 'chain_id') ?? '' }
        : { chain_id: stated(payload, 'chain_id') });
      // T10: a start the bridge refused because its vault is locked carries
      // error_code "vault_locked"; route it to the pane showing that session.
      announcePaneVaultLocked(String(payload?.session_id || ''), payload);
      return;
    default:
      return;
  }
}
