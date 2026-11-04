import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import type { ProviderSettingsHeading } from '../settings/ProvidersPanel';
import { useDispatch, useSelector } from 'react-redux';
import { Badge, Button, Panel, Spinner, StatusPill, Text } from '@ui';
import { heimdallApi } from '../../api/heimdallApi';
import { apiErrorText, cookieMutation } from '../../api/cookieFetch';
import { selectIsVaultUnlocked } from '../../store/vaultSlice';
import { encryptVaultText } from '../../utils/vaultCrypto';
import { providerSetupApi, type BridgeProviderStatus } from './providerSetupApi';
import {
  configDirectoryMode,
  generateConfigDirectory,
  type ConfigDirectoryMode,
  decodeProfileArgs,
  encodeProfileArgs,
  environmentForSave,
  generateProfileId,
  profileIdentityError,
  profileLabel,
  providerProfilesApi,
  type ProfileMetadata,
  type ProviderProfile,
  type ProfileEnv,
} from './providerProfiles';
import ProviderExtensionInstallAction from '../extension/ProviderExtensionInstallAction';
import BridgeContextWindows from '../settings/BridgeContextWindows';
import ProviderBinaryPath from './ProviderBinaryPath';
import { providerEnabledView } from './providerEnabledState';
import ProviderTestRunModal, { type ProviderTestTarget } from './ProviderTestRunModal';

const fieldClass =
  'min-w-0 w-full rounded-[var(--radius-md)] border border-subtle bg-[var(--color-border-subtle)] px-3 py-2 text-sm text-primary focus-visible:outline-none focus-visible:border-accent focus-visible:shadow-focus disabled:opacity-50';
const runtimeFieldClass = fieldClass + ' font-[family-name:var(--font-mono)]';
// Profile accents are serialized hex values, independent of the active theme.
const defaultAccent = '#9c9c9c';
const newProfile = (provider: string, used: string[]): ProviderProfile => ({
  profile_id: generateProfileId(provider, used),
  provider,
  label_enc: '',
  accent: defaultAccent,
  enabled: true,
  environment: [],
  config: {},
});

