/**
 * AgentFormPage — `/agents/new` and `/agents/:id/edit`.
 * ------------------------------------------------------------------
 * One page serves create and edit (REQ-UI-9).
 *
 * Fields: name (required), slug (optional, auto-derived from name on create),
 * instructions (optional), templateId, requireApprovals (permission_mode
 * `ask` when on, `yolo` when off — REQ-EXT-PERM-2).
 *
 * No per-bridge paths: agents are not filesystem-bound like projects.
 * No "cannot clear" complexity: agent PATCH accepts empty strings and the
 * server stores what it receives (unlike project PATCH which ignores empties).
 */
import React from 'react';
import {
  Alert,
  Button,
  Checkbox,
  FormField,
  Icon,
  Input,
  PageShell,
  Panel,
  Select,
  Spinner,
  Textarea,
} from '@ui';
import {
  agentErrorText,
  normalizeAgent,
  useArchiveAgentIdentityMutation,
  useCreateAgentMutation,
  useFetchAgentIdentityQuery,
  useListAgentTemplatesQuery,
  useUpdateAgentIdentityMutation,
  type AgentRecord,
} from '../../api/endpoints/agents';
import {
  agentEditHref,
  agentListHref,
  agentTitle,
  agentViewHref,
  editCrumbs,
  mapServerError,
  navigateTo,
  newCrumbs,
  parseAgentListUrl,
  type AgentFormField,
} from './agentModel';
import { getRouteSearch } from '../../utils/appLocation';

/* ------------------------------------------------------------------ *
 * Unsaved-changes guard (same mechanism as ProjectFormPage)
 * ------------------------------------------------------------------ */

