// REQ-ENR-4 on Linux: AppImage and deb cannot run a per-user setup at install
// time (a deb's maintainer scripts run as root, an AppImage has no installer),
// so the packaged Linux app asks App / Bridge / both on its first launch.
// Windows (NSIS page) and macOS (.pkg choices) ask in their installers instead.
//
// "Bridge" runs the same ham-bridge setup as Settings > Bridges. "Bridge only"
// never opens the main window and quits afterwards; ham-bridge setup copies
// what the Bridge needs into its own profile, so the app can then be removed.
// The answer is remembered, so a later launch simply opens the app.
const fs = require('fs');
const path = require('path');

type InstallChoice = 'both' | 'app' | 'bridge';
type Deps = {
  markerPath: string;
  showMessageBox: (options: any) => Promise<{ response: number }>;
  setupBridge: () => Promise<{ ok: boolean; error?: string }>;
  packageKind: 'appimage' | 'deb' | 'other';
};

const CHOICES: InstallChoice[] = ['both', 'app', 'bridge'];

function shouldAsk(platform: string, isPackaged: boolean, markerPath: string): boolean {
  if (platform !== 'linux' || !isPackaged) return false;
  try { return !fs.existsSync(markerPath); } catch (_err) { return true; }
}

function packageKind(env: Record<string, string | undefined> = process.env): Deps['packageKind'] {
  if (env.APPIMAGE) return 'appimage';
  // electron-builder's deb installs under /opt/<productName>.
  return process.execPath.startsWith('/opt/') ? 'deb' : 'other';
}

function removalHint(kind: Deps['packageKind']): string {
  if (kind === 'appimage') return 'You can delete the Heimdall AppImage; the Bridge does not need it.';
  if (kind === 'deb') return 'You can remove the app with `sudo apt remove heimdall`; the Bridge does not need it.';
  return 'You can remove the Heimdall app; the Bridge does not need it.';
}

function remember(markerPath: string, choice: InstallChoice) {
  fs.mkdirSync(path.dirname(markerPath), { recursive: true });
  fs.writeFileSync(markerPath, `${JSON.stringify({ choice, at: new Date().toISOString() })}\n`, { mode: 0o600 });
}

// Asks once and acts on the answer. Resolves whether the main window should open.
async function runFirstLaunch(deps: Deps): Promise<{ openWindow: boolean; choice: InstallChoice }> {
  const { response } = await deps.showMessageBox({
    type: 'question',
    title: 'Set up Heimdall',
    message: 'What should Heimdall install on this computer?',
    detail: 'The App is the Heimdall desktop window. The Bridge connects this computer to your Heimdall Hub so agents can run here; setting it up opens your browser to approve this computer.',
    buttons: ['App and Bridge', 'App only', 'Bridge only'],
    defaultId: 0,
    cancelId: 1,
    noLink: true,
  });
  const choice = CHOICES[response] || 'app';
  remember(deps.markerPath, choice);
  if (choice === 'app') return { openWindow: true, choice };
  if (choice === 'both') {
    // The window opens at once; the result is reported when setup finishes.
    void deps.setupBridge().then((result) => {
      if (!result.ok) void deps.showMessageBox({ type: 'warning', message: 'Heimdall Bridge setup failed.', detail: `${result.error || 'Unknown error.'}\nFinish it from Settings > Bridges.`, buttons: ['OK'] });
    });
    return { openWindow: true, choice };
  }
  const result = await deps.setupBridge();
  await deps.showMessageBox(result.ok
    ? { type: 'info', message: 'The Heimdall Bridge is installed and running.', detail: `Manage it from its tray icon. ${removalHint(deps.packageKind)}`, buttons: ['OK'] }
    : { type: 'error', message: 'Heimdall Bridge setup failed.', detail: `${result.error || 'Unknown error.'}\nOpen Heimdall again to retry from Settings > Bridges.`, buttons: ['OK'] });
  return { openWindow: false, choice };
}

module.exports = { packageKind, removalHint, runFirstLaunch, shouldAsk };
