const { contextBridge, ipcRenderer } = require('electron');

let pendingBridgeUpdateCheck = false;
const bridgeUpdateCheckListeners = new Set<() => void>();
ipcRenderer.on('heimdall-bridge:check-updates', () => {
  if (bridgeUpdateCheckListeners.size === 0) pendingBridgeUpdateCheck = true;
  for (const callback of bridgeUpdateCheckListeners) callback();
});

// REQ-MAC-CHROME-1: read-only window chrome state. The sandboxed preload cannot
// require windowChrome.cts, so the flag and channel are matched literally.
const windowChromeStyle = process.argv.includes('--heimdall-window-chrome=mac-hidden') ? 'mac-hidden'
  : process.argv.includes('--heimdall-window-chrome=win-overlay') ? 'win-overlay' : 'native';
let windowFullscreen = false;
const windowChromeListeners = new Set<(state: { fullscreen: boolean }) => void>();
ipcRenderer.on('heimdall-window:chrome-state', (_event: any, payload: any) => {
  windowFullscreen = Boolean(payload?.fullscreen);
  for (const callback of windowChromeListeners) callback({ fullscreen: windowFullscreen });
});

contextBridge.exposeInMainWorld('odinApi', {
  windowChrome: {
    style: windowChromeStyle,
    getState: () => ({ fullscreen: windowFullscreen }),
    onStateChange: (callback: (state: { fullscreen: boolean }) => void) => {
      windowChromeListeners.add(callback);
      return () => { windowChromeListeners.delete(callback); };
    },
  },
  notifications: {
    supported: process.argv.includes('--heimdall-native-notifications'),
    show: (plan: { title: string; body: string; tag: string; route: string }) =>
      ipcRenderer.invoke('heimdall-notifications:show', plan),
  },
  pickDirectory: () => ipcRenderer.invoke('odin-api:pick-directory'),
  daemonUrl: process.env.HEIMDALL_DAEMON_URL || '',
  hubApiBaseUrl: process.env.HEIMDALL_HUB_API_URL || process.env.HEIMDALL_HUB_URL || '',
  setAuthenticatedUser: (identity: any) => ipcRenderer.send('heimdall-auth:set-user', identity),
  // REQ-OIDC-DESKTOP-1: the desktop UI uses the Hub's HttpOnly OIDC session
  // cookie. No Hub user token/HUT storage or Authorization-header bridge is
  // exposed to the renderer.
  openExternal: (url: string) => ipcRenderer.invoke('heimdall-api:open-external', url),
  bridgeManager: {
    getStatus: () => ipcRenderer.invoke('heimdall-bridge:get-status'),
    installBundled: () => ipcRenderer.invoke('heimdall-bridge:install-bundled'),
    startEnrollment: () => ipcRenderer.invoke('heimdall-bridge:start-enrollment'),
    startReEnrollment: () => ipcRenderer.invoke('heimdall-bridge:start-re-enrollment'),
    onEnrollmentEvent: (callback: (event: any) => void) => {
      const listener = (_event: any, payload: any) => callback(payload);
      ipcRenderer.on('heimdall-bridge:enrollment-event', listener);
      return () => ipcRenderer.removeListener('heimdall-bridge:enrollment-event', listener);
    },
    onCheckUpdatesRequested: (callback: () => void) => {
      bridgeUpdateCheckListeners.add(callback);
      if (pendingBridgeUpdateCheck) {
        pendingBridgeUpdateCheck = false;
        queueMicrotask(callback);
      }
      return () => bridgeUpdateCheckListeners.delete(callback);
    },
  },
});
