# `sparkles:syntax` — label-vocabulary dialect reconciliation

_A defect report and remediation plan for `label.d`'s `standardLabels`. The
vocabulary merges two capture-name dialects that are synonyms of each other and
reconciles neither, so a third of what the shipped grammars emit can never be
styled by any built-in theme. Written after the theme-generator specificity fix
(`tools/download_themes.d`), which addressed a different, smaller problem in the
same area. File:line references are anchors, not gospel — confirm before
editing._

## 1. Symptom

Numbers are uncolored in every built-in theme, in 20 of the 26 bundled grammars:

```bash
printf 'x = 42\n' > /tmp/t.py
hue --tui --theme=catppuccin-mocha /tmp/t.py | cat -v
# ^[[3;38;5;217;48;5;235mx^[[23;38;5;189m ^[[1;38;5;183m=^[[22;38;5;189m ^[[39m42
#                                                                    ^^^^^^^^^
#                                              ESC[39m — default foreground
```

Catppuccin defines a peach for numeric literals. Nothing can reach it. The same
holds for object properties, booleans, constructors, attributes, escapes,
namespaces, and labels — and, most visibly, for **all of markdown**: headings,
bold, italic, inline code, and links are unstyled by the tree-sitter path.

## 2. Root cause: two dialects merged, never reconciled

`standardLabels` was assembled as a **lexical union of two naming dialects that
are synonyms of each other**, with nothing mapping the overlap. `label.d:27-29`
states the provenance: "the reference tree-sitter highlighter's recognized
capture names and Helix's theme scopes, merged."

Both members of each synonymous pair are present as **separate labels**, and
the three components each pick a different member:

| concept       | upstream-ts name (grammars emit) | Helix name (themes style) |
| ------------- | -------------------------------- | ------------------------- |
| numeric       | `number` (20 grammars)           | `constant.numeric`        |
| member access | `property` (16)                  | `variable.member`         |
| attribute     | `attribute` (9)                  | `tag.attribute`           |
| escape        | `escape` (6)                     | `string.escape`           |
| boolean       | `boolean` (5)                    | `constant.builtin`        |
| namespace     | `namespace` (2)                  | `module`                  |

Every left-hand label is in the vocabulary, emitted by grammars, and has no
theme rule. Every right-hand label has theme rules and is largely never
emitted. Each pair is dead at both ends.

**What licensed the union** is the premise in [`index.md`](./index.md) §2:
"tree-sitter capture names deliberately track TextMate scope names, so one theme
layer drives both engines." If capture names really tracked scope names, merging
the two name sets would be harmless. That was true of older tree-sitter;
upstream has since moved to short flat names (`number`, `property`, `boolean`)
that do not track TextMate at all — and the nixpkgs bundle behind
`$SPARKLES_TS_GRAMMAR_PATH` ships exactly those queries.

The codebase already brushed against this without generalizing it:
`ts/highlighter.d:871` notes a markdown capture "which resolves in our
vocabulary — unlike its neovim-style `@text.strong`". That is this defect, seen
once and read as a quirk.

### Measured coverage

Across the 26 grammars in the bundle, 81 distinct capture names (excluding
`@_`-prefixed predicate-only captures by convention):

| outcome                                              | names |
| ---------------------------------------------------- | ----- |
| resolves to a label that has a theme rule            | 41    |
| resolves, but the label has **no rule in any theme** | 20    |
| resolves to nothing — `LabelId.none`, emits no span  | 20    |

**33% of (grammar, capture) pairs are unstylable.** Two of the 20 unresolvable
names are intentional no-ops in nvim queries (`@none` suppresses highlighting,
`@spell` is a spellcheck hint), leaving 18 genuine misses.

The gap splits into two distinct sub-problems that need different fixes:

- **(A1) synonym pairs** — the label exists but a _different_ vocabulary label
  carries the theme rule: `number`, `property`, `attribute`, `boolean`,
  `escape`, `namespace`. Fixable only on the **capture** side.
- **(A2) unrouted canonical labels** — the label is the right name and has no
  duplicate, but **no TextMate scope maps to it**, so no generated theme ever
  defines it: `constructor` (10 grammars), `punctuation.special` (10),
  `string.special` (7), `embedded` (6), `label` (6), `keyword.directive` (3),
  `keyword.function` (3), `string.special.key|path|symbol`. Fixable only on the
  **theme** side, by extending `scopeMappingRules`.

