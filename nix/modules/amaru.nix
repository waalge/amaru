# Copyright 2026 PRAGMA
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# NixOS module running Amaru as a systemd service.
#
# Instances are keyed by network name (e.g. "mainnet", "preprod", "preview",
# or "testnet_<magic>"), which doubles as both the attribute name and the
# value passed as `AMARU_NETWORK`. Running two instances on the same network
# on one host isn't supported: each instance gets its own state directory,
# unit (`amaru-<network>.service`), and listening port.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.amaru;

  instanceModule = {name, ...}: {
    options = {
      enable = lib.mkEnableOption "this Amaru instance (network ${name})" // {default = true;};

      package = lib.mkOption {
        type = lib.types.package;
        default = cfg.package;
        description = "The `amaru` package providing this instance's binary.";
      };

      dataDir = lib.mkOption {
        type = lib.types.path;
        default = "/var/lib/amaru-${name}";
        description = "Directory holding this instance's ledger and chain databases.";
      };

      listenAddress = lib.mkOption {
        type = lib.types.str;
        default = "0.0.0.0";
        description = "Address to listen on for incoming peer connections.";
      };

      listenPort = lib.mkOption {
        type = lib.types.port;
        default = 3000;
        description = "Port to listen on for incoming peer connections.";
      };

      peers = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = ["relay.example.com:3001"];
        description = "Upstream peer addresses to synchronize from. Defaults to the network's bootstrap peer when empty.";
      };

      # NOTE: paths only; the module does not manage ownership/permissions of the key
      # files themselves (e.g. via systemd's LoadCredential) -- that's on the operator.
      operatorKesFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to the KES signing key, readable by `services.amaru.user`. Together with
          `operatorVrfFile` and `operatorCertFile`, enables block forging. Mainnet refuses
          these; only use on preprod/preview/testnets.
        '';
      };

      operatorVrfFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to the VRF signing key, readable by `services.amaru.user`.";
      };

      operatorCertFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to the operational certificate, readable by `services.amaru.user`.";
      };

      openFirewall = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether to open `listenPort` in the firewall.";
      };

      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = ["--submit-api-listen-on" "127.0.0.1:8090"];
        description = ''
          Extra arguments passed verbatim to `amaru node run`, for anything not already
          exposed as a dedicated option (e.g. `--submit-api-listen-on`, `--peers-mix`,
          `--trace-buffer`, ...). See `amaru node run --help`.
        '';
      };

      extraBootstrapArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = ["--epoch" "500"];
        description = ''
          Extra arguments passed verbatim to the one-time `amaru node bootstrap` run
          (e.g. `--epoch`, `--s3-bucket`, ...). See `amaru node bootstrap --help`.
        '';
      };

      edgeMode = {
        enable = lib.mkEnableOption ''
          periodic chain-store pruning for this instance. On `edgeMode.onCalendar`, stops
          the node, runs the `amaru dev chain prune` maintenance command (which trims chain
          headers older than the oldest kept ledger snapshot), then restarts the node.
          Intended for resource-constrained (edge) deployments that can't keep full chain
          history on disk
        '';

        onCalendar = lib.mkOption {
          type = lib.types.str;
          default = "weekly";
          description = "systemd.time(7) calendar expression controlling how often to prune.";
        };
      };
    };
  };

  enabledInstances = lib.filterAttrs (_: icfg: icfg.enable) cfg.instances;

  mkInstanceServices = name: icfg: let
    dbLedger = "${icfg.dataDir}/ledger.db";
    dbChain = "${icfg.dataDir}/chain.db";

    environment =
      {
        AMARU_NETWORK = name;
        AMARU_DB_LEDGER = dbLedger;
        AMARU_DB_CHAIN = dbChain;
        AMARU_PEERS_LISTEN_ON = "${icfg.listenAddress}:${toString icfg.listenPort}";
      }
      // lib.optionalAttrs (icfg.peers != []) {AMARU_PEER = lib.concatStringsSep "," icfg.peers;}
      // lib.optionalAttrs (icfg.operatorKesFile != null) {AMARU_OPERATOR_KES = icfg.operatorKesFile;}
      // lib.optionalAttrs (icfg.operatorVrfFile != null) {AMARU_OPERATOR_VRF = icfg.operatorVrfFile;}
      // lib.optionalAttrs (icfg.operatorCertFile != null) {AMARU_OPERATOR_CERT = icfg.operatorCertFile;};

    # A directory that exists but is empty isn't a bootstrapped store (`amaru node
    # bootstrap` treats it the same way, and will happily resume into it), so this checks
    # for actual contents rather than mere existence.
    isPopulated = dir: ''[ -d "${dir}" ] && [ -n "$(ls -A "${dir}" 2>/dev/null)" ]'';
    bootstrapIfNeeded = pkgs.writeShellScript "amaru-${name}-bootstrap" ''
      set -euo pipefail
      if ! { ${isPopulated dbLedger} && ${isPopulated dbChain}; }; then
        exec ${icfg.package}/bin/amaru node bootstrap ${lib.escapeShellArgs icfg.extraBootstrapArgs}
      fi
    '';

    # Runs as root (no User=) so it can call `systemctl`; the trap guarantees the node
    # restarts even if the prune step itself fails.
    # NOTE: unconditionally restarts the node afterward, even if an operator had it
    # stopped on purpose for unrelated maintenance when the timer fired.
    pruneCycle = pkgs.writeShellScript "amaru-${name}-prune-cycle" ''
      set -eu
      trap 'systemctl start amaru-${name}.service' EXIT
      systemctl stop amaru-${name}.service
      systemctl start amaru-${name}-prune.service
    '';
  in
    {
      "amaru-${name}" = {
        description = "Amaru Cardano node (${name})";
        documentation = ["https://github.com/pragma-org/amaru"];
        wantedBy = ["multi-user.target"];
        after = ["network-online.target"];
        wants = ["network-online.target"];

        inherit environment;

        serviceConfig = {
          Type = "simple";
          User = cfg.user;
          Group = cfg.group;
          WorkingDirectory = icfg.dataDir;
          ExecStartPre = bootstrapIfNeeded;
          ExecStart = "${icfg.package}/bin/amaru node run ${lib.escapeShellArgs icfg.extraArgs}";
          # Bootstrap (fetching ledger snapshots, etc.) can take far longer than systemd's
          # default 90s start timeout; it and `ExecStart` share this budget.
          TimeoutStartSec = "infinity";
          Restart = "on-failure";
          RestartSec = "5s";

          # Hardening
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ReadWritePaths = [icfg.dataDir];
        };
      };
    }
    // lib.optionalAttrs icfg.edgeMode.enable {
      # Exclusive RocksDB access means this must only ever run while the node is stopped;
      # only `amaru-${name}-prune-cycle.service` is meant to start it.
      "amaru-${name}-prune" = {
        description = "Prune Amaru chain store (${name})";
        documentation = ["https://github.com/pragma-org/amaru"];
        environment = {
          AMARU_NETWORK = name;
          AMARU_DB_LEDGER = dbLedger;
          AMARU_DB_CHAIN = dbChain;
        };
        serviceConfig = {
          Type = "oneshot";
          User = cfg.user;
          Group = cfg.group;
          WorkingDirectory = icfg.dataDir;
          ExecStart = "${icfg.package}/bin/amaru dev chain prune";
        };
      };

      "amaru-${name}-prune-cycle" = {
        description = "Stop, prune, and restart Amaru (${name})";
        documentation = ["https://github.com/pragma-org/amaru"];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pruneCycle}";
        };
      };
    };

  mkInstanceTimers = name: icfg:
    lib.optionalAttrs icfg.edgeMode.enable {
      "amaru-${name}-prune-cycle" = {
        description = "Periodic Amaru chain prune (${name})";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = icfg.edgeMode.onCalendar;
          Persistent = true;
        };
      };
    };
