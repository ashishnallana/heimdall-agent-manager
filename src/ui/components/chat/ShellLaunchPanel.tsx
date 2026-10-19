import { useEffect, useMemo, useRef, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { Combobox, Icon, Modal } from '@ui';
import { useCreateShellMutation, useKillShellMutation, useListShellsQuery, type ShellSession } from '../../api/endpoints/shells';
import { selectIsVaultUnlocked } from '../../store/vaultSlice';
import { bridgeLabel } from '../../utils/bridgeLaunchOptions';
import { composerBridgeIsArchived, composerBridgeIsOnline } from '../../utils/composerBridgeOptions';
import { describeApiError } from '../../utils/bridgeVaultStatus';
import { buildInteractiveShellRequest, resolveProjectBridgeShellCwd } from '../shells/interactiveShellLaunch';
import { attachableShells, shellPaneName, shellUptime } from '../shells/shellPaneModel';
import BridgeDirectoryPicker from '../BridgeDirectoryPicker';
import { useListBridgeDirQuery } from '../../api/endpoints/bridgeFs';

export interface ShellLaunchPanelProps {
  projects: any[];
  bridges: any[];
  projectId: string;
  onProjectChange: (projectId: string) => void;
  /** Preferred bridge (the user's remembered launch bridge). */
  initialBridgeId?: string;
  /** Ids already shown in Main panes ("Open" badge; picking one focuses it). */
  openIds?: readonly string[];
  isMobile: boolean;
  disabled?: boolean;
  /** Focuses Start once it becomes actionable for an explicit shortcut launch. */
  autoFocusStart?: boolean;
  /** Opens a shell session in the pane (new or attached). */
  onOpenShell: (sessionId: string) => void;
}

/**
 * Shell mode of the new-conversation picker (SH-1): start a new interactive shell
 * (project, online bridge, cwd defaulting to the project's path on that bridge, with
 * a bridge directory browser) or attach to / kill a running one.
 */
export function ShellLaunchPanel({ projects, bridges, projectId, onProjectChange, initialBridgeId, openIds = [], isMobile, disabled, autoFocusStart = false, onOpenShell }: ShellLaunchPanelProps) {
  const dispatch = useDispatch();
  const vaultUnlocked = useSelector(selectIsVaultUnlocked);
  const usableBridges = useMemo(
    () => bridges.filter((b) => !composerBridgeIsArchived(b)).sort((a, b) => Number(composerBridgeIsOnline(b)) - Number(composerBridgeIsOnline(a))),
    [bridges],
  );
  const onlineBridges = usableBridges.filter(composerBridgeIsOnline);
  const [bridgeId, setBridgeId] = useState('');
  useEffect(() => {
    if (bridgeId && usableBridges.some((b) => b.bridge_id === bridgeId)) return;
    const preferred = onlineBridges.find((b) => b.bridge_id === initialBridgeId) || onlineBridges[0];
    setBridgeId(preferred?.bridge_id || '');
  }, [bridgeId, initialBridgeId, onlineBridges, usableBridges]);
  const bridge = usableBridges.find((b) => b.bridge_id === bridgeId);
  const project = projects.find((p) => p.project_id === projectId);

  // The working directory defaults to the project's path on the chosen bridge and
  // re-defaults whenever the project or bridge changes; the user can edit/browse.
  // Without a project path, fall back to the bridge's own default directory (the
  // path its filesystem API lists for an empty path, i.e. the user's home) so the
  // field always shows the real directory the shell will start in.
  const projectPath = (project && bridgeId && resolveProjectBridgeShellCwd(project, bridgeId)) || '';
  const bridgeHomeQuery = useListBridgeDirQuery({ bridgeId, path: '' }, { skip: Boolean(projectPath) || !bridge || !composerBridgeIsOnline(bridge) });
  const projectCwd = projectPath || (bridgeHomeQuery.data?.ok !== false ? String(bridgeHomeQuery.data?.path || '') : '');
  const [cwd, setCwd] = useState(projectCwd);
  useEffect(() => { setCwd(projectCwd); }, [projectCwd]);
  const [browsing, setBrowsing] = useState(false);

  const [createShell, createState] = useCreateShellMutation();
  const blocked = !vaultUnlocked ? 'vault' : !bridge || !composerBridgeIsOnline(bridge) ? 'bridge' : '';
  const startRef = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    if (!autoFocusStart || disabled || blocked || createState.isLoading) return;
    const frame = requestAnimationFrame(() => startRef.current?.focus());
    return () => cancelAnimationFrame(frame);
  }, [autoFocusStart, blocked, createState.isLoading, disabled]);

  const [query, setQuery] = useState('');
  const [allProjects, setAllProjects] = useState(false);
  const shellsQuery = useListShellsQuery({ status: 'live', limit: 200 });
  const live = attachableShells(shellsQuery.data?.sessions, { projectId, allProjects, query });
  const [killTarget, setKillTarget] = useState<ShellSession | null>(null);
  const [killShell, killState] = useKillShellMutation();
  const bridgeNameOf = (id: string) => bridgeLabel(bridges.find((b) => b.bridge_id === id)) || id;

  const field = `w-full rounded-xl border border-subtle bg-surface px-3 text-primary outline-none focus:border-accent disabled:opacity-50 ${isMobile ? 'min-h-11 text-base' : 'min-h-10 text-sm'}`;
  const start = async () => {
    if (blocked || !bridgeId) return;
    try {
      const session = await createShell(buildInteractiveShellRequest({ bridgeId, cwd: cwd.trim() || undefined, projectId: projectId || undefined })).unwrap();
      onOpenShell(session.session_id);
    } catch { /* error rendered below */ }
  };

  return (
    <div data-debug-id="new-convo-shell-panel" className="flex w-full flex-col gap-6">
      <section className="rounded-2xl border border-subtle bg-surface p-4">
        <h2 className="mb-3 text-sm font-semibold text-primary">Start a new shell</h2>
        <div className={`grid gap-3 ${isMobile ? 'grid-cols-1' : 'grid-cols-2'}`}>
          <label className="flex min-w-0 flex-col gap-1.5">
            <span className="text-xs font-medium text-muted">Project</span>
            <Combobox
              debugId="new-convo-shell-project-select"
              options={projects.filter((p) => p.state === 'active').map((p) => ({ value: p.project_id, title: String(p.name || 'Project') }))}
              value={projectId}
              onChange={onProjectChange}
              placeholder="Choose project"
              searchPlaceholder="Search projects…"
              disabled={disabled}
              width="full"
            />
          </label>
          <label className="flex min-w-0 flex-col gap-1.5">
            <span className="text-xs font-medium text-muted">Bridge</span>
            <select data-debug-id="new-convo-shell-bridge-select" value={bridgeId} disabled={disabled} onChange={(e) => setBridgeId(e.target.value)} className={field}>
              {usableBridges.length === 0 ? <option value="">No bridges</option> : null}
              {usableBridges.map((b) => (
                <option key={b.bridge_id} value={b.bridge_id} disabled={!composerBridgeIsOnline(b)}>
                  {bridgeLabel(b)}{composerBridgeIsOnline(b) ? '' : ' (offline)'}
                </option>
              ))}
            </select>
          </label>
          <label className={`flex min-w-0 flex-col gap-1.5 ${isMobile ? '' : 'col-span-2'}`}>
            <span className="text-xs font-medium text-muted">Working directory</span>
            <span className="flex gap-2">
              <input
                data-debug-id="new-convo-shell-cwd-input"
                value={cwd}
                disabled={disabled}
                onChange={(e) => setCwd(e.target.value)}
                placeholder={!bridge ? 'Choose a bridge' : bridgeHomeQuery.isFetching ? 'Loading…' : '/path/to/directory'}
                className={`${field} min-w-0 flex-1 font-mono`}
              />
              <button
                type="button"
                data-debug-id="new-convo-shell-browse-btn"
                disabled={disabled || !bridge || !composerBridgeIsOnline(bridge)}
                onClick={() => setBrowsing(true)}
                className={`inline-flex shrink-0 items-center gap-1.5 rounded-xl border border-subtle bg-surface-raised px-3 text-sm text-primary hover:bg-neutral-soft disabled:opacity-40 ${isMobile ? 'min-h-11' : 'min-h-10'}`}
              >
                <Icon name="folder-open" size={15} />Browse…
              </button>
            </span>
          </label>
        </div>
        {blocked === 'vault' ? (
          <p data-debug-id="new-convo-shell-vault-locked" className="mt-3 flex flex-wrap items-center gap-2 rounded-xl border border-warning/30 bg-warning-soft px-3 py-2 text-sm text-warning">
            <Icon name="lock" size={14} />This device's vault keys are not installed yet; shell commands are encrypted.
          </p>
        ) : blocked === 'bridge' && onlineBridges.length === 0 ? (
          <p data-debug-id="new-convo-shell-no-bridge" className="mt-3 flex items-center gap-2 rounded-xl bg-neutral-soft px-3 py-2 text-sm text-muted">
            <Icon name="alert" size={14} />No bridge is online. Start a bridge to launch a shell.
          </p>
        ) : null}
        {createState.error ? <p role="alert" className="mt-3 text-sm text-danger">{describeApiError(createState.error) || 'Could not start the shell.'}</p> : null}
        <div className="mt-4 flex justify-end">
          <button
            ref={startRef}
            type="button"
            data-debug-id="new-convo-shell-start-btn"
            disabled={disabled || Boolean(blocked) || createState.isLoading}
            onClick={() => void start()}
            className={`inline-flex items-center justify-center gap-2 rounded-xl bg-accent px-4 font-semibold text-accent-fg disabled:opacity-40 ${isMobile ? 'min-h-11 w-full text-base' : 'min-h-10 text-sm'}`}
          >
            <Icon name="play" size={15} />{createState.isLoading ? 'Starting…' : 'Start shell'}
          </button>
        </div>
      </section>

      <section>
        <div className="mb-2 flex items-center justify-between gap-3">
          <h2 className="text-sm font-semibold text-primary">Attach to a running shell</h2>
          <label className={`flex cursor-pointer items-center gap-2 text-xs text-muted ${isMobile ? 'min-h-11' : ''}`}>
            <input data-debug-id="new-convo-shell-all-projects" type="checkbox" checked={allProjects} onChange={(e) => setAllProjects(e.target.checked)} className="h-4 w-4 accent-accent" />
            All projects
          </label>
        </div>
        <div className="relative mb-2">
          <Icon name="search" size={15} className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-faint" />
          <input data-debug-id="new-convo-shell-search-input" value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Search shells…" className={`${field} pl-9`} />
        </div>
        <ul data-debug-id="new-convo-shell-attach-list" className="overflow-hidden rounded-2xl border border-subtle bg-surface">
          {shellsQuery.isLoading ? <li className="px-4 py-6 text-center text-sm text-faint">Loading shells…</li> : null}
          {!shellsQuery.isLoading && live.length === 0 ? (
            <li className="px-4 py-6 text-center text-sm text-faint">No running shells{allProjects ? '' : ' in this project'}.</li>
          ) : null}
          {live.map((s) => {
            const open = openIds.includes(s.session_id);
            return (
              <li key={s.session_id} className="flex items-center border-b border-subtle last:border-b-0">
                <button
                  type="button"
                  data-debug-id={`new-convo-shell-attach-${s.session_id}`}
                  disabled={disabled}
                  onClick={() => onOpenShell(s.session_id)}
                  className={`flex min-w-0 flex-1 items-center gap-3 px-4 text-left hover:bg-neutral-soft ${isMobile ? 'min-h-14 py-2' : 'py-2.5'}`}
                >
                  <span className="grid h-8 w-8 shrink-0 place-items-center rounded-lg bg-neutral-soft text-muted"><Icon name="terminal" size={15} /></span>
                  <span className="min-w-0 flex-1">
                    <span className="flex items-center gap-2">
                      <span className="truncate text-sm font-semibold text-primary">{shellPaneName(s)}</span>
                      {open ? <span className="shrink-0 rounded-full bg-accent/15 px-2 py-0.5 text-[10px] font-semibold text-accent">Open</span> : null}
                    </span>
                    <span className="block truncate font-mono text-[11px] text-muted">{bridgeNameOf(s.bridge_id)} · {s.cwd || '~'}</span>
                  </span>
                  <span className="shrink-0 text-[11px] text-faint">{shellUptime(s.started_at)}</span>
                </button>
                <button
                  type="button"
                  data-debug-id={`new-convo-shell-kill-${s.session_id}`}
                  aria-label={`Kill ${shellPaneName(s)}`}
                  title="Kill shell"
                  disabled={disabled}
                  onClick={() => setKillTarget(s)}
                  className={`mr-2 grid shrink-0 place-items-center rounded-full text-muted hover:bg-danger-soft hover:text-danger ${isMobile ? 'h-11 w-11' : 'h-8 w-8'}`}
                >
                  <Icon name="stop" size={isMobile ? 16 : 14} />
                </button>
              </li>
            );
          })}
        </ul>
      </section>

      <Modal open={browsing} onOpenChange={setBrowsing} title="Choose working directory" size="lg" data-debug-id="new-convo-shell-browse-modal">
        <Modal.Body>
          {browsing && bridge ? (
            <BridgeDirectoryPicker
              debugId="new-convo-shell-dir-picker"
              bridgeId={bridge.bridge_id}
              bridgeLabel={bridgeLabel(bridge)}
              initialPath={cwd || projectCwd}
              onPick={(path) => { setCwd(path); setBrowsing(false); }}
              onClose={() => setBrowsing(false)}
            />
          ) : null}
        </Modal.Body>
      </Modal>

      <Modal open={Boolean(killTarget)} onOpenChange={(open) => { if (!open) setKillTarget(null); }} title={killTarget ? `Kill “${shellPaneName(killTarget)}”?` : 'Kill shell?'} size="sm" data-debug-id="new-convo-shell-kill-modal">
        <Modal.Body>
          <p className="text-sm text-muted">The process on {killTarget ? bridgeNameOf(killTarget.bridge_id) : 'the bridge'} is terminated{killTarget && openIds.includes(killTarget.session_id) ? ', and the pane showing it will show it as exited' : ''}.</p>
          {killState.error ? <p role="alert" className="mt-2 text-sm text-danger">{describeApiError(killState.error) || 'Could not kill the shell.'}</p> : null}
          <div className="mt-4 flex justify-end gap-2">
            <button type="button" data-debug-id="new-convo-shell-kill-cancel" onClick={() => setKillTarget(null)} className={`rounded-xl border border-subtle px-4 text-primary ${isMobile ? 'min-h-11' : 'min-h-9'}`}>Cancel</button>
            <button
              type="button"
              data-debug-id="new-convo-shell-kill-confirm"
              disabled={killState.isLoading}
              onClick={async () => {
                if (!killTarget) return;
                try { await killShell({ sessionId: killTarget.session_id }).unwrap(); setKillTarget(null); } catch { /* shown above */ }
              }}
              className={`rounded-xl bg-danger px-4 font-semibold text-white disabled:opacity-50 ${isMobile ? 'min-h-11' : 'min-h-9'}`}
            >
              Kill
            </button>
          </div>
        </Modal.Body>
      </Modal>
    </div>
  );
}

export default ShellLaunchPanel;
