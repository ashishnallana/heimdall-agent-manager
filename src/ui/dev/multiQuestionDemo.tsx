/** Local evidence fixture: real chat list/form, ephemeral test key, mocked delivery.
 * No backend, cookie auth or production message sends. Not a build entry. */
import { useState } from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { configureStore } from '@reduxjs/toolkit';
import ChatMessageList from '../components/chat/ChatMessageList';
import type { ChatMessage } from '../components/chat/types';
import type { QuestionGroup, QuestionSubmission } from '../components/chat/multiQuestion';
import { conversationOptionsRevision, expireConversationOptions } from '../api/conversationMessageEvents';
import vaultReducer, { keyringInstalled, keyringCleared } from '../store/vaultSlice';
import { setActiveVaultKey, encryptVaultText } from '../utils/vaultCrypto';
import { applyThemeToDocument } from '../store/themeSlice';
import '../styles.css';

async function main() {
  applyThemeToDocument('default-dark');
  const key = { userId: 'usr_fixture', vaultId: '7e57000000000001', currentEpoch: 1,
    keys: new Map([[1, await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt'])]]) };
  setActiveVaultKey(key);
  const store = configureStore({ reducer: { vault: vaultReducer } });
  store.dispatch(keyringInstalled({ currentEpoch: 1 }));
  const cid = 'chat_local_multi_question_fixture';
  const questions: QuestionGroup = { version: 1, questions: [
    { id: 'target', text: 'Where should the release go?', options: [{ id: 'staging', label: 'Staging' }, { id: 'production', label: 'Production' }] },
    { id: 'checks', text: 'Which checks should run?', selection_mode: 'multiple', options: [{ id: 'smoke', label: 'Smoke tests' }, { id: 'integration', label: 'Integration tests' }] },
    { id: 'report', text: 'What should the report include?', options: [{ id: 'full', label: 'Full report' }, { id: 'failures', label: 'Failures only' }] },
  ] };
  const sealed = { version: 1, questions: await Promise.all(questions.questions.map(async (q) => ({ ...q,
    text: await encryptVaultText(q.text, key), options: await Promise.all(q.options.map(async (o) => ({ ...o, label: await encryptVaultText(o.label, key) }))),
  }))) };
  const initialAnswered = new URLSearchParams(location.search).get('state') === 'answered';
  const base: ChatMessage = { key: 'source', messageId: 'source', body: 'Choose the release settings. Submit all answers when you are ready.',
    isUser: false, createdUnixMs: Date.UTC(2026, 9, 22, 14), deliveredUnixMs: 0, readUnixMs: 0, deliveryFailedUnixMs: 0, deliveryError: '',
    sending: false, authorLabel: 'Agent', messageType: 'multi_question', metadata: { multi_question: sealed },
    isLatestMessage: !initialAnswered, optionsRevision: conversationOptionsRevision(cid),
    questionAnswer: initialAnswered ? { answer_message_id: 'answer', answered_at: '2026-10-22T14:01:00Z' } : null };

  function Demo() {
    const [messages, setMessages] = useState<ChatMessage[]>([base]);
    const [locked, setLocked] = useState(false);
    const [fail, setFail] = useState(false);
    const [deliveries, setDeliveries] = useState(0);
    const addMessage = (isUser: boolean) => {
      expireConversationOptions(cid);
      setMessages((rows) => [...rows, { ...base, key: crypto.randomUUID(), messageId: crypto.randomUUID(),
        body: isUser ? 'A newer user message.' : 'A newer agent message.', isUser, messageType: 'text', metadata: {}, isLatestMessage: false }]);
    };
    const submit = async (_source: string, submission: QuestionSubmission) => {
      if (fail) { setFail(false); throw new Error('Simulated connection loss. Retry your answers.'); }
      setDeliveries((n) => n + 1);
      expireConversationOptions(cid);
      setMessages((rows) => [...rows.map((row) => row.messageId === 'source' ? { ...row, questionAnswer: { answer_message_id: 'answer', answered_at: '2026-10-22T14:01:00Z' } } : row),
        { ...base, key: 'answer', messageId: 'answer', body: submission.body, isUser: true, messageType: 'multi_question_answer', metadata: {}, isLatestMessage: false }]);
    };
    return <main className="mx-auto flex min-h-screen max-w-3xl flex-col gap-4 bg-canvas p-3 text-primary sm:p-6">
      <header className="space-y-2"><h1 className="text-xl font-semibold">Release settings</h1>
        <p className="text-sm text-muted">Local UI fixture · encrypted questions · mocked delivery</p>
        <div className="flex flex-wrap gap-2">
          <button type="button" data-debug-id="mq-demo-new-user" className="min-h-11 rounded-lg border border-subtle px-3 text-sm" onClick={() => addMessage(true)}>New user message</button>
          <button type="button" data-debug-id="mq-demo-new-agent" className="min-h-11 rounded-lg border border-subtle px-3 text-sm" onClick={() => addMessage(false)}>New agent message</button>
          <button type="button" data-debug-id="mq-demo-lock" className="min-h-11 rounded-lg border border-subtle px-3 text-sm" onClick={() => {
            setActiveVaultKey(locked ? key : null);
            store.dispatch(locked ? keyringInstalled({ currentEpoch: 1 }) : keyringCleared()); setLocked(!locked);
          }}>{locked ? 'Unlock fixture' : 'Lock fixture'}</button>
          <button type="button" data-debug-id="mq-demo-fail" aria-pressed={fail} className="min-h-11 rounded-lg border border-subtle px-3 text-sm" onClick={() => setFail(!fail)}>Fail next send</button>
        </div>
        <p data-debug-id="mq-demo-deliveries" role="status" className="text-sm text-muted">Mock deliveries: {deliveries}</p>
      </header>
      <ChatMessageList conversationKey={cid} messages={messages} debugPrefix="mq-demo" onAnswerQuestions={submit}
        wrapperClassName="min-w-0 flex-1" scrollClassName="space-y-4" />
    </main>;
  }
  createRoot(document.getElementById('root')!).render(<Provider store={store}><Demo /></Provider>);
}
void main();
