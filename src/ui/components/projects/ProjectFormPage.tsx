/**
 * ProjectFormPage — `/projects/new` and `/projects/:id/edit`.
 * ------------------------------------------------------------------
 * One page serves create and edit (REQ-UI-9).
 *
 * Two things specific to projects:
 *
 *  1. **A field cannot be CLEARED.** `update` merges only non-empty input
 *     (`project_service.odin:232-239`: `if input.x != "" do project.x = input.x`),
 *     so emptying Description or Repository URL and pressing Save would appear to
 *     work and change nothing. The form blocks it on the field instead, with the
 *     reason. Sending a single space to fake a clear was the alternative, and it
 *     writes a lie into the record.
 *
 *  2. **Per-bridge paths are not form fields.** A project has a path PER BRIDGE
 *     (`domain/project.odin:30-41`), and each one is its own endpoint
 *     (`PUT`/`DELETE`/`POST …/validate` on `/projects/:id/bridge-paths/:bridge_id`),
 *     only reachable once the project exists, carrying server-owned validation
 *     state that a dirty-state form would fight. So they get their own section
 *     BELOW the form, each row saving immediately through its own endpoint, and
 *     the section says so rather than letting a user think Save covers it. On
 *     create the section is a placeholder: there is no project id to hang a path
 *     on yet.
 */
import React from 'react';
import {
  Alert,
  Button,
  FormField,
  Icon,
  Input,
  Modal,
  ModalBody,
  ModalFooter,
  PageShell,
  Panel,
  Select,
  Spinner,
  StatusPill,
  Text,
  Textarea,
} from '@ui';
import BridgeDirectoryPicker from '../BridgeDirectoryPicker';
import {
  normalizeProject,
  projectErrorText,
  useCreateProjectMutation,
  useDeleteProjectBridgePathMutation,
  useFetchProjectQuery,
  useSetProjectBridgePathMutation,
  useUpdateProjectMutation,
  useValidateProjectBridgePathMutation,
  type ProjectBridgePath,
} from '../../api/endpoints/projects';
import { useListBridgesQuery } from '../../api/endpoints/bridgeSupport';
import {
  CANNOT_CLEAR_MESSAGE,
  absoluteTime,
  editCrumbs,
  looksLikeRepoUrl,
  mapServerError,
  navigateTo,
  newCrumbs,
  projectListHref,
  projectTitle,
  projectViewHref,
  relativeTime,
  type ProjectFormField,
} from './projectModel';

interface FormState {
  name: string;
  description: string;
  repoUrl: string;
  vcsKind: string;
  defaultPath: string;
}

const EMPTY_FORM: FormState = {
  name: '',
  description: '',
  repoUrl: '',
  vcsKind: '',
  defaultPath: '',
};

/* ------------------------------------------------------------------ *
 * The unsaved-changes guard (REQ-UI-21)
 * ------------------------------------------------------------------ */

/**
 * Raises a confirm before a dirty form is abandoned — by a breadcrumb, an in-app
 * link, the browser's back button or a reload. Same mechanism as the Memory form:
 * an intercepted click covers hash links, and `popstate` needs the other half
 * because the browser has already moved by the time we hear about it.
 */
function useUnsavedChangesGuard(dirty: boolean) {
  const [pendingHref, setPendingHref] = React.useState('');
  const dirtyRef = React.useRef(dirty);
  dirtyRef.current = dirty;
  const selfHref = React.useRef('');

  React.useEffect(() => {
    selfHref.current = window.location.href;
  }, []);

  React.useEffect(() => {
    if (!dirty) return undefined;

    const onBeforeUnload = (event: BeforeUnloadEvent) => {
      event.preventDefault();
      event.returnValue = '';
    };

    const onClick = (event: MouseEvent) => {
      if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey) return;
      const anchor = (event.target as HTMLElement | null)?.closest?.('a[href]') as HTMLAnchorElement | null;
      if (!anchor) return;
      const href = anchor.getAttribute('href') || '';
      if (!href.startsWith('#')) return;
      if (window.location.hash === href) return;
      event.preventDefault();
      setPendingHref(href);
    };

    const onPopState = () => {
      if (!dirtyRef.current) return;
      const attempted = window.location.hash;
      window.history.pushState(window.history.state, '', selfHref.current);
      setPendingHref(attempted);
    };

    window.addEventListener('beforeunload', onBeforeUnload);
    document.addEventListener('click', onClick, true);
    window.addEventListener('popstate', onPopState);
    return () => {
      window.removeEventListener('beforeunload', onBeforeUnload);
      document.removeEventListener('click', onClick, true);
      window.removeEventListener('popstate', onPopState);
    };
  }, [dirty]);

  return {
    pendingHref,
    keepEditing: () => setPendingHref(''),
    discard: () => {
      const href = pendingHref;
      dirtyRef.current = false;
      setPendingHref('');
      if (href) navigateTo(href);
    },
    /** Leave deliberately (a successful save), without the guard interfering. */
    leaveTo: (href: string) => {
      dirtyRef.current = false;
      navigateTo(href);
    },
  };
}

