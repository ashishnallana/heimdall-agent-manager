// Guards shared by the bridge e2e scripts for runs that use the REAL home (CI service
// runs, and every macOS run: see the keychain note in bridge_lifecycle_e2e.mjs).
import fs from 'node:fs';
import path from 'node:path';

// Nothing of the caller's own bridge may reach the binaries under test. A shell the
// bridge spawned exports HEIMDALL_BRIDGE_SERVICE_NAME, and `ham-bridge enroll` stops and
// restarts that service as its own when the profile has none registered yet
// (bridge_enroll_service_for). Scrubbed from process.env itself because children
// (and bridgeManager) inherit it. HEIMDALL_E2E_* configure the test and are kept.
export function scrubHeimdallEnv() {
  for (const k of Object.keys(process.env)) {
    const u = k.toUpperCase();
    if (u.startsWith('HEIMDALL_') && !u.startsWith('HEIMDALL_E2E_')) delete process.env[k];
  }
}

// enroll's last fallback is the pre-profile fixed-name service; with the real home it
// would stop a real install. Refuse rather than touch it. Windows has no such unit.
export function refuseLegacyInstall(home, platform = process.platform) {
  const unit = platform === 'win32' ? ''
    : platform === 'darwin' ? path.join(home, 'Library', 'LaunchAgents', 'works.earendil.heimdall-bridge.plist')
    : path.join(home, '.config', 'systemd', 'user', 'heimdall-bridge.service');
  if (unit && fs.existsSync(unit)) throw new Error(`e2e refuses to run with the real home: ${unit} is a real bridge install that \`ham-bridge enroll\` would stop`);
}
