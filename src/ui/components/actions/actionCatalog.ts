/**
 * actionCatalog — resolving an action's target ids to names, once.
 * ------------------------------------------------------------------
 * An action on the wire is all foreign keys: `target_instance_id`,
 * `target_agent_id`, `target_bridge_id`, `target_project_id`. None of them is a
 * name, and `GET /api/v1/actions` does not expand any of them. Every surface that
 * shows an action — the row, the filter drawer, the detail cards, the form —
 * needs the same four lookups, so they live here rather than four times over.
 *
 * Amendment 5's rule about catalogs applies to every one of these: **loading,
 * empty and failed read differently.** "No bridges available" is not the same fact
 * as "Couldn't load bridges", and a row must degrade to the raw id rather than
 * render blank when a lookup fails.
 */
import React from 'react';
import { containsVaultArmored, maskVaultArmored } from '../../utils/vaultContent.ts';
import { buildRouteHash } from '../../utils/appLocation';
import { useListAgentIdentitiesQuery } from '../../api/endpoints/agents';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import { useListProjectsQuery } from '../../api/endpoints/projects';
import { useListAllAgentInstancesQuery } from '../../api/endpoints/actions';

/**
 * A catalog's state. `ready` is the ordinary case; the other three are Amendment 5's
 * rule that loading, empty and failed must READ DIFFERENTLY — "No bridges available"
 * is not the same fact as "Couldn't load bridges", and neither is an empty list.
 */
export type CatalogState = 'loading' | 'ready' | 'empty' | 'failed';

export interface CatalogEntry {
  id: string;
  label: string;
  sub?: string;
  keywords?: string;
  /**
   * Where this record can be opened, when a route for it exists. Absent is a real
   * answer: there is no per-bridge route in the shell's route table, so a bridge is
   * named and never linked rather than linked somewhere it does not land.
   */
  href?: string;
}

export interface CatalogSlice {
  state: CatalogState;
  byId: Map<string, CatalogEntry>;
  all: CatalogEntry[];
}

function sliceFrom(entries: CatalogEntry[], loading: boolean, failed: boolean): CatalogSlice {
  const byId = new Map<string, CatalogEntry>();
  for (const entry of entries) byId.set(entry.id, entry);
  const state: CatalogState = failed ? 'failed' : loading ? 'loading' : entries.length ? 'ready' : 'empty';
  return { state, byId, all: entries };
}

export interface ActionCatalog {
  instances: CatalogSlice;
  agents: CatalogSlice;
  bridges: CatalogSlice;
  projects: CatalogSlice;
  /** True while any of the four is still in flight. */
  loading: boolean;
}

