{
  stdenvNoCC,
  fetchFromGitHub,
  fetchzip,
  makeWrapper,
  python3,
  zeromq,
  readers ? [ "generic_nfcpy" ],
}:
let

  readerDeps = p: {
    generic_nfcpy = [ p.nfcpy ];
    generic_usb = [ ];
    rdm6300_serial = [ p.pyserial ];
  };

  py = python3.withPackages (
    p:
    [
      # your pyzmq override and core packages, minus nfcpy
    ]
    ++ lib.concatMap (
      r: (readerDeps p).${r} or (throw "phoniebox: no packaging for reader module '${r}' yet")
    ) readers
  );

  rev = "4fa84fd50750fd4b52984d51aa7c95466cf5b241"; # your existing pin
  upstreamVersion = "3.6.0";

  zeromqDrafts = zeromq.override { enableDrafts = true; };

  py = python3.withPackages (
    p: with p; [
      ((pyzmq.override { zeromq = zeromqDrafts; }).overridePythonAttrs (old: {
        env = (old.env or { }) // {
          ZMQ_DRAFT_API = "1";
        };
        doCheck = false;
      }))
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
  );
in
stdenvNoCC.mkDerivation {
  pname = "phoniebox";
  version = "3-unstable";

  src = fetchFromGitHub {
    owner = "MiczFlor";
    repo = "RPi-Jukebox-RFID";
    inherit rev;
    hash = "sha256-mRTTY/R4Bh9zlsejxJjNt/bgdS3YiySUFg7f2Z6gKuM="; # same as your dev flake
  };

  patches = [ ./generic_nfcpy-fixes.patch ];
  nativeBuildInputs = [ makeWrapper ];
  dontBuild = true;

  installPhase = ''
    share=$out/share/phoniebox
    mkdir -p $share/src $share/shared/settings
    cp -r src/jukebox $share/src/
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
