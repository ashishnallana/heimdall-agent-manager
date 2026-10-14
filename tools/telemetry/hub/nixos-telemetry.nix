# Heimdall hub telemetry stack for the hub's NixOS host (hub telemetry plan,
# sections 5-6): Prometheus + node_exporter + blackbox_exporter + Grafana
# (OIDC via Authentik, admins only), everything bound to loopback and fronted
# by the existing nginx.
#
# Usage (in your NixOS flake):
#
#   imports = [ "${inputs.heimdall}/tools/telemetry/hub/nixos-telemetry.nix" ];
#   services.heimdall-telemetry = {
#     enable = true;
#     publicUrl = "https://heimdall.mundus.in";      # what blackbox probes
#     grafanaDomain = "grafana.mundus.in";           # nginx vhost (ACME)
#     authentikUrl = "https://auth.mundus.in";        # OIDC issuer host
#     oauthClientId = "grafana";
#     oauthClientSecretFile = "/run/secrets/grafana-oauth-secret";
#     telemetryDir = "${inputs.heimdall}/tools/telemetry/hub";
#   };
#
# and start the hub with `--metrics-addr 127.0.0.1:9464` (see SELF_HOSTING.md).
#
# Authentik side (not expressible here): create group `heimdall-admins`, an
# OAuth2/OpenID provider + application for `https://<grafanaDomain>/login/generic_oauth`
# with the default `profile` scope (it already emits `groups`), and bind a
# group-membership policy to the application so non-admins are rejected at
# Authentik before Grafana ever sees them. Grafana additionally refuses any
# user without the group via role_attribute_strict (defense in depth).
{ config, lib, pkgs, ... }:

let
  cfg = config.services.heimdall-telemetry;
in
{
  options.services.heimdall-telemetry = with lib; {
    enable = mkEnableOption "Prometheus + Grafana telemetry for a Heimdall hub";

    telemetryDir = mkOption {
      type = types.path;
      description = "Path to tools/telemetry/hub from the heimdall checkout (alerts.yml, grafana/).";
    };

    hubMetricsAddr = mkOption {
      type = types.str;
      default = "127.0.0.1:9464";
      description = "Address ham-hub was started with via --metrics-addr.";
    };

    publicUrl = mkOption {
      type = types.str;
      example = "https://heimdall.example.com";
      description = "Public hub origin probed by blackbox_exporter (TLS + nginx + hub up).";
    };

    grafanaDomain = mkOption {
      type = types.str;
      example = "grafana.example.com";
      description = "nginx virtual host for Grafana (ACME + forceSSL).";
    };

    authentikUrl = mkOption {
      type = types.str;
      example = "https://auth.example.com";
      description = "Authentik origin; OIDC endpoints are under /application/o/.";
    };

    authentikSlug = mkOption {
      type = types.str;
      default = "grafana";
      description = "Authentik application slug (used in the end-session URL).";
    };

    oauthClientId = mkOption {
      type = types.str;
      default = "grafana";
    };

    oauthClientSecretFile = mkOption {
      type = types.path;
      description = "File containing the OIDC client secret (read by Grafana at start, never in the store).";
    };

    adminGroup = mkOption {
      type = types.str;
      default = "heimdall-admins";
      description = "Authentik group whose members become Grafana Admins; everyone else is rejected.";
    };

    retentionTime = mkOption { type = types.str; default = "15d"; };
    retentionSize = mkOption { type = types.str; default = "8GB"; };
  };

  config = lib.mkIf cfg.enable {
    # --- Prometheus -------------------------------------------------------
    services.prometheus = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 9090;
      retentionTime = cfg.retentionTime;
      extraFlags = [ "--storage.tsdb.retention.size=${cfg.retentionSize}" ];
      globalConfig = {
        scrape_interval = "15s";
        scrape_timeout = "10s";
        evaluation_interval = "15s";
      };
      ruleFiles = [ "${cfg.telemetryDir}/alerts.yml" ];
      scrapeConfigs = [
        {
          job_name = "heimdall-hub";
          static_configs = [{ targets = [ cfg.hubMetricsAddr ]; }];
        }
        {
          job_name = "node";
          static_configs = [{ targets = [ "127.0.0.1:${toString config.services.prometheus.exporters.node.port}" ]; }];
        }
        {
          job_name = "blackbox";
          metrics_path = "/probe";
          params.module = [ "https_2xx" ];
          static_configs = [{ targets = [ "${cfg.publicUrl}/api/v1/bridges" ]; }];
          relabel_configs = [
            { source_labels = [ "__address__" ]; target_label = "__param_target"; }
            { source_labels = [ "__param_target" ]; target_label = "instance"; }
            { target_label = "__address__"; replacement = "127.0.0.1:${toString config.services.prometheus.exporters.blackbox.port}"; }
          ];
        }
      ];

      exporters.node = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = 9100;
        enabledCollectors = [ "systemd" "processes" ];
      };

      exporters.blackbox = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = 9115;
        configFile = pkgs.writeText "blackbox.yml" (builtins.toJSON {
          modules.https_2xx = {
            prober = "http";
            timeout = "10s";
            http = {
              method = "GET";
              # Unauthenticated API calls return 401 by design; what we assert
              # is TLS, nginx and the hub answering at all.
              valid_status_codes = [ 200 201 204 301 302 401 403 404 ];
              fail_if_not_ssl = true;
              preferred_ip_protocol = "ip4";
            };
          };
        });
      };
    };

    # --- Grafana ------------------------------------------------------------
    services.grafana = {
      enable = true;
      settings = {
        server = {
          http_addr = "127.0.0.1";
          http_port = 3000;
          domain = cfg.grafanaDomain;
          root_url = "https://${cfg.grafanaDomain}/";
        };
        analytics.reporting_enabled = false;
        users.allow_sign_up = false;
        "auth.anonymous".enabled = false;
        "auth.basic".enabled = false;
        auth = {
          disable_login_form = true;
          signout_redirect_url = "${cfg.authentikUrl}/application/o/${cfg.authentikSlug}/end-session/";
        };
        # Plan section 5.2, verbatim: OIDC only, no forward-auth in front.
        "auth.generic_oauth" = {
          enabled = true;
          name = "Authentik";
          allow_sign_up = true;
          client_id = cfg.oauthClientId;
          client_secret = "$__file{${cfg.oauthClientSecretFile}}";
          scopes = "openid email profile";
          auth_url = "${cfg.authentikUrl}/application/o/authorize/";
          token_url = "${cfg.authentikUrl}/application/o/token/";
          api_url = "${cfg.authentikUrl}/application/o/userinfo/";
          login_attribute_path = "preferred_username";
          groups_attribute_path = "groups";
          role_attribute_path = "contains(groups[*], '${cfg.adminGroup}') && 'Admin' || ''";
          role_attribute_strict = true;
          skip_org_role_sync = false;
          use_pkce = true;
        };
      };
      provision = {
        enable = true;
        datasources.path = "${cfg.telemetryDir}/grafana/provisioning/datasources/prometheus.yml";
        dashboards.settings = {
          apiVersion = 1;
          providers = [{
            name = "heimdall";
            folder = "Heimdall";
            type = "file";
            disableDeletion = true;
            allowUiUpdates = false;
            options.path = "${cfg.telemetryDir}/grafana/dashboards";
          }];
        };
      };
    };

    # --- nginx vhost for Grafana (public listener stays loopback) -----------
    services.nginx.virtualHosts.${cfg.grafanaDomain} = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:3000";
        proxyWebsockets = true;
      };
    };
  };
}
