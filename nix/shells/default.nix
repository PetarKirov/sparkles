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

        src = pkgs.fetchPypi {
          inherit pname version;
          hash = "sha256-kfvvlyBLlqPU1CFgm4A0C3YM8z4m2hI/8kPXax/ajdo=";
        };

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
      mkSparklesShell =
        greeting:
        pkgs.mkShell {
          packages = [
            # Pre-commit hooks
            pkgs.prek
            pkgs.lychee
            # Used by :test-utils package
            pkgs.delta
            # Profiling
            pkgs.tracy
            pkgs.capstone
            pkgs.mold
            # Documentation site
            pkgs.nodejs
            # CI helper (markdown examples, standalone examples, link maintenance)
            config.packages.ci

            # libcurl — linked by the gen_unicode_tables generator tool
            # (libs/base/tools), which fetches UCD files via std.net.curl.
            pkgs.curl

            # ghostty — the slim repack (shared lib + headers + .pc), NOT the
            # upstream `.dev` output: its static archive embeds zig store
            # paths in debug info, dragging a 1.5 GiB toolchain closure into
            # the shell. See nix/packages/libghostty-vt.nix.
            pkgs.pkg-config
            config.packages.libghostty-vt

            # Independent oracle libraries for the text-conformance harness
            # (bindings under libs/base/tools/text-conformance/bindings). utf8proc
            # is single-output (headers + .pc in `out`); icu/notcurses carry their
            # pkg-config in the `.dev` output.
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
            # engines wired up via the benchIsaHook below).
            pkgs.simdjson

            # Python + wcwidth for the PyD-embedded Layer 10.
            pythonEnv

            # rendering
            pkgs.raylib
          ]
          # OS-API research examples (docs/research/.../os-apis): the X11 and Wayland
          # ImportC examples are **Linux-only**, so gate these on Linux — `wayland`,
          # `libx11`, etc. refuse to evaluate on darwin. pkg-config (above) resolves
          # the headers via the `.dev` outputs (dub#3085 feeds `--cflags` to ImportC);
          # `xvfb-run` lets the X11 example open a real window on a headless runner.
          ++ lib.optionals pkgs.stdenv.isLinux [
            pkgs.libx11
            pkgs.libx11.dev
            pkgs.xorgproto
            pkgs.wayland
            pkgs.wayland.dev
            pkgs.xvfb-run
          ]
          ++ lib.optional greeting pkgs.figlet
          ++ d-toolchain.packages;
          shellHook = ''
            ${envExports}
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

            ${lib.optionalString greeting "figlet 'sparkles : *'"}
          ''
          + config.pre-commit.installationScript;
        };
    in
    {
      devShells = {
        # Quiet shell for non-interactive use (LLM agents, scripts, CI).
        default = mkSparklesShell false;
        # Full shell for interactive use — adds the figlet greeting on entry.
        full = mkSparklesShell true;
      };
    };
}
