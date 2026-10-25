#!/usr/bin/env python3
"""Management API test for runnable ham-dev-proxy (DP-2 / DP-3 / DP-7).

Drives the loopback-only JSON management API end-to-end against a running
ham-dev-proxy + echo Hub:
  - POST /_dev/api/users  creates a persisted, immediately-selectable user (DP-2)
  - duplicate / empty username -> 409 (DP-2)
  - POST /_dev/api/active     sets persisted active + ham_dev_user cookie (DP-3),
    and the next sign-in (/api/v1/auth/login) is hinted as that user; proxied
    requests carry no identity headers (DP-3 / AC2)
  - DELETE /_dev/api/users/<active> removes the user AND clears active (DP-7 / AC3)
  - non-loopback bind -> every /_dev/api/* route returns 404 (DP-7 / AC4)
  - management paths are never forwarded to the Hub (DP-6 invariant)

Run: HAM_DEV_PROXY_BIN=<path> python3 tests/test_ham_dev_proxy_management_api.py
"""
from __future__ import annotations

import http.server
import json
import os
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
from dev_proxy_oidc_fixture import answer_login_redirect, assert_no_identity_headers, login_hint  # noqa: E402


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class HubHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if answer_login_redirect(self):
            return
        body = json.dumps({
            "path": self.path,
            "headers": {k: v for k, v in self.headers.items()},
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


def wait_for_proxy(proc: subprocess.Popen, port: int) -> None:
    deadline = time.time() + 10
    while time.time() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(f"proxy exited early: {proc.poll()}\n{proc.stdout.read() if proc.stdout else ''}")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.05)
    raise RuntimeError("proxy did not start")


def start_proxy(proxy_bin: str, listen: str, hub_port: int, testhome: str) -> subprocess.Popen:
    env = dict(os.environ)
    env["HEIMDALL_HOME"] = testhome
    return subprocess.Popen(
        [proxy_bin, "--listen", listen, "--hub-url", f"http://127.0.0.1:{hub_port}"],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        env=env,
    )


def api(base: str, method: str, path: str, body: dict | None = None) -> tuple[int, dict | None, str]:
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json"} if body is not None else {}
    req = urllib.request.Request(f"{base}{path}", data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            raw = resp.read().decode()
            parsed = _maybe_json(raw)
            return resp.status, parsed, resp.headers.get("Set-Cookie", "")
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        parsed = _maybe_json(raw)
        return e.code, parsed, e.headers.get("Set-Cookie", "")


def _maybe_json(raw: str) -> dict | None:
    # Management error responses may be text/plain (e.g. the non-loopback 404);
    # only parse when the body looks like JSON to avoid masking the status code.
    if not raw or not raw.lstrip().startswith(("{", "[")):
        return None
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return None


def ensure_proxy_bin(temp_dir: Path) -> Path:
    import shutil
    env_bin = os.environ.get("HAM_DEV_PROXY_BIN")
    if env_bin and Path(env_bin).exists():
        return Path(env_bin)
    out_bin = temp_dir / "ham-dev-proxy"
    odin = os.environ.get("ODIN") or shutil.which("odin")
    if odin:
        subprocess.run([odin, "build", "src/dev_proxy", "-collection:odin_test=src", f"-out:{out_bin}"], cwd=ROOT, check=True)
    else:
        subprocess.run(["nix", "develop", "--command", "odin", "build", "src/dev_proxy", "-collection:odin_test=src", f"-out:{out_bin}"], cwd=ROOT, check=True)
    return out_bin


def main() -> None:
    import shutil
    import tempfile

    testhome = Path(tempfile.mkdtemp())
    try:
        proxy_bin = ensure_proxy_bin(testhome)
        hub_port = free_port()
        proxy_port = free_port()
        hub = http.server.ThreadingHTTPServer(("127.0.0.1", hub_port), HubHandler)
        threading.Thread(target=hub.serve_forever, daemon=True).start()

        proc = start_proxy(str(proxy_bin), f"127.0.0.1:{proxy_port}", hub_port, str(testhome))
        try:
            wait_for_proxy(proc, proxy_port)
            base = f"http://127.0.0.1:{proxy_port}"

            # AC1 (DP-2): create -> 201; new user appears in GET and is selectable.
            status, created, _ = api(base, "POST", "/_dev/api/users", {"username": "carol", "display_name": "Carol", "email": "carol@example.com"})
            assert status == 201, f"create should be 201, got {status}: {created}"
            assert created == {"username": "carol", "display_name": "Carol", "email": "carol@example.com"}, f"created body mismatch: {created}"

            status, listing, _ = api(base, "GET", "/_dev/api/users")
            assert status == 200
            usernames = [u["username"] for u in listing["users"]]
            assert "carol" in usernames and "tanmay" in usernames and "reviewer" in usernames, f"roster missing users: {usernames}"

            # AC1 (DP-2): duplicate username -> 409; empty username -> 409.
            status, _, _ = api(base, "POST", "/_dev/api/users", {"username": "carol"})
            assert status == 409, f"duplicate should be 409, got {status}"
            status, _, _ = api(base, "POST", "/_dev/api/users", {"display_name": "no username"})
            assert status == 409, f"empty username should be 409, got {status}"

            # AC2 (DP-3): set active -> 200 + ham_dev_user cookie.
            status, _, cookie = api(base, "POST", "/_dev/api/active", {"username": "carol"})
            assert status == 200, f"set active should be 200, got {status}"
            assert "ham_dev_user=carol" in cookie, f"set-active should set ham_dev_user cookie; got {cookie!r}"

            # AC2 (DP-3): persisted active reflected in GET, and a proxied /api/v1
            # sign-in (no cookie) is hinted as carol; nothing identity-bearing is injected.
            status, listing, _ = api(base, "GET", "/_dev/api/users")
            assert listing["active"] == "carol", f"active should be carol, got {listing['active']}"
            assert login_hint(base) == "carol", "next sign-in should be hinted as carol"
            fwd = json.loads(urllib.request.urlopen(f"{base}/api/v1/me", timeout=5).read())
            assert_no_identity_headers(fwd["headers"])

            # AC3 (DP-7): delete the active user -> 204 AND active is cleared.
            status, _, _ = api(base, "DELETE", "/_dev/api/users/carol")
            assert status == 204, f"delete should be 204, got {status}"
            status, listing, _ = api(base, "GET", "/_dev/api/users")
            assert listing["active"] is None, f"active should be cleared after deleting active user; got {listing['active']}"
            assert "carol" not in [u["username"] for u in listing["users"]], "carol should be gone from roster"

            # DP-6 invariant: management paths are never forwarded to the Hub
            # (the echo Hub only handles GET; a POST to /_dev/api/users must not
            # appear as a forwarded GET to the Hub). Verified implicitly above
            # since the proxy answered all /_dev/api/* locally without error.

            # Management mutation persisted across the in-memory snapshot: a fresh
            # create on a different user is reflected in a subsequent GET.
            status, _, _ = api(base, "POST", "/_dev/api/users", {"username": "dave", "display_name": "Dave", "email": "dave@example.com"})
            assert status == 201
            status, listing, _ = api(base, "GET", "/_dev/api/users")
            assert "dave" in [u["username"] for u in listing["users"]], "dave should be visible after create (shared config)"

            print("PASS: management API create/list/select/delete + forwarded identity + persisted active")
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()
            hub.shutdown()
            hub.server_close()

        # AC4 (DP-7): non-loopback bind -> every /_dev/api/* returns 404.
        nl_port = free_port()
        nl_hub_port = free_port()
        nl_hub = http.server.ThreadingHTTPServer(("127.0.0.1", nl_hub_port), HubHandler)
        threading.Thread(target=nl_hub.serve_forever, daemon=True).start()
        nl_proc = start_proxy(str(proxy_bin), f"0.0.0.0:{nl_port}", nl_hub_port, str(testhome))
        try:
            wait_for_proxy(nl_proc, nl_port)
            status, _, _ = api(f"http://127.0.0.1:{nl_port}", "GET", "/_dev/api/users")
            assert status == 404, f"non-loopback GET management should be 404, got {status}"
            status, _, _ = api(f"http://127.0.0.1:{nl_port}", "POST", "/_dev/api/users", {"username": "evil"})
            assert status == 404, f"non-loopback POST management should be 404, got {status}"
            print("PASS: non-loopback bind disables management routes (404) (DP-7)")
        finally:
            nl_proc.terminate()
            try:
                nl_proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                nl_proc.kill()
            nl_hub.shutdown()
            nl_hub.server_close()

        print("ALL PASS")
    finally:
        shutil.rmtree(testhome, ignore_errors=True)


if __name__ == "__main__":
    main()