function useUnsavedChangesGuard(dirty: boolean) {
  const [pendingHref, setPendingHref] = React.useState('');

  React.useEffect(() => {
    if (!dirty) return undefined;
    function onBeforeUnload(e: BeforeUnloadEvent) {
      e.preventDefault();
    }
    window.addEventListener('beforeunload', onBeforeUnload);
    return () => window.removeEventListener('beforeunload', onBeforeUnload);
  }, [dirty]);

  React.useEffect(() => {
    if (!dirty) return undefined;
    function onClick(e: MouseEvent) {
      const anchor = (e.target as HTMLElement).closest('a');
      const href = anchor?.getAttribute('href');
      if (!href || !href.startsWith('#') || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
      e.preventDefault();
      setPendingHref(href);
    }
    function onPopState() {
      if (!dirty) return;
      const confirmed = window.confirm('You have unsaved changes. Leave anyway?');
      if (!confirmed) window.history.forward();
    }
    window.addEventListener('click', onClick, { capture: true });
    window.addEventListener('popstate', onPopState);
    return () => {
      window.removeEventListener('click', onClick, { capture: true });
      window.removeEventListener('popstate', onPopState);
    };
  }, [dirty]);

  return { pendingHref, setPendingHref };
}

/* ------------------------------------------------------------------ *
 * Form state
 * ------------------------------------------------------------------ */

interface FormState {
  name: string;
  slug: string;
  instructions: string;
  templateId: string;
  requireApprovals: boolean;
}

const EMPTY_FORM: FormState = {
  name: '',
  slug: '',
  instructions: '',
  templateId: '',
  requireApprovals: false,
};

function slugify(name: string): string {
  return name.trim().toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
}

function formFromRecord(record: AgentRecord): FormState {
  return {
    name: record.name,
    slug: record.slug,
    instructions: record.instructions,
    templateId: record.templateId,
    requireApprovals: record.permissionMode === 'ask',
  };
}

function isDirty(form: FormState, baseline: FormState): boolean {
  return (Object.keys(form) as (keyof FormState)[]).some((k) => form[k] !== baseline[k]);
}

/* ------------------------------------------------------------------ *
 * The page
 * ------------------------------------------------------------------ */

export default function AgentFormPage({ agentId }: { agentId?: string } = {}) {
  const isEdit = Boolean(agentId);
  const listState = React.useMemo(() => parseAgentListUrl(getRouteSearch()), []);

  const agentQuery = useFetchAgentIdentityQuery({ agentId: agentId! }, { skip: !isEdit });
  const templatesQuery = useListAgentTemplatesQuery();

  const [createAgent, { isLoading: creating }] = useCreateAgentMutation();
  const [updateAgent, { isLoading: updating }] = useUpdateAgentIdentityMutation();

  const record: AgentRecord | null = React.useMemo(() => {
    const raw = agentQuery.data?.agent;
    return raw ? normalizeAgent(raw) : null;
  }, [agentQuery.data]);

  const [form, setForm] = React.useState<FormState>(EMPTY_FORM);
  const [baseline, setBaseline] = React.useState<FormState>(EMPTY_FORM);
  const [fieldErrors, setFieldErrors] = React.useState<Partial<Record<AgentFormField, string>>>({});
  const [submitError, setSubmitError] = React.useState('');
  const [slugAutosynced, setSlugAutosynced] = React.useState(!isEdit);

  React.useEffect(() => {
    if (!record) return;
    const filled = formFromRecord(record);
    setForm(filled);
    setBaseline(filled);
    setSlugAutosynced(false);
  }, [record?.agentId]);

  const dirty = isDirty(form, baseline);
  const { pendingHref, setPendingHref } = useUnsavedChangesGuard(dirty);

  const templates = React.useMemo(
    () => (templatesQuery.data?.templates || []).map((tmpl: any) => ({
      id: String(tmpl.template_id || tmpl.templateId || tmpl.id || ''),
      name: String(tmpl.name || tmpl.template_id || tmpl.id || ''),
    })).filter((t: { id: string }) => t.id),
    [templatesQuery.data?.templates],
  );

  function setField<K extends keyof FormState>(key: K, value: FormState[K]) {
    setForm((prev) => {
      const next = { ...prev, [key]: value };
      if (key === 'name' && slugAutosynced) {
        next.slug = slugify(String(value));
      }
      return next;
    });
    setFieldErrors((prev) => ({ ...prev, [key]: '' }));
    setSubmitError('');
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    const errors: Partial<Record<AgentFormField, string>> = {};
    if (!form.name.trim()) errors.name = 'Name is required.';
    if (Object.keys(errors).length) {
      setFieldErrors(errors);
      return;
    }

    setSubmitError('');
    try {
      if (isEdit) {
        await updateAgent({
          agentId: agentId!,
          name: form.name,
          slug: form.slug || undefined,
          templateId: form.templateId || undefined,
          instructions: form.instructions,
          permissionMode: form.requireApprovals ? 'ask' : 'yolo',
        }).unwrap();
        navigateTo(agentViewHref(agentId!));
      } else {
        const result = await createAgent({
          name: form.name,
          slug: form.slug || slugify(form.name) || form.name,
          templateId: form.templateId || undefined,
          instructions: form.instructions,
          permissionMode: form.requireApprovals ? 'ask' : 'yolo',
        }).unwrap();
        const newId = String(result?.agent_id || result?.agentId || result?.agent?.agent_id || '');
        navigateTo(newId ? agentViewHref(newId) : agentListHref(listState));
      }
    } catch (err) {
      const mapped = mapServerError(err);
      if (mapped) {
        if (mapped.field !== 'form') {
          setFieldErrors({ [mapped.field]: mapped.message });
        } else {
          setSubmitError(mapped.message);
        }
      } else {
        setSubmitError(agentErrorText(err, `Couldn't ${isEdit ? 'save' : 'create'} this agent.`));
      }
    }
  }

  const busy = creating || updating;
  const title = isEdit ? agentTitle(record) : 'New agent';
  const breadcrumbs = isEdit && record
    ? editCrumbs(agentTitle(record), agentId!, listState)
    : isEdit
      ? [{ label: 'Agents', href: agentListHref(listState) }, { label: 'Edit' }]
      : newCrumbs(listState);

  if (isEdit && agentQuery.isLoading) {
    return (
      <PageShell rhythm="banded" width="content" title="Edit agent" breadcrumbs={breadcrumbs} loading />
    );
  }

  return (
    <PageShell
      rhythm="banded"
      width="content"
      title={title}
      breadcrumbs={breadcrumbs}
    >
      {/* Unsaved-changes confirm dialog */}
      {pendingHref ? (
        <div
          role="dialog"
          aria-modal="true"
          aria-label="Unsaved changes"
          className="fixed inset-x-0 top-0 app-viewport-height z-modal flex items-center justify-center bg-overlay p-4"
        >
          <div className="w-full max-w-sm rounded-[var(--radius-lg)] bg-surface p-6 shadow-lg">
            <p className="mb-4 text-body text-primary">You have unsaved changes. Leave this page?</p>
            <div className="flex justify-end gap-2">
              <Button variant="secondary" onClick={() => setPendingHref('')}>Stay</Button>
              <Button
                variant="danger"
                onClick={() => {
                  const href = pendingHref;
                  setPendingHref('');
                  navigateTo(href);
                }}
              >
                Leave
              </Button>
            </div>
          </div>
        </div>
      ) : null}

      <form onSubmit={handleSubmit} noValidate className="flex flex-col gap-4">
        <Panel className="p-4">
          <div className="flex flex-col gap-4">
            <FormField label="Name" error={fieldErrors.name} required>
              <Input
                value={form.name}
                onChange={(next) => setField('name', next)}
                placeholder="Friendly display name"
                aria-label="Agent name"
                data-debug-id="agent-form-name"
                autoFocus={!isEdit}
              />
            </FormField>

            <FormField
              label="Slug"
              hint="A URL-safe identifier auto-derived from the name. Edit only if you need a custom one."
              error={fieldErrors.slug}
            >
              <Input
                value={form.slug}
                onChange={(next) => {
                  setSlugAutosynced(false);
                  setField('slug', next);
                }}
                placeholder="auto-generated"
                aria-label="Agent slug"
                data-debug-id="agent-form-slug"
                className="font-mono"
              />
            </FormField>

            <FormField label="Instructions" hint="System prompt and persona instructions. Supports markdown.">
              <Textarea
                value={form.instructions}
                onChange={(next) => setField('instructions', next)}
                rows={8}
                placeholder="You are a…"
                aria-label="Agent instructions"
                data-debug-id="agent-form-instructions"
              />
            </FormField>
          </div>
        </Panel>

        <Panel className="p-4">
          <div className="mb-3">
            <p className="text-title text-primary">Template</p>
            <p className="text-body-sm text-muted">
              Provider and model are selected explicitly when an instance launches.
            </p>
          </div>
          <div className="flex flex-col gap-4">
            {templates.length > 0 ? (
              <FormField label="Template" hint="Base template to inherit settings from.">
                <Select
                  value={form.templateId}
                  onChange={(next) => setField('templateId', next)}
                  aria-label="Template"
                  data-debug-id="agent-form-template"
                >
                  <option value="">No template</option>
                  {templates.map((tmpl: { id: string; name: string }) => (
                    <option key={tmpl.id} value={tmpl.id}>{tmpl.name}</option>
                  ))}
                </Select>
              </FormField>
            ) : null}
          </div>
        </Panel>

        <Panel className="p-4">
          <div className="mb-3">
            <p className="text-title text-primary">Permissions</p>
          </div>
          <div className="flex flex-col gap-1">
            <Checkbox
              checked={form.requireApprovals}
              onChange={(next) => setField('requireApprovals', next)}
              label="Require permission approvals"
              data-debug-id="agent-form-require-approvals"
            />
            <p className="text-body-sm text-muted">
              Launches the provider without its auto-approve flags, so the agent asks before using tools.
              Approvals appear in Ninjy when the provider extension is installed, otherwise in the
              agent&apos;s terminal. This is the default for new launches; a running agent can
              override it with &quot;Bypass permissions&quot; in its conversation settings.
            </p>
          </div>
        </Panel>

        {submitError ? (
          <Alert tone="danger" title="That didn't work">{submitError}</Alert>
        ) : null}

        <div className="flex items-center justify-between gap-3">
          <Button
            variant="secondary"
            type="button"
            data-debug-id="agent-form-cancel"
            onClick={() =>
              navigateTo(isEdit ? agentViewHref(agentId!) : agentListHref(listState))
            }
          >
            Cancel
          </Button>
          <Button
            variant="primary"
            type="submit"
            loading={busy}
            data-debug-id="agent-form-submit"
          >
            {isEdit ? 'Save changes' : 'Create agent'}
          </Button>
        </div>
      </form>
    </PageShell>
  );
}
