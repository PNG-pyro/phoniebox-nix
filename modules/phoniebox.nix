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

  settingsFormat = pkgs.formats.yaml { };
  settingsFile = settingsFormat.generate "jukebox-overrides.yaml" cfg.settings;

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

    settings = lib.mkOption {
      type = settingsFormat.type;
      default = { };
      description = ''
        Keys of jukebox.yaml managed by this module. They are deep-merged into
        the live file on every start; everything else stays as the daemon and
        the web app left it.
      '';
    };
  };

  config = lib.mkIf cfg.enable {

    users.users.${cfg.user} = {
      linger = true;
      extraGroups = [
        "dialout"
        "input"
      ];

      services.phoniebox.settings = {
        webapp.coverart_cache_path = lib.mkDefault "../../shared/cover-cache";
        playermpd.mpd_conf = lib.mkDefault "${S}/mpd.conf";
      };
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
      path = [
        pkgs.coreutils
        pkgs.yq-go
      ];

      preStart = ''
        mkdir -p ${S}/src/jukebox ${S}/mpd ${S}/shared/{settings,audiofolders,playlists,cover-cache,logs}

        # refreshed every start: these point into the store
        ln -sfn ${share}/resources ${S}/resources
        ln -sfn ${mpdConf} ${S}/mpd.conf

        # declarative: always overwritten
        install -m 644 ${rfidYaml} ${S}/shared/settings/rfid.yaml

        J=${S}/shared/settings/jukebox.yaml

        # first start: upstream defaults, untouched
        [ -e "$J" ] || install -m 644 ${share}/resources/default-settings/jukebox.default.yaml "$J"

        # every start: module-managed keys win
        yq -i '. *= load("${settingsFile}")' "$J"
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
