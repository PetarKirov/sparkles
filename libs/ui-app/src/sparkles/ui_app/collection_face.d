/**
A family's faces inside OpenType collections, for the native arm.

macOS ships Menlo and Courier only as `.ttc` collections. The raylib arm's
loader reads a collection's header as a font, so the CoreText resolver leaves
collections out, and `--font Menlo` found nothing. `sparkles:font` opens a
collection's members by index, so the native arm asks CoreText for them too
(`familyFaces(family, collections: true)`) and finds each member's index by
its PostScript name, the one thing CoreText reports that tells members apart.
*/
module sparkles.ui_app.collection_face;

import sparkles.font : name, openCollection;

/// A face: its file, and its index in that file.
struct FaceAt
{
    string path; ///
    uint index;  ///
}

/// The member of the collection in `bytes` whose PostScript name (`name` ID 6)
/// is `postScriptName`, or `uint.max`. A single font is a collection of one.
uint memberNamed(scope const(ubyte)[] bytes, scope const(char)[] postScriptName) @safe nothrow @nogc
{
    if (!postScriptName.length)
        return uint.max;
    auto collection = openCollection(bytes);
    if (collection.hasError)
        return uint.max;
    char[256] text;
    foreach (i; 0 .. collection.value.count)
    {
        auto face = collection.value.face(i);
        if (face.hasError)
            continue;
        auto table = name(face.value);
        if (table.hasError)
            continue;
        foreach (record; table.value.records)
        {
            if (record.hasError || record.value.nameID != 6)
                continue;
            auto decoded = record.value.decode(text[]);
            if (decoded.hasValue && decoded.value == postScriptName)
                return i;
        }
    }
    return uint.max;
}

@("ui_app.collection_face.memberNamedFindsEachMember")
@system unittest
{
    import std.file : read;
    import std.path : buildPath;
    import std.process : environment;

    const root = environment.get("SPARKLES_FONTS_PATH");
    assert(root.length, "SPARKLES_FONTS_PATH is required");

    // The bundled CJK collection: every member is found by its own name.
    const bytes = cast(const(ubyte)[]) read(buildPath(root, "NotoSansCJK-VF.otf.ttc"));
    auto collection = openCollection(bytes).value;
    assert(collection.count > 1);
    char[256] text;
    foreach (i; 0 .. collection.count)
    {
        auto table = name(collection.face(i).value).value;
        foreach (record; table.records)
            if (record.hasValue && record.value.nameID == 6)
            {
                const ps = record.value.decode(text[]).value.idup;
                assert(memberNamed(bytes, ps) == i, ps);
                break;
            }
    }
    assert(memberNamed(bytes, "NoSuchFace-Regular") == uint.max);
    assert(memberNamed(bytes, "") == uint.max);
    // A single font is a collection of one.
    const single = cast(const(ubyte)[]) read(buildPath(root, "DejaVuSansMono.ttf"));
    assert(memberNamed(single, "DejaVuSansMono") == 0);
}

// The CoreText resolver is `sparkles:raylib-text`'s, linked into the GUI
// configurations only.
version (OSX) version (UiAppGuiVulkan)
{
    /**
    The first family of `nameOrList` (a family or a comma-separated list;
    generic names are skipped, as they resolve without collections) that
    CoreText finds in a collection: its regular, bold, italic and bold-italic
    members, by `FaceStyle` order, a style the family lacks left empty. `load`
    maps a file's bytes. False when no family has a regular member in one.
    */
    bool collectionFamily(const(char)[] nameOrList,
        scope const(ubyte)[] delegate(string) @system load, out FaceAt[4] styles) @system
    {
        import sparkles.raylib_text.font_coretext : familyFaces, isCollectionFile, isGenericMonospace;

        import std.algorithm.iteration : splitter;

        foreach (raw; nameOrList.splitter(','))
        {
            const field = stripSpaces(raw);
            if (!field.length || isGenericMonospace(field))
                continue;
            styles = typeof(styles).init;
            foreach (f; familyFaces(field.idup, collections: true))
            {
                const slot = (f.bold ? 1 : 0) + (f.italic ? 2 : 0);
                if (styles[slot].path.length || !isCollectionFile(f.path))
                    continue;
                const index = memberNamed(load(f.path), f.postScriptName);
                if (index != uint.max)
                    styles[slot] = FaceAt(f.path, index);
            }
            if (styles[0].path.length)
                return true;
        }
        styles = typeof(styles).init;
        return false;
    }
}

/// `s` without leading or trailing spaces and tabs.
private inout(char)[] stripSpaces(return scope inout(char)[] s) @safe pure nothrow @nogc
{
    while (s.length && (s[0] == ' ' || s[0] == '\t'))
        s = s[1 .. $];
    while (s.length && (s[$ - 1] == ' ' || s[$ - 1] == '\t'))
        s = s[0 .. $ - 1];
    return s;
}

@("ui_app.collection_face.stripSpaces")
@safe pure nothrow @nogc unittest
{
    assert(stripSpaces(" Courier \t") == "Courier");
    assert(stripSpaces("  ") == "");
}
