#!/usr/bin/env python3
"""Regression test for REQ-BE-TASK-CHAIN-RELEVANT-DIRECTORIES:
Full lifecycle of task chain relevant directories (schema, migration, REST API,
chain detail embedding, lean payload verification, and CLI).
"""

import json
import os
import re
import socket
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def require(ok: bool, message: str) -> None:
    if not ok:
        print(f"FAILED: {message}", file=sys.stderr)
        raise AssertionError(message)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def find_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def test_sqlite_schema_execution() -> None:
    print("Testing SQLite migration execution on real database...")
    db = sqlite3.connect(":memory:")
    cursor = db.cursor()
    cursor.execute("PRAGMA foreign_keys = ON;")

    for fpath in sorted((ROOT / "src/hub/repository/sqlite/migrations").glob("*.sql")):
        fname = fpath.name
        sql = fpath.read_text(encoding="utf-8")
        try:
            cursor.executescript(sql)
        except Exception as e:
            # FTS5 virtual tables may not be available in standard python sqlite3 without extensions
            if "fts" in fname.lower() or "no such module: fts5" in str(e).lower():
                continue
            raise AssertionError(f"Migration {fname} failed in SQLite: {e}")

    # Verify task_chain_directories table exists
    cursor.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='task_chain_directories';")
    row = cursor.fetchone()
    require(row is not None, "task_chain_directories table must exist in schema")

    # Verify column structure
    cursor.execute("PRAGMA table_info(task_chain_directories);")
    cols = {col[1]: col[2] for col in cursor.fetchall()}
    for req_col in ["directory_id", "chain_id", "owner_user_id", "path", "bridge_id", "vcs_kind", "vcs_info_json", "created_at", "updated_at"]:
        require(req_col in cols, f"column {req_col} must exist in task_chain_directories")

    # Verify foreign key cascade delete
    cursor.execute("""
        INSERT INTO task_chains (chain_id, owner_user_id, title, description, publish_state, status, kind, coordinator_agent_instance_id, default_reviewer_refs_json, created_at, updated_at, published_at, completed_at)
        VALUES ('chain_test_fk', 'user_test', 'Test Chain', 'Desc', 'published', 'active', 'team_work', '', '[]', '2026-09-22T00:00:00Z', '2026-09-22T00:00:00Z', '2026-09-22T00:00:00Z', '');
    """)
    cursor.execute("""
        INSERT INTO task_chain_directories (directory_id, chain_id, owner_user_id, path, bridge_id, vcs_kind, vcs_info_json, created_at, updated_at)
        VALUES ('dir_fk_1', 'chain_test_fk', 'user_test', '/tmp/test', '', 'git', '{}', '2026-09-22T00:00:00Z', '2026-09-22T00:00:00Z');
    """)
    cursor.execute("SELECT count(*) FROM task_chain_directories WHERE directory_id = 'dir_fk_1';")
    require(cursor.fetchone()[0] == 1, "directory row must be inserted")

    # Delete parent chain and verify cascade
    cursor.execute("DELETE FROM task_chains WHERE chain_id = 'chain_test_fk';")
    cursor.execute("SELECT count(*) FROM task_chain_directories WHERE directory_id = 'dir_fk_1';")
    require(cursor.fetchone()[0] == 0, "ON DELETE CASCADE must remove task_chain_directories when parent chain is deleted")

    # Test immutable owner trigger
    cursor.execute("""
        INSERT INTO task_chains (chain_id, owner_user_id, title, description, publish_state, status, kind, coordinator_agent_instance_id, default_reviewer_refs_json, created_at, updated_at, published_at, completed_at)
        VALUES ('chain_test_imm', 'user_test', 'Test Chain', 'Desc', 'published', 'active', 'team_work', '', '[]', '2026-09-22T00:00:00Z', '2026-09-22T00:00:00Z', '2026-09-22T00:00:00Z', '');
    """)
    cursor.execute("""
        INSERT INTO task_chain_directories (directory_id, chain_id, owner_user_id, path, bridge_id, vcs_kind, vcs_info_json, created_at, updated_at)
        VALUES ('dir_imm_1', 'chain_test_imm', 'user_test', '/tmp/test', '', 'git', '{}', '2026-09-22T00:00:00Z', '2026-09-22T00:00:00Z');
    """)
    triggered = False
    try:
        cursor.execute("UPDATE task_chain_directories SET owner_user_id = 'evil_user' WHERE directory_id = 'dir_imm_1';")
    except sqlite3.IntegrityError as e:
        triggered = True
        require("owner_user_id is immutable" in str(e), "trigger must abort with owner_user_id is immutable")
    require(triggered, "owner_immutable trigger must prevent updating owner_user_id")

    db.close()
    print("SQLite migration and trigger verification PASSED.")


