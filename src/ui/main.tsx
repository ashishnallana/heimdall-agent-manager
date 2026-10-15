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
import { initializeVaultPersistence } from './store/vaultSlice';
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

// Vault key rehydration (REQ-VAULT-HARDEN-2, wired for REQ-BVS-5).
// THIS CALL IS LOAD-BEARING — DO NOT REMOVE IT AS "UNUSED".
// `initializeVaultPersistence` is the ONLY code that restores the non-extractable
// CryptoKey from IndexedDB back into the module-level `activeVaultCryptoKey` in
// utils/vaultCrypto.ts. It shipped with ZERO production callers, so after any page
// reload `getActiveVaultKey()` returned null even though the key was still sitting in
// IndexedDB. The visible consequence: `createShell` (api/endpoints/shells.ts) omits
// `enc_spec` entirely when there is no active key, and every vault-active bridge then
// rejects shell creation with "unauthorized: missing or invalid vault enc_spec".
//
// It lives at module scope rather than in a component effect so it runs exactly once:
// React StrictMode double-mounts components in dev, while this module is evaluated a
// single time. The flag is parked on `globalThis` rather than in a module-local `let`
// precisely because a module-local one would be re-initialised along with the module —
// it guards the case a module-local cannot, namely a Vite HMR re-evaluation or a second
// copy of this module being pulled in by a different import path.
//
// It must NEVER fabricate an unlocked state: when IndexedDB holds no key the function
// dispatches nothing and resolves to null, leaving the app in exactly the state it is
// in today. Failures are swallowed inside the function and logged; startup is never
// blocked, hence `void`.
const VAULT_REHYDRATION_FLAG = '__heimdallVaultRehydrationStarted';
if (!(globalThis as any)[VAULT_REHYDRATION_FLAG]) {
  (globalThis as any)[VAULT_REHYDRATION_FLAG] = true;
  void initializeVaultPersistence(store.dispatch);
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
