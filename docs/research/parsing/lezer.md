# Lezer (JavaScript / CodeMirror)

An **incremental [GLR][general-parsing] parser** written in TypeScript for [CodeMirror 6][codemirror], designed to keep a syntax tree current as an editor buffer changes and to stay usable in the face of syntax errors — a second, browser-native incremental engine that is _"hugely inspired by [tree-sitter]"_ but trades tree-sitter's C11 runtime and lossless CST for a compact JavaScript tree tuned for size and edit-time reuse.

| Field                     | Value                                                                                                                        |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Language                  | TypeScript (compiles to JS/ESM); runtime split across `@lezer/lr` (parser) + `@lezer/common` (tree)                          |
| License                   | MIT                                                                                                                          |
| Repository                | [`lezer-parser/lr`][repo] (GitHub mirror) — canonical home moved to [`code.haverbeke.berlin/lezer/lr`][home]                 |
| Documentation             | [lezer.codemirror.net][docs]                                                                                                 |
| Key authors               | **Marijn Haverbeke** (author of [CodeMirror][codemirror], ProseMirror, Acorn) — `LICENSE` © 2018                             |
| Category                  | Incremental / IDE-grade parser (in-browser)                                                                                  |
| Algorithm / grammar class | Table-driven **incremental GLR**; tables generated ahead of time by `@lezer/generator`                                       |
| Lexing model              | Generated DFA `TokenGroup`s + hand-written `ExternalTokenizer`s; `@context` `ContextTracker`s for stateful/contextual lexing |
| Output                    | Compact `Tree` / `TreeBuffer` **blob tree** — nodes are "just blobs with a start, end, tag, and set of child nodes"          |
| Incrementality model      | `TreeFragment` reuse across edits — old-tree regions fed back as reusable subtrees via the `goto` table                      |
| Latest release            | `@lezer/lr` `1.4.8` (2026-01-25); on-disk parser-table format `File.Version` `14`                                            |

> [!NOTE]
> This deep-dive surveys the **runtime** packages `@lezer/lr` (`src/parse.ts`, `src/stack.ts`, `src/token.ts`, at SHA `ed59b8b`) and `@lezer/common` (`src/tree.ts`, `src/parse.ts`, at SHA `d87b56c`). The **grammar compiler** `@lezer/generator` (which turns a `.grammar` file into the `states`/`data`/`goto` tables the runtime consumes) and individual language packages (`@lezer/javascript`, `@lezer/python`, …) are separate repositories, referenced but not catalogued here. Lezer is consumed almost exclusively through [CodeMirror 6][codemirror]'s language support; it is the incremental analogue of [tree-sitter] for the JS/browser world.

---

## Overview

### What it solves

