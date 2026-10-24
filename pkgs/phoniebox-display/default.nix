{
  stdenvNoCC,
  makeWrapper,
  python3,
}:
let
  py = python3.withPackages (p: [
    (p.callPackage ../luma-oled { })
    p.pyzmq
    p.pillow
  ]);
in
stdenvNoCC.mkDerivation {
  pname = "phoniebox-display";
  version = "0.1";
  src = ./oled-status.py;
  dontUnpack = true;
  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    install -Dm644 $src $out/share/phoniebox-display/oled-status.py
    makeWrapper ${py}/bin/python $out/bin/phoniebox-display \
      --add-flags $out/share/phoniebox-display/oled-status.py
  '';
}
