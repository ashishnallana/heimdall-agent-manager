import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useDispatch } from 'react-redux';
import { Badge, Button, Icon, Spinner, StatusPill } from '@ui';
import {
  useListShellsQuery,
  useGetShellSessionQuery,
  useCreateShellMutation,
  useKillShellMutation,
  useRestartShellMutation,
  useSignalShellMutation,
  type ShellSession,
} from '../../api/endpoints/shells';
import { openPreviewInWorkbench } from '../../store/workbenchSlice';
import { ShellTerminalPane } from '../shells/ShellTerminalPane';
import { ShellLogViewer } from '../shells/ShellLogViewer';
import { NewShellDialog } from '../shells/NewShellDialog';
import { SetShellPortDialog } from '../shells/SetShellPortDialog';
import { buildInteractiveShellRequest } from '../shells/interactiveShellLaunch';
import { describeApiError } from '../../utils/bridgeVaultStatus';
import {
  isTerminal,
  kindLabel,
  shellTitle,
  statusPresentation,
  supportsLivePreview,
} from '../shells/shellModel';

export interface ShellWorkbenchPaneProps {
  sessionId?: string;
  bridgeId?: string;
  projectId?: string;
  chainId?: string;
  agentInstanceId?: string;
  defaultCwd?: string;
  cwdReady?: boolean;
  autoCreate?: boolean;
  isActiveTab?: boolean;
  onSelectSession?: (sessionId: string) => void;
  onOpenPreview?: (session: ShellSession) => void;
}

