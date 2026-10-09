/**
The Design Tokens Community Group format, edition 2025.10 (D12): a parsed
token document that can be resolved and written back in canonical form.

The theme file ($(MREF sparkles,ui,theme_file)) is one consumer; nothing here
knows what a theme is. This module owns the format's own rules:

$(LIST
    * $(B The tree is kept.) $(LREF DtcgJson) is an owned, editable copy of the
        whole document, so a file saved after loading keeps its primitives,
        aliases, descriptions and unknown `$extensions` (`FMT4`).
    * $(B Canonical output.) $(LREF writeDtcg) sorts object keys and indents
        by two spaces, so two documents that are equal as DTCG serialize to the
        same bytes.
    * $(B Resolution.) $(LREF DtcgTokens) applies group `$extends`, collects
        every token (including `$root` tokens), inherits `$type` from the
        closest group, and resolves both alias forms — `"{a.b}"` and the
        `{"$ref": "#/a/b/$value"}` JSON Pointer — with cycle detection.
    * $(B Values.) Colors and dimensions parse from the 2025.10 object forms
        and, for files written against the drafts, from `"#rrggbb"` and
        `"4px"` strings; they are always written in the 2025.10 form.
)

Every failure is a $(LREF DtcgError) naming the JSON path it concerns, never an
assertion (`FMT3`).
*/
module sparkles.ui.dtcg;

import std.algorithm.comparison : among;
import std.array : appender, join;
import std.conv : ConvException, to;
import std.format : format;
import std.math : round;
import std.range.primitives : put;

import expected : err, Expected, ok;

import sparkles.base.term_color : RgbColor;
import sparkles.base.text.writers : formatted;

@safe:

// ── the format ──────────────────────────────────────────────────────────────

/**
The DTCG format tag: a theme file and the CSS properties emitted from it spell
an enum member by its wire name (`ColorChannel.foreground` is `fg`), resolved
by `sparkles.base.text.wire_names` like every other format.
*/
struct Dtcg
{
}

// ── errors ──────────────────────────────────────────────────────────────────

/// A failure, located: `path` is a JSON path (`$.text.primary.fg.$value`) or,
/// for a parse failure, `line:column`.
struct DtcgError
{
    string path;    /// where
    string message; /// what

    /// `path: message`.
    void toString(W)(ref W w) const
    {
        put(w, path);
        put(w, ": ");
        put(w, message);
    }
}

/// A value or the error that prevented it.
alias DtcgResult(T) = Expected!(T, DtcgError);

private DtcgResult!T fail(T)(string path, string message)
    => err!T(DtcgError(path, message));

// ── the owned tree ──────────────────────────────────────────────────────────

/**
An owned, editable JSON value. Numbers keep their source lexeme, so a document
round-trips without reformatting its numbers; object members keep their source
order until $(LREF writeDtcg) sorts them.
*/
struct DtcgJson
{
    /// The JSON type.
    enum Kind : ubyte
    {
        null_,   ///
        bool_,   ///
        number,  /// `text` holds the lexeme
        string_, /// `text` holds the unescaped string
        array,   /// `items`
        object,  /// `members`
    }

    Kind kind;             ///
    bool boolean;          /// for `bool_`
    string text;           /// for `number` and `string_`
    DtcgJson[] items;      /// for `array`
    DtcgMember[] members;  /// for `object`

    /// Constructors for each kind.
    static DtcgJson str(string s) pure nothrow => DtcgJson(Kind.string_, false, s);
    /// ditto
    static DtcgJson num(string lexeme) pure nothrow => DtcgJson(Kind.number, false, lexeme);
    /// ditto
    static DtcgJson num(double v)
        => DtcgJson(Kind.number, false, formatted!writeNumber(v).toString);
    /// ditto
    static DtcgJson boolean_(bool b) pure nothrow => DtcgJson(Kind.bool_, b);
    /// ditto
    static DtcgJson object(DtcgMember[] m = null) pure nothrow
        => DtcgJson(Kind.object, false, null, null, m);
    /// ditto
    static DtcgJson array(DtcgJson[] a) pure nothrow
        => DtcgJson(Kind.array, false, null, a);

    /// Whether this is an object.
    bool isObject() const pure nothrow @nogc => kind == Kind.object;
    /// Whether this is a string.
    bool isString() const pure nothrow @nogc => kind == Kind.string_;

    /// The member named `key`, or `null`.
    inout(DtcgJson)* get(scope const(char)[] key) inout return pure nothrow @nogc
    {
        foreach (ref m; members)
            if (m.key == key)
                return &m.value;
        return null;
    }

    /// Sets member `key`, replacing an existing one in place.
    void set(string key, DtcgJson value) pure nothrow
    {
        if (auto p = get(key))
            *p = value;
        else
            members ~= DtcgMember(key, value);
    }

    /// Removes member `key`; whether it existed.
    bool remove(scope const(char)[] key) pure nothrow
    {
        foreach (i, ref m; members)
            if (m.key == key)
            {
                members = members[0 .. i] ~ members[i + 1 .. $];
                return true;
            }
        return false;
    }

