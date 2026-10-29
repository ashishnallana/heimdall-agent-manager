const APP_ID = 'works.earendil.heimdall';

// CommandLineToArgvW quoting: spaces, quotes and trailing backslashes must
// survive Explorer relaunching a pinned shortcut.
function quoteArgument(value: string): string {
  return '"' + value.replace(/(\\*)"/g, '$1$1\\"').replace(/(\\+)$/g, '$1$1') + '"';
}

function taskbarDetails(platform: string, packaged: boolean, executable: string, entry: string, icon: string) {
  if (platform !== 'win32') return null;
  return {
    appId: APP_ID,
    appIconPath: packaged ? executable : icon,
    appIconIndex: 0,
    relaunchDisplayName: 'Ninjy',
    // An unpackaged Electron executable needs the app entry argument. Without
    // it, a pin opens Electron's welcome page instead of Heimdall.
    relaunchCommand: [executable, ...(packaged ? [] : [entry])].map(quoteArgument).join(' '),
  };
}

export = { APP_ID, taskbarDetails };
