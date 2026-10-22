/** Hub-resolved parameters. Feature consumers must not branch on plan IDs. */
export interface UserEntitlements {
  max_bridges: number;
  terminal_streaming_enabled: boolean;
  terminal_input_enabled: boolean;
  max_concurrent_streams: number;
  shells_enabled: boolean;
}

export const PERMISSIVE_ENTITLEMENTS: UserEntitlements = Object.freeze({
  max_bridges: -1,
  terminal_streaming_enabled: true,
  terminal_input_enabled: true,
  max_concurrent_streams: -1,
  shells_enabled: true,
});

export function atPlanLimit(allowed: number, current: number): boolean {
  return allowed >= 0 && current >= allowed;
}

export function describeEntitlements(params: UserEntitlements): string {
  const bridges = params.max_bridges < 0 ? 'Unlimited bridges' : `${params.max_bridges} ${params.max_bridges === 1 ? 'bridge' : 'bridges'}`;
  const streams = params.max_concurrent_streams < 0 ? 'Unlimited streams' : `${params.max_concurrent_streams} streams`;
  return `${bridges} · Terminal streaming ${params.terminal_streaming_enabled ? 'included' : 'not included'} · ${params.terminal_input_enabled ? 'Interactive input' : 'View-only'} · ${streams} · Shells ${params.shells_enabled ? 'included' : 'not included'}`;
}
