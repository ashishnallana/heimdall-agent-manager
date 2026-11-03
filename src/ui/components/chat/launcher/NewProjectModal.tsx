// NewProjectModal — the launcher's "New project" dialog.
//
// The user browses a folder on the bridge chosen in the headline (reusing
// BridgeDirectoryPicker in place of the form, then back). The folder becomes
// default_path, its name the default project name, and useProjectFolderInspection
// detects the VCS kind and prefills the description from the newer of AGENTS.md /
// CLAUDE.md. Auto values never replace what the user typed: each field is only
// rewritten while it still holds the last auto value (or is empty). Inspection
// failures leave the form usable; they only add a short status line.

import { useEffect, useRef, useState, type FormEvent } from 'react';
import { Alert, Button, FormField, Input, Modal, Select, Text, Textarea } from '@ui';
import { apiErrorText } from '../../../api/cookieFetch';
import { useCreateProjectMutation } from '../../../api/endpoints/projects';
import { deriveProjectSlug } from '../../../utils/slug';
import BridgeDirectoryPicker from '../../BridgeDirectoryPicker';
import {
  folderBaseName,
  PREFILL_MAX_CHARS,
  useProjectFolderInspection,
  type ProjectVcsKind,
} from '../../projects/useProjectFolderInspection';

export const VCS_KIND_OPTIONS: { value: ProjectVcsKind; text: string }[] = [
  { value: 'git', text: 'Git' },
  { value: 'jj', text: 'Jujutsu (jj)' },
  { value: 'none', text: 'No version control' },
];

export type NewProjectPayload = { name: string; slug: string; description: string; default_path: string; vcs_kind: ProjectVcsKind };

export type NewProjectModalProps = {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** The bridge selected on the launcher; '' when none. */
  bridgeId: string;
  bridgeLabel?: string;
  /** False when the bridge is missing or offline: browsing and Create are off. */
  bridgeUsable: boolean;
  /** Called with the new project's id after a successful create. */
  onCreated: (projectId: string) => void | Promise<void>;
};

function vcsHint(detected: ProjectVcsKind | null, colocated: boolean, loading: boolean): string {
  if (loading) return 'Detecting version control…';
  if (!detected) return 'Detected from the folder once you choose one.';
  if (detected === 'jj') return colocated ? 'Detected: jj (colocated with Git).' : 'Detected: jj.';
  if (detected === 'git') return 'Detected: Git.';
  return 'Detected: no version control.';
}

