# Prettier's decisions, extracted

A **mechanical inventory** of every formatting decision prettier actually makes, read off its
printer sources rather than its documentation, and scored for a D formatter. The
[prettier deep-dive][prettier] answers _how the engine works_; this page answers _what the engine
decides_, one row at a time, so each row can be argued about on its own.

**Last reviewed:** August 19, 2026

The extraction is the input to tuning [`sparkles:dmd-fmt`][dmd-fmt-spec]. Each row is scored
against dmd-fmt's **two-tier scope**, fixed in [the decision record][dmd-fmt-spec] (`D9`):

- **The layout tier** reformats without touching the token stream, and is always on. It is the
  v1 policy — author's breaks preserved, indentation recomputed, whitespace normalized.
- **The rewrite tier** may add, remove or respell tokens. Trailing commas are on by default,
  because inserting one is what lets a long signature or call break one-per-line at all; every
  other rewrite is **opt-in**, off unless the project asks for it.

That split is the filter this page applies, and it replaces the reading this survey started from —
which treated any token change as out of scope, and therefore scored a sixth of prettier's
decisions as unreachable. They are reachable. They are simply not free, and the price is paid per
rule.

> [!IMPORTANT]
> **The headline: rewriting is the cheap part; _verifying_ a rewrite is the whole cost.** The M1
> verifier's tier-3 check is token equality modulo whitespace — it is what makes the layout tier
> provably safe, and **every rewrite breaks it by construction**. A rewrite rule is therefore not
> done when it produces the right bytes; it is done when it ships with the check that proves it did
> not change meaning — and those checks do not generalize. Paren removal needs precedence. Import
> sorting needs to know no import in the group has an import-order side effect. Declaration
> reordering needs to know nothing reflects over declaration order, which in D means
> `__traits(allMembers)`, `static foreach` over it, and any string mixin built from it. So the rule
> this page ends up recommending is: **each opt-in rewrite carries its own verifier, or it does not
> ship** — which is also why shipping them one at a time, off by default, is the right shape.
>
> Two findings survive the scope change intact. Prettier's preservation surface is larger than
> advertised — six independent source hints read the original text — and the expensive _layout_
> decisions cluster in exactly three printers, which are the three shapes a D reader meets
> constantly.

---

## Method

Every row cites the source that implements it, at a pinned revision. Nothing here is taken from
prettier's docs unless the docs are the only statement of the rule (marked _rationale_), and
several rows contradict the folk understanding of what prettier does.

- **Tree:** [`prettier/prettier`][repo] @ `414e453ae9034866d93eea456b430aa52140371b` (2026-08-13).
- **Read in full:** `src/language-js/print/{assignment,binaryish,call-arguments,member-chain,object,array,block,statement-sequence,if-statement,clause,switch-statement,return-statement,expression-statement,variable-declaration,try-statement,for-statement,while-statement,do-while-statement,for-x-statement,function,function-parameters,arrow-function,class,class-body,decorators,module,comment,member,call-expression,key,literal,miscellaneous,type-parameters,union-type,template-literal,type-alias,enum,mapped-type,type-annotation,ignored}.js`,
  `src/language-js/{options.js,utilities/{should-flatten,is-simple-call-argument,is-lone-short-argument}.js}`,
  `src/{main/core-options.evaluate.js,common/common-options.evaluate.js,utilities/{print-string,print-number,make-string}.js}`,
  `docs/rationale.md`, `commands.md`.
- **Excluded:** JSX, Flow, Angular/Vue/HTML-binding, and the parts of the TypeScript type layer
  with no D construct (mapped types; unions and intersections as a type algebra). Template
  literals and the type-level printers **are** included, mapped onto D's interpolated expression
  sequences ([IES][ies]) and its template parameters, constraints and `alias` declarations — §I.

**A "decision" is a rule that can change bytes of output.** A helper that only computes a predicate
is folded into the row it serves. Where prettier implements one idea in three printers (the
"break a delimited list" shape), it is one row with the printers listed.

### Legend

| Verdict     | Meaning                                                                        |
| ----------- | ------------------------------------------------------------------------------ |
| **Adopt**   | Applies to D; implement it, on by default.                                     |
| **Adapt**   | The idea transfers, the trigger or shape must change for D.                    |
| **Opt-in**  | A rewrite worth having, shipped **off by default**, with its own verifier.     |
| **Have**    | dmd-fmt already decides this, the same way or deliberately differently.        |
| **Oracle**  | Reachable only with AST facts the `oracle.d` offset arrays do not yet collect. |
| **Codemod** | Real, but a [codemod][codemods] rather than a formatter rule — it needs types. |
| **Reject**  | Decided against for D.                                                         |
| **N/A**     | No D construct.                                                                |

---

## A. The configurable surface

What prettier lets you change is a decision in itself — its
[option philosophy][option-philosophy] is that an option exists only where the team could not pick
a winner. Eighteen format-affecting options, in a formatter that markets itself as opinionated.

| #   | Decision                                                                                                                     | Source              | Verdict    |
| --- | ---------------------------------------------------------------------------------------------------------------------------- | ------------------- | ---------- |
| P1  | `printWidth` defaults to **80**, and is explicitly a _target_, not a cap — prettier emits longer lines on purpose (P67, P77) | [core-options][opt] | **Have**   |
| P2  | `tabWidth` defaults to **2**; `useTabs` defaults to false                                                                    | [core-options][opt] | **Have**   |
| P3  | `endOfLine` defaults to `lf`; `auto` infers from the line ending after the file's first line                                 | [core-options][opt] | **Adapt**  |
| P4  | `semi` (default on) — when off, a leading `;` is emitted on lines that would otherwise continue the previous statement       | [js-options][jsopt] | **N/A**    |
| P5  | `singleQuote` (default off) only breaks ties; escape count wins first (P108)                                                 | [js-options][jsopt] | **Opt-in** |
| P6  | `quoteProps: as-needed \| consistent \| preserve` — quoting of object keys                                                   | [key.js][key]       | **N/A**    |
| P7  | `trailingComma` defaults to **`all`**: prettier _writes_ trailing commas whenever a list breaks                              | [js-options][jsopt] | **Adopt**  |
| P8  | `bracketSpacing` (default on) — `{ a }` vs `{a}`; the sole horizontal-spacing option                                         | [common-opts][copt] | **Adapt**  |
| P9  | `arrowParens` defaults to `always`: `(x) => x`, not `x => x`                                                                 | [js-options][jsopt] | **Adapt**  |
| P10 | `objectWrap: preserve \| collapse` — makes the object source-hint (P17) switchable, added because it is a known wart         | [common-opts][copt] | **Adapt**  |
| P11 | `experimentalOperatorPosition: end \| start` — operator at the end of the broken line, or the start of the next              | [binaryish][bin]    | **Adapt**  |
| P12 | `experimentalTernaries` — an entire second ternary printer, opt-in, because the first one is disliked                        | [ternary][tern]     | **Adapt**  |
| P13 | `requirePragma` / `insertPragma` / `checkIgnorePragma` — file-level opt-in/opt-out via a docblock marker                     | [core-options][opt] | **Adapt**  |
| P14 | `rangeStart`/`rangeEnd` — format a byte range, extended outward to whole statements                                          | [core-options][opt] | **Adopt**  |
| P15 | `cursorOffset` — report where a cursor lands after formatting                                                                | [core-options][opt] | **Adopt**  |
| P16 | `embeddedLanguageFormatting: auto \| off` — format code embedded in strings/templates                                        | [core-options][opt] | **Adapt**  |

