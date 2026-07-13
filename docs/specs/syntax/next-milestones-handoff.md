# `sparkles:syntax` — next-milestones handoff

_A pick-up guide for the six items after M7 (injections). M0–M7 are on `main` /
PR #104. Each section is self-contained: goal, approach grounded in the existing
code and the reference (`tree-sitter-highlight` 0.27 at
`/home/petar/code/repos/parsing/tree-sitter/crates/highlight/src/highlight.rs`),
the seams already in place, the traps, and how to verify. File:line references
are anchors, not gospel — confirm before editing._

## Suggested order & dependencies

```
4 toRgb + byStyledLine   ──► 6 raylib viewer        (viewer needs both helpers)
3 theme-file parsing         (independent, small)
5 CSS-variable HTML          (independent, renderer)
1 injection.combined         (engine, small — completes injections)
2 locals                     (engine, largest — hardest of the six)
```

Recommended sequence: **4 → 6** (tiny helpers, then the end-to-end demo that
proves them), then **3** and **5** (independent renderer/theme wins), then **1**
(closes the injection story), then **2** (the big one). 1 and 2 are pure engine
work and don't touch 3/4/5/6.

## Shared context (applies to all engine/consumer work)

- **Grammars come from `$SPARKLES_TS_GRAMMAR_PATH`** (set by the devshell,
  `nix/shells/default.nix:180`). Run inside `nix develop`; grammar-dependent
  tests `skipTest` when it is unset.
- **One `LabelSet.standard()` instance** must feed both `TsConfigCache.create`
  and `resolveTheme`, or label ids won't align (`ResolvedTheme.opIndex` is total
  but returns `defaults` for out-of-vocab ids — `theme.d:82`).
- **Totality law:** every failure degrades to plain text; only size-guard trips
  and failed _root_ parses return an error (`highlighter.d:82`).
- **`@safe pure nothrow @nogc`** where the design allows; the `ts/` engine is
  `@system` (grammar dlopen, raw nodes). Tests carry explicit safety attributes.

---

## 1. `injection.combined`

**Goal.** Honor `#set! injection.combined`: gather the content nodes of _all_
matches of a combined injection pattern into **one** child layer parsed over
their disjoint ranges, instead of one layer per match. Completes the injection
feature (M7 shipped everything else).

**Why it matters.** Grammars use combined injections when many small fragments
share one embedded parse (e.g. all the string chunks of a heredoc, or every
comment line of a doc block, parsed as a single document). Without it, each
fragment becomes an isolated layer and cross-fragment structure is lost.

**Reference (highlight.rs).** Construction builds a **second, injection-only
query** (lines 387–404); combined patterns are disabled in the main query,
non-combined patterns disabled in the combined query. During layer build
(617–651) the combined query runs over the whole tree and accumulates
`injections_by_pattern_index: (lang, Vec<content_node>, include_children)` —
overwriting language, **pushing** each content node — then builds one layer per
pattern from `intersect_ranges(&ranges, &content_nodes, include_children)`.

**Approach in our engine.** We already keep injections as a _separate_ query and
discover up front (`buildLayers`, `highlighter.d`), so this is simpler than the
reference's two-query split:

- In `buildLayers`'s injection loop, split matches into **non-combined**
  (current behavior: one child layer each) and **combined** (accumulate).
- A pattern is combined iff its `#set!` settings contain `injection.combined`
  (already parsed into `config.injectionPredicates[patternIndex].settings` —
  `injection.d:injectionForMatch` reads settings the same way for `.language`).
  Add an `isCombined` read there (or a `bool[]` on the config).
- Accumulate combined matches into `size_t[pattern → (lang, TSRange[])]`: for
  each combined match, resolve language + `intersectRanges` and **append** its
  ranges. After the match loop, enqueue one `Work(childConfig, mergedRanges,
depth+1)` per combined pattern.

