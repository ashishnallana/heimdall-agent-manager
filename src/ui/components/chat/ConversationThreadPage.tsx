import { conversationConfigurationIssues } from '../../utils/conversationConfigurationValidity';
import InstanceReconfigurationProgress from './InstanceReconfigurationProgress';
import TaskChainOverview from '../taskchain/TaskChainOverview';
import { TaskChainSelectorModal } from '../chains/TaskChainSelectorModal';
import ChainOverviewPanel from './ChainOverviewPanel';
import ProjectFilesPanel, { ProjectQuickOpenModal } from './ProjectFilesPanel';
import ProjectVcsPanel from './ProjectVcsPanel';
import AtMentionPopup, { type MentionEntity } from './AtMentionPopup';
import AgentPaneComposerPanel from './AgentPaneComposerPanel';
import { type ClipboardEvent, type FormEvent, type UIEvent, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  useFetchConversationQuery,
  useFetchConversationMessagesQuery,
  useLazyFetchConversationMessagesQuery,
  useUpdateConversationTitleMutation,
  useRequestPaneCaptureMutation,
  useSendConversationMessageMutation,
  useMarkConversationReadMutation,
} from '../../api/endpoints/chats';
import {
  useFetchAgentInstanceQuery,
  useFetchAgentIdentityQuery,
  useApplyInstanceConfigurationMutation,
  useRetryInstanceConfigurationMutation,
  useListInstanceReconfigurationsQuery,
  type InstanceReconfiguration,
  useRestartAgentInstanceMutation,
  useStopAgentInstanceMutation,
} from '../../api/endpoints/agents';
import { useCreateArtifactMutation } from '../../api/endpoints/artifacts';
import { useFetchProjectQuery } from '../../api/endpoints/projects';
import { useFetchExperimentsQuery } from '../../api/endpoints/settings';
import { useGetAgentsLiveQuery } from '../../api/endpoints/agentsLive';
import { ArtifactAttachmentPreview } from '../ArtifactAttachmentPreview';
import {
  normalizeBridgeCapabilities,
  useListBridgesQuery,
  type BridgeCapability,
} from '../../api/endpoints/bridgeSupport';
import { useSelector } from 'react-redux';
import { MAX_UPLOAD_BYTES } from '../ArtifactUpload';
import Markdown from '../Markdown';
import { VaultText } from '../vault/VaultText';
import {
  isVaultArmored,
  containsVaultArmored,
  decryptVaultText,
  decryptEmbeddedVaultTokens,
} from '../../utils/vaultContent';
import { selectActiveVaultKey } from '../../store/vaultSlice';
import ChatMessageList from './ChatMessageList';
import { CommandPalette, Drawer, Icon as UiIcon, Menu, Modal, StatusDot, runtimeStateFromStatus, runtimeStateLabel, runtimeStatusToTone } from '@ui';
import { buildRouteHash, getRoutePathname, getRouteSearch } from '../../utils/appLocation';
import {
  CHAT_VIEW_MIN_WIDTH,
  RIGHT_SIDEBAR_DEFAULT_WIDTH,
  RIGHT_SIDEBAR_MIN_WIDTH,
  clampRightSidebarWidth,
  readRightSidebarOpen,
  readRightSidebarTab,
  readRightSidebarWidth,
  writeRightSidebarOpen,
  writeRightSidebarTab,
  writeRightSidebarWidth,
  isRightSidebarTab,
  type RightSidebarTab,
} from '../../utils/clientPersistence';
import Icon from '../Icon';
import { MessageComposerInput, MessageComposerActions } from './MessageComposer';
import RuntimeConfigurationOptions from './RuntimeConfigurationOptions';
import { useFetchChainTasksQuery, useFetchTaskChainDetailQuery } from '../../api/endpoints/tasks';
import AgentActivityBubbles from './AgentActivityBubbles';
import { ClubbedRunGroup, PinnedShellRuns, pinnedRunSessions, ShellRunRow, useConversationRuns, type ShellRunMarker } from '../shells/ShellRunIndicator';
import { groupTranscriptMessages, isAgentStartMessage } from './transcriptGrouping';
import { type TaskLike } from './chainTaskInference';
import { useIsBelowTailwindSm, useIsMobile } from '../shell/responsive';
import { artifactKindForFile, artifactLinkFromResponse, artifactMimeForFile, artifactUploadName, clipboardFilesFromEvent } from '../../utils/artifactUpload';
import { describeCron, formatInTimeZone, timeZoneLabel } from '../actions/scheduleUtils';
import type { ChatDeliveryStatus, ChatMessage, ChatTimestamp } from './types';
import { resolveProjectVcsExperiment } from './projectVcsExperiment';

// e2e conversation thread for /conversations/{agentInstanceId}. Cookie-auth,
// hub-native. Fetches messages via /api/v1/chats/{id}/messages, sends via POST,
// marks read, and (per the launch composer) exposes provider/model selection for
// the bound instance — plus a Bridge indicator — so a live conversation can be
// reconfigured/restarted without leaving the page.

type Message = {
  message_id?: string;
  messageId?: string;
  id?: string;
  conversation_id?: string;
  conversationId?: string;
  direction?: string;
  body?: string;
  created_at?: string;
  createdAt?: string;
  created_unix_ms?: number | string;
  createdUnixMs?: number | string;
  delivered_at?: string;
  deliveredAt?: string;
  delivered_unix_ms?: number | string;
  deliveredUnixMs?: number | string;
  read_at?: string;
  readAt?: string;
  read_unix_ms?: number | string;
  readUnixMs?: number | string;
  delivery_failed_at?: string;
  deliveryFailedAt?: string;
  delivery_failed_unix_ms?: number | string;
  deliveryFailedUnixMs?: number | string;
  delivery_error?: string;
  deliveryError?: string;
  sender_agent_instance_id?: string;
  senderAgentInstanceId?: string;
  artifact_ids?: string[];
  artifactIds?: string[];
  artifact_ids_json?: string;
  artifactIdsJson?: string;
  message_type?: string;
  messageType?: string;
  message_status?: string;
  messageStatus?: string;
  metadata?: any;
  metadata_json?: string;
  metadataJson?: string;
  sending?: boolean;
};

type PendingAttachment = {
  localId: string;
  id: string;
  name: string;
  file: File;
  status: 'uploading' | 'uploaded' | 'error';
  error: string;
};

const modelOrder = ['cheap', 'normal', 'smart'];

// RTK Query queryFn errors reject with `{ status: 'CUSTOM_ERROR', error: '...' }`
// (not an Error), so `err.message` is undefined and String(err) => "[object
// Object]". Extract the real message from every shape we produce.
function errMsg(err: any, fallback: string): string {
  if (!err) return fallback;
  if (typeof err === 'string') return err;
  return String(err.message || err.error || err.data?.error?.message || err.data?.message || fallback);
}

const EMPTY_TIMESTAMP: ChatTimestamp = { label: '', iso: '' };
const EMPTY_DELIVERY: ChatDeliveryStatus = { glyph: '', label: '', tone: '' };

function bridgeId(bridge: any): string { return String(bridge?.bridge_id || bridge?.bridgeId || bridge?.id || ''); }
function msgId(m: Message, i: number): string { return String(m.message_id || m.messageId || m.id || `idx-${i}`); }
function msgDir(m: Message): string { return String(m.direction || ''); }

function extractMessageArtifactIds(message: Message): string[] | undefined {
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

  const direct = (message as any).artifact_ids ?? (message as any).artifactIds;
  if (Array.isArray(direct)) direct.forEach(push);

  const artifactIdsJson = (message as any).artifact_ids_json ?? (message as any).artifactIdsJson;
  if (typeof artifactIdsJson === 'string' && artifactIdsJson.trim()) {
    try {
      const parsed = JSON.parse(artifactIdsJson);
      if (Array.isArray(parsed)) parsed.forEach(push);
    } catch (e) {}
  } else if (Array.isArray(artifactIdsJson)) {
    artifactIdsJson.forEach(push);
  }

  const body = String(message.body || '');
  const artifactLinkPattern = /artifact:\/\/([A-Za-z0-9._:-]+)/g;
  let match: RegExpExecArray | null;
  while ((match = artifactLinkPattern.exec(body)) !== null) push(match[1]);

  return out.length ? out : undefined;
}

