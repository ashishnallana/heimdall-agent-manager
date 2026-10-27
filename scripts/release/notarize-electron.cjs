const { spawnSync } = require('node:child_process');
const path = require('node:path');

function retryStaple(appPath) {
  const script = path.join(__dirname, 'staple-with-retry.sh');
  const result = spawnSync(script, [appPath], { env: process.env, stdio: 'inherit' });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`Failed to staple notarized application after bounded retries (exit ${result.status ?? 'signal'})`);
  }
}

/** REQ-DMG-1: electron-builder afterSign hook. */
exports.default = async function notarizeDesktop(context) {
  if (process.platform !== 'darwin') return;
  // Local packaging smoke tests can exercise app assembly without contacting
  // Apple's service. Release CI never sets this and still fails closed below.
  if (process.env.HEIMDALL_SKIP_NOTARIZE === '1') return;
  const appleId = process.env.APPLE_ID;
  const appleIdPassword = process.env.APPLE_APP_SPECIFIC_PASSWORD;
  const teamId = process.env.APPLE_TEAM_ID;
  if (!appleId || !appleIdPassword || !teamId) {
    throw new Error('APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, and APPLE_TEAM_ID are required to notarize the macOS DMG');
  }
  // @electron/notarize 3.x is ESM. Keep the electron-builder hook CommonJS,
  // but load the package through its supported dynamic-import boundary.
  const { notarize } = await import('@electron/notarize');
  const appPath = `${context.appOutDir}/${context.packager.appInfo.productFilename}.app`;
  try {
    await notarize({ appPath, appleId, appleIdPassword, teamId });
  } catch (error) {
    // REQ-DMG-4: @electron/notarize has already received Apple's Accepted
    // result when this exact error is raised. Retry only ticket stapling so a
    // transient CloudKit lookup failure does not resubmit the app.
    if (!String(error?.message || error).includes('Failed to staple your application')) throw error;
    console.warn('Apple accepted the notarization, but ticket stapling was temporarily unavailable; retrying.');
    retryStaple(appPath);
  }
};
