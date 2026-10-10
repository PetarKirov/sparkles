/**
The build document embedded in a packaged binary (`TPG2`).

Nix writes a strict JSON document into a format-specific section
(ELF `.build_info`, Mach-O `__DATA,__build_info`, PE `.bldinfo`). The
fixed fields decode into $(LREF BuildInfo). The open `components` object
stays a $(LREF JsonValue) view of the $(LREF JsonDocument) this load
keeps alive — wired has no second, copyable JSON tree, and this module
does not import `std.json`.

A `dub` build has no section. Callers treat that as unstamped: `version`
`dev`, `unknown commit`, no links, no components.
*/
module sparkles.core_cli.build_info;

import sparkles.wired.json.codec : fromJSON;
import sparkles.wired.json.document : JsonDocument, JsonKind, JsonValue;

alias OwnedDocument = JsonDocument!();
import sparkles.wired.json.error : JsonError, JsonStage, parseStageError;
import sparkles.wired.json.reader : parseJsonDocument;
import sparkles.wired.policy : WireName, WireOptional;

/**
Identity, links, and build type. `components` is not a field: it is the
open object in the document this was decoded from.
*/
struct BuildInfo
{
    /// Package name (`sparkles:terminal`). Empty when the document omitted it.
    @WireOptional() string name;

    /// Product version. A missing key, including the placeholder `{}`,
    /// stays `dev`. `@WireOptional` is what makes the omission legal —
    /// the initializer alone does not.
    @WireOptional() @WireName("version") string version_ = "dev";

    /// Short commit. Omitted when the build had no rev.
    @WireOptional() string commit;

    /// `true` when `commit` was taken from a dirty tree.
    @WireOptional() bool dirty;

    /// `debug`, `checked`, or `release`. Empty when the document omitted it.
    @WireOptional() string buildType;

    /// Named URLs (`source`, `docs`, `credits`). Absent is an empty map.
    @WireOptional() string[string] links;

    /**
    The commit as a reader should see it: `4f2c1aa`, `4f2c1aa + uncommitted
    changes`, or `unknown commit`. Same words as `BuildStamp.commitLabel`.
    */
    string commitLabel() const @safe pure nothrow
        => commit.length == 0 ? "unknown commit"
            : dirty ? commit ~ " + uncommitted changes"
            : commit;
}

/**
One parsed build document. Move-only, like $(LREF JsonParseResult):
`Expected` cannot carry the non-copyable document, and the component
views borrow it.
*/
struct BuildLoad
{
    /// Decoded fixed fields. Meaningful when $(LREF hasValue).
    BuildInfo info;

    /// The arena. Component views borrow it. Empty when parsing failed
    /// or the caller built an unstamped load with no document.
    OwnedDocument document;

    /// Meaningful when $(LREF hasError).
    JsonError error;

    private bool ok;

    /// The document decoded. An unstamped placeholder (`{}`, or
    /// $(LREF unstamped)) counts.
    bool hasValue() const @safe pure nothrow @nogc => ok;

    /// ditto
    bool hasError() const @safe pure nothrow @nogc => !ok;

    /// A load that shows the unstamped facts and has no component rows.
    static BuildLoad unstamped() @safe pure nothrow
    {
        BuildLoad load;
        load.info = BuildInfo.init;
        load.ok = true;
        return load;
    }

    /**
    The `components` object, or a `JsonKind.none` view when the document
    omitted it. The view borrows $(LREF document).
    */
    JsonValue components() const return scope @safe pure nothrow @nogc
    {
        if (!ok || !document.valid)
            return JsonValue.init;
        auto root = document.root;
        if (root.kind != JsonKind.object)
            return JsonValue.init;
        return root.objectGet("components");
    }

    /// Move-assignment. The document is not copyable.
    void opAssign(BuildLoad rhs)
    {
        import core.lifetime : move;

        info = rhs.info;
        document = move(rhs.document);
        error = rhs.error;
        ok = rhs.ok;
    }
}

