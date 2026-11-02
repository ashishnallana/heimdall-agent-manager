// Fleet provider/model selection logic (REQ-FLEET-PT-3) and the restart-confirmation
// decision that guards it (REQ-RS-3 / REQ-RS-4).
//
// DELIBERATELY DEPENDENCY-FREE leaf module (following repository conventions, see
// src/ui/search/scopedSearchLogic.ts) so `node --test` can exercise the Fleet
// Management drawer's provider/model draft + change-detection logic directly,
// without a bundler or DOM. FleetManagementDrawer.tsx consumes these helpers.
//
// Semantics: provider/model are per-fleet-role strings where '' means "inherit"
// (the bridge/agent defaults), matching the hub contract where fleet JSON always
// carries both fields and PUT /task-chains/:id/fleets/:agentId accepts them.

export interface FleetProviderModel {
  provider: string;
  provider_profile?: string;
  model: string;
}

export interface FleetProviderCapability {
  provider: string;
  profile_id?: string; label?: string; accent?: string;
  models: string[];
}

/** Resolve an omitted fleet selection in the same catalog order as JIT launch. */
export function resolvedFleetProviderModel(
  selection: FleetProviderModel,
  capabilities: FleetProviderCapability[],
): FleetProviderModel {
  if (selection.provider && selection.model) return { ...selection };
  for (const capability of capabilities) {
    if (selection.provider && (selection.provider !== capability.provider || (selection.provider_profile || selection.provider) !== (capability.profile_id || capability.provider))) continue;
    const model = selection.model
      ? capability.models.find((model) => model === selection.model)
      : capability.models[0];
    if (model) return { provider: capability.provider, model, ...(capability.profile_id ? { provider_profile: capability.profile_id } : {}) };
  }
  return { ...selection };
}

/**
 * Provider/model options from a bridge providers payload. The live
 * GET /bridges/:id/provider-status is normalized to literal active model ids.
 */
export function fleetProviderCapabilities(providersPayload: any): FleetProviderCapability[] {
  const source = Array.isArray(providersPayload?.providers) ? providersPayload.providers : [];
  const list: FleetProviderCapability[] = [];
  for (const entry of source) {
    if (entry === null || typeof entry !== 'object') continue;
    if (entry.enabled === false) continue;
    const provider = String(entry.provider || entry.name || '');
    if (!provider) continue;
    let models: string[];
    if (Array.isArray(entry.models)) {
      models = entry.models.map((t: any) => String(t)).filter(Boolean);
    } else {
      const modelMap = entry.models && typeof entry.models === 'object' ? entry.models : {};
      models = Object.keys(modelMap).filter((model) => Boolean(modelMap[model]));
    }
    list.push({ provider, models, ...(entry.profile_id ? { profile_id: entry.profile_id, label: entry.label, accent: entry.accent } : {}) });
  }
  return list;
}

export const FLEET_ROLES = ['worker', 'reviewer'] as const;

/**
 * A fleet role name: `worker` is the work role; any other name is a REVIEW role a
 * brief can require via review_roles (`reviewer`, `security`, `ux`, …). Mirrors the
 * hub's fleet_role_name_valid: 1–32 chars of [a-z0-9_-], starting with a letter.
 */
export function isValidFleetRoleName(role: string): boolean {
  return /^[a-z][a-z0-9_-]{0,31}$/.test(role);
}

/** Normalize a fleet roles array: valid, de-duplicated roles with worker/reviewer first (canonical order) and custom review roles after, defaulting to ['worker', 'reviewer'] (or fallback). */
export function normalizeFleetRoles(roles?: any, fallback: string[] = ['worker', 'reviewer']): string[] {
  if (!Array.isArray(roles)) return fallback.slice();
  const cleaned = roles.map((item: any) => String(item || '').trim().toLowerCase()).filter(isValidFleetRoleName);
  const builtin = FLEET_ROLES.filter((r) => cleaned.includes(r));
  const custom = Array.from(new Set(cleaned.filter((r) => !(FLEET_ROLES as readonly string[]).includes(r))));
  const valid = [...builtin, ...custom];
  return valid.length > 0 ? valid : fallback.slice();
}

/** Toggle a role (worker, reviewer or a custom review role) in a roles array while guaranteeing at least one role stays selected. */
export function toggleFleetRole(currentRoles: string[] | undefined, role: string): string[] {
  const normalized = normalizeFleetRoles(currentRoles);
  const target = String(role || '').trim().toLowerCase();
  if (!isValidFleetRoleName(target)) return normalized;
  if (normalized.includes(target)) {
    // Prevent deselecting the last remaining role
    if (normalized.length <= 1) return normalized;
    return normalized.filter((r) => r !== target);
  }
  return normalizeFleetRoles([...normalized, target]);
}

/** Format a concise role badge label for role cards (e.g. 'worker + reviewer', 'reviewer + security'). */
export function formatFleetRolesBadge(roles?: string[]): string {
  const norm = normalizeFleetRoles(roles);
  return norm.join(' + ') || 'worker';
}

export interface FleetPlacementDrafts {
  roles?: Record<string, string[]>;
  bridgeIds?: Record<string, string>;
  topLevelProviderModels?: Record<string, FleetProviderModel>;
  minWarms?: Record<string, number>;
  idleTtls?: Record<string, number>;
}

