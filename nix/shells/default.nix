{ inputs, ... }:
{
  perSystem =
    {
      config,
      pkgs,
      inputs',
      ...
    }:
    let
      inherit (pkgs) lib;
      inherit (config.legacyPackages) d-toolchain;

      # LDC's ImportC cannot parse the C23 `[[deprecated(...)]]` attribute that
      # `nix_api_value.h` / `nix_api_expr.h` put on the deprecated `Value`
      # typedef (which `sparkles:nix` does not use). Strip it from a copy of
      # `nix-expr-c`'s dev output and repoint the pkg-config includedir at the
      # patched headers. Prepending this on PKG_CONFIG_PATH (below) makes it
      # win over the unpatched copy that `nix-flake-c` propagates.
      nix-expr-c-dev-patched = pkgs.runCommand "nix-expr-c-dev-patched" { } ''
        cp -r ${inputs'.nix.packages.nix-expr-c.dev} $out
        chmod -R u+w $out
        sed -i -E 's/\[\[[^]]*\]\]//g' \
          $out/include/nix_api_value.h \
          $out/include/nix_api_expr.h
        substituteInPlace $out/lib/pkgconfig/nix-expr-c.pc \
          --replace-quiet ${inputs'.nix.packages.nix-expr-c.dev} $out
      '';

      # All Nix C API headers are supplied via pkg-config (PKG_CONFIG_PATH),
      # NOT via buildInputs `.dev` outputs — otherwise the nix cc wrapper would
      # inject the unpatched nix-expr-c include dir into NIX_CFLAGS_COMPILE and
      # shadow nix-expr-c-dev-patched. The patched expr dev is listed first.
      nixCApiPkgConfigPath = lib.makeSearchPath "lib/pkgconfig" [
        nix-expr-c-dev-patched
        inputs'.nix.packages.nix-util-c.dev
        inputs'.nix.packages.nix-store-c.dev
        inputs'.nix.packages.nix-fetchers-c.dev
        inputs'.nix.packages.nix-flake-c.dev
        inputs'.nix.packages.nix-main-c.dev
      ];

      envExports = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}") d-toolchain.env
      );

      exclusions = import ../flake-exclusions.nix;

      # Every flake input as a `/nix/store` path. `self` is omitted — interpolating
      # it recurses / re-copies the tree into the shell closure. Opt-in benchmark
      # corpora from nix/flake-exclusions.nix are also omitted to keep the shell lean.
      # Name transform: `dmd-src` → `SPARKLES_FLAKE_INPUT_DMD_SRC`. See AGENTS.md
      # "Flake-input store paths".
      flakeInputPaths = lib.mapAttrs (_: v: toString v) (
        removeAttrs inputs ([ "self" ] ++ exclusions.excludedFlakeInputs)
      );
      flakeInputEnvName =
        name: "SPARKLES_FLAKE_INPUT_" + lib.toUpper (lib.replaceStrings [ "-" ] [ "_" ] name);
      flakeInputExports = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (
          name: path: "export ${flakeInputEnvName name}=${lib.escapeShellArg path}"
        ) flakeInputPaths
        ++ [
          "export SPARKLES_ALL_FLAKE_INPUTS=${lib.escapeShellArg (builtins.toJSON flakeInputPaths)}"
        ]
      );

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

      # ISA presets for the nix-built engines of the wired runtime JSON bench:
      # the sandbox forbids -march=native, so each native engine is built once
      # per preset and the best one the host supports is picked at shell entry
      # below ($WIRED_BENCH_ISA + PKG_CONFIG_PATH). One pkgconfig search dir
      # per preset, grown by each bench engine module (yyjson, C++/Rust shims).
      benchIsaPresets = import ../packages/wired-bench-isa-presets.nix pkgs;
      benchPkgsFor = preset: [
        config.packages."wired-bench-yyjson-${preset.attr}"
        config.packages."wired-bench-cpp-shim-${preset.attr}"
        config.packages."wired-bench-rs-${preset.attr}"
      ];
      benchPcPath = preset: lib.makeSearchPath "lib/pkgconfig" (benchPkgsFor preset);
      benchIsaHook =
        if builtins.length benchIsaPresets == 2 then
          # x86_64: runtime pick between the v4 and v2 presets.
          let
            v2 = builtins.elemAt benchIsaPresets 0;
            v4 = builtins.elemAt benchIsaPresets 1;
          in
          ''
            if grep -q avx512f /proc/cpuinfo 2>/dev/null; then
              export WIRED_BENCH_ISA=${v4.isa}
              export PKG_CONFIG_PATH=${benchPcPath v4}''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}
            else
              export WIRED_BENCH_ISA=${v2.isa}
              export PKG_CONFIG_PATH=${benchPcPath v2}''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}
            fi
          ''
        else
          let
            only = builtins.head benchIsaPresets;
          in
          ''
            export WIRED_BENCH_ISA=${only.isa}
            export PKG_CONFIG_PATH=${benchPcPath only}''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}
          '';
      # Yarn Berry 4: `package.json#packageManager` selects the release.
      # `corepack enable` cannot write shims into the Nix store, so this is a
      # Corepack passthrough named `yarn`.
      yarn = pkgs.writeShellScriptBin "yarn" ''
        export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
        exec ${pkgs.nodejs}/bin/corepack yarn "$@"
      '';

      # ── The `ci` tier, as features ─────────────────────────────────────
      #
      # The `ci` tier is the floor: exactly what `ci --test`,
      # `ci --example-files` and `ci --test-extracted` need in order to *run*
      # rather than skip. Everything else is interactive-only and lives in
      # `devPackages`, because CI pays for it in download time on every cold
      # runner — chromium alone is a 1.7 GiB closure, and nothing in CI opens
      # a browser.
      #
      # The floor is split into named features, each the packages and the
      # shell-hook lines of one capability. The dev shells take all of them;
      # a CI job takes only those its units need (`nix/ci/lib/graph.nix` says
      # which, from the recipes' `libs` and a table of what tests exec or
      # read), so a job's closure is what it runs, not the union.
      #
      # The rule for adding to a feature: it belongs here if a CI job links
      # it, execs it, or degrades to a skip without it. Every name exists on
      # every system — a feature with nothing to offer there is empty — so
      # the graph, which is system-independent, can name any of them.
      ciFeatures =
        ciTool:
        let
          inherit (pkgs.stdenv.hostPlatform) isLinux isDarwin;
          linux = lib.optionals isLinux;
          feature =
            {
              packages ? [ ],
              hook ? "",
            }:
            {
              inherit packages hook;
            };
          libraryPath = paths: ''
            export LIBRARY_PATH="${lib.makeLibraryPath paths}''${LIBRARY_PATH:+:$LIBRARY_PATH}"
            export LD_LIBRARY_PATH="${lib.makeLibraryPath paths}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
          '';
        in
        {
          # What every job compiling D needs: the compilers and dub, the
          # helper, and the tools `dub test` itself execs.
          base = feature {
            packages = d-toolchain.packages ++ [
              # CI helper — the `ci --test` / `ci --example-files` the jobs
              # invoke. libcurl is linked by its --ci-stats subcommand (and by
              # hue).
              ciTool
              pkgs.curl

              # Tests, `ci --build-each-commit` and dub's version detection
              # all exec git. Minimal, so no second Python.
              pkgs.gitMinimal
              # dub resolves every `libs` through it.
              pkgs.pkg-config
              # Used by :test-utils for diff output on a failing assertion.
              pkgs.delta
              # `unzip -l`, the cross-check of the cosmopolitan-ape ZIP example.
              pkgs.unzip

              # Tests exec node (the wasm runtime of `--wasm`, and fixture
              # generators); it is in the helper's closure regardless.
              pkgs.nodejs
              # Yarn, for the VitePress site and the twoslash fixture generator.
              yarn
            ];
            hook = ''
              # Seed writable sources, preserving any existing user versions.
              # The packaged helper retains the bundle through its runtime
              # closure.
              export SPARKLES_DUB_SOURCES=${config.packages.dub-sources}
              ${lib.getExe ciTool} --seed-dub-cache >/dev/null 2>&1 || {
                echo 'Failed to seed DUB sources; run ci --seed-dub-cache for details.' >&2
                return 1
              }

              # Keep D's std.process child setup inside the signed-int range.
              # Phobos casts RLIMIT_NOFILE from rlim_t to int before closing
              # inherited descriptors; an unlimited soft limit overflows, and
              # a low macOS default can also starve parallel dub/ldc builds.
              ulimit -n ${toString d-toolchain.nofileLimit} 2>/dev/null || true

              ${envExports}
            '';
          };

          # `shader-compile`, which sparkles:ui's `gpu-effects` configuration
          # runs as a pre-generate step — so every build selecting it needs
          # this: the dcompute-enabled LDC compiles a package's `@compute`
          # modules to SPIR-V, spirv-tools validate and optimise it,
          # spirv-cross turns it into GLSL and glslang proves each file.
          # (glslang also regenerates the committed `.spv` under
          # `libs/vulkan-wsi/src/shaders/`.) The LDC is `ldc2-vulkan` — the
          # name `shader-compile` looks for, and one that cannot shadow the
          # shell's own `ldc2` — wherever dlang.nix defines it.
          shaders = feature {
            packages = [
              pkgs.glslang
              pkgs.spirv-tools
              pkgs.spirv-cross
            ]
            ++ lib.optional (config.packages ? ldc2-vulkan) config.packages.ldc2-vulkan;
          };

          # wasm-ld, for the test runner's `--wasm` mode: nixpkgs' LDC is
          # built without -link-internally, so the wasm32 link needs an
          # external linker. Without it the mode skips rather than runs (and
          # `--require-toolchain` turns that skip into a failure). The wasm
          # runtime it hands off to is `base`'s node.
          wasm = feature { packages = [ pkgs.lld ]; };

          # ghostty — the slim repack (shared lib + headers + .pc), NOT the
          # upstream `.dev` output: its static archive embeds zig store paths
          # in debug info, dragging a 1.5 GiB toolchain closure into the
          # shell. See nix/packages/libghostty-vt.nix.
          ghostty = feature { packages = [ config.packages.libghostty-vt ]; };

          # Nix C API — bound by `sparkles:nix` via ImportC. Only the `out`
          # outputs (the .so's) are packages, for linking; the headers come
          # via PKG_CONFIG_PATH (see nixCApiPkgConfigPath above) so the
          # patched nix-expr-c headers are used and the unpatched ones never
          # reach NIX_CFLAGS_COMPILE.
          nix-c-api = feature {
            packages = [
              inputs'.nix.packages.nix-util-c
              inputs'.nix.packages.nix-store-c
              inputs'.nix.packages.nix-expr-c
              inputs'.nix.packages.nix-fetchers-c
              inputs'.nix.packages.nix-flake-c
              inputs'.nix.packages.nix-main-c
            ];
            hook = ''
              export PKG_CONFIG_PATH="${nixCApiPkgConfigPath}''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
            '';
          };

          # tree-sitter runtime for sparkles:tree-sitter / sparkles:syntax
          # (single-output: headers + .so + .pc all in `out`), and the
          # grammar bundle (one dir per language: parser + queries/). Tests
          # skip when the path is unset.
          tree-sitter = feature {
            packages = [ pkgs.tree-sitter ];
            hook = ''
              export SPARKLES_TS_GRAMMAR_PATH=${config.packages.ts-grammars}
            '';
          };

          # `libs "raylib"`, and raylib-text's ImportC shaping bridge.
          raylib = feature {
            packages = [
              pkgs.raylib
              pkgs.freetype
              pkgs.freetype.dev
              pkgs.harfbuzz
              pkgs.harfbuzz.dev
            ];
          };

          # `libs "vulkan"`. The `.dev` output carries `vulkan.pc`, whose
          # `includedir` points at vulkan-headers — so one pkg-config entry
          # supplies both the ImportC include path and the link flags.
          # MoltenVK is Darwin's Vulkan ICD (Vulkan-on-Metal): the loader is
          # only dispatch; without it vkCreateInstance fails with
          # VK_ERROR_INCOMPATIBLE_DRIVER / an empty device list.
          vulkan = feature {
            packages = [
              pkgs.vulkan-loader
              pkgs.vulkan-loader.dev
            ]
            ++ lib.optional isDarwin pkgs.moltenvk;
            hook = lib.optionalString isDarwin ''
              # Defaulted rather than assigned: testing against a locally
              # built MoltenVK is the reason someone would set it first.
              export VK_DRIVER_FILES="''${VK_DRIVER_FILES:-${pkgs.moltenvk}/share/vulkan/icd.d/MoltenVK_icd.json}"
              # The pre-1.3.207 spelling, for a system loader older than the
              # rename; the nixpkgs one reads VK_DRIVER_FILES.
              export VK_ICD_FILENAMES="$VK_DRIVER_FILES"
            '';
          };

          # `libs "sdl3"` in libs/ui-sdl3. `.dev` carries `sdl3.pc`; `.lib` is
          # what the built binary loads at runtime.
          sdl3 = feature {
            packages = [
              pkgs.sdl3
              pkgs.sdl3.dev
            ];
          };

          # libs/wsi's Linux backends: XCB (with XTEST, XInput, XKB and
          # fcitx's XIM-over-XCB client), Wayland and xkbcommon, plus what
          # the OS-API research examples link. pkg-config resolves the
          # headers via the `.dev` outputs (dub#3085 feeds `--cflags` to
          # ImportC). xcb-imdkit's .pc requires xcb-util.
          wsi-linux = feature {
            packages = linux [
              pkgs.libx11
              pkgs.libx11.dev
              pkgs.xorgproto
              pkgs.wayland
              pkgs.wayland.dev
              pkgs.wayland-protocols
              pkgs.wayland-scanner
              pkgs.libxkbcommon
              pkgs.libxkbcommon.dev
              pkgs.libxext
              pkgs.libxext.dev
              pkgs.libxi
              pkgs.libxi.dev
              pkgs.libxfixes
              pkgs.libxfixes.dev
              pkgs.libxcursor
              pkgs.libxcursor.dev
              pkgs.libxrandr
              pkgs.libxrandr.dev
              pkgs.libxcb
              pkgs.libxcb.dev
              pkgs.xcb-imdkit
              pkgs.xorg.xcbutil
              pkgs.xorg.xcbutil.dev
            ];
          };

          # The windowing demos run for real: X11 under Xvfb, Wayland under a
          # headless weston. Without them the demos print SKIP and the job
          # goes green having verified nothing.
          xvfb = feature { packages = linux [ pkgs.xvfb-run ]; };
          weston = feature { packages = linux [ pkgs.weston ]; };

          # CPU-PMU research probes (docs/research/cpu-pmu/examples): `libs
          # "dw" "elf"` and `libs "pfm"`. Neither is found by `nix shell`
          # alone (no setup hooks run), hence the explicit library paths.
          perf-probes = feature {
            packages = linux [
              pkgs.elfutils
              pkgs.libpfm
            ];
            hook = lib.optionalString isLinux (libraryPath [
              pkgs.elfutils.out
              pkgs.libpfm
            ]);
          };

          # mheily/libkqueue for event-horizon's `libkqueue` config (`libs
          # "kqueue"`; fiber-echo `-c libkqueue`). Same package the Android
          # build cross-compiles the source of.
          kqueue = feature {
            packages = linux [ pkgs.libkqueue ];
            hook = lib.optionalString isLinux (libraryPath [ pkgs.libkqueue ]);
          };

          # Sanitizers research probes (docs/research/sanitizers/examples):
          # the valgrind-*.d probes exec `valgrind` from PATH and print a SKIP
          # line when it is absent. The `nix run .#ci` wrapper deliberately
          # omits it to keep the .#ci closure small.
          valgrind = feature { packages = linux [ pkgs.valgrind ]; };

          # `setsid`, exec'd by event-horizon's supervision tests (a
          # descendant in its own session).
          util-linux = feature { packages = linux [ pkgs.util-linux ]; };

          # `dbus-daemon`, exec'd by apps/terminal's D-Bus tests as a private
          # bus with a fake notification server and portal.
          dbus = feature { packages = linux [ pkgs.dbus ]; };

          # ── corpora: tests skip when their variable is unset ──

          # Raw flake-input store paths (`SPARKLES_FLAKE_INPUT_*` plus the
          # `$SPARKLES_ALL_FLAKE_INPUTS` JSON map). dmd-fmt corpus tests
          # assert `$SPARKLES_FLAKE_INPUT_DMD_SRC` exists.
          flake-inputs = feature { hook = flakeInputExports; };

          # Nerd Fonts glyphnames.json for the icon table (GLY4).
          nerd-font-glyphnames = feature {
            hook = ''
              export SPARKLES_NERD_FONT_GLYPHNAMES=${config.packages.nerd-font-glyphnames}
            '';
          };

          # JSONTestSuite conformance corpora for the wired JSON reader.
          json-test-suite = feature {
            hook = ''
              export JSON_TEST_SUITE=${config.packages.json-test-suite}
              export NATIVEJSON_TEST_SUITE=${config.packages.nativejson-test-suite}
            '';
          };

          # The bundled fonts, the corpus for sparkles:font and its HarfBuzz
          # oracle.
          fonts = feature {
            hook = ''
              export SPARKLES_FONTS_PATH=${config.packages.sparkles-fonts}/fonts
            '';
          };

          # druntime/phobos sources matching the pinned dmd:frontend, for
          # sparkles:dmd-lsp semantic analysis (BLD3), and the dcompute LDC's,
          # for its LDC profiles — shader (device) code imports
          # `ldc.dcompute` (TGT3).
          d-import-paths = feature {
            hook = ''
              export SPARKLES_DMD_IMPORT_PATH=${config.packages.dmd-import-paths}/druntime:${config.packages.dmd-import-paths}/phobos
            ''
            + lib.optionalString (config.packages ? ldc-import-paths) ''
              export SPARKLES_LDC_IMPORT_PATH=${config.packages.ldc-import-paths}/druntime:${config.packages.ldc-import-paths}/phobos
            '';
          };
        };

      # A feature subset as packages and a hook. `names` is a list of feature
      # names, or null for all of them.
      ciTier =
        {
          ciTool,
          names ? null,
        }:
        let
          all = ciFeatures ciTool;
          # `flake-input:<name>` is one input of `flake-inputs`: a test that
          # reads one checkout need not download every input's source.
          oneInput =
            n:
            let
              input = lib.removePrefix "flake-input:" n;
            in
            if lib.hasPrefix "flake-input:" n && flakeInputPaths ? ${input} then
              {
                packages = [ ];
                hook = "export ${flakeInputEnvName input}=${lib.escapeShellArg flakeInputPaths.${input}}";
              }
            else
              null;
          lookup = n: all.${n} or (oneInput n);
          unknown = builtins.filter (n: lookup n == null) (if names == null then [ ] else names);
          chosen =
            if unknown != [ ] then
              throw "mkSparklesShell: unknown feature(s) ${lib.concatStringsSep ", " unknown}"
            else
              # `base` first: its hook seeds the dub cache the others' users
              # read. The rest sorted, so a shell is a function of the *set*.
              map lookup (
                [ "base" ]
                ++ lib.sort (a: b: a < b) (
                  lib.remove "base" (lib.unique (if names == null then builtins.attrNames all else names))
                )
              );
        in
        {
          packages = lib.concatMap (f: f.packages) chosen;
          hook = lib.concatMapStrings (f: f.hook + "\n") chosen;
        };

      devPackages = [
        # Pre-commit hooks
        pkgs.prek
        pkgs.lychee

        # Vulkan's validation layers, including synchronization validation —
        # the semaphore/fence reuse rules in `sparkles.ui_sdl3.frame` are the
        # kind that only a layer catches, and `--validation` is a no-op
        # without them installed.
        pkgs.vulkan-validation-layers

        # Profiling
        pkgs.tracy
        pkgs.capstone
        pkgs.mold

        # Independent oracle libraries for the text-conformance harness
        # (bindings under libs/base/tools/text-conformance/bindings). utf8proc
        # is single-output (headers + .pc in `out`); icu/notcurses carry their
        # pkg-config in the `.dev` output. Only the opt-in `oracles.sdl`
        # recipe needs these; CI gates official corpora offline.
        pkgs.utf8proc
        pkgs.icu
        pkgs.icu.dev
        notcursesCore
        notcursesCore.dev

        # Rust unicode-width oracle helper (Layer 9), built from the in-tree
        # crate under the harness's oracles/ dir.
        config.packages.uwidth-rs

        # wired runtime JSON bench: the cpp shim's `Requires: simdjson`
        # resolves against this simdjson.pc (generic build — simdjson
        # dispatches SIMD kernels at runtime, unlike the preset-built
        # engines wired up via the benchIsaHook below). The bench is not a
        # root sub-package either.
        pkgs.simdjson

        # Python + wcwidth for the PyD-embedded Layer 10.
        pythonEnv

        # terminal benchmarking: the third-party tools the harness pairs
        # with (see apps/terminal-benchmark/README.md)
        config.packages.vtebench
        config.packages.termbench
        pkgs.cmatrix
      ]
      ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
        # Headless Chromium for the sparkles:twoslash visual-regression check
        # (libs/twoslash/examples/visual-check.mjs): it lays out the rendered
        # HTML overlay and asserts popup geometry. Dev-only ($CHROME_BIN
        # exported below) — it is a .mjs, so neither `ci --example-files`
        # (which globs .d) nor any other job runs it.
        pkgs.chromium

        # perf is Linux-only; the harness/profiling flow is too (reads
        # /proc). Nothing execs the CLI — the probes call perf_event_open
        # directly and link libpfm — so this is for interactive profiling.
        pkgs.perf
      ];

      # ── Shell hooks ────────────────────────────────────────────────────

      # Deliberately NOT in the `ci` tier's hooks:
      #
      #   * `GITHUB_TOKEN` — `gh auth token` has no logged-in gh on a runner,
      #     so this resolves to the empty string and *overwrites* the token the
      #     job was given, quietly de-authenticating lychee's GitHub requests.
      #   * the bench/oracle corpora and PyD paths, whose packages are not in
      #     the ci tier at all.
      devShellHook = ''
        export GITHUB_TOKEN="$(gh auth token)"

        # Where the Khronos loader looks for explicit layers. The package is
        # inert without it: the loader searches system directories, and a nix
        # store path is not one of them, so `--validation` on the ui-sdl3
        # examples would silently enable nothing. Dev tier, not CI — no job
        # runs a Vulkan example, and interpolating the path here would pull
        # the layers into the CI shell's closure.
        #
        # Defaulted rather than assigned, so a developer testing against a
        # locally built layer can set it before entering the shell.
        export VK_LAYER_PATH="''${VK_LAYER_PATH:-${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d}"

        # Pinned corpora for the wired runtime JSON bench
        # (libs/wired/bench/runtime; its --data-dir flag overrides this).
        export WIRED_BENCH_DATA=${config.packages.wired-bench-data}

        ${benchIsaHook}

        # PyD-embedded Python (text-conformance Layer 10): make libpython
        # linkable and let the embedded interpreter find wcwidth + the stdlib.
        export LIBRARY_PATH="${pythonEnv}/lib''${LIBRARY_PATH:+:$LIBRARY_PATH}"
        export LD_LIBRARY_PATH="${pythonEnv}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        export PYTHONPATH="${pythonEnv}/${pythonEnv.sitePackages}''${PYTHONPATH:+:$PYTHONPATH}"

        ${lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
          # Browser for the sparkles:twoslash visual-regression check.
          export CHROME_BIN=${pkgs.chromium}/bin/chromium
        ''}
      '';

      # `ciTool` is a parameter so the CI module (nix/ci) can evaluate the same
      # shell around a stub `ci`: a job's laziness key must not change every
      # time one of the 23 libraries the helper links does. `features` picks
      # a subset of the `ci` tier (null: all of it) — what a CI job's units
      # need, and nothing else.
      mkSparklesShell =
        {
          greeting ? false,
          tier ? "dev",
          ciTool ? config.packages.ci,
          features ? null,
        }:
        let
          ci = ciTier {
            inherit ciTool;
            names = features;
          };
        in
        pkgs.mkShell {
          packages =
            ci.packages
            ++ lib.optionals (tier == "dev") (devPackages ++ d-toolchain.devPackages)
            ++ lib.optional greeting pkgs.figlet;

          shellHook =
            ci.hook
            + lib.optionalString (tier == "dev") devShellHook
            + lib.optionalString greeting "figlet 'sparkles : *'\n"
            # Installs the git hooks into .git/. Wanted on a developer's
            # checkout, pointless on a runner that clones once and throws the
            # tree away — and it is what drags prek into the closure.
            + lib.optionalString (tier == "dev") config.pre-commit.installationScript;
        };
    in
    {
      devShells = {
        # Quiet shell for non-interactive use (LLM agents, scripts).
        default = mkSparklesShell { };
        # Full shell for interactive use — adds the figlet greeting on entry.
        full = mkSparklesShell { greeting = true; };
        # The CI floor: no browser, no profilers, no benchmark corpora, no
        # oracle libraries, no pre-commit tooling. See `ciFeatures` above.
        ci = mkSparklesShell { tier = "ci"; };
      };

      # For nix/ci, which runs a subset of the `ci` tier as each CI job's
      # environment.
      legacyPackages.mkSparklesShell = mkSparklesShell;
      # The same Yarn, for CI steps that need node and nothing of the tier.
      legacyPackages.yarn = yarn;
    };
}
