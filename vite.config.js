import { fileURLToPath, URL } from 'node:url';
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// UI-19 / HBR-5 / HBR-6: the rewrite `/api/v1` path must obtain trusted-proxy
// identity exclusively from `ham-dev-proxy` (the reverse proxy inside the Hub's
// --trusted-proxy-cidr), never from the client. In dev the renderer runs at the
// Vite dev-server origin (127.0.0.1:5173), so relative `/api/v1` requests
// resolve to Vite itself. Forward them to `ham-dev-proxy`, which injects
// `X-authentik-*` server-side from the `ham_dev_user` cookie set by
// `/_dev/login?user=<name>`. No client-side header injection.
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
  server: {
    // Route the trusted-proxy auth surface through ham-dev-proxy in dev.
    proxy: {
      // Dev login/logout cookie flow (sets ham_dev_user). Kept on the renderer
      // origin so the cookie is same-origin with the SPA and is sent on
      // subsequent /api/v1 requests.
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
