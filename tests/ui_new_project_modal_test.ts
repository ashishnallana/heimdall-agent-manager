// Launcher New project modal (T12): folder browser on the selected bridge, name from
// the folder, VCS auto-detect (.jj > .git > none), description prefill from the newer
// of AGENTS.md / CLAUDE.md through GET /bridges/{id}/fs/file, no overwrite of typed
// text, read failures that never block Create, and the create payload.
//
// The modal mounts in jsdom against a vault-unlocked store with a fake bridge
// filesystem behind fetch. File contents come back vault-encrypted, as the bridge
// sends them. Components are imported inside the DOM; DOM nodes are never compared
// with assert.equal (see the chain's dead ends).
//
// RUN: node --import ./tests/helpers/vaultEndpointHarness.ts --test tests/ui_new_project_modal_test.ts

import { test } from 'node:test';
import assert from 'node:assert/strict';
import React from 'react';
import { makeVaultStore, unlockVault } from './helpers/vaultEndpointHarness.ts';

const TEST_KEY = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const ROOT = '/home/u';
const OLD = '2026-10-01T10:00:00Z';
const NEW = '2026-11-02T10:00:00Z';

type Entry = { name: string; is_dir: boolean; hidden?: boolean; modified_at?: string };
type FileSpec = { content?: string; modified_at?: string; error?: { code: string; cause: string; message: string } };
type Fs = { dirs: Record<string, Entry[]>; files?: Record<string, FileSpec>; failList?: boolean; truncated?: Record<string, boolean> };
type Call = { method: string; url: string; path: string; query: URLSearchParams; body: any };
type Ctx = {
  doc: Document; win: any; calls: Call[]; created: string[];
  act: (fn: () => Promise<void> | void) => Promise<void>;
  settle: (ms?: number) => Promise<void>;
  decrypt: (text: string) => Promise<string>;
};

