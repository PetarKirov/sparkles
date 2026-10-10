# Shared builder for the executable sub-packages under `apps/`. Wraps nixpkgs'
# `buildDubPackage` with the sparkles-specific plumbing every app needs: the
# shared `nix/dub-lock.json`, an in-tree source fileset (the manifests of the
# root package's declared sub-packages plus the `.d`/`.c`/`.i` sources of the
# app's transitive `sparkles:*` closure), the writable-build-tree fixup dub
# needs, a `build/<pname>` install,
# `makeWrapper` on the build inputs, and a `remove-references-to` scrub *derived*
# from a default Phobos-leak set (minus anything in `buildInputs`) so callers
# configure the leak list in one place. The derivation returned to callers is
# a second step: it copies the compile and replaces a `{}` section with the
# build-info JSON. The compile does not see the commit, and the wrapper runs
# only after the replace.
#
# Exposed as `legacyPackages.buildSparklesApp` (flake-parts' escape hatch for
# non-derivation values — see `build-d-wasm-module` for precedent); internal
# consumers call it via `config.legacyPackages.buildSparklesApp`.
{ lib, inputs, ... }:
{
  perSystem =
    { config, pkgs, ... }:
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
            grow (seen ++ [ name ]) (rest ++ refsOf (readManifest "libs/${name}"));

      sparklesSrcClosure =
        appDir: [ "${appDir}/src" ] ++ map (n: "libs/${n}/src") (grow [ ] (refsOf (readManifest appDir)));

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
              file = recipeOf "libs/${name}";
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
                # string-imports).
                file:
                file.hasExt "d"
                || file.hasExt "c"
                || file.hasExt "i"
                || file.hasExt "h"
                || file.hasExt "css"
                || file.hasExt "svg"
                || file.hasExt "frag"
              ) (fromRoot path)
            ) sourceDirs
          );
        };
      # sparkles:ui's `gpu-effects` configuration generates its effect GLSL in a
      # pre-generate step that takes the dcompute-enabled LDC. Nix runs that
      # once (`ui-shaders`) and copies the output, with its `prebuilt` stamp,
      # into the tree of every build that reaches the configuration — through
      # `sparkles:ui-raylib`, whose dependents select it — so the step finds it fresh and
      # no app build needs LLVM. The step still builds the tool to read the
      # stamp, hence its sources. (The closure is read from the manifests, so
      # it can over-approximate — an unused copy, nothing more.)
      needsUiShaders = srcDirs: builtins.elem "libs/ui-raylib/src" srcDirs;
      uiShaderDirs = srcDirs: lib.optional (needsUiShaders srcDirs) "apps/shader-compile/src";
      placeUiShaders =
        rootDir:
        lib.optionalString (config.packages ? ui-shaders) ''
          chmod -R u+w "${rootDir}"
          install -d "${rootDir}/libs/ui/generated/shaders"
          cp ${config.packages.ui-shaders}/*.frag ${config.packages.ui-shaders}/.stamp \
            "${rootDir}/libs/ui/generated/shaders/"
        '';

      # ELF `.build_info`, Mach-O `__DATA,__build_info`, PE `.bldinfo`.
      # Android `.so` files are ELF even when the builder is Linux; that
      # caller passes `.build_info` itself.
      buildInfoSectionName =
        if pkgs.stdenv.hostPlatform.isWindows then
          ".bldinfo"
        else if pkgs.stdenv.hostPlatform.isDarwin then
          "__DATA,__build_info"
        else
          ".build_info";

      emptyBuildInfoJson = pkgs.writeText "build-info-empty.json" "{}";

      # `target` is a shell word. ELF `--update-section` resizes. Mach-O
      # refuses a larger replacement, so the old section is removed first.
      # A PE section keeps its bytes only when flagged as initialized data;
      # VirtualSize is then the content and SizeOfRawData is file-aligned.
      buildInfoObjcopy =
        {
          section,
          json,
          target,
          replace ? false,
        }:
        let
          sec = lib.escapeShellArg section;
          file = lib.escapeShellArg "${json}";
          drop = lib.optionalString replace "--remove-section ${sec}";
        in
        if section == ".bldinfo" then
          "llvm-objcopy ${drop} --add-section ${sec}=${file} --set-section-flags ${sec}=data,readonly ${target}"
        else if replace && lib.hasInfix "," section then
          "llvm-objcopy --remove-section ${sec} --add-section ${sec}=${file} ${target}"
        else if replace then
          "llvm-objcopy --update-section ${sec}=${file} ${target}"
        else
          "llvm-objcopy --add-section ${sec}=${file} ${target}";

      # Direct native inputs, keyed by pname. A `dev` output is dropped
      # when that pname is already listed, whatever order the list has.
      nativeComponents =
        pkgsList:
        let
          described = map (pkg: {
            pname = pkg.pname or pkg.name;
            dev = (pkg.outputName or "out") == "dev";
            value = {
              version = pkg.version or "unknown";
              storePath = pkg.outPath;
            };
          }) pkgsList;
          mainNames = map (d: d.pname) (lib.filter (d: !d.dev) described);
          kept = lib.filter (d: !d.dev || !(lib.elem d.pname mainNames)) described;
        in
        lib.listToAttrs (
          map (d: {
            name = d.pname;
            value = d.value;
          }) kept
        );

      inTreeComponents =
        names:
        lib.listToAttrs (
          map (n: {
            name = "sparkles:${n}";
            value = {
              version = "in-tree";
            };
          }) names
        );

      sparklesBuildInfo =
        {
          name,
          version,
          buildType ? "checked",
          links ? { },
          components ? { },
        }:
        let
          short = inputs.self.shortRev or null;
          dirtyRev = inputs.self.dirtyShortRev or null;
          commit =
            if short != null then
              short
            else if dirtyRev != null then
              lib.removeSuffix "-dirty" dirtyRev
            else
              null;
          # A clean rev still records dirty = false. Neither rev: omit both.
          dirty = short == null && dirtyRev != null;
          document = {
            inherit name version buildType;
          }
          // lib.optionalAttrs (commit != null) { inherit commit dirty; }
          // lib.optionalAttrs (links != { }) { inherit links; }
          // {
            inherit components;
          };
        in
        {
          inherit document;
          json = builtins.toJSON document;
        };

      # The about-page contract for a terminal-shaped document: in-tree
      # sparkles packages carry no store path, a linked native input does,
      # and the dev output and PATH-only wrappers stay out.
      assertDirectBuildInfo =
        doc:
        let
          c = doc.components;
          base = c."sparkles:base" or { };
          vt = c."libghostty-vt" or { };
          hasRev = (inputs.self.shortRev or null) != null || (inputs.self.dirtyShortRev or null) != null;
        in
        assert lib.assertMsg (base.version or "" == "in-tree") "sparkles:base.version must be in-tree";
        assert lib.assertMsg (!(base ? storePath)) "sparkles:base must not carry a storePath";
        assert lib.assertMsg (
          vt ? storePath && lib.hasPrefix "/nix/store/" vt.storePath
        ) "libghostty-vt.storePath must be a store path";
        assert lib.assertMsg (
          !(lib.hasSuffix "-dev" vt.storePath)
        ) "libghostty-vt must be the output that was linked, not its dev output";
        assert lib.assertMsg (!(c ? fontconfig)) "fontconfig is a PATH wrapper, not a linked input";
        assert lib.assertMsg (lib.all (n: !(lib.hasSuffix ".dev" n)) (
          lib.attrNames c
        )) "a dev output must not be its own component";
        assert lib.assertMsg (
          if hasRev then (doc ? commit && doc ? dirty) else (!(doc ? commit) && !(doc ? dirty))
        ) "commit and dirty are present exactly when the flake has a rev";
        assert lib.assertMsg (
          !(c ? "sparkles:test-utils")
        ) "test-utils is a test configuration, not a linked input";
        assert lib.assertMsg (
          !(c ? "sparkles:test-runner")
        ) "the test-runner shim is an import path for UDAs, not a linked input";
        assert lib.assertMsg (
          !(c ? "sparkles:test-runner-impl")
        ) "test-runner-impl is linked only into a test binary";
        assert lib.assertMsg (
          !(c ? "sparkles:ui-tui") && !(c ? "sparkles:tui")
        ) "the gui configuration does not link the tui backend";
        doc;
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
        componentNames = shippedComponentNames;
        refsIn = refsOf;
        inherit sourceFor manifestFileset;
        inherit needsUiShaders uiShaderDirs placeUiShaders;
      };

      # The build stamp an application reports as its version and commit
      # (`sparkles.base.build_stamp`, docs/specs/terminal/pages.md `TPG2`): a
      # directory holding `sparkles-build-stamp`, for the compiler's `-J`.
      # Only a release build (`withCommit`) records the commit — and then a
      # tree with uncommitted changes is stamped `<rev>-dirty`, never as its
      # last commit. Every other build carries the version alone, so it stays
      # cached across commits that do not touch its sources. `components`
      # names the versions of what it links in (an about page lists them,
      # `TPG1`), as `component.<name>=<version>` lines.
      legacyPackages.sparklesBuildInfo = sparklesBuildInfo;
      legacyPackages.assertDirectBuildInfo = assertDirectBuildInfo;
      legacyPackages.buildInfoObjcopy = buildInfoObjcopy;
      legacyPackages.emptyBuildInfoJson = emptyBuildInfoJson;

      legacyPackages.mkBuildStamp =
        {
          version,
          withCommit ? false,
          components ? { },
        }:
        let
          rev = if withCommit then inputs.self.shortRev or inputs.self.dirtyShortRev or null else null;
        in
        pkgs.writeTextDir "sparkles-build-stamp" (
          "version=${version}\n"
          + lib.optionalString (rev != null) "commit=${rev}\n"
          + lib.concatStrings (lib.mapAttrsToList (n: v: "component.${n}=${v}\n") components)
        );

      # Step 1 is `buildDubPackage` plus a stable `{}` section and no
      # wrapper. Step 2 copies it, replaces the section with the JSON, then
      # runs the caller's `postFixup` (makeWrapper records the ELF it execs,
      # so the wrapper has to be written after the replace). The commit is
      # read only while building step 2.
      legacyPackages.buildSparklesApp =
        let
          unstampedSparklesApp = lib.extendMkDerivation {
            constructDrv = pkgs.buildDubPackage;

            # `sourceDirs` and `links` are consumed here, not mkDerivation attributes.
            excludeDrvArgNames = [
              "sourceDirs"
              "links"
            ];

            extendDrvArgs =
              finalAttrs: args:
              let
                # Explicit `sourceDirs` override, else the computed closure.
                srcDirs = args.sourceDirs or (sparklesSrcClosure "apps/${finalAttrs.pname}");
                # ImportC's headers and the linked shaping libraries travel with
                # every raylib-text consumer, including transitive UI consumers.
                shapingInputs = lib.optionals (builtins.elem "libs/raylib-text/src" srcDirs) [
                  pkgs.freetype
                  pkgs.freetype.dev
                  pkgs.harfbuzz
                  pkgs.harfbuzz.dev
                ];
                buildInputs = (args.buildInputs or [ ]) ++ shapingInputs;
                dubBuildType = args.dubBuildType or "checked";
                buildInfoComponents =
                  inTreeComponents (shippedComponentNames "apps/${finalAttrs.pname}") // nativeComponents buildInputs;

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
                # The compiler underneath, when `compiler` is a wrapper — which the
                # repo's is: `nix/d-toolchain.nix` `symlinkJoin`s over dlang.nix's
                # ldc to fix its config and dynamic linker. druntime's asserts bake
                # `__FILE__` strings naming the *inner* path into every binary
                # (`…-ldc-1.42.0/include/d/core/atomic.d`), so scrubbing only the
                # join removed a path that was never there while `disallowedReferences`
                # asserted against that same absent path — the leak passed straight
                # through the check meant to catch it. One surviving dead string was
                # worth 1.4 GiB of closure (ldc-binary + llvm-lib + gcc-wrapper).
                ++ lib.optionals (compiler ? unwrapped) [ compiler.unwrapped ]
                ++ [
                  pkgs.curl.out
                  pkgs.tzdata
                ];
                disallowed = lib.subtractLists buildInputs (args.disallowedReferences or defaultDisallowed);
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
                inherit dubBuildType;

                # Not part of the derivation hash. Step 2 reads these; step 1's
                # builder must not.
                passthru = (args.passthru or { }) // {
                  callerPostFixup = args.postFixup or "";
                  buildInfoLinks = args.links or { };
                  buildInfoBuildType = dubBuildType;
                  inherit buildInfoComponents;
                };

                src = args.src or (sourceFor (srcDirs ++ uiShaderDirs srcDirs));
                sourceRoot = args.sourceRoot or "${finalAttrs.src.name}/apps/${finalAttrs.pname}";

                nativeBuildInputs =
                  (args.nativeBuildInputs or [ ])
                  ++ [
                    pkgs.makeWrapper
                    pkgs.llvmPackages.llvm
                  ]
                  ++ lib.optional (shapingInputs != [ ]) pkgs.pkg-config;
                inherit buildInputs;

                # dub writes into the unpacked (read-only) source tree.
                preBuild =
                  (args.preBuild or ''chmod -R u+w "$NIX_BUILD_TOP"'')
                  + "\n"
                  + lib.optionalString (needsUiShaders srcDirs) (
                    placeUiShaders "$NIX_BUILD_TOP/${finalAttrs.src.name}"
                  );

                installPhase =
                  args.installPhase or ''
                    install -Dm755 build/${finalAttrs.pname} $out/bin/${finalAttrs.pname}
                  '';

                disallowedReferences = disallowed;

                # Scrub compiler leaks, then add the stable `{}` section. The
                # caller's wrapper runs in step 2, after the JSON replaces it.
                postFixup =
                  (lib.optionalString (disallowed != [ ]) ''
                    find "$out" -type f -exec remove-references-to ${scrubFlags} '{}' +
                  '')
                  + ''
                    if [ -f "$out/bin/${finalAttrs.pname}" ]; then
                      ${buildInfoObjcopy {
                        section = buildInfoSectionName;
                        json = emptyBuildInfoJson;
                        target = ''"$out/bin/${finalAttrs.pname}"'';
                      }}
                    fi
                  '';
              };
          };

          stampSparklesApp =
            step1:
            let
              pname = step1.pname;
              version = step1.version or "0.1.0";
              info = sparklesBuildInfo {
                name = "sparkles:${pname}";
                inherit version;
                buildType = step1.passthru.buildInfoBuildType or "checked";
                links = step1.passthru.buildInfoLinks or { };
                components = step1.passthru.buildInfoComponents or { };
              };
              json = pkgs.writeText "build-info.json" info.json;
            in
            pkgs.runCommand "${pname}-${version}"
              {
                inherit pname version;
                dontStrip = true;
                nativeBuildInputs = [
                  pkgs.llvmPackages.llvm
                  pkgs.makeWrapper
                ];
                passthru = {
                  unstamped = step1;
                  buildInfo = info.document;
                };
                meta = step1.meta or { };
              }
              ''
                cp -a ${step1} "$out"
                chmod -R u+w "$out"
                if [ -f "$out/bin/${pname}" ]; then
                  ${buildInfoObjcopy {
                    section = buildInfoSectionName;
                    json = json;
                    target = ''"$out/bin/${pname}"'';
                    replace = true;
                  }}
                fi
                ${step1.passthru.callerPostFixup or ""}
              '';
        in
        callerArgs: stampSparklesApp (unstampedSparklesApp callerArgs);
    };
}
