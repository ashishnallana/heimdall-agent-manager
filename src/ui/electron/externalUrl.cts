// REQ-EXT-URL-1: the renderer is the remote Hub UI, so any URL it hands to
// shell.openExternal must be a web or mail link. file:, smb:, javascript: and
// custom-scheme URLs can launch local applications on macOS.
const EXTERNAL_PROTOCOLS = new Set(['https:', 'mailto:']);

// allowedExternalUrl returns the normalized URL when it may be opened in the
// system browser or mail client, or '' when it must be refused.
function allowedExternalUrl(value: unknown): string {
  try {
    const url = new URL(String(value || '').trim());
    if (!EXTERNAL_PROTOCOLS.has(url.protocol)) return '';
    if (url.protocol === 'https:' && (!url.hostname || url.username || url.password)) return '';
    return url.href;
  } catch (_err) {
    return '';
  }
}

// allowedPairingUrl accepts a Bridge enrollment approval URL only on one of the
// configured Hub/UI origins. Those origins may be http: in local development.
function allowedPairingUrl(value: unknown, trustedOrigins: string[]): string {
  try {
    const url = new URL(String(value || '').trim());
    const origins = new Set(trustedOrigins.map((origin) => { try { return new URL(origin).origin; } catch (_err) { return ''; } }).filter(Boolean));
    if (!origins.has(url.origin) || url.username || url.password) return '';
    return url.href;
  } catch (_err) {
    return '';
  }
}

module.exports = { allowedExternalUrl, allowedPairingUrl };
