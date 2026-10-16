// REQ-IMPL-5 — the bridge-enrollment approval screen (REQ-ENROLL-5/6/14).
//
// Reached at `/device/add`. The operator types the short code printed by the
// bridge and explicitly compares the displayed key fingerprint with the terminal.
//
// ── Why this screen lives in the SPA and not in the standalone device page ──
//
// The Hub also serves a self-contained approval page at `GET /api/v1/device`
// (src/hub/service/device_auth/page.odin), which the Electron device flow uses
// and which is left exactly as it was. It cannot host THIS screen, because the
// vault key is in-memory module state inside the SPA (`getActiveVaultKey`), and
// a separate document on the same origin shares cookies and storage but no JS
// module memory. The alternative — reimplementing vault key derivation inside an
// inline-JS page with no build step and no test coverage — would put the most
// security-sensitive code in the system into a second, untested copy. So the
// enrollment ceremony happens here, where the vault key, the vault crypto and an
// authenticated session already are.
//
// ── The three things this screen must get right ─────────────────────────────
//
// 1. PROVENANCE (REQ-ENROLL-14). The verify payload nests fields under
//    `hub_observed` (measured by the Hub) and `host_asserted` (claimed by the
//    machine asking to be let in). Those two halves are rendered as visibly
//    different things, and the distinction is carried by HEADING TEXT and
//    per-row marks, not by colour alone — a colour-blind or high-contrast
//    operator must not lose it at the moment it matters.
//
// 2. KEY CONFIRMATION (REQ-ENROLL-5). The Hub returns the bridge public key and
//    its computed fingerprint. Approval remains disabled until the operator says
//    that fingerprint matches the independently computed value on the bridge's
//    terminal. The vault key is then encrypted to that confirmed public key.
//
// 3. NO AUTO-APPROVE (Part A item 4). Entering a code verifies and displays; it
//    never decides. Confirmation and approval are separate explicit actions.
//
// ── Residual risk — stated, not papered over ────────────────────────────────
//
// This defeats a SUBSTITUTING Hub. It does NOT defeat a COMPROMISED UI ORIGIN:
// the Hub serves the JavaScript doing the encryption, so a Hub serving malicious
// code can simply lie about the comparison it claims to have made. No in-browser
// design escapes that. The guarantee is narrow and real: a Hub that merely
// relays ciphertext cannot swap the key without the operator's own browser
// noticing.
//
// Separately, the bridge's ECDH keypair is ephemeral per process
// (`bridge_unseal_init`), so it legitimately changes on every bridge restart.
// The terminal fingerprint confirmation therefore applies to this enrollment
// process only; the steady-state unlock path uses the currently advertised key.

import React, {
  useCallback,
  useEffect,
  useRef,
  useState,
  type ClipboardEvent,
  type FormEvent,
  type KeyboardEvent,
} from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { Button, Input, Icon, Modal, ModalBody, ModalFooter, Select } from '@ui';

import { cookieJsonFetch, cookieMutation } from '../../api/cookieFetch';
import { fetchBridgePublicKey, unsealBridgeE2EE } from '../../api/endpoints/bridges';
import { useGetUserVaultQuery } from '../../api/endpoints/userVault';
import {
  getActiveVaultKey,
  getActiveBridgeVaultKeyMaterial,
  selectIsVaultUnlocked,
  setActiveBridgeVaultKeyMaterial,
  setVaultUnlocked,
} from '../../store/vaultSlice';
import {
  deriveKeyFromPassword,
  decryptVaultKeyEnvelope,
  decryptVaultKeyEnvelopeHex,
  DEFAULT_KDF_ITERATIONS,
} from '../../utils/vaultCrypto';
import { canUnsealWithKey } from '../../utils/vaultBridgeUnseal';
import {
  approvedBridgeIsOnline,
  enrollmentContinueAvailable,
  enrollmentRestartConfirmation,
  navigateEnrollmentProviderSetup,
  nextAvailableBridgeLabel,
  RESTART_CONFIRMATION_TIMEOUT_SECONDS,
  WRONG_MASTER_PASSWORD_MESSAGE,
} from './bridgeEnrollmentCompletion';
import {
  bridgeApprovalBlocked,
  bridgeFingerprintConfirmationReady,
  deviceCodeFromHash,
  formatDeviceCode,
  normalizeDeviceCodeSymbols,
  sanitizeForDisplay,
  DISPLAY_MAX_CHARS,
} from '../../utils/deviceApprovalSafety';

// ---------------------------------------------------------------------------
// Wire shapes
// ---------------------------------------------------------------------------

/** One row of GET /api/v1/bridges, trimmed to what the picker below needs. */
interface BridgeSummary {
  bridge_id?: string;
  label?: string;
  machine_hostname?: string;
  status?: string;
}

interface VerifyPayload {
  client?: string;
  device_label?: string;
  os?: string;
  app_version?: string;
  request_ip?: string;
  requested_at?: number;
  is_bridge_enrollment?: boolean;
  bridge_public_key?: string;
  bridge_key_fingerprint?: string;
  os_user?: string;
  hub_observed?: {
    bridge_key_fingerprint?: string;
    bridge_public_key_on_record?: string;
    fingerprint_algorithm?: string;
    request_ip?: string;
    /** The Hub's own clock reading, unix seconds. NEVER the browser's. */
    server_time?: number;
  };
  host_asserted?: {
    bridge_public_key?: string;
    os_user?: string;
    device_label?: string;
    os?: string;
    app_version?: string;
  };
}


