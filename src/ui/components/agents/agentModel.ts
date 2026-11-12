/**
 * agentModel — the Agents pages' shared vocabulary.
 * ------------------------------------------------------------------
 * Inherited silently from projectModel; only what differs is remarked.
 *
 * Key differences:
 *  - No VCS filter: the list endpoint takes limit+cursor only, so tab
 *    is the ONLY client-side filter and `hasActiveFilters` is always false.
 *  - Agent verbs: edit + archive/unarchive. Delete is separate: the hub
 *    deletes only an agent nothing refers to (`GET /agents/{id}/usage`), so it
 *    is offered per agent rather than by state.
 *  - Instructions replaces description throughout.
 *  - Row pills: provider · model · active instances · (Archived).
 */
import { buildRouteHash } from '../../utils/appLocation';
import type { Tone } from '@ui';

/* ------------------------------------------------------------------ *
 * State
 * ------------------------------------------------------------------ */

export type AgentState = 'active' | 'archived';

export function agentState(record: { state?: string } | null | undefined): AgentState {
  return String(record?.state || '').trim().toLowerCase() === 'archived' ? 'archived' : 'active';
}

export function stateLabel(state: AgentState): string {
  return state === 'archived' ? 'Archived' : 'Active';
}

export function stateTone(state: AgentState): Tone {
  return state === 'archived' ? 'neutral' : 'success';
}

/* ------------------------------------------------------------------ *
 * Tabs (client-side — same note as Projects)
 * ------------------------------------------------------------------ */

export type AgentTab = 'live' | 'active' | 'archived';

export const AGENT_TABS: { value: AgentTab; label: string }[] = [
  { value: 'active', label: 'Active' },
  { value: 'live', label: 'Live Instances' },
  { value: 'archived', label: 'Archived' },
];

export function matchesTab(record: { state?: string }, tab: AgentTab): boolean {
  return agentState(record) === tab;
}

/** How many extra pages the list will pull chasing rows for a client-side tab. */
export const FILTER_PAGE_CAP = 5;

/* ------------------------------------------------------------------ *
 * Verbs
 * ------------------------------------------------------------------ */

export type AgentVerb = 'edit' | 'archive' | 'unarchive';

/** Like Projects: an archived agent can be edited and unarchived. */
export function verbsForState(state: AgentState): AgentVerb[] {
  return state === 'archived' ? ['edit', 'unarchive'] : ['edit', 'archive'];
}

export const VERB_LABEL: Record<AgentVerb, string> = {
  edit: 'Edit',
  archive: 'Archive',
  unarchive: 'Unarchive',
};

export function archiveConfirmBody(names: string[]): string {
  const subject =
    names.length === 1
      ? `"${names[0]}"`
      : `${names.length} agents`;
  return `Archiving ${subject} only takes ${names.length === 1 ? 'it' : 'them'} out of the Active list — running instances and associated memories are untouched, and nothing is deleted. You can unarchive ${names.length === 1 ? 'it' : 'them'} later.`;
}

/* ------------------------------------------------------------------ *
 * Delete (only for an agent nothing refers to)
 * ------------------------------------------------------------------ */

type UsageCounts = {
  instances: number;
  conversations: number;
  messages: number;
  artifacts: number;
  chains: number;
  tasks: number;
  memories: number;
  actions: number;
  workflows: number;
};

const USAGE_WORDS: [keyof UsageCounts, string, string][] = [
  ['instances', 'instance', 'instances'],
  ['conversations', 'conversation', 'conversations'],
  ['messages', 'message', 'messages'],
  ['artifacts', 'artifact', 'artifacts'],
  ['chains', 'chain', 'chains'],
  ['tasks', 'task', 'tasks'],
  ['memories', 'memory', 'memories'],
  ['actions', 'action', 'actions'],
  ['workflows', 'workflow', 'workflows'],
];

/** "2 instances, 1 chain" — the non-zero counts, in the hub's order. */
export function agentUsageSummary(usage: UsageCounts | null | undefined): string {
  if (!usage) return '';
  return USAGE_WORDS
    .filter(([key]) => (usage[key] || 0) > 0)
    .map(([key, one, many]) => `${usage[key]} ${usage[key] === 1 ? one : many}`)
    .join(', ');
}

export function deleteConfirmBody(name: string): string {
  return `"${name}" has never been used — no instances, conversations, chains, tasks, memories, actions or workflows refer to it. Deleting it removes it for good, along with its bridge settings and its place in your favorites. This can't be undone.`;
}

/* ------------------------------------------------------------------ *
 * Display helpers
 * ------------------------------------------------------------------ */

export function agentTitle(record: { name?: string; agentId?: string } | null | undefined): string {
  const name = String(record?.name || '').trim();
  if (name) return name;
  const id = String(record?.agentId || '').trim();
  return id || 'Untitled agent';
}