export interface ChangedFleetEntry {
  provider_profile?: string;
  bridgeModels?: Record<string, FleetProviderModel>;
  agentId: string;
  capacity: number;
  provider: string;
  model: string;
  roles?: string[];
  bridgeId?: string;
  minWarm?: number;
  idleTtlSeconds?: number;
}

function fleetAgentId(f: any): string {
  return String(f?.agent_id || f?.agentId || '');
}

function fleetProviderModel(f: any): FleetProviderModel {
  return { provider: String(f?.provider || ''), model: String(f?.model || ''), ...(f?.provider_profile ? { provider_profile: String(f.provider_profile) } : {}) };
}

function fleetBridgeId(f: any): string {
  return String(f?.bridge_id ?? f?.bridgeId ?? '');
}

/** Draft provider/model per role, seeded from server-returned fleets ('' = inherit). */
export function seedProviderModelDrafts(fleets: any[]): Record<string, FleetProviderModel> {
  const init: Record<string, FleetProviderModel> = {};
  for (const f of fleets || []) {
    const aid = fleetAgentId(f);
    if (!aid) continue;
    init[aid] = fleetProviderModel(f);
  }
  return init;
}

/** Draft roles per fleet template, seeded from server-returned fleets (defaults to ['worker']). */
export function seedFleetRolesDrafts(fleets: any[]): Record<string, string[]> {
  const init: Record<string, string[]> = {};
  for (const f of fleets || []) {
    const aid = fleetAgentId(f);
    if (!aid) continue;
    init[aid] = normalizeFleetRoles(f?.roles);
  }
  return init;
}

/** Draft bridge placement per fleet template, seeded from server-returned fleets ('' = inherit). */
export function seedFleetBridgeIdDrafts(fleets: any[]): Record<string, string> {
  const init: Record<string, string> = {};
  for (const f of fleets || []) {
    const aid = fleetAgentId(f);
    if (!aid) continue;
    init[aid] = fleetBridgeId(f);
  }
  return init;
}

/** Draft min_warm per fleet template, seeded from server-returned fleets (defaults to 0). */
export function seedFleetMinWarmDrafts(fleets: any[]): Record<string, number> {
  const init: Record<string, number> = {};
  for (const f of fleets || []) {
    const aid = fleetAgentId(f);
    if (!aid) continue;
    const mw = typeof f?.min_warm === 'number' ? f.min_warm : (typeof f?.minWarm === 'number' ? f.minWarm : 0);
    init[aid] = mw;
  }
  return init;
}

/** Draft idle_ttl_seconds per fleet template, seeded from server-returned fleets (defaults to 600). */
export function seedFleetIdleTtlDrafts(fleets: any[]): Record<string, number> {
  const init: Record<string, number> = {};
  for (const f of fleets || []) {
    const aid = fleetAgentId(f);
    if (!aid) continue;
    const ttl = typeof f?.idle_ttl_seconds === 'number' ? f.idle_ttl_seconds : (typeof f?.idleTtlSeconds === 'number' ? f.idleTtlSeconds : 600);
    init[aid] = ttl;
  }
  return init;
}

/** Server/original provider+model for a role; roles without a persisted row inherit ''/''. */
export function getOriginalProviderModel(fleets: any[], agentId: string): FleetProviderModel {
  const found = (fleets || []).find((f) => fleetAgentId(f) === agentId);
  return found ? fleetProviderModel(found) : { provider: '', model: '' };
}

/** Server/original roles for a fleet row; unpersisted rows return null. */
export function getOriginalFleetRoles(fleets: any[], agentId: string): string[] | null {
  const found = (fleets || []).find((f) => fleetAgentId(f) === agentId);
  if (!found) return null;
  return normalizeFleetRoles(found.roles);
}

/** Server/original bridge_id for a fleet row; unpersisted rows return ''. */
export function getOriginalFleetBridgeId(fleets: any[], agentId: string): string {
  const found = (fleets || []).find((f) => fleetAgentId(f) === agentId);
  return found ? fleetBridgeId(found) : '';
}

/** Server/original min_warm for a fleet row; unpersisted rows return 0. */
export function getOriginalFleetMinWarm(fleets: any[], agentId: string): number {
  const found = (fleets || []).find((f) => fleetAgentId(f) === agentId);
  if (!found) return 0;
  return typeof found.min_warm === 'number' ? found.min_warm : (typeof found.minWarm === 'number' ? found.minWarm : 0);
}

/** Server/original idle_ttl_seconds for a fleet row; unpersisted rows return 600. */
export function getOriginalFleetIdleTtl(fleets: any[], agentId: string): number {
  const found = (fleets || []).find((f) => fleetAgentId(f) === agentId);
  if (!found) return 600;
  return typeof found.idle_ttl_seconds === 'number'
    ? found.idle_ttl_seconds
    : (typeof found.idleTtlSeconds === 'number' ? found.idleTtlSeconds : 600);
}

export function fleetRolesEqual(a: string[] | undefined | null, b: string[] | undefined | null): boolean {
  const na = normalizeFleetRoles(a);
  const nb = normalizeFleetRoles(b);
  if (na.length !== nb.length) return false;
  return na.every((r, idx) => r === nb[idx]);
}

/** Model options offered by the selected provider; '' (Auto) provider has none. */
export function modelOptionsForProvider(capabilities: FleetProviderCapability[], provider: string, profileId?: string): string[] {
  if (!provider) return [];
  const cap = (capabilities || []).find((c) => c && c.provider === provider && (c.profile_id || c.provider) === (profileId || provider));
  return cap ? (cap.models || []).slice() : [];
}

