#!/usr/bin/env dub
/+ dub.sdl:
name "editor-insert-each"
targetPath "build"
dependency "sparkles:ui" path="../../.."
buildType "checked" {
    buildOptions "optimize" "inline" "debugInfo"
}
+/
/// Position-aware insertion shares one editor transaction across several carets.
module insert_each_example;

import std.stdio : writeln;
import sparkles.text_buffer.text : Text;
import sparkles.ui.editor.command : EditCommand, EditKind;
import sparkles.ui.editor.field : EditorField;
import sparkles.ui.editor.selection : EditRange, SelectionSet;

void main() @safe
{
    auto field = EditorField.make("abc");
    EditRange[2] carets = [EditRange.caret(1), EditRange.caret(3)];
    field.state.selection = SelectionSet.of(carets[], 0);
    field.insertEach((in Text text, size_t position) @safe pure nothrow @nogc
        => position == 1 ? "A" : "B");
    writeln(field.text);
    field.run(EditCommand.of(EditKind.undo));
    writeln(field.text);
}
