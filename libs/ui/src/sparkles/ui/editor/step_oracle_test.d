/**
Generated tests for the editor step (`docs/specs/ui/editor.md`, Oracles).

$(UL
    $(LI A reference editor over a plain string implements the one-cursor
        commands in the most direct way, sharing no code with the editor:
        boundaries come from whole-string segmentation, not the seek queries,
        and kills, yanks and line ends are plain slicing.)
    $(LI Random multi-cursor runs check the invariants after every step:
        grapheme-boundary endpoints (`EDT3`), a normalized set (`EDT4`), no
        line break in single-line mode (`EDT8`), and undo followed by redo
        restoring text and ranges.))
*/
module sparkles.ui.editor.step_oracle_test;

version (unittest):

import sparkles.base.text.boundaries : WordBoundaryWorkspace, wordBoundaries;
import sparkles.base.text.grapheme : GraphemeSpan, GraphemeStream, scanGraphemeStream;
import sparkles.base.text.unicode_algorithm : UnicodeBoundary, UnicodeBoundaryKind;
import sparkles.base.text.unicode_tables : GeneralCategory, UnicodeProperty, generalCategory,
    unicodeProperty;
import sparkles.base.text.utf : UtfMode, UtfStatus, UtfToken, UtfTokenKind, decodeToken;
import sparkles.base.text.seek : isGraphemeBoundary;
import sparkles.ui.editor.command : Boundary, EditCommand, EditKind;
import sparkles.ui.editor.effect : EffectKind;
import sparkles.ui.editor.state : EditorOptions;
import sparkles.ui.editor.testing : Harness, show;

private:

struct Xorshift
{
    ulong state;

    size_t next(size_t bound) @safe pure nothrow @nogc
    {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        return cast(size_t)(state % bound);
    }
}

static immutable string[] pieces = [
    "a", "bc", "foo", " ", "  ", "\n", "\r\n", ".", "/", "-", "_", "7", "42",
    "é", "世", "\U0001F600", "\U0001F1FA\U0001F1F8", "क्क",
    "\t", "\xC0", "'", ",",
];

/// Whole-string segmentation, by the batch algorithms.
struct Segmentation
{
    bool[] grapheme;   // grapheme boundary at each offset
    bool[] segment;    // word ∧ grapheme boundary
    dchar[] scalarAt;  // scalar starting at each offset, or dchar.max

    this(const(char)[] s) @safe pure nothrow
    {
        grapheme = new bool[s.length + 1];
        segment = new bool[s.length + 1];
        scalarAt = new dchar[s.length + 1];
        scalarAt[] = dchar.max;
        UtfToken[] tokens;
        for (size_t i; i < s.length;)
        {
            const d = decodeToken(s[i .. $], UtfMode.replacement);
            tokens ~= UtfToken(kind: UtfTokenKind.scalar, scalar: d.token.scalar, start: i,
                end: i + d.result.consumed);
            scalarAt[i] = d.token.scalar;
            i += d.result.consumed;
        }
        GraphemeStream stream;
        stream.reset(UtfMode.replacement);
        auto spans = new GraphemeSpan[s.length + 1];
        const scanned = scanGraphemeStream(stream, s, spans, true);
        assert(scanned.status == UtfStatus.end);
        foreach (span; spans[0 .. scanned.written])
            grapheme[span.start] = true;
        grapheme[s.length] = true;
        auto words = new UnicodeBoundary[tokens.length + 1];
        auto workspace = new WordBoundaryWorkspace[tokens.length];
        assert(wordBoundaries(tokens, words, workspace).succeeded());
        foreach (b; words)
            segment[b.offset] = grapheme[b.offset] && b.kind == UnicodeBoundaryKind.allowed;
        segment[0] = segment[s.length] = true;
    }

    size_t next(size_t p) const @safe pure nothrow
    {
        foreach (i; p + 1 .. grapheme.length)
            if (grapheme[i])
                return i;
        return grapheme.length - 1;
    }

    size_t previous(size_t p) const @safe pure nothrow
    {
        foreach_reverse (i; 0 .. p)
            if (grapheme[i])
                return i;
        return 0;
    }

    bool isWord(size_t start, size_t end) const @safe pure nothrow
    {
        foreach (i; start .. end)
        {
            if (scalarAt[i] == dchar.max)
                continue;
            const c = generalCategory(scalarAt[i]);
            if ((c >= GeneralCategory.Ll && c <= GeneralCategory.Lu && c != GeneralCategory.LC)
                || (c >= GeneralCategory.Nd && c <= GeneralCategory.No) || c == GeneralCategory.Pc)
                return true;
        }
        return false;
    }

