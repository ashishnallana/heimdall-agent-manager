"""Test helper: run tools/mock-oidc and sign in to a local hub like a browser.

The hub no longer accepts trusted-proxy identity headers or hub user tokens;
tests authenticate either with the browser session cookie obtained from the
real OIDC authorization-code flow against the mock provider, or with a mock
access token (native-app bearer; device-proof gated routes need more).

Usage:
    mock = MockOIDC.start(port)              # or MockOIDC.start() for a free port
    env = {**os.environ, **mock.hub_env()}  # pass to the ham-hub subprocess
    # ham-hub ... --ui-origin http://127.0.0.1:<hub_port>
    cookie = login(hub_base, username="alice", mock=mock)
    headers = session_headers(cookie, hub_base)   # includes Origin for CSRF
"""
import json
import os
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MOCK = ROOT / "tools" / "mock-oidc" / "mock_oidc.py"
SESSION_COOKIE = "__Host-heimdall_session"
LOGIN_COOKIE = "__Host-heimdall_login"


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


def _get(url, headers=None):
    req = urllib.request.Request(url, headers=headers or {})
    try:
        resp = _OPENER.open(req, timeout=10)
    except urllib.error.HTTPError as err:  # 3xx arrive here with _NoRedirect
        resp = err
    with resp:
        return resp.code, resp.headers, resp.read()


def _cookie_from(headers, name):
    # Parsed by hand: __Host-/Secure cookies over http://127.0.0.1 are refused by
    # http.cookiejar, but the hub (in dev mode) and browsers on localhost use them.
    for value in headers.get_all("Set-Cookie") or []:
        pair = value.split(";", 1)[0]
        key, _, val = pair.partition("=")
        if key.strip() == name and val:
            return val
    return ""


class MockOIDC:
    def __init__(self, port, proc, client_id="heimdall-web"):
        self.port, self.proc, self.client_id = port, proc, client_id
        self.issuer = f"http://127.0.0.1:{port}/application/o/heimdall-native/"

    @classmethod
    def start(cls, port=None, username="dev", client_id="heimdall-web", extra_args=()):
        port = port or free_port()
        proc = subprocess.Popen([sys.executable, str(MOCK), "--port", str(port), "--username", username,
                                 "--client-id", client_id, *extra_args],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                _get(f"http://127.0.0.1:{port}/application/o/heimdall-native/jwks/")
                return cls(port, proc, client_id)
            except OSError:
                time.sleep(0.05)
        proc.kill()
        raise RuntimeError("mock OIDC provider did not start")

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()

    def hub_env(self, hub_base=None):
        """Hub environment for this provider. `hub_base` pins the redirect URI so
        the callback lands on this hub even if --ui-origin names another origin."""
        i = self.issuer
        extra = {"HAM_OIDC_REDIRECT_URI": hub_base.rstrip("/") + "/api/v1/auth/callback"} if hub_base else {}
        return {**extra,
            "HAM_OIDC_ALLOW_INSECURE_LOCALHOST": "1",
            "HAM_OIDC_ISSUER": i,
            "HAM_OIDC_JWKS_URL": i + "jwks/",
            "HAM_OIDC_USERINFO_URL": i + "userinfo/",
            "HAM_OIDC_AUTHORIZE_URL": i + "authorize/",
            "HAM_OIDC_TOKEN_URL": i + "token/",
            "HAM_OIDC_END_SESSION_URL": i + "end-session/",
            "HAM_OIDC_API_AUDIENCE": "heimdall-api",
            "HAM_OIDC_API_SCOPE": "heimdall.api",
            "HAM_OIDC_WEB_CLIENT_ID": self.client_id,
            # Tests sign in as fresh usernames and expect a user to exist.
            "HAM_AUTO_PROVISION_USERS": "true",
            "HAM_OIDC_CLAIM_EXISTING_USERS": "true",
        }

    def access_token(self, username="dev", subject=None):
        body = json.dumps({"username": username, **({"subject": subject} if subject else {})}).encode()
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}/__mock/access-token", data=body,
                                     headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read())["access_token"]


def subject_for(username, mock_default_username="dev"):
    return "mock-subject-dev" if username == mock_default_username else f"mock-{username}"


def login(hub_base, username="dev", return_to="/"):
    """Run the browser authorization-code flow against the hub; return the raw session id."""
    hub_base = hub_base.rstrip("/")
    status, headers, _ = _get(f"{hub_base}/api/v1/auth/login?" + urllib.parse.urlencode({"return_to": return_to}))
    if status != 302:
        raise RuntimeError(f"/api/v1/auth/login returned {status}")
    login_state = _cookie_from(headers, LOGIN_COOKIE)
    authorize = headers["Location"] + ("&" + urllib.parse.urlencode({"login_hint": username}) if username else "")
    status, headers, _ = _get(authorize)
    if status != 302:
        raise RuntimeError(f"mock authorize returned {status}")
    callback = headers["Location"]
    # Deliver the callback to hub_base whatever origin the redirect URI names
    # (e.g. a UI dev server that is not running yet); the cookie is host-scoped.
    parts = urllib.parse.urlsplit(callback)
    callback = hub_base + parts.path + (("?" + parts.query) if parts.query else "")
    status, headers, body = _get(callback, {"Cookie": f"{LOGIN_COOKIE}={login_state}"})
    session = _cookie_from(headers, SESSION_COOKIE)
    if status != 302 or not session:
        raise RuntimeError(f"callback failed: {status} {headers.get('Location')} {body[:200]!r}")
    return session


def session_headers(session, ui_origin, extra=None):
    """Request headers for a signed-in browser (Origin satisfies the CSRF check)."""
    headers = {"Cookie": f"{SESSION_COOKIE}={session}", "Origin": ui_origin.rstrip("/")}
    headers.update(extra or {})
    return headers


def hub_args(hub_port, ui_origin=None):
    """Extra ham-hub flags for a local hub signed into via the mock provider."""
    return ["--ui-origin", ui_origin or f"http://127.0.0.1:{hub_port}"]


if __name__ == "__main__":  # manual smoke: python3 tests/hub_oidc_login.py <hub_base> [username]
    print(login(sys.argv[1], *(sys.argv[2:3] or ["dev"])))