/**
 * Model to keep when a role's provider changes: a model the new provider does not
 * offer would yield a provider/model pair the bridge can never launch, so it
 * falls back to '' (Auto).
 */
export function nextModelOnProviderChange(
  currentModel: string,
  nextProvider: string,
  capabilities: FleetProviderCapability[],
): string {
  if (!nextProvider) return '';
  return modelOptionsForProvider(capabilities, nextProvider).includes(currentModel) ? currentModel : '';
}

/** Server/original capacity for a role; null = role not persisted. */
export function getOriginalFleetCapacity(fleets: any[], agentId: string): number | null {
  const found = (fleets || []).find((f) => fleetAgentId(f) === agentId);
  if (found) return typeof found.capacity === 'number' ? found.capacity : 1;
  return null;
}

/**
 * Draft provider/model per role and per bridge: Record<agentId, Record<bridgeId, FleetProviderModel>>
 * Seeding maps each active bridge to its configured provider & model, defaulting to '' (inherit).
 */
export function seedPerBridgeProviderModelDrafts(
  fleets: any[],
  bridges: any[],
  preferredBridgeId?: string,
): Record<string, Record<string, FleetProviderModel>> {
  const base = seedProviderModelDrafts(fleets);
  const result: Record<string, Record<string, FleetProviderModel>> = {};
  for (const f of fleets || []) {
    const aid = fleetAgentId(f);
    if (!aid) continue;
    result[aid] = {};
    const basePT = base[aid] || { provider: '', model: '' };
    for (const b of bridges || []) {
      const bId = String(b.bridge_id || b.bridgeId || b.id || '');
      if (!bId) continue;
      result[aid][bId] = { ...(f.bridge_models?.[bId] || basePT) };
    }
    if (preferredBridgeId && !result[aid][preferredBridgeId]) {
      result[aid][preferredBridgeId] = { ...basePT };
    }
  }
  return result;
}

/**
 * Returns true if any bridge in the role's drafts has custom provider or model overrides.
 */
export function hasCustomRuntimeOverrides(
  roleDrafts?: Record<string, FleetProviderModel>,
): boolean {
  if (!roleDrafts) return false;
  return Object.values(roleDrafts).some((pt) => Boolean(pt?.provider || pt?.model));
}

/**
 * Flatten per-bridge draft provider/model map or return flat draft as is.
 */
export function flattenProviderModelDrafts(
  drafts: Record<string, FleetProviderModel | Record<string, FleetProviderModel>>,
  preferredBridgeId?: string,
): Record<string, FleetProviderModel> {
  const flat: Record<string, FleetProviderModel> = {};
  for (const [aid, draft] of Object.entries(drafts || {})) {
    if (!draft) continue;
    if ('provider' in draft && typeof (draft as any).provider === 'string') {
      flat[aid] = draft as FleetProviderModel;
    } else {
      const perBridge = draft as Record<string, FleetProviderModel>;
      if (preferredBridgeId && perBridge[preferredBridgeId] && (perBridge[preferredBridgeId].provider || perBridge[preferredBridgeId].model)) {
        flat[aid] = perBridge[preferredBridgeId];
      } else if (preferredBridgeId && perBridge[preferredBridgeId]) {
        const withOverride = Object.values(perBridge).find((pt) => Boolean(pt?.provider || pt?.model));
        flat[aid] = withOverride ?? perBridge[preferredBridgeId];
      } else {
        const withOverride = Object.values(perBridge).find((pt) => Boolean(pt?.provider || pt?.model));
        flat[aid] = withOverride ?? Object.values(perBridge)[0] ?? { provider: '', model: '' };
      }
    }
  }
  return flat;
}

/**
 * Roles whose drafts diverge from the server state (or that are newly staged):
 * the exact entries the drawer's Apply button turns into fleet PUTs. A role
 * counts as changed when its capacity differs, its provider/model differs, its
 * placement (roles, bridgeId, minWarm, idleTtlSeconds) differs, or it
 * is a not-yet-persisted role with any non-inherit value staged.
 */
