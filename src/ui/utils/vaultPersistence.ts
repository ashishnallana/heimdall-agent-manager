// Zero-Knowledge Vault IndexedDB Structured Cloning Persistence
// Implements secure storage of non-extractable WebCrypto CryptoKey handles
// across tab reloads without exposing raw key material to JS memory.
// REQ-VAULT-HARDEN-1, REQ-VAULT-HARDEN-2

export const VAULT_DB_NAME = 'heimdall_vault';
export const VAULT_DB_VERSION = 1;
export const VAULT_STORE_NAME = 'vault_keys';
export const VAULT_KEY_RECORD_ID = 'active_vault_key';

// version 3: the search key is the v2 per-epoch derivation (P1 adapter: epoch 1).
// A version-2 record's search key was derived under the retired v1 domain, so only
// its content key is restored.
export type PersistedVaultKeys = {
  version: 3;
  contentKey: CryptoKey;
  taskChainSearchKey: CryptoKey;
};

export type RestoredVaultKeys = {
  contentKey: CryptoKey;
  taskChainSearchKey: CryptoKey | null;
  version: 1 | 2 | 3;
};

function isCryptoKey(value: unknown): value is CryptoKey {
  return Boolean(
    value
    && typeof value === 'object'
    && typeof (value as CryptoKey).type === 'string'
    && typeof (value as CryptoKey).extractable === 'boolean'
    && (value as CryptoKey).algorithm,
  );
}

let vaultWriteQueue: Promise<void> = Promise.resolve();

function serializeVaultWrite(operation: () => Promise<void>): Promise<void> {
  const result = vaultWriteQueue.catch(() => {}).then(operation);
  vaultWriteQueue = result.catch(() => {});
  return result;
}

/**
 * Access the IndexedDB factory across browser, electron, and global environments.
 */
export function getIdbFactory(): IDBFactory | null {
  if (typeof indexedDB !== 'undefined') return indexedDB;
  if (typeof window !== 'undefined' && window.indexedDB) return window.indexedDB;
  if (typeof globalThis !== 'undefined' && (globalThis as any).indexedDB) return (globalThis as any).indexedDB;
  return null;
}

/**
 * Open the vault IndexedDB and ensure the 'vault_keys' object store exists.
 */
export function openVaultDb(): Promise<IDBDatabase> {
  const factory = getIdbFactory();
  if (!factory) {
    return Promise.reject(new Error('IndexedDB is not available in the current environment'));
  }
  return new Promise((resolve, reject) => {
    const request = factory.open(VAULT_DB_NAME, VAULT_DB_VERSION);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains(VAULT_STORE_NAME)) {
        db.createObjectStore(VAULT_STORE_NAME);
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error || new Error('Failed to open vault IndexedDB'));
  });
}

/**
 * Persist non-extractable CryptoKey directly into IndexedDB on vault unlock.
 * Leverages browser HTML5 Structured Clone support for WebCrypto keys.
 */
export async function persistVaultKey(key: CryptoKey): Promise<void> {
  return persistVaultRecord(key);
}

async function persistVaultRecord(record: CryptoKey | PersistedVaultKeys): Promise<void> {
  return serializeVaultWrite(() => persistVaultRecordNow(record));
}

async function persistVaultRecordNow(record: CryptoKey | PersistedVaultKeys): Promise<void> {
  const db = await openVaultDb();
  return new Promise((resolve, reject) => {
    try {
      const tx = db.transaction(VAULT_STORE_NAME, 'readwrite');
      const store = tx.objectStore(VAULT_STORE_NAME);
      const req = store.put(record, VAULT_KEY_RECORD_ID);
      req.onsuccess = () => resolve();
      req.onerror = () => reject(req.error || new Error('Failed to persist vault key to IndexedDB'));
      tx.oncomplete = () => {
        try {
          db.close();
        } catch {}
      };
    } catch (err) {
      try {
        db.close();
      } catch {}
      reject(err);
    }
  });
}

/** Persist the versioned pair without ever serializing raw key bytes. */
export async function persistVaultKeys(
  contentKey: CryptoKey,
  taskChainSearchKey: CryptoKey,
): Promise<void> {
  await persistVaultRecord({ version: 3, contentKey, taskChainSearchKey });
}

/**
 * Restore non-extractable CryptoKey from IndexedDB on page load/init.
 */
export async function restoreVaultKey(): Promise<CryptoKey | null> {
  return (await restoreVaultKeys())?.contentKey ?? null;
}

