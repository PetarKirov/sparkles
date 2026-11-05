# Unicode showcase

Text lab's **Specimen → Sample group** selects a curated set of samples.
`n` and `N` select the next and previous group. **Start at row** and
Page Up/Page Down expose later rows on small displays or at large font sizes.
**Wrapped row offset** exposes the continuation of a sample that itself wraps
past the panel's bottom. Cell-grid comparison retains natural shaping for RTL
items so their letters and brackets keep the resolved direction.
The same samples appear on dark and light panels; `--no-loupe` leaves both
unobscured. For example:

```bash
dub run :text-lab -- --showcase cjk --no-loupe --shot /tmp/cjk.png
dub run :text-lab -- --showcase rtl --no-loupe --shot /tmp/rtl.png
dub run :text-lab -- --showcase historic --sample-row 1 --no-loupe --shot /tmp/glagolitic.png
```

The inventory lives in
[`unicode_samples.d`](../../../../apps/text-lab/src/unicode_samples.d).
Each row declares its script, blocks and behavior. It is a rendering sample
set, rather than a claim to cover every Unicode block or writing system.

## Planes

| Plane                                    | Samples                                                               | Purpose                                                              |
| ---------------------------------------- | --------------------------------------------------------------------- | -------------------------------------------------------------------- |
| 0 — Basic Multilingual Plane             | Living scripts, marks, punctuation, symbols, BMP private use          | Script fallback, shaping and cell graphics                           |
| 1 — Supplementary Multilingual Plane     | Historic scripts, emoji, music, mathematical letters, legacy graphics | Four-byte UTF-8, supplementary shaping and color glyphs              |
| 2 — Supplementary Ideographic Plane      | `𠀋` U+2000B and `𠮷` U+20BB7                                         | CJK Extension B fallback                                             |
| 3 — Tertiary Ideographic Plane           | U+30729                                                               | CJK Extension G fallback                                             |
| 14 — Supplementary Special-purpose Plane | Ideographic variation selector U+E0100, England emoji tag sequence    | Format characters participate in sequences without standalone glyphs |
| 15 — Supplementary Private Use Area-A    | FiraCode Nerd Font icons U+F0001, U+F0004, U+F02DC                    | Supplementary private-use decoding and font-specific conventions     |

Plane 16 and unassigned planes are outside this sample set. A font need not
cover the first scalar of a block: the supplementary Han probes above are
characters actually covered by the bundled CJK font.

## Scripts and blocks

| Group            | Scripts                                                                                          | Blocks represented                                                                                                                                                                                                                                                                                                                                                                                                                             |
| ---------------- | ------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `overview`       | Latin, Greek, Cyrillic, Han, Hiragana, Katakana, Hangul, Braille, Common, Inherited, private use | Basic Latin; Latin-1 Supplement; Latin Extended-A; Latin Extended Additional; Greek and Coptic; Cyrillic; Combining Diacritical Marks; CJK Unified Ideographs; Hiragana; Katakana; Hangul Syllables; Emoticons; Miscellaneous Symbols; Miscellaneous Symbols and Pictographs; Combining Diacritical Marks for Symbols; Private Use Area; Arrows; Mathematical Operators; Dingbats; Number Forms; Box Drawing; Block Elements; Braille Patterns |
| `latin`          | Latin, Greek, Cyrillic, Common, Inherited                                                        | Basic Latin; Latin-1 Supplement; Latin Extended Additional; Combining Diacritical Marks; Greek and Coptic; Cyrillic; General Punctuation                                                                                                                                                                                                                                                                                                       |
| `rtl`            | Arabic, Hebrew, Latin, Common                                                                    | Arabic; Hebrew; Basic Latin; General Punctuation                                                                                                                                                                                                                                                                                                                                                                                               |
| `indic`          | Devanagari, Bengali, Tamil, Telugu, Sinhala                                                      | Devanagari; Bengali; Tamil; Telugu; Sinhala                                                                                                                                                                                                                                                                                                                                                                                                    |
| `southeastAsian` | Thai, Lao, Khmer, Myanmar, Tibetan                                                               | Thai; Lao; Khmer; Myanmar; Tibetan                                                                                                                                                                                                                                                                                                                                                                                                             |
| `cjk`            | Han, Hiragana, Katakana, Hangul, Bopomofo, Latin, Common, Inherited                              | CJK Unified Ideographs; CJK Unified Ideographs Extensions B and G; Hiragana; Katakana; Hangul Syllables; Hangul Jamo; Bopomofo; Variation Selectors Supplement; Halfwidth and Fullwidth Forms; CJK Symbols and Punctuation                                                                                                                                                                                                                     |
| `world`          | Armenian, Georgian, Ethiopic, Cherokee, Canadian Aboriginal                                      | Armenian; Georgian; Ethiopic; Cherokee; Unified Canadian Aboriginal Syllabics                                                                                                                                                                                                                                                                                                                                                                  |
| `historic`       | Glagolitic, Gothic, Deseret, Egyptian Hieroglyphs, Cuneiform, Ogham, Runic                       | Glagolitic; Gothic; Deseret; Egyptian Hieroglyphs; Cuneiform; Ogham; Runic                                                                                                                                                                                                                                                                                                                                                                     |
| `symbols`        | Common, Braille                                                                                  | Mathematical Operators; Mathematical Alphanumeric Symbols; Enclosed Alphanumerics; Number Forms; Superscripts and Subscripts; Currency Symbols; Latin-1 Supplement; Musical Symbols; Miscellaneous Technical; Box Drawing; Block Elements; Braille Patterns; Symbols for Legacy Computing                                                                                                                                                      |
| `emoji`          | Common, Inherited                                                                                | Emoticons; Supplemental Symbols and Pictographs; Dingbats; Variation Selectors; Miscellaneous Symbols and Pictographs; General Punctuation; Enclosed Alphanumeric Supplement; Basic Latin; Combining Diacritical Marks for Symbols; Tags                                                                                                                                                                                                       |
| `icons`          | Private use                                                                                      | Private Use Area; Supplementary Private Use Area-A                                                                                                                                                                                                                                                                                                                                                                                             |

