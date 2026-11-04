import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  APP_VIEWPORT_BOTTOM_OFFSET_VAR,
  APP_VIEWPORT_HEIGHT_VAR,
  APP_VIEWPORT_OFFSET_TOP_VAR,
  APP_VIEWPORT_POLL_MS,
  appViewportBottomOffsetFrom,
  appViewportHeightFrom,
  appViewportOffsetTopFrom,
  installAppViewportHeightSync,
  readAppViewport,
  type AppViewportReading,
} from '../src/ui/utils/appViewportHeight.ts';

// REQ-VIEWPORT-ORIGIN-1: the visible region has an ORIGIN as well as a height. Tabbed iOS
// Safari pans the visual viewport inside the layout viewport with the keyboard up, so the
// shell must be placed at `offsetTop` (from the same sample as its height), with `top`
// rather than `transform`, and only on fixed boxes.

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const stylesSource = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/styles.css'), 'utf8');

const reading = (r: Partial<AppViewportReading>): AppViewportReading => ({
  innerHeight: 812, visualHeight: 812, scale: 1, offsetTop: 0, ...r,
});

test('tabbed iOS Safari keyboard-up reading: shell height, origin and bottom offset describe the visible region', () => {
  // Device probe B (`?kbd=1&state=draft`, keyboard up): inner 630, vv h 377, offsetTop 84.
  const r = reading({ innerHeight: 630, visualHeight: 377, offsetTop: 84 });
  assert.equal(appViewportHeightFrom(r), 377);
  assert.equal(appViewportOffsetTopFrom(r), 84);
  assert.equal(appViewportBottomOffsetFrom(r), 630 - 84 - 377);
  // One line, three numbers: origin + height + bottom offset is the layout viewport.
  assert.equal(appViewportOffsetTopFrom(r) + appViewportHeightFrom(r) + appViewportBottomOffsetFrom(r), 630);
});

test('surfaces that do not pan are unchanged: standalone PWA (REQ-KBD-1), desktop and no visualViewport', () => {
  const pwa = reading({ innerHeight: 812, visualHeight: 409, offsetTop: 0 });
  assert.deepEqual([appViewportHeightFrom(pwa), appViewportOffsetTopFrom(pwa), appViewportBottomOffsetFrom(pwa)], [409, 0, 403]);
  const desktop = reading({ innerHeight: 900, visualHeight: 900, offsetTop: 0 });
  assert.deepEqual([appViewportHeightFrom(desktop), appViewportOffsetTopFrom(desktop), appViewportBottomOffsetFrom(desktop)], [900, 0, 0]);
  const legacy = reading({ innerHeight: 700, visualHeight: null, scale: null, offsetTop: null });
  assert.deepEqual([appViewportHeightFrom(legacy), appViewportOffsetTopFrom(legacy), appViewportBottomOffsetFrom(legacy)], [700, 0, 0]);
});

test('origin is floored at 0 but never capped by innerHeight; non-finite values read as 0', () => {
  // REQ-KBD-1 measured offsetTop -111..+466 for one 403px keyboard: negatives are rubber-band.
  assert.equal(appViewportOffsetTopFrom(reading({ visualHeight: 409, offsetTop: -111 })), 0);
  assert.equal(appViewportOffsetTopFrom(reading({ visualHeight: 409, offsetTop: Number.NaN })), 0);
  assert.equal(appViewportOffsetTopFrom(reading({ visualHeight: 409, offsetTop: 84.6 })), 85, 'rounded like the height');
  // Large origins pass through: innerHeight is not the layout viewport on WebKit (see below).
  assert.equal(appViewportOffsetTopFrom(reading({ visualHeight: 409, offsetTop: 466 })), 466);
  assert.equal(appViewportBottomOffsetFrom(reading({ visualHeight: 409, offsetTop: 466 })), 0, 'bottom offset floors at 0');
  for (let top = -200; top <= 600; top += 37) {
    assert.equal(appViewportOffsetTopFrom(reading({ visualHeight: 409, offsetTop: top })), Math.max(0, top));
  }
});