/** Restore a v2 key pair or adapt a legacy record containing only the content key. */
export async function restoreVaultKeys(): Promise<RestoredVaultKeys | null> {
  const factory = getIdbFactory();
  if (!factory) return null;
  try {
    const db = await openVaultDb();
    return await new Promise((resolve, reject) => {
      try {
        const tx = db.transaction(VAULT_STORE_NAME, 'readonly');
        const store = tx.objectStore(VAULT_STORE_NAME);
        const req = store.get(VAULT_KEY_RECORD_ID);
        req.onsuccess = () => {
          const result = req.result;
          if (isCryptoKey(result)) {
            resolve({ contentKey: result, taskChainSearchKey: null, version: 1 });
          } else if (
            result?.version === 3
            && isCryptoKey(result.contentKey)
            && isCryptoKey(result.taskChainSearchKey)
          ) {
            resolve({
              contentKey: result.contentKey,
              taskChainSearchKey: result.taskChainSearchKey,
              version: 3,
            });
          } else if (result?.version === 2 && isCryptoKey(result.contentKey)) {
            resolve({ contentKey: result.contentKey, taskChainSearchKey: null, version: 2 });
          } else {
            resolve(null);
          }
        };
        req.onerror = () => reject(req.error || new Error('Failed to restore vault key from IndexedDB'));
        tx.oncomplete = () => {
          try {
            db.close();
          } catch {}
        };
      } catch (err) {
        try {
          db.close();
        } catch {}
        reject(err);
      }
    });
  } catch {
    return null;
  }
}

/**
 * Delete IndexedDB record on vault lock (lockVault).
 */
export async function deleteVaultKey(): Promise<void> {
  const factory = getIdbFactory();
  if (!factory) return;
  return serializeVaultWrite(deleteVaultKeyNow);
}

async function deleteVaultKeyNow(): Promise<void> {
  try {
    const db = await openVaultDb();
    return await new Promise((resolve, reject) => {
      try {
        const tx = db.transaction(VAULT_STORE_NAME, 'readwrite');
        const store = tx.objectStore(VAULT_STORE_NAME);
        const req = store.delete(VAULT_KEY_RECORD_ID);
        req.onsuccess = () => resolve();
        req.onerror = () => reject(req.error || new Error('Failed to delete vault key from IndexedDB'));
        tx.oncomplete = () => {
          try {
            db.close();
          } catch {}
        };
      } catch (err) {
        try {
          db.close();
        } catch {}
        reject(err);
      }
    });
  } catch {}
}

export const clearVaultKey = deleteVaultKey;

/**
 * Helper to construct an in-memory IndexedDB mock for unit tests in Node.js environments.
 */
export function createMockIndexedDB(): IDBFactory {
  const stores = new Map<string, Map<string, any>>();
  return {
    open(dbName: string, version?: number): IDBOpenDBRequest {
      const req: any = {
        result: {
          name: dbName,
          version: version ?? 1,
          objectStoreNames: {
            contains(name: string): boolean {
              return stores.has(name);
            },
            item(index: number) {
              return Array.from(stores.keys())[index] ?? null;
            },
            get length() {
              return stores.size;
            },
            [Symbol.iterator]() {
              return stores.keys();
            },
          },
          createObjectStore(name: string) {
            if (!stores.has(name)) {
              stores.set(name, new Map());
            }
            return {};
          },
          transaction(storeName: string, _mode?: string) {
            if (!stores.has(storeName)) {
              stores.set(storeName, new Map());
            }
            const map = stores.get(storeName)!;
            const tx: any = {
              oncomplete: null,
              onerror: null,
              objectStore(_name: string) {
                return {
                  put(val: any, key: string) {
                    const r: any = {};
                    map.set(key, val);
                    queueMicrotask(() => {
                      if (r.onsuccess) r.onsuccess({ target: r });
                      if (tx.oncomplete) tx.oncomplete();
                    });
                    return r;
                  },
                  get(key: string) {
                    const r: any = { result: map.get(key) };
                    queueMicrotask(() => {
                      if (r.onsuccess) r.onsuccess({ target: r });
                      if (tx.oncomplete) tx.oncomplete();
                    });
                    return r;
                  },
                  delete(key: string) {
                    const r: any = {};
                    map.delete(key);
                    queueMicrotask(() => {
                      if (r.onsuccess) r.onsuccess({ target: r });
                      if (tx.oncomplete) tx.oncomplete();
                    });
                    return r;
                  },
                  clear() {
                    const r: any = {};
                    map.clear();
                    queueMicrotask(() => {
                      if (r.onsuccess) r.onsuccess({ target: r });
                      if (tx.oncomplete) tx.oncomplete();
                    });
                    return r;
                  },
                };
              },
            };
            return tx;
          },
          close() {},
        },
      };
      queueMicrotask(() => {
        if (req.onupgradeneeded) req.onupgradeneeded({ target: req });
        if (req.onsuccess) req.onsuccess({ target: req });
      });
      return req as IDBOpenDBRequest;
    },
    deleteDatabase(_name: string) {
      stores.clear();
      const req: any = {};
      queueMicrotask(() => {
        if (req.onsuccess) req.onsuccess({ target: req });
      });
      return req as IDBOpenDBRequest;
    },
    cmp(a: any, b: any) {
      return a < b ? -1 : a > b ? 1 : 0;
    },
  } as unknown as IDBFactory;
}
