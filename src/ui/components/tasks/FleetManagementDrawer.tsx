import ModelCatalogRefresh from '../providers/ModelCatalogRefresh';
import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useDispatch } from 'react-redux';
import {
  Badge,
  Button,
  Drawer,
  Icon,
  IconButton,
  Modal,
  ModalBody,
  ModalFooter,
  Select,
  StatusDot,
  Text,
} from '@ui';
import { heimdallApi } from '../../api/heimdallApi';
import {
  useGetTaskChainFleetsQuery,
  useUpdateTaskChainFleetMutation,
  useDeleteTaskChainFleetMutation,
  type TaskChainFleet,
} from '../../api/endpoints/taskChains';
import { useFetchTaskChainDetailQuery } from '../../api/endpoints/tasks';
import {
  normalizeBridgeCapabilities,
  useListBridgesQuery,
  useListBridgeProvidersQuery,
} from '../../api/endpoints/bridgeSupport';
import { effectiveChainBridgeId, isRevokedBridge, taskBridgeOptions } from '../../utils/taskBridgePin';
import {
  FLEET_ROLES,
  activeTasksByRole,
  changedFleetEntries,
  detectLiveInstanceRuntimeMismatch,
  fleetApplyRequests,
  fleetProviderCapabilities,
  fleetRolesEqual,
  formatFleetRolesBadge,
  resolvedFleetProviderModel,
  getOriginalFleetBridgeId,
  getOriginalFleetCapacity,
  getOriginalFleetIdleTtl,
  getOriginalFleetMinWarm,
  getOriginalFleetRoles,
  getOriginalProviderModel,
  hasCustomRuntimeOverrides,
  liveInstancesByRole,
  nextModelOnProviderChange,
  normalizeFleetRoles,
  providerModelModified,
  restartAffectedEntries,
  seedFleetBridgeIdDrafts,
  seedFleetIdleTtlDrafts,
  seedFleetMinWarmDrafts,
  seedFleetRolesDrafts,
  seedPerBridgeProviderModelDrafts,
  seedProviderModelDrafts,
  summarizeFleetRestartResults,
  toggleFleetRole,
  isValidFleetRoleName,
  describeEffectivePlacement,
  modelOptionsForProvider,
  type ChangedFleetEntry,
  type FleetPlacementDrafts,
  type FleetProviderCapability,
  type FleetProviderModel,
  type FleetRestartSummary,
} from './fleetSelection';
import { useListAgentIdentitiesQuery, useListAgentInstancesQuery } from '../../api/endpoints/agents';
import { readableAgentFallback } from './taskNames';

export function formatFleetRoleName(agentId?: string, identities?: any[]): string {
  if (!agentId) return 'Worker';
  const found = identities?.find(
    (a) => String(a.agent_id || a.agentId || a.id || '') === agentId
  );
  if (found?.name) return found.name;
  if (found?.display_name) return found.display_name;
  return readableAgentFallback(agentId);
}

export function getQueuedWaitingSlotName(task: any, identities?: any[]): string {
  if (!task) return 'Worker';
  const status = String(task.status || '').toLowerCase();
  if (status === 'in_validation') {
    return 'Reviewer';
  }
  const assigneeRef = task.assigneeRef || task.assignee_ref;
  const targetAgentId =
    assigneeRef?.agent_id ||
    assigneeRef?.agentId ||
    task.assigneeAgentId ||
    task.assignee_agent_id ||
    '';
  if (targetAgentId) {
    return formatFleetRoleName(targetAgentId, identities);
  }
  return 'Worker';
}

export {
  isRoleAssignedWithoutLiveInstance,
  canStartTask,
  hasLiveNudgeTarget,
  getUnpauseStatus,
  canCompleteTask,
  canPauseTask,
} from './taskCardLegacy';

interface BridgeRuntimeRowProps {
  agentId: string;
  roleName: string;
  bridge: any;
  draftPT: FleetProviderModel;
  onProviderChange: (provider: string, capabilities: FleetProviderCapability[]) => void;
  onModelChange: (model: string) => void;
  disabled: boolean;
}

const BridgeRuntimeRow: React.FC<BridgeRuntimeRowProps> = ({
  agentId,
  roleName,
  bridge,
  draftPT,
  onProviderChange,
  onModelChange,
  disabled,
}) => {
  const bId = String(bridge.bridge_id || bridge.bridgeId || bridge.id || '');
  const providersQuery = useListBridgeProvidersQuery({ bridgeId: bId }, { skip: !bId });
  const instancesQuery = useListAgentInstancesQuery({ agentId, limit: 1000 }, { skip: !agentId });

  const capabilities = useMemo<FleetProviderCapability[]>(() => {
    const fromQuery = fleetProviderCapabilities(providersQuery.currentData);
    if (providersQuery.currentData) return fromQuery;
    return normalizeBridgeCapabilities(bridge);
  }, [providersQuery.currentData, bridge]);

  const resolved = resolvedFleetProviderModel(draftPT, capabilities);
  const effectiveProvider = resolved.provider;
  const effectiveProfile = resolved.provider_profile || resolved.provider;
  const effectiveModel = resolved.model;
  const modelOptions = modelOptionsForProvider(capabilities, effectiveProvider, effectiveProfile);
  const bridgeInstances = (instancesQuery.data?.instances || []).filter(
    (instance: any) => String(instance.bridge_id || instance.bridgeId || '') === bId &&
      !['failed', 'terminated', 'stopped'].includes(String(instance.runtime_status || instance.runtimeStatus || ''))
  );

  const status = String(bridge.status || bridge.runtime_status || '').toLowerCase();
  const isOnline = status === 'online' || status === 'connected';
  const label = bridge.label || bridge.machine_hostname || bridge.machineHostname || bridge.hostname || bId;
  const host = bridge.machine_hostname || bridge.machineHostname || bridge.hostname || bridge.host || '—';

  return (
    <div
      data-debug-id={`fleet-bridge-runtime-row-${agentId}-${bId}`}
      className="rounded-lg border border-subtle bg-surface p-2.5 space-y-2"
    >
      <div className="flex items-center justify-between gap-2">
        <div className="flex items-center gap-1.5 min-w-0">
          <StatusDot
            size="sm"
            tone={isOnline ? 'success' : 'neutral'}
            label={isOnline ? 'Online' : 'Offline'}
          />
          <span className="text-xs font-semibold text-primary truncate" title={label}>
            {label}
          </span>
          <span className="text-[10px] text-muted font-mono truncate" title={host}>
            ({host})
          </span>
        </div>
      </div>

      <div className="grid grid-cols-2 gap-2">
        <div className="space-y-1">
          <span className="block text-[10px] font-semibold uppercase tracking-wide text-muted">
            Provider
          </span>
          <Select
            data-debug-id={`fleet-provider-select-${agentId}-${bId}`}
            value={effectiveProfile}
            onChange={(v) => onProviderChange(v, capabilities)}
            disabled={disabled}
            size="sm"
            width="full"
            aria-label={`Provider for ${roleName} on ${label}`}
            options={[
              ...(!effectiveProvider ? [{ value: '', label: 'Unavailable' }] :
                capabilities.some((cap) => (cap.profile_id || cap.provider) === effectiveProfile) ? [] : [{ value: effectiveProfile, label: effectiveProfile }]),
              ...capabilities.map((cap) => ({ value: cap.profile_id || cap.provider, label: cap.label || cap.profile_id || cap.provider })),
            ]}
          />
        </div>
        <div className="space-y-1">
          <span className="block text-[10px] font-semibold uppercase tracking-wide text-muted">
            Model
          </span>
          <Select
            data-debug-id={`fleet-model-select-${agentId}-${bId}`}
            value={effectiveModel}
            onChange={(model) => { onProviderChange(effectiveProfile, capabilities); onModelChange(model); }}
            disabled={effectiveProvider === '' || disabled}
            size="sm"
            width="full"
            aria-label={`Model model for ${roleName} on ${label}`}
            options={[
              ...(!effectiveModel ? [{ value: '', label: 'Unavailable' }] :
                modelOptions.includes(effectiveModel) ? [] : [{ value: effectiveModel, label: `${effectiveModel} (unavailable)` }]),
              ...modelOptions.map((model) => ({ value: model, label: model })),
            ]}
          />
        </div>
      </div>
      <ModelCatalogRefresh bridgeId={bId} provider={effectiveProvider} profileId={effectiveProfile} online={isOnline} disabled={disabled} debugPrefix={`fleet-${agentId}-${bId}`} />
      {bridgeInstances.map((instance: any) => (
        <div key={instance.agent_instance_id || instance.agentInstanceId} className="text-[11px] text-muted">
          {instance.display_name || instance.displayName || instance.agent_instance_id || instance.agentInstanceId}: {instance.provider} / {instance.model}
        </div>
      ))}
    </div>
  );
};

