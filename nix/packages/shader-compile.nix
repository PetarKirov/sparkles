# `shader-compile` (`EFX20`, `EFX25`): turns the repository's single-source D
# shaders into the GLSL `sparkles:ui-raylib` loads. See apps/shader-compile.
#
# Its toolchain is invisible in its dub manifest, because the tool shells out
# to it:
#
#   * `ldc-vulkan` from dlang.nix — LDC with dcompute's Vulkan target and the
#     `@fragment` graphics stage (PetarKirov/ldc `sparkles/vulkan-shaders`),
#     built against LLVM main with the SPIR-V backend. Stock LDC has neither,
#     which is exactly what the tool reports and skips on.
#   * spirv-tools (spirv-val, spirv-opt, spirv-dis), spirv-cross, glslang.
#
# The wrapper carries all of it, so `nix run .#shader-compile` (from the
# repository root — the unit table is repo-relative) regenerates or
# `--verify`s `libs/ui/src/sparkles/ui/shaders/` with no devshell and no local
# compiler build; a caller who exports their own `$SPARKLES_SHADER_LDC` still
# wins. Linux only: that is where dlang.nix defines `ldc-vulkan`.
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
        shader-compile = config.legacyPackages.buildSparklesApp (finalAttrs: {
          pname = "shader-compile";
          version = "0.1.0";
          dubBuildType = "checked";

          env = config.legacyPackages.d-toolchain.env;

          postFixup = ''
            wrapProgram $out/bin/${finalAttrs.pname} \
              --set-default SPARKLES_SHADER_LDC ${lib.getExe' inputs'.dlang-nix.packages.ldc-vulkan "ldc2"} \
              --prefix PATH : ${
                lib.makeBinPath [
                  pkgs.spirv-tools
                  pkgs.spirv-cross
                  pkgs.glslang
                ]
              }
          '';

          meta = {
            description = "Compile the repository's single-source D shaders to the GLSL sparkles:ui-raylib loads";
            mainProgram = finalAttrs.pname;
            platforms = lib.platforms.linux;
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
