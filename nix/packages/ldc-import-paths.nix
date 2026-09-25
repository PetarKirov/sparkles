# Runtime source import paths for sparkles:dmd-lsp's LDC profiles — the
# dcompute device side of a `@compute` module above all
# (docs/specs/dmd-lsp/feature-requirements.md, TGT3).
#
# A device module imports `ldc.dcompute` and `ldc.intrinsics`, which exist
# only in LDC's druntime — and only the dcompute LDC's (`ldc-vulkan` from
# dlang.nix, PetarKirov/ldc `sparkles/vulkan-shaders`) has the `@fragment`
# stage and `Sampler2D.sample`. This is that compiler's *source* tree, not the
# compiler: evaluating `.src` fetches a checkout and builds nothing, so the
# analysis never pulls in the LLVM the compiler is built against. The devshell
# (and the twoslash-extract wrapper) expose the pair as the colon-separated
# $SPARKLES_LDC_IMPORT_PATH; tests skip when it is unset.
#
# Linux only, like `ldc-vulkan` itself: dlang.nix defines it nowhere else.
{ lib, ... }:
{
  perSystem =
    { inputs', pkgs, ... }:
    let
      # Gate the attrs, not the module (see shader-compile.nix).
      available = inputs'.dlang-nix.packages ? ldc-vulkan;
      ldcSrc = inputs'.dlang-nix.packages.ldc-vulkan.src;
    in
    {
      packages = lib.optionalAttrs available {
        ldc-import-paths = pkgs.linkFarm "sparkles-ldc-import-paths" [
          {
            name = "druntime";
            path = "${ldcSrc}/runtime/druntime/src";
          }
          {
            name = "phobos";
            path = "${ldcSrc}/runtime/phobos";
          }
        ];
      };
    };
}