export function changedFleetEntries(
  fleets: any[],
  draftCapacities: Record<string, number>,
  draftProviderModels: Record<string, FleetProviderModel | Record<string, FleetProviderModel>>,
  rawFleets: any[],
  preferredBridgeId?: string,
  placementDrafts?: FleetPlacementDrafts,
): ChangedFleetEntry[] {
  const flatPT = flattenProviderModelDrafts(draftProviderModels, preferredBridgeId);
  const list: ChangedFleetEntry[] = [];
  for (const fleet of fleets || []) {
    const aid = fleetAgentId(fleet);
    if (!aid) continue;
    const draftCapacity = draftCapacities[aid];
    const draftPT = flatPT[aid] ?? (draftProviderModels[aid] && 'provider' in (draftProviderModels[aid] as any) ? (draftProviderModels[aid] as FleetProviderModel) : undefined);
    const draftRoles = placementDrafts?.roles?.[aid];
    const draftBridgeId = placementDrafts?.bridgeIds?.[aid];
    const draftTopPT = placementDrafts?.topLevelProviderModels?.[aid];
    const draftMinWarm = placementDrafts?.minWarms?.[aid];
    const draftIdleTtl = placementDrafts?.idleTtls?.[aid];

    const hasPlacementDraft =
      draftRoles !== undefined ||
      draftBridgeId !== undefined ||
      draftTopPT !== undefined ||
      draftMinWarm !== undefined ||
      draftIdleTtl !== undefined;

    // Roles with no draft at all are untouched (a role only appears here when it
    // is persisted or staged via Add Role, so it always carries drafts).
    if (
      draftCapacity === undefined &&
      draftPT === undefined &&
      draftProviderModels[aid] === undefined &&
      !hasPlacementDraft
    ) {
      continue;
    }

    const effectiveCapacity =
      draftCapacity !== undefined ? draftCapacity : (typeof fleet.capacity === 'number' ? fleet.capacity : 1);
    const origCapacity = getOriginalFleetCapacity(rawFleets, aid);
    const origPT = getOriginalProviderModel(rawFleets, aid);
    const origRoles = getOriginalFleetRoles(rawFleets, aid);
    const origBridgeId = getOriginalFleetBridgeId(rawFleets, aid);
    const origMinWarm = getOriginalFleetMinWarm(rawFleets, aid);
    const origIdleTtl = getOriginalFleetIdleTtl(rawFleets, aid);

    const capacityChanged = origCapacity === null || effectiveCapacity !== origCapacity;
    const roleDraft = draftProviderModels[aid];
    const perBridge = roleDraft && !('provider' in roleDraft) ? roleDraft as Record<string, FleetProviderModel> : undefined;
    const originalFleet = (rawFleets || []).find((f) => fleetAgentId(f) === aid);
    const bridgeChanged = perBridge && Object.entries(perBridge).some(([id, selection]) => {
      const original = originalFleet?.bridge_models?.[id] || origPT;
      return selection.provider !== original.provider || (selection.provider_profile || selection.provider) !== (original.provider_profile || original.provider) || selection.model !== original.model;
    });

    const effectiveTopProvider = draftTopPT !== undefined
      ? draftTopPT.provider
      : (perBridge ? origPT.provider : draftPT ? draftPT.provider : origPT.provider);
    const effectiveTopModel = draftTopPT !== undefined
      ? draftTopPT.model
      : (perBridge ? origPT.model : draftPT ? draftPT.model : origPT.model);

    const effectiveTopProfile = (draftTopPT || (perBridge ? origPT : draftPT) || origPT).provider_profile;
    const providerChanged = effectiveTopProvider !== origPT.provider || (effectiveTopProfile || effectiveTopProvider) !== (origPT.provider_profile || origPT.provider);
    const tierChanged = effectiveTopModel !== origPT.model;

    const normalizedDraftRoles = draftRoles !== undefined ? normalizeFleetRoles(draftRoles) : undefined;
    const rolesChanged = normalizedDraftRoles !== undefined && (origRoles === null || !fleetRolesEqual(normalizedDraftRoles, origRoles));
    const bridgeIdChanged = draftBridgeId !== undefined && (origCapacity === null || draftBridgeId !== origBridgeId);
    const minWarmChanged = draftMinWarm !== undefined && (origCapacity === null || draftMinWarm !== origMinWarm);
    const idleTtlChanged = draftIdleTtl !== undefined && (origCapacity === null || draftIdleTtl !== origIdleTtl);

    if (
      capacityChanged ||
      providerChanged ||
      tierChanged ||
      bridgeChanged ||
      rolesChanged ||
      bridgeIdChanged ||
      minWarmChanged ||
      idleTtlChanged
    ) {
      const entry: ChangedFleetEntry = {
        agentId: aid,
        capacity: effectiveCapacity,
        provider: effectiveTopProvider,
        ...(effectiveTopProfile ? { provider_profile: effectiveTopProfile } : {}),
        model: effectiveTopModel,
        ...(perBridge ? { bridgeModels: {
          ...originalFleet?.bridge_models,
          ...Object.fromEntries(Object.entries(perBridge).filter(([id, pt]) =>
            pt.provider && pt.model && (originalFleet?.bridge_models?.[id] ||
              pt.provider !== origPT.provider || (pt.provider_profile || pt.provider) !== (origPT.provider_profile || origPT.provider) || pt.model !== origPT.model)
          )),
        } } : {}),
      };
      if (normalizedDraftRoles !== undefined) {
        entry.roles = normalizedDraftRoles;
      } else if (Array.isArray(fleet?.roles) && fleet.roles.length > 0) {
        entry.roles = normalizeFleetRoles(fleet.roles);
      }
      if (draftBridgeId !== undefined) {
        entry.bridgeId = draftBridgeId;
      } else if (fleet?.bridge_id !== undefined || fleet?.bridgeId !== undefined) {
        entry.bridgeId = fleetBridgeId(fleet);
      }
      if (draftMinWarm !== undefined) {
        entry.minWarm = draftMinWarm;
      }
      if (draftIdleTtl !== undefined) {
        entry.idleTtlSeconds = draftIdleTtl;
      }
      list.push(entry);
    }
  }
  return list;
}

// ---------------------------------------------------------------------------
// Restart confirmation (REQ-RS-3 / REQ-RS-4)
//
// A provider/model edit only takes effect for instances launched AFTER the change;
// live instances keep the old values until they restart. The drawer therefore asks
// the user, before any PUT, whether the affected roles' live instances should be
// relaunched now (the hub's PUT restart_live_instances flag) — and the decision of
// WHICH roles are affected is pure and lives here so `node --test` can drive it.
// ---------------------------------------------------------------------------

export interface FleetRestartFailure {
  instance_id: string;
  message: string;
}

