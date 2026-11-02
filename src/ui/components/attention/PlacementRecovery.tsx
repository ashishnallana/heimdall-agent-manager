import { useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { Button } from '@ui';
import { attentionApi, useRecoverPlacementMutation, type AttentionTaskItem, type PlacementTarget } from '../../api/endpoints/attention';
import { useListAgentIdentitiesQuery, useListAgentInstancesQuery } from '../../api/endpoints/agents';
import { useListBridgesQuery, useBridgeProviderStatus, useListAgentBridgeSupportQuery } from '../../api/endpoints/bridgeSupport';
import { useGetTaskChainFleetsQuery } from '../../api/endpoints/taskChains';
import { useFetchChainTaskDetailQuery, useFetchTaskChainDetailQuery } from '../../api/endpoints/tasks';
import { apiErrorText, queryErrorStatus } from '../../api/cookieFetch';
import { heimdallApi } from '../../api/heimdallApi';
import { setPlacementDraft, clearPlacementDraft, type PlacementDraft } from '../../store/attentionSlice';
import { bridgeIdOf, bridgeIsOnline, bridgeLabel } from '../../utils/bridgeLaunchOptions';
import { FleetManagementDrawer } from '../tasks/FleetManagementDrawer';
import { VaultText } from '../vault';
import { placementIdentityCandidates, placementRecoveryInput, placementTargetKey } from './attentionModel';

const EMPTY_DRAFT: PlacementDraft = { action: 'bridge', bridgeId: '', agentId: '' };
const SOURCE_LABELS: Record<string, string> = {
  task_pin: 'Ticket bridge pin', fleet: 'Chain fleet', chain_directory: 'Chain workspace', coordinator: 'Coordinator instance', none: 'No placement',
};

/** Each target keeps its own selection; a refreshed guard always needs a new confirmation. */
export function PlacementRecovery({ item, onOpenConfiguration }: { item: AttentionTaskItem; onOpenConfiguration?: () => void }) {
  return (
    <section aria-label="Placement recovery" data-debug-id="attention-placement" className="mt-3 space-y-3 text-[13px]">
      <p className="text-muted">Repair each unavailable worker or reviewer. Other reviewers, role requirements and your approval stay in place.</p>
      {(item.details.targets || []).map((target) => (
        <RecoveryTarget key={placementTargetKey(item.card_id, target)} item={item} target={target} onOpenConfiguration={onOpenConfiguration} />
      ))}
    </section>
  );
}

function RecoveryTarget({ item, target, onOpenConfiguration }: { item: AttentionTaskItem; target: PlacementTarget; onOpenConfiguration?: () => void }) {
  const dispatch = useDispatch<any>();
  const key = placementTargetKey(item.card_id, target);
  const prefix = `attention-placement-${target.failure.phase}-${target.failure.agent_id || 'unassigned'}-${target.failure.role}`;
  const draft = useSelector((s: any): PlacementDraft => s.attention?.placementDrafts?.[key] || EMPTY_DRAFT);
  const change = (patch: Partial<PlacementDraft>) => {
    dispatch(setPlacementDraft({ key, draft: { ...draft, ...patch } }));
    setConfirmation('');
  };
  const [confirmation, setConfirmation] = useState('');
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [refreshing, setRefreshing] = useState(false);
  const [fleetOpen, setFleetOpen] = useState(false);
  const [recover, mutation] = useRecoverPlacementMutation();
  const chainId = item.action_refs.chain_id;
  const taskId = item.action_refs.task_id;
  const identities = useListAgentIdentitiesQuery();
  const fleets = useGetTaskChainFleetsQuery({ chainId });
  const bridges = useListBridgesQuery();
  const detail = useFetchChainTaskDetailQuery({ chainId, taskId });
  const task = detail.data?.task;
  const leases: any[] = task?.leases || [];
  const instances = useListAgentInstancesQuery({ limit: 1000 }, { skip: !leases.length });
  const rows: any[] = bridges.data?.bridges || [];
  const agents: any[] = identities.data?.agents || [];
  const f = target.failure;
  const worker = f.phase === 'work';
  const affected = useFetchTaskChainDetailQuery({ chainId }, { skip: worker || draft.action !== 'bridge' || !confirmation });
  const name = agents.find((a) => (a.agent_id || a.id) === f.agent_id);
  const targetName = String(name?.name || name?.display_name || name?.slug || (f.agent_id ? `Unavailable agent (${f.agent_id})` : 'Unassigned worker'));
  const effectiveBridge = rows.find((b) => bridgeIdOf(b) === f.bridge_id);
  const row = (fleets.data || []).find((r) => r.agent_id === f.agent_id);
  const candidates = placementIdentityCandidates(target, fleets.data || [], agents, worker ? [] : [...(task?.brief?.reviewers || []), task?.brief?.assignee || '']);
  const eligibleBridges = rows.filter((b) => bridgeIsOnline(b) && !b.revoked_at && !b.enrollment_pending_until && b.enrollment_state !== 'pending');
  const selectedBridge = eligibleBridges.find((b) => bridgeIdOf(b) === draft.bridgeId);
  const providerStatus = useBridgeProviderStatus(selectedBridge, { skip: draft.action !== 'bridge' });
  const support = useListAgentBridgeSupportQuery({ agentId: f.agent_id }, { skip: !f.agent_id || draft.action !== 'bridge' });
  const selection: { provider?: string; provider_profile?: string; model?: string } = row?.bridge_models?.[draft.bridgeId] || row || {};
  // Fleet overrides are resolved on the destination, never copied from the failed host.
  const provider = selection.provider || '';
  const profile = selection.provider_profile || provider;
  const model = selection.model || '';
  const supportsProvider = providerStatus.capabilities.some((c) =>
    (!provider || c.provider === provider) && (!profile || (c.profile_id || c.provider) === profile) && (model ? c.models.includes(model) : c.models.length > 0));
  const enabled = !support.data?.entries?.some((s: any) => s.bridgeId === draft.bridgeId && !s.enabled);
  const bridgeReady = !!selectedBridge && providerStatus.loaded && supportsProvider && enabled && !support.isFetching && !support.isError;
  const identityReady = candidates.some((c) => c.agentId === draft.agentId);
  const destination = draft.action === 'bridge' ? draft.bridgeId : draft.agentId;
  const allowedAction = draft.action === 'bridge' ? target.bridge_action === 'change_bridge' : target.identity_action !== 'configure_fleet';
  const input = allowedAction ? placementRecoveryInput(target, draft.action, destination) : null;
  const signature = JSON.stringify(input);
  const guardSignature = JSON.stringify(target.guard);
  const stale = draft.rejectedGuard === guardSignature;
  const workflow = !!(task?.workflow_run_id || task?.stage_key);
  const live = leases.some((l) => worker ? l.kind === 'work' : l.kind === 'review' &&
    (instances.data?.instances || []).some((i: any) => i.agent_instance_id === l.holder_instance_id && i.agent_id === f.agent_id));
  const loading = identities.isFetching || fleets.isFetching || bridges.isFetching || detail.isFetching;
  const failed = identities.isError || fleets.isError || bridges.isError || detail.isError;
  const ready = !!task && allowedAction && !workflow && !live && !stale && !loading && !refreshing && !affected.isFetching && !failed &&
    (draft.action === 'bridge' ? bridgeReady : identityReady);
  const fleetScope = draft.action === 'bridge' && !worker;
  const refresh = async () => {
    setConfirmation(''); setError(''); setRefreshing(true);
    dispatch(heimdallApi.util.invalidateTags([
      { type: 'Attention', id: 'ALL' }, { type: 'Task', id: taskId }, { type: 'TaskChainFleets', id: chainId },
      { type: 'Bridges', id: 'LIST' }, { type: 'Agents', id: 'LIST' }, { type: 'BridgeSupport', id: f.agent_id },
      { type: 'BridgeProviders', id: draft.bridgeId },
    ]));
    try {
      const fresh = await dispatch(attentionApi.endpoints.getAttention.initiate({ since: 'all', kind: 'task' }, { subscribe: false, forceRefetch: true })).unwrap();
      const card = fresh.items.find((i: any) => i.card_id === item.card_id);
      const current = card?.kind === 'task' && card.details.targets?.find((t: PlacementTarget) => placementTargetKey(item.card_id, t) === key);
      // Only a successful fresh read can permit reviewing the same observation
      // again. A failed refresh must never re-enable the stale mutation.
      if (current && JSON.stringify(current.guard) === guardSignature) change({ rejectedGuard: undefined });
    } catch (err) { setError(apiErrorText(err, 'Could not refresh placement')); }
    finally { setRefreshing(false); }
  };
  const apply = async () => {
    if (!ready || !input || confirmation !== signature || mutation.isLoading) return;
    setError(''); setNotice('');
    try {
      await recover({ cardId: item.card_id, chainId, taskId, input }).unwrap();
      dispatch(clearPlacementDraft(key));
      setNotice('Placement updated. Matching will retry; any remaining launch failure stays in Need Attention.');
    } catch (err) {
      setError(apiErrorText(err));
      if (queryErrorStatus(err) === 409) change({ rejectedGuard: guardSignature });
    } finally { setConfirmation(''); }
  };

  return (
    <section aria-label={`${worker ? 'Worker' : 'Reviewer'} ${targetName} ${f.role}`} data-debug-id={prefix} className="space-y-2 rounded-[var(--radius-md)] border border-subtle p-3">
      <h4 className="font-semibold text-primary">{worker ? 'Worker' : 'Reviewer'} · {targetName}{!worker ? ` · ${f.role === 'named' ? 'Named reviewer' : f.role}` : ''}</h4>
      <p data-debug-id={`${prefix}-effective`} className="text-muted">
        Effective bridge: {effectiveBridge ? bridgeLabel(effectiveBridge) : f.bridge_id ? `Missing or inaccessible bridge (${f.bridge_id})` : 'No bridge'} · {SOURCE_LABELS[f.source] || f.source}
        {f.provider ? ` · ${f.provider_profile || f.provider}${f.model ? ` / ${f.model}` : ''}` : ''}
      </p>
      <p data-debug-id={`${prefix}-cause`} role="status" className="text-warning">{f.message || f.reason}</p>
      <p className="text-muted">A live target lease must use checkpoint/hold before a move. Other live leases keep their placement.</p>
      {workflow ? <p role="alert">This is a workflow-managed ticket. Change placement through workflow configuration.</p> : null}
      {live ? <p role="alert">This target has a live lease. Use the checkpoint/hold workflow before changing it.</p> : null}
      {failed ? <p role="alert">Could not load recovery choices. Refresh to retry; your selections are kept.</p> : null}
      <div className="flex flex-wrap gap-2">
        {target.bridge_action === 'configure_coordinator' ? (
          <a data-debug-id={`${prefix}-coordinator`} href={`#/chains/${encodeURIComponent(chainId)}`} onClick={onOpenConfiguration} className="text-accent underline">Configure coordinator instance</a>
        ) : <Button size="sm" data-debug-id={`${prefix}-bridge`} disabled={mutation.isLoading || workflow || live} onClick={() => change({ action: 'bridge' })}>Change bridge</Button>}
        {target.identity_action === 'configure_fleet' ? (
          <Button size="sm" data-debug-id={`${prefix}-fleet`} disabled={workflow || mutation.isLoading} onClick={() => setFleetOpen(true)}>Configure fleet role: {f.role}</Button>
        ) : <Button size="sm" data-debug-id={`${prefix}-identity`} disabled={mutation.isLoading || workflow || live} onClick={() => change({ action: 'identity' })}>{target.identity_action_label}</Button>}
        <Button size="sm" variant="ghost" data-debug-id={`${prefix}-refresh`} disabled={mutation.isLoading || refreshing} onClick={() => void refresh()}>{refreshing ? 'Refreshing…' : 'Refresh'}</Button>
      </div>
      {target.identity_action === 'configure_fleet' ? <p className="text-muted">Role {f.role} uses all eligible fleet holders; this ticket cannot assign a single replacement. Fleet role changes affect the chain. Other role requirements remain required. {candidates.length ? `Other eligible holders: ${candidates.map((c) => c.name).join(', ')}.` : 'No other eligible holder is configured.'}</p> : null}
      {allowedAction && !workflow ? (
        <>
          <label className="block text-muted" htmlFor={`${prefix}-select`}>{draft.action === 'bridge' ? 'Destination bridge' : 'Replacement durable agent'}</label>
          <select id={`${prefix}-select`} aria-label={draft.action === 'bridge' ? `Destination bridge for ${targetName}` : `Replacement agent for ${targetName}`} data-debug-id={`${prefix}-select`} value={destination} disabled={mutation.isLoading || live} className="w-full rounded border border-subtle bg-surface p-2 text-primary" onChange={(e) => change(draft.action === 'bridge' ? { bridgeId: e.target.value } : { agentId: e.target.value })}>
            <option value="">Choose {draft.action === 'bridge' ? 'an online enrolled bridge' : 'an eligible fleet agent'}</option>
            {destination && !(draft.action === 'bridge' ? eligibleBridges.some((b) => bridgeIdOf(b) === destination) : candidates.some((c) => c.agentId === destination)) ? <option value={destination} disabled>Previous selection is currently unavailable</option> : null}
            {draft.action === 'bridge' ? eligibleBridges.map((b) => <option key={bridgeIdOf(b)} value={bridgeIdOf(b)}>{bridgeLabel(b)}</option>) : candidates.map((c) => <option key={c.agentId} value={c.agentId}>{c.name}</option>)}
          </select>
          {draft.action === 'bridge' && destination && !bridgeReady ? <p role="status">{!providerStatus.loaded ? 'Checking destination provider availability…' : !enabled ? 'This agent is disabled on the destination bridge.' : 'Destination provider/profile/model is unavailable. Configure the bridge and refresh.'}</p> : null}
          {draft.action === 'identity' && !candidates.length ? (
            <div>
              <p>No eligible active fleet identity. Configure an unpaused {worker ? 'worker' : 'reviewer'} row first.</p>
              <Button size="sm" data-debug-id={`${prefix}-fleet`} onClick={() => setFleetOpen(true)}>Configure fleet</Button>
            </div>
          ) : null}
          <p data-debug-id={`${prefix}-scope`} className="text-muted">{fleetScope ? 'All tickets using this fleet: changes this agent’s bridge across the chain for future grants. Existing leases keep their placement.' : draft.action === 'bridge' ? 'This ticket: changes only its worker bridge pin.' : worker ? 'This ticket: replaces only its durable assignee.' : 'This ticket: replaces only this failed named reviewer. Other reviewers, roles and user approval remain required.'}</p>
          {fleetScope ? <p data-debug-id={`${prefix}-affected`}>Potentially affected ready/review tickets: {target.affected_task_ids.length}. <span className="text-muted">Already granted leases continue on their original bridge.</span></p> : null}
          <p className="text-muted">The destination must have a valid chain workspace and provider configuration. Host-local paths are never copied.</p>
          {stale ? <p role="alert">The observed placement changed or is restricted. Refresh and review the current target before applying; your selection is kept.</p> : null}
          {confirmation === signature ? (
            <div data-debug-id={`${prefix}-confirmation`} className="space-y-2 border-t border-subtle pt-2">
              <p>Apply {draft.action === 'bridge' ? `bridge change to ${bridgeLabel(selectedBridge)}` : `replacement with ${candidates.find((c) => c.agentId === destination)?.name}`} for {targetName}? {fleetScope ? 'This affects the chain fleet.' : 'This affects this ticket.'}</p>
              {fleetScope ? (
                <div data-debug-id={`${prefix}-affected-list`}>
                  <p className="text-muted">{affected.isFetching ? 'Loading affected ticket titles…' : 'Potentially affected ready/review work:'}</p>
                  <ul className="list-disc pl-4">
                    {target.affected_task_ids.map((id) => {
                      const queued = (affected.data?.chain?.tasks || []).find((t: any) => (t.task_id || t.id) === id);
                      return <li key={id}><a data-debug-id={`${prefix}-affected-${id}`} href={`#/chains/${encodeURIComponent(chainId)}/tasks/${encodeURIComponent(id)}`} onClick={onOpenConfiguration} className="text-accent underline"><VaultText value={queued?.title || id} /></a></li>;
                    })}
                  </ul>
                </div>
              ) : null}
              <Button size="sm" variant="primary" data-debug-id={`${prefix}-apply`} disabled={!ready || mutation.isLoading} onClick={() => void apply()}>{mutation.isLoading ? 'Applying…' : 'Apply change'}</Button>
              <Button size="sm" variant="ghost" data-debug-id={`${prefix}-cancel`} disabled={mutation.isLoading} onClick={() => setConfirmation('')}>Keep selection</Button>
            </div>
          ) : <Button size="sm" data-debug-id={`${prefix}-review`} disabled={!ready || mutation.isLoading} onClick={() => setConfirmation(signature)}>Review change</Button>}
        </>
      ) : null}
      {error ? <p role="alert" data-debug-id={`${prefix}-error`}>{error}</p> : null}
      {error ? <a data-debug-id={`${prefix}-configuration`} href={`#/chains/${encodeURIComponent(chainId)}`} onClick={onOpenConfiguration} className="text-accent underline">Open chain workspace and runtime configuration</a> : null}
      {notice ? <p role="status">{notice}</p> : null}
      {fleetOpen ? <FleetManagementDrawer chainId={chainId} isOpen onClose={() => setFleetOpen(false)} focusRole={f.role === 'named' ? 'reviewer' : f.role} /> : null}
    </section>
  );
}
