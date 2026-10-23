// Render the production form/list and exercise the real encrypted RTK endpoint.
// node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_multi_question_messages_test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import React, { act } from 'react';
import { JSDOM } from 'jsdom';
import { makeVaultStore, unlockVault, lockVaultFully } from './helpers/vaultEndpointHarness.ts';
import { keyringFromHex } from './helpers/vaultTestKeyring.ts';

const { default: Form } = await import('../src/ui/components/chat/MultiQuestionForm.tsx');
const { default: List } = await import('../src/ui/components/chat/ChatMessageList.tsx');
const { Provider } = await import('react-redux');
const { createRoot } = await import('react-dom/client');
const { chatEndpoints } = await import('../src/ui/api/endpoints/chats.ts');
const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
const events = await import('../src/ui/api/conversationMessageEvents.ts');
const { messageOptionsEligible } = await import('../src/ui/components/chat/types.ts');
const { groupTranscriptMessages } = await import('../src/ui/components/chat/transcriptGrouping.ts');
const { parseQuestionGroup, buildQuestionSubmission } = await import('../src/ui/components/chat/multiQuestion.ts');
const { encryptVaultText, decryptVaultText } = await import('../src/ui/utils/vaultContent.ts');

const KEY_HEX = '0123456789abcdef'.repeat(4);
const group = { version: 1 as const, questions: [
  { id: 'target', text: 'Where should this run?', options: [{ id: 'stage', label: 'Staging' }, { id: 'prod', label: 'Production' }] },
  { id: 'checks', text: 'Which checks?', selection_mode: 'multiple' as const, options: [{ id: 'smoke', label: 'Smoke' }, { id: 'integration', label: 'Integration' }] },
  { id: 'notes', text: 'What should we report?', options: [{ id: 'all', label: 'Everything' }] },
] };

function json(body: any, status = 200) {
  return { ok: status < 400, status, headers: { get: () => 'application/json' }, json: async () => body, text: async () => JSON.stringify(body) } as Response;
}
function row(id: string, extra: any = {}) {
  return { key: id, messageId: id, body: `Body for ${id}`, isUser: false, createdUnixMs: 1,
    deliveredUnixMs: 0, readUnixMs: 0, deliveryFailedUnixMs: 0, deliveryError: '', sending: false, authorLabel: 'Agent',
    messageType: 'multi_question', metadata: { multi_question: group }, isLatestMessage: true, optionsRevision: 0, ...extra };
}

async function withUI(run: (h: any) => Promise<void>) {
  const dom = new JSDOM('<!DOCTYPE html><div id="root"></div>', { url: 'http://localhost', pretendToBeVisual: true });
  // Like the attention harness, leave timer-backed rAF globals installed for
  // RTK's delayed subscription cleanup after the last window has closed.
  const keys = ['window', 'document', 'HTMLElement', 'Node', 'CustomEvent', 'IS_REACT_ACT_ENVIRONMENT', 'fetch'];
  const saved = new Map(keys.map((k) => [k, (globalThis as any)[k]]));
  for (const k of ['window', 'document', 'HTMLElement', 'Node', 'CustomEvent']) (globalThis as any)[k] = (dom.window as any)[k];
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  (globalThis as any).requestAnimationFrame = (cb: any) => setTimeout(() => cb(Date.now()), 0);
  (globalThis as any).cancelAnimationFrame = clearTimeout;
  dom.window.requestAnimationFrame = (globalThis as any).requestAnimationFrame;
  dom.window.cancelAnimationFrame = clearTimeout as any;
  dom.window.HTMLElement.prototype.scrollTo = function () {};
  dom.window.HTMLElement.prototype.scrollIntoView = function () {};
  dom.window.matchMedia = () => ({ matches: false, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} }) as any;
  const store = await makeVaultStore();
  const key = await unlockVault(store, KEY_HEX);
  globalThis.fetch = async () => json({ data: {} });
  const root = createRoot(dom.window.document.getElementById('root')!);
  const q = (id: string) => dom.window.document.querySelector(`[data-debug-id="${id}"]`) as any;
  const render = async (node: any) => {
    await act(async () => { root.render(React.createElement(Provider, { store }, node)); });
    await act(async () => { await new Promise((r) => setTimeout(r, 15)); });
  };
  const click = async (id: string) => { assert.ok(q(id), `missing ${id}`); await act(async () => q(id).click()); };
  // Existing jsdom convention: React's input feature detection ran before this
  // window existed. Drive the installed production handler for textarea changes.
  const type = async (id: string, value: string) => {
    const el = q(id); assert.ok(el);
    const props = Object.keys(el).find((k) => k.startsWith('__reactProps$'))!;
    await act(async () => { el.value = value; el[props].onChange({ target: el, currentTarget: el }); });
  };
  try { await run({ dom, store, key, root, q, render, click, type, text: () => dom.window.document.body.textContent || '' }); }
  finally {
    await act(async () => root.unmount());
    await lockVaultFully(store);
    await new Promise((r) => setTimeout(r, 30));
    dom.window.close();
    for (const [k, v] of saved) (globalThis as any)[k] = v;
  }
}
const form = (key: any, onSubmit: any, extra: any = {}) => React.createElement(Form, { group, eligible: true, vaultKey: key, debugPrefix: 'mq', onSubmit, ...extra });
async function fill(h: any) {
  await h.click('mq-question-target-option-stage');
  await h.click('mq-question-checks-option-smoke');
  await h.click('mq-question-checks-option-integration');
  await h.click('mq-question-notes-option-all');
  await h.type('mq-question-notes-custom', 'Only failures, please');
}

