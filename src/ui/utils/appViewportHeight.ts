/**
 * appViewportHeight — drive the app shell's height from the VISUAL viewport.
 * ---------------------------------------------------------------------------
 * REQ-KBD-2. Root cause established on device in REQ-KBD-1 (artifact
 * `art_18db9abe5a639a40` §1): on iOS a software keyboard shrinks only the VISUAL
 * viewport. `window.innerHeight` — and therefore `100dvh`, `100lvh` and `100vh` —
 * does not move. Measured in the installed home-screen app with the keyboard up:
 *
 *     innerHeight = 812   visualViewport.height = 409   visualOffsetTop = 0
 *
 * The shell was sized `100dvh`, so its bottom edge stayed nailed at 812 while the
 * visible region collapsed to 0..409. The composer sat at 540..776 — entirely inside
 * the invisible 403px. Scrolling cannot rescue a box whose container's bottom edge is
 * pinned to a viewport the keyboard never shrinks.
 *
 * The fix is to stop sizing the shell from a viewport unit and size it from
 * `visualViewport.height` instead, published as the CSS custom property
 * `--app-viewport-height` on `<html>`. Everything that used to say `100dvh` says
 * `var(--app-viewport-height)`; the shell then ends where the keyboard begins and the
 * browser's own scroll-into-view does the rest.
 *
 * Two requirements below are NOT obvious and are both load-bearing. They come from
 * measurement, not taste. Read the comments before changing either.
 */

/** The custom property this module owns. Nothing else may write it. */
export const APP_VIEWPORT_HEIGHT_VAR = '--app-viewport-height';

/**
 * REQ-VIEWPORT-SWEEP-1: the companion property, for boxes pinned to the BOTTOM edge.
 *
 * A `position: fixed` box resolves `bottom` against the LAYOUT viewport, so `bottom: 0`
 * puts its lower edge at `innerHeight` — 812 on the REQ-KBD-1 device, while the visible
 * region ended at 409. That is the same defect as `height: 100dvh`, in a spelling none of
 * the height greps can see: there is no `vh`, no `h-screen` and no `innerHeight` in
 * `fixed inset-x-0 bottom-0`. It put the app's entire mobile tab bar, every toast viewport
 * and the mobile sticky action bars at 758..814 — not clipped, fully past the fold.
 *
 * This property is how far up from the layout viewport's bottom edge such a box must sit:
 * the occluded height. See `appViewportBottomOffsetFrom` for why it is NOT `100lvh - var()`.
 */
export const APP_VIEWPORT_BOTTOM_OFFSET_VAR = '--app-viewport-bottom-offset';

/**
 * REQ-VIEWPORT-ORIGIN-1: the companion property for the TOP edge — where the visible region
 * begins inside the layout viewport, in CSS pixels.
 *
 * Measured on device in tabbed iOS Safari with the keyboard up (morphing-composer chain,
 * probes A/B/C, all three agreeing to within 3px):
 *
 *     innerHeight = 630   visualViewport.height = 377   offsetTop = 84   scale = 1
 *
 * The shell was sized 377 (correct) but anchored at layout y 0, while iOS had panned the
 * visible region to 84..461 — despite `body { position: fixed }`. The whole app sat 84px too
 * high: the top of the transcript under the status bar, 84px of empty canvas above the
 * keyboard. The flow root and `AppShell` were displaced identically, so the defect is in the
 * shared origin, not in any one surface. Height alone cannot describe a region that does not
 * start at 0; the shell needs the region's ORIGIN as well, from the SAME sample.
 *
 * Consumers position with `top` (never `transform`): a transformed ancestor would become the
 * containing block of every `position: fixed` descendant — portalled menus, the mobile
 * sidebar, overlays — and move them twice. Fixed boxes resolve `top` against the layout
 * viewport, so each fixed box applies this once and nesting cannot compound it.
 */
export const APP_VIEWPORT_OFFSET_TOP_VAR = '--app-viewport-offset-top';

/**
 * REQUIREMENT 1 — RE-READ ON A SETTLING TICK, NOT ONLY ON EVENTS.
 *
 * `visualViewport` events on this surface fire only MID-TRANSIENT. The complete event
 * log for one keyboard raise (REQ-KBD-1 §3) is two events at `10:10:03.180/.181`, both
 * taken while the viewport was still moving; the SETTLED state then held for SIX SECONDS
 * and fired nothing at all. `window.resize` never fired once. An event-only listener
 * latches the transient and never sees the steady state — that is precisely the defect
 * that made the former `useKeyboardInset()` hook report 0 forever (deleted in REQ-KBD-3).
 *
 * So every GEOMETRY event (visualViewport resize/scroll, window resize/orientationchange —
 * never focus) schedules a ladder of re-reads after itself, AND a standing poll runs
 * regardless of whether any event ever arrives. Writes are suppressed when the value is
 * unchanged (see `installAppViewportHeightSync`), which is what makes the poll free: the
 * steady state costs two property reads and an integer compare per tick.
 */
