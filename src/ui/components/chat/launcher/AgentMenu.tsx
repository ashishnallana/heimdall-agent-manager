/**
 * AgentMenu — the composer's agent chip and its favorites menu.
 * ------------------------------------------------------------------
 * Spec §3.3 "Agent menu", motion §4 #9 (a star `pop`s as it turns on) and #10
 * (list <-> edit cross-fades in place and the popover height transitions).
 *
 * List view (a `role="menu"`): "Favorite agents" with `{n} / 6`, the favorites
 * (name + workflow label) as `menuitemradio` rows, a separator, "Edit favorites".
 *
 * Edit view (the same popover; no modal). It holds a search field, toggle buttons
 * and a form, which are not menu items, so the popup switches to `@ui` Menu's
 * `mode="dialog"` (Tab moves between controls; Esc / outside click still close):
 *   - header "Edit favorites", `{n} / 6`, "Done" (back to the list);
 *   - search "Find an agent by name or ID";
 *   - rows: name + `agent_id` in mono + a star `IconButton` (`aria-pressed`);
 *   - pinned agents (backend `pinned_agent_ids`: Coordinator, Soloist) show
 *     "Always on" and a disabled filled star;
 *   - at 6 favorites, empty stars are disabled with the limit hint;
 *   - a collapsible "Create a favorite agent" form at the bottom.
 *
 * Favorites are toggled through the caller's `onToggleFavorite` (the page's
 * existing `changeFavorite`). Removing the selected agent selects the first
 * remaining favorite (`firstRemainingFavorite`).
 */
import React, { useEffect, useLayoutEffect, useRef, useState, type FormEvent } from 'react';
import { Accordion, Button, Combobox, Icon, IconButton, Input, Menu, Textarea } from '@ui';
import { VaultText } from '../../vault/VaultText';
import { isVaultArmored } from '../../../utils/vaultContent';
import { SentenceToken, prefersReducedMotion } from './SentenceToken';

export const MAX_FAVORITE_AGENTS = 6;
export const AGENT_MENU_WIDTH = 360;
export const FAVORITES_FULL_HINT = 'You have 6 favorites, the most allowed. Remove one to add another.';

export interface AgentMenuAgent {
  agent_id: string;
  name: string;
  slug?: string;
  state?: string;
}

export interface AgentMenuTemplate {
  template_id: string;
  name?: string;
}

export interface NewFavoriteAgent {
  name: string;
  templateId: string;
  instructions: string;
}

/** Result of a favorite toggle or create: `false` means it failed (the caller shows the error). */
type Outcome = boolean | void | string;

export interface AgentMenuProps {
  agents: AgentMenuAgent[];
  /** Favorite agent ids, in display order. */
  favoriteIds: string[];
  /** Agents that are always favorites (backend `pinned_agent_ids`). */
  pinnedIds: string[];
  selectedId: string;
  onSelect: (agentId: string) => void;
  /** The page's `changeFavorite`. Resolve `false` on failure so the selection is left alone. */
  onToggleFavorite: (agentId: string, favorite: boolean) => Promise<Outcome> | Outcome;
  /** A favorite write is in flight (stars are disabled). */
  toggling?: boolean;
  templates: AgentMenuTemplate[];
  /** The page's `addAgent`. Resolve `false` on failure to keep the form filled. */
  onCreateAgent: (agent: NewFavoriteAgent) => Promise<Outcome> | Outcome;
  creating?: boolean;
  /** Error from a favorite or create call, shown in the edit view. */
  error?: string;
  disabled?: boolean;
  debugPrefix?: string;
  side?: 'bottom' | 'top';
  align?: 'start' | 'end';
  /** Told whenever the menu opens or closes (the page undocks the mobile composer while a sheet is up). */
  onOpenChange?: (open: boolean) => void;
}

/** Plain-text agent name (vault-armored names are never shown as ciphertext). */
export function agentLabel(name: string, fallback: string): string {
  return isVaultArmored(name) ? 'Locked name' : name || fallback;
}