/** A live fleet member: every runtime status except the three terminal ones. */
export function isLiveFleetMember(member: any): boolean {
  const status = String(member?.runtimeStatus || member?.runtime_status || '').toLowerCase();
  return status !== 'stopped' && status !== 'failed' && status !== 'terminated';
}

/** Live members grouped by role (agent_id), preserving member order. */
export function liveInstancesByRole(members: any[]): Record<string, any[]> {
  const map: Record<string, any[]> = {};
  for (const m of members || []) {
    const aid = fleetAgentId(m);
    if (!aid || !isLiveFleetMember(m)) continue;
    (map[aid] || (map[aid] = [])).push(m);
  }
  return map;
}

const ACTIVE_TASK_STATUSES = ['in_progress', 'in_validation', 'queued'];

/**
 * Tasks still occupying a role's fleet, grouped by role (agent_id). Mirrors the
 * drawer's per-role predicate: a task matches its assignee role and, when bound to
 * a member instance, that instance's role too — so it can count for both.
 */
export function activeTasksByRole(tasks: any[], members: any[]): Record<string, any[]> {
  const roleByInstanceId: Record<string, string> = {};
  for (const m of members || []) {
    const aid = fleetAgentId(m);
    const iid = String(m?.agentInstanceId || m?.agent_instance_id || '');
    if (aid && iid) roleByInstanceId[iid] = aid;
  }
  const map: Record<string, any[]> = {};
  for (const t of tasks || []) {
    const status = String(t?.status || '').toLowerCase();
    if (!ACTIVE_TASK_STATUSES.includes(status)) continue;
    const assigneeAid = String(t?.assigneeRef?.agent_id || t?.assigneeRef?.agentId || '');
    const instanceAid = t?.assigneeAgentInstanceId
      ? roleByInstanceId[String(t.assigneeAgentInstanceId)] || ''
      : '';
    for (const aid of new Set([assigneeAid, instanceAid])) {
      if (!aid) continue;
      (map[aid] || (map[aid] = [])).push(t);
    }
  }
  return map;
}

/** True when a role's staged provider/model diverges from its persisted values. */
export function providerModelModified(
  rawFleets: any[],
  agentId: string,
  draftProviderModels: Record<string, FleetProviderModel | Record<string, FleetProviderModel>>,
  preferredBridgeId?: string,
  topLevelDraftPT?: Record<string, FleetProviderModel>,
): boolean {
  const orig = getOriginalProviderModel(rawFleets, agentId);
  const topDraft = topLevelDraftPT?.[agentId];
  if (topDraft && (topDraft.provider !== orig.provider || (topDraft.provider_profile || topDraft.provider) !== (orig.provider_profile || orig.provider) || topDraft.model !== orig.model)) {
    return true;
  }
  const flat = flattenProviderModelDrafts(draftProviderModels, preferredBridgeId);
  const draft = flat[agentId] ?? (draftProviderModels[agentId] && 'provider' in (draftProviderModels[agentId] as any) ? (draftProviderModels[agentId] as FleetProviderModel) : undefined);
  if (!draft) return false;
  const roleDraft = draftProviderModels[agentId];
  if (roleDraft && !('provider' in roleDraft)) {
    const fleet = (rawFleets || []).find((f) => fleetAgentId(f) === agentId);
    return Object.entries(roleDraft).some(([id, pt]) => {
      const original = fleet?.bridge_models?.[id] || orig;
      return pt.provider !== original.provider || (pt.provider_profile || pt.provider) !== (original.provider_profile || original.provider) || pt.model !== original.model;
    });
  }
  return draft.provider !== orig.provider || (draft.provider_profile || draft.provider) !== (orig.provider_profile || orig.provider) || draft.model !== orig.model;
}

/**
 * The changed roles a restart decision applies to: provider/model changed AND the
 * role currently has at least one live instance. Capacity-only edits never restart.
 */
export function restartAffectedEntries(
  changedEntries: ChangedFleetEntry[],
  rawFleets: any[],
  draftProviderModels: Record<string, FleetProviderModel | Record<string, FleetProviderModel>>,
  liveInstanceCounts: Record<string, number>,
  preferredBridgeId?: string,
  topLevelDraftPT?: Record<string, FleetProviderModel>,
): ChangedFleetEntry[] {
  return (changedEntries || []).filter(
    (entry) =>
      providerModelModified(rawFleets, entry.agentId, draftProviderModels, preferredBridgeId, topLevelDraftPT) &&
      (liveInstanceCounts[entry.agentId] || 0) >= 1,
  );
}

export interface FleetApplyRequest {
  provider_profile?: string;
  bridgeModels?: Record<string, FleetProviderModel>;
  agentId: string;
  capacity: number;
  provider: string;
  model: string;
  roles?: string[];
  bridgeId?: string;
  minWarm?: number;
  idleTtlSeconds?: number;
  /** Present (true) only on the PUTs that must relaunch live role instances. */
  restartLiveInstances?: true;
}

/**
 * The PUT payloads for an Apply, one per changed role, in changedFleets order.
 * `restartAffected` empty = "Apply to New Instances Only": every payload then
 * carries no flag key at all, i.e. today's request shape byte-for-byte.
 */
