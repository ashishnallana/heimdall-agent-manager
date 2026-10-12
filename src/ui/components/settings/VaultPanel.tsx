import React, { useState, useEffect, useCallback, type FormEvent } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import {
  PageShell,
  Panel,
  Button,
  Input,
  Textarea,
  Checkbox,
  StatusPill,
  Badge,
  Icon,
  Text,
  Modal,
  Tabs,
} from '@ui';
import {
  selectIsVaultConfigured,
  selectIsVaultUnlocked,
  setVaultConfigured,
  setVaultUnlocked,
  setActiveBridgeVaultKeyMaterial,
  lockVault,
  VAULT_UNSUPPORTED_TITLE,
  VAULT_UNSUPPORTED_REASON,
} from '../../store/vaultSlice';
import {
  useGetUserVaultQuery,
  useSetUserVaultMutation,
} from '../../api/endpoints/userVault';
import {
  unsealAllConnectedBridges,
  lockAllConnectedBridges,
} from '../../api/endpoints/bridges';
import {
  generateVaultKey,
  exportRawKeyHex,
  deriveKeyFromPassword,
  generate12RecoveryWords,
  validateRecoveryWords,
  deriveKeyFromRecoveryWords,
  encryptVaultKeyEnvelope,
  decryptVaultKeyEnvelope,
  generateSaltHex,
  DEFAULT_KDF_ITERATIONS,
  isVaultSupported,
} from '../../utils/vaultCrypto';

async function copyTextToClipboard(text: string): Promise<boolean> {
  try {
    if (navigator?.clipboard?.writeText) {
      await navigator.clipboard.writeText(text);
      return true;
    }
  } catch {}
  try {
    const el = document.createElement('textarea');
    el.value = text;
    el.style.position = 'fixed';
    el.style.opacity = '0';
    document.body.appendChild(el);
    el.focus();
    el.select();
    const ok = document.execCommand('copy');
    document.body.removeChild(el);
    return ok;
  } catch {
    return false;
  }
}

/**
 * The vault key is imported as a NON-EXTRACTABLE WebCrypto `CryptoKey`
 * (REQ-VAULT-HARDEN-1), so no raw hex for it exists anywhere this component could
 * read. The key viewer is therefore a status surface, not a key display: it reports
 * that the key is protected and offers no copy affordance for material that cannot
 * exist. Driven by a constant rather than a selector so it cannot silently start
 * rendering key material again.
 */
const VAULT_KEY_PROTECTED_LABEL = 'Protected in WebCrypto (non-extractable)';

/**
 * How bridges get the key. There is no CLI step: the browser delivers the key to each
 * bridge from Settings -> Bridges, and no key file exists on the bridge host.
 */
const VAULT_BRIDGE_INSTRUCTIONS =
  'Bridges receive the key from this browser. Open Settings → Bridges and use Unseal (or Configure encryption) on each bridge you want to encrypt.';

function extractVaultRecord(record: any) {
  if (!record) return null;
  return {
    encryptedVaultKey: record.encrypted_vault_key || record.encryptedVaultKey || '',
    vaultKeyNonce: record.vault_key_nonce || record.vaultKeyNonce || '',
    vaultKeyTag: record.vault_key_tag || record.vaultKeyTag || '',
    kdfSalt: record.kdf_salt || record.kdfSalt || '',
    kdfIterations: Number(record.kdf_iterations || record.kdfIterations || DEFAULT_KDF_ITERATIONS),
    recoveryEncryptedVaultKey: record.recovery_encrypted_vault_key || record.recoveryEncryptedVaultKey || '',
    recoveryNonce: record.recovery_nonce || record.recoveryNonce || '',
    recoveryTag: record.recovery_tag || record.recoveryTag || '',
    recoverySalt: record.recovery_salt || record.recoverySalt || '',
  };
}

