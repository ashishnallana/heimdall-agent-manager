/** Display metadata for a saved catalog; reading it never requests discovery. */
export interface ModelCatalogMetadata {
  models_source?: string;
  models_state?: string;
  models_checked_at?: string | null;
  models_attempted_at?: string | null;
  models_has_snapshot?: boolean;
  models_binary_path?: string;
  models_version_text?: string;
}
export function normalizeModelCatalog(raw: any): ModelCatalogMetadata {
  return {
    models_source: String(raw?.models_source || 'static_fallback'),
    models_state: String(raw?.models_state || 'not_checked'),
    models_checked_at: raw?.models_checked_at ? String(raw.models_checked_at) : null,
    models_attempted_at: raw?.models_attempted_at ? String(raw.models_attempted_at) : null,
    models_has_snapshot: Boolean(raw?.models_has_snapshot),
    models_binary_path: String(raw?.models_binary_path || ''),
    models_version_text: String(raw?.models_version_text || ''),
  };
}
export function modelCatalogSummary(value: ModelCatalogMetadata): string {
  const saved = Boolean(value.models_has_snapshot);
  const parts = [saved ? 'Discovered on this bridge' : 'Built-in model list'];
  if (value.models_checked_at) {
    const date = new Date(value.models_checked_at);
    if (Number.isFinite(date.getTime())) parts.push('Checked ' + date.toLocaleString());
  }
  const state = value.models_state || 'not_checked';
  if (state === 'not_checked') parts.push('Models have not been refreshed');
  else if (state !== 'success') {
    const reason = state === 'authentication_required' ? 'Sign in to refresh models'
      : state === 'unsupported' ? 'Model refresh is unavailable on this bridge'
      : state === 'timeout' ? 'Model refresh timed out'
      : state === 'busy' ? 'Bridge is busy'
      : 'Could not refresh models';
    parts.push(reason + (saved ? '; keeping the last successful list' : '; using the built-in list'));
  }
  return parts.join(' · ');
}
