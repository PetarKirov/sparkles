# The standalone examples' catalogue, read at evaluation time: every
# `libs/*/examples` program with an inline dub recipe, its file's text, what
# its path and recipe say (`exampleInfo`), where it may build
# (`buildableHere`), and how `ci --example-files` runs it (`exampleSpec`).
# Exported as `legacyPackages.exampleCatalog` for the example builder
# (examples.nix), `run-all-examples` and the Android examples.
{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      root = ../..;
      fromRoot = lib.path.append root;

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
      #
      # The recipe test keeps out `.d` files that sit directly in `examples/`
      # but are not single-file dub programs: conformance drivers built by a
      # lib's `scripts/verify-*.sh` with a bare compiler invocation, and the
      # helper modules they import (`libs/wsi/examples/`). `dub --single`
      # requires the inline `/+ dub.sdl:` comment, so a file without one can
      # never build here — skip it instead of failing the whole example set.
      candidateFilesIn =
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

      libNames = lib.attrNames (
        lib.filterAttrs (_: type: type == "directory") (builtins.readDir (fromRoot "libs"))
      );

      # Evaluation reads each candidate file once, and works out each
      # example's files, info and run spec once, however many places ask:
      # these attribute sets are the memo (a function call is not).
      texts = lib.listToAttrs (
        map (p: lib.nameValuePair (toString p) (builtins.readFile p)) (
          lib.concatMap candidateFilesIn libNames
        )
      );
      textOf = p: texts.${toString p} or (builtins.readFile p);
      linesOf = p: lib.splitString "\n" (textOf p);

      examplesIn = lib.genAttrs libNames (
        libName: builtins.filter (p: lib.hasInfix "dub.sdl:" (textOf p)) (candidateFilesIn libName)
      );
      exampleFilesIn = libName: examplesIn.${libName} or [ ];

      allExampleFiles = lib.concatMap exampleFilesIn libNames;

      # Decompose an absolute example path into the metadata needed for the
      # derivation (lib name, file basename, attribute name, sub-paths).
      mkExampleInfo =
        examplePath:
        let
          lines = linesOf examplePath;
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
          nameMatches = builtins.filter (l: builtins.match nameRe l != null) lines;
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
          platformsMatches = builtins.filter (l: builtins.match platformsRe l != null) lines;
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
      infos = lib.listToAttrs (map (p: lib.nameValuePair (toString p) (mkExampleInfo p)) allExampleFiles);
      exampleInfo = p: infos.${toString p} or (mkExampleInfo p);

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

      # Faithful port of ci's `parseStandaloneExampleSpec` (apps/ci/src/app.d):
      # skip the shebang and the inline `/+ dub.sdl: … +/` block, then scan the
      # header comment — the first `// ci:` / `// run_md_examples:` directive
      # decides the mode, and the header ends at the first non-comment line.
      #
      # The directive's first word is the mode; anything after it is the
      # program's arguments (`// ci: run --help`). Keep both in step with ci's
      # reader — an example that needs arguments to exit zero fails here
      # otherwise.
      mkExampleSpec =
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
          } (linesOf examplePath);
        in
        {
          mode = if result.mode == null then "run" else result.mode;
          inherit (result) runArgs;
        };
      specs = lib.listToAttrs (map (p: lib.nameValuePair (toString p) (mkExampleSpec p)) allExampleFiles);
      exampleSpec = p: specs.${toString p};
    in
    {
      # Every example file with an inline recipe, whatever its `platforms`,
      # and what its path and recipe say. `nix/packages/android/examples.nix`
      # builds the `platforms "android"` ones as APKs.
      legacyPackages.exampleCatalog = {
        inherit
          allExampleFiles
          exampleFilesIn
          exampleInfo
          exampleSpec
          buildableHere
          textOf
          ;
      };
    };
}
