/**
 * actionModel — the Actions pages' shared vocabulary.
 * ------------------------------------------------------------------
 * Inherited silently from agentModel/projectModel; only what DIFFERS is remarked.
 * In Heimdall an **Action is a scheduled or on-demand prompt targeted at an agent**
 * — it is not a UI affordance.
 *
 * What differs for this resource, and why (verified in source, not assumed):
 *
 *  1. **No pagination, by user ruling and by endpoint.** `list_actions_handler`
 *     (`action_handlers.odin:216`) returns `{"data":[…]}` with no limit, cursor,
 *     has_more or count. REQ-UI-6 is WAIVED for actions only. `useInfiniteList`'s
 *     own doc rules itself out for "a list small enough to load whole", so the list
 *     page uses `useListActionsQuery` and filters the whole set in memory. A happy
 *     consequence: REQ-UI-5 (a query disregards filters) is exactly true here,
 *     because search and filters read the same already-loaded array.
 *
 *  2. **No name field.** `prompt_text` is the only human-readable identifier, so the
 *     row title is its first line and the two body lines are the remainder.
 *
 *  3. **The row's bottom-right time is the NEXT RUN, not `updated_at`.** Every other
 *     resource shows a past edit time there. The hub sorts this list
 *     `ORDER BY target_run_at ASC` (`action_repo_sqlite.odin:204`), so a past
 *     timestamp bottom-right would be a number unrelated to the order the eye is
 *     reading down the page. Deliberate divergence from Amendment 6.
 *
 *  4. **Delete, not archive.** `DELETE /api/v1/actions/:id` soft-deletes server-side
 *     but nothing restores it and `deleted_at` is never serialised, so to the UI a
 *     delete is permanent. There is no Archived tab.
 *
 *  5. **No Pause verb — because `completed` is a TERMINAL state, not a pause.**
 *     A state write does stop the scheduler: `action_scheduler_can_claim`
 *     (`src/bridge/action_scheduler.odin:392`) returns false for
 *     `state == "completed"`. (The hub's own lease CAS,
 *     `action_repo_sqlite.odin:269`, checks only `in_flight` and `target_run_at` —
 *     the state gate lives on the bridge, which is the thing that decides what to
 *     claim.) But `completed` already means "ran, and there is no next slot":
 *     `execute_action` sets it exactly when the bridge reports no further fire time
 *     (`action_handlers.odin:704`). Overloading it as Pause would make a paused
 *     action indistinguishable from a finished one in the list, on the record, and
 *     in the state filter. A real Pause wants its own state in the domain; until
 *     then the honest pause is the active-until window, which lives in the form.
 *
 *  6. **Target is immutable on edit.** `patch_action_handler` (:388-470) reads no
 *     `target_*` key at all — it silently drops them.
 */
import { buildRouteHash } from '../../utils/appLocation';
import type { Tone } from '@ui';
import type { Action } from '../../api/endpoints/actions';
import { parseBlackoutDates } from '../../api/endpoints/actions';
import { describeCron, formatInTimeZone, timeZoneLabel } from './scheduleUtils';

/* ------------------------------------------------------------------ *
 * State
 * ------------------------------------------------------------------ */

export type ActionState = 'active' | 'in_flight' | 'completed';

export function actionState(record: Pick<Action, 'state' | 'in_flight'> | null | undefined): ActionState {
  if (record?.in_flight) return 'in_flight';
  const raw = String(record?.state || '').trim().toLowerCase();
  if (raw === 'in_flight' || raw === 'completed') return raw;
  return 'active';
}

export function stateLabel(state: ActionState): string {
  if (state === 'in_flight') return 'In flight';
  if (state === 'completed') return 'Completed';
  return 'Active';
}

export function stateTone(state: ActionState): Tone {
  if (state === 'in_flight') return 'warning';
  if (state === 'completed') return 'neutral';
  return 'success';
}

export const STATE_FILTER_OPTIONS: { value: ActionState; label: string }[] = [
  { value: 'active', label: 'Active' },
  { value: 'in_flight', label: 'In flight' },
  { value: 'completed', label: 'Completed' },
];

/* ------------------------------------------------------------------ *
 * Tabs — scheduled vs on-demand, NOT state
 * ------------------------------------------------------------------ *
 * State is a filter, not a tab: `in_flight` lasts as long as one dispatch, so
 * state tabs would make rows hop between tabs while someone is reading them.
 * Scheduled/on-demand is the resource's real and stable division, and it also
 * explains the list order — an action with no computed `target_run_at` sorts to
 * the TOP of an ascending sort, so in a mixed list the on-demand ones float
 * above everything regardless of when they were touched.
 */

