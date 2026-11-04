import { Badge, Text } from '@ui';
import { providerBinaryPathView } from './providerBinaryPath';

/** Resolved executable path (monospace, truncated, full path in the tooltip). */
export default function ProviderBinaryPath({ provider, status, overridePath = '' }: {
  provider: string;
  status?: { state?: string; binary_path?: string };
  overridePath?: string;
}) {
  const view = providerBinaryPathView(status, overridePath);
  return (
    <span data-debug-id={'provider-binary-path-' + provider} data-binary-kind={view.kind} className="flex min-w-0 items-center gap-2">
      {view.kind === 'missing'
        ? <Text role="caption" tone="muted">{view.label}</Text>
        : <Text role="code" tone="muted" className="min-w-0 truncate" title={view.path}>{view.path}</Text>}
      {view.kind === 'override' ? <Badge>{view.label}</Badge> : null}
    </span>
  );
}
