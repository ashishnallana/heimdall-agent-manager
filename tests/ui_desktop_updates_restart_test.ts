import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { transformSync } from 'esbuild';
import { createPreparationRegistry, desktopUpdatePreparation, desktopUpdateMutationGuard } from '../src/ui/utils/desktopUpdatePreparation.ts';

const module = { exports: {} as any };
vm.runInNewContext(transformSync(fs.readFileSync(new URL('../src/ui/electron/desktopUpdateRestart.cts', import.meta.url), 'utf8'),
  { loader: 'ts', format: 'cjs' }).code, { module, exports: module.exports, setTimeout, clearTimeout });
const { createDesktopUpdateRestart } = module.exports;
const deferred = <T,>() => { let resolve!: (value: T) => void; const promise = new Promise<T>(r => { resolve = r; }); return { promise, resolve }; };

test('latest edit flushes under freeze; stale releases cannot unlock a newer epoch', async () => {
  const registry = createPreparationRegistry(); let draft = 'old'; let persisted = '';
  registry.register({ flush: () => { assert.equal(registry.frozen(), true); persisted = draft; } });
  draft = 'latest keystroke';
  assert.equal(await registry.prepare(1), true); assert.equal(persisted, 'latest keystroke');
  registry.release(0); assert.equal(registry.frozen(), true);
  registry.release(1); assert.equal(registry.frozen(), false);
  assert.equal(await registry.prepare(1), false, 'stale prepare');
  assert.equal(await registry.prepare(2), true);
  registry.release(1); assert.equal(registry.frozen(), true); registry.release(2);
});

test('storage failures, missing coverage and pending uploads refuse readiness', async () => {
  const registry = createPreparationRegistry(); assert.equal(await registry.prepare(1), false);
  let pending = true;
  const remove = registry.register({ blocked: () => pending, flush: () => {} });
  assert.equal(await registry.prepare(2), false); assert.equal(registry.frozen(), false);
  pending = false; remove();
  registry.register({ flush: () => { throw new Error('quota'); } });
  assert.equal(await registry.prepare(3), false); assert.equal(registry.frozen(), false);
});

test('release during delayed flush cannot acknowledge readiness', async () => {
  const registry = createPreparationRegistry(); const flush = deferred<void>();
  registry.register({ flush: () => flush.promise });
  const pending = registry.prepare(1); registry.release(1); flush.resolve();
  assert.equal(await pending, false);
});

test('layout and composer dispatch boundaries reject delayed mutations while frozen', async () => {
  const remove = desktopUpdatePreparation.register({ flush: () => {} });
  await desktopUpdatePreparation.prepare(10);
  const actions: string[] = [];
  const dispatch = desktopUpdateMutationGuard()((action: any) => actions.push(action.type));
  for (const type of ['workspaceLayout/resize', 'workspaceChrome/setAuxWidth', 'auxPanes/open', 'composerContext/clear']) dispatch({ type });
  assert.deepEqual(actions, []);
  desktopUpdatePreparation.release(10); dispatch({ type: 'workspaceLayout/resize' });
  assert.deepEqual(actions, ['workspaceLayout/resize']); remove();
});

function fixture() {
  let document: any = {}; let busy = false; let eligible = true; let installs = 0; let cancellations = 0;
  let phase = 'downloaded'; let target = '1.2.4'; const releases: number[] = [];
  const prepare = deferred<boolean>(); const confirm = deferred<boolean>();
  const native = deferred<void>(); const timers = new Set<() => void>();
  let gate: () => boolean = () => false;
  const restart = createDesktopUpdateRestart({
    controller: { getState: () => ({ phase, targetVersion: target }), beginRestart: () => { if (phase !== 'downloaded') return false; phase = 'preparing-restart'; return true; }, abortRestart: () => { phase = 'downloaded'; } },
    bridgeBusy: () => busy, eligibility: () => eligible, document: () => document,
    prepare: () => prepare.promise, release: (epoch: number) => releases.push(epoch), confirm: () => confirm.promise,
    install: (final: () => boolean) => { gate = final; return native.promise; }, cancelInstall: () => { cancellations++; },
    clock: { setTimeout: (fn: () => void) => { timers.add(fn); return fn; }, clearTimeout: (fn: () => void) => timers.delete(fn) },
  });
  return { restart, prepare, confirm, native, timers, releases, cancellations: () => cancellations,
    changeDocument: () => { document = {}; }, bridgeBusy: () => { busy = true; }, disable: () => { eligible = false; }, changeTarget: () => { target = '1.2.5'; },
    complete: () => { if (gate()) installs++; native.resolve(); }, installs: () => installs };
}
async function prepared(f: ReturnType<typeof fixture>) { f.prepare.resolve(true); await Promise.resolve(); await Promise.resolve(); await Promise.resolve(); }
async function consented(f: ReturnType<typeof fixture>) { f.confirm.resolve(true); await Promise.resolve(); await Promise.resolve(); await Promise.resolve(); }

test('restart holds exclusion across preparation, confirmation and delayed native completion', async () => {
  const f = fixture(); const pending = f.restart.restart();
  assert.equal(f.restart.held(), true); assert.equal((await f.restart.restart()).ok, false);
  await prepared(f); assert.equal(f.restart.held(), true); assert.equal(f.installs(), 0);
  await consented(f); assert.equal(f.restart.held(), true); assert.equal(f.installs(), 0);
  f.complete(); assert.equal((await pending).ok, true); assert.equal(f.installs(), 1);
  assert.equal(f.restart.exiting(), true); assert.deepEqual(f.releases, []);
});
test('Later and timeout release guards, even if renderer never acknowledges', async () => {
  const later = fixture(); const pending = later.restart.restart(); await prepared(later); later.confirm.resolve(false);
  assert.equal((await pending).ok, false); assert.equal(later.restart.held(), false); assert.deepEqual(later.releases, [1]);
  const timeout = fixture(); const hung = timeout.restart.restart();
  for (const fn of timeout.timers) fn(); assert.equal((await hung).ok, false);
  assert.equal(timeout.restart.held(), false); assert.equal(timeout.cancellations(), 1);
});
test('navigation, eligibility, version and Bridge races fail the synchronous final gate', async () => {
  for (const invalidate of ['changeDocument', 'disable', 'changeTarget', 'bridgeBusy'] as const) {
    const f = fixture(); const pending = f.restart.restart(); await prepared(f); await consented(f);
    f[invalidate](); f.complete();
    assert.equal(f.installs(), 0, invalidate);
    // The actual install adapter rejects a failed gate; invalidate/abort releases the transaction.
    f.restart.abort(); await pending; assert.equal(f.restart.held(), false);
  }
});
test('abort during native staging disarms before release and a late completion cannot quit', async () => {
  const f = fixture(); const pending = f.restart.restart(); await prepared(f); await consented(f);
  f.restart.abort(); assert.equal((await pending).ok, false);
  f.complete(); assert.equal(f.installs(), 0); assert.equal(f.restart.exiting(), false); assert.deepEqual(f.releases, [1]);
});
