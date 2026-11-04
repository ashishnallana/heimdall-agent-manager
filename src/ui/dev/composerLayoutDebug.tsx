/**
 * DEV-ONLY layout debug mode for the composer demo (user QA round 4): `?debug=layout`.
 * ---------------------------------------------------------------------------
 * Shows every element that contributes to the transcript's height or scroll range, so the
 * reviewer can see where the sent bubble starts its travel and why:
 * - each element gets a translucent background (scoped CSS under `[data-debug-layout]`)
 *   and, in a fixed overlay that never takes layout space, a 1px outline, a green ring over
 *   its padding, an orange ring over its margin, and a label with its live height;
 * - crosshairs at the captured composer-text origin, the computed start, the start measured
 *   on the first painted frame, and the final resting point, plus a line at pinOffset;
 * - a HUD with live scroll metrics and controls for slow motion (`?slow=10` starts at 0.1x),
 *   pause, frame step and resend;
 * - each send's measurements are logged to the console (`[pin-debug]`), with the bubble's
 *   rect and scrollTop on every frame of the first 100ms of the travel;
 * - the HUD lists the last programmatic scrollTop writes, spacer and inset changes, gesture
 *   starts and older-page loads (ChatMessageList's `onLog`), so a write mid-gesture shows.
 * Remove this file, its import in composerDemo.tsx and ChatMessageList's `pinDebug` prop
 * before the PR.
 */
import { useCallback, useEffect, useMemo, useRef, useState, type CSSProperties, type ReactElement } from 'react';
import type { PinDebugEvent, PinDebugHooks, PinDebugLog, PinDebugPoint } from '../components/chat/ChatMessageList';

const PREFIX = 'composer-demo';

// [debug-id selector, label, background colour]. Order is paint order in the overlay.
const TARGETS: Array<[string, string, string]> = [
  ['transcript', 'transcript', 'rgba(120,120,120,0.10)'],
  ['scroll-wrapper', 'scroll wrapper', 'rgba(0,160,255,0.06)'],
  ['scroll', 'scroller', 'rgba(0,120,255,0.10)'],
  ['messages-container', 'content', 'rgba(160,0,255,0.08)'],
  ['pin-activity-slot', 'activity slot', 'rgba(255,200,0,0.30)'],
  ['working-indicator', 'working', 'rgba(255,150,0,0.30)'],
  ['pin-turn-spacer', 'TURN SPACER', 'rgba(255,0,80,0.22)'],
  ['bottom-inset', 'BOTTOM INSET', 'rgba(0,200,120,0.25)'],
  ['bottom-anchor', 'bottom anchor', 'rgba(255,0,0,0.9)'],
  ['pin-tail-blur', 'tail blur', 'rgba(255,255,0,0.18)'],
  ['header', 'header', 'rgba(0,220,220,0.22)'],
  ['composer-dock', 'composer dock', 'rgba(255,120,0,0.16)'],
  ['composer-shell', 'composer form', 'rgba(255,60,160,0.14)'],
];
const USER_ROW = 'rgba(0,140,255,0.22)';
const AGENT_ROW = 'rgba(0,200,80,0.16)';

function slowFromUrl(): number {
  const value = Number(new URLSearchParams(window.location.search).get('slow') ?? '');
  return Number.isFinite(value) && value > 1 ? 1 / value : 1;
}

export function layoutDebugEnabled(): boolean {
  return new URLSearchParams(window.location.search).get('debug') === 'layout';
}