    /// A deep copy: editing it never changes `this`.
    DtcgJson dup() const pure nothrow
    {
        DtcgJson r;
        r.kind = kind;
        r.boolean = boolean;
        r.text = text;
        foreach (ref i; items)
            r.items ~= i.dup;
        foreach (ref m; members)
            r.members ~= DtcgMember(m.key, m.value.dup);
        return r;
    }

    /// Structural equality, member order ignored and numbers compared by
    /// value — "equal as DTCG".
    bool sameAs(const DtcgJson o) const
    {
        if (kind != o.kind)
            return false;
        final switch (kind)
        {
            case Kind.null_:   return true;
            case Kind.bool_:   return boolean == o.boolean;
            case Kind.string_: return text == o.text;
            case Kind.number:  return numberOf(text) == numberOf(o.text);
            case Kind.array:
                if (items.length != o.items.length)
                    return false;
                foreach (i, ref v; items)
                    if (!v.sameAs(o.items[i]))
                        return false;
                return true;
            case Kind.object:
                if (members.length != o.members.length)
                    return false;
                foreach (ref m; members)
                {
                    auto other = o.get(m.key);
                    if (other is null || !m.value.sameAs(*other))
                        return false;
                }
                return true;
        }
    }
}

/// One object member.
struct DtcgMember
{
    string key;     ///
    DtcgJson value; ///
}

// Correctly rounded on every platform (`sparkles.base.text.float_conv`), so a
// lexeme and the double it names agree everywhere; the whole lexeme must be
// a number.
package double numberOf(string lexeme)
{
    import sparkles.base.text.float_conv : readDecimalFloat;

    const(char)[] rest = lexeme;
    auto r = readDecimalFloat!double(rest);
    return r.hasValue && rest.length == 0 ? r.value : double.nan;
}

/// Writes the shortest lexeme of `v` that reads back as the same `double`:
/// an integral value as an integer, else wired's JSON writer, which owns that
/// algorithm rather than trusting the C runtime's `%g`, whose round trip
/// differs between platforms.
void writeNumber(W)(ref W w, double v)
{
    import sparkles.base.text.writers : writeInteger;
    import sparkles.wired.json.writer : writeJsonDouble;

    if (v == cast(long) v && v > -1e15 && v < 1e15)
        writeInteger(w, cast(long) v);
    else
        writeJsonDouble(w, v);
}

@("dtcg.writeNumber.shortest")
@safe unittest
{
    import sparkles.base.buffer : checkWriter;

    checkWriter!((ref b) => writeNumber(b, 4))("4");
    checkWriter!((ref b) => writeNumber(b, 0.5))("0.5");
    // A runtime double: a constant-folded one may carry extra precision.
    double v = 0x1e;
    v /= 255;
    assert(numberOf(formatted!writeNumber(v).toString) == v);
}

// ── parsing and writing ─────────────────────────────────────────────────────

/**
Parses a DTCG document: a JSON object. A syntax error reports its line and
column; a document whose root is not an object, or an object with a repeated
key, is rejected.
*/
DtcgResult!DtcgJson parseDtcg(scope const(char)[] text)
{
    import sparkles.wired.json.document : JsonKind, JsonValue;
    import sparkles.wired.json.error : parseStageError;
    import sparkles.wired.json.reader : JsonReadOptions, parseJsonDocument;

    enum JsonReadOptions opts = { rawNumbers: true };
    auto parsed = parseJsonDocument!opts(text);
    if (parsed.hasError)
    {
        const e = parseStageError(parsed.error, text);
        return fail!DtcgJson(format("%s:%s", e.line, e.column),
            "malformed JSON: " ~ e.reason.idup);
    }
    const root = parsed.document.root;
    if (root.kind != JsonKind.object)
        return fail!DtcgJson("$", "a DTCG document is a JSON object");

    string duplicate;
    DtcgJson own(JsonValue v, string path)
    {
        final switch (v.kind)
        {
            case JsonKind.none:
            case JsonKind.null_:
                return DtcgJson.init;
            case JsonKind.bool_:
                return DtcgJson.boolean_(v.boolean);
            case JsonKind.integer:
            case JsonKind.uinteger:
            case JsonKind.floating:
                return DtcgJson.num(v.asDouble);
            case JsonKind.rawNumber:
                return DtcgJson.num(v.raw.idup);
            case JsonKind.string_:
                return DtcgJson.str(v.str.idup);
            case JsonKind.array:
            {
                DtcgJson[] items;
                size_t i;
                foreach (e; v.byElement)
                    items ~= own(e, format("%s[%s]", path, i++));
                return DtcgJson.array(items);
            }
            case JsonKind.object:
            {
                auto r = DtcgJson.object();
                foreach (m; v.byKeyValue)
                {
                    const key = m.key.idup;
                    const childPath = path ~ "." ~ key;
                    if (r.get(key) !is null && duplicate is null)
                        duplicate = childPath;
                    r.members ~= DtcgMember(key, own(m.value, childPath));
                }
                return r;
            }
        }
    }

    auto tree = own(root, "$");
    if (duplicate !is null)
        return fail!DtcgJson(duplicate, "the key is repeated in its object");
    return ok!DtcgError(tree);
}

