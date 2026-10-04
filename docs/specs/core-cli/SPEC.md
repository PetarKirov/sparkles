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

The direct description gives each command with subcommands a field whose
type, a tagged union of the child command types, lists its children. It
works, but it repeats the hierarchy in fields that exist only to name types
for the parser, and it keeps a command's children apart from the struct
nesting D already offers. Describing children any other way raises
questions of its own: where the parsed child lives, in which order children
appear in help and take precedence in dispatch, what happens when the user
names a group but none of its children, and how a handler deep in the tree
reads options given to its ancestors.

The library answers them with a [command
graph](../../glossary.md#command-graph) that it builds at compile time from
the root command type. A command's children are the command structs nested
inside it and the command types registered into it with a mixin,
interleaved in the order the compiler lists its members. A command that
keeps the explicit field takes its children from that field instead. In
both models the parser stores the selection in a synthesized parse tree,
whose nodes each hold one command's parsed fields and, for a [command
group](../../glossary.md#command-group), the selected child's node.
Parsing returns one public result type whichever model the program uses,
so callers do not depend on how the children were declared. A handler may
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
field-based model and [Motivation](#motivation) its costs. [The command
graph](#the-command-graph) and [Command child
discovery](#command-child-discovery) define the two ways to register
children and the order they take. [Synthesized parse
tree](#synthesized-parse-tree) and [Program tree
access](#program-tree-access) define the parse result, [Dispatch and
handlers](#dispatch-and-handlers) the handler precedence and the defaults
of command groups, and [Compatibility
requirements](#compatibility-requirements) what both models share.

## Explicit subcommand fields

The `sparkles.core_cli.args` package
(`libs/core-cli/src/sparkles/core_cli/args/`) describes a CLI with D
structs and UDAs:

- `@(Command(...))` on a struct declares a command.
- `@(Option(...))` on a field declares a named option.
- `@(Argument(...))` on a field declares a positional argument.
- `@Subcommands` on a `SumType` field declares the command's children: the
  field's variants, in variant order.

In this model a command names its subcommands in one field:

```d
@(Command("git"))
struct Git
{
    @Subcommands
    SumType!(Add, Commit, Status) command;
}
```

A deeper tree places another `@Subcommands SumType!(...)` field on an
intermediate command struct. The field only lists the children: the parser
never assigns it, and stores the selected command in the parse tree's
`command` member instead, as for the graph-based model
([Synthesized parse tree](#synthesized-parse-tree)). A command that has a
`@Subcommands` field takes its children from that field alone; command
structs nested in it are not children.

## Motivation

The explicit `@Subcommands SumType!(...)` field has two costs:

- Its storage field repeats the command hierarchy and holds nothing at run
  time.
- It separates the command hierarchy from D's own struct nesting.

The command graph removes both: nesting a command struct, or registering an
external one with a mixin, declares a child without any storage field.

## The command graph

For a root command type, the parser builds a compile-time command graph
from command metadata. A command's children come from one of two sources:
its `@Subcommands` field when it has one, and otherwise the command graph
members described here.

There are two ways to register a graph child.

### Nested command structs

A member type of a command that carries `@(Command(...))` is a subcommand of
that command:

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

Here `git worktree list` is discovered without a `@Subcommands` field.

### External command registration

A command defined outside its parent is registered with a mixin inside the
parent, optionally together with a handler
([Dispatch and handlers](#dispatch-and-handlers)):

```d
@(Command("git"))
struct Git
{
    mixin addSubCommand!Worktree;
    mixin addSubCommand!(Status, statusHandler);
}
```

Each `addSubCommand` mixin declares a private marker field of type
`SubCommandRegistration!T` or `SubCommandRegistrationWithHandler!(T,
handler)`. Registration is a member rather than an attribute on the parent
so that nested and registered children are found by one discovery pass
over the parent's members, and so take one order.

## Command child discovery

The `sparkles.core_cli.args` package exposes the graph children of a command
as the template `commandChildren`. For a `Git` that nests `Worktree` and
then registers `Status`, `commandChildren!Git` is
`AliasSeq!(Git.Worktree, Status)`.

The graph children of a command are:

- member types that carry a `Command` UDA;
- command types registered by `mixin addSubCommand!T` or
  `mixin addSubCommand!(T, handler)`;

interleaved in the order `__traits(allMembers, T)` lists their members.

Children, whether from the graph or from a `@Subcommands` field, appear in
help in this order, and a command whose children carry more than one default
marker uses the first one ([Default handlers for command
groups](#default-handlers-for-command-groups)). Arranging the members of a
command struct therefore arranges its `--help` listing.

**CLI1: Duplicate graph children.** `commandChildren!T` **must** fail
compilation when two graph children of `T` are the same type, or when two of
them share a primary command name.

## Synthesized parse tree

Nested structs and registration markers do not store a selected child, and
a `@Subcommands` field is not written either. For every command with
children, parsing fills a `CommandNode` instead:

```d
struct CommandNode(Command_)
{
    alias Command = Command_;

    Command value;
    alias value this;

    bool[string] seenOptions;

    // Present only when Command has children.
    SumType!(staticMap!(CommandNode, allChildren!Command)) command;
    bool commandSelected;
}
```

For `git worktree list`, the parsed value has this shape:

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

The node of a command without children is still a `CommandNode`; only the
root of a program without any subcommands is not wrapped. The public alias
`ParsedCommand` names the result type:

```d
template ParsedCommand(Command)
{
    static if (allChildren!Command.length > 0)
        alias ParsedCommand = CommandNode!Command;
    else
        alias ParsedCommand = Command;
}
```

`parseCli!Root` and `parseKnownCli!Root` return
`CliExpected!(ParsedCommand!Root)`, and `runCli!Root` passes a
`ref ParsedCommand!Root` to its `beforeRun` callback. Both the explicit and
the graph-based model produce this type, so a program can move from one to
the other without changing its callers. `alias value this` keeps direct
reads of a command's own options, such as `parsed.value.logLevel`, compiling
on the node.

## Dispatch and handlers

`runParsedCli` walks the parse tree from the root, following `command`
through every node whose `commandSelected` is set, and calls the handler of
the command where the walk stops. A handler is either a `run` member of the
command or an external handler registered with
`mixin addSubCommand!(T, handler)`.

Dispatch priority:

1. the external handler registered by `mixin addSubCommand!(T, handler)`,
   called as `handler!Program(program)`, `handler(program)` or `handler()`,
   the first form that compiles;
2. `run!Program(program)`, a template taking the whole parse tree;
3. `run(program)`, a non-template taking the parse tree;
4. `run()`.

A `run` member may be `static` or an instance method; an instance method
reads both its own parsed fields and the program. A handler returns `int`,
`void`, or an `Expected`. An `int` or a successful `Expected!int` is the exit
code, and `void` or another successful `Expected` exits with 0; an error is reported and mapped to an exit code
(`CliError` through `reportCliError`, an `int` error as itself, anything
else as 1).

**CLI2: Missing handler.** Dispatch **must** fail compilation when the
command it reaches has neither a registered handler nor a `run` member
callable in one of the forms above.

`Program` is `ParsedCommand!Root`, so a command can inspect the entire
synthesized parse tree even though the tree type is generated by the
library:

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

A command group requires a subcommand unless default handling applies.

**CLI3: Missing subcommand.** When parsing ends at a command group without
selecting a child, and neither of the defaults below applies, `parseCli`
**must** fail with a parse error whose message is `Missing subcommand` and
whose help text is that group's help. `runCli` prints `Error: Missing
subcommand` followed by the help and exits with 1; unlike `--help`, the call
is reported as incorrect.

Default handling is declared on a child, not on the group: `makeDefault()`
on a command's `Command` metadata, or `isDefault: true` in its constructor,
marks that command as its parent's _default child_. The marker has two
effects.

First, the parent hands its remaining arguments to the default child,
parsing them as though the child's name had been typed, when it meets:

- a non-option token that names none of its children;
- an option that neither it nor any ancestor recognizes;
- the end of the arguments with no child selected, in which case the
  default child parses an empty argument list.

Second, a marked command that is itself a group, and whose parse selects
none of its children, succeeds without a child, and dispatch calls the
group's own handler under the same priority rules as any other command. A
group consults its own default child before falling back to its own
handler.

```d
@(Command("worktree").makeDefault())
struct Worktree
{
    @(Option("verbose"))
    bool verbose;

    static int run(Program)(in Program program)
    {
        return 0;
    }

    @(Command("list"))
    struct List
    {
        int run() => 7;
    }
}
```

With `Worktree` nested in `git`, `git worktree list` runs `List`, while
`git worktree`, `git worktree --verbose` and `git` alone run `Worktree`'s
own handler. Without the marker, `git worktree` fails with `Missing
subcommand`.

## Program tree access

A `CommandNode` exposes these members:

- `value`: the parsed fields of the current command, also reachable through
  `alias value this`;
- `seenOptions`: the dotted field paths (`"treeWidth"`, `"sink.backend"` for
  a `@Flatten`ed group) that an argument explicitly set at this level, named
  options and positionals alike, so a caller can layer the command line
  over configuration and override only what the user typed;
- `command`: the selected child node, present only for a command group;
- `commandSelected`: whether `command` holds a parsed child, present only
  for a command group.

The library provides no helper for selected-leaf lookup, command-path
lookup or visiting the selected chain; a handler matches on `command` level
by level.

## Compatibility requirements

The explicit and the graph-based models share one implementation. The only
point where they differ is the source of a command's children, so both
models parse, format help, resolve string-imported help paths such as
`git/worktree/list`, and dispatch identically:

- explicit `@Subcommands SumType!(...)` fields parse and run;
- `run()` leaf methods dispatch alongside the program-taking forms;
- help generation and string-import path resolution walk the children of
  either model.

## Open questions

- None.