in {
  options.services.amaru = {
    enable = lib.mkEnableOption "Amaru, a Cardano blockchain node";

    package = lib.mkOption {
      type = lib.types.package;
      description = "Default `amaru` package used by instances that don't override it.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "amaru";
      description = "User account under which all Amaru instances run.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "amaru";
      description = "Group under which all Amaru instances run.";
    };

    instances = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule instanceModule);
      default = {};
      description = ''
        Amaru instances to run, keyed by network name (e.g. `mainnet`, `preprod`,
        `preview`, `testnet_42`). Each instance runs as `amaru-<network>.service`,
        with its own state directory and listening port.
      '';
      example = lib.literalExpression ''
        {
          mainnet.listenPort = 3000;
          preprod = {
            listenPort = 3001;
            peers = [ "relay-preprod.example.com:3001" ];
          };
        }
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      description = "Amaru service user";
    };

    users.groups.${cfg.group} = {};

    systemd.tmpfiles.rules =
      lib.mapAttrsToList (_: icfg: "d '${icfg.dataDir}' 0750 ${cfg.user} ${cfg.group} - -") enabledInstances;

    systemd.services = lib.foldl' (a: b: a // b) {} (lib.mapAttrsToList mkInstanceServices enabledInstances);

    systemd.timers = lib.foldl' (a: b: a // b) {} (lib.mapAttrsToList mkInstanceTimers enabledInstances);

    networking.firewall.allowedTCPPorts =
      lib.mapAttrsToList (_: icfg: icfg.listenPort) (lib.filterAttrs (_: icfg: icfg.openFirewall) enabledInstances);
  };
}
