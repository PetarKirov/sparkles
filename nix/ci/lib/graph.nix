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

  # A sub-package nested inside another (`libs/base/tools/text-conformance`
  # inside `libs/base`) is its own unit, so it is cut out of its parent's.
  nestedIn = dir: builtins.filter (d: d != dir && lib.hasPrefix "${dir}/" d) subPackageDirs;

  packageUnits = lib.mapAttrs' (
    name: dir:
    lib.nameValuePair (pkgUnit name) {
      files = fs.difference (fromRoot dir) (fs.unions (map fromRoot (nestedIn dir)));
      deps = [ "dub-manifests" ] ++ depsOf (read "${dir}/dub.sdl");
      arg = name;
    }
  ) packageDirs;

  # Tests that read files outside their package directory. Over-approximation
  # is safe (a job re-runs when it did not need to); under-approximation is a
  # stale pass, so anything a test opens by a repo-relative path belongs here.
  testReads = {
    doc-view = [ "docs/specs/base/text/index.md" ];
    hue = [ "docs/credits" ];
  };

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
        arg = file;
      }
    ) runnableMarkdown
  );

  # ── multi-file research packages ───────────────────────────────────

  # The OS-API windowing examples and demos: dub packages outside the root
  # recipe, one unit per platform directory.
  osApis = "docs/research/window-system-integration/os-apis";
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
            [ (fromRoot dir) ]
            ++ lib.optional (platform == "x11") (
              fromRoot "docs/research/window-system-integration/cursor-shapes"
            )
          );
          deps = [
            "dub-manifests"
          ]
          ++ lib.unique (lib.concatMap (r: depsOf (read r)) recipes);
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
in
{
  inherit
    units
    closure
    packageDirs
    subPackageDirs
    exampleFiles
    runnableMarkdown
    refsIn
    ;
  packageNames = builtins.attrNames packageDirs;
}
