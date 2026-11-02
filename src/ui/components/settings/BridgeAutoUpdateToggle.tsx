import { useEffect, useState } from 'react';
import { cookieJsonFetch, cookieMutation } from '../../api/cookieFetch';
import { Text, Toggle } from '@ui';

export default function BridgeAutoUpdateToggle({ bridgeId, online }: { bridgeId: string; online: boolean }) {
  const [enabled, setEnabled] = useState<boolean | null>(null);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');
  const path = `/bridges/${encodeURIComponent(bridgeId)}/auto-update`;
  useEffect(() => {
    let active = true;
    setEnabled(null);
    setError('');
    if (online) {
      void cookieJsonFetch(path).then((reply: any) => {
        const data = reply?.data ?? reply;
        if (active && typeof data?.enabled === 'boolean') setEnabled(data.enabled);
      }).catch((err: any) => { if (active) setError(String(err?.message || 'Could not load automatic updates')); });
    }
    return () => { active = false; };
  }, [path, online]);

  async function save(value: boolean) {
    setSaving(true);
    setError('');
    try {
      const reply: any = await cookieMutation(path, 'PUT', { enabled: value });
      const data = reply?.data ?? reply;
      if (typeof data?.enabled !== 'boolean') throw new Error('Bridge did not confirm the setting');
      setEnabled(data.enabled);
    } catch (err: any) {
      setError(String(err?.message || 'Could not save automatic updates'));
    } finally {
      setSaving(false);
    }
  }

  return <div className="flex flex-col gap-2" data-debug-id={`settings-bridge-auto-update-${bridgeId}`}>
    <div className="flex items-center justify-between gap-3">
      <Text as="span" role="caption" tone="muted">
        Automatic bridge updates{!online ? ' (connect to change)' : enabled === null ? ' (loading…)' : ''}
      </Text>
      <Toggle size="sm" aria-label="Automatic bridge updates"
        aria-describedby={`settings-bridge-auto-update-help-${bridgeId}`}
        data-debug-id={`settings-bridge-auto-update-toggle-${bridgeId}`}
        checked={enabled === true} disabled={!online || enabled === null || saving}
        onChange={(checked) => void save(checked)} />
    </div>
    <Text as="p" role="caption" tone="muted" id={`settings-bridge-auto-update-help-${bridgeId}`}>
      Checks about every 6 hours and installs when no agents are running.
    </Text>
    {error ? <p role="alert" className="text-caption text-danger">{error}</p> : null}
  </div>;
}
