/**
 * memoryModel — the Memory pages' shared vocabulary.
 * ------------------------------------------------------------------
 * The three Memory routes (`/memory`, `/memory/:id`, `/memory/new|:id/edit`) agree
 * on statuses, verbs, titles, breadcrumbs and URL state here rather than each
 * re-deriving them. Nothing in this file renders: it is product knowledge that is
 * specific to memory, so it lives beside the pages and NOT in `@ui`.
 *
 * Spec: `docs/ui-rebuild/memory.md` (revision 3 + Amendment 1). Section numbers in
 * the comments below refer to it.
 */
import { buildRouteHash } from '../../utils/appLocation';
import type { Tone } from '@ui';

/* ------------------------------------------------------------------ *
 * Status and type
 * ------------------------------------------------------------------ */

/**
 * The four statuses the hub actually stores (content_service.odin:119,191-215).
 * There is no `proposed`, and no DELETE: `archived` is the soft-delete.
 */
export type MemoryStatus = 'pending' | 'active' | 'rejected' | 'archived';

export const MEMORY_STATUSES: MemoryStatus[] = ['pending', 'active', 'rejected', 'archived'];

const STATUS_LABEL: Record<MemoryStatus, string> = {
  pending: 'Pending',
  active: 'Active',
  rejected: 'Rejected',
  archived: 'Archived',
};

const STATUS_TONE: Record<MemoryStatus, Tone> = {
  pending: 'warning',
  active: 'success',
  rejected: 'danger',
  archived: 'neutral',
};

export function memoryStatus(record: { status?: string } | null | undefined): MemoryStatus {
  const raw = String(record?.status || '').trim().toLowerCase();
  return (MEMORY_STATUSES as string[]).includes(raw) ? (raw as MemoryStatus) : 'pending';
}

export function statusLabel(status: MemoryStatus): string {
  return STATUS_LABEL[status];
}

export function statusTone(status: MemoryStatus): Tone {
  return STATUS_TONE[status];
}

/** The five wire values; `unknown` is rejected on write (content.odin:5-43). */
export const MEMORY_TYPE_OPTIONS = ['fact', 'habit', 'episode', 'expertise', 'skill'] as const;
export type MemoryType = (typeof MEMORY_TYPE_OPTIONS)[number];

export interface Memory {
  id?: string;
  memory_id?: string;
  memoryId?: string;
  proposal_id?: string;
  proposalId?: string;
  title?: string;
  description?: string;
  body?: string;
  body_preview?: string;
  bodyPreview?: string;
  type?: MemoryType | string;
  status?: MemoryStatus | string;
  expires_at?: string;
  expiresAt?: string;
  created_at?: string;
  updated_at?: string;
  updatedAt?: string;
  reason?: string;
  evidence?: string;
  metadata_json?: string;
  metadataJson?: string;
  target?: string;
  agent_ids?: string[];
  agentIds?: string[];
  project_ids?: string[];
  projectIds?: string[];
  bridge_ids?: string[];
  bridgeIds?: string[];
  template_ids?: string[];
  templateIds?: string[];
  [key: string]: any;
}

/**
 * Returns true if m.expires_at is non-empty and new Date(m.expires_at).getTime() <= Date.now().
 */
export function isMemoryExpired(m: { expires_at?: string; expiresAt?: string } | null | undefined): boolean {
  const expiresAt = m?.expires_at || m?.expiresAt;
  if (!expiresAt || typeof expiresAt !== 'string' || !expiresAt.trim()) {
    return false;
  }
  const time = new Date(expiresAt).getTime();
  if (Number.isNaN(time)) {
    return false;
  }
  return time <= Date.now();
}

/* ------------------------------------------------------------------ *
 * Tabs (§1, Amendment A1.3)
 * ------------------------------------------------------------------ */

/**
 * Three tabs, one status query each. `rejected` lives inside Archived as a
 * second-level control, because both of its options are terminal — so neither the
 * tab nor the sub-control can ever misdescribe what is on screen. There is
 * deliberately NO status filter anywhere else on the page.
 */
