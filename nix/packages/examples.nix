{ lib, ... }:
{
  perSystem =
    { config, pkgs, ... }:
    let
      inherit (config.legacyPackages) nativeLibs;
      inherit (config.legacyPackages.dubBuilder)
        mkDubDerivation
        buildDubDeps
        sharesArtifacts
        ;

      # The catalogue (nix/packages/example-catalogue.nix).
      inherit (config.legacyPackages.exampleCatalog)
        allExampleFiles
        exampleFilesIn
        exampleInfo
        buildableHere
        textOf
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
        placeVulkanWsiShaders
        needsUiShaders
        needsUiVulkanShaders
        uiShaderDirs
        placeUiShaders
        placeUiVulkanShaders
        ;

      # The triangle examples select sparkles:vulkan-wsi's `gpu-shaders`
      # configuration, whose pre-generate step finds the prebuilt SPIR-V
      # (`vulkan-wsi-shaders`) fresh, but still builds `shader-compile` to
      # read its stamp, hence the tool's sources. Placed with the tree's
      # normalised mtime, so a lib's bundle and its examples see one tree.
      selectsVulkanWsiShaders =
        libName: builtins.any (p: lib.hasInfix ''"gpu-shaders"'' (textOf p)) (exampleFilesIn libName);
      vulkanWsiShadersFor =
        libName:
        lib.optionalString (selectsVulkanWsiShaders libName) (
          placeVulkanWsiShaders "$dubTreeRoot"
          + ''
            find "$dubTreeRoot/libs/vulkan-wsi/generated" -exec touch -h -d "@1" '{}' +
          ''
        );

      uiShadersFor =
        libName:
        let
          dirs = libSourceDirsFor libName;
        in
        lib.optionalString (needsUiShaders dirs) (
          placeUiShaders "$dubTreeRoot"
          + ''
            find "$dubTreeRoot/libs/ui/generated" -exec touch -h -d "@1" '{}' +
          ''
        )
        + lib.optionalString (needsUiVulkanShaders dirs) (
          placeUiVulkanShaders "$dubTreeRoot"
          + ''
            find "$dubTreeRoot/libs/ui-vulkan/generated" -exec touch -h -d "@1" '{}' +
          ''
        );

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
      libSourceDirsFor =
        libName: libsClosure ([ libName ] ++ lib.concatMap (p: refsIn (textOf p)) (exampleFilesIn libName));
      libSourcesFor =
        libName:
        fs.unions (
          map (
            dir:
            fs.fileFilter (
              # `.h`: libs/wsi's ImportC bridges include vendored protocol
              # headers (`wayland_xdg_shell_client_protocol.h`) from src/.
              # `.spv`: libs/vulkan-wsi string-imports its test pattern's
              # shaders from `src/shaders/`.
              file:
              file.hasExt "d"
              || file.hasExt "c"
              || file.hasExt "i"
              || file.hasExt "h"
              || file.hasExt "spv"
              # sparkles:ui's generated effect GLSL, string-imported by effect.d
              || file.hasExt "frag"
            ) (fromRoot dir)
          ) (libSourceDirsFor libName)
        );

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
          fileset = fs.unions (
            [
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
            ]
            ++ lib.optional (selectsVulkanWsiShaders libName) (fromRoot "apps/shader-compile/src")
            ++ map fromRoot (uiShaderDirs (libSourceDirsFor libName))
          );
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
        # Maps its own store paths out of the examples (nix/d-toolchain.nix).
        compiler = pkgs.ldc.reproducible;

        # Examples that depend on sparkles:syntax (or other ImportC bindings)
        # need pkg-config + the C library so dub#3085 can feed -P-I...
        # to ImportC for headers like <tree_sitter/api.h>.
        # Default configs only — event-horizon's opt-in `libkqueue` path is a
        # devshell `dub -c libkqueue` run.
        nativeBuildInputs = [ pkgs.pkg-config ];
        buildInputs = [
          pkgs.tree-sitter
          pkgs.raylib
        ]
        ++ nativeLibs.shaping
        ++ nativeLibs.vulkan
        ++ [
          # `libs "SDL3"` in libs/ui-sdl3, same reasoning: `.dev` carries
          # `sdl3.pc`, `.lib` is what the built example loads at runtime.
          pkgs.sdl3
          pkgs.sdl3.dev
        ]
        ++ nativeLibs.wsi;
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
            preBuild = vulkanWsiShadersFor libName + uiShadersFor libName;
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
          compiler = commonExampleArgs.compiler;
          # Every layer of the compiler, asserted absent: it maps its own paths
          # out of `__FILE__` and debug info, so nothing of it is removed.
          compilerPaths = [
            compiler
            compiler.unwrapped
          ]
          ++ lib.optional (compiler.unwrapped ? unwrapped) compiler.unwrapped.unwrapped;
          # Phobos' service paths, removed (see below).
          servicePaths = [
            pkgs.curl.out
            pkgs.tzdata
          ];
        in
        mkDubDerivation (
          commonExampleArgs
          // lib.optionalAttrs (artifacts != null) { dubArtifacts = artifacts; }
          // {
            pname = "${info.libName}-example-${info.fileBase}";

            src = srcForLib info.libName;
            preBuild = vulkanWsiShadersFor info.libName + uiShadersFor info.libName;
            # Where to build inside the normalised source tree (the vendored
            # builder's replacement for `sourceRoot`, which cannot vary: the
            # tree root is pinned so artifacts hash identically).
            dubSubdir = info.parentDirRel;

            # Phobos compiles two store paths into itself: the nixpkgs-patched
            # `libcurl.so.4` dlopen path (which alone pulls the ~18 MiB
            # openssl/krb5/nghttp tail) and the tzdata dir. No example touches
            # std.net.curl or named time zones — the run-all-examples runner
            # exercises them all — so they are removed. NB: `pkgs.curl.out` is
            # libcurl's output; bare `pkgs.curl` coerces to the `-bin` output.
            disallowedReferences = compilerPaths ++ servicePaths;
            preFixup = ''
              find "$out" -type f -exec remove-references-to \
                ${lib.concatMapStringsSep " " (r: "-t ${r}") servicePaths} '{}' +
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

    in
    {
      legacyPackages.examples = examplesByLib;
    };
}
