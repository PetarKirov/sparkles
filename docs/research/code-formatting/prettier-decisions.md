# Prettier's decisions, extracted

A **mechanical inventory** of every formatting decision prettier actually makes, read off its
printer sources rather than its documentation, and scored for a D formatter. The
[prettier deep-dive][prettier] answers _how the engine works_; this page answers _what the engine
decides_, one row at a time, so each row can be argued about on its own.

**Last reviewed:** August 19, 2026

The extraction is the input to tuning [`sparkles:dmd-fmt`][dmd-fmt-spec]. Its v1 policy is
**author's-breaks-preserved with structural reindentation** — line structure is the author's,
indentation is recomputed, horizontal whitespace is normalized, and _no token is ever added or
removed_. That policy is a filter, and running prettier's decision list through it is the point of
the exercise: it says which of prettier's 134 decisions are reachable at all, which are reachable
only with more oracle than we have, and which are excluded by construction.

> [!IMPORTANT]
> **The headline number: 24 of the 134 decisions below never reach a D formatter that does not
> rewrite tokens.** Trailing commas, semicolons, quote characters, number spelling, redundant
> parentheses, quoted object keys — every one of these is prettier _editing your code_, not laying
> it out. dmd-fmt v1 declares that a non-goal, so a sixth of prettier's decision surface is out of
> scope before the first line of D is written, and it is the sixth prettier is most famous for. Of
> the remainder, another large block turns out to be **source-hint preservation**
> (objects, decorators, template interpolations, blank lines) — which is the v1 policy already,
> arrived at independently. What is genuinely _new_ and genuinely _applicable_ is a much shorter
> list than prettier's size suggests: the [shortlist](#the-shortlist) has twelve entries.

---

## Method

Every row cites the source that implements it, at a pinned revision. Nothing here is taken from
prettier's docs unless the docs are the only statement of the rule (marked _rationale_), and
several rows contradict the folk understanding of what prettier does.

- **Tree:** [`prettier/prettier`][repo] @ `414e453ae9034866d93eea456b430aa52140371b` (2026-08-13).
- **Read in full:** `src/language-js/print/{assignment,binaryish,call-arguments,member-chain,object,array,block,statement-sequence,if-statement,clause,switch-statement,return-statement,expression-statement,variable-declaration,try-statement,for-statement,while-statement,do-while-statement,for-x-statement,function,function-parameters,arrow-function,class,class-body,decorators,module,comment,member,call-expression,key,literal,miscellaneous,type-parameters,union-type,ignored}.js`,
  `src/language-js/{options.js,utilities/{should-flatten,is-simple-call-argument,is-lone-short-argument}.js}`,
  `src/{main/core-options.evaluate.js,common/common-options.evaluate.js,utilities/{print-string,print-number,make-string}.js}`,
  `docs/rationale.md`, `commands.md`.
- **Excluded:** JSX, Flow, Angular/Vue/HTML-binding, template literals, and the TypeScript
  type-level printers, except where a rule generalizes (type parameters → D template parameters).
  Those have no D analogue and would pad the list without informing it.

**A "decision" is a rule that can change bytes of output.** A helper that only computes a predicate
is folded into the row it serves. Where prettier implements one idea in three printers (the
"break a delimited list" shape), it is one row with the printers listed.

### Legend

| Verdict    | Meaning                                                                        |
| ---------- | ------------------------------------------------------------------------------ |
| **Adopt**  | Applies to D as-is; worth implementing.                                        |
| **Adapt**  | The idea transfers, the trigger or shape must change for D.                    |
| **Have**   | v1 already decides this, the same way or deliberately differently.             |
| **Oracle** | Reachable only with AST facts the `oracle.d` offset arrays do not yet collect. |
| **Token**  | Excluded by v1: adds or removes tokens.                                        |
| **N/A**    | No D construct.                                                                |

---

## A. The configurable surface

