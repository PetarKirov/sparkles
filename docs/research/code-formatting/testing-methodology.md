# How formatters test themselves

A survey of the **test infrastructure** of eleven production formatters, read from their pinned
source trees. [Verification][verification] answers _how a formatter proves it did not break your
code_; this page answers the more mundane and more immediately useful question — **what does the
test suite look like, and how do you write 160 decisions' worth of expectations without drowning?**

**Last reviewed:** August 25, 2026

The two are different problems. Verification is a property check that runs on every file forever
(`PARSE(FORMAT(s)) ≡ PARSE(s)`). Testing is an authoring problem: every layout decision needs an
example, every configurable decision needs one example _per value_, and each example has to stay
correct across years of engine changes. The formatter that gets verification right and testing
wrong ends up with a correct engine nobody dares change.

> [!IMPORTANT]
> **The finding that matters most: the best suites make one written artifact serve three jobs.**
> dart*style's fixture files are simultaneously the test corpus, the specification of each rule, and
> readable prose with descriptions attached to each case. rustfmt goes further and makes its
> \_user documentation* executable — every code block in `Configurations.md` is formatted under the
> option it documents and asserted to be already-formatted, plus a gate that **fails the build if
> any config option lacks a documentation section**. That is the pattern to copy: not "write tests,
> then write docs", but one source that generates both, with a coverage gate connecting them.
>
> The second finding is a warning. **clang-format's `messUp` — mangle the expected output, assert
> the formatter recovers it — is the highest-leverage technique in the survey and it is unavailable
> to any formatter that preserves the author's line breaks**, because the mangling destroys exactly
> the input signal such a formatter reads. §"What does not transfer" works out the replacement.

---

## Method

Every claim is read from a pinned checkout. Test harness code, fixture files and CI workflows were
read directly; nothing here comes from a project's own description of its testing.

| System                      | Pin                                        |
| --------------------------- | ------------------------------------------ |
| [prettier][pr]              | `414e453ae9034866d93eea456b430aa52140371b` |
| [rustfmt][rf]               | `320de2e6d44f3190ea7cc73772e67a2ae86f5e71` |
| [dart_style][ds]            | `3b1f30e3a0b568281f72320bcb248a2f0cd8ce79` |
| [black][bk]                 | `74371e2041a3120a049ced8f1cab0e7a6bc8ecd3` |
| [ruff][ru]                  | `3b067a163e58614fd022c24f1274404a0f386179` |
| [clang-format][llvm] (LLVM) | `73802c2e9d102a4fb646bc039754779fca3ea476` |
| [gofmt][go] (Go)            | `015343854b5d9e2829481df30dbcae2ca6682d25` |
| [ocamlformat][of]           | `20c4543119c82a51c2f3a9bf81620a7f31fe0e50` |
| [zig fmt][zg] (Zig)         | `1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa` |
| [swift-format][sf]          | `4be9f3a16d429df692694ab17744b1014b0ac7af` |
| [dfmt][dfmt-repo] (D)       | `c65d1c8a9cd2d784ded4cc7517c2cdd42c0c5c76` |

---

## The comparison

**Fixture shape** is how an input/expected pair is written down. **Options** is how a test says
_"with this setting"_. **Bless** is the mechanism for updating expectations wholesale.

| System           | Fixture shape                                                                      | Options mechanism                             | Bless                | Idempotence             | Semantic check         | Real-world corpus  | Fuzz             |
| ---------------- | ---------------------------------------------------------------------------------- | --------------------------------------------- | -------------------- | ----------------------- | ---------------------- | ------------------ | ---------------- |
| **dart_style**   | **many cases per file**, `>>>` input / `<<<` output, each with a description       | per-file header + per-case `(indent 4)`       | script               | ✅                      | —                      | —                  | —                |
| **rustfmt**      | parallel trees: `tests/source/x.rs` → `tests/target/x.rs`                          | `// rustfmt-key: value` header in the fixture | —                    | ✅                      | —                      | —                  | —                |
| **prettier**     | input file + **jest snapshot** holding options, input, output                      | `jsfmt.spec.js` per directory, option matrix  | `jest -u`            | ✅ (second format)      | ✅ AST compare         | —                  | —                |
| **black**        | one file, `# flags:` header, `# output` separator                                  | `# flags: --unstable` in the fixture          | env var              | ✅                      | ✅ AST equivalence     | —                  | ✅ hypothesmith  |
| **ruff**         | input + **insta snapshot**; `x.py.options.json` may hold an _array_ of option sets | `.options.json` beside the input              | `cargo insta accept` | ✅ stability check      | ✅ unchanged AST       | ✅                 | —                |
| **clang-format** | **C++ unit tests**; `verifyFormat(expected)` — no input file at all                | argument to the assertion                     | —                    | ✅ implied              | —                      | —                  | —                |
| **gofmt**        | `testdata/x.input` → `testdata/x.golden`                                           | flags in the test table                       | `-update`            | ✅ explicit second pass | —                      | ✅ stdlib          | —                |
| **ocamlformat**  | `tests/x.ml` + `x.ml.ref` + `x.ml.err` + `x.ml.opts`                               | **four parallel `refs.<profile>/` trees**     | `dune promote`       | ✅ (engine)             | ✅ runtime, every file | ✅ `test/projects` | —                |
| **zig fmt**      | **inline in source**: `testCanonical(src)` / `testTransform(src, expected)`        | —                                             | —                    | ✅ canonical            | —                      | —                  | ✅ OOM injection |
| **swift-format** | inline strings with **marker-annotated** expected diagnostics                      | `Configuration` argument                      | —                    | ✅                      | —                      | —                  | —                |
| **dfmt** (D)     | `tests/x.d` + `x.args` + refs under `allman/` and `otbs/`                          | `x.args` file of CLI flags                    | `gen_expected.sh`    | —                       | —                      | —                  | —                |

