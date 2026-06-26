{ lib, ... }:
let
  generatedJsonFiles = [
    # Nix Flake lock file
    "flake.lock"

    # Dub lock file
    "dub.selections.json"

    # NPM / Yarn lock files
    "package-lock.json"
    "yarn.lock"
  ];

  yarnPnPFiles = [
    ".pnp.cjs"
    ".pnp.loader.mjs"
    ".pnp.data.json"
  ];

  filesToExcludeRegex =
    files: lib.concatMapStringsSep "|" (entry: "(${lib.escapeRegex entry})") files;
in
{
  perSystem =
    { config, pkgs, ... }:
    {
      devShells.pre-commit =
        let
          inherit (config.pre-commit.settings) enabledPackages package configFile;
        in
        pkgs.mkShell {
          packages = enabledPackages ++ [ package ];
          shellHook = ''
            ln -fvs ${configFile} .pre-commit-config.yaml
            echo "Running Pre-commit checks"
            echo "========================="
          '';
        };

      # `nix fmt` runs prek, but only the hooks that *rewrite* files — formatting
      # is the job, not linting. Checkers (editorconfig-checker, lychee,
      # verify-md-examples, the `check-*`/`detect-*` family) and generators
      # (gen-text-svg) are deliberately excluded; they run on commit, not on
      # `nix fmt`. Defining a concrete formatter also resolves flake-parts'
      # heuristic, which otherwise can't prove `formatter` is null for the custom
      # `systems` input and emits a broken `formatter.<system>` output.
      #
      # Note: like `prek`/`pre-commit` itself, this exits non-zero when a hook
      # reformats a file; re-run until clean. Pass paths to format a subset.
      formatter =
        let
          inherit (config.pre-commit.settings) package configFile;
          formattingHooks = [
            "nixfmt"
            "prettier"
            "fix-markdown-reference-links"
            "trailing-whitespace"
            "end-of-file-fixer"
            "file-contents-sorter"
            "fix-byte-order-marker"
            "pretty-format-json"
            "mixed-line-ending"
          ];
        in
        pkgs.writeShellApplication {
          name = "sparkles-fmt";
          runtimeInputs = [
            package
            pkgs.git
          ];
          text = ''
            hooks=(${lib.concatStringsSep " " formattingHooks})
            if [ "$#" -eq 0 ]; then
              exec prek run --config ${configFile} --all-files "''${hooks[@]}"
            else
              exec prek run --config ${configFile} "''${hooks[@]}" --files "$@"
            fi
          '';
        };

      # impl: https://github.com/cachix/git-hooks.nix/blob/master/flake-module.nix
      pre-commit = {
        # Disable `checks` flake output
        check.enable = false;

        # Enable commonly used formatters
        settings = {
          # Use Rust-based alternative to pre-commit:
          # * https://github.com/j178/prek
          # * https://prek.j178.dev/
          package = pkgs.prek;

          excludes = [ "^.*\.age$" ];

          hooks = {
            editorconfig-checker.enable = true;

            # *.nix formatting
            nixfmt.enable = true;

            # *.{js,jsx,ts,tsx,css,html,md,json} formatting
            prettier = {
              enable = true;
              args = [
                "--check"
                "--list-different=false"
                "--log-level=warn"
                "--ignore-unknown"
                "--write"
              ];
              excludes = builtins.map lib.escapeRegex (generatedJsonFiles ++ yarnPnPFiles);
            };

            fix-markdown-reference-links = {
              enable = true;
              files = "\\.md$";
              language = "system";
              name = "fix-markdown-reference-links";
              require_serial = false;
              pass_filenames = true;
              entry = lib.getExe config.packages.ci;
              args = [
                "--fix-reference-links"
                "--files"
              ];
            };

            verify-md-examples = {
              enable = true;
              files = "\\.md$";
              language = "system";
              name = "verify-md-examples";
              # Hand every matched *.md to ONE `ci` invocation instead of letting
              # prek fan out file batches across parallel processes. `ci` then
              # parallelizes the per-example builds itself, capped by available
              # cores/memory (see SPARKLES_CI_JOBS) — example builds are OOM-prone,
              # and one coordinator bounds total concurrency where N independent
              # prek processes (~32 here) cannot. The build-artifact race itself is
              # fixed in `ci` via dub `--temp-build`; serializing here is about
              # bounded, predictable parallelism rather than correctness.
              require_serial = true;
              pass_filenames = true;
              entry = lib.getExe config.packages.ci;
              args = [
                "--verify"
                "--fail-fast"
                "--files"
              ];
            };

            # Regenerate the cell-grid SVG for docs/specs/base/text/ whenever the
            # text algorithm or its generator changes. The generator is the
            # prebuilt standalone example (rebuilt by Nix when the sources change),
            # so the committed SVG can never drift from `byGraphemeCluster`; prek
            # reports a failure if the file was rewritten, mirroring prettier.
            gen-text-svg = {
              enable = true;
              files = "(^libs/base/src/sparkles/base/text/.*\\.d$)|(^libs/base/examples/text-cell-svg\\.d$)";
              language = "system";
              name = "gen-text-svg";
              pass_filenames = false;
              entry = toString (
                pkgs.writeShellScript "gen-text-svg" ''
                  set -euo pipefail
                  repo_root=$(git rev-parse --show-toplevel)
                  ${lib.getExe config.legacyPackages.examples.base."text-cell-svg"} \
                    --out "$repo_root/docs/public/text-cells.svg"
                ''
              );
            };

            lychee = {
              enable = true;
              files = "\\.md$";
              pass_filenames = true;
              # Run a single lychee process over all matched files. Without this,
              # prek splits `--all-files` into many parallel lychee invocations
              # (~32 on this repo); the aggregate connection rate exhausts local
              # sockets (ResourceBusy / connect failures) and each process keeps
              # its own per-host throttle governor, defeating the web.archive.org
              # request_interval and re-tripping its connection-refusal limit.
              require_serial = true;
              entry = lib.mkForce (
                toString (
                  pkgs.writeShellScript "lychee-with-auth" ''
                    extra_args=()
                    repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)

                    if [ -z "$repo_root" ] && [ "$#" -gt 0 ]; then
                      first_arg_dir=$(dirname "$1")
                      repo_root=$(git -C "$first_arg_dir" rev-parse --show-toplevel 2>/dev/null || true)
                    fi

                    if [ -z "$repo_root" ]; then
                      echo "Failed to determine repository root for lychee config" >&2
                      exit 1
                    fi

                    lychee_config_file="$repo_root/lychee.toml"
                    shared_exclude_file="$repo_root/lychee.exclude"
                    ci_exclude_file="$repo_root/lychee.ci.exclude"

                    for exclude_file in "$shared_exclude_file" "$ci_exclude_file"; do
                      if [ "$exclude_file" = "$ci_exclude_file" ] && [ -z "$CI" ]; then
                        continue
                      fi

                      if [ ! -f "$exclude_file" ]; then
                        continue
                      fi

                      while IFS= read -r pattern || [ -n "$pattern" ]; do
                        case "$pattern" in
                          ""|\#*)
                            continue
                            ;;
                        esac

                        extra_args+=(--exclude "$pattern")
                      done < "$exclude_file"
                    done
                    if [ -n "$GITHUB_TOKEN" ]; then
                      extra_args+=(--header "Authorization: Bearer $GITHUB_TOKEN")
                    fi

                    exec ${lib.getExe pkgs.lychee} \
                      --config "$lychee_config_file" \
                      --root-dir "$repo_root" \
                      --no-progress \
                      --cache \
                      "''${extra_args[@]}" \
                      "$@"
                  ''
                )
              );
            };
          };

          # Prek built-in hooks:
          # https://prek.j178.dev/builtin/#supported-hooks_1
          rawConfig.repos = [
            {
              repo = "builtin";
              hooks = [
                { id = "trailing-whitespace"; }
                {
                  id = "check-added-large-files";
                  # The cell-explorer wasm (real sparkles.base.text + Phobos, built
                  # by `nix build .#text-wasm`) is ~2.5 MB; it is an intentional,
                  # reproducible docs asset. Regenerate with that command.
                  exclude = "^docs/public/spk-text\\.wasm$";
                }
                { id = "check-case-conflict"; }
                { id = "check-illegal-windows-names"; }
                {
                  id = "end-of-file-fixer";
                  # Test data files contain exact byte sequences — no trailing newline
                  exclude = "^libs/core-cli/test/data/";
                }
                { id = "file-contents-sorter"; }
                { id = "fix-byte-order-marker"; }
                { id = "check-json"; }
                { id = "check-json5"; }
                {
                  id = "pretty-format-json";
                  exclude = filesToExcludeRegex ([ "package.json" ] ++ generatedJsonFiles);
                }
                { id = "check-toml"; }
                { id = "check-vcs-permalinks"; }
                { id = "check-yaml"; }
                { id = "check-xml"; }
                {
                  id = "mixed-line-ending";
                  args = [ "--fix=lf" ];
                }
                { id = "check-symlinks"; }
                { id = "destroyed-symlinks"; }
                { id = "check-merge-conflict"; }
                { id = "detect-private-key"; }
                { id = "no-commit-to-branch"; }
                { id = "check-shebang-scripts-are-executable"; }
                { id = "check-executables-have-shebangs"; }
              ];
            }
          ];
        };
      };
    };
}
