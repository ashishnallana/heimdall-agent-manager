// Shared building blocks for the Memory surface (MemoryListPage / MemoryViewPage /
// MemoryFormPage). Memory targeting is a LIST per dimension (T1 contract):
// agent_ids / project_ids / bridge_ids / template_ids, where an EMPTY list means
// "applies to all" for that dimension. The TS API exposes these as camelCase
// string[] (agentIds/projectIds/bridgeIds/templateIds); this module centralises
// the dimension metadata, the option catalogs, and the read-only scope chips so
// the page, detail, and proposal surfaces all render targeting consistently.

import { useMemo } from 'react';
import { Combobox, type ComboboxOption } from '@ui';
import {
  useListAgentIdentitiesQuery,
  useListAgentTemplatesQuery,
} from '../../../api/endpoints/agents';
import { useListSidebarProjectsQuery } from '../../../api/endpoints/sidebar';
import { useListBridgesQuery } from '../../../api/endpoints/bridgeSupport';
import { containsVaultArmored, maskVaultArmored } from '../../../utils/vaultContent';

/**
 * REQ-CACHE-1: project names are vault-armored (`encryptProjectFields` at
 * `vaultProjects.ts:23`), and `useListSidebarProjectsQuery` decrypts them inside
 * its `queryFn` only when the vault was already unlocked at FETCH time
 * (`sidebar.ts:238-242`). While locked, the catalog therefore receives
 * `vault:v2:...` strings. The catalog is the choke point for every scope control
 * -- the chips, their `aria-label`s, the comboboxes and the `byId` lookups all
 * read these names -- so the armored form is masked HERE rather than at each
 * render site, which is the per-site inconsistency this bug class came from.
 *
 * Masking, not decrypting: the catalog feeds plain strings into option lists and
 * `aria-label`s, where a React decrypt hook cannot go. The decrypted form arrives
 * via the query itself, which `vaultCacheInvalidationMiddleware` now refetches on
 * the unlock transition.
 *
 * Only the project dimension needs this. Agent, bridge and template names are not
 * vault-bearing -- there is no `encryptVaultText` call for any of them.
 */
function maskArmoredName(name: string): string {
  return containsVaultArmored(name) ? maskVaultArmored(name) : name;
}

// Targeting is a fully-populated shape internally (each dimension is always an
// array; empty = all). Components spread this straight into the memory API.
export type Targeting = {
  agentIds: string[];
  projectIds: string[];
  bridgeIds: string[];
  templateIds: string[];
};

export type ScopeDimKey = keyof Targeting;

// Presentation metadata for each targeting dimension. Order matches the mock:
// Projects / Agents / Bridges / Templates. Chip colors are full Tailwind class
// strings (Tailwind can't compose class names at runtime) so each dimension is
// visually distinguishable when scanning mixed scope lists.
export const SCOPE_DIMS: {
  key: ScopeDimKey;
  label: string;
  allLabel: string;
  debug: string;
  chip: string;
}[] = [
  { key: 'projectIds', label: 'Projects', allLabel: 'All projects', debug: 'project', chip: 'border-success/30 bg-success-soft text-success' },
  { key: 'agentIds', label: 'Agents', allLabel: 'All agents', debug: 'agent', chip: 'border-accent/30 bg-accent/10 text-accent' },
  { key: 'bridgeIds', label: 'Bridges', allLabel: 'All bridges', debug: 'bridge', chip: 'border-info/30 bg-info-soft text-info' },
  { key: 'templateIds', label: 'Templates', allLabel: 'All templates', debug: 'template', chip: 'border-warning/30 bg-warning-soft text-warning' },
];

export const MEMORY_TYPES = ['fact', 'habit', 'episode', 'expertise', 'skill'];

export function emptyTargeting(): Targeting {
  return { agentIds: [], projectIds: [], bridgeIds: [], templateIds: [] };
}

// Pull the targeting lists off a normalized memory record (memoryCatalog already
// exposes agentIds/projectIds/bridgeIds/templateIds as arrays).
// TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
export function targetingFromRecord(record: any): Targeting {
  // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
  const list = (value: any) => (Array.isArray(value) ? value.map((v: any) => String(v || '').trim()).filter(Boolean) : []);
  return {
    agentIds: list(record?.agentIds),
    projectIds: list(record?.projectIds),
    bridgeIds: list(record?.bridgeIds),
    templateIds: list(record?.templateIds),
  };
}

