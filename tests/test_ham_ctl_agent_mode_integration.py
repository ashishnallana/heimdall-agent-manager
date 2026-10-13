#!/usr/bin/env python3
"""Integration test for ham-ctl agent mode against a mock local Bridge endpoint.

Builds ham-ctl, stands up a mock JSONL v1 TCP endpoint, and drives the real
`ham-ctl agent` binary through the local endpoint contract (RTE2E-7):
- request envelope (v=1, id, token, method, params),
- success response passthrough,
- clear offline error when the endpoint is unreachable.
"""
import json
import os
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get("HAM_CTL_BIN", "/tmp/test-ham-ctl" if Path("/tmp/test-ham-ctl").exists() else "/tmp/ham-ctl-rte2e7/bin/ham-ctl"))


def require(cond, msg):
    if not cond:
        print(f"FAIL: {msg}", file=sys.stderr)
        sys.exit(1)


def build_binary(out_path: Path):
    import shutil
    odin = os.environ.get("ODIN") or shutil.which("odin")
    res = None
    if odin and os.environ.get("IN_NIX_SHELL"):
        res = subprocess.run([odin, "build", "src/ctl", "-collection:odin_test=src", f"-out:{out_path}"], cwd=ROOT, capture_output=True, text=True)
    if res is None or res.returncode != 0:
        res = subprocess.run(["nix", "develop", "--command", "odin", "build", "src/ctl", "-collection:odin_test=src", f"-out:{out_path}"], cwd=ROOT, capture_output=True, text=True)
    require(res.returncode == 0, f"ham-ctl build failed: {res.stderr}")


class MockEndpoint:
    """A one-shot JSONL v1 TCP endpoint that captures the request and replies."""

    def __init__(self):
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(1)
        self.port = self.listener.getsockname()[1]
        self.captured = None
        self.reply = '{"v":1,"id":"ham-ctl-agent","ok":true,"data":{"agent_instance_id":"inst_mock"}}'

    def serve_once(self):
        conn, _ = self.listener.accept()
        conn.settimeout(5)
        try:
            data = b""
            while b"\n" not in data:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
            self.captured = data.decode().strip()
            conn.sendall((self.reply + "\n").encode())
        finally:
            conn.close()

    def close(self):
        self.listener.close()


def run_agent(args, env_extra=None):
    env = dict(os.environ)
    if env_extra:
        env.update(env_extra)
    proc = subprocess.run(
        [str(BIN), "agent"] + args,
        capture_output=True, text=True, timeout=15, env=env,
    )
    return proc


