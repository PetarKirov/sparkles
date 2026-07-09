# `sparkles:dman` — Command Schema

_The bidirectional, `wired`-based CLI/command pillar: one struct-with-UDAs
schema serves both dman's **own** CLI (`argv → struct`) and the **invocation**
of third-party tools like `git` (`struct → argv → spawn → decode`). This is the
CLI analogue of what [`sparkles:wired`](../wired/SPEC.md) does for JSON._

## The idea — the CLI is another `wired` format

`wired` maps D values ⇄ JSON, governed by `@Wire*` policy UDAs and a format
marker (`struct Json {}`). The insight ([D6](./DECISIONS.md)) is that the
**command line is just another format** (`struct Cli {}`): the same struct, the
same policy vocabulary, a different backend. In D this is unusually clean,
because a field's declared type **is** its parsed type — there is no separate
type-inference machinery to build.

So `@Option`/`@Argument` are domain-friendly **aliases** that desugar onto the
shared policy, plus a few CLI-only axes that `core-cli` owns:

| Axis         | Shared `wired.policy`                                          | CLI meaning (render ⇄ parse)                                               |
| ------------ | -------------------------------------------------------------- | -------------------------------------------------------------------------- |
| Name         | `@WireName("message")`                                         | `--message` (long spelling)                                                |
| Case         | `@WireCase(kebab)`                                             | `dryRun` → `--dry-run`                                                     |
| Optional     | `@WireOptional(WireSkip.whenDefault / WireInvalid.useDefault)` | omit flag when == default (render); missing → default (parse)              |
| Enum repr    | `@WireRepr(name)`                                              | a `choice` flag over enum member names                                     |
| Transform    | `@WireConvert!(to, from)`                                      | `Duration` ⇄ `"30s"` at the boundary                                       |
| — CLI-only — | _(no wired equivalent, owned by core-cli)_                     | flag-vs-**positional**-vs-**subcommand**, short alias `-m`, counter `-vvv` |

`@WireOptional`'s existing semantics — encode-omission (`whenDefault`) and
decode-tolerance (`useDefault`) — map _directly_ onto rendering and parsing an
optional flag, which is why the alias relationship is more than cosmetic.

## Three directions over one schema

```d
// ONE declarative schema — a faithful model of git's CLI surface.
@Command("git")
struct Git {
    @Option("C") string directory;                 // git -C <path>
    @Command("worktree") struct Worktree {
        @Command("add") struct Add {
            @Option("b")      string newBranch;     // -b <branch>
            @Option("detach") bool   detach;        // --detach
            @Argument("path") string path;
            @Argument("commit-ish", optional: true) string commitish;
        }
    }
}
```

1. **Parse** `argv → struct` — for dman's own CLI (`dman repo/worktree/branch`).
   _This half already exists_ in `core-cli`'s subcommands framework, with rich
   typing (int/enum/bool/`string[]`/counters), subcommand trees, help, and
   unknown-flag passthrough (`parseKnownCli`).
2. **Render** `struct → argv` — the inverse, over the _same_ UDAs (flag spelling
   from the name/aliases, `bool` → bare flag, `T[]` → repeated, positionals in
   declaration order, `--` handling). _Net-new; pure introspection; lives in
   `core-cli`._
3. **Decode** `stdout / exit → T` — return-type-driven collectors. _Net-new;
   glue in dman._

```d
// Invoke: struct → argv → spawn (io_uring) → typed result.
auto add = Git.Worktree.Add(newBranch: "feat/x", detach: true, path: "../wt-x");
Expected!(void, ProcError)     r  = env.run(add);                    // exit-code collector
Expected!(WorktreeList, _)     wl = env.run!WorktreeList(listCmd);   // stdout decoded via wired
```

## Return-type-driven collectors

`run!T` picks the collector by the requested return type, mirroring the fixed
menu Effect derives from a single `spawn`:

| `run!T`                           | Collector                                                      |
| --------------------------------- | -------------------------------------------------------------- |
| `run(cmd)` → `Expected!(void, E)` | exit code (nonzero ⇒ error)                                    |
| `run!string(cmd)`                 | stdout as text                                                 |
| `run!(string[])(cmd)`             | stdout split into lines                                        |
| `run!Struct(cmd)`                 | stdout decoded via `wired` (JSON), or a small porcelain parser |

For Git specifically, prefer machine-readable output: `--porcelain=v2`, `-z`
(NUL-delimited), or `--format`; `gh` offers `--json`. Where a tool has no
structured output, a small hand-rolled parser over `base.text` readers fills the
gap. The two formats interlock where a flag's _value_ derives from `wired`
field-names (e.g. `gh pr list --json number,title`).

## Packaging — no `sparkles:command`

There is **no dedicated executor library** ([D5](./DECISIONS.md)). The "run a
tool" path is glue composing three libraries already present:

```
core_cli.renderArgv(cmd)  →  event_horizon.proc.spawn(argv, opts)  →  wired.fromJSON!T(stdout)
   (pure, in core-cli)          (spawn + reap on the loop)              (return-type-driven decode)
```

- `core-cli` gains the pure `struct → argv` renderer and depends on `wired` for
  the shared `@Wire*` policy — but **never** on `event-horizon`, so arg-parsing
  stays free of `io_uring`.
- The spawn + decode glue lives in dman, promotable to a `core_cli.command`
  _module_ (not a package) if it proves reusable.
- A future option, deferred: split `core-cli` into `sparkles:tui` +
  `sparkles:command` once that surface grows.

## Testability & passthrough

Two properties fall out of the design:

- **The spawner is a capability.** Swap `env` for a `FakeSpawner` returning
  canned `(exit, stdout, stderr)` keyed by argv, and dman's entire VCS layer is
  testable with **zero real git** — the direct analogue of event-horizon's
  `TestClock` / `SimNet` and Effect's dependency-injected executor.
- **Git-compatible passthrough for free.** Because the schema parses _and_
  renders, dman can accept git-style arguments and re-emit them to real git —
  a thin VCS wrapper with no extra code.

## Prior art

The design unifies two separate Effect modules into one D vocabulary:
`platform/Command` (describe → spawn an external process → shape output) and
`cli/Command` (define a CLI: argv → typed handler input). What Effect needs a
`Param` / `Config.Infer` machinery for — mapping a flag spec to its value type —
is free in D, because the field type is the value type; the whole thing collapses
into field types + UDAs resolved at compile time.
