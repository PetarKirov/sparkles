# `sparkles:dman` — CLI Surface

_The concrete `dman` v1 command tree — the scriptable interface, defined with the
**same** command schema ([D5](./DECISIONS.md)/[D6](./DECISIONS.md)) dman uses to
invoke git. Every operation is available non-interactively; bare `dman` (on a TTY)
launches the [TUI shell](./tui-shell.md). Commands delegate to the
[VCS backend](./vcs-backend.md) and [repo catalog](./repo-catalog.md)._

## The command tree

The root carries global options that reach every leaf; subcommands are the
noun-verb tree:

```d
@Command("dman")
struct Dman {
    @Option("repo")      string repo;        // PATH | URL; default = CWD walk-up
    @Option("config")    string configPath;
    @Option("json")      bool   json;        // emit wired-JSON instead of tables
    @Option("v|verbose") bool   verbose;
    @Option("no-color")  bool   noColor;

    @Subcommands SumType!(Repo, Branch, Worktree, Status, Tui) command;
}

@Command("branch") struct Branch {
    @Subcommands SumType!(List, Show, Delete, Create, Switch) command;

    @Command("delete") struct Delete {
        @Option("force")   bool     force;      // allow unmerged
        @Option("dry-run") bool     dryRun;
        @Option("yes")     bool     yes;        // no confirm (CI)
        @Argument("name")  string[] names;      // multi-select
    }
    // List: @Option filter/sort/search flags; Show/Create/Switch analogous
}
```

## Commands → operations

| Command                                                      | Does                        | Backend call                  |
| ------------------------------------------------------------ | --------------------------- | ----------------------------- |
| `dman repo scan [--root DIR]… [--depth N]`                   | discover + catalog repos    | catalog scan                  |
| `dman repo list [--tag T] \| add \| remove \| show`          | manage the catalog          | catalog                       |
| `dman repo tag add\|remove <tag>`                            | manage user tags            | catalog                       |
| `dman workspace list \| show \| create \| members \| delete` | multi-repo groups           | [Workspaces](./workspaces.md) |
| `dman branch list [--filter --sort --search]`                | classified branch list      | `VcsRepo.branches`            |
| `dman branch show NAME`                                      | one branch's detail         | `VcsRepo.branches`            |
| `dman branch delete NAME… [--force --dry-run --yes]`         | delete branches             | `VcsRepo.deleteBranch`        |
| `dman branch create \| switch`                               | create / switch             | (git via schema)              |
| `dman worktree list \| add \| remove \| prune`               | worktree ops                | `VcsRepo.*Worktree*`          |
| `dman worktree enter NAME`                                   | cd in + record context      | [D13](./DECISIONS.md)         |
| `dman worktree exec NAME -- CMD…`                            | run in worktree (exit code) | [D13](./DECISIONS.md)         |
| `dman status`                                                | repo status                 | `VcsRepo.status`              |
| `dman` (TTY) or `dman tui`                                   | interactive UI              | [TUI shell](./tui-shell.md)   |

## Scripting & machine output

- **`--json`** on any read command emits `wired`-JSON of the _typed_ result
  (`BranchInfo[]`, `WorktreeInfo[]`, `RepoRef[]`) — the same structs the TUI
  renders, straight to a pipe. The struct field-names are the JSON keys
  ([D6](./DECISIONS.md)).
- **Mutations** support `--dry-run` (show what would happen, write to the action
  log) and `--yes` (skip confirmation). The non-interactive path is **genuinely
  prompt-free** — no hidden prompt may block a `--yes` run — so branch/worktree
  cleanup scripts work unattended in CI.
- **Exit codes** are structured and actionable: distinct codes for selection
  failures (a **reserved code** meaning "selection required"), protected-branch
  refusals, and tool errors.

## Interactive vs non-interactive

Bare `dman` on a TTY opens the TUI; a non-TTY invocation or an explicit subcommand
runs the scriptable path. Both drive the _same_ `VcsRepo` + catalog + command
schemas — the TUI is a second front-end over the identical core, not a fork.

## Git-compatible passthrough

Because the command schema parses _and_ renders, dman can forward git-style
arguments to real git (`parseKnownCli` collects unrecognized flags), so a thin
`dman git …` wrapper — or accepting familiar git flags on dman's own verbs — costs
no extra code. See [Command schema](./command-schema.md#testability--passthrough).

## Backend dispatch & jj-only verbs (P3)

The command tree above is backend-neutral: `dman branch`/`worktree`/`status`
dispatch to the per-repo backend the catalog recorded (git or jj), with an
optional `--backend` override. When the jj backend lands ([D8](./DECISIONS.md),
[Designing for jj](./jj-model.md)) it adds **capability-gated** verbs that have no
git counterpart — `dman op log` / `dman undo` (real operation-log undo),
`dman worktree update-stale`, and bookmark `track`/`untrack` + delete-vs-forget —
hidden or erroring on git repos. On jj, `worktree` maps to `jj workspace` and
`branch` to bookmarks; dman's `--dry-run` action log gains genuine one-command
undo behind it.
