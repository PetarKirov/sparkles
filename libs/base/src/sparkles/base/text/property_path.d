/** Syntax-only runtime property addresses shared by tree and configuration consumers.
    Names are ASCII identifiers or quoted UTF-8 byte strings; numeric segments
    distinguish positional indices from stable element identities. */
module sparkles.base.text.property_path;

import std.array : appender, Appender;
import std.range.primitives : put;
import sparkles.base.text.writers : writeInteger;

/// One owned parsed segment. Quoting is retained for canonical map addresses.
struct PathSeg
{
    string name;   /// Member / child / map-key name.
    size_t index;  /// Positional element.
    ulong key;     /// Stable element identity (`[#key]`).
    bool isIndex;
    bool isKey;
    bool isQuoted; /// A quoted name, including identifier-shaped map keys.
}

/** Parse an empty root or a sequence of names, `[index]`, `[#key]`, and
    `["name"]` segments. Bare names are ASCII identifiers; only quote and
    backslash may be escaped in quoted names. Numeric overflow and malformed
    continuations are rejected. On failure `segs` is empty, never a prefix.
    Returned names own their text independently of the input. */
bool parsePath(scope const(char)[] path, out PathSeg[] segs)
    @safe pure nothrow
{
    segs = null;
    size_t count;
    // Validate before allocating; malformed input cannot publish a prefix.
    if (!scanPath(path, null, count))
        return false;
    if (count == 0)
        return true;
    auto result = new PathSeg[count];
    size_t filled;
    const valid = scanPath(path, result, filled);
    assert(valid && filled == count);
    segs = result;
    return true;
}

private bool nameStart(char c) @safe pure nothrow @nogc
    => c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');

private bool nameChar(char c) @safe pure nothrow @nogc
    => nameStart(c) || (c >= '0' && c <= '9');

private bool bareName(scope const(char)[] name) @safe pure nothrow @nogc
{
    if (name.length == 0 || !nameStart(name[0]))
        return false;
    foreach (c; name[1 .. $])
        if (!nameChar(c))
            return false;
    return true;
}

private bool readNumber(T)(scope const(char)[] path, ref size_t i, out T value)
{
    value = 0;
    const start = i;
    while (i < path.length && path[i] >= '0' && path[i] <= '9')
    {
        const digit = cast(T)(path[i] - '0');
        if (value > (T.max - digit) / 10)
            return false;
        value = value * 10 + digit;
        ++i;
    }
    return i > start && i < path.length && path[i++] == ']';
}

// Both passes share validation. With no output the walk allocates nothing.
private bool scanPath(scope const(char)[] path, PathSeg[] output, out size_t count)
    @safe pure nothrow
{
    count = 0;
    size_t i;
    while (i < path.length)
    {
        if (count && path[i] == '.')
        {
            ++i;
            if (i == path.length || !nameStart(path[i]))
                return false;
        }
        else if (count && path[i] != '[')
            return false;

        PathSeg segment;
        if (path[i] != '[')
        {
            if (!nameStart(path[i]))
                return false;
            const start = i++;
            while (i < path.length && nameChar(path[i]))
                ++i;
            if (output.length)
                segment.name = path[start .. i].idup;
        }
        else
        {
            if (++i == path.length)
                return false;
            if (path[i] == '"')
            {
                segment.isQuoted = true;
                const start = ++i;
                size_t decodedLength;
                bool escaped;
                while (i < path.length && path[i] != '"')
                {
                    if (path[i] == '\\')
                    {
                        escaped = true;
                        if (++i == path.length || (path[i] != '"' && path[i] != '\\'))
                            return false;
                    }
                    ++decodedLength;
                    ++i;
                }
                const end = i;
                if (i == path.length || ++i == path.length || path[i++] != ']')
                    return false;
                if (output.length)
                {
                    if (!escaped)
                        segment.name = path[start .. end].idup;
                    else
                    {
                        auto name = appender!string;
                        name.reserve(decodedLength);
                        for (size_t j = start; j < end; ++j)
                        {
                            if (path[j] == '\\')
                                ++j;
                            put(name, path[j]);
                        }
                        segment.name = name.data;
                    }
                }
            }
            else if (path[i] == '#')
            {
                ++i;
                segment.isKey = true;
                if (!readNumber(path, i, segment.key))
                    return false;
            }
            else
            {
                segment.isIndex = true;
                if (!readNumber(path, i, segment.index))
                    return false;
            }
        }
        if (output.length)
            output[count] = segment;
        ++count;
    }
    return true;
}

private void writeQuoted(Writer)(ref Writer w, scope const(char)[] name)
{
    put(w, `["`);
    foreach (c; name)
    {
        if (c == '"' || c == '\\')
            put(w, '\\');
        put(w, c);
    }
    put(w, `"]`);
}

private void writeChild(Writer)(ref Writer w, bool hasParent,
    scope const(char)[] name, bool quoted = false)
{
    if (!quoted && bareName(name))
    {
        if (hasParent)
            put(w, '.');
        put(w, name);
    }
    else
        writeQuoted(w, name);
}

private size_t quotedSize(scope const(char)[] name) @safe pure nothrow @nogc
{
    size_t size = name.length + 4;
    foreach (c; name)
        if (c == '"' || c == '\\')
            ++size;
    return size;
}

private Appender!string pathWriter(scope const(char)[] parent, size_t suffixSize)
    @safe pure nothrow
{
    auto w = appender!string;
    w.reserve(parent.length + suffixSize);
    put(w, parent);
    return w;
}

/// Append a member/child name, quoting only outside the identifier subset.
string childPath(scope const(char)[] parent, scope const(char)[] member)
    @safe pure nothrow
{
    auto w = pathWriter(parent, bareName(member)
        ? member.length + (parent.length != 0) : quotedSize(member));
    writeChild(w, parent.length != 0, member);
    return w.data;
}

