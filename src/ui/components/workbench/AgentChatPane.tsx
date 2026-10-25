import React, {
  type ClipboardEvent,
  type FormEvent,
  useCallback,
  useEffect,
  useMemo,
  useReducer,
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
  useAnswerConversationQuestionsMutation,
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
  useBridgeProviderStatus,
  useListBridgeProvidersQuery,
  useListBridgesQuery,
  type BridgeCapability,
} from '../../api/endpoints/bridgeSupport';
import {
  useFetchChainTasksQuery,
  useFetchTaskChainConversationQuery,
  useFetchTaskChainDetailQuery,
} from '../../api/endpoints/tasks';
import { chainTargetId } from '../../utils/paneTarget';
import { selectActiveVaultKey } from '../../store/vaultSlice';
import type { AuxContent } from '../../store/auxTabId';
import { buildRouteHash } from '../../utils/appLocation';
import { useRegisterActions } from '../../services/shortcuts/useRegisterActions';
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
import { decryptPaneCaptureBody } from '../../utils/vaultChats';
import { VAULT_LOCKED_MARKER } from '../../utils/vaultCrypto';
import { describeCron, formatInTimeZone, timeZoneLabel } from '../actions/scheduleUtils';
import { useActionsAccess } from '../actions/useActionsAccess';
import { TaskChainSelectorModal } from '../chains/TaskChainSelectorModal';
import { useIsMobile } from '../shell/responsive';
import { chromeIconButtonSizeClass } from '../shell/shellChrome';
import { navigateTo, shellViewHref } from '../shells/shellModel';
import LiveToolActivity from '../extension/LiveToolActivity';
import AgentActivityBubbles from '../chat/AgentActivityBubbles';
import AtMentionPopup, { type MentionEntity } from '../chat/AtMentionPopup';
import ChatMessageList from '../chat/ChatMessageList';
import InstanceReconfigurationProgress from '../chat/InstanceReconfigurationProgress';
import { MessageComposerInput, MessageComposerActions, MessageComposerStatus } from '../chat/MessageComposer';
import RuntimeConfigurationOptions from '../chat/RuntimeConfigurationOptions';
import { usePaneDeferredRefresh, usePaneMarkRead, usePanePollPolicy, usePaneVisible, visiblePollInterval } from './paneVisibility';
import {
  CONVERSATION_MESSAGES_READ_EVENT,
  applyReadReceipt,
  reconcileOlderPages,
  type ConversationMessagesRead,
} from '../../api/conversationMessageEvents';
import { permissionToggleRequest, permissionToggleState } from './permissionToggleModel';
import { type TaskLike } from '../chat/chainTaskInference';
import { groupTranscriptMessages, isAgentStartMessage } from '../chat/transcriptGrouping';
import type { ChatDeliveryStatus, ChatMessage, ChatTimestamp } from '../chat/types';
import type { SplitDirection } from '../../tiling/types';
import { replaceVaultTokens } from '../../utils/vaultCrypto.ts';
import { appendArtifactLinks } from '../../utils/artifactUpload';
import { ActionTray, NeedYouPill, useActionTrayItems, useSendTrayMode } from '../attention/ActionTray';
import {
  INITIAL_TRAY_STATE,
  TRAY_MODE_COPY,
  needYouPillVisible,
  trayReducer,
  trayVisible,
} from '../attention/actionTrayModel';

export const COMPOSER_DRAFT_KEY = 'heimdall:composer:draft';

/**
 * For user-initiated refreshes only; data freshness otherwise comes from tag
 * invalidation. RTK Query throws (error #38) when refetching a query that has not
 * started, e.g. one still skipped while its arguments load.
 */
// Fallback cadence for an unsettled reconfiguration this pane accepted (focused and on
// screen only). The hub announces every phase; this only bounds a missed frame.
export const RECONFIGURATION_ACTIVE_FALLBACK_MS = 15000;

export function refetchIfStarted(query: { isUninitialized: boolean; refetch: () => unknown }) {
  if (!query.isUninitialized) void query.refetch();
}

