import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import { authenticatedStreamUrl } from '../src/ui/api/userStreamUrl.ts';

test('streams resolve to the API cookie origin with no ticket', async () => {
  const previousWindow = (globalThis as any).window, previousDocument = (globalThis as any).document;
  const previousFetch = globalThis.fetch;
  const dom = new JSDOM('', { url: 'https://hub.test/' });
  Object.assign(globalThis, { window: dom.window, document: dom.window.document });
  let fetches = 0;
  globalThis.fetch = async () => { fetches += 1; return new Response('{}'); };
  try {
    const controller = new AbortController();
    assert.equal(await authenticatedStreamUrl('/api/v1/tool-activity/stream'),
      'wss://hub.test/api/v1/tool-activity/stream');
    assert.equal(await authenticatedStreamUrl('/api/v1/tool-activity/stream', controller.signal),
      'wss://hub.test/api/v1/tool-activity/stream');
    assert.equal(fetches, 0, 'cookie-authenticated streams mint no ticket');
  } finally {
    Object.assign(globalThis, { window: previousWindow, document: previousDocument });
    globalThis.fetch = previousFetch; dom.window.close();
  }
});
