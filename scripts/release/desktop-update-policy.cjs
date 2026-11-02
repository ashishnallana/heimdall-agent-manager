const fs = require('node:fs');
const path = require('node:path');

// afterPack runs before app signing. A signed app owns this marker; it is not
// a renderer preference or proof that external credentials are configured.
module.exports = async function desktopUpdatePolicy(context) {
  const platform = context.electronPlatformName;
  const signed = process.env.HEIMDALL_DESKTOP_SIGNED_RELEASE === '1';
  const publisher = String(process.env.HEIMDALL_WINDOWS_PUBLISHER_NAME || '').trim();
  const version = context.packager.appInfo.version;
  const targets = context.targets.map(target => target.name);
  if (signed && platform === 'win32' && (targets.length !== 1 || targets[0] !== 'nsis')) throw new Error('Signed Windows updates require only the NSIS target');
  if (signed && platform === 'darwin' && (!targets.includes('zip') || targets.some(target => !['zip', 'dmg'].includes(target)))) throw new Error('Signed macOS updates require ZIP and supported app targets');
  if (signed && !/^\d+\.\d+\.\d+$/.test(version)) throw new Error('Desktop updates support numeric stable/candidate versions only');
  let enabled = false;
  let publishers;
  if (signed && platform === 'darwin') {
    for (const key of ['CSC_NAME', 'APPLE_ID', 'APPLE_APP_SPECIFIC_PASSWORD', 'APPLE_TEAM_ID']) {
      if (!process.env[key]) throw new Error(`Signed desktop release requires ${key}`);
    }
    if (!context.packager.config.forceCodeSigning) throw new Error('Signed desktop release requires forceCodeSigning');
    enabled = true;
  } else if (signed && platform === 'win32') {
    const configured = context.packager.platformSpecificBuildOptions.publisherName;
    publishers = typeof configured === 'string' ? [configured] : configured;
    if (!publisher || !Array.isArray(publishers) || publishers.length !== 1 || publishers[0] !== publisher
      || !process.env.CSC_LINK || !process.env.CSC_KEY_PASSWORD || !context.packager.config.forceCodeSigning
      || context.packager.platformSpecificBuildOptions.verifyUpdateCodeSignature === false) {
      throw new Error('Signed Windows release requires configured publisher, signing access and signature verification');
    }
    enabled = true;
  }
  const resources = platform === 'darwin'
    ? path.join(context.appOutDir, `${context.packager.appInfo.productFilename}.app`, 'Contents', 'Resources')
    : path.join(context.appOutDir, 'resources');
  fs.mkdirSync(resources, { recursive: true });
  const policy = { schemaVersion: 1, distribution: platform === 'darwin' ? 'mac-app' : platform === 'win32' ? 'windows-nsis' : 'package-managed',
    updatesEnabled: enabled, ...(enabled && publishers ? { publisherName: publishers } : {}) };
  fs.writeFileSync(path.join(resources, 'desktop-update-policy.json'), JSON.stringify(policy) + '\n');
};
