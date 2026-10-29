#!/usr/bin/env node
import { existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { resolve } from 'node:path';

const APP_NAME = 'Ninjy';
const BUNDLE_ID = 'works.earendil.heimdall.dev';
const plistPath = resolve('node_modules/electron/dist/Electron.app/Contents/Info.plist');

if (process.platform !== 'darwin' || !existsSync(plistPath)) process.exit(0);

function plutil(args) {
  execFileSync('/usr/bin/plutil', args, { stdio: 'ignore' });
}

try {
  plutil(['-replace', 'CFBundleName', '-string', APP_NAME, plistPath]);
  plutil(['-replace', 'CFBundleDisplayName', '-string', APP_NAME, plistPath]);
  plutil(['-replace', 'CFBundleIdentifier', '-string', BUNDLE_ID, plistPath]);
} catch (err) {
  console.warn(`[heimdall] warning: unable to patch Electron.app display name: ${err?.message || err}`);
}
