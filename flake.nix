{
  description = "Phoniebox RFID jukebox for NixOS";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-linux"
        "x86_64-linux"
        "riscv64-linux"
      ];
      forAll = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
    in
    {
      packages = forAll (pkgs: rec {
        phoniebox = pkgs.callPackage ./pkgs/phoniebox { };
        default = phoniebox;
        oled-env = pkgs.python3.withPackages (p: [ (p.callPackage ./pkgs/luma-oled { }) ]);
      });
      overlays.default = final: prev: {
        phoniebox = final.callPackage ./pkgs/phoniebox { };
      };
      nixosModules.default = ./modules/phoniebox.nix;
    };
}
