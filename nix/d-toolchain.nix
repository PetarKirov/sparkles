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

              # Official LDC 1.41 still rpaths glibc 2.40. nixpkgs
              # elfutils 0.195 needs GLIBC_ABI_GNU2_TLS from this
              # stdenv's glibc. Point host ELF links at that
              # interpreter + rpath so `libs "dw"` examples run.
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
                      -L--dynamic-linker=${prev.stdenv.cc.bintools.dynamicLinker} \
                      -L-rpath=${prev.stdenv.cc.libc}/lib \
                      "$@"
                  else
                    exec "${unwrapped}" "$@"
                  fi
                '';

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
                    # Pass the real ldc's separate `include` output through the
                    # wrapper: the closure scrubs in
                    # nix/packages/{default,examples}.nix reference
                    # `pkgs.ldc.include` (phobos sources leak into binaries via
                    # assert/`__FILE__` strings) and must evaluate uniformly on
                    # both platforms.
                    passthru = {
                      inherit (prev.ldc) include;
                    };
                    meta = prev.ldc.meta // {
                      mainProgram = "ldc2";
                    };
                  }
                else
                  prev.symlinkJoin {
                    name = "ldc-${prev.ldc.version}";
                    paths = [ prev.ldc ];
                    postBuild = ''
                      rm -f "$out/bin/ldc2" "$out/bin/ldmd2"
                      ln -s ${linuxHostElfCompilerWrapper "${prev.ldc}/bin/ldc2"} "$out/bin/ldc2"
                      ln -s ${linuxHostElfCompilerWrapper "${prev.ldc}/bin/ldmd2"} "$out/bin/ldmd2"
                    '';
                    passthru = {
                      inherit (prev.ldc) include;
                    };
                    meta = prev.ldc.meta // {
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
              dtools = prev.dtools.override { ldc = prev.ldc; };

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