export type MemoryTab = 'all' | 'proposals' | 'active' | 'archived';
export type ArchivedView = 'archived' | 'rejected';

export const MEMORY_TABS: { value: MemoryTab; label: string }[] = [
  { value: 'all', label: 'All' },
  { value: 'proposals', label: 'Proposed' },
  { value: 'active', label: 'Active' },
  { value: 'archived', label: 'Archived' },
];

/** The status a tab (plus, for Archived, its sub-view) queries. */
export function statusForTab(tab: MemoryTab, archivedView: ArchivedView): MemoryStatus | '' {
  if (tab === 'all') return '';
  if (tab === 'proposals') return 'pending';
  if (tab === 'active') return 'active';
  return archivedView === 'rejected' ? 'rejected' : 'archived';
}

/* ------------------------------------------------------------------ *
 * Verbs (§6)
 * ------------------------------------------------------------------ */

export type MemoryVerb = 'edit' | 'approve' | 'reject' | 'archive' | 'restore';

/**
 * What a row offers, by status.
 *
 * `rejected` gets **Approve**, never "Restore": `approve_memory` has no status
 * precondition (content_service.odin:191), so the call works from either terminal
 * state — but an archived memory was in force before and a rejected proposal never
 * was. Sending a rejected proposal to `active` puts it into force without ever
 * passing the approval that `pending` exists to enforce, and "Restore" would hide
 * that behind a word that sounds like an undo.
 *
 * `rejected` also gets no Edit: PATCH refuses anything but pending/active
 * (content_service.odin:168-188), and `approve` WITH edits would succeed — so the
 * UI, not the API, is what gates it.
 */
export function verbsForStatus(status: MemoryStatus): MemoryVerb[] {
  switch (status) {
    case 'pending':
      return ['approve', 'reject', 'edit'];
    case 'active':
      return ['edit', 'archive'];
    case 'archived':
      return ['restore'];
    case 'rejected':
      return ['approve'];
  }
}

export const VERB_LABEL: Record<MemoryVerb, string> = {
  edit: 'Edit',
  approve: 'Approve',
  reject: 'Reject',
  archive: 'Archive',
  restore: 'Restore',
};

/**
 * Delete is not a MemoryVerb: it is offered in the detail view in every status,
 * always behind a confirm, and never in bulk or on a keyboard shortcut. Archive
 * stays the everyday way to retire a memory; delete is for content that must not
 * be kept at all.
 */
export const MEMORY_DELETE_CONFIRM_BODY =
  "This permanently removes the memory and its text from Heimdall — it can't be restored. Agents launched from now on won't receive it, but agents already running keep the copy they were started with. To only stop using it, archive it instead.";

/** Only `pending` and `active` records may be edited at all (content_service.odin:168-188). */
export function isEditable(status: MemoryStatus): boolean {
  return status === 'pending' || status === 'active';
}

/** The `Alert` shown when the edit route is opened on a record that cannot be edited. */
export function editGateMessage(status: MemoryStatus): string {
  return status === 'rejected'
    ? "Rejected memories can't be edited. Restore it first."
    : "Archived memories can't be edited. Restore it first.";
}

/* ------------------------------------------------------------------ *
 * Display helpers
 * ------------------------------------------------------------------ */

/**
 * A memory's display title. `title` is optional on the wire, so a titleless memory
 * falls back to the first line of its body (the list serialises `body_preview` into
 * the same field) and, failing that, names its type.
 */
/**
 * Agents propose memories with an "Agent proposed: " prefix baked into the title
 * (`ham-ctl memory propose`). It is noise in a display title — it says the same thing
 * the Proposals tab and the Pending pill already say — so it is stripped wherever a
 * title is DISPLAYED. It is not stripped from the stored record, and nothing infers
 * provenance from it: a memory has no author field, and `status === 'pending'` is a
 * lifecycle state, not an author (user ruling 4).
 */
const PROPOSAL_PREFIX = /^\s*agent\s+proposed\s*:\s*/i;

