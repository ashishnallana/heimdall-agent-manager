import { fileURLToPath, URL } from 'node:url';
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Users authenticate only with OIDC. In dev the renderer runs at the Vite
// dev-server origin (the hub's --ui-origin), so relative `/api/v1` requests —
// including the sign-in flow (/api/v1/auth/login -> mock provider ->
// /api/v1/auth/callback) — resolve to Vite and are forwarded to `ham-dev-proxy`,
// which passes the hub session cookie through unchanged and adds the dev user
// selected with `/_dev/login?user=<name>` as the provider login_hint. Locally the
// provider is tools/mock-oidc (see tools/mock-oidc/README.md). Nothing here
// fakes identity: the dev UI talks to a hub signed into via that mock.
//
// Override the upstream proxy with HEIMDALL_DEV_PROXY_URL if your
// ham-dev-proxy listens elsewhere.
const DEV_PROXY_URL = process.env.HEIMDALL_DEV_PROXY_URL || 'http://127.0.0.1:8080';
const LONG_PROXY_TIMEOUT_MS = 16 * 60 * 1000;

export default defineConfig({
  plugins: [react()],
  base: './',
  resolve: {
    alias: [
      {
        // Avoid an esbuild 0.21 miscompile of xterm 6.0.0's ESM requestMode enum.
        find: /^@xterm\/xterm$/,
        replacement: fileURLToPath(new URL('./node_modules/@xterm/xterm/lib/xterm.js', import.meta.url)),
      },
      {
        // `@ui/*` -> the shared component library (src/ui/components/ui/*).
        // Mirrors the tsconfig.renderer.json path alias so imports resolve at
        // typecheck, dev, and build.
        find: '@ui',
        replacement: fileURLToPath(new URL('./src/ui/components/ui', import.meta.url)),
      },
    ],
  },
  build: {
    rollupOptions: {
      output: {
        // React and Redux change far less often than the app, so a separate chunk
        // stays cached in the browser across most releases.
        manualChunks(id) {
          if (/[\\/]node_modules[\\/](react|react-dom|scheduler|react-redux|@reduxjs[\\/]toolkit|redux|immer|reselect|use-sync-external-store)[\\/]/.test(id)) {
            return 'vendor-react';
          }
        },
      },
    },
  },
  server: {
    // Route the Hub API (and its OIDC sign-in routes) through ham-dev-proxy in dev.
    proxy: {
      // Dev-user selection (sets ham_dev_user, used as the sign-in login_hint).
      // Kept on the renderer origin so the cookie reaches the proxy on
      // /api/v1/auth/login.
      '/_dev/login': { target: DEV_PROXY_URL, changeOrigin: true },
      '/_dev/logout': { target: DEV_PROXY_URL, changeOrigin: true },
      '/api/v1': {
        target: DEV_PROXY_URL,
        changeOrigin: true,
        cookieDomainRewrite: '',
        ws: true,
        timeout: LONG_PROXY_TIMEOUT_MS,
        proxyTimeout: LONG_PROXY_TIMEOUT_MS,
        bypass: (req) => {
          if (req.url && req.url.startsWith('/api/v1/preview')) {
            return req.url;
          }
        },
      },
    },
  },
});
