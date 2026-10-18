// REQ-RAWKEY-A8: shared bootstrap for endpoint-layer vault tests.
//
// WHY: the P0 that started this chain (artifact names and chain titles written to the
// wire in PLAINTEXT) survived in four places because the endpoint layer had no runtime
// coverage. The suites that claimed to cover it only exercised the encrypt*Fields
// HELPERS, which the endpoints never call -- or worse, RE-IMPLEMENTED the endpoint's
// queryFn logic inside the test body and asserted on their own copy, which stays green
// no matter how broken the real endpoint is.
//
// This module makes the honest thing cheap: a REAL store, the REAL injected endpoints,
// a stubbed global fetch, and assertions on the ACTUAL WIRE PAYLOAD.
//
// Importing this module registers a module resolve hook, so it MUST be imported before
// any module that reaches an endpoint file. Prefer `await import()` for those.

import fs from 'node:fs';
import path from 'node:path';
import { createRequire, registerHooks } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';

export const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

const _req = createRequire(REPO_ROOT + '/package.json');
let _transformSync: ((code: string, opts: Record<string, unknown>) => { code: string }) | null = null;
function getTransformSync() {
  if (!_transformSync) {
    _transformSync = (_req('esbuild') as { transformSync: (code: string, opts: Record<string, unknown>) => { code: string } }).transformSync;
  }
  return _transformSync;
}

// Endpoint modules use extensionless relative imports (`from '../cookieFetch'`) and `@ui` aliases
// that only vite resolves at build time. Retry those against the real file extensions and
// transpile `.ts`/`.tsx` under `src/` via esbuild so plain `node --test` can load them.
registerHooks({
  load(url, context, nextLoad) {
    if (url.startsWith('file:') && url.endsWith('.css')) {
      return { format: 'module', source: 'export default {};', shortCircuit: true };
    }
    if (url.startsWith('file:') && (url.endsWith('.tsx') || (url.endsWith('.ts') && url.includes('/src/')))) {
      const source = fs.readFileSync(fileURLToPath(url), 'utf8');
      const result = getTransformSync()(source, {
        loader: url.endsWith('.tsx') ? 'tsx' : 'ts',
        format: 'esm',
        target: 'esnext',
        jsx: 'automatic',
      });
      return { format: 'module', source: result.code, shortCircuit: true };
    }
    return nextLoad(url, context);
  },
  resolve(specifier, context, nextResolve) {
    // Tests import `${REPO_ROOT}/...`; on Windows that is `C:\...`, which the ESM
    // loader reads as a URL with scheme `c:`. Hand it on as a file:// URL instead.
    if (/^[A-Za-z]:[\\/]/.test(specifier)) {
      return nextResolve(pathToFileURL(specifier).href, context);
    }
    if (specifier === '@ui' || specifier.startsWith('@ui/')) {
      const rel = specifier === '@ui' ? '' : specifier.slice(4);
      const targetBase = path.join(REPO_ROOT, 'src', 'ui', 'components', 'ui', rel);
      for (const cand of [
        targetBase,
        targetBase + '.ts',
        targetBase + '.tsx',
        path.join(targetBase, 'index.ts'),
        path.join(targetBase, 'index.tsx'),
      ]) {
        if (fs.existsSync(cand) && fs.statSync(cand).isFile()) {
          return { url: pathToFileURL(cand).href, shortCircuit: true };
        }
      }
    }
    try {
      return nextResolve(specifier, context);
    } catch (err) {
      if (!specifier.startsWith('.') && !specifier.startsWith('/')) throw err;
      const base = new URL(specifier, context.parentURL);
      for (const cand of [base.href + '.ts', base.href + '.tsx',
                          base.href + '/index.ts', base.href + '/index.tsx']) {
        if (fs.existsSync(fileURLToPath(cand))) return { url: cand, shortCircuit: true };
      }
      throw err;
    }
  },
});

// daemonApi's requestJson uses window.setTimeout/clearTimeout and some endpoints read
// window.location.protocol. Shim ONLY those: a bare `window = globalThis` makes
// browser-only branches fire and then throw.
export function installWindowShim(): void {
  (globalThis as any).window = {
    setTimeout: (...a: any[]) => (setTimeout as any)(...a),
    clearTimeout: (h: any) => clearTimeout(h),
    location: { protocol: 'file:', href: 'file:///test' },
  };
}

export type CapturedRequest = { url: string; method: string; body: any };

