# Tree-sitter (C)

A parser-generator and a `pure C11` runtime that produces a **lossless concrete syntax tree** with a table-driven [GLR][general-parsing] algorithm, re-parses **incrementally** on every keystroke, and recovers from syntax errors — the parsing substrate behind Neovim, Helix, Zed, Emacs, and GitHub's in-browser code navigation.

| Field                     | Value                                                                                                                                           |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| Language                  | C11 runtime (`lib/src/`); Rust CLI/codegen (`crates/cli/`); `grammar.js` is JavaScript                                                          |
| License                   | MIT                                                                                                                                             |
| Repository                | [`tree-sitter/tree-sitter`][repo]                                                                                                               |
| Documentation             | [tree-sitter.github.io][docs]                                                                                                                   |
| Key authors               | Max Brunsfeld (creator, GitHub/Atom), Amaan Qureshi, and contributors                                                                           |
| Category                  | Incremental / IDE-grade parser generator                                                                                                        |
| Algorithm / grammar class | Table-driven **GLR** (generalized LR) over a context-free grammar; ambiguity resolved by static `prec` and runtime `prec.dynamic` / error cost  |
| Lexing model              | **Separate lexer**, generated alongside the parser; context-aware, on-demand, longest-match with lexical precedence; pluggable external scanner |
| Output                    | **Lossless** concrete syntax tree (every byte accounted for via `padding` + `size`); ref-counted `Subtree` nodes shared across edits            |
| Latest release            | `0.25.x` series (the runtime API is stable; see [Ecosystem & maturity](#ecosystem--maturity))                                                   |

> [!NOTE]
> This deep-dive surveys the **upstream C runtime and parser generator** (`tree-sitter/tree-sitter`). Individual language grammars (`tree-sitter-rust`, `tree-sitter-python`, …) and host-language bindings (Rust, Node, WASM, Go, Python, …) are separate repositories that link the same `lib/src/` runtime; they are referenced but not catalogued here.

---

## Overview

### What it solves

A compiler front-end parses a file once, from scratch, and aborts on the first syntax error. A text editor needs the opposite contract: it must parse a file that is **constantly half-typed**, re-parse it **on every keystroke** without redoing all the work, and still return a usable tree even while a brace is unbalanced or an expression is incomplete. Classic [LR][bottom-up] and [LL][top-down] generators (`bison`, `ANTLR`) were built for the batch contract; using them for editor tooling means re-running the whole parse per edit and getting nothing on a syntax error.

Tree-sitter targets the editor contract directly. From the project introduction ([`docs/src/index.md`][index-md]):

> _"Tree-sitter is a parser generator tool and an incremental parsing library. It can build a concrete syntax tree for a source file and efficiently update the syntax tree as the source file is edited. Tree-sitter aims to be:_
>
> - _**General** enough to parse any programming language_
> - _**Fast** enough to parse on every keystroke in a text editor_
> - _**Robust** enough to provide useful results even in the presence of syntax errors_
> - _**Dependency-free** so that the runtime library (which is written in pure C) can be embedded in any application"_

These four goals — **general, fast, robust, dependency-free** — are the design axes, and each maps to a concrete mechanism in `lib/src/`:

| Goal            | Mechanism                                                                                                            |
| --------------- | -------------------------------------------------------------------------------------------------------------------- |
| General         | [GLR][general-parsing] accepts any context-free grammar; conflicts are explored at runtime, not rejected at gen-time |
| Fast            | Incremental reuse of unchanged `Subtree`s (`ts_parser__reuse_node`); table-driven shift/reduce; inline small leaves  |
| Robust          | `ERROR` / `MISSING` nodes via a cost-minimizing recovery search (`ts_parser__recover`)                               |
| Dependency-free | `pure C11` runtime in `lib/src/`, no libc beyond `malloc`; embeddable in any host via the C ABI                      |

The output is a **concrete** syntax tree ([CST][concepts]), not an abstract one: it is _lossless_ — every byte of the source, including whitespace and comments, is accounted for, so the tree can be losslessly re-serialized and an editor can map any tree node back to an exact byte range and `(row, column)` point.

### Design philosophy

Three convictions, stated in the docs and visible in the source, shape everything:

1. **Parsing is a continuous, stateful service, not a one-shot function.** A `TSTree` is meant to be _edited and re-parsed_, not discarded. The advanced-parsing guide ([`docs/src/using-parsers/3-advanced-parsing.md`][advanced-md]) makes the workflow explicit: after an edit you call `ts_tree_edit()`, then _"you can call `ts_parser_parse` again, passing in the old tree. This will create a new tree that internally shares structure with the old tree."_ Structure sharing is not an optimization bolted on afterward — it is the central data-structure decision (the ref-counted `Subtree`, below).

2. **A grammar should be a program, not a static file.** The grammar is written in a JavaScript DSL (`grammar.js`) that _runs_ to emit a JSON grammar, which the generator compiles to a C parse table. This lets a grammar author use ordinary JavaScript — variables, functions, `Array.prototype.map` — to factor repetitive rules, instead of a fixed BNF dialect.

3. **The runtime owes nothing to its host.** The whole parsing engine is `pure C11` with no third-party dependencies, so it embeds equally in a Rust editor (Zed, Helix), a C one (Neovim), a Lisp one (Emacs), or a browser (compiled to WASM). The parser tables a grammar compiles to are _also_ just C — a generated `parser.c` — so a language is shipped as a tiny C object plus the shared runtime.

Tree-sitter's lineage is the incremental-LR research of **Tim Wagner & Susan Graham** — _"Practical Algorithms for Incremental Software Development Environments"_ ([Wagner's 1997 Berkeley thesis][wagner-thesis]) and _"Efficient and Flexible Incremental Parsing"_ — adapted to GLR and to the realities of a real-time editor. Within [this survey][index] it is the canonical **incremental, IDE-grade** data point; contrast it with the batch [LALR generators][bison-yacc] / [ANTLR][antlr], the [PEG][peg-packrat] approaches ([pest], [parser combinators][haskell-parsec]), and the SIMD data-parallel outlier [simdjson]. See the [comparison][comparison] for the cross-cutting view.