// A catalog is in exactly ONE of three states, and they are three different facts:
// still loading, loaded and genuinely empty ("you own no bridges"), or failed to
// load ("we could not fetch it"). Rendering all three as an empty list is what made
// a hub with zero bridges look like a broken selector.
export type ScopeCatalogEntry = {
  options: ComboboxOption[];
  loading: boolean;
  /** The request failed. Never the same as "there are none". */
  failed: boolean;
  /** Re-run the failed request. */
  retry: () => void;
  byId: Map<string, string>;
};

export type ScopeCatalog = Record<ScopeDimKey, ScopeCatalogEntry>;

function toEntry(
  rows: { id: string; name: string; subtitle?: string }[],
  loading: boolean,
  failed: boolean,
  retry: () => void,
): ScopeCatalogEntry {
  const options = rows.map((row) => ({ value: row.id, title: row.name, subtitle: row.subtitle, id: row.id }));
  const byId = new Map(rows.map((row) => [row.id, row.name]));
  return { options, loading, failed, retry, byId };
}

/**
 * The one place the three states become words. `noun` is the dimension's plural in
 * lower case ("bridges"), so every dimension says the same thing about itself.
 */
export function scopeCatalogState(entry: ScopeCatalogEntry, noun: string): {
  kind: 'loading' | 'failed' | 'empty' | 'ready';
  message: string;
} {
  if (entry.loading) return { kind: 'loading', message: `Loading ${noun}…` };
  if (entry.failed) return { kind: 'failed', message: `Couldn't load ${noun}.` };
  if (entry.options.length === 0) return { kind: 'empty', message: `No ${noun} available.` };
  return { kind: 'ready', message: '' };
}

// useMemoryScopeCatalog loads the four option catalogs (agents/projects/bridges/
// templates) used by every scope control on the Memory surface. It mirrors the
// normalization the previous MemoryScopeSelector used, but exposes reusable
// ComboboxOption lists + id→name lookups keyed by targeting dimension.
export function useMemoryScopeCatalog(): ScopeCatalog {
  const identitiesQuery = useListAgentIdentitiesQuery();
  const projectsQuery = useListSidebarProjectsQuery();
  const bridgesQuery = useListBridgesQuery();
  const templatesQuery = useListAgentTemplatesQuery();

  const agents = useMemo(() => {
    const raw = identitiesQuery.data?.agents;
    const list = Array.isArray(raw) ? raw : Array.isArray(identitiesQuery.data) ? (identitiesQuery.data as any[]) : [];
    return list
      // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
      // TODO(FIX): Replace loose fallback chain with canonical typed schema property
      .map((item: any) => ({ id: String(item.agent_id || item.agentId || item.id || ''), name: String(item.name || item.slug || item.agent_id || item.agentId || 'Unnamed agent') }))
      .filter((item) => Boolean(item.id));
  }, [identitiesQuery.data]);

  const projects = useMemo(() => {
    const list = Array.isArray(projectsQuery.data) ? projectsQuery.data : [];
    return list
      // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
      // TODO(FIX): Replace loose fallback chain with canonical typed schema property
      .map((item: any) => ({ id: String(item.projectId || item.project_id || item.id || ''), name: maskArmoredName(String(item.name || item.title || item.projectId || 'Unnamed project')) }))
      .filter((item) => Boolean(item.id));
  }, [projectsQuery.data]);

  const bridges = useMemo(() => {
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    const raw = (bridgesQuery.data as any)?.bridges || bridgesQuery.data || [];
    const list = Array.isArray(raw) ? raw : [];
    return list
      // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
      // TODO(FIX): Replace loose fallback chain with canonical typed schema property
      .map((item: any) => ({ id: String(item.bridge_id || item.bridgeId || item.id || ''), name: String(item.name || item.label || item.bridge_id || item.bridgeId || 'Unnamed bridge') }))
      .filter((item) => Boolean(item.id));
  }, [bridgesQuery.data]);

  const templates = useMemo(() => {
    // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
    const raw = (templatesQuery.data as any)?.templates || templatesQuery.data || [];
    const list = Array.isArray(raw) ? raw : [];
    return list
      // TODO(FIX): Replace any with strict TypeScript interface matching Odin backend schema
      // TODO(FIX): Replace loose fallback chain with canonical typed schema property
      .map((item: any) => ({ id: String(item.template_id || item.templateId || item.id || ''), name: String(item.name || item.title || item.template_id || 'Unnamed template') }))
      .filter((item) => Boolean(item.id));
  }, [templatesQuery.data]);

  return {
    agentIds: toEntry(agents, identitiesQuery.isLoading, Boolean(identitiesQuery.isError), () => { void identitiesQuery.refetch(); }),
    projectIds: toEntry(projects, projectsQuery.isLoading, Boolean(projectsQuery.isError), () => { void projectsQuery.refetch(); }),
    bridgeIds: toEntry(bridges, bridgesQuery.isLoading, Boolean(bridgesQuery.isError), () => { void bridgesQuery.refetch(); }),
    templateIds: toEntry(templates, templatesQuery.isLoading, Boolean(templatesQuery.isError), () => { void templatesQuery.refetch(); }),
  };
}