def build_odin_pkg(pkg: str, out_path: Path) -> None:
    import shutil
    odin = os.environ.get("ODIN") or shutil.which("odin")
    res = None
    if odin and os.environ.get("IN_NIX_SHELL"):
        res = subprocess.run([odin, "build", pkg, "-collection:odin_test=src", f"-out:{out_path}"], cwd=ROOT, capture_output=True, text=True)
    if res is None or res.returncode != 0:
        res = subprocess.run(["nix", "develop", "--command", "odin", "build", pkg, "-collection:odin_test=src", f"-out:{out_path}"], cwd=ROOT, capture_output=True, text=True)
    require(res.returncode == 0, f"build failed for {pkg}: {res.stderr}")


def test_e2e_hub_rest_and_cli() -> None:
    import shutil
    import tempfile
    print("Testing end-to-end REST API and CLI on live Hub...")
    tmp_dir = Path(tempfile.mkdtemp(prefix="ham-test-dirs-"))
    hub_bin = tmp_dir / "test_hub"
    ctl_bin = tmp_dir / "test_ctl"
    print("Building test_hub and test_ctl binaries...")
    build_odin_pkg("src/hub", hub_bin)
    build_odin_pkg("src/ctl", ctl_bin)

    port = find_free_port()
    db_path = str(tmp_dir / f"ham-test-dirs-{port}.db")

    migrations_dir = str(ROOT / "src/hub/repository/sqlite/migrations")
    user_out = subprocess.check_output(
        [str(hub_bin), "users", "create", "--name", "Test User", "--email", "test@example.com", "--db", db_path, "--migrations-dir", migrations_dir],
        text=True,
    )
    user_tok = None
    for line in user_out.splitlines():
        line = line.strip()
        if line.startswith("token="):
            user_tok = line.split("=", 1)[1].strip()
            break
    require(user_tok is not None and len(user_tok) > 0, "Failed to provision user token")

    hub_proc = subprocess.Popen(
        [str(hub_bin), "--listen", f"127.0.0.1:{port}", "--db", db_path],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    try:
        # Wait for Hub to be ready
        ready = False
        base_url = f"http://127.0.0.1:{port}"
        for _ in range(50):
            try:
                with urllib.request.urlopen(f"{base_url}/api/v1/health", timeout=1) as resp:
                    if resp.status == 200:
                        ready = True
                        break
            except Exception:
                time.sleep(0.1)

        require(ready, "Hub failed to start up within timeout")

        def api_request(method: str, path: str, payload=None) -> tuple[int, dict]:
            url = f"{base_url}{path}"
            data = json.dumps(payload).encode("utf-8") if payload is not None else None
            req = urllib.request.Request(url, data=data, method=method)
            req.add_header("Authorization", f"Bearer {user_tok}")
            req.add_header("Content-Type", "application/json")
            try:
                with urllib.request.urlopen(req, timeout=5) as resp:
                    return resp.status, json.loads(resp.read().decode("utf-8"))
            except urllib.error.HTTPError as e:
                body = e.read().decode("utf-8")
                try:
                    parsed = json.loads(body)
                except Exception:
                    parsed = {"raw": body}
                return e.code, parsed

        # 1. Create a task chain
        status, data = api_request("POST", "/api/v1/task-chains", {"title": "Directories Test Chain", "kind": "team_work"})
        require(status == 201 or status == 200, f"failed to create chain: {status} {data}")
        chain_id = data["data"]["chain_id"]

        # 2. Check task chain detail includes directories (currently empty)
        status, data = api_request("GET", f"/api/v1/task-chains/{chain_id}")
        require(status == 200, f"failed to get chain: {status}")
        require("directories" in data["data"], "task chain detail must include 'directories' key")
        require(data["data"]["directories"] == [], "'directories' must be empty array initially")

        # 3. Add directory 1 with full VCS info
        vcs_info = {"branch": "feat/cloudtop-single-node", "root": "/usr/local/repo", "clean": True}
        status, data = api_request("POST", f"/api/v1/task-chains/{chain_id}/directories", {
            "path": "/usr/local/repo",
            "bridge_id": "brg_local_1",
            "vcs_kind": "git",
            "vcs": vcs_info,
        })
        require(status == 201, f"failed to add directory: {status} {data}")
        dir1 = data["data"]
        require(dir1["directory_id"].startswith("dir_"), f"directory_id should start with dir_: {dir1['directory_id']}")
        require(dir1["path"] == "/usr/local/repo", f"path mismatch: {dir1['path']}")
        require(dir1["bridge_id"] == "brg_local_1", f"bridge_id mismatch: {dir1['bridge_id']}")
        require(dir1["vcs_kind"] == "git", f"vcs_kind mismatch: {dir1['vcs_kind']}")
        require(dir1["vcs"] == vcs_info, f"vcs object mismatch: {dir1['vcs']}")

        # Strict check: payload MUST BE LEAN. NO created_at, updated_at, owner_user_id, chain_id
        for forbidden_key in ["created_at", "updated_at", "owner_user_id", "created_by", "updated_by"]:
            require(forbidden_key not in dir1, f"forbidden field '{forbidden_key}' found in lean directory payload")

        dir1_id = dir1["directory_id"]

        # 4. Add directory 2 (minimal fields)
        status, data = api_request("POST", f"/api/v1/task-chains/{chain_id}/directories", {
            "path": "/usr/local/secondary-docs",
        })
        require(status == 201, f"failed to add secondary directory: {status} {data}")
        dir2 = data["data"]
        require(dir2["path"] == "/usr/local/secondary-docs", "dir2 path mismatch")
        require(dir2["vcs"] == {}, "dir2 empty vcs should be {}")
        dir2_id = dir2["directory_id"]

        # 5. List directories
        status, data = api_request("GET", f"/api/v1/task-chains/{chain_id}/directories")
        require(status == 200, f"failed to list directories: {status} {data}")
        dirs = data["data"]
        require(len(dirs) == 2, f"expected 2 directories, got {len(dirs)}")
        require(dirs[0]["directory_id"] == dir1_id, "first directory id mismatch")
        require(dirs[1]["directory_id"] == dir2_id, "second directory id mismatch")

        # 6. Check task chain detail now embeds both directories
        status, data = api_request("GET", f"/api/v1/task-chains/{chain_id}")
        require(status == 200, f"failed to get chain detail: {status}")
        embedded_dirs = data["data"]["directories"]
        require(len(embedded_dirs) == 2, f"expected 2 embedded directories in chain detail, got {len(embedded_dirs)}")
        require(embedded_dirs[0]["directory_id"] == dir1_id, "embedded directory 1 mismatch")
        require(embedded_dirs[1]["directory_id"] == dir2_id, "embedded directory 2 mismatch")
        # Verify embedded directory is also lean
        for forbidden_key in ["created_at", "updated_at", "owner_user_id"]:
            require(forbidden_key not in embedded_dirs[0], f"forbidden key '{forbidden_key}' leaked in embedded directory")

        # 7. Update directory 1 via PATCH
        status, data = api_request("PATCH", f"/api/v1/task-chains/{chain_id}/directories/{dir1_id}", {
            "path": "/usr/local/repo_renamed",
            "vcs_kind": "piper",
            "vcs": {"citc_workspace": "tanmay_ws"},
        })
        require(status == 200, f"failed to patch directory: {status} {data}")
        updated_dir1 = data["data"]
        require(updated_dir1["path"] == "/usr/local/repo_renamed", "updated path mismatch")
        require(updated_dir1["vcs_kind"] == "piper", "updated vcs_kind mismatch")
        require(updated_dir1["vcs"] == {"citc_workspace": "tanmay_ws"}, "updated vcs mismatch")
        require(updated_dir1["bridge_id"] == "brg_local_1", "unchanged bridge_id must be preserved")

        # 8. Remove directory 2 via DELETE
        status, data = api_request("DELETE", f"/api/v1/task-chains/{chain_id}/directories/{dir2_id}")
        require(status == 200, f"failed to delete directory: {status} {data}")
        require(data["data"]["removed"] is True, "delete response must contain removed: true")

        # 9. Verify listing and detail now only have 1 directory
        status, data = api_request("GET", f"/api/v1/task-chains/{chain_id}/directories")
        require(len(data["data"]) == 1, f"expected 1 directory after deletion, got {len(data['data'])}")
        require(data["data"][0]["directory_id"] == dir1_id, "remaining directory mismatch")

        status, data = api_request("GET", f"/api/v1/task-chains/{chain_id}")
        require(len(data["data"]["directories"]) == 1, "chain detail should have 1 directory remaining")

        # 10. Test CLI command integration (via test_ctl binary in hub user-mode)
        def run_ctl(*args: str) -> tuple[int, str]:
            cmd = [str(ctl_bin), "hub", "--hub-url", base_url, "--user-token", user_tok] + list(args)
            res = subprocess.run(cmd, capture_output=True, text=True)
            return res.returncode, res.stdout

        print("Testing CLI commands via ham-ctl hub...")
        rc, out = run_ctl("task-chains", "directory", "list", "--chain-id", chain_id)
        require(rc == 0, f"CLI directory list failed: {out}")
        require(dir1_id in out, f"CLI list output should contain dir1_id: {out}")

        rc, out = run_ctl("task-chains", "directory", "add", "--chain-id", chain_id, "--path", "/cli/added/dir", "--vcs-kind", "jj")
        require(rc == 0, f"CLI directory add failed: {out}")
        require("/cli/added/dir" in out, f"CLI add output should contain path: {out}")
        require('"vcs_kind":"jj"' in out, f"CLI add output should contain vcs_kind jj: {out}")

        # Extract newly added directory id
        match = re.search(r'"directory_id":"(dir_[^"]+)"', out)
        require(match is not None, f"Could not find directory_id in CLI output: {out}")
        cli_dir_id = match.group(1)

        rc, out = run_ctl("task-chains", "directory", "update", "--chain-id", chain_id, "--directory-id", cli_dir_id, "--path", "/cli/updated/dir")
        require(rc == 0, f"CLI directory update failed: {out}")
        require("/cli/updated/dir" in out, f"CLI update output should contain updated path: {out}")

        rc, out = run_ctl("task-chains", "directory", "remove", "--chain-id", chain_id, "--directory-id", cli_dir_id)
        require(rc == 0, f"CLI directory remove failed: {out}")
        require('"removed":true' in out, f"CLI remove output should contain removed:true: {out}")

        print("End-to-end REST API and CLI verification PASSED.")

    finally:
        hub_proc.terminate()
        try:
            hub_proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            hub_proc.kill()
        shutil.rmtree(tmp_dir, ignore_errors=True)


if __name__ == "__main__":
    test_sqlite_schema_execution()
    test_e2e_hub_rest_and_cli()
    print("\nALL TASK CHAIN DIRECTORIES TESTS PASSED! (0 errors)")
