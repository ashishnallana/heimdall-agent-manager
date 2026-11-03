import { useEffect, useLayoutEffect, useMemo, useState } from 'react';
import { Badge, Button, Panel, Spinner, StatusPill, Text } from '@ui';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import { apiErrorText } from '../../api/cookieFetch';
import ProviderProfilesSurface from '../providers/ProviderProfilesSurface';
import { providerSetupApi, type BridgeProviderStatus } from '../providers/providerSetupApi';

const bridgeKey = (bridge: any) => String(bridge?.bridge_id || bridge?.id || '');
export const providerBridgePath = (id: string) => '/settings/providers/' + encodeURIComponent(id);
export const providerBridgeName = (bridge: any) => String(bridge?.label || bridge?.machine_hostname || bridgeKey(bridge));

function ProviderBridgeCard({ bridge }: { bridge: any }) {
  const id = bridgeKey(bridge);
  const [providers, setProviders] = useState<BridgeProviderStatus[] | null>(null);
  const [error, setError] = useState('');
  useEffect(() => {
    let cancelled = false;
    setProviders(null);
    setError('');
    void providerSetupApi.get(id, true).then((result) => {
      if (!cancelled) setProviders(result.providers);
    }).catch((e) => { if (!cancelled) setError(apiErrorText(e)); });
    return () => { cancelled = true; };
  }, [id, bridge.status, bridge.vault_status]);
  const detected = Array.from(new Map((providers || []).filter((p) => p.state === 'present')
    .map((p) => [p.provider, p.display_name || p.provider])).values());
  const missing = Array.from(new Set((providers || []).map((p) => p.provider)))
    .filter((driver) => !providers?.some((p) => p.provider === driver && p.state === 'present')).length;
  const online = bridge.status === 'online';
  return (
    <Panel href={'#' + providerBridgePath(id)} data-debug-id={'providers-bridge-' + id} className="min-w-0 space-y-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0 break-words">
          <Text as="h3" role="heading">{providerBridgeName(bridge)}</Text>
          <Text role="code" tone="muted">{bridge.machine_hostname || id}</Text>
        </div>
        <StatusPill tone={online ? 'success' : 'neutral'}>{online ? 'Online' : 'Offline'}</StatusPill>
      </div>
      <Text role="body-sm" tone="muted">
        {error ? 'Provider summary unavailable. Open bridge to retry.' : providers
          ? `${providers.length} profiles · ${detected.length} provider CLIs detected`
          : 'Loading provider summary…'}
      </Text>
      {!online || bridge.vault_status !== 'unlocked' ? <Text role="caption" tone="muted">Last reported catalog</Text> : null}
      <div className="flex flex-wrap gap-2">
        {detected.map((name) => <Badge key={name}>{name}</Badge>)}
        {missing > 0 ? <Badge>{missing} not installed</Badge> : null}
      </div>
      <div className="flex flex-wrap justify-between gap-2 border-t border-subtle pt-3">
        <Text role="body-sm" tone="muted">Bridge vault: {bridge.vault_status || 'unknown'}</Text>
        <Text role="body-sm" tone="accent">View providers →</Text>
      </div>
    </Panel>
  );
}

export interface ProviderSettingsHeading {
  title: string;
  description: string;
  breadcrumb: string;
  focusKey: string;
}

