#!/usr/bin/env python3
"""Development harness for the custom flow UI. NOT used in production.

In production this page is served by Authentik's own origin (an nginx `location` on
auth.brolabs.ai), so the browser talks to the flow API same-origin and nothing proxies.

For development we need that same-origin property without touching the VPS, so this serves
the page and forwards /api/v3 and /if/ to auth.brolabs.ai.

ONE WRINKLE, and the reason this file is more than ten lines: the Heimdall preview tunnel
strips every `authentik_*` cookie, which is exactly the session cookie the flow executor
authenticates with. So the session cookie is renamed on the way through — `authentik_session`
upstream, `ak_sess` in the browser. That is a dev-only shim; production needs no such thing.

    python3 dev-proxy.py [port]
"""
import http.client
import http.server
import socketserver
import sys
import urllib.parse
from pathlib import Path

UPSTREAM = "auth.brolabs.ai"
HERE = Path(__file__).resolve().parent
PROXY_PREFIXES = ("/api/v3/", "/if/", "/static/", "/flows/")

# The tunnel eats `authentik_*`, so the session rides under a neutral name on our origin.
BROWSER_COOKIE = "ak_sess"
UPSTREAM_COOKIE = "authentik_session"

# Cloudflare rejects unusual User-Agents on this host, so pass a browser-ish one.
UA = "Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "heimdall-flow-ui-dev"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    # -- static ---------------------------------------------------------------
    def serve_static(self):
        name = "index.html" if self.path.split("?")[0] in ("/", "/index.html") else None
        if name is None:
            self.send_error(404)
            return
        body = (HERE / name).read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    # -- proxy ----------------------------------------------------------------
    def proxy(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None

        out = {
            "Host": UPSTREAM,
            "User-Agent": UA,
            "Accept": self.headers.get("Accept", "*/*"),
            "Referer": f"https://{UPSTREAM}/",
        }
        if self.headers.get("Content-Type"):
            out["Content-Type"] = self.headers["Content-Type"]

        # Rename our cookie back to what Authentik expects.
        jar = []
        for part in (self.headers.get("Cookie") or "").split(";"):
            part = part.strip()
            if not part:
                continue
            k, _, v = part.partition("=")
            jar.append(f"{UPSTREAM_COOKIE}={v}" if k == BROWSER_COOKIE else part)
        if jar:
            out["Cookie"] = "; ".join(jar)

        conn = http.client.HTTPSConnection(UPSTREAM, timeout=30)
        try:
            conn.request(self.command, self.path, body=body, headers=out)
            resp = conn.getresponse()
            payload = resp.read()
        except Exception as exc:                       # noqa: BLE001 - surface it to the browser
            self.send_error(502, f"upstream: {exc}")
            return
        finally:
            conn.close()

        self.send_response(resp.status)
        for key, value in resp.getheaders():
            low = key.lower()
            if low in ("transfer-encoding", "content-encoding", "content-length", "connection"):
                continue
            if low == "set-cookie":
                value = self.rewrite_cookie(value)
                if value is None:
                    continue
            if low == "location":
                # Keep redirects on our own origin so the browser stays in the dev harness.
                value = value.replace(f"https://{UPSTREAM}", "")
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    @staticmethod
    def rewrite_cookie(value):
        """Rename the session cookie and make its flags valid for a plain-http dev origin."""
        name = value.split("=", 1)[0].strip()
        if name == UPSTREAM_COOKIE:
            value = value.replace(f"{UPSTREAM_COOKIE}=", f"{BROWSER_COOKIE}=", 1)
        attrs = [a.strip() for a in value.split(";")]
        kept = [attrs[0]]
        for a in attrs[1:]:
            low = a.lower()
            # Secure and SameSite=None need https + a cross-site context; neither holds here,
            # and Domain would scope the cookie to the upstream host.
            if (low in ("secure",) or low.startswith("domain=")
                    or low.startswith("samesite=") or low.startswith("path=")):
                continue
            kept.append(a)
        kept.append("SameSite=Lax")
        kept.append("Path=/")
        return "; ".join(kept)

    def route(self):
        path = self.path.split("?")[0]
        if any(path.startswith(p) for p in PROXY_PREFIXES):
            self.proxy()
        else:
            self.serve_static()

    do_GET = route
    do_POST = route
    do_OPTIONS = route


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8472
    print(f"flow-ui dev harness on 127.0.0.1:{port}, proxying {PROXY_PREFIXES} -> {UPSTREAM}")
    Server(("127.0.0.1", port), Handler).serve_forever()
