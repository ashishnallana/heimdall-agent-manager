# Minimal stand-in for the Hub's preview relay (DEV/TEST ONLY), used by
# scripts/oidc-smoke/dev-login-smoke.sh. It mirrors what
# src/hub/transport/http/shell_session_handlers.odin does to a request on its way
# to a previewed app, so the dev login flow can be exercised without a real Hub:
#   - serves only under PREFIX (/p/<sid>) and strips it before forwarding
#   - forwards an allowlist of request headers (no Sec-Fetch-*), WebSocket
#     negotiation headers on upgrades, and cookies minus __Host-heimdall_*,
#     heimdall_* and authentik_*
#   - rewrites every response Set-Cookie Path to PREFIX/ (dropping Domain) and a
#     root-relative or upstream-absolute Location under PREFIX (unless it already is)
# Usage: relay.py <listen-port> <prefix> <upstream-port>
import socket, sys, threading

PORT, PREFIX, UPSTREAM = int(sys.argv[1]), sys.argv[2].rstrip("/"), int(sys.argv[3])
PASS = {"accept", "accept-encoding", "accept-language", "content-type", "content-length",
        "cache-control", "range", "if-none-match", "if-modified-since", "if-match",
        "if-unmodified-since", "content-encoding", "user-agent", "referer", "origin",
        "x-csrf-token", "x-csrftoken", "x-xsrf-token", "x-requested-with"}
WS = {"upgrade", "connection", "sec-websocket-key", "sec-websocket-version",
      "sec-websocket-protocol", "sec-websocket-extensions"}


def read_head(sock):
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(65536)
        if not chunk:
            return None, b""
        buf += chunk
    head, rest = buf.split(b"\r\n\r\n", 1)
    return head.decode("latin-1"), rest


def filter_cookie(value):
    kept = []
    for part in value.split(";"):
        cookie = part.strip()
        name = cookie.split("=", 1)[0].strip().lower()
        if name.startswith(("authentik_", "__host-heimdall_", "heimdall_")) or not cookie:
            continue
        kept.append(cookie)
    return "; ".join(kept)


def filter_set_cookie(value):
    parts = [p.strip() for p in value.split(";")]
    out = [parts[0]]
    for attr in parts[1:]:
        name = attr.split("=", 1)[0].strip().lower()
        if name in ("domain", "path"):
            continue
        out.append(attr)
    out.append(f"Path={PREFIX}/")
    return "; ".join(out)


def rewrite_location(value):
    if value == PREFIX or value.startswith(PREFIX + "/"):
        return value
    for base in (f"{s}://{h}:{UPSTREAM}" for s in ("http", "https") for h in ("127.0.0.1", "localhost")):
        if value.lower().startswith(base) and (len(value) == len(base) or value[len(base)] in "/?#"):
            return PREFIX + value[len(base):]
    if value.startswith("/") and not value.startswith("//"):
        return PREFIX + value
    return value


def pipe(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def handle(client):
    try:
        head, rest = read_head(client)
        if head is None:
            return
        lines = head.split("\r\n")
        method, target, version = lines[0].split(" ", 2)
        if target != PREFIX and not target.startswith(PREFIX + "/") and not target.startswith(PREFIX + "?"):
            client.sendall(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        path = target[len(PREFIX):] or "/"
        if path.startswith("?"):
            path = "/" + path
        headers = [(l.split(":", 1)[0].strip(), l.split(":", 1)[1].strip()) for l in lines[1:] if ":" in l]
        upgrade = any(n.lower() == "upgrade" and v.lower() == "websocket" for n, v in headers)
        out = [f"{method} {path} {version}", f"Host: 127.0.0.1:{UPSTREAM}"]
        for name, value in headers:
            lower = name.lower()
            if lower == "cookie":
                value = filter_cookie(value)
                if value:
                    out.append(f"{name}: {value}")
            elif lower in PASS or (upgrade and lower in WS):
                out.append(f"{name}: {value}")
        if not upgrade:
            out.append("Connection: close")
        upstream = socket.create_connection(("127.0.0.1", UPSTREAM), timeout=30)
        upstream.sendall(("\r\n".join(out) + "\r\n\r\n").encode("latin-1") + rest)
        if not upgrade:
            # Request bodies here are small and arrive with the head (or right after).
            threading.Thread(target=pipe, args=(client, upstream), daemon=True).start()
        rhead, rrest = read_head(upstream)
        if rhead is None:
            return
        rlines = rhead.split("\r\n")
        rout = [rlines[0]]
        for line in rlines[1:]:
            if ":" not in line:
                continue
            name, value = line.split(":", 1)
            value = value.strip()
            if name.lower() == "set-cookie":
                value = filter_set_cookie(value)
            elif name.lower() == "location":
                value = rewrite_location(value)
            rout.append(f"{name}: {value}")
        client.sendall(("\r\n".join(rout) + "\r\n\r\n").encode("latin-1") + rrest)
        if upgrade:
            threading.Thread(target=pipe, args=(client, upstream), daemon=True).start()
        pipe(upstream, client)
    except OSError:
        pass
    finally:
        client.close()


server = socket.create_server(("127.0.0.1", PORT), reuse_port=False)
while True:
    conn, _ = server.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
