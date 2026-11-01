import React, { useEffect, useState } from 'react';
import { desktopCapabilities, type DesktopUpdateState } from '../../bridge/desktopBridge';

const reasons: Record<string, string> = {
  'package-managed': 'Update this installation using its package manager or official installer.',
  development: 'Development builds do not update themselves.',
  'read-only-install': 'Move Ninjy to a writable Applications folder or reinstall using the official installer.',
  'signing-unavailable': 'Automatic updates require a signed installation. Install the latest official signed release manually.',
  'unsupported-architecture': 'This architecture requires a manual update.',
  'missing-policy': 'This app predates authenticated automatic updates. Install the latest official release manually.',
  'invalid-policy': 'This installation cannot safely update itself. Reinstall the official release.',
  'invalid-feed': 'The packaged update configuration is invalid. Reinstall the official release.',
  'unsupported-distribution': 'Use the official installer to update this distribution.',
};

export default function DesktopUpdatesPanel() {
  const capabilities = desktopCapabilities();
  const api = capabilities.desktopUpdates;
  const [state, setState] = useState<DesktopUpdateState | null>(null);
  const [message, setMessage] = useState('');
  const [pending, setPending] = useState(false);
  useEffect(() => {
    if (!api) return;
    let active = true;
    let events = 0;
    const accept = (next: DesktopUpdateState) => { if (active && next?.schemaVersion === 1) setState(next); };
    const unsubscribe = api.onState(next => { events++; accept(next); });
    const initial = events;
    void api.getState().then(next => { if (events === initial) accept(next); }).catch(() => { if (active) setMessage('Unable to read app update status. Reopen settings or use the application menu.'); });
    return () => { active = false; unsubscribe(); };
  }, [api]);
  async function run(operation: 'check' | 'retry' | 'restartAndInstall') {
    if (!api || pending) return;
    setPending(true); setMessage('');
    try {
      const result = await api[operation]();
      if ('error' in result && result.error) setMessage(result.error);
    } catch { setMessage('Unable to update. Try again or use the official installer.'); }
    finally { setPending(false); }
  }
  const busy = pending || ['checking', 'available', 'downloading', 'preparing-restart'].includes(state?.phase || '');
  const buttonClass = 'rounded-md border border-border px-3 py-2 text-body hover:bg-hover disabled:opacity-50';
  return <section data-debug-id="desktop-updates-panel" className="space-y-4">
    <div><h3 className="text-body font-medium">App updates</h3><p className="text-caption text-muted">Updates replace Ninjy. Your Bridge services and running agents continue independently.</p></div>
    <p data-debug-id="desktop-updates-current-version">Installed version: {state?.currentVersion || 'Unavailable'} · Stable channel</p>
    <p data-debug-id="desktop-updates-status" role="status" aria-live="polite">
      {message || (!capabilities.desktop ? 'You are using the browser. Update the installed desktop app separately.'
        : !api ? 'This app needs a manual upgrade before it can manage automatic updates.'
        : state?.phase === 'disabled' ? reasons[state.reason] || 'Use the official installer to update this installation.'
        : state?.message || 'Loading app update status…')}
    </p>
    {state?.lastCheckedAt && <p className="text-caption text-muted">Last checked: {new Date(state.lastCheckedAt).toLocaleString()}</p>}
    {state?.phase === 'downloading' && <progress data-debug-id="desktop-updates-progress" aria-label="Downloading Ninjy update" max={100} value={state.percent ?? undefined} />}
    {api && state?.supported && <div className="flex flex-wrap gap-2">
      <button data-debug-id="desktop-updates-check" className={buttonClass} disabled={busy || state.phase === 'downloaded'} onClick={() => void run('check')}>Check for updates</button>
      {state.retryable && <button data-debug-id="desktop-updates-retry" className={buttonClass} disabled={busy} onClick={() => void run('retry')}>Retry</button>}
      {state.phase === 'downloaded' && <>
        <button data-debug-id="desktop-updates-restart" className={buttonClass} disabled={busy} onClick={() => void run('restartAndInstall')}>Restart to update</button>
        <button data-debug-id="desktop-updates-later" className={buttonClass} disabled={busy} onClick={() => setMessage('You can keep using Ninjy. Restart to update when you are ready.')}>Later</button>
      </>}
    </div>}
    <a data-debug-id="desktop-updates-release-link" href="https://github.com/tanmayv/heimdall-agent-manager/releases" target="_blank" rel="noreferrer">Official releases and manual installers</a>
  </section>;
}
