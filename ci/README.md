# `ci/` — provider-neutral CI scripts

Everything both CI providers do that is more than "run this one command" lives
here. `.github/workflows/` and `.circleci/config.yml` are the two thin YAML
front-ends; a behaviour change belongs in this directory so it lands on both.

> [!NOTE]
> Do not confuse this with `apps/ci`, the repository's D helper (`ci --test`,
> `ci --verify`, …). That tool is the _workload_ CI runs. These scripts are the
> _plumbing_ that gets a runner to the point where it can run it.

## Why shell, and not D

[AGENTS.md](../AGENTS.md) says substantial repo tooling belongs in D, in
`apps/ci`. These scripts are the deliberate exception, for one structural
reason: **they are what makes the D toolchain exist.** `nix-install.sh` and
`nix-configure.sh` run before `nix`, `dub`, or `ldc2` are on `PATH`, so they
cannot be a program that a devShell provides. The remainder
(`with-cachix.sh`, `release-pin.sh`, `paths-changed.sh`, …) stay shell to keep
the whole layer in one language and one dependency footprint — none of them is
more than a guarded sequence of calls to `nix`, `cachix`, `git`, or `gh`.

If any of these grows real decision logic, promote it to an `apps/ci`
subcommand and have the script shell out to `nix run .#ci`.

## Environment contract

Provider-neutral names. GitHub Actions maps its `inputs`/`vars`/`secrets` onto
these in `.github/actions/setup-nix/action.yml` and at the step level; CircleCI
supplies them from the `sparkles-ci` context.

| Variable                  | Used by                                       | Purpose                                            |
| ------------------------- | --------------------------------------------- | -------------------------------------------------- |
| `CACHIX_CACHE`            | `nix-configure`, `with-cachix`, `release-pin` | Binary cache name                                  |
| `CACHIX_AUTH_TOKEN`       | same                                          | Read (netrc) and write (push/pin) token            |
| `NIX_SUBSTITUTERS`        | `nix-configure`                               | Extra substituters, space-separated                |
| `NIX_TRUSTED_PUBLIC_KEYS` | `nix-configure`                               | Extra trusted public keys, space-separated         |
| `NIX_GITHUB_TOKEN`        | `nix-configure`                               | `access-tokens` entry for github.com               |
| `NIX_GITLAB_TOKEN`        | `nix-configure`                               | `access-tokens` entry for `NIX_GITLAB_DOMAIN`      |
| `NIX_ACCEPT_FLAKE_CONFIG` | `nix-configure`                               | Trust flake.nix's `nixConfig` caches (see below)   |
| `CI_DEVSHELL`             | `nix-devshell`                                | devShell to activate (`default`, `pre-commit`)     |
| `CI_NIX_SINGLE_USER`      | `nix-install`                                 | Single-user store, required to cache `/nix`        |
| `GITHUB_TOKEN`            | `lint`, `pr-comment`                          | lychee's GitHub API budget; PR preview comment     |
| `CLOUDFLARE_API_TOKEN`    | `deploy-cloudflare-pages`                     | Pages deploy                                       |
| `CLOUDFLARE_ACCOUNT_ID`   | `deploy-cloudflare-pages`                     | Pages deploy                                       |
| `DUB_REGISTRY_SECRET`     | `notify-dub-registry`                         | Optional; only if the package has an update secret |
| `DC`                      | job step                                      | D compiler for the test suite (`ldc2` / `dmd`)     |

Anything unset degrades rather than failing: no Cachix token means builds run
without a push, no `GITHUB_TOKEN` means no PR comment. That is what lets a fork
PR — which gets no secrets — still run the pipeline.

## Scripts