export function useActionCatalog(): ActionCatalog {
  const instancesQuery = useListAllAgentInstancesQuery();
  const agentsQuery = useListAgentIdentitiesQuery();
  const bridgesQuery = useListBridgesQuery();
  const projectsQuery = useListProjectsQuery();

  const instances = React.useMemo(() => {
    const rows = (instancesQuery.data?.instances || []) as any[];
    const entries = rows
      .map((inst) => {
        const id = String(inst?.agent_instance_id || inst?.agentInstanceId || inst?.id || '');
        const label = String(
          inst?.display_name || inst?.displayName || inst?.agent_name || inst?.agentName || id,
        );
        const status = String(inst?.runtime_status || inst?.runtimeStatus || '');
        // An instance has no route of its own; its CHAIN does, and that is where the
        // instance's conversation lives. No chain on the record -> no link.
        const chainId = String(inst?.chain_id || inst?.chainId || '');
        return {
          id,
          label,
          sub: status,
          keywords: [id, label, status].filter(Boolean).join(' '),
          href: chainId ? buildRouteHash(`/chains/${encodeURIComponent(chainId)}`, '') : undefined,
        };
      })
      .filter((entry) => Boolean(entry.id))
      .sort((l, r) => l.label.localeCompare(r.label));
    return sliceFrom(entries, instancesQuery.isLoading, Boolean(instancesQuery.error));
  }, [instancesQuery.data, instancesQuery.isLoading, instancesQuery.error]);

  const agents = React.useMemo(() => {
    const rows = (agentsQuery.data?.agents || []) as any[];
    const entries = rows
      .map((agent) => {
        // The /agents serializer emits `agent_id` (no `id`); fall back for safety.
        const id = String(agent?.agent_id || agent?.agentId || agent?.id || '');
        const label = String(agent?.name || agent?.slug || id);
        return {
          id,
          label,
          sub: String(agent?.template_id || agent?.templateId || ''),
          keywords: [id, label, String(agent?.slug || '')].filter(Boolean).join(' '),
          href: buildRouteHash(`/agents/${encodeURIComponent(id)}`, ''),
        };
      })
      .filter((entry) => Boolean(entry.id))
      .sort((l, r) => l.label.localeCompare(r.label));
    return sliceFrom(entries, agentsQuery.isLoading, Boolean(agentsQuery.error));
  }, [agentsQuery.data, agentsQuery.isLoading, agentsQuery.error]);

  const bridges = React.useMemo(() => {
    const rows = (bridgesQuery.data?.bridges || []) as any[];
    const entries = rows
      // The /bridges serializer emits `bridge_id` / `label` / `machine_hostname` and a
      // `status` of online|offline|revoked. A revoked bridge cannot accept a run, so it
      // is not offered as a target — but it is still RESOLVED, because an existing
      // action may already point at one and the row must name it rather than blank out.
      .map((bridge) => {
        const id = String(bridge?.bridge_id || bridge?.bridgeId || bridge?.id || '');
        const label = String(bridge?.label || bridge?.machine_hostname || id);
        const status = String(bridge?.status || '');
        return {
          id,
          label,
          sub: status,
          keywords: [id, label, String(bridge?.machine_hostname || '')].filter(Boolean).join(' '),
        };
      })
      .filter((entry) => Boolean(entry.id))
      .sort((l, r) => l.label.localeCompare(r.label));
    return sliceFrom(entries, bridgesQuery.isLoading, Boolean(bridgesQuery.error));
  }, [bridgesQuery.data, bridgesQuery.isLoading, bridgesQuery.error]);

  const projects = React.useMemo(() => {
    const rows = (projectsQuery.data?.projects || []) as any[];
    const entries = rows
      .map((project) => {
        const id = String(project?.project_id || project?.projectId || project?.id || '');
        // REQ-CACHE-1: project names are vault-armored (`encryptProjectFields` at
        // `vaultProjects.ts:23`) and the projects query decrypts them inside its
        // `queryFn` only when the vault was already unlocked at FETCH time, so while
        // locked this catalog receives `vault:v2:...` strings. Masked HERE because
        // every consumer funnels through `projectLabel` below and `keywords` is derived
        // from the same string -- so one line covers all five consumers and keeps
        // armored text out of the searchable index too. Masking, not decrypting: these
        // strings go into option lists, `aria-label`s and a search haystack, where a
        // React decrypt hook cannot go; the decrypted form arrives on the refetch that
        // `vaultCacheInvalidationMiddleware` triggers on the unlock transition.
        // Project is the only armored dimension -- agent, bridge and instance names
        // have no `encryptVaultText` path.
        const rawName = String(project?.name || id);
        const label = containsVaultArmored(rawName) ? maskVaultArmored(rawName) : rawName;
        return {
          id,
          label,
          keywords: [id, label].filter(Boolean).join(' '),
          href: buildRouteHash(`/projects/${encodeURIComponent(id)}`, ''),
        };
      })
      .filter((entry) => Boolean(entry.id))
      .sort((l, r) => l.label.localeCompare(r.label));
    return sliceFrom(entries, projectsQuery.isLoading, Boolean(projectsQuery.error));
  }, [projectsQuery.data, projectsQuery.isLoading, projectsQuery.error]);

  return React.useMemo(
    () => ({
      instances,
      agents,
      bridges,
      projects,
      loading:
        instances.state === 'loading' ||
        agents.state === 'loading' ||
        bridges.state === 'loading' ||
        projects.state === 'loading',
    }),
    [instances, agents, bridges, projects],
  );
}

/**
 * The target's human name. Falls back to the raw id — never to blank, so a failed
 * or still-loading catalog degrades to something the user can at least copy.
 */
export function targetLabel(
  record: { target_instance_id?: string; target_agent_id?: string },
  catalog: ActionCatalog,
): string {
  const instanceId = String(record.target_instance_id || '').trim();
  if (instanceId) return catalog.instances.byId.get(instanceId)?.label || instanceId;
  const agentId = String(record.target_agent_id || '').trim();
  if (agentId) return catalog.agents.byId.get(agentId)?.label || agentId;
  return 'No target';
}

export function bridgeLabel(bridgeId: string | undefined, catalog: ActionCatalog): string {
  const id = String(bridgeId || '').trim();
  if (!id) return '';
  return catalog.bridges.byId.get(id)?.label || id;
}

export function projectLabel(projectId: string | undefined, catalog: ActionCatalog): string {
  const id = String(projectId || '').trim();
  if (!id) return '';
  return catalog.projects.byId.get(id)?.label || id;
}

/** The wording for a catalog that is loading, empty or failed. */
export function catalogNote(state: CatalogState, plural: string): string {
  if (state === 'loading') return `Loading ${plural}…`;
  if (state === 'failed') return `Couldn't load ${plural}.`;
  if (state === 'empty') return `No ${plural} available.`;
  return '';
}
