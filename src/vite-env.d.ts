/// <reference types="vite/client" />

interface ImportMetaEnv {
  /** Dev override for the PostHog key; release builds read /posthog-config.json at runtime (docs/analytics.md). */
  readonly VITE_POSTHOG_KEY?: string;
  /** Ingest host used with VITE_POSTHOG_KEY; defaults to /ingest (web) or https://web.ninjy.ai/ingest (Electron). */
  readonly VITE_POSTHOG_HOST?: string;
  /** App version sent as the `app_version` super-property; defaults to package.json. */
  readonly VITE_APP_VERSION?: string;
}

interface OdinApiRequestOptions {
  url: string;
  method?: string;
  body?: unknown;
  headers?: Record<string, string>;
}

interface OdinPickDirectoryResult {
  ok: boolean;
  canceled: boolean;
  path: string;
}

interface Window {
  odinApi?: {
    request: (options: OdinApiRequestOptions) => Promise<unknown>;
    pickDirectory?: () => Promise<OdinPickDirectoryResult>;
  };
}