export function ShellWorkbenchPane({
  sessionId,
  bridgeId,
  projectId,
  chainId,
  defaultCwd,
  cwdReady = true,
  autoCreate = false,
  onSelectSession,
  onOpenPreview,
}: ShellWorkbenchPaneProps) {
  const dispatch = useDispatch();

  const { data: listData, isLoading: isListLoading } = useListShellsQuery(
    {
      bridgeId: bridgeId || undefined,
      projectId: projectId || undefined,
      chainId: chainId || undefined,
    },
    { pollingInterval: 15000 },
  );

  const sessions: ShellSession[] = useMemo(() => listData?.sessions ?? [], [listData]);

  const [selectedSessionId, setSelectedSessionId] = useState<string>(sessionId || '');
  useEffect(() => {
    if (sessionId) {
      setSelectedSessionId(sessionId);
    } else if (!autoCreate && !selectedSessionId && sessions.length > 0) {
      setSelectedSessionId(sessions[0].session_id);
    }
  }, [autoCreate, sessionId, selectedSessionId, sessions]);

  const { data: singleSessionData } = useGetShellSessionQuery(
    { sessionId: selectedSessionId },
    { skip: !selectedSessionId },
  );

  const activeSession: ShellSession | null = useMemo(() => {
    if (singleSessionData && (singleSessionData as ShellSession).session_id) {
      return singleSessionData as ShellSession;
    }
    return sessions.find((s) => s.session_id === selectedSessionId) || null;
  }, [singleSessionData, sessions, selectedSessionId]);

  const [createShell, { isLoading: isCreatingShell, error: createShellError }] = useCreateShellMutation();
  const [killShell, { isLoading: isKilling }] = useKillShellMutation();
  const [restartShell, { isLoading: isRestarting }] = useRestartShellMutation();
  const [signalShell, { isLoading: isSignaling }] = useSignalShellMutation();

  const [showNewShellDialog, setShowNewShellDialog] = useState(false);
  const [showPortDialog, setShowPortDialog] = useState(false);
  const [viewMode, setViewMode] = useState<'terminal' | 'log'>('terminal');
  const autoCreateAttemptedRef = useRef(false);
  const [autoCreateFailed, setAutoCreateFailed] = useState(false);

  useEffect(() => {
    if (!activeSession) return;
    if (activeSession.kind === 'shell') {
      setViewMode('terminal');
    } else {
      const running = activeSession.status === 'running' || activeSession.status === 'starting';
      setViewMode(running ? 'terminal' : 'log');
    }
  }, [activeSession?.session_id, activeSession?.kind]);

  const handleSelectSession = useCallback(
    (nextId: string) => {
      setSelectedSessionId(nextId);
      onSelectSession?.(nextId);
    },
    [onSelectSession],
  );

  const startInteractiveShell = useCallback(async () => {
    if (!bridgeId || isCreatingShell) return;
    setAutoCreateFailed(false);
    try {
      const session = await createShell(buildInteractiveShellRequest({
        bridgeId,
        cwd: defaultCwd,
        chainId,
        projectId,
      })).unwrap();
      handleSelectSession(session.session_id);
    } catch {
      setAutoCreateFailed(true);
    }
  }, [bridgeId, chainId, createShell, defaultCwd, handleSelectSession, isCreatingShell, projectId]);

  useEffect(() => {
    if (!autoCreate || !cwdReady || sessionId || !bridgeId || autoCreateAttemptedRef.current) return;
    autoCreateAttemptedRef.current = true;
    void startInteractiveShell();
  }, [autoCreate, bridgeId, cwdReady, sessionId, startInteractiveShell]);

  const handleOpenPreview = useCallback(
    (session: ShellSession) => {
      if (onOpenPreview) {
        onOpenPreview(session);
        return;
      }
      dispatch(
        openPreviewInWorkbench({
          sessionId: session.session_id,
          label: session.label || session.cmd || session.session_id,
          port: session.server_port,
        }),
      );
    },
    [dispatch, onOpenPreview],
  );

  const presentation = activeSession ? statusPresentation(activeSession) : null;
  const isCaptureless = activeSession?.kind === 'shell';

  return (
    <div
      data-debug-id="workbench-shell-pane"
      className="flex h-full min-h-0 w-full flex-col overflow-hidden bg-surface text-primary"
    >
      {/* Top Session Toolbar */}
      <div
        data-debug-id="workbench-shell-toolbar"
        className="flex h-9 shrink-0 items-center justify-between gap-2 border-b border-subtle bg-surface-raised/60 px-3"
      >
        <div className="flex min-w-0 items-center gap-2">
          <Icon name="terminal" size={14} className="shrink-0 text-muted" />
          {sessions.length > 0 ? (
            <select
              aria-label="Select shell session"
              data-debug-id="workbench-shell-session-select"
              value={selectedSessionId}
              onChange={(e) => handleSelectSession(e.target.value)}
              className="max-w-[220px] truncate rounded border border-subtle bg-surface px-2 py-0.5 text-xs font-medium text-primary focus:border-accent focus:outline-none"
            >
              {sessions.map((s) => (
                <option key={s.session_id} value={s.session_id}>
                  {shellTitle(s)} ({s.status})
                </option>
              ))}
            </select>
          ) : (
            <span className="text-xs font-medium text-muted">
              {isListLoading ? 'Loading sessions…' : 'No active shell sessions'}
            </span>
          )}

          {activeSession && presentation ? (
            <>
              <StatusPill tone={presentation.tone} title={presentation.title}>
                {presentation.label}
              </StatusPill>
              <Badge tone="neutral">{kindLabel(activeSession.kind)}</Badge>
              {activeSession.server_port > 0 ? (
                <Badge tone="info">:{activeSession.server_port}</Badge>
              ) : null}
            </>
          ) : null}
        </div>

        <div className="flex shrink-0 items-center gap-1.5">
          {activeSession && !isCaptureless ? (
            <div
              data-debug-id="workbench-shell-view-mode-toggle"
              className="flex items-center rounded border border-subtle bg-surface p-0.5"
            >
              <button
                type="button"
                onClick={() => setViewMode('terminal')}
                className={`rounded px-1.5 py-0.5 text-[11px] font-medium ${
                  viewMode === 'terminal' ? 'bg-accent/15 text-accent' : 'text-muted hover:text-primary'
                }`}
              >
                Terminal
              </button>
              <button
                type="button"
                onClick={() => setViewMode('log')}
                className={`rounded px-1.5 py-0.5 text-[11px] font-medium ${
                  viewMode === 'log' ? 'bg-accent/15 text-accent' : 'text-muted hover:text-primary'
                }`}
              >
                Log
              </button>
            </div>
          ) : null}

          {activeSession && supportsLivePreview(activeSession) ? (
            <button
              type="button"
              data-debug-id="workbench-shell-open-preview-btn"
              onClick={() => handleOpenPreview(activeSession)}
              className="inline-flex items-center gap-1 rounded border border-subtle bg-surface px-2 py-0.5 text-[11px] font-medium text-accent hover:bg-accent/10"
            >
              <Icon name="eye" size={12} />
              <span>Preview :{activeSession.server_port}</span>
            </button>
          ) : null}

          {activeSession ? (
            <>
              <button
                type="button"
                onClick={() => setShowPortDialog(true)}
                title="Set server port"
                data-debug-id="workbench-shell-set-port-btn"
                className="rounded border border-subtle bg-surface px-1.5 py-0.5 text-[11px] text-muted hover:bg-neutral-soft hover:text-primary"
              >
                Port
              </button>
              {!isTerminal(activeSession) ? (
                <>
                  <button
                    type="button"
                    disabled={isSignaling}
                    onClick={() => void signalShell({ sessionId: activeSession.session_id, signal: 2 })}
                    title="Send SIGINT (Ctrl+C)"
                    data-debug-id="workbench-shell-sigint-btn"
                    className="rounded border border-subtle bg-surface px-1.5 py-0.5 text-[11px] text-muted hover:bg-neutral-soft hover:text-primary"
                  >
                    SIGINT
                  </button>
                  <button
                    type="button"
                    disabled={isKilling}
                    onClick={() => void killShell({ sessionId: activeSession.session_id })}
                    title="Kill shell session"
                    data-debug-id="workbench-shell-kill-btn"
                    className="rounded border border-subtle bg-surface px-1.5 py-0.5 text-[11px] text-danger hover:bg-danger-soft"
                  >
                    Kill
                  </button>
                </>
              ) : (
                <button
                  type="button"
                  disabled={isRestarting}
                  onClick={() => void restartShell({ sessionId: activeSession.session_id })}
                  title="Restart shell session"
                  data-debug-id="workbench-shell-restart-btn"
                  className="rounded border border-subtle bg-surface px-1.5 py-0.5 text-[11px] text-accent hover:bg-accent/10"
                >
                  Restart
                </button>
              )}
            </>
          ) : null}

          <Button
            size="sm"
            variant="secondary"
            disabled={isCreatingShell}
            data-debug-id="workbench-shell-new-btn"
            onClick={() => setShowNewShellDialog(true)}
          >
            {isCreatingShell ? <Spinner size="sm" /> : <Icon name="plus" size={12} />}
            <span>New Shell</span>
          </Button>
        </div>
      </div>

      {/* Body */}
      <div className="relative flex flex-1 min-h-0 w-full flex-col overflow-hidden">
        {activeSession ? (
          viewMode === 'terminal' || isCaptureless ? (
            <div className="flex flex-1 min-h-0 w-full flex-col overflow-hidden p-2">
              <ShellTerminalPane key={activeSession.session_id} session={activeSession} />
            </div>
          ) : (
            <div className="flex flex-1 min-h-0 w-full flex-col overflow-y-auto p-3">
              <ShellLogViewer session={activeSession} showSessionVerbs={false} />
            </div>
          )
        ) : (
          <div
            data-debug-id="workbench-shell-empty"
            className="flex flex-1 flex-col items-center justify-center gap-3 p-6 text-center"
          >
            <Icon name="terminal" size={24} className="text-muted" />
            <div className="space-y-1">
              <p className="text-sm font-semibold text-primary">
                {isCreatingShell
                  ? 'Starting interactive shell…'
                  : autoCreateFailed
                    ? 'Could not start shell'
                    : 'No shell session selected'}
              </p>
              <p className="text-xs text-muted max-w-xs">
                {autoCreateFailed
                  ? describeApiError(createShellError) || 'The bridge did not start the interactive shell.'
                  : 'Start a new interactive shell or server session on your bridge to run commands directly inside the workbench.'}
              </p>
            </div>
            {autoCreateFailed ? (
              <Button
                size="sm"
                variant="primary"
                data-debug-id="workbench-shell-auto-retry-btn"
                disabled={isCreatingShell}
                onClick={() => void startInteractiveShell()}
              >
                <Icon name="refresh" size={14} />
                <span>Retry</span>
              </Button>
            ) : null}
            <Button
              size="sm"
              variant="primary"
              data-debug-id="workbench-shell-empty-create-btn"
              onClick={() => setShowNewShellDialog(true)}
            >
              <Icon name="plus" size={14} />
              <span>Start Shell Session</span>
            </Button>
          </div>
        )}
      </div>

      {showNewShellDialog ? (
        <NewShellDialog
          bridgeId={bridgeId}
          projectId={projectId}
          defaultCwd={defaultCwd}
          chainId={chainId}
          onClose={() => setShowNewShellDialog(false)}
          onCreated={(createdSessionId) => {
            setShowNewShellDialog(false);
            handleSelectSession(createdSessionId);
          }}
        />
      ) : null}

      {activeSession && showPortDialog ? (
        <SetShellPortDialog
          session={activeSession}
          onClose={() => setShowPortDialog(false)}
        />
      ) : null}
    </div>
  );
}

export default ShellWorkbenchPane;
