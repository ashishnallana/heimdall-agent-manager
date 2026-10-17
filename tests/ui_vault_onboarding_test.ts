// REQ-VAULT-UI-CLIENT-FLOW-1: Tests for Vault Onboarding Modal,
// password/recovery UI, session persistence, and AppShell integration.
//
// RUN: node --test tests/ui_vault_onboarding_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

import {
  generateVaultKey,
  exportRawKeyHex,
  importRawKeyHex,
  isVaultSupported,
  AES_GCM_NONCE_BYTES,
  bytesToHex,
  hexToBytes,
} from '../src/ui/utils/vaultCrypto.ts';
import {
  persistVaultKey,
  restoreVaultKey,
  deleteVaultKey,
  createMockIndexedDB,
} from '../src/ui/utils/vaultPersistence.ts';
import vaultReducer, {
  setVaultConfigured,
  setVaultUnlocked,
  importLocalKey,
  lockVault,
  hydrateVaultFromSession,
  selectIsVaultConfigured,
  selectIsVaultUnlocked,
  selectRawVaultKeyHex,
  validateHexVaultKey,
  importAndValidateCryptoKey,
  readSessionVaultKey,
  writeSessionVaultKey,
  clearSessionVaultKey,
  readOnboardingDismissed,
  writeOnboardingDismissed,
  loadInitialVaultState,
  shouldOpenVaultOnboarding,
  vaultStatusLabel,
  VAULT_UNSUPPORTED_REASON,
  VAULT_SESSION_KEY,
  VAULT_ONBOARDING_DISMISSED_KEY,
} from '../src/ui/store/vaultSlice.ts';

// Helper to provide an in-memory sessionStorage mock for Node test environment
function setupMockSessionStorage(): Map<string, string> {
  const store = new Map<string, string>();
  const mockStorage: Storage = {
    length: 0,
    clear: () => {
      store.clear();
      mockStorage.length = 0;
    },
    getItem: (key: string) => store.get(key) ?? null,
    key: (index: number) => Array.from(store.keys())[index] ?? null,
    removeItem: (key: string) => {
      store.delete(key);
      mockStorage.length = store.size;
    },
    setItem: (key: string, value: string) => {
      store.set(key, String(value));
      mockStorage.length = store.size;
    },
  };
  (globalThis as any).sessionStorage = mockStorage;
  return store;
}

// -----------------------------------------------------------------------------
// Test 3: Functional verification of 64-hex key import, WebCrypto import, & Redux
// -----------------------------------------------------------------------------

test('Direct 64-char hex key import validates, imports CryptoKey, and unlocks Redux vault', async () => {
  setupMockSessionStorage();

  // Generate valid 256-bit AES-GCM vault key and export hex
  const vaultKey = await generateVaultKey();
  const validHexKey = await exportRawKeyHex(vaultKey);
  assert.equal(validHexKey.length, 64);
  assert.match(validHexKey, /^[0-9a-f]{64}$/);

  // 1. Validation test
  assert.equal(validateHexVaultKey(validHexKey), validHexKey);
  assert.equal(validateHexVaultKey(`  ${validHexKey.toUpperCase()}  `), validHexKey);

  // Invalid key lengths or characters must throw
  assert.throws(() => validateHexVaultKey(''), /Invalid vault key/);
  assert.throws(() => validateHexVaultKey('1234abcd'), /Invalid vault key/);
  assert.throws(() => validateHexVaultKey('z'.repeat(64)), /Invalid vault key/);
  assert.throws(() => validateHexVaultKey(validHexKey.slice(0, 63)), /Invalid vault key/);
  assert.throws(() => validateHexVaultKey(validHexKey + '0'), /Invalid vault key/);

  // 2. WebCrypto import validation
  const importedKey = await importAndValidateCryptoKey(validHexKey);
  assert.ok(importedKey instanceof CryptoKey);
  assert.equal(importedKey.algorithm.name, 'AES-GCM');

  // Verify key can encrypt & decrypt correctly
  const plaintext = new TextEncoder().encode('Hello, Heimdall Zero-Knowledge Vault!');
  const nonce = crypto.getRandomValues(new Uint8Array(AES_GCM_NONCE_BYTES));
  const ciphertext = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv: nonce },
    importedKey,
    plaintext,
  );
  const decrypted = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: nonce },
    importedKey,
    ciphertext,
  );
  assert.equal(new TextDecoder().decode(decrypted), 'Hello, Heimdall Zero-Knowledge Vault!');

  // 3. Redux reducer importLocalKey action without session persistence
  let state = vaultReducer(undefined, { type: '@@INIT' });
  assert.equal(selectIsVaultConfigured({ vault: state }), false);
  assert.equal(selectIsVaultUnlocked({ vault: state }), false);
  assert.equal(selectRawVaultKeyHex({ vault: state }), null);

  state = vaultReducer(state, importLocalKey(validHexKey, false));
  assert.equal(selectIsVaultConfigured({ vault: state }), true);
  assert.equal(selectIsVaultUnlocked({ vault: state }), true);
  assert.equal((state as any).rawVaultKeyHex, undefined);
  assert.equal(selectRawVaultKeyHex({ vault: state }), null);
  assert.equal(readSessionVaultKey(), null, 'Key must not be in sessionStorage when rememberSession is false');

  // Lock vault
  state = vaultReducer(state, lockVault());
  assert.equal(selectIsVaultUnlocked({ vault: state }), false);
  assert.equal(selectRawVaultKeyHex({ vault: state }), null);
});