What prettier lets you change is a decision in itself — its
[option philosophy][option-philosophy] is that an option exists only where the team could not pick
a winner. Eighteen format-affecting options, in a formatter that markets itself as opinionated.

| #   | Decision                                                                                                                     | Source              | Verdict   |
| --- | ---------------------------------------------------------------------------------------------------------------------------- | ------------------- | --------- |
| P1  | `printWidth` defaults to **80**, and is explicitly a _target_, not a cap — prettier emits longer lines on purpose (P67, P77) | [core-options][opt] | **Have**  |
| P2  | `tabWidth` defaults to **2**; `useTabs` defaults to false                                                                    | [core-options][opt] | **Have**  |
| P3  | `endOfLine` defaults to `lf`; `auto` infers from the line ending after the file's first line                                 | [core-options][opt] | **Adapt** |
| P4  | `semi` (default on) — when off, a leading `;` is emitted on lines that would otherwise continue the previous statement       | [js-options][jsopt] | **N/A**   |
| P5  | `singleQuote` (default off) only breaks ties; escape count wins first (P108)                                                 | [js-options][jsopt] | **Token** |
| P6  | `quoteProps: as-needed \| consistent \| preserve` — quoting of object keys                                                   | [key.js][key]       | **Token** |
| P7  | `trailingComma` defaults to **`all`**: prettier _writes_ trailing commas whenever a list breaks                              | [js-options][jsopt] | **Token** |
| P8  | `bracketSpacing` (default on) — `{ a }` vs `{a}`; the sole horizontal-spacing option                                         | [common-opts][copt] | **Adapt** |
| P9  | `arrowParens` defaults to `always`: `(x) => x`, not `x => x`                                                                 | [js-options][jsopt] | **Token** |
| P10 | `objectWrap: preserve \| collapse` — makes the object source-hint (P17) switchable, added because it is a known wart         | [common-opts][copt] | **Adapt** |
| P11 | `experimentalOperatorPosition: end \| start` — operator at the end of the broken line, or the start of the next              | [binaryish][bin]    | **Adapt** |
| P12 | `experimentalTernaries` — an entire second ternary printer, opt-in, because the first one is disliked                        | [ternary][tern]     | **Adapt** |
| P13 | `requirePragma` / `insertPragma` / `checkIgnorePragma` — file-level opt-in/opt-out via a docblock marker                     | [core-options][opt] | **Adapt** |
| P14 | `rangeStart`/`rangeEnd` — format a byte range, extended outward to whole statements                                          | [core-options][opt] | **Adopt** |
| P15 | `cursorOffset` — report where a cursor lands after formatting                                                                | [core-options][opt] | **Adopt** |
| P16 | `embeddedLanguageFormatting: auto \| off` — format code embedded in strings/templates                                        | [core-options][opt] | **Adapt** |

> **For D.** P1–P3 and P8 are already `FormatConfig`. P14/P15 are the editor contract dmd-fmt owes
> an LSP and does not have; both are cheap on a token spine with exact byte spans and expensive on
> an AST, which is an argument for the spine. P16 is the `q{ … }` / mixin question. P4–P7, P9 are
> token-changing and excluded — note how many of prettier's _options_ are options only because the
> decision is a rewrite in the first place.

---

## B. The preservation policy — what prettier keeps from the author

The most under-advertised part of prettier. A formatter that "reprints from the AST" in fact reads
the original text in at least six places to decide layout, and its docs apologize for four of them.

