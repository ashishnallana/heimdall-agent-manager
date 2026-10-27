const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('odinApi', {
  pickDirectory: () => ipcRenderer.invoke('odin-api:pick-directory'),
  getDebugInfo: () => ipcRenderer.invoke('odin-api:get-debug-info'),
  toggleDebugServer: (enable: boolean) => ipcRenderer.invoke('odin-api:toggle-debug-server', enable),
  daemonUrl: process.env.HEIMDALL_DAEMON_URL || '',
  hubApiBaseUrl: process.env.HEIMDALL_HUB_API_URL || process.env.HEIMDALL_HUB_URL || '',
  // REQ-OIDC-DESKTOP-1: the desktop UI uses the Hub's HttpOnly OIDC session
  // cookie. No Hub user token/HUT storage or Authorization-header bridge is
  // exposed to the renderer.
  openExternal: (url: string) => ipcRenderer.invoke('heimdall-api:open-external', url),
  bridgeManager: {
    getStatus: () => ipcRenderer.invoke('heimdall-bridge:get-status'),
    installBundled: () => ipcRenderer.invoke('heimdall-bridge:install-bundled'),
    startEnrollment: () => ipcRenderer.invoke('heimdall-bridge:start-enrollment'),
    onEnrollmentEvent: (callback: (event: any) => void) => {
      const listener = (_event: any, payload: any) => callback(payload);
      ipcRenderer.on('heimdall-bridge:enrollment-event', listener);
      return () => ipcRenderer.removeListener('heimdall-bridge:enrollment-event', listener);
    },
  },
});
