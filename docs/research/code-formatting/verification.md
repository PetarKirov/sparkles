# Verification — How a Formatter Proves It Did Not Break Your Code

A formatter is a program that rewrites every line of your source. The question "how do you know it
didn't change anything?" has a real answer, a literature, and — across the systems surveyed here —
an enormous variance in how seriously it is taken. This page collects the practice, ranks it, and
turns it into the contract [the D proposal][proposal] builds first, before any layout code.

**Last reviewed:** August 15, 2026

---

## The three properties

From [the concepts vocabulary][concepts-idem] and
[de Jonge & Visser's equations][preservation], specialized to a formatter:

| Property                  | Statement                                                  | What it catches                     |
| ------------------------- | ---------------------------------------------------------- | ----------------------------------- |
| **Semantic preservation** | `PARSE(FORMAT(s)) ≡ PARSE(s)`                              | the formatter changed the program   |
| **Idempotence**           | `FORMAT(FORMAT(s)) = FORMAT(s)`                            | the formatter disagrees with itself |
| **Totality**              | `FORMAT(s)` terminates without crashing, for all valid `s` | the formatter panics or hangs       |

De Jonge & Visser's **Correctness** criterion, `PARSE(CONSTRTEXT(TRANSF(PARSE(s)))) = TRANSF(PARSE(s))`,
is the first row with `TRANSF = id`. Their **Preservation** criterion,
`CONSTRTEXT(PARSE(s)) = s`, is too strong for a formatter as a whole — a formatter is _supposed_
to change layout — but it is exactly right, unweakened, for the regions a formatter declines to
touch: [verbatim regions][hatches], `// fmt off` ranges, and everything outside a range-format
request.

---

## The ladder, as practised

Ranked by strength, with who does what:

| Tier | Check                                                                      | Cost                 | Practised by                                                    |
| ---- | -------------------------------------------------------------------------- | -------------------- | --------------------------------------------------------------- |
| 0    | **Nothing** — a test suite and hope                                        | —                    | [dfmt][dfmt] ("Make backups of your files"), [zig fmt][zig-fmt] |
| 1    | **Golden-file corpus**                                                     | cheap                | [gofmt][gofmt] (`testdata/*.golden`), everyone                  |
| 2    | **Idempotence in CI** — format twice, diff                                 | cheap                | [ruff][rust-reimpl], [dart_style][dart-style]                   |
| 3    | **Token equality modulo whitespace** — lex both, compare non-trivia tokens | cheap, needs a lexer | —                                                               |
| 4    | **AST equality on reparse**, in CI                                         | moderate             | [black][long-tail], [prettier][prettier] (`--debug-check`)      |
| 5    | **AST equality at runtime, every file**                                    | expensive            | **[ocamlformat][ocamlformat]**                                  |
| 6    | **+ trivia-specific checks** (comments survived, docstrings did not move)  | expensive            | **[ocamlformat][ocamlformat]** alone                            |
| 7    | **Convergence enforced** — iterate to a fixed point or fail                | expensive            | **[ocamlformat][ocamlformat]** alone                            |

**Nobody is above tier 7, and only one system is above tier 4.** For a class of tool that rewrites
every line of every file, that is a striking distribution.

---

## The reference implementation: ocamlformat

[OCamlFormat's `print_check` loop][ocamlformat] is the only runtime verifier in the survey, and
its design is worth copying whole. Per file, per run:

1. **Reparse** the output.
2. **AST equality** — `Normalize_std_ast.equal std_fg conf std_t.ast std_t_new.ast`; on failure,
   dump both normalized ASTs to `.unequal-ast` files.
3. **A separate docstring check** — re-compare with `~ignore_doc_comments:true`; if _that_ passes
   while step 2 failed, `Normalize_std_ast.moved_docstrings` names the docstrings that moved.
4. **Comment check** — `check_comments ~old ~new_`, plus `check_all_locations`.
5. **Iterate** — recurse until output stabilizes, or fail with
   `Unstable {iteration; prev; next; input_name}` at `max-iters` (default 10).

Three design choices generalize:

- **Normalize before comparing.** A raw AST comparison fails on irrelevant differences
  (positions). The normalization _is_ the specification of what the formatter is allowed to change.
- **Separate the trivia check from the code check.** "The code is identical but a docstring moved"
  is a different bug from "the code changed", with a different severity and a different fix.
  Collapsing them into one boolean loses the information that matters.
- **Failure produces artifacts, not just an exit code.** `.unequal-ast` dumps exist because this
  class of bug is rare and impossible to debug from a diff of formatted output.

## The cheap alternative: ruff's ecosystem harness

[ruff][rust-reimpl] gets most of tiers 2–4 for a fraction of the runtime cost by moving the checks
from the tool into CI, over real projects:

> "The stability checks catch for three common problems: The second formatting pass looks
> different than the first (formatter instability or lack of idempotency), printing invalid syntax
> (e.g. missing parentheses around multiline expressions) and panics (mostly in debug assertions)."
> — [`crates/ruff_python_formatter/CONTRIBUTING.md`][ruff-contributing]

That is idempotence + a weak form of semantic preservation + totality, on an ecosystem corpus,
gating every change. Paired with the **similarity index** (see below) it is the best
cost/assurance ratio in the survey.

## The compatibility metric

For a formatter _replacing_ an incumbent, there is a fourth property nobody else measures:
how much does the output differ from the tool being replaced?

> "It will print the similarity index, the percentage of lines that remains unchanged between
> Black's formatting and our formatting. You could compute it as the number of neutral lines in a
> diff divided by the neutral plus the removed lines. … You should ensure that your changes don't
> decrease the similarity index." — [`CONTRIBUTING.md`][ruff-contributing]

A published definition, a single number, and a CI gate. For a D formatter succeeding
[dfmt][dfmt] this is directly applicable — and it remains useful even where the new formatter
_deliberately_ diverges, because then the index measures the size of the intended divergence
rather than an accident.

---

## What each surveyed system actually does

| System                       | Semantic preservation                             | Idempotence                  | Totality              | Notes                                               |
| ---------------------------- | ------------------------------------------------- | ---------------------------- | --------------------- | --------------------------------------------------- |
| [ocamlformat][ocamlformat]   | **runtime AST equality**                          | **enforced, ≤ `max-iters`**  | errors as bug reports | + docstring-movement and comment checks             |
| [ruff][rust-reimpl]          | CI: output must reparse                           | **CI, ecosystem corpus**     | **CI: no panics**     | + similarity index gate                             |
| [black][long-tail]           | AST-equivalence tests                             | stability tests              | fuzzing               | comment loss is an admitted historical bug class    |
| [prettier][prettier]         | `--debug-check` (opt-in)                          | test suite                   | test suite            | "exact same behavior" stated as requirement #1      |
| [dart_style][dart-style]     | —                                                 | format-twice test            | —                     |                                                     |
| [gofmt][gofmt]               | —                                                 | golden corpus                | golden corpus         |                                                     |
| [rustfmt][rustfmt]           | verbatim fallback preserves unformattable regions | —                            | —                     | `--error-on-unformatted` surfaces silent fallback   |
| [clang-format][clang-format] | —                                                 | —                            | —                     | very large regression suite; two silent search caps |
| [dfmt][dfmt]                 | **none**                                          | **none**                     | **none**              | "Make backups of your files or use source control"  |
| [zig fmt][zig-fmt]           | —                                                 | test suite                   | —                     |                                                     |
| [topiary][topiary]           | refuses `ERROR` trees                             | idempotence in its own tests | —                     | `@leaf` gives byte-exact regions                    |

---

## The contract for a D formatter

[The proposal][proposal] makes this **M1 — before any layout code** — because a verifier built
after a printer is a verifier written to agree with the printer's existing bugs.

**Tier 3 is the sweet spot for D, and it is unusually cheap here.** If the formatter is built on a
token spine ([dfmt's architecture][dfmt], and the proposal's Q-c), then _the verifier already has a
lexer_, and token-equality-modulo-whitespace is a few dozen lines. It catches every class of error
a formatter realistically produces — dropped tokens, mangled literals, lost comments — without a
reparse.

The recommended stack, in build order:

1. **Round-trip the spine** — reconstruct the input byte-for-byte from the token+trivia stream
   before any formatting exists. If this fails, nothing downstream can be trusted.
2. **Token equality modulo whitespace** on every format, in `--check` and in tests.
3. **A separate DDoc check.** D has exactly OCaml's hazard: ddoc comments are semantically
   attached, `dmd-lsp` keeps them alive deliberately, and a formatter that reattaches one has
   silently changed the generated documentation. It deserves its own check and its own error
   message, following [ocamlformat's `moved_docstrings`][ocamlformat].
4. **Idempotence**, iterated to a fixed point with a bounded count; non-convergence is a
   reportable bug, not a curiosity.
5. **Ecosystem corpus in CI** — Phobos, druntime, `sparkles` — with ruff's three stability checks
   and the **similarity index against dfmt**, gated so it cannot decrease unintentionally.
6. **Verbatim-region preservation**, checked: for every `// dfmt off` range, `asm` block, `q{}`
   token string and unformattable construct, assert `FORMAT(s)` reproduces those bytes exactly —
   [de Jonge & Visser's Preservation criterion][preservation], applied where it actually holds.

Tiers 5–7 (runtime AST equality on every file) are worth revisiting only if the token check proves
insufficient in practice; they cost a reparse per file and D's compile-time budget is already the
binding constraint on [the LSP path][baseline].

---

## Sources

- [`ocaml-ppx/ocamlformat`][ocamlformat-repo] @ `20c45431`: `lib/Translation_unit.ml`, `lib/Conf.ml`
- [`astral-sh/ruff`][ruff-repo] @ `3b067a16`: `crates/ruff_python_formatter/CONTRIBUTING.md`
- [`psf/black`][black-repo] @ `74371e20`: `docs/the_black_code_style/index.md`
- [`dlang-community/dfmt`][dfmt-repo] @ `c65d1c8a`: `README.md`
- de Jonge & Visser 2011, §2 — the Correctness and Preservation criteria and the lens laws

**Related deep-dives in this tree:**
[Layout preservation][layout-preserving] · [Concepts][concepts] · [ocamlformat][ocamlformat] ·
[The Rust reimplementation wave][rust-reimpl] · [dfmt][dfmt] · [Comparison][comparison] ·
[The proposal][proposal]

<!-- References -->

[ocamlformat-repo]: https://github.com/ocaml-ppx/ocamlformat/tree/20c4543119c82a51c2f3a9bf81620a7f31fe0e50
[ruff-repo]: https://github.com/astral-sh/ruff/tree/3b067a163e58614fd022c24f1274404a0f386179
[ruff-contributing]: https://github.com/astral-sh/ruff/blob/3b067a163e58614fd022c24f1274404a0f386179/crates/ruff_python_formatter/CONTRIBUTING.md
[black-repo]: https://github.com/psf/black/tree/74371e2041a3120a049ced8f1cab0e7a6bc8ecd3
[dfmt-repo]: https://github.com/dlang-community/dfmt/tree/c65d1c8a9cd2d784ded4cc7517c2cdd42c0c5c76
[layout-preserving]: ./theory/layout-preserving.md
[preservation]: ./theory/layout-preserving.md#preservation-as-a-pair-of-equations
[concepts]: ./concepts.md
[concepts-idem]: ./concepts.md#7-idempotence-stability-convergence
[hatches]: ./concepts.md#9-verbatim-regions-and-escape-hatches
[comparison]: ./comparison.md
[baseline]: ./dmd-lsp-baseline.md
[proposal]: ./dmd-fmt-proposal.md
[ocamlformat]: ./ocamlformat.md
[rust-reimpl]: ./rust-reimplementations.md
[long-tail]: ./long-tail.md
[prettier]: ./prettier.md
[dart-style]: ./dart-style.md
[gofmt]: ./gofmt.md
[rustfmt]: ./rustfmt.md
[clang-format]: ./clang-format.md
[dfmt]: ./dfmt.md
[zig-fmt]: ./zig-fmt.md
[topiary]: ./topiary.md
