import { useEffect, useMemo, useState } from 'react';
import { Select, Spinner } from '@ui';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import ProviderSetupSurface from '../providers/ProviderSetupSurface';

export function ProvidersPanel() {
  const query = useListBridgesQuery(undefined, { pollingInterval: 120000, refetchOnMountOrArgChange: true });
  const bridges = useMemo(() => (query.data?.bridges || []).filter(
    (bridge: any) => String(bridge?.status || '').toLowerCase() !== 'revoked' && !bridge?.revoked_at,
  ), [query.data]);
  const [bridgeId, setBridgeId] = useState('');

  useEffect(() => {
    if (!bridgeId && bridges.length) setBridgeId(String(bridges[0]?.bridge_id || bridges[0]?.id || ''));
    if (bridgeId && !bridges.some((bridge: any) => String(bridge?.bridge_id || bridge?.id || '') === bridgeId)) {
      setBridgeId(String(bridges[0]?.bridge_id || bridges[0]?.id || ''));
    }
  }, [bridgeId, bridges]);

  if (query.isLoading) return <div className="flex min-h-64 items-center justify-center gap-2 text-sm text-muted"><Spinner size="sm" /> Loading bridges…</div>;
  if (query.isError) return <div role="alert" className="rounded-xl border border-danger/30 bg-danger-soft p-4 text-sm text-danger">Could not load bridges.</div>;
  if (!bridges.length) return <div className="rounded-xl border border-subtle bg-surface p-5 text-sm text-muted">Enroll a bridge before configuring providers.</div>;

  return (
    <div data-debug-id="providers-panel" className="space-y-5">
      <div className="max-w-sm">
        <label htmlFor="provider-bridge-select" className="mb-1 block text-xs font-semibold uppercase tracking-wide text-muted">Bridge</label>
        <Select id="provider-bridge-select" data-debug-id="providers-bridge-select" value={bridgeId} onChange={setBridgeId}>
          {bridges.map((bridge: any) => {
            const id = String(bridge?.bridge_id || bridge?.id || '');
            return <option key={id} value={id}>{String(bridge?.label || bridge?.machine_hostname || id)} · {String(bridge?.status || 'offline')}</option>;
          })}
        </Select>
      </div>
      {bridgeId ? <ProviderSetupSurface mode="settings" bridgeId={bridgeId} /> : null}
    </div>
  );
}

// Provider recipes are Hub-owned and migration-defined. Legacy editor routes now
// render the status/enablement surface instead of exposing command authoring.
export function ProviderEditorPage(_props: { providerName?: string } = {}) { return <ProvidersPanel />; }

export default ProvidersPanel;
