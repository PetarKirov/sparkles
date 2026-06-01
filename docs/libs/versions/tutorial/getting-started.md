# Getting started with `sparkles:versions`

This tutorial walks you, end to end, through the four things the library
does most often: **parse** a version string, **compare** two versions,
**sort** a list, and **test** a version against a range. By the end you
will have a single program that does all four and you will have run it.

You do not need to know anything about the library's design to follow
along — every line here is meant to be typed (or pasted) and run. The
[explanation](../explanation/design.md) and
[reference](../reference/concepts.md) sections are there for afterwards,
when you want to understand _why_ it is shaped this way.

## What you need

- A D compiler and `dub` (the examples are tested with LDC).
- Two minutes.

## Step 1 — a project that depends on the library

The whole tutorial is one self-contained `dub` single-file program.
Create `tour.d` with this header — the `/+ dub.sdl: … +/` block tells
`dub` what to fetch, so there is no separate project to set up:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "tour"
    dependency "sparkles:versions" version="*"
+/
```

Everything in the following steps goes into the same file. We will build
up one `main` and run it once at the end.

## Step 2 — parse a version

A _scheme_ is the type that knows how to read one ecosystem's version
strings. `SemVer` is the [Semantic Versioning](https://semver.org)
scheme. Parsing never throws — it returns a result you ask for the
`.value` of:

```d
import sparkles.versions.schemes.semver : SemVer;

auto v = SemVer.parse("1.4.2").value;
```

`v` is now a typed `SemVer`, not a string. (If the input were malformed,
`SemVer.parse` would return an error instead of a value — we cover that
in [Compare and sort versions](../how-to/compare-and-sort.md) and the
[reference](../reference/concepts.md#parsing). For now the inputs are all
valid.)

## Step 3 — compare two versions

Versions are _totally ordered_, so the ordinary `<`, `>`, `==` operators
work. The one rule worth learning up front: a **prerelease precedes its
release** — `1.4.2-rc.1` is _less than_ `1.4.2`, because a release
candidate comes before the final release.

```d
auto rc = SemVer.parse("1.4.2-rc.1").value;
bool before = rc < v;          // true: the rc comes first
```

## Step 4 — sort a list

`sort` orders a slice of versions ascending, in place. It uses the same
ordering as `<`, so the prerelease rule from Step 3 still holds:

```d
import sparkles.versions.operations : sort;

auto list = [
    SemVer.parse("1.10.0").value,
    SemVer.parse("1.2.0").value,
    SemVer.parse("1.2.0-beta").value,
];
sort(list);
// list is now: 1.2.0-beta, 1.2.0, 1.10.0
```

Notice `1.10.0` sorts _after_ `1.2.0`: components are compared
numerically, not as text, so `10 > 2`.

## Step 5 — test a version against a range

A _range_ is a set of versions. `parseNativeRange` reads the ecosystem's
own range syntax — for SemVer that is the npm grammar, including the
caret `^`. `^1.2.0` means "compatible within major version 1", i.e. every
`1.x.y` at or above `1.2.0` but below `2.0.0`. Ask whether a version is
in the set with `satisfies`:

```d
import sparkles.versions.operations : satisfies;

auto range = SemVer.parseNativeRange("^1.2.0").value;
bool ok  = v.satisfies(range);                          // 1.4.2 → true
bool no  = SemVer.parse("2.0.0").value.satisfies(range);// 2.0.0 → false
```

## The whole program

Put the steps together. This is the complete, runnable file:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "tour"
    dependency "sparkles:versions" version="*"
+/
import std.stdio : writeln;
import sparkles.versions.schemes.semver : SemVer;
import sparkles.versions.operations : sort, satisfies;

void main()
{
    // 1. Parse a version string into a typed value.
    auto v = SemVer.parse("1.4.2").value;
    writeln("parsed: ", v);

    // 2. Compare two versions — a prerelease precedes its release.
    auto rc = SemVer.parse("1.4.2-rc.1").value;
    writeln("rc < release: ", rc < v);

    // 3. Sort a handful of versions ascending.
    auto list = [
        SemVer.parse("1.10.0").value,
        SemVer.parse("1.2.0").value,
        SemVer.parse("1.2.0-beta").value,
    ];
    sort(list);
    foreach (x; list)
        writeln("  ", x);

    // 4. Parse an npm-style range and test membership.
    auto range = SemVer.parseNativeRange("^1.2.0").value;
    writeln("1.4.2 satisfies ^1.2.0: ", v.satisfies(range));
    writeln("2.0.0 satisfies ^1.2.0: ",
        SemVer.parse("2.0.0").value.satisfies(range));
}
```

Run it with `dub run --single tour.d`. You will see:

```
parsed: 1.4.2
rc < release: true
  1.2.0-beta
  1.2.0
  1.10.0
1.4.2 satisfies ^1.2.0: true
2.0.0 satisfies ^1.2.0: false
```

## What you learned

You parsed version strings into typed values, compared and sorted them
(prerelease before release, numeric components), and tested membership in
a caret range. That is the core loop for one ecosystem.

## Where to go next

- **A specific task?** The [how-to guides](../index.md#how-to-guides)
  cover comparing and sorting, building ranges, VERS/pURL interop, and
  adding your own scheme.
- **More than one ecosystem?** `SemVer` is one of eleven shipped schemes
  (PyPI, Maven, Debian, CalVer, …). The
  [scheme catalogue](../reference/schemes.md) lists them all.
- **Why is it shaped this way?** Start with
  [the design](../explanation/design.md).
