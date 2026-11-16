/**
Line-wise editing conveniences (`EDC12`, `EDC13`): indentation, conservative
auto-indent and line comments.

The functions here plan edits; the step applies a plan as one change set
and one undo revision. Blanks are the ASCII space and tab only: no other
white space is treated as indentation.

Specification: `docs/specs/ui/editor.md` §3.
*/
module sparkles.ui.editor.line_edit;

import sparkles.base.buffer : SharedBuffer, UniqueBuffer;
import sparkles.base.text.seek : nextGraphemeBoundary;
import sparkles.text_buffer.change_set : Edit;
import sparkles.text_buffer.text : Text;
import sparkles.ui.editor.context : clusterCells;
import sparkles.ui.editor.selection : EditRange, SelectionSet;

/// How the editor indents (`EDC12`).
struct IndentOptions
{
    /// One indent level is a tab; otherwise it is spaces up to the next stop.
    bool useTabs = true;
    /// Columns per indent level and between tab stops; 0 counts as 1.
    ubyte width = 4;
    /// `insertNewline` repeats the current line's leading blanks.
    bool autoIndent;

    /// The width between stops, at least 1.
    size_t stop() const scope @safe pure nothrow @nogc => width ? width : 1;
}

///
@("editor.indent.options.stop")
@safe pure nothrow @nogc
unittest
{
    assert(IndentOptions.init.stop == 4 && IndentOptions.init.useTabs);
    assert(IndentOptions(useTabs: false, width: 0).stop == 1);
}

/**
The line-comment token of a language, by its canonical name as
`sparkles.syntax.ts.registry.canonicalLanguage` spells it, or `null` when the
language has no line comment the editor knows (`EDC13`).
*/
string lineCommentToken(scope const(char)[] language) @safe pure nothrow @nogc
{
    switch (language)
    {
    case "c", "cpp", "c-sharp", "d", "go", "gomod", "gowork", "rust", "javascript",
        "typescript", "tsx", "jsx", "java", "kotlin", "swift", "scala", "dart", "zig",
        "glsl", "hlsl", "wgsl", "qmljs", "fsharp", "koka", "typst", "jsonnet", "sdl",
        "protobuf", "groovy", "objc", "solidity", "odin", "v":
        return "//";
    case "bash", "python", "ruby", "make", "dockerfile", "yaml", "toml", "nim", "elixir",
        "starlark", "nix", "perl", "r", "julia", "cmake", "powershell", "just", "fish",
        "tcl", "awk", "gitignore", ".gitignore", "conf", "ini", "meson", "graphql", "crystal":
        return "#";
    case "ada", "haskell", "lua", "sql", "elm", "purescript", "vhdl", "agda", "idris":
        return "--";
    case "asm", "llvm", "spirv", "scheme", "racket", "clojure", "commonlisp", "lisp",
        "elisp", "fennel":
        return ";";
    case "latex", "tex", "erlang", "matlab", "prolog":
        return "%";
    case "vim":
        return "\"";
    default:
        return null;
    }
}

///
@("editor.comment.lineCommentToken")
@safe pure nothrow @nogc
unittest
{
    assert(lineCommentToken("d") == "//");
    assert(lineCommentToken("python") == "#");
    assert(lineCommentToken("haskell") == "--");
    assert(lineCommentToken("scheme") == ";");
    assert(lineCommentToken("markdown") is null, "block comments only");
    assert(lineCommentToken("text") is null);
}

/**
The leading blanks of the line holding `position`, up to `position`: what
auto-indent repeats on a new line (`EDC12`). A position inside the line's
indentation repeats only the blanks before it.
*/
Text autoIndentAt(in Text text, size_t position) @safe pure nothrow @nogc
{
    const at = position < text.length ? position : text.length;
    const start = text.lineStart(text.lineOf(at));
    size_t end = start;
    while (end < at && isBlank(text.byteAt(end)))
        ++end;
    return text.slice(start, end);
}

///
@("editor.indent.autoIndentAt")
@safe pure nothrow @nogc
unittest
{
    const text = Text("\t  a\n  b\r\n");
    assert(autoIndentAt(text, 4) == Text("\t  "));
    assert(autoIndentAt(text, 2) == Text("\t "), "only the blanks before the caret");
    assert(autoIndentAt(text, 8) == Text("  "));
    assert(autoIndentAt(text, text.length) == Text(""));
}

package:

bool isBlank(char c) @safe pure nothrow @nogc => c == ' ' || c == '\t';

/// The lines the selection touches, ascending and once each. A non-empty
/// range that ends at the start of a later line does not touch that line.
void touchedLines(in Text text, in SelectionSet selection, ref SharedBuffer!(size_t, 8) lines)
    @safe pure nothrow @nogc
{
    foreach (r; selection.ranges)
    {
        const first = text.lineOf(r.start);
        size_t last = text.lineOf(r.end);
        if (last > first && r.end == text.lineStart(last))
            --last;
        foreach (line; first .. last + 1)
            if (lines.length == 0 || lines[][$ - 1] < line)
                lines.put(line);
    }
}