/**
Parses `text` once and decodes $(LREF BuildInfo) from that document.
A present `components` member that is not a JSON object is an error.
An absent member yields no component rows.
*/
BuildLoad buildInfoFromJSON(scope const(char)[] text) @safe
{
    BuildLoad load;
    auto parsed = parseJsonDocument(text);
    if (parsed.hasError)
    {
        load.error = parseStageError(parsed.error, text);
        return load;
    }

    auto decoded = fromJSON!BuildInfo(parsed.document.root);
    if (decoded.hasError)
    {
        load.error = decoded.error;
        return load;
    }

    if (parsed.document.root.kind == JsonKind.object)
    {
        auto comps = parsed.document.root.objectGet("components");
        if (comps.kind != JsonKind.none && comps.kind != JsonKind.object)
        {
            JsonError err;
            err.stage = JsonStage.decode;
            err.reason = "components must be a JSON object";
            err.targetType = BuildInfo.stringof;
            err.actualKind = comps.kind;
            err.prependKey("components");
            load.error = err;
            return load;
        }
    }

    import core.lifetime : move;

    load.info = decoded.value;
    load.document = move(parsed.document);
    load.ok = true;
    return load;
}

/**
What `--version` prints. `section is null` is a missing section: the
unstamped document (`version` `dev`), exit 0. A section that decodes is
copied to stdout, exit 0. A section that does not decode is an error on
stderr, exit 1.
*/
struct VersionReport
{
    /// Bytes for stdout. Empty when $(LREF code) is not 0.
    string stdoutText;
    /// The decode error, when $(LREF code) is not 0.
    string stderrText;
    /// 0 when the section is missing or valid. 1 when it does not decode.
    int code;
}

/// ditto
VersionReport versionReport(scope const(ubyte)[] section) @safe
{
    import sparkles.wired.json.codec : toJSON;

    if (section is null)
    {
        auto encoded = toJSON(BuildInfo.init);
        if (encoded.hasError)
            return VersionReport(null, encoded.error.toString(), 1);
        return VersionReport(withNewline(encoded.value[].idup), null, 0);
    }

    auto load = buildInfoFromJSON(cast(const(char)[]) section);
    if (!load.hasValue)
        return VersionReport(null, load.error.toString(), 1);
    char[] copied;
    copied.reserve(section.length);
    foreach (b; section)
        copied ~= cast(char) b;
    return VersionReport(withNewline(copied.idup), null, 0);
}

private string withNewline(string text) @safe pure nothrow
{
    if (text.length == 0 || text[$ - 1] != '\n')
        text ~= '\n';
    return text;
}

/**
The build-info section of an ELF, Mach-O, or PE image, or `null` when
the image has no such section. The slice aliases `image`.
*/
const(ubyte)[] buildInfoSectionOf(return scope const(ubyte)[] image)
    @safe pure nothrow @nogc
{
    if (image.length >= 4 && image[0] == 0x7F && image[1] == 'E'
        && image[2] == 'L' && image[3] == 'F')
        return elfSection(image);
    if (image.length >= 4)
    {
        uint magic;
        if (u32At(image, 0, true, magic))
        {
            if (magic == 0xFEED_FACF || magic == 0xFEED_FACE
                || magic == 0xCFFA_EDFE || magic == 0xCEFA_EDFE)
                return machoSection(image, magic);
            if (magic == 0xBEBA_FECA || magic == 0xCAFE_BABE)
                return fatSection(image, magic == 0xCAFE_BABE);
        }
    }
    if (image.length >= 0x40 && image[0] == 'M' && image[1] == 'Z')
        return peSection(image);
    return null;
}

/**
Reads `path` and returns a copy of its build-info section, or `null`
when the file is missing, unreadable, or has no such section.
*/
ubyte[] buildInfoSection(scope const(char)[] path) @safe
{
    import std.file : read;

    ubyte[] image;
    try
        image = () @trusted { return cast(ubyte[]) read(path); }();
    catch (Exception)
        return null;
    auto slice = buildInfoSectionOf(image);
    if (slice is null)
        return null;
    return slice.dup;
}