async function withModal(fs: Fs, props: Record<string, unknown>, run: (ctx: Ctx) => Promise<void>) {
  const { JSDOM } = await import('jsdom');
  const dom = new JSDOM('<!DOCTYPE html><html><body><div id="root"></div></body></html>', { url: 'http://localhost/' });
  const win = dom.window as any;
  win.matchMedia = (q: string) => ({ matches: false, media: q, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {} });
  win.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };
  win.HTMLElement.prototype.animate = function animate() { return { finished: Promise.resolve(), cancel() {} }; };
  win.HTMLElement.prototype.scrollIntoView = function scrollIntoView() {};
  // jsdom has no CSS.escape; @ui Select uses it for the active option (same shim as ui_setup_profiles_test).
  win.CSS = { escape: (value: string) => value.replace(/[^a-zA-Z0-9_-]/g, (ch) => `\\${ch}`) };
  const keys = ['window', 'document', 'HTMLElement', 'Node', 'KeyboardEvent', 'MouseEvent', 'localStorage', 'ResizeObserver', 'CSS'] as const;
  const saved: Record<string, unknown> = {};
  for (const k of keys) saved[k] = (globalThis as any)[k];
  const savedNavigator = (globalThis as any).navigator;
  const savedFetch = (globalThis as any).fetch;
  const savedRaf = (globalThis as any).requestAnimationFrame;
  const savedCaf = (globalThis as any).cancelAnimationFrame;
  for (const k of keys) (globalThis as any)[k] = k === 'window' ? win : k === 'document' ? win.document : win[k];
  Object.defineProperty(globalThis, 'navigator', { value: win.navigator, configurable: true });
  (globalThis as any).requestAnimationFrame = (cb: any) => setTimeout(cb, 0);
  (globalThis as any).cancelAnimationFrame = (id: any) => clearTimeout(id);
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;

  const { encryptVaultText, decryptVaultText, getActiveVaultKey } = await import('../src/ui/utils/vaultContent.ts');
  const calls: Call[] = [];
  const json = (data: any, status = 200) => {
    const text = JSON.stringify(status === 200 ? { data } : data);
    return { ok: status === 200, status, headers: { get: () => 'application/json' }, text: async () => text, json: async () => JSON.parse(text) } as any;
  };
  (globalThis as any).fetch = async (input: any, init: any = {}) => {
    const url = String(input?.url ?? input);
    const method = String(init?.method || input?.method || 'GET').toUpperCase();
    const raw = init?.body ?? (typeof input?.clone === 'function' && method !== 'GET' ? await input.clone().text() : '');
    let body: any = {};
    try { body = raw ? JSON.parse(String(raw)) : {}; } catch { body = raw; }
    const u = new URL(url, 'http://localhost');
    calls.push({ method, url, path: u.pathname, query: u.searchParams, body });
    if (/\/bridges\/[^/]+\/fs$/.test(u.pathname)) {
      if (fs.failList) return json({ error: { code: 'unavailable', message: 'Bridge b_river is not connected' } }, 503);
      const path = u.searchParams.get('path') || ROOT;
      const entries = fs.dirs[path];
      if (!entries) return json({ ok: false, path, root: ROOT, parent: '', entries: [], truncated: false, error: { code: 'not_found', cause: 'path_not_found', message: 'Path does not exist' } });
      const parent = path === ROOT ? '' : path.slice(0, path.lastIndexOf('/')) || '/';
      return json({ ok: true, path, root: ROOT, parent, entries, truncated: Boolean(fs.truncated?.[path]) });
    }
    if (/\/bridges\/[^/]+\/fs\/file$/.test(u.pathname)) {
      const path = u.searchParams.get('path') || '';
      const spec = fs.files?.[path];
      if (!spec) return json({ ok: false, path, viewable: false, mime: '', size: 0, modified_at: '', truncated: false, error: { code: 'not_found', cause: 'path_not_found', message: 'Path does not exist' } });
      if (spec.error) return json({ ok: false, path, viewable: false, mime: 'text/markdown', size: 0, modified_at: spec.modified_at || '', truncated: false, error: spec.error });
      const limit = Number(u.searchParams.get('limit') || '0') || spec.content!.length;
      const chunk = spec.content!.slice(0, limit);
      const content = await encryptVaultText(chunk, getActiveVaultKey()!);
      return json({ ok: true, path, viewable: true, content, encoding: 'utf8', mime: 'text/markdown', size: spec.content!.length, modified_at: spec.modified_at, truncated: false, offset: 0, bytes_returned: chunk.length, eof: chunk.length >= spec.content!.length });
    }
    if (u.pathname.endsWith('/projects') && method === 'POST') return json({ project_id: 'proj_new', name: body.name, default_path: body.default_path, vcs_kind: body.vcs_kind });
    return json({});
  };

  const { Provider } = await import('react-redux');
  const { createRoot } = await import('react-dom/client');
  const { act } = await import('react');
  const { heimdallApi } = await import('../src/ui/api/heimdallApi.ts');
  const { NewProjectModal } = await import('../src/ui/components/chat/launcher/NewProjectModal.tsx');
  const store = await makeVaultStore();
  await unlockVault(store, TEST_KEY);
  const root = createRoot(win.document.getElementById('root')!);
  const created: string[] = [];
  const settle = async (ms = 30) => { await act(async () => { await new Promise((r) => setTimeout(r, ms)); }); };
  try {
    await act(async () => {
      root.render(React.createElement(Provider, { store }, React.createElement(NewProjectModal, {
        open: true, onOpenChange: () => {}, bridgeId: 'b_river', bridgeLabel: 'riverwood', bridgeUsable: true,
        onCreated: (id: string) => { created.push(id); }, ...props,
      })));
    });
    await settle(60);
    await run({ doc: win.document, win, calls, created, act: async (fn) => { await act(async () => { await fn(); }); }, settle, decrypt: (t) => decryptVaultText(t, getActiveVaultKey()!) });
  } finally {
    await act(async () => root.unmount());
    store.dispatch(heimdallApi.util.resetApiState());
    (await import('../src/ui/utils/vaultCrypto.ts')).setActiveVaultKey(null);
    dom.window.close();
    for (const k of keys) (globalThis as any)[k] = saved[k];
    Object.defineProperty(globalThis, 'navigator', { value: savedNavigator, configurable: true });
    (globalThis as any).fetch = savedFetch;
    (globalThis as any).requestAnimationFrame = savedRaf;
    (globalThis as any).cancelAnimationFrame = savedCaf;
  }
}

const q = (doc: Document, id: string) => doc.querySelector(`[data-debug-id="${id}"]`) as HTMLElement | null;
const squash = (t: string | null | undefined) => String(t ?? '').replace(/\s+/g, ' ').trim();
const field = (doc: Document, id: string) => q(doc, id) as HTMLInputElement | HTMLTextAreaElement;

