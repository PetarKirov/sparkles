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
        {
          ci,
          ciMinimal,
          features ? [ ],
        }:
        rec {
          inherit pkgs ci ciMinimal;
          inherit (config) packages checks;
          inherit (pkgs.stdenv.hostPlatform) system;

          # The same tools around a shell of these features: a job's shell
          # holds what its units need (`graph.needsOf`), not the whole tier.
          withFeatures =
            fs:
            mkTools {
              inherit ci ciMinimal;
              features = fs;
            };

          # The `ci` dev shell's environment, cut to `features` and captured
          # at build time.
          env = shellEnv.capture (
            config.legacyPackages.mkSparklesShell {
              tier = "ci";
              ciTool = ci;
              inherit features;
            }
          );
          # A step that runs inside the `ci` dev shell.
          inShell =
            name: text:
            shellEnv.script {
              inherit name text;
              inherit env;
            };
          # A step that runs prek over a cut of the repository's hook
          # config: `only` the named hooks, or all but `skip`. The config is
          # the git-hooks one, filtered here, so the step's closure holds the
          # hooks it runs and not the others (`verify-md-examples` alone
          # brings the whole toolchain). `$PRE_COMMIT_CONFIG` names the file.
          preCommit =
            name:
            {
              only ? null,
              skip ? [ ],
              text,
            }:
            let
              settings = config.pre-commit.settings;
              keep = id: (only == null || builtins.elem id only) && !builtins.elem id skip;
              raw = settings.rawConfig // {
                repos = map (r: r // { hooks = builtins.filter (h: keep h.id) r.hooks; }) settings.rawConfig.repos;
              };
              kept = lib.filterAttrs (id: h: h.enable && keep id) settings.hooks;
            in
            script name {
              # The hooks' own tools, as the pre-commit shell would put them
              # on PATH, plus git, which prek and `--from-ref` need.
              runtimeInputs = [
                settings.package
                pkgs.gitMinimal
              ]
              ++ lib.concatMap (h: lib.optional (h.package != null) h.package) (builtins.attrValues kept);
              text = ''
                export PRE_COMMIT_CONFIG=${pkgs.writeText "pre-commit-config.json" (builtins.toJSON raw)}
                ${text}
              '';
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

          inherit (config.legacyPackages) yarn;
          nix = pkgs.nix;
          nixFlags = "--extra-experimental-features 'nix-command flakes'";

          # ── the planner, recorder and verdict ──────────────────────

          # `plan <workflow>`: evaluate the workflow's stamps, ask the cache
          # which exist, and publish the stale units per job.
          plan = script "ci-plan" {
            runtimeInputs = [
              nix
              pkgs.jq
              pkgs.gitMinimal
            ];
            text = ''
              wf=$1
              echo "::group::Evaluating the stamps of $wf"
              nix ${nixFlags} eval --json ".#ci.plan.$wf" > raw.json
              echo "::endgroup::"

              # Only presence matters, and through a file: hundreds of narinfo
              # objects overflow an argument list. Batches of 100, each retried
              # once: a batch that still fails reads as "missing", so an
              # unreachable cache re-runs work, never skips it.
              echo '{}' > present.json
              if [ "''${CI_FORCE:-0}" = 1 ]; then
                echo "Forced: every unit runs."
              else
                jq -r '.jobs[].units[].path' raw.json | split -l 100 - batch.
                for batch in batch.*; do
                  for attempt in 1 2; do
                    # shellcheck disable=SC2046 # one store path per word
                    if nix ${nixFlags} path-info --json --store '${cachixUrl}' $(cat "$batch") \
                        > "$batch.json" 2> "$batch.err"; then
                      break
                    fi
                    echo "::warning::stamp lookup failed (attempt $attempt): $(tail -n 3 "$batch.err")"
                    echo '{}' > "$batch.json"
                    sleep 5
                  done
                done
                jq -s 'add // {} | with_entries(select(.value != null)) | map_values(true)' \
                  batch.*.json > present.json
                rm -f batch.*
                echo "$(jq length present.json) of $(jq '[.jobs[].units[]] | length' raw.json) stamps already pass."
              fi

              jq --slurpfile present present.json \
                '.jobs as $jobs | { $jobs, bundles, stale: ($jobs | map_values([.units[] | select($present[0][.path] | not) | .arg])) }' \
                raw.json > plan.json
              {
                echo "stale=$(jq -c .stale plan.json)"
                echo "bundles=$(jq -c .bundles plan.json)"
              } >> "''${GITHUB_OUTPUT:-/dev/null}"

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
          # it ran and push them, so the next run with these inputs skips them —
          # unless a `$GATE` job (the drift check) failed.
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
              gate=''${GATE:-'{}'}
              failed=$(jq -r '[to_entries[] | select(.value != "success" and .value != "skipped") | .key] | join(" ")' <<< "$gate")
              if [ -n "$failed" ]; then
                echo "::notice::The workflow's gate did not pass ($failed): nothing recorded."
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
