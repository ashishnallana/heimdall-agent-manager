import { useSelector } from 'react-redux';
import { accountBillingApi } from '../api/endpoints/accountBilling';
import { PERMISSIVE_ENTITLEMENTS, type UserEntitlements } from '../utils/accountEntitlements';

/** Cache-only access. AppShell is the sole query subscriber/loader. */
export function selectEntitlements(state: any): UserEntitlements {
  // Device-vault bootstrap records the authenticated /me identity before the
  // shell mounts. chat.session.userId belongs to the legacy client registration.
  const userId = String(state?.deviceVault?.userId || '');
  if (!userId) return PERMISSIVE_ENTITLEMENTS;
  return accountBillingApi.endpoints.getAccountBilling.select(userId)(state).data?.entitlements ?? PERMISSIVE_ENTITLEMENTS;
}

export function useEntitlements(): UserEntitlements {
  return useSelector(selectEntitlements);
}
