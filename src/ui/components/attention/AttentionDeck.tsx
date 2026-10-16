import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react';
import { createPortal } from 'react-dom';
import { useDispatch } from 'react-redux';
import { Icon, type IconName } from '@ui';
import { heimdallApi } from '../../api/heimdallApi';
import {
  ATTENTION_RANGES,
  useGetAttentionQuery,
  type AttentionItem,
  type AttentionMessageItem,
  type AttentionRange,
  type AttentionTaskItem,
} from '../../api/endpoints/attention';
import {
  useAddTaskCommentMutation,
  useListAgentIdentitiesQuery,
  useMarkConversationReadMutation,
  useSendConversationMessageMutation,
  useVoteTaskMutation,
} from '../../api/endpoints';
import { attentionScheduler, type ActionScheduler } from '../../services/attention/actionScheduler';
import { acceptCard, assignReviewerAgent, cancelTask, markConversationRead, snoozeCard } from '../../services/attention/attentionActions';
import { ATTENTION_RANGE_LABELS } from '../../services/attention/attentionPrefs';
import { snoozePresets, toHubTimestamp } from '../../services/attention/snoozePresets';
import { appendArtifactLinks } from '../../utils/artifactUpload';
import { buildRouteHash, navigateTo } from '../../utils/appLocation';
import { AttentionCardBody } from './AttentionCardBody';
import { AttentionComposer, type ComposerSubmit } from './AttentionComposer';
import { DECK_TABS, clampIndex, defaultTab, stepIndex, swipeDelta, tabCounts, visibleItems, type DeckTab } from './attentionModel';

type Popover = null | 'snooze' | 'reviewer';
type Composer = null | 'reply' | 'comment';

