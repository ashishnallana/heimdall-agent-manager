import { ApiError, cookieJsonFetch, cookieMutation } from '../../api/cookieFetch';
import { decryptVaultText, encryptVaultText, getActiveVaultKey } from '../../utils/vaultCrypto';

export type ProfileEnv = {
  name: string;
  value: string;
  sensitive: boolean;
  value_redacted?: boolean;
  keep?: boolean;
};
export type ProfileConfig = {
  binary_path?: string;
  config_dir?: string;
  home_path?: string;
  shadow_home_path?: string;
  launch_args?: string;
  custom_models?: string[];
  auth_method?: string;
  api_key?: string;
  api_key_redacted?: boolean;
  gcp_project?: string;
  gcp_location?: string;
};
export type ProviderProfile = {
  profile_id: string;
  provider: string;
  label_enc: string;
  accent: string;
  enabled: boolean;
  environment: ProfileEnv[];
  config: ProfileConfig;
};
export type ProfileMetadata = Omit<ProviderProfile, 'environment' | 'config'> & { state?: string };
export type ProfileOperation = 'get' | 'upsert' | 'remove' | 'reset';

export function generateProfileId(
  provider: string,
  used: readonly string[],
  random = crypto.getRandomValues(new Uint8Array(4)),
): string {
  const alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
  const base =
    provider.slice(0, 27) + '_' + Array.from(random.slice(0, 4), (n) => alphabet[n & 31]).join('');
  let id = base;
  for (let i = 2; used.includes(id); i++) id = base.slice(0, 32 - String(i).length - 1) + '_' + i;
  return id;
}
export function profileIdentityError(
  id: string,
  label: string,
  accent: string,
  used: readonly string[],
  reserved: readonly string[],
): string {
  if (!/^[a-z][a-z0-9_-]{0,31}$/.test(id))
    return 'Use 1–32 lowercase letters, digits, underscores or hyphens, starting with a letter.';
  if (used.includes(id) || reserved.includes(id))
    return 'This profile ID is already in use or reserved for a default provider.';
  if (!label.trim() || label.length > 256) return 'Enter a label of at most 256 characters.';
  if (accent && !/^#[0-9a-fA-F]{6}$/.test(accent)) return 'Choose a six-digit hex accent color.';
  return '';
}
// Quote each literal argument for the bridge tokenizer; never invoke a shell.
export function encodeProfileArgs(args: readonly string[], validate = true): string {
  const rows = args.filter((s) => s !== '');
  if (
    validate &&
    (rows.length > 32 ||
      rows.some((s) => new TextEncoder().encode(s).length > 1024 || s.includes('\0')))
  )
    throw new Error('Use at most 32 arguments, each at most 1 KiB.');
  return rows.map((s) => '"' + s.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"').join(' ');
}
export function decodeProfileArgs(input = ''): string[] {
  const result: string[] = [];
  let current = '';
  let quote = '';
  for (let i = 0; i < input.length; i++) {
    const c = input[i];
    if (quote) {
      if (c === quote) quote = '';
      else if (
        c === '\\' &&
        quote === '"' &&
        i + 1 < input.length &&
        ['"', '\\', '$', String.fromCharCode(96)].includes(input[i + 1])
      )
        current += input[++i];
      else current += c;
    } else if (c === '\\' && i + 1 < input.length && /[\s'"]/.test(input[i + 1]))
      current += input[++i];
    else if (c === '"' || c === "'") quote = c;
    else if (/\s/.test(c)) {
      if (current) {
        result.push(current);
        current = '';
      }
    } else current += c;
  }
  if (current) result.push(current);
  return result;
}
export function environmentForSave(rows: readonly ProfileEnv[]): ProfileEnv[] {
  if (rows.length > 64) throw new Error('Use at most 64 environment variables.');
  const names = new Set<string>();
  return rows.map((row) => {
    const name = row.name.trim();
    if (
      !/^[A-Za-z_][A-Za-z0-9_]*$/.test(name) ||
      names.has(name) ||
      /^(HEIMDALL_|HOME$|USERPROFILE$)/i.test(name)
    )
      throw new Error(
        'Environment names must be unique valid names; HOME, USERPROFILE and HEIMDALL_* are reserved.',
      );
    names.add(name);
    if (new TextEncoder().encode(row.value).length > 32768 || row.value.includes('\0'))
      throw new Error('Environment values must be at most 32 KiB without NUL characters.');
    if (row.value_redacted && !row.sensitive)
      throw new Error('Replace or clear a stored secret before making it public.');
    return {
      name,
      value: row.value,
      sensitive: row.sensitive,
      value_redacted: Boolean(row.sensitive && row.value_redacted && !row.value),
      keep: Boolean(row.sensitive && row.value_redacted && !row.value),
    };
  });
}
export async function profileLabel(
  profile: { label_enc?: string; profile_id?: string; provider?: string },
  fallback = '',
): Promise<string> {
  if (profile.label_enc && getActiveVaultKey()) {
    try {
      return await decryptVaultText(profile.label_enc);
    } catch {
      /* fail closed */
    }
  }
  return fallback || profile.profile_id || profile.provider || 'Provider';
}
export function profileEnvelope(
  op: ProfileOperation,
  bridgeId: string,
  bootId: string,
  profileId: string,
  body: unknown,
  ts = Date.now(),
  nonce = crypto.randomUUID(),
) {
  if (!bridgeId || !bootId || !profileId)
    throw new Error('The bridge must be connected before editing profiles.');
  return {
    op,
    profile_id: profileId,
    body: body ?? {},
    bridge_id: bridgeId,
    boot_id: bootId,
    ts,
    nonce,
  };
}
export const providerProfilesApi = {
  async list(bridgeId: string): Promise<ProfileMetadata[]> {
    const data = await cookieJsonFetch(
      '/bridges/' + encodeURIComponent(bridgeId) + '/provider-profiles',
    );
    return Array.isArray(data?.profiles) ? data.profiles : [];
  },
  async operate(
    bridgeId: string,
    profileId: string,
    op: ProfileOperation,
    body?: unknown,
  ): Promise<ProviderProfile | undefined> {
    // A stale boot is safe to retry once: it was refused before acting. No retry for
    // timeouts, transport failures or replays, which may have already applied.
    for (let attempt = 0; attempt < 2; attempt++) {
      const keyring = getActiveVaultKey();
      if (!keyring) throw new Error('Unlock this device before editing provider profiles.');
      const target = await cookieJsonFetch(
        '/bridges/' + encodeURIComponent(bridgeId) + '/public-key',
      );
      const envelope = profileEnvelope(
        op,
        bridgeId,
        String(target?.unseal_boot_id || ''),
        profileId,
        body,
      );
      if (getActiveVaultKey() !== keyring)
        throw new Error('The device keyring changed. Reopen the profile.');
      const sealed = await encryptVaultText(JSON.stringify(envelope), keyring);
      const base =
        '/bridges/' +
        encodeURIComponent(bridgeId) +
        '/provider-profiles/' +
        encodeURIComponent(profileId);
      const path = base + (op === 'get' || op === 'reset' ? '/' + op : '');
      const result = await cookieMutation(
        path,
        op === 'upsert' ? 'PUT' : op === 'remove' ? 'DELETE' : 'POST',
        { sealed },
      );
      if (getActiveVaultKey() !== keyring)
        throw new Error('The device keyring changed. Reopen the profile.');
      if (!result?.ok) {
        if (result?.error === 'profile_stale_boot' && attempt === 0) continue;
        throw new ApiError(
          String(result?.error || 'Profile operation failed'),
          undefined,
          result?.error,
        );
      }
      if (op !== 'get') return;
      if (typeof result.sealed !== 'string' || !result.sealed.startsWith('vault:v2:'))
        throw new Error('The bridge returned an invalid sealed profile.');
      const response = JSON.parse(await decryptVaultText(result.sealed, keyring));
      if (getActiveVaultKey() !== keyring)
        throw new Error('The device keyring changed. Reopen the profile.');
      if (response.nonce !== envelope.nonce)
        throw new Error('The profile response did not match this request.');
      const profile = response.profiles?.find((p: ProviderProfile) => p.profile_id === profileId);
      if (!profile) throw new Error('The requested profile was not returned.');
      // Never retain a sensitive value even if a malformed bridge returned one.
      return {
        ...profile,
        config: {
          ...profile.config,
          api_key: '',
          api_key_redacted: Boolean(profile.config?.api_key_redacted || profile.config?.api_key),
        },
        environment: (profile.environment || []).map((e: ProfileEnv) =>
          e.sensitive
            ? { ...e, value: '', value_redacted: Boolean(e.value_redacted || e.value) }
            : e,
        ),
      };
    }
  },
};

export type ConfigDirectoryMode = 'inherit' | 'random' | 'custom';

export function configDirectoryMode(value = ''): ConfigDirectoryMode {
  if (!value.trim()) return 'inherit';
  return /(?:^|[\\/])\.heimdall-claude-[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value)
    ? 'random'
    : 'custom';
}

export function generateConfigDirectory(): string {
  return '~/.heimdall-claude-' + crypto.randomUUID();
}