export function stripProposalPrefix(value: string): string {
  const out = value.replace(PROPOSAL_PREFIX, '').trim();
  // A title that is ONLY the prefix would otherwise render as an empty row label.
  return out || value.trim();
}

export function memoryTitle(record: { title?: string; body?: string; type?: string } | null | undefined): string {
  const title = stripProposalPrefix(String(record?.title || '').trim());
  if (title) return title;
  const firstLine = String(record?.body || '')
    .split('\n')
    .map((line) => line.trim())
    .find(Boolean);
  if (firstLine) return stripProposalPrefix(firstLine);
  const type = String(record?.type || '').trim();
  return type ? `Untitled ${type} memory` : 'Untitled memory';
}

/** The client-only 200-character convention on single-line display names (§7). */
export const TITLE_MAX_LENGTH = 200;

/** `updated_at` is RFC3339 (platform/clock.odin:24-27). Absolute, for a `title=`. */
export function absoluteTime(updatedAt?: string): string {
  if (!updatedAt) return '—';
  const ms = Date.parse(updatedAt);
  if (!Number.isFinite(ms)) return updatedAt;
  return new Date(ms).toLocaleString();
}

/** Relative time for the Updated column ("2h ago"). Falls back to the raw value. */
export function relativeTime(updatedAt?: string): string {
  if (!updatedAt) return '—';
  const ms = Date.parse(updatedAt);
  if (!Number.isFinite(ms)) return updatedAt;
  const delta = Date.now() - ms;
  if (delta < 0) return 'just now';
  const mins = Math.floor(delta / 60000);
  if (mins < 1) return 'just now';
  if (mins < 60) return `${mins}m ago`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  if (days < 30) return `${days}d ago`;
  return new Date(ms).toLocaleDateString();
}

/* ------------------------------------------------------------------ *
 * URL state (§11)
 * ------------------------------------------------------------------ */

/**
 * Everything the list page keeps in the URL. Short, human-facing names map to the
 * API's own (`project` → `project_id`) at fetch time, and each scope param holds ONE
 * id — which is all the endpoint honours.
 *
 * Cursors are deliberately absent: a cursor is an `updated_at` timestamp, so a
 * shared link carrying one would land on a page of rows that no longer exists.
 */
export interface MemoryListUrlState {
  tab: MemoryTab | '';
  archivedView: ArchivedView;
  type: string;
  project: string;
  agent: string;
  bridge: string;
  template: string;
  q: string;
}

export const EMPTY_LIST_URL_STATE: MemoryListUrlState = {
  tab: '',
  archivedView: 'archived',
  type: '',
  project: '',
  agent: '',
  bridge: '',
  template: '',
  q: '',
};

export function parseMemoryListUrl(search: string): MemoryListUrlState {
  const params = new URLSearchParams(search.startsWith('?') ? search.slice(1) : search);
  const tab = String(params.get('tab') || '');
  const archivedView = String(params.get('view') || '');
  const typeParam = String(params.get('type') || '');
  return {
    tab: (MEMORY_TABS.some((entry) => entry.value === tab) ? tab : '') as MemoryTab | '',
    archivedView: archivedView === 'rejected' ? 'rejected' : 'archived',
    type: (MEMORY_TYPE_OPTIONS as readonly string[]).includes(typeParam) ? typeParam : '',
    project: String(params.get('project') || ''),
    agent: String(params.get('agent') || ''),
    bridge: String(params.get('bridge') || ''),
    template: String(params.get('template') || ''),
    q: String(params.get('q') || ''),
  };
}

/** Serialises list state, omitting every param that is at its default. */
export function memoryListSearch(state: MemoryListUrlState): string {
  const params = new URLSearchParams();
  if (state.tab) params.set('tab', state.tab);
  if (state.tab === 'archived' && state.archivedView === 'rejected') params.set('view', 'rejected');
  if (state.type) params.set('type', state.type);
  if (state.project) params.set('project', state.project);
  if (state.agent) params.set('agent', state.agent);
  if (state.bridge) params.set('bridge', state.bridge);
  if (state.template) params.set('template', state.template);
  if (state.q) params.set('q', state.q);
  const query = params.toString();
  return query ? `?${query}` : '';
}

