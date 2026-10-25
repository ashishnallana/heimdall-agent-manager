#!/usr/bin/env python3
"""Mock OIDC provider for Heimdall LOCAL DEVELOPMENT AND TESTS ONLY.

Never expose it on a network: it auto-approves every authorization request for
one configured user and signs tokens with the TEST-ONLY key committed in
src/hub/service/auth/testdata/oidc_rs256_signing.json.

Endpoints (issuer = http://127.0.0.1:<port>/application/o/heimdall-native/):
  GET  <issuer>authorize/     auto-approve -> 302 redirect_uri?code&state
  POST <issuer>token/         authorization_code (PKCE S256) -> id_token + access_token
  GET  <issuer>jwks/          public half of the test key
  GET  <issuer>userinfo/      Bearer access_token -> claims (401 otherwise)
  GET  <issuer>end-session/   302 post_logout_redirect_uri (or 200)
  POST /__mock/access-token   {"username"?, "subject"?} -> {"access_token": ...}
                              (mint a native-app bearer for tests; no browser)

Stdlib only. Run `python3 mock_oidc.py --help`.
"""
import argparse
import base64
import hashlib
import json
import os
import secrets
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ISSUER_PATH = "/application/o/heimdall-native/"
DIGEST_INFO_SHA256 = bytes.fromhex("3031300d060960864801650304020105000420")
DEFAULT_KEY = Path(__file__).resolve().parents[2] / "src/hub/service/auth/testdata/oidc_rs256_signing.json"


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def b64url_decode(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


class Signer:
    def __init__(self, key_path: Path):
        key = json.loads(key_path.read_text())
        self.kid = key["kid"]
        self.n_b64, self.e_b64 = key["n"], key["e"]
        self.n = int.from_bytes(b64url_decode(key["n"]), "big")
        self.d = int.from_bytes(b64url_decode(key["d"]), "big")
        self.k = (self.n.bit_length() + 7) // 8

    def sign(self, claims: dict) -> str:
        header = {"alg": "RS256", "kid": self.kid, "typ": "JWT"}
        signing_input = b64url(json.dumps(header, separators=(",", ":")).encode()) + "." + \
            b64url(json.dumps(claims, separators=(",", ":")).encode())
        t = DIGEST_INFO_SHA256 + hashlib.sha256(signing_input.encode()).digest()
        em = b"\x00\x01" + b"\xff" * (self.k - len(t) - 3) + b"\x00" + t
        sig = pow(int.from_bytes(em, "big"), self.d, self.n).to_bytes(self.k, "big")
        return signing_input + "." + b64url(sig)

    def verify(self, token: str) -> dict:
        signing_input, _, sig = token.rpartition(".")
        e = int.from_bytes(b64url_decode(self.e_b64), "big")
        em = pow(int.from_bytes(b64url_decode(sig), "big"), e, self.n).to_bytes(self.k, "big")
        t = DIGEST_INFO_SHA256 + hashlib.sha256(signing_input.encode()).digest()
        if em != b"\x00\x01" + b"\xff" * (self.k - len(t) - 3) + b"\x00" + t:
            raise ValueError("bad signature")
        return json.loads(b64url_decode(signing_input.split(".")[1]))

    def jwks(self) -> dict:
        return {"keys": [{"kty": "RSA", "kid": self.kid, "alg": "RS256", "use": "sig", "n": self.n_b64, "e": self.e_b64}]}


class Provider:
    def __init__(self, args):
        self.args = args
        self.signer = Signer(Path(args.key))
        self.issuer = f"http://127.0.0.1:{args.port}{ISSUER_PATH}"
        self.codes = {}  # code -> grant
        self.lock = threading.Lock()

    def user_claims(self, username=None, subject=None):
        username = username or self.args.username
        subject = subject or (self.args.subject if username == self.args.username else f"mock-{username}")
        return {"sub": subject, "preferred_username": username, "name": username.title(), "email": f"{username}@example.test"}

    def access_token(self, username=None, subject=None):
        now = int(time.time())
        claims = dict(self.user_claims(username, subject))
        claims.update({"iss": self.issuer, "aud": [self.args.client_id, self.args.api_audience], "iat": now,
                       "exp": now + self.args.token_ttl, "scope": f"openid profile email {self.args.api_scope}"})
        return self.signer.sign(claims)

    def env_lines(self, ui_origin):
        i = self.issuer
        return [
            "HAM_OIDC_ALLOW_INSECURE_LOCALHOST=1",
            f"HAM_OIDC_ISSUER={i}",
            f"HAM_OIDC_JWKS_URL={i}jwks/",
            f"HAM_OIDC_USERINFO_URL={i}userinfo/",
            f"HAM_OIDC_AUTHORIZE_URL={i}authorize/",
            f"HAM_OIDC_TOKEN_URL={i}token/",
            f"HAM_OIDC_END_SESSION_URL={i}end-session/",
            f"HAM_OIDC_API_AUDIENCE={self.args.api_audience}",
            f"HAM_OIDC_API_SCOPE={self.args.api_scope}",
            f"HAM_OIDC_WEB_CLIENT_ID={self.args.client_id}",
            "HAM_OIDC_CLAIM_EXISTING_USERS=true",
            "HAM_AUTO_PROVISION_USERS=true",
            f"# hub flag: --ui-origin {ui_origin}",
        ]


def make_handler(provider: Provider):
    class Handler(BaseHTTPRequestHandler):
        server_version = "heimdall-mock-oidc"

        def log_message(self, fmt, *a):
            if provider.args.verbose:
                sys.stderr.write("mock-oidc: " + fmt % a + "\n")

        def send_json(self, status, body, headers=()):
            data = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(data)))
            for k, v in headers:
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(data)

        def redirect(self, location):
            self.send_response(302)
            self.send_header("Location", location)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def route(self):
            parsed = urllib.parse.urlsplit(self.path)
            path = parsed.path
            if path.startswith(ISSUER_PATH):
                path = path[len(ISSUER_PATH):].strip("/")
            return path, urllib.parse.parse_qs(parsed.query)

        def do_GET(self):
            path, q = self.route()
            one = lambda k: (q.get(k) or [""])[0]
            if path == "jwks":
                return self.send_json(200, provider.signer.jwks())
            if path == ".well-known/openid-configuration":
                i = provider.issuer
                return self.send_json(200, {"issuer": i, "authorization_endpoint": i + "authorize/", "token_endpoint": i + "token/",
                                            "jwks_uri": i + "jwks/", "userinfo_endpoint": i + "userinfo/", "end_session_endpoint": i + "end-session/"})
            if path == "authorize":
                if one("response_type") != "code" or one("client_id") != provider.args.client_id or not one("redirect_uri"):
                    return self.send_json(400, {"error": "invalid_request"})
                if one("code_challenge_method") != "S256" or not one("code_challenge"):
                    return self.send_json(400, {"error": "invalid_request", "error_description": "PKCE S256 required"})
                # The LAST login_hint wins: a dev proxy may append its own, and an
                # explicit hint added after it (tests, scripts) must take precedence.
                username = (q.get("login_hint") or [""])[-1] or provider.args.username
                code = secrets.token_urlsafe(24)
                with provider.lock:
                    provider.codes[code] = {"client_id": one("client_id"), "redirect_uri": one("redirect_uri"), "nonce": one("nonce"),
                                            "challenge": one("code_challenge"), "username": username, "expires": time.time() + 60}
                sep = "&" if "?" in one("redirect_uri") else "?"
                return self.redirect(one("redirect_uri") + sep + urllib.parse.urlencode({"code": code, "state": one("state")}))
            if path == "userinfo":
                auth = self.headers.get("Authorization", "")
                if not auth.startswith("Bearer "):
                    return self.send_json(401, {"error": "invalid_token"})
                try:
                    claims = provider.signer.verify(auth[7:])
                    assert claims["iss"] == provider.issuer and claims["exp"] > time.time()
                except Exception:
                    return self.send_json(401, {"error": "invalid_token"})
                return self.send_json(200, {k: claims[k] for k in ("sub", "preferred_username", "name", "email") if k in claims})
            if path == "end-session":
                target = one("post_logout_redirect_uri")
                if target:
                    return self.redirect(target)
                return self.send_json(200, {"logged_out": True})
            return self.send_json(404, {"error": "not_found"})

        def do_POST(self):
            path, _ = self.route()
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length).decode() if length else ""
            if self.path.startswith("/__mock/access-token"):
                body = json.loads(raw or "{}")
                return self.send_json(200, {"access_token": provider.access_token(body.get("username"), body.get("subject")), "token_type": "Bearer"})
            if path != "token":
                return self.send_json(404, {"error": "not_found"})
            form = {k: v[0] for k, v in urllib.parse.parse_qs(raw).items()}
            client_id = form.get("client_id", "")
            basic = self.headers.get("Authorization", "")
            if basic.startswith("Basic "):
                user, _, secret = base64.b64decode(basic[6:]).decode().partition(":")
                client_id = urllib.parse.unquote(user)
                if provider.args.client_secret and urllib.parse.unquote(secret) != provider.args.client_secret:
                    return self.send_json(401, {"error": "invalid_client"})
            elif provider.args.client_secret:
                return self.send_json(401, {"error": "invalid_client"})
            with provider.lock:
                grant = provider.codes.pop(form.get("code", ""), None)
            if form.get("grant_type") != "authorization_code" or grant is None or grant["expires"] < time.time():
                return self.send_json(400, {"error": "invalid_grant"})
            if client_id != grant["client_id"] or form.get("redirect_uri") != grant["redirect_uri"]:
                return self.send_json(400, {"error": "invalid_grant"})
            if b64url(hashlib.sha256(form.get("code_verifier", "").encode()).digest()) != grant["challenge"]:
                return self.send_json(400, {"error": "invalid_grant", "error_description": "PKCE verification failed"})
            now = int(time.time())
            claims = dict(provider.user_claims(grant["username"]))
            claims.update({"iss": provider.issuer, "aud": grant["client_id"], "iat": now, "exp": now + provider.args.token_ttl, "nonce": grant["nonce"]})
            return self.send_json(200, {"id_token": provider.signer.sign(claims), "access_token": provider.access_token(grant["username"]),
                                        "token_type": "Bearer", "expires_in": provider.args.token_ttl})

    return Handler