/**
Writes `doc` canonically: object keys sorted by code unit (so `$type` and
`$value` lead their token), two-space indentation, one member per line, and a
final newline. Two documents that are $(LREF DtcgJson.sameAs) each other and
spell their numbers alike write the same bytes.
*/
void writeDtcg(W)(ref W w, const DtcgJson doc)
{
    writeValue(w, doc, 0);
    put(w, "\n");
}

/// ditto
string writeDtcg(const DtcgJson doc)
{
    auto w = appender!string;
    writeDtcg(w, doc);
    return w[];
}

private void writeValue(W)(ref W w, const DtcgJson v, uint depth)
{
    import sparkles.wired.json.writer : writeJsonString;

    void indent(uint d)
    {
        put(w, "\n");
        foreach (_; 0 .. d)
            put(w, "  ");
    }

    final switch (v.kind)
    {
        case DtcgJson.Kind.null_:
            put(w, "null");
            break;
        case DtcgJson.Kind.bool_:
            put(w, v.boolean ? "true" : "false");
            break;
        case DtcgJson.Kind.number:
            put(w, v.text);
            break;
        case DtcgJson.Kind.string_:
            writeJsonString(w, v.text);
            break;
        case DtcgJson.Kind.array:
            if (v.items.length == 0)
            {
                put(w, "[]");
                break;
            }
            // An array of scalars stays on one line: components, attributes.
            bool flat = true;
            foreach (ref i; v.items)
                if (i.kind.among(DtcgJson.Kind.array, DtcgJson.Kind.object))
                    flat = false;
            put(w, "[");
            foreach (n, ref i; v.items)
            {
                if (n)
                    put(w, flat ? ", " : ",");
                if (!flat)
                    indent(depth + 1);
                writeValue(w, i, depth + 1);
            }
            if (!flat)
                indent(depth);
            put(w, "]");
            break;
        case DtcgJson.Kind.object:
            if (v.members.length == 0)
            {
                put(w, "{}");
                break;
            }
            put(w, "{");
            foreach (n, ref m; sortedMembers(v))
            {
                if (n)
                    put(w, ",");
                indent(depth + 1);
                writeJsonString(w, m.key);
                put(w, ": ");
                writeValue(w, m.value, depth + 1);
            }
            indent(depth);
            put(w, "}");
            break;
    }
}

private const(DtcgMember)[] sortedMembers(const DtcgJson v)
{
    import std.algorithm.sorting : sort;

    DtcgMember[] copy;
    foreach (ref m; v.members)
        copy ~= DtcgMember(m.key, m.value.dup);
    copy.sort!((a, b) => a.key < b.key);
    return copy;
}

@("dtcg.parseAndWrite.canonical")
@safe unittest
{
    const doc = parseDtcg(`{"b": {"$value": 1.50, "$type": "number"}, "a": [1, 2]}`).value;
    assert(writeDtcg(doc) == "{\n  \"a\": [1, 2],\n  \"b\": {\n    \"$type\": \"number\",\n"
        ~ "    \"$value\": 1.50\n  }\n}\n");
    // Reading the canonical form back is a fixed point.
    assert(writeDtcg(parseDtcg(writeDtcg(doc)).value) == writeDtcg(doc));
}

@("dtcg.parse.rejectsWithALocation")
@safe unittest
{
    auto bad = parseDtcg(`{"a": }`);
    assert(bad.hasError && bad.error.path == "1:7", bad.error.path);
    auto notObject = parseDtcg(`[1]`);
    assert(notObject.hasError && notObject.error.path == "$");
    auto repeated = parseDtcg(`{"a": {"x": 1, "x": 2}}`);
    assert(repeated.hasError && repeated.error.path == "$.a.x");
}

// ── tokens, types and aliases ───────────────────────────────────────────────

/// One token: its dotted path, its JSON path, its resolved `$type`, and its
/// raw (unresolved) `$value`.
struct DtcgToken
{
    string path;     /// `text.primary.fg`, or `accent.$root`
    string jsonPath; /// `$.text.primary.fg`
    string type;     /// after inheritance and alias typing
    DtcgJson value;  /// the `$value` as written
    DtcgJson node;   /// the whole token object, `$extensions` included
}

/**
The tokens of a document, with group `$extends` applied, `$type` inherited and
aliases resolvable. Built by $(LREF collectTokens); the source document is not
modified, so it can still be saved as written.
*/
struct DtcgTokens
{
    DtcgToken[] tokens;       /// in document order
    DtcgJson expanded;        /// the document after `$extends`
    private size_t[string] byPath;

    /// The token at `path`, or `null`.
    const(DtcgToken)* opBinaryRight(string op : "in")(scope const(char)[] path) const
    {
        if (auto i = path in byPath)
            return &tokens[*i];
        return null;
    }

