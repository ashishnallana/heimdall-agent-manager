import { cookieJsonFetch, cookieMutation } from '../cookieFetch';
import { heimdallApi } from '../heimdallApi';
import type { UserEntitlements } from '../../utils/accountEntitlements';

export interface BillingOffer {
  offer_id: string;
  plan_label: string;
  entitlements: UserEntitlements;
}
export interface AccountBilling {
  user_id: string;
  plan_label: string;
  subscription_plan_label: string;
  status: string;
  entitlements: UserEntitlements;
  offers: BillingOffer[] | null;
  checkout_enabled: boolean;
  manage_subscription_enabled: boolean;
  checkout_pending: boolean;
  renews_at: string;
  cancels_at: string;
  grace_until: string;
  environment: 'sandbox' | 'live';
  client_token: string;
}

export const accountBillingApi = heimdallApi.injectEndpoints({
  endpoints: (build) => ({
    getAccountBilling: build.query<AccountBilling, string>({
      keepUnusedDataFor: Infinity,
      providesTags: ['planLimitReached'],
      queryFn: async (userId) => {
        try {
          const data: AccountBilling = await cookieJsonFetch('/account/billing');
          if (data.user_id !== userId) throw new Error('Your account session changed. Refresh to continue.');
          return { data };
        }
        catch (error) { return { error: { status: 'CUSTOM_ERROR', error: (error as Error).message } }; }
      },
    }),
    createAccountCheckout: build.mutation<{ transaction_id: string; checkout_url: string }, string>({
      invalidatesTags: (result) => result ? ['planLimitReached'] : [],
      queryFn: async (offerId) => {
        try { return { data: await cookieMutation('/account/billing/checkout', 'POST', { offer_id: offerId }) }; }
        catch (error) { return { error: { status: 'CUSTOM_ERROR', error: (error as Error).message } }; }
      },
    }),
    createAccountPortal: build.mutation<{ url: string }, void>({
      queryFn: async () => {
        try { return { data: await cookieMutation('/account/billing/portal', 'POST', {}) }; }
        catch (error) { return { error: { status: 'CUSTOM_ERROR', error: (error as Error).message } }; }
      },
    }),
  }),
});

export const { useGetAccountBillingQuery, useCreateAccountCheckoutMutation, useCreateAccountPortalMutation } = accountBillingApi;
