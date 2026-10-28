/**
The soft keyboard follows editor focus (`EDI9`).

A touch host asks once per frame whether any editor has the keyboard, and
this turns the answer into the edges the platform needs: show the keyboard
as an editor gains focus, hide it as the last one loses it. Asking every
frame instead would re-raise a keyboard the user dismissed by hand.

Specification: `docs/specs/ui/editor.md` §6.
*/
module sparkles.ui.editor.soft_keyboard;

/// What a host does with the soft keyboard this frame.
enum KeyboardAsk : ubyte
{
    /// Nothing changed.
    none,
    /// An editor gained focus: show the keyboard.
    show,
    /// No editor has focus any more: hide the keyboard.
    hide,
}

/// The edges of editor focus, one frame at a time.
struct SoftKeyboard
{
    private bool focused;

@safe pure nothrow @nogc:

    /// Whether an editor had focus as of the last `update`.
    bool editing() const => focused;

    /// Report whether an editor has focus now; returns what to do.
    KeyboardAsk update(bool editorFocused)
    {
        if (editorFocused == focused)
            return KeyboardAsk.none;
        focused = editorFocused;
        return editorFocused ? KeyboardAsk.show : KeyboardAsk.hide;
    }
}

///
@("editor.softKeyboard.followsFocusEdges")
@safe pure nothrow @nogc
unittest
{
    SoftKeyboard keyboard;
    assert(keyboard.update(false) == KeyboardAsk.none, "nothing to hide at start");
    assert(keyboard.update(true) == KeyboardAsk.show);
    assert(keyboard.update(true) == KeyboardAsk.none,
        "a keyboard the user dismissed is not raised again every frame");
    assert(keyboard.update(false) == KeyboardAsk.hide);
    assert(!keyboard.editing);
}