/**
One JSON value as a property-tree subject (`PRT3`–`PRT5`).

The page stores the $(LREF BuildLoad) and builds this as a local of each
`rebuild`. The cell pointer copied here stays valid while that document
is alive and unmoved. `PropertyTree` does not retain the subject.
*/
struct JsonSubject
{
    /// The value this row describes.
    JsonValue value;

    /// Copies `v`'s cell pointer. `v` must outlive every use of the copy,
    /// which holds while the owning document is alive and unmoved.
    this(return scope JsonValue v) @trusted pure nothrow @nogc
    {
        value = v;
    }

    /// Objects and arrays open. Scalars, `null`, and an empty view do not.
    bool propExpandable() const @safe pure nothrow @nogc
        => value.kind == JsonKind.object || value.kind == JsonKind.array;

    /// A leaf's text, or a container's size. A string's text is the string.
    string propText() const @safe pure
    {
        final switch (value.kind) with (JsonKind)
        {
        case none:
        case null_:
            return "null";
        case bool_:
            return value.boolean ? "true" : "false";
        case integer:
            return numberText(value.integer);
        case uinteger:
            return numberText(value.uinteger);
        case floating:
            return numberText(value.floating);
        case string_:
            return value.str.idup;
        case rawNumber:
            return value.raw.idup;
        case array:
            return braced(value.length, '[', ']');
        case object:
            return braced(value.length, '{', '}');
        }
    }

    /// Children of an object (keys sorted) or an array (source order).
    int opApply(scope int delegate(size_t, const(char)[], ref JsonSubject) @safe dg)
        @safe
    {
        static struct Item
        {
            const(char)[] key;
            JsonSubject child;
        }

        Item[] items;
        if (value.kind == JsonKind.object)
        {
            foreach (m; value.byKeyValue)
                items ~= Item(m.key, JsonSubject(m.value));
            sortItems(items);
        }
        else if (value.kind == JsonKind.array)
        {
            foreach (el; value.byElement)
                items ~= Item(null, JsonSubject(el));
        }
        foreach (i, ref item; items)
            if (auto r = dg(i, item.key, item.child))
                return r;
        return 0;
    }

    /// The property walk looks this up as a member (`PRT5`). A free
    /// function is invisible to `hasPropChildren` in `sparkles:ui`.
    @property auto propChildren() return @safe
    {
        static struct Range
        {
            JsonSubject* self;

            int opApply(scope int delegate(size_t, const(char)[], ref JsonSubject) @safe dg)
                @safe
                => self.opApply(dg);
        }

        return Range(() @trusted { return &this; }());
    }
}

private string numberText(T)(T v) @safe pure
{
    import std.conv : text;

    return text(v);
}

private string braced(size_t n, char open, char close) @safe pure
{
    import std.conv : text;

    return text(open, n, close == '}' ? " keys}" : "]");
}

private void sortItems(T)(T[] items) @safe pure
{
    foreach (i; 1 .. items.length)
    {
        auto key = items[i];
        size_t j = i;
        while (j > 0 && items[j - 1].key > key.key)
        {
            items[j] = items[j - 1];
            j--;
        }
        items[j] = key;
    }
}

// ── image sections ──────────────────────────────────────────────────────────

private bool u16At(scope const(ubyte)[] b, size_t off, bool le, out ushort v)
    @safe pure nothrow @nogc
{
    if (off > b.length || b.length - off < 2)
        return false;
    v = le ? cast(ushort)(b[off] | (b[off + 1] << 8))
        : cast(ushort)((b[off] << 8) | b[off + 1]);
    return true;
}

private bool u32At(scope const(ubyte)[] b, size_t off, bool le, out uint v)
    @safe pure nothrow @nogc
{
    if (off > b.length || b.length - off < 4)
        return false;
    v = 0;
    foreach (i; 0 .. 4)
    {
        const shift = le ? i : 3 - i;
        v |= cast(uint) b[off + i] << (8 * shift);
    }
    return true;
}

