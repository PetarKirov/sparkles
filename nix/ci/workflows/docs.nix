# `.github/workflows/docs.yml` — build the site and deploy it to Cloudflare
# Pages: a preview per pull request (its URL commented on the PR), production
# from `main`. Not lazy: a deploy is a side effect per target, and the build
# itself is gated lazily in `ci.yml`.
{ config, ... }:
let
  paths = [
    "docs/**"
    "libs/twoslash/**"
    "package.json"
    "yarn.lock"
    ".yarnrc.yml"
  ];
in
{
  ci.workflows.docs = {
    name = "Deploy Docs";
    on = {
      push = {
        branches = [ "main" ];
        inherit paths;
      };
      pull_request = { inherit paths; };
      workflow_dispatch = { };
    };
    concurrency = {
      group = "docs-\${{ github.ref }}";
      cancel-in-progress = true;
    };
    jobs.deploy = {
      name = "deploy";
      timeout-minutes = 40;
      env.COREPACK_ENABLE_DOWNLOAD_PROMPT = "0";
      permissions = {
        contents = "read";
        deployments = "write";
        pull-requests = "write";
      };
      steps = _: [
        {
          name = "Cache Yarn";
          uses = config.ci.settings.actions.cache;
          "with" = {
            path = "~/.yarn/berry/cache";
            key = "yarn-\${{ runner.os }}-\${{ hashFiles('yarn.lock') }}";
            restore-keys = "yarn-\${{ runner.os }}-";
          };
        }
        {
          task = "merge-badges";
          continue-on-error = true;
        }
        # Builds the site first (its `after`).
        { task = "docs-deploy"; }
      ];
    };
  };
}
