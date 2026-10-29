/**
 * projectModel — the Projects pages' shared vocabulary.
 * ------------------------------------------------------------------
 * The three Projects routes (`/projects`, `/projects/:id`, `/projects/new` and
 * `/projects/:id/edit`) agree on state, verbs, titles, breadcrumbs and URL state
 * here rather than each re-deriving them. Nothing in this file renders: it is
 * product knowledge specific to projects, so it lives beside the pages and NOT in
 * `@ui`.
 *
 * Built on the Memory reference (`docs/ui-rebuild/memory.md`, Amendments 2-7). Only
 * what differs is commented; everything unremarked is the inherited convention.
 */
import { useMemo } from 'react';
import { buildRouteHash } from '../../utils/appLocation';
import { useListProjectsQuery } from '../../api/endpoints/projects';
import type { Tone } from '@ui';

/* ------------------------------------------------------------------ *
 * State
 * ------------------------------------------------------------------ */

/**
 * The two states the hub stores (`domain/project.odin:5-9`). A project is
 * soft-archived, never hard-deleted — and unlike a memory it cannot come BACK:
 * `archive_project` sets `.Archived` (`project_service.odin:245-250`) and
 * `Update_Project_Input` has no `state` field, so no endpoint reverses it.
 */
export type ProjectState = 'active' | 'archived';

export function projectState(record: { state?: string } | null | undefined): ProjectState {
  return String(record?.state || '').trim().toLowerCase() === 'archived' ? 'archived' : 'active';
}

export function isProjectArchived(record: { state?: string } | null | undefined): boolean {
  return projectState(record) === 'archived';
}

export function useArchivedProjectIds(): Set<string> {
  const { data } = useListProjectsQuery();
  return useMemo(() => {
    const set = new Set<string>();
    const list = data?.projects || (Array.isArray(data) ? data : []);
    for (const p of list) {
      if (isProjectArchived(p)) {
        const id = p.project_id || p.projectId;
        if (id) set.add(id);
      }
    }
    return set;
  }, [data]);
}

export function stateLabel(state: ProjectState): string {
  return state === 'archived' ? 'Archived' : 'Active';
}

export function stateTone(state: ProjectState): Tone {
  return state === 'archived' ? 'neutral' : 'success';
}

/**
 * The VCS kinds the UI offers.
 *
 * `vcs_kind` is a free string server-side and only `"git"` changes behaviour — the
 * bridge walks up for a `.git` root when validating a path
 * (`project_path_validation.odin:32-37`). So this is a UI convention, not an
 * enum the API enforces, and a project carrying some other value renders it
 * verbatim rather than being silently re-labelled.
 */
export const VCS_KIND_OPTIONS = ['', 'git', 'jj'] as const;

export function vcsLabel(kind: string): string {
  const value = String(kind || '').trim();
  if (!value) return 'No VCS';
  return value;
}

/* ------------------------------------------------------------------ *
 * Tabs (client-side — see the note)
 * ------------------------------------------------------------------ */

export type ProjectTab = 'active' | 'archived';

export const PROJECT_TABS: { value: ProjectTab; label: string }[] = [
  { value: 'active', label: 'Active' },
  { value: 'archived', label: 'Archived' },
];

/**
 * THE structural difference from Memory.
 *
 * Memory's tabs are server queries (`?status=`), so its tab, its filters and its
 * infinite scroll all agree about what a page contains. `GET /api/v1/projects`
 * takes `limit` and `cursor` and nothing else (`project_handlers.odin:15-25`), so
 * the tab — and the VCS filter — are applied HERE, over the rows the keyset stream
 * has already produced.
 *
 * The consequence the list page has to handle honestly: a tab can be empty while
 * `has_more` is still true. It does that by continuing to page while the filtered
 * result is empty (bounded — see `FILTER_PAGE_CAP`), and by offering to keep
 * loading rather than claiming there is nothing there.
 */
export function matchesTab(record: { state?: string }, tab: ProjectTab): boolean {
  return projectState(record) === tab;
}

/** How many extra pages the list will pull chasing rows for a client-side tab. */
export const FILTER_PAGE_CAP = 5;

/* ------------------------------------------------------------------ *
 * Verbs
 * ------------------------------------------------------------------ */

export type ProjectVerb = 'edit' | 'archive';

/**
 * What a row offers, by state.
 *
 * An archived project gets **Edit but no Restore**: `update` has no state
 * precondition so editing genuinely works, while un-archiving has no endpoint at
 * all. Offering a Restore that 404s — or a Restore that silently does nothing —
 * would be worse than offering none, and this is the Archived-tab lesson from
 * Memory applied to a resource whose terminal state really is terminal.
 */
export function verbsForState(state: ProjectState): ProjectVerb[] {
  return state === 'archived' ? ['edit'] : ['edit', 'archive'];
}

