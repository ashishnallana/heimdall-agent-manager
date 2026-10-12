import React, { useEffect, useRef, useState } from 'react';
import { Badge, Button } from '@ui';
import type { SettingsUser } from './SettingsModal';
import { describeEntitlements } from '../../utils/accountEntitlements';
import { useGetAccountBillingQuery, useCreateAccountCheckoutMutation, useCreateAccountPortalMutation } from '../../api/endpoints/accountBilling';
import { apiErrorText } from '../../api/cookieFetch';
import { redirectToCheckout, validatePortalUrl } from '../../services/paddleCheckout';

export default function AccountPanel({ user }: { user: SettingsUser | null }) {
  const [pollPending, setPollPending] = useState(false);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const activeUser = useRef(user?.user_id);
  const checkoutAbort = useRef(new AbortController());
  activeUser.current = user?.user_id;
  useEffect(() => {
    activeUser.current = user?.user_id;
    const controller = new AbortController();
    checkoutAbort.current = controller;
    setPollPending(false); setError(''); setBusy(false);
    return () => { controller.abort(); activeUser.current = undefined; };
  }, [user?.user_id]);
  const billingQuery = useGetAccountBillingQuery(user?.user_id || '', { skip: !user?.user_id, pollingInterval: pollPending ? 5000 : 0, refetchOnFocus: true, refetchOnMountOrArgChange: true });
  const [createCheckout] = useCreateAccountCheckoutMutation();
  const [createPortal] = useCreateAccountPortalMutation();
  const subscription = billingQuery.currentData;
  useEffect(() => {
    setPollPending(Boolean(subscription?.checkout_pending));
  }, [subscription]);

  async function upgrade(offerId: string) {
    if (!subscription) return;
    const owner = user?.user_id;
    const signal = checkoutAbort.current.signal;
    let leaving = false;
    setBusy(true); setError('');
    try {
      const result = await createCheckout(offerId).unwrap();
      if (signal.aborted || activeUser.current !== owner) return;
      // Leave the authenticated origin for Paddle's approved checkout page. On
      // return, checkout_pending keeps this panel polling until the webhook
      // fulfills the subscription.
      redirectToCheckout(result);
      leaving = true;
    } catch (err) { if (!signal.aborted && activeUser.current === owner) setError(apiErrorText(err, 'Could not open checkout.')); }
    finally { if (!leaving && activeUser.current === owner) setBusy(false); }
  }

  async function manageSubscription() {
    const owner = user?.user_id;
    setBusy(true); setError('');
    // Open synchronously so browsers do not block the portal after an API roundtrip.
    const desktop = (window as any).odinApi?.deviceAuth;
    const tab = desktop?.openExternal ? null : window.open('about:blank', '_blank');
    if (tab) tab.opener = null;
    try {
      if (!desktop?.openExternal && !tab) throw new Error('Allow pop-ups to open subscription management.');
      const result = await createPortal().unwrap();
      if (activeUser.current !== owner) { tab?.close(); return; }
      const url = validatePortalUrl(result.url);
      if (desktop?.openExternal) await desktop.openExternal(url);
      else if (tab) tab.location.href = url;
    } catch (err) { tab?.close(); if (activeUser.current === owner) setError(apiErrorText(err, 'Could not open subscription management.')); }
    finally { if (activeUser.current === owner) setBusy(false); }
  }
  const displayName = user?.display_name || user?.name || user?.user_id;

  return (
    <div data-debug-id="account-panel" className="space-y-6 text-left">
      <section className="rounded-xl border border-subtle bg-surface p-5">
        <div className="flex items-center gap-3">
          <div aria-hidden="true" className="grid h-10 w-10 shrink-0 place-items-center rounded-full bg-neutral-soft text-lg font-semibold text-muted">
            {(displayName || 'U').slice(0, 1).toUpperCase()}
          </div>
          <div className="min-w-0">
            <h3 className="break-words text-sm font-semibold text-primary">{displayName || 'Account information unavailable'}</h3>
            <p className="break-words text-xs text-muted">{user?.email || 'No email provided'}</p>
          </div>
        </div>
        <dl className="mt-5 space-y-3 text-sm">
          <div className="flex flex-wrap justify-between gap-2"><dt className="text-muted">Account ID</dt><dd className="break-all text-primary">{user?.user_id || 'Unavailable'}</dd></div>
          <div className="flex justify-between gap-2"><dt className="text-muted">Sign-in provider</dt><dd className="text-primary">Authentik</dd></div>
        </dl>
      </section>

      <section className="rounded-xl border border-subtle bg-surface p-5">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div><h3 className="text-sm font-semibold text-primary">Subscription</h3><p className="mt-1 text-xs text-muted">Your plan and included features.</p></div>
          {subscription?.environment === 'sandbox' && <Badge>Sandbox</Badge>}
        </div>
        {billingQuery.isLoading && <p className="mt-4 text-sm text-muted" role="status">Loading subscription…</p>}
        {billingQuery.isError && <div className="mt-4 space-y-2"><p className="text-sm text-danger" role="alert">{apiErrorText(billingQuery.error, 'Could not load subscription.')}</p><Button data-debug-id="account-billing-retry" variant="ghost" onClick={() => void billingQuery.refetch()}>Retry</Button></div>}
        {subscription && <>
          <div className="mt-5 flex flex-wrap items-center justify-between gap-3">
            <div><p className="text-lg font-semibold text-primary">{subscription.plan_label}</p><p className="mt-1 text-xs text-muted">{describeEntitlements(subscription.entitlements)}</p></div>
            {subscription.manage_subscription_enabled && <Button data-debug-id="account-manage-subscription" variant="secondary" disabled={busy} onClick={() => void manageSubscription()}>Manage subscription</Button>}
          </div>
          {subscription.renews_at && !subscription.cancels_at && subscription.status !== 'canceled' && subscription.status !== 'paused' && <p className="mt-3 text-xs text-muted">Renews {new Date(subscription.renews_at).toLocaleDateString()}</p>}
          {subscription.cancels_at && <p className="mt-3 text-xs text-muted">Cancels {new Date(subscription.cancels_at).toLocaleDateString()}</p>}
          {subscription.status === 'past_due' && <p className="mt-3 text-sm text-danger">Payment needs attention. Update your payment method to keep your subscription active.</p>}
          {subscription.status === 'paused' && <p className="mt-3 text-xs text-muted">Subscription paused.</p>}
          {subscription.checkout_pending && <p className="mt-3 text-sm text-muted" role="status">Checkout started. Your plan updates here once Paddle confirms payment.</p>}
          {!subscription.checkout_enabled && <p className="mt-4 text-xs text-muted">Billing setup is in progress. Upgrades are not available yet.</p>}
          {(subscription.offers || []).map((offer) => <div key={offer.offer_id} className="mt-4 flex flex-wrap items-center justify-between gap-3 border-t border-subtle pt-4">
            <div><h4 className="text-sm font-semibold text-primary">{offer.plan_label}</h4><p className="mt-1 text-xs text-muted">{describeEntitlements(offer.entitlements)}</p></div>
            <Button data-debug-id={`account-upgrade-${offer.offer_id}`} variant="primary" disabled={busy || !subscription.checkout_enabled} onClick={() => void upgrade(offer.offer_id)}>{busy ? 'Opening…' : `Upgrade to ${offer.plan_label}`}</Button>
          </div>)}
        </>}
        {error && <p className="mt-4 text-sm text-danger" role="alert">{error}</p>}
      </section>
    </div>
  );
}
