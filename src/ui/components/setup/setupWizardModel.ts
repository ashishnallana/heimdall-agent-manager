// First-run setup wizard (/setup): the pure parts, unit-tested in
// tests/ui_setup_wizard_test.ts. The page is components/setup/SetupWizardPage.tsx.
//
// Flow: detect this machine → (connected: status, update, uninstall) or (install +
// pair with live log) → bridge identity (reuse one, or register new and sunset one
// when the plan is full) → agents → projects from past sessions → New conversation.

import type { DesktopBridgeStatus, WizardModel, WizardStepState } from '../../bridge/desktopBridge';
import type { ReusableBridge } from '../../api/endpoints/vaultDevices';

export type SetupStep = 'detect' | 'machine' | 'install' | 'identity' | 'agents' | 'projects';

/** Reuse an unenrolled local slot, or suggest a free name without touching
 * another account's enrolled slot. Empty string is the valid default profile. */
export function setupProfileChoices(profiles: DesktopBridgeStatus[]): string[] {
  const enrolled = new Set(profiles.filter((p) => p.enrolled).map((p) => p.profile || ''));
  const choices = new Set(profiles.filter((p) => !p.enrolled).map((p) => p.profile || ''));
  if (!enrolled.has('')) choices.add('');
  if (!choices.size) {
    for (let n = 2; ; n += 1) {
      const name = `account-${n}`;
      if (!enrolled.has(name)) { choices.add(name); break; }
    }
  }
  return [...choices].filter((p) => !enrolled.has(p));
}

export type RailState = 'done' | 'current' | 'todo';

export interface RailItem {
  id: 'machine' | 'install' | 'identity' | 'agents' | 'projects';
  label: string;
  hint: string;
  state: RailState;
}

const RAIL: { id: RailItem['id']; label: string; hint: string; skippedHint: string }[] = [
  { id: 'machine', label: 'This machine', hint: 'Find its bridge', skippedHint: 'Connected' },
  { id: 'install', label: 'Install & enroll', hint: 'Runtime and pairing', skippedHint: 'Already done' },
  { id: 'identity', label: 'Bridge identity', hint: 'Finish enrolling', skippedHint: 'Already done' },
  { id: 'agents', label: 'Agents', hint: 'Claude Code, Codex…', skippedHint: '' },
  { id: 'projects', label: 'Projects', hint: 'From past sessions', skippedHint: '' },
];

const RAIL_INDEX: Record<SetupStep, number> = { detect: 0, machine: 0, install: 1, identity: 2, agents: 3, projects: 4 };

/**
 * The left rail. `alreadyConnected`: this machine already ran the signed-in
 * account's bridge, so Install and Identity were never needed and show as done.
 */
export function setupRail(step: SetupStep, alreadyConnected: boolean): RailItem[] {
  const current = RAIL_INDEX[step];
  return RAIL.map((item, index) => {
    const skipped = alreadyConnected && (item.id === 'install' || item.id === 'identity');
    const state: RailState = index === current ? 'current' : index < current || skipped ? 'done' : 'todo';
    return { id: item.id, label: item.label, hint: alreadyConnected && item.skippedHint ? item.skippedHint : item.hint, state };
  });
}

// ---------------------------------------------------------------------------
// Install: the setup operation's rows folded down to Download → Install → Pair.
// ---------------------------------------------------------------------------

export interface InstallRow {
  id: 'download' | 'install' | 'pair';
  label: string;
  state: WizardStepState;
  message: string;
}

/**
 * ham-bridge's own rows (desktopBridge WIZARD_STEPS) shown as three. Pairing is
 * the `enroll` row; while the pairing code is out it is "waiting for you",
 * which the wizard answers on its identity step.
 */
export function installRows(wizard: WizardModel): InstallRow[] {
  const row = (id: string) => wizard.steps.find((s) => s.id === id);
  const download = row('download');
  const install = row('install');
  const enroll = row('enroll');
  return [
    { id: 'download', label: 'Download', state: download?.state || 'pending', message: download?.message || '' },
    { id: 'install', label: 'Install', state: install?.state || 'pending', message: install?.message || '' },
    {
      id: 'pair',
      label: 'Pair',
      state: enroll?.state || 'pending',
      message: wizard.pairing ? 'Waiting for you to choose a bridge identity' : enroll?.message || '',
    },
  ];
}

export function installRowStatus(state: WizardStepState): string {
  switch (state) {
    case 'ok': return 'Done';
    case 'skipped': return 'Skipped';
    case 'running': return 'Running';
    case 'recovering': return 'Retrying';
    case 'failed': return 'Failed';
    default: return 'Waiting';
  }
}

// ---------------------------------------------------------------------------
// Identity: reuse one of the account's bridges, or register this machine as a
// new bridge — which, when the plan is full, needs one bridge to sunset.
// ---------------------------------------------------------------------------

export interface IdentityChoice {
  mode: 'reuse' | 'new' | '';
  reuseId: string;
  sunsetId: string;
}

