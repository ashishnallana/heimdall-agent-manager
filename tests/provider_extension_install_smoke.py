#!/usr/bin/env python3
"""Exercise the real provider CLIs in disposable homes; never install on the host.

Build ham-ctl first, then run:
  python3 tests/provider_extension_install_smoke.py --ctl /path/to/ham-ctl
Requires agy, claude and codex on PATH. Every provider gets a separate HOME,
configuration/data directories, and a private copy of the extension marketplace.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def run(argv, env, cwd):
    result = subprocess.run(
        [str(arg) for arg in argv], env=env, cwd=cwd,
        capture_output=True, text=True, timeout=65, stdin=subprocess.DEVNULL,
    )
    if result.returncode:
        raise AssertionError(f"{argv}: {result.stderr or result.stdout}")
    return result.stdout


def stamp(bundle, version):
    for name in ("antigravity/plugin.json", "claude-code/.claude-plugin/plugin.json",
                 "codex/.codex-plugin/plugin.json"):
        path = bundle / name
        data = json.loads(path.read_text())
        data["version"] = version
        path.write_text(json.dumps(data))
    path = bundle / ".claude-plugin/marketplace.json"
    data = json.loads(path.read_text())
    data["metadata"]["version"] = version
    data["plugins"][0]["version"] = version
    path.write_text(json.dumps(data))


def check_provider(provider, binary, ctl, source, root):
    work = root / provider
    home = work / "home"
    home.mkdir(parents=True)
    bundle = work / "extensions"
    shutil.copytree(source, bundle, symlinks=True)
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("HEIMDALL_", "CLAUDE_", "CODEX_", "GEMINI_", "XDG_"))}
    env.update(HOME=str(home), CLAUDE_CONFIG_DIR=str(home / ".claude"),
               CODEX_HOME=str(home / ".codex"), GEMINI_CONFIG_DIR=str(home / ".gemini"),
               XDG_CONFIG_HOME=str(home / ".config"),
               XDG_DATA_HOME=str(home / ".local/share"),
               XDG_CACHE_HOME=str(home / ".cache"),
               XDG_STATE_HOME=str(home / ".local/state"))
    for name in (".claude", ".codex", ".gemini"):
        (home / name).mkdir()
    variant = "claude-code" if provider == "claude" else provider
    for version in ("0.1.0", "0.4.31"):
        stamp(bundle, version)
        output = run([ctl, "extension", "install", provider, "--path", bundle / variant, "--json"], env, work)
        result = json.loads(output)
        assert result["ok"], result
        listed = json.loads(run([binary, "plugin", "list", "--json"], env, work))
        if provider == "claude":
            entries = listed
            match = next(item for item in entries if item["id"] == "heimdall@heimdall")
            assert match["version"] == version and match["enabled"], match
        elif provider == "codex":
            match = next(item for item in listed["installed"] if item["pluginId"] == "heimdall@heimdall-codex")
            assert match["version"] == version and match["enabled"], match
        else:
            assert any(item["name"] == "heimdall" for item in listed["imports"]), listed
            manifests = list((home / ".gemini").rglob("plugins/heimdall/plugin.json"))
            assert manifests, "installed Antigravity manifest missing"
            assert json.loads(manifests[0].read_text())["version"] == version
        print(f"PASS {provider}: install/update to {version}", flush=True)
    if provider == "antigravity":
        run([binary, "plugin", "disable", "heimdall"], env, work)
        listed = json.loads(run([binary, "plugin", "list", "--json"], env, work))
        assert any(item["name"] == "heimdall" for item in listed["imports"])
        configs = list((home / ".gemini").rglob("config.json"))
        assert any(json.loads(path.read_text()).get("plugins", {}).get("heimdall", {}).get("enabled") is False
                   for path in configs)
        print("PASS antigravity: disable leaves imports listed; config records enabled=false", flush=True)


def check_json_diagnostics(ctl, root):
    directory = root / "fake-bin"
    directory.mkdir()
    binary = directory / "agy"
    binary.write_text('#!/bin/sh\nprintf \'%s\\n\' \'provider "error" with \\slashes\' \'second line\' >&2\nexit 7\n')
    binary.chmod(0o700)
    env = dict(os.environ, PATH=str(directory) + os.pathsep + os.environ["PATH"])
    result = subprocess.run(
        [str(ctl), "extension", "install", "antigravity", "--path", str(root), "--json"],
        env=env, cwd=root, capture_output=True, text=True, timeout=5,
    )
    assert result.returncode == 1, result
    output = json.loads(result.stdout)
    assert output["ok"] is False and output["error"] == 'provider "error" with \\slashes\nsecond line', output
    print("PASS CLI JSON: provider stderr quotes, backslashes and newlines round-trip", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ctl", required=True, type=Path)
    args = parser.parse_args()
    ctl = args.ctl.resolve(strict=True)
    source = Path(__file__).resolve().parents[1] / "extensions"
    binaries = {provider: shutil.which(binary) for provider, binary in
                (("antigravity", "agy"), ("claude", "claude"), ("codex", "codex"))}
    assert all(binaries.values()), f"Missing provider CLI: {binaries}"
    cache = Path.home() / ".cache/heimdall-tests"
    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="provider-extension-smoke-", dir=cache) as temporary:
        root = Path(temporary)
        check_json_diagnostics(ctl, root)
        for provider, binary in binaries.items():
            check_provider(provider, binary, ctl, source, root)
    print("All isolated native provider extension checks passed.")


if __name__ == "__main__":
    main()
