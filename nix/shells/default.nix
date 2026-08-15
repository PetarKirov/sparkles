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

      envExports = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}") d-toolchain.env
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

        # wasm-ld, for the test runner's `--wasm` mode: nixpkgs' LDC is
        # built without -link-internally, so the wasm32 link needs an
        # external linker. Without it the mode skips rather than runs
        # (and `--require-toolchain` turns that skip into a failure).
        # The wasm runtime it hands off to is `pkgs.nodejs` below.
        pkgs.lld
        pkgs.nodejs

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

        # tree-sitter runtime for sparkles:tree-sitter / sparkles:syntax
        # (single-output: headers + .so + .pc all in `out`). Grammars come
        # from the ts-grammars bundle via $SPARKLES_TS_GRAMMAR_PATH below.
        # `libs "tree-sitter"` in libs/tree-sitter/dub.sdl.
        pkgs.tree-sitter

        # `libs "raylib"` in libs/raylib-text and apps/terminal.
        pkgs.raylib

        # `libs "vulkan"` in libs/vulkan. The `.dev` output carries
        # `vulkan.pc`, whose `includedir` points at vulkan-headers — so one
        # pkg-config entry supplies both the ImportC include path and the link
        # flags. The headers alone would not be discoverable: vulkan-headers
        # ships no `.pc` of its own.
        pkgs.vulkan-loader
        pkgs.vulkan-loader.dev

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
      ];

      devPackages = [
        # Pre-commit hooks
        pkgs.prek
        pkgs.lychee
        # Profiling
        pkgs.tracy
        pkgs.capstone
        pkgs.mold

        # Independent oracle libraries for the text-conformance harness
        # (bindings under libs/base/tools/text-conformance/bindings). utf8proc
        # is single-output (headers + .pc in `out`); icu/notcurses carry their
        # pkg-config in the `.dev` output. Not a root sub-package, so no CI
        # job builds it.
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

      # ── Shell hooks, split on the same seam ────────────────────────────

      ciShellHook = ''
        # Keep D's std.process child setup inside the signed-int range.
        # Phobos casts RLIMIT_NOFILE from rlim_t to int before closing
        # inherited descriptors; an unlimited soft limit overflows, and a
        # low macOS default can also starve parallel dub/ldc builds. This
        # was part of the original Darwin toolchain workaround but was
        # lost when the dev shell moved behind the shared toolchain module.
        ulimit -n ${toString d-toolchain.nofileLimit} 2>/dev/null || true

        ${envExports}

        # tree-sitter grammar bundle for sparkles:syntax (one dir per
        # language: parser + queries/). Tests skip when unset.
        export SPARKLES_TS_GRAMMAR_PATH=${config.packages.ts-grammars}

        # JSONTestSuite conformance corpus for the wired native JSON
        # reader (dub test :wired skips those tests when unset).
        export JSON_TEST_SUITE=${config.packages.json-test-suite}
        export NATIVEJSON_TEST_SUITE=${config.packages.nativejson-test-suite}

        # druntime/phobos sources matching the pinned dmd:frontend, for
        # sparkles:dmd-lsp semantic analysis (BLD3). Tests skip when unset.
        export SPARKLES_DMD_IMPORT_PATH=${config.packages.dmd-import-paths}/druntime:${config.packages.dmd-import-paths}/phobos

        ${lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
          # libdw/libelf (elfutils), libpfm, libkqueue — for `dub run --single`
          # linking (`libs "dw" "elf"` / `libs "pfm"` / `libs "kqueue"`).
          export LIBRARY_PATH="${pkgs.elfutils.out}/lib:${pkgs.libpfm}/lib:${pkgs.libkqueue}/lib''${LIBRARY_PATH:+:$LIBRARY_PATH}"
          export LD_LIBRARY_PATH="${pkgs.elfutils.out}/lib:${pkgs.libpfm}/lib:${pkgs.libkqueue}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
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