**Key files.** `libs/syntax/src/sparkles/syntax/ts/injection.d` (an `isCombined`
/ combined-settings read), `.../ts/highlighter.d` (`buildLayers` accumulation).

**Reused seams.** `#set!` already parsed (`predicates.d:206`); `intersectRanges`
already returns a `TSRange[]` you can concatenate (`injection.d`); `setIncludedRanges`
already takes multiple disjoint ranges (`wrappers.d`).

**Traps.** (a) Combined ranges must stay **ascending and non-overlapping** — sort
the accumulated ranges by `start_byte` before enqueue (tree-sitter rejects
unordered ranges; `setIncludedRanges` returns `false`). (b) A combined pattern
with a captured `@injection.language` (rather than a `#set!`) can name different
languages across matches — the reference lets the last win; match that or bucket
by (pattern, language).

**Tests.** Find or synthesize a grammar whose `injections.scm` sets
`injection.combined` (grep the bundle). If none in the bundle, a hand-written
config + query fixture over a small language (like the existing
`jsonConfigForTest(queryOverride)` pattern) exercising two content nodes → one
layer. Assert `assertWellFormed` + that a construct spanning both fragments
highlights coherently.

**Effort:** small/medium.

---

## 2. Locals (`@local.scope` / `.definition` / `.reference`)

**Goal.** Def/use variable coloring: a `@local.reference` borrows the highlight
of its resolved `@local.definition`; `(#is-not? local)` highlights are suppressed
on nodes that resolved as locals. The spec frames this as "a quality bonus,
deferred indefinitely for batch rendering" — it is the **largest and trickiest**
of the six.

**Reference (highlight.rs), precise.** Locals is woven into the merged query and
the per-node capture stream:

- **Merged query, locals-first (353–454).** `injection ++ locals ++ highlights`
  into one query; `locals_pattern_index` / `highlights_pattern_index` partition
  pattern-index space into three bands. Dispatch: `pattern_index <
locals_pattern_index` ⇒ injection; `< highlights_pattern_index` ⇒ locals; else
  highlight. **Load-bearing guarantee (1107–1111):** captures for one node arrive
  in pattern-index order, so a node's locals captures precede its highlight
  capture in the single stream.
- **Capture indices (417–435):** `local.scope`, `local.definition`,
  `local.definition-value`, `local.reference`.
- **`non_local_variable_patterns` (408–415):** per-pattern `(#is-not? local)`.
- **Per-layer state (182–191):** `scope_stack: Vec<LocalScope{inherits, range,
local_defs: Vec<LocalDef{name, value_range, highlight}>}>`, root
  `{inherits:false, 0..MAX, []}`.
- **The locals block (1005–1146):** (1) pop scopes while `capture.start >
top.range.end`; (2) while the same-node capture is a locals pattern —
  `local.scope` pushes a scope (`local.scope-inherits` `#set!`, default true);
  `local.definition` pushes a def, reads its sibling `@local.definition-value`
  range, and remembers the def's highlight slot; `local.reference` (only if no
  definition on this node) walks scopes outward for a def with matching name and
  `value_range.end <= ref.start`, honoring `inherits`; (3) in the highlight
  same-node last-wins, **skip** a following highlight capture when the node
  resolved local and `non_local_variable_patterns[pattern]`; (4) write the def's
  own highlight back into its slot; **emit `reference_highlight.or(current)`**.
- **Locals emit no events** — they only mutate `scope_stack` and redirect/suppress
  the node's own highlight capture.

**Approach in our engine — the decisions.**

1. **Merge `localsScm` into the highlights query (locals first).** Injections
   stay a separate query (they only spawn layers — no per-node highlight
   coupling), but locals _must_ share the stream with highlights so a node's
   locals captures precede its highlight capture. In `TsHighlightConfig.create`,
   when `localsScm` is non-empty build the main query from
   `localsScm ~ "\n" ~ highlightsScm`. **Get `localsPatternIndex` for free** by
   compiling `localsScm` alone first and taking its `patternCount` — avoids a new
   `ts_query_start_byte_for_pattern` C binding. (`localsScm` is currently
   discarded at `config.d:60`.)