test('rendered mixed single/multiple/custom form validates and explicitly submits one complete answer', async () => {
  await withUI(async (h: any) => {
    const sent: any[] = [];
    await h.render(form(h.key, async (payload: any) => { sent.push(payload); }));
    assert.equal(h.q('mq-question-target-option-stage').type, 'radio');
    assert.equal(h.q('mq-question-checks-option-smoke').type, 'checkbox');
    await h.click('mq-submit');
    assert.match(h.text(), /Answer every question/);
    assert.equal(sent.length, 0);
    await fill(h);
    assert.equal(h.q('mq-question-notes-option-all').checked, false, 'custom replaces choices');
    assert.equal(sent.length, 0, 'selection must never send');
    await h.click('mq-submit');
    assert.equal(sent.length, 1);
    assert.deepEqual(sent[0].answers, [
      { question_id: 'target', option_ids: ['stage'] },
      { question_id: 'checks', option_ids: ['smoke', 'integration'] },
      { question_id: 'notes', custom_text: 'Only failures, please' },
    ]);
    assert.match(sent[0].body, /Which checks\?\nSmoke, Integration/);
    assert.match(h.text(), /Answers submitted/);
    assert.equal(h.dom.window.document.querySelectorAll('input,textarea,button').length, 0);
    for (const fieldset of h.dom.window.document.querySelectorAll('fieldset')) assert.ok(fieldset.querySelector('legend'));
  });
});

test('rendered pending submit prevents duplicates and a lost-response retry retains exact draft/key', async () => {
  await withUI(async (h: any) => {
    const sent: any[] = [];
    let reject: (error: Error) => void;
    await h.render(form(h.key, (payload: any) => {
      sent.push(payload);
      return sent.length === 1 ? new Promise((_resolve, fail) => { reject = fail; }) : Promise.resolve({ replayed: true });
    }));
    await fill(h);
    await h.click('mq-submit');
    assert.equal(h.q('mq-submit').disabled, true);
    await h.click('mq-submit');
    assert.equal(sent.length, 1);
    await act(async () => reject!(new Error('Connection lost')));
    assert.match(h.text(), /Connection lost.*draft is preserved/);
    assert.equal(h.q('mq-question-notes-custom').value, 'Only failures, please');
    assert.equal(h.q('mq-question-notes-custom').matches(':disabled'), true, 'retry preserves the exact potentially committed answer');
    await h.click('mq-submit');
    assert.equal(sent.length, 2);
    assert.deepEqual(sent[1], sent[0]);
    assert.match(h.text(), /Answers submitted/);
  });
});

