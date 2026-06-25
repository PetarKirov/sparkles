# The project's D toolchain, as a flake-parts module.
#
# For each system it:
#
#   1. Applies a nixpkgs overlay that replaces `ldc`, `dmd` and `dub` with the
#      project-pinned, platform-corrected variants (`_module.args.pkgs`), so
#      *every* consumer — directly and through `buildDubPackage`, whose
#      `dub`/`compiler` default to `pkgs.dub`/`pkgs.ldc` — resolves the same
#      toolchain. That consistency is the whole point: the dev shell, the `ci`
#      package and the example derivations can no longer drift onto a different
#      `dub` or `ldc` than each other.
#
#   2. Derives the dev-shell/packaging metadata (package list, env vars, NOFILE
#      cap) from the overlaid package set and exports it under
#      `legacyPackages.d-toolchain`. Other modules consume it via
#      `config.legacyPackages.d-toolchain.*`.
{ inputs, ... }:
{
  perSystem =
    {
      system,
      inputs',
      pkgs,
      ...
    }:
    {
      _module.args.pkgs = import inputs.nixpkgs {
        inherit system;
        overlays = [
          (final: prev: {
            # The project LDC is the *official upstream release binary*,
            # packaged by dlang.nix — not nixpkgs' source build. Two reasons:
            #
            #   1. The official binaries ship with integrated LLD, so
            #      `-link-internally` works; the win32 cross shell
            #      (nix/shells/win32-cross.nix) cross-links PE executables
            #      with it in one `ldc2` invocation. nixpkgs' ldc is built
            #      without LLD and rejects the flag.
            #   2. It retires the Darwin ldc2.conf cleanup wrapper that the
            #      nixpkgs package needed (its conf shipped a nonexistent
            #      compiler-rt `lib-dirs` entry): the release archive's conf
            #      only references its own relocated prefix.
            #
            # Keep the version in lockstep with `ldcWindowsLibs` in
            # win32-cross.nix — cross-linking mixes this compiler with the
            # Windows druntime/phobos import libs of the same release.
            ldc = inputs'.dlang-nix.packages."ldc-binary-1_41_0";

            # Build `dtools` (rdmd, dustmite, …) against nixpkgs' own ldc,
            # not the dlang.nix release binary above: nixpkgs `by-name`
            # packages bind `callPackage` to the *final* package set, so a
            # bare `prev.dtools` would resolve `ldc` to the overlaid binary,
            # whose derivation layout nixpkgs' dtools build was never tested
            # against — the `ldc` argument is pinned back to the nixpkgs
            # package the recipe was written for.
            dtools = prev.dtools.override { ldc = prev.ldc; };

            dmd = inputs'.dlang-nix.packages.dmd-2_112_1;

            dub = inputs'.dlang-nix.packages.dub-1_43_0-alpha-5efed36;

          })
        ];
      };

      legacyPackages.d-toolchain =
        let
          inherit (pkgs) lib;
          inherit (pkgs.stdenv) isDarwin isx86_64;

          clangUnwrapped = pkgs.clangStdenv.cc.cc;
        in
        {
          packages = [
            pkgs.ldc
            pkgs.dub
            pkgs.dtools
          ]
          ++ lib.optionals (isx86_64) [
            pkgs.dmd
          ];

          env = lib.optionalAttrs isDarwin {
            CC = "${clangUnwrapped}/bin/clang";
            CXX = "${clangUnwrapped}/bin/clang++";
            SDKROOT = "${pkgs.apple-sdk}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk";
            MACOSX_DEPLOYMENT_TARGET = "14.0";
          };

          # Caps open-file limit so D's std.process.fork() child doesn't overflow
          # when casting rlim_cur to int (phobos bug with unlimited NOFILE).
          nofileLimit = 131072;
        };
    };
}
