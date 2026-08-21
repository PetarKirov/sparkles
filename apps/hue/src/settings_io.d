/**
Config-file I/O: the JSONC read path (`CFG13`'s consequence — a starter file
carries comments a user keeps, so hue must read them back).

wired's `JsonReadOptions` declares `allowComments`/`allowTrailingCommas` but
its parser still rejects them at compile time ("not implemented yet",
SPEC §11.3), so the concession happens here instead: `stripJsonc` overwrites
comment bytes and trailing commas with spaces $(B in place), preserving every
byte offset — a located error in the stripped text names the same line and
column as the file the user is looking at. The parse itself stays strict
RFC 8259.

`hue config show/write/save` rendering joins this module in a later commit.

NOTE: no module-level `@safe:` — the wired decode this module fronts infers
`@system` for aggregates.
*/
module settings_io;

import expected : Expected, err;

import sparkles.wired.json : JsonError, JsonStage, fromJSON;

// ─────────────────────────────────────────────────────────────────────────────
// JSONC → strict JSON, offsets preserved.
// ─────────────────────────────────────────────────────────────────────────────

/**
Blanks `//` and `/* *``/` comments and trailing commas with spaces, in place.
Newlines inside a block comment survive, so line/column positions of
everything after it are untouched. String literals are honored (a `//` inside
a string is content, not a comment); an unterminated construct is left for
the strict parser to report at its true offset.
*/
void stripJsonc(scope char[] text) @safe pure nothrow @nogc
{
    // Pass 1: comments.
    bool inString, escaped;
    size_t i;
    while (i < text.length)
    {
        const c = text[i];
        if (inString)
        {
            if (escaped)
                escaped = false;
            else if (c == '\\')
                escaped = true;
            else if (c == '"')
                inString = false;
            i++;
            continue;
        }
        if (c == '"')
        {
            inString = true;
            i++;
            continue;
        }
        if (c == '/' && i + 1 < text.length && text[i + 1] == '/')
        {
            while (i < text.length && text[i] != '\n')
                text[i++] = ' ';
            continue;
        }
        if (c == '/' && i + 1 < text.length && text[i + 1] == '*')
        {
            text[i] = ' ';
            text[i + 1] = ' ';
            i += 2;
            while (i < text.length)
            {
                if (text[i] == '*' && i + 1 < text.length && text[i + 1] == '/')
                {
                    text[i] = ' ';
                    text[i + 1] = ' ';
                    i += 2;
                    break;
                }
                if (text[i] != '\n')
                    text[i] = ' ';
                i++;
            }
            continue;
        }
        i++;
    }

    // Pass 2 (comment-free now): a comma whose next non-whitespace byte
    // closes a container is trailing — blank it.
    inString = escaped = false;
    foreach (j, c; text)
    {
        if (inString)
        {
            if (escaped)
                escaped = false;
            else if (c == '\\')
                escaped = true;
            else if (c == '"')
                inString = false;
            continue;
        }
        if (c == '"')
        {
            inString = true;
            continue;
        }
        if (c != ',')
            continue;
        size_t k = j + 1;
        while (k < text.length && (text[k] == ' ' || text[k] == '\t'
                || text[k] == '\n' || text[k] == '\r'))
            k++;
        if (k < text.length && (text[k] == '}' || text[k] == ']'))
            text[j] = ' ';
    }
}

/**
Reads `path` as JSONC (comments and trailing commas tolerated), decodes into
a `T`. Same non-throwing contract and error shape as wired's `readJSONFile`:
I/O failures are `fileRead`-stage errors, parse/decode failures keep their
stage, position and `$`-path, and every error records the file.
*/
Expected!(T, JsonError) readJsoncFile(T)(string path)
{
    import std.file : readText;

    char[] text;
    try
        text = readText!(char[])(path);
    catch (Exception e)
    {
        JsonError fe;
        fe.stage = JsonStage.fileRead;
        fe.filePath ~= path;
        fe.reason = e.msg;
        return err!T(fe);
    }

    stripJsonc(text);

    auto r = fromJSON!T(text);
    if (r.hasError)
    {
        auto fe = r.error;
        fe.filePath ~= path;
        return err!T(fe);
    }
    return r;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

@("settings_io.stripJsonc.preservesOffsets")
@safe pure unittest
{
    char[] t = ("{\n" ~
        "  // a line comment\n" ~
        "  \"a\": \"url://not-a-comment\", /* block\n" ~
        "     spanning */ \"b\": 2,\n" ~
        "}\n").dup;
    const before = t.length;
    stripJsonc(t);
    assert(t.length == before);

    // Newlines survive, so anything after a comment keeps its line/column.
    import std.algorithm.searching : canFind;
    import std.algorithm.iteration : filter;
    import std.range : walkLength;
    assert(t.filter!(c => c == '\n').walkLength == 5);
    // The `//` inside a string literal is content and stays; the comments
    // and the trailing comma are gone.
    assert(t.canFind(`"url://not-a-comment"`));
    assert(!t.canFind("line comment"));
    assert(!t.canFind("block"));
    assert(!t.canFind(",\n}"));
}

@("settings_io.readJsoncFile.roundTrip")
@system unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;

    import settings : HueConfig;
    import settings_overlay : Sparse;

    const dir = buildPath(tempDir, "hue-settings-io-test");
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);

    const path = buildPath(dir, "config.json");
    write(path, "{\n" ~
        "  // the theme hue starts with\n" ~
        "  \"appearance\": { \"theme\": \"builtin-dark\", },\n" ~
        "}\n");

    auto r = readJsoncFile!(Sparse!HueConfig)(path);
    assert(!r.hasError, r.error.toString);
    assert(r.value.appearance.theme.get == "builtin-dark");
    assert(r.value.panes.viewer.tabWidth.isNull);

    // A malformed value is a located decode error: the `$`-path names the
    // setting, the file is recorded (decode errors are path-addressed;
    // line/column belong to parse-stage errors).
    write(path, "{\n" ~
        "  // comment\n" ~
        "  \"panes\": { \"viewer\": { \"tabWidth\": \"eight\" } }\n" ~
        "}\n");
    auto bad = readJsoncFile!(Sparse!HueConfig)(path);
    assert(bad.hasError);
    import std.algorithm.searching : canFind;
    assert(bad.error.path[].canFind("tabWidth"), bad.error.toString);
    assert(bad.error.filePath[] == path);

    // A syntax error (after stripping) keeps its true line in the file the
    // user is looking at — the strip preserved every offset.
    write(path, "{\n" ~
        "  /* two\n" ~
        "     lines */\n" ~
        "  \"panes\": nope\n" ~
        "}\n");
    auto syn = readJsoncFile!(Sparse!HueConfig)(path);
    assert(syn.hasError);
    assert(syn.error.line == 4, syn.error.toString);
}