/** True when any of the five filters is off its default (the mobile Filters dot). */
export function hasActiveFilters(state: MemoryListUrlState): boolean {
  return Boolean(state.type || state.project || state.agent || state.bridge || state.template);
}

/* ------------------------------------------------------------------ *
 * Routes and breadcrumbs (§9)
 * ------------------------------------------------------------------ */

export const MEMORY_LIST_PATH = '/memory';

export function memoryListHref(state?: MemoryListUrlState): string {
  return buildRouteHash(MEMORY_LIST_PATH, state ? memoryListSearch(state) : '');
}

/**
 * The detail href CARRIES the list's state (tab, filters, query). In the two-pane
 * layout the detail route is also what the list renders from, so a bare
 * `#/memory/:id` would silently reset the tab and filters the moment a row is
 * opened — the user would click a row under "Archived" and watch the list jump to
 * "Active" underneath them. It also gives the detail's breadcrumb a real tab to name
 * and makes the back trip land on the list exactly as it was left.
 */
export function memoryViewHref(memoryId: string, listState?: MemoryListUrlState): string {
  return buildRouteHash(
    `${MEMORY_LIST_PATH}/${encodeURIComponent(memoryId)}`,
    listState ? memoryListSearch(listState) : '',
  );
}

export function memoryEditHref(memoryId: string): string {
  return buildRouteHash(`${MEMORY_LIST_PATH}/${encodeURIComponent(memoryId)}/edit`, '');
}

export function memoryNewHref(): string {
  return buildRouteHash(`${MEMORY_LIST_PATH}/new`, '');
}

/** Push a route (a new history entry — back returns to where the user was). */
export function navigateTo(href: string): void {
  window.location.hash = href.startsWith('#') ? href.slice(1) : href;
}

/**
 * Rewrite the list's own query string in place. Tab/filter/query changes REPLACE so
 * that back leaves the list rather than walking its filter history; and because the
 * shell keys its route off the pathname alone, a replaced query re-renders nothing.
 */
export function replaceListSearch(state: MemoryListUrlState): void {
  window.history.replaceState(
    window.history.state,
    '',
    buildRouteHash(MEMORY_LIST_PATH, memoryListSearch(state)),
  );
}

export interface MemoryCrumb {
  label: string;
  href?: string;
}

/**
 * The four trails. Every crumb but the last is a link, and `Memory` carries the
 * list's URL state so drilling in and back out never loses the tab and filters.
 */
export function listCrumbs(): MemoryCrumb[] {
  return [{ label: 'Memory' }];
}

export function viewCrumbs(title: string, listState?: MemoryListUrlState): MemoryCrumb[] {
  return [{ label: 'Memory', href: memoryListHref(listState) }, { label: title }];
}

/**
 * The detail trail: **Memory / <the tab it came from>**, with the title carried by the
 * `<h1>` and never repeated as a crumb (`PageShell` renders ancestors only, so the
 * title is passed as the terminal crumb and dropped from the trail).
 *
 * The tab is whatever the URL carries. A memory reached from search or a pasted link
 * carries no tab, and inventing one would put a false trail on the page — so the
 * fallback is the tab the record's OWN status belongs to, which is where the list
 * would actually show it. `tabForStatus` never returns empty, so the crumb is never
 * blank.
 */
export function detailCrumbs(title: string, status: MemoryStatus, listState?: MemoryListUrlState): MemoryCrumb[] {
  const tab = listState?.tab || tabForStatus(status);
  const label = MEMORY_TABS.find((entry) => entry.value === tab)?.label || 'Active';
  const state: MemoryListUrlState = { ...(listState || EMPTY_LIST_URL_STATE), tab };
  return [
    { label: 'Memory', href: memoryListHref({ ...state, tab: '' as MemoryTab | '' } as MemoryListUrlState) },
    { label, href: memoryListHref(state) },
    { label: title },
  ];
}

/** Which tab a memory lives under, from its own status. Total — never empty. */
export function tabForStatus(status: MemoryStatus): MemoryTab {
  if (status === 'pending') return 'proposals';
  if (status === 'archived' || status === 'rejected') return 'archived';
  return 'active';
}