/* ------------------------------------------------------------------ *
 * The page
 * ------------------------------------------------------------------ */

export default function ProjectFormPage({ projectId }: { projectId?: string }) {
  const editing = Boolean(projectId);

  const projectQuery = useFetchProjectQuery({ projectId: projectId || '' }, { skip: !projectId });
  const record = React.useMemo(
    () => (projectQuery.data?.project ? normalizeProject(projectQuery.data.project) : null),
    [projectQuery.data],
  );

  const [form, setForm] = React.useState<FormState>(EMPTY_FORM);
  const [dirty, setDirty] = React.useState(false);
  const [errors, setErrors] = React.useState<Partial<Record<ProjectFormField, string>>>({});
  const [saving, setSaving] = React.useState(false);
  const [pickerOpen, setPickerOpen] = React.useState(false);

  const nameRef = React.useRef<HTMLInputElement | null>(null);
  const repoRef = React.useRef<HTMLInputElement | null>(null);
  const pathRef = React.useRef<HTMLInputElement | null>(null);
  const descriptionRef = React.useRef<HTMLTextAreaElement | null>(null);

  const [createProject] = useCreateProjectMutation();
  const [updateProject] = useUpdateProjectMutation();

  /** What the record held when the form was seeded — the clear-guard's reference. */
  const originalRef = React.useRef<FormState>(EMPTY_FORM);

  // Seed from the record once it arrives. Keyed on identity, never on the whole
  // record: re-seeding on a cache refresh would clobber edits in progress.
  React.useEffect(() => {
    if (!record) return;
    const next: FormState = {
      name: record.name,
      description: record.description,
      repoUrl: record.repoUrl,
      vcsKind: record.vcsKind,
      defaultPath: record.defaultPath,
    };
    setForm(next);
    originalRef.current = next;
    setDirty(false);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [record?.projectId]);

  const guard = useUnsavedChangesGuard(dirty);

  function update<K extends keyof FormState>(key: K, value: FormState[K]) {
    setForm((prev) => ({ ...prev, [key]: value }));
    setDirty(true);
  }

  /**
   * Client-side validation. The two required rules are the server's
   * (`project_service.odin:206-209`); the repo-URL shape and the clear-guard are
   * the client's, and both are marked as such.
   */
  function validate(): boolean {
    const next: Partial<Record<ProjectFormField, string>> = {};
    if (!form.name.trim()) next.name = 'Give the project a name.';
    if (!form.defaultPath.trim()) next.defaultPath = 'Choose the folder this project lives in.';
    if (!looksLikeRepoUrl(form.repoUrl)) next.repoUrl = "That doesn't look like a repository URL.";

    // The clear-guard: only on EDIT, and only for a field that HAD a value and is
    // now empty. On create an empty optional field is simply absent.
    if (editing) {
      const original = originalRef.current;
      if (original.description.trim() && !form.description.trim()) next.description = CANNOT_CLEAR_MESSAGE;
      if (original.repoUrl.trim() && !form.repoUrl.trim()) next.repoUrl = CANNOT_CLEAR_MESSAGE;
      if (original.vcsKind.trim() && !form.vcsKind.trim()) next.vcsKind = CANNOT_CLEAR_MESSAGE;
    }

    setErrors(next);
    // The first failing field is focused.
    if (next.name) nameRef.current?.focus();
    else if (next.defaultPath) pathRef.current?.focus();
    else if (next.repoUrl) repoRef.current?.focus();
    else if (next.description) descriptionRef.current?.focus();
    return Object.keys(next).length === 0;
  }

  function applyServerError(err: unknown) {
    const mapped = mapServerError(projectErrorText(err));
    setErrors({ [mapped.field]: mapped.message });
    if (mapped.field === 'name') nameRef.current?.focus();
    else if (mapped.field === 'defaultPath') pathRef.current?.focus();
  }

  async function save() {
    if (!validate()) return;
    setSaving(true);
    const payload = {
      name: form.name.trim(),
      description: form.description.trim(),
      repo_url: form.repoUrl.trim(),
      vcs_kind: form.vcsKind.trim(),
      default_path: form.defaultPath.trim(),
    };
    try {
      if (!editing) {
        const created = await createProject(payload as any).unwrap();
        const newId = String(created?.project_id || created?.projectId || '');
        guard.leaveTo(newId ? projectViewHref(newId) : projectListHref());
        return;
      }
      await updateProject({ projectId: projectId as string, ...payload } as any).unwrap();
      guard.leaveTo(projectViewHref(projectId as string));
    } catch (err) {
      applyServerError(err);
    } finally {
      setSaving(false);
    }
  }

  if (editing && projectQuery.isLoading) {
    return <PageShell rhythm="banded" title="Edit project" breadcrumbs={editCrumbs('Loading…', projectId || '')} loading />;
  }

  const heading = editing ? 'Edit project' : 'New project';
  const crumbs = editing ? editCrumbs(projectTitle(record), projectId || '') : newCrumbs();

  return (
    <PageShell rhythm="banded" width="content" title={heading} breadcrumbs={crumbs}>
      <div data-debug-id="project-form-page" className="flex w-full max-w-3xl min-w-0 flex-col gap-4">
        {errors.form ? <Alert tone="danger" title="That didn't save">{errors.form}</Alert> : null}

        <FormField label="Name" required error={errors.name}>
          <Input
            ref={nameRef}
            value={form.name}
            onChange={(next) => update('name', next)}
            width="full"
            invalid={Boolean(errors.name)}
            data-debug-id="project-form-name"
            placeholder="What this project is called"
          />
        </FormField>

        <FormField
          label="Default path"
          required
          error={errors.defaultPath}
          hint="The folder this project lives in. A bridge with no override of its own uses this one."
        >
          <div className="flex items-start gap-2">
            <Input
              ref={pathRef}
              value={form.defaultPath}
              onChange={(next) => update('defaultPath', next)}
              width="full"
              invalid={Boolean(errors.defaultPath)}
              data-debug-id="project-form-path"
              placeholder="/home/you/code/my-project"
              className="min-w-0 flex-1 font-mono"
            />
            {/* The modal picker (REQ-UI-9's "modal picker" input type). It browses a
                REAL bridge's filesystem, so it needs one chosen first — which is why
                it opens a chooser rather than a bare tree. */}
            <Button
              variant="secondary"
              data-debug-id="project-form-browse"
              leading={<Icon name="folder" size="sm" />}
              onClick={() => setPickerOpen(true)}
            >
              Browse
            </Button>
          </div>
        </FormField>

        <FormField label="Description" error={errors.description} hint="Optional. Markdown. Shown on the project page and given to agents.">
          <Textarea
            ref={descriptionRef}
            value={form.description}
            onChange={(next) => update('description', next)}
            rows={5}
            width="full"
            invalid={Boolean(errors.description)}
            data-debug-id="project-form-description"
          />
        </FormField>

        <FormField label="Repository URL" error={errors.repoUrl} hint="Optional. Used when validating a path against a remote.">
          <Input
            ref={repoRef}
            value={form.repoUrl}
            onChange={(next) => update('repoUrl', next)}
            width="full"
            invalid={Boolean(errors.repoUrl)}
            data-debug-id="project-form-repo"
            placeholder="https://github.com/you/my-project"
          />
        </FormField>

        <FormField
          label="Version control"
          error={errors.vcsKind}
          hint="Only git changes behaviour — a bridge validating a path checks for a git root."
        >
          <Select
            value={form.vcsKind}
            onChange={(next) => update('vcsKind', next)}
            width="full"
            invalid={Boolean(errors.vcsKind)}
            data-debug-id="project-form-vcs"
          >
            <option value="">None</option>
            <option value="git">git</option>
            <option value="jj">jj</option>
          </Select>
        </FormField>

        {/* No Slug field (T17): the slug is derived from the name when the project
            is created (createProject) and is never shown or edited in the UI. */}
        {editing && record ? (
          <FormField label="Project ID" hint="Set when the project was created and never changes.">
            <Input value={record.projectId} onChange={() => undefined} width="full" disabled readOnly data-debug-id="project-form-id" className="font-mono" />
          </FormField>
        ) : null}

        <div className="flex flex-wrap items-center gap-2">
          <Button
            variant="primary"
            loading={saving}
            data-debug-id="project-form-submit"
            leading={<Icon name="save" size="sm" />}
            onClick={() => void save()}
          >
            {editing ? 'Save changes' : 'Create project'}
          </Button>
          <Button
            variant="secondary"
            data-debug-id="project-form-cancel"
            onClick={() => navigateTo(editing ? projectViewHref(projectId as string) : projectListHref())}
          >
            Cancel
          </Button>
        </div>

        {/* ---- the per-bridge paths section ---- */}
        <BridgePathsSection projectId={projectId || ''} paths={record?.bridgePaths || []} defaultPath={form.defaultPath} />
      </div>

      {pickerOpen ? (
        <BridgePickerModal
          initialPath={form.defaultPath}
          onClose={() => setPickerOpen(false)}
          onPick={(path) => {
            update('defaultPath', path);
            if (!editing && !form.name.trim()) {
              const base = path.split('/').filter(Boolean).pop();
              if (base) update('name', base);
            }
            setPickerOpen(false);
          }}
        />
      ) : null}

      {guard.pendingHref ? (
        <Modal
          open
          onOpenChange={(next) => { if (!next) guard.keepEditing(); }}
          title="Discard your changes to this project?"
          size="sm"
          data-debug-id="project-form-discard-modal"
        >
          <ModalBody>
            <Text role="body">Your edits haven&apos;t been saved yet.</Text>
          </ModalBody>
          <ModalFooter>
            <Button variant="secondary" data-debug-id="project-form-keep-editing" onClick={guard.keepEditing}>Keep editing</Button>
            <Button variant="danger" data-debug-id="project-form-discard" onClick={guard.discard}>Discard</Button>
          </ModalFooter>
        </Modal>
      ) : null}
    </PageShell>
  );
}

/* ------------------------------------------------------------------ *
 * Per-bridge paths
 * ------------------------------------------------------------------ */

/**
 * The paths section.
 *
 * Every control here writes IMMEDIATELY through its own endpoint — it is not part
 * of the form's Save, and the section says so in one line rather than leaving the
 * user to discover it. That is the honest arrangement given the API: a path is
 * addressed by `(project, bridge)` and has no representation in the project PATCH
 * body at all.
 */
function BridgePathsSection({
  projectId,
  paths,
  defaultPath,
}: {
  projectId: string;
  paths: ProjectBridgePath[];
  defaultPath: string;
}) {
  const bridgesQuery = useListBridgesQuery();
  const bridges: any[] = bridgesQuery.data?.bridges || [];
  const [setPath] = useSetProjectBridgePathMutation();
  const [deletePath] = useDeleteProjectBridgePathMutation();
  const [validatePath] = useValidateProjectBridgePathMutation();
  const [busy, setBusy] = React.useState('');
  const [error, setError] = React.useState('');
  const [picking, setPicking] = React.useState<{ bridgeId: string; current: string } | null>(null);
  const [draftPaths, setDraftPaths] = React.useState<Record<string, string>>({});

  const byBridge = React.useMemo(() => {
    const map = new Map<string, ProjectBridgePath>();
    for (const entry of paths) map.set(entry.bridge_id, entry);
    return map;
  }, [paths]);

  if (!projectId) {
    return (
      <Panel data-debug-id="project-form-paths-placeholder" className="p-4">
        <Text as="div" role="title">Bridge paths</Text>
        <Text as="div" role="body-sm" tone="muted" className="ui-measure mt-1">
          Add per-bridge paths after you save. A path belongs to a project and a machine together, so it needs a project that exists.
        </Text>
      </Panel>
    );
  }

  async function run(action: 'set' | 'validate' | 'remove', bridgeId: string, path?: string) {
    setBusy(bridgeId);
    setError('');
    try {
      if (action === 'set') await setPath({ projectId, bridgeId, path: path || '' }).unwrap();
      else if (action === 'validate') await validatePath({ projectId, bridgeId }).unwrap();
      else await deletePath({ projectId, bridgeId }).unwrap();
    } catch (err) {
      setError(projectErrorText(err));
    } finally {
      setBusy('');
    }
  }

  return (
    <Panel data-debug-id="project-form-paths" className="p-4">
      <div className="mb-2">
        <Text as="div" role="title">Bridge paths</Text>
        <Text as="div" role="body-sm" tone="muted" className="ui-measure">
          Where this project sits on each machine, when it differs from the default path.
          {' '}
          <strong>These save on their own</strong> — they are separate from the form above, so the Save button does not cover them.
        </Text>
      </div>

      {error ? <Alert tone="danger" title="That didn't work">{error}</Alert> : null}

      {bridgesQuery.isLoading ? (
        <div className="flex items-center gap-2" data-debug-id="project-form-paths-loading">
          <Spinner size="sm" />
          <Text as="span" role="body-sm" tone="muted">Loading bridges…</Text>
        </div>
      ) : bridgesQuery.error ? (
        // Three catalog states, not one: failed is not the same fact as empty.
        <Text as="div" role="body-sm" tone="muted" data-debug-id="project-form-paths-failed">
          Couldn&apos;t load your bridges, so per-bridge paths can&apos;t be edited right now.
        </Text>
      ) : bridges.length === 0 ? (
        <Text as="div" role="body-sm" tone="muted" data-debug-id="project-form-paths-none">
          No bridges are enrolled yet. Every machine you enrol can carry its own path for this project.
        </Text>
      ) : (
        <ul className="flex flex-col gap-3" data-debug-id="project-form-paths-list">
          {bridges.map((bridge) => {
            const bridgeId = String(bridge?.bridge_id || bridge?.bridgeId || bridge?.id || '');
            const label = String(bridge?.label || bridge?.machine_hostname || bridgeId);
            const entry = byBridge.get(bridgeId);
            return (
              <li
                key={bridgeId}
                data-debug-id={`project-form-path-${bridgeId}`}
                className="flex flex-col gap-1.5 border-t border-subtle pt-3 first:border-0 first:pt-0"
              >
                <div className="flex flex-wrap items-center gap-2">
                  <Text as="span" role="label">{label}</Text>
                  {entry ? (
                    entry.is_validated ? (
                      <StatusPill tone="success">Validated</StatusPill>
                    ) : entry.validation_error ? (
                      <StatusPill tone="danger">Failed</StatusPill>
                    ) : (
                      <StatusPill tone="neutral">Not checked</StatusPill>
                    )
                  ) : null}
                </div>

                <div className="flex items-start gap-2">
                  <Input
                    value={draftPaths[bridgeId] ?? entry?.path ?? ''}
                    onChange={(v) => setDraftPaths((prev) => ({ ...prev, [bridgeId]: v }))}
                    onBlur={() => {
                      const draft = draftPaths[bridgeId];
                      if (draft === undefined) return;
                      const saved = entry?.path ?? '';
                      if (draft !== saved) void run('set', bridgeId, draft);
                    }}
                    placeholder={defaultPath || 'Path on this machine'}
                    className="min-w-0 flex-1 font-mono"
                    data-debug-id={`project-form-path-input-${bridgeId}`}
                  />
                  <Button
                    size="sm"
                    variant="secondary"
                    leading={<Icon name="folder" size="sm" />}
                    data-debug-id={`project-form-path-browse-${bridgeId}`}
                    onClick={() => setPicking({ bridgeId, current: draftPaths[bridgeId] ?? entry?.path ?? defaultPath })}
                  >
                    Browse
                  </Button>
                </div>

                {entry?.validation_error ? (
                  <Text as="div" role="body-sm" tone="danger">{entry.validation_error}</Text>
                ) : null}
                {entry?.last_validated_at ? (
                  <Text as="div" role="caption" tone="muted" title={absoluteTime(entry.last_validated_at)}>
                    Checked {relativeTime(entry.last_validated_at)}
                  </Text>
                ) : null}

                {entry ? (
                  <div className="flex flex-wrap items-center gap-2">
                    <Button
                      size="sm"
                      variant="secondary"
                      loading={busy === bridgeId}
                      data-debug-id={`project-form-path-validate-${bridgeId}`}
                      onClick={() => void run('validate', bridgeId)}
                    >
                      Validate
                    </Button>
                    <Button
                      size="sm"
                      variant="ghost"
                      loading={busy === bridgeId}
                      data-debug-id={`project-form-path-remove-${bridgeId}`}
                      onClick={() => void run('remove', bridgeId)}
                    >
                      Use the default
                    </Button>
                  </div>
                ) : null}
              </li>
            );
          })}
        </ul>
      )}

      {picking ? (
        <Modal
          open
          onOpenChange={(next) => { if (!next) setPicking(null); }}
          title="Choose a folder on this machine"
          size="lg"
          className="min-h-[440px] flex flex-col"
          data-debug-id="project-form-path-picker"
        >
          <ModalBody className="min-h-[440px] flex-1">
            <BridgeDirectoryPicker
              bridgeId={picking.bridgeId}
              initialPath={picking.current}
              debugId={`project-form-picker-${picking.bridgeId}`}
              onPick={(path) => {
                const bridgeId = picking.bridgeId;
                setPicking(null);
                setDraftPaths((prev) => ({ ...prev, [bridgeId]: path }));
                void run('set', bridgeId, path);
              }}
              onClose={() => setPicking(null)}
            />
          </ModalBody>
        </Modal>
      ) : null}
    </Panel>
  );
}

/**
 * The Browse modal for the DEFAULT path.
 *
 * The picker browses a real machine, so it needs a bridge before it can show
 * anything — the default path is not bridge-specific, but choosing it still means
 * looking at some machine's disk. The chooser makes that explicit rather than
 * silently picking the first bridge and presenting its tree as "the" filesystem.
 */
function BridgePickerModal({
  initialPath,
  onPick,
  onClose,
}: {
  initialPath: string;
  onPick: (path: string) => void;
  onClose: () => void;
}) {
  const bridgesQuery = useListBridgesQuery();
  const bridges: any[] = bridgesQuery.data?.bridges || [];
  const [bridgeId, setBridgeId] = React.useState('');

  React.useEffect(() => {
    if (!bridgeId && bridges.length === 1) {
      setBridgeId(String(bridges[0]?.bridge_id || bridges[0]?.bridgeId || bridges[0]?.id || ''));
    }
  }, [bridgeId, bridges]);

  return (
    <Modal
      open
      onOpenChange={(next) => { if (!next) onClose(); }}
      title="Choose the project folder"
      size="lg"
      className="min-h-[440px] flex flex-col"
      data-debug-id="project-form-browse-modal"
    >
      <ModalBody className="min-h-[440px] flex-1">
        {bridgesQuery.isLoading ? (
          <div className="flex items-center gap-2">
            <Spinner size="sm" />
            <Text as="span" role="body-sm" tone="muted">Loading bridges…</Text>
          </div>
        ) : bridgesQuery.error ? (
          <Text as="div" role="body-sm" tone="muted">
            Couldn&apos;t load your bridges. You can still type the path in directly.
          </Text>
        ) : bridges.length === 0 ? (
          <Text as="div" role="body-sm" tone="muted">
            No bridges are enrolled, so there is no machine to browse. Type the path in directly — it will be used once a bridge comes online.
          </Text>
        ) : (
          <div className="flex flex-col gap-3">
            <FormField label="Machine" hint="Browsing reads this machine's filesystem; the path is saved on the project itself.">
              <Select value={bridgeId} onChange={setBridgeId} width="full" data-debug-id="project-form-browse-bridge">
                <option value="">Choose a machine…</option>
                {bridges.map((bridge) => {
                  const id = String(bridge?.bridge_id || bridge?.bridgeId || bridge?.id || '');
                  return (
                    <option key={id} value={id}>
                      {String(bridge?.label || bridge?.machine_hostname || id)}
                    </option>
                  );
                })}
              </Select>
            </FormField>
            {bridgeId ? (
              <BridgeDirectoryPicker
                bridgeId={bridgeId}
                initialPath={initialPath}
                debugId="project-form-browse-picker"
                onPick={onPick}
                onClose={onClose}
              />
            ) : null}
          </div>
        )}
      </ModalBody>
      <ModalFooter>
        <Button variant="secondary" data-debug-id="project-form-browse-close" onClick={onClose}>Close</Button>
      </ModalFooter>
    </Modal>
  );
}
