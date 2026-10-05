/// Independent raw-UCD casing oracle: all scalars and contextual locale samples.
module sparkles.text_conformance.layer16_casing;

import sparkles.text_conformance.config : Config;
import sparkles.text_conformance.report : LayerResult, Divergence;
import sparkles.text_conformance.ucd : ucdText;
import std.exception : enforce;
import std.format : format;
import sparkles.base.text.casing;
import sparkles.base.text.transform;
import sparkles.base.text.unicode_algorithm;
import sparkles.base.text.utf : UtfToken, UtfTokenKind, isUnicodeScalar;
import sparkles.base.text.boundaries : WordBoundaryWorkspace;
import std.string : split, strip, indexOf;
import std.conv : to;

private uint hex(string value) { return to!uint(value.strip, 16); }
private dchar[] sequence(string value)
{
    dchar[] result;
    foreach (word; value.strip.split) result ~= cast(dchar) hex(word);
    return result;
}
private string[] rows(string text)
{
    string[] result;
    foreach (line; text.split('\n'))
    {
        const comment = line.indexOf('#');
        if (comment >= 0) line = line[0 .. comment];
        line = line.strip;
        if (line.length) result ~= line;
    }
    return result;
}
private bool[uint] property(string text, string name)
{
    bool[uint] result;
    foreach (row; rows(text))
    {
        const fields = row.split(';');
        if (fields.length < 2 || fields[1].strip != name) continue;
        const range = fields[0].strip.split("..");
        uint first = hex(range[0]), last = range.length == 1 ? first : hex(range[1]);
        foreach (cp; first .. last + 1) result[cp] = true;
    }
    return result;
}
private struct Harness
{
    struct Rule { uint cp; dchar[] lower, title, upper; string condition; }
    uint[uint] ccc;
    bool[uint] cased, ignorable, soft;
    Rule[] rules;
    dchar[][uint] fullLower, fullUpper, fullTitle, fullFold, simpleFold, turkic;
    dchar[uint] lower, upper, title;

    bool has(bool[uint] set, dchar cp) { return (cp in set) !is null; }
    uint combining(dchar cp) { auto p = cp in ccc; return p is null ? 0 : *p; }
    bool predicate(string name, const(dchar)[] text, size_t i)
    {
        if (name == "Final_Sigma")
        {
            bool before;
            for (size_t j = i; j;)
            {
                auto cp = text[--j];
                if (has(ignorable, cp)) continue;
                before = has(cased, cp); break;
            }
            if (!before) return false;
            foreach (cp; text[i + 1 .. $])
            {
                if (has(ignorable, cp)) continue;
                return !has(cased, cp);
            }
            return true;
        }
        if (name == "After_Soft_Dotted" || name == "After_I")
        {
            for (size_t j = i; j;)
            {
                auto cp = text[--j];
                if (name == "After_I" ? cp == 0x49 : has(soft, cp)) return true;
                if (combining(cp) == 0 || combining(cp) == 230) return false;
            }
            return false;
        }
        if (name == "More_Above" || name == "Before_Dot")
        {
            foreach (cp; text[i + 1 .. $])
            {
                if (name == "More_Above" ? combining(cp) == 230 : cp == 0x307) return true;
                if (combining(cp) == 0 || (name == "Before_Dot" && combining(cp) == 230)) return false;
            }
            return false;
        }
        throw new Exception("unknown reference context " ~ name);
    }
    dchar[] reference(const(dchar)[] text, UnicodeCaseMode mode, string locale)
    {
        dchar[] result;
        foreach (i, cp; text)
        {
            bool mapped;
            foreach (rule; rules)
            {
                if (rule.cp != cp) continue;
                bool match = true;
                foreach (token; rule.condition.split)
                {
                    if (token == "tr" || token == "az" || token == "lt") match &= token == locale;
                    else
                    {
                        bool negate = token.length > 4 && token[0 .. 4] == "Not_";
                        match &= predicate(negate ? token[4 .. $] : token, text, i) != negate;
                    }
                }
                if (!match) continue;
                result ~= mode == UnicodeCaseMode.lower ? rule.lower : rule.upper;
                mapped = true; break;
            }
            if (!mapped)
            {
                auto p = mode == UnicodeCaseMode.lower ? cp in fullLower : cp in fullUpper;
                if (p is null) result ~= cp; else result ~= *p;
            }
        }
        return result;
    }

