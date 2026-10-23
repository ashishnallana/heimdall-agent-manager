import { StartAgentAction, needsAgentStart, useStartAgent } from './StartAgentAction';
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react';
import { createPortal } from 'react-dom';
import { useDispatch, useSelector } from 'react-redux';
import { useFetchConversationMessagesQuery } from '../../api/endpoints/chats';
import { conversationOptionsRevision, subscribeConversationOptions } from '../../api/conversationMessageEvents';
import { messageOptionsEligible, visibleMessageOptions } from '../chat/types';
import { selectActiveVaultKey, selectIsVaultUnlocked } from '../../store/vaultSlice';
import { decryptVaultText, isVaultArmored, getActiveVaultKey } from '../../utils/vaultContent';
import { VaultText } from '../vault/VaultText';
import { Icon, Spinner, type IconName } from '@ui';
import { heimdallApi } from '../../api/heimdallApi';
import {
  ATTENTION_RANGES,
  attentionApi,
  useGetAttentionQuery,
  EMPTY_ATTENTION_COUNTS,
  type AttentionBlockerItem,
  type AttentionItem,
  type AttentionMessageItem,
  type AttentionRange,
  type AttentionResult,
  type AttentionTaskItem,
} from '../../api/endpoints/attention';
import {
  useAddTaskCommentMutation,
  useGetTaskChainFleetsQuery,
  useListAgentIdentitiesQuery,
  useMarkConversationReadMutation,
  useSendConversationMessageMutation,
} from '../../api/endpoints';
import { attentionScheduler, type ActionScheduler } from '../../services/attention/actionScheduler';
import { acceptCard, assignReviewerAgent, cancelTask, markConversationRead, rejectCard, snoozeCard } from '../../services/attention/attentionActions';
import { ATTENTION_RANGE_LABELS } from '../../services/attention/attentionPrefs';
import { snoozePresets, toHubTimestamp } from '../../services/attention/snoozePresets';
import { appendArtifactLinks } from '../../utils/artifactUpload';
import { buildRouteHash, navigateTo } from '../../utils/appLocation';
import { useDialogA11y } from '../ui/composites/useDialogA11y';
import { AttentionCardBody } from './AttentionCardBody';
import { openBlockerAgent, useResolveBlocker } from './AgentBlockerCard';
import { AttentionComposer, type ComposerSubmit } from './AttentionComposer';
import { DECK_TABS, clampIndex, defaultTab, hideKey, nextLiveTab, reviewerCandidates, stepIndex, swipeAxis, swipeDelta, tabCounts, visibleItems, type DeckTab } from './attentionModel';

const NO_ITEMS: AttentionItem[] = [];

type Popover = null | 'snooze' | 'reviewer';
type Composer = null | 'reply' | 'comment' | 'answer';

/** The deck sheet slides up from the bottom on open and back down on close. */
export const SHEET_MS = 220;

function prefersReducedMotion(): boolean {
  try {
    return typeof window !== 'undefined' && !!window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;
  } catch {
    return false;
  }
}

const DECK_CSS = `
@keyframes attention-in-right { from { transform: translateX(40%); opacity: 0 } to { transform: none; opacity: 1 } }
@keyframes attention-in-left { from { transform: translateX(-40%); opacity: 0 } to { transform: none; opacity: 1 } }
@keyframes attention-sheet-in { from { transform: translateY(calc(100% + var(--ui-bottom-chrome, 32px))) } to { transform: none } }
@keyframes attention-sheet-out { from { transform: none } to { transform: translateY(calc(100% + var(--ui-bottom-chrome, 32px))) } }
@keyframes attention-fade-in { from { opacity: 0 } to { opacity: 1 } }
@keyframes attention-fade-out { from { opacity: 1 } to { opacity: 0 } }
[data-attention-sheet='open'] { animation: attention-sheet-in ${SHEET_MS}ms cubic-bezier(0.2, 0.8, 0.2, 1) }
[data-attention-sheet='closing'] { animation: attention-sheet-out ${SHEET_MS}ms ease-in forwards }
[data-attention-backdrop='open'] { animation: attention-fade-in ${SHEET_MS}ms ease-out }
[data-attention-backdrop='closing'] { animation: attention-fade-out ${SHEET_MS}ms ease-in forwards; pointer-events: none }
[data-attention-top] { display: grid; grid-template-columns: minmax(0, 1fr) auto auto; grid-template-areas: 'title title actions' 'tabs range range'; align-items: center; column-gap: 0.5rem; row-gap: 0.75rem }
[data-attention-top] [data-attention-title] { grid-area: title; align-self: start }
[data-attention-top] [data-attention-actions] { grid-area: actions; align-self: start; justify-self: end }
[data-attention-top] [data-attention-tabs] { grid-area: tabs; overflow-x: auto; scrollbar-width: none }
[data-attention-top] [data-attention-tabs]::-webkit-scrollbar { display: none }
[data-attention-top] [data-attention-range] { grid-area: range; justify-self: end }
/* Compact: phones, foldables and short windows. One band: title, range and
   close on the first row, the tabs (scrolling sideways if needed) on the second;
   the subtitle goes and the rest of the chrome tightens so the card gets the room. */
@media (max-width: 639px), (max-height: 760px) {
  [data-attention-sheet] [data-attention-top] { grid-template-areas: 'title range actions' 'tabs tabs tabs'; row-gap: 0.5rem; padding-top: 0.625rem; padding-bottom: 0.5rem }
  [data-attention-top] [data-attention-title], [data-attention-top] [data-attention-actions] { align-self: center }
  [data-attention-top] [data-attention-title] h2 { font-size: 16px }
  [data-attention-top] [data-attention-title] p { display: none }
  [data-attention-sheet] [data-attention-card] { padding: 0.75rem }
  [data-attention-sheet] [data-attention-options] { padding-top: 0.5rem }
  [data-attention-sheet] [data-attention-counter] { padding-top: 0.25rem; padding-bottom: 0.25rem }
  [data-attention-sheet] [data-attention-dock] { margin-bottom: 0.5rem; padding-top: 0.25rem; padding-bottom: 0.25rem }
}
@media (prefers-reduced-motion: reduce) { [data-attention-slide], [data-attention-sheet], [data-attention-backdrop] { animation: none !important } }
`;

