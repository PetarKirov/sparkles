/// Official bidi property and character oracles, including paragraph and line maps.
module sparkles.text_conformance.layer14_bidi;

import sparkles.text_conformance.config : Config;
import sparkles.text_conformance.report : LayerResult, Divergence;
import sparkles.text_conformance.ucd : ucdText;
import std.format : format;
import std.exception : enforce;
import sparkles.base.text.bidi;
import sparkles.base.text.utf : UtfToken;
import sparkles.base.text.unicode_algorithm : UnicodeStatus;
import std.string : split, splitLines, strip, indexOf;
import std.conv : to;


// Representatives chosen independently from UCD Bidi_Class definitions. ON uses
// punctuation without Bidi_Paired_Bracket, as required by BidiTest's domain.
private dchar representative(string type)
{
    switch (type)
    {
    case "L": return 'a';
    case "R": return 0x05D0;
    case "AL": return 0x0627;
    case "EN": return '0';
    case "AN": return 0x0660;
    case "ES": return '+';
    case "ET": return '$';
    case "CS": return ',';
    case "NSM": return 0x0300;
    case "BN": return 0x00AD;
    case "B": return 0x2029;
    case "S": return 0x0009;
    case "WS": return ' ';
    case "ON": return '!';
    case "LRE": return 0x202A;
    case "RLE": return 0x202B;
    case "PDF": return 0x202C;
    case "LRO": return 0x202D;
    case "RLO": return 0x202E;
    case "LRI": return 0x2066;
    case "RLI": return 0x2067;
    case "FSI": return 0x2068;
    case "PDI": return 0x2069;
    default: throw new Exception("Unknown corpus class: " ~ type);
    }
}
private int[] parseLevels(string field)
{
    int[] result;
    foreach (word; split(field)) result ~= word == "x" ? -1 : to!int(word);
    return result;
}
private size_t[] parseOrder(string field)
{
    size_t[] result;
    foreach (word; split(field)) result ~= to!size_t(word);
    return result;
}
private struct Runner
{
    BidiCell[] cells;
    size_t[] sequence, visual, inverse, lineVisual;
    ubyte[] lineLevels;
    size_t cases, failures;
    LayerResult report;
    void check(dchar[] scalars, BidiDirection requested, int base,
        int[] expectedLevels, size_t[] expectedOrder, string file, size_t lineNumber)
    {
        ++cases;
        const n = scalars.length;
        if (cells.length < n)
        {
            cells = new BidiCell[n]; sequence = new size_t[n]; visual = new size_t[n];
            inverse = new size_t[n]; lineVisual = new size_t[n]; lineLevels = new ubyte[n];
        }
        auto source = new UtfToken[n];
        foreach (i, cp; scalars) source[i] = UtfToken(scalar: cp, start: 100 + i, end: 101 + i);
        auto snapshot = source.dup;
        BidiWorkspace workspace = BidiWorkspace(cells, sequence, visual);
        auto result = resolveBidiParagraph(source, requested, workspace);
        bool valid = result.outcome.status == UnicodeStatus.ok && source == snapshot;
        if (valid && base >= 0) valid = result.paragraph.baseLevel == base;
        if (valid) valid = expectedLevels.length == n;
        if (valid)
        {
            foreach (i, expected; expectedLevels)
            {
                // X9 controls retain identity but have no display position.
                if (expected < 0)
                    valid = valid && cells[i].level == bidiRemovedLevel && cells[i].logicalToVisual == bidiNoPosition;
                else valid = valid && cells[i].lineLevel == expected;
            }
            valid = valid && result.paragraph.visualToLogical == expectedOrder;
            foreach (position, logical; expectedOrder)
                valid = valid && cells[logical].logicalToVisual == position;
            BidiLineWorkspace lineWorkspace = BidiLineWorkspace(lineLevels, inverse, lineVisual);
            auto selected = resolveBidiLine(result.paragraph, 0, n, lineWorkspace);
            valid = valid && selected.outcome.status == UnicodeStatus.ok;
            if (selected.outcome.status == UnicodeStatus.ok)
            {
                valid = valid && selected.line.visualToLogical == expectedOrder;
                foreach (i, expected; expectedLevels)
                    valid = valid && selected.line.levels[i] == (expected < 0 ? bidiRemovedLevel : expected);
                foreach (position, logical; expectedOrder)
                    valid = valid && selected.line.logicalToVisual[logical] == position;
                foreach (i, expected; expectedLevels)
                    if (expected < 0) valid = valid && selected.line.logicalToVisual[i] == bidiNoPosition;
            }
        }
        if (!valid)
        {
            ++failures;
            ubyte[] actual;
            foreach (cell; result.paragraph.cells) actual ~= cell.lineLevel;
            report.divergences ~= Divergence(14,
                format("%s:%s direction=%s", file, lineNumber, requested),
                format("status=%s base=%s levels=%s order=%s", result.outcome.status,
                    result.paragraph.baseLevel, actual, result.paragraph.visualToLogical),
                format("base=%s levels=%s order=%s", base, expectedLevels, expectedOrder),
                format("scalars=%s; paragraph/line levels, inverse maps, and source identity", scalars));
        }
        else ++report.passed;
    }
}
LayerResult runLayer14(in Config cfg)
{
    Runner runner;
    runner.report.name = "14: bidi";
    int[] levels;
    size_t[] order;
    size_t propertyRows, characterRows;
    foreach (lineIndex, raw; splitLines(ucdText(cfg.versionIdentity, "BidiTest.txt", cfg)))
    {
        auto comment = indexOf(raw, '#');
        auto line = strip(comment < 0 ? raw : raw[0 .. comment]);
        if (!line.length) continue;
        if (line.length >= 8 && line[0 .. 8] == "@Levels:") { levels = parseLevels(line[8 .. $]); continue; }
        if (line.length >= 9 && line[0 .. 9] == "@Reorder:") { order = parseOrder(line[9 .. $]); continue; }
        if (line[0] == '@') continue;
        auto fields = split(line, ';'); enforce(fields.length == 2);
        dchar[] scalars; foreach (word; split(fields[0])) scalars ~= representative(word);
        const bits = to!uint(strip(fields[1]), 16);
        enforce((bits & ~7) == 0 && bits != 0);
        ++propertyRows;
        if (bits & 1) runner.check(scalars, BidiDirection.automatic, -1, levels, order, "BidiTest", lineIndex + 1);
        if (bits & 2) runner.check(scalars, BidiDirection.ltr, 0, levels, order, "BidiTest", lineIndex + 1);
        if (bits & 4) runner.check(scalars, BidiDirection.rtl, 1, levels, order, "BidiTest", lineIndex + 1);
    }
    foreach (lineIndex, raw; splitLines(ucdText(cfg.versionIdentity, "BidiCharacterTest.txt", cfg)))
    {
        auto comment = indexOf(raw, '#');
        auto line = strip(comment < 0 ? raw : raw[0 .. comment]);
        if (!line.length) continue;
        auto fields = split(line, ';'); enforce(fields.length == 5);
        dchar[] scalars; foreach (word; split(fields[0])) scalars ~= cast(dchar) to!uint(word, 16);
        const requested = to!uint(strip(fields[1])); enforce(requested <= 2);
        const direction = requested == 0 ? BidiDirection.ltr : requested == 1 ? BidiDirection.rtl : BidiDirection.automatic;
        ++characterRows;
        runner.check(scalars, direction, to!int(strip(fields[2])), parseLevels(fields[3]),
            parseOrder(fields[4]), "BidiCharacterTest", lineIndex + 1);
    }
    runner.report.notes ~= format("BidiTest rows=%s BidiCharacterTest rows=%s total direction cases=%s failures=%s",
        propertyRows, characterRows, runner.cases, runner.failures);
    enforce(propertyRows > 0 && characterRows > 0, "empty official bidi corpus");
    return runner.report;
}