async function until(ctx: Ctx, pred: () => boolean, label: string, ms = 3000) {
  const end = Date.now() + ms;
  while (!pred()) {
    if (Date.now() > end) assert.fail(`timed out waiting for: ${label}`);
    await ctx.settle(20);
  }
}
async function click(ctx: Ctx, el: HTMLElement | null) {
  assert.ok(el, 'element to click exists');
  await ctx.act(() => { el!.dispatchEvent(new ctx.win.MouseEvent('click', { bubbles: true, cancelable: true })); });
  await ctx.settle();
}
async function type(ctx: Ctx, el: HTMLElement | null, value: string) {
  assert.ok(el, 'field exists');
  const proto = el instanceof ctx.win.HTMLTextAreaElement ? ctx.win.HTMLTextAreaElement.prototype : ctx.win.HTMLInputElement.prototype;
  await ctx.act(() => { Object.getOwnPropertyDescriptor(proto, 'value')!.set!.call(el, value); el!.dispatchEvent(new ctx.win.Event('input', { bubbles: true })); });
  await ctx.settle();
}
/** Type a folder path and press Enter (the same chooseFolder path as Browse). */
async function enterFolder(ctx: Ctx, path: string) {
  const input = q(ctx.doc, 'new-convo-project-folder-input');
  await type(ctx, input, path);
  await ctx.act(() => { input!.dispatchEvent(new ctx.win.KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true })); });
  await until(ctx, () => !/Detecting|Looking for/.test(squash(q(ctx.doc, 'new-convo-project-form')?.textContent)), `inspection of ${path}`);
}
const vcsValue = (doc: Document) => squash(q(doc, 'new-convo-project-vcs-select')?.textContent);
const createButton = (doc: Document) => q(doc, 'new-convo-create-project-btn') as HTMLButtonElement;
const lastCreate = (ctx: Ctx) => [...ctx.calls].reverse().find((c) => c.method === 'POST' && c.path.endsWith('/projects'));
const fileReads = (ctx: Ctx) => ctx.calls.filter((c) => c.path.endsWith('/fs/file')).map((c) => c.query.get('path'));

test('Browse picks a folder on the selected bridge; name, colocated jj and payload follow it', async () => {
  const fs: Fs = {
    dirs: {
      [ROOT]: [{ name: 'heimdall', is_dir: true }],
      [`${ROOT}/heimdall`]: [{ name: '.git', is_dir: true, hidden: true }, { name: '.jj', is_dir: true, hidden: true }, { name: 'src', is_dir: true }, { name: 'README.md', is_dir: false }],
    },
  };
  await withModal(fs, {}, async (ctx) => {
    assert.match(squash(q(ctx.doc, 'new-convo-project-form')?.textContent), /Folder on riverwood/);
    assert.ok(createButton(ctx.doc).disabled, 'Create is off until a folder and a name exist');
    await click(ctx, q(ctx.doc, 'new-convo-project-browse-btn'));
    await until(ctx, () => Boolean(q(ctx.doc, 'new-convo-project-browser-entry-heimdall')), 'picker lists the bridge root');
    assert.ok(ctx.calls.some((c) => c.path === '/api/v1/bridges/b_river/fs'), 'the picker browses the selected bridge');
    await click(ctx, q(ctx.doc, 'new-convo-project-browser-entry-heimdall'));
    await until(ctx, () => (q(ctx.doc, 'new-convo-project-browser-path-input') as HTMLInputElement)?.value === `${ROOT}/heimdall`, 'picker opened the folder');
    await click(ctx, q(ctx.doc, 'new-convo-project-browser-pick-btn'));
    await until(ctx, () => /Detected: jj/.test(squash(q(ctx.doc, 'new-convo-project-form')?.textContent)), 'detection done');

    assert.equal(field(ctx.doc, 'new-convo-project-folder-input').value, `${ROOT}/heimdall`);
    assert.equal(field(ctx.doc, 'new-convo-project-name-input').value, 'heimdall');
    assert.match(vcsValue(ctx.doc), /Jujutsu/);
    assert.match(squash(q(ctx.doc, 'new-convo-project-form')?.textContent), /Detected: jj \(colocated with Git\)\./);
    assert.equal(field(ctx.doc, 'new-convo-project-description-input').value, '', 'no instruction file, no prefill');
    assert.deepEqual(fileReads(ctx), [], 'nothing to read when neither file is listed');

    await click(ctx, createButton(ctx.doc));
    await until(ctx, () => ctx.created.length === 1, 'onCreated');
    const body = lastCreate(ctx)!.body;
    assert.equal(body.default_path, `${ROOT}/heimdall`);
    assert.equal(body.vcs_kind, 'jj');
    assert.equal(await ctx.decrypt(body.name), 'heimdall');
    assert.deepEqual(ctx.created, ['proj_new']);
  });
});