export function fleetApplyRequests(
  changedEntries: ChangedFleetEntry[],
  restartAffected: ChangedFleetEntry[],
): FleetApplyRequest[] {
  const restartIds = new Set((restartAffected || []).map((entry) => entry.agentId));
  return (changedEntries || []).map((entry) => {
    const request: FleetApplyRequest = {
      agentId: entry.agentId,
      capacity: entry.capacity,
      provider: entry.provider,
      model: entry.model,
    };
    if (entry.provider_profile !== undefined) request.provider_profile = entry.provider_profile;
    if (entry.bridgeModels) request.bridgeModels = entry.bridgeModels;
    if (entry.roles !== undefined) request.roles = entry.roles;
    if (entry.bridgeId !== undefined) request.bridgeId = entry.bridgeId;
    if (entry.minWarm !== undefined) request.minWarm = entry.minWarm;
    if (entry.idleTtlSeconds !== undefined) request.idleTtlSeconds = entry.idleTtlSeconds;
    if (restartIds.has(entry.agentId)) request.restartLiveInstances = true;
    return request;
  });
}

export interface FleetRestartRoleResult {
  agentId: string;
  restarted_instance_ids?: string[];
  restart_failures?: FleetRestartFailure[];
}

export interface FleetRestartSummary {
  restartedByRole: { agentId: string; count: number }[];
  failures: FleetRestartFailure[];
}

/**
 * Collapse the flagged PUT responses into the Apply summary. A role's
 * restarted_instance_ids is counted only when the server sent it (it is present
 * exactly on the flagged PUTs); failures are flattened verbatim.
 */
export function summarizeFleetRestartResults(results: FleetRestartRoleResult[]): FleetRestartSummary {
  const restartedByRole: { agentId: string; count: number }[] = [];
  const failures: FleetRestartFailure[] = [];
  for (const result of results || []) {
    if (!result) continue;
    if (Array.isArray(result.restarted_instance_ids)) {
      restartedByRole.push({ agentId: result.agentId, count: result.restarted_instance_ids.length });
    }
    for (const failure of result.restart_failures || []) {
      failures.push({
        instance_id: String(failure?.instance_id || ''),
        message: String(failure?.message || ''),
      });
    }
  }
  return { restartedByRole, failures };
}

// ---------------------------------------------------------------------------
// Runtime mismatch detection (REQ-FLEET-MISMATCH-MODAL-1)
// ---------------------------------------------------------------------------

export interface LiveInstanceRuntimeMismatch {
  instanceId: string;
  agentId: string;
  bridgeId: string;
  actualProvider: string;
  actualModel: string;
  targetProvider: string;
  targetModel: string;
  targetBridgeId?: string;
  mismatchType: 'provider' | 'model' | 'bridge' | 'multiple';
  reasons: string[];
  // Compatibility aliases for snake_case/camelCase callers
  agent_instance_id: string;
  agent_id: string;
  bridge_id: string;
  provider: string;
  model: string;
}

export type LiveInstanceRuntimeMismatchList = LiveInstanceRuntimeMismatch[] & {
  affectedRoleIds: string[];
  mismatchedRoles: string[];
};

export interface TargetRuntimeOptions {
  roleDefaults?: Record<string, FleetProviderModel> | any[];
  perBridgeOverrides?: Record<string, Record<string, FleetProviderModel>>;
  draftProviderModels?: Record<string, FleetProviderModel | Record<string, FleetProviderModel>>;
  targetBridgeId?: string;
  preferredBridgeId?: string;
  [key: string]: any;
}

export interface MismatchedRoleSummary {
  agentId: string;
  mismatchedCount: number;
  instances: LiveInstanceRuntimeMismatch[];
  targetProvider: string;
  targetModel: string;
}

export function groupMismatchesByRole(
  mismatches: LiveInstanceRuntimeMismatch[],
): Record<string, MismatchedRoleSummary> {
  const map: Record<string, MismatchedRoleSummary> = {};
  for (const m of mismatches || []) {
    if (!map[m.agentId]) {
      map[m.agentId] = {
        agentId: m.agentId,
        mismatchedCount: 0,
        instances: [],
        targetProvider: m.targetProvider,
        targetModel: m.targetModel,
      };
    }
    map[m.agentId].mismatchedCount += 1;
    map[m.agentId].instances.push(m);
  }
  return map;
}

/**
 * Detects whether any running agent instances differ from the newly configured target runtime.
 * Takes live agent instances of the role (from members where runtime_status is active)
 * and target runtime configurations (role default and per-bridge overrides).
 * Compares live instance's actual runtime (inst.provider, inst.model, inst.bridge_id)
 * against the target runtime configured for that bridge.
 * Returns list of mismatched instances / roles.
 */
