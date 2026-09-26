# `shader-compile` (`EFX20`, `EFX25`): turns a dub package's single-source D
# shaders into the GLSL `sparkles:ui-raylib` loads. See apps/shader-compile.
#
# Its toolchain is invisible in its dub manifest, because the tool shells out
# to it:
#
#   * `ldc2-vulkan`: dlang.nix's `ldc-vulkan` — LDC with dcompute's Vulkan
#     target and the `@fragment` graphics stage (PetarKirov/ldc
#     `sparkles/vulkan-shaders`), built against LLVM main with the SPIR-V
#     backend — under the name the tool looks for. Stock LDC has neither.
#   * spirv-tools (spirv-val, spirv-opt, spirv-dis), spirv-cross, glslang.
#     Their versions shape the output (an spirv-opt upgrade rewrites a branch),
#     so a build's GLSL is only as reproducible as their pins.
#   * dub, which the tool asks for the package's device configuration.
#
# The wrapper carries all of it, so
#
#     nix run .#shader-compile -- --package=libs/ui --out=libs/ui/generated/shaders
#
# generates the effect GLSL with no devshell and no local compiler build. A
# build does the same by itself (sparkles:ui's `gpu-effects` pre-generate step),
# and Nix builds it once as `.#ui-shaders` (./ui-shaders.nix). Linux and macOS:
# that is where dlang.nix defines `ldc-vulkan`.
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
      # Gate the attrs, not the module: a module whose *shape* depends on an
      # input's package set is infinite recursion in flake-parts.
      available = inputs'.dlang-nix.packages ? ldc-vulkan;
    in
    {
      packages = lib.optionalAttrs available {
        # A symlink, not a wrapper script: LDC finds its `ldc2.conf` (and so
        # the dcompute druntime) from its resolved executable path.
        ldc2-vulkan = pkgs.runCommand "ldc2-vulkan" { meta.mainProgram = "ldc2-vulkan"; } ''
          mkdir -p $out/bin
          ln -s ${lib.getExe' inputs'.dlang-nix.packages.ldc-vulkan "ldc2"} $out/bin/ldc2-vulkan
        '';

        shader-compile = config.legacyPackages.buildSparklesApp (finalAttrs: {
          pname = "shader-compile";
          version = "0.1.0";
          dubBuildType = "checked";

          env = config.legacyPackages.d-toolchain.env;

          postFixup = ''
            wrapProgram $out/bin/${finalAttrs.pname} \
              --prefix PATH : ${
                lib.makeBinPath [
                  config.packages.ldc2-vulkan
                  pkgs.dub
                  pkgs.spirv-tools
                  pkgs.spirv-cross
                  pkgs.glslang
                ]
              }
          '';

          meta = {
            description = "Compile a dub package's single-source D shaders to the GLSL sparkles:ui-raylib loads";
            mainProgram = finalAttrs.pname;
            platforms = lib.platforms.linux ++ lib.platforms.darwin;
          };
        });
      };

      apps = lib.optionalAttrs available {
        shader-compile = {
          type = "app";
          program = lib.getExe config.packages.shader-compile;
        };
      };
    };
}
