export type ConfigurationValidityInput = {
  instanceLoaded: boolean;
  instanceError: boolean;
  bridgeId: string;
  bridgesLoaded: boolean;
  bridgesError: boolean;
  bridge?: { status?: string; provider_status_error?: boolean; runtime_connected?: boolean };
  projectId: string;
  projectLoaded: boolean;
  projectError: boolean;
  project?: { state?: string; status?: string };
  provider: string;
  providerProfile?: string;
  model: string;
  capabilities: { provider: string; profile_id?: string; models: string[] }[];
  /** Provider status for `bridge` has answered; omitted means it arrived with the bridge. */
  capabilitiesLoaded?: boolean;
};

/** Validate authoritative capabilities, never picker options containing stale values. */
export function conversationConfigurationIssues(input: ConfigurationValidityInput): string[] {
  const issues: string[] = [];
  if (input.instanceError) return ['Agent configuration could not be verified. Reload it before sending.'];
  if (!input.instanceLoaded) return ['Checking the agent configuration before allowing messages.'];
  if (input.bridgesError) issues.push('Bridge availability could not be verified. Refresh the bridge connection.');
  else if (!input.bridgesLoaded) issues.push('Checking the selected bridge before allowing messages.');
  else if (!input.bridgeId || !input.bridge) issues.push('Bridge is missing or no longer accessible. Choose an available bridge.');
  else {
    const status = String(input.bridge.status || '').toLowerCase();
    if (['archived', 'revoked', 'deleted'].includes(status)) issues.push(`Bridge is ${status}. Choose an active bridge.`);
    else if (status !== 'online') issues.push('Bridge is offline or unavailable. Reconnect it or choose an online bridge.');
    else if (input.bridge.runtime_connected === false) issues.push('Bridge command connection is disconnected. Reconnect it or choose a connected bridge.');
    else if (input.bridge.provider_status_error) issues.push('Provider availability could not be verified on this bridge. Refresh its provider status.');
    else if (input.capabilitiesLoaded === false) issues.push('Checking provider availability on this bridge before allowing messages.');
    else {
      const capability = input.capabilities.find(item => item.provider === input.provider && (item.profile_id || item.provider) === (input.providerProfile || input.provider));
      if (!input.provider || !capability) issues.push(`Provider${input.provider ? ` “${input.provider}”` : ''} is unavailable, disabled, or archived on this bridge. Choose an active provider.`);
      else if (!input.model || !capability.models.includes(input.model)) issues.push(`Model/tier${input.model ? ` “${input.model}”` : ''} is unavailable or archived for “${input.provider}”. Choose an active model/tier.`);
    }
  }
  // A conversation without project scope is valid; an explicitly bound project must exist.
  if (input.projectId) {
    if (input.projectError) issues.push('Project is unavailable or could not be verified. Choose an accessible active project or clear the project.');
    else if (!input.projectLoaded) issues.push('Checking the selected project before allowing messages.');
    else if (!input.project) issues.push('Project no longer exists or is inaccessible. Choose an active project or clear the project.');
    else if (String(input.project.state || input.project.status || '').toLowerCase() !== 'active') issues.push('Project is archived or inactive. Restore it, choose an active project, or clear the project.');
  }
  return issues;
}