export type ActionTab = 'scheduled' | 'on-demand';

export const ACTION_TABS: { value: ActionTab; label: string }[] = [
  { value: 'scheduled', label: 'Scheduled' },
  { value: 'on-demand', label: 'On demand' },
];

/** Scheduled = a cron expression, or a legacy interval. Both fire on their own. */
export function isScheduled(record: Pick<Action, 'cron_expr' | 'interval'>): boolean {
  return Boolean(String(record.cron_expr || '').trim() || String(record.interval || '').trim());
}

export function matchesTab(record: Action, tab: ActionTab): boolean {
  return isScheduled(record) === (tab === 'scheduled');
}

/* ------------------------------------------------------------------ *
 * Verbs
 * ------------------------------------------------------------------ */

export type ActionVerb = 'run' | 'edit' | 'delete';

/** Offer only the verbs that mean something in this state. */
export function verbsForState(state: ActionState): ActionVerb[] {
  // A second dispatch while one is already in flight is meaningless — the row is
  // mid-run and the scheduler holds the lease.
  return state === 'in_flight' ? ['edit', 'delete'] : ['run', 'edit', 'delete'];
}

export const VERB_LABEL: Record<ActionVerb, string> = {
  run: 'Run now',
  edit: 'Edit',
  delete: 'Delete',
};

export function deleteConfirmBody(titles: string[]): string {
  const subject = titles.length === 1 ? `"${titles[0]}"` : `${titles.length} actions`;
  return `Deleting ${subject} removes ${titles.length === 1 ? 'its' : 'their'} schedule permanently — Ninjy can't undo this from here. Instances the action already spawned, and anything those runs produced, are left alone.`;
}

/* ------------------------------------------------------------------ *
 * Display helpers
 * ------------------------------------------------------------------ */