def main():
    p = argparse.ArgumentParser(description="Heimdall mock OIDC provider (DEV/TEST ONLY; binds 127.0.0.1).")
    p.add_argument("--port", type=int, default=int(os.environ.get("MOCK_OIDC_PORT", "9400")))
    p.add_argument("--username", default="dev", help="user every authorize request signs in as (login_hint overrides)")
    p.add_argument("--subject", default="mock-subject-dev")
    p.add_argument("--client-id", default="heimdall-web")
    p.add_argument("--client-secret", default="", help="require this client secret at the token endpoint")
    p.add_argument("--api-audience", default="heimdall-api")
    p.add_argument("--api-scope", default="heimdall.api")
    p.add_argument("--token-ttl", type=int, default=3600)
    p.add_argument("--key", default=str(DEFAULT_KEY))
    p.add_argument("--ui-origin", default="http://127.0.0.1:8081", help="only used by --print-env")
    p.add_argument("--print-env", action="store_true", help="print the hub environment for this provider and exit")
    p.add_argument("--verbose", action="store_true")
    args = p.parse_args()
    provider = Provider(args)
    if args.print_env:
        print("\n".join(provider.env_lines(args.ui_origin)))
        return
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(provider))
    print(f"mock-oidc: issuer {provider.issuer} (TEST KEY, DEV ONLY)", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
