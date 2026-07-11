#!/usr/bin/env dub
/+ dub.sdl:
    name "highlight-events-ansi"
    dependency "sparkles:syntax" path="../../.."
    targetPath "build"
+/

// The engine-agnostic core end-to-end, without any engine: a hand-built
// highlight-event stream over a D snippet, resolved against the built-in dark
// theme and folded to SGR-styled terminal output. This is exactly what a real
// engine (the tree-sitter precise mode) produces mechanically — the renderer
// neither knows nor cares where events come from.

module highlight_events_ansi;

import std.stdio : writeln;

import sparkles.syntax;

void main()
{
    const source = "const answer = readInteger(\"42\");\n";

    const labels = LabelSet.standard();
    LabelId l(string name) { return labels.find(name); }

    alias E = HighlightEvent;
    const events = [
        E.pushLabel(l("keyword.storage")),
        E.sourceSpan(0, 5), // const
        E.popLabel(),
        E.sourceSpan(5, 6),
        E.pushLabel(l("variable")),
        E.sourceSpan(6, 12), // answer
        E.popLabel(),
        E.sourceSpan(12, 13),
        E.pushLabel(l("operator")),
        E.sourceSpan(13, 14), // =
        E.popLabel(),
        E.sourceSpan(14, 15),
        E.pushLabel(l("function")),
        E.sourceSpan(15, 26), // readInteger
        E.popLabel(),
        E.pushLabel(l("punctuation.bracket")),
        E.sourceSpan(26, 27), // (
        E.popLabel(),
        E.pushLabel(l("string")),
        E.sourceSpan(27, 31), // "42"
        E.popLabel(),
        E.pushLabel(l("punctuation.bracket")),
        E.sourceSpan(31, 32), // )
        E.popLabel(),
        E.pushLabel(l("punctuation.delimiter")),
        E.sourceSpan(32, 33), // ;
        E.popLabel(),
        E.sourceSpan(33, 34),
    ];

    const theme = resolveTheme(builtinDark, labels);

    import std.array : appender;

    auto ansi = appender!string;
    renderAnsi(source, events, theme, ansi,
        AnsiOptions(depth: detectColorDepth()));
    writeln(ansi[]);

    // The same stream flattened to styled runs — the data a non-terminal
    // backend (e.g. a GPU text renderer) would consume instead of escapes.
    foreach (span; events.byStyledSpan)
    {
        const style = theme[span.label];
        writeln(span.start, "..", span.end, "  ",
            span.label ? labels.name(span.label) : "(plain)",
            style.fg.kind == Color.Kind.rgb ? " fg=rgb" : "");
    }
}
