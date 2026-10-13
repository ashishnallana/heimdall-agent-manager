#!/usr/bin/env python3
"""Home Manager bridge service env must be self-contained enough to launch agents."""
from pathlib import Path
import json
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def eval_bridge(extra_module: str = "{}") -> dict:
    expr = f'''
let
  flake = builtins.getFlake "git+file://{ROOT}";
  system = builtins.currentSystem;
  pkgs = import flake.inputs.nixpkgs {{ inherit system; }};
  lib = pkgs.lib // {{ hm = {{ dag = {{ entryAfter = deps: value: value; }}; }}; }};
  module = flake.outputs.homeModules.default;
  hmStub = {{ lib, ... }}: {{
    options = {{
      home.username = lib.mkOption {{ type = lib.types.str; default = "tester"; }};
      home.homeDirectory = lib.mkOption {{ type = lib.types.str; default = "/home/tester"; }};
      home.profileDirectory = lib.mkOption {{ type = lib.types.str; default = "/home/tester/.nix-profile"; }};
      home.packages = lib.mkOption {{ type = lib.types.listOf lib.types.anything; default = []; }};
      home.activation = lib.mkOption {{ type = lib.types.attrsOf lib.types.anything; default = {{}}; }};
      assertions = lib.mkOption {{ type = lib.types.listOf lib.types.anything; default = []; }};
      xdg.configFile = lib.mkOption {{
        type = lib.types.attrsOf (lib.types.submodule ({{ name, ... }}: {{
          options.source = lib.mkOption {{ type = lib.types.path; }};
        }}));
        default = {{}};
      }};
      systemd.user.services = lib.mkOption {{ type = lib.types.attrsOf lib.types.anything; default = {{}}; }};
      launchd.agents = lib.mkOption {{ type = lib.types.attrsOf lib.types.anything; default = {{}}; }};
    }};
  }};
  eval = lib.evalModules {{
    modules = [
      hmStub
      module
      {{
        programs.heimdall.enable = true;
        programs.heimdall.packageNames = [ "bridge" ];
        programs.heimdall.bridge.enable = true;
      }}
      {extra_module}
    ];
    specialArgs = {{ inherit pkgs; }};
  }};
in builtins.toJSON {{
  systemdEnv = eval.config.systemd.user.services.heimdall-bridge.Service.Environment;
  launchdEnv = eval.config.launchd.agents.heimdall-bridge.config.EnvironmentVariables;
  packageNames = map (p: p.pname or p.name or "") eval.config.home.packages;
}}
'''
    res = subprocess.run(
        ["nix", "eval", "--impure", "--raw", "--expr", expr],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if res.returncode != 0:
        print(res.stdout)
        print(res.stderr)
        raise SystemExit(res.returncode)
    return json.loads(res.stdout)


def require(name: str, ok: bool) -> None:
    if not ok:
        raise AssertionError(name)


def systemd_env_map(rows: list[str]) -> dict[str, str]:
    out = {}
    for row in rows:
        key, _, value = row.partition("=")
        out[key] = value
    return out


def main() -> int:
    data = eval_bridge()
    sys_env = systemd_env_map(data["systemdEnv"])
    launchd_env = data["launchdEnv"]
    packages = "\n".join(data["packageNames"])

    for env_name, env in [("systemd", sys_env), ("launchd", launchd_env)]:
        # pty-host runtime: the bridge launches agents through ham-pty-host, so the
        # pty-host bin is pinned (no ham-wrapper), plus the ham-ctl bin for bootstrap.
        require(f"{env_name} pty-host bin pinned", env.get("HEIMDALL_HAM_PTY_HOST_BIN", "").endswith("/bin/ham-pty-host"))
        require(f"{env_name} pty-host runtime enabled", env.get("HEIMDALL_BRIDGE_PTY_HOST", "") == "true")
        require(f"{env_name} ctl bin pinned", env.get("HEIMDALL_HAM_CTL_BIN", "").endswith("/bin/ham-ctl"))
        require(f"{env_name} shell is absolute bash", env.get("SHELL", "").endswith("/bin/bash"))
        path = env.get("PATH", "")
        require(f"{env_name} PATH includes home profile", "/home/tester/.nix-profile/bin" in path)
        require(f"{env_name} PATH includes pi install dir", "/home/tester/.pi/agent/bin" in path)
        require(f"{env_name} PATH includes user local bin", "/home/tester/.local/bin" in path)
        require(f"{env_name} PATH includes pty-host package", "ham-pty-host" in path)
        require(f"{env_name} PATH includes bash package", "bash" in path)
        require(f"{env_name} PATH includes system fallback", "/run/current-system/sw/bin" in path)

    require("bridge installs matching ham-ctl for agent bootstrap", "ham-ctl" in packages)
    require("bridge installs ham-pty-host runtime dependency", "ham-pty-host" in packages)

    overridden = eval_bridge('''
      {
        programs.heimdall.bridge.environment = {
          PATH = "/custom/bin";
          SHELL = "/custom/sh";
        };
      }
    ''')
    overridden_sys = systemd_env_map(overridden["systemdEnv"])
    require("bridge env PATH remains user-overridable", overridden_sys.get("PATH") == "/custom/bin")
    require("bridge env SHELL remains user-overridable", overridden_sys.get("SHELL") == "/custom/sh")

    print("TEST PASSED: Home Manager bridge env includes PATH/SHELL and matching pty-host/ctl")
    return 0


if __name__ == "__main__":
    sys.exit(main())