private bool u64At(scope const(ubyte)[] b, size_t off, bool le, out ulong v)
    @safe pure nothrow @nogc
{
    if (off > b.length || b.length - off < 8)
        return false;
    v = 0;
    foreach (i; 0 .. 8)
    {
        const shift = le ? i : 7 - i;
        v |= cast(ulong) b[off + i] << (8 * shift);
    }
    return true;
}

private bool nameAt(scope const(ubyte)[] bytes, scope const(char)[] want)
    @safe pure nothrow @nogc
{
    if (bytes.length < want.length)
        return false;
    foreach (i, c; want)
        if (bytes[i] != cast(ubyte) c)
            return false;
    foreach (i; want.length .. bytes.length)
        if (bytes[i] != 0)
            return false;
    return true;
}

private const(ubyte)[] sliceAt(return scope const(ubyte)[] b, ulong off, ulong size)
    @safe pure nothrow @nogc
{
    if (off > b.length || size > b.length - off)
        return null;
    return b[cast(size_t) off .. cast(size_t)(off + size)];
}

private const(ubyte)[] elfSection(return scope const(ubyte)[] image)
    @safe pure nothrow @nogc
{
    if (image.length < 64 || image[4] < 1 || image[4] > 2 || image[5] < 1 || image[5] > 2)
        return null;
    const is64 = image[4] == 2;
    const le = image[5] == 1;
    const shoffAt = is64 ? 40 : 32;
    const shentAt = is64 ? 58 : 46;
    ulong shoff;
    ushort shentsize, shnum, shstrndx;
    if (is64)
    {
        if (!u64At(image, shoffAt, le, shoff))
            return null;
    }
    else
    {
        uint narrow;
        if (!u32At(image, shoffAt, le, narrow))
            return null;
        shoff = narrow;
    }
    if (!u16At(image, shentAt, le, shentsize) || !u16At(image, shentAt + 2, le, shnum)
        || !u16At(image, shentAt + 4, le, shstrndx))
        return null;
    if (shentsize < (is64 ? 64 : 40) || shnum == 0 || shstrndx >= shnum)
        return null;

    ulong strOff, strSize;
    if (!sectionLoc(image, shoff, shentsize, shstrndx, is64, le, strOff, strSize))
        return null;
    auto strtab = sliceAt(image, strOff, strSize);
    if (strtab is null)
        return null;

    foreach (i; 0 .. shnum)
    {
        ulong nameOff = shoff + cast(ulong) i * shentsize;
        uint nameIdx;
        if (!u32At(image, cast(size_t) nameOff, le, nameIdx))
            return null;
        if (nameIdx >= strtab.length)
            continue;
        auto name = cstr(strtab[nameIdx .. $]);
        if (name != ".build_info")
            continue;
        ulong off, size;
        if (!sectionLoc(image, shoff, shentsize, cast(ushort) i, is64, le, off, size))
            return null;
        return sliceAt(image, off, size);
    }
    return null;
}

private bool sectionLoc(scope const(ubyte)[] image, ulong shoff, ushort shentsize,
    ushort index, bool is64, bool le, out ulong off, out ulong size)
    @safe pure nothrow @nogc
{
    const base = shoff + cast(ulong) index * shentsize;
    if (is64)
        return u64At(image, cast(size_t)(base + 24), le, off)
            && u64At(image, cast(size_t)(base + 32), le, size);
    uint narrowOff, narrowSize;
    if (!u32At(image, cast(size_t)(base + 16), le, narrowOff)
        || !u32At(image, cast(size_t)(base + 20), le, narrowSize))
        return false;
    off = narrowOff;
    size = narrowSize;
    return true;
}

private const(char)[] cstr(return scope const(ubyte)[] bytes) @safe pure nothrow @nogc
{
    size_t n;
    while (n < bytes.length && bytes[n] != 0)
        n++;
    return cast(const(char)[]) bytes[0 .. n];
}