const CSS = `
[data-debug-layout] [data-debug-id="${PREFIX}-scroll"] > [data-debug-id="${PREFIX}-messages-container"] > [data-debug-id^="${PREFIX}-message-"] { background: ${AGENT_ROW} !important; }
[data-debug-layout] [data-debug-id="${PREFIX}-scroll"] > [data-debug-id="${PREFIX}-messages-container"] > [data-debug-id^="${PREFIX}-message-"].justify-end { background: ${USER_ROW} !important; }
${TARGETS.map(([id, , bg]) => `[data-debug-layout] [data-debug-id="${PREFIX}-${id}"] { background-color: ${bg} !important; }`).join('\n')}
[data-debug-layout] [data-debug-id="${PREFIX}-pin-tail-blur"] { opacity: 1 !important; }
.pin-dbg-layer { position: fixed; inset: 0; pointer-events: none; z-index: 9990; }
.pin-dbg-clip { position: fixed; overflow: hidden; pointer-events: none; }
.pin-dbg-box { position: absolute; box-sizing: border-box; outline: 1px solid var(--c); }
.pin-dbg-ring { position: absolute; box-sizing: border-box; border-style: solid; }
.pin-dbg-label { position: absolute; font: 9px/1.2 ui-monospace, monospace; color: #fff; background: var(--c); padding: 0 3px; white-space: nowrap; border-radius: 2px; opacity: 0.92; }
.pin-dbg-cross { position: fixed; width: 0; height: 0; pointer-events: none; z-index: 9995; }
.pin-dbg-cross::before, .pin-dbg-cross::after { content: ''; position: absolute; background: var(--c); }
.pin-dbg-cross::before { left: -14px; top: -1px; width: 28px; height: 2px; }
.pin-dbg-cross::after { left: -1px; top: -14px; width: 2px; height: 28px; }
.pin-dbg-cross > span { position: absolute; left: 6px; top: 4px; font: 9px/1.2 ui-monospace, monospace; color: #fff; background: var(--c); padding: 0 3px; white-space: nowrap; }
.pin-dbg-line { position: fixed; height: 0; border-top: 2px dashed #ff0050; pointer-events: none; z-index: 9995; }
.pin-dbg-line > span { position: absolute; right: 0; top: -12px; font: 9px/1.2 ui-monospace, monospace; color: #fff; background: #ff0050; padding: 0 3px; }
.pin-dbg-hud { position: fixed; top: 4px; right: 4px; z-index: 9999; max-width: min(340px, calc(100vw - 8px)); max-height: calc(100vh - 8px); overflow: auto;
  font: 10px/1.35 ui-monospace, monospace; color: #e8e8e8; background: rgba(0,0,0,0.82); border-radius: 6px; padding: 6px 8px; white-space: pre-wrap; word-break: break-all; }
.pin-dbg-hud button { font: inherit; color: #fff; background: #333; border: 1px solid #666; border-radius: 4px; padding: 1px 6px; margin: 0 3px 4px 0; pointer-events: auto; }
.pin-dbg-hud button[aria-pressed="true"] { background: #b0005a; }
`;

type Box = { key: string; label: string; color: string; clip: boolean; rect: DOMRect; margin: number[]; padding: number[]; border: number[] };

function sides(style: CSSStyleDeclaration, prop: 'margin' | 'padding' | 'border'): number[] {
  const names = prop === 'border'
    ? ['borderTopWidth', 'borderRightWidth', 'borderBottomWidth', 'borderLeftWidth'] as const
    : (['Top', 'Right', 'Bottom', 'Left'] as const).map((side) => `${prop}${side}` as 'marginTop');
  return names.map((name) => Math.max(0, parseFloat(style[name as 'marginTop']) || 0));
}

function solidColor(bg: string): string {
  return bg.replace(/rgba\(([^,]+),([^,]+),([^,]+),[^)]+\)/, 'rgb($1,$2,$3)');
}

function collect(): Box[] {
  const boxes: Box[] = [];
  const scroll = document.querySelector<HTMLElement>(`[data-debug-id="${PREFIX}-scroll"]`);
  const push = (el: Element, key: string, label: string, bg: string, clip: boolean) => {
    const style = getComputedStyle(el);
    if (style.display === 'none') return;
    boxes.push({ key, label, color: solidColor(bg), clip, rect: el.getBoundingClientRect(),
      margin: sides(style, 'margin'), padding: sides(style, 'padding'), border: sides(style, 'border') });
  };
  for (const [id, label, bg] of TARGETS) {
    const el = id === 'scroll-wrapper' ? scroll?.parentElement : document.querySelector(`[data-debug-id="${PREFIX}-${id}"]`);
    if (el) push(el, id, label, bg, Boolean(scroll && id !== 'scroll' && id !== 'scroll-wrapper' && id !== 'transcript' && id !== 'header' && !id.startsWith('composer') && id !== 'pin-tail-blur' && scroll.contains(el)));
  }
  const content = scroll?.querySelector(`[data-debug-id="${PREFIX}-messages-container"]`);
  const view = scroll?.getBoundingClientRect();
  content?.querySelectorAll<HTMLElement>(`:scope > [data-debug-id^="${PREFIX}-message-"]`).forEach((row) => {
    const rect = row.getBoundingClientRect();
    if (view && (rect.bottom < view.top - 40 || rect.top > view.bottom + 40)) return;
    const user = row.classList.contains('justify-end');
    const index = row.dataset.chatPinIndex ?? '?';
    const pinned = row.dataset.chatPinRow === 'true' ? ' PINNED' : '';
    push(row, `row-${index}`, `${user ? 'user' : 'agent'} row #${index}${pinned}`, user ? USER_ROW : AGENT_ROW, true);
    const body = row.querySelector('[data-chat-body]');
    if (body && user) push(body, `body-${index}`, `bubble #${index}`, 'rgba(0,80,255,0.5)', true);
  });
  return boxes;
}