    bool blankAt(size_t p) const @safe pure nothrow
        => scalarAt[p] != dchar.max && unicodeProperty(scalarAt[p], UnicodeProperty.WSpace);
}

/// The reference editor: one caret, a string, and Readline's kill ring.
struct Reference
{
    char[] text;
    size_t caret;
    string[] ring;
    bool lastKill;
    bool lastYank;

    void apply(in EditCommand c, string inserted) @safe pure nothrow
    {
        const seg = Segmentation(text);
        bool kill;
        bool yank;
        final switch (c.kind)
        {
        case EditKind.insertText:
            text = text[0 .. caret] ~ inserted ~ text[caret .. $];
            caret += inserted.length;
            break;
        case EditKind.moveGrapheme:
            caret = c.direction < 0 ? seg.previous(caret) : seg.next(caret);
            break;
        case EditKind.deleteGrapheme:
            if (c.direction < 0)
            {
                const p = seg.previous(caret);
                text = text[0 .. p] ~ text[caret .. $];
                caret = p;
            }
            else
                text = text[0 .. caret] ~ text[seg.next(caret) .. $];
            break;
        case EditKind.moveWord:
            caret = wordTarget(seg, caret, c.direction);
            break;
        case EditKind.killWord:
            killTo(wordTarget(seg, caret, c.direction), c.direction < 0);
            kill = true;
            break;
        case EditKind.killBlankWord:
            {
                size_t p = caret;
                while (p > 0 && seg.blankAt(seg.previous(p)))
                    p = seg.previous(p);
                while (p > 0 && !seg.blankAt(seg.previous(p)))
                    p = seg.previous(p);
                killTo(p, true);
                kill = true;
            }
            break;
        case EditKind.moveLineBoundary:
            caret = c.boundary == Boundary.end ? lineEnd(caret) : lineStartToggle(seg, caret);
            break;
        case EditKind.killToLineBoundary:
            if (c.boundary == Boundary.end)
            {
                const end = lineEnd(caret);
                killTo(end > caret ? end : nextLineStart(caret), false);
            }
            else
            {
                const start = lineStart(caret);
                killTo(start < caret ? start : previousLineEnd(caret), true);
            }
            kill = true;
            break;
        case EditKind.moveDocument:
            caret = c.boundary == Boundary.start ? 0 : text.length;
            break;
        case EditKind.yank:
            if (ring.length)
            {
                text = text[0 .. caret] ~ ring[$ - 1] ~ text[caret .. $];
                caret += ring[$ - 1].length;
                yank = true;
            }
            break;
        case EditKind.none: case EditKind.insertNewline: case EditKind.insertTab:
        case EditKind.moveLine: case EditKind.movePage: case EditKind.selectAll:
        case EditKind.selectWord: case EditKind.selectLine: case EditKind.collapseToPrimary:
        case EditKind.setRange: case EditKind.addNextOccurrence: case EditKind.skipOccurrence:
        case EditKind.selectAllOccurrences: case EditKind.addCursorVertical:
        case EditKind.splitIntoLines: case EditKind.addRangeAt: case EditKind.removeRangeAt:
        case EditKind.columnSelect: case EditKind.undo: case EditKind.redo: case EditKind.earlier:
        case EditKind.later: case EditKind.yankPop: case EditKind.copy: case EditKind.cut:
        case EditKind.paste: case EditKind.pasteAnswer: case EditKind.compose:
        case EditKind.commitComposition: case EditKind.submit: case EditKind.cancel:
        case EditKind.escape:
        case EditKind.blur:
            assert(0, "not generated");
        }
        lastKill = kill;
        lastYank = yank;
    }

    /// Kill `[caret, to)` or `[to, caret)`; a kill after a kill joins it.
    void killTo(size_t to, bool backward) @safe pure nothrow
    {
        const from = to < caret ? to : caret;
        const end = to < caret ? caret : to;
        if (from == end)
            return;
        const killed = text[from .. end].idup;
        if (lastKill && ring.length)
            ring[$ - 1] = backward ? killed ~ ring[$ - 1] : ring[$ - 1] ~ killed;
        else
            ring ~= killed;
        text = text[0 .. from] ~ text[end .. $];
        caret = from;
    }