---

## The technique catalogue

Twelve techniques, each with what it costs and what it buys. Most systems use three or four; nobody
uses all twelve.

### 1. Expected-only fixtures (`verifyFormat`, `testCanonical`)

**clang-format, zig fmt.** The test states only the _output_. The harness asserts the formatter
leaves it unchanged, then mangles it and asserts the formatter reproduces it. One string, two
assertions, and the fixture is readable as a specification because it contains no deliberate ugliness.

```cpp
verifyFormat("void f() { return; }");   // format(x) == x, and format(messUp(x)) == x
```

### 2. Deterministic mangling (`messUp`)

**clang-format.** [`messUp`][messup] replaces every newline outside comments and preprocessor
directives with a space, then squeezes runs of spaces: the whole construct on one line. It converts
every expected-output fixture into a recovery test for free. Its cost is that it presumes the
formatter's output is a pure function of the AST — see [what does not transfer](#what-does-not-transfer).

### 3. Multi-case fixture files with descriptions

**dart_style** ([`test/README.md`][ds-readme]). One file per construct family, dozens of cases,
each introduced by `>>> Optional description.` and answered by `<<<`. The density is the point:
`test/tall/declaration/field.unit` holds every field-declaration decision in one readable file,
and the descriptions ("Don't split after `covariant`.") are the rule statements.

### 4. The column ruler

**dart_style, prettier.** dart_style's fixture files begin with a header line ending in `|`:

```
40 columns                              |
```

so the wrap column is _visible_ in the fixture, and tests can exercise wrapping without inventing
120-character identifiers. Prettier does the same thing in its snapshots, right-aligning
`printWidth: 80 |` above the code. This is the single cheapest readability win in the survey and
it costs about fifteen lines of harness.

### 5. Options in the fixture

Four spellings, in increasing order of power:

- **rustfmt** — `// rustfmt-brace_style: AlwaysNextLine` as a comment at the top of the input.
- **black** — `# flags: --unstable`, same idea.
- **dart_style** — parenthesized options per _file_ and per _case_: `>>> (indent 4) Description.`
- **ruff** — a sidecar `x.py.options.json` that may hold an **array** of option sets; every set is
  formatted and all results land in one snapshot.

ruff's array form is the one that scales to a large option surface, because the matrix lives with
the fixture instead of in the harness.

### 6. Parallel expectation trees for a config matrix

**ocamlformat, dfmt.** One input tree, N reference trees — ocamlformat keeps
`refs.default/`, `refs.janestreet/`, `refs.ocamlformat/`, `refs.ahrefs/`; dfmt keeps `allman/` and
`otbs/`. Adding a profile is a directory, not a harness change, and reviewing a profile's effect is
`diff -r refs.a refs.b`. The cost is N× the bytes, and a rule change touches N trees.

### 7. Snapshots that embed their own options

**prettier, ruff.** The snapshot file is not just expected output; it is a small document:

```
====================================options=====================================
parsers: ["babel"]
printWidth: 80
                                                       printWidth: 80 (default) |
=====================================input======================================
…
=====================================output=====================================
…
================================================================================
```

Anyone reading the snapshot in a diff sees which settings produced it. This is the closest thing in
the survey to a generated specification, and it is a by-product of the test rather than an extra
artifact.

### 8. Known-failure registries with a "please remove me" assertion

**prettier.** `unstableTests` and `astUnstableTests` list the fixtures that fail idempotence or AST
equality. The harness asserts they _still_ fail:

> `Unstable file '…' is stable now, please remove from the 'unstableTests' list.`

A ratchet that cannot silently loosen. The list is also an honest public inventory of the
formatter's bugs, which is more than most projects publish.

### 9. Differential snapshots against a reference implementation

