# HarfBuzz as sparkles:font's shaping engine pins it (docs/specs/font/SPEC.md
# FTS8): the release and source revision of the `harfbuzz-src` flake input,
# built with nixpkgs' recipe. Its Unicode tables must match base's release;
# 14.5.0 was the first with Unicode 18.0.0.
#
# Every sparkles consumer that links HarfBuzz (the dev shell, app and example
# builds, the Android static library) takes this one, so a process never
# mixes two. Other nixpkgs packages keep nixpkgs' HarfBuzz; it shares the
# soname, and HarfBuzz keeps its ABI backward compatible, so whichever copy
# the loader binds serves both — which is why sparkles:font checks the
# running version, not the one it was built against.
#
# One patch: HarfBuzz stops applying lookups when a run spends its operation
# budget, and in a few places it did so without marking the buffer, returning
# a partial run as shaped. The patch marks it there too, so the shaper reports
# `engineBuffer` (FTB3, FTS7). `passthru.sparklesPatches` hands the patch to
# the Android build, which does not use nixpkgs' recipe.
{ inputs, ... }:
let
  sparklesPatches = [ ./harfbuzz-operation-budget.patch ];
in
{
  perSystem =
    { pkgs, ... }:
    {
      packages.harfbuzz = pkgs.harfbuzz.overrideAttrs (old: {
        version = "14.6.0";
        src = inputs.harfbuzz-src;
        patches = (old.patches or [ ]) ++ sparklesPatches;
        # The hb-gpu demo (new in 14) needs GLEW and GLFW; the library does not.
        mesonFlags = old.mesonFlags ++ [ (pkgs.lib.mesonEnable "gpu_demo" false) ];
        passthru = (old.passthru or { }) // {
          inherit sparklesPatches;
        };
      });
    };
}
