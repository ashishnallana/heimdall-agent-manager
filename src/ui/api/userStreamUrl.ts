import { apiAbsoluteUrl } from './apiBase';

// Browsers and the packaged Electron app (which loads the Hub UI origin) both
// authenticate stream upgrades with the Hub session cookie.
export async function authenticatedStreamUrl(path: string, _signal?: AbortSignal): Promise<string> {
  if (typeof window === 'undefined') return '';
  // Built from the API base so a preview build's socket follows the same path
  // prefix as its fetches, rather than silently attaching to whatever hub happens
  // to own the origin the preview is framed in.
  const url = new URL(apiAbsoluteUrl(path));
  url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
  return url.toString();
}
