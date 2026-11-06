# The showcase applications as self-contained programs (toolchain
# specification TC20): built by dlang.nix's `ldc-vulkan-llvm-runtimes` (TC18),
# with every D, C and C++ dependency linked statically and compiled by the same
# `clang-sparkles` against LLVM's runtimes. Dynamic remain only the C library
# and what the platform loads at run time: the Vulkan loader, which loads the
# graphics drivers, and the window system (Wayland, XCB, Xlib, xkbcommon).
# Linux only.
#
# - `terminal-static`: the terminal's default (native, Vulkan) configuration.
# - `hue-static`: hue's default configuration, TUI and the native window.
#
# The bundled libraries:
#
# - HarfBuzz, the release sparkles:font pins (./harfbuzz.nix), with FreeType,
#   libpng and zlib beneath it, and no GLib, Graphite2 or ICU. It needs no C++
#   runtime, so neither program links libc++ at all.
# - tree-sitter's runtime (sparkles:syntax), one C file. Grammars stay plugins,
#   loaded from `SPARKLES_TS_GRAMMAR_PATH`, built by the same clang
#   (`grammars`).
# - raylib over GLFW (the fork ./../d-toolchain.nix builds raylib with), which
#   loads GL, Wayland, xkbcommon and the X libraries at run time, by store
#   path. Neither program links it any more: both draw on the native arm.
#   It stays bundled for the raylib configurations until they are retired.
# - libghostty-vt's own static archive (zig-built, with simdutf and highway
#   inside), less the debug info that names zig's store paths. Its
#   `compiler_rt.o` stays (aarch64 needs its `__extendxftf2`, which LLVM's
#   builtins have only for x86), but with the C library's names in it
#   (`memcpy`, `memset`, `ceil`, …, all weak) made local: in a static link
#   they would replace glibc's and libm's for the whole program.
# - hue's libcurl (the forge client, `DPR1`): HTTP and HTTPS over OpenSSL and
#   zlib, nothing else. Phobos' `std.net.curl` looks its functions up at run
#   time, in the program first (`dlsym` on the program's handle) and then in a
#   `libcurl.so`; the program exports `curl_*` so the first lookup finds them.
#
# dub asks pkg-config for every library in one call; `bundledPkgConfig` asks
# for the bundled ones with `--static` (their private dependencies) and for
# the platform's without (wayland's private libffi has no `.pc` here).
#
# `legacyPackages.staticAppChecks.<app>` asserts each program: its `NEEDED`
# entries are all platform interfaces, none is a GCC or LLVM runtime, it
# starts, the grammars it opens need only the C library, and neither the
# program nor the grammars refer to GCC's C++ runtime.
# `legacyPackages.staticAppChecks.<app>-tests` runs its test suite, built the
# same way, headless.
#
# They are not flake `checks`: CI's `test` legs run `nix flake check`, and
# these four rebuild both programs and run both suites under Xvfb whenever a
# source changes, which took those legs past their time limits. The
# `static-apps` job in .github/workflows/ci.yml builds them instead, on
# x86_64-linux and aarch64-linux:
#
#     nix build .#legacyPackages.x86_64-linux.staticAppChecks.{hue-static,hue-static-tests,terminal-static,terminal-static-tests}
{ inputs, lib, ... }:
let
  # The libraries these programs link statically, by pkg-config name.
  bundled = [
    "harfbuzz"
    "freetype2"
    "raylib"
    "glfw3"
    "tree-sitter"
    "libghostty-vt"
    "curl"
    "libcurl"
  ];

  # The shared libraries a self-contained program may need (TC20): the C
  # library, the Vulkan loader and the window system.
  platformInterfaces = [
    "libc\\.so\\.6"
    "libm\\.so\\.6"
    "libdl\\.so\\.2"
    "librt\\.so\\.1"
    "libpthread\\.so\\.0"
    "ld-linux-[a-z0-9_-]+\\.so\\.[0-9]+"
    "libvulkan\\.so\\.1"
    "libwayland-client\\.so\\.0"
    "libxcb(-[a-z]+)?\\.so\\.[0-9]+"
    "libxkbcommon(-x11)?\\.so\\.0"
    "libX11\\.so\\.6"
  ];
