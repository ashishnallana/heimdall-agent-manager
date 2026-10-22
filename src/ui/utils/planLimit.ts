export interface PlanLimitDetails {
  limit?: string;
  allowed?: number;
  current?: number;
  plan_label?: string;
  upgrade_path?: string;
}

export const PLAN_LIMIT_EVENT = 'heimdall:plan-limit-reached';

/** Accept HTTP ApiError, RTK query errors, and typed WebSocket control frames. */
export function isPlanLimitError(error: unknown): boolean {
  const e = error as any;
  return e?.code === 'plan_limit_reached' || e?.status === 402 || e?.originalStatus === 402
    || e?.code === 4402 || e?.data?.error?.code === 'plan_limit_reached';
}

export function planLimitDetails(error: unknown): PlanLimitDetails {
  const e = error as any;
  return e?.details || e?.data?.error?.details || {};
}

export function planLimitMessage(details: PlanLimitDetails): string {
  switch (details.limit) {
    case 'max_bridges': return `Your plan allows ${details.allowed ?? 'a limited number of'} ${details.allowed === 1 ? 'bridge' : 'bridges'}. Reuse an existing bridge or upgrade to add another.`;
    case 'max_concurrent_streams': return `Your plan allows ${details.allowed ?? 'a limited number of'} concurrent terminal streams. Close another pane or upgrade for more streams.`;
    case 'terminal_input_enabled': return 'Read-only · Upgrade to type, resize, or send signals.';
    case 'terminal_streaming_enabled': return 'Terminal streaming is not included in your plan.';
    case 'shells_enabled': return 'Interactive shells require an upgrade.';
    default: return 'You have reached a limit of your current plan.';
  }
}

/** AppShell owns the single cache refresh and the fallback prompt for API mutations. */
export function announcePlanLimit(error: unknown): void {
  if (!isPlanLimitError(error) || typeof window === 'undefined' || typeof window.dispatchEvent !== 'function') return;
  window.dispatchEvent(new window.CustomEvent(PLAN_LIMIT_EVENT, { detail: planLimitDetails(error) }));
}