| #   | Decision                                                                                                                                                                     | Source                      | Verdict   |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------- | --------- |
| P17 | **The object source hint:** an object stays exploded iff the author put a newline between `{` and the first key. Long one-liners expand; short multi-liners never collapse   | [object.js][obj]            | **Adapt** |
| P18 | Prettier documents P17 as _a workaround, not a feature_, and calls it non-reversible formatting it wants to remove                                                           | [rationale][rationale]      | **Have**  |
| P19 | **Blank lines are preserved, then collapsed to one.** A run of empty lines between statements becomes exactly one                                                            | [statement-sequence][seq]   | **Have**  |
| P20 | Blank lines at the start and end of a block are deleted                                                                                                                      | [block.js][block]           | **Have**  |
| P21 | A file always ends with exactly one newline                                                                                                                                  | [block.js][block]           | **Have**  |
| P22 | **The decorator source hint:** decorators written inline stay inline; decorators written on their own line stay there — detected by "is there a newline after any decorator" | [decorators.js][dec]        | **Adopt** |
| P23 | …except on classes, which always get their decorators on their own line                                                                                                      | [decorators.js][dec]        | **Adapt** |
| P24 | **The interpolation source hint:** a `${…}` breaks only if the author already broke it; otherwise the template stays on one line at any length                               | [rationale][rationale]      | **N/A**   |
| P25 | A blank line _inside_ an argument list forces the whole list to explode, one argument per line                                                                               | [call-arguments][args]      | **Adopt** |
| P26 | A blank line after an array element / object property / class member is preserved as a hardline inside the broken list                                                       | [array][arr], [object][obj] | **Adopt** |
| P27 | A blank line after a call in a member chain is preserved, and forces the chain to break                                                                                      | [member-chain][chain]       | **Adopt** |
| P28 | Comment content is never reflowed or rewrapped — "we can't know how to format it"                                                                                            | [rationale][rationale]      | **Have**  |
| P29 | **Nothing is ever sorted or moved** — not imports, not object keys, not class members. Sorting is a transform, and unsafe                                                    | [rationale][rationale]      | **Have**  |
| P30 | Strings are never converted between quote styles and templates, never split across lines with `+`                                                                            | [rationale][rationale]      | **Have**  |
| P31 | Optional `{}` / `return` / `?:`↔`if` are never added or removed                                                                                                              | [rationale][rationale]      | **Have**  |

> **For D.** P17–P18 is the single most interesting row in the table: prettier's own team calls its
> source hint a wart it cannot remove, and it is _the same mechanism_ dmd-fmt v1 elevates to a
> policy. Two readings are available and both are defensible — either prettier's regret is evidence
> against v1, or prettier's inability to find a better heuristic in nine years is evidence for it.
> The difference in kind: prettier's hint is **one construct's exception** inside a reprinting
> formatter, so it reads as an inconsistency; in v1 it is **the rule everywhere**, so it does not.
> P22/P23 map exactly onto D's UDAs (`@attr`) and their placement before aggregates. P25–P27 are
> real, small, and adoptable now — the spine already knows where blank lines are.

---

## C. Vertical structure — blocks and statements

