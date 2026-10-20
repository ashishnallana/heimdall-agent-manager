import { StartAgentAction, needsAgentStart, useStartAgent } from './StartAgentAction';
import { useCallback, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react';
import { useDispatch } from 'react-redux';
import { Icon, Menu } from '@ui';
import { heimdallApi } from '../../api/heimdallApi';
import { useGetAttentionQuery, type AttentionTaskItem } from '../../api/endpoints/attention';
import { useGetTaskChainFleetsQuery, useListAgentIdentitiesQuery } from '../../api/endpoints';
import { attentionScheduler, type ActionScheduler } from '../../services/attention/actionScheduler';
import { acceptCard, assignReviewerAgent, rejectCard, snoozeCard } from '../../services/attention/attentionActions';
import { snoozePresets, toHubTimestamp } from '../../services/attention/snoozePresets';
import { buildRouteHash, navigateTo } from '../../utils/appLocation';
import { ActionTaskCard } from './ActionTaskCard';
import { clampIndex, hideKey, reviewerCandidates } from './attentionModel';
import { TRAY_MODE_COPY, isBlockedItem, needYouLabel, trayItems, type TrayModeKind, type TrayScope } from './actionTrayModel';

const NO_ITEMS: AttentionTaskItem[] = [];

/**
 * The task items waiting on the user in one conversation (its chain, or the
 * agent instance when there is no chain), live: the hub's attention_changed
 * hint invalidates the Attention tag, so nothing polls. Cards with a pending or
 * settled attention action are left out at once.
 */
export function useActionTrayItems(scope: TrayScope, { skip = false, scheduler = attentionScheduler }: { skip?: boolean; scheduler?: ActionScheduler } = {}): AttentionTaskItem[] {
  const off = skip || (!scope.chainId && !scope.agentInstanceId);
  const query = useGetAttentionQuery({ since: 'all', kind: 'task' }, { skip: off });
  const snap = useSyncExternalStore(scheduler.subscribe, scheduler.getSnapshot, scheduler.getSnapshot);
  const items = off ? undefined : query.data?.items;
  return useMemo(
    () => (items ? trayItems(items, scope, snap.hidden) : NO_ITEMS),
    [items, scope.chainId, scope.agentInstanceId, snap.hidden], // eslint-disable-line react-hooks/exhaustive-deps
  );
}

/** Other views' lists refresh after an action; the tray itself waits for attention_changed. */
function useInvalidateTaskLists() {
  const dispatch = useDispatch();
  return useCallback(() => {
    dispatch(heimdallApi.util.invalidateTags([
      { type: 'Cards', id: 'LIST' },
      { type: 'Task', id: 'LIST' },
      { type: 'Chain', id: 'LIST' },
    ]) as any);
  }, [dispatch]);
}

/**
 * Sends the text a borrowed composer collected (REQ-AT-3), like the deck:
 * Answer clears the block through the card (`expected_block` pins the question
 * the user saw); Request changes rejects the review card with the reason (never
 * the task.review card op, which always approves). Immediate, not deferred: the
 * card leaves at once and comes back if the call fails.
 */
export function useSendTrayMode(scheduler: ActionScheduler = attentionScheduler) {
  const invalidate = useInvalidateTaskLists();
  return useCallback(async (item: AttentionTaskItem, kind: TrayModeKind, text: string): Promise<string> => {
    const key = hideKey(item);
    scheduler.settle(key);
    try {
      if (kind === 'answer') await acceptCard(item.card_id, false, { note: text, expected_block: item.details.block_id || undefined });
      else await rejectCard(item.card_id, false, { summary: text });
    } catch (err) {
      scheduler.unsettle(key);
      throw err;
    }
    invalidate();
    return TRAY_MODE_COPY[kind].sent;
  }, [scheduler, invalidate]);
}

type Panel = null | { kind: 'snooze' | 'delegate'; cardId: string };

const ACTION_BTN = 'inline-flex min-h-10 shrink-0 items-center justify-center gap-1.5 whitespace-nowrap rounded-full px-3.5 text-[14px] font-medium';
const ACTION_BTN_MOBILE = 'inline-flex min-h-10 min-w-0 flex-auto items-center justify-center whitespace-nowrap rounded-full px-3 text-[13px] font-medium';
const ACTION_ICON_BTN = 'grid h-10 w-10 shrink-0 place-items-center rounded-full text-muted hover:bg-neutral-soft hover:text-primary';

/**
 * The chat pane's action tray (REQ-AT-1..5): while this conversation has task
 * items waiting on the user, it takes the composer's place in the dock. One card
 * per page (swipe, or the ‹ i/n › pager). "Composer" switches back to the
 * composer, whose "<n> need you" pill returns here.
 *
 * Actions reuse the deck's services. Approve, Snooze and Delegate are deferred
 * through the app-level undo scheduler (the shell's Undo toast); Answer and
 * Request changes borrow the composer for their text (`onStartMode`); Open
 * routes to the task.
 */
export function ActionTray({
  items,
  mobile,
  onShowComposer,
  onStartMode,
  scheduler = attentionScheduler,
  nowMs,
}: {
  items: AttentionTaskItem[];
  mobile: boolean;
  onShowComposer: () => void;
  onStartMode: (kind: TrayModeKind, item: AttentionTaskItem) => void;
  scheduler?: ActionScheduler;
  nowMs?: number;
}) {
  const now = nowMs ?? Date.now();
  const invalidate = useInvalidateTaskLists();
  const agentStart = useStartAgent(invalidate);
  const [page, setPage] = useState(0);
  const [panel, setPanel] = useState<Panel>(null);
  const safePage = clampIndex(page, items.length);
  const scroller = useRef<HTMLDivElement>(null);

  // Stay on the card that was showing when the list changes (a card settled, a
  // new one arrived); if it left, its neighbour takes its place.
  const shownId = useRef<string | undefined>(undefined);
  useLayoutEffect(() => {
    const prev = shownId.current;
    if (!prev) return;
    const at = items.findIndex((i) => i.card_id === prev);
    if (at >= 0 && at !== safePage) setPage(at);
  }, [items]); // eslint-disable-line react-hooks/exhaustive-deps
  useLayoutEffect(() => { shownId.current = items[safePage]?.card_id; });

  // Keep the scroll position on the current page (pager, removed cards, resize).
  useLayoutEffect(() => {
    const el = scroller.current;
    if (!el || !el.clientWidth) return;
    const target = safePage * el.clientWidth;
    if (Math.abs(el.scrollLeft - target) > 2) el.scrollTo({ left: target });
  }, [safePage, items.length]);

  const onScroll = () => {
    const el = scroller.current;
    if (!el || !el.clientWidth) return;
    const next = clampIndex(Math.round(el.scrollLeft / el.clientWidth), items.length);
    if (next !== safePage) {
      setPage(next);
      setPanel(null);
    }
  };
  const go = (delta: number) => {
    const next = clampIndex(safePage + delta, items.length);
    scroller.current?.scrollTo({ left: next * (scroller.current?.clientWidth ?? 0), behavior: 'smooth' });
    setPage(next);
    setPanel(null);
  };

  const schedule = (item: AttentionTaskItem, label: string, send: (keepalive: boolean) => Promise<void>) => {
    setPanel(null);
    scheduler.schedule({ cardId: hideKey(item), label, run: async (keepalive) => { await send(keepalive); invalidate(); } });
  };

  const openTask = (item: AttentionTaskItem) => {
    navigateTo(buildRouteHash(`/chains/${encodeURIComponent(item.action_refs.chain_id)}/tasks/${encodeURIComponent(item.action_refs.task_id)}`, ''));
  };

  // Delegate picker: fetched on demand when it opens.
  const delegateItem = panel?.kind === 'delegate' ? items.find((i) => i.card_id === panel.cardId) : undefined;
  const reviewerChainId = delegateItem?.action_refs.chain_id || '';
  const fleetQuery = useGetTaskChainFleetsQuery({ chainId: reviewerChainId }, { skip: !reviewerChainId });
  const agentsQuery = useListAgentIdentitiesQuery({ limit: 200 }, { skip: !reviewerChainId });
  const reviewersLoading = !!reviewerChainId && !(fleetQuery.data && agentsQuery.data) && (fleetQuery.isFetching || agentsQuery.isFetching);
  const reviewersError = !reviewersLoading && (fleetQuery.isError || agentsQuery.isError);
  const reviewers = fleetQuery.data && agentsQuery.data ? reviewerCandidates(fleetQuery.data, agentsQuery.data.agents || []) : [];

  if (items.length === 0) return null;

  const renderFooter = (item: AttentionTaskItem) => {
    if (panel?.cardId === item.card_id) {
      const isDelegate = panel.kind === 'delegate';
      return (
        <div role="menu" data-debug-id={isDelegate ? 'action-tray-delegate-picker' : 'action-tray-snooze-menu'} className="rounded-[var(--radius-lg)] border border-subtle bg-surface p-1 shadow-panel">
          <div className="flex items-center justify-between px-2 pb-1 pt-0.5">
            <p className="text-[12px] text-muted">{isDelegate ? 'Hand the review to an agent' : 'Snooze until'}</p>
            <button type="button" aria-label="Close" data-debug-id="action-tray-panel-close" onClick={() => setPanel(null)} className="grid h-8 w-8 place-items-center rounded-full text-muted hover:text-primary">
              <Icon name="close" size={14} />
            </button>
          </div>
          {isDelegate ? (
            reviewersLoading ? <p className="px-2 py-2 text-[13px] text-muted">Loading agents…</p>
            : reviewersError ? <p role="alert" className="px-2 py-2 text-[13px] text-danger">Could not load agents.</p>
            : reviewers.length === 0 ? <p className="px-2 py-2 text-[13px] text-muted">No agent in this chain's fleet can review.</p>
            : (
              <div className="grid max-h-48 grid-cols-2 gap-0.5 overflow-y-auto">
                {reviewers.map((r) => (
                  <button
                    key={r.agentId}
                    type="button"
                    role="menuitem"
                    data-debug-id={`action-tray-delegate-${r.agentId}`}
                    onClick={() => schedule(item, `Handed to ${r.name}`, (k) => assignReviewerAgent(item.action_refs, { agentId: r.agentId, displayName: r.name }, k))}
                    className="flex min-h-11 w-full items-center gap-2.5 rounded-[var(--radius-sm)] px-2 py-1.5 text-left hover:bg-surface-raised"
                  >
                    <span className="grid h-7 w-7 shrink-0 place-items-center rounded-full bg-surface-raised text-muted">
                      <Icon name={r.source === 'reviewer_template' ? 'sparkle' : 'bot'} size={15} />
                    </span>
                    <span className="min-w-0 flex-1">
                      <span className="block truncate text-[14px] text-primary">{r.name}</span>
                      <span className="hidden truncate text-[12px] text-faint sm:block">{r.source === 'fleet' ? 'In this chain' : 'Reviewer'}</span>
                    </span>
                  </button>
                ))}
              </div>
            )
          ) : (
            <div className="grid gap-0.5 sm:grid-cols-2">
              {snoozePresets(new Date(now)).map((p) => (
                <button
                  key={p.id}
                  type="button"
                  role="menuitem"
                  data-debug-id={`action-tray-snooze-${p.id}`}
                  onClick={() => schedule(item, `Snoozed · ${p.label.toLowerCase()}`, (k) => snoozeCard(item.card_id, toHubTimestamp(p.until), k))}
                  className="flex min-h-11 w-full items-center gap-2 rounded-[var(--radius-sm)] px-2 text-left text-[14px] text-primary hover:bg-surface-raised"
                >
                  <Icon name="clock" size={15} className="text-muted" />
                  {p.label}
                </button>
              ))}
            </div>
          )}
        </div>
      );
    }
    if (needsAgentStart(item)) return <StartAgentAction debugPrefix="action-tray" onStart={() => void agentStart.start(item)} {...agentStart.states[item.card_id]} />;
    return (
      <ActionRow
        item={item}
        mobile={mobile}
        onAnswer={() => { setPanel(null); onStartMode('answer', item); }}
        onApprove={() => schedule(item, 'Approved', (k) => acceptCard(item.card_id, k))}
        onRequestChanges={() => { setPanel(null); onStartMode('changes', item); }}
        onDelegate={() => setPanel({ kind: 'delegate', cardId: item.card_id })}
        onSnooze={() => setPanel({ kind: 'snooze', cardId: item.card_id })}
        onOpen={() => openTask(item)}
      />
    );
  };

  return (
    <section
      aria-label="Waiting on you"
      data-debug-id="action-tray"
      className={`ui-frost-card relative isolate flex flex-col border ${mobile ? 'max-h-[60svh] rounded-[24px] p-3' : 'max-h-[min(64vh,620px)] rounded-[22px] p-4'}`}
    >
      <div aria-hidden="true" className="ui-frost-gradient -z-10">
        <span />
        <span />
        <span />
      </div>
      <header className="mb-2 flex shrink-0 items-center gap-2">
        <span aria-hidden="true" className="h-2 w-2 shrink-0 rounded-full bg-warning" />
        <h2 data-debug-id="action-tray-title" className="min-w-0 truncate text-[14px] font-semibold text-primary">
          {needYouLabel(items.length)}
        </h2>
        {items.length > 1 ? (
          <div data-debug-id="action-tray-pager" className="flex shrink-0 items-center text-[13px] tabular-nums text-muted">
            <button type="button" aria-label="Previous task" data-debug-id="action-tray-prev" disabled={safePage === 0} onClick={() => go(-1)} className="grid h-9 w-9 place-items-center rounded-full hover:text-primary disabled:opacity-30">
              <Icon name="chevron-left" size={18} />
            </button>
            <span data-debug-id="action-tray-page">{safePage + 1} / {items.length}</span>
            <button type="button" aria-label="Next task" data-debug-id="action-tray-next" disabled={safePage >= items.length - 1} onClick={() => go(1)} className="grid h-9 w-9 place-items-center rounded-full hover:text-primary disabled:opacity-30">
              <Icon name="chevron-right" size={18} />
            </button>
          </div>
        ) : null}
        <button
          type="button"
          data-debug-id="action-tray-show-composer"
          onClick={onShowComposer}
          className="ml-auto inline-flex min-h-9 shrink-0 items-center gap-1.5 rounded-full border border-subtle bg-surface-raised px-3 text-[13px] font-medium text-primary hover:bg-neutral-soft"
        >
          <Icon name="pencil" size={13} />
          Composer
        </button>
      </header>
      <div
        ref={scroller}
        onScroll={onScroll}
        data-debug-id="action-tray-cards"
        className="flex min-h-0 flex-1 snap-x snap-mandatory overflow-x-auto overscroll-x-contain [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
      >
        {items.map((item, i) => (
          <div key={item.card_id} className="flex w-full shrink-0 snap-start snap-always flex-col px-0.5">
            <div className={`flex min-h-0 flex-1 flex-col rounded-[var(--radius-lg)] border border-subtle bg-surface-raised ${mobile ? 'p-3.5' : 'p-5'}`}>
              <ActionTaskCard item={item} mobile={mobile} active={i === safePage} now={now} footer={renderFooter(item)} />
            </div>
          </div>
        ))}
      </div>
    </section>
  );
}

/**
 * One compact row. Blocked: Answer (in the composer), more (Snooze, Open).
 * Review: Approve, Request changes (reason in the composer), Delegate, more.
 * Delegating a blocked question has no API yet, so blocked cards offer none.
 */
function ActionRow({
  item,
  mobile,
  onAnswer,
  onApprove,
  onRequestChanges,
  onDelegate,
  onSnooze,
  onOpen,
}: {
  item: AttentionTaskItem;
  mobile: boolean;
  onAnswer: () => void;
  onApprove: () => void;
  onRequestChanges: () => void;
  onDelegate: () => void;
  onSnooze: () => void;
  onOpen: () => void;
}) {
  const more = <OverflowMenu onSnooze={onSnooze} onOpen={onOpen} />;
  if (isBlockedItem(item)) {
    return (
      <div data-debug-id="action-tray-actions-blocked" className="flex items-center justify-end gap-1">
        <button type="button" data-debug-id="action-tray-answer" onClick={onAnswer} className={`${ACTION_BTN} bg-accent text-accent-fg hover:brightness-110`}>
          <Icon name="chat" size={16} />
          Answer
        </button>
        {more}
      </div>
    );
  }
  return (
    <div data-debug-id="action-tray-actions-review" className={`flex items-center ${mobile ? 'gap-1.5' : 'gap-2'}`}>
      <button
        type="button"
        data-debug-id="action-tray-approve"
        onClick={onApprove}
        className={`${mobile ? ACTION_BTN_MOBILE : ACTION_BTN} border border-success/30 bg-success-soft font-semibold text-success hover:brightness-110`}
      >
        {mobile ? null : <Icon name="check" size={16} />}
        Approve
      </button>
      <button
        type="button"
        data-debug-id="action-tray-request-changes"
        onClick={onRequestChanges}
        className={`${mobile ? ACTION_BTN_MOBILE : ACTION_BTN} border border-subtle text-primary hover:bg-neutral-soft`}
      >
        {mobile ? null : <Icon name="pencil" size={16} />}
        Request changes
      </button>
      <div className="ml-auto flex shrink-0 items-center">
        <button
          type="button"
          data-debug-id="action-tray-delegate"
          aria-label="Delegate the review to an agent"
          title="Delegate the review to an agent"
          onClick={onDelegate}
          className={mobile ? ACTION_ICON_BTN : `${ACTION_BTN} text-muted hover:bg-neutral-soft hover:text-primary`}
        >
          <Icon name="bot" size={18} />
          {mobile ? null : <span>Delegate</span>}
        </button>
        {more}
      </div>
    </div>
  );
}

/** The actions that rarely matter: Snooze, Open. */
function OverflowMenu({ onSnooze, onOpen }: { onSnooze: () => void; onOpen: () => void }) {
  const [open, setOpen] = useState(false);
  return (
    <Menu
      side="top"
      align="end"
      label="More actions"
      open={open}
      onOpenChange={setOpen}
      trigger={
        <button type="button" aria-label="More actions" data-debug-id="action-tray-more" className={ACTION_ICON_BTN}>
          <Icon name="more-horizontal" size={20} />
        </button>
      }
    >
      <Menu.Item data-debug-id="action-tray-snooze" onClick={() => { setOpen(false); onSnooze(); }}>
        <Icon name="clock" size={16} />
        <span>Snooze…</span>
      </Menu.Item>
      <Menu.Item data-debug-id="action-tray-open" onClick={() => { setOpen(false); onOpen(); }}>
        <Icon name="arrow-right" size={16} />
        <span>Open task</span>
      </Menu.Item>
    </Menu>
  );
}

/** "3 need you": rides on the composer card's top edge and switches back to the tray. */
export function NeedYouPill({ count, onClick }: { count: number; onClick: () => void }) {
  return (
    <button
      type="button"
      data-debug-id="action-tray-need-you-pill"
      onClick={onClick}
      className="inline-flex min-h-9 max-w-full items-center gap-1.5 rounded-full border border-warning-soft bg-surface-raised px-3 text-[13px] font-semibold text-warning shadow-panel hover:bg-warning-soft"
    >
      <span aria-hidden="true" className="h-2 w-2 shrink-0 rounded-full bg-warning" />
      <span className="shrink-0 tabular-nums">{needYouLabel(count)}</span>
    </button>
  );
}

