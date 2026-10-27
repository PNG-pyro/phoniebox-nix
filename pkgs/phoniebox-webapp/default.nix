{
  buildNpmPackage,
  nodejs_22,
  phoniebox,
  lib,
  # See pkgs/phoniebox's enableExtraFeatures - same switch, kept independent here
  # since the webapp is built/consumed separately.
  enableExtraFeatures ? true,
}:

buildNpmPackage {
  pname = "phoniebox-webapp";
  version = phoniebox.version;

  # Same pinned source as the daemon, just the web app folder
  src = "${phoniebox.src}/src/webapp";
  nodejs = nodejs_22;

  npmDepsHash = "sha256-ewiwTnesYolBWgtAa6pVTUi9PlJA/HymfaiIlURWey0="; # first build prints the real one

  # Web app patches (paths relative to src/webapp) - all of these are the develop-branch
  # library/card extras, none are upstream bug/hardware fixes, so the whole list is gated.
  patches = lib.optionals enableExtraFeatures [
    ../../patches/scroll-memory.patch
    ../../patches/lazy-covers.patch
    ../../patches/floating-back-button.patch
    ../../patches/playlists-view-webapp.patch
    ../../patches/playlist-root-boundary.patch
    ../../patches/playlist-actions.patch
    ../../patches/playlist-expanded-view.patch
    ../../patches/playlist-create-m3u.patch
    ../../patches/playlist-icons-and-empty-message.patch
    ../../patches/collection-kind-refactor.patch
    ../../patches/podcasts-collection-support.patch
    ../../patches/radio-collection-support.patch
    ../../patches/compact-view-tabs.patch
    ../../patches/responsive-view-tabs.patch
    ../../patches/view-tabs-title-row.patch
    ../../patches/add-collection-entry-webapp.patch
    ../../patches/collection-view-metadata-webapp.patch
    ../../patches/card-labels-webapp.patch
    ../../patches/add-to-playlist-webapp.patch
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
