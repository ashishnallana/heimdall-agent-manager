import { test } from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import { describeEntitlements } from '../src/ui/utils/accountEntitlements.ts';
import { redirectToCheckout, validateCheckoutUrl, validatePortalUrl } from '../src/ui/services/paddleCheckout.ts';

test('user parameters describe custom bridge counts and explicit capabilities', () => {
  const viewOnly = { terminal_input_enabled: false, max_concurrent_streams: 2, shells_enabled: false };
  assert.equal(describeEntitlements({ ...viewOnly, max_bridges: 0, terminal_streaming_enabled: false }), '0 bridges · Terminal streaming not included · View-only · 2 streams · Shells not included');
  assert.equal(describeEntitlements({ ...viewOnly, max_bridges: 1, terminal_streaming_enabled: true }), '1 bridge · Terminal streaming included · View-only · 2 streams · Shells not included');
  assert.equal(describeEntitlements({ max_bridges: -1, terminal_streaming_enabled: true, terminal_input_enabled: true, max_concurrent_streams: -1, shells_enabled: true }), 'Unlimited bridges · Terminal streaming included · Interactive input · Unlimited streams · Shells included');
});

test('checkout redirects to the validated Paddle URL without loading Paddle.js', () => {
  const dom = new JSDOM('<!doctype html><html><head></head><body></body></html>', { url: 'https://hub.example.test/settings' });
  const assigned: string[] = [];
  const location = { assign: (url: string) => assigned.push(url) };
  const url = 'https://www.brolabs.ai/heimdall/checkout?_ptxn=txn_01m4qhm8k14vqm92dwdbh8a8xh';
  redirectToCheckout({ transaction_id: 'txn_01m4qhm8k14vqm92dwdbh8a8xh', checkout_url: url }, location);
  assert.deepEqual(assigned, [url]);
  assert.throws(() => redirectToCheckout({ transaction_id: 'txn_server123', checkout_url: 'https://pay.example.test/?_ptxn=txn_other' }, location), /Invalid checkout link/);
  assert.equal(assigned.length, 1, 'rejected links never navigate');
  assert.equal(dom.window.document.querySelectorAll('script').length, 0, 'no Paddle.js on the authenticated origin');
  dom.window.close();
});

test('checkout links reject untrusted destinations and transaction mismatches', () => {
  assert.equal(validateCheckoutUrl('https://pay.example.test/checkout?a=1&_ptxn=txn_abc', 'txn_abc'), 'https://pay.example.test/checkout?a=1&_ptxn=txn_abc');
  for (const url of ['', 'not a url', 'javascript:alert(1)//?_ptxn=txn_abc', 'http://pay.example.test/?_ptxn=txn_abc', 'https://user:pass@pay.example.test/?_ptxn=txn_abc', 'https://pay.example.test@evil.test/?_ptxn=txn_evil', 'https://pay.example.test/', 'https://pay.example.test/?_ptxn=txn_other', 'https://pay.example.test/?_ptxn=txn_abcd', 'https://pay.example.test/?_ptxn=txn_abc&_ptxn=txn_abc', 'https://pay.example.test/#?_ptxn=txn_abc']) {
    assert.throws(() => validateCheckoutUrl(url, 'txn_abc'), /Invalid checkout link/, url);
  }
  assert.throws(() => validateCheckoutUrl('https://pay.example.test/?_ptxn=pri_abc', 'pri_abc'), /Invalid checkout link/);
});

test('portal links reject spoofed origins and non-HTTPS URLs', () => {
  assert.equal(validatePortalUrl('https://customer-portal.paddle.com/cpl_123?token=temporary'), 'https://customer-portal.paddle.com/cpl_123?token=temporary');
  assert.equal(validatePortalUrl('https://sandbox-customer-portal.paddle.com/cpl_123'), 'https://sandbox-customer-portal.paddle.com/cpl_123');
  for (const url of ['javascript:alert(1)', 'https://customer-portal.paddle.com.evil.test/', 'https://customer-portal.paddle.com@evil.test/', 'http://customer-portal.paddle.com/', 'https://user:pass@customer-portal.paddle.com/', 'https://customer-portal.paddle.com:8443/']) {
    assert.throws(() => validatePortalUrl(url));
  }
});
