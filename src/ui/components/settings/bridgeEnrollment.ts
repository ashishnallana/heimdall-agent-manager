// REQ-BRG-1: Bridge enrollment and readiness predicates.
// Disentangles bridge connection health from capability population
// and eliminates ghosting of consumed/revoked enrollments.

// `isPendingEnrollment` lived here and is DELETED (REQ-ENROLL-9). It decided whether
// a pending-enrollment row was still worth showing; there are no enrollment rows any
// more, because the endpoints that minted, listed and revoked the one-time enrollment
// token are gone. `bridgeReady` below is unrelated and still used.


export function statusLabel(bridge: any): string {
  const status = String(bridge?.status || bridge?.runtime_status || '').toLowerCase();
  return status || 'offline';
}

export function bridgeReady(bridge: any): boolean {
  const status = statusLabel(bridge);
  return !bridge?.plan_disabled_at && (status === 'online' || status === 'connected');
}