export function detectLiveInstanceRuntimeMismatch(
  liveInstances: any[] | Record<string, any[]>,
  targetConfigs: TargetRuntimeOptions | Record<string, any> | any[],
  roleDefaultsOrOverrides?: any,
  preferredBridgeId?: string,
): LiveInstanceRuntimeMismatchList {
  // Normalize live instances list
  let rawList: any[] = [];
  if (Array.isArray(liveInstances)) {
    rawList = liveInstances;
  } else if (liveInstances && typeof liveInstances === 'object') {
    rawList = Object.values(liveInstances).flat();
  }

  // Parse target configs
  let rawFleetsList: any[] | undefined;
  const roleDefaultsMap: Record<string, FleetProviderModel> = {};
  const perBridgeMap: Record<string, Record<string, FleetProviderModel>> = {};
  let targetBridgeId = '';
  let preferredBridge = preferredBridgeId || '';

  const processConfigObj = (cfg: any) => {
    if (!cfg || typeof cfg !== 'object') return;
    if (Array.isArray(cfg)) {
      rawFleetsList = cfg;
      return;
    }
    if ('roleDefaults' in cfg || 'perBridgeOverrides' in cfg || 'draftProviderModels' in cfg) {
      if (Array.isArray(cfg.roleDefaults)) rawFleetsList = cfg.roleDefaults;
      else if (cfg.roleDefaults && typeof cfg.roleDefaults === 'object') {
        for (const [aid, val] of Object.entries(cfg.roleDefaults)) {
          if (val && typeof val === 'object') roleDefaultsMap[aid] = val as FleetProviderModel;
        }
      }
      if (cfg.perBridgeOverrides && typeof cfg.perBridgeOverrides === 'object') {
        for (const [aid, bmap] of Object.entries(cfg.perBridgeOverrides)) {
          if (bmap && typeof bmap === 'object') perBridgeMap[aid] = bmap as Record<string, FleetProviderModel>;
        }
      }
      if (cfg.draftProviderModels && typeof cfg.draftProviderModels === 'object') {
        for (const [aid, val] of Object.entries(cfg.draftProviderModels)) {
          if (val && typeof val === 'object' && ('provider' in val || 'model' in val)) {
            roleDefaultsMap[aid] = val as FleetProviderModel;
          } else if (val && typeof val === 'object') {
            perBridgeMap[aid] = val as Record<string, FleetProviderModel>;
          }
        }
      }
      if (cfg.targetBridgeId) targetBridgeId = String(cfg.targetBridgeId);
      if (cfg.preferredBridgeId && !preferredBridge) preferredBridge = String(cfg.preferredBridgeId);
    } else {
      for (const [aid, val] of Object.entries(cfg)) {
        if (val && typeof val === 'object' && ('provider' in val || 'model' in val)) {
          roleDefaultsMap[aid] = val as FleetProviderModel;
        } else if (val && typeof val === 'object') {
          perBridgeMap[aid] = val as Record<string, FleetProviderModel>;
        }
      }
    }
  };

  processConfigObj(targetConfigs);
  if (roleDefaultsOrOverrides) {
    if (Array.isArray(roleDefaultsOrOverrides)) {
      if (!rawFleetsList) rawFleetsList = roleDefaultsOrOverrides;
    } else {
      processConfigObj(roleDefaultsOrOverrides);
    }
  }

  if (rawFleetsList) {
    for (const f of rawFleetsList) {
      const aid = fleetAgentId(f);
      if (aid && !roleDefaultsMap[aid]) {
        roleDefaultsMap[aid] = fleetProviderModel(f);
      }
    }
  }

  const mismatches: LiveInstanceRuntimeMismatch[] = [];

  for (const inst of rawList) {
    if (!inst || typeof inst !== 'object') continue;
    if (!isLiveFleetMember(inst)) continue;

    const agentId = String(inst?.agent_id || inst?.agentId || inst?.agent || '');
    if (!agentId) continue;

    const instanceId = String(
      inst?.agent_instance_id || inst?.agentInstanceId || inst?.instance_id || inst?.instanceId || inst?.id || ''
    );
    let actualBridgeId = String(inst?.bridge_id || inst?.bridgeId || inst?.bridge || '');
    let actualProvider = String(
      inst?.provider_profile || inst?.provider || inst?.runtime_provider || inst?.runtimeProvider || inst?.providerProfile || inst?.runtime?.provider || ''
    );
    let actualModel = String(
      inst?.model || inst?.runtime_model || inst?.runtimeModel || inst?.model || inst?.runtime?.model || ''
    );

    // If actual runtime is not explicitly stored on member instance, fall back to role original persisted values
    if (!actualProvider && rawFleetsList) {
      const orig = getOriginalProviderModel(rawFleetsList, agentId);
      actualProvider = orig.provider;
      if (!actualModel) actualModel = orig.model;
    }
    if (!actualBridgeId && preferredBridge) {
      actualBridgeId = preferredBridge;
    }

    // Determine target runtime for this instance on its bridge
    let targetProvider = roleDefaultsMap[agentId]?.provider_profile || roleDefaultsMap[agentId]?.provider || '';
    let targetModel = roleDefaultsMap[agentId]?.model ?? '';
    const expectedBridgeId = targetBridgeId || '';

    const roleBridgeDrafts = perBridgeMap[agentId];
    if (roleBridgeDrafts) {
      const bridgeOverride = actualBridgeId ? roleBridgeDrafts[actualBridgeId] : undefined;
      if (bridgeOverride) {
        if (bridgeOverride.provider !== undefined && bridgeOverride.provider !== '') {
          targetProvider = bridgeOverride.provider_profile || bridgeOverride.provider;
        }
        if (bridgeOverride.model !== undefined && bridgeOverride.model !== '') {
          targetModel = bridgeOverride.model;
        }
      } else if (!actualBridgeId && preferredBridge && roleBridgeDrafts[preferredBridge]) {
        const prefOverride = roleBridgeDrafts[preferredBridge];
        if (prefOverride.provider !== undefined && prefOverride.provider !== '') {
          targetProvider = prefOverride.provider_profile || prefOverride.provider;
        }
        if (prefOverride.model !== undefined && prefOverride.model !== '') {
          targetModel = prefOverride.model;
        }
      } else if (hasCustomRuntimeOverrides(roleBridgeDrafts)) {
        const anyOverride = Object.values(roleBridgeDrafts).find((pt) => Boolean(pt?.provider || pt?.model));
        if (anyOverride) {
          if (anyOverride.provider) targetProvider = anyOverride.provider_profile || anyOverride.provider;
          if (anyOverride.model) targetModel = anyOverride.model;
        }
      }
    }

    const providerMismatch = actualProvider !== targetProvider;
    const tierMismatch = actualModel !== targetModel;
    const bridgeMismatch = Boolean(expectedBridgeId && actualBridgeId && actualBridgeId !== expectedBridgeId);

    if (providerMismatch || tierMismatch || bridgeMismatch) {
      const reasons: string[] = [];
      if (providerMismatch) {
        reasons.push(`Provider mismatch: actual "${actualProvider || 'auto'}" vs target "${targetProvider || 'auto'}"`);
      }
      if (tierMismatch) {
        reasons.push(`Model mismatch: actual "${actualModel || 'auto'}" vs target "${targetModel || 'auto'}"`);
      }
      if (bridgeMismatch) {
        reasons.push(`Bridge mismatch: actual "${actualBridgeId}" vs target "${expectedBridgeId}"`);
      }

      let mismatchType: 'provider' | 'model' | 'bridge' | 'multiple' = 'multiple';
      if (providerMismatch && !tierMismatch && !bridgeMismatch) mismatchType = 'provider';
      else if (!providerMismatch && tierMismatch && !bridgeMismatch) mismatchType = 'model';
      else if (!providerMismatch && !tierMismatch && bridgeMismatch) mismatchType = 'bridge';

      mismatches.push({
        instanceId,
        agentId,
        bridgeId: actualBridgeId,
        actualProvider,
        actualModel,
        targetProvider,
        targetModel,
        targetBridgeId: expectedBridgeId || undefined,
        mismatchType,
        reasons,
        agent_instance_id: instanceId,
        agent_id: agentId,
        bridge_id: actualBridgeId,
        provider: actualProvider,
        model: actualModel,
      });
    }
  }

  const affectedRoleIds = Array.from(new Set(mismatches.map((m) => m.agentId)));
  const result = mismatches as LiveInstanceRuntimeMismatchList;
  result.affectedRoleIds = affectedRoleIds;
  result.mismatchedRoles = affectedRoleIds;
  return result;
}

