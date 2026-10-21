import React, { useState } from 'react';
import { Badge, Button, IconButton, Input, Modal, ModalBody, ModalFooter, Select, Text, Textarea } from '@ui';
import {
  useDeleteChainReviewRoleMutation,
  useGetTaskChainFleetsQuery,
  useListChainReviewRolesQuery,
  useUpdateTaskChainFleetMutation,
  useUpsertChainReviewRoleMutation,
  type ChainReviewRole,
} from '../../api/endpoints/taskChains';
import { useListAgentIdentitiesQuery } from '../../api/endpoints/agents';
import { actionErrorMessage } from './useTaskActions';
import { EMPTY_TASK_NAMES, type TaskNames } from './taskNames';
import { isValidFleetRoleName } from './fleetSelection';

export interface ReviewRolesModalProps {
  chainId: string;
  open: boolean;
  onClose: () => void;
  names?: TaskNames;
}

/**
 * The chain's review roles (hybrid review model). A role is optional: templates
 * and coordinators ask for "a security review" without naming agents. Each role
 * has a description (handed to the reviewing agent) and members (agents whose
 * fleet row holds the role). People mostly name reviewer agents on the task.
 */
export const ReviewRolesModal: React.FC<ReviewRolesModalProps> = ({ chainId, open, onClose, names = EMPTY_TASK_NAMES }) => {
  const { data: roles = [] } = useListChainReviewRolesQuery({ chainId }, { skip: !open });
  const { data: fleets = [] } = useGetTaskChainFleetsQuery({ chainId }, { skip: !open });
  const { data: identitiesData } = useListAgentIdentitiesQuery(undefined, { skip: !open });
  const [upsertRole, upsertState] = useUpsertChainReviewRoleMutation();
  const [deleteRole, deleteState] = useDeleteChainReviewRoleMutation();
  const [updateFleet, fleetState] = useUpdateTaskChainFleetMutation();

  const [newName, setNewName] = useState('');
  const [newDescription, setNewDescription] = useState('');
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const [addAgent, setAddAgent] = useState<Record<string, string>>({});
  const [error, setError] = useState('');
  const busy = upsertState.isLoading || deleteState.isLoading || fleetState.isLoading;

  const agents: any[] = identitiesData?.agents || [];
  const agentName = (id: string) => names.agent(id);

  const run = async (fn: () => Promise<unknown>) => {
    setError('');
    try {
      await fn();
      return true;
    } catch (err) {
      setError(actionErrorMessage(err));
      return false;
    }
  };

  // Membership is the fleet row's role list; keep the row's other settings.
  const setMembership = (agentId: string, role: string, on: boolean) =>
    run(() => {
      const row: any = fleets.find((f: any) => String(f.agent_id) === agentId);
      const current: string[] = row?.roles || [];
      const roles = on ? Array.from(new Set([...current, role])) : current.filter((r) => r !== role);
      return updateFleet({
        chainId,
        agentId,
        capacity: row?.capacity || 1,
        minWarm: row?.min_warm,
        idleTtlSeconds: row?.idle_ttl_seconds,
        provider: row?.provider || '',
        model: row?.model || '',
        bridgeId: row?.bridge_id ?? '',
        roles: roles.length ? roles : ['named-reviewer'],
      }).unwrap();
    });

  const createRole = async () => {
    const name = newName.trim().toLowerCase();
    if (!isValidFleetRoleName(name)) {
      setError('Role names are 1-32 chars of a-z, 0-9, _ or -, starting with a letter.');
      return;
    }
    if (await run(() => upsertRole({ chainId, name, description: newDescription }).unwrap())) {
      setNewName('');
      setNewDescription('');
    }
  };

  // A render function, not a nested component: a component defined inside
  // render is a new type every render, so React remounted each row and the
  // description box lost focus after every keystroke (audit finding).
  const renderRoleRow = (role: ChainReviewRole) => {
    const draft = drafts[role.name] ?? role.description;
    const candidates = agents.filter((a) => !role.holders.includes(String(a.agent_id || a.agentId)));
    return (
      <li key={role.name} data-debug-id={`review-role-${role.name}`} className="space-y-1.5 border-t border-subtle pt-3 first:border-t-0 first:pt-0">
        <div className="flex flex-wrap items-center gap-2">
          <Text as="span" role="label">
            {role.name}
          </Text>
          {role.openTaskCount > 0 && <Badge tone="info">{role.openTaskCount} open tasks need it</Badge>}
          <span className="ml-auto" />
          <Button
            size="sm"
            variant="ghost"
            tone="danger"
            disabled={busy || role.openTaskCount > 0}
            title={role.openTaskCount > 0 ? 'Open tasks still require this role' : undefined}
            onClick={() => {
              if (window.confirm(`Delete the ${role.name} role? Agents holding it lose it.`)) void run(() => deleteRole({ chainId, name: role.name }).unwrap());
            }}
          >
            Delete
          </Button>
        </div>
        <Textarea
          value={draft}
          onChange={(v) => setDrafts((d) => ({ ...d, [role.name]: v }))}
          placeholder="What should this reviewer check? This is given to the reviewing agent."
          rows={2}
          size="sm"
          width="full"
        />
        {draft !== role.description && (
          <Button size="sm" variant="secondary" disabled={busy} onClick={() => void run(() => upsertRole({ chainId, name: role.name, description: draft }).unwrap())}>
            Save description
          </Button>
        )}
        <div className="flex flex-wrap items-center gap-1.5">
          {role.holders.length === 0 && (
            <Text role="caption" tone="warning">
              Nobody holds this role yet.
            </Text>
          )}
          {role.holders.map((agentId) => (
            <span key={agentId} className="inline-flex items-center gap-0.5 rounded-md border border-subtle px-1.5 py-0.5 text-[11px] text-primary">
              {agentName(agentId)}
              <IconButton icon="close" label={`Remove ${agentName(agentId)} from ${role.name}`} variant="ghost" size="sm" disabled={busy} onClick={() => void setMembership(agentId, role.name, false)} />
            </span>
          ))}
          {candidates.length > 0 && (
            <Select
              size="sm"
              value={addAgent[role.name] || ''}
              onChange={(v) => {
                setAddAgent((x) => ({ ...x, [role.name]: '' }));
                if (v) void setMembership(v, role.name, true);
              }}
              options={[
                { value: '', text: 'Add an agent…' },
                ...candidates.map((a) => ({ value: String(a.agent_id || a.agentId), text: String(a.name || a.display_name || agentName(a.agent_id)) })),
              ]}
              aria-label={`Add an agent to ${role.name}`}
            />
          )}
        </div>
      </li>
    );
  };

  return (
    <Modal open={open} onOpenChange={(o) => !o && onClose()} title="Review roles" size="md">
      <ModalBody className="space-y-4 text-xs">
        <Text as="p" role="caption" tone="muted">
          Optional. Name reviewer agents on each task for most work. A role asks every agent holding it to review, which
          suits templates and coordinators. Its description tells the reviewer what to check.
        </Text>
        <ul className="space-y-3">
          {roles.map(renderRoleRow)}
        </ul>
        <div className="space-y-1.5 border-t border-subtle pt-3">
          <Text as="p" role="label">
            New role
          </Text>
          <Input value={newName} onChange={setNewName} placeholder="e.g. security" size="sm" width="full" aria-label="Role name" />
          <Textarea value={newDescription} onChange={setNewDescription} placeholder="What should this reviewer check?" rows={2} size="sm" width="full" />
          <Button size="sm" variant="primary" disabled={busy || !newName.trim()} onClick={createRole}>
            Add role
          </Button>
        </div>
        {error && (
          <Text as="p" role="caption" tone="danger" className="whitespace-pre-line break-words">
            {error}
          </Text>
        )}
      </ModalBody>
      <ModalFooter>
        <Button size="sm" variant="ghost" onClick={onClose}>
          Done
        </Button>
      </ModalFooter>
    </Modal>
  );
};

export default ReviewRolesModal;