test('VCS: .git only -> git, neither -> none, and the user can override it', async () => {
  const fs: Fs = { dirs: { [`${ROOT}/a`]: [{ name: '.git', is_dir: false, hidden: true }], [`${ROOT}/b`]: [{ name: 'notes.txt', is_dir: false }] } };
  await withModal(fs, {}, async (ctx) => {
    await enterFolder(ctx, `${ROOT}/a`);
    assert.match(vcsValue(ctx.doc), /^Git/, 'a .git file (worktree) counts as git');
    await enterFolder(ctx, `${ROOT}/b`);
    assert.match(vcsValue(ctx.doc), /No version control/);
    assert.match(squash(q(ctx.doc, 'new-convo-project-form')?.textContent), /Detected: no version control\./);
    // Override through the @ui Select.
    await click(ctx, q(ctx.doc, 'new-convo-project-vcs-select'));
    const jjOption = [...ctx.doc.querySelectorAll('[role="option"]')].find((o) => /Jujutsu/.test(o.textContent || '')) as HTMLElement;
    await click(ctx, jjOption);
    assert.match(vcsValue(ctx.doc), /Jujutsu/);
    await click(ctx, createButton(ctx.doc));
    await until(ctx, () => ctx.created.length === 1, 'onCreated');
    assert.equal(lastCreate(ctx)!.body.vcs_kind, 'jj', 'the override is sent');
  });
});

test('description prefill uses the more recently modified of AGENTS.md / CLAUDE.md', async () => {
  const dir = `${ROOT}/proj`;
  const fs: Fs = {
    dirs: { [dir]: [{ name: '.git', is_dir: true }, { name: 'AGENTS.md', is_dir: false, modified_at: OLD }, { name: 'CLAUDE.md', is_dir: false, modified_at: NEW }] },
    files: { [`${dir}/AGENTS.md`]: { content: '# Old agents notes', modified_at: OLD }, [`${dir}/CLAUDE.md`]: { content: '\n# Claude notes\nUse nix.\n', modified_at: NEW } },
  };
  await withModal(fs, {}, async (ctx) => {
    await enterFolder(ctx, dir);
    assert.equal(field(ctx.doc, 'new-convo-project-description-input').value, '# Claude notes\nUse nix.', 'decrypted, trimmed CLAUDE.md');
    assert.match(squash(q(ctx.doc, 'new-convo-project-form')?.textContent), /Prefilled from CLAUDE\.md\./);
    assert.deepEqual(fileReads(ctx), [`${dir}/CLAUDE.md`], 'only the newer file is read');
    const read = ctx.calls.find((c) => c.path.endsWith('/fs/file'))!;
    assert.equal(read.path, '/api/v1/bridges/b_river/fs/file', 'bridge-scoped read route');
    assert.equal(read.query.get('limit'), String(16 * 1024));
    await click(ctx, createButton(ctx.doc));
    await until(ctx, () => ctx.created.length === 1, 'onCreated');
    assert.equal(await ctx.decrypt(lastCreate(ctx)!.body.description), '# Claude notes\nUse nix.', 'the prefill is sent vault-encrypted');
  });

  // The other way round: AGENTS.md is newer.
  const fs2: Fs = {
    dirs: { [dir]: [{ name: 'AGENTS.md', is_dir: false, modified_at: NEW }, { name: 'CLAUDE.md', is_dir: false, modified_at: OLD }] },
    files: { [`${dir}/AGENTS.md`]: { content: 'Agents first', modified_at: NEW }, [`${dir}/CLAUDE.md`]: { content: 'Claude second', modified_at: OLD } },
  };
  await withModal(fs2, {}, async (ctx) => {
    await enterFolder(ctx, dir);
    assert.equal(field(ctx.doc, 'new-convo-project-description-input').value, 'Agents first');
    assert.match(squash(q(ctx.doc, 'new-convo-project-form')?.textContent), /Prefilled from AGENTS\.md\./);
  });
});

