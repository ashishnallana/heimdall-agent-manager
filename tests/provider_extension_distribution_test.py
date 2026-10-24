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
        self.next_migration = max(int(p.name.split("_", 1)[0])
                                  for p in (self.sql / "migrations").glob("*.sql")) + 1
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
        for name in ("ham-bridge", "ham-ctl", "heimdall", "ham-pty-host"):
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

    def stale(self, dest):
        for manifest in MANIFESTS:
            self.write(dest / manifest, '{"version":"0.1.0"}\n')
        self.write(dest / "codex/stale-file", "remove me")
        self.write(dest / "my-plugin/user.txt", "keep me")
        self.write(dest / ".agents/plugins/user-marketplace.json", "keep hidden")
        self.write(dest / ".claude-plugin/user.txt", "keep hidden too")

    def assert_refreshed(self, dest):
        self.assert_assets(dest)
        self.assertFalse((dest / "codex/stale-file").exists())
        self.assertEqual((dest / "my-plugin/user.txt").read_text(), "keep me")
        self.assertEqual((dest / ".agents/plugins/user-marketplace.json").read_text(), "keep hidden")
        self.assertEqual((dest / ".claude-plugin/user.txt").read_text(), "keep hidden too")

    def apply(self, stage, data, **env):
        return self.run_script(stage / "scripts/apply-bridge-update.sh",
                               "--data-dir", data, "--stage-dir", stage,
                               "--restart-hook", self.root / "hook", "--stop-hook", self.root / "hook",
                               "--health-timeout", "1", env=env, success=env.get("TEST_HTTP", "200") == "200")

    def test_release_archive_and_repeated_update_all_layouts(self):
        for target in ("linux-amd64", "darwin-arm64", "termux-arm64"):
            for layout in ("", "extract", "heimdall-cloudtop"):
                with self.subTest(target=target, layout=layout):
                    base = self.root / (target + (layout or "direct"))
                    stage = base / "stage"
                    extracted = stage / layout if layout else stage
                    self.extract(self.package(target), extracted)
                    self.assert_assets(extracted / "share/heimdall/extensions")
                    data = base / "data"
                    self.write(data / "bin/ham-bridge", "#!/bin/sh\necho old\n", executable=True)
                    self.stale(data / "extensions")
                    env = {"TEST_OS": "Darwin"} if target.startswith("darwin") else {}
                    # --stage-dir accepts the wrapper directory as well.
                    self.apply(extracted, data, **env) if not layout else self.run_script(
                        extracted / "scripts/apply-bridge-update.sh", "--data-dir", data,
                        "--stage-dir", stage, "--restart-hook", self.root / "hook",
                        "--stop-hook", self.root / "hook", "--health-timeout", "1", env=env)
                    self.assert_refreshed(data / "extensions")
                    self.assertFalse(stage.exists())
                    self.extract(self.package(target), extracted)
                    self.apply(extracted, data, **env)
                    self.assert_refreshed(data / "extensions")

    def test_update_health_failure_restores_previous_assets(self):
        stage = self.root / "stage"
        self.extract(self.package(), stage)
        data = self.root / "data"
        self.write(data / "bin/ham-bridge", "#!/bin/sh\necho old\n", executable=True)
        self.stale(data / "extensions")
        self.apply(stage, data, TEST_HTTP="503")
        self.assertEqual(json.loads((data / "extensions/codex/.codex-plugin/plugin.json").read_text())["version"], "0.1.0")
        self.assertTrue((data / "extensions/codex/stale-file").exists())

    def cloudtop(self):
        # Real bundle builder; replace only expensive external build tools.
        self.stub("nix", """#!/usr/bin/env python3
import pathlib, sys
a=sys.argv[1:]; name=a[1].split('#')[1]; output=pathlib.Path(a[a.index('-o')+1])
(output/'bin').mkdir(parents=True, exist_ok=True)
p=output/'bin'/name; p.write_text('#!/bin/sh\\nexit 0\\n'); p.chmod(0o755)
""")
        for name in ("npm", "npx", "nix-shell", "ldd"):
            self.stub(name, "#!/bin/sh\nexit 0\n")
        for item in ("scripts/install-systemd-service.sh", "scripts/snapshot-hub.sh", "systemd/heimdall.service"):
            self.write(self.repo / item, "# fixture\n")
        self.run_script(self.repo / "scripts/package-cloudtop-bundle.sh")
        bundle = self.repo / "dist/heimdall-cloudtop"
        syntax = subprocess.run(["bash", "-n", str(bundle / "start.sh")],
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(syntax.returncode, 0, syntax.stdout)
        # Execute only the generated start script's real asset-staging prelude.
        # No port probes, service actions, or provider config writes can run.
        start = (bundle / "start.sh").read_text()
        (bundle / "stage-only.sh").write_text(start.split("is_ancestor_or_self() {", 1)[0])
        return bundle

    def test_cloudtop_hidden_metadata_refresh_and_repeated_staging(self):
        bundle = self.cloudtop()
        for path in ("share/extensions", "extensions"):
            self.assert_assets(bundle / path)
        data = self.root / "data"
        self.stale(data / "extensions")
        for _ in range(2):
            self.run_script(bundle / "stage-only.sh", env={"HEIMDALL_DATA_DIR": str(data)})
            self.assert_refreshed(data / "extensions")
        # Legacy bundle layout is supported too.
        shutil.rmtree(bundle / "share/extensions")
        self.run_script(bundle / "stage-only.sh", env={"HEIMDALL_DATA_DIR": str(data)})
        self.assert_refreshed(data / "extensions")

    def test_cloudtop_upgrade_replaces_stale_manifest_before_restart(self):
        bundle = self.cloudtop()
        data = self.root / "data"
        self.stale(data / "extensions")
        self.run_script(bundle / "stage-only.sh", env={"HEIMDALL_DATA_DIR": str(data)})
        for manifest in MANIFESTS:
            self.assertEqual((data / "extensions" / manifest).read_bytes(),
                             (self.repo / "extensions" / manifest).read_bytes())
        self.assertFalse((data / "extensions/codex/stale-file").exists())

    def test_cloudtop_copy_failure_is_visible_and_preserves_old_generation(self):
        bundle = self.cloudtop()
        data = self.root / "data"
        self.stale(data / "extensions")
        real_cp = shutil.which("cp")
        self.stub("cp", "#!/bin/sh\nfor arg do\ncase \"$arg\" in *share/extensions/codex*) echo injected-copy-failure >&2; exit 73;; esac\ndone\nexec " + shlex.quote(real_cp) + ' "$@"\n')
        result = self.run_script(bundle / "stage-only.sh", success=False,
                                 env={"HEIMDALL_DATA_DIR": str(data)})
        self.assertIn("injected-copy-failure", result.stdout)
        self.assertEqual(json.loads((data / "extensions/codex/.codex-plugin/plugin.json").read_text())["version"], "0.1.0")
        self.assertTrue((data / "extensions/codex/stale-file").exists())

    def test_update_copy_failure_leaves_service_and_old_assets_untouched(self):
        stage = self.root / "stage"
        self.extract(self.package(), stage)
        data = self.root / "data"
        self.stale(data / "extensions")
        marker = self.root / "service-stopped"
        self.write(self.root / "hook", "#!/bin/sh\ntouch " + shlex.quote(str(marker)) + "\n", executable=True)
        real_cp = shutil.which("cp")
        self.stub("cp", "#!/bin/sh\nfor arg do\ncase \"$arg\" in *share/heimdall/extensions/codex*) echo injected-copy-failure >&2; exit 73;; esac\ndone\nexec " + shlex.quote(real_cp) + ' "$@"\n')
        result = self.run_script(stage / "scripts/apply-bridge-update.sh",
                                 "--data-dir", data, "--stage-dir", stage,
                                 "--restart-hook", self.root / "hook", "--stop-hook", self.root / "hook",
                                 success=False)
        self.assertIn("injected-copy-failure", result.stdout)
        self.assertFalse(marker.exists())
        self.assertTrue((data / "extensions/codex/stale-file").exists())

    def test_incomplete_bundle_is_rejected_without_changing_installed_assets(self):
        dest = self.root / "data/extensions"
        self.stale(dest)
        (self.repo / "extensions/codex/hooks/hooks.json").unlink()
        result = self.run_script(self.repo / "scripts/refresh-provider-extensions.sh",
                                 self.repo / "extensions", dest, success=False)
        self.assertIn("Incomplete provider extension bundle", result.stdout)
        self.assertTrue((dest / "codex/stale-file").exists())

    def test_refresh_swap_failure_restores_old_generation(self):
        data = self.root / "data"
        self.stale(data / "extensions")
        real_mv = shutil.which("mv")
        self.stub("mv", "#!/bin/sh\ncase \"$1\" in */.extensions-refresh.*/new) echo injected-swap-failure >&2; exit 74;; esac\nexec " + shlex.quote(real_mv) + ' "$@"\n')
        result = self.run_script(self.repo / "scripts/refresh-provider-extensions.sh",
                                 self.repo / "extensions", data / "extensions", success=False)
        self.assertIn("injected-swap-failure", result.stdout)
        self.assertTrue((data / "extensions/codex/stale-file").exists())
        self.assertFalse(list(data.glob(".extensions-refresh.*")))

    def test_refresh_failure_after_backup_restores_user_data(self):
        data = self.root / "data"
        self.stale(data / "extensions")
        real_mv = shutil.which("mv")
        self.stub("mv", "#!/bin/sh\ncase \"$2\" in */.extensions-refresh.*/old) " + shlex.quote(real_mv) + ' "$@"; echo injected-after-backup >&2; exit 75;; esac\nexec ' + shlex.quote(real_mv) + ' "$@"\n')
        result = self.run_script(self.repo / "scripts/refresh-provider-extensions.sh",
                                 self.repo / "extensions", data / "extensions", success=False)
        self.assertIn("injected-after-backup", result.stdout)
        self.assertTrue((data / "extensions/codex/stale-file").exists())
        self.assertEqual((data / "extensions/my-plugin/user.txt").read_text(), "keep me")
        self.assertFalse(list(data.glob(".extensions-refresh.*")))

    def test_refresh_rejects_symlinked_metadata_parent_without_touching_user_data(self):
        dest = self.root / "data/extensions"
        external = self.root / "external"
        external.mkdir()
        self.write(external / "keep", "user content")
        dest.mkdir(parents=True)
        (dest / ".agents").symlink_to(external, target_is_directory=True)
        result = self.run_script(self.repo / "scripts/refresh-provider-extensions.sh",
                                 self.repo / "extensions", dest, success=False)
        self.assertIn("symlinked extension destination", result.stdout)
        self.assertEqual((external / "keep").read_text(), "user content")
        self.assertEqual(list(external.iterdir()), [external / "keep"])

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


class InstallerDistributionTests(unittest.TestCase):
    def installer_fixture(self):
        # Reuse the existing hermetic service/download/enrollment fixtures,
        # without rerunning unrelated installer tests.
        from test_installer_clean import InstallerTests
        fixture = InstallerTests(methodName="test_names")
        fixture.setUp()
        self.addCleanup(fixture.tearDown)
        archive = fixture.root / "bundle"
        with tarfile.open(archive) as stream:
            payloads = [(member, stream.extractfile(member).read()) for member in stream.getmembers()]
        with tarfile.open(archive, "w:gz") as stream:
            for member, content in payloads:
                stream.addfile(member, io.BytesIO(content))
            stream.add(ROOT / "extensions", arcname="share/heimdall/extensions", recursive=True)
            helper = ROOT / "scripts/refresh-provider-extensions.sh"
            if helper.exists():
                stream.add(helper, arcname="scripts/refresh-provider-extensions.sh")
        return fixture

    def test_installer_rejects_unsafe_asset_before_service_changes(self):
        fixture = self.installer_fixture()
        archive = fixture.root / "bundle"
        with tarfile.open(archive) as stream:
            entries = [(member, stream.extractfile(member).read() if member.isfile() else None)
                       for member in stream.getmembers()]
        for unsafe in ("traversal", "symlink", "hardlink"):
            with self.subTest(unsafe=unsafe):
                with tarfile.open(archive, "w:gz") as stream:
                    for member, content in entries:
                        stream.addfile(member, io.BytesIO(content) if content is not None else None)
                    if unsafe == "traversal":
                        member = tarfile.TarInfo("share/heimdall/extensions/../../escape")
                    else:
                        member = tarfile.TarInfo("share/heimdall/extensions/unsafe")
                        member.type = tarfile.SYMTYPE if unsafe == "symlink" else tarfile.LNKTYPE
                        member.linkname = "/tmp/escape"
                    stream.addfile(member)
                output = fixture.run_install("--hub", "https://hub.mundus.in", "--version", "vtest", success=False)
                self.assertRegex(output, r"Unsafe.*extension")
                self.assertTrue(all(command == ["systemctl", "--user", "show-environment"]
                                    for command in fixture.commands()), fixture.commands())

    def test_fresh_install_and_refresh_preserve_unrelated_data(self):
        fixture = self.installer_fixture()
        name = "heimdall-bridge-hub-mundus-in"
        real_mv = shutil.which("mv")
        fixture.stub("mv", """#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
with (pathlib.Path(os.environ['MOCK_ROOT'])/'renames.jsonl').open('a') as output:
    output.write(json.dumps(sys.argv[1:])+'\\n')
sys.exit(subprocess.run([""" + repr(real_mv) + """, *sys.argv[1:]]).returncode)
""")
        for osname in ("Linux", "Darwin"):
            fixture.env["MOCK_OS"] = osname
            fixture.run_install("--hub", "https://hub.mundus.in", "--version", "vtest")
            dest = fixture.data(name) / "extensions"
            for manifest in MANIFESTS:
                self.assertEqual((dest / manifest).read_bytes(), (ROOT / "extensions" / manifest).read_bytes())
            self.assertTrue((dest / "antigravity/hooks.json").is_symlink())
            (dest / "codex/stale-file").write_text("old")
            (dest / "user-plugin").mkdir(exist_ok=True)
            (dest / "user-plugin/keep").write_text("keep")
            fixture.run_install("--hub", "https://hub.mundus.in", "--version", "vtest")
            self.assertFalse((dest / "codex/stale-file").exists())
            self.assertEqual((dest / "user-plugin/keep").read_text(), "keep")
        swaps = [json.loads(line) for line in (fixture.root / "renames.jsonl").read_text().splitlines()
                 if ".extensions-install." in line]
        self.assertTrue(swaps)
        for source, destination in swaps:
            self.assertTrue(Path(source).is_relative_to(fixture.data(name)))
            self.assertTrue(Path(destination).is_relative_to(fixture.data(name)))


if __name__ == "__main__":
    unittest.main(verbosity=2)