Lezer targets the **editor contract**, not the batch contract: parse a file that is _constantly half-typed_, re-parse it after every edit reusing prior work, and always return a usable tree even while the syntax is broken (the [incremental / IDE-grade][incremental] problem this survey's theory page frames). The `@lezer/lr` README states the mandate verbatim ([`README.md`][lr-readme]):

> _"Lezer ("reader" in Dutch, pronounced pretty much as laser) is an incremental GLR parser intended for use in an editor or similar system, which needs to keep a representation of the program current during changes and in the face of syntax errors."_

It is the parsing substrate under CodeMirror 6, where the syntax tree drives highlighting, indentation, folding, and structural selection — all of which re-derive on each keystroke, so the parse must be cheap to redo.

### Design philosophy

The README's second paragraph is the whole trade-off in one sentence ([`README.md`][lr-readme]):

> _"It prioritizes speed and compactness (both of parser table files and of syntax tree) over having a highly usable parse tree—trees nodes are just blobs with a start, end, tag, and set of child nodes, with no further labeling of child nodes or extra metadata."_

Three convictions follow, and each maps to a concrete mechanism below:

1. **Compactness is a first-class goal, on par with speed.** A CodeMirror grammar ships as a serialized table decoded from a string (`decodeArray`), and the output tree packs runs of small nodes into flat `Uint16Array` buffers (`TreeBuffer`) rather than allocating a heap object per node. Both the table _and_ the tree are optimized for size because they live in a browser tab.
2. **The tree is a minimal blob; usability is the consumer's job.** Unlike [tree-sitter]'s `field(name, …)`/`alias` labels, a Lezer node carries only `{type, from, to, children}`. Navigation, absolute positions, and parent pointers are computed lazily by cursor/`SyntaxNode` wrappers ([`tree.ts`][common-tree]) — a deliberately light [red/green][incremental-rg] split.
3. **Parsing is a resumable, incremental service.** A parse is a `PartialParse` you `advance()` piece-by-piece, seeded with `TreeFragment`s from the previous tree so that unchanged regions are spliced in rather than re-parsed. CodeMirror runs it in time-sliced chunks so a large file never blocks the UI thread.

Lezer credits its lineage openly ([`README.md`][lr-readme]): _"This project was hugely inspired by [tree-sitter]."_ It inherits tree-sitter's core bet — GLR + incremental subtree reuse for the editor — but re-implements it in TypeScript with an ahead-of-time table generator, a different stack/tree representation, and a fragment-based (rather than ref-count-based) reuse scheme. Within [this survey][umbrella] it is the second **incremental, IDE-grade** data point; read it against [tree-sitter] (its inspiration), [Roslyn][roslyn] and [rust-analyzer] ([red/green][incremental-rg] + query graphs), and the [rustc query system][rustc]. See the [comparison][comparison] for the cross-cutting view and [`theory/incremental.md`][incremental] for the shared vocabulary.

---

## How it works

### Core packages and types

Lezer is deliberately split into two runtime layers. `@lezer/common` owns the **tree data structure** and the parser abstractions (`Parser`, `PartialParse`, `TreeFragment`); `@lezer/lr` owns the **LR engine** that produces those trees.

| Concept               | Type / function (`file`)                                        | Role                                                                                |
| --------------------- | --------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Parse tables          | `LRParser` (`lr/src/parse.ts`)                                  | Immutable `states` / `data` / `goto` typed arrays generated by `@lezer/generator`   |
| In-progress parse     | `Parse implements PartialParse` (`lr/src/parse.ts`)             | Holds the live stacks, token cache, fragment cursor; driven by `advance()`          |
| Parse stack (impl)    | `Stack` (`lr/src/stack.ts`)                                     | One GLR parse "version": state stack + shared output buffer + score                 |
| Token cache           | `TokenCache` / `InputStream` (`lr/src/token.ts`)                | On-demand, context-masked tokenizing with per-tokenizer caching                     |
| Syntax tree           | `Tree` (`common/src/tree.ts`)                                   | A node: `type`, `children`, relative `positions`, `length`, optional per-node props |
| Packed leaf run       | `TreeBuffer` (`common/src/tree.ts`)                             | A flat `Uint16Array` of `(type, start, end, endIndex)` quads — many small nodes     |
| Reuse unit            | `TreeFragment` (`common/src/parse.ts`)                          | A region of an old tree, offset into the new document, reusable in the next parse   |
| Navigation (red side) | `TreeCursor` / `TreeNode` / `BufferNode` (`common/src/tree.ts`) | Lazy cursors computing absolute positions + parent links over the blob tree         |

The public entry point is `Parser.parse(input, fragments?, ranges?)` ([`common/src/parse.ts`][common-parse]); passing `fragments` from a prior tree is what makes the parse **incremental**, and passing `ranges` restricts it to byte ranges (the hook for mixed-language parsing). `input` is an `Input` interface (`chunk`/`read`), so Lezer parses CodeMirror's rope directly rather than a materialized string.

### The compact syntax tree: `Tree` + `TreeBuffer`

A `Tree` node stores only its `type`, its `children`, the children's `positions` (offsets **relative** to the node's own start), and its total `length` ([`common/src/tree.ts`][common-tree]):

```ts
// @lezer/common — tree.ts (constructor, abridged)
export class Tree {
  constructor(
    readonly type: NodeType,
    readonly children: readonly (Tree | TreeBuffer)[],
    readonly positions: readonly number[], // relative offsets
    readonly length: number,
    props?: readonly [NodeProp<any> | number, any][],
  ) {
    /* ... */
  }
}
```

The compactness win is `TreeBuffer`: instead of one `Tree` object per small node, a whole run of small nodes is packed into a single flat `Uint16Array` of `(type, start, end, endIndex)` quads, in prefix order ([`common/src/tree.ts`][common-tree]):

> _"Tree buffers contain (type, start, end, endIndex) quads for each node. In such a buffer, nodes are stored in prefix order (parents before children, with the endIndex of the parent indicating which children belong to it)."_ — [`common/src/tree.ts`][common-tree]

