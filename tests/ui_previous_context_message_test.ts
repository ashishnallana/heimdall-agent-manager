// previous_context messages (chain T7): collapsed-by-default <details> block in
// the agent conversation, never clubbed into start/tool groups.
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_previous_context_message_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';

const block = await import('../src/ui/components/chat/PreviousContextBlock.tsx');
const grouping = await import('../src/ui/components/chat/transcriptGrouping.ts');

function msg(id: string, messageType: string, body: string, extra: any = {}): any {
  return {
    key: id, messageId: id, body, isUser: false, createdUnixMs: 1000, deliveredUnixMs: 0, readUnixMs: 0,
    deliveryFailedUnixMs: 0, deliveryError: '', sending: false, authorLabel: '', messageType, ...extra,
  };
}

async function withDom<T>(fn: (dom: any) => Promise<T>): Promise<T> {
  const { JSDOM } = await import('jsdom');
  const dom = new JSDOM('<!DOCTYPE html><html><body><div id="root"></div></body></html>', { url: 'http://localhost/' });
  const prev = { window: (globalThis as any).window, document: (globalThis as any).document, HTMLElement: (globalThis as any).HTMLElement };
  (globalThis as any).window = dom.window;
  (globalThis as any).document = dom.window.document;
  (globalThis as any).HTMLElement = dom.window.HTMLElement;
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  try {
    return await fn(dom);
  } finally {
    dom.window.close();
    Object.assign(globalThis as any, prev);
  }
}

test('label carries rollover % and window when present', () => {
  assert.equal(block.previousContextLabel({ context_pct: 82, context_window: 200000 }), 'Previous context (rollover at 82% of 200K)');
  assert.equal(block.previousContextLabel({ context_pct: '80.4', window: 1000000 }), 'Previous context (rollover at 80% of 1M)');
  assert.equal(block.previousContextLabel({ context_pct: 81, context_window: 475000 }), 'Previous context (rollover at 81% of 475K)');
  assert.equal(block.previousContextLabel({ context_pct: 80 }), 'Previous context (rollover at 80%)');
  assert.equal(block.previousContextLabel({ context_window: 1500000 }), 'Previous context (1.5M window)');
});

test('label falls back to plain "Previous context" when metadata is absent or unusable', () => {
  for (const metadata of [undefined, null, {}, 'not-an-object', { context_pct: 'abc', context_window: -1 }, { context_pct: 0, window: '' }]) {
    assert.equal(block.previousContextLabel(metadata), 'Previous context', JSON.stringify(metadata));
  }
});

test('block is collapsed by default, keyboard-reachable, and expands to the markdown body', async () => {
  await withDom(async (dom) => {
    const React = await import('react');
    const { createRoot } = await import('react-dom/client');
    const { default: MarkdownBody } = await import('../src/ui/components/MarkdownBody.tsx');
    const { Provider } = await import('react-redux');
    const { makeVaultStore } = await import('./helpers/vaultEndpointHarness.ts');
    const store = await makeVaultStore();
    const root = createRoot(dom.window.document.getElementById('root')!);
    await React.act(async () => root.render(React.createElement(Provider, { store, children: React.createElement(block.PreviousContextBlock, {
      messageId: 'msg_pctx_1', metadata: { context_pct: 82, context_window: 200000 },
      children: React.createElement(MarkdownBody, { source: '## Handoff\n\n**Next:** run the tests' }),
    }) })));
    const doc = dom.window.document;
    const details = doc.querySelector('[data-debug-id="conversation-previous-context-msg_pctx_1"]');
    assert.ok(details, 'block renders');
    assert.equal(details.tagName, 'DETAILS');
    assert.equal(details.open, false, 'collapsed by default');
    assert.equal(details.hasAttribute('open'), false);

    const summary = details.querySelector('summary');
    assert.ok(summary, 'native <summary> (focusable, Enter/Space toggles)');
    assert.equal(summary.parentElement, details);
    assert.equal(summary.textContent, 'Previous context (rollover at 82% of 200K)');
    summary.focus();
    assert.equal(doc.activeElement, summary, 'summary takes keyboard focus');

    await React.act(async () => { summary.click(); });
    assert.equal(details.open, true, 'activating the summary expands the block');
    const body = details.querySelector('[data-debug-id="conversation-previous-context-body-msg_pctx_1"]');
    assert.ok(body);
    assert.ok(body.querySelector('h2'), 'markdown heading rendered');
    assert.equal(body.querySelector('strong')?.textContent, 'Next:');

    await React.act(async () => { summary.click(); });
    assert.equal(details.open, false, 'activating again collapses it');
    await React.act(async () => root.unmount());
  });
});

test('block without metadata renders the plain label', async () => {
  const React = await import('react');
  const { renderToStaticMarkup } = await import('react-dom/server');
  const html = renderToStaticMarkup(React.createElement(block.PreviousContextBlock, { messageId: 'm2', children: 'body' }));
  assert.match(html, /<details[^>]*data-debug-id="conversation-previous-context-m2"/);
  assert.doesNotMatch(html, /<details[^>]*\sopen/);
  assert.match(html, />Previous context</);
  assert.doesNotMatch(html, /rollover/);
});

test('previous_context is never clubbed into start dividers or treated as a tool row', () => {
  // Rollover handoffs routinely say "restart"/"started"/"ready"; body sniffing must not catch them.
  const pctx = msg('pctx', 'previous_context', 'Context restarted; agent ready. Work started on T7.', { metadata: { context_pct: 80 } });
  assert.equal(block.isPreviousContextMessage(pctx), true);
  assert.equal(block.isPreviousContextMessage({ message_type: 'previous_context' }), true);
  assert.equal(block.isPreviousContextMessage(msg('t', 'text', 'x')), false);
  assert.equal(grouping.isAgentStartMessage(pctx), false);
  assert.equal(grouping.isLegacyToolMessage(pctx), false);

  const startA = msg('s1', 'system', 'Agent started.', { createdUnixMs: 900 });
  const startB = msg('s2', 'system', 'Agent started.', { createdUnixMs: 1100 });
  const grouped = grouping.groupTranscriptMessages([startA, pctx, startB]);
  assert.deepEqual(grouped.map((m: any) => m.messageType), ['system', 'previous_context', 'system']);
  assert.equal(grouped[1], pctx, 'kept as its own row, unchanged');

  const tool = msg('tool', 'tool_activity', '3 tools');
  assert.deepEqual(grouping.groupTranscriptMessages([tool, pctx, tool]).map((m: any) => m.messageId), ['pctx']);
});