function localMessageId(): string {
  return `local_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
}

function optimisticUserMessage(conversationId: string, body: string): Message {
  return {
    message_id: localMessageId(),
    conversation_id: conversationId,
    direction: 'user_to_agent',
    body,
    created_unix_ms: Date.now(),
    sending: true,
  };
}

function optimisticPaneCaptureMessage(conversationId: string, requestId: string, agentInstanceId: string): Message {
  return {
    message_id: `local_${requestId}`,
    conversation_id: conversationId,
    direction: 'agent_to_user',
    body: 'Requesting pane capture...',
    message_type: 'pane_capture',
    message_status: 'pending',
    metadata: { pane_capture_request_id: requestId, agent_instance_id: agentInstanceId, width: 80, line_limit: 120 },
    created_unix_ms: Date.now(),
    sending: true,
  };
}

function sentMessageFromResult(result: any): Message | null {
  const candidate = result?.message || result?.chat_message || result?.chatMessage || result;
  if (!candidate || typeof candidate !== 'object') return null;
  const id = String(candidate.message_id || candidate.messageId || candidate.id || '');
  const body = String(candidate.body || '');
  if (!id && !body) return null;
  return { ...candidate, sending: false } as Message;
}

function failedLocalMessage(message: Message, error: string): Message {
  return {
    ...message,
    sending: false,
    delivery_failed_unix_ms: Date.now(),
    delivery_error: error,
  };
}

function failedPaneCaptureMessage(message: Message, error: string): Message {
  return {
    ...message,
    sending: false,
    body: error,
    message_status: 'failed',
    messageStatus: 'failed',
    metadata: { ...((message as any).metadata || {}), error_code: 'request_failed' },
  };
}

function PaneCaptureOutput({ body, messageId }: { body: string; messageId: string }) {
  const preRef = useRef<HTMLPreElement | null>(null);

  useEffect(() => {
    const node = preRef.current;
    if (!node) return;
    const scrollToBottom = () => {
      node.scrollTop = node.scrollHeight;
    };
    scrollToBottom();
    const frame = typeof window !== 'undefined' ? window.requestAnimationFrame(scrollToBottom) : 0;
    return () => {
      if (frame && typeof window !== 'undefined') window.cancelAnimationFrame(frame);
    };
  }, [body, messageId]);

  return <pre ref={preRef} data-debug-id={`conversation-pane-capture-pre-${messageId}`} className="chat-scrollbar max-h-[420px] max-w-full overflow-auto whitespace-pre-wrap rounded-xl border border-subtle bg-surface p-3 font-mono text-xs leading-5 text-primary">{body}</pre>;
}

function ThreadMessageBody({ body }: { body: string }) {
  const isArmored = isVaultArmored(body);
  const containsArmored = containsVaultArmored(body);
  const hasVault = isArmored || containsArmored;
  // Key material lives only as a non-extractable CryptoKey (REQ-VAULT-HARDEN-1).
  // state.vault.rawVaultKeyHex is never assigned, so the old `rawKey || getActiveVaultKey()`
  // worked solely by its fallback, and the render gates below could show raw ciphertext
  // whenever the vault reported unlocked without a key. Both now test the real key.
  const activeKey = useSelector(selectActiveVaultKey);
  const [decrypted, setDecrypted] = useState<string | null>(null);

  useEffect(() => {
    let mounted = true;
    if (!hasVault) {
      setDecrypted(body);
      return;
    }
    if (!activeKey) {
      setDecrypted(null);
      return;
    }
    const decryptPromise = isArmored
      ? decryptVaultText(body, activeKey)
      : decryptEmbeddedVaultTokens(body, activeKey);
    decryptPromise
      .then((res) => {
        if (mounted) setDecrypted(res);
      })
      .catch(() => {
        if (mounted) setDecrypted(body);
      });
    return () => {
      mounted = false;
    };
  }, [body, hasVault, isArmored, activeKey]);

  if (isArmored && !activeKey) {
    return <VaultText value={body} as="div" />;
  }
  if (containsArmored && !activeKey) {
    const sanitized = body.replace(/vault:v1:[A-Za-z0-9+/=]+/g, '[🔒 Encrypted]');
    return <Markdown source={sanitized} compact copyAll={false} />;
  }
  return <Markdown source={decrypted !== null ? decrypted : body} compact copyAll={false} />;
}

function parseMessageMetadata(message: Message): any {
  const raw = (message as any).metadata ?? (message as any).metadata_json ?? (message as any).metadataJson;
  if (!raw) return {};
  if (typeof raw === 'object') return raw;
  try { return JSON.parse(String(raw)); } catch (_err) { return {}; }
}

// MSG-3: derive a human-readable schedule context line for a scheduled-action
// message from its metadata. The hub bridge_execute path may attach action
// context (cron_expr, timezone, target_run_at, action_id) to the action
// message's metadata_json; this reads it defensively so the card degrades
// gracefully to just the header when no metadata is present.
//   HOOK: once the hub emits these fields, the schedule summary + trigger time
//   appear automatically — no further UI change required.
function scheduleContextFromMetadata(metadata: any): { summary: string; triggeredAt: string } {
  const meta = metadata && typeof metadata === 'object' ? metadata : {};
  const cronExpr = String(meta.cron_expr ?? meta.cronExpr ?? meta.cron ?? '').trim();
  const timezone = String(meta.timezone ?? meta.time_zone ?? meta.tz ?? '').trim();

  let summary = '';
  if (cronExpr) {
    const described = describeCron(cronExpr);
    summary = timezone ? `${described} (${timezone})` : described;
  }

  let triggeredAt = '';
  const rawTrigger = String(meta.target_run_at ?? meta.targetRunAt ?? meta.triggered_at ?? meta.triggeredAt ?? '').trim();
  if (rawTrigger) {
    const date = new Date(rawTrigger);
    if (!Number.isNaN(date.getTime())) {
      triggeredAt = `${formatInTimeZone(date, timezone)} (${timeZoneLabel(date, timezone)})`;
    }
  }

  return { summary, triggeredAt };
}

function capModels(cap: BridgeCapability | undefined): string[] {
  if (!cap) return [];
  return Array.isArray(cap.models) ? cap.models.filter(Boolean) : [];
}

function coerceUnixMs(value: any): number {
  const parsed = Number(value ?? 0);
  if (!Number.isFinite(parsed) || parsed <= 0) return 0;
  return parsed < 1_000_000_000_000 ? parsed * 1000 : parsed;
}

function dateStringToUnixMs(value: any): number {
  const raw = String(value || '').trim();
  if (!raw) return 0;
  const parsed = Date.parse(raw);
  return Number.isFinite(parsed) ? parsed : 0;
}

function messageCreatedUnixMs(message: Message): number {
  return coerceUnixMs(message.created_unix_ms ?? message.createdUnixMs) || dateStringToUnixMs(message.created_at || message.createdAt);
}

function formatMessageTimestamp(unixMs: number): ChatTimestamp {
  if (!unixMs) return EMPTY_TIMESTAMP;
  const date = new Date(unixMs);
  if (Number.isNaN(date.getTime())) return EMPTY_TIMESTAMP;
  return { label: date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }), iso: date.toISOString() };
}

function looksLikeInternalId(value: string): boolean {
  return /^(agt|inst|chat|conv|usr|brg|task|chain|proj|art)_[a-z0-9]/i.test(String(value || '').trim());
}

function conversationAgentLabel(conversation: any): string {
  const candidates = [conversation?.agent_name, conversation?.agentName, conversation?.agent_display_name, conversation?.agentDisplayName, conversation?.agent_slug, conversation?.agentSlug];
  for (const value of candidates) {
    const trimmed = String(value || '').trim();
    if (trimmed && !looksLikeInternalId(trimmed)) return trimmed;
  }
  return '';
}

function conversationDisplayTitle(conversation: any, agentId: string, agentInstanceId: string, conversationId: string): string {
  const rawTitle = String(conversation?.title || '').trim();
  const agentLabel = conversationAgentLabel(conversation);
  if (!rawTitle || rawTitle === agentId || rawTitle === agentInstanceId || rawTitle === conversationId || looksLikeInternalId(rawTitle)) {
    return agentLabel || agentId || conversationId;
  }
  return rawTitle;
}

function runtimeNeedsStart(status: string): boolean {
  const normalized = String(status || '').toLowerCase();
  // `idle` is a live Bridge runtime state: the wrapper is connected and ready,
  // just not currently busy. Show Stop for idle/running/busy instances so users
  // can stop the real process instead of accidentally relaunching it.
  return !normalized || normalized === 'stopped' || normalized === 'failed' || normalized === 'unreachable';
}

function runtimeIsStopping(status: string): boolean {
  return String(status || '').toLowerCase() === 'stopping';
}

function deliveryStatusFor(message: ChatMessage): ChatDeliveryStatus {
  if (!message.isUser) return EMPTY_DELIVERY;
  if (message.sending) return { glyph: '…', label: 'Sending', tone: 'text-muted' };
  if (message.deliveryFailedUnixMs > 0) return { glyph: '!', label: message.deliveryError || 'Delivery failed', tone: 'text-danger' };
  if (message.readUnixMs > 0) return { glyph: '✓✓', label: 'Read', tone: 'text-success' };
  if (message.deliveredUnixMs > 0) return { glyph: '✓', label: 'Delivered', tone: 'text-muted' };
  return { glyph: '✓', label: 'Sent', tone: 'text-faint' };
}

function normalizeConversationMessages(rows: Message[], agentLabel: string): ChatMessage[] {
  const seen = new Set<string>();
  return rows
    .map((message, index) => {
      const id = msgId(message, index);
      const direction = msgDir(message);
      const isUser = direction === 'user_to_agent';
      const createdUnixMs = messageCreatedUnixMs(message);
      const sender = String(message.sender_agent_instance_id || message.senderAgentInstanceId || '');
      const messageType = String((message as any).message_type || (message as any).messageType || 'text');
      // SYS-2: the system message card is self-labeled ('System'), so suppress
      // the redundant generic author label above it. System notices arrive as
      // message_type='system' (direction is 'agent_to_user'), so key on the type,
      // not direction. ChatMessageList renders the label span unconditionally
      // with the timestamp beside it, so an empty label degrades cleanly
      // (timestamp still shows) without layout changes.
      const authorLabel = isUser ? 'you' : messageType === 'system' ? '' : (sender || agentLabel || 'agent');
      const artifactIds = extractMessageArtifactIds(message);
      return {
        order: index,
        chatMessage: {
          key: id || `${direction}-${createdUnixMs}-${index}`,
          messageId: id,
          body: String(message.body || ''),
          isUser,
          createdUnixMs,
          deliveredUnixMs: coerceUnixMs(message.delivered_unix_ms ?? message.deliveredUnixMs) || dateStringToUnixMs(message.delivered_at ?? message.deliveredAt),
          readUnixMs: coerceUnixMs(message.read_unix_ms ?? message.readUnixMs) || dateStringToUnixMs(message.read_at ?? message.readAt),
          deliveryFailedUnixMs: coerceUnixMs(message.delivery_failed_unix_ms ?? message.deliveryFailedUnixMs) || dateStringToUnixMs(message.delivery_failed_at ?? message.deliveryFailedAt),
          deliveryError: String(message.delivery_error || message.deliveryError || ''),
          sending: Boolean(message.sending),
          authorLabel,
          artifactIds,
          messageType,
          messageStatus: String((message as any).message_status || (message as any).messageStatus || 'complete'),
          metadata: parseMessageMetadata(message),
        } satisfies ChatMessage,
      };
    })
    .filter(({ chatMessage }) => {
      const key = chatMessage.messageId || chatMessage.key;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    })
    .sort((left, right) => {
      const lt = left.chatMessage.createdUnixMs;
      const rt = right.chatMessage.createdUnixMs;
      if (lt && rt && lt !== rt) return lt - rt;
      return left.order - right.order;
    })
    .map(({ chatMessage }) => chatMessage);
}

export const COMPOSER_DRAFT_KEY = 'heimdall:composer:draft';

export default function ConversationThreadPage({ agentInstanceId: routeInstanceId, focusMessageId }: { agentInstanceId: string; focusMessageId?: string }) {
  // The route is instance-id-only (#/conversations/{agentInstanceId}); an instance
  // maps 1:1 to a conversation, which we resolve via the O(1) by-instance endpoint.
  // New messages, read receipts and delivery status arrive live over the user WS
  // (`chat_event` -> wsInvalidation patches the `Chat`/`ConversationSummaries`
  // caches and invalidates the `Chat` tag for this conversation). Polling is only
  // a slow fallback for missed events, so we poll at 10s and pause when the tab is
  // unfocused so we don't hammer the hub in the background. (skipPollingIfUnfocused.)
  // No refetchOnMountOrArgChange: serve cached conversation instantly on switch
  // (keepUnusedDataFor keeps it warm); WS chat_event invalidation + the 10s poll
  // keep it fresh. This avoids a full /chats/by-instance fetch on every switch.
  const convQuery = useFetchConversationQuery({ conversationId: '', agentInstanceId: routeInstanceId }, { skip: !routeInstanceId, pollingInterval: 10000, skipPollingIfUnfocused: true });
  const conversation = convQuery.data?.conversation || null;
  // Message fetch/send/markRead stay keyed by conversation_id (server contract);
  // only the URL is instance-id. Resolve it from the fetched conversation.
  const conversationId = String(conversation?.conversation_id || conversation?.conversationId || '');
  // Do NOT force a refetch on every conversation switch: with keepUnusedDataFor
  // (30s) a recently-viewed thread renders instantly from cache, and the user WS
  // `chat_event` already invalidates this conversation's `Chat` tag when anything
  // changes. refetchOnMountOrArgChange:true made every switch blank the transcript
  // behind a "Loading messages…" gate while it re-hit the hub — the perceived hang.
  const messagesQuery = useFetchConversationMessagesQuery({ conversationId }, { skip: !conversationId, pollingInterval: 10000, skipPollingIfUnfocused: true });
  const [fetchOlderMessages, olderMessagesState] = useLazyFetchConversationMessagesQuery();
  const [updateConversationTitle, updateTitleState] = useUpdateConversationTitleMutation();
  const [requestPaneCapture, requestPaneCaptureState] = useRequestPaneCaptureMutation();
  const [sendMessage] = useSendConversationMessageMutation();
  const [markRead] = useMarkConversationReadMutation();
  const [reconfigureInstance, reconfigureState] = useApplyInstanceConfigurationMutation();
  const [retryConfiguration, retryConfigurationState] = useRetryInstanceConfigurationMutation();
  const [restartInstance, restartState] = useRestartAgentInstanceMutation();
  const [stopInstance, stopState] = useStopAgentInstanceMutation();
  const [createArtifact] = useCreateArtifactMutation();

  const agentId = String(conversation?.agent_id || conversation?.agentId || '');
  const agentInstanceId = String(conversation?.agent_instance_id || conversation?.agentInstanceId || routeInstanceId);
  const conversationRuntimeStatusForPoll = String(conversation?.runtime_status || conversation?.runtimeStatus || '');
  const chainId = String(conversation?.chain_id || conversation?.chainId || '');
  const title = conversationDisplayTitle(conversation, agentId, agentInstanceId, conversationId);

  const configurationInputBlockedRef = useRef(false);

  // Publish the Files panel's collected line comments as a single chat message to
  // this conversation's agent. Returns true on success so the panel clears its
  // in-memory store.
  const publishFileComments = useCallback(
    async (markdown: string): Promise<boolean> => {
      if (configurationInputBlockedRef.current || !conversationId || !markdown.trim()) return false;
      try {
        const res: any = await sendMessage({ conversationId, body: markdown }).unwrap();
        return !(res?.error);
      } catch {
        return false;
      }
    },
    [conversationId, sendMessage],
  );

  // Lightweight chain-task progress for the header "Task chain N/M" button, so
  // the coordinator's chain is one glance + one click away. Only fetched when the
  // conversation is linked to a chain.
  const chainTasksQuery = useFetchChainTasksQuery({ chainId }, { skip: !chainId });
  // Cookie-auth chain detail (works in the live shell, unlike the client-token
  // fetchChainTasks). Used to resolve the agent's current task for the working
  // indicator; polled modestly so the task title stays fresh.
  // Tasks change infrequently and task/chain mutations invalidate the Chain tag
  // over WS, so poll slowly (2 min) as a fallback rather than every 10s.
  const chainDetailQuery = useFetchTaskChainDetailQuery({ chainId }, { skip: !chainId, pollingInterval: 120000 });
  const chainProgress = useMemo(() => {
    // Prefer the cookie-auth chain detail (works in the live shell); fall back to
    // the legacy client-token fetchChainTasks. Without this the live shell always
    // read 0/0 because fetchChainTasks needs a client token the shell doesn't have.
    const allTasks: TaskLike[] = (chainDetailQuery.data?.chain?.tasks || chainTasksQuery.data?.tasks || []) as TaskLike[];
    const tasks = allTasks.filter((t: TaskLike) => t.status !== 'cancelled');
    const total = tasks.length;
    const done = tasks.filter((t: TaskLike) => t.status === 'validated_good' || t.status === 'completed').length;
    return { total, done };
  }, [chainDetailQuery.data, chainTasksQuery.data]);
  const rawTitle = String(conversation?.title || '').trim();
  const editableTitle = rawTitle && !looksLikeInternalId(rawTitle) ? rawTitle : title;
  const chainTitle = String(chainDetailQuery.data?.chain?.title || '').trim();

  // The instance record is the source of truth for the CONCRETE provider / model /
  // bridge this conversation runs on (never "default"/"Auto").
  // Adaptive polling: while the runtime is transitional (starting) poll fast so
  // the status chip settles quickly; once stable, poll moderately. The interval is
  // derived from the last-seen status tracked in a ref (updated after each read),
  // seeded from the conversation summary before the instance loads.
  const lastInstanceStatusRef = useRef('');
  const pollHint = lastInstanceStatusRef.current || conversationRuntimeStatusForPoll;
  const instancePollInterval = runtimeStateFromStatus(pollHint) === 'starting' ? 2500 : 8000;
  // No refetchOnMountOrArgChange: serve the cached instance runtime instantly on
  // switch. WS resource_changed(agent_instance) patches runtime/activity live,
  // reconfigure invalidates AgentInstances, and the poll below is the backstop.
  const instanceQuery = useFetchAgentInstanceQuery({ instanceId: agentInstanceId }, { skip: !agentInstanceId, pollingInterval: instancePollInterval, skipPollingIfUnfocused: true });
  const instance = instanceQuery.data?.instance || null;
  // Currently running agents across all projects/chains, for the composer's
  // agent-switcher picker (grouped by project → chain like the sidebar). Polled
  // slowly (the picker is a convenience, not a live surface).
  const { data: liveProjects } = useGetAgentsLiveQuery(undefined, { pollingInterval: 30000, skipPollingIfUnfocused: true });
  // Agent identity (name + persona/instructions) — used for the empty-state
  // welcome so a fresh conversation shows who you're talking to.
  const agentIdentityQuery = useFetchAgentIdentityQuery({ agentId }, { skip: !agentId });
  const agentIdentity = agentIdentityQuery.data?.agent || null;
  const agentDisplayName = String(agentIdentity?.name || conversationAgentLabel(conversation) || agentId || '').trim();
  const agentPersona = String(agentIdentity?.instructions || agentIdentity?.persona || agentIdentity?.template_persona || '').trim();
  useEffect(() => {
    const s = String(instance?.runtime_status || instance?.runtimeStatus || '');
    if (s) lastInstanceStatusRef.current = s;
  }, [instance?.runtime_status, instance?.runtimeStatus]);
  const instanceProvider = String(instance?.provider || '');
  const instanceModel = String(instance?.model || '');
  const instanceBridgeId = String(instance?.bridge_id || instance?.bridgeId || '');
  // Project the conversation/instance is scoped to — powers the Files (project
  // directory browser) tab. Prefer the live instance, fall back to conversation.
  const projectId = String(instance ? (instance.project_id ?? instance.projectId ?? '') : (conversation?.project_id || conversation?.projectId || ''));
  const experimentsQuery = useFetchExperimentsQuery();
  const projectVcsExperimentState = resolveProjectVcsExperiment(
    experimentsQuery.isLoading ? undefined : (experimentsQuery.data?.flags ?? []),
  );
  const projectVcsEnabled = projectVcsExperimentState === 'enabled';
  // Project display name for the composer chip (falls back to the id).
  const projectQuery = useFetchProjectQuery({ projectId }, { skip: !projectId });
  const projectName = String(projectQuery.data?.project?.name || projectQuery.data?.project?.display_name || projectId || '').trim();
  const conversationRuntimeStatus = String(conversation?.runtime_status || conversation?.runtimeStatus || '');
  const runtimeStatus = String(instance?.runtime_status || instance?.runtimeStatus || conversationRuntimeStatus || '');
  const startupStatus = String(instance?.startup_status || instance?.startupStatus || conversation?.startup_status || conversation?.startupStatus || '').toLowerCase();
  const isStarting = startupStatus === 'starting' || runtimeStateFromStatus(runtimeStatus) === 'starting';
  const activityStatus = String(instance?.activity_status || instance?.activityStatus || '').toLowerCase();
  const isWorking = runtimeStateFromStatus(runtimeStatus) === 'live' && (activityStatus === 'active' || activityStatus === 'busy' || activityStatus === 'working');


  const [stagedBridgeId, setStagedBridgeId] = useState<string | null>(null);
  const [provider, setProvider] = useState('');
  const [model, setModel] = useState('');
  const [runtimeMenuOpen, setRuntimeMenuOpen] = useState(false);
  // Connectivity is live: refresh promptly while editing and on settings open.
  const editingRuntime = runtimeMenuOpen || stagedBridgeId !== null || Boolean(provider && provider !== instanceProvider) || Boolean(model && model !== instanceModel);
  const bridgesQuery = useListBridgesQuery(undefined, { pollingInterval: editingRuntime ? 5000 : 30000, skipPollingIfUnfocused: true });
  useEffect(() => { if (runtimeMenuOpen) void bridgesQuery.refetch(); }, [runtimeMenuOpen]);
  const bridges = bridgesQuery.data?.bridges || [];
  const instanceBridge = useMemo(() => bridges.find((b: any) => bridgeId(b) === instanceBridgeId), [bridges, instanceBridgeId]);

  const baseMessages: Message[] = messagesQuery.data?.messages || [];
  const [olderMessages, setOlderMessages] = useState<Message[]>([]);
  const [olderCursor, setOlderCursor] = useState('');
  const [olderHasMore, setOlderHasMore] = useState(false);
  const [draft, setDraft] = useState<string>(() => {
    if (typeof window === 'undefined') return '';
    try {
      return window.localStorage.getItem(COMPOSER_DRAFT_KEY) || '';
    } catch {
      return '';
    }
  });

  const updateDraft = useCallback((value: string) => {
    setDraft(value);
    if (typeof window !== 'undefined') {
      try {
        if (value) {
          window.localStorage.setItem(COMPOSER_DRAFT_KEY, value);
        } else {
          window.localStorage.removeItem(COMPOSER_DRAFT_KEY);
        }
      } catch {
        // ignore storage errors
      }
    }
  }, []);
  const [isPaneExpanded, setIsPaneExpanded] = useState<boolean>(false);
  const userManuallyToggledPaneRef = useRef<boolean>(false);
  const prevRuntimeStatusRef = useRef<string>(runtimeStatus);
  const prevStartupStatusRef = useRef<string>(startupStatus);

  useEffect(() => {
    userManuallyToggledPaneRef.current = false;
    prevRuntimeStatusRef.current = runtimeStatus;
    prevStartupStatusRef.current = startupStatus;
  }, [agentInstanceId]);

  // REQ-STREAM-EVENT-3: Lifecycle event handlers for deterministic preview popup expansion and teardown
  const handleStreamReady = useCallback((_info?: any) => {
    if (!userManuallyToggledPaneRef.current) {
      setIsPaneExpanded(true);
    }
  }, []);

  const handleStreamClosed = useCallback((_info?: any) => {
    if (!userManuallyToggledPaneRef.current) {
      setIsPaneExpanded(false);
    }
  }, []);

  const handleStreamOutput = useCallback(() => {
    // REQ-STREAM-EVENT-3: stream popup auto-expansion is driven by stream_ready rather than raw stdout bytes
  }, []);

  useEffect(() => {
    const prevStatus = prevRuntimeStatusRef.current;
    prevRuntimeStatusRef.current = runtimeStatus;
    const prevStartup = prevStartupStatusRef.current;
    prevStartupStatusRef.current = startupStatus;

    if (isStarting && (prevStatus !== runtimeStatus || prevStartup !== startupStatus)) {
      userManuallyToggledPaneRef.current = false;
    }

    if (startupStatus === 'ready' && prevStartup !== 'ready') {
      if (!userManuallyToggledPaneRef.current) {
        setIsPaneExpanded(false);
      }
    }
  }, [runtimeStatus, startupStatus, isStarting]);
  // @-mention popup state: mentionQuery is the fragment typed after '@' (null when
  // the popup is closed); mentionIndex is the highlighted row for arrow-key nav.
  const [mentionQuery, setMentionQuery] = useState<string | null>(null);
  const [mentionIndex, setMentionIndex] = useState(0);
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const composerContainerRef = useRef<HTMLFormElement | HTMLDivElement | null>(null);
  const [error, setError] = useState('');
  const [attachments, setAttachments] = useState<PendingAttachment[]>([]);
  const [localMessages, setLocalMessages] = useState<Message[]>([]);
  const settingsEditedRef = useRef(false);
  const [acceptedOperation, setAcceptedOperation] = useState<InstanceReconfiguration | null>(null);
  const [reconfigStatus, setReconfigStatus] = useState('');
  const [isSmallComposer, setIsSmallComposer] = useState(false);
  // Flatten the live projects->chains->agents tree into a single @-mention list
  // (agents, projects, and task chains). liveProjects is LiveProject[] with the
  // camelCase shape from api/endpoints/agentsLive.ts.
  const mentionEntities = useMemo<MentionEntity[]>(() => {
    const items: MentionEntity[] = [];
    for (const proj of (liveProjects ?? [])) {
      const projectName = String(proj.name || proj.projectId || '');
      items.push({ type: 'project', id: String(proj.projectId || ''), label: projectName, sublabel: 'project' });
      for (const chain of (proj.chains ?? [])) {
        items.push({ type: 'chain', id: String(chain.chainId || ''), label: String(chain.title || chain.chainId || ''), sublabel: projectName });
        for (const agent of (chain.liveAgents ?? [])) {
          items.push({ type: 'agent', id: String(agent.agentInstanceId || ''), label: String(agent.displayName || agent.agentInstanceId || ''), sublabel: String(chain.title || '') });
        }
      }
    }
    return items;
  }, [liveProjects]);
  // Client-side fuzzy filter (label or id contains the query, case-insensitive),
  // capped at 8 items. Empty query shows the first 8 entities.
  const filteredMentions = useMemo(() => {
    if (mentionQuery === null) return [] as MentionEntity[];
    const q = mentionQuery.toLowerCase();
    return mentionEntities
      .filter((e) => !q || e.label.toLowerCase().includes(q) || e.id.toLowerCase().includes(q))
      .slice(0, 8);
  }, [mentionEntities, mentionQuery]);
  // Replace the '@fragment' immediately before the caret with '@<id>' and restore
  // focus/caret after React re-renders the textarea value.
  function handleMentionSelect(entity: MentionEntity) {
    const ta = textareaRef.current;
    const pos = ta?.selectionStart ?? draft.length;
    const before = draft.slice(0, pos);
    const after = draft.slice(pos);
    const newBefore = before.replace(/@([^\s@]*)$/, `@${entity.id}`);
    updateDraft(newBefore + after);
    setMentionQuery(null);
    setMentionIndex(0);
    setTimeout(() => { ta?.focus(); const np = newBefore.length; ta?.setSelectionRange(np, np); }, 0);
  }
  const isMobile = useIsMobile();
  // REQ-UI-DUP-1: the two right-panel branches below are shown/hidden by `sm:` classes
  // (`sm:hidden` / `hidden sm:flex`). Those are CSS visibility only — React mounts BOTH
  // subtrees at every width, so one opened file produced two ProjectFilesPanel instances,
  // two LSP sessions and two language-server processes on the bridge host. Gate each branch
  // in JS on the SAME 640px boundary its own classes already use, so exactly one mounts and
  // the rendered output is pixel-identical at every width. Deliberately 640 (Tailwind `sm:`)
  // and not MOBILE_MAX=767 — see `useIsBelowTailwindSm` and artifact art_18d7b91b4ac8743e item 9.
  const isBelowSm = useIsBelowTailwindSm();
  // Unified right-sidebar state. The top-right toggle opens/closes the panel; the
  // panel itself has Tasks / Files / RunDir tabs. 'closed' hides it entirely.
  // Initialized from ?panel= / ?sidebar= query param, falling back to UI storage.
  const [rightPanel, setRightPanel] = useState<'closed' | RightSidebarTab>(() => {
    const search = getRouteSearch();
    const params = new URLSearchParams(search.replace(/^\?/, ''));
    const param = params.get('panel') || params.get('sidebar');
    if (param) {
      const norm = param.trim().toLowerCase();
      if (norm === 'rundir') return 'files';
      if (isRightSidebarTab(norm)) return norm;
      if (norm === 'closed' || norm === 'false' || norm === '0') return 'closed';
      if (norm === 'open' || norm === 'true' || norm === '1') {
        return (chainId ? readRightSidebarTab({ chainId, instanceId: agentInstanceId }) : readRightSidebarTab(agentInstanceId)) || 'tasks';
      }
    }
    // Guard initial rightPanel state on mobile: !isMobile && readRightSidebarOpen()
    const open = !isMobile && (chainId ? readRightSidebarOpen({ chainId, instanceId: agentInstanceId }) : readRightSidebarOpen(agentInstanceId));
    if (open) {
      return (chainId ? readRightSidebarTab({ chainId, instanceId: agentInstanceId }) : readRightSidebarTab(agentInstanceId)) || 'tasks';
    }
    return 'closed';
  });

  const [sidebarWidth, setSidebarWidth] = useState<number>(() => readRightSidebarWidth());
  const [isDragging, setIsDragging] = useState(false);
  const [isRightPanelMaximized, setIsRightPanelMaximized] = useState(false);
  const [isQuickOpenOpen, setIsQuickOpenOpen] = useState(false);
  const [openSearchInFilesOnMount, setOpenSearchInFilesOnMount] = useState(false);
  const [openCommandPaletteOnMount, setOpenCommandPaletteOnMount] = useState(false);
  const [editorFileToOpen, setEditorFileToOpen] = useState<string | null>(null);
  const [vcsFileToOpen, setVcsFileToOpen] = useState<string | null>(null);
  const [focusedTaskId, setFocusedTaskId] = useState<string | null>(null);
  const containerRef = useRef<HTMLDivElement>(null);
  // Guards the one-shot chain-tab auto-open so it only fires once per conversation load.
  const chainAutoOpenedRef = useRef(false);
  const prevChainIdRef = useRef<string | null>(null);

  // When switching agents within the same chain, reset per-conversation local state
  // Input draft and attachments are retained across agent switching (REQ-COMPOSER-INPUT-PERSIST-29)
  useEffect(() => {
    setLocalMessages([]);
    setOlderMessages([]);
    setOlderCursor('');
    setOlderHasMore(false);
    setError('');
    setFocusedTaskId(null);
  }, [routeInstanceId]);

  // REQ-COMPOSER-MODEL-ICON-33: Track composer container width for compact model/provider selector icon button
  useEffect(() => {
    const el = composerContainerRef.current;
    if (!el || typeof ResizeObserver === 'undefined') return;
    const checkWidth = () => {
      if (typeof el.getBoundingClientRect === 'function') {
        const rect = el.getBoundingClientRect();
        setIsSmallComposer(rect.width > 0 && rect.width < 540);
      }
    };
    checkWidth();
    const observer = new ResizeObserver((entries) => {
      for (const entry of entries) {
        const width = entry.contentRect.width;
        setIsSmallComposer(width > 0 && width < 540);
      }
    });
    observer.observe(el);
    return () => observer.disconnect();
  }, [conversation?.conversation_id, conversation?.conversationId, agentInstanceId]);

  // REQ-SIDEBAR-5, REQ-SIDEBAR-TOGGLE-SINGLE-CLICK-10: coordinator conversations with a chainId default the right sidebar
  // to the 'chain' tab. Fires once when chainId first becomes available and the panel
  // is still closed (user hasn't explicitly chosen a tab or opened it manually).
  useEffect(() => {
    if (!chainId || isMobile || chainAutoOpenedRef.current) return;
    chainAutoOpenedRef.current = true;

    // Respect explicitly persisted closed state
    const isExplicitlyClosed = (() => {
      if (typeof window === 'undefined') return false;
      try {
        const chainRaw = window.localStorage.getItem(`heimdall:sidebar:open:chain:${chainId}`);
        if (chainRaw !== null) return chainRaw === 'false' || chainRaw === '0';
        if (agentInstanceId) {
          const instRaw = window.localStorage.getItem(`heimdall:sidebar:open:${agentInstanceId}`);
          if (instRaw !== null) return instRaw === 'false' || instRaw === '0';
        }
        return false;
      } catch {
        return false;
      }
    })();

    if (!isExplicitlyClosed) {
      setRightPanel((current) => (current === 'closed' ? 'chain' : current));
    }
  }, [chainId, isMobile, agentInstanceId]);

  // Synchronize sidebar state when agentInstanceId changes (REQ-UI-INSTANCE-SIDEBAR-TAB-PERSISTENCE, REQ-CHAIN-SIDEBAR-PERSIST-5)
  useEffect(() => {
    if (!agentInstanceId) return;

    // If chainId is present and unchanged (switching instance within the same chain),
    // preserve the current user-selected rightPanel tab without resetting or re-reading.
    if (chainId && prevChainIdRef.current === chainId) {
      return;
    }
    prevChainIdRef.current = chainId || null;

    const search = getRouteSearch();
    const params = new URLSearchParams(search.replace(/^\?/, ''));
    const param = params.get('panel') || params.get('sidebar');
    if (param) {
      const norm = param.trim().toLowerCase();
      if (norm === 'rundir') {
        setRightPanel('files');
        return;
      }
      if (isRightSidebarTab(norm)) {
        setRightPanel(norm);
        return;
      }
      if (norm === 'closed' || norm === 'false' || norm === '0') {
        setRightPanel('closed');
        return;
      }
    }
    const open = !isMobile && (chainId ? readRightSidebarOpen({ chainId, instanceId: agentInstanceId }) : readRightSidebarOpen(agentInstanceId));
    if (open) {
      setRightPanel((chainId ? readRightSidebarTab({ chainId, instanceId: agentInstanceId }) : readRightSidebarTab(agentInstanceId)) || 'tasks');
    } else {
      setRightPanel('closed');
    }
  }, [agentInstanceId, chainId, isMobile]);

  // A stale URL or persisted VCS tab may outlive experiment access. Wait until
  // flags have loaded so an enabled deep-link is preserved, then fail closed to
  // the same Tasks/Files fallback used by the panel renderer.
  useEffect(() => {
    if (projectVcsExperimentState !== 'disabled' || rightPanel !== 'vcs') return;
    const fallback: RightSidebarTab = chainId ? 'tasks' : (projectId || agentInstanceId) ? 'files' : 'tasks';
    setRightPanel(fallback);
    writeRightSidebarOpen(true, { chainId, instanceId: agentInstanceId });
    writeRightSidebarTab(fallback, { chainId, instanceId: agentInstanceId });
    syncUrlPanel(fallback);
  }, [projectVcsExperimentState, rightPanel, chainId, projectId, agentInstanceId]);

  // Global Cmd+P / Ctrl+P shortcut to trigger Quick Open across the conversation page (REQ-UI-GLOBAL-CMDP-EVERYWHERE)
  useEffect(() => {
    if (!projectId) return;
    const handleGlobalKeyDown = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && (e.key === 'p' || e.key === 'P') && !e.shiftKey) {
        e.preventDefault();
        setIsQuickOpenOpen((prev) => !prev);
      }
    };
    window.addEventListener('keydown', handleGlobalKeyDown);
    return () => window.removeEventListener('keydown', handleGlobalKeyDown);
  }, [projectId]);

  // Global Cmd+Shift+F / Ctrl+Shift+F shortcut to open files drawer (REQ-SEARCH-SHORTCUTS-1)
  useEffect(() => {
    if (!projectId) return;
    const handleGlobalSearchKeyDown = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && (e.key === 'f' || e.key === 'F') && e.shiftKey) {
        e.preventDefault();
        e.stopPropagation();
        if (rightPanel !== 'files') {
          setOpenSearchInFilesOnMount(true);
          selectRightPanelTab('files');
        }
      }
    };
    window.addEventListener('keydown', handleGlobalSearchKeyDown, true);
    return () => window.removeEventListener('keydown', handleGlobalSearchKeyDown, true);
  }, [projectId, rightPanel]);

  // Global Cmd+Shift+P / Ctrl+Shift+P and F1 shortcut to open Command Palette (REQ-EDITOR-COMMAND-PALETTE-1)
  useEffect(() => {
    if (!projectId) return;
    const handleGlobalCommandPaletteKeyDown = (e: KeyboardEvent) => {
      const isCmdShiftP = (e.metaKey || e.ctrlKey) && (e.key === 'p' || e.key === 'P') && e.shiftKey;
      const isF1 = e.key === 'F1';
      if (isCmdShiftP || isF1) {
        e.preventDefault();
        e.stopPropagation();
        if (rightPanel !== 'files') {
          setOpenCommandPaletteOnMount(true);
          selectRightPanelTab('files');
        }
      }
    };
    window.addEventListener('keydown', handleGlobalCommandPaletteKeyDown, true);
    return () => window.removeEventListener('keydown', handleGlobalCommandPaletteKeyDown, true);
  }, [projectId, rightPanel]);

  const handleQuickOpenSelectFile = (filePath: string) => {
    setIsQuickOpenOpen(false);
    selectRightPanelTab('files');
    setEditorFileToOpen(filePath);
  };

  // Sync state if hash/search changes while mounted (e.g. browser back/forward or internal navigation)
  useEffect(() => {
    const handleLocationChange = () => {
      const search = getRouteSearch();
      const params = new URLSearchParams(search.replace(/^\?/, ''));
      const param = params.get('panel') || params.get('sidebar');
      if (param) {
        const norm = param.trim().toLowerCase();
        const tab = norm === 'rundir' ? 'files' : norm;
        if (isRightSidebarTab(tab)) {
          setRightPanel(tab);
          writeRightSidebarOpen(true, { chainId, instanceId: agentInstanceId });
          writeRightSidebarTab(tab, { chainId, instanceId: agentInstanceId });
        } else if (norm === 'closed' || norm === 'false' || norm === '0') {
          setRightPanel('closed');
          writeRightSidebarOpen(false, { chainId, instanceId: agentInstanceId });
        }
      } else {
        setRightPanel('closed');
        writeRightSidebarOpen(false, { chainId, instanceId: agentInstanceId });
      }
    };
    window.addEventListener('hashchange', handleLocationChange);
    window.addEventListener('popstate', handleLocationChange);
    return () => {
      window.removeEventListener('hashchange', handleLocationChange);
      window.removeEventListener('popstate', handleLocationChange);
    };
  }, [agentInstanceId, chainId]);

  // Guardrail: adjust sidebar width on window resize so chat view never violates CHAT_VIEW_MIN_WIDTH
  useEffect(() => {
    const handleWindowResize = () => {
      if (!containerRef.current) return;
      const containerWidth = containerRef.current.getBoundingClientRect().width;
      const maxAllowedWidth = Math.max(RIGHT_SIDEBAR_MIN_WIDTH, containerWidth - CHAT_VIEW_MIN_WIDTH);
      setSidebarWidth((prev) => {
        if (prev > maxAllowedWidth) {
          return maxAllowedWidth;
        }
        return prev;
      });
    };
    window.addEventListener('resize', handleWindowResize);
    return () => window.removeEventListener('resize', handleWindowResize);
  }, []);
  const [statusMenuOpen, setStatusMenuOpen] = useState(false);
  const [headerActionsOpen, setHeaderActionsOpen] = useState(false);
  const [paletteOpen, setPaletteOpen] = useState(false);
  const [chainSelectorOpen, setChainSelectorOpen] = useState(false);
  const [chainAgentSwitcherOpen, setChainAgentSwitcherOpen] = useState(false);
  const searchOpen = paletteOpen;
  const setSearchOpen = setPaletteOpen;

  // The chain's agents, shaped as a single palette conversation group so the
  // scoped search modal (opened from the header) lists them even before typing.
  // Sourced from the chain detail we already fetch — no extra request.
  const chainAgentGroups = useMemo(() => {
    const chain = chainDetailQuery.data?.chain;
    const members = (chain?.members || []) as any[];
    if (!chainId || members.length === 0) return [];
    const coordinator = String(chain?.coordinatorAgentInstanceId || '');
    return [{
      projectId: chainId,
      projectName: 'Agents in this chain',
      conversations: members
        .filter((m) => m?.agentInstanceId)
        .map((m) => ({
          conversationId: String(m.agentInstanceId),
          agentInstanceId: String(m.agentInstanceId),
          title: String(m.displayName || m.agentInstanceId),
          agentName: m.displayName ? String(m.displayName) : undefined,
          isCoordinator: String(m.agentInstanceId) === coordinator,
          runtimeStatus: m.runtimeStatus || undefined,
          activityStatus: m.activityStatus || undefined,
          unreadCount: 0,
        })),
    }];
  }, [chainDetailQuery.data, chainId]);

  // status / runtime / header-actions overlays are @ui Menu / Popover / Drawer —
  // they own their own outside-click / Esc / focus handling (no bespoke refs).
  const fileInputRef = useRef<HTMLInputElement | null>(null);



  const [renaming, setRenaming] = useState(false);
  const [titleDraft, setTitleDraft] = useState('');
  const [titleError, setTitleError] = useState('');

  const destinationBridgeId = stagedBridgeId ?? instanceBridgeId;
  const destinationProjectId = projectId;
  const destinationBridge = bridges.find((item: any) => bridgeId(item) === destinationBridgeId);
  const destinationProjectQuery = projectQuery;
  const operationQuery = useListInstanceReconfigurationsQuery({ instanceId: agentInstanceId }, { skip: !agentInstanceId, pollingInterval: acceptedOperation && !['ready', 'failed', 'recovery_required'].includes(acceptedOperation.phase) ? 2000 : 8000 });
  const serverOperation = operationQuery.data?.operations?.[0];
  const operation = acceptedOperation && (!serverOperation || (serverOperation.operation_id === acceptedOperation.operation_id && serverOperation.revision < acceptedOperation.revision)) ? acceptedOperation : serverOperation;
  const operationInFlight = Boolean(operation && ['prepared', 'stopping', 'source_stopped', 'launching'].includes(operation.phase));
  const operationBlocksInput = Boolean(operation && operation.phase !== 'ready' && !(operation.phase === 'failed' && (operation.failure_code === 'recovery_stopped' || (!operation.source_stopped && !operation.destination_committed))));
  const bridgeLabel = String(instanceBridge?.label || instanceBridge?.machine_hostname || instanceBridgeId || '');
  const currentCaps = useMemo(() => normalizeBridgeCapabilities(instanceBridge), [instanceBridge]);
  const caps = useMemo(() => normalizeBridgeCapabilities(destinationBridge), [destinationBridge]);

  const providerOptions = useMemo(() => {
    const list = caps.map((c) => c.provider).filter(Boolean);
    // Always include the instance's current provider so it is selectable/visible.
    if (instanceProvider && !list.includes(instanceProvider)) list.push(instanceProvider);
    return Array.from(new Set(list)).sort();
  }, [caps, instanceProvider]);
  const modelOptions = useMemo(() => {
    const selectedProvider = provider || instanceProvider || providerOptions[0] || '';
    const cap = caps.find((c) => c.provider === selectedProvider);
    const t = capModels(cap);
    const ordered = modelOrder.filter((x) => t.includes(x)).concat(t.filter((x) => !modelOrder.includes(x)));
    if (instanceModel && !ordered.includes(instanceModel)) ordered.unshift(instanceModel);
    return ordered;
  }, [caps, provider, providerOptions, instanceProvider, instanceModel]);

  const chatMessages = useMemo(
    // REQ-SUBTLE-AGENT-START-14: Retain agent start/restart system messages for subtle divider rendering
    () => normalizeConversationMessages([...olderMessages, ...baseMessages, ...localMessages], agentId || agentInstanceId),
    [olderMessages, baseMessages, localMessages, agentId, agentInstanceId],
  );
  /* REQ-SHELL-6 §2 — THE RUN INDICATOR's three derived values.
   *
   * REQ-SHELL-5 posts one lean marker per run, message_type="shell_run", carrying ONLY
   * {"session_id": …}. Status is deliberately absent from it, so the marker tells us
   * WHICH runs belong in this thread and the shell_sessions row tells us everything
   * about their state. */
  const runMarkers: ShellRunMarker[] = useMemo(
    () => chatMessages
      .filter((message) => message.messageType === 'shell_run')
      .map((message) => ({
        messageId: message.messageId,
        sessionId: String(message.metadata?.session_id || message.metadata?.sessionId || ''),
        createdUnixMs: message.createdUnixMs || 0,
      }))
      .filter((marker) => Boolean(marker.sessionId)),
    [chatMessages],
  );

  /* The newest message that is NOT a run marker — i.e. the last time a user or an agent
   * actually said something. This is what UNPINS a finished run, per the user's
   * sequencing: a run that has stopped stays on screen until the next such message
   * arrives, so one finishing while nobody is talking remains readable. Markers are
   * excluded because a run must not unpin itself (or its siblings) merely by existing. */
  const lastConversationMessageMs = useMemo(
    () => chatMessages.reduce(
      (newest, message) => (message.messageType === 'shell_run' || isAgentStartMessage(message) ? newest : Math.max(newest, message.createdUnixMs || 0)),
      0,
    ),
    [chatMessages],
  );

  const conversationRuns = useConversationRuns(agentInstanceId, conversationId);
  const pinnedRuns = useMemo(
    () => pinnedRunSessions(conversationRuns, runMarkers, lastConversationMessageMs),
    [conversationRuns, runMarkers, lastConversationMessageMs],
  );
  const runBySessionId = useMemo(
    () => new Map(conversationRuns.map((session) => [session.session_id, session])),
    [conversationRuns],
  );

  /* A pinned run is rendered ABOVE THE COMPOSER, so its marker must not ALSO render at
   * its chronological place — the row would appear twice. Dropping it from the list
   * rather than rendering an empty body matters: ChatMessageList wraps every message in
   * a bubble with a timestamp and a hover-copy control, so a null body would leave a
   * visible empty row behind. Once the run unpins, the marker comes back here and the
   * transcript keeps its permanent record of the run where it happened. */
  const pinnedSessionIds = useMemo(
    () => new Set(pinnedRuns.map((session) => session.session_id)),
    [pinnedRuns],
  );
  // REQ-CLUB-RUN-COMMANDS-13 & REQ-SUBTLE-AGENT-START-14: Group consecutive shell_run and agent start messages
  const transcriptMessages = useMemo(
    () => groupTranscriptMessages(chatMessages, pinnedSessionIds),
    [chatMessages, pinnedSessionIds],
  );

  const needsStart = runtimeNeedsStart(runtimeStatus);
  const runtimeStopping = runtimeIsStopping(runtimeStatus);
  const runtimeActionBusy = operationInFlight || retryConfigurationState.isLoading || reconfigureState.isLoading || restartState.isLoading || stopState.isLoading;
  const hasUploadingAttachments = attachments.some((item) => item.status === 'uploading');
  const hasFailedAttachments = attachments.some((item) => item.status === 'error');
  const uploadedAttachments = attachments.filter((item) => item.status === 'uploaded' && item.id);

  const pendingPaneCapture = chatMessages.some((message) => message.messageType === 'pane_capture' && message.messageStatus === 'pending');
  const paneCaptureDisabled = !agentInstanceId || needsStart || runtimeStopping || pendingPaneCapture || requestPaneCaptureState.isLoading;

  useEffect(() => { if (!renaming) setTitleDraft(editableTitle); }, [editableTitle, renaming]);
  useEffect(() => { if (agentInstanceId && (conversation?.unread_count || conversation?.unreadCount)) void markRead({ conversationId }); }, [conversationId, agentInstanceId]);
  // Polling must not overwrite edits or substitute an incompatible model.
  useEffect(() => {
    if (settingsEditedRef.current) return;
    setProvider(instanceProvider); setModel(instanceModel);
  }, [instanceProvider, instanceModel]);
  useEffect(() => {
    settingsEditedRef.current = false;
    setStagedBridgeId(null); setAcceptedOperation(null);
    setProvider(instanceProvider); setModel(instanceModel); setReconfigStatus('');
  }, [agentInstanceId]);
  useEffect(() => {
    if (!operation || !operationBlocksInput || operation.failure_code === 'force_stopping') return;
    settingsEditedRef.current = true;
    setStagedBridgeId(operation.destination.bridge_id);
    setProvider(operation.destination.provider); setModel(operation.destination.model);
  }, [operation?.operation_id, operation?.phase]);
  useEffect(() => {
    if (!operation || operation.phase !== 'ready') return;
    settingsEditedRef.current = false;
    setStagedBridgeId(null);
    setProvider(operation.destination.provider); setModel(operation.destination.model);
    setAcceptedOperation(null); setReconfigStatus('');
    void instanceQuery.refetch(); void convQuery.refetch(); void messagesQuery.refetch();
  }, [operation?.operation_id, operation?.phase]);
  useEffect(() => {
    if (operation?.failure_code !== 'recovery_stopped' || operation.phase !== 'failed') return;
    setAcceptedOperation(null); setReconfigStatus('');
    void instanceQuery.refetch(); void messagesQuery.refetch();
  }, [operation?.operation_id, operation?.phase, operation?.failure_code]);
  useEffect(() => {
    setOlderMessages([]);
    setOlderCursor('');
    setOlderHasMore(false);
    setLocalMessages([]);
    setAttachments([]);
  }, [conversationId]);
  useEffect(() => {
    if (baseMessages.length === 0 || localMessages.length === 0) return;
    const serverIds = new Set(baseMessages.map((message, index) => msgId(message, index)));
    setLocalMessages((current) => current.filter((message, index) => {
      const id = msgId(message, index);
      return !id || id.startsWith('local_') || !serverIds.has(id);
    }));
  }, [baseMessages, localMessages.length]);
  useEffect(() => {
    if (olderMessages.length > 0) return;
    setOlderCursor(String(messagesQuery.data?.nextCursor || ''));
    setOlderHasMore(Boolean(messagesQuery.data?.hasMore));
  }, [messagesQuery.data?.nextCursor, messagesQuery.data?.hasMore, olderMessages.length]);
  // (status / runtime / header-actions outside-click + Esc handling now lives in
  // the @ui Menu / Popover / Drawer primitives.)

  // Apply & relaunch only matters when the selection differs from what the
  // instance currently runs; otherwise it's a no-op (use Restart instead).
  const effectiveProvider = provider || instanceProvider;
  const effectiveModel = model || instanceModel;
  const selectionChangesConfig = Boolean(agentInstanceId) && (destinationBridgeId !== instanceBridgeId || (effectiveProvider && effectiveProvider !== instanceProvider) || (effectiveModel && effectiveModel !== instanceModel));
  const validityInput = {
    instanceLoaded: Boolean(instance), instanceError: instanceQuery.isError,
    bridgeId: instanceBridgeId, bridge: instanceBridge,
    bridgesLoaded: Boolean(bridgesQuery.data), bridgesError: bridgesQuery.isError,
    projectId, project: projectQuery.data?.project,
    projectLoaded: Boolean(projectQuery.data), projectError: projectQuery.isError,
    provider: instanceProvider, model: instanceModel, capabilities: currentCaps,
  };
  const configurationIssues = conversationConfigurationIssues(validityInput);
  const stagedConfigurationIssues = conversationConfigurationIssues({
    ...validityInput, bridgeId: destinationBridgeId, bridge: destinationBridge,
    projectId: destinationProjectId, project: destinationProjectQuery.data?.project,
    projectLoaded: Boolean(destinationProjectQuery.data), projectError: destinationProjectQuery.isError,
    provider: effectiveProvider, model: effectiveModel, capabilities: caps,
  });
  if (destinationBridge && destinationBridge.runtime_connected !== true && !stagedConfigurationIssues.some(issue => issue.includes('connection is disconnected'))) stagedConfigurationIssues.push('Destination bridge is not connected. Reconnect it or choose a connected bridge before Apply.');
  if (destinationBridge && !destinationBridge.reconfiguration_supported) stagedConfigurationIssues.push('Update the destination bridge before applying configuration changes.');
  if (instanceBridge && !instanceBridge.reconfiguration_supported) stagedConfigurationIssues.push('Update the source bridge before applying configuration changes.');
  if (operation?.failure_code === 'force_stopping') stagedConfigurationIssues.push('Waiting for Force stop confirmation before allowing Apply.');
  if (operationBlocksInput) configurationIssues.push(operation?.failure_message || 'Configuration change is in progress. Messages are disabled until the destination is ready.');
  if (operationQuery.isLoading) configurationIssues.push('Checking for an in-progress configuration change before allowing messages.');
  if (operationQuery.isError) configurationIssues.push('Configuration operation state could not be verified. Refresh before sending.');
  const conversationReadOnly = configurationIssues.length > 0;
  const configurationInputBlocked = conversationReadOnly || selectionChangesConfig || runtimeActionBusy || runtimeStopping || isStarting;
  configurationInputBlockedRef.current = Boolean(configurationInputBlocked);
  const sendDisabled = configurationInputBlocked || hasUploadingAttachments || hasFailedAttachments || (!draft.trim() && uploadedAttachments.length === 0);



  async function saveConversationTitle() {
    const next = titleDraft.trim();
    if (!next) { setTitleError('Title is required.'); return; }
    setTitleError('');
    try {
      await updateConversationTitle({ conversationId, title: next }).unwrap();
      setRenaming(false);
      void convQuery.refetch();
    } catch (err: any) {
      setTitleError(errMsg(err, 'Rename failed'));
    }
  }

  async function loadOlderMessages() {
    if (!olderCursor || olderMessagesState.isFetching) return;
    setError('');
    try {
      const data = await fetchOlderMessages({ conversationId, limit: 30, cursor: olderCursor }).unwrap();
      const rows: Message[] = data?.messages || [];
      setOlderMessages((current) => {
        const seen = new Set(current.map((message, index) => msgId(message, index)));
        const next = [...current];
        rows.forEach((message, index) => {
          const id = msgId(message, current.length + index);
          if (seen.has(id)) return;
          seen.add(id);
          next.push(message);
        });
        return next;
      });
      setOlderCursor(String(data?.nextCursor || ''));
      setOlderHasMore(Boolean(data?.hasMore));
    } catch (err: any) {
      setError(errMsg(err, 'Could not load older messages'));
    }
  }

  async function uploadAttachment(file: File, existingLocalId = '') {
    if (configurationInputBlocked) return;
    const localId = existingLocalId || `att_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
    const name = artifactUploadName(file, 'conversation-attachment');
    const tooLarge = file.size > MAX_UPLOAD_BYTES;
    setError('');
    setAttachments((current) => {
      const without = current.filter((item) => item.localId !== localId);
      return [...without, { localId, id: '', name, file, status: tooLarge ? 'error' : 'uploading', error: tooLarge ? `File is too large. Maximum upload size is ${Math.round(MAX_UPLOAD_BYTES / (1024 * 1024))} MB.` : '' }];
    });
    if (tooLarge) return;
    try {
      const res = await createArtifact({
        file,
        name,
        mime: artifactMimeForFile(file),
        kind: artifactKindForFile(file),
        originKind: 'conversation_chat',
        originRef: conversationId,
        projectId,
        agentId,
        agentInstanceId,
        chainId,
      }).unwrap();
      const link = artifactLinkFromResponse(res);
      const id = link.replace(/^artifact:\/\//i, '');
      if (!id) throw new Error('Upload failed: Hub did not return an artifact id.');
      setAttachments((current) => current.map((item) => item.localId === localId ? { ...item, id, status: 'uploaded', error: '' } : item));
    } catch (err: any) {
      setAttachments((current) => current.map((item) => item.localId === localId ? { ...item, status: 'error', error: errMsg(err, 'Upload failed') } : item));
    }
  }

  function handleAttachmentInput(event: any) {
    if (configurationInputBlocked) return;
    const files = Array.from(event.target.files || []) as File[];
    event.target.value = '';
    files.forEach((file) => void uploadAttachment(file));
  }

  function openAttachmentPicker() {
    if (!configurationInputBlocked) fileInputRef.current?.click();
  }

  function handleComposerPaste(event: ClipboardEvent<HTMLTextAreaElement>) {
    if (configurationInputBlocked) return;
    const files = clipboardFilesFromEvent(event);
    if (files.length === 0) return;
    event.preventDefault();
    files.forEach((file) => void uploadAttachment(file));
  }

  async function submit(event: FormEvent) {
    event.preventDefault();
    if (sendDisabled) return;
    const body = draft.trim();
    const attachmentIds = uploadedAttachments.map(a => a.id);
    const sendBody = body || (attachmentIds.length ? 'Uploaded file' : '');
    if (!sendBody && attachmentIds.length === 0) return;
    const local = optimisticUserMessage(conversationId, sendBody);
    const localId = msgId(local, 0);
    (local as any).artifact_ids_json = JSON.stringify(attachmentIds);
    setError('');
    updateDraft('');
    setAttachments([]);
    setLocalMessages((current) => [...current, local]);
    try {
      const result = await sendMessage({ conversationId, body: sendBody, artifactIds: attachmentIds }).unwrap();
      const sent = sentMessageFromResult(result);
      setLocalMessages((current) => current.map((message) => {
        if (msgId(message, 0) !== localId) return message;
        return sent ? { ...sent, body: String(sent.body || sendBody), direction: sent.direction || 'user_to_agent', artifact_ids_json: (sent as any).artifact_ids_json || JSON.stringify(attachmentIds) } : { ...message, sending: false };
      }));
      void messagesQuery.refetch();
    } catch (err: any) {
      const message = errMsg(err, 'Send failed');
      setLocalMessages((current) => current.map((item) => (msgId(item, 0) === localId ? failedLocalMessage(item, message) : item)));
    }
  }

  async function handleSendReply(text: string) {
    if (configurationInputBlocked) return;
    const sendBody = text.trim();
    if (!sendBody || !conversationId) return;
    const local = optimisticUserMessage(conversationId, sendBody);
    const localId = msgId(local, 0);
    setError('');
    setLocalMessages((current) => [...current, local]);
    try {
      const result = await sendMessage({ conversationId, body: sendBody, artifactIds: [] }).unwrap();
      const sent = sentMessageFromResult(result);
      setLocalMessages((current) => current.map((message) => {
        if (msgId(message, 0) !== localId) return message;
        return sent ? { ...sent, body: String(sent.body || sendBody), direction: sent.direction || 'user_to_agent', artifact_ids_json: '[]' } : { ...message, sending: false };
      }));
      void messagesQuery.refetch();
    } catch (err: any) {
      const message = errMsg(err, 'Send failed');
      setLocalMessages((current) => current.map((item) => (msgId(item, 0) === localId ? failedLocalMessage(item, message) : item)));
    }
  }

  async function requestPane() {
    if (paneCaptureDisabled) return;
    const requestId = `cap_local_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
    const local = optimisticPaneCaptureMessage(conversationId, requestId, agentInstanceId);
    const localId = msgId(local, 0);
    setError('');
    setLocalMessages((current) => [...current, local]);
    try {
      const result = await requestPaneCapture({ conversationId, width: 80, settleMs: 3000, lineLimit: 120 }).unwrap();
      const serverMessage = result?.message || null;
      setLocalMessages((current) => current.map((message) => (msgId(message, 0) === localId && serverMessage ? { ...serverMessage, sending: false } : message)));
      void messagesQuery.refetch();
    } catch (err: any) {
      const message = errMsg(err, 'Pane capture request failed');
      setLocalMessages((current) => current.map((item) => (msgId(item, 0) === localId ? failedPaneCaptureMessage(item, message) : item)));
    }
  }

  function beginRenameFromHeader() {
    setHeaderActionsOpen(false);
    setTitleDraft(editableTitle);
    setRenaming(true);
    setTitleError('');
  }

  function refreshFromHeader() {
    setHeaderActionsOpen(false);
    void messagesQuery.refetch();
  }

  // Default the panel's active tab based on what this conversation has: prefer
  // Tasks when linked to a chain, else Files when it has a project or agent instance.
  function defaultPanelTab(): RightSidebarTab {
    if (chainId) return 'tasks';
    if (projectId || agentInstanceId) return 'files';
    return 'tasks';
  }

  // Sync ?panel=<tab> to route hash search on panel open/tab switch, or clean it up on close
  function syncUrlPanel(tab: RightSidebarTab | null) {
    if (typeof window === 'undefined') return;
    try {
      const search = getRouteSearch();
      const params = new URLSearchParams(search.replace(/^\?/, ''));
      if (tab) {
        params.set('panel', tab);
        params.delete('sidebar');
      } else {
        params.delete('panel');
        params.delete('sidebar');
      }
      const nextSearch = params.toString();
      const nextHash = buildRouteHash(getRoutePathname(), nextSearch);
      if (window.location.hash !== nextHash) {
        window.history.replaceState(window.history.state || {}, '', nextHash);
      }
    } catch {
      // Best-effort URL query parameter synchronization
    }
  }

  // Top-right toggle: open to the default tab, or close if already open.
  function toggleRightPanel() {
    setHeaderActionsOpen(false);
    setRightPanel((cur) => {
      if (cur === 'closed') {
        const targetTab = readRightSidebarTab({ chainId, instanceId: agentInstanceId }) || defaultPanelTab();
        writeRightSidebarOpen(true, { chainId, instanceId: agentInstanceId });
        writeRightSidebarTab(targetTab, { chainId, instanceId: agentInstanceId });
        syncUrlPanel(targetTab);
        return targetTab;
      } else {
        setIsRightPanelMaximized(false);
        writeRightSidebarOpen(false, { chainId, instanceId: agentInstanceId });
        syncUrlPanel(null);
        return 'closed';
      }
    });
  }

  // Open the panel focused on a specific tab (e.g. the composer project chip
  // opens Files; a current-task link opens Tasks).
  function openRightPanel(tab: RightSidebarTab) {
    const targetTab = tab === 'rundir' ? 'files' : tab;
    setHeaderActionsOpen(false);
    writeRightSidebarOpen(true, { chainId, instanceId: agentInstanceId });
    writeRightSidebarTab(targetTab, { chainId, instanceId: agentInstanceId });
    syncUrlPanel(tab);
    setRightPanel(targetTab);
  }

  function closeRightPanel() {
    setIsRightPanelMaximized(false);
    writeRightSidebarOpen(false, { chainId, instanceId: agentInstanceId });
    syncUrlPanel(null);
    setRightPanel('closed');
  }

  useEffect(() => {
    const handleCloseSidebar = () => {
      setIsRightPanelMaximized(false);
      setRightPanel('closed');
      writeRightSidebarOpen(false);
      if (agentInstanceId || chainId) writeRightSidebarOpen(false, { chainId, instanceId: agentInstanceId });
      syncUrlPanel(null);
    };
    window.addEventListener('heimdall:close-sidebar', handleCloseSidebar);
    return () => {
      window.removeEventListener('heimdall:close-sidebar', handleCloseSidebar);
    };
  }, [agentInstanceId, chainId]);

  function selectRightPanelTab(tab: RightSidebarTab) {
    const targetTab = tab === 'rundir' ? 'files' : tab;
    writeRightSidebarOpen(true, { chainId, instanceId: agentInstanceId });
    writeRightSidebarTab(targetTab, { chainId, instanceId: agentInstanceId });
    syncUrlPanel(tab);
    setRightPanel(targetTab);
  }

  const handleResizerPointerDown = (e: React.PointerEvent) => {
    e.preventDefault();
    setIsDragging(true);

    const startX = e.clientX;
    const startWidth = sidebarWidth;
    const container = containerRef.current;
    const containerWidth = container ? container.getBoundingClientRect().width : window.innerWidth;
    const maxAllowedWidth = Math.max(RIGHT_SIDEBAR_MIN_WIDTH, containerWidth - CHAT_VIEW_MIN_WIDTH);

    let latestWidth = startWidth;

    const handlePointerMove = (moveEvent: PointerEvent) => {
      moveEvent.preventDefault();
      const deltaX = startX - moveEvent.clientX;
      const rawWidth = startWidth + deltaX;
      const clampedWidth = clampRightSidebarWidth(rawWidth, maxAllowedWidth);
      latestWidth = clampedWidth;
      setSidebarWidth(clampedWidth);
    };

    const handlePointerUp = (upEvent: PointerEvent) => {
      upEvent.preventDefault();
      setIsDragging(false);
      writeRightSidebarWidth(latestWidth);
      window.removeEventListener('pointermove', handlePointerMove);
      window.removeEventListener('pointerup', handlePointerUp);
      window.removeEventListener('pointercancel', handlePointerUp);
    };

    window.addEventListener('pointermove', handlePointerMove);
    window.addEventListener('pointerup', handlePointerUp);
    window.addEventListener('pointercancel', handlePointerUp);
  };

  const handleResizerDoubleClick = () => {
    setSidebarWidth(RIGHT_SIDEBAR_DEFAULT_WIDTH);
    writeRightSidebarWidth(RIGHT_SIDEBAR_DEFAULT_WIDTH);
  };

  const handleResizerKeyDown = (event: React.KeyboardEvent) => {
    const step = event.shiftKey ? 40 : 10;
    const containerWidth = containerRef.current?.getBoundingClientRect().width || window.innerWidth;
    const maxAllowedWidth = Math.max(RIGHT_SIDEBAR_MIN_WIDTH, containerWidth - CHAT_VIEW_MIN_WIDTH);

    if (event.key === 'ArrowLeft') {
      event.preventDefault();
      setSidebarWidth((prev) => {
        const next = clampRightSidebarWidth(prev + step, maxAllowedWidth);
        writeRightSidebarWidth(next);
        return next;
      });
    } else if (event.key === 'ArrowRight') {
      event.preventDefault();
      setSidebarWidth((prev) => {
        const next = clampRightSidebarWidth(prev - step, maxAllowedWidth);
        writeRightSidebarWidth(next);
        return next;
      });
    } else if (event.key === 'Home') {
      event.preventDefault();
      setSidebarWidth(RIGHT_SIDEBAR_MIN_WIDTH);
      writeRightSidebarWidth(RIGHT_SIDEBAR_MIN_WIDTH);
    } else if (event.key === 'End') {
      event.preventDefault();
      setSidebarWidth(maxAllowedWidth);
      writeRightSidebarWidth(maxAllowedWidth);
    } else if (event.key === 'Enter') {
      event.preventDefault();
      handleResizerDoubleClick();
    }
  };

  function renderConversationMessageBody(message: ChatMessage) {
    /* REQ-SHELL-6 §2. A marker reaching this point is NOT pinned (pinned ones are
       filtered out of `transcriptMessages`), so it always renders the finished,
       collapsed form. Resolved from the live session row — never from the message, which
       carries no status by design. If the row is not loaded yet there is nothing
       truthful to say about the run, so the marker renders nothing rather than guessing
       a state. */
    // REQ-CLUB-RUN-COMMANDS-13: Clubbed consecutive shell_run messages
    if (message.messageType === 'shell_run_group') {
      const clubbedRuns: ChatMessage[] = message.metadata?.clubbedRuns || [];
      return (
        <ClubbedRunGroup
          messages={clubbedRuns}
          runBySessionId={runBySessionId}
          formatTimestamp={formatMessageTimestamp}
        />
      );
    }
    if (message.messageType === 'shell_run') {
      const sessionId = String(message.metadata?.session_id || message.metadata?.sessionId || '');
      const session = sessionId ? runBySessionId.get(sessionId) : undefined;
      if (!session) return null;
      return <ShellRunRow session={session} />;
    }
    if (message.messageType === 'pane_capture') {
      const metadata = message.metadata || {};
      const status = message.messageStatus || 'complete';
      const lineCount = Number(metadata.line_count || metadata.lineCount || 0);
      return (
        <div data-debug-id={status === 'pending' ? `conversation-pane-capture-loading-${message.messageId}` : status === 'failed' ? `conversation-pane-capture-error-${message.messageId}` : `conversation-pane-capture-output-${message.messageId}`} className={`rounded-2xl border p-3 ${status === 'failed' ? 'border-danger/30 bg-danger-soft text-danger' : 'border-info/30 bg-info-soft text-info'}`}>
          <div className="mb-2 flex flex-wrap items-center gap-2 text-caption uppercase tracking-wide text-info">
            <span>{status === 'pending' ? 'Requesting terminal pane…' : status === 'failed' ? 'Pane capture failed' : 'Terminal pane capture'}</span>
            <span>{Number(metadata.width || 80)} cols</span>
            {lineCount ? <span>{lineCount} lines</span> : null}
            {metadata.truncated ? <span>truncated</span> : null}
          </div>
          {status === 'pending' ? <div className="text-sm text-info">Waiting for the wrapper to resize and capture the pane…</div> : <PaneCaptureOutput body={message.body} messageId={message.messageId} />}
          {status === 'failed' ? <button type="button" data-debug-id={`conversation-pane-capture-retry-${message.messageId}`} onClick={() => void requestPane()} disabled={paneCaptureDisabled} className="mt-2 rounded-full border border-subtle bg-surface px-3 py-1 text-xs text-primary hover:bg-surface-raised disabled:opacity-50">Retry</button> : null}
        </div>
      );
    }
    // REQ-SUBTLE-AGENT-START-14: Consecutive agent start messages clubbed together
    if (message.messageType === 'configuration_change') {
      const metadata = message.metadata || {};
      const source = metadata.source || {};
      const destination = metadata.destination || {};
      const fields = [
        { name: 'Bridge', key: 'bridge_id', label: 'bridge_label' },
        { name: 'Project', key: 'project_id', label: 'project_label' },
        { name: 'Provider', key: 'provider', label: 'provider' },
        { name: 'Model', key: 'model', label: 'model' },
      ].filter(field => source[field.key] !== destination[field.key]);
      return <div data-debug-id={`conversation-configuration-event-${message.messageId}`} className="py-2 text-xs text-muted">
        <span className="font-medium">{message.body}</span>
        {fields.map(field => <span key={field.key}> · {field.name}: <VaultText value={source[field.label] || source[field.key] || 'None'} fallback={source[field.key] || 'None'} /> → <VaultText value={destination[field.label] || destination[field.key] || 'None'} fallback={destination[field.key] || 'None'} /></span>)}
        {metadata.failure_message ? <div className="mt-1 text-danger">{metadata.failure_message}</div> : null}
      </div>;
    }
    if (message.messageType === 'agent_start_clubbed') {
      const count = message.metadata?.count || 2;
      const startMs = message.metadata?.startUnixMs || message.createdUnixMs;
      const endMs = message.metadata?.endUnixMs || message.createdUnixMs;
      const startTime = formatMessageTimestamp(startMs).label;
      const endTime = formatMessageTimestamp(endMs).label;
      const timeStr = startTime && endTime ? `${startTime} – ${endTime}` : (startTime || endTime || '');
      return (
        <div data-debug-id={`conversation-agent-start-clubbed-${message.messageId}`} className="my-2 flex w-full items-center gap-3">
          <div className="flex-1 border-t border-subtle/40" />
          <span className="shrink-0 font-mono text-[11px] text-faint">
            agent started {count} times ({timeStr})
          </span>
          <div className="flex-1 border-t border-subtle/40" />
        </div>
      );
    }
    // REQ-SUBTLE-AGENT-START-14: Isolated agent start message rendered as subtle divider
    if (isAgentStartMessage(message)) {
      const time = formatMessageTimestamp(message.createdUnixMs).label;
      return (
        <div data-debug-id={`conversation-agent-start-${message.messageId}`} className="my-2 flex w-full items-center gap-3">
          <div className="flex-1 border-t border-subtle/40" />
          <span className="shrink-0 font-mono text-[11px] text-faint">
            agent started ({time})
          </span>
          <div className="flex-1 border-t border-subtle/40" />
        </div>
      );
    }
    // SYS-1: general system notices (other than agent start/restart)
    if (message.messageType === 'system') {
      return (
        <div data-debug-id={`conversation-system-message-${message.messageId}`} className="rounded-xl border border-subtle bg-surface px-3 py-2 text-muted">
          <div className="mb-1 flex items-center gap-1.5 text-[10px] font-semibold uppercase tracking-wider text-faint">
            <Icon name="info" size={12} title="System message" />
            System
          </div>
          <div className="text-sm text-primary">
            <ThreadMessageBody body={message.body} />
          </div>
        </div>
      );
    }
    // MSG-1/MSG-2: scheduled actions arrive as message_type='action'. Give them a
    // distinct card (left accent rail + border + header with an Icon badge, no
    // emoji) so they are recognizable at a glance versus normal chat, while
    // keeping the Markdown body + artifact previews intact.
    if (message.messageType === 'action') {
      const { summary, triggeredAt } = scheduleContextFromMetadata(message.metadata);
      return (
        <div data-debug-id={`conversation-action-message-${message.messageId}`} className="rounded-2xl border border-warning/30 border-l-2 border-l-warning bg-warning-soft p-3">
          <div className="mb-2 flex flex-wrap items-center gap-x-2 gap-y-1 text-caption uppercase tracking-wide text-warning">
            <span className="inline-flex items-center gap-1.5 font-semibold text-warning">
              <Icon name="clock" size={13} title="Scheduled action" />
              Scheduled action
            </span>
            {summary ? <span className="normal-case tracking-normal text-muted"><VaultText value={summary} as="span" /></span> : null}
          </div>
          {triggeredAt ? (
            <div className="mb-2 text-caption text-faint">Ran on schedule: {triggeredAt}</div>
          ) : null}
          <ThreadMessageBody body={message.body} />
          {message.artifactIds && message.artifactIds.length > 0 && (
            <div className="mt-2 flex max-w-full flex-wrap gap-2">
              {message.artifactIds.map((id) => (
                <ArtifactAttachmentPreview key={id} artifactId={id} session={{ daemonUrl: '', clientToken: '' }} debugId={`conversation-thread-artifact-${message.messageId}-${id}`} />
              ))}
            </div>
          )}
        </div>
      );
    }
    return (
      <div className="flex flex-col gap-1">
        <ThreadMessageBody body={message.body} />
        {message.artifactIds && message.artifactIds.length > 0 && (
          <div className="mt-2 flex max-w-full flex-wrap gap-2">
            {message.artifactIds.map((id) => (
              <ArtifactAttachmentPreview key={id} artifactId={id} session={{ daemonUrl: '', clientToken: '' }} debugId={`conversation-thread-artifact-${message.messageId}-${id}`} />
            ))}
          </div>
        )}
      </div>
    );
  }

  // Start/stop the agent from the runtime status popup.
  async function toggleRuntime() {
    if (!agentId || !agentInstanceId || runtimeActionBusy) return;
    setStatusMenuOpen(false);
    setReconfigStatus(needsStart ? 'Starting…' : 'Stopping…');
    try {
      if (needsStart) await restartInstance({ agentId, instanceId: agentInstanceId }).unwrap();
      else await stopInstance({ agentId, instanceId: agentInstanceId }).unwrap();
      setReconfigStatus(needsStart ? 'Start requested.' : 'Stop requested.');
      void instanceQuery.refetch();
    } catch (err: any) {
      setReconfigStatus(errMsg(err, needsStart ? 'Start failed' : 'Stop failed'));
    }
  }

  async function applyReconfigure() {
    if (!agentInstanceId || runtimeActionBusy || stagedConfigurationIssues.length > 0) return;
    if (operation?.phase === 'recovery_required') {
      setReconfigStatus('Retrying configuration change…');
      try {
        const retried = await retryConfiguration({ instanceId: agentInstanceId, idempotency_key: operation.idempotency_key, expected_operation_revision: operation.revision }).unwrap();
        setAcceptedOperation(retried); setReconfigStatus(''); void operationQuery.refetch();
      } catch (error: any) { setReconfigStatus(errMsg(error, 'Recovery retry failed')); void operationQuery.refetch(); }
      return;
    }
    const nextProvider = provider || providerOptions[0] || '';
    const nextModel = model || modelOptions[0] || '';
    if (!nextProvider || !nextModel) { setReconfigStatus('Choose a provider and model first.'); return; }
    setRuntimeMenuOpen(false);
    setReconfigStatus(`Applying configuration on ${bridgeLabel || instanceBridgeId || 'this bridge'}…`);
    try {
      const applied = await reconfigureInstance({
        instanceId: agentInstanceId, bridge_id: destinationBridgeId,
        project_id: destinationProjectId, provider: nextProvider, model: nextModel,
        expected_revision: Number(instance?.configuration_revision || 0),
        idempotency_key: globalThis.crypto?.randomUUID?.() || `apply-${Date.now()}-${Math.random().toString(36).slice(2)}`,
      }).unwrap();
      setAcceptedOperation(applied);
      setReconfigStatus('');
      void operationQuery.refetch();
      void instanceQuery.refetch();
      void messagesQuery.refetch();
    } catch (err: any) {
      setReconfigStatus(errMsg(err, 'Configuration change failed'));
      void operationQuery.refetch();
    }
  }

  async function forceStopRuntime() {
    if (!agentId || !agentInstanceId || (needsStart && !operationBlocksInput) || stopState.isLoading || reconfigureState.isLoading || retryConfigurationState.isLoading) return;
    setReconfigStatus('Force stopping…');
    try {
      await stopInstance({ agentId, instanceId: agentInstanceId, force: true }).unwrap();
      setReconfigStatus('Force stop requested. Waiting for confirmed termination…');
      void instanceQuery.refetch(); void operationQuery.refetch();
    } catch (err: any) { setReconfigStatus(errMsg(err, 'Force stop failed')); }
  }

  function resetRuntimeConfiguration() {
    settingsEditedRef.current = false;
    setStagedBridgeId(null); setProvider(instanceProvider); setModel(instanceModel); setReconfigStatus('');
  }

  const pendingReconfig = selectionChangesConfig || operation?.phase === 'recovery_required';
  const runtimeControls = (
    <div data-debug-id="conversation-runtime-controls" className="text-left">
      <div className="mb-4 flex flex-wrap items-center justify-between gap-3 rounded-xl border border-subtle p-3">
        <span className="inline-flex items-center gap-2 text-sm text-primary"><StatusDot size="sm" tone={runtimeStatusToTone(runtimeStatus)} label={needsStart ? 'Stopped' : 'Running'} />{needsStart ? 'Stopped' : runtimeStopping ? 'Stopping…' : isStarting ? 'Starting…' : 'Running'}</span>
        <div className="flex gap-2">
          <button type="button" data-debug-id="conversation-runtime-modal-toggle-btn" disabled={!agentInstanceId || runtimeActionBusy || runtimeStopping || operationBlocksInput || (needsStart && conversationReadOnly)} onClick={() => void toggleRuntime()} className="min-h-11 rounded-xl border border-subtle px-3 text-sm text-primary disabled:opacity-40">{needsStart ? 'Start agent' : 'Stop agent'}</button>
          <button type="button" data-debug-id="conversation-runtime-force-stop-btn" disabled={!agentInstanceId || (needsStart && !operationBlocksInput) || stopState.isLoading || reconfigureState.isLoading || retryConfigurationState.isLoading || instanceBridge?.runtime_connected !== true} onClick={() => void forceStopRuntime()} className="min-h-11 rounded-xl border border-danger/30 px-3 text-sm text-danger disabled:opacity-40">Force stop</button>
        </div>
      </div>
      <div className="mb-4 rounded-xl bg-neutral-soft px-3 py-2 text-xs text-muted">Project: {projectId ? <VaultText value={projectName} fallback="Project" /> : 'No project'}</div>
      <RuntimeConfigurationOptions debugPrefix="conversation" bridges={bridges} selection={{ bridgeId: destinationBridgeId, provider, model }} requireReconfiguration disabled={runtimeActionBusy || operationBlocksInput || isStarting} onChange={next => { settingsEditedRef.current = true; setStagedBridgeId(next.bridgeId); setProvider(next.provider); setModel(next.model); }} />
      <div className="mt-1.5 flex items-center gap-2 border-t border-subtle px-2 pt-2 text-[12px] text-muted">
        <Icon name="alert" size={14} className={pendingReconfig ? 'text-warning' : 'text-faint'} />
        <span><span className={`font-semibold ${pendingReconfig ? 'text-warning' : 'text-muted'}`}>Restarts the agent</span> — choose Apply to confirm.</span>
      </div>
      {pendingReconfig && stagedConfigurationIssues.length ? <ul data-debug-id="conversation-destination-validation" className="mt-2 list-disc space-y-1 pl-5 text-xs text-danger">{stagedConfigurationIssues.map(issue => <li key={issue}>{issue}</li>)}</ul> : null}
      {reconfigStatus ? <div data-debug-id="conversation-reconfigure-status" className="px-2 pt-1 text-caption text-muted">{reconfigStatus}</div> : null}
    </div>
  );

  // While the instance-id route is being resolved to its conversation (the
  // by-instance fetch), show a resolving state rather than the not-found card.
  if (!conversation && convQuery.isFetching) {
    return (
      <section data-debug-id="conversation-thread-page" className="w-full max-w-4xl rounded-[2rem] border border-subtle bg-surface p-6 text-left">
        <div data-debug-id="conversation-thread-resolving" className="grid min-h-[220px] place-items-center text-sm text-muted">Loading conversation…</div>
      </section>
    );
  }

  if (!conversation && !convQuery.isFetching) {
    return (
      <section data-debug-id="conversation-thread-page" className="w-full max-w-4xl rounded-[2rem] border border-subtle bg-surface p-6 text-left">
        <h2 className="text-xl font-semibold text-primary">Conversation not found</h2>
        <p className="mt-2 text-sm text-muted">No conversation for instance <span className="font-mono">{routeInstanceId}</span> for this user.</p>
        <a data-debug-id="conversation-thread-back-btn" href="#/conversations/new" className="mt-4 inline-flex rounded-2xl bg-accent px-4 py-2 text-sm font-bold text-accent-fg hover:opacity-90">Start a new conversation</a>
      </section>
    );
  }


  // The right sidebar: a Tasks / Files tabbed panel. Tabs only appear when the
  // conversation actually has that context (a chain for Tasks, a project for
  // Files). `isMobile` renders it as a full-width overlay with its own header.
  function renderRightPanel(isMobilePanel: boolean) {
    const hasChain = Boolean(chainId);
    const hasTasks = Boolean(chainId);
    const hasFiles = Boolean(projectId || chainId || agentInstanceId);
    const hasVcs = Boolean(projectId) && projectVcsEnabled;
    // The file-explorer tab is labeled with a folder icon + the resource name.
    const filesLabel = projectName || 'Files';
    const active: RightSidebarTab =
      rightPanel === 'chain' && hasChain ? 'chain'
      : rightPanel === 'files' && hasFiles ? 'files'
      : rightPanel === 'vcs' && hasVcs ? 'vcs'
      : rightPanel === 'tasks' && (hasTasks || convQuery.isLoading) ? 'tasks'
      : hasTasks ? 'tasks'
      : hasFiles ? 'files'
      : 'tasks';
    const tabBase = 'relative inline-flex h-10 shrink-0 items-center justify-center gap-1.5 rounded-xl px-3';
    return (
      <div data-debug-id="conversation-right-panel" className="flex h-full min-h-0 min-w-0 max-w-full flex-col overflow-hidden bg-surface">
        <div data-debug-id="conversation-right-panel-tabs" className="relative sticky top-0 z-20 flex shrink-0 items-center gap-1.5 px-3 py-2.5 sm:px-4 bg-canvas/90 backdrop-blur-md">
          <div className="flex min-w-0 flex-1 items-center gap-2 overflow-x-auto overflow-y-hidden flex-nowrap [-webkit-overflow-scrolling:touch] no-scrollbar py-0.5">
            {hasChain ? (
              <button
                type="button"
                aria-label="Chain Overview"
                title="Chain Overview"
                data-debug-id="conversation-right-panel-tab-chain"
                onClick={() => selectRightPanelTab('chain')}
                aria-pressed={active === 'chain' ? 'true' : 'false'}
                className={`${tabBase} ${active === 'chain' ? 'bg-accent/15 text-accent' : 'text-muted hover:bg-neutral-soft hover:text-primary'}`}
              >
                <Icon name="layers" size={20} />
              </button>
            ) : null}
            {hasTasks ? (
              <button type="button" aria-label="Tasks" title="Tasks" data-debug-id="conversation-right-panel-tab-tasks" onClick={() => selectRightPanelTab('tasks')} aria-pressed={active === 'tasks' ? 'true' : 'false'} className={`${tabBase} ${active === 'tasks' ? 'bg-accent/15 text-accent' : 'text-muted hover:bg-neutral-soft hover:text-primary'}`}>
                <Icon name="tasks" size={20} />
                {chainProgress.total > 0 ? <span className="rounded-full bg-neutral-soft px-1.5 py-0.5 text-[10px] font-bold text-accent">{chainProgress.done}/{chainProgress.total}</span> : null}
              </button>
            ) : null}
            {hasFiles ? (
              <button type="button" title={filesLabel} aria-label={filesLabel} data-debug-id="conversation-right-panel-tab-files" onClick={() => selectRightPanelTab('files')} aria-pressed={active === 'files' ? 'true' : 'false'} className={`${tabBase} ${active === 'files' ? 'bg-accent/15 text-accent' : 'text-muted hover:bg-neutral-soft hover:text-primary'}`}>
                <Icon name="folder" size={20} />
                <span className="sr-only"><VaultText value={projectName} fallback="Project" /></span>
              </button>
            ) : null}
            {hasVcs ? (
              <button type="button" title="VCS" aria-label="VCS" data-debug-id="conversation-right-panel-tab-vcs" onClick={() => selectRightPanelTab('vcs')} aria-pressed={active === 'vcs' ? 'true' : 'false'} className={`${tabBase} ${active === 'vcs' ? 'bg-accent/15 text-accent' : 'text-muted hover:bg-neutral-soft hover:text-primary'}`}>
                <Icon name="git-branch" size={20} />
              </button>
            ) : null}
          </div>
          <div className="ml-auto shrink-0 flex items-center gap-1.5 pl-2">

            <button
              type="button"
              data-debug-id="conversation-right-panel-maximize-btn"
              aria-label={isRightPanelMaximized ? 'Restore side panel' : 'Maximize side panel'}
              title={isRightPanelMaximized ? 'Restore panel' : 'Maximize panel'}
              onClick={() => setIsRightPanelMaximized((prev) => !prev)}
              className="grid h-10 w-10 shrink-0 place-items-center rounded-xl text-muted hover:bg-neutral-soft hover:text-primary"
            >
              <Icon name={isRightPanelMaximized ? 'minimize' : 'maximize'} size={20} />
            </button>
            <button
              type="button"
              data-debug-id="conversation-right-panel-close-btn"
              aria-label="Close side panel"
              title="Close panel"
              onClick={closeRightPanel}
              className="grid h-10 w-10 shrink-0 place-items-center rounded-xl text-muted hover:bg-neutral-soft hover:text-primary"
            >
              <Icon name="panel-right" size={20} />
            </button>
          </div>
          <div className="pointer-events-none absolute inset-x-0 -bottom-6 h-6 bg-gradient-to-b from-canvas/90 via-canvas/50 to-transparent backdrop-blur-sm" aria-hidden="true" />
        </div>
        <div className="flex flex-col h-full min-h-0 flex-1 overflow-hidden">
          {active === 'chain' && hasChain ? (
            <ChainOverviewPanel
              chainId={chainId}
              projectId={projectId}
              bridgeId={instanceBridgeId}
              agentInstanceId={agentInstanceId}
              projectVcsEnabled={projectVcsEnabled}
              onClose={closeRightPanel}
              onSelectTask={(taskId) => {
                if (taskId) setFocusedTaskId(taskId);
                selectRightPanelTab('tasks');
              }}
              onOpenFileDiff={projectVcsEnabled ? (filePath) => {
                selectRightPanelTab('vcs');
                setVcsFileToOpen(filePath);
              } : undefined}
              onOpenVcsFiles={projectVcsEnabled ? () => {
                selectRightPanelTab('vcs');
              } : undefined}
              isMobile={isMobilePanel}
            />
          ) : active === 'files' && hasFiles ? (
            <ProjectFilesPanel
              key={agentInstanceId || projectId}
              agentInstanceId={agentInstanceId}
              projectId={projectId}
              chainId={chainId}
              directories={chainDetailQuery.data?.chain?.directories}
              members={chainDetailQuery.data?.chain?.members}
              bridgeId={instanceBridgeId}
              projectName={projectName}
              conversationKey={conversationId}
              onPublishComments={publishFileComments}
              onClose={closeRightPanel}
              isMobile={isMobilePanel}
              openFilePath={editorFileToOpen}
              onFileOpened={() => setEditorFileToOpen(null)}
              onOpenQuickOpen={() => setIsQuickOpenOpen(true)}
              initialOpenSearchInFiles={openSearchInFilesOnMount}
              onSearchDrawerConsumed={() => setOpenSearchInFilesOnMount(false)}
              initialOpenCommandPalette={openCommandPaletteOnMount}
              onCommandPaletteConsumed={() => setOpenCommandPaletteOnMount(false)}
            />
          ) : active === 'vcs' && hasVcs ? (
            <ProjectVcsPanel
              key={`vcs:${projectId}`}
              projectId={projectId}
              bridgeId={instanceBridgeId}
              experimentEnabled={projectVcsEnabled}
              onClose={closeRightPanel}
              isMobile={isMobilePanel}
              onOpenDirectory={() => selectRightPanelTab('files')}
              openFilePath={vcsFileToOpen}
              onFileOpened={() => setVcsFileToOpen(null)}
            />
          ) : active === 'tasks' ? (
            chainId ? (
              <TaskChainOverview
                chainId={chainId}
                focusTaskId={focusedTaskId || undefined}
                onClose={closeRightPanel}
                isMobile={isMobilePanel}
              />
            ) : (
              <div className="grid h-full place-items-center text-sm text-muted">Loading tasks…</div>
            )
          ) : null}
        </div>
      </div>
    );
  }

  function renderComposer() {
    const activeProvider = instanceProvider || provider;
    const composerInput = (<MessageComposerInput mobile={isMobile} debugId="conversation-composer-input"
              ref={textareaRef}
              value={draft}
              disabled={configurationInputBlocked}
              onChange={(e) => {
                updateDraft(e.target.value);
                const val = e.target.value;
                const pos = e.target.selectionStart ?? val.length;
                const before = val.slice(0, pos);
                const match = before.match(/@([^\s@]*)$/);
                if (match) {
                  setMentionQuery(match[1]);
                  setMentionIndex(0);
                } else {
                  setMentionQuery(null);
                }
              }}
              onKeyDown={(e) => {
                if (mentionQuery !== null && filteredMentions.length > 0) {
                  if (e.key === 'ArrowDown') { e.preventDefault(); setMentionIndex((i) => (i + 1) % filteredMentions.length); return; }
                  if (e.key === 'ArrowUp') { e.preventDefault(); setMentionIndex((i) => (i - 1 + filteredMentions.length) % filteredMentions.length); return; }
                  if (e.key === 'Enter') { e.preventDefault(); handleMentionSelect(filteredMentions[mentionIndex]); return; }
                  if (e.key === 'Escape') { e.preventDefault(); setMentionQuery(null); return; }
                }
                if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) { e.preventDefault(); void submit(e as any); }
              }}
              onPaste={handleComposerPaste}
              placeholder={isMobile ? 'Message the agent…' : 'Message the agent… (Cmd/Ctrl+Enter to send)'}
            />);
    const composerActions = {
      debugPrefix: 'conversation', mobile: isMobile, compactModel: isSmallComposer, provider: activeProvider, model: instanceModel,
      onSettings: () => setRuntimeMenuOpen(true), onUpload: openAttachmentPicker,
      uploadDisabled: configurationInputBlocked, sendDisabled, paneExpanded: isPaneExpanded,
      onPaneToggle: () => { userManuallyToggledPaneRef.current = true; setIsPaneExpanded(prev => !prev); },
    };
    return (
      <form
        ref={composerContainerRef as any}
        onSubmit={submit}
        data-debug-id="conversation-composer-shell"
        className="w-full max-w-4xl mx-auto px-3 sm:px-0 py-4"
      >
        <div className="mx-auto w-full max-w-4xl">
          {error ? <div data-debug-id="conversation-composer-send-error" className="mb-2 rounded-xl border border-danger/30 bg-danger-soft px-3 py-2 text-xs text-danger">{error}</div> : null}
          {attachments.length > 0 && (
            <div data-debug-id="conversation-attachment-tray" className="mb-2 space-y-2 rounded-2xl border border-subtle bg-surface-raised p-2 text-xs text-primary">
              {attachments.map((a) => (
                <div key={a.localId} data-debug-id={`conversation-attachment-${a.localId}`} className="rounded-xl border border-subtle bg-surface px-2.5 py-2">
                  <div className="flex min-w-0 items-center gap-2">
                    <span className={a.status === 'uploaded' ? 'text-success' : a.status === 'error' ? 'text-danger' : 'text-accent'}>{a.status === 'uploading' ? '⇧' : a.status === 'uploaded' ? '✓' : '!'}</span>
                    <span className="min-w-0 flex-1 truncate" title={a.name}>{a.name}</span>
                    <span className={a.status === 'uploaded' ? 'text-success' : a.status === 'error' ? 'text-danger' : 'text-accent'}>{a.status === 'uploading' ? 'Uploading…' : a.status === 'uploaded' ? 'Uploaded' : 'Failed'}</span>
                    {a.status === 'error' ? <button type="button" data-debug-id={`conversation-attachment-retry-${a.localId}`} onClick={() => void uploadAttachment(a.file, a.localId)} className="rounded-full border border-subtle px-2 py-0.5 text-primary hover:bg-neutral-soft">Retry</button> : null}
                    <button type="button" data-debug-id={`conversation-attachment-remove-${a.localId}`} onClick={() => setAttachments(prev => prev.filter((item) => item.localId !== a.localId))} className="rounded-full border border-subtle px-2 py-0.5 text-muted hover:bg-neutral-soft hover:text-primary">Remove</button>
                  </div>
                  {a.status === 'uploading' ? <div data-debug-id={`conversation-attachment-progress-${a.localId}`} className="mt-2 h-1.5 overflow-hidden rounded-full bg-neutral-soft"><div className="h-full w-1/2 animate-pulse rounded-full bg-accent" /></div> : null}
                  {a.error ? <div data-debug-id={`conversation-attachment-error-${a.localId}`} className="mt-1 text-danger">{a.error}</div> : null}
                </div>
              ))}
              {hasUploadingAttachments ? <div data-debug-id="conversation-attachment-uploading-hint" className="text-caption text-muted">You can keep typing. Send unlocks when uploads finish.</div> : null}
              {hasFailedAttachments ? <div data-debug-id="conversation-attachment-failed-hint" className="text-caption text-danger">Retry or remove failed uploads before sending.</div> : null}
            </div>
          )}
          <input ref={fileInputRef} data-debug-id="conversation-attach-input" type="file" multiple className="hidden" onChange={handleAttachmentInput} />
          {/* Desktop context and toolbar; mobile keeps input, send and options in one row. */}
          <div data-debug-id="conversation-composer-card" className="rounded-[22px] border border-subtle bg-surface px-3 py-2.5 focus-within:border-accent sm:px-4 sm:py-3">
          <div data-debug-id="conversation-composer-context" className="mb-2 hidden min-w-0 items-center gap-x-2 sm:flex text-[12px] text-muted">
            <div className="flex min-w-0 flex-1 items-center gap-1.5 overflow-hidden">
              <button type="button" onClick={() => setRuntimeMenuOpen(true)} aria-haspopup="dialog" aria-label="Change bridge, provider or model" data-debug-id="conversation-composer-bridge-chip" className="inline-flex min-w-0 max-w-[50%] shrink items-center gap-1.5" title={`Bridge: ${bridgeLabel || '—'} (current location)`}>
                <Icon name="device" size={12} className="shrink-0" /><span className="min-w-0 truncate font-semibold text-muted">{bridgeLabel || 'no bridge'}</span>
              </button>
              {projectId ? (
                <>
                  <span className="shrink-0 opacity-40">·</span>
                  <button type="button" data-debug-id="conversation-composer-project-chip" onClick={() => openRightPanel('files')} title={`Open project files — ${projectName}`} className="inline-flex min-w-0 max-w-[50%] shrink items-center gap-1.5 rounded-md px-1 py-0.5 hover:bg-neutral-soft hover:text-primary">
                    <Icon name="folder" size={13} className="shrink-0" /><span className="min-w-0 truncate font-semibold text-muted"><VaultText value={projectName} fallback="Project" /></span>
                  </button>
                </>
              ) : null}
            </div>
            <div className="ml-auto shrink-0">
              <Menu
                side="top"
                align="end"
                label="Runtime status"
                open={statusMenuOpen}
                onOpenChange={setStatusMenuOpen}
                trigger={
                  <button type="button" data-debug-id="conversation-runtime-status-chip" title="Runtime status — start/stop the agent" className="inline-flex items-center gap-1.5 rounded-full border border-subtle bg-surface-raised px-2.5 py-1 text-caption text-muted hover:bg-neutral-soft hover:text-primary">
                    <StatusDot size="sm" tone={runtimeStatusToTone(runtimeStatus)} label={needsStart ? 'Stopped' : runtimeStopping ? 'Stopping' : runtimeStateLabel(runtimeStateFromStatus(runtimeStatus))} />
                    {needsStart ? 'Stopped' : (runtimeStopping ? 'Stopping…' : (runtimeStateFromStatus(runtimeStatus) === 'starting' ? 'Starting…' : 'Running'))}
                  </button>
                }
              >
                <Menu.Label>Runtime: {needsStart ? 'Stopped' : (runtimeStopping ? 'Stopping…' : (runtimeStateFromStatus(runtimeStatus) === 'starting' ? 'Starting…' : 'Running'))}</Menu.Label>
                <Menu.Item data-debug-id="conversation-runtime-status-toggle-btn" disabled={!agentInstanceId || runtimeActionBusy || runtimeStopping} onClick={() => void toggleRuntime()} className={needsStart ? 'text-success' : 'text-danger'}>
                  <Icon name={needsStart ? 'play' : 'stop'} size={15} />
                  <span>{needsStart ? 'Start agent' : 'Stop agent'}</span>
                </Menu.Item>
                {reconfigStatus ? <Menu.Label>{reconfigStatus}</Menu.Label> : null}
              </Menu>
            </div>
          </div>

          {/* Terminal pane panel above composer textarea when isPaneExpanded is true */}
          <AgentPaneComposerPanel
            agentInstanceId={agentInstanceId}
            isExpanded={isPaneExpanded}
            onClose={() => {
              userManuallyToggledPaneRef.current = true;
              setIsPaneExpanded(false);
            }}
            onToggleExpand={() => {
              userManuallyToggledPaneRef.current = true;
              setIsPaneExpanded((prev) => !prev);
            }}
            isActiveTab={true}
            runtimeStatus={runtimeStatus}
            startupStatus={startupStatus}
            isStarting={isStarting}
            runCount={instance?.run_count ?? instance?.runCount}
            startedAt={instance?.started_at ?? instance?.startedAt}
            onStreamOutput={handleStreamOutput}
            onStreamReady={handleStreamReady}
            onStreamClosed={handleStreamClosed}
            className="mb-2.5"
          />

          <div className="relative">
            {mentionQuery !== null && (
              <AtMentionPopup
                query={mentionQuery}
                entities={filteredMentions}
                activeIndex={mentionIndex}
                onSelect={handleMentionSelect}
                onClose={() => setMentionQuery(null)}
              />
            )}
            {pendingReconfig && stagedConfigurationIssues.length > 0 ? <div data-debug-id="conversation-apply-blocked-reasons" role="status" className="mb-2 rounded-xl border border-subtle px-3 py-2 text-xs text-muted"><div className="font-medium text-primary">Changes cannot be applied yet</div><ul className="mt-1 list-disc pl-4">{stagedConfigurationIssues.map(issue => <li key={issue}>{issue}</li>)}</ul></div> : null}
            {operation ? <InstanceReconfigurationProgress operation={operation} /> : null}
            {operationBlocksInput ? <div className="mb-3 flex flex-wrap items-center justify-between gap-3 rounded-xl border border-subtle px-3 py-2">
              <p className="min-w-0 flex-1 text-xs text-muted">{operation?.failure_code === 'force_stopping' ? 'Waiting for confirmed termination. Settings will unlock once the agent is stopped.' : 'To change the model or bridge, force stop this run first. Settings unlock after the bridge confirms termination.'}</p>
              <button type="button" data-debug-id="conversation-recovery-force-stop-btn" disabled={stopState.isLoading || reconfigureState.isLoading || retryConfigurationState.isLoading || instanceBridge?.runtime_connected !== true} onClick={() => void forceStopRuntime()} className="min-h-10 rounded-xl border border-danger/30 px-3 text-sm text-danger disabled:opacity-40">Force stop</button>
            </div> : null}
            {(!operationInFlight && (runtimeStopping || isStarting || reconfigStatus)) ? <div data-debug-id="conversation-runtime-transition" role="status" aria-live="polite" className="mb-2 rounded-xl border border-subtle bg-neutral-soft px-3 py-2 text-sm">
              <div className="font-medium text-primary">{runtimeStopping ? 'Stopping agent' : isStarting ? 'Starting agent' : 'Runtime configuration'}</div>
              <div className="mt-0.5 truncate text-xs text-muted">{bridgeLabel || instanceBridgeId || 'Current bridge'}{projectId ? <> · <VaultText value={projectName} fallback="Project" /></> : null}</div>
              {reconfigStatus ? <div className="mt-1 text-xs text-muted">{reconfigStatus}</div> : null}
            </div> : null}
            {conversationReadOnly ? <div data-debug-id="conversation-configuration-read-only" role="status" aria-live="polite" className="rounded-xl border border-subtle bg-neutral-soft px-4 py-3 text-sm">
              <div className="font-semibold text-primary">This conversation is read-only</div>
              <p className="mt-1 text-xs text-muted">Messages are disabled until the following configuration issues are resolved.</p>
              <ul className="mt-2 list-disc space-y-1 pl-4 text-xs text-muted">{configurationIssues.map(issue => <li key={issue}>{issue}</li>)}</ul>
            </div> : (isMobile && !pendingReconfig ? <div className="flex items-end gap-2">
              <div className="min-w-0 flex-1 py-1.5">{composerInput}</div>
              <MessageComposerActions {...composerActions} inline />
            </div> : composerInput)}
          </div>

          {!(isMobile && !pendingReconfig && !conversationReadOnly) ? <MessageComposerActions {...composerActions} readOnly={conversationReadOnly} pendingActions={pendingReconfig ? <div className="flex items-center gap-2">
                <button type="button" data-debug-id="conversation-reconfigure-reset-btn" disabled={runtimeActionBusy || operationBlocksInput} onClick={resetRuntimeConfiguration} className="rounded-xl border border-subtle px-4 py-2 text-sm text-primary disabled:opacity-40">Reset</button>
                <button type="button" data-debug-id="conversation-reconfigure-apply-btn" disabled={runtimeActionBusy || (operation?.phase !== 'recovery_required' && (isStarting || runtimeStopping)) || stagedConfigurationIssues.length > 0} onClick={() => void applyReconfigure()} className="rounded-xl bg-accent px-4 py-2 text-sm font-semibold text-accent-fg disabled:opacity-40">Apply</button>
              </div> : undefined} /> : null}
        </div>
      </div>
      </form>
    );
  }

  const transcript = (
    /* REQ-VIEWPORT-SWEEP-1: a flex COLUMN — the transcript scrolls, the composer dock does not.
       See the composer dock below for why the composer is no longer inside the scroller. */
    <div data-debug-id="conversation-thread-transcript" className="flex w-full min-h-0 min-w-0 max-w-full flex-1 flex-col overflow-x-hidden p-0 sm:px-4 sm:py-3">
      <ChatMessageList
        conversationKey={conversationId}
        messages={transcriptMessages}
        debugPrefix="conversation-thread"
        focusMessageId={focusMessageId}
        hasMore={olderHasMore && Boolean(olderCursor)}
        loadingOlder={olderMessagesState.isFetching}
        onLoadOlder={loadOlderMessages}
        onReply={handleSendReply}
        formatTimestamp={formatMessageTimestamp}
        getDeliveryStatus={deliveryStatusFor}
        agentIsWorking={isWorking}
        renderMessageBody={({ message }) => renderConversationMessageBody(message)}
        wrapperClassName="relative min-h-0 min-w-0 max-w-full flex-1 overflow-hidden overflow-x-hidden"
        scrollClassName="chat-scrollbar h-full min-h-0 max-w-full space-y-3 overflow-y-auto overflow-x-hidden rounded-none bg-canvas px-1 py-3 sm:space-y-4 sm:rounded-[18px] sm:px-4 sm:py-4"
        emptyState={messagesQuery.isFetching ? (
          <div data-debug-id="conversation-thread-empty-state" className="grid h-full min-h-[220px] place-items-center p-6 text-sm text-muted">Loading messages…</div>
        ) : (
          <div data-debug-id="conversation-thread-empty-state" className="flex h-full min-h-[220px] flex-col items-center justify-center gap-4 p-6 text-center">
            <div data-debug-id="conversation-thread-empty-avatar" className="grid h-16 w-16 place-items-center rounded-full bg-neutral-soft text-2xl font-semibold text-primary">
              {(agentDisplayName || 'A').trim().charAt(0).toUpperCase()}
            </div>
            <h3 data-debug-id="conversation-thread-empty-title" className="text-2xl font-semibold text-primary">{agentDisplayName || 'New conversation'}</h3>
            {agentPersona ? (
              <p data-debug-id="conversation-thread-empty-persona" className="max-w-xl whitespace-pre-line text-[15px] leading-relaxed text-muted">{agentPersona}</p>
            ) : (
              <p data-debug-id="conversation-thread-empty-persona" className="max-w-md text-[15px] text-muted">Say something below to get started.</p>
            )}
          </div>
        )}
      />
      {/*
        REQ-VIEWPORT-SWEEP-1 — THE COMPOSER IS A SIBLING OF THE SCROLLER, NOT A CHILD OF IT.
        It used to be passed as `footer` to `ChatMessageList`, which renders into
        `conversation-thread-messages-container` INSIDE the `overflow-y-auto` box
        (REQ-SIMPLIFY-LAYOUT-1 / REQ-SIMPLIFY-SCROLL-4, whose actual targets were the old
        fixed-overlay composer and the mobile chrome hide/reveal — both of which stay
        deleted; this dock is still in-flow and still not a fixed overlay. The exact class
        string of that old overlay is deliberately not repeated here: a static test greps
        the source for it, so quoting it in a comment turns the guard red.)

        Why it could not stay there, measured (`scratch-sweep1/composer-reach.html`, the
        REQ-KBD-1 numbers: layout 812, visible 409):

          composer inside the scroller   keyboard down 631..811 (fold 812) -> visible
                                         keyboard up   631..811 (fold 409) -> 222px PAST IT
          composer as a sibling          keyboard up   228..408 (fold 409) -> visible

        The arithmetic: when the keyboard opens, the shell shrinks, so the scroller's
        `clientHeight` shrinks with it and `maxScrollTop = scrollHeight - clientHeight`
        GROWS by the keyboard's height — measured 614 -> 1017, exactly +403. `scrollTop`
        does not move, so a user who was already at the bottom is now 403px short of it and
        the composer, the last child, is below the fold. Nothing re-scrolls afterwards:
        the browser's own scroll-into-view fires on FOCUS, which happens before the resize,
        and REQ-KBD-3 deleted every scroll ladder and focus handler.

        As a sibling the composer is not scrollable content at all: shrinking the shell
        shrinks only the transcript, and the composer stays above the keyboard by layout
        alone. No keyboard detection, no scroll management, no focus handler — D4 intact.
        Do not pass this back in as `footer`.
      */}
      <div data-debug-id="conversation-thread-composer-dock" className="mx-auto w-full max-w-4xl shrink-0">
        <AgentActivityBubbles instanceId={agentInstanceId} />
        <PinnedShellRuns sessions={pinnedRuns} />
        {renderComposer()}
      </div>
    </div>
  );

  const panelOpen = rightPanel !== 'closed' && Boolean(chainId || projectId || agentInstanceId);

  return (
    <section
      data-debug-id="conversation-thread-page"
      ref={containerRef}
      className="relative flex flex-col sm:flex-row h-full min-h-0 w-full max-w-full overflow-hidden bg-canvas p-0 text-left"
    >
      {/* Mobile (< 640px, Tailwind `sm:`): the panel is a full-width overlay; the chat is hidden behind it when panel is open. */}
      {panelOpen && isBelowSm ? (
        <div className="absolute inset-0 z-30 flex h-full w-full min-h-0 max-w-full flex-col overflow-hidden bg-surface sm:hidden">
          {renderRightPanel(true)}
        </div>
      ) : null}

      {/* Col 1: Chat pane on the left: expands to full width when sidebar is closed or on mobile */}
      <div
        data-debug-id="conversation-chat-column"
        className={`flex h-full w-full min-h-0 min-w-0 flex-1 flex-col overflow-hidden sm:min-w-[380px] ${
          isRightPanelMaximized && panelOpen ? 'hidden' : ''
        }`}
      >
        {/* Scoped top bar in Col 1: narrows automatically when sidebar opens */}
        <header
          data-debug-id="conversation-thread-header"
          className="sticky top-0 z-20 flex shrink-0 items-center gap-2 px-3 py-2 sm:gap-3 sm:px-4 bg-canvas/90 backdrop-blur-md overflow-visible"
        >
          {/* Bottom blur-fade gradient overlay: blurs and softly fades text scrolling underneath */}
          <div
            data-debug-id="conversation-topbar-blur-fade"
            className="pointer-events-none absolute left-0 right-0 -bottom-6 h-6 bg-gradient-to-b from-canvas/90 via-canvas/50 to-transparent backdrop-blur-sm z-10"
            aria-hidden="true"
          />

          <div className="flex min-w-0 flex-1 items-center justify-start gap-1.5">
            {renaming ? (
              <div className="flex min-w-0 flex-1 items-center gap-2">
                <input
                  data-debug-id="conversation-thread-title-input"
                  value={titleDraft}
                  onChange={(event) => { setTitleDraft(event.target.value); setTitleError(''); }}
                  onKeyDown={(event) => {
                    if (event.key === 'Enter') { event.preventDefault(); void saveConversationTitle(); }
                    if (event.key === 'Escape') { setRenaming(false); setTitleError(''); setTitleDraft(editableTitle); }
                  }}
                  className="min-h-9 min-w-0 flex-1 rounded-xl border border-subtle bg-surface px-3 py-1.5 text-base font-semibold text-primary outline-none focus:border-accent sm:text-sm"
                  autoFocus
                />
                <button type="button" data-debug-id="conversation-thread-title-save-btn" aria-label="Save conversation title" title="Save" onClick={() => void saveConversationTitle()} disabled={updateTitleState.isLoading || !titleDraft.trim()} className="grid h-9 w-9 shrink-0 place-items-center rounded-xl bg-accent text-accent-fg hover:opacity-90 disabled:opacity-50"><Icon name="check" size={16} /></button>
                <button type="button" data-debug-id="conversation-thread-title-cancel-btn" aria-label="Cancel title edit" title="Cancel" onClick={() => { setRenaming(false); setTitleError(''); setTitleDraft(editableTitle); }} className="grid h-9 w-9 shrink-0 place-items-center rounded-xl border border-subtle bg-surface-raised text-muted hover:bg-neutral-soft hover:text-primary"><Icon name="close" size={16} /></button>
              </div>
            ) : (
              <div data-debug-id="conversation-thread-breadcrumb" className="flex min-w-0 items-center gap-1.5 text-sm font-medium">
                <span data-debug-id="conversation-breadcrumb-project" className="truncate text-muted"><VaultText value={projectName} fallback="Project" /></span>
                <span className="shrink-0 text-faint">/</span>
                <button
                  type="button"
                  data-debug-id="conversation-thread-title"
                  aria-label="Select task chain"
                  title="Click to search and select task chains"
                  onClick={() => setChainSelectorOpen(true)}
                  className="group flex min-w-0 items-center gap-1.5 rounded-md px-1.5 py-0.5 text-left text-sm font-medium text-primary hover:bg-neutral-soft hover:text-accent transition-colors cursor-pointer"
                >
                  <span className="truncate">
                    <VaultText value={chainTitle || title} as="span" />
                  </span>
                  <Icon name="chevron-down" size={13} className="shrink-0 text-muted group-hover:text-accent" />
                </button>
                <span className="shrink-0 text-faint">/</span>
                <button type="button" data-debug-id="conversation-chain-agent-switcher-btn" aria-label="Switch agent in this task chain" aria-haspopup="dialog" aria-expanded={chainAgentSwitcherOpen} onClick={() => { setChainAgentSwitcherOpen(true); void chainDetailQuery.refetch(); }} className="flex min-w-0 items-center gap-1.5 rounded-md px-1.5 py-0.5 text-primary hover:bg-neutral-soft">
                  <StatusDot size="sm" tone={runtimeStatusToTone(runtimeStatus)} label={needsStart ? 'Stopped' : runtimeStopping ? 'Stopping' : isStarting ? 'Starting' : 'Running'} />
                  <span className="truncate"><VaultText value={chainAgentGroups[0]?.conversations.find(member => member.agentInstanceId === agentInstanceId)?.title || agentDisplayName || agentId} fallback="Agent" /></span>
                  <Icon name="chevron-down" size={13} className="shrink-0 text-muted" />
                </button>
              </div>
            )}
            {titleError ? <div data-debug-id="conversation-thread-title-error" className="mt-1 text-caption text-danger">{titleError}</div> : null}
          </div>

          <button
            type="button"
            data-debug-id="conversation-search-btn"
            aria-label="Search task chains"
            title="Search task chains"
            onClick={() => setChainSelectorOpen(true)}
            className="grid h-10 w-10 shrink-0 place-items-center rounded-xl text-muted hover:bg-neutral-soft hover:text-primary"
          >
            <UiIcon name="search" size={20} />
          </button>

          <div className="shrink-0">
            <Menu
              align="end"
              label="Conversation options"
              open={headerActionsOpen}
              onOpenChange={setHeaderActionsOpen}
              className="w-64 max-w-[calc(100vw-2rem)] z-30"
              trigger={
                <button
                  type="button"
                  data-debug-id="conversation-thread-overflow-menu-btn"
                  aria-label="Conversation options"
                  title="More options"
                  className="grid h-10 w-10 shrink-0 place-items-center rounded-xl text-muted hover:bg-neutral-soft hover:text-primary"
                >
                  <Icon name="more-horizontal" size={20} />
                </button>
              }
            >
              <Menu.Item
                data-debug-id="conversation-thread-rename-action"
                onClick={beginRenameFromHeader}
              >
                <Icon name="pencil" size={15} />
                <span>Rename conversation</span>
              </Menu.Item>
              <Menu.Item
                data-debug-id="conversation-thread-refresh-btn"
                onClick={refreshFromHeader}
              >
                <Icon name="refresh" size={15} />
                <span>Refresh messages</span>
              </Menu.Item>
              <Menu.Separator />
              <div data-debug-id="conversation-thread-overflow-details" role="presentation" className="px-3 py-1.5 text-caption leading-5 text-faint overflow-hidden">
                <div data-debug-id="conversation-thread-agent" className="truncate">Agent: {agentDisplayName || agentId || '—'}</div>
                <div data-debug-id="conversation-thread-instance" className="truncate">Instance: {agentInstanceId || '—'}</div>
                <div data-debug-id="conversation-thread-bridge" className="truncate">Bridge: {bridgeLabel || '—'}</div>
                <div className="flex gap-2"><span data-debug-id="conversation-thread-provider">Provider: {instanceProvider || '—'}</span><span data-debug-id="conversation-thread-model">Model: {instanceModel || '—'}</span></div>
                <div data-debug-id="conversation-thread-status">Status: {runtimeStatus || '—'}</div>
                {chainId ? <div data-debug-id="conversation-thread-chain" className="truncate">Chain: <VaultText value={chainTitle || chainId} as="span" /></div> : null}
              </div>
            </Menu>
          </div>

          {rightPanel === 'closed' && (chainId || projectId || agentInstanceId) ? (
            <button
              type="button"
              data-debug-id="conversation-right-panel-toggle-btn"
              aria-label="Open side panel"
              title="Open panel"
              aria-pressed="false"
              onClick={toggleRightPanel}
              className="relative grid h-10 w-10 shrink-0 place-items-center rounded-xl text-muted hover:bg-neutral-soft hover:text-primary"
            >
              <Icon name="panel-right" size={20} />
              {chainId && chainProgress.total > 0 ? (
                <span
                  data-debug-id="conversation-right-panel-toggle-progress"
                  className="absolute -right-1 -top-1 rounded-full bg-accent px-1 text-[9px] font-bold leading-4 text-accent-fg"
                >
                  {chainProgress.done}/{chainProgress.total}
                </span>
              ) : null}
            </button>
          ) : null}
        </header>

        {transcript}
      </div>

      {/* Desktop (>= 640px, Tailwind `sm:`) vertical resizer divider between chat view and right sidebar */}
      {panelOpen && !isRightPanelMaximized ? (
        <div
          role="separator"
          aria-orientation="vertical"
          aria-label="Resize right sidebar"
          aria-valuenow={sidebarWidth}
          aria-valuemin={RIGHT_SIDEBAR_MIN_WIDTH}
          tabIndex={0}
          data-debug-id="conversation-right-panel-resizer"
          onPointerDown={handleResizerPointerDown}
          onDoubleClick={handleResizerDoubleClick}
          onKeyDown={handleResizerKeyDown}
          className={`hidden sm:flex group relative w-1.5 cursor-col-resize shrink-0 select-none items-center justify-center border-l border-subtle hover:border-accent/50 hover:bg-accent/10 active:bg-accent/20 z-10 ${isDragging ? 'bg-accent/20 border-accent' : ''}`}
        >
          <div className={`h-8 w-0.5 rounded-full ${isDragging ? 'bg-accent' : 'bg-neutral-soft group-hover:bg-accent'}`} />
        </div>
      ) : null}

      {/* Col 2: Desktop (>= 640px, Tailwind `sm:`) right sidebar with smooth 200ms open/close transition & overflow clipping */}
      {!isBelowSm ? (
        <div
          data-debug-id="conversation-right-panel-resizable-container"
          style={{
            width:
              !panelOpen
                ? '0px'
                : isRightPanelMaximized
                ? '100%'
                : `${sidebarWidth}px`,
          }}
          className={`hidden sm:flex h-full min-h-0 overflow-hidden shrink-0 flex-col ${
            isRightPanelMaximized ? 'w-full flex-1 max-w-full min-w-0' : ''
          } ${isDragging ? 'transition-none' : 'transition-[width] duration-200 ease-in-out'}`}
        >
          <div
            style={{
              width: isRightPanelMaximized ? '100%' : `${sidebarWidth}px`,
            }}
            className={`h-full min-h-0 overflow-hidden flex flex-col ${
              isRightPanelMaximized ? 'w-full flex-1 min-w-0' : 'min-w-[360px]'
            }`}
          >
            {renderRightPanel(false)}
          </div>
        </div>
      ) : null}


      <Modal open={runtimeMenuOpen} onOpenChange={setRuntimeMenuOpen} title="Agent settings" size="lg" data-debug-id="conversation-runtime-modal">
        <Modal.Body>{runtimeControls}</Modal.Body>
        <Modal.Footer>
          <button type="button" data-debug-id="conversation-runtime-modal-reset-btn" disabled={!pendingReconfig || runtimeActionBusy || operationBlocksInput} onClick={resetRuntimeConfiguration} className="min-h-11 rounded-xl border border-subtle px-4 py-2 text-sm text-primary disabled:opacity-40">Reset</button>
          <button type="button" data-debug-id="conversation-runtime-modal-apply-btn" disabled={!pendingReconfig || runtimeActionBusy || (operation?.phase !== 'recovery_required' && (isStarting || runtimeStopping)) || stagedConfigurationIssues.length > 0} onClick={() => void applyReconfigure()} className="min-h-11 rounded-xl bg-accent px-4 py-2 text-sm font-semibold text-accent-fg disabled:opacity-40">Apply</button>
        </Modal.Footer>
      </Modal>

      <Modal open={chainAgentSwitcherOpen} onOpenChange={setChainAgentSwitcherOpen} title="Agents in this task chain" size="md" data-debug-id="conversation-chain-agent-modal">
        <Modal.Body>
          <div className="space-y-2">
            {(chainAgentGroups[0]?.conversations || []).map(member => <button key={member.agentInstanceId} type="button" data-debug-id={`conversation-chain-agent-option-${member.agentInstanceId}`} aria-pressed={member.agentInstanceId === agentInstanceId} onClick={() => { setChainAgentSwitcherOpen(false); window.location.hash = buildRouteHash(`/conversations/${encodeURIComponent(member.agentInstanceId)}`, ''); }} className={`flex min-h-14 w-full items-center gap-3 rounded-xl border px-3 py-3 text-left ${member.agentInstanceId === agentInstanceId ? 'border-accent bg-accent/10' : 'border-subtle hover:bg-neutral-soft'}`}>
              <StatusDot size="sm" tone={runtimeStatusToTone(member.runtimeStatus)} label={runtimeStateLabel(runtimeStateFromStatus(member.runtimeStatus))} />
              <span className="min-w-0 flex-1"><span className="block truncate text-sm font-medium text-primary"><VaultText value={member.title} fallback="Agent" /></span>{member.isCoordinator ? <span className="text-xs text-muted">Coordinator</span> : null}</span>
              {member.agentInstanceId === agentInstanceId ? <Icon name="check" size={18} className="text-accent" /> : null}
            </button>)}
            {!chainAgentGroups[0]?.conversations.length ? <p className="text-sm text-muted">No agents are available in this task chain.</p> : null}
          </div>
        </Modal.Body>
      </Modal>

      <TaskChainSelectorModal
        open={chainSelectorOpen}
        onClose={() => setChainSelectorOpen(false)}
        currentChainId={chainId}
        projectId={projectId}
      />

      <CommandPalette
        open={paletteOpen}
        onClose={() => setPaletteOpen(false)}
        onNavigate={(route) => { window.location.hash = buildRouteHash(route, ''); setPaletteOpen(false); }}
        actions={[]}
        conversationGroups={chainAgentGroups}
      />

      {projectId ? (
        <ProjectQuickOpenModal
          projectId={projectId}
          chainId={chainId}
          directories={chainDetailQuery.data?.chain?.directories}
          bridgeId={instanceBridgeId}
          isOpen={isQuickOpenOpen}
          onClose={() => setIsQuickOpenOpen(false)}
          onSelectFile={handleQuickOpenSelectFile}
          onSwitchToCommandPalette={() => {
            setOpenCommandPaletteOnMount(true);
            selectRightPanelTab('files');
          }}
        />
      ) : null}
    </section>
  );
}
