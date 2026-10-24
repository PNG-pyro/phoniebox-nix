# phoniebox-nix

A NixOS flake for [Phoniebox](https://github.com/MiczFlor/RPi-Jukebox-RFID) (RPi-Jukebox-RFID v3): the RFID jukebox, packaged and configured declaratively. Tap a card, music plays.

It provides:

- **Packages** for the Phoniebox daemon, its web app (built from source), and a few Python dependencies
- **A NixOS module**, `services.phoniebox`, that sets up the daemon, MPD, the web app behind Caddy, and optional extras
- **A patch** against a pinned upstream commit, with bug fixes and new features (summarized below)

Status: a hobby project, in daily use on an Orange Pi Zero 3. Expect rough edges.

## Quick start

Add the flake as an input and import the module:

```nix
{
  inputs.phoniebox.url = "github:YOUR-USERNAME/phoniebox-nix";

  outputs = { nixpkgs, phoniebox, ... }: {
    nixosConfigurations.jukebox = nixpkgs.lib.nixosSystem {
      modules = [
        phoniebox.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

Then in your configuration:

```nix
services.phoniebox = {
  enable = true;
  user = "alice";                # the daemon and MPD run as this user
  openFirewall = true;

  readers.read_00 = {
    module = "generic_nfcpy";    # USB PN532 reader
    settings.device_path = "tty:USB0:pn532";
  };

  audio.primary = {
    sink = "alsa_output.usb-...analog-stereo";   # from `pactl list short sinks`
    alias = "Speakers";
  };
};
```

Open `http://<hostname>/` for the web app.

**Tip:** the web app is plain HTML/JS, identical on every architecture. If you deploy to an ARM or RISC-V board from an x86 machine, build it natively instead of under emulation:

```nix
services.phoniebox.webappPackage = inputs.phoniebox.packages.x86_64-linux.webapp;
```

## Main options

| Option | Purpose |
|---|---|
| `enable`, `user`, `stateDir` | Basics; state (music, cards, settings) lives in `/var/lib/phoniebox` |
| `readers` | RFID readers; generates `rfid.yaml` (e.g. `generic_nfcpy`, `pn532_i2c_py532`) |
| `settings` | Deep-merged into Phoniebox's `jukebox.yaml` on every start |
| `evdev.devices` | Buttons, rotary dials and other input devices |
| `audio.primary`, `audio.secondary` | Output sinks (`sink`, `alias`, optional `volumeLimit`) |
| `audio.startupVolume` | `null` (default) keeps the last volume across reboots |
| `audio.normalize` | Even out loudness between songs (MPD volume normalization) |
| `copyparty.enable` | Web uploads via [copyparty](https://github.com/9001/copyparty), served at `/upload` |
| `display.enable` | SSD1306/SH1106 I2C OLED status display |
| `hotspot.enable` | Setup WiFi hotspot when no known network is in range |
| `webappPackage` | Which web app build to serve |

Settings you want to change from the web app (second-swipe action, max volume, …) should be left unset in Nix, since anything set in `settings` is reapplied on every start.

## What the patch changes

Fixes and additions to upstream Phoniebox v3:

**Daemon**
- PN532 over USB serial (nfcpy): correct device path, tolerate driver mismatches, retry on startup
- Second swipe: works for album and folder cards; a swipe after playback has stopped counts as a first swipe; the setting can be changed from the web app and applies immediately (new "ignore" option)
- Playlists: create, add to, remove from, reorder, rename and delete `.m3u` playlists in a `Playlists/` folder; songs added to a playing playlist are queued too
- Playing a folder skips files MPD can't play instead of failing on the first one
- Folder listings mark unplayable entries and hide dotfiles
- WiFi: show the current network, scan, and connect (via NetworkManager)
- Hotspot control adapted to the module's services

**Web app**
- All requests share one connection, fixing freezes when loading a large library with cover art (upstream opened a new WebSocket per request and never closed them)
- Everything goes through one port: the daemon's WebSockets and copyparty are proxied by Caddy
- Cover art: cached in the browser session, loaded only for albums on screen, retried while the daemon is still extracting it
- Library: Albums / Playlists / Folders switch, playlist view with editing, "add to playlist" everywhere, play buttons on rows, tap-to-open folders
- Settings: WiFi section, working second-swipe selection
- Smaller things: remembers your scroll position, sticky library header, upload link, layout and dialog fixes

**System (via the module)**
- MPD and the daemon as systemd user services, the web app served by Caddy
- OLED status display service, setup hotspot (hostapd + dnsmasq with a captive portal redirect)
- Text-to-speech for "say my IP", shutdown/reboot from the web app

## Hardware

Tested on:

- **Orange Pi Zero 3** (Allwinner H618, vendor kernel) with a USB PN532 reader, USB speakers, an SSD1306 OLED and a SayoDevice E1 dial
- **Raspberry Pi 3** with a Waveshare PN532 HAT over I2C (reader only)

## Known issues

- The shutdown jingle occasionally hangs; a stop timeout keeps shutdown from blocking.
- The hotspot's captive-portal redirect needs VPNs, Private DNS and browser secure DNS turned off on the phone.
- First library load after boot can be slow while the daemon warms up.

## Credits

All the real jukebox work is upstream: [MiczFlor/RPi-Jukebox-RFID](https://github.com/MiczFlor/RPi-Jukebox-RFID) and its contributors. This repo only packages it for NixOS and patches it.

This port was developed with a lot of help from Anthropic's Claude Opus 5.5, which wrote much of the code and patches; I tested, debugged and assembled it on real hardware.

## License

MIT, like upstream. See [LICENSE](LICENSE).
