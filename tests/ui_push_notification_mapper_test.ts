import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

test('planForPushPayload maps Web Push payloads and provides total visible fallbacks', async () => {
const { planForPushPayload } = await import('../src/ui/api/pushNotificationMapper.ts');

// --- Full payload round-trips faithfully ----------------------------------
{
  const plan = planForPushPayload({
    title: 'New message',
    body: 'Deployment finished successfully.',
    tag: 'heimdall:chat:conv_1',
    route: '/conversations/conv_1',
    category: 'chat',
    href: 'https://hub.test/index.html#/conversations/conv_1',
  });
  assert.equal(plan.title, 'New message');
  assert.match(plan.body, /Deployment finished/);
  assert.equal(plan.tag, 'heimdall:chat:conv_1', 'tag preserved for coalescing');
  assert.equal(plan.route, '/conversations/conv_1');
  assert.equal(plan.href, 'https://hub.test/index.html#/conversations/conv_1');
  assert.equal(plan.category, 'chat');
}

// --- attention category preserved -----------------------------------------
{
  const plan = planForPushPayload({
    title: 'Agent needs your input',
    body: 'An agent is waiting for your response.',
    tag: 'heimdall:attention:approval:chain_9',
    route: '/chains/chain_9',
    category: 'attention',
    href: 'https://hub.test/#/chains/chain_9',
  });
  assert.equal(plan.category, 'attention');
  assert.equal(plan.route, '/chains/chain_9');
}

// --- unknown/invalid category falls back to 'attention' -------------------
{
  const plan = planForPushPayload({ title: 't', body: 'b', category: 'weird' });
  assert.equal(plan.category, 'attention', 'unknown category => attention');
}

// --- category match is exact + case-sensitive -----------------------------
// Only the literal 'chat' is the chat bucket; anything else (including a
// different case) is treated as 'attention' so per-category behaviour stays
// predictable and can't be spoofed by a mis-cased wire value.
{
  assert.equal(planForPushPayload({ category: 'Chat' }).category, 'attention', "'Chat' is not 'chat'");
  assert.equal(planForPushPayload({ category: 'CHAT' }).category, 'attention', "'CHAT' is not 'chat'");
  assert.equal(planForPushPayload({ category: 'attention' }).category, 'attention');
}

// --- TOTAL: null payload => visible Heimdall fallback ---------------------
{
  const plan = planForPushPayload(null);
  assert.equal(plan.title, 'Heimdall', 'null payload still shows a title');
  assert.equal(plan.body, 'You have a new notification.');
  assert.equal(plan.tag, 'heimdall:push');
  assert.equal(plan.route, '/conversations');
  assert.equal(plan.href, '');
  assert.equal(plan.category, 'attention');
}

// --- TOTAL: empty object => same fallback ---------------------------------
{
  const plan = planForPushPayload({});
  assert.equal(plan.title, 'Heimdall');
  assert.equal(plan.body, 'You have a new notification.');
  assert.equal(plan.route, '/conversations');
}

// --- TOTAL: non-null, non-object payloads still yield the fallback ---------
// event.data.json() could yield a JSON primitive/array (not the expected
// object). The mapper's `typeof === 'object'` guard must treat these like an
// empty payload so the SW can still show a visible notification.
for (const bad of ['a raw string', 42, true, ['not', 'an', 'object']] as unknown[]) {
  const plan = planForPushPayload(bad as never);
  assert.equal(plan.title, 'Heimdall', `non-object payload (${typeof bad}) => fallback title`);
  assert.equal(plan.body, 'You have a new notification.');
  assert.equal(plan.category, 'attention');
}

// --- partial payload: missing fields fall back individually ---------------
{
  const plan = planForPushPayload({ title: 'Only a title' });
  assert.equal(plan.title, 'Only a title', 'provided field kept');
  assert.equal(plan.body, 'You have a new notification.', 'missing body falls back');
  assert.equal(plan.tag, 'heimdall:push', 'missing tag falls back');
  assert.equal(plan.route, '/conversations', 'missing route falls back');
}

// --- body is whitespace-collapsed and truncated ---------------------------
{
  const long = 'x'.repeat(300);
  const plan = planForPushPayload({ title: 'a\n\tb', body: `line1\n\n   line2 ${long}` });
  assert.equal(plan.title, 'a b', 'whitespace collapsed in title');
  assert.ok(plan.body.length <= 140, 'body truncated to <=140 chars');
  assert.ok(plan.body.endsWith('…'), 'truncated body ends with ellipsis');
}

// --- title is whitespace-collapsed and truncated too ----------------------
// The title runs through the same normalize/truncate path as the body, so a
// long title is clamped to <=140 chars with a trailing ellipsis.
{
  const plan = planForPushPayload({ title: `New\tmessage ${'y'.repeat(300)}` });
  assert.ok(plan.title.length <= 140, 'title truncated to <=140 chars');
  assert.ok(plan.title.endsWith('…'), 'truncated title ends with ellipsis');
  assert.ok(plan.title.startsWith('New message '), 'title whitespace collapsed');
}

// --- whitespace-only fields collapse to empty => fallback -----------------
// truncate() collapses runs of whitespace and trims, so an all-whitespace
// title/body becomes '' and the `|| FALLBACK` guard shows the Heimdall default
// (never a blank, silent-looking notification that iOS would penalise).
{
  const plan = planForPushPayload({ title: '   \n\t  ', body: '\n\n   ' });
  assert.equal(plan.title, 'Heimdall', 'whitespace-only title => fallback');
  assert.equal(plan.body, 'You have a new notification.', 'whitespace-only body => fallback');
}

// --- truncation boundary: exactly max stays intact, one over is clipped ---
{
  const exact = 'z'.repeat(140);
  const over = 'z'.repeat(141);
  const atLimit = planForPushPayload({ title: 'ok', body: exact });
  assert.equal(atLimit.body, exact, 'body at the 140-char limit is not truncated');
  assert.ok(!atLimit.body.endsWith('…'), 'at-limit body has no ellipsis');
  const clipped = planForPushPayload({ title: 'ok', body: over }).body;
  assert.equal(clipped.length, 140, 'over-limit body clipped to exactly 140 chars');
  assert.ok(clipped.endsWith('…'), 'over-limit body ends with ellipsis');
}
});

