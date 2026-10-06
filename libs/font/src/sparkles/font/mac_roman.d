/**
The Mac OS Roman character set, for platform-1 encoding-0 `cmap` subtables
(FTP25) and `name` records (FTP29).

It is a legacy byte encoding, not a Unicode algorithm: bytes below 0x80 are
ASCII, and the 128 above map through `macRomanHigh`. The table matches
HarfBuzz's (`hb-ot-cmap-table.hh`), including U+20AC at 0xDB and U+F8FF at
0xF0. Encoding the resulting scalars as UTF-8 is base's job (FTA15).
*/
module sparkles.font.mac_roman;

@safe pure nothrow @nogc:

/// The scalar of each byte 0x80–0xFF.
immutable dchar[128] macRomanHigh = [
    'Ä', 'Å', 'Ç', 'É', 'Ñ', 'Ö', 'Ü', 'á',
    'à', 'â', 'ä', 'ã', 'å', 'ç', 'é', 'è',
    'ê', 'ë', 'í', 'ì', 'î', 'ï', 'ñ', 'ó',
    'ò', 'ô', 'ö', 'õ', 'ú', 'ù', 'û', 'ü',
    '†', '°', '¢', '£', '§', '•', '¶', 'ß',
    '®', '©', '™', '´', '¨', '≠', 'Æ', 'Ø',
    '∞', '±', '≤', '≥', '¥', 'µ', '∂', '∑',
    '∏', 'π', '∫', 'ª', 'º', 'Ω', 'æ', 'ø',
    '¿', '¡', '¬', '√', 'ƒ', '≈', '∆', '«',
    '»', '…', ' ', 'À', 'Ã', 'Õ', 'Œ', 'œ',
    '–', '—', '“', '”', '‘', '’', '÷', '◊',
    'ÿ', 'Ÿ', '⁄', '€', '‹', '›', 'ﬁ', 'ﬂ',
    '‡', '·', '‚', '„', '‰', 'Â', 'Ê', 'Á',
    'Ë', 'È', 'Í', 'Î', 'Ï', 'Ì', 'Ó', 'Ô',
    '', 'Ò', 'Ú', 'Û', 'Ù', 'ı', 'ˆ', '˜',
    '¯', '˘', '˙', '˚', '¸', '˝', '˛', 'ˇ',
];

/// The scalar a Mac Roman byte stands for.
dchar macRomanToUnicode(ubyte b) => b < 0x80 ? b : macRomanHigh[b - 0x80];

/// A Unicode scalar and its Mac Roman byte.
struct MacRomanPair
{
    dchar unicode;
    ubyte mac;
}

/// All 256 bytes as `(unicode, mac)` pairs, sorted by Unicode.
immutable MacRomanPair[256] macRomanByUnicode = () {
    MacRomanPair[256] pairs;
    foreach (b; 0 .. 256)
        pairs[b] = MacRomanPair(macRomanToUnicode(cast(ubyte) b), cast(ubyte) b);
    // Insertion sort: CTFE, 256 entries.
    foreach (i; 1 .. 256)
        for (size_t j = i; j > 0 && pairs[j - 1].unicode > pairs[j].unicode; --j)
        {
            const t = pairs[j];
            pairs[j] = pairs[j - 1];
            pairs[j - 1] = t;
        }
    return pairs;
}();

/// The Mac Roman byte of `c`, or -1 when Mac Roman cannot encode it.
int unicodeToMacRoman(dchar c)
{
    size_t lo = 0, hi = macRomanByUnicode.length;
    while (lo < hi)
    {
        const mid = (lo + hi) / 2;
        if (macRomanByUnicode[mid].unicode < c) lo = mid + 1;
        else hi = mid;
    }
    return lo < macRomanByUnicode.length && macRomanByUnicode[lo].unicode == c
        ? macRomanByUnicode[lo].mac : -1;
}

///
@("macRoman.roundTrip")
@safe pure nothrow @nogc
unittest
{
    assert(macRomanToUnicode('A') == 'A' && macRomanToUnicode(0xDB) == '€');
    assert(macRomanToUnicode(0xF0) == '');
    foreach (b; 0 .. 256)
        assert(unicodeToMacRoman(macRomanToUnicode(cast(ubyte) b)) == b);
    assert(unicodeToMacRoman('Ā') == -1);
    foreach (i; 1 .. 256)
        assert(macRomanByUnicode[i - 1].unicode < macRomanByUnicode[i].unicode);
}