| #   | Decision                                                                                                                                                                                                  | Source                    | Verdict   |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------- | --------- |
| P32 | Statements in a block are separated by a hardline; the block never collapses onto one line at any width                                                                                                   | [statement-sequence][seq] | **Have**  |
| P33 | A non-empty block body is `{` + indent(hardline + body) + hardline + `}` — K&R braces, never Allman, not configurable                                                                                     | [block.js][block]         | **Adapt** |
| P34 | An **empty** block prints `{}` — except after `if`/`else`/`try`/labels, where a hardline is inserted between the braces                                                                                   | [block.js][block]         | **Adapt** |
| P35 | Empty statements (stray `;`) are dropped from statement sequences                                                                                                                                         | [statement-sequence][seq] | **Token** |
| P36 | `if (…)` condition: group(indent(softline + test) + softline) — the condition indents inside the parens when it breaks                                                                                    | [miscellaneous][misc]     | **Adopt** |
| P37 | …unless the condition is `!(…)` or `!!(…)` over a logical expression, which hugs — so that deleting the `!` doesn't change the indent                                                                     | [miscellaneous][misc]     | **Adapt** |
| P38 | A non-block `if` body is indented on its own line: `if (x)\n  foo();` — braces are never added, but the body never stays inline                                                                           | [clause.js][clause]       | **Adapt** |
| P39 | `else` attaches to the previous `}` with one space; after a non-block consequent it goes on its own line                                                                                                  | [if-statement][ifs]       | **Adopt** |
| P40 | `else if` is printed as a flat chain, not a nested indent                                                                                                                                                 | [clause.js][clause]       | **Have**  |
| P41 | A clause whose leading comment is on its own line gets a hardline before it — the comment forces the break                                                                                                | [clause.js][clause]       | **Adopt** |
| P42 | `for (init; test; update)` breaks all three clauses together, indented, or none                                                                                                                           | [for-statement][for]      | **Adopt** |
| P43 | `for (;;)` is the canonical empty-header spelling                                                                                                                                                         | [for-statement][for]      | **Token** |
| P44 | `switch` cases are hardline-separated; a `case` body that is a single block hugs (`case x: {`), otherwise it indents one level                                                                            | [switch-statement][sw]    | **Have**  |
| P45 | `switch` discriminant breaks like an `if` condition (P36)                                                                                                                                                 | [switch-statement][sw]    | **Adopt** |
| P46 | `try`/`catch`/`finally` are always brace-hugged on one line; the catch parameter only breaks if it carries comments                                                                                       | [try-statement][try]      | **Adopt** |
| P47 | `do { … } while (…)`: the `while` hugs the closing brace; a non-block body puts it on its own line                                                                                                        | [do-while][dowhile]       | **Adopt** |
| P48 | Multiple declarators in one declaration: **hardline** between them if any has an initializer, `line` if none — `let a, b, c;` may stay flat, `let a = 1, b = 2;` never does                               | [variable-decl][vardecl]  | **Adopt** |
| P49 | The first declarator is indented when there is more than one (ESLint `one-var` compatibility)                                                                                                             | [variable-decl][vardecl]  | **Adapt** |
| P50 | `return`/`throw` of a binary expression wraps in `ifBreak` parens: `return (\n  a &&\n  b\n);`                                                                                                            | [return-statement][ret]   | **Token** |
| P51 | `return` whose argument has a leading own-line comment gets hard parens and a hardline                                                                                                                    | [return-statement][ret]   | **Token** |
| P52 | Class body members are hardline-separated, blank lines preserved; interface/object-type members use `line` and can collapse                                                                               | [class-body][cbody]       | **Adapt** |
| P53 | The class head (`class X extends Y implements Z`) enters "group mode" only when there are ≥2 heritage clauses, comments, or a member-expression superclass; otherwise `extends` is glued on the same line | [class.js][cls]           | **Adopt** |
| P54 | When the class head breaks, the `{` moves to its own line (via `ifBreak` on the heritage group) — but _not_ for interfaces, reverted after user complaints                                                | [class.js][cls]           | **Adapt** |

> **For D.** P33/P34 are where v1 differs on purpose — D's house style is Allman, and v1 recomputes
> indentation without moving braces, so prettier's brace decisions are informative, not adoptable.
> P36/P37 and P42/P45 are the reusable shapes: a parenthesized header that indents its contents when
> it breaks. P37 is a genuinely good idea worth stealing — _make the layout invariant under adding a
> negation_ — and it generalizes: any wrapper that would change indentation when deleted is a
> stability hazard. P48 is directly applicable to D declaration lists. P52–P54 map onto D aggregate
> heads with base classes, interfaces, and `if (…)` template constraints, which is exactly where D
> declarations get long.

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
| P58 | A trailing comma is _emitted_ when broken and elided when flat, via `ifBreak(",")`                                                                           | [miscellaneous][misc]                              | **Token** |
| P59 | …except after a rest element (`...x`), where a trailing comma is illegal                                                                                     | [function-params][fparams]                         | **Token** |

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
> names, which is exactly the thing a D formatter must not grow.

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

