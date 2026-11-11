import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react';
import type { ReactNode, RefObject, UIEvent } from 'react';
import { useSelector } from 'react-redux';
import Markdown from '../Markdown';
import { replyPhase, settleReply, useLiveReplies, useReplyMotionVersion } from './replyMotion';
import { useSettleWithoutReveal, type StreamRevealOptions } from './streamReveal';
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
import { usePaneLayoutVisible } from '../workbench/paneVisibility';
import { Icon, Spinner } from '@ui';
import { replaceVaultTokens } from '../../utils/vaultCrypto.ts';
import WorkingRings from './WorkingRings';

const EMPTY_TIMESTAMP: ChatTimestamp = { label: '', iso: '' };
const EMPTY_DELIVERY: ChatDeliveryStatus = { glyph: '', label: '', tone: '' };

// CHAT-SCROLL (user QA round 3): inbound messages, activity rows and replies never
// scroll the list. Only opening a conversation, "jump to latest" and the user's OWN send
// move it: to the bottom, or with pinOnSend to the pin position under the top of the
// list (REQ-PIN-1), which the exchange spacer makes the end of the scroll range.

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

// Reactive form of prefersReducedMotion (mirrors LiveToolActivity): re-renders when the
// OS setting flips mid-session, so a send after the flip honours it.
function subscribeReducedMotion(onChange: () => void): () => void {
  if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return () => undefined;
  const query = window.matchMedia('(prefers-reduced-motion: reduce)');
  if (typeof query.addEventListener === 'function') {
    query.addEventListener('change', onChange);
    return () => query.removeEventListener('change', onChange);
  }
  query.addListener?.(onChange);
  return () => query.removeListener?.(onChange);
}

function useReducedMotion(): boolean {
  return useSyncExternalStore(subscribeReducedMotion, prefersReducedMotion, () => false);
}

// REQ-PIN-1..6: send pin-to-top. On the user's own send the new bubble travels from
// where the composer text was (measured before the insert) to its slot just under the
// top of the list. The strip above it keeps the faded, lightly blurred tail of the
// previous message (its last line and action row).
// REQ-PIN-1 rev4 (user QA round 2): the travel is ~550ms on a visibly curved path, Y on
// PIN_EASE and X on PIN_EASE_X (both start slow, see below); the history moves with the
// bubble on the Y curve as ONE animation. Transforms only (WAAPI, so it runs on the
// compositor; rAF where WAAPI is missing).
export const PIN_TRAVEL_MS = 550;
export const PIN_SETTLE_MS = PIN_TRAVEL_MS;
export const PIN_ACTIVITY_DELAY_MS = 200;
// User direction 2026-11-04 13:04: the Y travel (and the history, on the same curve so the
// bubble stays in its slot) STARTS SLOW. The earlier strong ease-out [0.2, 0.8, 0.2, 1] moved
// ~12% of the distance in the first 16ms frame, so one late first frame on a phone showed
// the bubble already well along its path; this ease-in-out moves ~0.2% there. X starts
// later still, so the path bends.
export type PinEaseCurve = [number, number, number, number];
export const PIN_EASE: PinEaseCurve = [0.4, 0, 0.2, 1];
export const PIN_EASE_X: PinEaseCurve = [0.45, 0, 0.25, 1];
const bezierCss = (ease: PinEaseCurve) => `cubic-bezier(${ease.join(', ')})`;
// The visible tail: from the bubble up to the top of the previous message's last line,
// so that line and its action row peek out, kept within PIN_TAIL_PX..PIN_TAIL_MAX_PX.
export const PIN_TAIL_PX = 48;
export const PIN_TAIL_MAX_PX = 96;
export function pinTailFor(gapToPreviousText: number, lineHeight: number): number {
  return Math.min(PIN_TAIL_MAX_PX, Math.max(PIN_TAIL_PX, Math.round(gapToPreviousText + lineHeight)));
}
// The slot sits below the scroller's top padding, which may clear a floating header
// (e.g. pt-16), so the bubble never lands under that header.
export function pinOffsetFor(paddingTop: number, tail = PIN_TAIL_PX): number {
  return Math.round(paddingTop) + tail;
}
// REQ-PIN-2 rev2 (user QA round 3): the space below the newest exchange is permanent
// layout, not a mode. From the sent row to the end of the scroll range there must be
// exactly `clientHeight - pinOffset` px, so the maximum scrollTop puts the row at
// pinOffset and the list can never scroll past it (behind the composer). Everything
// already below the row (reply, activity, tools, the composer inset spacer, padding)
// counts, and the spacer fills the rest: 0 once the exchange outgrows the view.
export function pinSpacerFor(clientHeight: number, pinOffset: number, belowRowExcludingSpacer: number): number {
  return Math.max(0, Math.round(clientHeight - pinOffset - belowRowExcludingSpacer));
}
// REQ-PIN-2 rev3 (user decision 2026-11-04, "decouple"): the composer and the keyboard
// overlay the conversation instead of resizing it. The exchange is sized against the
// RESTING composer height: the smallest settled dock inset seen for this form factor (the
// collapsed, single-line pill), never the live one. An expanded composer, an attachment
// tray or the keyboard covers the empty space under the pinned bubble.
export function restingInsetFor(previous: number, inset: number): number {
  if (inset <= 0) return previous;
  return previous <= 0 ? inset : Math.min(previous, inset);
}
// While the reader's finger is down or momentum runs, and for this long after the last
// user scroll event, the list never shrinks the spacer or writes scrollTop (iOS kills
// momentum on either); a deferred re-size lands once the scroll is idle.
export const PIN_SCROLL_IDLE_MS = 160;
// "Jump to latest" shows only when the reader is this far above the end of the range.
// A pinOnSend list uses lastContentHidden instead (user QA 2026-11-04 13:24).
export const JUMP_THRESHOLD_PX = 64;
// User QA 13:24: on a pinOnSend list the exchange spacer runs under the floating composer,
// so distance from max scroll says nothing about unread content. "Jump to latest" shows
// only while the bottom of the newest real content sits below the composer's top edge.
export function lastContentHidden(contentBottom: number, composerTop: number): boolean {
  return contentBottom > composerTop + 1;
}
// REQ-PIN-3 rev2: the faded tail follows the scroll position. It is fully on at the
// maximum scrollTop and fades out over the first PIN_FADE_RANGE_PX the reader scrolls up.
export const PIN_FADE_RANGE_PX = 64;
export function pinFadeFor(distanceFromMax: number): number {
  const distance = Math.max(0, distanceFromMax);
  return distance <= 1 ? 1 : Math.max(0, 1 - distance / PIN_FADE_RANGE_PX);
}

