# `sparkles.base.text` — conformance test cases

_This is the tracked conformance ledger for the
[cell-splitting & width specification](./index.md). Each row is a normative case:
its `want` width is what kitty's algorithm prescribes. The executable report below
measures the current implementation via `visibleWidth` and prints `PASS` / `FAIL`
per case. It always exits 0, so it is verified by `apps/ci` against its `[Output]`
block — which currently records the deviations as `FAIL` lines. **The goal of the
next iteration is to fix `sparkles.base.text` so every case is `PASS`**, then
re-run `ci --update` here and promote these cases into library `unittest`s._

## Ledger

`want` = kitty-normative width (in cells). `current` is shown only where it differs.

### Conformant

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

### Known deviations (must become `PASS`)

| Case                       | Input (code points) | want | current | rule                             |
| -------------------------- | ------------------- | ---- | ------- | -------------------------------- |
| base + spacing mark (`Mc`) | `U+0915 U+093E`     | 1    | 2       | Marks: all `M*` (incl. `Mc`) → 0 |
| Devanagari syllable        | `U+0915 U+0940`     | 1    | 2       | as above                         |
| lone spacing mark (`Mc`)   | `U+093E`            | 0    | 1       | as above                         |
| lone regional indicator    | `U+1F1FA`           | 2    | 1       | Regional indicators → 2          |
| lone emoji modifier        | `U+1F3FE`           | 0    | 2       | Marks: emoji modifiers → 0       |
| noncharacter               | `U+FDD0`            | 0    | 1       | invalid code points discarded    |

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
        // Conformant
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
        // Deviations (kitty-normative want; current implementation differs)
        Case("base+Mc (U+0915 U+093E)",     "का", 1),
        Case("syllable U+0915 U+0940",      "की", 1),
        Case("lone Mc U+093E",              "ा", 0),
        Case("lone RI U+1F1FA",             "\U0001F1FA", 2),
        Case("lone emoji modifier U+1F3FE", "\U0001F3FE", 0),
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
FAIL  base+Mc (U+0915 U+093E)          got=2 want=1
FAIL  syllable U+0915 U+0940           got=2 want=1
FAIL  lone Mc U+093E                   got=1 want=0
FAIL  lone RI U+1F1FA                  got=1 want=2
FAIL  lone emoji modifier U+1F3FE      got=2 want=0
FAIL  noncharacter U+FDD0              got=1 want=0
---- 12 passed, 6 failed (of 18) ----
```