export function ProfileRuntimeEditor({
  profile,
  onChange,
  disabled = false,
  onValidationChange,
}: {
  profile: ProviderProfile;
  onChange: (p: ProviderProfile) => void;
  disabled?: boolean;
  onValidationChange?: (error: string) => void;
}) {
  const config = (key: keyof ProviderProfile['config'], value: unknown) =>
    onChange({ ...profile, config: { ...profile.config, [key]: value } });
  const row = (
    key: keyof ProviderProfile['config'],
    label: string,
    help: string,
    secret = false,
  ) => (
    <label className="block space-y-1">
      <span className="text-sm font-medium">{label}</span>
      <input
        className={runtimeFieldClass}
        data-debug-id={'profile-config-' + key}
        type={secret ? 'password' : 'text'}
        autoComplete="off"
        disabled={disabled}
        value={String(profile.config[key] || '')}
        placeholder={
          secret && profile.config.api_key_redacted
            ? 'Stored secret, enter a new value to replace'
            : undefined
        }
        onChange={(e) => {
          if (secret)
            onChange({
              ...profile,
              config: {
                ...profile.config,
                api_key: e.target.value,
                api_key_redacted: profile.config.api_key_redacted,
              },
            });
          else config(key, e.target.value);
        }}
      />
      <span className="block text-xs text-muted">{help}</span>
      {secret && profile.config.api_key_redacted ? (
        <button
          type="button"
          disabled={disabled}
          className="text-xs text-danger"
          data-debug-id="profile-api-key-clear"
          onClick={() =>
            onChange({
              ...profile,
              config: { ...profile.config, api_key: '', api_key_redacted: false },
            })
          }
        >
          Clear stored secret
        </button>
      ) : null}
    </label>
  );
  const [directoryMode, setDirectoryMode] = useState(() =>
    configDirectoryMode(profile.config.config_dir),
  );
  const randomDirectory = useRef(directoryMode === 'random' ? profile.config.config_dir || '' : '');
  const customDirectory = useRef(directoryMode === 'custom' ? profile.config.config_dir || '' : '');
  const directoryError =
    profile.provider === 'claude' &&
    directoryMode === 'custom' &&
    !profile.config.config_dir?.trim()
      ? 'Enter a custom config directory.'
      : '';
  useEffect(() => {
    onValidationChange?.(directoryError);
  }, [directoryError, onValidationChange]);
  const changeDirectoryMode = (mode: ConfigDirectoryMode) => {
    if (directoryMode === 'custom') customDirectory.current = profile.config.config_dir || '';
    if (mode === 'random' && !randomDirectory.current)
      randomDirectory.current = generateConfigDirectory();
    setDirectoryMode(mode);
    config(
      'config_dir',
      mode === 'inherit'
        ? ''
        : mode === 'random'
          ? randomDirectory.current
          : customDirectory.current,
    );
  };
  const [args, setArgs] = useState(() => decodeProfileArgs(profile.config.launch_args));
  const changeArgs = (next: string[]) => {
    setArgs(next);
    config('launch_args', encodeProfileArgs(next, false));
  };
  const env = (index: number, patch: Partial<ProfileEnv>) =>
    onChange({
      ...profile,
      environment: profile.environment.map((e, i) => (i === index ? { ...e, ...patch } : e)),
    });
  return (
    <fieldset disabled={disabled} className="min-w-0 space-y-6">
      <section className="space-y-3">
        <Text as="h2" role="heading">Runtime</Text>
        {row('binary_path', 'Binary', 'Optional executable name or absolute path on this bridge.')}
        {profile.provider === 'claude' ? (
          <div className="space-y-2">
            <label className="block space-y-1">
              <span className="text-sm font-medium">Config directory</span>
              <select
                className={runtimeFieldClass}
                data-debug-id="profile-config-dir-mode"
                value={directoryMode}
                onChange={(e) => changeDirectoryMode(e.target.value as ConfigDirectoryMode)}
              >
                <option data-debug-id="profile-config-dir-mode-inherit" value="inherit">
                  Inherit
                </option>
                <option data-debug-id="profile-config-dir-mode-random" value="random">
                  Random
                </option>
                <option data-debug-id="profile-config-dir-mode-custom" value="custom">
                  Custom
                </option>
              </select>
            </label>
            {directoryMode !== 'inherit' ? (
              <label className="block space-y-1">
                <span className="text-xs text-muted">
                  {directoryMode === 'random'
                    ? 'Directory on bridge'
                    : 'Custom directory on bridge'}
                </span>
                <input
                  className={runtimeFieldClass}
                  data-debug-id="profile-config-config_dir"
                  autoComplete="off"
                  readOnly={directoryMode === 'random'}
                  value={profile.config.config_dir || ''}
                  required={directoryMode === 'custom'}
                  aria-invalid={Boolean(directoryError)}
                  onChange={(e) => config('config_dir', e.target.value)}
                />
              </label>
            ) : null}
            <p className="text-xs text-muted">
              {directoryMode === 'inherit'
                ? 'Use the bridge’s default Claude configuration.'
                : directoryMode === 'random'
                  ? 'A new private directory is created on save. Sign in once for this profile. The directory stays the same when reopened.'
                  : 'Sets CLAUDE_CONFIG_DIR. Use an absolute path or ~ for the bridge home.'}
            </p>
            {directoryError ? (
              <p role="alert" className="text-xs text-danger">
                {directoryError}
              </p>
            ) : null}
          </div>
        ) : null}
        {profile.provider === 'codex' ? (
          <>
            {row('home_path', 'Codex home', 'Sets CODEX_HOME. Leave blank to inherit.')}
            {row(
              'shadow_home_path',
              'Shadow home',
              'Optional private Codex overlay with its own authentication and state.',
            )}
          </>
        ) : null}
        {profile.provider === 'antigravity' ? (
          <>
            <label className="block text-sm">
              Authentication
              <select
                className={runtimeFieldClass}
                data-debug-id="profile-auth-method"
                value={profile.config.auth_method || ''}
                onChange={(e) => config('auth_method', e.target.value)}
              >
                <option value="">Default</option>
                {['oauth-personal', 'oauth-business', 'gemini-api-key', 'agent-platform'].map(
                  (m) => (
                    <option key={m}>{m}</option>
                  ),
                )}
              </select>
            </label>
            {row('api_key', 'API key', 'Stored as a secret on this bridge.', true)}
            {row('gcp_project', 'Google Cloud project', 'Used with agent-platform authentication.')}
            {row(
              'gcp_location',
              'Google Cloud location',
              'Used with agent-platform authentication.',
            )}
          </>
        ) : (
          <section className="space-y-2">
            <h4 className="text-sm font-medium">Launch arguments</h4>
            <p className="text-xs text-muted">
              One literal argument per row. No shell expansion; up to 32 arguments.
            </p>
            {args.map((arg, i) => (
              <div className="flex gap-2" key={i}>
                <input
                  aria-label={'Argument ' + (i + 1)}
                  data-debug-id={'profile-arg-' + i}
                  className={runtimeFieldClass}
                  value={arg}
                  onChange={(e) => changeArgs(args.map((a, j) => (j === i ? e.target.value : a)))}
                />
                <button
                  type="button"
                  data-debug-id={'profile-arg-remove-' + i}
                  aria-label={'Remove argument ' + (i + 1)}
                  onClick={() => changeArgs(args.filter((_, j) => j !== i))}
                >
                  Remove
                </button>
              </div>
            ))}
            <button
              type="button"
              data-debug-id="profile-arg-add"
              disabled={args.length >= 32}
              className="text-sm text-accent"
              onClick={() => changeArgs([...args, ''])}
            >
              Add argument
            </button>
          </section>
        )}
      </section>
      <section className="space-y-3">
        <Text as="h2" role="heading">Environment</Text>
        {profile.environment.map((entry, i) => (
          <div
            key={i}
            className="space-y-2 rounded-lg border border-subtle p-3"
            data-debug-id={'profile-env-row-' + i}
          >
            <div className="grid gap-2 sm:grid-cols-2">
              <input
                aria-label={'Variable name ' + (i + 1)}
                className={runtimeFieldClass}
                data-debug-id={'profile-env-name-' + i}
                value={entry.name}
                disabled={disabled || Boolean(entry.value_redacted)}
                onChange={(e) => env(i, { name: e.target.value })}
              />
              <input
                aria-label={'Variable value ' + (i + 1)}
                type={entry.sensitive ? 'password' : 'text'}
                autoComplete="off"
                className={runtimeFieldClass}
                data-debug-id={'profile-env-value-' + i}
                placeholder={
                  entry.value_redacted ? 'Stored secret, enter a new value to replace' : 'Value'
                }
                value={entry.value}
                onChange={(e) => env(i, { value: e.target.value })}
              />
            </div>
            <div className="flex flex-wrap items-center gap-3 text-xs">
              <label className="flex items-center gap-1">
                <input
                  type="checkbox"
                  data-debug-id={'profile-env-sensitive-' + i}
                  checked={entry.sensitive}
                  disabled={disabled || Boolean(entry.value_redacted && !entry.value)}
                  onChange={(e) => env(i, { sensitive: e.target.checked, value_redacted: false })}
                />
                Sensitive
              </label>
              {entry.value_redacted ? (
                <button
                  type="button"
                  className="text-danger"
                  data-debug-id={'profile-env-clear-' + i}
                  onClick={() => env(i, { value: '', value_redacted: false, keep: false })}
                >
                  Clear stored secret
                </button>
              ) : null}
              <button
                type="button"
                className="text-danger"
                data-debug-id={'profile-env-remove-' + i}
                onClick={() =>
                  onChange({
                    ...profile,
                    environment: profile.environment.filter((_, j) => j !== i),
                  })
                }
              >
                Remove variable
              </button>
            </div>
          </div>
        ))}
        <button
          type="button"
          className="text-sm text-accent"
          data-debug-id="profile-env-add"
          onClick={() =>
            onChange({
              ...profile,
              environment: [...profile.environment, { name: '', value: '', sensitive: true }],
            })
          }
        >
          Add variable
        </button>
        <p className="text-xs text-muted">
          Stored on this bridge only; never sent to or kept by the hub. Empty replacement keeps a
          stored secret; use Clear to erase it.
        </p>
      </section>
      {profile.provider !== 'antigravity' ? (
        <section className="space-y-2">
          <Text as="h2" role="heading">Models</Text>
          <label className="block text-sm">
            Custom model IDs
            <textarea
              className={runtimeFieldClass}
              rows={3}
              data-debug-id="profile-custom-models"
              value={(profile.config.custom_models || []).join('\n')}
              onChange={(e) => config('custom_models', e.target.value.split('\n'))}
            />
            <span className="text-xs text-muted">
              One model ID per line, in addition to discovered models.
            </span>
          </label>
        </section>
      ) : null}
    </fieldset>
  );
}

