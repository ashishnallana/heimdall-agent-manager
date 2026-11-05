/**
 * DEV-ONLY composer demo (REQ-DEMO-1..5), served by Vite at `composer-demo.html`.
 * ---------------------------------------------------------------------------
 * Lets a reviewer judge the floating gradient-frost morphing composer in the Heimdall
 * preview, where the full app cannot run: the vault refuses non-UI origins by design.
 * Nothing here talks to the network, the vault or auth. The redux store below only
 * exists because `ChatMessageList` / `Markdown` read it with `useSelector`; it holds
 * only the vault slice (no API slice, no chat slice), so no request can be issued
 * from this page.
 *
 * What is real and what is stubbed:
 * - REAL: `ChatMessageList` (bottom inset, auto-scroll, jump-to-latest), the morphing
 *   composer from MessageComposer.tsx (`useComposerExpanded`, `MessageComposerMorphShell`,
 *   `MessageComposerInput morph`, `MessageComposerActions morph`, `useComposerDockInset`,
 *   `MessageComposerStatus`), `Icon`, `Menu`, and the `ui-float-dock` / `ui-frost-*` /
 *   `ui-liquid-glass` classes from styles.css.
 * - MIRRORED: the dock, context row (bridge · project, runtime status menu) and attachment
 *   tray markup from `AgentChatPane.renderComposer` (AgentChatPane itself needs the API and
 *   vault). Keep the two in sync when the composer markup changes.
 * - MIRRORED: the floating header (menu, title/subtitle, "…") from the reference
 *   screenshots.
 * - STUBBED: composer callbacks; "sending" appends locally and fakes an agent reply;
 *   the runtime status is local state (its menu in the composer's context row starts or
 *   stops it); upload adds a fake local attachment (no file chooser, no upload); the
 *   terminal, tasks and model buttons only show a toast (see `ComposerDemo`).
 *
 * URL presets, so a state can be linked or screenshotted without interaction:
 *   ?theme=light|dark   start in that appearance
 *   ?draft=<text>       prefill the composer (use %0A for extra lines)
 *   ?scroll=top         start scrolled to the top, which shows jump-to-latest
 *   ?status=running|stopped  runtime indicator state (default running)
 *   ?state=empty|focused|draft|menu|attachments  composer open condition to start in:
 *                       collapsed pill, focused field, a draft, the owned runtime status
 *                       menu open, or two queued attachments (default empty)
 *   ?layout=phone|desktop  phone column (default) or a desktop-width conversation
 * A sent message containing "long" gets a reply taller than the viewport.
 * The header "…" menu applies the same presets in place (`composer-demo-preset-*`).
 *
 * Not shipped: vite.config.js has no `rollupOptions.input`, so `vite build` emits only
 * index.html (REQ-DEMO-5).
 */
import { StrictMode, useCallback, useEffect, useMemo, useRef, useState, type FormEvent } from 'react';
import ReactDOM from 'react-dom/client';
import { Provider } from 'react-redux';
import { combineReducers, configureStore } from '@reduxjs/toolkit';
import { Icon, Menu, runtimeStatusToTone } from '@ui';
import ChatMessageList from '../components/chat/ChatMessageList';
import {
  MessageComposerActions,
  MessageComposerInput,
  MessageComposerMorphShell,
  MessageComposerStatus,
  useComposerDockInset,
  useComposerExpanded,
} from '../components/chat/MessageComposer';
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

// The incoming-reply demo: a long reply with a heading, bullets, a code block and a table,
// revealed word by word once it arrives.
const AGENT_REPLY = `Done. Here's what I found while checking the **send animation** (demo reply, nothing was sent).

### What changed
- The pinned bubble stays put while the reply grows below it, so there's no single-frame jump and nothing above moves.
- Each new chunk fades in where it lands, leaving a soft gradient on the newest words.
- Bullets, headings, code blocks and table rows arrive with their first words.

\`\`\`ts
// Only the newly revealed tail animates.
revealer.reveal(nextLength, true);
\`\`\`

| Phase | Timing |
| --- | --- |
| Text chunk | 350ms ease-out |
| Action row | +120ms, 200ms |

Earlier text never re-animates, and \`inline code\` or **bold** never flashes raw markdown.`;

const LONG_AGENT_REPLY = Array.from({ length: 14 }, (_, i) => `${i + 1}. A long demo reply line, so the exchange outgrows the viewport and you scroll through it normally.`).join('\n\n');

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