private const(ubyte)[] machoSection(return scope const(ubyte)[] image, uint magic)
    @safe pure nothrow @nogc
{
    const le = magic == 0xFEED_FACF || magic == 0xFEED_FACE;
    const is64 = magic == 0xFEED_FACF || magic == 0xCFFA_EDFE;
    const header = is64 ? 32 : 28;
    uint ncmds;
    if (!u32At(image, 16, le, ncmds))
        return null;
    size_t at = header;
    foreach (_; 0 .. ncmds)
    {
        uint cmd, cmdsize;
        if (!u32At(image, at, le, cmd) || !u32At(image, at + 4, le, cmdsize)
            || cmdsize < 8 || at + cmdsize > image.length)
            return null;
        const segment64 = cmd == 0x19;
        const segment32 = cmd == 0x1;
        if (segment64 || segment32)
        {
            auto hit = machoSegment(image, at, cmdsize, le, segment64);
            if (hit !is null)
                return hit;
        }
        at += cmdsize;
    }
    return null;
}

private const(ubyte)[] machoSegment(return scope const(ubyte)[] image, size_t at,
    uint cmdsize, bool le, bool is64) @safe pure nothrow @nogc
{
    // segname starts at +8. nsects is after the fixed segment header.
    const sectOff = is64 ? 72 : 56;
    const sectSize = is64 ? 80 : 68;
    if (cmdsize < sectOff + 8)
        return null;
    uint nsects;
    if (!u32At(image, at + (is64 ? 64 : 48), le, nsects))
        return null;
    size_t cursor = at + sectOff;
    foreach (_; 0 .. nsects)
    {
        if (cursor + sectSize > at + cmdsize || cursor + sectSize > image.length)
            return null;
        if (nameAt(image[cursor .. cursor + 16], "__build_info")
            && nameAt(image[cursor + 16 .. cursor + 32], "__DATA"))
        {
            ulong size;
            uint offset;
            if (is64)
            {
                if (!u64At(image, cursor + 40, le, size) || !u32At(image, cursor + 48, le, offset))
                    return null;
            }
            else
            {
                uint narrow;
                if (!u32At(image, cursor + 36, le, narrow) || !u32At(image, cursor + 40, le, offset))
                    return null;
                size = narrow;
            }
            return sliceAt(image, offset, size);
        }
        cursor += sectSize;
    }
    return null;
}

private const(ubyte)[] fatSection(return scope const(ubyte)[] image, bool beMagic)
    @safe pure nothrow @nogc
{
    // FAT_MAGIC is big-endian on disk; FAT_CIGAM is little-endian.
    const le = !beMagic;
    uint narch;
    if (!u32At(image, 4, le, narch))
        return null;
    foreach (i; 0 .. narch)
    {
        const base = 8 + i * 20;
        uint offset, size;
        if (!u32At(image, base + 8, le, offset) || !u32At(image, base + 12, le, size))
            return null;
        auto slice = sliceAt(image, offset, size);
        if (slice is null)
            return null;
        auto hit = buildInfoSectionOf(slice);
        if (hit !is null)
            return hit;
    }
    return null;
}

private const(ubyte)[] peSection(return scope const(ubyte)[] image)
    @safe pure nothrow @nogc
{
    uint lfanew;
    if (!u32At(image, 0x3C, true, lfanew))
        return null;
    if (cast(ulong) lfanew + 24 > image.length)
        return null;
    if (image[lfanew .. lfanew + 4] != ['P', 'E', 0, 0])
        return null;
    const coff = lfanew + 4;
    ushort nsec, optSize;
    if (!u16At(image, coff + 2, true, nsec) || !u16At(image, coff + 16, true, optSize))
        return null;
    ulong table = cast(ulong) coff + 20 + optSize;
    foreach (i; 0 .. nsec)
    {
        const at = table + cast(ulong) i * 40;
        if (at + 40 > image.length)
            return null;
        auto name = image[cast(size_t) at .. cast(size_t) at + 8];
        if (!nameAt(name, ".bldinfo"))
            continue;
        // VirtualSize is the content. SizeOfRawData is the file-aligned
        // span llvm-objcopy writes when the section is readable data, so
        // a non-zero VirtualSize is the JSON and the rest is padding.
        uint virtualSize, rawSize, offset;
        if (!u32At(image, cast(size_t)(at + 8), true, virtualSize)
            || !u32At(image, cast(size_t)(at + 16), true, rawSize)
            || !u32At(image, cast(size_t)(at + 20), true, offset))
            return null;
        const size = virtualSize != 0 ? virtualSize : rawSize;
        return sliceAt(image, offset, size);
    }
    return null;
}