A third group is pure waste in the other direction — labels every theme defines
that no grammar ever emits: `punctuation` (bare), `constant.character.escape`,
`variable.other.member`, `tag.attribute`, `error`, `string.regexp`, and the
whole `markup.*` family. Worth noting for the punctuation change already
committed: **no grammar emits bare `punctuation`**, so dropping those rules
from 15 themes costs nothing on the tree-sitter path.

### Markdown is the worst case

The bundle's markdown grammars use the **old nvim `text.*` dialect**, none of
which resolves:

| capture (markdown, markdown-inline)          | outcome             |
| -------------------------------------------- | ------------------- |
| `text.title`, `text.strong`, `text.emphasis` | resolves to nothing |
| `text.literal`, `text.uri`, `text.reference` | resolves to nothing |
| `punctuation.special`                        | resolves, no rule   |
| `punctuation.delimiter`, `string.escape`     | styled              |

So the tree-sitter markdown path contributes almost no styling, which is part of
why `hue --gui`'s preview builds its own decoration layer over
`md/model.d` rather than consuming highlight events.

## 3. Why dropping TextMate support would not help

"TextMate support" means two separable things here, and neither removal fixes
this:

**(a) TextMate/Shiki JSON as the theme source** — today the only source for
`themes.d`. Dropping it does not help, because themes still have to come from
somewhere and the realistic alternative is Helix TOML, whose selectors are
`constant.numeric` — precisely the member the grammars _do not_ emit. Same
mismatch, different import format. The only theme ecosystem that matches our
grammars out of the box is nvim colorschemes, which are Lua programs rather than
data, and adopting them forfeits the Shiki-derived set and the HTML/docs story.

**(b) The future TextMate grammar engine** ([`index.md`](./index.md) §2, the
"fast mode... later engine behind the same seam") — also no. An engine is a
label _producer_; it would emit TextMate scopes and need the same scope→label
map on the way in. Dropping it removes a consumer of the mapping, not the
mapping.

What dropping TextMate _would_ eliminate is a narrower, genuinely inherent loss:
TextMate's open-ended, language-qualified scope space
(`punctuation.separator.namespace.ruby`) that no finite map covers. That is the
class behind the punctuation/underline bugs, it is already contained by
`excessBudget` in the generator, and it was never what makes numbers colorless.

**The mismatch is between grammar-capture dialect and theme-selector dialect.**
TextMate is one selector dialect among several; removing it reconciles nothing.
The remediation below is identical with or without it.

## 4. Remediation

### D1 — Canonical dialect + alias table (capture side)

**Goal.** One canonical name per concept; every other dialect spelling resolves
onto it at configure time.

**Canonical direction: the hierarchical (Helix-style) names.** Not taste — the
vocabulary's own resolution algorithm rewards it. Longest-dot-prefix degrades
`constant.numeric.float` → `constant.numeric` → `constant`, two useful fallback
levels; the flat `number.float` → `number` → nothing. Performance does not enter
into it: `TsHighlightConfig.configure` (`ts/config.d:128`) resolves capture names
to `LabelId`s **once per query**, not per token, so an alias lookup there is free
at render time.

**Where.** `LabelSet.resolve` in `label.d` — one place, so it benefits every
theme source (including the runtime theme parser of handoff item 3 and
user-authored themes) and every engine. This makes capture-name resolution
deliberately **not** identical to theme-selector resolution, which
[`index.md`](./index.md) §2 currently states as "one algorithm for captures and
themes". The justification for the divergence: capture names arrive from an
external supply chain in several dialects, theme selectors are our own
vocabulary. That premise change must be written into `index.md` (§5 D3).

**Alias table** (alias → canonical), from the measured gaps:

| alias                                                     | canonical                  |
| --------------------------------------------------------- | -------------------------- |
| `number`                                                  | `constant.numeric`         |
| `number.float`, `float`                                   | `constant.numeric.float`   |
| `boolean`                                                 | `constant.builtin.boolean` |
| `character`                                               | `constant.character`       |
| `property`, `property.definition`                         | `variable.member`          |
| `escape`                                                  | `string.escape`            |
| `namespace`                                               | `module`                   |
| `attribute`                                               | `tag.attribute`            |
| `parameter`                                               | `variable.parameter`       |
| `conditional`, `repeat`, `exception`, `include`, `import` | `keyword.control`          |
| `storageclass`                                            | `keyword.storage`          |
| `method`                                                  | `function.method`          |
| `method.call`                                             | `function.method`          |
| `delimiter`                                               | `punctuation.delimiter`    |
| `text.title`                                              | `markup.heading`           |
| `text.strong`                                             | `markup.bold`              |
| `text.emphasis`                                           | `markup.italic`            |
| `text.literal`                                            | `markup.raw.inline`        |
| `text.uri`                                                | `markup.link.url`          |
| `text.reference`                                          | `markup.link`              |

