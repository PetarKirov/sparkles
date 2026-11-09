# The dub manifest graph, read at evaluation time: which in-tree packages an
# app or a lib reaches, which it ships, and the source tree a build needs.
# Exported as `legacyPackages.sparklesSources` for the builders that use it:
# `buildSparklesApp`, the examples, and the Android cross build, which
# bypasses dub.
{ lib, ... }:
{
  perSystem =
    { config, ... }:
    let
      fs = lib.fileset;
      root = ../..;
      fromRoot = lib.path.append root;

      # The dub recipe module the recipe table reads through where the
      # evaluator has `builtins.wasm` (docs/specs/wired/wasm WW7, WW8): the
      # pinned module of nix/nix-wasm-pin.json, built at the pin's revision and
      # fetched by hash, so evaluation builds nothing. An evaluator without the
      # builtin never fetches it, and an empty pin keeps every evaluation on the
      # regular-expression reader.
      nixWasmPin = lib.importJSON ../nix-wasm-pin.json;
      nixWasmModule =
        if builtins ? wasm && nixWasmPin.rev != null then
          builtins.fetchurl {
            inherit (nixWasmPin) url;
            sha256 = nixWasmPin.hash;
          }
        else
          null;

      # Compute the source closure of an app from its dub manifests, so the
      # fileset stays in sync with the actual dependency graph instead of a
      # hand-maintained list. Given the app's repo-relative dir, read its
      # `dub.sdl` and transitively every referenced `libs/<name>/dub.sdl`,
      # collecting each package's `src` dir.
      #
      # The recipes are read through one table per evaluation (recipe-facts.nix,
      # docs/specs/wired/wasm WW9): by the dub recipe module where the evaluator
      # has `builtins.wasm`, by regular expressions otherwise.
      #
      # Two kinds of edge are followed, from the top level and from every
      # configuration declared before `unittest` (an app/library build never
      # compiles unittest-only dependencies, and the configurations after it,
      # such as `allocation-audit`, are test configurations too):
      #   * `dependency "sparkles:<name>" path="..."` — real dub dependencies;
      #   * sibling source refs `../<name>/src` / `../../libs/<name>/src` on
      #     `importPaths`/`sourcePaths` — how `base`/`core-cli` pull in the
      #     source-included `math` and test-runner shim (they can't
      #     `dependency` them: dub would reject the resulting cycle).
      # Both map `<name>` → `libs/<name>`. `configuration "testing"` in
      # `build-primitives` sits above `unittest` and still names
      # `sparkles:test-utils`; that edge stays in this fileset and is dropped by
      # `shippedComponentNames`, which is what the build-info document lists.
      matchAll = re: s: map builtins.head (builtins.filter builtins.isList (builtins.split re s));

      recipes = import ../lib/recipe-facts.nix {
        inherit root;
        module = nixWasmModule;
      };

      # The edges of a scope list, in the order the walks have always taken
      # them: every dependency, then every sibling ref, then every lib ref.
      edgesOf =
        scopes:
        lib.concatMap (s: s.deps) scopes
        ++ lib.concatMap (s: s.siblingRefs) scopes
        ++ lib.concatMap (s: s.libRefs) scopes;

      # The fileset walk's edges of the recipe in `relDir`.
      closureRefs =
        relDir:
        let
          f = recipes.facts relDir;
          stop = lib.lists.findFirstIndex (n: n == "unittest") null f.configurations;
          configs = if stop == null then f.configurations else lib.take stop f.configurations;
        in
        edgesOf ([ f.preamble ] ++ map (n: f.scopes.${n}) configs);

      # `refsIn text` for builders that read a recipe embedded in a `.d` file
      # (android/examples.nix); outside the table, as recipe-facts.nix reads
      # `dub.sdl` files only.
      refsOf =
        text:
        matchAll ''dependency "sparkles:([a-z-]+)"'' text
        ++ matchAll ''\.\./([a-z-]+)/src'' text
        ++ matchAll ''\.\./\.\./libs/([a-z-]+)/src'' text;

      # Breadth-first fixpoint over lib names, seeded from the app manifest.
      grow =
        seen: frontier:
        if frontier == [ ] then
          seen
        else
          let
            name = builtins.head frontier;
            rest = builtins.tail frontier;
          in
          if builtins.elem name seen then
            grow seen rest
          else
            grow (seen ++ [ name ]) (rest ++ closureRefs (libDir name));

      # A library's directory: `libs/<name>`, or, for a package nested in
      # another's (`sparkles:table-wasm` in libs/core-cli/table-wasm), the
      # declared sub-package directory whose last component is its name.
      libDir =
        name:
        lib.findFirst (d: lib.hasPrefix "libs/" d && baseNameOf d == name) "libs/${name}" subPackageDirs;

      # A library's source directories: `src`, and the `src-engine` an optional
      # configuration compiles (`sparkles:font`'s HarfBuzz engine, which
      # `sparkles:ui-vulkan` selects) where the library has one.
      libSrcDirs =
        n:
        [ "${libDir n}/src" ]
        ++ lib.optional (builtins.pathExists (root + "/${libDir n}/src-engine")) "${libDir n}/src-engine";

      sparklesSrcClosure =
        appDir: [ "${appDir}/src" ] ++ lib.concatMap libSrcDirs (grow [ ] (closureRefs appDir));

      # What an application build links. The fileset walk follows every
      # configuration above `unittest`, so it still carries `ui-app`'s `tui`
      # arm and `build-primitives`' `testing` arm. This walk follows the
      # top level plus one configuration: the first, unless a selected recipe
      # names another with `subConfiguration`. An import-path edge does not
      # activate the target's dependencies. The test-runner shim is that
      # import path so UDA names resolve; the application build does not link
      # it.
      #
      # The scopes of the recipe in `relDir` as built with configuration
      # `cfg`, or with its first configuration when `cfg` is null.
      selectedScopes =
        relDir: cfg:
        let
          f = recipes.facts relDir;
          name = if cfg != null then cfg else firstConfig relDir;
        in
        [ f.preamble ] ++ lib.optional (name != null) (f.scopes.${name} or recipes.emptyScope);

      firstConfig =
        relDir:
        let
          names = (recipes.facts relDir).configurations;
        in
        if names == [ ] then null else builtins.head names;

      # The first choice of each dependency wins, the top level's first.
      subOverrides = scopes: lib.foldr (s: acc: acc // s.subConfigurations) { } scopes;

      depRefs = scopes: lib.concatMap (s: s.deps) scopes;

      # `test-runner` is the UDA import path, not a linked library.
      pathRefs =
        scopes:
        lib.filter (n: n != "test-runner") (
          lib.concatMap (s: s.siblingRefs) scopes ++ lib.concatMap (s: s.libRefs) scopes
        );

      # `seen.${name}` is the configuration walked, or "" for the default.
      # A concrete `subConfiguration` replaces a default already walked; a
      # default does not replace a concrete choice (the root's choice is seeded
      # first). Import-only nodes do not follow recipe dependencies.
      growShipped =
        seen: frontier:
        if frontier == [ ] then
          seen
        else
          let
            head = builtins.head frontier;
            rest = builtins.tail frontier;
            name = head.name;
            prev = seen.${name} or null;
            # "import" has not followed recipe dependencies yet. "" is the
            # default configuration. A concrete subConfiguration replaces "".
            upgrade = prev == "import" && head.link || prev == "" && head.cfg != null;
            skip = prev != null && !upgrade;
          in
          if skip then
            growShipped seen rest
          else
            let
              dir = libDir name;
              cfg = if head.cfg != null then head.cfg else firstConfig dir;
              scopes = selectedScopes dir (if head.link then cfg else null);
              overrides = subOverrides scopes;
              more =
                (lib.optionals head.link (
                  map (n: {
                    name = n;
                    cfg = overrides.${n} or null;
                    link = true;
                  }) (depRefs scopes)
                ))
                ++ map (n: {
                  name = n;
                  cfg = null;
                  link = false;
                }) (pathRefs scopes);
              marked = if head.link then (if cfg == null then "" else cfg) else "import";
            in
            growShipped (seen // { ${name} = marked; }) (rest ++ more);

      shippedComponentNames =
        appDir:
        let
          scopes = selectedScopes appDir null;
          overrides = subOverrides scopes;
          seed =
            map (n: {
              name = n;
              cfg = overrides.${n} or null;
              link = true;
            }) (depRefs scopes)
            ++ map (n: {
              name = n;
              cfg = null;
              link = false;
            }) (pathRefs scopes);
        in
        builtins.attrNames (growShipped { } seed);

      # The manifests dub needs on disk: the root recipe plus one pair per
      # sub-package it declares. Dub validates every `subPackage` of the root
      # package, so they must all be present even when building one app — but
      # *only* those. Filtering `dub.sdl`/`dub.selections.json` over the whole
      # tree (the previous rule) also swept in manifests dub never looks at —
      # `docs/research/**`, `libs/*/bench/**`, `libs/base/tools/**` — so editing
      # a research sample's recipe changed the source hash of every app, and
      # through `ci`, of the dev shell.
      manifestsFor = dir: [
        (fromRoot "${dir}/dub.sdl")
        (fs.maybeMissing (fromRoot "${dir}/dub.selections.json"))
      ];

      subPackageDirs = recipes.rootFacts.subPackages;

      manifestFileset = fs.unions (
        [
          (fromRoot "dub.sdl")
          (fs.maybeMissing (fromRoot "dub.selections.json"))
        ]
        ++ lib.concatMap manifestsFor subPackageDirs
      );

      # A source tree containing the dub manifests above plus the
      # `.d`/`.c`/`.i` sources of the given repo-relative dirs (`.c`/`.i` for
      # ImportC shims).
      sourceFor = sourceDirs: sourceForWith sourceDirs [ ];

      # ditto, plus `extraFiles`: repo-relative files an app string-imports
      # from outside its source dirs (the fileset explorer's help page, which
      # is a docs page compiled in).
      sourceForWith =
        sourceDirs: extraFiles:
        fs.toSource {
          inherit root;
          fileset = fs.unions (
            [ manifestFileset ]
            ++ map fromRoot extraFiles
            ++ map (
              path:
              fs.fileFilter (
                # `.d`/`.c`/`.i` sources (`.c`/`.i` for ImportC shims) plus
                # `.css`/`.svg` string-import view assets (e.g. sparkles:twoslash's
                # `views/twoslash.css` and `views/icons/**/*.svg`, pulled in via `import()`)
                # and `.frag` shaders (sparkles:ui's are generated and come from
                # `ui-shaders`; this keeps any hand-written one a package
                # string-imports), and the committed SPIR-V (`.spv`) a package
                # string-imports (sparkles:vulkan-wsi's test pattern).
                file:
                file.hasExt "d"
                || file.hasExt "c"
                || file.hasExt "i"
                || file.hasExt "h"
                || file.hasExt "css"
                || file.hasExt "svg"
                || file.hasExt "frag"
                || file.hasExt "spv"
              ) (fromRoot path)
            ) sourceDirs
          );
        };
    in
    {
      # The source-closure machinery, exported for builders that bypass dub
      # (the Android cross build) or that start from something other than an
      # app manifest (`examples.nix`, which seeds from each example's inline
      # recipe):
      #   * `srcClosure "apps/hue"` → repo-relative source dirs of the app's
      #     transitive sparkles closure;
      #   * `libsClosure [ "base" ]` → the same, seeded from lib names;
      #   * `refsIn text` → the `sparkles:*` names a recipe body references,
      #     both as `dependency` and as a sibling `../<name>/src` import path;
      #   * `sourceFor dirs` → the filtered fileset source tree;
      #   * `manifestFileset` → the dub manifests every build needs present;
      #   * the shader placement of ui-shaders.nix (`uiShaderPlacement`).
      legacyPackages.sparklesSources = {
        srcClosure = sparklesSrcClosure;
        libsClosure = names: lib.concatMap libSrcDirs (grow [ ] names);
        componentNames = shippedComponentNames;
        refsIn = refsOf;
        inherit sourceFor sourceForWith manifestFileset;
        inherit (config.legacyPackages.uiShaderPlacement)
          needsUiShaders
          uiShaderDirs
          needsUiVulkanShaders
          placeUiVulkanShaders
          placeUiShaders
          placeVulkanWsiShaders
          ;
      };
    };
}
