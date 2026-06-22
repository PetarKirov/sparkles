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
          (
            final: prev:
            let
              inherit (prev) lib;
              inherit (prev.stdenv) isDarwin;

              cleanLdcConfig = lib.pipe "${prev.ldc}/etc/ldc2.conf" [
                builtins.readFile
                (lib.splitString "\n")
                (lib.filter (line: !(lib.hasInfix "/lib/clang/" line && lib.hasInfix "/lib/darwin" line)))
                lib.concatLines
                (prev.writeText "ldc2-clean.conf")
              ];
            in
            {
              # On Darwin, ldc2.conf ships a lib-dirs entry pointing at a
              # compiler-rt path that does not exist in the Nix store, yielding
              # a spurious `ld: warning: directory not found`. Re-point both
              # drivers at the cleaned config via a wrapper. Because this overlay
              # replaces `pkgs.ldc` package-set-wide, the result must stay a
              # *complete* ldc — dub builds link against `${ldc}/lib`
              # (druntime/phobos) and may invoke `ldmd2` — so we `symlinkJoin`
              # the real package and only wrap the two drivers, rather than
              # substituting a bare `ldc2` shim.
              ldc =
                if isDarwin then
                  prev.symlinkJoin {
                    name = "ldc-${prev.ldc.version}";
                    paths = [ prev.ldc ];
                    nativeBuildInputs = [ prev.makeWrapper ];
                    postBuild = ''
                      for drv in ldc2 ldmd2; do
                        wrapProgram "$out/bin/$drv" --add-flags "-conf=${cleanLdcConfig}"
                      done
                    '';
                    meta = prev.ldc.meta // {
                      mainProgram = "ldc2";
                    };
                  }
                else
                  prev.ldc;

              # Build `dtools` (rdmd, dustmite, …) against the *unwrapped* ldc.
              # Its check phase (`test_rdmd`) copies `ldmd2` into a temp dir and
              # execs it, which trips over the Darwin wrapper above ("Permission
              # denied"), and the tool bundle gains nothing from our cleaned
              # config. A bare `prev.dtools` would not help: nixpkgs `by-name`
              # packages bind `callPackage` to the *final* package set, so
              # `prev.dtools` already resolves `ldc` to the wrapper — the `ldc`
              # argument has to be overridden back to the plain package.
              dtools = prev.dtools.override { ldc = prev.ldc; };

              dmd = inputs'.dlang-nix.packages.dmd-2_112_1;

              dub = inputs'.dlang-nix.packages.dub-1_43_0-alpha-5efed36;
            }
          )
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