    /**
    The token's value with every alias inside it replaced by its target's
    resolved value. Fails on an unknown target or a cycle.
    */
    DtcgResult!DtcgJson resolved(scope const(char)[] path) const
    {
        auto t = path in this;
        if (t is null)
            return fail!DtcgJson("$." ~ path.idup, "no token has this path");
        string[] stack = [t.path];
        return resolveValue(t.value, t.jsonPath ~ ".$value", stack);
    }

    private DtcgResult!DtcgJson resolveValue(const DtcgJson v, string where,
        ref string[] stack) const
    {
        if (auto target = aliasTarget(v))
        {
            auto node = lookup(*target, where);
            if (node.hasError)
                return err!DtcgJson(node.error);
            const key = node.value.key;
            foreach (s; stack)
                if (s == key)
                    return fail!DtcgJson(where, "alias cycle through " ~ (stack ~ key).join(" -> "));
            stack ~= key;
            scope (exit) stack = stack[0 .. $ - 1];
            return resolveValue(node.value.value, where, stack);
        }
        if (v.kind == DtcgJson.Kind.object)
        {
            auto r = DtcgJson.object();
            foreach (ref m; v.members)
            {
                auto c = resolveValue(m.value, where ~ "." ~ m.key, stack);
                if (c.hasError)
                    return c;
                r.members ~= DtcgMember(m.key, c.value);
            }
            return ok!DtcgError(r);
        }
        if (v.kind == DtcgJson.Kind.array)
        {
            DtcgJson[] items;
            foreach (i, ref e; v.items)
            {
                auto c = resolveValue(e, format("%s[%s]", where, i), stack);
                if (c.hasError)
                    return c;
                items ~= c.value;
            }
            return ok!DtcgError(DtcgJson.array(items));
        }
        return ok!DtcgError(v.dup);
    }

    private struct Found { string key; DtcgJson value; }

    // An alias target is either a token path (`{a.b}`) or a JSON Pointer
    // (`#/a/b/$value`); both resolve to a value and an identity for cycles.
    private DtcgResult!Found lookup(const AliasTarget target, string where) const
    {
        if (!target.pointer)
        {
            auto t = target.text in this;
            if (t is null)
                return fail!Found(where, "alias {" ~ target.text ~ "} names no token");
            return ok!DtcgError(Found(t.path, t.value.dup));
        }
        const(DtcgJson)* node = &expanded;
        string[] segs;
        foreach (raw; splitPointer(target.text))
        {
            const seg = unescapePointer(raw);
            segs ~= seg;
            if (node.kind == DtcgJson.Kind.object)
                node = node.get(seg);
            else if (node.kind == DtcgJson.Kind.array)
            {
                size_t i;
                try
                    i = seg.to!size_t;
                catch (ConvException)
                    node = null;
                node = node !is null && i < node.items.length ? &node.items[i] : null;
            }
            else
                node = null;
            if (node is null)
                return fail!Found(where, "$ref " ~ target.text ~ " points at nothing");
        }
        // A pointer at a token object (not at its `$value`) means the value.
        if (node.kind == DtcgJson.Kind.object)
            if (auto v = node.get("$value"))
                return ok!DtcgError(Found("#/" ~ segs.join("/"), v.dup));
        return ok!DtcgError(Found("#/" ~ segs.join("/"), node.dup));
    }
}

/// An alias, if `v` is one: the `"{a.b}"` string form or the `{"$ref": …}`
/// object form.
struct AliasTarget
{
    string text;  /// the token path, or the pointer without its `#/`
    bool pointer; /// whether `text` is a JSON Pointer
}

/// ditto
AliasTarget* aliasTarget(const DtcgJson v)
{
    if (v.kind == DtcgJson.Kind.string_ && v.text.length > 2
        && v.text[0] == '{' && v.text[$ - 1] == '}')
        return new AliasTarget(v.text[1 .. $ - 1], false);
    if (v.kind == DtcgJson.Kind.object && v.members.length == 1)
        if (auto r = v.get("$ref"))
            if (r.isString && r.text.length >= 2 && r.text[0 .. 2] == "#/")
                return new AliasTarget(r.text[2 .. $], true);
    return null;
}

private string[] splitPointer(string p)
{
    import std.algorithm.iteration : splitter;
    import std.array : array;

    return p.splitter('/').array;
}

private string unescapePointer(string s)
{
    import std.array : replace;

    return s.replace("~1", "/").replace("~0", "~");
}

/// Whether `name` may name a group or token: no leading `$` (except
/// `$root`), and none of `{`, `}`, `.`.
bool isValidTokenName(scope const(char)[] name) pure nothrow @nogc
{
    if (name.length == 0)
        return false;
    if (name[0] == '$')
        return name == "$root";
    foreach (c; name)
        if (c == '{' || c == '}' || c == '.')
            return false;
    return true;
}

