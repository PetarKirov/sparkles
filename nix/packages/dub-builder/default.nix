# A dub builder that can share compiled dependencies between derivations.
#
# nixpkgs' `buildDubPackage` gives every derivation a private `$DUB_HOME` and
# unpacks its source under a per-package directory name. That is correct but
# quadratic for a monorepo: each of the ~35 `libs/*/examples/*.d` derivations
# recompiles the whole `sparkles:*` closure it links against, from scratch.
#
# crane solves the same problem for Rust by passing cargo's `target/` between
# derivations. dub's cache is *not* relocatable the way cargo's is, so the
# port needs two extra normalisations, both established by measurement:
#
#   1. **Path.** A build ID hashes the absolute paths of the package's source
#      files, so identical sources under different directories miss. Every
#      derivation therefore compiles from `$NIX_BUILD_TOP/dub-src`, which the
#      sandbox pins to `/build/dub-src` — and `$DUB_HOME` likewise sits at
#      `$NIX_BUILD_TOP/.dub`, since dub records absolute target paths in the
#      per-package `db.json`. Where `$NIX_BUILD_TOP` is *not* pinned — the
#      sandbox disabled, or Darwin, whose sandbox has no `sandbox-build-dir`
#      — every derivation gets a different path and reuse degrades to a full
#      rebuild. That is a slowdown, never a wrong result.
#
#   2. **Time.** `isUpToDate` (dub/generators/build.d) is a pure mtime
#      comparison — a target is reused when no input is *strictly* newer. The
#      inputs of a package include the cached targets of its dependencies, so
#      a `cp` that stamps files in traversal order can make a dependency look
#      newer than the artifact built from it and cascade a rebuild up the
#      chain. The hooks pin the source tree to the epoch and flatten every
#      mtime under `$DUB_HOME` to one instant.
#
# Normalisation (2) disables dub's only staleness check, so **Nix** has to
# provide it instead: an artifact bundle is an input of its consumer, so any
# source edit changes the bundle's hash and a fresh bundle is built. The
# invariant that makes that sound — and the one thing a caller can get wrong —
# is that a bundle must be built from the *same* `src` as the package
# inheriting it. `buildDubDeps` and its consumers are therefore always
# constructed from one shared source fileset.
#
# Exposed as `legacyPackages.dubBuilder` (flake-parts' escape hatch for
# non-derivation values, as with `buildSparklesApp`).
{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      inherit (pkgs)
        stdenv
        dub
        ldc
        makeSetupHook
        importDubLock
        removeReferencesTo
        ;

      dubNormalizeSourceHook = makeSetupHook {
        name = "dub-normalize-source-hook";
      } ./hooks/dub-normalize-source-hook.sh;

      dubHomeSetupHook = makeSetupHook {
        name = "dub-home-setup-hook";
        propagatedBuildInputs = [ dub ];
      } ./hooks/dub-home-setup-hook.sh;

      installDubArtifactsHook = makeSetupHook {
        name = "install-dub-artifacts-hook";
      } ./hooks/install-dub-artifacts-hook.sh;

      # The common base: normalised source path, normalised `$DUB_HOME`,
      # registry dependencies from the lockfile, and an optional inherited
      # artifact bundle. Everything else is plain `mkDerivation`.
      mkDubDerivation = lib.extendMkDerivation {
        constructDrv = stdenv.mkDerivation;

        # Nix-level arguments the derivation itself must not see.
        excludeDrvArgNames = [
          "dubLock"
          "compiler"
        ];

        extendDrvArgs =
          finalAttrs:
          {
            # A lockfile in `dub-to-nix` format — a path, or an attrset
            # already read with `lib.importJSON`.
            dubLock,
            compiler ? ldc,
            ...
          }@args:
          {
            # Named after the lockfile rather than the package: this only
            # fetches and registers the registry dependencies, so every
            # package sharing a lockfile can share the one derivation instead
            # of each fetching its own byte-identical copy.
            dubDeps = importDubLock {
              pname = "dub-registry";
              version = "deps";
              lock = dubLock;
            };

            strictDeps = args.strictDeps or true;

            nativeBuildInputs = (args.nativeBuildInputs or [ ]) ++ [
              dubNormalizeSourceHook
              dubHomeSetupHook
              installDubArtifactsHook
              compiler
              dub
              removeReferencesTo
            ];

            # Read by the hooks and by the default build phase.
            dubBuildType = args.dubBuildType or "release";
            dubCompiler = lib.getExe compiler;

            buildPhase =
              args.buildPhase or ''
                runHook preBuild

                dub build \
                  --skip-registry=all \
                  --compiler="$dubCompiler" \
                  --build="$dubBuildType"

                runHook postBuild
              '';

            doCheck = args.doCheck or false;

            meta = {
              platforms = dub.meta.platforms;
            }
            // args.meta or { };
          };
      };

      # Build a reusable artifact bundle: compile one or more *primer*
      # packages so that everything they depend on lands in `$DUB_HOME/cache`,
      # then install `$DUB_HOME` wholesale.
      #
      # `dubPrimers` is a list of `{ subdir, single }`, each compiled with
      # `dub build --single` from `<tree>/<subdir>`. The primers' own targets
      # are kept rather than stripped: a consumer's root package is rebuilt
      # regardless (dub never reuses a cached target for a `--single` root),
      # so stripping would save nothing and only risk dropping a shared one.
      buildDubDeps =
        args:
        mkDubDerivation (
          builtins.removeAttrs args [ "dubPrimers" ]
          // {
            buildPhase = ''
              runHook preBuild

              ${lib.concatMapStrings (primer: ''
                echo "Priming ${primer.subdir}/${primer.single}"
                (
                  cd "$dubTreeRoot/${primer.subdir}"
                  dub build \
                    --single ${lib.escapeShellArg primer.single} \
                    --skip-registry=all \
                    --compiler="$dubCompiler" \
                    --build="$dubBuildType"
                )
              '') args.dubPrimers}

              runHook postBuild
            '';

            installPhase = "installDubArtifactsHook";

            # The bundle holds intermediate object code and static libraries,
            # never a runtime closure — the compiler references in it are
            # expected, and the consumer's own fixups scrub what ends up in a
            # binary.
            dontFixup = true;
          }
        );
    in
    {
      legacyPackages.dubBuilder = {
        inherit mkDubDerivation buildDubDeps;
      };
    };
}
