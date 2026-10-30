# The independent oracles of the text-conformance harness
# (libs/base/tools/text-conformance): the libraries its opt-in `oracles.sdl`
# recipe binds, and the Python its PyD-embedded Layer 10 runs. Exported as
# `legacyPackages.textOracles` for the dev shell; CI gates the official
# corpora offline without them.
{ inputs, ... }:
{
  perSystem =
    { config, pkgs, ... }:
    let
      # Python (3.11, the newest CPython PyD supports) with jquast wcwidth, for
      # the text-conformance harness Layer 10 (PyD-embedded Python wcwidth oracle).
      # PyD is hard-pinned to 3.11 (dub `subConfiguration "pyd" "python311"`), so
      # this can't reuse another interpreter. To keep the closure to this *single*
      # Python, the ci and pre-commit tooling use `gitMinimal` rather than full
      # git — full git drags in a second CPython via git-p4's shebang.
      wcwidth = pkgs.python311Packages.buildPythonPackage rec {
        pname = "wcwidth";
        version = "0.8.2";
        pyproject = true;

        src = inputs.wcwidth-src;

        build-system = [ pkgs.python311Packages.hatchling ];
        pythonImportsCheck = [ "wcwidth" ];
      };
      pythonEnv = pkgs.python311.withPackages (_: [ wcwidth ]);

      # The harness only calls `ncstrwidth` (Layer 8), which lives in
      # libnotcurses-core. The default `notcurses` links the whole multimedia
      # backend (ffmpeg + audio/video codecs, ~140 MiB of closure) that we never
      # touch — drop it. `.dev` still carries the pkg-config the binding needs.
      notcursesCore = pkgs.notcurses.override { multimediaSupport = false; };
    in
    {
      legacyPackages.textOracles = {
        # utf8proc is single-output (headers + .pc in `out`); icu and
        # notcurses carry their pkg-config in the `.dev` output. The Rust
        # unicode-width helper (Layer 9) is built from the in-tree crate under
        # the harness's oracles/ dir.
        libraries = [
          pkgs.utf8proc
          pkgs.icu
          pkgs.icu.dev
          notcursesCore
          notcursesCore.dev
          config.packages.uwidth-rs
        ];
        # Python + wcwidth for the PyD-embedded Layer 10.
        inherit pythonEnv;
      };
    };
}
