# The image/video capability probe of docs/research/images/hardware, packaged
# so a contributor can `nix run` it without a D toolchain.
{ lib, ... }:
{
  perSystem =
    { config, pkgs, ... }:
    let
      stamp = config.legacyPackages.mkBuildStamp {
        version = "1";
        withCommit = true;
      };
    in
    {
      packages.media-hw-probe = config.legacyPackages.buildSparklesApp {
        pname = "media-hw-probe";
        version = "1";
        sourceRoot = "source/docs/research/images/hardware/examples";
        sourceDirs =
          config.legacyPackages.sparklesSources.libsClosure [
            "core-cli"
            "vulkan"
            "wired"
          ]
          ++ [ "docs/research/images/hardware/examples" ];
        env = config.legacyPackages.d-toolchain.env;
        nativeBuildInputs = [ pkgs.pkg-config ];
        # `libs/vulkan/src/sparkles/vulkan/vulkan_c.c` enables the Wayland and
        # XCB surface types, so ImportC needs their headers on Linux.
        buildInputs = lib.optionals pkgs.stdenv.isLinux [
          pkgs.wayland.dev
          pkgs.libxcb.dev
        ];
        buildPhase = ''
          runHook preBuild
          # The recipe's `stringImportPaths "."` picks the stamp up; a plain
          # `dub build` has none and reports `dev`.
          cp ${stamp}/sparkles-build-stamp .
          dub build --single media-hw-probe.d --compiler=${lib.getExe' pkgs.ldc "ldc2"} \
            --skip-registry=all --build=checked
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          install -Dm755 build/media-hw-probe $out/bin/media-hw-probe
          runHook postInstall
        '';
        # `adb` for `--adb`, `vainfo` for VA-API on Linux; on macOS the loader
        # is pointed at MoltenVK, the way the dev shell does it.
        postFixup = ''
          wrapProgram $out/bin/media-hw-probe \
            --suffix PATH : ${
              lib.makeBinPath ([ pkgs.android-tools ] ++ lib.optionals pkgs.stdenv.isLinux [ pkgs.libva-utils ])
            } ${lib.optionalString pkgs.stdenv.isDarwin ''
              --set-default VK_DRIVER_FILES ${pkgs.moltenvk}/share/vulkan/icd.d/MoltenVK_icd.json \
              --set-default VK_ICD_FILENAMES ${pkgs.moltenvk}/share/vulkan/icd.d/MoltenVK_icd.json''}
        '';
        meta = {
          description = "Read-only image and video hardware capability probe (JSON)";
          mainProgram = "media-hw-probe";
          platforms = lib.platforms.linux ++ lib.platforms.darwin;
        };
      };
      apps.media-hw-probe = {
        type = "app";
        program = lib.getExe config.packages.media-hw-probe;
      };
    };
}
