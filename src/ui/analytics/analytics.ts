// Product analytics (PostHog) for the Ninjy app — web (web.ninjy.ai) and Electron.
// Taxonomy, privacy rules and env vars: docs/analytics.md.
//
// REQ-PH-3: everything here is a no-op unless the build was made with a non-empty
// VITE_POSTHOG_KEY. Self-hosted and dev builds have no key, so posthog-js is not even
// in their bundle (main.tsx guards its dynamic import on the statically replaced key)
// and nothing is ever sent. With a key, autocapture, pageviews and session recording are off:
// the only events are the typed ones below.
//
// REQ-PH-4/5: identify() takes the Hub user id and nothing else; milestone events
// are sent once per user (a local flag per user plus a `$set_once` person property),
// and their properties are limited to counts and type names. Never pass message,
// task, vault, file or prompt content, names, emails or free text.

import { desktopCapabilities } from '../bridge/desktopBridge';

export type AnalyticsPlatform = 'web' | 'electron';

/** Every event the app may send, with the only properties it may carry. */
export interface AnalyticsEventProps {
  app_opened: Record<string, never>;
  app_login: Record<string, never>;
  bridge_connected: { bridge_count: number; online_count: number };
  provider_configured: { provider: string; provider_count: number };
  first_chain_created: { chain_kind?: string };
  first_agent_started: { via: string; provider?: string };
}
export type AnalyticsEvent = keyof AnalyticsEventProps;

/** The subset of the posthog-js API this module uses (injectable for tests). */
export interface AnalyticsClient {
  init(key: string, config: Record<string, unknown>): unknown;
  register(props: Record<string, unknown>): void;
  capture(event: string, props?: Record<string, unknown>, options?: Record<string, unknown>): unknown;
  identify(distinctId: string): void;
  reset(): void;
}

export interface AnalyticsConfig {
  key: string;
  apiHost: string;
  uiHost: string;
  platform: AnalyticsPlatform;
  appVersion: string;
}

export interface AnalyticsEnv {
  VITE_POSTHOG_KEY?: string;
  VITE_POSTHOG_HOST?: string;
  VITE_APP_VERSION?: string;
}

