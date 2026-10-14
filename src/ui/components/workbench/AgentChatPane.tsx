import React, {
  type ClipboardEvent,
  type FormEvent,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react';
import { useSelector } from 'react-redux';
import {
  CommandPalette,
  Icon as UiIcon,
  Menu,
  Modal,
  StatusDot,
  runtimeStateFromStatus,
  runtimeStateLabel,
  runtimeStatusToTone,
} from '@ui';
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
  reconfigurationSettled,
  useRestartAgentInstanceMutation,
  useStopAgentInstanceMutation,
} from '../../api/endpoints/agents';
import { useCreateArtifactMutation } from '../../api/endpoints/artifacts';
import { useFetchProjectQuery } from '../../api/endpoints/projects';
import { useGetAgentsLiveQuery } from '../../api/endpoints/agentsLive';
import {
  normalizeBridgeCapabilities,
  useListBridgesQuery,
  type BridgeCapability,
} from '../../api/endpoints/bridgeSupport';
import { useFetchChainTasksQuery, useFetchTaskChainDetailQuery } from '../../api/endpoints/tasks';
import { selectActiveVaultKey } from '../../store/vaultSlice';
import type { AuxContent } from '../../store/auxTabId';
import { buildRouteHash } from '../../utils/appLocation';
import { readComposerDraft, writeComposerDraft } from '../../utils/clientPersistence';
import { conversationConfigurationIssues } from '../../utils/conversationConfigurationValidity';
import {
  isVaultArmored,
  containsVaultArmored,
  decryptVaultText,
  decryptEmbeddedVaultTokens,
} from '../../utils/vaultContent';
import {
  artifactKindForFile,
  artifactLinkFromResponse,
  artifactMimeForFile,
  artifactUploadName,
  clipboardFilesFromEvent,
} from '../../utils/artifactUpload';
import { MAX_UPLOAD_BYTES } from '../ArtifactUpload';
import { ArtifactAttachmentPreview } from '../ArtifactAttachmentPreview';
import Icon from '../Icon';
import Markdown from '../Markdown';
import { VaultText } from '../vault/VaultText';
import { describeCron, formatInTimeZone, timeZoneLabel } from '../actions/scheduleUtils';
import { TaskChainSelectorModal } from '../chains/TaskChainSelectorModal';
import { useIsMobile } from '../shell/responsive';
import {
  ClubbedRunGroup,
  PinnedShellRuns,
  pinnedRunSessions,
  ShellRunRow,
  useConversationRuns,
  type ShellRunMarker,
} from '../shells/ShellRunIndicator';
import AgentActivityBubbles from '../chat/AgentActivityBubbles';
import AtMentionPopup, { type MentionEntity } from '../chat/AtMentionPopup';
import ChatMessageList from '../chat/ChatMessageList';
import InstanceReconfigurationProgress from '../chat/InstanceReconfigurationProgress';
import { MessageComposerInput, MessageComposerActions } from '../chat/MessageComposer';
import RuntimeConfigurationOptions from '../chat/RuntimeConfigurationOptions';
import { type TaskLike } from '../chat/chainTaskInference';
import { groupTranscriptMessages, isAgentStartMessage } from '../chat/transcriptGrouping';
import type { ChatDeliveryStatus, ChatMessage, ChatTimestamp } from '../chat/types';
import type { SplitDirection } from '../../tiling/types';

export const COMPOSER_DRAFT_KEY = 'heimdall:composer:draft';

/**
 * For user-initiated refreshes only; data freshness otherwise comes from tag
 * invalidation. RTK Query throws (error #38) when refetching a query that has not
 * started, e.g. one still skipped while its arguments load.
 */
export function refetchIfStarted(query: { isUninitialized: boolean; refetch: () => unknown }) {
  if (!query.isUninitialized) void query.refetch();
}

export interface AgentChatPaneProps {
  agentInstanceId: string;
  paneId?: string;
  focusMessageId?: string;
  isActiveTab?: boolean;
  isMobile?: boolean;
  /** Main: true when this chat is the only Main pane. */
  isSinglePane?: boolean;
  projectVcsEnabled?: boolean;
  /**
   * 'main' (default): a Main workspace leaf with the full header
   * (`<Project> / <Task chain> / <agent>`, ⋮, [≡]).
   * 'auxSubagent': an aux sub-agent chat tab, transcript + composer ONLY.
   */
  variant?: 'main' | 'auxSubagent';
  /** Opens (or focuses) a tab in the current aux strip. */
  onOpenAuxTab?: (content: AuxContent, title?: string) => void;
  /** Agent switcher: swap the agent shown in this Main pane (deduped by the host). */
  onSwitchAgent?: (agentInstanceId: string, title?: string) => void;
  onSplitPane?: (direction: SplitDirection) => void;
  onReplaceWithNew?: () => void;
  onClosePane?: () => void;
  /** Main: this pane is the focused one (shows its close ✕ in split view). */
  isFocusedPane?: boolean;
  /** Inline before the breadcrumb (hidden-sidebar toggle + app name, top-left pane). */
  headerLeading?: React.ReactNode;
  /** Inline just before the ⋮ menu (update-available badge, top-right pane). */
  headerTrailing?: React.ReactNode;
  /** Inline at the far right (the side-panel toggle, top-right pane). */
  headerEnd?: React.ReactNode;
}

export function stripArtifactLinks(text: string): string {
  return String(text || '')
    .replace(/https?:\/\/[^\s)]+\/api\/v1\/artifacts\/[A-Za-z0-9_-]+\/download/g, '')
    .replace(/\/api\/v1\/artifacts\/[A-Za-z0-9_-]+\/download/g, '')
    .trim();
}

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

function errMsg(err: any, fallback: string): string {
  if (!err) return fallback;
  if (typeof err === 'string') return err;
  return String(
    err.message || err.error || err.data?.error?.message || err.data?.message || fallback,
  );
}

const EMPTY_TIMESTAMP: ChatTimestamp = { label: '', iso: '' };
const EMPTY_DELIVERY: ChatDeliveryStatus = { glyph: '', label: '', tone: '' };

function bridgeId(bridge: any): string {
  return String(bridge?.bridge_id || bridge?.bridgeId || bridge?.id || '');
}
function msgId(m: Message, i: number): string {
  return String(m.message_id || m.messageId || m.id || `idx-${i}`);
}
function msgDir(m: Message): string {
  return String(m.direction || '');
}

function extractMessageArtifactIds(message: Message): string[] | undefined {
  const seen = new Set<string>();
  const out: string[] = [];
  const push = (value: any) => {
    const raw =
      typeof value === 'object' && value !== null
        ? String(value.artifact_id || value.artifactId || value.id || '')
        : String(value || '');
    const id = raw.replace(/^artifact:\/\//i, '').trim();
    if (!id || seen.has(id)) return;
    seen.add(id);
    out.push(id);
  };

  const direct = (message as any).artifact_ids ?? (message as any).artifactIds;
  if (Array.isArray(direct)) direct.forEach(push);

  const artifactIdsJson =
    (message as any).artifact_ids_json ?? (message as any).artifactIdsJson;
  if (typeof artifactIdsJson === 'string' && artifactIdsJson.trim()) {
    try {
      const parsed = JSON.parse(artifactIdsJson);
      if (Array.isArray(parsed)) parsed.forEach(push);
    } catch {
      // ignore invalid json
    }
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

function optimisticPaneCaptureMessage(
  conversationId: string,
  requestId: string,
  agentInstanceId: string,
): Message {
  return {
    message_id: `local_${requestId}`,
    conversation_id: conversationId,
    direction: 'agent_to_user',
    body: 'Requesting pane capture...',
    message_type: 'pane_capture',
    message_status: 'pending',
    metadata: {
      pane_capture_request_id: requestId,
      agent_instance_id: agentInstanceId,
      width: 80,
      line_limit: 120,
    },
    created_unix_ms: Date.now(),
    sending: true,
  };
}

function sentMessageFromResult(result: any): Message | null {
  const candidate =
    result?.message || result?.chat_message || result?.chatMessage || result;
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
    const frame =
      typeof window !== 'undefined' ? window.requestAnimationFrame(scrollToBottom) : 0;
    return () => {
      if (frame && typeof window !== 'undefined') window.cancelAnimationFrame(frame);
    };
  }, [body, messageId]);

  return (
    <pre
      ref={preRef}
      data-debug-id={`conversation-pane-capture-pre-${messageId}`}
      className="chat-scrollbar max-h-[420px] max-w-full overflow-auto whitespace-pre-wrap rounded-xl border border-subtle bg-surface p-3 font-mono text-xs leading-5 text-primary"
    >
      {body}
    </pre>
  );
}

function ThreadMessageBody({ body }: { body: string }) {
  const isArmored = isVaultArmored(body);
  const containsArmored = containsVaultArmored(body);
  const hasVault = isArmored || containsArmored;
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
  const raw =
    (message as any).metadata ??
    (message as any).metadata_json ??
    (message as any).metadataJson;
  if (!raw) return {};
  if (typeof raw === 'object') return raw;
  try {
    return JSON.parse(String(raw));
  } catch {
    return {};
  }
}

function scheduleContextFromMetadata(metadata: any): {
  summary: string;
  triggeredAt: string;
} {
  const meta = metadata && typeof metadata === 'object' ? metadata : {};
  const cronExpr = String(meta.cron_expr ?? meta.cronExpr ?? meta.cron ?? '').trim();
  const timezone = String(meta.timezone ?? meta.time_zone ?? meta.tz ?? '').trim();

  let summary = '';
  if (cronExpr) {
    const described = describeCron(cronExpr);
    summary = timezone ? `${described} (${timezone})` : described;
  }

  let triggeredAt = '';
  const rawTrigger = String(
    meta.target_run_at ?? meta.targetRunAt ?? meta.triggered_at ?? meta.triggeredAt ?? '',
  ).trim();
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
  return (
    coerceUnixMs(message.created_unix_ms ?? message.createdUnixMs) ||
    dateStringToUnixMs(message.created_at || message.createdAt)
  );
}

function formatMessageTimestamp(unixMs: number): ChatTimestamp {
  if (!unixMs) return EMPTY_TIMESTAMP;
  const date = new Date(unixMs);
  if (Number.isNaN(date.getTime())) return EMPTY_TIMESTAMP;
  return {
    label: date.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }),
    iso: date.toISOString(),
  };
}

function looksLikeInternalId(value: string): boolean {
  return /^(agt|inst|chat|conv|usr|brg|task|chain|proj|art)_[a-z0-9]/i.test(
    String(value || '').trim(),
  );
}

function conversationAgentLabel(conversation: any): string {
  const candidates = [
    conversation?.agent_name,
    conversation?.agentName,
    conversation?.agent_display_name,
    conversation?.agentDisplayName,
    conversation?.agent_slug,
    conversation?.agentSlug,
  ];
  for (const value of candidates) {
    const trimmed = String(value || '').trim();
    if (trimmed && !looksLikeInternalId(trimmed)) return trimmed;
  }
  return '';
}

