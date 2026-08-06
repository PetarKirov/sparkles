# Shared builder for the executable sub-packages under `apps/`. Wraps nixpkgs'
# `buildDubPackage` with the sparkles-specific plumbing every app needs: the
# shared `nix/dub-lock.json`, an in-tree source fileset (the manifests of the
# root package's declared sub-packages plus the `.d`/`.c`/`.i` sources of the
# app's transitive `sparkles:*` closure), the writable-build-tree fixup dub
# needs, a `build/<pname>` install,
# `makeWrapper` on the build inputs, and a `remove-references-to` scrub *derived*
# from a default Phobos-leak set (minus anything in `buildInputs`) so callers
# configure the leak list in one place.
#
# Exposed as `legacyPackages.buildSparklesApp` (flake-parts' escape hatch for
# non-derivation values — see `build-d-wasm-module` for precedent); internal
# consumers call it via `config.legacyPackages.buildSparklesApp`.
{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
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
      # dependencies like `sparkles:test-utils`):
      #   * `dependency "sparkles:<name>" path="..."` — real dub dependencies;
      #   * sibling source refs `../<name>/src` / `../../libs/<name>/src` on
      #     `importPaths`/`sourcePaths` — how `base`/`core-cli` pull in the
      #     source-included `math` and test-runner shim+impl (they can't
      #     `dependency` them: dub would reject the resulting cycle).
      # Both map `<name>` → `libs/<name>`. In every manifest the `unittest`
      # block is last and runs to EOF, so truncating at it is exact.
      matchAll = re: s: map builtins.head (builtins.filter builtins.isList (builtins.split re s));

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
            grow (seen ++ [ name ]) (rest ++ refsOf (readManifest "libs/${name}"));

      sparklesSrcClosure =
        appDir: [ "${appDir}/src" ] ++ map (n: "libs/${n}/src") (grow [ ] (refsOf (readManifest appDir)));

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
                # `views/twoslash.css` and `views/icons/**/*.svg`, pulled in via `import()`).
                file:
                file.hasExt "d" || file.hasExt "c" || file.hasExt "i" || file.hasExt "css" || file.hasExt "svg"
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
      #   * `manifestFileset` → the dub manifests every build needs present.
      legacyPackages.sparklesSources = {
        srcClosure = sparklesSrcClosure;
        libsClosure = names: map (n: "libs/${n}/src") (grow [ ] names);
        refsIn = refsOf;
        inherit sourceFor manifestFileset;
      };

      legacyPackages.buildSparklesApp = lib.extendMkDerivation {
        constructDrv = pkgs.buildDubPackage;

        # `sourceDirs` is a synthetic override consumed here, not a
        # mkDerivation attribute.
        excludeDrvArgNames = [ "sourceDirs" ];

        extendDrvArgs =
          finalAttrs: args:
          let
            # Explicit `sourceDirs` override, else the computed closure.
            srcDirs = args.sourceDirs or (sparklesSrcClosure "apps/${finalAttrs.pname}");

            # Default leak set. `buildDubPackage` already scrubs the compiler
            # itself in its `preFixup`, so this only adds the Phobos-baked paths
            # it does *not* handle: ldc's separate `include` output (dead
            # assert/`__FILE__` strings) and the curl/tzdata dlopen fallbacks a
            # static binary never reaches. A runtime dep the caller lists in
            # `buildInputs` is a genuine reference, so it is subtracted (never
            # scrubbed) — and a package needing a compiler at runtime (e.g. `ci`)
            # just puts it on PATH via `postFixup`; its store path is not the
            # *build* compiler's, so nothing disallows it.
            compiler = args.compiler or pkgs.ldc;
            # `compiler` itself is the assertion `buildDubPackage`'s built-in
            # `disallowedReferences = [ compiler ]` provides; supplying our own
            # list replaces it, so re-add it here. It only *asserts* what the
            # preFixup scrub already removes — a genuine runtime compiler (ci's
            # DMD on PATH) is a different store path and is unaffected.
            defaultDisallowed = [
              compiler
            ]
            ++ lib.optionals (compiler ? include) [ compiler.include ]
            ++ [
              pkgs.curl.out
              pkgs.tzdata
            ];
            disallowed = lib.subtractLists (args.buildInputs or [ ]) (
              args.disallowedReferences or defaultDisallowed
            );
            scrubFlags = lib.concatMapStringsSep " " (r: "-t ${r}") disallowed;
          in
          {
            # All sparkles nix packages share the one Nix-format lockfile.
            dubLock = args.dubLock or (fromRoot "nix/dub-lock.json");

            # Which dub build type the app is compiled with (the build hook's
            # own knob, surfaced here so callers set it as an argument and get
            # a default they can read).
            #
            # `checked` — `optimize` + `inline` + `debugInfo`, and neither
            # `releaseMode` nor `debugMode` — is the repo's build for every
            # shipped artifact. The two dub defaults are each wrong for one:
            #
            #   * `release` implies `-release`, which deletes assert
            #     *expressions* outright. An assertion that never runs is not
            #     a cheap assertion, it is an absent one — and a call written
            #     inside an assert silently stops happening.
            #   * `debug` implies `-debug`, which compiles `debug { }` blocks
            #     in. Those exist to hold checks too expensive to ship (an
            #     `isSorted` over the whole input), so they do not belong in
            #     an artifact either.
            #
            # `checked` keeps assertions and drops the debug blocks, at ~3%
            # over `release` where it was measured (`apps/twoslash-extract`).
            # Where even that is too much for a hot path, the lever is
            # `-checkaction=halt` on that code — not deleting the check.
            dubBuildType = args.dubBuildType or "checked";

            src = args.src or (sourceFor srcDirs);
            sourceRoot = args.sourceRoot or "${finalAttrs.src.name}/apps/${finalAttrs.pname}";

            nativeBuildInputs = (args.nativeBuildInputs or [ ]) ++ [ pkgs.makeWrapper ];

            # dub writes into the unpacked (read-only) source tree.
            preBuild = args.preBuild or ''chmod -R u+w "$NIX_BUILD_TOP"'';

            installPhase =
              args.installPhase or ''
                install -Dm755 build/${finalAttrs.pname} $out/bin/${finalAttrs.pname}
              '';

            disallowedReferences = disallowed;

            # postFixup (after buildDubPackage's preFixup compiler scrub): strip
            # the disallowed references, then run any caller fixup (e.g. a
            # `wrapProgram`).
            postFixup =
              (lib.optionalString (disallowed != [ ]) ''
                find "$out" -type f -exec remove-references-to ${scrubFlags} '{}' +
              '')
              + (args.postFixup or "");
          };
      };
    };
}
