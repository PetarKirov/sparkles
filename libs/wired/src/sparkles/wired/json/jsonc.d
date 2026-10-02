/**
JSONC on read: comments and trailing commas in a hand-edited configuration
file, tolerated without loosening the parser.

`JsonReadOptions` declares `allowComments`/`allowTrailingCommas`, but the
parser still rejects them (SPEC §11.3), so the concession happens before it:
$(LREF stripJsonc) overwrites comment bytes and trailing commas with spaces
$(B in place), preserving every byte offset. A located error in the stripped
text therefore names the same line and column as the file the user is looking
at, and the parse itself stays strict RFC 8259.

Applications that keep a user-editable settings file (hue, the terminal) read
it through $(LREF readJsoncFile) and write it back as strict JSON.
*/
module sparkles.wired.json.jsonc;

import expected : Expected, err;

import sparkles.wired.json.codec : fromJSON;
import sparkles.wired.json.error : JsonError, JsonStage;

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

///
@("wired.json.jsonc.stripJsonc.preservesOffsets")
@safe pure unittest
{
    import std.algorithm.iteration : filter;
    import std.algorithm.searching : canFind;
    import std.range : walkLength;

    char[] t = ("{\n" ~
        "  // a line comment\n" ~
        "  \"a\": \"url://not-a-comment\", /* block\n" ~
        "     spanning */ \"b\": 2,\n" ~
        "}\n").dup;
    const before = t.length;
    stripJsonc(t);
    assert(t.length == before);

    // Newlines survive, so anything after a comment keeps its line/column.
    assert(t.filter!(c => c == '\n').walkLength == 5);
    // The `//` inside a string literal is content and stays; the comments
    // and the trailing comma are gone.
    assert(t.canFind(`"url://not-a-comment"`));
    assert(!t.canFind("line comment"));
    assert(!t.canFind("block"));
    assert(!t.canFind(",\n}"));
}

/**
Reads `path` as JSONC (comments and trailing commas tolerated), decodes into
a `T`. Same non-throwing contract and error shape as `readJSONFile`: I/O
failures are `fileRead`-stage errors, parse/decode failures keep their stage,
position and `$`-path, and every error records the file.
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

///
@("wired.json.jsonc.readJsoncFile.locatedErrors")
@system unittest
{
    import std.algorithm.searching : canFind;
    import std.file : write;

    import sparkles.test_utils.tmpfs : TmpFS;

    static struct Viewer
    {
        int tabWidth = 4;
    }

    static struct Cfg
    {
        string theme;
        Viewer viewer;
    }

    auto fixture = TmpFS.create();
    const path = fixture.writeFileAt("config.json", "{\n" ~
        "  // the theme to start with\n" ~
        "  \"theme\": \"builtin-dark\",\n" ~
        "  \"viewer\": { \"tabWidth\": 2, },\n" ~
        "}\n");

    auto r = readJsoncFile!Cfg(path);
    assert(!r.hasError, r.error.toString);
    assert(r.value.theme == "builtin-dark");

    // A malformed value is a located decode error: the `$`-path names the
    // setting and the file is recorded.
    write(path, "{\n  // comment\n  \"viewer\": { \"tabWidth\": \"eight\" }\n}\n");
    auto bad = readJsoncFile!Cfg(path);
    assert(bad.hasError);
    assert(bad.error.path[].canFind("tabWidth"), bad.error.toString);
    assert(bad.error.filePath[] == path);

    // A syntax error after stripping keeps its true line in the file.
    write(path, "{\n  /* two\n     lines */\n  \"viewer\": nope\n}\n");
    auto syn = readJsoncFile!Cfg(path);
    assert(syn.hasError);
    assert(syn.error.line == 4, syn.error.toString);

    // An unreadable file is a read-stage error, not an exception.
    auto missing = readJsoncFile!Cfg(path ~ ".absent");
    assert(missing.hasError && missing.error.stage == JsonStage.fileRead);
}
