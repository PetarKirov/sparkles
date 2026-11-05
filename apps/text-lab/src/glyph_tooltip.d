/** Presentation of renderer-supplied glyph provenance and Unicode properties. */
module glyph_tooltip;

import std.conv : text;
import std.format : format;
import sparkles.base.text.unicode_tables : bidiClass, generalCategory, script;
import sparkles.base.text.utf : decodeToken;
import sparkles.ui_vulkan.painter : GlyphInspection;

/// Owned lines suitable for both a hover tooltip and a retained touch popup.
string[] glyphTooltipLines(string source, string sample, in GlyphInspection glyph) @safe
{
    string[] lines = [text("Glyph ", glyph.glyph,
        glyph.glyph == 0 ? " · missing glyph"
            : glyph.glyphName.length ? " · " ~ glyph.glyphName : " · unnamed"),
        "Face: " ~ (glyph.faceName.length ? glyph.faceName : "Name unavailable"),
        format("%s · member %s · %s", glyph.fallback ? "Fallback" : "Selected font",
            glyph.faceIndex, glyph.colour ? "colour capable" : "outline"),
        format("%.2f px/em · advance %.2f px", glyph.ppem, glyph.advance),
        format("Offset %.2f, %.2f px · bytes %s..%s", glyph.xOffset, glyph.yOffset,
            glyph.start, glyph.end),
        text(sample, " · ", glyph.shaped ? "shaped" : "cell rendering",
            " · flags ", glyph.flags)];
    if (glyph.glyphs.length > 1) lines ~= text("Source-span glyphs: ", glyph.glyphs);
    size_t count;
    while (source.length && count < 8)
    {
        const decoded = decodeToken(source);
        if (!decoded.result.consumed) break;
        const cp = decoded.token.scalar;
        lines ~= format("U+%04X · %s · %s · %s", cast(uint) cp,
            script(cp), generalCategory(cp), bidiClass(cp));
        source = source[decoded.result.consumed .. $];
        ++count;
    }
    if (source.length) lines ~= "… more codepoints in this cluster";
    return lines;
}

/// The popup exposes actual serving-face identity and every codepoint in a
/// small multi-scalar cluster, rather than guessing a face from its family.
@("text_lab.glyphTooltip.provenanceAndUnicode")
@safe unittest
{
    import std.algorithm.searching : canFind;
    const glyph = GlyphInspection(found: true, shaped: true, fallback: true,
        faceName: "Noto Sans Glagolitic", glyph: 42, faceIndex: 2, advance: 24);
    const lines = glyphTooltipLines("Ⰰ\u0301", "Glagolitic", glyph);
    assert(lines[1] == "Face: Noto Sans Glagolitic");
    assert(lines[2].canFind("Fallback") && lines[2].canFind("member 2"));
    assert(lines[6].canFind("U+2C00") && lines[7].canFind("U+0301"));
}
