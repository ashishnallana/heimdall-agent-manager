// PostHog runtime config: the project key comes from a file the deployment serves, not from
// the build. web.ninjy.ai renders /posthog-config.json from sops
// (nix-homelab-config secrets/trusted/ai/posthog.yaml:posthog_project_key); docs/analytics.md.
//
// Shape: {"key": "phc_…", "host": "/ingest"} — `host` optional. A 404, network error,
// non-JSON answer (e.g. an SPA index.html fallback) or empty key means analytics off, and
// nothing is thrown or logged.

import type { AnalyticsPlatform } from './analytics';

export const RUNTIME_CONFIG_PATH = '/posthog-config.json';
/** Electron always reads the hosted deployment's config, whatever UI origin it loads. */
export const ELECTRON_RUNTIME_CONFIG_URL = 'https://web.ninjy.ai/posthog-config.json';

export interface PosthogRuntimeConfig {
  key: string;
  /** Absolute ingest URL (a relative host is resolved against the config's origin), or '' for the platform default. */
  host: string;
}

type FetchLike = (url: string, init?: Record<string, unknown>) => Promise<{ ok: boolean; text(): Promise<string> }>;

export interface RuntimeConfigOptions {
  platform: AnalyticsPlatform;
  fetch?: FetchLike;
  /** Page origin the web config is read from; defaults to window.location.origin. */
  origin?: string;
}

export function runtimeConfigUrl(platform: AnalyticsPlatform, origin?: string): string | null {
  if (platform === 'electron') return ELECTRON_RUNTIME_CONFIG_URL;
  try {
    const base = origin ?? (typeof window === 'undefined' ? '' : window.location.origin);
    return /^https?:\/\//i.test(base) ? new URL(RUNTIME_CONFIG_PATH, base).href : null;
  } catch {
    return null;
  }
}

/** `null` unless `body` is a config object with a non-empty string key. */
export function parseRuntimeConfig(body: string, configUrl: string): PosthogRuntimeConfig | null {
  let raw: unknown;
  try { raw = JSON.parse(body); } catch { return null; }
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const { key, host } = raw as Record<string, unknown>;
  const cleanKey = typeof key === 'string' ? key.trim() : '';
  if (!cleanKey) return null;
  return { key: cleanKey, host: resolveHost(host, configUrl) };
}

function resolveHost(host: unknown, configUrl: string): string {
  if (typeof host !== 'string' || !host.trim()) return '';
  try {
    const url = new URL(host.trim(), configUrl);
    if (url.protocol !== 'https:' && url.protocol !== 'http:') return '';
    return url.href.replace(/\/+$/, '');
  } catch {
    return '';
  }
}

export async function loadRuntimeConfig(options: RuntimeConfigOptions): Promise<PosthogRuntimeConfig | null> {
  const url = runtimeConfigUrl(options.platform, options.origin);
  const fetchImpl = options.fetch ?? (typeof fetch === 'function' ? (fetch as unknown as FetchLike) : null);
  if (!url || !fetchImpl) return null;
  try {
    // No cookies: the file is public, and Electron's request is cross-origin when the
    // window is pointed at another UI origin (web.ninjy.ai answers with ACAO *).
    const response = await fetchImpl(url, { credentials: 'omit', cache: 'no-store' });
    if (!response.ok) return null;
    return parseRuntimeConfig(await response.text(), url);
  } catch {
    return null;
  }
}
