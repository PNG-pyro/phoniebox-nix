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

  readerModules = lib.unique (lib.mapAttrsToList (_: r: r.module) cfg.readers);

  rfidYaml = settingsFormat.generate "rfid.yaml" {
    rfid.readers = lib.mapAttrs (
      _: r:
      {
        same_id_delay = 1.0;
        log_ignored_cards = false;
        place_not_swipe = {
          enabled = false;
          card_removal_action.alias = "pause";
        };
      }
      // removeAttrs r [
        "module"
        "settings"
      ] # freeform keys override the defaults
      // {
        inherit (r) module;
        config = r.settings;
      }
    ) cfg.readers;
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

  evdevFile = settingsFormat.generate "evdev.yaml" {
    devices = lib.mapAttrs (_: d: {
      device_name = d.name;
      inherit (d) exact;
      input_devices = lib.mapAttrs (_: b: {
        type = "Button";
        kwargs.key_code = b.key;
        actions.on_press = b.action;
      }) d.buttons;
    }) cfg.evdev.devices;
  };

  hasEvdev = cfg.evdev.devices != { };

  outputType = lib.types.submodule {
    options = {
      sink = lib.mkOption {
        type = lib.types.str;
        description = "PipeWire/Pulse sink name, from `pactl list short sinks`.";
      };
      alias = lib.mkOption {
        type = lib.types.str;
        default = "Speakers";
      };
      volumeLimit = lib.mkOption {
        type = lib.types.ints.between 0 100;
        default = 100;
        description = "Hard ceiling: the 0-100% range is scaled into 0..this. Not changeable from the web app.";
      };
      softMaxVolume = lib.mkOption {
        type = lib.types.ints.between 0 100;
        default = 100;
        description = "Soft cap that can be changed temporarily from the web app.";
      };
    };
  };

  toOutput = o: {
    inherit (o) alias;
    volume_limit = o.volumeLimit;
    soft_max_volume = o.softMaxVolume;
    pulse_sink_name = o.sink;
  };

in
{
  options.services.phoniebox = {

    enable = lib.mkEnableOption "Phoniebox RFID jukebox";
    user = lib.mkOption { type = lib.types.str; };

    audio = {
      startupVolume = lib.mkOption {
        type = lib.types.nullOr (lib.types.ints.between 0 100);
        default = null;
      };
      primary = lib.mkOption {
        type = lib.types.nullOr outputType;
        default = null;
      };
      secondary = lib.mkOption {
        type = lib.types.nullOr outputType;
        default = null;
      };
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/phoniebox";
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
        default = "${cfg.stateDir}/copyparty-accounts.conf";
        description = "copyparty config file with an [accounts] section. Keep it out of the Nix store.";
      };
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../pkgs/phoniebox { readers = readerModules; };
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

    evdev.devices = lib.mkOption {
      default = { };
      description = "USB input devices (dials, keypads, arcade encoders) and their button mappings.";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Device name as shown by evtest.";
            };
            exact = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Require an exact name match (safer when one device exposes several inputs).";
            };
            buttons = lib.mkOption {
              default = { };
              type = lib.types.attrsOf (
                lib.types.submodule {
                  options = {
                    key = lib.mkOption {
                      type = lib.types.int;
                      description = "evdev key code, e.g. 115 for KEY_VOLUMEUP.";
                    };
                    action = lib.mkOption {
                      type = settingsFormat.type;
                      description = "RPC command, e.g. { alias = \"toggle\"; }.";
                    };
                  };
                }
              );
            };
          };
        }
      );
    };

    readers = lib.mkOption {
      description = "RFID readers, written to rfid.yaml. Attribute names become reader IDs.";
      default = {
        read_00 = {
          module = "generic_nfcpy";
          settings.device_path = "tty:USB0:pn532";
        };
      };
      type = lib.types.attrsOf (
        lib.types.submodule {
          freeformType = settingsFormat.type; # passes through same_id_delay etc.
          options = {
            module = lib.mkOption {
              type = lib.types.enum [
                "generic_nfcpy"
                "generic_usb"
                "rdm6300_serial"
                "pn532_i2c_py532"
              ];
            };
            settings = lib.mkOption {
              type = settingsFormat.type;
              default = { };
              description = "Reader-specific options (the 'config' block in rfid.yaml).";
            };
          };
        }
      );
    };

  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {

        users.users.${cfg.user} = {
          linger = true;
          extraGroups =
            lib.optional (
              lib.elem "generic_nfcpy" readerModules || lib.elem "rdm6300_serial" readerModules
            ) "dialout"
            ++ lib.optional (lib.elem "generic_usb" readerModules) "input"
            ++ lib.optional (lib.elem "pn532_i2c_py532" readerModules) "i2c";
        };

        hardware.i2c.enable = lib.mkIf (lib.elem "pn532_i2c_py532" readerModules) (lib.mkDefault true);

        services.phoniebox.settings = {
          webapp.coverart_cache_path = lib.mkDefault "../../shared/cover-cache";
          playermpd.mpd_conf = lib.mkDefault "${S}/mpd.conf";
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

            ${lib.optionalString hasEvdev "install -m 644 ${evdevFile} ${S}/shared/settings/evdev.yaml"}

            # first start: upstream defaults, untouched
            J=${S}/shared/settings/jukebox.yaml

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

        services.pipewire = {
          enable = lib.mkDefault true;
          pulse.enable = lib.mkDefault true;
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

      }

      (lib.mkIf hasEvdev {
        users.users.${cfg.user}.extraGroups = [ "input" ];
        services.phoniebox.settings = {
          modules.named.event_devices = "controls.event_devices";
          evdev = {
            enable = true; # 'enable', not 'enabled' (the docs are wrong)
            config_file = "../../shared/settings/evdev.yaml";
          };
        };
      })

      (lib.mkIf (cfg.audio.startupVolume != null) {
        services.phoniebox.settings.pulse.startup_volume = cfg.audio.startupVolume;
      })

      (lib.mkIf (cfg.audio.primary != null) {
        services.phoniebox.settings.pulse.outputs.primary = toOutput cfg.audio.primary;
      })

      (lib.mkIf (cfg.audio.secondary != null) {
        services.phoniebox.settings.pulse.outputs.secondary = toOutput cfg.audio.secondary;
      })

    ]
  );
}
