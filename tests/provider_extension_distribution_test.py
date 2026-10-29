#!/usr/bin/env python3
"""Hermetic distribution regressions: actual scripts, stubbed builds/services only."""
from contextlib import closing
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import sqlite3
import subprocess
import tarfile
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]
MANIFESTS = (
    "antigravity/plugin.json",
    "claude-code/.claude-plugin/plugin.json",
    "codex/.codex-plugin/plugin.json",
)
MARKETS = (".claude-plugin/marketplace.json", ".agents/plugins/marketplace.json")


class DistributionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="heimdall-distribution-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo with spaces"
        self.repo.mkdir()
        shutil.copytree(ROOT / "scripts", self.repo / "scripts")
        shutil.copytree(ROOT / "nix", self.repo / "nix")
        shutil.copytree(ROOT / "extensions", self.repo / "extensions", symlinks=True)
        for name in ("README.md", "LICENSE", "flake.nix"):
            shutil.copy2(ROOT / name, self.repo / name)
        for name in ("contracts", "hub/repository/sqlite"):
            dest = self.repo / "src" / name
            dest.mkdir(parents=True)
        shutil.copy2(ROOT / "src/contracts/protocol.odin", self.repo / "src/contracts/protocol.odin")
        current = json.loads((self.repo / "extensions" / MANIFESTS[0]).read_text())["version"]
        major = int(current.split(".")[0]) + 1
        self.next_version = f"{major}.0.0"
        self.next_prerelease = f"{major}.0.1-beta.1"
        self.sql = self.repo / "src/hub/repository/sqlite"
        shutil.copytree(ROOT / "src/hub/repository/sqlite/migrations", self.sql / "migrations")
        shutil.copy2(ROOT / "src/hub/repository/sqlite/migrations.odin", self.sql / "migrations.odin")
        # Numbered migrations only (native_*.sql are a separate, unnumbered series).
        self.next_migration = max(int(p.name.split("_", 1)[0])
                                  for p in (self.sql / "migrations").glob("[0-9]*.sql")) + 1
        self.write(self.repo / "extensions/codex/hooks/fixture-hook.sh",
                   "#!/bin/sh\nexit 0\n", executable=True)
        self.mock = self.root / "mock"
        self.mock.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("HEIMDALL_", "HAM_")) and k not in (
                        "DATA_DIR", "STAGE_DIR", "BRIDGE_PID", "SERVICE_NAME", "STOP_HOOK",
                        "RESTART_HOOK", "PREFIX", "TERMUX_VERSION", "SOURCE_DATE_EPOCH")}
        self.env.update(HOME=str(self.home), PATH=str(self.mock) + ":" + os.environ["PATH"])
        self.stub("curl", '#!/bin/sh\nprintf "${TEST_HTTP:-200}"\n')
        self.stub("uname", '#!/bin/sh\nprintf "${TEST_OS:-Linux}\\n"\n')
        self.write(self.root / "hook", "#!/bin/sh\nexit 0\n", executable=True)

    def write(self, path, text, executable=False):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        if executable:
            path.chmod(0o755)

    def stub(self, name, text):
        self.write(self.mock / name, text, executable=True)

    def run_script(self, path, *args, success=True, env=None):
        result = subprocess.run(["bash", str(path), *map(str, args)], cwd=self.repo,
                                env=dict(self.env, **(env or {})), text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def package(self, target="linux-amd64"):
        outputs = []
        for name in ("ham-bridge", "ham-ctl", "ham-pty-host"):
            output = self.root / ("output-" + name)
            self.write(output / "bin" / name, "#!/bin/sh\necho new\n", executable=True)
            outputs.append(output)
        self.run_script(self.repo / "scripts/release/package-local-binary-tarball.sh",
                        target, "0.4.31", self.root / "dist", *outputs)
        return self.root / "dist" / ("heimdall-local-" + target + ".tar.gz")

    def extract(self, archive, dest):
        dest.mkdir(parents=True)
        with tarfile.open(archive) as stream:
            # Only our own fixture archives; retain relative hook symlinks.
            stream.extractall(dest, filter="tar")

    def assert_assets(self, path):
        for item in (*MANIFESTS, *MARKETS, "antigravity/hooks/hooks.json",
                     "claude-code/hooks/hooks.json", "codex/hooks/hooks.json", "codex/hooks/fixture-hook.sh"):
            self.assertEqual((path / item).read_bytes(), (self.repo / "extensions" / item).read_bytes())
            self.assertEqual((path / item).stat().st_mode & 0o777,
                             (self.repo / "extensions" / item).stat().st_mode & 0o777)
        link = path / "antigravity/hooks.json"
        self.assertTrue(link.is_symlink(), str(link))
        self.assertEqual(os.readlink(link), "hooks/hooks.json")

    def test_release_archive_ships_extensions_and_no_update_scripts(self):
        # Updates and extension refreshes run inside ham-bridge (update / setup /
        # extensions sync): the bundle carries binaries and assets only.
        archive = self.package()
        dest = self.root / "extracted"
        self.extract(archive, dest)
        self.assert_assets(dest / "share/heimdall/extensions")
        self.assertFalse((dest / "scripts").exists())
        self.assertTrue((dest / "bin/ham-bridge").is_file())

    def git(self, *args):
        result = subprocess.run(["git", "-C", str(self.repo), *map(str, args)],
                                env=self.env, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def init_release_git(self):
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Release Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "core.hooksPath", "/dev/null")
        self.git("add", ".")
        self.git("commit", "-m", "fixture baseline")

    def assert_git_release_source(self, version, committed=False):
        # Nix local Git source uses indexed paths and working-tree contents.
        # Committed prepare output must also survive a clean build checkout.
        paths = (self.git("ls-tree", "-r", "--name-only", "HEAD") if committed
                 else self.git("ls-files")).splitlines()
        snapshot = self.root / "git-source"
        if snapshot.exists():
            shutil.rmtree(snapshot)
        snapshot.mkdir()
        for name in paths:
            dest = snapshot / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            if committed:
                dest.write_bytes(subprocess.check_output(
                    ["git", "-C", str(self.repo), "show", "HEAD:" + name]))
            else:
                shutil.copy2(self.repo / name, dest)
        registry = (snapshot / "src/hub/repository/sqlite/migrations.odin").read_text()
        for name in re.findall(r'#load\("(migrations/[^\"]+\.sql)"', registry):
            self.assertTrue((snapshot / "src/hub/repository/sqlite" / name).is_file(), name)
        for manifest in MANIFESTS:
            self.assertEqual(json.loads((snapshot / "extensions" / manifest).read_text())["version"], version)
        market = json.loads((snapshot / "extensions/.claude-plugin/marketplace.json").read_text())
        self.assertEqual(market["metadata"]["version"], version)
        self.assertEqual(market["plugins"][0]["version"], version)
        self.assertIn(version, (snapshot / "flake.nix").read_text())
        generated = list((snapshot / "src/hub/repository/sqlite/migrations").glob("*_extension_version_sync_*.sql"))
        self.assertTrue(any(version in path.read_text() for path in generated))

    def test_release_prepare_commits_complete_version_source(self):
        self.init_release_git()
        # Execute the actual workflow prepare block against a local-only remote.
        remote = self.root / "remote.git"
        self.git("init", "--bare", remote)
        self.git("remote", "add", "origin", remote)
        workflow = (ROOT / ".github/workflows/release-local-binaries.yml").read_text()
        body = re.search(r"        run: \|\n(.*?)\n  build:", workflow, re.S)[1]
        prepare = self.root / "prepare.sh"
        prepare.write_text(textwrap.dedent(body))
        self.run_script(prepare, env={"REQUESTED_VERSION": self.next_version,
                                    "GITHUB_REF_TYPE": "branch", "GITHUB_REF_NAME": "main",
                                    "GITHUB_OUTPUT": str(self.root / "outputs")})
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assert_git_release_source(self.next_version, committed=True)
        # Build jobs stamp metadata again; no new migration should appear.
        self.run_script(self.repo / "scripts/release/bump-version.sh", self.next_version,
                        "abcdef12", "2026-10-24T00:00:00Z")
        self.assertEqual(self.git("ls-files", "--others", "--exclude-standard"), "")
        self.assert_git_release_source(self.next_version)

    def test_local_and_tag_build_bumps_include_generated_sql_in_git_source(self):
        self.init_release_git()
        self.write(self.repo / "unrelated-user-file", "do not stage\n")
        for args, version in ((("--version-only",), self.next_version), ((), self.next_prerelease)):
            with self.subTest(args=args):
                self.run_script(self.repo / "scripts/release/bump-version.sh", *args, version)
                self.assert_git_release_source(version)
                self.assertEqual(self.git("diff", "--cached", "--name-only"), "")
                self.assertEqual(self.git("ls-files", "--others", "--exclude-standard"), "unrelated-user-file")

    @unittest.skipUnless(shutil.which("nix"), "Nix is required to inspect its actual Git source filter")
    def test_nix_git_source_contains_generated_migration(self):
        self.init_release_git()
        self.run_script(self.repo / "scripts/release/bump-version.sh", self.next_version)
        expression = ('let source = builtins.fetchGit { url = ' + json.dumps(str(self.repo)) + '; }; '
                      'in builtins.readFile (source + "/src/hub/repository/sqlite/migrations.odin")')
        result = subprocess.run(["nix", "eval", "--impure", "--raw", "--expr", expression],
                                env=self.env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        generated = list((self.sql / "migrations").glob(f"{self.next_migration:03d}_extension_version_sync_*.sql"))
        self.assertEqual(len(generated), 1)
        self.assertIn(generated[0].name, result.stdout)
        expression = ('let source = builtins.fetchGit { url = ' + json.dumps(str(self.repo)) + '; }; '
                      'in builtins.readFile (source + ' + json.dumps("/" + str(generated[0].relative_to(self.repo))) + ')')
        result = subprocess.run(["nix", "eval", "--impure", "--raw", "--expr", expression],
                                env=self.env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, generated[0].read_text())

    def test_version_generator_rejects_unregistered_collision_without_partial_stamp(self):
        self.write(self.sql / f"migrations/{self.next_migration:03d}_collision.sql", "-- occupied migration number\n")
        files = {p: p.read_bytes() for p in self.repo.rglob("*") if p.is_file()}
        result = self.run_script(self.repo / "scripts/release/bump-version.sh",
                                 "--version-only", self.next_version, success=False)
        self.assertIn("collisions", result.stdout)
        self.assertEqual(files, {p: p.read_bytes() for p in self.repo.rglob("*") if p.is_file()})

    def test_version_generator_uses_next_free_registered_number_and_build_metadata(self):
        registry = self.sql / "migrations.odin"
        text = registry.read_text()
        order = re.search(r"(migration_order :: \[)(\d+)(\]string \{)(.*?)(\n\})", text, re.S)
        name = f"{self.next_migration:03d}_reserved.sql"
        text = (text[:order.start()] + order[1] + str(int(order[2]) + 1) + order[3]
                + order[4] + '\n\t"' + name + '",' + order[5] + text[order.end():])
        registry.write_text(text)
        self.write(self.sql / "migrations" / name, "-- unrelated forward migration\n")
        self.run_script(self.repo / "scripts/release/bump-version.sh", "v" + self.next_version,
                        "abcdef12", "2026-10-24T00:00:00Z")
        self.assertTrue(list((self.sql / "migrations").glob(f"{self.next_migration + 1:03d}_extension_version_sync_*.sql")))
        protocol = (self.repo / "src/contracts/protocol.odin").read_text()
        self.assertIn('GIT_COMMIT :: #config(HAM_GIT_COMMIT, "abcdef12")', protocol)
        self.assertIn('BUILD_TIMESTAMP :: #config(HAM_BUILD_TIMESTAMP, "2026-10-24T00:00:00Z")', protocol)

    def test_version_bump_stamps_manifests_and_append_only_catalog(self):
        migrations = self.sql / "migrations"
        helper = self.repo / "scripts/release/stamp-provider-versions.py"
        spec = importlib.util.spec_from_file_location("stamp_fixture", helper)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        names = re.findall(r'"([^"]+\.sql)"', module.ORDER.search((self.sql / "migrations.odin").read_text())[4])
        with closing(module.catalog_database(migrations, names)) as db:
            self.assertEqual(module.catalog_etag(db), db.execute("SELECT catalog_etag FROM provider_catalog_meta").fetchone()[0])
        original = {p.name: p.read_bytes() for p in migrations.glob("*.sql")}
        registry = (self.sql / "migrations.odin").read_text()
        package = self.repo / "package.json"
        self.write(package, '{"version":"0.1.0"}\n')
        for version in (self.next_version, self.next_prerelease):
            self.run_script(self.repo / "scripts/release/bump-version.sh", "--version-only", version)
            for manifest in MANIFESTS:
                self.assertEqual(json.loads((self.repo / "extensions" / manifest).read_text())["version"], version)
            market = json.loads((self.repo / "extensions/.claude-plugin/marketplace.json").read_text())
            self.assertEqual(market["metadata"]["version"], version)
            self.assertEqual(market["plugins"][0]["version"], version)
            self.assertEqual(package.read_text(), '{"version":"0.1.0"}\n')
            for name, content in original.items():
                self.assertEqual((migrations / name).read_bytes(), content, name)
            generated = sorted(p for p in migrations.glob("*.sql") if p.name not in original)
            self.assertTrue(generated, "future bump must advance catalog minimum through a forward migration")
            latest = generated[-1]
            with closing(sqlite3.connect(":memory:")) as db:
                db.executescript("CREATE TABLE provider_catalog(provider TEXT, extension TEXT);"
                                 "CREATE TABLE provider_catalog_meta(catalog_etag TEXT);")
                db.executemany("INSERT INTO provider_catalog VALUES (?, ?)",
                               [(p, '{"min_version":"0.4.31","preserved":true}') for p in ("claude", "codex", "antigravity", "other")])
                db.commit()
                for sql in generated:
                    db.executescript(sql.read_text())
                for provider, extension in db.execute("SELECT provider, extension FROM provider_catalog"):
                    value = json.loads(extension)
                    self.assertEqual(value["min_version"], "0.4.31" if provider == "other" else version)
                    self.assertTrue(value["preserved"])
                etag = db.execute("SELECT catalog_etag FROM provider_catalog_meta").fetchone()[0]
                self.assertTrue(etag.startswith("sha256:"))
            text = (self.sql / "migrations.odin").read_text()
            self.assertIn('#load("migrations/' + latest.name + '", string)', text)
            self.assertIn('if name == "' + latest.name + '"', text)
            order = re.search(r"migration_order :: \[(\d+)\]string \{(.*?)\n\}", text, re.S)
            names = re.findall(r'"([^"]+\.sql)"', order[2])
            self.assertEqual(int(order[1]), len(names))
            self.assertEqual(names[-1], latest.name)
            before = {str(p.relative_to(self.repo)): p.read_bytes() for p in self.repo.rglob("*") if p.is_file()}
            self.run_script(self.repo / "scripts/release/bump-version.sh", "--version-only", version)
            self.assertEqual(before, {str(p.relative_to(self.repo)): p.read_bytes() for p in self.repo.rglob("*") if p.is_file()})
        self.assertNotEqual(registry, (self.sql / "migrations.odin").read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