/** Where the post-approval vault delivery has got to. */
type DeliveryState =
  | { phase: 'idle' }
  | { phase: 'not-needed' }
  | { phase: 'need-password'; target: UnsealTarget }
  | { phase: 'waiting-for-bridge'; secondsLeft: number }
  | { phase: 'delivering'; target: UnsealTarget }
  | { phase: 'delivered' }
  | { phase: 'confirming-restart'; secondsLeft: number }
  | { phase: 'confirmed' }
  | {
      phase: 'restart-unconfirmed';
      reason: 'sealed' | 'timed-out';
      vaultStatus: string;
      error?: string;
    }
  | { phase: 'failed'; message: string }
  | { phase: 'timed-out' };

/**
 * Which process a vault key is wrapped for. `enrollment` is the CLI process whose
 * key the operator confirmed against the terminal; `restarted` is the registered
 * service it hands over to, whose ephemeral key is whatever it advertises now —
 * the same steady-state path Settings → Bridges uses.
 */
type UnsealTarget = 'enrollment' | 'restarted';

/**
 * How long to wait for the just-approved bridge to connect before giving up
 * VISIBLY.
 *
 * The bridge only learns it was approved on its next poll, then has to open its
 * WebSocket, so it is not addressable at the instant of approval. A silent skip
 * here would be the worst outcome: the operator would believe the vault key was
 * delivered and find out otherwise the next time the bridge needed it.
 */
const BRIDGE_ONLINE_TIMEOUT_SECONDS = 45;
const BRIDGE_POLL_INTERVAL_MS = 2000;
const DEVICE_CODE_LENGTH = 8;

function unwrap(body: any): any {
  return (body && body.data) || body || {};
}

// ---------------------------------------------------------------------------
// Presentation helpers
// ---------------------------------------------------------------------------

function Banner({
  tone,
  title,
  children,
}: {
  tone: 'danger' | 'warn' | 'ok';
  title: string;
  children: React.ReactNode;
}) {
  const palette = {
    danger: { bg: 'rgba(185,28,28,0.08)', line: '#fca5a5', fg: '#b91c1c' },
    warn: { bg: 'rgba(245,158,11,0.10)', line: '#fcd34d', fg: '#92400e' },
    ok: { bg: 'rgba(16,185,129,0.08)', line: '#86efac', fg: '#065f46' },
  }[tone];
  return (
    <div
      role={tone === 'danger' ? 'alert' : 'status'}
      style={{
        background: palette.bg,
        border: `1px solid ${palette.line}`,
        borderRadius: 8,
        padding: '12px 14px',
        marginBottom: 12,
        color: palette.fg,
        fontSize: '0.88rem',
      }}
    >
      <strong style={{ display: 'block', marginBottom: 4 }}>{title}</strong>
      {children}
    </div>
  );
}

// ---------------------------------------------------------------------------
// The screen
// ---------------------------------------------------------------------------

