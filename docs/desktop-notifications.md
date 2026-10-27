# Desktop notifications

In Settings → Notifications, enable **desktop notifications** and choose Chat
messages and/or Needs attention. **Send test notification** sends a real native
notification and reports the result in an in-app toast.

The Electron shell uses the existing chat/attention event mapper and vault
privacy rules. A focused conversation does not notify while you are viewing it;
other conversations can notify even while the window is focused. A notification
click restores the app and opens its conversation or chain. Repeated events for
the same thread replace the active native notification.

| Platform | System setup |
| --- | --- |
| Linux | Run in a desktop session with a notification service implementing `org.freedesktop.Notifications`. |
| macOS | Enable Heimdall in System Settings → Notifications. Use the packaged application for application identity and signing. |
| Windows | Enable Heimdall in Settings → System → Notifications. Install the packaged application so its Start menu shortcut and `works.earendil.heimdall` app identity match. |

System notification preferences and Do Not Disturb/Focus modes can suppress
banners. Electron's support flag indicates API availability, not that OS policy
allows banners. A delivery failure is reported by the test button; it does not
silently fall back to the browser API.

The app must be running with its UI loaded to receive chat/attention events.
Hiding the loaded window in the macOS/Windows tray retains that UI; starting only
the tray at login does not load it. Fully quitting the app stops delivery.

## Release and verification

The packaged shell loads the hosted Hub UI. Deploy the renderer changes together
with an updated desktop shell containing the notifications preload API. Older
shells report native notifications as unavailable in the updated UI.

On each operating system, use the installed app to verify:

1. Enable notifications, send a test, and confirm its native banner/center entry.
2. Background or minimize the app; receive a chat and an attention event. On
   macOS/Windows also check with the loaded window hidden in the tray.
3. Click a notification and confirm window restoration and correct routing.
4. Confirm the current focused conversation is suppressed; another conversation
   still notifies. Disable a category and the master toggle and confirm opt-outs.
5. Lock the vault and confirm encrypted content is replaced with a locked
   placeholder. Unlock it and confirm display content is decrypted.
6. Deny system notifications and confirm the app remains usable and the test
   does not claim guaranteed banner visibility.

Automated coverage lives in `tests/ui_electron_notifications_test.ts`, alongside
the existing notification mapper, service, settings, funnel, and vault tests.
Mocked native tests verify IPC and lifecycle behavior; they do not establish
that actual OS banners display on macOS or Windows.

Electron API references: [native notification API](https://www.electronjs.org/docs/latest/api/notification)
and [platform notification requirements](https://www.electronjs.org/docs/latest/tutorial/notifications).
