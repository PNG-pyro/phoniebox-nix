{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.phoniebox;
  pkg = cfg.package;
  share = "${pkg}/share/phoniebox";
  S = cfg.stateDir;

  mpdConf = pkgs.writeText "phoniebox-mpd.conf" ''
    music_directory    "${S}/shared/audiofolders"
    playlist_directory "${S}/shared/playlists"
    db_file            "${S}/mpd/database"
    state_file         "${S}/mpd/state"
    bind_to_address    "localhost"
    port               "6600"
    auto_update        "yes"

    audio_output {
      type "pulse"
      name "Pulse"
    }
  '';

  # upstream defaults, with our two path fixes applied
  jukeboxDefault = pkgs.runCommand "jukebox.yaml" { } ''
    sed -e 's|../../src/webapp/build/cover-cache|../../shared/cover-cache|' \
        -e 's|~/.config/mpd/mpd.conf|${S}/mpd.conf|' \
        ${share}/resources/default-settings/jukebox.default.yaml > $out
  '';

  rfidYaml = (pkgs.formats.yaml { }).generate "rfid.yaml" {
    rfid.readers.read_00 = {
      module = "generic_nfcpy";
      config.device_path = cfg.readerDevice;
      same_id_delay = 1.0;
      log_ignored_cards = false;
      place_not_swipe = {
        enabled = false;
        card_removal_action.alias = "pause";
      };
    };
  };

  copypartyConf = pkgs.writeText "copyparty.conf" ''
    [global]
      p: ${toString cfg.copyparty.port}
      no-thumb
      q

    [/music]
      ${S}/shared/audiofolders
      accs:
        rwmd: ${cfg.user}
  '';

in
{
  options.services.phoniebox = {
    enable = lib.mkEnableOption "Phoniebox RFID jukebox";
    user = lib.mkOption { type = lib.types.str; };
    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/phoniebox";
    };
    readerDevice = lib.mkOption {
      type = lib.types.str;
      default = "tty:USB0:pn532";
    };
    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    webPort = lib.mkOption {
      type = lib.types.port;
      default = 80;
    };
    copyparty = {
      enable = lib.mkEnableOption "copyparty web upload for the music folder";
      port = lib.mkOption {
        type = lib.types.port;
        default = 3923;
      };
      accountsFile = lib.mkOption {
        type = lib.types.str;
        description = "copyparty config file with an [accounts] section. Keep it out of the Nix store.";
      };
    };
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../pkgs/phoniebox { };
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.user} = {
      linger = true;
      extraGroups = [
        "dialout"
        "input"
      ];
    };

    # /var/lib isn't writable by users, so create the top folder as root
    systemd.tmpfiles.rules = [
      "d ${S} 0755 ${cfg.user} ${config.users.users.${cfg.user}.group} -"
    ];

    systemd.user.services.phoniebox-upload = lib.mkIf cfg.copyparty.enable {
      description = "copyparty upload for Phoniebox";
      wantedBy = [ "default.target" ];
      unitConfig.ConditionUser = cfg.user;
      serviceConfig = {
        ExecStart = "${pkgs.copyparty}/bin/copyparty -c ${copypartyConf} -c ${cfg.copyparty.accountsFile}";
        Restart = "on-failure";
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall (
      [
        cfg.webPort
        5556
        5557
      ]
      ++ lib.optional cfg.copyparty.enable cfg.copyparty.port
    );

    systemd.user.services.phoniebox-mpd = {
      description = "MPD for Phoniebox";
      wantedBy = [ "default.target" ];
      wants = [ "pipewire-pulse.service" ];
      after = [ "pipewire-pulse.service" ];
      unitConfig.ConditionUser = cfg.user;
      serviceConfig = {
        ExecStart = "${pkgs.mpd}/bin/mpd --no-daemon --stderr ${mpdConf}";
        Restart = "on-failure";
      };
    };

    systemd.user.services.phoniebox = {
      description = "Phoniebox jukebox daemon";
      wantedBy = [ "default.target" ];
      wants = [ "pipewire-pulse.service" ];
      requires = [ "phoniebox-mpd.service" ];
      after = [
        "phoniebox-mpd.service"
        "pipewire-pulse.service"
      ];
      unitConfig.ConditionUser = cfg.user;
      environment.PHONIEBOX_STATE = S;
      path = [ pkgs.coreutils ];

      preStart = ''
        mkdir -p ${S}/src/jukebox ${S}/mpd ${S}/shared/{settings,audiofolders,playlists,cover-cache,logs}

        # refreshed every start: these point into the store
        ln -sfn ${share}/resources ${S}/resources
        ln -sfn ${mpdConf} ${S}/mpd.conf

        # declarative: always overwritten
        install -m 644 ${rfidYaml} ${S}/shared/settings/rfid.yaml

        # seeded once, then owned by the daemon
        [ -e ${S}/shared/settings/jukebox.yaml ] || install -m 644 ${jukeboxDefault} ${S}/shared/settings/jukebox.yaml
      '';

      serviceConfig = {
        ExecStart = "${pkg}/bin/phoniebox-daemon";
        Restart = "always";
        RestartSec = 5;
      };

    };

    services.caddy = {
      enable = true;
      virtualHosts.":${toString cfg.webPort}".extraConfig = ''
        handle_path /cover-cache/* {
          root * ${S}/shared/cover-cache
          file_server
        }
        handle_path /logs/* {
          root * ${S}/shared/logs
          file_server browse
        }
        handle {
          root * ${pkg.webapp}
          file_server
        }
      '';
    };

    services.phoniebox.copyparty = {
      enable = true;
      accountsFile = "/var/lib/phoniebox/copyparty-accounts.conf";
    };

  };
}
