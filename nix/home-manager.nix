# Heimdall AI Manager – Home Manager module
#
# Exposes programs.heimdall.{hub,bridge,ctl,...} options and generates
# ~/.config/heimdall/config.toml.  ham-* binaries are added to $PATH via
# home.packages.
#
# Usage in a flake-based home-manager config:
#
#   inputs.heimdall.url = "github:yourorg/heimdall-agent-manager";
#
#   home-manager.users.you = { imports = [ inputs.heimdall.homeModules.default ]; ... };
#
# Then set programs.heimdall options (see nix/README.md for a full example).

{ self }:
{ config, lib, pkgs, ... }:

let
  cfg = config.programs.heimdall;

  tomlFormat  = pkgs.formats.toml { };

  system = pkgs.stdenv.hostPlatform.system;
  bridgePkg = self.packages.${system}.ham-bridge;
  ctlPkg = self.packages.${system}.ham-ctl;
  ptyHostPkg = self.packages.${system}.ham-pty-host;

  mkGuideAgent = g: {
    enabled            = g.enabled;
    autostart          = g.autostart;
    restart_if_stopped = g.restartIfStopped;
    agent_instance_id  = g.agentInstanceId;
    template_id        = g.templateId;
    provider_profile   = g.providerProfile;
    model_tier         = g.modelTier;
  };

  configAttrs =
    { guide_agent = mkGuideAgent cfg.guideAgent; }
    // lib.optionalAttrs cfg.bridge.enable  {
      bridge = {
        pty_host_runtime = cfg.bridge.ptyHostRuntime;
        fs_read_page_bytes = cfg.bridge.fsReadPageBytes;
      };
    }
    // lib.optionalAttrs cfg.ctl.enable     { ctl     = { daemon_url = cfg.ctl.daemonUrl; }; };

  resolvePackage = name:
    if name == "agents" then hamAgentsPkg
    else
      self.packages.${system}.${
        { hub = "ham-hub"; bridge = "ham-bridge"; ctl = "ham-ctl";
          test-agent = "ham-test-agent"; ui = "heimdall"; pty-host = "ham-pty-host"; }.${name}
      };

  bridgeInstanceType = lib.types.submodule ({ name, ... }: {
    options = {
      enable = lib.mkOption { type = lib.types.bool; default = true; description = "Enable this named ham-bridge service."; };
      ptyHostRuntime = lib.mkOption { type = lib.types.bool; default = true; description = "Run agents directly via ham-pty-host (replacing wrapper/tmux)."; };
      hubUrl = lib.mkOption { type = lib.types.str; default = "http://127.0.0.1:8081"; example = "https://hub.mundus.in"; description = "Hub base URL used by ham-bridge (--hub)."; };
      fsReadPageBytes = lib.mkOption { type = lib.types.int; default = 131072; description = "Per-request byte chunk size for paginated fs_read_file reads. 128 KiB matches the socat TLS backend (the default); the legacy s_client fallback clamps the effective page down to 8000 internally (its ~16 KB multi-read teardown ceiling)."; };
      tokenFile = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; description = "Path to a file containing this bridge's enrolled hba_ credential, written by `ham-bridge enroll --ui`. The legacy non-expiring hbr_ token is no longer minted or accepted (REQ-ENROLL-9)."; };
      bindHost = lib.mkOption { type = lib.types.str; default = "127.0.0.1"; description = "Loopback host for this bridge HTTP server."; };
      port = lib.mkOption { type = lib.types.port; default = 49323; description = "Loopback TCP port for this bridge HTTP server. Must be unique per local bridge."; };
      localEndpointPort = lib.mkOption { type = lib.types.nullOr lib.types.port; default = null; description = "Wrapper-local endpoint TCP port. Null defaults to port + 1, so wrappers launched by this bridge heartbeat to the matching bridge."; };
      localRunDir = lib.mkOption { type = lib.types.str; default = "/tmp/heimdall-bridge-local-${name}"; description = "Runtime directory for this bridge's local endpoint socket/files. Must be unique per local bridge."; };
      logDir = lib.mkOption { type = lib.types.str; default = "/tmp/heimdall-logs"; description = "Directory used for launchd stdout/stderr logs on macOS."; };
      extraArgs = lib.mkOption { type = lib.types.listOf lib.types.str; default = []; description = "Additional arguments appended to this ham-bridge service command."; };
      environment = lib.mkOption { type = lib.types.attrsOf lib.types.str; default = {}; description = "Extra environment variables for this bridge service."; };
      service = {
        enable = lib.mkOption { type = lib.types.bool; default = true; description = "Create a systemd user service on Linux or launchd agent on macOS."; };
        startOnBoot = lib.mkOption { type = lib.types.bool; default = true; description = "Start this bridge service on user login."; };
      };
    };
  });

  bridgePrimaryConfig = {
    enable = cfg.bridge.enable;
    ptyHostRuntime = cfg.bridge.ptyHostRuntime;
    hubUrl = cfg.bridge.hubUrl;
    fsReadPageBytes = cfg.bridge.fsReadPageBytes;
    tokenFile = cfg.bridge.tokenFile;
    bindHost = cfg.bridge.bindHost;
    port = cfg.bridge.port;
    localEndpointPort = cfg.bridge.localEndpointPort;
    localRunDir = cfg.bridge.localRunDir;
    logDir = cfg.bridge.logDir;
    extraArgs = cfg.bridge.extraArgs;
    environment = cfg.bridge.environment;
    service = cfg.bridge.service;
  };

  # The per-Hub profile service name ham-bridge setup/status/update/uninstall use
  # (bridgesvc.service_name): heimdall-bridge-<hub>[_<profile>], <hub> being the
  # lower-cased host with every other character as '-' plus -<port> unless it
  # is the scheme's default. The launchd label is the same name.
  hubServiceName = url: profile:
    let
      m = builtins.match "(https?)://([^/?#]*).*" (lib.toLower url);
      scheme = builtins.elemAt m 0;
      authority = builtins.elemAt m 1;
      v6 = builtins.match "\\[([^]]*)](:([0-9]+))?" authority;
      hp = if v6 != null then v6 else builtins.match "([^:]*)(:([0-9]+))?" authority;
      host = lib.removeSuffix "." (builtins.elemAt hp 0);
      rawPort = builtins.elemAt hp 2;
      port = if rawPort == null then "" else toString (lib.toInt rawPort);
      defaultPort = (scheme == "http" && port == "80") || (scheme == "https" && port == "443");
      safe = lib.stringAsChars (c: if builtins.match "[a-z0-9-]" c != null then c else "-") host;
    in
    assert lib.assertMsg (m != null) "programs.heimdall: hubUrl ${url} must be an http(s) origin";
    "heimdall-bridge-${safe}${lib.optionalString (port != "" && !defaultPort) "-${port}"}${lib.optionalString (profile != "") "_${profile}"}";

  bridgeServiceEntries =
    (lib.optional cfg.bridge.enable (let n = hubServiceName bridgePrimaryConfig.hubUrl ""; in { name = "default"; config = bridgePrimaryConfig; serviceName = n; label = n; }))
    ++ (lib.mapAttrsToList (name: bridgeCfg: let n = hubServiceName bridgeCfg.hubUrl name; in { name = name; config = bridgeCfg; serviceName = n; label = n; }) cfg.bridges);

  anyBridgeEnabled = cfg.bridge.enable || lib.any (bridgeCfg: bridgeCfg.enable) (lib.attrValues cfg.bridges);
  enabledBridgeEntries = lib.filter (entry: entry.config.enable) bridgeServiceEntries;
  enabledBridgeServiceEntries = lib.filter (entry: entry.config.enable && entry.config.service.enable && entry.config.service.startOnBoot) bridgeServiceEntries;

  bridgeActualLocalEndpointPort = bridgeCfg:
    if bridgeCfg.localEndpointPort != null then bridgeCfg.localEndpointPort else bridgeCfg.port + 1;

  hamAgentsPkg =
    let
      entry =
        if enabledBridgeEntries != [] then lib.head enabledBridgeEntries
        else { config = bridgePrimaryConfig; };
    in
    pkgs.writeShellScriptBin "ham-agents" ''
      #!/usr/bin/env bash
      set -euo pipefail
      SOCKET="''${HAM_PTY_HOST_SOCKET:-${entry.config.localRunDir}/pty-host-port-${toString (bridgeActualLocalEndpointPort entry.config)}.sock}"
      exec ${ptyHostPkg}/bin/ham-pty-host --socket "$SOCKET" "$@"
    '';

  bridgeCommandArgsFor = bridgeCfg: [
    "${bridgePkg}/bin/ham-bridge"
    "--hub" bridgeCfg.hubUrl
    "--bind-host" bridgeCfg.bindHost
    "--port" (toString bridgeCfg.port)
    "--fs-read-page-bytes" (toString bridgeCfg.fsReadPageBytes)
    "--local-endpoint-port" (toString (bridgeActualLocalEndpointPort bridgeCfg))
    "--local-run-dir" bridgeCfg.localRunDir
  ]
  ++ lib.optionals (bridgeCfg.tokenFile != null) [ "--bridge-token-file" bridgeCfg.tokenFile ]
  ++ bridgeCfg.extraArgs;

  bridgeDefaultPath = lib.concatStringsSep ":" [
    "${config.home.profileDirectory}/bin"
    "${config.home.homeDirectory}/.pi/agent/bin"
    "${config.home.homeDirectory}/.local/bin"
    "${ptyHostPkg}/bin"
    (lib.makeBinPath [ pkgs.bashInteractive pkgs.coreutils pkgs.telegraf ])
    "/run/current-system/sw/bin"
    "/etc/profiles/per-user/${config.home.username}/bin"
    "/opt/homebrew/bin"
    "/usr/local/bin"
    "/usr/bin"
    "/bin"
  ];

  bridgeEnvironmentFor = bridgeCfg: {
    HEIMDALL_HAM_PTY_HOST_BIN = "${ptyHostPkg}/bin/ham-pty-host";
    HEIMDALL_BRIDGE_PTY_HOST = if bridgeCfg.ptyHostRuntime then "true" else "false";
    HEIMDALL_HAM_CTL_BIN = "${ctlPkg}/bin/ham-ctl";
    PATH = bridgeDefaultPath;
    SHELL = "${pkgs.bashInteractive}/bin/bash";
  } // bridgeCfg.environment;

  bridgeServicePorts = map (entry: entry.config.port) enabledBridgeServiceEntries;
  bridgeLocalEndpointPorts = map (entry: bridgeActualLocalEndpointPort entry.config) enabledBridgeServiceEntries;
  bridgeLocalRunDirs = map (entry: entry.config.localRunDir) enabledBridgeServiceEntries;

