---
status: accepted
owner: sparkles:core-cli
---

# core-cli args subcommand specification

## Abstract

`sparkles:core-cli` lets a D program declare its command-line interface as
ordinary structs marked with attributes, and derives parsing, help and
dispatch from that declaration at compile time. This specification covers
how commands nest into subcommands. A program may list a command's
subcommands explicitly in one field, or simply nest command structs and
register externally defined ones, and the library discovers the tree
itself. Either way, parsing returns one stable result type that records the
whole chain of selected commands. The selected command runs through the
first handler it provides, in a fixed order of precedence, and that handler
may read the options given at every level of the chain.

## Introduction

Command-line tools with many operations group them into subcommands, often
several levels deep: `git worktree list` selects `list` within `worktree`
within `git`, and each level has its own options and help. A declarative
parser in D describes each command as a struct whose fields are its options
and positional arguments, so the compiler checks names and types and the
help text cannot drift from the parser. The subcommand hierarchy has to be
described too, and the way it is described shapes every program that uses
the library.

The direct description gives each command with subcommands a field that
holds whichever child the user selected, typed as a tagged union of the
child command types. It works, but it repeats the hierarchy in fields that
exist only for the parser to fill, and it keeps a command's children apart
from the struct nesting D already offers. Dropping the field raises
questions of its own: where the parsed child lives when no field holds it,
in which order children appear in help and take precedence in dispatch,
what happens when the user names a group but none of its children, and how
a handler deep in the tree reads options given to its ancestors.

The library answers them with a [command
graph](../../glossary.md#command-graph) that it builds at compile time from
the root command type. A command's children are the command structs nested
inside it and the command types registered into it with a mixin,
interleaved in the order the compiler lists its members. A command that
keeps the explicit field takes its children from that field instead. When
no field stores the selection, the parser synthesizes a parse tree whose
nodes each hold one command's parsed fields and, for a [command
group](../../glossary.md#command-group), the selected child's node.
Parsing returns one public result type whichever model the program uses,
so callers do not depend on where the selection is stored. A handler may
take the whole tree as a template parameter and read any level of it.

This page specifies command declaration, child discovery, the parse tree,
handler dispatch, and the compatibility between the explicit and the
graph-based models. It does not define the syntax of options and
arguments, value conversion, or help layout beyond the order of children.
The package's table renderer and terminal components have their own
specifications, [table.md](./table.md) and [the TUI component
suite](./tui-components/index.md). Rendering a declaration back into an
argument vector, and sharing naming and conversion rules with
`sparkles:wired`, are out of scope; the [command schema
page](../dman/command-schema.md) of `sparkles:dman` describes that design.

[Explicit subcommand fields](#explicit-subcommand-fields) describes the
field-based model and [Motivation](#motivation) its drawbacks. [The command
graph](#the-command-graph) and [Command child
discovery](#command-child-discovery) define the two ways to register
children and the order they take. [Synthesized parse
tree](#synthesized-parse-tree) and [Program tree
access](#program-tree-access) define the parse result, [Dispatch and
handlers](#dispatch-and-handlers) the handler precedence and the defaults
of command groups, and [Compatibility
requirements](#compatibility-requirements) what both models share.

## Explicit subcommand fields

`libs/core-cli/src/sparkles/core_cli/args/` describes CLIs with D structs and UDAs:

- `@(Command(...))` on a struct declares a command.
- `@(Option(...))` on a field declares a named option.
- `@(Argument(...))` on a field declares a positional argument.
- `@Subcommands` on a field declares the selected subcommand storage.

In this model, subcommands are named explicitly by a `SumType` field:

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

## The command graph

The parser builds a compile-time command graph for a root command type. The graph is
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
