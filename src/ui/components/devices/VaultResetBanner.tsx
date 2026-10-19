// App-level vault banners for approved devices:
//  - a scheduled vault reset (72 h delay) with a Cancel action — any approved device may cancel;
//  - an attention entry when devices are waiting for approval (no code is ever shown
//    here: the code exists only on the new device's screen).

import React, { useState } from 'react';
import { useSelector } from 'react-redux';
import { Button, Icon } from '@ui';
import { selectDeviceVault } from '../../store/deviceVaultSlice';
import { cancelVaultReset } from '../../services/deviceVault';
import { buildRouteHash } from '../../utils/appLocation';

export function VaultResetBanner() {
  const state = useSelector(selectDeviceVault);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  if (state.status !== 'ready') return null;
  const pending = state.pendingDevices.length;
  if (!state.reset && pending === 0) return null;
  const due = state.reset ? new Date(Date.parse(state.reset.effectiveAt)).toLocaleString() : '';
  return (
    <div className="pointer-events-none fixed inset-x-0 top-[env(safe-area-inset-top)] z-50 flex flex-col items-center gap-2 p-2">
      {state.reset ? (
        <div data-debug-id="vault-reset-banner" role="alert" className="pointer-events-auto flex max-w-2xl flex-wrap items-center gap-2 rounded-xl border border-danger/40 bg-danger-soft px-3 py-2 text-sm text-danger shadow">
          <Icon name="alert" size={14} />
          <span>A vault reset is scheduled for {due}. It deletes every key; encrypted history becomes unreadable.</span>
          <Button
            size="sm"
            variant="danger"
            data-debug-id="vault-reset-banner-cancel-btn"
            loading={busy}
            onClick={() => {
              setBusy(true);
              setError('');
              cancelVaultReset().catch((err) => setError(String(err?.message || err))).finally(() => setBusy(false));
            }}
          >
            Cancel reset
          </Button>
          {error ? <span data-debug-id="vault-reset-banner-error" className="text-xs">{error}</span> : null}
        </div>
      ) : null}
      {pending > 0 ? (
        <a
          data-debug-id="vault-pending-devices-banner"
          href={buildRouteHash('/settings/devices', '')}
          className="pointer-events-auto inline-flex items-center gap-2 rounded-xl border border-warning/40 bg-warning-soft px-3 py-1.5 text-sm text-warning shadow hover:underline"
        >
          <Icon name="lock" size={14} />
          {pending === 1 ? 'A device is waiting for approval' : `${pending} devices are waiting for approval`}
        </a>
      ) : null}
    </div>
  );
}

export default VaultResetBanner;
