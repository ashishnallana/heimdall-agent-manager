// REQ-MAC-CHROME-1 / REQ-WIN-CHROME-1: on macOS the main window hides the gray native title bar
// and keeps the native traffic lights, centered in the renderer's 48px top
// chrome row (shellChrome.ts TOP_CHROME_HEIGHT). Windows uses native caption
// buttons in a 48px overlay on the right. The window frame stays, so
// resize edges, shadow, the Window menu and Cmd-W/M are unchanged.
// Linux and native-title-bar opt-out keep their previous options.
//
// HEIMDALL_NATIVE_TITLE_BAR=1 restores the native title bar. It is a diagnostic
// kill switch, so the separate web-contents/window misalignment can be
// reproduced with and without the hidden title bar.

const MAC_HIDDEN_STYLE = 'mac-hidden';
const WINDOWS_OVERLAY_STYLE = 'win-overlay';
const CHROME_ARG_PREFIX = '--heimdall-window-chrome=';
// 12-14px buttons centered on y=24 of the 48px row.
const MAC_TRAFFIC_LIGHT_POSITION = { x: 16, y: 17 };

function windowChromeStyle(platform: string, env: Record<string, string | undefined>): string {
  if (String(env.HEIMDALL_NATIVE_TITLE_BAR || '').trim() === '1') return 'native';
  if (platform === 'darwin') return MAC_HIDDEN_STYLE;
  if (platform === 'win32') return WINDOWS_OVERLAY_STYLE;
  return 'native';
}

function windowChromeOptions(platform: string, env: Record<string, string | undefined>): Record<string, unknown> {
  const style = windowChromeStyle(platform, env);
  if (style === WINDOWS_OVERLAY_STYLE) {
    // Native caption buttons preserve Windows Snap and accessibility.
    return { titleBarStyle: 'hidden', titleBarOverlay: { height: 48 }, autoHideMenuBar: true };
  }
  if (style !== MAC_HIDDEN_STYLE) return {};
  return { titleBarStyle: 'hidden', trafficLightPosition: { ...MAC_TRAFFIC_LIGHT_POSITION } };
}

// Passed to the preload through webPreferences.additionalArguments (the
// sandboxed preload cannot require this module, so it matches the literal
// flag). Absent with the native title bar, so the renderer keeps its layout.
function windowChromeArgs(platform: string, env: Record<string, string | undefined>): string[] {
  const style = windowChromeStyle(platform, env);
  return style === 'native' ? [] : [`${CHROME_ARG_PREFIX}${style}`];
}

export = {
  CHROME_STATE_CHANNEL: 'heimdall-window:chrome-state',
  windowChromeStyle,
  windowChromeOptions,
  windowChromeArgs,
};
