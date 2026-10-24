// Isolated browser fixture: actual production components/styles, synthetic stream
// frames, no Hub connection or production data. See live_tool_motion_browser.mjs.
import React, { useState } from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { configureStore } from '@reduxjs/toolkit';
import ChatMessageList from '../../../src/ui/components/chat/ChatMessageList';
import LiveToolActivity from '../../../src/ui/components/extension/LiveToolActivity';
import reducer from '../../../src/ui/store/toolActivitySlice';
import { heimdallApi } from '../../../src/ui/api/heimdallApi';
import { FakeToolSocket, snapshot } from '../../helpers/toolStreamHarness';
import '../../../src/ui/styles.css';

let socket: FakeToolSocket;
let generation = 1, revision = 0, calls: any[] = [];
let needsBaseline = false;
let current = snapshot('inst_fixture', ++revision, { active: [] });
window.WebSocket = class extends FakeToolSocket {
  constructor(url: string) { super(url); socket = this; setTimeout(() => this.open(), 0); }
  send(data: string) {
    super.send(data);
    const frame = JSON.parse(data);
    if (frame.type === 'subscribe') this.state(current);
    if (frame.type === 'ping') this.frame({ type: 'pong' });
  }
} as any;
const store = configureStore({
  reducer: { toolActivity: reducer, chat: (s = { session: { userId: 'fixture' } }) => s,
    vault: (s = {}) => s, [heimdallApi.reducerPath]: heimdallApi.reducer },
  middleware: (gdm) => gdm().concat(heimdallApi.middleware),
});
const message = (n: number, own = false) => ({ key: 'm' + n, messageId: 'm' + n,
  body: 'Conversation message ' + n, isUser: own, createdUnixMs: 1, messageType: 'tool_activity', metadata: {} });
const fixture: any = {
  scrollWrites: [], opened: [],
  deliveryTimes: [],
  setCalls(ids: number[], status = 'completed') {
    const next = ids.map((id) => ({ ...snapshot('inst_fixture').active[0],
      call_id: 'call_' + id, summary: 'Tool call ' + id + ': rg pattern src', started_at_ms: Date.now() - 1000 }));
    const completed = calls.filter((call) => !next.some((n) => n.call_id === call.call_id))
      .map((call) => ({ ...call, status, duration_ms: 1234, completed_at_ms: Date.now() }));
    calls = next;
    current = snapshot('inst_fixture', ++revision, { generation, active: next, completed_since_last: completed });
    socket.state(current, needsBaseline);
    needsBaseline = false;
  },
  completeOnly(id: number, status = 'completed', baseline = false, refresh = false) {
    const call = { ...snapshot('inst_fixture').active[0], call_id: 'call_' + id,
      summary: 'Instant tool call ' + id, status, duration_ms: 17, completed_at_ms: Date.now() };
    current = snapshot('inst_fixture', ++revision, { generation, active: calls, completed_since_last: [call] });
    socket.state(current, baseline || needsBaseline, refresh);
    needsBaseline = false;
  },
  replay() { socket.state(current, false); },
  coalescedHistory(id: number) {
    fixture.completeOnly(id, 'completed', true);
    fixture.completeOnly(id);
    fixture.completeOnly(id + 1, 'completed', false, true);
    fixture.completeOnly(id + 1);
  },
  fastCall(id: number, status = 'completed') {
    const started = performance.now();
    fixture.setCalls([id]);
    setTimeout(() => {
      fixture.setCalls([], status);
      fixture.deliveryTimes.push({ id, elapsed: performance.now() - started });
    }, 20);
  },
  unavailable() {
    socket.frame({ type: 'unavailable', instance_id: 'inst_fixture', reason: 'bridge_offline' });
    calls = []; needsBaseline = true;
  },
  reset() { generation++; calls = []; fixture.setCalls([]); },
};
(window as any).motionFixture = fixture;
const originalScrollTo = HTMLElement.prototype.scrollTo;
HTMLElement.prototype.scrollTo = function (...args: any[]) {
  fixture.scrollWrites.push({ at: performance.now(), id: this.getAttribute('data-debug-id'), args });
  return originalScrollTo.apply(this, args as any);
};

function App() {
  const [messages, setMessages] = useState(() => Array.from({ length: 40 }, (_, n) => message(n)));
  const [inset, setInset] = useState(0);
  fixture.setInset = setInset;
  fixture.setMessageCount = (count: number) => setMessages(Array.from({ length: count }, (_, n) => message(n)));
  fixture.prepend = () => setMessages((rows) => [...Array.from({ length: 8 }, (_, n) => message(n - 8)), ...rows]);
  fixture.append = (own = false) => setMessages((rows) => [...rows, message(rows.length, own)]);
  return <div style={{ height: '100dvh', display: 'flex', flexDirection: 'column', background: 'var(--color-canvas)' }}>
    <div style={{ padding: 12, display: 'flex', flexWrap: 'wrap', gap: 12, color: 'var(--color-text-primary)' }}>
      <strong>Isolated live tool motion fixture</strong>
      <button data-debug-id="fixture-start" onClick={() => fixture.setCalls([1, 2, 3])}>Start calls</button>
      <button data-debug-id="fixture-success" onClick={() => fixture.setCalls([], 'completed')}>Succeed</button>
      <button data-debug-id="fixture-fail" onClick={() => fixture.setCalls([], 'failed')}>Fail</button>
      <button data-debug-id="fixture-unavailable" onClick={() => fixture.unavailable()}>Disconnect</button>
    </div>
    <ChatMessageList conversationKey="fixture" debugPrefix="fixture" messages={messages as any}
      bottomInset={inset} renderMessageBody={({ message }) => <div style={{ height: 64 }}>{message.body}</div>}>
      <LiveToolActivity instanceId="inst_fixture" onOpenShell={(id) => fixture.opened.push(id)} />
    </ChatMessageList>
  </div>;
}
createRoot(document.getElementById('root')!).render(<Provider store={store}><App /></Provider>);
