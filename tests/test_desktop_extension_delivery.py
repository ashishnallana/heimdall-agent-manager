"""Run the macOS desktop resource staging script and its bundled-extension check.

Only the binaries/signature metadata are fixtures; extension assets, checksums
and the desktop resource stager are production code. Installing the extensions
is `ham-bridge setup`'s job (src/bridge/extensions_cmd.odin and its tests).
"""
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DesktopExtensionDeliveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="heimdall-desktop-extensions-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        # A Windows checkout may have CRLF shell files. Run unchanged script
        # contents with Unix newlines, as GitHub's macOS checkout does.
        self.repo = self.root / "repo"
        for name in ("scripts/install.sh",
                     "scripts/release/stage-macos-desktop-resources.sh",
                     "scripts/release/verify-bundled-extensions.sh"):
            destination = self.repo / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text((ROOT / name).read_text())

    def bundle(self, target, missing=None):
        archive = self.root / f"heimdall-local-{target}.tar.gz"
        with tarfile.open(archive, "w:gz") as stream:
            for binary in ("ham-bridge", "ham-ctl", "ham-pty-host"):
                data = b"#!/bin/sh\nexit 0\n"
                member = tarfile.TarInfo(f"bin/{binary}")
                member.size, member.mode = len(data), 0o755
                stream.addfile(member, io.BytesIO(data))
            data = json.dumps({"version": "vtest", "target": target, "developer_id_signed": True}).encode()
            member = tarfile.TarInfo("METADATA.json")
            member.size = len(data)
            stream.addfile(member, io.BytesIO(data))
            stream.add(ROOT / "extensions", arcname="share/heimdall/extensions",
                       filter=lambda member: None if member.name == f"share/heimdall/extensions/{missing}" else member)
        return archive

    def stage(self, target, missing=None):
        output = self.root / f"staged-{target}"
        result = subprocess.run(
            ["bash", "scripts/release/stage-macos-desktop-resources.sh", target,
             str(self.bundle(target, missing)), "vtest", str(output)],
            cwd=self.repo, text=True, capture_output=True, timeout=30)
        return result, output

    def test_both_mac_architectures_install_extensions_before_staging(self):
        for target in ("darwin-arm64", "darwin-amd64"):
            with self.subTest(target=target):
                result, output = self.stage(target)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("carries all provider extensions for ham-bridge setup", result.stdout)
                self.assertTrue((output / "install.sh").is_file())
                self.assertTrue((output / "SHA256SUMS").is_file())
                self.assertEqual((output / f"heimdall-local-{target}.tar.gz").read_bytes(),
                                 (self.root / f"heimdall-local-{target}.tar.gz").read_bytes())

    def test_missing_hidden_manifests_prevent_desktop_staging(self):
        for missing in (".claude-plugin/marketplace.json", "claude-code/.claude-plugin/plugin.json",
                        ".agents/plugins/marketplace.json", "codex/hooks/hooks.json"):
            with self.subTest(missing=missing):
                result, output = self.stage("darwin-arm64", missing)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Incomplete provider extension bundle", result.stdout + result.stderr)
                self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