// -----------------------------------------------------------------------------
// Test 4: Functional verification of session persistence & hydration
// -----------------------------------------------------------------------------

test('Session persistence saves non-extractable key to IndexedDB and ensures sessionStorage has no raw key (REQ-VAULT-HARDEN-1, REQ-VAULT-HARDEN-2)', async () => {
  const store = setupMockSessionStorage();
  (globalThis as any).indexedDB = createMockIndexedDB();

  const vaultKey = await generateVaultKey();
  const hexKey = await exportRawKeyHex(vaultKey);

  // 1. Import with rememberSession = true
  let state = vaultReducer(undefined, { type: '@@INIT' });
  state = vaultReducer(state, importLocalKey(hexKey, true));

  assert.equal(selectIsVaultConfigured({ vault: state }), true);
  assert.equal(selectIsVaultUnlocked({ vault: state }), true);
  assert.equal((state as any).rawVaultKeyHex, undefined);
  assert.equal(selectRawVaultKeyHex({ vault: state }), null);

  // Verify sessionStorage NEVER contains raw key
  assert.equal(store.get(VAULT_SESSION_KEY), undefined, 'sessionStorage must not contain raw key');
  assert.equal(readSessionVaultKey(), null);

  // 2. Persist non-extractable CryptoKey directly to IndexedDB
  const nonExtractableKey = await importRawKeyHex(hexKey);
  assert.equal(nonExtractableKey.extractable, false);
  await persistVaultKey(nonExtractableKey);

  // 3. Simulate page reload: restore non-extractable CryptoKey from IndexedDB
  const restoredKey = await restoreVaultKey();
  assert.ok(restoredKey, 'IndexedDB must restore CryptoKey');
  assert.equal(restoredKey.extractable, false, 'Restored key must remain non-extractable');

  // Calling crypto.subtle.exportKey('raw', restoredKey) throws InvalidAccessError
  await assert.rejects(async () => {
    await crypto.subtle.exportKey('raw', restoredKey);
  }, (err: any) => err.name === 'InvalidAccessError' || String(err).includes('not extractable'));

  // 4. Locking the vault clears IndexedDB and resets unlocked state
  state = vaultReducer(state, lockVault());
  assert.equal(selectIsVaultUnlocked({ vault: state }), false);
  assert.equal(selectRawVaultKeyHex({ vault: state }), null);
  await deleteVaultKey();
  const keyAfterLock = await restoreVaultKey();
  assert.equal(keyAfterLock, null, 'Locking vault must purge IndexedDB record');
  assert.equal(store.get(VAULT_SESSION_KEY), undefined);
  assert.equal(readSessionVaultKey(), null);

  // 5. Setting vault configured to false also clears IndexedDB
  await persistVaultKey(nonExtractableKey);
  assert.ok(await restoreVaultKey());
  state = vaultReducer(state, setVaultConfigured(false));
  await deleteVaultKey();
  assert.equal(await restoreVaultKey(), null, 'setVaultConfigured(false) must clear IndexedDB');
});

// -----------------------------------------------------------------------------
// Test 5: Functional verification of onboarding dismissal
// -----------------------------------------------------------------------------

