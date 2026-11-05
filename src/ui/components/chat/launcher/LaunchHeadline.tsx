/**
 * LaunchHeadline — the new conversation page's sentence headline and the meta
 * line under it (spec §3.1).
 *
 *   Start a new [mode] in [project] on [bridge]
 *
 *  - One of three templates (`spin` / `going` / `start`) is picked at random per
 *    mount with `useState(() => …)` and never re-picked on re-render. Every
 *    template keeps the order mode -> project -> bridge, so the controls never move.
 *  - The default-conversations project reads "without a project" (the
 *    ProjectMenu token label), and the template drops its "in".
 *  - The `on [bridge]` clause only shows when the user has more than one usable
 *    (non-revoked) bridge and at least one of them is online.
 *  - Meta line: with a project, `bridge:default_path` and the branch in mono 12px,
 *    omitting what is unknown; without one, a one-line hint.
 *
 * Presentational: the page passes its data and its existing handlers
 * (`setPaneMode`, `chooseProject`, `chooseRuntime`); the tokens are the T4 menus.
 */
import React, { useMemo, useState } from 'react';
import { Icon, Text } from '@ui';
import { composerBridgeIsOnline, composerBridgeOptions } from '../../../utils/composerBridgeOptions';
import type { RuntimeSelection } from '../RuntimeConfigurationOptions';
import { BridgeMenu, bridgeDisplayName } from './BridgeMenu';
import { ModeMenu, type LauncherMode } from './ModeMenu';
import { ProjectMenu, isDefaultConversationProject, type LauncherProject } from './ProjectMenu';

export const HEADLINE_TEMPLATE_IDS = ['spin', 'going', 'start'] as const;
export type HeadlineTemplateId = (typeof HEADLINE_TEMPLATE_IDS)[number];

export const NO_PROJECT_META = 'Not tied to a repo. Pick a project above to work in its code.';

/** A headline piece: connector text, or the slot a token goes in. */
export type HeadlineSegment = string | { slot: 'mode' | 'project' | 'bridge' };

type TemplateParts = { lead: string; afterMode: string };

/**
 * `lead` comes before the mode token; `afterMode` sits between the mode and the
 * project token ("in", "going in"). With no project the trailing "in" is dropped,
 * because the token itself reads "without a project".
 */
const TEMPLATES: Record<HeadlineTemplateId, TemplateParts> = {
  spin: { lead: 'Spin up a', afterMode: 'in' },
  going: { lead: "Let's get a", afterMode: 'going in' },
  start: { lead: 'Start a new', afterMode: 'in' },
};

export function pickHeadlineTemplate(random: () => number = Math.random): HeadlineTemplateId {
  const index = Math.min(HEADLINE_TEMPLATE_IDS.length - 1, Math.max(0, Math.floor(random() * HEADLINE_TEMPLATE_IDS.length)));
  return HEADLINE_TEMPLATE_IDS[index];
}

/** The ordered headline pieces for a template (spec §3.1 table). */
export function headlineSegments(template: HeadlineTemplateId, opts: { hasProject: boolean; showBridge: boolean }): HeadlineSegment[] {
  const { lead, afterMode } = TEMPLATES[template];
  const between = opts.hasProject ? afterMode : afterMode.replace(/\s*\bin$/, '');
  const segments: HeadlineSegment[] = [lead, { slot: 'mode' }];
  if (between) segments.push(between);
  segments.push({ slot: 'project' });
  if (opts.showBridge) segments.push('on', { slot: 'bridge' });
  return segments;
}

/** The `on [bridge]` clause: more than one non-revoked bridge, and at least one online. */
export function shouldShowBridgeClause(bridges: ReadonlyArray<any> | null | undefined): boolean {
  const usable = composerBridgeOptions(bridges as any[]);
  return usable.length > 1 && usable.some(({ bridge }) => composerBridgeIsOnline(bridge));
}

export type HeadlineMeta =
  | { kind: 'none' }
  | { kind: 'project'; location: string; branch: string };

/**
 * What the meta line shows. With a (non-default) project: `bridge:path` (or just
 * the path when no bridge is chosen) and the branch; unknown items are ''. When
 * both are unknown there is no line at all (`location` and `branch` both '').
 */
export function headlineMeta(project: LauncherProject | null | undefined, bridge: any, branch?: string | null): HeadlineMeta {
  if (!project || isDefaultConversationProject(project)) return { kind: 'none' };
  const path = project.default_path?.trim() || '';
  const bridgeName = bridge ? bridgeDisplayName(bridge, '') : '';
  const location = path ? (bridgeName ? `${bridgeName}:${path}` : path) : '';
  return { kind: 'project', location, branch: String(branch || '').trim() };
}

export type LaunchHeadlineMenu = 'mode' | 'project' | 'bridge';

export interface LaunchHeadlineProps {
  mode: LauncherMode;
  onModeChange: (mode: LauncherMode) => void;
  projects: ReadonlyArray<LauncherProject>;
  projectId: string;
  /** The page's existing `chooseProject`. */
  onProjectChange: (projectId: string) => void;
  /** Opens the page's New project modal (ProjectMenu footer). */
  onNewProject?: () => void;
  newProjectDisabled?: boolean;
  bridges: ReadonlyArray<any>;
  runtime: RuntimeSelection;
  /** The page's existing `chooseRuntime`. */
  onRuntimeChange: (next: RuntimeSelection) => void;
  requireReconfiguration?: boolean;
  /** The project's current branch, when the page knows it. */
  branch?: string | null;
  /** Force a template (tests, previews). Default: random per mount. */
  template?: HeadlineTemplateId;
  disabled?: boolean;
  /** Which token menu is open, for page layout that reacts to it (e.g. the mobile dock). */
  onMenuOpenChange?: (menu: LaunchHeadlineMenu | null) => void;
}

