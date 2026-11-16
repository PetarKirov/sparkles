/**
The editor's find and replace bar (`EAP5`, `EAP7`): two single-line shared
editor fields, the query's switches and the matches of the active document,
recomputed only when the text, the pattern or a switch changes. The
matching, replacement and its undo belong to `sparkles.ui.editor.search`.
*/
module find_bar;

import core.time : MonoTime;
import sparkles.text_buffer.text : Text;
import sparkles.ui.editor.field : EditorField;
import sparkles.ui.editor.keys : EditorTarget;
import sparkles.ui.editor.search : findMatches, MatchRange, SearchBudget, SearchPattern, SearchQuery, SearchResult;
import commands : FindOption;

/// The bar's state; one bar serves whichever document is active.
struct FindBar
{
    /// The bar is shown and holds the keyboard.
    bool open;
    /// The replacement field is shown.
    bool replacing;
    /// The keyboard is in the replacement field rather than the query.
    bool onReplacement;
    /// The query's switches; its `pattern` is the query field's text.
    SearchQuery options;
    /// The fields.
    EditorField query, replacement;
    /// Changes whenever the bar opens, so a clipboard reply for an earlier
    /// bar is not pasted into this one.
    ulong epoch;

    private Text searched;
    private ulong searchedDocument;
    private SearchQuery searchedQuery;
    private bool fresh;
    private SearchPattern pattern_;
    private SearchResult result_;

    /// Show the bar, seeding the query with `seed` when it is given.
    void show(bool replace, scope const(char)[] seed, EditorTarget target) @safe
    {
        import sparkles.ui.editor.command : EditCommand, EditKind;
        if (!open || seed.length)
        {
            query = EditorField.singleLine(seed.length ? seed.idup : query.text, target);
            query.run(EditCommand.of(EditKind.selectAll), MonoTime.currTime);
        }
        if (replace && !replacing) replacement = EditorField.singleLine(replacement.text, target);
        replacing |= replace;
        onReplacement = false;
        open = true;
        ++epoch;
    }

    /// Hide the bar; its fields and switches are kept for the next one.
    void close() @safe pure nothrow @nogc { open = false; onReplacement = false; }

    /// The field holding the keyboard.
    ref EditorField focused() return @safe pure nothrow @nogc
        => onReplacement && replacing ? replacement : query;

    /// Flip one switch.
    void toggle(FindOption option) @safe pure nothrow @nogc
    {
        final switch (option)
        {
            case FindOption.regex: options.regex = !options.regex; break;
            case FindOption.caseSensitive: options.caseSensitive = !options.caseSensitive; break;
            case FindOption.wholeWord: options.wholeWord = !options.wholeWord; break;
        }
    }

    /// The compiled query of the last `refresh`.
    ref const(SearchPattern) pattern() const return @safe pure nothrow @nogc => pattern_;
    /// The matches of the last `refresh`.
    ref const(SearchResult) result() const return @safe pure nothrow @nogc => result_;

    /**
    Recompute the matches of `text` (document `document`) when the text, the
    query or a switch changed since the last call. Work is bounded by
    `budget`: a larger document reports its first matches as truncated.
    */
    void refresh(in Text text, ulong document, in SearchBudget budget = SearchBudget.init) @safe
    {
        SearchQuery wanted = options;
        wanted.pattern = query.text;
        if (fresh && document == searchedDocument && wanted == searchedQuery && searched == text) return;
        fresh = true;
        searched = Text(text);
        searchedDocument = document;
        searchedQuery = wanted;
        pattern_ = SearchPattern.compile(wanted);
        result_ = pattern_.valid && wanted.pattern.length ? findMatches(text, pattern_, 0, budget) : SearchResult.init;
    }

    /// The ordinal of the match at or after `position`, 1-based; 0 without matches.
    size_t ordinalAt(size_t position) const @safe pure nothrow @nogc
    {
        foreach (i, m; result_.matches)
            if (m.start >= position) return i + 1;
        return result_.matches.length ? 1 : 0;
    }

    /// The bar's one-line summary: `3 of 12`, `No results`, or the pattern error.
    string summary(size_t selectionStart, size_t selectionEnd) const @safe pure
    {
        import std.conv : text;
        if (!query.text.length) return "";
        if (pattern_.error.length) return pattern_.error;
        if (!result_.matches.length) return result_.truncated ? "No results yet" : "No results";
        size_t current;
        foreach (i, m; result_.matches)
            if (m.start == selectionStart && m.end == selectionEnd) current = i + 1;
        const total = text(result_.matches.length, result_.truncated ? "+" : "");
        return current ? text(current, " of ", total) : text(total, result_.matches.length == 1 ? " match" : " matches");
    }
}

/// The matches follow the query, the switches and the text, and say so in the summary.
@("editor.findBar.refresh")
@safe unittest
{
    FindBar bar;
    bar.show(false, "ab", EditorTarget.window);
    auto text = Text("ab Ab ab");
    bar.refresh(text, 1);
    assert(bar.result.matches.length == 3, "case-insensitive by default");
    assert(bar.summary(0, 2) == "1 of 3" && bar.summary(1, 1) == "3 matches");
    bar.toggle(FindOption.caseSensitive);
    bar.refresh(text, 1);
    assert(bar.result.matches.length == 2);
    bar.toggle(FindOption.regex);
    bar.query.setText("a(");
    bar.refresh(text, 1);
    assert(!bar.pattern.valid && bar.summary(0, 0).length && !bar.result.matches.length);
    bar.query.setText("x");
    bar.refresh(text, 1);
    assert(bar.summary(0, 0) == "No results");
}
