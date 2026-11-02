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

      # Compute the source closure of an app from its dub manifests, so the
      # fileset stays in sync with the actual dependency graph instead of a
      # hand-maintained list. Given the app's repo-relative dir, read its
      # `dub.sdl` and transitively every referenced `libs/<name>/dub.sdl`,
      # collecting each package's `src` dir.
      #
      # Two kinds of edge are followed, both truncated at the `unittest`
      # configuration (an app/library build never compiles unittest-only
      # dependencies):
      #   * `dependency "sparkles:<name>" path="..."` — real dub dependencies;
      #   * sibling source refs `../<name>/src` / `../../libs/<name>/src` on
      #     `importPaths`/`sourcePaths` — how `base`/`core-cli` pull in the
      #     source-included `math` and test-runner shim (they can't
      #     `dependency` them: dub would reject the resulting cycle).
      # Both map `<name>` → `libs/<name>`. In every manifest the `unittest`
      # block is last and runs to EOF, so truncating at it is exact for that
      # block. `configuration "testing"` in `build-primitives` sits above it
      # and still names `sparkles:test-utils`; that edge stays in this fileset
      # and is dropped by `shippedComponentNames`, which is what the
      # build-info document lists.
      matchAll = re: s: map builtins.head (builtins.filter builtins.isList (builtins.split re s));
      matchAllPairs = re: s: builtins.filter builtins.isList (builtins.split re s);

      readManifest =
        relDir:
        let
          f = root + "/${relDir}/dub.sdl";
        in
        if builtins.pathExists f then
          builtins.head (builtins.split ''configuration "unittest"'' (builtins.readFile f))
        else
          "";

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
            grow (seen ++ [ name ]) (rest ++ refsOf (readManifest (libDir name)));

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
        appDir: [ "${appDir}/src" ] ++ lib.concatMap libSrcDirs (grow [ ] (refsOf (readManifest appDir)));

      # What an application build links. The fileset walk follows every
      # configuration above `unittest`, so it still carries `ui-app`'s `tui`
      # arm and `build-primitives`' `testing` arm. This walk follows the
      # preamble plus one configuration: the first, unless a selected recipe
      # names another with `subConfiguration`. An import-path edge does not
      # activate the target's dependencies. The test-runner shim is that
      # import path so UDA names resolve; the application build does not link
      # it. `//` comments quote dependency lines and are not edges.
      stripLineComments =
        text:
        lib.concatMapStrings (line: builtins.head (builtins.split "//" line) + "\n") (
          lib.splitString "\n" text
        );

      recipeOf =
        relDir:
        let
          f = root + "/${relDir}/dub.sdl";
        in
        if builtins.pathExists f then stripLineComments (builtins.readFile f) else "";

      firstConfig =
        text:
        let
          parts = builtins.split ''configuration "([A-Za-z0-9-]+)"'' text;
        in
        if builtins.length parts < 2 then null else builtins.head (builtins.elemAt parts 1);

      preambleOf = text: builtins.head (builtins.split ''configuration "'' text);

      # The body inside `configuration "name" { ... }`, braces respected.
      configBody =
        text: name:
        let
          parts = builtins.split (''configuration "'' + name + ''" \{'') text;
          after = if builtins.length parts < 3 then "" else builtins.elemAt parts 2;
          step =
            depth: acc: rest:
            if rest == [ ] || depth == 0 then
              acc
            else
              let
                h = builtins.head rest;
                t = builtins.tail rest;
              in
              if builtins.isList h then
                let
                  ch = builtins.head h;
                in
                if ch == "{" then
                  step (depth + 1) (acc + ch) t
                else if ch == "}" && depth == 1 then
                  acc
                else if ch == "}" then
                  step (depth - 1) (acc + ch) t
                else
                  step depth (acc + ch) t
              else
                step depth (acc + h) t;
        in
        step 1 "" (builtins.split "([{}])" after);

      # `cfg == null` selects the first configuration. Preamble dependencies
      # are on in every configuration.
      selectedRecipe =
        text: cfg:
        let
          name = if cfg != null then cfg else firstConfig text;
          body = if name == null then "" else configBody text name;
        in
        preambleOf text + "\n" + body;

      subOverrides =
        text:
        lib.listToAttrs (
          map (p: {
            name = builtins.elemAt p 0;
            value = builtins.elemAt p 1;
          }) (matchAllPairs ''subConfiguration "sparkles:([a-z-]+)" "([A-Za-z0-9-]+)"'' text)
        );

      depRefs = text: matchAll ''dependency "sparkles:([a-z-]+)"'' text;

      # `test-runner` is the UDA import path, not a linked library.
      pathRefs =
        text:
        lib.filter (n: n != "test-runner") (
          matchAll ''\.\./([a-z-]+)/src'' text ++ matchAll ''\.\./\.\./libs/([a-z-]+)/src'' text
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
              file = recipeOf (libDir name);
              cfg = if head.cfg != null then head.cfg else firstConfig file;
              text = selectedRecipe file (if head.link then cfg else null);
              overrides = subOverrides text;
              more =
                (lib.optionals head.link (
                  map (n: {
                    name = n;
                    cfg = overrides.${n} or null;
                    link = true;
                  }) (depRefs text)
                ))
                ++ map (n: {
                  name = n;
                  cfg = null;
                  link = false;
                }) (pathRefs text);
              marked = if head.link then (if cfg == null then "" else cfg) else "import";
            in
            growShipped (seen // { ${name} = marked; }) (rest ++ more);

      shippedComponentNames =
        appDir:
        let
          text = selectedRecipe (recipeOf appDir) null;
          overrides = subOverrides text;
          seed =
            map (n: {
              name = n;
              cfg = overrides.${n} or null;
              link = true;
            }) (depRefs text)
            ++ map (n: {
              name = n;
              cfg = null;
              link = false;
            }) (pathRefs text);
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

      subPackageDirs = matchAll ''subPackage "([^"]+)"'' (builtins.readFile (root + "/dub.sdl"));

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
      sourceFor =
        sourceDirs:
        fs.toSource {
          inherit root;
          fileset = fs.unions (
            [ manifestFileset ]
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
        inherit sourceFor manifestFileset;
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
