# `.github/workflows/docs.yml` — build the site and deploy it to Cloudflare
# Pages: a preview per pull request (its URL commented on the PR), production
# from `main`. Not lazy: a deploy is a side effect per target, and the build
# itself is gated lazily in `ci.yml`.
{ lib, config, ... }:
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
      steps = t: [
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
          # Best-effort: the badges are a nicety, never a reason not to deploy.
          name = "Refresh the merge badges";
          continue-on-error = true;
          run = t.script "ci-merge-badges" {
            runtimeInputs = [ t.pkgs.gitMinimal ];
            text = ''
              ${lib.getExe t.ciMinimal} --ci-stats --merges \
                --repo "$GITHUB_REPOSITORY" --limit 1000 --badge-dir docs/public/badges
            '';
          };
          env.GITHUB_TOKEN = "\${{ github.token }}";
        }
        {
          name = "Build the VitePress site";
          run = import ./docs-build.nix t;
        }
        {
          name = "Deploy to Cloudflare Pages & comment the preview URL";
          run = t.ciScript "deploy-cloudflare-pages.sh" [
            t.pkgs.nodejs
            t.yarn
            t.pkgs.gh
            t.pkgs.gitMinimal
            t.pkgs.gnugrep
            t.pkgs.gnused
            t.pkgs.jq
          ];
          env = {
            CLOUDFLARE_API_TOKEN = "\${{ secrets.CLOUDFLARE_API_TOKEN }}";
            CLOUDFLARE_ACCOUNT_ID = "\${{ secrets.CLOUDFLARE_ACCOUNT_ID }}";
            GITHUB_TOKEN = "\${{ github.token }}";
          };
        }
      ];
    };
  };
}