/**
Collects every token of `doc` (`DTCG §5–§6`): applies group `$extends`, walks
groups with the closest `$type` inherited, and types an untyped alias token
from its target. Fails, with the offending path, on an invalid name, a token
with no determinable type, or an `$extends` that names nothing or cycles.
*/
DtcgResult!DtcgTokens collectTokens(const DtcgJson doc)
{
    DtcgTokens r;
    auto expanded = expandExtends(doc);
    if (expanded.hasError)
        return err!DtcgTokens(expanded.error);
    r.expanded = expanded.value;

    string[] untyped; // paths whose type comes from their alias target

    DtcgError failure;
    bool failed;

    void walk(const DtcgJson node, string path, string jsonPath, string inherited)
    {
        if (failed)
            return;
        if (node.get("$value") !is null)
        {
            string type = inherited;
            if (auto t = node.get("$type"))
                type = t.text;
            r.byPath[path] = r.tokens.length;
            r.tokens ~= DtcgToken(path, jsonPath, type, node.get("$value").dup, node.dup);
            if (type.length == 0)
                untyped ~= path;
            return;
        }
        string groupType = inherited;
        if (auto t = node.get("$type"))
            groupType = t.text;
        foreach (ref m; node.members)
        {
            if (m.key.length && m.key[0] == '$' && m.key != "$root")
                continue;
            if (!isValidTokenName(m.key))
            {
                failure = DtcgError(jsonPath ~ "." ~ m.key,
                    "a name may not start with $ or contain {, } or .");
                failed = true;
                return;
            }
            if (!m.value.isObject)
            {
                failure = DtcgError(jsonPath ~ "." ~ m.key,
                    "a group member must be a token or a group (an object)");
                failed = true;
                return;
            }
            walk(m.value, path.length ? path ~ "." ~ m.key : m.key,
                jsonPath ~ "." ~ m.key, groupType);
        }
    }

    walk(r.expanded, "", "$", "");
    if (failed)
        return err!DtcgTokens(failure);

    // An untyped token takes its alias target's type; follow chains.
    foreach (p; untyped)
    {
        auto t = &r.tokens[r.byPath[p]];
        string[] seen = [p];
        DtcgToken* cur = t;
        while (cur.type.length == 0)
        {
            auto a = aliasTarget(cur.value);
            // A pointer at a token's `$value` names that token.
            if (a !is null && a.pointer && a.text.length > 7 && a.text[$ - 7 .. $] == "/$value")
                *a = AliasTarget(splitPointer(a.text[0 .. $ - 7]).join("."), false);
            if (a is null || a.pointer)
                return fail!DtcgTokens(t.jsonPath,
                    "the token has no $type and none can be inherited");
            auto next = a.text in r.byPath;
            if (next is null)
                return fail!DtcgTokens(t.jsonPath ~ ".$value",
                    "alias {" ~ a.text ~ "} names no token");
            foreach (s; seen)
                if (s == a.text)
                    return fail!DtcgTokens(t.jsonPath ~ ".$value",
                        "alias cycle through " ~ (seen ~ a.text).join(" -> "));
            seen ~= a.text;
            cur = &r.tokens[*next];
        }
        t.type = cur.type;
    }
    return ok!DtcgError(r);
}

// `$extends` (2025.10 §6.4): a group inherits a target group's members, deep
// merged — a local token replaces an inherited one, a local group merges.
private DtcgResult!DtcgJson expandExtends(const DtcgJson doc)
{
    auto root = doc.dup;
    string[] active;

    DtcgResult!bool expand(ref DtcgJson node, string jsonPath)
    {
        foreach (ref m; node.members)
            if (m.value.isObject && m.value.get("$value") is null)
            {
                auto r = expand(m.value, jsonPath ~ "." ~ m.key);
                if (r.hasError)
                    return r;
            }
        auto ext = node.get("$extends");
        if (ext is null)
            return ok!DtcgError(true);
        auto a = aliasTarget(*ext);
        if (a is null || a.pointer)
            return fail!bool(jsonPath ~ ".$extends", "$extends names a group as {a.b}");
        foreach (s; active)
            if (s == a.text)
                return fail!bool(jsonPath ~ ".$extends",
                    "$extends cycle through " ~ (active ~ a.text).join(" -> "));
        const(DtcgJson)* target = &root;
        import std.algorithm.iteration : splitter;
        foreach (seg; a.text.splitter('.'))
        {
            target = target.get(seg);
            if (target is null)
                return fail!bool(jsonPath ~ ".$extends",
                    "$extends {" ~ a.text ~ "} names no group");
        }
        if (target.get("$value") !is null)
            return fail!bool(jsonPath ~ ".$extends",
                "$extends {" ~ a.text ~ "} names a token, not a group");
        active ~= a.text;
        scope (exit) active = active[0 .. $ - 1];
        auto base = target.dup;
        auto r = expand(base, "$." ~ a.text);
        if (r.hasError)
            return r;
        base.remove("$extends");
        auto local = node.dup;
        local.remove("$extends");
        node = mergeGroups(base, local);
        return ok!DtcgError(true);
    }

    auto r = expand(root, "$");
    if (r.hasError)
        return err!DtcgJson(r.error);
    return ok!DtcgError(root);
}