test('Onboarding dismissal flag prevents aggressive re-popping in current session', () => {
  const store = setupMockSessionStorage();

  // Initially not dismissed
  assert.equal(readOnboardingDismissed(), false);

  // Dismiss for session
  writeOnboardingDismissed(true);
  assert.equal(store.get(VAULT_ONBOARDING_DISMISSED_KEY), 'true');
  assert.equal(readOnboardingDismissed(), true);

  // Reset dismissal
  writeOnboardingDismissed(false);
  assert.equal(store.get(VAULT_ONBOARDING_DISMISSED_KEY), undefined);
  assert.equal(readOnboardingDismissed(), false);
});

// -----------------------------------------------------------------------------
// REQ-VAULT-UNSUP-5: graceful "Vault unsupported" when crypto.subtle is unavailable
//
// Self-hosting over plain HTTP on a non-localhost origin means the page is not a
// secure context, so `crypto.subtle` is undefined while `window.crypto` still exists.
// These tests stub that shape and assert the *decisions* the UI makes, not merely
// that a predicate returns false.
// -----------------------------------------------------------------------------

/**
 * Run `fn` with `globalThis.crypto` replaced by a non-secure-context shape: present,
 * with getRandomValues, but no `subtle`. Restores the real crypto afterwards.
 */
function withoutSubtleCrypto<T>(fn: () => T): T {
  const realCrypto = globalThis.crypto;
  Object.defineProperty(globalThis, 'crypto', {
    value: { getRandomValues: (a: any) => a },
    configurable: true,
    writable: true,
  });
  try {
    return fn();
  } finally {
    Object.defineProperty(globalThis, 'crypto', {
      value: realCrypto,
      configurable: true,
      writable: true,
    });
  }
}

test('isVaultSupported() is true in a secure context and false when crypto.subtle is absent', () => {
  // True: Node's real webcrypto exposes subtle.generateKey.
  assert.equal(isVaultSupported(), true, 'must be true when SubtleCrypto is present');

  // False: crypto present, subtle missing — the plain-HTTP non-localhost shape.
  withoutSubtleCrypto(() => {
    assert.equal(
      (globalThis.crypto as any)?.subtle,
      undefined,
      'stub must reproduce the non-secure-context shape (crypto present, subtle absent)',
    );
    assert.equal(isVaultSupported(), false, 'must be false when crypto.subtle is absent');
  });

  // False: crypto object entirely missing.
  const realCrypto = globalThis.crypto;
  Object.defineProperty(globalThis, 'crypto', { value: undefined, configurable: true, writable: true });
  try {
    assert.equal(isVaultSupported(), false, 'must be false when globalThis.crypto is undefined');
  } finally {
    Object.defineProperty(globalThis, 'crypto', { value: realCrypto, configurable: true, writable: true });
  }

  // Restored.
  assert.equal(isVaultSupported(), true, 'must be restored to true after stubbing');
});

test('onboarding modal stays closed when crypto.subtle is absent, for both open paths', () => {
  setupMockSessionStorage();

  // Baseline: in a secure context the modal DOES open for a locked, undismissed vault.
  assert.equal(
    shouldOpenVaultOnboarding({ isVaultUnlocked: false, dismissed: false }),
    true,
    'secure-context behavior must be unchanged: modal opens when locked and not dismissed',
  );

  withoutSubtleCrypto(() => {
    // Path 1 — AppShell first-visit auto-pop. Every combination that would otherwise
    // open the modal must now be suppressed.
    for (const isVaultUnlocked of [false, true]) {
      for (const dismissed of [false, true]) {
        assert.equal(
          shouldOpenVaultOnboarding({ isVaultUnlocked, dismissed }),
          false,
          `auto-pop must stay closed when unsupported (unlocked=${isVaultUnlocked}, dismissed=${dismissed})`,
        );
      }
    }

    // Path 2 — the isUnlockModalOpen back door from vault placeholders is gated on
    // isVaultSupported() directly, so a placeholder click cannot reopen the modal.
    assert.equal(isVaultSupported(), false, 'back-door gate must evaluate false when unsupported');
  });

  // Secure-context path provably untouched after restore.
  assert.equal(shouldOpenVaultOnboarding({ isVaultUnlocked: false, dismissed: false }), true);
  assert.equal(shouldOpenVaultOnboarding({ isVaultUnlocked: true, dismissed: false }), false);
  assert.equal(shouldOpenVaultOnboarding({ isVaultUnlocked: false, dismissed: true }), false);
});

