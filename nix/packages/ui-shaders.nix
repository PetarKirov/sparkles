# Generated shaders, built once per package that generates them:
#
#   * `ui-shaders`: sparkles:ui's effect GLSL and SPIR-V;
#   * `vulkan-wsi-shaders`: sparkles:vulkan-wsi's triangle SPIR-V;
#   * `ui-vulkan-shaders`: sparkles:ui-vulkan's canvas SPIR-V.
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
      inherit (config.legacyPackages.sparklesSources) libsClosure;

      # Copies a generated-shaders package, with its `prebuilt` stamp, into
      # `libs/<lib>/generated/shaders/` of the source tree at `rootDir`.
      placeShaders =
        {
          package,
          lib',
          exts,
        }:
        rootDir: ''
          chmod -R u+w "${rootDir}"
          install -d "${rootDir}/libs/${lib'}/generated/shaders"
          cp ${lib.concatMapStringsSep " " (ext: "${package}/*.${ext}") exts} ${package}/.stamp \
            "${rootDir}/libs/${lib'}/generated/shaders/"
        '';

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

          # The tool, and what `dub describe` reads to find the unit: the
          # package's closure (sources and recipes) plus its device-only
          # entry points.
          sourceDirs = [ "apps/shader-compile/src" ] ++ extraDirs ++ libsClosure [ lib' ];
          sourceRoot = "${finalAttrs.src.name}/apps/shader-compile";
          generatesShaders = true;

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
      # Where a build's source tree gets the generated shaders. sparkles:ui's
      # `gpu-effects` configuration generates its effect GLSL in a
      # pre-generate step that takes the dcompute-enabled LDC; Nix runs that
      # once (`ui-shaders`) and every build that reaches the configuration
      # (through `sparkles:ui-raylib`, whose dependents select it) gets the
      # output copied in, so the step finds it fresh and no app build needs
      # LLVM. The step still builds the tool to read the stamp, hence its
      # sources. (The closure is read from the manifests, so it can
      # over-approximate: an unused copy, nothing more.) sparkles:ui-vulkan's
      # canvas SPIR-V likewise, for every build that reaches the native
      # canvas, and sparkles:vulkan-wsi's `gpu-shaders` configuration, which
      # the triangle examples select. Re-exported by `sparklesSources`.
      legacyPackages.uiShaderPlacement = rec {
        # ui-raylib and ui-vulkan both select `gpu-effects`: the GLSL for the
        # one, the SPIR-V for the other.
        needsUiShaders =
          srcDirs: builtins.elem "libs/ui-raylib/src" srcDirs || builtins.elem "libs/ui-vulkan/src" srcDirs;
        needsUiVulkanShaders = srcDirs: builtins.elem "libs/ui-vulkan/src" srcDirs;
        uiShaderDirs =
          srcDirs:
          lib.optional (needsUiShaders srcDirs || needsUiVulkanShaders srcDirs) "apps/shader-compile/src";
        placeUiShaders = placeShaders {
          package = config.packages.ui-shaders;
          lib' = "ui";
          exts = [
            "frag"
            "spv"
          ];
        };
        placeUiVulkanShaders = placeShaders {
          package = config.packages.ui-vulkan-shaders;
          lib' = "ui-vulkan";
          exts = [ "spv" ];
        };
        placeVulkanWsiShaders = placeShaders {
          package = config.packages.vulkan-wsi-shaders;
          lib' = "vulkan-wsi";
          exts = [ "spv" ];
        };
      };

      packages = {
        ui-shaders = prebuiltShaders {
          pname = "ui-shaders";
          lib' = "ui";
          extraDirs = [ "libs/ui/shaders" ];
          description = "sparkles:ui's effect fragment shaders, GLSL and SPIR-V generated from their single-source D";
        };
        vulkan-wsi-shaders = prebuiltShaders {
          pname = "vulkan-wsi-shaders";
          lib' = "vulkan-wsi";
          description = "sparkles:vulkan-wsi's triangle shaders, SPIR-V generated from their D";
        };
        ui-vulkan-shaders = prebuiltShaders {
          pname = "ui-vulkan-shaders";
          lib' = "ui-vulkan";
          extraDirs = [ "libs/ui-vulkan/shaders" ];
          description = "sparkles:ui-vulkan's canvas shaders, SPIR-V generated from their D";
        };
      };
    };
}
