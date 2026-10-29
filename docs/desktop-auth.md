# Electron hosted-UI login

A locally built Electron shell can load a hosted UI. It is not a Vite development
session merely because `app.isPackaged` is false. The shell resolves one effective
UI URL for its main window, navigation policy, login return, notifications and
session refresh.

For the Brolabs production API (`https://hub.brolabs.ai`), the UI is now
`https://web.ninjy.ai`. The exact legacy UI setting
`https://heimdall.brolabs.ai` is recognized and changed to the canonical UI before
the main window loads. A startup notice reports this transition. Packaged installs
default to the canonical UI; locally built shells with an explicitly configured
production API do too. Other Hub/UI deployments retain their explicit URLs.

For a local shell loading production, use:

```powershell
$env:HEIMDALL_HUB_API_URL = "https://hub.brolabs.ai"
$env:HEIMDALL_UI_URL = "https://web.ninjy.ai"
Remove-Item Env:VITE_DEV_SERVER_URL -ErrorAction SilentlyContinue
npm ci
npm run build:electron
npx electron .
```

Use the same profile as before. This does not delete or move old-origin cookies
or IndexedDB/vault identities. The canonical origin may need ordinary device
approval/recovery before existing conversations can decrypt. If a login popup
already created an approved identity at the canonical origin, the main window
reuses that origin's identity in the shared Electron profile. No cookies or
private keys are copied between origins. Legacy hosting and the Hub API identity
are unchanged.

In true Vite mode, set `VITE_DEV_SERVER_URL` to the actual local frontend URL.
It is also the main window's trusted UI URL. Leave `HEIMDALL_UI_URL` unset or set
it to the same URL; conflicting values fail with an explicit configuration error.
A local Vite frontend needs a Hub/provider callback configured for that local
origin; pointing it at a production callback does not transfer host-only cookies
back to localhost.

The preload-free login window closes only after a navigation commits to the
expected UI, excluding API/callback pages. It then reloads/focuses its original
owner on that same-origin return route, preserving `auth_error` if login failed.
Repeated sign-in focuses the existing popup. Closing a pending popup cancels the
handoff; a destroyed owner never causes another window to be navigated.
Navigation-redirect events alone cannot finish login before the callback response
has committed its HttpOnly cookie. The renderer never receives session secrets.

Rebuild/restart Electron to apply these shell changes. Hosted UI title-bar
support must still be deployed before a shell with integrated window controls;
see [desktop window chrome](desktop-window-chrome.md).