private DtcgJson mergeGroups(DtcgJson base, const DtcgJson local)
{
    foreach (ref m; local.members)
    {
        auto existing = base.get(m.key);
        const bothGroups = existing !is null && existing.isObject && m.value.isObject
            && existing.get("$value") is null && m.value.get("$value") is null;
        if (bothGroups)
            *existing = mergeGroups(*existing, m.value);
        else
            base.set(m.key, m.value.dup);
    }
    return base;
}

@("dtcg.collectTokens.inheritsTypesAndResolvesAliases")
@safe unittest
{
    const doc = parseDtcg(`{
        "color": { "$type": "color",
            "indigo": { "$value": "#4f46e5" },
            "accent": { "$root": { "$value": "{color.indigo}" } } },
        "link": { "$value": {"$ref": "#/color/indigo/$value"} },
        "chain": { "$value": "{link}" }
    }`).value;
    auto toks = collectTokens(doc);
    assert(toks.hasValue, toks.hasError ? toks.error.message : "");
    const t = toks.value;
    assert(("color.accent.$root" in t).type == "color");
    assert(t.resolved("color.accent.$root").value.text == "#4f46e5");
    assert(t.resolved("link").value.text == "#4f46e5");
    // Untyped tokens take their target's type through both alias forms:
    // `chain` → `{link}` → `#/color/indigo/$value` → `color`.
    assert(("link" in t).type == "color");
    assert(("chain" in t).type == "color");
    assert(t.resolved("chain").value.text == "#4f46e5");
}

@("dtcg.collectTokens.rejectsCyclesAndDanglingAliases")
@safe unittest
{
    auto cyc = collectTokens(parseDtcg(`{"a": {"$type": "number", "$value": "{b}"},
        "b": {"$type": "number", "$value": "{a}"}}`).value);
    assert(cyc.hasValue);
    auto r = cyc.value.resolved("a");
    assert(r.hasError && r.error.path == "$.a.$value", r.error.path);

    auto dangling = collectTokens(parseDtcg(`{"a": {"$type": "number", "$value": "{nope}"}}`).value);
    assert(dangling.value.resolved("a").hasError);

    auto untyped = collectTokens(parseDtcg(`{"a": {"$value": 1}}`).value);
    assert(untyped.hasError && untyped.error.path == "$.a");

    auto badName = collectTokens(parseDtcg(`{"a.b": {"$type": "number", "$value": 1}}`).value);
    assert(badName.hasError && badName.error.path == "$.a.b");
}

@("dtcg.collectTokens.extendsMergesGroups")
@safe unittest
{
    auto t = collectTokens(parseDtcg(`{
        "button": { "$type": "number", "pad": { "$value": 1 }, "gap": { "$value": 2 } },
        "wide": { "$extends": "{button}", "pad": { "$value": 3 } }
    }`).value);
    assert(t.hasValue, t.hasError ? t.error.message : "");
    assert(t.value.resolved("wide.pad").value.text == "3");
    assert(t.value.resolved("wide.gap").value.text == "2");
    assert(("wide.gap" in t.value).type == "number");

    auto cyc = collectTokens(parseDtcg(`{"a": {"$extends": "{b}"}, "b": {"$extends": "{a}"}}`).value);
    assert(cyc.hasError);
}

// ── values ──────────────────────────────────────────────────────────────────

/// An sRGB color with 8-bit channels and alpha.
struct DtcgColor
{
    RgbColor rgb;       ///
    ubyte alpha = 0xFF; ///
}

/**
Reads a resolved `color` value: the 2025.10 object (`colorSpace` `srgb`, or
any space that carries a `hex` fallback) or, from the drafts, a `#rgb`,
`#rgba`, `#rrggbb` or `#rrggbbaa` string.
*/
DtcgResult!DtcgColor parseColor(const DtcgJson v, string where)
{
    if (v.isString)
        return parseHex(v.text, where);
    if (!v.isObject)
        return fail!DtcgColor(where, "a color is an object (or, in drafts, a hex string)");
    DtcgColor c;
    if (auto a = v.get("alpha"))
    {
        auto x = unitInterval(*a, where ~ ".alpha");
        if (x.hasError)
            return err!DtcgColor(x.error);
        c.alpha = cast(ubyte) round(x.value * 255);
    }
    const space = v.get("colorSpace");
    if (space is null || !space.isString)
        return fail!DtcgColor(where ~ ".colorSpace", "a color names its colorSpace");
    if (space.text != "srgb")
    {
        // Another space is usable only through its sRGB `hex` fallback.
        if (auto h = v.get("hex"))
        {
            auto fromHex = parseHex(h.text, where ~ ".hex");
            if (fromHex.hasError)
                return fromHex;
            fromHex.value.alpha = c.alpha;
            return fromHex;
        }
        return fail!DtcgColor(where ~ ".colorSpace",
            "color space " ~ space.text ~ " is supported only with a hex fallback");
    }
    const comps = v.get("components");
    if (comps is null || comps.kind != DtcgJson.Kind.array || comps.items.length != 3)
        return fail!DtcgColor(where ~ ".components", "an srgb color has three components");
    ubyte[3] ch;
    foreach (i, ref e; comps.items)
    {
        if (e.isString && e.text == "none")
            continue;
        auto x = unitInterval(e, format("%s.components[%s]", where, i));
        if (x.hasError)
            return err!DtcgColor(x.error);
        ch[i] = cast(ubyte) round(x.value * 255);
    }
    c.rgb = RgbColor(ch[0], ch[1], ch[2]);
    return ok!DtcgError(c);
}

