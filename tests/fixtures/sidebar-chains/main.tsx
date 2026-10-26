import React from 'react';
import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
// The browser runner bypasses only AuthGate in a Vite transform, so the real
// shell/layout/styles are exercised without provisioning auth or vaults.
import AppShell from '../../../src/ui/components/shell/AppShell';
import { AuthUserProvider } from '../../../src/ui/components/auth/AuthUserContext';
import { ShortcutProvider } from '../../../src/ui/services/shortcuts/ShortcutContext';
import { store } from '../../../src/ui/store/store';
import { handleUserWsEvent } from '../../../src/ui/api/wsInvalidation';
import { announceTaskChainCreated } from '../../../src/ui/api/taskChainCreationEvents';
import { installAppViewportHeightSync } from '../../../src/ui/utils/appViewportHeight';
import '../../../src/ui/styles.css';

class StubSocket {
  static OPEN = 1; static CLOSED = 3;
  readyState = 1;
  addEventListener() {} removeEventListener() {} send() {} close() { this.readyState = 3; }
}
(window as any).WebSocket = StubSocket;
installAppViewportHeightSync(window as never);
const user = { user_id: 'sidebar-fixture', display_name: 'Sidebar Reviewer' };
(window as any).sidebarFixture = {
  store,
  created: announceTaskChainCreated,
  event: (event: any) => handleUserWsEvent(store.dispatch, event),
};
createRoot(document.getElementById('root')!).render(
  <Provider store={store}><ShortcutProvider><AuthUserProvider value={user}>
    <AppShell />
  </AuthUserProvider></ShortcutProvider></Provider>,
);
