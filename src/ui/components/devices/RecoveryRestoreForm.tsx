// "Use recovery key" on the waiting (pairing) screen (plan P4). The user types the 12
// recovery words; this browser verifies the device log from genesis, opens the
// recovery credential the words belong to, and approves ITSELF as that credential.
// Wrong words, another account's words, a tampered or revoked recovery key install
// nothing. Afterwards it lists the other approved devices: revoke the lost ones in
// Settings -> Devices.

import React, { useState } from 'react';
import { Alert, Button } from '@ui';
import { restoreWithRecoveryKey, type RecoveryRestoreResult } from '../../services/deviceVault';
import { buildRouteHash } from '../../utils/appLocation';

export function splitRecoveryWords(text: string): string[] {
  return String(text ?? '').trim().toLowerCase().split(/[\s,]+/).filter(Boolean);
}

export function RecoveryRestoreForm() {
  const [open, setOpen] = useState(false);
  const [text, setText] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [done, setDone] = useState<RecoveryRestoreResult | null>(null);

  if (done) {
    return (
      <div data-debug-id="device-recovery-restore-done">
        <Alert tone="success" title="Restored with your recovery key">
          This browser was approved by your recovery key.
          {done.otherDevices.length > 0 ? (
            <> If any of these were lost or stolen, revoke them in{' '}
              <a data-debug-id="device-recovery-restore-devices-link" className="font-medium text-accent hover:underline" href={buildRouteHash('/settings/devices', '')}>Settings → Devices</a>:{' '}
              {done.otherDevices.map((d) => d.label).join(', ')}.</>
          ) : null}
        </Alert>
      </div>
    );
  }
  if (!open) {
    return (
      <button type="button" data-debug-id="device-recovery-restore-open-btn" className="text-xs font-medium text-accent hover:underline" onClick={() => setOpen(true)}>
        Use recovery key
      </button>
    );
  }
  const submit = async () => {
    setBusy(true);
    setError('');
    try {
      setDone(await restoreWithRecoveryKey(splitRecoveryWords(text)));
      setText('');
    } catch (err) {
      setError(String((err as Error)?.message || err));
    } finally {
      setBusy(false);
    }
  };
  return (
    <div data-debug-id="device-recovery-restore" className="flex flex-col gap-2">
      <label htmlFor="device-recovery-restore-words" className="text-xs font-medium text-muted">Your 12 recovery words, in order</label>
      <textarea
        id="device-recovery-restore-words"
        data-debug-id="device-recovery-restore-words-input"
        className="min-h-20 rounded-lg border border-subtle bg-surface p-2 font-mono text-sm text-primary"
        autoComplete="off"
        spellCheck={false}
        value={text}
        onChange={(e) => setText(e.target.value)}
      />
      <div className="flex gap-2">
        <Button size="sm" variant="primary" data-debug-id="device-recovery-restore-submit-btn" loading={busy} disabled={splitRecoveryWords(text).length !== 12} onClick={() => void submit()}>Restore</Button>
        <Button size="sm" variant="ghost" data-debug-id="device-recovery-restore-cancel-btn" onClick={() => { setOpen(false); setText(''); setError(''); }}>Cancel</Button>
      </div>
      {error ? <p data-debug-id="device-recovery-restore-error" className="text-xs text-danger">{error}</p> : null}
    </div>
  );
}