`buildTree` (`common/src/tree.ts`, driven from the parser's `stackToTree`) collects the parser's output and promotes a subtree to a heap `Tree` object only when it exceeds `maxBufferLength` (default `DefaultBufferLength = 1024`); everything smaller lives in a buffer. It also **balances** the children (`balanceRange`) so a long flat list becomes a shallow, `O(lg n)`-navigable tree.

This is the load-bearing contrast with [tree-sitter]. Tree-sitter avoids per-leaf heap objects by storing a small leaf **inline in a pointer-sized `Subtree` union** (the `is_inline` bit trick). Lezer instead **batches runs of small nodes into one shared `Uint16Array`** — the same "no heap object per leaf" goal reached by packing rather than pointer-punning. And because the tree is _relative-positioned_ and _label-free_, it is the [green half][incremental-rg] of a red/green split: absolute positions and parent pointers are recomputed on demand by `TreeCursor`/`TreeNode`/`BufferNode`, exactly as Roslyn's red nodes wrap green nodes.

### The parse algorithm: table-driven GLR with forking stacks

`@lezer/generator` compiles the grammar to an LR parse table ahead of time; `@lezer/lr` drives it with a **generalized** LR loop. When the table has a conflict, the parser does not reject the grammar — it **forks**, running competing interpretations in parallel and discarding dead ends. The live parse versions are just an array of `Stack`s on the `Parse` object, advanced together in `advance()` ([`lr/src/parse.ts`][lr-parse]):

```ts
// @lezer/lr — parse.ts, advance() (abridged): every live stack is stepped to the next pos
for (let i = 0; i < stacks.length; i++) {
  let stack = stacks[i];
  for (;;) {
    if (stack.pos > pos) newStacks.push(stack);
    else if (this.advanceStack(stack, newStacks, stacks)) continue;
    else {
      /* stopped → error recovery */
    }
    break;
  }
}
```

Forking happens in `advanceStack`: when a state offers several actions, all but the last get a `stack.split()` copy ([`lr/src/parse.ts`][lr-parse]). Lezer's stack representation differs from tree-sitter's textbook **graph-structured stack**, and the difference is the interesting part. The _output buffer_ is graph-structured — split stacks share buffer history through a `parent` pointer and a `bufferBase` offset, so a fork copies no output — while the (usually shallow) _state stack_ is sliced. The `split()` comment states the economics ([`lr/src/stack.ts`][lr-stack]):

> _"Split the stack. Due to the buffer sharing and the fact that `this.stack` tends to stay quite shallow, this isn't very expensive."_ — [`lr/src/stack.ts`][lr-stack]

To stop the fan-out from exploding, `advance()` **prunes and merges**: stacks in the same state (`sameState`) or that have run without splitting for a while are collapsed, keeping the higher-`score` one (`pushStackDedup`), and the whole set is capped at `Rec.MaxStackCount = 12` (_"the maximum number of non-recovering stacks to explore … to avoid getting bogged down with exponentially multiplying stacks in ambiguous content"_, [`lr/src/parse.ts`][lr-parse]). Genuine ambiguity is scored by the stack `score`, which accumulates **dynamic precedence** (`parser.dynamicPrecedence(type)` added on reduce, [`lr/src/stack.ts`][lr-stack]) and error penalties — the counterpart to tree-sitter's `ts_parser__select_tree` cost ordering.

### Incremental reuse: `TreeFragment`s

This is Lezer's answer to "reuse the tree", and it is architecturally distinct from tree-sitter's ref-counted-`Subtree` reuse. The unit of reuse is a **`TreeFragment`**: a slice of a previous tree, tagged with the `offset` between tree coordinates and the _updated_ document ([`common/src/parse.ts`][common-parse]):

> _"Tree fragments are used during incremental parsing to track parts of old trees that can be reused in a new parse. … Use the static `applyChanges` method to update fragments for document changes."_ — [`common/src/parse.ts`][common-parse]

The editor-side flow is two static methods on `TreeFragment`:

- **`TreeFragment.addTree(tree)`** turns a freshly parsed tree into a fragment set.
- **`TreeFragment.applyChanges(fragments, changes)`** takes the old fragments plus the document's `ChangedRange`s (`fromA`/`toA` → `fromB`/`toB`) and _"removing or splitting fragments as necessary to remove edited ranges, and adjusting offsets for fragments that moved"_ ([`common/src/parse.ts`][common-parse]). Fragments touching an edit are dropped; the rest are re-offset into the new coordinate space, and a `minGap` (default 128) suppresses tiny useless fragments.

> [!IMPORTANT]
> The prompt located `TreeFragment` in `@lezer/common`'s `src/tree.ts`; in the tree as checked out at SHA `d87b56c` it lives in **`@lezer/common/src/parse.ts`** (`applyChanges`/`addTree` at lines 69–100). `src/tree.ts` holds the `Tree`/`TreeBuffer` types it reuses. Both are cited accordingly.

Inside the engine, `Parse` builds a `FragmentCursor` over those fragments — but only when the input is large enough to be worth it: `this.stream.end - from > parser.bufferLength * 4` ([`lr/src/parse.ts`][lr-parse]), so a tiny buffer parses from scratch. Then, before spending any real work at each position, `advanceStack` asks the cursor for a reusable node and, if the current state's `goto` table accepts that node type, splices it in whole with `stack.useNode` ([`lr/src/parse.ts`][lr-parse]):

```ts
// @lezer/lr — parse.ts, advanceStack (abridged): reuse an old subtree if the goto table allows it
for (let cached = this.fragments.nodeAt(start); cached;) {
  let match = this.parser.nodeSet.types[cached.type.id] == cached.type
    ? parser.getGoto(stack.state, cached.type.id) : -1
  if (match > -1 && cached.length &&
      (!strictCx || (cached.prop(NodeProp.contextHash) || 0) == cxHash)) {
    stack.useNode(cached, match)      // reuse whole subtree, jump pos to its end
    return true
  }
  // else: descend into the node's first child and retry
  ...
}
```

Two guards make the reuse **safe** across an edit, both visible in `FragmentCursor.nodeAt` and `cutAt` ([`lr/src/parse.ts`][lr-parse]):

- **Lookahead margin.** A node is reusable only if the tokenizer's lookahead did not reach past the fragment's safe end: `!lookAhead || end + lookAhead < this.fragment.to`. Lezer stores that lookahead as a per-node prop (`NodeProp.lookAhead`) but _only when it exceeds 25 code units_ (`Lookahead.Margin = 25`), because every token is assumed to look at least that far ([`lr/src/stack.ts`][lr-stack]) — a compactness/safety trade the way tree-sitter uses `lookahead_bytes`.
- **Context hash.** If the grammar uses a strict `ContextTracker`, a node may be reused only if it was parsed in the same context (`NodeProp.contextHash` must match) — _"used to limit reuse of contextual nodes"_ ([`common/src/tree.ts`][common-tree]).

So where tree-sitter marks a `has_changes` path and reuses any untouched ref-counted `Subtree`, Lezer feeds whole old subtrees back into the LR automaton _as if they were terminals_, gated on `goto`-acceptance, lookahead, and context — the classic [Wagner & Graham][incremental-wagner] "nonterminals as input" reuse, realized through fragments.

### Tokenizers: generated, contextual, and external

Lezer is **not** scannerless. Lexing is on-demand and context-masked: each parse state carries a `TokenizerMask`, and `TokenCache.getActions` only runs the tokenizers reachable from the current state ([`lr/src/token.ts`][lr-token], [`lr/src/parse.ts`][lr-parse]). Three tokenizer kinds coexist:

- **`TokenGroup`** — the common case: a generated DFA encoded in the parser's `tokenData`, interpreted by `readToken` via a binary search over character-range edges, with `overrides` resolving lexical precedence from a `tokenPrecTable` ([`lr/src/token.ts`][lr-token]).
- **`ExternalTokenizer`** — a hand-written function (`token(input, stack)`) for tokens no DFA can express, declared `@external tokens` in the grammar. Options mirror tree-sitter's escape hatch: `contextual` (result can't be cached between actions at the same position), `fallback`, `extend` ([`lr/src/token.ts`][lr-token]).
- **`ContextTracker`** — Lezer's answer to tree-sitter's _serializable external-scanner state_. Instead of asking a stateful scanner to `serialize`/`deserialize` its bytes onto every node, Lezer threads an **immutable context value** through the parse, updated on `shift`/`reduce`/`reuse`, and hashes it into `NodeProp.contextHash` so incremental reuse can check it (`@context exportName from "module"`, [`lr/src/parse.ts`][lr-parse]):

  > _"Context trackers are used to track stateful context (such as indentation in the Python grammar, or parent elements in the XML grammar) needed by external tokenizers. … Context values should be immutable, and can be updated (replaced) on shift or reduce actions."_ — [`lr/src/parse.ts`][lr-parse]

