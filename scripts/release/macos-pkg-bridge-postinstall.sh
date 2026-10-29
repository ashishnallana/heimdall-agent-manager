#!/bin/bash
# postinstall of the Heimdall .pkg "Heimdall Bridge" choice (build-macos-pkg.sh).
# Installer runs this as root from a root-only scripts directory; the Bridge is a
# per-user launchd service, so the staged bundle is handed to the logged-in
# console user, and install.sh (verify + exec `ham-bridge setup`) runs in that
# user's GUI session, where ham-bridge can open the approval page.
#
# Hub: https://hub.brolabs.ai, or an MDM/admin override:
#   sudo defaults write /Library/Preferences/works.earendil.heimdall HubURL https://hub.example.com
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

# A failing postinstall makes Installer report the whole install as failed. When
# the App choice was installed too (its package runs first), the app is usable
# and finishes the Bridge from Settings > Bridges, so report success with a hint;
# for "Bridge only" the failure is real.
bridge_failed() {
  echo "Heimdall Bridge: $1; set it up later from the Heimdall app (Settings > Bridges)." >&2
  if [ -d /Applications/Heimdall.app ]; then exit 0; fi
  exit 1
}

user="$(stat -f %Su /dev/console)"
case "$user" in
  ''|root|loginwindow|_mbsetupuser) bridge_failed 'nobody is logged in at the console' ;;
esac
uid="$(id -u "$user")"
hub="$(defaults read /Library/Preferences/works.earendil.heimdall HubURL 2>/dev/null || true)"
[ -n "$hub" ] || hub=https://hub.brolabs.ai

archive="$(cd "$here" && ls heimdall-local-darwin-*.tar.gz)"
work="$(mktemp -d /tmp/heimdall-pkg-bridge.XXXXXX)"
trap "$(printf 'rm -rf %q' "$work")" EXIT
cp "$here/install.sh" "$here/SHA256SUMS" "$here/$archive" "$work/"
chown -R "$user" "$work"

launchctl asuser "$uid" sudo -u "$user" -H /bin/bash "$work/install.sh" \
  --bundle "$work/$archive" --checksum-file "$work/SHA256SUMS" --hub "$hub" --interactive \
  || bridge_failed "setup exited with status $?"
