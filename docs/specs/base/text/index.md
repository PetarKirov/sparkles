# `sparkles.base.text` — cell-splitting & width specification

_Audience: developers and coding agents building against `sparkles:base`. This
document is normative and self-contained — it states how the library decodes,
segments, measures, and wraps styled UTF-8 in terminal cells. It is **based on
[kitty's Text Sizing Protocol](https://sw.kovidgoyal.net/kitty/text-sizing-protocol/)**,
whose normative "algorithm for splitting text into cells" is the clearest written
reference for the modern-terminal width consensus; relevant passages are quoted with
credit below. The conformance ledger — every case the implementation must satisfy,
including currently-failing ones — lives in [test cases](./test-cases.md). For the
library overview see [`sparkles:base`](../../../libs/base/index.md)._

## 1. Scope & credits

This spec governs three modules of `sparkles.base.text`:

| Module             | Role                                                                                                |
| ------------------ | --------------------------------------------------------------------------------------------------- |
| `width.d`          | width of a single code point (`codepointWidth`) and of a grapheme cluster (`graphemeClusterWidth`)  |
| `grapheme.d`       | segmentation of styled UTF-8 into escapes + clusters (`byGraphemeCluster`) and total `visibleWidth` |
| `wrap.d`           | greedy line wrapping in cells (`writeWrappedText` / `wrapText`) — a sparkles extension              |
| `unicode_tables.d` | generated East-Asian-Width and emoji-VS-base tables (`isEastAsianWide`, `isEmojiVsBase`)            |

The width model follows kitty. Quoted passages in this document are taken from
kitty's documentation and source, **© Kovid Goyal, licensed GPL-3.0**:

- The prose spec — `docs/text-sizing-protocol.rst`, section _"The algorithm for
  splitting text into cells"_
  ([online](https://sw.kovidgoyal.net/kitty/text-sizing-protocol/#the-algorithm-for-splitting-text-into-cells)).
- The width-class implementation — `gen/wcwidth.py` (the generator that emits
  kitty's character-property tables).

> [!NOTE]
> kitty's algorithm document states it is based on **Unicode 16**. sparkles pins its
> East-Asian-Width / emoji tables to **Unicode 17.0** (see
> `libs/base/tools/gen_unicode_tables.d`), matching the toolchain's `std.uni`
> grapheme tables. Width assignments are stable across these versions for the cases
> in this spec.

## 2. Measurement model vs. kitty's placement model

kitty's algorithm is written for a terminal that **places** decoded scalars into a
cursor-addressed grid of cells. `sparkles.base.text` is a **measurement and layout**
library: it does not own a grid. The correspondence is exact:

- one kitty **cell** ⇔ one sparkles **grapheme cluster** (width 1 or 2);
- kitty's "advance the cursor by the code point's width" ⇔ `visibleWidth` summing
  each cluster's width;
- kitty's "add the code point to the previous cell" ⇔ the cluster absorbing a
  zero-width or combining member without changing its width.

So `visibleWidth(s)` equals the number of cells kitty would advance the cursor by
when printing `s` (escapes excluded — see [§9](#_9-styled-text-a-sparkles-extension)).

## 3. Decoding (safe UTF-8)

> A terminal using this algorithm must decode the bytes they receive into Unicode
> scalar values (i.e., code points except surrogates) using UTF-8. When it
> encounters any UTF-8 ill-formed subsequences, it must replace each maximal subpart
> of the ill-formed subsequence with a `U+FFFD REPLACEMENT CHARACTER` (�).
>
> — kitty Text Sizing Protocol

`grapheme.d` decodes with `std.utf.decode!(Yes.useReplacementDchar)`, which yields
`U+FFFD` for ill-formed input rather than throwing — keeping the scanner
`@nogc nothrow`. `U+FFFD` is East-Asian _ambiguous_, so it measures as width 1.
(The exact byte-grouping of a maximal ill-formed subpart is a Phobos decoding
detail and is not pinned by this spec.)

## 4. The per-code-point pipeline

kitty specifies, for each decoded code point:

> 1. First check if the code point is an ASCII control code, and handle it
>    appropriately. ASCII control codes are the code points less than `U+0032` and
>    the code point `U+0127 DEL`. The code point `U+0000 NUL` must be discarded.
> 2. Next, check if the code point is _invalid_, and if it is, discard it … Invalid
>    code points are code points with Unicode category `Cc or Cs` and 66 additional
>    code points: `[0xfdd0, 0xfdef]`, `[0xfffe, 0x10ffff-1, 0x10000]` and
>    `[0xffff, 0x10ffff, 0x10000]`.
> 3. Next, check if there is a previous cell …
> 4. Next, calculate the width in cells of the received code point, which can be 0,
>    1, or 2 …
> 5. If there is no previous cell and the code point's width is zero, the code point
>    is discarded …
> 6. If there is a previous cell, the Grapheme segmentation algorithm UAX29-C1-1 is
>    used to determine if there is a grapheme boundary …
> 7. If there is no boundary, the current code point is added to the previous cell …
> 8. If there is a boundary, but the width of the current code point is zero, it is
>    added to the previous cell …
> 9. The code point is added to the current cell and the cursor is moved forward
>    (right) by either 1 or 2 cells …
>
> — kitty Text Sizing Protocol

> [!NOTE]
> The thresholds `U+0032` and `U+0127 DEL` in step 1 are apparent typos in kitty's
> prose for `U+0020` (space) and `U+007F` (DEL). sparkles classifies controls via
> `std.uni.isControl`, which correctly covers the C0 (`U+0000`–`U+001F`), `U+007F`
> DEL, and C1 ranges, all measured as width 0.

sparkles realizes this pipeline as: segment with `byGraphemeCluster` (steps 3, 6–9),
where each cluster's width comes from `graphemeClusterWidth` ([§6](#_6-width-of-a-grapheme-cluster)),
which takes the leading scalar's width and folds zero-width members (steps 7–8).
Invalid/non-character handling (step 2) is implemented in `codepointWidth` via
`isNoncharacter`, which measures `U+FDD0`..`U+FDEF` and any `U+xxFFFE`/`U+xxFFFF` as
width 0.

## 5. Width of a single code point

kitty assigns width by these classes, in **decreasing priority**:

> 1. _Regional indicators_: 26 code points starting at `0x1F1E6`. These all have
>    width 2.
> 2. _Doublewidth_: … All code points marked `W` or `F` [in `EastAsianWidth.txt`]
>    have width two. All code points in the following ranges have width two _unless_
>    they are marked as `A`: `[0x3400, 0x4DBF], [0x4E00, 0x9FFF], [0xF900, 0xFAFF], [0x20000, 0x2FFFD], [0x30000, 0x3FFFD]`.
> 3. _Wide emoji_: … All `Basic_Emoji` have width two unless they are followed by
>    `FE0F` in the file. The leading codepoints in all `RGI_Emoji_Modifier_Sequence`
>    and `RGI_Emoji_Tag_Sequence` have width two. All code points in
>    `RGI_Emoji_Flag_Sequence` have width two.
> 4. _Marks_: These are all zero width code points. They are code points with Unicode
>    categories whose first letter is `M` or `S`. Additionally, code points with
>    Unicode category `Cf`. Finally, they include all modifier code points from
>    `RGI_Emoji_Modifier_Sequence` …
> 5. All remaining code points have a width of one cell.
>
> — kitty Text Sizing Protocol

> [!IMPORTANT]
> **Prose vs. implementation for rule 4.** kitty's _implementation_ does **not**
> treat category `S` as zero width. `gen/wcwidth.py` puts only `M*`, `Cf`,
> `Other_Default_Ignorable_Code_Point`, and emoji modifiers into `marks` (width 0);
> code points with a category starting in `S` go to a separate symbols set and keep
> the default width 1:
>
> ```python
> if category.startswith('M'):
>     marks.add(codepoint)         # M* -> width 0
> elif category.startswith('S'):
>     all_symbols.add(codepoint)   # S* -> NOT marks (width 1)
> elif category == 'Cf':
>     marks.add(codepoint)         # Cf -> width 0
> ```
>
> So `+` (`U+002B`, category `Sm`) is width **1**, not 0. **sparkles follows the
> implementation**: `codepointWidth` returns 1 for symbols.
>
> The same priority order resolves **emoji skin-tone modifiers** (`U+1F3FB`..`U+1F3FF`):
> the prose lists them under _Marks_, but they have `East_Asian_Width = W`, and
> _Doublewidth_ (rule 2) outranks _Marks_ (rule 4) — so a modifier in **isolation**
> is width **2**. It only contributes 0 _inside_ a cluster, where the leading emoji
> already sets the width.

sparkles' `codepointWidth(dchar)` implements rules 1, 2, 4, 5 directly: a regional
indicator (`U+1F1E6`..`U+1F1FF`) → 2 (they are EAW-neutral, so this is an explicit
check); noncharacters and controls/line-separators → 0; all Marks `Mn | Mc | Me`
plus `Cf` and a few conjoining ranges (`zeroWidthSet`) → 0; East-Asian `W`/`F` (via
`isEastAsianWide`, which also covers wide emoji and modifiers) → 2; everything else
→ 1. Rule 3's variation-selector adjustment is applied at the **cluster** level
([§6](#_6-width-of-a-grapheme-cluster)).

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "spec_text_codepoint_width"
    dependency "sparkles:base" version="*"
+/
import std.stdio : writefln;
import sparkles.base.text.width : codepointWidth;

void main()
{
    static struct C { string label; dchar cp; }
    static immutable C[] cps = [
        C("U+0041 LATIN A",        'A'),
        C("U+002B PLUS (Sm)",      '+'),
        C("U+4E16 CJK (EAW W)",    '世'),
        C("U+FF21 FULLWIDTH (F)",  'Ａ'),
        C("U+0301 COMB. ACUTE",    '́'),
        C("U+200B ZWSP (Cf)",      '​'),
        C("U+0009 TAB (control)",  '\t'),
    ];
    foreach (c; cps)
        writefln("%-24s width=%s", c.label, codepointWidth(c.cp));
}
```

```[Output]
U+0041 LATIN A           width=1
U+002B PLUS (Sm)         width=1
U+4E16 CJK (EAW W)       width=2
U+FF21 FULLWIDTH (F)     width=2
U+0301 COMB. ACUTE       width=0
U+200B ZWSP (Cf)         width=0
U+0009 TAB (control)     width=0
```

## 6. Width of a grapheme cluster

A cluster occupies one cell whose width is set by its **leading** scalar; combining
members add nothing, and only the variation selectors ([§7](#_7-variation-selectors))
adjust it. `graphemeClusterWidth(in dchar[])` implements exactly that. So a flag
(leading regional indicator → 2), a ZWJ family (leading wide emoji → 2), and an
emoji + skin-tone modifier (leading wide emoji → 2) each resolve to one 2-cell
cluster, while a base + spacing mark (`Mc`) stays one 1-cell cluster.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "spec_text_cluster_width"
    dependency "sparkles:base" version="*"
+/
import std.stdio : writefln;
import sparkles.base.text.width : graphemeClusterWidth;

void main()
{
    static struct C { string label; dstring s; }
    static immutable C[] cs = [
        C("A + combining acute",  "Á"d),
        C("CJK U+4E16",           "世"d),
        C("flag (RI + RI)",       "\U0001F1FA\U0001F1F8"d),
        C("thumbs-up + tone",     "\U0001F44D\U0001F3FE"d),
        C("woman ZWJ girl",       "\U0001F469‍\U0001F467"d),
        C("heart + VS16",         "❤️"d),
        C("heart (bare)",         "❤"d),
        C("heart + VS15",         "❤︎"d),
    ];
    foreach (c; cs)
        writefln("%-22s width=%s", c.label, graphemeClusterWidth(c.s));
}
```

```[Output]
A + combining acute    width=1
CJK U+4E16             width=2
flag (RI + RI)         width=2
thumbs-up + tone       width=2
woman ZWJ girl         width=2
heart + VS16           width=2
heart (bare)           width=1
heart + VS15           width=1
```

## 7. Variation selectors

> `U+FE0E` - Variation Selector 15 — When the previous cell has width two and the
> last code point in the previous cell is one of the `Basic_Emoji` code points from
> the _Wide emoji_ rule above that is _not_ followed by `FE0F` then the width of the
> previous cell is decreased to one.
>
> `U+FE0F` - Variation Selector 16 — When the previous cell has width one and the
> last code point in the previous cell is one of the `Basic_Emoji` code points from
> the _Wide emoji_ rule above that is followed by `FE0F` then the width of the
> previous cell is increased to two.
>
> — kitty Text Sizing Protocol

In `width.d`, VS16 promotion is **gated** on the base being an emoji-VS base
(`isEmojiVsBase`, generated from `emoji-variation-sequences.txt`), exactly as
specified — see the `heart + VS16` (→ 2) versus bare `heart` (→ 1) cases in
[§6](#_6-width-of-a-grapheme-cluster). `A + VS16` stays width 1 because `A` is not an
emoji base.

## 8. Grapheme segmentation (UAX29-C1-1)

> The basis for the algorithm is the Grapheme segmentation algorithm from the
> Unicode standard. … the Grapheme segmentation algorithm UAX29-C1-1 is used to
> determine if there is a grapheme boundary …
>
> — kitty Text Sizing Protocol
>
> kitty comes with a utility to test terminal compliance with this algorithm … This
> uses tests published by the Unicode consortium, `GraphemeBreakTest.txt`.

sparkles segments via `std.uni.graphemeStride` (the toolchain's Unicode-17 grapheme
tables) inside `byGraphemeCluster`. This implements the parts of UAX #29 that matter
for terminal width: **regional-indicator pairing** (a flag is one cluster) and
**emoji ZWJ sequences** (a multi-person emoji is one cluster). Both are verified in
[§6](#_6-width-of-a-grapheme-cluster) and the [conformance ledger](./test-cases.md).

## 9. Styled text (a sparkles extension)

kitty's algorithm operates on already-decoded text; ANSI escape sequences are out of
its scope. `grapheme.d` extends the model so callers can measure **styled** strings
directly: `byGraphemeCluster` yields each ANSI escape (SGR, OSC 8 hyperlink) as its
own unit with `isEscape = true` and width 0, and `visibleWidth` ignores them. Thus a
flag is still one 2-cell cluster, and color codes never inflate a measurement.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "spec_text_segmentation"
    dependency "sparkles:base" version="*"
+/
import std.stdio : writefln, writeln;
import sparkles.base.text.grapheme : byGraphemeCluster, visibleWidth;

void main()
{
    const s = "a\x1b[31m世界\x1b[0m\U0001F1FA\U0001F1F8";
    foreach (u; s.byGraphemeCluster)
        writefln("%-7s width=%s  %s", u.isEscape ? "escape" : "cluster", u.width,
            u.isEscape ? "<esc>" : u.slice.idup);
    writeln("visibleWidth = ", visibleWidth(s));
}
```

```[Output]
cluster width=1  a
escape  width=0  <esc>
cluster width=2  世
cluster width=2  界
escape  width=0  <esc>
cluster width=2  🇺🇸
visibleWidth = 7
```

## 10. Line wrapping (a sparkles extension)

kitty's protocol governs cell **width**, not line breaking. `wrap.d` adds greedy
wrapping measured in cells: it never lets a 2-cell glyph straddle the wrap column,
breaks at a documented **reduced subset of UAX #14** (spaces, ZWSP, between
ideographs, after a soft hyphen; never at NBSP / word-joiner) via `classOf`, honours
mandatory breaks, and — with `StyleContinuity` — suspends active SGR/OSC-8 state at a
wrap newline and re-emits it on the continuation line so styling never bleeds onto a
border.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "spec_text_wrapping"
    dependency "sparkles:base" version="*"
+/
import std.stdio : writeln;
import std.array : replace;
import sparkles.base.text.wrap : wrapText, WrapOptions, WhitespaceMode, StyleContinuity;

void main()
{
    // CJK breaks between ideographs (each is 2 cells; width 4 fits two).
    writeln("CJK @ width 4:");
    writeln(wrapText("世界世", WrapOptions(width: 4)));

    // Soft hyphen: the '-' appears only at a realized break.
    writeln("soft hyphen @ width 3:");
    writeln(wrapText("ab­cd", WrapOptions(width: 3, whitespace: WhitespaceMode.collapse)));

    // SGR suspended at the break and re-emitted on the next line (ESC shown as \e).
    writeln("styled @ width 3 (ESC as \\e):");
    const styled = wrapText("\x1b[31mfoo bar\x1b[0m",
        WrapOptions(width: 3, continuity: StyleContinuity.sgrReset, whitespace: WhitespaceMode.collapse));
    writeln(styled.replace("\x1b", "\\e"));
}
```

```[Output]
CJK @ width 4:
世界
世
soft hyphen @ width 3:
ab-
cd
styled @ width 3 (ESC as \e):
\e[31mfoo\e[0m
\e[31mbar\e[0m
```

## 11. Conformance

The full, executable conformance ledger — every normative case the implementation
must satisfy, with pass status — is maintained in [test cases](./test-cases.md), and
the same assertions are mirrored as `unittest`s in `width.d` / `grapheme.d`. All
cases conform to kitty:

| Rule                        | Status | Note                                           |
| --------------------------- | ------ | ---------------------------------------------- |
| EAW `W`/`F` → 2             | ✓      | also covers emoji bases & skin-tone modifiers  |
| all Marks `M*` + `Cf` → 0   | ✓      | incl. spacing marks (`Mc`) — Brahmic syllables |
| symbols (`S*`) → 1          | ✓      | matches kitty's implementation, not its prose  |
| regional indicator → 2      | ✓      | lone half and flag pair                        |
| flags, ZWJ emoji, VS16/VS15 | ✓      | segmentation + cluster width                   |
| lone emoji modifier → 2     | ✓      | EAW `W` outranks _Marks_ in isolation          |
| noncharacters discarded → 0 | ✓      | `U+FDD0`..`U+FDEF`, `U+xxFFFE`, `U+xxFFFF`     |

## 12. References

- kitty Text Sizing Protocol — <https://sw.kovidgoyal.net/kitty/text-sizing-protocol/>
  (and `docs/text-sizing-protocol.rst`, `gen/wcwidth.py` in the kitty source) — © Kovid Goyal, GPL-3.0.
- [UAX #11 East Asian Width](https://www.unicode.org/reports/tr11/)
- [UAX #14 Line Breaking](https://www.unicode.org/reports/tr14/)
- [UAX #29 Grapheme Cluster Boundaries](https://www.unicode.org/reports/tr29/#Grapheme_Cluster_Boundaries)
- [UTS #51 Emoji](https://www.unicode.org/reports/tr51/)
- [`EastAsianWidth.txt`](https://www.unicode.org/Public/UCD/latest/ucd/EastAsianWidth.txt),
  [`emoji-variation-sequences.txt`](https://www.unicode.org/Public/UCD/latest/ucd/emoji/emoji-variation-sequences.txt)
- sparkles modules: `width.d`, `grapheme.d`, `wrap.d`, `unicode_tables.d` (under
  `libs/base/src/sparkles/base/text/`); table generator
  `libs/base/tools/gen_unicode_tables.d`.
