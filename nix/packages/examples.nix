{ lib, ... }:
{
  perSystem =
    { config, pkgs, ... }:
    let
      inherit (config.legacyPackages.dubBuilder) mkDubDerivation buildDubDeps;

      fs = lib.fileset;
      root = ../..;
      fromRoot = lib.path.append root;

      isDubManifest =
        file:
        builtins.elem file.name [
          "dub.sdl"
          "dub.selections.json"
        ];

      # Enumerate every standalone `.d` example across all libs as a flat list
      # of absolute paths — `libs/*/examples/*.d`, the $(I direct) children
      # only. A nested tree under `examples/` is input data, not a program to
      # build: `libs/twoslash-d/examples/src/*.d` are analyzer samples the
      # extractor reads (with their `fixtures/` payloads beside them), and
      # globbing recursively had `.#all` trying to `dub --single` all 36 of
      # them — each failing, since they are not single-file dub scripts.
      exampleFilesIn =
        libName:
        let
          dir = fromRoot "libs/${libName}/examples";
        in
        if !builtins.pathExists dir then
          [ ]
        else
          lib.pipe (builtins.readDir dir) [
            (lib.filterAttrs (file: type: type == "regular" && lib.hasSuffix ".d" file))
            (lib.mapAttrsToList (file: _: dir + "/${file}"))
          ];

      allExampleFiles = lib.pipe (builtins.readDir (fromRoot "libs")) [
        (lib.filterAttrs (_: type: type == "directory"))
        (lib.mapAttrsToList (name: _: exampleFilesIn name))
        lib.concatLists
      ];

      # Every lib's `src/` tree, as one fileset. An example may `dependency` on
      # any sibling sub-package (e.g. `tree.d` pulls in `build-primitives`), and
      # `core-cli` additionally imports `math` (ScreenSize) via importPaths — so
      # rather than guess the transitive set per example, include them all (a
      # `dub build --single` only compiles what the example actually reaches).
      allLibSources = lib.pipe (builtins.readDir (fromRoot "libs")) [
        (lib.filterAttrs (_: type: type == "directory"))
        (lib.mapAttrsToList (name: _: fs.maybeMissing (fromRoot "libs/${name}/src")))
        fs.unions
        (fs.intersection (
          fs.fileFilter (file: file.hasExt "d" || file.hasExt "c" || file.hasExt "i") (fromRoot "libs")
        ))
      ];

      # Decompose an absolute example path into the metadata needed for the
      # derivation (lib name, file basename, attribute name, sub-paths).
      exampleInfo =
        examplePath:
        let
          subpath = lib.path.removePrefix root examplePath;
          parts = lib.splitString "/" (lib.removePrefix "./" subpath);
          libName = builtins.elemAt parts 1;
          fileBase = lib.removeSuffix ".d" (lib.last parts);

          # The example's inline `dub.sdl` `name` determines the built binary
          # (`build/<name>`), which can differ from the file's basename: a
          # single-file D script's module name comes from the filename, so it
          # must be a valid identifier (`git_clean.d`), while the dub package
          # name may be kebab-case (`name "git-clean"`). Parse it, falling back
          # to the basename when no `name` line is present.
          nameRe = "[[:space:]]*name[[:space:]]+\"([^\"]+)\".*";
          nameMatches = builtins.filter (l: builtins.match nameRe l != null) (
            lib.splitString "\n" (builtins.readFile examplePath)
          );
          dubName =
            if nameMatches == [ ] then
              fileBase
            else
              builtins.head (builtins.match nameRe (builtins.head nameMatches));
          # dub's `platforms "linux"` restricts where a recipe is buildable.
          # Honour it here: without this, an example that imports Linux-only
          # modules (inotify/proc/watch — the M7 agent-tooling demo) is still
          # handed to the Darwin builder and fails the whole example set, even
          # though its own manifest says it is Linux-only.
          platformsRe = "[[:space:]]*platforms[[:space:]]+(.*)";
          platformsMatches = builtins.filter (l: builtins.match platformsRe l != null) (
            lib.splitString "\n" (builtins.readFile examplePath)
          );
          platforms =
            if platformsMatches == [ ] then
              [ ] # unrestricted
            else
              # `platforms "linux" "windows"` → the quoted words
              builtins.filter (m: builtins.isString m) (
                builtins.split "[^[:alnum:]_-]+" (
                  builtins.head (builtins.match platformsRe (builtins.head platformsMatches))
                )
              );
        in
        {
          inherit
            libName
            fileBase
            dubName
            platforms
            ;
          examplesRel = "libs/${libName}/examples";
        };

      # Does this example's manifest allow the system we are building for?
      # An empty `platforms` means unrestricted.
      buildableHere =
        examplePath:
        let
          p = builtins.filter (x: x != "") (exampleInfo examplePath).platforms;
        in
        p == [ ] || builtins.any (want: lib.hasInfix want pkgs.stdenv.hostPlatform.system) p;

      # The source tree an example compiles from. It is a function of the
      # *lib*, not of the individual example — every example of a lib sees the
      # same files — and that is exactly what lets them share one compiled
      # dependency bundle: `nix/packages/dub-builder` requires a bundle and its
      # consumers to be built from the same `src`, since normalising dub's
      # mtimes disables its own staleness check.
      srcForLib =
        libName:
        fs.toSource {
          inherit root;
          fileset = fs.unions [
            # Dub validates every sub-package declared in the root `dub.sdl`,
            # so all sibling manifests must be present even when only one
            # example is being built.
            (fs.fileFilter isDubManifest root)
            # Library sources the example links against via
            # `dependency "sparkles:<lib>" path="../../.."` — plus the impl
            # runner sources `base`/`core-cli` import unconditionally, and
            # `math` which `core-cli` reaches via importPaths. See allLibSources.
            allLibSources
            # The full `examples/` subtree — this brings in the shared
            # `views/` string-import assets alongside the script itself.
            (fromRoot "libs/${libName}/examples")
          ];
        };

      # Arguments shared by an example and by the deps bundle it inherits.
      # These must agree: the build type and compiler are part of dub's build
      # ID, so a mismatch turns every cache hit into a rebuild.
      commonExampleArgs = {
        version = "0.1.0";

        # The examples currently depend on the same set of packages as
        # the `ci` helper, so we share a single Nix-format lockfile
        # under `nix/dub-lock.json` instead of generating (and
        # regenerating) one per example. If a future example pulls in
        # an additional dependency, that dep needs to be added to the
        # shared lockfile or split out into its own.
        dubLock = fromRoot "nix/dub-lock.json";
        compiler = pkgs.ldc;
        dubBuildType = "release";

        # Examples that depend on sparkles:syntax (or other ImportC bindings)
        # need pkg-config + the C library so dub#3085 can feed -P-I...
        # to ImportC for headers like <tree_sitter/api.h>.
        nativeBuildInputs = [ pkgs.pkg-config ];
        buildInputs = [ pkgs.tree-sitter ];
      };

      # One bundle per lib, primed by compiling every one of that lib's
      # examples. Each primer after the first is nearly free (it reuses what
      # the ones before it built), so the bundle costs about one example's
      # full build and saves that cost in each of the N per-example
      # derivations, which then only recompile their own module and link.
      depsForLib =
        libName: paths:
        buildDubDeps (
          commonExampleArgs
          // {
            pname = "${libName}-example-deps";
            src = srcForLib libName;
            dubPrimers = map (path: {
              subdir = (exampleInfo path).examplesRel;
              single = "${(exampleInfo path).fileBase}.d";
            }) paths;
          }
        );

      mkExamplePackage =
        artifacts: examplePath:
        let
          info = exampleInfo examplePath;
        in
        mkDubDerivation (
          commonExampleArgs
          // {
            pname = "${info.libName}-example-${info.fileBase}";

            src = srcForLib info.libName;
            # Where to build inside the normalised source tree (the vendored
            # builder's replacement for `sourceRoot`, which cannot vary: the
            # tree root is pinned so artifacts hash identically).
            dubSubdir = info.examplesRel;
            dubArtifacts = artifacts;

            # Phobos bakes store paths into every binary that must not leak into
            # the runtime closure: assert/`__FILE__` strings referencing ldc's
            # separate `include` output (~19 MiB; the builder scrubs and
            # disallows only the compiler's `out` — same story as `release` in
            # ./default.nix), plus the nixpkgs-patched `libcurl.so.4` dlopen
            # path (which alone pulls the ~18 MiB openssl/krb5/nghttp tail) and
            # the tzdata dir. The curl/tzdata paths are phobos *service* paths,
            # but no example touches std.net.curl or named time zones — the
            # run-all-examples runner exercises them all — so scrub and
            # disallow all three. NB: `pkgs.curl.out` — libcurl's output; bare
            # `pkgs.curl` coerces to the `-bin` output.
            disallowedReferences = [
              pkgs.ldc
              pkgs.ldc.include
              pkgs.curl.out
              pkgs.tzdata
            ];
            preFixup = ''
              find "$out" -type f -exec remove-references-to \
                -t ${pkgs.ldc} -t ${pkgs.ldc.include} -t ${pkgs.curl.out} -t ${pkgs.tzdata} '{}' +
            '';

            # The example carries its own inline `dub.sdl` block, so this is
            # `--single` mode against the specific .d file rather than the
            # builder's default package-rooted build.
            buildPhase = ''
              runHook preBuild

              dub build \
                --single ${info.fileBase}.d \
                --compiler="$dubCompiler" \
                --skip-registry=all \
                --build="$dubBuildType"

              runHook postBuild
            '';

            # The inline `dub.sdl` sets `targetPath "build"`, so the binary is
            # `build/<dubName>` — the dub package name, which may differ from the
            # file's basename (see `dubName` in exampleInfo).
            installPhase = ''
              install -Dm755 build/${info.dubName} $out/bin/${info.dubName}
            '';

            meta = {
              description = "Standalone example: ${info.libName}/examples/${info.fileBase}.d";
              mainProgram = info.dubName;
            };
          }
        );

      # Group example derivations by their owning lib:
      # `examples.<lib>.<exampleName>`. Each group shares one deps bundle.
      examplesByLib = lib.pipe (builtins.filter buildableHere allExampleFiles) [
        (lib.groupBy (path: (exampleInfo path).libName))
        (lib.mapAttrs (
          libName: paths:
          let
            artifacts = depsForLib libName paths;
          in
          lib.listToAttrs (
            map (path: {
              name = (exampleInfo path).fileBase;
              value = mkExamplePackage artifacts path;
            }) paths
          )
        ))
      ];

      # Faithful port of ci's `parseStandaloneExampleMode` (apps/ci/src/app.d):
      # skip the shebang and the inline `/+ dub.sdl: … +/` block, then scan the
      # header comment — the first `// ci:` / `// run_md_examples:` directive
      # decides the mode, and the header ends at the first non-comment line.
      exampleMode =
        examplePath:
        let
          step =
            acc: rawLine:
            let
              line = lib.trim rawLine;
              directive =
                prefix:
                acc
                // {
                  mode =
                    if lib.toLower (lib.trim (lib.removePrefix prefix line)) == "build-only" then
                      "build-only"
                    else
                      "run";
                };
            in
            if acc.mode != null || line == "" || lib.hasPrefix "#!" line then
              acc
            else if acc.insideDubSdl then
              acc // { insideDubSdl = !lib.hasPrefix "+/" line; }
            else if lib.hasPrefix "/+ dub.sdl:" line then
              acc // { insideDubSdl = true; }
            else if lib.hasPrefix "// ci:" line then
              directive "// ci:"
            else if lib.hasPrefix "// run_md_examples:" line then
              directive "// run_md_examples:"
            else if !lib.hasPrefix "//" line then
              acc // { mode = "run"; }
            else
              acc;
          result = lib.foldl' step {
            mode = null;
            insideDubSdl = false;
          } (lib.splitString "\n" (builtins.readFile examplePath));
        in
        if result.mode == null then "run" else result.mode;

      # Every example paired with its derivation and ci-equivalent mode.
      # Filtered exactly like `examplesByLib`: a manifest that restricts its
      # `platforms` has no derivation on other systems, so mapping over the
      # unfiltered list would look up a missing attribute (every
      # event-horizon example is `platforms "linux"`, so on Darwin the whole
      # `event-horizon` group is absent — `attribute 'event-horizon' missing`).
      annotatedExamples = map (
        path:
        let
          info = exampleInfo path;
        in
        {
          label = "${info.libName}/${info.fileBase}";
          mode = exampleMode path;
          drv = examplesByLib.${info.libName}.${info.fileBase};
        }
      ) (builtins.filter buildableHere allExampleFiles);
    in
    {
      legacyPackages.examples = examplesByLib;

      # Smoke-run every standalone example the way `ci --example-files` does:
      # `// ci: build-only` examples are built (they are retained in the
      # script's closure) but not executed; the rest run sequentially and any
      # non-zero exit is collected into the final status.
      packages.run-all-examples = pkgs.writeShellApplication {
        name = "run-all-examples";
        text = ''
          failures=0
          ${lib.concatMapStrings (
            ex:
            if ex.mode == "build-only" then
              ''
                echo "⊘ ${ex.label} — build-only, not run (${ex.drv})"
                echo
              ''
            else
              ''
                echo "━━━ ${ex.label} ━━━"
                if ! ${lib.getExe ex.drv}; then
                  echo "✗ ${ex.label} failed"
                  failures=$((failures + 1))
                fi
                echo
              ''
          ) annotatedExamples}
          total=${
            toString (builtins.length (builtins.filter (ex: ex.mode != "build-only") annotatedExamples))
          }
          echo "$((total - failures))/$total examples ran successfully"
          [ "$failures" -eq 0 ]
        '';
      };
    };
}
