# Shared builder for the executable sub-packages under `apps/` (currently
# `hue`). Wraps nixpkgs' `buildDubPackage` with the sparkles-specific plumbing
# every app needs: an in-tree source fileset (all sibling dub manifests plus the
# `.d`/`.c`/`.i` sources of the app's transitive `sparkles:*` closure), the
# writable-build-tree fixup dub needs, a `build/<pname>` install, `makeWrapper`
# on the build inputs, and a `remove-references-to` scrub *derived* from
# `disallowedReferences` so callers configure the leak list in one place.
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

      isDubManifest =
        file:
        builtins.elem file.name [
          "dub.sdl"
          "dub.selections.json"
        ];

      # A source tree containing every sibling dub manifest (dub validates all
      # sub-packages declared in the root `dub.sdl`, so they must all be
      # present even when building one app) plus the `.d`/`.c`/`.i` sources of
      # the given repo-relative dirs (`.c`/`.i` for ImportC shims).
      sourceFor =
        sourceDirs:
        fs.toSource {
          inherit root;
          fileset = fs.unions (
            [ (fs.fileFilter isDubManifest root) ]
            ++ map (
              path: fs.fileFilter (file: file.hasExt "d" || file.hasExt "c" || file.hasExt "i") (fromRoot path)
            ) sourceDirs
          );
        };
    in
    {
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

            # The scrub expression is derived from `disallowedReferences`: every
            # disallowed path is passed to `remove-references-to`. An empty (or
            # absent) list means no extra scrub — `buildDubPackage` still scrubs
            # the compiler on its own.
            drefs = args.disallowedReferences or [ ];
            scrubFlags = lib.concatMapStringsSep " " (r: "-t ${r}") drefs;
          in
          {
            src = args.src or (sourceFor srcDirs);
            sourceRoot = args.sourceRoot or "${finalAttrs.src.name}/apps/${finalAttrs.pname}";

            nativeBuildInputs = (args.nativeBuildInputs or [ ]) ++ [ pkgs.makeWrapper ];

            # dub writes into the unpacked (read-only) source tree.
            preBuild = args.preBuild or ''chmod -R u+w "$NIX_BUILD_TOP"'';

            installPhase =
              args.installPhase or ''
                install -Dm755 build/${finalAttrs.pname} $out/bin/${finalAttrs.pname}
              '';

            # postFixup (after buildDubPackage's preFixup compiler scrub): strip
            # the disallowed references, then run any caller fixup (e.g. a
            # `wrapProgram`).
            postFixup =
              (lib.optionalString (drefs != [ ]) ''
                find "$out" -type f -exec remove-references-to ${scrubFlags} '{}' +
              '')
              + (args.postFixup or "");
          }
          # Forward the leak list to buildDubPackage only when the caller set it
          # (an unset list would otherwise clobber its `[ compiler ]` default).
          // lib.optionalAttrs (args ? disallowedReferences) {
            inherit (args) disallowedReferences;
          };
      };
    };
}