function flatten(source: string): string {
  return source
    .replace(/```[\s\S]*?```/g, ' ')
    .replace(/`([^`]*)`/g, '$1')
    .replace(/\s+/g, ' ')
    .trim();
}

/** The row title: the prompt's first non-empty line. There is no name field. */
export function actionTitle(record: Pick<Action, 'prompt_text'> | null | undefined): string {
  const lines = String(record?.prompt_text || '').split('\n');
  for (const line of lines) {
    const trimmed = line.trim();
    if (trimmed) return flatten(trimmed);
  }
  return 'Untitled action';
}

/**
 * The row body: the prompt AFTER its first line. A one-line prompt therefore has an
 * empty body, and the two lines stay reserved so the pill row does not ride up.
 */
export function actionSnippet(record: Pick<Action, 'prompt_text'> | null | undefined): string {
  const source = String(record?.prompt_text || '');
  const lines = source.split('\n');
  let firstIndex = -1;
  for (let i = 0; i < lines.length; i += 1) {
    if (lines[i].trim()) {
      firstIndex = i;
      break;
    }
  }
  if (firstIndex < 0) return '';
  return flatten(lines.slice(firstIndex + 1).join(' '));
}

/** The schedule pill's text: a human reading of cron, else the interval, else on-demand. */
export function scheduleLabel(record: Pick<Action, 'cron_expr' | 'interval'>): string {
  const cron = String(record.cron_expr || '').trim();
  if (cron) return describeCron(cron);
  const interval = String(record.interval || '').trim();
  if (interval) return `Every ${interval}`;
  return 'On demand';
}

/** Absolute rendering of an ISO timestamp in the action's own timezone. */
export function absoluteRun(iso?: string, timezone?: string): string {
  if (!iso) return '—';
  const ms = Date.parse(iso);
  if (!Number.isFinite(ms)) return iso;
  const date = new Date(ms);
  const tz = String(timezone || '').trim() || 'UTC';
  try {
    return `${formatInTimeZone(date, tz)} (${timeZoneLabel(date, tz)})`;
  } catch {
    // An unknown IANA name should degrade to something readable, not throw the row away.
    return date.toLocaleString();
  }
}

/** Absolute rendering in the viewer's own locale — for a `title=` on a past time. */
export function absoluteTime(iso?: string): string {
  if (!iso) return '—';
  const ms = Date.parse(iso);
  if (!Number.isFinite(ms)) return iso;
  return new Date(ms).toLocaleString();
}

/** Relative PAST time ("2h ago"), for created/updated. */
export function relativeTime(iso?: string): string {
  if (!iso) return '—';
  const ms = Date.parse(iso);
  if (!Number.isFinite(ms)) return iso;
  const delta = Date.now() - ms;
  if (delta < 60000) return 'just now';
  const mins = Math.floor(delta / 60000);
  if (mins < 60) return `${mins}m ago`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  if (days < 30) return `${days}d ago`;
  return new Date(ms).toLocaleDateString();
}

/**
 * The row's bottom-right label — a FUTURE time, the divergence noted in the header.
 * Returns the display text and the absolute form for its `title`.
 */
export function nextRunLabel(record: Action): { text: string; title: string } {
  const state = actionState(record);
  if (state === 'in_flight') {
    return { text: 'Running now', title: record.leased_at ? `Leased ${absoluteTime(record.leased_at)}` : 'Running now' };
  }
  if (!isScheduled(record)) {
    return { text: 'On demand', title: 'Runs only when you run it' };
  }
  const iso = String(record.target_run_at || '').trim();
  if (!iso) {
    return { text: 'Next run pending', title: 'The bridge has not computed the next fire time yet' };
  }
  const ms = Date.parse(iso);
  if (!Number.isFinite(ms)) return { text: iso, title: iso };

  const title = `Next run ${absoluteRun(iso, record.timezone)}`;
  const delta = ms - Date.now();
  if (delta <= 0) return { text: 'Due now', title };
  const mins = Math.round(delta / 60000);
  if (mins < 1) return { text: 'in <1m', title };
  if (mins < 60) return { text: `in ${mins}m`, title };
  const hours = Math.round(mins / 60);
  if (hours < 24) return { text: `in ${hours}h`, title };
  const days = Math.round(hours / 24);
  if (days < 30) return { text: `in ${days}d`, title };
  return { text: new Date(ms).toLocaleDateString(), title };
}

/** Which of the two target modes this action uses. Mirrors `action_target_mode`. */
export type ActionTargetMode = 'instance' | 'agent';

export function targetMode(record: Pick<Action, 'target_instance_id'>): ActionTargetMode {
  return String(record.target_instance_id || '').trim() ? 'instance' : 'agent';
}

export function blackoutCount(record: Pick<Action, 'blackout_dates'>): number {
  return parseBlackoutDates(record.blackout_dates).length;
}

/* ------------------------------------------------------------------ *
 * URL state
 * ------------------------------------------------------------------ */

export interface ActionListUrlState {
  tab: ActionTab | '';
  q: string;
  /** Filters. All client-side — the whole list is loaded, so there is no query param
   *  to back them with, and single-select per Amendment 8. */
  state: ActionState | '';
  project: string;
  bridge: string;
}

export const EMPTY_LIST_URL_STATE: ActionListUrlState = { tab: '', q: '', state: '', project: '', bridge: '' };

export function parseActionListUrl(search: string): ActionListUrlState {
  const params = new URLSearchParams(search.startsWith('?') ? search.slice(1) : search);
  const tab = String(params.get('tab') || '');
  const state = String(params.get('state') || '');
  return {
    tab: (ACTION_TABS.some((entry) => entry.value === tab) ? tab : '') as ActionTab | '',
    q: String(params.get('q') || ''),
    state: (STATE_FILTER_OPTIONS.some((entry) => entry.value === state) ? state : '') as ActionState | '',
    project: String(params.get('project') || ''),
    bridge: String(params.get('bridge') || ''),
  };
}

export function actionListSearch(state: ActionListUrlState): string {
  const params = new URLSearchParams();
  if (state.tab) params.set('tab', state.tab);
  if (state.q) params.set('q', state.q);
  if (state.state) params.set('state', state.state);
  if (state.project) params.set('project', state.project);
  if (state.bridge) params.set('bridge', state.bridge);
  const query = params.toString();
  return query ? `?${query}` : '';
}

export function hasActiveFilters(state: ActionListUrlState): boolean {
  return Boolean(state.state || state.project || state.bridge);
}

export function activeFilterCount(state: ActionListUrlState): number {
  return [state.state, state.project, state.bridge].filter(Boolean).length;
}

/* ------------------------------------------------------------------ *
 * Routes and breadcrumbs
 * ------------------------------------------------------------------ */

export const ACTION_LIST_PATH = '/actions';

export function actionListHref(state?: ActionListUrlState): string {
  return buildRouteHash(ACTION_LIST_PATH, state ? actionListSearch(state) : '');
}

export function actionViewHref(actionId: string, listState?: ActionListUrlState): string {
  return buildRouteHash(
    `${ACTION_LIST_PATH}/${encodeURIComponent(actionId)}`,
    listState ? actionListSearch(listState) : '',
  );
}

export function actionEditHref(actionId: string): string {
  return buildRouteHash(`${ACTION_LIST_PATH}/${encodeURIComponent(actionId)}/edit`, '');
}

export function actionNewHref(): string {
  return buildRouteHash(`${ACTION_LIST_PATH}/new`, '');
}

export function navigateTo(href: string): void {
  window.location.hash = href.startsWith('#') ? href.slice(1) : href;
}

export function replaceListSearch(state: ActionListUrlState): void {
  window.history.replaceState(
    window.history.state,
    '',
    buildRouteHash(ACTION_LIST_PATH, actionListSearch(state)),
  );
}

export interface ActionCrumb {
  label: string;
  href?: string;
}

/** A list page is the root of its own section — one heading, no trail (Amendment 5). */
export function listCrumbs(): ActionCrumb[] {
  return [{ label: 'Actions' }];
}

export function detailCrumbs(title: string, record: Action | null, listState?: ActionListUrlState): ActionCrumb[] {
  const tab: ActionTab = listState?.tab || (record && isScheduled(record) ? 'scheduled' : 'on-demand');
  const label = ACTION_TABS.find((entry) => entry.value === tab)?.label || 'Scheduled';
  const full: ActionListUrlState = { ...(listState || EMPTY_LIST_URL_STATE), tab };
  return [
    { label: 'Actions', href: actionListHref({ ...full, tab: '' }) },
    { label, href: actionListHref(full) },
    { label: title },
  ];
}

export function viewCrumbs(title: string, listState?: ActionListUrlState): ActionCrumb[] {
  return [{ label: 'Actions', href: actionListHref(listState) }, { label: title }];
}

export function newCrumbs(listState?: ActionListUrlState): ActionCrumb[] {
  return [{ label: 'Actions', href: actionListHref(listState) }, { label: 'New action' }];
}

export function editCrumbs(title: string, actionId: string, listState?: ActionListUrlState): ActionCrumb[] {
  return [
    { label: 'Actions', href: actionListHref(listState) },
    { label: title, href: actionViewHref(actionId) },
    { label: 'Edit' },
  ];
}

/* ------------------------------------------------------------------ *
 * Scroll restoration
 * ------------------------------------------------------------------ */

const LAST_ROW_KEY = 'heimdall:actions:last-row';

export function rememberRow(actionId: string): void {
  try {
    window.sessionStorage.setItem(LAST_ROW_KEY, actionId);
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
 * Errors
 * ------------------------------------------------------------------ */

export function actionErrorText(err: unknown, fallback = 'Something went wrong.'): string {
  if (!err) return fallback;
  const anyErr = err as any;
  const message = String(
    anyErr?.data?.error?.message || anyErr?.data?.error || anyErr?.error || anyErr?.message || '',
  ).trim();
  return message || fallback;
}

/* ------------------------------------------------------------------ *
 * The form
 * ------------------------------------------------------------------ */

export type ActionFormField =
  | 'targetInstanceId'
  | 'targetAgentId'
  | 'targetBridgeId'
  | 'promptText'
  | 'cronExpr'
  | 'blackoutDates'
  | 'activeWindow'
  | 'form';

export interface MappedServerError {
  field: ActionFormField;
  message: string;
}

/**
 * Map a server validation message back onto the field that produced it. The strings
 * matched here are the literal ones in `action_handlers.odin` — if they change, this
 * degrades to a form-level error rather than pointing at the wrong field.
 */
export function mapServerError(err: unknown): MappedServerError | null {
  const msg = actionErrorText(err, '');
  if (!msg) return null;
  if (/cron_expr/i.test(msg)) return { field: 'cronExpr', message: msg };
  if (/blackout_dates/i.test(msg)) return { field: 'blackoutDates', message: msg };
  if (/prompt_text/i.test(msg)) return { field: 'promptText', message: msg };
  if (/target_instance_id/i.test(msg)) return { field: 'targetInstanceId', message: msg };
  if (/target_agent_id/i.test(msg)) return { field: 'targetAgentId', message: msg };
  if (/target_bridge_id/i.test(msg)) return { field: 'targetBridgeId', message: msg };
  return { field: 'form', message: msg };
}
