---
status: accepted
owner: sparkles:core-cli
---

# core-cli environment fallback specification

## Abstract

An option of a `sparkles:core-cli` program may name an environment variable
to fall back to: when the command line leaves the option out, the parser
reads the option's value from that variable, exactly as it would read
`--option=VALUE`. The program's help names the variable beside the option,
and a subcommand's help lists the options of the commands above it, so
every setting a program reads from the environment can be found from
`--help` and given on the command line instead.

## Introduction

Tools read settings from the environment because it reaches them through
wrappers, scripts and CI jobs that never touch the command line: a cache
directory from `XDG_CACHE_HOME`, a token from `GITHUB_TOKEN`. A variable
read directly with `environment.get`, though, is invisible: no help page
names it, nothing parses or validates it the way an option is, and the only
way to set it for one run is to prefix the command. The library therefore
lets the option own the variable. The command line stays the one place a
setting is given, the variable becomes that option's default, and the help
documents both.

The design follows argparse's `EnvFallback`, with one difference: an empty
variable counts as unset, the convention of the XDG base directory
specification and of `NO_COLOR`, so `XDG_CACHE_HOME= tool` behaves as if the
variable were absent.

This page covers declaring a fallback, when and how the parser reads it, and
how help shows it. The command graph, dispatch and the parse tree are
specified in [the subcommand specification](./SPEC.md).

## Declaring a fallback

`Option` takes the variable's name as `envFallback`, as a named argument or
through the builder:

```d
@(Option(`cache-dir`, placeholder: "DIR", envFallback: "XDG_CACHE_HOME",
    description: "The cache home."))
string cacheDir;
```

`parseCli` and `parseKnownCli` read the process environment. A caller may
pass an `EnvLookup` instead, a delegate from a variable's name to its value
(empty when unset), which is how the tests run against a fixed environment.

**CLE1: Precedence.** An option given on the command line **must** take its
value from the command line, wherever the option appears: an ancestor's
option given after the subcommand's name still wins over its variable.
Otherwise, when its variable is set and not empty, the option **must** take
the variable's value. Otherwise the field **must** keep the value it had
before parsing.

**CLE2: Parsing.** A variable's value **must** parse as `--option=VALUE`
would: an enum by its wire names, a `bool` by its spellings, an array split
on commas, `allowedValues` enforced, a `Switches` set through its own
syntax. `help` and `?` in a variable are values, not requests for help. A
value that does not parse **must** fail the parse with a message that names
the variable and the option, `$TOOL_JOBS (the fallback for --jobs): …`.

**CLE3: A fallback counts as given.** An option filled from its variable
**must** satisfy `required`, and **must** appear in its node's
`seenOptions`, so a caller layering the command line over configuration
files lets the environment override them as a typed option would.

## Help

**CLE4: The variable is discoverable.** The help line of an option with a
fallback **must** end with `[env: NAME]`, and so must the option's own help
(`--option=?`). A subcommand's help **must** list the options of each
command above it, which it accepts too, in one section per ancestor headed
`<command> options`, the root's first.

## Evidence ledger

| Requirement | Status    | Evidence                                                                                                | Gaps |
| ----------- | --------- | ------------------------------------------------------------------------------------------------------- | ---- |
| CLE1        | delivered | `args.envFallback.precedence`, `args.envFallback.rootOptionAfterSubcommand`                             | —    |
| CLE2        | delivered | `args.envFallback.parsesAsAnInlineValue`                                                                | —    |
| CLE3        | delivered | `args.envFallback.satisfiesRequired`                                                                    | —    |
| CLE4        | delivered | `args.envFallback.help`, `args.formatHelp.inheritedOptions`, `args.Option.namedArguments` (the builder) | —    |