/** The workflow line under a favorite. */
export function agentWorkflowLabel(agent: Pick<AgentMenuAgent, 'slug'> | undefined): string {
  return agent?.slug === 'coordinator' ? 'Multi-agent workflow' : agent?.slug === 'soloist' ? 'Single-agent workflow' : '';
}

/** The agent to select after `removedId` stops being a favorite: the first remaining active favorite, else ''. */
export function firstRemainingFavorite(favoriteIds: string[], removedId: string, agents: AgentMenuAgent[]): string {
  const remaining = favoriteIds.filter((id) => id !== removedId);
  return remaining.find((id) => agents.find((agent) => agent.agent_id === id)?.state === 'active') || '';
}

/** Agents the edit view lists: active ones plus any favorite, matching the query by name or id. */
export function filterEditableAgents(agents: AgentMenuAgent[], favoriteIds: string[], query: string): AgentMenuAgent[] {
  const q = query.trim().toLowerCase();
  return agents.filter((agent) => {
    if (agent.state !== 'active' && !favoriteIds.includes(agent.agent_id)) return false;
    if (!q) return true;
    return agentLabel(agent.name, agent.agent_id).toLowerCase().includes(q) || agent.agent_id.toLowerCase().includes(q);
  });
}

export function AgentMenu({
  agents,
  favoriteIds,
  pinnedIds,
  selectedId,
  onSelect,
  onToggleFavorite,
  toggling = false,
  templates,
  onCreateAgent,
  creating = false,
  error,
  disabled = false,
  debugPrefix = 'new-convo',
  side = 'bottom',
  align = 'start',
  onOpenChange,
}: AgentMenuProps) {
  const [open, setOpen] = useState(false);
  const [view, setView] = useState<'list' | 'edit'>('list');
  const [query, setQuery] = useState('');
  const [createOpen, setCreateOpen] = useState<string[]>([]);
  const [name, setName] = useState('');
  const [templateId, setTemplateId] = useState('tmpl_worker');
  const [instructions, setInstructions] = useState('');

  const full = favoriteIds.length >= MAX_FAVORITE_AGENTS;
  const count = `${favoriteIds.length} / ${MAX_FAVORITE_AGENTS}`;
  const agentById = (id: string) => agents.find((agent) => agent.agent_id === id);
  const selected = agentById(selectedId);

  // Counts list <-> edit swaps since the menu opened; the swapped content only
  // cross-fades after a real swap (motion #10), never on open.
  const [swaps, setSwaps] = useState(0);

  function changeOpen(next: boolean) {
    // Every open starts on the list view with an empty search.
    if (next) {
      setView('list');
      setQuery('');
      setSwaps(0);
    }
    setOpen(next);
    onOpenChange?.(next);
  }

  async function toggle(agentId: string, favorite: boolean) {
    const outcome = await onToggleFavorite(agentId, favorite);
    if (outcome === false) return;
    if (!favorite && agentId === selectedId) {
      const next = firstRemainingFavorite(favoriteIds, agentId, agents);
      if (next) onSelect(next);
    }
  }

  async function create(event: FormEvent) {
    event.preventDefault();
    if (full || creating || !name.trim() || !templateId) return;
    const outcome = await onCreateAgent({ name: name.trim(), templateId, instructions });
    if (outcome === false) return;
    setName('');
    setInstructions('');
    setCreateOpen([]);
    // Close through changeOpen so onOpenChange hears about it (the page re-docks
    // the mobile composer on close).
    changeOpen(false);
  }

  // #10: the popover height transitions from the old view's height to the new one.
  const bodyRef = useRef<HTMLDivElement | null>(null);
  const heightBeforeSwap = useRef<number | null>(null);
  useLayoutEffect(() => {
    const el = bodyRef.current;
    const from = heightBeforeSwap.current;
    heightBeforeSwap.current = null;
    if (!el || from === null || typeof el.animate !== 'function' || prefersReducedMotion()) return;
    const to = el.getBoundingClientRect().height;
    if (from === to) return;
    el.animate([{ height: `${from}px`, overflow: 'hidden' }, { height: `${to}px`, overflow: 'hidden' }], {
      duration: 200,
      easing: 'cubic-bezier(.2,.8,.2,1)',
    });
  }, [swaps]);

  // Focus follows the swap: the search field in edit, "Edit favorites" back in the list.
  const searchRef = useRef<HTMLInputElement | null>(null);
  const editRowRef = useRef<HTMLDivElement | null>(null);
  useEffect(() => {
    if (swaps === 0) return;
    if (view === 'edit') searchRef.current?.focus();
    else editRowRef.current?.querySelector<HTMLElement>('[role="menuitem"]')?.focus();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [swaps]);
  const swapTo = (next: 'list' | 'edit') => {
    heightBeforeSwap.current = bodyRef.current?.getBoundingClientRect().height ?? null;
    if (next === 'edit') setQuery('');
    setView(next);
    setSwaps((n) => n + 1);
  };

  const fade = swaps > 0 && !prefersReducedMotion() ? 'animate-fade-in' : '';

  const listView = (
    <div key="list" className={fade}>
      <Menu.Label>
        <span>Favorite agents</span>
        <span data-debug-id={`${debugPrefix}-favorite-count`}>{count}</span>
      </Menu.Label>
      {favoriteIds.map((id) => {
        const agent = agentById(id);
        const workflow = agentWorkflowLabel(agent);
        return (
          <Menu.RadioItem
            key={id}
            checked={id === selectedId}
            disabled={!agent || agent.state !== 'active'}
            description={workflow || undefined}
            data-debug-id={`${debugPrefix}-favorite-agent-${id}`}
            onClick={() => {
              if (id !== selectedId) onSelect(id);
            }}
          >
            {agent ? <VaultText value={agent.name} fallback="Agent" /> : id}
          </Menu.RadioItem>
        );
      })}
      {favoriteIds.length === 0 ? <p className="px-2.5 py-2 text-body-sm text-muted">No favorite agents yet.</p> : null}
      <Menu.Separator />
      <div ref={editRowRef}>
        <Menu.Item
          keepOpen
          leading={<Icon name="pencil" />}
          className="text-muted"
          data-debug-id={`${debugPrefix}-edit-favorites`}
          onClick={() => swapTo('edit')}
        >
          Edit favorites
        </Menu.Item>
      </div>
    </div>
  );

  const rows = filterEditableAgents(agents, favoriteIds, query);
  const editView = (
    <div key="edit" className={fade}>
      <div className="flex items-center gap-2 py-1.5 pl-2.5 pr-1.5">
        <p className="m-0 flex-1 text-body font-semibold text-primary">Edit favorites</p>
        <span data-debug-id={`${debugPrefix}-favorite-count`} className="text-caption font-medium text-faint">{count}</span>
        <Button size="sm" variant="secondary" data-debug-id={`${debugPrefix}-edit-favorites-done`} onClick={() => swapTo('list')}>
          Done
        </Button>
      </div>
      <div className="px-1 pb-1.5">
        <label htmlFor={`${debugPrefix}-agent-search`} className="sr-only">Find an agent by name or ID</label>
        <Input
          ref={searchRef}
          id={`${debugPrefix}-agent-search`}
          type="search"
          width="full"
          value={query}
          onChange={setQuery}
          placeholder="Find an agent by name or ID"
          leading={<Icon name="search" />}
          autoComplete="off"
          data-debug-id={`${debugPrefix}-agent-search`}
        />
      </div>
      <div className="max-h-64 overflow-y-auto" data-debug-id={`${debugPrefix}-favorite-rows`}>
        {rows.map((agent) => {
          const favorite = favoriteIds.includes(agent.agent_id);
          const pinned = pinnedIds.includes(agent.agent_id);
          const text = agentLabel(agent.name, agent.agent_id);
          const action = pinned ? `${text} is always a favorite` : favorite ? `Remove ${text} from favorites` : `Add ${text} to favorites`;
          return (
            <div
              key={agent.agent_id}
              data-debug-id={`${debugPrefix}-favorite-row-${agent.agent_id}`}
              className="flex min-h-11 items-center gap-2.5 rounded-[var(--radius-md)] py-1 pl-2.5 pr-1.5"
            >
              <span className="flex min-w-0 flex-1 flex-col">
                <span className="truncate font-medium text-primary"><VaultText value={agent.name} fallback="Agent" /></span>
                <span className="truncate font-mono text-caption text-muted">{agent.agent_id}</span>
              </span>
              {pinned ? <span className="text-caption font-medium text-faint">Always on</span> : null}
              <IconButton
                size="sm"
                icon="star"
                pressedIcon="star-filled"
                pressed={favorite || pinned}
                label={action}
                disabled={pinned || toggling || disabled || (!favorite && full)}
                data-debug-id={`${debugPrefix}-favorite-toggle-${agent.agent_id}`}
                onClick={() => void toggle(agent.agent_id, !favorite)}
              />
            </div>
          );
        })}
        {rows.length === 0 ? <p className="px-2.5 py-2 text-body-sm text-muted">No agent matches that name or ID.</p> : null}
      </div>
      <p data-debug-id={`${debugPrefix}-favorite-limit`} className="m-0 px-2.5 pb-1.5 pt-2 text-caption text-muted">
        {full ? FAVORITES_FULL_HINT : 'Coordinator and Soloist are always favorites. Star others to add them here.'}
      </p>
      {error ? <p role="alert" className="m-0 px-2.5 pb-1.5 text-caption text-danger">{error}</p> : null}
      <Accordion type="single" value={createOpen} onChange={setCreateOpen} className="border-t border-subtle px-2.5">
        <Accordion.Item value="create" title="Create a favorite agent" debugId={`${debugPrefix}-create-agent-toggle`}>
          <form onSubmit={create} className="space-y-2" data-debug-id={`${debugPrefix}-create-agent-form`}>
            <label htmlFor={`${debugPrefix}-agent-name-input`} className="sr-only">Agent name</label>
            <Input
              id={`${debugPrefix}-agent-name-input`}
              width="full"
              value={name}
              onChange={setName}
              placeholder="Agent name"
              required
              data-debug-id={`${debugPrefix}-agent-name-input`}
            />
            <Combobox
              debugId={`${debugPrefix}-agent-template-select`}
              options={templates.map((t) => ({ value: t.template_id, title: agentLabel(t.name || '', t.template_id) }))}
              value={templateId}
              onChange={setTemplateId}
              placeholder="Choose template"
              width="full"
            />
            <label htmlFor={`${debugPrefix}-agent-instructions-input`} className="sr-only">Additional instructions</label>
            <Textarea
              id={`${debugPrefix}-agent-instructions-input`}
              width="full"
              rows={3}
              value={instructions}
              onChange={setInstructions}
              placeholder="Additional instructions (optional)"
              data-debug-id={`${debugPrefix}-agent-instructions-input`}
            />
            <Button
              type="submit"
              variant="primary"
              size="sm"
              loading={creating}
              disabled={full || !name.trim() || !templateId}
              data-debug-id={`${debugPrefix}-create-favorite-agent-btn`}
            >
              {creating ? 'Creating…' : 'Create and favorite'}
            </Button>
          </form>
        </Accordion.Item>
      </Accordion>
    </div>
  );

  return (
    <SentenceToken
      appearance="chip"
      value={selectedId}
      label={view === 'edit' ? 'Edit favorites' : 'Favorite agents'}
      debugId={`${debugPrefix}-agent-picker`}
      menuWidth={AGENT_MENU_WIDTH}
      menuMode={view === 'edit' ? 'dialog' : 'menu'}
      side={side}
      align={align}
      open={open}
      onOpenChange={changeOpen}
      disabled={disabled}
      leading={<Icon name="bot" size={14} className="flex-none text-muted" />}
      renderMenu={() => (
        <div ref={bodyRef} data-debug-id={`${debugPrefix}-agent-menu-${view}`} className="min-w-0">
          {view === 'list' ? listView : editView}
        </div>
      )}
    >
      {selected ? (
        <span className="truncate"><VaultText value={selected.name} fallback="Agent" /></span>
      ) : (
        <span className="text-muted">Choose agent</span>
      )}
    </SentenceToken>
  );
}

export default AgentMenu;
