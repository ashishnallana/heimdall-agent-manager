// REQ-ENR-4 / F13 / F14: the Linux first-launch App / Bridge / both choice and
// which packaged desktop apps self-update.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';
import { transformSync } from 'esbuild';

const nodeRequire = createRequire(import.meta.url);

function loadCts(name: string, requireImpl: (id: string) => any = nodeRequire) {
  const source = fs.readFileSync(new URL(`../src/ui/electron/${name}.cts`, import.meta.url), 'utf8');
  const module = { exports: {} as any };
  vm.runInNewContext(transformSync(source, { loader: 'ts', format: 'cjs' }).code,
    { module, exports: module.exports, require: requireImpl, process, setTimeout, clearTimeout, setInterval, clearInterval, Date, JSON });
  return module.exports;
}

const installChoice = loadCts('installChoice');
// Objects from the vm context have that realm's prototypes; compare plain copies.
const plain = (value: any) => JSON.parse(JSON.stringify(value));

function tempMarker() {
  return path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'heimdall-choice-')), 'userData', 'install-choice.json');
}

function deps(response: number, setupResult = { ok: true } as { ok: boolean; error?: string }) {
  const boxes: any[] = [];
  let setups = 0;
  const markerPath = tempMarker();
  return {
    boxes,
    setups: () => setups,
    deps: {
      markerPath,
      packageKind: 'appimage' as const,
      showMessageBox: async (options: any) => { boxes.push(options); return { response: boxes.length === 1 ? response : 0 }; },
      setupBridge: async () => { setups += 1; return setupResult; },
    },
  };
}

test('only a packaged Linux app without an answer asks', () => {
  const marker = tempMarker();
  assert.equal(installChoice.shouldAsk('linux', true, marker), true);
  assert.equal(installChoice.shouldAsk('linux', false, marker), false);
  assert.equal(installChoice.shouldAsk('win32', true, marker), false, 'Windows asks in the NSIS installer');
  assert.equal(installChoice.shouldAsk('darwin', true, marker), false, 'macOS asks in the .pkg');
  fs.mkdirSync(path.dirname(marker), { recursive: true });
  fs.writeFileSync(marker, '{"choice":"app"}\n');
  assert.equal(installChoice.shouldAsk('linux', true, marker), false, 'asked once');
});

test('App only opens the window and sets up no Bridge', async () => {
  const f = deps(1);
  assert.deepEqual(plain(await installChoice.runFirstLaunch(f.deps)), { openWindow: true, choice: 'app' });
  assert.equal(f.setups(), 0);
  assert.equal(JSON.parse(fs.readFileSync(f.deps.markerPath, 'utf8')).choice, 'app');
  assert.deepEqual(plain(f.boxes[0].buttons), ['App and Bridge', 'App only', 'Bridge only']);
});

test('App and Bridge opens the window and runs Bridge setup', async () => {
  const f = deps(0);
  assert.deepEqual(plain(await installChoice.runFirstLaunch(f.deps)), { openWindow: true, choice: 'both' });
  assert.equal(f.setups(), 1);
});

test('Bridge only runs setup, never opens the window, and says the app can go', async () => {
  const f = deps(2);
  assert.deepEqual(plain(await installChoice.runFirstLaunch(f.deps)), { openWindow: false, choice: 'bridge' });
  assert.equal(f.setups(), 1);
  assert.match(f.boxes[1].detail, /delete the Heimdall AppImage/);
});

test('a failed Bridge-only setup is reported and points at Settings > Bridges', async () => {
  const f = deps(2, { ok: false, error: 'approval timed out' });
  assert.deepEqual(plain(await installChoice.runFirstLaunch(f.deps)), { openWindow: false, choice: 'bridge' });
  assert.equal(f.boxes[1].type, 'error');
  assert.match(f.boxes[1].detail, /approval timed out/);
  assert.match(f.boxes[1].detail, /Settings > Bridges/);
});

test('dismissing the dialog counts as App only', async () => {
  const f = deps(7);
  assert.equal((await installChoice.runFirstLaunch(f.deps)).choice, 'app');
});

test('package kind comes from APPIMAGE', () => {
  assert.equal(installChoice.packageKind({ APPIMAGE: '/home/u/Heimdall.AppImage' }), 'appimage');
  assert.match(installChoice.removalHint('deb'), /apt remove heimdall/);
});

test('desktop auto-update covers Windows, macOS and AppImage, never dev or deb', () => {
  const updater = loadCts('desktopUpdater', (id: string) => (id === 'electron-updater' ? { autoUpdater: {} } : nodeRequire(id)));
  assert.equal(updater.supported('win32', true, {}), true);
  assert.equal(updater.supported('darwin', true, {}), true, 'F14: macOS updates from the zip');
  assert.equal(updater.supported('linux', true, { APPIMAGE: '/x.AppImage' }), true);
  assert.equal(updater.supported('linux', true, {}), false, 'a deb is updated by reinstalling it');
  assert.equal(updater.supported('darwin', false, {}), false, 'dev runs never self-update');
});
