import { useEffect, useMemo, useRef, useState } from 'react';
import type { KeyboardEvent as ReactKeyboardEvent } from 'react';
import { Icon, Modal } from '@ui';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import { useListProjectsQuery } from '../../api/endpoints/projects';
import { useListShellsQuery } from '../../api/endpoints/shells';
import { bridgeLabel } from '../../utils/bridgeLaunchOptions';
import { attachableShells, shellPaneName, shellUptime } from '../shells/shellPaneModel';
import { navigateIndex, selectionDirectionForEvent } from '../chains/taskChainSelectorLogic';

export interface RunningShellSelectorModalProps {
  open: boolean;
  onClose: () => void;
  onSelectShell: (sessionId: string) => void;
}

/** Reusable all-project running-shell chooser for whole-app and pane destinations. */
export function RunningShellSelectorModal({ open, onClose, onSelectShell }: RunningShellSelectorModalProps) {
  const [query, setQuery] = useState('');
  const [activeIndex, setActiveIndex] = useState(0);
  const searchRef = useRef<HTMLInputElement>(null);
  const listRef = useRef<HTMLUListElement>(null);
  const shellsQuery = useListShellsQuery({ status: 'live', limit: 200 }, { skip: !open });
  const bridgesQuery = useListBridgesQuery(undefined, { skip: !open });
  const projectsQuery = useListProjectsQuery(undefined, { skip: !open });
  const sessions = useMemo(
    () => attachableShells(shellsQuery.data?.sessions, { allProjects: true, query }),
    [query, shellsQuery.data?.sessions],
  );

  useEffect(() => {
    if (!open) return;
    setQuery('');
    setActiveIndex(0);
    const frame = requestAnimationFrame(() => searchRef.current?.focus());
    return () => cancelAnimationFrame(frame);
  }, [open]);

  useEffect(() => {
    setActiveIndex((current) => (sessions.length === 0 ? 0 : Math.min(current, sessions.length - 1)));
  }, [sessions.length]);

  useEffect(() => {
    if (!open) return;
    const active = listRef.current?.querySelector<HTMLElement>(`[data-shell-index="${activeIndex}"]`);
    active?.scrollIntoView?.({ block: 'nearest' });
  }, [activeIndex, open]);

  const selectShell = (sessionId: string) => {
    onSelectShell(sessionId);
    onClose();
  };

  const handleSearchKeyDown = (event: ReactKeyboardEvent<HTMLInputElement>) => {
    const direction = selectionDirectionForEvent(event);
    if (direction) {
      event.preventDefault();
      setActiveIndex((current) => navigateIndex(current, sessions.length, direction));
      return;
    }
    if (event.key === 'Enter') {
      const selected = sessions[activeIndex];
      if (!selected) return;
      event.preventDefault();
      selectShell(selected.session_id);
    }
  };

  const bridgeName = (bridgeId: string) => {
    const bridge = (bridgesQuery.data?.bridges || []).find((item) => item.bridge_id === bridgeId);
    return bridgeLabel(bridge) || bridgeId;
  };
  const projectName = (projectId: string | undefined) => {
    const project = (projectsQuery.data?.projects || []).find((item: any) => item.project_id === projectId);
    return String(project?.name || 'No project');
  };

  return (
    <Modal open={open} onOpenChange={(next) => { if (!next) onClose(); }} title="Open running shell" size="lg" data-debug-id="running-shell-selector-modal">
      <Modal.Body>
        <div className="relative mb-3">
          <Icon name="search" size={15} className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-faint" />
          <input
            ref={searchRef}
            data-debug-id="running-shell-selector-search-input"
            role="combobox"
            aria-expanded="true"
            aria-controls="running-shell-selector-listbox"
            aria-activedescendant={sessions.length ? `running-shell-option-${activeIndex}` : undefined}
            value={query}
            onChange={(event) => { setQuery(event.target.value); setActiveIndex(0); }}
            onKeyDown={handleSearchKeyDown}
            placeholder="Search shells across all projects…"
            className="min-h-10 w-full rounded-xl border border-subtle bg-surface px-3 pl-9 text-sm text-primary outline-none focus:border-accent"
          />
        </div>
        <ul ref={listRef} id="running-shell-selector-listbox" role="listbox" aria-label="Running shells" data-debug-id="running-shell-selector-list" className="max-h-[min(65vh,40rem)] overflow-y-auto rounded-2xl border border-subtle bg-surface">
          {shellsQuery.isLoading ? <li className="px-4 py-6 text-center text-sm text-faint">Loading shells…</li> : null}
          {!shellsQuery.isLoading && sessions.length === 0 ? <li className="px-4 py-6 text-center text-sm text-faint">No running shells match this search.</li> : null}
          {sessions.map((session, index) => (
            <li key={session.session_id} role="none" className="border-b border-subtle last:border-b-0">
              <button
                type="button"
                id={`running-shell-option-${index}`}
                role="option"
                aria-selected={index === activeIndex}
                data-shell-index={index}
                data-debug-id={`running-shell-selector-row-${session.session_id}`}
                onMouseEnter={() => setActiveIndex(index)}
                onClick={() => selectShell(session.session_id)}
                className={`flex min-h-16 w-full items-center gap-3 px-4 py-3 text-left hover:bg-neutral-soft ${index === activeIndex ? 'bg-accent/10 ring-1 ring-inset ring-accent/30' : ''}`}
              >
                <span className="grid h-9 w-9 shrink-0 place-items-center rounded-xl bg-neutral-soft text-muted"><Icon name="terminal" size={16} /></span>
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-sm font-semibold text-primary">{shellPaneName(session)}</span>
                  <span className="block truncate font-mono text-[11px] text-muted">{projectName(session.project_id)} · {bridgeName(session.bridge_id)} · {session.cwd || '~'}</span>
                </span>
                <span className="shrink-0 text-[11px] text-faint">{shellUptime(session.started_at)}</span>
              </button>
            </li>
          ))}
        </ul>
      </Modal.Body>
    </Modal>
  );
}

export default RunningShellSelectorModal;
