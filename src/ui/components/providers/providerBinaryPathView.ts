// Where a provider's executable comes from, for the provider settings rows.
// `override` is the profile's own binary_path (the user's choice); otherwise the
// path is whatever the bridge resolved on PATH. Absent => "not found on PATH".
export type ProviderBinaryPathKind = 'override' | 'path' | 'missing';

export interface ProviderBinaryPathView {
  kind: ProviderBinaryPathKind;
  /** The path to show; empty when missing. */
  path: string;
  /** Short label shown beside the path. */
  label: string;
}

export function providerBinaryPathView(
  status: { state?: string; binary_path?: string } | undefined,
  overridePath = '',
  hasOverride = false,
): ProviderBinaryPathView {
  const override = overridePath.trim();
  if (override) return { kind: 'override', path: override, label: 'Override' };
  // The profile list only carries `has_binary` (the path itself stays on the bridge):
  // label the override and show whatever path discovery reported, if any.
  if (hasOverride) return { kind: 'override', path: (status?.binary_path || '').trim(), label: 'Override' };
  const resolved = (status?.binary_path || '').trim();
  if (status?.state === 'present' && resolved) return { kind: 'path', path: resolved, label: '' };
  return { kind: 'missing', path: '', label: 'Not found on PATH' };
}
