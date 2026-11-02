// Composer "Bypass permissions" toggle (instance permission_mode). Pure logic,
// no React and no fetch, so every rule is unit-testable
// (tests/ui_composer_permission_toggle_test.ts).
//
// Sources:
//   - GET /bridges/{id}/provider-status → providers[].extension.capabilities: the
//     provider catalog's extension descriptor. The toggle exists only when it
//     declares "permissions".
//   - The agent instance JSON → effective_permission_mode (what the running
//     agent was launched with) and extension.capabilities (what the running
//     extension reported in its hello).

import type { ApplyInstanceConfigurationInput } from '../../api/endpoints/agents';
import {
  normalizeInstanceExtension,
  normalizeProviderExtension,
} from '../extension/extensionBadgeModel.ts';

export type PermissionMode = 'yolo' | 'ask';

export const PERMISSIONS_CAPABILITY = 'permissions';
export const INSTALL_EXTENSION_HINT = 'Install the provider extension to require approvals';
export const PENDING_CHANGES_HINT = 'Apply or reset the other changes first.';

export interface PermissionToggleInput {
  /** providers[].extension from the bridge provider-status for the instance's provider. */
  catalogExtension: unknown;
  /** The instance JSON (`effective_permission_mode`, `extension`). */
  instance: any;
  /** A configuration change or runtime action is in flight. */
  busy?: boolean;
  /** The settings panel has staged, unapplied provider/model/bridge edits. */
  pendingChanges?: boolean;
}

export interface PermissionToggleState {
  /** Render the toggle at all (catalog declares "permissions"). */
  visible: boolean;
  /** Checked = bypass permissions (yolo). */
  bypass: boolean;
  disabled: boolean;
  /** Short helper text ('' = none). */
  hint: string;
}

/** effective_permission_mode from the instance JSON; anything but "ask" is yolo. */
export function effectivePermissionMode(instance: any): PermissionMode {
  return instance?.effective_permission_mode === 'ask' ? 'ask' : 'yolo';
}

/** Whether the provider catalog's extension declares the permissions capability. */
export function catalogSupportsPermissions(catalogExtension: unknown): boolean {
  const ext = normalizeProviderExtension(catalogExtension);
  return Boolean(ext && ext.state !== 'unsupported' && ext.capabilities.includes(PERMISSIONS_CAPABILITY));
}

/** Whether the running instance's extension reported the permissions capability. */
export function instanceReportsPermissions(instance: any): boolean {
  return Boolean(normalizeInstanceExtension(instance?.extension)?.capabilities.includes(PERMISSIONS_CAPABILITY));
}

export function permissionToggleState(input: PermissionToggleInput): PermissionToggleState {
  const bypass = effectivePermissionMode(input.instance) === 'yolo';
  if (!catalogSupportsPermissions(input.catalogExtension)) {
    return { visible: false, bypass, disabled: true, hint: '' };
  }
  // Turning bypass OFF needs the running extension, otherwise approvals would
  // only appear in the terminal. Turning it back ON is always allowed.
  if (bypass && !instanceReportsPermissions(input.instance)) {
    return { visible: true, bypass, disabled: true, hint: INSTALL_EXTENSION_HINT };
  }
  if (input.pendingChanges) return { visible: true, bypass, disabled: true, hint: PENDING_CHANGES_HINT };
  return { visible: true, bypass, disabled: Boolean(input.busy), hint: '' };
}

/**
 * The reconfiguration that flips the toggle: the instance's CURRENT destination
 * (same bridge, project, provider, model) plus the new permission_mode, so the
 * hub restarts the agent with or without the provider's yolo flags.
 */
export function permissionToggleRequest(
  instance: any,
  bypass: boolean,
  idempotencyKey: string,
): ApplyInstanceConfigurationInput {
  return {
    instanceId: String(instance?.agent_instance_id || ''),
    bridge_id: String(instance?.bridge_id || ''),
    project_id: String(instance?.project_id || ''),
    provider: String(instance?.provider || ''),
    ...(instance?.provider_profile ? { provider_profile: String(instance.provider_profile) } : {}),
    model: String(instance?.model || ''),
    expected_revision: Number(instance?.configuration_revision || 0),
    idempotency_key: idempotencyKey,
    permission_mode: bypass ? 'yolo' : 'ask',
  };
}