in
{
  perSystem =
    {
      config,
      inputs',
      pkgs,
      ...
    }:
    # `mkIf`, not `optionalAttrs`: the condition reads `pkgs`, a module argument.
    lib.mkIf pkgs.stdenv.hostPlatform.isLinux (
      let
        dlang = inputs'.dlang-nix;
        inherit (config.legacyPackages) buildSparklesApp sparklesSources;

        # Static libraries, by the profile's `clang-sparkles`.
        staticStdenv = pkgs.stdenvAdapters.makeStaticLibraries dlang.legacyPackages.clangStdenv-sparkles-llvm-runtimes;

        zlib = pkgs.zlib.override {
          stdenv = staticStdenv;
          shared = false;
        };
        libpng = pkgs.libpng.override {
          stdenv = staticStdenv;
          inherit zlib;
        };
        freetype =
          (pkgs.freetype.override {
            stdenv = staticStdenv;
            inherit zlib libpng;
          }).overrideAttrs
            (old: {
              buildInputs = [ ];
              propagatedBuildInputs = [
                zlib
                libpng
              ];
              configureFlags = old.configureFlags ++ [
                "--without-bzip2"
                "--without-brotli"
                "--without-harfbuzz"
              ];
              # nixpkgs' installs `freetype-config` against the shared library.
              postInstall = "";
              doCheck = false;
            });
        harfbuzz =
          (config.packages.harfbuzz.override {
            stdenv = staticStdenv;
            inherit freetype;
            withIntrospection = false;
            withGraphite2 = false;
          }).overrideAttrs
            (old: {
              outputs = [
                "out"
                "dev"
              ];
              buildInputs = [ ];
              propagatedBuildInputs = [ freetype ];
              nativeBuildInputs = [
                pkgs.meson
                pkgs.ninja
                pkgs.pkg-config
                pkgs.python3
              ];
              mesonFlags = [
                "-Ddefault_library=static"
                "-Dfreetype=enabled"
                "-Dglib=disabled"
                "-Dgobject=disabled"
                "-Dintrospection=disabled"
                "-Dgraphite2=disabled"
                "-Dicu=disabled"
                "-Dcairo=disabled"
                "-Dchafa=disabled"
                "-Dtests=disabled"
                "-Ddocs=disabled"
                "-Dutilities=disabled"
                "-Dgpu_demo=disabled"
              ];
              postInstall = "";
              postFixup = "";
              doCheck = false;
              doInstallCheck = false;
            });
        tree-sitter = staticStdenv.mkDerivation {
          pname = "tree-sitter-runtime-static";
          inherit (pkgs.tree-sitter) version src;
          dontConfigure = true;
          buildPhase = ''
            runHook preBuild
            $CC -c lib/src/lib.c -o lib.o -Ilib/include -Ilib/src -O2 -fPIC
            $AR rcs libtree-sitter.a lib.o
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            install -Dm644 libtree-sitter.a $out/lib/libtree-sitter.a
            cp -r lib/include $out/include
            mkdir -p $out/lib/pkgconfig
            cat > $out/lib/pkgconfig/tree-sitter.pc <<EOF
            Name: tree-sitter
            Description: tree-sitter's runtime
            Version: ${pkgs.tree-sitter.version}
            Cflags: -I$out/include
            Libs: -L$out/lib -ltree-sitter
            EOF
            runHook postInstall
          '';
          meta = {
            description = "tree-sitter's C runtime as a static library";
            inherit (pkgs.tree-sitter.meta) license homepage;
          };
        };
        # GLFW, the fork ./../d-toolchain.nix builds raylib with, static. It
        # loads every window-system and GL library itself: nixpkgs points its
        # Wayland, xkbcommon, libdecor and GL names at store paths, and the X
        # libraries get the same treatment here in place of nixpkgs' patch
        # that links them (which would make them `NEEDED`).
        glfw = (pkgs.glfw3.override { stdenv = staticStdenv; }).overrideAttrs (old: {
          src = inputs.glfw;
          patches = [ ];
          postPatch =
            old.postPatch
            +
              lib.concatMapStrings
                (
                  { lib', so }:
                  ''
                    substituteInPlace src/x11_init.c \
                      --replace-fail '"${so}"' '"${lib.getLib lib'}/lib/${so}"'
                  ''
                )
                [
                  {
                    lib' = pkgs.libx11;
                    so = "libX11.so.6";
                  }
                  {
                    lib' = pkgs.libx11;
                    so = "libX11-xcb.so.1";
                  }
                  {
                    lib' = pkgs.libxxf86vm;
                    so = "libXxf86vm.so.1";
                  }
                  {
                    lib' = pkgs.libxi;
                    so = "libXi.so.6";
                  }
                  {
                    lib' = pkgs.libxrandr;
                    so = "libXrandr.so.2";
                  }
                  {
                    lib' = pkgs.libxcursor;
                    so = "libXcursor.so.1";
                  }
                  {
                    lib' = pkgs.libxinerama;
                    so = "libXinerama.so.1";
                  }
                  {
                    lib' = pkgs.libxrender;
                    so = "libXrender.so.1";
                  }
                  {
                    lib' = pkgs.libxext;
                    so = "libXext.so.6";
                  }
                ];
          propagatedBuildInputs = [ ];
          cmakeFlags = [ (lib.cmakeBool "BUILD_SHARED_LIBS" false) ];
        });
        raylib =
          (pkgs.raylib.override {
            stdenv = staticStdenv;
            sharedLib = false;
            inherit glfw;
          }).overrideAttrs
            (old: {
              # Headers alone: raylib calls Xlib for the clipboard's images and
              # includes GLFW's native header and GL's.
              buildInputs = [
                glfw
                pkgs.libGL
                pkgs.libx11
                pkgs.libxrandr
                pkgs.libxinerama
                pkgs.libxcursor
                pkgs.libxi
                pkgs.wayland
                pkgs.libxkbcommon
              ];
              propagatedBuildInputs = [ ];
              appendRunpaths = [ ];
              cmakeFlags = old.cmakeFlags ++ [ (lib.cmakeBool "BUILD_EXAMPLES" false) ];
              # Xlib, the one window-system library raylib calls itself, from the
              # platform: linked only where those calls are, so a program that
              # never opens raylib's window does not need it.
              postFixup = (old.postFixup or "") + ''
                sed -i 's|^Libs: \(.*\)$|Libs: \1 -L${lib.getLib pkgs.libx11}/lib --push-state --as-needed -lX11 --pop-state|' \
                  ''${!outputDev}/lib/pkgconfig/raylib.pc
              '';
            });
        vt = inputs'.ghostty.packages.libghostty-vt;
        ghostty =
          pkgs.runCommand "libghostty-vt-static-${vt.version}" { nativeBuildInputs = [ pkgs.binutils ]; }
            ''
              mkdir -p $out/lib/pkgconfig
              install -m644 ${vt.dev}/lib/libghostty-vt.a $out/lib/
              strip -g $out/lib/libghostty-vt.a
              (
                cd $TMPDIR
                ar x $out/lib/libghostty-vt.a compiler_rt.o
                nm --defined-only compiler_rt.o | awk '$2 == "W" && $3 !~ /^__/ { print $3 }' > libc-names
                objcopy --localize-symbols=libc-names compiler_rt.o
                ar r $out/lib/libghostty-vt.a compiler_rt.o
              )
              cp -r ${vt.dev}/include $out/include
              cat > $out/lib/pkgconfig/libghostty-vt.pc <<EOF
              Name: libghostty-vt
              Description: Ghostty's terminal emulation, as a static library
              Version: ${vt.version}
              Cflags: -I$out/include
              Libs: -L$out/lib -lghostty-vt
              EOF
            '';
        openssl = pkgs.openssl.override {
          stdenv = staticStdenv;
          static = true;
        };
        # HTTP and HTTPS alone. `--export-dynamic-symbol` rides in the
        # pkg-config file: dub passes its flags to the linker, so the program
        # exports what `std.net.curl` looks up in it.
        curl =
          (pkgs.curlMinimal.override {
            stdenv = staticStdenv;
            inherit zlib openssl;
            opensslSupport = true;
            http2Support = false;
            scpSupport = false;
            gssSupport = false;
          }).overrideAttrs
            (old: {
              doCheck = false;
              postFixup = (old.postFixup or "") + ''
                sed -i 's|^Libs: \(.*\)$|Libs: \1 --export-dynamic-symbol=curl_*|' \
                  ''${!outputDev}/lib/pkgconfig/libcurl.pc
              '';
            });

        # The grammar bundle (./ts-grammars.nix) over the same sources, built
        # by the profile's clang. A grammar links as C unless its scanner is
        # C++; then libc++ and LLVM's unwinder link in statically and hidden,
        # so no grammar needs a C++ runtime or loads a second unwinder (TC19).
        buildGrammar =
          args:
          (pkgs.callPackage "${pkgs.path}/pkgs/by-name/tr/tree-sitter/grammars/build-grammar.nix" {
            stdenv = dlang.legacyPackages.clangStdenv-sparkles-llvm-runtimes;
          } args).overrideAttrs
            {
              buildPhase = ''
                runHook preBuild
                link=($CC -static-libgcc)
                if [[ -e src/scanner.cc ]]; then
                  $CXX -fPIC -c src/scanner.cc -o scanner.o $CXXFLAGS
                  link=($CXX -static-libstdc++ -static-libgcc -Wl,--exclude-libs,ALL)
                elif [[ -e src/scanner.c ]]; then
                  $CC -fPIC -c src/scanner.c -o scanner.o $CFLAGS
                fi
                $CC -fPIC -c src/parser.c -o parser.o $CFLAGS
                rm -rf parser
                "''${link[@]}" -shared -o parser *.o
                runHook postBuild
              '';
            };
        grammars = config.legacyPackages.tsGrammarBundleWith {
          g = builtins.mapAttrs (_: buildGrammar) pkgs.tree-sitter.grammars;
          inherit buildGrammar;
          inHouse = {
            d = buildGrammar config.packages.tree-sitter-d.grammarArgs;
            sdl = buildGrammar config.packages.tree-sitter-sdl.grammarArgs;
          };
        };

        bundledPkgConfig = pkgs.writeShellScriptBin "pkg-config" ''
          opts=() bundled=() platform=()
          for a in "$@"; do
            case "$a" in
              -*) opts+=("$a") ;;
              ${lib.concatStringsSep "|" bundled}) bundled+=("$a") ;;
              *) platform+=("$a") ;;
            esac
          done
          if (( ''${#bundled[@]} + ''${#platform[@]} == 0 )); then
            exec ${lib.getExe' pkgs.pkg-config "pkg-config"} "$@"
          fi
          out=""
          if (( ''${#bundled[@]} )); then
            out+="$(${lib.getExe' pkgs.pkg-config "pkg-config"} --static "''${opts[@]}" "''${bundled[@]}") " || exit
          fi
          if (( ''${#platform[@]} )); then
            out+="$(${lib.getExe' pkgs.pkg-config "pkg-config"} "''${opts[@]}" "''${platform[@]}")" || exit
          fi
          echo "$out"
        '';

        bundledLibraries = {
          inherit
            zlib
            libpng
            freetype
            harfbuzz
            tree-sitter
            glfw
            raylib
            ghostty
            openssl
            curl
            ;
        };

        # An application built by the profile's LDC against the bundled
        # libraries; a program and its test suite alike.
        staticBuild = appDir: {
          inherit appDir;
          compiler = pkgs.ldc-llvm-runtimes.reproducible;

          # Ahead of `pkgs.pkg-config`, which buildSparklesApp adds.
          nativeBuildInputs = [
            bundledPkgConfig
            pkgs.pkg-config
          ];
          # Ahead of the shared HarfBuzz and FreeType buildSparklesApp adds
          # for sparkles:raylib-text: pkg-config finds these first.
          buildInputs = lib.concatMap (p: [ p ] ++ lib.optional (p ? dev) p.dev) (
            builtins.attrValues bundledLibraries
          );
        };

        # An application's test suite, built as its program is and run
        # headless: Xvfb for the window system, Mesa's lavapipe for Vulkan.
        # dub's unittest build type asks for the shared druntime; the profile
        # links the static one all the same (dlang.nix TC19).
        staticTests =
          {
            pname,
            appDir,
            configuration,
            # Sources the suite reads at run time, as `{ src; dest; }`, `dest`
            # relative to the application's directory.
            fixtures ? [ ],
            nativeCheckInputs ? [ ],
          }:
          let
            base = staticBuild appDir;
          in
          buildSparklesApp (
            base
            // {
              inherit pname;
              version = "0.1.0";
              # The application's closure and the test runner's.
              sourceDirs =
                sparklesSources.srcClosure appDir
                ++ sparklesSources.libsClosure [
                  "test-runner"
                  "test-runner-impl"
                  "test-utils"
                ];
              nativeBuildInputs = base.nativeBuildInputs ++ [ pkgs.xvfb-run ] ++ nativeCheckInputs;

              dontDubBuild = true;
              buildPhase = ''
                runHook preBuild
                runHook postBuild
              '';
              doCheck = true;
              checkPhase = ''
                runHook preCheck
                export VK_DRIVER_FILES=${pkgs.mesa}/share/vulkan/icd.d/lvp_icd.${pkgs.stdenv.hostPlatform.uname.processor}.json
                export SPARKLES_TS_GRAMMAR_PATH=${grammars}
                ${lib.concatMapStrings (f: ''
                  mkdir -p "$(dirname ${f.dest})"
                  cp -rT --no-preserve=mode ${f.src} ${f.dest}
                '') fixtures}
                xvfb-run -a -s '-screen 0 1280x800x24' \
                  dub test --skip-registry=all --config=${configuration} -- -v 2>&1 \
                  | tee $NIX_BUILD_TOP/test.log
                grep -E '^Summary: [0-9]+ passed, 0 failed' $NIX_BUILD_TOP/test.log
                runHook postCheck
              '';
              installPhase = ''
                mkdir -p $out
                grep -E '^Summary:' $NIX_BUILD_TOP/test.log > $out/summary
              '';
            }
          );

        # What every self-contained program must hold to (TC19, TC20), and
        # `smoke`, the program's own run.
        staticCheck =
          {
            name,
            app,
            smoke,
          }:
          pkgs.runCommand "${name}-check"
            {
              nativeBuildInputs = [ pkgs.binutils ];
            }
            ''
              exe=${app}/bin/.${app.pname}-wrapped
              readelf -d $exe | tee dynamic.txt
              grep -oP '(?<=Shared library: \[)[^]]+' dynamic.txt > needed.txt
              if grep -vxE '${lib.concatStringsSep "|" platformInterfaces}' needed.txt; then
                echo "needed beyond the platform interfaces (above)"
                exit 1
              fi
              if grep -E 'libgcc_s|libstdc\+\+|libc\+\+|libunwind' needed.txt; then
                echo "a GCC or LLVM runtime is linked dynamically"
                exit 1
              fi
              # The C library's memcpy, not a bundled library's.
              nm -D --undefined-only $exe | grep -qw memcpy
              LD_DEBUG=libs $exe --version 2> loaded.txt > /dev/null
              if grep -E 'libgcc_s|libstdc\+\+' loaded.txt; then
                echo "the program loaded a GCC runtime"
                exit 1
              fi
              ${smoke}

              # The grammars it opens need only the C library, and GCC's C++
              # runtime is in neither their closure nor among the program's own
              # references. (What the platform loads may bring it, as a Mesa
              # driver or GLFW's libdecor does, and as glibc brings `libgcc_s`.)
              for parser in ${grammars}/*/parser; do
                readelf -d $parser | grep -oP '(?<=Shared library: \[)[^]]+'
              done | sort -u > grammars-needed.txt
              cat grammars-needed.txt
              if grep -vxE 'libc\.so\.6|libm\.so\.6|ld-linux-[a-z0-9_-]+\.so\.[0-9]+' grammars-needed.txt; then
                echo "a grammar needs more than the C library (above)"
                exit 1
              fi
              grep -aoE '${builtins.storeDir}/[a-z0-9]{32}-[^/"[:space:]]+' $exe | sort -u > references.txt
              if cat references.txt ${pkgs.closureInfo { rootPaths = [ grammars ]; }}/store-paths \
                | grep -E -- '-gcc-[0-9.]+-lib$'; then
                echo "GCC's C++ runtime is referenced (above)"
                exit 1
              fi
              touch $out
            '';

        terminal-static = buildSparklesApp (
          finalAttrs:
          staticBuild "apps/terminal"
          // {
            pname = "terminal-static";
            version = "0.1.0";
            dubBuildFlags = [ "--config=application" ];

            installPhase = ''
              install -Dm755 build/terminal $out/bin/${finalAttrs.pname}
            '';

            # As `terminal`: grammars and `fc-match` come from the store.
            postFixup = ''
              wrapProgram $out/bin/${finalAttrs.pname} \
                --set-default SPARKLES_TS_GRAMMAR_PATH ${grammars} \
                --prefix PATH : ${lib.makeBinPath [ pkgs.fontconfig ]}
            '';

            passthru.bundled = bundledLibraries;

            meta = {
              description = "The terminal on the Vulkan arm, linked self-contained under the all-LLVM runtime profile";
              mainProgram = finalAttrs.pname;
            };
          }
        );

        hue-static = buildSparklesApp (
          finalAttrs:
          let
            base = staticBuild "apps/hue";
          in
          base
          // {
            pname = "hue-static";
            version = "0.1.0";
            dubBuildFlags = [ "--config=application" ];
            # As `hue`: the format preview's `dmd:frontend` asks git for the
            # compiler's version string at build time.
            nativeBuildInputs = base.nativeBuildInputs ++ [ pkgs.gitMinimal ];

            installPhase = ''
              install -Dm755 build/hue $out/bin/${finalAttrs.pname}
            '';

            # As `hue`: grammars, `fc-match` and the live-types extractor come
            # from the store.
            postFixup = ''
              wrapProgram $out/bin/${finalAttrs.pname} \
                --set-default SPARKLES_TS_GRAMMAR_PATH ${grammars} \
                --set-default SPARKLES_TWOSLASH_EXTRACT ${lib.getExe config.packages.twoslash-extract.oracle} \
                --prefix PATH : ${lib.makeBinPath [ pkgs.fontconfig ]}
            '';

            passthru.bundled = bundledLibraries;

            meta = {
              description = "hue, linked self-contained under the all-LLVM runtime profile";
              mainProgram = finalAttrs.pname;
            };
          }
        );
      in
      {
        packages = {
          inherit terminal-static hue-static;
        };

        legacyPackages.staticAppChecks.terminal-static = staticCheck {
          name = "terminal-static";
          app = terminal-static;
          smoke = ''
            $exe --help > help.txt
            grep -q 'SYNOPSIS' help.txt
          '';
        };
        legacyPackages.staticAppChecks.terminal-static-tests = staticTests {
          pname = "terminal-static-tests";
          appDir = "apps/terminal";
          configuration = "unittest";
          # `keymap.bindingsMarkdown.matchesTheReference` reads the reference page.
          fixtures = [
            {
              src = ../../docs/apps/terminal/reference/bindings.md;
              dest = "../../docs/apps/terminal/reference/bindings.md";
            }
          ];
        };

        legacyPackages.staticAppChecks.hue-static = staticCheck {
          name = "hue-static";
          app = hue-static;
          # A render: hue prints a highlighted file when its output is not a
          # terminal, opening the D grammar, which must be the profile's.
          smoke = ''
            $exe --help > help.txt
            grep -qi 'usage\|synopsis' help.txt
            export SPARKLES_TS_GRAMMAR_PATH=${grammars}
            LD_DEBUG=libs $exe --no-gui ${../../apps/hue/test/fixtures/dub-single-file.d} \
              > render.txt 2> render-loaded.txt
            grep -q $'\e\[' render.txt
            for p in ${grammars}/*/parser; do readlink -f $p; done | sort -u > bundle.txt
            grep -oP '(?<=calling init: )\S+/parser$' render-loaded.txt \
              | xargs -r readlink -f | sort -u > opened.txt
            cat opened.txt
            grep -q . opened.txt
            if comm -23 opened.txt bundle.txt | grep .; then
              echo "a grammar from outside the profile's bundle (above)"
              exit 1
            fi
          '';
        };
        legacyPackages.staticAppChecks.hue-static-tests = staticTests {
          pname = "hue-static-tests";
          appDir = "apps/hue";
          configuration = "unittest";
          # The fixtures the suite opens: every kind of file, not only D.
          fixtures = [
            {
              src = ../../apps/hue/test;
              dest = "test";
            }
            # `workspace.initialLocationSelection` opens the repository's
            # `package.json` from the working directory.
            {
              src = ../../package.json;
              dest = "package.json";
            }
          ];
          nativeCheckInputs = [ pkgs.gitMinimal ];
        };
      }
    );
}