/** The row body: instructions as plain text (never rendered as markdown in a row). */
export function agentSnippet(record: { instructions?: string } | null | undefined): string {
  const source = String(record?.instructions || '').trim();
  if (!source) return '';
  return source
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/`([^`]*)`/g, '$1')
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/^[>\s]*[-*+]\s+/gm, '')
    .replace(/^#{1,6}\s+/gm, '')
    .replace(/[*_~]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}

/** `updated_at` is RFC3339. Absolute, for a `title=`. */
export function absoluteTime(updatedAt?: string): string {
  if (!updatedAt) return '—';
  const ms = Date.parse(updatedAt);
  if (!Number.isFinite(ms)) return updatedAt;
  return new Date(ms).toLocaleString();
}

/** Relative time for the row's meta line ("2h ago"). */
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
 * URL state
 * ------------------------------------------------------------------ */

export interface AgentListUrlState {
  tab: AgentTab | '';
  q: string;
  instanceId?: string;
}

export const EMPTY_LIST_URL_STATE: AgentListUrlState = { tab: '', q: '' };

export function parseAgentListUrl(search: string): AgentListUrlState {
  const params = new URLSearchParams(search.startsWith('?') ? search.slice(1) : search);
  const tab = String(params.get('tab') || '');
  const instance = String(params.get('instance') || '');
  return {
    tab: (AGENT_TABS.some((entry) => entry.value === tab) ? tab : '') as AgentTab | '',
    q: String(params.get('q') || ''),
    ...(instance ? { instanceId: instance } : {}),
  };
}

export function agentListSearch(state: AgentListUrlState): string {
  const params = new URLSearchParams();
  if (state.tab) params.set('tab', state.tab);
  if (state.q) params.set('q', state.q);
  if (state.instanceId) params.set('instance', state.instanceId);
  const query = params.toString();
  return query ? `?${query}` : '';
}

export function isLiveRuntimeStatus(status?: string): boolean {
  if (!status) return false;
  const s = status.trim().toLowerCase();
  return ['running', 'starting', 'launching', 'idle', 'busy', 'ready'].includes(s);
}

/* ------------------------------------------------------------------ *
 * Routes and breadcrumbs
 * ------------------------------------------------------------------ */

export const AGENT_LIST_PATH = '/agents';

export function agentListHref(state?: AgentListUrlState): string {
  return buildRouteHash(AGENT_LIST_PATH, state ? agentListSearch(state) : '');
}

export function agentViewHref(agentId: string, listState?: AgentListUrlState): string {
  return buildRouteHash(
    `${AGENT_LIST_PATH}/${encodeURIComponent(agentId)}`,
    listState ? agentListSearch(listState) : '',
  );
}

export function agentEditHref(agentId: string): string {
  return buildRouteHash(`${AGENT_LIST_PATH}/${encodeURIComponent(agentId)}/edit`, '');
}

export function agentNewHref(): string {
  return buildRouteHash(`${AGENT_LIST_PATH}/new`, '');
}

export function navigateTo(href: string): void {
  window.location.hash = href.startsWith('#') ? href.slice(1) : href;
}

export function replaceListSearch(state: AgentListUrlState): void {
  window.history.replaceState(
    window.history.state,
    '',
    buildRouteHash(AGENT_LIST_PATH, agentListSearch(state)),
  );
}

export interface AgentCrumb {
  label: string;
  href?: string;
}

export function listCrumbs(): AgentCrumb[] {
  return [{ label: 'Agents' }];
}

export function detailCrumbs(title: string, state: AgentState, listState?: AgentListUrlState): AgentCrumb[] {
  const tab: AgentTab = listState?.tab || state;
  const label = AGENT_TABS.find((entry) => entry.value === tab)?.label || 'Active';
  const full: AgentListUrlState = { ...(listState || EMPTY_LIST_URL_STATE), tab };
  return [
    { label: 'Agents', href: agentListHref({ ...full, tab: '' }) },
    { label, href: agentListHref(full) },
    { label: title },
  ];
}

export function viewCrumbs(title: string, listState?: AgentListUrlState): AgentCrumb[] {
  return [{ label: 'Agents', href: agentListHref(listState) }, { label: title }];
}

export function newCrumbs(listState?: AgentListUrlState): AgentCrumb[] {
  return [{ label: 'Agents', href: agentListHref(listState) }, { label: 'New agent' }];
}

export function editCrumbs(title: string, agentId: string, listState?: AgentListUrlState): AgentCrumb[] {
  return [
    { label: 'Agents', href: agentListHref(listState) },
    { label: title, href: agentViewHref(agentId) },
    { label: 'Edit' },
  ];
}

/* ------------------------------------------------------------------ *
 * Scroll restoration
 * ------------------------------------------------------------------ */

const LAST_ROW_KEY = 'heimdall:agents:last-row';

export function rememberRow(agentId: string): void {
  try {
    window.sessionStorage.setItem(LAST_ROW_KEY, agentId);
  } catch {
    /* Private mode / blocked storage: restoration is a convenience, not a contract. */
  }
}

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
 * The form
 * ------------------------------------------------------------------ */

export type AgentFormField = 'name' | 'slug' | 'instructions' | 'templateId' | 'form';

export interface MappedServerError {
  field: AgentFormField;
  message: string;
}

export function mapServerError(err: unknown): MappedServerError | null {
  const msg = String((err as any)?.data?.error || (err as any)?.error || (err as any)?.message || '');
  if (!msg) return null;
  if (/name/i.test(msg)) return { field: 'name', message: msg };
  if (/slug/i.test(msg)) return { field: 'slug', message: msg };
  return { field: 'form', message: msg };
}
