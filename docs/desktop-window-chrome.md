# Desktop window chrome (integrated macOS and Windows headers)

On macOS the desktop app hides the gray native title bar and keeps the native
traffic lights, centered in the UI's 48px top chrome row (REQ-MAC-CHROME-1).
The window frame stays, so resize edges, the shadow, the Window menu and
Cmd-W/Cmd-M behave as before. The OIDC sign-in window keeps its native title
bar because it shows identity-provider pages that cannot declare drag regions.

On Windows the main window also hides the native title bar. A 48px native
Window Controls Overlay retains minimize/maximize/close, Windows Snap and
native accessibility. The Edit/View/Window menu is auto-hidden; Alt and menu
accelerators remain available. The OIDC popup keeps its native title bar/menu.

Linux, the browser and the PWA retain their existing layout.

| Piece | Where | Ships with |
| --- | --- | --- |
| `titleBarStyle: 'hidden'`, `trafficLightPosition {16,17}`, `--heimdall-window-chrome=mac-hidden` argv flag, fullscreen state events | `src/ui/electron/windowChrome.cts`, `main.cts` `createWindow`, `preload.cts` `odinApi.windowChrome` | Desktop release |
| 78px traffic-light inset, `html[data-window-chrome]`, drag/no-drag CSS, gate-screen drag strip | `shellChrome.ts`, `hooks/useWindowChrome.ts`, `AppShell.tsx`, header components, `styles.css` | Hub UI release |

The preload state is display-only: a style string, the cached fullscreen flag
and a subscription. It adds no renderer-to-main IPC, and `webPreferences`
security settings (`contextIsolation`, `nodeIntegration: false`, `sandbox`) are
unchanged.

## Drag regions

Under a desktop-reported `mac-hidden` or `win-overlay` style only:

- `.window-drag` (the top-left cluster, sidebar header spacer, non-workspace top
  bar, workspace top-right cluster and conversation headers) moves the window.
- Controls inside it, HTML5-draggable elements (pane grips and the picker
  header, which stays draggable for split/swap), dialogs, menus, listboxes and
  tooltips are `no-drag`. Chromium drag regions otherwise swallow their clicks.
- The auth, device-vault and standalone device screens have no chrome row. A
  fixed 40px strip at the top is their drag surface, and the standalone device
  pages are padded below it. The strip is hidden once the full app shell mounts.

In fullscreen the control insets drop to 0.

On Windows, the read-only Window Controls Overlay geometry determines the
right inset in CSS pixels. Geometry changes and viewport resize update it.
Until valid geometry arrives, a conservative 160px reservation protects the
caption buttons. The fixed workspace cluster moves left, and pane/dock headers
reserve its width plus that inset. The rest of the content remains full width.
Auth/device gate screens reserve a 48px top strip on Windows (40px on macOS).
No new renderer-to-main IPC is used for overlay geometry.

## Diagnostic kill switch

`HEIMDALL_NATIVE_TITLE_BAR=1` restores the native title bar on either platform: no hidden style, no
argv flag, so the UI renders exactly as on other platforms. Use it to reproduce
the separate web-contents/window misalignment (targeted by the Electron 44 runtime
upgrade; resolution still requires a real macOS check) with and without the hidden title bar. A clean hidden title bar does
not prove that misalignment is fixed.

## Rollout order

The packaged app loads the Hub-served UI, so the two halves deploy separately:

| Desktop | Hub UI | Result |
| --- | --- | --- |
| old | new | No argv flag, so the UI is unchanged. Safe. |
| new | old | Traffic lights cover the sidebar toggle and nothing drags. **Not acceptable.** |

Deploy the Hub UI release first, verify it is live, then publish the desktop
release.

The same order applies to a locally built Electron shell that loads a hosted
UI. Rebuilding Electron alone does not update the Hub-served renderer. In true
Vite development mode, rebuild/restart the Electron process and reload its local
UI together.

## Validation

Automated checks run on Linux: `npm run typecheck`, `npm run build:electron`,
`npm run build`, and `tests/ui_window_chrome_test.ts`,
`tests/ui_sidebar_layout_test.ts`, `tests/ui_bridge_status_control_test.ts`.
They cover options, preload state, inset math, CSS gating and markup, not native
rendering.

Real macOS validation on a packaged build is still required: traffic-light
placement, dragging every header and gate screen, clicking every header
control, popovers and modals over the header, pane split-drag, resize to
920x620, fullscreen enter/exit and reload while fullscreen, zoom, Split View,
Stage Manager, external displays, tray hide/reopen, VoiceOver, light/dark, the
OIDC window, and the kill switch. In multi-pane layouts every conversation
header is a drag region, including pane headers below the top row; confirm
that is acceptable.

Windows local-run validation is also required: caption buttons, drag and
header double-click, Alt menu and shortcuts, tray hide/reopen, minimize and
maximize/restore, Windows 11 maximize-hover Snap Layouts and Win+arrow,
100/125/150/200% display scaling and browser zoom, mixed-DPI monitors,
fullscreen enter/exit and reload, minimum window size, light/dark/high-contrast
OS and app themes, pane grips/popovers/aux dock, auth gates and the native login
popup. Native system colors are retained for caption contrast. Linux tests of
the geometry math and hook lifecycle do not prove Windows rendering or Snap.
