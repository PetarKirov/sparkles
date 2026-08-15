# Prettier (JavaScript / TypeScript / CSS / …)

The most widely deployed formatter in existence, and a direct implementation of
[Lindig's strict transcription of Wadler's algebra][combinators] — `MODE_FLAT`/`MODE_BREAK` over
a worklist, exactly as published in 2000. Its engine is small (~2,400 lines) and its _language
rules_ are large (~10,800 lines for JS alone, plus 1,255 lines of comment placement), which is
the clearest available demonstration of where the work in a real formatter actually lives.

|                     |                                                                                                 |
| ------------------- | ----------------------------------------------------------------------------------------------- |
| **Languages**       | JS, TS, JSX, Flow, CSS/SCSS/Less, HTML, Vue, Angular, Markdown, YAML, GraphQL, Handlebars, JSON |
| **License**         | MIT                                                                                             |
| **Repository**      | [`prettier/prettier`][repo] @ `414e453a` (`3.9.6-155-g…`, 2026-08-13)                           |
| **Engine**          | `src/document/` (2,418) — `printer/printer.js` (578), `builders/` (15 files), `utilities/`      |
| **Driver**          | `src/main/` (2,131) — `core.js`, `ast-to-doc.js`, `range.js`, `comments/attach.js` (393)        |
| **JS rules**        | `src/language-js/print/` (10,820) + `comments/handle-comments.js` (1,255)                       |
| **Category**        | AST + attached comments · combinator group/flat (greedy) · opinionated                          |
| **Layout paradigm** | [combinator `group`/flat][combinators]                                                          |

---

## Overview

### What it solves

Prettier's stated contract is narrow and absolute:

> "The first requirement of Prettier is to output valid code that has the exact same behavior as
> before formatting." — [`docs/rationale.md`][rationale]

Everything else is subordinate to that, including the layout. The product claim is the _removal
of choice_: reprint from the AST, discard the author's formatting, and end the debate. In
practice the "discard" is qualified in two documented places (below), and those qualifications
are the most interesting part of the design.

### Design philosophy

Prettier names its lineage precisely:

> "This printer is a fork of [recast](https://github.com/benjamn/recast)'s printer with its
> algorithm replaced by the one described by Wadler in 'A prettier printer'."
> — [`docs/technical-details.md`][tech-details]

> "The basic idea is that the printer takes an AST and returns an intermediate representation of
> the output, and the printer uses that to generate a string. The advantage is that the printer
> can 'measure' the IR and see if the output is going to fit on a line, and break if not."
> — [`docs/technical-details.md`][tech-details]

What it _implements_, because JavaScript is strict, is [Lindig 2000][combinators]: the mode is an
explicit tag rather than a lazily-chosen branch.

```js
const MODE_BREAK = Symbol('MODE_BREAK');
const MODE_FLAT = Symbol('MODE_FLAT');
```

and the fit test takes the rest of the worklist, exactly as Lindig's `fits w ((i,Flat,x)::z)`:

```js
function fits(next, restCommands, remainingWidth, hasLineSuffix, groupModeMap, mustBeFlat)
```

— [`src/document/printer/printer.js`][printer]

---

## How it works

### The `Doc` builders

Fifteen builders in `src/document/builders/`: `group`, `fill`, `indent`, `align`, `line`,
`ifBreak`, `indentIfBreak`, `breakParent`, `lineSuffix`, `lineSuffixBoundary`, `join`, `label`,
`trim`, `cursor`. The [cross-naming table][concepts-ir] maps them to Oppen's and Box's
vocabularies; three deserve comment here because they are prettier's genuine _additions_ beyond
the published algebra:

