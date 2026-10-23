import './helpers/vaultEndpointHarness.ts';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { JSDOM } from 'jsdom';
import { authenticatedStreamUrl } from '../src/ui/api/userStreamUrl.ts';

test('browser streams use API cookie origin; Electron mints a fresh cancellable single-use ticket per connection', async () => {
  const previousWindow = (globalThis as any).window, previousDocument = (globalThis as any).document;
  const previousFetch = globalThis.fetch;
  const dom = new JSDOM('', { url: 'https://hub.test/' });
  Object.assign(globalThis, { window: dom.window, document: dom.window.document });
  try {
    assert.equal(await authenticatedStreamUrl('/api/v1/tool-activity/stream'),
      'wss://hub.test/api/v1/tool-activity/stream');
    (dom.window as any).odinApi = { deviceAuth: { getConfig: async () => ({ apiBaseUrl: 'https://electron.test' }) } };
    const controller = new AbortController();
    let calls = 0;
    globalThis.fetch = async (url, options) => {
      assert.equal(url, '/api/v1/me/ws-ticket');
      assert.equal(options?.method, 'POST'); assert.equal(options?.signal, controller.signal);
      return new Response(JSON.stringify({ data: { ticket: 'once_' + ++calls } }));
    };
    assert.equal(await authenticatedStreamUrl('/api/v1/tool-activity/stream', controller.signal),
      'wss://electron.test/api/v1/tool-activity/stream?ticket=once_1');
    assert.equal(await authenticatedStreamUrl('/api/v1/tool-activity/stream', controller.signal),
      'wss://electron.test/api/v1/tool-activity/stream?ticket=once_2');
    globalThis.fetch = async () => new Response('{}', { status: 401 });
    await assert.rejects(authenticatedStreamUrl('/api/v1/tool-activity/stream'), /WebSocket ticket failed/);
  } finally {
    Object.assign(globalThis, { window: previousWindow, document: previousDocument });
    globalThis.fetch = previousFetch; dom.window.close();
  }
});
