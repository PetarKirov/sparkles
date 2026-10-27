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
              inherit (prev.stdenv.hostPlatform) isDarwin;

              # dlang.nix's `ldc-vulkan`: the PetarKirov/ldc fork that also
              # compiles the shaders (dcompute's Vulkan target) and, as
              # `ldc-sparkles`, the wasm modules (nix/packages/build-d-wasm-module.nix).
              # One compiler and one LLVM for the host, the shaders and WASI.
              # The WASI runtime and sysroot stay out of this package's closure:
              # only the wasm builds need them.
              rawLdc = inputs'.dlang-nix.packages.ldc-vulkan;

              # The compiler's own `ldc2.conf/` drop-ins without dlang.nix's
              # `50-nix.conf`: its `-link-defaultlib-shared` breaks standalone
              # binaries once `buildDubPackage` scrubs compiler references. What
              # remains links druntime/Phobos statically, and keeps upstream's
              # wasm sections (bare `wasm32-unknown-unknown` for `--wasm` tests).
              cleanLdcConfig = prev.runCommand "ldc2.conf" { } ''
                mkdir $out
                for f in ${rawLdc}/etc/ldc2.conf/*; do
                  [ "$(basename "$f")" = 50-nix.conf ] || cp -L "$f" $out/
                done
              '';

            in
            {
              # dlang.nix defaults to `-link-defaultlib-shared` in its ldc2.conf,
              # which breaks standalone binaries when `buildDubPackage` scrubs
              # compiler references. Re-point drivers at `cleanLdcConfig` (static
              # defaultlibs).
              # Because this overlay replaces `pkgs.ldc` package-set-wide, the
              # result must stay a *complete* ldc — dub builds link against
              # `${ldc}/lib` (druntime/phobos) and may invoke `ldmd2` — so we
              # `symlinkJoin` the real package and only wrap the two drivers,
              # rather than substituting a bare `ldc2` shim.
              ldc = prev.symlinkJoin {
                name = "ldc-${rawLdc.version}";
                paths = [ rawLdc ];
                nativeBuildInputs = [ prev.makeWrapper ];
                postBuild = ''
                  for drv in ldc2 ldmd2; do
                    wrapProgram "$out/bin/$drv" --add-flags "-conf=${cleanLdcConfig}"
                  done
                '';
                passthru =
                  lib.optionalAttrs (rawLdc ? include) {
                    inherit (rawLdc) include;
                  }
                  // {
                    # The package this joins over. Consumers scrubbing compiler
                    # paths out of a built binary need it: druntime bakes
                    # `__FILE__` strings naming *this* store path into every
                    # assert, and scrubbing the join is scrubbing the wrong one.
                    unwrapped = rawLdc;
                  };
                meta = rawLdc.meta // {
                  mainProgram = "ldc2";
                };
              };

              # Build `dtools` (rdmd, dustmite, …) against the *unwrapped* ldc.
              # Its check phase (`test_rdmd`) copies `ldmd2` into a temp dir and
              # execs it, which trips over the driver wrapper above ("Permission
              # denied"), and the tool bundle gains nothing from our cleaned
              # config. A bare `prev.dtools` would not help: nixpkgs `by-name`
              # packages bind `callPackage` to the *final* package set, so
              # `prev.dtools` already resolves `ldc` to the wrapper — the `ldc`
              # argument has to be overridden back to the plain package.
              #
              # Even against the plain ldc, `test_rdmd` fails on the Darwin
              # runners since dlang.nix 028a93e (`stat /private/tmp/ldmd2`):
              # the copied compiler is never found. The check tests rdmd's
              # compiler discovery, not the tools we use, so it is skipped
              # there; Linux still runs it.
              dtools = (prev.dtools.override { ldc = rawLdc; }).overrideAttrs {
                doCheck = !isDarwin;
              };

              dmd = inputs'.dlang-nix.packages.dmd-2_112_1;

              dub = inputs'.dlang-nix.packages.dub-1_43_0-alpha-5efed36;

              # GNOME/Adwaita dropped XCursor files. Stock GLFW 3.5.1 still
              # uploads pixmap cursors, so hue's ew/ns resize shapes fail.
              # inputs.glfw — glfw#2679 rewritten on 3.5.1. The fix is
              # Wayland's, so only Linux raylib gets it: a global `glfw3`
              # override would rebuild every other GLFW consumer too.
              #
              # nixpkgs' raylib has one output, so the library shares a store
              # path with its CMake package files, and on macOS those name the
              # Apple SDK, whose tools wrap clang: every program loading
              # `libraylib.dylib` carried the C toolchain (TC13). A `dev`
              # output takes the headers, CMake and pkg-config files.
              raylib =
                (
                  if isDarwin then
                    prev.raylib
                  else
                    prev.raylib.override {
                      glfw = prev.glfw3.overrideAttrs (_old: {
                        src = inputs.glfw;
                      });
                    }
                ).overrideAttrs
                  (_old: {
                    outputs = [
                      "out"
                      "dev"
                    ];
                  });
            }
            // lib.optionalAttrs isDarwin {
              # The fork's glfw 3.5.1 bump buys Darwin nothing, yet makes
              # raylib, tracy and every other GLFW consumer a cache miss. Use
              # upstream's glfw3 recipe, whose builds cache.nixos.org has.
              glfw3 = final.callPackage "${inputs.nixpkgs-upstream-glfw}/pkgs/by-name/gl/glfw3/package.nix" { };
              glfw = final.glfw3;
            }
          )
        ];
      };

      legacyPackages.d-toolchain =
        let
          inherit (pkgs) lib;
          inherit (pkgs.stdenv.hostPlatform) isDarwin isx86_64;

          clangUnwrapped = pkgs.clangStdenv.cc.cc;
        in
        {
          packages = [
            pkgs.ldc
            pkgs.dub
            pkgs.dtools
            pkgs.dub-to-nix
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