function BoxView({ box }: { box: Box }) {
  const { rect, margin, padding, border, color } = box;
  const style = { ['--c' as string]: color } as CSSProperties;
  return (
    <>
      <div className="pin-dbg-ring" style={{
        left: rect.left - margin[3], top: rect.top - margin[0], width: rect.width + margin[1] + margin[3], height: rect.height + margin[0] + margin[2],
        borderWidth: `${margin[0]}px ${margin[1]}px ${margin[2]}px ${margin[3]}px`, borderColor: 'rgba(255,140,0,0.45)',
      }} />
      <div className="pin-dbg-ring" style={{
        left: rect.left + border[3], top: rect.top + border[0], width: rect.width - border[1] - border[3], height: rect.height - border[0] - border[2],
        borderWidth: `${padding[0]}px ${padding[1]}px ${padding[2]}px ${padding[3]}px`, borderColor: 'rgba(0,200,90,0.35)',
      }} />
      <div className="pin-dbg-box" style={{ ...style, left: rect.left, top: rect.top, width: rect.width, height: rect.height }} />
      <div className="pin-dbg-label" style={{ ...style, left: rect.left + 1, top: rect.top + 1 }}>
        {box.label} h{Math.round(rect.height)}{padding.some(Boolean) ? ` p${padding.map(Math.round).join('/')}` : ''}{margin.some(Boolean) ? ` m${margin.map(Math.round).join('/')}` : ''}
      </div>
    </>
  );
}

function Cross({ point, color, label, row }: { point: PinDebugPoint | null; color: string; label: string; row: number }) {
  if (!point) return null;
  return (
    <div className="pin-dbg-cross" style={{ left: point.x, top: point.y, ['--c' as string]: color } as CSSProperties}>
      <span style={{ top: 4 + row * 12 }}>{label} {Math.round(point.x)},{Math.round(point.y)}</span>
    </div>
  );
}

const fmt = (p: PinDebugPoint | null | undefined) => (p ? `${Math.round(p.x)},${Math.round(p.y)}` : '-');

function measureBubble(): PinDebugPoint | null {
  const body = document.querySelector<HTMLElement>(`[data-debug-id="${PREFIX}-scroll"] [data-chat-pin-row="true"] [data-chat-body]`);
  if (!body) return null;
  const rect = body.getBoundingClientRect();
  const style = getComputedStyle(body);
  return { x: rect.left + (parseFloat(style.borderLeftWidth) || 0) + (parseFloat(style.paddingLeft) || 0),
    y: rect.top + (parseFloat(style.borderTopWidth) || 0) + (parseFloat(style.paddingTop) || 0) };
}

/**
 * Returns the `pinDebug` hooks for ChatMessageList and renders the overlay + HUD.
 * `onResend` sends a fixed test message so a travel can be replayed with one tap.
 */
