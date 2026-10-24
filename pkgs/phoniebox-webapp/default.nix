{
  buildNpmPackage,
  nodejs_22,
  phoniebox,
}:

buildNpmPackage {
  pname = "phoniebox-webapp";
  version = phoniebox.version;

  # Same pinned source as the daemon, just the web app folder
  src = "${phoniebox.src}/src/webapp";
  nodejs = nodejs_22;

  npmDepsHash = ""; # first build prints the real one

  # Web app patches go here later (paths relative to src/webapp)
  patches = [ ];

  env = {
    CI = "false"; # don't treat lint warnings as errors
    GENERATE_SOURCEMAP = "false"; # smaller output
    DISABLE_ESLINT_PLUGIN = "true"; # faster build
    NODE_OPTIONS = "--max-old-space-size=4096";
  };

  # The build produces a static site; install just that
  installPhase = ''
    runHook preInstall
    cp -r build $out
    runHook postInstall
  '';
}
