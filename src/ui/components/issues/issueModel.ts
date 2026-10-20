import { buildRouteHash } from '../../utils/appLocation';
import type { Tone } from '@ui';
import type { Issue, IssueStatus, IssueScopeType } from '../../api/endpoints/issues';

export const ISSUE_STATUSES: IssueStatus[] = ['new', 'fixed', 'obsolete'];

export const STATUS_LABEL: Record<IssueStatus, string> = {
  new: 'New',
  fixed: 'Fixed',
  obsolete: 'Obsolete',
};

export const STATUS_TONE: Record<IssueStatus, Tone> = {
  new: 'warning',
  fixed: 'success',
  obsolete: 'neutral',
};

export function issueStatus(record: { status?: string } | null | undefined): IssueStatus {
  const raw = String(record?.status || '').trim().toLowerCase();
  return (ISSUE_STATUSES as string[]).includes(raw) ? (raw as IssueStatus) : 'new';
}

export function statusLabel(status: IssueStatus): string {
  return STATUS_LABEL[status] || status;
}

export function statusTone(status: IssueStatus): Tone {
  return STATUS_TONE[status] || 'neutral';
}

export const SCOPE_OPTIONS = [
  { value: 'global', label: 'Global' },
  { value: 'project', label: 'Project' },
  { value: 'agent_id', label: 'Agent' },
  { value: 'bridge_id', label: 'Bridge' },
] as const;

export function scopeLabel(scope?: string): string {
  const s = String(scope || '').trim().toLowerCase();
  if (s === 'project') return 'Project';
  if (s === 'agent' || s === 'agent_id') return 'Agent';
  if (s === 'bridge' || s === 'bridge_id') return 'Bridge';
  return 'Global';
}

export function scopeTone(scope?: string): Tone {
  const s = String(scope || '').trim().toLowerCase();
  if (s === 'project') return 'info';
  if (s === 'agent' || s === 'agent_id') return 'info';
  if (s === 'bridge' || s === 'bridge_id') return 'warning';
  return 'neutral';
}

export function issueTitle(issue: any): string {
  return String(issue?.title || issue?.issue_id || issue?.id || 'Untitled issue');
}

export function issueSnippet(issue: any): string {
  const desc = String(
    issue?.description_preview ||
    issue?.descriptionPreview ||
    issue?.description ||
    ''
  ).trim();
  if (!desc) return '';
  if (desc.startsWith('vault:v2:')) return desc;
  // Strip markdown headers/newlines for preview snippet
  return desc.replace(/[#*`_~[\]()]/g, ' ').replace(/\s+/g, ' ').trim();
}

export function absoluteTime(updatedAt?: string): string {
  if (!updatedAt) return '—';
  const ms = Date.parse(updatedAt);
  if (!Number.isFinite(ms)) return updatedAt;
  return new Date(ms).toLocaleString();
}

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

export interface IssueListUrlState {
  status: string;
  scope: string;
  target: string;
  chain: string;
  q: string;
}

export function issueListSearch(state: IssueListUrlState): string {
  const params = new URLSearchParams();
  if (state.status) params.set('status', state.status);
  if (state.scope) params.set('scope', state.scope);
  if (state.target) params.set('target', state.target);
  if (state.chain) params.set('chain', state.chain);
  if (state.q) params.set('q', state.q);
  return params.toString();
}

export const ISSUES_LIST_PATH = '/issues';

export function issuesListHref(state?: IssueListUrlState): string {
  const search = state ? issueListSearch(state) : '';
  return buildRouteHash(ISSUES_LIST_PATH, search);
}

export function issueViewHref(issueId: string, listState?: IssueListUrlState): string {
  return buildRouteHash(
    `${ISSUES_LIST_PATH}/${encodeURIComponent(issueId)}`,
    listState ? issueListSearch(listState) : '',
  );
}

export function issueEditHref(issueId: string): string {
  return buildRouteHash(`${ISSUES_LIST_PATH}/${encodeURIComponent(issueId)}/edit`, '');
}

export function issueNewHref(): string {
  return buildRouteHash(`${ISSUES_LIST_PATH}/new`, '');
}

export function navigateTo(href: string): void {
  window.location.hash = href.startsWith('#') ? href.slice(1) : href;
}

export interface IssueCrumb {
  label: string;
  href?: string;
}

export function listCrumbs(): IssueCrumb[] {
  return [{ label: 'Issues' }];
}

export function newCrumbs(): IssueCrumb[] {
  return [
    { label: 'Issues', href: issuesListHref() },
    { label: 'New Issue' },
  ];
}

export function editCrumbs(issue: any): IssueCrumb[] {
  const title = issue ? issueTitle(issue) : 'Issue';
  const issueId = issue?.issue_id || issue?.issueId || issue?.id || '';
  return [
    { label: 'Issues', href: issuesListHref() },
    { label: title, href: issueId ? issueViewHref(issueId) : undefined },
    { label: 'Edit' },
  ];
}