export const EMPTY_IDENTITY_CHOICE: IdentityChoice = { mode: '', reuseId: '', sunsetId: '' };

export interface SunsetCandidate {
  bridge_id: string;
  label: string;
  machine_hostname: string;
  status: string;
}

/** The account's bridges that still count against the plan (not revoked). */
export function sunsetCandidates(bridges: readonly any[] | null | undefined): SunsetCandidate[] {
  return (Array.isArray(bridges) ? bridges : [])
    .filter((b) => b && !b.revoked_at && String(b.status || '').toLowerCase() !== 'revoked')
    .map((b) => ({
      bridge_id: String(b.bridge_id || b.id || ''),
      label: String(b.label || b.machine_hostname || b.bridge_id || ''),
      machine_hostname: String(b.machine_hostname || b.hostname || ''),
      status: String(b.status || ''),
    }))
    .filter((b) => /^brg_[A-Za-z0-9_-]{1,60}$/.test(b.bridge_id));
}

export interface IdentityPlan {
  /** Ready to approve. */
  ok: boolean;
  /** The approve button's label. */
  action: string;
  /** Reuse target (must be one the hub listed as reusable). */
  reuse: ReusableBridge | null;
  /** Bridge the hub retires atomically with this approval (plan full). */
  sunset: SunsetCandidate | null;
}

/**
 * Turn the user's picks into what approval will do. A new bridge at plan
 * capacity is only allowed once a bridge to sunset is picked; the hub revokes the
 * sunset bridge in the same transaction that admits the new one (sunset_bridge_id),
 * so it is never revoked up front.
 */
export function identityPlan(
  choice: IdentityChoice,
  reusable: readonly ReusableBridge[],
  candidates: readonly SunsetCandidate[],
  atCapacity: boolean,
): IdentityPlan {
  if (choice.mode === 'reuse') {
    const reuse = reusable.find((b) => b.bridge_id === choice.reuseId) || null;
    return { ok: Boolean(reuse), action: reuse ? `Use ${reuse.label || reuse.bridge_id} and finish` : 'Choose an identity', reuse, sunset: null };
  }
  if (choice.mode === 'new') {
    if (!atCapacity) return { ok: true, action: 'Register and finish', reuse: null, sunset: null };
    const sunset = candidates.find((b) => b.bridge_id === choice.sunsetId) || null;
    return { ok: Boolean(sunset), action: sunset ? `Register and sunset ${sunset.label}` : 'Choose a bridge to sunset', reuse: null, sunset };
  }
  return { ok: false, action: 'Choose an identity', reuse: null, sunset: null };
}

/**
 * What a failed "register new and sunset one" approval did to the sunset bridge, read
 * from the bridge list fetched AFTER the failure (`refreshed`; null when that fetch
 * failed), never inferred from how far the client got: a POST can commit on the hub
 * and still fail on the client (lost response, proxy error after commit).
 *
 * The hub retires the bridge in the transaction that approves this machine and gives
 * it back when the pending enrollment rolls back (refused or failed vault commit at
 * once; cancel or the 5-minute expiry otherwise), unless its plan slot was taken in
 * the meantime. It is final only once this machine finishes enrolling.
 */
export function sunsetFailureNote(sunset: { bridge_id: string; label: string }, refreshed: readonly any[] | null): string {
  const label = sunset.label || sunset.bridge_id;
  if (!refreshed) {
    return `Could not check whether ${label} is still active; see Bridges. If it was retired for this approval, it comes back on its next retry after the unfinished enrollment is cancelled or expires, unless its plan slot is used meanwhile. Pending enrollments expire after 5 minutes. `;
  }
  if (sunsetCandidates(refreshed).some((b) => b.bridge_id === sunset.bridge_id)) return `${label} is still active. `;
  return `${label} is retired while this approval is pending. If this machine does not finish enrolling, ${label} comes back on its next retry after the enrollment is cancelled or expires, unless its plan slot is used meanwhile. Pending enrollments expire after 5 minutes. `;
}

// ---------------------------------------------------------------------------
// Updates and first-run bookkeeping.
// ---------------------------------------------------------------------------

/** The Hub's row for this machine's bridge has a newer release it can install. */
export function bridgeHasUpdate(row: any): boolean {
  return Boolean(row?.update_available) && row?.update_artifact_available !== false;
}

const SEEN_PREFIX = 'ninjy.setup.done.';

/** True once this account finished or skipped setup in this app. */
export function setupSeen(userId: string, storage: Pick<Storage, 'getItem'> | null = safeStorage()): boolean {
  if (!userId || !storage) return true;
  try { return storage.getItem(SEEN_PREFIX + userId) === '1'; } catch { return true; }
}

export function markSetupSeen(userId: string, storage: Pick<Storage, 'setItem'> | null = safeStorage()): void {
  if (!userId || !storage) return;
  try { storage.setItem(SEEN_PREFIX + userId, '1'); } catch { /* private window: shown again next launch */ }
}

function safeStorage(): Storage | null {
  try { return typeof window === 'undefined' ? null : window.localStorage; } catch { return null; }
}
