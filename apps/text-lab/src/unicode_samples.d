/** Curated Unicode specimens and the font families needed to display them. */
module unicode_samples;

/// Small navigable sets, rather than an exhaustive character chart.
enum Showcase { overview, latin, rtl, indic, southeastAsian, cjk, world, historic, symbols, emoji, icons }

/// Metadata describes the behavior under test; source text stays in logical order.
struct UnicodeSample
{
    Showcase group;
    string label, text, scripts, blocks, behavior;
}

/// Representative samples; format controls occur only in deliberate sequences.
immutable UnicodeSample[] unicodeSamples = [
    {Showcase.overview, "Latin", "The quick brown fox jumps over the lazy dog.", "Latin", "Basic Latin", "natural advances"},
    {Showcase.overview, "Shapes", "Hamburgefontsiv  il1I|  oO0  rn m  cl d  ,.;:'\"", "Latin", "Basic Latin", "glyph distinctions"},
    {Showcase.overview, "Digits", "0123456789  +-*/=<>  ()[]{}  @#$%^&  ~`_\\", "Common", "Basic Latin", "digits and punctuation"},
    {Showcase.overview, "Code", "-> => != === <= >= :: |> <| /* */ // www 0x1F", "Common", "Basic Latin", "programming ligatures"},
    {Showcase.overview, "Accents", "café naïve façade Ångström Øresund ŁÓDŹ ẞ", "Latin", "Latin-1 Supplement; Latin Extended-A; Latin Extended Additional", "precomposed accents"},
    {Showcase.overview, "Scripts", "Ωμέγα αβγδ  Здравей, свят!  Tiếng Việt  Ğğ İı Şş", "Greek; Cyrillic; Latin", "Greek and Coptic; Cyrillic; Latin Extended Additional", "script fallback; Bulgarian Cyrillic"},
    {Showcase.overview, "Combining", "é ä ñ ô ç  Z̵̀a͓ḻg͔o", "Latin; Inherited", "Combining Diacritical Marks", "stacked marks"},
    {Showcase.overview, "CJK", "漢字 かな カナ 한국어 中文字体", "Han; Hiragana; Katakana; Hangul", "CJK Unified Ideographs; Hiragana; Katakana; Hangul Syllables", "CJK fallback"},
    {Showcase.overview, "Emoji", "😀 😎 ❤️ ❤ ✨ 👍 👍🏽 🎉 🚀", "Common", "Emoticons; Miscellaneous Symbols; Miscellaneous Symbols and Pictographs", "color and presentation"},
    {Showcase.overview, "Sequences", "👩‍💻 👨‍👩‍👧 🇧🇬 1️⃣ #️⃣ ❤️‍🔥", "Common", "Miscellaneous Symbols and Pictographs; Combining Diacritical Marks for Symbols", "grapheme sequences"},
    {Showcase.overview, "Icons", "\uE0A0 \uE0B0 \uF115 \uF07B \uF013 \uF1D3 \uE7A8 \uF489", "Private use", "Private Use Area", "Nerd Font conventions"},
    {Showcase.overview, "Symbols", "←→↑↓ ⇐⇒ ✓✗ ∑∫√∞≈≠ ±×÷ °§¶ ©®™ ½¾", "Common", "Arrows; Mathematical Operators; Dingbats; Number Forms", "symbols"},
    {Showcase.overview, "Box", "┌─┬─┐ ╔═╦═╗ ╭─╮ │ ├┼┤ ░▒▓█ ▁▂▃▄▅▆▇ ⣿⠿⠛", "Common; Braille", "Box Drawing; Block Elements; Braille Patterns", "cell alignment"},

    {Showcase.latin, "NFC / NFD", "é e\u0301 Å A\u030A ñ n\u0303", "Latin; Inherited", "Latin-1 Supplement; Combining Diacritical Marks", "canonical-equivalent shaping"},
    {Showcase.latin, "Marks", "a\u0323\u0301 o\u0302\u0301 n\u0303\u0323", "Latin; Inherited", "Combining Diacritical Marks", "above and below marks"},
    {Showcase.latin, "Vietnamese", "Tiếng Việt: Trường đại học", "Latin", "Latin Extended Additional", "multiple diacritics"},
    {Showcase.latin, "Greek", "Ελληνικά Ωμέγα αβγδ", "Greek", "Greek and Coptic", "Greek accents"},
    {Showcase.latin, "Cyrillic", "Здравей, свят! България Щъркел ѝ", "Cyrillic", "Cyrillic", "Bulgarian language"},
    {Showcase.latin, "Punct.", "‘single’ “double” «guillemets» — …", "Common", "General Punctuation; Latin-1 Supplement", "paired punctuation"},
    {Showcase.latin, "Spaces", "A B A\u00A0B A\u2009B", "Common", "Basic Latin; Latin-1 Supplement; General Punctuation", "space, NBSP, thin space"},

    {Showcase.rtl, "Arabic", "مرحبا بالعالم", "Arabic", "Arabic", "contextual joining and RTL word order"},
    {Showcase.rtl, "Marks", "العَرَبِيَّة", "Arabic", "Arabic", "Arabic vowel marks"},
    {Showcase.rtl, "Hebrew", "שָׁלוֹם עוֹלָם", "Hebrew", "Hebrew", "RTL and niqqud"},
    {Showcase.rtl, "Mixed", "ABC (שלום) 123 مرحبا", "Latin; Hebrew; Arabic", "Basic Latin; Hebrew; Arabic", "bidi levels and bracket mirroring"},
    {Showcase.rtl, "Digits", "السعر ١٢٣٫٤٥ USD", "Arabic; Latin", "Arabic; Basic Latin", "Arabic-Indic digits in mixed text"},
    {Showcase.rtl, "Joiners", "می\u200Cروم لا ل\u200Dا", "Arabic", "Arabic; General Punctuation", "ZWNJ and ZWJ shaping"},
    {Showcase.rtl, "Isolates", "ABC \u2067שלום 123\u2069 XYZ", "Latin; Hebrew", "Basic Latin; Hebrew; General Punctuation", "RLI/PDI isolation"},

    {Showcase.indic, "Devanagari", "नमस्ते क्ष त्र ज्ञ", "Devanagari", "Devanagari", "conjuncts and vowel reordering"},
    {Showcase.indic, "Bengali", "বাংলা ক্ষ", "Bengali", "Bengali", "conjuncts and dependent vowels"},
    {Showcase.indic, "Tamil", "தமிழ்", "Tamil", "Tamil", "dependent vowels"},
    {Showcase.indic, "Telugu", "తెలుగు", "Telugu", "Telugu", "syllable shaping"},
    {Showcase.indic, "Sinhala", "සිංහල", "Sinhala", "Sinhala", "syllable shaping"},
    {Showcase.indic, "Digits", "०१२३ ০১২৩ ௧௨௩", "Devanagari; Bengali; Tamil", "Devanagari; Bengali; Tamil", "decimal digit sets"},

    {Showcase.southeastAsian, "Thai", "ภาษาไทย", "Thai", "Thai", "positioned vowels and marks"},
    {Showcase.southeastAsian, "Lao", "ພາສາລາວ", "Lao", "Lao", "positioned vowels and marks"},
    {Showcase.southeastAsian, "Khmer", "ភាសាខ្មែរ", "Khmer", "Khmer", "subscript consonants"},
    {Showcase.southeastAsian, "Myanmar", "မြန်မာစာ", "Myanmar", "Myanmar", "stacking and reordering"},
    {Showcase.southeastAsian, "Tibetan", "བོད་སྐད།", "Tibetan", "Tibetan", "stacked consonants"},

    {Showcase.cjk, "Han", "漢字 中文字体 臺灣", "Han", "CJK Unified Ideographs", "unified ideographs"},
    {Showcase.cjk, "Kana", "ひらがな カタカナ が か\u3099", "Hiragana; Katakana", "Hiragana; Katakana", "voicing and combining dakuten"},
    {Showcase.cjk, "Hangul", "한글 한국어 한글", "Hangul", "Hangul Syllables; Hangul Jamo", "precomposed and decomposed syllables"},
    {Showcase.cjk, "Bopomofo", "ㄅㄆㄇㄈ", "Bopomofo", "Bopomofo", "phonetic symbols"},
    {Showcase.cjk, "SIP Han", "\U0002000B \U00020BB7", "Han", "CJK Unified Ideographs Extension B", "plane 2 scalar decoding"},
    {Showcase.cjk, "TIP Han", "\U00030729", "Han", "CJK Unified Ideographs Extension G", "plane 3 scalar decoding"},
    {Showcase.cjk, "IVS", "辻 辻\U000E0100", "Han; Inherited", "CJK Unified Ideographs; Variation Selectors Supplement", "IVS shaping; unsupported variants retain the base"},
    {Showcase.cjk, "Fullwidth", "ＡＢＣ１２３ 「日本語」、。", "Latin; Han; Common", "Halfwidth and Fullwidth Forms; CJK Symbols and Punctuation", "fullwidth forms and punctuation"},

    {Showcase.world, "Armenian", "Հայերեն", "Armenian", "Armenian", "distinct alphabet"},
    {Showcase.world, "Georgian", "ქართული", "Georgian", "Georgian", "distinct alphabet"},
    {Showcase.world, "Ethiopic", "አማርኛ", "Ethiopic", "Ethiopic", "abugida"},
    {Showcase.world, "Cherokee", "ᏣᎳᎩ", "Cherokee", "Cherokee", "syllabary"},
    {Showcase.world, "Canadian", "ᐃᓄᒃᑎᑐᑦ", "Canadian Aboriginal", "Unified Canadian Aboriginal Syllabics", "syllabics"},

    {Showcase.historic, "Glagolitic", "ⰀⰁⰂⰃⰄ ⰰⰱⰲⰳⰴ", "Glagolitic", "Glagolitic", "historic Bulgarian alphabet; upper/lowercase"},
    {Showcase.historic, "Gothic", "\U00010330\U00010331\U00010332", "Gothic", "Gothic", "supplementary alphabet"},
    {Showcase.historic, "Deseret", "\U00010400\U00010428", "Deseret", "Deseret", "supplementary upper/lowercase"},
    {Showcase.historic, "Egyptian", "\U00013000\U00013001\U00013002", "Egyptian Hieroglyphs", "Egyptian Hieroglyphs", "hieroglyph outlines"},
    {Showcase.historic, "Cuneiform", "\U00012000\U00012001\U00012002", "Cuneiform", "Cuneiform", "supplementary signs"},
    {Showcase.historic, "Ogham", "᚛ᚑᚌᚐᚋ᚜", "Ogham", "Ogham", "historic BMP script"},
    {Showcase.historic, "Runic", "ᚠᚢᚦᚨᚱᚲ", "Runic", "Runic", "historic BMP script"},

    {Showcase.symbols, "Math", "∑ ∫ √ ∞ ≈ ≠ ≤ ≥", "Common", "Mathematical Operators", "mathematical operators"},
    {Showcase.symbols, "Math SMP", "𝔄 𝔹 𝒞 𝕏", "Common", "Mathematical Alphanumeric Symbols", "supplementary mathematical letters"},
    {Showcase.symbols, "Numbers", "① Ⅳ ½ ₃ ²", "Common", "Enclosed Alphanumerics; Number Forms; Superscripts and Subscripts", "non-decimal number categories"},
    {Showcase.symbols, "Currency", "€ £ ¥ ₩ ₹ ₿", "Common", "Currency Symbols; Latin-1 Supplement", "currency symbols"},
    {Showcase.symbols, "Music", "𝄞 𝄢 𝅘𝅥 𝅘𝅥𝅮", "Common", "Musical Symbols", "supplementary notation"},
    {Showcase.symbols, "Technical", "⌘ ⌥ ⌫ ⎋ ⏎ ⌦", "Common", "Miscellaneous Technical", "technical symbols"},
    {Showcase.symbols, "Box", "┌─┬─┐ ╔═╦═╗ ╭─╮ ░▒▓█", "Common", "Box Drawing; Block Elements", "cell graphics"},
    {Showcase.symbols, "Braille", "⠁ ⠃ ⠉ ⠿ ⣿", "Braille", "Braille Patterns", "dot patterns"},
    {Showcase.symbols, "Legacy", "\U0001FB00 \U0001FB01", "Common", "Symbols for Legacy Computing", "supplementary terminal graphics"},

    {Showcase.emoji, "Faces", "😀 😎 🥳", "Common", "Emoticons; Supplemental Symbols and Pictographs", "color bitmap glyphs"},
    {Showcase.emoji, "VS15/16", "❤\uFE0E ❤\uFE0F", "Common; Inherited", "Dingbats; Variation Selectors", "text versus emoji presentation"},
    {Showcase.emoji, "Modifiers", "👍 👍🏻 👍🏽 👍🏿", "Common", "Miscellaneous Symbols and Pictographs", "skin-tone modifiers"},
    {Showcase.emoji, "ZWJ", "👩‍💻 👨‍👩‍👧 ❤️‍🔥", "Common", "Miscellaneous Symbols and Pictographs; General Punctuation", "joined emoji sequences"},
    {Showcase.emoji, "Flags", "🇧🇬 🇯🇵 🇺🇳", "Common", "Enclosed Alphanumeric Supplement", "regional-indicator pairs"},
    {Showcase.emoji, "Keycaps", "1️⃣ #️⃣ *️⃣", "Common; Inherited", "Basic Latin; Combining Diacritical Marks for Symbols", "enclosing keycap marks"},
    {Showcase.emoji, "Tags", "\U0001F3F4\U000E0067\U000E0062\U000E0065\U000E006E\U000E0067\U000E007F", "Common", "Miscellaneous Symbols and Pictographs; Tags", "England tag flag, including plane 14 controls"},

    {Showcase.icons, "PUA BMP", "\uE0A0 \uE0B0 \uF115 \uF07B \uF013 \uF1D3 \uE7A8 \uF489", "Private use", "Private Use Area", "FiraCode Nerd Font conventions"},
    {Showcase.icons, "PUA 15", "\U000F0001 \U000F0004 \U000F02DC", "Private use", "Supplementary Private Use Area-A", "font-specific supplementary icons"},
];

