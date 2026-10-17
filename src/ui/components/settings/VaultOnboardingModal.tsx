import React, { useState, useEffect, useCallback, type FormEvent } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import {
  Modal,
  Button,
  Input,
  Textarea,
  Checkbox,
  Icon,
} from '@ui';
import {
  selectIsVaultConfigured,
  selectIsVaultUnlocked,
  setVaultConfigured,
  setVaultUnlocked,
  readOnboardingDismissed,
  setActiveBridgeVaultKeyMaterial,
  writeOnboardingDismissed,
} from '../../store/vaultSlice';
import {
  useGetUserVaultQuery,
  useSetUserVaultMutation,
} from '../../api/endpoints/userVault';
import {
  generateVaultKey,
  exportRawKeyHex,
  deriveKeyFromPassword,
  generate12RecoveryWords,
  validateRecoveryWords,
  deriveKeyFromRecoveryWords,
  encryptVaultKeyEnvelope,
  decryptVaultKeyEnvelope,
  decryptVaultKeyEnvelopeHex,
  generateSaltHex,
  DEFAULT_KDF_ITERATIONS,
} from '../../utils/vaultCrypto';
import { VaultPasswordPurposeNote } from './VaultPasswordPurposeNote';

export interface VaultOnboardingModalProps {
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
  onDismiss?: () => void;
  mode?: 'vault-unlock' | 'bridge-reauthentication';
  onBridgeReauthenticate?: (rawVaultKeyHex: string) => Promise<void>;
}

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

