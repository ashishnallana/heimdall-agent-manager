const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('odinApi', {
  notifications: {
    supported: process.argv.includes('--heimdall-native-notifications'),
    show: (plan: { title: string; body: string; tag: string; route: string }) =>
      ipcRenderer.invoke('heimdall-notifications:show', plan),
  },
  pickDirectory: () => ipcRenderer.invoke('odin-api:pick-directory'),
  daemonUrl: process.env.HEIMDALL_DAEMON_URL || '',
  hubApiBaseUrl: process.env.HEIMDALL_HUB_API_URL || process.env.HEIMDALL_HUB_URL || '',
  // REQ-OIDC-DESKTOP-1: the desktop UI uses the Hub's HttpOnly OIDC session
  // cookie. No Hub user token/HUT storage or Authorization-header bridge is
  // exposed to the renderer.
  openExternal: (url: string) => ipcRenderer.invoke('heimdall-api:open-external', url),
  // REQ-ENR-9/10: Settings > Bridges. Every call is re-checked in the main
  // process (sender origin, F25); the renderer gets status and progress only.
  bridgeManager: {
    getConfig: () => ipcRenderer.invoke('heimdall-bridge:get-config'),
    setHubUrl: (hubUrl: string) => ipcRenderer.invoke('heimdall-bridge:set-hub-url', hubUrl),
    getStatus: (target?: any) => ipcRenderer.invoke('heimdall-bridge:get-status', target || {}),
    list: () => ipcRenderer.invoke('heimdall-bridge:list'),
    run: (kind: string, target?: any, options?: any) => ipcRenderer.invoke('heimdall-bridge:run', kind, target || {}, options || {}),
    cancel: () => ipcRenderer.invoke('heimdall-bridge:cancel'),
    openLog: (logPath: string) => ipcRenderer.invoke('heimdall-bridge:open-log', logPath),
    onEvent: (callback: (event: any) => void) => {
      const listener = (_event: any, payload: any) => callback(payload);
      ipcRenderer.on('heimdall-bridge:event', listener);
      return () => ipcRenderer.removeListener('heimdall-bridge:event', listener);
    },
  },
});
