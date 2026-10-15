# `nix/ci` — the GitHub Actions pipeline, generated from Nix

Every file in `.github/workflows/` is rendered from this directory. Edit the
Nix, then run:

```bash
nix run .#render-workflows        # rewrite .github/workflows/*.yml
nix build .#checks.x86_64-linux.ci-workflows   # drift + actionlint/shellcheck
```

The `ci-workflows` pre-commit hook re-renders on every commit that touches
`nix/ci`. The workflow files name no store path that the repository's sources
decide (below), so a library edit leaves them alone. They change only when
the pipeline's shape does. A rebase conflict in a workflow file is resolved
by re-rendering, never by hand.

The shape follows [nialov/actions.nix](https://github.com/nialov/actions.nix/blob/25d2104c420cceacbf5b3935e2dd1dbfabe01d8c/README.md):
workflows, jobs and steps are a flake-parts option tree
(`ci.workflows.<name>.jobs.<id>.steps`), with `ci.defaultValues` for job
defaults. Three things are added.

## The work is tasks; jobs place them

What CI does is declared once, in [`tasks.nix`](./tasks.nix), as
`ci.tasks.<name>`. The model is
[devenv's tasks](https://devenv.sh/tasks/), built to store paths. A task is:

- a program, built by one of the factories below;
- the units it covers, which are its laziness;
- the dev-shell features it needs beyond what those units need;
- the tasks it runs `after`.

A workflow only places tasks: `steps = _: [ { task = "test"; units = shard; } ]`
puts a shard of `test` on a runner with that job's env (`DC=dmd`), and the
`after` tasks go before it, each once per job. `uses:` steps (caches)
interleave freely.

Run a task locally exactly as a job does. Unit args default to all the task's
units; the job's env (`DC`, tokens) is yours to set:

```bash
nix run .#ciTasks.test -- base core-cli
nix run .#ciTasks.examples -- docs/libs/event-horizon/tutorial/snippets/collie_channel.d
nix eval --json .#ci.tasks         # each task's units, features and `after`
```

A pass is remembered per (task, unit), and keyed by:

- the task's program;
- the system;
- the step and job env;
- the checkout depth;
- the `after` programs;
- the unit closure's sources.

So two jobs that place the same task on the same unit, in the same
environment, share the pass. Jobs without Nix (Windows, cloud-env) cannot run
a task. They keep a job-level `lazy`, keyed by their rendered YAML.

## Every step is a store path

On a runner with Nix, a step's `run` is a derivation; the option's type
rejects a string there. A step is built by one of the factories in
[`tools.nix`](./tools.nix):

| Factory                                  | PATH inside the step                                                 |
| ---------------------------------------- | -------------------------------------------------------------------- |
| `t.inShell name text`                    | the `ci` dev shell's, cut to the job's features (below)              |
| `t.preCommit name { only/skip; text; }`  | prek, git and the kept hooks' tools; `$PRE_COMMIT_CONFIG` is the cut |
| `t.script name { runtimeInputs; text; }` | exactly `runtimeInputs` (`writeShellApplication`, no inherited PATH) |
| `t.ciScript "x.sh" inputs`               | a `ci/x.sh` from the store, with `inputs`                            |

Nothing is looked up on the runner's PATH. The exceptions are explicit: the
bootstrap (checkout, install Nix, realise the job's closure), and the jobs
that run without Nix on purpose (`system = null`: the Windows leg, which has
no Nix, and `cloud-env-*`, which tests a bootstrap from nothing).

A Nix job's steps are gathered into one store path, the job's _bundle_
(`.#ci.bundles.<workflow>.<job>`): `bin/<NN>-<name>` links to each step's
program. The YAML runs `$CI_BUNDLE/bin/02-ci-lint`, not the program's store
path. The job's first own step resolves the bundle from the commit it runs:

- a job that needs the planner takes the path from the plan, which keyed the
  job's stamps from that same evaluation;
- any other job evaluates it;
- the planner's own bundle, made from nixpkgs alone, is written into the
  YAML, to spare the critical path an evaluation.

The step then substitutes the bundle from the cache, or builds it from the
flake. So what runs is always what the flake says now, never what an older
render committed. The only store paths left in the YAML (the planner's
bundle and the default shell's `bash`) change with a nixpkgs bump, not with
an edit to the repository.

## A job's shell is what its units need

The `ci` tier of the dev shell is a set of named _features_ (`ciFeatures` in
[`nix/shells/default.nix`](../shells/default.nix)): `base` (compilers, dub, the
helper, git, node), `sdl3`, `vulkan`, `shaders`, `nix-c-api`, `weston`, the
corpora, …. The dev shells take all of them. A task's `t.inShell` program
gets only the features its placed units' closures need (`graph.needsOf`),
plus any it lists in `features`:

- linked libraries are read from the recipes — each `libs` name maps to a
  feature (`libFeatures` in [`lib/graph.nix`](./lib/graph.nix)), and selecting
  `sparkles:ui`'s `gpu-effects` configuration needs `shaders`;
- what a test execs or reads at run time is listed in `testNeeds` (packages)
  and `fileNeeds` (examples and markdown by path), as `testReads` lists the
  files. A missing entry turns a test into a skip, or a failure.

A unit's needs reach its dependents. To see a job's set:

```bash
nix eval --json .#ci.features.ci
```

So a shard without the SDL3 backend does not download SDL3, only `wsi-demos`
gets weston, and a shard's key changes only when one of _its_ features does.
Jobs that run no D build (`docs`, the link sweeps) use `t.script` with their
few inputs instead of a shell.

## The pipeline is lazy

[`lib/graph.nix`](./lib/graph.nix) partitions the repository into units: each
dub sub-package (`pkg/<name>`, edges read from the recipes), each standalone
example (`example/<path>`), each runnable markdown file (`md/<path>`), the
OS-API demo trees, and a few coarse units (`repo`, `nix`, `harness`). A task
declares the units it covers (`units`) and the derivations it builds
(`drvs`).

For every (task, unit) a job places, the planner computes a key, a hash of:

- what the task's outcome depends on (see above);
- the store paths of the unit closure's filesets;
- the derivations' `drvPath`s.

It turns that key into a _stamp_, a flat fixed-output store path
([`lib/stamps.nix`](./lib/stamps.nix)). The `plan` job asks the cache which
stamps exist. A job whose stamps all exist is skipped, and a job placing a
`granular` task receives just its stale units in `$CI_UNITS`. The fan-in job
(`CI`, the one required check) records the stamps of every job that passed.
Nothing is recorded when one of the workflow's `fanIn.gate` jobs (the flake
checks, which hold the drift check) failed: a pass under a workflow that no
longer renders from the flake is not evidence.
A job with `lazy.enable = false` (a release) always runs.

So a docs edit runs the docs, the whole-tree checks and the markdown it
touched; an edit to `libs/x` re-runs everything whose closure reaches it.

`common = [ "harness" ]` keeps the `ci` helper's store path out of the
key: its steps are evaluated a second time against a stub `ci` (`ciTools.key`),
and `apps/ci`'s own sources join the key instead. Without that, an edit to any
of the 23 libraries the helper links would re-run every job. The tasks whose
pass `ci` judges (the tests, the examples, the markdown) also take
`pkg/core-cli` and `pkg/build-primitives`, through which it spawns the runs and
reads their results: a bug there that hid a failure would otherwise be
recorded as a pass.

To ignore every stamp, run the `CI` workflow by hand with `force`.

To see what an edit would re-run, compare plans before and after it:

```bash
nix eval --json .#ci.plan.ci > before.json   # then edit, and again
```
