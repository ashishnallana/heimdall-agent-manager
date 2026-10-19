import React from 'react';
import ReactDOM from 'react-dom/client';
import { Provider } from 'react-redux';
import AppShell from './components/shell/AppShell';
import ElectronDeviceAuthGate, { installElectronApiFetchBridge } from './components/ElectronDeviceAuthGate';
import ToastViewport from './components/ToastViewport';
import { store } from './store/store';
import { legacyPathRouteHash } from './utils/appLocation';
import { registerNotificationServiceWorker } from './services/notificationService';
import { resubscribeOnLoad } from './services/pushSubscriptionService';
import { selectNotificationsState } from './store/notificationsSlice';
import { configureDeviceVault } from './services/deviceVault';
import { bridgeUnsealTransport } from './api/endpoints/bridges';
import { installAppViewportHeightSync } from './utils/appViewportHeight';
import { ShortcutProvider } from './services/shortcuts/ShortcutContext';
import { ChordHud } from './components/shortcuts/ChordHud';
import { ShortcutCheatsheetModal } from './components/shortcuts/ShortcutCheatsheetModal';
import './debugCapture';
import './styles.css';

// Legacy deep-link migration: if the app was opened at a real path-based route
// (e.g. an old bookmark `.../workspace/chains/X/tasks/Y?...`, or a direct
// `/device/add?code=...` / `/device/providers/<bridge>` hit) with no hash, fold
// that route into the hash. Only the fragment is replaced (a fragment-only URL
// resolves against the current document), so routing reads the hash from then
// on and an Electron file:// refresh always reloads the same document. See
// legacyPathRouteHash for the folding rules.
(function migrateLegacyPathRoute() {
  try {
    if (typeof window === 'undefined') return;
    const { pathname, search, hash } = window.location;
    const target = legacyPathRouteHash(pathname, search, hash);
    if (target) window.history.replaceState(window.history.state || {}, '', target);
  } catch (_err) {
    // Non-fatal: fall back to default routing.
  }
})();

// REQ-KBD-2: publish `--app-viewport-height` from `visualViewport.height` and keep it
// current. Everything that used to be sized `100dvh` reads that var instead, so the app
// shell ends where the soft keyboard begins. Installed before render — and deliberately
// NOT as a React hook — because `html`/`body`/`#root` are sized from it too, and those
// are outside the React tree. See src/ui/utils/appViewportHeight.ts for why this needs a
// settling tick and why it must never subtract `visualViewport.offsetTop`.
if (typeof window !== 'undefined') installAppViewportHeightSync(window as never);

(window as any).__debugStore = store;
installElectronApiFetchBridge();

// Register the notification service worker early so OS notifications work on
// platforms where the in-page Notification constructor is unavailable (iOS
// Safari PWAs) and to install the click->route message listener. No-ops under
// Electron / insecure contexts. Never blocks startup.
void registerNotificationServiceWorker();

// Resubscribe-on-load: if the user previously enabled notifications (and the
// browser still reports permission granted), refresh the Web Push subscription
// with the Hub. iOS drops subscriptions across reinstalls and endpoints can
// rotate, so we re-register whenever the app boots with notifications enabled.
// No-ops under Electron / insecure contexts and when the server has no VAPID
// key. Never blocks startup.
{
  const settings = selectNotificationsState(store.getState());
  void resubscribeOnLoad(settings.enabled, settings.permission === 'granted');
}

// Passwordless vault device boot (docs/plans/passwordless-vault.md §2 P3). Replaces the
// old password-key rehydration. Configured once at module scope (the flag survives a
// Vite HMR re-evaluation): the device vault uses this browser's IndexedDB identity and
// the real bridge transport. The boot itself needs the signed-in user, so AuthGate
// calls bootDeviceVault(user) as soon as /api/v1/me answers; until then — and until
// this device's keyring is verified and installed — DeviceVaultGate shows a gate
// screen instead of any decrypted surface.
const DEVICE_VAULT_FLAG = '__heimdallDeviceVaultConfigured';
if (!(globalThis as any)[DEVICE_VAULT_FLAG]) {
  (globalThis as any)[DEVICE_VAULT_FLAG] = true;
  configureDeviceVault({ bridges: bridgeUnsealTransport });
}

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <Provider store={store}>
      <ShortcutProvider>
        <ElectronDeviceAuthGate>
          <AppShell />
        </ElectronDeviceAuthGate>
        <ChordHud />
        <ShortcutCheatsheetModal />
      </ShortcutProvider>
      {/*
        REQ-UI-TOAST-1. THIS MOUNT IS LOAD-BEARING — DO NOT REMOVE IT AS "UNUSED".
        ToastViewport is the ONLY component that selects the store/toastSlice
        queue. Without it, `dispatch(showToast(...))` still runs, still mutates
        state and still returns cleanly, while the user sees nothing at all. It
        shipped unmounted, and four call sites dispatched into that void for its
        whole life — including the Notifications "Test notification" button,
        whose entire purpose is to prove notifications work.
        It sits OUTSIDE ElectronDeviceAuthGate on purpose: it needs only the
        store, so a toast can still surface on the pre-auth screen. It portals to
        document.body, so its position in this tree does not affect layout.
        Note this is NOT the app's only toast mechanism — five list pages render
        their own local ones (see REQ-UI-TOAST-2). They never dispatch to this
        queue, so nothing here double-renders.
      */}
      <ToastViewport />
    </Provider>
  </React.StrictMode>,
);
