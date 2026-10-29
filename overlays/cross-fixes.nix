# Fixes for cross-compiling Python packages (e.g. to RISC-V).
# Does nothing on native builds.
final: prev:
let
  isCross = prev.stdenv.buildPlatform != prev.stdenv.hostPlatform;
in
{
  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
    (
      pyfinal: pyprev:
      prev.lib.optionalAttrs isCross {
        # CMake >= 4.1 (CMP0190) won't look for Python when cross-compiling without
        # an "emulator". Use the build machine's Python (which reports the target's
        # configuration under nixpkgs' cross hooks), run natively via `env`.
        pyzmq = pyprev.pyzmq.overridePythonAttrs (old: {
          env = (old.env or { }) // {
            CMAKE_ARGS = prev.lib.concatStringsSep " " [
              "-DCMAKE_CROSSCOMPILING_EMULATOR=${prev.buildPackages.coreutils}/bin/env"
              "-DPython_EXECUTABLE=${pyfinal.python.pythonOnBuildForHost.interpreter}"
              "-DPython_INCLUDE_DIR=${pyfinal.python}/include/python${pyfinal.python.pythonVersion}"
            ];
          };
        });
      }
    )
  ];
}