export function ProvidersPanel({ bridgeId: routeBridgeId = '', onHeadingChange }: {
  bridgeId?: string;
  onHeadingChange?: (heading: ProviderSettingsHeading) => void;
} = {}) {
  const [editorHeading, setEditorHeading] = useState<ProviderSettingsHeading | null>(null);
  const [hash, setHash] = useState(() => window.location.hash);
  useEffect(() => {
    const changed = () => setHash(window.location.hash);
    window.addEventListener('hashchange', changed);
    return () => window.removeEventListener('hashchange', changed);
  }, []);
  const query = useListBridgesQuery(undefined, { refetchOnMountOrArgChange: true });
  const bridges = useMemo(() => (query.data?.bridges || []).filter(
    (bridge: any) => String(bridge?.status || '').toLowerCase() !== 'revoked' && !bridge?.revoked_at,
  ), [query.data]);
  // Keep existing bridge bookmarks without selecting a bridge implicitly.
  const legacyBridge = new URLSearchParams(hash.split('?')[1] || '').get('bridge') || '';
  const bridgeSegment = hash.split('?')[0].replace(/^#\/?settings\/providers\/?/, '');
  let pathBridge = '';
  if (hash.startsWith('#/settings/providers/') && bridgeSegment !== 'new' && !bridgeSegment.endsWith('/edit')) {
    try { pathBridge = decodeURIComponent(bridgeSegment); } catch { /* Invalid bookmark: show overview. */ }
  }
  const bridgeId = routeBridgeId || pathBridge || legacyBridge;
  const bridge = bridges.find((b: any) => bridgeKey(b) === bridgeId);

  const bridgeName = bridge ? providerBridgeName(bridge) : bridgeId;
  const heading = editorHeading?.focusKey.startsWith(bridgeId + '/') && bridge && !query.isError && !query.isLoading
    ? editorHeading : {
      title: bridgeName || 'Providers',
      description: bridgeId
        ? query.isLoading ? 'Loading bridge provider settings…'
          : query.isError ? 'Could not load bridge provider settings.'
          : bridge ? 'Provider profiles and runtime settings on this bridge.'
          : 'This bridge is no longer available. Choose another bridge.'
        : 'Choose a bridge to manage its provider profiles and runtime settings.',
      breadcrumb: bridgeId ? 'Settings / Providers' : '',
      focusKey: bridgeId ? bridgeId + '/list' : '',
    };
  useLayoutEffect(() => {
    onHeadingChange?.(heading);
  }, [onHeadingChange, heading.title, heading.description, heading.breadcrumb, heading.focusKey]);

  if (query.isLoading) return <div className="flex min-h-64 items-center justify-center gap-2 text-sm text-muted"><Spinner size="sm" /> Loading bridges…</div>;
  if (query.isError) return <Panel><p role="alert" className="text-danger">Could not load bridges.</p><Button variant="secondary" data-debug-id="providers-retry" onClick={() => void query.refetch()}>Try again</Button></Panel>;
  if (bridgeId) return (
    <div data-debug-id="providers-panel" className="min-w-0 space-y-4">
      <a data-debug-id="providers-all-bridges" className="text-sm text-accent" href="#/settings/providers">← All bridges</a>
      {bridge ? <ProviderProfilesSurface key={bridgeId} bridge={bridge} onHeadingChange={setEditorHeading} /> : <Panel><Text role="body">This bridge is no longer available. Choose another bridge.</Text></Panel>}
    </div>
  );

  return (
    <div data-debug-id="providers-panel" className="min-w-0 space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <Text as="h2" role="heading">Your bridges</Text>
        <Text role="body-sm" tone="muted">{bridges.length} bridges</Text>
      </div>
      {bridges.length ? <div className="grid grid-cols-1 gap-3" data-debug-id="providers-bridge-overview">
        {bridges.map((b: any) => <ProviderBridgeCard key={bridgeKey(b)} bridge={b} />)}
      </div> : <Panel><Text role="body" tone="muted">Enroll a bridge before configuring providers.</Text></Panel>}
      <Text role="body-sm" tone="muted">Provider profiles belong to a bridge. Each bridge keeps its own accounts, environment and runtime configuration.</Text>
    </div>
  );
}

// Provider recipes are Hub-owned and migration-defined. Legacy editor routes now
// render the status/enablement surface instead of exposing command authoring.
export function ProviderEditorPage(_props: { providerName?: string } = {}) { return <ProvidersPanel />; }

export default ProvidersPanel;
