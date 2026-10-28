# Python with fixes for cross-compiling, shared by every package in this flake.
{
  lib,
  python3,
  buildPackages,
}:
let
  isCross = python3.stdenv.buildPlatform != python3.stdenv.hostPlatform;

  # A command that runs target-platform programs on the build machine
  # (qemu user mode, e.g. qemu-riscv64), as nixpkgs knows it for this target.
  emulator = python3.stdenv.hostPlatform.emulator buildPackages;

  python = python3.override {
    self = python;
    packageOverrides =
      self: super:
      lib.optionalAttrs isCross {
        # CMake >= 4.1 (policy CMP0190) won't search for the target's Python when
        # cross-compiling unless it can run target programs. pyzmq's build asks for
        # it, so give CMake an emulator to run the real target Python with.
        pyzmq = super.pyzmq.overridePythonAttrs (old: {
          env = (old.env or { }) // {
            CMAKE_ARGS = lib.concatStringsSep " " [

              "-DCMAKE_CROSSCOMPILING_EMULATOR=${buildPackages.coreutils}/bin/env"
              "-DPython_EXECUTABLE=${python3.pythonOnBuildForHost.interpreter}"
              # Headers must be the target's, not the build machine's
              "-DPython_INCLUDE_DIR=${python3}/include/python${python3.pythonVersion}"

            ];
          };
        });
      };
  };
in
python