/**
 * ScopeCatalogNote — the visible half of the three states, next to the control.
 *
 * The popup's `emptyLabel` only speaks once a user has opened it; this says the same
 * thing on the page, which is the part that was missing when a hub with zero bridges
 * rendered an empty list that read as "broken". A FAILED catalog offers the retry; an
 * empty one does not, because there is nothing to retry.
 *
 * Any surface building its own scope grid should render this under each control — it
 * is why the wording lives here rather than in `ScopeEditor`.
 */
export function ScopeCatalogNote({ entry, noun, debugId }: { entry: ScopeCatalogEntry; noun: string; debugId: string }) {
  const state = scopeCatalogState(entry, noun);
  if (state.kind === 'ready') return null;
  return (
    <div data-debug-id={debugId} className="mt-1 flex items-center gap-2">
      <span className={`text-caption ${state.kind === 'failed' ? 'text-danger' : 'text-muted'}`}>{state.message}</span>
      {state.kind === 'failed' ? (
        <button
          type="button"
          onClick={entry.retry}
          data-debug-id={`${debugId}-retry`}
          className="rounded-[var(--radius-sm)] text-caption font-medium text-accent underline focus-visible:shadow-focus focus-visible:outline-none"
        >
          Retry
        </button>
      ) : null}
    </div>
  );
}

/** The popup's wording for a catalog that is loading, empty or failed. */
export function scopeCatalogEmptyLabel(entry: ScopeCatalogEntry, noun: string): string {
  const state = scopeCatalogState(entry, noun);
  return state.kind === 'ready' ? 'No matches.' : state.message;
}

// ScopeChips renders a memory's targeting as read-only chips. Ids resolve to human
// names via the catalog when available, falling back to the raw id.
//
// Two variants, because a list row and a record page are asking different questions:
//
//   'full'    — one chip per dimension per id, with an explicit "All projects" /
//               "All agents" chip for each empty dimension. The record page, where
//               the question is "what exactly does this apply to?".
//   'compact' — the default, for a list row. A memory narrowed by NOTHING is a
//               single **Global** chip; a narrowed memory shows only the chips that
//               NARROW it, followed by one muted "all other scopes" chip (titled
//               with which ones). Four near-identical "All …" chips on every row
//               cost three lines of row height to say nothing distinguishing.
//
// The empty=applies-to-all meaning survives in both: "Global" and "all other scopes"
// both read as deliberate statements, which a blank cell would not.
export type ScopeChipsVariant = 'compact' | 'full';

