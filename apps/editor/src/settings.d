/** The editor's presentation settings (`EAP5`): what the document pane draws. */
module settings;

/// Each part of the code-editor presentation, every one of which can be hidden.
struct PresentationSettings
{
    /// A line-number gutter beside the text.
    bool lineNumbers = true;
    /// The caret's line on a raised background.
    bool currentLine = true;
    /// Guides at each indentation stop of a line's leading spaces.
    bool indentGuides = true;
    /// The bracket at the caret and its partner, or an unmatched one.
    bool bracketMatching = true;
    /// Trailing spaces and tabs, except where the caret is typing them.
    bool trailingWhitespace = true;
}

/// One presentation switch, as a command argument.
enum PresentationToggle : ubyte { lineNumbers, currentLine, indentGuides, bracketMatching, trailingWhitespace }

/// The palette label of a switch.
string label(PresentationToggle toggle) @safe pure nothrow @nogc
{
    final switch (toggle)
    {
        case PresentationToggle.lineNumbers: return "Toggle line numbers";
        case PresentationToggle.currentLine: return "Toggle current-line highlight";
        case PresentationToggle.indentGuides: return "Toggle indentation guides";
        case PresentationToggle.bracketMatching: return "Toggle bracket matching";
        case PresentationToggle.trailingWhitespace: return "Toggle trailing-whitespace marks";
    }
}

/// Flip one switch.
void toggle(ref PresentationSettings settings, PresentationToggle which) @safe pure nothrow @nogc
{
    final switch (which)
    {
        case PresentationToggle.lineNumbers: settings.lineNumbers = !settings.lineNumbers; break;
        case PresentationToggle.currentLine: settings.currentLine = !settings.currentLine; break;
        case PresentationToggle.indentGuides: settings.indentGuides = !settings.indentGuides; break;
        case PresentationToggle.bracketMatching: settings.bracketMatching = !settings.bracketMatching; break;
        case PresentationToggle.trailingWhitespace: settings.trailingWhitespace = !settings.trailingWhitespace; break;
    }
}

/// Every switch flips exactly its own part.
@("editor.settings.toggle")
@safe pure nothrow @nogc unittest
{
    PresentationSettings settings;
    settings.toggle(PresentationToggle.indentGuides);
    assert(!settings.indentGuides && settings.lineNumbers && settings.bracketMatching);
    settings.toggle(PresentationToggle.indentGuides);
    assert(settings == PresentationSettings.init);
}