@("build_info.versionReport.missingValidCorrupt")
@safe
unittest
{
    import std.algorithm.searching : canFind;

    auto missing = versionReport(null);
    assert(missing.code == 0);
    assert(missing.stderrText.length == 0);
    assert(missing.stdoutText.canFind(`"version":"dev"`));

    auto ok_ = versionReport(cast(const(ubyte)[]) `{"version":"9"}`);
    assert(ok_.code == 0);
    assert(ok_.stdoutText == "{\"version\":\"9\"}\n");

    auto bad = versionReport(cast(const(ubyte)[]) `{`);
    assert(bad.code == 1);
    assert(bad.stdoutText.length == 0);
    assert(bad.stderrText.length != 0);
}

@("build_info.commitLabel.words")
@safe pure nothrow
unittest
{
    BuildInfo none;
    assert(none.commitLabel == "unknown commit");

    BuildInfo clean;
    clean.commit = "4f2c1aa";
    assert(clean.commitLabel == "4f2c1aa");

    BuildInfo dirty;
    dirty.commit = "4f2c1aa";
    dirty.dirty = true;
    assert(dirty.commitLabel == "4f2c1aa + uncommitted changes");
}

@("build_info.fromJSON.placeholderAndOpenObject")
@safe
unittest
{
    auto blank = buildInfoFromJSON("{}");
    assert(blank.hasValue);
    assert(blank.info.version_ == "dev");
    assert(blank.info.name.length == 0);
    assert(blank.components.kind == JsonKind.none);

    auto extra = buildInfoFromJSON(`{"version":"1.2.3","nope":true}`);
    assert(extra.hasValue);
    assert(extra.info.version_ == "1.2.3");

    auto missing = buildInfoFromJSON(`{"name":"sparkles:terminal"}`);
    assert(missing.hasValue);
    assert(missing.components.kind == JsonKind.none);

    enum example = `{
        "name": "sparkles:terminal",
        "version": "0.1.0",
        "commit": "4f2c1aa",
        "dirty": false,
        "buildType": "checked",
        "links": {"source": "https://github.com/PetarKirov/sparkles"},
        "components": {
            "libghostty-vt": {"version": "0.1.0-dev+4749c4e", "storePath": "/nix/store/eeee", "note": "extra"},
            "sparkles:base": {"version": "in-tree"}
        }
    }`;
    auto load = buildInfoFromJSON(example);
    assert(load.hasValue);
    assert(load.info.name == "sparkles:terminal");
    assert(load.info.version_ == "0.1.0");
    assert(load.info.commitLabel == "4f2c1aa");
    assert(load.info.buildType == "checked");
    assert(load.info.links["source"] == "https://github.com/PetarKirov/sparkles");

    auto vt = load.components.objectGet("libghostty-vt");
    assert(vt.kind == JsonKind.object);
    assert(vt.objectGet("storePath").str == "/nix/store/eeee");
    assert(vt.objectGet("note").str == "extra");
    assert(load.components.objectGet("sparkles:base").objectGet("storePath").kind == JsonKind.none);

    auto bad = buildInfoFromJSON(`{"components":["nope"]}`);
    assert(bad.hasError);
    assert(!bad.hasValue);
}

