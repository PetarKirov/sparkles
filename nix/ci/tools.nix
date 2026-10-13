# What a CI step is made of, per system: `legacyPackages.ciTools.{real,key}`.
#
# A workflow's `steps` is a function of these tools. `real` is what runs;
# `key` is the same set around a stub `ci` harness, evaluated (never built) to
# compute laziness keys — the harness's own sources join a key as a unit
# instead, so a change to one of the libraries the helper links re-runs only
# the work that covers that library.
{ lib, config, ... }:
let
  inherit (config.ci.settings) cachix;
in
{
  perSystem =
    { config, pkgs, ... }:
    let
      shellEnv = import ./lib/shell-env.nix { inherit lib pkgs; };
      cachixUrl = "https://${cachix.name}.cachix.org";

      stub =
        name:
        pkgs.writeShellScriptBin name ''
          echo "${name}: the CI-key stub, not the real helper" >&2
          exit 1
        '';

      mkTools =
        { ci, ciMinimal }:
        rec {
          inherit pkgs ci ciMinimal;
          inherit (config) packages checks;
          inherit (pkgs.stdenv.hostPlatform) system;

          # The `ci` dev shell's environment, captured at build time.
          env = shellEnv.capture (
            config.legacyPackages.mkSparklesShell {
              tier = "ci";
              ciTool = ci;
            }
          );
          # The pre-commit hooks' shell (prek and every hook's tool); its hook
          # links `.pre-commit-config.yaml`, which prek reads.
          preCommitEnv = shellEnv.capture config.devShells.pre-commit;

          # A step that runs inside the `ci` dev shell.
          inShell =
            name: text:
            shellEnv.script {
              inherit name text;
              inherit env;
            };
          # The same, with extra tools ahead of the shell's own.
          inShellWith =
            path: name: text:
            shellEnv.script {
              inherit
                name
                text
                env
                path
                ;
            };
          # A step that runs inside the pre-commit shell (plus git, which the
          # hooks and `--from-ref` need and the shell does not carry).
          inPreCommit =
            name: text:
            shellEnv.script {
              inherit name text;
              env = preCommitEnv;
              path = [ pkgs.gitMinimal ];
            };
          # A step whose PATH is its declared inputs and nothing else.
          script =
            name:
            {
              runtimeInputs ? [ ],
              text,
            }:
            pkgs.writeShellApplication {
              inherit name text;
              runtimeInputs = runtimeInputs ++ [ pkgs.coreutils ];
              inheritPath = false;
            };
          # The repository's `ci/*.sh` scripts in the store — only the
          # scripts, so editing `ci/README.md` changes no step. They find
          # `lib/common.sh` beside themselves.
          ciScripts = lib.fileset.toSource {
            root = ../../ci;
            fileset = lib.fileset.fileFilter (f: f.hasExt "sh") ../../ci;
          };
          ciScript =
            name: runtimeInputs:
            script "ci-${lib.removeSuffix ".sh" name}" {
              inherit runtimeInputs;
              text = ''exec ${pkgs.bash}/bin/bash ${ciScripts}/${name} "$@"'';
            };

          nix = pkgs.nix;
          nixFlags = "--extra-experimental-features 'nix-command flakes'";

          # ── the planner, recorder and verdict ──────────────────────

          # `plan <workflow>`: evaluate the workflow's stamps, ask the cache
          # which exist, and publish the stale units per job.
          plan = script "ci-plan" {
            runtimeInputs = [
              nix
              pkgs.jq
              pkgs.findutils
              pkgs.gitMinimal
            ];
            text = ''
              wf=$1
              echo "::group::Evaluating the stamps of $wf"
              nix ${nixFlags} eval --json ".#ci.plan.$wf" > raw.json
              echo "::endgroup::"

              # Only presence matters, and through a file: hundreds of narinfo
              # objects overflow an argument list.
              echo '{}' > present.json
              if [ "''${CI_FORCE:-0}" = 1 ]; then
                echo "Forced: every unit runs."
              else
                # One narinfo lookup per stamp; a lookup that fails reads as
                # "missing", so an unreachable cache re-runs work, never skips it.
                jq -r '.[].units[].path' raw.json \
                  | xargs -r nix ${nixFlags} path-info --json --store '${cachixUrl}' 2> /dev/null \
                  | jq -s 'add // {} | with_entries(select(.value != null)) | map_values(true)' \
                    > present.next.json \
                  && mv present.next.json present.json \
                  || echo "::warning::Could not ask the cache for stamps; everything runs."
              fi

              jq --slurpfile present present.json \
                '{ jobs: ., stale: map_values([.units[] | select($present[0][.path] | not) | .arg]) }' \
                raw.json > plan.json
              echo "stale=$(jq -c .stale plan.json)" >> "''${GITHUB_OUTPUT:-/dev/null}"

              {
                echo "### Work this run covers"
                echo
                echo "| job | to run | of |"
                echo "| --- | ---: | ---: |"
                jq -r '.jobs as $j | .stale | to_entries[]
                  | "| `\(.key)` | \(.value | length) | \($j[.key].units | length) |"' plan.json
              } | tee -a "''${GITHUB_STEP_SUMMARY:-/dev/null}"
            '';
          };

          # `record`: for every job that succeeded, add the stamps of the units
          # it ran and push them, so the next run with these inputs skips them.
          record = script "ci-record" {
            runtimeInputs = [
              nix
              pkgs.jq
              pkgs.cachix
            ];
            text = ''
              if [ -z "''${CACHIX_AUTH_TOKEN:-}" ]; then
                echo "::notice::No cache token (a fork's pull request?): nothing recorded."
                exit 0
              fi
              if [ ! -f plan.json ]; then
                echo "::warning::No plan artifact: nothing recorded."
                exit 0
              fi

              tmp=$(mktemp -d)
              jq -c --argjson results "$RESULTS" '
                .stale as $stale
                | .jobs | to_entries[]
                | select($results[.key] == "success")
                | .key as $job
                | .value.units[]
                | select(.arg as $a | any(($stale[$job] // [])[]; . == $a))
              ' plan.json > "$tmp/passed.jsonl"

              paths=()
              i=0
              while IFS= read -r unit; do
                i=$((i + 1))
                name=$(jq -r .name <<< "$unit")
                want=$(jq -r .path <<< "$unit")
                mkdir "$tmp/$i"
                jq -j .content <<< "$unit" > "$tmp/$i/$name"
                got=$(nix ${nixFlags} store add --mode flat --hash-algo sha256 --name "$name" "$tmp/$i/$name")
                if [ "$got" != "$want" ]; then
                  echo "::warning::stamp $name: added $got, the plan expected $want"
                  continue
                fi
                paths+=("$got")
              done < "$tmp/passed.jsonl"

              if [ "''${#paths[@]}" -eq 0 ]; then
                echo "Nothing new passed."
                exit 0
              fi
              cachix push "$CACHIX_CACHE" "''${paths[@]}"
              echo "Recorded ''${#paths[@]} stamp(s)."
            '';
          };

          # `verdict`: the single required check. Skipped is fine — that is
          # what laziness looks like; failed and cancelled are not.
          verdict = script "ci-verdict" {
            runtimeInputs = [ pkgs.jq ];
            text = ''
              jq -r 'to_entries[] | "\(.key): \(.value)"' <<< "$RESULTS"
              bad=$(jq -r '[to_entries[] | select(.value != "success" and .value != "skipped") | .key] | join(" ")' <<< "$RESULTS")
              if [ -n "$bad" ]; then
                echo "::error::did not succeed: $bad"
                exit 1
              fi
            '';
          };
        };
    in
    {
      legacyPackages.ciTools = {
        real = mkTools {
          ci = config.packages.ci;
          ciMinimal = config.packages.ci-minimal;
        };
        key = mkTools {
          ci = stub "ci";
          ciMinimal = stub "ci-minimal";
        };
      };
    };
}
