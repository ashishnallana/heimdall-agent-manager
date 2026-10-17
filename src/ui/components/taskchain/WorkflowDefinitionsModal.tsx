import React, { useState } from 'react';
import {
  useFetchWorkflowDefinitionsQuery,
  useDefineWorkflowMutation,
  useRunWorkflowMutation,
  type WorkflowDefinitionItem,
} from '../../api/endpoints/tasks';

interface WorkflowDefinitionsModalProps {
  isOpen: boolean;
  onClose: () => void;
  onRunCreated?: (chainId: string) => void;
}

const STARTER_TEMPLATE = JSON.stringify(
  {
    schema: 'workflow.v1',
    name: 'custom_pipeline',
    title: 'Custom Multi-Stage Pipeline',
    description: 'An automated pipeline with analysis, implementation, and review gate.',
    inputs: [
      { name: 'target', type: 'string', description: 'Target component or path to analyze', required: true, default: 'src/' },
      { name: 'strict', type: 'boolean', description: 'Fail on any warnings', required: false, default: true },
    ],
    stages: [
      {
        key: 'analyze',
        kind: 'task',
        title: 'Analyze {{inputs.target}}',
        brief: {
          goal: 'Run static analysis and tests against {{inputs.target}}',
          acceptance: ['Exit with 0 failures', 'Produce report output'],
          verify: 'none',
          output: { schema: 'analysis_report.v1' },
        },
      },
      {
        key: 'gate_approval',
        kind: 'gate',
        title: 'Human Review Gate',
        needs: ['analyze'],
        gate: {
          requires_user_approval: true,
          message: 'Review analysis findings before continuing',
        },
      },
      {
        key: 'deploy',
        kind: 'task',
        title: 'Deploy Changes',
        needs: ['gate_approval'],
        brief: {
          goal: 'Deploy verified artifacts',
          acceptance: ['Health check passes'],
          verify: 'none',
        },
      },
    ],
  },
  null,
  2
);