@("build_info.section.elfMachOPe")
@safe pure nothrow
unittest
{
    auto elf = elf64("hello-json");
    auto got = buildInfoSectionOf(elf);
    assert(got == cast(const(ubyte)[]) "hello-json");

    assert(buildInfoSectionOf(elfWithout()) is null);

    auto macho = macho64("hello-json");
    assert(buildInfoSectionOf(macho) == cast(const(ubyte)[]) "hello-json");

    auto pe = pe64("hello-json");
    assert(buildInfoSectionOf(pe) == cast(const(ubyte)[]) "hello-json");

    // File-aligned raw size, exact content in VirtualSize.
    auto peAligned = pe64Aligned("hello-json");
    assert(buildInfoSectionOf(peAligned) == cast(const(ubyte)[]) "hello-json");

    assert(buildInfoSectionOf(cast(const(ubyte)[]) "not a binary") is null);
}

@("build_info.JsonSubject.sortedChildren")
@safe
unittest
{
    auto load = buildInfoFromJSON(`{"components":{"b":"x","a":{"z":"1","m":"0"}}}`);
    assert(load.hasValue);
    auto root = JsonSubject(load.components);
    assert(root.propExpandable);

    string[] names;
    foreach (i, name, ref child; root.propChildren)
    {
        names ~= name.idup;
        if (name == "b")
        {
            assert(!child.propExpandable);
            assert(child.propText == "x");
        }
        if (name == "a")
        {
            assert(child.propExpandable);
            string[] inner;
            foreach (j, iname, ref leaf; child.propChildren)
            {
                inner ~= iname.idup;
                assert(leaf.propText == (iname == "m" ? "0" : "1"));
            }
            assert(inner == ["m", "z"]);
        }
    }
    assert(names == ["a", "b"]);
}

private ubyte[] elf64(scope const(char)[] payload) @safe pure nothrow
{
    // 64-byte header, payload, shstrtab, 3 section headers.
    enum strtab = "\0.shstrtab\0.build_info\0";
    const payloadAt = 64;
    const strAt = payloadAt + payload.length;
    const shoff = strAt + strtab.length;
    ubyte[] b;
    b.length = shoff + 64 * 3;
    b[0 .. 4] = [0x7F, 'E', 'L', 'F'];
    b[4] = 2; // ELFCLASS64
    b[5] = 1; // ELFDATA2LSB
    b[6] = 1;
    put64(b, 40, shoff);
    put16(b, 58, 64); // shentsize
    put16(b, 60, 3); // shnum
    put16(b, 62, 1); // shstrndx
    if (payload.length)
        b[payloadAt .. payloadAt + payload.length] = cast(const(ubyte)[]) payload;
    b[strAt .. strAt + strtab.length] = cast(const(ubyte)[]) strtab;

    // [1] .shstrtab
    put32(b, shoff + 64 + 0, 1); // name
    put32(b, shoff + 64 + 4, 3); // SHT_STRTAB
    put64(b, shoff + 64 + 24, strAt);
    put64(b, shoff + 64 + 32, strtab.length);
    // [2] .build_info
    put32(b, shoff + 128 + 0, 11); // ".build_info"
    put32(b, shoff + 128 + 4, 1); // SHT_PROGBITS
    put64(b, shoff + 128 + 24, payloadAt);
    put64(b, shoff + 128 + 32, payload.length);
    return b;
}

private ubyte[] elfWithout() @safe pure nothrow
{
    enum strtab = "\0.shstrtab\0";
    const strAt = 64;
    const shoff = strAt + strtab.length;
    ubyte[] b;
    b.length = shoff + 64 * 2;
    b[0 .. 4] = [0x7F, 'E', 'L', 'F'];
    b[4] = 2;
    b[5] = 1;
    b[6] = 1;
    put64(b, 40, shoff);
    put16(b, 58, 64);
    put16(b, 60, 2);
    put16(b, 62, 1);
    b[strAt .. strAt + strtab.length] = cast(const(ubyte)[]) strtab;
    put32(b, shoff + 64, 1);
    put32(b, shoff + 64 + 4, 3);
    put64(b, shoff + 64 + 24, strAt);
    put64(b, shoff + 64 + 32, strtab.length);
    return b;
}

