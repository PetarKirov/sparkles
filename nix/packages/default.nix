{ lib, ... }:
{
  imports = [
    ./examples.nix
    ./bench-tools.nix
  ];

  perSystem =
    {
      config,
      pkgs,
      inputs',
      system,
      ...
    }:
    let
      inherit (config.legacyPackages) d-toolchain;

      # `ci` execs a D compiler at runtime to build the examples, so it lands in
      # ci's runtime closure (and every consumer's — pre-commit devShell, lint
      # CI). Prefer DMD on x86_64-linux for `--example-files` / `--test`: no
      # LLVM backend, so ~half LDC's closure. DMD only targets
      # x86_64/i686-linux + x86_64-darwin; keep LDC elsewhere. `--wasm`
      # (via `--test-extracted --require-toolchain`) still needs LDC +
      # wasm-ld + a runtime, so those go on PATH even when DMD is the
      # default compiler.
      ciCompiler = if system == "x86_64-linux" then pkgs.dmd else pkgs.ldc;

      # The LDC with the WASI runtimes: `--build` and `--build-each-commit`
      # compile the WebAssembly modules with it (`$SPARKLES_WASI_LDC`).
      wasiLdc = inputs'.dlang-nix.packages.ldc-sparkles;
    in
    {
      # Sources retained by ci's runtime closure and published with all-desktop.
      # Keep example-only dependencies out of normal application builds.
      packages.dub-sources = pkgs.importDubLock {
        pname = "sparkles";
        version = "sources";
        lock.dependencies =
          (lib.importJSON ../dub-lock.json).dependencies // (lib.importJSON ../ci-dub-lock.json).dependencies;
      };

      packages.ci = config.legacyPackages.buildSparklesApp (finalAttrs: {
        pname = "ci";
        version = "0.1.0";

        # `--audit-fences` classifies fence labels against the grammar bundle, so
        # `ci` now links sparkles:syntax -> sparkles:tree-sitter, whose ImportC
        # shim `#include`s <tree_sitter/api.h>. That header is found through
        # pkg-config (dub#3085 feeds `--cflags` to ImportC), so the resolver has
        # to be present at *build* time — without it the build dies on
        # "tree_sitter/api.h: No such file or directory", which also breaks the
        # dev shell, since it depends on this package.
        nativeBuildInputs = [ pkgs.pkg-config ];

        # Runtime deps subtracted from buildSparklesApp's default scrub set:
        # - `ciCompiler` — shells out via PATH (see postFixup)
        # - `pkgs.ldc` / `pkgs.lld` / `pkgs.nodejs` — `--test-extracted --wasm`
        # - `wasiLdc` — the WebAssembly modules' builds
        # - `pkgs.curl.out` — `--ci-stats` uses std.net.curl; Phobos bakes an
        #   absolute libcurl path
        # - `pkgs.tree-sitter` — `libs "tree-sitter"` in libs/tree-sitter
        buildInputs = [
          ciCompiler
          pkgs.ldc
          pkgs.lld-sparkles
          wasiLdc
          pkgs.nodejs
          pkgs.coreutils
          pkgs.curl.out
          pkgs.tree-sitter
        ];

        # ci shells out to `dub --single` at runtime to compile examples, so it
        # needs a D compiler + `dub` + git on PATH (via wrapProgram below).
        # gitMinimal avoids the second CPython that full git's git-p4 shebang pulls.
        postFixup =
          let
            path = lib.makeBinPath [
              ciCompiler
              pkgs.ldc
              pkgs.lld-sparkles
              pkgs.nodejs
              pkgs.wasmtime
              pkgs.dub
              pkgs.coreutils
              pkgs.gitMinimal
            ];
            # The toolchain env (non-empty on darwin: CC/CXX/SDKROOT/
            # MACOSX_DEPLOYMENT_TARGET).
            setEnv = lib.escapeShellArgs d-toolchain.wrapperArgs;
            # The examples link C libraries (the cpu-pmu research probes' `libs
            # "dw" "elf"` / `libs "pfm"`). Inside the devshell the shellHook
            # exports their paths (nix/shells); carry them in the wrapper too so
            # `nix run .#ci -- --example-files` links them outside any shell.
            inherit (d-toolchain) libraryPath;
            exampleLibArgs = lib.optionalString (
              libraryPath != ""
            ) "--prefix LIBRARY_PATH : ${libraryPath} --prefix LD_LIBRARY_PATH : ${libraryPath}";
          in
          # Best-effort bump of NOFILE: dub/ldc can open many files in parallel
          # builds.
          ''
            wrapProgram $out/bin/${finalAttrs.pname} \
              --prefix PATH : ${path} \
              --set-default SPARKLES_DUB_SOURCES ${config.packages.dub-sources} \
              --set-default SPARKLES_WASI_LDC ${lib.getExe' wasiLdc "ldc2"} \
              ${setEnv} \
              ${exampleLibArgs} \
              --run ${lib.escapeShellArg d-toolchain.nofileCommand}
          '';

        meta = {
          description = ''
            Repository CI helper for markdown examples, standalone examples, and
            markdown link maintenance
          '';
          mainProgram = finalAttrs.pname;
        };
      });

      # The same `ci` binary with nothing on PATH — for the subcommands that
      # only talk to an HTTP API and never exec a compiler.
      #
      # `packages.ci` is 1.4 GiB on x86_64-linux, and essentially none of it is
      # linked: the wrapper above puts the LDC with its LLVM (1.0 GiB), DMD
      # (529 MiB), lld (378 MiB, shared with the LDC's LLVM), nodejs (204 MiB)
      # and git on PATH so `--example-files` can compile markdown examples.
      # That is right for the job that runs examples and wrong for one that
      # files a check run: `main-checks.yml` sits on the merge path, so a
      # gigabyte-sized substitution there is paid on every merge to buy nothing.
      #
      # So: no `postFixup`, and `buildInputs` narrowed to the two genuine
      # runtime references — libcurl, whose absolute path Phobos bakes into
      # `std.net.curl`, and tree-sitter, which `--audit-fences` links. Everything
      # else returns to the scrub set it was exempted from.
      #
      # It builds `apps/ci` under its own name, so it names its `appDir`, from
      # which `buildSparklesApp` derives the source closure, the unpacked
      # directory to build in, and the binary dub emits (`build/ci`, installed
      # as `bin/ci-minimal`).
      packages.ci-minimal = config.legacyPackages.buildSparklesApp (finalAttrs: {
        pname = "ci-minimal";
        version = "0.1.0";

        appDir = "apps/ci";

        nativeBuildInputs = [ pkgs.pkg-config ];

        buildInputs = [
          pkgs.curl.out
          pkgs.tree-sitter
        ];

        meta = {
          description = ''
            Repository CI helper, unwrapped: the API-driven subcommands
            (--mirror-checks, --report-link-rot, --ci-stats) with no compiler
            toolchain in its closure
          '';
          mainProgram = finalAttrs.pname;
        };
      });

      packages.toolchain-pin-check = pkgs.stdenv.mkDerivation {
        pname = "toolchain-pin-check";
        version = "0.1.0";

        src = config.legacyPackages.sparklesSources.sourceFor (
          [
            "apps/ci/tools/check-pin-cache.d"
            "apps/ci/src/derivation_pin_set.d"
            "apps/ci/src/derivation_pin_cachix.d"
            "libs/core-cli/src"
          ]
          ++ config.legacyPackages.sparklesSources.libsClosure [ "base" ]
        );

        nativeBuildInputs = [
          pkgs.ldc
          pkgs.lld-sparkles
        ];

        buildInputs = [
          pkgs.curl.out
        ];

        buildPhase = ''
          ldc2 -O2 -preview=dip1000 -preview=in -i \
            -Iapps/ci/src \
            -Ilibs/base/src \
            -Ilibs/metadata/src \
            -Ilibs/reflection/src \
            -Ilibs/core-cli/src \
            -Ilibs/test-runner/src \
            -L-lcurl \
            -of=toolchain-pin-check \
            apps/ci/tools/check-pin-cache.d
        '';

        installPhase = ''
          mkdir -p $out/bin
          cp toolchain-pin-check $out/bin/
        '';

        meta = {
          description = "Check that all pinned toolchain outputs are in Cachix";
          mainProgram = "toolchain-pin-check";
        };
      };

      # Reuse the existing harness, with no foreign-oracle libraries or curl.
      # Foreign dependencies live in a separate opt-in recipe so DUB never
      # resolves them here; the shared builder provisions root manifests.
      packages.text-conformance = config.legacyPackages.buildSparklesApp (finalAttrs: {
        pname = "text-conformance";
        version = "0.1.0";
        sourceDirs = [
          "libs/base/tools/text-conformance/src"
        ]
        ++ config.legacyPackages.sparklesSources.libsClosure [
          "base"
          "core-cli"
        ];
        sourceRoot = "${finalAttrs.src.name}/libs/base/tools/text-conformance";
        dubBuildFlags = [ "--config=offline" ];
        meta = {
          description = "Offline manifest-authenticated owned Unicode conformance harness";
          mainProgram = finalAttrs.pname;
        };
      });

      # Provision every authenticated input before the sandboxed offline gate.
      # Only the reviewed manifest belongs to the source tree; fetchurl checks
      # each upstream file's exact SHA-256 before linkFarm preserves its path.
      packages.unicode-conformance-data =
        let
          manifestPath = ../../libs/base/tools/unicode/manifest.json;
          manifest = builtins.fromJSON (builtins.readFile manifestPath);
        in
        pkgs.linkFarm "unicode-conformance-data" (
          [
            {
              name = "manifest.json";
              path = manifestPath;
            }
          ]
          ++ map (artifact: {
            name = "${manifest.release}/${artifact.path}";
            path = pkgs.fetchurl {
              inherit (artifact) url sha256;
            };
          }) manifest.artifacts
        );

      # Ordinary sandboxed derivation: test execution has no network access,
      # and the offline executable has no downloader compiled in. D verifies
      # the manifest identity against the generated tables and each input hash.
      checks.text-conformance = pkgs.runCommand "text-conformance-official" { } ''
        set -o pipefail
        ${lib.getExe config.packages.text-conformance} \
          --layers 0,1,2,11,12,13,14,15,16 --no-network \
          --manifest ${config.packages.unicode-conformance-data}/manifest.json \
          --ucd-dir ${config.packages.unicode-conformance-data}/18.0.0 \
          | tee "$out"
      '';

      # `buildSparklesApp` derives the source closure from apps/terminal/dub.sdl
      # (transitively: base, core-cli, ghostty, math, and the test-runner
      # shim+impl) and supplies the shared dub plumbing, so only the raylib +
      # libghostty-vt build inputs and the fontconfig runtime wrapper remain.
      packages.terminal = config.legacyPackages.buildSparklesApp (finalAttrs: {
        pname = "terminal";
        version = "0.1.0";

        # The about page shows the commit (`TPG2`), so this package is
        # rebuilt (step 2 only) on every commit.
        stampBuildInfo = true;
        checkBuildInfo = config.legacyPackages.checkTerminalBuildInfo;

        nativeBuildInputs = [ pkgs.pkg-config ];

        buildInputs = [
          # The document viewer (`TDV`, sparkles:doc-view) highlights through
          # sparkles:syntax.
          pkgs.tree-sitter
          pkgs.raylib
          inputs'.ghostty.packages.libghostty-vt
          inputs'.ghostty.packages.libghostty-vt.dev
        ];

        links = config.legacyPackages.terminalLinks;

        # The credits page (`TPG15`), beside the executable: the document and
        # its staged licence texts, the files the docs site renders (`TPG16`).
        installPhase = ''
          install -Dm755 build/${finalAttrs.pname} $out/bin/${finalAttrs.pname}
          mkdir -p $out/share/sparkles-terminal
          cp -r ${config.legacyPackages.sparklesCredits.bundle} $out/share/sparkles-terminal/credits
        '';

        # The terminal shells out to `fc-match` (fontconfig) at runtime to
        # resolve fonts (see apps/terminal/src/app.d). Under `nix run` PATH is
        # the ambient user environment, so wrap the binary to guarantee
        # fontconfig is reachable instead of relying on the user's PATH.
        # Step 2 runs this, after the build-info section is replaced.
        postFixup = ''
          wrapProgram $out/bin/${finalAttrs.pname} \
            --set-default SPARKLES_TS_GRAMMAR_PATH ${config.packages.ts-grammars} \
            --prefix PATH : ${lib.makeBinPath [ pkgs.fontconfig ]}
        '';

        meta = {
          description = "A minimal terminal emulator using libghostty-vt";
          mainProgram = finalAttrs.pname;
        };
      });

      # Buttons on the terminal's about page, desktop and Android alike. The
      # document carries them; the page does not.
      legacyPackages.terminalLinks = {
        source = "https://github.com/PetarKirov/sparkles";
        docs = "https://sparkles.petar-kirov.dev/apps/terminal/";
        credits = "https://sparkles.petar-kirov.dev/credits/terminal";
      };

      # CPU benchmark harness for the terminal. Pure D + core-cli (it only spawns
      # terminal binaries handed to it and reads /proc), so no raylib/ghostty
      # build inputs and no runtime wrapper are needed — just the default
      # `buildSparklesApp` closure (core-cli → base, math, test-runner shim+impl).
      packages.terminal-benchmark = config.legacyPackages.buildSparklesApp (finalAttrs: {
        pname = "terminal-benchmark";
        version = "0.1.0";

        meta = {
          description = "CPU/throughput benchmark harness for the sparkles:terminal emulator";
          mainProgram = finalAttrs.pname;
        };
      });

      # The sparkles:ui catalog. It reaches raylib through `sparkles:ui-app`'s
      # `full` configuration — the gallery itself names no backend — so the
      # build inputs are the window's, not the application's. libghostty-vt is
      # the Terminal page's: it embeds `sparkles:terminal-view` (TVW7).
      # `fc-match` is on the same footing as the terminal's: the font set
      # shells out to it at runtime, and under `nix run` PATH is the ambient
      # user environment.
      packages.ui-gallery = config.legacyPackages.buildSparklesApp (finalAttrs: {
        pname = "ui-gallery";
        version = "0.1.0";

        nativeBuildInputs = [ pkgs.pkg-config ];
        buildInputs = [
          pkgs.raylib
          inputs'.ghostty.packages.libghostty-vt
          inputs'.ghostty.packages.libghostty-vt.dev
        ];

        postFixup = ''
          wrapProgram $out/bin/${finalAttrs.pname} \
            --prefix PATH : ${lib.makeBinPath [ pkgs.fontconfig ]}
        '';

        meta = {
          description = "A browsable catalog of the sparkles:ui toolkit, in a terminal or a window";
          mainProgram = finalAttrs.pname;
        };
      });

      # The native arm's builds (`configuration "vulkan"`): sparkles:wsi windows
      # drawn by sparkles:ui-vulkan, whose canvas SPIR-V comes prebuilt
      # (`ui-vulkan-shaders`). Packaged so the desktop aggregate compiles
      # them; `dub test` builds neither. raylib stays a build input: the
      # native host resolves its cell font through sparkles:raylib-text,
      # which links it, until sparkles:font's catalog replaces that.
      packages.ui-gallery-vulkan = config.legacyPackages.buildSparklesApp (finalAttrs: {
        pname = "ui-gallery-vulkan";
        version = "0.1.0";
        appDir = "apps/ui-gallery";
        dubBuildFlags = [ "--config=vulkan" ];

        nativeBuildInputs = [ pkgs.pkg-config ];
        buildInputs = [
          pkgs.raylib
          inputs'.ghostty.packages.libghostty-vt
          inputs'.ghostty.packages.libghostty-vt.dev
        ];

        meta = {
          description = "The sparkles:ui catalog on the native Vulkan arm";
          mainProgram = finalAttrs.pname;
        };
      });

      # The Vulkan canvas's text lab (`apps/text-lab`): the native arm only.
      packages.text-lab = config.legacyPackages.buildSparklesApp (finalAttrs: {
        pname = "text-lab";
        version = "0.1.0";
        appDir = "apps/text-lab";

        nativeBuildInputs = [ pkgs.pkg-config ];
        buildInputs = [ pkgs.raylib ];

        meta = {
          description = "The Vulkan canvas's text rendering, switched live and seen through a loupe";
          mainProgram = finalAttrs.pname;
        };
      });

      packages.terminal-vulkan = config.legacyPackages.buildSparklesApp (finalAttrs: {
        pname = "terminal-vulkan";
        version = "0.1.0";
        appDir = "apps/terminal";
        dubBuildFlags = [ "--config=vulkan" ];

        nativeBuildInputs = [ pkgs.pkg-config ];
        buildInputs = [
          pkgs.tree-sitter
          pkgs.raylib
          inputs'.ghostty.packages.libghostty-vt
          inputs'.ghostty.packages.libghostty-vt.dev
        ];

        meta = {
          description = "The terminal on the native Vulkan arm (text waits on the font atlas)";
          mainProgram = finalAttrs.pname;
        };
      });

      packages.release = config.legacyPackages.buildSparklesApp (finalAttrs: {
        pname = "release";
        version = "0.1.0";

        # Deliberately UNWRAPPED. `release` shells out to git, `gh`, `ci` and —
        # for the publishing stages — fdroidserver, a JDK, rclone and
        # bundletool. Bundling all of that would put a Python and JVM toolchain
        # into the closure of a tool most often run to create a tag, and CI
        # would download it just to build an APK.
        #
        # So the lean package is the binary alone and takes its tools from
        # PATH, which the dev shell (and CI's own steps) already provide. When
        # it needs something it cannot find, the stage-aware check in
        # `sparkles.release.store.tools` names the missing program and what it
        # was for, rather than failing three steps in.
        #
        # `release-full` below is the same binary with everything pinned, for
        # the workstation that actually publishes.
        meta = {
          description = ''
            Cut a sparkles release: scan tags, summarize commits, suggest a bump,
            write notes, tag and publish
          '';
          mainProgram = finalAttrs.pname;
        };
      });

      # The publishing configuration: `release` with every external program it
      # can invoke pinned by this repository rather than resolved from PATH.
      #
      # This is what signs and publishes, so "whatever version happens to be
      # installed" is the wrong answer for all of them — an fdroidserver or
      # apksigner picked up from the environment would decide the bytes users
      # install.
      packages.release-full = pkgs.symlinkJoin {
        name = "release-full-${config.packages.release.version}";
        paths = [ config.packages.release ];
        nativeBuildInputs = [ pkgs.makeWrapper ];
        postBuild =
          let
            path = lib.makeBinPath [
              pkgs.gitMinimal
              pkgs.gh
              config.packages.ci
              pkgs.fdroidserver
              # fdroidserver shells out to keytool, jarsigner and jar, and the
              # nixpkgs package wraps only apksigner onto PATH — `fdroid
              # update` fails outright without a JDK.
              pkgs.jdk_headless
              pkgs.apksigner
              pkgs.rclone
              # Builds the App Bundle for the Play channel.
              pkgs.bundletool
            ];
          in
          ''
            wrapProgram $out/bin/release --prefix PATH : ${path}
          '';
        meta = {
          description = "release, with every publishing tool pinned (signing workstation)";
          mainProgram = "release";
        };
      };
      # `nix run .#release-full` — the publishing configuration.

    };
}