The `strict` flag on a `ContextTracker` (default true) says a node may be reused only in the same context — the storage/reuse trade that the serializable-scanner-state contract makes explicit in tree-sitter is here folded into an immutable, hashable value.

### Error recovery: scored insert / delete / force-reduce

When no stack can advance and the parser is not in `strict` mode (which throws `SyntaxError` instead), `advance()` enters recovery for `Rec.Distance` steps and `runRecovery` tries several repairs per stuck stack, each charging a **penalty to the stack `score`** ([`lr/src/parse.ts`][lr-parse], [`lr/src/stack.ts`][lr-stack]):

```ts
// @lezer/lr — stack.ts, the complete recovery cost model
export const enum Recover {
  Insert = 200, // recoverByInsert: fabricate a missing token/rule
  Delete = 190, // recoverByDelete: skip an unexpected token
  Reduce = 100, // forceReduce: close an open production early
  MaxNext = 4,
  MaxInsertStackDepth = 300,
  DampenInsertStackDepth = 120,
  MinBigReduction = 2000,
}
```

`recoverByInsert` splits the stack, pushes an `Err` (`Term.Err = 0`) node and a fabricated shift, and docks `Recover.Insert`; `recoverByDelete` stores an `Err` node over the skipped token and docks `Recover.Delete`; `forceReduce` closes an unfinished production and docks `Recover.Reduce` ([`lr/src/stack.ts`][lr-stack]). Because GLR keeps several stacks alive, recovery is a **forked, scored search**: the surviving stacks are sorted by `score` and pruned to a budget (`newStacks.sort((a, b) => b.score - a.score)`, [`lr/src/parse.ts`][lr-parse]), so the tree that "explains" the broken input with the fewest, cheapest repairs wins. Adjacent `Err` nodes are merged in `storeNode` to avoid error spam. This is precisely tree-sitter's cost-model recovery — the numbers differ, and the sign is flipped (Lezer maximizes a `score` reduced by penalties; tree-sitter minimizes an `error_cost`), but the design is the same: never fail, always return a tree, minimize the repair.

