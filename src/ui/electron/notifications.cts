// The renderer owns notification policy and vault decryption. This module only
// accepts display-ready text from the trusted main frame and owns OS delivery.
function installNotifications({ ipcMain, Notification, getWindow, showWindow, uiUrl, icon }: any) {
  const active = new Map<string, any>();

  function trustedUrl(value: string): boolean {
    try {
      const url = new URL(value);
      return url.origin === new URL(uiUrl).origin && !url.pathname.startsWith('/api/');
    } catch { return false; }
  }

  function trustedSender(event: any): boolean {
    const win = getWindow();
    return Boolean(win && !win.isDestroyed() && event.sender === win.webContents &&
      event.senderFrame === win.webContents.mainFrame && trustedUrl(event.senderFrame?.url));
  }

  function validPlan(value: any): boolean {
    if (!value || typeof value !== 'object') return false;
    const bounded = (key: string, max: number) => typeof value[key] === 'string' &&
      value[key].length > 0 && value[key].length <= max && !value[key].includes('\0');
    return bounded('title', 256) && bounded('body', 4096) && bounded('tag', 512) &&
      bounded('route', 2048) && /^(?:#)?\/(?:conversations|chains|settings)(?:[/?][^#\s\\]*)?$/.test(value.route);
  }

  ipcMain.handle('heimdall-notifications:show', async (event: any, plan: any) => {
    if (!trustedSender(event) || !validPlan(plan) || !Notification.isSupported()) return false;
    return new Promise<boolean>((resolve) => {
      let notification: any;
      let timer: ReturnType<typeof setTimeout>;
      let settled = false;
      const finish = (shown: boolean) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(shown);
      };
      const release = () => {
        if (active.get(plan.tag)?.notification === notification) active.delete(plan.tag);
        finish(false);
      };
      try {
        // Coalesce repeated events per thread and bound native object retention.
        active.get(plan.tag)?.close();
        if (active.size >= 100) active.values().next().value?.close();
        notification = new Notification({ title: plan.title, body: plan.body, icon });
        const entry = {
          notification,
          close() {
            release();
            try { notification.close(); } catch { /* already destroyed by the OS */ }
          },
        };
        active.set(plan.tag, entry);
        notification.once('show', () => finish(true));
        notification.once('failed', release);
        notification.once('close', release);
        notification.once('click', () => {
          finish(true);
          release();
          const win = showWindow();
          const navigate = () => {
            if (win.isDestroyed() || !trustedUrl(win.webContents.getURL())) return;
            // JSON serialization keeps display content out of executable code.
            const hash = plan.route.startsWith('#') ? plan.route : `#${plan.route}`;
            void win.webContents.executeJavaScript(`window.location.hash = ${JSON.stringify(hash)}`)
              .catch(() => undefined);
          };
          if (win.webContents.isLoadingMainFrame()) win.webContents.once('did-finish-load', navigate);
          else navigate();
        });
        timer = setTimeout(() => entry.close(), 5000);
        notification.show();
      } catch {
        release();
      }
    });
  });

  return {
    dispose() {
      for (const notification of active.values()) notification.close();
      active.clear();
    },
  };
}

export = { installNotifications };
