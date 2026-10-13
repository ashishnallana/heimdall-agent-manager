#!/usr/bin/env python3
"""Persistence + active-selection test for runnable ham-dev-proxy (DP-1 / DP-5).

Proves the persisted dev-user store at <data_dir>/dev-proxy/users.json:
  - round-trips a persisted roster (non-seed users become selectable),
  - is honored on startup: a request with no cookie resolves to the persisted
    active user (DP-5),
  - is additive with seed users (seed users remain selectable),
  - still lets an existing ham_dev_user cookie win per-request (DP-5),
  - survives a process restart with the same persisted active,
  - preserves DP-6 forwarding invariants (Authorization bearer passthrough,
    spoofable X-authentik-* stripped).

The store path follows the codebase data-dir convention: HEIMDALL_HOME is the
data-dir root, so the store lives at $HEIMDALL_HOME/dev-proxy/users.json.

Run: HAM_DEV_PROXY_BIN=<path> python3 tests/test_ham_dev_proxy_persistence.py
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


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class HubHandler(http.server.BaseHTTPRequestHandler):
    """Echoes the request path + received headers so the test can inspect what
    the proxy injected server-side."""

    def do_GET(self):
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


def start_proxy(proxy_bin: str, proxy_port: int, hub_port: int, testhome: str) -> subprocess.Popen:
    env = dict(os.environ)
    env["HEIMDALL_HOME"] = testhome
    return subprocess.Popen(
        [proxy_bin, "--listen", f"127.0.0.1:{proxy_port}", "--hub-url", f"http://127.0.0.1:{hub_port}"],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        env=env,
    )


def assert_user_injected(resp_headers: dict, expected_username: str, expected_email: str, ctx: str) -> None:
    got_user = resp_headers.get("x-authentik-username")
    got_email = resp_headers.get("x-authentik-email")
    if got_user != expected_username or got_email != expected_email:
        raise AssertionError(f"{ctx}: expected user={expected_username} email={expected_email}, got {resp_headers}")


def run_once(proxy_bin: str, proxy_port: int, hub_port: int, testhome: Path) -> None:
    hub = http.server.ThreadingHTTPServer(("127.0.0.1", hub_port), HubHandler)
    threading.Thread(target=hub.serve_forever, daemon=True).start()
    proc = start_proxy(proxy_bin, proxy_port, hub_port, str(testhome))
    try:
        wait_for_proxy(proc, proxy_port)
        base = f"http://127.0.0.1:{proxy_port}"

        # AC1 / AC3: persisted roster loaded -> non-seed 'alice' selectable; seeds still selectable; bob rejected.
        login = urllib.request.urlopen(f"{base}/_dev/login?user=alice", timeout=5)
        assert login.status == 204 and "ham_dev_user=alice" in login.headers.get("Set-Cookie", ""), "persisted non-seed user alice must be selectable"
        login = urllib.request.urlopen(f"{base}/_dev/login?user=tanmay", timeout=5)
        assert "ham_dev_user=tanmay" in login.headers.get("Set-Cookie", ""), "seed user tanmay must remain selectable"
        try:
            urllib.request.urlopen(f"{base}/_dev/login?user=bob", timeout=5)
            raise AssertionError("unknown user bob must be rejected (400)")
        except urllib.error.HTTPError as e:
            assert e.code == 400, f"bob should be 400, got {e.code}"

        # AC2 / DP-5: no cookie -> persisted active 'reviewer' (with overridden email).
        payload = json.loads(urllib.request.urlopen(f"{base}/api/v1/me", timeout=5).read())
        assert_user_injected({k.lower(): v for k, v in payload["headers"].items()}, "reviewer", "rev@persisted.example", "no-cookie default")

        # AC2 / DP-5: existing cookie WINS over persisted active.
        req = urllib.request.Request(f"{base}/api/v1/me", headers={"Cookie": "ham_dev_user=tanmay"})
        payload = json.loads(urllib.request.urlopen(req, timeout=5).read())
        assert_user_injected({k.lower(): v for k, v in payload["headers"].items()}, "tanmay", "tanmay@example.com", "cookie override")

        # DP-6 invariant: Authorization bearer passthrough.
        req = urllib.request.Request(f"{base}/api/v1/me", headers={"Authorization": "Bearer keep-me"})
        payload = json.loads(urllib.request.urlopen(req, timeout=5).read())
        h = {k.lower(): v for k, v in payload["headers"].items()}
        assert h.get("authorization") == "Bearer keep-me", f"bearer passthrough broken: {h}"

        # DP-6 invariant: client-supplied X-authentik-* stripped, persisted active injected instead.
        req = urllib.request.Request(f"{base}/api/v1/me", headers={"X-authentik-username": "spoofed"})
        payload = json.loads(urllib.request.urlopen(req, timeout=5).read())
        h = {k.lower(): v for k, v in payload["headers"].items()}
        assert h.get("x-authentik-username") == "reviewer", f"spoofed trusted header not stripped: {h}"
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
    hub.shutdown()
    hub.server_close()


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
        # Pre-seed the store at $HEIMDALL_HOME/dev-proxy/users.json (HEIMDALL_HOME is the data-dir root).
        store_dir = testhome / "dev-proxy"
        store_dir.mkdir(parents=True)
        (store_dir / "users.json").write_text(json.dumps({
            "active": "reviewer",
            "users": [
                {"username": "alice", "display_name": "Alice Dev", "email": "alice@example.com"},
                {"username": "reviewer", "display_name": "Reviewer Override", "email": "rev@persisted.example"},
            ],
        }))

        proxy_port = free_port()

        # Run 1: persisted roster + active honored, cookie wins, DP-6 invariants.
        run_once(str(proxy_bin), proxy_port, free_port(), testhome)
        print("PASS: persisted roster + active honored, cookie wins, DP-6 invariants (run 1)")

        # Run 2 (restart simulation): same HEIMDALL_HOME, fresh process + fresh hub port -> same persisted active.
        run_once(str(proxy_bin), proxy_port, free_port(), testhome)
        print("PASS: persisted active survives restart (run 2)")

        print("ALL PASS")
    finally:
        shutil.rmtree(testhome, ignore_errors=True)


if __name__ == "__main__":
    main()
