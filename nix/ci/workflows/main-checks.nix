# `.github/workflows/main-checks.yml` — what the default branch's tip reports.
#
# The repository merges by rebase, so every commit on `main` has a SHA no CI
# run has seen. When the landed *tree* equals the tree the pull request built,
# that pull request's checks are a report about this exact content, and
# `ci --mirror-checks` files them against the landed commit. When the trees
# differ, the merge produced content nothing has built, and this calls the
# real `CI` workflow — whose laziness then skips whatever an earlier run
# already proved on the same inputs. Measured over 333 merged pull requests
# (`ci --ci-stats --merges`): 75.7% mirrorable.
{ lib, ... }:
{
  ci.workflows.main-checks = {
    name = "Main branch checks";
    on = {
      push.branches = [ "main" ];
      # Rehearsal and repair: a `push` workflow cannot be exercised by the pull
      # request that changes it. `dry_run` defaults to true, so pressing the
      # button reports the decision and files nothing.
      workflow_dispatch.inputs = {
        sha = {
          description = "Commit to mirror onto (default: the branch tip)";
          required = false;
          type = "string";
        };
        dry_run = {
          description = "Report the decision without filing checks or rebuilding";
          required = false;
          type = "boolean";
          default = true;
        };
      };
    };
    permissions = {
      contents = "read";
      # Filing check runs needs an app token; a personal one cannot.
      checks = "write";
    };
    concurrency = {
      group = "main-checks-\${{ github.ref }}";
      # Each push describes a different commit.
      cancel-in-progress = false;
    };
    jobs = {
      mirror = {
        name = "Mirror the pull request's checks";
        timeout-minutes = 10;
        cachix.push = false;
        outputs.mirrored = "\${{ steps.mirror.outputs.mirrored }}";
        steps = t: [
          {
            # `--skip-check deploy`: `Deploy Docs` files its own on this push.
            name = "Mirror, if the landed tree is the tree that was built";
            id = "mirror";
            run = t.script "ci-mirror-checks" {
              runtimeInputs = [ t.pkgs.gitMinimal ];
              text = ''
                # shellcheck disable=SC2086 # DRY_RUN is one optional flag or empty
                ${lib.getExe t.ciMinimal} --mirror-checks \
                  --repo "$GITHUB_REPOSITORY" --sha "$SHA" --skip-check deploy $DRY_RUN
              '';
            };
            env = {
              GITHUB_TOKEN = "\${{ github.token }}";
              SHA = "\${{ inputs.sha || github.sha }}";
              DRY_RUN = "\${{ inputs.dry_run && '--dry-run' || '' }}";
            };
          }
        ];
      };

      # The real pipeline, called so its checks land on this very commit. A
      # dispatch would race the branch tip, and a workflow token cannot
      # reliably trigger one.
      rebuild = {
        name = "Build the commit for real";
        system = null;
        timeout-minutes = null;
        checkout.enable = false;
        needs = [ "mirror" ];
        "if" = "needs.mirror.outputs.mirrored != 'true' && !inputs.dry_run";
        extra = {
          uses = "./.github/workflows/ci.yml";
          secrets = "inherit";
        };
      };
    };
  };
}
