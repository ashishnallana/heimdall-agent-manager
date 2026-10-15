import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { Icon, Menu } from '@ui';
import {
  useCreateShellMutation,
  useGetShellSessionQuery,
  useKillShellMutation,
  useListShellsQuery,
  useRestartShellMutation,
} from '../../api/endpoints/shells';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import { bridgeLabel } from '../../utils/bridgeLaunchOptions';
import { describeApiError } from '../../utils/bridgeVaultStatus';
import { buildInteractiveShellRequest } from '../shells/interactiveShellLaunch';
import { isTerminal } from '../shells/shellModel';
import { attachableShells, shellPaneName } from '../shells/shellPaneModel';
import { ShellWorkbenchPane } from '../workbench/ShellWorkbenchPane';
import { chromeIconButtonSizeClass } from '../shell/shellChrome';

export interface ShellMainPaneProps {
  sessionId: string;
  isMobile: boolean;
  /** Ids open in OTHER Main panes, for the switcher's "Open" badge. */
  openIds: readonly string[];
  /** Show another shell in this pane (dedup: an id open elsewhere focuses that pane). */
  onSwitch: (sessionId: string) => void;
  /** Detach: closes the pane, the shell keeps running. */
  onClose: () => void;
  headerLeading?: ReactNode;
  headerEnd?: ReactNode;
}

/**
 * A Main workspace pane bound to one interactive shell (SH-1). Header reads
 * `<Bridge> / <Shell name> ▾`; the shell segment opens a switcher. Closing the pane
 * detaches; killing is an explicit, confirmed menu action.
 */
