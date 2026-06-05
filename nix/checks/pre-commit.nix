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

          excludes = [
            "^.*\.age$"
            # age testkit conformance vectors are byte-exact fixtures (some
            # intentionally contain trailing whitespace, CR bytes, or specific
            # line endings); keep every hook away from them so prek never
            # rewrites them.
            "^libs/age/tests/testkit/"
          ];

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
              require_serial = false;
              pass_filenames = true;
              entry = lib.getExe config.packages.ci;
              args = [
                "--verify"
                "--fail-fast"
                "--files"
              ];
            };

            lychee = {
              enable = true;
              files = "\\.md$";
              pass_filenames = true;
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

                    # Remap only PetarKirov/sparkles links to the Contents API (where we have valid authentication token)
                    extra_args+=(
                      --remap 'https://github\.com/PetarKirov/sparkles/blob/([^/]+)/(.*) https://api.github.com/repos/PetarKirov/sparkles/contents/$2?ref=$1'
                      --remap 'https://github\.com/PetarKirov/sparkles/tree/([^/]+)/(.*) https://api.github.com/repos/PetarKirov/sparkles/contents/$2?ref=$1'
                      # Remap other public repositories' files to raw.githubusercontent.com to avoid API rate limits and 401 auth issues
                      --remap 'https://github\.com/([^/]+)/([^/]+)/blob/([^/]+)/(.*) https://raw.githubusercontent.com/$1/$2/$3/$4'
                    )

                    exec ${lib.getExe pkgs.lychee} \
                      --config "$lychee_config_file" \
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
                { id = "check-added-large-files"; }
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
                {
                  id = "detect-private-key";
                  # The SSH recipient/identity parsers contain the OpenSSH PEM
                  # private-key begin marker, and their DDoc and unit-test
                  # fixtures embed throwaway example keys (as the upstream age
                  # testdata does). These are not secrets; exempt the files that
                  # legitimately reference the marker.
                  exclude = filesToExcludeRegex [
                    "docs/specs/age/SPEC.md"
                    "apps/age/src/sparkles/age_cli/keygen_flow.d"
                    "libs/age/src/sparkles/age/identity_file.d"
                    "libs/age/src/sparkles/age/recipients/ssh_ed25519.d"
                    "libs/age/src/sparkles/age/recipients/ssh_keys.d"
                  ];
                }
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