const BRIDGE_SOURCE_TEXT: Record<string, string> = {
  task_pin: 'pinned on the ticket',
  fleet: 'set on this fleet row',
  chain_directory: "from the chain's directory",
  coordinator: "the coordinator's bridge",
};
const MODEL_SOURCE_TEXT: Record<string, string> = {
  fleet: 'set on this fleet row',
  bridge_override: 'set for this bridge',
  catalog_default: 'default for this bridge',
};

export interface EffectivePlacementText {
  /** e.g. "dawnstar"; "" when no bridge resolves. */
  bridge: string;
  bridgeSource: string;
  /** e.g. "claude · claude-sonnet-5-5"; "" when no model resolves. */
  model: string;
  modelSource: string;
  /** One line for the UI, never "inherit" / "default". */
  summary: string;
}

/**
 * Words for what will actually be applied (plan REQ-UI-12). `bridgeName` turns a
 * bridge id into its label.
 */
export function describeEffectivePlacement(
  eff: { bridge_id?: string; bridge_source?: string; provider?: string; model?: string; model_source?: string } | null | undefined,
  bridgeName: (bridgeId: string) => string,
): EffectivePlacementText {
  const bridgeId = String(eff?.bridge_id || '');
  if (!bridgeId) {
    return {
      bridge: '',
      bridgeSource: '',
      model: '',
      modelSource: '',
      summary: 'No bridge yet: add a chain directory or pin a bridge',
    };
  }
  const bridge = bridgeName(bridgeId);
  const bridgeSource = BRIDGE_SOURCE_TEXT[String(eff?.bridge_source || '')] || '';
  const model = eff?.provider && eff?.model ? `${eff.provider} · ${eff.model}` : '';
  const modelSource = MODEL_SOURCE_TEXT[String(eff?.model_source || '')] || '';
  const summary = model
    ? `${bridge} (${bridgeSource}) · ${model} (${modelSource})`
    : `${bridge} (${bridgeSource}) · no model available on this bridge`;
  return { bridge, bridgeSource, model, modelSource, summary };
}

/**
 * The placement a task would get: its bridge pin first, then the assignee's
 * fleet row, else the first worker row (any free worker).
 */
export function taskEffectivePlacement(
  task: { bridge_id?: string; brief?: { assignee?: string } | null },
  fleets: any[] = [],
): { bridge_id: string; bridge_source: string; provider: string; model: string; model_source: string } | null {
  const assignee = String(task.brief?.assignee || '');
  const rows = (fleets || []).filter((f) => (f?.roles || ['worker']).includes('worker'));
  const row = (assignee ? rows.find((f) => String(f.agent_id || f.agentId) === assignee) : rows[0]) || null;
  const eff = row?.effective || null;
  const pin = String(task.bridge_id || '');
  if (pin) {
    // The model shown is the row's; a different pinned bridge may change it.
    return {
      bridge_id: pin,
      bridge_source: 'task_pin',
      provider: eff?.provider || '',
      model: eff?.model || '',
      model_source: eff?.model_source || 'none',
    };
  }
  return eff ? { ...eff } : null;
}
