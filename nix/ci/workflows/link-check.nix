# `.github/workflows/link-check.yml` — the nightly networked link sweep.
#
# Not a gate: a dead third-party URL is somebody else's expired domain, and
# making it a dependency of `CI` turned this repository red for it. It
# reconciles one standing issue instead (`ci --report-link-rot`). Pull
# requests check the links in their own diff (`ci.yml`, job `lint`).
{ config, ... }:
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
      steps = _: [
        {
          name = "Restore the lychee cache";
          uses = config.ci.settings.actions.cache-restore;
          "with" = cacheWith // {
            restore-keys = "cache-lychee-v4-";
          };
        }
        {
          task = "link-sweep";
          id = "sweep";
          continue-on-error = true;
        }
        {
          name = "Save the lychee cache";
          "if" = "always()";
          uses = config.ci.settings.actions.cache-save;
          "with" = cacheWith;
        }
        {
          task = "report-link-rot";
          "if" = "always() && steps.sweep.conclusion != 'skipped'";
          env.ROTTEN = "\${{ steps.sweep.outcome == 'failure' && '--rotten' || '' }}";
        }
      ];
    };
  };
}
