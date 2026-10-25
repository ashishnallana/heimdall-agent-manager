#!/usr/bin/env python3
"""Forwarding-invariants + security-boundary regression test for ham-dev-proxy.

Locks in the DP-6 forwarding contract and the DP-7 loopback boundary against a
real built ham-dev-proxy binary driving a recording mock Hub upstream. The Hub
records every request it receives (method/path/headers), so we can assert both
*what* is forwarded and *that management paths are never forwarded*.

DP-6 invariants under test (OIDC era: the Hub authenticates users only with
its own session cookie or an OIDC bearer, so the proxy injects NO identity):
  - Authorization: Bearer ... and Cookie are forwarded unchanged.
  - Client-supplied X-authentik-* and X-Dev-User are STRIPPED, and nothing is
    injected in their place.
  - The selected dev user is applied at sign-in: the Hub's /api/v1/auth/login
    redirect gets login_hint=<user> appended (tools/mock-oidc honours it).
  - Selection precedence: X-Dev-User header > ham_dev_user cookie > default.
  - Management paths (/_dev/, /_dev/api/users, /_dev/login, /_dev/logout) are
    answered locally and NEVER forwarded to the Hub.

DP-7:
  - Non-loopback bind: every /_dev/* route returns 404, while normal proxied
    forwarding still works.

Run: HAM_DEV_PROXY_BIN=<path> python3 tests/test_ham_dev_proxy_forwarding_invariants.py
"""
from __future__ import annotations

import http.server
import json
import os
import socket
import subprocess
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Default dev users seeded in src/dev_proxy/users.odin (default_dev_users).
TANMAY = {"username": "tanmay", "display_name": "Tanmay Vijay", "email": "tanmay@example.com"}
REVIEWER = {"username": "reviewer", "display_name": "Reviewer User", "email": "reviewer@example.com"}


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class RecordingHub:
    """Mock Hub upstream that records every received request under a lock."""

    def __init__(self) -> None:
        self.requests: list[dict] = []
        self.lock = threading.Lock()

    def handler_factory(self) -> type:
        hub = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def _record(self) -> None:
                body = json.dumps({"path": self.path, "headers": {k: v for k, v in self.headers.items()}}).encode()
                with hub.lock:
                    hub.requests.append({"method": self.command, "path": self.path,
                                         "headers": dict(self.headers)})
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self) -> None:
                if self.path.startswith("/api/v1/auth/login"):
                    with hub.lock:
                        hub.requests.append({"method": self.command, "path": self.path, "headers": dict(self.headers)})
                    self.send_response(302)
                    self.send_header("Location", "http://127.0.0.1:9/application/o/heimdall-native/authorize/?state=s")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                self._record()
            def do_POST(self) -> None: self._record()
            def do_DELETE(self) -> None: self._record()

            def log_message(self, *_args) -> None: pass

        return Handler

    def reset(self) -> None:
        with self.lock:
            self.requests.clear()

    def paths(self) -> list[str]:
        with self.lock:
            return [r["path"] for r in self.requests]


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
        cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env,
    )


def proxied_headers(base: str, path: str, headers: dict | None = None, cookie: str | None = None) -> dict:
    """Send a request through the proxy and return the headers the Hub SAW."""
    req_headers = dict(headers or {})
    if cookie:
        req_headers["Cookie"] = cookie
    req = urllib.request.Request(f"{base}{path}", headers=req_headers)
    with urllib.request.urlopen(req, timeout=5) as resp:
        payload = json.loads(resp.read().decode())
    return {k.lower(): v for k, v in payload["headers"].items()}


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def login_hint(base: str, headers: dict | None = None, cookie: str | None = None) -> str:
    """The login_hint the proxy adds to the Hub's sign-in redirect."""
    req_headers = dict(headers or {})
    if cookie:
        req_headers["Cookie"] = cookie
    opener = urllib.request.build_opener(_NoRedirect)
    try:
        opener.open(urllib.request.Request(f"{base}/api/v1/auth/login?return_to=%2F", headers=req_headers), timeout=5)
        raise AssertionError("expected a redirect")
    except urllib.error.HTTPError as e:
        assert e.code == 302, e.code
        location = e.headers["Location"]
        e.close()
    from urllib.parse import parse_qs, urlsplit
    return (parse_qs(urlsplit(location).query).get("login_hint") or [""])[0]


def assert_no_identity_headers(h: dict) -> None:
    leaked = [k for k in h if k.startswith("x-authentik-") or k == "x-dev-user"]
    assert not leaked, f"identity headers must never reach the Hub; saw {leaked}"


