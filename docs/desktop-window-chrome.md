# Desktop window chrome (macOS integrated title bar)

On macOS the desktop app hides the gray native title bar and keeps the native
traffic lights, centered in the UI's 48px top chrome row (REQ-MAC-CHROME-1).
The window frame stays, so resize edges, the shadow, the Window menu and
Cmd-W/Cmd-M behave as before. The OIDC sign-in window keeps its native title
bar because it shows identity-provider pages that cannot declare drag regions.

Windows, Linux, the browser and the PWA are unchanged.

| Piece | Where | Ships with |
| --- | --- | --- |
| `titleBarStyle: 'hidden'`, `trafficLightPosition {16,17}`, `--heimdall-window-chrome=mac-hidden` argv flag, fullscreen state events | `src/ui/electron/windowChrome.cts`, `main.cts` `createWindow`, `preload.cts` `odinApi.windowChrome` | Desktop release |
| 78px traffic-light inset, `html[data-window-chrome]`, drag/no-drag CSS, gate-screen drag strip | `shellChrome.ts`, `hooks/useWindowChrome.ts`, `AppShell.tsx`, header components, `styles.css` | Hub UI release |

The preload state is display-only: a style string, the cached fullscreen flag
and a subscription. It adds no renderer-to-main IPC, and `webPreferences`
security settings (`contextIsolation`, `nodeIntegration: false`, `sandbox`) are
unchanged.

## Drag regions

Under `html[data-window-chrome="mac-hidden"]` only:

- `.window-drag` (the top-left cluster, sidebar header spacer, non-workspace top
  bar, workspace top-right cluster and conversation headers) moves the window.
- Controls inside it, HTML5-draggable elements (pane grips and the picker
  header, which stays draggable for split/swap), dialogs, menus, listboxes and
  tooltips are `no-drag`. Chromium drag regions otherwise swallow their clicks.
- The auth, device-vault and standalone device screens have no chrome row. A
  fixed 40px strip at the top is their drag surface, and the standalone device
  pages are padded below it. The strip is hidden once the full app shell mounts.

In fullscreen macOS hides the traffic lights, so the inset drops to 0.

## Diagnostic kill switch

`HEIMDALL_NATIVE_TITLE_BAR=1` restores the native title bar: no hidden style, no
argv flag, so the UI renders exactly as on other platforms. Use it to reproduce
the separate web-contents/window misalignment (fixed by the Electron 44 runtime
upgrade) with and without the hidden title bar. A clean hidden title bar does
not prove that misalignment is fixed.

## Rollout order

The packaged app loads the Hub-served UI, so the two halves deploy separately:

| Desktop | Hub UI | Result |
| --- | --- | --- |
| old | new | No argv flag, so the UI is unchanged. Safe. |
| new | old | Traffic lights cover the sidebar toggle and nothing drags. **Not acceptable.** |

Deploy the Hub UI release first, verify it is live, then publish the desktop
release.

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
