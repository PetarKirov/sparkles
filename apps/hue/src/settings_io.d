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

Also home to the `hue config` renderers: `renderConfigShow` (`CFG10`, every
effective setting with the origin that supplied it, `git config
--show-origin` style) and `renderStarterConfig` (`CFG13`, the commented
starting file whose descriptions and defaults come from the same schema
reflection — so the file a user starts from and the state hue reports cannot
disagree).

NOTE: no module-level `@safe:` — the wired decode this module fronts infers
`@system` for aggregates.
*/
module settings_io;

import std.traits : FieldNameTuple, getUDAs, hasUDA;

import expected : Expected, err;

import sparkles.wired.json : JsonError, JsonStage, fromJSON;

import sparkles.ui.property_tree : Doc;

import settings : ConfigSection, HueConfig;
import settings_load : LoadedConfig;
import settings_overlay : Origin, OriginKind, Origins;

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

// ─────────────────────────────────────────────────────────────────────────────
// `hue config show` — the layering made observable (CFG10).
// ─────────────────────────────────────────────────────────────────────────────

/// One rendered line's origin column, `git config --show-origin` style.
/// (By value — returning the detail out of a scoped `in` view is a dip1000
/// error, and an `Origin` is two words.)
private string originText(Origin o) @safe pure nothrow
    => o.kind == OriginKind.default_ ? "default"
        : o.detail.length ? o.detail : "cli";

/// A leaf value in the listing's spelling: scalars and enum member names
/// verbatim, arrays as `[a, b]` — the spec's example format.
private string showValueText(V)(in V v)
{
    import std.conv : text;

    static if (is(V == string))
        return v.length ? v : "";
    else static if (is(V : const(string)[]))
    {
        string s = "[";
        foreach (i, e; v)
        {
            if (i)
                s ~= ", ";
            s ~= e;
        }
        return s ~ "]";
    }
    else static if (is(V == E[], E))
    {
        import std.conv : to;

        return v.to!string;
    }
    else
        return text(v);
}

/**
Writes every effective setting — defaults included, so the output is a
complete picture — prefixed with the origin that supplied it. `changedOnly`
filters to non-default origins. Renders from the same resolved value as the
starter file and the save path, which is what keeps the three consistent.
*/
void renderConfigShow(Writer)(ref Writer w, in LoadedConfig lc,
    bool changedOnly = false)
{
    foreach (warning; lc.warnings)
    {
        w ~= warning;
        w ~= '\n';
    }
    renderShowSection(w, lc.effective, lc.origins, null, changedOnly);
}

