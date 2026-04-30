# core-cli args subcommand specification

This document records the current `sparkles.core_cli.args` command model and the planned
alternative subcommand definition model.

## Current design

`libs/core-cli/src/sparkles/core_cli/args.d` describes CLIs with D structs and UDAs:

- `@(Command(...))` on a struct declares a command.
- `@(Option(...))` on a field declares a named option.
- `@(Argument(...))` on a field declares a positional argument.
- `@Subcommands` on a field declares the selected subcommand storage.

Subcommands are currently represented with an explicit `SumType` field:

```d
@(Command("git"))
struct Git
{
    @Subcommands
    SumType!(Add, Commit, Status) command;
}
```

Nested command trees are supported by placing another `@Subcommands SumType!(...)` field on
intermediate command structs. Parsing walks this explicit tree, stores the selected command
instance in the matching `SumType`, and `runParsedCli` recursively unwraps the selected
variant until it reaches a leaf command.

Help formatting and string-imported help text also use this explicit subcommand tree to
compute command paths such as `git/worktree/list`.

## Motivation

The explicit `@Subcommands SumType!(...)` field works, but it has two drawbacks:

- It requires boilerplate storage fields that repeat the command hierarchy.
- It separates the structural command hierarchy from natural D nesting.

The new design should allow command hierarchy to be described by nested structs and by
mixins that register externally defined command structs.

## New design

The parser should build a compile-time command graph for a root command type. The graph is
derived from command metadata rather than only from a physical `@Subcommands` field.

There are two ways to register child commands.

### Nested command structs

Direct nested member types with `@(Command(...))` are subcommands of their containing
command:

```d
@(Command("git"))
struct Git
{
    @(Command("worktree"))
    struct Worktree
    {
        @(Command("list"))
        struct List
        {
            @(Option("porcelain"))
            bool porcelain;

            int run() { return 0; }
        }
    }
}
```

In this example, `git worktree list` is discovered without an explicit
`@Subcommands SumType!(Worktree)` field.

### External command registration

Commands defined outside the parent can be registered with a mixin inside the parent:

```d
@(Command("git"))
struct Git
{
    mixin addSubCommand!Worktree;
    mixin addSubCommand!(Status, statusHandler);
}
```

This replaces the previously considered UDA builder form:

```d
@(Command("git")
    .addSubcommand!Worktree()
    .addSubcommand!(Status, statusHandler)())
struct Git {}
```

The mixin form keeps nested commands and external commands in the same discovery pass:
both are members of the parent command type.

## Command child discovery

`args.d` should expose or internally define one unified trait:

```d
alias commandChildren!Git = AliasSeq!(Git.Worktree, Status);
```

The children of a command are:

- direct nested member types with a `Command` UDA;
- command types registered by `mixin addSubCommand!T`;
- optionally both, concatenated in compiler-provided member discovery order.

The compiler-provided order should be used for help output and dispatch precedence. This
lets users customize `--help` ordering by arranging or naming members in command structs
according to the compiler's member ordering rules.

Duplicate child registrations should be rejected at compile time. At minimum, duplicate
types and duplicate primary command names should fail clearly.

The existing explicit `@Subcommands SumType!(...)` model remains supported for
compatibility. The new graph-based model is an alternative, not an immediate replacement.

## Synthesized parse tree

Nested structs do not create storage fields. Therefore, when a command graph is discovered
without an explicit `@Subcommands` storage field, parsing must synthesize a parse tree type.

Conceptually:

```d
struct CommandNode(Command)
{
    Command value;

    // Present only when Command has children.
    SumType!(
        CommandNode!(Child1),
        CommandNode!(Child2),
    ) command;
}
```

For `git worktree list`, the parsed value is conceptually:

```d
CommandNode!Git {
    value: Git(...),
    command: CommandNode!(Git.Worktree) {
        value: Worktree(...),
        command: CommandNode!(Git.Worktree.List) {
            value: List(...)
        }
    }
}
```

The public alias should make this type name stable:

```d
alias ParsedCommand!T = CommandNode!T;
```

`parseCli!Root` should always return `CliExpected!(ParsedCommand!Root)`. For command
trees that already use explicit `@Subcommands SumType!(...)` storage, `ParsedCommand!Root`
may alias `Root` as a compatibility detail, but callers should write against
`ParsedCommand!Root` as the public parsed result type.

This keeps the parser API stable as command storage moves from user-declared fields to
synthesized command nodes.

## Dispatch and handlers

Leaf dispatch should support both command-owned `run` methods and externally registered
handlers.

Dispatch priority:

1. external handler registered by `mixin addSubCommand!(T, handler)`;
2. `static int run(Program)(in Program program)`;
3. `static void run(Program)(in Program program)`;
4. `int run()`;
5. `void run()`;
6. compile-time error.

External handlers registered through `mixin addSubCommand!(T, handler)` should support the
same signatures as `run` member functions.

The generic `Program` form lets a command inspect the entire synthesized parse tree even
though the exact tree type is generated by `args.d`:

```d
@(Command("list"))
struct List
{
    static int run(Program)(in Program program)
    {
        // Inspect root, parent, or selected command data through `program`.
        return 0;
    }
}
```

### Default handlers for command groups

Commands with children should normally require a subcommand. If no subcommand is selected
and the command has no default handler, parsing should treat the input as an incorrect CLI
call and print help for that command group. For example, `git worktree` should behave like
`git worktree --help` when `worktree` has subcommands but no default handler.

A command group opts into default handling with command metadata, using a
`Command.makeDefault()` method or a similarly named builder:

```d
@(Command("worktree").makeDefault())
struct Worktree
{
    static int run(Program)(in Program program)
    {
        return 0;
    }

    @(Command("list"))
    struct List
    {
    }
}
```

The default handler is called when the command itself is selected and none of its available
subcommands is selected. It should use the same handler signature rules as any other
command handler.

## Program tree access

Generated command nodes should expose predictable member names:

- `value`: parsed fields for the current command node;
- `command`: selected child node, present only for non-leaf nodes.

Additional helper APIs may be added later, such as:

- selected leaf lookup;
- command path lookup;
- visitors over the selected command chain.

These helpers should be layered on top of the stable node shape rather than replacing it.

## Compatibility requirements

The implementation should preserve current behavior for existing callers:

- explicit `@Subcommands SumType!(...)` fields continue to parse and run;
- existing `run()` leaf methods continue to work;
- existing help generation and string-import path resolution continue to work.

The new graph-based model should share the same parsing, help formatting, and dispatch
semantics as the explicit model wherever possible.

## Open questions

- None currently.
