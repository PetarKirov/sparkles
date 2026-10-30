{ inputs, ... }:
{
  perSystem =
    {
      config,
      inputs',
      pkgs,
      ...
    }:
    let
      inherit (config.legacyPackages) nativeLibs;
      inherit (pkgs) lib;
      inherit (config.legacyPackages) d-toolchain nixCApi textOracles;
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

      # ── Package tiers ──────────────────────────────────────────────────
      #
      # `ciPackages` is the floor: exactly what `ci --test`,
      # `ci --example-files` and `ci --test-extracted` need in order to *run*
      # rather than skip. Everything else is interactive-only and lives in
      # `devPackages`, because CI pays for it in download time on every cold
      # runner — chromium alone is a 1.7 GiB closure, and nothing in CI opens
      # a browser.
      #
      # The rule for moving something up: it belongs in `ciPackages` if a CI
      # job links it, execs it, or degrades to a skip without it.

      ciPackages = [
        # Used by :test-utils for diff output on a failing assertion.
        pkgs.delta

        # `shader-compile`, which sparkles:ui's `gpu-effects` configuration runs
        # as a pre-generate step — so every build on `ui-raylib`, `ci --test`
        # included, needs it: the dcompute-enabled LDC compiles a package's
        # `@compute` modules to SPIR-V, spirv-tools validate and optimise it,
        # spirv-cross turns it into GLSL and glslang proves each file. (glslang
        # also regenerates the test pattern's committed `.spv` under
        # `libs/vulkan-wsi/src/shaders/`.)
        pkgs.glslang
        pkgs.spirv-tools
        pkgs.spirv-cross
      ]
      # The dcompute-enabled LDC itself, as `ldc2-vulkan` — the name
      # `shader-compile` looks for, and one that cannot shadow the shell's own
      # `ldc2`.
      ++ [ config.packages.ldc2-vulkan ]
      # `fc-list`, the oracle the font platform listing (FTD18) is compared
      # with, from the same fontconfig the test loads ($SPARKLES_FONTCONFIG_LIB);
      # without it the comparison skips.
      ++ lib.optional (pkgs.stdenv.hostPlatform.isLinux || pkgs.stdenv.hostPlatform.isFreeBSD) (
        lib.getBin pkgs.fontconfig
      )
      ++ [
        # lld, which links D programs on Linux, and node, which runs the
        # test runner's `--wasm-bare` modules and the WebAssembly modules'
        # agreement check.
        pkgs.lld-sparkles
        pkgs.nodejs
        # The test runner's `--wasm` runs the `@wasm` tests' WASI program here
        # (WTD27); the WASI LDC it compiles with is `$SPARKLES_WASI_LDC`.
        pkgs.wasmtime
        # Yarn Berry 4 for the VitePress site (`yarn docs:build`) and the
        # twoslash fixture generator. `package.json#packageManager` selects
        # the release. `corepack enable` cannot write shims into the Nix
        # store, so this is a Corepack passthrough named `yarn`.
        (pkgs.writeShellScriptBin "yarn" ''
          export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
          exec ${pkgs.nodejs}/bin/corepack yarn "$@"
        '')

        # CI helper — the `ci --test` / `ci --example-files` the jobs invoke.
        pkgs.curl # libcurl, linked by its --ci-stats subcommand
        config.packages.ci

        # ghostty — the slim repack (shared lib + headers + .pc), NOT the
        # upstream `.dev` output: its static archive embeds zig store
        # paths in debug info, dragging a 1.5 GiB toolchain closure into
        # the shell. See nix/packages/libghostty-vt.nix.
        # `libs "ghostty-vt"` in libs/ghostty/dub.sdl.
        pkgs.pkg-config
        config.packages.libghostty-vt

      ]
      # The Nix C API `sparkles:nix` binds (nix/shells/nix-c-api.nix): `ci
      # --test` links `:nix`, so this is the CI floor, not the interactive tier.
      ++ nixCApi.libs
      ++ [
        # tree-sitter runtime for sparkles:tree-sitter / sparkles:syntax
        # (single-output: headers + .so + .pc all in `out`). Grammars come
        # from the ts-grammars bundle via $SPARKLES_TS_GRAMMAR_PATH below.
        # `libs "tree-sitter"` in libs/tree-sitter/dub.sdl.
        pkgs.tree-sitter

        # `libs "raylib"` in libs/raylib-text and apps/terminal.
        pkgs.raylib
      ]
      # raylib-text's shaping libraries and the Vulkan loader
      # (nix/packages/native-libs.nix).
      ++ nativeLibs.shaping
      ++ nativeLibs.vulkan
      ++ [
        # `libs "sdl3"` in libs/ui-sdl3: the window, the input source, and the
        # Vulkan surface. `.dev` carries `sdl3.pc`; `.lib` is what the built
        # binary loads at runtime.
        pkgs.sdl3
        pkgs.sdl3.dev
      ]
      # OS-API research examples (docs/research/.../os-apis): the X11 and Wayland
      # ImportC examples are **Linux-only**, so gate these on Linux — `wayland`,
      # `libx11`, etc. refuse to evaluate on darwin. pkg-config (above) resolves
      # the headers via the `.dev` outputs (dub#3085 feeds `--cflags` to ImportC);
      # `xvfb-run` lets the X11 example open a real window on a headless runner.
      ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
        pkgs.libx11
        pkgs.libx11.dev
        pkgs.xorgproto
        pkgs.wayland
        pkgs.wayland.dev
        pkgs.xvfb-run

        # CPU-PMU research probes (docs/research/cpu-pmu/examples): the
        # symbolization/unwind probes link `libs "dw" "elf"` and the
        # event-naming probe links `libs "pfm"`. Neither library is found
        # by `nix shell` alone (no setup hooks run), so they're shell
        # packages here with LIBRARY_PATH/LD_LIBRARY_PATH exports below.
        # `ci --example-files` builds these, so a missing library is a
        # link error, not a skip.
        pkgs.elfutils
        pkgs.libpfm

        # Sanitizers research probes (docs/research/sanitizers/examples):
        # the valgrind-*.d probes exec `valgrind` from PATH (never link it)
        # and print a SKIP line when it is absent. `ci --example-files`
        # runs them, so this is here to keep three examples from silently
        # degrading to SKIP in CI — the `nix run .#ci` wrapper deliberately
        # omits it to keep the .#ci closure small.
        pkgs.valgrind

        # mheily/libkqueue for event-horizon's `libkqueue` config
        # (`libs "kqueue"`; fiber-echo `-c libkqueue`). Same package the
        # Android build cross-compiles the source of.
        pkgs.libkqueue

        # Windowing feature demos (os-apis/<platform>/examples/): the CI job
        # builds and RUNS these (xvfb for X11, a headless weston for Wayland),
        # so they are the ci tier, not dev: without weston the Wayland demos
        # print SKIP and the job goes green having verified nothing.
        pkgs.weston
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

        # fcitx's XIM-over-XCB library: `libs "xcb-imdkit"` in libs/wsi —
        # the X11 backend's XIM client, and the lane's test XIM server,
        # both over the backend's single XCB connection. Its .pc requires
        # xcb-util, so pkg-config needs that too.
        pkgs.xcb-imdkit
        pkgs.libxcb-util
        pkgs.libxcb-util.dev

        # `dbus-daemon`, exec'd by apps/terminal's D-Bus tests (`dbus_conn`,
        # `desktop_bus`) as a private bus with a fake notification server
        # and portal. Without it they skip, so `ci --test` needs it.
        pkgs.dbus
      ]
      ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
        # MoltenVK is Darwin's Vulkan ICD (Vulkan-on-Metal). The loader
        # above is only dispatch; without this, vkCreateInstance fails
        # with VK_ERROR_INCOMPATIBLE_DRIVER / an empty device list.
        # `VK_DRIVER_FILES` in the hook points the loader at the ICD json.
        pkgs.moltenvk
      ];

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

      ]
      # The text-conformance harness's oracle libraries
      # (nix/shells/text-oracles.nix).
      ++ textOracles.libraries
      ++ [
        # wired runtime JSON bench: the cpp shim's `Requires: simdjson`
        # resolves against this simdjson.pc (generic build — simdjson
        # dispatches SIMD kernels at runtime, unlike the preset-built
        # engines wired up via `wiredBenchIsaHook` below). The bench is not a
        # root sub-package either.
        pkgs.simdjson

        # BLAKE3 reference bench (libs/base/bench/blake3, not a root
        # sub-package): the official C implementation, with its own runtime
        # SIMD dispatch; `libblake3.pc` and the header are in `.dev`.
        pkgs.libblake3
        pkgs.libblake3.dev

        # Python + wcwidth for the PyD-embedded Layer 10.
        textOracles.pythonEnv

        # terminal benchmarking: the third-party tools the harness pairs
        # with (see apps/terminal-benchmark/README.md)
        config.packages.vtebench
        pkgs.cmatrix
      ]
      # Not on Linux arm64 (nix/packages/bench-tools.nix).
      ++ lib.optional (config.packages ? termbench) config.packages.termbench
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

      # ── Shell hooks, split on the same seam ────────────────────────────

      ciShellHook = ''
        # Seed writable sources, preserving any existing user versions. The
        # packaged helper retains the bundle through its runtime closure.
        export SPARKLES_DUB_SOURCES=${config.packages.dub-sources}
        # The LDC with the WASI runtimes: the test runner's `--wasm` and the
        # WebAssembly modules' builds (`ci --build`).
        export SPARKLES_WASI_LDC=${lib.getExe' inputs'.dlang-nix.packages.ldc-sparkles "ldc2"}
        ${lib.getExe config.packages.ci} --seed-dub-cache >/dev/null 2>&1 || {
          echo 'Failed to seed DUB sources; run ci --seed-dub-cache for details.' >&2
          return 1
        }

        # Keep D's std.process child setup inside the signed-int range.
        # Phobos casts RLIMIT_NOFILE from rlim_t to int before closing
        # inherited descriptors; an unlimited soft limit overflows, and a
        # low macOS default can also starve parallel dub/ldc builds. This
        # was part of the original Darwin toolchain workaround but was
        # lost when the dev shell moved behind the shared toolchain module.
        ${d-toolchain.nofileCommand}

        ${d-toolchain.shellExports}

        # Raw flake-input store paths (`SPARKLES_FLAKE_INPUT_*` plus the
        # `$SPARKLES_ALL_FLAKE_INPUTS` JSON map). dmd-fmt corpus tests assert
        # `$SPARKLES_FLAKE_INPUT_DMD_SRC` exists — dropping this fails them.
        ${flakeInputExports}

        # Supply the Nix C API headers via pkg-config only (patched expr
        # first); see nix/shells/nix-c-api.nix. Must live in the CI hook so
        # `dub test :nix` ImportC sees the headers.
        export PKG_CONFIG_PATH="${nixCApi.pkgConfigPath}''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

        # tree-sitter grammar bundle for sparkles:syntax (one dir per
        # language: parser + queries/). Tests skip when unset.
        export SPARKLES_TS_GRAMMAR_PATH=${config.packages.ts-grammars}

        # Nerd Fonts glyphnames.json for the icon table (GLY4); the
        # sparkles:ui check skips when unset.
        export SPARKLES_NERD_FONT_GLYPHNAMES=${config.packages.nerd-font-glyphnames}

        # JSONTestSuite conformance corpus for the wired native JSON
        # reader (dub test :wired skips those tests when unset).
        export JSON_TEST_SUITE=${config.packages.json-test-suite}
        export NATIVEJSON_TEST_SUITE=${config.packages.nativejson-test-suite}

        # The bundled fonts, the corpus for sparkles:font and its HarfBuzz
        # oracle (dub test :font / :font-oracle skip those tests when unset).
        export SPARKLES_FONTS_PATH=${config.packages.sparkles-fonts}/fonts
        # Test-only faces (variable CFF2) the bundle does not ship.
        export SPARKLES_FONT_TEST_CORPUS=${config.packages.sparkles-font-test-corpus}
        ${lib.optionalString (pkgs.stdenv.hostPlatform.isLinux || pkgs.stdenv.hostPlatform.isFreeBSD) ''
          # fontconfig, which the platform listing (FTD18) loads at run time
          # rather than links (FTA7). A Nix store has no global library path,
          # so a bare dlopen("libfontconfig.so.1") from a test binary fails;
          # the listing test passes this path instead, and skips when unset.
          export SPARKLES_FONTCONFIG_LIB=${lib.getLib pkgs.fontconfig}/lib/libfontconfig.so.1
        ''}
        # The UCD release HarfBuzz's USE table was generated from (14.6.0 reads
        # DerivedCoreProperties-17.0.0): the FTS8 manifest check compares its
        # Default_Ignorable_Code_Point set with base's 18.0.0.
        export SPARKLES_HARFBUZZ_USE_UCD=${pkgs.unicode-character-database}/share/unicode

        # druntime/phobos sources matching the pinned dmd:frontend, for
        # sparkles:dmd-lsp semantic analysis (BLD3). Tests skip when unset.
        export SPARKLES_DMD_IMPORT_PATH=${config.packages.dmd-import-paths.importPath}

        # The dcompute LDC's druntime/phobos sources, for sparkles:dmd-lsp's
        # LDC profiles — shader (device) code imports `ldc.dcompute` (TGT3).
        export SPARKLES_LDC_IMPORT_PATH=${config.packages.ldc-import-paths.importPath}

        ${lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
          # libdw/libelf (elfutils), libpfm, libkqueue — for `dub run --single`
          # linking (`libs "dw" "elf"` / `libs "pfm"` / `libs "kqueue"`).
          export LIBRARY_PATH="${d-toolchain.libraryPath}''${LIBRARY_PATH:+:$LIBRARY_PATH}"
          export LD_LIBRARY_PATH="${d-toolchain.libraryPath}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        ''}

        ${lib.optionalString pkgs.stdenv.hostPlatform.isDarwin ''
          # Khronos loader looks here for ICDs. The json's library_path is
          # already the absolute nix store path of libMoltenVK.dylib.
          #
          # Defaulted rather than assigned: every other export in this hook is
          # a store path a developer has no reason to override, but this one
          # they do — testing against a locally built MoltenVK is the whole
          # reason someone would set it before entering the shell.
          export VK_DRIVER_FILES="''${VK_DRIVER_FILES:-${pkgs.moltenvk}/share/vulkan/icd.d/MoltenVK_icd.json}"

          # The pre-1.3.207 spelling of the same variable, kept for a system
          # loader older than the rename; the nixpkgs one reads VK_DRIVER_FILES.
          export VK_ICD_FILENAMES="$VK_DRIVER_FILES"
        ''}
      '';

      # Deliberately NOT in ciShellHook:
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

        ${config.legacyPackages.wiredBenchIsaHook}

        # PyD-embedded Python (text-conformance Layer 10): make libpython
        # linkable and let the embedded interpreter find wcwidth + the stdlib.
        export LIBRARY_PATH="${textOracles.pythonEnv}/lib''${LIBRARY_PATH:+:$LIBRARY_PATH}"
        export LD_LIBRARY_PATH="${textOracles.pythonEnv}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        export PYTHONPATH="${textOracles.pythonEnv}/${textOracles.pythonEnv.sitePackages}''${PYTHONPATH:+:$PYTHONPATH}"

        ${lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
          # Browser for the sparkles:twoslash visual-regression check.
          export CHROME_BIN=${pkgs.chromium}/bin/chromium
        ''}
      '';

      mkSparklesShell =
        {
          greeting ? false,
          tier ? "dev",
        }:
        pkgs.mkShell {
          packages =
            ciPackages
            ++ lib.optionals (tier == "dev") devPackages
            ++ lib.optional greeting pkgs.figlet
            ++ d-toolchain.packages;

          shellHook =
            ciShellHook
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
        # oracle libraries, no pre-commit tooling. See `ciPackages` above.
        ci = mkSparklesShell { tier = "ci"; };
      };
    };
}