def api(base: str, method: str, path: str, body: dict | None = None) -> int:
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json"} if body is not None else {}
    req = urllib.request.Request(f"{base}{path}", data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status
    except urllib.error.HTTPError as e:
        return e.code


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

        hub = RecordingHub()
        hub_port = free_port()
        server = http.server.ThreadingHTTPServer(("127.0.0.1", hub_port), hub.handler_factory())
        threading.Thread(target=server.serve_forever, daemon=True).start()

        proxy_port = free_port()
        proc = start_proxy(str(proxy_bin), f"127.0.0.1:{proxy_port}", hub_port, str(testhome))
        try:
            wait_for_proxy(proc, proxy_port)
            base = f"http://127.0.0.1:{proxy_port}"

            # --- DP-6: Bearer Authorization passthrough (unchanged) ---------------
            for token in ("eyJ.oidc.access", "hba_abcdef0123456789"):
                h = proxied_headers(base, "/api/v1/me", {"Authorization": f"Bearer {token}"})
                assert h.get("authorization") == f"Bearer {token}", (
                    f"bearer must be forwarded unchanged; got {h.get('authorization')}")
            h = proxied_headers(base, "/api/v1/me", cookie="__Host-heimdall_session=abc; ham_dev_user=tanmay")
            assert "__Host-heimdall_session=abc" in h.get("cookie", ""), f"session cookie forwarded; got {h}"
            print("PASS: DP-6 bearer Authorization and the Hub session cookie forwarded unchanged")

            # --- DP-6: spoofed identity headers stripped; nothing injected -------
            h = proxied_headers(base, "/api/v1/me", {
                "X-Dev-User": "reviewer",                       # selects reviewer, then stripped
                "X-authentik-username": "evil",                 # legacy spoof — must be stripped
                "X-authentik-name": "Evil Imposter",
                "X-authentik-email": "evil@attacker.example",
                "Authorization": "Bearer keep",
            })
            assert_no_identity_headers(h)
            assert h.get("authorization") == "Bearer keep", "non-identity headers still forwarded"
            assert "evil" not in json.dumps(h), f"spoofed values leaked into forwarded headers: {h}"
            print("PASS: DP-6 X-authentik-* + X-Dev-User stripped; no identity injected")

            # --- DP-6: selection precedence via the sign-in login_hint ------------
            assert login_hint(base) == TANMAY["username"], "default should be tanmay"
            assert login_hint(base, cookie="ham_dev_user=reviewer") == REVIEWER["username"]
            assert login_hint(base, {"X-Dev-User": "reviewer"}, cookie="ham_dev_user=tanmay") == "reviewer", "X-Dev-User header must win over cookie"
            print("PASS: DP-6 selection precedence (header > cookie > default) applied as login_hint")

            # --- DP-6: management paths NEVER forwarded to the Hub ---------------
            hub.reset()
            # Each of these must be answered LOCALLY (own status), not forwarded.
            mgmt_calls = [
                ("GET", "/_dev/", None),                       # UI HTML
                ("GET", "/_dev/api/users", None),              # roster JSON
                ("POST", "/_dev/api/users", {"username": "erin", "display_name": "Erin", "email": "erin@e.example"}),
                ("GET", "/_dev/login?user=erin", None),        # cookie login
                ("GET", "/_dev/logout", None),                 # cookie clear
            ]
            statuses = []
            for method, path, body in mgmt_calls:
                statuses.append(api(base, method, path, body))
            forwarded = hub.paths()
            assert forwarded == [], (
                f"management paths must NEVER be forwarded; Hub saw: {forwarded}")
            assert all(s < 400 for s in statuses), f"management calls should succeed locally; got {statuses}"
            print(f"PASS: DP-6 management paths answered locally, never forwarded (statuses={statuses})")

            # --- DP-6: unknown dev user is rejected (400), not forwarded --------
            hub.reset()
            code = api(base, "GET", "/api/v1/me", None) if False else None
            try:
                urllib.request.urlopen(
                    urllib.request.Request(f"{base}/api/v1/me", headers={"X-Dev-User": "ghost"}), timeout=5)
                raise AssertionError("unknown dev user should be rejected")
            except urllib.error.HTTPError as e:
                assert e.code == 400, f"unknown user should be 400; got {e.code}"
            assert hub.paths() == [], "rejected request must not reach the Hub"
            print("PASS: DP-6 unknown dev user -> 400, not forwarded")
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()
            server.shutdown()
            server.server_close()

        # --- DP-7: non-loopback bind disables management; forwarding still works -
        nl_hub = RecordingHub()
        nl_hub_port = free_port()
        nl_server = http.server.ThreadingHTTPServer(("127.0.0.1", nl_hub_port), nl_hub.handler_factory())
        threading.Thread(target=nl_server.serve_forever, daemon=True).start()
        nl_port = free_port()
        nl_proc = start_proxy(str(proxy_bin), f"0.0.0.0:{nl_port}", nl_hub_port, str(testhome))
        try:
            wait_for_proxy(nl_proc, nl_port)
            nbase = f"http://127.0.0.1:{nl_port}"
            # Every management surface returns 404 on non-loopback.
            for path in ("/_dev/", "/_dev/api/users", "/_dev/login?user=tanmay", "/_dev/logout"):
                code = api(nbase, "GET", path)
                assert code == 404, f"non-loopback {path} should be 404; got {code}"
            code = api(nbase, "POST", "/_dev/api/users", {"username": "evil"})
            assert code == 404, f"non-loopback POST management should be 404; got {code}"
            # Normal proxied forwarding is unaffected by the loopback gate.
            h = proxied_headers(nbase, "/api/v1/me", {"Authorization": "Bearer keep"})
            assert h.get("authorization") == "Bearer keep", "forwarding must still work on non-loopback"
            assert_no_identity_headers(h)
            print("PASS: DP-7 non-loopback disables all /_dev/* (404); forwarding still works")
        finally:
            nl_proc.terminate()
            try:
                nl_proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                nl_proc.kill()
            nl_server.shutdown()
            nl_server.server_close()

        print("ALL PASS")
    finally:
        shutil.rmtree(testhome, ignore_errors=True)


if __name__ == "__main__":
    main()