interface StorageLike {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

export const WEB_DEFAULT_HOST = '/ingest';
export const ELECTRON_DEFAULT_HOST = 'https://web.ninjy.ai/ingest';
export const POSTHOG_UI_HOST = 'https://us.posthog.com';
// Deliberately NOT one of the app-owned prefixes (utils/clientPersistence.ts), so the
// once-per-user flags survive the client-state wipe on an account switch.
const ONCE_KEY_PREFIX = 'ninjy-analytics.once.';
const SESSION_OPENED_KEY = 'ninjy-analytics.opened';
// Property values are ids, counts and type names; anything longer is not one of those.
const MAX_PROP_LENGTH = 64;

/** `null` (analytics off) unless the build carries a PostHog project key. */
export function resolveAnalyticsConfig(env: AnalyticsEnv | undefined, platform: AnalyticsPlatform): AnalyticsConfig | null {
  const key = String(env?.VITE_POSTHOG_KEY ?? '').trim();
  if (!key) return null;
  const host = String(env?.VITE_POSTHOG_HOST ?? '').trim();
  return {
    key,
    apiHost: host || (platform === 'electron' ? ELECTRON_DEFAULT_HOST : WEB_DEFAULT_HOST),
    uiHost: POSTHOG_UI_HOST,
    platform,
    appVersion: String(env?.VITE_APP_VERSION ?? '').trim() || 'unknown',
  };
}

/** Electron when the desktop preload API is present (bridge/desktopBridge.ts owns that probe). */
export function detectPlatform(isDesktop: () => boolean = () => desktopCapabilities().desktop): AnalyticsPlatform {
  try { return isDesktop() ? 'electron' : 'web'; } catch { return 'web'; }
}

// URL properties posthog-js adds by itself. The app routes in the hash and some routes
// carry secrets in their query (e.g. `#/device/add?code=…`), so only origin + path leave.
const URL_PROPERTIES = ['$current_url', '$initial_current_url', '$session_entry_url', '$referrer', '$initial_referrer'];

export function stripUrlQueryAndHash(value: unknown): unknown {
  if (typeof value !== 'string' || !/^[a-z][a-z0-9+.-]*:/i.test(value)) return value;
  try {
    const url = new URL(value);
    return `${url.origin === 'null' ? `${url.protocol}//` : url.origin}${url.pathname}`;
  } catch {
    return value.split(/[?#]/, 1)[0];
  }
}

/** posthog-js `before_send`: redacts the automatic URL properties of every event. */
export function redactCapturedUrls<T extends Record<string, any> | null>(capture: T): T {
  if (!capture) return capture;
  for (const bag of [capture.properties, capture.$set, capture.$set_once]) {
    if (!bag || typeof bag !== 'object') continue;
    for (const name of URL_PROPERTIES) if (name in bag) bag[name] = stripUrlQueryAndHash(bag[name]);
  }
  return capture;
}

export function posthogInitOptions(config: AnalyticsConfig): Record<string, unknown> {
  return {
    api_host: config.apiHost,
    ui_host: config.uiHost,
    autocapture: false,
    capture_pageview: false,
    capture_pageleave: false,
    disable_session_recording: true,
    disable_surveys: true,
    disable_web_experiments: true,
    disable_product_tours: true,
    capture_exceptions: false,
    capture_dead_clicks: false,
    capture_heatmaps: false,
    rageclick: false,
    // Only the bundled library runs: no remote scripts pulled through the proxy.
    disable_external_dependency_loading: true,
    person_profiles: 'identified_only',
    before_send: redactCapturedUrls,
  };
}

/** Keeps only short primitive values, so a mistaken call cannot ship content. */
export function sanitizeProps(props: Record<string, unknown> | undefined): Record<string, string | number | boolean> {
  const out: Record<string, string | number | boolean> = {};
  for (const [name, value] of Object.entries(props || {})) {
    if (typeof value === 'number' && Number.isFinite(value)) out[name] = value;
    else if (typeof value === 'boolean') out[name] = value;
    else if (typeof value === 'string' && value && value.length <= MAX_PROP_LENGTH) out[name] = value;
  }
  return out;
}

function defaultStorage(kind: 'localStorage' | 'sessionStorage'): StorageLike | null {
  try { return typeof window === 'undefined' ? null : window[kind]; } catch { return null; }
}

function readFlag(storage: StorageLike | null, key: string): boolean {
  try { return storage?.getItem(key) === '1'; } catch { return false; }
}

function writeFlag(storage: StorageLike | null, key: string): void {
  try { storage?.setItem(key, '1'); } catch { /* storage unavailable: the person property still dedupes */ }
}

export interface AnalyticsOptions {
  env?: AnalyticsEnv;
  platform?: AnalyticsPlatform;
  /** Loads posthog-js. main.tsx passes it only in a keyed build, so Vite drops the chunk otherwise. */
  loadClient?: () => Promise<AnalyticsClient>;
  localStorage?: StorageLike | null;
  sessionStorage?: StorageLike | null;
  now?: () => Date;
}

/** One analytics session. The app uses the module-level instance below. */
export class Analytics {
  private config: AnalyticsConfig | null = null;
  private client: AnalyticsClient | null = null;
  private pending: Array<(client: AnalyticsClient) => void> = [];
  private userId = '';
  private sent = new Set<string>();
  private local: StorageLike | null = null;
  private session: StorageLike | null = null;
  private now: () => Date = () => new Date();

  get enabled(): boolean { return this.config !== null; }
  get currentUserId(): string { return this.userId; }

  /** Starts analytics when the build has a key; returns whether it did. */
  init(options: AnalyticsOptions = {}): boolean {
    if (this.config) return true;
    const config = resolveAnalyticsConfig(options.env, options.platform ?? detectPlatform());
    if (!config || !options.loadClient) return false;
    this.config = config;
    this.local = options.localStorage !== undefined ? options.localStorage : defaultStorage('localStorage');
    this.session = options.sessionStorage !== undefined ? options.sessionStorage : defaultStorage('sessionStorage');
    if (options.now) this.now = options.now;
    void options.loadClient().then((client) => {
      client.init(config.key, posthogInitOptions(config));
      client.register({ platform: config.platform, app_version: config.appVersion });
      this.client = client;
      const queued = this.pending;
      this.pending = [];
      for (const call of queued) call(client);
    }).catch(() => {
      // Blocked or failed to load (ad blocker, offline): analytics is best-effort.
      this.pending = [];
    });
    // REQ-PH-3: no router, so one `app_opened` per browser session instead of pageviews.
    if (!readFlag(this.session, SESSION_OPENED_KEY)) {
      writeFlag(this.session, SESSION_OPENED_KEY);
      this.track('app_opened', {});
    }
    return true;
  }

  private withClient(call: (client: AnalyticsClient) => void): void {
    if (!this.config) return;
    if (this.client) call(this.client);
    else this.pending.push(call);
  }

  track<E extends AnalyticsEvent>(event: E, props: AnalyticsEventProps[E], options?: Record<string, unknown>): void {
    const clean = sanitizeProps(props as Record<string, unknown>);
    this.withClient((client) => { client.capture(event, clean, options); });
  }

  /**
   * Sends a milestone at most once per signed-in user. Without a user the event is
   * dropped: every milestone happens after sign-in, and an anonymous one could not
   * be attributed to the funnel anyway.
   */
  trackOnce<E extends AnalyticsEvent>(event: E, props: AnalyticsEventProps[E]): boolean {
    if (!this.config || !this.userId) return false;
    const key = `${ONCE_KEY_PREFIX}${this.userId}.${event}`;
    if (this.sent.has(key) || readFlag(this.local, key)) {
      this.sent.add(key);
      return false;
    }
    this.sent.add(key);
    writeFlag(this.local, key);
    this.track(event, props, { $set_once: { [`${event}_at`]: this.now().toISOString() } });
    return true;
  }

  /** Whether this user's milestone was already sent (cheap; checked per dispatch). */
  hasSentOnce(event: AnalyticsEvent): boolean {
    return Boolean(this.userId) && this.sent.has(`${ONCE_KEY_PREFIX}${this.userId}.${event}`);
  }

  /** REQ-PH-4: the stable Hub user id only; never email, name or other traits. */
  identify(userId: string): void {
    const id = String(userId || '').trim();
    if (!this.config || !id || id === this.userId) return;
    // An account switch must not merge two people into one.
    if (this.userId) this.reset();
    this.userId = id;
    this.withClient((client) => { client.identify(id); });
    this.trackOnce('app_login', {});
  }

  /** On sign-out or account switch: drop the identity so later events are anonymous. */
  reset(): void {
    if (!this.config) return;
    this.userId = '';
    this.withClient((client) => { client.reset(); });
  }
}

export const analytics = new Analytics();