/// Append a map key. Always quoted, even when identifier-shaped.
string keyPath(scope const(char)[] parent, scope const(char)[] key)
    @safe pure nothrow
{
    auto w = pathWriter(parent, quotedSize(key));
    writeQuoted(w, key);
    return w.data;
}

/// Append a positional element.
string elementPath(scope const(char)[] parent, size_t index) @safe pure nothrow
{
    auto w = pathWriter(parent, 22); // brackets plus at most 20 decimal digits
    put(w, '[');
    writeInteger(w, index);
    put(w, ']');
    return w.data;
}

/// Append a stable-identity element (not a map key).
string keyedPath(scope const(char)[] parent, ulong key) @safe pure nothrow
{
    auto w = pathWriter(parent, 23); // stable-key marker plus ulong's 20 digits
    put(w, "[#");
    writeInteger(w, key);
    put(w, ']');
    return w.data;
}

private void appendSeg(Writer)(ref Writer w, bool hasParent, in PathSeg s)
{
    if (s.isKey || s.isIndex)
    {
        put(w, s.isKey ? "[#" : "[");
        if (s.isKey)
            writeInteger(w, s.key);
        else
            writeInteger(w, s.index);
        put(w, ']');
    }
    else
        writeChild(w, hasParent, s.name, s.isQuoted);
}

/// Canonical parent address; a root segment or malformed input answers `""`.
/// Quoted names remain quoted so map keys cannot turn into member addresses.
string parentPath(scope const(char)[] path) @safe pure nothrow
{
    PathSeg[] segs;
    if (!parsePath(path, segs) || segs.length < 2)
        return "";
    auto w = appender!string;
    w.reserve(path.length);
    foreach (i, ref const s; segs[0 .. $ - 1])
        appendSeg(w, i != 0, s);
    return w.data;
}

/// Runtime addresses retain segment kinds and canonical parent addresses.
@("property_path.grammarAndParents")
@safe pure nothrow unittest
{
    PathSeg[] segs;
    assert(parsePath("", segs) && segs.length == 0);
    assert(parsePath("style.opacity", segs) && segs[1].name == "opacity");
    assert(parsePath("stops[2]", segs) && segs[1].isIndex && segs[1].index == 2);
    assert(parsePath("items[#7]", segs) && segs[1].isKey && segs[1].key == 7);
    assert(parsePath(`["weird.key [0]"]`, segs) && segs[0].name == "weird.key [0]");
    assert(parentPath("a.b[2].c") == "a.b[2]");
    assert(parentPath(`a["member"].child`) == `a["member"]`);
    assert(parentPath("a[0002].child") == "a[2]");
    assert(parentPath("a") == "");
    assert(parentPath("a.b[invalid]") == "");
}

/// Arbitrary child names round-trip; quoted map keys stay quoted.
@("property_path.namesRoundTripAndMapKeys")
@safe pure nothrow unittest
{
    foreach (name; ["", "member", "_x9", "9x", "a.b", "a[b]", "любой", `say "hi"`, `a\b`, "line\nbreak"])
    {
        PathSeg[] child, key;
        const memberPath = childPath("root", name);
        const mapPath = keyPath("root", name);
        assert(parsePath(memberPath, child) && child[1].name == name);
        assert(parsePath(mapPath, key) && key[1].name == name && key[1].isQuoted);
        assert(parentPath(childPath(mapPath, "leaf")) == mapPath);
    }
    assert(childPath("fill", "tint") == "fill.tint");
    assert(keyPath("fill", "tint") == `fill["tint"]`);
    assert(keyPath("", "tint") == `["tint"]`);
}

/// Index and identity widths are checked without truncation or wraparound.
@("property_path.numericBoundaries")
@safe pure nothrow unittest
{
    PathSeg[] segs;
    const largestIndex = elementPath("items", size_t.max);
    const largestKey = keyedPath("items", ulong.max);
    assert(parsePath(largestIndex, segs) && segs[1].index == size_t.max);
    assert(parsePath(largestKey, segs) && segs[1].key == ulong.max);
    assert(parsePath("[0][#0]", segs) && segs[0].index == 0 && segs[1].key == 0);
    assert(!parsePath("items[#18446744073709551616]", segs) && segs.length == 0);
    static if (size_t.sizeof == 8)
        assert(!parsePath("items[18446744073709551616]", segs) && segs.length == 0);
    else
        assert(!parsePath("items[4294967296]", segs) && segs.length == 0);
}

/// Invalid syntax discards every previously parsed segment.
@("property_path.malformedNeverReturnsPrefix")
@safe pure nothrow unittest
{
    foreach (path; [".a", "a.", "a..b", "a.[0]", "a[", "a[x]", "a[#]",
        "a[-1]", "a[+1]", "a[#-1]", "a[0]junk", "a[0]0", "a]", "9a", "a b",
        `a["unterminated`, `a["x"]junk`, `a["x"x]`, `a["\q"]`, `a["\n"]`, `a["x\`])
    {
        PathSeg[] segs;
        assert(parsePath("valid.prefix", segs));
        assert(!parsePath(path, segs), path);
        assert(segs.length == 0, path);
    }
}

/// Parsed names remain valid when the caller changes its input buffer.
@("property_path.parsedNamesOwnInput")
@safe pure nothrow unittest
{
    auto input = `member["escaped\"key"]`.dup;
    PathSeg[] segs;
    assert(parsePath(input, segs));
    input[] = 'x';
    assert(segs[0].name == "member");
    assert(segs[1].name == `escaped"key`);
}