/// A canonical family and its bundled filename; mask selects the pages using it.
struct ShowcaseFont
{
    uint pages;
    string family, filename;
    uint faceIndex; /// exact member of the canonical bundled collection
}

private uint pages(Showcase[] groups...) @safe pure nothrow @nogc
{
    uint result;
    foreach (group; groups) result |= 1u << cast(uint) group;
    return result;
}

/// Page fonts load lazily; loaded bytes remain pinned for the session's renderers.
immutable ShowcaseFont[] showcaseFonts = [
    {uint.max, "Noto Sans", "NotoSans.ttf"},
    {pages(Showcase.overview, Showcase.symbols, Showcase.emoji), "DejaVu Sans Mono", "DejaVuSansMono.ttf"},
    {pages(Showcase.overview, Showcase.cjk), "Noto Sans CJK SC", "NotoSansCJK-VF.otf.ttc", 2},
    {pages(Showcase.overview, Showcase.icons), "FiraCode Nerd Font Mono", "FiraCodeNerdFontMono-Regular.ttf"},
    {pages(Showcase.overview, Showcase.emoji), "Noto Color Emoji", "NotoColorEmoji.ttf"},
    {pages(Showcase.rtl), "Noto Sans Arabic", "NotoSansArabic.ttf"},
    {pages(Showcase.rtl), "Noto Sans Hebrew", "NotoSansHebrew.ttf"},
    {pages(Showcase.indic), "Noto Sans Devanagari", "NotoSansDevanagari.ttf"},
    {pages(Showcase.indic), "Noto Sans Bengali", "NotoSansBengali.ttf"},
    {pages(Showcase.indic), "Noto Sans Tamil", "NotoSansTamil.ttf"},
    {pages(Showcase.indic), "Noto Sans Telugu", "NotoSansTelugu.ttf"},
    {pages(Showcase.indic), "Noto Sans Sinhala", "NotoSansSinhala.ttf"},
    {pages(Showcase.southeastAsian), "Noto Sans Thai", "NotoSansThai.ttf"},
    {pages(Showcase.southeastAsian), "Noto Sans Lao", "NotoSansLao.ttf"},
    {pages(Showcase.southeastAsian), "Noto Sans Khmer", "NotoSansKhmer.ttf"},
    {pages(Showcase.southeastAsian), "Noto Sans Myanmar", "NotoSansMyanmar.ttf"},
    {pages(Showcase.southeastAsian), "Noto Serif Tibetan", "NotoSerifTibetan.ttf"},
    {pages(Showcase.world), "Noto Sans Armenian", "NotoSansArmenian.ttf"},
    {pages(Showcase.world), "Noto Sans Georgian", "NotoSansGeorgian.ttf"},
    {pages(Showcase.world), "Noto Sans Ethiopic", "NotoSansEthiopic.ttf"},
    {pages(Showcase.world), "Noto Sans Cherokee", "NotoSansCherokee.ttf"},
    {pages(Showcase.world), "Noto Sans Canadian Aboriginal", "NotoSansCanadianAboriginal.ttf"},
    {pages(Showcase.historic), "Noto Sans Glagolitic", "NotoSansGlagolitic-Regular.otf"},
    {pages(Showcase.historic), "Noto Sans Gothic", "NotoSansGothic-Regular.otf"},
    {pages(Showcase.historic), "Noto Sans Deseret", "NotoSansDeseret-Regular.otf"},
    {pages(Showcase.historic), "Noto Sans Egyptian Hieroglyphs", "NotoSansEgyptianHieroglyphs-Regular.otf"},
    {pages(Showcase.historic), "Noto Sans Cuneiform", "NotoSansCuneiform-Regular.otf"},
    {pages(Showcase.historic), "Noto Sans Ogham", "NotoSansOgham-Regular.otf"},
    {pages(Showcase.historic), "Noto Sans Runic", "NotoSansRunic-Regular.otf"},
    {pages(Showcase.overview, Showcase.symbols, Showcase.emoji), "Noto Sans Symbols 2", "NotoSansSymbols2-Regular.otf"},
    {pages(Showcase.symbols), "Noto Sans Symbols", "NotoSansSymbols.ttf"},
    {pages(Showcase.symbols), "Noto Sans Math", "NotoSansMath-Regular.otf"},
    {pages(Showcase.symbols), "Noto Music", "NotoMusic-Regular.otf"},
];