export default function VaultOnboardingModal({
  open: controlledOpen,
  onOpenChange,
  onDismiss,
  mode = 'vault-unlock',
  onBridgeReauthenticate,
}: VaultOnboardingModalProps) {
  const dispatch = useDispatch();
  const isVaultConfiguredInRedux = useSelector(selectIsVaultConfigured);
  const isUnlocked = useSelector(selectIsVaultUnlocked);

  const { data: vaultData, refetch: refetchVault, isLoading: isVaultLoading, isError: isVaultError } = useGetUserVaultQuery();
  const [setUserVault, { isLoading: isSavingVault }] = useSetUserVaultMutation();

  const isConfigured = Boolean(vaultData?.isConfigured || isVaultConfiguredInRedux);
  const isBridgeReauthentication = mode === 'bridge-reauthentication';

  // Sync Redux configured state with server query
  useEffect(() => {
    if (vaultData?.isConfigured !== undefined) {
      dispatch(setVaultConfigured(vaultData.isConfigured));
    }
  }, [vaultData?.isConfigured, dispatch]);

  // Internal open state for uncontrolled usage
  const [internalOpen, setInternalOpen] = useState(false);

  useEffect(() => {
    if (controlledOpen === undefined) {
      const dismissed = readOnboardingDismissed();
      if (!isUnlocked && !dismissed) {
        setInternalOpen(true);
      } else {
        setInternalOpen(false);
      }
    }
  }, [controlledOpen, isUnlocked]);

  const isOpen = controlledOpen !== undefined ? controlledOpen : internalOpen;

  // Session persistence preference (checkbox)
  const [rememberSession, setRememberSession] = useState(true);

  // Error message
  const [errorMessage, setErrorMessage] = useState('');

  // Setup Wizard State
  const [masterPassword, setMasterPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');
  const passwordsDoNotMatch = confirmPassword.length > 0 && masterPassword !== confirmPassword;
  const [recoveryWords, setRecoveryWords] = useState<string[]>([]);
  const [confirmedBackup, setConfirmedBackup] = useState(false);
  const [isSubmittingSetup, setIsSubmittingSetup] = useState(false);
  const [copiedWords, setCopiedWords] = useState(false);

  // Unlock State
  const [unlockMode, setUnlockMode] = useState<'password' | 'recovery'>('password');
  const [unlockPassword, setUnlockPassword] = useState('');
  const [recoveryPhraseInput, setRecoveryPhraseInput] = useState('');
  const [isUnlocking, setIsUnlocking] = useState(false);

  // Initialize recovery words
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

  const handleClose = useCallback(() => {
    if (onOpenChange) {
      onOpenChange(false);
    } else {
      setInternalOpen(false);
    }
    onDismiss?.();
  }, [onOpenChange, onDismiss]);

  const handleSkip = useCallback(() => {
    writeOnboardingDismissed(true);
    handleClose();
  }, [handleClose]);

  // Close when vault is successfully unlocked
  useEffect(() => {
    if (!isBridgeReauthentication && isUnlocked && isOpen) {
      handleClose();
    }
  }, [isBridgeReauthentication, isUnlocked, isOpen, handleClose]);

  // Setup Wizard Submit Handler
  async function handleSetupSubmit(e: FormEvent) {
    e.preventDefault();
    setErrorMessage('');

    if (!masterPassword) {
      setErrorMessage('Enter a password.');
      return;
    }
    if (masterPassword.length < 8) {
      setErrorMessage('Use at least 8 characters.');
      return;
    }
    if (masterPassword !== confirmPassword) {
      setErrorMessage('Passwords do not match.');
      return;
    }
    if (!confirmedBackup) {
      setErrorMessage('Save your recovery phrase before continuing.');
      return;
    }
    if (recoveryWords.length !== 12) {
      setErrorMessage('Invalid recovery words. Please regenerate the phrase.');
      return;
    }

    try {
      setIsSubmittingSetup(true);

      // 1. Generate 256-bit symmetric AES-GCM Vault Key (KV)
      const vaultKey = await generateVaultKey();
      const rawVaultKeyHex = await exportRawKeyHex(vaultKey);

      // 2. Derive Master Wrapping Key (KM) from Password
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
      // getActiveVaultKey() is still null (REQ-RAWKEY-A7b).
      dispatch(setVaultUnlocked({ key: vaultKey, rememberSession }));
      setActiveBridgeVaultKeyMaterial(rawVaultKeyHex);

      // Reset sensitive password inputs
      setMasterPassword('');
      setConfirmPassword('');
      void refetchVault();
      handleClose();
    } catch (err: any) {
      setErrorMessage(String(err?.message || err?.error || err || 'Failed to initialize vault'));
    } finally {
      setIsSubmittingSetup(false);
    }
  }

  // Unlock with Password
  async function handleUnlockWithPassword(e?: FormEvent) {
    if (e) e.preventDefault();
    setErrorMessage('');

    if (!unlockPassword) {
      setErrorMessage('Enter your password.');
      return;
    }

    const record = extractVaultRecord(vaultData?.vault);
    if (!record || !record.encryptedVaultKey) {
      setErrorMessage('No encrypted vault envelope found on server.');
      return;
    }

    try {
      setIsUnlocking(true);
      const wrappingKey = await deriveKeyFromPassword(unlockPassword, record.kdfSalt, record.kdfIterations);
      const rawVaultKeyHex = await decryptVaultKeyEnvelopeHex(
        wrappingKey,
        record.encryptedVaultKey,
        record.vaultKeyNonce,
        record.vaultKeyTag,
      );
      if (isBridgeReauthentication) {
        await onBridgeReauthenticate?.(rawVaultKeyHex);
        setUnlockPassword('');
        handleClose();
        return;
      }
      const vaultKey = await decryptVaultKeyEnvelope(
        wrappingKey,
        record.encryptedVaultKey,
        record.vaultKeyNonce,
        record.vaultKeyTag,
      );
      dispatch(setVaultUnlocked({ key: vaultKey, rememberSession }));
      setActiveBridgeVaultKeyMaterial(rawVaultKeyHex);
      setUnlockPassword('');
      handleClose();
    } catch (_err) {
      setErrorMessage('Incorrect password. Try again.');
    } finally {
      setIsUnlocking(false);
    }
  }

  // Unlock with 12 Recovery Words
  async function handleUnlockWithRecovery(e?: FormEvent) {
    if (e) e.preventDefault();
    setErrorMessage('');

    const words = recoveryPhraseInput.trim().toLowerCase().split(/\s+/).filter(Boolean);
    if (words.length !== 12) {
      setErrorMessage(`Expected 12 recovery words, but found ${words.length}.`);
      return;
    }

    if (!validateRecoveryWords(words)) {
      setErrorMessage('Invalid recovery words or checksum. Please verify all 12 words.');
      return;
    }

    const record = extractVaultRecord(vaultData?.vault);
    if (!record || !record.recoveryEncryptedVaultKey) {
      setErrorMessage('No recovery envelope found on server.');
      return;
    }

    try {
      setIsUnlocking(true);
      const recoveryWrappingKey = await deriveKeyFromRecoveryWords(words, record.recoverySalt, record.kdfIterations);
      const rawVaultKeyHex = await decryptVaultKeyEnvelopeHex(
        recoveryWrappingKey,
        record.recoveryEncryptedVaultKey,
        record.recoveryNonce,
        record.recoveryTag,
      );
      if (isBridgeReauthentication) {
        await onBridgeReauthenticate?.(rawVaultKeyHex);
        setRecoveryPhraseInput('');
        handleClose();
        return;
      }
      const vaultKey = await decryptVaultKeyEnvelope(
        recoveryWrappingKey,
        record.recoveryEncryptedVaultKey,
        record.recoveryNonce,
        record.recoveryTag,
      );
      dispatch(setVaultUnlocked({ key: vaultKey, rememberSession }));
      setActiveBridgeVaultKeyMaterial(rawVaultKeyHex);
      setRecoveryPhraseInput('');
      handleClose();
    } catch (_err) {
      setErrorMessage('Failed to unlock vault with recovery words. Verification failed.');
    } finally {
      setIsUnlocking(false);
    }
  }

  if (!isOpen) {
    return null;
  }

  return (
    <Modal
      open={isOpen}
      onOpenChange={(next) => { if (!next) handleClose(); }}
      title={isBridgeReauthentication ? 'Unlock connected bridges' : isConfigured ? 'Unlock vault' : 'Set up vault'}
      size="md"
      data-debug-id="vault-onboarding-modal"
    >
      <Modal.Body className="space-y-4">
        {isVaultLoading ? (
          <p className="text-sm text-muted" role="status">Loading vault…</p>
        ) : isVaultError ? (
          <p className="text-sm text-danger" role="alert">Unable to load your vault. Close this dialog and try again.</p>
        ) : !isConfigured ? (
          <form data-debug-id="vault-onboarding-setup-form" onSubmit={handleSetupSubmit} className="space-y-4">
            <p className="text-sm text-muted">Protect your encrypted content with a password.</p>
            <VaultPasswordPurposeNote />
            <div className="grid gap-3 sm:grid-cols-2">
              <label className="text-xs font-medium text-primary">
                Password
                <Input type="password" data-debug-id="vault-onboarding-master-password-input"
                  value={masterPassword} onChange={setMasterPassword} placeholder="At least 8 characters"
                  autoComplete="new-password" minLength={8} width="full" className="mt-1"
                  disabled={isSubmittingSetup} required />
              </label>
              <label className="text-xs font-medium text-primary">
                Confirm password
                <Input type="password" data-debug-id="vault-onboarding-confirm-password-input"
                  value={confirmPassword} onChange={setConfirmPassword} placeholder="Repeat password"
                  autoComplete="new-password" minLength={8} width="full" className="mt-1"
                  invalid={passwordsDoNotMatch}
                  aria-describedby={passwordsDoNotMatch ? 'vault-password-mismatch' : undefined}
                  disabled={isSubmittingSetup} required />
                {passwordsDoNotMatch && (
                  <span id="vault-password-mismatch" data-debug-id="vault-onboarding-password-mismatch"
                    role="status" className="mt-1 block text-xs font-normal text-danger">
                    Passwords do not match.
                  </span>
                )}
              </label>
            </div>
            <div className="space-y-2 border-t border-subtle pt-3">
              <div className="flex items-center justify-between gap-2">
                <span className="text-xs font-medium text-primary">Recovery phrase</span>
                <div className="flex gap-1">
                  <Button type="button" size="sm" variant="ghost"
                    data-debug-id="vault-onboarding-regenerate-words-btn"
                    onClick={handleRegenerateWords} disabled={isSubmittingSetup}>Regenerate</Button>
                  <Button type="button" size="sm" variant="ghost"
                    data-debug-id="vault-onboarding-copy-words-btn"
                    onClick={handleCopyWords} disabled={isSubmittingSetup}>
                    <Icon name="copy" size="sm" />{copiedWords ? 'Copied' : 'Copy'}
                  </Button>
                </div>
              </div>
              <p className="text-xs text-muted">Save these 12 words offline. Use them if you forget your password.</p>
              <div data-debug-id="vault-onboarding-recovery-words-grid"
                className="grid grid-cols-2 sm:grid-cols-3 gap-x-4 gap-y-2 rounded-lg border border-subtle bg-neutral-soft p-3">
                {recoveryWords.map((word, idx) => (
                  <div key={idx} data-debug-id={`vault-onboarding-recovery-word-${idx + 1}`}
                    className="flex items-center gap-2 text-xs">
                    <span className="w-4 text-right text-muted tabular-nums">{idx + 1}</span>
                    <span className="font-mono text-primary">{word}</span>
                  </div>
                ))}
              </div>
              <Checkbox data-debug-id="vault-onboarding-setup-backup-checkbox"
                checked={confirmedBackup} onChange={setConfirmedBackup}
                label="I saved my recovery phrase" disabled={isSubmittingSetup} />
            </div>
            <Checkbox data-debug-id="vault-onboarding-remember-checkbox"
              checked={rememberSession} onChange={setRememberSession}
              label="Keep unlocked in this browser session" disabled={isSubmittingSetup} />
            <div className="flex items-center justify-end gap-2">
              <Button type="button" variant="ghost" data-debug-id="vault-onboarding-skip-btn"
                onClick={handleSkip} disabled={isSubmittingSetup || isSavingVault}>
                Skip for now
              </Button>
              <Button type="submit" variant="primary" data-debug-id="vault-onboarding-setup-submit-btn"
                disabled={isSubmittingSetup || isSavingVault || masterPassword.length < 8 || masterPassword !== confirmPassword || !confirmedBackup}>
                {isSubmittingSetup ? 'Creating vault…' : 'Create vault'}
              </Button>
            </div>
          </form>
        ) : (
          <div data-debug-id="vault-onboarding-unlock-form" className="space-y-4">
            <p className="text-sm text-muted">
              {isBridgeReauthentication
                ? 'Re-enter your vault credentials to securely unlock connected bridges. Your browser vault stays unlocked.'
                : 'Unlock to view your encrypted content.'}
            </p>
            <div className="flex gap-1" role="group" aria-label="Unlock method">
              <Button type="button" size="sm" variant={unlockMode === 'password' ? 'secondary' : 'ghost'}
                data-debug-id="vault-onboarding-unlock-mode-password-btn" aria-pressed={unlockMode === 'password'}
                onClick={() => { setUnlockMode('password'); setErrorMessage(''); }}>Password</Button>
              <Button type="button" size="sm" variant={unlockMode === 'recovery' ? 'secondary' : 'ghost'}
                data-debug-id="vault-onboarding-unlock-mode-recovery-btn" aria-pressed={unlockMode === 'recovery'}
                onClick={() => { setUnlockMode('recovery'); setErrorMessage(''); }}>Recovery phrase</Button>
            </div>
            <form onSubmit={unlockMode === 'password' ? handleUnlockWithPassword : handleUnlockWithRecovery} className="space-y-4">
              {unlockMode === 'password' ? (
                <label className="block text-xs font-medium text-primary">
                  Password
                  <Input type="password" data-debug-id="vault-onboarding-unlock-password-input"
                    value={unlockPassword} onChange={setUnlockPassword} placeholder="Enter password"
                    autoComplete="current-password" width="full" className="mt-1" disabled={isUnlocking} autoFocus required />
                </label>
              ) : (
                <label className="block text-xs font-medium text-primary">
                  Recovery phrase
                  <Textarea data-debug-id="vault-onboarding-unlock-recovery-input"
                    value={recoveryPhraseInput} onChange={setRecoveryPhraseInput} placeholder="Enter your 12 words"
                    width="full" rows={3} className="mt-1" disabled={isUnlocking} autoFocus required />
                </label>
              )}
              {!isBridgeReauthentication ? (
                <Checkbox data-debug-id="vault-onboarding-remember-checkbox"
                  checked={rememberSession} onChange={setRememberSession}
                  label="Keep unlocked in this browser session" disabled={isUnlocking} />
              ) : null}
              <div className="flex justify-end">
                <Button type="submit" variant="primary" data-debug-id="vault-onboarding-unlock-submit-btn"
                  disabled={isUnlocking || !(unlockMode === 'password' ? unlockPassword : recoveryPhraseInput.trim())}>
                  {isUnlocking ? 'Unlocking…' : isBridgeReauthentication ? 'Unlock bridges' : 'Unlock vault'}
                </Button>
              </div>
            </form>
          </div>
        )}
        {errorMessage ? (
          <div data-debug-id="vault-onboarding-error" role="alert"
            className="rounded-lg border border-danger/30 bg-danger-soft px-3 py-2 text-xs text-danger">{errorMessage}</div>
        ) : null}
      </Modal.Body>
      {(isConfigured || isVaultLoading || isVaultError) && <Modal.Footer>
        <Button type="button" variant="ghost" data-debug-id="vault-onboarding-skip-btn"
          onClick={isBridgeReauthentication ? handleClose : handleSkip}>
          {isConfigured ? 'Cancel' : 'Skip for now'}
        </Button>
      </Modal.Footer>}
    </Modal>
  );
}