Private use is a font convention, not a Unicode script. The icon samples use
FiraCode Nerd Font's assigned meanings.

The Cyrillic specimens use Bulgarian: **Здравей, свят! България Щъркел ѝ**.
The historic group includes uppercase and lowercase Glagolitic letters
from the Glagolitic block (U+2C00–U+2C5F).

## Categories and behaviors

The samples exercise uppercase/lowercase/other letters (`Lu`, `Ll`, `Lo`),
decimal/letter/other numbers (`Nd`, `Nl`, `No`), nonspacing/spacing/enclosing
marks (`Mn`, `Mc`, `Me`), separators (`Zs`), punctuation (`Pc`, `Pd`, `Ps`,
`Pe`, `Pi`, `Pf`, `Po`), symbols (`Sm`, `Sc`, `Sk`, `So`), deliberate format
controls (`Cf`), and private use (`Co`). The audit prints the actual categories
present in every row.

The selected sequences check NFC/NFD pairs, stacked and below-base marks,
Indic conjuncts and vowel reordering, Southeast Asian marks and stacks,
precomposed/decomposed Hangul, combining dakuten, supplementary Han, and
ideographic variation selectors. An unsupported ideographic variant should
retain its base glyph; these examples do not require every font to provide a
distinct alternate outline.

RTL samples exercise Arabic joining, Hebrew niqqud, mixed Latin/RTL text,
digits, bracket mirroring, ZWNJ/ZWJ and directional isolates. Paragraphs stay
in logical order. UAX #9 resolves levels before wrapping and visual order
after wrapping; each shaping item receives its resolved direction.

Emoji samples distinguish VS15 text and VS16 emoji presentation, skin tones,
ZWJ families/professions, regional flags, keycaps and a tag flag. Historic
Egyptian samples demonstrate individual signs, rather than full hieroglyphic
quadrant composition. Vertical writing is outside this showcase.

Surrogates (`Cs`), unassigned characters (`Cn`), noncharacters and arbitrary
control characters (`Cc`) are not positive glyph examples. A missing standalone
glyph for a joiner, selector or bidi control is expected; its effect on the
surrounding sequence is what matters.

## Font coverage and diagnosis

The previous APK omitted Noto CJK. Its ordinary fallback binding also selected
only regular, icon and emoji faces, and Vulkan's lookup stopped after eight
faces. Shipping many Noto script fonts therefore did not make them reachable.
Natural specimen text additionally omitted emoji presentation, and fallback
coverage incorrectly demanded standalone supplementary variation-selector
glyphs.

The bundle includes the CJK variable CFF2 collection, Music and Tibetan faces.
Each page declares its required families; background Event Horizon workers
load them, preserving collection indices, before the page's first screenshot.
Loaded font bytes remain alive for renderer borrows throughout the session.
The selected specimen face remains first for text; script fallbacks fill its
gaps. Emoji presentation prefers a color face. Explicit `--font-dir` corpora
may omit these families; the header reports missing sample fonts.

Run the coverage audit against a built font bundle:

```bash
dub run --single apps/text-lab/tools/audit-unicode.d --force -- /path/to/bundle/fonts
```

It fails for absent required fonts or uncovered visible scalars and prints a
TSV row containing planes, categories and missing codepoints for every sample.
`--force` also recompiles the imported sample inventory after edits to it.
Format controls and variation selectors do not require standalone cmap entries.
Cmap coverage is necessary but does not prove shaping or final pixels;
screenshots and renderer tests supply those separate checks.

See [specimen font hosting](./specimen-fonts.md) for fallback ownership and
[Unicode's charts](https://www.unicode.org/charts/) for the block repertoire.