def main():
    global BIN
    import shutil
    import tempfile
    tmp_dir = None
    if not os.environ.get("HAM_CTL_BIN") or not BIN.exists():
        tmp_dir = Path(tempfile.mkdtemp(prefix="ham-ctl-rte2e7-"))
        BIN = tmp_dir / "ham-ctl"
        build_binary(BIN)
    require(BIN.exists(), "ham-ctl binary must build")

    # --- missing endpoint/token -> usage -----------------------------------
    proc = run_agent(["--bridge-endpoint", "tcp:127.0.0.1:1", "context"],
                     env_extra={"HEIMDALL_AGENT_TOKEN": "hlat_test"})
    require(proc.returncode != 0 or "reachable" in proc.stdout,
            "missing endpoint should not silently succeed")

    # --- offline endpoint -> clear error -----------------------------------
    proc = run_agent(["--bridge-endpoint", "tcp:127.0.0.1:1",
                      "--agent-token", "hlat_test", "context"])
    require("reachable" in proc.stdout,
            f"offline endpoint must report clear error; got: {proc.stdout!r}")

    # --- live endpoint: context.get round-trip -----------------------------
    mock = MockEndpoint()
    t = threading.Thread(target=mock.serve_once)
    t.start()
    proc = run_agent([
        "--bridge-endpoint", f"tcp:127.0.0.1:{mock.port}",
        "--agent-token", "hlat_test_token", "context",
    ])
    t.join(timeout=10)
    mock.close()

    require(proc.returncode == 0, f"agent context should succeed; stderr={proc.stderr!r}")
    require(mock.captured is not None, "endpoint must capture the request line")
    req = json.loads(mock.captured)
    require(req["v"] == 1, "request must declare protocol v1")
    require(req["token"] == "hlat_test_token", "request must carry the local agent token")
    require(req["method"] == "agent.context.get", "request method must be agent.context.get")
    require("params" in req, "request must carry params object")
    require("agent_instance_id" in proc.stdout,
            f"stdout must pass through the endpoint data; got: {proc.stdout!r}")

    # --- env discovery (no flags) ------------------------------------------
    mock2 = MockEndpoint()
    t2 = threading.Thread(target=mock2.serve_once)
    t2.start()
    proc2 = run_agent(["start-success"],
                      env_extra={
                          "HEIMDALL_BRIDGE_ENDPOINT": f"tcp:127.0.0.1:{mock2.port}",
                          "HEIMDALL_AGENT_TOKEN": "hlat_env_token",
                      })
    t2.join(timeout=10)
    mock2.close()
    require(mock2.captured is not None, "env-based endpoint discovery must connect")
    req2 = json.loads(mock2.captured)
    require(req2["token"] == "hlat_env_token",
            "token must be discovered from HEIMDALL_AGENT_TOKEN env")
    require(req2["method"] == "agent.start_success",
            "start-success subcommand must map to agent.start_success")

    # --- H8: memory propose forwards scope flags into params ----------------
    # The hub already honors template_id/project_id/bridge_id/agent_id; this
    # asserts the CLI actually sends them (previously it dropped every scope).
    mock3 = MockEndpoint()
    t3 = threading.Thread(target=mock3.serve_once)
    t3.start()
    proc3 = run_agent([
        "--bridge-endpoint", f"tcp:127.0.0.1:{mock3.port}",
        "--agent-token", "hlat_mem", "memory", "propose",
        "--type", "habit", "--title", "Reviewer checklist", "--body", "do X",
        "--template-id", "tmpl_rev", "--project-id", "proj_1",
        "--bridge-id", "brg_1", "--agent-id", "agt_9",
    ])
    t3.join(timeout=10)
    mock3.close()
    require(mock3.captured is not None, "memory propose must reach the endpoint")
    req3 = json.loads(mock3.captured)
    require(req3["method"] == "agent.memory.propose",
            "memory propose must map to agent.memory.propose")
    p3 = req3["params"]
    require(p3.get("type") == "habit" and p3.get("title") == "Reviewer checklist",
            "type/title must be forwarded")
    require(p3.get("template_ids") == ["tmpl_rev"], "--template-id must forward template_ids")
    require(p3.get("project_ids") == ["proj_1"], "--project-id must forward project_ids")
    require(p3.get("bridge_ids") == ["brg_1"], "--bridge-id must forward bridge_ids")
    require(p3.get("agent_ids") == ["agt_9"], "--agent-id must forward agent_ids")

    # --- H8: omitting scope flags must NOT emit empty scope keys ------------
    # (so the hub's defaults apply: agent -> caller's own, others -> global).
    mock4 = MockEndpoint()
    t4 = threading.Thread(target=mock4.serve_once)
    t4.start()
    proc4 = run_agent([
        "--bridge-endpoint", f"tcp:127.0.0.1:{mock4.port}",
        "--agent-token", "hlat_mem", "memory", "propose",
        "--type", "fact", "--title", "No scope",
    ])
    t4.join(timeout=10)
    mock4.close()
    req4 = json.loads(mock4.captured)
    p4 = req4["params"]
    # --- cards create ------------------------------------------------------
    mock5 = MockEndpoint()
    t5 = threading.Thread(target=mock5.serve_once)
    t5.start()
    proc5 = run_agent([
        "--bridge-endpoint", f"tcp:127.0.0.1:{mock5.port}",
        "--agent-token", "hlat_card", "cards", "create",
        "--title", "Review PR", "--rationale", "Needs audit",
        "--operations", '[{"type":"task.create"}]',
        "--guard", '{"chain_idle":true}',
    ])
    t5.join(timeout=10)
    mock5.close()
    require(mock5.captured is not None, "cards create must reach endpoint")
    req5 = json.loads(mock5.captured)
    require(req5["method"] == "agent.cards.create", "cards create method must match")
    p5 = req5["params"]
    require(p5.get("title") == "Review PR", "title must match")
    require(p5.get("rationale") == "Needs audit", "rationale must match")
    require(p5.get("operations") == [{"type": "task.create"}], "operations must match")
    require(p5.get("guard") == {"chain_idle": True}, "guard must match")

    # --- cards list --------------------------------------------------------
    mock6 = MockEndpoint()
    t6 = threading.Thread(target=mock6.serve_once)
    t6.start()
    proc6 = run_agent([
        "--bridge-endpoint", f"tcp:127.0.0.1:{mock6.port}",
        "--agent-token", "hlat_card", "cards", "list",
        "--status", "pending", "--scope", "project",
    ])
    t6.join(timeout=10)
    mock6.close()
    req6 = json.loads(mock6.captured)
    require(req6["method"] == "agent.cards.list", "cards list method must match")
    require(req6["params"].get("status") == "pending", "status filter must match")
    require(req6["params"].get("scope") == "project", "scope filter must match")

    # --- cards show --------------------------------------------------------
    mock7 = MockEndpoint()
    t7 = threading.Thread(target=mock7.serve_once)
    t7.start()
    proc7 = run_agent([
        "--bridge-endpoint", f"tcp:127.0.0.1:{mock7.port}",
        "--agent-token", "hlat_card", "cards", "show", "crd_abc123",
    ])
    t7.join(timeout=10)
    mock7.close()
    req7 = json.loads(mock7.captured)
    require(req7["method"] == "agent.cards.show", "cards show method must match")
    require(req7["params"].get("card_id") == "crd_abc123", "card_id must match")

    # --- cards discard -----------------------------------------------------
    mock8 = MockEndpoint()
    t8 = threading.Thread(target=mock8.serve_once)
    t8.start()
    proc8 = run_agent([
        "--bridge-endpoint", f"tcp:127.0.0.1:{mock8.port}",
        "--agent-token", "hlat_card", "cards", "discard", "crd_abc123",
    ])
    t8.join(timeout=10)
    mock8.close()
    req8 = json.loads(mock8.captured)
    require(req8["method"] == "agent.cards.discard", "cards discard method must match")
    require(req8["params"].get("card_id") == "crd_abc123", "card_id must match")

    # --- cards accept ------------------------------------------------------
    mock9 = MockEndpoint()
    t9 = threading.Thread(target=mock9.serve_once)
    t9.start()
    proc9 = run_agent([
        "--bridge-endpoint", f"tcp:127.0.0.1:{mock9.port}",
        "--agent-token", "hlat_card", "cards", "accept", "crd_abc123",
    ])
    t9.join(timeout=10)
    mock9.close()
    req9 = json.loads(mock9.captured)
    require(req9["method"] == "agent.cards.accept", "cards accept method must match")
    require(req9["params"].get("card_id") == "crd_abc123", "card_id must match")

    print("PASS: ham-ctl agent mode integration")


if __name__ == "__main__":
    main()
