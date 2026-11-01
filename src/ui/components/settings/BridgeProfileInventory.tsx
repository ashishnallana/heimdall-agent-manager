import { useEffect, useState } from 'react';
import { Toggle } from '@ui';
import { bridgeProfileLabel, type DesktopBridgeStatus } from '../../bridge/desktopBridge';

/** Local discovery is OS-user scoped; displaying a slot never grants access to it. */
export default function BridgeProfileInventory({ profiles, accountBridgeIds, debugId }: {
  profiles: DesktopBridgeStatus[];
  accountBridgeIds: string[];
  debugId: string;
}) {
  const own = new Set(accountBridgeIds);
  const scope = JSON.stringify([...own].sort());
  const [visibility, setVisibility] = useState({ scope, showOthers: false });
  useEffect(() => { setVisibility({ scope, showOthers: false }); }, [scope]);
  // Reset the view immediately when the signed-in account's scope changes.
  const showOthers = visibility.scope === scope && visibility.showOthers;
  const isOwn = (p: DesktopBridgeStatus) => Boolean(p.bridge_id && own.has(p.bridge_id));
  const hasOthers = profiles.some((p) => !isOwn(p));
  const visible = showOthers ? profiles : profiles.filter(isOwn);
  if (!profiles.length) return <p data-debug-id={`${debugId}-empty`} className="text-sm text-muted">No Bridge profiles installed for this Hub on this computer.</p>;
  return <section data-debug-id={debugId} className="overflow-hidden rounded-xl border border-subtle bg-surface">
    <div className="flex flex-wrap items-center justify-between gap-3 border-b border-subtle px-4 py-3">
      <h3 className="text-xs font-medium text-muted">{showOthers ? 'Detected Bridge profiles' : 'Your Bridge profiles'}</h3>
      {hasOthers ? <div className="flex items-center gap-2">
        <label htmlFor={`${debugId}-show-others`} className="text-xs text-muted">Show other local profiles</label>
        <Toggle id={`${debugId}-show-others`} data-debug-id={`${debugId}-show-others`} size="sm" checked={showOthers}
          onChange={(show) => setVisibility({ scope, showOthers: show })} />
      </div> : null}
    </div>
    {!visible.length ? <p data-debug-id={`${debugId}-account-empty`} className="px-4 py-3 text-sm text-muted">No Bridge profiles linked to your account on this computer.</p> : <ul className="divide-y divide-subtle">
      {visible.map((p) => <li key={p.service || p.profile || ''} data-debug-id={`${debugId}-${p.profile || 'default'}`} className="flex flex-wrap items-center justify-between gap-2 px-4 py-3 text-sm">
        <span className="font-mono text-primary">{bridgeProfileLabel(p.profile)}</span>
        <span className="text-xs text-muted">{p.bridge_id && own.has(p.bridge_id) ? 'Your account' : p.enrolled ? 'Not linked to this account' : 'Not enrolled'}</span>
      </li>)}
    </ul>}
  </section>;
}