test('a long file is cut at a line break and the hint says so; a truncated listing reads both files', async () => {
  const dir = `${ROOT}/big`;
  const long = Array.from({ length: 400 }, (_, i) => `line ${i} of the instructions`).join('\n');
  const fs: Fs = {
    dirs: { [dir]: [{ name: 'node_modules', is_dir: true }] },
    truncated: { [dir]: true },
    files: { [`${dir}/AGENTS.md`]: { content: long, modified_at: OLD }, [`${dir}/CLAUDE.md`]: { content: 'short', modified_at: '2026-01-01T00:00:00Z' } },
  };
  await withModal(fs, {}, async (ctx) => {
    await enterFolder(ctx, dir);
    assert.deepEqual(fileReads(ctx).sort(), [`${dir}/AGENTS.md`, `${dir}/CLAUDE.md`], 'listing was cut, so both files are read directly');
    const value = field(ctx.doc, 'new-convo-project-description-input').value;
    assert.ok(value.length <= 4000 && value.length > 2000, `capped (${value.length})`);
    assert.ok(value.endsWith('of the instructions'), 'cut at a line break');
    assert.match(squash(q(ctx.doc, 'new-convo-project-form')?.textContent), /Prefilled from AGENTS\.md \(first 4,000 characters\)\./);
  });
});

test('typed name and description are never overwritten; auto values follow a new folder', async () => {
  const fs: Fs = {
    dirs: { [`${ROOT}/one`]: [{ name: 'CLAUDE.md', is_dir: false, modified_at: NEW }], [`${ROOT}/two`]: [{ name: 'AGENTS.md', is_dir: false, modified_at: NEW }] },
    files: { [`${ROOT}/one/CLAUDE.md`]: { content: 'one notes', modified_at: NEW }, [`${ROOT}/two/AGENTS.md`]: { content: 'two notes', modified_at: NEW } },
  };
  // Auto values track the folder while untouched.
  await withModal(fs, {}, async (ctx) => {
    await enterFolder(ctx, `${ROOT}/one`);
    assert.equal(field(ctx.doc, 'new-convo-project-name-input').value, 'one');
    assert.equal(field(ctx.doc, 'new-convo-project-description-input').value, 'one notes');
    await enterFolder(ctx, `${ROOT}/two`);
    assert.equal(field(ctx.doc, 'new-convo-project-name-input').value, 'two', 'auto name follows the new folder');
    assert.equal(field(ctx.doc, 'new-convo-project-description-input').value, 'two notes', 'auto description follows too');
  });
  // Typed before choosing a folder: kept.
  await withModal(fs, {}, async (ctx) => {
    await type(ctx, q(ctx.doc, 'new-convo-project-name-input'), 'My project');
    await type(ctx, q(ctx.doc, 'new-convo-project-description-input'), 'My own words');
    await enterFolder(ctx, `${ROOT}/one`);
    assert.equal(field(ctx.doc, 'new-convo-project-name-input').value, 'My project');
    assert.equal(field(ctx.doc, 'new-convo-project-description-input').value, 'My own words');
    assert.doesNotMatch(squash(q(ctx.doc, 'new-convo-project-form')?.textContent), /Prefilled from/, 'no prefill claim over typed text');
  });
  // Edited after an auto fill: kept on the next folder.
  await withModal(fs, {}, async (ctx) => {
    await enterFolder(ctx, `${ROOT}/one`);
    await type(ctx, q(ctx.doc, 'new-convo-project-name-input'), 'renamed');
    await type(ctx, q(ctx.doc, 'new-convo-project-description-input'), 'one notes, edited');
    await enterFolder(ctx, `${ROOT}/two`);
    assert.equal(field(ctx.doc, 'new-convo-project-name-input').value, 'renamed');
    assert.equal(field(ctx.doc, 'new-convo-project-description-input').value, 'one notes, edited');
  });
});

