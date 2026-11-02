import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react';
import type { ReactNode, UIEvent } from 'react';
import { useSelector } from 'react-redux';
import Markdown from '../Markdown';
import ChatHoverCopyButton from '../ChatHoverCopyButton';
import { VaultText } from '../vault/VaultText';
import {
  isVaultArmored,
  containsVaultArmored,
  decryptVaultText,
  decryptEmbeddedVaultTokens,
  resolveCopyableVaultText,
  maskVaultArmored,
  getActiveVaultKey,
} from '../../utils/vaultContent';
import { selectActiveVaultKey, selectIsVaultUnlocked } from '../../store/vaultSlice';
import { visibleMessageOptions, messageOptionsEligible } from './types';
import { conversationOptionsRevision, subscribeConversationOptions } from '../../api/conversationMessageEvents';
import { parseQuestionGroup, type QuestionSubmission } from './multiQuestion';
import MultiQuestionForm from './MultiQuestionForm';
import type { ChatDeliveryStatus, ChatMessage, ChatTimestamp } from './types';
import ChatActionCard from './ChatActionCard';
import { useIsMobile } from '../shell/responsive';
import { Icon, Spinner } from '@ui';
import { replaceVaultTokens } from '../../utils/vaultCrypto.ts';
import WorkingRings from './WorkingRings';

const EMPTY_TIMESTAMP: ChatTimestamp = { label: '', iso: '' };
const EMPTY_DELIVERY: ChatDeliveryStatus = { glyph: '', label: '', tone: '' };

// CHAT-SCROLL: an INBOUND message scrolls the list to the bottom only when the reader
// is already at the bottom (stickyRef), so reading history is never yanked away.
// The user's OWN send always scrolls to the bottom.
const SCROLL_TO_BOTTOM_ON_INBOUND = false;

// Infinite scroll: start fetching the previous page once the top sentinel is within
// this distance of the viewport, so it usually lands before the reader reaches it.
const LOAD_OLDER_ROOT_MARGIN = '400px 0px 0px 0px';

// Deep-link scroll-to-match tuning. HIGHLIGHT_MS is how long the matched message
// stays tinted; MAX_FOCUS_PAGE_LOADS caps how many "load older" pages we auto-fetch
// while hunting for a not-yet-loaded match, so a bad/old id can never loop forever.
const HIGHLIGHT_MS = 1500;
const MAX_FOCUS_PAGE_LOADS = 25;

// prefersReducedMotion reads the user's OS setting (mirrors AgentActivityBubbles):
// when true we skip smooth scrolling and the highlight fade so nothing animates.
function prefersReducedMotion(): boolean {
  return (
    typeof window !== 'undefined' &&
    typeof window.matchMedia === 'function' &&
    window.matchMedia('(prefers-reduced-motion: reduce)').matches
  );
}

function DefaultMessageBody({ body }: { body: string }) {
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
    const sanitized = replaceVaultTokens(body, '[🔒 Encrypted]');
    return <Markdown source={sanitized} compact copyAll={false} />;
  }
  return <Markdown source={decrypted !== null ? decrypted : body} compact copyAll={false} />;
}

// The copy text is resolved ahead of the click: iOS Safari rejects a clipboard write made
// after an `await` in the handler, so decrypting on click would fail on mobile. Until the
// plaintext is ready the button holds the masked body, so ciphertext is never copied.
function MessageCopyButton({ debugId, body, className }: { debugId: string; body: string; className?: string }) {
  const activeKey = useSelector(selectActiveVaultKey);
  const [text, setText] = useState(() => maskVaultArmored(body));

  useEffect(() => {
    let mounted = true;
    setText(maskVaultArmored(body));
    resolveCopyableVaultText(body, activeKey).then((res) => {
      if (mounted) setText(res);
    });
    return () => {
      mounted = false;
    };
  }, [body, activeKey]);

  return <ChatHoverCopyButton debugId={debugId} text={text} className={className} />;
}