| Script                       | What it does                                                                             |
| ---------------------------- | ---------------------------------------------------------------------------------------- |
| `lib/common.sh`              | Provider detection, log grouping, and `ci_export` (bridges `$GITHUB_ENV` vs `$BASH_ENV`) |
| `nix-install.sh`             | Installs Nix if absent; re-exports `PATH` when a cached `/nix` was restored              |
| `nix-configure.sh`           | Writes `nix.conf` + `netrc`; adds the job user to `trusted-users` on daemon installs     |
| `nix-devshell.sh`            | Builds a devShell (fail-fast), then exports it to later steps via direnv                 |
| `nix-tool-path.sh`           | Puts nixpkgs attrs on `PATH` — Node for the docs build, pinned by this flake             |
| `with-cachix.sh`             | Runs a command under `cachix watch-exec`, pushing paths as they are built                |
| `release-pin.sh`             | Highest-tag guard, then `cachix push` + `cachix pin --keep-revisions`                    |
| `notify-dub-registry.sh`     | Pokes code.dlang.org to ingest a new tag                                                 |
| `deploy-cloudflare-pages.sh` | `wrangler pages deploy`, then upserts the preview-URL comment                            |
| `pr-comment.sh`              | Marker-keyed comment upsert, so re-runs edit instead of appending                        |
| `paths-changed.sh`           | CircleCI's stand-in for `on: push: paths:` — pair with `circleci-agent step halt`        |
| `install-ldc-windows.sh`     | LDC + bundled dub on a Windows runner (CircleCI has no D orb)                            |

Lint them with `shellcheck -x -s bash ci/*.sh ci/lib/common.sh`.

## Job mapping

| GitHub Actions job                  | CircleCI job                         | Notes                                                      |
| ----------------------------------- | ------------------------------------ | ---------------------------------------------------------- |
| `test` (ubuntu × ldc2/dmd)          | `test-linux-ldc2`, `test-linux-dmd`  | Matrix over the `dc` parameter                             |
| `test` (macos × ldc2)               | `test-macos`                         | Separate job — different executor                          |
| `extracted-tests`                   | `extracted-tests`                    |                                                            |
| `win32-example`                     | `win32-example`                      | `setup-dlang` → `install-ldc-windows.sh`                   |
| `nix-build` (ubuntu, macos)         | `nix-build-linux`, `nix-build-macos` |                                                            |
| `nix-build-android`                 | `nix-build-android`                  |                                                            |
| `lint`                              | `lint`                               |                                                            |
| `docs` (build)                      | `docs`                               |                                                            |
| `docs.yml` `deploy`                 | `docs-deploy`                        | Path filter moves into the job (`paths-changed.sh`)        |
| `release.yml` `notify-dub-registry` | `notify-dub-registry`                |                                                            |
| `release.yml` `nix-build-pin`       | `nix-build-pin-linux/-macos`         |                                                            |
| `ci` (fan-in)                       | `ci`                                 | CircleCI will not start it unless every `requires:` passed |

## Setting up the CircleCI project

1. Create a **context** named `sparkles-ci` and add every variable from the
   table above that applies (the two Cachix values, `NIX_SUBSTITUTERS`,
   `NIX_TRUSTED_PUBLIC_KEYS`, `GITHUB_TOKEN`, the two Cloudflare values, and
   optionally `DUB_REGISTRY_SECRET`).
   - `GITHUB_TOKEN` must be a real PAT with `public_repo`. CircleCI has no
     equivalent of the automatic `github.token`.
2. Turn on **Auto-cancel redundant workflows** in project settings. That is the
   replacement for `concurrency.cancel-in-progress`; there is no config-file
   equivalent.
3. macOS jobs need a **Performance plan** — the Free plan has no macOS access
   at all, and a concurrency limit of 1.
4. Nothing needs "dynamic config" / setup workflows. The docs path filter is
   handled inside the job.

## Substituters: two ways to configure them

`flake.nix` declares this project's caches in its `nixConfig` block, but Nix
ignores a flake's own config by default — it warns
`ignoring untrusted flake configuration setting 'extra-substituters'` and then
builds from source, which for this repo means the whole D toolchain.

There are two ways to avoid that, and the two providers use different ones:

- **CircleCI** sets `NIX_ACCEPT_FLAKE_CONFIG: true`, so `flake.nix` is the
  single source of truth. This is only safe because CircleCI does not build
  forked PRs unless the project opts in; a branch that can set
  `extra-trusted-public-keys` can make Nix accept paths from a cache it chose.
  **Do not enable "Build forked pull requests" while this is on.**
