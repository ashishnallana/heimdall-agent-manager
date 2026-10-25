# Minimal static+proxy front for scripts/oidc-smoke/smoke.sh (DEV/TEST ONLY).
# Minimal "Caddy-equivalent": serves the built UI (dist/) and reverse-proxies /api/ to the hub.
import http.server, sys, urllib.request, os
DIST, HUB, PORT = sys.argv[1], sys.argv[2], int(sys.argv[3])
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k): return None
opener = urllib.request.build_opener(NoRedirect)
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k): super().__init__(*a, directory=DIST, **k)
    def log_message(self, *a): pass
    def _proxy(self):
        n = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(n) if n else None
        req = urllib.request.Request(HUB + self.path, data=body, method=self.command)
        for k, v in self.headers.items():
            if k.lower() not in ('host', 'content-length', 'connection'): req.add_header(k, v)
        try: resp = opener.open(req, timeout=30)
        except urllib.error.HTTPError as e: resp = e
        data = resp.read()
        self.send_response(resp.status if hasattr(resp, 'status') else resp.code)
        for k, v in resp.headers.items():
            if k.lower() not in ('content-length', 'connection', 'transfer-encoding'): self.send_header(k, v)
        self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        if self.path.startswith('/api/'): return self._proxy()
        return super().do_GET()
    def do_POST(self): return self._proxy()
http.server.ThreadingHTTPServer(('127.0.0.1', PORT), H).serve_forever()