test('dock badge reads "Unsupported" with precedence over Unlocked/Locked/Unconfigured', () => {
  // Secure context: unchanged three-state behavior.
  assert.equal(vaultStatusLabel({ isVaultUnlocked: true, isVaultConfigured: true }), 'Unlocked');
  assert.equal(vaultStatusLabel({ isVaultUnlocked: false, isVaultConfigured: true }), 'Locked');
  assert.equal(vaultStatusLabel({ isVaultUnlocked: false, isVaultConfigured: false }), 'Unconfigured');

  // Unsupported wins over every combination.
  withoutSubtleCrypto(() => {
    for (const isVaultUnlocked of [false, true]) {
      for (const isVaultConfigured of [false, true]) {
        assert.equal(
          vaultStatusLabel({ isVaultUnlocked, isVaultConfigured }),
          'Unsupported',
          `Unsupported must take precedence (unlocked=${isVaultUnlocked}, configured=${isVaultConfigured})`,
        );
      }
    }
  });

  // Tooltip names both cause and remedy.
  assert.match(VAULT_UNSUPPORTED_REASON, /secure context/i, 'tooltip must name the cause');
  assert.match(VAULT_UNSUPPORTED_REASON, /HTTPS|localhost/i, 'tooltip must name the remedy');
});

test('REQ-AUX-10: bridge reauthentication keeps an unlocked browser open and forwards only submit-scoped raw material', () => {
  const source = fs.readFileSync(
    fileURLToPath(new URL('../src/ui/components/settings/VaultOnboardingModal.tsx', import.meta.url)),
    'utf8',
  );
  assert.match(source, /mode\?: 'vault-unlock' \| 'bridge-reauthentication' \| 'search-reauthentication'/);
  assert.match(source, /if \(!isCredentialReauthentication && isUnlocked && isOpen\)/);
  assert.match(source, /const rawVaultKeyHex = await decryptVaultKeyEnvelopeHex\([\s\S]*if \(isBridgeReauthentication\) \{[\s\S]*await onBridgeReauthenticate\?\.\(rawVaultKeyHex\)/);
  assert.match(source, /isBridgeReauthentication[\s\S]*'Unlock connected bridges'/);
  assert.match(source, /!isCredentialReauthentication \? \([\s\S]*vault-onboarding-remember-checkbox/);
});

test('search reauthentication stays open while unlocked, persists v2, and makes encrypted search usable', async () => {
  const shellSource = fs.readFileSync(
    fileURLToPath(new URL('../src/ui/components/shell/AppShell.tsx', import.meta.url)),
    'utf8',
  );
  assert.match(shellSource, /<VaultOnboardingHost/);
  const hostSource = fs.readFileSync(
    fileURLToPath(new URL('../src/ui/components/settings/VaultOnboardingHost.tsx', import.meta.url)),
    'utf8',
  );
  assert.match(hostSource, /requestedOpen && isSearchReauthentication \? 'search-reauthentication' : 'vault-unlock'/);
  const searchCallback = hostSource.match(/onSearchReauthenticate=\{async \(rawVaultKeyHex\) => \{([\s\S]*?)\n\s*\}\}/)?.[1] || '';
  assert.match(searchCallback, /await setActiveBridgeVaultKeyMaterial\(rawVaultKeyHex\)/);
  assert.doesNotMatch(searchCallback, /reconcile|unseal/i, 'search reauthentication must not alter bridge unseal behavior');

  const { JSDOM } = await import('jsdom');
  const dom = new JSDOM('<!DOCTYPE html><html><body><div id="root"></div></body></html>', { url: 'http://localhost/' });
  const previous = {
    window: (globalThis as any).window,
    document: (globalThis as any).document,
    HTMLElement: (globalThis as any).HTMLElement,
    navigator: (globalThis as any).navigator,
    fetch: (globalThis as any).fetch,
    indexedDB: (globalThis as any).indexedDB,
  };
  (globalThis as any).window = dom.window;
  (globalThis as any).document = dom.window.document;
  (globalThis as any).HTMLElement = dom.window.HTMLElement;
  Object.defineProperty(globalThis, 'navigator', { value: dom.window.navigator, configurable: true });
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  (globalThis as any).indexedDB = createMockIndexedDB();

  const password = 'legacy-search-password';
  const iterations = 10_000;
  const salt = '17'.repeat(16);
  const extractableKey = await generateVaultKey();
  const rawVaultKeyHex = await exportRawKeyHex(extractableKey);
  const contentKey = await importRawKeyHex(rawVaultKeyHex);
  const vaultCrypto = await import('../src/ui/utils/vaultCrypto.ts');
  const wrappingKey = await vaultCrypto.deriveKeyFromPassword(password, salt, iterations);
  const envelope = await vaultCrypto.encryptVaultKeyEnvelope(wrappingKey, extractableKey);
  await persistVaultKey(contentKey);

  const vault = await import('../src/ui/store/vaultSlice.ts');
  await vault.initializeVaultPersistence();
  assert.equal(vault.getActiveTaskChainSearchKey(), null, 'legacy v1 restore begins without a search key');

  const response = (body: unknown, status = 200) => ({
    ok: status >= 200 && status < 300,
    status,
    headers: { get: () => 'application/json' },
    text: async () => JSON.stringify(body),
    json: async () => body,
  }) as any;
  (globalThis as any).fetch = async (input: any, init?: any) => {
    const url = String(input?.url ?? input);
    if (url.includes('/user/vault')) {
      return response({ data: { vault: {
        encrypted_vault_key: envelope.ciphertextHex,
        vault_key_nonce: envelope.nonceHex,
        vault_key_tag: envelope.tagHex,
        kdf_salt: salt,
        kdf_iterations: iterations,
        recovery_encrypted_vault_key: '',
        recovery_nonce: '',
        recovery_tag: '',
        recovery_salt: '',
      } } });
    }
    if (url.includes('/task-chains/search/relay')) {
      const request = JSON.parse(String(init?.body || '{}'));
      const search = await import('../src/ui/utils/taskChainSearch.ts');
      const key = vault.getActiveTaskChainSearchKey();
      assert.ok(key);
      await search.openTaskChainSearch(
        request.envelope,
        key,
        search.taskChainSearchAad('usr_legacy', request.bridge_id, request.request_id, 'request', request.expires_at_ms),
      );
      const resultEnvelope = await search.sealTaskChainSearch(
        {
          request_id: request.request_id,
          bridge_id: request.bridge_id,
          indexed_revision: 1,
          stale: false,
          hits: [{ chain_id: 'chain_found', project_id: 'proj_1', status: 'active', updated_at: '2026-10-17T00:00:00Z', title: 'Found', description: '' }],
        },
        key,
        search.taskChainSearchAad('usr_legacy', request.bridge_id, request.request_id, 'response', request.expires_at_ms),
      );
      return response({ data: { ok: true, envelope: resultEnvelope } });
    }
    if (url.includes('/bridges')) {
      return response({ bridges: [{ bridge_id: 'brg_search', status: 'online', vault_status: 'unlocked', task_chain_search_ready: true }] });
    }
    return response({});
  };

  const React = await import('react');
  const { createRoot } = await import('react-dom/client');
  const { act } = await import('react');
  const { Provider } = await import('react-redux');
  const { configureStore } = await import('@reduxjs/toolkit');
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const { VaultOnboardingHost } = await import('../src/ui/components/settings/VaultOnboardingHost.tsx');
  const store = configureStore({
    reducer: { vault: vault.default, [heimdallApi.reducerPath]: heimdallApi.reducer },
    middleware: (getDefault: any) => getDefault({ serializableCheck: false, immutableCheck: false }).concat(heimdallApi.middleware),
  });
  store.dispatch(vault.setVaultConfigured(true));
  store.dispatch(vault.hydrateVaultFromSession());
  assert.equal(await vault.verifyActiveVaultKeyMaterial(rawVaultKeyHex), true);
  assert.equal(await vault.verifyActiveVaultKeyMaterial('ef'.repeat(32)), false);
  store.dispatch(vault.openSearchReauthentication());
  const root = createRoot(dom.window.document.getElementById('root')!);

  try {
    await act(async () => {
      root.render(React.createElement(
        Provider,
        { store },
        React.createElement(VaultOnboardingHost, {
          onboardingOpen: false,
          onOnboardingOpenChange: () => {},
          bridgeReauthenticationOpen: false,
          onBridgeReauthenticationOpenChange: () => {},
          onBridgeReauthenticate: async () => {},
        }),
      ));
    });
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 100));
    });
    const input = dom.window.document.querySelector('[data-debug-id="vault-onboarding-unlock-password-input"]') as HTMLInputElement;
    assert.ok(input, `password ceremony remains visible even though the content Vault is already unlocked: ${dom.window.document.body.innerHTML}`);
    assert.match(dom.window.document.body.textContent || '', /Enable task-chain search/);
    assert.equal((store.getState() as any).vault.isUnlockModalOpen, true, 'effects do not clear the Redux request before the ceremony closes');
    assert.equal((store.getState() as any).vault.unlockModalPurpose, 'search-reauthentication');

    await act(async () => {
      const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, 'value')!.set!;
      setter.call(input, password);
      input.dispatchEvent(new dom.window.Event('input', { bubbles: true }));
    });
    await act(async () => {
      (dom.window.document.querySelector('[data-debug-id="vault-onboarding-unlock-submit-btn"]') as HTMLButtonElement).click();
      await new Promise((resolve) => setTimeout(resolve, 75));
    });

    assert.ok(vault.getActiveTaskChainSearchKey(), 'password submission installs the derived search key');
    assert.equal((store.getState() as any).vault.isUnlockModalOpen, false, 'the Redux request clears only after the ceremony closes');
    assert.equal((store.getState() as any).vault.unlockModalPurpose, undefined);
    const restored = await (await import('../src/ui/utils/vaultPersistence.ts')).restoreVaultKeys();
    assert.equal(restored?.version, 2, 'remembered legacy record is upgraded to a v2 key pair');
    const search = await import('../src/ui/utils/taskChainSearch.ts');
    const result = await search.searchTaskChainsEncrypted('found chain', 'usr_legacy');
    assert.equal(result.hits[0]?.chain_id, 'chain_found');
  } finally {
    await act(async () => root.unmount());
    store.dispatch(heimdallApi.util.resetApiState());
    vault.setActiveVaultKey(null);
    dom.window.close();
    (globalThis as any).window = previous.window;
    (globalThis as any).document = previous.document;
    (globalThis as any).HTMLElement = previous.HTMLElement;
    Object.defineProperty(globalThis, 'navigator', { value: previous.navigator, configurable: true });
    (globalThis as any).fetch = previous.fetch;
    (globalThis as any).indexedDB = previous.indexedDB;
  }
});


