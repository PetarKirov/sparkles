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
    nixpkgs.url = "github:PetarKirov/nixpkgs?ref=glfw3-3.5.1";
    flake-parts.url = "github:hercules-ci/flake-parts";

    git-hooks-nix = {
      url = "github:cachix/git-hooks.nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-compat.follows = "flake-compat";
      };
    };

    systems.url = "github:nix-systems/triplet";

    dlang-nix = {
      # feat/ldc-wasm: extends feat/ldc-android (the `ldc-android` aarch64 cross-
      # compiler used by `devShells.android`) with the `ldc-wasm` wasm32-wasip2
      # toolchain consumed by `packages.text-wasm`. Revert toward the default
      # branch once these land upstream.
      url = "github:PetarKirov/dlang.nix/feat/ldc-wasm";
      inputs = {
        flake-compat.follows = "flake-compat";
        flake-parts.follows = "flake-parts";
        git-hooks-nix.follows = "git-hooks-nix";
      };
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
    tree-sitter-d-src = {
      url = "github:PetarKirov/tree-sitter-d/feat/dub-single-file-injections";
      flake = false;
    };
    tree-sitter-sdl-src = {
      url = "github:PetarKirov/tree-sitter-sdl/v0.1.0";
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
      url = "github:cmuratori/termbench";
      flake = false;
    };
    json-test-suite = {
      url = "github:nst/JSONTestSuite";
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
    ldc-windows-x64 = {
      type = "file";
      url = "https://github.com/ldc-developers/ldc/releases/download/v1.41.0/ldc2-1.41.0-windows-x64.7z";
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
    dub-expected = {
      type = "file";
      url = "https://code.dlang.org/packages/expected/0.4.1.zip";
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
  };
  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.git-hooks-nix.flakeModule
        ./nix/d-toolchain.nix
        ./nix/packages/all.nix
        ./nix/packages/android
        ./nix/packages/build-d-wasm-module.nix
        ./nix/packages/build-sparkles-app.nix
        ./nix/packages/default.nix
        ./nix/packages/dmd-import-paths.nix
        ./nix/packages/dub-builder
        ./nix/packages/fonts.nix
        ./nix/packages/hue.nix
        ./nix/packages/libghostty-vt.nix
        ./nix/packages/skia.nix
        ./nix/packages/text-wasm.nix
        ./nix/packages/table-wasm.nix
        ./nix/packages/tree-sitter-d.nix
        ./nix/packages/tree-sitter-sdl.nix
        ./nix/packages/ts-grammars.nix
        ./nix/packages/twoslash-extract.nix
        ./nix/packages/uwidth-rs.nix
        ./nix/packages/wired-bench-data.nix
        ./nix/packages/json-test-suite.nix
        ./nix/packages/wired-bench-yyjson.nix
        ./nix/packages/wired-bench-cpp-shim.nix
        ./nix/packages/wired-bench-rs.nix
        ./nix/checks/pre-commit.nix
        ./nix/shells/default.nix
        ./nix/shells/android.nix
        ./nix/shells/win32-cross.nix
      ];
      systems = import inputs.systems;
    };
}
