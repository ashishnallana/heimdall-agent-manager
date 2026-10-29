// Heimdall notification service worker (Level 1 local + Level 2 Web Push).
//
// Purpose: enable OS notifications on platforms where the in-page
// `new Notification()` constructor is unavailable/blocked — most importantly
// iOS/iPadOS Safari installed as a Home-Screen PWA (16.4+), which ONLY supports
// notifications via ServiceWorkerRegistration.showNotification(). On desktop
// Chrome/Edge/Firefox/Safari this path also works and is preferred.
//
// Responsibilities: (a) exist so the page can call reg.showNotification() for
// the WS-driven local path; (b) handle the W3C `push` event so background/closed
// PWAs still notify (Level 2); (c) route notification clicks back to an existing
// app window (or open one); (d) best-effort resubscribe on
// `pushsubscriptionchange`.

/* eslint-disable no-restricted-globals */

// Activate immediately so the first registration can show notifications without
// requiring a reload.
self.addEventListener('install', () => {
  self.skipWaiting();
});
self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
});

// App icon shown on every notification (falls back to the browser default when
// absent). Resolved against the SW scope so it works under a sub-path deploy.
const NOTIFICATION_ICON = 'icon.png';
const VAULT_ARMOR_PREFIX = 'vault:v1:';
const ENCRYPTED_NOTIFICATION_BODY = '[🔒 Encrypted notification]';

// Fallback content so a push with a missing/undecodable payload STILL shows a
// visible notification — on iOS a silent push (one that shows nothing) causes
// Safari to revoke the push permission. Mirrors pushNotificationMapper.ts.
const PUSH_FALLBACK = {
  title: 'Ninjy',
  body: 'You have a new notification.',
  tag: 'heimdall:push',
  route: '/conversations',
  href: '',
};

// Turn a decoded push payload into the concrete showNotification arguments.
// Total by design: any missing field falls back so we always show something.
function planForPushPayload(payload) {
  const p = (payload && typeof payload === 'object') ? payload : {};
  const rawTitle = p.title ? String(p.title) : '';
  const rawBody = p.body ? String(p.body) : '';
  return {
    // Defense in depth for old/cached Hubs and malformed producer payloads.
    // A service worker has no Vault key, so it must never render ciphertext.
    title: rawTitle.includes(VAULT_ARMOR_PREFIX)
      ? ENCRYPTED_NOTIFICATION_BODY
      : rawTitle || PUSH_FALLBACK.title,
    body: rawBody.includes(VAULT_ARMOR_PREFIX)
      ? ENCRYPTED_NOTIFICATION_BODY
      : rawBody || PUSH_FALLBACK.body,
    tag: (p.tag ? String(p.tag) : '') || PUSH_FALLBACK.tag,
    route: (p.route ? String(p.route) : '') || PUSH_FALLBACK.route,
    href: p.href ? String(p.href) : PUSH_FALLBACK.href,
  };
}

// Web Push (Level 2): the Hub sends a VAPID-signed, RFC 8291-encrypted JSON
// payload; the browser decrypts it and delivers it here as `event.data`. We
// ALWAYS call showNotification (see PUSH_FALLBACK) so iOS never revokes the push
// permission for a silent push.
self.addEventListener('push', (event) => {
  event.waitUntil((async () => {
    let payload = null;
    try {
      payload = event.data ? event.data.json() : null;
    } catch (_e) {
      payload = null;
    }
    const plan = planForPushPayload(payload);
    try {
      await self.registration.showNotification(plan.title, {
        body: plan.body,
        tag: plan.tag,
        icon: NOTIFICATION_ICON,
        renotify: true,
        data: { route: plan.route, href: plan.href },
      });
    } catch (_e) {
      /* showNotification can reject if permission was revoked; nothing to do */
    }
  })());
});

// The push service can rotate a subscription's endpoint/keys without user
// action. Re-subscribe with the same VAPID key and notify any open page so it
// can POST the fresh subscription to the Hub. Best-effort: failures are silent.
self.addEventListener('pushsubscriptionchange', (event) => {
  event.waitUntil((async () => {
    try {
      let subscription = null;
      const oldSubscription = event.oldSubscription || null;
      const applicationServerKey = oldSubscription && oldSubscription.options
        ? oldSubscription.options.applicationServerKey
        : null;
      if (self.registration.pushManager && applicationServerKey) {
        subscription = await self.registration.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey,
        });
      }
      const all = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
      for (const client of all) {
        client.postMessage({
          type: 'heimdall-push-subscription-change',
          subscription: subscription ? subscription.toJSON() : null,
        });
      }
    } catch (_e) {
      /* best-effort resubscribe; the page also resubscribes on next load */
    }
  })());
});

// Notification click: focus an existing Heimdall window and tell it which route
// to open; if none is open, open a new window at the deep-link. The click data
// is attached by the page when it calls showNotification({ data: { route, href } }).
self.addEventListener('notificationclick', (event) => {
  const notification = event.notification;
  const data = (notification && notification.data) || {};
  const route = data.route || '';
  const href = data.href || '';
  try { notification.close(); } catch (_e) { /* ignore */ }

  event.waitUntil((async () => {
    const all = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const client of all) {
      // Reuse any open Heimdall window: focus it and hand off the route so the
      // in-page router navigates (SPA hash routing lives in the page, not the SW).
      try {
        await client.focus();
        client.postMessage({ type: 'heimdall-notification-click', route });
        return;
      } catch (_e) {
        /* try the next client */
      }
    }
    // No open window — open the deep-link (absolute href includes the hash route).
    if (href && self.clients.openWindow) {
      try { await self.clients.openWindow(href); } catch (_e) { /* ignore */ }
    }
  })());
});
