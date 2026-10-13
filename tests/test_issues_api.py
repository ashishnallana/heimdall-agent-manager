#!/usr/bin/env python3
"""Integration and regression test suite for REQ-ISSUES-API-AND-CLI:
Verifies Issues REST API handlers, voting/unvoting endpoints, owner authorization,
and ham-ctl CLI verbs in both user mode and agent mode.
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


def build_odin_pkg(pkg: str, out_path: Path) -> None:
    import shutil
    odin = os.environ.get("ODIN") or shutil.which("odin")
    res = None
    if odin and os.environ.get("IN_NIX_SHELL"):
        res = subprocess.run([odin, "build", pkg, "-collection:odin_test=src", f"-out:{out_path}"], cwd=ROOT, capture_output=True, text=True)
    if res is None or res.returncode != 0:
        res = subprocess.run(["nix", "develop", "--command", "odin", "build", pkg, "-collection:odin_test=src", f"-out:{out_path}"], cwd=ROOT, capture_output=True, text=True)
    require(res.returncode == 0, f"Compilation of {pkg} failed: {res.stderr}")


def test_live_hub_and_cli() -> None:
    import shutil
    import tempfile
    print("Testing live Hub REST API and ham-ctl CLI...")
    tmp_dir = Path(tempfile.mkdtemp(prefix="ham-issues-test-"))
    hub_bin = tmp_dir / "ham-hub"
    ctl_bin = tmp_dir / "ham-ctl"

    print("Building hub and ctl binaries...")
    build_odin_pkg("src/hub", hub_bin)
    build_odin_pkg("src/ctl", ctl_bin)

    port = find_free_port()
    db_path = str(tmp_dir / f"ham-issues-test-{port}.db")

    migrations_dir = str(ROOT / "src/hub/repository/sqlite/migrations")

    # Provision user 1
    user1_out = subprocess.check_output(
        [str(hub_bin), "users", "create", "--name", "Alice", "--email", "alice@example.com", "--db", db_path, "--migrations-dir", migrations_dir],
        text=True,
    )
    user1_tok = None
    for line in user1_out.splitlines():
        line = line.strip()
        if line.startswith("token="):
            user1_tok = line.split("=", 1)[1].strip()
            break
    require(user1_tok is not None and len(user1_tok) > 0, "Failed to provision user1 token")

    # Provision user 2 (for authorization isolation tests)
    user2_out = subprocess.check_output(
        [str(hub_bin), "users", "create", "--name", "Bob", "--email", "bob@example.com", "--db", db_path, "--migrations-dir", migrations_dir],
        text=True,
    )
    user2_tok = None
    for line in user2_out.splitlines():
        line = line.strip()
        if line.startswith("token="):
            user2_tok = line.split("=", 1)[1].strip()
            break
    require(user2_tok is not None and len(user2_tok) > 0, "Failed to provision user2 token")

    # Start Hub server
    hub_proc = subprocess.Popen(
        [str(hub_bin), "--listen", f"127.0.0.1:{port}", "--db", db_path],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    base_url = f"http://127.0.0.1:{port}"

    try:
        # Wait for Hub to become healthy
        ready = False
        for _ in range(50):
            try:
                with urllib.request.urlopen(f"{base_url}/api/v1/health", timeout=1) as resp:
                    if resp.status == 200:
                        ready = True
                        break
            except Exception:
                time.sleep(0.1)
        require(ready, "Hub failed to start within timeout")

        def api_call(method: str, path: str, token: str, payload=None) -> tuple[int, dict]:
            url = f"{base_url}{path}"
            data = json.dumps(payload).encode("utf-8") if payload is not None else None
            req = urllib.request.Request(url, data=data, method=method)
            req.add_header("Authorization", f"Bearer {token}")
            req.add_header("Content-Type", "application/json")
            try:
                with urllib.request.urlopen(req, timeout=5) as resp:
                    body = json.loads(resp.read().decode("utf-8"))
                    return resp.status, body
            except urllib.error.HTTPError as e:
                err_body = json.loads(e.read().decode("utf-8")) if e.fp else {}
                return e.code, err_body

        # -------------------------------------------------------------
        # 1. Test POST /api/v1/issues (Create Issue)
        # -------------------------------------------------------------
        print("Testing Issue creation...")
        status, body = api_call("POST", "/api/v1/issues", user1_tok, {
            "title": "Bug in compiler",
            "description": "Fails on specific edge case",
            "scope": "project",
            "target_id": "proj_test_1",
            "chain_id": "chain_test_1",
        })
        require(status == 201, f"Expected 201 Created, got {status}: {body}")
        issue = body["data"]
        issue_id = issue["issue_id"]
        require(issue_id.startswith("iss_"), f"Issue ID should start with iss_, got {issue_id}")
        require(issue["title"] == "Bug in compiler", "Title should match")
        require(issue["description"] == "Fails on specific edge case", "Description should match")
        require("comments" in issue and isinstance(issue["comments"], list), "Create issue response should contain embedded comments array")
        require(len(issue["comments"]) == 0, "Created issue should have empty comments array")
        require(issue["status"] == "new", "Initial status should be new")
        require(issue["scope_type"] == "project", "Scope should be project")
        require(issue["target_id"] == "proj_test_1", "Target ID should match")
        require(issue["chain_id"] == "chain_test_1", "Chain ID should match")
        require(issue["vote_count"] == 0, "Initial vote_count should be 0")
        require(issue["comment_count"] == 0, "Initial comment_count should be 0")
        require(issue["has_voted"] is False, "Initial has_voted should be false")
        require(issue["closed_at"] == "", "Initial closed_at should be empty")

        # -------------------------------------------------------------
        # 2. Test GET /api/v1/issues/:id (Get Issue)
        # -------------------------------------------------------------
        print("Testing Get Issue (detail payload)...")
        status, body = api_call("GET", f"/api/v1/issues/{issue_id}", user1_tok)
        require(status == 200, f"Expected 200 OK, got {status}: {body}")
        fetched = body["data"]
        require(fetched["issue_id"] == issue_id, "Fetched issue_id should match")
        require(fetched["description"] == "Fails on specific edge case", "Get Issue must have full description")
        require("comments" in fetched and isinstance(fetched["comments"], list), "Get Issue must have embedded comments array")

        # -------------------------------------------------------------
        # 3. Test GET /api/v1/issues (List Issues - Lean Payload)
        # -------------------------------------------------------------
        print("Testing List Issues (lean payload)...")
        status, body = api_call("GET", "/api/v1/issues?status=new", user1_tok)
        require(status == 200, f"Expected 200 OK, got {status}: {body}")
        issues = body["data"]
        require(len(issues) >= 1, "Should list at least 1 issue")
        require(any(i["issue_id"] == issue_id for i in issues), "Created issue should be in list")

        for item in issues:
            require("description_preview" in item, "List issue item must contain description_preview")
            require("description" not in item, "List issue item must NOT contain full description")
            require("comments" not in item, "List issue item must NOT contain comments array")
            require("comment_count" in item, "List issue item must contain comment_count")
            require("vote_count" in item, "List issue item must contain vote_count")

        target_item = next(i for i in issues if i["issue_id"] == issue_id)
        require(target_item["description_preview"] == "Fails on specific edge case", "description_preview should match snippet")

        # Test filter by scope
        status, body = api_call("GET", "/api/v1/issues?scope=project", user1_tok)
        require(status == 200 and len(body["data"]) >= 1, "Filter by scope=project should match")

        status, body = api_call("GET", "/api/v1/issues?scope=global", user1_tok)
        require(status == 200 and len(body["data"]) == 0, "Filter by scope=global should be empty")

        # -------------------------------------------------------------
        # 4. Test PATCH /api/v1/issues/:id (Update Issue & Closed Timestamp)
        # -------------------------------------------------------------
        print("Testing Patch Issue & status transition...")
        status, body = api_call("PATCH", f"/api/v1/issues/{issue_id}", user1_tok, {
            "status": "fixed",
            "description": "Resolved in patch",
        })
        require(status == 200, f"Expected 200 OK, got {status}: {body}")
        updated = body["data"]
        require(updated["status"] == "fixed", "Status should be fixed")
        require(updated["description"] == "Resolved in patch", "Description should be updated")
        require("comments" in updated and isinstance(updated["comments"], list), "Patched issue must contain comments array")
        require(updated["closed_at"] != "", "closed_at timestamp should be populated when status is fixed")

        # Reopen issue -> closed_at cleared
        status, body = api_call("PATCH", f"/api/v1/issues/{issue_id}", user1_tok, {
            "status": "new",
        })
        require(status == 200, f"Expected 200 OK, got {status}: {body}")
        require(body["data"]["status"] == "new", "Status should be new")
        require(body["data"]["closed_at"] == "", "closed_at timestamp should be cleared when status reverts to new")

        # -------------------------------------------------------------
        # 5. Test Comments CRUD
        # -------------------------------------------------------------
        print("Testing Comments API...")
        # Create comment
        status, body = api_call("POST", f"/api/v1/issues/{issue_id}/comments", user1_tok, {
            "body": "First comment on the issue",
            "author_id": "inst_worker_1",
            "author_name": "Worker 1",
        })
        require(status == 201, f"Expected 201 Created for comment, got {status}: {body}")
        comment = body["data"]
        comment_id = comment["comment_id"]
        require(comment_id.startswith("icmt_"), f"comment_id should start with icmt_, got {comment_id}")
        require(comment["body"] == "First comment on the issue", "Comment body should match")

        # List comments
        status, body = api_call("GET", f"/api/v1/issues/{issue_id}/comments", user1_tok)
        require(status == 200, f"Expected 200 OK, got {status}: {body}")
        comments = body["data"]
        require(len(comments) == 1, f"Expected 1 comment, got {len(comments)}")
        require(comments[0]["comment_id"] == comment_id, "Listed comment ID should match")

        # Verify comment count and embedded comments array on issue
        status, body = api_call("GET", f"/api/v1/issues/{issue_id}", user1_tok)
        require(status == 200, f"Expected 200 OK, got {status}: {body}")
        detail_data = body["data"]
        require(detail_data["comment_count"] == 1, "Issue comment_count should be 1")
        require("comments" in detail_data and isinstance(detail_data["comments"], list), "Embedded comments array must be present")
        require(len(detail_data["comments"]) == 1, f"Embedded comments should have 1 item, got {len(detail_data['comments'])}")
        require(detail_data["comments"][0]["comment_id"] == comment_id, "Embedded comment_id should match")
        require(detail_data["comments"][0]["body"] == "First comment on the issue", "Embedded comment body should match")
        require(detail_data["comments"][0]["author_name"] == "Worker 1", "Embedded comment author_name should match")

        # Delete comment
        status, body = api_call("DELETE", f"/api/v1/issues/{issue_id}/comments/{comment_id}", user1_tok)
        require(status == 200, f"Expected 200 OK for comment delete, got {status}: {body}")
        require(body["data"].get("deleted") is True, "Comment deleted should be true")

        # Verify comments list is now empty
        status, body = api_call("GET", f"/api/v1/issues/{issue_id}/comments", user1_tok)
        require(len(body["data"]) == 0, "Comments list should be empty after deletion")

        # -------------------------------------------------------------
        # 6. Test Voting, Duplicate Vote Rejection, and Unvoting
        # -------------------------------------------------------------
        print("Testing Voting & Unvoting enforcement...")
        # Vote 1
        status, body = api_call("POST", f"/api/v1/issues/{issue_id}/vote", user1_tok, {
            "voter_id": "voter_agent_1",
            "voter_name": "Agent 1",
        })
        require(status == 200, f"Expected 200 OK for vote, got {status}: {body}")
        require(body["data"].get("voted") is True, "voted should be true")

        # Check issue has_voted and vote_count
        status, body = api_call("GET", f"/api/v1/issues/{issue_id}?voter_id=voter_agent_1", user1_tok)
        require(body["data"]["has_voted"] is True, "has_voted should be true for voter_agent_1")
        require(body["data"]["vote_count"] == 1, "vote_count should be 1")

        # Duplicate vote by voter_agent_1 must be rejected with 409 Conflict
        status, body = api_call("POST", f"/api/v1/issues/{issue_id}/vote", user1_tok, {
            "voter_id": "voter_agent_1",
            "voter_name": "Agent 1",
        })
        require(status == 409, f"Expected 409 Conflict for duplicate vote, got {status}: {body}")

        # Second voter votes
        status, body = api_call("POST", f"/api/v1/issues/{issue_id}/vote", user1_tok, {
            "voter_id": "voter_agent_2",
            "voter_name": "Agent 2",
        })
        require(status == 200, f"Expected 200 OK for voter 2, got {status}: {body}")

        # List votes
        status, body = api_call("GET", f"/api/v1/issues/{issue_id}/votes", user1_tok)
        require(status == 200, f"Expected 200 OK for votes list, got {status}: {body}")
        votes = body["data"]
        require(len(votes) == 2, f"Expected 2 votes, got {len(votes)}")
        voter_ids = {v["voter_id"] for v in votes}
        require("voter_agent_1" in voter_ids and "voter_agent_2" in voter_ids, "Both voters should be recorded")

        # Unvote voter_agent_1
        status, body = api_call("DELETE", f"/api/v1/issues/{issue_id}/vote?voter_id=voter_agent_1", user1_tok)
        require(status == 200, f"Expected 200 OK for unvote, got {status}: {body}")
        require(body["data"].get("unvoted") is True, "unvoted should be true")

        # Verify has_voted is cleared and vote_count is 1
        status, body = api_call("GET", f"/api/v1/issues/{issue_id}?voter_id=voter_agent_1", user1_tok)
        require(body["data"]["has_voted"] is False, "has_voted should be false after unvote")
        require(body["data"]["vote_count"] == 1, "vote_count should be decremented to 1")

        # Duplicate unvote returns 404
        status, body = api_call("DELETE", f"/api/v1/issues/{issue_id}/vote?voter_id=voter_agent_1", user1_tok)
        require(status == 404, f"Expected 404 for duplicate unvote, got {status}: {body}")

        # -------------------------------------------------------------
        # 7. Test Owner Authorization Isolation
        # -------------------------------------------------------------
        print("Testing Owner Authorization Isolation...")
        # User 2 tries to access User 1's issue
        status, body = api_call("GET", f"/api/v1/issues/{issue_id}", user2_tok)
        require(status in (403, 404), f"User 2 should not access User 1's issue, got status {status}")

        # User 2 lists issues -> should not see User 1's issue
        status, body = api_call("GET", "/api/v1/issues", user2_tok)
        require(status == 200, f"User 2 list issues should succeed, got {status}")
        require(len(body["data"]) == 0, f"User 2 should see 0 issues, got {len(body['data'])}")

        # -------------------------------------------------------------
        # 8. Test DELETE /api/v1/issues/:id (Delete Issue)
        # -------------------------------------------------------------
        print("Testing Issue deletion...")
        status, body = api_call("DELETE", f"/api/v1/issues/{issue_id}", user1_tok)
        require(status == 200, f"Expected 200 OK for issue delete, got {status}: {body}")
        require(body["data"].get("deleted") is True, "Issue deleted should be true")

        status, body = api_call("GET", f"/api/v1/issues/{issue_id}", user1_tok)
        require(status == 404, f"Deleted issue should return 404, got {status}")

        # -------------------------------------------------------------
        # 9. Test CLI verbs (ham-ctl issue ...)
        # -------------------------------------------------------------
        print("Testing ham-ctl CLI commands...")
        def run_ctl(*cmd_args: str) -> dict:
            full_cmd = [str(ctl_bin)] + list(cmd_args) + ["--hub-url", base_url, "--user-token", user1_tok]
            out = subprocess.check_output(full_cmd, text=True, cwd=ROOT)
            return json.loads(out)

        # CLI: create
        res = run_ctl("issue", "create", "--title", "CLI Created Issue", "--description", "CLI Description", "--scope", "global")
        require("data" in res and "issue_id" in res["data"], f"CLI create failed: {res}")
        cli_iss_id = res["data"]["issue_id"]
        require(cli_iss_id.startswith("iss_"), f"CLI issue_id invalid: {cli_iss_id}")

        # CLI: show
        res = run_ctl("issue", "show", cli_iss_id)
        require("data" in res and res["data"]["title"] == "CLI Created Issue", f"CLI show failed: {res}")
        require("description" in res["data"] and res["data"]["description"] == "CLI Description", "CLI show must include description")
        require("comments" in res["data"] and isinstance(res["data"]["comments"], list), "CLI show must include comments array")

        # CLI: list
        res = run_ctl("issue", "list", "--status", "new")
        require("data" in res and len(res["data"]) >= 1, f"CLI list failed: {res}")
        cli_item = next(i for i in res["data"] if i["issue_id"] == cli_iss_id)
        require("description_preview" in cli_item, "CLI list item must include description_preview")
        require("description" not in cli_item, "CLI list item must NOT include full description")
        require("comments" not in cli_item, "CLI list item must NOT include comments array")
        require("comment_count" in cli_item, "CLI list item must include comment_count")

        # CLI: update
        res = run_ctl("issue", "update", cli_iss_id, "--status", "fixed")
        require("data" in res and res["data"]["status"] == "fixed", f"CLI update failed: {res}")

        # CLI: comment
        res = run_ctl("issue", "comment", cli_iss_id, "--body", "Comment from CLI")
        require("data" in res and res["data"]["body"] == "Comment from CLI", f"CLI comment failed: {res}")

        # CLI: vote
        res = run_ctl("issue", "vote", cli_iss_id, "--voter-id", "cli_agent_voter")
        require("data" in res and res["data"].get("voted") is True, f"CLI vote failed: {res}")

        # CLI: unvote
        res = run_ctl("issue", "unvote", cli_iss_id, "--voter-id", "cli_agent_voter")
        require("data" in res and res["data"].get("unvoted") is True, f"CLI unvote failed: {res}")

        # CLI: delete
        res = run_ctl("issue", "delete", cli_iss_id)
        require("data" in res and res["data"].get("deleted") is True, f"CLI delete failed: {res}")

        print("Live Hub and CLI tests: ALL PASSED")

    finally:
        hub_proc.terminate()
        try:
            hub_proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            hub_proc.kill()
        shutil.rmtree(tmp_dir, ignore_errors=True)


def main() -> None:
    print("=" * 60)
    print("RUNNING REQ-ISSUES-API-AND-CLI TEST SUITE")
    print("=" * 60)
    test_live_hub_and_cli()
    print("=" * 60)
    print("ALL TESTS PASSED SUCCESSFULLY!")
    print("=" * 60)


if __name__ == "__main__":
    main()