private ubyte[] macho64(scope const(char)[] payload) @safe pure nothrow
{
    // header 32 + segment_command_64 72 + section_64 80, then payload.
    const header = 32 + 72 + 80;
    ubyte[] b;
    b.length = header + payload.length;
    put32(b, 0, 0xFEED_FACF);
    put32(b, 4, 0x0100_0007); // CPU_TYPE_X86_64
    put32(b, 12, 2); // MH_EXECUTE
    put32(b, 16, 1); // ncmds
    put32(b, 20, 72 + 80);
    put32(b, 32, 0x19); // LC_SEGMENT_64
    put32(b, 36, 72 + 80);
    putName(b, 40, "__DATA");
    put64(b, 32 + 48, payload.length); // filesize at header+40+8?
    // segment_command_64: cmd 0, cmdsize 4, segname 8, vmaddr 24, vmsize 32,
    // fileoff 40, filesize 48, maxprot 56, initprot 60, nsects 64, flags 68.
    // `at` of the command is 32.
    put64(b, 32 + 48, payload.length);
    put32(b, 32 + 64, 1); // nsects
    const sec = 32 + 72;
    putName(b, sec, "__build_info");
    putName(b, sec + 16, "__DATA");
    put64(b, sec + 40, payload.length); // size
    put32(b, sec + 48, header); // offset
    if (payload.length)
        b[header .. header + payload.length] = cast(const(ubyte)[]) payload;
    return b;
}

private ubyte[] pe64(scope const(char)[] payload) @safe pure nothrow
{
    ubyte[] b;
    b.length = 0xC0 + payload.length;
    b[0] = 'M';
    b[1] = 'Z';
    put32(b, 0x3C, 0x80);
    b[0x80 .. 0x84] = ['P', 'E', 0, 0];
    put16(b, 0x84 + 2, 1); // NumberOfSections
    put16(b, 0x84 + 16, 0); // SizeOfOptionalHeader
    // section table at 0x84 + 20 = 0x98
    putName8(b, 0x98, ".bldinfo");
    put32(b, 0x98 + 16, cast(uint) payload.length);
    put32(b, 0x98 + 20, 0xC0);
    if (payload.length)
        b[0xC0 .. 0xC0 + payload.length] = cast(const(ubyte)[]) payload;
    return b;
}

/// Same image, with VirtualSize naming the content and SizeOfRawData
/// counting four bytes of padding after it.
private ubyte[] pe64Aligned(scope const(char)[] payload) @safe pure nothrow
{
    auto b = pe64(payload);
    put32(b, 0x98 + 8, cast(uint) payload.length);
    put32(b, 0x98 + 16, cast(uint) payload.length + 4);
    b ~= [0, 0, 0, 0];
    return b;
}

private void put16(ubyte[] b, size_t off, ushort v) @safe pure nothrow @nogc
{
    b[off] = cast(ubyte) v;
    b[off + 1] = cast(ubyte)(v >> 8);
}

private void put32(ubyte[] b, size_t off, uint v) @safe pure nothrow @nogc
{
    foreach (i; 0 .. 4)
        b[off + i] = cast(ubyte)(v >> (8 * i));
}

private void put64(ubyte[] b, size_t off, ulong v) @safe pure nothrow @nogc
{
    foreach (i; 0 .. 8)
        b[off + i] = cast(ubyte)(v >> (8 * i));
}

private void putName(ubyte[] b, size_t off, scope const(char)[] name) @safe pure nothrow @nogc
{
    b[off .. off + 16] = 0;
    b[off .. off + name.length] = cast(const(ubyte)[]) name;
}

private void putName8(ubyte[] b, size_t off, scope const(char)[] name) @safe pure nothrow @nogc
{
    b[off .. off + 8] = 0;
    b[off .. off + name.length] = cast(const(ubyte)[]) name;
}