export default function ChatMessageList({
  conversationKey,
  messages,
  debugPrefix,
  focusMessageId,
  emptyText = 'No chat loaded.',
  emptyState,
  hasMore = false,
  paginationCursor,
  loadingOlder = false,
  onLoadOlder,
  onScroll: onScrollProp,
  onReply,
  onAnswerQuestions,
  renderMessageTop,
  renderMessageBody,
  formatTimestamp = () => EMPTY_TIMESTAMP,
  getDeliveryStatus = () => EMPTY_DELIVERY,
  agentIsWorking = false,
  children,
  wrapperClassName = 'relative min-h-0 min-w-0 max-w-full flex-1 overflow-hidden overflow-x-hidden',
  scrollClassName = 'chat-scrollbar h-full min-h-0 max-w-full space-y-[22px] overflow-y-auto overflow-x-hidden rounded-none bg-canvas px-1 py-4 sm:space-y-4 sm:rounded-[18px] sm:px-4 sm:py-4',
  bottomInset = 0,
}: {
  conversationKey: string;
  messages: ChatMessage[];
  debugPrefix: string;
  // Deep-link focus target (from `/conversations/:id?msg=:mid`): once messages have
  // loaded, scroll this message into view and briefly highlight it, exactly once per
  // id. Best-effort: if the message isn't on a loaded page yet we simply stay put.
  focusMessageId?: string;
  emptyText?: string;
  emptyState?: ReactNode;
  hasMore?: boolean;
  /** Raw cursor changes even when an entire server page is hidden. */
  paginationCursor?: string;
  loadingOlder?: boolean;
  onLoadOlder?: () => void;
  onScroll?: (event: UIEvent<HTMLDivElement>) => void;
  onReply?: (reply: string) => void;
  onAnswerQuestions?: (sourceMessageId: string, submission: QuestionSubmission) => Promise<unknown>;
  renderMessageTop?: (args: { message: ChatMessage; index: number; messages: ChatMessage[] }) => React.ReactNode;
  renderMessageBody?: (args: { message: ChatMessage; onReply: (reply: string) => void }) => React.ReactNode;
  formatTimestamp?: (unixMs: number) => ChatTimestamp;
  getDeliveryStatus?: (message: ChatMessage) => ChatDeliveryStatus;
  agentIsWorking?: boolean;
  /**
   * Transient conversation-tail content (e.g. live tools) scrolls with messages.
   * The composer stays outside this slot so keyboard resizing keeps it reachable.
   */
  children?: ReactNode;
  wrapperClassName?: string;
  scrollClassName?: string;
  /**
   * REQ-FROST-1: height (px) of a caller overlay floating over the bottom of the list,
   * e.g. the mobile composer card. The list ends with an empty spacer this tall, so
   * auto-scroll and "jump to latest" leave the newest message above the overlay, and
   * the jump button sits just above it. This is empty space, not caller content, so it
   * does not reintroduce the REQ-VIEWPORT-SWEEP-1 bug described on `children`.
   */
  bottomInset?: number;
}) {
  const isMobile = useIsMobile();
  const isUnlocked = useSelector(selectIsVaultUnlocked);
  const installedKey = useSelector(selectActiveVaultKey);
  const activeKey = isUnlocked ? installedKey : null;
  const scrollRef = useRef<HTMLDivElement | null>(null);
  const contentRef = useRef<HTMLDivElement | null>(null);
  const bottomAnchorRef = useRef<HTMLDivElement | null>(null);
  const pendingBottomFrameRef = useRef(0);
  const revision = useSyncExternalStore(subscribeConversationOptions, () => conversationOptionsRevision(conversationKey), () => 0);
  const stickyRef = useRef(true);
  const lastCountRef = useRef(0);
  // First/last keys and scrollHeight as of the previous layout pass, to tell a
  // prepended older page (keep the reader's position) from an appended message.
  const firstKeyRef = useRef<string | null>(null);
  const lastKeyRef = useRef<string | null>(null);
  const prevScrollHeightRef = useRef(0);
  const topSentinelRef = useRef<HTMLDivElement | null>(null);
  const lastConversationRef = useRef(conversationKey);
  const didInitialScrollRef = useRef(false);
  const [showJump, setShowJump] = useState(false);
  const [highlightId, setHighlightId] = useState<string | null>(null);
  const focusedRef = useRef<string | null>(null);
  // Scroll-to-match bookkeeping: how many "load older" pages we've auto-fetched for
  // the current focus id, the id we've already given up on (so we announce "not
  // found" once), and a polite aria-live message for screen readers.
  const focusPageLoadsRef = useRef(0);
  const gaveUpRef = useRef<string | null>(null);
  const [focusAnnouncement, setFocusAnnouncement] = useState('');
  const reduceMotion = prefersReducedMotion();
  const reply = useMemo(() => onReply || (() => undefined), [onReply]);

  const scrollToBottom = useCallback((behavior: ScrollBehavior = 'auto') => {
    const node = scrollRef.current;
    if (!node) return;
    node.scrollTo({ top: node.scrollHeight, behavior: prefersReducedMotion() ? 'auto' : behavior });
    stickyRef.current = true;
    if (bottomAnchorRef.current) bottomAnchorRef.current.style.overflowAnchor = 'auto';
    setShowJump(false);
  }, []);

  useLayoutEffect(() => {
    const node = scrollRef.current;
    const firstKey = messages[0]?.key ?? null;
    const lastKey = messages[messages.length - 1]?.key ?? null;
    const prevFirstKey = firstKeyRef.current;
    const prevLastKey = lastKeyRef.current;
    const prevScrollHeight = prevScrollHeightRef.current;
    firstKeyRef.current = firstKey;
    lastKeyRef.current = lastKey;
    prevScrollHeightRef.current = node?.scrollHeight ?? 0;

    if (lastConversationRef.current !== conversationKey) {
      lastConversationRef.current = conversationKey;
      lastCountRef.current = 0;
      stickyRef.current = true;
      if (bottomAnchorRef.current) bottomAnchorRef.current.style.overflowAnchor = 'auto';
      didInitialScrollRef.current = false;
      setShowJump(false);
    }

    const count = messages.length;
    if (count === 0) {
      lastCountRef.current = 0;
      return;
    }

    if (!didInitialScrollRef.current) {
      didInitialScrollRef.current = true;
      lastCountRef.current = count;
      scrollToBottom('auto');
      return;
    }

    if (count !== lastCountRef.current) {
      const grew = count > lastCountRef.current;
      lastCountRef.current = count;
      // An older page was prepended (same newest message, new oldest one): hold the
      // reader where they were by shifting scrollTop by the height that was added
      // above them. Never scroll to the bottom for this.
      if (grew && node && lastKey === prevLastKey && firstKey !== prevFirstKey) {
        node.scrollTop += node.scrollHeight - prevScrollHeight;
        return;
      }
      if (grew) {
        // Always scroll on the user's OWN send (even if scrolled up); for inbound
        // messages scroll per SCROLL_TO_BOTTOM_ON_INBOUND, else only when the user
        // is already near the bottom (stickyRef).
        const ownSend = messages[count - 1]?.isUser === true;
        if (ownSend || SCROLL_TO_BOTTOM_ON_INBOUND || stickyRef.current) {
          cancelAnimationFrame(pendingBottomFrameRef.current);
          pendingBottomFrameRef.current = requestAnimationFrame(() => scrollToBottom('smooth'));
        }
      }
    }
  }, [conversationKey, messages, scrollToBottom]);

  useLayoutEffect(() => () => cancelAnimationFrame(pendingBottomFrameRef.current), [conversationKey]);

  // Reset the scroll-to-match bookkeeping whenever the target id changes, so a new
  // search result re-runs the hunt (and re-announces) rather than being suppressed by
  // the once-per-id guards below.
  useEffect(() => {
    focusPageLoadsRef.current = 0;
    gaveUpRef.current = null;
    setFocusAnnouncement('');
  }, [focusMessageId]);

  // Deep-link scroll-to-match: bring the target message into view + briefly highlight
  // it, and move focus/announce for a11y. Runs after the initial bottom-scroll layout
  // effect so it wins, and succeeds at most once per focusMessageId (a background
  // poll/new message must not yank the reader back). If the message is NOT on a loaded
  // page yet, auto-fetch older pages (capped) until it appears; if it never does, give
  // up gracefully with a non-blocking announcement (no error, reader stays put).
  useEffect(() => {
    if (!focusMessageId) return;
    if (focusedRef.current === focusMessageId) return;
    if (gaveUpRef.current === focusMessageId) return;
    if (messages.length === 0) return;
    const node = scrollRef.current;
    if (!node) return;

    const el = node.querySelector<HTMLElement>(`[data-debug-id="${debugPrefix}-message-${focusMessageId}"]`);
    if (el) {
      focusedRef.current = focusMessageId;
      const frame = requestAnimationFrame(() => {
        el.scrollIntoView({ block: 'center', behavior: reduceMotion ? 'auto' : 'smooth' });
        // Move keyboard/AT focus to the matched message (non-tab-stop) so keyboard and
        // screen-reader users land on it; preventScroll keeps scrollIntoView in charge.
        el.tabIndex = -1;
        el.focus({ preventScroll: true });
        stickyRef.current = false; // we intentionally moved off the bottom
        if (bottomAnchorRef.current) bottomAnchorRef.current.style.overflowAnchor = 'none';
        setShowJump(true);
      });
      setHighlightId(focusMessageId);
      setFocusAnnouncement('Jumped to the matching message.');
      const timer = window.setTimeout(() => setHighlightId((cur) => (cur === focusMessageId ? null : cur)), HIGHLIGHT_MS);
      return () => { cancelAnimationFrame(frame); window.clearTimeout(timer); };
    }

    // Not loaded yet: walk older pages until the row appears or we exhaust/limit.
    if (hasMore && onLoadOlder && !loadingOlder && focusPageLoadsRef.current < MAX_FOCUS_PAGE_LOADS) {
      focusPageLoadsRef.current += 1;
      setFocusAnnouncement('Loading earlier messages to reach the matching message…');
      onLoadOlder(); // messages grows → this effect re-runs and re-checks
      return;
    }

    // No more pages (or hit the cap) and still not found: stop, announce once.
    if (!loadingOlder) {
      gaveUpRef.current = focusMessageId;
      setFocusAnnouncement('Could not find the matching message in this conversation.');
    }
  }, [focusMessageId, messages, debugPrefix, hasMore, loadingOlder, onLoadOlder, reduceMotion]);

  // Infinite scroll: fetch the previous page when the top sentinel nears the viewport.
  // Waits for the initial bottom-scroll so opening a conversation doesn't page in
  // history the reader never scrolled to.
  useEffect(() => {
    const root = scrollRef.current;
    const sentinel = topSentinelRef.current;
    if (!root || !sentinel || !hasMore || !onLoadOlder || loadingOlder) return;
    if (typeof IntersectionObserver === 'undefined') return;
    const observer = new IntersectionObserver((entries) => {
      if (!didInitialScrollRef.current && messages.length > 0) return;
      if (entries.some((entry) => entry.isIntersecting)) onLoadOlder();
    }, { root, rootMargin: LOAD_OLDER_ROOT_MARGIN });
    observer.observe(sentinel);
    return () => observer.disconnect();
  }, [hasMore, loadingOlder, onLoadOlder, messages.length, paginationCursor]);

  // REQ-FROST-1: when the overlay grows (multi-line draft, attachment tray), keep a
  // reader who was at the bottom pinned there instead of letting the overlay cover it.
  useLayoutEffect(() => {
    if (stickyRef.current && didInitialScrollRef.current) scrollToBottom('auto');
  }, [bottomInset, scrollToBottom]);

  // Live tail rows change independently of message props. Follow their height
  // only for readers already at the bottom; preserve a scrolled-up reader.
  useEffect(() => {
    const content = contentRef.current;
    if (!content || typeof ResizeObserver === 'undefined') return;
    let overflowBootstrapped = false;
    const observer = new ResizeObserver(() => {
      // Keep prepend compensation based on the latest tail height, including
      // changes while the reader is stationary in history.
      prevScrollHeightRef.current = scrollRef.current?.scrollHeight ?? 0;
      // Native anchoring follows the tail during CSS height interpolation. Avoid
      // forcing scrollTop on every ResizeObserver delivery / animation frame.
      if (!stickyRef.current) return;
      const moving = Boolean(content.querySelector('[data-tool-motion="true"]'));
      const node = scrollRef.current;
      if (!moving || (node && node.scrollHeight <= node.clientHeight)) overflowBootstrapped = false;
      // A previously non-scrollable thread has no selected native anchor. Seed
      // it once when the first overflow appears; subsequent frames use native
      // anchoring (scrollTop is then positive), including the rest of this entry.
      const firstOverflow = !overflowBootstrapped && node && node.scrollTop === 0 && node.scrollHeight > node.clientHeight;
      if (moving && firstOverflow) overflowBootstrapped = true;
      if (!moving || firstOverflow) scrollToBottom('auto');
    });
    observer.observe(content);
    return () => observer.disconnect();
  }, [conversationKey, scrollToBottom]);

  const onScroll = useCallback((event: UIEvent<HTMLDivElement>) => {
    onScrollProp?.(event);
    const node = scrollRef.current;
    if (!node) return;
    prevScrollHeightRef.current = node.scrollHeight;
    const distance = node.scrollHeight - node.scrollTop - node.clientHeight;
    const moving = Boolean(contentRef.current?.querySelector('[data-tool-motion="true"]'));
    // Native anchor scrolls must not disable follow as the tail is interpolating.
    if (moving && stickyRef.current) return;
    const nearBottom = distance < (moving ? 1 : 64);
    stickyRef.current = nearBottom;
    if (bottomAnchorRef.current) bottomAnchorRef.current.style.overflowAnchor = nearBottom ? 'auto' : 'none';
    setShowJump(!nearBottom && messages.length > 0);
  }, [messages.length, onScrollProp]);

  const cancelTailFollow = () => {
    cancelAnimationFrame(pendingBottomFrameRef.current);
    stickyRef.current = false;
    if (bottomAnchorRef.current) bottomAnchorRef.current.style.overflowAnchor = 'none';
  };

  return (
    <div className={wrapperClassName}>
      {/* Polite live region for scroll-to-match: announces the jump / paging / not-found
          to screen readers without stealing focus or blocking. */}
      <div data-debug-id={`${debugPrefix}-focus-status`} role="status" aria-live="polite" className="sr-only">{focusAnnouncement}</div>
      <div ref={scrollRef} data-debug-id={`${debugPrefix}-scroll`} onScroll={onScroll}
        onWheel={(event) => { if (event.deltaY < 0) cancelTailFollow(); }} onTouchMove={cancelTailFollow}
        onPointerDown={(event) => { if (event.target === event.currentTarget) cancelTailFollow(); }}
        onKeyDown={(event) => {
          if (event.defaultPrevented || (event.target as HTMLElement).closest('input, textarea, select, [contenteditable="true"]')) return;
          if (['ArrowUp', 'PageUp', 'Home'].includes(event.key) || (event.key === ' ' && event.shiftKey)) cancelTailFollow();
        }}
        className={scrollClassName} style={{ overflowAnchor: 'auto' }}>
        <div ref={contentRef} data-debug-id={`${debugPrefix}-messages-container`}
          className="mx-auto w-full max-w-4xl space-y-3 sm:space-y-4 [--live-tools-tail-gap:12px] sm:[--live-tools-tail-gap:16px]"
          style={{ overflowAnchor: 'none' }}>
          {hasMore ? (
            <div
              ref={topSentinelRef}
              data-debug-id={`${debugPrefix}-load-older-sentinel`}
              className="flex min-h-8 justify-center"
            >
              {loadingOlder ? <Spinner size="sm" label="Loading older messages…" /> : (
                <button type="button" data-debug-id={debugPrefix + '-load-older'}
                  onClick={onLoadOlder} className="text-xs text-muted hover:text-primary">
                  Load older messages
                </button>
              )}
            </div>
          ) : null}
          {messages.length === 0 ? (
            emptyState || <div className="rounded-2xl border border-dashed border-subtle p-6 text-sm text-faint">{emptyText}</div>
          ) : messages.map((message, index) => {
            const timestamp = formatTimestamp(message.createdUnixMs);
            const delivery = getDeliveryStatus(message);
            const isDivider = message.messageType === 'configuration_change' || message.messageType === 'agent_start_clubbed' || message.messageType === 'agent_start' || (message.messageType === 'system' && (
              !message.body || message.body.toLowerCase().includes('started') || message.body.toLowerCase().includes('ready') || message.body.toLowerCase().includes('restart')
            ));
            const isClubbedGroup = message.messageType === 'shell_run_group' || message.messageType === 'tool_activity_group';
            // tool_activity is a lean marker (REQ-EXT-CONV-2): no copy/time row.
            const hideCardChrome = isDivider || isClubbedGroup || message.messageType === 'tool_activity';
            const eligible = messageOptionsEligible(message, revision);
            const options = eligible ? visibleMessageOptions(message, Boolean(activeKey)) : [];
            const questionGroup = message.messageType === 'multi_question' ? parseQuestionGroup(message.metadata) : null;
            return (
              <div key={message.key} data-debug-id={`${debugPrefix}-message-${message.messageId}`} className={`msg group flex min-w-0 max-w-full rounded-xl outline-none focus-visible:shadow-focus ${reduceMotion ? '' : 'transition-colors duration-500'} ${message.messageId === highlightId ? 'bg-warning-soft ring-1 ring-warning' : ''} ${message.isUser ? 'justify-end' : 'justify-start'}`}>
                <div className={`flex min-w-0 max-w-full ${message.isUser ? 'max-w-[86%] items-end sm:max-w-[78%]' : 'w-full items-start'} flex-col text-sm`}>
                  {renderMessageTop ? renderMessageTop({ message, index, messages }) : null}
                  <div className={`min-w-0 max-w-full overflow-hidden break-words [overflow-wrap:anywhere] ${message.isUser ? 'rounded-[15px] border border-subtle bg-surface-raised px-[14px] py-[10px] text-primary' : 'w-full text-primary'}`}>
                    {renderMessageBody ? renderMessageBody({ message, onReply: reply }) : <DefaultMessageBody body={message.body} />}
                    <ChatActionCard message={message} conversationId={conversationKey} onReply={reply} />
                    {questionGroup && !message.isUser ? <MultiQuestionForm
                      key={`${conversationKey}-${message.messageId}`} group={questionGroup}
                      eligible={eligible && Boolean(onAnswerQuestions)} answered={Boolean(message.questionAnswer)} vaultKey={activeKey}
                      debugPrefix={`${debugPrefix}-questions-${message.messageId}`}
                      onSubmit={(submission) => onAnswerQuestions!(message.messageId, submission)}
                    /> : null}
                  </div>
                  {options.length > 0 && !message.isUser && (
                    <div data-debug-id={`${debugPrefix}-message-options-${message.messageId}`} className="mt-2 flex flex-wrap gap-1.5">
                      {options.map((option, optIdx) => (
                        <button
                          key={optIdx}
                          type="button"
                          data-debug-id={`${debugPrefix}-option-chip-${message.messageId}-${optIdx}`}
                          onClick={() => {
                            if (conversationOptionsRevision(conversationKey) !== revision) return;
                            if (isVaultArmored(option) && activeKey) {
                              void decryptVaultText(option, activeKey).then((value) => {
                                if (conversationOptionsRevision(conversationKey) === revision && getActiveVaultKey() === activeKey) reply(value);
                              }).catch(() => undefined);
                            } else reply(option);
                          }}
                          className={`inline-flex items-center rounded-full border border-accent/40 bg-accent/10 ${isMobile ? 'min-h-11 px-4 text-sm' : 'px-3 py-1 text-xs'} font-medium text-accent hover:bg-accent/20 active:scale-95 transition-all cursor-pointer`}
                        >
                          <VaultText value={option} />
                        </button>
                      ))}
                    </div>
                  )}
                  {!hideCardChrome && (
                    <div data-debug-id={`${debugPrefix}-message-actions-${message.messageId}`} className="mt-1 flex min-h-11 w-full items-center justify-end gap-1.5 text-[10px] text-faint sm:min-h-8">
                      <MessageCopyButton debugId={`${debugPrefix}-message-copy-btn-${message.messageId}`} body={message.body} className="rounded-full border border-subtle bg-surface/80 shadow-lg" />
                      {timestamp.label ? <time data-debug-id={`${debugPrefix}-message-${message.messageId}-time`} dateTime={timestamp.iso} title={timestamp.iso}>{timestamp.label}</time> : null}
                      {message.isUser && delivery.glyph ? (
                        <span data-debug-id={`${debugPrefix}-message-${message.messageId}-status`} title={delivery.label} className={delivery.tone}>{delivery.glyph} {delivery.label}</span>
                      ) : null}
                    </div>
                  )}
                </div>
              </div>
            );
          })}
          {agentIsWorking && (
            <div data-debug-id={`${debugPrefix}-working-indicator`} className="msg flex min-w-0 max-w-full justify-start">
              <div className="flex w-full flex-col items-start py-1">
                <WorkingRings size={18} label="The agent is working" />
              </div>
            </div>
          )}
          {children}
        </div>
        {bottomInset > 0 ? (
          <div data-debug-id={`${debugPrefix}-bottom-inset`} aria-hidden="true" className="!mt-0 shrink-0" style={{ height: bottomInset, overflowAnchor: 'none' }} />
        ) : null}
        <div ref={bottomAnchorRef} data-debug-id={`${debugPrefix}-bottom-anchor`} aria-hidden="true"
          className="!mt-0" style={{ height: 1, overflowAnchor: 'auto' }} />
      </div>
      {showJump ? (
        <button
          type="button"
          data-debug-id={`${debugPrefix}-jump-latest-btn`}
          aria-label="Jump to latest"
          title="Jump to latest"
          onClick={() => scrollToBottom('smooth')}
          style={bottomInset > 0 ? { bottom: bottomInset + 12 } : undefined}
          className={`ui-liquid-glass absolute bottom-3 left-1/2 z-30 grid -translate-x-1/2 place-items-center rounded-full text-primary transition-transform active:scale-95 ${isMobile ? 'h-11 w-11' : 'h-9 w-9'}`}
        >
          <Icon name="arrow-down" size={isMobile ? 20 : 18} />
        </button>
      ) : null}
    </div>
  );
}