test('server stale/answered errors retire controls and retain readable questions and draft', async () => {
  for (const code of ['question_stale', 'question_answered']) await withUI(async (h: any) => {
    await h.render(form(h.key, async () => { throw { code, error: 'This question has expired.' }; }));
    await fill(h); await h.click('mq-submit');
    assert.equal(h.q('mq-submit'), null);
    assert.equal(h.dom.window.document.querySelector('input,textarea'), null);
    assert.match(h.text(), /Where should this run/);
    assert.match(h.text(), /Only failures, please/);
    assert.match(h.text(), /This question has expired/);
  });
});

test('vault lock, unlock, relock, bad epoch and reload answered state never expose ciphertext controls', async () => {
  await withUI(async (h: any) => {
    const sealed = { version: 1 as const, questions: await Promise.all(group.questions.map(async (q) => ({
      ...q, text: await encryptVaultText(q.text, h.key), options: await Promise.all(q.options.map(async (o) => ({ ...o, label: await encryptVaultText(o.label, h.key) }))),
    }))) };
    const props = { group: sealed };
    await h.render(form(null, async () => {}, props));
    assert.ok(h.q('mq-locked')); assert.doesNotMatch(h.text(), /vault:v2:|Where should this run/);
    await h.render(form(h.key, async () => {}, props));
    assert.ok(h.q('mq-submit')); assert.match(h.text(), /Where should this run/);
    await h.render(form(null, async () => {}, props));
    assert.ok(h.q('mq-locked')); assert.doesNotMatch(h.text(), /Where should this run/);
    const wrongEpoch = { ...h.key, currentEpoch: 2, keys: new Map() };
    await h.render(form(wrongEpoch, async () => {}, props));
    assert.equal(h.q('mq-submit'), null);
    // A different authentic vault also resolves to a marker, never usable labels.
    const other = { ...await keyringFromHex('f'.repeat(64)), vaultId: '7e57000000000002' };
    await h.render(form(other, async () => {}, props));
    assert.equal(h.q('mq-submit'), null);
    await h.render(form(h.key, async () => {}, { ...props, key: 'reloaded', answered: true }));
    assert.ok(h.q('mq-answered')); assert.equal(h.q('mq-submit'), null);
    assert.match(h.text(), /Which checks/);
    assert.doesNotMatch(h.text(), /vault:v2:/);
  });
});

test('canonical last-message eligibility survives reversed timestamps, grouping, paging and both message directions', async () => {
  await withUI(async (h: any) => {
    const cid = 'chat_freshness';
    const source = row('source', { optionsRevision: events.conversationOptionsRevision(cid), createdUnixMs: 1000 });
    const messages = [source, row('older', { messageType: 'text', isLatestMessage: false, createdUnixMs: 9999, metadata: { options: ['Old chip'] } })];
    const show = (rows: any[]) => h.render(React.createElement(List, { conversationKey: cid, messages: rows, debugPrefix: 'chat', onAnswerQuestions: async () => {}, renderMessageBody: ({ message }: any) => React.createElement('p', null, message.body) }));
    await show(messages);
    assert.ok(h.q('chat-questions-source-submit'), 'server latest wins over timestamps/display order');
    assert.equal(h.q('chat-message-options-older'), null);
    // A user message and an agent message each retire the same source, before GET completes.
    for (const isUser of [true, false]) {
      await act(async () => events.expireConversationOptions(cid));
      await show([...messages, row(`new-${isUser}`, { isUser, messageType: 'text', isLatestMessage: false, metadata: {} })]);
      assert.equal(h.q('chat-questions-source-submit'), null);
      assert.match(h.text(), /Body for source/); assert.match(h.text(), /Where should this run/);
    }
    const shell = row('shell', { messageType: 'shell_run', metadata: { session_id: 'sh_example' }, isLatestMessage: false });
    await show(groupTranscriptMessages([shell, ...messages], new Set()));
    assert.equal(h.q('chat-questions-source-submit'), null, 'grouping or losing the newer row must not revive controls');
    await show([source]);
    assert.equal(h.q('chat-questions-source-submit'), null, 'a paginated subset cannot revive a previously latest row');
    assert.equal(messageOptionsEligible({ isLatestMessage: true, optionsRevision: events.conversationOptionsRevision(cid), questionAnswer: { answer_message_id: 'answer' } }, events.conversationOptionsRevision(cid)), false);
  });
});

