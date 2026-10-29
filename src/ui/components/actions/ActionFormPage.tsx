/**
 * ActionFormPage — `/actions/new` and `/actions/:id/edit`.
 * ------------------------------------------------------------------
 * One page serves create and edit (REQ-UI-9).
 *
 * **The target is the hard part of this form, and it is an either/or.** An action
 * targets EITHER one running instance OR an agent identity plus a bridge — never
 * both, never neither (`action_handlers.odin:249-259`). The two modes are a radio
 * pair rather than "fill in whichever you like", and they validate as a unit.
 *
 * **The target is immutable on edit, and that is the API's rule, not a UI choice.**
 * `patch_action_handler` (:388-470) reads no `target_*` key at all — send one and it
 * is silently dropped. So on edit the whole target section is disabled with the
 * reason stated, rather than accepting edits the server will discard. The one
 * exception is `instance_strategy`, which IS patchable and stays editable.
 *
 * **The schedule editor is reused, not rewritten.** `ScheduleEditor` +
 * `scheduleUtils` already handle cron presets, the advanced expression, timezone,
 * blackout dates and the active window, and already build on `@ui` primitives only.
 * Rebuilding a cron input from zero would be the second component library this
 * rebuild exists to prevent.
 *
 * Client validation mirrors the server's own strings, so the two cannot disagree
 * about what is valid.
 */
import React from 'react';
import {
  Alert,
  Button,
  Combobox,
  FormField,
  Input,
  PageShell,
  Panel,
  Radio,
  Text,
  Toggle,
  type ComboboxOption,
} from '@ui';
import ScheduleEditor, { type ScheduleEditorValue } from './ScheduleEditor';
import { validateCronExpression, getLocalTimezone } from './scheduleUtils';
import {
  parseBlackoutDates,
  useCreateActionMutation,
  useFetchActionQuery,
  usePatchActionMutation,
  type Action,
  type ActionInstanceStrategy,
} from '../../api/endpoints/actions';
import { catalogNote, useActionCatalog, type CatalogSlice } from './actionCatalog';
import {
  actionErrorText,
  actionListHref,
  actionTitle,
  actionViewHref,
  editCrumbs,
  mapServerError,
  navigateTo,
  newCrumbs,
  parseActionListUrl,
  type ActionFormField,
  type ActionTargetMode,
} from './actionModel';
import { getRouteSearch } from '../../utils/appLocation';

/* ------------------------------------------------------------------ *
 * Unsaved-changes guard (same mechanism as AgentFormPage)
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
  targetMode: ActionTargetMode;
  targetInstanceId: string;
  targetAgentId: string;
  targetBridgeId: string;
  targetProvider: string;
  targetModel: string;
  targetProjectId: string;
  instanceStrategy: ActionInstanceStrategy;
  promptText: string;
  scheduled: boolean;
  cronExpr: string;
  timezone: string;
  blackoutDates: string[];
  activeFrom: string;
  activeUntil: string;
}

function emptyForm(): FormState {
  return {
    targetMode: 'agent',
    targetInstanceId: '',
    targetAgentId: '',
    targetBridgeId: '',
    targetProvider: '',
    targetModel: '',
    targetProjectId: '',
    instanceStrategy: 'reuse',
    promptText: '',
    scheduled: false,
    cronExpr: '',
    timezone: getLocalTimezone(),
    blackoutDates: [],
    activeFrom: '',
    activeUntil: '',
  };
}

function formFromRecord(record: Action): FormState {
  const cron = String(record.cron_expr || '').trim();
  return {
    targetMode: record.target_instance_id ? 'instance' : 'agent',
    targetInstanceId: String(record.target_instance_id || ''),
    targetAgentId: String(record.target_agent_id || ''),
    targetBridgeId: String(record.target_bridge_id || ''),
    targetProvider: String(record.target_provider || ''),
    targetModel: String(record.target_model || ''),
    targetProjectId: String(record.target_project_id || ''),
    instanceStrategy: (record.instance_strategy as ActionInstanceStrategy) || 'reuse',
    promptText: String(record.prompt_text || ''),
    scheduled: Boolean(cron),
    cronExpr: cron,
    timezone: String(record.timezone || '') || 'UTC',
    blackoutDates: parseBlackoutDates(record.blackout_dates),
    activeFrom: String(record.active_from || ''),
    activeUntil: String(record.active_until || ''),
  };
}

function isDirty(form: FormState, baseline: FormState): boolean {
  return JSON.stringify(form) !== JSON.stringify(baseline);
}

function toOptions(slice: CatalogSlice): ComboboxOption[] {
  return slice.all.map((entry) => ({
    value: entry.id,
    title: entry.label,
    id: entry.id,
    tag: entry.sub || undefined,
    keywords: entry.keywords,
  }));
}

/* ------------------------------------------------------------------ *
 * The page
 * ------------------------------------------------------------------ */