test('vault setup explains the vault password is separate from login and used for E2E encryption', () => {
  const read = (rel: string) => fs.readFileSync(fileURLToPath(new URL(rel, import.meta.url)), 'utf8');
  const note = read('../src/ui/components/settings/VaultPasswordPurposeNote.tsx');
  assert.match(note, /different from your login password/);
  assert.match(note, /end-to-end encryption of your messages and remote connections/);

  // Rendered in the modal's CREATION form, before the password field, and not in
  // its unlock form. VaultPanel's setup wizard is asserted in ui_vault_panel_test.ts.
  const surfaces = [
    {
      file: '../src/ui/components/settings/VaultOnboardingModal.tsx',
      setupForm: 'data-debug-id="vault-onboarding-setup-form"',
      passwordInput: 'vault-onboarding-master-password-input',
      unlockMarkers: ['data-debug-id="vault-onboarding-unlock-form"'],
    },
  ];
  for (const surface of surfaces) {
    const source = read(surface.file);
    const uses = source.split('<VaultPasswordPurposeNote />').length - 1;
    assert.equal(uses, 1, `${surface.file}: note rendered exactly once`);
    const noteAt = source.indexOf('<VaultPasswordPurposeNote />');
    const setupAt = source.indexOf(surface.setupForm);
    assert.ok(setupAt >= 0 && noteAt > setupAt, `${surface.file}: note is inside the setup form`);
    assert.ok(noteAt < source.indexOf(surface.passwordInput), `${surface.file}: note precedes the password field`);
    for (const marker of surface.unlockMarkers) {
      const unlockAt = source.indexOf(marker);
      assert.ok(unlockAt > noteAt, `${surface.file}: note is not in ${marker}`);
    }
  }
});
