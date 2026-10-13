# `.github/workflows/link-check.yml` — the nightly networked link sweep.
#
# Not a gate: a dead third-party URL is somebody else's expired domain, and
# making it a dependency of `CI` turned this repository red for it. It
# reconciles one standing issue instead (`ci --report-link-rot`). Pull
# requests check the links in their own diff (`ci.yml`, job `lint`).
{ lib, config, ... }:
let
  cacheWith = {
    path = ".lycheecache";
    enableCrossOsArchive = true;
    key = "cache-lychee-v4-\${{ github.run_id }}";
  };
in
{
  ci.workflows.link-check = {
    name = "Link check";
    on = {
      schedule = [ { cron = "17 4 * * *"; } ];
      workflow_dispatch = { };
    };
    permissions = {
      contents = "read";
      issues = "write";
    };
    concurrency = {
      group = "link-check";
      cancel-in-progress = false;
    };
    jobs.sweep = {
      name = "Check every link";
      timeout-minutes = 35;
      steps = t: [
        {
          name = "Restore the lychee cache";
          uses = config.ci.settings.actions.cache-restore;
          "with" = cacheWith // {
            restore-keys = "cache-lychee-v4-";
          };
        }
        {
          name = "Check every link";
          id = "sweep";
          continue-on-error = true;
          run = t.preCommit "ci-link-sweep" {
            only = [ "lychee" ];
            text = ''
              prek run --config "$PRE_COMMIT_CONFIG" lychee --all-files --show-diff-on-failure --color never \
                | tee lychee-report.txt
            '';
          };
          env.GITHUB_TOKEN = "\${{ github.token }}";
        }
        {
          name = "Save the lychee cache";
          "if" = "always()";
          uses = config.ci.settings.actions.cache-save;
          "with" = cacheWith;
        }
        {
          name = "Reconcile the standing link-rot issue";
          "if" = "always() && steps.sweep.conclusion != 'skipped'";
          run = t.script "ci-report-link-rot" {
            runtimeInputs = [ t.pkgs.gitMinimal ];
            text = ''
              # shellcheck disable=SC2086 # ROTTEN is one optional flag or empty
              ${lib.getExe t.ciMinimal} --report-link-rot \
                --repo "$GITHUB_REPOSITORY" \
                --report lychee-report.txt \
                --run-url "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" \
                $ROTTEN
            '';
          };
          env = {
            GITHUB_TOKEN = "\${{ github.token }}";
            ROTTEN = "\${{ steps.sweep.outcome == 'failure' && '--rotten' || '' }}";
          };
        }
      ];
    };
  };
}
