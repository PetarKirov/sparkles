/**
The Unicode corpus replayed through the app (`EAP17`, `EAP18`; testing §3).
Every line of the baseline corpus is opened, drawn, walked and edited
through the real application and recording host. The oracle is the base
library's grapheme segmentation over the raw bytes, never the layout under
test: every drawn row's source ranges cover the line exactly once; visual
Right and Left from the line's start visit every grapheme boundary and
stop nowhere else, whatever the direction of the text; and inserting then deleting at each
boundary changes exactly that boundary's bytes and restores the line.
*/
module unicode_corpus_test;

version (unittest):

/// One line per corpus category of testing §3.
private immutable string[] corpus = [
    "Latin NFC é and NFD é, stacked ạ́̂",
    "Ελληνικά and Кириллица",
    "عربي مرحبا بالعالم (123) [x]",
    "עִבְרִית with marks and 42",
    "हिन्दी বাংলা தமிழ் తెలుగు සිංහල",
    "ไทย ລາວ ខ្មែរ မြန်မာ བོད་",
    "かな が ぱ 한국어 한국어 漢字 𠀋",
    "𓀀𓀁 𐌰𐌱 historic",
    "emoji ☺️ 👍🏽 👩‍💻 🇧🇬 1️⃣ 🏴󠁧󠁢󠁳󠁣󠁴󠁿",
];

@("editor.app.unicodeCorpusReplay")
@safe unittest
{
    import core.time : MonoTime;
    import editor_app : EditorApp;
    import sparkles.base.text.seek : nextGraphemeBoundary;
    import sparkles.text_buffer.text : Text;
    import sparkles.ui.editor.command : EditCommand, EditKind;
    import sparkles.ui.style : defaultTwoslashPalette;
    import sparkles.ui_app.record : RecordingHost;
    import sparkles.ui_app.run_app : AppTheme, FrameSnapshot, presentApp;

    foreach (line; corpus)
    {
        size_t[] boundaries = [0];
        for (size_t at = 0; at < line.length;)
            boundaries ~= at = nextGraphemeBoundary(line, at);

        foreach (width; [80, 12]) // one row, then wrapped rows
        {
            auto app = new EditorApp;
            scope (exit) destroy(*app);
            RecordingHost host;
            host.size.width = width;
            FrameSnapshot frame;
            app.document.field.setText(line);
            app.document.field.run(EditCommand.setRange(0, 0));
            presentApp(*app, host, AppTheme(defaultTwoslashPalette()), frame);
            app.paint(host, frame.tree, frame.frames);

            // Every source byte is drawn exactly once across the rows.
            auto drawn = new int[line.length];
            foreach (node; app.paintedRowNodes)
                foreach (span; frame.tree.nodes[node].spans)
                    if (span.srcStart != size_t.max)
                        foreach (b; span.srcStart .. span.srcEnd) ++drawn[b];
            foreach (b, count; drawn)
                assert(count == 1, line);

            // The logical start is a visual edge of its row (left for LTR, right
            // for RTL): walking Right and Left from it visits every boundary.
            bool[size_t] seen = [0: true];
            foreach (direction; [1, -1])
            {
                app.document.field.run(EditCommand.setRange(0, 0));
                foreach (_; 0 .. 2 * boundaries.length + 2)
                {
                    app.document.field.run(EditCommand.grapheme(direction));
                    seen[app.document.field.state.selection.primary.head] = true;
                }
            }
            // No stop falls inside a grapheme. Visual movement collapses the two
            // logical offsets at a direction-run edge into one stop (EAD9), so a
            // bidi line may skip a boundary there, and only there.
            foreach (stop; seen.byKey)
                assert(isBoundary(boundaries, stop), line);
            foreach (b; boundaries)
                assert(b in seen || directionEdge(line, b), line ~ " misses " ~ boundaryText(b, width, seen.keys));

            // An edit at each boundary touches only that boundary.
            foreach (b; boundaries)
            {
                app.document.field.run(EditCommand.setRange(b, b));
                app.document.field.insert("x");
                assert(app.document.field.text == line[0 .. b] ~ "x" ~ line[b .. $], line);
                app.document.field.run(EditCommand.of(EditKind.undo), MonoTime.currTime);
                assert(app.document.field.text == line, line);
            }
        }
    }
}

private string boundaryText(size_t b, size_t width, size_t[] seen) @safe pure
{
    import std.algorithm : sort;
    import std.conv : text;
    return text(b, " at width ", width, "; visited ", seen.sort);
}

private bool isBoundary(in size_t[] boundaries, size_t at) @safe pure nothrow @nogc
{
    foreach (b; boundaries) if (b == at) return true;
    return false;
}

/// Whether the scripts on either side of `at` differ in direction: an
/// RTL scalar on one side and none on the other.
private bool directionEdge(string line, size_t at) @safe pure
{
    import std.utf : decode, strideBack;
    bool rtl(dchar c) => (c >= 0x0590 && c <= 0x08FF) || (c >= 0xFB1D && c <= 0xFEFC);
    // A line without right-to-left text has no run edges: it must visit everything.
    bool any;
    foreach (dchar c; line) any |= rtl(c);
    if (!any) return false;
    bool before, after;
    if (at > 0) { size_t i = at - strideBack(line, at); before = rtl(decode(line, i)); }
    if (at < line.length) { size_t i = at; after = rtl(decode(line, i)); }
    // Neutrals (spaces, digits, brackets) take their direction from context,
    // so an edge next to one is also a run edge.
    bool neutral(size_t from, bool forward)
    {
        if (forward ? from >= line.length : from == 0) return false;
        size_t i = forward ? from : from - strideBack(line, from);
        const c = decode(line, i);
        return c == ' ' || (c >= '0' && c <= '9') || c == '(' || c == ')' || c == '[' || c == ']';
    }
    return before != after || neutral(at, true) || neutral(at, false);
}