const SLIDE_CSS = `
@keyframes attention-in-right { from { transform: translateX(40%); opacity: 0 } to { transform: none; opacity: 1 } }
@keyframes attention-in-left { from { transform: translateX(-40%); opacity: 0 } to { transform: none; opacity: 1 } }
@media (prefers-reduced-motion: reduce) { [data-attention-slide] { animation: none !important } }
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
  const query = useGetAttentionQuery({ since: range }, { skip: !open });
  const snap = useSyncExternalStore(scheduler.subscribe, scheduler.getSnapshot, scheduler.getSnapshot);
  const items = query.data?.items ?? [];
  const counts = query.data?.counts ?? { total: 0, older: 0, message: 0, task: 0 };
  const perTab = tabCounts(counts, items, snap.hidden);

  const [tab, setTab] = useState<DeckTab>('message');
  const [index, setIndex] = useState(0);
  const [slide, setSlide] = useState<'left' | 'right' | null>(null);
  const [popover, setPopover] = useState<Popover>(null);
  const [composer, setComposer] = useState<Composer>(null);
  const [notice, setNotice] = useState('');
  const [dragX, setDragX] = useState(0);
  const drag = useRef<{ x: number; id: number } | null>(null);
  const tabChosen = useRef(false);
  const now = nowMs ?? Date.now();

  // Open on the first non-empty tab, once per opening.
  useEffect(() => {
    if (!open) {
      tabChosen.current = false;
      setPopover(null);
      setComposer(null);
      return;
    }
    if (!tabChosen.current && query.data) {
      tabChosen.current = true;
      setTab(defaultTab(perTab));
      setIndex(0);
    }
  }, [open, query.data]); // eslint-disable-line react-hooks/exhaustive-deps

  // Forget locally-settled cards once the server stops returning them.
  useEffect(() => {
    if (query.data) scheduler.prune(items.map((i) => i.card_id));
  }, [query.data, scheduler]); // eslint-disable-line react-hooks/exhaustive-deps

  const list = useMemo(() => visibleItems(items, tab, snap.hidden), [items, tab, snap.hidden]);
  const safeIndex = clampIndex(index, list.length);
  const current: AttentionItem | undefined = list[safeIndex];

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

  const invalidate = useCallback(() => {
    dispatch(heimdallApi.util.invalidateTags([
      { type: 'Attention', id: 'ALL' },
      { type: 'Cards', id: 'LIST' },
      { type: 'Task', id: 'LIST' },
      { type: 'Chain', id: 'LIST' },
    ]) as any);
  }, [dispatch]);

  const schedule = (item: AttentionItem, label: string, send: (keepalive: boolean) => Promise<void>) => {
    scheduler.schedule({ cardId: item.card_id, label, run: async (keepalive) => { await send(keepalive); invalidate(); } });
    setSlide('right');
    resetCardUi();
  };

  // Immediate (encrypting) actions.
  const [addComment] = useAddTaskCommentMutation();
  const [voteTask] = useVoteTaskMutation();
  const [sendMessage] = useSendConversationMessageMutation();
  const [markRead] = useMarkConversationReadMutation();
  const agentsQuery = useListAgentIdentitiesQuery(undefined, { skip: !open || popover !== 'reviewer' });

  const noticeTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(() => () => { if (noticeTimer.current) clearTimeout(noticeTimer.current); }, []);
  const say = (text: string) => {
    setNotice(text);
    if (noticeTimer.current) clearTimeout(noticeTimer.current);
    noticeTimer.current = setTimeout(() => setNotice(''), 3500);
  };

  const replyAndRead = async (item: AttentionMessageItem, body: string, artifactIds: string[] = []) => {
    const conversationId = item.action_refs.conversation_id;
    scheduler.settle(item.card_id);
    try {
      await (sendMessage({ conversationId, body, artifactIds }) as any).unwrap();
      await (markRead({ conversationId }) as any).unwrap();
      invalidate();
      say(`Reply sent to ${item.context.agent_name || 'the agent'}`);
    } catch (err: any) {
      scheduler.unsettle(item.card_id);
      throw err;
    }
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
      scheduler.settle(item.card_id);
      try {
        await (voteTask({ chainId, taskId, result: 'ngtm', comment: body }) as any).unwrap();
      } catch (err) {
        scheduler.unsettle(item.card_id);
        throw err;
      }
      invalidate();
      say('Changes requested');
    } else {
      await (addComment({ chainId, taskId, body }) as any).unwrap();
      invalidate();
      say('Comment posted');
    }
    setComposer(null);
  };

  const openSource = (item: AttentionItem) => {
    const path = item.kind === 'task'
      ? `/chains/${encodeURIComponent(item.action_refs.chain_id)}/tasks/${encodeURIComponent(item.action_refs.task_id)}`
      : `/conversations/${encodeURIComponent(item.action_refs.agent_instance_id)}`;
    navigateTo(buildRouteHash(path, ''));
    onClose();
  };

  type DockAction = { key: string; label: string; icon: IconName; tone?: 'success' | 'danger'; run: () => void; debug: string };
  const dock: DockAction[] = !current ? [] : current.kind === 'task' ? [
    { key: 'a', label: 'Approve', icon: 'check', tone: 'success', debug: 'approve', run: () => schedule(current, 'Approved', (k) => acceptCard(current.card_id, k)) },
    { key: 'c', label: 'Comment', icon: 'chat', debug: 'comment', run: () => { setPopover(null); setComposer(composer === 'comment' ? null : 'comment'); } },
    { key: 'r', label: 'Reviewer', icon: 'bot', debug: 'reviewer', run: () => { setComposer(null); setPopover(popover === 'reviewer' ? null : 'reviewer'); } },
    { key: 's', label: 'Snooze', icon: 'clock', debug: 'snooze', run: () => { setComposer(null); setPopover(popover === 'snooze' ? null : 'snooze'); } },
    { key: 'd', label: 'Discard', icon: 'trash', tone: 'danger', debug: 'discard', run: () => schedule(current, 'Task discarded', (k) => cancelTask((current as AttentionTaskItem).action_refs, k)) },
    { key: 'o', label: 'Open', icon: 'arrow-right', debug: 'open', run: () => openSource(current) },
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
        return;
      }
      if (isTyping(e.target) || e.metaKey || e.ctrlKey || e.altKey) return;
      if (e.key === 'ArrowRight') { go(1); e.preventDefault(); return; }
      if (e.key === 'ArrowLeft') { go(-1); e.preventDefault(); return; }
      const hit = dock.find((d) => d.key === e.key.toLowerCase());
      if (hit) { e.preventDefault(); hit.run(); }
    };
    window.addEventListener('keydown', onKey, true);
    return () => window.removeEventListener('keydown', onKey, true);
  });

  if (!open || typeof document === 'undefined') return null;

  const onPointerDown = (e: React.PointerEvent) => {
    if ((e.target as HTMLElement).closest('button, a, textarea, input, [data-no-drag]')) return;
    drag.current = { x: e.clientX, id: e.pointerId };
  };
  const onPointerMove = (e: React.PointerEvent) => {
    if (drag.current && drag.current.id === e.pointerId) setDragX(e.clientX - drag.current.x);
  };
  const onPointerUp = () => {
    if (!drag.current) return;
    const delta = swipeDelta(dragX);
    drag.current = null;
    setDragX(0);
    if (delta !== 0) go(delta);
  };

  const showOlder = range !== 'all' && counts.older > 0;

  return createPortal(
    <div data-debug-id="attention-deck-backdrop" className="fixed inset-0 z-modal flex items-end justify-center bg-backdrop" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <style>{SLIDE_CSS}</style>
      <section
        role="dialog"
        aria-modal="true"
        aria-label="What needs you"
        data-debug-id="attention-deck"
        className="relative mb-[var(--ui-bottom-chrome,32px)] flex h-[min(680px,calc(100%-48px))] w-full max-w-[620px] flex-col overflow-hidden rounded-t-[var(--radius-lg)] border border-subtle bg-surface shadow-panel max-sm:mb-0 max-sm:h-full max-sm:rounded-none"
      >
        <header className="flex items-start gap-3 px-4 pt-4">
          <div className="min-w-0">
            <h2 className="text-[18px] font-semibold text-primary">What needs you</h2>
            <p className="text-[12px] text-muted">Questions from agents and tasks waiting on your review, across all chains.</p>
          </div>
          <button type="button" data-debug-id="attention-deck-close" aria-label="Close" onClick={onClose} className="ml-auto rounded-full border border-subtle p-1.5 text-muted hover:text-primary">
            <Icon name="close" size={14} />
          </button>
        </header>

        <div className="flex flex-wrap items-center gap-2 px-4 py-3">
          <div role="tablist" aria-label="Kinds" className="flex gap-1">
            {DECK_TABS.map((t) => (
              <button
                key={t.id}
                role="tab"
                type="button"
                aria-selected={tab === t.id}
                data-debug-id={`attention-deck-tab-${t.id}`}
                onClick={() => { setTab(t.id); setIndex(0); resetCardUi(); }}
                className={`rounded-full border px-3 py-1 text-[12px] ${tab === t.id ? 'border-strong bg-surface-raised text-primary' : 'border-subtle text-muted hover:text-primary'}`}
              >
                {t.label}
                <span className={`ml-1.5 tabular-nums ${tab === t.id ? 'text-warning' : 'text-faint'}`}>{perTab[t.id]}</span>
              </button>
            ))}
          </div>
          <div role="group" aria-label="Time range" data-debug-id="attention-deck-range" className="ml-auto flex rounded-[var(--radius-md)] border border-subtle p-0.5">
            {ATTENTION_RANGES.map((r) => (
              <button
                key={r}
                type="button"
                aria-pressed={range === r}
                data-debug-id={`attention-deck-range-${r}`}
                onClick={() => { onRangeChange(r); setIndex(0); }}
                className={`rounded-[var(--radius-sm)] px-2 py-0.5 text-[11px] ${range === r ? 'bg-surface-raised text-primary' : 'text-muted hover:text-primary'}`}
              >
                {ATTENTION_RANGE_LABELS[r]}
              </button>
            ))}
          </div>
        </div>

        <div className="relative min-h-0 flex-1 px-4" onPointerDown={onPointerDown} onPointerMove={onPointerMove} onPointerUp={onPointerUp} onPointerCancel={onPointerUp}>
          {query.isLoading ? (
            <p data-debug-id="attention-deck-loading" className="py-10 text-center text-[13px] text-muted">Loading…</p>
          ) : query.isError ? (
            <div data-debug-id="attention-deck-error" className="py-10 text-center text-[13px] text-danger">
              Could not load what needs you. <button type="button" className="underline" onClick={() => query.refetch()}>Retry</button>
            </div>
          ) : current ? (
            <div
              key={current.card_id}
              data-attention-slide
              data-debug-id="attention-deck-card"
              className="h-full cursor-grab touch-pan-y select-none rounded-[var(--radius-lg)] border border-subtle bg-surface-raised p-4 active:cursor-grabbing"
              style={{
                transform: dragX ? `translateX(${dragX}px) rotate(${dragX / 40}deg)` : undefined,
                transition: dragX ? 'none' : 'transform 180ms ease',
                animation: slide && !dragX ? `attention-in-${slide} 200ms ease-out` : undefined,
              }}
              onAnimationEnd={() => setSlide(null)}
            >
              <AttentionCardBody item={current} now={now}>
                {current.kind === 'message' && current.details.options.length > 0 ? (
                  <div data-debug-id="attention-card-options" className="mt-3 flex flex-wrap gap-2" data-no-drag>
                    {current.details.options.map((opt, i) => (
                      <button
                        key={`${i}:${opt}`}
                        type="button"
                        data-debug-id={`attention-card-option-${i}`}
                        onClick={() => void replyAndRead(current, opt).catch((err) => say(`Reply failed: ${err?.message || 'error'}`))}
                        className="rounded-full border border-warning-soft px-3 py-1 text-[12px] text-warning hover:bg-warning-soft"
                      >
                        {opt}
                      </button>
                    ))}
                  </div>
                ) : null}
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
                {composer === 'comment' && current.kind === 'task' ? (
                  <AttentionComposer
                    debugId="attention-comment"
                    placeholder="Write a comment…"
                    originKind="task_comment"
                    originRef={`${current.action_refs.chain_id}:${current.action_refs.task_id}`}
                    submitLabel="Comment"
                    secondaryLabel="Request changes"
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
                {perTab.message + perTab.task > 0 ? 'Nothing here. The other tab still has items.' : 'Nothing in this time range needs you.'}
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
              <p className="px-2 py-1 text-[11px] uppercase tracking-wide text-faint">Hand the review to</p>
              {agentsQuery.isLoading ? <p className="px-2 py-1.5 text-[12px] text-muted">Loading agents…</p> : null}
              {(agentsQuery.data?.agents || []).filter((a: any) => (a?.agent_id || a?.id) && (a?.state ?? 'active') !== 'archived').map((a: any) => {
                const agentId = String(a.agent_id || a.id);
                const name = String(a.name || a.display_name || a.slug || 'Agent');
                return (
                  <button
                    key={agentId}
                    role="menuitem"
                    type="button"
                    data-debug-id={`attention-reviewer-${a.slug || 'agent'}`}
                    onClick={() => schedule(current, `Handed to ${name}`, (k) => assignReviewerAgent(current.action_refs, { agentId, displayName: name }, k))}
                    className="flex w-full items-center gap-2 rounded-[var(--radius-sm)] px-2 py-1.5 text-left text-[13px] text-primary hover:bg-surface-raised"
                  >
                    <Icon name="bot" size={14} />
                    <span className="truncate">{name}</span>
                  </button>
                );
              })}
            </div>
          ) : null}
        </div>

        <div className="flex items-center justify-center gap-3 py-2 text-[12px] text-faint tabular-nums" data-debug-id="attention-deck-counter">
          {list.length > 0 ? (
            <>
              <button type="button" aria-label="Previous" data-debug-id="attention-deck-prev" disabled={list.length < 2} onClick={() => go(-1)} className="px-2 hover:text-primary disabled:opacity-40">‹</button>
              <span>{safeIndex + 1} / {list.length}</span>
              <button type="button" aria-label="Next" data-debug-id="attention-deck-next" disabled={list.length < 2} onClick={() => go(1)} className="px-2 hover:text-primary disabled:opacity-40">›</button>
            </>
          ) : null}
          {showOlder && list.length > 0 ? (
            <button type="button" data-debug-id="attention-deck-older" onClick={() => onRangeChange('all')} className="hover:text-primary">+{counts.older} older</button>
          ) : null}
        </div>
        {notice ? <p role="status" data-debug-id="attention-deck-notice" className="px-4 pb-1 text-center text-[12px] text-success">{notice}</p> : null}

        <nav aria-label="Card actions" data-debug-id="attention-deck-dock" className="mx-4 mb-4 flex justify-around rounded-[var(--radius-lg)] border border-subtle bg-surface-raised px-1 py-1.5" style={{ visibility: current ? 'visible' : 'hidden' }}>
          {dock.map((d) => (
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