2. **New config fields:** `uint localsPatternIndex`, `localScopeIndex`,
   `localDefIndex`, `localDefValueIndex`, `localRefIndex` (default `uint.max`,
   scanned in the same `captureName(i)` loop that finds injection indices),
   `hasLocals()`. `config.predicates` is already rebuilt over `query.patternCount`
   so it covers the merged query — no reindex bug as long as the same merged
   query is executed and looked up (it is).
3. **Per-layer scope stack + capture-struct fields.** Add `patternIndex` and (for
   defs) `valueStart/valueEnd` to `PendingCapture`/`LayerCapture` — because our
   engine copies **one** capture out and drops the match (`highlighter.d:136`
   comment), the `@local.definition-value` **sibling** capture must be read during
   `peek`/`peekLayer` while the match is live and stashed. Add a `LocalScope[]`
   scope stack (per-`Layer` in `interleaveLayers`; a local in `highlightTree`).
4. **Wire the loop** in _both_ loops (`highlightTree` ~204–231 and
   `interleaveLayers` ~511–540): scope-pop → locals accumulation → suppression in
   last-wins → write-back → `emit reference_highlight ? reference : own`.

**Key files.** `config.d` (merge + fields), `highlighter.d` (scope stack + locals
block in both loops + capture-struct fields), `predicates.d` (nothing to add —
`isNotLocal` at `predicates.d:73,218` and `#set!` settings already exist), maybe
`wrappers.d` (only if you take the `start_byte_for_pattern` route instead of the
throwaway-count route).

**Hardest parts (flag prominently).**

- **Merged-query ordering is non-negotiable** — a separate locals cursor breaks
  the redirect/suppress mechanism or forces an expensive cross-stream node join.
- **Two divergent loops** — `highlightTree` and `interleaveLayers` each need the
  locals block; consider refactoring their per-capture core into one shared helper
  first. The `injectionAgreesWithSingleLayer` guard (`highlighter.d:830`) asserts
  they stay in agreement — locals must preserve that.
- **`definition-value` vs eager copy-out** — read the sibling capture in `peek`.
- **`#is-not? local` is parsed but never consumed** — B3.3 is its first user.

**Tests.** A language with a real `locals.scm` in the bundle (many ship one —
check `queries/locals.scm` per grammar). Fixtures: a `let x = 1; use(x)` → the
`use` reference gets `x`'s definition color; a shadowing case across scopes; a
`let x = x` self-reference guard; a `(#is-not? local)` suppression case. Reuse
`labeledSpans` + `assertWellFormed`. Add a no-locals agreement check (a config
without `localsScm` yields the identical stream to today).

**Effort:** medium/large. Budget a full session; land the config-merge + fields
first (green, no behavior change), then the loop logic.

---

## 3. Theme-file parsing

**Goal.** Load themes from a file into the existing `Theme` model (plain data:
`Theme{name, defaultFg, defaultBg, ThemeRule[] rules}`) at runtime — today the
30+ themes in `themes.d` are **build-time codegen** (`tools/download_themes.d`),
with no runtime parser.

**What exists (reuse).** `tools/download_themes.d` is a codegen tool that fetches
**Shiki/TextMate theme JSON** and emits D source. Its scope→selector mapping is
the crux and is directly liftable:

- `scopeMappingRules` (`download_themes.d:60`) — ordered TextMate-scope →
  dotted-label table (`entity.name.function → function`, `keyword.operator →
operator`, …).
- `mapScopeToLabel(scope)` (`download_themes.d:143`) — identity fast-path for
  scopes already in `standardLabels`, then the prefix table, then longest-dotted-
  prefix fallback. **Returns a real label string — reusable as-is.**
