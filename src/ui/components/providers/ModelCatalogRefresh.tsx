import { useState } from 'react';
import { Button, Icon, Spinner } from '@ui';
import { useListBridgeProvidersQuery, useRefreshBridgeModelsMutation } from '../../api/endpoints/bridgeSupport';
import { modelCatalogSummary } from './modelCatalogStatus';

/** Only this button starts probes. Mounting reads saved status only. */
export default function ModelCatalogRefresh({ bridgeId, provider, profileId, online, disabled, debugPrefix }: {
  bridgeId: string; provider?: string; profileId?: string; online: boolean; disabled?: boolean; debugPrefix: string;
}) {
  const [refresh, { isLoading }] = useRefreshBridgeModelsMutation();
  const status = useListBridgeProvidersQuery({ bridgeId }, { skip: !bridgeId });
  const [error, setError] = useState('');
  const entry = status.currentData?.providers?.find((row: any) => row.provider === provider && (row.profile_id || row.provider) === (profileId || provider));
  return <div className="space-y-1">
    <Button size="sm" variant="ghost" data-debug-id={`${debugPrefix}-model-refresh-btn`}
      disabled={disabled || !bridgeId || !online || isLoading}
      leading={isLoading ? <Spinner size="sm" /> : <Icon name="refresh" size={14} />}
      onClick={async () => {
        setError('');
        try { await refresh({ bridgeId }).unwrap(); }
        catch { setError('Could not refresh models. The saved list is still available.'); }
      }}>
      {isLoading ? 'Refreshing models…' : 'Refresh models'}
    </Button>
    {entry ? <p data-debug-id={`${debugPrefix}-model-catalog-status`} className="text-xs text-muted">{modelCatalogSummary(entry)}</p> : null}
    {error ? <p role="alert" className="text-xs text-danger">{error}</p> : null}
  </div>;
}
