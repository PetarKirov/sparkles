{ lib, ... }:
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

          excludes = [ "^.*\.age$" ];

          hooks = {
            # Basic whitespace formatting
            end-of-file-fixer = {
              enable = true;
              # Test data files contain exact byte sequences — no trailing newline
              excludes = [ "^libs/core-cli/test/data/" ];
            };
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
            };

            fix-markdown-reference-links = {
              enable = true;
              files = "\\.md$";
              language = "system";
              name = "fix-markdown-reference-links";
              require_serial = true;
              entry = lib.getExe config.packages.run_md_examples;
              args = [ "--fix-reference-links" ];
            };

            verify-md-examples = {
              enable = true;
              files = "\\.md$";
              language = "system";
              name = "verify-md-examples";
              require_serial = true;
              entry = lib.getExe config.packages.run_md_examples;
              args = [ "--verify" ];
            };

            lychee = {
              enable = true;
              files = "\\.md$";
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

                    exec ${lib.getExe pkgs.lychee} \
                      --config "$lychee_config_file" \
                      --no-progress \
                      --cache \
                      --header "Authorization: Bearer $GITHUB_TOKEN" \
                      "''${extra_args[@]}" \
                      "$@"
                  ''
                )
              );
            };
          };
        };
      };
    };
}