> **For D.** P82/P83 are marked **Oracle** and this is the sharpest boundary the extraction found:
> deciding what to flatten needs operator precedence, and precedence needs the unary/binary
> distinction that the [dmd-fmt proposal][proposal] explicitly declined to solve at the token level.
> Everything else in this section is reachable. P96–P101 are the **UFCS pipeline decision** — the
> repo's own [functional-declarative guidelines][fdg] make `x.filter!(…).map!(…).array` the house
> idiom, so how a broken pipeline lays out is the most-seen formatting decision in this codebase.
> P98's capitalization heuristic maps onto D naming (types are capitalized, so `Type.make(x)` as a
> chain head is exactly the intended case). P93's short-key rule generalizes to any `name: value`
> or `name = value` where the name is too short for a wrap to read as one; that is worth stating as
> a width rule, not a key rule.

---

## F. Token-level normalization

Everything in this section is prettier _rewriting_ code, and is out of v1's scope. It is inventoried
anyway because it is the sharpest available statement of what "just formatting" does not mean.

| #    | Decision                                                                                                                         | Source                  | Verdict   |
| ---- | -------------------------------------------------------------------------------------------------------------------------------- | ----------------------- | --------- |
| P108 | **Quote choice by escape count:** pick the quote that needs fewer escapes; `singleQuote` only breaks ties                        | [print-string][pstr]    | **Token** |
| P109 | Escape sequences inside the string are preserved exactly — `"🙂"` never becomes `"\uD83D\uDE42"`, or the reverse                 | [make-string][mkstr]    | **Token** |
| P110 | Re-escaping is minimal: quotes of the _other_ kind are unescaped when switching quote styles                                     | [make-string][mkstr]    | **Token** |
| P111 | Numbers are lowercased; `+` and leading zeros are stripped from exponents; `1e0` → `1`; `.5` → `0.5`; `1.50` → `1.5`; `1.` → `1` | [print-number][pnum]    | **Token** |
| P112 | BigInt literals are lowercased                                                                                                   | [literal.js][lit]       | **Token** |
| P113 | Regex flags are sorted alphabetically                                                                                            | [literal.js][lit]       | **Token** |
| P114 | Object keys are quoted or unquoted per `quoteProps`, with a consistency rule: if one sibling needs quotes, all get them          | [key.js][key]           | **Token** |
| P115 | Key unquoting is refused wherever it would change semantics (TypeScript numeric keys, Flow, `--strictPropertyInitialization`)    | [key.js][key]           | **Token** |
| P116 | Redundant parentheses are dropped; needed ones are re-derived from precedence rather than preserved                              | [needs-parens][np]      | **Token** |
| P117 | Semicolons are inserted or removed per `semi`, including the defensive leading `;`                                               | [expression-stmt][expr] | **N/A**   |
| P118 | `directive` string literals ("use strict") keep their exact code units — quote swapping is refused when they contain quotes      | [literal.js][lit]       | **N/A**   |

> **For D.** The row that matters is **P116**. Prettier can drop parentheses because it reprints
> from an AST that knows precedence; a token-spine formatter cannot, and must not try. The rest of
> the section is a menu for a hypothetical `dmd-fmt --fix`-style pass that v1 deliberately does not
> have; if such a pass is ever built, P109/P110/P115 are the guard rails — **normalize spelling, never
> semantics** — and they are the reason prettier's string handling is 3 functions instead of 1.

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
> which v1 currently passes through untouched — re-indenting them is a small, safe, well-specified
> win, and P122 is the trap to avoid while doing it. P123's dangling-comment classification is the
> one piece of comment machinery a token-spine formatter still needs, because "the comment inside an
> otherwise-empty `()`" has no token to hang off. P125/P126 are worth internalizing generally: a
> comment is a layout input, not just content to relocate. P129 is a warning dmd-fmt inherits the
> moment it moves any line — `// dfmt off`-style range pragmas are safer than line-scoped ones, and
> that is already the design.

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

## What the extraction says

**1. A sixth of the surface is not layout at all.** 19 rows are marked **Token** and another 5
**N/A**; §F alone is eleven rows of pure rewriting. Prettier's identity as "the formatter with no options" depends on being
allowed to rewrite quotes, commas, semicolons, parentheses and number spelling; a formatter that
declines that — as v1 does, to keep verification tractable — cannot be prettier and should stop
being measured against it.