export function useLayoutDebug(enabled: boolean, onResend: (text: string) => void): { hooks: PinDebugHooks | undefined; overlay: ReactElement | null } {
  const [rate, setRate] = useState(slowFromUrl);
  const [last, setLast] = useState<PinDebugEvent | null>(null);
  const [measuredStart, setMeasuredStart] = useState<PinDebugPoint | null>(null);
  const [measuredFinal, setMeasuredFinal] = useState<PinDebugPoint | null>(null);
  const [travel, setTravel] = useState(false);
  const [paused, setPaused] = useState(false);
  const [hudOpen, setHudOpen] = useState(true);
  const [logs, setLogs] = useState<PinDebugLog[]>([]);
  const animationsRef = useRef<Animation[]>([]);
  const rateRef = useRef(rate);
  rateRef.current = rate;

  const onEvent = useCallback((event: PinDebugEvent) => {
    const { animations, ...plain } = event;
    if (event.phase === 'start') {
      animationsRef.current = animations;
      setTravel(animations.length > 0);
      setPaused(false);
      setLast(event);
      setMeasuredFinal(null);
      // The position actually painted at t≈0 (the transforms are live on the next frame).
      const atEvent = measureBubble();
      // QA round 5: per-frame bubble position and scrollTop over the first 100ms, at any rate.
      const t0 = performance.now();
      const scroller = document.querySelector<HTMLElement>(`[data-debug-id="${PREFIX}-scroll"]`);
      const frames: Array<{ t: number; bubble: string; scrollTop: number }> = [{ t: 0, bubble: fmt(atEvent), scrollTop: scroller?.scrollTop ?? -1 }];
      const sample = () => {
        const t = Math.round(performance.now() - t0);
        frames.push({ t, bubble: fmt(measureBubble()), scrollTop: Math.round(scroller?.scrollTop ?? -1) });
        if (t < 100) requestAnimationFrame(sample);
        else { console.log('[pin-debug] per-frame (first 100ms):'); console.table(frames); }
      };
      requestAnimationFrame(sample);
      requestAnimationFrame(() => {
        const painted = measureBubble();
        setMeasuredStart(painted);
        console.log('[pin-debug] first frame: bubble text at', fmt(painted), '(at event time', fmt(atEvent) + ')',
          'content transform', getComputedStyle(document.querySelector(`[data-debug-id="${PREFIX}-messages-container"]`)!).transform);
      });
      console.groupCollapsed(`[pin-debug] send start: origin ${fmt(event.origin)} → computed start ${fmt(event.computedStart)} → final ${fmt(event.final)}`);
      console.table(plain);
      console.log('scrollTop before → after sync set:', event.scrollBefore, '→', event.scrollAfter,
        '| history translate', event.history, '| row translate', event.rowX, event.rowY, '| rate', rateRef.current);
      console.groupEnd();
    } else {
      animationsRef.current = [];
      setTravel(false);
      setPaused(false);
      const settled = measureBubble();
      setMeasuredFinal(settled);
      console.log('[pin-debug] settle: bubble text at', fmt(settled), 'expected', fmt(event.final), 'scrollTop', event.scrollAfter);
    }
  }, []);

  const onLog = useCallback((entry: PinDebugLog) => {
    console.log(`[pin-debug] ${entry.at.toFixed(0)}ms ${entry.kind}: ${entry.detail}`);
    setLogs((prev) => [...prev.slice(-7), entry]);
  }, []);

  const hooks = useMemo<PinDebugHooks | undefined>(() => (enabled ? { playbackRate: rate, onEvent, onLog } : undefined), [enabled, rate, onEvent, onLog]);

  useEffect(() => {
    if (!enabled) return;
    const root = document.documentElement;
    root.dataset.debugLayout = 'true';
    const style = document.createElement('style');
    style.dataset.pinDebug = '';
    style.textContent = CSS;
    document.head.appendChild(style);
    return () => { delete root.dataset.debugLayout; style.remove(); };
  }, [enabled]);

  const [, setTick] = useState(0);
  useEffect(() => {
    if (!enabled) return;
    let frame = 0;
    const loop = () => { setTick((n) => (n + 1) % 1e6); frame = requestAnimationFrame(loop); };
    frame = requestAnimationFrame(loop);
    return () => cancelAnimationFrame(frame);
  }, [enabled]);

  if (!enabled) return { hooks: undefined, overlay: null };

  const scroll = document.querySelector<HTMLElement>(`[data-debug-id="${PREFIX}-scroll"]`);
  const view = scroll?.getBoundingClientRect();
  const boxes = collect();
  const pinOffset = parseFloat(scroll?.style.getPropertyValue('--chat-pin-offset') ?? '') || 0;
  const spacer = document.querySelector<HTMLElement>(`[data-debug-id="${PREFIX}-pin-turn-spacer"]`)?.offsetHeight ?? 0;
  const inset = document.querySelector<HTMLElement>(`[data-debug-id="${PREFIX}-bottom-inset"]`)?.offsetHeight ?? 0;
  const vv = window.visualViewport;
  const main = animationsRef.current[0];
  const progress = main && typeof main.currentTime === 'number' && last ? Math.min(1, main.currentTime / last.duration) : travel ? 0 : 1;
  const live = measureBubble();

  const setAllRate = (next: number) => {
    setRate(next);
    animationsRef.current.forEach((a) => { a.playbackRate = next; });
  };
  const togglePause = () => {
    const anims = animationsRef.current;
    if (!anims.length) return;
    if (paused) anims.forEach((a) => a.play()); else anims.forEach((a) => a.pause());
    setPaused(!paused);
  };
  const step = (ms: number) => {
    const anims = animationsRef.current;
    if (!anims.length) return;
    anims.forEach((a) => { a.pause(); a.currentTime = Math.max(0, Number(a.currentTime ?? 0) + ms); });
    setPaused(true);
  };

  const hud = [
    `scrollTop     ${scroll ? scroll.scrollTop.toFixed(1) : '-'}`,
    `scrollHeight  ${scroll?.scrollHeight ?? '-'}`,
    `clientHeight  ${scroll?.clientHeight ?? '-'}`,
    `max scrollTop ${scroll ? scroll.scrollHeight - scroll.clientHeight : '-'}`,
    `pinOffset     ${pinOffset}`,
    `turn spacer   ${spacer}`,
    `bottom inset  ${inset}`,
    `visualVP      h${vv ? Math.round(vv.height) : '-'} top${vv ? Math.round(vv.offsetTop) : '-'}  win h${window.innerHeight}`,
    `travel        ${travel ? 'ON' : 'off'}${paused ? ' (paused)' : ''}  rate ${rate}x`,
    `progress      ${(progress * 100).toFixed(0)}%  t=${main?.currentTime != null ? Math.round(Number(main.currentTime)) : '-'}/${last?.duration ?? '-'}ms`,
    `── last send ──`,
    `origin        ${fmt(last?.origin)}${last && !last.origin ? ' (NO ORIGIN, fallback)' : ''}`,
    `computed start ${fmt(last?.computedStart)}`,
    `painted start ${fmt(measuredStart)}`,
    `final (calc)  ${fmt(last?.final)}`,
    `final (meas)  ${fmt(measuredFinal)}`,
    `bubble now    ${fmt(live)}`,
    `scroll b→a    ${last ? `${last.scrollBefore} → ${last.scrollAfter}` : '-'}`,
    `history Δ     ${last?.history ?? '-'}   row Δ ${last ? `${Math.round(last.rowX)},${Math.round(last.rowY)}` : '-'}`,
    `tail          ${last?.tail ?? '-'}   scroller top ${view ? Math.round(view.top) : '-'}`,
    `── layout/scroll log ──`,
    ...(logs.length ? logs.map((l) => `${(l.at / 1000).toFixed(2)}s ${l.kind} ${l.detail}`) : ['(none yet)']),
  ].join('\n');

  const overlay = (
    <>
      <div className="pin-dbg-layer" data-debug-id="composer-demo-layout-debug-overlay" aria-hidden="true">
        {boxes.filter((b) => !b.clip).map((b) => <BoxView key={b.key} box={b} />)}
      </div>
      {view ? (
        <div className="pin-dbg-clip" aria-hidden="true" style={{ left: 0, top: view.top, width: '100vw', height: view.height }}>
          <div style={{ position: 'absolute', left: 0, top: -view.top }}>
            {boxes.filter((b) => b.clip).map((b) => <BoxView key={b.key} box={b} />)}
          </div>
        </div>
      ) : null}
      {view && pinOffset ? (
        <div className="pin-dbg-line" aria-hidden="true" style={{ left: view.left, width: view.width, top: view.top + pinOffset }}>
          <span>pinOffset {pinOffset} (bubble row top lands here)</span>
        </div>
      ) : null}
      <Cross point={last?.origin ?? null} color="#ff00d4" label="origin" row={0} />
      <Cross point={last?.computedStart ?? null} color="#ff7a00" label="calc start" row={1} />
      <Cross point={measuredStart} color="#ffd000" label="painted start" row={2} />
      <Cross point={last?.final ?? null} color="#00d26a" label="final" row={0} />
      <div className="pin-dbg-hud" data-debug-id="composer-demo-layout-debug-hud">
        <div>
          <button type="button" data-debug-id="composer-demo-layout-debug-hud-toggle-btn" aria-pressed={!hudOpen} onClick={() => setHudOpen(!hudOpen)}>{hudOpen ? 'hide' : 'hud'}</button>
          <button type="button" data-debug-id="composer-demo-layout-debug-rate-btn" aria-pressed={rate !== 1} onClick={() => setAllRate(rate === 1 ? 0.1 : 1)}>{rate === 1 ? 'slow 0.1x' : 'speed 1x'}</button>
          <button type="button" data-debug-id="composer-demo-layout-debug-pause-btn" aria-pressed={paused} onClick={togglePause}>{paused ? 'play' : 'pause'}</button>
          <button type="button" data-debug-id="composer-demo-layout-debug-step-back-btn" onClick={() => step(-16)}>-16ms</button>
          <button type="button" data-debug-id="composer-demo-layout-debug-step-btn" onClick={() => step(16)}>+16ms</button>
          <button type="button" data-debug-id="composer-demo-layout-debug-resend-btn" onClick={() => onResend('Debug send')}>resend</button>
        </div>
        {hudOpen ? hud : null}
      </div>
    </>
  );
  return { hooks, overlay };
}