/// Whether any range covers more than one line, as `touchedLines` counts.
bool spansLines(in Text text, in SelectionSet selection) @safe pure nothrow @nogc
{
    foreach (r; selection.ranges)
    {
        const first = text.lineOf(r.start);
        const last = text.lineOf(r.end);
        if (last > first + 1 || (last == first + 1 && r.end != text.lineStart(last)))
            return true;
    }
    return false;
}

/// The end of `line`'s leading blanks.
size_t leadingEnd(in Text text, size_t line) @safe pure nothrow @nogc
{
    size_t p = text.lineStart(line);
    const end = text.lineEnd(line);
    while (p < end && isBlank(text.byteAt(p)))
        ++p;
    return p;
}

/// The column of `to` on a line starting at `from`: a tab advances to the
/// next stop, a grapheme by its cells.
size_t columnOf(in Text text, size_t from, size_t to, size_t stop) @safe pure nothrow @nogc
{
    size_t column;
    for (size_t at = from; at < to;)
    {
        if (text.byteAt(at) == '\t')
        {
            column = (column / stop + 1) * stop;
            ++at;
            continue;
        }
        const next = nextGraphemeBoundary(text, at);
        column += clusterCells(text, at, next);
        at = next;
    }
    return column;
}

/// One indent level for text at `column`: a tab, or spaces to the next stop.
Text indentAt(size_t column, in IndentOptions options) @safe pure nothrow @nogc
{
    if (options.useTabs)
        return Text("\t");
    static immutable char[255] spaces = ' ';
    const stop = options.stop;
    return Text(spaces[0 .. stop - column % stop]);
}

/// Indent every non-empty line in `lines` by one level at its start.
void planIndent(in Text text, scope const(size_t)[] lines, in IndentOptions options,
    ref UniqueBuffer!(Edit, 4) edits) @safe pure nothrow @nogc
{
    foreach (line; lines)
    {
        const start = text.lineStart(line);
        if (start != text.lineEnd(line))
            edits.put(Edit(start, start, indentAt(0, options)));
    }
}

/// Remove up to one indent level from the start of every line in `lines`: a
/// leading tab, or the spaces back to the previous stop.
void planOutdent(in Text text, scope const(size_t)[] lines, in IndentOptions options,
    ref UniqueBuffer!(Edit, 4) edits) @safe pure nothrow @nogc
{
    foreach (line; lines)
    {
        const start = text.lineStart(line);
        const end = text.lineEnd(line);
        if (start == end)
            continue;
        if (text.byteAt(start) == '\t')
        {
            edits.put(Edit(start, start + 1, Text.init));
            continue;
        }
        size_t spaces;
        while (start + spaces < end && text.byteAt(start + spaces) == ' ')
            ++spaces;
        if (spaces == 0)
            continue;
        const stop = options.stop;
        const remove = spaces % stop ? spaces % stop : stop;
        edits.put(Edit(start, start + (remove < spaces ? remove : spaces), Text.init));
    }
}

/**
Toggle `token` on the non-blank lines in `lines`: when every one starts
(after its blanks) with the token, remove it and one space after it;
otherwise insert the token and a space at the smallest indentation column
among them. Blank lines are left alone.
*/
void planToggleComment(in Text text, scope const(size_t)[] lines, scope const(char)[] token,
    in IndentOptions options, ref UniqueBuffer!(Edit, 4) edits) @safe pure nothrow @nogc
{
    const stop = options.stop;
    bool allCommented = true;
    bool any;
    size_t minColumn = size_t.max;
    foreach (line; lines)
    {
        const lead = leadingEnd(text, line);
        if (lead == text.lineEnd(line))
            continue;
        any = true;
        allCommented = allCommented && startsWith(text, lead, text.lineEnd(line), token);
        const column = columnOf(text, text.lineStart(line), lead, stop);
        if (column < minColumn)
            minColumn = column;
    }
    if (!any)
        return;
    SharedBuffer!(char, 16) marker;
    marker.put(token);
    marker.put(' ');
    auto inserted = Text(marker[]);
    foreach (line; lines)
    {
        const start = text.lineStart(line);
        const end = text.lineEnd(line);
        const lead = leadingEnd(text, line);
        if (lead == end)
            continue;
        if (allCommented)
        {
            size_t to = lead + token.length;
            if (to < end && text.byteAt(to) == ' ')
                ++to;
            edits.put(Edit(lead, to, Text.init));
            continue;
        }
        // The first position whose column reaches the smallest indentation.
        size_t at = start;
        size_t column;
        while (at < lead && column < minColumn)
        {
            column = text.byteAt(at) == '\t' ? (column / stop + 1) * stop : column + 1;
            ++at;
        }
        edits.put(Edit(at, at, inserted));
    }
}

bool startsWith(in Text text, size_t at, size_t end, scope const(char)[] token)
    @safe pure nothrow @nogc
{
    if (token.length == 0 || end - at < token.length)
        return false;
    foreach (i, c; token)
        if (text.byteAt(at + i) != c)
            return false;
    return true;
}