- **GitHub Actions** leaves it off and passes the caches explicitly through
  `NIX_SUBSTITUTERS` / `NIX_TRUSTED_PUBLIC_KEYS`, because it _does_ build fork
  PRs. The cost is that those repo variables must list every cache
  `flake.nix` names, and drift between the two is silent.

## Cold start

The first pipeline on a new project has an empty `/nix` cache and pays for the
whole closure. That is much worse on Linux than on macOS, because
`devShells.default` adds Linux-only tools that dominate the download:

| Linux-only devShell entry | Closure   |
| ------------------------- | --------- |
| `chromium`                | 1.7 GiB   |
| `perf`                    | 288.1 MiB |
| `valgrind`                | 148.9 MiB |

macOS gets none of these, which is why a cold `test-macos` finishes in ~5.5 min
while a cold Linux leg is still fetching well past 15. Let the first run finish
— it is what populates both the CircleCI `/nix` cache and Cachix. Subsequent
runs restore instead of fetching.

The `nix-build-*` jobs additionally pay ~380 MiB for the `cachix` binary's own
closure (it pulls `aws-sdk-cpp` and `boost`), since they run without a devShell
and `with-cachix.sh` has to fetch it via `nix run`.

## Behaviour that could not be ported

- **No `merge_group` trigger.** CircleCI does not integrate with GitHub merge
  queues. If the queue is in use, GitHub Actions has to stay the gate.
- **No "release published" event.** `release.yml` deliberately fires on the
  published Release rather than the tag push, leaving a window in which a
  mistaken tag can be deleted before the registry is nudged. The CircleCI
  `release` workflow fires on the `v*` tag push, so that window is gone.
- **No per-job wall-clock timeout.** The GitHub `timeout-minutes` caps exist
  because the hosted Apple-Silicon runner occasionally hangs (a 5m job has
  stalled for 78m). CircleCI's `no_output_timeout` only catches a step that
  goes _silent_, which is not the same failure. The project-wide max-runtime
  setting is the closest equivalent.
- **`paths:` filters** become an in-job `paths-changed.sh` check plus
  `circleci-agent step halt`. The job still spins up before deciding.

## Cost

Measured with `ci --ci-stats` over `2026-07-06 … 2026-08-06`. GitHub's Actions
API caps pagination at 1000 runs, so the sample is the most recent 1000 of the
window's 1396 runs (3176 jobs, 16,363 job-minutes); the monthly figures below
scale that by 1.396.

| Runner         | Jobs/mo | Minutes/mo | CircleCI class   | Credits/min |     Credits/mo |
| -------------- | ------: | ---------: | ---------------- | ----------: | -------------: |
| ubuntu-latest  |  ~3,040 |    ~16,040 | Linux VM `large` |          20 |       ~320,700 |
| macos-latest   |    ~930 |     ~6,480 | `m4pro.medium`   |         200 |     ~1,295,000 |
| windows-latest |    ~465 |       ~330 | `windows.medium` |          40 |        ~13,200 |
| **Total**      |  ~4,435 |    ~22,850 |                  |             | **~1,629,000** |

Against CircleCI's 30,000 included credits and $15 per additional 25,000, that
is roughly **$960/month** — versus **$0 today**, because this repository is
public and GitHub-hosted runners are free for public repos.

**macOS is 79% of that.** The two macOS jobs (`test-macos`, `nix-build-macos`)
run on every pipeline at 200 credits/min, ten times the Linux rate. The single
highest-leverage change is to stop running them per-PR:

| Lever                                                     |           Saving |
| --------------------------------------------------------- | ---------------: |
| macOS on `main` + nightly only, not every PR (≈90% fewer) |         ~$700/mo |
| Linux `medium` instead of `large` (2 vCPU, slower)        |          ~$96/mo |
| Auto-cancel redundant workflows                           | volume-dependent |

For context on the volume itself: 1396 pipeline runs in 31 days is ~45/day,
and the fan-out is ~9 jobs per CI run. Halving the number of runs halves the
bill more reliably than any resource-class change.