export const APP_VIEWPORT_SETTLE_DELAYS_MS: readonly number[] = [50, 150, 300, 600, 1000];

/** Standing re-read interval. Covers keyboard transitions longer than the ladder. */
export const APP_VIEWPORT_POLL_MS = 250;

/**
 * Above this `visualViewport.scale` the user has pinch-zoomed in. `visualViewport.height`
 * then reports the zoomed-in slice, which is not a keyboard and must not shrink the shell.
 * Falling back to `innerHeight` there keeps pinch-zoom a pure magnifier.
 */
export const APP_VIEWPORT_MAX_UNZOOMED_SCALE = 1.01;

export type AppViewportReading = {
  /**
   * `window.innerHeight`. The layout viewport height on Chromium and in the REQ-KBD-1 PWA; on
   * tabbed iOS Safari with the keyboard up it reports the VISIBLE height instead (see
   * `appViewportOffsetTopFrom`), so nothing here uses it as a bound on a layout-viewport
   * coordinate.
   */
  innerHeight: number;
  /** `visualViewport.height`, or `null` where `visualViewport` is unavailable. */
  visualHeight: number | null;
  /** `visualViewport.scale`, or `null` where unavailable. Only used to detect pinch-zoom. */
  scale: number | null;
  /**
   * `visualViewport.offsetTop` — the visible region's top edge inside the LAYOUT viewport —
   * or `null` where unavailable. Only `appViewportOffsetTopFrom` (and the bottom offset, which
   * must agree with it) reads this; the HEIGHT never does. See REQUIREMENT 2.
   */
  offsetTop: number | null;
};

/**
 * The height the app shell should occupy, in CSS pixels.
 *
 * REQUIREMENT 2 — THE HEIGHT DOES NOT READ `visualViewport.offsetTop`, AND MUST NOT.
 *
 * The mechanism it replaces computed `innerHeight - visualHeight - visualOffsetTop`.
 * Across 350 focused device samples on a valid standalone surface, `visualOffsetTop`
 * ranged **-111 to +466** for one physically constant 403px keyboard, and that formula
 * produced **40 distinct values** (0, 41, 99, 105, 127, 221, …, 403, …, 456) — because
 * the visual viewport pans continuously while the keyboard is up. Any quantity derived by
 * subtracting a continuously-panning offset is non-deterministic by construction. The
 * height we want is simply "how tall is the visible region", which is `visualHeight`
 * alone. (REQ-KBD-1 §5, H5.)
 *
 * REQ-VIEWPORT-ORIGIN-1 does read `offsetTop`, but only as the region's ORIGIN
 * (`appViewportOffsetTopFrom`), never subtracted into this height. A panning origin is not
 * noise to be filtered out of a height: it is where the visible region currently is, and a
 * shell that follows it is exactly as deterministic as the pan itself.
 */
export function appViewportHeightFrom(reading: AppViewportReading): number {
  const { innerHeight, visualHeight, scale } = reading;
  const layout = Number.isFinite(innerHeight) && innerHeight > 0 ? innerHeight : 0;
  const isPinchZoomed = scale !== null && Number.isFinite(scale) && scale > APP_VIEWPORT_MAX_UNZOOMED_SCALE;
  if (visualHeight === null || !Number.isFinite(visualHeight) || visualHeight <= 0 || isPinchZoomed) {
    return Math.round(layout);
  }
  return Math.round(visualHeight);
}

/**
 * Where the visible region begins inside the layout viewport, in CSS pixels
 * (REQ-VIEWPORT-ORIGIN-1). `0` on every surface that does not pan the visual viewport,
 * which is why a box using it is unchanged on desktop. Any surface that does pan (tabbed
 * Safari; REQ-KBD-1 also saw the standalone PWA pan -111..+466) gets the pan itself.
 *
 * - `offsetTop`, not `pageTop`: every consumer is `position: fixed` (body included), and a
 *   fixed box resolves `top` against the layout viewport. `pageTop` adds the document
 *   scroll, which already moves the layout viewport — and every fixed box with it — so
 *   using it would apply that scroll twice where the layout viewport scrolls.
 * - Pinch-zoom returns `0`: the height falls back to `innerHeight` there, and zoom must
 *   stay a pure magnifier, not drag the app around under the user's fingers.
 * - Floored at `0` (rubber-band overscroll reports a negative origin), and NOT capped by
 *   `innerHeight`. iPhone device readouts (tabbed iOS Safari, keyboard up) disproved the
 *   old `[0, innerHeight - height]` cap: WebKit reports `innerHeight` as the VISIBLE height
 *   there (377, equal to `visualViewport.height`) and then lets it wander 377..544 during the
 *   reveal pan, while the region fixed boxes actually resolve against stays 714 tall
 *   (`documentElement.scrollHeight`). The cap therefore pinned the origin to 0..167 while
 *   `offsetTop` was 204..337, and the whole shell sat that far above the screen. In every
 *   sample where the cap happened not to bite (`top == offsetTop`), the shell measured exactly
 *   `0..377` on screen. `innerHeight` is not the layout viewport on that engine, so it must not
 *   bound a layout-viewport coordinate.
 */
