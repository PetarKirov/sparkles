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

/// How the document indents (`EAP7`): applied to every tab's editor.
struct EditingSettings
{
    /// Indent with tab characters rather than spaces.
    bool useTabs;
    /// Columns per indentation level, 1–16.
    ubyte indentWidth = 4;
    /// Enter copies the line's leading blanks.
    bool autoIndent = true;
}

/// One indentation choice, as a command argument.
enum IndentChoice : ubyte { spaces, tabs, width2, width4, width8, autoIndent }

/// The palette label of a choice.
string label(IndentChoice choice) @safe pure nothrow @nogc
{
    final switch (choice)
    {
        case IndentChoice.spaces: return "Indent with spaces";
        case IndentChoice.tabs: return "Indent with tabs";
        case IndentChoice.width2: return "Indentation width: 2";
        case IndentChoice.width4: return "Indentation width: 4";
        case IndentChoice.width8: return "Indentation width: 8";
        case IndentChoice.autoIndent: return "Toggle auto-indent";
    }
}

/// Apply one choice.
void choose(ref EditingSettings settings, IndentChoice choice) @safe pure nothrow @nogc
{
    final switch (choice)
    {
        case IndentChoice.spaces: settings.useTabs = false; break;
        case IndentChoice.tabs: settings.useTabs = true; break;
        case IndentChoice.width2: settings.indentWidth = 2; break;
        case IndentChoice.width4: settings.indentWidth = 4; break;
        case IndentChoice.width8: settings.indentWidth = 8; break;
        case IndentChoice.autoIndent: settings.autoIndent = !settings.autoIndent; break;
    }
}

/// Choices set exactly their own setting.
@("editor.settings.indentChoices")
@safe pure nothrow @nogc unittest
{
    EditingSettings settings;
    settings.choose(IndentChoice.tabs);
    settings.choose(IndentChoice.width2);
    assert(settings.useTabs && settings.indentWidth == 2 && settings.autoIndent);
    settings.choose(IndentChoice.autoIndent);
    settings.choose(IndentChoice.spaces);
    assert(!settings.useTabs && !settings.autoIndent && settings.indentWidth == 2);
}
