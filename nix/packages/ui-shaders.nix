# Generated shaders, built once per package that generates them:
#
#   * `ui-shaders`: sparkles:ui's effect GLSL;
#   * `vulkan-wsi-shaders`: sparkles:vulkan-wsi's triangle SPIR-V.
#
# Each package's opt-in configuration (`gpu-effects`, `gpu-shaders`)
# generates its shaders at build time (a `preGenerateCommands` step running
# `shader-compile --if-stale`), which takes the dcompute-enabled LDC. Nix
# builds do not repeat that per app: these derivations run the tool once, and
# every build that reaches the configuration gets the output copied into the
# package's `generated/shaders/` with a `prebuilt` stamp
# (`sparklesSources.placeUiShaders`, `placeVulkanWsiShaders`), which the step
# takes as fresh. So no app derivation needs LLVM in its build closure, and
# the Android build — which bypasses dub — string-imports the same files.
#
# Linux and macOS: that is where dlang.nix defines `ldc-vulkan`.
{ lib, ... }:
{
  perSystem =
    {
      config,
      pkgs,
      inputs',
      ...
    }:
    let
      # Gate the attrs, not the module (see ./shader-compile.nix).
      available = inputs'.dlang-nix.packages ? ldc-vulkan;
      inherit (config.legacyPackages.sparklesSources) libsClosure;

      # The output of `shader-compile` for the package `libs/<lib>`, whose
      # device-only entry points (if any) are in `extraDirs`.
      prebuiltShaders =
        {
          pname,
          lib',
          extraDirs ? [ ],
          description,
        }:
        config.legacyPackages.buildSparklesApp (finalAttrs: {
          inherit pname;
          version = "0.1.0";
          dubBuildType = "checked";

          # The tool, and what `dub describe` reads to find the unit: the
          # package's closure (sources and recipes) plus its device-only
          # entry points.
          sourceDirs = [ "apps/shader-compile/src" ] ++ extraDirs ++ libsClosure [ lib' ];
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
            build/shader-compile --package=../../libs/${lib'} --out=$out --quiet
            # Taken as fresh wherever it is copied: the output is this
            # derivation's, not the copy's to re-derive.
            echo prebuilt > $out/.stamp
            runHook postInstall
          '';

          # Generated files only; nothing to scrub, and no compiler reference
          # to assert against.
          disallowedReferences = [ ];

          meta = {
            inherit description;
            platforms = lib.platforms.linux ++ lib.platforms.darwin;
          };
        });
    in
    {
      packages = lib.optionalAttrs available {
        ui-shaders = prebuiltShaders {
          pname = "ui-shaders";
          lib' = "ui";
          extraDirs = [ "libs/ui/shaders" ];
          description = "sparkles:ui's effect fragment shaders, generated from their single-source D";
        };
        vulkan-wsi-shaders = prebuiltShaders {
          pname = "vulkan-wsi-shaders";
          lib' = "vulkan-wsi";
          description = "sparkles:vulkan-wsi's triangle shaders, SPIR-V generated from their D";
        };
      };
    };
}
