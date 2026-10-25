{
  buildNpmPackage,
  nodejs_22,
  phoniebox,
  lib,
}:

buildNpmPackage {
  pname = "phoniebox-webapp";
  version = phoniebox.version;

  # Same pinned source as the daemon, just the web app folder
  src = "${phoniebox.src}/src/webapp";
  nodejs = nodejs_22;

  npmDepsHash = "sha256-ewiwTnesYolBWgtAa6pVTUi9PlJA/HymfaiIlURWey0="; # first build prints the real one

  # Web app patches go here later (paths relative to src/webapp)
  patches = [
    ../../patches/scroll-memory.patch
    ../../patches/lazy-covers.patch
    ../../patches/floating-back-button.patch
    ../../patches/playlists-view-webapp.patch
    ../../patches/playlist-root-boundary.patch
    ../../patches/playlist-actions.patch
    ../../patches/playlist-expanded-view.patch
  ];

  env = {
    NODE_OPTIONS = "--max-old-space-size=4096";
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
  };

  # env = {
  #   CI = "false"; # don't treat lint warnings as errors
  #   GENERATE_SOURCEMAP = "false"; # smaller output
  #   DISABLE_ESLINT_PLUGIN = "true"; # faster build
  #   NODE_OPTIONS = "--max-old-space-size=4096";
  # };

  # The build produces a static site; install just that
  installPhase = ''
    runHook preInstall
    cp -r build $out
    runHook postInstall
  '';
}