---

## How it works

### Core abstractions and types

The public C API ([`lib/include/tree_sitter/api.h`][api-h]) is small and opaque; almost all state lives behind four handle types:

| Concept            | Type / function                                            | Role                                                                             |
| ------------------ | ---------------------------------------------------------- | -------------------------------------------------------------------------------- |
| Language table     | `TSLanguage`                                               | The compiled parse table + lex modes for one language; an immutable, opaque blob |
| Parser             | `TSParser`                                                 | Stateful; holds a `TSLanguage`, a parse stack, a lexer, and reuse machinery      |
| Syntax tree        | `TSTree`                                                   | A whole parsed file; ref-counts the root `Subtree`; editable + re-parseable      |
| Node handle        | `TSNode`                                                   | A lightweight cursor into a `TSTree` (a `Subtree*` + byte/point offsets)         |
| Cursor             | `TSTreeCursor`                                             | Cheap stateful walk of a subtree (`ts_tree_cursor_goto_first_child`, …)          |
| Edit descriptor    | `TSInputEdit`                                              | `start_byte` / `old_end_byte` / `new_end_byte` + the three `TSPoint`s            |
| Streaming input    | `TSInput`                                                  | `read` callback + `payload` + `encoding` — parse from a rope, not just a string  |
| Query              | `TSQuery` / `TSQueryCursor`                                | A compiled S-expression pattern set + an execution cursor                        |
| Tree node (impl)   | `Subtree` / `SubtreeHeapData` (`lib/src/subtree.h`)        | The actual immutable, ref-counted CST node — _not_ exposed across the API        |
| Parse stack (impl) | `Stack` / `StackNode` / `StackVersion` (`lib/src/stack.c`) | The **graph-structured stack** that lets GLR fork on conflicts                   |

The entry sequence, from the getting-started guide ([`docs/src/using-parsers/1-getting-started.md`][using-md]):

```c
// Create a parser, assign a language, parse a string.
TSParser *parser = ts_parser_new();
ts_parser_set_language(parser, tree_sitter_json());
TSTree *tree = ts_parser_parse_string(
  parser,
  NULL,                 // no old tree → parse from scratch
  source_code,
  strlen(source_code)
);
TSNode root = ts_tree_root_node(tree);
```

