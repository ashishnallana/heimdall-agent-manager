import type { ReactNode } from 'react';

/**
 * REQ-OIDC-DESKTOP-1
 *
 * Kept as a compatibility boundary for the root tree, but intentionally does
 * not install a fetch shim or gate on a stored bearer token. The packaged
 * Electron window loads the Hub UI at its HTTPS origin and Chromium carries the
 * Hub's HttpOnly OIDC session cookie exactly as it does in a browser.
 *
 * The previous device-authorization/HUT implementation was removed when Hub
 * user tokens were retired. Bridge device authorization remains a separate,
 * browser-approved machine enrollment and is exposed by `bridgeManager`.
 */
export function installElectronApiFetchBridge(): void {
  // No-op by design: rewriting requests or adding Authorization would bypass
  // the OIDC-only browser-session contract.
}

export default function ElectronDeviceAuthGate({ children }: { children: ReactNode }) {
  return <>{children}</>;
}
