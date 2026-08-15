# OCamlFormat (OCaml)

Included not for its layout algorithm but for its **verification discipline**, which is the most
rigorous in this survey by a wide margin. OCamlFormat does not trust itself: after formatting it
**reparses the output, normalizes both ASTs and compares them**, separately checks that comments
and docstrings survived and did not move, and then **formats again until the output stops
changing** — reporting `Unstable` as an error if it has not converged within `max-iters`. Where
every other formatter here treats correctness as a test-suite property, OCamlFormat treats it as
a runtime precondition.

|                     |                                                                                                                  |
| ------------------- | ---------------------------------------------------------------------------------------------------------------- |
| **Language**        | OCaml                                                                                                            |
| **License**         | MIT                                                                                                              |
| **Repository**      | [`ocaml-ppx/ocamlformat`][repo] @ `20c45431` (2026-07-30)                                                        |
| **Verification**    | `lib/Translation_unit.ml` — the `print_check` loop, `Normalize_std_ast`, `check_comments`, `check_all_locations` |
| **Category**        | AST + comment attachment · combinator · **self-verifying**                                                       |
| **Layout paradigm** | [combinator][combinators] (`Fmt` over OCaml's `Format`)                                                          |

---

## Overview

### What it solves

OCaml has a specific hazard that forced the issue: `(** … *)` docstrings are **semantically
attached** — the compiler and `odoc` decide which declaration a docstring documents — so a
formatter that moves one has changed the program's documentation, silently. OCamlFormat's
response is to refuse rather than guess:

> "(Warning 50) This file contains a documentation comment (\*\* ... \*) that the OCaml compiler
> does not know how to attach to the AST. OCamlformat does not support these cases. … If you'd
> like to disable this check and let ocamlformat make a choice (though it might not be consistent
> with the ocaml compilers and odoc), you can set the `--no-comment-check` option."
> — [`lib/Translation_unit.ml`][tu]

Note what that message concedes: the formatter _could_ make a choice, and the choice might
disagree with the compiler. Rather than ship the disagreement, it errors and offers an opt-out.
This is [the attachment problem][attachment] met head-on, with the only fully honest answer in
the survey.

### The verification loop

`Translation_unit.ml`'s `print_check` is a recursive function that formats, checks, and repeats:

1. **Reparse** the formatted output.
2. **AST equality** — `Normalize_std_ast.equal std_fg conf std_t.ast std_t_new.ast`. On failure
   it dumps both normalized ASTs to `.unequal-ast` files for diffing.
3. **Docstring check** — a _second_ comparison with `~ignore_doc_comments:true`, and if that one
   passes while the first failed, `Normalize_std_ast.moved_docstrings` reports precisely which
   docstrings moved. Separating "the code changed" from "a docstring moved" is a distinction no
   other formatter draws.
4. **Comment check** — `check_comments conf cmts_t ~old ~new_` verifies comments survived;
   `check_all_locations` audits positions.
5. **Stability** — if the output differs from the input to this iteration, recurse. If
   `i >= conf.opr_opts.max_iters.v` (default **10**), return
   `Unstable {iteration; prev; next; input_name}`.

The user-visible failures are correspondingly precise:

> `"%s: %S was not already formatted. ([max-iters = 1])"`
> `"%s: Cannot process %S.\n  Please report this bug at …"` — [`lib/Translation_unit.ml`][tu]

The first is the `--check` path; the second means the formatter failed to converge and says so as
a bug report rather than emitting something.

This is [de Jonge & Visser's Correctness criterion][preservation] —
`PARSE(FORMAT(s)) = PARSE(s)` — enforced at runtime, plus an idempotence check on top, plus two
trivia-specific checks the equations do not cover.

---

## 1. Input model & fidelity

**AST (`Parsetree`) with attached comments.** Doc comments are semantically significant, which is
why they get their own check. Behaviour on unparseable input: refuses.

**Round-trip:** the strongest guarantee here — not "we tested it", but "we verified it for this
file, on this run".

## 2. Layout IR & break decision

**Paradigm: [combinator][combinators]**, built over OCaml's stdlib `Format` (itself
[Oppen][oppen]-derived) via an `Fmt` layer. Hard `margin`.

## 3. Alignment, indentation & vertical rhythm

Conventional; `ocp-indent` compatibility is an explicit concern.

## 4. Comments, trivia & preservation

The defining dimension. Comment placement is checked, docstring movement is detected and named,
and `--no-comment-check` is the documented escape.

## 5. Configurability, opinionation & config discovery

Large option surface plus **profiles** (`conventional`, `default`, `janestreet`, `ocamlformat`),
selected in `.ocamlformat`. `max-iters` is itself an option (default 10).

## 6. Integration surface & output contract

Whole document; `--check`; no range formatting or cursor.

---

## Strengths

- **Runtime AST-equivalence verification** — unique in this survey.
- **Separate docstring-movement detection**, with the moved docstrings named.
- **Convergence enforced**, with a bounded iteration count and a clear error.
- **Refuses ambiguous docstring attachment** instead of guessing.
- **Failure artifacts** (`.unequal-ast` dumps) designed for debugging.

## Weaknesses

- **Slow** — formatting runs up to `max-iters` times plus normalization and comparison.
- **Refuses input it could format**, which users experience as friction.
- **Large option surface** with profiles that fragment style.
- **No range formatting or cursor.**
- Layout quality is conventional; nothing here advances [the theory][theory].

---

## Key design decisions and trade-offs

| Decision                                               | Rationale                                                                     | Trade-off                                                              |
| ------------------------------------------------------ | ----------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| **Verify AST equality at runtime**                     | A formatter that changes meaning is worse than no formatter                   | Reparse + normalize + compare on every file                            |
| **A separate docstring-movement check**                | OCaml docstrings are semantically attached; moving one is a silent regression | A second full comparison pass                                          |
| **Iterate to a fixed point** (`max-iters`, default 10) | Idempotence is a property users depend on and formatters routinely violate    | Up to 10× the work; and non-convergence becomes a hard failure         |
| **Error on ambiguous docstring attachment**            | Better to refuse than to disagree with the compiler                           | Files that other tools accept are rejected; needs `--no-comment-check` |
| **Dump `.unequal-ast` artifacts on failure**           | Makes a rare, hard bug diagnosable                                            | Extra machinery only ever used when something is already wrong         |
| **Profiles** over raw option sets                      | Communities want a name, not 60 flags                                         | Style fragments along profile lines                                    |

---

## What a D formatter should take

**Take the whole verification design.** It is the strongest single import available from this
survey and it is cheap relative to the printer:

- `PARSE(FORMAT(s)) = PARSE(s)` on every run in CI, `--check` in the hot path.
- A **separate ddoc check**. D has exactly OCaml's hazard: DDoc comments are semantically attached
  (`dmd-lsp` overrides `doDocComment` to keep them alive), and a formatter that reattaches one has
  silently changed the generated documentation. This deserves its own check and its own error,
  not a line in a diff.
- **Iterate to a fixed point** with a bounded count, and treat non-convergence as a reportable
  bug rather than a curiosity.

This is the content of [the proposal][proposal]'s Q-d and M1 — the verifier is built _before_ the
layout engine, so every subsequent milestone is developed against a working oracle.

---

## Sources

- [`ocaml-ppx/ocamlformat`][repo] @ `20c4543119c82a51c2f3a9bf81620a7f31fe0e50`:
  `lib/Translation_unit.ml` (the `print_check` loop, error messages, `Unstable`), `lib/Conf.ml`
  (`max-iters`, default 10)

**Related deep-dives in this tree:**
[Verification][verification] · [Layout preservation][layout-preserving] · [Concepts][concepts] ·
[Combinators][combinators] · [The proposal][proposal]

<!-- References -->

[repo]: https://github.com/ocaml-ppx/ocamlformat/tree/20c4543119c82a51c2f3a9bf81620a7f31fe0e50
[tu]: https://github.com/ocaml-ppx/ocamlformat/blob/20c4543119c82a51c2f3a9bf81620a7f31fe0e50/lib/Translation_unit.ml
[theory]: ./theory/index.md
[oppen]: ./theory/oppen.md
[combinators]: ./theory/combinators.md
[layout-preserving]: ./theory/layout-preserving.md
[preservation]: ./theory/layout-preserving.md#preservation-as-a-pair-of-equations
[concepts]: ./concepts.md
[attachment]: ./concepts.md#2-trivia-and-the-attachment-problem
[verification]: ./verification.md
[proposal]: ./dmd-fmt-proposal.md
