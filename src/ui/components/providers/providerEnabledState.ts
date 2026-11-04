// One effective "enabled" state for a provider profile, shared by the provider list and the
// profile page so they can never disagree. Launch requires BOTH the profile flag and the
// bridge (runtime) flag; the hub defaults the bridge flag to on for a present provider.
export type ProviderEnabledView = {
  enabled: boolean;
  label: 'Enabled' | 'Disabled';
  /** Why the state is what it is; empty when profile and bridge agree on "enabled". */
  reason: string;
  /** The single action that fixes a disabled state. */
  fix: 'none' | 'enable_profile' | 'enable_on_bridge';
  fixLabel: string;
};

export function providerEnabledView(profileEnabled: boolean, runtimeEnabled: boolean | undefined): ProviderEnabledView {
  if (profileEnabled && runtimeEnabled) return { enabled: true, label: 'Enabled', reason: '', fix: 'none', fixLabel: '' };
  if (!profileEnabled) {
    return { enabled: false, label: 'Disabled', reason: 'Profile disabled', fix: 'enable_profile', fixLabel: 'Enable profile' };
  }
  return {
    enabled: false,
    label: 'Disabled',
    reason: runtimeEnabled === undefined ? 'Profile enabled, not yet reported by this bridge' : 'Profile enabled, disabled on this bridge',
    fix: 'enable_on_bridge',
    fixLabel: 'Enable on this bridge',
  };
}