export const VERB_LABEL: Record<ProjectVerb, string> = {
  edit: 'Edit',
  archive: 'Archive',
};

/**
 * The archive confirm's body. It carries two facts the user cannot recover from
 * afterwards and cannot see anywhere else: archiving does NOT cascade
 * (`project_service.odin:242-244` — chains, tasks and instances are untouched), and
 * the hub has no way back.
 */
export function archiveConfirmBody(names: string[]): string {
  const subject =
    names.length === 1
      ? `“${names[0]}”`
      : `${names.length} projects`;
  return `Archiving ${subject} only takes ${names.length === 1 ? 'it' : 'them'} out of the Active list — chains, agents and memories keep working, and nothing is deleted. Ninjy can't un-archive from here.`;
}

/* ------------------------------------------------------------------ *
 * Display helpers
 * ------------------------------------------------------------------ */

export function projectTitle(record: { name?: string; projectId?: string } | null | undefined): string {
  const name = String(record?.name || '').trim();
  if (name) return name;
  const id = String(record?.projectId || '').trim();
  return id || 'Untitled project';
}

/**
 * The row body: a project's description, stripped to plain text.
 *
 * Markdown is NOT rendered in a row — a row is a scanning target and a half-parsed
 * heading or list marker is worse than prose. Same treatment as `memorySnippet`.
 */
