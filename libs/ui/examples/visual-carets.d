#!/usr/bin/env dub
/+ dub.sdl:
name "editor-visual-carets"
targetPath "build"
dependency "sparkles:ui" path="../../.."
buildType "checked" {
    buildOptions "optimize" "inline" "debugInfo"
}
+/
/// A fixed RTL row demonstrates the editor context boundary without a renderer.
module visual_carets_example;

import std.stdio : writeln;
import sparkles.text_buffer.summary : Affinity;
import sparkles.text_buffer.text : Text;
import sparkles.ui.editor.command : Boundary, EditCommand;
import sparkles.ui.editor.context : CaretTarget, LogicalContext;
import sparkles.ui.editor.field : FieldTextPool;
import sparkles.ui.editor.kill_ring : KillRing;
import sparkles.ui.editor.selection : SelectionSet;
import sparkles.ui.editor.layout : LayoutContext;
import sparkles.ui.editor.state : EditorState;
import sparkles.ui.editor.step : stepInPlace;

/// The row is known independently: Bet at the left, Alef at the right.
struct FixedRtlRow
{
    LogicalContext logical;
    alias logical this;

    /// A real layout would resolve the current wrapped row and its caret stops here.
    CaretTarget lineBoundaryCaret(in Text text, size_t position, Affinity affinity, Boundary boundary)
        const @safe pure nothrow @nogc
    {
        assert(text == "אב");
        return boundary == Boundary.start ? CaretTarget(4, Affinity.before)
            : CaretTarget(0, Affinity.after);
    }
}

void main() @safe
{
    auto state = EditorState.create("אב");
    state.selection = SelectionSet.caret(2);
    FieldTextPool input;
    KillRing ring;
    FixedRtlRow context;
    stepInPlace(state, ring, input, EditCommand.lineBoundary(Boundary.start), context);
    writeln("Home byte: ", state.selection.primary.head);
    stepInPlace(state, ring, input, EditCommand.lineBoundary(Boundary.end), context);
    writeln("End byte: ", state.selection.primary.head);

    // The production context derives the same answers from the bidi layout.
    auto laidOut = EditorState.create("אב");
    laidOut.selection = SelectionSet.caret(2);
    LayoutContext layout;
    stepInPlace(laidOut, ring, input, EditCommand.lineBoundary(Boundary.start), layout);
    writeln("Layout Home byte: ", laidOut.selection.primary.head);
    stepInPlace(laidOut, ring, input, EditCommand.lineBoundary(Boundary.end), layout);
    writeln("Layout End byte: ", laidOut.selection.primary.head);
}
