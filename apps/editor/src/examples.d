/** Editable examples exercise the shared editor without filesystem access. */
module examples;

enum Example : ubyte { none, code, unicode, protectedText }

/// Stable authored samples; these are editable documents, not rendered pictures.
string exampleText(Example example) @safe pure nothrow @nogc
{
    final switch (example)
    {
    case Example.none: return "";
    case Example.code: return q{
module example;

import std.stdio : writeln;

// Select a word, then add its next occurrence with the command palette.
void main()
{
    auto message = "Hello, Unicode! 日本語 — مرحبا";
    foreach (index; 0 .. 3)
        writeln(index, ": ", message);
}
};
    case Example.unicode: return
        "Latin: naïve, café, coöperate — e\u0301 a\u0308\n"
        ~ "Greek: Καλημέρα κόσμε\nCyrillic: Здравей, свят\n"
        ~ "Hebrew: שלום עולם (123)\nArabic: مرحبا بالعالم (123)\n"
        ~ "Mixed: abc אבג 123 العربية xyz\n"
        ~ "Devanagari: नमस्ते दुनिया\nBengali: বাংলা ভাষা\n"
        ~ "Thai: สวัสดีชาวโลก\nTamil: வணக்கம் உலகம்\n"
        ~ "CJK: 中文 日本語 한글\n"
        ~ "Emoji: 👩🏽‍💻 👨‍👩‍👧‍👦 🏳️‍🌈 🇧🇬\n"
        ~ "Math: ∑ ∫ ∞ 𝕏 𝔘 𝛼\nHistoric: 𐐀 𐎀 𓀀\n";
    case Example.protectedText: return
        "Generated header (protected)\n"
        ~ "Edit this text. The first line is protected.\n"
        ~ "Use multi-cursor and undo commands from the palette.\n";
    }
}
