/++
The terminal's 2-D geometry vocabulary.

$(LREF TermPosition) is a cell coordinate you can do arithmetic on — it
specializes $(REF Vector, sparkles,math,vector) with terminal-native field names
(`col`/`row`, matching SGR mouse reports, `winsize`, and `CSI row;col`) rather
than the generic pixel `x`/`y`, exactly as
$(REF Point, sparkles,ui,geometry)/`Size` specialize it for the abstract UI
grid.

$(REF TermSize, sparkles,base,term_caps) is re-exported here rather than defined:
a size is what the *capability probe* reports, so it lives in `sparkles:base`
alongside `terminalSize`, and never needs vector arithmetic. Consumers get both
halves of the vocabulary from `sparkles.tui`.

`sparkles:math` is on `importPaths` rather than a real dependency — `Vector` is
all-template, and a `dependency` would close a dub cycle through math's unittest
configuration, the same reason `sparkles:core-cli` takes the import-only route.
+/
module sparkles.tui.geometry;

import sparkles.math : Vector;

public import sparkles.base.term_caps : TermSize;

/// A cell position, 1-based in the terminal's own convention.
alias TermPosition = Vector!(ushort, 2, ["col", "row"]);

@("tui.geometry.TermPosition.fieldNames")
@safe pure nothrow @nogc
unittest
{
    const p = TermPosition(12, 3);
    assert(p.col == 12);
    assert(p.row == 3);
}