function isTyping(target: EventTarget | null): boolean {
  const el = target as HTMLElement | null;
  return !!el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable);
}

/**
 * The attention deck (attention deck v1): what needs the user across every chain,
 * one card at a time, actionable in place. Messages = the latest unread agent
 * question per instance; Tasks = tasks waiting on the user's review.
 *
 * One-tap actions go through the app-level undo scheduler (held 4s, undoable,
 * survives closing the deck); replies and comments are sent immediately.
 */
export function AttentionDeck({
  open,
  onClose,
  range,
  onRangeChange,
  scheduler = attentionScheduler,
  nowMs,
}: {
  open: boolean;
  onClose: () => void;
  range: AttentionRange;
  onRangeChange: (range: AttentionRange) => void;
  /** Injectable for tests. */
  scheduler?: ActionScheduler;
  nowMs?: number;
}) {
  const dispatch = useDispatch();
  // Stay mounted through the slide-down after open turns false (skipped under
  // reduced motion); input is ignored while closing.
  const [present, setPresent] = useState(open);
  useEffect(() => {
    if (open) {
      setPresent(true);
      return;
    }
    if (!present) return;
    if (prefersReducedMotion()) {
      setPresent(false);
      return;
    }
    const timer = setTimeout(() => setPresent(false), SHEET_MS);
    return () => clearTimeout(timer);
  }, [open]); // eslint-disable-line react-hooks/exhaustive-deps
  const phase: 'open' | 'closing' = open ? 'open' : 'closing';
  // Focus moves into the deck on open (and back on close), so its keys -- Esc
  // included -- work even when focus was in a terminal or preview frame.
  const panelRef = useRef<HTMLElement | null>(null);
  useDialogA11y(open, onClose, panelRef);
  // inert while sliding down: no clicks or focus on a closing deck (set on the
  // node directly; React 18 has no boolean inert prop).
  useLayoutEffect(() => {
    panelRef.current?.toggleAttribute('inert', !open);
  });
  // Every opening revalidates in the background: the cards from last time stay
  // on screen (lastData) while the forced refetch runs, then the response
  // replaces them -- new cards slot in, stale ones drop out, and the card being
  // looked at stays selected by identity. Nothing polls; while the deck is open
  // the hub's attention_changed hint refetches this one query only.
  const query = useGetAttentionQuery({ since: range }, { skip: !open, refetchOnMountOrArgChange: true });
  const lastData = useRef<AttentionResult | undefined>(undefined);
  if (query.data && query.data.since === range) lastData.current = query.data;
  const data = lastData.current?.since === range ? lastData.current : undefined;
  const openedAt = useRef(0);
  if (!open) openedAt.current = 0;
  else if (openedAt.current === 0) openedAt.current = Date.now();
  const fresh = !!query.data && !query.isFetching && (query.fulfilledTimeStamp ?? 0) >= openedAt.current;
  const snap = useSyncExternalStore(scheduler.subscribe, scheduler.getSnapshot, scheduler.getSnapshot);
  const items = data?.items ?? NO_ITEMS;
  const counts = data?.counts ?? EMPTY_ATTENTION_COUNTS;
  const perTab = tabCounts(counts, items, snap.hidden);

  const [tab, setTab] = useState<DeckTab>('message');
  const [index, setIndex] = useState(0);
  const [slide, setSlide] = useState<'left' | 'right' | null>(null);
  const [popover, setPopover] = useState<Popover>(null);
  const [composer, setComposer] = useState<Composer>(null);
  const [notice, setNotice] = useState('');
  const [dragX, setDragX] = useState(0);
  const drag = useRef<{ x: number; y: number; id: number; t: number; dx: number; axis: 'pending' | 'x' | 'y' } | null>(null);
  // Whether this opening's tab came from the data (cached or fresh) or the user.
  const tabChoice = useRef<'none' | 'cached' | 'fresh' | 'user'>('none');
  const now = nowMs ?? Date.now();

  // Reopening resumes where the user left off (same tab, same card). Only when
  // that tab is empty -- on cached cards or once fresh ones arrive -- does the
  // deck move to the first non-empty tab, unless the user picked a tab.
  useEffect(() => {
    if (!open) {
      tabChoice.current = 'none';
      setPopover(null);
      setComposer(null);
      return;
    }
    if (!data || tabChoice.current === 'user') return;
    if (perTab[tab] === 0) {
      const next = defaultTab(perTab);
      if (next !== tab) {
        setTab(next);
        setIndex(0);
      }
    }
    tabChoice.current = fresh ? 'fresh' : 'cached';
  }, [open, data, fresh]); // eslint-disable-line react-hooks/exhaustive-deps

  // Keep the summary cache in step with the deck's counts, so the bar pill
  // stays right while its own query is paused and closing the deck needs no fetch.
  useEffect(() => {
    if (query.data && fresh) dispatch(attentionApi.util.upsertQueryData('getAttentionSummary', { since: range }, { since: range, counts: query.data.counts }) as any);
  }, [query.data, fresh, range, dispatch]);

  // Forget locally-settled cards once the server stops returning them.
  useEffect(() => {
    if (query.data && fresh) scheduler.prune(query.data.items.map(hideKey));
  }, [query.data, fresh, scheduler]);

  // Finishing the last card of a tab moves on to a live tab with cards (never
  // into Snoozed). Only a tab
  // that RAN OUT moves -- clicking an empty tab stays there.
  const prevTabCount = useRef<{ tab: DeckTab; count: number } | null>(null);
  useEffect(() => {
    const count = perTab[tab];
    const prev = prevTabCount.current;
    prevTabCount.current = { tab, count };
    if (!open || !prev || prev.tab !== tab || prev.count === 0 || count > 0) return;
    const next = nextLiveTab(tab, perTab);
    if (next) {
      setTab(next);
      setIndex(0);
      setSlide('right');
    }
  }); // eslint-disable-line react-hooks/exhaustive-deps

  const list = useMemo(() => visibleItems(items, tab, snap.hidden), [items, tab, snap.hidden]);
  const safeIndex = clampIndex(index, list.length);
  const current: AttentionItem | undefined = list[safeIndex];
  // Attention cards can outlive their source. Resolve the canonical conversation
  // row before offering chips or numeric shortcuts; never trust the excerpt alone.
  const optionConversationId = current?.kind === 'message' ? current.action_refs.conversation_id : '';
  const optionPage = useFetchConversationMessagesQuery({ conversationId: optionConversationId }, { skip: !open || !optionConversationId, refetchOnMountOrArgChange: true });
  const optionRevision = useSyncExternalStore(subscribeConversationOptions, () => conversationOptionsRevision(optionConversationId), () => 0);
  const isVaultUnlocked = useSelector(selectIsVaultUnlocked);
  const installedKey = useSelector(selectActiveVaultKey);
  const vaultKey = isVaultUnlocked ? installedKey : null;
  const optionSource = current?.kind === 'message' ? optionPage.data?.messages?.find((row: any) => row.message_id === current.action_refs.message_id) : null;
  const currentOptions: string[] = optionSource && messageOptionsEligible({ isLatestMessage: optionSource.is_latest_message, optionsRevision: optionSource.optionsRevision, questionAnswer: optionSource.question_answer }, optionRevision)
    ? visibleMessageOptions(optionSource, Boolean(vaultKey)) : [];

  // When the list itself changes (a refetch merged in, a card settled), stay on
  // the card that was showing if it is still there; if it left, its neighbour
  // takes its place. Navigation does not change the list, so it is unaffected.
  const shownId = useRef<string | undefined>(undefined);
  useLayoutEffect(() => {
    const prev = shownId.current;
    if (!prev) return;
    const at = list.findIndex((i) => i.card_id === prev);
    if (at >= 0 && at !== safeIndex) setIndex(at);
  }, [list]); // eslint-disable-line react-hooks/exhaustive-deps
  useLayoutEffect(() => {
    shownId.current = current?.card_id;
  });

  const resetCardUi = () => {
    setPopover(null);
    setComposer(null);
    setDragX(0);
  };

  const go = useCallback((delta: number) => {
    if (list.length < 2) return;
    setSlide(delta > 0 ? 'right' : 'left');
    setIndex((i) => stepIndex(clampIndex(i, list.length), delta, list.length));
    resetCardUi();
  }, [list.length]);

  // The deck never refetches itself after an action: the card is already hidden
  // locally and the hub's attention_changed hint brings the one refetch. Only the
  // other views' lists are refreshed here.
  const invalidate = useCallback(() => {
    dispatch(heimdallApi.util.invalidateTags([
      { type: 'Cards', id: 'LIST' },
      { type: 'Task', id: 'LIST' },
      { type: 'Chain', id: 'LIST' },
    ]) as any);
  }, [dispatch]);

  const agentStart = useStartAgent(invalidate);

  const schedule = (item: AttentionItem, label: string, send: (keepalive: boolean) => Promise<void>) => {
    scheduler.schedule({ cardId: hideKey(item), label, run: async (keepalive) => { await send(keepalive); invalidate(); } });
    setSlide('right');
    resetCardUi();
  };

  // Immediate (encrypting) actions.
  const [addComment] = useAddTaskCommentMutation();
  const [sendMessage] = useSendConversationMessageMutation();
  const [markRead] = useMarkConversationReadMutation();

  // Reviewer menu: fetched on demand when it opens -- the chain's fleet, plus the
  // agent list for names (and the reviewer-template fallback).
  const reviewerChainId = open && popover === 'reviewer' && current?.kind === 'task' ? current.action_refs.chain_id : '';
  const fleetQuery = useGetTaskChainFleetsQuery({ chainId: reviewerChainId }, { skip: !reviewerChainId });
  const agentsQuery = useListAgentIdentitiesQuery({ limit: 200 }, { skip: !reviewerChainId });
  const reviewersLoading = !!reviewerChainId && (fleetQuery.isFetching || agentsQuery.isFetching) && !(fleetQuery.data && agentsQuery.data);
  const reviewersError = !reviewersLoading && (fleetQuery.isError || agentsQuery.isError);
  const reviewers = fleetQuery.data && agentsQuery.data ? reviewerCandidates(fleetQuery.data, agentsQuery.data.agents || []) : [];

  const noticeTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(() => () => { if (noticeTimer.current) clearTimeout(noticeTimer.current); }, []);
  const say = (text: string) => {
    setNotice(text);
    if (noticeTimer.current) clearTimeout(noticeTimer.current);
    noticeTimer.current = setTimeout(() => setNotice(''), 3500);
  };

  const replyAndRead = async (item: AttentionMessageItem, body: string, artifactIds: string[] = []) => {
    const conversationId = item.action_refs.conversation_id;
    // The answered card leaves at once, so the next one slides in.
    scheduler.settle(hideKey(item));
    setSlide('right');
    try {
      await (sendMessage({ conversationId, body, artifactIds }) as any).unwrap();
      await (markRead({ conversationId }) as any).unwrap();
      invalidate();
      say(`Reply sent to ${item.context.agent_name || 'the agent'}`);
    } catch (err: any) {
      scheduler.unsettle(hideKey(item));
      throw err;
    }
  };

  const sendOption = (item: AttentionMessageItem, i: number) => {
    const opt = currentOptions[i];
    if (opt === undefined || conversationOptionsRevision(optionConversationId) !== optionRevision) return;
    void (async () => {
      const text = isVaultArmored(opt) && vaultKey ? await decryptVaultText(opt, vaultKey) : opt;
      if (conversationOptionsRevision(optionConversationId) !== optionRevision || (vaultKey && getActiveVaultKey() !== vaultKey)) return;
      await replyAndRead(item, text);
    })().catch((err) => say(`Reply failed: ${err?.message || 'error'}`));
  };

  const submitReply = async (item: AttentionMessageItem, value: ComposerSubmit) => {
    const links = value.attachments.map((a) => a.link);
    const body = value.text || appendArtifactLinks('', links).trim();
    await replyAndRead(item, body, value.attachments.map((a) => a.id));
    setComposer(null);
  };

  const submitComment = async (item: AttentionTaskItem, value: ComposerSubmit, verdict: 'comment' | 'ngtm') => {
    const body = appendArtifactLinks(value.text, value.attachments.map((a) => a.link)).trim();
    const { chain_id: chainId, task_id: taskId } = item.action_refs;
    if (verdict === 'ngtm') {
      scheduler.settle(hideKey(item));
      setSlide('right');
      try {
        // Through the card (its guard pins the attempt): Request changes with the
        // reason; on a plan gate this re-plans with it.
        await rejectCard(item.card_id, false, { summary: body });
      } catch (err) {
        scheduler.unsettle(hideKey(item));
        throw err;
      }
      invalidate();
      say('Changes requested');
    } else {
      await (addComment({ chainId, taskId, body }) as any).unwrap();
      invalidate();
      say('Comment posted');
      // A comment does not settle the review, so the card stays in the deck;
      // move on to the next one anyway.
      go(1);
    }
    setComposer(null);
  };

  // Answer a blocked task (the agent's question, a merge conflict, an exhausted
  // budget): clears the block through the card, so the task is ready again.
  const submitAnswer = async (item: AttentionTaskItem, value: ComposerSubmit) => {
    const note = appendArtifactLinks(value.text, value.attachments.map((a) => a.link)).trim();
    scheduler.settle(hideKey(item));
    setSlide('right');
    try {
      // expected_block: answer the question the user actually saw, not a newer one.
      await acceptCard(item.card_id, false, { note, expected_block: item.details.block_id || undefined });
    } catch (err) {
      scheduler.unsettle(hideKey(item));
      throw err;
    }
    invalidate();
    say('Answer sent');
    setComposer(null);
  };

  // Allow / Deny an agent blocker: immediate (the agent is stalled), not the undo
  // scheduler; the card hides at once and comes back if the call fails.
  const resolveBlocker = useResolveBlocker(scheduler);
  const decideBlocker = (item: AttentionBlockerItem, decision: 'allow' | 'deny') => {
    setSlide('right');
    resetCardUi();
    void resolveBlocker(item, decision).then((err) => say(err ? `Not sent: ${err}` : decision === 'allow' ? 'Allowed' : 'Denied'));
  };

  const openSource = (item: AttentionItem) => {
    if (item.kind === 'agent_blocker') {
      openBlockerAgent(item);
      onClose();
      return;
    }
    const path = item.kind === 'task'
      ? `/chains/${encodeURIComponent(item.action_refs.chain_id)}/tasks/${encodeURIComponent(item.action_refs.task_id)}`
      : item.kind === 'memory'
        // Memories open straight into their editor: "edit it yourself".
        ? `/memory/${encodeURIComponent(item.action_refs.memory_id)}/edit`
        : `/conversations/${encodeURIComponent(item.action_refs.agent_instance_id)}`;
    navigateTo(buildRouteHash(path, ''));
    onClose();
  };

  type DockAction = { key: string; label: string; icon: IconName; tone?: 'success' | 'danger'; run: () => void; debug: string };
  // Snoozed cards keep their original actions: acting settles them in place.
  const dock: DockAction[] = !current ? [] : current.kind === 'agent_blocker' ? (current.details.blocker_kind === 'terminal_prompt' ? [
    { key: 'o', label: 'Open terminal', icon: 'arrow-right', debug: 'open-terminal', run: () => openSource(current) },
  ] : [
    { key: 'a', label: 'Allow', icon: 'check', tone: 'success', debug: 'allow', run: () => decideBlocker(current, 'allow') },
    { key: 'x', label: 'Deny', icon: 'close', tone: 'danger', debug: 'deny', run: () => decideBlocker(current, 'deny') },
    { key: 'o', label: 'Open', icon: 'arrow-right', debug: 'open', run: () => openSource(current) },
  ]) : current.kind === 'task' && current.details.attention === 'blocked' ? [
    { key: 'a', label: needsAgentStart(current) ? 'Start agent' : 'Answer', icon: 'chat', tone: 'success', debug: 'answer', run: () => { if (needsAgentStart(current)) { void agentStart.start(current); return; } setPopover(null); setComposer(composer === 'answer' ? null : 'answer'); } },
    { key: 'c', label: 'Comment', icon: 'chat', debug: 'comment', run: () => { setPopover(null); setComposer(composer === 'comment' ? null : 'comment'); } },
    { key: 's', label: 'Snooze', icon: 'clock', debug: 'snooze', run: () => { setComposer(null); setPopover(popover === 'snooze' ? null : 'snooze'); } },
    { key: 'x', label: 'Cancel task', icon: 'stop', tone: 'danger', debug: 'cancel-task', run: () => schedule(current, 'Task cancelled', (k) => cancelTask((current as AttentionTaskItem).action_refs, k)) },
    { key: 'o', label: 'Open', icon: 'arrow-right', debug: 'open', run: () => openSource(current) },
  ] : current.kind === 'task' ? [
    { key: 'a', label: 'Approve', icon: 'check', tone: 'success', debug: 'approve', run: () => schedule(current, 'Approved', (k) => acceptCard(current.card_id, k)) },
    { key: 'c', label: 'Comment', icon: 'chat', debug: 'comment', run: () => { setPopover(null); setComposer(composer === 'comment' ? null : 'comment'); } },
    ...(current.details.badge === 'gate' ? [] : [
      { key: 'r', label: 'Reviewer', icon: 'bot' as IconName, debug: 'reviewer', run: () => { setComposer(null); setPopover(popover === 'reviewer' ? null : 'reviewer'); } },
    ]),
    { key: 's', label: 'Snooze', icon: 'clock', debug: 'snooze', run: () => { setComposer(null); setPopover(popover === 'snooze' ? null : 'snooze'); } },
    // Cancels the task itself (the card resolves with it), so it says so.
    { key: 'x', label: 'Cancel task', icon: 'stop', tone: 'danger', debug: 'cancel-task', run: () => schedule(current, 'Task cancelled', (k) => cancelTask((current as AttentionTaskItem).action_refs, k)) },
    { key: 'o', label: 'Open', icon: 'arrow-right', debug: 'open', run: () => openSource(current) },
  ] : current.kind === 'memory' ? [
    { key: 'a', label: 'Approve', icon: 'check', tone: 'success', debug: 'approve', run: () => schedule(current, 'Memory approved', (k) => acceptCard(current.card_id, k)) },
    { key: 'x', label: 'Reject', icon: 'close', tone: 'danger', debug: 'reject', run: () => schedule(current, 'Memory rejected', (k) => rejectCard(current.card_id, k)) },
    { key: 's', label: 'Snooze', icon: 'clock', debug: 'snooze', run: () => { setComposer(null); setPopover(popover === 'snooze' ? null : 'snooze'); } },
    { key: 'e', label: 'Edit', icon: 'pencil', debug: 'edit', run: () => openSource(current) },
  ] : [
    { key: 'r', label: 'Reply', icon: 'chat', debug: 'reply', run: () => { setPopover(null); setComposer(composer === 'reply' ? null : 'reply'); } },
    { key: 'm', label: 'Mark read', icon: 'check', tone: 'success', debug: 'mark-read', run: () => schedule(current, 'Marked as read', (k) => markConversationRead((current as AttentionMessageItem).action_refs.conversation_id, k)) },
    { key: 's', label: 'Snooze', icon: 'clock', debug: 'snooze', run: () => { setComposer(null); setPopover(popover === 'snooze' ? null : 'snooze'); } },
    { key: 'o', label: 'Open', icon: 'arrow-right', debug: 'open', run: () => openSource(current) },
  ];

  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        if (popover) setPopover(null);
        else if (composer) setComposer(null);
        else onClose();
        e.preventDefault();
        // Handled here (layered: menu, then composer, then the deck); keep the
        // dialog hook's own Esc from closing the deck on top of it.
        e.stopPropagation();
        return;
      }
      if (isTyping(e.target) || e.metaKey || e.ctrlKey || e.altKey) return;
      if (e.key === 'ArrowRight') { go(1); e.preventDefault(); return; }
      if (e.key === 'ArrowLeft') { go(-1); e.preventDefault(); return; }
      if (/^[1-9]$/.test(e.key) && current?.kind === 'message' && Number(e.key) <= currentOptions.length) {
        e.preventDefault();
        sendOption(current, Number(e.key) - 1);
        return;
      }
      const hit = dock.find((d) => d.key === e.key.toLowerCase());
      if (hit) { e.preventDefault(); hit.run(); }
    };
    window.addEventListener('keydown', onKey, true);
    return () => window.removeEventListener('keydown', onKey, true);
  });

  if ((!open && !present) || typeof document === 'undefined') return null;

  // Swipe / drag to move between cards (navigation only, never an action).
  // Scrolling the card's content wins: the gesture only moves the card once it
  // is clearly horizontal (swipeAxis); a vertical one is left to the browser for
  // the rest of the touch. The pointer is captured only after that horizontal
  // lock, and a pointercancel (the browser took the gesture) never navigates.
  const onPointerDown = (e: React.PointerEvent) => {
    if ((e.target as HTMLElement).closest('button, a, textarea, input, [data-no-drag]')) return;
    drag.current = { x: e.clientX, y: e.clientY, id: e.pointerId, t: e.timeStamp, dx: 0, axis: 'pending' };
  };
  const onPointerMove = (e: React.PointerEvent) => {
    const g = drag.current;
    if (!g || g.id !== e.pointerId || g.axis === 'y') return;
    const dx = e.clientX - g.x;
    if (g.axis === 'pending') {
      g.axis = swipeAxis(dx, e.clientY - g.y);
      if (g.axis !== 'x') return;
      try { (e.currentTarget as HTMLElement).setPointerCapture?.(e.pointerId); } catch { /* not capturable */ }
    }
    g.dx = dx;
    setDragX(dx);
  };
  const onPointerUp = (e: React.PointerEvent) => {
    const g = drag.current;
    if (!g || g.id !== e.pointerId) return;
    drag.current = null;
    setDragX(0);
    if (e.type === 'pointercancel' || g.axis !== 'x') return;
    const delta = swipeDelta(g.dx, e.timeStamp - g.t);
    if (delta !== 0) go(delta);
  };

  const showOlder = range !== 'all' && counts.older > 0;

  return createPortal(
    <div data-debug-id="attention-deck-backdrop" data-attention-backdrop={phase} className="fixed inset-0 z-modal flex items-end justify-center bg-backdrop" onMouseDown={(e) => { if (open && e.target === e.currentTarget) onClose(); }}>
      <style>{DECK_CSS}</style>
      {/* Desktop: a tall sheet, centered, nearly full height (a 40px gap above,
          the bottom chrome below) with a readable max width. Phones: full screen. */}
      <section
        role="dialog"
        aria-modal="true"
        aria-label="What needs you"
        data-debug-id="attention-deck"
        data-attention-sheet={phase}
        ref={panelRef}
        tabIndex={-1}
        className="relative mb-[var(--ui-bottom-chrome,32px)] flex h-[calc(100%-var(--ui-bottom-chrome,32px)-40px)] w-full max-w-[760px] flex-col overflow-hidden rounded-t-[var(--radius-lg)] border border-subtle bg-surface shadow-panel max-sm:mb-0 max-sm:h-full max-sm:rounded-none"
      >
        {/* Header and filters share one grid so short / narrow screens (foldables,
            phones in landscape) can reflow them into a single compact band; see
            DECK_CSS. Desktop: title | close, then tabs | range. */}
        <header data-attention-top className="px-4 pb-3 pt-4">
          <div data-attention-title className="min-w-0">
            <h2 className="truncate text-[18px] font-semibold text-primary">What needs you</h2>
            <p className="text-[12px] text-muted">Questions from agents and tasks waiting on your review, across all chains.</p>
          </div>
          <div data-attention-actions className="flex items-center gap-2">
            {data && query.isError && !query.isFetching ? (
              <button type="button" data-debug-id="attention-deck-refresh-error" className="text-[11px] text-danger underline" onClick={() => query.refetch()}>
                Couldn't refresh · Retry
              </button>
            ) : data && !fresh ? (
              <span data-debug-id="attention-deck-checking" aria-live="polite" className="text-[11px] text-faint">Checking…</span>
            ) : null}
            <button type="button" data-debug-id="attention-deck-close" aria-label="Close" onClick={onClose} className="grid h-8 w-8 shrink-0 place-items-center rounded-full border border-subtle text-muted hover:text-primary">
              <Icon name="close" size={14} />
            </button>
          </div>
          <div role="tablist" aria-label="Kinds" data-attention-tabs className="flex min-w-0 gap-1">
            {DECK_TABS.map((t) => (
              <button
                key={t.id}
                role="tab"
                type="button"
                aria-selected={tab === t.id}
                data-debug-id={`attention-deck-tab-${t.id}`}
                onClick={() => { tabChoice.current = 'user'; setTab(t.id); setIndex(0); resetCardUi(); }}
                className={`shrink-0 whitespace-nowrap rounded-full border px-3 py-1 text-[12px] ${tab === t.id ? 'border-strong bg-surface-raised text-primary' : 'border-subtle text-muted hover:text-primary'}`}
              >
                {t.label}
                <span className={`ml-1.5 tabular-nums ${tab === t.id ? 'text-warning' : 'text-faint'}`}>{perTab[t.id]}</span>
              </button>
            ))}
          </div>
          <div role="group" aria-label="Time range" data-debug-id="attention-deck-range" data-attention-range className="flex rounded-[var(--radius-md)] border border-subtle p-0.5">
            {ATTENTION_RANGES.map((r) => (
              <button
                key={r}
                type="button"
                aria-pressed={range === r}
                data-debug-id={`attention-deck-range-${r}`}
                onClick={() => { onRangeChange(r); setIndex(0); }}
                className={`whitespace-nowrap rounded-[var(--radius-sm)] px-2 py-0.5 text-[11px] ${range === r ? 'bg-surface-raised text-primary' : 'text-muted hover:text-primary'}`}
              >
                {ATTENTION_RANGE_LABELS[r]}
              </button>
            ))}
          </div>
        </header>

        <div className="relative min-h-0 flex-1 px-4" onPointerDown={onPointerDown} onPointerMove={onPointerMove} onPointerUp={onPointerUp} onPointerCancel={onPointerUp}>
          {!data && !query.isError ? (
            <p data-debug-id="attention-deck-loading" className="py-10 text-center text-[13px] text-muted">Loading…</p>
          ) : !data ? (
            <div data-debug-id="attention-deck-error" className="py-10 text-center text-[13px] text-danger">
              Could not load what needs you. <button type="button" className="underline" onClick={() => query.refetch()}>Retry</button>
            </div>
          ) : current ? (
            <div
              key={current.card_id}
              data-attention-slide
              data-debug-id="attention-deck-card"
              data-attention-card
              className="h-full cursor-grab touch-pan-y select-none rounded-[var(--radius-lg)] border border-subtle bg-surface-raised p-4 active:cursor-grabbing"
              style={{
                transform: dragX ? `translateX(${dragX}px) rotate(${dragX / 40}deg)` : undefined,
                transition: dragX ? 'none' : 'transform 180ms ease',
                animation: slide && !dragX ? `attention-in-${slide} 200ms ease-out` : undefined,
              }}
              onAnimationEnd={() => setSlide(null)}
            >
              <AttentionCardBody item={current} now={now}>
                {composer === 'reply' && current.kind === 'message' ? (
                  <AttentionComposer
                    debugId="attention-reply"
                    placeholder={`Reply to ${current.context.agent_name || 'the agent'}…`}
                    originKind="chat"
                    originRef={current.action_refs.conversation_id}
                    submitLabel="Send reply"
                    onSubmit={(v) => submitReply(current, v)}
                    onCancel={() => setComposer(null)}
                  />
                ) : null}
                {composer === 'answer' && current.kind === 'task' ? (
                  <AttentionComposer
                    debugId="attention-answer"
                    placeholder={current.details.badge === 'merge_conflict' ? 'How should the agent resolve it?' : 'Your answer…'}
                    originKind="task_comment"
                    originRef={`${current.action_refs.chain_id}:${current.action_refs.task_id}`}
                    submitLabel="Send answer"
                    onSubmit={(v) => submitAnswer(current, v)}
                    onCancel={() => setComposer(null)}
                  />
                ) : null}
                {composer === 'comment' && current.kind === 'task' ? (
                  <AttentionComposer
                    debugId="attention-comment"
                    placeholder="Write a comment…"
                    originKind="task_comment"
                    originRef={`${current.action_refs.chain_id}:${current.action_refs.task_id}`}
                    submitLabel="Comment"
                    secondaryLabel={current.details.attention === 'blocked' ? undefined : 'Request changes'}
                    onSubmit={(v) => submitComment(current, v, 'comment')}
                    onSecondary={(v) => submitComment(current, v, 'ngtm')}
                    onCancel={() => setComposer(null)}
                  />
                ) : null}
              </AttentionCardBody>
            </div>
          ) : (
            <div data-debug-id="attention-deck-empty" className="flex h-full flex-col items-center justify-center gap-2 text-center">
              <Icon name="check" size={28} />
              <p className="text-[15px] font-semibold text-primary">All clear</p>
              <p className="text-[12px] text-muted">
                {perTab.agent_blocker + perTab.message + perTab.task > 0 ? 'Nothing here. The other tab still has items.' : 'Nothing in this time range needs you.'}
              </p>
              {showOlder ? (
                <button type="button" data-debug-id="attention-deck-show-older" className="text-[12px] text-warning underline" onClick={() => onRangeChange('all')}>
                  Show {counts.older} older
                </button>
              ) : null}
            </div>
          )}

          {popover === 'snooze' && current ? (
            <div role="menu" data-debug-id="attention-snooze-menu" data-no-drag className="absolute bottom-2 left-1/2 z-10 w-56 -translate-x-1/2 rounded-[var(--radius-md)] border border-subtle bg-surface p-1 shadow-panel">
              {snoozePresets(new Date(now)).map((p) => (
                <button
                  key={p.id}
                  role="menuitem"
                  type="button"
                  data-debug-id={`attention-snooze-${p.id}`}
                  onClick={() => schedule(current, `Snoozed · ${p.label.toLowerCase()}`, (k) => snoozeCard(current.card_id, toHubTimestamp(p.until), k))}
                  className="block w-full rounded-[var(--radius-sm)] px-2 py-1.5 text-left text-[13px] text-primary hover:bg-surface-raised"
                >
                  {p.label}
                </button>
              ))}
            </div>
          ) : null}

          {popover === 'reviewer' && current?.kind === 'task' ? (
            <div role="menu" data-debug-id="attention-reviewer-menu" data-no-drag className="absolute bottom-2 left-1/2 z-10 max-h-64 w-72 -translate-x-1/2 overflow-y-auto rounded-[var(--radius-md)] border border-subtle bg-surface p-1 shadow-panel">
              <p className="px-2 py-1 text-[11px] uppercase tracking-wide text-faint">
                Hand the review to{reviewers.length > 0 ? (reviewers[0].source === 'fleet' ? ' · this chain\'s fleet' : ' · reviewer agents') : ''}
              </p>
              {reviewersLoading ? (
                <p data-debug-id="attention-reviewer-loading" className="flex items-center gap-2 px-2 py-1.5 text-[12px] text-muted">
                  <Spinner size="sm" label="Finding reviewers…" /> Finding reviewers…
                </p>
              ) : reviewersError ? (
                <p data-debug-id="attention-reviewer-error" className="px-2 py-1.5 text-[12px] text-danger">
                  Couldn't load agents.{' '}
                  <button type="button" className="underline" onClick={() => { fleetQuery.refetch(); agentsQuery.refetch(); }}>Retry</button>
                </p>
              ) : reviewers.length === 0 ? (
                <p data-debug-id="attention-reviewer-empty" className="px-2 py-1.5 text-[12px] text-muted">No reviewer agents set up for this chain.</p>
              ) : (
                reviewers.map((r) => (
                  <button
                    key={r.agentId}
                    role="menuitem"
                    type="button"
                    data-debug-id="attention-reviewer-option"
                    onClick={() => schedule(current, `Handed to ${r.name}`, (k) => assignReviewerAgent(current.action_refs, { agentId: r.agentId, displayName: r.name }, k))}
                    className="flex w-full items-center gap-2 rounded-[var(--radius-sm)] px-2 py-1.5 text-left text-[13px] text-primary hover:bg-surface-raised"
                  >
                    <Icon name="bot" size={14} />
                    <span className="truncate">{r.name}</span>
                  </button>
                ))
              )}
            </div>
          ) : null}
        </div>

        {/* Quick replies sit outside the scrolling card, just above the arrows, so a
            long message never pushes them out of view. Number keys 1-9 send them. */}
        {current && current.kind === 'message' && currentOptions.length > 0 && open ? (
          <div data-debug-id="attention-card-options" data-no-drag data-attention-options className="flex flex-wrap justify-center gap-2 px-4 pt-3" role="group" aria-label="Quick replies">
            {currentOptions.map((opt, i) => (
              <button
                key={`${i}:${opt}`}
                type="button"
                data-debug-id={`attention-card-option-${i}`}
                aria-keyshortcuts={i < 9 ? String(i + 1) : undefined}
                onClick={() => sendOption(current, i)}
                className="inline-flex items-center gap-1.5 rounded-full border border-warning-soft py-1 pl-1.5 pr-3 text-[12px] text-warning hover:bg-warning-soft"
              >
                {i < 9 ? <kbd className="grid h-4 min-w-4 place-items-center rounded-full bg-warning-soft px-1 text-[10px] font-semibold not-italic">{i + 1}</kbd> : null}
                <VaultText value={opt} />
              </button>
            ))}
          </div>
        ) : null}
        <div className="flex items-center justify-center gap-3 py-2 text-[12px] text-faint tabular-nums" data-debug-id="attention-deck-counter" data-attention-counter>
          {list.length > 0 ? (
            <>
              <button type="button" aria-label="Previous card" title="Previous card (←)" data-debug-id="attention-deck-prev" disabled={list.length < 2} onClick={() => go(-1)} className="grid h-8 w-8 place-items-center rounded-full border border-subtle text-muted hover:border-strong hover:text-primary disabled:opacity-40">
                <Icon name="chevron-left" size={16} />
              </button>
              <span className="min-w-[3.5rem] text-center">{safeIndex + 1} / {list.length}</span>
              <button type="button" aria-label="Next card" title="Next card (→)" data-debug-id="attention-deck-next" disabled={list.length < 2} onClick={() => go(1)} className="grid h-8 w-8 place-items-center rounded-full border border-subtle text-muted hover:border-strong hover:text-primary disabled:opacity-40">
                <Icon name="chevron-right" size={16} />
              </button>
            </>
          ) : null}
          {showOlder && list.length > 0 ? (
            <button type="button" data-debug-id="attention-deck-older" onClick={() => onRangeChange('all')} className="hover:text-primary">+{counts.older} older</button>
          ) : null}
        </div>
        {notice ? <p role="status" data-debug-id="attention-deck-notice" className="px-4 pb-1 text-center text-[12px] text-success">{notice}</p> : null}

        <nav aria-label="Card actions" data-debug-id="attention-deck-dock" data-attention-dock className="mx-4 mb-4 flex justify-around rounded-[var(--radius-lg)] border border-subtle bg-surface-raised px-1 py-1.5" style={{ visibility: current ? 'visible' : 'hidden' }}>
          {dock.map((d) => current && needsAgentStart(current) && d.debug === 'answer' ? (
            <StartAgentAction key={current.card_id} debugPrefix="attention" onStart={() => void agentStart.start(current)} {...agentStart.states[current.card_id]} />
          ) : (
            <button
              key={d.debug}
              type="button"
              data-debug-id={`attention-action-${d.debug}`}
              title={`${d.label} (${d.key.toUpperCase()})`}
              onClick={d.run}
              className="relative flex min-w-[56px] flex-col items-center gap-0.5 rounded-[var(--radius-md)] px-1 py-1 text-[11px] text-muted hover:bg-surface hover:text-primary"
            >
              <Icon name={d.icon} size={18} />
              <span className={d.tone === 'success' ? 'text-success' : d.tone === 'danger' ? 'text-danger' : undefined}>{d.label}</span>
              <span aria-hidden="true" className="absolute right-1 top-0.5 text-[9px] text-faint max-sm:hidden">{d.key.toUpperCase()}</span>
            </button>
          ))}
        </nav>
      </section>
    </div>,
    document.body,
  );
}

export default AttentionDeck;

