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
    ${lib.optionalString cfg.audio.normalize ''volume_normalization "yes"''}

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

  # copyparty is the upload path, but it knows nothing about MPD - without this the
  # daemon never rescans and uploaded music stays invisible in the web app. The API
  # is loopback-only, so no login is involved even when login.enable is set.
  copypartyRefreshHook = pkgs.writeShellScript "phoniebox-library-refresh" ''
    exec ${pkgs.curl}/bin/curl -fsS -m 30 -X POST \
      http://127.0.0.1:5556/api/v1/library/refresh > /dev/null
  '';

  copypartyConf = pkgs.writeText "copyparty.conf" ''
    [global]
      hist: ${cfg.stateDir}/copyparty-hist
      p: ${toString cfg.copyparty.port}
      no-thumb
      q
      rp-loc: /upload
      lo: ${cfg.stateDir}/copyparty.log
      i: 127.0.0.1,::1
      rproxy: -1
      e2dsa

    [/music]
      ${S}/shared/audiofolders/Music
      accs:
        rwmd: *
      flags:
        # Fire once the volume has been idle a few seconds, so dropping 200 files
        # triggers one rescan rather than 200. f = don't block the upload on it.
        xiu: f,i5,${copypartyRefreshHook}
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
        type = lib.types.nullOr (lib.types.ints.between 0 100);
        default = null;
        description = ''
          Hard ceiling for this output: the 0-100% range is scaled into 0..this.
          Not changeable from the web app. null leaves it to Phoniebox (100).
        '';
      };
    };
  };

  toOutput =
    o:
    lib.filterAttrs (_: v: v != null) {
      inherit (o) alias;
      volume_limit = o.volumeLimit;
      pulse_sink_name = o.sink;
    };

  displayPkg = pkgs.callPackage ../pkgs/phoniebox-display { };
  i2cDevice = "dev-i2c\\x2d${toString cfg.display.bus}.device";

  h = cfg.hotspot;
  hotspotPrefix = lib.concatStringsSep "." (lib.take 3 (lib.splitString "." h.address));
  hotspotFlag = "${S}/hotspot-disabled";

  hostapdConf = pkgs.writeText "hostapd.conf" (
    ''
      interface=${h.interface}
      driver=nl80211
      ssid=${h.ssid}
      hw_mode=g
      channel=${toString h.channel}
    ''
    + lib.optionalString (h.password != null) ''
      wpa=2
      wpa_key_mgmt=WPA-PSK
      rsn_pairwise=CCMP
      wpa_passphrase=${h.password}
    ''
  );

  dnsmasqConf = pkgs.writeText "hotspot-dnsmasq.conf" ''
    interface=${h.interface}
    bind-interfaces
    no-resolv
    # captive portal: every name points at the box
    address=/#/${h.address}
    dhcp-range=${hotspotPrefix}.10,${hotspotPrefix}.50,1h
    dhcp-option=option:router,${h.address}
    dhcp-option=114,"http://${h.address}/captive-portal/api"
    dhcp-authoritative
  '';

  loginDir = "${cfg.stateDir}/login";

  # `sudo phoniebox-set-password` sets or changes the web login; `--off` removes it
  setPassword = pkgs.writeShellApplication {
    name = "phoniebox-set-password";
    runtimeInputs = [
      config.services.caddy.package
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
      if [ "$(id -u)" -ne 0 ]; then
        echo "Run with sudo." >&2
        exit 1
      fi
      file=${loginDir}/login.caddy

      if [ "''${1:-}" = "--off" ]; then
        rm -f "$file"
        systemctl reload caddy
        echo "Login removed: the jukebox is open to everyone on the network."
        exit 0
      fi

      hash=$(caddy hash-password)
      tmp=$(mktemp ${loginDir}/.login.XXXXXX)
      printf 'basic_auth @phoniebox_protected {\n\t%s %s\n}\n' ${lib.escapeShellArg cfg.login.user} "$hash" > "$tmp"
      chown root:${config.services.caddy.group} "$tmp"
      chmod 0640 "$tmp"
      mv "$tmp" "$file"
      systemctl reload caddy
      echo "Login set for user '${cfg.login.user}'."
    '';
  };

in
{
  imports = [
    (lib.mkRemovedOptionModule [ "services" "phoniebox" "copyparty" "accountsFile" ]
      "copyparty now runs without accounts, reachable only through the web app (Caddy); protect it with the web login instead."
    )
  ];

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
      normalize = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Even out loudness between songs (MPD's volume_normalization).
          Adjusts volume while playing; can make quiet intros swell.
        '';
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

    login = {
      enable = lib.mkEnableOption ''
        a login in front of the web app and uploads (HTTP basic auth via Caddy).
        Set the password on the box with `sudo phoniebox-set-password`; until then, no login is asked
      '';
      user = lib.mkOption {
        type = lib.types.str;
        default = "phoniebox";
        description = "Login name.";
      };
    };

    copyparty = {
      enable = lib.mkEnableOption "copyparty web upload for the music folder";
      port = lib.mkOption {
        type = lib.types.port;
        default = 3923;
      };
    };

    display = {
      enable = lib.mkEnableOption "an I2C OLED status display";
      bus = lib.mkOption {
        type = lib.types.int;
        default = 1;
        description = "I2C bus number (/dev/i2c-N).";
      };
      address = lib.mkOption {
        type = lib.types.str;
        default = "0x3C";
      };
      driver = lib.mkOption {
        type = lib.types.enum [
          "ssd1306"
          "sh1106"
        ];
        default = "ssd1306";
      };
      timeout = lib.mkOption {
        type = lib.types.int;
        default = 6;
        description = "Seconds before the screen goes dark.";
      };
    };

    hotspot = {
      enable = lib.mkEnableOption "a setup hotspot when no known WiFi is available";
      interface = lib.mkOption {
        type = lib.types.str;
        default = "wlan0";
      };
      ssid = lib.mkOption {
        type = lib.types.str;
        default = "Phoniebox-Setup";
      };
      password = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "WPA2 password (8+ characters), or null for an open network. Stored in the Nix store.";
      };
      channel = lib.mkOption {
        type = lib.types.int;
        default = 6;
      };
      address = lib.mkOption {
        type = lib.types.str;
        default = "10.42.0.1";
      };
      bootDelay = lib.mkOption {
        type = lib.types.int;
        default = 60;
        description = "Seconds after boot before the first check.";
      };
      checkInterval = lib.mkOption {
        type = lib.types.str;
        default = "5min";
      };
    };

    extraFeatures.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Enable the develop-branch library/card extras beyond plain upstream (playlists,
        podcasts, radio, collection metadata, card labels, ...). Hardware fixes (e.g. the
        PN532 reader patch) always apply regardless of this setting. Off gives you a
        closer-to-upstream `develop` web app and daemon.
      '';
    };

    webappPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../pkgs/phoniebox-webapp {
        phoniebox = cfg.package;
        enableExtraFeatures = cfg.extraFeatures.enable;
      };
      description = "The built web app. Architecture-independent, so an x86-built copy works on any board.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../pkgs/phoniebox {
        readers = readerModules;
        enableExtraFeatures = cfg.extraFeatures.enable;
      };
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
          modules.named.player = lib.mkDefault "player.plugin";
          # Raspberry Pi OS workaround: makes the whole music library world-writable on
          # every start. Not needed on NixOS, where permissions are already right.
          playermpd.library.check_user_rights = lib.mkDefault false;

          # Uses 'sudo iwconfig', which isn't available here; WiFi power saving is
          # better set per host (e.g. networking.networkmanager.wifi.powersave).
          host.wlan_power.disable_power_down = lib.mkDefault false;

          pulse.startup_volume = lib.mkDefault cfg.audio.startupVolume; # null = keep the last volume
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
            ExecStart = "${pkgs.copyparty}/bin/copyparty -c ${copypartyConf}";
            Restart = "on-failure";
          };
        };

        networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall ([
          cfg.webPort
        ]);

        security.sudo.extraRules = [
          {
            users = [ cfg.user ];
            commands = [
              {
                command = "${config.systemd.package}/bin/shutdown";
                options = [ "NOPASSWD" ];
              }
            ];
          }
        ];

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

        systemd.user.services.jukebox-daemon = {
          description = "Phoniebox jukebox daemon";
          wantedBy = [ "default.target" ];
          wants = [ "pipewire-pulse.service" ];
          requires = [ "phoniebox-mpd.service" ];
          after = [
            "phoniebox-mpd.service"
            "pipewire-pulse.service"
            "pipewire.service"
          ];
          unitConfig.ConditionUser = cfg.user;
          environment.PHONIEBOX_STATE = S;
          path = [
            pkgs.coreutils
            pkgs.espeak-ng
            pkgs.yq-go
            config.systemd.package
            "/run/wrappers"
            pkgs.hostname-debian
            pkgs.networkmanager
          ];

          preStart = ''
            mkdir -p ${S}/src/jukebox ${S}/mpd ${S}/shared/{settings,audiofolders,playlists,cover-cache,logs} ${S}/shared/audiofolders/Playlists ${S}/shared/audiofolders/Music ${S}/shared/audiofolders/Radio ${S}/shared/audiofolders/Podcasts

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
            TimeoutStopSec = 10;
          };

        };

        services.pipewire = {
          enable = lib.mkDefault true;
          pulse.enable = lib.mkDefault true;
        };

        services.caddy = {
          enable = true;
          virtualHosts.":${toString cfg.webPort}".extraConfig =
            lib.optionalString cfg.login.enable ''
              @phoniebox_protected not path /captive-portal/*
              import ${loginDir}/*.caddy
            ''
            + lib.optionalString h.enable ''
              @captive {
                remote_ip ${hotspotPrefix}.0/24
                not host ${h.address}
              }
              redir @captive http://${h.address}/ 302

              handle /captive-portal/api {
                header Content-Type application/captive+json
                respond `{"captive": true, "user-portal-url": "http://${h.address}/"}` 200
              }
            ''
            + ''
              handle_path /cover-cache/* {
                root * ${S}/shared/cover-cache
                file_server
              }
              handle_path /logs/* {
                root * ${S}/shared/logs
                file_server browse
              }
              handle /api/* {
                reverse_proxy localhost:5556
              }
            ''
            # Only route /upload when something is actually listening there; otherwise
            # the web app's upload link gets a 502 from a dead proxy instead of a 404.
            + lib.optionalString cfg.copyparty.enable ''
              handle /upload* {
                reverse_proxy localhost:${toString cfg.copyparty.port}
              }
            ''
            + ''
              handle {
                root * ${cfg.webappPackage}
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

      (lib.mkIf (cfg.audio.primary != null) {
        services.phoniebox.settings.pulse.outputs.primary = toOutput cfg.audio.primary;
      })

      (lib.mkIf (cfg.audio.secondary != null) {
        services.phoniebox.settings.pulse.outputs.secondary = toOutput cfg.audio.secondary;
      })

      (lib.mkIf cfg.login.enable {
        environment.systemPackages = [ setPassword ];
        systemd.tmpfiles.rules = [
          "d ${loginDir} 0750 root ${config.services.caddy.group} -"
          # Always at least one file for the import to match, so it never depends
          # on Caddy accepting an import that matches nothing
          "f ${loginDir}/00-empty.caddy 0640 root ${config.services.caddy.group} -"
        ];
      })

      (lib.mkIf cfg.display.enable {
        hardware.i2c.enable = lib.mkDefault true;
        users.users.${cfg.user}.extraGroups = [ "i2c" ];

        # Let systemd track /dev/i2c-* so a service can wait for it
        services.udev.extraRules = ''
          SUBSYSTEM=="i2c-dev", TAG+="systemd"
        '';

        systemd.services.phoniebox-display = {
          description = "Phoniebox OLED status display";
          wantedBy = [ "sysinit.target" ];

          # Start early: only wait for local disks and the I2C bus
          unitConfig.DefaultDependencies = false;
          after = [
            "local-fs.target"
            i2cDevice
          ];
          bindsTo = [ i2cDevice ];

          # Stop late: after the user services (and the daemon) are gone
          before = [
            "user.slice"
            "shutdown.target"
          ];
          conflicts = [ "shutdown.target" ];

          environment = {
            OLED_BUS = toString cfg.display.bus;
            OLED_ADDRESS = cfg.display.address;
            OLED_DRIVER = cfg.display.driver;
            OLED_TIMEOUT = toString cfg.display.timeout;
          };
          path = [ config.systemd.package ]; # for the systemctl shutdown check

          serviceConfig = {
            ExecStart = "${displayPkg}/bin/phoniebox-display";
            User = cfg.user;
            Restart = "always";
            RestartSec = 2;
          };
        };
      })

      (lib.mkIf h.enable {
        systemd.services.autohotspot-ap = {
          description = "Setup hotspot: access point";
          wants = [ "autohotspot-dns.service" ];
          path = [
            pkgs.networkmanager
            pkgs.iproute2
          ];
          preStart = ''
            nmcli device set ${h.interface} managed no || true
            ip addr flush dev ${h.interface}
            ip addr add ${h.address}/24 dev ${h.interface}
            ip link set ${h.interface} up
          '';
          postStop = ''
            ip addr flush dev ${h.interface}
            nmcli device set ${h.interface} managed yes || true
          '';
          serviceConfig = {
            ExecStart = "${pkgs.hostapd}/bin/hostapd ${hostapdConf}";
            Restart = "on-failure";
            RestartSec = 5;
          };
        };

        systemd.services.autohotspot-dns = {
          description = "Setup hotspot: DHCP and captive DNS";
          bindsTo = [ "autohotspot-ap.service" ];
          after = [ "autohotspot-ap.service" ];
          serviceConfig.ExecStart = "${pkgs.dnsmasq}/bin/dnsmasq --keep-in-foreground --conf-file=${dnsmasqConf}";
        };

        # The decision: hotspot or normal WiFi?
        systemd.services.autohotspot = {
          description = "Decide between WiFi client and setup hotspot";
          serviceConfig.Type = "oneshot";
          path = [
            pkgs.networkmanager
            pkgs.iw
            pkgs.gnugrep
            pkgs.coreutils
            config.systemd.package
          ];
          script = ''
            IFACE=${h.interface}
            ap_running() { systemctl is-active --quiet autohotspot-ap.service; }
            connected()  { nmcli -g GENERAL.STATE device show "$IFACE" 2>/dev/null | grep -q '^100'; }
            stations()   { iw dev "$IFACE" station dump 2>/dev/null | grep -c '^Station' || true; }

            # Switched off in the web app: make sure we're a normal client.
            if [ -e ${hotspotFlag} ]; then
              ap_running && systemctl stop autohotspot-ap.service
              exit 0
            fi

            if ap_running; then
              # Someone is on the setup page: don't pull the rug out.
              [ "$(stations)" -gt 0 ] && exit 0
              # Nobody here: give NetworkManager a minute to find a known network.
              systemctl stop autohotspot-ap.service
              for i in $(seq 30); do connected && exit 0; sleep 2; done
              systemctl start autohotspot-ap.service
            else
              connected || systemctl start autohotspot-ap.service
            fi
          '';
        };

        systemd.timers.autohotspot = {
          wantedBy = [ "timers.target" ];
          unitConfig.ConditionPathExists = "!${hotspotFlag}";
          timerConfig = {
            OnBootSec = "${toString h.bootDelay}s";
            OnUnitActiveSec = h.checkInterval;
          };
        };

        # DHCP and DNS for hotspot clients
        networking.firewall.interfaces.${h.interface} = {
          allowedUDPPorts = [
            53
            67
          ];
          allowedTCPPorts = [ 53 ];
        };

        # Let the web app switch control the hotspot (exact commands only)
        security.sudo.extraRules = [
          {
            users = [ cfg.user ];
            commands =
              map
                (args: {
                  command = "${config.systemd.package}/bin/systemctl ${args}";
                  options = [ "NOPASSWD" ];
                })
                [
                  "start autohotspot.timer"
                  "stop autohotspot.timer"
                  "--no-block start autohotspot.service"
                ];
          }
        ];
      })

    ]
  );
}
