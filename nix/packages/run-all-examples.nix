# `run-all-examples`: smoke-runs every standalone example the way
# `ci --example-files` does.
{ lib, ... }:
{
  perSystem =
    { config, pkgs, ... }:
    let
      inherit (config.legacyPackages.exampleCatalog)
        allExampleFiles
        exampleInfo
        exampleSpec
        buildableHere
        ;
      examplesByLib = config.legacyPackages.examples;

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
      # Smoke-run every standalone example the way `ci --example-files` does:
      # `// ci: build-only` examples are built (they are retained in the
      # script's closure) but not executed; the rest run sequentially and any
      # non-zero exit is collected into the final status.
      packages.run-all-examples = pkgs.writeShellApplication {
        name = "run-all-examples";
        text = ''
          # Match the development shell's font fixture on every platform.
          export SPARKLES_FONTS_PATH=${config.packages.sparkles-fonts}/fonts
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