private DtcgResult!double unitInterval(const DtcgJson v, string where)
{
    if (v.kind != DtcgJson.Kind.number)
        return fail!double(where, "expected a number from 0 to 1");
    double x = numberOf(v.text);
    if (!(x >= 0 && x <= 1))
        return fail!double(where, "out of range: " ~ v.text ~ " is not from 0 to 1");
    return ok!DtcgError(x);
}

private DtcgResult!DtcgColor parseHex(string s, string where)
{
    static int nibble(char c) pure nothrow @nogc
    {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    }
    if (s.length == 0 || s[0] != '#' || !s.length.among(4, 5, 7, 9))
        return fail!DtcgColor(where, "not a hex color: " ~ s);
    const d = s[1 .. $];
    ubyte[4] v = [0, 0, 0, 0xFF];
    const short_ = d.length <= 4;
    foreach (i; 0 .. (short_ ? d.length : d.length / 2))
    {
        int x;
        if (short_)
        {
            const n = nibble(d[i]);
            if (n < 0)
                return fail!DtcgColor(where, "not a hex color: " ~ s);
            x = n * 17;
        }
        else
        {
            const hi = nibble(d[2 * i]), lo = nibble(d[2 * i + 1]);
            if (hi < 0 || lo < 0)
                return fail!DtcgColor(where, "not a hex color: " ~ s);
            x = hi * 16 + lo;
        }
        v[i] = cast(ubyte) x;
    }
    return ok!DtcgError(DtcgColor(RgbColor(v[0], v[1], v[2]), v[3]));
}

/// A color in the 2025.10 form: sRGB components, `alpha` only when not
/// opaque, and the `hex` fallback.
DtcgJson colorValue(const DtcgColor c)
{
    // Four decimals: channels are 1/255 apart, so rounding back is exact.
    DtcgJson comp(ubyte x) => DtcgJson.num(formatted!writeNumber(round(x / 255.0 * 1e4) / 1e4).toString);
    auto o = DtcgJson.object([
        DtcgMember("colorSpace", DtcgJson.str("srgb")),
        DtcgMember("components", DtcgJson.array([comp(c.rgb.r), comp(c.rgb.g), comp(c.rgb.b)])),
        DtcgMember("hex", DtcgJson.str(format("#%02x%02x%02x", c.rgb.r, c.rgb.g, c.rgb.b))),
    ]);
    if (c.alpha != 0xFF)
        o.set("alpha", DtcgJson.num(formatted!writeNumber(c.alpha / 255.0).toString));
    return o;
}

@("dtcg.color.bothFormsRoundTrip")
@safe unittest
{
    const c = DtcgColor(RgbColor(0x1e, 0x1e, 0x2e), 0x80);
    assert(parseColor(colorValue(c), "$").value == c);
    assert(parseColor(DtcgJson.str("#1e1e2e80"), "$").value == c);
    assert(parseColor(DtcgJson.str("#fff"), "$").value == DtcgColor(RgbColor(255, 255, 255)));
    auto range = parseColor(parseDtcg(`{"x": {"colorSpace": "srgb", "components": [0, 2, 0]}}`)
        .value.members[0].value, "$.x");
    assert(range.hasError && range.error.path == "$.x.components[1]");
    auto space = parseColor(parseDtcg(`{"x": {"colorSpace": "oklch", "components": [0.5, 0.1, 200]}}`)
        .value.members[0].value, "$.x");
    assert(space.hasError);
    auto viaHex = parseColor(parseDtcg(`{"x": {"colorSpace": "oklch", "components": [0.5, 0.1, 200], "hex": "#336699"}}`)
        .value.members[0].value, "$.x");
    assert(viaHex.value.rgb == RgbColor(0x33, 0x66, 0x99));
}

/// A `dimension`: a value and its unit.
struct DtcgDimension
{
    double value; ///
    string unit;  /// `px` or `rem`
}