export default function ActionFormPage({ actionId }: { actionId?: string } = {}) {
  const isEdit = Boolean(actionId);
  const listState = React.useMemo(() => parseActionListUrl(getRouteSearch()), []);

  const actionQuery = useFetchActionQuery({ id: actionId! }, { skip: !isEdit });
  const catalog = useActionCatalog();

  const [createAction, { isLoading: creating }] = useCreateActionMutation();
  const [patchAction, { isLoading: patching }] = usePatchActionMutation();

  const record: Action | null = (actionQuery.data?.action as Action | null) || null;

  const [form, setForm] = React.useState<FormState>(emptyForm);
  const [baseline, setBaseline] = React.useState<FormState>(emptyForm);
  const [fieldErrors, setFieldErrors] = React.useState<Partial<Record<ActionFormField, string>>>({});
  const [submitError, setSubmitError] = React.useState('');

  React.useEffect(() => {
    if (!record) return;
    const filled = formFromRecord(record);
    setForm(filled);
    setBaseline(filled);
  }, [record?.id]);

  const dirty = isDirty(form, baseline);
  const { pendingHref, setPendingHref } = useUnsavedChangesGuard(dirty);

  function setField<K extends keyof FormState>(key: K, value: FormState[K]) {
    setForm((prev) => ({ ...prev, [key]: value }));
    setFieldErrors((prev) => ({ ...prev, [key]: '' }));
    setSubmitError('');
  }

  const scheduleValue: ScheduleEditorValue = {
    cron_expr: form.cronExpr,
    timezone: form.timezone,
    blackout_dates: form.blackoutDates,
    active_from: form.activeFrom,
    active_until: form.activeUntil,
  };

  function onScheduleChange(next: ScheduleEditorValue) {
    setForm((prev) => ({
      ...prev,
      cronExpr: next.cron_expr,
      timezone: next.timezone,
      blackoutDates: next.blackout_dates,
      activeFrom: next.active_from || '',
      activeUntil: next.active_until || '',
    }));
    setFieldErrors((prev) => ({ ...prev, cronExpr: '', blackoutDates: '', activeWindow: '' }));
    setSubmitError('');
  }

  function validate(): Partial<Record<ActionFormField, string>> {
    const errors: Partial<Record<ActionFormField, string>> = {};

    // The either/or, validated as a unit — the server rejects both-or-neither.
    // On edit the target is not sent at all, so it is not re-validated either.
    if (!isEdit) {
      if (form.targetMode === 'instance') {
        if (!form.targetInstanceId) errors.targetInstanceId = 'Choose the agent instance this action runs against.';
      } else {
        if (!form.targetAgentId) errors.targetAgentId = 'Choose the agent this action runs as.';
        if (!form.targetBridgeId) errors.targetBridgeId = 'Choose the bridge the agent runs on.';
      }
    }

    if (!form.promptText.trim()) errors.promptText = 'Enter the prompt this action will send.';

    if (form.scheduled) {
      const cron = form.cronExpr.trim();
      if (!cron) {
        errors.cronExpr = 'Set a schedule, or turn off "Runs on a schedule".';
      } else {
        const result = validateCronExpression(cron);
        if (!result.valid) errors.cronExpr = result.error || 'That cron expression is not valid.';
      }
      if (form.activeFrom && form.activeUntil && Date.parse(form.activeFrom) > Date.parse(form.activeUntil)) {
        errors.activeWindow = 'The active window ends before it starts.';
      }
    }

    return errors;
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    const errors = validate();
    if (Object.keys(errors).length) {
      setFieldErrors(errors);
      return;
    }

    setSubmitError('');
    // Turning the schedule off must actually CLEAR it on the server, not merely stop
    // sending it — PATCH only touches keys that are present.
    const schedule = form.scheduled
      ? {
          cron_expr: form.cronExpr.trim(),
          timezone: form.timezone || 'UTC',
          blackout_dates: form.blackoutDates,
          active_from: form.activeFrom,
          active_until: form.activeUntil,
        }
      : { cron_expr: '', blackout_dates: [] as string[], active_from: '', active_until: '' };

    try {
      if (isEdit) {
        await patchAction({
          id: actionId!,
          prompt_text: form.promptText,
          instance_strategy: form.instanceStrategy,
          ...schedule,
        }).unwrap();
        navigateTo(actionViewHref(actionId!));
      } else {
        const target =
          form.targetMode === 'instance'
            ? { target_instance_id: form.targetInstanceId }
            : {
                target_agent_id: form.targetAgentId,
                target_bridge_id: form.targetBridgeId,
                target_provider: form.targetProvider || undefined,
                target_model: form.targetModel || undefined,
                target_project_id: form.targetProjectId || undefined,
                instance_strategy: form.instanceStrategy,
              };
        const result = await createAction({
          ...target,
          prompt_text: form.promptText,
          ...schedule,
        }).unwrap();
        const newId = String((result?.action as any)?.id || '');
        navigateTo(newId ? actionViewHref(newId) : actionListHref(listState));
      }
    } catch (err) {
      const mapped = mapServerError(err);
      if (mapped && mapped.field !== 'form') {
        setFieldErrors({ [mapped.field]: mapped.message });
      } else if (mapped) {
        setSubmitError(mapped.message);
      } else {
        setSubmitError(actionErrorText(err, `Couldn't ${isEdit ? 'save' : 'create'} this action.`));
      }
    }
  }

  const busy = creating || patching;
  const title = isEdit ? (record ? actionTitle(record) : 'Edit action') : 'New action';
  const breadcrumbs = isEdit && record
    ? editCrumbs(actionTitle(record), actionId!, listState)
    : isEdit
      ? [{ label: 'Actions', href: actionListHref(listState) }, { label: 'Edit' }]
      : newCrumbs(listState);

  if (isEdit && actionQuery.isLoading) {
    return <PageShell rhythm="banded" width="content" title="Edit action" breadcrumbs={breadcrumbs} loading />;
  }

  const instanceOptions = toOptions(catalog.instances);
  const agentOptions = toOptions(catalog.agents);
  // A revoked bridge cannot accept a run, so it is not offered — but an action that
  // already points at one still resolves its name elsewhere.
  const bridgeOptions = toOptions(catalog.bridges).filter((opt) => opt.tag !== 'revoked');
  const projectOptions = toOptions(catalog.projects);

  return (
    <PageShell rhythm="banded" width="content" title={title} breadcrumbs={breadcrumbs}>
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
        {/* ---------------- Target ---------------- */}
        <Panel className="p-4">
          <div className="mb-3">
            <Text as="p" role="title">Target</Text>
            <Text as="p" role="body-sm" tone="muted" className="ui-measure">
              {isEdit
                ? "An action's target is fixed once it exists — Ninjy can't move a schedule to a different agent. Create a new action to target something else."
                : 'Either one running instance, or an agent identity plus the bridge it runs on. Not both.'}
            </Text>
          </div>

          <fieldset disabled={isEdit} className="flex flex-col gap-4 disabled:opacity-60">
            <div className="flex flex-col gap-2" role="radiogroup" aria-label="Target mode">
              <Radio
                name="action-target-mode"
                checked={form.targetMode === 'agent'}
                onChange={() => setField('targetMode', 'agent')}
                label="An agent identity — the scheduler finds or launches an instance when it fires"
                data-debug-id="action-form-mode-agent"
              />
              <Radio
                name="action-target-mode"
                checked={form.targetMode === 'instance'}
                onChange={() => setField('targetMode', 'instance')}
                label="One specific running instance"
                data-debug-id="action-form-mode-instance"
              />
            </div>

            {form.targetMode === 'instance' ? (
              <FormField
                label="Instance"
                required
                error={fieldErrors.targetInstanceId}
                hint={catalogNote(catalog.instances.state, 'instances') || undefined}
              >
                <Combobox
                  value={form.targetInstanceId}
                  onChange={(next) => setField('targetInstanceId', next)}
                  options={instanceOptions}
                  placeholder="Choose a target agent instance…"
                  emptyLabel="No instances match."
                  loading={catalog.instances.state === 'loading'}
                  debugId="action-form-instance"
                />
              </FormField>
            ) : (
              <>
                <FormField
                  label="Agent"
                  required
                  error={fieldErrors.targetAgentId}
                  hint={catalogNote(catalog.agents.state, 'agents') || undefined}
                >
                  <Combobox
                    value={form.targetAgentId}
                    onChange={(next) => setField('targetAgentId', next)}
                    options={agentOptions}
                    placeholder="Choose an agent identity…"
                    emptyLabel="No agents match."
                    loading={catalog.agents.state === 'loading'}
                    debugId="action-form-agent"
                  />
                </FormField>

                <FormField
                  label="Bridge"
                  required
                  error={fieldErrors.targetBridgeId}
                  hint={catalogNote(catalog.bridges.state, 'bridges') || 'The machine the agent runs on.'}
                >
                  <Combobox
                    value={form.targetBridgeId}
                    onChange={(next) => setField('targetBridgeId', next)}
                    options={bridgeOptions}
                    placeholder="Choose a bridge…"
                    emptyLabel="No bridges match."
                    loading={catalog.bridges.state === 'loading'}
                    debugId="action-form-bridge"
                  />
                </FormField>

                <FormField label="Provider" hint="Optional. Leave blank to use the agent's default.">
                  <Input
                    value={form.targetProvider}
                    onChange={(next) => setField('targetProvider', next)}
                    placeholder="e.g. anthropic"
                    aria-label="Provider"
                    data-debug-id="action-form-provider"
                  />
                </FormField>

                <FormField label="Model" hint="Optional. Leave blank to use the agent's default.">
                  <Input
                    value={form.targetModel}
                    onChange={(next) => setField('targetModel', next)}
                    placeholder="e.g. smart"
                    aria-label="Model"
                    data-debug-id="action-form-model"
                  />
                </FormField>

                <FormField
                  label="Project"
                  hint={catalogNote(catalog.projects.state, 'projects') || 'Optional. The project the spawned instance works in.'}
                >
                  <Combobox
                    value={form.targetProjectId}
                    onChange={(next) => setField('targetProjectId', next)}
                    options={projectOptions}
                    placeholder="Global (no project)"
                    emptyLabel="No projects match."
                    loading={catalog.projects.state === 'loading'}
                    debugId="action-form-project"
                  />
                </FormField>
              </>
            )}
          </fieldset>

          {/* `instance_strategy` IS patchable, so unlike the rest of the target it
              stays editable on edit. It only means something for an agent target. */}
          {form.targetMode === 'agent' ? (
            <div className="mt-4 flex flex-col gap-2" role="radiogroup" aria-label="Instance strategy">
              <Text as="div" role="label" tone="muted">Instance strategy</Text>
              <Radio
                name="action-instance-strategy"
                checked={form.instanceStrategy === 'reuse'}
                onChange={() => setField('instanceStrategy', 'reuse')}
                label="Reuse an instance — wake the agent's existing session each run"
                data-debug-id="action-form-strategy-reuse"
              />
              <Radio
                name="action-instance-strategy"
                checked={form.instanceStrategy === 'fresh_per_run'}
                onChange={() => setField('instanceStrategy', 'fresh_per_run')}
                label="Fresh instance per run — mint a new one each time and reap the previous"
                data-debug-id="action-form-strategy-fresh"
              />
            </div>
          ) : null}
        </Panel>

        {/* ---------------- Prompt ---------------- */}
        <Panel className="p-4">
          <div className="mb-3">
            <Text as="p" role="title">Prompt</Text>
            <Text as="p" role="body-sm" tone="muted" className="ui-measure">
              Sent to the agent exactly as written. The first line becomes this action&apos;s
              name in the list, so make it say what the action does.
            </Text>
          </div>
          <FormField label="Prompt" required error={fieldErrors.promptText}>
            {/* A plain textarea rather than @ui's `Textarea`: the prompt is sent
                verbatim and is often long, so it gets a monospace face and a taller
                default. Everything else about it is the shared control's styling. */}
            <textarea
              value={form.promptText}
              onChange={(e) => setField('promptText', e.target.value)}
              rows={10}
              placeholder="e.g. Check test failures, inspect the current branch, and summarise what's pending."
              aria-label="Prompt text"
              data-debug-id="action-form-prompt"
              /* No autoFocus. The prompt is the third section, and focusing it on
                 mount scrolls the page past the Target radio — the first and least
                 reversible decision on this form, since the target is immutable
                 once the action exists. AgentFormPage can autofocus because its
                 first field IS its first decision; this one's is not. */
              className="w-full rounded-[var(--radius-md)] border border-subtle bg-surface px-3 py-2 font-mono text-body-sm text-primary focus-visible:shadow-focus focus-visible:outline-none"
            />
          </FormField>
        </Panel>

        {/* ---------------- Schedule ---------------- */}
        <Panel className="p-4">
          <div className="mb-3 flex items-start justify-between gap-3">
            <div className="min-w-0">
              <Text as="p" role="title">Schedule</Text>
              <Text as="p" role="body-sm" tone="muted" className="ui-measure">
                Off means the action runs only when you run it.
              </Text>
            </div>
            <div className="flex shrink-0 items-center gap-2">
              <Text as="span" role="body-sm">Runs on a schedule</Text>
              <Toggle
                checked={form.scheduled}
                onChange={(next) => {
                  setField('scheduled', next);
                  // Turning it on with nothing set lands on a sensible daily default
                  // rather than an empty expression the server would reject.
                  if (next && !form.cronExpr) setField('cronExpr', '0 9 * * *');
                }}
                aria-label="Runs on a schedule"
                data-debug-id="action-form-scheduled"
              />
            </div>
          </div>

          {form.scheduled ? (
            <div data-debug-id="action-form-schedule-editor">
              <ScheduleEditor value={scheduleValue} onChange={onScheduleChange} />
              {fieldErrors.cronExpr ? (
                <Alert tone="danger" title="Check the schedule" className="mt-3">{fieldErrors.cronExpr}</Alert>
              ) : null}
              {fieldErrors.blackoutDates ? (
                <Alert tone="danger" title="Check the blackout dates" className="mt-3">{fieldErrors.blackoutDates}</Alert>
              ) : null}
              {fieldErrors.activeWindow ? (
                <Alert tone="danger" title="Check the active window" className="mt-3">{fieldErrors.activeWindow}</Alert>
              ) : null}
            </div>
          ) : (
            <Text as="div" role="body-sm" tone="muted" data-debug-id="action-form-schedule-off">
              On demand. You can run it from the list or its own page at any time.
            </Text>
          )}

          {isEdit && record?.interval ? (
            <Alert tone="info" title="This action uses a legacy interval" className="mt-3">
              It fires every {record.interval}. Intervals are not editable here — set a cron
              schedule above to replace it, or leave it as it is.
            </Alert>
          ) : null}
        </Panel>

        {submitError ? <Alert tone="danger" title="That didn't work">{submitError}</Alert> : null}

        <div className="flex items-center justify-between gap-3">
          <Button
            variant="secondary"
            type="button"
            data-debug-id="action-form-cancel"
            onClick={() => navigateTo(isEdit ? actionViewHref(actionId!) : actionListHref(listState))}
          >
            Cancel
          </Button>
          <Button variant="primary" type="submit" loading={busy} data-debug-id="action-form-submit">
            {isEdit ? 'Save changes' : 'Create action'}
          </Button>
        </div>
      </form>
    </PageShell>
  );
}
