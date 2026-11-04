{
  nixConfig = {
    extra-substituters = [
      "https://sparkles.cachix.org"
      "https://dlang-community.cachix.org"
    ];
    extra-trusted-public-keys = [
      "sparkles.cachix.org-1:CPQ+GG8UKQCNUyvCrgZj8p7P+7cYqpjmGAmUPlLwbZc="
      "dlang-community.cachix.org-1:eAX1RqX4PjTDPCAp/TvcZP+DYBco2nJBackkAJ2BsDQ="
    ];
  };

  inputs = {
    nixpkgs.url = "github:PetarKirov/nixpkgs?ref=glfw3-3.5.1-nixos-unstable-2026-10-27";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      # Its `lib` from our nixpkgs, not a second, `nixpkgs.lib`-only checkout.
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    git-hooks-nix = {
      url = "github:cachix/git-hooks.nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-compat.follows = "flake-compat";
      };
    };

    systems.url = "github:nix-systems/triplet";

    dlang-nix = {
      # feat/ldc-sparkles: the project's one toolchain (toolchain spec TC1,
      # TC2). `ldc-vulkan` is the PetarKirov/ldc `sparkles/main` fork (LDC
      # master, dcompute's Vulkan target from ldc-developers/ldc#5132 and its
      # shader stages), built against `llvm-spirv-vulkan`, the
      # PetarKirov/llvm-project `sparkles/main` fork (LLVM main with
      # llvm/llvm-project#216919), whose clang, lld and compiler-rt build and
      # link everything else. `ldc-vulkan` is `pkgs.ldc` (nix/d-toolchain.nix)
      # and `ldc2-vulkan` (nix/packages/shader-compile.nix). As `ldc-sparkles`
      # it is the wasm modules' compiler, with a druntime/Phobos and a sysroot
      # built from source for each production WASI preview (`wasm32-wasip1`,
      # `wasm32-wasip2`); as `ldc-android`, the cross-compiler of the Android
      # libraries (aarch64 and x86_64) on Linux and macOS hosts, with
      # unstripped runtimes. Fold back once the upstream PRs and the forks'
      # commits land.
      url = "github:PetarKirov/dlang.nix/feat/ldc-sparkles";
      inputs = {
        # One nixpkgs for the toolchain and everything it builds: one glibc
        # and one GCC runtime in every closure (toolchain spec TC4).
        nixpkgs.follows = "nixpkgs";
        flake-compat.follows = "flake-compat";
        flake-parts.follows = "flake-parts";
        git-hooks-nix.follows = "git-hooks-nix";
      };
    };

    # nix-on-droid, for the terminal's Nix flavour (`terminal-nix-*`,
    # nix/packages/android/terminal-nix.nix): `lib.bootstrapPackages` builds
    # the bootstrap that app installs. The branch is the upstreamable one with
    # `build.androidAppId`, until a release branch has it.
    #
    # Its bootstrap builds from its own pinned `nixpkgs-for-bootstrap`, which
    # stays pinned (nix-on-droid fixes the proot-termux store paths to it).
    # Its `nixpkgs` and `nixpkgs-docs` serve only outputs we do not use (the
    # `nix-on-droid` CLI package, home-manager, the docs), so they follow ours
    # rather than locking two more nixpkgs.
    nix-on-droid = {
      url = "github:PetarKirov/nix-on-droid/feat/android-app-id";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.nixpkgs-docs.follows = "nixpkgs";
    };

    ghostty = {
      url = "github:ghostty-org/ghostty";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.systems.follows = "systems";
      inputs.flake-compat.follows = "flake-compat";
    };

    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };

    # --- third-party sources (flake = false; the locked rev is in flake.lock) ---

    glfw = {
      url = "github:PetarKirov/glfw/wayland-cursor-shape-v1";
      flake = false;
    };
    # Upstream nixpkgs at the commit the `nixpkgs` fork branches from. The
    # fork bumps glfw3 to 3.5.1; Darwin takes this tree's glfw3 recipe
    # instead, so raylib's GLFW (and every other consumer's) stays the one
    # cache.nixos.org already built. Keep it at the fork's merge base.
    nixpkgs-upstream-glfw = {
      url = "github:NixOS/nixpkgs/31ecbaca1bdefa45dffc409f0250bd8039ea0010";
      flake = false;
    };
    tree-sitter-d-src = {
      url = "github:PetarKirov/tree-sitter-d/feat/dub-single-file-injections";
      flake = false;
    };
    tree-sitter-sdl-src = {
      url = "github:PetarKirov/tree-sitter-sdl/v0.1.0";
      flake = false;
    };
    # Roboto's source repository, for its licence text: nixpkgs builds the
    # fonts from a release archive that carries none (docs/credits/parts/roboto.md).
    roboto-src = {
      url = "github:googlefonts/roboto-3-classic/v3.015";
      flake = false;
    };
    # Must stay in lockstep with nix/dub-lock.json's `dmd` entry (the frontend
    # the dmdserver-dub pin compiles against).
    dmd-src = {
      url = "github:PetarKirov/dmd/dmdserver-dub";
      flake = false;
    };
    # Tracks the dmd-src pin's VERSION.
    phobos-src = {
      url = "github:dlang/phobos/v2.113.0-beta.1";
      flake = false;
    };
    vtebench-src = {
      url = "github:alacritty/vtebench";
      flake = false;
    };
    termbench-src = {
      url = "github:PetarKirov/termbench";
      flake = false;
    };
    json-test-suite = {
      url = "github:nst/JSONTestSuite";
      flake = false;
    };
    # The compatibility oracle for sparkles.wired.sdl, not a production dependency.
    dub-sdl-src = {
      url = "github:dlang/dub/5efed360e1c9342453bc5dd19339c75981526d83";
      flake = false;
    };
    # PngSuite and libpng's own test images (contrib/pngsuite,
    # contrib/testpngs): the PNG decoder's differential corpus.
    libpng-src = {
      url = "github:pnggroup/libpng/v1.6.44";
      flake = false;
    };
    nativejson-benchmark = {
      url = "github:miloyip/nativejson-benchmark";
      flake = false;
    };
    # Locked to a pre-#1582 commit that still ships jsonexamples/.
    simdjson-src = {
      url = "github:simdjson/simdjson";
      flake = false;
    };
    # The shaping engine sparkles:font pins (docs/specs/font/SPEC.md FTS8):
    # the first release line whose Unicode data matches base's 18.0.0.
    harfbuzz-src = {
      url = "github:harfbuzz/harfbuzz/14.6.0";
      flake = false;
    };
    maple-font = {
      url = "github:subframe7536/maple-font/v7.9";
      flake = false;
    };
    maple-font-cn-base = {
      type = "file";
      url = "https://github.com/subframe7536/maple-font/releases/download/cn-base/cn-base-static.zip";
      flake = false;
    };
    ufo-extractor-wheel = {
      type = "file";
      url = "https://files.pythonhosted.org/packages/cd/cf/34b74c79439ac47ee16e129b709b1fe61ef20211175ac358a252ae50dd3b/ufo_extractor-0.8.1-py2.py3-none-any.whl";
      flake = false;
    };
    yyjson-src = {
      url = "github:ibireme/yyjson/0.12.0";
      flake = false;
    };
    # The upstream of `sparkles.base.expected` at the revision vendored into
    # libs/base: its licence text, for the credits (nix/packages/credits.nix).
    expected-src = {
      url = "github:tchaloupka/expected/0793e8b7dc06dd05b3fa3103e5a99bf0bfd5f638";
      flake = false;
    };
    # The upstream of `sparkles.event_horizon.sys.uring` at the revision vendored
    # into libs/event-horizon-sys: its licence text, for the credits.
    during-src = {
      url = "github:tchaloupka/during/3cd81909a4204b94da7de9f7b9d8e707a7360e74";
      flake = false;
    };
    wcwidth-src = {
      url = "https://files.pythonhosted.org/packages/source/w/wcwidth/wcwidth-0.8.2.tar.gz";
      flake = false;
    };

    # Dub registry zips (same pins as nix/dub-lock.json). `type = file` so
    # the zip stays a zip for the unzip sites in the Android / wasm builders.
    dub-raylib-d = {
      type = "file";
      url = "https://code.dlang.org/packages/raylib-d/6.0.1.zip";
      flake = false;
    };
    dub-optional = {
      type = "file";
      url = "https://code.dlang.org/packages/optional/1.3.1.zip";
      flake = false;
    };
    dub-bolts = {
      type = "file";
      url = "https://code.dlang.org/packages/bolts/1.3.1.zip";
      flake = false;
    };

    # Opt-in external benchmark datasets for sparkles:wired (see nix/packages/wired-bench-datasets.nix
    # and nix/flake-exclusions.nix). Kept out of the devshell closure.
    wired-bench-external-wikidata = {
      type = "file";
      url = "https://raw.githubusercontent.com/Wikidata-Toolkit/Wikidata-Toolkit/master/wdtk-dumpfiles/src/test/resources/mock-dump-for-long-testing.json";
      flake = false;
    };
    wired-bench-external-osm = {
      type = "file";
      url = "https://raw.githubusercontent.com/simdjson/simdjson-data/master/jsonexamples/marine_ik.json";
      flake = false;
    };
    wired-bench-external-cloudtrail = {
      type = "file";
      url = "https://raw.githubusercontent.com/simdjson/simdjson-data/master/jsonexamples/amazon_cellphones.ndjson";
      flake = false;
    };
    # Elastic's getting-started Bulk API body: action and source lines.
    wired-bench-external-elasticsearch = {
      type = "file";
      url = "https://raw.githubusercontent.com/elastic/elasticsearch/6d42e197b82aa1c98a1796d547e373f7029ee27a/docs/src/test/resources/accounts.json";
      flake = false;
    };
  };
  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.git-hooks-nix.flakeModule
        ./nix/d-toolchain.nix
        ./nix/packages/all.nix
        ./nix/packages/android
        ./nix/packages/build-sparkles-app.nix
        ./nix/packages/credits.nix
        ./nix/packages/default.nix
        ./nix/packages/dmd-import-paths.nix
        ./nix/packages/ldc-import-paths.nix
        ./nix/packages/dub-builder
        ./nix/packages/fonts.nix
        ./nix/packages/font-test-corpus.nix
        ./nix/packages/font-unfree-corpus.nix
        ./nix/packages/harfbuzz.nix
        ./nix/packages/freebsd-vm.nix
        ./nix/packages/hue.nix
        ./nix/packages/example-catalogue.nix
        ./nix/packages/run-all-examples.nix
        ./nix/packages/manifest-graph.nix
        ./nix/packages/build-info.nix
        ./nix/packages/native-libs.nix
        ./nix/packages/libghostty-vt.nix
        ./nix/packages/static-apps.nix
        ./nix/packages/shader-compile.nix
        ./nix/packages/android-dev-env-probe.nix
        ./nix/packages/ui-shaders.nix
        ./nix/packages/skia.nix
        ./nix/packages/wasm-modules.nix
        ./nix/packages/tree-sitter-d.nix
        ./nix/packages/tree-sitter-sdl.nix
        ./nix/packages/ts-grammars.nix
        ./nix/packages/nerd-font-glyphnames.nix
        ./nix/packages/twoslash-extract.nix
        ./nix/packages/uwidth-rs.nix
        ./nix/packages/wired-bench-data.nix
        ./nix/packages/json-test-suite.nix
        ./nix/packages/wired-bench-yyjson.nix
        ./nix/packages/wired-bench-cpp-shim.nix
        ./nix/packages/wired-bench-rs.nix
        ./nix/pin-targets.nix
        ./nix/checks/pre-commit.nix
        ./nix/checks/d-compiler.nix
        ./nix/shells/default.nix
        ./nix/shells/nix-c-api.nix
        ./nix/shells/text-oracles.nix
        ./nix/shells/android.nix
        ./nix/shells/win32-cross.nix
      ];
      systems = import inputs.systems;
    };
}
