import { useEffect, useState } from 'react';
import { VaultText } from '../vault/VaultText';
import type { InstanceReconfiguration } from '../../api/endpoints/agents';

function permissionLabel(mode: string | undefined): string {
  return mode === 'ask' ? 'Approvals required' : mode === 'yolo' ? 'Permissions bypassed' : 'Agent default permissions';
}

export default function InstanceReconfigurationProgress({ operation }: { operation: InstanceReconfiguration }) {
  const ready = operation.phase === 'ready';
  const recoveryStopped = operation.phase === 'failed' && operation.failure_code === 'recovery_stopped';
  const forceStopping = operation.failure_code === 'force_stopping';
  const completionKey = `${operation.operation_id}:${operation.revision}`;
  const [dismissedCompletion, setDismissedCompletion] = useState('');
  const completedAt = Date.parse(operation.updated_at || '');
  const remaining = Number.isFinite(completedAt) ? Math.min(5000, Math.max(0, 5000 - (Date.now() - completedAt))) : 5000;
  useEffect(() => {
    if (!ready) return;
    if (remaining === 0) { setDismissedCompletion(completionKey); return; }
    const timer = window.setTimeout(() => setDismissedCompletion(completionKey), remaining);
    return () => window.clearTimeout(timer);
  }, [completionKey, ready, operation.updated_at]);
  // Completed history must not reappear as a runtime banner after reload.
  if (ready && (dismissedCompletion === completionKey || remaining === 0)) return null;
  const failed = operation.phase === 'failed' || operation.phase === 'recovery_required';
  const permissionChanged = (operation.source?.permission_mode || '') !== (operation.destination?.permission_mode || '');
  const sourceStatus = operation.source_stopped ? 'Stopped' : failed ? 'Stop not confirmed' : operation.phase === 'stopping' ? 'Stopping…' : 'Waiting';
  const destinationStatus = recoveryStopped ? 'Stopped' : forceStopping ? 'Stopping…' : ready ? 'Ready' : !operation.source_stopped ? 'Not started' : failed ? 'Needs attention' : operation.destination_committed ? 'Starting…' : 'Waiting';
  return (
    <div data-debug-id="conversation-reconfiguration-progress" role="status" aria-live="polite" className="mb-3 rounded-xl border border-subtle bg-neutral-soft px-4 py-3">
      <div className="mb-2 text-sm font-semibold text-primary">{recoveryStopped ? 'Agent stopped' : forceStopping ? 'Force stopping agent' : ready ? 'Configuration applied' : failed ? 'Configuration change needs attention' : 'Applying configuration'}</div>
      {[{ key: 'source', title: 'Stopping on', config: operation.source, status: sourceStatus, complete: operation.source_stopped }, { key: 'destination', title: 'Starting on', config: operation.destination, status: destinationStatus, complete: ready }].map(row => (
        <div key={row.key} data-debug-id={`conversation-reconfiguration-${row.key}`} className="flex min-w-0 items-start justify-between gap-3 py-1.5">
          <div className="min-w-0">
            <div className="text-xs text-muted">{row.title}</div>
            <div className="break-words text-sm font-medium text-primary">{row.config.bridge_label || row.config.bridge_id} · {row.config.project_id ? <VaultText value={row.config.project_label || row.config.project_id} fallback="Project" /> : 'No project'}</div>
            <div className="break-words text-xs text-muted">{row.config.provider} · {row.config.model}{permissionChanged ? ` · ${permissionLabel(row.config.permission_mode)}` : ''}</div>
          </div>
          <span className={`shrink-0 rounded-full px-2 py-1 text-xs ${row.complete ? 'text-success' : failed && ((row.key === 'source' && !operation.source_stopped) || (row.key === 'destination' && operation.source_stopped)) ? 'text-danger' : row.status.endsWith('…') ? 'text-accent' : 'text-muted'}`}>{row.status}</span>
        </div>
      ))}
      {operation.failure_message ? <p className={`mt-2 text-xs ${recoveryStopped ? 'text-muted' : 'text-danger'}`}>{operation.failure_message}{!recoveryStopped ? ' This conversation remains read-only until recovery is confirmed.' : ''}</p> : null}
    </div>
  );
}
