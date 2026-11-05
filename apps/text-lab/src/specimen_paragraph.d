/** Logical specimen items and UAX #9 ordering after line wrapping. */
module specimen_paragraph;

import sparkles.base.text.grapheme : byGraphemeCluster;
import sparkles.base.text.bidi : BidiDirection, BidiParagraph, BidiWorkspace,
    BidiLineWorkspace, bidiNoPosition, bidiRemovedLevel, resolveBidiParagraph, resolveBidiLine;
import sparkles.base.text.unicode_tables : bidiClass, BidiClass, script, Script;
import sparkles.base.text.utf : decodePrefix, UtfToken;
import sparkles.font.cluster_shaping : ClusterDirection;

/// One logical shaping item; its source scalars remain in their original order.
struct SpecimenItem
{
    string text;
    size_t start, end;
    ClusterDirection direction;
    bool space;
}

/// Cached paragraph metadata, independent of font, size, colors and panel.
final class SpecimenParagraph
{
    private UtfToken[] source;
    private BidiWorkspace workspace;
    private BidiParagraph paragraph;
    private BidiLineWorkspace lineWorkspace;
    SpecimenItem[] items;

    this(string text) @safe
    {
        source.length = text.length;
        const decoded = decodePrefix(text, source);
        assert(decoded.consumed == text.length);
        source.length = decoded.written;
        workspace.cells.length = source.length;
        workspace.sequence.length = source.length;
        workspace.visualToLogical.length = source.length;
        const resolved = resolveBidiParagraph(source, BidiDirection.automatic, workspace);
        assert(resolved.paragraph.source.length == source.length);
        paragraph = resolved.paragraph;
        lineWorkspace.levels.length = source.length;
        lineWorkspace.logicalToVisual.length = source.length;
        lineWorkspace.visualToLogical.length = source.length;
        size_t start;
        while (start < source.length)
        {
            if (formatControl(source[start].scalar)) { ++start; continue; }
            const space = breakSpace(source[start].scalar);
            const whitespace = bidiClass(source[start].scalar) == BidiClass.WS;
            const level = effectiveLevel(start);
            auto currentScript = script(source[start].scalar);
            size_t end = start + 1;
            while (end < source.length)
            {
                const cp = source[end].scalar;
                if (formatControl(cp) || breakSpace(cp) != space
                    || (bidiClass(cp) == BidiClass.WS) != whitespace || effectiveLevel(end) != level) break;
                const nextScript = script(cp);
                if (strongScript(nextScript))
                {
                    if (strongScript(currentScript) && currentScript != nextScript) break;
                    currentScript = nextScript;
                }
                ++end;
            }
            items ~= SpecimenItem(text[source[start].start .. source[end - 1].end], start, end,
                level & 1 ? ClusterDirection.rtl : ClusterDirection.ltr, space);
            start = end;
        }
    }

    /// Visual scalar positions for the selected wrapped line; storage is reused.
    const(size_t)[] positions(size_t start, size_t end) @safe
    {
        const resolved = resolveBidiLine(paragraph, start, end, lineWorkspace);
        assert(resolved.line.logicalToVisual.length == end - start);
        return resolved.line.logicalToVisual;
    }

    /// RTL paragraphs align wrapped lines to the right edge of the specimen.
    bool rightAligned() const @safe pure nothrow @nogc => (paragraph.baseLevel & 1) != 0;

    private ubyte effectiveLevel(size_t index) const @safe pure nothrow @nogc
    {
        // Joiners remain inside shaping items even though UAX #9 removes BN.
        while (index && paragraph.cells[index].level == bidiRemovedLevel) --index;
        const level = paragraph.cells[index].level;
        return level == bidiRemovedLevel ? paragraph.baseLevel : level;
    }
}

private bool strongScript(Script value) @safe pure nothrow @nogc
    => value != Script.Zyyy && value != Script.Zinh && value != Script.Zzzz;

private bool breakSpace(dchar cp) @safe pure nothrow @nogc
    => bidiClass(cp) == BidiClass.WS && cp != 0x00A0 && cp != 0x202F;

private bool formatControl(dchar cp) @safe pure nothrow @nogc
    => cp == 0x061C || cp == 0x200E || cp == 0x200F
        || cp >= 0x202A && cp <= 0x202E || cp >= 0x2066 && cp <= 0x2069;

/// Fit a long item at grapheme boundaries, keeping at least one whole cluster.
SpecimenItem fitSpecimenItem(Measure)(SpecimenItem item, int width, scope Measure measure)
{
    if (measure(item.text) <= width) return item;
    size_t bytes, scalars;
    foreach (cluster; item.text.byGraphemeCluster)
    {
        const end = bytes + cluster.slice.length;
        const advance = measure(item.text[0 .. end]);
        if (bytes && advance > width) break;
        bytes = end;
        scalars += cluster.codepoints;
        if (advance > width) break;
    }
    item.text = item.text[0 .. bytes];
    item.end = item.start + scalars;
    return item;
}

/// A combining sequence and a family emoji never split when a word overflows.
@("text_lab.specimen_paragraph.graphemeWrapping")
@safe unittest
{
    auto p = new SpecimenParagraph("a\u0301b");
    const first = fitSpecimenItem(p.items[0], 1,
        (string text) => cast(int) text.length);
    assert(first.text == "a\u0301" && first.end == 2);
    auto emoji = new SpecimenParagraph("👩‍💻😀");
    const cluster = fitSpecimenItem(emoji.items[0], 1,
        (string text) => cast(int) text.length);
    assert(cluster.text == "👩‍💻" && cluster.end == 3);
}

/// Arabic words reorder, while their logical UTF-8 and shaping direction survive.
@("text_lab.specimen_paragraph.arabicWords")
@safe unittest
{
    auto p = new SpecimenParagraph("مرحبا بالعالم");
    assert(p.items.length == 3 && p.rightAligned);
    assert(p.items[0].text == "مرحبا" && p.items[2].text == "بالعالم");
    const map = p.positions(p.items[0].start, p.items[$ - 1].end);
    assert(map[p.items[2].start] < map[p.items[0].start]);
    assert(p.items[0].direction == ClusterDirection.rtl);
}

/// Mixed text keeps digits LTR, removes isolate controls from drawing and keeps joiners.
@("text_lab.specimen_paragraph.mixedAndJoiners")
@safe unittest
{
    auto p = new SpecimenParagraph("ABC \u2067שלום 123\u2069 XYZ");
    assert(!p.rightAligned);
    bool digits, hebrew;
    foreach (item; p.items)
    {
        assert(item.text != "\u2067" && item.text != "\u2069");
        if (item.text == "123") { digits = true; assert(item.direction == ClusterDirection.ltr); }
        if (item.text == "שלום") { hebrew = true; assert(item.direction == ClusterDirection.rtl); }
    }
    assert(digits && hebrew);
    auto joined = new SpecimenParagraph("می\u200Cروم");
    assert(joined.items.length == 1 && joined.items[0].text == "می\u200Cروم");
}
