// Pure view-model for the chat pane's action tray (REQ-AT-1/6/7): which task
// items belong to a conversation, and whether the tray or the composer shows.
// No React; unit-tested in tests/ui_action_tray_test.ts.
import type { AttentionItem, AttentionTaskItem } from '../../api/endpoints/attention';
import { hideKey } from './attentionModel';

/** Whose items a pane shows: its task chain, or (no chain) the agent instance holding the task. */
export type TrayScope = { chainId: string; agentInstanceId: string };

/**
 * The task items that need the user in this conversation: live (not snoozed)
 * task cards that are blocked on the user or waiting on their review, and are
 * not hidden by a pending/settled attention action. Server order is kept.
 */
export function trayItems(items: readonly AttentionItem[], scope: TrayScope, hidden: ReadonlySet<string> = new Set()): AttentionTaskItem[] {
  const chainId = scope.chainId.trim();
  const instanceId = scope.agentInstanceId.trim();
  if (!chainId && !instanceId) return [];
  return items.filter((item): item is AttentionTaskItem => {
    if (item.kind !== 'task' || item.snoozed) return false;
    const attention = item.details?.attention;
    if (attention !== 'blocked' && attention !== 'review') return false;
    if (hidden.has(hideKey(item))) return false;
    if (chainId) return item.action_refs?.chain_id === chainId;
    return !!instanceId && item.details?.holder_instance_id === instanceId;
  });
}

export function isBlockedItem(item: AttentionTaskItem): boolean {
  return item.details.attention === 'blocked';
}

/** "Needs your answer" (blocked) / "Needs your approval" (review). */
export function needLabel(item: AttentionTaskItem): string {
  if (item.details.badge === 'agent_not_running') return 'Needs you to start the agent';
  return isBlockedItem(item) ? 'Needs your answer' : 'Needs your approval';
}

/** The pill and panel title: "1 need you", "3 need you". */
export function needYouLabel(count: number): string {
  return `${count} need you`;
}

/** Answer (blocked) and Request changes (review) borrow the composer for their text. */
export type TrayModeKind = 'answer' | 'changes';
export type TrayMode = { kind: TrayModeKind; cardId: string };

export type TrayState = {
  /** What the user picked: the items, or the composer. */
  view: 'items' | 'composer';
  /** The composer is borrowed to answer / request changes on one card. */
  mode: TrayMode | null;
  /** Card ids already seen, so only a NEW item flips the dock back to the tray. */
  seen: readonly string[];
};

export const INITIAL_TRAY_STATE: TrayState = { view: 'items', mode: null, seen: [] };

export type TrayEvent =
  | { type: 'show_composer' }
  | { type: 'show_items' }
  | { type: 'start_mode'; kind: TrayModeKind; cardId: string }
  | { type: 'cancel_mode' }
  | { type: 'mode_sent' }
  /** The visible items changed. draftEmpty: the user is not halfway through a message. */
  | { type: 'items'; ids: readonly string[]; draftEmpty: boolean };

export function trayReducer(state: TrayState, event: TrayEvent): TrayState {
  switch (event.type) {
    case 'show_composer':
      return state.view === 'composer' && !state.mode ? state : { ...state, view: 'composer', mode: null };
    case 'show_items':
      return state.view === 'items' && !state.mode ? state : { ...state, view: 'items', mode: null };
    case 'start_mode':
      return { ...state, view: 'composer', mode: { kind: event.kind, cardId: event.cardId } };
    // Leaving a mode (sent or cancelled) goes back to the items; with none left
    // the composer shows anyway.
    case 'cancel_mode':
    case 'mode_sent':
      return { ...state, view: 'items', mode: null };
    case 'items': {
      const ids = event.ids;
      const known = new Set(state.seen);
      const arrived = ids.some((id) => !known.has(id));
      let { view, mode } = state;
      // The card being answered went away (answered elsewhere, or settled): drop the mode.
      if (mode && !ids.includes(mode.cardId)) {
        mode = null;
        view = 'items';
      }
      // A new item takes the dock back, unless the user is typing.
      if (arrived && !mode && event.draftEmpty) view = 'items';
      const sameSeen = ids.length === state.seen.length && ids.every((id, i) => id === state.seen[i]);
      if (sameSeen && view === state.view && mode === state.mode) return state;
      return { view, mode, seen: sameSeen ? state.seen : [...ids] };
    }
    default:
      return state;
  }
}

/** The dock shows the tray only when there are items, the user picked them, and no mode borrows the composer. */
export function trayVisible(state: TrayState, itemCount: number): boolean {
  return itemCount > 0 && state.view === 'items' && !state.mode;
}

/** The "<n> need you" pill rides on the composer when items wait and no mode is active. */
export function needYouPillVisible(state: TrayState, itemCount: number): boolean {
  return itemCount > 0 && !state.mode && !trayVisible(state, itemCount);
}

/** Composer copy while a mode borrows it. */
export const TRAY_MODE_COPY: Record<TrayModeKind, { banner: string; placeholder: string; sent: string }> = {
  answer: { banner: 'Answering', placeholder: 'Your answer…', sent: 'Answer sent' },
  changes: { banner: 'Requesting changes on', placeholder: 'What should change?', sent: 'Changes requested' },
};

/** Heimdall artifact ids (art_<hex>) referenced by an artifacts facet and the handoff text, in order, deduplicated. */
export function artifactIdsFrom(artifactsFacet: unknown, ...texts: unknown[]): string[] {
  const found: string[] = [];
  const add = (s: unknown) => {
    if (typeof s !== 'string') return;
    for (const m of s.matchAll(/\bart_[0-9a-f]{8,32}\b/g)) if (!found.includes(m[0])) found.push(m[0]);
  };
  const facet = artifactsFacet as any;
  const list: any[] = Array.isArray(facet) ? facet : Array.isArray(facet?.items) ? facet.items : [];
  for (const it of list) {
    if (!it || typeof it !== 'object') continue;
    add(it.ref); add(it.path); add(it.url); add(it.uri);
  }
  texts.forEach(add);
  return found;
}

/** Non-artifact links from an artifacts facet (url/link items, previews): label + href. */
export function artifactLinksFrom(artifactsFacet: unknown): Array<{ label: string; href: string }> {
  const facet = artifactsFacet as any;
  const list: any[] = Array.isArray(facet) ? facet : Array.isArray(facet?.items) ? facet.items : [];
  const out: Array<{ label: string; href: string }> = [];
  for (const it of list) {
    if (!it || (it.kind !== 'url' && it.kind !== 'link')) continue;
    const href = String(it.url || it.uri || it.ref || '');
    if (!/^https?:\/\//.test(href) || /\bart_[0-9a-f]{8,32}\b/.test(href)) continue;
    out.push({ label: String(it.label || it.title || href), href });
  }
  return out;
}

/** Handoff decisions as display strings (strings, or {decision|text|summary} objects). */
export function handoffDecisions(handoff: unknown): string[] {
  const raw = (handoff as any)?.decisions;
  const list: unknown[] = Array.isArray(raw) ? raw : [];
  return list
    .map((d: any) => (typeof d === 'string' ? d : String(d?.decision || d?.text || d?.summary || '')))
    .map((s) => s.trim())
    .filter(Boolean);
}