export function LaunchHeadline({
  mode,
  onModeChange,
  projects,
  projectId,
  onProjectChange,
  onNewProject,
  newProjectDisabled,
  bridges,
  runtime,
  onRuntimeChange,
  requireReconfiguration,
  branch,
  template,
  disabled,
  onMenuOpenChange,
}: LaunchHeadlineProps) {
  const [pickedTemplate] = useState<HeadlineTemplateId>(() => pickHeadlineTemplate());
  const templateId = template ?? pickedTemplate;
  const [openMenu, setOpenMenuState] = useState<LaunchHeadlineMenu | null>(null);
  const setOpenMenu = (menu: LaunchHeadlineMenu, open: boolean) => {
    const next = open ? menu : openMenu === menu ? null : openMenu;
    if (next === openMenu) return;
    setOpenMenuState(next);
    onMenuOpenChange?.(next);
  };

  const project = useMemo(
    () => projects.find((candidate) => candidate?.project_id === projectId && candidate.state === 'active') ?? null,
    [projects, projectId],
  );
  const hasProject = !isDefaultConversationProject(project);
  const showBridge = useMemo(() => shouldShowBridgeClause(bridges), [bridges]);
  const bridge = useMemo(
    () => (runtime.bridgeId ? composerBridgeOptions(bridges as any[]).find((option) => option.id === runtime.bridgeId)?.bridge : undefined),
    [bridges, runtime.bridgeId],
  );
  const meta = headlineMeta(project, bridge, branch);
  const segments = headlineSegments(templateId, { hasProject, showBridge });

  const token = (slot: LaunchHeadlineMenu) => {
    if (slot === 'mode') {
      return <ModeMenu value={mode} onChange={onModeChange} disabled={disabled} open={openMenu === 'mode'} onOpenChange={(open) => setOpenMenu('mode', open)} />;
    }
    if (slot === 'project') {
      return (
        <ProjectMenu
          projects={projects}
          value={projectId}
          onChange={onProjectChange}
          onNewProject={onNewProject}
          newProjectDisabled={newProjectDisabled}
          disabled={disabled}
          open={openMenu === 'project'}
          onOpenChange={(open) => setOpenMenu('project', open)}
        />
      );
    }
    return (
      <BridgeMenu
        bridges={bridges}
        runtime={runtime}
        onChange={onRuntimeChange}
        requireReconfiguration={requireReconfiguration}
        disabled={disabled}
        open={openMenu === 'bridge'}
        onOpenChange={(open) => setOpenMenu('bridge', open)}
      />
    );
  };

  const slotNode = (slot: LaunchHeadlineMenu) => (
    // Never wider than the line: below md a long value truncates next to its chevron.
    <span className="relative inline-block min-w-0 max-w-full" data-headline-slot={slot}>
      {token(slot)}
    </span>
  );

  return (
    <div className="flex flex-col gap-3" data-headline-template={templateId}>
      <Text as="h1" role="headline" tone="muted" data-debug-id="new-convo-headline" className="m-0 max-md:[text-wrap:balance]">
        {segments.map((segment, index) => {
          // One space between every pair of pieces, so the sentence reads and wraps naturally.
          const space = index > 0 ? ' ' : null;
          if (typeof segment !== 'string') {
            // A token after a connector is rendered with that connector (below).
            if (typeof segments[index - 1] === 'string') return null;
            return <React.Fragment key={segment.slot}>{space}{slotNode(segment.slot)}</React.Fragment>;
          }
          const next = segments[index + 1];
          if (next === undefined || typeof next === 'string') return <React.Fragment key={`t${index}`}>{space}{segment}</React.Fragment>;
          // Keep the connector's last word with the token after it ("going [project]"), so
          // a wrap never leaves that word alone at the end of a line.
          const cut = segment.lastIndexOf(' ');
          return (
            <React.Fragment key={`t${index}`}>
              {space}
              {cut >= 0 ? `${segment.slice(0, cut)} ` : null}
              {/* Below md a flex row (the space is dropped there, hence the gap), so the
                  token shrinks to fit the line beside the word. */}
              <span
                className="whitespace-nowrap max-md:inline-flex max-md:max-w-full max-md:items-baseline max-md:gap-x-[0.25em]"
                data-headline-group={next.slot}
              >
                <span className="shrink-0">{segment.slice(cut + 1)}</span> {slotNode(next.slot)}
              </span>
            </React.Fragment>
          );
        })}
      </Text>
      {meta.kind === 'none' ? (
        <Text role="body-sm" tone="muted" className="m-0" data-debug-id="new-convo-meta">
          {NO_PROJECT_META}
        </Text>
      ) : meta.location || meta.branch ? (
        <div className="flex flex-wrap items-center gap-x-4 gap-y-2" data-debug-id="new-convo-meta">
          {/* Each item stays on one line and truncates; the title carries the full text. */}
          {meta.location ? (
            <Text role="code-sm" tone="muted" as="span" title={meta.location} className="inline-flex min-w-0 max-w-full items-center gap-1.5" data-meta-item="location">
              <Icon name="folder" size="sm" className="shrink-0" />
              <span className="min-w-0 truncate">{meta.location}</span>
            </Text>
          ) : null}
          {meta.branch ? (
            <Text role="code-sm" tone="muted" as="span" title={meta.branch} className="inline-flex min-w-0 max-w-full items-center gap-1.5" data-meta-item="branch">
              <Icon name="git-branch" size="sm" className="shrink-0" />
              <span className="min-w-0 truncate">{meta.branch}</span>
            </Text>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}

export default LaunchHeadline;