export interface AgentChatPaneProps {
  /** The agent instance shown (a chain pane passes its resolved coordinator). */
  agentInstanceId: string;
  /**
   * Set when this Main pane is addressed by chain (`chain:<id>`, REQ-TV2-7): the
   * chain context comes from the target instead of being inferred from the
   * conversation, and the chain selector swaps the pane's TARGET.
   */
  chainTarget?: { chainId: string; title?: string };
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
  /**
   * Agent/chain switcher: swap this Main pane's TARGET (an agent instance id or
   * `chain:<id>`; deduped by the host).
   */
  onSwitchAgent?: (targetId: string, title?: string) => void;
  /** Opens a pane target (e.g. a selected chain's `chain:<id>`) in a new pane beside this one. */
  onOpenAgentInSplit?: (targetId: string, direction: 'right' | 'bottom') => void;
  /** Requests that this pane open its task-chain picker for a shortcut placement. */
  chainSelectorRequest?: {
    id: number;
    placement: 'replace' | 'right' | 'bottom';
  };
  onChainSelectorRequestHandled?: (requestId: number) => void;
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
/** Composer width below which the model pill shows only the provider icon. */
const COMPACT_MODEL_PILL_WIDTH = 300;

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

function PaneCaptureOutput({ body: rawBody, messageId }: { body: string; messageId: string }) {
  const preRef = useRef<HTMLPreElement | null>(null);
  const activeKey = useSelector(selectActiveVaultKey);
  const armored = isVaultArmored(rawBody);
  // A sealed capture shows the locked marker until it decrypts; never the ciphertext.
  const [body, setBody] = useState<string>(armored ? VAULT_LOCKED_MARKER : rawBody);

  useEffect(() => {
    let mounted = true;
    if (!armored) {
      setBody(rawBody);
      return;
    }
    setBody(VAULT_LOCKED_MARKER);
    void decryptPaneCaptureBody(rawBody, activeKey).then((text) => {
      if (mounted) setBody(text);
    });
    return () => {
      mounted = false;
    };
  }, [rawBody, armored, activeKey]);

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
    const sanitized = replaceVaultTokens(body, '[🔒 Encrypted]');
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
  // Newest-page data supersedes carried older rows with the same durable ID,
  // including answered state and freshness. Display sorting happens afterwards.
  const canonicalRows = new Map(rows.map((row, index) => [msgId(row, index), row]));
  return [...canonicalRows.values()]
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
          isLatestMessage: (message as any).is_latest_message === true,
          optionsRevision: (message as any).optionsRevision,
          questionAnswer: (message as any).question_answer,
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
  chainTarget,
  paneId,
  focusMessageId,
  isActiveTab = true,
  isMobile: explicitIsMobile,
  isSinglePane = true,
  variant = 'main',
  projectVcsEnabled = false,
  onOpenAuxTab,
  onSwitchAgent,
  onOpenAgentInSplit,
  chainSelectorRequest,
  onChainSelectorRequestHandled,
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
  // On screen (not behind a maximised pane, an off-screen mobile page or a hidden
  // tab). Hidden panes keep their caches but do not poll or mark read.
  const paneVisible = usePaneVisible();
  // Steady polls are retired: conversation, messages, instance, live tree, bridges and
  // chain detail all refresh from owner-scoped user-WS events (wsInvalidation.ts), and
  // initial/reconnect/gap recovery refetches mounted queries. The policy still tracks
  // 401/403/404/410 so the active-operation fallback below stops on a gone instance.
  const pollPolicy = usePanePollPolicy(paneVisible);

  const convQuery = useFetchConversationQuery(
    { conversationId: '', agentInstanceId: routeInstanceId },
    { skip: !routeInstanceId },
  );
  const conversation = convQuery.data?.conversation || null;
  const conversationId = String(
    conversation?.conversation_id || conversation?.conversationId || '',
  );
  const messagesQuery = useFetchConversationMessagesQuery(
    { conversationId },
    { skip: !conversationId },
  );
  // Message events that reach only hidden panes are deferred (paneDeferral.ts); the
  // newest page refetches once when this pane is shown again (after any older request
  // still in flight settles).
  usePaneDeferredRefresh(conversationId, paneVisible, messagesQuery.refetch, messagesQuery);
  const [fetchOlderMessages, olderMessagesState] = useLazyFetchConversationMessagesQuery();
  const [updateConversationTitle, updateTitleState] = useUpdateConversationTitleMutation();
  const [requestPaneCapture, requestPaneCaptureState] = useRequestPaneCaptureMutation();
  const [sendMessage] = useSendConversationMessageMutation();
  const [answerQuestions] = useAnswerConversationQuestionsMutation();
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
  // A chain-addressed pane knows its chain from the target; an agent pane infers
  // it from its conversation.
  const chainId = String(
    chainTarget?.chainId || conversation?.chain_id || conversation?.chainId || '',
  );
  const ownTargetId = chainTarget?.chainId ? chainTargetId(chainTarget.chainId) : agentInstanceId;
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
    { skip: !chainId },
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
  const chainTitle = String(
    chainDetailQuery.data?.chain?.title || chainTarget?.title || '',
  ).trim();
  // Legacy instance link (REQ-TV2-7): when this instance was its chain's
  // coordinator and has since been replaced, offer the chain-addressed URL.
  const chainConversationQuery = useFetchTaskChainConversationQuery(
    { chainId },
    { skip: !chainId || Boolean(chainTarget) || isAuxSubagent },
  );
  const replacedCoordinator = Boolean(
    !chainTarget &&
      chainId &&
      agentInstanceId &&
      chainConversationQuery.data?.coordinatorAgentInstanceId &&
      chainConversationQuery.data.coordinatorAgentInstanceId !== agentInstanceId &&
      chainConversationQuery.data.replacedCoordinatorInstanceIds.includes(agentInstanceId),
  );
  const openCurrentChainCoordinator = () => {
    const target = chainTargetId(chainId);
    if (!target) return;
    if (onSwitchAgent) onSwitchAgent(target);
    else if (typeof window !== 'undefined') {
      window.location.hash = buildRouteHash(`/conversations/${target}`, '');
    }
  };

  // agent_instance/* events carry the complete instance summary (status, config,
  // current task, run_count/started_at for restarts) and are patched into this entry.
  const instanceQuery = useFetchAgentInstanceQuery(
    { instanceId: agentInstanceId },
    { skip: !agentInstanceId },
  );
  const instance = instanceQuery.data?.instance || null;
  const { data: liveProjects } = useGetAgentsLiveQuery(undefined);
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
  // Bridge status/update/revoke events patch or invalidate this list; opening the
  // runtime picker fetches only the selected bridge's provider status.
  const bridgesQuery = useListBridgesQuery(undefined);
  const bridges = bridgesQuery.data?.bridges || [];
  const instanceBridgeRow = useMemo(
    () => bridges.find((b: any) => bridgeId(b) === instanceBridgeId),
    [bridges, instanceBridgeId],
  );
  // Provider status for this pane's bridge only (it gates sending); polled only while
  // the runtime is being edited.
  const instanceProviders = useBridgeProviderStatus(instanceBridgeRow, { live: editingRuntime });
  const instanceBridge = instanceProviders.bridge;

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

  // REQ-AT-1: task items waiting on the user in this conversation (its chain, or
  // the agent instance without one) replace the composer with the action tray.
  // Answer / Request changes borrow the composer with their own draft
  // (`trayDraft`), so the persisted chat draft is never touched.
  const trayItemList = useActionTrayItems(
    { chainId, agentInstanceId },
    { skip: isAuxSubagent || !agentInstanceId },
  );
  const [trayState, dispatchTray] = useReducer(trayReducer, INITIAL_TRAY_STATE);
  const [trayDraft, setTrayDraft] = useState('');
  const [trayNotice, setTrayNotice] = useState('');
  const sendTrayMode = useSendTrayMode();
  const trayItemIds = useMemo(() => trayItemList.map((item) => item.card_id), [trayItemList]);
  const trayItemIdsKey = trayItemIds.join('\n');
  const draftEmpty = !draft.trim();
  useEffect(() => {
    dispatchTray({ type: 'items', ids: trayItemIds, draftEmpty });
  }, [trayItemIdsKey]); // eslint-disable-line react-hooks/exhaustive-deps
  const trayMode = trayState.mode;
  // Only task items borrow the composer (agent blockers act in place).
  const trayModeFound = trayMode
    ? trayItemList.find((item) => item.card_id === trayMode.cardId)
    : undefined;
  const trayModeItem = trayModeFound?.kind === 'task' ? trayModeFound : undefined;
  const showTray = trayVisible(trayState, trayItemList.length);
  useEffect(() => {
    if (!trayNotice) return;
    const id = setTimeout(() => setTrayNotice(''), 3500);
    return () => clearTimeout(id);
  }, [trayNotice]);
  // Leaving a mode clears its draft.
  useEffect(() => {
    if (!trayMode) setTrayDraft('');
  }, [trayMode]);

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
  // REQ-FROST-1: on mobile the composer dock floats over the transcript; its measured
  // height becomes the transcript's bottom inset so the last message stays reachable.
  const composerDockRef = useRef<HTMLDivElement | null>(null);
  const [composerDockHeight, setComposerDockHeight] = useState(0);
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

  // The model pill keeps its label down to phone widths (it truncates); only a composer
  // narrower than a small phone collapses it to the provider icon.
  useEffect(() => {
    const el = composerContainerRef.current;
    if (!el || typeof ResizeObserver === 'undefined') return;
    const checkWidth = () => {
      if (typeof el.getBoundingClientRect === 'function') {
        const rect = el.getBoundingClientRect();
        setIsSmallComposer(rect.width > 0 && rect.width < COMPACT_MODEL_PILL_WIDTH);
      }
    };
    checkWidth();
    const observer = new ResizeObserver((entries) => {
      for (const entry of entries) {
        const width = entry.contentRect.width;
        setIsSmallComposer(width > 0 && width < COMPACT_MODEL_PILL_WIDTH);
      }
    });
    observer.observe(el);
    return () => observer.disconnect();
    // showTray: the composer form unmounts while the action tray has the dock.
  }, [conversation?.conversation_id, conversation?.conversationId, agentInstanceId, showTray]);

  useEffect(() => {
    const el = composerDockRef.current;
    if (!el || typeof ResizeObserver === 'undefined') {
      setComposerDockHeight(0);
      return;
    }
    const measure = () => setComposerDockHeight(Math.ceil(el.getBoundingClientRect().height));
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(el);
    return () => observer.disconnect();
  }, [isMobile, conversation?.conversation_id, conversation?.conversationId, agentInstanceId]);

  const [statusMenuOpen, setStatusMenuOpen] = useState(false);
  const [headerActionsOpen, setHeaderActionsOpen] = useState(false);
  const actionsAccess = useActionsAccess();
  const [paletteOpen, setPaletteOpen] = useState(false);
  const [chainSelectorOpen, setChainSelectorOpen] = useState(false);
  const [chainSelectorPlacement, setChainSelectorPlacement] = useState<'replace' | 'right' | 'bottom'>('replace');
  const [chainAgentSwitcherOpen, setChainAgentSwitcherOpen] = useState(false);

  useEffect(() => {
    if (!chainSelectorRequest) return;
    setChainSelectorPlacement(chainSelectorRequest.placement);
    setChainSelectorOpen(true);
    onChainSelectorRequestHandled?.(chainSelectorRequest.id);
  }, [chainSelectorRequest, onChainSelectorRequestHandled]);

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

  const chainAgentOptions = chainAgentGroups[0]?.conversations || [];
  const canOpenChainAgentSwitcher = (
    variant === 'main'
    && isFocusedPane
    && Boolean(paneId)
    && Boolean(chainId)
    && chainAgentOptions.length > 0
  );
  useRegisterActions([{
    id: `workspace.open-chain-agents.${variant}.${paneId || routeInstanceId}`,
    title: 'Agents in this task chain',
    category: 'Workspace',
    sequence: ['s', 'o', 'a'],
    isEnabled: () => canOpenChainAgentSwitcher,
    run: () => {
      if (!canOpenChainAgentSwitcher) return;
      setChainAgentSwitcherOpen(true);
      refetchIfStarted(chainDetailQuery);
    },
  }]);

  const fileInputRef = useRef<HTMLInputElement | null>(null);

  const [renaming, setRenaming] = useState(false);
  const [titleDraft, setTitleDraft] = useState('');
  const [titleError, setTitleError] = useState('');

  const destinationBridgeId = stagedBridgeId ?? instanceBridgeId;
  const destinationProjectId = projectId;
  const destinationBridgeRow = useMemo(
    () => bridges.find((item: any) => bridgeId(item) === destinationBridgeId),
    [bridges, destinationBridgeId],
  );
  const stagingOtherBridge = destinationBridgeId !== instanceBridgeId;
  const destinationProviders = useBridgeProviderStatus(destinationBridgeRow, {
    skip: !stagingOtherBridge,
    live: editingRuntime,
  });
  const destination = stagingOtherBridge ? destinationProviders : instanceProviders;
  const destinationBridge = destination.bridge;
  const destinationProjectQuery = projectQuery;
  const operationQuery = useListInstanceReconfigurationsQuery(
    { instanceId: agentInstanceId },
    {
      // A deleted instance (404) has no reconfigurations to poll either.
      skip: !agentInstanceId,
      // Event-driven: every phase advance publishes agent_instance_reconfiguration and
      // the hub reaper progresses operations without client reads. While an operation
      // this pane accepted is unsettled, a slow focused fallback covers a missed frame
      // between resyncs; idle panes never poll.
      pollingInterval:
        pollPolicy.isTerminal('instance') || pollPolicy.isTerminal('reconfigurations')
          ? 0
          : acceptedOperation &&
              !['ready', 'failed', 'recovery_required'].includes(acceptedOperation.phase)
            ? visiblePollInterval(paneVisible, RECONFIGURATION_ACTIVE_FALLBACK_MS)
            : 0,
      skipPollingIfUnfocused: true,
    },
  );
  pollPolicy.useReportErrors({
    conversation: convQuery.error,
    messages: messagesQuery.error,
    instance: instanceQuery.error,
    reconfigurations: operationQuery.error,
  });
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

  const transcriptMessages = useMemo(
    () => groupTranscriptMessages(chatMessages),
    [chatMessages],
  );
  const liveChain = chainDetailQuery.data?.chain;
  const isChainCoordinator = Boolean(chainId) && (
    String(liveChain?.coordinatorAgentInstanceId || liveChain?.coordinator_agent_instance_id || '') === agentInstanceId ||
    (liveChain?.members || []).some((member: any) =>
      String(member.agentInstanceId || member.agent_instance_id || '') === agentInstanceId &&
      (member.role === 'coordinator' || member.isCoordinator === true))
  );

  const needsStart = runtimeNeedsStart(runtimeStatus);
  const runtimeStopping = runtimeIsStopping(runtimeStatus);
  const runtimeActionBusy =
    operationInFlight ||
    retryConfigurationState.isLoading ||
    reconfigureState.isLoading ||
    restartState.isLoading ||
    stopState.isLoading;
  // Composer "Bypass permissions" toggle: the catalog descriptor for the
  // instance's provider comes from the bridge provider-status (only fetched
  // while the settings panel is open).
  const instanceProvidersQuery = useListBridgeProvidersQuery(
    { bridgeId: instanceBridgeId },
    { skip: !instanceBridgeId || !runtimeMenuOpen },
  );
  const instanceCatalogExtension = useMemo(
    () =>
      (instanceProvidersQuery.data?.providers || []).find(
        (entry: any) => entry?.provider === instanceProvider,
      )?.extension ?? null,
    [instanceProvidersQuery.data, instanceProvider],
  );
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
  const unreadCount = Number(conversation?.unread_count || conversation?.unreadCount || 0);
  usePaneMarkRead({
    isActiveTab,
    paneVisible,
    conversationId,
    agentInstanceId,
    unreadCount,
    markRead: (id) => void markRead({ conversationId: id }),
  });
  // No catch-up refetch on show: nothing polls, and events/resyncs reach a hidden
  // pane's subscriptions the same as a visible one's.
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
  // The refetched newest page (after new messages, a reconnect or a show) may have
  // dropped rows the loaded older pages do not hold: carry them, or re-anchor when the
  // pages no longer join (reconcileOlderPages).
  const previousBaseRef = useRef<Message[]>([]);
  useEffect(() => {
    const previous = previousBaseRef.current;
    previousBaseRef.current = baseMessages;
    if (previous === baseMessages) return;
    const idOf = (message: Message) => String(message.message_id || message.messageId || message.id || '');
    const { older, reanchor } = reconcileOlderPages(previous, baseMessages, olderMessages, idOf);
    if (reanchor) {
      setOlderMessages([]);
      setOlderCursor(String(messagesQuery.data?.nextCursor || ''));
      setOlderHasMore(Boolean(messagesQuery.data?.hasMore));
    } else if (older !== olderMessages) {
      setOlderMessages(older);
    }
  }, [baseMessages]);
  // Read receipts for older pages held in state (RTK pages are patched in wsInvalidation).
  useEffect(() => {
    if (!conversationId) return undefined;
    const onRead = (event: Event) => {
      const receipt = (event as CustomEvent<ConversationMessagesRead>).detail;
      if (!receipt || receipt.conversationId !== conversationId) return;
      setOlderMessages((current) => applyReadReceipt(current, receipt));
    };
    window.addEventListener(CONVERSATION_MESSAGES_READ_EVENT, onRead);
    return () => window.removeEventListener(CONVERSATION_MESSAGES_READ_EVENT, onRead);
  }, [conversationId]);

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
    capabilitiesLoaded: !instanceBridge || instanceProviders.loaded,
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
    capabilitiesLoaded: !destinationBridge || destination.loaded,
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
  // A borrowed composer (Answer / Request changes) talks to the hub, not the
  // agent runtime, so runtime state does not block it.
  const sendDisabled = trayModeItem
    ? hasUploadingAttachments || hasFailedAttachments || !trayDraft.trim()
    : configurationInputBlocked ||
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

  async function submitTrayMode() {
    if (!trayMode || !trayModeItem) return;
    const text = appendArtifactLinks(
      trayDraft.trim(),
      uploadedAttachments.map((a) => `artifact://${a.id}`),
    ).trim();
    const item = trayModeItem;
    const { kind } = trayMode;
    const typed = trayDraft;
    setError('');
    dispatchTray({ type: 'mode_sent' });
    setAttachments([]);
    try {
      setTrayNotice(await sendTrayMode(item, kind, text));
    } catch (err: any) {
      // The card is back (unsettled): reopen the mode with what was typed.
      dispatchTray({ type: 'start_mode', kind, cardId: item.card_id });
      setTrayDraft(typed);
      setError(errMsg(err, kind === 'answer' ? 'Answer failed' : 'Request changes failed'));
    }
  }

  async function submit(event: FormEvent) {
    event.preventDefault();
    if (sendDisabled) return;
    if (trayModeItem) {
      await submitTrayMode();
      return;
    }
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

  async function togglePermissionBypass(bypass: boolean) {
    if (!agentInstanceId || !instance || runtimeActionBusy) return;
    setRuntimeMenuOpen(false);
    setReconfigStatus(
      bypass ? 'Restarting with permissions bypassed…' : 'Restarting with permission approvals…',
    );
    try {
      const applied = await reconfigureInstance(
        permissionToggleRequest(
          { ...instance, agent_instance_id: agentInstanceId },
          bypass,
          globalThis.crypto?.randomUUID?.() ||
            `perm-${Date.now()}-${Math.random().toString(36).slice(2)}`,
        ),
      ).unwrap();
      setAcceptedOperation(applied);
      setReconfigStatus('');
    } catch (err: any) {
      setReconfigStatus(errMsg(err, 'Permission mode change failed'));
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
  const permissionToggle = permissionToggleState({
    catalogExtension: instanceCatalogExtension,
    instance,
    busy:
      runtimeActionBusy || operationBlocksInput || isStarting || runtimeStopping || !agentInstanceId,
    pendingChanges: pendingReconfig,
  });
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
      {permissionToggle.visible ? (
        <div
          data-debug-id="conversation-permission-toggle"
          className="mb-4 rounded-xl border border-subtle p-3"
        >
          <label className="flex min-h-11 items-center justify-between gap-3 text-sm text-primary">
            <span>
              <span className="block font-medium">Bypass permissions</span>
              <span className="block text-xs text-muted">
                {permissionToggle.bypass
                  ? 'The agent runs tools without asking.'
                  : 'The agent asks before running tools; approve them here.'}{' '}
                Applies to this running agent and restarts it. The agent&apos;s
                default is set in its settings.
              </span>
            </span>
            <input
              type="checkbox"
              role="switch"
              data-debug-id="conversation-permission-toggle-input"
              aria-checked={permissionToggle.bypass}
              checked={permissionToggle.bypass}
              disabled={permissionToggle.disabled}
              onChange={(e) => void togglePermissionBypass(e.target.checked)}
              className="h-5 w-5 shrink-0 accent-accent disabled:opacity-40"
            />
          </label>
          {permissionToggle.hint ? (
            <p
              data-debug-id="conversation-permission-toggle-hint"
              className="mt-1 text-xs text-muted"
            >
              {permissionToggle.hint}
            </p>
          ) : null}
        </div>
      ) : null}
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
    const showNeedYouPill = needYouPillVisible(trayState, trayItemList.length);
    const composerInput = (
      <MessageComposerInput
        mobile={isMobile}
        debugId="conversation-composer-input"
        ref={textareaRef}
        value={trayModeItem ? trayDraft : draft}
        disabled={trayModeItem ? false : configurationInputBlocked}
        onChange={(e) => {
          if (trayModeItem) {
            setTrayDraft(e.target.value);
            return;
          }
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
          if (e.key === 'Escape' && trayModeItem) {
            e.preventDefault();
            dispatchTray({ type: 'cancel_mode' });
          }
        }}
        onPaste={handleComposerPaste}
        placeholder={
          trayMode && trayModeItem
            ? TRAY_MODE_COPY[trayMode.kind].placeholder
            : isMobile
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
      uploadDisabled: trayModeItem ? false : configurationInputBlocked,
      sendDisabled,
      paneExpanded: false,
      onPaneToggle: handleOpenPtyTab,
      onOpenTasks: chainId ? () => openAux({ type: 'tasks' }) : undefined,
    };
    const runtimeLabel = needsStart
      ? 'Stopped'
      : runtimeStopping
      ? 'Stopping…'
      : isStarting
      ? 'Starting…'
      : isWorking
      ? 'Working…'
      : 'Running';
    const runtimeStatusMenu = (
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
            data-status={runtimeStateFromStatus(runtimeStatus)}
            aria-label={`Agent ${runtimeLabel.replace('…', '').toLowerCase()}. Start or stop the agent`}
            title={`${runtimeLabel} — start/stop the agent`}
            className={`grid shrink-0 place-items-center rounded-full hover:bg-neutral-soft ${isMobile ? 'h-10 w-10' : 'h-9 w-9'}`}
          >
            <MessageComposerStatus
              debugPrefix="conversation"
              tone={runtimeStatusToTone(runtimeStatus)}
              label={runtimeLabel}
            />
          </button>
        }
      >
        <Menu.Label>Runtime: {runtimeLabel}</Menu.Label>
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
    );
    return (
      <form
        ref={composerContainerRef as any}
        onSubmit={submit}
        data-debug-id="conversation-composer-shell"
        className={`w-full max-w-4xl mx-auto ${showNeedYouPill ? 'pt-5' : 'pt-2'} ${
          isMobile ? 'px-3 ui-float-dock-pad' : 'px-3 sm:px-0 pb-4'
        }`}
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
                        className={`rounded-full border border-subtle text-primary hover:bg-neutral-soft ${isMobile ? 'min-h-11 px-4' : 'px-2 py-0.5'}`}
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
                      className={`rounded-full border border-subtle text-muted hover:bg-neutral-soft hover:text-primary ${isMobile ? 'min-h-11 px-4' : 'px-2 py-0.5'}`}
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
            className={
              isMobile
                ? 'ui-frost-card relative isolate rounded-[26px] border px-3 py-2.5 focus-within:border-accent'
                : 'ui-frost-card relative isolate rounded-[22px] border px-3 py-2.5 focus-within:border-accent sm:px-4 sm:py-3'
            }
          >
            {/* REQ-FROST-2: stacked backdrop layers, strongest behind the input row and
                fading toward the action row (see `.ui-frost-gradient` in styles.css). */}
            <div data-debug-id="conversation-composer-frost" aria-hidden="true" className="ui-frost-gradient -z-10">
              <span />
              <span />
              <span />
            </div>
            {/* REQ-AT-1: rides on the card's top edge, so it costs the composer no height. */}
            {showNeedYouPill ? (
              <div className="absolute -top-4 right-4 z-10">
                <NeedYouPill
                  count={trayItemList.length}
                  onClick={() => dispatchTray({ type: 'show_items' })}
                />
              </div>
            ) : null}
            {trayMode && trayModeItem ? (
              <div
                data-debug-id="conversation-composer-tray-mode"
                className="mb-2 flex min-w-0 items-center gap-2 rounded-xl bg-warning-soft py-1 pl-2.5 pr-1 text-[13px] text-warning"
              >
                <Icon name={trayMode.kind === 'answer' ? 'chat' : 'pencil'} size={14} className="shrink-0" />
                <span className="min-w-0 flex-1 truncate">
                  {TRAY_MODE_COPY[trayMode.kind].banner}{' '}
                  <strong className="font-semibold">
                    <VaultText value={trayModeItem.title} fallback="this task" />
                  </strong>
                </span>
                <button
                  type="button"
                  aria-label="Cancel"
                  data-debug-id="conversation-composer-tray-mode-cancel"
                  onClick={() => dispatchTray({ type: 'cancel_mode' })}
                  className="grid h-8 w-8 shrink-0 place-items-center rounded-full hover:bg-surface-raised"
                >
                  <Icon name="close" size={14} />
                </button>
              </div>
            ) : null}
            {/* REQ-LAY-2: desktop only (REQ-LAY-3: no chips row on mobile). Bridge/project chips,
                then the runtime StatusDot (start/stop menu) at the right end of the row. */}
            {!isMobile ? (
              <div
                data-debug-id="conversation-composer-context"
                className="mb-2 flex min-w-0 items-center gap-x-2 text-[12px] text-muted"
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
                      {/* The chip opens Project Explorer files only while it is enabled
                          (REQ-EXP-GATE-2); otherwise it just names the project. */}
                      <button
                        type="button"
                        data-debug-id="conversation-composer-project-chip"
                        disabled={!projectVcsEnabled}
                        onClick={projectVcsEnabled ? () => openAux({ type: 'files' }) : undefined}
                        title={projectVcsEnabled ? `Open project files — ${projectName}` : `Project — ${projectName}`}
                        className="inline-flex min-w-0 max-w-[50%] shrink items-center gap-1.5 rounded-md px-1 py-0.5 enabled:hover:bg-neutral-soft enabled:hover:text-primary disabled:cursor-default"
                      >
                        <Icon name="folder" size={13} className="shrink-0" />
                        <span className="min-w-0 truncate font-semibold text-muted">
                          <VaultText value={projectName} fallback="Project" />
                        </span>
                      </button>
                    </>
                  ) : null}
                </div>
                {!conversationReadOnly ? <div className="ml-auto -my-1.5 shrink-0">{runtimeStatusMenu}</div> : null}
              </div>
            ) : null}

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
              {replacedCoordinator ? (
                <div
                  data-debug-id="conversation-replaced-coordinator"
                  role="status"
                  className="mb-2 flex flex-wrap items-center justify-between gap-2 rounded-xl border border-subtle bg-neutral-soft px-3 py-2 text-xs text-muted"
                >
                  <span className="min-w-0 flex-1">
                    This agent no longer coordinates{' '}
                    <VaultText value={chainTitle} fallback="this task chain" as="span" />.
                  </span>
                  <button
                    type="button"
                    data-debug-id="conversation-open-chain-coordinator-btn"
                    onClick={openCurrentChainCoordinator}
                    className="min-h-9 rounded-lg border border-subtle px-3 text-xs font-medium text-primary hover:bg-surface-raised"
                  >
                    Open current coordinator
                  </button>
                </div>
              ) : null}
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
              ) : (
                // REQ-LAY-3: mobile top row = input, then the runtime StatusDot (start/stop menu) at
                // top right, in the same column as the send button below it. REQ-LAY-2: desktop = input only.
                isMobile ? (
                  <div className="flex items-start gap-1">
                    <div className="min-w-0 flex-1 pt-1.5">{composerInput}</div>
                    {runtimeStatusMenu}
                  </div>
                ) : (
                  <div className="min-w-0">{composerInput}</div>
                )
              )}
            </div>

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
            className={`flex ${isMobile ? 'min-h-14' : 'min-h-12'} shrink-0 items-center justify-end gap-1 px-3 py-2`}
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
                className={`grid ${chromeIconButtonSizeClass(isMobile)} place-items-center text-muted hover:bg-neutral-soft hover:text-primary`}
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
        data-pane-active={isFocusedPane ? 'true' : 'false'}
        className={`sticky top-0 z-20 flex ${isMobile ? 'min-h-14' : 'min-h-12'} shrink-0 items-center gap-2 px-3 py-2 sm:gap-3 sm:px-4 bg-canvas/90 backdrop-blur-md overflow-visible`}
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
                className={`${isMobile ? 'min-h-11' : 'min-h-9'} min-w-0 flex-1 rounded-xl border border-subtle bg-surface px-3 py-1.5 text-base font-semibold text-primary outline-none focus:border-accent sm:text-sm`}
                autoFocus
              />
              <button
                type="button"
                data-debug-id="conversation-thread-title-save-btn"
                aria-label="Save conversation title"
                title="Save"
                onClick={() => void saveConversationTitle()}
                disabled={updateTitleState.isLoading || !titleDraft.trim()}
                className={`grid ${isMobile ? 'h-11 w-11 rounded-full' : 'h-9 w-9 rounded-xl'} shrink-0 place-items-center bg-accent text-accent-fg hover:opacity-90 disabled:opacity-50`}
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
                className={`grid ${isMobile ? 'h-11 w-11 rounded-full' : 'h-9 w-9 rounded-xl'} shrink-0 place-items-center border border-subtle bg-surface-raised text-muted hover:bg-neutral-soft hover:text-primary`}
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
                    data-pane-crumb
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
                data-pane-crumb
                aria-label="Select task chain"
                title="Click to search and select task chains"
                onClick={() => {
                  setChainSelectorPlacement('replace');
                  setChainSelectorOpen(true);
                }}
                className={`group flex min-w-0 items-center gap-1.5 rounded-md px-1.5 py-0.5 text-left ${isMobile ? 'min-h-11 text-[15px]' : 'text-sm'} font-medium text-primary hover:bg-neutral-soft hover:text-accent transition-colors cursor-pointer`}
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
                data-pane-crumb
                aria-label="Switch agent in this task chain"
                aria-haspopup="dialog"
                aria-expanded={chainAgentSwitcherOpen}
                onClick={() => {
                  setChainAgentSwitcherOpen(true);
                  refetchIfStarted(chainDetailQuery);
                }}
                className={`flex min-w-0 items-center gap-1.5 rounded-md px-1.5 py-0.5 text-primary hover:bg-neutral-soft ${isMobile ? 'min-h-11 text-[15px]' : ''}`}
              >
                {/* REQ-PORT-5: on mobile the runtime dot lives in the composer card instead. */}
                {!isMobile ? (
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
                ) : null}
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
                className={`grid ${chromeIconButtonSizeClass(isMobile)} shrink-0 place-items-center text-muted hover:bg-neutral-soft hover:text-primary`}
              >
                <Icon name="more-vertical" size={isMobile ? 22 : 18} />
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
              className={`grid ${chromeIconButtonSizeClass(isMobile)} shrink-0 place-items-center text-muted hover:bg-neutral-soft hover:text-primary`}
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
        className={`relative flex w-full min-h-0 min-w-0 max-w-full flex-1 flex-col overflow-x-hidden p-0 sm:px-4 sm:py-3`}
      >
        <ChatMessageList
          conversationKey={conversationId}
          messages={transcriptMessages}
          debugPrefix="conversation-thread"
          focusMessageId={focusMessageId}
          hasMore={olderHasMore && Boolean(olderCursor)}
          paginationCursor={olderCursor}
          loadingOlder={olderMessagesState.isFetching}
          onLoadOlder={loadOlderMessages}
          onReply={handleSendReply}
          onAnswerQuestions={(sourceMessageId, submission) => answerQuestions({ conversationId, sourceMessageId, submission }).unwrap()}
          formatTimestamp={formatMessageTimestamp}
          getDeliveryStatus={deliveryStatusFor}
          agentIsWorking={isWorking}
          bottomInset={composerDockHeight}
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
        >
          <LiveToolActivity
            conversationId={conversationId}
            enabled={isActiveTab && paneVisible}
            instanceId={agentInstanceId}
            members={isChainCoordinator ? [
              { instanceId: agentInstanceId, displayName: agentDisplayName },
              ...(liveChain?.members || []).map((member: any) => ({
                instanceId: String(member.agentInstanceId || member.agent_instance_id || ''),
                displayName: String(member.displayName || member.display_name || ''),
              })),
            ] : [{ instanceId: agentInstanceId, displayName: agentDisplayName }]}
            onOpenShell={(sessionId) => navigateTo(shellViewHref(sessionId))}
          />
        </ChatMessageList>
        <div
          ref={composerDockRef}
          data-debug-id="conversation-thread-composer-dock"
          data-floating="true"
          // REQ-FROST-1 / REQ-PORT-4: float over the transcript on every form factor. Touches
          // in the gaps around the card fall through to the transcript (`.ui-float-dock`).
          className="ui-float-dock absolute inset-x-0 bottom-0 z-20 mx-auto w-full max-w-4xl"
        >
          <div aria-hidden="true" className="ui-frost-tail" />
          <AgentActivityBubbles instanceId={agentInstanceId} />
          {trayNotice ? (
            <div className="pointer-events-none mb-2 flex justify-center px-3">
              <div
                role="status"
                data-debug-id="conversation-tray-notice"
                className="ui-liquid-glass max-w-full truncate rounded-full px-4 py-1.5 text-[13px] text-primary"
              >
                {trayNotice}
              </div>
            </div>
          ) : null}
          {showTray ? (
            <div
              data-debug-id="conversation-action-tray"
              className={isMobile ? 'w-full px-3 pt-2 ui-float-dock-pad' : 'mx-auto w-full max-w-4xl px-3 pt-2 pb-4 sm:px-0'}
            >
              <ActionTray
                items={trayItemList}
                mobile={isMobile}
                onShowComposer={() => {
                  dispatchTray({ type: 'show_composer' });
                  requestAnimationFrame(() => textareaRef.current?.focus());
                }}
                onStartMode={(kind, item) => {
                  setError('');
                  dispatchTray({ type: 'start_mode', kind, cardId: item.card_id });
                  requestAnimationFrame(() => textareaRef.current?.focus());
                }}
              />
            </div>
          ) : (
            renderComposer()
          )}
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
                  // The coordinator is addressed by chain so the pane follows a
                  // coordinator replacement (REQ-TV2-7).
                  const memberTarget =
                    member.isCoordinator && chainId ? chainTargetId(chainId) : member.agentInstanceId;
                  if (onSwitchAgent) {
                    // The workspace swaps the target in THIS pane (deduped: a target
                    // already open elsewhere is focused instead) and syncs the URL.
                    onSwitchAgent(memberTarget, member.title);
                  } else if (typeof window !== 'undefined') {
                    window.location.hash = buildRouteHash(
                      `/conversations/${encodeURIComponent(memberTarget).replace(/%3A/gi, ':')}`,
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
        // Per-pane (REQ-TV2-7): picking a chain swaps THIS pane's target to
        // `chain:<id>` in place (deduped by the workspace); other panes never
        // change. A chain without a coordinator keeps the default navigation to
        // /chains/<id>.
        onSelectChain={
          onSwitchAgent || onOpenAgentInSplit
            ? (chain) => {
                if (chain.coordinatorAgentInstanceId) {
                  const target = chainTargetId(chain.chainId);
                  if (chainSelectorPlacement === 'replace') {
                    if (target !== ownTargetId) onSwitchAgent?.(target);
                  } else {
                    onOpenAgentInSplit?.(target, chainSelectorPlacement);
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
        actionsEnabled={actionsAccess === 'enabled'}
        conversationGroups={chainAgentGroups}
      />
    </div>
  );
}

export default AgentChatPane;