export default function BridgeEnrollmentApprovalPage() {
  const dispatch = useDispatch();
  const isUnlocked = useSelector(selectIsVaultUnlocked);
  const vaultQuery = useGetUserVaultQuery();
  const vaultEnvelope = vaultQuery.data?.vault;

  const [fragmentCode] = useState(() =>
    typeof window === 'undefined' ? '' : deviceCodeFromHash(window.location.hash),
  );
  const [codeSymbols, setCodeSymbols] = useState(() => normalizeDeviceCodeSymbols(fragmentCode));
  const codeInput = formatDeviceCode(codeSymbols);
  const codeInputRefs = useRef<Array<HTMLInputElement | null>>([]);
  const fragmentCodeHandled = useRef(false);
  const [grant, setGrant] = useState<VerifyPayload | null>(null);
  // The code that actually produced `grant`. The decision is sent for THIS
  // value, never for whatever the editable input happens to hold at click time.
  const [verifiedCode, setVerifiedCode] = useState('');
  const [verifyError, setVerifyError] = useState('');
  const [verifying, setVerifying] = useState(false);
  const [decision, setDecision] = useState<'none' | 'approved' | 'rejected'>('none');
  const [decideError, setDecideError] = useState('');
  const [deciding, setDeciding] = useState(false);
  const [bridgeId, setBridgeId] = useState('');
  const [bridgeConnected, setBridgeConnected] = useState(false);
  const [delivery, setDelivery] = useState<DeliveryState>({ phase: 'idle' });
  const [masterPassword, setMasterPassword] = useState('');
  const [passwordError, setPasswordError] = useState('');
  const [passwordBusy, setPasswordBusy] = useState(false);
  const [rememberSession, setRememberSession] = useState(true);
  // "Attach to an existing bridge" instead of minting a new one. Empty means
  // the default (unchanged) behaviour: create a new bridge.
  const [bridgeTargets, setBridgeTargets] = useState<BridgeSummary[]>([]);
  const [targetBridgeId, setTargetBridgeId] = useState('');
  const [newBridgeLabel, setNewBridgeLabel] = useState('');
  const [fingerprintConfirmed, setFingerprintConfirmed] = useState(false);

  const doVerify = useCallback(async (code: string) => {
    const canonical = formatDeviceCode(code);
    if (normalizeDeviceCodeSymbols(canonical).length !== DEVICE_CODE_LENGTH) {
      setVerifyError('Enter all eight characters shown on the machine you are enrolling.');
      return;
    }
    setVerifying(true);
    setVerifyError('');
    try {
      const res = await cookieMutation('/device/verify', 'POST', { user_code: canonical });
      setGrant(unwrap(res) as VerifyPayload);
      setVerifiedCode(canonical);
      setFingerprintConfirmed(false);
    } catch (err: any) {
      // The Hub answers a generic error for unknown/expired codes on purpose
      // (anti-enumeration), so there is nothing more specific to say here.
      setVerifyError(
        err?.status === 410
          ? 'This code was already used.'
          : 'That code is not valid, or it has expired.',
      );
      setGrant(null);
      setVerifiedCode('');
      setFingerprintConfirmed(false);
    } finally {
      setVerifying(false);
    }
  }, []);

  useEffect(() => {
    if (fragmentCodeHandled.current) return;
    fragmentCodeHandled.current = true;
    if (!fragmentCode) return;

    // Fragments are not sent in HTTP requests, but remove the short code from
    // the visible URL and session history as soon as this page consumes it.
    window.history.replaceState(
      window.history.state,
      '',
      `${window.location.pathname}${window.location.search}#/device/add`,
    );
    void doVerify(fragmentCode);
  }, [doVerify, fragmentCode]);

  const focusCodeCell = useCallback((index: number) => {
    codeInputRefs.current[Math.max(0, Math.min(index, DEVICE_CODE_LENGTH - 1))]?.focus();
  }, []);

  const putCodeSymbols = useCallback(
    (index: number, raw: string) => {
      const incoming = normalizeDeviceCodeSymbols(raw);
      if (!incoming) {
        setCodeSymbols((current) => current.slice(0, index) + current.slice(index + 1));
        return;
      }

      setCodeSymbols((current) => {
        const cells = Array.from(
          { length: DEVICE_CODE_LENGTH },
          (_, cell) => current[cell] ?? '',
        );
        // A complete pasted code fills the control from the first box even if
        // the operator happened to focus a later box.
        const start = incoming.length === DEVICE_CODE_LENGTH ? 0 : index;
        for (
          let offset = 0;
          offset < incoming.length && start + offset < DEVICE_CODE_LENGTH;
          offset += 1
        ) {
          cells[start + offset] = incoming[offset];
        }
        return cells.join('');
      });
      const start = incoming.length === DEVICE_CODE_LENGTH ? 0 : index;
      window.setTimeout(
        () => focusCodeCell(Math.min(start + incoming.length, DEVICE_CODE_LENGTH - 1)),
        0,
      );
    },
    [focusCodeCell],
  );

  const handleCodePaste = useCallback(
    (index: number, event: ClipboardEvent<HTMLInputElement>) => {
      event.preventDefault();
      putCodeSymbols(index, event.clipboardData.getData('text'));
    },
    [putCodeSymbols],
  );

  const handleCodeKeyDown = useCallback(
    (index: number, event: KeyboardEvent<HTMLInputElement>) => {
      if (event.key === 'Backspace') {
        event.preventDefault();
        if (codeSymbols[index]) {
          setCodeSymbols(codeSymbols.slice(0, index) + codeSymbols.slice(index + 1));
        } else if (index > 0) {
          setCodeSymbols(codeSymbols.slice(0, index - 1) + codeSymbols.slice(index));
          focusCodeCell(index - 1);
        }
      } else if (event.key === 'ArrowLeft' && index > 0) {
        event.preventDefault();
        focusCodeCell(index - 1);
      } else if (event.key === 'ArrowRight' && index < DEVICE_CODE_LENGTH - 1) {
        event.preventDefault();
        focusCodeCell(index + 1);
      } else if (event.key === 'Enter') {
        event.preventDefault();
        void doVerify(codeInput);
      }
    },
    [codeInput, codeSymbols, doVerify, focusCodeCell],
  );

  // Offer "attach to an existing bridge" only for a bridge-enrollment grant —
  // a plain user/Electron device grant has no bridge_id to attach to. Fetch
  // runs once the grant verifies; a failure here is non-fatal, the picker
  // just stays empty (new bridge only), same as the plain /api/v1/device
  // page's fallback behaviour.
  useEffect(() => {
    if (grant?.is_bridge_enrollment !== true) {
      setBridgeTargets([]);
      setNewBridgeLabel('');
      return;
    }
    let cancelled = false;
    (async () => {
      try {
        const data = await cookieJsonFetch('/bridges');
        const unwrapped = unwrap(data);
        const list: BridgeSummary[] = Array.isArray(unwrapped)
          ? unwrapped
          : Array.isArray(unwrapped?.bridges)
            ? unwrapped.bridges
            : [];
        if (!cancelled) {
          // A revoked bridge has nothing to attach to; the Hub also refuses
          // this server-side, this is just not offering a dead end in the UI.
          const available = list.filter((b) => b && b.status !== 'revoked');
          setBridgeTargets(available);
          const hostname = sanitizeForDisplay(
            grant.host_asserted?.device_label ?? grant.device_label,
            DISPLAY_MAX_CHARS,
          ).text;
          // Revoked bridges are not valid attachment targets, but their labels
          // still count as existing names for the suggested new identity.
          setNewBridgeLabel(nextAvailableBridgeLabel(hostname, list));
        }
      } catch {
        if (!cancelled) {
          setBridgeTargets([]);
          const hostname = sanitizeForDisplay(
            grant.host_asserted?.device_label ?? grant.device_label,
            DISPLAY_MAX_CHARS,
          ).text;
          setNewBridgeLabel(nextAvailableBridgeLabel(hostname, []));
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [
    grant?.is_bridge_enrollment,
    grant?.host_asserted?.device_label,
    grant?.device_label,
  ]);

  // ── The REQ-ENROLL-5 operator cross-check ───────────────────────────────
  const hubKey = String(
    grant?.hub_observed?.bridge_public_key_on_record || grant?.bridge_public_key || '',
  )
    .trim()
    .toLowerCase();
  const hubFingerprint = String(
    grant?.hub_observed?.bridge_key_fingerprint || grant?.bridge_key_fingerprint || '',
  ).trim();
  const bridgeKeyReady = bridgeFingerprintConfirmationReady(hubKey, hubFingerprint);
  const approvalBlocked = bridgeApprovalBlocked(
    grant?.is_bridge_enrollment === true,
    hubKey,
    hubFingerprint,
    fingerprintConfirmed,
  );

  // Host-provided values remain sanitised even though the page intentionally
  // presents only the two details an operator needs for this decision.
  const asserted = grant?.host_asserted ?? {};
  const label = sanitizeForDisplay(asserted.device_label ?? grant?.device_label, DISPLAY_MAX_CHARS);
  const os = sanitizeForDisplay(asserted.os ?? grant?.os, DISPLAY_MAX_CHARS);
  const flagged = [
    label.suspicious && 'hostname',
    os.suspicious && 'operating system',
  ].filter(Boolean) as string[];

  // ── Vault delivery ──────────────────────────────────────────────────────

  const waitForAuthenticatedBridge = useCallback(async (targetBridgeId: string): Promise<boolean> => {
    const deadline = Date.now() + BRIDGE_ONLINE_TIMEOUT_SECONDS * 1000;
    for (;;) {
      const secondsLeft = Math.max(0, Math.ceil((deadline - Date.now()) / 1000));
      setDelivery({ phase: 'waiting-for-bridge', secondsLeft });

      try {
        const data = await cookieJsonFetch('/bridges');
        const unwrapped = unwrap(data);
        const list = Array.isArray(unwrapped) ? unwrapped : unwrapped?.bridges;
        if (approvedBridgeIsOnline(list, targetBridgeId)) {
          setBridgeConnected(true);
          return true;
        }
      } catch {
        // A transient authenticated-poll failure is not an enrollment failure.
      }

      if (Date.now() >= deadline) {
        setDelivery({ phase: 'timed-out' });
        return false;
      }
      await new Promise((resolve) => setTimeout(resolve, BRIDGE_POLL_INTERVAL_MS));
    }
  }, []);

  /**
   * After the enrolling process has the key it persists it, restarts the
   * registered service and exits. Poll until the RESTARTED service reports
   * itself unsealed, so the page never claims more than it has seen (REQ-T2-4).
   */
  const confirmRestart = useCallback(
    async (targetBridgeId: string) => {
      const deadline = Date.now() + RESTART_CONFIRMATION_TIMEOUT_SECONDS * 1000;
      let sealedPolls = 0;
      for (;;) {
        const secondsLeft = Math.max(0, Math.ceil((deadline - Date.now()) / 1000));
        setDelivery({ phase: 'confirming-restart', secondsLeft });

        let rows: unknown = null;
        let advertised = '';
        try {
          const unwrapped = unwrap(await cookieJsonFetch('/bridges'));
          rows = Array.isArray(unwrapped) ? unwrapped : unwrapped?.bridges;
          advertised = await fetchBridgePublicKey(targetBridgeId);
        } catch {
          // A transient poll failure is not a verdict; the deadline still applies.
        }

        const decision = enrollmentRestartConfirmation({
          rows,
          bridgeId: targetBridgeId,
          enrollmentPublicKey: hubKey,
          advertisedPublicKey: advertised,
          sealedPolls,
          expired: Date.now() >= deadline,
        });
        sealedPolls = decision.sealedPolls;
        if (decision.outcome === 'confirmed') {
          setDelivery({ phase: 'confirmed' });
          return;
        }
        if (decision.outcome === 'sealed' || decision.outcome === 'timed-out') {
          setDelivery({
            phase: 'restart-unconfirmed',
            reason: decision.outcome,
            vaultStatus: decision.vaultStatus,
          });
          return;
        }
        await new Promise((resolve) => setTimeout(resolve, BRIDGE_POLL_INTERVAL_MS));
      }
    },
    [hubKey],
  );

  /**
   * Encrypts the vault key for one bridge process. `enrollment` uses the
   * operator-confirmed key; `restarted` uses the key the service advertises now.
   */
  const deliverVaultKey = useCallback(
    async (
      targetBridgeId: string,
      vaultKeyMaterial: string | CryptoKey,
      target: UnsealTarget = 'enrollment',
    ) => {
      if (target === 'enrollment' && (!bridgeKeyReady || !fingerprintConfirmed)) {
        setDelivery({
          phase: 'failed',
          message:
            'The bridge fingerprint was not confirmed, so the vault key was not delivered.',
        });
        return;
      }

      setDelivery({ phase: 'delivering', target });
      try {
        let publicKey = hubKey;
        if (target === 'restarted') {
          publicKey = await fetchBridgePublicKey(targetBridgeId);
          if (!publicKey) {
            throw new Error('The bridge advertised no public key — it may have gone offline.');
          }
        }
        // Throws the bridge's typed error when it refuses the unseal.
        await unsealBridgeE2EE(targetBridgeId, publicKey, vaultKeyMaterial);
      } catch (err: any) {
        const message = String(err?.message || err);
        if (target === 'restarted') {
          // Enrollment already finished: stay on the warning, with the reason.
          setDelivery({
            phase: 'restart-unconfirmed',
            reason: 'sealed',
            vaultStatus: '',
            error: message,
          });
        } else {
          setDelivery({ phase: 'failed', message });
        }
        return;
      }
      if (target === 'enrollment') setDelivery({ phase: 'delivered' });
      await confirmRestart(targetBridgeId);
    },
    [bridgeKeyReady, fingerprintConfirmed, hubKey, confirmRestart],
  );

  /** "Unseal now": wrap the key for the restarted service, or ask for the password. */
  const unsealRestartedBridge = useCallback(async () => {
    if (!bridgeId) return;
    const active = getActiveBridgeVaultKeyMaterial() || getActiveVaultKey();
    if (isUnlocked && active && canUnsealWithKey(active)) {
      await deliverVaultKey(bridgeId, active, 'restarted');
      return;
    }
    setPasswordError('');
    setDelivery({ phase: 'need-password', target: 'restarted' });
  }, [bridgeId, isUnlocked, deliverVaultKey]);

  /** Obtains the vault key without ever degrading to a weaker payload. */
  const deliverToEnrollment = useCallback(
    async (targetBridgeId: string) => {
      const active = getActiveBridgeVaultKeyMaterial() || getActiveVaultKey();
      if (isUnlocked && active && canUnsealWithKey(active)) {
        await deliverVaultKey(targetBridgeId, active);
        return;
      }
      // A hardened or IndexedDB-restored handle cannot be wrapped, which is the
      // expected case rather than a malfunction. Ask the operator.
      setPasswordError('');
      setDelivery({ phase: 'need-password', target: 'enrollment' });
    },
    [isUnlocked, deliverVaultKey],
  );

  const startDelivery = useCallback(
    async (targetBridgeId: string) => {
      if (!(await waitForAuthenticatedBridge(targetBridgeId))) return;

      if (!vaultQuery.isLoading && !vaultEnvelope) {
        setDelivery({ phase: 'not-needed' });
        return;
      }
      await deliverToEnrollment(targetBridgeId);
    },
    [deliverToEnrollment, vaultEnvelope, vaultQuery.isLoading, waitForAuthenticatedBridge],
  );

  const handlePasswordSubmit = useCallback(
    async (e: FormEvent) => {
      e.preventDefault();
      if (!masterPassword || !vaultEnvelope || !bridgeId || passwordBusy) return;
      const target: UnsealTarget =
        delivery.phase === 'need-password' ? delivery.target : 'enrollment';
      setPasswordBusy(true);
      setPasswordError('');
      let unsealHex: string;
      try {
        const derived = await deriveKeyFromPassword(
          masterPassword,
          vaultEnvelope.kdf_salt,
          vaultEnvelope.kdf_iterations || DEFAULT_KDF_ITERATIONS,
        );
        // Two shapes from one envelope, as elsewhere: the hex is what the unseal
        // protocol has to transmit and dies with this closure; the handle
        // installed as the active key is imported NON-extractable.
        unsealHex = await decryptVaultKeyEnvelopeHex(
          derived,
          vaultEnvelope.encrypted_vault_key,
          vaultEnvelope.vault_key_nonce,
          vaultEnvelope.vault_key_tag,
        );
        const handle = await decryptVaultKeyEnvelope(
          derived,
          vaultEnvelope.encrypted_vault_key,
          vaultEnvelope.vault_key_nonce,
          vaultEnvelope.vault_key_tag,
        );
        dispatch(setVaultUnlocked({ key: handle, rememberSession }));
        setActiveBridgeVaultKeyMaterial(unsealHex);
      } catch {
        // The envelope is AES-GCM: a failed decrypt means the password is wrong.
        // Browsers word that OperationError differently (or not at all), so say
        // it plainly and keep the prompt open for another try.
        setPasswordError(WRONG_MASTER_PASSWORD_MESSAGE);
        setMasterPassword('');
        setPasswordBusy(false);
        return;
      }
      setMasterPassword('');
      setPasswordBusy(false);
      // Delivery reports its own failures (bridge refused, went offline).
      await deliverVaultKey(bridgeId, unsealHex, target);
    },
    [masterPassword, vaultEnvelope, bridgeId, passwordBusy, rememberSession, dispatch, deliverVaultKey, delivery],
  );

  /** Closing the prompt skips delivery; the enrolled bridge simply stays sealed. */
  const dismissPasswordPrompt = useCallback(() => {
    if (passwordBusy || delivery.phase !== 'need-password') return;
    const target = delivery.target;
    setMasterPassword('');
    setPasswordError('');
    if (target === 'restarted') {
      setDelivery({ phase: 'restart-unconfirmed', reason: 'sealed', vaultStatus: '', error: '' });
    } else {
      setDelivery({ phase: 'failed', message: 'You closed the password prompt.' });
    }
  }, [passwordBusy, delivery]);

  // ── The decision ────────────────────────────────────────────────────────

  const decide = useCallback(
    async (approve: boolean) => {
      // Belt and braces: the button is already disabled, but a code path that
      // could approve past a failed key check must not exist.
      if (approve && approvalBlocked) {
        setDecideError('Approval is blocked until you confirm the bridge fingerprint.');
        return;
      }
      setDeciding(true);
      setDecideError('');
      try {
        // Approve the code that was VERIFIED and displayed, not whatever the
        // input holds now. The field is also locked once a grant is on screen,
        // but a decision must not depend on an editable control agreeing with
        // what the operator was shown.
        const res = await cookieMutation('/device/approve', 'POST', {
          user_code: (verifiedCode || codeInput).trim(),
          approve,
          // Ignored server-side for anything but an approved bridge-enrollment
          // grant, so sending it unconditionally on a deny or a non-bridge
          // grant is harmless.
          target_bridge_id: targetBridgeId || undefined,
          new_bridge_label:
            grant?.is_bridge_enrollment === true && !targetBridgeId
              ? newBridgeLabel.trim()
              : undefined,
        });
        setDecision(approve ? 'approved' : 'rejected');

        const minted = String(unwrap(res)?.hub_observed?.bridge_id || '');
        if (approve && minted) {
          setBridgeId(minted);
          void startDelivery(minted);
        }
      } catch (err: any) {
        setDecideError(
          err?.status === 409
            ? 'This code was already used.'
            : String(err?.message || 'That code is not valid, or it has expired.'),
        );
      } finally {
        setDeciding(false);
      }
    },
    [approvalBlocked, codeInput, verifiedCode, startDelivery, targetBridgeId, grant?.is_bridge_enrollment, newBridgeLabel],
  );

  // ── Render ──────────────────────────────────────────────────────────────

  const isBridge = grant?.is_bridge_enrollment === true;

  return (
    <div
      data-debug-id="enrollment-approval-page"
      className="mx-auto flex min-h-full w-full max-w-lg items-start px-4 py-4 sm:py-6"
    >
      <section className="w-full rounded-2xl border border-subtle bg-surface p-5 shadow-2xl sm:p-7">
        <div className="mb-6 text-center">
          <div className="mx-auto mb-3 grid h-12 w-12 place-items-center rounded-2xl bg-accent-soft text-accent">
            <Icon name="device" size={22} />
          </div>
          <h1 className="text-xl font-semibold tracking-tight text-primary">
            {isBridge ? 'Approve this bridge?' : 'Approve this device?'}
          </h1>
          <p className="mt-2 text-sm leading-6 text-muted">
            Only continue if you started this request on a device you trust.
          </p>
        </div>

      {!grant && (
        <div style={{ marginBottom: 16 }}>
          <label htmlFor="user_code_1" style={{ fontSize: '0.8rem', display: 'block', marginBottom: 8 }}>
            Device code
          </label>
          <div
            data-debug-id="enrollment-device-code-input"
            className="mb-4 flex items-center justify-center gap-2"
            role="group"
            aria-label="Eight-character device code"
          >
            {Array.from({ length: DEVICE_CODE_LENGTH }, (_, index) => (
              <React.Fragment key={index}>
                {index === 4 && (
                  <span aria-hidden="true" className="px-0.5 text-xl font-semibold text-muted">
                    –
                  </span>
                )}
                <Input
                  ref={(node) => { codeInputRefs.current[index] = node; }}
                  id={`user_code_${index + 1}`}
                  data-debug-id={`enrollment-device-code-char-${index + 1}`}
                  aria-label={`Device code character ${index + 1} of ${DEVICE_CODE_LENGTH}`}
                  value={codeSymbols[index] ?? ''}
                  maxLength={1}
                  autoComplete="off"
                  autoCapitalize="characters"
                  autoCorrect="off"
                  spellCheck={false}
                  disabled={verifying}
                  className="h-12 w-10 p-0 text-center font-mono text-lg font-semibold uppercase sm:w-11"
                  onChange={(value) => putCodeSymbols(index, value)}
                  onPaste={(event) => handleCodePaste(index, event)}
                  onKeyDown={(event) => handleCodeKeyDown(index, event)}
                  onFocus={(event) => event.currentTarget.select()}
                />
              </React.Fragment>
            ))}
          </div>
          <Button
            data-debug-id="enrollment-device-code-submit-btn"
            variant="primary"
            onClick={() => void doVerify(codeInput)}
            disabled={
              verifying || normalizeDeviceCodeSymbols(codeInput).length !== DEVICE_CODE_LENGTH
            }
          >
            {verifying ? 'Checking…' : 'Continue'}
          </Button>
        </div>
      )}

      {verifyError && <Banner tone="danger" title="That code did not work">{verifyError}</Banner>}

      {grant && (
        <>
          {isBridge && !bridgeKeyReady && (
            <Banner tone="danger" title="This enrollment request has no usable bridge key.">
              Approval is disabled. Reject this request and restart enrollment on the machine.
            </Banner>
          )}
          {flagged.length > 0 && (
            <Banner tone="warn" title="This device name may be misleading.">
              The {flagged.join(' and ')} contained unusual or hidden characters. If you did not expect this,
              reject the request.
            </Banner>
          )}

          <dl className="mb-5 overflow-hidden rounded-xl border border-subtle bg-surface-raised/40">
            <div className="grid grid-cols-[7rem_1fr] gap-3 border-b border-subtle px-4 py-3">
              <dt className="text-sm text-muted">Hostname</dt>
              <dd
                data-debug-id="enrollment-device-hostname"
                className="min-w-0 break-words text-right text-sm font-medium text-primary"
              >
                {label.text || 'Unknown'}
              </dd>
            </div>
            <div className="grid grid-cols-[7rem_1fr] gap-3 border-b border-subtle px-4 py-3">
              <dt className="text-sm text-muted">Operating system</dt>
              <dd
                data-debug-id="enrollment-device-os"
                className="min-w-0 break-words text-right text-sm font-medium text-primary"
              >
                {os.text || 'Unknown'}
              </dd>
            </div>
            {isBridge && (
              <div className="grid grid-cols-[7rem_1fr] gap-3 px-4 py-3">
                <dt className="text-sm text-muted">Fingerprint</dt>
                <dd
                  data-debug-id="enrollment-device-fingerprint"
                  className="min-w-0 break-words text-right font-mono text-sm font-semibold text-primary"
                >
                  {hubFingerprint || 'Unavailable'}
                </dd>
              </div>
            )}
          </dl>

          {decision === 'none' && isBridge && bridgeKeyReady && (
            <label
              data-debug-id="enrollment-fingerprint-confirm-label"
              className="mb-4 flex cursor-pointer items-start gap-3 rounded-xl border border-subtle bg-surface-raised/40 px-4 py-3 text-sm text-primary"
            >
              <input
                data-debug-id="enrollment-fingerprint-confirm-checkbox"
                type="checkbox"
                checked={fingerprintConfirmed}
                disabled={deciding}
                onChange={(event) => setFingerprintConfirmed(event.target.checked)}
              />
              <span>
                This fingerprint exactly matches the one printed by the bridge enrollment command.
              </span>
            </label>
          )}

          {decision === 'none' && isBridge && (
            <div className="mb-4 space-y-3">
              {bridgeTargets.length > 0 && (
                <div>
                  <label htmlFor="target_bridge_id" className="mb-1 block text-xs font-medium text-muted">
                    Bridge identity
                  </label>
                  <Select
                    id="target_bridge_id"
                    data-debug-id="enrollment-bridge-identity-select"
                    value={targetBridgeId}
                    onChange={setTargetBridgeId}
                    disabled={deciding}
                  >
                    <option value="">Create a new bridge</option>
                    {bridgeTargets.map((b) => (
                      <option key={b.bridge_id} value={b.bridge_id}>
                        {(b.label || b.bridge_id || 'bridge') +
                          ' (' +
                          (b.machine_hostname || 'unknown host') +
                          ')'}
                      </option>
                    ))}
                  </Select>
                </div>
              )}
              {!targetBridgeId && (
                <div>
                  <label htmlFor="new_bridge_label" className="mb-1 block text-xs font-medium text-muted">
                    Bridge name
                  </label>
                  <Input
                    id="new_bridge_label"
                    data-debug-id="enrollment-new-bridge-name-input"
                    value={newBridgeLabel}
                    onChange={setNewBridgeLabel}
                    disabled={deciding}
                    maxLength={128}
                  />
                </div>
              )}
              {targetBridgeId && (
                <p className="text-xs leading-5 text-warning">
                  This replaces that bridge's credential and disconnects it, ending any of its
                  running sessions.
                </p>
              )}
            </div>
          )}

          {decision === 'none' ? (
            <div style={{ display: 'flex', gap: 8 }}>
              <Button
                data-debug-id="enrollment-approve-btn"
                variant="primary"
                onClick={() => void decide(true)}
                disabled={
                  deciding ||
                  approvalBlocked ||
                  (isBridge && !targetBridgeId && !newBridgeLabel.trim())
                }
                title={approvalBlocked ? 'Confirm the bridge fingerprint before approving.' : undefined}
              >
                {deciding ? 'Working…' : 'Approve'}
              </Button>
              <Button
                data-debug-id="enrollment-reject-btn"
                onClick={() => void decide(false)}
                disabled={deciding}
              >
                Reject
              </Button>
            </div>
          ) : (
            <Banner
              tone={decision === 'approved' ? 'ok' : 'warn'}
              title={decision === 'approved' ? 'Approval accepted.' : 'Rejected.'}
            >
              {decision === 'approved'
                ? 'Waiting for this bridge to authenticate and connect to the Hub.'
                : 'The code no longer works.'}
            </Banner>
          )}

          {decideError && <Banner tone="danger" title="That did not work">{decideError}</Banner>}

          {/* ── Vault delivery status ───────────────────────────────────── */}
          {delivery.phase === 'waiting-for-bridge' && (
            <Banner tone="warn" title="Waiting for the bridge to connect…">
              <span style={{ display: 'inline-flex', alignItems: 'center', gap: 8 }}>
                <Icon name="refresh" size={16} className="animate-spin" />
                Waiting for the approved bridge to authenticate with the Hub. Giving up in{' '}
                {delivery.secondsLeft}s.
              </span>
            </Banner>
          )}
          {delivery.phase === 'delivering' && (
            <Banner tone="warn" title="Delivering the vault key…">
              {delivery.target === 'restarted'
                ? 'Encrypting to the key the restarted bridge advertises and sending it through the Hub as ciphertext.'
                : 'Encrypting to the key from your link and sending it through the Hub as ciphertext.'}
            </Banner>
          )}
          {(delivery.phase === 'delivered' || delivery.phase === 'confirming-restart') && (
            <Banner tone="warn" title="Vault key delivered, waiting for the bridge to restart and confirm…">
              <span style={{ display: 'inline-flex', alignItems: 'center', gap: 8 }}>
                <Icon name="refresh" size={16} className="animate-spin" />
                The enrolling process received the key and is restarting the bridge service, which must
                unseal itself from the saved key.
                {delivery.phase === 'confirming-restart' && <> Giving up in {delivery.secondsLeft}s.</>}
              </span>
            </Banner>
          )}
          {delivery.phase === 'confirmed' && (
            <Banner tone="ok" title="Bridge restarted and confirmed unsealed">
              The bridge is enrolled, and its restarted service reports the vault unlocked.
            </Banner>
          )}
          {delivery.phase === 'restart-unconfirmed' && (
            <Banner
              tone="warn"
              title={
                delivery.reason === 'sealed'
                  ? 'The bridge restarted but is still sealed.'
                  : 'Could not confirm the bridge unsealed after restarting.'
              }
            >
              <p style={{ margin: '0 0 8px' }}>
                {delivery.reason === 'sealed'
                  ? `It reports its vault ${delivery.vaultStatus || 'locked'}, so it could not read the saved key.`
                  : `The restarted service did not report an unlocked vault within ${RESTART_CONFIRMATION_TIMEOUT_SECONDS}s.`}{' '}
                The enrollment itself succeeded.
              </p>
              {delivery.error && <p style={{ margin: '0 0 8px' }}>{delivery.error}</p>}
              <Button
                data-debug-id="enrollment-unseal-now-btn"
                variant="primary"
                onClick={() => void unsealRestartedBridge()}
              >
                Unseal now
              </Button>
            </Banner>
          )}
          {delivery.phase === 'not-needed' && (
            <Banner tone="ok" title="Enrollment approved.">
              The bridge authenticated successfully.
            </Banner>
          )}
          {decision === 'approved' && bridgeConnected && bridgeId &&
          enrollmentContinueAvailable(
            delivery.phase,
            delivery.phase === 'need-password' || delivery.phase === 'delivering'
              ? delivery.target
              : undefined,
          ) ? (
            <Button
              variant="primary"
              data-debug-id="enrollment-continue-provider-selection-btn"
              onClick={() => navigateEnrollmentProviderSetup(bridgeId)}
            >
              Continue to provider selection
            </Button>
          ) : null}
          {delivery.phase === 'timed-out' && (
            <Banner tone="warn" title="The bridge did not connect in time.">
              The machine was approved, but Heimdall could not confirm that this bridge authenticated and
              connected. Leave this page open and retry enrollment if it does not appear in Settings → Bridges.
            </Banner>
          )}
          {delivery.phase === 'failed' && (
            <Banner tone="danger" title="The vault key was not delivered.">
              <p style={{ margin: '0 0 8px' }}>
                {delivery.message} The enrollment itself succeeded; the bridge is approved but still sealed.
                Retry now, or unlock it later from Settings → Bridges.
              </p>
              {bridgeId && (
                <Button
                  data-debug-id="enrollment-retry-delivery-btn"
                  variant="secondary"
                  onClick={() => void deliverToEnrollment(bridgeId)}
                >
                  Retry
                </Button>
              )}
            </Banner>
          )}
          <Modal
            open={delivery.phase === 'need-password'}
            onOpenChange={(open) => { if (!open) dismissPasswordPrompt(); }}
            title="Unlock vault for this bridge"
            data-debug-id="enrollment-unlock-modal"
          >
            <form onSubmit={(e) => void handlePasswordSubmit(e)}>
              <ModalBody className="space-y-4">
                <div className="flex items-center gap-2">
                  <Icon name="lock" size="md" className="text-accent" />
                  <h3 className="text-base font-semibold text-primary">Unlock vault for this bridge</h3>
                </div>
                <p className="text-xs leading-relaxed text-muted">
                  Enter your master password to deliver the vault key to the bridge. It is used for this delivery
                  only and is not stored.
                </p>
                <Input
                  data-debug-id="enrollment-master-password-input"
                  type="password"
                  value={masterPassword}
                  autoComplete="current-password"
                  placeholder="Master password"
                  autoFocus
                  required
                  className="min-h-[44px] w-full"
                  onChange={(value) => {
                    setMasterPassword(value);
                    if (passwordError) setPasswordError('');
                  }}
                />
                <label
                  data-debug-id="enrollment-remember-session-label"
                  className="flex min-h-[44px] cursor-pointer items-center gap-2 text-xs text-muted"
                >
                  <input
                    data-debug-id="enrollment-remember-session-checkbox"
                    type="checkbox"
                    checked={rememberSession}
                    onChange={(e) => setRememberSession(e.target.checked)}
                    className="min-h-[20px] min-w-[20px] rounded text-accent focus:ring-accent"
                  />
                  <span>Keep the vault unlocked for this session</span>
                </label>
                {passwordError ? (
                  <div
                    role="alert"
                    data-debug-id="enrollment-unlock-modal-error"
                    className="rounded-lg border border-danger/30 bg-danger-soft p-2.5 text-xs text-danger"
                  >
                    {passwordError}
                  </div>
                ) : null}
              </ModalBody>
              <ModalFooter>
                <Button
                  variant="secondary"
                  data-debug-id="enrollment-unlock-modal-cancel"
                  disabled={passwordBusy}
                  onClick={dismissPasswordPrompt}
                >
                  Not now
                </Button>
                <Button
                  data-debug-id="enrollment-deliver-vault-key-btn"
                  variant="primary"
                  type="submit"
                  loading={passwordBusy}
                  disabled={!masterPassword}
                >
                  Unlock &amp; deliver
                </Button>
              </ModalFooter>
            </form>
          </Modal>

        </>
      )}
      </section>
    </div>
  );
}