test('iPhone keyboard-up readouts: the published origin is exactly the visible origin, whatever innerHeight reports', () => {
  // Real samples from the preview server log (tabbed iOS Safari, keyboard up, main + aux chat).
  // `inner` wanders 377..544 while vv.height stays 377 and the fixed-box region stays 714 tall.
  // The old cap published min(offsetTop, inner - 377) and the shell landed at -top+y on screen.
  const samples = [
    { inner: 377, vh: 377, top: 337, oldY: 0 },
    { inner: 510, vh: 377, top: 204, oldY: 133 },
    { inner: 441, vh: 377, top: 190, oldY: 64 },
    { inner: 544, vh: 377, top: 87, oldY: 87 },
    { inner: 279, vh: 279, top: 435, oldY: 0 },
    { inner: 714, vh: 377, top: 0, oldY: 0 },
  ];
  for (const s of samples) {
    const r = reading({ innerHeight: s.inner, visualHeight: s.vh, offsetTop: s.top });
    const y = appViewportOffsetTopFrom(r);
    assert.equal(y, s.top, `inner ${s.inner} top ${s.top}: origin follows offsetTop (the old cap wrote ${s.oldY})`);
    // Independent model: the fixed-box region is 714 tall (documentElement.scrollHeight), so the
    // shell placed at the origin fits inside it on every sample.
    assert.ok(y + appViewportHeightFrom(r) <= 714, `inner ${s.inner}: shell stays inside the 714px region`);
    assert.equal(appViewportHeightFrom(r), s.vh);
  }
});

test('pinch-zoom stays a pure magnifier: no origin, full layout height, zero bottom offset', () => {
  const zoomed = reading({ innerHeight: 812, visualHeight: 300, scale: 2.5, offsetTop: 250 });
  assert.deepEqual([appViewportHeightFrom(zoomed), appViewportOffsetTopFrom(zoomed), appViewportBottomOffsetFrom(zoomed)], [812, 0, 0]);
});

test('the height never depends on offsetTop (REQUIREMENT 2 still holds for the height)', () => {
  for (const offsetTop of [-111, 0, 41, 99, 221, 403, 466]) {
    assert.equal(appViewportHeightFrom(reading({ visualHeight: 409, offsetTop })), 409);
  }
});

type Listener = () => void;
function fakeWindow(init: { innerHeight: number; height: number; offsetTop: number; scale?: number; removable?: boolean }) {
  const props = new Map<string, string>();
  const writes: Array<[string, string]> = [];
  const winListeners = new Map<string, Set<Listener>>();
  const vvListeners = new Map<string, Set<Listener>>();
  const timeouts = new Map<number, () => void>();
  const intervals = new Map<number, () => void>();
  let nextId = 1;
  const on = (m: Map<string, Set<Listener>>) => (t: string, l: Listener) => { if (!m.has(t)) m.set(t, new Set()); m.get(t)!.add(l); };
  const off = (m: Map<string, Set<Listener>>) => (t: string, l: Listener) => { m.get(t)?.delete(l); };
  const style: any = { setProperty: (n: string, v: string) => { props.set(n, v); writes.push([n, v]); } };
  if (init.removable !== false) style.removeProperty = (n: string) => { props.delete(n); };
  const vv = { height: init.height, offsetTop: init.offsetTop, scale: init.scale ?? 1, addEventListener: on(vvListeners), removeEventListener: off(vvListeners) };
  const win = {
    innerHeight: init.innerHeight,
    visualViewport: vv,
    document: { documentElement: { style } },
    addEventListener: on(winListeners),
    removeEventListener: off(winListeners),
    setTimeout: (fn: () => void) => { const id = nextId++; timeouts.set(id, fn); return id; },
    clearTimeout: (id: number) => { timeouts.delete(id); },
    setInterval: (fn: () => void, ms: number) => { assert.equal(ms, APP_VIEWPORT_POLL_MS); const id = nextId++; intervals.set(id, fn); return id; },
    clearInterval: (id: number) => { intervals.delete(id); },
  };
  const count = (m: Map<string, Set<Listener>>) => [...m.values()].reduce((n, s) => n + s.size, 0);
  return {
    win, vv, props, writes, timeouts, intervals,
    fireVv: (t: string) => { for (const l of [...(vvListeners.get(t) ?? [])]) l(); },
    tick: () => { for (const fn of [...intervals.values()]) fn(); },
    flushTimeouts: () => { for (const [id, fn] of [...timeouts]) { timeouts.delete(id); fn(); } },
    listenerCount: () => count(winListeners) + count(vvListeners),
    winListenerTypes: () => [...winListeners].filter(([, set]) => set.size > 0).map(([t]) => t).sort(),
    vvListenerTypes: () => [...vvListeners].filter(([, set]) => set.size > 0).map(([t]) => t).sort(),
  };
}