/**
 * The one-line body snippet under a row title. Markdown is NOT rendered in a row —
 * it is stripped to plain text, because a row is a scanning target and a half-parsed
 * heading or list marker is worse than prose.
 */
export function memorySnippet(record: { description?: string; body?: string; title?: string } | null | undefined): string {
  const source = String(record?.description || record?.body || '').trim();
  if (!source) return '';
  const plain = source
    .replace(/```[\s\S]*?```/g, ' ')       // fenced code
    .replace(/`([^`]*)`/g, '$1')            // inline code
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, '$1') // links / images → their text
    .replace(/^[>\s]*[-*+]\s+/gm, '')       // list markers
    .replace(/^#{1,6}\s+/gm, '')            // headings
    .replace(/[*_~]/g, '')                  // emphasis
    .replace(/\s+/g, ' ')
    .trim();
  return stripProposalPrefix(plain);
}

export function newCrumbs(listState?: MemoryListUrlState): MemoryCrumb[] {
  return [{ label: 'Memory', href: memoryListHref(listState) }, { label: 'New memory' }];
}

export function editCrumbs(title: string, memoryId: string, listState?: MemoryListUrlState): MemoryCrumb[] {
  return [
    { label: 'Memory', href: memoryListHref(listState) },
    { label: title, href: memoryViewHref(memoryId) },
    { label: 'Edit' },
  ];
}

/* ------------------------------------------------------------------ *
 * Scroll restoration (§11)
 * ------------------------------------------------------------------ */

const LAST_ROW_KEY = 'heimdall:memory:last-row';

/** Remember the row the user opened, so coming back can scroll to it. */
export function rememberRow(memoryId: string): void {
  try {
    window.sessionStorage.setItem(LAST_ROW_KEY, memoryId);
  } catch {
    /* Private mode / blocked storage: restoration is a convenience, not a contract. */
  }
}

/** Read and clear the remembered row. Restoration is attempted at most once. */
export function takeRememberedRow(): string {
  try {
    const value = window.sessionStorage.getItem(LAST_ROW_KEY) || '';
    window.sessionStorage.removeItem(LAST_ROW_KEY);
    return value;
  } catch {
    return '';
  }
}

/* ------------------------------------------------------------------ *
 * Server errors mapped onto form fields (§7, REQ-UI-21)
 * ------------------------------------------------------------------ */

export type MemoryFormField = 'title' | 'type' | 'description' | 'body' | 'evidence' | 'scope' | 'form';

export interface MappedServerError {
  field: MemoryFormField;
  message: string;
  /** For a scope error: which dimension the message named. */
  dimension?: 'projectIds' | 'agentIds' | 'bridgeIds' | 'templateIds';
}

/**
 * The hub returns one message; the form puts it on the control that caused it
 * rather than dumping it in a banner. Anything unrecognised stays form-level with
 * the server's own words.
 */
export function mapServerError(message: string): MappedServerError {
  const text = String(message || '').toLowerCase();
  if (text.includes('memory body is required')) {
    return { field: 'body', message: 'Body is required — this is the text your agents will read.' };
  }
  if (text.includes('memory type is invalid')) {
    return { field: 'type', message: 'Choose a memory type.' };
  }
  const notFound: { needle: string; noun: string; dimension: MappedServerError['dimension'] }[] = [
    { needle: 'project not found', noun: 'project', dimension: 'projectIds' },
    { needle: 'agent not found', noun: 'agent', dimension: 'agentIds' },
    { needle: 'bridge not found', noun: 'bridge', dimension: 'bridgeIds' },
    { needle: 'template not found', noun: 'template', dimension: 'templateIds' },
  ];
  for (const entry of notFound) {
    if (text.includes(entry.needle)) {
      return {
        field: 'scope',
        dimension: entry.dimension,
        message: `That ${entry.noun} no longer exists. Remove it and try again.`,
      };
    }
  }
  return { field: 'form', message: String(message || 'Something went wrong') };
}
