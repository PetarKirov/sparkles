# `checks.d-compiler-is-fork`: the evidence for toolchain spec TC1 ("one
# compiler fork"). Every application `buildSparklesApp` builds and every
# example must be compiled by an LDC built from dlang.nix's `ldc-vulkan`, the
# PetarKirov/ldc fork the lock pins. Evaluating the check walks those
# derivations' compilers (`passthru.compiler`) and fails, naming the offending
# packages, if any is another one; building it then does nothing.
#
# A compiler is the fork when `ldc-vulkan` is one of its layers: the project's
# `pkgs.ldc` and its `.reproducible` variant (nix/d-toolchain.nix) wrap it as
# `.unwrapped`, `ldc-android` joins it as one of its `paths`, and it wraps its
# own build in turn.
#
# DMD is outside TC1: `ci` puts it on PATH on x86_64-linux as the compiler
# its examples run with, and `twoslash-extract` uses it there to answer dub's
# compiler probe. Both are run-time tools; neither compiles a package here.
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
      fork = inputs'.dlang-nix.packages.ldc-vulkan;

      layers =
        c:
        [ c ]
        ++ lib.optionals (c ? unwrapped) (layers c.unwrapped)
        ++ lib.concatMap layers (builtins.filter lib.isDerivation (c.paths or [ ]));
      isFork = c: builtins.any (l: l.outPath == fork.outPath) (layers c);

      # A package and the derivations it is made from: a stamped app's
      # `unstamped` build, a wrapper's `unwrapped` program.
      parts =
        p:
        [ p ]
        ++
          lib.concatMap (name: lib.optionals (p ? ${name} && lib.isDerivation p.${name}) (parts p.${name}))
            [
              "unstamped"
              "unwrapped"
            ];

      # Every D build reached from the flake's packages and the examples, as
      # `{ name; compiler; }`.
      dBuilds =
        let
          fromPackages = lib.concatLists (
            lib.mapAttrsToList (
              name: p:
              map (part: {
                inherit name;
                inherit (part) compiler;
              }) (builtins.filter (part: part ? compiler) (parts p))
            ) config.packages
          );
          fromExamples = lib.concatLists (
            lib.mapAttrsToList (
              lib': examples:
              lib.mapAttrsToList (example: drv: {
                name = "examples.${lib'}.${example}";
                inherit (drv) compiler;
              }) (lib.filterAttrs (_: lib.isDerivation) examples)
            ) config.legacyPackages.examples
          );
        in
        fromPackages ++ fromExamples;

      offenders = map (b: "${b.name} (${b.compiler.name or "?"})") (
        builtins.filter (b: !isFork b.compiler) dBuilds
      );
    in
    {
      checks.d-compiler-is-fork =
        assert lib.assertMsg (offenders == [ ]) ''
          TC1: these packages are not compiled by the LDC fork (dlang.nix's
          `ldc-vulkan`): ${lib.concatStringsSep ", " offenders}'';
        pkgs.runCommand "d-compiler-is-fork" { } ''
          echo ${toString (builtins.length dBuilds)} D builds use the LDC fork > $out
        '';
    };
}
