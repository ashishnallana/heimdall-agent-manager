# Checks for scripts/oidc-smoke/dev-login-smoke.sh (DEV/TEST ONLY): a browser on
# the preview origin signs in through ham-dev-proxy's broker behind a preview relay.
import argparse, base64, json, os, socket, sys, urllib.error, urllib.parse, urllib.request

ap = argparse.ArgumentParser()
ap.add_argument("--relay", required=True)  # http://127.0.0.1:<port>/p/<sid>
ap.add_argument("--proxy", required=True)  # the dev proxy itself (negative control)
ap.add_argument("--preview-origin", required=True)
ap.add_argument("--user", required=True)
args = ap.parse_args()
RELAY, PREFIX = args.relay.rstrip("/"), urllib.parse.urlsplit(args.relay).path.rstrip("/")
ORIGIN = args.preview_origin
results = []


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


OPENER = urllib.request.build_opener(NoRedirect)


def req(base, path, method="GET", headers=None, body=None):
    r = urllib.request.Request(base + path, data=body, method=method, headers=headers or {})
    try:
        resp = OPENER.open(r, timeout=20)
    except urllib.error.HTTPError as e:
        resp = e
    with resp:
        return resp.code, resp.headers, resp.read()


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("ok   " if cond else "FAIL ") + name + (f"  [{detail}]" if detail and not cond else ""))


def me(base, origin=ORIGIN):
    code, _, body = req(base, "/api/v1/me", headers={"Origin": origin} if origin else {})
    user = ""
    if code == 200:
        d = json.loads(body)
        user = (d.get("data") or {}).get("user_id", "")
    return code, user


def post(base, path, origin=ORIGIN):
    return req(base, path, method="POST", headers={"Origin": origin, "Content-Type": "application/json"}, body=b"{}")


def ws_status(origin=ORIGIN):
    url = urllib.parse.urlsplit(RELAY)
    s = socket.create_connection((url.hostname, url.port), timeout=10)
    try:
        key = base64.b64encode(os.urandom(16)).decode()
        s.sendall((f"GET {PREFIX}/api/v1/user-ws HTTP/1.1\r\nHost: {url.netloc}\r\nUpgrade: websocket\r\n"
                   f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
                   f"Origin: {origin}\r\n\r\n").encode())
        return s.recv(4096).decode(errors="replace").split("\r\n")[0]
    finally:
        s.close()


# 1. browser sign-in: a page navigation to /auth/login, brokered by the proxy
code, h, _ = req(RELAY, f"/api/v1/auth/login?return_to={urllib.parse.quote(PREFIX + '/#/home', safe='')}",
                 headers={"Accept": "text/html"})
check("login navigation -> 302 back to the preview page", code == 302 and h.get("Location") == f"{PREFIX}/#/home",
      f"{code} {h.get('Location')}")
cookies = h.get_all("Set-Cookie") or []
check("no hub session cookie reaches the browser", not any(c.startswith("__Host-heimdall_session=") and "Max-Age=0" not in c for c in cookies), cookies)

# 2. the page's API calls on the preview origin carry the brokered session
code, user = me(RELAY)
check("/me through the relay -> 200", code == 200, str(code))
check(f"/me is the dev user ({args.user})", user == args.user, user)
for p in ("/api/v1/projects", "/api/v1/bridges", "/api/v1/agents"):
    check(f"GET {p} through the relay -> 200", req(RELAY, p, headers={"Origin": ORIGIN})[0] == 200)
code, _, body = post(RELAY, "/api/v1/me/ws-ticket")
check("CSRF-checked POST (ws-ticket) through the relay -> 200", code == 200, f"{code} {body[:200]!r}")
first = ws_status()
check("user WebSocket through the relay -> 101", " 101 " in first, first)

# 3. nothing else gets the session
check("foreign Origin through the relay -> 401", me(RELAY, "https://evil.example")[0] == 401)
check("foreign Origin WebSocket -> no 101", " 101 " not in ws_status("https://evil.example"))
check("preview Origin straight at the proxy (no relay) -> 401", me(args.proxy)[0] == 401)

# 4. sign-out ends the session; signing in again restores it
code, _, body = post(RELAY, "/api/v1/auth/logout")
check("logout through the relay -> 2xx", 200 <= code < 300, f"{code} {body[:200]!r}")
check("/me after logout -> 401 (no silent sign-in)", me(RELAY)[0] == 401)
code, h, _ = req(RELAY, "/api/v1/auth/login?return_to=%2F", headers={"Accept": "text/html"})
check("sign-in again restores the session", code == 302 and me(RELAY)[0] == 200)

print(f"pass={sum(results)} fail={len(results) - sum(results)}")
sys.exit(0 if all(results) else 1)