private void renderShowSection(Writer, T, O)(ref Writer w, in T value,
    in O origins, string prefix, bool changedOnly)
{
    static foreach (i, name; FieldNameTuple!T)
    {
        static if (hasUDA!(typeof(T.tupleof[i]), ConfigSection))
            renderShowSection(w, value.tupleof[i], origins.tupleof[i],
                prefix ~ name ~ ".", changedOnly);
        else
        {{
            const o = origins.tupleof[i];
            if (!changedOnly || o.kind != OriginKind.default_)
            {
                const org = originText(o);
                w ~= org;
                // One aligned column; long origins get a plain separator.
                foreach (_; org.length .. 44)
                    w ~= ' ';
                if (org.length >= 44)
                    w ~= "  ";
                w ~= prefix;
                w ~= name;
                w ~= '=';
                w ~= showValueText(value.tupleof[i]);
                w ~= '\n';
            }
        }}
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// `hue config write` — the commented starting file (CFG13).
// ─────────────────────────────────────────────────────────────────────────────

/**
Emits the JSONC starter: every setting as a commented-out assignment carrying
its `@Doc` description and its compiled default — drawn from the schema's
field initialisers and UDAs, the same reflection everything else reads. The
file decodes as the empty overlay until the user uncomments something.
*/
void renderStarterConfig(Writer)(ref Writer w)
{
    w ~= "{\n";
    w ~= "  // hue configuration — generated by `hue config write`.\n";
    w ~= "  // Every setting is optional: an absent setting inherits from the\n";
    w ~= "  // layer below (compiled defaults, unless a project .hue.json or a\n";
    w ~= "  // flag speaks). Comments and trailing commas are accepted.\n";
    renderStarterSection(w, HueConfig.init, 1);
    w ~= "}\n";
}

private void renderStarterSection(Writer, T)(ref Writer w, in T value, int depth)
{
    import sparkles.wired.json : toJSON;

    void indent()
    {
        foreach (_; 0 .. depth * 2)
            w ~= ' ';
    }

    static foreach (i, name; FieldNameTuple!T)
    {
        static if (hasUDA!(typeof(T.tupleof[i]), ConfigSection))
        {
            static if (FieldNameTuple!(typeof(T.tupleof[i])).length)
            {
                indent();
                w ~= '"';
                w ~= name;
                w ~= "\": {\n";
                renderStarterSection(w, value.tupleof[i], depth + 1);
                indent();
                w ~= "},\n";
            }
        }
        else
        {{
            static if (hasUDA!(T.tupleof[i], Doc))
            {
                indent();
                w ~= "// ";
                w ~= getUDAs!(T.tupleof[i], Doc)[0].text;
                w ~= '\n';
            }
            indent();
            w ~= "// \"";
            w ~= name;
            w ~= "\": ";
            auto dflt = toJSON(value.tupleof[i]);
            assert(!dflt.hasError, "a schema default failed to encode");
            w ~= dflt.value[];
            w ~= ",\n";
        }}
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Renderer tests.
// ─────────────────────────────────────────────────────────────────────────────

@("settings_io.renderConfigShow.originsAndFilter")
@system unittest
{
    import std.algorithm.searching : canFind;
    import std.array : appender;
    import std.string : splitLines;

    import settings_load : LoadedConfig;
    import settings_overlay : applyOverlay, Sparse;

    LoadedConfig lc;
    Sparse!HueConfig user;
    user.appearance.theme = "builtin-dark";
    user.panes.viewer.tabWidth = 8;
    applyOverlay(lc.effective, lc.origins, user,
        Origin(OriginKind.userFile, "file:/home/u/.config/hue/config.json"));
    lc.warnings ~= "config: something was ignored";

    auto full = appender!string;
    renderConfigShow(full, lc);
    const lines = full[].splitLines;

    // Warnings first, then every leaf — defaults included.
    assert(lines[0] == "config: something was ignored");
    assert(full[].canFind(
        "file:/home/u/.config/hue/config.json        appearance.theme=builtin-dark"),
        full[]);
    assert(full[].canFind("default"), full[]);
    assert(full[].canFind("panes.viewer.tabWidth=8"));
    assert(full[].canFind("appearance.fonts.size=18"));
    assert(full[].canFind("behaviour.tableCopy=detect"));

    // --changed keeps exactly the non-default origins.
    auto changed = appender!string;
    renderConfigShow(changed, lc, changedOnly: true);
    const clines = changed[].splitLines;
    assert(clines.length == 3, changed[]); // warning + two set fields
    assert(!changed[].canFind("fonts.size"));
}

@("settings_io.renderStarterConfig.decodesEmptyAndDocumented")
@system unittest
{
    import std.algorithm.searching : canFind;
    import std.array : appender;

    import settings_overlay : Sparse;

    auto w = appender!string;
    renderStarterConfig(w);
    auto text = w[].dup;

    // The starter is documentation until uncommented: stripped, it decodes
    // to the empty overlay.
    stripJsonc(text);
    auto r = fromJSON!(Sparse!HueConfig)(text);
    assert(!r.hasError, r.error.toString);
    assert(r.value == Sparse!HueConfig.init);

    // Descriptions and defaults come from the schema.
    assert(w[].canFind(`// Colour theme, by name`));
    assert(w[].canFind(`// "theme": "tokyo-night",`));
    assert(w[].canFind(`"appearance": {`));
    assert(w[].canFind(`// "tabWidth": 4,`));
    assert(w[].canFind(`// "delayMs": 200,`));
}