Passing `NULL` as the second argument parses from scratch; passing a previously-edited `TSTree` is what triggers _incremental_ re-parsing (see [Error handling & recovery](#error-handling--recovery)). For input that is not a contiguous string — an editor's rope or gap buffer — `ts_parser_parse` takes a `TSInput` whose `read` callback hands back successive chunks, so the parser never needs the whole file materialized.

### The concrete syntax tree: `Subtree`

The CST node is the `Subtree`, a tagged union defined in [`lib/src/subtree.h`][subtree-h]. Its design carries three of the four goals (fast, robust, dependency-free) at once. Small, non-error leaf nodes are stored **inline** in the pointer-sized handle itself:

```c
// lib/src/subtree.h — the handle is a union of an inline payload and a heap pointer.
typedef union {
  SubtreeInlineData data;
  const SubtreeHeapData *ptr;
} Subtree;
```

The trick is documented in the header verbatim:

> _"The idea behind the layout of this struct is that the `is_inline` bit will fall exactly into the same location as the least significant bit of the pointer in `Subtree` … Because of alignment, for any valid pointer this will be 0, giving us the opportunity to make use of this bit to signify whether to use the pointer or the inline struct."_ — [`lib/src/subtree.h`][subtree-h]

Larger nodes (parents, errors, external tokens) use the heap form, `SubtreeHeapData`, whose first field is the **reference count** that powers structure sharing across edits:

```c
// lib/src/subtree.h — SubtreeHeapData (abridged)
typedef struct {
  volatile uint32_t ref_count;
  Length padding;          // bytes/rows/cols of leading whitespace+comments
  Length size;             // bytes/rows/cols of the node's own text
  uint32_t lookahead_bytes;
  uint32_t error_cost;     // accumulated recovery cost in this subtree
  uint32_t child_count;
  TSSymbol symbol;
  TSStateId parse_state;

  bool visible : 1;
  bool named : 1;
  bool extra : 1;
  bool fragile_left : 1;
  bool fragile_right : 1;
  bool has_changes : 1;    // overlaps an edit → cannot be reused as-is
  bool is_missing : 1;
  // ...
} SubtreeHeapData;
```

Two fields make the tree **lossless**: `padding` (the leading whitespace/comment extent, a `Length` carrying bytes, rows, and columns) and `size` (the node's own extent). Every byte of source is covered by exactly one node's `padding` or `size`, so positions are exact and the source can be reconstructed. The `ref_count` makes the tree **persistent**: when an edit re-parses a file, unchanged subtrees are not copied — their `ref_count` is bumped (`ts_subtree_retain`) and they are spliced into the new tree. This is why _"the new tree internally shares structure with the old tree."_

### The parse algorithm: table-driven GLR

Tree-sitter generates an **LR parse table** from the grammar, then drives it with a _generalized_ LR loop. Plain LR ([deterministic bottom-up][bottom-up]) requires the grammar to be conflict-free; GLR does not — when the table has a shift/reduce or reduce/reduce conflict, the parser **forks**, pursuing all interpretations in parallel and discarding the ones that hit dead ends. From the writing-the-grammar guide ([`docs/src/creating-parsers/3-writing-the-grammar.md`][grammar-write-md]), GLR _"can handle any context-free grammar,"_ including intentional ambiguities the author declares via the `conflicts` field.

Forking is made cheap by a **graph-structured stack** (GSS), the classic GLR data structure, implemented in [`lib/src/stack.c`][stack-c]. Rather than copy the whole stack per fork, the parser keeps a DAG of `StackNode`s; multiple parse "versions" (`StackVersion`) share a common prefix and diverge only at the suffix:

```c
// lib/src/stack.c (abridged) — many heads share one DAG of nodes.
typedef struct {
  Array(StackHead) heads;   // the live parse versions (forked branches)
  StackNodeArray node_pool;
  StackNode *base_node;
} Stack;

struct StackNode {
  StackLink links[MAX_LINK_COUNT];   // up to MAX_LINK_COUNT predecessors
  short unsigned int link_count;
  // ...
};
```

Each `StackLink` carries a `Subtree` and points at a predecessor node; because a node can have multiple predecessors, _two diverging parses that later reach the same state re-merge_ (`ts_stack_merge`), collapsing the exponential fan-out back down. This is what keeps GLR's worst case bounded in practice for real grammars.

When two parses produce competing trees for the same span, Tree-sitter must pick one. `ts_parser__select_tree` ([`lib/src/parser.c`][parser-c]) is the arbiter, and its priority order is the whole ambiguity story in one function:

```c
// lib/src/parser.c — ts_parser__select_tree (abridged)
// The decision is based on the trees' error costs (if any), their dynamic
// precedence, and finally, as a default, by a recursive comparison of the trees' symbols.
static bool ts_parser__select_tree(TSParser *self, Subtree left, Subtree right) {
  if (ts_subtree_error_cost(right) < ts_subtree_error_cost(left)) return true;   // fewer errors wins
  if (ts_subtree_error_cost(left)  < ts_subtree_error_cost(right)) return false;

  if (ts_subtree_dynamic_precedence(right) > ts_subtree_dynamic_precedence(left)) return true;  // prec.dynamic
  if (ts_subtree_dynamic_precedence(left)  > ts_subtree_dynamic_precedence(right)) return false;
  // ... falls back to a recursive structural comparison
}
```

So a _genuine_ ambiguity (one the grammar declares via `conflicts`) is resolved at runtime by **(1) lowest error cost, (2) highest `prec.dynamic`, (3) a deterministic structural tiebreak** — never by silently dropping one reading at generation time. Conflicts the author did _not_ intend remain a generation-time error, forcing them to either refactor or annotate with static `prec` / `prec.left` / `prec.right` (resolved when the table is built) or list the rule pair in `conflicts` (deferred to GLR + `prec.dynamic`).

### Lexing: a separate, context-aware, longest-match lexer

Tree-sitter is **not** scannerless. The grammar compiles to _two_ artifacts — a parser table and a lexer — and lexing is interleaved with parsing on demand. From [`docs/src/creating-parsers/3-writing-the-grammar.md`][grammar-write-md]:

> _"Tree-sitter's parsing process is divided into two phases: parsing … and lexing — the process of grouping individual characters into the language's fundamental tokens. … Tree-sitter performs lexing on-demand, during the parsing process. At any given position in a source document, the lexer only tries to recognize tokens that are valid at that position in the document."_

That _context-aware_ on-demand lexing is the first tiebreaker; when several tokens still match, the documented resolution order is:

1. **Context** — only tokens valid in the current parse state are even attempted.
2. **Lexical precedence** — explicit `token(prec(n, …))` values bias the choice.
3. **Longest match** — _"the token that matches the longest sequence of characters."_
4. **Specificity** — a `String` literal token beats a `RegExp` token.
5. **Grammar order** — earlier-declared token wins, as a final tiebreak.

The generated lexer ([`lib/src/lexer.c`][lexer-c]) tracks position precisely: `ts_lexer__advance` consumes one UTF-8 (or UTF-16/custom) code point, updating bytes, rows, and columns, and a `skip` flag marks the consumed text as _padding_ (whitespace/`extras`) rather than token content — which is how the `padding`/`size` split on every `Subtree` gets populated. The `word` token enables the **keyword-extraction optimization**: _"If you specify a word token in your grammar, Tree-sitter will find the set of keyword tokens that match strings also matched by the word token,"_ letting it _"generate a smaller, simpler lexing function"_ and parse identifiers vs. keywords in one pass.

### The grammar DSL (`grammar.js`)

A grammar is a JavaScript module exporting `grammar({ name, rules, … })`. Each rule is a function of `$` (the grammar's symbols) returning a rule expression built from combinators. The core vocabulary, from [`docs/src/creating-parsers/2-the-grammar-dsl.md`][grammar-dsl-md]:

| Combinator                 | Meaning                                                                                |
| -------------------------- | -------------------------------------------------------------------------------------- |
| `seq(a, b, …)`             | match `a` then `b` then … in order                                                     |
| `choice(a, b, …)`          | match exactly one alternative                                                          |
| `repeat(r)` / `repeat1(r)` | zero-or-more / one-or-more occurrences                                                 |
| `optional(r)`              | zero or one occurrence                                                                 |
| `prec(n, r)`               | static numeric precedence to resolve an LR conflict (compile time)                     |
| `prec.left` / `prec.right` | associativity for same-precedence conflicts (prefer ending earlier / later)            |
| `prec.dynamic(n, r)`       | precedence applied **at runtime** by `ts_parser__select_tree` for genuine ambiguities  |
| `token(r)`                 | collapse `r` into a single lexical token; combine with `prec` for _lexical_ precedence |
| `field(name, r)`           | label the matched child with a field name (queried later as `name:`)                   |
| `alias(r, name)`           | expose `r` under a different node name (named or anonymous)                            |

```js
// A precedence-climbing arithmetic grammar fragment (grammar.js style).
binary_expression: $ => choice(
  prec.left(2, seq($.expression, '*', $.expression)),
  prec.left(1, seq($.expression, '+', $.expression)),
),
```

Top-level grammar fields tune the generator: `extras` (tokens — usually whitespace and comments — that may appear _anywhere_, captured as a node's `padding`), `word` (the keyword-extraction token), `conflicts` (rule pairs whose LR conflict is _intended_ and deferred to GLR), `externals` (tokens produced by a hand-written external scanner), `inline` (rules to splice away), and `supertypes` (abstract groupings like `expression`). The DSL author writes ordinary JavaScript, so a 200-rule grammar can be generated with loops and helper functions rather than copy-paste.

### External scanners: escaping the regular languages

Some tokens are not regular and cannot be expressed as a regex: significant indentation, heredocs, Ruby percent-strings, raw-string delimiters that must balance. For these, a grammar declares an `externals` array and ships a hand-written C **external scanner**. From [`docs/src/creating-parsers/4-external-scanners.md`][scanner-md]:

> _"Many languages have some tokens whose structure is impossible or inconvenient to describe with a regular expression. Some examples: … Indent and dedent tokens in Python … Heredocs in Bash and Ruby … Percent strings in Ruby."_

The scanner implements five C functions named `tree_sitter_<lang>_external_scanner_{create,destroy,scan,serialize,deserialize}`. `scan` receives a `TSLexer*` exposing `lookahead` (_"the current next character … as a 32-bit unicode code point"_), `advance`, `mark_end` (_"a function for marking the end of the recognized token"_), and `eof`. Crucially, the scanner's state must be **serializable**: `serialize` copies the scanner's state into a byte buffer that is stored _on the `Subtree`_ (`ExternalScannerState` in `subtree.h`), and `deserialize` restores it. The docs spell out why:

> _"The data that this function writes will ultimately be stored in the syntax tree so that the scanner can be restored to the right state when handling edits or ambiguities."_ — [`docs/src/creating-parsers/4-external-scanners.md`][scanner-md]

This is the non-obvious cost of combining a _stateful_ hand-written lexer with _incremental_ and _GLR_ parsing: because the parser may rewind to an old position (incremental reuse) or fork (GLR), the scanner cannot keep mutable global state — it must be snapshot-and-restore at every external token.

### The S-expression query language

Once a tree exists, syntax-aware tooling (highlighting, indentation, code navigation, structural search) is expressed as **queries** — S-expression patterns matched against the CST. From [`docs/src/using-parsers/queries/1-syntax.md`][query-md], a pattern _"consists of a pair of parentheses containing … the node's type, and optionally, a series of other S-expressions that match the node's children."_ Captures are introduced with `@name`; fields with `name:`; wildcards with `_`; the synthetic `(ERROR)` and `(MISSING)` nodes are themselves queryable.

```query
; Capture a function's name field and its body.
(function_definition
  name: (identifier) @function.name
  body: (block) @function.body)

; Predicate: only match if the identifier text is exactly "self".
((identifier) @keyword
 (#eq? @keyword "self"))
```

A key architectural decision: **predicates are not evaluated by the C runtime.** Operators like `#eq?`, `#not-eq?`, `#match?`, `#any-of?`, `#is?`, and `#set!` are parsed and exposed in structured form, but the _filtering is the host's job_. From [`docs/src/using-parsers/queries/3-predicates-and-directives.md`][predicates-md]:

> _"Predicates and directives are not handled directly by the Tree-sitter C library. They are just exposed in a structured form so that higher-level code can perform the filtering."_

This keeps the runtime dependency-free (no regex engine in `lib/src/`) while letting each binding implement predicates in its host language. The query engine itself is compiled (`ts_query_new`) into an automaton and executed with a `ts_query_cursor_new` / `ts_query_cursor_exec` / `ts_query_cursor_next_match` cursor, so a query set runs in a single tree traversal.

---

## Algorithm & grammar class

- **Formalism.** A **context-free grammar** authored in a JavaScript DSL, compiled to an **LR(1)-style parse table** and driven by a **generalized LR (GLR)** loop. The generator builds the deterministic table where it can and falls back to runtime forking only at declared conflict points. Per the Wikipedia summary, _"Tree-sitter uses a GLR parser, a type of LR parser."_
- **Grammar class accepted.** Effectively **all context-free grammars** — GLR is not restricted to LALR(1) or LR(1) the way [`bison`][bison-yacc]/[yacc][bison-yacc] are. Ambiguity is a _feature_ you opt into via `conflicts`, not a generation error you must eliminate. (Contrast with [PEG][peg-packrat], which is unambiguous-by-construction via ordered `choice`, at the cost of being unable to express genuine ambiguity.)
- **Ambiguity handling, three layers:**
  1. **Static, at generation time** — `prec(n)`, `prec.left`, `prec.right` resolve shift/reduce and reduce/reduce conflicts when the table is built.
  2. **Runtime, declared** — `conflicts` defers a conflict to GLR; competing parses run in parallel on the graph-structured stack.
  3. **Runtime, scored** — `ts_parser__select_tree` picks the survivor by **error cost**, then **`prec.dynamic`**, then a deterministic structural comparison.
- **Lexing class.** Tokens are **regular** (string/regex) by default, recognized by a separate, generated, context-aware lexer with longest-match + lexical-precedence resolution; **non-regular** tokens escape to a hand-written external scanner with serializable state.

## Interface & composition model

- **Grammar expression.** An **external DSL** (`grammar.js`) that is a _JavaScript program_ emitting a JSON grammar — combinators (`seq`, `choice`, `repeat`, …) rather than raw BNF, so grammars are generated with host-language code. This sits between a pure [parser-combinator library][haskell-parsec] (combinators _are_ the runtime) and a [classic `.y` generator][bison-yacc] (a static declarative file). Tree-sitter's combinators are _staged_: they run once at generation time to build a table, not per parse.
- **Codegen.** `tree-sitter generate` (Rust CLI, `crates/cli/`) reads `grammar.js`, computes the LR item sets, and emits a single `src/parser.c` containing the parse table, lex modes, and symbol metadata as static C arrays. A language ships as that generated `parser.c` (plus an optional `scanner.c`) compiled against the shared runtime.
- **Host-language integration.** The runtime is a **C ABI**; every binding (Rust, Node, WASM, Python, Go, Swift, …) is a thin FFI shell over the same `lib/src/`. The tree itself is queried through lightweight `TSNode` handles and `TSTreeCursor`s; nodes are _not_ heap objects per node, so walking is cheap and allocation-light.
- **CST construction.** The tree is built **bottom-up** by reductions: each `reduce` action pops `N` child `Subtree`s off the graph-structured stack and packs them into a parent `SubtreeHeapData`. Visibility flags (`visible`, `named`) and `field`/`alias` metadata (the `production_id`) decide what a host sees as a _named_ node, an _anonymous_ node, or a hidden one — so the same physical tree exposes a clean named view and a complete anonymous one.
- **Composition across languages.** `ts_parser_set_included_ranges()` restricts a parse to specific byte ranges, the mechanism for **language injection** (e.g. SQL inside a Python string, JS inside HTML): parse the host language, find the embedded ranges via a query, then parse those ranges with a second grammar. This is composition at the _tree_ level, not the grammar level — grammars themselves do not import one another.

## Performance

- **Time complexity.** A from-scratch parse is **linear** in input size for the common LR case; GLR forking is bounded by the graph-structured stack's sharing/merging, so the pathological exponential GLR blow-up is avoided on real grammars (the merge in `ts_stack_merge` collapses re-converging branches). The headline number is the _incremental_ case: re-parsing after a small edit costs work proportional to the **edited region plus the path from the edit to the root**, not the whole file — which is what makes "parse on every keystroke" viable.
- **Incremental reuse mechanics.** `ts_parser__reuse_node` ([`lib/src/parser.c`][parser-c]) walks the _old_ tree alongside the new parse and reuses any subtree it can. A node is reused only if it passes every gate — the disqualifiers, verbatim from the source, are:

  ```c
  // lib/src/parser.c — ts_parser__reuse_node (abridged): reasons a node CANNOT be reused
  if (ts_subtree_has_changes(result))      reason = "has_changes";        // overlaps the edit
  else if (ts_subtree_is_error(result))    reason = "is_error";
  else if (ts_subtree_missing(result))     reason = "is_missing";
  else if (ts_subtree_is_fragile(result))  reason = "is_fragile";         // sat on a conflict boundary
  else if (/* contains a changed included range */) reason = "contains_different_included_range";
  ```

  An edit first marks the touched path with `has_changes` (via `ts_tree_edit`); everything _not_ so marked is a reuse candidate. `error`/`missing`/`fragile` nodes are deliberately _not_ reused, so a corrected typo re-parses cleanly rather than re-inheriting a stale error.

- **Allocation behaviour.** Small leaf nodes are stored **inline** in the `Subtree` handle (no heap node at all); the parser pools and recycles `Subtree`s (`SubtreePool` with `free_trees`) and stack nodes (`node_pool`) to avoid per-node `malloc`. Reused subtrees are shared by **ref-count bump**, not copied. The result is that an incremental re-parse allocates roughly in proportion to the _new_ nodes only.
- **Zero-copy / streaming.** The `TSInput` `read` callback lets the parser consume a rope/gap-buffer in chunks — the whole file need never be a contiguous buffer, and the editor's existing text representation is read in place. Trees themselves are persistent and copy-on-write across edits.
- **SIMD / data-parallelism.** **None** — and this is a deliberate non-goal. Unlike [`simdjson`][simdjson], which extracts parallelism from the _bytes_, Tree-sitter's win is _temporal_ (reuse across time/edits), not _spatial_ (parallel over the buffer). A single keystroke touches a tiny region, so there is nothing to vectorize; the bottleneck is redundant work, which incrementality, not SIMD, removes.
- **Published benchmarks.** The project does not publish a canonical benchmark table in-repo; the operative empirical claim is the design goal itself — _"Fast enough to parse on every keystroke in a text editor"_ — validated by adoption in latency-sensitive editors (Neovim, Zed, Helix) that re-parse on input. Treat specific µs figures from third-party blogs as indicative, not authoritative.

## Error handling & recovery

This is where Tree-sitter most diverges from a batch parser, and it is the "robust" goal made concrete.

- **Error representation.** Two synthetic node kinds appear in the tree, both queryable and both flagged on the `Subtree`:
  - **`ERROR`** — a node wrapping source the parser could not fit into the grammar (its `symbol == ts_builtin_sym_error`; the leaf form even stores the offending `lookahead_char`).
  - **`MISSING`** — a _zero-width_ node the parser **inserted** to satisfy the grammar (e.g. a `;` you haven't typed yet), flagged `is_missing`. The host detects them via `ts_node_is_error`, `ts_node_is_missing`, and `ts_node_has_error`.
- **Recovery strategy — cost-minimizing search.** When the parser enters the error state, `ts_parser__recover` ([`lib/src/parser.c`][parser-c]) chooses between two strategies, documented verbatim in the source:

  > _"When the parser is in the error state, there are two strategies for recovering with a given lookahead token: 1. Find a previous state on the stack in which that lookahead token would be valid. Then, create a new stack version that is in that state again. This entails popping all of the subtrees that have been pushed onto the stack since that previous state, and wrapping them in an ERROR node. 2. Wrap the lookahead token in an ERROR node, push that ERROR node onto the stack, and move on to the next lookahead token, remaining in the error state."_ — [`lib/src/parser.c`][parser-c]

  The choice is **scored**: each recovery candidate is charged a cost, and the parser keeps the cheapest. The cost constants live in [`lib/src/error_costs.h`][error-costs-h] in their entirety:

  ```c
  // lib/src/error_costs.h — the complete cost model
  #define ERROR_STATE 0
  #define ERROR_COST_PER_RECOVERY 500
  #define ERROR_COST_PER_MISSING_TREE 110
  #define ERROR_COST_PER_SKIPPED_TREE 100
  #define ERROR_COST_PER_SKIPPED_LINE 30
  #define ERROR_COST_PER_SKIPPED_CHAR 1
  ```

  A recovery that _skips a character_ costs 1; skipping a whole _line_ costs 30; _inserting_ a missing tree costs 110; entering a fresh recovery costs 500. Because GLR keeps multiple stack versions alive, recovery is itself a _forked search_: the parser explores several repairs in parallel and `ts_parser__select_tree` keeps the one with the **smallest total error cost** — so the recovered tree is the one that "explains" the broken input by discarding/inserting the _least_ text.

- **Incremental reparsing = error handling.** The incremental path and the error path are the same machinery: an edit marks `has_changes`, the parser re-parses the dirty region reusing clean subtrees, and if the edit leaves the file syntactically broken it produces `ERROR`/`MISSING` nodes — but the _unbroken_ parts of the tree remain intact and usable. `ts_tree_get_changed_ranges` then reports exactly which byte ranges changed between the old and new tree, so an editor can re-highlight only what moved.
- **IDE-readiness.** This is the _defining_ dimension for Tree-sitter and it scores at the top: a half-typed file always yields a complete tree (errors localized to `ERROR`/`MISSING` nodes), positions are exact down to the column, edits are O(edit) not O(file), and the changed-range delta drives incremental re-highlighting. No other subject in this catalog combines all four. (Batch generators like [`bison`][bison-yacc] abort on the first error; [parser combinators][haskell-parsec] and [PEG][peg-packrat] give a single error position, not a recovered tree.)

## Ecosystem & maturity

- **Origin & adoption.** Created by **Max Brunsfeld** at GitHub for the **Atom** editor, first released in **2018** ([Wikipedia][wikipedia]). His Strange Loop 2018 talk, _["Tree-sitter — a new parsing system for programming tools"][strangeloop]_, presents the algorithm and its use in Atom and GitHub.com.
- **Who uses it in production.** Tree-sitter is now the de-facto editor parsing substrate. Wikipedia lists official editor integrations in _"GNU Emacs, Neovim, Lapce, Zed, Helix, and Atom,"_ and notes that _"GitHub uses Tree-sitter to support in-browser symbolic code navigation in Git repositories."_ It also underpins difftastic (structural diffing), many LSP/highlighting tools, and a growing set of code-analysis/AI pipelines.
- **Grammars.** Over a hundred maintained grammars exist (`tree-sitter-rust`, `-python`, `-javascript`, `-go`, `-c`, `-cpp`, …), each a small repo shipping a `grammar.js` + generated `parser.c`.
- **Bindings / ports.** First-class bindings for Rust, Node.js, WASM (browser), Python, Go, Swift, Java, Kotlin, OCaml, Ruby, Perl, Lua, C#, and Zig — all over the same C runtime. Pure-language _re-implementations_ of the runtime also exist (e.g. Go ports), trading the C dependency for less battle-testing.
- **Tooling.** The `tree-sitter` CLI does codegen, an interactive `playground` (WASM in the browser), corpus-based `test`, `highlight`, and `query` evaluation. The query DSL is its own ecosystem (`highlights.scm`, `injections.scm`, `locals.scm` conventions shared across editors).
- **Stability.** The C runtime API (`tree_sitter/api.h`) is stable and versioned; the project is on the `0.25.x` line at the time of writing and is maintained by an active org (`tree-sitter`) plus a large grammar-maintainer community. It is mature, widely embedded, and under continuous development.

---

## Strengths

- **Purpose-built for editors:** incremental re-parse, error recovery, and a lossless CST in one system — the only catalogued subject that delivers all three.
- **Robust by default:** a half-typed or broken file _always_ yields a usable tree with errors localized to `ERROR`/`MISSING` nodes; the cost-model recovery keeps repairs minimal.
- **General:** GLR accepts any context-free grammar, so genuinely ambiguous constructs are expressible (declared `conflicts` + `prec.dynamic`) rather than contorted away.
- **Dependency-free, embeddable runtime:** `pure C11`, no third-party deps, compiles to WASM — embeds in editors written in any language.
- **Ergonomic grammar authoring:** `grammar.js` is a real program, so large grammars are generated with loops/helpers; precedence and associativity are first-class.
- **Lossless & position-exact:** `padding`/`size` cover every byte; every node maps to an exact byte range and `(row, column)` point.
- **Powerful, host-agnostic queries:** the S-expression query language drives highlighting, indentation, injection, and code navigation portably across editors.
- **External scanners** cleanly handle indentation/heredocs/balanced delimiters that no CFG/regex can.

## Weaknesses

- **No semantics, no validation:** Tree-sitter produces a _syntax_ tree only — it does no name resolution, typing, or semantic checking; that is the host's job.
- **Grammar authoring has a learning curve:** taming LR conflicts with `prec`/`conflicts`/`prec.dynamic` requires understanding the LR machinery the DSL nominally hides; subtle conflicts surface only at generation time.
- **External scanners are fiddly and unsafe:** hand-written C with a hard _serializable-state_ contract (for incrementality + GLR); a stateful-scanner bug corrupts incremental reuse in non-obvious ways.
- **CST, not AST:** the concrete tree includes every token and is shaped by the grammar's factoring; consumers often want an abstracted view and must build it (helped by `field`/`alias`/`supertypes`, but not eliminated).
- **GLR has tail risks:** pathological grammars _can_ still fork heavily; ambiguity management is the author's responsibility.
- **Predicate evaluation is the host's problem:** keeping the runtime dependency-free means every binding re-implements `#match?`/`#eq?` filtering, so query semantics can drift between hosts.
- **No SIMD/data-parallel speedups:** for a _cold_ full parse of a huge file, a data-parallel approach like [`simdjson`][simdjson] is far faster; Tree-sitter's advantage is incremental, not throughput.

## Key design decisions and trade-offs

| Decision                                                             | Rationale                                                                                            | Trade-off                                                                                    |
| -------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| **Table-driven GLR** (not deterministic LR/LALR)                     | Accept _any_ CFG; defer real ambiguities to runtime forking instead of rejecting the grammar         | More runtime machinery (graph-structured stack); pathological grammars can fork heavily      |
| **Lossless CST** with `padding`/`size` on every node                 | Exact positions, re-serializable tree, whitespace/comments preserved for editor tooling              | Bigger trees than an AST; consumers must abstract the concrete shape themselves              |
| **Ref-counted, persistent `Subtree`s**                               | Unchanged subtrees are _shared_ across edits — the core enabler of fast incremental re-parse         | Immutability + ref-counting overhead; careful retain/release discipline in the runtime       |
| **Incremental reuse keyed on `has_changes`/`is_error`/`is_fragile`** | Re-parse only the dirty path; never reuse error/missing/fragile nodes so fixes re-parse cleanly      | A correct edit near an old error re-parses a wider region than strictly necessary            |
| **Cost-model error recovery** (`error_costs.h`)                      | Always return a tree; the _cheapest_ repair best explains the broken input                           | Recovery is a forked search (cost in time); the "right" repair is heuristic, not guaranteed  |
| **Separate, context-aware lexer** (not scannerless)                  | Longest-match + lexical precedence + on-demand lexing; smaller tables; keyword extraction            | Two artifacts to reason about; lexer/parser interaction is a source of subtle grammar bugs   |
| **External scanners with serializable state**                        | Handle non-regular tokens (indentation, heredocs) that no CFG/regex can express                      | Hand-written C; the serialize/deserialize contract is mandatory and easy to get subtly wrong |
| **`grammar.js` JavaScript DSL** (not a static `.y` file)             | Grammars are _programs_ — generated with loops/helpers; combinators read clearly                     | Requires a JS runtime to generate; the staging (gen-time vs parse-time) confuses newcomers   |
| **Predicates evaluated by the host, not the C runtime**              | Keep the runtime `pure C11` and dependency-free (no regex engine inside `lib/src/`)                  | Every binding re-implements `#match?`/`#eq?`; query semantics can drift across hosts         |
| **No SIMD / data-parallelism**                                       | The win is _temporal_ (reuse across keystrokes), not _spatial_; a keystroke has nothing to vectorize | A cold full parse of a huge file is slower than a data-parallel parser like `simdjson`       |

---

## Sources

- [`tree-sitter/tree-sitter` — GitHub repository][repo]
- [Tree-sitter documentation site][docs]
- [`docs/src/index.md` — the four design goals (general / fast / robust / dependency-free)][index-md]
- [`docs/src/using-parsers/1-getting-started.md` — `TSParser`/`TSTree`/`TSNode`/`TSLanguage`, parse flow][using-md]
- [`docs/src/using-parsers/3-advanced-parsing.md` — `ts_tree_edit`, `TSInputEdit`, incremental reparse, included ranges][advanced-md]
- [`docs/src/creating-parsers/2-the-grammar-dsl.md` — `seq`/`choice`/`repeat`/`prec`/`token`/`field`/`externals`/`conflicts`][grammar-dsl-md]
- [`docs/src/creating-parsers/3-writing-the-grammar.md` — lexing phases, token resolution order, keyword extraction, GLR conflicts][grammar-write-md]
- [`docs/src/creating-parsers/4-external-scanners.md` — external scanner functions, `TSLexer`, serializable state][scanner-md]
- [`docs/src/using-parsers/queries/1-syntax.md` — S-expression query syntax, captures, `ERROR`/`MISSING`][query-md]
- [`docs/src/using-parsers/queries/3-predicates-and-directives.md` — predicates handled by the host, not the C library][predicates-md]
- [`lib/include/tree_sitter/api.h` — the public C API surface][api-h]
- [`lib/src/subtree.h` — `Subtree`/`SubtreeHeapData`, inline-bit trick, ref-counting, `padding`/`size`][subtree-h]
- [`lib/src/parser.c` — `ts_parser__reuse_node`, `ts_parser__select_tree`, `ts_parser__recover`][parser-c]
- [`lib/src/stack.c` — graph-structured stack, `StackVersion` forking/merging][stack-c]
- [`lib/src/lexer.c` — the generated separate lexer, position tracking][lexer-c]
- [`lib/src/error_costs.h` — the complete error-recovery cost model][error-costs-h]
- [Tim A. Wagner, _Practical Algorithms for Incremental Software Development Environments_ (UC Berkeley, 1997)][wagner-thesis]
- [Max Brunsfeld, _Tree-sitter — a new parsing system for programming tools_ (Strange Loop 2018)][strangeloop]
- [Tree-sitter (parser generator) — Wikipedia (creation, adoption, GLR, license)][wikipedia]
- Related deep-dives: [general/GLR parsing theory][general-parsing] · [bottom-up/LR][bottom-up] · [PEG/packrat][peg-packrat] · [Bison/yacc][bison-yacc] · [ANTLR][antlr] · [simdjson][simdjson] · [the comparison][comparison]

<!-- References -->

[repo]: https://github.com/tree-sitter/tree-sitter
[docs]: https://tree-sitter.github.io/tree-sitter/
[index-md]: https://github.com/tree-sitter/tree-sitter/blob/master/docs/src/index.md
[using-md]: https://github.com/tree-sitter/tree-sitter/blob/master/docs/src/using-parsers/1-getting-started.md
[advanced-md]: https://github.com/tree-sitter/tree-sitter/blob/master/docs/src/using-parsers/3-advanced-parsing.md
[grammar-dsl-md]: https://github.com/tree-sitter/tree-sitter/blob/master/docs/src/creating-parsers/2-the-grammar-dsl.md
[grammar-write-md]: https://github.com/tree-sitter/tree-sitter/blob/master/docs/src/creating-parsers/3-writing-the-grammar.md
[scanner-md]: https://github.com/tree-sitter/tree-sitter/blob/master/docs/src/creating-parsers/4-external-scanners.md
[query-md]: https://github.com/tree-sitter/tree-sitter/blob/master/docs/src/using-parsers/queries/1-syntax.md
[predicates-md]: https://github.com/tree-sitter/tree-sitter/blob/master/docs/src/using-parsers/queries/3-predicates-and-directives.md
[api-h]: https://github.com/tree-sitter/tree-sitter/blob/master/lib/include/tree_sitter/api.h
[subtree-h]: https://github.com/tree-sitter/tree-sitter/blob/master/lib/src/subtree.h
[parser-c]: https://github.com/tree-sitter/tree-sitter/blob/master/lib/src/parser.c
[stack-c]: https://github.com/tree-sitter/tree-sitter/blob/master/lib/src/stack.c
[lexer-c]: https://github.com/tree-sitter/tree-sitter/blob/master/lib/src/lexer.c
[error-costs-h]: https://github.com/tree-sitter/tree-sitter/blob/master/lib/src/error_costs.h
[wagner-thesis]: https://www2.eecs.berkeley.edu/Pubs/TechRpts/1997/CSD-97-946.pdf
[strangeloop]: https://www.thestrangeloop.com/2018/tree-sitter---a-new-parsing-system-for-programming-tools.html
[wikipedia]: https://en.wikipedia.org/wiki/Tree-sitter_(parser_generator)
[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[general-parsing]: ./theory/general-parsing.md
[bottom-up]: ./theory/bottom-up.md
[top-down]: ./theory/top-down.md
[peg-packrat]: ./theory/peg-packrat.md
[simdjson]: ./simdjson.md
[bison-yacc]: ./bison-yacc.md
[antlr]: ./antlr.md
[haskell-parsec]: ./haskell-parsec.md
[pest]: ./pest.md
