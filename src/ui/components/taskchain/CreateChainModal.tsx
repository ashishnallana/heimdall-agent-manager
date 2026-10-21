import React, { useState, useEffect } from 'react';
import {
  useCreateTaskChainMutation,
  useRunWorkflowMutation,
  useFetchWorkflowTemplatesQuery,
  useFetchWorkflowDefinitionsQuery,
} from '../../api/endpoints/tasks';
import { useListAgentIdentitiesQuery } from '../../api/endpoints/agents';

export interface CreateChainModalProps {
  isOpen: boolean;
  onClose: () => void;
  onCreated?: (chainId: string) => void;
  projects?: Array<{ project_id: string; name?: string }>;
  defaultProjectId?: string;
}

export const CreateChainModal: React.FC<CreateChainModalProps> = ({
  isOpen,
  onClose,
  onCreated,
  projects = [],
  defaultProjectId = '',
}) => {
  const [kind, setKind] = useState<'ticket' | 'workflow'>('ticket');
  const [title, setTitle] = useState('');
  const [description, setDescription] = useState('');
  const [projectId, setProjectId] = useState(defaultProjectId);
  const [coordinatorAgentId, setCoordinatorAgentId] = useState('');

  // Workflow template state
  // The modal stays mounted while closed (it returns null below), so every query is
  // skipped until it opens.
  const { data: templatesData } = useFetchWorkflowTemplatesQuery(undefined, { skip: !isOpen });
  const templates: any[] = templatesData?.templates || [];
  const { data: defsData } = useFetchWorkflowDefinitionsQuery(undefined, { skip: !isOpen });
  const definitions: any[] = defsData?.definitions || [];

  const [selectedWorkflowRef, setSelectedWorkflowRef] = useState<string>('');
  const [workflowInputs, setWorkflowInputs] = useState<Record<string, string>>({});

  const { data: agentsData } = useListAgentIdentitiesQuery(undefined, { skip: !isOpen });
  const agents: any[] = agentsData?.agents || [];

  const [createTaskChain, { isLoading: isCreatingChain }] = useCreateTaskChainMutation();
  const [runWorkflow, { isLoading: isRunningWorkflow }] = useRunWorkflowMutation();

  useEffect(() => {
    if (!selectedWorkflowRef) {
      if (templates.length > 0) {
        setSelectedWorkflowRef(`tpl:${templates[0].template_id}`);
      } else if (definitions.length > 0) {
        setSelectedWorkflowRef(`def:${definitions[0].def_id}`);
      }
    }
  }, [templates, definitions, selectedWorkflowRef]);

  useEffect(() => {
    if (!selectedWorkflowRef) return;
    const initial: Record<string, string> = {};
    if (selectedWorkflowRef.startsWith('def:')) {
      const defId = selectedWorkflowRef.slice(4);
      const curDef = definitions.find((d) => d.def_id === defId);
      if (curDef?.spec?.inputs && Array.isArray(curDef.spec.inputs)) {
        curDef.spec.inputs.forEach((inp: any) => {
          initial[inp.name] = inp.default !== undefined ? String(inp.default) : '';
        });
      }
    } else {
      const tplId = selectedWorkflowRef.startsWith('tpl:') ? selectedWorkflowRef.slice(4) : selectedWorkflowRef;
      const curTemplate = templates.find((t) => t.template_id === tplId);
      if (curTemplate?.inputs) {
        Object.entries(curTemplate.inputs).forEach(([k, spec]: [string, any]) => {
          initial[k] = spec.default !== undefined ? String(spec.default) : '';
        });
      }
    }
    setWorkflowInputs(initial);
  }, [selectedWorkflowRef, templates, definitions]);

  if (!isOpen) return null;

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!title.trim()) return;

    try {
      if (kind === 'workflow') {
        const payload: any = {
          name: title.trim(),
          inputs: workflowInputs,
          project_id: projectId || undefined,
        };
        if (selectedWorkflowRef.startsWith('def:')) {
          payload.def_id = selectedWorkflowRef.slice(4);
        } else {
          payload.template_id = selectedWorkflowRef.startsWith('tpl:')
            ? selectedWorkflowRef.slice(4)
            : selectedWorkflowRef;
        }
        const res: any = await runWorkflow(payload).unwrap();
        const cid = res?.chain_id || res?.chain?.chain_id;
        if (cid) onCreated?.(cid);
        else onClose();
      } else {
        const res: any = await createTaskChain({
          title: title.trim(),
          description: description.trim() || undefined,
          kind: 'ticket',
          projectId: projectId || undefined,
          coordinatorAgentId: coordinatorAgentId || undefined,
        }).unwrap();
        const cid = res?.chain_id || res?.chain?.chain_id || res?.id;
        if (cid) onCreated?.(cid);
        else onClose();
      }
    } catch (err) {
      console.error('Failed to create chain', err);
    }
  };

  const isSubmitting = isCreatingChain || isRunningWorkflow;

  return (
    <div
      data-debug-id="create-chain-modal"
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4"
    >
      <div className="w-full max-w-lg rounded-2xl border border-subtle bg-surface p-6 text-left shadow-2xl space-y-4">
        <div className="flex items-center justify-between border-b border-subtle pb-3">
          <h2 className="text-base font-bold text-primary">New Task Chain</h2>
          <button
            type="button"
            onClick={onClose}
            className="text-faint hover:text-primary text-sm font-bold"
          >
            ✕
          </button>
        </div>

        <form onSubmit={handleSubmit} className="space-y-4 text-xs">
          {/* Kind Selector: Ticket vs Workflow */}
          <div className="flex flex-col gap-1.5">
            <span className="font-semibold text-muted uppercase tracking-wider text-[11px]">
              Chain Kind
            </span>
            <div className="grid grid-cols-2 gap-2">
              <button
                type="button"
                data-debug-id="chain-kind-ticket"
                onClick={() => setKind('ticket')}
                className={`flex flex-col gap-1 rounded-xl border p-3 text-left transition-all ${
                  kind === 'ticket'
                    ? 'border-accent bg-accent/10 text-primary'
                    : 'border-subtle bg-surface-raised text-muted hover:border-accent/40'
                }`}
              >
                <span className="font-bold text-xs text-primary">Ticket Chain</span>
                <span className="text-[11px] leading-tight text-muted">
                  Standard 5-state tickets with role-based fleet matching and review gates.
                </span>
              </button>

              <button
                type="button"
                data-debug-id="chain-kind-workflow"
                onClick={() => setKind('workflow')}
                className={`flex flex-col gap-1 rounded-xl border p-3 text-left transition-all ${
                  kind === 'workflow'
                    ? 'border-accent bg-accent/10 text-primary'
                    : 'border-subtle bg-surface-raised text-muted hover:border-accent/40'
                }`}
              >
                <span className="font-bold text-xs text-primary">Workflow Run</span>
                <span className="text-[11px] leading-tight text-muted">
                  Declarative multi-stage pipeline with fan-out, gates, and automatic cascade retry.
                </span>
              </button>
            </div>
          </div>

          {/* Project selector */}
          {projects.length > 0 && (
            <label className="flex flex-col gap-1 text-muted">
              <span className="font-semibold text-[11px]">Project</span>
              <select
                value={projectId}
                onChange={(e) => setProjectId(e.target.value)}
                className="rounded-lg border border-subtle bg-canvas px-3 py-2 text-primary text-xs outline-none focus:border-accent"
              >
                <option value="">— Unassigned —</option>
                {projects.map((p) => (
                  <option key={p.project_id} value={p.project_id}>
                    {p.name || p.project_id}
                  </option>
                ))}
              </select>
            </label>
          )}

          {/* Title */}
          <label className="flex flex-col gap-1 text-muted">
            <span className="font-semibold text-[11px]">Title</span>
            <input
              type="text"
              required
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              placeholder={kind === 'workflow' ? 'e.g. Audit auth routes' : 'e.g. PTY streaming network optimization'}
              className="rounded-lg border border-subtle bg-canvas px-3 py-2 text-primary text-xs outline-none focus:border-accent"
            />
          </label>

          {/* Ticket-specific fields */}
          {kind === 'ticket' && (
            <>
              <label className="flex flex-col gap-1 text-muted">
                <span className="font-semibold text-[11px]">Description</span>
                <textarea
                  value={description}
                  onChange={(e) => setDescription(e.target.value)}
                  placeholder="Overview of the tasks, objectives, and acceptance guidelines…"
                  rows={2}
                  className="rounded-lg border border-subtle bg-canvas p-2.5 text-primary text-xs outline-none focus:border-accent"
                />
              </label>

              {agents.length > 0 && (
                <label className="flex flex-col gap-1 text-muted">
                  <span className="font-semibold text-[11px]">Coordinator Agent (Optional)</span>
                  <select
                    value={coordinatorAgentId}
                    onChange={(e) => setCoordinatorAgentId(e.target.value)}
                    className="rounded-lg border border-subtle bg-canvas px-3 py-2 text-primary text-xs outline-none focus:border-accent"
                  >
                    <option value="">— None (self-managed) —</option>
                    {agents.map((a) => (
                      <option key={a.agent_id || a.id} value={a.agent_id || a.id}>
                        {a.name || a.agent_id || a.id}
                      </option>
                    ))}
                  </select>
                </label>
              )}
            </>
          )}

          {/* Workflow-specific fields */}
          {kind === 'workflow' && (
            <div className="space-y-3 rounded-xl border border-subtle bg-surface-raised p-3">
              <label className="flex flex-col gap-1 text-muted">
                <span className="font-semibold text-[11px]">Workflow Template / Definition</span>
                <select
                  value={selectedWorkflowRef}
                  onChange={(e) => setSelectedWorkflowRef(e.target.value)}
                  className="rounded-lg border border-subtle bg-canvas px-3 py-2 text-primary text-xs outline-none focus:border-accent"
                >
                  {templates.length > 0 && (
                    <optgroup label="Built-in Templates">
                      {templates.map((t) => (
                        <option key={t.template_id} value={`tpl:${t.template_id}`}>
                          {t.name || t.template_id} (v{t.version || 1})
                        </option>
                      ))}
                    </optgroup>
                  )}
                  {definitions.length > 0 && (
                    <optgroup label="Custom Workflow Definitions">
                      {definitions.map((d) => (
                        <option key={d.def_id} value={`def:${d.def_id}`}>
                          {d.spec?.title || d.name} (v{d.version})
                        </option>
                      ))}
                    </optgroup>
                  )}
                </select>
              </label>

              {/* Dynamic Inputs for chosen template */}
              {Object.keys(workflowInputs).length > 0 && (
                <div className="space-y-2 pt-2 border-t border-subtle">
                  <span className="font-semibold text-muted text-[11px] uppercase tracking-wider block">
                    Workflow Inputs
                  </span>
                  {Object.entries(workflowInputs).map(([inputKey, val]) => (
                    <label key={inputKey} className="flex flex-col gap-1 text-muted">
                      <span className="font-mono text-[11px] text-primary">{inputKey}</span>
                      <input
                        type="text"
                        value={val}
                        onChange={(e) =>
                          setWorkflowInputs((prev) => ({
                            ...prev,
                            [inputKey]: e.target.value,
                          }))
                        }
                        className="rounded border border-subtle bg-canvas px-2.5 py-1 text-primary text-xs outline-none focus:border-accent font-mono"
                      />
                    </label>
                  ))}
                </div>
              )}
            </div>
          )}

          {/* Footer buttons */}
          <div className="flex items-center justify-end gap-2 pt-3 border-t border-subtle">
            <button
              type="button"
              onClick={onClose}
              className="rounded-lg border border-subtle bg-surface px-3 py-2 text-xs font-semibold text-muted hover:text-primary transition-colors"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={isSubmitting || !title.trim()}
              className="rounded-lg bg-accent px-4 py-2 text-xs font-semibold text-accent-fg hover:opacity-90 transition-opacity disabled:opacity-50"
            >
              {isSubmitting
                ? 'Creating…'
                : kind === 'workflow'
                  ? 'Start Workflow Run'
                  : 'Create Ticket Chain'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
};

export default CreateChainModal;
