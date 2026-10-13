# `nix/ci` — the GitHub Actions pipeline, generated from Nix

Every file in `.github/workflows/` is rendered from this directory. Edit the
Nix, then run:

```bash
nix run .#render-workflows        # rewrite .github/workflows/*.yml
nix build .#checks.x86_64-linux.ci-workflows   # drift + actionlint/shellcheck
```

The `ci-workflows` pre-commit hook re-renders on every commit that touches a
source the steps are built from. A rebase conflict in a workflow file is
resolved by re-rendering, never by hand.

The shape follows [nialov/actions.nix](https://github.com/nialov/actions.nix/blob/25d2104c420cceacbf5b3935e2dd1dbfabe01d8c/README.md):
workflows, jobs and steps are a flake-parts option tree
(`ci.workflows.<name>.jobs.<id>.steps`), with `ci.defaultValues` for job
defaults. Two things are added.

## Every step is a store path

On a runner with Nix, a step's `run` is a derivation, rendered as its
`/nix/store/…/bin/<name>`; the option's type rejects a string there. A step
is built by one of the factories in [`tools.nix`](./tools.nix):

| Factory                                  | PATH inside the step                                                 |
| ---------------------------------------- | -------------------------------------------------------------------- |
| `t.inShell name text`                    | the `ci` dev shell's, captured at build time (`lib/shell-env.nix`)   |
| `t.inPreCommit name text`                | the pre-commit shell's, plus git                                     |
| `t.script name { runtimeInputs; text; }` | exactly `runtimeInputs` (`writeShellApplication`, no inherited PATH) |
| `t.ciScript "x.sh" inputs`               | a `ci/x.sh` from the store, with `inputs`                            |

Nothing is looked up on the runner's PATH. The exceptions are explicit: the
bootstrap (checkout, install Nix, realise the job's closure), and the jobs
that run without Nix on purpose (`system = null`: the Windows leg, which has
no Nix, and `cloud-env-*`, which tests a bootstrap from nothing).

Each Nix job's first own step realises one store path, the job's _bundle_
(every step program). It is substituted from the cache when it is there, and
built from the flake when it is not; a built path that differs from the one
in the YAML fails the job as stale workflows.

## The pipeline is lazy

[`lib/graph.nix`](./lib/graph.nix) partitions the repository into units: each
dub sub-package (`pkg/<name>`, edges read from the recipes), each standalone
example (`example/<path>`), each runnable markdown file (`md/<path>`), the
OS-API demo trees, and a few coarse units (`repo`, `nix`, `harness`). A job
declares the units it covers (`lazy.units`) and the derivations it builds
(`lazy.drvs`).

For every (job, unit) pair the planner computes a key — a hash of the job's
rendered YAML, the store paths of the unit closure's filesets and the
derivations' `drvPath`s — and turns it into a _stamp_, a flat fixed-output
store path ([`lib/stamps.nix`](./lib/stamps.nix)). The `plan` job asks the
cache which stamps exist; a job whose units all have one is skipped, and a
`granular` job receives just its stale units in `$CI_UNITS`. The fan-in job
(`CI`, the one required check) records the stamps of every job that passed.

So a docs edit runs the docs, the whole-tree checks and the markdown it
touched; an edit to `libs/x` re-runs everything whose closure reaches it.

`lazy.common = [ "harness" ]` keeps the `ci` helper's store path out of the
key: its steps are evaluated a second time against a stub `ci` (`ciTools.key`),
and `apps/ci`'s own sources join the key instead. Without that, an edit to any
of the 23 libraries the helper links would re-run every job.

To ignore every stamp, run the `CI` workflow by hand with `force`.

To see what an edit would re-run, compare plans before and after it:

```bash
nix eval --json .#ci.plan.ci > before.json   # then edit, and again
```
