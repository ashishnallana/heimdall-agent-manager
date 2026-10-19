/**
 * DEV-ONLY composer demo (REQ-DEMO-1..5), served by Vite at `composer-demo.html`.
 * ---------------------------------------------------------------------------
 * Lets a reviewer judge the floating gradient-frost mobile composer in the Heimdall
 * preview, where the full app cannot run: the vault refuses non-UI origins by design.
 * Nothing here talks to the network, the vault or auth. The redux store below only
 * exists because `ChatMessageList` / `Markdown` read it with `useSelector`; it holds
 * only the vault slice (no API slice, no chat slice), so no request can be issued
 * from this page.
 *
 * What is real and what is stubbed:
 * - REAL: `ChatMessageList` (bottom inset, auto-scroll, jump-to-latest),
 *   `MessageComposerInput`, `MessageComposerActions` (+ upload, terminal, model
 *   switcher, send), the `StatusDot` runtime indicator, `Icon`, `Menu`, and
 *   the `ui-float-dock` / `ui-frost-*` / `ui-liquid-glass` classes from styles.css.
 * - MIRRORED: the dock + card markup from the mobile branch of
 *   `AgentChatPane.renderComposer` (AgentChatPane itself needs the API and vault).
 *   Keep the two in sync when the mobile composer markup changes.
 * - MIRRORED: the floating header (menu, title/subtitle, "…") from the reference
 *   screenshots.
 * - STUBBED: composer callbacks; "sending" appends locally and fakes an agent reply;
 *   the runtime status is local state (tap the indicator at the top right of the
 *   composer card to toggle it); the terminal and tasks buttons only show a toast (see
 *   `ComposerDemo` for the real handlers).
 *
 * URL presets, so a state can be linked or screenshotted without interaction:
 *   ?theme=light|dark   start in that appearance
 *   ?draft=<text>       prefill the composer (use %0A for extra lines)
 *   ?scroll=top         start scrolled to the top, which shows jump-to-latest
 *   ?status=running|stopped  runtime indicator state (default running)
 *
 * Not shipped: vite.config.js has no `rollupOptions.input`, so `vite build` emits only
 * index.html (REQ-DEMO-5).
 */
