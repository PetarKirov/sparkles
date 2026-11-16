/** The editor's presentation settings (`EAP5`): what the document pane draws. */
module settings;

import sparkles.ui.property_tree : Doc, Label, Range;
import sparkles.font.families : DocumentFont;
import session_record : SessionSettings;

/// Each part of the code-editor presentation, every one of which can be hidden.
struct PresentationSettings
{
    /// A line-number gutter beside the text.
    @Label("Line numbers") bool lineNumbers = true;
    /// The caret's line on a raised background.
    @Label("Current line") bool currentLine = true;
    /// Guides at each indentation stop of a line's leading spaces.
    @Label("Indentation guides") bool indentGuides = true;
    /// The bracket at the caret and its partner, or an unmatched one.
    @Label("Bracket matching") bool bracketMatching = true;
    /// Trailing spaces and tabs, except where the caret is typing them.
    @Label("Trailing whitespace") bool trailingWhitespace = true;
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
    @Label("Indent with tabs") bool useTabs;
    /// Columns per indentation level, 1–16.
    @Label("Indentation width") @Range(1, 16, 1) ubyte indentWidth = 4;
    /// Enter copies the line's leading blanks.
    @Label("Auto-indent") bool autoIndent = true;
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

/**
The settings pane's subject (`EAP15`): every setting the editor offers, as
one value, so the pane is generated from it through `PropertyTree` rather
than drawn by hand. `.init` is the shipped configuration.
*/
struct EditorSettings
{
    @Label("View") @Doc("What the document pane draws (EAP5).")
    PresentationSettings view;
    @Label("Editing") @Doc("Indentation and Enter (EAP7).")
    EditingSettings editing;
    @Label("Document font") @Doc("The code font, independent of the interface's (EAP16).")
    DocumentFont font;
}

/// The pane's tree is generated from the subject, with its bounds.
@("editor.settings.generatedTree")
@safe unittest
{
    import sparkles.ui.components.tree_view : TreeViewState;
    import sparkles.ui.property_tree : Edit, editProperty, EditValue, PropertyEditState, PropertyTree;
    EditorSettings settings;
    PropertyTree!EditorSettings tree;
    TreeViewState!string state;
    tree.rebuild(settings, state);
    assert(tree.data.nodes.length >= 2, "the View and Editing sections");
    PropertyEditState edits;
    assert(!editProperty(settings, Edit("editing.indentWidth", EditValue.of(40.0)), edits).ok);
    assert(editProperty(settings, Edit("view.lineNumbers", EditValue.of(false)), edits).ok);
    assert(!settings.view.lineNumbers && settings.editing.indentWidth == 4);
}

/// The settings as the session record stores them (`EAP26`).
SessionSettings toSession(const EditorSettings settings) @safe pure nothrow @nogc
{
    SessionSettings result;
    static foreach (field; __traits(allMembers, PresentationSettings))
        __traits(getMember, result, field) = __traits(getMember, settings.view, field);
    static foreach (field; __traits(allMembers, EditingSettings))
        __traits(getMember, result, field) = __traits(getMember, settings.editing, field);
    result.fontFamily = settings.font.family;
    result.fontSize = settings.font.size;
    result.ligatures = settings.font.ligatures;
    result.lineHeight = settings.font.lineHeight;
    result.letterSpacing = settings.font.letterSpacing;
    result.fontWeight = settings.font.weight;
    result.opticalSize = settings.font.opticalSize;
    return result;
}

/// The settings a session record restores; its width is already validated.
EditorSettings fromSession(const SessionSettings stored) @safe pure nothrow @nogc
{
    EditorSettings result;
    static foreach (field; __traits(allMembers, PresentationSettings))
        __traits(getMember, result.view, field) = __traits(getMember, stored, field);
    static foreach (field; __traits(allMembers, EditingSettings))
        __traits(getMember, result.editing, field) = __traits(getMember, stored, field);
    result.font = DocumentFont(stored.fontFamily, stored.fontSize, stored.ligatures, stored.lineHeight,
        stored.letterSpacing, stored.fontWeight, stored.opticalSize).clamped;
    return result;
}

/// Every setting has a stored form, and the two convert exactly.
@("editor.settings.sessionRoundTrip")
@safe pure nothrow @nogc unittest
{
    EditorSettings settings;
    settings.view.indentGuides = false;
    settings.editing.indentWidth = 8;
    settings.editing.useTabs = true;
    settings.font.family = "DejaVu Sans Mono";
    settings.font.lineHeight = 1.5;
    assert(fromSession(toSession(settings)) == settings);
    assert(fromSession(SessionSettings.init) == EditorSettings.init, "the shipped defaults agree");
}