test('legacy chips use canonical freshness and vault gating and send decrypted choice text', async () => {
  await withUI(async (h: any) => {
    const cid = 'chat_chips'; const replies: string[] = [];
    const body = await encryptVaultText('Pick one', h.key);
    const choice = await encryptVaultText('Go ahead', h.key);
    const source = row('chip', { body, messageType: 'text', metadata: { options: [choice] }, optionsRevision: events.conversationOptionsRevision(cid) });
    const show = () => h.render(React.createElement(List, { conversationKey: cid, messages: [source], debugPrefix: 'chat', onReply: (value: string) => replies.push(value), renderMessageBody: () => null }));
    await show();
    assert.ok(h.q('chat-option-chip-chip-0')); assert.match(h.text(), /Go ahead/); assert.doesNotMatch(h.text(), /vault:v2:/);
    await h.click('chat-option-chip-chip-0');
    await act(async () => { await new Promise((r) => setTimeout(r, 10)); });
    assert.deepEqual(replies, ['Go ahead']);
    await act(async () => events.expireConversationOptions(cid));
    assert.equal(h.q('chat-option-chip-chip-0'), null);
    source.optionsRevision = events.conversationOptionsRevision(cid);
    await h.render(null);
    await act(async () => lockVaultFully(h.store));
    await show(); assert.equal(h.q('chat-option-chip-chip-0'), null);
  });
});

test('real answer endpoint encrypts summary/custom, targets the source, preserves retry key and fails closed locked', async () => {
  await withUI(async (h: any) => {
    const captured: any[] = [];
    globalThis.fetch = async (url: any, init: any) => {
      captured.push({ url: String(url), payload: JSON.parse(init.body) });
      return json({ data: { message: { message_id: 'msg_answer_msg_source' }, question_answer: { answer_message_id: 'msg_answer_msg_source', answered_at: 'now' }, replayed: captured.length > 1 } }, 201);
    };
    const draft = { target: { optionIds: ['stage'], customText: '' }, checks: { optionIds: ['smoke', 'integration'], customText: '' }, notes: { optionIds: [], customText: 'Only failures' } };
    const submission = buildQuestionSubmission(group, draft, 'retry_key_1');
    const send = () => h.store.dispatch(chatEndpoints.endpoints.answerConversationQuestions.initiate({ conversationId: 'chat/id', sourceMessageId: 'msg/source', submission })).unwrap();
    await send(); await send();
    assert.equal(captured.length, 2);
    assert.match(captured[0].url, /chats\/chat%2Fid\/messages\/msg%2Fsource\/answers$/);
    for (const { payload } of captured) {
      assert.equal(payload.idempotency_key, 'retry_key_1');
      assert.match(payload.body, /^vault:v2:/);
      assert.equal(await decryptVaultText(payload.body, h.key), submission.body);
      assert.equal(await decryptVaultText(payload.answers[2].custom_text, h.key), 'Only failures');
      assert.deepEqual(payload.answers[1].option_ids, ['smoke', 'integration']);
      assert.doesNotMatch(JSON.stringify(payload), /Only failures|Where should this run/);
    }
    await lockVaultFully(h.store);
    await assert.rejects(send(), (error: any) => /Unlock Vault/.test(error.error));
    assert.equal(captured.length, 2, 'locked path must not send any request');
  });
});

test('real endpoint preserves stale codes and newest/older reads keep opaque cursors and race-safe freshness', async () => {
  await withUI(async (h: any) => {
    const cid = 'chat_pages';
    let release: () => void = () => {};
    const gate = new Promise<void>((resolve) => { release = resolve; });
    let waiting = false;
    let stale = false;
    globalThis.fetch = async (url: any, init: any = {}) => {
      if (init.method === 'POST') return json({ error: { code: 'question_stale', message: 'Newer message exists' } }, 409);
      if (waiting) await gate;
      assert.ok(!String(url).includes('NaN'));
      return json({ data: [{ message_id: 'source', is_latest_message: !stale, question_answer: null }], page: { next_cursor: '2026-10-22T13:00:00Z|msg_tie', has_more: true } });
    };
    const request = (cursor = '') => h.store.dispatch(chatEndpoints.endpoints.fetchConversationMessages.initiate({ conversationId: cid, cursor }, { subscribe: false, forceRefetch: true }));
    const initial = await request().unwrap();
    assert.equal(initial.nextCursor, '2026-10-22T13:00:00Z|msg_tie');
    assert.ok(initial.messages[0].is_latest_message);
    waiting = true;
    const raced = request(initial.nextCursor);
    await act(async () => events.expireConversationOptions(cid));
    release();
    const older = await raced.unwrap();
    assert.equal(messageOptionsEligible({ isLatestMessage: true, optionsRevision: older.messages[0].optionsRevision }, events.conversationOptionsRevision(cid)), false, 'response started before new-message event stays expired');
    waiting = false; stale = true;
    const fresh = await request().unwrap();
    assert.equal(fresh.messages[0].is_latest_message, false);
    const result = await h.store.dispatch(chatEndpoints.endpoints.answerConversationQuestions.initiate({ conversationId: cid, sourceMessageId: 'source', submission: { version: 1, idempotency_key: 'retry', body: 'Answer', answers: [] } }));
    assert.equal(result.error.code, 'question_stale'); assert.equal(result.error.originalStatus, 409);
  });
});

