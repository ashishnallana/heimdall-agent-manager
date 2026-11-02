"""Exercise the actual workflow Bash with synthetic bundles and a local gh stub."""
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = "v9.0.0"
MANDATORY = ["darwin-arm64", "linux-amd64", "linux-arm64"]


def workflow_script(filename, step):
    text = (ROOT / ".github/workflows" / filename).read_text()
    block = text.split(f"      - name: {step}\n", 1)[1]
    lines = block.split("        run: |\n", 1)[1].splitlines()
    body = []
    for line in lines:
        if line and not line.startswith("          "):
            break
        body.append(line[10:])
    return ("\n".join(body).replace("${{ needs.prepare.outputs.version }}", VERSION)
            .replace("${{ needs.prepare.outputs.clean_version }}", VERSION[1:]))


class ReleaseTargetsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        (self.work / "dist").mkdir()
        self.env = dict(os.environ, RUNNER_TEMP=str(self.work), VERSION=VERSION,
                        GITHUB_WORKSPACE=str(ROOT))

    def run_script(self, script):
        return subprocess.run(["bash", "-c", script], cwd=self.work, env=self.env,
                              text=True, capture_output=True)

    def bundles(self, intel=False):
        entries = ["bin/ham-bridge", "bin/ham-ctl", "bin/heimdall", "bin/ham-pty-host",
                   "scripts/apply-bridge-update.sh", "README.md", "LICENSE"]
        for target in MANDATORY + (["darwin-amd64"] if intel else []):
            with tarfile.open(self.work / "dist" / f"heimdall-local-{target}.tar.gz", "w:gz") as archive:
                for name in entries:
                    item = tarfile.TarInfo(name)
                    item.size = 1
                    archive.addfile(item, io.BytesIO(b"x"))
        with zipfile.ZipFile(self.work / "dist/heimdall-local-windows-amd64.zip", "w") as archive:
            for name in ["bin/ham-bridge.exe", "bin/ham-ctl.exe", "bin/ham-pty-host.exe",
                         "README.md", "LICENSE", "METADATA.json"]:
                archive.writestr(name, "x")
        for arch in ["arm64"] + (["x64"] if intel else []):
            for extension in ["dmg", "zip", "zip.blockmap", "dmg.blockmap", "pkg"]:
                (self.work / "dist" / f"Ninjy-{VERSION[1:]}-{arch}.{extension}").write_text("fixture")
            target = "darwin-arm64" if arch == "arm64" else "darwin-amd64"
            name = f"Ninjy-{VERSION[1:]}-{arch}.zip"
            (self.work / "dist" / f"latest-mac-{target}.yml").write_text(
                f"version: {VERSION[1:]}\nfiles:\n  - url: {name}\n    sha512: fixture\npath: {name}\nsha512: fixture\n")
        for suffix in ["x86_64.AppImage", "arm64.AppImage", "amd64.deb", "arm64.deb", "x64.exe", "x64.exe.blockmap"]:
            (self.work / "dist" / f"Ninjy-{VERSION[1:]}-{suffix}").write_text("fixture")
        for name in ["latest.yml", "latest-linux.yml", "latest-linux-arm64.yml"]:
            (self.work / "dist" / name).write_text("fixture")

    def test_matrix_default_and_explicit_opt_in(self):
        script = ROOT / "scripts/release/local-build-matrix.py"
        for value, intel in [(None, False), ("false", False), ("true", True), ("TRUE", False)]:
            env = dict(os.environ)
            env.pop("BUILD_DARWIN_X64", None)
            if value is not None:
                env["BUILD_DARWIN_X64"] = value
            result = subprocess.check_output(["python3", str(script)], env=env, text=True)
            matrix = json.loads(result)["include"]
            self.assertEqual({row["target"] for row in matrix}, set(MANDATORY + (["darwin-amd64"] if intel else [])))
            self.assertEqual(any(row["runner"] == "macos-15-intel" for row in matrix), intel)
            arm = next(row for row in matrix if row["target"] == "darwin-arm64")
            self.assertEqual(arm["runner"], "macos-15")
            self.assertEqual(arm["nix_system"], "aarch64-darwin")
        text = (ROOT / ".github/workflows/release-local-binaries.yml").read_text()
        self.assertEqual(text.count("matrix: ${{ fromJSON(needs.prepare.outputs.build_matrix) }}"), 2)
        self.assertIn("github.event_name == 'workflow_dispatch' && inputs.build_darwin_x64 == true", text)

    def test_tarballs_and_checksums_both_modes(self):
        script = workflow_script("release-local-binaries.yml", "Verify tarballs and create SHA256SUMS")
        for intel in [False, True]:
            self.bundles(intel)
            self.env["BUILD_DARWIN_X64"] = str(intel).lower()
            result = self.run_script(script)
            self.assertEqual(result.returncode, 0, result.stderr)
            sums = (self.work / "dist/SHA256SUMS").read_text()
            self.assertEqual("darwin-amd64" in sums, intel)
            self.assertEqual(f"Ninjy-{VERSION[1:]}-x64.dmg" in sums, intel)
            metadata = (self.work / "dist/latest-mac.yml").read_text()
            self.assertEqual("-x64.zip" in metadata, intel)
            self.assertIn("-arm64.zip", metadata)
            self.assertIn("windows-amd64", sums)
            self.assertEqual(self.run_script("cd dist && sha256sum -c SHA256SUMS").returncode, 0)

    def test_opt_in_requires_intel_bundle(self):
        self.bundles()
        self.env["BUILD_DARWIN_X64"] = "true"
        result = self.run_script(workflow_script("release-local-binaries.yml", "Verify tarballs and create SHA256SUMS"))
        self.assertNotEqual(result.returncode, 0)

    def test_release_notes_follow_opt_in(self):
        script = workflow_script("release-local-binaries.yml", "Create or update GitHub Release")
        script = re.sub(r"\$\{\{.*?\}\}", "false", script)
        self.gh_stub()
        helper = self.work / "scripts/release"
        helper.mkdir(parents=True)
        (helper / "changelog.sh").write_text("#!/bin/sh\nprintf 'Fixture changelog\\n'\n")
        (helper / "changelog.sh").chmod(0o755)
        for name in ["install.sh", "install.ps1"]:
            (self.work / "scripts" / name).write_text("fixture")
        self.env.update(RELEASE_COMMIT="fixture", EXTRA_NOTES="", GITHUB_SERVER_URL="https://example.invalid",
                        GITHUB_REPOSITORY="fixture/repo")
        (self.work / "fixture-release.json").write_text("{}")
        for intel in [False, True]:
            self.env["BUILD_DARWIN_X64"] = str(intel).lower()
            result = self.run_script(script)
            self.assertEqual(result.returncode, 0, result.stderr)
            notes = (self.work / "release-notes.md").read_text()
            for name in ["darwin-amd64", f"Ninjy-{VERSION[1:]}-x64.dmg", f"Ninjy-{VERSION[1:]}-x64.pkg"]:
                self.assertEqual(name in notes, intel)
            self.assertIn(f"Ninjy-{VERSION[1:]}-x64.exe", notes)

    def gh_stub(self):
        stub = self.work / "gh"
        stub.write_text('''#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
root = pathlib.Path(os.environ["RUNNER_TEMP"])
remote = root / "remote-assets"
metadata = root / "fixture-release.json"
if sys.argv[1:3] == ["release", "view"]:
    data = json.loads(metadata.read_text())
    if "--jq" in sys.argv:
        print("\\n".join(a["name"] for a in data.get("assets", [])))
    else:
        print(json.dumps(data))
elif sys.argv[1:3] == ["release", "download"]:
    source = remote / "SHA256SUMS" if remote.exists() else root / "fixture-sums.txt"
    shutil.copyfile(source, "sums.txt")
elif sys.argv[1:3] == ["release", "upload"] and remote.exists():
    for arg in sys.argv[4:]:
        if not arg.startswith("--"):
            shutil.copyfile(arg, remote / pathlib.Path(arg).name)
    data = json.loads(metadata.read_text())
    data["assets"] = [{"name": p.name} for p in remote.iterdir()]
    metadata.write_text(json.dumps(data))
elif sys.argv[1:3] == ["release", "delete-asset"]:
    (remote / sys.argv[4]).unlink()
    data = json.loads(metadata.read_text())
    data["assets"] = [{"name": p.name} for p in remote.iterdir()]
    metadata.write_text(json.dumps(data))
''')
        stub.chmod(0o755)
        self.env["PATH"] = str(self.work) + os.pathsep + self.env["PATH"]

    def test_existing_release_reruns_reconcile_intel_assets(self):
        self.gh_stub()
        remote = self.work / "remote-assets"
        remote.mkdir()
        (self.work / "fixture-release.json").write_text(json.dumps({
            "isDraft": False, "isPrerelease": True, "assets": []}))
        helper = self.work / "scripts/release"
        helper.mkdir(parents=True)
        (helper / "changelog.sh").write_text("#!/bin/sh\nprintf 'Fixture changelog\\n'\n")
        (helper / "changelog.sh").chmod(0o755)
        for name in ["install.sh", "install.ps1"]:
            (self.work / "scripts" / name).write_text("fixture")
        self.env.update(RELEASE_COMMIT="fixture", EXTRA_NOTES="", GITHUB_SERVER_URL="https://example.invalid",
                        GITHUB_REPOSITORY="fixture/repo")
        publish = re.sub(r"\$\{\{.*?\}\}", "false", workflow_script(
            "release-local-binaries.yml", "Create or update GitHub Release"))
        for intel in [True, True, False, False, True]:
            shutil.rmtree(self.work / "dist")
            (self.work / "dist").mkdir()
            self.bundles(intel)
            self.env["BUILD_DARWIN_X64"] = str(intel).lower()
            for script in [workflow_script("release-local-binaries.yml", "Verify tarballs and create SHA256SUMS"),
                           publish, workflow_script("promote-release.yml", "Verify the release is a complete candidate")]:
                result = self.run_script(script)
                self.assertEqual(result.returncode, 0, result.stderr)
            names = {p.name for p in remote.iterdir()}
            self.assertEqual(f"heimdall-local-darwin-amd64-{VERSION}.tar.gz" in names, intel)
            for suffix in ["dmg", "dmg.blockmap", "zip", "zip.blockmap", "pkg"]:
                # DMG blockmaps are optional in current uploads but must be
                # cleaned up if an earlier run published one.
                name = f"Ninjy-{VERSION[1:]}-x64.{suffix}"
                if suffix != "dmg.blockmap":
                    self.assertEqual(name in names, intel)
            if intel:
                (remote / f"Ninjy-{VERSION[1:]}-x64.dmg.blockmap").write_text("legacy")
                data = json.loads((self.work / "fixture-release.json").read_text())
                data["assets"] = [{"name": p.name} for p in remote.iterdir()]
                (self.work / "fixture-release.json").write_text(json.dumps(data))
            else:
                self.assertNotIn(f"Ninjy-{VERSION[1:]}-x64.dmg.blockmap", names)
            self.assertIn(f"Ninjy-{VERSION[1:]}-x64.exe", names)
            self.assertIn(f"Ninjy-{VERSION[1:]}-x64.exe.blockmap", names)
            self.assertEqual("-x64.zip" in (remote / "latest-mac.yml").read_text(), intel)

    def test_promotion_optional_asset_manifest_agreement(self):
        self.gh_stub()
        script = workflow_script("promote-release.yml", "Verify the release is a complete candidate")
        for target, extension in [("darwin-amd64", "tar.gz"), ("windows-amd64", "zip")]:
            name = f"heimdall-local-{target}-{VERSION}.{extension}"
            for present, listed in [(False, False), (True, True), (True, False), (False, True)]:
                assets = [f"heimdall-local-{t}-{VERSION}.tar.gz" for t in MANDATORY] + ["SHA256SUMS"]
                if present:
                    assets.append(name)
                (self.work / "fixture-release.json").write_text(json.dumps({
                    "isDraft": False, "isPrerelease": True, "assets": [{"name": n} for n in assets]}))
                (self.work / "fixture-sums.txt").write_text(f"{'a' * 64}  {name}\n" if listed else "")
                result = self.run_script(script)
                self.assertEqual(result.returncode == 0, present == listed, result.stderr)


if __name__ == "__main__":
    unittest.main()