    size_t wordTarget(ref const Segmentation seg, size_t p, int direction) const @safe pure nothrow
    {
        if (direction > 0)
        {
            while (p < text.length)
            {
                size_t end = p + 1;
                while (!seg.segment[end])
                    ++end;
                size_t start = p;
                while (!seg.segment[start])
                    --start;
                p = end;
                if (seg.isWord(start, end))
                    break;
            }
            return p;
        }
        while (p > 0)
        {
            size_t start = p - 1;
            while (!seg.segment[start])
                --start;
            size_t end = p;
            while (!seg.segment[end])
                ++end;
            p = start;
            if (seg.isWord(start, end))
                break;
        }
        return p;
    }

    size_t lineStart(size_t p) const @safe pure nothrow
    {
        while (p > 0 && text[p - 1] != '\n')
            --p;
        return p;
    }

    size_t lineEnd(size_t p) const @safe pure nothrow
    {
        while (p < text.length && text[p] != '\n')
            ++p;
        if (p < text.length && p > lineStart(p) && text[p - 1] == '\r')
            --p;
        return p;
    }

    size_t nextLineStart(size_t p) const @safe pure nothrow
    {
        while (p < text.length && text[p] != '\n')
            ++p;
        return p < text.length ? p + 1 : p;
    }

    size_t previousLineEnd(size_t p) const @safe pure nothrow
        => p == 0 ? 0 : lineEnd(lineStart(p - 1));

    size_t lineStartToggle(ref const Segmentation seg, size_t p) const @safe pure nothrow
    {
        const start = lineStart(p);
        if (p != start)
            return start;
        size_t q = start;
        const end = lineEnd(start);
        while (q < end && seg.blankAt(q))
            q = seg.next(q);
        return q;
    }
}

EditCommand randomCommand(ref Xorshift random, out string inserted) @safe pure nothrow
{
    const direction = random.next(2) ? 1 : -1;
    const boundary = random.next(2) ? Boundary.end : Boundary.start;
    switch (random.next(12))
    {
    case 0: case 1: case 2:
        inserted = pieces[random.next(pieces.length)];
        return EditCommand.of(EditKind.insertText);
    case 3: return EditCommand.grapheme(direction);
    case 4: return EditCommand.deleteGrapheme(direction);
    case 5: return EditCommand.word(direction);
    case 6: return EditCommand.killWord(direction);
    case 7: return EditCommand.of(EditKind.killBlankWord);
    case 8: return EditCommand.lineBoundary(boundary);
    case 9: return EditCommand.killToLineBoundary(boundary);
    case 10: return EditCommand.document(boundary);
    default: return EditCommand.of(EditKind.yank);
    }
}

/// The editor and the reference agree on text and caret after every
/// command of random one-cursor sequences.
@("editor.oracle.referenceEditor")
@safe pure // failure messages name the command
unittest
{
    foreach (seed; [1UL, 2, 3, 4, 5, 6])
    {
        auto random = Xorshift(0x9E3779B97F4A7C15 * seed);
        auto h = Harness("|");
        Reference model;
        foreach (step; 0 .. 250)
        {
            string inserted;
            auto c = randomCommand(random, inserted);
            if (c.kind == EditKind.insertText)
                c = EditCommand.insert(h.intern(inserted));
            h.run(c);
            model.apply(c, inserted);
            assert(h.state.selection.length == 1);
            const caret = h.state.selection.primary;
            import std.conv : to;

            assert(h.state.text == model.text, "seed " ~ seed.to!string ~ " step " ~ step.to!string
                ~ " " ~ c.kind.to!string ~ "(" ~ c.direction.to!string ~ ", " ~ c.boundary.to!string
                ~ "): got " ~ show(h.state) ~ " expected " ~ model.text.idup ~ " @" ~ model.caret.to!string);
            assert(caret.head == model.caret, "caret differs from the reference");
            if (c.kind == EditKind.yank)
                continue;
            assert(caret.empty);
        }
    }
}

