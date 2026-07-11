# Reference — the tree-sitter engine

The precise mode (`sparkles.syntax.ts`): whole-buffer parse + `highlights.scm`
queries over the `sparkles:tree-sitter` binding, producing the core event
stream. A single-layer port of the reference `tree-sitter-highlight`
semantics.

## Grammar supply

Grammars are compiled shared objects plus query files, supplied by the Nix
`ts-grammars` bundle (26 languages) and found through
`$SPARKLES_TS_GRAMMAR_PATH` — a path-separator-separated list of directories,
each holding `<lang>/parser` and `<lang>/queries/*.scm`. First hit wins, so
a local directory can shadow one grammar ahead of the bundle.

| Symbol                                 | What it is                                                                    |
| -------------------------------------- | ----------------------------------------------------------------------------- |
| `GrammarRegistry.fromEnvironment()`    | registry over `$SPARKLES_TS_GRAMMAR_PATH`                                     |
| `grammar(lang)`                        | dlopen + `tree_sitter_<lang>` + ABI window check, cached                      |
| `queryText(lang, kind = "highlights")` | the query source, from the same entry as the parser                           |
| `canonicalLanguage(label)`             | fence-tag/extension normalization (`ts` → `typescript`, `md` → `markdown`, …) |

Every lookup returns a `TsExpected` — a missing grammar is an error value
your code turns into plain-text output, never a crash.

## Configuration

```d
TsError error;
auto config = TsHighlightConfig.create(grammar, highlightsScm, error);
config.configure(labels);   // capture names → LabelIds (longest-dot-prefix)
```

Built once per (language, vocabulary); non-copyable, pass by `ref`. The
`injectionsScm`/`localsScm` parameters are recorded seams for the injection
milestone.

**Predicates.** The C API records query predicates but does not evaluate
them — the engine implements the reference text-predicate set: `#eq?` /
`#not-eq?` / `#any-eq?` / `#any-not-eq?` (literal and capture-vs-capture),
the `#match?` family (via `std.regex`), `#any-of?` / `#not-any-of?`;
`#set!` is parsed and stored; `#is-not? local` is recognized. **Anything
else disables that one pattern with a warning** (`config.warnings`) instead
of failing the language — query dialects drift, and a batch highlighter
always has the plain-text fallback.

## Highlighting

```d
auto result = highlight(config, source, sink, options);       // batch
auto result = highlightTree(config, tree, source, sink, options); // incremental seam
```

`sink` is any output range of `HighlightEvent`. The event loop follows the
reference rules: captures in position order, predicate-rejected matches
removed, ends close before starts at equal offsets, **same-node
last-pattern-wins**, unresolved captures emit nothing, cancellation checked
every 100 events plus inside the C query execution.

## Guards (`HighlightOptions`)

| Option           | Default | Rationale                                                                                                      |
| ---------------- | ------- | -------------------------------------------------------------------------------------------------------------- |
| `maxSourceBytes` | 512 MiB | Helix's cap; 2 GiB ceiling is structural (32-bit indices)                                                      |
| `parseBudget`    | 500 ms  | Helix's `PARSE_TIMEOUT`; progress-callback cancellation                                                        |
| `matchLimit`     | 256     | Helix's tuned value (Neovim's 64 breaks Erlang); exceeding truncates + sets `matchLimitExceeded`, not an error |
| `queryBudget`    | off     | wall clock for query execution + event assembly                                                                |
| `cancelFlag`     | null    | host cancellation, polled by every guard                                                                       |

## Error codes (`TsErrorCode`)

`grammarNotFound` / `dlopenFailed` / `symbolNotFound` / `incompatibleAbi`
(loader), `queryFileMissing` / `querySyntax` / `queryNodeType` / … (query
compile, byte offset in `detail`), `sourceTooLarge` / `parseTimeout` /
`parseCancelled` / `highlightTimeout` / `highlightCancelled` (guards),
`unsupportedPlatform` (non-Posix dlopen). All surface as
`TsExpected!T = Expected!(T, TsError, NoGcHook)`.

## Out of scope (v1)

Injection layers (`injections.scm` — markdown-inline and fenced code blocks;
the next milestone, seams in place), locals, UTF-16 sources, Windows
`LoadLibrary`, incremental editing (keep the `TsTree`, re-parse, call
`highlightTree` — the split exists; the machinery doesn't yet).

## See also

- [The core](./core.md) — the event stream this engine produces.
- The [delivery plan](../../../specs/syntax/PLAN.md) — milestones and
  deferrals.