/// Every page has specimens, named behavior, and bounded display labels.
@("text_lab.unicode_samples.pageInventory")
@safe pure unittest
{
    uint[Showcase.max + 1] counts;
    uint planeMask;
    foreach (sample; unicodeSamples)
    {
        ++counts[sample.group];
        assert(sample.label.length && sample.label.length <= 11);
        assert(sample.text.length && sample.scripts.length && sample.blocks.length && sample.behavior.length);
        foreach (dchar cp; sample.text) planeMask |= 1u << (cp >> 16);
    }
    foreach (count; counts) assert(count);
    foreach (plane; [0, 1, 2, 3, 14, 15]) assert(planeMask & (1u << plane));
}

/// Bulgarian Cyrillic and the Glagolitic block are explicit inventory entries.
@("text_lab.unicode_samples.bulgarianAndGlagolitic")
@safe pure unittest
{
    bool bulgarian, glagolitic;
    foreach (sample; unicodeSamples)
    {
        if (sample.label == "Cyrillic")
        {
            assert(sample.text == "Здравей, свят! България Щъркел ѝ");
            bulgarian = true;
        }
        if (sample.blocks == "Glagolitic")
        {
            assert(sample.group == Showcase.historic && sample.scripts == "Glagolitic");
            foreach (dchar cp; sample.text)
                assert(cp == ' ' || cp >= 0x2C00 && cp <= 0x2C5F);
            glagolitic = true;
        }
    }
    assert(bulgarian && glagolitic);
}