- `cleanHexColor` / `parseFontStyle` (`:170`, `:189`) — logic reusable, but they
  return _D-source fragments_; re-express to return `Color` / `FontStyle`.
- `color.d:parseHexColor` (`color.d:108`) already parses `#RGB`/`#RRGGBB`/
  `#RRGGBBAA` into `Color` — use it for color literals.

**Parser availability (decides the format).**

- **TOML: none** — no parser anywhere in the repo/registry/nix. Helix-TOML would
  need a **new dub dependency** on `libs/syntax`, which today depends only on
  `expected` + internal packages. Weigh that.
- **JSON: `std.json` (Phobos), no new dep.**

**Recommendation.** Ship **JSON first** (zero new deps):

1. A **native `Theme` JSON** round-trip (serialize/parse the library's own model)
   — trivial, for user-authored themes.
2. **TextMate/VSCode JSON** — lift `scopeMappingRules` + `mapScopeToLabel` from the
   tool into a runtime `ts/../theme_file.d` (or `theme_parse.d`), reusing
   `parseHexColor`. This is the format the project already handles correctly.

Defer **Helix TOML** (best selector fidelity — Helix scopes ≈ our vocabulary per
`label.d`'s provenance note) until the team accepts a TOML dep; it also needs
`[palette]` named-color resolution and `modifiers`-array → `FontStyle`.

**Key files.** New `libs/syntax/src/sparkles/syntax/theme_file.d`;
reference `tools/download_themes.d` (mapping), `theme.d` (target model +
`resolveTheme`), `color.d` (`parseHexColor`), `label.d` (vocabulary).

**Traps.** TextMate `scope` may be a string _or_ array, each comma-separated
(handle both — `download_themes.d:302`); many scopes map to `null` (drop them);
theme `settings` entry with no `scope` is the document default (`defaultFg/Bg`).
De-dup rules (`download_themes.d` uses a `seen` set).

**Tests.** Round-trip a known `Theme` through native JSON (`==`); parse a small
TextMate JSON fixture and assert specific `ThemeRule`s resolve
(`resolveTheme(parsed, LabelSet.standard())[find("keyword")]` matches expected).
Golden a full parse against one of the codegen'd `themes.d` entries.

**Effort:** small/medium (native JSON small; TextMate JSON medium via the mapping
lift).

---

## 4. `toRgb(Color, fallback)` + `byStyledLine`

**Goal.** The two small, recorded GPU-consumer helpers that a non-terminal
backend (item 6) needs. Both are documented seams.

**`toRgb` — concretize a `Color` to `RgbColor`.** `Color` is a sum type
(`color.d:50`, `Kind.{unset, default_, palette, rgb}`); a GPU/raylib consumer
needs concrete `RgbColor{r,g,b}`:

```d
RgbColor toRgb(Color c, RgbColor fallback) @safe pure nothrow @nogc
{
    final switch (c.kind)
    {
        case Color.Kind.rgb:      return c.rgb;
        case Color.Kind.palette:  return xterm256ToRgb(c.index); // color.d:300
        case Color.Kind.unset:
        case Color.Kind.default_: return fallback;               // theme default fg/bg
    }
}
```

The building blocks (`xterm256ToRgb`, `RgbColor`) already exist; this is the
recorded seam at `color.d:13,294`. Home: `color.d`.

**`byStyledLine` — split styled runs on newlines.** `byStyledSpan` (`event.d:149`)
yields `StyledSpan` runs that **can contain `'\n'`**; a (col,row) consumer needs
runs clipped to single lines. Add a lazy adapter over `byStyledSpan` that emits,
per line, the run segments plus a line-break marker (or a `(line, StyledSpan)`
pair). The ANSI renderer already scans each run for `'\n'` and resets per line
(`render/ansi.d:98`) — extract that logic as the reusable adapter. Home:
`event.d` (next to `byStyledSpan`). Keep it engine-agnostic (offsets only; the
caller slices `source`).

**Key files.** `color.d` (`toRgb` + test), `event.d` (`byStyledLine` + test).

**Traps.** `toRgb` — `default_` and `unset` both fall back (a theme "default"
color means "use the document default", not black). `byStyledLine` — a run
ending exactly at `'\n'`, an empty line (consecutive `'\n'`), and the final line
without a trailing newline; keep it `@nogc`/lazy (no allocation).

**Tests.** `toRgb`: each `Kind` incl. palette→known RGB and default→fallback.
`byStyledLine`: a multi-line run splits into per-line segments with correct
offsets; empty lines; CRLF is out of scope (byte offsets only).

**Effort:** small (both). Do these before item 6.

---

## 5. CSS-variable multi-theme HTML

**Goal.** A third `HtmlMode` (the Shiki doctrine): emit **one** HTML document that
renders under multiple themes by swapping CSS custom properties — no
re-highlighting, no duplicate markup. `render/html.d` already reserves the
`cssVariables` slot (doc note; `HtmlMode` today is `{inlineStyles, cssClasses}`).

**Approach.** Two viable shapes; pick one (or support both):

- **Class + variables (recommended):** reuse `cssClasses` markup
  (`<span class="syn-keyword">`), but the stylesheet defines each label's color as
  a CSS variable per theme, switched by a `:root[data-theme="dark"]` /
  `@media (prefers-color-scheme: dark)` selector. Extend `writeThemeStylesheet` to
  take **N** resolved themes and emit `.syn-keyword{color:var(--syn-keyword)}` +
  `:root{--syn-keyword:#…}` blocks per theme. Markup is theme-independent; the
  page toggles `data-theme`.
- **Inline dual-color (Shiki's default):** each `<span>` carries both colors as
  vars: `style="color:var(--s0);--s0:#dark;--s1:#light"` with a root rule choosing
  `--s0`/`--s1`. Self-contained per token, larger output.

Go with **class + variables** — it composes with the existing `cssClasses` path
and the theme-aware-page pattern (the repo's Artifacts already use
`:root[data-theme=…]` + `prefers-color-scheme`).

**Key files.** `render/html.d`: add `HtmlMode.cssVariables`; generalize
`writeThemeStylesheet` to `writeThemeVariables(themes[], w)`; `renderHtml`'s
`cssVariables` case reuses the `cssClasses` tag path.

**Reused seams.** `writeClassName` (dots→dashes), `writeStyleDeclarations`,
`concreteRgb`/`writeHexRgb`, `xterm256ToRgb` — all already in `html.d`. The
per-line close/reopen invariant is unchanged.

**Traps.** A label unstyled in theme A but styled in theme B still needs a class

- a var in both (or the fallback shows through). Decide the variable naming
  (`--syn-<label>`) and the theme-selection contract (data-attr vs media query vs
  both). `default_`/`unset` colors emit no declaration (as today).

**Tests.** Golden the stylesheet for two themes (dark+light) — assert both
`--syn-keyword` blocks and one class rule; assert markup is byte-identical to
`cssClasses` mode (only the stylesheet differs). Reuse the balanced-tags-per-line
property test.

**Effort:** medium.

---

## 6. Raylib text-file viewer (`apps/syntax-viewer`)

**Goal.** A new app: open a source file, highlight it with `sparkles:syntax`, and
render it with raylib — the end-to-end demo of the GPU/third-backend contract and
the motivating consumer for item 4. **Depends on item 4** (`toRgb` +
`byStyledLine`); build those first (in the lib, or in the app then upstream them).

**Reuse from `apps/terminal` (take the scaffolding, drop the VT engine).** ~90% of
`app.d` is terminal-specific (pty, ghostty, kitty graphics) — ignore it. Reuse:

- Window init (`app.d:377`), `SetTargetFPS(60)`, resizable flag.
- Font: `getRequiredCodepoints` (`:265`) + `LoadFontEx` (`:390`) atlas;
  `fontHasGlyph` + `glyphCache` fallback (`:250`); `fc-match` name resolution
  (`:359`).
- Cell metrics: `MeasureTextEx(font, "M", …)` → `cellWidth/cellHeight` (`:429`).
- Per-glyph draw + **fake styling** — bold=redraw+1px, italic=x-shift,
  underline/strike=thin `DrawRectangle` (`:859–903`) — maps straight onto
  `FontStyle` bits.
- Font-size zoom (`:694`) + resize (`:726`) (clear `glyphCache` + recompute cells
  on font reload).

**Data path (the contract).**

```
GrammarRegistry.fromEnvironment()                       // registry.d:25
auto cache = TsConfigCache.create(&registry, labels);   // injection.d:190  labels = LabelSet.standard()
auto sink  = appender!(HighlightEvent[]);
highlightInjected(cache, extensionOf(path), source, sink);  // highlighter.d:293
auto theme = resolveTheme(builtinDark, labels);         // theme.d:95  (SAME labels)
foreach (line, run; byStyledLine(sink[])) {             // item 4
    StyleSpec s = theme[run.label];                     // theme.d:82
    RgbColor fg = toRgb(s.fg, toRgb(theme.defaults.fg, docFg)); // item 4
    // DrawTextEx(source[run.start..run.end]) at (col*cellW, line*cellH)
}
```

Language from the file extension: pass the extension (no dot) straight to
`canonicalLanguage` (`registry.d:110`) — it already folds `rs/py/ts/md/…` and
`TsConfigCache.resolve` calls it internally. Unknown ext → miss → plain text.

**Dependencies / wiring.** `apps/syntax-viewer/dub.sdl`: `dependency "raylib-d"
version="~>6.0.1"`, `libs "raylib"`, `dependency "sparkles:syntax" path="../.."`
(+ `sparkles:core-cli` for args). Add `subPackage "apps/syntax-viewer"` to the
root `dub.sdl`. raylib is already a devshell system package
(`nix/shells/default.nix:138`); `SPARKLES_TS_GRAMMAR_PATH` is set there too.

**Design decisions to make.**

- **Highlight once on load** (batch, whole file), buffer the events; re-highlight
  only on file change.
- **Scrolling:** build a line-start byte-offset index; draw only `StyledSpan`s in
  the visible line range (this is where `byStyledLine` earns its keep).
- **Wide chars/tabs:** advance columns via `graphemeClusterWidth`
  (`base/text/width.d:117`) — CJK/emoji = 2 cells — not naive `+1`; expand tabs
  viewer-side.
- **Gutter** (line numbers), **theme picker** (`builtinDark`/`builtinLight` + the
  ~20 named themes), **`ClearBackground(Theme.defaultBg)`**.
- Degrade to plain text when the grammar is missing (totality).

**Traps.** `highlightInjected` is `@system`; the whole app is fine as `@system`.
Registry/cache must outlive the highlight calls (own them at app scope). Don't
re-`resolveTheme` per frame. `LoadFontEx` only bakes the codepoints you pass.

**Tests.** Apps are hard to unit-test; add a headless smoke (highlight a fixture
file, assert non-empty styled runs + well-formed) and a manual "open a .d/.md
file, eyeball it" checklist. Consider a screenshot in the app README.

**Effort:** medium (mostly viewer plumbing — the highlighting is a solved path).

---

## Cross-cutting reminders

- Commit per phase, each green (`dub test :syntax` / `:tree-sitter`); keep the
  `injectionAgreesWithSingleLayer` regression guard passing for any loop change.
- New files must be `git add`ed before `nix`/flake builds see them; a new app
  needs the root-`dub.sdl` `subPackage` line and (if a new dep) `dub.selections.json`
  - `nix/dub-lock.json` updates.
- Update `docs/specs/syntax/PLAN.md` §4 and the engine reference
  (`docs/libs/syntax/reference/engine.md`) as each lands.
