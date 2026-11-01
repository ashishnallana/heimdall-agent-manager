import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const source = fs.readFileSync(new URL('../scripts/release/desktop-update-policy.cjs', import.meta.url), 'utf8');
function hook(env: Record<string, string> = {}) {
  const module = { exports: null as any };
  vm.runInNewContext(source, { module, exports: {}, require, process: { env } });
  return module.exports;
}
function context(directory: string, platform = 'win32', targets = ['nsis']) {
  return { appOutDir: directory, electronPlatformName: platform, targets: targets.map(name => ({ name })),
    packager: { appInfo: { version: '1.2.4', productFilename: 'Ninjy' }, config: { forceCodeSigning: true },
      platformSpecificBuildOptions: { publisherName: ['Fixture Publisher'], verifyUpdateCodeSignature: true } } };
}

test('unsigned manual builds disable updater; signed Windows packaging requires publisher, credentials and NSIS only', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'ninjy-update-policy-'));
  try {
    const ctx = context(directory);
    await hook()(ctx);
    const marker = () => JSON.parse(fs.readFileSync(path.join(directory, 'resources/desktop-update-policy.json'), 'utf8'));
    assert.equal(marker().updatesEnabled, false);
    await assert.rejects(hook({ HEIMDALL_DESKTOP_SIGNED_RELEASE: '1' })(ctx), /publisher/);
    const env = { HEIMDALL_DESKTOP_SIGNED_RELEASE: '1', HEIMDALL_WINDOWS_PUBLISHER_NAME: 'Fixture Publisher', CSC_LINK: 'fixture-not-a-certificate', CSC_KEY_PASSWORD: 'fixture-not-a-password' };
    await hook(env)(ctx); assert.deepEqual(marker().publisherName, ['Fixture Publisher']); assert.equal(marker().updatesEnabled, true);
    await assert.rejects(hook(env)(context(directory, 'win32', ['portable'])), /only the NSIS/);
    await assert.rejects(hook(env)(context(directory, 'win32', ['nsis', 'portable'])), /only the NSIS/);
    await assert.rejects(hook(env)({ ...ctx, packager: { ...ctx.packager, config: { forceCodeSigning: false } } }), /signing access/);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});

test('macOS signed marker requires ZIP, forced signing, notarization inputs and numeric release version', async () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'ninjy-update-policy-'));
  try {
    const ctx = context(directory, 'darwin', ['dmg', 'zip']);
    const env = { HEIMDALL_DESKTOP_SIGNED_RELEASE: '1', CSC_NAME: 'Fixture Identity', APPLE_ID: 'fixture', APPLE_APP_SPECIFIC_PASSWORD: 'fixture', APPLE_TEAM_ID: 'fixture' };
    await assert.rejects(hook({ HEIMDALL_DESKTOP_SIGNED_RELEASE: '1' })(ctx), /requires CSC_NAME/);
    await hook(env)(ctx);
    const marker = JSON.parse(fs.readFileSync(path.join(directory, 'Ninjy.app/Contents/Resources/desktop-update-policy.json'), 'utf8'));
    assert.equal(marker.updatesEnabled, true); assert.equal(marker.distribution, 'mac-app');
    await assert.rejects(hook(env)(context(directory, 'darwin', ['mas'])), /ZIP/);
    ctx.packager.appInfo.version = '1.2.4-beta.1'; await assert.rejects(hook(env)(ctx), /numeric/);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});

test('builder and release workflows parse and preserve signing/promotion validation wiring', () => {
  const { load } = require('js-yaml');
  const builder = load(fs.readFileSync(new URL('../electron-builder.yml', import.meta.url), 'utf8'));
  assert.equal(builder.win.verifyUpdateCodeSignature, true);
  assert.equal(builder.afterPack, 'scripts/release/desktop-update-policy.cjs');
  for (const name of ['release-local-binaries.yml', 'promote-release.yml']) {
    const text = fs.readFileSync(new URL(`../.github/workflows/${name}`, import.meta.url), 'utf8');
    assert.ok(load(text).jobs); assert.match(text, /validate-desktop-updates\.py/);
  }
});
