# `sparkles:syntax` — label-vocabulary dialect reconciliation

_A defect report and remediation record for `label.d`'s `standardLabels`. The
vocabulary merged two capture-name dialects that are synonyms of each other and
reconciled neither, so a third of what the shipped grammars emit could not be
styled by any built-in theme. Written after the theme-generator specificity fix
(`tools/download_themes.d`), which addressed a different, smaller problem in the
same area. File:line references are anchors, not gospel — confirm before
editing._

> [!NOTE]
> **Status: D1–D4 implemented.** Sections 1–3 describe the defect as found and
> are kept as the rationale; §4 records what each change did, §5 how it is
> verified, and §6 what is left. `sparkles.syntax.ts.coverage` now fails
> `dub test :syntax` if this regresses.

## 1. Symptom (as found)

Numbers were uncolored in every built-in theme, in 20 of the 26 bundled grammars:

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

The codebase already brushed against this without generalizing it: the
`markdownInlineSelfInjection` test carried a comment noting that a markdown
capture "resolves in our vocabulary — unlike its neovim-style `@text.strong`".
That is this defect, seen once and read as a quirk. The aside is now gone and
`markdownNeovimDialectResolves` asserts the general case instead.

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

  > [!IMPORTANT]
  > The A2 list above **overstates the gap**, and the correction shaped the
  > design. It was measured against the set of selectors themes emit, but theme
  > lookup is `ResolvedTheme`, which is longest-dot-prefix: a label with no rule
  > of its own still inherits an ancestor's. `string.special` is styled by any
  > `string` rule, `keyword.directive` by any `keyword` rule. Only a label whose
  > **whole dotted chain** is unstyled is a real gap — which, of the list above,
  > means the flat ones: `constructor`, `embedded`, `label`, and
  > `punctuation.special` in themes that have no bare `punctuation` rule.
  >
  > Hence the D1 preference for hierarchical canonical names is not only about
  > `resolve` degrading — it is what makes a label inheritable. A flat label is
  > unstylable unless something routes to it exactly; `function.constructor` and
  > `constant.builtin.boolean` inherit for free. `sparkles.syntax.ts.coverage`
  > measures the resolved style, not selector membership, for this reason.

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

## 4. Remediation (implemented)

### D1 — Canonical dialect + alias table (capture side) — **done**

**Goal.** One canonical name per concept; every other dialect spelling resolves
onto it at configure time.

**Landed as** `standardAliases` + `LabelAlias` in `label.d`, consulted by
`LabelSet.resolve` after the vocabulary misses at each prefix depth. 26 aliases;
`standardLabels` went from 73 entries to 65 as the duplicate spellings became
aliases. `LabelSet.fromNames` carries none — a caller supplying its own
vocabulary owns the spellings that reach it. Two `static assert`s hold the
invariants: every alias target is a real label, and no alias is also a label.

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

**Vocabulary cleanup.** The aliased spellings stopped being labels.
`constant.builtin.boolean` and `function.constructor` were **added** as
canonical targets: `boolean` and `constructor` are flat upstream names, and a
flat label inherits nothing, so parking them under an existing branch is what
makes them styleable at all (see the correction in §2). `variable.other.member`
was a TextMate-side duplicate of `variable.member` that no grammar emits —
demoted to an alias, which also stopped the generator's identity fast-path from
emitting rules for it.

**Traps.** `standardLabels` carries `static assert`s for byte-wise sorted +
unique and for `LabelId` capacity (`label.d`); the alias table now carries its
own. Removing a label changes `LabelId` values, so any persisted/golden id must
be re-derived. `resolveTheme` resolves theme selectors against the same
`LabelSet`, so an alias must not be reachable as a _selector_ — enforced by the
"no alias is also a label" assert.

### D2 — Missing scope routes (theme side) — **done**

**Goal.** Give the (A2) labels a path from TextMate scope space so generated
themes define them. Extended `scopeMappingRules` in `tools/download_themes.d`;
same class as the diff-label routes added earlier.

| label                      | TextMate scopes routed                                                      |
| -------------------------- | --------------------------------------------------------------------------- |
| `function.constructor`     | `entity.name.function.constructor`, `support.class.constructor`             |
| `punctuation.special`      | `punctuation.definition.template-expression`, `constant.other.placeholder`  |
| `module`                   | `entity.name.type.namespace`, `entity.name.namespace`, `entity.name.module` |
| `string.special.key`       | `support.type.property-name`                                                |
| `string.special.url`       | `string.other.link`                                                         |
| `string.special.symbol`    | `constant.other.symbol`                                                     |
| `constant.builtin.boolean` | `constant.language.boolean`                                                 |
| `embedded`                 | `meta.embedded`                                                             |
| `label`                    | `entity.name.label`                                                         |
| `keyword.directive`        | `keyword.control.directive`, `meta.preprocessor`                            |
| `keyword.function`         | `storage.type.function`                                                     |