**`fill`** is [Oppen's inconsistent breaking][oppen-cons], and prettier's own documentation is the
clearest statement of the distinction in any source read for this survey:

> "This is an alternative type of group which behaves like text layout: it's going to add a break
> whenever the next element doesn't fit in the line anymore. The difference with `group` is that
> it's not going to break all the separators, just the ones that are at the end of lines."
> — [`commands.md`][commands]

**`conditionalGroup`** escapes the two-candidate limit of `group = flatten x <|> x` by taking an
ordered list of alternatives, "going from the least expanded (most flattened) representation
first to the most expanded". The docs attach a warning that is the practical restatement of
[the optimality complexity results][optimality]:

> "This should be used as **last resort** as it triggers an exponential complexity when nested."
> — [`commands.md`][commands]

**`propagateBreaks`** is a pre-pass, not a builder: it walks the finished `Doc` and marks any
group containing a `breakParent` as `break: true`, so `fits` is never called on a group already
known to break. This is prettier's main performance mitigation for repeated measurement.

### Comment attachment: where the real work is

`src/main/comments/attach.js` (393 lines) implements the generic algorithm — classify each
comment as **own-line**, **end-of-line**, or **remaining**, find the enclosing node, and pick a
preceding/following/enclosing owner. `src/language-js/comments/handle-comments.js` is **1,255
lines** of JavaScript-specific overrides on top of that.

That ratio is the finding. Prettier's whole layout engine is 578 lines; its JavaScript comment
placement is more than twice that. [The attachment problem][attachment] is not a footnote in a
reprinting formatter — it is the single largest module. A D formatter that reprints from an AST
should budget accordingly; one built on a token spine, like [dfmt][dfmt], does not pay this cost
at all.

### The two places the author's formatting survives

Prettier is not purely reprinting, and says so:

> "It turns out that empty lines are very hard to automatically generate. The approach that
> Prettier takes is to preserve empty lines the way they were in the original source code."
> — [`docs/rationale.md`][rationale]

and the object-expansion heuristic — prettier "keeps objects multi-line if there's a newline
between the `{` and the first key in the original source code", now controlled by the
`objectWrap` option. Both are [author's-breaks-preserved][concepts-break] signals smuggled into
an otherwise reprinting design, for the same reason [black added the magic trailing
comma][concepts-break]: some grouping intent is not recoverable from the tree.

---

## 1. Input model & fidelity

**AST plus a comment array**, attached during `ast-to-doc.js`. Not full-fidelity: whitespace is
not in the tree, which is why blank lines need the explicit preservation rule above.

**Round-trip guarantee:** semantic, not textual. `--debug-check` reparses the output and compares
ASTs — the [Correctness criterion][preservation] — but it is a debugging flag, not a default.

**Behaviour on unparseable input:** **refuses**, and does so strictly. Prettier is the
strict-error end of the axis where [clang-format][clang-format] is the lenient end.

## 2. Layout IR & break decision

**Paradigm: [combinator group/flat, greedy][combinators].** Width policy is a hard `printWidth`
(default 80), described in the docs as a guideline rather than a hard limit — the engine will
overflow rather than produce an invalid layout.

## 3. Alignment, indentation & vertical rhythm

`indent` (relative) and `align` (to a column) are separate builders; `indent.js` (184 lines)
implements the indentation state machine including dedent-to-root and tab/space widths.
Blank-line runs are collapsed to at most one. Width is measured with a `getStringWidth` that
accounts for wide characters — a genuine grapheme/width model, unlike [dfmt][dfmt]'s byte count.

## 4. Comments, trivia & preservation

Covered above: 393 lines generic + 1,255 lines JS-specific. `lineSuffix` is the builder that
makes trailing comments possible — deferred text emitted at the next newline, which is the
[`Doc`][combinators] answer to the problem [Oppen solved with a lied-about token length][oppen].

Escape hatch: `// prettier-ignore`, which "will exclude the next node in the abstract syntax tree
from formatting" ([`docs/ignore.md`][ignore]) — **node-scoped**, not a line range, which is the
cleaner design and is only possible because prettier works on a tree.

## 5. Configurability, opinionation & config discovery

Deliberately small: `printWidth`, `tabWidth`, `useTabs`, `semi`, `singleQuote`, `trailingComma`,
`bracketSpacing`, `arrowParens`, `objectWrap`, and a handful more. The
[option-philosophy][option-philosophy] document argues against growth. Discovery is
`.prettierrc` and friends, walked up from the file.

## 6. Integration surface & output contract

**Whole document**, but with two genuine extras:

- **Range formatting** — `src/main/range.js` (269 lines) implements `rangeStart`/`rangeEnd` by
  finding the enclosing node that covers the range and formatting only that.
- **Cursor preservation** — a `cursor` builder and `cursorOffset` option exist, so an editor can
  map the caret through a reformat.

No `TextEdit[]` output; editors diff the result themselves.

---

## Strengths

- **Correct by construction on layout choice.** The `group` invariant means a layout decision can
  never change content — a very strong safety property.
- **Small, comprehensible engine.** 578 lines of printer; anyone can read it.
- **The `Doc` IR is genuinely reusable** across 13 language plugins, which is the strongest
  practical evidence for the [combinator][combinators] interface.
- **Semantic preservation is stated first** and checkable with `--debug-check`.
- **Range formatting and cursor preservation exist**, unusually for a document-output formatter.
- **Ecosystem proof**: the option-minimalism argument won.

## Weaknesses

- **Greedy.** Subject to [Bernardy's counterexample][optimality]; `conditionalGroup` is the patch
  and carries an exponential-complexity warning in its own docs.
- **Comment placement is the dominant cost** — 1,255 lines for one language, and still a frequent
  source of bug reports.
- **Refuses invalid input**, ruling out format-while-typing.
- **The "no configuration" position is partly fiction** — blank lines and object expansion _are_
  read from the source, because they had to be.
- **No edit output**, so minimal-diff integration is left to the caller.

---

## Key design decisions and trade-offs

| Decision                                                    | Rationale                                                       | Trade-off                                                                                       |
| ----------------------------------------------------------- | --------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Reprint from the **AST** via a `Doc` IR                     | One engine, 13 languages; layout choice cannot alter content    | Everything the tree does not carry — comments, blank lines, grouping intent — must be recovered |
| Implement **Lindig's strict form** of Wadler                | JavaScript is strict; the lazy formulation would be exponential | The mode must be threaded manually through every builder                                        |
| Add **`conditionalGroup`** for N-way choice                 | Two candidates are not enough for real JS layouts               | Exponential when nested — documented as a last resort; needs `shouldRemeasure`                  |
| Add **`propagateBreaks`** as a pre-pass                     | Avoids measuring groups already known to break                  | An extra full traversal; correctness depends on `breakParent` being placed correctly            |
| **Preserve blank lines** from the source                    | "empty lines are very hard to automatically generate"           | Breaks the pure-reprint story; output depends on input formatting after all                     |
| **Preserve object expansion** when the source had a newline | Recovers grouping intent the AST does not carry                 | A second input-dependent rule; needed an option (`objectWrap`) once users disagreed             |
| **Node-scoped `// prettier-ignore`**                        | Precise; no start/end pairing to get wrong                      | Requires a tree — unavailable to a token-stream formatter                                       |
| **Strict** on parse errors                                  | Never emit code you did not fully understand                    | Cannot format a buffer mid-edit                                                                 |
| **Few options, by policy**                                  | The product _is_ the absence of debate                          | Projects with existing conventions cannot adopt incrementally                                   |

---

## What a D formatter should take

**Take:** the `Doc` builder vocabulary essentially wholesale — it is the best-tested layout API in
existence, and [`signature_layout.d`][sig-layout] already implements a hand-rolled subset of it;
`lineSuffix` for trailing comments; `propagateBreaks` as a cheap optimization; node-scoped ignore
directives if the architecture permits; range formatting designed in rather than retrofitted.

**Note as a warning:** the 1,255-line comment module is the cost of reprinting from a tree. It is
the single strongest argument for [dfmt][dfmt]'s token-spine architecture and it is quantified
here rather than asserted.

---

## Sources

- [`prettier/prettier`][repo] @ `414e453ae9034866d93eea456b430aa52140371b`:
  `src/document/printer/printer.js`, `src/document/builders/*`, `src/document/utilities/index.js`,
  `src/main/{core,ast-to-doc,range}.js`, `src/main/comments/attach.js`,
  `src/language-js/comments/handle-comments.js`
- [`commands.md`][commands] — the `Doc` builder reference
- [`docs/technical-details.md`][tech-details] · [`docs/rationale.md`][rationale] ·
  [`docs/option-philosophy.md`][option-philosophy] · [`docs/ignore.md`][ignore]

**Related deep-dives in this tree:**
[Combinators][combinators] · [Oppen][oppen] · [Optimality][optimality] · [Concepts][concepts] ·
[dfmt][dfmt] · [clang-format][clang-format] · [Comparison][comparison]

<!-- References -->

<!-- Source trees -->

[repo]: https://github.com/prettier/prettier/tree/414e453ae9034866d93eea456b430aa52140371b
[printer]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/document/printer/printer.js
[commands]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/commands.md
[tech-details]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/docs/technical-details.md
[rationale]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/docs/rationale.md
[option-philosophy]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/docs/option-philosophy.md
[ignore]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/docs/ignore.md
[sig-layout]: https://github.com/PetarKirov/sparkles/blob/557ccfc11709507ecfbd50991b5afe1dbffd4686/libs/twoslash/src/sparkles/twoslash/signature_layout.d

<!-- Theory docs -->

[oppen]: ./theory/oppen.md
[oppen-cons]: ./theory/oppen.md#consistent-vs-inconsistent-breaking
[combinators]: ./theory/combinators.md
[optimality]: ./theory/optimality.md
[preservation]: ./theory/layout-preserving.md#preservation-as-a-pair-of-equations

<!-- Tree-level docs -->

[concepts]: ./concepts.md
[concepts-ir]: ./concepts.md#the-layout-ir-cross-naming-table
[concepts-break]: ./concepts.md#5-line-breaking-vocabulary
[attachment]: ./concepts.md#2-trivia-and-the-attachment-problem
[comparison]: ./comparison.md

<!-- System deep-dives -->

[dfmt]: ./dfmt.md
[clang-format]: ./clang-format.md
