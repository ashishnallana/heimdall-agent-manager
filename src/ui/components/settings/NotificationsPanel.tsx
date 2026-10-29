import { useCallback, useEffect, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import {
  categoryEnabled,
  notificationCategorySet,
  notificationPermissionRefreshed,
  notificationPermissionSet,
  notificationsEnabledSet,
  selectNotificationsState,
} from '../../store/notificationsSlice';
import type { NotificationCategory } from '../../api/notificationMapper';
import {
  isElectronRuntime,
  isNotificationSupported,
  requestNotificationPermission,
  showNativeNotification,
} from '../../services/notificationService';
import {
  disablePushSubscription,
  enablePushSubscription,
  getActiveSubscriptionKey,
  getServerVapidPublicKey,
  isPushSupported,
  resubscribeWithCurrentKey,
} from '../../services/pushSubscriptionService';
import { showToast } from '../../store/toastSlice';
import { Button, Panel, PageShell, Toggle } from '@ui';

const CATEGORY_LABELS: Array<{ key: NotificationCategory; label: string; description: string }> = [
  { key: 'chat', label: 'Chat messages', description: 'New messages directed to you, nudges, and mentions.' },
  { key: 'attention', label: 'Needs attention', description: 'Agent questions/approvals and pending merge decisions.' },
];

// H11: the sample plan the Send-test-notification button fires through the real
// native path. Exported so tests can assert exactly what is shown.
export const TEST_NOTIFICATION_PLAN = {
  title: 'Ninjy test notification',
  body: 'If you can see this, notifications are working.',
  tag: 'heimdall-test',
  route: '#/settings',
  category: 'attention' as const,
};

  // H11: pure helper computing the always-shown in-app toast message for the test
// button, covering every case (native fired / electron / unsupported / denied /
// default). Pure + exported so it is unit-testable without React.
export function testNotificationFeedback(opts: {
  nativeShown: boolean;
  electron: boolean;
  supported: boolean;
  permission: string;
}): string {
  if (opts.nativeShown) {
    return 'Sent a native notification. If your tab is focused the OS popup may be suppressed — this toast confirms the path fired.';
  }
  if (opts.electron) {
    return 'The desktop app could not show a notification. Check your system notification settings; this toast confirms the test ran.';
  }
  if (!opts.supported) {
    return 'This browser has no Notifications API; showing an in-app toast instead.';
  }
  if (opts.permission === 'denied') {
    return 'Notifications are blocked for this site — enable them in your browser settings. Showing an in-app toast for now.';
  }
  return 'Showing an in-app test notification.';
}

// Web Push diagnostics: the three comparison states between the browser's active
// subscription key and the server's current VAPID key.
type PushKeyStatus = 'MATCH' | 'MISMATCH' | 'NO SUBSCRIPTION';

// Pure: derive the status badge from the two keys. MATCH only when both are
// present and equal; MISMATCH when both present and differ; NO SUBSCRIPTION when
// the browser has no active subscription key. Exported for unit testing.
export function pushKeyStatus(frontendKey: string, serverKey: string): PushKeyStatus {
  if (!frontendKey) return 'NO SUBSCRIPTION';
  if (serverKey && frontendKey === serverKey) return 'MATCH';
  return 'MISMATCH';
}

// Pure: friendly label for a push endpoint host so the user can tell WHICH push
// service (Apple vs FCM) the subscription is bound to. Exported for testing.
export function pushEndpointHostLabel(host: string): string {
  if (host.includes('push.apple.com')) return 'Apple';
  if (host.includes('fcm.googleapis.com') || host.includes('android')) return 'FCM';
  return host;
}

// Pure: truncate a long key to first12…last6, keeping short keys intact. The
// full value is shown in the title attribute at the call site. Exported for
// testing.
export function truncateKey(key: string): string {
  if (!key) return '—';
  if (key.length <= 20) return key;
  return `${key.slice(0, 12)}…${key.slice(-6)}`;
}

type PushDiagnostics = {
  serverKey: string;
  frontendKey: string;
  endpointHost: string;
  status: PushKeyStatus;
};

export default function NotificationsPanel() {
  const dispatch = useDispatch();
  const state = useSelector(selectNotificationsState);
  const supported = isNotificationSupported();
  const electron = isElectronRuntime();

  // Web Push diagnostics: which VAPID key the browser's live subscription is
  // bound to vs the server's current key. `null` = not loaded yet.
  const pushDiagAvailable = isPushSupported() && !electron;
  const [pushDiag, setPushDiag] = useState<PushDiagnostics | null>(null);
  const [resubscribing, setResubscribing] = useState(false);

  const loadPushDiagnostics = useCallback(async () => {
    if (!pushDiagAvailable) {
      setPushDiag(null);
      return;
    }
    const [serverKey, sub] = await Promise.all([getServerVapidPublicKey(), getActiveSubscriptionKey()]);
    const frontendKey = sub?.applicationServerKey ?? '';
    const host = sub ? (() => { try { return new URL(sub.endpoint).host; } catch { return ''; } })() : '';
    setPushDiag({
      serverKey,
      frontendKey,
      endpointHost: pushEndpointHostLabel(host),
      status: pushKeyStatus(frontendKey, serverKey),
    });
  }, [pushDiagAvailable]);

  useEffect(() => {
    void loadPushDiagnostics();
  }, [loadPushDiagnostics]);

  // Force unsubscribe → fresh subscribe against the server's CURRENT VAPID key,
  // then reload the diagnostics and always surface a toast.
  async function onResubscribe() {
    setResubscribing(true);
    let ok = false;
    try {
      ok = await resubscribeWithCurrentKey();
    } catch (_err) {
      ok = false;
    }
    await loadPushDiagnostics();
    setResubscribing(false);
    dispatch(showToast(ok
      ? { kind: 'success', title: 'Re-subscribed', message: 'Push subscription refreshed against the current server key.' }
      : { kind: 'error', title: 'Re-subscribe failed', message: 'Could not create a fresh push subscription — check that notifications are granted and the server has a VAPID key.' }));
  }

  // Keep the stored permission in sync with the live browser state on mount and
  // when the tab regains visibility (the user may have changed it in browser
  // settings). This is feature-detection only — never requestPermission().
  useEffect(() => {
    dispatch(notificationPermissionRefreshed());
    const onVisibility = () => dispatch(notificationPermissionRefreshed());
    document.addEventListener('visibilitychange', onVisibility);
    return () => document.removeEventListener('visibilitychange', onVisibility);
  }, [dispatch]);

  const masterDisabled = !supported || state.permission === 'denied';

  // H11: fire a real test notification so the user can confirm notifications
  // appear. It ALWAYS dispatches an in-app toast (visible feedback in every case:
  // focused tab, Electron, denied, or unsupported) and, when native
  // notifications are supported + granted, also fires the real native path via
  // showNativeNotification. Non-throwing: any failure still yields a toast.
  async function onSendTest() {
    let nativeShown = false;
    let permission = state.permission;
    try {
      if (supported && permission === 'granted') {
        nativeShown = await showNativeNotification(TEST_NOTIFICATION_PLAN);
      } else if (supported && permission === 'default') {
        // Explicit user gesture: it is safe to request permission here. If granted,
        // fire the native notification immediately.
        permission = await requestNotificationPermission();
        dispatch(notificationPermissionSet(permission));
        if (permission === 'granted') {
          nativeShown = await showNativeNotification(TEST_NOTIFICATION_PLAN);
        }
      }
    } catch (_err) {
      // never throw from a test button; the toast below still fires.
      nativeShown = false;
    }
    // Always give visible in-app feedback.
    dispatch(showToast({
      kind: 'info',
      title: 'Test notification',
      message: testNotificationFeedback({ nativeShown, electron, supported, permission }),
    }));
  }

  async function onMasterToggle(next: boolean) {
    if (!next) {
      dispatch(notificationsEnabledSet(false));
      // Best-effort: drop the Web Push subscription so the Hub stops sending
      // background notifications. Non-blocking and never throws.
      void disablePushSubscription();
      return;
    }
    // Turning ON: request permission from this explicit user gesture if needed.
    if (state.permission !== 'granted') {
      const result = await requestNotificationPermission();
      dispatch(notificationPermissionSet(result));
      if (result !== 'granted') return; // denied/unsupported => stay off, no error thrown
    }
    dispatch(notificationsEnabledSet(true));
    // Subscribe to Web Push so notifications arrive when the PWA is fully
    // backgrounded/closed (the WS path only fires while the tab is alive). This
    // is a no-op under Electron / insecure contexts and when the server has no
    // VAPID key configured. Fire-and-forget: it must not block the toggle.
    void enablePushSubscription();
  }

  const statusLine = electron
    ? supported
      ? 'Native desktop notifications are available. Your system notification settings control banners and sounds.'
      : 'Native notifications are unavailable in this desktop session. Update the desktop app and check your system notification service.'
    : !supported
      ? 'This browser does not support the Web Notifications API. Notifications are unavailable here.'
      : state.permission === 'denied'
        ? 'Notifications are blocked for this site. Re-enable them in your browser site settings, then reload.'
        : state.permission === 'granted'
          ? 'Permission granted. You will be notified while this tab is open in the background.'
          : 'Permission not requested yet. Turn on notifications to grant permission.';

  return (
    <PageShell
      title="Notifications"
      description="Get native notifications for important events. Notifications for the conversation you are viewing are suppressed while the app is focused."
    >
      <div data-debug-id="settings-notifications-panel" className="space-y-5 text-left">
      <Panel>
        <div className="flex items-start justify-between gap-4">
          <div>
            <div className="font-semibold text-primary">{electron ? 'Enable desktop notifications' : 'Enable browser notifications'}</div>
            <p className="mt-1 text-sm text-muted" data-debug-id="settings-notifications-status">{statusLine}</p>
          </div>
          <Toggle
            checked={state.enabled}
            onChange={onMasterToggle}
            disabled={masterDisabled}
            data-debug-id="settings-notifications-master-toggle"
            aria-label={electron ? 'Enable desktop notifications' : 'Enable browser notifications'}
          />
        </div>
      </Panel>

      <Panel className={state.enabled ? '' : 'opacity-50'}>
        <div className="mb-3 text-sm font-semibold text-primary">Categories</div>
        <div className="space-y-3">
          {CATEGORY_LABELS.map((cat) => (
            <div key={cat.key} className="flex items-start justify-between gap-4">
              <div>
                <div className="text-sm font-medium text-primary">{cat.label}</div>
                <p className="mt-0.5 text-xs text-muted">{cat.description}</p>
              </div>
              <Toggle
                checked={categoryEnabled(state, cat.key)}
                onChange={(next) => dispatch(notificationCategorySet({ category: cat.key, enabled: next }))}
                disabled={!state.enabled}
                data-debug-id={`settings-notifications-category-${cat.key}`}
                aria-label={cat.label}
              />
            </div>
          ))}
        </div>
      </Panel>

      <Panel>
        <div className="flex items-start justify-between gap-4">
          <div>
            <div className="font-semibold text-primary">Test notifications</div>
            <p className="mt-1 text-sm text-muted">
              Send a sample notification to check native delivery. Your system settings control banner visibility;
              an in-app toast reports the result every time.
            </p>
          </div>
          <Button
            variant="primary"
            data-debug-id="settings-notifications-test-btn"
            onClick={() => void onSendTest()}
            className="shrink-0"
          >
            Send test notification
          </Button>
        </div>
      </Panel>

      <Panel>
        <div className="mb-3">
          <div className="font-semibold text-primary">Web Push diagnostics</div>
          <p className="mt-1 text-sm text-muted">
            Compare the VAPID public key your browser&apos;s active push subscription is bound to against the server&apos;s
            current key. A mismatch (e.g. after a server key rotation) causes the push service to reject deliveries.
          </p>
        </div>

        {!pushDiagAvailable ? (
          <p className="text-sm text-muted" data-debug-id="settings-push-unavailable">
            Web Push isn&apos;t available in this context.
          </p>
        ) : (
          <div className="space-y-3">
            <div className="flex items-center justify-between gap-4">
              <span className="text-sm text-muted">Status</span>
              <span
                data-debug-id="settings-push-match-badge"
                className={`rounded-full px-2.5 py-0.5 text-xs font-semibold ${
                  pushDiag?.status === 'MATCH'
                    ? 'bg-success-soft text-success'
                    : pushDiag?.status === 'MISMATCH'
                      ? 'bg-danger-soft text-danger'
                      : 'bg-neutral-soft text-muted'
                }`}
              >
                {pushDiag?.status ?? '…'}
              </span>
            </div>

            <div className="flex items-center justify-between gap-4">
              <span className="text-sm text-muted">Server key</span>
              <span
                data-debug-id="settings-push-server-key"
                title={pushDiag?.serverKey || ''}
                className="font-mono text-xs text-primary"
              >
                {truncateKey(pushDiag?.serverKey ?? '')}
              </span>
            </div>

            <div className="flex items-center justify-between gap-4">
              <span className="text-sm text-muted">Frontend key</span>
              <span
                data-debug-id="settings-push-frontend-key"
                title={pushDiag?.frontendKey || ''}
                className="font-mono text-xs text-primary"
              >
                {truncateKey(pushDiag?.frontendKey ?? '')}
              </span>
            </div>

            <div className="flex items-center justify-between gap-4">
              <span className="text-sm text-muted">Endpoint host</span>
              <span
                data-debug-id="settings-push-endpoint-host"
                className="font-mono text-xs text-primary"
              >
                {pushDiag?.endpointHost || '—'}
              </span>
            </div>

            <div className="flex justify-end pt-1">
              <Button
                variant="primary"
                data-debug-id="settings-push-resubscribe-btn"
                onClick={() => void onResubscribe()}
                disabled={resubscribing}
                className="shrink-0"
              >
                {resubscribing ? 'Re-subscribing…' : 'Re-subscribe with current key'}
              </Button>
            </div>
          </div>
        )}
      </Panel>
      </div>
    </PageShell>
  );
}
