# Unicode semantics — case, classes, boundaries, and their cost

What `\w` means, what "case-insensitive" means, and what each costs. The layer
where hue currently has a **defect** rather than a decision: its two in-document
searches disagree about case.

> **Last reviewed:** August 28, 2026.

---

## The field's positions

| Tool                   | Unicode                                    | Rationale                                            |
| ---------------------- | ------------------------------------------ | ---------------------------------------------------- |
| [ripgrep][ripgrep]     | **On by default**; `--no-unicode` opts out | `\w`/`\b` mean what a user expects                   |
| [fff][fff-grep]        | **Off** — `.unicode(false)`                | Code search does not need Unicode classes            |
| [GNU grep][gnu-grep]   | Locale-driven                              | POSIX conformance; `LC_ALL=C` is dramatically faster |
| [ugrep][ugrep]         | On, with encoding conversion               | Breadth                                              |
| [Oniguruma][oniguruma] | Encoding as a parameter object             | Non-Unicode encodings are first-class                |

`[source-verified]`. The split is real and each side is defensible; what is _not_
defensible is having no position, which is where hue is.

## Smart case

An ad-hoc convention, not a formalism: **a pattern containing an uppercase
character is matched case-sensitively; otherwise case-insensitively.** Every
interactive tool implements it, each slightly differently — [fff][fff-grep]
derives it from "any uppercase in the pattern", `sparkles:fuzzy` from "any
uppercase _cased scalar_", which is the more careful formulation.

**The rule must live in exactly one place.** hue's current state is the
cautionary example: the GUI matches case-sensitively with `std.string.indexOf`
and the TUI case-insensitively with an ASCII fold, so the same query answers
differently depending on which canvas is painting. Two implementations produced
two conventions, and a third would entrench it.

## Simple versus full case folding

**Simple** folding is a per-code-point map — the common case, and what
`sparkles:base`'s `AnalysisCase.simpleFold` implements. **Full** folding is
length-changing: `ß` folds to `ss`, `ﬁ` to `fi`. Full folding means a match may
span a different number of source bytes than the pattern, which is why every
engine that offers it treats it as a distinct mode.

`sparkles:fuzzy` already draws exactly this line — `codePath` uses simple folding,
`generalLanguage` uses full — and a content matcher should inherit it rather than
re-decide it.

## Classes and boundaries

`\w`, `\b`, `\p{L}` are the expensive constructs. Under Unicode, `\w` is a large
codepoint set requiring a compressed representation — `std.regex` uses a
`CodepointSet`/`Trie` pair, and [.NET's minterms][dotnet] are the cleverest answer
surveyed, partitioning the alphabet into the classes the pattern actually
distinguishes.

Under ASCII, `\w` is a 256-entry table. That is the whole cost difference, and it
is why `--no-unicode` exists and why fff ships without it.

`\b` is the construct code search most wants and is a **look-behind**: it depends
on the previous character's class as well as the current one. A step function that
carries no previous-character state cannot express it — a concrete gap
[the engine comparison][engine] records against `glob.d`.

## Normalization

NFC/NFD matter for text that has been through different editors. `sparkles:fuzzy`
already normalizes — NFC for `codePath`, NFKC for `generalLanguage` — and no grep
surveyed does any normalization at all: they compare bytes.

For content search that is probably right. A source file's bytes are what the
compiler sees, and a search that silently matched a differently-normalized
sequence would be reporting a position that does not exist in the file as stored.

## The measured cost

[fff][fff-grep] is the one data point in the survey with a number attached:
per-line UTF-8 validation was measured at **~8% of fuzzy grep runtime**, which it
removed by validating the whole file once and using unchecked access per line.
`[literature]` — it is the authors' observation, not this repository's
measurement — but the technique is sound and the primitive already exists here.

## What this catalog concluded

1. **One `smartCase` function**, shared by every mode and both consumers. This is
   the defect-closing item, not a nicety.
2. **Simple folding by default**, following `codePath`; full folding only where
   `generalLanguage` is already chosen.
3. **ASCII-only classes to start** — follow fff's `.unicode(false)`, and revisit
   with evidence from real queries rather than in anticipation.
4. **`\b` is wanted** and needs a previous-character bit in the step function.
5. **No normalization on the content path**, since a reported byte offset must
   correspond to the file as stored.
6. **Validate UTF-8 once per file**, then trust.

## Sources

`[source-verified]` from [ripgrep][ripgrep], [fff-grep][fff-grep],
[gnu-grep][gnu-grep], [ugrep][ugrep], [oniguruma][oniguruma],
[std-regex][std-regex] and [dotnet-nonbacktracking][dotnet]. Sparkles-side facts
from the [baseline][baseline] and `docs/specs/fuzzy/SPEC.md`.

<!-- References -->

[ripgrep]: ./ripgrep.md
[fff-grep]: ./fff-grep.md
[gnu-grep]: ./gnu-grep.md
[ugrep]: ./ugrep.md
[oniguruma]: ./oniguruma.md
[std-regex]: ./std-regex.md
[dotnet]: ./dotnet-nonbacktracking.md
[engine]: ./engine-comparison.md
[baseline]: ./sparkles-baseline.md
