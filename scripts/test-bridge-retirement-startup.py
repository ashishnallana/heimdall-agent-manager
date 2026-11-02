#!/usr/bin/env python3
"""Focused real-binary retirement startup/activation checks; no enrollment or keychain."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="ham-retirement-") as temporary, socket.socket() as listener:
    root = Path(temporary)
    env = dict(os.environ, HOME=str(root), HEIMDALL_HOME=str(root))
    env.pop("HAM_BRIDGE_TOKEN_FILE", None)
    listener.bind(("127.0.0.1", 0))
    listener.listen()
    hub = f"http://127.0.0.1:{listener.getsockname()[1]}"
    bridge_id = "brg_retirement_smoke"
    config = root / "config.toml"
    config.write_text("")
    alias = root / "config-alias.toml"
    alias.symlink_to(config)
    marker = Path(str(config) + ".hub-paused-v1")
    args = ["--config", str(alias), "--hub", hub, "--daemon-id", bridge_id,
            "--data-dir", str(root / "data")]
    pause = dict(hub=hub, bridge_id=bridge_id, final=False)

    def write_pause(value):
        marker.write_text(json.dumps(value) if isinstance(value, dict) else value)
        marker.chmod(0o600)

    def no_traffic():
        assert not select.select([listener], [], [], 0.05)[0], "unexpected Hub connection"

    def resume(expected):
        original = marker.read_bytes()
        result = subprocess.run([binary, "recovery", "resume-sunset", *args], env=env,
                                capture_output=True, text=True, timeout=5)
        assert result.returncode == expected, (result.returncode, result.stdout, result.stderr)
        if expected:
            assert marker.read_bytes() == original, "refusal modified the pause"
        else:
            assert not marker.exists(), "activation did not clear the pause"
        no_traffic()

    # Real startup, through a config symlink, must park before even credentialless
    # enrollment recovery. The parked service also owns the config exclusion lock.
    for value in (pause, {**pause, "final": True}, "corrupt"):
        write_pause(value)
        child = subprocess.Popen([binary, *args], env=env, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True)
        try:
            assert select.select([child.stderr], [], [], 5)[0], "no startup result"
            line = child.stderr.readline()
            assert "Hub traffic is paused" in line, line
            assert child.poll() is None, "parked service exited into a restart loop"
            no_traffic()
            resume(1)
        finally:
            child.terminate()
            child.communicate(timeout=5)
    print("PASS temporary/final/corrupt startup parks, alias shares fence, live service refuses activation", flush=True)

    # Parent-held POSIX locks prove the real child honors both exclusion scopes.
    write_pause(pause)
    scope_digest = hashlib.sha256(f"heimdall-bridge-scope/v1|{hub}|{bridge_id}".encode()).hexdigest()[:32]
    for kind, key in (("config", str(config.resolve())), ("scope", f"{bridge_id}_{scope_digest}")):
        digest = hashlib.sha256(f"heimdall-bridge-lock/v1|{kind}|{key}".encode()).hexdigest()[:32]
        path = root / ".config/heimdall/locks" / f"{kind}-{digest}.lock"
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a+") as held:
            fcntl.lockf(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            resume(1)
    print("PASS explicit activation refuses held config/scope locks without Hub I/O", flush=True)

    for value in ({**pause, "final": True}, {**pause, "bridge_id": "brg_other"}, "corrupt"):
        write_pause(value)
        resume(1)
    write_pause(pause)
    resume(0)
    print("PASS final/mismatched/corrupt resume refuses; matching temporary resume clears locally", flush=True)