function conversationDisplayTitle(
  conversation: any,
  agentId: string,
  agentInstanceId: string,
  conversationId: string,
): string {
  const rawTitle = String(conversation?.title || '').trim();
  const agentLabel = conversationAgentLabel(conversation);
  if (
    !rawTitle ||
    rawTitle === agentId ||
    rawTitle === agentInstanceId ||
    rawTitle === conversationId ||
    looksLikeInternalId(rawTitle)
  ) {
    return agentLabel || agentId || conversationId;
  }
  return rawTitle;
}

function runtimeNeedsStart(status: string): boolean {
  const normalized = String(status || '').toLowerCase();
  return (
    !normalized ||
    normalized === 'stopped' ||
    normalized === 'failed' ||
    normalized === 'unreachable'
  );
}

function runtimeIsStopping(status: string): boolean {
  return String(status || '').toLowerCase() === 'stopping';
}

function deliveryStatusFor(message: ChatMessage): ChatDeliveryStatus {
  if (!message.isUser) return EMPTY_DELIVERY;
  if (message.sending) return { glyph: '…', label: 'Sending', tone: 'text-muted' };
  if (message.deliveryFailedUnixMs > 0)
    return {
      glyph: '!',
      label: message.deliveryError || 'Delivery failed',
      tone: 'text-danger',
    };
  if (message.readUnixMs > 0) return { glyph: '✓✓', label: 'Read', tone: 'text-success' };
  if (message.deliveredUnixMs > 0)
    return { glyph: '✓', label: 'Delivered', tone: 'text-muted' };
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
      const sender = String(
        message.sender_agent_instance_id || message.senderAgentInstanceId || '',
      );
      const messageType = String(
        (message as any).message_type || (message as any).messageType || 'text',
      );
      const authorLabel = isUser
        ? 'you'
        : messageType === 'system'
        ? ''
        : sender || agentLabel || 'agent';
      const artifactIds = extractMessageArtifactIds(message);
      return {
        order: index,
        chatMessage: {
          key: id || `${direction}-${createdUnixMs}-${index}`,
          messageId: id,
          body: String(message.body || ''),
          isUser,
          createdUnixMs,
          deliveredUnixMs:
            coerceUnixMs(message.delivered_unix_ms ?? message.deliveredUnixMs) ||
            dateStringToUnixMs(message.delivered_at ?? message.deliveredAt),
          readUnixMs:
            coerceUnixMs(message.read_unix_ms ?? message.readUnixMs) ||
            dateStringToUnixMs(message.read_at ?? message.readAt),
          deliveryFailedUnixMs:
            coerceUnixMs(
              message.delivery_failed_unix_ms ?? message.deliveryFailedUnixMs,
            ) ||
            dateStringToUnixMs(message.delivery_failed_at ?? message.deliveryFailedAt),
          deliveryError: String(message.delivery_error || message.deliveryError || ''),
          sending: Boolean(message.sending),
          authorLabel,
          artifactIds,
          messageType,
          messageStatus: String(
            (message as any).message_status || (message as any).messageStatus || 'complete',
          ),
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

export function AgentChatPane({
  agentInstanceId: routeInstanceId,
  focusMessageId,
  isActiveTab = true,
  isMobile: explicitIsMobile,
  isSinglePane = true,
  variant = 'main',
  onOpenAuxTab,
  onSwitchAgent,
  onSplitPane,
  onReplaceWithNew,
  onClosePane,
  isFocusedPane = false,
  headerLeading,
  headerTrailing,
  headerEnd,
}: AgentChatPaneProps) {
  const isMobileHook = useIsMobile();
  const isMobile = explicitIsMobile ?? isMobileHook;
  const isAuxSubagent = variant === 'auxSubagent';

  const convQuery = useFetchConversationQuery(
    { conversationId: '', agentInstanceId: routeInstanceId },
    { skip: !routeInstanceId, pollingInterval: 10000, skipPollingIfUnfocused: true },
  );
  const conversation = convQuery.data?.conversation || null;
  const conversationId = String(
    conversation?.conversation_id || conversation?.conversationId || '',
  );
  const messagesQuery = useFetchConversationMessagesQuery(
    { conversationId },
    { skip: !conversationId, pollingInterval: 10000, skipPollingIfUnfocused: true },
  );
  const [fetchOlderMessages, olderMessagesState] = useLazyFetchConversationMessagesQuery();
  const [updateConversationTitle, updateTitleState] = useUpdateConversationTitleMutation();
  const [requestPaneCapture, requestPaneCaptureState] = useRequestPaneCaptureMutation();
  const [sendMessage] = useSendConversationMessageMutation();
  const [markRead] = useMarkConversationReadMutation();
  const [reconfigureInstance, reconfigureState] = useApplyInstanceConfigurationMutation();
  const [retryConfiguration, retryConfigurationState] =
    useRetryInstanceConfigurationMutation();
  const [restartInstance, restartState] = useRestartAgentInstanceMutation();
  const [stopInstance, stopState] = useStopAgentInstanceMutation();
  const [createArtifact] = useCreateArtifactMutation();

  const agentId = String(conversation?.agent_id || conversation?.agentId || '');
  const agentInstanceId = String(
    conversation?.agent_instance_id || conversation?.agentInstanceId || routeInstanceId,
  );
  const conversationRuntimeStatusForPoll = String(
    conversation?.runtime_status || conversation?.runtimeStatus || '',
  );
  const chainId = String(conversation?.chain_id || conversation?.chainId || '');
  const isMultiPane = !isSinglePane;
  const title = conversationDisplayTitle(
    conversation,
    agentId,
    agentInstanceId,
    conversationId,
  );

  const configurationInputBlockedRef = useRef(false);

  const chainTasksQuery = useFetchChainTasksQuery({ chainId }, { skip: !chainId });
  const chainDetailQuery = useFetchTaskChainDetailQuery(
    { chainId },
    { skip: !chainId, pollingInterval: 120000 },
  );
  const chainProgress = useMemo(() => {
    const allTasks: TaskLike[] = (chainDetailQuery.data?.chain?.tasks ||
      chainTasksQuery.data?.tasks ||
      []) as TaskLike[];
    const tasks = allTasks.filter((t: TaskLike) => t.status !== 'cancelled');
    const total = tasks.length;
    const done = tasks.filter(
      (t: TaskLike) => t.status === 'validated_good' || t.status === 'completed',
    ).length;
    return { total, done };
  }, [chainDetailQuery.data, chainTasksQuery.data]);
  const rawTitle = String(conversation?.title || '').trim();
  const editableTitle = rawTitle && !looksLikeInternalId(rawTitle) ? rawTitle : title;
  const chainTitle = String(chainDetailQuery.data?.chain?.title || '').trim();

  const lastInstanceStatusRef = useRef('');
  const pollHint = lastInstanceStatusRef.current || conversationRuntimeStatusForPoll;
  const instancePollInterval =
    runtimeStateFromStatus(pollHint) === 'starting' ? 2500 : 8000;
  const instanceQuery = useFetchAgentInstanceQuery(
    { instanceId: agentInstanceId },
    {
      skip: !agentInstanceId,
      pollingInterval: instancePollInterval,
      skipPollingIfUnfocused: true,
    },
  );
  const instance = instanceQuery.data?.instance || null;
  const { data: liveProjects } = useGetAgentsLiveQuery(undefined, {
    pollingInterval: 30000,
    skipPollingIfUnfocused: true,
  });
  const agentIdentityQuery = useFetchAgentIdentityQuery({ agentId }, { skip: !agentId });
  const agentIdentity = agentIdentityQuery.data?.agent || null;
  const agentDisplayName = String(
    agentIdentity?.name || conversationAgentLabel(conversation) || agentId || '',
  ).trim();
  const agentPersona = String(
    agentIdentity?.instructions ||
      agentIdentity?.persona ||
      agentIdentity?.template_persona ||
      '',
  ).trim();
  useEffect(() => {
    const s = String(instance?.runtime_status || instance?.runtimeStatus || '');
    if (s) lastInstanceStatusRef.current = s;
  }, [instance?.runtime_status, instance?.runtimeStatus]);
  const instanceProvider = String(instance?.provider || '');
  const instanceModel = String(instance?.model || '');
  const instanceBridgeId = String(instance?.bridge_id || instance?.bridgeId || '');
  const projectId = String(
    instance
      ? instance.project_id ?? instance.projectId ?? ''
      : conversation?.project_id || conversation?.projectId || '',
  );
  const projectQuery = useFetchProjectQuery({ projectId }, { skip: !projectId });
  const projectName = String(
    projectQuery.data?.project?.name ||
      projectQuery.data?.project?.display_name ||
      projectId ||
      '',
  ).trim();
  const conversationRuntimeStatus = String(
    conversation?.runtime_status || conversation?.runtimeStatus || '',
  );
  const runtimeStatus = String(
    instance?.runtime_status || instance?.runtimeStatus || conversationRuntimeStatus || '',
  );
  const startupStatus = String(
    instance?.startup_status ||
      instance?.startupStatus ||
      conversation?.startup_status ||
      conversation?.startupStatus ||
      '',
  ).toLowerCase();
  const isStarting =
    startupStatus === 'starting' || runtimeStateFromStatus(runtimeStatus) === 'starting';
  const activityStatus = String(
    instance?.activity_status || instance?.activityStatus || '',
  ).toLowerCase();
  const isWorking =
    runtimeStateFromStatus(runtimeStatus) === 'live' &&
    (activityStatus === 'active' ||
      activityStatus === 'busy' ||
      activityStatus === 'working');

  const [stagedBridgeId, setStagedBridgeId] = useState<string | null>(null);
  const [provider, setProvider] = useState('');
  const [model, setModel] = useState('');
  const [runtimeMenuOpen, setRuntimeMenuOpen] = useState(false);
  const editingRuntime =
    runtimeMenuOpen ||
    stagedBridgeId !== null ||
    Boolean(provider && provider !== instanceProvider) ||
    Boolean(model && model !== instanceModel);
  const bridgesQuery = useListBridgesQuery(undefined, {
    pollingInterval: editingRuntime ? 5000 : 30000,
    skipPollingIfUnfocused: true,
  });
  useEffect(() => {
    if (runtimeMenuOpen) refetchIfStarted(bridgesQuery);
  }, [runtimeMenuOpen]);
  const bridges = bridgesQuery.data?.bridges || [];
  const instanceBridge = useMemo(
    () => bridges.find((b: any) => bridgeId(b) === instanceBridgeId),
    [bridges, instanceBridgeId],
  );

  const baseMessages: Message[] = messagesQuery.data?.messages || [];
  const [olderMessages, setOlderMessages] = useState<Message[]>([]);
  const [olderCursor, setOlderCursor] = useState('');
  const [olderHasMore, setOlderHasMore] = useState(false);

  // Per-agent composer draft state isolated by routeInstanceId, with fallback to COMPOSER_DRAFT_KEY
  const loadedDraftAgentIdRef = useRef<string>(routeInstanceId);
  const [draft, setDraft] = useState<string>(() => readComposerDraft(routeInstanceId));

  useEffect(() => {
    if (loadedDraftAgentIdRef.current !== routeInstanceId) {
      const nextDraft = readComposerDraft(routeInstanceId);
      loadedDraftAgentIdRef.current = routeInstanceId;
      setDraft(nextDraft);
      return;
    }
    writeComposerDraft(routeInstanceId, draft);
  }, [routeInstanceId, draft]);

  const updateDraft = useCallback(
    (value: string) => {
      setDraft(value);
      if (loadedDraftAgentIdRef.current === routeInstanceId) {
        writeComposerDraft(routeInstanceId, value);
      }
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
    },
    [routeInstanceId],
  );

  // Context surfaces (files, terminal, ...) open as tabs in the aux dock.
  const openAux = useCallback(
    (content: AuxContent, auxTitle?: string) => {
      onOpenAuxTab?.(content, auxTitle);
    },
    [onOpenAuxTab],
  );

  const handleOpenPtyTab = useCallback(() => {
    const label = agentDisplayName || editableTitle || agentInstanceId;
    openAux({ type: 'agentPty', agentInstanceId }, `${label} terminal`);
  }, [agentDisplayName, editableTitle, agentInstanceId, openAux]);

  const [mentionQuery, setMentionQuery] = useState<string | null>(null);
  const [mentionIndex, setMentionIndex] = useState(0);
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const composerContainerRef = useRef<HTMLFormElement | HTMLDivElement | null>(null);
  const [error, setError] = useState('');
  const [attachments, setAttachments] = useState<PendingAttachment[]>([]);
  const [localMessages, setLocalMessages] = useState<Message[]>([]);
  const settingsEditedRef = useRef(false);
  const [acceptedOperation, setAcceptedOperation] =
    useState<InstanceReconfiguration | null>(null);
  const [reconfigStatus, setReconfigStatus] = useState('');
  const [isSmallComposer, setIsSmallComposer] = useState(false);

  const mentionEntities = useMemo<MentionEntity[]>(() => {
    const items: MentionEntity[] = [];
    for (const proj of liveProjects ?? []) {
      const pName = String(proj.name || proj.projectId || '');
      items.push({
        type: 'project',
        id: String(proj.projectId || ''),
        label: pName,
        sublabel: 'project',
      });
      for (const chain of proj.chains ?? []) {
        items.push({
          type: 'chain',
          id: String(chain.chainId || ''),
          label: String(chain.title || chain.chainId || ''),
          sublabel: pName,
        });
        for (const agent of chain.liveAgents ?? []) {
          items.push({
            type: 'agent',
            id: String(agent.agentInstanceId || ''),
            label: String(agent.displayName || agent.agentInstanceId || ''),
            sublabel: String(chain.title || ''),
          });
        }
      }
    }
    return items;
  }, [liveProjects]);

  const filteredMentions = useMemo(() => {
    if (mentionQuery === null) return [] as MentionEntity[];
    const q = mentionQuery.toLowerCase();
    return mentionEntities
      .filter(
        (e) => !q || e.label.toLowerCase().includes(q) || e.id.toLowerCase().includes(q),
      )
      .slice(0, 8);
  }, [mentionEntities, mentionQuery]);

  function handleMentionSelect(entity: MentionEntity) {
    const ta = textareaRef.current;
    const pos = ta?.selectionStart ?? draft.length;
    const before = draft.slice(0, pos);
    const after = draft.slice(pos);
    const newBefore = before.replace(/@([^\s@]*)$/, `@${entity.id}`);
    updateDraft(newBefore + after);
    setMentionQuery(null);
    setMentionIndex(0);
    setTimeout(() => {
      ta?.focus();
      const np = newBefore.length;
      ta?.setSelectionRange(np, np);
    }, 0);
  }

  useEffect(() => {
    setLocalMessages([]);
    setOlderMessages([]);
    setOlderCursor('');
    setOlderHasMore(false);
    setError('');
  }, [routeInstanceId]);

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

  const [statusMenuOpen, setStatusMenuOpen] = useState(false);
  const [headerActionsOpen, setHeaderActionsOpen] = useState(false);
  const [paletteOpen, setPaletteOpen] = useState(false);
  const [chainSelectorOpen, setChainSelectorOpen] = useState(false);
  const [chainAgentSwitcherOpen, setChainAgentSwitcherOpen] = useState(false);

  const chainAgentGroups = useMemo(() => {
    const chain = chainDetailQuery.data?.chain;
    const members = (chain?.members || []) as any[];
    if (!chainId || members.length === 0) return [];
    const coordinator = String(chain?.coordinatorAgentInstanceId || '');
    return [
      {
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
      },
    ];
  }, [chainDetailQuery.data, chainId]);

  const fileInputRef = useRef<HTMLInputElement | null>(null);

  const [renaming, setRenaming] = useState(false);
  const [titleDraft, setTitleDraft] = useState('');
  const [titleError, setTitleError] = useState('');

  const destinationBridgeId = stagedBridgeId ?? instanceBridgeId;
  const destinationProjectId = projectId;
  const destinationBridge = bridges.find(
    (item: any) => bridgeId(item) === destinationBridgeId,
  );
  const destinationProjectQuery = projectQuery;
  const operationQuery = useListInstanceReconfigurationsQuery(
    { instanceId: agentInstanceId },
    {
      skip: !agentInstanceId,
      pollingInterval:
        acceptedOperation &&
        !['ready', 'failed', 'recovery_required'].includes(acceptedOperation.phase)
          ? 2000
          : 8000,
    },
  );
  const serverOperation = operationQuery.data?.operations?.[0];
  const operation =
    acceptedOperation &&
    (!serverOperation ||
      (serverOperation.operation_id === acceptedOperation.operation_id &&
        serverOperation.revision < acceptedOperation.revision))
      ? acceptedOperation
      : serverOperation;
  const operationInFlight = Boolean(
    operation &&
      ['prepared', 'stopping', 'source_stopped', 'launching'].includes(operation.phase),
  );
  const operationBlocksInput = Boolean(
    operation &&
      operation.phase !== 'ready' &&
      !(
        operation.phase === 'failed' &&
        (operation.failure_code === 'recovery_stopped' ||
          (!operation.source_stopped && !operation.destination_committed))
      ),
  );
  const bridgeLabel = String(
    instanceBridge?.label || instanceBridge?.machine_hostname || instanceBridgeId || '',
  );
  const currentCaps = useMemo(
    () => normalizeBridgeCapabilities(instanceBridge),
    [instanceBridge],
  );
  const caps = useMemo(
    () => normalizeBridgeCapabilities(destinationBridge),
    [destinationBridge],
  );

  const providerOptions = useMemo(() => {
    const list = caps.map((c) => c.provider).filter(Boolean);
    if (instanceProvider && !list.includes(instanceProvider)) list.push(instanceProvider);
    return Array.from(new Set(list)).sort();
  }, [caps, instanceProvider]);
  const modelOptions = useMemo(() => {
    const selectedProvider = provider || instanceProvider || providerOptions[0] || '';
    const cap = caps.find((c) => c.provider === selectedProvider);
    const t = capModels(cap);
    const ordered = modelOrder
      .filter((x) => t.includes(x))
      .concat(t.filter((x) => !modelOrder.includes(x)));
    if (instanceModel && !ordered.includes(instanceModel)) ordered.unshift(instanceModel);
    return ordered;
  }, [caps, provider, providerOptions, instanceProvider, instanceModel]);

  const chatMessages = useMemo(
    () =>
      normalizeConversationMessages(
        [...olderMessages, ...baseMessages, ...localMessages],
        agentId || agentInstanceId,
      ),
    [olderMessages, baseMessages, localMessages, agentId, agentInstanceId],
  );

  const activeVaultKey = useSelector(selectActiveVaultKey);
  const hasLockedVaultMessages = useMemo(
    () =>
      !activeVaultKey &&
      chatMessages.some(
        (m) => isVaultArmored(m.body) || containsVaultArmored(m.body),
      ),
    [activeVaultKey, chatMessages],
  );

  const runMarkers: ShellRunMarker[] = useMemo(
    () =>
      chatMessages
        .filter((message) => message.messageType === 'shell_run')
        .map((message) => ({
          messageId: message.messageId,
          sessionId: String(
            message.metadata?.session_id || message.metadata?.sessionId || '',
          ),
          createdUnixMs: message.createdUnixMs || 0,
        }))
        .filter((marker) => Boolean(marker.sessionId)),
    [chatMessages],
  );

  const lastConversationMessageMs = useMemo(
    () =>
      chatMessages.reduce(
        (newest, message) =>
          message.messageType === 'shell_run' || isAgentStartMessage(message)
            ? newest
            : Math.max(newest, message.createdUnixMs || 0),
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

  const pinnedSessionIds = useMemo(
    () => new Set(pinnedRuns.map((session) => session.session_id)),
    [pinnedRuns],
  );
  const transcriptMessages = useMemo(
    () => groupTranscriptMessages(chatMessages, pinnedSessionIds),
    [chatMessages, pinnedSessionIds],
  );

  const needsStart = runtimeNeedsStart(runtimeStatus);
  const runtimeStopping = runtimeIsStopping(runtimeStatus);
  const runtimeActionBusy =
    operationInFlight ||
    retryConfigurationState.isLoading ||
    reconfigureState.isLoading ||
    restartState.isLoading ||
    stopState.isLoading;
  const hasUploadingAttachments = attachments.some((item) => item.status === 'uploading');
  const hasFailedAttachments = attachments.some((item) => item.status === 'error');
  const uploadedAttachments = attachments.filter(
    (item) => item.status === 'uploaded' && item.id,
  );

  const pendingPaneCapture = chatMessages.some(
    (message) =>
      message.messageType === 'pane_capture' && message.messageStatus === 'pending',
  );
  const paneCaptureDisabled =
    !agentInstanceId ||
    needsStart ||
    runtimeStopping ||
    pendingPaneCapture ||
    requestPaneCaptureState.isLoading;

  useEffect(() => {
    if (!renaming) setTitleDraft(editableTitle);
  }, [editableTitle, renaming]);
  useEffect(() => {
    if (
      isActiveTab &&
      agentInstanceId &&
      conversationId &&
      (conversation?.unread_count || conversation?.unreadCount)
    ) {
      void markRead({ conversationId });
    }
  }, [isActiveTab, conversationId, agentInstanceId, conversation?.unread_count, conversation?.unreadCount]);
  useEffect(() => {
    if (settingsEditedRef.current) return;
    setProvider(instanceProvider);
    setModel(instanceModel);
  }, [instanceProvider, instanceModel]);
  const observedOperationRef = useRef<InstanceReconfiguration | undefined>(undefined);
  useEffect(() => {
    observedOperationRef.current = undefined;
    settingsEditedRef.current = false;
    setStagedBridgeId(null);
    setAcceptedOperation(null);
    setProvider(instanceProvider);
    setModel(instanceModel);
    setReconfigStatus('');
  }, [agentInstanceId]);
  useEffect(() => {
    if (
      !operation ||
      !operationBlocksInput ||
      operation.failure_code === 'force_stopping'
    )
      return;
    settingsEditedRef.current = true;
    setStagedBridgeId(operation.destination.bridge_id);
    setProvider(operation.destination.provider);
    setModel(operation.destination.model);
  }, [operation?.operation_id, operation?.phase]);
  // React to an operation settling WHILE this pane watches it, never to a settled
  // operation it merely loads (an instance reconfigured long ago reports `ready` on
  // every open). Refreshing the instance, conversation and messages is the API
  // layer's job (listInstanceReconfigurations invalidates their tags).
  useEffect(() => {
    const previous = observedOperationRef.current;
    observedOperationRef.current = operation;
    if (!operation || !reconfigurationSettled(previous, operation)) return;
    setAcceptedOperation(null);
    setReconfigStatus('');
    if (operation.phase !== 'ready') return;
    settingsEditedRef.current = false;
    setStagedBridgeId(null);
    setProvider(operation.destination.provider);
    setModel(operation.destination.model);
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
    setLocalMessages((current) =>
      current.filter((message, index) => {
        const id = msgId(message, index);
        return !id || id.startsWith('local_') || !serverIds.has(id);
      }),
    );
  }, [baseMessages, localMessages.length]);
  useEffect(() => {
    if (olderMessages.length > 0) return;
    setOlderCursor(String(messagesQuery.data?.nextCursor || ''));
    setOlderHasMore(Boolean(messagesQuery.data?.hasMore));
  }, [messagesQuery.data?.nextCursor, messagesQuery.data?.hasMore, olderMessages.length]);

  const effectiveProvider = provider || instanceProvider;
  const effectiveModel = model || instanceModel;
  const selectionChangesConfig =
    Boolean(agentInstanceId) &&
    (destinationBridgeId !== instanceBridgeId ||
      (effectiveProvider && effectiveProvider !== instanceProvider) ||
      (effectiveModel && effectiveModel !== instanceModel));
  const validityInput = {
    instanceLoaded: Boolean(instance),
    instanceError: instanceQuery.isError,
    bridgeId: instanceBridgeId,
    bridge: instanceBridge,
    bridgesLoaded: Boolean(bridgesQuery.data),
    bridgesError: bridgesQuery.isError,
    projectId,
    project: projectQuery.data?.project,
    projectLoaded: Boolean(projectQuery.data),
    projectError: projectQuery.isError,
    provider: instanceProvider,
    model: instanceModel,
    capabilities: currentCaps,
  };
  const configurationIssues = conversationConfigurationIssues(validityInput);
  const stagedConfigurationIssues = conversationConfigurationIssues({
    ...validityInput,
    bridgeId: destinationBridgeId,
    bridge: destinationBridge,
    projectId: destinationProjectId,
    project: destinationProjectQuery.data?.project,
    projectLoaded: Boolean(destinationProjectQuery.data),
    projectError: destinationProjectQuery.isError,
    provider: effectiveProvider,
    model: effectiveModel,
    capabilities: caps,
  });
  if (
    destinationBridge &&
    destinationBridge.runtime_connected !== true &&
    !stagedConfigurationIssues.some((issue) =>
      issue.includes('connection is disconnected'),
    )
  ) {
    stagedConfigurationIssues.push(
      'Destination bridge is not connected. Reconnect it or choose a connected bridge before Apply.',
    );
  }
  if (destinationBridge && !destinationBridge.reconfiguration_supported) {
    stagedConfigurationIssues.push(
      'Update the destination bridge before applying configuration changes.',
    );
  }
  if (instanceBridge && !instanceBridge.reconfiguration_supported) {
    stagedConfigurationIssues.push(
      'Update the source bridge before applying configuration changes.',
    );
  }
  if (operation?.failure_code === 'force_stopping') {
    stagedConfigurationIssues.push(
      'Waiting for Force stop confirmation before allowing Apply.',
    );
  }
  if (operationBlocksInput) {
    configurationIssues.push(
      operation?.failure_message ||
        'Configuration change is in progress. Messages are disabled until the destination is ready.',
    );
  }
  if (operationQuery.isLoading) {
    configurationIssues.push(
      'Checking for an in-progress configuration change before allowing messages.',
    );
  }
  if (operationQuery.isError) {
    configurationIssues.push(
      'Configuration operation state could not be verified. Refresh before sending.',
    );
  }
  const conversationReadOnly = configurationIssues.length > 0;
  const configurationInputBlocked =
    conversationReadOnly ||
    selectionChangesConfig ||
    runtimeActionBusy ||
    runtimeStopping ||
    isStarting;
  configurationInputBlockedRef.current = Boolean(configurationInputBlocked);
  const sendDisabled =
    configurationInputBlocked ||
    hasUploadingAttachments ||
    hasFailedAttachments ||
    (!draft.trim() && uploadedAttachments.length === 0);

  async function saveConversationTitle() {
    const next = titleDraft.trim();
    if (!next) {
      setTitleError('Title is required.');
      return;
    }
    setTitleError('');
    try {
      await updateConversationTitle({ conversationId, title: next }).unwrap();
      setRenaming(false);
    } catch (err: any) {
      setTitleError(errMsg(err, 'Rename failed'));
    }
  }

  async function loadOlderMessages() {
    if (!olderCursor || olderMessagesState.isFetching) return;
    setError('');
    try {
      const data = await fetchOlderMessages({
        conversationId,
        limit: 30,
        cursor: olderCursor,
      }).unwrap();
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
    const localId =
      existingLocalId || `att_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
    const name = artifactUploadName(file, 'conversation-attachment');
    const tooLarge = file.size > MAX_UPLOAD_BYTES;
    setError('');
    setAttachments((current) => {
      const without = current.filter((item) => item.localId !== localId);
      return [
        ...without,
        {
          localId,
          id: '',
          name,
          file,
          status: tooLarge ? 'error' : 'uploading',
          error: tooLarge
            ? `File is too large. Maximum upload size is ${Math.round(
                MAX_UPLOAD_BYTES / (1024 * 1024),
              )} MB.`
            : '',
        },
      ];
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
      setAttachments((current) =>
        current.map((item) =>
          item.localId === localId ? { ...item, id, status: 'uploaded', error: '' } : item,
        ),
      );
    } catch (err: any) {
      setAttachments((current) =>
        current.map((item) =>
          item.localId === localId
            ? { ...item, status: 'error', error: errMsg(err, 'Upload failed') }
            : item,
        ),
      );
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
    const attachmentIds = uploadedAttachments.map((a) => a.id);
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
      const result = await sendMessage({
        conversationId,
        body: sendBody,
        artifactIds: attachmentIds,
      }).unwrap();
      const sent = sentMessageFromResult(result);
      setLocalMessages((current) =>
        current.map((message) => {
          if (msgId(message, 0) !== localId) return message;
          return sent
            ? {
                ...sent,
                body: String(sent.body || sendBody),
                direction: sent.direction || 'user_to_agent',
                artifact_ids_json:
                  (sent as any).artifact_ids_json || JSON.stringify(attachmentIds),
              }
            : { ...message, sending: false };
        }),
      );
    } catch (err: any) {
      const message = errMsg(err, 'Send failed');
      setLocalMessages((current) =>
        current.map((item) =>
          msgId(item, 0) === localId ? failedLocalMessage(item, message) : item,
        ),
      );
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
      const result = await sendMessage({
        conversationId,
        body: sendBody,
        artifactIds: [],
      }).unwrap();
      const sent = sentMessageFromResult(result);
      setLocalMessages((current) =>
        current.map((message) => {
          if (msgId(message, 0) !== localId) return message;
          return sent
            ? {
                ...sent,
                body: String(sent.body || sendBody),
                direction: sent.direction || 'user_to_agent',
                artifact_ids_json: '[]',
              }
            : { ...message, sending: false };
        }),
      );
    } catch (err: any) {
      const message = errMsg(err, 'Send failed');
      setLocalMessages((current) =>
        current.map((item) =>
          msgId(item, 0) === localId ? failedLocalMessage(item, message) : item,
        ),
      );
    }
  }

  async function requestPane() {
    if (paneCaptureDisabled) return;
    const requestId = `cap_local_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
    const local = optimisticPaneCaptureMessage(
      conversationId,
      requestId,
      agentInstanceId,
    );
    const localId = msgId(local, 0);
    setError('');
    setLocalMessages((current) => [...current, local]);
    try {
      const result = await requestPaneCapture({
        conversationId,
        width: 80,
        settleMs: 3000,
        lineLimit: 120,
      }).unwrap();
      const serverMessage = result?.message || null;
      setLocalMessages((current) =>
        current.map((message) =>
          msgId(message, 0) === localId && serverMessage
            ? { ...serverMessage, sending: false }
            : message,
        ),
      );
    } catch (err: any) {
      const message = errMsg(err, 'Pane capture request failed');
      setLocalMessages((current) =>
        current.map((item) =>
          msgId(item, 0) === localId ? failedPaneCaptureMessage(item, message) : item,
        ),
      );
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
    refetchIfStarted(messagesQuery);
  }

  function renderConversationMessageBody(message: ChatMessage) {
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
      const sessionId = String(
        message.metadata?.session_id || message.metadata?.sessionId || '',
      );
      const session = sessionId ? runBySessionId.get(sessionId) : undefined;
      if (!session) return null;
      return <ShellRunRow session={session} />;
    }
    if (message.messageType === 'pane_capture') {
      const metadata = message.metadata || {};
      const status = message.messageStatus || 'complete';
      const lineCount = Number(metadata.line_count || metadata.lineCount || 0);
      return (
        <div
          data-debug-id={
            status === 'pending'
              ? `conversation-pane-capture-loading-${message.messageId}`
              : status === 'failed'
              ? `conversation-pane-capture-error-${message.messageId}`
              : `conversation-pane-capture-output-${message.messageId}`
          }
          className={`rounded-2xl border p-3 ${
            status === 'failed'
              ? 'border-danger/30 bg-danger-soft text-danger'
              : 'border-info/30 bg-info-soft text-info'
          }`}
        >
          <div className="mb-2 flex flex-wrap items-center gap-2 text-caption uppercase tracking-wide text-info">
            <span>
              {status === 'pending'
                ? 'Requesting terminal pane…'
                : status === 'failed'
                ? 'Pane capture failed'
                : 'Terminal pane capture'}
            </span>
            <span>{Number(metadata.width || 80)} cols</span>
            {lineCount ? <span>{lineCount} lines</span> : null}
            {metadata.truncated ? <span>truncated</span> : null}
          </div>
          {status === 'pending' ? (
            <div className="text-sm text-info">
              Waiting for the wrapper to resize and capture the pane…
            </div>
          ) : (
            <PaneCaptureOutput body={message.body} messageId={message.messageId} />
          )}
          {status === 'failed' ? (
            <button
              type="button"
              data-debug-id={`conversation-pane-capture-retry-${message.messageId}`}
              onClick={() => void requestPane()}
              disabled={paneCaptureDisabled}
              className="mt-2 rounded-full border border-subtle bg-surface px-3 py-1 text-xs text-primary hover:bg-surface-raised disabled:opacity-50"
            >
              Retry
            </button>
          ) : null}
        </div>
      );
    }
    if (message.messageType === 'configuration_change') {
      const metadata = message.metadata || {};
      const source = metadata.source || {};
      const destination = metadata.destination || {};
      const fields = [
        { name: 'Bridge', key: 'bridge_id', label: 'bridge_label' },
        { name: 'Project', key: 'project_id', label: 'project_label' },
        { name: 'Provider', key: 'provider', label: 'provider' },
        { name: 'Model', key: 'model', label: 'model' },
      ].filter((field) => source[field.key] !== destination[field.key]);
      return (
        <div
          data-debug-id={`conversation-configuration-event-${message.messageId}`}
          className="py-2 text-xs text-muted"
        >
          <span className="font-medium">{message.body}</span>
          {fields.map((field) => (
            <span key={field.key}>
              {' '}
              · {field.name}:{' '}
              <VaultText
                value={source[field.label] || source[field.key] || 'None'}
                fallback={source[field.key] || 'None'}
              />{' '}
              →{' '}
              <VaultText
                value={destination[field.label] || destination[field.key] || 'None'}
                fallback={destination[field.key] || 'None'}
              />
            </span>
          ))}
          {metadata.failure_message ? (
            <div className="mt-1 text-danger">{metadata.failure_message}</div>
          ) : null}
        </div>
      );
    }
    if (message.messageType === 'agent_start_clubbed') {
      const count = message.metadata?.count || 2;
      const startMs = message.metadata?.startUnixMs || message.createdUnixMs;
      const endMs = message.metadata?.endUnixMs || message.createdUnixMs;
      const startTime = formatMessageTimestamp(startMs).label;
      const endTime = formatMessageTimestamp(endMs).label;
      const timeStr =
        startTime && endTime ? `${startTime} – ${endTime}` : startTime || endTime || '';
      return (
        <div
          data-debug-id={`conversation-agent-start-clubbed-${message.messageId}`}
          className="my-2 flex w-full items-center gap-3"
        >
          <div className="flex-1 border-t border-subtle/40" />
          <span className="shrink-0 font-mono text-[11px] text-faint">
            agent started {count} times ({timeStr})
          </span>
          <div className="flex-1 border-t border-subtle/40" />
        </div>
      );
    }
    if (isAgentStartMessage(message)) {
      const time = formatMessageTimestamp(message.createdUnixMs).label;
      return (
        <div
          data-debug-id={`conversation-agent-start-${message.messageId}`}
          className="my-2 flex w-full items-center gap-3"
        >
          <div className="flex-1 border-t border-subtle/40" />
          <span className="shrink-0 font-mono text-[11px] text-faint">
            agent started ({time})
          </span>
          <div className="flex-1 border-t border-subtle/40" />
        </div>
      );
    }
    if (message.messageType === 'system') {
      return (
        <div
          data-debug-id={`conversation-system-message-${message.messageId}`}
          className="rounded-xl border border-subtle bg-surface px-3 py-2 text-muted"
        >
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
    if (message.messageType === 'action') {
      const { summary, triggeredAt } = scheduleContextFromMetadata(message.metadata);
      return (
        <div
          data-debug-id={`conversation-action-message-${message.messageId}`}
          className="rounded-2xl border border-warning/30 border-l-2 border-l-warning bg-warning-soft p-3"
        >
          <div className="mb-2 flex flex-wrap items-center gap-x-2 gap-y-1 text-caption uppercase tracking-wide text-warning">
            <span className="inline-flex items-center gap-1.5 font-semibold text-warning">
              <Icon name="clock" size={13} title="Scheduled action" />
              Scheduled action
            </span>
            {summary ? (
              <span className="normal-case tracking-normal text-muted">
                <VaultText value={summary} as="span" />
              </span>
            ) : null}
          </div>
          {triggeredAt ? (
            <div className="mb-2 text-caption text-faint">
              Ran on schedule: {triggeredAt}
            </div>
          ) : null}
          <ThreadMessageBody body={message.body} />
          {message.artifactIds && message.artifactIds.length > 0 && (
            <div className="mt-2 flex max-w-full flex-wrap gap-2">
              {message.artifactIds.map((id) => (
                <ArtifactAttachmentPreview
                  key={id}
                  artifactId={id}
                  session={{ daemonUrl: '', clientToken: '' }}
                  debugId={`conversation-thread-artifact-${message.messageId}-${id}`}
                />
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
              <ArtifactAttachmentPreview
                key={id}
                artifactId={id}
                session={{ daemonUrl: '', clientToken: '' }}
                debugId={`conversation-thread-artifact-${message.messageId}-${id}`}
              />
            ))}
          </div>
        )}
      </div>
    );
  }

  async function toggleRuntime() {
    if (!agentId || !agentInstanceId || runtimeActionBusy) return;
    setStatusMenuOpen(false);
    setReconfigStatus(needsStart ? 'Starting…' : 'Stopping…');
    try {
      if (needsStart) await restartInstance({ agentId, instanceId: agentInstanceId }).unwrap();
      else await stopInstance({ agentId, instanceId: agentInstanceId }).unwrap();
      setReconfigStatus(needsStart ? 'Start requested.' : 'Stop requested.');
    } catch (err: any) {
      setReconfigStatus(errMsg(err, needsStart ? 'Start failed' : 'Stop failed'));
    }
  }

  async function applyReconfigure() {
    if (!agentInstanceId || runtimeActionBusy || stagedConfigurationIssues.length > 0)
      return;
    if (operation?.phase === 'recovery_required') {
      setReconfigStatus('Retrying configuration change…');
      try {
        const retried = await retryConfiguration({
          instanceId: agentInstanceId,
          idempotency_key: operation.idempotency_key,
          expected_operation_revision: operation.revision,
        }).unwrap();
        setAcceptedOperation(retried);
        setReconfigStatus('');
      } catch (error: any) {
        setReconfigStatus(errMsg(error, 'Recovery retry failed'));
      }
      return;
    }
    const nextProvider = provider || providerOptions[0] || '';
    const nextModel = model || modelOptions[0] || '';
    if (!nextProvider || !nextModel) {
      setReconfigStatus('Choose a provider and model first.');
      return;
    }
    setRuntimeMenuOpen(false);
    setReconfigStatus(
      `Applying configuration on ${bridgeLabel || instanceBridgeId || 'this bridge'}…`,
    );
    try {
      const applied = await reconfigureInstance({
        instanceId: agentInstanceId,
        bridge_id: destinationBridgeId,
        project_id: destinationProjectId,
        provider: nextProvider,
        model: nextModel,
        expected_revision: Number(instance?.configuration_revision || 0),
        idempotency_key:
          globalThis.crypto?.randomUUID?.() ||
          `apply-${Date.now()}-${Math.random().toString(36).slice(2)}`,
      }).unwrap();
      setAcceptedOperation(applied);
      setReconfigStatus('');
    } catch (err: any) {
      setReconfigStatus(errMsg(err, 'Configuration change failed'));
    }
  }

  async function forceStopRuntime() {
    if (
      !agentId ||
      !agentInstanceId ||
      (needsStart && !operationBlocksInput) ||
      stopState.isLoading ||
      reconfigureState.isLoading ||
      retryConfigurationState.isLoading
    )
      return;
    setReconfigStatus('Force stopping…');
    try {
      await stopInstance({
        agentId,
        instanceId: agentInstanceId,
        force: true,
      }).unwrap();
      setReconfigStatus(
        'Force stop requested. Waiting for confirmed termination…',
      );
    } catch (err: any) {
      setReconfigStatus(errMsg(err, 'Force stop failed'));
    }
  }

  function resetRuntimeConfiguration() {
    settingsEditedRef.current = false;
    setStagedBridgeId(null);
    setProvider(instanceProvider);
    setModel(instanceModel);
    setReconfigStatus('');
  }

  const pendingReconfig =
    selectionChangesConfig || operation?.phase === 'recovery_required';
  const runtimeControls = (
    <div data-debug-id="conversation-runtime-controls" className="text-left">
      <div className="mb-4 flex flex-wrap items-center justify-between gap-3 rounded-xl border border-subtle p-3">
        <span className="inline-flex items-center gap-2 text-sm text-primary">
          <StatusDot
            size="sm"
            tone={runtimeStatusToTone(runtimeStatus)}
            label={needsStart ? 'Stopped' : 'Running'}
          />
          {needsStart
            ? 'Stopped'
            : runtimeStopping
            ? 'Stopping…'
            : isStarting
            ? 'Starting…'
            : 'Running'}
        </span>
        <div className="flex gap-2">
          <button
            type="button"
            data-debug-id="conversation-runtime-modal-toggle-btn"
            disabled={
              !agentInstanceId ||
              runtimeActionBusy ||
              runtimeStopping ||
              operationBlocksInput ||
              (needsStart && conversationReadOnly)
            }
            onClick={() => void toggleRuntime()}
            className="min-h-11 rounded-xl border border-subtle px-3 text-sm text-primary disabled:opacity-40"
          >
            {needsStart ? 'Start agent' : 'Stop agent'}
          </button>
          <button
            type="button"
            data-debug-id="conversation-runtime-force-stop-btn"
            disabled={
              !agentInstanceId ||
              (needsStart && !operationBlocksInput) ||
              stopState.isLoading ||
              reconfigureState.isLoading ||
              retryConfigurationState.isLoading ||
              instanceBridge?.runtime_connected !== true
            }
            onClick={() => void forceStopRuntime()}
            className="min-h-11 rounded-xl border border-danger/30 px-3 text-sm text-danger disabled:opacity-40"
          >
            Force stop
          </button>
        </div>
      </div>
      <div className="mb-4 rounded-xl bg-neutral-soft px-3 py-2 text-xs text-muted">
        Project:{' '}
        {projectId ? (
          <VaultText value={projectName} fallback="Project" />
        ) : (
          'No project'
        )}
      </div>
      <RuntimeConfigurationOptions
        debugPrefix="conversation"
        bridges={bridges}
        selection={{ bridgeId: destinationBridgeId, provider, model }}
        requireReconfiguration
        disabled={runtimeActionBusy || operationBlocksInput || isStarting}
        onChange={(next) => {
          settingsEditedRef.current = true;
          setStagedBridgeId(next.bridgeId);
          setProvider(next.provider);
          setModel(next.model);
        }}
      />
      <div className="mt-1.5 flex items-center gap-2 border-t border-subtle px-2 pt-2 text-[12px] text-muted">
        <Icon
          name="alert"
          size={14}
          className={pendingReconfig ? 'text-warning' : 'text-faint'}
        />
        <span>
          <span
            className={`font-semibold ${
              pendingReconfig ? 'text-warning' : 'text-muted'
            }`}
          >
            Restarts the agent
          </span>{' '}
          — choose Apply to confirm.
        </span>
      </div>
      {pendingReconfig && stagedConfigurationIssues.length ? (
        <ul
          data-debug-id="conversation-destination-validation"
          className="mt-2 list-disc space-y-1 pl-5 text-xs text-danger"
        >
          {stagedConfigurationIssues.map((issue) => (
            <li key={issue}>{issue}</li>
          ))}
        </ul>
      ) : null}
      {reconfigStatus ? (
        <div
          data-debug-id="conversation-reconfigure-status"
          className="px-2 pt-1 text-caption text-muted"
        >
          {reconfigStatus}
        </div>
      ) : null}
    </div>
  );

  function renderComposer() {
    const activeProvider = instanceProvider || provider;
    const composerInput = (
      <MessageComposerInput
        mobile={isMobile}
        debugId="conversation-composer-input"
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
            if (e.key === 'ArrowDown') {
              e.preventDefault();
              setMentionIndex((i) => (i + 1) % filteredMentions.length);
              return;
            }
            if (e.key === 'ArrowUp') {
              e.preventDefault();
              setMentionIndex(
                (i) => (i - 1 + filteredMentions.length) % filteredMentions.length,
              );
              return;
            }
            if (e.key === 'Enter') {
              e.preventDefault();
              handleMentionSelect(filteredMentions[mentionIndex]);
              return;
            }
            if (e.key === 'Escape') {
              e.preventDefault();
              setMentionQuery(null);
              return;
            }
          }
          if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
            e.preventDefault();
            void submit(e as any);
          }
        }}
        onPaste={handleComposerPaste}
        placeholder={
          isMobile
            ? 'Message the agent…'
            : 'Message the agent… (Cmd/Ctrl+Enter to send)'
        }
      />
    );
    const composerActions = {
      debugPrefix: 'conversation',
      mobile: isMobile,
      compactModel: isSmallComposer,
      provider: activeProvider,
      model: instanceModel,
      onSettings: () => setRuntimeMenuOpen(true),
      onUpload: openAttachmentPicker,
      uploadDisabled: configurationInputBlocked,
      sendDisabled,
      paneExpanded: false,
      onPaneToggle: handleOpenPtyTab,
    };
    return (
      <form
        ref={composerContainerRef as any}
        onSubmit={submit}
        data-debug-id="conversation-composer-shell"
        className="w-full max-w-4xl mx-auto px-3 sm:px-0 py-4"
      >
        <div className="mx-auto w-full max-w-4xl">
          {error ? (
            <div
              data-debug-id="conversation-composer-send-error"
              className="mb-2 rounded-xl border border-danger/30 bg-danger-soft px-3 py-2 text-xs text-danger"
            >
              {error}
            </div>
          ) : null}
          {attachments.length > 0 && (
            <div
              data-debug-id="conversation-attachment-tray"
              className="mb-2 space-y-2 rounded-2xl border border-subtle bg-surface-raised p-2 text-xs text-primary"
            >
              {attachments.map((a) => (
                <div
                  key={a.localId}
                  data-debug-id={`conversation-attachment-${a.localId}`}
                  className="rounded-xl border border-subtle bg-surface px-2.5 py-2"
                >
                  <div className="flex min-w-0 items-center gap-2">
                    <span
                      className={
                        a.status === 'uploaded'
                          ? 'text-success'
                          : a.status === 'error'
                          ? 'text-danger'
                          : 'text-accent'
                      }
                    >
                      {a.status === 'uploading'
                        ? '⇧'
                        : a.status === 'uploaded'
                        ? '✓'
                        : '!'}
                    </span>
                    <span className="min-w-0 flex-1 truncate" title={a.name}>
                      {a.name}
                    </span>
                    <span
                      className={
                        a.status === 'uploaded'
                          ? 'text-success'
                          : a.status === 'error'
                          ? 'text-danger'
                          : 'text-accent'
                      }
                    >
                      {a.status === 'uploading'
                        ? 'Uploading…'
                        : a.status === 'uploaded'
                        ? 'Uploaded'
                        : 'Failed'}
                    </span>
                    {a.status === 'error' ? (
                      <button
                        type="button"
                        data-debug-id={`conversation-attachment-retry-${a.localId}`}
                        onClick={() => void uploadAttachment(a.file, a.localId)}
                        className="rounded-full border border-subtle px-2 py-0.5 text-primary hover:bg-neutral-soft"
                      >
                        Retry
                      </button>
                    ) : null}
                    <button
                      type="button"
                      data-debug-id={`conversation-attachment-remove-${a.localId}`}
                      onClick={() =>
                        setAttachments((prev) =>
                          prev.filter((item) => item.localId !== a.localId),
                        )
                      }
                      className="rounded-full border border-subtle px-2 py-0.5 text-muted hover:bg-neutral-soft hover:text-primary"
                    >
                      Remove
                    </button>
                  </div>
                  {a.status === 'uploading' ? (
                    <div
                      data-debug-id={`conversation-attachment-progress-${a.localId}`}
                      className="mt-2 h-1.5 overflow-hidden rounded-full bg-neutral-soft"
                    >
                      <div className="h-full w-1/2 animate-pulse rounded-full bg-accent" />
                    </div>
                  ) : null}
                  {a.error ? (
                    <div
                      data-debug-id={`conversation-attachment-error-${a.localId}`}
                      className="mt-1 text-danger"
                    >
                      {a.error}
                    </div>
                  ) : null}
                </div>
              ))}
              {hasUploadingAttachments ? (
                <div
                  data-debug-id="conversation-attachment-uploading-hint"
                  className="text-caption text-muted"
                >
                  You can keep typing. Send unlocks when uploads finish.
                </div>
              ) : null}
              {hasFailedAttachments ? (
                <div
                  data-debug-id="conversation-attachment-failed-hint"
                  className="text-caption text-danger"
                >
                  Retry or remove failed uploads before sending.
                </div>
              ) : null}
            </div>
          )}
          <input
            ref={fileInputRef}
            data-debug-id="conversation-attach-input"
            type="file"
            multiple
            className="hidden"
            onChange={handleAttachmentInput}
          />
          <div
            data-debug-id="conversation-composer-card"
            className="rounded-[22px] border border-subtle bg-surface px-3 py-2.5 focus-within:border-accent sm:px-4 sm:py-3"
          >
            <div
              data-debug-id="conversation-composer-context"
              className="mb-2 hidden min-w-0 items-center gap-x-2 sm:flex text-[12px] text-muted"
            >
              <div className="flex min-w-0 flex-1 items-center gap-1.5 overflow-hidden">
                <button
                  type="button"
                  onClick={() => setRuntimeMenuOpen(true)}
                  aria-haspopup="dialog"
                  aria-label="Change bridge, provider or model"
                  data-debug-id="conversation-composer-bridge-chip"
                  className="inline-flex min-w-0 max-w-[50%] shrink items-center gap-1.5"
                  title={`Bridge: ${bridgeLabel || '—'} (current location)`}
                >
                  <Icon name="device" size={12} className="shrink-0" />
                  <span className="min-w-0 truncate font-semibold text-muted">
                    {bridgeLabel || 'no bridge'}
                  </span>
                </button>
                {projectId && !isAuxSubagent ? (
                  <>
                    <span className="shrink-0 opacity-40">·</span>
                    <button
                      type="button"
                      data-debug-id="conversation-composer-project-chip"
                      onClick={() => openAux({ type: 'files' })}
                      title={`Open project files — ${projectName}`}
                      className="inline-flex min-w-0 max-w-[50%] shrink items-center gap-1.5 rounded-md px-1 py-0.5 hover:bg-neutral-soft hover:text-primary"
                    >
                      <Icon name="folder" size={13} className="shrink-0" />
                      <span className="min-w-0 truncate font-semibold text-muted">
                        <VaultText value={projectName} fallback="Project" />
                      </span>
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
                    <button
                      type="button"
                      data-debug-id="conversation-runtime-status-chip"
                      title="Runtime status — start/stop the agent"
                      className="inline-flex items-center gap-1.5 rounded-full border border-subtle bg-surface-raised px-2.5 py-1 text-caption text-muted hover:bg-neutral-soft hover:text-primary"
                    >
                      <StatusDot
                        size="sm"
                        tone={runtimeStatusToTone(runtimeStatus)}
                        label={
                          needsStart
                            ? 'Stopped'
                            : runtimeStopping
                            ? 'Stopping'
                            : runtimeStateLabel(runtimeStateFromStatus(runtimeStatus))
                        }
                      />
                      {needsStart
                        ? 'Stopped'
                        : runtimeStopping
                        ? 'Stopping…'
                        : runtimeStateFromStatus(runtimeStatus) === 'starting'
                        ? 'Starting…'
                        : 'Running'}
                    </button>
                  }
                >
                  <Menu.Label>
                    Runtime:{' '}
                    {needsStart
                      ? 'Stopped'
                      : runtimeStopping
                      ? 'Stopping…'
                      : runtimeStateFromStatus(runtimeStatus) === 'starting'
                      ? 'Starting…'
                      : 'Running'}
                  </Menu.Label>
                  <Menu.Item
                    data-debug-id="conversation-runtime-status-toggle-btn"
                    disabled={!agentInstanceId || runtimeActionBusy || runtimeStopping}
                    onClick={() => void toggleRuntime()}
                    className={needsStart ? 'text-success' : 'text-danger'}
                  >
                    <Icon name={needsStart ? 'play' : 'stop'} size={15} />
                    <span>{needsStart ? 'Start agent' : 'Stop agent'}</span>
                  </Menu.Item>
                  {reconfigStatus ? <Menu.Label>{reconfigStatus}</Menu.Label> : null}
                </Menu>
              </div>
            </div>

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
              {pendingReconfig && stagedConfigurationIssues.length > 0 ? (
                <div
                  data-debug-id="conversation-apply-blocked-reasons"
                  role="status"
                  className="mb-2 rounded-xl border border-subtle px-3 py-2 text-xs text-muted"
                >
                  <div className="font-medium text-primary">
                    Changes cannot be applied yet
                  </div>
                  <ul className="mt-1 list-disc pl-4">
                    {stagedConfigurationIssues.map((issue) => (
                      <li key={issue}>{issue}</li>
                    ))}
                  </ul>
                </div>
              ) : null}
              {operation ? (
                <InstanceReconfigurationProgress operation={operation} />
              ) : null}
              {operationBlocksInput ? (
                <div className="mb-3 flex flex-wrap items-center justify-between gap-3 rounded-xl border border-subtle px-3 py-2">
                  <p className="min-w-0 flex-1 text-xs text-muted">
                    {operation?.failure_code === 'force_stopping'
                      ? 'Waiting for confirmed termination. Settings will unlock once the agent is stopped.'
                      : 'To change the model or bridge, force stop this run first. Settings unlock after the bridge confirms termination.'}
                  </p>
                  <button
                    type="button"
                    data-debug-id="conversation-recovery-force-stop-btn"
                    disabled={
                      stopState.isLoading ||
                      reconfigureState.isLoading ||
                      retryConfigurationState.isLoading ||
                      instanceBridge?.runtime_connected !== true
                    }
                    onClick={() => void forceStopRuntime()}
                    className="min-h-10 rounded-xl border border-danger/30 px-3 text-sm text-danger disabled:opacity-40"
                  >
                    Force stop
                  </button>
                </div>
              ) : null}
              {!operationInFlight &&
              (runtimeStopping || isStarting || reconfigStatus) ? (
                <div
                  data-debug-id="conversation-runtime-transition"
                  role="status"
                  aria-live="polite"
                  className="mb-2 rounded-xl border border-subtle bg-neutral-soft px-3 py-2 text-sm"
                >
                  <div className="font-medium text-primary">
                    {runtimeStopping
                      ? 'Stopping agent'
                      : isStarting
                      ? 'Starting agent'
                      : 'Runtime configuration'}
                  </div>
                  <div className="mt-0.5 truncate text-xs text-muted">
                    {bridgeLabel || instanceBridgeId || 'Current bridge'}
                    {projectId ? (
                      <>
                        {' '}
                        · <VaultText value={projectName} fallback="Project" />
                      </>
                    ) : null}
                  </div>
                  {reconfigStatus ? (
                    <div className="mt-1 text-xs text-muted">{reconfigStatus}</div>
                  ) : null}
                </div>
              ) : null}
              {conversationReadOnly ? (
                <div
                  data-debug-id="conversation-configuration-read-only"
                  role="status"
                  aria-live="polite"
                  className="rounded-xl border border-subtle bg-neutral-soft px-4 py-3 text-sm"
                >
                  <div className="font-semibold text-primary">
                    This conversation is read-only
                  </div>
                  <p className="mt-1 text-xs text-muted">
                    Messages are disabled until the following configuration issues are
                    resolved.
                  </p>
                  <ul className="mt-2 list-disc space-y-1 pl-4 text-xs text-muted">
                    {configurationIssues.map((issue) => (
                      <li key={issue}>{issue}</li>
                    ))}
                  </ul>
                </div>
              ) : isMobile && !pendingReconfig ? (
                <div className="flex items-end gap-2">
                  <div className="min-w-0 flex-1 py-1.5">{composerInput}</div>
                  <MessageComposerActions {...composerActions} inline />
                </div>
              ) : (
                composerInput
              )}
            </div>

            {!(isMobile && !pendingReconfig && !conversationReadOnly) ? (
              <MessageComposerActions
                {...composerActions}
                readOnly={conversationReadOnly}
                pendingActions={
                  pendingReconfig ? (
                    <div className="flex items-center gap-2">
                      <button
                        type="button"
                        data-debug-id="conversation-reconfigure-reset-btn"
                        disabled={runtimeActionBusy || operationBlocksInput}
                        onClick={resetRuntimeConfiguration}
                        className="rounded-xl border border-subtle px-4 py-2 text-sm text-primary disabled:opacity-40"
                      >
                        Reset
                      </button>
                      <button
                        type="button"
                        data-debug-id="conversation-reconfigure-apply-btn"
                        disabled={
                          runtimeActionBusy ||
                          (operation?.phase !== 'recovery_required' &&
                            (isStarting || runtimeStopping)) ||
                          stagedConfigurationIssues.length > 0
                        }
                        onClick={() => void applyReconfigure()}
                        className="rounded-xl bg-accent px-4 py-2 text-sm font-semibold text-accent-fg disabled:opacity-40"
                      >
                        Apply
                      </button>
                    </div>
                  ) : undefined
                }
              />
            ) : null}
          </div>
        </div>
      </form>
    );
  }

  if (!conversation && convQuery.isFetching) {
    return (
      <div
        data-debug-id={`workbench-agent-chat-pane-${agentInstanceId}`}
        className="flex h-full min-h-0 w-full flex-col overflow-hidden bg-canvas p-6 text-left"
      >
        <div
          data-debug-id="conversation-thread-resolving"
          className="grid min-h-[220px] place-items-center text-sm text-muted"
        >
          Loading conversation…
        </div>
      </div>
    );
  }

  if (!conversation && !convQuery.isFetching) {
    return (
      <div
        data-debug-id={`workbench-agent-chat-pane-${agentInstanceId}`}
        className="flex h-full min-h-0 w-full flex-col overflow-hidden bg-canvas text-left"
      >
        {!isAuxSubagent && (onReplaceWithNew || (isMultiPane && onClosePane) || headerLeading || headerEnd) ? (
          // Minimal header so a pane whose conversation is missing can still be
          // replaced or closed.
          <header
            data-debug-id="conversation-thread-header-minimal"
            className="flex min-h-12 shrink-0 items-center justify-end gap-1 px-3 py-2"
          >
            {headerLeading ? <div className="mr-auto flex items-center gap-1">{headerLeading}</div> : null}
            {onReplaceWithNew ? (
              <button
                type="button"
                data-debug-id="conversation-replace-with-new-action"
                onClick={onReplaceWithNew}
                className="inline-flex h-8 items-center gap-1.5 rounded-lg px-2 text-xs text-muted hover:bg-neutral-soft hover:text-primary"
              >
                <Icon name="plus" size={14} />
                <span>Replace with New</span>
              </button>
            ) : null}
            {isMultiPane && onClosePane ? (
              <button
                type="button"
                data-debug-id="conversation-remove-from-split-action"
                aria-label="Close pane"
                title="Close pane"
                onClick={onClosePane}
                className="grid h-8 w-8 place-items-center rounded-lg text-muted hover:bg-neutral-soft hover:text-primary"
              >
                <Icon name="close" size={16} />
              </button>
            ) : null}
            {headerTrailing}
            {headerEnd}
          </header>
        ) : null}
        <div className="mx-auto mt-6 w-full max-w-4xl rounded-[2rem] border border-subtle bg-surface p-6">
          <h2 className="text-xl font-semibold text-primary">Conversation not found</h2>
          <p className="mt-2 text-sm text-muted">
            No conversation for instance{' '}
            <span className="font-mono">{routeInstanceId}</span> for this user.
          </p>
          <a
            data-debug-id="conversation-thread-back-btn"
            href="#/conversations/new"
            className="mt-4 inline-flex rounded-2xl bg-accent px-4 py-2 text-sm font-bold text-accent-fg hover:opacity-90"
          >
            Start a new conversation
          </a>
        </div>
      </div>
    );
  }

  return (
    <div
      data-debug-id={`workbench-agent-chat-pane-${agentInstanceId}`}
      className="relative flex h-full w-full min-h-0 min-w-0 flex-1 flex-col overflow-hidden bg-canvas text-left"
    >
      {/* Scoped top bar in Chat Pane (absent in an aux sub-agent tab: transcript + composer only) */}
      {!isAuxSubagent ? (
      <header
        data-debug-id="conversation-thread-header"
        className="sticky top-0 z-20 flex min-h-12 shrink-0 items-center gap-2 px-3 py-2 sm:gap-3 sm:px-4 bg-canvas/90 backdrop-blur-md overflow-visible"
      >
        <div
          data-debug-id="conversation-topbar-blur-fade"
          className="pointer-events-none absolute left-0 right-0 -bottom-6 h-6 bg-gradient-to-b from-canvas/90 via-canvas/50 to-transparent backdrop-blur-sm z-10"
          aria-hidden="true"
        />

        <div className="flex min-w-0 flex-1 items-center justify-start gap-1.5">
          {headerLeading ? (
            <div data-debug-id="conversation-header-leading" className="flex shrink-0 items-center gap-1">
              {headerLeading}
            </div>
          ) : null}
          {renaming ? (
            <div className="flex min-w-0 flex-1 items-center gap-2">
              <input
                data-debug-id="conversation-thread-title-input"
                value={titleDraft}
                onChange={(event) => {
                  setTitleDraft(event.target.value);
                  setTitleError('');
                }}
                onKeyDown={(event) => {
                  if (event.key === 'Enter') {
                    event.preventDefault();
                    void saveConversationTitle();
                  }
                  if (event.key === 'Escape') {
                    setRenaming(false);
                    setTitleError('');
                    setTitleDraft(editableTitle);
                  }
                }}
                className="min-h-9 min-w-0 flex-1 rounded-xl border border-subtle bg-surface px-3 py-1.5 text-base font-semibold text-primary outline-none focus:border-accent sm:text-sm"
                autoFocus
              />
              <button
                type="button"
                data-debug-id="conversation-thread-title-save-btn"
                aria-label="Save conversation title"
                title="Save"
                onClick={() => void saveConversationTitle()}
                disabled={updateTitleState.isLoading || !titleDraft.trim()}
                className="grid h-9 w-9 shrink-0 place-items-center rounded-xl bg-accent text-accent-fg hover:opacity-90 disabled:opacity-50"
              >
                <Icon name="check" size={16} />
              </button>
              <button
                type="button"
                data-debug-id="conversation-thread-title-cancel-btn"
                aria-label="Cancel title edit"
                title="Cancel"
                onClick={() => {
                  setRenaming(false);
                  setTitleError('');
                  setTitleDraft(editableTitle);
                }}
                className="grid h-9 w-9 shrink-0 place-items-center rounded-xl border border-subtle bg-surface-raised text-muted hover:bg-neutral-soft hover:text-primary"
              >
                <Icon name="close" size={16} />
              </button>
            </div>
          ) : (
            <div
              data-debug-id="conversation-thread-breadcrumb"
              className="flex min-w-0 items-center gap-1.5 text-sm font-medium"
            >
              {!isMobile ? (
                <>
                  <span
                    data-debug-id="conversation-breadcrumb-project"
                    className="truncate text-muted"
                  >
                    <VaultText value={projectName} fallback="Project" />
                  </span>
                  <span className="shrink-0 text-faint">/</span>
                </>
              ) : null}
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
                <Icon
                  name="chevron-down"
                  size={13}
                  className="shrink-0 text-muted group-hover:text-accent"
                />
              </button>
              <span className="shrink-0 text-faint">/</span>
              <button
                type="button"
                data-debug-id="conversation-chain-agent-switcher-btn"
                aria-label="Switch agent in this task chain"
                aria-haspopup="dialog"
                aria-expanded={chainAgentSwitcherOpen}
                onClick={() => {
                  setChainAgentSwitcherOpen(true);
                  refetchIfStarted(chainDetailQuery);
                }}
                className="flex min-w-0 items-center gap-1.5 rounded-md px-1.5 py-0.5 text-primary hover:bg-neutral-soft"
              >
                <StatusDot
                  size="sm"
                  tone={runtimeStatusToTone(runtimeStatus)}
                  label={
                    needsStart
                      ? 'Stopped'
                      : runtimeStopping
                      ? 'Stopping'
                      : isStarting
                      ? 'Starting'
                      : 'Running'
                  }
                />
                <span className="truncate">
                  <VaultText
                    value={
                      chainAgentGroups[0]?.conversations.find(
                        (member) => member.agentInstanceId === agentInstanceId,
                      )?.title ||
                      agentDisplayName ||
                      agentId
                    }
                    fallback="Agent"
                  />
                </span>
                <Icon name="chevron-down" size={13} className="shrink-0 text-muted" />
              </button>
            </div>
          )}
          {titleError ? (
            <div
              data-debug-id="conversation-thread-title-error"
              className="mt-1 text-caption text-danger"
            >
              {titleError}
            </div>
          ) : null}
        </div>

        {/* Right Cluster: Vault pill + Vertical 3-dots menu (⋮). The ONE side-panel toggle lives in the workspace top bar. */}
        <div className="flex shrink-0 items-center gap-1">
          {hasLockedVaultMessages ? (
            <span
              data-debug-id="conversation-thread-vault-pill"
              title="Vault is locked — unlock Vault to decrypt armored messages"
              className="inline-flex items-center gap-1 rounded-full border border-warning/30 bg-warning-soft px-2 py-0.5 text-[11px] font-medium text-warning"
            >
              <Icon name="lock" size={12} />
              <span className="hidden sm:inline">Vault locked</span>
            </span>
          ) : null}

          {headerTrailing}
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
                className="grid h-8 w-8 shrink-0 place-items-center rounded-lg text-muted hover:bg-neutral-soft hover:text-primary"
              >
                <Icon name="more-vertical" size={18} />
              </button>
            }
          >
            <Menu.Item
              data-debug-id="conversation-thread-rename-action"
              onClick={beginRenameFromHeader}
            >
              <Icon name="pencil" size={15} />
              <span>Rename</span>
            </Menu.Item>
            <Menu.Item
              data-debug-id="conversation-thread-refresh-btn"
              onClick={refreshFromHeader}
            >
              <Icon name="refresh" size={15} />
              <span>Refresh messages</span>
            </Menu.Item>
            <Menu.Item
              data-debug-id="conversation-thread-settings-action"
              onClick={() => {
                setHeaderActionsOpen(false);
                setRuntimeMenuOpen(true);
              }}
            >
              <Icon name="gear" size={15} />
              <span>Agent settings</span>
            </Menu.Item>
            <Menu.Separator />
            {onSplitPane || onReplaceWithNew || (isMultiPane && onClosePane) ? (
              <>
                <Menu.Label>{isMobile ? 'Panes' : 'Split'}</Menu.Label>
                {onSplitPane ? (
                  isMobile ? (
                    <Menu.Item
                      data-debug-id="conversation-new-pane-action"
                      onClick={() => {
                        setHeaderActionsOpen(false);
                        onSplitPane('right');
                      }}
                    >
                      <Icon name="plus" size={15} />
                      <span>New Pane</span>
                    </Menu.Item>
                  ) : (
                    <>
                      {(
                        [
                          ['right', 'Split Right', 'panel-right'],
                          ['bottom', 'Split Down', 'chevron-down'],
                          ['left', 'Split Left', 'panel-left'],
                          ['top', 'Split Up', 'chevron-up'],
                        ] as const
                      ).map(([direction, label, icon]) => (
                        <Menu.Item
                          key={direction}
                          data-debug-id={`conversation-split-${direction === 'bottom' ? 'down' : direction === 'top' ? 'up' : direction}-action`}
                          onClick={() => {
                            setHeaderActionsOpen(false);
                            onSplitPane(direction);
                          }}
                        >
                          <Icon name={icon} size={15} />
                          <span>{label}</span>
                        </Menu.Item>
                      ))}
                    </>
                  )
                ) : null}
                {onReplaceWithNew ? (
                  <Menu.Item
                    data-debug-id="conversation-replace-with-new-action"
                    onClick={() => {
                      setHeaderActionsOpen(false);
                      onReplaceWithNew();
                    }}
                  >
                    <Icon name="plus" size={15} />
                    <span>Replace with New</span>
                  </Menu.Item>
                ) : null}
                {isMultiPane && onClosePane ? (
                  <Menu.Item
                    data-debug-id="conversation-remove-from-split-action"
                    onClick={() => {
                      setHeaderActionsOpen(false);
                      onClosePane();
                    }}
                  >
                    <Icon name="close" size={15} />
                    <span>{isMobile ? 'Close Pane' : 'Remove from Split'}</span>
                  </Menu.Item>
                ) : null}
              </>
            ) : null}
            <Menu.Separator />
            <div
              data-debug-id="conversation-thread-overflow-details"
              role="presentation"
              className="px-3 py-1.5 text-caption leading-5 text-faint overflow-hidden"
            >
              <div data-debug-id="conversation-thread-agent" className="truncate">
                Agent: {agentDisplayName || agentId || '—'}
              </div>
              <div data-debug-id="conversation-thread-instance" className="truncate">
                Instance: {agentInstanceId || '—'}
              </div>
              <div data-debug-id="conversation-thread-bridge" className="truncate">
                Bridge: {bridgeLabel || '—'}
              </div>
              <div className="flex gap-2">
                <span data-debug-id="conversation-thread-provider">
                  Provider: {instanceProvider || '—'}
                </span>
                <span data-debug-id="conversation-thread-model">
                  Model: {instanceModel || '—'}
                </span>
              </div>
              <div data-debug-id="conversation-thread-status">
                Status: {runtimeStatus || '—'}
              </div>
              {chainId ? (
                <div data-debug-id="conversation-thread-chain" className="truncate">
                  Chain: <VaultText value={chainTitle || chainId} as="span" />
                </div>
              ) : null}
            </div>
          </Menu>
          {/* Jetski: in split view the focused pane shows a close ✕. */}
          {isMultiPane && isFocusedPane && onClosePane ? (
            <button
              type="button"
              data-debug-id="conversation-close-pane-btn"
              aria-label="Close pane"
              title="Close pane"
              onClick={onClosePane}
              className="grid h-8 w-8 shrink-0 place-items-center rounded-lg text-muted hover:bg-neutral-soft hover:text-primary"
            >
              <Icon name="close" size={16} />
            </button>
          ) : null}
          {headerEnd}
        </div>
      </header>
      ) : null}

      {/* Transcript + Composer Dock */}
      <div
        data-debug-id="conversation-thread-transcript"
        className="flex w-full min-h-0 min-w-0 max-w-full flex-1 flex-col overflow-x-hidden p-0 sm:px-4 sm:py-3"
      >
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
          emptyState={
            messagesQuery.isFetching ? (
              <div
                data-debug-id="conversation-thread-empty-state"
                className="grid h-full min-h-[220px] place-items-center p-6 text-sm text-muted"
              >
                Loading messages…
              </div>
            ) : (
              <div
                data-debug-id="conversation-thread-empty-state"
                className="flex h-full min-h-[220px] flex-col items-center justify-center gap-4 p-6 text-center"
              >
                <div
                  data-debug-id="conversation-thread-empty-avatar"
                  className="grid h-16 w-16 place-items-center rounded-full bg-neutral-soft text-2xl font-semibold text-primary"
                >
                  {(agentDisplayName || 'A').trim().charAt(0).toUpperCase()}
                </div>
                <h3
                  data-debug-id="conversation-thread-empty-title"
                  className="text-2xl font-semibold text-primary"
                >
                  {agentDisplayName || 'New conversation'}
                </h3>
                {agentPersona ? (
                  <p
                    data-debug-id="conversation-thread-empty-persona"
                    className="max-w-xl whitespace-pre-line text-[15px] leading-relaxed text-muted"
                  >
                    {agentPersona}
                  </p>
                ) : (
                  <p
                    data-debug-id="conversation-thread-empty-persona"
                    className="max-w-md text-[15px] text-muted"
                  >
                    Say something below to get started.
                  </p>
                )}
              </div>
            )
          }
        />
        <div
          data-debug-id="conversation-thread-composer-dock"
          className="mx-auto w-full max-w-4xl shrink-0"
        >
          <AgentActivityBubbles instanceId={agentInstanceId} />
          <PinnedShellRuns sessions={pinnedRuns} />
          {renderComposer()}
        </div>
      </div>

      <Modal
        open={runtimeMenuOpen}
        onOpenChange={setRuntimeMenuOpen}
        title="Agent settings"
        size="lg"
        data-debug-id="conversation-runtime-modal"
      >
        <Modal.Body>{runtimeControls}</Modal.Body>
        <Modal.Footer>
          <button
            type="button"
            data-debug-id="conversation-runtime-modal-reset-btn"
            disabled={!pendingReconfig || runtimeActionBusy || operationBlocksInput}
            onClick={resetRuntimeConfiguration}
            className="min-h-11 rounded-xl border border-subtle px-4 py-2 text-sm text-primary disabled:opacity-40"
          >
            Reset
          </button>
          <button
            type="button"
            data-debug-id="conversation-runtime-modal-apply-btn"
            disabled={
              !pendingReconfig ||
              runtimeActionBusy ||
              (operation?.phase !== 'recovery_required' &&
                (isStarting || runtimeStopping)) ||
              stagedConfigurationIssues.length > 0
            }
            onClick={() => void applyReconfigure()}
            className="min-h-11 rounded-xl bg-accent px-4 py-2 text-sm font-semibold text-accent-fg disabled:opacity-40"
          >
            Apply
          </button>
        </Modal.Footer>
      </Modal>

      <Modal
        open={chainAgentSwitcherOpen}
        onOpenChange={setChainAgentSwitcherOpen}
        title="Agents in this task chain"
        size="md"
        data-debug-id="conversation-chain-agent-modal"
      >
        <Modal.Body>
          <div className="space-y-2">
            {(chainAgentGroups[0]?.conversations || []).map((member) => (
              <button
                key={member.agentInstanceId}
                type="button"
                data-debug-id={`conversation-chain-agent-option-${member.agentInstanceId}`}
                aria-pressed={member.agentInstanceId === agentInstanceId}
                onClick={() => {
                  setChainAgentSwitcherOpen(false);
                  if (member.agentInstanceId === agentInstanceId) return;
                  if (onSwitchAgent) {
                    // The workspace swaps the agent in THIS pane (deduped: an agent
                    // already open elsewhere is focused instead) and syncs the URL.
                    onSwitchAgent(member.agentInstanceId, member.title);
                  } else if (typeof window !== 'undefined') {
                    window.location.hash = buildRouteHash(
                      `/conversations/${encodeURIComponent(member.agentInstanceId)}`,
                      '',
                    );
                  }
                }}
                className={`flex min-h-14 w-full items-center gap-3 rounded-xl border px-3 py-3 text-left ${
                  member.agentInstanceId === agentInstanceId
                    ? 'border-accent bg-accent/10'
                    : 'border-subtle hover:bg-neutral-soft'
                }`}
              >
                <StatusDot
                  size="sm"
                  tone={runtimeStatusToTone(member.runtimeStatus)}
                  label={runtimeStateLabel(runtimeStateFromStatus(member.runtimeStatus))}
                />
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-sm font-medium text-primary">
                    <VaultText value={member.title} fallback="Agent" />
                  </span>
                  {member.isCoordinator ? (
                    <span className="text-xs text-muted">Coordinator</span>
                  ) : null}
                </span>
                {member.agentInstanceId === agentInstanceId ? (
                  <Icon name="check" size={18} className="text-accent" />
                ) : null}
              </button>
            ))}
            {!chainAgentGroups[0]?.conversations.length ? (
              <p className="text-sm text-muted">
                No agents are available in this task chain.
              </p>
            ) : null}
          </div>
        </Modal.Body>
      </Modal>

      <TaskChainSelectorModal
        open={chainSelectorOpen}
        onClose={() => setChainSelectorOpen(false)}
        currentChainId={chainId}
        projectId={projectId}
        // Per-pane: picking a chain swaps THIS pane to its coordinator in place
        // (deduped by the workspace). A chain without a coordinator keeps the
        // default navigation to /chains/<id>.
        onSelectChain={
          onSwitchAgent
            ? (chain) => {
                if (chain.coordinatorAgentInstanceId) {
                  if (chain.coordinatorAgentInstanceId !== agentInstanceId) {
                    onSwitchAgent(chain.coordinatorAgentInstanceId);
                  }
                } else if (typeof window !== 'undefined') {
                  window.location.hash = buildRouteHash(
                    `/chains/${encodeURIComponent(chain.chainId)}`,
                    '',
                  );
                }
              }
            : undefined
        }
      />

      <CommandPalette
        open={paletteOpen}
        onClose={() => setPaletteOpen(false)}
        onNavigate={(route) => {
          window.location.hash = buildRouteHash(route, '');
          setPaletteOpen(false);
        }}
        actions={[]}
        conversationGroups={chainAgentGroups}
      />
    </div>
  );
}

export default AgentChatPane;
