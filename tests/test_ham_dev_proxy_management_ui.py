#!/usr/bin/env python3
"""Self-contained management UI test for ham-dev-proxy (DP-3 / DP-4 / DP-7).

Validates the single HTML document served at /_dev/:
  - AC1 (DP-4): GET /_dev/ returns one HTML doc with inline <style>/<script>,
    no external <script src>/<link>, the user list + create form containers,
    fetch calls to the /_dev/api/* endpoints, and the loopback footer note.
  - AC2 (DP-3): the UI's [Use] action target (POST /_dev/api/active) makes a
    user active, and a proxied /api/v1/ request is forwarded as that user.
  - AC3 (DP-4): the create-form target (POST /_dev/api/users) adds a user that
    the list target (GET /_dev/api/users) returns; [Delete] removes it.
  - AC4 (DP-7): non-loopback bind does not serve the UI (404).
  - XSS (constraint): no executable .innerHTML assignment; user data is rendered
    via textContent/createElement only.

No headless browser is required: the UI is static HTML whose behavior is fully
exercised by its /_dev/api/* targets, which we drive directly and assert on.
The HTML shape is checked statically.

Run: HAM_DEV_PROXY_BIN=<path> python3 tests/test_ham_dev_proxy_management_ui.py
"""
from __future__ import annotations

import http.server
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
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
        body = json.dumps({"path": self.path, "headers": {k: v for k, v in self.headers.items()}}).encode()
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
        cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env,
    )


def check_html_shape(html: str) -> None:
    checks = {
        "single html doc": html.lstrip().startswith("<!DOCTYPE html>") and "</html>" in html,
        "inline <style>": "<style>" in html and "</style>" in html,
        "inline <script>": "<script>" in html and "</script>" in html,
        "no external <script src=>": "<script src=" not in html,
        "no external http(s) src": 'src="http' not in html,
        "no external <link>": "<link " not in html,
        "user list container": 'id="users"' in html,
        "create form": 'id="createForm"' in html,
        "fetches GET /_dev/api/users": "/_dev/api/users" in html,
        "fetches POST /_dev/api/active": "/_dev/api/active" in html,
        "fetches DELETE /_dev/api/users/": "/_dev/api/users/" in html,
        "loopback footer note": "loopback" in html.lower(),
    }
    # XSS-safety: no executable .innerHTML assignment (only allowed in comments).
    executable_innerhtml = re.findall(r"\.innerHTML\s*=", html)
    checks["no executable .innerHTML assignment (XSS-safe)"] = len(executable_innerhtml) == 0
    checks["uses textContent/createElement"] = ("textContent" in html) and ("createElement" in html)
    failed = [k for k, v in checks.items() if not v]
    if failed:
        raise AssertionError(f"HTML shape check failed: {failed}")
    print("PASS: HTML shape (single doc, inline CSS/JS, no external deps, API hooks, loopback note, XSS-safe)")


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

            # AC1 (DP-4): GET /_dev/ returns the self-contained HTML doc.
            with urllib.request.urlopen(f"{base}/_dev/", timeout=5) as resp:
                assert resp.status == 200, f"/_dev/ should be 200, got {resp.status}"
                ctype = resp.headers.get("Content-Type", "")
                assert ctype.startswith("text/html"), f"content-type should be text/html, got {ctype}"
                html = resp.read().decode()
            check_html_shape(html)

            # /_dev/ui alias serves the same doc.
            with urllib.request.urlopen(f"{base}/_dev/ui", timeout=5) as resp:
                assert resp.status == 200

            # AC3 (DP-4): the create-form target adds a user the list returns.
            data = json.dumps({"username": "erin", "display_name": "Erin", "email": "erin@example.com"}).encode()
            req = urllib.request.Request(f"{base}/_dev/api/users", data=data, method="POST",
                                         headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=5) as resp:
                assert resp.status == 201, f"create should be 201, got {resp.status}"
            with urllib.request.urlopen(f"{base}/_dev/api/users", timeout=5) as resp:
                roster = json.loads(resp.read())
            assert "erin" in [u["username"] for u in roster["users"]], "erin should appear after create"

            # AC2 (DP-3): [Use] target sets active; proxied /api/v1 reflects erin.
            data = json.dumps({"username": "erin"}).encode()
            req = urllib.request.Request(f"{base}/_dev/api/active", data=data, method="POST",
                                         headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=5) as resp:
                assert resp.status == 200
                assert "ham_dev_user=erin" in resp.headers.get("Set-Cookie", ""), "active should set ham_dev_user cookie"
            assert login_hint(base) == "erin", "next sign-in should be hinted as erin"
            with urllib.request.urlopen(f"{base}/api/v1/me", timeout=5) as resp:
                fwd = json.loads(resp.read())
            assert_no_identity_headers(fwd["headers"])

            # AC3 (DP-4): [Delete] target removes the user.
            req = urllib.request.Request(f"{base}/_dev/api/users/erin", method="DELETE")
            with urllib.request.urlopen(req, timeout=5) as resp:
                assert resp.status in (200, 204), f"delete should be 204, got {resp.status}"
            with urllib.request.urlopen(f"{base}/_dev/api/users", timeout=5) as resp:
                roster = json.loads(resp.read())
            assert "erin" not in [u["username"] for u in roster["users"]], "erin should be gone after delete"
            print("PASS: UI-backed API flow create/select(proxied identity)/delete (DP-3/DP-4)")
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()
            hub.shutdown()
            hub.server_close()

        # AC4 (DP-7): non-loopback bind does not serve the UI.
        nl_port = free_port()
        nl_proc = start_proxy(str(proxy_bin), f"0.0.0.0:{nl_port}", free_port(), str(testhome))
        try:
            wait_for_proxy(nl_proc, nl_port)
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{nl_port}/_dev/", timeout=5)
                raise AssertionError("non-loopback /_dev/ should 404, got 200")
            except urllib.error.HTTPError as e:
                assert e.code == 404, f"non-loopback /_dev/ should be 404, got {e.code}"
            print("PASS: non-loopback bind does not serve the UI (DP-7)")
        finally:
            nl_proc.terminate()
            try:
                nl_proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                nl_proc.kill()

        print("ALL PASS")
    finally:
        shutil.rmtree(testhome, ignore_errors=True)


import urllib.error

if __name__ == "__main__":
    main()