**2. Prettier's preservation is larger than advertised, and regretted.** Six independent source
hints (P17, P22, P24, P19, P25–P27) read the original text. The team documents P17 and P24 as
workarounds they want to remove and have not, in nine years, found a replacement for. This is the
strongest external evidence available for the v1 policy, and simultaneously the strongest argument
that the policy will be criticized in exactly the same terms.

**3. The expensive decisions cluster in three places** — call arguments (P60–P66), member chains
(P96–P101), assignment (P89–P95). Together they are ~1,300 lines of prettier's ~10,800-line JS
printer, roughly one line in eight, and they are the three shapes a D reader meets constantly:
lambda-taking calls, UFCS pipelines, and `auto x = …`. Everything else is comparatively mechanical.

**4. Two decisions are inadmissible on principle** — P68 and P69 hardcode third-party library names
(`it`, `describe`, `useEffect`) into a general-purpose formatter. They are the visible cost of
"opinionated": once the formatter owns the layout, every community with a bad-looking idiom
petitions for a special case.

**5. The `Doc` IR gap is small and specific.** `libs/dmd-fmt/src/sparkles/dmd_fmt/doc.d` already has `text`/`line`/`softline`/
`hardline`/`group`/`fill`/`indentBlock`/`alignBlock`/`ifBreak`/`lineSuffix`/`conditional`. Missing,
in the order the decisions above need them:

| Missing primitive                         | Needed by                          | Note                                                                                |
| ----------------------------------------- | ---------------------------------- | ----------------------------------------------------------------------------------- |
| **Group ids** + `indentIfBreak(id)`       | P90 (`fluid` assignment), P80, P54 | The single biggest gap: three of the best decisions are unimplementable without it. |
| `ifBreak` over **Docs**, not just strings | P50, P74, P81                      | Current signature takes `string broken, string flat`.                               |
| `willBreak` / `canBreak` inspection       | P57, P60, P64, P89, P101           | Every "does this sub-doc break?" guard.                                             |
| `removeLines`                             | P60, P63                           | Flattening a hugged signature.                                                      |
| `breakParent`                             | P22, P25, P101                     | Partly covered: `hardline` already forces enclosing groups.                         |
| `label`                                   | P96 (chain detection), P60         | Tagging a doc so a parent printer can branch on how a child printed.                |

Adding group ids and doc-valued `ifBreak` is the enabling change; the rest are conveniences.

## The shortlist

Twelve decisions, ordered by value per unit of work, that apply to D, survive the v1 policy, and do
not need an oracle we lack:

1. **P90 + group ids** — the `fluid` assignment layout, and the IR change that unlocks P80 and P54.
2. **P96–P101** — member-chain grouping, for UFCS pipelines. The most-seen layout in this codebase.
3. **P74** — concise fill for all-numeric array literals.
4. **P25–P27** — blank lines inside lists and chains as break forcers.
5. **P121 + P122** — re-indent DDoc `/** … */` comment bodies, with the hard-break trap handled.
6. **P36 + P37** — parenthesized-header indentation, invariant under adding a negation.
7. **P48** — hardline between declarators when any has an initializer.
8. **P93** — the short-name wrap rule, generalized off object keys.
9. **P75** — force-break an array of same-kind multi-element elements (the table heuristic).
10. **P61 + P62 + P65** — the refusal guards, so that any future hugging looks deliberate.
11. **P123 + P124** — dangling comments inside empty delimiters.
12. **P14 + P15** — range formatting and cursor tracking, the editor contract the spine makes cheap.

Deferred with reasons: P60–P66 (needs argument boundaries from the oracle), P82–P83 (needs
precedence, i.e. unary/binary disambiguation), everything in §F (token-changing), P68/P69
(inadmissible), P17 (already the policy, not a decision to re-take).

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
[fdg]: ../../guidelines/functional-declarative-programming-guidelines.md
