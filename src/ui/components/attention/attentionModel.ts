// Pure view-model helpers for the attention deck (no React; unit-tested).
import type { AttentionCounts, AttentionItem, AttentionKind } from '../../api/endpoints/attention';

/** Messages and Tasks hold live cards; Snoozed holds cards whose snooze is running. */
export type DeckTab = AttentionKind | 'snoozed';

export const DECK_TABS: ReadonlyArray<{ id: DeckTab; label: string }> = [
  { id: 'message', label: 'Messages' },
  { id: 'task', label: 'Tasks' },
  { id: 'snoozed', label: 'Snoozed' },
];

/**
 * The key a card is hidden under while an action on it is pending/settled. It
 * names the card's current state, so a settled key is pruned as soon as the
 * server returns the card in any other state -- e.g. snoozing a live card, or
 * re-snoozing a snoozed one to a new time, brings it back in the Snoozed tab.
 */
export function hideKey(item: AttentionItem): string {
  return item.snoozed ? `${item.card_id}#snoozed@${item.snooze_until}` : item.card_id;
}

function inTab(item: AttentionItem, tab: DeckTab): boolean {
  return tab === 'snoozed' ? item.snoozed : !item.snoozed && item.kind === tab;
}

/** Items of a tab the deck should show: not hidden by a pending/settled action. */
export function visibleItems(items: readonly AttentionItem[], tab: DeckTab, hidden: ReadonlySet<string>): AttentionItem[] {
  return items.filter((item) => inTab(item, tab) && !hidden.has(hideKey(item)));
}

/** Per-tab counts: the server's exact counts minus cards hidden locally. */
export function tabCounts(counts: AttentionCounts, items: readonly AttentionItem[], hidden: ReadonlySet<string>): Record<DeckTab, number> {
  const hiddenOf = (tab: DeckTab) => items.filter((item) => inTab(item, tab) && hidden.has(hideKey(item))).length;
  return {
    message: Math.max(0, counts.message - hiddenOf('message')),
    task: Math.max(0, counts.task - hiddenOf('task')),
    snoozed: Math.max(0, counts.snoozed - hiddenOf('snoozed')),
  };
}

/** The tab to open on: the first live tab with something in it (never Snoozed). */
export function defaultTab(counts: Record<DeckTab, number>): DeckTab {
  return counts.message > 0 || counts.task === 0 ? 'message' : 'task';
}

/**
 * Where the deck goes when the tab being worked through runs out: the other live
 * tab if it has cards, never Snoozed. null = stay (nothing else to work on).
 */
export function nextLiveTab(current: DeckTab, counts: Record<DeckTab, number>): DeckTab | null {
  const other: DeckTab = current === 'message' ? 'task' : 'message';
  if (current !== 'snoozed' && counts[other] > 0) return other;
  if (current === 'snoozed') return counts.message > 0 ? 'message' : counts.task > 0 ? 'task' : null;
  return null;
}

/** "Tue 09:00", "today 18:30", "tomorrow 09:00" (local time). */
export function formatWake(iso: string, now: number): string {
  const at = new Date(iso);
  if (!iso || Number.isNaN(at.getTime())) return '';
  const hm = `${String(at.getHours()).padStart(2, '0')}:${String(at.getMinutes()).padStart(2, '0')}`;
  const day = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const diffDays = Math.round((day(at) - day(new Date(now))) / 86400000);
  if (diffDays === 0) return `today ${hm}`;
  if (diffDays === 1) return `tomorrow ${hm}`;
  if (diffDays > 1 && diffDays < 7) return `${at.toLocaleDateString('en-US', { weekday: 'short' })} ${hm}`;
  return `${at.toLocaleDateString('en-US', { month: 'short', day: 'numeric' })} ${hm}`;
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
  if (item.snoozed) {
    const wake = formatWake(item.snooze_until, now);
    return wake ? `Snoozed until ${wake}` : 'Snoozed';
  }
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
export const SWIPE_COMMIT_PX = 60;
/** ...or a quick flick: at least this far, released within FLICK_MS. */
export const FLICK_PX = 25;
export const FLICK_MS = 250;

/** Left swipe = next card, right swipe = previous; navigation only, never an action. */
export function swipeDelta(dx: number, ms = Infinity): -1 | 0 | 1 {
  const far = Math.abs(dx) >= SWIPE_COMMIT_PX || (Math.abs(dx) >= FLICK_PX && ms <= FLICK_MS);
  if (!far) return 0;
  return dx < 0 ? 1 : -1;
}

/** Built-in reviewer template id (hub domain.TEMPLATE_REVIEWER_ID). */
export const REVIEWER_TEMPLATE_ID = 'tmpl_reviewer';

export type ReviewerCandidate = { agentId: string; name: string; source: 'fleet' | 'reviewer_template' };

/**
 * Who a task's review can be handed to: the active agents in the task chain's
 * fleet; when the fleet has none, every active agent made from the reviewer
 * template. Ids are for the action only -- the menu renders names.
 */
export function reviewerCandidates(fleet: ReadonlyArray<{ agent_id?: string; agentId?: string }>, agents: readonly any[]): ReviewerCandidate[] {
  const active = agents.filter((a) => (a?.agent_id || a?.id) && (a?.state ?? 'active') !== 'archived');
  const idOf = (a: any) => String(a.agent_id || a.id);
  const nameOf = (a: any) => String(a.name || a.display_name || a.slug || 'Agent');
  const inFleet = new Set(fleet.map((f) => String(f.agent_id || f.agentId || '')).filter(Boolean));
  const fromFleet = active.filter((a) => inFleet.has(idOf(a)));
  const picked = fromFleet.length > 0 ? fromFleet : active.filter((a) => a?.template_id === REVIEWER_TEMPLATE_ID);
  const source = fromFleet.length > 0 ? 'fleet' : 'reviewer_template';
  return picked
    .map((a) => ({ agentId: idOf(a), name: nameOf(a), source }) as ReviewerCandidate)
    .sort((x, y) => x.name.localeCompare(y.name));
}
