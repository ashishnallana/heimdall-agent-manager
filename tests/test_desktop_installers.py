"""REQ-ENR-4 / F13 / F14: per-OS desktop installers offer App, Bridge, or both;
release CI builds the Linux app; macOS and Windows (and the AppImage) self-update."""

from pathlib import Path
import io
import json
import os
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MERGE = ROOT / 'scripts/release/merge-latest-mac.py'
STAGE = ROOT / 'scripts/release/stage-macos-desktop-resources.sh'


def read(name: str) -> str:
    return (ROOT / name).read_text()


def latest_mac(version: str, arch: str) -> str:
    suffix = f'-{arch}'
    return (
        f'version: {version}\n'
        'files:\n'
        f'  - url: Heimdall-{version}{suffix}.zip\n'
        f'    sha512: zip{arch}==\n'
        '    size: 100\n'
        f'  - url: Heimdall-{version}{suffix}.dmg\n'
        f'    sha512: dmg{arch}==\n'
        '    size: 200\n'
        f'path: Heimdall-{version}{suffix}.zip\n'
        f'sha512: zip{arch}==\n'
        "releaseDate: '2026-10-29T08:00:00.000Z'\n"
    )


class MergeLatestMacTests(unittest.TestCase):
    def run_merge(self, *texts):
        with tempfile.TemporaryDirectory() as td:
            paths = []
            for i, text in enumerate(texts):
                p = Path(td) / f'{i}.yml'
                p.write_text(text)
                paths.append(str(p))
            return subprocess.run(['python3', str(MERGE), *paths], capture_output=True, text=True)

    def test_both_arches_land_in_one_document(self):
        res = self.run_merge(latest_mac('1.2.3', 'x64'), latest_mac('1.2.3', 'arm64'))
        self.assertEqual(res.returncode, 0, res.stderr)
        out = res.stdout
        self.assertEqual(out.count('  - url: '), 4)
        for name in ('x64.zip', 'x64.dmg', 'arm64.zip', 'arm64.dmg'):
            self.assertIn(f'  - url: Heimdall-1.2.3-{name}\n', out)
        # The base (x64) keeps the legacy single-file fields.
        self.assertIn('path: Heimdall-1.2.3-x64.zip\n', out)
        self.assertTrue(out.startswith('version: 1.2.3\nfiles:\n'))
        self.assertEqual(out.count('version: '), 1)
        self.assertEqual(out.count('releaseDate: '), 1)

    def test_version_mismatch_and_duplicates_fail(self):
        res = self.run_merge(latest_mac('1.2.3', 'x64'), latest_mac('1.2.4', 'arm64'))
        self.assertNotEqual(res.returncode, 0)
        self.assertIn('version', res.stderr)
        res = self.run_merge(latest_mac('1.2.3', 'x64'), latest_mac('1.2.3', 'x64'))
        self.assertNotEqual(res.returncode, 0)
        self.assertIn('duplicate', res.stderr)

    def test_unexpected_shape_fails(self):
        res = self.run_merge('version: 1\n', latest_mac('1', 'arm64'))
        self.assertNotEqual(res.returncode, 0)


class StageResourcesTests(unittest.TestCase):
    def stage(self, target: str, signed: bool):
        td = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, td)
        bundle = Path(td) / f'heimdall-local-{target}.tar.gz'
        meta = json.dumps({'version': 'v1.2.3', 'target': target, 'developer_id_signed': signed}).encode()
        with tarfile.open(bundle, 'w:gz') as tf:
            info = tarfile.TarInfo('METADATA.json')
            info.size = len(meta)
            tf.addfile(info, io.BytesIO(meta))
        out = Path(td) / 'out'
        res = subprocess.run(['bash', str(STAGE), target, str(bundle), 'v1.2.3', str(out)],
                             cwd=ROOT, capture_output=True, text=True)
        return res, out

    def test_linux_targets_stage_without_developer_id(self):
        res, out = self.stage('linux-amd64', signed=False)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertTrue((out / 'heimdall-local-linux-amd64.tar.gz').is_file())
        self.assertIn('heimdall-local-linux-amd64.tar.gz', (out / 'SHA256SUMS').read_text())
        self.assertTrue((out / 'install.sh').is_file())

    def test_macos_still_requires_developer_id(self):
        res, _ = self.stage('darwin-arm64', signed=False)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn('not Developer ID signed', res.stderr)


NSIS_HARNESS = r'''
Unicode true
Name "Heimdall"
OutFile "harness.exe"
RequestExecutionLevel user
InstallDir "$LOCALAPPDATA\Programs\heimdall"
!define UNINSTALL_FILENAME "Uninstall Heimdall.exe"
!define isUpdated "1 = 0"
; Stand-ins for electron-builder's UAC.nsh (its UAC.dll ships only with
; electron-builder's NSIS bundle): @INNER@ picks the elevated per-machine path.
!define UAC_IsInnerInstance "@INNER@"
!define UAC_SYNCREGISTERS 0x1
!define UAC_SYNCINSTDIR 0x8
!macro UAC_AsUser_Call type name flags
  Call ${name}
!macroend
!include "@INCLUDE@"
!include MUI2.nsh
Var launchLink
!macro StartApp
  ExecShell "open" "$launchLink"
!macroend
Function .onInit
  !insertmacro customInit
FunctionEnd
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro customPageAfterChangeDir
!insertmacro MUI_PAGE_INSTFILES
!insertmacro customFinishPage
!insertmacro MUI_LANGUAGE "English"
Section "install"
  SetOutPath $INSTDIR
  StrCpy $launchLink "$INSTDIR\Heimdall.exe"
  !insertmacro customInstall
SectionEnd
'''


