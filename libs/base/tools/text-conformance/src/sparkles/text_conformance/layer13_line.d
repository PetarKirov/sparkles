module sparkles.text_conformance.layer13_line;

import std.format : format;
import std.string : lineSplitter;
import sparkles.base.text.line_break : lineOpportunities, LineBreakWorkspaceEntry;
import sparkles.base.text.utf : UtfToken;
import sparkles.base.text.unicode_algorithm : UnicodeBoundary, UnicodeBoundaryKind;
import sparkles.text_conformance.boundary_corpus : parseBoundaryRecord;
import sparkles.text_conformance.config : Config;
import sparkles.text_conformance.report : Divergence, LayerResult;
import sparkles.text_conformance.ucd : ucdText;

LayerResult runLayer13(in Config cfg)
{
    enum path = "auxiliary/LineBreakTest.txt";
    const text = ucdText(cfg.versionIdentity, path, cfg);
    LayerResult r;
    r.name = "13: owned line opportunities";
    size_t cases, boundaries, lineNumber;
    foreach (line; text.lineSplitter)
    {
        ++lineNumber;
        const record = parseBoundaryRecord(line);
        if (!record.allowed.length) continue;
        auto tokens = new UtfToken[record.scalars.length];
        foreach (i, scalar; record.scalars)
            tokens[i] = UtfToken(scalar: scalar, start: 19 + i * 3, end: 22 + i * 3);
        auto output = new UnicodeBoundary[record.allowed.length];
        auto workspace = new LineBreakWorkspaceEntry[tokens.length];
        const result = lineOpportunities(tokens, output, workspace);
        ++cases;
        if (!result.succeeded() || result.written != output.length || result.required != output.length)
        {
            r.divergences ~= Divergence(13, format("%s:%s:operation", path, lineNumber),
                format("success=%s written=%s required=%s", result.succeeded(), result.written, result.required),
                format("success=true written=%s required=%s", output.length, output.length), line);
            continue;
        }
        foreach (i, boundary; output)
        {
            ++boundaries;
            const actual = boundary.kind != UnicodeBoundaryKind.prohibited;
            // The fixture marks opportunities, not soft versus mandatory. The
            // original runner independently checks hard-break scalar semantics.
            bool mandatory;
            if (i == tokens.length)
                mandatory = true;
            else if (i != 0)
            {
                const left = tokens[i - 1].scalar;
                const right = tokens[i].scalar;
                const hard = left == 0x000A || left == 0x000B || left == 0x000C
                    || left == 0x000D || left == 0x0085 || left == 0x2028 || left == 0x2029;
                mandatory = hard && !(left == 0x000D && right == 0x000A);
            }
            const mandatoryMatches = (boundary.kind == UnicodeBoundaryKind.mandatory) == mandatory;
            if (actual == record.allowed[i] && boundary.index == i
                && boundary.offset == 19 + i * 3 && mandatoryMatches
                && (i != 0 || boundary.kind == UnicodeBoundaryKind.prohibited))
                ++r.passed;
            else
                r.divergences ~= Divergence(13, format("%s:%s:boundary=%s", path, lineNumber, i),
                    format("kind=%s index=%s offset=%s", boundary.kind, boundary.index, boundary.offset),
                    format("allowed=%s mandatory=%s index=%s offset=%s", record.allowed[i], mandatory, i, 19 + i * 3), line);
        }
    }
    if (!cases) throw new Exception("no corpus records parsed: " ~ path);
    r.notes ~= format("%s: %s cases, %s boundary checks", path, cases, boundaries);
    return r;
}
