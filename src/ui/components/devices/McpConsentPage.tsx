import React, { useEffect, useState } from 'react';
import { Alert, Button, Checkbox, Panel, Text } from '@ui';
import { completeMcpConsent, fetchMcpConsent } from '../../api/endpoints/mcp';
import { currentDeviceIdentity, fetchVerifiedChain } from '../../services/deviceVault';
import { getKeyringSession, withKeyringBytes } from '../../utils/vaultKeyringSession';
import { getRouteSearch } from '../../utils/appLocation';
import { buildMcpConsent, type McpConsentRequest } from '../../utils/mcpConsent';
import { MCP_CAPABILITIES, selectedMcpScopes } from '../../utils/mcpCapabilities';

export default function McpConsentPage() {
  const ticket = new URLSearchParams(getRouteSearch()).get('request') || '';
  const [request, setRequest] = useState<McpConsentRequest | null>(null);
  const [hosted, setHosted] = useState(false);
  const [selected, setSelected] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  useEffect(() => {
    let active = true;
    setRequest(null); setSelected([]); setHosted(false); setError('');
    if (!ticket) { setError('This connector request is missing. Start the connection again.'); return; }
    fetchMcpConsent(ticket).then((r) => { if (active) setRequest(r); }).catch(() => { if (active) setError('This request expired, or this browser is not an approved Ninjy device. Open Ninjy on an approved device and start the connection again.'); });
    return () => { active = false; };
  }, [ticket]);
  async function approve() {
    if (!request || busy) return;
    setBusy(true); setError('');
    let body: Awaited<ReturnType<typeof buildMcpConsent>> | undefined;
    try {
      const identity = currentDeviceIdentity();
      if (!identity || !getKeyringSession()) throw new Error('An approved unlocked Ninjy device is required');
      const { chain } = await fetchVerifiedChain();
      body = await buildMcpConsent(ticket, request, hosted ? 'hosted' : 'device', identity, chain, (run) => withKeyringBytes(run, chain), Date.now(), selectedMcpScopes(request.scope, selected));
      const result = await completeMcpConsent(body);
      // The server returns the exact registered HTTPS callback with a one-use
      // code. Never save it to history/state or print it to an error message.
      if (!result.redirect.startsWith(`${request.redirect}${request.redirect.includes('?') ? '&' : '?'}code=`)) throw new Error('Connector callback did not match');
      window.location.replace(result.redirect);
    } catch {
      setError('Connection was not completed. Check that this device is approved and unlocked, then start a fresh connector request.');
    } finally {
      if (body) { body.private_capability = ''; body.consent = ''; }
      setBusy(false);
    }
  }
  return <main className="mx-auto max-w-xl p-4" data-debug-id="mcp-consent-page">
    <Text as="h1" role="display">Connect to Ninjy</Text>
    <Text as="p" role="body" className="my-4">Allow this connector to list, read and create your chains and wait for changes. It cannot act as a worker or reviewer.</Text>
    {request && <Panel className="space-y-4">
      <Text as="p" role="body-sm">Account: {request.owner}</Text>
      <Text as="p" role="body-sm">Connector callback: {request.redirect}</Text>
      <Text as="p" role="body-sm">Resource: {request.resource}</Text>
      {MCP_CAPABILITIES.filter(([scope]) => request.scope.split(' ').includes(scope)).length > 0 && <fieldset className="space-y-2" disabled={busy}>
        <legend>Additional permissions</legend>
        <Text as="p" role="body-sm">Only enable the actions you want this connection to perform. Existing connections keep their original permissions.</Text>
        {MCP_CAPABILITIES.filter(([scope]) => request.scope.split(' ').includes(scope)).map(([scope, label]) => <Checkbox
          key={scope} data-debug-id={`mcp-consent-capability-${scope.replaceAll(':', '-')}`}
          checked={selected.includes(scope)} disabled={busy} label={label}
          onChange={(checked) => setSelected((current) => checked ? [...current.filter((value) => value !== scope), scope] : current.filter((value) => value !== scope))}
        />)}
      </fieldset>}
      <Text as="p" role="body-sm">By default, an approved online bridge or an approved unlocked browser must decrypt results.</Text>
      <Checkbox data-debug-id="mcp-consent-hosted" checked={hosted} onChange={setHosted} label="Allow hosted decryption for this connection" disabled={busy} />
      {hosted && <Alert tone="warning" title="The hosted service can read your results">The service will receive decryption access in memory and send readable results to your AI provider. This connection can work while your devices are offline. Disconnecting stops future access; it cannot erase data already shared.</Alert>}
      <Text as="p" role="body-sm">You can disconnect this connection in Settings → Devices → AI connections.</Text>
      <div className="flex gap-2">
        <Button data-debug-id="mcp-consent-approve" onClick={approve} loading={busy}>Allow connection</Button>
        <Button data-debug-id="mcp-consent-cancel" variant="ghost" disabled={busy} onClick={() => window.location.replace('/#/settings/devices')}>Cancel</Button>
      </div>
    </Panel>}
    {error && <Alert tone="danger" title="Connection unavailable" className="mt-4">{error}</Alert>}
  </main>;
}
