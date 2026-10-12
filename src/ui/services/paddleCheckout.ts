// Checkout runs on Paddle's approved public payment page rather than an overlay
// on the authenticated origin. Server-created transactions carry account
// correlation; the browser never supplies a tier or account ID.

// Mirrors the hub's valid_checkout_url so a tampered response cannot redirect
// the user to another destination or transaction.
export function validateCheckoutUrl(value: string, transactionId: string): string {
  if (!/^txn_[a-z0-9]+$/.test(transactionId)) throw new Error('Invalid checkout link.');
  let url: URL;
  try { url = new URL(value); } catch { throw new Error('Invalid checkout link.'); }
  const ptxn = url.searchParams.getAll('_ptxn');
  if (url.protocol !== 'https:' || !url.hostname || url.username || url.password || ptxn.length !== 1 || ptxn[0] !== transactionId) throw new Error('Invalid checkout link.');
  return url.href;
}

export function redirectToCheckout(result: { transaction_id: string; checkout_url: string }, location: Pick<Location, 'assign'> = window.location): void {
  location.assign(validateCheckoutUrl(result.checkout_url, result.transaction_id));
}

export function validatePortalUrl(value: string): string {
  const url = new URL(value);
  if (url.protocol !== 'https:' || !['customer-portal.paddle.com', 'sandbox-customer-portal.paddle.com'].includes(url.hostname) || url.username || url.password || url.port) throw new Error('Invalid subscription management link.');
  return url.href;
}
