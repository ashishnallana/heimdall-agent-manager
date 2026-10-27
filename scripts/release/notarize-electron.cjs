const { notarize } = require('@electron/notarize');

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
  const appPath = `${context.appOutDir}/${context.packager.appInfo.productFilename}.app`;
  await notarize({ appPath, appleId, appleIdPassword, teamId });
};
