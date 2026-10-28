// REQ-MAC-CHROME-1: on macOS the main window hides the gray native title bar
// and keeps the native traffic lights, centered in the renderer's 48px top
// chrome row (shellChrome.ts TOP_CHROME_HEIGHT). The window frame stays, so
// resize edges, shadow, the Window menu and Cmd-W/M are unchanged. Every other
// platform gets exactly the options it had before.
//
// HEIMDALL_NATIVE_TITLE_BAR=1 restores the native title bar. It is a diagnostic
// kill switch, so the separate web-contents/window misalignment can be
// reproduced with and without the hidden title bar.

const MAC_HIDDEN_STYLE = 'mac-hidden';
const CHROME_ARG_PREFIX = '--heimdall-window-chrome=';
// 12-14px buttons centered on y=24 of the 48px row.
const MAC_TRAFFIC_LIGHT_POSITION = { x: 16, y: 17 };

function windowChromeStyle(platform: string, env: Record<string, string | undefined>): string {
  if (platform !== 'darwin') return 'native';
  if (String(env.HEIMDALL_NATIVE_TITLE_BAR || '').trim() === '1') return 'native';
  return MAC_HIDDEN_STYLE;
}

function windowChromeOptions(platform: string, env: Record<string, string | undefined>): Record<string, unknown> {
  if (windowChromeStyle(platform, env) !== MAC_HIDDEN_STYLE) return {};
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