test('versioned metadata rejects malformed IDs/modes/counts and custom answer limits', () => {
  assert.ok(parseQuestionGroup({ multi_question: group }));
  for (const malformed of [ { ...group, version: 2 }, { ...group, questions: [] }, { ...group, questions: [group.questions[0], group.questions[0]] }, { ...group, questions: [{ ...group.questions[0], selection_mode: 'all' }] } ]) assert.equal(parseQuestionGroup({ multi_question: malformed }), null);
  assert.throws(() => buildQuestionSubmission(group, { target: { optionIds: [], customText: 'x'.repeat(8193) } }, 'key'), /8192/);
});

test('prototype-named question IDs render, validate, update and submit without inherited drafts', async () => {
  const special = { version: 1 as const, questions: ['constructor', 'toString', '__proto__'].map((id, i) => ({
    ...group.questions[i], id,
  })) };
  assert.ok(parseQuestionGroup({ multi_question: special }));
  for (const q of special.questions) {
    const single = { version: 1 as const, questions: [q] };
    assert.throws(() => buildQuestionSubmission(single, {}, 'key'), /Answer every question/);
    const inherited = Object.create({ [q.id]: { optionIds: [q.options[0].id], customText: '' } });
    assert.throws(() => buildQuestionSubmission(single, inherited, 'key'), /Answer every question/);
    const own = { [q.id]: { optionIds: [q.options[0].id], customText: '' } };
    assert.deepEqual(buildQuestionSubmission(single, own, 'key').answers, [
      { question_id: q.id, option_ids: [q.options[0].id] },
    ]);
  }
  await withUI(async (h: any) => {
    const sent: any[] = [];
    const show = (extra: any = {}) => h.render(form(h.key, async (payload: any) => { sent.push(payload); }, { group: special, ...extra }));
    await show({ eligible: false });
    assert.equal(h.q('mq-submit'), null);
    assert.match(h.text(), /Where should this run/);
    await show();
    await h.click('mq-submit');
    assert.match(h.text(), /Answer every question/);
    assert.equal(sent.length, 0);
    await h.click('mq-question-constructor-option-stage');
    await h.click('mq-question-toString-option-smoke');
    await h.click('mq-question-toString-option-integration');
    await h.click('mq-question-__proto__-option-all');
    await h.type('mq-question-__proto__-custom', 'Special ID answer');
    assert.equal(h.q('mq-question-__proto__-option-all').checked, false);
    assert.equal(h.q('mq-question-constructor-option-stage').checked, true);
    assert.equal(sent.length, 0);
    await h.click('mq-submit');
    assert.deepEqual(sent[0].answers, [
      { question_id: 'constructor', option_ids: ['stage'] },
      { question_id: 'toString', option_ids: ['smoke', 'integration'] },
      { question_id: '__proto__', custom_text: 'Special ID answer' },
    ]);
    assert.match(h.text(), /Answers submitted/);
    assert.match(h.text(), /Special ID answer/);
    assert.equal(h.dom.window.document.querySelector('input,textarea,button'), null);
    await show({ key: 'reloaded-special-ids', answered: true });
    assert.match(h.text(), /Answers submitted/);
    assert.match(h.text(), /Which checks/);
  });
});
