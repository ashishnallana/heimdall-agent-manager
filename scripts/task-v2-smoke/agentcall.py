#!/usr/bin/env python3
"""agentcall.py — speak the bridge's local JSONL v1 endpoint as an agent instance.

    agentcall.py --shim <run_dir>/bin/ham-ctl <method> [params-json]
    agentcall.py --endpoint tcp:127.0.0.1:18082 --token hlat_... <method> [params-json]

The shim the bridge materialises in every agent run_dir exports
HEIMDALL_BRIDGE_ENDPOINT / HEIMDALL_AGENT_TOKEN; --shim parses those two lines so
the smoke can act AS the woken instance (same token the real agent holds).

Methods are sent natively first. For the Task System v2 verbs the bridge may not
route yet (lease.submit/handoff/block, review.post, task.fetch) a bridge answer of
forbidden/unknown-method falls back to `agent.rest.request` against the matching
hub agent-actions path with body {"params": …} — which is exactly what the native
route relays, minus the bridge's .Local vcs enrichment. Pass --rest to force the
fallback, --no-rest to forbid it.

Output: one JSON line. On a hub error relayed through rest.request the hub's error
body is unwrapped so callers see {"ok":false,"error":{"code":..,"details":{"code":..}}}
just like the native route. Exit status 0 iff ok.
"""
import json
import os
import socket
import sys
import time

M2_PATHS = {
    "agent.lease.next": "/api/v1/agent-actions/lease/next",
    "agent.lease.heartbeat": "/api/v1/agent-actions/lease/heartbeat",
    "agent.lease.submit": "/api/v1/agent-actions/lease/submit",
    "agent.lease.handoff": "/api/v1/agent-actions/lease/handoff",
    "agent.lease.block": "/api/v1/agent-actions/lease/block",
    "agent.review.post": "/api/v1/agent-actions/review/post",
    "agent.task.fetch": "/api/v1/agent-actions/task/fetch",
    "agent.workflow.templates": "/api/v1/agent-actions/workflow/templates",
    "agent.workflow.list": "/api/v1/agent-actions/workflow/templates",
    "agent.workflow.define": "/api/v1/agent-actions/workflow/define",
    "agent.workflow.run": "/api/v1/agent-actions/workflow/run",
    "agent.workflow.status": "/api/v1/agent-actions/workflow/status",
    "agent.workflow.output": "/api/v1/agent-actions/workflow/output",
    "agent.workflow.retry": "/api/v1/agent-actions/workflow/retry",
    "agent.workflow.cancel": "/api/v1/agent-actions/workflow/cancel",
}


def parse_shim(path):
    endpoint = token = ""
    with open(path) as f:
        for line in f:
            line = line.strip()
            for key in ("HEIMDALL_BRIDGE_ENDPOINT", "HEIMDALL_AGENT_TOKEN"):
                prefix = f"export {key}="
                if line.startswith(prefix):
                    val = line[len(prefix):]
                    if val.startswith("'") and val.endswith("'"):
                        val = val[1:-1].replace("'\\''", "'")
                    if key == "HEIMDALL_BRIDGE_ENDPOINT":
                        endpoint = val
                    else:
                        token = val
    return endpoint, token


def dial(endpoint, timeout):
    if endpoint.startswith("tcp:"):
        _, host, port = endpoint.split(":")
        s = socket.create_connection((host or "127.0.0.1", int(port)), timeout=timeout)
    elif endpoint.startswith("unix:"):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(endpoint[len("unix:"):])
    else:
        raise SystemExit(f"bad endpoint {endpoint!r}")
    return s


def call(endpoint, token, method, params, timeout):
    req = {"v": 1, "id": f"smoke-{int(time.time()*1000)}", "token": token, "method": method, "params": params}
    s = dial(endpoint, timeout)
    try:
        s.sendall((json.dumps(req) + "\n").encode())
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
    finally:
        s.close()
    line = buf.split(b"\n", 1)[0].decode(errors="replace").strip()
    if not line:
        return {"ok": False, "error": {"code": "empty_response", "message": "bridge closed without a reply"}}
    try:
        return json.loads(line)
    except json.JSONDecodeError:
        return {"ok": False, "error": {"code": "bad_json", "message": line[:500]}}


def unwrap_hub_error(resp):
    """rest.request puts the hub's error body (a JSON string) in error.message."""
    err = resp.get("error") or {}
    if err.get("code") != "hub_error":
        return resp
    try:
        body = json.loads(err.get("message", ""))
    except json.JSONDecodeError:
        return resp
    hub_err = body.get("error") if isinstance(body, dict) else None
    if isinstance(hub_err, dict):
        return {"v": 1, "ok": False, "error": hub_err, "via": "rest.request"}
    return resp


def main(argv):
    endpoint = token = ""
    rest_mode = "auto"
    timeout = 330.0
    args = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--shim":
            endpoint, token = parse_shim(argv[i + 1]); i += 2
        elif a == "--endpoint":
            endpoint = argv[i + 1]; i += 2
        elif a == "--token":
            token = argv[i + 1]; i += 2
        elif a == "--timeout":
            timeout = float(argv[i + 1]); i += 2
        elif a == "--rest":
            rest_mode = "force"; i += 1
        elif a == "--no-rest":
            rest_mode = "never"; i += 1
        else:
            args.append(a); i += 1
    if not endpoint or not token or not args:
        print(__doc__, file=sys.stderr)
        return 2
    method = args[0]
    params = json.loads(args[1]) if len(args) > 1 and args[1].strip() else {}

    resp = None
    if rest_mode != "force":
        resp = call(endpoint, token, method, params, timeout)
        code = (resp.get("error") or {}).get("code", "")
        needs_fallback = (not resp.get("ok")) and code in ("forbidden", "unknown_method", "not_found", "bad_request", "unsupported") \
            and method in M2_PATHS and rest_mode == "auto"
        if not needs_fallback:
            print(json.dumps(resp))
            return 0 if resp.get("ok") else 1
    if method not in M2_PATHS:
        print(json.dumps(resp or {"ok": False, "error": {"code": "no_rest_path", "message": method}}))
        return 1
    rest = call(endpoint, token, "agent.rest.request",
                {"http_method": "POST", "path": M2_PATHS[method], "body": {"params": params}}, timeout)
    rest = unwrap_hub_error(rest)
    if rest.get("ok"):
        # the hub envelope is {ok,data,meta}; surface data like the native route does
        data = rest.get("data")
        if isinstance(data, dict) and "data" in data and "ok" in data:
            rest = {"v": 1, "ok": True, "data": data["data"], "via": "rest.request"}
        else:
            rest["via"] = "rest.request"
    print(json.dumps(rest))
    return 0 if rest.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
