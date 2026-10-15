# The repository as a graph of *units* — the granularity CI is lazy at.
#
# A unit is a fileset plus the units it depends on. Every unit's identity is
# the content of its own fileset; a unit's *closure* is itself plus everything
# it reaches. A CI job declares the units it covers, and it re-runs exactly
# when the content of one of their closures is new (`./stamps.nix`).
#
# Nothing here is hand-maintained where the repository already says it:
#
#   * dub sub-packages and their edges come from the root `dub.sdl` and each
#     package's own recipe (every configuration, `unittest` included — tests
#     compile `sparkles:test-utils` and the source-included runner);
#   * single-file examples and runnable markdown are discovered from the
#     tree, and their edges read from the inline `dub.sdl` recipes they carry;
#   * the standalone-example globs are read from the data file the `ci` tool reads
#     (`apps/ci/example-globs.json`), so `ci --example-files` and this file
#     cannot disagree about what an example is.
#
# Pure and system-independent: the same graph serves every runner.
{ lib, root }:
let
  fs = lib.fileset;
  fromRoot = lib.path.append root;
  read = rel: builtins.readFile (fromRoot rel);
  exists = rel: builtins.pathExists (fromRoot rel);

  matchAll = re: s: map builtins.head (builtins.filter builtins.isList (builtins.split re s));

  # Repo-relative paths (`libs/base/dub.sdl`) of a fileset's files.
  relativeFiles = set: map (p: lib.removePrefix "./" (lib.path.removePrefix root p)) (fs.toList set);

  # Repo-relative paths of the regular files directly in `dir` (not recursive).
  filesIn =
    dir:
    lib.mapAttrsToList (name: _: "${dir}/${name}") (
      lib.filterAttrs (_: type: type == "regular") (builtins.readDir (fromRoot dir))
    );

  # ── dub sub-packages ────────────────────────────────────────────────

  subPackageDirs = matchAll ''subPackage "([^"]+)"'' (read "dub.sdl");

  # `dub test :<name>` and `ci --packages <name>` both name a sub-package by
  # its directory's base name.
  packageDirs = lib.listToAttrs (map (dir: lib.nameValuePair (baseNameOf dir) dir) subPackageDirs);

  # The `sparkles:*` names a recipe reaches: real `dependency` edges, plus the
  # sibling source includes (`../<name>/src`, `../../libs/<name>/src`) that
  # `base`/`core-cli` use where a `dependency` would close a dub cycle.
  # Names that are not sub-packages (a comment's prose, say) are dropped.
  refsIn =
    text:
    lib.unique (
      builtins.filter (n: packageDirs ? ${n}) (
        matchAll ''"sparkles:([a-z0-9-]+)"'' text
        ++ matchAll ''\.\./([a-z0-9-]+)/src'' text
        ++ matchAll ''\.\./\.\./libs/([a-z0-9-]+)/src'' text
      )
    );

  pkgUnit = name: "pkg/${name}";
  depsOf = text: map pkgUnit (refsIn text);

  # ── what a unit needs from its environment ──────────────────────────
  #
  # A unit's *needs* are feature names of the dev shell's `ci` tier
  # (`ciFeatures` in nix/shells/default.nix); a job's shell carries the
  # features its units' closures need, and nothing else. Linking needs are
  # read from the recipes: each `libs` name through this table (a name not
  # in it — `imm32`, `pthread` — needs nothing beyond the toolchain), and
  # `subConfiguration "sparkles:ui" "gpu-effects"` for the shader toolchain.
  libFeatures =
    lib.genAttrs [
      "raylib"
      "freetype"
      "freetype2"
      "harfbuzz"
    ] (_: "raylib")
    // lib.genAttrs [
      "nix-util-c"
      "nix-store-c"
      "nix-expr-c"
      "nix-fetchers-c"
      "nix-flake-c"
      "nix-main-c"
    ] (_: "nix-c-api")
    // lib.genAttrs [
      "wayland-client"
      "wayland-cursor"
      "x11"
      "x11-xcb"
      "xext"
      "xi"
      "xfixes"
      "xcursor"
      "xrandr"
      "xcb"
      "xcb-xkb"
      "xcb-xtest"
      "xcb-xinput"
      "xcb-present"
      "xcb-imdkit"
      "xkbcommon"
      "xkbcommon-x11"
    ] (_: "wsi-linux")
    // lib.genAttrs [ "dw" "elf" "pfm" ] (_: "perf-probes")
    // {
      "ghostty-vt" = "ghostty";
      "tree-sitter" = "tree-sitter";
      SDL3 = "sdl3";
      vulkan = "vulkan";
      kqueue = "kqueue";
    };

  # `lib.hasInfix` is a `.*x.*` match, which overflows the regex engine's
  # stack on a large file (a 149 KB spec); `split` scans instead.
  contains = needle: text: builtins.length (builtins.split (lib.escapeRegex needle) text) > 1;

  # Line by line, for the same reason.
  libsIn =
    text:
    lib.concatMap (
      line:
      let
        m = builtins.match ''[[:space:]]*libs(( "[^"]+")+).*'' line;
      in
      lib.optionals (m != null) (matchAll ''"([^"]+)"'' (builtins.head m))
    ) (lib.splitString "\n" text);

  # Registry packages whose own recipe links a system library.
  dubFeatures = {
    raylib-d = "raylib";
  };

  recipeNeeds =
    text:
    builtins.filter (f: f != null) (map (l: libFeatures.${l} or null) (libsIn text))
    ++ builtins.filter (f: f != null) (
      map (d: dubFeatures.${d} or null) (matchAll ''dependency "([^"]+)"'' text)
    )
    ++ lib.optional (contains ''subConfiguration "sparkles:ui" "gpu-effects"'' text) "shaders";

  # What tests exec or read at run time, which no recipe says. Missing an
  # entry degrades the test to a skip (or fails it), so over-listing is the
  # safe side. A unit's needs reach its dependents: a test that drives a
  # dependency's code needs what that code reads.
  testNeeds = {
    ci = [
      "nerd-font-glyphnames"
      "tree-sitter"
    ];
    dmd-fmt = [ "flake-input:dmd-src" ];
    dmd-lsp = [ "d-import-paths" ];
    doc-view = [ "tree-sitter" ];
    event-horizon = [ "util-linux" ];
    font = [ "fonts" ];
    font-oracle = [ "fonts" ];
    hue = [
      "d-import-paths"
      "tree-sitter"
    ];
    shader-compile = [ "shaders" ];
    source-view = [ "tree-sitter" ];
    syntax = [ "tree-sitter" ];
    terminal = [ "dbus" ];
    test-runner-impl = [ "wasm" ];
    twoslash = [ "tree-sitter" ];
    twoslash-d = [ "d-import-paths" ];
    twoslash-extract = [ "d-import-paths" ];
    ui = [ "nerd-font-glyphnames" ];
    wired = [ "json-test-suite" ];
  };

  # Examples and markdown by path prefix: the probes that exec a tool.
  fileNeeds = file: lib.optional (lib.hasPrefix "docs/research/sanitizers/" file) "valgrind";

  # A sub-package nested inside another (`libs/base/tools/text-conformance`
  # inside `libs/base`) is its own unit, so it is cut out of its parent's.
  nestedIn = dir: builtins.filter (d: d != dir && lib.hasPrefix "${dir}/" d) subPackageDirs;

  packageUnits = lib.mapAttrs' (
    name: dir:
    lib.nameValuePair (pkgUnit name) {
      files = fs.difference (fromRoot dir) (fs.unions (map fromRoot (nestedIn dir)));
      deps = [ "dub-manifests" ] ++ depsOf (read "${dir}/dub.sdl");
      needs = recipeNeeds (read "${dir}/dub.sdl") ++ testNeeds.${name} or [ ];
      arg = name;
    }
  ) packageDirs;

  # Tests that read files outside their package directory. Over-approximation
  # is safe (a job re-runs when it did not need to); under-approximation is a
  # stale pass, so anything a test opens by a repo-relative path belongs here.
  # The data file is shared with `ci --check-test-reads`, which fails on a
  # path a package's sources name that is neither here nor in its closure.
  testReads =
    lib.filterAttrs (n: _: !lib.hasPrefix "$" n)
      (builtins.fromJSON (read "nix/ci/test-reads.json")).reads;

  testReadUnits = lib.mapAttrs' (
    name: paths:
    lib.nameValuePair "reads/${name}" {
      files = fs.unions (map (p: fs.maybeMissing (fromRoot p)) paths);
      deps = [ ];
    }
  ) testReads;

  withTestReads = lib.mapAttrs (
    unit: u:
    let
      name = lib.removePrefix "pkg/" unit;
    in
    u // { deps = u.deps ++ lib.optional (testReads ? ${name}) "reads/${name}"; }
  ) packageUnits;

  # dub validates every sub-package the root recipe declares, so each build
  # reads all of their manifests — not only its own.
  manifestUnit = {
    dub-manifests = {
      files = fs.unions (
        [
          (fromRoot "dub.sdl")
          (fs.maybeMissing (fromRoot "dub.selections.json"))
        ]
        ++ lib.concatMap (dir: [
          (fromRoot "${dir}/dub.sdl")
          (fs.maybeMissing (fromRoot "${dir}/dub.selections.json"))
        ]) subPackageDirs
      );
      deps = [ ];
    };
  };

  # ── single-file examples ───────────────────────────────────────────

  # The globs `ci --example-files` defaults to. Every one is a `<dir>/*.d`,
  # which is all this needs to expand.
  exampleGlobs = (builtins.fromJSON (read "apps/ci/example-globs.json")).globs;
  exampleFiles = lib.concatMap (
    glob:
    let
      dir = lib.removeSuffix "/*.d" glob;
    in
    lib.optionals (exists dir) (builtins.filter (lib.hasSuffix ".d") (filesIn dir))
  ) exampleGlobs;

  # An example sees its own file and whatever non-example files sit beside it
  # (fixtures, patches, data) — not its sibling examples.
  exampleUnits = lib.listToAttrs (
    map (
      file:
      let
        dir = dirOf file;
      in
      lib.nameValuePair "example/${file}" {
        files = fs.unions [
          (fromRoot file)
          (fs.fileFilter (f: !f.hasExt "d") (fromRoot dir))
        ];
        deps =
          let
            refs = depsOf (read file);
          in
          lib.optionals (refs != [ ]) ([ "dub-manifests" ] ++ refs)
          ++ lib.optional (lib.hasPrefix "docs/libs/event-horizon/tutorial/snippets/" file) "eh-comparisons";
        needs = recipeNeeds (read file) ++ fileNeeds file;
        arg = file;
      }
    ) exampleFiles
  );

  # The comparison snippets build against pinned third-party checkouts that
  # `apps/ci/tools/prepare-event-horizon-comparisons.d` clones and patches.
  ehComparisons = {
    eh-comparisons = {
      files = fs.unions (
        [ (fromRoot "apps/ci/tools/prepare-event-horizon-comparisons.d") ]
        ++ map fromRoot (builtins.filter (lib.hasSuffix ".patch") (filesIn "apps/ci/tools"))
      );
      deps = [ ];
    };
  };

  # ── runnable markdown ──────────────────────────────────────────────

  # `ci --verify` runs a fence whose first two lines are the dub single-file
  # shebang and recipe opener; a file without one has nothing to verify.
  markdownExcludes = [
    "libs/syntax/test/data/"
    "libs/source-view/test/data/"
  ];
  markdownFiles = builtins.filter (rel: !lib.any (p: lib.hasPrefix p rel) markdownExcludes) (
    relativeFiles (fs.fileFilter (f: f.hasExt "md") root)
  );
  isRunnableMarkdown =
    rel:
    builtins.length (builtins.split ''#!/usr/bin/env dub[[:space:]]*/\+ dub\.sdl:'' (read rel)) > 1;
  runnableMarkdown = builtins.filter isRunnableMarkdown markdownFiles;

  markdownUnits = lib.listToAttrs (
    map (
      file:
      lib.nameValuePair "md/${file}" {
        files = fromRoot file;
        deps = [ "dub-manifests" ] ++ depsOf (read file);
        needs = recipeNeeds (read file) ++ fileNeeds file;
        arg = file;
      }
    ) runnableMarkdown
  );

  # ── multi-file research packages ───────────────────────────────────

  # The OS-API windowing examples and demos: dub packages outside the root
  # recipe, one unit per platform directory.
  osApis = "docs/research/window-system-integration/os-apis";
  # The interactive cursor probe the x11 job compiles (a single-file recipe).
  cursorShapes = "docs/research/window-system-integration/cursor-shapes/cursor-shapes.d";
  osApiUnits = lib.listToAttrs (
    map
      (
        platform:
        let
          dir = "${osApis}/${platform}";
          recipes = relativeFiles (fs.fileFilter (f: f.name == "dub.sdl") (fromRoot dir));
        in
        lib.nameValuePair "os-api/${platform}" {
          files = fs.unions (
            [ (fromRoot dir) ] ++ lib.optional (platform == "x11") (fromRoot (dirOf cursorShapes))
          );
          deps = [
            "dub-manifests"
          ]
          ++ lib.unique (lib.concatMap (r: depsOf (read r)) recipes);
          # The demos run for real: X11 under Xvfb, Wayland under weston.
          needs =
            lib.concatMap (r: recipeNeeds (read r)) (recipes ++ lib.optional (platform == "x11") cursorShapes)
            ++ {
              x11 = [ "xvfb" ];
              wayland = [ "weston" ];
            }
            .${platform} or [ ];
        }
      )
      (
        builtins.filter (p: exists "${osApis}/${p}") [
          "x11"
          "wayland"
          "win32"
        ]
      )
  );

  # ── coarse units ───────────────────────────────────────────────────

  coarseUnits = {
    # Everything git tracks. The docs site renders a listing of every source
    # file, and the lint hooks read the whole tree, so for them this is honest.
    repo = {
      files = root;
      deps = [ ];
    };

    # The `ci` helper's own sources, without the libraries it links. A job
    # driven by `ci` depends on this; the helper's store path is kept out of
    # job keys (`../tools.nix`), so a library edit does not re-run the world.
    harness = {
      files = fromRoot "apps/ci";
      deps = [ ];
    };

    # The flake: everything `nix flake check` evaluates beyond the sources.
    nix = {
      files = fs.unions [
        (fromRoot "flake.nix")
        (fromRoot "flake.lock")
        (fromRoot "nix")
      ];
      deps = [ ];
    };

    # The shell scripts the jobs without Nix run from the checkout.
    ci-scripts = {
      files = fs.fileFilter (f: f.hasExt "sh") (fromRoot "ci");
      deps = [ ];
    };

    # What `ci/prepare-cloud-env.sh` bootstraps: the flake and its scripts.
    cloud-env = {
      files = fs.unions [
        (fromRoot "ci/prepare-cloud-env.sh")
        (fromRoot "ci/lib")
      ];
      deps = [ "nix" ];
    };
  };

  units =
    manifestUnit
    // withTestReads
    // testReadUnits
    // exampleUnits
    // ehComparisons
    // markdownUnits
    // osApiUnits
    // coarseUnits;

  # Transitive closure, cycle-safe (`base` source-includes the test runner
  # whose implementation depends on `base`).
  closure =
    names:
    map (x: x.key) (
      builtins.genericClosure {
        startSet = map (key: { inherit key; }) names;
        operator =
          { key }: map (d: { key = d; }) (units.${key}.deps or (throw "ci: unknown unit `${key}`"));
      }
    );

  # The features a set of units needs: every need in their closures.
  needsOf = names: lib.unique (lib.concatMap (u: units.${u}.needs or [ ]) (closure names));
in
{
  inherit
    units
    closure
    needsOf
    packageDirs
    subPackageDirs
    exampleFiles
    runnableMarkdown
    refsIn
    ;
  packageNames = builtins.attrNames packageDirs;
}
