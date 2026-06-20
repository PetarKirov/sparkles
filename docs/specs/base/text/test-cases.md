# `sparkles.base.text` — conformance test cases

_This is the tracked conformance ledger for the
[cell-splitting & width specification](./index.md). Each row is a normative case:
its `want` width is what kitty's algorithm prescribes. The executable report below
measures the implementation via `visibleWidth` and prints `PASS` / `FAIL` per case,
then a tally; it is verified by `apps/ci` against its `[Output]` block. **All cases
currently pass.** The same assertions also live as library `unittest`s in `width.d`
and `grapheme.d`._

## Ledger

`want` = kitty-normative width (in cells).

| Case                           | Input (code points)      | want | status |
| ------------------------------ | ------------------------ | ---- | ------ |
| ASCII letter                   | `U+0041`                 | 1    | ✓      |
| CJK ideograph (EAW W)          | `U+4E16`                 | 2    | ✓      |
| Fullwidth letter (EAW F)       | `U+FF21`                 | 2    | ✓      |
| base + combining mark (`Mn`)   | `U+0041 U+0301`          | 1    | ✓      |
| zero-width space (`Cf`)        | `U+200B`                 | 0    | ✓      |
| flag (regional-indicator pair) | `U+1F1FA U+1F1F8`        | 2    | ✓      |
| emoji + skin-tone modifier     | `U+1F44D U+1F3FE`        | 2    | ✓      |
| ZWJ family                     | `U+1F469 U+200D U+1F467` | 2    | ✓      |
| emoji base + VS16              | `U+2764 U+FE0F`          | 2    | ✓      |
| emoji base bare (ambiguous)    | `U+2764`                 | 1    | ✓      |
| emoji base + VS15              | `U+2764 U+FE0E`          | 1    | ✓      |
| styled text (escapes width 0)  | `ESC[31m h i ESC[0m`     | 2    | ✓      |
| base + spacing mark (`Mc`)     | `U+0915 U+093E`          | 1    | ✓      |
| Devanagari syllable            | `U+0915 U+0940`          | 1    | ✓      |
| lone spacing mark (`Mc`)       | `U+093E`                 | 0    | ✓      |
| lone regional indicator        | `U+1F1FA`                | 2    | ✓      |
| lone emoji modifier            | `U+1F3FE`                | 2    | ✓      |
| noncharacter                   | `U+FDD0`                 | 0    | ✓      |

### Notes on the trickier rows

Several rows were brought into conformance by the width-class fixes in `width.d`:

- **Spacing marks (`Mc`)** are now zero width (all Marks `M*` join `Cf` in the
  zero-width set), so a Brahmic syllable such as `U+0915 U+093E` is one 1-cell
  cluster — not two cells.
- **A lone regional indicator** is width 2 (`EastAsianWidth.txt` marks `U+1F1E6`..`U+1F1FF`
  as neutral, but kitty's flag rule overrides them to 2).
- **Noncharacters** (`U+FDD0`..`U+FDEF`, `U+xxFFFE`, `U+xxFFFF`) are discarded → 0.
- **A lone emoji modifier** is width **2**, not 0. kitty's prose lists modifiers
  under zero-width _Marks_, but `U+1F3FB`..`U+1F3FF` have `East_Asian_Width = W`, and
  in kitty's priority order _Doublewidth_ outranks _Marks_, so a modifier in
  isolation is 2 (it only ever contributes 0 _inside_ a cluster, where the leading
  emoji already sets the width). sparkles matches this.

## Executable report

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "spec_text_conformance"
    dependency "sparkles:base" version="*"
+/
import std.stdio : writefln;
import sparkles.base.text.grapheme : visibleWidth;

struct Case { string label; string input; size_t want; }

void main()
{
    // `want` is the kitty-normative width, measured via the top-level visibleWidth.
    static immutable Case[] cases = [
        Case("ASCII 'A'",                   "A", 1),
        Case("CJK U+4E16",                  "世", 2),
        Case("Fullwidth U+FF21",            "Ａ", 2),
        Case("base+Mn (A+U+0301)",          "Á", 1),
        Case("ZWSP U+200B",                 "​", 0),
        Case("flag US",                     "\U0001F1FA\U0001F1F8", 2),
        Case("emoji+tone",                  "\U0001F44D\U0001F3FE", 2),
        Case("ZWJ family",                  "\U0001F469‍\U0001F467", 2),
        Case("heart+VS16",                  "❤️", 2),
        Case("heart bare (ambiguous)",      "❤", 1),
        Case("heart+VS15",                  "❤︎", 1),
        Case("styled (escapes=0)",          "\x1b[31mhi\x1b[0m", 2),
        Case("base+Mc (U+0915 U+093E)",     "का", 1),
        Case("syllable U+0915 U+0940",      "की", 1),
        Case("lone Mc U+093E",              "ा", 0),
        Case("lone RI U+1F1FA",             "\U0001F1FA", 2),
        Case("lone emoji modifier U+1F3FE", "\U0001F3FE", 2),
        Case("noncharacter U+FDD0",         "﷐", 0),
    ];

    size_t pass, fail;
    foreach (c; cases)
    {
        const got = visibleWidth(c.input);
        if (got == c.want) { writefln("PASS  %-32s width=%s", c.label, got); ++pass; }
        else { writefln("FAIL  %-32s got=%s want=%s", c.label, got, c.want); ++fail; }
    }
    writefln("---- %s passed, %s failed (of %s) ----", pass, fail, pass + fail);
}
```

```[Output]
PASS  ASCII 'A'                        width=1
PASS  CJK U+4E16                       width=2
PASS  Fullwidth U+FF21                 width=2
PASS  base+Mn (A+U+0301)               width=1
PASS  ZWSP U+200B                      width=0
PASS  flag US                          width=2
PASS  emoji+tone                       width=2
PASS  ZWJ family                       width=2
PASS  heart+VS16                       width=2
PASS  heart bare (ambiguous)           width=1
PASS  heart+VS15                       width=1
PASS  styled (escapes=0)               width=2
PASS  base+Mc (U+0915 U+093E)          width=1
PASS  syllable U+0915 U+0940           width=1
PASS  lone Mc U+093E                   width=0
PASS  lone RI U+1F1FA                  width=2
PASS  lone emoji modifier U+1F3FE      width=2
PASS  noncharacter U+FDD0              width=0
---- 18 passed, 0 failed (of 18) ----
```
