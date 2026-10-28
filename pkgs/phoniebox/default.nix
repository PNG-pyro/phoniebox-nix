{
  stdenvNoCC,
  fetchFromGitHub,
  fetchzip,
  applyPatches,
  makeWrapper,
  callPackage,
  zeromq,
  lib,
  readers ? [ "generic_nfcpy" ],
  # Turns off everything beyond the reader fix - the develop-branch library/card
  # features that aren't plain upstream. On by default so existing deployments
  # (and the flake's own package outputs) are unaffected.
  enableExtraFeatures ? true,
}:

let

  rev = "0d9d70fdf44a53c42ff3617d14ae7e5d1fdba9ac"; # your existing pin
  upstreamVersion = "3.6.0";

  readerDeps = p: {
    generic_nfcpy = [ p.nfcpy ];
    generic_usb = [ ];
    rdm6300_serial = [ p.pyserial ];
    pn532_i2c_py532 = [ (p.callPackage ../py532lib { }) ];
  };

  patchedSrc = applyPatches {
    name = "phoniebox-source";
    src = fetchFromGitHub {
      owner = "MiczFlor";
      repo = "RPi-Jukebox-RFID";
      inherit rev;
      hash = "sha256-KnXh5fiV3RzRRWvQoGTomm7DW1Qzxld0UrGxb4pHrlw=";
    };
    patches = [
      ../../patches/reader.patch
    ]
    ++ lib.optionals enableExtraFeatures [
      ../../patches/playlists-view-daemon.patch
      ../../patches/podcasts-view-daemon.patch
      ../../patches/hide-dotfiles-in-collections.patch
      ../../patches/radio-view-daemon.patch
      ../../patches/add-collection-entry-daemon.patch
      ../../patches/collection-view-metadata-daemon.patch
      ../../patches/card-labels-daemon.patch
      ../../patches/add-to-playlist-daemon.patch
    ];
  };

  python = callPackage ../shared/python.nix { };

  py = python.withPackages (
    p:
    with p;
    [
      pyzmq
      evdev
      mutagen
      pyalsaaudio
      pulsectl
      mpd2
      ruamel-yaml
      requests
      tornado
      paho-mqtt
    ]
    ++ lib.concatMap (
      r: (readerDeps p).${r} or (throw "phoniebox: no packaging for reader module '${r}' yet")
    ) readers
  );
in

stdenvNoCC.mkDerivation {
  pname = "phoniebox";
  version = "3-unstable";

  # src = fetchFromGitHub {
  #   owner = "MiczFlor";
  #   repo = "RPi-Jukebox-RFID";
  #   inherit rev;
  #   hash = "sha256-mRTTY/R4Bh9zlsejxJjNt/bgdS3YiySUFg7f2Z6gKuM="; # same as your dev flake
  # };

  src = patchedSrc;
  nativeBuildInputs = [ makeWrapper ];
  dontBuild = true;

  installPhase = ''
    share=$out/share/phoniebox
    mkdir -p $share/src $share/shared/settings
    cp -r src/jukebox $share/src/
    ${py}/bin/python -m compileall -q $share/src/jukebox
    cp -r resources $share/
    cp resources/default-settings/logger.default.yaml $share/shared/settings/logger.yaml

    makeWrapper ${py}/bin/python $out/bin/phoniebox-daemon \
      --run 'cd "''${PHONIEBOX_STATE:-/var/lib/phoniebox}/src/jukebox"' \
      --add-flags "$share/src/jukebox/run_jukebox.py" \
      --add-flags "-c ../../shared/settings/jukebox.yaml"
  '';

  passthru.webapp = fetchzip {
    url = "https://github.com/MiczFlor/RPi-Jukebox-RFID/releases/download/v${upstreamVersion}/webapp-build-${builtins.substring 0 10 rev}.tar.gz";
    hash = "sha256-ZzTv1bClQ9P7QML2qdVSwDmONzAPwZFsMRXPmB+Lqa4="; # first build prints the real one
  };
}
