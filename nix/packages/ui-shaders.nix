# `ui-shaders`: sparkles:ui's generated effect GLSL, built once.
#
# `sparkles:ui`'s `gpu-effects` configuration generates these at build time
# (a `preGenerateCommands` step running `shader-compile --if-stale`), which
# takes the dcompute-enabled LDC. Nix builds do not repeat that per app:
# this derivation runs the tool once, and every app whose closure reaches
# `sparkles:ui-raylib` gets the output copied into `libs/ui/generated/shaders/`
# with a `prebuilt` stamp (`sparklesSources.placeUiShaders`), which the step
# takes as fresh. So no app derivation needs LLVM in its build closure, and
# the Android build — which bypasses dub — string-imports the same files.
#
# Linux and macOS: that is where dlang.nix defines `ldc-vulkan`.
{ lib, ... }:
{
  perSystem =
    {
      config,
      inputs',
      pkgs,
      ...
    }:
    let
      # Gate the attrs, not the module (see ./shader-compile.nix).
      available = inputs'.dlang-nix.packages ? ldc-vulkan;
      inherit (config.legacyPackages.sparklesSources) libsClosure;
    in
    {
      packages = lib.optionalAttrs available {
        ui-shaders = config.legacyPackages.buildSparklesApp (finalAttrs: {
          pname = "ui-shaders";
          version = "0.1.0";
          dubBuildType = "checked";

          # The tool, and what `dub describe` reads to find the unit: ui's
          # closure (sources and recipes) plus its device-only entry points.
          sourceDirs = [
            "apps/shader-compile/src"
            "libs/ui/shaders"
          ]
          ++ libsClosure [ "ui" ];
          sourceRoot = "${finalAttrs.src.name}/apps/shader-compile";

          env = config.legacyPackages.d-toolchain.env;

          nativeBuildInputs = [
            config.packages.ldc2-vulkan
            pkgs.spirv-tools
            pkgs.spirv-cross
            pkgs.glslang
          ];

          installPhase = ''
            runHook preInstall
            build/shader-compile --package=../../libs/ui --out=$out --quiet
            # Taken as fresh wherever it is copied: the output is this
            # derivation's, not the copy's to re-derive.
            echo prebuilt > $out/.stamp
            runHook postInstall
          '';

          # Text files only; nothing to scrub, and no compiler reference to
          # assert against.
          disallowedReferences = [ ];

          meta = {
            description = "sparkles:ui's effect fragment shaders, generated from their single-source D";
            platforms = lib.platforms.linux ++ lib.platforms.darwin;
          };
        });
      };
    };
}
