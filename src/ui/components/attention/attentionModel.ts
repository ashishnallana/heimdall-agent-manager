// Pure view-model helpers for the attention deck (no React; unit-tested).
import type { AttentionCounts, AttentionItem, AttentionKind } from '../../api/endpoints/attention';

export type DeckTab = AttentionKind;

export const DECK_TABS: ReadonlyArray<{ id: DeckTab; label: string }> = [
  { id: 'message', label: 'Messages' },
  { id: 'task', label: 'Tasks' },
];

/** Items of a tab the deck should show: not hidden by a pending/settled action. */
export function visibleItems(items: readonly AttentionItem[], tab: DeckTab, hidden: ReadonlySet<string>): AttentionItem[] {
  return items.filter((item) => item.kind === tab && !hidden.has(item.card_id));
}

/** Per-tab counts: the server's exact counts minus cards hidden locally. */
export function tabCounts(counts: AttentionCounts, items: readonly AttentionItem[], hidden: ReadonlySet<string>): Record<DeckTab, number> {
  const hiddenOf = (kind: DeckTab) => items.filter((item) => item.kind === kind && hidden.has(item.card_id)).length;
  return {
    message: Math.max(0, counts.message - hiddenOf('message')),
    task: Math.max(0, counts.task - hiddenOf('task')),
  };
}

/** The tab to open on: the first one with something in it. */
export function defaultTab(counts: Record<DeckTab, number>): DeckTab {
  return counts.message > 0 || counts.task === 0 ? 'message' : 'task';
}

export function clampIndex(index: number, length: number): number {
  if (length <= 0) return 0;
  return Math.min(Math.max(index, 0), length - 1);
}

/** Wraps around, like the mock. */
export function stepIndex(index: number, delta: number, length: number): number {
  if (length <= 0) return 0;
  return (((index + delta) % length) + length) % length;
}

/** "3 min", "2h", "1 day", "5 days". */
export function formatAge(sinceIso: string, now: number): string {
  const since = Date.parse(sinceIso);
  if (!Number.isFinite(since)) return '';
  const minutes = Math.max(0, Math.floor((now - since) / 60000));
  if (minutes < 1) return 'just now';
  if (minutes < 60) return `${minutes} min`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h`;
  const days = Math.floor(hours / 24);
  return days === 1 ? '1 day' : `${days} days`;
}

/** Human reason line, e.g. "Waiting on your review · 2h". Never shows ids. */
export function reasonLine(item: AttentionItem, now: number): string {
  const age = formatAge(item.attention_since, now);
  const base = item.kind === 'task' ? 'Waiting on your review' : 'Waiting on your reply';
  return age ? `${base} · ${age}` : base;
}

export function urgencyClass(urgency: AttentionItem['urgency']): string {
  if (urgency === 'error') return 'text-danger';
  if (urgency === 'warn') return 'text-warning';
  return 'text-info';
}

export const PRIORITY_LABELS: Record<string, string> = { p0: 'Urgent priority', p1: 'High priority', p2: 'Normal priority' };

/** A drag/swipe this far (px) commits a card change; less snaps back. */
export const SWIPE_COMMIT_PX = 90;

export function swipeDelta(dx: number): -1 | 0 | 1 {
  if (dx <= -SWIPE_COMMIT_PX) return 1;
  if (dx >= SWIPE_COMMIT_PX) return -1;
  return 0;
}