// REQ-FADE-1..3: the always-on top edge strip, flush under the header. It fades in over
// the first TOP_FADE_PX of scroll (at the very top there is nothing to dissolve) and
// hands over to the pin tail as that one fades in, so the two never stack into a
// double-dark band.
export const TOP_FADE_PX = 32;
export function topFadeFor(scrollTop: number, pinFade: number): number {
  return Math.min(1, Math.max(0, scrollTop) / TOP_FADE_PX) * (1 - pinFade);
}

function cssPx(el: Element, prop: 'paddingTop' | 'paddingBottom' | 'paddingLeft' | 'borderTopWidth' | 'borderLeftWidth' | 'lineHeight'): number {
  const style = el.ownerDocument.defaultView?.getComputedStyle(el);
  return parseFloat(style?.[prop] ?? '') || 0;
}

// The first opaque background at or above `el`, as "r g b" for rgb(... / alpha): the tail
// fade paints this colour over the strip instead of masking the scroller (REQ-PIN-3 rev3).
function opaqueBackgroundRgb(el: Element | null): string | null {
  for (let node = el; node; node = node.parentElement) {
    const match = node.ownerDocument.defaultView?.getComputedStyle(node).backgroundColor
      ?.match(/^rgba?\(\s*([\d.]+)[\s,]+([\d.]+)[\s,]+([\d.]+)(?:\s*[,/]\s*([\d.]+%?))?\s*\)$/);
    if (match && (match[4] === undefined || parseFloat(match[4]) > 0)) return `${match[1]} ${match[2]} ${match[3]}`;
  }
  return null;
}

// Where an element's text starts on screen (its content box's top-left corner).
function textOrigin(el: Element): { left: number; top: number } {
  const rect = el.getBoundingClientRect();
  return { left: rect.left + cssPx(el, 'borderLeftWidth') + cssPx(el, 'paddingLeft'),
    top: rect.top + cssPx(el, 'borderTopWidth') + cssPx(el, 'paddingTop') };
}

// The send travel moves the pinned row on Y and its inner column on X.
function pinTargetOf(row: HTMLElement, target: 'row' | 'inner'): HTMLElement {
  return target === 'inner' ? (row.firstElementChild as HTMLElement | null) ?? row : row;
}

function resetPinnedRowStyle(content: HTMLElement) {
  const row = content.querySelector<HTMLElement>('[data-chat-pin-row="true"]');
  if (!row) return;
  for (const prop of ['transform', 'translate', 'position', 'z-index']) row.style.removeProperty(prop);
  if (row.firstElementChild instanceof HTMLElement) row.firstElementChild.style.removeProperty('transform');
}

// Solves a CSS cubic-bezier timing function for progress x in [0, 1].
export function cubicBezierAt([x1, y1, x2, y2]: [number, number, number, number], x: number): number {
  if (x <= 0) return 0;
  if (x >= 1) return 1;
  const bx = (t: number) => ((1 - 3 * x2 + 3 * x1) * t + (3 * x2 - 6 * x1)) * t * t + 3 * x1 * t;
  const by = (t: number) => ((1 - 3 * y2 + 3 * y1) * t + (3 * y2 - 6 * y1)) * t * t + 3 * y1 * t;
  let lo = 0;
  let hi = 1;
  let t = x;
  for (let i = 0; i < 24; i += 1) {
    const value = bx(t);
    if (Math.abs(value - x) < 1e-5) break;
    if (value < x) lo = t; else hi = t;
    t = (lo + hi) / 2;
  }
  return by(t);
}