export function ScopeChips({ targeting, catalog, debugId, max, variant = 'compact' }: { targeting: Targeting; catalog: ScopeCatalog; debugId: string; max?: number; variant?: ScopeChipsVariant }) {
  const narrowed = SCOPE_DIMS.filter((dim) => targeting[dim.key].length > 0);
  const unnarrowed = SCOPE_DIMS.filter((dim) => targeting[dim.key].length === 0);

  const idChips = (dims: typeof SCOPE_DIMS) =>
    dims.flatMap((dim) =>
      targeting[dim.key].map((id) => ({
        key: `${dim.key}-${id}`,
        debugId: `${debugId}-${dim.debug}-${id}`,
        title: `${dim.label}: ${id}`,
        label: catalog[dim.key].byId.get(id) || id,
        className: dim.chip,
      })),
    );

  let chips: { key: string; debugId: string; title: string; label: string; className: string }[];

  if (variant === 'full') {
    // Record-page rendering: every dimension states itself, narrowed or not.
    chips = SCOPE_DIMS.flatMap((dim) =>
      targeting[dim.key].length === 0
        ? [{
            key: dim.key,
            debugId: `${debugId}-${dim.debug}-all`,
            title: dim.allLabel,
            label: dim.allLabel,
            className: 'border-subtle bg-neutral-soft text-muted',
          }]
        : idChips([dim]),
    );
  } else if (narrowed.length === 0) {
    // Narrowed by nothing at all: one chip, and it says so.
    chips = [{
      key: 'global',
      debugId: `${debugId}-global`,
      title: 'Applies to all projects, agents, bridges and templates',
      label: 'Global',
      className: 'border-subtle bg-neutral-soft text-muted',
    }];
  } else {
    chips = idChips(narrowed);
    if (unnarrowed.length > 0) {
      chips.push({
        key: 'all-other',
        debugId: `${debugId}-all-other`,
        title: `Applies to all ${unnarrowed.map((dim) => dim.label.toLowerCase()).join(', ')}`,
        label: 'all other scopes',
        className: 'border-subtle bg-neutral-soft text-muted',
      });
    }
  }

  // `max` caps the run in a narrow container (a list cell, a card line) with a
  // "+N" rather than letting the chips wrap the row to three lines.
  const shown = typeof max === 'number' && max > 0 ? chips.slice(0, max) : chips;
  const overflow = chips.length - shown.length;

  return (
    // Compact stays on ONE line — a chip run that wraps puts the row height straight
    // back, which is what the compact variant exists to prevent. `full` wraps, since
    // the record page has the width to spend.
    <div
      data-debug-id={debugId}
      className={
        variant === 'full'
          ? 'flex flex-wrap items-center gap-1.5'
          : 'flex min-w-0 flex-nowrap items-center gap-1.5 overflow-hidden'
      }
    >
      {shown.map((chip) => (
        <span key={chip.key} title={chip.title} data-debug-id={chip.debugId} className={`inline-flex shrink-0 items-center whitespace-nowrap rounded-full border px-2 py-0.5 text-caption ${chip.className}`}>
          {chip.label}
        </span>
      ))}
      {overflow > 0 ? (
        <span data-debug-id={`${debugId}-overflow`} title={chips.slice(shown.length).map((chip) => chip.label).join(', ')} className="shrink-0 whitespace-nowrap text-caption text-muted">
          +{overflow}
        </span>
      ) : null}
    </div>
  );
}

// ScopeEditor renders the four targeting dimensions as multi-select Combobox
// controls (empty = all). Shared by the create modal, proposal review, and the
// detail edit surface so scope editing behaves identically everywhere.
export function ScopeEditor({ targeting, catalog, onChange, debugId, disabled = false }: { targeting: Targeting; catalog: ScopeCatalog; onChange: (next: Targeting) => void; debugId: string; disabled?: boolean }) {
  return (
    <div data-debug-id={debugId} className="grid gap-4 sm:grid-cols-2">
      {SCOPE_DIMS.map((dim) => {
        const entry = catalog[dim.key];
        const noun = dim.label.toLowerCase();
        const state = scopeCatalogState(entry, noun);
        return (
          <div key={dim.key} className="block">
            <div className="mb-1 text-label font-medium text-muted">{dim.label}</div>
            <Combobox
              multiple
              options={entry.options}
              value={targeting[dim.key]}
              onChange={(next) => onChange({ ...targeting, [dim.key]: next })}
              debugId={`${debugId}-${dim.debug}`}
              placeholder={dim.allLabel}
              chipClassName={dim.chip}
              loading={entry.loading}
              // The popup says which of the three states it is in, rather than
              // showing an empty list that reads as "broken" whatever the cause.
              emptyLabel={scopeCatalogEmptyLabel(entry, noun)}
              disabled={disabled || state.kind === 'failed'}
              searchPlaceholder={`Search ${noun}…`}
            />
            <ScopeCatalogNote entry={entry} noun={noun} debugId={`${debugId}-${dim.debug}-state`} />
          </div>
        );
      })}
    </div>
  );
}

/** EL-023: the unified scope selector, named for the design system. `ScopeField` === `ScopeEditor`. */
export { ScopeEditor as ScopeField };
