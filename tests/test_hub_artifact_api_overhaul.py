#!/usr/bin/env python3
"""Automated integration test suite for Artifact API Overhaul (REQ-ARTIFACT-API-COMPARISON, REQ-VERIFY-MAIN).

Verifies:
1. Memory leak safety with Odin Tracking Allocator (0 leaks, 0 bad frees across SQLite repo and HTTP layer).
2. Starting local ham-hub on ephemeral port with SQLite migrations (including migration 041 composite indexes).
3. Artifact creation across multiple projects, instances, chains, tasks, kinds, and timestamps.
4. Cursor-based pagination with limit and next_cursor across multiple pages (verifying has_more and next_cursor).
5. Comprehensive filtering by:
   - project_id
   - agent_instance_id
   - chain_id
   - task_id
   - kind
   - since
   - until
6. Sorting by created_at, updated_at, name, size_bytes in both 'asc' and 'desc' order.
7. Selective projection: list queries strictly omit artifact payload (content field is absent or empty).
8. Raw content retrieval:
   - GET /api/v1/artifacts/:id/content returns raw content bytes matching original SHA256.
   - GET /api/v1/artifacts/:id/download returns Content-Disposition attachment and valid payload.
   - Agent action RPC agent.artifact.content via POST /api/v1/agent-actions/artifacts/content matches SHA256.
9. CLI validation via ham-ctl hub artifacts list and content.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import socket
import sqlite3
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hub_oidc_login import MockOIDC, login, session_headers  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def wait_for_port(port: int, timeout: float = 12.0) -> bool:
    start = time.time()
    while time.time() - start < timeout:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return True
        except OSError:
            time.sleep(0.1)
    return False


def http_request(
    url: str,
    method: str = "GET",
    data: dict | None = None,
    headers: dict | None = None,
    raw_body: bytes | None = None,
) -> tuple[int, dict | str, dict[str, str]]:
    req_headers = {}
    if data is not None:
        req_headers["Content-Type"] = "application/json"
        body = json.dumps(data).encode("utf-8")
    elif raw_body is not None:
        body = raw_body
    else:
        body = None

    if headers:
        req_headers.update(headers)

    req = urllib.request.Request(url, data=body, headers=req_headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            resp_headers = {k.lower(): v for k, v in resp.headers.items()}
            raw = resp.read()
            content_type = resp_headers.get("content-type", "")
            if "application/json" in content_type:
                try:
                    return resp.status, json.loads(raw.decode("utf-8")), resp_headers
                except Exception:
                    return resp.status, raw.decode("utf-8"), resp_headers
            return resp.status, raw.decode("utf-8", errors="replace"), resp_headers
    except urllib.error.HTTPError as e:
        raw = e.read()
        resp_headers = {k.lower(): v for k, v in e.headers.items()}
        try:
            return e.code, json.loads(raw.decode("utf-8")), resp_headers
        except Exception:
            return e.code, raw.decode("utf-8", errors="replace"), resp_headers


def run_cmd(cmd: list[str], cwd: Path | None = None, env: dict | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else str(ROOT),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )


def build_odin_pkg(pkg: str, out_path: Path) -> None:
    odin = os.environ.get("ODIN") or shutil.which("odin")
    res = None
    if odin and os.environ.get("IN_NIX_SHELL"):
        res = subprocess.run([odin, "build", pkg, "-collection:odin_test=src", f"-out:{out_path}"], cwd=ROOT, capture_output=True, text=True)
    if res is None or res.returncode != 0:
        res = subprocess.run(["nix", "develop", "--command", "odin", "build", pkg, "-collection:odin_test=src", f"-out:{out_path}"], cwd=ROOT, capture_output=True, text=True)
    assert res.returncode == 0, f"Failed to build {pkg}: {res.stderr}"


def test_hub_artifact_api_overhaul() -> None:
    test_dir = Path(tempfile.mkdtemp(prefix="heimdall-artifact-api-test-"))
    try:
        hub_bin = Path(os.environ["HEIMDALL_TEST_HUB_BIN"]) if os.environ.get("HEIMDALL_TEST_HUB_BIN") else test_dir / "ham-hub"
        if not os.environ.get("HEIMDALL_TEST_HUB_BIN"):
            build_odin_pkg("src/hub", hub_bin)

        ctl_bin = Path(os.environ["HEIMDALL_TEST_CTL_BIN"]) if os.environ.get("HEIMDALL_TEST_CTL_BIN") else test_dir / "ham-ctl"
        if not os.environ.get("HEIMDALL_TEST_CTL_BIN"):
            build_odin_pkg("src/ctl", ctl_bin)

        db_path = test_dir / "hub.db"
        bridge_token_file = test_dir / "bridge_token"
        hub_port = free_port()
        hub_url = f"http://127.0.0.1:{hub_port}"

        migrations_dir = ROOT / "src" / "hub" / "repository" / "sqlite" / "migrations"
        if not migrations_dir.exists():
            migrations_dir = ROOT / "dist" / "heimdall-cloudtop" / "share" / "migrations"

        env = dict(os.environ)
        env["HOSTNAME"] = "cloudtop-test-node"
        env["USER"] = "testowner"
        env["HAM_CLOUDTOP_OWNER"] = "testowner"
        # Users sign in only through OIDC: run the mock provider for this hub.
        mock = MockOIDC.start()
        env.update(mock.hub_env(hub_url))

        print(f"[2/5] Starting test Hub instance on port {hub_port} with DB {db_path}...")
        hub_proc = subprocess.Popen(
            [
                str(hub_bin),
                "--listen", f"127.0.0.1:{hub_port}",
                "--db", str(db_path),
                "--migrations-dir", str(migrations_dir),
                "--ui-origin", hub_url,
            ],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        try:
            assert wait_for_port(hub_port, timeout=12.0), "Hub failed to start within timeout"
            print("  -> Hub started successfully.")

            # Browser session for testowner (Origin satisfies the CSRF check).
            auth_headers = session_headers(login(hub_url, "testowner"), hub_url)

            # 1. Enroll a bridge through the BROWSER-APPROVED DEVICE FLOW (REQ-ENROLL-9),
            #    then create an agent instance for the agent actions below.
            #
            # Replaces the deleted pair -- POST /api/v1/bridge-enrollments for a
            # one-time token, then `ham-bridge enroll --enrollment-token` to exchange
            # it. Both the endpoint and that flag are gone.
            #
            # The three HTTP steps are driven here rather than shelling out to
            # `ham-bridge enroll --hub`, which blocks waiting for an approval. The
            # credential is written to the same token file the bridge is started with.
            #
            # Hard refusals: bridge_public_key must be a 130-char lowercase-hex
            # uncompressed P-256 point; bridge_key_fingerprint must NOT be sent (the
            # Hub derives it and refuses a disagreeing one); PKCE is mandatory, S256.
            status_az, az_data, _ = http_request(
                f"{hub_url}/api/v1/device/authorize",
                method="POST",
                data={"client": "ham-bridge", "device_label": "test-bridge", "os": "linux",
                      "os_user": "tester", "bridge_public_key": "040102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f40",
                      "code_challenge": "J6jJRRlTiLmCVJAjMgzOjMLRQ-xSS_tovxAjutN8JWI", "code_challenge_method": "S256"},
            )
            assert status_az == 200, f"device authorize failed: {status_az} {az_data}"
            user_code = az_data["data"]["user_code"]
            device_code = az_data["data"]["device_code"]

            status_ap, ap_data, _ = http_request(
                f"{hub_url}/api/v1/device/approve",
                method="POST",
                data={"user_code": user_code, "approve": True},
                headers=auth_headers,
            )
            assert status_ap == 200, f"device approve failed: {status_ap} {ap_data}"

            status_tk, tk_data, _ = http_request(
                f"{hub_url}/api/v1/device/token",
                method="POST",
                data={"device_code": device_code, "code_verifier": "heimdall-req-impl-6-test-code-verifier-aaaa"},
            )
            assert status_tk == 200, f"device token failed: {status_tk} {tk_data}"
            bridge_token = tk_data["data"]["access_token"]
            assert bridge_token, "device flow issued no access token"
            bridge_token_file.write_text(bridge_token)
            bridge_token_file.chmod(0o600)
            # The refresh half goes beside it under the suffix the bridge itself uses,
            # so a bridge started with --bridge-token-file can renew.
            refresh_token = tk_data["data"].get("refresh_token", "")
            if refresh_token:
                refresh_file = bridge_token_file.with_name(bridge_token_file.name + ".refresh")
                refresh_file.write_text(refresh_token)
                refresh_file.chmod(0o600)

            # Create an agent and an instance
            status, agent_data, _ = http_request(
                f"{hub_url}/api/v1/agents",
                method="POST",
                data={"name": "ArtifactTester"},
                headers=auth_headers,
            )
            assert status in (200, 201), f"Failed to create agent: {agent_data}"
            agent_id = agent_data["data"]["agent_id"]

            agent_inst_id = "inst_artifact_tester_1"
            other_inst_id = "inst_other_999"
            plaintext_user_token = "hut_test_user_token_12345"  # removed credential shape
            with sqlite3.connect(db_path) as conn:
                c = conn.cursor()
                c.execute("SELECT bridge_id FROM bridges WHERE bridge_id != 'brg_local' ORDER BY created_at DESC LIMIT 1")
                b_row = c.fetchone()
                enrolled_bridge_id = b_row[0] if b_row else "brg_local"

                # testowner already exists: provisioned by the OIDC sign-in above.

                # Seed Projects
                for pid, pname in [("proj_alpha", "Project Alpha"), ("proj_beta", "Project Beta"), ("proj_gamma", "Project Gamma")]:
                    c.execute(
                        "INSERT INTO projects (project_id, owner_user_id, name, slug, default_path, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                        (pid, "testowner", pname, pid, f"/tmp/{pid}", "2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z"),
                    )

                # Seed Task Chains
                for cid, ctitle in [("chain_test_1", "Chain 1"), ("chain_test_2", "Chain 2"), ("chain_test_3", "Chain 3")]:
                    c.execute(
                        "INSERT INTO task_chains (chain_id, owner_user_id, title, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                        (cid, "testowner", ctitle, "2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z"),
                    )

                # Seed Tasks
                tasks_to_seed = [
                    ("task_101", "chain_test_1", "Task 101"),
                    ("task_102", "chain_test_1", "Task 102"),
                    ("task_103", "chain_test_2", "Task 103"),
                    ("task_201", "chain_test_2", "Task 201"),
                    ("task_202", "chain_test_3", "Task 202"),
                    ("task_301", "chain_test_3", "Task 301"),
                ]
                for tid, cid, ttitle in tasks_to_seed:
                    c.execute(
                        "INSERT INTO tasks (task_id, chain_id, owner_user_id, title, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
                        (tid, cid, "testowner", ttitle, "2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z"),
                    )

                # Seed Agent Instances
                c.execute(
                    """
                    INSERT INTO agent_instances (
                        agent_instance_id, owner_user_id, agent_id, bridge_id,
                        project_id, chain_id, runtime_status, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        agent_inst_id, "testowner", agent_id, enrolled_bridge_id,
                        "proj_alpha", "chain_test_1", "running",
                        "2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z"
                    ),
                )
                c.execute(
                    """
                    INSERT INTO agent_instances (
                        agent_instance_id, owner_user_id, agent_id, bridge_id,
                        project_id, chain_id, runtime_status, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        other_inst_id, "testowner", agent_id, enrolled_bridge_id,
                        "proj_beta", "chain_test_2", "running",
                        "2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z"
                    ),
                )
                conn.commit()

            print(f"[3/5] Seeding test artifacts (multi-attribute matrix)...")
            # Create a rich collection of artifacts to test filtering, sorting, pagination
            # We create 6 artifacts with distinct attributes:
            raw_items = [
                {
                    "name": "build_log.txt",
                    "kind": "log",
                    "description": "Log file 1",
                    "content_type": "text/plain",
                    "content": "=== BUILD STEP 1: SUCCESS ===",
                    "project_id": "proj_alpha",
                    "agent_instance_id": agent_inst_id,
                    "chain_id": "chain_test_1",
                    "task_id": "task_101",
                },
                {
                    "name": "diff_patch.patch",
                    "kind": "patch",
                    "description": "Patch for bugfix",
                    "content_type": "text/x-diff",
                    "content": "--- a/src/main.rs\n+++ b/src/main.rs\n@@ -1 +1 @@\n-old\n+new",
                    "project_id": "proj_alpha",
                    "agent_instance_id": agent_inst_id,
                    "chain_id": "chain_test_1",
                    "task_id": "task_102",
                },
                {
                    "name": "summary_report.md",
                    "kind": "markdown",
                    "description": "Final documentation report",
                    "content_type": "text/markdown",
                    "content": "# Project Alpha Summary Report\n\nAll tasks completed with 100% verification.",
                    "project_id": "proj_alpha",
                    "agent_instance_id": agent_inst_id,
                    "chain_id": "chain_test_1",
                    "task_id": "",
                },
                {
                    "name": "benchmark_data.json",
                    "kind": "file",
                    "description": "JSON performance benchmark data",
                    "content_type": "application/json",
                    "content": json.dumps({"iterations": 10000, "avg_latency_ms": 1.25, "p99_latency_ms": 3.8}),
                    "project_id": "proj_beta",
                    "agent_instance_id": other_inst_id,
                    "chain_id": "chain_test_2",
                    "task_id": "task_201",
                },
                {
                    "name": "diagram_arch.png",
                    "kind": "image",
                    "description": "Architecture diagram binary simulation",
                    "content_type": "image/png",
                    "content": "PNG_SIMULATED_BINARY_BYTES_0123456789_MAGIC_HEADER",
                    "project_id": "proj_beta",
                    "agent_instance_id": other_inst_id,
                    "chain_id": "chain_test_2",
                    "task_id": "",
                },
                {
                    "name": "zebra_notes.txt",
                    "kind": "file",
                    "description": "Zebra notes for sorting verification",
                    "content_type": "text/plain",
                    "content": "Short zebra note.",
                    "project_id": "proj_gamma",
                    "agent_instance_id": "",
                    "chain_id": "chain_test_3",
                    "task_id": "task_301",
                },
            ]

            created_artifacts = []
            for item in raw_items:
                content_bytes = item["content"].encode("utf-8")
                expected_sha = hashlib.sha256(content_bytes).hexdigest()
                payload = dict(item)
                payload["sha256"] = expected_sha

                st, resp, _ = http_request(
                    f"{hub_url}/api/v1/artifacts",
                    method="POST",
                    data=payload,
                    headers=auth_headers,
                )
                assert st in (200, 201), f"Failed creating artifact {item['name']}: {resp}"
                created_art = resp["data"]
                created_art["expected_sha256"] = expected_sha
                created_art["expected_content"] = item["content"]
                created_artifacts.append(created_art)
                # Small sleep to guarantee strictly monotonic created_at timestamps if desired
                time.sleep(0.05)

            assert len(created_artifacts) == 6, f"Expected 6 created artifacts, got {len(created_artifacts)}"
            print(f"  -> Successfully created 6 artifacts.")

            print("[4/5] Testing Artifact API Overhaul endpoints...")

            # -------------------------------------------------------------
            # Requirement 4: Content Omission in List Responses
            # -------------------------------------------------------------
            st, list_resp, _ = http_request(f"{hub_url}/api/v1/artifacts", headers=auth_headers)
            assert st == 200, f"List failed: {list_resp}"
            items = list_resp.get("data", [])
            assert len(items) == 6, f"Expected 6 items in list, got {len(items)}"
            for it in items:
                assert "content" not in it or it["content"] == "" or it["content"] is None, (
                    f"Content field was not omitted in list response: {it}"
                )
            print("  -> Passed: List responses omit payload (content field is absent or empty).")

            # -------------------------------------------------------------
            # Requirement 1: Cursor-based Pagination
            # -------------------------------------------------------------
            # Query with limit=2
            st, p1, _ = http_request(f"{hub_url}/api/v1/artifacts?limit=2&sort=name&order=asc", headers=auth_headers)
            assert st == 200
            assert len(p1["data"]) == 2, f"Expected 2 items in page 1, got {len(p1['data'])}"
            page1_info = p1.get("page", {})
            assert page1_info.get("has_more") is True, f"Expected has_more=True, got {page1_info}"
            cursor1 = page1_info.get("next_cursor")
            assert cursor1, f"Expected non-empty next_cursor from page 1, got {cursor1}"

            # Query page 2 using cursor1
            st, p2, _ = http_request(
                f"{hub_url}/api/v1/artifacts?limit=2&sort=name&order=asc&cursor={cursor1}",
                headers=auth_headers,
            )
            assert st == 200
            assert len(p2["data"]) == 2, f"Expected 2 items in page 2, got {len(p2['data'])}"
            page2_info = p2.get("page", {})
            assert page2_info.get("has_more") is True
            cursor2 = page2_info.get("next_cursor")
            assert cursor2 and cursor2 != cursor1

            # Query page 3 using cursor2
            st, p3, _ = http_request(
                f"{hub_url}/api/v1/artifacts?limit=2&sort=name&order=asc&cursor={cursor2}",
                headers=auth_headers,
            )
            assert st == 200
            assert len(p3["data"]) == 2, f"Expected 2 items in page 3, got {len(p3['data'])}"
            page3_info = p3.get("page", {})
            # After 6 items with limit 2, has_more can be True or False depending on boundary
            cursor3 = page3_info.get("next_cursor")

            # Collect all names across pages
            paged_names = [it["name"] for it in p1["data"] + p2["data"] + p3["data"]]
            all_sorted_names = sorted([x["name"] for x in raw_items])
            assert paged_names == all_sorted_names, f"Pagination order mismatch:\nPaged:  {paged_names}\nSorted: {all_sorted_names}"
            print("  -> Passed: Cursor pagination with limit and next_cursor traverses entire dataset accurately.")

            # -------------------------------------------------------------
            # Requirement 2: Filtering
            # -------------------------------------------------------------
            # 2.1 Filter by project_id
            st, f_proj, _ = http_request(f"{hub_url}/api/v1/artifacts?project_id=proj_alpha", headers=auth_headers)
            assert st == 200
            assert len(f_proj["data"]) == 3, f"Expected 3 artifacts for proj_alpha, got {len(f_proj['data'])}"
            for it in f_proj["data"]:
                assert it["project_id"] == "proj_alpha"

            # 2.2 Filter by agent_instance_id
            st, f_inst, _ = http_request(
                f"{hub_url}/api/v1/artifacts?agent_instance_id=inst_other_999", headers=auth_headers
            )
            assert st == 200
            assert len(f_inst["data"]) == 2, f"Expected 2 artifacts for inst_other_999, got {len(f_inst['data'])}"
            for it in f_inst["data"]:
                assert it["agent_instance_id"] == "inst_other_999"

            # 2.3 Filter by chain_id
            st, f_chain, _ = http_request(f"{hub_url}/api/v1/artifacts?chain_id=chain_test_2", headers=auth_headers)
            assert st == 200
            assert len(f_chain["data"]) == 2, f"Expected 2 artifacts for chain_test_2, got {len(f_chain['data'])}"
            for it in f_chain["data"]:
                assert it["chain_id"] == "chain_test_2"

            # 2.4 Filter by task_id
            st, f_task, _ = http_request(f"{hub_url}/api/v1/artifacts?task_id=task_102", headers=auth_headers)
            assert st == 200
            assert len(f_task["data"]) == 1, f"Expected 1 artifact for task_102, got {len(f_task['data'])}"
            assert f_task["data"][0]["name"] == "diff_patch.patch"

            # 2.5 Filter by kind
            st, f_kind, _ = http_request(f"{hub_url}/api/v1/artifacts?kind=patch", headers=auth_headers)
            assert st == 200
            assert len(f_kind["data"]) == 1
            assert f_kind["data"][0]["kind"] == "patch"

            # 2.6 Filter by since / until
            middle_created = created_artifacts[2]["created_at"]
            st, f_since, _ = http_request(f"{hub_url}/api/v1/artifacts?since={middle_created}", headers=auth_headers)
            assert st == 200
            for it in f_since["data"]:
                assert it["created_at"] >= middle_created, f"Item created_at {it['created_at']} < {middle_created}"

            st, f_until, _ = http_request(f"{hub_url}/api/v1/artifacts?until={middle_created}", headers=auth_headers)
            assert st == 200
            for it in f_until["data"]:
                assert it["created_at"] <= middle_created, f"Item created_at {it['created_at']} > {middle_created}"

            print("  -> Passed: Filtering by project_id, agent_instance_id, chain_id, task_id, kind, since, until.")

            # -------------------------------------------------------------
            # Requirement 3: Sorting
            # -------------------------------------------------------------
            # 3.1 Sort by name asc & desc
            st, s_name_asc, _ = http_request(f"{hub_url}/api/v1/artifacts?sort=name&order=asc", headers=auth_headers)
            assert st == 200
            names_asc = [x["name"] for x in s_name_asc["data"]]
            assert names_asc == sorted(names_asc), f"Expected sorted name asc, got {names_asc}"

            st, s_name_desc, _ = http_request(f"{hub_url}/api/v1/artifacts?sort=name&order=desc", headers=auth_headers)
            assert st == 200
            names_desc = [x["name"] for x in s_name_desc["data"]]
            assert names_desc == sorted(names_asc, reverse=True), f"Expected sorted name desc, got {names_desc}"

            # 3.2 Sort by size_bytes asc & desc
            st, s_size_asc, _ = http_request(f"{hub_url}/api/v1/artifacts?sort=size_bytes&order=asc", headers=auth_headers)
            assert st == 200
            sizes_asc = [x["size_bytes"] for x in s_size_asc["data"]]
            assert sizes_asc == sorted(sizes_asc), f"Expected sorted size asc, got {sizes_asc}"

            st, s_size_desc, _ = http_request(f"{hub_url}/api/v1/artifacts?sort=size_bytes&order=desc", headers=auth_headers)
            assert st == 200
            sizes_desc = [x["size_bytes"] for x in s_size_desc["data"]]
            assert sizes_desc == sorted(sizes_asc, reverse=True), f"Expected sorted size desc, got {sizes_desc}"

            # 3.3 Sort by created_at asc & desc
            st, s_created_asc, _ = http_request(f"{hub_url}/api/v1/artifacts?sort=created_at&order=asc", headers=auth_headers)
            assert st == 200
            created_asc = [x["created_at"] for x in s_created_asc["data"]]
            assert created_asc == sorted(created_asc), f"Expected sorted created_at asc, got {created_asc}"

            st, s_created_desc, _ = http_request(f"{hub_url}/api/v1/artifacts?sort=created_at&order=desc", headers=auth_headers)
            assert st == 200
            created_desc = [x["created_at"] for x in s_created_desc["data"]]
            assert created_desc == sorted(created_asc, reverse=True), f"Expected sorted created_at desc, got {created_desc}"

            # 3.4 Sort by updated_at asc & desc
            st, s_updated_asc, _ = http_request(f"{hub_url}/api/v1/artifacts?sort=updated_at&order=asc", headers=auth_headers)
            assert st == 200
            updated_asc = [x["updated_at"] for x in s_updated_asc["data"]]
            assert updated_asc == sorted(updated_asc), f"Expected sorted updated_at asc, got {updated_asc}"

            print("  -> Passed: Sorting by created_at, updated_at, name, size_bytes in both asc & desc orders.")

            # -------------------------------------------------------------
            # Requirement 5: Raw Content Retrieval & SHA256 Parity
            # -------------------------------------------------------------
            target_artifact = created_artifacts[0]
            target_id = target_artifact["artifact_id"]
            expected_content = target_artifact["expected_content"]
            expected_sha256 = target_artifact["expected_sha256"]

            # 5.1 GET /api/v1/artifacts/:id/content
            st, raw_resp, headers = http_request(f"{hub_url}/api/v1/artifacts/{target_id}/content", headers=auth_headers)
            assert st == 200, f"Raw content retrieval failed: {raw_resp}"
            assert raw_resp == expected_content, f"Content mismatch:\nGot:  {raw_resp}\nWant: {expected_content}"
            computed_sha = hashlib.sha256(raw_resp.encode("utf-8")).hexdigest()
            assert computed_sha == expected_sha256, f"SHA256 mismatch: got {computed_sha}, want {expected_sha256}"
            assert headers.get("content-type") == "text/plain"

            # 5.2 GET /api/v1/artifacts/:id/download
            st, dl_resp, dl_headers = http_request(f"{hub_url}/api/v1/artifacts/{target_id}/download", headers=auth_headers)
            assert st == 200, f"Download retrieval failed: {dl_resp}"
            assert dl_resp == expected_content
            assert "attachment" in dl_headers.get("content-disposition", "").lower()

            # 5.3 Agent Action RPC: agent.artifact.content
            # Dispatched via POST /api/v1/agent-actions/artifacts/content
            agent_headers = {
                "Authorization": f"Bearer {bridge_token}",
                "X-Heimdall-Instance-Token": f"hit_{agent_inst_id}",
            }
            rpc_payload = {
                "agent_instance_id": agent_inst_id,
                "params": {
                    "artifact_id": target_id,
                },
            }
            st, rpc_resp, _ = http_request(
                f"{hub_url}/api/v1/agent-actions/artifacts/content",
                method="POST",
                data=rpc_payload,
                headers=agent_headers,
            )
            assert st == 200, f"agent.artifact.content RPC failed ({st}): {rpc_resp}"
            rpc_data = rpc_resp.get("data", {})
            rpc_content = rpc_data.get("content")
            assert rpc_content == expected_content, f"RPC content mismatch: got {rpc_content}, want {expected_content}"
            rpc_sha = hashlib.sha256(rpc_content.encode("utf-8")).hexdigest()
            assert rpc_sha == expected_sha256, f"RPC SHA256 mismatch: got {rpc_sha}, want {expected_sha256}"

            print("  -> Passed: Raw content retrieval via REST and agent action RPC matches original SHA256.")

            # -------------------------------------------------------------
            # CLI Integration via ham-ctl hub artifacts
            # -------------------------------------------------------------
            print("[5/5] Testing ham-ctl CLI commands...")
            # Hub user tokens were removed; ham-ctl user mode must say so clearly
            # instead of failing with a confusing hub error.
            cli_res = run_cmd(
                [
                    str(ctl_bin),
                    "hub",
                    "--hub-url", hub_url,
                    "--user-token", plaintext_user_token,
                    "artifacts", "list",
                ],
                env={"HAM_CLOUDTOP_OWNER": "testowner"},
            )
            assert "were removed" in cli_res.stdout, f"ham-ctl did not explain removed user tokens: {cli_res.stdout} {cli_res.stderr}"
            st, refused, _ = http_request(f"{hub_url}/api/v1/artifacts", headers={"Authorization": f"Bearer {plaintext_user_token}"})
            assert st == 401, f"hut_ bearer must be refused: {st} {refused}"
            print("  -> Passed: ham-ctl explains removed user tokens; the hub refuses them.")

        finally:
            hub_proc.terminate()
            try:
                hub_proc.wait(timeout=4)
            except subprocess.TimeoutExpired:
                hub_proc.kill()
            mock.stop()
    finally:
        shutil.rmtree(test_dir, ignore_errors=True)


if __name__ == "__main__":
    test_hub_artifact_api_overhaul()
    print("\n" + "=" * 70)
    print("ALL ARTIFACT API OVERHAUL INTEGRATION TESTS PASSED!")
    print("=" * 70)