export const WorkflowDefinitionsModal: React.FC<WorkflowDefinitionsModalProps> = ({
  isOpen,
  onClose,
  onRunCreated,
}) => {
  const [tab, setTab] = useState<'list' | 'create'>('list');
  const [selectedDefId, setSelectedDefId] = useState<string | null>(null);

  // Create state
  const [specJson, setSpecJson] = useState<string>(STARTER_TEMPLATE);
  const [nameOverride, setNameOverride] = useState<string>('');
  const [validationError, setValidationError] = useState<string | null>(null);
  const [saveSuccessMsg, setSaveSuccessMsg] = useState<string | null>(null);

  // Run form state
  const [runningDef, setRunningDef] = useState<WorkflowDefinitionItem | null>(null);
  const [runTitle, setRunTitle] = useState<string>('');
  const [runInputs, setRunInputs] = useState<Record<string, string>>({});

  const { data: defsData, isLoading: isLoadingDefs, refetch: refetchDefs } = useFetchWorkflowDefinitionsQuery(undefined, {
    skip: !isOpen,
  });
  const definitions = defsData?.definitions || [];

  const [defineWorkflow, { isLoading: isSaving }] = useDefineWorkflowMutation();
  const [runWorkflow, { isLoading: isRunning }] = useRunWorkflowMutation();

  if (!isOpen) return null;

  // Validate JSON on the fly
  const handleJsonChange = (val: string) => {
    setSpecJson(val);
    setSaveSuccessMsg(null);
    try {
      const parsed = JSON.parse(val);
      if (parsed.schema && parsed.schema !== 'workflow.v1') {
        setValidationError(`Schema must be "workflow.v1" (got "${parsed.schema}")`);
        return;
      }
      if (!parsed.name && !nameOverride) {
        setValidationError('A workflow "name" is required in the JSON or as an override');
        return;
      }
      if (!parsed.stages || !Array.isArray(parsed.stages) || parsed.stages.length === 0) {
        setValidationError('Workflow must contain at least one stage in "stages" array');
        return;
      }
      setValidationError(null);
    } catch (err: any) {
      setValidationError(`Syntax error: ${err.message}`);
    }
  };

  const handleSave = async () => {
    try {
      const parsed = JSON.parse(specJson);
      setValidationError(null);
      const res = await defineWorkflow({
        spec: parsed,
        name: nameOverride.trim() || undefined,
      }).unwrap();

      setSaveSuccessMsg(`Successfully saved workflow "${res.name}" (version ${res.version})!`);
      refetchDefs();
      setSelectedDefId(res.def_id);
      setTimeout(() => {
        setTab('list');
        setSaveSuccessMsg(null);
      }, 1200);
    } catch (err: any) {
      setValidationError(err?.data?.message || err?.message || 'Failed to save workflow definition');
    }
  };

  const handleOpenRun = (def: WorkflowDefinitionItem) => {
    setRunningDef(def);
    setRunTitle(`${def.spec?.title || def.name} Run`);
    const initialInputs: Record<string, string> = {};
    if (def.spec?.inputs && Array.isArray(def.spec.inputs)) {
      def.spec.inputs.forEach((inp) => {
        initialInputs[inp.name] = inp.default !== undefined ? String(inp.default) : '';
      });
    }
    setRunInputs(initialInputs);
  };

  const handleExecuteRun = async () => {
    if (!runningDef) return;
    try {
      const res: any = await runWorkflow({
        def_id: runningDef.def_id,
        name: runTitle.trim() || `${runningDef.name} Run`,
        inputs: runInputs,
      }).unwrap();
      const cid = res?.chain_id || res?.chain?.chain_id;
      if (cid) {
        onRunCreated?.(cid);
      } else {
        onClose();
      }
    } catch (err: any) {
      console.error('Failed to run workflow', err);
    }
  };

  const selectedDef = definitions.find((d) => d.def_id === selectedDefId) || definitions[0];

  return (
    <div
      data-debug-id="workflow-definitions-modal"
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4"
    >
      <div className="flex flex-col w-full max-w-4xl max-h-[85vh] rounded-2xl border border-subtle bg-surface shadow-2xl overflow-hidden">
        {/* Header */}
        <div className="flex items-center justify-between border-b border-subtle px-6 py-4 bg-surface-header">
          <div className="flex items-center gap-3">
            <span className="text-xl">⚙</span>
            <div>
              <h2 className="text-base font-bold text-primary">Workflow Definitions</h2>
              <p className="text-xs text-faint">
                Define and manage reusable multi-stage workflows (`workflow.v1`) with tasks and review gates
              </p>
            </div>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="text-faint hover:text-primary text-base font-bold px-2 py-1 rounded"
          >
            ✕
          </button>
        </div>

        {/* Tab Bar */}
        <div className="flex items-center border-b border-subtle px-6 bg-surface-secondary/40 gap-4">
          <button
            type="button"
            onClick={() => { setTab('list'); setRunningDef(null); }}
            className={`py-2.5 text-xs font-semibold border-b-2 transition-colors ${
              tab === 'list' && !runningDef
                ? 'border-accent text-primary'
                : 'border-transparent text-muted hover:text-primary'
            }`}
          >
            Definitions Library ({definitions.length})
          </button>
          <button
            type="button"
            onClick={() => { setTab('create'); setRunningDef(null); }}
            className={`py-2.5 text-xs font-semibold border-b-2 transition-colors ${
              tab === 'create'
                ? 'border-accent text-primary'
                : 'border-transparent text-muted hover:text-primary'
            }`}
          >
            + Create Definition
          </button>
          {runningDef && (
            <div className="py-2.5 text-xs font-semibold border-b-2 border-accent text-accent">
              ▶ Run: {runningDef.name} (v{runningDef.version})
            </div>
          )}
        </div>

        {/* Content Body */}
        <div className="flex-1 overflow-y-auto p-6 text-xs">
          {runningDef ? (
            /* Run Configuration Form */
            <div className="max-w-xl mx-auto space-y-4">
              <div className="rounded-xl border border-accent/30 bg-accent/5 p-4 space-y-2">
                <h3 className="font-bold text-primary text-sm">
                  Launch Workflow: {runningDef.spec?.title || runningDef.name}
                </h3>
                <p className="text-muted text-xs">
                  {runningDef.spec?.description || 'Configure parameters below to start a new execution chain.'}
                </p>
              </div>

              <div className="space-y-1.5">
                <label className="font-semibold text-primary">Run Name / Title</label>
                <input
                  type="text"
                  value={runTitle}
                  onChange={(e) => setRunTitle(e.target.value)}
                  className="w-full rounded-lg border border-subtle bg-surface px-3 py-2 text-primary focus:border-accent outline-none"
                  placeholder="e.g. Nightly Analysis Run"
                />
              </div>

              {runningDef.spec?.inputs && runningDef.spec.inputs.length > 0 && (
                <div className="space-y-3 pt-2">
                  <h4 className="font-bold text-muted uppercase tracking-wider text-[11px]">Workflow Inputs</h4>
                  {runningDef.spec.inputs.map((inp) => (
                    <div key={inp.name} className="space-y-1">
                      <div className="flex items-center justify-between">
                        <label className="font-medium text-primary">
                          {inp.name}
                          {inp.required && <span className="text-red-400 ml-1">*</span>}
                        </label>
                        <span className="text-[10px] text-faint font-mono">{inp.type || 'string'}</span>
                      </div>
                      {inp.description && <p className="text-[11px] text-faint">{inp.description}</p>}
                      <input
                        type="text"
                        value={runInputs[inp.name] || ''}
                        onChange={(e) => setRunInputs({ ...runInputs, [inp.name]: e.target.value })}
                        className="w-full rounded-lg border border-subtle bg-surface px-3 py-1.5 text-primary focus:border-accent outline-none"
                        placeholder={inp.default !== undefined ? String(inp.default) : `Value for ${inp.name}`}
                      />
                    </div>
                  ))}
                </div>
              )}

              <div className="flex items-center justify-end gap-3 pt-4 border-t border-subtle">
                <button
                  type="button"
                  onClick={() => setRunningDef(null)}
                  className="px-4 py-2 rounded-lg border border-subtle text-muted hover:text-primary transition-colors"
                >
                  Cancel
                </button>
                <button
                  type="button"
                  onClick={handleExecuteRun}
                  disabled={isRunning}
                  className="px-5 py-2 rounded-lg bg-accent text-white font-semibold hover:opacity-90 transition-opacity disabled:opacity-50"
                >
                  {isRunning ? 'Launching Run...' : 'Launch Workflow'}
                </button>
              </div>
            </div>
          ) : tab === 'create' ? (
            /* Create Definition Tab */
            <div className="space-y-4">
              <div className="flex items-center justify-between">
                <div>
                  <h3 className="font-bold text-primary text-sm">New Workflow Specification</h3>
                  <p className="text-faint text-xs">
                    Paste or compose a valid `workflow.v1` JSON definition with stages and optional input parameters.
                  </p>
                </div>
                <button
                  type="button"
                  onClick={() => setSpecJson(STARTER_TEMPLATE)}
                  className="px-3 py-1.5 text-[11px] font-medium border border-subtle rounded-lg text-muted hover:text-primary transition-colors"
                >
                  Reset to Starter
                </button>
              </div>

              <div className="grid grid-cols-2 gap-3">
                <div className="space-y-1">
                  <label className="font-semibold text-primary">Name Override (optional)</label>
                  <input
                    type="text"
                    value={nameOverride}
                    onChange={(e) => { setNameOverride(e.target.value); handleJsonChange(specJson); }}
                    placeholder="Defaults to JSON name field"
                    className="w-full rounded-lg border border-subtle bg-surface px-3 py-1.5 text-primary focus:border-accent outline-none"
                  />
                </div>
              </div>

              <div className="space-y-1">
                <label className="font-semibold text-primary">Specification JSON (`workflow.v1`)</label>
                <textarea
                  rows={14}
                  value={specJson}
                  onChange={(e) => handleJsonChange(e.target.value)}
                  className="w-full font-mono text-[11px] rounded-lg border border-subtle bg-surface-secondary/70 p-3 text-primary focus:border-accent outline-none leading-relaxed"
                  spellCheck={false}
                />
              </div>

              {validationError && (
                <div className="rounded-lg bg-red-950/40 border border-red-800/60 p-3 text-red-300 font-medium">
                  ⚠ {validationError}
                </div>
              )}

              {saveSuccessMsg && (
                <div className="rounded-lg bg-emerald-950/40 border border-emerald-800/60 p-3 text-emerald-300 font-medium">
                  ✓ {saveSuccessMsg}
                </div>
              )}

              <div className="flex items-center justify-end gap-3 pt-2">
                <button
                  type="button"
                  onClick={() => setTab('list')}
                  className="px-4 py-2 rounded-lg border border-subtle text-muted hover:text-primary"
                >
                  Cancel
                </button>
                <button
                  type="button"
                  onClick={handleSave}
                  disabled={isSaving || !!validationError}
                  className="px-5 py-2 rounded-lg bg-accent text-white font-semibold hover:opacity-90 transition-opacity disabled:opacity-50"
                >
                  {isSaving ? 'Saving...' : 'Save Definition'}
                </button>
              </div>
            </div>
          ) : (
            /* Definitions Library View */
            <div className="grid grid-cols-1 md:grid-cols-3 gap-6 h-full">
              {/* Definition List Sidebar */}
              <div className="md:col-span-1 border-r border-subtle pr-4 space-y-2">
                <div className="flex items-center justify-between pb-1">
                  <span className="font-bold text-muted uppercase tracking-wider text-[11px]">Saved Workflows</span>
                  <button
                    type="button"
                    onClick={() => setTab('create')}
                    className="text-accent hover:underline text-[11px] font-semibold"
                  >
                    + New
                  </button>
                </div>

                {isLoadingDefs ? (
                  <div className="py-8 text-center text-faint">Loading definitions...</div>
                ) : definitions.length === 0 ? (
                  <div className="py-8 text-center text-faint space-y-2">
                    <p>No custom workflows yet.</p>
                    <button
                      type="button"
                      onClick={() => setTab('create')}
                      className="px-3 py-1.5 text-xs bg-accent text-white rounded-lg font-semibold"
                    >
                      Create First Workflow
                    </button>
                  </div>
                ) : (
                  <div className="space-y-1.5 overflow-y-auto max-h-[50vh]">
                    {definitions.map((def) => {
                      const isSelected = (selectedDef?.def_id === def.def_id);
                      return (
                        <div
                          key={def.def_id}
                          onClick={() => setSelectedDefId(def.def_id)}
                          className={`p-3 rounded-xl border cursor-pointer transition-all ${
                            isSelected
                              ? 'border-accent bg-accent/10 shadow-sm'
                              : 'border-subtle bg-surface hover:border-accent/40'
                          }`}
                        >
                          <div className="flex items-center justify-between">
                            <span className="font-bold text-primary truncate max-w-[140px]">{def.name}</span>
                            <span className="px-1.5 py-0.5 rounded text-[10px] font-mono bg-surface-secondary border border-subtle text-muted">
                              v{def.version}
                            </span>
                          </div>
                          <p className="text-[11px] text-faint truncate mt-1">
                            {def.spec?.title || def.name}
                          </p>
                          <div className="flex items-center gap-2 mt-2 text-[10px] text-faint">
                            <span>{def.spec?.stages?.length || 0} stages</span>
                            <span>•</span>
                            <span>{def.spec?.inputs?.length || 0} inputs</span>
                          </div>
                        </div>
                      );
                    })}
                  </div>
                )}
              </div>

              {/* Definition Detail & Preview */}
              <div className="md:col-span-2 space-y-4">
                {selectedDef ? (
                  <div className="space-y-4">
                    <div className="flex items-start justify-between border-b border-subtle pb-3">
                      <div>
                        <div className="flex items-center gap-2">
                          <h3 className="text-base font-bold text-primary">
                            {selectedDef.spec?.title || selectedDef.name}
                          </h3>
                          <span className="px-2 py-0.5 rounded-full text-[10px] font-mono bg-accent/15 text-accent border border-accent/30 font-semibold">
                            v{selectedDef.version}
                          </span>
                        </div>
                        <p className="text-xs text-muted mt-1">
                          {selectedDef.spec?.description || `Workflow definition ID: ${selectedDef.def_id}`}
                        </p>
                      </div>
                      <button
                        type="button"
                        onClick={() => handleOpenRun(selectedDef)}
                        className="px-4 py-2 rounded-lg bg-accent text-white font-semibold hover:opacity-90 transition-opacity flex items-center gap-1.5"
                      >
                        <span>▶</span>
                        <span>Run</span>
                      </button>
                    </div>

                    {/* Stages Overview */}
                    <div className="space-y-2">
                      <h4 className="font-bold text-muted uppercase tracking-wider text-[11px]">
                        Pipeline Stages ({selectedDef.spec?.stages?.length || 0})
                      </h4>
                      <div className="flex flex-wrap items-center gap-2">
                        {selectedDef.spec?.stages?.map((stage, idx) => (
                          <div
                            key={stage.key}
                            className="flex items-center gap-1.5 px-2.5 py-1.5 rounded-lg border border-subtle bg-surface-secondary text-primary"
                          >
                            <span className="text-[10px] font-mono text-faint">{idx + 1}.</span>
                            <span className="font-semibold">{stage.title || stage.key}</span>
                            <span
                              className={`text-[9px] uppercase px-1 py-0.2 rounded font-mono ${
                                stage.kind === 'gate' ? 'bg-amber-950/40 text-amber-300' : 'bg-blue-950/40 text-blue-300'
                              }`}
                            >
                              {stage.kind}
                            </span>
                            {idx < (selectedDef.spec?.stages?.length || 0) - 1 && (
                              <span className="text-faint ml-1">→</span>
                            )}
                          </div>
                        ))}
                      </div>
                    </div>

                    {/* Inputs Overview */}
                    {selectedDef.spec?.inputs && selectedDef.spec.inputs.length > 0 && (
                      <div className="space-y-1.5">
                        <h4 className="font-bold text-muted uppercase tracking-wider text-[11px]">Inputs</h4>
                        <div className="grid grid-cols-2 gap-2">
                          {selectedDef.spec.inputs.map((inp) => (
                            <div key={inp.name} className="p-2 rounded-lg border border-subtle bg-surface-secondary">
                              <div className="flex items-center justify-between font-mono text-[11px]">
                                <span className="font-bold text-primary">{inp.name}</span>
                                <span className="text-faint text-[10px]">{inp.type || 'string'}</span>
                              </div>
                              {inp.description && (
                                <p className="text-[10px] text-faint mt-0.5">{inp.description}</p>
                              )}
                            </div>
                          ))}
                        </div>
                      </div>
                    )}

                    {/* Full JSON Specification */}
                    <div className="space-y-1.5 pt-2">
                      <h4 className="font-bold text-muted uppercase tracking-wider text-[11px]">Specification JSON</h4>
                      <pre className="max-h-56 overflow-y-auto p-3 rounded-lg border border-subtle bg-surface-secondary text-[10px] font-mono leading-relaxed text-muted">
                        {JSON.stringify(selectedDef.spec, null, 2)}
                      </pre>
                    </div>
                  </div>
                ) : (
                  <div className="py-16 text-center text-faint">Select a workflow definition to view details.</div>
                )}
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
};

export default WorkflowDefinitionsModal;