class WindowsInstallerTests(unittest.TestCase):
    def test_components_page_contract(self):
        nsh = read('build/installer.nsh')
        config = read('electron-builder.yml')
        self.assertIn('include: build/installer.nsh', config)
        for label in ('App and Bridge (recommended)', 'App only', 'Bridge only'):
            self.assertIn(label, nsh)
        self.assertIn('install.ps1" -Bundle "$INSTDIR\\resources\\bridge\\heimdall-local-windows-amd64.zip"', nsh)
        self.assertIn('-Interactive', nsh)
        # Auto-updates (--updated) never re-run Bridge setup or remove the app.
        self.assertIn('${IfNot} ${isUpdated}', nsh)
        self.assertIn('/COMPONENTS=', nsh)
        # Per-machine installs run sections elevated; Bridge setup must go back to the user.
        self.assertIn('${If} ${UAC_IsInnerInstance}', nsh)
        self.assertIn('!insertmacro UAC_AsUser_Call Function HeimdallBridgeSetupAsUser '
                      '${UAC_SYNCREGISTERS}|${UAC_SYNCINSTDIR}', nsh)
        as_user = nsh.split('Function HeimdallBridgeSetupAsUser', 1)[1].split('FunctionEnd', 1)[0]
        self.assertIn('-Hub "$1" -Interactive\' $0', as_user)
        self.assertNotIn('$HeimdallHub', as_user)  # outer instance never ran the page/customInit state

    @unittest.skipUnless(shutil.which('makensis') or os.environ.get('MAKENSIS'), 'makensis not available')
    def test_include_compiles_with_warnings_as_errors(self):
        makensis = os.environ.get('MAKENSIS') or shutil.which('makensis')
        with tempfile.TemporaryDirectory() as td:
            # Per-user install (sections run as the user) and per-machine (elevated inner instance).
            for inner in ('1 = 0', '1 = 1'):
                harness = Path(td) / 'harness.nsi'
                harness.write_text(NSIS_HARNESS.replace('@INCLUDE@', str(ROOT / 'build/installer.nsh'))
                                   .replace('@INNER@', inner))
                res = subprocess.run([makensis, '-WX', '-V2', str(harness)], capture_output=True, text=True, cwd=td)
                self.assertEqual(res.returncode, 0, inner + '\n' + res.stdout + res.stderr)
            # electron-builder includes the file in the uninstaller build too.
            un = Path(td) / 'un.nsi'
            un.write_text(f'Unicode true\nName "u"\nOutFile "un.exe"\n!define BUILD_UNINSTALLER\n'
                          f'!include "{ROOT / "build/installer.nsh"}"\nSection\nSectionEnd\n')
            res = subprocess.run([makensis, '-WX', '-V2', str(un)], capture_output=True, text=True, cwd=td)
            self.assertEqual(res.returncode, 0, res.stdout + res.stderr)


class MacAndLinuxInstallerTests(unittest.TestCase):
    def test_macos_pkg_offers_app_and_bridge_choices(self):
        script = read('scripts/release/build-macos-pkg.sh')
        post = read('scripts/release/macos-pkg-bridge-postinstall.sh')
        self.assertIn('customize="always"', script)
        self.assertIn('<choice id="app"', script)
        self.assertIn('<choice id="bridge"', script)
        self.assertIn('--nopayload', script)
        self.assertIn('launchctl asuser "$uid" sudo -u "$user"', post)
        self.assertIn('--interactive', post)
        # A Bridge failure must not fail the whole install when the App was installed too.
        self.assertIn('if [ -d /Applications/Heimdall.app ]; then exit 0; fi', post)
        self.assertIn('|| bridge_failed', post)
        for path in ('scripts/release/build-macos-pkg.sh', 'scripts/release/macos-pkg-bridge-postinstall.sh'):
            self.assertEqual(subprocess.run(['bash', '-n', str(ROOT / path)]).returncode, 0)
            self.assertTrue(os.access(ROOT / path, os.X_OK), path)

    def test_electron_targets(self):
        config = read('electron-builder.yml')
        self.assertIn('    - dmg\n    - zip\n', config)
        self.assertIn('linux:\n', config)
        self.assertIn('    - AppImage\n    - deb\n', config)
        deb = config.split('\ndeb:\n', 1)[1].split('\nafterSign:', 1)[0]
        # deb.depends replaces electron-builder's defaults, so it must keep all of them.
        for dep in ('libgtk-3-0', 'libnotify4', 'libnss3', 'libxss1', 'libxtst6', 'xdg-utils',
                    'libatspi2.0-0', 'libuuid1', 'libsecret-1-0'):
            self.assertIn(f'    - {dep}\n', deb)
        self.assertIn('libayatana-appindicator3-1', deb)

    def test_release_ci_builds_installers_and_update_metadata(self):
        workflow = read('.github/workflows/release-local-binaries.yml')
        self.assertIn('npx electron-builder --linux AppImage deb "$arch" --publish never', workflow)
        self.assertIn('scripts/release/build-macos-pkg.sh', workflow)
        self.assertIn('merge-latest-mac.py', workflow)
        for asset in ('dist/latest-mac.yml', 'dist/latest-linux.yml', 'dist/latest-linux-arm64.yml',
                      'dist/Heimdall-*.pkg', 'dist/Heimdall-*.AppImage', 'dist/Heimdall-*.deb', 'dist/Heimdall-*.zip'):
            self.assertEqual(workflow.count(f' {asset} '), 2, asset)  # gh release upload and create

    def test_desktop_updater_is_not_windows_only(self):
        main = read('src/ui/electron/main.cts')
        self.assertIn('desktopUpdater.supported(process.platform, app.isPackaged)', main)
        self.assertNotIn("process.platform === 'win32', () => undefined", main)


if __name__ == '__main__':
    unittest.main()