export default function VaultPanel() {
  const dispatch = useDispatch();
  const isVaultConfiguredInRedux = useSelector(selectIsVaultConfigured);
  const isUnlocked = useSelector(selectIsVaultUnlocked);

  const { data: vaultData, isLoading: isVaultLoading, refetch: refetchVault } = useGetUserVaultQuery();
  const [setUserVault, { isLoading: isSavingVault }] = useSetUserVaultMutation();

  const isConfigured = Boolean(vaultData?.isConfigured || isVaultConfiguredInRedux);

  // Sync Redux configured state with server query
  useEffect(() => {
    if (vaultData?.isConfigured !== undefined) {
      dispatch(setVaultConfigured(vaultData.isConfigured));
    }
  }, [vaultData?.isConfigured, dispatch]);

  // Setup Wizard State
  const [masterPassword, setMasterPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');
  const [recoveryWords, setRecoveryWords] = useState<string[]>([]);
  const [confirmedBackup, setConfirmedBackup] = useState(false);
  const [setupError, setSetupError] = useState('');
  const [isSubmittingSetup, setIsSubmittingSetup] = useState(false);
  const [copiedWords, setCopiedWords] = useState(false);

  // Unlock View State
  const [unlockMode, setUnlockMode] = useState<'password' | 'recovery'>('password');
  const [unlockPassword, setUnlockPassword] = useState('');
  const [recoveryPhraseInput, setRecoveryPhraseInput] = useState('');
  const [unlockError, setUnlockError] = useState('');
  const [isUnlocking, setIsUnlocking] = useState(false);
  const [isUnlockModalOpen, setIsUnlockModalOpen] = useState(false);

  // Unlocked State View
  const [isKeyVisible, setIsKeyVisible] = useState(false);

  // Initialize 12 recovery words on mount
  useEffect(() => {
    if (recoveryWords.length === 0) {
      const generated = generate12RecoveryWords();
      setRecoveryWords(generated.words);
    }
  }, [recoveryWords.length]);

  const handleRegenerateWords = useCallback(() => {
    const generated = generate12RecoveryWords();
    setRecoveryWords(generated.words);
    setConfirmedBackup(false);
  }, []);

  const handleCopyWords = useCallback(async () => {
    if (recoveryWords.length === 0) return;
    const ok = await copyTextToClipboard(recoveryWords.join(' '));
    if (ok) {
      setCopiedWords(true);
      setTimeout(() => setCopiedWords(false), 2000);
    }
  }, [recoveryWords]);

  // Setup Wizard Submit Handler
  async function handleSetupSubmit(e: FormEvent) {
    e.preventDefault();
    setSetupError('');

    if (!masterPassword) {
      setSetupError('Master Password is required.');
      return;
    }
    if (masterPassword.length < 8) {
      setSetupError('Master Password must be at least 8 characters long.');
      return;
    }
    if (masterPassword !== confirmPassword) {
      setSetupError('Passwords do not match. Please re-enter.');
      return;
    }
    if (!confirmedBackup) {
      setSetupError('Please confirm that you have securely saved your 12 recovery words.');
      return;
    }
    if (recoveryWords.length !== 12) {
      setSetupError('Invalid recovery words. Please regenerate the phrase.');
      return;
    }

    try {
      setIsSubmittingSetup(true);

      // 1. Generate 256-bit symmetric AES-GCM Vault Key (KV)
      const vaultKey = await generateVaultKey();
      const rawHex = await exportRawKeyHex(vaultKey);

      // 2. Derive Master Wrapping Key (KM) from Master Password
      const kdfSalt = generateSaltHex(16);
      const wrappingKey = await deriveKeyFromPassword(masterPassword, kdfSalt, DEFAULT_KDF_ITERATIONS);
      const envelope = await encryptVaultKeyEnvelope(wrappingKey, vaultKey);

      // 3. Derive Recovery Wrapping Key (KR) from 12 recovery words
      const recoverySalt = generateSaltHex(16);
      const recoveryWrappingKey = await deriveKeyFromRecoveryWords(recoveryWords, recoverySalt, DEFAULT_KDF_ITERATIONS);
      const recoveryEnvelope = await encryptVaultKeyEnvelope(recoveryWrappingKey, vaultKey);

      // 4. Persist encrypted envelopes to Hub SQLite backend
      await setUserVault({
        encrypted_vault_key: envelope.ciphertextHex,
        vault_key_nonce: envelope.nonceHex,
        vault_key_tag: envelope.tagHex,
        kdf_algorithm: 'PBKDF2-SHA256',
        kdf_salt: kdfSalt,
        kdf_iterations: DEFAULT_KDF_ITERATIONS,
        recovery_encrypted_vault_key: recoveryEnvelope.ciphertextHex,
        recovery_nonce: recoveryEnvelope.nonceHex,
        recovery_tag: recoveryEnvelope.tagHex,
        recovery_salt: recoverySalt,
      }).unwrap();

      // 5. Update Redux store
      dispatch(setVaultConfigured(true));
      // Pass the CryptoKey, not the hex: the key payload is installed synchronously
      // inside the reducer, so there is no tick in which isUnlocked is true while
      // getActiveVaultKey() is still null (REQ-RAWKEY-A7b). rawHex is still needed
      // below, for the E2EE bridge unseal payload.
      dispatch(setVaultUnlocked(vaultKey));
      setActiveBridgeVaultKeyMaterial(rawHex);
      void unsealAllConnectedBridges(rawHex);

      // Reset sensitive password inputs
      setMasterPassword('');
      setConfirmPassword('');
      void refetchVault();
    } catch (err: any) {
      setSetupError(String(err?.message || err?.error || err || 'Failed to initialize vault'));
    } finally {
      setIsSubmittingSetup(false);
    }
  }

  // Unlock with Master Password
  async function handleUnlockWithPassword(e?: FormEvent) {
    if (e) e.preventDefault();
    setUnlockError('');

    if (!unlockPassword) {
      setUnlockError('Please enter your Master Password.');
      return;
    }

    const record = extractVaultRecord(vaultData?.vault);
    if (!record || !record.encryptedVaultKey) {
      setUnlockError('No encrypted vault envelope found on server.');
      return;
    }

    try {
      setIsUnlocking(true);
      const wrappingKey = await deriveKeyFromPassword(unlockPassword, record.kdfSalt, record.kdfIterations);
      const vaultKey = await decryptVaultKeyEnvelope(
        wrappingKey,
        record.encryptedVaultKey,
        record.vaultKeyNonce,
        record.vaultKeyTag,
        true,
      );
      const rawHex = await exportRawKeyHex(vaultKey);
      dispatch(setVaultUnlocked(vaultKey));
      setActiveBridgeVaultKeyMaterial(rawHex);
      void unsealAllConnectedBridges(rawHex);
      setUnlockPassword('');
      setIsUnlockModalOpen(false);
    } catch (_err) {
      setUnlockError('Incorrect Master Password. Decryption failed.');
    } finally {
      setIsUnlocking(false);
    }
  }

  // Unlock with 12 Recovery Words
  async function handleUnlockWithRecovery(e?: FormEvent) {
    if (e) e.preventDefault();
    setUnlockError('');

    const words = recoveryPhraseInput.trim().toLowerCase().split(/\s+/).filter(Boolean);
    if (words.length !== 12) {
      setUnlockError(`Expected 12 recovery words, but found ${words.length}.`);
      return;
    }

    if (!validateRecoveryWords(words)) {
      setUnlockError('Invalid recovery words or checksum. Please verify all 12 words.');
      return;
    }

    const record = extractVaultRecord(vaultData?.vault);
    if (!record || !record.recoveryEncryptedVaultKey) {
      setUnlockError('No recovery envelope found on server.');
      return;
    }

    try {
      setIsUnlocking(true);
      const recoveryWrappingKey = await deriveKeyFromRecoveryWords(words, record.recoverySalt, record.kdfIterations);
      const vaultKey = await decryptVaultKeyEnvelope(
        recoveryWrappingKey,
        record.recoveryEncryptedVaultKey,
        record.recoveryNonce,
        record.recoveryTag,
        true,
      );
      const rawHex = await exportRawKeyHex(vaultKey);
      dispatch(setVaultUnlocked(vaultKey));
      setActiveBridgeVaultKeyMaterial(rawHex);
      void unsealAllConnectedBridges(rawHex);
      setRecoveryPhraseInput('');
      setIsUnlockModalOpen(false);
    } catch (_err) {
      setUnlockError('Failed to unlock vault with recovery words. Verification failed.');
    } finally {
      setIsUnlocking(false);
    }
  }

  // Unsupported context (REQ-VAULT-UNSUP-4). The bottom-dock badge routes here, so this
  // must explain the situation rather than offering setup/unlock controls that cannot
  // possibly work — every one of them calls crypto.subtle on its first action.
  if (!isVaultSupported()) {
    return (
      <PageShell
        title="User Vault"
        description="Zero-Knowledge client vault with Master Password encryption and 12-word recovery phrase."
      >
        <div data-debug-id="settings-vault-panel" className="space-y-6 text-left">
          <Panel tone="raised" padding="lg" className="border border-subtle">
            <div
              data-debug-id="vault-unsupported-notice"
              className="flex items-start gap-3"
            >
              <Icon name="lock" size="md" className="mt-0.5 text-muted" />
              <div className="space-y-2">
                <div className="flex items-center gap-2">
                  <Text role="title">{VAULT_UNSUPPORTED_TITLE}</Text>
                  <StatusPill tone="neutral" data-debug-id="vault-status-badge">Unsupported</StatusPill>
                </div>
                <p className="text-sm text-muted">{VAULT_UNSUPPORTED_REASON}</p>
                <p className="text-xs text-faint">
                  Browsers expose Web Crypto (<code>crypto.subtle</code>) only in a secure
                  context. Reach this page over HTTPS, or on <code>localhost</code>, and the
                  vault setup and unlock controls become available. No vault data is lost —
                  the vault simply cannot be opened from this origin.
                </p>
              </div>
            </div>
          </Panel>
        </div>
      </PageShell>
    );
  }

  // Loading State
  if (isVaultLoading) {
    return (
      <PageShell
        title="User Vault"
        description="Zero-Knowledge client vault with Master Password encryption and 12-word recovery phrase."
      >
        <div data-debug-id="settings-vault-loading" className="flex items-center justify-center p-12 text-muted">
          <Icon name="refresh" className="animate-spin mr-2" size="md" />
          <span>Loading vault status…</span>
        </div>
      </PageShell>
    );
  }

  // Render Setup Wizard
  const renderSetupWizard = () => (
    <div data-debug-id="vault-setup-wizard" className="space-y-6">
      <Panel tone="raised" padding="lg" className="border border-subtle">
        <div className="flex items-start justify-between gap-4">
          <div>
            <h3 className="text-base font-semibold text-primary">Setup Zero-Knowledge Vault</h3>
            <p className="mt-1 text-sm text-muted">
              Initialize your client vault with a Master Password and 12-word recovery phrase.
              Your secrets are encrypted client-side using a 256-bit AES-GCM key.
            </p>
          </div>
          <Badge tone="warning">Unconfigured</Badge>
        </div>

        <form data-debug-id="vault-setup-form" onSubmit={handleSetupSubmit} className="mt-6 space-y-6">
          {/* Master Password Section */}
          <div className="space-y-4">
            <Text as="div" role="overline" tone="muted">1. Master Password</Text>
            <div className="grid gap-4 sm:grid-cols-2">
              <label className="text-sm font-medium text-primary">
                Master Password
                <Input
                  type="password"
                  data-debug-id="vault-master-password-input"
                  value={masterPassword}
                  onChange={setMasterPassword}
                  placeholder="Enter strong password (min 8 chars)"
                  width="full"
                  className="mt-1.5 min-h-[44px]"
                  disabled={isSubmittingSetup}
                  required
                />
              </label>
              <label className="text-sm font-medium text-primary">
                Confirm Master Password
                <Input
                  type="password"
                  data-debug-id="vault-confirm-password-input"
                  value={confirmPassword}
                  onChange={setConfirmPassword}
                  placeholder="Confirm master password"
                  width="full"
                  className="mt-1.5 min-h-[44px]"
                  disabled={isSubmittingSetup}
                  required
                />
              </label>
            </div>
            <p className="text-xs text-muted">
              Choose a strong password. This password derives your Master Wrapping Key (PBKDF2-SHA256, 100,000 iterations).
            </p>
          </div>

          {/* 12 Recovery Words Section */}
          <div className="space-y-3">
            <div className="flex items-center justify-between">
              <Text as="div" role="overline" tone="muted">2. 12-Word Recovery Phrase</Text>
              <div className="flex flex-wrap items-center gap-2">
                <Button
                  type="button"
                  size="sm"
                  variant="ghost"
                  data-debug-id="vault-regenerate-words-btn"
                  onClick={handleRegenerateWords}
                  disabled={isSubmittingSetup}
                  className="min-h-[44px] min-w-[44px] touch-manipulation"
                >
                  <Icon name="refresh" size="sm" />
                  Regenerate
                </Button>
                <Button
                  type="button"
                  size="sm"
                  variant="secondary"
                  data-debug-id="vault-copy-words-btn"
                  onClick={handleCopyWords}
                  disabled={isSubmittingSetup}
                  className="min-h-[44px] min-w-[44px] touch-manipulation"
                >
                  <Icon name="copy" size="sm" />
                  {copiedWords ? 'Copied Words!' : 'Copy Words'}
                </Button>
              </div>
            </div>

            <p className="text-xs text-muted">
              Write down or save these 12 words in order. If you lose your password, these words are the ONLY way to recover your vault.
            </p>

            <div
              data-debug-id="vault-recovery-words-grid"
              className="grid grid-cols-1 min-[360px]:grid-cols-2 sm:grid-cols-3 md:grid-cols-4 gap-2.5 pt-2"
            >
              {recoveryWords.map((word, idx) => (
                <div
                  key={idx}
                  data-debug-id={`vault-recovery-word-${idx + 1}`}
                  className="flex items-center gap-2 rounded-xl border border-subtle bg-surface px-3 py-2 text-sm font-mono"
                >
                  <span className="text-xs text-muted select-none w-5 text-right">{idx + 1}.</span>
                  <span className="font-semibold text-primary">{word}</span>
                </div>
              ))}
            </div>
          </div>

          {/* Confirmation Checkbox */}
          <div className="rounded-xl border border-subtle bg-surface/50 p-4">
            <Checkbox
              data-debug-id="vault-setup-backup-checkbox"
              checked={confirmedBackup}
              onChange={setConfirmedBackup}
              label="I have securely saved these 12 recovery words in a safe offline location."
              disabled={isSubmittingSetup}
            />
          </div>

          {setupError ? (
            <div
              data-debug-id="vault-setup-error"
              className="rounded-xl border border-danger/30 bg-danger-soft px-4 py-3 text-xs text-danger"
            >
              {setupError}
            </div>
          ) : null}

          <div className="flex justify-end pt-2">
            <Button
              type="submit"
              variant="primary"
              data-debug-id="vault-setup-submit-btn"
              disabled={isSubmittingSetup || isSavingVault || !masterPassword || !confirmPassword || !confirmedBackup}
            >
              <Icon name="lock" size="sm" />
              {isSubmittingSetup ? 'Initializing Vault…' : 'Initialize & Unlock Vault'}
            </Button>
          </div>
        </form>
      </Panel>
    </div>
  );

  // Render Unlock Form Content (used in both inline view and modal dialog)
  const renderUnlockFormContent = () => (
    <div className="space-y-4">
      <div className="flex border-b border-subtle pb-3">
        <div className="inline-flex rounded-xl bg-surface-raised p-1 gap-1">
          <button
            type="button"
            data-debug-id="vault-unlock-tab-password"
            className={`rounded-lg px-3 py-1.5 text-xs font-semibold transition-colors ${
              unlockMode === 'password'
                ? 'bg-accent text-accent-fg shadow-sm'
                : 'text-muted hover:text-primary'
            }`}
            onClick={() => {
              setUnlockMode('password');
              setUnlockError('');
            }}
          >
            Master Password
          </button>
          <button
            type="button"
            data-debug-id="vault-unlock-tab-recovery"
            className={`rounded-lg px-3 py-1.5 text-xs font-semibold transition-colors ${
              unlockMode === 'recovery'
                ? 'bg-accent text-accent-fg shadow-sm'
                : 'text-muted hover:text-primary'
            }`}
            onClick={() => {
              setUnlockMode('recovery');
              setUnlockError('');
            }}
          >
            12 Recovery Words
          </button>
        </div>
      </div>

      {unlockMode === 'password' ? (
        <form
          data-debug-id="vault-unlock-password-form"
          onSubmit={handleUnlockWithPassword}
          className="space-y-4"
        >
          <label className="block text-sm font-medium text-primary">
            Master Password
            <Input
              type="password"
              data-debug-id="vault-unlock-password-input"
              value={unlockPassword}
              onChange={setUnlockPassword}
              placeholder="Enter your Master Password"
              width="full"
              className="mt-1.5 min-h-[44px]"
              disabled={isUnlocking}
              autoFocus
            />
          </label>
          <p className="text-xs text-muted">
            Derives your wrapping key client-side and decrypts the 256-bit Vault Key in browser memory.
          </p>
          <div className="flex justify-end pt-2">
            <Button
              type="submit"
              variant="primary"
              data-debug-id="vault-unlock-password-btn"
              disabled={isUnlocking || !unlockPassword}
            >
              <Icon name="lock" size="sm" />
              {isUnlocking ? 'Decrypting…' : 'Unlock Vault'}
            </Button>
          </div>
        </form>
      ) : (
        <form
          data-debug-id="vault-unlock-recovery-form"
          onSubmit={handleUnlockWithRecovery}
          className="space-y-4"
        >
          <label className="block text-sm font-medium text-primary">
            12-Word Recovery Phrase
            <Textarea
              data-debug-id="vault-unlock-recovery-input"
              value={recoveryPhraseInput}
              onChange={setRecoveryPhraseInput}
              placeholder="Enter your 12 recovery words separated by spaces…"
              width="full"
              rows={3}
              className="mt-1.5 font-mono text-xs"
              disabled={isUnlocking}
              autoFocus
            />
          </label>
          <p className="text-xs text-muted">
            Enter all 12 BIP-39 recovery words in the correct order to recover and decrypt your vault key.
          </p>
          <div className="flex justify-end pt-2">
            <Button
              type="submit"
              variant="primary"
              data-debug-id="vault-unlock-recovery-btn"
              disabled={isUnlocking || !recoveryPhraseInput.trim()}
            >
              <Icon name="lock" size="sm" />
              {isUnlocking ? 'Recovering…' : 'Recover & Unlock'}
            </Button>
          </div>
        </form>
      )}

      {unlockError ? (
        <div
          data-debug-id="vault-unlock-error"
          className="rounded-xl border border-danger/30 bg-danger-soft px-4 py-3 text-xs text-danger"
        >
          {unlockError}
        </div>
      ) : null}
    </div>
  );

  // Render Locked State View
  const renderLockedView = () => (
    <div data-debug-id="vault-unlock-view" className="space-y-6">
      <Panel tone="raised" padding="lg" className="border border-subtle">
        <div className="flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4">
          <div className="space-y-1">
            <div className="flex items-center gap-2">
              <h3 className="text-base font-semibold text-primary">Zero-Knowledge Vault is Locked</h3>
              <StatusPill tone="neutral" data-debug-id="vault-status-badge">Locked</StatusPill>
            </div>
            <p className="text-sm text-muted">
              Your vault is configured and encrypted on the Hub. Unlock it with your Master Password or 12 Recovery Words.
            </p>
          </div>
          <Button
            variant="secondary"
            data-debug-id="vault-open-unlock-dialog-btn"
            className="min-h-[44px] min-w-[44px] touch-manipulation w-full sm:w-auto"
            onClick={() => {
              setUnlockError('');
              setIsUnlockModalOpen(true);
            }}
          >
            <Icon name="lock" size="sm" />
            Open Unlock Dialog
          </Button>
        </div>

        <div className="mt-6 border-t border-subtle pt-6">
          {renderUnlockFormContent()}
        </div>
      </Panel>
    </div>
  );

  // Render Unlocked State View
  const renderUnlockedView = () => (
    <div data-debug-id="vault-unlocked-view" className="space-y-6">
      <Panel tone="raised" padding="lg" className="border border-subtle">
        {/* Status Header */}
        <div className="flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4">
          <div className="space-y-1">
            <div className="flex items-center gap-2">
              <h3 className="text-base font-semibold text-primary">Zero-Knowledge Vault Unlocked</h3>
              <StatusPill tone="success" data-debug-id="vault-status-badge">Unlocked</StatusPill>
            </div>
            <p className="text-sm text-muted">
              Your 256-bit AES-GCM Vault Key has been decrypted into memory. It is never persisted to disk or sent to the server in plaintext.
            </p>
          </div>
          <Button
            variant="secondary"
            data-debug-id="vault-lock-btn"
            className="min-h-[44px] min-w-[44px] touch-manipulation w-full sm:w-auto"
            onClick={() => {
              void lockAllConnectedBridges();
              dispatch(lockVault());
            }}
          >
            <Icon name="lock" size="sm" />
            Lock Vault
          </Button>
        </div>

        {/* 256-bit Hex Vault Key Viewer */}
        <div data-debug-id="vault-key-viewer" className="mt-6 space-y-3 rounded-2xl border border-subtle bg-surface/60 p-5">
          <div className="flex items-center justify-between">
            <div>
              <h4 className="text-sm font-semibold text-primary">256-bit Hexadecimal Vault Key</h4>
              <p className="text-xs text-muted">
                Active symmetric key (KV) used for client-side secret encryption.
              </p>
            </div>
            <div className="flex items-center gap-2">
              <Button
                size="sm"
                variant="ghost"
                data-debug-id="vault-key-toggle-visibility-btn"
                onClick={() => setIsKeyVisible(!isKeyVisible)}
              >
                <Icon name={isKeyVisible ? 'eye-off' : 'eye'} size="sm" />
                {isKeyVisible ? 'Hide Key' : 'Reveal Key'}
              </Button>
              <Button
                size="sm"
                variant="secondary"
                data-debug-id="vault-key-copy-btn"
                disabled
                title="The vault key is a non-extractable WebCrypto key: there is no raw key material to copy."
              >
                <Icon name="copy" size="sm" />
                Copy Key
              </Button>
            </div>
          </div>

          <div
            data-debug-id="vault-key-hex-display"
            className="break-all rounded-xl border border-subtle bg-surface-raised/40 p-3.5 font-mono text-xs text-primary select-all tracking-wider"
          >
            {isKeyVisible ? VAULT_KEY_PROTECTED_LABEL : '•'.repeat(64)}
          </div>
        </div>

        {/* Bridge Setup Instructions */}
        <div data-debug-id="vault-bridge-instructions" className="mt-6 space-y-3 rounded-2xl border border-subtle bg-surface-raised/30 p-5">
          <h4 className="text-sm font-semibold text-primary">Bridge Setup Instructions</h4>
          <p data-debug-id="vault-bridge-cmd-display" className="text-xs text-muted">
            {VAULT_BRIDGE_INSTRUCTIONS}
          </p>

          <p className="text-xs text-faint">
            Once configured, Bridge tasks and agents will be able to securely decrypt environment secrets.
          </p>
        </div>
      </Panel>
    </div>
  );

  return (
    <PageShell
      title="User Vault"
      description="Zero-Knowledge client vault with Master Password encryption, 12-word recovery phrase, and non-extractable key status."
    >
      <div data-debug-id="settings-vault-panel" className="space-y-6 text-left">
        {!isConfigured && renderSetupWizard()}
        {isConfigured && !isUnlocked && renderLockedView()}
        {isConfigured && isUnlocked && renderUnlockedView()}
      </div>

      {/* Unlock Modal Dialog */}
      <Modal
        open={isUnlockModalOpen}
        onOpenChange={setIsUnlockModalOpen}
        title="Unlock User Vault"
        size="md"
        data-debug-id="vault-unlock-modal"
      >
        <Modal.Body>
          <div className="p-1">
            {renderUnlockFormContent()}
          </div>
        </Modal.Body>
        <Modal.Footer>
          <Button
            variant="ghost"
            onClick={() => {
              setIsUnlockModalOpen(false);
              setUnlockError('');
            }}
          >
            Cancel
          </Button>
        </Modal.Footer>
      </Modal>
    </PageShell>
  );
}