`@none` and `@spell` stay unresolved — they are intentional no-ops upstream.

**Vocabulary cleanup.** The aliased spellings stop being labels and become
alias entries; `boolean` needs `constant.builtin.boolean` added as its canonical
target. `variable.other.member` is a TextMate-side duplicate of
`variable.member` that no grammar emits — demote it to an alias too.

**Traps.** `standardLabels` carries `static assert`s for byte-wise sorted +
unique and for `LabelId` capacity (`label.d:108-111`); the alias table needs the
same discipline or its own. Removing a label changes `LabelId` values, so any
persisted/golden id must be re-derived — grep for hardcoded ids before touching
the list. `resolveTheme` resolves theme selectors against the same `LabelSet`,
so an alias must not be reachable as a _selector_ or two rules could target one
label.

### D2 — Missing scope routes (theme side)

**Goal.** Give the (A2) labels a path from TextMate scope space so generated
themes define them. Extends `scopeMappingRules` in `tools/download_themes.d`;
same class as the diff-label routes already added.

| label                 | candidate TextMate scopes                                                  |
| --------------------- | -------------------------------------------------------------------------- |
| `constructor`         | `entity.name.function.constructor`, `support.class.constructor`            |
| `punctuation.special` | `punctuation.definition.template-expression`, `constant.other.placeholder` |
| `string.special.key`  | `support.type.property-name`                                               |
| `string.special.url`  | `string.other.link`                                                        |
| `embedded`            | `meta.embedded`                                                            |
| `label`               | `entity.name.label`                                                        |
| `keyword.directive`   | `keyword.control.directive`, `meta.preprocessor`                           |
| `keyword.function`    | `storage.type.function`                                                    |

Several of these appear in the generator's `--report` dropped-scope list today,
so the fix is routing what is already being discarded rather than inventing
mappings.

### D3 — Documentation corrections

- [`index.md`](./index.md) §2 — the claim that capture names track TextMate
  scope names is false for the queries actually shipped; and "one algorithm for
  captures and themes" (also §5's prior-art table) stops holding once D1 lands.
- [`next-milestones-handoff.md`](./next-milestones-handoff.md) item 3 lists
  "many scopes map to `null` (drop them)" as a **trap to preserve** when lifting
  `mapScopeToLabel` into the runtime theme parser. As written, item 3 would
  inherit this defect. It needs a pointer here.

### D4 — A coverage audit that fails CI

The numbers above came from ad-hoc analysis. They should be a checked-in D tool
(per the repo's D-over-throwaway-script rule) — the natural home is a
`--coverage` mode beside the generator's existing `--report`, or an `apps/ci`
subcommand: walk `$SPARKLES_TS_GRAMMAR_PATH`, resolve every capture through
`LabelSet.standard()`, and fail when a capture emitted by N or more grammars
resolves to a label no built-in theme styles. That turns this class of defect
into a build error instead of something a user notices in a screenshot.

## 5. Suggested order

```
D1 alias table        ──► D3 doc corrections   (D3 records what D1 changed)
D2 scope routes           (independent, small — generator only)
D4 coverage audit         (after D1+D2, to lock the result in)
```

D2 is independently shippable and low-risk. D1 is the substantive change and
the one that fixes numbers. D4 is what prevents the regression from recurring
silently.

## 6. Verification

- **Direct:** `hue --tui --theme=catppuccin-mocha` over a Python file — `42`
  renders peach, not `ESC[39m`.
- **Unit:** `LabelSet.standard().resolve("number") == find("constant.numeric")`
  for each alias-table row; `@none`/`@spell` still resolve to `LabelId.none`.
- **Regression:** the existing `themes.builtins.resolveCleanly` unittest in the
  generated `themes.d`, plus a new assertion that every label a bundled grammar
  emits has a rule in `builtinDark`.
- **Markdown end-to-end:** a `# heading` and `**bold**` through the tree-sitter
  markdown path emit `markup.heading` / `markup.bold` spans (they emit nothing
  today).
