import { useEffect, useMemo, useRef, useState } from 'react';
import Icon from '../Icon';
import { useListBridgesQuery, type Bridge } from '../../api/endpoints/bridgeSupport';
import { desktopBridgeManager, desktopBridgeStatusLabel, type DesktopBridgeEnrollmentEvent, type DesktopBridgeStatus } from '../../bridge/desktopBridge';
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
 * REQ-BTOP-1 / REQ-BTOP-2: persistent top-bar Bridge control. It combines the
 * Hub's update knowledge with this Mac's main-process status. Browser builds
 * retain the Hub-only view; packaged macOS builds also install and enroll the
 * signed Bridge embedded in the DMG.
 */
export default function SidebarUpdateBadge({ onOpen }: { onOpen: (update: PendingBridgeUpdate) => void }) {
  const bridgesQuery = useListBridgesQuery(undefined);
  const manager = useMemo(() => desktopBridgeManager(), []);
  const [desktop, setDesktop] = useState<DesktopBridgeStatus | null>(null);
  const [open, setOpen] = useState(false);
  const [checking, setChecking] = useState(false);
  const [operationError, setOperationError] = useState('');
  const [pairing, setPairing] = useState<{ code: string; url: string } | null>(null);
  const [enrollmentMessage, setEnrollmentMessage] = useState('');
  const rootRef = useRef<HTMLDivElement | null>(null);

  const refreshDesktop = async () => {
    if (!manager) return null;
    const status = await manager.getStatus();
    setDesktop(status);
    return status;
  };

  useEffect(() => {
    if (!manager) return;
    let active = true;
    void manager.getStatus().then((status) => { if (active) setDesktop(status); });
    const timer = window.setInterval(() => { void manager.getStatus().then((status) => { if (active) setDesktop(status); }); }, 15_000);
    const unsubscribe = manager.onEnrollmentEvent((event: DesktopBridgeEnrollmentEvent) => {
      if (!active) return;
      if (event.type === 'pairing' && event.code && event.url) {
        setPairing({ code: event.code, url: event.url });
        setEnrollmentMessage('Approval page opened in your browser. Enter this pairing code.');
      } else if (event.type === 'complete') {
        setEnrollmentMessage(event.message || 'Bridge enrollment complete.');
        void refreshDesktop();
      } else if (event.type === 'error') {
        setOperationError(event.message || 'Bridge enrollment failed.');
      }
    });
    return () => { active = false; window.clearInterval(timer); unsubscribe?.(); };
  }, [manager]); // eslint-disable-line react-hooks/exhaustive-deps

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
  const status = desktop?.supported ? desktopBridgeStatusLabel(desktop) : hubBridgeLabel(hubBridge);
  const version = desktop?.supported
    ? (desktop.installedVersion || desktop.bundledVersion)
    : String(hubBridge?.version || '');
  const summary = `${status.label}${version ? ` · v${version.replace(/^v/, '')}` : ''}`;

  const checkUpdates = async () => {
    setChecking(true);
    setOperationError('');
    try { await Promise.all([bridgesQuery.refetch(), refreshDesktop()]); }
    catch (error: any) { setOperationError(String(error?.message || error || 'Unable to check for updates.')); }
    finally { setChecking(false); }
  };

  useEffect(() => {
    if (!manager) return;
    return manager.onCheckUpdatesRequested(() => {
      setOpen(true);
      void checkUpdates();
    });
  }, [manager]); // eslint-disable-line react-hooks/exhaustive-deps

  const install = async () => {
    if (!manager) return;
    setChecking(true);
    setOperationError('');
    const result = await manager.installBundled().catch((error: any) => ({ ok: false, error: String(error?.message || error) } as any));
    if (result?.status) setDesktop(result.status);
    if (!result?.ok) setOperationError(result?.error || 'Bridge installation failed.');
    else await refreshDesktop();
    setChecking(false);
  };

  const enroll = async () => {
    if (!manager) return;
    setOperationError('');
    setPairing(null);
    setEnrollmentMessage('Starting browser-approved enrollment…');
    const result = await manager.startEnrollment().catch((error: any) => ({ ok: false, error: String(error?.message || error) }));
    if (!result.ok) setOperationError(result.error || 'Unable to start enrollment.');
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
              {desktop?.bundledVersion ? <p className="mt-0.5 text-[11px] text-faint">Packaged version v{desktop.bundledVersion}</p> : null}
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

          {desktop?.supported && !desktop.installed ? (
            <button
              type="button"
              data-debug-id="shell-bridge-install-btn"
              disabled={checking || !desktop.packaged}
              onClick={() => { void install(); }}
              className="mt-3 inline-flex w-full items-center justify-center gap-2 rounded-lg bg-accent px-3 py-2 text-xs font-semibold text-on-accent hover:opacity-90 disabled:opacity-50"
            >
              <Icon name="download" size={13} /> Install packaged Bridge
            </button>
          ) : null}

          {desktop?.supported && desktop.installed && !desktop.enrolled ? (
            <button
              type="button"
              data-debug-id="shell-bridge-enroll-btn"
              onClick={() => { void enroll(); }}
              className="mt-3 inline-flex w-full items-center justify-center gap-2 rounded-lg bg-accent px-3 py-2 text-xs font-semibold text-on-accent hover:opacity-90"
            >
              <Icon name="device" size={13} /> Enroll this Mac
            </button>
          ) : null}

          {pairing ? (
            <div data-debug-id="shell-bridge-pairing-code" className="mt-3 rounded-lg border border-warning/30 bg-warning-soft p-3">
              <p className="text-[11px] text-warning">{enrollmentMessage}</p>
              <div className="mt-2 flex items-center justify-between gap-2">
                <code className="select-all text-sm font-bold tracking-wide text-primary">{pairing.code}</code>
                <button
                  type="button"
                  data-debug-id="shell-bridge-copy-pairing-code-btn"
                  onClick={() => { void navigator.clipboard.writeText(pairing.code); }}
                  className="inline-flex h-8 items-center gap-1 rounded-lg border border-subtle px-2 text-xs font-semibold text-muted hover:bg-neutral-soft"
                ><Icon name="copy" size={12} /> Copy</button>
              </div>
            </div>
          ) : enrollmentMessage ? <p className="mt-3 text-xs text-muted">{enrollmentMessage}</p> : null}

          {operationError ? <p role="alert" data-debug-id="shell-bridge-operation-error" className="mt-3 whitespace-pre-wrap text-xs text-danger">{operationError}</p> : null}
          {desktop?.hubUrl ? <p className="mt-3 truncate border-t border-subtle pt-2 text-[10px] text-faint" title={desktop.hubUrl}>{desktop.hubUrl}</p> : null}
        </section>
      ) : null}
    </div>
  );
}
