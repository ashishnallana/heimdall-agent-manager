/**
 * Pure helpers for shells shown as Main workspace panes (SH-1): the human name in
 * the pane header / pickers, and which sessions an "attach" list offers.
 */
import type { ShellSession } from '../../api/endpoints/shells';
import { isTerminal } from './shellModel';

/** Human-readable shell name: label, else the cwd's folder, else the session id. */
export function shellPaneName(session: Pick<ShellSession, 'label' | 'cwd' | 'session_id'> | null | undefined): string {
  const label = String(session?.label || '').trim();
  if (label) return label;
  const cwd = String(session?.cwd || '').trim().replace(/\/+$/, '');
  const folder = cwd.split('/').pop() || '';
  if (folder) return folder;
  if (cwd === '' && String(session?.cwd || '').startsWith('/')) return '/';
  return String(session?.session_id || 'Shell');
}

export type AttachableShellFilter = {
  projectId?: string;
  allProjects?: boolean;
  query?: string;
};

/** Live interactive shells (kind `shell`), optionally narrowed to a project and a search. */
export function attachableShells(sessions: readonly ShellSession[] | null | undefined, filter: AttachableShellFilter = {}): ShellSession[] {
  const query = String(filter.query || '').trim().toLowerCase();
  return (sessions || [])
    .filter((s) => s.kind === 'shell' && !isTerminal(s))
    .filter((s) => filter.allProjects || !filter.projectId || s.project_id === filter.projectId)
    .filter((s) => !query || `${shellPaneName(s)} ${s.cwd} ${s.session_id} ${s.label}`.toLowerCase().includes(query));
}

/** "12m", "3h 4m", "2d": how long a shell has been running. */
export function shellUptime(startedAt: string | undefined, now = Date.now()): string {
  const started = Date.parse(String(startedAt || ''));
  if (!Number.isFinite(started)) return '';
  const minutes = Math.max(0, Math.floor((now - started) / 60000));
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 48) return `${hours}h ${minutes % 60}m`;
  return `${Math.floor(hours / 24)}d`;
}
