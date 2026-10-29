import { useEffect, useRef, useState } from 'react';
import Icon from '../Icon';
import { useListBridgesQuery, type Bridge } from '../../api/endpoints/bridgeSupport';
import { pendingBridgeUpdates, type PendingBridgeUpdate } from '../settings/bridgeUpdate';

function preferredHubBridge(bridges: Bridge[] | null | undefined): Bridge | null {
  const rows = Array.isArray(bridges) ? bridges : [];
  return rows.find((bridge) => bridge.runtime_connected === true && String(bridge.status || '').toLowerCase() === 'online') || rows[0] || null;
}

function hubBridgeLabel(bridge: Bridge | null): { label: string; tone: 'success' | 'warning' | 'danger' | 'muted' } {
  if (!bridge) return { label: 'No Bridge connected', tone: 'muted' };
  if (bridge.runtime_connected === true && String(bridge.status || '').toLowerCase() === 'online') return { label: 'Bridge online', tone: 'success' };
  if (String(bridge.status || '').toLowerCase() === 'revoked') return { label: 'Bridge revoked', tone: 'danger' };
  return { label: 'Bridge offline', tone: 'danger' };
}

const toneClass = {
  success: 'bg-success',
  warning: 'bg-warning',
  danger: 'bg-danger',
  muted: 'bg-muted',
};

/**
 * REQ-BTOP-1 / F29: the sidebar Bridge control shows the Hub's view of the
 * user's bridges and pending updates. Installing, enrolling, updating and
 * uninstalling all live in Settings > Bridges; this control only links there.
 */
export default function SidebarUpdateBadge({ onOpen, onManage }: { onOpen: (update: PendingBridgeUpdate) => void; onManage: () => void }) {
  const bridgesQuery = useListBridgesQuery(undefined);
  const [open, setOpen] = useState(false);
  const [checking, setChecking] = useState(false);
  const [operationError, setOperationError] = useState('');
  const rootRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (!open) return;
    const close = (event: PointerEvent) => { if (!rootRef.current?.contains(event.target as Node)) setOpen(false); };
    document.addEventListener('pointerdown', close);
    return () => document.removeEventListener('pointerdown', close);
  }, [open]);

  const bridges = bridgesQuery.data?.bridges as Bridge[] | undefined;
  const hubBridge = preferredHubBridge(bridges);
  const updates = pendingBridgeUpdates(bridges);
  const update = updates[0] || null;
  const status = hubBridgeLabel(hubBridge);
  const version = String(hubBridge?.version || '');
  const summary = `${status.label}${version ? ` · v${version.replace(/^v/, '')}` : ''}`;

  const checkUpdates = async () => {
    setChecking(true);
    setOperationError('');
    try { await bridgesQuery.refetch(); }
    catch (error: any) { setOperationError(String(error?.message || error || 'Unable to check for updates.')); }
    finally { setChecking(false); }
  };

  return (
    <div ref={rootRef} data-debug-id="shell-bridge-status-control" className="relative inline-flex shrink-0">
      <button
        type="button"
        data-debug-id="shell-bridge-status-btn"
        onClick={() => { setOpen((value) => !value); if (!open) void checkUpdates(); }}
        aria-expanded={open}
        aria-haspopup="dialog"
        aria-label={summary}
        title={summary}
        className="inline-flex h-7 items-center gap-1.5 rounded-full border border-subtle bg-surface px-2 text-[10.5px] font-semibold text-muted transition-colors hover:bg-neutral-soft hover:text-primary focus-visible:outline-none focus-visible:shadow-focus"
      >
        <span aria-hidden="true" className={`h-1.5 w-1.5 rounded-full ${toneClass[status.tone]}`} />
        <Icon name="device" size={12} />
        <span>{version ? `Bridge v${version.replace(/^v/, '')}` : 'Bridge'}</span>
        {update ? <Icon name="download" size={11} /> : null}
        <Icon name="chevron-down" size={10} />
      </button>

      {open ? (
        <section
          role="dialog"
          aria-label="Bridge status"
          data-debug-id="shell-bridge-status-popover"
          className="absolute right-0 top-[calc(100%+0.5rem)] z-[90] w-80 rounded-xl border border-subtle bg-surface p-3 text-left shadow-2xl"
        >
          <div className="flex items-start justify-between gap-3">
            <div>
              <div className="flex items-center gap-2 text-sm font-semibold text-primary">
                <span aria-hidden="true" className={`h-2 w-2 rounded-full ${toneClass[status.tone]}`} />
                {status.label}
              </div>
              <p className="mt-1 text-xs text-muted">
                {version ? `Installed version v${version.replace(/^v/, '')}` : 'No installed version detected'}
              </p>
            </div>
            <button
              type="button"
              data-debug-id="shell-bridge-check-update-btn"
              disabled={checking}
              onClick={() => { void checkUpdates(); }}
              className="inline-flex h-8 items-center gap-1 rounded-lg border border-subtle px-2 text-xs font-semibold text-muted hover:bg-neutral-soft hover:text-primary disabled:opacity-50"
            >
              <Icon name="refresh" size={12} /> {checking ? 'Checking…' : 'Check update'}
            </button>
          </div>

          {update ? (
            <button
              type="button"
              data-debug-id="shell-bridge-update-available-btn"
              onClick={() => { setOpen(false); onOpen(update); }}
              className="mt-3 flex w-full items-center justify-between rounded-lg border border-accent/30 bg-accent/10 px-3 py-2 text-xs font-semibold text-accent hover:bg-accent/15"
            >
              <span>Update available</span><span>v{update.latestVersion}</span>
            </button>
          ) : <p className="mt-3 text-xs text-muted">No newer installable Bridge release was reported.</p>}

          <button
            type="button"
            data-debug-id="shell-bridge-manage-btn"
            onClick={() => { setOpen(false); onManage(); }}
            className="mt-3 inline-flex w-full items-center justify-center gap-2 rounded-lg border border-subtle px-3 py-2 text-xs font-semibold text-muted hover:bg-neutral-soft hover:text-primary"
          >
            <Icon name="device" size={13} /> Manage bridges
          </button>

          {operationError ? <p role="alert" data-debug-id="shell-bridge-operation-error" className="mt-3 whitespace-pre-wrap text-xs text-danger">{operationError}</p> : null}
        </section>
      ) : null}
    </div>
  );
}
