{ lib, ... }:
{
  perSystem =
    { config, pkgs, ... }:
    let
      inherit (config.legacyPackages.dubBuilder)
        mkDubDerivation
        buildDubDeps
        sharesArtifacts
        ;

      fs = lib.fileset;
      root = ../..;
      fromRoot = lib.path.append root;

      # `manifestFileset` — the root recipe plus the manifests of the
      # sub-packages it declares — is shared with `buildSparklesApp` so both
      # builders agree on what dub needs on disk, and so neither is invalidated
      # by a `dub.sdl` under `docs/research/**` or `libs/*/bench/**`.
      # `libsClosure`/`refsIn` are the same manifest-walking fixpoint the app
      # builder uses, reused here to size each lib's example source tree.
      inherit (config.legacyPackages.sparklesSources)
        manifestFileset
        libsClosure
        refsIn
        ;

      # Enumerate every standalone `.d` example across all libs as a flat list
      # of absolute paths.
      #
      # Every `.d` directly under `libs/*/examples/` is an example. Deeper down,
      # one is an example only when it is named after the directory holding it —
      # `examples/cli/git/git.d`. That is the shape of an example too big for
      # one file: the program plus the `views/` tree it reads its help from,
      # in a directory of their own.
      #
      # The name test is what keeps the rest of a nested tree out. Anything else
      # under `examples/` is input data rather than a program to build:
      # `libs/twoslash-d/examples/src/*.d` are analyzer samples the extractor
      # reads (with their `fixtures/` payloads beside them), and globbing
      # recursively had `.#all` trying to `dub --single` all 36 of them — each
      # failing, since they are not single-file dub scripts.
      exampleFilesIn =
        libName:
        let
          top = fromRoot "libs/${libName}/examples";
          # `nested` is false only at the `examples/` root, where a `.d` child
          # needs no directory to match.
          walk =
            dir: nested:
            lib.pipe (builtins.readDir dir) [
              (lib.mapAttrsToList (
                entry: type:
                if type == "directory" then
                  walk (dir + "/${entry}") true
                else if
                  type == "regular"
                  && lib.hasSuffix ".d" entry
                  && (!nested || lib.removeSuffix ".d" entry == baseNameOf dir)
                then
                  [ (dir + "/${entry}") ]
                else
                  [ ]
              ))
              lib.concatLists
            ];
        in
        if !builtins.pathExists top then [ ] else walk top false;

      allExampleFiles = lib.pipe (builtins.readDir (fromRoot "libs")) [
        (lib.filterAttrs (_: type: type == "directory"))
        (lib.mapAttrsToList (name: _: exampleFilesIn name))
        lib.concatLists
      ];

      # The `src/` trees a lib's examples compile against, as one fileset.
      #
      # An example may `dependency` on any sibling sub-package (e.g. `tree.d`
      # pulls in `build-primitives`), and those packages in turn reach further
      # ones — `core-cli` imports `math` (ScreenSize) via importPaths. Rather
      # than guess, seed the app builder's manifest-walking fixpoint from what
      # each example's inline recipe actually declares.
      #
      # This is deliberately computed per *lib*, not per example: a lib's
      # examples share one `buildDubDeps` bundle, and `nix/packages/dub-builder`
      # requires a bundle and its consumers to be built from the same `src`
      # (normalising dub's mtimes disables its own staleness check). Seeding
      # from `exampleFilesIn` — the unfiltered list — also keeps the tree
      # identical across platforms, where `platforms`-restricted examples drop
      # out of the derivation set.
      #
      # The previous rule unioned *every* lib's sources into every example, so a
      # `libs/twoslash-d` edit rebuilt all ~35 example derivations and their
      # bundles — and, through the `gen-text-svg` hook's use of
      # `examples.base."text-cell-svg"`, the dev shell.
      libSourcesFor =
        libName:
        fs.unions (
          map
            (dir: fs.fileFilter (file: file.hasExt "d" || file.hasExt "c" || file.hasExt "i") (fromRoot dir))
            (
              libsClosure (
                [ libName ] ++ lib.concatMap (p: refsIn (builtins.readFile p)) (exampleFilesIn libName)
              )
            )
        );

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
          # (`build/<name>`), which can differ from the file's basename — the
          # two answer to different conventions. Filenames are kebab-case, while
          # a dub name is often qualified and identifier-safe to keep it unique
          # across the workspace: `pty-drain.d` declares
          # `name "event_horizon_pty_drain"`. Parse it, falling back to the
          # basename when no `name` line is present.
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
          # Where the example's own dub package rooted: the directory holding
          # the `.d` file. For a direct child of `examples/` that is
          # `examplesRel`; for a nested example it is its own directory, which
          # is what makes `views/` resolve next to the script.
          parentDirRel = lib.concatStringsSep "/" (lib.init parts);
          examplePathRel = lib.concatStringsSep "/" parts;
        };

      # What a manifest's `platforms` entries may name. dub's vocabulary is not
      # nix's — it says `osx` where the system string says `aarch64-darwin`, and
      # says `posix`, which appears in no system string at all — so matching
      # bare against `hostPlatform.system` silently excludes those everywhere.
      # This must agree with `hostPlatformTokens` in
      # `apps/ci/src/example_manifest.d`: the two decide the same question, and
      # a disagreement means an example nix builds is skipped by
      # `ci --example-files`, or the reverse.
      hostPlatformTokens = [
        pkgs.stdenv.hostPlatform.system
      ]
      ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
        "linux"
        "posix"
      ]
      ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
        "osx"
        "darwin"
        "posix"
      ]
      ++ lib.optional pkgs.stdenv.hostPlatform.isWindows "windows";

      # Does this example's manifest allow the system we are building for?
      # An empty `platforms` means unrestricted.
      buildableHere =
        examplePath:
        let
          p = builtins.filter (x: x != "") (exampleInfo examplePath).platforms;
        in
        p == [ ] || builtins.any (want: builtins.any (lib.hasInfix want) hostPlatformTokens) p;

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
            manifestFileset
            # Library sources the examples link against via
            # `dependency "sparkles:<lib>" path="../../.."`, transitively — see
            # `libSourcesFor`.
            (libSourcesFor libName)
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

        # `checked` — the repo-wide artifact build (see the note on
        # `buildSparklesApp`). Assertions live, which is the whole point of
        # running the examples in CI: under `-release` an example that asserts
        # its own result and exits 0 has verified nothing, and one that
        # performs I/O inside an assert doesn't even do the I/O — which is how
        # `fiber-echo` came to hang for 13 minutes on a 20-minute-capped job.
        dubBuildType = "checked";

        # Examples that depend on sparkles:syntax (or other ImportC bindings)
        # need pkg-config + the C library so dub#3085 can feed -P-I...
        # to ImportC for headers like <tree_sitter/api.h>.
        # Default configs only — event-horizon's opt-in `libkqueue` path is a
        # devshell `dub -c libkqueue` run.
        nativeBuildInputs = [ pkgs.pkg-config ];
        buildInputs = [
          pkgs.tree-sitter

          # `libs "vulkan"` in libs/vulkan. `vulkan.pc` lives in the loader's
          # `.dev` output and points `includedir` at vulkan-headers, so one
          # entry gives ImportC the header path and the linker its flags.
          # The dev shell has these; this derivation is a separate closure and
          # needs them too, or `<vulkan/vulkan.h>` is simply absent.
          pkgs.vulkan-loader
          pkgs.vulkan-loader.dev

          # `libs "SDL3"` in libs/ui-sdl3, same reasoning: `.dev` carries
          # `sdl3.pc`, `.lib` is what the built example loads at runtime.
          pkgs.sdl3
          pkgs.sdl3.dev
        ];
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
              subdir = (exampleInfo path).parentDirRel;
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
          // lib.optionalAttrs (artifacts != null) { dubArtifacts = artifacts; }
          // {
            pname = "${info.libName}-example-${info.fileBase}";

            src = srcForLib info.libName;
            # Where to build inside the normalised source tree (the vendored
            # builder's replacement for `sourceRoot`, which cannot vary: the
            # tree root is pinned so artifacts hash identically).
            dubSubdir = info.parentDirRel;

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
              description = "Standalone example: ${info.examplePathRel}";
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
            # Where the build path isn't pinned (Darwin), a bundle is an
            # extra full build that nothing can hit — see `sharesArtifacts`.
            artifacts = if sharesArtifacts then depsForLib libName paths else null;
          in
          lib.listToAttrs (
            map (path: {
              name = (exampleInfo path).fileBase;
              value = mkExamplePackage artifacts path;
            }) paths
          )
        ))
      ];

      # Faithful port of ci's `parseStandaloneExampleSpec` (apps/ci/src/app.d):
      # skip the shebang and the inline `/+ dub.sdl: … +/` block, then scan the
      # header comment — the first `// ci:` / `// run_md_examples:` directive
      # decides the mode, and the header ends at the first non-comment line.
      #
      # The directive's first word is the mode; anything after it is the
      # program's arguments (`// ci: run --help`). Keep both in step with ci's
      # reader — an example that needs arguments to exit zero fails here
      # otherwise.
      exampleSpec =
        examplePath:
        let
          step =
            acc: rawLine:
            let
              line = lib.trim rawLine;
              directive =
                prefix:
                let
                  value = lib.trim (lib.removePrefix prefix line);
                  words = builtins.filter (w: builtins.isString w && w != "") (builtins.split "[[:space:]]+" value);
                  modeWord = if words == [ ] then "run" else lib.toLower (builtins.head words);
                in
                acc
                // (
                  if modeWord == "build-only" then
                    {
                      mode = "build-only";
                      runArgs = [ ];
                    }
                  else
                    {
                      mode = "run";
                      runArgs = if words == [ ] then [ ] else builtins.tail words;
                    }
                );
            in
            if acc.mode != null || line == "" || lib.hasPrefix "#!" line then
              acc
            else if acc.insideDubSdl then
              acc // { insideDubSdl = !lib.hasPrefix "+/" line; }
            else if lib.hasPrefix "/+ dub.sdl:" line then
              acc // { insideDubSdl = true; }
            # A `module …;` declaration may sit between the recipe and the
            # directive. It is not a comment, so without this the scan would
            # stop at it (the `!hasPrefix "//"` branch below) and ignore the
            # directive — the example would run when it asked to be built only.
            else if lib.hasPrefix "module " line && lib.hasSuffix ";" line then
              acc
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
            runArgs = [ ];
            insideDubSdl = false;
          } (lib.splitString "\n" (builtins.readFile examplePath));
        in
        {
          mode = if result.mode == null then "run" else result.mode;
          inherit (result) runArgs;
        };

      # Every example paired with its derivation and ci-equivalent mode.
      # Filtered exactly like `examplesByLib`: a manifest that restricts its
      # `platforms` has no derivation on other systems, so mapping over the
      # unfiltered list would look up a missing attribute (on Darwin the
      # `event-horizon` group holds only `fiber-echo`, the one example that is
      # not `platforms "linux"` — `attribute 'callback-echo' missing`).
      annotatedExamples = map (
        path:
        let
          info = exampleInfo path;
        in
        {
          label = "${info.libName}/${info.fileBase}";
          inherit (exampleSpec path) mode runArgs;
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
                if ! ${lib.getExe ex.drv} ${lib.escapeShellArgs ex.runArgs}; then
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
