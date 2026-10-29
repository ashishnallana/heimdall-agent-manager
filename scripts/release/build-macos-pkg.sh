#!/usr/bin/env bash
set -euo pipefail

# REQ-ENR-4: the macOS installer offers App, Bridge, or both. electron-builder's
# pkg target cannot express choices, so this assembles one product archive from
# two component packages:
#   app    - the signed Heimdall.app, installed into /Applications
#   bridge - payload-free; its postinstall runs the bundled install.sh (verify
#            the staged bundle + exec `ham-bridge setup --interactive`) as the
#            logged-in user, so ham-bridge opens the approval page in a browser
# The Installer's Customize pane (customize="always") shows both, both ticked.
#
# Signing: with HEIMDALL_MACOS_INSTALLER_IDENTITY ("Developer ID Installer: …")
# the product archive is signed; notarizing and stapling stay with the caller.
usage() {
  echo 'usage: build-macos-pkg.sh <Heimdall.app> <bridge-resources-dir> <version> <arm64|x64> <out.pkg>' >&2
}

[ "$#" -eq 5 ] || { usage; exit 2; }
app="$1"
bridge_dir="$2"
version="${3#v}"
arch="$4"
out="$5"

case "$arch" in arm64) host_arch=arm64; target=darwin-arm64 ;; x64) host_arch=x86_64; target=darwin-amd64 ;; *) usage; exit 2 ;; esac
[ -d "$app" ] || { echo "missing app bundle: $app" >&2; exit 1; }
archive="heimdall-local-$target.tar.gz"
for f in install.sh SHA256SUMS "$archive"; do
  [ -f "$bridge_dir/$f" ] || { echo "missing staged Bridge file: $bridge_dir/$f" >&2; exit 1; }
done

work="$(mktemp -d "${TMPDIR:-/tmp}/heimdall-pkg.XXXXXX")"
trap "$(printf 'rm -rf %q' "$work")" EXIT

# Component 1: the app (no relocation, so a moved copy is not silently updated).
mkdir -p "$work/app-root"
ditto "$app" "$work/app-root/$(basename "$app")"
pkgbuild --analyze --root "$work/app-root" "$work/app.plist" >/dev/null
/usr/libexec/PlistBuddy -c 'Set :0:BundleIsRelocatable false' "$work/app.plist"
pkgbuild --root "$work/app-root" --component-plist "$work/app.plist" \
  --install-location /Applications \
  --identifier works.earendil.heimdall.app --version "$version" "$work/app.pkg"

# Component 2: the Bridge. The scripts directory carries the bundle itself.
mkdir -p "$work/bridge-scripts"
install -m 0755 "$bridge_dir/install.sh" "$work/bridge-scripts/install.sh"
install -m 0644 "$bridge_dir/SHA256SUMS" "$work/bridge-scripts/SHA256SUMS"
install -m 0644 "$bridge_dir/$archive" "$work/bridge-scripts/$archive"
install -m 0755 scripts/release/macos-pkg-bridge-postinstall.sh "$work/bridge-scripts/postinstall"
pkgbuild --nopayload --scripts "$work/bridge-scripts" \
  --identifier works.earendil.heimdall.bridge --version "$version" "$work/bridge.pkg"

cat > "$work/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>Heimdall</title>
  <options customize="always" require-scripts="false" hostArchitectures="$host_arch"/>
  <domains enable_localSystem="true"/>
  <choices-outline>
    <line choice="app"/>
    <line choice="bridge"/>
  </choices-outline>
  <choice id="app" title="Heimdall App" description="The Heimdall desktop app, installed in Applications.">
    <pkg-ref id="works.earendil.heimdall.app"/>
  </choice>
  <choice id="bridge" title="Heimdall Bridge" description="Connects this Mac to your Heimdall Hub so agents can run here. Setup opens your browser to approve this Mac.">
    <pkg-ref id="works.earendil.heimdall.bridge"/>
  </choice>
  <pkg-ref id="works.earendil.heimdall.app" version="$version" onConclusion="none">app.pkg</pkg-ref>
  <pkg-ref id="works.earendil.heimdall.bridge" version="$version" onConclusion="none">bridge.pkg</pkg-ref>
</installer-gui-script>
XML

sign=()
if [ -n "${HEIMDALL_MACOS_INSTALLER_IDENTITY:-}" ]; then
  sign=(--sign "$HEIMDALL_MACOS_INSTALLER_IDENTITY" --timestamp)
fi
mkdir -p "$(dirname "$out")"
productbuild --distribution "$work/distribution.xml" --package-path "$work" ${sign[@]+"${sign[@]}"} "$out"
echo "$out"
