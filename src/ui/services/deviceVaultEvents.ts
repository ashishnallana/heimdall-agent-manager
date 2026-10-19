// WS `resource_changed` events for the passwordless vault: `vault_devices`
// (pending / approved / revoked / denied) and `vault_directory` (genesis /
// reset_scheduled / reset_cancelled / reset_executed). Events never carry a code and
// are only nudges: the directory is re-fetched and re-verified.

import { showToast } from '../store/toastSlice';
import { refreshDeviceVault } from './deviceVault';

export function handleVaultDirectoryEvent(dispatch: (action: unknown) => unknown, resource: string, _resourceId: string, change: string): void {
  void refreshDeviceVault(`ws:${resource}:${change}`);
  if (resource === 'vault_devices' && change === 'pending') {
    dispatch(showToast({
      id: 'vault-device-pending',
      kind: 'info',
      title: 'A new device is waiting for approval',
      message: 'Enter the code shown on that device at Settings → Devices → Add a device. Approve only devices you set up yourself.',
      autoDismissMs: 15000,
    }));
  } else if (resource === 'vault_directory' && change === 'reset_scheduled') {
    dispatch(showToast({
      id: 'vault-reset-scheduled',
      kind: 'error',
      title: 'A vault reset was requested',
      message: 'It runs in 72 hours and deletes all keys. Cancel it in Settings → Devices if you did not request it.',
      autoDismissMs: 30000,
    }));
  }
}