test('sync publishes height, bottom offset and origin from one sample, and a pure pan republishes the origin', () => {
  const f = fakeWindow({ innerHeight: 630, height: 377, offsetTop: 0 });
  const stop = installAppViewportHeightSync(f.win as never);
  try {
    assert.equal(f.props.get(APP_VIEWPORT_HEIGHT_VAR), '377px');
    assert.equal(f.props.get(APP_VIEWPORT_OFFSET_TOP_VAR), '0px');
    assert.equal(f.props.get(APP_VIEWPORT_BOTTOM_OFFSET_VAR), '253px');

    // iOS pans the visible region with the height unchanged: only the origin path can see it.
    f.vv.offsetTop = 84;
    f.fireVv('scroll');
    assert.equal(f.props.get(APP_VIEWPORT_HEIGHT_VAR), '377px');
    assert.equal(f.props.get(APP_VIEWPORT_OFFSET_TOP_VAR), '84px');
    assert.equal(f.props.get(APP_VIEWPORT_BOTTOM_OFFSET_VAR), '169px');

    // Unchanged readings cost no writes (the standing poll stays free) and the settle ladder
    // is timers, not frames.
    const before = f.writes.length;
    f.tick(); f.flushTimeouts(); f.tick();
    assert.equal(f.writes.length, before);
    assert.equal(f.intervals.size, 1, 'exactly the one standing poll');

    // A pan the event never reported is still caught by the poll (REQUIREMENT 1).
    f.vv.offsetTop = 40;
    f.tick();
    assert.equal(f.props.get(APP_VIEWPORT_OFFSET_TOP_VAR), '40px');
    assert.equal(f.props.get(APP_VIEWPORT_BOTTOM_OFFSET_VAR), '213px');

    // The layout viewport grows (chrome retracting) while iOS deepens the pan by the same
    // amount: height and bottom offset are identical, only the origin moved. A gate on the
    // first two alone would publish a stale origin here.
    f.win.innerHeight = 640; f.vv.offsetTop = 50;
    f.tick();
    assert.equal(f.props.get(APP_VIEWPORT_BOTTOM_OFFSET_VAR), '213px');
    assert.equal(f.props.get(APP_VIEWPORT_OFFSET_TOP_VAR), '50px');

    // Keyboard closes: back to the unpanned full viewport.
    f.win.innerHeight = 714; f.vv.height = 714; f.vv.offsetTop = 0;
    f.fireVv('resize');
    assert.deepEqual(
      [f.props.get(APP_VIEWPORT_HEIGHT_VAR), f.props.get(APP_VIEWPORT_OFFSET_TOP_VAR), f.props.get(APP_VIEWPORT_BOTTOM_OFFSET_VAR)],
      ['714px', '0px', '0px'],
    );
  } finally {
    stop();
  }
});

test('teardown removes listeners, timers and the poll, and hands every property back to the CSS fallbacks', () => {
  const f = fakeWindow({ innerHeight: 630, height: 377, offsetTop: 84 });
  const stop = installAppViewportHeightSync(f.win as never);
  f.fireVv('scroll');
  assert.ok(f.timeouts.size > 0, 'settle ladder pending');
  assert.ok(f.listenerCount() > 0);
  stop();
  assert.equal(f.listenerCount(), 0);
  assert.equal(f.timeouts.size, 0);
  assert.equal(f.intervals.size, 0);
  assert.equal(f.props.size, 0, 'no stale origin keeps the app displaced after teardown');
  // A callback that was already captured cannot write after teardown.
  const writes = f.writes.length;
  f.vv.offsetTop = 10;
  f.fireVv('scroll');
  assert.equal(f.writes.length, writes);

  // Callers whose style has no removeProperty (older fakes) still tear down cleanly.
  const legacy = fakeWindow({ innerHeight: 630, height: 377, offsetTop: 0, removable: false });
  installAppViewportHeightSync(legacy.win as never)();
  assert.equal(legacy.listenerCount(), 0);
});

