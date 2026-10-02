/**
The user-facing side of a layered configuration file: listing every effective
setting with the layer that supplied it, the commented starting file, and the
sparse write-back.

All three render from the same schema reflection the layers decode through
(`sparkles.wired.overlay`), so the file a user starts from, the state an
application reports and what it saves cannot disagree. What a layer $(I is) —
its origin type, its spelling, where its files live — stays the application's:
the renderers take the origin's spelling and the description UDA as template
arguments.

NOTE: no module-level `@safe:` — the encode/decode walks infer `@system` for
aggregates.
*/
module sparkles.wired.config_file;

import std.array : appender;
import std.traits : FieldNameTuple, getUDAs, hasUDA;

import expected : Expected, err, ok;

import sparkles.wired.json : fromJSON, JsonError, JsonKind, JsonStage, JsonValue;
import sparkles.wired.overlay : mergeSparse, Sparse, WireSection;

// ─────────────────────────────────────────────────────────────────────────────
// `config show` — the layering made observable.
// ─────────────────────────────────────────────────────────────────────────────

/// A leaf value in the listing's spelling: scalars and enum member names
/// verbatim, string arrays as `[a, b]`, maps by their size.
string showValueText(V)(in V v)
{
    import std.conv : text;
    import std.traits : isAssociativeArray;

    static if (isAssociativeArray!V)
        return v.length ? text(v.length, " entries") : "{}";
    else static if (is(V == string))
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
Writes one line per leaf of `value` — defaults included, so the output is a
complete picture — prefixed with `originText(origin)` in one aligned column,
`git config --show-origin` style. `isDefault(origin)` says whether a leaf
still holds the schema's initialiser; `changedOnly` keeps only the others.
*/
void renderConfigShow(alias originText, alias isDefault, Writer, T, O)(
    ref Writer w, in T value, in O origins, bool changedOnly = false,
    string prefix = null)
{
    static foreach (i, name; FieldNameTuple!T)
    {
        static if (hasUDA!(typeof(T.tupleof[i]), WireSection))
            renderConfigShow!(originText, isDefault)(w, value.tupleof[i],
                origins.tupleof[i], changedOnly, prefix ~ name ~ ".");
        else
        {{
            const o = origins.tupleof[i];
            if (!changedOnly || !isDefault(o))
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
// `config write` — the commented starting file.
// ─────────────────────────────────────────────────────────────────────────────

/**
Emits the body of a JSONC starter: every setting of `value` as a commented-out
assignment, preceded by its `DocUda` description (any UDA with a `text`
member). Sections nest; an empty section is omitted. Stripped of its comments
the result decodes as the empty overlay — documentation until the user
uncomments something. The caller writes the enclosing braces and its header.
*/
void renderStarterSections(DocUda, Writer, T)(ref Writer w, in T value,
    int depth = 1)
{
    import sparkles.wired.json : toJSON;

    void indent()
    {
        foreach (_; 0 .. depth * 2)
            w ~= ' ';
    }

    static foreach (i, name; FieldNameTuple!T)
    {
        static if (hasUDA!(typeof(T.tupleof[i]), WireSection))
        {
            static if (FieldNameTuple!(typeof(T.tupleof[i])).length)
            {
                indent();
                w ~= '"';
                w ~= name;
                w ~= "\": {\n";
                renderStarterSections!DocUda(w, value.tupleof[i], depth + 1);
                indent();
                w ~= "},\n";
            }
        }
        else
        {{
            static if (hasUDA!(T.tupleof[i], DocUda))
            {
                indent();
                w ~= "// ";
                w ~= getUDAs!(T.tupleof[i], DocUda)[0].text;
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
// Reading a hand-edited file: one bad value costs that value.
// ─────────────────────────────────────────────────────────────────────────────

/// What $(LREF readJsoncFileTolerant) returns: the layer, and every value it
/// had to drop (each a decode error naming the file and the `$`-path).
struct TolerantRead(T)
{
    /// The decoded layer, without the dropped values.
    T value;
    /// One error per dropped value, in the order they were found.
    JsonError[] dropped;
}

/**
Reads `path` as JSONC into `T`, dropping the values that fail to decode:
each decode error's `$`-path is removed from the document and the decode is
retried, so a typo in one setting costs that setting and the rest of the file
still applies. A file that cannot be read or parsed at all, or a failure whose
path cannot be located (or more than `maxDrops` of them), is an error, as from
`readJsoncFile`.

Meant for a sparse layer (`Sparse!S`), where an absent key is always valid:
dropping a value can never make the decode fail for a missing field.
*/
Expected!(TolerantRead!T, JsonError) readJsoncFileTolerant(T)(string path,
    size_t maxDrops = 32)
{
    import std.file : readText;

    import sparkles.wired.json.jsonc : stripJsonc;
    import sparkles.wired.json.reader : parseJsonDocument;

    alias R = TolerantRead!T;

    static JsonError located(JsonError e, string path)
    {
        e.filePath ~= path;
        return e;
    }

    char[] text;
    try
        text = readText!(char[])(path);
    catch (Exception e)
    {
        JsonError fe;
        fe.stage = JsonStage.fileRead;
        fe.filePath ~= path;
        fe.reason = e.msg;
        return err!R(fe);
    }
    stripJsonc(text);

    R result;
    const(char)[] current = text;
    foreach (_; 0 .. maxDrops + 1)
    {
        auto r = fromJSON!T(current);
        if (r.hasValue)
        {
            result.value = r.value;
            return ok!JsonError(result);
        }
        auto e = located(r.error, path);
        if (e.stage != JsonStage.decode)
            return err!R(e);

        auto parsed = parseJsonDocument(current);
        if (parsed.hasError)
            return err!R(e);
        string rest;
        const segments = splitWirePath(e.path[], rest);
        if (segments is null || rest.length)
            return err!R(e);
        auto w = appender!(char[]);
        if (!writeWithout(parsed.document.root, segments, w))
            return err!R(e);
        // Located in the file as written: earlier drops rewrote `current`,
        // but the path still names the same value in the original text.
        size_t at;
        if (locateWirePath(text, segments, at))
            e.setLocation(text, at);
        result.dropped ~= e;
        current = w[];
    }
    JsonError last = result.dropped[$ - 1];
    last.reason = "too many invalid values";
    return err!R(last);
}

/// The segments of a decode error's `$`-path (`$.a.b[3]` or `.a.b[3]` → `a`, `b`, `[3]`);
/// null when it has none. Anything it cannot read is left in `rest`.
private string[] splitWirePath(scope const(char)[] p, out string rest) @safe pure
{
    string[] segs;
    size_t i = p.length && p[0] == '$' ? 1 : 0;
    while (i < p.length)
    {
        if (p[i] == '.')
        {
            size_t j = i + 1;
            while (j < p.length && p[j] != '.' && p[j] != '[')
                j++;
            segs ~= p[i + 1 .. j].idup;
            i = j;
        }
        else if (p[i] == '[' && i + 1 < p.length && p[i + 1] != '"')
        {
            size_t j = i + 1;
            while (j < p.length && p[j] != ']')
                j++;
            if (j == p.length)
                break;
            segs ~= p[i .. j + 1].idup;
            i = j + 1;
        }
        else
            break;
    }
    rest = p[i .. $].idup;
    return segs.length ? segs : null;
}

/**
Finds the value `segments` names in the JSON `text` and sets `offset` to its
first byte; false when the path is not there. A scanner, not a parse: it
skips what it does not descend into, so `text` must be valid JSON (it is: a
decode error comes after a successful parse).
*/
private bool locateWirePath(scope const(char)[] text, in string[] segments,
    out size_t offset) @safe pure nothrow @nogc
{
    size_t i;

    void space()
    {
        while (i < text.length && (text[i] == ' ' || text[i] == '\n'
            || text[i] == '\r' || text[i] == '\t'))
            i++;
    }

    // Skips a string at `i`; `[start, end)` are its raw contents (escapes
    // intact) — positions, not a slice, so nothing escapes `text`.
    void str(out size_t start, out size_t end)
    {
        start = ++i;
        while (i < text.length && text[i] != '"')
            i += text[i] == '\\' ? 2 : 1;
        end = i < text.length ? i : text.length;
        i++;
    }

    void skip()
    {
        space();
        if (i >= text.length)
            return;
        if (text[i] == '"')
        {
            size_t s, e;
            str(s, e);
            return;
        }
        if (text[i] == '{' || text[i] == '[')
        {
            int depth;
            while (i < text.length)
            {
                const c = text[i];
                if (c == '"')
                {
                    size_t s, e;
                    str(s, e);
                    continue;
                }
                if (c == '{' || c == '[')
                    depth++;
                else if (c == '}' || c == ']')
                {
                    i++;
                    if (--depth == 0)
                        return;
                    continue;
                }
                i++;
            }
            return;
        }
        while (i < text.length && text[i] != ',' && text[i] != '}' && text[i] != ']')
            i++;
    }

    foreach (seg; segments)
    {
        space();
        if (i >= text.length)
            return false;
        if (seg.length && seg[0] == '[')
        {
            if (text[i] != '[')
                return false;
            size_t want;
            foreach (c; seg[1 .. $ - 1])
            {
                if (c < '0' || c > '9')
                    return false;
                want = want * 10 + (c - '0');
            }
            i++;
            foreach (_; 0 .. want)
            {
                skip();
                space();
                if (i >= text.length || text[i] != ',')
                    return false;
                i++;
            }
            continue;
        }
        if (text[i] != '{')
            return false;
        i++;
        for (;;)
        {
            space();
            if (i >= text.length || text[i] != '"')
                return false;
            size_t ks, ke;
            str(ks, ke);
            space();
            if (i >= text.length || text[i] != ':')
                return false;
            i++;
            if (text[ks .. ke] == seg)
                break;
            skip();
            space();
            if (i >= text.length || text[i] != ',')
                return false;
            i++;
        }
    }
    space();
    offset = i;
    return i < text.length;
}

/// Writes `v` as JSON with the value at `segments` left out; false when the
/// path does not name a value in `v`.
private bool writeWithout(Writer)(JsonValue v, in string[] segments, ref Writer w)
{
    import std.conv : to;

    import sparkles.wired.json.writer : writeJson, writeJsonString;

    const seg = segments[0];
    const last = segments.length == 1;
    bool found;
    if (seg[0] == '[')
    {
        if (v.kind != JsonKind.array)
            return false;
        size_t want;
        try
            want = seg[1 .. $ - 1].to!size_t;
        catch (Exception)
            return false;
        w.put('[');
        bool first = true;
        size_t i;
        foreach (e; v.byElement)
        {
            const hit = i++ == want;
            found |= hit;
            if (hit && last)
                continue;
            if (!first)
                w.put(',');
            first = false;
            if (hit && !writeWithout(e, segments[1 .. $], w))
                return false;
            if (!hit)
                writeJson(e, w);
        }
        w.put(']');
        return found;
    }
    if (v.kind != JsonKind.object)
        return false;
    w.put('{');
    bool first = true;
    foreach (m; v.byKeyValue)
    {
        const hit = m.key == seg;
        found |= hit;
        if (hit && last)
            continue;
        if (!first)
            w.put(',');
        first = false;
        writeJsonString(w, m.key);
        w.put(':');
        if (hit && !writeWithout(m.value, segments[1 .. $], w))
            return false;
        if (!hit)
            writeJson(m.value, w);
    }
    w.put('}');
    return found;
}

@("wired.config_file.readJsoncFileTolerant.dropsOnlyTheBadValues")
@system unittest
{
    import std.algorithm.searching : canFind;

    import sparkles.test_utils.tmpfs : TmpFS;

    auto fixture = TmpFS.create();
    const path = fixture.writeFileAt("config.json", "{\n" ~
        "  // two typos and two good settings\n" ~
        "  \"theme\": \"builtin-dark\",\n" ~
        "  \"viewer\": { \"tabWidth\": \"eight\", \"lineNumbers\": false },\n" ~
        "  \"paths\": [\"/a\", 7],\n" ~
        "}\n");

    auto r = readJsoncFileTolerant!(Sparse!Cfg)(path);
    assert(r.hasValue, r.error.toString);
    assert(r.value.value.theme.get == "builtin-dark");
    assert(r.value.value.viewer.lineNumbers.get == false);
    assert(r.value.value.viewer.tabWidth.isNull, "the typo is dropped");
    assert(r.value.dropped.length == 2);
    assert(r.value.dropped[0].path[].canFind("tabWidth"));
    assert(r.value.dropped[0].filePath[] == path);
    // Each names where its value sits in the file as written, comments and
    // all, not only its `$`-path.
    assert(r.value.dropped[0].line == 4 && r.value.dropped[0].column == 27);
    assert(r.value.dropped[1].line == 5 && r.value.dropped[1].column == 19);
    assert(r.value.dropped[0].toString.canFind("(line 4, column 27)"));

    // A syntax error is not a value to drop: the whole file fails, located.
    const broken = fixture.writeFileAt("broken.json", "{\n  \"theme\": nope\n}\n");
    auto b = readJsoncFileTolerant!(Sparse!Cfg)(broken);
    assert(b.hasError && b.error.line == 2);
}

// ─────────────────────────────────────────────────────────────────────────────
// `config save` — persist deltas into the user file.
// ─────────────────────────────────────────────────────────────────────────────

/// Why a save did not happen.
struct SaveRefusal
{
    /// ditto
    enum Kind : ubyte
    {
        /// The existing file only parses as JSONC — comments a rewrite would
        /// destroy. A file the application did not generate is never
        /// rewritten.
        humanOwned,
        /// Encoding or filesystem failure.
        ioError,
    }

    Kind kind;

    /// Rendered explanation; for `humanOwned` it carries the exact strict-
    /// JSON delta snippet to paste, so the refusal is instructive, not lossy.
    string message;
}

/// The pretty strict-JSON text of a sparse overlay (unset fields omitted) —
/// what $(LREF saveSparseConfig) writes, and what a refusal shows to paste.
string sparseText(T)(in Sparse!T overlay)
{
    import std.array : appender;

    import sparkles.wired.json : writeJSON;
    import sparkles.wired.json.writer : JsonWriteOptions;

    auto w = appender!string;
    auto r = writeJSON!(JsonWriteOptions(pretty: true))(overlay, w);
    assert(!r.hasError, "a sparse overlay failed to encode");
    return w[];
}

/**
Persists `existing ∪ deltas` as the user file at `path`. The caller supplies
`deltas` as the settings the user actually changed, expressed sparsely, so a
value a higher layer (a flag, a compatibility file) supplied but the user
never touched is absent and can never be baked into the file.

A file that parses as strict RFC 8259 is machine-owned and is rewritten; one
that only parses as JSONC carries a human's comments and is $(B refused) with
the snippet to paste (`force` overwrites, destroying the comments). A missing
file is written fresh, with its directory. `appName` names the application in
the refusal.
*/
Expected!(void, SaveRefusal) saveSparseConfig(T)(string path,
    Sparse!T existing, Sparse!T deltas, string appName, bool force = false)
{
    import std.file : exists, mkdirRecurse, readText;
    import std.path : dirName;

    import sparkles.wired.json : writeJSONFile;

    static Expected!(void, SaveRefusal) refuse(SaveRefusal.Kind kind, string msg)
        => err!void(SaveRefusal(kind, msg));

    if (!path.length)
        return refuse(SaveRefusal.Kind.ioError, "no writable config location");

    const merged = mergeSparse!T(existing, deltas);

    if (path.exists && !force)
    {
        string text;
        try
            text = readText(path);
        catch (Exception e)
            return refuse(SaveRefusal.Kind.ioError, e.msg);

        if (fromJSON!(Sparse!T)(text).hasError)
            return refuse(SaveRefusal.Kind.humanOwned,
                path ~ " carries comments " ~ appName ~ " would destroy — " ~
                "paste this into it instead (or pass force):\n" ~
                sparseText!T(deltas));
    }

    try
        mkdirRecurse(path.dirName);
    catch (Exception e)
        return refuse(SaveRefusal.Kind.ioError, e.msg);

    auto wrote = writeJSONFile(merged, path);
    if (wrote.hasError)
        return refuse(SaveRefusal.Kind.ioError, wrote.error.toString);
    return ok!SaveRefusal();
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    private struct Note
    {
        string text;
    }

    @WireSection
    private struct Viewer
    {
        @Note("Spaces per tab stop.")
        int tabWidth = 4;
        bool lineNumbers = true;
    }

    private struct Cfg
    {
        @Note("Colour theme, by name.")
        string theme = "tokyo-night";
        Viewer viewer;
        string[] paths;
    }

    private enum Layer : ubyte { none, user, cli }
}

@("wired.config_file.renderConfigShow.originsAndFilter")
@safe unittest
{
    import std.algorithm.searching : canFind;
    import std.array : appender;
    import std.string : splitLines;
    import std.algorithm.searching : endsWith, startsWith;

    import sparkles.wired.overlay : applyOverlay, Origins;

    Cfg resolved;
    Origins!(Cfg, Layer) origins;
    Sparse!Cfg user;
    user.theme = "builtin-dark";
    user.viewer.tabWidth = 8;
    applyOverlay(resolved, origins, user, Layer.user);

    static string text(Layer l) => l == Layer.none ? "default" : "file:user.json";
    static bool dflt(Layer l) => l == Layer.none;

    auto full = appender!string;
    renderConfigShow!(text, dflt)(full, resolved, origins);
    assert(full[].splitLines.canFind!(l => l.startsWith("file:user.json ")
        && l.endsWith(" theme=builtin-dark")), full[]);
    assert(full[].canFind("viewer.tabWidth=8"));
    assert(full[].canFind("viewer.lineNumbers=true"));
    assert(full[].canFind("paths=[]"));

    auto changed = appender!string;
    renderConfigShow!(text, dflt)(changed, resolved, origins, changedOnly: true);
    assert(changed[].splitLines.length == 2, changed[]);
}

@("wired.config_file.renderStarterSections.decodesEmptyAndDocumented")
@system unittest
{
    import std.algorithm.searching : canFind;
    import std.array : appender;

    import sparkles.wired.json.jsonc : stripJsonc;

    auto w = appender!string;
    w ~= "{\n";
    renderStarterSections!Note(w, Cfg.init);
    w ~= "}\n";
    auto text = w[].dup;

    stripJsonc(text);
    auto r = fromJSON!(Sparse!Cfg)(text);
    assert(!r.hasError, r.error.toString);
    assert(r.value == Sparse!Cfg.init);

    assert(w[].canFind(`  // Colour theme, by name.`));
    assert(w[].canFind(`  // "theme": "tokyo-night",`));
    assert(w[].canFind(`  "viewer": {`));
    assert(w[].canFind(`    // Spaces per tab stop.`));
    assert(w[].canFind(`    // "tabWidth": 4,`));
}

@("wired.config_file.saveSparseConfig.freshRewriteAndRefusal")
@system unittest
{
    import std.algorithm.searching : canFind;
    import std.path : buildPath;

    import sparkles.test_utils.tmpfs : TmpFS;
    import sparkles.wired.json.jsonc : readJsoncFile;

    auto fixture = TmpFS.create();
    // A directory that does not exist yet: the save creates it.
    const path = buildPath(fixture.dir, "app", "config.json");

    Sparse!Cfg deltas;
    deltas.theme = "builtin-dark";
    deltas.viewer.tabWidth = 8;
    auto first = saveSparseConfig!Cfg(path, Sparse!Cfg.init, deltas, "app");
    assert(!first.hasError, first.hasError ? first.error.message : "");

    auto back = readJsoncFile!(Sparse!Cfg)(path);
    assert(!back.hasError);
    assert(back.value.theme.get == "builtin-dark");
    assert(back.value.viewer.lineNumbers.isNull, "still sparse");

    Sparse!Cfg next;
    next.viewer.tabWidth = 2;
    assert(!saveSparseConfig!Cfg(path, back.value, next, "app").hasError);
    auto again = readJsoncFile!(Sparse!Cfg)(path);
    assert(again.value.theme.get == "builtin-dark");
    assert(again.value.viewer.tabWidth.get == 2);

    // A commented file is human-owned: refused, with the snippet to paste.
    const human = fixture.writeFileAt("human.json",
        "{\n  // mine\n  \"theme\": \"x\"\n}\n");
    auto refused = saveSparseConfig!Cfg(human, Sparse!Cfg.init, next, "app");
    assert(refused.hasError);
    assert(refused.error.kind == SaveRefusal.Kind.humanOwned);
    assert(refused.error.message.canFind(`"tabWidth": 2`), refused.error.message);
    assert(refused.error.message.canFind("app would destroy"));
}