    UnicodeTransformUnit[64] iu;
    UnicodeSourceSpan[64] isp;
    UnicodeDeletion[64] ide;
    UnicodeTransformEpoch[1] ie;
    UnicodeTransformUnit[192] ou;
    UnicodeSourceSpan[128] osp;
    UnicodeDeletion[128] ode;
    UnicodeTransformEpoch[1] oe;
    ubyte[64] ctx;
    size_t[65] remap;
    UtfToken[64] tok;
    UnicodeBoundary[65] words;
    WordBoundaryWorkspace[64] wb;
    UnicodeTransformWorkspace input, output;
    UnicodeCasingScratch scratch;
    size_t checked, simpleChecked;
    LayerResult report;
    void check(const(dchar)[] text, const(dchar)[] expected, UnicodeCaseMode mode,
        string locale = "", UnicodeFoldMode fold = UnicodeFoldMode.defaultFold)
    {
        ++checked;
        try
        {
            performCheck(text, expected, mode, locale, fold);
            ++report.passed;
        }
        catch (Exception failure)
        {
            report.divergences ~= Divergence(16,
                format("input=%s mode=%s locale=%s fold=%s", text, mode, locale, fold),
                failure.msg, format("%s", expected), "raw-UCD full mapping/context oracle");
        }
    }
    void simpleCheck(uint cp, dchar actual, dchar expected, string mode)
    {
        ++simpleChecked;
        if (actual == expected) ++report.passed;
        else report.divergences ~= Divergence(16, format("U+%04X simple %s", cp, mode),
            format("U+%04X", cast(uint) actual), format("U+%04X", cast(uint) expected),
            "raw UnicodeData/CaseFolding scalar mapping");
    }
    void performCheck(const(dchar)[] text, const(dchar)[] expected, UnicodeCaseMode mode,
        string locale = "", UnicodeFoldMode fold = UnicodeFoldMode.defaultFold)
    {
        enforce(input.begin().succeeded());
        foreach (i, cp; text)
        {
            UnicodeSourceSpan[1] span = [UnicodeSourceSpan(i, i + 1)];
            size_t first;
            enforce(input.appendSources(span[], first).succeeded());
            enforce(input.appendUnit(UnicodeTransformUnit(value: cp,
                provenanceStart: first, provenanceCount: 1)).succeeded());
        }
        input.publish();
        const result = caseTransform(input.output(), output, mode, scratch, locale, fold);
        enforce(result.succeeded(), "transform failed " ~ result.status.to!string);
        const view = output.output();
        enforce(view.valid() && view.units.length == expected.length,
            "length mismatch cp=" ~ text.to!string ~ " mode=" ~ mode.to!string ~ " locale=" ~ locale);
        foreach (i, cp; expected)
            enforce(view.units[i].value == cp,
                "mapping mismatch input=" ~ text.to!string ~ " expected=" ~ expected.to!string
                ~ " actual=" ~ view.units[i].value.to!string ~ " mode=" ~ mode.to!string ~ " locale=" ~ locale);
    }
    LayerResult run(in Config cfg)
    {
        report.name = "16: casing";
        input = UnicodeTransformWorkspace(units: iu[], spans: isp[], deletions: ide[], epoch: ie[]);
        output = UnicodeTransformWorkspace(units: ou[], spans: osp[], deletions: ode[], epoch: oe[]);
        scratch = UnicodeCasingScratch(ctx[], remap[], tok[], words[], wb[]);
        foreach (row; rows(ucdText(cfg.versionIdentity, "UnicodeData.txt", cfg)))
        {
            auto f = row.split(';');
            uint cp = hex(f[0]);
            ccc[cp] = to!uint(f[3].strip);
            if (f[12].strip.length) { upper[cp] = cast(dchar) hex(f[12]); fullUpper[cp] = [upper[cp]]; }
            if (f[13].strip.length) { lower[cp] = cast(dchar) hex(f[13]); fullLower[cp] = [lower[cp]]; }
            if (f[14].strip.length) { title[cp] = cast(dchar) hex(f[14]); fullTitle[cp] = [title[cp]]; }
        }
        cased = property(ucdText(cfg.versionIdentity, "DerivedCoreProperties.txt", cfg), "Cased");
        ignorable = property(ucdText(cfg.versionIdentity, "DerivedCoreProperties.txt", cfg), "Case_Ignorable");
        soft = property(ucdText(cfg.versionIdentity, "PropList.txt", cfg), "Soft_Dotted");
        foreach (row; rows(ucdText(cfg.versionIdentity, "SpecialCasing.txt", cfg)))
        {
            auto f = row.split(';');
            Rule rule = Rule(hex(f[0]), sequence(f[1]), sequence(f[2]), sequence(f[3]), f[4].strip);
            if (rule.condition.length) rules ~= rule;
            else { fullLower[rule.cp] = rule.lower; fullTitle[rule.cp] = rule.title; fullUpper[rule.cp] = rule.upper; }
        }
        foreach (row; rows(ucdText(cfg.versionIdentity, "CaseFolding.txt", cfg)))
        {
            auto f = row.split(';'); uint cp = hex(f[0]); auto value = sequence(f[2]);
            switch (f[1].strip)
            {
            case "C": fullFold[cp] = value; simpleFold[cp] = value; break;
            case "F": fullFold[cp] = value; break;
            case "S": simpleFold[cp] = value; break;
            case "T": turkic[cp] = value; break;
            default: throw new Exception("unknown CaseFolding status " ~ f[1].strip);
            }
        }
        foreach (uint cp; 0 .. 0x110000)
        {
            if (!isUnicodeScalar(cast(dchar) cp)) continue;
            auto pl = cp in lower, pu = cp in upper, pt = cp in title, ps = cp in simpleFold;
            simpleCheck(cp, unicodeSimpleLower(cast(dchar) cp), cast(dchar)(pl is null ? cp : *pl), "lower");
            simpleCheck(cp, unicodeSimpleUpper(cast(dchar) cp), cast(dchar)(pu is null ? cp : *pu), "upper");
            simpleCheck(cp, unicodeSimpleTitle(cast(dchar) cp), cast(dchar)(pt is null ? cp : *pt), "title");
            simpleCheck(cp, unicodeSimpleFold(cast(dchar) cp), cast(dchar)(ps is null ? cp : (*ps)[0]), "fold");
            dchar[1] value = [cast(dchar) cp];
            check(value[], reference(value[], UnicodeCaseMode.lower, ""), UnicodeCaseMode.lower);
            check(value[], reference(value[], UnicodeCaseMode.upper, ""), UnicodeCaseMode.upper);
            auto pf = cp in fullFold;
            check(value[], pf is null ? value[] : *pf, UnicodeCaseMode.fullFold);
            auto ptk = cp in turkic;
            check(value[], ptk is null ? (pf is null ? value[] : *pf) : *ptk,
                UnicodeCaseMode.fullFold, "", UnicodeFoldMode.turkic);
            simpleCheck(cp, unicodeSimpleFold(cast(dchar) cp, UnicodeFoldMode.turkic),
                cast(dchar)(ptk is null ? (ps is null ? cp : (*ps)[0]) : (*ptk)[0]), "turkic fold");
            auto ptitle = cp in fullTitle;
            check(value[], ptitle is null ? value[] : *ptitle, UnicodeCaseMode.title);
        }
        // Independently evaluated contextual corpus covers every conditional rule,
        // mark blocking (ccc 0/220/230), case-ignorable and cased intersections.
        immutable dstring[] samples = ["ΟΣ", "ΟΣΑ", "Σ", "ΑΣ'", "Α\u0345Σ\u0301", "\u0345Σ",
            "ΑΣ\u0345Α", "I", "I\u0307", "I\u0323\u0307", "I\u0301\u0307", "I\u034F\u0307",
            "J\u0300", "\u012E\u0301", "\u00CC\u00CD\u0128", "i\u0307\u0301", "j\u0323\u0307",
            "i\u0301\u0307", "\u0130iI\u0131", "\u0307", "I\u0307\u0307"];
        foreach (locale; ["", "tr", "az", "lt"])
            foreach (text; samples)
                foreach (mode; [UnicodeCaseMode.lower, UnicodeCaseMode.upper])
                    check(text, reference(text, mode, locale), mode, locale);
        check("'hELLO can't ΣΟΣ \u01F3ABC \uFB03OO"d,
            "'Hello Can't Σος \u01F2abc Ffioo"d, UnicodeCaseMode.title);
        check("a\u0301BC'dEF 42fOO"d, "A\u0301bc'def 42Foo"d, UnicodeCaseMode.title);
        report.notes ~= format("casing corpus: %s full transformations; %s all-scalar simple map comparisons; root/tr/az/lt contexts", checked, simpleChecked);
        return report;
    }
}

LayerResult runLayer16(in Config cfg)
{
    Harness harness;
    return harness.run(cfg);
}
