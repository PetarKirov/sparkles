# `sparkles:unittest-layout`

The lint behind the build graph's unittest layout rule
([BGV4–BGV5](../../specs/build-primitives/build-graph/SPEC.md#_3-variants)).

## Why the rule exists

A package's test binary compiles its own sources with `-unittest`, which
turns `version (unittest)` on in every module it imports, its dependencies'
included. The dependency libraries it links were compiled without it. So a
`version (unittest)` in a library that adds a field, a virtual method, a
public declaration or a template branch makes the test binary see one
layout and link code compiled against another.

## What it reports

`checkLayout` (`sparkles.unittest_layout.lint`) parses a module with DMD's
parser, without semantic analysis, so it sees both branches of every
`version (unittest)` and every template body. It reports, by line:

- a declaration visible outside its module in a `version (unittest)` branch,
  at any level; a `public:` label above an import makes it a public import;
- a field, virtual method, destructor, postblit or copy constructor there, of
  any visibility;
- a template there, whatever its visibility;
- a `version (unittest)` inside a template, or inside the body of a function
  a dependent compiles (an `auto` function, one in a template, one under
  `pragma(inline, true)`);
- an import there of a module the library does not depend on.

A `private`, non-template, module-level declaration is exempt when its
`version (unittest)` has no `else` branch: without `-unittest` it does not
exist, so only tests can use it. Declarations inside `unittest` blocks are
never reported, since a `unittest` block compiles only in its own package's
test root.

```d
import sparkles.unittest_layout.lint : checkLayout;

const report = checkLayout("m.d", "struct S {\nversion (unittest) int x;\n}", (m) => true);
assert(report.parsed && report.violations[0].what == "a field");
```

## DMD's parser, for now through the frontend

The lint needs DMD's parse-only AST, which the fork's `dmd:parser` leaves out,
so it depends on `dmd:frontend` and parses as `sparkles:dmd-fmt` does
([build-graph D56](../../specs/build-primitives/build-graph/decisions.md#d56-planning-reads-d-source-with-dmd-s-lexer-and-parser-accepted)).
It parses under `sparkles:d-source`'s lock for DMD's process-wide state.
