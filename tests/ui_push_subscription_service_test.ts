import { test } from 'node:test';
import assert from 'node:assert/strict';
import './helpers/vaultEndpointHarness.ts';

test('uint8ArrayToBase64Url and base64UrlToUint8Array round-trip VAPID keys byte-for-byte', async () => {
  const { uint8ArrayToBase64Url, base64UrlToUint8Array } = await import('../src/ui/services/pushSubscriptionService.ts');

  const KNOWN_VAPID = 'BCpPdJm-4wgtUnecweYLMFV6n8TpDjNYfaLH7BE2W4Clyu8UOV6DqM3yFzxhhqvQ9Ro_ZImu0_gdQmeMsdb7IEU';

  {
    const bytes = base64UrlToUint8Array(KNOWN_VAPID);
    assert.equal(bytes.length, 65, 'uncompressed P-256 point decodes to 65 bytes');
    assert.equal(bytes[0], 0x04, 'uncompressed point starts with the 0x04 prefix');
    const back = uint8ArrayToBase64Url(bytes);
    assert.equal(back, KNOWN_VAPID, 'encode∘decode round-trips to the exact unpadded base64url input');
  }

  {
    const original = new Uint8Array(65);
    for (let i = 0; i < original.length; i += 1) original[i] = (i * 37 + 5) & 0xff;
    const encoded = uint8ArrayToBase64Url(original);
    assert.ok(!/[+/=]/.test(encoded), 'output uses the URL-safe alphabet and drops padding');
    const decoded = base64UrlToUint8Array(encoded);
    assert.deepEqual(Array.from(decoded), Array.from(original), 'decode∘encode round-trips raw bytes exactly');
  }

  {
    assert.equal(uint8ArrayToBase64Url(new Uint8Array(0)), '', 'empty bytes -> empty string');
  }
});