---

## Algorithm & grammar class

- **Formalism.** A context-free grammar compiled **ahead of time** by `@lezer/generator` into LR parse tables (`states`, `data`, `goto` typed arrays), driven at runtime by a **generalized LR (GLR)** loop. The runtime only interprets tables — it never sees the grammar source (contrast [tree-sitter], where `grammar.js` is a JS program run at generation time; Lezer's grammar is a declarative `.grammar` file).
- **Grammar class accepted.** Effectively **all context-free grammars**: conflicts are not generation errors but runtime forks over multiple `Stack`s. Ambiguity is opt-in and scored by **dynamic precedence** (`dynamicPrecedences`, added to `Stack.score` on reduce) plus static token precedence (`tokenPrecTable`). (Contrast [PEG][peg-packrat], unambiguous-by-construction and unable to express genuine ambiguity.)
- **Ambiguity handling.** (1) static token precedence during lexing (`overrides`/`tokenPrecTable`); (2) runtime forking on table conflicts across the live stacks; (3) scored selection by `Stack.score` (dynamic precedence + recovery penalties), with equal-state merge (`sameState`/`pushStackDedup`) collapsing re-converging branches and a hard `MaxStackCount = 12` cap.
- **Lexing class.** Tokens are **regular** (generated DFA `TokenGroup`s) by default; **non-regular** tokens escape to hand-written `ExternalTokenizer`s, and **stateful** context (indentation, XML nesting) is carried by an immutable `ContextTracker` rather than mutable scanner state.

## Interface & composition model

- **Grammar expression.** An **external, declarative DSL** — a `.grammar` file compiled offline by `@lezer/generator` to serialized tables the browser decodes with `decodeArray`. This sits opposite [tree-sitter]'s `grammar.js`-as-a-program: Lezer's grammar is static data, not code, which keeps the shipped runtime tiny.
- **Host integration.** Lezer is a library, not a codegen-into-C toolchain. A language package exports an `LRParser` built from the generated tables; CodeMirror wraps it in a `Language`/`LRLanguage` and time-slices the `PartialParse`. Node navigation is through `TreeCursor`/`SyntaxNode` — lightweight cursors over the blob tree, not heap objects per node.
- **Tree construction.** Built **bottom-up** by reductions: each `reduce` pops frames off the state stack, writes a node record into the shared output buffer (`storeNode`), and `stackToTree` → `buildTree` packs the buffer into balanced `Tree`/`TreeBuffer`s. Visibility is coarse — anonymous/repeat terms exist, but there is **no per-child `field` labeling** (the README's "no further labeling of child nodes").
- **Composition across languages.** `ranges` on `Parser.parse` restricts a parse to byte ranges, and a `ParseWrapper` (`configure({wrap})`) injects mixed-language parsing via `@lezer/common`'s `parseMixed` and the `NodeProp.mounted` prop ([`common/src/tree.ts`][common-tree]) — e.g. CSS/JS inside HTML. Composition is at the _tree_ level (mounted overlays), as in tree-sitter's included-ranges injection, not at the grammar level.

## Performance

- **Time complexity.** A from-scratch parse is **linear** for the deterministic LR case; GLR forking is bounded by same-state merge (`pushStackDedup`) and the `MaxStackCount = 12` / `MinBufferLengthPrune` caps, so ambiguous content cannot blow up unboundedly. The headline is the incremental case: an edit re-parses the changed region and splices unchanged `TreeFragment` subtrees, so work scales with the **edit plus a fragment splice**, not the file — the [Wagner & Graham `O(t + s·lg N)`][incremental-wagner] shape, adapted to GLR.
- **Incremental reuse mechanics.** `FragmentCursor.nodeAt` walks the old tree in document order and hands `advanceStack` a reuse candidate; `stack.useNode` jumps `pos` to the node's end and records it as a reused child (buffer `size == -1`). Reuse is gated on **goto-acceptance**, **non-zero length**, **lookahead margin** (`end + lookAhead < fragment.to`), and **context hash** — see [Incremental reuse](#incremental-reuse-treefragments).
- **Compactness.** Both artifacts are size-tuned: parser tables are decoded from strings (`decodeArray`), and the tree packs small-node runs into `Uint16Array` `TreeBuffer`s, promoting to heap `Tree`s only past `DefaultBufferLength = 1024`, then balancing. This is the "compactness" half of the README's stated priority, and the reason Lezer nodes are label-free blobs.
- **Time-slicing.** The parse is a `PartialParse` with `advance()` / `stopAt(pos)` / `parsedPos`, so CodeMirror runs it in bounded work chunks off the critical path and can `stopAt` the visible viewport, deferring the rest.
- **SIMD / data-parallelism.** **None** — like [tree-sitter], the win is _temporal_ (reuse across edits), not _spatial_ (vectorized over bytes as in [simdjson]). A keystroke touches a tiny region; there is nothing to vectorize.
- **Published benchmarks.** No canonical benchmark table ships in-repo; the operative claim is the README's stated priority ("speed and compactness"), validated by CodeMirror 6's adoption in latency-sensitive, in-browser editors. Treat third-party µs figures as indicative.

## Incrementality model

This is the extra spine dimension for the [incremental cluster][incremental], and where Lezer's design personality is clearest against its siblings:

- **Unit of reuse — a fragment/subtree, not a ref-counted node.** [tree-sitter] reuses individual **ref-counted `Subtree`s** whose reuse is gated on per-node flags (`has_changes`/`is_error`/`is_fragile`). Lezer reuses **`TreeFragment` regions**: `applyChanges` first computes _which spans of the old tree survive the edit_, then `FragmentCursor` offers subtrees from those spans back to the LR automaton, each accepted only if the current `goto` accepts its type. Reuse is decided at parse time by the automaton, not pre-marked on the tree.
- **No persistent ref-counting; fragments are recomputed per edit.** There is no `ref_count` on a Lezer node. Old trees stay alive because JS holds them; `applyChanges` produces a _fresh_ fragment array each edit by slicing/offsetting the old one. The immutable `Tree`/`TreeBuffer` values are freely shared (structural sharing), but the bookkeeping is the fragment list, not per-node counts.
- **Versus [Roslyn][roslyn]/[rust-analyzer] red/green.** Lezer's `Tree`/`TreeBuffer` are effectively **green** (immutable, relative-positioned, label-free), and `TreeCursor`/`TreeNode`/`BufferNode` are the **red** wrappers computing absolute positions and parents lazily — the same split Roslyn documents. But Lezer has **no query graph**: it reuses the _tree_, not the _computation_. Downstream analyses (highlighting, indentation) are re-run by CodeMirror over the new tree; there is no [salsa][rust-analyzer]-style memoized `K → V` layer. On the [incremental.md two-column map][incremental], Lezer is "tree reuse: yes; computation reuse: no", exactly like tree-sitter.
- **Contextual reuse is hashed, not serialized.** The stateful-lexer problem (indentation, nesting) that tree-sitter solves with serializable external-scanner state, Lezer solves with an immutable `ContextTracker` value hashed into `NodeProp.contextHash`; strict trackers refuse to reuse a node parsed in a different context.

## Error handling & recovery

- **Error representation.** A single error term, `Term.Err = 0`, marks both skipped input and inserted-repair points; adjacent `Err` nodes are merged in `storeNode` to keep the tree readable ([`lr/src/stack.ts`][lr-stack]). There is no separate `MISSING` node kind as in tree-sitter — insertions and deletions both surface as `Err`.
- **Recovery strategy — scored forked search.** `runRecovery` explores `recoverByInsert` (penalty `Recover.Insert = 200`), `recoverByDelete` (`Recover.Delete = 190`), and `forceReduce` (`Recover.Reduce = 100`) across the live stacks, keeping the highest-`score` survivors and pruning the rest ([Error recovery](#error-recovery-scored-insert--delete--force-reduce)). Because recovery reuses the same GLR stack machinery, it is a parallel search for the cheapest repair — the same shape as tree-sitter's `error_costs.h` cost model, with different constants.
- **`strict` escape hatch.** `configure({strict: true})` makes the parser `throw new SyntaxError("No parse at " + pos)` instead of recovering ([`lr/src/parse.ts`][lr-parse]) — useful for a batch/validation use where a tree-from-garbage is not wanted.
- **IDE-readiness.** High, and by design co-equal with [tree-sitter]: a half-typed file yields a complete tree with errors localized to `Err` nodes, positions are exact (relative offsets resolved on the red side), edits are `O(edit + splice)` via fragments, and CodeMirror re-derives highlighting from the changed regions. The gap versus tree-sitter is not robustness but _tree richness_ (label-free blobs) and _reach_ (JS-only runtime).

## Ecosystem & maturity

- **Origin & authorship.** Created by **Marijn Haverbeke** — author of [CodeMirror][codemirror], ProseMirror, and the Acorn JS parser — as the parsing layer for CodeMirror 6; `LICENSE` is © 2018. The canonical repository moved from GitHub to [`code.haverbeke.berlin/lezer/lr`][home] (the [`lezer-parser/lr`][repo] GitHub mirror remains).
- **Adoption.** Lezer is the syntax engine of **CodeMirror 6**, which is widely embedded (in-browser editors, docs sites, notebook UIs, playgrounds). It is reached almost entirely through CodeMirror's language packages rather than used standalone.
- **Grammars.** A family of official language packages (`@lezer/javascript`, `@lezer/python`, `@lezer/css`, `@lezer/html`, `@lezer/rust`, `@lezer/json`, …), each shipping a compiled `LRParser` plus CodeMirror integration. Grammars are authored in a `.grammar` file and compiled with `@lezer/generator`.
- **Stability.** `@lezer/lr` is on the `1.4.x` line (`1.4.8`, 2026-01-25); the on-disk table format is versioned (`File.Version = 14`, checked at `LRParser` construction) so a runtime rejects mismatched generated tables. The `CHANGELOG` shows steady, small bug-fix releases around tree-corruption and reuse edge cases — a mature, actively maintained engine.
- **Scope limit.** The runtime is **JavaScript-only**. Unlike [tree-sitter]'s `pure C11` core with bindings for a dozen host languages, Lezer runs where JS runs; embedding it in a native editor means embedding a JS engine.

---

## Strengths

- **Purpose-built for the browser editor:** incremental re-parse, scored error recovery, and a compact tree in one JS package, time-sliceable via `PartialParse` — the CodeMirror 6 substrate.
- **Compact by design:** string-decoded parse tables + `TreeBuffer`-packed trees keep both artifacts small enough to ship to a browser tab; the README makes compactness a co-equal goal with speed.
- **General:** GLR accepts any CFG; genuine ambiguity is expressible and scored (dynamic precedence) rather than contorted away.
- **Robust:** a broken file always yields a complete tree with errors localized to `Err` nodes; recovery minimizes the repair via the scored forked search.
- **Clean incrementality primitive:** `TreeFragment.applyChanges` is a small, well-defined API for mapping edits to reuse — easy to reason about and to drive from an editor.
- **Contextual lexing without mutable scanner state:** immutable `ContextTracker` values (hashed for reuse) handle indentation/nesting more safely than a serialize/deserialize scanner contract.
- **Mixed-language parsing:** `ranges` + `parseMixed` + `NodeProp.mounted` overlay grammars (JS-in-HTML, etc.) at the tree level.

## Weaknesses

- **Minimal node metadata:** nodes are label-free blobs (`{type, from, to, children}`) — no per-child `field` names, so consumers do more work to interpret structure than with tree-sitter's `field`/`alias`.
- **JavaScript-only runtime:** no `pure C11` core and no multi-language bindings; embedding outside a JS environment is impractical.
- **Parse-only, no query/computation reuse:** Lezer reuses the tree but not analyses; there is no [salsa][rust-analyzer]-style memoized query graph — the host re-derives everything downstream.
- **Grammar authoring has an LR learning curve:** taming conflicts with precedence/ambiguity declarations requires understanding the LR/GLR machinery the DSL nominally hides (shared with tree-sitter).
- **External tokenizers / context trackers are fiddly:** hand-written scanning plus the immutable-context + `contextHash` contract for correct incremental reuse is subtle.
- **No SIMD / data-parallel throughput:** for a cold full parse of a huge document, a data-parallel design like [simdjson] is far faster; Lezer's advantage is incremental, not throughput.

## Key design decisions and trade-offs

| Decision                                                       | Rationale                                                                                              | Trade-off                                                                                      |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------- |
| **Ahead-of-time table generation** (`.grammar` → typed arrays) | Ship a tiny runtime + string-decoded tables to the browser; no grammar interpreter at parse time       | Grammar is static data, not a program — less generative than [tree-sitter]'s `grammar.js`      |
| **Compact blob tree** (`Tree` + packed `TreeBuffer`)           | Minimize memory in a browser tab; batch small nodes into one `Uint16Array`, balance for `O(lg n)`      | Label-free nodes — consumers get less usable structure than a `field`-labeled CST              |
| **Relative positions + red/green cursors**                     | Immutable green nodes are freely shareable; absolute positions/parents computed lazily on the red side | Every navigation recomputes offsets/parents instead of reading them off the node               |
| **`TreeFragment` reuse** (fragments, not ref-counts)           | A small, editor-friendly `applyChanges` API; reuse decided by the automaton via `goto`                 | Fragments recomputed per edit; no persistent ref-count sharing across many tree versions       |
| **GLR with shared-buffer forking stacks**                      | Accept any CFG; forks copy no output (shared buffer), merge on equal state, cap at 12                  | More machinery than deterministic LR; ambiguous content still needs pruning heuristics         |
| **Immutable `ContextTracker` + `contextHash`**                 | Stateful lexing (indentation/nesting) without serialize/deserialize; hash gates safe reuse             | Author must model context as an immutable value and provide a correct hash                     |
| **Scored insert/delete/force-reduce recovery**                 | Always return a tree; parallel stacks find the cheapest repair by `score`                              | Constants are heuristic; recovery is a forked search (time), the "right" repair not guaranteed |
| **JavaScript-only runtime**                                    | Runs everywhere CodeMirror runs; no native toolchain to embed a language                               | No C core / cross-language bindings — unusable outside a JS host                               |
| **Parse only, no query graph**                                 | Keep the engine small and focused; leave analysis caching to the host                                  | No computation reuse — unlike [rust-analyzer], downstream analyses re-run each edit            |

---

## Sources

- [`@lezer/lr` — repository (GitHub mirror)][repo] and [canonical home][home]
- [`@lezer/common` — repository][common-repo]
- [Lezer documentation site][docs] · [CodeMirror 6][codemirror]
- [`@lezer/lr` `README.md` — "incremental GLR parser", speed/compactness priority, "hugely inspired by tree-sitter"][lr-readme]
- [`lr/src/parse.ts` — `LRParser`, `Parse.advance`/`advanceStack`, `FragmentCursor`, reuse via `useNode`, `MaxStackCount`, `ContextTracker`, `strict`][lr-parse]
- [`lr/src/stack.ts` — `Stack` split/reduce/shift, `useNode`, `Recover` cost model, dynamic precedence, `Lookahead.Margin = 25`][lr-stack]
- [`lr/src/token.ts` — `TokenGroup` DFA, `ExternalTokenizer`, `InputStream`, context-masked lexing][lr-token]
- [`lr/src/constants.ts` — `Action`/`StateFlag`/`ParseState` bitfields, `File.Version = 14`][lr-constants]
- [`common/src/tree.ts` — `Tree`, `TreeBuffer` quads, `buildTree`/`balanceRange`, `NodeProp.lookAhead`/`contextHash`/`mounted`, `DefaultBufferLength = 1024`][common-tree]
- [`common/src/parse.ts` — `TreeFragment.addTree`/`applyChanges`, `ChangedRange`, `PartialParse`, `Parser`][common-parse]
- Theory: [incremental & query-based parsing][incremental] ([node reuse / Wagner & Graham][incremental-wagner]; [red/green trees][incremental-rg]) · [general/GLR][general-parsing] · [bottom-up/LR][bottom-up]
- Related deep-dives: [tree-sitter] (Lezer's inspiration) · [rust-analyzer] · [Roslyn][roslyn] · [`rustc` queries][rustc] · [PEG/packrat][peg-packrat] · [simdjson] · [the comparison][comparison]

<!-- References -->

[repo]: https://github.com/lezer-parser/lr
[home]: https://code.haverbeke.berlin/lezer/lr
[common-repo]: https://github.com/lezer-parser/common
[docs]: https://lezer.codemirror.net/
[codemirror]: https://codemirror.net/
[lr-readme]: https://github.com/lezer-parser/lr/blob/ed59b8b9c0c26164d6483f4c881a8c200184894e/README.md
[lr-parse]: https://github.com/lezer-parser/lr/blob/ed59b8b9c0c26164d6483f4c881a8c200184894e/src/parse.ts
[lr-stack]: https://github.com/lezer-parser/lr/blob/ed59b8b9c0c26164d6483f4c881a8c200184894e/src/stack.ts
[lr-token]: https://github.com/lezer-parser/lr/blob/ed59b8b9c0c26164d6483f4c881a8c200184894e/src/token.ts
[lr-constants]: https://github.com/lezer-parser/lr/blob/ed59b8b9c0c26164d6483f4c881a8c200184894e/src/constants.ts
[common-tree]: https://github.com/lezer-parser/common/blob/d87b56cbe3d6f54edb5b8343ee794f8f96f9c86c/src/tree.ts
[common-parse]: https://github.com/lezer-parser/common/blob/d87b56cbe3d6f54edb5b8343ee794f8f96f9c86c/src/parse.ts
[incremental]: ./theory/incremental.md
[incremental-wagner]: ./theory/incremental.md#incremental-parsing-node-reuse-wagner--graham
[incremental-rg]: ./theory/incremental.md#persistent--red-green-trees-making-reuse-cheap
[general-parsing]: ./theory/general-parsing.md
[bottom-up]: ./theory/bottom-up.md
[peg-packrat]: ./theory/peg-packrat.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[umbrella]: ./index.md
[tree-sitter]: ./tree-sitter.md
[rust-analyzer]: ./rust-analyzer.md
[roslyn]: ./roslyn.md
[rustc]: ./rustc-queries.md
[simdjson]: ./simdjson.md