export function ShellMainPane({ sessionId, isMobile, openIds, onSwitch, onClose, headerLeading, headerEnd }: ShellMainPaneProps) {
  const { data: session } = useGetShellSessionQuery({ sessionId }, { skip: !sessionId });
  const { data: bridgesData } = useListBridgesQuery(undefined);
  const bridge = (bridgesData?.bridges || []).find((b: any) => b.bridge_id === session?.bridge_id);
  const bridgeName = bridgeLabel(bridge) || session?.bridge_id || 'bridge';
  const name = session ? shellPaneName(session) : sessionId;
  const exited = Boolean(session && isTerminal(session));

  const [switcherOpen, setSwitcherOpen] = useState(false);
  const [menuOpen, setMenuOpen] = useState(false);
  const [confirmKill, setConfirmKill] = useState(false);
  const [killShell, killState] = useKillShellMutation();
  const [restartShell, restartState] = useRestartShellMutation();
  const iconBtn = `grid ${chromeIconButtonSizeClass(isMobile)} shrink-0 place-items-center text-muted hover:bg-neutral-soft hover:text-primary`;

  return (
    <div data-debug-id={`shell-main-pane-${sessionId}`} className="relative flex h-full min-h-0 w-full flex-col overflow-hidden bg-canvas">
      <header
        data-debug-id="shell-main-pane-header"
        className={`relative z-20 flex shrink-0 items-center gap-2 border-b border-subtle bg-canvas/90 px-3 backdrop-blur-md ${isMobile ? 'min-h-14' : 'min-h-12'}`}
      >
        {headerLeading ? <div className="flex shrink-0 items-center gap-1">{headerLeading}</div> : null}
        <nav aria-label="Shell" className={`flex min-w-0 flex-1 items-center gap-1 ${isMobile ? 'text-[15px]' : 'text-sm'}`}>
          <span data-debug-id="shell-main-pane-bridge" className="max-w-[40%] shrink-0 truncate text-muted">{bridgeName}</span>
          <span className="shrink-0 text-faint">/</span>
          <button
            type="button"
            data-debug-id="shell-main-pane-switcher-btn"
            aria-haspopup="dialog"
            aria-expanded={switcherOpen}
            title="Switch shell"
            onClick={() => setSwitcherOpen((open) => !open)}
            className={`flex min-w-0 items-center gap-1.5 rounded-md px-1.5 font-semibold text-primary hover:bg-neutral-soft ${isMobile ? 'min-h-11' : 'py-0.5'}`}
          >
            <Icon name="terminal" size={13} className="shrink-0 text-accent" />
            <span className="truncate">{name}</span>
            <Icon name="chevron-down" size={13} className="shrink-0 text-muted" />
          </button>
        </nav>
        {session ? (
          <span
            data-debug-id="shell-main-pane-status"
            className={`hidden shrink-0 items-center gap-1.5 rounded-full px-2 py-0.5 text-[11px] font-medium sm:inline-flex ${exited ? 'bg-neutral-soft text-muted' : 'bg-success-soft text-success'}`}
          >
            <span className={`h-1.5 w-1.5 rounded-full ${exited ? 'bg-muted' : 'bg-success'}`} />
            {exited ? `exited${session.exit_code_set ? ` ${session.exit_code}` : ''}` : session.status}
          </span>
        ) : null}
        <Menu
          align="end"
          label="Shell options"
          open={menuOpen}
          onOpenChange={setMenuOpen}
          className="z-30 w-60 max-w-[calc(100vw-2rem)]"
          trigger={
            <button type="button" data-debug-id="shell-main-pane-menu-btn" aria-label="Shell options" className={iconBtn}>
              <Icon name="more-vertical" size={isMobile ? 22 : 18} />
            </button>
          }
        >
          <Menu.Item data-debug-id="shell-main-pane-restart" disabled={!session || restartState.isLoading} onClick={() => void restartShell({ sessionId })}>
            <Icon name="refresh" size={15} />
            <span>Restart shell</span>
          </Menu.Item>
          <Menu.Item data-debug-id="shell-main-pane-open-page" onClick={() => { window.location.hash = `#/shells/${encodeURIComponent(sessionId)}`; }}>
            <Icon name="file" size={15} />
            <span>Open in Shells page</span>
          </Menu.Item>
          <Menu.Item data-debug-id="shell-main-pane-kill" danger disabled={!session || exited} onClick={() => setConfirmKill(true)}>
            <Icon name="stop" size={15} />
            <span>Kill shell…</span>
          </Menu.Item>
        </Menu>
        <button
          type="button"
          data-debug-id="shell-main-pane-close"
          aria-label="Close pane"
          title="Close pane (the shell keeps running)"
          onClick={onClose}
          className={iconBtn}
        >
          <Icon name="close" size={isMobile ? 20 : 16} />
        </button>
        {headerEnd}
        {switcherOpen && session ? (
          <ShellSwitcher
            current={sessionId}
            bridgeId={session.bridge_id}
            projectId={session.project_id}
            cwd={session.cwd}
            bridgeName={bridgeName}
            openIds={openIds}
            isMobile={isMobile}
            onPick={(id) => { setSwitcherOpen(false); if (id !== sessionId) onSwitch(id); }}
            onClose={() => setSwitcherOpen(false)}
          />
        ) : null}
      </header>

      {exited ? (
        <div data-debug-id="shell-main-pane-exited" className="flex shrink-0 items-center gap-3 border-b border-subtle bg-neutral-soft px-4 py-2 text-sm text-muted">
          <Icon name="info" size={15} />
          <span className="flex-1">Shell exited{session?.exit_code_set ? ` with code ${session.exit_code}` : ''}.</span>
          <button type="button" data-debug-id="shell-main-pane-exited-restart" onClick={() => void restartShell({ sessionId })} disabled={restartState.isLoading} className={`rounded-lg bg-accent px-3 font-semibold text-accent-fg disabled:opacity-50 ${isMobile ? 'h-11' : 'h-8'}`}>Restart</button>
          <button type="button" data-debug-id="shell-main-pane-exited-close" onClick={onClose} className={`rounded-lg border border-subtle px-3 text-primary ${isMobile ? 'h-11' : 'h-8'}`}>Close</button>
        </div>
      ) : null}

      <div className="min-h-0 flex-1">
        <ShellWorkbenchPane key={sessionId} sessionId={sessionId} bridgeId={session?.bridge_id} />
      </div>

      {confirmKill ? (
        <div data-debug-id="shell-main-pane-kill-confirm" role="dialog" aria-modal="true" className="absolute inset-0 z-40 grid place-items-center bg-surface-overlay/80 p-4 backdrop-blur-sm">
          <div className="w-full max-w-sm rounded-2xl border border-subtle bg-surface-raised p-5 shadow-2xl">
            <h3 className="text-base font-semibold text-primary">Kill “{name}”?</h3>
            <p className="mt-1 text-sm text-muted">The process on {bridgeName} is terminated. Closing the pane instead keeps it running.</p>
            {killState.error ? <p className="mt-2 text-sm text-danger">{describeApiError(killState.error) || 'Could not kill the shell.'}</p> : null}
            <div className="mt-4 flex justify-end gap-2">
              <button type="button" data-debug-id="shell-main-pane-kill-cancel" onClick={() => setConfirmKill(false)} className={`rounded-xl border border-subtle px-4 text-primary ${isMobile ? 'h-11' : 'h-9'}`}>Cancel</button>
              <button
                type="button"
                data-debug-id="shell-main-pane-kill-confirm-btn"
                disabled={killState.isLoading}
                onClick={async () => {
                  try { await killShell({ sessionId }).unwrap(); setConfirmKill(false); onClose(); } catch { /* error shown above */ }
                }}
                className={`rounded-xl bg-danger px-4 font-semibold text-white disabled:opacity-50 ${isMobile ? 'h-11' : 'h-9'}`}
              >
                Kill
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </div>
  );
}

function ShellSwitcher({
  current, bridgeId, projectId, cwd, bridgeName, openIds, isMobile, onPick, onClose,
}: {
  current: string; bridgeId: string; projectId: string; cwd: string; bridgeName: string;
  openIds: readonly string[]; isMobile: boolean; onPick: (id: string) => void; onClose: () => void;
}) {
  const [query, setQuery] = useState('');
  const ref = useRef<HTMLDivElement | null>(null);
  const { data } = useListShellsQuery({ status: 'live', limit: 200 });
  const [createShell, createState] = useCreateShellMutation();
  const list = useMemo(() => attachableShells(data?.sessions, { allProjects: true, query }), [data, query]);
  useEffect(() => {
    const onDown = (event: MouseEvent) => { if (ref.current && !ref.current.contains(event.target as Node)) onClose(); };
    const onKey = (event: KeyboardEvent) => { if (event.key === 'Escape') onClose(); };
    document.addEventListener('mousedown', onDown);
    document.addEventListener('keydown', onKey);
    return () => { document.removeEventListener('mousedown', onDown); document.removeEventListener('keydown', onKey); };
  }, [onClose]);

  const row = isMobile ? 'min-h-12' : 'py-2';
  return (
    <div
      ref={ref}
      data-debug-id="shell-main-pane-switcher"
      role="dialog"
      aria-label="Switch shell"
      className={`absolute top-full z-40 mt-1 overflow-hidden rounded-2xl border border-subtle bg-surface-raised shadow-2xl ${isMobile ? 'left-2 right-2' : 'left-3 w-[380px]'}`}
    >
      <div className="border-b border-subtle p-2">
        <input
          autoFocus
          data-debug-id="shell-main-pane-switcher-search"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder="Switch shell…"
          className={`w-full rounded-xl border border-subtle bg-surface px-3 text-primary outline-none focus:border-accent ${isMobile ? 'h-11 text-base' : 'h-9 text-sm'}`}
        />
      </div>
      <ul className="max-h-80 overflow-auto py-1">
        {list.length === 0 ? <li className="px-3 py-4 text-center text-sm text-faint">No running shells.</li> : null}
        {list.map((s) => (
          <li key={s.session_id}>
            <button
              type="button"
              data-debug-id={`shell-main-pane-switcher-item-${s.session_id}`}
              onClick={() => onPick(s.session_id)}
              className={`flex w-full items-center gap-3 px-3 text-left hover:bg-neutral-soft ${row}`}
            >
              <Icon name={s.session_id === current ? 'check' : 'terminal'} size={14} className={s.session_id === current ? 'text-accent' : 'text-muted'} />
              <span className="min-w-0 flex-1">
                <span className="block truncate text-sm font-semibold text-primary">{shellPaneName(s)}</span>
                <span className="block truncate font-mono text-[11px] text-faint">{s.cwd}</span>
              </span>
              {s.session_id !== current && openIds.includes(s.session_id) ? (
                <span className="shrink-0 rounded-full bg-accent/15 px-2 py-0.5 text-[10px] font-semibold text-accent">Open</span>
              ) : null}
            </button>
          </li>
        ))}
      </ul>
      <button
        type="button"
        data-debug-id="shell-main-pane-switcher-new"
        disabled={createState.isLoading}
        onClick={async () => {
          try {
            const created = await createShell(buildInteractiveShellRequest({ bridgeId, cwd, projectId })).unwrap();
            onPick(created.session_id);
          } catch { /* error shown below */ }
        }}
        className={`flex w-full items-center gap-2 border-t border-subtle px-3 text-left text-sm font-semibold text-accent hover:bg-neutral-soft disabled:opacity-50 ${row}`}
      >
        <Icon name="plus" size={15} />
        {createState.isLoading ? 'Starting…' : `New shell on ${bridgeName}`}
      </button>
      {createState.error ? <p className="px-3 pb-2 text-xs text-danger">{describeApiError(createState.error) || 'Could not start a shell.'}</p> : null}
    </div>
  );
}

export default ShellMainPane;
