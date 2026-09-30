# Standalone core-cli collector, built with the shared D dependency lock.
{ lib, ... }:
{
  perSystem =
    { config, pkgs, ... }:
    {
      packages.android-dev-env-probe = config.legacyPackages.buildSparklesApp {
        pname = "android-dev-env-probe";
        version = "0.1.0";
        sourceRoot = "source/docs/research/android-dev-env/device-validation/examples";
        sourceDirs = config.legacyPackages.sparklesSources.libsClosure [ "core-cli" ] ++ [
          "docs/research/android-dev-env/device-validation/examples"
        ];
        env = config.legacyPackages.d-toolchain.env;
        buildPhase = ''
          runHook preBuild
          dub build --single contributor-probe.d --compiler=${lib.getExe' pkgs.ldc "ldc2"} \
            --skip-registry=all --build=checked
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          install -Dm755 build/android-dev-env-probe $out/bin/android-dev-env-probe
          runHook postInstall
        '';
        postFixup = ''
          wrapProgram $out/bin/android-dev-env-probe --prefix PATH : ${
            lib.makeBinPath [
              pkgs.android-tools
              pkgs.coreutils
            ]
          }
        '';
        meta = {
          description = "Read-only Android AVF and native Nix store evidence collector";
          mainProgram = "android-dev-env-probe";
          platforms = lib.platforms.linux ++ lib.platforms.darwin;
        };
      };
      apps.android-dev-env-probe = {
        type = "app";
        program = lib.getExe config.packages.android-dev-env-probe;
      };
    };
}