> **For D.** P1–P3 and P8 are already `FormatConfig`. On P2, prettier's `tabWidth: 2` is the one
> default D simply does not take — [DStyle][dstyle] fixes four columns per level, and
> `FormatConfig.indentSize` already does. P14/P15 are the editor contract dmd-fmt owes an LSP and
> does not have; both are cheap on a token spine with exact byte spans and expensive on an AST,
> which is an argument for the spine. P16 is the `q{ … }` / `mixin` question — see P154.
>
> The options that are _rewrites_ now land as D options rather than exclusions: P5/P108 become the
> literal-form option (P154), P7 the default-on trailing comma, P9 the lambda-paren option
> (`preserve` default, `avoid` matching DStyle's own `filter!(a => a == 42)`, `always`), P6 alone
> stays N/A because D has no quotable object keys. Note how much of prettier's _option_ surface is
> option-shaped only because the underlying decision is a rewrite: seven of its eighteen.

---

## B. The preservation policy — what prettier keeps from the author

The most under-advertised part of prettier. A formatter that "reprints from the AST" in fact reads
the original text in at least six places to decide layout, and its docs apologize for four of them.

| #   | Decision                                                                                                                                                                     | Source                      | Verdict    |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------- | ---------- |
| P17 | **The object source hint:** an object stays exploded iff the author put a newline between `{` and the first key. Long one-liners expand; short multi-liners never collapse   | [object.js][obj]            | **Have**   |
| P18 | Prettier documents P17 as _a workaround, not a feature_, and calls it non-reversible formatting it wants to remove                                                           | [rationale][rationale]      | **Have**   |
| P19 | **Blank lines are preserved, then collapsed to one.** A run of empty lines between statements becomes exactly one                                                            | [statement-sequence][seq]   | **Have**   |
| P20 | Blank lines at the start and end of a block are deleted                                                                                                                      | [block.js][block]           | **Have**   |
| P21 | A file always ends with exactly one newline                                                                                                                                  | [block.js][block]           | **Have**   |
| P22 | **The decorator source hint:** decorators written inline stay inline; decorators written on their own line stay there — detected by "is there a newline after any decorator" | [decorators.js][dec]        | **Adopt**  |
| P23 | …except on classes, which always get their decorators on their own line                                                                                                      | [decorators.js][dec]        | **Adapt**  |
| P24 | **The interpolation source hint:** a `${…}` breaks only if the author already broke it; otherwise the template stays on one line at any length                               | [rationale][rationale]      | **Adapt**  |
| P25 | A blank line _inside_ an argument list forces the whole list to explode, one argument per line                                                                               | [call-arguments][args]      | **Adopt**  |
| P26 | A blank line after an array element / object property / class member is preserved as a hardline inside the broken list                                                       | [array][arr], [object][obj] | **Adopt**  |
| P27 | A blank line after a call in a member chain is preserved, and forces the chain to break                                                                                      | [member-chain][chain]       | **Adopt**  |
| P28 | Comment content is never reflowed or rewrapped — "we can't know how to format it"                                                                                            | [rationale][rationale]      | **Opt-in** |
| P29 | **Nothing is ever sorted or moved** — not imports, not object keys, not class members. Sorting is a transform, and unsafe                                                    | [rationale][rationale]      | **Opt-in** |
| P30 | Strings are never converted between quote styles and templates, never split across lines with `+`                                                                            | [rationale][rationale]      | **Opt-in** |
| P31 | Optional `{}` / `return` / `?:`↔`if` are never added or removed                                                                                                              | [rationale][rationale]      | **Have**   |

> **For D.** P17–P18 is the row to be clear-eyed about. Prettier's own team calls its object source
> hint a wart it has failed to remove, and it is _the same mechanism_ dmd-fmt makes policy — but the
> difference in kind is real, and it is why dmd-fmt keeps it deliberately rather than apologetically:
> in prettier the hint is **one construct's exception** inside a reprinting formatter, so it reads as
> an inconsistency; in dmd-fmt it is **the rule everywhere**, so a reader never has to learn which
> constructs listen to them and which do not. Reversibility, prettier's stated objection, is a
> property of the whole tier here, not of one node type.
>
> P22/P23 map exactly onto D's UDAs and their placement before aggregates. P24 maps onto
> [IES][ies] — `i"…$(expr)…"` — and is developed in §I. P25–P27 are real, small, and adoptable now:
> the spine already knows where blank lines are. P28–P30 are no longer statements of scope but
> **the three opt-in rewrite families**: DDoc reflow (§G), reordering (P147), and literal-form
> selection (P154).

---

## C. Vertical structure — blocks and statements

| #   | Decision                                                                                                                                                                                                  | Source                    | Verdict   |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------- | --------- |
| P32 | Statements in a block are separated by a hardline; the block never collapses onto one line at any width                                                                                                   | [statement-sequence][seq] | **Have**  |
| P33 | A non-empty block body is `{` + indent(hardline + body) + hardline + `}` — K&R braces, never Allman, not configurable                                                                                     | [block.js][block]         | **Adapt** |
| P34 | An **empty** block prints `{}` — except after `if`/`else`/`try`/labels, where a hardline is inserted between the braces                                                                                   | [block.js][block]         | **Adapt** |
| P35 | Empty statements (stray `;`) are dropped from statement sequences                                                                                                                                         | [statement-sequence][seq] | **Adopt** |
| P36 | `if (…)` condition: group(indent(softline + test) + softline) — the condition indents inside the parens when it breaks                                                                                    | [miscellaneous][misc]     | **Adopt** |
| P37 | …unless the condition is `!(…)` or `!!(…)` over a logical expression, which hugs — so that deleting the `!` doesn't change the indent                                                                     | [miscellaneous][misc]     | **Adapt** |
| P38 | A non-block `if` body is indented on its own line: `if (x)\n  foo();` — braces are never added, but the body never stays inline                                                                           | [clause.js][clause]       | **Adapt** |
| P39 | `else` attaches to the previous `}` with one space; after a non-block consequent it goes on its own line                                                                                                  | [if-statement][ifs]       | **Adapt** |
| P40 | `else if` is printed as a flat chain, not a nested indent                                                                                                                                                 | [clause.js][clause]       | **Have**  |
| P41 | A clause whose leading comment is on its own line gets a hardline before it — the comment forces the break                                                                                                | [clause.js][clause]       | **Adopt** |
| P42 | `for (init; test; update)` breaks all three clauses together, indented, or none                                                                                                                           | [for-statement][for]      | **Adopt** |
| P43 | `for (;;)` is the canonical empty-header spelling                                                                                                                                                         | [for-statement][for]      | **Adapt** |
| P44 | `switch` cases are hardline-separated; a `case` body that is a single block hugs (`case x: {`), otherwise it indents one level                                                                            | [switch-statement][sw]    | **Have**  |
| P45 | `switch` discriminant breaks like an `if` condition (P36)                                                                                                                                                 | [switch-statement][sw]    | **Adopt** |
| P46 | `try`/`catch`/`finally` are always brace-hugged on one line; the catch parameter only breaks if it carries comments                                                                                       | [try-statement][try]      | **Adopt** |
| P47 | `do { … } while (…)`: the `while` hugs the closing brace; a non-block body puts it on its own line                                                                                                        | [do-while][dowhile]       | **Adopt** |
| P48 | Multiple declarators in one declaration: **hardline** between them if any has an initializer, `line` if none — `let a, b, c;` may stay flat, `let a = 1, b = 2;` never does                               | [variable-decl][vardecl]  | **Adopt** |
| P49 | The first declarator is indented when there is more than one (ESLint `one-var` compatibility)                                                                                                             | [variable-decl][vardecl]  | **Adapt** |
| P50 | `return`/`throw` of a binary expression wraps in `ifBreak` parens: `return (\n  a &&\n  b\n);`                                                                                                            | [return-statement][ret]   | **Adapt** |
| P51 | `return` whose argument has a leading own-line comment gets hard parens and a hardline                                                                                                                    | [return-statement][ret]   | **Adapt** |
| P52 | Class body members are hardline-separated, blank lines preserved; interface/object-type members use `line` and can collapse                                                                               | [class-body][cbody]       | **Adapt** |
| P53 | The class head (`class X extends Y implements Z`) enters "group mode" only when there are ≥2 heritage clauses, comments, or a member-expression superclass; otherwise `extends` is glued on the same line | [class.js][cls]           | **Adopt** |
| P54 | When the class head breaks, the `{` moves to its own line (via `ifBreak` on the heritage group) — but _not_ for interfaces, reverted after user complaints                                                | [class.js][cls]           | **Adapt** |

> **For D.** P33/P34/P38/P39 become **brace style, configurable** — [DStyle][dstyle] is Allman and
> that is the default; K&R is an option, as in dfmt. Two sub-decisions matter more than the brace
> column itself: a braceless `if (x) foo();` is preserved when the author wrote it (never
> expanded, never brace-injected), and `else if` chains stay flat (P40), which DStyle mandates
> explicitly. P36/P37 and P42/P45 are the reusable shapes: a parenthesized header that indents its
> contents when it breaks. P37 is worth stealing outright — _make the layout invariant under adding
> a negation_ — and it generalizes: any wrapper that would change indentation when deleted is a
> stability hazard.
>
> P35 is safe, with a caveat worth recording because it corrects an assumption easy to make: a bare
> `;` is **not** universally an error in D. As the body of an `if`/`while`/`for` it is
> (`Error: use { } for an empty statement, not ;`, verified on DMD 2.112.1), but inside a block —
> `{ int x; ;;; }` — and after an aggregate or function body — `struct S { };` — it compiles
> cleanly. So there is something to remove, dropping it is a no-op, and the rewrite is safe for the
> reason that it is dead syntax rather than the reason that it is illegal. P48 applies directly to
> D declaration lists. P52–P54 map onto D aggregate heads with base classes, interfaces and `if (…)`
> template constraints — exactly where D declarations get long, and where DStyle already has an
> opinion (constraints indent to their declaration's level; see P157).

---

## D. Delimited lists — the shape that repeats

Call arguments, parameters, arrays, object bodies, import specifiers and template parameters are
six printers implementing one shape with different exceptions. The exceptions _are_ the decisions.

### The base shape

| #   | Decision                                                                                                                                                     | Source                                             | Verdict   |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------- | --------- |
| P55 | The canonical list: `group("(" + indent(softline + join(","+line, items)) + trailingComma + softline + ")")` — all-or-nothing, one item per line when broken | [call-arguments][args], [function-params][fparams] | **Adopt** |
| P56 | An empty list prints `()`/`{}`/`[]` with no inner break, carrying only dangling comments                                                                     | [call-arguments][args]                             | **Adopt** |
| P57 | If any item's printed doc contains a hardline, the whole list is forced broken (`shouldBreak` propagation)                                                   | [call-arguments][args]                             | **Adapt** |
| P58 | A trailing comma is _emitted_ when broken and elided when flat, via `ifBreak(",")`                                                                           | [miscellaneous][misc]                              | **Adopt** |
| P59 | …except after a rest element (`...x`), where a trailing comma is illegal                                                                                     | [function-params][fparams]                         | **Adapt** |

### Call arguments — the expensive part

| #   | Decision                                                                                                                                                                                                                           | Source                     | Verdict    |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------- | ---------- |
| P60 | **Last-argument expansion:** if the final argument is a function/object/array literal, print `f(a, b, () => {` and let only that argument break — tried as a `conditionalGroup` of three layouts (flat, hugged-broken, all-broken) | [call-arguments][args]     | **Adapt**  |
| P61 | Last-arg expansion is refused when the last two arguments have the **same node type** — the reader can't tell which one hugged                                                                                                     | [call-arguments][args]     | **Adopt**  |
| P62 | Last-arg expansion is refused when the last argument carries leading or trailing comments                                                                                                                                          | [call-arguments][args]     | **Adopt**  |
| P63 | **First-argument expansion:** the mirror case, only for exactly two arguments where the first is a function and the second is "hopefully short"                                                                                    | [call-arguments][args]     | **Adapt**  |
| P64 | Expansion is attempted _speculatively_ and abandoned by exception (`ArgExpansionBailout`) when the hugged signature would itself break                                                                                             | [function-params][fparams] | **Adapt**  |
| P65 | Function-composition arguments (all arguments are functions) force the all-broken layout — no hugging when everything could hug                                                                                                    | [call-arguments][args]     | **Adopt**  |
| P66 | A "long curried call" (`f(a)(b)(c)`) deliberately omits its own group so the _inner_ arguments break before the outer ones                                                                                                         | [call-arguments][args]     | **Adapt**  |
| P67 | `require("…")`, `import("…")`, AMD `define(…)`, and single-string module imports are kept on one line at any length                                                                                                                | [call-expression][call]    | **Adapt**  |
| P68 | Test-framework calls (`it`, `describe`, `test` with a string + callback) are kept on one line at any length — a hardcoded library allowlist in a general-purpose formatter                                                         | [call-expression][call]    | **Reject** |
| P69 | React hook calls with a dependency array (`useEffect(fn, [a, b])`) get a bespoke never-break layout                                                                                                                                | [call-arguments][args]     | **Reject** |

### Parameters

| #   | Decision                                                                                                                                      | Source                     | Verdict   |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------- | --------- |
| P70 | **Sole-parameter hug:** a single destructuring/object-typed parameter prints without the surrounding break, so `function ({\n a,\n b\n}) {}`  | [function-params][fparams] | **Adapt** |
| P71 | The hug is refused if the parameter has decorators or comments                                                                                | [function-params][fparams] | **Adopt** |
| P72 | The parameter list and the return type share one group so that **the return type breaks first**, and only when there is exactly one parameter | [function-params][fparams] | **Adopt** |
| P73 | Parameters with access modifiers (`private x`) and more than one parameter force the list broken                                              | [function-params][fparams] | **Adapt** |

### Arrays, objects, imports, type parameters

| #   | Decision                                                                                                                                                | Source                 | Verdict   |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------- | --------- |
| P74 | **Concise (fill) mode** for arrays whose elements are _all_ numeric literals: pack as many per line as fit, Oppen-inconsistent, instead of one per line | [array.js][arr]        | **Adopt** |
| P75 | An array of ≥2 elements that are _all_ multi-element arrays or objects **of the same kind** is forced broken — the matrix/table heuristic               | [array.js][arr]        | **Adopt** |
| P76 | Destructuring patterns with nested patterns inside force the object broken                                                                              | [object.js][obj]       | **Adapt** |
| P77 | Import specifiers only get a breakable group when there are ≥2 of them; a single named import never breaks, at any length                               | [module.js][mod]       | **Adopt** |
| P78 | …stated in the docs as an intentional print-width violation, because users asked for it                                                                 | [rationale][rationale] | **Have**  |
| P79 | Template/type parameters are inlined (never broken) when there is exactly one and it is an object type or "huggable"                                    | [type-parameters][tp]  | **Adapt** |
| P80 | A type parameter's `extends` bound and `= default` each use their own group id, so the bound can break while the default stays flat                     | [type-parameters][tp]  | **Adopt** |
| P81 | Union types print `\| A \| B` with a leading bar when broken, `A \| B` when flat, each member aligned by 2                                              | [union-type][ut]       | **N/A**   |

> **For D.** P55–P57 are the core and already partially in the printer. P60–P66 are the
> **highest-value, highest-cost block in the whole extraction**: D calls take delegates and lambdas
> as final arguments constantly (`filter!(a => …)`, `each!((k, v) { … })`), so last-argument
> expansion is the decision D readers would notice most — and it needs argument-boundary facts the
> spine does not currently produce. P61/P62/P65 are the guard rails that make it not look random,
> and they are cheap once the boundaries exist. P70 maps onto D's single-struct-literal parameter.
> P74 is directly usable for D array literals and `enum` tables. P77 maps onto `import a.b : c;`.
> P79/P80 map onto `!(T, U)` template parameter lists and their `: bound = default` forms. P68/P69
> are the anti-pattern: a general-purpose formatter with a hardcoded list of third-party library
> names, which is exactly the thing a D formatter must not grow. P58's trailing comma is the one
> rewrite that is on by default, and it is enabling rather than cosmetic — without it, a list that
> breaks one-per-line has no comma after its last element, so the magic-trailing-comma signal
> dmd-fmt already reads (M4) can only ever be written by hand.

---

## E. Expression layout

### Binary and logical chains

| #   | Decision                                                                                                                                                                        | Source                 | Verdict    |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------- | ---------- |
| P82 | Operators of the **same precedence** are flattened into one group so they all break together, or none do                                                                        | [binaryish][bin]       | **Oracle** |
| P83 | Flattening is refused for right-associative `**`, for equality chains, for mixed `*`/`/`/`%`, and for shift chains — cases where flat printing would suggest the wrong grouping | [should-flatten][flat] | **Oracle** |
| P84 | The break goes **after** the operator by default; the whole chain is `head + indent(rest)`, so the first operand is not indented                                                | [binaryish][bin]       | **Adopt**  |
| P85 | No extra indent when the parent already provides one (`return`, arrow body, `for` header, assignment RHS…) — a list of ~10 parent contexts                                      | [binaryish][bin]       | **Adapt**  |
| P86 | A binary expression in an `if`/`while`/`switch` header is printed _without_ its own group, so it breaks with the header                                                         | [binaryish][bin]       | **Adopt**  |
| P87 | A single binary expression gets its own group so a short right operand (`-1`) doesn't land alone on a line                                                                      | [binaryish][bin]       | **Adopt**  |
| P88 | A trailing line comment on the left operand forces the chain broken                                                                                                             | [binaryish][bin]       | **Adopt**  |

### Assignment

| #   | Decision                                                                                                                                                                                                  | Source            | Verdict   |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | --------- |
| P89 | Assignment has **eight** layouts chosen by a decision procedure: `break-after-operator`, `never-break-after-operator`, `fluid`, `break-lhs`, `chain`, `chain-tail`, `chain-tail-arrow-chain`, `only-left` | [assignment][asg] | **Adapt** |
| P90 | Default is `fluid`: try to break the RHS first; only if that fails, break after the `=` — implemented with a group id and `indentIfBreak`                                                                 | [assignment][asg] | **Adopt** |
| P91 | Break after `=` when the RHS is a binary chain, a sequence, a poorly-breakable call/member chain, or a bare string literal                                                                                | [assignment][asg] | **Adopt** |
| P92 | Never break after `=` when the LHS cannot break and the RHS is a boolean, a number, a class, or a template                                                                                                | [assignment][asg] | **Adopt** |
| P93 | **Short-key rule:** an object property whose key is shorter than `tabWidth + 3` never breaks after the `:` — the wrapped line would overlap the key by too little to read as a wrap                       | [assignment][asg] | **Adopt** |
| P94 | Complex destructuring LHS (>2 properties, with defaults or renames) breaks the **left** side first                                                                                                        | [assignment][asg] | **Adapt** |
| P95 | Assignment chains (`a = b = c`) print unwrapped so that one break breaks them all — but only from three segments up                                                                                       | [assignment][asg] | **Adopt** |

### Member chains — the UFCS question

| #    | Decision                                                                                                                                                                                                    | Source                | Verdict   |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------- | --------- |
| P96  | A call-on-member chain is linearized and re-grouped into "one `.name(args)` per group", then printed one group per line when it breaks                                                                      | [member-chain][chain] | **Adopt** |
| P97  | The **head** group absorbs leading calls, numeric index accesses, and all-but-one member access — so `this.items` or `a()()` stays with the head                                                            | [member-chain][chain] | **Adopt** |
| P98  | **The factory heuristic:** if the head identifier starts with a capital or is all `_`/`$`, the first call merges into the head (`Object.keys(x)\n  .filter(…)`)                                             | [member-chain][chain] | **Adapt** |
| P99  | **The short-name heuristic:** in an expression statement, a head shorter than `tabWidth` also merges (`d3.scaleLinear()\n  .domain(…)`)                                                                     | [member-chain][chain] | **Adopt** |
| P100 | Chains of ≤2 groups (3 if merged) are never given the fancy treatment — plain concatenation                                                                                                                 | [member-chain][chain] | **Adopt** |
| P101 | A chain is forced broken when: it has comments, or >2 calls have a non-trivial argument, or any but the last group contains a hardline, or the last call breaks while earlier calls take function arguments | [member-chain][chain] | **Adopt** |

### Ternaries and lookups

| #    | Decision                                                                                                          | Source                  | Verdict   |
| ---- | ----------------------------------------------------------------------------------------------------------------- | ----------------------- | --------- |
| P102 | Nested ternaries in the alternate position form a flat chain, not an indent staircase                             | [ternary][tern]         | **Adopt** |
| P103 | A ternary as an assignment RHS gets an _extra_ indent level so the `?`/`:` don't align with the assignment target | [ternary][tern]         | **Adopt** |
| P104 | A ternary that is the object of a member access breaks its closing paren so the chain continues after it          | [ternary][tern]         | **Adapt** |
| P105 | Computed member lookups (`a[expr]`) break inside the brackets; numeric and identifier lookups never break         | [member.js][mem]        | **Adopt** |
| P106 | `a.b` where both sides are plain identifiers never breaks at the dot                                              | [member.js][mem]        | **Adopt** |
| P107 | `new` callee is inlined rather than chain-formatted                                                               | [call-expression][call] | **Adapt** |

> **For D.** P82/P83 are marked **Oracle**, and with rewriting in scope this is now the _load-bearing_
> boundary of the whole page rather than a footnote: flattening by precedence needs the
> unary-vs-binary distinction the [proposal][proposal] declined to solve at token level — and so do
> P116 (paren removal) and P156 (DStyle's binary-operator spacing). Three of the most-wanted rules
> share one blocker, which changes its cost/benefit: it is not one feature's prerequisite, it is
> the gate on a third of the rewrite tier.
>
> Everything else in this section is reachable today. P96–P101 are the **UFCS pipeline decision** —
> the repo's own [functional-declarative guidelines][fdg] make `x.filter!(…).map!(…).array` the
> house idiom, so how a broken pipeline lays out is the most-seen formatting decision in this
> codebase. P98's capitalization heuristic maps onto D naming (types are PascalCase, so
> `Type.make(x)` as a chain head is exactly the intended case). P93's short-key rule generalizes to
> any `name: value` or `name = value` where the name is too short for a wrap to read as one — worth
> stating as a width rule, not a key rule. P50/P51 are now allowed to insert the parens they need,
> which D makes safer than JS: there is no ASI, so a wrapped `return (…)` cannot change meaning.

---

## F. Token-level normalization

This section is prettier _rewriting_ code. Under the two-tier scope it is no longer excluded — it
is where the opt-in tier's prettier-derived rules live, and the section that most needs a per-rule
verdict rather than a blanket one. §J adds the D-specific rewrites prettier has no row for.

| #    | Decision                                                                                                                         | Source                  | Verdict    |
| ---- | -------------------------------------------------------------------------------------------------------------------------------- | ----------------------- | ---------- |
| P108 | **Quote choice by escape count:** pick the quote that needs fewer escapes; `singleQuote` only breaks ties                        | [print-string][pstr]    | **Opt-in** |
| P109 | Escape sequences inside the string are preserved exactly — `"🙂"` never becomes `"\uD83D\uDE42"`, or the reverse                 | [make-string][mkstr]    | **Adopt**  |
| P110 | Re-escaping is minimal: quotes of the _other_ kind are unescaped when switching quote styles                                     | [make-string][mkstr]    | **Adopt**  |
| P111 | Numbers are lowercased; `+` and leading zeros are stripped from exponents; `1e0` → `1`; `.5` → `0.5`; `1.50` → `1.5`; `1.` → `1` | [print-number][pnum]    | **Reject** |
| P112 | BigInt literals are lowercased                                                                                                   | [literal.js][lit]       | **Reject** |
| P113 | Regex flags are sorted alphabetically                                                                                            | [literal.js][lit]       | **Reject** |
| P114 | Object keys are quoted or unquoted per `quoteProps`, with a consistency rule: if one sibling needs quotes, all get them          | [key.js][key]           | **N/A**    |
| P115 | Key unquoting is refused wherever it would change semantics (TypeScript numeric keys, Flow, `--strictPropertyInitialization`)    | [key.js][key]           | **N/A**    |
| P116 | Redundant parentheses are dropped; needed ones are re-derived from precedence rather than preserved                              | [needs-parens][np]      | **Opt-in** |
| P117 | Semicolons are inserted or removed per `semi`, including the defensive leading `;`                                               | [expression-stmt][expr] | **N/A**    |
| P118 | `directive` string literals ("use strict") keep their exact code units — quote swapping is refused when they contain quotes      | [literal.js][lit]       | **N/A**    |

> **For D.** **P116** is the one to take, and the one to gate. Prettier can drop parentheses because
> it reprints from an AST that knows precedence; a token-spine formatter must acquire that knowledge
> first (P82/P83), and until it does, paren removal is unimplementable rather than merely disabled.
> Once it exists, D wants the rule in _both_ directions — drop the redundant pair, and add a
> clarifying pair where mixed precedence is easy to misread — which prettier does not do, and which
> DStyle half-endorses already ("avoid unnecessary parentheses": `a == b ? "foo" : "bar"`).
>
> **P108–P110 generalize into P154**, D's literal-form selection: D has five spellings of a string
> literal where JS has two, so "fewest escapes" is a choice among `"…"`, `` `…` ``, `q"ID…ID"`,
> `q{…}` and `x"…"` rather than between two quote characters. P109/P110 are the guard rails that
> make it safe — **normalize spelling, never semantics** — and they are the reason prettier's string
> handling is three functions instead of one.
>
> **P111–P113 are rejected.** Number spelling in D carries author intent that no formatter can
> recover: `0x1F` vs `31`, `1_000_000`'s digit separators, `1.0f` vs `1.0`, the `L`/`u` suffixes.
> Prettier can normalize because JS has one numeric type and one canonical spelling; D has neither,
> and a rule that lowercases `0xDEADBEEF` or strips a trailing `.0` would destroy information while
> changing nothing about layout. **P114/P115 are N/A** — D's AA literals key on expressions, so
> there is no quoted-key question. **P117 is N/A**: D's semicolons are mandatory, so there is
> nothing to insert or elide (the stray-`;` case is P35).

---

## G. Comments

| #    | Decision                                                                                                                                                         | Source                  | Verdict   |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------- | --------- |
| P119 | A line comment is emitted verbatim with trailing whitespace trimmed                                                                                              | [comment.js][cmt]       | **Have**  |
| P120 | A block comment is emitted verbatim, with line endings normalized                                                                                                | [comment.js][cmt]       | **Have**  |
| P121 | **Only** block comments whose every line starts with `*` are re-indented — the JSDoc exception, prettier's one comment edit                                      | [comment.js][cmt]       | **Adopt** |
| P122 | A JSDoc line ending in two spaces (a markdown hard break) is emitted as a `literalline` so the indentation is not re-applied                                     | [comment.js][cmt]       | **Adopt** |
| P123 | Comments are classified leading / trailing / **dangling** (attached to a node with no children to attach to, e.g. inside `()`), with a printer per position      | [call-arguments][args]  | **Adapt** |
| P124 | A dangling line comment inside an empty list forces a hardline; a dangling block comment does not                                                                | [miscellaneous][misc]   | **Adopt** |
| P125 | A leading own-line comment on an assignment RHS switches the layout to `break-after-operator` (P89) — the comment changes the layout, not just the position      | [assignment][asg]       | **Adopt** |
| P126 | An indentable block comment leading the RHS does the same                                                                                                        | [assignment][asg]       | **Adopt** |
| P127 | Comments in a member chain force it broken (P101), and a trailing comment closes the current chain group                                                         | [member-chain][chain]   | **Adopt** |
| P128 | A `/** @type {…} */` cast comment is printed _before_ an inserted leading semicolon, so it keeps applying to the right expression                                | [expression-stmt][expr] | **Adapt** |
| P129 | Prettier documents that magic comments (`eslint-disable-next-line`) can be silently invalidated by its own reflow, and tells users to prefer range-based pragmas | [rationale][rationale]  | **Adopt** |

> **For D.** P121/P122 is the exact analogue of DDoc block comments (`/** … */` with leading `*`),
> and it is the _floor_ of what dmd-fmt does here rather than the ceiling: re-indenting the body is
> safe and unconditional, while **P28 becomes the opt-in DDoc reflow** — rewrap prose to the print
> width, indent section bodies one level as [DStyle][dstyle] requires, leave `---` example blocks
> and fenced code untouched, and lay out DDoc tables with the repo's own solver
> (`libs/ui/src/sparkles/ui/components/table/layout.d`, already used for the markdown adapter). The
> precedent is hue, which renders and reflows markdown today; the escape hatches are the same ones
> a reader already knows — a language-less code block, or `// dfmt off`. P122 is the trap to handle
> while doing it: a line ending in two spaces is a markdown hard break, and re-indenting it silently
> deletes the break.
>
> P123's dangling-comment classification is the one piece of comment machinery a token-spine
> formatter still needs, because "the comment inside an otherwise-empty `()`" has no token to hang
> off. P125/P126 are worth internalizing generally: a comment is a layout input, not just content
> to relocate. P129 is a warning dmd-fmt inherits the moment it moves any line — range pragmas are
> safer than line-scoped ones, and that is already the design (D5).

---

## H. Escape hatches and the scope boundary

| #    | Decision                                                                                                               | Source                 | Verdict   |
| ---- | ---------------------------------------------------------------------------------------------------------------------- | ---------------------- | --------- |
| P130 | `// prettier-ignore` prints the next node's **original source range verbatim**, byte for byte                          | [ignored.js][ign]      | **Have**  |
| P131 | An ignored node still gets its semicolon/leading-semicolon fixup, so the surrounding statement stays valid             | [ignored.js][ign]      | **Adopt** |
| P132 | An ignored class expression with decorators still gets its indent/softline wrapper                                     | [ignored.js][ign]      | **Adapt** |
| P133 | Machine-generated files (`package.json`) get a different printer entirely, to avoid fighting the tool that writes them | [rationale][rationale] | **Adapt** |
| P134 | Prettier states it will not fix a semicolon-related bug, only reveal it by printing what the code actually means       | [rationale][rationale] | **Have**  |

---

## I. Template literals and the type level

Included on the second pass, because both map onto D constructs that the first reading dismissed:
prettier's template literals are the closest thing in its corpus to D's
[interpolated expression sequences][ies], and its type-level printers reuse the same layout
machinery D needs for template parameters, constraints and `alias` declarations.

| #    | Decision                                                                                                                                        | Source                  | Verdict   |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------- | --------- |
| P135 | A template literal is never broken and never re-quoted; its quasis are emitted verbatim between the backticks                                   | [template-literal][tl]  | **Have**  |
| P136 | An interpolation is first rendered at **infinite width**; it may break only if it _still_ contains a newline at that width                      | [template-literal][tl]  | **Adopt** |
| P137 | When one does break, the break is taken at the `${` / `}` boundary in preference to breaking inside a member expression                         | [template-literal][tl]  | **Adopt** |
| P138 | Rebuilt template content is **re-escaped** (`` ` ``, `\`, `${`) so a doc-level rewrite cannot silently change the string's meaning              | [template-literal][tl]  | **Adopt** |
| P139 | Interpolation indentation is preserved by aligning the expression to the `${` column, or dedenting to root when the previous quasi ends in `\n` | [template-literal][tl]  | **Adapt** |
| P140 | `jest.each` tagged templates: prettier detects a pipe-delimited table _inside_ a template literal and pads its columns into alignment           | [template-literal][tl]  | **Adapt** |
| P141 | A `type X<T> = …` alias is printed through the **assignment** machinery, so type aliases inherit all eight layouts of P89                       | [type-alias][talias]    | **Adopt** |
| P142 | An enum body always breaks — one member per line, at any width                                                                                  | [object.js][obj]        | **Adapt** |
| P143 | An enum member's initializer uses a plain `" = "`, never the assignment layouts                                                                 | [enum.js][enum]         | **Adopt** |
| P144 | A conditional type breaks before the `?` when either side is generic; chains of them print flat, like nested ternaries                          | [assignment][asg]       | **Adapt** |
| P145 | Whether a leading space precedes a type annotation is decided by **which token precedes it** (`:` vs `=>`), not by the annotation itself        | [type-annotation][tann] | **Adapt** |

> **For D.** P136 is the rule to take for IES, and it is a strictly better version of P24: instead
> of "did the author break it", the test is "does it break _anyway_ at unlimited width" — same
> stability, no source hint. P137 says the break belongs at `$(` / `)`, not inside the expression,
> which is what keeps `i"…$(a.b.c)…"` readable. P138 is the guard rail every literal rewrite needs
> (P154): D has more escaping regimes than JS — `"…"` escapes, `` `…` `` and `q"…"` do not, and
> `i"…"` adds `\$` — so a form change is only sound if the decoded code units are unchanged, which
> is exactly what makes it verifiable. P140 is library-specific in its trigger and generic in its
> mechanism: aligning a table that lives _inside_ a literal is the DDoc-table case (P28), and the
> repo already owns a better solver than prettier's.
>
> P141 is the row that pays: D's `alias X(T) = …;` is an assignment, so every layout in P89–P95
> applies to it for free once assignment is implemented. P144 maps onto nested ternaries in
> eponymous templates (`enum f(T) = cond ? a : b`) and, loosely, onto `static if`/`else static if`
> chains, which DStyle already requires to stay flat. P145 is a reminder that in D the `:` is
> overloaded across selective imports (`import a : b`, spaces both sides per DStyle), template
> constraints, AA literals, named arguments, `case a: .. case b:` and label statements — one token,
> six spacing rules, and the spine sees only the token.

---

## J. The D rewrite catalog

Rules with no prettier row, because they are D's. This is the section the two-tier scope opens up,
and it is deliberately a menu of **opt-in** rules with their hazards attached — the hazard is the
specification of the verifier each one needs.

| #    | Rule                                                                                                                                                                       | Source of the rule       | Verdict     |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------ | ----------- |
| P146 | **Import grouping**: `core.*`, `std.*`, external, other sub-packages, same sub-package — one blank line between groups                                                     | [code style][code-style] | **Opt-in**  |
| P147 | **Import sorting**: lexicographic within a group, and the selective symbol list sorted too (`import a : b, c;`)                                                            | [DStyle][dstyle]         | **Opt-in**  |
| P148 | **Declaration ordering**: public API before implementation details, topologically within                                                                                   | [code style][code-style] | **Opt-in**  |
| P149 | **Test adjacency**: a `unittest` moves to directly follow the declaration it exercises                                                                                     | [code style][code-style] | **Opt-in**  |
| P150 | **Attribute ordering**: alphabetical ignoring the `@` — `const @nogc nothrow pure @safe`                                                                                   | [DStyle][dstyle]         | **Opt-in**  |
| P151 | **Legacy `alias` retirement**: `alias Y X;` → `alias X = Y;`                                                                                                               | [DStyle][dstyle]         | **Opt-in**  |
| P152 | **Shortened function bodies** (DIP1043): a body that is one `return` becomes `=> expr;`                                                                                    | [code style][code-style] | **Opt-in**  |
| P153 | **Expression contracts** (DIP1009): an `in`/`out` block holding exactly one `assert` becomes `in (…)` / `out (r; …)`, and the `do` goes away                               | [DStyle][dstyle]         | **Opt-in**  |
| P154 | **Literal-form selection**: pick the spelling that needs no escapes — `` `…` `` for text with `"`, `q"ID…ID"` for blocks, `q{…}` for D code inside `mixin(…)`              | [code style][code-style] | **Opt-in**  |
| P155 | **`format("%s %s", a, b)` → `i"$(a) $(b)"`** — reclassified: a **codemod**, not a formatter rule ([roadmap][codemods] C2)                                                  | this survey              | **Codemod** |
| P156 | **DStyle spacing**: space after `if`/`foreach`/`while`/`version`, around binary operators and slice `..`, after `cast(T)`; none after unary operators, `assert`, or a call | [DStyle][dstyle]         | **Oracle**  |
| P157 | **Constraint and contract indentation**: `if (…)`, `in`, `out` sit at their declaration's indentation level, not one deeper                                                | [DStyle][dstyle]         | **Adopt**   |
| P158 | **Field alignment**: the space between a field's type and its name in an aggregate — configurable, DStyle's one space as the default                                       | [DStyle][dstyle]         | **Adopt**   |
| P159 | **Dead-semicolon removal**: `struct S { };` → `struct S { }`, the declaration-level half of P35                                                                            | this survey              | **Adopt**   |
| P160 | **Template-argument simplification**: `f!(T)` → `f!T` when the argument is a single token                                                                                  | this survey              | **Opt-in**  |

### The hazards, which are the verifier specifications

- **P146/P147 are safer in D than the same rule is in JS**, and the reason is worth stating because
  it is the strongest argument in this section: D's module constructors run in **dependency order
  computed by the runtime**, not in the order `import` statements appear, so reordering imports
  cannot reorder initialization the way reordering ES module imports can. Overload sets assembled
  from several modules are order-independent too — ambiguity is an error, not first-wins. The
  residual hazards are narrow and checkable: never move an import across a `version`/`static if`
  boundary, never merge imports at different scopes, and preserve renamed-import spelling.
- **P148/P149 are the dangerous pair, and must never touch aggregate fields.** Reordering fields
  changes `.offsetof`, the ABI, and every `align`/union assumption in the program. Even at module
  scope, D reflects over declaration order: `__traits(allMembers)` returns it, `static foreach` over
  that order generates code from it, and a string mixin built from either bakes it into the output.
  A defensible verifier is therefore: refuse the rewrite in any module that mentions
  `__traits(allMembers)`, `__traits(derivedMembers)`, or `.tupleof`, and restrict the rewrite to
  module-scope functions in the first release. P149 has a cheap hook this repo already provides —
  the `@("module.symbol.case")` test-name convention names the subject.
- **P150 must reorder only the commuting set** (`@safe`/`@trusted`/`@system`, `pure`, `nothrow`,
  `@nogc`, `const`/`immutable`/`inout`/`shared` as member qualifiers). `ref`, `scope` and `return`
  are **not** in it: `return scope` and `scope return` differ, and a sort that treats them as
  keywords to alphabetize is a semantic change wearing a style rule's clothes.
- **P152's real blocker is documented in this repo already**: a local `import` in the body forces a
  braced body, so the rewrite must decline whenever the body imports — which is a syntactic check,
  not a semantic one, and therefore cheap.
- **P154 is the most verifiable rewrite in the catalog**, and should be built first for that reason:
  decode the old spelling and the new one and compare code units. If they differ, the rewrite is
  wrong, and the check is total rather than heuristic. Note the one form that is not a pure
  respelling: `q{…}` is **lexed** by the compiler, so moving text into it can turn a passing build
  into a failing one (an unbalanced brace inside a comment, say) — which is a feature when the
  content really is D code and a bug otherwise, so restrict it to `mixin(…)` arguments.
- **P155 is a codemod, and that is a place rather than a rejection.** `format(…)` returns a
  `string`; an IES literal is a compile-time _sequence_ that deliberately does not convert to one.
  The rewrite therefore only type-checks where the callee accepts IES (`writeln`, an IES-aware
  overload), so no syntactic argument establishes its safety — which is exactly the line
  [the codemod roadmap][codemods] draws between the two tools, and P155 is its C2 opener, applied
  per site with the callee's signature checked. The general test: **a formatter rewrite is safe by
  decoding; a codemod is safe only by typing.**
- **P156 is the largest single gap between dmd-fmt and DStyle**, and the one users will notice
  first: v1 preserves `a+b` because it has no opinion on spacing, while DStyle mandates `a + b`.
  It is gated on the same unary-vs-binary question as P82/P83 and P116 — which is the argument for
  paying that cost once, deliberately, rather than three times by accident.
- **P158 is an option with three positions, not a yes/no.** M4 preserves author alignment (aligned
  table literals stay aligned); DStyle asks for exactly one space between a field's type and its
  name, explicitly to keep diffs small. Both are defensible, so the key takes a value: `dstyle`
  (the default — collapse aggregate field padding to one space), `preserve` (today's M4 behaviour),
  and `align` (**enforce** column alignment across a run of field declarations, creating it where
  the author did not). The third position is the one no surveyed formatter offers as a first-class
  option and that users of every formatter keep asking for; it is a column solver over a contiguous
  declaration run, and the repo already owns one
  (`libs/ui/src/sparkles/ui/components/table/layout.d`). The scope is the same under all three
  values: **aggregate field declarations only** — alignment inside array and table literals stays
  the author's.

---

## What the extraction says

160 rows: **64 Adopt · 47 Adapt · 17 Have · 16 Opt-in · 7 N/A · 5 Reject · 3 Oracle · 1 Codemod.**

**1. The scope change moved the bottleneck from _permission_ to _proof_.** Under the old reading,
19 rows were excluded because they touched tokens. Under the two-tier scope only 5 are rejected on
their merits and 1 is reclassified as a [codemod][codemods], and the constraint that replaced the blanket exclusion is sharper and more useful:
tier-3 token equality cannot verify a rewrite, so each opt-in rule needs its own check. Ranked by
how cheap that check is: **P154** (decode both spellings, compare code units — total, not
heuristic) · **P151/P152/P153/P159/P160** (syntactic, local, mechanically checkable) ·
**P146/P147** (needs a scope-boundary check, and D's dependency-ordered module construction makes
the semantics easier than JS's) · **P116/P156** (needs precedence) · **P148/P149** (needs to prove
nothing reflects over declaration order — the hardest, and the one to ship last).

**2. One missing fact gates a third of the rewrite tier.** Unary-vs-binary disambiguation — declined
at token level by the proposal — is the prerequisite for P82/P83 (operator flattening), P116
(parenthesis normalization) and P156 (DStyle's binary-operator spacing). Three separately-requested
rules, one blocker. That reframes it: not a per-feature cost, but a single investment that unlocks
the most-visible difference between dmd-fmt's output and DStyle's prescription.

**3. Prettier's preservation is larger than advertised, and it is what dmd-fmt made policy.** Six
independent source hints read the original text (P17, P19, P22, P24, P25–P27). Prettier's docs call
two of them workarounds it wants to remove; dmd-fmt keeps them deliberately, and the difference is
consistency: prettier's hint is one construct's exception, dmd-fmt's is the rule everywhere. P136 is
the one improvement available — "does it break at unlimited width" is the same stability with no
source hint at all.

**4. The expensive _layout_ decisions cluster in three places** — call arguments (P60–P66), member
chains (P96–P101), assignment (P89–P95). Together ~1,300 lines of prettier's ~10,800-line JS
printer, and the three shapes a D reader meets constantly: lambda-taking calls, UFCS pipelines,
`auto x = …`. Everything else is comparatively mechanical.

**5. Two decisions are inadmissible on principle** — P68 and P69 hardcode third-party library names
(`it`, `describe`, `useEffect`) into a general-purpose formatter. They are the visible cost of
"opinionated": once the formatter owns the layout, every community with a bad-looking idiom
petitions for a special case. P155 is the D-side instance of the same temptation, and is rejected
for a stronger reason — it does not preserve types.

**6. The `Doc` IR gap is small and specific.** `libs/dmd-fmt/src/sparkles/dmd_fmt/doc.d` already has
`text`/`line`/`softline`/`hardline`/`group`/`fill`/`indentBlock`/`alignBlock`/`ifBreak`/
`lineSuffix`/`conditional`. Missing, in the order the decisions above need them:

| Missing primitive                         | Needed by                          | Note                                                                                |
| ----------------------------------------- | ---------------------------------- | ----------------------------------------------------------------------------------- |
| **Group ids** + `indentIfBreak(id)`       | P90 (`fluid` assignment), P80, P54 | The single biggest gap: three of the best decisions are unimplementable without it. |
| `ifBreak` over **Docs**, not just strings | P50, P74, P81                      | Current signature takes `string broken, string flat`.                               |
| `willBreak` / `canBreak` inspection       | P57, P60, P64, P89, P101           | Every "does this sub-doc break?" guard.                                             |
| `removeLines`                             | P60, P63                           | Flattening a hugged signature.                                                      |
| `breakParent`                             | P22, P25, P101                     | Partly covered: `hardline` already forces enclosing groups.                         |
| `dedentToRoot`                            | P139                               | Interpolations that start at column 0 inside a multi-line literal.                  |
| `label`                                   | P96 (chain detection), P60         | Tagging a doc so a parent printer can branch on how a child printed.                |

Adding group ids and doc-valued `ifBreak` is the enabling change; the rest are conveniences.

## The shortlist

**Layout tier — twelve, ordered by value per unit of work.** All apply to D, none need an oracle
we lack:

1. **P90 + group ids** — the `fluid` assignment layout, and the IR change that unlocks P80 and P54.
2. **P96–P101** — member-chain grouping, for UFCS pipelines. The most-seen layout in this codebase.
3. **P141** — route `alias X(T) = …;` through assignment, and every layout in P89–P95 comes free.
4. **P74** — concise fill for all-numeric array literals.
5. **P25–P27** — blank lines inside lists and chains as break forcers.
6. **P121 + P122** — re-indent DDoc `/** … */` bodies, with the hard-break trap handled.
7. **P36 + P37** — parenthesized-header indentation, invariant under adding a negation.
8. **P157** — constraints and contracts at their declaration's indentation level (DStyle).
9. **P48** — hardline between declarators when any has an initializer.
10. **P93** — the short-name wrap rule, generalized off object keys.
11. **P75** — force-break an array of same-kind multi-element elements (the table heuristic).
12. **P136 + P137** — IES interpolation: break only if it breaks at unlimited width, and break at
    the `$(` boundary.

**Rewrite tier — build order, cheapest verifier first.** Trailing commas (P7/P58) are the default-on
member and are already specified; the opt-in rules should land in this order, each with the check
named in §J:

1. **P154** — literal-form selection. Total verifier (decode and compare), highest daily value.
2. **P159 + P35** — dead-semicolon removal. Trivial, and a good first exercise of the
   rewrite-plus-verifier harness.
3. **P151 + P152 + P153 + P160** — the syntactic modernizations (legacy `alias`, `=>` bodies,
   expression contracts, `!T`).
4. **P146 + P147** — import grouping and sorting, with the scope-boundary check.
5. **P150** — attribute ordering, restricted to the commuting set.
6. **P158** — field alignment as a three-valued key (`dstyle` default, `preserve`, `align`).
7. **P116 + P156** — parenthesis normalization and DStyle spacing, after the precedence oracle
   exists. These two justify that investment between them.
8. **P148 + P149** — declaration ordering and test adjacency, last, and never for aggregate fields.

Deferred with reasons: P60–P66 (needs argument boundaries from the oracle), P82/P83 (needs
precedence — same gate as item 7 above), P68/P69 (inadmissible — hardcoded library names),
P111–P113 (number and regex spelling carries author intent D cannot recover), P17 (already the
policy, not a decision to re-take). Moved rather than deferred: P155, to
[the codemod roadmap][codemods].

**How this list gets executed and published** is [the testing spec][testing-spec]: every decision
above needs a `.cases` fixture, every configurable one needs a fixture per value, and the published
per-decision documentation is generated from those fixtures so a documented example is by
construction the formatter's actual output.

---

## Sources

- [`prettier/prettier`][repo] @ `414e453ae9034866d93eea456b430aa52140371b` — the printer sources
  listed under [Method](#method)
- [`docs/rationale.md`][rationale] · [`docs/option-philosophy.md`][option-philosophy] ·
  [`commands.md`][commands]

**Related in this tree:** [prettier deep-dive][prettier] · [Concepts][concepts] ·
[Combinators][combinators] · [Comparison][comparison] · [dfmt][dfmt] ·
[The D proposal][proposal]

<!-- References -->

[repo]: https://github.com/prettier/prettier/tree/414e453ae9034866d93eea456b430aa52140371b
[opt]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/main/core-options.evaluate.js
[copt]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/common/common-options.evaluate.js
[jsopt]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/options.js
[rationale]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/docs/rationale.md
[option-philosophy]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/docs/option-philosophy.md
[commands]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/commands.md
[asg]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/assignment.js
[bin]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/binaryish.js
[flat]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/utilities/should-flatten.js
[args]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/call-arguments.js
[call]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/call-expression.js
[chain]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/member-chain.js
[mem]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/member.js
[tern]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/ternary.js
[obj]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/object.js
[arr]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/array.js
[block]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/block.js
[seq]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/statement-sequence.js
[ifs]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/if-statement.js
[clause]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/clause.js
[sw]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/switch-statement.js
[ret]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/return-statement.js
[expr]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/expression-statement.js
[vardecl]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/variable-declaration.js
[try]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/try-statement.js
[for]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/for-statement.js
[dowhile]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/do-while-statement.js
[fparams]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/function-parameters.js
[cls]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/class.js
[cbody]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/class-body.js
[dec]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/decorators.js
[mod]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/module.js
[cmt]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/comment.js
[ign]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/ignored.js
[misc]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/miscellaneous.js
[tp]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/type-parameters.js
[ut]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/union-type.js
[key]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/key.js
[tl]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/template-literal.js
[talias]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/type-alias.js
[enum]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/enum.js
[tann]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/type-annotation.js
[lit]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/print/literal.js
[np]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/language-js/parentheses/needs-parentheses.js
[pstr]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/utilities/print-string.js
[mkstr]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/utilities/make-string.js
[pnum]: https://github.com/prettier/prettier/blob/414e453ae9034866d93eea456b430aa52140371b/src/utilities/print-number.js

<!-- Tree-level docs -->

[prettier]: ./prettier.md
[concepts]: ./concepts.md
[combinators]: ./theory/combinators.md
[comparison]: ./comparison.md
[dfmt]: ./dfmt.md
[proposal]: ./dmd-fmt-proposal.md
[dmd-fmt-spec]: ../../specs/dmd-fmt/index.md
[codemods]: ../../specs/dmd-fmt/codemods.md
[testing-spec]: ../../specs/dmd-fmt/testing.md
[dstyle]: ../../guidelines/dstyle.md
[code-style]: ../../guidelines/code-style.md
[ies]: ../../guidelines/interpolated-expression-sequences.md
[fdg]: ../../guidelines/functional-declarative-programming-guidelines.md