export function appViewportOffsetTopFrom(reading: AppViewportReading): number {
  const { offsetTop, scale } = reading;
  if (offsetTop === null || !Number.isFinite(offsetTop) || offsetTop <= 0) return 0;
  // Pinch-zoom: the height falls back to `innerHeight` (see `appViewportHeightFrom`), so the
  // shell keeps its unzoomed box and the zoom stays a pure magnifier.
  if (scale !== null && Number.isFinite(scale) && scale > APP_VIEWPORT_MAX_UNZOOMED_SCALE) return 0;
  return Math.round(offsetTop);
}

/**
 * How far above the layout viewport's bottom edge the visible region ends, in CSS pixels.
 * `0` whenever nothing is occluding and nothing is panned.
 *
 * WHY THIS AND NOT `calc(100lvh - var(--app-viewport-height))`, which needs no JS at all:
 * `lvh` is the LARGE viewport, the one with browser chrome RETRACTED, and it is a STATIC
 * unit — it does not move when the keyboard opens and it does not move when chrome
 * retracts mid-session. In a standalone PWA (the surface REQ-KBD-1 measured) there is no
 * retractable chrome, so `100lvh == innerHeight` and the two agree. In TABBED Safari,
 * `100lvh > innerHeight` by the chrome height permanently, so `100lvh - visible` overstates
 * the offset and floats the bar above where it belongs. Tabbed Safari is on REQ-KBD-1's
 * NOT-MEASURED list, so the `lvh` spelling would be correct only on the surface we happened
 * to measure. Subtracting within one sample cannot diverge from the height the shell is
 * already sized by, because it is the same number minus the same number.
 *
 * This is NOT a second sampler: it takes the same `AppViewportReading` and calls
 * `appViewportHeightFrom`. That also makes pinch-zoom fall out for free — there the height
 * function returns `innerHeight`, so the offset is exactly 0 and nothing is displaced.
 *
 * REQ-VIEWPORT-ORIGIN-1: the visible region ends at `origin + height`, so the offset is
 * `innerHeight - origin - height`, floored at 0. Where `innerHeight` really is the layout
 * viewport (Chromium, the REQ-KBD-1 PWA) a bottom-pinned bar and the shell's bottom edge are
 * the same line. On tabbed iOS Safari with the keyboard up `innerHeight` is the visible height
 * (see `appViewportOffsetTopFrom`), so this reads 0 there; no chat surface depends on it (the
 * composer dock is in-flow, see `styles.css`), and it is kept only for the legacy bottom-pinned
 * bars.
 */
export function appViewportBottomOffsetFrom(reading: AppViewportReading): number {
  const { innerHeight } = reading;
  const layout = Number.isFinite(innerHeight) && innerHeight > 0 ? Math.round(innerHeight) : 0;
  return Math.max(0, layout - appViewportOffsetTopFrom(reading) - appViewportHeightFrom(reading));
}

/** The subset of `Window` this module touches, so tests can pass a fake. */
export type AppViewportWindow = {
  innerHeight: number;
  visualViewport?: {
    height: number;
    scale?: number;
    offsetTop?: number;
    addEventListener: (type: string, listener: () => void) => void;
    removeEventListener: (type: string, listener: () => void) => void;
  } | null;
  document: {
    documentElement: {
      style: { setProperty: (name: string, value: string) => void; removeProperty?: (name: string) => unknown };
    };
  };
  addEventListener: (type: string, listener: () => void, options?: unknown) => void;
  removeEventListener: (type: string, listener: () => void, options?: unknown) => void;
  setTimeout: (fn: () => void, ms: number) => unknown;
  clearTimeout: (handle: never) => void;
  setInterval: (fn: () => void, ms: number) => unknown;
  clearInterval: (handle: never) => void;
};