export function NewProjectModal({ open, onOpenChange, bridgeId, bridgeLabel, bridgeUsable, onCreated }: NewProjectModalProps) {
  const [createProject, createState] = useCreateProjectMutation();
  const { result: inspection, inspect, reset } = useProjectFolderInspection(bridgeId);

  const [browsing, setBrowsing] = useState(false);
  const [folder, setFolder] = useState('');
  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [vcsKind, setVcsKind] = useState<ProjectVcsKind>('none');
  const [error, setError] = useState('');
  // The last value each field was auto-filled with; a field is only rewritten
  // while it still equals this (or is empty), so typed text always wins.
  const auto = useRef({ name: '', description: '', vcs: 'none' as ProjectVcsKind });
  // The folder most recently chosen. An inspection that resolves after the user
  // has moved on to another folder must not write into the new folder's form.
  const latestFolder = useRef('');

  useEffect(() => {
    if (!open) return;
    setBrowsing(false); setFolder(''); setName(''); setDescription(''); setVcsKind('none'); setError('');
    auto.current = { name: '', description: '', vcs: 'none' };
    latestFolder.current = '';
    reset();
  }, [open, reset]);

  async function chooseFolder(path: string) {
    const next = path.trim();
    setBrowsing(false);
    setFolder(next);
    latestFolder.current = next;
    if (!next) return;
    // Updaters run later, during render: compare against the auto value captured
    // here, before auto.current moves on to the new one.
    const base = folderBaseName(next);
    const prevName = auto.current.name;
    auto.current.name = base;
    setName((current) => (!current.trim() || current === prevName ? base : current));
    const found = await inspect(next);
    if (found.path !== next || latestFolder.current !== next) return;
    if (found.status !== 'done' && found.status !== 'error') return;
    // The previous folder's auto values do not describe this one. Replace them
    // with what this folder yields; when it yields nothing (no instruction file,
    // or the folder could not be read) fall back to empty / 'none'. Typed values
    // are left alone.
    const detected: ProjectVcsKind = found.vcsKind ?? 'none';
    const prevVcs = auto.current.vcs;
    auto.current.vcs = detected;
    setVcsKind((current) => (current === prevVcs ? detected : current));
    const text = found.prefill?.text ?? '';
    const prevDescription = auto.current.description;
    auto.current.description = text;
    setDescription((current) => (!current.trim() || current === prevDescription ? text : current));
  }

  const inspecting = inspection.status === 'loading' && inspection.path === folder;
  const shown = inspection.path === folder ? inspection : null;
  const prefillApplied = Boolean(shown?.prefill && description === shown.prefill.text);
  const descriptionHint = prefillApplied && shown?.prefill
    ? `Prefilled from ${shown.prefill.source}${shown.prefill.truncated ? ` (first ${PREFILL_MAX_CHARS.toLocaleString('en-US')} characters)` : ''}.`
    : inspecting ? 'Looking for AGENTS.md or CLAUDE.md…' : undefined;
  const canCreate = bridgeUsable && Boolean(name.trim()) && Boolean(folder.trim()) && !createState.isLoading;

  async function submit(event: FormEvent) {
    event.preventDefault();
    if (!canCreate) return;
    setError('');
    // The slug is sent explicitly (from the plaintext name, else the folder name)
    // so it never depends on the hub's fallback, which only sees the sealed name.
    const payload: NewProjectPayload = { name: name.trim(), slug: deriveProjectSlug(name, folder.trim()), description, default_path: folder.trim(), vcs_kind: vcsKind };
    try {
      const created = await createProject(payload).unwrap();
      await onCreated(String(created?.project_id || ''));
    } catch (e) {
      setError(apiErrorText(e) || 'Could not create the project.');
    }
  }

  return <Modal open={open} onOpenChange={onOpenChange} title={browsing ? 'Choose the project folder' : 'New project'} size="lg" data-debug-id="new-convo-project-modal">
    <Modal.Body>
      {browsing ? <BridgeDirectoryPicker
        bridgeId={bridgeId}
        bridgeLabel={bridgeLabel}
        initialPath={folder}
        debugId="new-convo-project-browser"
        onPick={(path) => { void chooseFolder(path); }}
        onClose={() => setBrowsing(false)}
      /> : <form onSubmit={submit} className="flex flex-col gap-4" data-debug-id="new-convo-project-form">
        {error ? <div role="alert" data-debug-id="new-convo-project-error"><Alert tone="danger">{error}</Alert></div> : null}
        {!bridgeUsable ? <div data-debug-id="new-convo-project-no-bridge"><Alert tone="warning" title="No bridge to browse">
          A project lives in a folder on one of your machines. Choose an online bridge in the headline to pick its folder.
        </Alert></div> : null}
        <div className="flex items-end gap-2">
          <FormField label={bridgeLabel && bridgeUsable ? `Folder on ${bridgeLabel}` : 'Folder'} required className="min-w-0 flex-1">
            <Input
              data-debug-id="new-convo-project-folder-input"
              value={folder}
              onChange={setFolder}
              onBlur={() => { if (folder.trim() && folder.trim() !== inspection.path) void chooseFolder(folder); }}
              onKeyDown={(e) => { if (e.key === 'Enter') { e.preventDefault(); void chooseFolder(folder); } }}
              placeholder="Browse or type a path"
              disabled={!bridgeUsable}
              width="full"
              className="font-mono"
            />
          </FormField>
          <Button variant="secondary" data-debug-id="new-convo-project-browse-btn" disabled={!bridgeUsable} onClick={() => setBrowsing(true)}>Browse</Button>
        </div>
        <FormField label="Name" required>
          <Input data-debug-id="new-convo-project-name-input" value={name} onChange={setName} placeholder="Project name" width="full" />
        </FormField>
        <FormField label="Version control" hint={vcsHint(shown?.vcsKind ?? null, Boolean(shown?.colocated), inspecting)}>
          <Select data-debug-id="new-convo-project-vcs-select" value={vcsKind} onChange={(v) => setVcsKind(v as ProjectVcsKind)} options={VCS_KIND_OPTIONS} width="full" />
        </FormField>
        <FormField label="Description" hint={descriptionHint}>
          <Textarea data-debug-id="new-convo-project-description-input" value={description} onChange={setDescription} placeholder="Description (optional)" rows={5} width="full" />
        </FormField>
        {shown?.note ? <Text as="p" role="body-sm" tone="muted" className="m-0" data-debug-id="new-convo-project-inspect-note" aria-live="polite">{shown.note} You can type a description instead.</Text> : null}
        <div className="flex justify-end gap-2">
          <Button variant="secondary" data-debug-id="new-convo-cancel-project-btn" onClick={() => onOpenChange(false)}>Cancel</Button>
          <Button type="submit" variant="primary" data-debug-id="new-convo-create-project-btn" loading={createState.isLoading} disabled={!canCreate}>{createState.isLoading ? 'Creating…' : 'Create project'}</Button>
        </div>
      </form>}
    </Modal.Body>
  </Modal>;
}