/// Random multi-cursor runs keep every invariant, and undo then redo
/// restores text and ranges.
@("editor.oracle.invariants")
@safe pure nothrow
unittest
{
    foreach (seed; [11UL, 12, 13, 14])
    foreach (singleLine; [false, true])
    {
        auto random = Xorshift(0xD1B54A32D192ED03 * seed);
        EditorOptions options;
        options.singleLine = singleLine;
        auto h = Harness("|", options);
        foreach (step; 0 .. 200)
        {
            string inserted;
            auto c = randomCommand(random, inserted);
            switch (random.next(10))
            {
            case 0: c = EditCommand.cursorVertical(random.next(2) ? 1 : -1); break;
            case 1: c = EditCommand.addRangeAt(random.next(h.state.text.length + 1)); break;
            case 2: c = EditCommand.of(EditKind.addNextOccurrence); break;
            case 3: c = EditCommand.of(EditKind.selectWord); break;
            case 4: c = EditCommand.grapheme(random.next(2) ? 1 : -1, true); break;
            default: break;
            }
            if (c.kind == EditKind.insertText)
                c = EditCommand.insert(h.intern(inserted), random.next(4) == 0);
            h.run(c, random.next(800));

            const text = h.state.text;
            const ranges = h.state.selection.ranges;
            assert(ranges.length >= 1 && h.state.selection.primaryIndex < ranges.length);
            foreach (i, r; ranges)
            {
                assert(isGraphemeBoundary(text, r.anchor) && isGraphemeBoundary(text, r.head),
                    "EDT3: an endpoint inside a cluster");
                if (i)
                {
                    const p = ranges[i - 1];
                    assert(p.start <= r.start, "EDT4: unsorted");
                    assert(p.end < r.start || (p.end == r.start && !p.empty && !r.empty),
                        "EDT4: ranges touch");
                }
            }
            if (singleLine)
                foreach (chunk; text.chunks)
                    foreach (ch; chunk.bytes)
                        assert(ch != '\n' && ch != '\r', "EDT8: a line break in a single line");

            // Undo then redo, on a copy.
            if (h.effects.has(EffectKind.changed))
            {
                auto copy = h;
                copy.run(EditCommand.of(EditKind.undo)).run(EditCommand.of(EditKind.redo));
                assert(copy.state.text == h.state.text, "undo then redo changed the text");
                assert(copy.state.selection == h.state.selection,
                    "undo then redo changed the ranges");
            }
        }
    }
}

/// Commands whose ranges do not interact give the same text with n cursors
/// as applied at each cursor in turn, from the end of the text backwards.
@("editor.oracle.multiCursorMatchesOneAtATime")
@safe pure // failure messages name the command
unittest
{
    auto random = Xorshift(77);
    foreach (round; 0 .. 60)
    {
        // Three lines of text, a caret somewhere in each.
        string[3] lines;
        foreach (ref line; lines)
            foreach (_; 0 .. 1 + random.next(5))
            {
                const piece = pieces[random.next(13)]; // no malformed bytes
                if (piece != "\n" && piece != "\r\n")
                    line ~= piece;
            }
        foreach (ref line; lines)
            if (line.length == 0)
                line = "a"; // an empty line would let deletion cross its break
        string marked;
        foreach (i, line; lines)
        {
            if (i)
                marked ~= "\n";
            marked ~= line ~ "|";
        }
        string inserted;
        auto c = randomCommand(random, inserted);
        if (c.kind == EditKind.yank || c.kind == EditKind.killToLineBoundary
            || c.kind == EditKind.moveDocument || c.kind == EditKind.killWord
            || c.kind == EditKind.killBlankWord || c.kind == EditKind.moveWord
            || (c.kind == EditKind.deleteGrapheme && c.direction > 0)
            || (c.kind == EditKind.moveGrapheme && c.direction > 0)
            || inserted == "\n" || inserted == "\r\n")
            continue; // these reach across the line break into another range
        auto many = Harness(marked);
        if (c.kind == EditKind.insertText)
            c = EditCommand.insert(many.intern(inserted));
        many.run(c);

        // One caret at a time, last line first.
        string expected;
        foreach_reverse (i; 0 .. 3)
        {
            string single;
            foreach (j, line; lines)
            {
                if (j)
                    single ~= "\n";
                single ~= line ~ (j == i ? "|" : "");
            }
            auto one = Harness(single);
            if (c.kind == EditKind.insertText)
                c = EditCommand.insert(one.intern(inserted));
            one.run(c);
            auto bytes = new char[one.state.text.length];
            one.state.text.copyTo(0, bytes.length, bytes);
            // Fold this line's result into the expected text.
            const lineOfCaret = one.state.text.lineOf(one.state.selection.primary.head);
            const start = one.state.text.lineStart(lineOfCaret);
            const end = one.state.text.lineEnd(lineOfCaret);
            lines[i] = bytes[start .. end].idup;
        }
        foreach (i, line; lines)
            expected ~= (i ? "\n" : "") ~ line;
        auto got = new char[many.state.text.length];
        many.state.text.copyTo(0, got.length, got);
        import std.conv : to;

        import std.array : replace;

        assert(got == expected, (c.kind.to!string ~ "(" ~ c.direction.to!string ~ "): " ~ marked
            ~ " -> " ~ show(many.state) ~ " expected " ~ expected).replace("\n", "⏎"));
    }
}