test('shipped service worker masks armored Web Push bodies before rendering', async () => {
  const handlers = new Map<string, (event: any) => void>();
  const shown: Array<{ title: string; options: Record<string, any> }> = [];
  const self = {
    addEventListener(type: string, handler: (event: any) => void) {
      handlers.set(type, handler);
    },
    skipWaiting() {},
    clients: {
      claim: async () => {},
      matchAll: async () => [],
      openWindow: async () => {},
    },
    registration: {
      showNotification: async (title: string, options: Record<string, any>) => {
        shown.push({ title, options });
      },
      pushManager: null,
    },
  };

  const source = await readFile(new URL('../public/notification-sw.js', import.meta.url), 'utf8');
  vm.runInNewContext(source, { self }, { filename: 'public/notification-sw.js' });
  const push = handlers.get('push');
  assert.ok(push, 'the shipped worker must register a push handler');

  async function dispatch(payload: unknown, throws = false) {
    let pending: Promise<void> | undefined;
    push!({
      data: throws ? { json: () => { throw new Error('malformed'); } } : { json: () => payload },
      waitUntil(value: Promise<void>) { pending = value; },
    });
    await pending;
    return shown.at(-1)!;
  }

  const armored = await dispatch({
    title: `Notice vault:v1:${'B'.repeat(40)}`,
    body: `You: vault:v1:${'A'.repeat(180)}`,
    tag: 'heimdall:chat:conv_secret',
    route: '/conversations/inst_secret',
  });
  assert.equal(armored.title, '[🔒 Encrypted notification]');
  assert.equal(armored.options.body, '[🔒 Encrypted notification]');
  assert.doesNotMatch(armored.title, /vault:v1:/);
  assert.doesNotMatch(armored.options.body, /vault:v1:/);

  const plaintext = await dispatch({ title: 'New message', body: 'Plaintext body' });
  assert.equal(plaintext.options.body, 'Plaintext body');

  const enrollment = await dispatch({
    title: 'Bridge enrollment approved',
    body: 'A machine was just approved to enroll as a bridge on your account.',
  });
  assert.match(enrollment.options.body, /machine was just approved/);

  const malformed = await dispatch(null, true);
  assert.equal(malformed.title, 'Heimdall');
  assert.equal(malformed.options.body, 'You have a new notification.');
});