import { StrictMode, useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from 'react';
import ReactDOM from 'react-dom/client';
import { Provider } from 'react-redux';
import { combineReducers, configureStore } from '@reduxjs/toolkit';
import { Icon, Menu, StatusDot, runtimeStatusToTone } from '@ui';
import ChatMessageList from '../components/chat/ChatMessageList';
import { MessageComposerActions, MessageComposerInput } from '../components/chat/MessageComposer';
import type { ChatMessage, ChatTimestamp } from '../components/chat/types';
import vaultReducer from '../store/vaultSlice';
import { applyThemeToDocument } from '../store/themeSlice';
import { getTheme } from '../theme/registry';
import { installAppViewportHeightSync } from '../utils/appViewportHeight';
import '../styles.css';

const DARK_THEME_ID = 'default-dark';
const LIGHT_THEME_ID = 'catppuccin-latte';

const demoStore = configureStore({
  reducer: combineReducers({ vault: vaultReducer }),
});

const START_MS = Date.UTC(2026, 9, 19, 9, 0, 0);

function message(index: number, isUser: boolean, body: string): ChatMessage {
  const createdUnixMs = START_MS + index * 90_000;
  return {
    key: `demo-${index}`,
    messageId: `msg_demo_${index}`,
    body,
    isUser,
    createdUnixMs,
    deliveredUnixMs: isUser ? createdUnixMs + 1_000 : 0,
    readUnixMs: isUser ? createdUnixMs + 2_000 : 0,
    deliveryFailedUnixMs: 0,
    deliveryError: '',
    sending: false,
    authorLabel: isUser ? 'You' : 'worker',
  };
}

// Busy content on purpose: headings, lists, tables, inline code, links and fenced code
// give the frost layers high-contrast edges to blur.
const SAMPLE_BODIES: Array<[boolean, string]> = [
  [true, 'Can you look at why the bridge reconnect loop spins after a laptop sleeps?'],
  [false, `### Reconnect loop after sleep

I reproduced it. After resume the socket reports \`readyState === CLOSED\`, but the backoff timer was created **before** the sleep, so it fires immediately and every retry lands in the same tick.

- Root cause: \`scheduleReconnect()\` compares against \`Date.now()\` captured pre-sleep.
- Effect: ~40 reconnect attempts per second until the hub rate-limits us.
- See [the backoff notes](https://example.com/docs/backoff) for the intended curve.`],
  [true, 'Makes sense. What would the fix look like?'],
  [false, `Use a monotonic clock and reset the attempt counter on \`visibilitychange\`:

\`\`\`ts
function scheduleReconnect(attempt: number) {
  const delay = Math.min(30_000, 500 * 2 ** attempt);
  const due = performance.now() + delay;
  timer = setTimeout(function tick() {
    if (performance.now() < due) return void (timer = setTimeout(tick, due - performance.now()));
    connect();
  }, delay);
}

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') attempt = 0;
});
\`\`\`

That keeps the curve intact across sleep and caps the delay at 30s.`],
  [true, 'Ship it, and add a test please.'],
  [false, `#### Test plan

| Case | Expectation |
| --- | --- |
| Sleep 10 min, resume | one reconnect within 500 ms |
| Hub down 2 min | backoff 0.5s → 30s, no burst |
| Tab hidden | no reconnects while hidden |

Running \`npm test -- tests/ui_pane_transport_e2e_test.ts\` now.`],
  [false, `All **14** transport tests pass. I also noticed \`PaneWriteBatcher\` flushes on every keystroke when \`coalesce=false\`; that is unrelated, so I left a note in the task instead of changing it.

> Commit \`a1b2c3d\` on \`fix/reconnect-after-sleep\`.`],
  [true, 'Great. While you are there, can you summarize what the floating composer change does?'],
  [false, `### Floating mobile composer

1. The dock is \`position: absolute\` over the transcript on phones.
2. A \`ResizeObserver\` reports its height as \`bottomInset\`, so the list ends with a spacer that tall.
3. \`.ui-frost-gradient\` stacks three masked backdrop layers: **28px** blur behind the input row fading to **6px** at the action row.
4. \`.ui-frost-tail\` continues a light frost edge to edge beneath the card.

\`\`\`css
.ui-float-dock { pointer-events: none; }
.ui-float-dock > form > div > * { pointer-events: auto; }
\`\`\``],
  [true, 'And on browsers without backdrop-filter?'],
  [false, `An \`@supports not (backdrop-filter: blur(1px))\` block swaps the stack for a nearly solid card with a slight top-to-bottom tint, and hides layers 2 and 3. The tail becomes a 15%-transparent canvas wash. Nothing reflows, so the inset math is identical.`],
  [false, `Last message in the sample transcript. With the reader pinned to the bottom, this line must sit **fully above** the composer card, and growing the draft to three lines must keep it there.`],
];

const SAMPLE_MESSAGES: ChatMessage[] = SAMPLE_BODIES.map(([isUser, body], index) => message(index, isUser, body));

const AGENT_REPLY = `Got it (demo reply, nothing was sent). The newest message should land just above the composer.`;

const PRESETS = new URLSearchParams(window.location.search);

const timeFormatter = new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' });

function formatTimestamp(unixMs: number): ChatTimestamp {
  if (!unixMs) return { label: '', iso: '' };
  const date = new Date(unixMs);
  return { label: timeFormatter.format(date), iso: date.toISOString() };
}

function currentAppearance(): 'dark' | 'light' {
  return getTheme(document.documentElement.dataset.theme).appearance;
}

type DemoRuntimeStatus = 'running' | 'stopped';

// Solid canvas tint behind the title and subtitle, fading out below the header, so
// transcript text never bleeds through the title. A plain gradient rather than the
// `.ui-frost-tail` blur + mask recipe: with mask-image the layer let text show through
// even where the mask is opaque. Inline because Tailwind's `from-canvas/90` emits no
// gradient for the var-based token.
const HEADER_WASH_STYLE = {
  background:
    'linear-gradient(to bottom, color-mix(in oklab, var(--color-canvas), transparent 3%) 70%, transparent)',
} as const;

/**
 * Mirrors the floating mobile header from the reference screenshots: round menu button,
 * title/subtitle and a round "…" button floating over the transcript. Runtime status,
 * terminal and tasks live in the composer card, not here. The "…" menu holds the
 * light/dark switch and a second way to toggle the stubbed runtime status.
 */
function DemoHeader({
  status,
  onToggleStatus,
}: {
  status: DemoRuntimeStatus;
  onToggleStatus: () => void;
}) {
  const [appearance, setAppearance] = useState(currentAppearance);
  const [menuOpen, setMenuOpen] = useState(false);
  const nextAppearance = appearance === 'dark' ? 'light' : 'dark';
  const running = status === 'running';
  const roundButton =
    'ui-liquid-glass pointer-events-auto grid h-11 w-11 shrink-0 place-items-center rounded-full text-primary';
  return (
    <header
      data-debug-id="composer-demo-header"
      className="pointer-events-none absolute inset-x-0 top-0 z-30 flex items-center gap-2 px-3 pb-2 pt-[max(env(safe-area-inset-top),0.75rem)]"
    >
      {/* Blurred wash behind the floating controls so the title stays legible over the
          transcript; fades out below the header like the reference. */}
      <div
        aria-hidden="true"
        className="absolute inset-x-0 top-0 -z-10 h-[calc(100%+1.25rem)]"
        style={HEADER_WASH_STYLE}
      />
      <button type="button" data-debug-id="composer-demo-header-menu-btn" aria-label="Open navigation" className={roundButton}>
        <Icon name="menu" size={22} />
      </button>
      <div data-debug-id="composer-demo-header-title" className="min-w-0 flex-1 px-1 text-center">
        <div className="truncate text-[15px] font-semibold text-primary">Reconnect loop after sleep</div>
        <div className="truncate text-xs text-muted">worker · Opus 5.5</div>
      </div>
      <Menu
        side="bottom"
        align="end"
        label="Conversation options"
        open={menuOpen}
        onOpenChange={setMenuOpen}
        trigger={
          <button type="button" data-debug-id="composer-demo-header-more-btn" aria-label="Conversation options" className={roundButton}>
            <Icon name="more-horizontal" size={22} />
          </button>
        }
      >
        <Menu.Item
          data-debug-id="composer-demo-theme-toggle"
          onClick={() => {
            setMenuOpen(false);
            // Not persisted: this page must not change the app's saved theme.
            applyThemeToDocument(nextAppearance === 'dark' ? DARK_THEME_ID : LIGHT_THEME_ID);
            setAppearance(nextAppearance);
          }}
        >
          <Icon name="sparkle" size={16} />
          <span>Switch to {nextAppearance} theme</span>
        </Menu.Item>
        <Menu.Item data-debug-id="composer-demo-status-toggle" onClick={() => { setMenuOpen(false); onToggleStatus(); }}>
          <Icon name={running ? 'stop' : 'play'} size={16} />
          <span>{running ? 'Stop agent (demo)' : 'Start agent (demo)'}</span>
        </Menu.Item>
      </Menu>
    </header>
  );
}

/**
 * `?kbd=1`: live viewport readout for measuring the software keyboard on a real device
 * (REQ-KBD-1 style). Shows the numbers `appViewportHeight.ts` reads and the composer card's
 * position, so a screenshot with the keyboard up says which box ends where.
 */
function KeyboardReadout() {
  const [text, setText] = useState('');
  useEffect(() => {
    const read = () => {
      const vv = window.visualViewport;
      const card = document.querySelector('[data-debug-id="composer-demo-composer-card"]')?.getBoundingClientRect();
      const root = document.getElementById('root')?.getBoundingClientRect();
      const css = getComputedStyle(document.documentElement);
      const r = (n: number | undefined) => (n === undefined ? '-' : Math.round(n));
      setText(
        [
          `inner ${window.innerHeight} scrollY ${r(window.scrollY)}`,
          `vv h ${r(vv?.height)} top ${r(vv?.offsetTop)} pageTop ${r(vv?.pageTop)} s ${vv?.scale?.toFixed(2) ?? '-'}`,
          `var h ${css.getPropertyValue('--app-viewport-height').trim()} off ${css.getPropertyValue('--app-viewport-bottom-offset').trim()}`,
          `root ${r(root?.top)}..${r(root?.bottom)} card ${r(card?.top)}..${r(card?.bottom)}`,
          `shell ${PRESETS.get('shell') ?? 'flow'} focus ${document.activeElement?.tagName ?? '-'}`,
        ].join('\n'),
      );
    };
    read();
    const id = window.setInterval(read, 200);
    return () => window.clearInterval(id);
  }, []);
  return (
    <pre
      data-debug-id="composer-demo-kbd-readout"
      className="pointer-events-none fixed left-2 top-20 z-50 m-0 rounded-md bg-black/80 p-2 font-mono text-[11px] leading-4 text-white"
    >
      {text}
    </pre>
  );
}

function ComposerDemo() {
  const [messages, setMessages] = useState<ChatMessage[]>(SAMPLE_MESSAGES);
  const [draft, setDraft] = useState(() => PRESETS.get('draft') ?? '');
  const [agentIsWorking, setAgentIsWorking] = useState(false);
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const composerDockRef = useRef<HTMLDivElement | null>(null);
  const [composerDockHeight, setComposerDockHeight] = useState(0);
  const replyTimerRef = useRef(0);
  const [runtimeStatus, setRuntimeStatus] = useState<DemoRuntimeStatus>(() =>
    PRESETS.get('status') === 'stopped' ? 'stopped' : 'running',
  );
  const [toast, setToast] = useState('');
  const toastTimerRef = useRef(0);

  const showStubToast = useCallback((text: string) => {
    setToast(text);
    window.clearTimeout(toastTimerRef.current);
    toastTimerRef.current = window.setTimeout(() => setToast(''), 1800);
  }, []);
  const toggleRuntimeStatus = useCallback(
    () => setRuntimeStatus((prev) => (prev === 'running' ? 'stopped' : 'running')),
    [],
  );
  const running = runtimeStatus === 'running';
  const statusLabel = running ? 'Running' : 'Stopped';

  // Same measurement as AgentChatPane (REQ-FROST-1): the dock's height is the list's inset.
  useEffect(() => {
    const el = composerDockRef.current;
    if (!el || typeof ResizeObserver === 'undefined') return;
    const measure = () => setComposerDockHeight(Math.ceil(el.getBoundingClientRect().height));
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(el);
    return () => observer.disconnect();
  }, []);

  useEffect(
    () => () => {
      window.clearTimeout(replyTimerRef.current);
      window.clearTimeout(toastTimerRef.current);
    },
    [],
  );

  useEffect(() => {
    if (PRESETS.get('scroll') !== 'top') return;
    // After ChatMessageList's initial bottom scroll; its onScroll then shows the jump button.
    const frame = requestAnimationFrame(() => {
      document.querySelector('[data-debug-id="composer-demo-scroll"]')?.scrollTo({ top: 0 });
    });
    return () => cancelAnimationFrame(frame);
  }, []);

  const send = useCallback((body: string) => {
    const text = body.trim();
    if (!text) return;
    setMessages((prev) => [...prev, message(prev.length, true, text)]);
    setDraft('');
    setAgentIsWorking(true);
    window.clearTimeout(replyTimerRef.current);
    replyTimerRef.current = window.setTimeout(() => {
      setAgentIsWorking(false);
      setMessages((prev) => [...prev, message(prev.length, false, AGENT_REPLY)]);
    }, 900);
  }, []);

  const submit = (event: FormEvent) => {
    event.preventDefault();
    send(draft);
    textareaRef.current?.focus();
  };

  const composerActions = useMemo(
    () => ({
      debugPrefix: 'composer-demo',
      // The non-mobile toolbar is the variant that shows upload and the model switcher
      // directly; the mobile variant folds both into a "…" menu.
      mobile: false,
      // Empty on purpose: ProviderIcon fetches /api/v1/providers/<id>/icon for a named
      // provider, and this page must issue no API requests. It shows its fallback glyph.
      provider: '',
      model: 'Opus 5.5 Medium',
      onSettings: () => undefined,
      onUpload: () => undefined,
      // Terminal button (MessageComposer renders it from onPaneToggle). In the app,
      // AgentChatPane passes `handleOpenPtyTab`, i.e. openAux({ type: 'agentPty', agentInstanceId }).
      onPaneToggle: () => showStubToast('Would open Terminal tab'),
      extraActions: (
        // Tasks button. In the app this maps to AgentChatPane's `openAux({ type: 'tasks' })`
        // -> `onOpenAuxTab` -> `Workspace.openAuxFromPane`, which opens the chain's Tasks
        // aux tab (`TASKS_TAB_ID`); `workspace.toggle-aux-tasks` is the toggling variant.
        // Icon name matches AUX_TAB_ICONS.tasks, the glyph the aux tab strip uses.
        <button
          type="button"
          data-debug-id="composer-demo-tasks-btn"
          aria-label="Open tasks"
          onClick={() => showStubToast('Would open Tasks tab')}
          className="grid h-9 w-9 place-items-center rounded-xl text-muted hover:bg-neutral-soft"
        >
          <Icon name="tasks" size={18} />
        </button>
      ),
    }),
    [showStubToast],
  );

  return (
    <div
      data-debug-id="composer-demo-root"
      className={
        // `?shell=fixed` mirrors AppShell's mobile shell (`fixed inset-x-0 top-0 app-viewport-height`)
        // so the keyboard behaviour of the real app can be compared with the in-flow default.
        PRESETS.get('shell') === 'fixed'
          ? 'fixed inset-x-0 top-0 app-viewport-height flex w-full max-w-full justify-center overflow-hidden bg-canvas text-primary'
          : 'flex h-full w-full justify-center bg-canvas text-primary'
      }
    >
      {PRESETS.get('kbd') === '1' ? <KeyboardReadout /> : null}
      {/* Phone-width column so the demo reads the same on a desktop preview. */}
      <div className="flex h-full w-full max-w-[440px] flex-col sm:border-x sm:border-subtle">
        <div
          data-debug-id="composer-demo-transcript"
          className="relative flex w-full min-h-0 min-w-0 max-w-full flex-1 flex-col overflow-x-hidden p-0"
        >
          <DemoHeader status={runtimeStatus} onToggleStatus={toggleRuntimeStatus} />
          {toast ? (
            <div
              role="status"
              data-debug-id="composer-demo-toast"
              className="ui-liquid-glass pointer-events-none absolute left-1/2 top-[calc(max(env(safe-area-inset-top),0.75rem)+3.75rem)] z-40 -translate-x-1/2 whitespace-nowrap rounded-full px-4 py-2 text-sm text-primary"
            >
              {toast}
            </div>
          ) : null}
          <ChatMessageList
            conversationKey="composer-demo"
            messages={messages}
            debugPrefix="composer-demo"
            formatTimestamp={formatTimestamp}
            agentIsWorking={agentIsWorking}
            onReply={send}
            bottomInset={composerDockHeight}
            wrapperClassName="relative min-h-0 min-w-0 max-w-full flex-1 overflow-hidden overflow-x-hidden"
            scrollClassName="chat-scrollbar h-full min-h-0 max-w-full space-y-3 overflow-y-auto overflow-x-hidden rounded-none bg-canvas px-1 py-3 pt-16"
          />
          {/* Mirrors the mobile dock in AgentChatPane (REQ-FROST-1/2). */}
          <div
            ref={composerDockRef}
            data-debug-id="composer-demo-composer-dock"
            data-floating="true"
            className="ui-float-dock absolute inset-x-0 bottom-0 z-20 mx-auto w-full max-w-4xl"
          >
            <div aria-hidden="true" className="ui-frost-tail" />
            <form
              onSubmit={submit}
              data-debug-id="composer-demo-composer-shell"
              className="w-full max-w-4xl mx-auto px-3 pt-2 ui-float-dock-pad"
            >
              <div className="mx-auto w-full max-w-4xl">
                <div
                  data-debug-id="composer-demo-composer-card"
                  className="ui-frost-card relative isolate rounded-[26px] border px-3 py-2.5 focus-within:border-accent"
                >
                  <div data-debug-id="composer-demo-composer-frost" aria-hidden="true" className="ui-frost-gradient -z-10">
                    <span />
                    <span />
                    <span />
                  </div>
                  {/* Two rows like the reference: the input on top with the runtime status at
                      the top right, the REAL toolbar below (+ upload, terminal, tasks, model
                      switcher, send). */}
                  <div className="flex items-start gap-2 pl-1 pt-1">
                    <div className="min-w-0 flex-1">
                    <MessageComposerInput
                      mobile
                      debugId="composer-demo-composer-input"
                      ref={textareaRef}
                      value={draft}
                      onChange={(e) => setDraft(e.target.value)}
                      onKeyDown={(e) => {
                        if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
                          e.preventDefault();
                          send(draft);
                        }
                      }}
                      // The app's mobile placeholder (AgentChatPane renderComposer).
                      placeholder="Message the agent…"
                    />
                    </div>
                    {/* Real StatusDot with the canonical runtime tone, as in AgentChatPane's top
                        bar. Dot only, no text or spinner (user feedback). Tap toggles (demo). */}
                    <button
                      type="button"
                      data-debug-id="composer-demo-runtime-status-btn"
                      data-status={runtimeStatus}
                      aria-label={running ? 'Agent running, tap to stop (demo)' : 'Agent stopped, tap to start (demo)'}
                      title={statusLabel}
                      onClick={toggleRuntimeStatus}
                      className="-mr-1.5 -mt-1.5 grid h-9 w-9 shrink-0 place-items-center rounded-full hover:bg-neutral-soft"
                    >
                      <StatusDot
                        size="sm"
                        tone={runtimeStatusToTone(runtimeStatus)}
                        label={statusLabel}
                        data-debug-id="composer-demo-status-dot"
                      />
                    </button>
                  </div>
                  <MessageComposerActions {...composerActions} sendDisabled={!draft.trim()} />
                </div>
              </div>
            </form>
          </div>
        </div>
      </div>
    </div>
  );
}

const presetTheme = PRESETS.get('theme');
if (presetTheme === 'light' || presetTheme === 'dark') {
  applyThemeToDocument(presetTheme === 'dark' ? DARK_THEME_ID : LIGHT_THEME_ID);
}

installAppViewportHeightSync(window as never);

ReactDOM.createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <Provider store={demoStore}>
      <ComposerDemo />
    </Provider>
  </StrictMode>,
);
