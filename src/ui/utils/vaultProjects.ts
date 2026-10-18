// Zero-Knowledge Vault Transformers for Projects
// REQ-VAULT-PROJECTS-1

import type { VaultKeyring } from './vaultKeyring.ts';
import { isVaultArmored, encryptVaultText, decryptVaultText, getActiveVaultKey } from './vaultContent.ts';

export interface ProjectPayload {
  name?: string;
  description?: string;
  [key: string]: any;
}

/**
 * Encrypt project fields (name, description) if vault is unlocked using active CryptoKey or key string.
 */
export async function encryptProjectFields<T extends ProjectPayload>(
  payload: T,
  activeKey?: VaultKeyring | null,
): Promise<T> {
  const resolvedKey = activeKey || getActiveVaultKey();
  if (!resolvedKey) return { ...payload };
  const res = { ...payload };
  if (res.name && !isVaultArmored(res.name)) {
    res.name = await encryptVaultText(res.name, resolvedKey);
  }
  if (res.description && !isVaultArmored(res.description)) {
    res.description = await encryptVaultText(res.description, resolvedKey);
  }
  return res;
}

/**
 * Decrypt project fields (name, description) using active CryptoKey or key string.
 * If vault is locked or key is not provided, leaves armored strings as-is (graceful fallback).
 */
export async function decryptProjectRecord<T extends ProjectPayload>(
  project: T,
  activeKey?: VaultKeyring | null,
): Promise<T> {
  const resolvedKey = activeKey || getActiveVaultKey();
  if (!resolvedKey) return project;
  let name = project.name;
  let description = project.description;

  if (name && isVaultArmored(name)) {
    try {
      name = await decryptVaultText(name, resolvedKey);
    } catch {}
  }
  if (description && isVaultArmored(description)) {
    try {
      description = await decryptVaultText(description, resolvedKey);
    } catch {}
  }

  return {
    ...project,
    name,
    description,
  };
}

/**
 * Decrypt an array of project records.
 */
export async function decryptProjectList<T extends ProjectPayload>(
  projects: T[],
  activeKey?: VaultKeyring | null,
): Promise<T[]> {
  const resolvedKey = activeKey || getActiveVaultKey();
  if (!resolvedKey || !Array.isArray(projects)) return projects;
  return Promise.all(projects.map((project) => decryptProjectRecord(project, resolvedKey)));
}