/** One row of the restart-confirmation modal: the affected role + what to warn about. */
interface PendingRestartRole extends ChangedFleetEntry {
  liveCount: number;
  activeTaskCount: number;
  originalProvider: string;
  originalModel: string;
}

export interface FleetManagementDrawerProps {
  chainId: string;
  isOpen: boolean;
  onClose: () => void;
}

export const FleetManagementDrawer: React.FC<FleetManagementDrawerProps> = ({
  chainId,
  isOpen,
  onClose,
}) => {
  // REQ-FLEET-POLLING-1: fetch once on open — no polling interval. Mutation
  // cache invalidation plus the explicit refetch() after an apply keep this
  // current; do not reintroduce a timer here. The drawer stays mounted while
  // closed (it returns null below), so every query is skipped until it opens.
  const closed = !isOpen || !chainId;
  const { data: rawFleets = [], refetch, isLoading: fleetsLoading } = useGetTaskChainFleetsQuery(
    { chainId },
    { skip: closed }
  );
  const chainDetailQuery = useFetchTaskChainDetailQuery(
    { chainId },
    { skip: closed }
  );
  const agentIdentitiesQuery = useListAgentIdentitiesQuery(undefined, { skip: !isOpen });
  const agentIdentities = agentIdentitiesQuery.data?.agents || [];
  const validIdentitiesSet = useMemo(
    () => new Set(agentIdentities.map((a: any) => String(a.agent_id || a.agentId || a.id || ''))),
    [agentIdentities]
  );
  const members = (chainDetailQuery.data?.chain?.members || []) as any[];
  const tasks = (chainDetailQuery.data?.chain?.tasks || []) as any[];
  const liveInstancesByRoleMap = useMemo(() => liveInstancesByRole(members), [members]);
  const activeTasksByRoleMap = useMemo(() => activeTasksByRole(tasks, members), [tasks, members]);

  // Use the same effective bridge as reconciliation for role-wide settings.
  const allInstancesQuery = useListAgentInstancesQuery({ limit: 1000 }, { skip: !isOpen });
  const bridgesQuery = useListBridgesQuery(undefined, { skip: !isOpen, pollingInterval: 120000 });
  const activeBridges = useMemo(() => {
    return (bridgesQuery.data?.bridges || []).filter((b: any) => !isRevokedBridge(b));
  }, [bridgesQuery.data?.bridges]);
  // Bridge ids never surface in the drawer text; show the bridge's name.
  const bridgeLabel = (bridgeId: string): string => {
    const b: any = (bridgesQuery.data?.bridges || []).find((x: any) => String(x.bridge_id || x.bridgeId || x.id || '') === bridgeId);
    return String(b?.label || b?.name || b?.machine_hostname || 'unknown bridge');
  };

  const bridgeId = effectiveChainBridgeId(chainDetailQuery.data?.chain, allInstancesQuery.data?.instances || [], activeBridges);

  const bridgesToRender = useMemo(() => {
    if (activeBridges.length > 0) return activeBridges;
    if (bridgeId) {
      return [{ bridge_id: bridgeId, label: bridgeId, status: 'online' }];
    }
    return [];
  }, [activeBridges, bridgeId]);

  const bridgeSelectOptions = useMemo(() => taskBridgeOptions(bridgesToRender), [bridgesToRender]);

  const providersQuery = useListBridgeProvidersQuery({ bridgeId }, { skip: !bridgeId || !isOpen });
  const bridgeCapabilities = useMemo(
    () => fleetProviderCapabilities(providersQuery.currentData),
    [providersQuery.currentData]
  );

  const dispatch = useDispatch();
  const [updateFleet, { isLoading: isUpdating }] = useUpdateTaskChainFleetMutation();
  const [deleteFleet, { isLoading: isDeleting }] = useDeleteTaskChainFleetMutation();
  const [selectedNewAgentId, setSelectedNewAgentId] = useState('');
  // Per-row text for adding a custom review role (e.g. "security").
  const [customRoleDrafts, setCustomRoleDrafts] = useState<Record<string, string>>({});
  const [errorMsg, setErrorMsg] = useState('');
  const [successMsg, setSuccessMsg] = useState('');
  const [isApplying, setIsApplying] = useState(false);
  const [draftCapacities, setDraftCapacities] = useState<Record<string, number>>({});
  const [draftRoles, setDraftRoles] = useState<Record<string, string[]>>({});
  const [draftBridgeIds, setDraftBridgeIds] = useState<Record<string, string>>({});
  const [draftTopLevelPT, setDraftTopLevelPT] = useState<Record<string, FleetProviderModel>>({});
  const [draftMinWarms, setDraftMinWarms] = useState<Record<string, number>>({});
  const [draftIdleTtls, setDraftIdleTtls] = useState<Record<string, number>>({});
  const [draftProviderModels, setDraftProviderModels] = useState<
    Record<string, Record<string, FleetProviderModel>>
  >({});
  const [expandedRuntimeRoles, setExpandedRuntimeRoles] = useState<Record<string, boolean>>({});
  const [pendingRestart, setPendingRestart] = useState<PendingRestartRole[] | null>(null);
  const [restartSummary, setRestartSummary] = useState<FleetRestartSummary | null>(null);

  const prevIsOpenRef = useRef(false);
  // True when the current press started on the drawer backdrop itself (see the
  // backdrop's handlers): a press inside the panel — or on the restart modal's
  // portal overlay, whose mouseup lands on the backdrop once the modal unmounts —
  // must not dismiss the drawer.

  const seedDrafts = useCallback(() => {
    const validFleets = rawFleets.filter((f) => validIdentitiesSet.has(f.agent_id));
    const init: Record<string, number> = {};
    for (const f of validFleets) {
      init[f.agent_id] = f.capacity ?? 1;
    }
    setDraftCapacities(init);
    setDraftRoles(seedFleetRolesDrafts(validFleets));
    setDraftBridgeIds(seedFleetBridgeIdDrafts(validFleets));
    setDraftTopLevelPT(seedProviderModelDrafts(validFleets));
    setDraftMinWarms(seedFleetMinWarmDrafts(validFleets));
    setDraftIdleTtls(seedFleetIdleTtlDrafts(validFleets));
    setDraftProviderModels(
      seedPerBridgeProviderModelDrafts(
        validFleets,
        bridgesToRender,
        bridgeId
      )
    );
  }, [rawFleets, bridgesToRender, bridgeId, validIdentitiesSet]);

  // Sync drafts when drawer opens. The queries only start on open, so seeding waits
  // until the rows they seed from have loaded (cached rows count as loaded).
  const seededRef = useRef(false);
  const seedInputsLoading = fleetsLoading || agentIdentitiesQuery.isLoading || bridgesQuery.isLoading;
  useEffect(() => {
    if (!isOpen || seededRef.current || seedInputsLoading) return;
    seededRef.current = true;
    seedDrafts();
  }, [isOpen, seedInputsLoading, seedDrafts]);
  useEffect(() => {
    if (isOpen && !prevIsOpenRef.current) {
      setErrorMsg('');
      setSuccessMsg('');
      setRestartSummary(null);
      setPendingRestart(null);
    } else if (!isOpen && prevIsOpenRef.current) {
      // Closing resets the seed so the next open seeds from fresh rows.
      seededRef.current = false;
      setPendingRestart(null);
    }
    prevIsOpenRef.current = isOpen;
  }, [isOpen, seedDrafts]);

  // REQ-AUTO-1: render exactly the persisted rows plus any roles staged via
  // Add Role — no synthetic standard-role cards. An empty Fleet renders empty.
  const fleets = useMemo(() => {
    const list: TaskChainFleet[] = rawFleets.filter((f) => validIdentitiesSet.has(f.agent_id));
    const seen = new Set(list.map((f) => f.agent_id));

    // Include any newly added agent roles staged in draftCapacities
    for (const [aid, cap] of Object.entries(draftCapacities)) {
      if (!seen.has(aid) && validIdentitiesSet.has(aid)) {
        list.push({
          task_chain_id: chainId,
          agent_id: aid,
          capacity: cap,
          active_count: 0,
          roles: draftRoles[aid] ?? ['worker'],
          bridge_id: draftBridgeIds[aid] ?? '',
          provider: draftTopLevelPT[aid]?.provider ?? '',
          model: draftTopLevelPT[aid]?.model ?? '',
          min_warm: draftMinWarms[aid] ?? 0,
          idle_ttl_seconds: draftIdleTtls[aid] ?? 600,
        });
        seen.add(aid);
      }
    }

    return list;
  }, [rawFleets, chainId, draftCapacities, draftRoles, draftBridgeIds, draftTopLevelPT, draftMinWarms, draftIdleTtls, validIdentitiesSet]);

  const getOriginalCapacity = useCallback(
    (agentId: string) => getOriginalFleetCapacity(rawFleets, agentId),
    [rawFleets]
  );

  const handleDraftCapacityChange = useCallback((agentId: string, newCapacity: number) => {
    const clamped = Math.max(1, Math.min(20, newCapacity));
    setDraftCapacities((prev) => ({
      ...prev,
      [agentId]: clamped,
    }));
    setDraftMinWarms((prev) => {
      const current = prev[agentId];
      if (current !== undefined && current > clamped) {
        return { ...prev, [agentId]: clamped };
      }
      return prev;
    });
    setErrorMsg('');
    setSuccessMsg('');
    setRestartSummary(null);
  }, []);

  const handleDraftRoleToggle = useCallback((agentId: string, role: string, currentRoles?: string[]) => {
    setDraftRoles((prev) => {
      const existing = prev[agentId] ?? currentRoles ?? ['worker'];
      return {
        ...prev,
        [agentId]: toggleFleetRole(existing, role),
      };
    });
    setErrorMsg('');
    setSuccessMsg('');
    setRestartSummary(null);
  }, []);

  const handleDraftBridgeIdChange = useCallback((agentId: string, nextBridgeId: string) => {
    setDraftBridgeIds((prev) => ({
      ...prev,
      [agentId]: nextBridgeId,
    }));
    setErrorMsg('');
    setSuccessMsg('');
    setRestartSummary(null);
  }, []);

  const handleDraftTopLevelProviderChange = useCallback(
    (agentId: string, profileId: string) => {
      const capability = bridgeCapabilities.find(c => (c.profile_id || c.provider) === profileId);
      const provider = capability?.provider || profileId;
      setDraftTopLevelPT((prev) => {
        const currentModel = prev[agentId]?.model ?? '';
        const nextModel = provider
          ? modelOptionsForProvider(bridgeCapabilities, provider, profileId).find(m => m === currentModel) ||
            modelOptionsForProvider(bridgeCapabilities, provider, profileId)[0] ||
            ''
          : '';
        return {
          ...prev,
          [agentId]: { provider, provider_profile: profileId, model: nextModel },
        };
      });
      setErrorMsg('');
      setSuccessMsg('');
      setRestartSummary(null);
    },
    [bridgeCapabilities]
  );

  const handleDraftTopLevelModelChange = useCallback((agentId: string, model: string) => {
    setDraftTopLevelPT((prev) => ({
      ...prev,
      [agentId]: {
        provider: prev[agentId]?.provider ?? '',
        provider_profile: prev[agentId]?.provider_profile,
        model,
      },
    }));
    setErrorMsg('');
    setSuccessMsg('');
    setRestartSummary(null);
  }, []);

  const handleDraftMinWarmChange = useCallback((agentId: string, minWarm: number, maxCap: number) => {
    const clamped = Math.max(0, Math.min(maxCap, isNaN(minWarm) ? 0 : minWarm));
    setDraftMinWarms((prev) => ({
      ...prev,
      [agentId]: clamped,
    }));
    setErrorMsg('');
    setSuccessMsg('');
    setRestartSummary(null);
  }, []);

  const handleDraftIdleTtlChange = useCallback((agentId: string, ttlSeconds: number) => {
    const clamped = Math.max(30, isNaN(ttlSeconds) ? 600 : ttlSeconds);
    setDraftIdleTtls((prev) => ({
      ...prev,
      [agentId]: clamped,
    }));
    setErrorMsg('');
    setSuccessMsg('');
    setRestartSummary(null);
  }, []);

  const handleDraftBridgeProviderChange = useCallback(
    (agentId: string, bId: string, profileId: string, capabilities: FleetProviderCapability[]) => {
      const capability = capabilities.find(c => (c.profile_id || c.provider) === profileId);
      const provider = capability?.provider || profileId;
      setDraftProviderModels((prev) => {
        const roleDrafts = prev[agentId] || {};
        const currentModel = roleDrafts[bId]?.model ?? '';
        return {
          ...prev,
          [agentId]: {
            ...roleDrafts,
            [bId]: {
              provider,
              provider_profile: profileId,
              model: modelOptionsForProvider(capabilities, provider, profileId).find(m => m === currentModel) || modelOptionsForProvider(capabilities, provider, profileId)[0] || '',
            },
          },
        };
      });
      setErrorMsg('');
      setSuccessMsg('');
      setRestartSummary(null);
    },
    []
  );

  const handleDraftBridgeModelChange = useCallback(
    (agentId: string, bId: string, model: string) => {
      setDraftProviderModels((prev) => {
        const roleDrafts = prev[agentId] || {};
        return {
          ...prev,
          [agentId]: {
            ...roleDrafts,
            [bId]: {
              provider: roleDrafts[bId]?.provider || '',
              provider_profile: roleDrafts[bId]?.provider_profile,
              model,
            },
          },
        };
      });
      setErrorMsg('');
      setSuccessMsg('');
      setRestartSummary(null);
    },
    []
  );

  const handleDraftProviderChange = useCallback(
    (agentId: string, provider: string) => {
      const targetBridgeId = bridgeId || bridgesToRender[0]?.bridge_id || 'default';
      handleDraftBridgeProviderChange(agentId, targetBridgeId, provider, bridgeCapabilities);
    },
    [bridgeId, bridgesToRender, bridgeCapabilities, handleDraftBridgeProviderChange]
  );

  const handleDraftModelChange = useCallback(
    (agentId: string, model: string) => {
      const targetBridgeId = bridgeId || bridgesToRender[0]?.bridge_id || 'default';
      handleDraftBridgeModelChange(agentId, targetBridgeId, model);
    },
    [bridgeId, bridgesToRender, handleDraftBridgeModelChange]
  );

  const handleAddFleet = useCallback(
    (agentId: string) => {
      if (!agentId) return;
      const defaultRoles = agentId.toLowerCase().includes('review') ? ['reviewer'] : ['worker'];
      setDraftCapacities((prev) => ({
        ...prev,
        [agentId]: prev[agentId] ?? 1,
      }));
      setDraftRoles((prev) => ({
        ...prev,
        [agentId]: prev[agentId] ?? defaultRoles,
      }));
      setDraftBridgeIds((prev) => ({
        ...prev,
        [agentId]: prev[agentId] ?? '',
      }));
      setDraftTopLevelPT((prev) => ({
        ...prev,
        [agentId]: prev[agentId] ?? { provider: '', model: '' },
      }));
      setDraftMinWarms((prev) => ({
        ...prev,
        [agentId]: prev[agentId] ?? 0,
      }));
      setDraftIdleTtls((prev) => ({
        ...prev,
        [agentId]: prev[agentId] ?? 600,
      }));
      setDraftProviderModels((prev) => {
        const roleDrafts: Record<string, FleetProviderModel> = {};
        for (const b of bridgesToRender) {
          const bId = String(b.bridge_id || b.bridgeId || b.id || '');
          if (bId) roleDrafts[bId] = { provider: '', model: '' };
        }
        if (bridgeId && !roleDrafts[bridgeId]) {
          roleDrafts[bridgeId] = { provider: '', model: '' };
        }
        return {
          ...prev,
          [agentId]: prev[agentId] ?? roleDrafts,
        };
      });
      setSelectedNewAgentId('');
      setErrorMsg('');
      setSuccessMsg('');
      setRestartSummary(null);
    },
    [bridgesToRender, bridgeId]
  );

  const handleRemoveFleet = useCallback(
    async (agentId: string, isPersisted: boolean) => {
      setErrorMsg('');
      setSuccessMsg('');
      if (!isPersisted) {
        setDraftCapacities((prev) => {
          const next = { ...prev };
          delete next[agentId];
          return next;
        });
        setDraftRoles((prev) => {
          const next = { ...prev };
          delete next[agentId];
          return next;
        });
        setDraftBridgeIds((prev) => {
          const next = { ...prev };
          delete next[agentId];
          return next;
        });
        setDraftTopLevelPT((prev) => {
          const next = { ...prev };
          delete next[agentId];
          return next;
        });
        setDraftMinWarms((prev) => {
          const next = { ...prev };
          delete next[agentId];
          return next;
        });
        setDraftIdleTtls((prev) => {
          const next = { ...prev };
          delete next[agentId];
          return next;
        });
        setDraftProviderModels((prev) => {
          const next = { ...prev };
          delete next[agentId];
          return next;
        });
        return;
      }

      try {
        await deleteFleet({ chainId, agentId }).unwrap();
        dispatch(
          heimdallApi.util.invalidateTags([
            { type: 'TaskChainFleets' as const, id: chainId },
            { type: 'Chain' as const, id: chainId },
          ])
        );
        await refetch();
        await chainDetailQuery.refetch();
        setSuccessMsg(`Removed fleet role ${formatFleetRoleName(agentId, agentIdentities)}`);
      } catch (err: any) {
        setErrorMsg(
          String(err?.data?.error?.message || err?.error || err?.message || 'Failed to remove fleet role')
        );
      }
    },
    [chainId, deleteFleet, dispatch, refetch, chainDetailQuery, agentIdentities]
  );

  const placementDrafts = useMemo<FleetPlacementDrafts>(
    () => ({
      roles: draftRoles,
      bridgeIds: draftBridgeIds,
      topLevelProviderModels: draftTopLevelPT,
      minWarms: draftMinWarms,
      idleTtls: draftIdleTtls,
    }),
    [draftRoles, draftBridgeIds, draftTopLevelPT, draftMinWarms, draftIdleTtls]
  );

  const changedFleets = useMemo(
    () =>
      changedFleetEntries(
        fleets,
        draftCapacities,
        draftProviderModels,
        rawFleets,
        bridgeId,
        placementDrafts
      ),
    [fleets, draftCapacities, draftProviderModels, rawFleets, bridgeId, placementDrafts]
  );

  const hasPendingChanges = changedFleets.length > 0;

  const handleReset = useCallback(() => {
    seedDrafts();
    setErrorMsg('');
    setSuccessMsg('');
  }, [seedDrafts]);

  /** PUT every changed role; `restartAffected` roles additionally get the restart flag. */
  const applyFleetChanges = useCallback(
    async (restartAffected: ChangedFleetEntry[]) => {
      if (isUpdating || isApplying) return;
      setErrorMsg('');
      setSuccessMsg('');
      setRestartSummary(null);
      setIsApplying(true);
      try {
        const requests = fleetApplyRequests(changedFleets, restartAffected);
        const results = await Promise.all(
          requests.map(async (cf) => {
            const response = await updateFleet({
              chainId,
              agentId: cf.agentId,
              capacity: cf.capacity,
              provider: cf.provider,
              provider_profile: cf.provider_profile,
              model: cf.model,
              roles: cf.roles,
              bridgeId: cf.bridgeId,
              minWarm: cf.minWarm,
              idleTtlSeconds: cf.idleTtlSeconds,
              bridgeModels: cf.bridgeModels,
              restartLiveInstances: cf.restartLiveInstances,
            }).unwrap();
            return {
              agentId: cf.agentId,
              restarted_instance_ids: response?.restarted_instance_ids,
              restart_failures: response?.restart_failures,
            };
          })
        );
        dispatch(
          heimdallApi.util.invalidateTags([
            { type: 'BridgeSupport' as const },
            { type: 'ChainFleets' as const },
            { type: 'ChainMembers' as const },
          ])
        );
        await refetch();
        await chainDetailQuery.refetch();
        setSuccessMsg(
          `Applied fleet updates for ${changedFleets.length} ${
            changedFleets.length === 1 ? 'role' : 'roles'
          }`
        );
        const flaggedIds = new Set(restartAffected.map((entry) => entry.agentId));
        const flaggedResults = results.filter((result) => flaggedIds.has(result.agentId));
        if (flaggedResults.length > 0) {
          setRestartSummary(summarizeFleetRestartResults(flaggedResults));
        }
      } catch (err: any) {
        setErrorMsg(
          String(err?.data?.error?.message || err?.message || 'Failed to update fleet settings')
        );
      } finally {
        setIsApplying(false);
      }
    },
    [
      isUpdating,
      isApplying,
      changedFleets,
      draftProviderModels,
      updateFleet,
      chainId,
      dispatch,
      refetch,
      chainDetailQuery,
    ]
  );

  const handleApply = useCallback(() => {
    if (!hasPendingChanges || isUpdating || isApplying) return;
    const liveCounts: Record<string, number> = {};
    for (const [agentId, list] of Object.entries(liveInstancesByRoleMap)) {
      liveCounts[agentId] = list.length;
    }
    const affected = restartAffectedEntries(
      changedFleets,
      rawFleets,
      draftProviderModels,
      liveCounts,
      bridgeId,
      draftTopLevelPT
    );
    const mismatches = detectLiveInstanceRuntimeMismatch(
      members,
      draftProviderModels,
      rawFleets,
      bridgeId
    );
    // If no live instance has a runtime mismatch, save changes directly without prompting.
    if (affected.length === 0) {
      void applyFleetChanges([]);
      return;
    }
    setPendingRestart(
      affected.map((entry) => {
        const original = getOriginalProviderModel(rawFleets, entry.agentId);
        return {
          ...entry,
          liveCount: liveCounts[entry.agentId] ?? 0,
          activeTaskCount: (activeTasksByRoleMap[entry.agentId] || []).length,
          originalProvider: original.provider,
          originalModel: original.model,
        };
      })
    );
  }, [
    hasPendingChanges,
    isUpdating,
    isApplying,
    changedFleets,
    rawFleets,
    draftProviderModels,
    draftTopLevelPT,
    liveInstancesByRoleMap,
    members,
    activeTasksByRoleMap,
    applyFleetChanges,
    bridgeId,
  ]);

  const handleConfirmRestartNow = useCallback(() => {
    const affected = pendingRestart || [];
    setPendingRestart(null);
    void applyFleetChanges(affected);
  }, [pendingRestart, applyFleetChanges]);

  const handleApplyNewInstancesOnly = useCallback(() => {
    setPendingRestart(null);
    void applyFleetChanges([]);
  }, [applyFleetChanges]);

  const handleCancelRestart = useCallback(() => {
    setPendingRestart(null);
  }, []);

  // Available agent identities not yet in fleets
  const availableIdentitiesToAdd = useMemo(() => {
    const existing = new Set(fleets.map((f) => f.agent_id));
    return agentIdentities.filter(
      (a: any) => !existing.has(String(a.agent_id || a.agentId || a.id || ''))
    );
  }, [fleets, agentIdentities]);

  if (!isOpen) return null;

  // Portaled to <body> on the shared `z-modal` layer (same as Modal / SettingsModal):
  // rendered inline from ChainHeader / TaskChainOverview it sat inside the shell, where
  // the fixed mobile sidebar rail painted over its left edge and the bottom chrome over its
  // footer. As a body-level overlay mounted after the shell it covers both.
  // The shared Drawer primitive (portal on z-modal, Esc, focus trap, focus
  // return, scroll lock) replaces the hand-rolled overlay (audit finding).
  return (
    <Drawer
      open={isOpen}
      onOpenChange={(o) => !o && onClose()}
      title="Fleet"
      hideHeader
      size="md"
      data-debug-id="fleet-management-drawer"
    >
      <div className="flex h-full flex-col">
        {/* Drawer Header */}
        <div className="flex items-center justify-between border-b border-subtle px-4 py-3.5 bg-canvas/90">
          <div className="flex items-center gap-2">
            <Icon name="layers" size={18} className="text-accent" />
            <div>
              <h2 className="text-sm font-bold text-primary">Fleet Management</h2>
              <p className="text-[11px] text-muted">Placement, roles, concurrency &amp; live slots</p>
            </div>
          </div>
          <IconButton
            icon="close"
            label="Close drawer"
            size="sm"
            onClick={onClose}
          />
        </div>

        {errorMsg && (
          <div className="bg-danger-soft/30 border-b border-danger/30 px-4 py-2 text-xs text-danger">
            {errorMsg}
          </div>
        )}

        {/* Drawer Content. min-h-0 lets this region shrink below its intrinsic
            height so long role-card content scrolls instead of pushing the
            footer out of the viewport. */}
        <div className="flex-1 min-h-0 overflow-y-auto p-4 space-y-4">
          <div className="text-xs text-muted">
            Configure fleet roles (worker / reviewer), placement bridge, provider/model defaults, and concurrency limits per agent template.
          </div>

          <div className="space-y-3">
            {fleets.map((fleet) => {
              const agentId = fleet.agent_id;
              const roleName = formatFleetRoleName(agentId, agentIdentities);
              const effectiveCapacity = draftCapacities[agentId] ?? fleet.capacity ?? 1;
              const origCapacity = getOriginalCapacity(agentId);
              const isPersisted = origCapacity !== null;
              // The Soloist coordinator's implicit worker row: not stored, so there is
              // nothing to delete; saving an edit stores it as a real row.
              const isImplicit = Boolean((fleet as any).implicit);
              const activeCount = fleet.active_count ?? fleet.activeCount ?? 0;
              const isSaturated = activeCount >= effectiveCapacity;

              const effectiveRoles = normalizeFleetRoles(draftRoles[agentId] ?? fleet.roles);
              // What the hub will actually apply for this row (plan REQ-UI-12).
              const placement = describeEffectivePlacement((fleet as any).effective, bridgeLabel);
              const autoModel = (fleet as any).effective?.model_source === 'catalog_default';
              const origRoles = getOriginalFleetRoles(rawFleets, agentId);
              const rolesModified = origRoles === null || !fleetRolesEqual(effectiveRoles, origRoles);

              const effectiveBridgeId = draftBridgeIds[agentId] ?? fleet.bridge_id ?? fleet.bridgeId ?? '';
              const origBridgeId = getOriginalFleetBridgeId(rawFleets, agentId);
              const bridgeModified = origCapacity === null || effectiveBridgeId !== origBridgeId;

              const effectiveTopPT = draftTopLevelPT[agentId] ?? {
                provider: fleet.provider ?? '',
                provider_profile: fleet.provider_profile,
                model: fleet.model ?? '',
              };
              const topModelOptions = modelOptionsForProvider(bridgeCapabilities, effectiveTopPT.provider, effectiveTopPT.provider_profile);

              const effectiveMinWarm = draftMinWarms[agentId] ?? fleet.min_warm ?? fleet.minWarm ?? 0;
              const origMinWarm = getOriginalFleetMinWarm(rawFleets, agentId);
              const minWarmModified = origCapacity === null || effectiveMinWarm !== origMinWarm;

              const effectiveIdleTtl = draftIdleTtls[agentId] ?? fleet.idle_ttl_seconds ?? fleet.idleTtlSeconds ?? 600;
              const origIdleTtl = getOriginalFleetIdleTtl(rawFleets, agentId);
              const idleTtlModified = origCapacity === null || effectiveIdleTtl !== origIdleTtl;

              const roleDraftMap = draftProviderModels[agentId] || {};
              const capacityModified = origCapacity === null || effectiveCapacity !== origCapacity;
              const runtimeModified = providerModelModified(
                rawFleets,
                agentId,
                draftProviderModels,
                bridgeId,
                draftTopLevelPT
              );
              const isModified =
                capacityModified ||
                runtimeModified ||
                rolesModified ||
                bridgeModified ||
                minWarmModified ||
                idleTtlModified;

              const pendingParts: string[] = [];
              if (capacityModified) pendingParts.push(`capacity ${origCapacity ?? 0} to ${effectiveCapacity}`);
              if (rolesModified) pendingParts.push(`Roles: ${formatFleetRolesBadge(effectiveRoles)}`);
              if (bridgeModified) pendingParts.push(`Bridge: ${effectiveBridgeId ? bridgeLabel(effectiveBridgeId) : 'fleet default'}`);
              if (runtimeModified) pendingParts.push('Provider/model settings changed');
              if (minWarmModified) pendingParts.push(`Min warm: ${effectiveMinWarm}`);
              if (idleTtlModified) pendingParts.push(`Idle TTL: ${effectiveIdleTtl}s`);

              const liveInstances = liveInstancesByRoleMap[agentId] || [];
              const activeTasks = activeTasksByRoleMap[agentId] || [];
              const isRuntimeExpanded = Boolean(expandedRuntimeRoles[agentId]);
              const hasCustomOverrides =
                hasCustomRuntimeOverrides(roleDraftMap) ||
                Boolean(effectiveTopPT.provider || effectiveTopPT.model);

              return (
                <div
                  key={agentId}
                  data-debug-id={`fleet-drawer-role-card-${agentId}`}
                  className={`rounded-xl border p-3.5 space-y-3 transition-colors ${
                    isModified
                      ? 'border-warning/50 bg-warning-soft/10'
                      : 'border-subtle bg-surface-secondary/30'
                  }`}
                >
                  <div className="flex items-start justify-between gap-2">
                    <div className="flex min-w-0 items-center gap-2">
                      <div className="grid h-8 w-8 shrink-0 place-items-center rounded-lg bg-accent/10 text-accent font-bold text-xs uppercase">
                        {roleName.slice(0, 2)}
                      </div>
                      <div className="min-w-0">
                        <h4 className="text-xs font-bold text-primary flex min-w-0 flex-wrap items-center gap-x-1.5">
                          <span className="min-w-0 break-words" title={agentId}>{roleName}</span>
                          {fleet.paused && (
                            <span
                              data-debug-id={`fleet-paused-badge-${agentId}`}
                              className="rounded bg-warning-soft px-1.5 py-0.5 text-[10px] font-semibold text-warning"
                              title={`No new leases for: ${(fleet.paused_roles || []).join(', ') || 'all roles'}. Current work continues. Resume with task-chain fleet resume.`}
                            >
                              Paused{fleet.paused_roles && fleet.paused_roles.length > 0 && !fleetRolesEqual(fleet.paused_roles, fleet.roles) ? `: ${fleet.paused_roles.join(', ')}` : ''}
                            </span>
                          )}
                        </h4>
                        <div className="flex flex-wrap items-center gap-1 text-[11px] text-muted font-mono mt-0.5">
                          <span>{activeCount}/{effectiveCapacity} active</span>
                          {isModified && (
                            <span
                              data-debug-id={`fleet-staged-indicator-${agentId}`}
                              className="ml-1.5 rounded bg-warning-soft px-1.5 py-0.5 text-[10px] font-semibold text-warning"
                            >
                              Pending: {pendingParts.join(' · ')}
                            </span>
                          )}
                        </div>
                      </div>
                    </div>
                    <div className="flex items-center gap-1.5 shrink-0">
                      <Badge tone={isSaturated ? 'warning' : 'neutral'} className="shrink-0 whitespace-nowrap">
                        {isSaturated ? 'Saturated' : 'Available'}
                      </Badge>
                      {isImplicit && (
                        <span title="Solo mode: the coordinator works the tickets itself without a stored fleet row.">
                          <Badge tone="info" className="shrink-0 whitespace-nowrap">Solo</Badge>
                        </span>
                      )}
                      {!isImplicit && (
                        <Button
                          size="sm"
                          variant="ghost"
                          tone="danger"
                          data-debug-id={`fleet-delete-role-btn-${agentId}`}
                          onClick={() => {
                            // Deleting a saved row stops its agents getting work: ask first.
                            if (isPersisted && !window.confirm(`Remove ${roleName} from this chain's fleet? Its agents stop getting new tickets.`)) return;
                            void handleRemoveFleet(agentId, isPersisted);
                          }}
                          disabled={isUpdating || isApplying || isDeleting}
                          title={isPersisted ? `Delete ${roleName} fleet row` : `Remove staged ${roleName}`}
                          aria-label={`Remove ${roleName} from fleet`}
                        >
                          Remove
                        </Button>
                      )}
                    </div>
                  </div>

                  {/* Placement Section: Roles (worker / reviewer), Bridge Pin, and Role Default Provider/Model */}
                  <div
                    data-debug-id={`fleet-placement-section-${agentId}`}
                    className="rounded-lg border border-subtle bg-surface p-2.5 space-y-2.5"
                  >
                    <div className="space-y-1.5">
                      <span className="text-xs font-medium text-primary">Fleet Roles</span>
                      <div className="flex flex-wrap items-center gap-1.5" role="group" aria-label={`Roles for ${roleName}`}>
                        {/* named-reviewer is the hub's placement-only marker for reviewers named on a task; not a role people manage */}
                        {[...FLEET_ROLES, ...effectiveRoles.filter((r) => !(FLEET_ROLES as readonly string[]).includes(r) && r !== 'named-reviewer')].map((roleKey) => {
                          const selected = effectiveRoles.includes(roleKey);
                          return (
                            <button
                              key={roleKey}
                              type="button"
                              data-debug-id={`fleet-role-toggle-${agentId}-${roleKey}`}
                              aria-pressed={selected}
                              disabled={isUpdating || isApplying}
                              onClick={() => handleDraftRoleToggle(agentId, roleKey, effectiveRoles)}
                              className={`inline-flex items-center gap-1 rounded-full border px-2.5 py-0.5 text-[11px] font-semibold transition-colors cursor-pointer disabled:opacity-40 ${
                                selected
                                  ? 'border-accent bg-accent text-accent-fg'
                                  : 'border-dashed border-strong bg-transparent text-muted hover:border-solid hover:text-primary'
                              }`}
                            >
                              {selected ? <Icon name="check" size={10} /> : <Icon name="plus" size={10} />}
                              {roleKey}
                            </button>
                          );
                        })}
                        <input
                          type="text"
                          data-debug-id={`fleet-role-custom-input-${agentId}`}
                          aria-label={`Add review role for ${roleName}`}
                          placeholder="+ role"
                          title="Add a custom review role (e.g. security); tasks list it in review_roles"
                          value={customRoleDrafts[agentId] ?? ''}
                          disabled={isUpdating || isApplying}
                          onChange={(e) => setCustomRoleDrafts((prev) => ({ ...prev, [agentId]: e.target.value }))}
                          onKeyDown={(e) => {
                            if (e.key !== 'Enter') return;
                            e.preventDefault();
                            const role = String(customRoleDrafts[agentId] ?? '').trim().toLowerCase();
                            if (!isValidFleetRoleName(role)) {
                              setErrorMsg('Role names are 1-32 chars of a-z, 0-9, _ or -, starting with a letter');
                              return;
                            }
                            if (!effectiveRoles.includes(role)) handleDraftRoleToggle(agentId, role, effectiveRoles);
                            setCustomRoleDrafts((prev) => ({ ...prev, [agentId]: '' }));
                          }}
                          className="w-24 rounded-full border border-subtle bg-canvas px-2.5 py-0.5 text-[11px] text-primary outline-none focus:border-accent"
                        />
                      </div>
                    </div>

                    <div className="space-y-1">
                      <span className="block text-[10px] font-semibold uppercase tracking-wide text-muted">
                        Placement Bridge
                      </span>
                      <Select
                        data-debug-id={`fleet-bridge-select-${agentId}`}
                        value={effectiveBridgeId}
                        onChange={(val) => handleDraftBridgeIdChange(agentId, val)}
                        disabled={isUpdating || isApplying}
                        size="sm"
                        width="full"
                        aria-label={`Placement bridge for ${roleName}`}
                        options={(effectiveBridgeId && !bridgeSelectOptions.some((o) => o.value === effectiveBridgeId)
                          ? [...bridgeSelectOptions, { value: effectiveBridgeId, label: bridgeLabel(effectiveBridgeId) }]
                          : bridgeSelectOptions
                        ).map((o) =>
                          o.value === ''
                            ? {
                                ...o,
                                label:
                                  (fleet as any).effective?.bridge_source && (fleet as any).effective.bridge_source !== 'fleet' && placement.bridge
                                    ? `${placement.bridge} (${placement.bridgeSource})`
                                    : 'Chain default',
                              }
                            : o,
                        )}
                      />
                    </div>

                    <Text
                      as="p"
                      role="caption"
                      tone={placement.bridge ? 'muted' : 'warning'}
                      data-debug-id={`fleet-effective-placement-${agentId}`}
                    >
                      Runs on: {placement.summary}
                    </Text>

                    <div className="grid grid-cols-2 gap-2">
                      <div className="space-y-1">
                        <span className="block text-[10px] font-semibold uppercase tracking-wide text-muted">
                          Default Provider
                        </span>
                        <Select
                          data-debug-id={`fleet-default-provider-select-${agentId}`}
                          value={effectiveTopPT.provider_profile || effectiveTopPT.provider}
                          onChange={(val) => handleDraftTopLevelProviderChange(agentId, val)}
                          disabled={isUpdating || isApplying}
                          size="sm"
                          width="full"
                          aria-label={`Default provider for ${roleName}`}
                          options={[
                            {
                              value: '',
                              label: autoModel && (fleet as any).effective?.provider ? `${(fleet as any).effective.provider} (default)` : 'Bridge default',
                            },
                            ...(effectiveTopPT.provider &&
                            !bridgeCapabilities.some((cap) => (cap.profile_id || cap.provider) === (effectiveTopPT.provider_profile || effectiveTopPT.provider))
                              ? [{ value: effectiveTopPT.provider_profile || effectiveTopPT.provider, label: effectiveTopPT.provider_profile || effectiveTopPT.provider }]
                              : []),
                            ...bridgeCapabilities.map((cap) => ({ value: cap.profile_id || cap.provider, label: cap.label || cap.profile_id || cap.provider })),
                          ]}
                        />
                      </div>
                      <div className="space-y-1">
                        <span className="block text-[10px] font-semibold uppercase tracking-wide text-muted">
                          Default Model
                        </span>
                        <Select
                          data-debug-id={`fleet-default-model-select-${agentId}`}
                          value={effectiveTopPT.model}
                          onChange={(val) => handleDraftTopLevelModelChange(agentId, val)}
                          disabled={!effectiveTopPT.provider || isUpdating || isApplying}
                          size="sm"
                          width="full"
                          aria-label={`Default model for ${roleName}`}
                          options={[
                            {
                              value: '',
                              label: autoModel && (fleet as any).effective?.model ? `${(fleet as any).effective.model} (default)` : 'Bridge default',
                            },
                            ...(effectiveTopPT.model && !topModelOptions.includes(effectiveTopPT.model)
                              ? [{ value: effectiveTopPT.model, label: `${effectiveTopPT.model} (unavailable)` }]
                              : []),
                            ...topModelOptions.map((m) => ({ value: m, label: m })),
                          ]}
                        />
                      </div>
                    </div>
                  </div>

                  {/* Inline +/- and Slider controls */}
                  <div className="rounded-lg border border-subtle bg-surface p-2.5 space-y-2">
                    <div className="flex items-center justify-between">
                      <span className="text-xs font-medium text-primary">Capacity Limit</span>
                      <div className="flex items-center gap-1.5">
                        <button
                          type="button"
                          data-debug-id={`fleet-capacity-dec-${agentId}`}
                          onClick={() => handleDraftCapacityChange(agentId, Math.max(1, effectiveCapacity - 1))}
                          disabled={effectiveCapacity <= 1 || isUpdating || isApplying}
                          aria-label={`Decrease capacity for ${roleName}`}
                          className="h-6 w-6 rounded border border-subtle bg-surface-raised hover:bg-neutral-soft text-primary font-bold flex items-center justify-center disabled:opacity-40 cursor-pointer"
                        >
                          -
                        </button>
                        <span
                          data-debug-id={`fleet-capacity-val-${agentId}`}
                          className={`w-7 text-center font-mono font-bold text-xs ${
                            isModified ? 'text-warning font-black' : 'text-primary'
                          }`}
                        >
                          {effectiveCapacity}
                        </span>
                        <button
                          type="button"
                          data-debug-id={`fleet-capacity-inc-${agentId}`}
                          onClick={() => handleDraftCapacityChange(agentId, effectiveCapacity + 1)}
                          disabled={effectiveCapacity >= 20 || isUpdating || isApplying}
                          aria-label={`Increase capacity for ${roleName}`}
                          className="h-6 w-6 rounded border border-subtle bg-surface-raised hover:bg-neutral-soft text-primary font-bold flex items-center justify-center disabled:opacity-40 cursor-pointer"
                        >
                          +
                        </button>
                      </div>
                    </div>

                    <input
                      type="range"
                      min="1"
                      max="10"
                      value={effectiveCapacity}
                      data-debug-id={`fleet-capacity-slider-${agentId}`}
                      onChange={(e) => handleDraftCapacityChange(agentId, parseInt(e.target.value, 10))}
                      disabled={isUpdating || isApplying}
                      aria-label={`Capacity slider for ${roleName}`}
                      className="w-full h-1.5 bg-neutral-soft rounded-lg appearance-none cursor-pointer accent-accent"
                    />
                    <div className="flex justify-between text-[10px] text-muted">
                      <span>1 slot</span>
                      <span>5 slots</span>
                      <span>10 slots</span>
                    </div>

                    <div className="grid grid-cols-2 gap-2 pt-1 border-t border-subtle/60">
                      <label className="space-y-1 block">
                        <span className="block text-[10px] font-semibold uppercase tracking-wide text-muted">
                          Min Warm (0–{effectiveCapacity})
                        </span>
                        <input
                          type="number"
                          min={0}
                          max={effectiveCapacity}
                          value={effectiveMinWarm}
                          data-debug-id={`fleet-min-warm-input-${agentId}`}
                          disabled={isUpdating || isApplying}
                          onChange={(e) =>
                            handleDraftMinWarmChange(agentId, parseInt(e.target.value, 10), effectiveCapacity)
                          }
                          aria-label={`Min warm instances for ${roleName}`}
                          className="w-full rounded border border-subtle bg-surface-raised px-2 py-1 text-xs font-mono text-primary"
                        />
                      </label>
                      <label className="space-y-1 block">
                        <span className="block text-[10px] font-semibold uppercase tracking-wide text-muted">
                          Idle TTL (sec)
                        </span>
                        <input
                          type="number"
                          min={30}
                          step={60}
                          value={effectiveIdleTtl}
                          data-debug-id={`fleet-idle-ttl-input-${agentId}`}
                          disabled={isUpdating || isApplying}
                          onChange={(e) => handleDraftIdleTtlChange(agentId, parseInt(e.target.value, 10))}
                          aria-label={`Idle TTL seconds for ${roleName}`}
                          className="w-full rounded border border-subtle bg-surface-raised px-2 py-1 text-xs font-mono text-primary"
                        />
                      </label>
                    </div>
                  </div>

                  {/* Expandable "Configure Runtime" Section (REQ-FLEET-UI-EXPANDABLE-1, REQ-FLEET-PER-BRIDGE-1) */}
                  <div className="rounded-lg border border-subtle bg-surface overflow-hidden">
                    <button
                      type="button"
                      data-debug-id={`fleet-runtime-expand-btn-${agentId}`}
                      onClick={() =>
                        setExpandedRuntimeRoles((prev) => ({
                          ...prev,
                          [agentId]: !prev[agentId],
                        }))
                      }
                      aria-expanded={isRuntimeExpanded}
                      aria-label={`Configure runtime for ${roleName}`}
                      className="w-full flex items-center justify-between p-2.5 hover:bg-neutral-soft/40 transition-colors cursor-pointer text-left select-none"
                    >
                      <div className="flex items-center gap-1.5 min-w-0">
                        <Icon
                          name={isRuntimeExpanded ? 'chevron-down' : 'chevron-right'}
                          size={14}
                          className="text-muted shrink-0"
                        />
                        <span className="text-xs font-medium text-primary">Configure Per-Bridge Runtime</span>
                      </div>
                      <span
                        data-debug-id={`fleet-runtime-summary-pill-${agentId}`}
                        className={`rounded-full px-2 py-0.5 text-[10px] font-medium border shrink-0 ${
                          hasCustomOverrides
                            ? 'border-accent/30 bg-accent-soft/30 text-accent font-semibold'
                            : 'border-subtle bg-surface-raised text-muted'
                        }`}
                      >
                        {hasCustomOverrides ? 'Custom Overrides' : 'Defaults'}
                      </span>
                    </button>

                    {isRuntimeExpanded && (
                      <div className="border-t border-subtle p-2.5 space-y-2.5 bg-canvas/40">
                        {bridgesToRender.length === 0 ? (
                          <div className="text-[11px] text-muted italic p-1">
                            No active bridges connected.
                          </div>
                        ) : (
                          bridgesToRender.map((bridge: any) => {
                            const bId = String(bridge.bridge_id || bridge.bridgeId || bridge.id || '');
                            const bridgeDraftPT = roleDraftMap[bId] ?? { provider: '', model: '' };
                            return (
                              <BridgeRuntimeRow
                                key={bId}
                                agentId={agentId}
                                roleName={roleName}
                                bridge={bridge}
                                draftPT={bridgeDraftPT}
                                onProviderChange={(newProvider, caps) =>
                                  handleDraftBridgeProviderChange(agentId, bId, newProvider, caps)
                                }
                                onModelChange={(newModel) =>
                                  handleDraftBridgeModelChange(agentId, bId, newModel)
                                }
                                disabled={isUpdating || isApplying}
                              />
                            );
                          })
                        )}
                      </div>
                    )}
                  </div>

                  {/* Live Instances */}
                  <div className="space-y-1">
                    <div className="flex items-center justify-between text-[11px] text-muted">
                      <span>Live Instances ({liveInstances.length})</span>
                      <span>Active Tickets ({activeTasks.length})</span>
                    </div>
                    {liveInstances.length === 0 ? (
                      <p className="text-[11px] text-faint italic py-0.5">No warm instances spawned yet.</p>
                    ) : (
                      <div className="flex flex-wrap gap-1">
                        {liveInstances.map((inst) => {
                          const iid = String(inst.agentInstanceId || inst.agent_instance_id || '');
                          return (
                            <span
                              key={iid}
                              className="inline-flex items-center gap-1 rounded bg-surface px-1.5 py-0.5 text-[10px] font-mono border border-subtle text-primary"
                            >
                              <StatusDot size="sm" tone="success" label="Running" />
                              <span className="truncate max-w-[100px]">{inst.displayName || iid}</span>
                            </span>
                          );
                        })}
                      </div>
                    )}
                  </div>
                </div>
              );
            })}
          </div>

          {/* Add Fleet Role if unconfigured roles exist */}
          {availableIdentitiesToAdd.length > 0 && (
            <div className="rounded-xl border border-dashed border-subtle p-3 space-y-2">
              <span className="text-xs font-semibold text-primary">Configure Another Agent Role</span>
              <div className="flex items-center gap-2">
                <Select
                  data-debug-id="fleet-drawer-add-role-select"
                  width="full"
                  value={selectedNewAgentId}
                  onChange={setSelectedNewAgentId}
                  options={[
                    { value: '', label: 'Select agent identity…' },
                    ...availableIdentitiesToAdd.map((a: any) => {
                      const id = String(a.agent_id || a.agentId || a.id || '');
                      const name = a.name || a.display_name || formatFleetRoleName(id, agentIdentities);
                      return { value: id, label: name };
                    }),
                  ]}
                />
                <button
                  type="button"
                  data-debug-id="fleet-drawer-add-role-btn"
                  disabled={!selectedNewAgentId || isUpdating || isApplying}
                  onClick={() => handleAddFleet(selectedNewAgentId)}
                  className="rounded bg-accent px-3 py-1.5 text-xs font-semibold text-accent-fg hover:opacity-90 disabled:opacity-40 cursor-pointer shrink-0"
                >
                  Add
                </button>
              </div>
            </div>
          )}
        </div>

        {/* Drawer Footer with Batch Apply / Reset. shrink-0 keeps the controls
            pinned in view; the bottom padding lifts them above the persistent
            mobile tab bar / home-indicator safe area, and resolves to the plain
            0.75rem once --ui-bottom-chrome and the safe-area inset are 0. */}
        <div className="border-t border-subtle p-3 pb-[max(0.75rem,max(var(--ui-bottom-chrome,0px),env(safe-area-inset-bottom,0px)))] flex flex-wrap items-center justify-between gap-2.5 bg-canvas/90 shrink-0">
          {restartSummary &&
            (restartSummary.restartedByRole.length > 0 || restartSummary.failures.length > 0) && (
              <div
                data-debug-id="fleet-restart-summary"
                role="status"
                className="w-full space-y-1 rounded-lg border border-subtle bg-surface-secondary/40 px-3 py-2"
              >
                {restartSummary.restartedByRole.map((role) => (
                  <div key={role.agentId} className="flex items-center gap-1.5 text-xs text-success">
                    <Icon name="check" size="sm" />
                    <span>
                      {formatFleetRoleName(role.agentId, agentIdentities)}: restarted {role.count}{' '}
                      {role.count === 1 ? 'instance' : 'instances'}
                    </span>
                  </div>
                ))}
                {restartSummary.failures.map((failure, index) => (
                  <div
                    key={`${failure.instance_id}-${index}`}
                    data-debug-id="fleet-restart-failure"
                    className="text-xs text-warning"
                  >
                    <span title={failure.instance_id}>Instance restart failed</span>: {failure.message}
                  </div>
                ))}
              </div>
            )}
          <div className="text-xs text-muted">
            {hasPendingChanges ? (
              <span
                data-debug-id="fleet-drawer-pending-count"
                className="text-warning font-semibold flex items-center gap-1.5"
              >
                <span className="inline-block h-2 w-2 rounded-full bg-warning animate-pulse" />
                {changedFleets.length} {changedFleets.length === 1 ? 'role change' : 'role changes'} pending
              </span>
            ) : successMsg ? (
              <span className="text-success font-medium flex items-center gap-1">
                <Icon name="check" size="sm" /> {successMsg}
              </span>
            ) : (
              <span className="text-faint">No pending changes</span>
            )}
          </div>
          <div className="flex items-center gap-2">
            {hasPendingChanges && (
              <button
                type="button"
                data-debug-id="fleet-drawer-reset-btn"
                onClick={handleReset}
                disabled={isUpdating || isApplying}
                className="rounded border border-subtle bg-surface px-3 py-1.5 text-xs font-semibold text-muted hover:text-primary hover:bg-neutral-soft cursor-pointer transition-colors disabled:opacity-40"
              >
                Reset
              </button>
            )}
            <button
              type="button"
              data-debug-id="fleet-drawer-apply-btn"
              onClick={handleApply}
              disabled={!hasPendingChanges || isUpdating || isApplying}
              className="rounded bg-accent px-4 py-1.5 text-xs font-semibold text-accent-fg hover:opacity-90 cursor-pointer disabled:opacity-40 transition-opacity flex items-center gap-1.5"
            >
              {isApplying || isUpdating ? (
                <>
                  <span className="inline-block h-3 w-3 border-2 border-accent-fg border-t-transparent rounded-full animate-spin" />
                  Applying…
                </>
              ) : (
                'Apply'
              )}
            </button>
            <button
              type="button"
              data-debug-id="fleet-drawer-done-btn"
              onClick={onClose}
              className="rounded bg-neutral-soft px-3 py-1.5 text-xs font-semibold text-primary hover:bg-surface-raised cursor-pointer"
            >
              Done
            </button>
          </div>
        </div>

        {/* Confirm-before-restart. Opens from Apply (before any PUT) only when a
            provider/model edit would leave live instances on the old values. Mounted
            inside the panel so the drawer's backdrop click handler sees none of the
            portal's bubbled events; @ui Modal owns Esc / backdrop / focus return
            (the Apply button is the focus trigger). */}
        {pendingRestart && (
          <Modal
            open
            onOpenChange={(next) => {
              if (!next) setPendingRestart(null);
            }}
            title="Restart live instances?"
            size="md"
            data-debug-id="fleet-restart-confirm-modal"
          >
            <ModalBody>
              <Text role="body">
                Provider/model changes only take effect for instances started after the change. These
                roles currently have live instances running with the old values:
              </Text>
              <ul className="mt-3 space-y-2">
                {pendingRestart.map((role) => {
                  const roleName = formatFleetRoleName(role.agentId, agentIdentities);
                  return (
                    <li
                      key={role.agentId}
                      data-debug-id={`fleet-restart-role-${role.agentId}`}
                      className="space-y-1 rounded-lg border border-subtle bg-surface-secondary/40 p-2.5"
                    >
                      <div className="flex items-center justify-between gap-2">
                        <span className="text-xs font-semibold text-primary">{roleName}</span>
                        <span className="font-mono text-[11px] text-muted">
                          {role.liveCount} live {role.liveCount === 1 ? 'instance' : 'instances'} ·{' '}
                          {role.activeTaskCount} active {role.activeTaskCount === 1 ? 'task' : 'tasks'}
                        </span>
                      </div>
                      <div className="font-mono text-[11px] text-muted">
                        {role.bridgeModels ? Object.entries(role.bridgeModels).map(([id, selection]) => {
                          const bridge = bridgesToRender.find((bridge: any) => String(bridge.bridge_id || bridge.bridgeId || bridge.id || '') === id);
                          return <div key={id}>{bridge?.label || bridge?.machine_hostname || id}: {selection.provider} / {selection.model}</div>;
                        }) : <span>{role.provider || role.originalProvider} / {role.model || role.originalModel}</span>}
                      </div>
                    </li>
                  );
                })}
              </ul>
              <Text role="body-sm" tone="warning" className="mt-3 block">
                Restarting interrupts in-progress agent runs — the active task count above is the
                interruption cost. "Apply to New Instances Only" leaves live instances untouched.
              </Text>
            </ModalBody>
            <ModalFooter>
              <Button
                variant="secondary"
                data-debug-id="fleet-restart-cancel-btn"
                onClick={handleCancelRestart}
              >
                Cancel
              </Button>
              <Button
                variant="secondary"
                data-debug-id="fleet-restart-new-only-btn"
                onClick={handleApplyNewInstancesOnly}
              >
                Apply to New Instances Only
              </Button>
              <Button
                variant="primary"
                data-debug-id="fleet-restart-now-btn"
                onClick={handleConfirmRestartNow}
              >
                Apply &amp; Restart Now
              </Button>
            </ModalFooter>
          </Modal>
        )}
      </div>
    </Drawer>
  );
};