test('read failures leave the description editable and never block Create', async () => {
  const dir = `${ROOT}/locked`;
  const fs: Fs = {
    dirs: { [dir]: [{ name: '.git', is_dir: true }, { name: 'CLAUDE.md', is_dir: false, modified_at: NEW }] },
    files: { [`${dir}/CLAUDE.md`]: { error: { code: 'unprocessable_entity', cause: 'vault_locked', message: 'Bridge vault is locked.' } } },
  };
  await withModal(fs, {}, async (ctx) => {
    await enterFolder(ctx, dir);
    assert.match(squash(q(ctx.doc, 'new-convo-project-inspect-note')?.textContent), /Couldn't read CLAUDE\.md: the bridge vault is locked\. You can type a description instead\./);
    assert.equal(field(ctx.doc, 'new-convo-project-description-input').value, '');
    assert.match(vcsValue(ctx.doc), /^Git/, 'detection still applied');
    await type(ctx, q(ctx.doc, 'new-convo-project-description-input'), 'typed instead');
    assert.ok(!createButton(ctx.doc).disabled);
    await click(ctx, createButton(ctx.doc));
    await until(ctx, () => ctx.created.length === 1, 'created despite the read failure');
    assert.equal(await ctx.decrypt(lastCreate(ctx)!.body.description), 'typed instead');
  });
  // The listing itself fails: a status line, and Create still works with the typed path.
  await withModal({ dirs: {}, failList: true }, {}, async (ctx) => {
    await enterFolder(ctx, `${ROOT}/somewhere`);
    assert.match(squash(q(ctx.doc, 'new-convo-project-inspect-note')?.textContent), /Couldn't reach the bridge to inspect the folder\./);
    assert.equal(field(ctx.doc, 'new-convo-project-name-input').value, 'somewhere');
    await click(ctx, createButton(ctx.doc));
    await until(ctx, () => ctx.created.length === 1, 'created despite the listing failure');
    const body = lastCreate(ctx)!.body;
    assert.equal(body.default_path, `${ROOT}/somewhere`);
    assert.equal(body.vcs_kind, 'none');
  });
});

test('without a usable bridge the modal explains why and Create stays off', async () => {
  await withModal({ dirs: {} }, { bridgeUsable: false }, async (ctx) => {
    assert.match(squash(q(ctx.doc, 'new-convo-project-no-bridge')?.textContent), /Choose an online bridge in the headline/);
    assert.ok((q(ctx.doc, 'new-convo-project-browse-btn') as HTMLButtonElement).disabled);
    assert.ok((q(ctx.doc, 'new-convo-project-folder-input') as HTMLInputElement).disabled);
    await type(ctx, q(ctx.doc, 'new-convo-project-name-input'), 'named');
    assert.ok(createButton(ctx.doc).disabled);
    assert.ok(!ctx.calls.some((c) => c.path.includes('/fs')), 'nothing is browsed');
  });
});

test('pure helpers: detectVcsKind, rankInstructionFiles, descriptionFromFile, folderBaseName', async () => {
  // Runs last: the hook module pulls in the API layer, which must not be evaluated
  // before the DOM tests above (see the chain's react-dom canUseDOM dead end).
  const h = await import('../src/ui/components/projects/useProjectFolderInspection.ts');
  assert.deepEqual(h.detectVcsKind([{ name: '.jj' }, { name: '.git' }]), { kind: 'jj', colocated: true });
  assert.deepEqual(h.detectVcsKind([{ name: '.jj' }]), { kind: 'jj', colocated: false });
  assert.deepEqual(h.detectVcsKind([{ name: '.git' }]), { kind: 'git', colocated: false });
  assert.deepEqual(h.detectVcsKind([{ name: 'agents.md' }]), { kind: 'none', colocated: false });
  assert.deepEqual(h.rankInstructionFiles([
    { name: 'agents.md', is_dir: false, modified_at: NEW }, { name: 'CLAUDE.md', is_dir: true, modified_at: NEW }, { name: 'AGENTS.md', is_dir: false, modified_at: OLD },
  ]).map((f) => f.name), ['AGENTS.md'], 'case-sensitive, files only');
  assert.deepEqual(h.rankInstructionFiles([{ name: 'CLAUDE.md', is_dir: false }, { name: 'AGENTS.md', is_dir: false, modified_at: OLD }]).map((f) => f.name), ['AGENTS.md', 'CLAUDE.md'], 'unknown mtime ranks last');
  assert.deepEqual(h.descriptionFromFile('  hi\r\n', 10), { text: 'hi', truncated: false });
  assert.deepEqual(h.descriptionFromFile('short', 10, true), { text: 'short', truncated: true }, 'more bytes on the bridge than one page');
  assert.equal(h.folderBaseName('/home/u/repo/'), 'repo');
  assert.equal(h.folderBaseName('C:\\work\\repo'), 'repo');
});