function DefaultMessageBody({ body, reveal }: { body: string; reveal?: StreamRevealOptions }) {
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
        // REQ-ENC-2: a failed open shows the mask, never the ciphertext.
        if (mounted) setDecrypted(maskVaultArmored(body));
      });
    return () => {
      mounted = false;
    };
  }, [body, hasVault, isArmored, activeKey]);

  // A locked body drops the reveal, so settle the live reply right away.
  useSettleWithoutReveal(hasVault && !activeKey ? reveal : undefined);
  if (isArmored && !activeKey) {
    return <VaultText value={body} as="div" />;
  }
  if (containsArmored && !activeKey) {
    const sanitized = replaceVaultTokens(body, '[🔒 Encrypted]');
    return <Markdown source={sanitized} compact copyAll={false} />;
  }
  // REQ-ENC-2: never paint `vault:v2:`. Until a vault body has decrypted, keep the
  // previous plaintext of this row (state survives a body swap on the same key) or show
  // the mask, and hold the reveal.
  const pending = hasVault && (decrypted === null || isVaultArmored(decrypted) || containsVaultArmored(decrypted));
  const source = !hasVault ? body : pending ? maskVaultArmored(body) : decrypted!;
  return <Markdown source={source} compact copyAll={false}
    reveal={reveal && { ...reveal, hold: reveal.hold || pending }} />;
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
  agentActivity,
  children,
  wrapperClassName = 'relative min-h-0 min-w-0 max-w-full flex-1 overflow-hidden overflow-x-hidden',
  scrollClassName = 'chat-scrollbar h-full min-h-0 max-w-full space-y-[22px] overflow-y-auto overflow-x-hidden rounded-none bg-canvas px-1 py-4 sm:space-y-4 sm:rounded-[18px] sm:px-4 sm:py-4',
  bottomInset = 0,
  pinOnSend = false,
  pinOriginRef,
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
  /** `reveal` is set for an agent reply that arrived live (replyMotion.ts); pass it to Markdown. */
  renderMessageBody?: (args: { message: ChatMessage; onReply: (reply: string) => void; reveal?: StreamRevealOptions }) => React.ReactNode;
  formatTimestamp?: (unixMs: number) => ChatTimestamp;
  getDeliveryStatus?: (message: ChatMessage) => ChatDeliveryStatus;
  agentIsWorking?: boolean;
  /** Replaces the default working mark at the scrollable conversation tail. */
  agentActivity?: ReactNode;
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
  /**
   * REQ-PIN-1..6: on the user's own send, pin the new bubble under the top of the list
   * (with the previous message's faded tail above it) instead of scrolling to the bottom.
   * A predicate narrows which appended user rows count as a send (e.g. optimistic rows only).
   */
  pinOnSend?: boolean | ((message: ChatMessage) => boolean);
  /**
   * REQ-PIN-1 rev2: the composer input the sent bubble emerges from (its left edge and
   * top). Without it the bubble starts at the left of the list, just under the dock top.
   */
  pinOriginRef?: RefObject<HTMLElement | null>;
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
  // Opening (or returning to) a conversation lands on the latest message. The first
  // scroll happens before the composer inset and late heights (decrypt, highlighting)
  // exist, so until the reader scrolls, sends or the rows change, layout growth keeps
  // the list at the bottom. There is no saved per-conversation position to restore.
  const openSettleRef = useRef(true);
  const [showJump, setShowJump] = useState(false);
  const [highlightId, setHighlightId] = useState<string | null>(null);
  const focusedRef = useRef<string | null>(null);
  // Scroll-to-match bookkeeping: how many "load older" pages we've auto-fetched for
  // the current focus id, the id we've already given up on (so we announce "not
  // found" once), and a polite aria-live message for screen readers.
  const focusPageLoadsRef = useRef(0);
  const gaveUpRef = useRef<string | null>(null);
  const [focusAnnouncement, setFocusAnnouncement] = useState('');
  const reduceMotion = useReducedMotion();
  // Incoming replies: live agent replies reveal word by word, history renders instantly.
  useLiveReplies(conversationKey, messages, reduceMotion);
  useReplyMotionVersion();
  const pinEnabled = Boolean(pinOnSend);
  const pinOnSendRef = useRef(pinOnSend);
  pinOnSendRef.current = pinOnSend;
  // REQ-PIN-1 rev3: where the composer text sits, read during the render that adds the
  // sent row, i.e. before React commits the insert, the cleared draft or any scroll.
  const pinOriginStartRef = useRef<{ left: number; top: number } | null>(null);
  const renderedCountRef = useRef(messages.length);
  if (messages.length > renderedCountRef.current && pinOnSend && messages[messages.length - 1]?.isUser) {
    const origin = pinOriginRef?.current;
    pinOriginStartRef.current = origin ? textOrigin(origin) : null;
  }
  renderedCountRef.current = messages.length;
  const reduceMotionRef = useRef(reduceMotion);
  reduceMotionRef.current = reduceMotion;
  const reply = useMemo(() => onReply || (() => undefined), [onReply]);
  // Pin-to-top state. The newest sent row is tracked by its stable KEY (the pane keeps
  // the optimistic row's key across the send ack, see AgentChatPane), and its index is
  // derived from the key on each render, so a refetch that trims or prepends rows can
  // neither unpin it nor move the pin to another row (the 30-row newest page slide). There
  // is no pinned "mode" (REQ-PIN-2 rev2): once a send sets the key, the exchange spacer
  // below keeps max scrollTop = the pin position until the next send, a conversation
  // switch or the row leaving the list.
  const [pinKey, setPinKeyState] = useState<string | null>(null);
  const pinKeyRef = useRef<string | null>(null);
  const pinIndex = useMemo(() => (pinKey === null ? -1 : messages.findIndex((message) => message.key === pinKey)), [messages, pinKey]);
  // Where the pinned row (else the last row) sat in content coordinates at the end of the
  // previous layout pass, and the scrollTop then: a refetch that drops rows from the top
  // shifts everything up, and the browser may already have clamped scrollTop by the time
  // the layout effect runs.
  const anchorRef = useRef<{ key: string; top: number; scrollTop: number } | null>(null);
  const prevMessagesRef = useRef<ChatMessage[]>([]);
  // True only while the send travel runs.
  const travelRef = useRef(false);
  const finishTravelRef = useRef<(() => void) | null>(null);
  const [activityHeld, setActivityHeld] = useState(false);
  const pinFrameRef = useRef(0);
  type RowAnimationSpec = { target: 'row' | 'inner'; keyframes: Keyframe[]; options: KeyframeAnimationOptions };
  const pinAnimationsRef = useRef<{ content: Animation; rows: Animation[]; rowEl: HTMLElement; specs: RowAnimationSpec[] } | null>(null);
  const activityTimerRef = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const turnSpacerRef = useRef<HTMLDivElement | null>(null);
  const tailBlurRef = useRef<HTMLDivElement | null>(null);
  const tailFadeRef = useRef<HTMLDivElement | null>(null);
  const edgeBlurRef = useRef<HTMLDivElement | null>(null);
  const edgeFadeRef = useRef<HTMLDivElement | null>(null);
  const messageCountRef = useRef(messages.length);
  messageCountRef.current = messages.length;
  // How far the exchange reaches past the view (0 for a short reply): the pin position
  // is this far above the end of the scroll range.
  const pinOverflowRef = useRef(0);
  // The resolved slot (pinOffsetFor) and where the tail strip starts (the scroller's top
  // padding), measured at each send.
  const [pinOffset, setPinOffset] = useState(PIN_TAIL_PX);
  const [pinTop, setPinTop] = useState(0);
  const [pinBackground, setPinBackground] = useState<string | null>(null);
  const pinOffsetRef = useRef(PIN_TAIL_PX);
  // REQ-PIN-2 rev3: the fixed composer reference (restingInsetFor), per form factor.
  const restingInsetRef = useRef({ mobile: isMobile, value: 0 });
  if (restingInsetRef.current.mobile !== isMobile) restingInsetRef.current = { mobile: isMobile, value: 0 };
  restingInsetRef.current.value = restingInsetFor(restingInsetRef.current.value, bottomInset);
  // The live dock height, for the jump-latest visibility check only (see updateJump).
  const liveInsetRef = useRef(bottomInset);
  liveInsetRef.current = bottomInset;
  const restingInset = restingInsetRef.current.value;
  // The reader's scroll gesture: finger down, or a user scroll event within PIN_SCROLL_IDLE_MS.
  const gestureRef = useRef({ touching: false, lastScroll: -Infinity });
  const idleTimerRef = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const deferredSizeRef = useRef(false);
  const userScrolling = useCallback(() => gestureRef.current.touching
    || performance.now() - gestureRef.current.lastScroll < PIN_SCROLL_IDLE_MS, []);
  // Every programmatic scrollTop write on this list goes through here: the scroll event
  // it raises is not the reader's gesture.
  const programmaticScrollUntilRef = useRef(0);
  const writeScrollTop = useCallback((node: HTMLElement, top: number) => {
    programmaticScrollUntilRef.current = performance.now() + 50;
    node.scrollTop = top;
  }, []);
  const setPinKey = useCallback((key: string | null) => {
    pinKeyRef.current = key;
    setPinKeyState(key);
    const node = scrollRef.current;
    if (node) {
      if (key === null) delete node.dataset.chatPinned;
      else node.dataset.chatPinned = 'true';
    }
  }, []);

  // REQ-PIN-3 rev2: the faded, blurred tail is tied to the scroll position, not a mode:
  // fully on during the travel and at the pin position (max scrollTop for a short reply),
  // fading out as the reader scrolls away, so the end of a long reply is never masked.
  // REQ-PIN-3 rev3 (QA round 5, the first scroll-up stopping on iPad): nothing on the
  // scroller changes while it scrolls. The fade was a mask-image on the scroller driven by
  // a custom property, so every scroll event restyled the whole list and the mask dropped
  // off 64px in, which rebuilds WebKit's scrolling layer and kills the momentum. Two
  // fixed overlays now carry it (a backdrop blur, then the background colour fading the
  // strip), and the scroll only changes their opacity.
  const applyPinFade = useCallback(() => {
    const node = scrollRef.current;
    if (!node) return;
    const fade = pinKeyRef.current === null ? 0
      : travelRef.current ? 1
        : pinFadeFor(Math.abs(node.scrollHeight - node.clientHeight - pinOverflowRef.current - node.scrollTop));
    const value = String(Math.round(fade * 1000) / 1000);
    for (const overlay of [tailBlurRef.current, tailFadeRef.current]) {
      if (overlay && overlay.style.opacity !== value) overlay.style.opacity = value;
    }
    const edge = String(Math.round(topFadeFor(node.scrollTop, fade) * 1000) / 1000);
    for (const overlay of [edgeBlurRef.current, edgeFadeRef.current]) {
      if (overlay && overlay.style.opacity !== edge) overlay.style.opacity = edge;
    }
  }, []);

  // "Jump to latest": re-evaluated on scroll, at settle, after every spacer re-size, when
  // the reply grows and when the live composer inset changes, so a stale value never
  // outlives the layout. A plain list uses the distance from the end of the range. A
  // pinOnSend list (user QA 13:24) compares the bottom of the newest real content (the
  // last row's action row or body, or the revealed activity line) with the composer's
  // live top edge. That edge is read here only; it never feeds the spacer or scrollTop.
  const updateJump = useCallback(() => {
    const node = scrollRef.current;
    if (!node || travelRef.current) return;
    const distance = node.scrollHeight - node.clientHeight - node.scrollTop;
    stickyRef.current = distance < JUMP_THRESHOLD_PX;
    if (!pinOnSendRef.current) {
      setShowJump(!stickyRef.current && messageCountRef.current > 0);
      return;
    }
    const content = contentRef.current;
    const rows = content?.querySelectorAll<HTMLElement>('[data-chat-pin-index]');
    const last = rows && rows.length > 0 ? rows[rows.length - 1] : null;
    if (!content || !last) { setShowJump(false); return; }
    const end = last.querySelector<HTMLElement>('[data-chat-actions]') ?? last.querySelector<HTMLElement>('[data-chat-body]') ?? last;
    let bottom = end.getBoundingClientRect().bottom;
    const activitySlot = content.querySelector<HTMLElement>('[data-chat-pin-activity]');
    if (activitySlot && activitySlot.childElementCount > 0 && activitySlot.getAttribute('aria-hidden') !== 'true') {
      bottom = Math.max(bottom, activitySlot.getBoundingClientRect().bottom);
    }
    const composerTop = node.getBoundingClientRect().top + node.clientHeight - liveInsetRef.current;
    setShowJump(lastContentHidden(bottom, composerTop));
  }, []);

  const clearPinMotion = useCallback(() => {
    cancelAnimationFrame(pinFrameRef.current);
    pinFrameRef.current = 0;
    finishTravelRef.current = null;
    travelRef.current = false;
    const animations = pinAnimationsRef.current;
    pinAnimationsRef.current = null;
    if (animations) { animations.content.onfinish = null; animations.content.cancel(); animations.rows.forEach((a) => a.cancel()); }
    clearTimeout(activityTimerRef.current);
    setActivityHeld(false);
    const content = contentRef.current;
    if (!content) return;
    content.style.transform = '';
    resetPinnedRowStyle(content);
  }, []);

  // REQ-PIN-2 rev2: size the spacer that ends the newest exchange (the sent row and
  // everything after it) so max scrollTop puts that row at pinOffset. Layout positions
  // only (offsetTop/offsetHeight ignore the travel transforms).
  // REQ-PIN-2 rev3 (decouple): measured against the resting composer (restingInsetFor),
  // and re-run only on a send, exchange growth and the scroller's own resize (rotation,
  // window), never on composer, inset, keyboard or visual-viewport changes, nor on scroll.
  // A shrink during the reader's gesture waits until the scroll is idle (`force` skips
  // that for a send or a conversation switch, which are not gestures).
  const sizeTurnSpacer = useCallback((force = false) => {
    const node = scrollRef.current;
    const spacer = turnSpacerRef.current;
    if (!node || !spacer) return;
    const row = pinKeyRef.current === null ? null : contentRef.current?.querySelector<HTMLElement>('[data-chat-pin-row="true"]');
    let height = 0;
    let overflow = 0;
    if (row) {
      const after = restingInsetRef.current.value + (bottomAnchorRef.current?.offsetHeight ?? 0) + cssPx(node, 'paddingBottom');
      const below = spacer.offsetTop - row.offsetTop + after;
      height = pinSpacerFor(node.clientHeight, pinOffsetRef.current, below);
      overflow = Math.max(0, Math.round(below - (node.clientHeight - pinOffsetRef.current)));
    }
    const current = parseFloat(spacer.style.height) || 0;
    if (height < current && !force && userScrolling()) {
      deferredSizeRef.current = true;
      // The visibility check moves no layout, so it need not wait for the gesture.
      updateJump();
      return;
    }
    deferredSizeRef.current = false;
    pinOverflowRef.current = overflow;
    if (height !== current || spacer.style.height === '') spacer.style.height = `${height}px`;
    // The live-inset spacer only reaches past the exchange spacer (the end of a long reply
    // stays reachable above an expanded composer); see the bottom-inset element below.
    const inset = node.querySelector<HTMLElement>('[data-chat-bottom-inset="fixed"]');
    if (inset) inset.style.setProperty('--chat-turn-spacer', `${height}px`);
    applyPinFade();
    updateJump();
  }, [applyPinFade, updateJump, userScrolling]);

  // REQ-PIN-1/1b/6: pin the just-sent row (`key`, rendered at `index`). Runs in a layout effect, before
  // the first paint of the new row: the scroll position jumps to the end of the range
  // (which the exchange spacer makes the pin position), and transforms put the history
  // back where it was and the bubble back where the composer text was. Both then ease to
  // zero together as one motion: the history and the bubble's Y on one curve, the
  // bubble's X on its own curve so the path bends.
  const pinRow = useCallback((index: number, key: string) => {
    const node = scrollRef.current;
    const content = contentRef.current;
    const start = pinOriginStartRef.current;
    pinOriginStartRef.current = null;
    clearPinMotion();
    stickyRef.current = false;
    setShowJump(false);
    if (!node || !content) return;
    const row = content.querySelector<HTMLElement>(`[data-chat-pin-index="${index}"]`);
    if (!row) return;
    // REQ-PIN-2 rev2/5: the previous exchange gives up its space in this same pass.
    setPinKey(key);
    content.querySelectorAll<HTMLElement>('[data-chat-pin-row="true"]').forEach((el) => { delete el.dataset.chatPinRow; });
    row.dataset.chatPinRow = 'true';
    // REQ-PIN-3: keep the previous message's last line and action row in the tail.
    const previous = content.querySelector<HTMLElement>(`[data-chat-pin-index="${index - 1}"] [data-chat-body]`);
    const tail = previous
      ? pinTailFor(row.getBoundingClientRect().top - previous.getBoundingClientRect().bottom, cssPx(previous, 'lineHeight') || 24)
      : PIN_TAIL_PX;
    const paddingTop = cssPx(node, 'paddingTop');
    const offset = pinOffsetFor(paddingTop, tail);
    pinOffsetRef.current = offset;
    setPinOffset(offset);
    setPinTop(Math.round(paddingTop));
    setPinBackground(opaqueBackgroundRgb(node));
    const fromScroll = node.scrollTop;
    sizeTurnSpacer(true);
    const inset = restingInsetRef.current.value;
    writeScrollTop(node, node.scrollHeight - node.clientHeight);
    travelRef.current = true;
    applyPinFade();
    const settle = () => {
      cancelAnimationFrame(pinFrameRef.current);
      pinFrameRef.current = 0;
      finishTravelRef.current = null;
      travelRef.current = false;
      const animations = pinAnimationsRef.current;
      pinAnimationsRef.current = null;
      if (animations) { animations.content.cancel(); animations.rows.forEach((a) => a.cancel()); }
      content.style.transform = '';
      resetPinnedRowStyle(content);
      applyPinFade();
      updateJump();
      setActivityHeld(true);
      clearTimeout(activityTimerRef.current);
      activityTimerRef.current = setTimeout(() => setActivityHeld(false), PIN_ACTIVITY_DELAY_MS);
    };
    // Offsets, in screen pixels, from the resting state back to the moment of send.
    const history = node.scrollTop - fromScroll;
    const bubble = textOrigin(row.querySelector('[data-chat-body]') ?? row);
    const fromX = start ? start.left - bubble.left : 0;
    // Without a composer origin, start just under the dock top (behind the composer).
    const fromY = (start ? start.top : node.getBoundingClientRect().top + node.clientHeight - inset) - bubble.top;
    const duration = PIN_TRAVEL_MS;
    if (reduceMotionRef.current) {
      settle();
      setActivityHeld(false);
      return;
    }
    if (Math.abs(history) < 1 && Math.abs(fromX) < 1 && Math.abs(fromY) < 1) {
      settle();
      return;
    }
    // The row lives inside the moving content, so its own offset excludes the history's.
    const rowX = fromX;
    const rowY = fromY - history;
    // REQ-PIN-6 safety net: the opaque bubble draws above the list while it moves.
    row.style.position = 'relative';
    row.style.zIndex = '1';
    setActivityHeld(true);
    finishTravelRef.current = settle;
    const contentFrames: Keyframe[] = [{ transform: `translate3d(0, ${history}px, 0)` }, { transform: 'translate3d(0, 0, 0)' }];
    // Y runs on the row and X on its inner column, each on its own curve. Both are
    // `transform` (QA round 5: the individual `translate` property is not composited in
    // every WebKit, so at 1x a busy main thread could hold X back while Y ran).
    const specs: RowAnimationSpec[] = [
      { target: 'row', keyframes: [{ transform: `translate3d(0, ${rowY}px, 0)` }, { transform: 'translate3d(0, 0, 0)' }], options: { duration, easing: bezierCss(PIN_EASE) } },
      { target: 'inner', keyframes: [{ transform: `translate3d(${rowX}px, 0, 0)` }, { transform: 'translate3d(0, 0, 0)' }], options: { duration, easing: bezierCss(PIN_EASE_X) } },
    ];
    if (typeof content.animate === 'function' && typeof row.animate === 'function') {
      const contentAnimation = content.animate(contentFrames, { duration, easing: bezierCss(PIN_EASE) });
      const rows = specs.map((spec) => pinTargetOf(row, spec.target).animate(spec.keyframes, spec.options));
      pinAnimationsRef.current = { content: contentAnimation, rows, rowEl: row, specs };
      contentAnimation.onfinish = settle;
      return;
    }
    const apply = (elapsed: number) => {
      const progress = Math.min(1, elapsed / duration);
      const remainingY = 1 - cubicBezierAt(PIN_EASE, progress);
      const remainingX = 1 - cubicBezierAt(PIN_EASE_X, progress);
      content.style.transform = `translate3d(0, ${history * remainingY}px, 0)`;
      const pinned = content.querySelector<HTMLElement>('[data-chat-pin-row="true"]');
      if (pinned) {
        pinned.style.transform = `translate3d(0, ${rowY * remainingY}px, 0)`;
        pinTargetOf(pinned, 'inner').style.transform = `translate3d(${rowX * remainingX}px, 0, 0)`;
      }
    };
    apply(0);
    let begin = -1;
    const step = (now: number) => {
      if (begin < 0) begin = now;
      const elapsed = now - begin;
      if (elapsed >= duration) { settle(); return; }
      apply(elapsed);
      pinFrameRef.current = requestAnimationFrame(step);
    };
    pinFrameRef.current = requestAnimationFrame(step);
  }, [applyPinFade, clearPinMotion, setPinKey, sizeTurnSpacer, updateJump, writeScrollTop]);

  // The optimistic local_ -> server-id swap re-mounts the pinned row mid-travel: carry
  // its animations (and raised stacking) over to the new element, in step with the list.
  // Every layout pass also re-sizes the exchange spacer, before paint.
  useLayoutEffect(() => {
    if (pinKeyRef.current !== null) sizeTurnSpacer();
    const animations = pinAnimationsRef.current;
    if (!animations || !travelRef.current) return;
    const row = contentRef.current?.querySelector<HTMLElement>('[data-chat-pin-row="true"]');
    if (!row || row === animations.rowEl) return;
    animations.rows.forEach((a) => a.cancel());
    row.style.position = 'relative';
    row.style.zIndex = '1';
    const rows = animations.specs.map((spec) => {
      const next = pinTargetOf(row, spec.target).animate(spec.keyframes, spec.options);
      next.playbackRate = animations.content.playbackRate;
      next.currentTime = animations.content.currentTime;
      if (animations.content.playState === 'paused') next.pause();
      return next;
    });
    pinAnimationsRef.current = { ...animations, rows, rowEl: row };
  });

  useEffect(() => () => {
    cancelAnimationFrame(pinFrameRef.current);
    pinAnimationsRef.current?.content.cancel();
    pinAnimationsRef.current?.rows.forEach((a) => a.cancel());
    clearTimeout(activityTimerRef.current);
  }, []);

  // The end of the scroll range: with an exchange spacer this is the pin position
  // (REQ-PIN-3 rev2), so the initial open and "jump to latest" both land there.
  const scrollToBottom = useCallback((behavior: ScrollBehavior = 'auto') => {
    const node = scrollRef.current;
    if (!node) return;
    // Programmatic: the scroll event it fires is not the reader's gesture.
    programmaticScrollUntilRef.current = performance.now() + 50;
    node.scrollTo({ top: node.scrollHeight, behavior: prefersReducedMotion() ? 'auto' : behavior });
    stickyRef.current = true;
    setShowJump(false);
  }, []);

  const settlingOpen = useCallback(() => openSettleRef.current && didInitialScrollRef.current
    && pinKeyRef.current === null && !userScrolling(), [userScrolling]);

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
    const anchor = anchorRef.current;
    anchorRef.current = null;

    if (lastConversationRef.current !== conversationKey) {
      lastConversationRef.current = conversationKey;
      lastCountRef.current = 0;
      clearPinMotion();
      setPinKey(null);
      sizeTurnSpacer();
      stickyRef.current = true;
      didInitialScrollRef.current = false;
      openSettleRef.current = true;
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

    // The pinned key is gone. A caller that re-keys the sent row (the pane keeps the key
    // stable across the send ack; this is the safety net) puts a new user row at the
    // same index: adopt it. Otherwise the sent row itself left the list (deleted, or the
    // conversation was re-anchored): drop the exchange spacer. Rows trimmed around it
    // never unpin it (REQ-PIN-1).
    const prevMessages = prevMessagesRef.current;
    prevMessagesRef.current = messages;
    if (pinKeyRef.current !== null && !messages.some((message) => message.key === pinKeyRef.current)) {
      const prevIndex = prevMessages.findIndex((message) => message.key === pinKeyRef.current);
      const successor = prevIndex >= 0 && messages.length === prevMessages.length ? messages[prevIndex] : undefined;
      if (successor?.isUser && !prevMessages.some((message) => message.key === successor.key)) {
        setPinKey(successor.key);
      } else {
        clearPinMotion();
        setPinKey(null);
        sizeTurnSpacer();
      }
    }

    // REQ-PIN-1: rows were trimmed from the top (the old first row is gone): everything
    // below moved up by the lost height, so move scrollTop with the anchor row and the
    // view stays put. This runs whatever the count did (31 -> 30, or 30 -> 30 with a new
    // reply at the end).
    if (node && anchor && prevFirstKey !== null && firstKey !== prevFirstKey
      && !messages.some((message) => message.key === prevFirstKey)) {
      const index = messages.findIndex((message) => message.key === anchor.key);
      const row = index < 0 ? null : contentRef.current?.querySelector<HTMLElement>(`[data-chat-pin-index="${index}"]`);
      if (row && row.offsetTop !== anchor.top) writeScrollTop(node, anchor.scrollTop + row.offsetTop - anchor.top);
    }

    if (count !== lastCountRef.current) {
      openSettleRef.current = false;
      const prevCount = lastCountRef.current;
      const grew = count > prevCount;
      lastCountRef.current = count;
      // An older page was prepended (same newest message, new oldest one): hold the
      // reader where they were by shifting scrollTop by the height that was added
      // above them. Never scroll to the bottom for this.
      if (grew && node && lastKey === prevLastKey && firstKey !== prevFirstKey) {
        writeScrollTop(node, node.scrollTop + node.scrollHeight - prevScrollHeight);
        return;
      }
      // Only the user's OWN send moves the list (user QA round 3: inbound messages,
      // activity and replies never auto-scroll to the bottom).
      const last = messages[count - 1];
      if (grew && last?.isUser === true) {
        const pinRule = pinOnSendRef.current;
        cancelAnimationFrame(pendingBottomFrameRef.current);
        if (last.key === pinKeyRef.current) return;
        if (typeof pinRule === 'function' ? pinRule(last) : pinRule) {
          // REQ-PIN-1: pin the new bubble under the header instead of following the bottom.
          pinRow(count - 1, last.key);
          return;
        }
        // REQ-PIN-3: while a send is pinned, a user row that is not a new own send (a
        // server copy, an echo from another device) never pulls the view to the bottom.
        if (pinKeyRef.current !== null) return;
        pendingBottomFrameRef.current = requestAnimationFrame(() => scrollToBottom('smooth'));
      }
    }
  }, [clearPinMotion, conversationKey, messages, pinRow, scrollToBottom, setPinKey, sizeTurnSpacer, writeScrollTop]);

  // The strips fade into the list's own background, measured per conversation (and again
  // at each send, in pinRow).
  useLayoutEffect(() => {
    if (!pinEnabled) return;
    setPinBackground(opaqueBackgroundRgb(scrollRef.current));
    applyPinFade();
  }, [applyPinFade, conversationKey, pinEnabled]);

  // Record the anchor for the top-trim compensation above, after every layout pass.
  useLayoutEffect(() => {
    const node = scrollRef.current;
    const content = contentRef.current;
    if (!node || !content || messages.length === 0) return;
    const index = pinIndex >= 0 ? pinIndex : messages.length - 1;
    const row = content.querySelector<HTMLElement>(`[data-chat-pin-index="${index}"]`);
    anchorRef.current = row ? { key: messages[index].key, top: row.offsetTop, scrollTop: node.scrollTop } : null;
  });

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
      if (!entries.some((entry) => entry.isIntersecting)) return;
      onLoadOlder();
    }, { root, rootMargin: LOAD_OLDER_ROOT_MARGIN });
    observer.observe(sentinel);
    return () => observer.disconnect();
  }, [hasMore, loadingOlder, onLoadOlder, messages.length, paginationCursor]);

  // REQ-FROST-1: when the overlay grows (multi-line draft, attachment tray), keep a
  // reader who was at the bottom pinned there instead of letting the overlay cover it.
  // REQ-PIN-2 rev3 (decouple): a pinOnSend list never reacts to its composer; the dock
  // overlays it (see the bottom-inset element).
  useLayoutEffect(() => {
    if (pinEnabled) {
      if (settlingOpen()) scrollToBottom('auto');
      updateJump();
      return;
    }
    if (stickyRef.current && didInitialScrollRef.current) scrollToBottom('auto');
  }, [bottomInset, pinEnabled, scrollToBottom, settlingOpen, updateJump]);

  // A pane the layout hid while staying mounted (a pager page, a tile behind a
  // maximised one, the main area under a maximised aux dock) lands on the latest
  // message again when it is shown, like a fresh open.
  const layoutVisible = usePaneLayoutVisible();
  const wasLayoutVisibleRef = useRef(layoutVisible);
  useLayoutEffect(() => {
    const wasVisible = wasLayoutVisibleRef.current;
    wasLayoutVisibleRef.current = layoutVisible;
    if (!layoutVisible || wasVisible || !didInitialScrollRef.current || pinKeyRef.current !== null) return;
    openSettleRef.current = true;
    scrollToBottom('auto');
  }, [layoutVisible, scrollToBottom]);

  // Revealing the held activity line adds content below the bubble without a resize.
  useLayoutEffect(() => { if (pinEnabled) updateJump(); }, [activityHeld, pinEnabled, updateJump]);

  // Live tail rows change independently of message props. They never move the reader
  // (user QA round 3: no auto-follow of the bottom); only the exchange spacer and the
  // prepend bookkeeping track their height.
  useEffect(() => {
    const content = contentRef.current;
    if (!content || typeof ResizeObserver === 'undefined') return;
    const observer = new ResizeObserver(() => {
      // Keep prepend compensation based on the latest tail height, including
      // changes while the reader is stationary in history.
      prevScrollHeightRef.current = scrollRef.current?.scrollHeight ?? 0;
      sizeTurnSpacer();
      if (settlingOpen()) scrollToBottom('auto');
    });
    observer.observe(content);
    return () => observer.disconnect();
  }, [conversationKey, scrollToBottom, settlingOpen, sizeTurnSpacer]);

  // REQ-PIN-2 rev3: the scroller's own resize (rotation, window, app viewport) re-sizes
  // the exchange. No visualViewport listener and no inset observer: the keyboard and the
  // composer overlay the list instead of resizing it.
  useEffect(() => {
    const node = scrollRef.current;
    if (!pinEnabled || !node || typeof ResizeObserver === 'undefined') return;
    const observer = new ResizeObserver(() => sizeTurnSpacer());
    observer.observe(node);
    return () => observer.disconnect();
  }, [conversationKey, pinEnabled, sizeTurnSpacer]);

  // A spacer shrink deferred during the reader's gesture lands once the scroll is idle.
  const scheduleIdle = useCallback(() => {
    clearTimeout(idleTimerRef.current);
    idleTimerRef.current = setTimeout(() => {
      if (userScrolling()) { scheduleIdle(); return; }
      if (deferredSizeRef.current) sizeTurnSpacer();
    }, PIN_SCROLL_IDLE_MS);
  }, [sizeTurnSpacer, userScrolling]);
  useEffect(() => () => clearTimeout(idleTimerRef.current), []);

  const onScroll = useCallback((event: UIEvent<HTMLDivElement>) => {
    onScrollProp?.(event);
    const node = scrollRef.current;
    if (!node) return;
    prevScrollHeightRef.current = node.scrollHeight;
    if (anchorRef.current) anchorRef.current.scrollTop = node.scrollTop;
    if (performance.now() >= programmaticScrollUntilRef.current) {
      openSettleRef.current = false;
      gestureRef.current.lastScroll = performance.now();
      scheduleIdle();
    }
    // Scrolling never changes the layout (REQ-PIN-2 rev2), only the tail overlays' opacity.
    applyPinFade();
    updateJump();
  }, [applyPinFade, onScrollProp, scheduleIdle, updateJump]);

  const onTouchStart = () => {
    gestureRef.current.touching = true;
  };
  const onTouchEnd = () => {
    gestureRef.current.touching = false;
    // Momentum may follow the lift: its scroll events extend the gesture.
    gestureRef.current.lastScroll = performance.now();
    scheduleIdle();
  };

  // The reader's own scroll-up gesture: stop a pending bottom scroll, and land a send
  // travel at once so it never fights their scroll.
  const cancelTailFollow = () => {
    cancelAnimationFrame(pendingBottomFrameRef.current);
    finishTravelRef.current?.();
    stickyRef.current = false;
  };

  const activity = agentActivity ?? (agentIsWorking && (
    <div data-debug-id={`${debugPrefix}-working-indicator`} className="msg flex min-w-0 max-w-full justify-start">
      <div className="flex w-full flex-col items-start py-1">
        <WorkingRings size={18} label="The agent is working" />
      </div>
    </div>
  ));

  return (
    <div className={wrapperClassName}>
      {pinEnabled ? (
        // REQ-PIN-3 rev3: blur only the tail strip above the pinned bubble, then fade it
        // into the list's own background. REQ-FADE-1..2: the always-on edge strip below the
        // header is the base layer, handing over to the tail while a send is pinned. All
        // four overlays sit outside the scroller and only their opacity follows the scroll
        // (applyPinFade). The gap under the header was the tail starting at the scroller's
        // top padding (`pinTop`): rows scrolling through that padding were cut at the
        // wrapper edge. Both strips now start at 0, the tail with a solid lead over it.
        <>
          <div ref={edgeBlurRef} data-debug-id={`${debugPrefix}-top-edge-blur`} aria-hidden="true"
            className="ui-chat-top-edge-blur" style={{ height: TOP_FADE_PX, opacity: 0 }} />
          <div ref={edgeFadeRef} data-debug-id={`${debugPrefix}-top-edge-fade`} aria-hidden="true"
            className="ui-chat-top-edge-fade"
            style={{ height: TOP_FADE_PX, opacity: 0, ...(pinBackground ? { ['--chat-pin-bg' as string]: pinBackground } : {}) }} />
          <div ref={tailBlurRef} data-debug-id={`${debugPrefix}-pin-tail-blur`} aria-hidden="true"
            className="ui-chat-pin-tail-blur"
            style={{ top: 0, height: pinOffset, opacity: 0, ['--chat-pin-lead' as string]: `${pinTop}px` }} />
          <div ref={tailFadeRef} data-debug-id={`${debugPrefix}-pin-tail-fade`} aria-hidden="true"
            className="ui-chat-pin-tail-fade"
            style={{ top: 0, height: pinOffset, opacity: 0, ['--chat-pin-lead' as string]: `${pinTop}px`, ...(pinBackground ? { ['--chat-pin-bg' as string]: pinBackground } : {}) }} />
        </>
      ) : null}
      {/* Polite live region for scroll-to-match: announces the jump / paging / not-found
          to screen readers without stealing focus or blocking. */}
      <div data-debug-id={`${debugPrefix}-focus-status`} role="status" aria-live="polite" className="sr-only">{focusAnnouncement}</div>
      <div ref={scrollRef} data-debug-id={`${debugPrefix}-scroll`} onScroll={onScroll}
        onWheel={(event) => { if (event.deltaY < 0) cancelTailFollow(); }} onTouchMove={cancelTailFollow}
        onTouchStart={onTouchStart} onTouchEnd={onTouchEnd} onTouchCancel={onTouchEnd}
        onPointerDown={(event) => { if (event.target === event.currentTarget) cancelTailFollow(); }}
        onKeyDown={(event) => {
          if (event.defaultPrevented || (event.target as HTMLElement).closest('input, textarea, select, [contenteditable="true"]')) return;
          if (['ArrowUp', 'PageUp', 'Home'].includes(event.key) || (event.key === ' ' && event.shiftKey)) cancelTailFollow();
        }}
        className={scrollClassName}
        style={{ overflowAnchor: 'none', ...(pinEnabled ? { ['--chat-pin-offset' as string]: `${pinOffset}px`, ['--chat-pin-start' as string]: `${pinTop}px` } : {}) }}>
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
            const replyMotion = replyPhase(message.key);
            const reveal: StreamRevealOptions | undefined = replyMotion ? {
              enabled: replyMotion === 'revealing',
              onSettled: () => settleReply(message.key),
            } : undefined;
            return (
              <div key={message.key} data-debug-id={`${debugPrefix}-message-${message.messageId}`}
                data-chat-pin-index={pinEnabled ? index : undefined}
                data-chat-pin-row={pinEnabled && message.key === pinKey ? 'true' : undefined}
                className={`msg group flex min-w-0 max-w-full rounded-xl outline-none focus-visible:shadow-focus ${reduceMotion ? '' : 'transition-colors duration-500'} ${message.messageId === highlightId ? 'bg-warning-soft ring-1 ring-warning' : ''} ${message.isUser ? 'justify-end' : 'justify-start'}`}>
                <div className={`flex min-w-0 max-w-full ${message.isUser ? 'max-w-[86%] items-end sm:max-w-[78%]' : 'w-full items-start'} flex-col text-sm`}>
                  {renderMessageTop ? renderMessageTop({ message, index, messages }) : null}
                  <div data-chat-body="" className={`min-w-0 max-w-full overflow-hidden break-words [overflow-wrap:anywhere] ${message.isUser ? 'rounded-[15px] border border-subtle bg-surface-raised px-[14px] py-[10px] text-primary' : 'w-full text-primary'}`}>
                    {renderMessageBody ? renderMessageBody({ message, onReply: reply, reveal }) : <DefaultMessageBody body={message.body} reveal={reveal} />}
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
                    // Phase 4: a live reply holds its action row (kept in layout) until the text
                    // settles, then fades it in, with the meta line after it.
                    <div data-debug-id={`${debugPrefix}-message-actions-${message.messageId}`} data-chat-actions="" data-reply-chrome={replyMotion || undefined}
                      className={`mt-1 flex min-h-11 w-full items-center justify-end gap-1.5 text-[10px] text-faint sm:min-h-8${replyMotion === 'revealing' ? ' reply-chrome-held' : ''}`}>
                      <MessageCopyButton debugId={`${debugPrefix}-message-copy-btn-${message.messageId}`} body={message.body} className={`rounded-full border border-subtle bg-surface/80 shadow-lg${replyMotion === 'settled' ? ' reply-chrome-in' : ''}`} />
                      {timestamp.label ? <time data-debug-id={`${debugPrefix}-message-${message.messageId}-time`} dateTime={timestamp.iso} title={timestamp.iso} className={replyMotion === 'settled' ? 'reply-meta-in' : undefined}>{timestamp.label}</time> : null}
                      {message.isUser && delivery.glyph ? (
                        <span data-debug-id={`${debugPrefix}-message-${message.messageId}-status`} title={delivery.label} className={delivery.tone}>{delivery.glyph} {delivery.label}</span>
                      ) : null}
                    </div>
                  )}
                </div>
              </div>
            );
          })}
          {pinEnabled ? (
            // REQ-PIN-4: the activity line appears PIN_ACTIVITY_DELAY_MS after the bubble
            // settles. It keeps its layout box while held, so revealing it moves nothing.
            <div data-debug-id={`${debugPrefix}-pin-activity-slot`} data-chat-pin-activity="" className="empty:hidden"
              aria-hidden={activityHeld || undefined}
              style={activityHeld ? { opacity: 0, pointerEvents: 'none' } : undefined}>
              {activity}
            </div>
          ) : activity}
          {children}
          {pinEnabled ? (
            <div ref={turnSpacerRef} data-debug-id={`${debugPrefix}-pin-turn-spacer`} aria-hidden="true"
              className="!mt-0" style={{ height: 0, overflowAnchor: 'none' }} />
          ) : null}
        </div>
        {bottomInset > 0 && pinEnabled ? (
          // REQ-PIN-2 rev3 (decouple): as tall as the RESTING composer, so the composer never
          // changes the scroll range of a short exchange. It grows (min-height, written per
          // frame by useComposerDockInset as --chat-live-inset) only by however much the live
          // dock outgrows the exchange spacer, which keeps the end of a long reply reachable
          // above an expanded composer without any scrollTop write.
          <div data-debug-id={`${debugPrefix}-bottom-inset`} data-chat-bottom-inset="fixed" aria-hidden="true" className="!mt-0 shrink-0"
            style={{ height: restingInset, minHeight: 'calc(var(--chat-live-inset, 0px) - var(--chat-turn-spacer, 0px))', overflowAnchor: 'none',
              ['--chat-live-inset' as string]: `${bottomInset}px` }} />
        ) : bottomInset > 0 ? (
          <div data-debug-id={`${debugPrefix}-bottom-inset`} data-chat-bottom-inset="" aria-hidden="true" className="!mt-0 shrink-0" style={{ height: bottomInset, overflowAnchor: 'none' }} />
        ) : null}
        <div ref={bottomAnchorRef} data-debug-id={`${debugPrefix}-bottom-anchor`} aria-hidden="true"
          className="!mt-0" style={{ height: 1, overflowAnchor: 'none' }} />
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