test('readAppViewport carries offsetTop only when visualViewport provides it', () => {
  assert.equal(readAppViewport({ innerHeight: 700, visualViewport: null } as never).offsetTop, null);
  assert.equal(readAppViewport({ innerHeight: 700, visualViewport: { height: 300 } } as never).offsetTop, null);
  assert.equal(readAppViewport({ innerHeight: 700, visualViewport: { height: 300, offsetTop: 12 } } as never).offsetTop, 12);
});

function cssRule(selector: string): string {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const matches = [...stylesSource.matchAll(new RegExp(`(?:^|\\n)${escaped}\\s*\\{([^}]*)\\}`, 'g'))];
  assert.ok(matches.length > 0, `styles.css has a ${selector} rule`);
  return matches.map((m) => m[1]).join('\n');
}

test('styles.css places the in-flow tree and every fixed shell at the origin with `top`, never `transform`', () => {
  assert.match(cssRule(':root'), /--app-viewport-offset-top:\s*0px;/, 'pre-JS fallback is no offset');
  const body = cssRule('body');
  assert.match(body, /position:\s*fixed;[\s\S]*inset:\s*0;[\s\S]*top:\s*var\(--app-viewport-offset-top\);/, 'body top follows the origin, declared after inset');
  const shell = cssRule('.app-viewport-height');
  assert.match(shell, /top:\s*var\(--app-viewport-offset-top\);/);
  assert.match(shell, /height:\s*var\(--app-viewport-height\);/);
  // The utility must come after Tailwind's utilities so it beats the callers' `top-0`.
  assert.ok(stylesSource.indexOf('.app-viewport-height {') > stylesSource.indexOf('@tailwind utilities;'));
  // No transform anywhere is driven by the origin: it would re-parent fixed descendants.
  assert.doesNotMatch(stylesSource, /transform:[^;]*--app-viewport-offset-top/);
  assert.doesNotMatch(stylesSource, /translate[^;]*--app-viewport-offset-top/);
  // Bottom-pinned boxes keep using the bottom offset, which now accounts for the origin.
  assert.match(cssRule('.app-viewport-bottom'), /bottom:\s*var\(--app-viewport-bottom-offset\);/);
});

function walk(dir: string, out: string[] = []): string[] {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(p, out);
    else if (/\.tsx?$/.test(entry.name)) out.push(p);
  }
  return out;
}