const DEMO_COMPOSER_STATES = ['empty', 'focused', 'draft', 'menu', 'attachments'] as const;
type DemoComposerState = (typeof DEMO_COMPOSER_STATES)[number];
const DEMO_COMPOSER_STATE_LABELS: Record<DemoComposerState, string> = {
  empty: 'Empty (collapsed)',
  focused: 'Focused, empty',
  draft: 'Draft',
  menu: 'Owned menu open',
  attachments: 'Attachments queued',
};
const DEMO_DRAFT = 'Can you check why the bridge install enrolls before the service starts?';

function presetState(): DemoComposerState {
  const value = PRESETS.get('state');
  return (DEMO_COMPOSER_STATES as readonly string[]).includes(value ?? '') ? (value as DemoComposerState) : 'empty';
}

type DemoAttachment = { localId: string; name: string };
const DEMO_ATTACHMENTS: DemoAttachment[] = [
  { localId: 'demo-a1', name: 'reconnect-trace.log' },
  { localId: 'demo-a2', name: 'sleep-resume.png' },
];

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
  onPreset,
}: {
  status: DemoRuntimeStatus;
  onToggleStatus: () => void;
  onPreset: (state: DemoComposerState) => void;
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
        <Menu.Label>Composer preset</Menu.Label>
        {DEMO_COMPOSER_STATES.map((state) => (
          <Menu.Item
            key={state}
            data-debug-id={`composer-demo-preset-${state}`}
            onClick={() => { setMenuOpen(false); onPreset(state); }}
          >
            <span>{DEMO_COMPOSER_STATE_LABELS[state]}</span>
          </Menu.Item>
        ))}
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
  const initialState = presetState();
  const desktop = PRESETS.get('layout') === 'desktop';
  const [messages, setMessages] = useState<ChatMessage[]>(SAMPLE_MESSAGES);
  const [draft, setDraft] = useState(() => PRESETS.get('draft') ?? (initialState === 'draft' ? DEMO_DRAFT : ''));
  const [attachments, setAttachments] = useState<DemoAttachment[]>(() => (initialState === 'attachments' ? DEMO_ATTACHMENTS : []));
  const [statusMenuOpen, setStatusMenuOpen] = useState(initialState === 'menu');
  const [agentIsWorking, setAgentIsWorking] = useState(false);
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const composerDockRef = useRef<HTMLDivElement | null>(null);
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

  // The same dock/transcript synchronisation as AgentChatPane (REQ-FROST-1).
  const composerDockHeight = useComposerDockInset(composerDockRef, {
    insetDebugId: 'composer-demo-bottom-inset',
    jumpDebugId: 'composer-demo-jump-latest-btn',
  });

  // The same open conditions as AgentChatPane, minus the ones this page has no source for
  // (quotes, borrowed tray modes, uploads, pending reconfiguration, read-only).
  const expansion = useComposerExpanded({
    draft,
    hasAttachments: attachments.length > 0,
    menuOpen: statusMenuOpen,
  });

  const applyPreset = useCallback((state: DemoComposerState) => {
    setDraft(state === 'draft' ? DEMO_DRAFT : '');
    setAttachments(state === 'attachments' ? DEMO_ATTACHMENTS : []);
    setStatusMenuOpen(state === 'menu');
    // After the menu that picked the preset has returned focus to its trigger.
    window.setTimeout(() => {
      if (state === 'focused' || state === 'draft') textareaRef.current?.focus();
      else if (state === 'empty' || state === 'attachments') textareaRef.current?.blur();
    }, 0);
  }, []);

  useEffect(() => {
    if (initialState !== 'focused') return;
    const frame = requestAnimationFrame(() => textareaRef.current?.focus());
    return () => cancelAnimationFrame(frame);
  }, [initialState]);

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
    setAttachments([]);
    setAgentIsWorking(true);
    window.clearTimeout(replyTimerRef.current);
    // Deliver the whole reply at once, as the hub does.
    replyTimerRef.current = window.setTimeout(() => {
      setAgentIsWorking(false);
      setMessages((prev) => [...prev, message(prev.length, false, /\blong\b/i.test(text) ? LONG_AGENT_REPLY : AGENT_REPLY)]);
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
      mobile: !desktop,
      // Empty on purpose: ProviderIcon fetches /api/v1/providers/<id>/icon for a named
      // provider, and this page must issue no API requests. It shows its fallback glyph.
      provider: '',
      model: 'Opus 5.5 Medium',
      // In the app the chip opens the "Agent settings" modal (bridge, provider, model).
      onSettings: () => showStubToast('Would open Agent settings'),
      // In the app this opens the native file chooser and uploads; here it queues a fake file.
      onUpload: () =>
        setAttachments((prev) => [...prev, { localId: `demo-a${prev.length + 1}-${Date.now()}`, name: `notes-${prev.length + 1}.md` }]),
      // Terminal button. In the app, AgentChatPane passes `handleOpenPtyTab`, i.e.
      // openAux({ type: 'agentPty', agentInstanceId }).
      onPaneToggle: () => showStubToast('Would open Terminal tab'),
      // Tasks button. In the app: openAux({ type: 'tasks' }) -> the chain's Tasks aux tab.
      onOpenTasks: () => showStubToast('Would open Tickets tab'),
    }),
    [desktop, showStubToast],
  );

  return (
    <div
      data-debug-id="composer-demo-root"
      data-layout={desktop ? 'desktop' : 'phone'}
      className={
        // `?shell=fixed` mirrors AppShell's mobile shell (`fixed inset-x-0 top-0 app-viewport-height`)
        // so the keyboard behaviour of the real app can be compared with the in-flow default.
        PRESETS.get('shell') === 'fixed'
          ? 'fixed inset-x-0 top-0 app-viewport-height flex w-full max-w-full justify-center overflow-hidden bg-canvas text-primary'
          : 'flex h-full w-full justify-center bg-canvas text-primary'
      }
    >
      {PRESETS.get('kbd') === '1' ? <KeyboardReadout /> : null}
      {/* Phone-width column so the demo reads the same on a desktop preview; `?layout=desktop`
          widens it to the conversation page's max width. */}
      <div className={`flex h-full w-full flex-col sm:border-x sm:border-subtle ${desktop ? 'max-w-[calc(56rem+3.5rem)]' : 'max-w-[440px]'}`}>
        <div
          data-debug-id="composer-demo-transcript"
          className="relative flex w-full min-h-0 min-w-0 max-w-full flex-1 flex-col overflow-x-hidden p-0"
        >
          <DemoHeader status={runtimeStatus} onToggleStatus={toggleRuntimeStatus} onPreset={applyPreset} />
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
            pinOnSend
            pinOriginRef={textareaRef}
            wrapperClassName="relative min-h-0 min-w-0 max-w-full flex-1 overflow-hidden overflow-x-hidden"
            scrollClassName="chat-scrollbar h-full min-h-0 max-w-full space-y-3 overflow-y-auto overflow-x-hidden rounded-none bg-canvas px-1 py-3 pt-16"
          />
          {/* Mirrors the composer dock in AgentChatPane (REQ-FROST-1/2). */}
          <div
            ref={composerDockRef}
            data-debug-id="composer-demo-composer-dock"
            data-floating="true"
            className="ui-float-dock absolute inset-x-0 bottom-0 z-20 mx-auto w-full max-w-[calc(56rem+1.5rem)]"
          >
            <div aria-hidden="true" className="ui-frost-tail" />
            <form
              onSubmit={submit}
              data-debug-id="composer-demo-composer-shell"
              className={`mx-auto w-full max-w-[calc(56rem+1.5rem)] px-3 pt-2 ${desktop ? 'pb-4' : 'ui-float-dock-pad'}`}
            >
              <div className="mx-auto w-full max-w-4xl">
                {attachments.length > 0 ? (
                  <div
                    data-debug-id="composer-demo-attachment-tray"
                    className="mb-2 space-y-2 rounded-2xl border border-subtle bg-surface-raised p-2 text-xs text-primary"
                  >
                    {attachments.map((a) => (
                      <div
                        key={a.localId}
                        data-debug-id={`composer-demo-attachment-${a.localId}`}
                        className="flex min-w-0 items-center gap-2 rounded-xl border border-subtle bg-surface px-2.5 py-2"
                      >
                        <span className="text-success">✓</span>
                        <span className="min-w-0 flex-1 truncate" title={a.name}>{a.name}</span>
                        <span className="text-success">Uploaded</span>
                        <button
                          type="button"
                          data-debug-id={`composer-demo-attachment-remove-${a.localId}`}
                          onClick={() => setAttachments((prev) => prev.filter((item) => item.localId !== a.localId))}
                          className={`rounded-full border border-subtle text-muted hover:bg-neutral-soft hover:text-primary ${desktop ? 'px-2 py-0.5' : 'min-h-11 px-4'}`}
                        >
                          Remove
                        </button>
                      </div>
                    ))}
                  </div>
                ) : null}
                <MessageComposerMorphShell
                  expansion={expansion}
                  debugPrefix="composer-demo"
                  debugId="composer-demo-composer-card"
                  className="ui-frost-card isolate rounded-[28px] border px-5"
                  leading={
                    <div data-debug-id="composer-demo-composer-frost" aria-hidden="true" className="ui-frost-gradient -z-10">
                      <span />
                      <span />
                      <span />
                    </div>
                  }
                  context={
                    <div
                      data-debug-id="composer-demo-composer-context"
                      className="flex min-w-0 items-center gap-x-2 text-[13px] font-semibold leading-5 text-muted"
                    >
                      <div className="flex min-w-0 flex-1 items-center gap-2 overflow-hidden">
                        <button
                          type="button"
                          data-debug-id="composer-demo-composer-bridge-chip"
                          onClick={() => showStubToast('Would open Agent settings')}
                          className="inline-flex min-w-0 max-w-[50%] shrink items-center gap-1.5 rounded-md hover:text-primary"
                        >
                          <Icon name="device" size={16} className="shrink-0" />
                          <span className="min-w-0 truncate">riverwood</span>
                        </button>
                        <span aria-hidden="true" className="shrink-0 text-faint">·</span>
                        <button
                          type="button"
                          data-debug-id="composer-demo-composer-project-chip"
                          onClick={() => showStubToast('Would open project files')}
                          className="inline-flex min-w-0 max-w-[50%] shrink items-center gap-1.5 rounded-md hover:text-primary"
                        >
                          <Icon name="folder" size={16} className="shrink-0" />
                          <span className="min-w-0 truncate">heimdall-agent-manager</span>
                        </button>
                      </div>
                      {/* The app's runtime status menu (a portal the composer owns). */}
                      <div className="ml-auto flex shrink-0">
                        <Menu
                          side="top"
                          align="end"
                          label="Runtime status"
                          open={statusMenuOpen}
                          onOpenChange={setStatusMenuOpen}
                          trigger={
                            <button
                              type="button"
                              data-debug-id="composer-demo-runtime-status-btn"
                              data-status={runtimeStatus}
                              aria-label={running ? 'Agent running. Start or stop the agent' : 'Agent stopped. Start or stop the agent'}
                              title={`${statusLabel} — start/stop the agent (demo)`}
                              className={`group grid shrink-0 place-items-center rounded-full ${desktop ? '-my-2 -mr-2 h-9 w-9' : '-my-2.5 -mr-2.5 h-10 w-10'}`}
                            >
                              <span data-debug-id="composer-demo-status-dot" className="grid h-6 w-6 place-items-center rounded-full group-hover:bg-neutral-soft">
                                <MessageComposerStatus
                                  debugPrefix="composer-demo"
                                  tone={runtimeStatusToTone(runtimeStatus)}
                                  label={statusLabel}
                                />
                              </span>
                            </button>
                          }
                        >
                          <Menu.Label>Runtime: {statusLabel}</Menu.Label>
                          <Menu.Item
                            data-debug-id="composer-demo-runtime-status-toggle-btn"
                            onClick={() => { setStatusMenuOpen(false); toggleRuntimeStatus(); }}
                            className={running ? 'text-danger' : 'text-success'}
                          >
                            <Icon name={running ? 'stop' : 'play'} size={15} />
                            <span>{running ? 'Stop agent (demo)' : 'Start agent (demo)'}</span>
                          </Menu.Item>
                        </Menu>
                      </div>
                    </div>
                  }
                  actions={
                    <MessageComposerActions
                      {...composerActions}
                      sendDisabled={!draft.trim() && attachments.length === 0}
                      morph={expansion}
                    />
                  }
                >
                  <MessageComposerInput
                    mobile={!desktop}
                    morph
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
                    // The app's placeholders (AgentChatPane renderComposer).
                    placeholder={desktop ? 'Message the agent… (Cmd/Ctrl+Enter to send)' : 'Message the agent…'}
                  />
                </MessageComposerMorphShell>
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
