import { useState, useSyncExternalStore } from 'react';
import { Alert, Button, Spinner } from '@ui';
import BridgeOperationRail from './BridgeOperationRail';
import type { DesktopBridgeManagerApi } from '../../bridge/desktopBridge';
import { desktopBridgeSession, runDesktopBridgeOperation, subscribeDesktopBridgeSession } from '../../bridge/desktopBridgeSession';

/** Shared local operation presentation. Never used for remote Hub updates. */
export default function BridgeOperationFeedback({ manager }: { manager: DesktopBridgeManagerApi }) {
  const session = useSyncExternalStore(subscribeDesktopBridgeSession, desktopBridgeSession);
  const [error, setError] = useState('');
  const run = session.lastRun;
  if (!run || run.kind === 'setup') return null;
  const busy = Boolean(session.operation);
  const failed = Boolean(session.wizard.failedStep || session.wizard.cancelled);
  if (!busy && !failed && !session.wizard.completed) return null;
  const name = run.kind === 'update' ? 'Update' : run.kind === 'reenroll' ? 'Re-enrollment' : 'Uninstall';
  return <section data-debug-id="settings-bridge-wizard-result" className="mt-4 min-w-0 space-y-3">
    <BridgeOperationRail label={name} debugId="local-bridge-operation-rail" items={[
      { id: 'review', label: 'Review', state: 'done' },
      { id: 'run', label: name, state: busy ? 'current' : 'done' },
      { id: 'result', label: 'Result', state: busy ? 'todo' : 'current' },
    ]} />
    {busy ? <p role="status" className="flex items-center gap-2 text-sm text-muted"><Spinner size="sm" />{name} in progress…</p>
      : failed ? <Alert tone={session.wizard.cancelled ? 'neutral' : 'danger'}>{name} {session.wizard.cancelled ? 'cancelled' : 'failed'}{session.wizard.error ? `: ${session.wizard.error}` : ''}{session.wizard.rolledBack ? ' Changes were rolled back.' : ''}</Alert>
      : session.wizard.completed ? <Alert tone="success">{name} completed</Alert> : null}
    {session.log.length ? <pre data-debug-id="settings-bridge-wizard-log" aria-live="polite" className="max-h-56 overflow-auto whitespace-pre-wrap break-all rounded-lg border border-subtle bg-canvas p-3 font-mono text-xs text-muted">{session.log.join('\n')}</pre> : null}
    {error ? <Alert tone="danger">{error}</Alert> : null}
    <div className="flex flex-wrap gap-2">
      {!busy && failed ? <Button size="sm" variant="secondary" data-debug-id="settings-bridge-wizard-retry" onClick={() => {
        if (run.target) void runDesktopBridgeOperation(manager, run.kind, run.target, run.options).then(setError);
      }}>Retry {name.toLowerCase()}</Button> : null}
      {busy && (run.kind !== 'reenroll' || !session.wizard.pairing) ? <Button size="sm" variant="ghost" data-debug-id="settings-bridge-operation-cancel" onClick={() => void manager.cancel()}>Cancel</Button> : null}
      {session.wizard.steps.find((step) => step.log)?.log ? <Button size="sm" variant="ghost" data-debug-id="settings-bridge-operation-open-log" onClick={() => void manager.openLog(String(session.wizard.steps.find((step) => step.log)?.log))}>Open log file</Button> : null}
      {session.log.length ? <Button size="sm" variant="ghost" onClick={() => void navigator.clipboard?.writeText(session.log.join('\n'))}>Copy log</Button> : null}
    </div>
  </section>;
}
