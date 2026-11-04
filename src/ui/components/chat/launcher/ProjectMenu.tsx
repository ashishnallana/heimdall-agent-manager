/**
 * ProjectMenu — the `[project]` token of the launcher headline
 * (spec §3.1 project token, §3.3 project menu: 380px).
 *
 *  - Search "Find a project", focused on open; nothing matches -> "No project matches that name."
 *  - "No project" (the default-conversations project) is always listed first and
 *    the token reads "without a project", never "Conversation".
 *  - Then the active projects, name plus `default_path` in mono.
 *  - Footer "New project" asks the page to open its existing New project modal
 *    (`useCreateProjectMutation` stays in the page).
 *
 * Presentational: the page passes its project list, the chosen id, and its
 * existing `chooseProject` as `onChange`.
 */
import React, { useMemo } from 'react';
import { Icon, Menu } from '@ui';
import { isVaultArmored } from '../../../utils/vaultContent';
import { SentenceToken, type SentenceTokenOption } from './SentenceToken';

export const PROJECT_MENU_WIDTH = 380;
export const NO_PROJECT_LABEL = 'No project';
export const NO_PROJECT_TOKEN_LABEL = 'without a project';
export const NO_PROJECT_DESCRIPTION = 'A plain conversation, not tied to a repo';
export const PROJECT_SEARCH_PLACEHOLDER = 'Find a project';
export const PROJECT_EMPTY_TEXT = 'No project matches that name.';

export interface LauncherProject {
  project_id: string;
  name?: string;
  slug?: string;
  state?: string;
  default_path?: string;
  is_default_conversations?: boolean;
}

/** The project a plain conversation lands in (same rule the page uses to preselect). */
export function isDefaultConversationProject(project: LauncherProject | null | undefined): boolean {
  return !!project && (!!project.is_default_conversations || project.slug === 'conversation');
}

function projectName(name: string | undefined): string {
  return name && isVaultArmored(name) ? 'Locked name' : name || 'Project';
}

/** "No project" first (when the default project exists), then the other active projects in their given order. */
export function projectMenuOptions(projects: ReadonlyArray<LauncherProject>): Array<SentenceTokenOption> {
  const active = projects.filter((project) => project?.project_id && project.state === 'active');
  const defaultProject = active.find(isDefaultConversationProject);
  const rows: Array<SentenceTokenOption> = [];
  if (defaultProject) {
    rows.push({
      value: defaultProject.project_id,
      label: NO_PROJECT_LABEL,
      tokenLabel: NO_PROJECT_TOKEN_LABEL,
      description: NO_PROJECT_DESCRIPTION,
      leading: <Icon name="folder" size="md" />,
      debugId: 'new-convo-project-option-none',
    });
  }
  for (const project of active) {
    if (project === defaultProject) continue;
    const path = project.default_path?.trim() || '';
    rows.push({
      value: project.project_id,
      label: projectName(project.name),
      description: path || undefined,
      descriptionMono: true,
      keywords: [path, project.slug || ''].filter(Boolean),
      leading: <Icon name="folder" size="md" />,
      debugId: `new-convo-project-option-${project.project_id}`,
    });
  }
  return rows;
}

export interface ProjectMenuProps {
  projects: ReadonlyArray<LauncherProject>;
  /** Chosen project id (the default project renders as "without a project"). */
  value: string;
  /** The page's existing `chooseProject`. */
  onChange: (projectId: string) => void;
  /** Opens the page's existing New project modal. Omit to hide the footer row. */
  onNewProject?: () => void;
  /** Disables only the "New project" row (e.g. vault locked). */
  newProjectDisabled?: boolean;
  disabled?: boolean;
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
}

export function ProjectMenu({ projects, value, onChange, onNewProject, newProjectDisabled, disabled, open, onOpenChange }: ProjectMenuProps) {
  const options = useMemo(() => projectMenuOptions(projects), [projects]);
  return (
    <SentenceToken
      value={value}
      options={options}
      onChange={onChange}
      label="Project"
      debugId="new-convo-project-token"
      menuWidth={PROJECT_MENU_WIDTH}
      search={{ placeholder: PROJECT_SEARCH_PLACEHOLDER, debugId: 'new-convo-project-search', emptyText: PROJECT_EMPTY_TEXT }}
      menuFooter={
        onNewProject ? (
          <>
            <Menu.Separator />
            <Menu.Item
              leading={<Icon name="plus" size="md" />}
              disabled={newProjectDisabled}
              data-debug-id="new-convo-new-project"
              onClick={onNewProject}
            >
              <span className="text-muted">New project</span>
            </Menu.Item>
          </>
        ) : null
      }
      disabled={disabled}
      open={open}
      onOpenChange={onOpenChange}
    >
      {options.some((option) => option.value === value) ? undefined : 'a project'}
    </SentenceToken>
  );
}

export default ProjectMenu;