export type FetchCapture = {
  /** Every request the endpoints made, in order. */
  requests: CapturedRequest[];
  /** Body the stub answers with next; a string is returned verbatim. */
  setNextResponse: (body: any) => void;
  reset: () => void;
  /** First captured request matching `pred`, with a readable failure message. */
  find: (pred: (r: CapturedRequest) => boolean) => CapturedRequest;
};

export function installFetchCapture(): FetchCapture {
  const requests: CapturedRequest[] = [];
  let nextResponseBody: any = { data: { ok: true } };

  (globalThis as any).fetch = async (input: any, init: any = {}) => {
    const url = String(input?.url ?? input);
    let body: any = init?.body;
    if (typeof body === 'string') { try { body = JSON.parse(body); } catch { /* keep raw */ } }
    else if (body && typeof body.entries === 'function') {
      const o: any = {};
      for (const [k, v] of body.entries()) o[k] = typeof v === 'string' ? v : '<blob>';
      body = o;
    }
    requests.push({ url, method: String(init?.method || 'GET').toUpperCase(), body });
    const text = typeof nextResponseBody === 'string' ? nextResponseBody : JSON.stringify(nextResponseBody);
    return {
      ok: true,
      status: 200,
      headers: { get: (h: string) => (h.toLowerCase() === 'content-type' ? 'application/json' : null) },
      text: async () => text,
      json: async () => (typeof nextResponseBody === 'string' ? JSON.parse(nextResponseBody) : nextResponseBody),
    } as any;
  };

  return {
    requests,
    setNextResponse: (b: any) => { nextResponseBody = b; },
    reset: () => { requests.length = 0; },
    find: (pred) => {
      const hit = requests.find(pred);
      if (!hit) {
        throw new Error(
          `no captured request matched; saw: ${requests.map((r) => `${r.method} ${r.url}`).join(', ') || '<none>'}`,
        );
      }
      return hit;
    },
  };
}

export async function makeVaultStore(): Promise<any> {
  const { configureStore } = await import(
    `${REPO_ROOT}/node_modules/@reduxjs/toolkit/dist/redux-toolkit.modern.mjs`
  );
  const { heimdallApi } = await import(`${REPO_ROOT}/src/ui/api/heimdallApi.ts`);
  const vaultReducer = (await import(`${REPO_ROOT}/src/ui/store/vaultSlice.ts`)).default;

  return configureStore({
    reducer: {
      vault: vaultReducer,
      chat: (s: any = { session: { daemonUrl: 'http://127.0.0.1:7777', clientToken: 'tok_test' } }) => s,
      [heimdallApi.reducerPath]: heimdallApi.reducer,
    },
    middleware: (g: any) =>
      g({ serializableCheck: false, immutableCheck: false }).concat(heimdallApi.middleware),
  });
}

/**
 * Unlock the vault the PRODUCTION way: a real non-extractable CryptoKey in the
 * module-level active-key slot. Nothing writes the key into Redux state -- the
 * `rawVaultKeyHex` field no longer exists, so a fixture that injects hex into mock
 * state is testing a mechanism no production read can reach.
 */
export async function unlockVault(store: any, keyHex: string): Promise<CryptoKey> {
  const { importRawKeyHex, setActiveVaultKey } = await import(`${REPO_ROOT}/src/ui/utils/vaultCrypto.ts`);
  const { setVaultConfigured, setVaultUnlocked } = await import(`${REPO_ROOT}/src/ui/store/vaultSlice.ts`);
  const key = await importRawKeyHex(keyHex);
  setActiveVaultKey(key, null);
  store.dispatch(setVaultConfigured(true));
  store.dispatch(setVaultUnlocked(keyHex));
  return key;
}

/** Lock the vault: dispatch lockVault AND clear the active key, as the real lock does. */
export async function lockVaultFully(store: any): Promise<void> {
  const { setActiveVaultKey } = await import(`${REPO_ROOT}/src/ui/utils/vaultCrypto.ts`);
  const { lockVault } = await import(`${REPO_ROOT}/src/ui/store/vaultSlice.ts`);
  const { heimdallApi } = await import(`${REPO_ROOT}/src/ui/api/heimdallApi.ts`);
  store.dispatch(lockVault());
  store.dispatch(heimdallApi.util.resetApiState());
  setActiveVaultKey(null);
}

/** Encryption disabled: no vault configured and no key anywhere. */
export async function clearActiveKey(): Promise<void> {
  const { setActiveVaultKey } = await import(`${REPO_ROOT}/src/ui/utils/vaultCrypto.ts`);
  setActiveVaultKey(null, null);
}
