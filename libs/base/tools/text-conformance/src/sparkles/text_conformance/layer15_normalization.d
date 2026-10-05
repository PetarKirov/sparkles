/// Official normalization invariants, omitted scalar identities, and provenance stress.
module sparkles.text_conformance.layer15_normalization;

import sparkles.text_conformance.config : Config;
import sparkles.text_conformance.report : LayerResult, Divergence;
import sparkles.text_conformance.ucd : ucdText;
import std.exception : enforce;

import sparkles.base.text.normalization;
import sparkles.base.text.transform;
import sparkles.base.text.unicode_algorithm;
import sparkles.base.text.utf : isUnicodeScalar;
import sparkles.base.text.unicode_tables : unicodeVersion;
import std.string : splitLines, split, strip, indexOf;
import std.conv : to;
import std.format : format;


private struct Harness
{
    UnicodeTransformUnit[] inputUnits, outputUnits;
    UnicodeSourceSpan[] inputSpans, outputSpans;
    UnicodeTransformEpoch[] inputEpoch, outputEpoch;
    UnicodeNormalizationItem[] items;
    size_t[] ordering;
    UnicodeTransformWorkspace input, output;
    size_t checks;
    LayerResult report;

    void setup()
    {
        enum capacity = 262144;
        inputUnits = new UnicodeTransformUnit[capacity];
        outputUnits = new UnicodeTransformUnit[capacity];
        inputSpans = new UnicodeSourceSpan[capacity];
        outputSpans = new UnicodeSourceSpan[capacity * 4];
        inputEpoch = new UnicodeTransformEpoch[1];
        outputEpoch = new UnicodeTransformEpoch[1];
        items = new UnicodeNormalizationItem[capacity];
        ordering = new size_t[capacity];
        input = UnicodeTransformWorkspace(units: inputUnits, spans: inputSpans, epoch: inputEpoch);
        output = UnicodeTransformWorkspace(units: outputUnits, spans: outputSpans, epoch: outputEpoch);
    }

    void check(scope const(dchar)[] source, scope const(dchar)[] expected,
        UnicodeNormalization form, size_t line, bool exactIdentity = false)
    {
        ++checks;
        try
        {
            performCheck(source, expected, form, line, exactIdentity);
            ++report.passed;
        }
        catch (Exception failure)
        {
            report.divergences ~= Divergence(15, format("line=%s form=%s source=%s", line, form, source),
                failure.msg, format("%s", expected), "official normalization invariant");
        }
    }

    void performCheck(scope const(dchar)[] source, scope const(dchar)[] expected,
        UnicodeNormalization form, size_t line, bool exactIdentity = false)
    {
        enforce(input.begin().succeeded());
        foreach (i, value; source)
        {
            UnicodeSourceSpan[1] spans = [UnicodeSourceSpan(i * 3, i * 3 + 1)];
            size_t first;
            enforce(input.appendSources(spans[], first).succeeded());
            enforce(input.appendUnit(UnicodeTransformUnit(value: value,
                provenanceStart: first, provenanceCount: 1)).succeeded());
        }
        input.publish();
        const sourceView = input.output();
        const result = normalizeText(sourceView, form, output,
            UnicodeNormalizationScratch(items: items, ordering: ordering));
        enforce(result.succeeded(), format("line %s form %s: status %s required %s", line, form, result.status, result.required));
        const view = output.output();
        enforce(view.valid() && view.units.length == expected.length,
            format("line %s form %s length %s expected %s", line, form, view.units.length, expected.length));
        foreach (i, value; expected)
            enforce(view.units[i].value == value,
                format("line %s form %s at %s got U+%X expected U+%X", line, form, i, view.units[i].value, value));
        enforce(sourceView.valid());
        foreach (i, value; source) enforce(sourceView.units[i].value == value);
        if (exactIdentity)
            foreach (i; 0 .. expected.length)
            {
                UnicodeSourceSpan[1] origin = [UnicodeSourceSpan(i * 3, i * 3 + 1)];
                enforce(view.contributingSourceSpans(i) == origin[],
                    format("line %s form %s at %s: exact provenance expected %s",
                        line, form, i, origin[]));
            }
    }
}

private dchar[] parseColumn(string column)
{
    dchar[] result;
    foreach (word; column.strip.split(" "))
        if (word.length) result ~= cast(dchar) to!uint(word, 16);
    return result;
}