/** One sample of `win`. All published values derive from this, so they cannot disagree. */
export function readAppViewport(win: AppViewportWindow): AppViewportReading {
  const vv = win.visualViewport ?? null;
  return {
    innerHeight: win.innerHeight,
    visualHeight: vv ? vv.height : null,
    scale: vv && typeof vv.scale === 'number' ? vv.scale : null,
    offsetTop: vv && typeof vv.offsetTop === 'number' ? vv.offsetTop : null,
  };
}

export function readAppViewportHeight(win: AppViewportWindow): number {
  return appViewportHeightFrom(readAppViewport(win));
}

/**
 * Publish `--app-viewport-height`, `--app-viewport-bottom-offset` and
 * `--app-viewport-offset-top` on `<html>` and keep them current. Returns a teardown.
 *
 * Safe to call before React mounts — it only writes an inline custom property, which the
 * `:root { --app-viewport-height: 100dvh }` fallback in `styles.css` covers until the
 * first write lands.
 */
export function installAppViewportHeightSync(win: AppViewportWindow): () => void {
  const vv = win.visualViewport ?? null;
  const timers = new Set<unknown>();
  let lastHeight = -1;
  let lastOffset = -1;
  let lastTop = -1;
  let stopped = false;

  const apply = () => {
    if (stopped) return;
    // ONE sample for all three properties. Reading twice could straddle a keyboard transition
    // and publish a height and an offset that do not describe the same viewport.
    const reading = readAppViewport(win);
    const height = appViewportHeightFrom(reading);
    if (height <= 0) return;
    const offset = appViewportBottomOffsetFrom(reading);
    const top = appViewportOffsetTopFrom(reading);
    // Suppressing no-op writes is what keeps the standing poll free, and it also keeps us
    // from invalidating layout 4x/second for values that have not moved. REQ-VIEWPORT-SWEEP-1:
    // the gate tests BOTH, because the offset also depends on `innerHeight` — a change that
    // moves the layout viewport and the visible region by the same amount (chrome retracting
    // as the keyboard closes) leaves the height identical while the offset moves, and gating
    // on the height alone would publish a stale offset.
    // REQ-VIEWPORT-ORIGIN-1: and the origin, which a pure pan moves with height unchanged.
    if (height === lastHeight && offset === lastOffset && top === lastTop) return;
    lastHeight = height;
    lastOffset = offset;
    lastTop = top;
    const style = win.document.documentElement.style;
    style.setProperty(APP_VIEWPORT_HEIGHT_VAR, `${height}px`);
    style.setProperty(APP_VIEWPORT_BOTTOM_OFFSET_VAR, `${offset}px`);
    style.setProperty(APP_VIEWPORT_OFFSET_TOP_VAR, `${top}px`);
  };

  const settle = () => {
    for (const delay of APP_VIEWPORT_SETTLE_DELAYS_MS) {
      const handle = win.setTimeout(() => {
        timers.delete(handle);
        apply();
      }, delay);
      timers.add(handle);
    }
  };

  // Read now (the transient), then again as it settles. See REQUIREMENT 1.
  const onEvent = () => {
    apply();
    settle();
  };

  apply();

  if (vv) {
    vv.addEventListener('resize', onEvent);
    vv.addEventListener('scroll', onEvent);
  }
  win.addEventListener('resize', onEvent);
  win.addEventListener('orientationchange', onEvent);
  // Geometry events only. Focus is NOT a trigger: treating focusin/focusout as "a keyboard is
  // about to move" is keyboard-state inference, which this module must not do. The standing
  // poll already covers transitions that fire no geometry event (REQUIREMENT 1).

  const poll = win.setInterval(apply, APP_VIEWPORT_POLL_MS);

  return () => {
    stopped = true;
    if (vv) {
      vv.removeEventListener('resize', onEvent);
      vv.removeEventListener('scroll', onEvent);
    }
    win.removeEventListener('resize', onEvent);
    win.removeEventListener('orientationchange', onEvent);
    win.clearInterval(poll as never);
    for (const handle of timers) win.clearTimeout(handle as never);
    timers.clear();
    // REQ-VIEWPORT-ORIGIN-1: a stale origin outlives the sampler that wrote it and keeps the
    // whole app displaced (a stale height merely mis-sizes it). Hand all three back to the
    // `styles.css` fallbacks, which are correct on every surface with nothing panned.
    if (lastHeight !== -1) {
      const style = win.document.documentElement.style;
      style.removeProperty?.(APP_VIEWPORT_HEIGHT_VAR);
      style.removeProperty?.(APP_VIEWPORT_BOTTOM_OFFSET_VAR);
      style.removeProperty?.(APP_VIEWPORT_OFFSET_TOP_VAR);
    }
  };
}