Most of these were already in the generator's `--report` dropped-scope list, so
the fix was routing what was being discarded rather than inventing mappings.
Ordering matters: each must precede the broader rule that would otherwise claim
it — the `module` routes before `entity.name.type`, the placeholder/symbol
routes before bare `constant`.

### D3 — Documentation corrections — **done**

- [`index.md`](./index.md) §2 — the vocabulary bullet now states that the
  convergence is only broad, that the vocabulary is hierarchical for a reason,
  and that capture and selector resolution deliberately differ. §5's prior-art
  table row was corrected to match.
- [`next-milestones-handoff.md`](./next-milestones-handoff.md) item 3 — the
  "drop them" trap now points here, and tells the runtime parser to lift
  `excessBudget` and `mergeByLabel` alongside the table.
- `label.d`'s module header, `docs/libs/syntax/explanation/design.md`, and
  `docs/libs/syntax/reference/core.md` carried the same premise; all corrected.

### D4 — A coverage audit that fails CI — **done**

Landed as `sparkles.syntax.ts.coverage`: `auditBundle` walks every
`<lang>/queries/highlights.scm` under `$SPARKLES_TS_GRAMMAR_PATH`, resolves each
capture through a `LabelSet`, and reports what a `ResolvedTheme` makes of it. A
unittest asserts that no capture the bundle emits goes unstyled by `builtinDark`,
skipping when the bundle is absent, so `dub test :syntax` fails on a regression
with the offending captures and their languages listed.

It measures the **resolved** style, not selector membership — the mistake §2
corrects. The query scanner skips `;` comments and string literals (a `#match?`
pattern or an email in a header comment otherwise reads as a capture) and drops
`_`-prefixed predicate-only captures.

An explicit `plainText` allowlist carries the captures that are _supposed_ to
render unstyled: `none` and `spell` (upstream no-ops), `text` (D's `__EOF__`
region), `embedded` (the injected grammar supplies the colors), and `label`
(goto labels read as ordinary identifiers in TextMate themes). Every entry is a
capture the audit can no longer protect, so the list should stay short.

## 5. Verification

All of these are in place:

- **Direct:** `hue --tui --theme=catppuccin-mocha` over a Python file — `42`
  renders `ESC[38;5;216m` (Catppuccin's peach), not `ESC[39m`.
- **Unit:** `label.LabelSet.resolveAlias` covers the dialect spellings and the
  chop around them (`number.float` exact, `number.weird` → `constant.numeric`);
  `label.LabelSet.aliasesNeverShadowLabels` asserts every canonical name still
  resolves to itself and every alias lands on a real, distinct label;
  `@none`/`@spell` still resolve to `LabelId.none`.
- **Regression:** `ts.coverage.auditBundle.everyCaptureIsStyled` over the whole
  bundle, plus `ts.coverage.captureNames.skipsCommentsAndStrings` for the
  scanner.
- **Markdown end-to-end:** `ts.highlighter.markdownNeovimDialectResolves` — a
  `# Title` with `**bold**` and `*italic*` now emits `markup.heading`,
  `markup.bold` and `markup.italic` spans, where the neovim `@text.*` dialect
  previously emitted nothing styleable.
- The six `ts.highlighter` tests that asserted `number:…` spans now assert
  `constant.numeric:…`, which is the alias working end-to-end through a real
  grammar.

## 6. What is left

- **`punctuation.special` is still unstyled in themes with no bare `punctuation`
  rule.** The two routes only fire for themes that define template-expression or
  placeholder scopes. It inherits `punctuation` where that exists, so the visible
  effect is limited to `${`-style delimiters rendering as plain text in some
  themes.
- **The `plainText` allowlist is a judgement call.** `label` and `embedded` are
  in it because TextMate themes essentially never style them, not because that
  is provably right; a Helix-TOML theme source would define both.
- **Descendant selectors are still mis-parsed.** A TextMate scope like
  `"markup.raw.block markup.inline.raw"` (space-separated = descendant) is
  treated as one scope by the generator, so it maps through its first element.
  Correct handling is to use the last element. Low impact today because
  `excessBudget` drops most of them, but it is a real gap in the importer.
- **Only `builtinDark` is audited.** Extending `auditBundle` across all 36 themes
  would catch per-theme holes, at the cost of a much noisier assertion.
