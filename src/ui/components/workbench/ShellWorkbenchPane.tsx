import React, { useCallback, useEffect, useRef, useState } from 'react';
import { Button, Icon } from '@ui';
import {
  useGetShellSessionQuery,
  useCreateShellMutation,
  useKillShellMutation,
  useRestartShellMutation,
  type ShellSession,
} from '../../api/endpoints/shells';
import { useAuxTabActions, type AuxTabAction } from '../aux/auxTabActions';
import { ShellTerminalPane } from '../shells/ShellTerminalPane';
import { buildInteractiveShellRequest } from '../shells/interactiveShellLaunch';
import { describeApiError } from '../../utils/bridgeVaultStatus';
import { isTerminal } from '../shells/shellModel';

export interface ShellWorkbenchPaneProps {
  /** The ONE interactive shell session this tab is bound to (absent = start a new one). */
  sessionId?: string;
  bridgeId?: string;
  projectId?: string;
  chainId?: string;
  agentInstanceId?: string;
  defaultCwd?: string;
  cwdReady?: boolean;
  autoCreate?: boolean;
  isActiveTab?: boolean;
  /** Reports the real session once this tab's interactive shell has started (tab rekey). */
  onSelectSession?: (sessionId: string) => void;
  /** Opens ANOTHER shell in a new aux tab (each tab = one interactive shell). */
  onNewShell?: () => void;
}

/**
 * Interactive shell aux tab. One tab is bound to exactly one interactive shell
 * session: there is no session switcher; "New shell" opens another tab. Only
 * interactive shells (kind `shell`) live here; server / run sessions are not
 * shell tabs. The tab renders the terminal only; verbs are in the aux ⋮ menu.
 */
export function ShellWorkbenchPane({
  sessionId,
  bridgeId,
  projectId,
  chainId,
  defaultCwd,
  cwdReady = true,
  autoCreate = false,
  onSelectSession,
  onNewShell,
}: ShellWorkbenchPaneProps) {
  const [boundSessionId, setBoundSessionId] = useState<string>(sessionId || '');
  useEffect(() => {
    if (sessionId) setBoundSessionId(sessionId);
  }, [sessionId]);

  const { data: sessionData } = useGetShellSessionQuery(
    { sessionId: boundSessionId },
    { skip: !boundSessionId },
  );
  const activeSession: ShellSession | null =
    sessionData && (sessionData as ShellSession).session_id ? (sessionData as ShellSession) : null;

  const [createShell, { isLoading: isCreatingShell, error: createShellError }] = useCreateShellMutation();
  const [killShell, { isLoading: isKilling }] = useKillShellMutation();
  const [restartShell, { isLoading: isRestarting }] = useRestartShellMutation();
  const autoCreateAttemptedRef = useRef(false);
  const [autoCreateFailed, setAutoCreateFailed] = useState(false);

  const startInteractiveShell = useCallback(async () => {
    if (!bridgeId || isCreatingShell) return;
    setAutoCreateFailed(false);
    try {
      const session = await createShell(
        buildInteractiveShellRequest({ bridgeId, cwd: defaultCwd, chainId, projectId }),
      ).unwrap();
      setBoundSessionId(session.session_id);
      onSelectSession?.(session.session_id);
    } catch {
      setAutoCreateFailed(true);
    }
  }, [bridgeId, chainId, createShell, defaultCwd, isCreatingShell, onSelectSession, projectId]);

  useEffect(() => {
    if (!autoCreate || !cwdReady || sessionId || !bridgeId || autoCreateAttemptedRef.current) return;
    autoCreateAttemptedRef.current = true;
    void startInteractiveShell();
  }, [autoCreate, bridgeId, cwdReady, sessionId, startInteractiveShell]);

  const actions: AuxTabAction[] = [];
  if (activeSession) {
    if (isTerminal(activeSession)) {
      actions.push({
        id: 'shell-restart',
        label: 'Restart shell',
        icon: 'refresh',
        disabled: isRestarting,
        onSelect: () => void restartShell({ sessionId: activeSession.session_id }),
      });
    } else {
      actions.push({
        id: 'shell-kill',
        label: 'Kill shell',
        icon: 'close',
        tone: 'danger',
        disabled: isKilling,
        onSelect: () => void killShell({ sessionId: activeSession.session_id }),
      });
    }
  }
  if (onNewShell) {
    actions.push({ id: 'shell-new', label: 'New shell (new tab)', icon: 'plus', onSelect: onNewShell });
  }
  useAuxTabActions(actions);

  return (
    <div
      data-debug-id="workbench-shell-pane"
      className="flex h-full min-h-0 w-full flex-col overflow-hidden bg-surface text-primary"
    >
      <div className="relative flex flex-1 min-h-0 w-full flex-col overflow-hidden">
        {activeSession ? (
          <div className="flex flex-1 min-h-0 w-full flex-col overflow-hidden p-2">
            <ShellTerminalPane key={activeSession.session_id} session={activeSession} />
          </div>
        ) : (
          <div
            data-debug-id="workbench-shell-empty"
            className="flex flex-1 flex-col items-center justify-center gap-3 p-6 text-center"
          >
            <Icon name="terminal" size={24} className="text-muted" />
            <div className="space-y-1">
              <p className="text-sm font-semibold text-primary">
                {isCreatingShell || (boundSessionId && !autoCreateFailed)
                  ? 'Starting interactive shell…'
                  : autoCreateFailed
                    ? 'Could not start shell'
                    : !bridgeId
                      ? 'No bridge for this agent'
                      : 'Waiting for the project directory…'}
              </p>
              {autoCreateFailed ? (
                <p className="max-w-xs text-xs text-muted">
                  {describeApiError(createShellError) || 'The bridge did not start the interactive shell.'}
                </p>
              ) : null}
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
          </div>
        )}
      </div>
    </div>
  );
}

export default ShellWorkbenchPane;
