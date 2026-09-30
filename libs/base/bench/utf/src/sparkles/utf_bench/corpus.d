module sparkles.utf_bench.corpus;

import std.conv : to;
import sparkles.utf_bench.reference : firstInvalid8, to16, decode16;

struct Corpus
{
    string name;
    char[] text;
    wchar[] wide;
    size_t invalid8;
    size_t invalid16;
    bool valid8;
    bool valid16;
}

private char[] fill(string tile, size_t length)
{
    auto result = new char[length];
    size_t at;
    while (length - at >= tile.length)
    {
        result[at .. at + tile.length] = tile[];
        at += tile.length;
    }
    result[at .. $] = 'a';
    return result;
}

private Corpus fromText(string name, char[] text)
{
    Corpus result;
    result.name = name;
    result.text = text;
    result.invalid8 = firstInvalid8(text);
    result.valid8 = result.invalid8 == text.length;
    if (result.valid8)
    {
        auto output = new wchar[text.length];
        const conversion = to16(text, output);
        assert(conversion.valid);
        result.wide = output[0 .. conversion.count];
        result.invalid16 = result.wide.length;
        result.valid16 = true;
    }
    return result;
}

Corpus[] corpora()
{
    Corpus[] result;
    enum string[] kinds = ["ascii", "two-byte", "cjk", "supplementary", "mixed", "nul"];
    enum string[] tiles = ["The quick brown fox 0123456789. ", "éΩж ", "漢字かな한글", "😀🌍𝄞", "aé漢😀z ", "a\0é漢😀"];
    // Exact byte sizes exercise both sides of word, SSE, AVX2 and AVX-512 blocks.
    enum size_t[] sizes = [0, 1, 7, 8, 15, 16, 31, 32, 33, 63, 64, 65, 127, 128, 129, 4096, 65536];
    foreach (k, tile; tiles)
        foreach (size; sizes)
            result ~= fromText(kinds[k] ~ "/" ~ size.to!string, fill(tile, size));

    enum string[] malformed = ["\x80", "\xC0\x80", "\xE0\x9F\xBF", "\xED\xA0\x80", "\xF4\x90\x80\x80", "\xF5\x80\x80\x80", "\xC2", "\xE1\x80", "\xF1\x80\x80", "\xE2(\xA1"];
    enum size_t[] offsets = [0, 7, 8, 15, 16, 31, 32, 33, 63, 64, 65, 127, 128, 4095, 65535];
    foreach (m, bad; malformed)
        foreach (offset; offsets)
        {
            auto text = fill("a", offset) ~ bad;
            auto c = fromText("invalid8/" ~ m.to!string ~ "/" ~ offset.to!string, text);
            assert(c.invalid8 == offset);
            result ~= c;
        }
    // Damage continuation bytes in CJK/supplementary blocks: lead, not damaged byte,
    // must be reported, including sequences straddling vector block boundaries.
    foreach (tile; ["漢", "😀"])
        foreach (offset; offsets)
            foreach (byteIndex; 0 .. tile.length)
            {
                auto text = fill("a", offset) ~ tile ~ "tail";
                text[offset + byteIndex] = '\xFF';
                auto c = fromText("corrupt/" ~ tile.length.to!string ~ "/" ~ offset.to!string ~ "/" ~ byteIndex.to!string, text);
                assert(c.invalid8 == offset);
                result ~= c;
            }
    foreach (offset; offsets)
        foreach (bad; [cast(wchar) 0xD800, cast(wchar) 0xDC00])
        {
            Corpus c;
            c.name = "invalid16/" ~ offset.to!string ~ "/" ~ (cast(uint) bad).to!string;
            c.wide = new wchar[offset + 1];
            c.wide[] = 'a';
            c.wide[offset] = bad;
            size_t at;
            uint cp;
            while (at < c.wide.length && decode16(c.wide, at, cp)) {}
            c.invalid16 = at;
            assert(at == offset);
            result ~= c;
        }
    return result;
}

struct DisplayCorpus
{
    string name;
    char[] text;
    size_t width;
    size_t[] boundaries; // exclusive UTF-8 byte offsets for every cluster
}

DisplayCorpus[] displayCorpora()
{
    DisplayCorpus[] result;
    enum string[] names = ["ascii", "two-byte", "cjk", "supplementary", "mixed", "grapheme"];
    enum string[] tiles = ["abc ", "éΩ ", "漢字 ", "😀🌍 ", "aé漢😀 ", "e\u0301 👩\u200D💻 🇧🇬 "];
    immutable size_t[][] ends = [[1, 2, 3, 4], [2, 4, 5], [3, 6, 7], [4, 8, 9], [1, 3, 6, 10, 11], [3, 4, 15, 16, 24, 25]];
    enum size_t[] widths = [4, 3, 5, 5, 7, 8];
    foreach (k, tile; tiles)
        foreach (size; [1UL, 64UL, 4096UL, 65536UL])
        {
            DisplayCorpus c;
            c.name = names[k] ~ "/" ~ size.to!string;
            c.text = fill(tile, size);
            size_t at;
            while (size - at >= tile.length)
            {
                foreach (end; ends[k]) c.boundaries ~= at + end;
                c.width += widths[k];
                at += tile.length;
            }
            while (at < size)
            {
                c.boundaries ~= ++at;
                c.width++;
            }
            result ~= c;
        }
    return result;
}
