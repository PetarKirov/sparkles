#!/usr/bin/env dub
/+ dub.sdl:
    name "text-fields"
    dependency "sparkles:base" path="../../.."
    targetPath "build"
+/

// The fixed-width field primitives from `sparkles.base.text.width`:
// `alignField` pads (never cuts), `truncateField` cuts with an ellipsis (never
// pads) — both measure terminal cells (ANSI escapes are free, CJK/emoji count
// 2), so styled and wide content lines up by what the reader sees.

module text_fields_example;

import std.stdio : writefln, writeln;

import sparkles.base.term_style : Style, stylize;
import sparkles.base.text.width : Align, alignField, truncateField;

void main()
{
    // alignField: pad to a visible-cell width — left, right, center.
    writeln("|", alignField("left", 10, Align.left), "|");
    writeln("|", alignField("right", 10, Align.right), "|");
    writeln("|", alignField("center", 10, Align.center), "|");

    // ANSI styling costs zero cells; the CJK ideograph costs two.
    writeln("|", alignField("ok".stylize(Style.green), 10, Align.right), "|");
    writeln("|", alignField("世界", 10, Align.right), "|");

    // truncateField: the cutting companion — longest grapheme prefix + '…',
    // styles reset before the ellipsis so color never bleeds past the cut.
    writeln(truncateField("a status line that is far too long", 16));
    writeln(truncateField("short enough", 16));
    writeln(truncateField("世界丂 wide clusters are never split", 5));

    // `Align.decimal` is columnar (values share a dot position) — `drawTable`
    // applies it per column; a lone field falls back to plain right:
    writeln("|", alignField("12.25", 8, Align.decimal), "|");
}