in
{
  # ── Option declarations ────────────────────────────────────────────────────

  options.programs.heimdall = {
    enable = lib.mkEnableOption "Heimdall Agent Manager";

    packageNames = lib.mkOption {
      type    = lib.types.listOf (lib.types.enum [ "hub" "bridge" "ctl" "test-agent" "ui" "pty-host" "agents" ]);
      default = [ "hub" "bridge" "ctl" "pty-host" ];
      example = [ "hub" "bridge" "ctl" "pty-host" "ui" ];
      description = ''
        Heimdall packages to install and add to $PATH.
        "hub"        → ham-hub
        "bridge"     → ham-bridge
        "ctl"        → ham-ctl     (+ bc-odinctl symlink)
        "test-agent" → ham-test-agent
        "pty-host"   → ham-pty-host
        "agents"     → ham-agents wrapper
        "ui"         → heimdall Electron app
      '';
    };

    extraPackages = lib.mkOption {
      type        = lib.types.listOf lib.types.package;
      default     = [];
      description = "Additional packages to install alongside the Heimdall binaries.";
    };

    # ── [guide_agent] ────────────────────────────────────────────────────────

    guideAgent = {
      enabled = lib.mkOption {
        type        = lib.types.bool;
        default     = false;
        description = "Whether the guide agent is enabled (`[guide_agent].enabled`).";
      };
      autostart = lib.mkOption {
        type        = lib.types.bool;
        default     = false;
        description = "Whether the daemon should start the guide agent during daemon startup (`[guide_agent].autostart`).";
      };
      restartIfStopped = lib.mkOption {
        type        = lib.types.bool;
        default     = false;
        description = "Guide-agent config parity for `[guide_agent].restart_if_stopped`. The current runtime stores and reports this value, but no restart loop behavior was found in the daemon yet.";
      };
      agentInstanceId = lib.mkOption {
        type        = lib.types.str;
        default     = "guide@heimdall";
        description = "Guide singleton agent instance ID (`[guide_agent].agent_instance_id`). Non-default values are accepted by config parsing, but the current daemon launch path only starts the default singleton and otherwise reports `invalid_singleton_id`.";
      };
      templateId = lib.mkOption {
        type        = lib.types.str;
        default     = "guide";
        description = "Guide template ID (`[guide_agent].template_id`).";
      };
      providerProfile = lib.mkOption {
        type        = lib.types.str;
        default     = "pi";
        description = "Provider profile for the guide agent (`[guide_agent].provider_profile`). Set to an empty string to fall back to `[daemon].default_agent_provider_profile`, then `pi`.";
      };
      modelTier = lib.mkOption {
        type        = lib.types.enum [ "cheap" "normal" "smart" ];
        default     = "smart";
        description = "Model tier for the guide agent (`[guide_agent].model_tier`).";
      };
    };


    bridge = {
      enable = lib.mkOption {
        type        = lib.types.bool;
        default     = false;
        description = "Install/configure the ham-bridge user service.";
      };
      ptyHostRuntime = lib.mkOption {
        type        = lib.types.bool;
        default     = true;
        description = "Run agents directly via ham-pty-host (replacing wrapper/tmux).";
      };
      hubUrl = lib.mkOption {
        type        = lib.types.str;
        default     = "http://127.0.0.1:8081";
        example     = "https://heimdall.mundus.in";
        description = "Hub base URL used by ham-bridge (--hub).";
      };
      fsReadPageBytes = lib.mkOption {
        type        = lib.types.int;
        default     = 131072;
        description = "Per-request byte chunk size for paginated fs_read_file reads. 128 KiB matches the socat TLS backend (the default); the legacy s_client fallback clamps the effective page down to 8000 internally (its ~16 KB multi-read teardown ceiling).";
      };
      tokenFile = lib.mkOption {
        type        = lib.types.nullOr lib.types.str;
        default     = null;
        defaultText = lib.literalExpression "null";
        description = ''
          Path to a file containing the enrolled bridge credential (hba_...). The
          file is read by ham-bridge via --bridge-token-file and is not
          generated into the Nix store. Create it with mode 0600, or enroll with
          `ham-bridge enroll --ui <browser-origin> --bridge-token-file <path>`.

          Enrollment is browser-approved: that command prints a link and a short
          code for a human to approve, and the credential is delivered to this
          machine directly. There is no enrollment token to create on the hub --
          `--enrollment-token` and the legacy non-expiring hbr_ token are deleted
          (REQ-ENROLL-9). Add --headless if this machine has no browser.
        '';
      };
      bindHost = lib.mkOption {
        type        = lib.types.str;
        default     = "127.0.0.1";
        description = "Loopback host for the bridge HTTP server.";
      };
      port = lib.mkOption {
        type        = lib.types.port;
        default     = 49323;
        description = "Loopback TCP port for the bridge HTTP server.";
      };
      localEndpointPort = lib.mkOption {
        type        = lib.types.nullOr lib.types.port;
        default     = null;
        description = "Optional TCP port for the wrapper-local bridge endpoint. Null defaults to bridge.port + 1 so wrappers launched by this bridge heartbeat to the matching bridge.";
      };
      localRunDir = lib.mkOption {
        type        = lib.types.str;
        default     = "/tmp/heimdall-bridge-local";
        description = "Runtime directory for the bridge local endpoint socket/files.";
      };
      logDir = lib.mkOption {
        type        = lib.types.str;
        default     = "/tmp/heimdall-logs";
        defaultText = lib.literalExpression ''"/tmp/heimdall-logs"'';
        description = "Directory used for launchd stdout/stderr logs on macOS.";
      };
      extraArgs = lib.mkOption {
        type        = lib.types.listOf lib.types.str;
        default     = [];
        description = "Additional arguments appended to the ham-bridge service command.";
      };
      environment = lib.mkOption {
        type        = lib.types.attrsOf lib.types.str;
        default     = {};
        description = "Extra environment variables for the bridge service.";
      };
      service = {
        enable = lib.mkOption {
          type        = lib.types.bool;
          default     = true;
          description = "Create a systemd user service on Linux or launchd agent on macOS.";
        };
        startOnBoot = lib.mkOption {
          type        = lib.types.bool;
          default     = true;
          description = "Start the bridge service on user login.";
        };
      };
    };

    bridges = lib.mkOption {
      type        = lib.types.attrsOf bridgeInstanceType;
      default     = {};
      example     = lib.literalExpression ''
        {
          work = { hubUrl = "https://hub.mundus.in"; port = 49333; tokenFile = "~/.config/heimdall/work-bridge-token"; };
          personal = { hubUrl = "https://other-hub.example"; port = 49343; tokenFile = "~/.config/heimdall/personal-bridge-token"; };
        }
      '';
      description = ''
        Additional named ham-bridge services. Each named bridge gets its own
        systemd user service or launchd agent and must use unique bridge/local
        endpoint ports and localRunDir. Wrappers launched by a given bridge are
        started with that bridge's exact --bridge-endpoint, so their liveness and
        notification subscription calls return to the correct bridge.
      '';
    };

    # ── [ctl] ─────────────────────────────────────────────────────────────────

    ctl = {
      enable = lib.mkOption {
        type        = lib.types.bool;
        default     = true;
        description = "Generate the [ctl] section in config.toml.";
      };
      daemonUrl = lib.mkOption {
        type        = lib.types.str;
        default     = "http://127.0.0.1:49322";
        description = "Daemon URL that ham-ctl connects to.";
      };
    };
  };

  # ── Activation ────────────────────────────────────────────────────────────

  config = lib.mkIf cfg.enable (
    {
      assertions = [
        {
          assertion = (lib.length bridgeServicePorts) == (lib.length (lib.unique bridgeServicePorts));
          message = "programs.heimdall bridge services must use unique bridge.port values.";
        }
        {
          assertion = (lib.length bridgeLocalEndpointPorts) == (lib.length (lib.unique bridgeLocalEndpointPorts));
          message = "programs.heimdall bridge services must use unique localEndpointPort values.";
        }
        {
          assertion = (lib.length bridgeLocalRunDirs) == (lib.length (lib.unique bridgeLocalRunDirs));
          message = "programs.heimdall bridge services must use unique localRunDir values.";
        }
      ];

      home.packages =
        (map resolvePackage cfg.packageNames)
        ++ lib.optional anyBridgeEnabled bridgePkg
        ++ lib.optional anyBridgeEnabled ptyHostPkg
        ++ lib.optional anyBridgeEnabled ctlPkg
        ++ lib.optional anyBridgeEnabled hamAgentsPkg
        ++ lib.optional anyBridgeEnabled pkgs.telegraf
        ++ cfg.extraPackages;

      xdg.configFile."heimdall/config.toml".source =
        tomlFormat.generate "heimdall-config.toml" configAttrs;

      home.activation.heimdallBridgeDirs = lib.mkIf anyBridgeEnabled (lib.hm.dag.entryAfter [ "writeBoundary" ] (lib.concatMapStringsSep "\n" (entry: ''
        $DRY_RUN_CMD mkdir -p ${lib.escapeShellArg entry.config.logDir}
        ${lib.optionalString (entry.config.tokenFile != null) "$DRY_RUN_CMD mkdir -p $(dirname ${lib.escapeShellArg entry.config.tokenFile})"}
        $DRY_RUN_CMD mkdir -p ${lib.escapeShellArg entry.config.localRunDir}
      '') enabledBridgeEntries));

      # macOS: home-manager's built-in setupLaunchAgents does an unreliable
      # `launchctl bootout <plist-path>` that frequently fails with
      # "Unrecognized target specifier", leaving the OLD bridge binary running
      # even though the plist now points at the new store path. Reload each
      # enabled bridge agent ourselves — AFTER the plists are written — using the
      # service-target form (gui/<uid>/<label>), waiting for the old service to
      # fully unload, then bootstrap + kickstart so the NEW store path is running.
      # (Mirrors the proven restart pattern used for agent-communicator-web.)
      home.activation.heimdallBridgeReload = lib.mkIf (anyBridgeEnabled && pkgs.stdenv.isDarwin) (
        lib.hm.dag.entryAfter [ "setupLaunchAgents" ] (
          lib.concatMapStringsSep "\n" (entry: ''
            label="${entry.label}"
            domain="gui/$(id -u)"
            service="$domain/$label"
            plist="$HOME/Library/LaunchAgents/$label.plist"
            $VERBOSE_ECHO "heimdall: force-restarting bridge launchd agent $label"
            if [ -f "$plist" ]; then
              # Unload the running (old) service. bootout by target is the reliable
              # spelling; ignore failure (may not be loaded yet).
              $DRY_RUN_CMD /bin/launchctl bootout "$service" >/dev/null 2>&1 || true
              # Wait for launchd to release the label + tear down the old pid.
              for _ in 1 2 3 4 5; do
                if ! /bin/launchctl print "$service" >/dev/null 2>&1; then break; fi
                $DRY_RUN_CMD /bin/sleep 1
              done
              # Load the freshly-written plist (new store path).
              if ! $DRY_RUN_CMD /bin/launchctl bootstrap "$domain" "$plist" >/dev/null 2>&1; then
                $VERBOSE_ECHO "heimdall: bootstrap failed for $service; falling back to kickstart"
              fi
              # Always kickstart to guarantee the new binary is actually running.
              if ! $DRY_RUN_CMD /bin/launchctl kickstart -k "$service" >/dev/null 2>&1; then
                $VERBOSE_ECHO "heimdall: kickstart failed for $service"
              fi
            else
              $VERBOSE_ECHO "heimdall: LaunchAgent plist not found: $plist"
            fi
          '') enabledBridgeServiceEntries
        )
      );

      systemd.user.services = {
      } // builtins.listToAttrs (map (entry: {
        name = entry.serviceName;
        value = {
          Unit = {
            Description = "Heimdall Bridge (${entry.name})";
            After       = [ "network-online.target" ];
          };
          Service = {
            ExecStart   = lib.escapeShellArgs (bridgeCommandArgsFor entry.config);
            Environment = lib.mapAttrsToList (name: value: "${name}=${value}") (bridgeEnvironmentFor entry.config);
            Restart     = "on-failure";
            RestartSec  = "5s";
            KillMode    = "process";
          };
          Install.WantedBy = [ "default.target" ];
        };
      }) enabledBridgeServiceEntries);

      launchd.agents = builtins.listToAttrs (map (entry: {
        name = entry.serviceName;
        value = {
          enable = true;
          config = {
            Label = entry.label;
            ProgramArguments = bridgeCommandArgsFor entry.config;
            EnvironmentVariables = bridgeEnvironmentFor entry.config;
            RunAtLoad = true;
            KeepAlive = { Crashed = true; SuccessfulExit = false; };
            # Like KillMode=process on Linux: the PTY host and the update supervisor
            # must outlive the bridge process instead of dying with its group.
            AbandonProcessGroup = true;
            StandardOutPath = "${entry.config.logDir}/${entry.serviceName}.out.log";
            StandardErrorPath = "${entry.config.logDir}/${entry.serviceName}.err.log";
          };
        };
      }) enabledBridgeServiceEntries);
    }
  );
}
