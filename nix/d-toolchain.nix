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

              clangSparkles = inputs'.dlang-nix.packages.clang-sparkles-unwrapped;
              llvmToolsView =
                name: tools:
                prev.runCommand "${name}-${clangSparkles.version}" { inherit (clangSparkles) version; } ''
                  mkdir -p $out/bin
                  for tool in ${lib.escapeShellArgs tools}; do
                    test -e ${clangSparkles}/bin/$tool || { echo "no $tool in ${clangSparkles}" >&2; exit 1; }
                    ln -s ${clangSparkles}/bin/$tool $out/bin/
                  done
                '';

              # A compiler package and every one it joins over (`unwrapped`), down to
              # the one whose `include/d` holds druntime's and Phobos' sources:
              # `ldc-vulkan` joins over one, the all-LLVM runtime profile's over two.
              layersOf = p: [ p ] ++ lib.optionals (p ? unwrapped) (layersOf p.unwrapped);

              # The project's wrapping of a dlang.nix LDC: its drivers read one of the
              # configurations below. `pkgs.ldc` wraps `rawLdc`; on Linux,
              # `pkgs.ldc-llvm-runtimes` wraps dlang.nix's all-LLVM runtime profile
              # (toolchain spec TC18), which nix/packages/terminal-static.nix builds with.
              ldcFrom =
                rawLdc:
                let
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

                  # For Nix builds (`ldc.reproducible`): the same, plus a map from
                  # the compiler's store paths to `/ldc` in `__FILE__`, assertion
                  # messages and debug info (toolchain spec TC15). druntime's and
                  # Phobos' templates instantiate in the program and name their
                  # source files, which would otherwise keep the compiler in the
                  # program's closure. Development shells keep the real paths, where
                  # a debugger finds the sources.
                  reproducibleLdcConfig = prev.runCommand "ldc2.conf-reproducible" { } ''
                    mkdir $out
                    cp ${cleanLdcConfig}/* $out/
                    cat > $out/40-file-prefix-map.conf <<'EOF'
                    "default":
                    {
                        switches ~= [
                            ${lib.concatMapStringsSep ",\n" (p: ''"-ffile-prefix-map=${p}=/ldc"'') (
                              map toString (layersOf rawLdc)
                            )}
                        ];
                    };
                    EOF
                  '';

                  # The project `ldc`: dlang.nix's with one of the configurations above.
                  wrapLdc =
                    conf:
                    prev.symlinkJoin {
                      name = "ldc-${rawLdc.version}";
                      paths = [ rawLdc ];
                      nativeBuildInputs = [ prev.makeWrapper ];
                      postBuild = ''
                        for drv in ldc2 ldmd2; do
                          wrapProgram "$out/bin/$drv" --add-flags "-conf=${conf}"
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
                          # The C compiler `ldc2` links through (the macOS shell's `CC`).
                          inherit (rawLdc) linkCc;
                          # The same compiler for Nix builds, mapping its store paths.
                          reproducible = wrapLdc reproducibleLdcConfig;
                          mapsStorePaths = conf == reproducibleLdcConfig;
                        };
                      meta = rawLdc.meta // {
                        mainProgram = "ldc2";
                      };
                    };
                in
                wrapLdc cleanLdcConfig;

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
              ldc = ldcFrom rawLdc;

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

              # The fork LLVM's linkers and binary tools (toolchain spec TC2):
              # one LLVM in every build, not the fork's for compiling and
              # nixpkgs' for linking and patching. Views of
              # `clang-sparkles-unwrapped` with only the tools named, so that
              # being on PATH does not also put an unwrapped `clang` there.
              #
              # `lld-sparkles`: `ld.lld`, `wasm-ld`, `lld-link` and `ld64.lld`.
              # On Linux it is dlang.nix's, whose `ld.lld` is behind nixpkgs'
              # bintools wrapper: a link through it records the store paths of
              # its `-L` libraries as RUNPATH entries, as a link through `ld`
              # does. On macOS, where ELF links are cross links, all are raw.
              lld-sparkles =
                if prev.stdenv.hostPlatform.isLinux then
                  inputs'.dlang-nix.packages.lld-sparkles
                else
                  llvmToolsView "lld-sparkles" [
                    "lld"
                    "ld.lld"
                    "ld64.lld"
                    "lld-link"
                    "wasm-ld"
                  ];
              # `llvm-objcopy` (the build-info section) and its siblings.
              llvm-binutils-sparkles = llvmToolsView "llvm-binutils-sparkles" [
                "llvm-ar"
                "llvm-nm"
                "llvm-objcopy"
                "llvm-objdump"
                "llvm-ranlib"
                "llvm-readelf"
                "llvm-readobj"
                "llvm-size"
                "llvm-strip"
              ];

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
            // lib.optionalAttrs prev.stdenv.hostPlatform.isLinux {
              # The all-LLVM runtime profile's LDC (TC18): its programs link
              # compiler-rt, libunwind and libc++ statically in place of the
              # GCC runtime, and druntime and Phobos statically always.
              ldc-llvm-runtimes = ldcFrom inputs'.dlang-nix.packages.ldc-vulkan-llvm-runtimes;
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
          inherit (pkgs.stdenv.hostPlatform) isDarwin isLinux isx86_64;

          # The shell's stdenv exports its own `CC`, which `ldc2` would link
          # with; name the wrapped `clang-sparkles` its wrapper defaults to
          # (TC6, TC8).
          env = lib.optionalAttrs isDarwin {
            CC = "${pkgs.ldc.linkCc}/bin/cc";
            CXX = "${pkgs.ldc.linkCc}/bin/c++";
            SDKROOT = "${pkgs.apple-sdk}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk";
            MACOSX_DEPLOYMENT_TARGET = "14.0";
          };

          # Caps open-file limit so D's std.process.fork() child doesn't overflow
          # when casting rlim_cur to int (phobos bug with unlimited NOFILE).
          nofileLimit = 131072;
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

          # The variables every D build and tool needs, as an attribute set (a
          # derivation's `env`; `buildSparklesApp`'s default) and rendered for
          # the two other consumers: a shell hook and a `makeWrapper` call.
          inherit env nofileLimit;
          shellExports = lib.concatStringsSep "\n" (
            lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}") env
          );
          # Not lib.cli.toCommandLine*: its option-spec model renders `--flag
          # value` pairs, not makeWrapper's three-token `--set KEY VALUE` form.
          wrapperArgs = lib.concatLists (
            lib.mapAttrsToList (name: value: [
              "--set"
              name
              value
            ]) env
          );

          # Raises the open-file limit to `nofileLimit`, best effort: where the
          # hard cap is lower (some CI runners, restricted sandboxes) the
          # inherited limit stays, and the command still succeeds (makeWrapper's
          # `--run` is under `set -e`).
          nofileCommand = "ulimit -n ${toString nofileLimit} 2>/dev/null || true";

          # The C libraries in-repo programs and examples link outside a Nix
          # build (`libs "dw" "elf"`, `libs "pfm"`, `libs "kqueue"` under `dub
          # run --single`): the shell's and the `ci` wrapper's `LIBRARY_PATH`
          # and `LD_LIBRARY_PATH`. Linux-only; empty elsewhere.
          libraryPath = lib.optionalString isLinux (
            lib.makeSearchPath "lib" [
              pkgs.elfutils.out
              pkgs.libpfm
              pkgs.libkqueue
            ]
          );
        };
    };
}