test('every `app-viewport-height` class is on a position: fixed box (the utility now also sets `top`)', () => {
  const offenders: string[] = [];
  let uses = 0;
  for (const file of walk(path.join(REPO_ROOT, 'src/ui'))) {
    const source = fs.readFileSync(file, 'utf8');
    // Class strings only: quoted/template literals containing the bare class token.
    for (const m of source.matchAll(/(['"`])([^'"`\n]*?)\1/g)) {
      const literal = m[2];
      if (!/(^|\s)app-viewport-height(\s|$)/.test(literal)) continue;
      if (literal.trim() === 'app-viewport-height') continue; // a `code` mention in a comment
      uses++;
      if (!/(^|\s)fixed(\s|$)/.test(literal)) offenders.push(`${path.relative(REPO_ROOT, file)}: "${literal.trim().slice(0, 90)}"`);
    }
  }
  assert.ok(uses >= 15, `found the shell/overlay callers (${uses})`);
  assert.deepEqual(offenders, [], 'a non-fixed box with this utility would be shifted by the origin');
});

test('AppShell and the composer demo shells rely on the utility (no second origin of their own)', () => {
  const appShell = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/shell/AppShell.tsx'), 'utf8');
  const demo = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/dev/composerDemo.tsx'), 'utf8');
  assert.match(appShell, /data-debug-id="app-shell"\s+className="fixed inset-x-0 top-0 app-viewport-height /);
  assert.match(appShell, /fixed top-0 left-0 z-50 app-viewport-height w-80/, 'mobile sidebar is placed with the shell');
  assert.match(demo, /'fixed inset-x-0 top-0 app-viewport-height flex/);
  for (const [name, src] of [['AppShell', appShell], ['composerDemo shells', demo.replace(/function KeyboardReadout[\s\S]*?\n}\n/, '')]] as const) {
    assert.doesNotMatch(src, /offsetTop|--app-viewport-offset-top/, `${name} applies no origin itself`);
  }
});

test('the sampler listens to geometry events only: no focus-driven keyboard inference', () => {
  const f = fakeWindow({ innerHeight: 630, height: 377, offsetTop: 0 });
  const stop = installAppViewportHeightSync(f.win as never);
  try {
    assert.deepEqual(f.winListenerTypes(), ['orientationchange', 'resize']);
    assert.deepEqual(f.vvListenerTypes(), ['resize', 'scroll']);
  } finally {
    stop();
  }
  const sampler = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/utils/appViewportHeight.ts'), 'utf8');
  assert.doesNotMatch(sampler, /addEventListener\(\s*'focus/, 'no focus listener in the sampler');
});

test('the composer dock padding is static geometry, never the inferred keyboard height', () => {
  const pad = cssRule('.ui-float-dock-pad');
  assert.match(pad, /padding-bottom:\s*max\(0\.75rem,\s*env\(safe-area-inset-bottom,\s*0px\)\);/);
  assert.doesNotMatch(pad, /--app-viewport-bottom-offset|--app-viewport-height|vh|innerHeight/);
  // Main and auxiliary chat (both AgentChatPane) and the demo still use the class.
  const pane = fs.readFileSync(path.join(REPO_ROOT, 'src/ui/components/workbench/AgentChatPane.tsx'), 'utf8');
  assert.ok((pane.match(/ui-float-dock-pad/g) ?? []).length >= 2, 'conversation and pane docks');
  for (const rel of ['src/ui/components/workbench/AgentChatPane.tsx', 'src/ui/dev/composerDemo.tsx', 'src/ui/components/chat/MessageComposer.tsx']) {
    const src = fs.readFileSync(path.join(REPO_ROOT, rel), 'utf8');
    assert.doesNotMatch(src.replace(/function KeyboardReadout[\s\S]*?\n}\n/, ''), /--app-viewport-bottom-offset|visualViewport|innerHeight/, `${rel}: composer reads no keyboard geometry`);
  }
});

test('the shell and sampler never reset window scroll: no window scroll writes or scroll-clamp listener', () => {
  // A window scroll listener that calls scrollTo(0, 0) fights WebKit's reveal-the-field pan
  // (iOS pans, the clamp resets, iOS pans again). The body is position: fixed and the shell
  // follows the visible origin instead, so no scroll reset is needed or allowed.
  for (const rel of ['src/ui/components/shell/AppShell.tsx', 'src/ui/utils/appViewportHeight.ts']) {
    const code = fs
      .readFileSync(path.join(REPO_ROOT, rel), 'utf8')
      .replace(/^\s*\/\*[\s\S]*?\*\//gm, '')
      .replace(/^\s*\/\/.*$/gm, '');
    assert.doesNotMatch(code, /(?:\bwindow|\bglobalThis|(?<![\w.]))\.?scroll(To|By)?\(/, `${rel}: no window scroll writes`);
    assert.doesNotMatch(code, /(scrollingElement|documentElement|document\.body)\??\.scroll(To|By)?\(/, `${rel}: no document scroll writes`);
    assert.doesNotMatch(code, /(scrollingElement|documentElement|document\.body)\??\.scrollTop\s*=[^=]/, `${rel}: no document scrollTop writes`);
    assert.doesNotMatch(code, /clampWindowScroll/);
  }
});
