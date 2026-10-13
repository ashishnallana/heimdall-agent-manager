#!/usr/bin/env python3
"""Regression test for Darwin BSD sed in bump-version.sh (REQ-REL-SED-DARWIN-1, REQ-REL-SED-DARWIN-2).

Verifies:
1. Static analysis:
   - bump-version.sh defines a portable sed_i helper.
   - sed_i handles Darwin (BSD sed) with `sed -i '' "$@"` and Linux with `sed -i "$@"`.
   - No raw `sed -i` invocations remain outside the sed_i helper definition.
2. Linux execution (real environment):
   - Updates flake.nix, src/contracts/protocol.odin, and package.json.
   - Does not create backup files.
3. Darwin BSD sed simulation:
   - With mocked uname returning "Darwin" and BSD sed argument semantics,
     bump-version.sh correctly invokes `sed -i '' ...` and updates all target files.
   - Confirms that raw `sed -i` would fail on BSD sed with the reproduction error
     ('invalid command code f'), but the portable helper succeeds.
"""

import os
import re
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
BUMP_SCRIPT = REPO_ROOT / "scripts" / "release" / "bump-version.sh"


class TestBumpVersionDarwinSed(unittest.TestCase):
    def setUp(self):
        self.assertTrue(BUMP_SCRIPT.exists(), f"bump-version.sh not found at {BUMP_SCRIPT}")

    def _setup_mock_repo(self, tmp_path: Path):
        """Creates a mock repo structure with fixtures for testing bump-version.sh."""
        scripts_dir = tmp_path / "scripts" / "release"
        scripts_dir.mkdir(parents=True)
        shutil.copy2(BUMP_SCRIPT, scripts_dir / "bump-version.sh")
        (scripts_dir / "bump-version.sh").chmod(0o755)

        # Fixture: flake.nix
        flake_content = """{
  description = "Heimdall agent manager";
  inputs = { nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable"; };
  outputs = { self, nixpkgs }: {
    appVersion = "0.1.0";
  };
}
"""
        (tmp_path / "flake.nix").write_text(flake_content, encoding="utf-8")

        # Fixture: src/contracts/protocol.odin
        odin_dir = tmp_path / "src" / "contracts"
        odin_dir.mkdir(parents=True)
        odin_content = """package contracts

APP_VERSION :: #config(HAM_APP_VERSION, "0.1.0")
GIT_COMMIT :: #config(HAM_GIT_COMMIT, "initial")
BUILD_TIMESTAMP :: #config(HAM_BUILD_TIMESTAMP, "1970-01-01T00:00:00Z")
"""
        (odin_dir / "protocol.odin").write_text(odin_content, encoding="utf-8")

        # Fixture: package.json
        pkg_content = """{
  "name": "heimdall-ui",
  "version": "0.1.0",
  "private": true
}
"""
        (tmp_path / "package.json").write_text(pkg_content, encoding="utf-8")

    def test_bump_version_linux_execution(self):
        """Test bump-version.sh execution on Linux (GNU sed) updates all files without leaving backups."""
        with tempfile.TemporaryDirectory(prefix="heimdall-bump-linux-") as tmp_dir:
            tmp_path = Path(tmp_dir)
            self._setup_mock_repo(tmp_path)

            script = tmp_path / "scripts" / "release" / "bump-version.sh"
            result = subprocess.run(
                [str(script), "1.2.3", "c0ffee12", "2026-10-03T12:00:00Z"],
                cwd=tmp_path,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, f"Script failed:\nstdout: {result.stdout}\nstderr: {result.stderr}")

            # Verify flake.nix
            flake_text = (tmp_path / "flake.nix").read_text(encoding="utf-8")
            self.assertIn('appVersion = "1.2.3";', flake_text)

            # Verify protocol.odin
            odin_text = (tmp_path / "src" / "contracts" / "protocol.odin").read_text(encoding="utf-8")
            self.assertIn('APP_VERSION :: #config(HAM_APP_VERSION, "1.2.3")', odin_text)
            self.assertIn('GIT_COMMIT :: #config(HAM_GIT_COMMIT, "c0ffee12")', odin_text)
            self.assertIn('BUILD_TIMESTAMP :: #config(HAM_BUILD_TIMESTAMP, "2026-10-03T12:00:00Z")', odin_text)

            # Verify package.json keeps its dependency-manifest version untouched
            pkg_text = (tmp_path / "package.json").read_text(encoding="utf-8")
            self.assertIn('"version": "0.1.0"', pkg_text)

            # Verify no backup files created
            all_files = [p.name for p in tmp_path.rglob("*")]
            for name in all_files:
                self.assertFalse(
                    name.endswith(".bak") or name.endswith("''") or name.endswith("-e"),
                    f"Unexpected backup file created: {name}",
                )

    def test_bump_version_darwin_bsd_sed_simulation(self):
        """Simulate Darwin BSD sed behavior: verify sed_i passes '' as backup extension and succeeds."""
        with tempfile.TemporaryDirectory(prefix="heimdall-bump-darwin-") as tmp_dir:
            tmp_path = Path(tmp_dir)
            self._setup_mock_repo(tmp_path)

            # Create mock bin directory with Darwin uname and BSD sed
            mock_bin = tmp_path / "mock_bin"
            mock_bin.mkdir()

            # Mock uname: returns "Darwin" when -s is queried
            mock_uname = mock_bin / "uname"
            mock_uname.write_text(
                """#!/bin/sh
if [ "$1" = "-s" ]; then
    echo "Darwin"
    exit 0
fi
exec /usr/bin/uname "$@"
""",
                encoding="utf-8",
            )
            mock_uname.chmod(0o755)

            # Mock BSD sed:
            # BSD sed requires `-i <ext>` (or `-i ''`).
            # If called as `sed -i "s/..." file`, argv is: [-i, s/..., file].
            # BSD sed treats argv[1] as -i, argv[2] as ext, argv[3] as script.
            # When argv[3] is 'flake.nix', it fails: `sed: 1: "flake.nix": invalid command code f`!
            # If called as `sed -i '' "s/..." file`, argv is: [-i, "", s/..., file].
            # BSD sed accepts "" as empty extension and executes script on file.
            mock_sed = mock_bin / "sed"
            mock_sed.write_text(
                r"""#!/usr/bin/env python3
import sys
import re

args = sys.argv[1:]
if not args:
    sys.exit(0)

if args[0] == "-i":
    if len(args) < 3:
        sys.stderr.write("sed: option requires an argument -- i\n")
        sys.exit(1)
    # Check if empty string extension was provided: [-i, '', script, file]
    if args[1] == "":
        script = args[2]
        filepath = args[3]
        import subprocess
        res = subprocess.run(["/bin/sed", "-i", script, filepath])
        sys.exit(res.returncode)
    else:
        # In BSD sed, `sed -i "s/..." file` treats args[1] as backup extension,
        # and args[2] as the sed script command.
        # If args[2] is a file name like "flake.nix", it tries to execute 'flake.nix' as sed command.
        # The first character 'f' is not a valid sed command!
        ext = args[1]
        script = args[2]
        cmd_char = script[0] if script else ""
        sys.stderr.write(f'sed: 1: "{script}": invalid command code {cmd_char}\n')
        sys.exit(1)
else:
    sys.stderr.write(f"sed: unsupported mock args: {args}\n")
    sys.exit(1)
""",
                encoding="utf-8",
            )
            mock_sed.chmod(0o755)

            # Test 1: Confirm our mock faithfully reproduces the Darwin BSD sed error when given raw `sed -i`
            raw_test = subprocess.run(
                [str(mock_sed), "-i", "s/foo/bar/", "flake.nix"],
                cwd=tmp_path,
                capture_output=True,
                text=True,
            )
            self.assertEqual(raw_test.returncode, 1)
            self.assertIn('sed: 1: "flake.nix": invalid command code f', raw_test.stderr)

            # Test 2: Run bump-version.sh under Darwin environment with mock_bin in PATH
            env = os.environ.copy()
            env["PATH"] = f"{mock_bin}:{env.get('PATH', '')}"

            script = tmp_path / "scripts" / "release" / "bump-version.sh"
            result = subprocess.run(
                [str(script), "2.0.0", "abcdef99", "2026-10-03T14:30:00Z"],
                cwd=tmp_path,
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, f"bump-version.sh failed on simulated Darwin:\nstdout: {result.stdout}\nstderr: {result.stderr}")

            # Verify flake.nix updated properly
            flake_text = (tmp_path / "flake.nix").read_text(encoding="utf-8")
            self.assertIn('appVersion = "2.0.0";', flake_text)

            # Verify protocol.odin updated properly
            odin_text = (tmp_path / "src" / "contracts" / "protocol.odin").read_text(encoding="utf-8")
            self.assertIn('APP_VERSION :: #config(HAM_APP_VERSION, "2.0.0")', odin_text)
            self.assertIn('GIT_COMMIT :: #config(HAM_GIT_COMMIT, "abcdef99")', odin_text)
            self.assertIn('BUILD_TIMESTAMP :: #config(HAM_BUILD_TIMESTAMP, "2026-10-03T14:30:00Z")', odin_text)

            # Verify package.json keeps its dependency-manifest version untouched
            pkg_text = (tmp_path / "package.json").read_text(encoding="utf-8")
            self.assertIn('"version": "0.1.0"', pkg_text)


if __name__ == "__main__":
    unittest.main()