**ruff.** For each fixture, ruff formats it and compares against black's output. If they agree,
_the snapshot file is deleted_; if they differ, a snapshot is written containing the input, a
unified diff labelled `Black`/`Ruff`, and both outputs. Convergence is visible as files
disappearing from the repository, and every divergence is reviewed as a diff in a PR rather than
tracked as a score.

### 10. Property-based generation

**black.** [`scripts/fuzz.py`][bk-fuzz] uses Hypothesis + Hypothesmith to generate syntactically
valid Python and asserts idempotence under randomized modes (line length 0–200, string
normalization, preview, pyi, magic trailing comma). Derandomized for CI stability. The mode
randomization matters as much as the source generation: it exercises option combinations no
hand-written fixture covers.

### 11. Allocation-failure injection

**zig fmt.** `testTransform` runs each case through `checkAllAllocationFailures`, which re-runs the
formatter failing the allocator at every allocation index in turn. Totality under OOM, exhaustively,
for free. Unusual, cheap in a language with an explicit allocator, and a plausible fit for a
`@nogc`-conscious D formatter.

### 12. Executable documentation

Three variants, ranked:

- **rustfmt** — [`configuration_snippet.rs`][rf-snippet] parses `Configurations.md`, extracts every
  ` ```rust ` block, formats it with the option/value the surrounding headings name, and asserts the
  block is already formatted. Then the coverage gate:

  > `panic!("{name} does not have a configuration guide")`

  Every option must be documented, and every documented example must be true. This is the strongest
  doc↔test link in the survey.

- **black** — `tests/test_docs.py` asserts the preview-feature list in the docs matches the
  `Preview` enum in code, in both directions.

- **prettier/ruff snapshots** — documentation as a by-product (§7), not a checked doc page.

---

## What does not transfer

**`messUp` (§2) is unavailable to a layout-preserving formatter, and so is every technique built on
it.** clang-format and prettier can mangle whitespace freely because their output is a function of
the AST alone: the author's newlines are discarded during parsing, so destroying them changes
nothing. A formatter whose policy is _author's breaks preserved_ — gofmt, zig fmt, dfmt's
keep-breaks mode, and [`sparkles:dmd-fmt`][dmd-fmt-spec]'s layout tier — reads those newlines as
input. Mangling them does not produce a harder instance of the same test; it produces a **different
test with a different expected answer**.

Two replacements, and they are not equivalent:

1. **Perturb only what the formatter promises to erase.** A layout tier that normalizes horizontal
   whitespace, recomputes indentation and collapses blank runs is _defined_ to be invariant under
   exactly those perturbations. So randomize indentation, insert trailing spaces, vary blank-run
   lengths — and assert byte-identical output. This is a true equality oracle, it needs no expected
   file, and it can run over an entire corpus. It is the preserving formatter's `messUp`.
2. **Keep the real mangling as a robustness input, not an oracle.** Collapsing a construct to one
   line is still a valid program, so the formatter must not crash on it, must converge, and must
   pass its verifier — just not produce a predetermined output.

The distinction generalizes: **an equality oracle is only available where the formatter has declared
the perturbed dimension irrelevant.** Every preservation policy is simultaneously a lost oracle and
a gained one.

---

## What a D formatter should take

Ordered by value, and specified in [the testing spec][testing-spec]:

1. **dart_style's multi-case fixture file with descriptions** (§3) plus **the column ruler** (§4) —
   the density and readability baseline.
2. **rustfmt's doc↔test link and its coverage gate** (§12) — with 160 catalogued decisions, "every
   decision has a fixture and a documented example" is the only way the set stays honest.
3. **ruff's option arrays** (§5) and **prettier's option-carrying snapshots** (§7) — one artifact
   per decision, all its variants inside it, which is what makes config-variant documentation
   generable rather than hand-written.
4. **The perturbation oracle** (§"What does not transfer") — free corpus-wide coverage that no
   fixture authoring can match.
5. **prettier's known-failure ratchet** (§8) and **ruff's differential-as-disappearing-snapshots**
   (§9) — the two mechanisms that keep a long-running comparison honest without a score to argue
   about.

Not taken: parallel expectation trees (§6) — with a large option surface the N× duplication is worse
than an option array inside one fixture; allocation-failure injection (§11) — the formatter is not
`@nogc` and the payoff is small.

---

## Sources

Test harnesses, fixture files and CI workflows at the pins in [Method](#method):
[prettier][pr-tests] (`tests/config/format-test/`) ·
[rustfmt][rf-tests] (`src/test/`, `tests/source/`, `tests/target/`) ·
[dart_style][ds-readme] (`test/README.md`, `test/tall/`) ·
[black][bk-tests] (`tests/data/cases/`, `scripts/fuzz.py`, `tests/test_docs.py`) ·
[ruff][ru-tests] (`crates/ruff_python_formatter/tests/fixtures.rs`) ·
[clang-format][cf-tests] (`clang/unittests/Format/`) ·
[gofmt][go-tests] (`src/cmd/gofmt/gofmt_test.go`, `src/go/printer/testdata/`) ·
[ocamlformat][of-tests] (`test/passing/`, `test/projects/`) ·
[zig][zg-tests] (`lib/std/zig/parser_test.zig`) ·
[swift-format][sf-tests] (`Tests/SwiftFormatTests/PrettyPrint/`) ·
[dfmt][dfmt-tests] (`tests/`)

**Related in this tree:** [Verification][verification] · [Prettier's decisions][decisions] ·
[The D proposal][proposal] · [Comparison][comparison]

<!-- References -->

[pr]: https://github.com/prettier/prettier/tree/414e453ae9034866d93eea456b430aa52140371b
[pr-tests]: https://github.com/prettier/prettier/tree/414e453ae9034866d93eea456b430aa52140371b/tests/config/format-test
[rf]: https://github.com/rust-lang/rustfmt/tree/320de2e6d44f3190ea7cc73772e67a2ae86f5e71
[rf-tests]: https://github.com/rust-lang/rustfmt/tree/320de2e6d44f3190ea7cc73772e67a2ae86f5e71/src/test
[rf-snippet]: https://github.com/rust-lang/rustfmt/blob/320de2e6d44f3190ea7cc73772e67a2ae86f5e71/src/test/configuration_snippet.rs
[ds]: https://github.com/dart-lang/dart_style/tree/3b1f30e3a0b568281f72320bcb248a2f0cd8ce79
[ds-readme]: https://github.com/dart-lang/dart_style/blob/3b1f30e3a0b568281f72320bcb248a2f0cd8ce79/test/README.md
[bk]: https://github.com/psf/black/tree/74371e2041a3120a049ced8f1cab0e7a6bc8ecd3
[bk-tests]: https://github.com/psf/black/tree/74371e2041a3120a049ced8f1cab0e7a6bc8ecd3/tests
[bk-fuzz]: https://github.com/psf/black/blob/74371e2041a3120a049ced8f1cab0e7a6bc8ecd3/scripts/fuzz.py
[ru]: https://github.com/astral-sh/ruff/tree/3b067a163e58614fd022c24f1274404a0f386179
[ru-tests]: https://github.com/astral-sh/ruff/blob/3b067a163e58614fd022c24f1274404a0f386179/crates/ruff_python_formatter/tests/fixtures.rs
[llvm]: https://github.com/llvm/llvm-project/tree/73802c2e9d102a4fb646bc039754779fca3ea476
[cf-tests]: https://github.com/llvm/llvm-project/tree/73802c2e9d102a4fb646bc039754779fca3ea476/clang/unittests/Format
[messup]: https://github.com/llvm/llvm-project/blob/73802c2e9d102a4fb646bc039754779fca3ea476/clang/unittests/Format/FormatTestUtils.h
[go]: https://github.com/golang/go/tree/015343854b5d9e2829481df30dbcae2ca6682d25
[go-tests]: https://github.com/golang/go/blob/015343854b5d9e2829481df30dbcae2ca6682d25/src/cmd/gofmt/gofmt_test.go
[of]: https://github.com/ocaml-ppx/ocamlformat/tree/20c4543119c82a51c2f3a9bf81620a7f31fe0e50
[of-tests]: https://github.com/ocaml-ppx/ocamlformat/tree/20c4543119c82a51c2f3a9bf81620a7f31fe0e50/test/passing
[zg]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa
[zg-tests]: https://codeberg.org/ziglang/zig/src/commit/1bcd8d9fe60f72849254b7f74d9ea0f48eae6aaa/lib/std/zig/parser_test.zig
[sf]: https://github.com/swiftlang/swift-format/tree/4be9f3a16d429df692694ab17744b1014b0ac7af
[sf-tests]: https://github.com/swiftlang/swift-format/tree/4be9f3a16d429df692694ab17744b1014b0ac7af/Tests/SwiftFormatTests/PrettyPrint
[dfmt-repo]: https://github.com/dlang-community/dfmt/tree/c65d1c8a9cd2d784ded4cc7517c2cdd42c0c5c76
[dfmt-tests]: https://github.com/dlang-community/dfmt/tree/c65d1c8a9cd2d784ded4cc7517c2cdd42c0c5c76/tests

<!-- Tree-level docs -->

[verification]: ./verification.md
[decisions]: ./prettier-decisions.md
[proposal]: ./dmd-fmt-proposal.md
[comparison]: ./comparison.md
[dmd-fmt-spec]: ../../specs/dmd-fmt/index.md
[testing-spec]: ../../specs/dmd-fmt/testing.md
