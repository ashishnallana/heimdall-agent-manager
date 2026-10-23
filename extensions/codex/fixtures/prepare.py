"""Create/check an isolated Codex fixture environment; never edit the real store."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil

EVENTS = ("SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse",
          "PostToolUse", "PermissionRequest", "SubagentStart", "SubagentStop",
          "Stop", "Interrupt", "PreCompact", "PostCompact")

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("action", choices=("init", "check", "cleanup"))
    ap.add_argument("root", type=Path)
    ap.add_argument("--copy-native-auth", action="store_true",
                    help="requires explicit authorization to copy native credentials")
    args = ap.parse_args()
    root = args.root.expanduser().absolute()
    real = Path.home() / ".codex"
    if args.action == "init":
        if real == root or real in root.parents:
            ap.error("fixture root must be outside the real Codex home")
        os.umask(0o077)
        root.mkdir(mode=0o700)
        for name in ("home", "user", "workspace", "capture"):
            (root / name).mkdir(mode=0o700)
        originals = [real / name for name in ("auth.json", "config.toml", "hooks.json")]
        (root / "original-checksums.json").write_text(
            json.dumps({str(p): digest(p) for p in originals}, indent=2) + "\n")
        command = shlex.join(("python3", str(Path(__file__).with_name("capture.py").resolve()),
                              str(root / "capture")))
        hooks = {"hooks": {event: [{"hooks": [{"type": "command", "command": command,
                 "timeout": 3 if event in ("Interrupt", "SessionEnd") else 330 if event == "PermissionRequest" else 10}]}]
                 for event in EVENTS}}
        (root / "home/hooks.json").write_text(json.dumps(hooks, indent=2) + "\n")
        # Preserve native model defaults. No production config/profile is copied.
        (root / "home/config.toml").write_text("")
        if args.copy_native_auth:
            shutil.copyfile(real / "auth.json", root / "home/auth.json")
            os.chmod(root / "home/auth.json", 0o600)
        print("Fixture environment created; review/trust hooks through native /hooks.")
    else:
        if args.action == "cleanup":
            (root / "home/auth.json").unlink(missing_ok=True)
        expected = json.loads((root / "original-checksums.json").read_text())
        changed = [p for p, value in expected.items() if digest(Path(p)) != value]
        if changed:
            raise SystemExit("Original files changed: " + ", ".join(changed))
        print("Original Codex auth/config checksums unchanged.")
        if args.action == "cleanup":
            print("Temporary native credential copy removed.")

if __name__ == "__main__":
    main()