LayerResult runLayer15(in Config cfg)
{
    enforce(unicodeVersion == "18.0.0");
    Harness harness;
    harness.report.name = "15: normalization";
    harness.setup();
    auto listedPart1 = new bool[0x110000];
    size_t rows, lineNumber;
    bool part1;
    foreach (raw; ucdText(cfg.versionIdentity, "NormalizationTest.txt", cfg).splitLines)
    {
        ++lineNumber;
        auto line = raw;
        const comment = line.indexOf('#');
        if (comment >= 0) line = line[0 .. comment];
        line = line.strip;
        if (!line.length) continue;
        if (line[0] == '@') { part1 = line == "@Part1"; continue; }
        auto columns = line.split(';');
        enforce(columns.length >= 5);
        dchar[][5] c;
        foreach (i; 0 .. 5) c[i] = parseColumn(columns[i]);
        if (part1)
        {
            enforce(c[0].length == 1);
            listedPart1[c[0][0]] = true;
        }
        foreach (i; 0 .. 5)
        {
            harness.check(c[i], c[i < 3 ? 1 : 3], UnicodeNormalization.NFC, lineNumber);
            harness.check(c[i], c[i < 3 ? 2 : 4], UnicodeNormalization.NFD, lineNumber);
            harness.check(c[i], c[3], UnicodeNormalization.NFKC, lineNumber);
            harness.check(c[i], c[4], UnicodeNormalization.NFKD, lineNumber);
        }
        ++rows;
    }
    // The official Part 1 omitted-character invariant, including unassigned scalars.
    size_t omitted;
    foreach (uint cp; 0 .. 0x110000)
    {
        if (!isUnicodeScalar(cast(dchar) cp) || listedPart1[cp]) continue;
        dchar[1] singleton = [cast(dchar) cp];
        foreach (form; [UnicodeNormalization.NFC, UnicodeNormalization.NFD,
            UnicodeNormalization.NFKC, UnicodeNormalization.NFKD])
            harness.check(singleton[], singleton[], form, 0, true);
        ++omitted;
    }
    // A 99,999-nonstarter run with descending CCC batches: no 30-mark limit/CGJ.
    enum stressLength = 100000;
    auto source = new dchar[stressLength];
    auto expected = new dchar[stressLength];
    source[0] = expected[0] = cast(dchar) 0x10FFFF;
    foreach (i; 1 .. stressLength)
        source[i] = cast(dchar)(i % 3 == 1 ? 0x0315 : i % 3 == 2 ? 0x0300 : 0x0323);
    enum marksPerClass = (stressLength - 1) / 3;
    expected[1 .. 1 + marksPerClass] = cast(dchar) 0x0323;
    expected[1 + marksPerClass .. 1 + 2 * marksPerClass] = cast(dchar) 0x0300;
    expected[1 + 2 * marksPerClass .. $] = cast(dchar) 0x0315;
    foreach (form; [UnicodeNormalization.NFC, UnicodeNormalization.NFD,
        UnicodeNormalization.NFKC, UnicodeNormalization.NFKD])
    {
        harness.check(source, expected, form, size_t.max);
        const view = harness.output.output();
        foreach (i; 1 .. stressLength)
        {
            const group = (i - 1) / marksPerClass;
            const ordinal = (i - 1) % marksPerClass;
            const original = ordinal * 3 + (group == 0 ? 3 : group == 1 ? 2 : 1);
            UnicodeSourceSpan[1] origin = [UnicodeSourceSpan(original * 3, original * 3 + 1)];
            if (!view.valid() || i >= view.units.length || view.contributingSourceSpans(i) != origin[])
            {
                harness.report.divergences ~= Divergence(15, format("stress form=%s position=%s", form, i),
                    "provenance mismatch", format("%s", origin[]), "99,999-nonstarter stable ordering provenance");
                break;
            }
        }
    }
    enforce(rows > 0, "empty official normalization corpus");
    harness.report.notes ~= format("Unicode %s normalization: %s official records x 20 invariants; %s omitted scalar identities x 4; 99,999-nonstarter provenance stress x 4; %s checks",
        unicodeVersion, rows, omitted, harness.checks);
    return harness.report;
}