export function projectSnippet(record: { description?: string } | null | undefined): string {
  const source = String(record?.description || '').trim();
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

/**
 * A path shortened for a row chip by dropping its HEAD, not its tail.
 *
 * `/home/tanmay/work/heimdall-agent-manager` and
 * `/home/tanmay/work/heimdall-hub-rewrite` are identical for their first 17
 * characters; a normal end-truncation renders both as the same chip. The tail is
 * what identifies a checkout, so that is what survives.
 */
export function shortPath(path: string, max = 34): string {
  const value = String(path || '').trim();
  if (value.length <= max) return value;
  return `…${value.slice(value.length - (max - 1))}`;
}

/** `updated_at` is RFC3339 (`platform/clock.odin:24-27`). Absolute, for a `title=`. */
export function absoluteTime(updatedAt?: string): string {
  if (!updatedAt) return '—';
  const ms = Date.parse(updatedAt);
  if (!Number.isFinite(ms)) return updatedAt;
  return new Date(ms).toLocaleString();
}

/** Relative time for the row's meta line ("2h ago"). Falls back to the raw value. */
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

export interface ProjectListUrlState {
  tab: ProjectTab | '';
  /** The one filter: `''` (any), a vcs kind, or `none` for projects with no VCS. */
  vcs: string;
  q: string;
}

export const EMPTY_LIST_URL_STATE: ProjectListUrlState = { tab: '', vcs: '', q: '' };

export function parseProjectListUrl(search: string): ProjectListUrlState {
  const params = new URLSearchParams(search.startsWith('?') ? search.slice(1) : search);
  const tab = String(params.get('tab') || '');
  const vcs = String(params.get('vcs') || '');
  return {
    tab: (PROJECT_TABS.some((entry) => entry.value === tab) ? tab : '') as ProjectTab | '',
    vcs: vcs === 'none' || (VCS_KIND_OPTIONS as readonly string[]).includes(vcs) ? vcs : '',
    q: String(params.get('q') || ''),
  };
}

/** Serialises list state, omitting every param that is at its default. */
export function projectListSearch(state: ProjectListUrlState): string {
  const params = new URLSearchParams();
  if (state.tab) params.set('tab', state.tab);
  if (state.vcs) params.set('vcs', state.vcs);
  if (state.q) params.set('q', state.q);
  const query = params.toString();
  return query ? `?${query}` : '';
}

export function hasActiveFilters(state: ProjectListUrlState): boolean {
  return Boolean(state.vcs);
}

/** Does this row survive the VCS filter? Client-side, because there is no facet. */
export function matchesVcsFilter(record: { vcsKind?: string }, vcs: string): boolean {
  if (!vcs) return true;
  const kind = String(record.vcsKind || '').trim();
  return vcs === 'none' ? kind === '' : kind === vcs;
}

/** The chip label for an applied VCS filter. */
export function vcsFilterLabel(vcs: string): string {
  return vcs === 'none' ? 'No VCS' : vcs;
}

/* ------------------------------------------------------------------ *
 * Routes and breadcrumbs
 * ------------------------------------------------------------------ */

export const PROJECT_LIST_PATH = '/projects';

export function projectListHref(state?: ProjectListUrlState): string {
  return buildRouteHash(PROJECT_LIST_PATH, state ? projectListSearch(state) : '');
}

/**
 * The detail href CARRIES the list's state (tab, filter, query). In the two-pane
 * layout the detail route is also what renders the list, so a bare
 * `#/projects/:id` would reset the tab and filter the moment a row is opened.
 */
export function projectViewHref(projectId: string, listState?: ProjectListUrlState): string {
  return buildRouteHash(
    `${PROJECT_LIST_PATH}/${encodeURIComponent(projectId)}`,
    listState ? projectListSearch(listState) : '',
  );
}

export function projectEditHref(projectId: string): string {
  return buildRouteHash(`${PROJECT_LIST_PATH}/${encodeURIComponent(projectId)}/edit`, '');
}

export function projectNewHref(): string {
  return buildRouteHash(`${PROJECT_LIST_PATH}/new`, '');
}

/** Push a route (a new history entry — back returns to where the user was). */
export function navigateTo(href: string): void {
  window.location.hash = href.startsWith('#') ? href.slice(1) : href;
}

/** Rewrite the list's own query string in place (tab/filter/query REPLACE). */
export function replaceListSearch(state: ProjectListUrlState): void {
  window.history.replaceState(
    window.history.state,
    '',
    buildRouteHash(PROJECT_LIST_PATH, projectListSearch(state)),
  );
}

export interface ProjectCrumb {
  label: string;
  href?: string;
}

/** A list page is the root of its section, so it carries a heading and no trail. */
export function listCrumbs(): ProjectCrumb[] {
  return [{ label: 'Projects' }];
}

/**
 * The detail trail: **Projects / <the tab it came from> / <title>**. `PageShell`
 * renders ancestors only and promotes the terminal crumb into the `<h1>`, so the
 * title is passed and never printed twice. A project reached from search or a
 * pasted link carries no tab, so the fallback is the tab its own state belongs to
 * — where the list would actually show it.
 */
export function detailCrumbs(title: string, state: ProjectState, listState?: ProjectListUrlState): ProjectCrumb[] {
  const tab: ProjectTab = listState?.tab || state;
  const label = PROJECT_TABS.find((entry) => entry.value === tab)?.label || 'Active';
  const full: ProjectListUrlState = { ...(listState || EMPTY_LIST_URL_STATE), tab };
  return [
    { label: 'Projects', href: projectListHref({ ...full, tab: '' }) },
    { label, href: projectListHref(full) },
    { label: title },
  ];
}

export function viewCrumbs(title: string, listState?: ProjectListUrlState): ProjectCrumb[] {
  return [{ label: 'Projects', href: projectListHref(listState) }, { label: title }];
}

export function newCrumbs(listState?: ProjectListUrlState): ProjectCrumb[] {
  return [{ label: 'Projects', href: projectListHref(listState) }, { label: 'New project' }];
}

export function editCrumbs(title: string, projectId: string, listState?: ProjectListUrlState): ProjectCrumb[] {
  return [
    { label: 'Projects', href: projectListHref(listState) },
    { label: title, href: projectViewHref(projectId) },
    { label: 'Edit' },
  ];
}

/* ------------------------------------------------------------------ *
 * Scroll restoration
 * ------------------------------------------------------------------ */

const LAST_ROW_KEY = 'heimdall:projects:last-row';

export function rememberRow(projectId: string): void {
  try {
    window.sessionStorage.setItem(LAST_ROW_KEY, projectId);
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

export type ProjectFormField = 'name' | 'slug' | 'description' | 'repoUrl' | 'vcsKind' | 'defaultPath' | 'form';

/**
 * PATCH merges only NON-EMPTY fields (`project_service.odin:232-239`:
 * `if input.x != "" do project.x = input.x`), so **a field cannot be cleared**
 * through this API. The edit form refuses the attempt instead of pretending to
 * save it — sending a single space to fake a clear would write a lie into the
 * record, and dropping the change silently is how a user comes to distrust a form.
 */
export const CANNOT_CLEAR_MESSAGE = "Ninjy can't clear this field yet — it would keep its previous value. Put something back, or leave it as it was.";

export interface MappedServerError {
  field: ProjectFormField;
  message: string;
}

/**
 * The hub returns one message; the form puts it on the control that caused it
 * rather than dumping it in a banner. Anything unrecognised stays form-level in
 * the server's own words.
 */
export function mapServerError(message: string): MappedServerError {
  const text = String(message || '').toLowerCase();
  if (text.includes('project name is required')) {
    return { field: 'name', message: 'Give the project a name.' };
  }
  if (text.includes('default_path is required')) {
    return { field: 'defaultPath', message: 'Choose the folder this project lives in.' };
  }
  return { field: 'form', message: String(message || 'Something went wrong') };
}

/**
 * A repo URL sanity check. Deliberately loose: the hub stores whatever it is given
 * and the bridge only best-effort matches it (`project_path_validation.odin:33`),
 * so this rejects what is obviously not a URL and nothing more.
 */
export function looksLikeRepoUrl(value: string): boolean {
  const url = String(value || '').trim();
  if (!url) return true;
  return /^[a-z][a-z0-9+.-]*:\/\//i.test(url) || /^[^@\s]+@[^:\s]+:/.test(url);
}