export default function ProviderProfilesSurface({ bridge, onHeadingChange }: {
  bridge: any;
  onHeadingChange?: (heading: ProviderSettingsHeading) => void;
}) {
  const bridgeId = String(bridge?.bridge_id || bridge?.id || '');
  const unlocked = useSelector(selectIsVaultUnlocked);
  const editable = unlocked && bridge?.status === 'online' && bridge?.vault_status === 'unlocked';
  const editableRef = useRef(editable);
  editableRef.current = editable;
  const dispatch = useDispatch();
  const [profiles, setProfiles] = useState<ProfileMetadata[]>([]);
  const [statuses, setStatuses] = useState<BridgeProviderStatus[]>([]);
  const [labels, setLabels] = useState<Record<string, string>>({});
  const [selected, setSelected] = useState('');
  const [draft, setDraft] = useState<ProviderProfile | null>(null);
  const [label, setLabel] = useState('');
  const [step, setStep] = useState<number | null>(null);
  const [busy, setBusy] = useState(false);
  const [loaded, setLoaded] = useState(false);
  const [error, setError] = useState('');
  const [runtimeError, setRuntimeError] = useState('');
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [savedDraft, setSavedDraft] = useState<ProviderProfile | null>(null);
  const [savedLabel, setSavedLabel] = useState('');
  const [testModelId, setTestModelId] = useState('');
  const [testTarget, setTestTarget] = useState<ProviderTestTarget | null>(null);
  const [revision, setRevision] = useState(0);
  const refresh = () => {
    setRevision((v) => v + 1);
    dispatch(heimdallApi.util.invalidateTags([{ type: 'BridgeProviders', id: bridgeId }]));
  };
  useEffect(() => {
    let cancelled = false;
    setLoaded(false);
    void Promise.all([providerProfilesApi.list(bridgeId), providerSetupApi.get(bridgeId, true)])
      .then(async ([metadata, status]) => {
        const rows = [...metadata];
        for (const s of status.providers)
          if (!rows.some((p) => p.profile_id === (s.profile_id || s.provider)))
            rows.push({
              profile_id: s.profile_id || s.provider,
              provider: s.provider,
              label_enc: s.label_enc || '',
              accent: s.accent || '',
              enabled: s.enabled,
              state: s.profile_state,
            });
        const names = await Promise.all(
          rows.map(async (p) => [
            p.profile_id,
            await profileLabel(
              p,
              p.profile_id === p.provider
                ? status.providers.find((s) => s.provider === p.provider)?.display_name
                : '',
            ),
          ]),
        );
        if (!cancelled) {
          setProfiles(rows);
          setStatuses(status.providers);
          setLabels(Object.fromEntries(names));
          setLoaded(true);
        }
      })
      .catch((e) => {
        if (!cancelled) {
          setError(apiErrorText(e));
          setLoaded(true);
        }
      });
    return () => {
      cancelled = true;
    };
  }, [bridgeId, revision, unlocked]);
  useEffect(() => {
    if (!editable) {
      setDraft(null);
      setSelected('');
      setStep(null);
      setLabel('');
    }
  }, [editable]);
  async function edit(p: ProfileMetadata) {
    setBusy(true);
    setError('');
    setDraft(null);
    setConfirmDelete(false);
    setSelected(p.profile_id);
    setTestModelId('');
    setStep(null);
    try {
      const full = await providerProfilesApi.operate(bridgeId, p.profile_id, 'get');
      if (full && editableRef.current) {
        // Edit persisted configuration; runtime availability is an independent projection.
        setDraft(full);
        setSavedDraft(full);
        setSavedLabel(labels[p.profile_id] || p.profile_id);
        setLabel(labels[p.profile_id] || p.profile_id);
      }
    } catch (e) {
      setError(apiErrorText(e));
    } finally {
      setBusy(false);
    }
  }
  async function save() {
    if (!draft) return;
    if (runtimeError) {
      setError(runtimeError);
      return;
    }
    setBusy(true);
    setError('');
    try {
      const identityError = profileIdentityError(
        draft.profile_id,
        label,
        draft.accent,
        step !== null ? profiles.map((p) => p.profile_id) : [],
        step !== null ? drivers : [],
      );
      if (
        identityError &&
        !(
          step === null &&
          draft.profile_id === draft.provider &&
          identityError.includes('reserved')
        )
      )
        throw new Error(identityError);
      await providerProfilesApi.operate(bridgeId, draft.profile_id, 'upsert', {
        ...draft,
        profile_id: undefined,
        label_enc: await encryptVaultText(label.trim()),
        environment: environmentForSave(draft.environment),
        config: {
          ...draft.config,
          api_key_redacted: Boolean(draft.config.api_key_redacted && !draft.config.api_key),
          launch_args: encodeProfileArgs(decodeProfileArgs(draft.config.launch_args)),
          custom_models: (draft.config.custom_models || []).map((s) => s.trim()).filter(Boolean),
        },
      });
      const saved = draft;
      setDraft(null);
      setLabel('');
      setSelected('');
      setStep(null);
      refresh();
      // The legacy enable setting can override registry metadata. Existing rows
      // need its enablement updated too; new custom profiles default to enabled.
      if (step === null && currentStatus && currentStatus.enabled !== saved.enabled) {
        try {
          if (saved.enabled)
            await cookieMutation(
              '/bridges/' + encodeURIComponent(bridgeId) + '/providers/discover',
              'POST',
              { stage: 'providers', providers: [saved.provider], profile_id: saved.profile_id },
            );
          await cookieMutation(
            '/bridges/' +
              encodeURIComponent(bridgeId) +
              '/providers/' +
              encodeURIComponent(saved.provider),
            'PUT',
            { enabled: saved.enabled, profile_id: saved.profile_id },
          );
        } catch (e) {
          setError('Profile saved, but enablement could not be updated: ' + apiErrorText(e));
        }
      }
      refresh();
      const id = saved.profile_id;
      // Fetch a redacted view after save so replacement secrets leave React state.
      const full = await providerProfilesApi.operate(bridgeId, id, 'get');
      if (full && editableRef.current) {
        setDraft(full);
        setSavedDraft(full);
        const savedName = await profileLabel(full);
        setLabel(savedName);
        setSavedLabel(savedName);
        setSelected(id);
      }
    } catch (e) {
      setError(apiErrorText(e));
    } finally {
      setBusy(false);
    }
  }
  async function removeOrReset() {
    if (!draft) return;
    setBusy(true);
    setError('');
    try {
      await providerProfilesApi.operate(
        bridgeId,
        draft.profile_id,
        draft.profile_id === draft.provider ? 'reset' : 'remove',
      );
      setDraft(null);
      setLabel('');
      setSelected('');
      setConfirmDelete(false);
      refresh();
    } catch (e: any) {
      setError(
        e?.code === 'profile_in_use'
          ? 'This profile is in use. Change the referenced agents and fleet rows before deleting it. ' +
              JSON.stringify(e.details || {})
          : apiErrorText(e),
      );
    } finally {
      setBusy(false);
    }
  }
  async function discover(stage: string) {
    setBusy(true);
    setError('');
    try {
      await cookieMutation(
        '/bridges/' + encodeURIComponent(bridgeId) + '/providers/discover',
        'POST',
        { stage, ...(draft ? { providers: [draft.provider], profile_id: draft.profile_id } : {}) },
      );
      refresh();
    } catch (e) {
      setError(apiErrorText(e));
    } finally {
      setBusy(false);
    }
  }
  const drivers = Array.from(new Set(statuses.map((s) => s.provider))).sort();
  const currentStatus = statuses.find(
    (s) => s.provider === draft?.provider && (s.profile_id || s.provider) === draft?.profile_id,
  );
  // Single fix for "profile enabled, disabled on this bridge": set the bridge flag only.
  async function enableOnBridge() {
    if (!draft) return;
    setBusy(true);
    setError('');
    try {
      await cookieMutation(
        '/bridges/' + encodeURIComponent(bridgeId) + '/providers/' + encodeURIComponent(draft.provider),
        'PUT',
        { enabled: true, profile_id: draft.profile_id },
      );
      refresh();
    } catch (e) {
      setError('Could not enable on this bridge: ' + apiErrorText(e));
    } finally {
      setBusy(false);
    }
  }
  const testModels = (currentStatus?.models || []).filter((m) => m.state === 'active');
  const testModel = testModels.find((m) => m.model_id === testModelId) || testModels[0];
  const draftChanged = Boolean(
    draft && (JSON.stringify(draft) !== JSON.stringify(savedDraft) || label !== savedLabel),
  );
  const editing = Boolean(draft || selected || step !== null);
  const bridgeName = String(bridge?.label || bridge?.machine_hostname || bridgeId);
  const title = editing ? step !== null ? 'Add provider' : label || selected : bridgeName;
  const description = editing ? `Provider profile and runtime settings on ${bridgeName}.`
    : 'Provider profiles and runtime settings on this bridge.';
  const breadcrumb = editing ? bridgeName + ' / ' + (draft?.provider || selected) : 'Settings / Providers';
  const focusKey = bridgeId + '/' + (editing ? step !== null ? 'new' : selected : 'list');
  useLayoutEffect(() => {
    onHeadingChange?.({ title, description, breadcrumb, focusKey });
  }, [onHeadingChange, title, description, breadcrumb, focusKey]);
  const closeEditor = () => {
    setDraft(null);
    setLabel('');
    setStep(null);
    setSelected('');
    setConfirmDelete(false);
    setRuntimeError('');
  };
  return (
    <div data-debug-id="provider-profiles" className="min-w-0 w-full space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        {editing ? <Button variant="secondary" data-debug-id="profile-back-to-list" disabled={busy} onClick={closeEditor}>← Back to providers</Button> : (
        <Button
          data-debug-id="profile-add"
          disabled={!editable || busy || !drivers.length}
          onClick={() => {
            const p = newProfile(
              drivers[0],
              profiles.map((p) => p.profile_id),
            );
            setDraft(p);
            setLabel('');
            setSelected('');
            setStep(0);
            setError('');
            setRuntimeError('');
            setConfirmDelete(false);
          }}
        >
          Add provider
        </Button>
        )}
      </div>
      {!editing ? <div className="flex flex-wrap items-center gap-3">
        <StatusPill tone={bridge?.status === 'online' ? 'success' : 'neutral'}>{bridge?.status === 'online' ? 'Online' : 'Offline'}</StatusPill>
        <StatusPill>Vault {bridge?.vault_status || 'unknown'}</StatusPill>
        <Text role="code" tone="muted">{bridge?.machine_hostname || bridgeId}</Text>
      </div> : null}
      {!editable ? (
        <p
          className="rounded-lg bg-neutral-soft p-3 text-sm text-muted"
          data-debug-id="profile-locked"
        >
          Connect and unseal this bridge, and unlock this device, to edit profiles.
        </p>
      ) : null}
      {error ? (
        <p role="alert" className="rounded-lg border border-danger/30 p-3 text-sm text-danger">
          {error}
        </p>
      ) : null}
      {!loaded ? <Spinner size="sm" /> : null}
      <div className="min-w-0">
        {!editing ? <div className="space-y-4" data-debug-id="profiles-list">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <Text as="h2" role="heading">Provider profiles</Text>
            <Button variant="secondary" size="sm" data-debug-id="profiles-refresh" disabled={!editable || busy} onClick={() => void discover('providers')}>Scan providers</Button>
          </div>
          <Panel padding="none" className="overflow-hidden">
          {drivers.flatMap((driver) => profiles.filter((p) => p.provider === driver))
                .map((p) => {
                  const s = statuses.find((s) => (s.profile_id || s.provider) === p.profile_id);
                  return (
                    <button
                      key={p.profile_id}
                      type="button"
                      data-debug-id={'profile-select-' + p.profile_id}
                      disabled={!editable || busy}
                      onClick={() => void edit(p)}
                      className={
                        'flex w-full flex-wrap items-center gap-3 border-b border-subtle p-4 text-left last:border-b-0 hover:bg-neutral-soft focus-visible:outline-none focus-visible:shadow-focus disabled:cursor-not-allowed disabled:opacity-50'
                      }
                    >
                      <span className="flex min-w-0 flex-1 items-center gap-3">
                        <span
                          className="h-2 w-2 rounded-full"
                          style={{ backgroundColor: p.accent || 'var(--color-text-muted)' }}
                        />
                        <span className="min-w-0 break-words">
                        <Text as="span" role="title" className="block">{labels[p.profile_id] || p.profile_id}</Text>
                        <span className="block text-xs text-muted">
                        {(() => { const ev = providerEnabledView(p.enabled, s?.enabled); return ev.label + (ev.reason ? ' (' + ev.reason + ')' : ''); })()} ·{' '}
                        {p.state && p.state !== 'ok' ? p.state : s?.state || 'Not checked'}
                        {s?.version_text ? ' · ' + s.version_text : ''}
                        </span>
                        <ProviderBinaryPath provider={p.profile_id} status={s} hasOverride={!!p.has_binary} />
                        </span>
                      </span>
                      {p.profile_id === p.provider ? <Badge>Default</Badge> : <Text role="code" tone="muted" className="break-all">{p.profile_id}</Text>}
                      <span className="text-sm text-accent">Edit →</span>
                    </button>
                  );
                })}
          {loaded && !profiles.length ? <Text role="body" tone="muted" className="p-4">No provider profiles reported. Scan providers when this bridge is connected and unlocked.</Text> : null}
          </Panel>
          <Text role="body-sm" tone="muted">Edit a default provider to change its overrides, or add a profile for a separate account. Default providers can be reset; additional profiles can be deleted.</Text>
        </div> : null}
        {editing ? <div className="min-w-0">
          {draft ? (
            <div
              className="min-w-0 space-y-6 rounded-[var(--radius-lg)] border border-subtle bg-surface-raised p-4 sm:p-6"
              data-debug-id="profile-editor"
            >
              {step !== null ? (
                <nav aria-label="Add provider progress" data-debug-id="profile-wizard-step">
                  <ol className="grid grid-cols-3 gap-2">
                    {['Provider', 'Identity', 'Config'].map((name, index) => (
                      <li key={name} aria-current={index === step ? 'step' : undefined}
                        className={'flex min-w-0 flex-col gap-2 rounded-lg p-3 text-sm sm:flex-row sm:items-center ' +
                          (index === step ? 'bg-neutral-soft text-primary' : 'text-muted')}>
                        <span aria-hidden="true" className={'flex h-7 w-7 shrink-0 items-center justify-center rounded-full border text-xs font-medium ' +
                          (index < step ? 'border-success text-success' : index === step ? 'border-accent text-accent' : 'border-subtle')}>{index + 1}</span>
                        <span className="min-w-0">
                          <span className="block font-medium">{name}</span>
                          <span className="block text-xs text-muted">{index < step ? 'Completed' : index === step ? 'Current step' : 'Upcoming'}</span>
                        </span>
                      </li>
                    ))}
                  </ol>
                </nav>
              ) : (
                <Text as="h2" role="heading">Identity</Text>
              )}
              {step !== 0 ? (
                <Panel className="flex flex-wrap items-center justify-between gap-4" data-debug-id="profile-enablement">
                  <div className="min-w-0">
                    <Text role="title">Profile availability</Text>
                    <Text role="body-sm" tone="muted">Configure whether this profile allows new launches. Save profile to apply changes.</Text>
                  </div>
                  <div className="flex flex-wrap items-center gap-3">
                    <Text role="caption" tone="muted" data-debug-id="profile-runtime-availability">Runtime availability: {currentStatus ? currentStatus.enabled ? 'Enabled' : 'Disabled' : 'Not reported'}</Text>
                    {(() => {
                      // Same effective state as the list row, from the saved profile flag.
                      const ev = providerEnabledView(draft.enabled, currentStatus?.enabled);
                      return (
                        <>
                          <StatusPill tone={ev.enabled ? 'success' : 'neutral'}>{ev.label}</StatusPill>
                          {ev.reason ? <Text role="caption" tone="muted" data-debug-id="profile-enabled-reason">{ev.reason}</Text> : null}
                          {ev.fix === 'enable_on_bridge' && savedDraft?.enabled === draft.enabled ? (
                            <Button variant="secondary" data-debug-id="profile-enable-on-bridge" disabled={busy || !editable}
                              onClick={() => void enableOnBridge()}>{ev.fixLabel}</Button>
                          ) : null}
                        </>
                      );
                    })()}
                    {step !== null || savedDraft?.enabled !== draft.enabled
                      ? <Text role="caption" tone="muted">Pending save</Text> : null}
                    <Button variant="secondary" data-debug-id="profile-enabled" aria-pressed={draft.enabled}
                      disabled={busy || !editable} onClick={() => setDraft({ ...draft, enabled: !draft.enabled })}>
                      {draft.enabled ? 'Disable profile' : 'Enable profile'}
                    </Button>
                  </div>
                </Panel>
              ) : null}
              {step === 0 ? (
                <label className="block text-sm">
                  Provider
                  <select
                    className={fieldClass}
                    data-debug-id="profile-driver"
                    value={draft.provider}
                    onChange={(e) => {
                      setDraft(
                        newProfile(
                          e.target.value,
                          profiles.map((p) => p.profile_id),
                        ),
                      );
                      setLabel('');
                    }}
                  >
                    {drivers.map((d) => (
                      <option key={d}>{d}</option>
                    ))}
                  </select>
                </label>
              ) : null}
              {step === 1 || step === null ? (
                <div className="space-y-3">
                  <label className="block text-sm">
                    Label
                    <input
                      className={fieldClass}
                      data-debug-id="profile-label"
                      value={label}
                      maxLength={256}
                      disabled={busy}
                      onChange={(e) => setLabel(e.target.value)}
                    />
                  </label>
                  <label className="block text-sm">
                    Profile ID
                    <input
                      className={runtimeFieldClass}
                      data-debug-id="profile-id"
                      value={draft.profile_id}
                      disabled={step === null || busy}
                      onChange={(e) => setDraft({ ...draft, profile_id: e.target.value })}
                    />
                    <span className="text-xs text-muted">
                      The profile ID is visible to the hub; the label is encrypted.
                    </span>
                  </label>
                  <label className="flex flex-wrap items-center gap-3 text-sm">
                    <span>Accent</span>
                    <input
                      type="color"
                      className="h-10 w-16 shrink-0 cursor-pointer rounded-lg border border-subtle bg-surface-raised p-1 focus-visible:outline-none focus-visible:shadow-focus disabled:opacity-50"
                      data-debug-id="profile-accent"
                      disabled={busy}
                      value={draft.accent || defaultAccent}
                      onChange={(e) => setDraft({ ...draft, accent: e.target.value })}
                    />
                  </label>
                </div>
              ) : null}
              {step === 2 || step === null ? (
                <>
                  <ProfileRuntimeEditor
                    key={draft.profile_id}
                    profile={draft}
                    onChange={setDraft}
                    onValidationChange={setRuntimeError}
                    disabled={busy}
                  />
                  {step === null ? (
                    <section className="space-y-2">
                      <Text as="h2" role="heading">Status and setup</Text>
                      <p className="text-sm text-muted">
                        {currentStatus?.state || 'Not checked'} ·{' '}
                        {currentStatus?.version_text || 'No version reported'}
                      </p>
                      <ProviderBinaryPath provider={draft.profile_id} status={currentStatus} overridePath={draft.config.binary_path || ''} />
                      <p className="text-xs text-muted">
                        Sign in with the provider CLI using this profile’s runtime directory. Then
                        scan again.
                      </p>
                      <div className="flex flex-wrap gap-2">
                        <Button
                          size="sm"
                          variant="secondary"
                          data-debug-id="profile-discover"
                          disabled={busy || !draft.enabled}
                          onClick={() => void discover('providers')}
                        >
                          Check provider
                        </Button>
                        <Button
                          size="sm"
                          variant="secondary"
                          data-debug-id="profile-model-refresh"
                          disabled={busy || !draft.enabled}
                          onClick={() => void discover('models')}
                        >
                          Refresh models
                        </Button>
                      </div>
                      <div className="space-y-2 border-t border-subtle pt-3">
                        <label className="block space-y-1 text-sm">
                          <span>Test model</span>
                          <select
                            className={fieldClass}
                            data-debug-id="profile-test-model"
                            disabled={busy || !testModels.length}
                            value={testModel?.model_id || ''}
                            onChange={(e) => setTestModelId(e.target.value)}
                          >
                            {!testModels.length ? (
                              <option value="">Check provider or refresh models first</option>
                            ) : null}
                            {testModels.map((m) => (
                              <option key={m.model_id} value={m.model_id}>
                                {m.label || m.model_id}
                              </option>
                            ))}
                          </select>
                        </label>
                        <Button
                          size="sm"
                          variant="secondary"
                          data-debug-id="profile-test"
                          disabled={
                            busy ||
                            draftChanged ||
                            !draft.enabled ||
                            !currentStatus?.enabled ||
                            currentStatus.state !== 'present' ||
                            !testModel
                          }
                          onClick={() => {
                            if (!testModel || draftChanged) return;
                            setTestTarget({
                              provider: draft.provider,
                              profileId: draft.profile_id,
                              providerLabel: label,
                              modelId: testModel.model_id,
                              modelLabel: testModel.label || testModel.model_id,
                              binaryPath: '',
                            });
                          }}
                        >
                          Test profile
                        </Button>
                        <p className="text-xs text-muted">
                          {draftChanged
                            ? 'Save your changes before testing this profile.'
                            : 'Run the saved profile in a live terminal. You can sign in or configure it there when your plan allows terminal input.'}
                        </p>
                      </div>
                      <ProviderExtensionInstallAction
                        layout="editor"
                        bridgeId={bridgeId}
                        provider={draft.provider}
                        profileId={draft.profile_id}
                        extension={currentStatus?.extension || null}
                        online={editable}
                        disabled={busy}
                        onComplete={refresh}
                        onRetryDiscovery={() => discover('providers')}
                      />
                      <div className="border-t border-subtle pt-3" data-debug-id="profile-context-windows">
                        <BridgeContextWindows bridgeId={bridgeId} online={bridge?.status === 'online'} provider={draft.provider} />
                      </div>
                    </section>
                  ) : null}
                </>
              ) : null}
              <div className="flex flex-wrap items-center gap-2 border-t border-subtle pt-3">
                {step !== null ? (
                  <Button
                    variant="secondary"
                    data-debug-id="profile-back"
                    disabled={busy || step === 0}
                    onClick={() => setStep(step - 1)}
                  >
                    Back
                  </Button>
                ) : null}
                {step !== null && step < 2 ? (
                  <Button
                    data-debug-id="profile-next"
                    disabled={busy}
                    onClick={() => {
                      const err =
                        step === 1
                          ? profileIdentityError(
                              draft.profile_id,
                              label,
                              draft.accent,
                              profiles.map((p) => p.profile_id),
                              drivers,
                            )
                          : '';
                      setError(err);
                      if (!err) setStep(step + 1);
                    }}
                  >
                    Next
                  </Button>
                ) : (
                  <Button
                    data-debug-id="profile-save"
                    disabled={busy || !editable}
                    onClick={() => void save()}
                  >
                    {busy ? 'Saving…' : 'Save profile'}
                  </Button>
                )}
                <Button
                  variant="secondary"
                  data-debug-id="profile-cancel"
                  disabled={busy}
                  onClick={closeEditor}
                >
                  Cancel
                </Button>
                {step === null ? (
                  <Button
                    variant="secondary"
                    data-debug-id="profile-delete-reset"
                    disabled={busy}
                    onClick={() => setConfirmDelete(true)}
                  >
                    {draft.profile_id === draft.provider ? 'Reset overrides' : 'Delete profile'}
                  </Button>
                ) : null}
              </div>
              {confirmDelete ? (
                <div className="space-y-2 text-sm">
                  <p>
                    {draft.profile_id === draft.provider
                      ? 'Clear runtime, environment and label overrides? Enablement is kept.'
                      : 'Delete this profile and its stored secrets? Runtime directories are kept.'}
                  </p>
                  <Button
                    variant="danger"
                    data-debug-id="profile-delete-confirm"
                    disabled={busy}
                    onClick={() => void removeOrReset()}
                  >
                    Confirm
                  </Button>
                  <Button
                    variant="secondary"
                    data-debug-id="profile-delete-cancel"
                    disabled={busy}
                    onClick={() => setConfirmDelete(false)}
                  >
                    Keep profile
                  </Button>
                </div>
              ) : null}
            </div>
          ) : (
            <p className="p-4 text-sm text-muted">
              {busy ? 'Loading profile…' : 'Choose a profile to edit its runtime and environment.'}
            </p>
          )}
        </div> : null}
      </div>
      {testTarget ? (
        <ProviderTestRunModal
          target={testTarget}
          setup={{ bridge: { bridge_id: bridgeId }, providers: statuses } as any}
          onClose={() => setTestTarget(null)}
        />
      ) : null}
    </div>
  );
}
