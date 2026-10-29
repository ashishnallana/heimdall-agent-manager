import { useEffect, useState } from 'react';
import {
  windowControlsInsetLeft, windowControlsInsetRight,
  type WindowChromeStyle, type WindowTitlebarArea,
} from '../components/shell/shellChrome';
import { desktopCapabilities } from '../bridge/desktopBridge';

/** Read-only desktop chrome. Browser/PWA and older desktops keep native layout. */
export interface WindowChromeState {
  style: WindowChromeStyle;
  fullscreen: boolean;
  insetLeft: number;
  insetRight: number;
}

interface DesktopWindowChrome {
  style?: unknown;
  getState?: () => { fullscreen?: unknown } | undefined;
  onStateChange?: (callback: (state: { fullscreen?: unknown }) => void) => (() => void) | void;
}

export interface WindowControlsOverlaySource {
  visible: boolean;
  getTitlebarAreaRect: () => WindowTitlebarArea;
  addEventListener: (type: string, callback: () => void) => void;
  removeEventListener: (type: string, callback: () => void) => void;
}
interface ViewportSource {
  addEventListener: (type: string, callback: () => void) => void;
  removeEventListener: (type: string, callback: () => void) => void;
}

function desktopWindowChrome(): DesktopWindowChrome | null {
  return desktopCapabilities().windowChrome as DesktopWindowChrome | null;
}

export function readWindowChromeStyle(api: DesktopWindowChrome | null = desktopWindowChrome()): WindowChromeStyle {
  return api?.style === 'mac-hidden' || api?.style === 'win-overlay' ? api.style : 'native';
}

/** Subscribe before the initial read so an early geometry event cannot be lost. */
export function subscribeWindowChromeGeometry(
  overlay: WindowControlsOverlaySource | undefined, viewport: ViewportSource, update: () => void,
): () => void {
  overlay?.addEventListener('geometrychange', update);
  viewport.addEventListener('resize', update);
  update();
  return () => {
    overlay?.removeEventListener('geometrychange', update);
    viewport.removeEventListener('resize', update);
  };
}

function desktopOverlay(): WindowControlsOverlaySource | undefined {
  return typeof navigator === 'undefined' ? undefined : (navigator as any).windowControlsOverlay;
}
function readWindowsInset(): number {
  let area: WindowTitlebarArea | null = null;
  try {
    const overlay = desktopOverlay();
    if (overlay?.visible) area = overlay.getTitlebarAreaRect();
  } catch { /* Missing/invalid geometry uses a safe initial reservation. */ }
  return windowControlsInsetRight('win-overlay', false, typeof window === 'undefined' ? 0 : window.innerWidth, area);
}

/** Mirrors only desktop-reported styles onto <html>, gating all chrome CSS. */
export function applyWindowChromeAttributes(
  root: HTMLElement, style: WindowChromeStyle, fullscreen: boolean, insetRight = 0,
): void {
  if (style === 'native') {
    root.removeAttribute('data-window-chrome');
    root.removeAttribute('data-window-fullscreen');
    root.style.removeProperty('--window-controls-inset-left');
    root.style.removeProperty('--window-controls-inset-right');
    return;
  }
  root.setAttribute('data-window-chrome', style);
  if (fullscreen) root.setAttribute('data-window-fullscreen', '');
  else root.removeAttribute('data-window-fullscreen');
  root.style.setProperty('--window-controls-inset-left', `${windowControlsInsetLeft(style, fullscreen)}px`);
  root.style.setProperty('--window-controls-inset-right', `${style === 'win-overlay' && !fullscreen ? insetRight : 0}px`);
}

export function useWindowChrome(): WindowChromeState {
  const [style] = useState<WindowChromeStyle>(() => readWindowChromeStyle());
  const [fullscreen, setFullscreen] = useState<boolean>(() => {
    if (style === 'native') return false;
    try { return Boolean(desktopWindowChrome()?.getState?.()?.fullscreen); } catch { return false; }
  });
  const [windowsInset, setWindowsInset] = useState(() => style === 'win-overlay' ? readWindowsInset() : 0);

  useEffect(() => {
    if (style === 'native') return undefined;
    const api = desktopWindowChrome();
    if (typeof api?.onStateChange !== 'function') return undefined;
    const unsubscribe = api.onStateChange((state) => setFullscreen(Boolean(state?.fullscreen)));
    // Re-read after subscribing: reload may receive fullscreen state before this effect.
    try { setFullscreen(Boolean(api.getState?.()?.fullscreen)); } catch { /* keep current */ }
    return () => { if (typeof unsubscribe === 'function') unsubscribe(); };
  }, [style]);

  useEffect(() => {
    if (style !== 'win-overlay' || typeof window === 'undefined') return undefined;
    return subscribeWindowChromeGeometry(desktopOverlay(), window, () => setWindowsInset(readWindowsInset()));
  }, [style]);

  // Keep the last windowed geometry/fallback cached through fullscreen transitions.
  const insetRight = style === 'win-overlay' && !fullscreen ? windowsInset : 0;
  useEffect(() => {
    if (typeof document === 'undefined') return;
    applyWindowChromeAttributes(document.documentElement, style, fullscreen, insetRight);
  }, [style, fullscreen, insetRight]);

  return { style, fullscreen, insetLeft: windowControlsInsetLeft(style, fullscreen), insetRight };
}
