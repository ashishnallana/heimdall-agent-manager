"""Shared bits for the ham-dev-proxy tests (OIDC era).

The proxy no longer injects identity headers; the selected dev user is applied
as `login_hint` on the Hub's /api/v1/auth/login redirect (tools/mock-oidc signs
in as that user). Fake Hubs call `answer_login_redirect` first in do_GET.
"""
import urllib.error
import urllib.request
from urllib.parse import parse_qs, urlsplit

FAKE_AUTHORIZE = "http://127.0.0.1:9/application/o/heimdall-native/authorize/?state=s"


def answer_login_redirect(handler) -> bool:
    if not handler.path.startswith("/api/v1/auth/login"):
        return False
    handler.send_response(302)
    handler.send_header("Location", FAKE_AUTHORIZE)
    handler.send_header("Content-Length", "0")
    handler.end_headers()
    return True


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def login_hint(base: str, headers: dict | None = None, cookie: str | None = None) -> str:
    req_headers = dict(headers or {})
    if cookie:
        req_headers["Cookie"] = cookie
    opener = urllib.request.build_opener(_NoRedirect)
    try:
        opener.open(urllib.request.Request(f"{base}/api/v1/auth/login?return_to=%2F", headers=req_headers), timeout=5)
    except urllib.error.HTTPError as e:
        with e:
            assert e.code == 302, e.code
            location = e.headers["Location"]
        return (parse_qs(urlsplit(location).query).get("login_hint") or [""])[0]
    raise AssertionError("expected the sign-in redirect")


def assert_no_identity_headers(h: dict) -> None:
    leaked = [k for k in h if k.lower().startswith("x-authentik-") or k.lower() == "x-dev-user"]
    assert not leaked, f"identity headers must never reach the Hub; saw {leaked}"
