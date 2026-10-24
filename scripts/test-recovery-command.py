#!/usr/bin/env python3
"""Exercise offline recovery against the real bridge, isolated from host state."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="ham-recovery-command-") as temporary:
    root = Path(temporary)
    env = dict(os.environ, HOME=str(root), HEIMDALL_HOME=str(root))
    env.pop("HAM_BRIDGE_TOKEN_FILE", None)
    config = root / "config.toml"
    config.write_text("")
    hub, bridge_id = "http://127.0.0.1:49322", "brg_recovery_regression"
    credential = root / "custom" / "access-token"
    credential.parent.mkdir()
    # Missing credentials are intentional: repair must work without healthy auth.
    args = ["--config", str(config), "--hub", hub, "--daemon-id", bridge_id,
            "--data-dir", str(root / "data"), "--local-run-dir", "recovery-fixture"]
    journal = root / "data/bridge/recovery-fixture/retry-journal-v1.json"
    journal.parent.mkdir(parents=True)
    budget = dict(state=1, attempts=1, code=0, **{"class": 0},
                  first_ms=1000, deadline_ms=121000, last_wall_ms=1000, next_ms=0)
    receipts = [dict(key=f"{kind}:{hub}:{bridge_id}", budget=budget.copy(), target_instance_id="")
                for kind in ("sync", "refresh")]
    receipts.append(dict(key="slot:preserve:1000", budget=budget.copy(), target_instance_id="inst_selected"))
    original = json.dumps(dict(version=1, receipts=receipts)).encode()
    journal.write_bytes(original)
    journal.chmod(0o600)
    marker = Path(str(journal) + ".initialized")
    marker.write_bytes(b"initialized")
    marker.chmod(0o600)

    def invoke(operation, expected, reason=""):
        result = subprocess.run([binary, "recovery", operation, *args], env=env,
                                capture_output=True, text=True, timeout=10)
        assert result.returncode == expected, (operation, result.returncode, result.stdout, result.stderr)
        if reason:
            assert reason in result.stderr, result.stderr
        if expected:
            assert journal.read_bytes() == original, "refusal rewrote receipt/fence"
            assert marker.read_bytes() == b"initialized", "refusal rewrote initialization marker"

    def lock_path(kind, key):
        digest = hashlib.sha256(f"heimdall-bridge-lock/v1|{kind}|{key}".encode()).hexdigest()[:32]
        path = root / ".config/heimdall/locks" / f"{kind}-{digest}.lock"
        path.parent.mkdir(parents=True, exist_ok=True)
        return path

    scope_digest = hashlib.sha256(f"heimdall-bridge-scope/v1|{hub}|{bridge_id}".encode()).hexdigest()[:32]
    scope = f"{bridge_id}_{scope_digest}"
    # Parent holds real POSIX service locks; child must refuse before journal load.
    for kind, key in (("config", str(config.resolve())), ("scope", scope)):
        with lock_path(kind, key).open("a+") as held:
            fcntl.lockf(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            for operation in ("resume-sync", "resume-refresh"):
                invoke(operation, 1, f"{kind} is unavailable")
        print(f"PASS both recovery commands refuse held {kind} lock without receipt changes", flush=True)

    # Environment-selected path must be used even when its access token is absent.
    env["HAM_BRIDGE_TOKEN_FILE"] = str(credential)
    pending = Path(str(credential) + ".pending-rotation-v1")
    pending.write_bytes(b"durable returned credential pair")
    pending.chmod(0o600)
    invoke("resume-refresh", 1, "pending rotated pair")
    assert pending.read_bytes() == b"durable returned credential pair"
    print("PASS environment-selected pending pair refuses reset and remains unchanged", flush=True)
    pending.unlink()
    env.pop("HAM_BRIDGE_TOKEN_FILE")
    invoke("resume-refresh", 1, "no effective credential file")
    print("PASS missing effective credential path fails closed", flush=True)

    # Releasing service locks and reconciling pending state permits explicit repair.
    env["HAM_BRIDGE_TOKEN_FILE"] = str(credential)
    invoke("resume-refresh", 0)
    updated = json.loads(journal.read_bytes())
    by_key = {r["key"]: r for r in updated["receipts"]}
    assert by_key[f"refresh:{hub}:{bridge_id}"]["budget"]["attempts"] == 0
    assert by_key[f"refresh:{hub}:{bridge_id}"]["budget"]["state"] == 0
    assert by_key["slot:preserve:1000"]["target_instance_id"] == "inst_selected"
    assert by_key["slot:preserve:1000"]["budget"]["attempts"] == 1
    assert by_key["slot:preserve:1000"]["budget"]["state"] == 4  # unknown remains fenced
    invoke("resume-sync", 0)
    assert json.loads(journal.read_bytes())["receipts"][0]["budget"]["attempts"] == 0
    print("PASS unlocked credentialless repair succeeds and preserves unknown slot fence", flush=True)
