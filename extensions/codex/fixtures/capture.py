"""Private, bounded capture of native Codex callbacks for synthetic fixture runs."""
import fcntl
import json
import os
from pathlib import Path
import sys

MAX_INPUT = 1024 * 1024
MAX_CAPTURE = 16 * 1024 * 1024

def main():
    root = Path(sys.argv[1]).resolve(strict=True)
    raw = sys.stdin.buffer.read(MAX_INPUT + 1)
    if len(raw) > MAX_INPUT:
        return
    try:
        payload = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        return
    if not isinstance(payload, dict):
        return
    # Never capture the prompt or transcript; fixture tools use synthetic data.
    omitted = {"prompt", "transcript_path", "agent_transcript_path",
               "last_assistant_message", "usage"}
    payload = {k: v for k, v in payload.items() if k not in omitted}
    line = (json.dumps(payload, ensure_ascii=False) + "\n").encode()
    fd = os.open(root / "callbacks.jsonl", os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        if os.fstat(fd).st_size + len(line) <= MAX_CAPTURE:
            os.write(fd, line)
    finally:
        os.close(fd)
    # Empty output leaves all native decisions unchanged.

if __name__ == "__main__":
    main()
