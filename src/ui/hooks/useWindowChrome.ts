import { useEffect, useState } from 'react';
import { windowControlsInsetLeft, type WindowChromeStyle } from '../components/shell/shellChrome';

/**
 * REQ-MAC-CHROME-1: window chrome reported by the desktop preload
 * (`odinApi.windowChrome`). The browser/PWA, Windows/Linux and older desktops
 * expose no `mac-hidden` style, so this stays `native` with a zero inset and
 * never sets the `data-window-chrome` attribute that gates drag-region CSS.
 */
export interface WindowChromeState {
  style: WindowChromeStyle;
  fullscreen: boolean;
  insetLeft: number;
}

interface DesktopWindowChrome {
  style?: unknown;
  getState?: () => { fullscreen?: unknown } | undefined;
  onStateChange?: (callback: (state: { fullscreen?: unknown }) => void) => (() => void) | void;
}

function desktopWindowChrome(): DesktopWindowChrome | null {
  if (typeof window === 'undefined') return null;
  const api = (window as any).odinApi?.windowChrome;
  return api && typeof api === 'object' ? api : null;
}

export function readWindowChromeStyle(api: DesktopWindowChrome | null = desktopWindowChrome()): WindowChromeStyle {
  return api?.style === 'mac-hidden' ? 'mac-hidden' : 'native';
}

/** Mirrors the state onto <html> so CSS can gate drag regions and the inset. */
export function applyWindowChromeAttributes(root: HTMLElement, style: WindowChromeStyle, fullscreen: boolean): void {
  if (style !== 'mac-hidden') {
    root.removeAttribute('data-window-chrome');
    root.removeAttribute('data-window-fullscreen');
    root.style.removeProperty('--window-controls-inset-left');
    return;
  }
  root.setAttribute('data-window-chrome', style);
  if (fullscreen) root.setAttribute('data-window-fullscreen', '');
  else root.removeAttribute('data-window-fullscreen');
  root.style.setProperty('--window-controls-inset-left', `${windowControlsInsetLeft(style, fullscreen)}px`);
}

export function useWindowChrome(): WindowChromeState {
  const [style] = useState<WindowChromeStyle>(() => readWindowChromeStyle());
  const [fullscreen, setFullscreen] = useState<boolean>(() => {
    if (style !== 'mac-hidden') return false;
    try { return Boolean(desktopWindowChrome()?.getState?.()?.fullscreen); } catch { return false; }
  });

  useEffect(() => {
    if (style !== 'mac-hidden') return undefined;
    const api = desktopWindowChrome();
    if (typeof api?.onStateChange !== 'function') return undefined;
    const unsubscribe = api.onStateChange((state) => setFullscreen(Boolean(state?.fullscreen)));
    // The main process may have sent a state (e.g. reload while fullscreen)
    // between the initial getState() read and this subscription; re-read it.
    try { setFullscreen(Boolean(api.getState?.()?.fullscreen)); } catch { /* keep current */ }
    return () => { if (typeof unsubscribe === 'function') unsubscribe(); };
  }, [style]);

  useEffect(() => {
    if (typeof document === 'undefined') return;
    applyWindowChromeAttributes(document.documentElement, style, fullscreen);
  }, [style, fullscreen]);

  return { style, fullscreen, insetLeft: windowControlsInsetLeft(style, fullscreen) };
}
