{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    {
      pre-commit.settings.hooks.rustfmt.enable = lib.mkForce false;

      # Test data files contain exact byte sequences — no trailing newline
      pre-commit.settings.hooks.end-of-file-fixer.excludes = [ "^libs/core-cli/test/data/" ];

      pre-commit.settings.hooks.lychee = {
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
}
