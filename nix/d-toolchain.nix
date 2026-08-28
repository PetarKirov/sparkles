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
              hostCpu = prev.stdenv.hostPlatform.parsed.cpu.name;

              rawLdc = inputs'.dlang-nix.packages.ldc-1_42_0;

              cleanLdcConfig = prev.writeText "ldc2.conf" ''
                default:
                {
                    switches = [
                        "-defaultlib=phobos2-ldc,druntime-ldc",
                    ];
                    post-switches = [
                        "-I=${rawLdc}/include/d",
                    ];
                    lib-dirs = [
                        "${rawLdc}/lib",
                    ];
                    rpath = "${rawLdc}/lib";
                };

                "^wasm(32|64)-":
                {
                    switches = [
                        "-defaultlib=",
                        "-L-z", "-Lstack-size=1048576",
                        "-L--stack-first",
                        "-link-internally",
                        "-L--export-dynamic",
                    ];
                    lib-dirs = [];
                };
              '';

              # LDC still needs host ELF links pointed at stdenv's glibc dynamic
              # linker + rpath so `libs "dw"` examples run with elfutils 0.195.
              #
              # Cannot be wrapProgram --add-flags: those flags are
              # prepended to every invocation, and wasm-ld rejects
              # `--dynamic-linker`. Skip them when `-mtriple` is a
              # non-host target (wasm, WASI, Windows, Darwin, …).
              linuxHostElfCompilerWrapper =
                unwrapped:
                prev.writeShellScript "${builtins.baseNameOf unwrapped}-host-elf" ''
                  set -eu
                  use_host_elf=1
                  consider() {
                    case "$1" in
                      wasm*|*-wasi*|*-windows*|*-mingw*|*-darwin*|*-macos*|*-ios*|*-android*|*-none*)
                        use_host_elf=0
                        return
                        ;;
                    esac
                    case "$1" in
                      ${hostCpu}-*|${hostCpu}_*) ;;
                      *) use_host_elf=0 ;;
                    esac
                  }
                  prev_is_mtriple=0
                  # Also honor DFLAGS: LDC prepends it, so a wasm
                  # triple there must suppress the host ELF flags.
                  # Intentional word-split — same as the compiler.
                  for arg in ''${DFLAGS-} "$@"; do
                    if [ "$prev_is_mtriple" -eq 1 ]; then
                      consider "$arg"
                      prev_is_mtriple=0
                      continue
                    fi
                    case "$arg" in
                      -mtriple=*|--mtriple=*)
                        consider "''${arg#*=}"
                        ;;
                      -mtriple|--mtriple)
                        prev_is_mtriple=1
                        ;;
                    esac
                  done
                  if [ "$use_host_elf" -eq 1 ]; then
                    exec "${unwrapped}" \
                      -conf=${cleanLdcConfig} \
                      -L--dynamic-linker=${prev.stdenv.cc.bintools.dynamicLinker} \
                      -L-rpath=${prev.stdenv.cc.libc}/lib \
                      "$@"
                  else
                    exec "${unwrapped}" -conf=${cleanLdcConfig} "$@"
                  fi
                '';
            in
            {
              # dlang.nix defaults to `-link-defaultlib-shared` in its ldc2.conf,
              # which breaks standalone binaries when `buildDubPackage` scrubs
              # compiler references. Re-point drivers at `cleanLdcConfig` (static
              # defaultlibs).
              # On Linux, wrap the drivers to also point host ELF links at stdenv's
              # dynamicLinker and glibc rpath.
              # Because this overlay replaces `pkgs.ldc` package-set-wide, the
              # result must stay a *complete* ldc — dub builds link against
              # `${ldc}/lib` (druntime/phobos) and may invoke `ldmd2` — so we
              # `symlinkJoin` the real package and only wrap the two drivers,
              # rather than substituting a bare `ldc2` shim.
              ldc =
                if isDarwin then
                  prev.symlinkJoin {
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
                  }
                else
                  prev.symlinkJoin {
                    name = "ldc-${rawLdc.version}";
                    paths = [ rawLdc ];
                    postBuild = ''
                      rm -f "$out/bin/ldc2" "$out/bin/ldmd2"
                      ln -s ${linuxHostElfCompilerWrapper "${rawLdc}/bin/ldc2"} "$out/bin/ldc2"
                      ln -s ${linuxHostElfCompilerWrapper "${rawLdc}/bin/ldmd2"} "$out/bin/ldmd2"
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
              # execs it, which trips over the Darwin wrapper above ("Permission
              # denied"), and the tool bundle gains nothing from our cleaned
              # config. A bare `prev.dtools` would not help: nixpkgs `by-name`
              # packages bind `callPackage` to the *final* package set, so
              # `prev.dtools` already resolves `ldc` to the wrapper — the `ldc`
              # argument has to be overridden back to the plain package.
              dtools = prev.dtools.override { ldc = rawLdc; };

              dmd =
                let
                  raw = inputs'.dlang-nix.packages.dmd-2_112_1;
                in
                if isDarwin then
                  raw
                else
                  # Same glibc 2.40/2.42 split as LDC: `ci` on x86_64-linux
                  # shells out to DMD for `--example-files`.
                  prev.symlinkJoin {
                    name = raw.name;
                    paths = [ raw ];
                    nativeBuildInputs = [ prev.makeWrapper ];
                    postBuild = ''
                      wrapProgram "$out/bin/dmd" \
                        --add-flags "-L--dynamic-linker=${prev.stdenv.cc.bintools.dynamicLinker}" \
                        --add-flags "-L-rpath=${prev.stdenv.cc.libc}/lib"
                    '';
                    passthru.unwrapped = raw;
                    meta = raw.meta // {
                      mainProgram = "dmd";
                    };
                  };

              dub = inputs'.dlang-nix.packages.dub-1_43_0-alpha-5efed36;

              # GNOME/Adwaita dropped XCursor files. Stock GLFW 3.5.1 still
              # uploads pixmap cursors, so hue's ew/ns resize shapes fail.
              # inputs.glfw — glfw#2679 rewritten on 3.5.1.
              glfw3 = prev.glfw3.overrideAttrs (_old: {
                src = inputs.glfw;
              });
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
