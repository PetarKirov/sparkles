/**
The toolkit's one editable-text component, as a model: a Regular state
advanced by a pure step, multiple cursors, a branching history, a kill
ring beside the clipboard, and Readline keys beside each platform's.

Specification: `docs/specs/ui/editor.md`.
*/
module sparkles.ui.editor;

public import sparkles.ui.editor.command;
public import sparkles.ui.editor.context;
public import sparkles.ui.editor.effect;
public import sparkles.ui.editor.field;
public import sparkles.ui.editor.keys;
public import sparkles.ui.editor.kill_ring;
public import sparkles.ui.editor.selection;
public import sparkles.ui.editor.state;
public import sparkles.ui.editor.step;
