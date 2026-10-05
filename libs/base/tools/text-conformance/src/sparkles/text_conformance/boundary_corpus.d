module sparkles.text_conformance.boundary_corpus;

import std.format : format;
import std.string : lineSplitter;
import sparkles.base.text.boundaries : wordBoundaries, sentenceBoundaries,
    WordBoundaryWorkspace, SentenceBoundaryWorkspace;
import sparkles.base.text.utf : UtfToken, UtfStatus, decodePrefix;
import sparkles.base.text.unicode_algorithm : UnicodeBoundary, UnicodeBoundaryKind;
import sparkles.text_conformance.config : Config;
import sparkles.text_conformance.report : Divergence, LayerResult;
import sparkles.text_conformance.ucd : ucdText;

struct BoundaryRecord
{
    dchar[] scalars;
    bool[] allowed;
}

// Parse the raw fixture bytes without production Unicode/property helpers.
BoundaryRecord parseBoundaryRecord(string line)
{
    BoundaryRecord record;
    size_t cursor;
    bool expectBoundary = true;
    while (cursor < line.length && line[cursor] != '#')
    {
        if (line[cursor] == ' ' || line[cursor] == '\t' || line[cursor] == '\r')
        {
            ++cursor;
            continue;
        }
        if (expectBoundary)
        {
            if (cursor + 1 >= line.length || cast(ubyte) line[cursor] != 0xC3)
                throw new Exception("invalid corpus boundary marker");
            const marker = cast(ubyte) line[cursor + 1];
            if (marker != 0xB7 && marker != 0x97)
                throw new Exception("invalid corpus boundary marker");
            record.allowed ~= marker == 0xB7;
            cursor += 2;
        }
        else
        {
            uint scalar;
            size_t digits;
            while (cursor < line.length)
            {
                const c = line[cursor];
                uint digit;
                if (c >= '0' && c <= '9') digit = c - '0';
                else if (c >= 'A' && c <= 'F') digit = c - 'A' + 10;
                else if (c >= 'a' && c <= 'f') digit = c - 'a' + 10;
                else break;
                if (scalar > (uint.max - digit) / 16)
                    throw new Exception("corpus scalar overflow");
                scalar = scalar * 16 + digit;
                ++cursor;
                ++digits;
            }
            if (!digits || scalar > 0x10FFFF || (scalar >= 0xD800 && scalar <= 0xDFFF))
                throw new Exception("invalid corpus scalar");
            record.scalars ~= cast(dchar) scalar;
        }
        expectBoundary = !expectBoundary;
    }
    if (record.allowed.length && (expectBoundary || record.allowed.length != record.scalars.length + 1))
        throw new Exception("incomplete corpus record");
    return record;
}

// Independent encoding also provides the oracle's UTF-8 source endpoints.
char[] encodeBoundaryRecord(BoundaryRecord record, out size_t[] offsets)
{
    char[] bytes;
    offsets = [0];
    foreach (cp; record.scalars)
    {
        if (cp < 0x80) bytes ~= cast(char) cp;
        else if (cp < 0x800)
        {
            bytes ~= cast(char) (0xC0 | (cp >> 6));
            bytes ~= cast(char) (0x80 | (cp & 0x3F));
        }
        else if (cp < 0x10000)
        {
            bytes ~= cast(char) (0xE0 | (cp >> 12));
            bytes ~= cast(char) (0x80 | ((cp >> 6) & 0x3F));
            bytes ~= cast(char) (0x80 | (cp & 0x3F));
        }
        else
        {
            bytes ~= cast(char) (0xF0 | (cp >> 18));
            bytes ~= cast(char) (0x80 | ((cp >> 12) & 0x3F));
            bytes ~= cast(char) (0x80 | ((cp >> 6) & 0x3F));
            bytes ~= cast(char) (0x80 | (cp & 0x3F));
        }
        offsets ~= bytes.length;
    }
    return bytes;
}

LayerResult runWordSentenceCorpus(bool sentence)(in Config cfg)
{
    enum layer = sentence ? 12 : 11;
    enum path = sentence ? "auxiliary/SentenceBreakTest.txt" : "auxiliary/WordBreakTest.txt";
    const text = ucdText(cfg.versionIdentity, path, cfg);
    LayerResult r;
    r.name = sentence ? "12: owned sentence boundaries" : "11: owned word boundaries";
    size_t records, positions, lineNumber;
    foreach (line; text.lineSplitter)
    {
        ++lineNumber;
        auto record = parseBoundaryRecord(line);
        if (!record.allowed.length) continue;
        auto tokens = new UtfToken[record.scalars.length];
        auto output = new UnicodeBoundary[record.allowed.length];
        static if (sentence)
            auto workspace = new SentenceBoundaryWorkspace[record.scalars.length];
        else
            auto workspace = new WordBoundaryWorkspace[record.scalars.length];
        size_t[] byteOffsets;
        auto bytes = encodeBoundaryRecord(record, byteOffsets);
        foreach (encoding; 0 .. 2)
        {
            const decoded = encoding == 0
                ? decodePrefix(record.scalars, tokens) : decodePrefix(bytes, tokens);
            const encodingName = encoding == 0 ? "UTF-32" : "UTF-8";
            if (decoded.status != UtfStatus.end || decoded.written != tokens.length)
            {
                r.divergences ~= Divergence(layer, format("%s:%s:%s:decode", path, lineNumber, encodingName),
                    format("status=%s written=%s", decoded.status, decoded.written),
                    format("status=end written=%s", tokens.length), line);
                continue;
            }
            static if (sentence)
                const result = sentenceBoundaries(tokens, output, workspace);
            else
                const result = wordBoundaries(tokens, output, workspace);
            if (!result.succeeded() || result.written != output.length || result.required != output.length)
            {
                r.divergences ~= Divergence(layer, format("%s:%s:%s:operation", path, lineNumber, encodingName),
                    format("success=%s written=%s required=%s", result.succeeded(), result.written, result.required),
                    format("success=true written=%s required=%s", output.length, output.length), line);
                continue;
            }
            foreach (i, expected; record.allowed)
            {
                ++positions;
                const offset = encoding == 0 ? i : byteOffsets[i];
                const kind = expected ? UnicodeBoundaryKind.allowed : UnicodeBoundaryKind.prohibited;
                if (output[i].kind == kind && output[i].index == i && output[i].offset == offset)
                    ++r.passed;
                else
                    r.divergences ~= Divergence(layer, format("%s:%s:%s:boundary=%s", path, lineNumber, encodingName, i),
                        format("kind=%s index=%s offset=%s", output[i].kind, output[i].index, output[i].offset),
                        format("kind=%s index=%s offset=%s", kind, i, offset), line);
            }
        }
        ++records;
    }
    if (!records) throw new Exception("no corpus records parsed: " ~ path);
    r.notes ~= format("%s: %s records, %s UTF-32/UTF-8 boundary checks", path, records, positions);
    return r;
}