/// Reads a resolved `dimension` value: the 2025.10 `{value, unit}` object or,
/// from the drafts, a `"4px"` string.
DtcgResult!DtcgDimension parseDimension(const DtcgJson v, string where)
{
    if (v.isString)
    {
        foreach (unit; ["px", "rem"])
            if (v.text.length > unit.length && v.text[$ - unit.length .. $] == unit)
            {
                const x = numberOf(v.text[0 .. $ - unit.length]);
                if (x == x)
                    return ok!DtcgError(DtcgDimension(x, unit));
            }
        return fail!DtcgDimension(where, "not a dimension: " ~ v.text);
    }
    if (!v.isObject)
        return fail!DtcgDimension(where, "a dimension is {value, unit}");
    const val = v.get("value"), unit = v.get("unit");
    if (val is null || val.kind != DtcgJson.Kind.number)
        return fail!DtcgDimension(where ~ ".value", "a dimension's value is a number");
    if (unit is null || !unit.isString || !unit.text.among("px", "rem"))
        return fail!DtcgDimension(where ~ ".unit", "a dimension's unit is px or rem");
    return ok!DtcgError(DtcgDimension(numberOf(val.text), unit.text));
}

/// A dimension in the 2025.10 form.
DtcgJson dimensionValue(double value, string unit = "px")
    => DtcgJson.object([
        DtcgMember("unit", DtcgJson.str(unit)),
        DtcgMember("value", DtcgJson.num(value)),
    ]);

@("dtcg.dimension.bothForms")
@safe unittest
{
    assert(parseDimension(dimensionValue(4), "$").value == DtcgDimension(4, "px"));
    assert(parseDimension(DtcgJson.str("1.5rem"), "$").value == DtcgDimension(1.5, "rem"));
    assert(parseDimension(DtcgJson.str("4em"), "$").hasError);
}

// ── the specification's own examples (`O4`) ────────────────────────────────

version (unittest)
{
    /// Examples that are not standalone valid documents, each with the reason.
    /// The edition labels them `json` but writes them as illustrations.
    private immutable string[2][] invalidExamples = [
        ["aliases-04.tokens", "comments, and a deliberate alias cycle"],
        ["aliases-05.tokens", "comments inside the JSON"],
        ["aliases-08.tokens", "illustrates JSON Pointer ambiguity; not a token document"],
        ["composite-types-01.tokens", "aliases {base.shadow}, defined in another example"],
        ["composite-types-07.tokens", "aliases {color.focusring}, defined in another example"],
        ["composite-types-09.tokens", "three token fragments, not one JSON value"],
        ["composite-types-12.tokens", "aliases {brand.secondary}, defined in another example"],
        ["composite-types-13.tokens", "aliases {font.serif}, defined in another example"],
        ["groups-03.tokens", "extends {button}, defined in another example"],
        ["groups-04.tokens", "points at #/button, defined in another example"],
        ["groups-05.tokens", "comments, and values that are not colors (#blue)"],
        ["groups-07.tokens", "tokens with no determinable $type (the edition's own rule)"],
        ["groups-08.tokens", "tokens with no determinable $type (the edition's own rule)"],
    ];

    private bool listedInvalid(string name) pure nothrow @nogc
    {
        foreach (ref e; invalidExamples)
            if (e[0] == name)
                return true;
        return false;
    }

    // Every token of `doc` resolves, and a color or dimension parses.
    private string checkExample(const DtcgJson doc)
    {
        auto toks = collectTokens(doc);
        if (toks.hasError)
            return toks.error.path ~ ": " ~ toks.error.message;
        foreach (ref t; toks.value.tokens)
        {
            auto v = toks.value.resolved(t.path);
            if (v.hasError)
                return v.error.path ~ ": " ~ v.error.message;
            if (t.type == "color")
                if (auto c = parseColor(v.value, t.jsonPath ~ ".$value"))
                    if (c.hasError)
                        return c.error.path ~ ": " ~ c.error.message;
            if (t.type == "dimension")
                if (auto d = parseDimension(v.value, t.jsonPath ~ ".$value"))
                    if (d.hasError)
                        return d.error.path ~ ": " ~ d.error.message;
        }
        return null;
    }
}

@("dtcg.specExamples.2025_10")
@safe unittest
{
    import std.algorithm.sorting : sort;
    import std.array : array;
    import std.file : dirEntries, readText, SpanMode;
    import std.path : baseName, buildPath, dirName;

    // The examples of the Design Tokens Format Module 2025.10, extracted from
    // design-tokens/community-group at the commit that published it; see the
    // directory's README.
    const dir = buildPath(__FILE_FULL_PATH__.dirName, "..", "..", "..", "test", "data", "dtcg-2025.10");
    string[] failures;
    size_t checked;
    foreach (f; () @trusted { return dirEntries(dir, "*.tokens", SpanMode.shallow).array; }().sort)
    {
        const name = f.name.baseName;
        auto parsed = parseDtcg(readText(f.name));
        string why = parsed.hasError ? parsed.error.path ~ ": " ~ parsed.error.message
            : checkExample(parsed.value);
        checked++;
        const expectedInvalid = listedInvalid(name);
        if ((why !is null) != expectedInvalid)
            failures ~= name ~ (why !is null ? " rejected: " ~ why : " accepted, but is listed invalid");
    }
    assert(checked == 48, "the example corpus is incomplete");
    assert(failures.length == 0, "\n" ~ failures.join("\n"));
}
