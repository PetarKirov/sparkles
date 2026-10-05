/** Finite scalar configuration admission, ownership, and resolution. */
module sparkles.wired.config.core;

import core.stdc.stdlib : malloc, free;
import core.stdc.string : memcpy;
import core.atomic : atomicLoad, cas;
import core.memory : GC;
import std.algorithm.mutation : move;
import std.algorithm.sorting : sort;
import std.traits : FieldNameTuple, Unqual, OriginalType, hasUDA, TemplateOf,
    TemplateArgsOf;
import std.typecons : Nullable;
import sparkles.wired.overlay : WireSection;

struct Atomic {}
struct Submodule {}
struct ConfigMerge(Policy) { alias policy = Policy; }
struct ConfigCheck(alias predicate_) { alias predicate = predicate_; }

struct ValidationResult
{
    bool accepted = true;
    string code;
    string detail;
    static ValidationResult accept() @safe pure nothrow @nogc => ValidationResult.init;
    static ValidationResult reject(string code, string detail = null) @safe pure nothrow @nogc
        => ValidationResult(false, code, detail);
}

enum ConfigSourceKind : ubyte
{
    builtinDefault, systemFile, userFile, projectFile, environment, commandLine, custom
}
enum ConfigErrorKind : ubyte
{
    none, invalidState, invalidLimits, invalidMetadata, invalidValue, unknownSource,
    wrongOwner, unknownOption, invalidHandle, duplicateSource, duplicateDefinition,
    limitExceeded, arithmeticOverflow, allocationFailed, notFullyResolved
}
enum OptionStatus : ubyte { resolved, conflict, invalidSelectedValue }
enum DefinitionDisposition : ubyte { overridden, contributing, conflicting, invalid }

struct SourceId
{
    immutable(ubyte)[] bytes;
    this(string text) @safe pure nothrow @nogc { bytes = immutableBytes(text); }
    this(immutable(ubyte)[] bytes) @safe pure nothrow @nogc { this.bytes = bytes; }
}
struct LocalId
{
    immutable(ubyte)[] bytes;
    this(string text) @safe pure nothrow @nogc { bytes = immutableBytes(text); }
    this(immutable(ubyte)[] bytes) @safe pure nothrow @nogc { this.bytes = bytes; }
}
struct SourceRef
{
    private ulong owner;
    private uint index;
    bool opEquals(SourceRef other) scope const @safe pure nothrow @nogc
        => owner == other.owner && index == other.index;
}
struct DefinitionRef
{
    private ulong owner;
    private uint index;
    bool opEquals(DefinitionRef other) scope const @safe pure nothrow @nogc
        => owner == other.owner && index == other.index;
}
struct SourceLocation
{
    ulong byteOffset;
    uint line;
    uint column;
}
struct ConfigLimits
{
    uint maxSources = 1024;
    uint maxDefinitions = 65_536;
    ulong maxPayloadBytes = 16_777_216;
    uint maxOptions = 4096;
    uint maxDepth = 32;
}
struct ConfigUsage
{
    ulong sources;
    ulong definitions;
    ulong payloadBytes;
    ulong options;
    ulong depth;
}
struct ConfigError
{
    ConfigErrorKind kind;
    string path;
    string limit;
    ulong used;
    ulong requested;
    /// Borrowed from the snapshot; valid only while that snapshot remains alive.
    const(string)[] failedOptions;
}

/** Explicit operation result; ownership is extracted, never implicitly copied. */
struct ConfigResult(V)
{
    @disable this(this);
    private bool present;
    private V payload;
    private ConfigError failure;
    @property bool hasValue() scope const @safe pure nothrow @nogc => present;
    @property bool hasError() scope const @safe pure nothrow @nogc => !present;
    @property ConfigError error() return scope const @safe pure nothrow @nogc => failure;
    @property auto value()() return scope const
    if (__traits(isCopyable, V))
    {
        assert(present);
        return payload;
    }
    V takeValue() @safe
    {
        assert(present);
        present = false;
        return move(payload);
    }
}
package ConfigResult!V successResult(V)(ref V value)
{
    ConfigResult!V result;
    result.payload = move(value);
    result.present = true;
    return result;
}
package ConfigResult!V errorResult(V)(return scope ConfigError error)
{
    ConfigResult!V result;
    result.failure = error;
    return result;
}
private ConfigError fail(ConfigErrorKind kind, string path = null) @safe pure nothrow @nogc
    => ConfigError(kind, path);

package alias ConfigFieldNames(T) = FieldNameTuple!T;
package alias ConfigFieldType(T, string name) = Unqual!(typeof(__traits(getMember, T.init, name)));

private template isAttribute(alias attribute, alias Family)
{
    static if (__traits(compiles, TemplateOf!(typeof(attribute))))
        enum isAttribute = __traits(isSame, TemplateOf!(typeof(attribute)), Family);
    else static if (__traits(compiles, TemplateOf!attribute))
        enum isAttribute = __traits(isSame, TemplateOf!attribute, Family);
    else
        enum isAttribute = false;
}
private template MergePolicy(T, string name)
{
    enum count = () {
        uint n;
        static foreach (a; __traits(getAttributes, __traits(getMember, T, name)))
            static if (isAttribute!(a, ConfigMerge)) ++n;
        return n;
    }();
    static assert(count <= 1, T.stringof ~ "." ~ name ~ ": duplicate ConfigMerge");
    static if (count == 0) alias MergePolicy = void;
    else static foreach (a; __traits(getAttributes, __traits(getMember, T, name)))
        static if (isAttribute!(a, ConfigMerge)) alias MergePolicy = typeof(a).policy;
}
package template ConfigIsSection(T, string name)
{
    alias V = ConfigFieldType!(T, name);
    alias P = MergePolicy!(T, name);
    enum marked = is(V == struct) && hasUDA!(V, WireSection);
    static assert(is(P == void) || is(P == Atomic) || is(P == Submodule),
        T.stringof ~ "." ~ name ~ ": unsupported merge policy");
    static assert(!(marked && is(P == Atomic)),
        T.stringof ~ "." ~ name ~ ": Atomic conflicts with WireSection");
    static assert(!is(P == Submodule) || is(V == struct),
        T.stringof ~ "." ~ name ~ ": Submodule requires a section struct");
    enum ConfigIsSection = marked || is(P == Submodule);
}
private template supportedScalar(V)
{
    static if (is(V == Nullable!N, N))
        enum supportedScalar = !is(N == Nullable!X, X) && supportedScalar!N;
    else static if (is(V == enum))
        enum supportedScalar = supportedInteger!(OriginalType!V);
    else
        enum supportedScalar = supportedInteger!V || is(V == bool)
            || is(V == float) || is(V == double) || is(V == string);
}
private enum supportedInteger(V) = is(V == byte) || is(V == ubyte)
    || is(V == short) || is(V == ushort) || is(V == int) || is(V == uint)
    || is(V == long) || is(V == ulong);
private template CheckPolicy(T, string name)
{
    enum count = () {
        uint n;
        static foreach (a; __traits(getAttributes, __traits(getMember, T, name)))
            static if (isAttribute!(a, ConfigCheck)) ++n;
        return n;
    }();
    static assert(count <= 1, T.stringof ~ "." ~ name ~ ": duplicate ConfigCheck");
    static if (count == 0) alias CheckPolicy = void;
    else static foreach (a; __traits(getAttributes, __traits(getMember, T, name)))
        static if (isAttribute!(a, ConfigCheck)) alias CheckPolicy = typeof(a).predicate;
}
private ValidationResult callCheck(alias predicate, V)(in V value) @safe pure nothrow
{
    return predicate(value);
}
private template validateSchema(T, string prefix = "", Ancestors...)
{
    static assert(is(T == struct), T.stringof ~ ": configuration root/section must be struct");
    static foreach (A; Ancestors)
        static assert(!is(T == A), T.stringof ~ ": cyclic configuration at " ~ prefix);
    static foreach (name; ConfigFieldNames!T)
    {
        static if (ConfigIsSection!(T, name))
        {
            static assert(is(CheckPolicy!(T, name) == void),
                T.stringof ~ "." ~ prefix ~ name ~ ": ConfigCheck requires scalar");
            static assert(validateSchema!(ConfigFieldType!(T, name), prefix ~ name ~ ".", Ancestors, T));
        }
        else
        {
            static assert(supportedScalar!(ConfigFieldType!(T, name)),
                T.stringof ~ "." ~ prefix ~ name ~ ": unsupported scalar configuration type "
                    ~ ConfigFieldType!(T, name).stringof);
            static if (!is(CheckPolicy!(T, name) == void))
                static assert(__traits(compiles,
                    callCheck!(CheckPolicy!(T, name), ConfigFieldType!(T, name))(
                        ConfigFieldType!(T, name).init)),
                    T.stringof ~ "." ~ prefix ~ name ~ ": check must be @safe pure nothrow and return ValidationResult");
        }
    }
    enum validateSchema = true;
}
private string[] makePaths(T)(string prefix = "")
{
    string[] result;
    static foreach (name; ConfigFieldNames!T)
    {
        static if (ConfigIsSection!(T, name))
            result ~= makePaths!(ConfigFieldType!(T, name))(prefix ~ name ~ ".");
        else result ~= prefix ~ name;
    }
    return result;
}
private uint schemaDepth(T)()
{
    uint depth;
    static foreach (name; ConfigFieldNames!T)
    {{
        static if (ConfigIsSection!(T, name))
        {
            auto child = 1 + schemaDepth!(ConfigFieldType!(T, name))();
            if (child > depth) depth = child;
        }
        else if (depth < 1) depth = 1;
    }}
    return depth;
}
package enum ConfigPaths(T) = makePaths!T();
package enum ConfigLeafCount(T) = ConfigPaths!T.length;
package enum ConfigDepth(T) = schemaDepth!T();
private string[] sortedPaths(T)()
{
    auto paths = makePaths!T();
    for (size_t i = 1; i < paths.length; ++i)
    {
        auto value = paths[i];
        size_t j = i;
        while (j && paths[j - 1] > value) { paths[j] = paths[j - 1]; --j; }
        paths[j] = value;
    }
    return paths;
}
private enum SortedPaths(T) = sortedPaths!T();
private size_t pathIndex(T, string path)()
{
    foreach (i, p; ConfigPaths!T) if (p == path) return i;
    assert(false);
}
private size_t dotPosition(string path) @safe pure nothrow @nogc
{
    foreach (i, c; path) if (c == '.') return i;
    return path.length;
}
private template LeafSite(T, string path)
{
    enum dot = dotPosition(path);
    static if (dot == path.length)
    {
        alias Parent = T;
        enum name = path;
        alias Value = ConfigFieldType!(T, path);
    }
    else
    {
        alias Next = LeafSite!(ConfigFieldType!(T, path[0 .. dot]), path[dot + 1 .. $]);
        alias Parent = Next.Parent;
        enum name = Next.name;
        alias Value = Next.Value;
    }
}
private string metadataPath(string path) @safe pure
{
    string result;
    foreach (c; path) result ~= c == '.' ? ".members." : [c];
    return result;
}

struct DefinitionSlot(V) { bool supplied; V value; }
struct LeafDefinitionMetadata
{
    Nullable!uint priority;
    Nullable!int order;
    Nullable!LocalId localId;
    Nullable!SourceLocation location;
}
struct SectionDefinitionMetadata(S)
{
    Nullable!uint priority;
    DefinitionMetadata!S members;
}
struct ConfigInput(T)
{
    static assert(validateSchema!T);
    static foreach (name; ConfigFieldNames!T)
        static if (ConfigIsSection!(T, name))
            mixin("ConfigInput!(ConfigFieldType!(T, \"" ~ name ~ "\")) " ~ name ~ ";");
        else
            mixin("DefinitionSlot!(ConfigFieldType!(T, \"" ~ name ~ "\")) " ~ name ~ ";");
}
struct DefinitionMetadata(T)
{
    static assert(validateSchema!T);
    static foreach (name; ConfigFieldNames!T)
        static if (ConfigIsSection!(T, name))
            mixin("SectionDefinitionMetadata!(ConfigFieldType!(T, \"" ~ name ~ "\")) " ~ name ~ ";");
        else mixin("LeafDefinitionMetadata " ~ name ~ ";");
}

/** Stateless native allocation seam. Templates infer attributes for adapters. */
package struct ConfigAllocator
{
    static void* allocate(size_t bytes) @trusted nothrow @nogc { return malloc(bytes); }
    static void deallocate(void* address) @trusted nothrow @nogc { free(address); }
    static void* allocateCopy(size_t bytes) @trusted
    {
        import core.exception : OutOfMemoryError;
        try { return GC.malloc(bytes, GC.BlkAttr.NO_SCAN); }
        catch (OutOfMemoryError) { return null; }
    }
    static void deallocateCopy(void* address) @trusted nothrow @nogc { GC.free(address); }
}
private struct Allocation { Allocation* next; }
private struct Arena(A)
{
    Allocation* first;
    Allocation* last;
    void* allocateBytes(size_t bytes, size_t alignment = 1)
    {
        enum offset = 16;
        if (alignment - 1 > size_t.max - offset) return null;
        auto overhead = offset + alignment - 1;
        if (bytes > size_t.max - overhead) return null;
        auto memory = A.allocate(bytes + overhead);
        if (memory is null) return null;
        auto block = allocationPointer(memory);
        block.next = null;
        if (last is null) first = block;
        else last.next = block;
        last = block;
        return alignedPayload(memory, offset, alignment);
    }
    X* allocate(X)()
    {
        auto raw = allocateBytes(X.sizeof, X.alignof);
        if (raw is null) return null;
        auto value = typedPointer!X(raw);
        *value = X.init;
        return value;
    }
    X[] array(X)(size_t count)
    {
        if (!count) return null;
        if (count > size_t.max / X.sizeof) return null;
        auto raw = allocateBytes(count * X.sizeof, X.alignof);
        if (raw is null) return null;
        auto values = typedSlice!X(raw, count);
        foreach (ref item; values) item = X.init;
        return values;
    }
    bool text(scope const(char)[] input, out string result)
    {
        if (input.ptr is null) { result = null; return true; }
        auto raw = allocateBytes(input.length ? input.length : 1);
        if (raw is null) return false;
        result = copyText(raw, input);
        return true;
    }
    bool bytes(scope const(ubyte)[] input, out immutable(ubyte)[] result)
    {
        string text;
        if (!this.text(byteText(input), text)) return false;
        result = immutableBytes(text);
        return true;
    }
    void absorb(ref Arena other)
    {
        if (other.first is null) return;
        if (last is null) first = other.first;
        else last.next = other.first;
        last = other.last;
        other.first = other.last = null;
    }
    void release()
    {
        auto block = first;
        first = last = null;
        while (block !is null)
        {
            auto next = block.next;
            A.deallocate(block);
            block = next;
        }
    }
}
private Allocation* allocationPointer(void* raw) @trusted nothrow @nogc
    => cast(Allocation*) raw;
private void* alignedPayload(void* raw, size_t offset, size_t alignment) @trusted nothrow @nogc
{
    auto address = cast(size_t) raw + offset;
    return cast(void*) ((address + alignment - 1) & ~(alignment - 1));
}
private X* typedPointer(X)(void* raw) @trusted nothrow @nogc => cast(X*) raw;
private X[] typedSlice(X)(void* raw, size_t length) @trusted nothrow @nogc
    => (cast(X*) raw)[0 .. length];
private string copyText(void* raw, scope const(char)[] input) @trusted nothrow @nogc
{
    if (input.length) memcpy(raw, input.ptr, input.length);
    return (cast(immutable(char)*) raw)[0 .. input.length];
}
private const(char)[] byteText(return scope const(ubyte)[] input) @trusted pure nothrow @nogc
    => cast(const(char)[]) input;
private immutable(ubyte)[] immutableBytes(string input) @trusted pure nothrow @nogc
    => cast(immutable(ubyte)[]) input;
private shared ulong nextOwner;
private ulong freshOwner() @safe nothrow @nogc
{
    for (;;)
    {
        auto seen = atomicLoad(nextOwner);
        if (seen == ulong.max) return 0;
        if (cas(&nextOwner, seen, seen + 1)) return seen + 1;
    }
}
private int compareBytes(scope const(ubyte)[] a, scope const(ubyte)[] b) @safe pure nothrow @nogc
{
    auto length = a.length < b.length ? a.length : b.length;
    foreach (i; 0 .. length)
        if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
    return a.length == b.length ? 0 : a.length < b.length ? -1 : 1;
}
private bool validIdentity(scope const(ubyte)[] bytes) @safe pure nothrow @nogc
    => bytes.length != 0 && bytes.length <= 1024;
private ConfigError validateLimits(ConfigLimits limits) @safe pure nothrow @nogc
{
    if (!limits.maxSources || !limits.maxDefinitions || !limits.maxPayloadBytes
        || !limits.maxOptions || !limits.maxDepth) return fail(ConfigErrorKind.invalidLimits);
    return ConfigError.init;
}
package ConfigError checkedCharge(ulong used, ulong added, ulong limit, string name)
    @safe pure nothrow @nogc
{
    if (added > ulong.max - used)
        return ConfigError(ConfigErrorKind.arithmeticOverflow, null, name, used, added);
    if (used > limit || added > limit - used)
        return ConfigError(ConfigErrorKind.limitExceeded, null, name, used, used + added);
    return ConfigError.init;
}

@("wired.config.core.checkedChargeBoundaries")
@safe unittest
{
    assert(checkedCharge(7, 1, 8, "bytes").kind == ConfigErrorKind.none);
    assert(checkedCharge(8, 0, 8, "bytes").kind == ConfigErrorKind.none);
    auto exceeded = checkedCharge(8, 1, 8, "bytes");
    assert(exceeded.kind == ConfigErrorKind.limitExceeded && exceeded.used == 8
        && exceeded.requested == 9 && exceeded.limit == "bytes");
    assert(checkedCharge(ulong.max - 1, 1, ulong.max, "bytes").kind == ConfigErrorKind.none);
    assert(checkedCharge(ulong.max - 1, 2, ulong.max, "bytes").kind == ConfigErrorKind.arithmeticOverflow);
    assert(checkedCharge(uint.max, 1, uint.max, "count").kind == ConfigErrorKind.limitExceeded);
}
private ConfigError checkUsage(ConfigUsage usage, ConfigLimits limits, bool retained = false)
    @safe pure nothrow @nogc
{
    auto error = validateLimits(limits);
    if (error.kind != ConfigErrorKind.none) return error;
    error = checkedCharge(retained ? usage.sources : 0, retained ? 0 : usage.sources,
        limits.maxSources, "maxSources");
    if (error.kind != ConfigErrorKind.none) return error;
    error = checkedCharge(retained ? usage.definitions : 0, retained ? 0 : usage.definitions,
        limits.maxDefinitions, "maxDefinitions");
    if (error.kind != ConfigErrorKind.none) return error;
    error = checkedCharge(retained ? usage.payloadBytes : 0, retained ? 0 : usage.payloadBytes,
        limits.maxPayloadBytes, "maxPayloadBytes");
    if (error.kind != ConfigErrorKind.none) return error;
    error = checkedCharge(retained ? usage.options : 0, retained ? 0 : usage.options,
        limits.maxOptions, "maxOptions");
    if (error.kind != ConfigErrorKind.none) return error;
    return checkedCharge(retained ? usage.depth : 0, retained ? 0 : usage.depth,
        limits.maxDepth, "maxDepth");
}
private bool addBytes(ref ulong used, ulong added) @safe pure nothrow @nogc
{
    if (added > ulong.max - used) return false;
    used += added;
    return true;
}
private ulong payloadCharge(V)(scope ref const V value)
{
    static if (is(V == Nullable!N, N))
        return value.isNull ? 1 : 1 + payloadCharge(value.get);
    else static if (is(V == string)) return value.length;
    else return V.sizeof;
}
private bool primitiveValid(V)(scope ref const V value)
{
    static if (is(V == Nullable!N, N))
        return value.isNull || primitiveValid(value.get);
    else static if (is(V == enum))
    {
        static foreach (member; __traits(allMembers, V))
            if (value == __traits(getMember, V, member)) return true;
        return false;
    }
    else return true;
}
private bool clonePayload(V, A)(ref Arena!A arena, scope ref const V input, out V output)
{
    static if (is(V == Nullable!N, N))
    {
        if (input.isNull) { output.nullify(); return true; }
        N child;
        if (!clonePayload(arena, input.get, child)) return false;
        output = child;
        return true;
    }
    else static if (is(V == string)) return arena.text(input, output);
    else { output = input; return true; }
}
private bool hasOverrides(scope ref const LeafDefinitionMetadata metadata) @safe pure nothrow @nogc
    => !metadata.priority.isNull || !metadata.order.isNull || !metadata.localId.isNull
        || !metadata.location.isNull;
private ConfigError validateLeaf(V)(scope ref const DefinitionSlot!V slot,
    scope ref const LeafDefinitionMetadata metadata, string path)
{
    if (!slot.supplied)
        return hasOverrides(metadata) ? fail(ConfigErrorKind.invalidMetadata, path) : ConfigError.init;
    if ((!metadata.localId.isNull && !validIdentity(metadata.localId.get.bytes))
        || (!metadata.location.isNull
            && (!metadata.location.get.line || !metadata.location.get.column)))
        return fail(ConfigErrorKind.invalidMetadata, path);
    if (!primitiveValid(slot.value)) return fail(ConfigErrorKind.invalidValue, path);
    return ConfigError.init;
}
private uint inheritedPriority(T, string path)(scope ref const DefinitionMetadata!T metadata,
    uint fallback)
{
    enum dot = dotPosition(path);
    static if (dot == path.length)
    {
        return __traits(getMember, metadata, path).priority.isNull ? fallback
            : __traits(getMember, metadata, path).priority.get;
    }
    else
    {
        return inheritedPriority!(ConfigFieldType!(T, path[0 .. dot]), path[dot + 1 .. $])(
            __traits(getMember, metadata, path[0 .. dot]).members,
            __traits(getMember, metadata, path[0 .. dot]).priority.isNull ? fallback
                : __traits(getMember, metadata, path[0 .. dot]).priority.get);
    }
}
private void copySectionPriorities(T)(scope ref const DefinitionMetadata!T input,
    ref DefinitionMetadata!T output)
{
    static foreach (name; ConfigFieldNames!T)
        static if (ConfigIsSection!(T, name))
        {
            __traits(getMember, output, name).priority = __traits(getMember, input, name).priority;
            copySectionPriorities(__traits(getMember, input, name).members,
                __traits(getMember, output, name).members);
        }
}
private bool cloneLeafMetadata(A)(ref Arena!A arena, scope ref const LeafDefinitionMetadata original,
    out LeafDefinitionMetadata captured, ref IdentityRecord* identities)
{
    captured.priority = original.priority;
    captured.order = original.order;
    captured.location = original.location;
    if (!original.localId.isNull)
    {
        immutable(ubyte)[] bytes;
        if (!intern(arena, identities, original.localId.get.bytes, bytes)) return false;
        captured.localId = LocalId(bytes);
    }
    return true;
}
private bool cloneMetadata(T, A)(ref Arena!A arena, scope ref const DefinitionMetadata!T input,
    out DefinitionMetadata!T output)
{
    copySectionPriorities(input, output);
    IdentityRecord* identities;
    static foreach (path; ConfigPaths!T)
        if (!cloneLeafMetadata(arena, mixin("input." ~ metadataPath(path)),
                mixin("output." ~ metadataPath(path)), identities)) return false;
    return true;
}

private struct CapsuleState(T, A)
{
    Arena!A arena;
    ConfigInput!T input;
    DefinitionMetadata!T metadata;
    ConfigLimits limits;
    ConfigUsage usage;
    bool finished;
}
struct OwnedConfigInput(T, A = ConfigAllocator)
{
    @disable this(this);
    private CapsuleState!(T, A)* state;
    ~this() { if (state !is null) { auto arena = state.arena; state = null; arena.release(); } }
    @property bool consumed() scope const @safe pure nothrow @nogc => state is null;
    @property ConfigUsage usage() scope const @safe pure nothrow @nogc
        => state is null ? ConfigUsage.init : state.usage;
    @property ConfigLimits limits() scope const @safe pure nothrow @nogc
        => state is null ? ConfigLimits.init : state.limits;
}
package ConfigResult!(OwnedConfigInput!(T, A)) beginOwnedInput(T, A = ConfigAllocator)(
    scope auto ref const DefinitionMetadata!T metadata = DefinitionMetadata!T.init,
    ConfigLimits limits = ConfigLimits.init)
{
    alias Owner = OwnedConfigInput!(T, A);
    auto error = validateLimits(limits);
    if (error.kind != ConfigErrorKind.none) return errorResult!Owner(error);
    Arena!A arena;
    auto state = arena.allocate!(CapsuleState!(T, A))();
    if (state is null) return errorResult!Owner(fail(ConfigErrorKind.allocationFailed));
    state.arena = arena;
    state.limits = limits;
    if (!cloneMetadata(state.arena, metadata, state.metadata))
    {
        auto cleanup = state.arena;
        cleanup.release();
        return errorResult!Owner(fail(ConfigErrorKind.allocationFailed));
    }
    Owner owner;
    owner.state = state;
    return successResult(owner);
}
package ref ConfigInput!T assemblyInput(T, A)(return ref OwnedConfigInput!(T, A) owner)
{
    assert(owner.state !is null && !owner.state.finished);
    return owner.state.input;
}
package ConfigError captureString(T, A)(ref OwnedConfigInput!(T, A) owner,
    scope const(char)[] bytes, out string captured)
{
    if (owner.state is null || owner.state.finished) return fail(ConfigErrorKind.invalidState);
    if (!owner.state.arena.text(bytes, captured)) return fail(ConfigErrorKind.allocationFailed);
    return ConfigError.init;
}
private ConfigError capsuleUsage(T)(scope ref const ConfigInput!T input,
    scope ref const DefinitionMetadata!T metadata, out ConfigUsage usage)
{
    usage.options = ConfigLeafCount!T;
    usage.depth = ConfigDepth!T;
    static foreach (path; SortedPaths!T)
    {{
        auto error = validateLeaf(mixin("input." ~ path), mixin("metadata." ~ metadataPath(path)), path);
        if (error.kind != ConfigErrorKind.none) return error;
    }}
    static foreach (i, path; ConfigPaths!T)
    {{
        auto error = chargeCapsuleLeaf!(T, path, i)(
            mixin("input." ~ path), mixin("metadata." ~ metadataPath(path)),
            input, metadata, usage);
        if (error.kind != ConfigErrorKind.none) return error;
    }}
    return ConfigError.init;
}
private ConfigError chargeCapsuleLeaf(T, string path, size_t index, V)(
    scope ref const DefinitionSlot!V slot, scope ref const LeafDefinitionMetadata md,
    scope ref const ConfigInput!T input, scope ref const DefinitionMetadata!T metadata,
    ref ConfigUsage usage)
{
    if (!addBytes(usage.payloadBytes, path.length))
        return fail(ConfigErrorKind.arithmeticOverflow, path);
    if (!slot.supplied) return ConfigError.init;
    ++usage.definitions;
    if (!addBytes(usage.payloadBytes, payloadCharge(slot.value)))
        return fail(ConfigErrorKind.arithmeticOverflow, path);
    if (!md.localId.isNull)
    {
        bool seen;
        static foreach (j, earlier; ConfigPaths!T)
            static if (j < index)
                if (mixin("input." ~ earlier ~ ".supplied")
                    && !mixin("metadata." ~ metadataPath(earlier) ~ ".localId.isNull")
                    && compareBytes(mixin("metadata." ~ metadataPath(earlier) ~ ".localId.get.bytes"),
                        md.localId.get.bytes) == 0) seen = true;
        if (!seen && !addBytes(usage.payloadBytes, md.localId.get.bytes.length))
            return fail(ConfigErrorKind.arithmeticOverflow, path);
    }
    return ConfigError.init;
}
package ConfigError preflightInput(T)(scope ref const ConfigInput!T input,
    scope ref const DefinitionMetadata!T metadata, ConfigLimits limits,
    ulong additionalStringBytes = 0)
{
    auto error = validateLimits(limits);
    if (error.kind != ConfigErrorKind.none) return error;
    ConfigUsage usage;
    error = capsuleUsage(input, metadata, usage);
    if (error.kind != ConfigErrorKind.none) return error;
    if (!addBytes(usage.payloadBytes, additionalStringBytes))
        return fail(ConfigErrorKind.arithmeticOverflow);
    return checkUsage(usage, limits);
}
package ConfigError finishOwnedInput(T, A)(ref OwnedConfigInput!(T, A) owner)
{
    if (owner.state is null || owner.state.finished) return fail(ConfigErrorKind.invalidState);
    ConfigUsage usage;
    auto error = capsuleUsage(owner.state.input, owner.state.metadata, usage);
    if (error.kind == ConfigErrorKind.none) error = checkUsage(usage, owner.state.limits);
    if (error.kind != ConfigErrorKind.none) return error;
    owner.state.usage = usage;
    owner.state.finished = true;
    return ConfigError.init;
}
ConfigResult!(OwnedConfigInput!(T, A)) captureInput(T, A = ConfigAllocator)(
    scope ref const ConfigInput!T input,
    scope auto ref const DefinitionMetadata!T metadata = DefinitionMetadata!T.init,
    ConfigLimits limits = ConfigLimits.init)
{
    alias Owner = OwnedConfigInput!(T, A);
    auto error = validateLimits(limits);
    if (error.kind != ConfigErrorKind.none) return errorResult!Owner(error);
    ConfigUsage usage;
    error = capsuleUsage(input, metadata, usage);
    if (error.kind == ConfigErrorKind.none) error = checkUsage(usage, limits);
    if (error.kind != ConfigErrorKind.none) return errorResult!Owner(error);
    auto started = beginOwnedInput!(T, A)(metadata, limits);
    if (started.hasError) return errorResult!Owner(started.error);
    auto owner = started.takeValue();
    static foreach (path; ConfigPaths!T)
    {
        if (mixin("input." ~ path ~ ".supplied"))
        {
            if (!clonePayload(owner.state.arena, mixin("input." ~ path ~ ".value"),
                mixin("owner.state.input." ~ path ~ ".value")))
                return errorResult!Owner(fail(ConfigErrorKind.allocationFailed));
            mixin("owner.state.input." ~ path ~ ".supplied") = true;
        }
    }
    owner.state.usage = usage;
    owner.state.finished = true;
    return successResult(owner);
}

@("wired.config.core.detachedCapsuleExactAccounting")
@safe unittest
{
    struct Settings { int width = 4; }
    ConfigInput!Settings input;
    input.width = DefinitionSlot!int(true, 8);
    DefinitionMetadata!Settings metadata;
    ConfigLimits limits;
    limits.maxPayloadBytes = 8;
    assert(captureInput!Settings(input, metadata, limits).error.kind == ConfigErrorKind.limitExceeded);
    limits.maxPayloadBytes = 9;
    auto captured = captureInput!Settings(input, metadata, limits);
    assert(captured.hasValue);
    auto capsule = captured.takeValue();
    assert(capsule.usage.sources == 0 && capsule.usage.definitions == 1
        && capsule.usage.options == 1 && capsule.usage.depth == 1 && capsule.usage.payloadBytes == 9);
    metadata.width.localId = LocalId("value");
    limits.maxPayloadBytes = 13;
    assert(captureInput!Settings(input, metadata, limits).error.kind == ConfigErrorKind.limitExceeded);
    limits.maxPayloadBytes = 14;
    auto explicitId = captureInput!Settings(input, metadata, limits);
    assert(explicitId.hasValue && explicitId.takeValue().usage.payloadBytes == 14);
    input.width.supplied = false;
    assert(captureInput!Settings(input, metadata).error.kind == ConfigErrorKind.invalidMetadata);
    metadata = DefinitionMetadata!Settings.init;
    limits.maxPayloadBytes = 5;
    auto empty = captureInput!Settings(input, metadata, limits);
    assert(empty.hasValue);
    auto emptyCapsule = empty.takeValue();
    assert(emptyCapsule.usage.payloadBytes == 5 && emptyCapsule.usage.definitions == 0);
}

@("wired.config.core.capturePreservesNullEmptyAndNullable")
@safe unittest
{
    struct Settings { string text; Nullable!string maybe; }
    ConfigInput!Settings input;
    input.text = DefinitionSlot!string(true, "");
    input.maybe.supplied = true;
    input.maybe.value = "";
    auto capture = captureInput!Settings(input);
    assert(capture.hasValue);
    auto capsule = capture.takeValue();
    assert(capsule.state.input.text.value.ptr !is null);
    assert(!capsule.state.input.maybe.value.isNull && capsule.state.input.maybe.value.get.ptr !is null);
    input.text.value = null;
    input.maybe.value.nullify();
    assert(capsule.state.input.text.value.ptr !is null && !capsule.state.input.maybe.value.isNull);
    auto nullCapture = captureInput!Settings(input);
    assert(nullCapture.hasValue);
    auto nullCapsule = nullCapture.takeValue();
    assert(nullCapsule.state.input.text.value.ptr is null && nullCapsule.state.input.maybe.value.isNull);
}

private struct IdentityRecord { IdentityRecord* next; immutable(ubyte)[] bytes; }
private struct SourceRecord
{
    SourceRecord* next;
    SourceRef ref_;
    immutable(ubyte)[] id;
    ConfigSourceKind kind;
    string detail;
    uint priority;
    int order;
}
/** Read-only payload representation. String data remains lifetime-tracked rather
than acquiring the language's independently escapable immutable-string promise.
The surrounding OptionView/DefinitionView template still names the original V. */
template ConfigBorrowedValue(V)
{
    static if (is(V == string))
        alias ConfigBorrowedValue = const(char)[];
    else static if (is(V == Nullable!N, N))
        alias ConfigBorrowedValue = ConfigNullableValueView!N;
    else
        alias ConfigBorrowedValue = V;
}
struct ConfigNullableValueView(V)
{
    private bool null_ = true;
    private ConfigBorrowedValue!V payload_;
    @property bool isNull() scope const @safe pure nothrow @nogc => null_;
    @property const(ConfigBorrowedValue!V) get() return scope const @safe pure nothrow @nogc
    {
        if (null_) assert(0, "Nullable configuration value is null");
        return payload_;
    }
}
struct ConfigValueView(V)
{
    private bool present_;
    private ConfigBorrowedValue!V payload_;
    @property bool hasValue() scope const @safe pure nothrow @nogc => present_;
    @property const(ConfigBorrowedValue!V) get() return scope const @safe pure nothrow @nogc
    {
        if (!present_) assert(0, "Configuration option has no effective value");
        return payload_;
    }
}
private ConfigBorrowedValue!V borrowValue(V)(return scope ref const V original)
{
    static if (is(V == Nullable!N, N))
    {
        ConfigBorrowedValue!V borrowed;
        borrowed.null_ = original.isNull;
        if (!original.isNull) borrowed.payload_ = borrowValue(original.get);
        return borrowed;
    }
    else return original;
}
private ConfigValueView!V valueView(V)(return scope ref const V original)
{
    ConfigValueView!V view;
    view.present_ = true;
    view.payload_ = borrowValue(original);
    return view;
}

private struct DefinitionRecord(V)
{
    DefinitionRecord* next;
    DefinitionRef ref_;
    const(SourceRecord)* source;
    immutable(ubyte)[] localId;
    uint priority;
    int order;
    Nullable!SourceLocation location;
    const(V)* value;
    DefinitionDisposition disposition;
}
struct ValidationFailureView
{
    string path;
    DefinitionRef definition;
    SourceRef source;
    uint priority;
    Nullable!SourceLocation location;
    const(char)[] code;
    const(char)[] detail;
}
struct ConfigDiagnosticView
{
    private bool present_;
    private ValidationFailureView payload_;
    @property bool hasValue() scope const @safe pure nothrow @nogc => present_;
    @property const(ValidationFailureView) get() return scope const @safe pure nothrow @nogc
    {
        if (!present_) assert(0, "Configuration option has no validation diagnostic");
        return payload_;
    }
}
private ConfigDiagnosticView diagnosticView(return scope ref const ValidationFailureView original)
    @safe pure nothrow @nogc
{
    ConfigDiagnosticView view;
    view.present_ = true;
    view.payload_ = original;
    return view;
}
struct OptionView(V)
{
    string path;
    enum policy = Atomic();
    OptionStatus status;
    uint selectedPriority;
    const(DefinitionRef)[] definitions;
    const(DefinitionRef)[] contributors;
    ConfigValueView!V effective;
    ConfigDiagnosticView diagnostic;
}
struct DefinitionView(V)
{
    string path;
    DefinitionRef ref_;
    SourceRef source;
    const(ubyte)[] sourceId;
    const(ubyte)[] localId;
    uint priority;
    int order;
    Nullable!SourceLocation location;
    DefinitionDisposition disposition;
    ConfigValueView!V value;
    @property DefinitionRef reference() scope const @safe pure nothrow @nogc => ref_;
}
struct SourceView
{
    SourceRef ref_;
    const(ubyte)[] id;
    ConfigSourceKind kind;
    const(char)[] detail;
    uint priority;
    int order;
    @property SourceRef reference() scope const @safe pure nothrow @nogc => ref_;
}
private struct OptionStorage(V)
{
    DefinitionRecord!V* first;
    DefinitionRecord!V* last;
    DefinitionRecord!V*[] sorted;
    DefinitionRef[] definitions;
    DefinitionRef[] contributors;
    OptionStatus status;
    uint selectedPriority;
    const(V)* effective;
    ValidationFailureView* diagnostic;
}
private struct RetainedState(T, A)
{
    Arena!A arena;
    ConfigLimits limits;
    ConfigUsage usage;
    ulong owner;
    T defaults;
    SourceRecord* firstSource;
    SourceRecord* lastSource;
    SourceRecord*[] sources;
    IdentityRecord* identities;
    string[] failedOptions;
    static foreach (i, path; ConfigPaths!T)
        mixin("OptionStorage!(LeafSite!(T, \"" ~ path ~ "\").Value) option" ~ i.stringof ~ ";");
}
private IdentityRecord* lookupIdentity(T, A)(RetainedState!(T, A)* state,
    scope const(ubyte)[] bytes)
{
    for (auto record = state.identities; record !is null; record = record.next)
        if (compareBytes(record.bytes, bytes) == 0) return record;
    return null;
}
private bool intern(A)(ref Arena!A arena, ref IdentityRecord* records,
    scope const(ubyte)[] bytes, out immutable(ubyte)[] result)
{
    for (auto record = records; record !is null; record = record.next)
        if (compareBytes(record.bytes, bytes) == 0) { result = record.bytes; return true; }
    auto record = arena.allocate!IdentityRecord();
    if (record is null || !arena.bytes(bytes, record.bytes)) return false;
    record.next = records;
    records = record;
    result = record.bytes;
    return true;
}
private bool internOwned(A)(ref Arena!A arena, ref IdentityRecord* records,
    immutable(ubyte)[] bytes, out immutable(ubyte)[] result)
{
    for (auto record = records; record !is null; record = record.next)
        if (compareBytes(record.bytes, bytes) == 0) { result = record.bytes; return true; }
    auto record = arena.allocate!IdentityRecord();
    if (record is null) return false;
    record.bytes = bytes;
    record.next = records;
    records = record;
    result = bytes;
    return true;
}
private const(SourceRecord)* lookupSource(T, A)(return scope const(RetainedState!(T, A))* state,
    SourceRef handle)
{
    for (const(SourceRecord)* record = state.firstSource; record !is null; record = record.next)
        if (record.ref_ == handle) return record;
    return null;
}
private ConfigError sourceError(T, A)(scope const(RetainedState!(T, A))* state, SourceRef handle)
{
    if (state is null) return fail(ConfigErrorKind.invalidState);
    if (handle.owner != state.owner) return fail(ConfigErrorKind.wrongOwner);
    if (lookupSource(state, handle) is null) return fail(ConfigErrorKind.unknownSource);
    return ConfigError.init;
}
private void appendDefinition(V)(ref OptionStorage!V option, DefinitionRecord!V* record)
{
    if (option.last is null) option.first = record;
    else option.last.next = record;
    option.last = record;
}
private immutable(ubyte)[] submittedLocal(return scope ref const LeafDefinitionMetadata metadata)
    @safe pure nothrow @nogc
    => metadata.localId.isNull ? immutableBytes("value") : metadata.localId.get.bytes;

/** A move-only collecting owner. Successful resolution consumes it. */
struct ConfigBuilder(T, A = ConfigAllocator)
{
    static assert(validateSchema!T);
    @disable this(this);
    private RetainedState!(T, A)* state;
    ~this() { if (state !is null) { auto arena = state.arena; state = null; arena.release(); } }
    @property bool consumed() scope const @safe pure nothrow @nogc => state is null;
    @property bool collecting() scope const @safe pure nothrow @nogc => state !is null;
    @property ConfigUsage usage() scope const @safe pure nothrow @nogc
        => state is null ? ConfigUsage.init : state.usage;
    @property ConfigLimits limits() scope const @safe pure nothrow @nogc
        => state is null ? ConfigLimits.init : state.limits;

    static ConfigResult!ConfigBuilder create(ConfigLimits limits = ConfigLimits.init,
        uint builtinPriority = 1500, int builtinOrder = 0)
    {
        auto error = validateLimits(limits);
        if (error.kind != ConfigErrorKind.none) return errorResult!ConfigBuilder(error);
        T defaults = T.init;
        static foreach (path; SortedPaths!T)
            if (!primitiveValid(mixin("defaults." ~ path)))
                return errorResult!ConfigBuilder(fail(ConfigErrorKind.invalidValue, path));
        ConfigUsage usage = ConfigUsage(1, ConfigLeafCount!T, 8, ConfigLeafCount!T, ConfigDepth!T);
        if (ConfigLeafCount!T) usage.payloadBytes += 11;
        static foreach (path; ConfigPaths!T)
        {
            if (!addBytes(usage.payloadBytes, path.length)
                || !addBytes(usage.payloadBytes, payloadCharge(mixin("defaults." ~ path))))
                return errorResult!ConfigBuilder(fail(ConfigErrorKind.arithmeticOverflow, path));
        }
        error = checkUsage(usage, limits);
        if (error.kind != ConfigErrorKind.none) return errorResult!ConfigBuilder(error);
        auto identity = freshOwner();
        if (!identity) return errorResult!ConfigBuilder(fail(ConfigErrorKind.arithmeticOverflow));
        Arena!A arena;
        auto retained = arena.allocate!(RetainedState!(T, A))();
        if (retained is null) return errorResult!ConfigBuilder(fail(ConfigErrorKind.allocationFailed));
        retained.arena = arena;
        ConfigBuilder builder;
        builder.state = retained;
        retained.limits = limits;
        retained.usage = usage;
        retained.owner = identity;
        auto source = retained.arena.allocate!SourceRecord();
        if (source is null) return errorResult!ConfigBuilder(fail(ConfigErrorKind.allocationFailed));
        if (!intern(retained.arena, retained.identities, immutableBytes("$builtin"), source.id))
            return errorResult!ConfigBuilder(fail(ConfigErrorKind.allocationFailed));
        source.ref_ = SourceRef(retained.owner, 0);
        source.kind = ConfigSourceKind.builtinDefault;
        source.priority = builtinPriority;
        source.order = builtinOrder;
        retained.firstSource = retained.lastSource = source;
        immutable(ubyte)[] local;
        if (ConfigLeafCount!T && !intern(retained.arena, retained.identities,
                immutableBytes("initializer"), local))
            return errorResult!ConfigBuilder(fail(ConfigErrorKind.allocationFailed));
        static foreach (i, path; ConfigPaths!T)
        {{
            alias V = LeafSite!(T, path).Value;
            auto definition = retained.arena.allocate!(DefinitionRecord!V)();
            if (definition is null) return errorResult!ConfigBuilder(fail(ConfigErrorKind.allocationFailed));
            definition.ref_ = DefinitionRef(retained.owner, cast(uint) i);
            definition.source = source;
            definition.localId = local;
            definition.priority = builtinPriority;
            definition.order = builtinOrder;
            definition.value = &mixin("retained.defaults." ~ path);
            appendDefinition(mixin("retained.option" ~ i.stringof), definition);
        }}
        return successResult(builder);
    }

    ConfigResult!SourceRef registerSource(SourceId id, ConfigSourceKind kind,
        scope const(char)[] detail, uint priority = 1000, int order = 0)
    { return registerSource(id.bytes, kind, detail, priority, order); }

    ConfigResult!SourceRef registerSource(scope const(ubyte)[] id, ConfigSourceKind kind,
        scope const(char)[] detail, uint priority = 1000, int order = 0)
    {
        if (state is null) return errorResult!SourceRef(fail(ConfigErrorKind.invalidState));
        if (!validIdentity(id) || compareBytes(id, immutableBytes("$builtin")) == 0
            || kind == ConfigSourceKind.builtinDefault || cast(uint) kind > cast(uint) ConfigSourceKind.custom)
            return errorResult!SourceRef(fail(ConfigErrorKind.invalidMetadata));
        for (auto source = state.firstSource; source !is null; source = source.next)
            if (compareBytes(source.id, id) == 0)
                return errorResult!SourceRef(fail(ConfigErrorKind.duplicateSource));
        ConfigUsage usage = state.usage;
        ++usage.sources;
        auto error = checkedCharge(state.usage.sources, 1, state.limits.maxSources, "maxSources");
        if (error.kind != ConfigErrorKind.none) return errorResult!SourceRef(error);
        ulong extra = detail.length;
        if (lookupIdentity(state, id) is null && !addBytes(extra, id.length))
            return errorResult!SourceRef(fail(ConfigErrorKind.arithmeticOverflow));
        error = checkedCharge(state.usage.payloadBytes, extra, state.limits.maxPayloadBytes, "maxPayloadBytes");
        if (error.kind != ConfigErrorKind.none) return errorResult!SourceRef(error);
        usage.payloadBytes += extra;
        Arena!A temporary;
        scope(exit) temporary.release();
        auto source = temporary.allocate!SourceRecord();
        if (source is null) return errorResult!SourceRef(fail(ConfigErrorKind.allocationFailed));
        auto identities = state.identities;
        if (!intern(temporary, identities, id, source.id) || !temporary.text(detail, source.detail))
            return errorResult!SourceRef(fail(ConfigErrorKind.allocationFailed));
        source.ref_ = SourceRef(state.owner, cast(uint) state.usage.sources);
        source.kind = kind;
        source.priority = priority;
        source.order = order;
        state.arena.absorb(temporary);
        state.identities = identities;
        state.lastSource.next = source;
        state.lastSource = source;
        state.usage = usage;
        auto handle = source.ref_;
        return successResult(handle);
    }

    ConfigError setLimits(ConfigLimits limits)
    {
        if (state is null) return fail(ConfigErrorKind.invalidState);
        auto error = checkUsage(state.usage, limits, true);
        if (error.kind != ConfigErrorKind.none) return error;
        state.limits = limits;
        return ConfigError.init;
    }

    private ConfigError preflight(SourceRef sourceRef, scope ref const ConfigInput!T input,
        scope ref const DefinitionMetadata!T metadata, out ConfigUsage usage)
    {
        auto error = sourceError(state, sourceRef);
        if (error.kind != ConfigErrorKind.none) return error;
        static foreach (path; SortedPaths!T)
        {{
            error = validateLeaf(mixin("input." ~ path), mixin("metadata." ~ metadataPath(path)), path);
            if (error.kind != ConfigErrorKind.none) return error;
        }}
        static foreach (path; SortedPaths!T)
        {{
            enum index = pathIndex!(T, path)();
            if (mixin("input." ~ path ~ ".supplied"))
            {
                auto local = submittedLocal(mixin("metadata." ~ metadataPath(path)));
                for (auto record = mixin("state.option" ~ index.stringof ~ ".first");
                    record !is null; record = record.next)
                    if (record.source.ref_ == sourceRef && compareBytes(record.localId, local) == 0)
                        return fail(ConfigErrorKind.duplicateDefinition, path);
            }
        }}
        ulong count, extra;
        static foreach (i, path; ConfigPaths!T)
        {{
            if (mixin("input." ~ path ~ ".supplied"))
            {
                ++count;
                if (!addBytes(extra, payloadCharge(mixin("input." ~ path ~ ".value"))))
                    return fail(ConfigErrorKind.arithmeticOverflow, path);
                auto local = submittedLocal(mixin("metadata." ~ metadataPath(path)));
                bool seen = lookupIdentity(state, local) !is null;
                static foreach (j, earlier; ConfigPaths!T)
                    static if (j < i)
                        if (mixin("input." ~ earlier ~ ".supplied")
                            && compareBytes(submittedLocal(mixin("metadata." ~ metadataPath(earlier))), local) == 0)
                            seen = true;
                if (!seen && !addBytes(extra, local.length))
                    return fail(ConfigErrorKind.arithmeticOverflow, path);
            }
        }}
        error = checkedCharge(state.usage.definitions, count, state.limits.maxDefinitions, "maxDefinitions");
        if (error.kind != ConfigErrorKind.none) return error;
        error = checkedCharge(state.usage.payloadBytes, extra, state.limits.maxPayloadBytes, "maxPayloadBytes");
        if (error.kind != ConfigErrorKind.none) return error;
        usage = state.usage;
        usage.definitions += count;
        usage.payloadBytes += extra;
        return ConfigError.init;
    }

    ConfigError submitBorrowed()(SourceRef source, scope ref const ConfigInput!T input,
        scope auto ref const DefinitionMetadata!T metadata = DefinitionMetadata!T.init)
    {
        ConfigUsage usage;
        auto error = preflight(source, input, metadata, usage);
        if (error.kind != ConfigErrorKind.none) return error;
        if (usage.definitions == state.usage.definitions) return ConfigError.init;
        // Detached accounting is distinct; the builder preflight already applies its policy.
        ConfigLimits temporaryLimits = ConfigLimits(uint.max, uint.max, ulong.max, uint.max, uint.max);
        auto captured = captureInput!(T, A)(input, metadata, temporaryLimits);
        if (captured.hasError) return captured.error;
        auto owner = captured.takeValue();
        return submitOwned(source, owner);
    }

    ConfigError submitOwned(SourceRef source, ref OwnedConfigInput!(T, A) input)
    {
        auto error = sourceError(state, source);
        if (error.kind != ConfigErrorKind.none) return error;
        if (input.state is null || !input.state.finished) return fail(ConfigErrorKind.invalidState);
        ConfigUsage usage;
        error = preflight(source, input.state.input, input.state.metadata, usage);
        if (error.kind != ConfigErrorKind.none) return error;
        Arena!A temporary;
        scope(exit) temporary.release();
        auto identities = state.identities;
        auto sourceRecord = lookupSource(state, source);
        // Stage every record and identity without touching any retained linked list.
        static foreach (i, path; ConfigPaths!T)
            mixin("DefinitionRecord!(LeafSite!(T, \"" ~ path ~ "\").Value)* pending" ~ i.stringof ~ ";");
        uint index = cast(uint) state.usage.definitions;
        static foreach (i, path; ConfigPaths!T)
        {{
            if (mixin("input.state.input." ~ path ~ ".supplied"))
            {
                alias V = LeafSite!(T, path).Value;
                auto record = temporary.allocate!(DefinitionRecord!V)();
                if (record is null) return fail(ConfigErrorKind.allocationFailed);
                auto metadata = &mixin("input.state.metadata." ~ metadataPath(path));
                if (!internOwned(temporary, identities, submittedLocal(*metadata), record.localId))
                    return fail(ConfigErrorKind.allocationFailed);
                record.ref_ = DefinitionRef(state.owner, index++);
                record.source = sourceRecord;
                record.priority = inheritedPriority!(T, path)(input.state.metadata, sourceRecord.priority);
                record.order = metadata.order.isNull ? sourceRecord.order : metadata.order.get;
                record.location = metadata.location;
                record.value = &mixin("input.state.input." ~ path ~ ".value");
                mixin("pending" ~ i.stringof) = record;
            }
        }}
        state.arena.absorb(temporary);
        state.arena.absorb(input.state.arena);
        state.identities = identities;
        static foreach (i, path; ConfigPaths!T)
            if (mixin("pending" ~ i.stringof) !is null)
                appendDefinition(mixin("state.option" ~ i.stringof), mixin("pending" ~ i.stringof));
        state.usage = usage;
        input.state = null;
        return ConfigError.init;
    }

    ConfigResult!(ConfigSnapshot!(T, A)) resolve()
    {
        alias Snapshot = ConfigSnapshot!(T, A);
        if (state is null) return errorResult!Snapshot(fail(ConfigErrorKind.invalidState));
        static foreach (i, path; ConfigPaths!T)
        {
            mixin("OptionStorage!(LeafSite!(T, \"" ~ path ~ "\").Value) pending" ~ i.stringof ~ ";");
            mixin("size_t count" ~ i.stringof ~ ", selected" ~ i.stringof ~ ";");
            mixin("ValidationResult validation" ~ i.stringof ~ ";");
        }
        ulong diagnosticBytes;
        size_t failureCount;
        // Compute selection and all diagnostic charges before attempting allocation.
        static foreach (i, path; ConfigPaths!T)
        {{
            alias Site = LeafSite!(T, path);
            scope auto option = &mixin("state.option" ~ i.stringof);
            scope auto pending = &mixin("pending" ~ i.stringof);
            pending.first = option.first;
            pending.last = option.last;
            pending.selectedPriority = uint.max;
            const(DefinitionRecord!(Site.Value))* winner;
            for (auto record = option.first; record !is null; record = record.next)
            {
                ++mixin("count" ~ i.stringof);
                if (winner is null || record.priority < pending.selectedPriority)
                {
                    pending.selectedPriority = record.priority;
                    mixin("selected" ~ i.stringof) = 1;
                    winner = record;
                }
                else if (record.priority == pending.selectedPriority)
                    ++mixin("selected" ~ i.stringof);
            }
            if (mixin("selected" ~ i.stringof) > 1)
            {
                pending.status = OptionStatus.conflict;
                ++failureCount;
            }
            else
            {
                static if (!is(CheckPolicy!(Site.Parent, Site.name) == void))
                    mixin("validation" ~ i.stringof) =
                        callCheck!(CheckPolicy!(Site.Parent, Site.name), Site.Value)(*winner.value);
                scope auto validation = &mixin("validation" ~ i.stringof);
                if (validation.accepted)
                {
                    pending.status = OptionStatus.resolved;
                    pending.effective = winner.value;
                }
                else
                {
                    assert(validation.code.length, "ConfigCheck rejection requires a stable nonempty code");
                    pending.status = OptionStatus.invalidSelectedValue;
                    ++failureCount;
                    if (!addBytes(diagnosticBytes, validation.code.length)
                        || !addBytes(diagnosticBytes, validation.detail.length))
                        return errorResult!Snapshot(fail(ConfigErrorKind.arithmeticOverflow, path));
                }
            }
        }}
        auto error = checkedCharge(state.usage.payloadBytes, diagnosticBytes,
            state.limits.maxPayloadBytes, "maxPayloadBytes");
        if (error.kind != ConfigErrorKind.none) return errorResult!Snapshot(error);
        Arena!A temporary;
        scope(exit) temporary.release();
        static foreach (i, path; ConfigPaths!T)
        {{
            alias V = LeafSite!(T, path).Value;
            scope auto pending = &mixin("pending" ~ i.stringof);
            auto count = mixin("count" ~ i.stringof);
            auto selected = mixin("selected" ~ i.stringof);
            pending.sorted = temporary.array!(DefinitionRecord!V*)(count);
            pending.definitions = temporary.array!DefinitionRef(count);
            pending.contributors = temporary.array!DefinitionRef(selected);
            if (pending.sorted.ptr is null || pending.definitions.ptr is null
                || pending.contributors.ptr is null)
                return errorResult!Snapshot(fail(ConfigErrorKind.allocationFailed));
            size_t n;
            for (auto record = pending.first; record !is null; record = record.next)
                pending.sorted[n++] = record;
            sortDefinitions(pending.sorted);
            foreach (j, record; pending.sorted)
            {
                pending.definitions[j] = record.ref_;
                if (j < selected) pending.contributors[j] = record.ref_;
            }
            if (pending.status == OptionStatus.invalidSelectedValue)
            {
                scope auto validation = &mixin("validation" ~ i.stringof);
                pending.diagnostic = temporary.allocate!ValidationFailureView();
                if (pending.diagnostic is null)
                    return errorResult!Snapshot(fail(ConfigErrorKind.allocationFailed));
                auto winner = pending.sorted[0];
                pending.diagnostic.path = path;
                pending.diagnostic.definition = winner.ref_;
                pending.diagnostic.source = winner.source.ref_;
                pending.diagnostic.priority = pending.selectedPriority;
                pending.diagnostic.location = winner.location;
                string code, detail;
                if (!temporary.text(validation.code, code)
                    || !temporary.text(validation.detail, detail))
                    return errorResult!Snapshot(fail(ConfigErrorKind.allocationFailed));
                pending.diagnostic.code = code;
                pending.diagnostic.detail = detail;
            }
        }}
        auto failed = temporary.array!string(failureCount);
        if (failureCount && failed.ptr is null)
            return errorResult!Snapshot(fail(ConfigErrorKind.allocationFailed));
        size_t at;
        static foreach (path; SortedPaths!T)
        {{
            enum i = pathIndex!(T, path)();
            if (mixin("pending" ~ i.stringof ~ ".status") != OptionStatus.resolved) failed[at++] = path;
        }}
        auto sources = temporary.array!(SourceRecord*)(cast(size_t) state.usage.sources);
        if (sources.ptr is null) return errorResult!Snapshot(fail(ConfigErrorKind.allocationFailed));
        at = 0;
        for (auto record = state.firstSource; record !is null; record = record.next) sources[at++] = record;
        sortSources(sources);
        static foreach (i, path; ConfigPaths!T)
        {{
            scope auto pending = &mixin("pending" ~ i.stringof);
            foreach (record; pending.sorted)
            {
                if (record.priority != pending.selectedPriority) record.disposition = DefinitionDisposition.overridden;
                else final switch (pending.status)
                {
                    case OptionStatus.resolved: record.disposition = DefinitionDisposition.contributing; break;
                    case OptionStatus.conflict: record.disposition = DefinitionDisposition.conflicting; break;
                    case OptionStatus.invalidSelectedValue: record.disposition = DefinitionDisposition.invalid; break;
                }
            }
            mixin("state.option" ~ i.stringof) = *pending;
        }}
        state.sources = sources;
        state.failedOptions = failed;
        state.usage.payloadBytes += diagnosticBytes;
        state.arena.absorb(temporary);
        Snapshot snapshot;
        snapshot.state = state;
        state = null;
        return successResult(snapshot);
    }
}

@("wired.config.core.atomicAdmissionAndBudgetRecovery")
@safe unittest
{
    struct Settings { int width = 4; }
    ConfigLimits limits;
    limits.maxPayloadBytes = 42;
    auto created = ConfigBuilder!Settings.create(limits);
    assert(created.hasValue);
    auto builder = created.takeValue();
    assert(builder.usage.payloadBytes == 28);
    auto registered = builder.registerSource(SourceId("u"), ConfigSourceKind.userFile, "file");
    assert(registered.hasValue);
    auto source = registered.value;
    assert(builder.usage.payloadBytes == 33);
    ConfigInput!Settings input;
    input.width = DefinitionSlot!int(true, 8);
    assert(builder.submitBorrowed(source, input).kind == ConfigErrorKind.none);
    assert(builder.usage.payloadBytes == 42 && builder.usage.definitions == 2);
    assert(builder.submitBorrowed(source, input).kind == ConfigErrorKind.duplicateDefinition);
    assert(builder.registerSource(SourceId("u"), ConfigSourceKind.userFile, "file").error.kind
        == ConfigErrorKind.duplicateSource);
    DefinitionMetadata!Settings metadata;
    metadata.width.localId = LocalId("other");
    auto captured = captureInput!Settings(input, metadata);
    assert(captured.hasValue);
    auto capsule = captured.takeValue();
    assert(builder.submitOwned(source, capsule).kind == ConfigErrorKind.limitExceeded);
    assert(!capsule.consumed && builder.usage.payloadBytes == 42 && builder.usage.definitions == 2);
    limits.maxPayloadBytes = 41;
    assert(builder.setLimits(limits).kind == ConfigErrorKind.limitExceeded);
    assert(builder.limits.maxPayloadBytes == 42);
    limits.maxPayloadBytes = 51;
    assert(builder.setLimits(limits).kind == ConfigErrorKind.none);
    assert(builder.submitOwned(source, capsule).kind == ConfigErrorKind.none);
    assert(capsule.consumed && capsule.usage == ConfigUsage.init && builder.usage.payloadBytes == 51);
    auto resolved = builder.resolve();
    assert(resolved.hasValue && builder.consumed);
    auto snapshot = resolved.takeValue();
    assert(snapshot.visitOption!((scope ref const OptionView!int view) {
        assert(view.status == OptionStatus.conflict && view.definitions.length == 3
            && view.contributors.length == 2 && !view.effective.hasValue);
    })("width").kind == ConfigErrorKind.none);
    assert(builder.submitBorrowed(source, input).kind == ConfigErrorKind.invalidState);
    assert(builder.setLimits(limits).kind == ConfigErrorKind.invalidState);
}

@("wired.config.core.builtinDomainBeforeSelectedChecks")
@safe unittest
{
    enum Mode : int { enabled = 1 }
    struct Invalid { Mode mode = cast(Mode) 9; }
    auto invalid = ConfigBuilder!Invalid.create();
    assert(invalid.hasError && invalid.error.kind == ConfigErrorKind.invalidValue
        && invalid.error.path == "mode");
    static ValidationResult positive(in int value) @safe pure nothrow
    {
        return value > 0 ? ValidationResult.accept() : ValidationResult.reject("positive");
    }
    struct Checked { @(ConfigCheck!positive()) int width; }
    auto created = ConfigBuilder!Checked.create();
    assert(created.hasValue);
    auto builder = created.takeValue();
    auto sourceResult = builder.registerSource(SourceId("u"), ConfigSourceKind.userFile, null);
    assert(sourceResult.hasValue);
    ConfigInput!Checked input;
    input.width = DefinitionSlot!int(true, 8);
    assert(builder.submitBorrowed(sourceResult.value, input).kind == ConfigErrorKind.none);
    auto resolved = builder.resolve();
    assert(resolved.hasValue);
    auto snapshot = resolved.takeValue();
    auto copied = snapshot.copyConfig();
    assert(copied.hasValue && copied.takeValue().width == 8);
    uint overridden;
    assert(snapshot.visitDefinitions!((scope ref const DefinitionView!int view) {
        if (view.disposition == DefinitionDisposition.overridden)
        {
            assert(view.value.get == 0);
            ++overridden;
        }
    })("width").kind == ConfigErrorKind.none);
    assert(overridden == 1);
}

@("wired.config.core.sectionPriorityAndEnclosingInitializer")
@safe unittest
{
    @WireSection struct Advanced { int zoom = 2; }
    @WireSection struct Viewer { int width = 4; int priority = 1; Advanced advanced; }
    struct Settings { Viewer viewer = Viewer(8, 1, Advanced(3)); }
    auto created = ConfigBuilder!Settings.create();
    auto builder = created.takeValue();
    auto sourceResult = builder.registerSource(SourceId("u"), ConfigSourceKind.userFile, null);
    ConfigInput!Settings input;
    input.viewer.width = DefinitionSlot!int(true, 12);
    input.viewer.advanced.zoom = DefinitionSlot!int(true, 9);
    DefinitionMetadata!Settings metadata;
    metadata.viewer.priority = 500u;
    metadata.viewer.members.advanced.priority = 300u;
    metadata.viewer.members.width.priority = 250u;
    metadata.viewer.members.priority.priority = 0u;
    assert(builder.submitBorrowed(sourceResult.value, input, metadata).kind == ConfigErrorKind.invalidMetadata);
    assert(builder.usage.definitions == 3);
    metadata.viewer.members.priority.priority.nullify();
    auto captured = captureInput!Settings(input, metadata);
    auto capsule = captured.takeValue();
    assert(builder.submitOwned(sourceResult.value, capsule).kind == ConfigErrorKind.none);
    auto resolved = builder.resolve();
    auto snapshot = resolved.takeValue();
    assert(snapshot.visitOptions!((scope ref const OptionView!int view) {
        if (view.path == "viewer.width") assert(view.selectedPriority == 250 && view.effective.get == 12);
        else if (view.path == "viewer.advanced.zoom") assert(view.selectedPriority == 300 && view.effective.get == 9);
        else assert(view.path == "viewer.priority" && view.selectedPriority == 1500 && view.effective.get == 1);
    })().kind == ConfigErrorKind.none);
    assert(snapshot.visitDefinitions!((scope ref const DefinitionView!int view) {
        if (view.disposition == DefinitionDisposition.overridden) assert(view.value.get == 8);
    })("viewer.width").kind == ConfigErrorKind.none);
}

@("wired.config.core.diagnosticRecoveryAndOwnerTransfers")
@safe unittest
{
    static ValidationResult positive(in int value) @safe pure nothrow
    {
        return value > 0 ? ValidationResult.accept() : ValidationResult.reject("positive");
    }
    struct Settings { @(ConfigCheck!positive()) int width = 4; }
    ConfigLimits limits;
    limits.maxPayloadBytes = 42;
    auto created = ConfigBuilder!Settings.create(limits);
    auto original = created.takeValue();
    auto sourceResult = original.registerSource(SourceId("u"), ConfigSourceKind.userFile, "file");
    auto source = sourceResult.value;
    auto builder = move(original);
    ConfigInput!Settings input;
    input.width = DefinitionSlot!int(true, 0);
    assert(original.submitBorrowed(source, input).kind == ConfigErrorKind.invalidState);
    assert(builder.submitBorrowed(source, input).kind == ConfigErrorKind.none);
    auto rejected = builder.resolve();
    assert(rejected.hasError && rejected.error.kind == ConfigErrorKind.limitExceeded && builder.collecting);
    assert(builder.usage.payloadBytes == 42);
    ConfigInput!Settings empty;
    assert(builder.submitBorrowed(source, empty).kind == ConfigErrorKind.none);
    limits.maxPayloadBytes = 50;
    assert(builder.setLimits(limits).kind == ConfigErrorKind.none);
    auto resolved = builder.resolve();
    assert(resolved.hasValue && builder.consumed);
    auto originalSnapshot = resolved.takeValue();
    auto snapshot = move(originalSnapshot);
    assert(originalSnapshot.visitSource!((scope ref const SourceView view) {
        assert(false);
    })(source).kind == ConfigErrorKind.invalidState);
    assert(snapshot.visitSource!((scope ref const SourceView view) {
        assert(view.id == immutableBytes("u") && view.detail == "file");
    })(source).kind == ConfigErrorKind.none);
    DefinitionRef selected;
    assert(snapshot.visitOption!((scope ref const OptionView!int view) {
        assert(view.status == OptionStatus.invalidSelectedValue && !view.effective.hasValue);
        assert(view.diagnostic.hasValue && view.diagnostic.get.code == "positive"
            && view.diagnostic.get.path == "width" && view.diagnostic.get.source == source);
        selected = view.diagnostic.get.definition;
    })("width").kind == ConfigErrorKind.none);
    assert(snapshot.visitDefinition!((scope ref const DefinitionView!int view) {
        assert(view.disposition == DefinitionDisposition.invalid && view.value.get == 0);
    })(selected).kind == ConfigErrorKind.none);
    auto copied = snapshot.copyConfig();
    assert(copied.hasError && copied.error.kind == ConfigErrorKind.notFullyResolved
        && copied.error.failedOptions == ["width"]);
    assert(builder.resolve().error.kind == ConfigErrorKind.invalidState);
    auto anotherResult = ConfigBuilder!Settings.create();
    auto another = anotherResult.takeValue();
    assert(another.submitBorrowed(source, empty).kind == ConfigErrorKind.wrongOwner);
}

@("wired.config.core.completeMixedSemanticOutcomes")
@safe unittest
{
    static ValidationResult positive(in int value) @safe pure nothrow
    {
        return value > 0 ? ValidationResult.accept() : ValidationResult.reject("positive", "must exceed zero");
    }
    struct Settings { int clash = 4; @(ConfigCheck!positive()) int bad = 4; int good = 4; }
    auto created = ConfigBuilder!Settings.create();
    auto builder = created.takeValue();
    auto user = builder.registerSource(SourceId("u"), ConfigSourceKind.userFile, null);
    auto project = builder.registerSource(SourceId("p"), ConfigSourceKind.projectFile, null);
    ConfigInput!Settings input;
    input.clash = DefinitionSlot!int(true, 11);
    input.bad = DefinitionSlot!int(true, 0);
    input.good = DefinitionSlot!int(true, 8);
    assert(builder.submitBorrowed(user.value, input).kind == ConfigErrorKind.none);
    input = ConfigInput!Settings.init;
    input.clash = DefinitionSlot!int(true, 12);
    assert(builder.submitBorrowed(project.value, input).kind == ConfigErrorKind.none);
    auto resolved = builder.resolve();
    auto snapshot = resolved.takeValue();
    uint declarationIndex, definitions;
    assert(snapshot.visitOptions!((scope ref const OptionView!int view) {
        if (declarationIndex == 0) assert(view.path == "clash" && view.status == OptionStatus.conflict);
        if (declarationIndex == 1) assert(view.path == "bad" && view.status == OptionStatus.invalidSelectedValue
            && view.diagnostic.get.code == "positive" && view.diagnostic.get.detail == "must exceed zero");
        if (declarationIndex == 2) assert(view.path == "good" && view.status == OptionStatus.resolved
            && view.effective.get == 8);
        ++declarationIndex;
        definitions += cast(uint) view.definitions.length;
    })().kind == ConfigErrorKind.none);
    assert(declarationIndex == 3 && definitions == 7);
    auto copied = snapshot.copyConfig();
    assert(copied.error.kind == ConfigErrorKind.notFullyResolved
        && copied.error.failedOptions == ["bad", "clash"]);
}
private bool definitionLess(V)(DefinitionRecord!V* a, DefinitionRecord!V* b)
{
    if (a.priority != b.priority) return a.priority < b.priority;
    if (a.order != b.order) return a.order < b.order;
    auto source = compareBytes(a.source.id, b.source.id);
    if (source) return source < 0;
    return compareBytes(a.localId, b.localId) < 0;
}
private void sortDefinitions(V)(DefinitionRecord!V*[] records)
{
    sort!((a, b) => definitionLess(a, b))(records);
}
private void sortSources(SourceRecord*[] records) @safe
{
    sort!((a, b) => compareBytes(a.id, b.id) < 0)(records);
}
private OptionView!V optionView(V)(string path, return scope ref const OptionStorage!V option)
{
    OptionView!V view;
    view.path = path;
    view.status = option.status;
    view.selectedPriority = option.selectedPriority;
    view.definitions = option.definitions;
    view.contributors = option.contributors;
    if (option.status == OptionStatus.resolved) view.effective = valueView(*option.effective);
    if (option.status == OptionStatus.invalidSelectedValue) view.diagnostic = diagnosticView(*option.diagnostic);
    return view;
}
private DefinitionView!V definitionView(V)(string path, return scope const DefinitionRecord!V* record)
{
    return DefinitionView!V(path, record.ref_, record.source.ref_, record.source.id,
        record.localId, record.priority, record.order, record.location, record.disposition,
        valueView(*record.value));
}
private SourceView sourceView(return scope const SourceRecord* record) @safe pure nothrow @nogc
{
    return SourceView(record.ref_, record.id, record.kind, record.detail, record.priority, record.order);
}

/** Complete move-only resolution owner. Inspection always borrows through a typed sink. */
struct ConfigSnapshot(T, A = ConfigAllocator)
{
    @disable this(this);
    private RetainedState!(T, A)* state;
    ~this() { if (state !is null) { auto arena = state.arena; state = null; arena.release(); } }
    @property bool consumed() scope const @safe pure nothrow @nogc => state is null;
    @property ConfigUsage usage() scope const @safe pure nothrow @nogc
        => state is null ? ConfigUsage.init : state.usage;
    @property ConfigLimits limits() scope const @safe pure nothrow @nogc
        => state is null ? ConfigLimits.init : state.limits;
    @property bool fullyResolved() scope const @safe pure nothrow @nogc
        => state !is null && state.failedOptions.length == 0;

    ConfigResult!T copyConfig() return scope const
    {
        if (state is null) return errorResult!T(fail(ConfigErrorKind.invalidState));
        if (state.failedOptions.length)
        {
            auto error = fail(ConfigErrorKind.notFullyResolved);
            error.failedOptions = state.failedOptions;
            return errorResult!T(error);
        }
        T result = T.init;
        CopyArena!A temporary;
        scope(exit) temporary.release();
        static foreach (i, path; ConfigPaths!T)
        {{
            if (!copyIndependent(temporary, *mixin("state.option" ~ i.stringof ~ ".effective"),
                    mixin("result." ~ path)))
                return errorResult!T(fail(ConfigErrorKind.allocationFailed));
        }}
        temporary.commit();
        return successResult(result);
    }
}

/// Borrows one option through a typed, scoped sink.
ConfigError visitOption(alias sink, T, A)(scope ref const ConfigSnapshot!(T, A) snapshot,
    scope const(char)[] path)
{
    scope auto state = snapshot.state;
    if (state is null) return fail(ConfigErrorKind.invalidState);
    static foreach (i, canonical; ConfigPaths!T)
        if (path == canonical)
        {
            scope auto view = optionView(canonical, mixin("state.option" ~ i.stringof));
            deliver!sink(view);
            return ConfigError.init;
        }
    return fail(ConfigErrorKind.unknownOption);
}

/// Visits options in schema declaration order.
ConfigError visitOptions(alias sink, T, A)(scope ref const ConfigSnapshot!(T, A) snapshot)
{
    scope auto state = snapshot.state;
    if (state is null) return fail(ConfigErrorKind.invalidState);
    static foreach (i, canonical; ConfigPaths!T)
    {{
        scope auto view = optionView(canonical, mixin("state.option" ~ i.stringof));
        deliver!sink(view);
    }}
    return ConfigError.init;
}

/// Visits all accepted definitions of one option in precedence order.
ConfigError visitDefinitions(alias sink, T, A)(scope ref const ConfigSnapshot!(T, A) snapshot,
    scope const(char)[] path)
{
    scope auto state = snapshot.state;
    if (state is null) return fail(ConfigErrorKind.invalidState);
    static foreach (i, canonical; ConfigPaths!T)
        if (path == canonical)
        {
            foreach (record; mixin("state.option" ~ i.stringof ~ ".sorted"))
            {
                scope auto view = definitionView(canonical, record);
                deliver!sink(view);
            }
            return ConfigError.init;
        }
    return fail(ConfigErrorKind.unknownOption);
}

/// Borrows one definition through its checked owner-bound handle.
ConfigError visitDefinition(alias sink, T, A)(scope ref const ConfigSnapshot!(T, A) snapshot,
    DefinitionRef handle)
{
    scope auto state = snapshot.state;
    if (state is null) return fail(ConfigErrorKind.invalidState);
    if (handle.owner != state.owner) return fail(ConfigErrorKind.wrongOwner);
    static foreach (i, canonical; ConfigPaths!T)
        foreach (record; mixin("state.option" ~ i.stringof ~ ".sorted"))
            if (record.ref_ == handle)
            {
                scope auto view = definitionView(canonical, record);
                deliver!sink(view);
                return ConfigError.init;
            }
    return fail(ConfigErrorKind.invalidHandle);
}

/// Borrows one registered source without allocating a visitor.
ConfigError visitSource(alias sink, T, A)(scope ref const ConfigSnapshot!(T, A) snapshot,
    SourceRef handle)
{
    scope auto state = snapshot.state;
    auto error = sourceError(state, handle);
    if (error.kind == ConfigErrorKind.unknownSource) return fail(ConfigErrorKind.invalidHandle);
    if (error.kind != ConfigErrorKind.none) return error;
    scope auto view = sourceView(lookupSource(state, handle));
    deliver!sink(view);
    return ConfigError.init;
}

/// Visits registered sources in unsigned identity-byte order.
ConfigError visitSources(alias sink, T, A)(scope ref const ConfigSnapshot!(T, A) snapshot)
{
    scope auto state = snapshot.state;
    if (state is null) return fail(ConfigErrorKind.invalidState);
    foreach (source; state.sources)
    {
        scope auto view = sourceView(source);
        deliver!sink(view);
    }
    return ConfigError.init;
}

@("wired.config.core.independentStringCopyLifetime")
@safe unittest
{
    struct Settings { string text; Nullable!string maybe; }
    Settings copied;
    {
        auto created = ConfigBuilder!Settings.create();
        auto builder = created.takeValue();
        auto registered = builder.registerSource(SourceId("u"), ConfigSourceKind.userFile, null);
        auto mutableText = "owned ordinary".dup;
        auto mutableNullable = "owned nullable".dup;
        ConfigInput!Settings input;
        input.text.supplied = input.maybe.supplied = true;
        input.text.value = (() @trusted { return cast(string) mutableText; })();
        input.maybe.value = (() @trusted { return cast(string) mutableNullable; })();
        auto captured = captureInput!Settings(input);
        auto capsule = captured.takeValue();
        auto originalPayload = &capsule.state.input.text.value[0];
        mutableText[0] = 'X';
        mutableNullable[0] = 'X';
        assert(builder.submitOwned(registered.value, capsule).kind == ConfigErrorKind.none && capsule.consumed);
        auto resolved = builder.resolve();
        auto snapshot = resolved.takeValue();
        assert(snapshot.visitOption!((scope ref const view) {
            static if (is(typeof(view) == const(OptionView!string)))
                assert(&view.effective.get[0] == originalPayload && view.effective.get == "owned ordinary");
        })("text").kind == ConfigErrorKind.none);
        bool observedNullable;
        assert(snapshot.visitOption!((scope ref const view) {
            static if (is(typeof(view) == const(OptionView!(Nullable!string))))
            {
                assert(!view.effective.get.isNull && view.effective.get.get == "owned nullable");
                observedNullable = true;
            }
        })("maybe").kind == ConfigErrorKind.none && observedNullable);
        auto result = snapshot.copyConfig();
        assert(result.hasValue);
        copied = result.takeValue();
        assert(&copied.text[0] != originalPayload);
    }
    GC.collect();
    assert(copied.text == "owned ordinary" && !copied.maybe.isNull
        && copied.maybe.get == "owned nullable");
}

@("wired.config.core.unsignedIdentityOrderingAndRetiredHandles")
@safe unittest
{
    struct Settings { int width = 4; }
    SourceRef saved;
    {
        auto created = ConfigBuilder!Settings.create();
        auto builder = created.takeValue();
        foreach (text; ["\xff", "aa", "\x80", "a", "\x7f"])
        {
            auto registered = builder.registerSource(SourceId(text), ConfigSourceKind.custom, null);
            assert(registered.hasValue);
            saved = registered.value;
            ConfigInput!Settings input;
            input.width = DefinitionSlot!int(true, 8);
            assert(builder.submitBorrowed(saved, input).kind == ConfigErrorKind.none);
        }
        auto resolved = builder.resolve();
        auto snapshot = resolved.takeValue();
        string[6] expected = ["$builtin", "a", "aa", "\x7f", "\x80", "\xff"];
        size_t index;
        assert(snapshot.visitSources!((scope ref const SourceView view) {
            assert(byteText(view.id) == expected[index++]);
        })().kind == ConfigErrorKind.none && index == 6);
        index = 1;
        assert(snapshot.visitDefinitions!((scope ref const DefinitionView!int view) {
            if (view.disposition == DefinitionDisposition.conflicting)
                assert(byteText(view.sourceId) == expected[index++]);
            else assert(view.disposition == DefinitionDisposition.overridden && view.value.get == 4);
        })("width").kind == ConfigErrorKind.none && index == 6);
    }
    auto created = ConfigBuilder!Settings.create();
    auto builder = created.takeValue();
    ConfigInput!Settings empty;
    assert(builder.submitBorrowed(saved, empty).kind == ConfigErrorKind.wrongOwner);
}

@("wired.config.core.minimumPriorityPermutationOracle")
@safe unittest
{
    struct Settings { int width = 4; }
    foreach (permutation; [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]])
    {
        auto created = ConfigBuilder!Settings.create();
        auto builder = created.takeValue();
        foreach (index; permutation)
        {
            auto registered = builder.registerSource(SourceId(["u", "p", "q"][index]),
                ConfigSourceKind.custom, null, [1000u, 500u, 1000u][index]);
            ConfigInput!Settings input;
            input.width = DefinitionSlot!int(true, [8, 4, 12][index]);
            assert(builder.submitBorrowed(registered.value, input).kind == ConfigErrorKind.none);
        }
        auto resolved = builder.resolve();
        auto snapshot = resolved.takeValue();
        assert(snapshot.visitOption!((scope ref const OptionView!int view) {
            assert(view.status == OptionStatus.resolved && view.selectedPriority == 500
                && view.effective.get == 4 && view.definitions.length == 4 && view.contributors.length == 1);
        })("width").kind == ConfigErrorKind.none);
        size_t index;
        assert(snapshot.visitDefinitions!((scope ref const DefinitionView!int view) {
            assert(byteText(view.sourceId) == ["p", "q", "u", "$builtin"][index++]);
        })("width").kind == ConfigErrorKind.none && index == 4);
    }
}

version (unittest)
private struct FailingConfigAllocator
{
    static long remaining = -1;
    static ulong attempts;
    static long liveNative;
    static void reset(long after) @safe nothrow @nogc { remaining = after; attempts = 0; }
    static bool denied() @safe nothrow @nogc
    {
        ++attempts;
        if (remaining == 0) return true;
        if (remaining > 0) --remaining;
        return false;
    }
    static void* allocate(size_t bytes) @safe nothrow @nogc
    {
        if (denied()) return null;
        auto result = ConfigAllocator.allocate(bytes);
        if (result !is null) ++liveNative;
        return result;
    }
    static void deallocate(void* address) @safe nothrow @nogc
    {
        if (address !is null) --liveNative;
        ConfigAllocator.deallocate(address);
    }
    static void* allocateCopy(size_t bytes) @safe
    {
        return denied() ? null : ConfigAllocator.allocateCopy(bytes);
    }
    static void deallocateCopy(void* address) @safe nothrow @nogc
    {
        ConfigAllocator.deallocateCopy(address);
    }
}

@("wired.config.core.realAllocationRollbackCaptureAndRegistration")
@safe unittest
{
    alias A = FailingConfigAllocator;
    struct Settings { string text = "default"; }
    bool captureSucceeded, registrationSucceeded, creationSucceeded;
    for (long failure = 0; failure < 128 && !creationSucceeded; ++failure)
    {
        A.reset(failure);
        {
            auto created = ConfigBuilder!(Settings, A).create();
            creationSucceeded = created.hasValue;
            if (!creationSucceeded) assert(created.error.kind == ConfigErrorKind.allocationFailed);
        }
        assert(A.liveNative == 0);
    }
    assert(creationSucceeded);
    ConfigInput!Settings input;
    input.text = DefinitionSlot!string(true, "captured");
    for (long failure = 0; failure < 128 && !captureSucceeded; ++failure)
    {
        A.reset(failure);
        {
            auto captured = captureInput!(Settings, A)(input);
            captureSucceeded = captured.hasValue;
            if (!captureSucceeded) assert(captured.error.kind == ConfigErrorKind.allocationFailed);
            assert(input.text.supplied && input.text.value == "captured");
        }
        assert(A.liveNative == 0);
    }
    assert(captureSucceeded);
    for (long failure = 0; failure < 128 && !registrationSucceeded; ++failure)
    {
        A.reset(-1);
        {
            auto created = ConfigBuilder!(Settings, A).create();
            auto builder = created.takeValue();
            auto before = builder.usage;
            auto live = A.liveNative;
            A.reset(failure);
            auto registered = builder.registerSource(SourceId("u"), ConfigSourceKind.userFile, "file");
            registrationSucceeded = registered.hasValue;
            if (!registrationSucceeded)
            {
                assert(registered.error.kind == ConfigErrorKind.allocationFailed);
                assert(builder.usage == before && A.liveNative == live);
                A.reset(-1);
                assert(builder.registerSource(SourceId("u"), ConfigSourceKind.userFile, "file").hasValue);
            }
            A.reset(-1);
        }
        assert(A.liveNative == 0);
    }
    assert(registrationSucceeded);
    A.reset(-1);
}

@("wired.config.core.realAllocationRollbackOwnedTransferAndResolve")
@safe unittest
{
    alias A = FailingConfigAllocator;
    static ValidationResult rejectBad(in string value) @safe pure nothrow
    {
        return value == "bad" ? ValidationResult.reject("notBad", "bad text") : ValidationResult.accept();
    }
    struct Settings { @(ConfigCheck!rejectBad()) string text = "default"; }
    bool submitSucceeded, resolveSucceeded;
    for (long failure = 0; failure < 128 && !submitSucceeded; ++failure)
    {
        A.reset(-1);
        {
            auto created = ConfigBuilder!(Settings, A).create();
            auto builder = created.takeValue();
            auto registered = builder.registerSource(SourceId("u"), ConfigSourceKind.userFile, null);
            ConfigInput!Settings input;
            input.text = DefinitionSlot!string(true, "bad");
            auto captured = captureInput!(Settings, A)(input);
            auto capsule = captured.takeValue();
            auto payload = &capsule.state.input.text.value[0];
            auto before = builder.usage;
            auto capsuleBefore = capsule.usage;
            auto live = A.liveNative;
            A.reset(failure);
            auto error = builder.submitOwned(registered.value, capsule);
            submitSucceeded = error.kind == ConfigErrorKind.none;
            if (!submitSucceeded)
            {
                assert(error.kind == ConfigErrorKind.allocationFailed && builder.usage == before
                    && capsule.usage == capsuleBefore && !capsule.consumed && A.liveNative == live);
                assert(&capsule.state.input.text.value[0] == payload);
            }
            else
            {
                assert(capsule.consumed);
                A.reset(-1);
                auto resolved = builder.resolve();
                auto snapshot = resolved.takeValue();
                assert(snapshot.visitDefinitions!((scope ref const DefinitionView!string view) {
                    if (view.disposition == DefinitionDisposition.invalid) assert(&view.value.get[0] == payload);
                })("text").kind == ConfigErrorKind.none);
            }
            A.reset(-1);
        }
        assert(A.liveNative == 0);
    }
    assert(submitSucceeded);
    for (long failure = 0; failure < 128 && !resolveSucceeded; ++failure)
    {
        A.reset(-1);
        {
            auto created = ConfigBuilder!(Settings, A).create();
            auto builder = created.takeValue();
            auto registered = builder.registerSource(SourceId("u"), ConfigSourceKind.userFile, null);
            ConfigInput!Settings input;
            input.text = DefinitionSlot!string(true, "bad");
            assert(builder.submitBorrowed(registered.value, input).kind == ConfigErrorKind.none);
            auto before = builder.usage;
            auto live = A.liveNative;
            A.reset(failure);
            auto resolved = builder.resolve();
            resolveSucceeded = resolved.hasValue;
            if (!resolveSucceeded)
            {
                assert(resolved.error.kind == ConfigErrorKind.allocationFailed && builder.collecting
                    && builder.usage == before && A.liveNative == live);
                A.reset(-1);
                ConfigInput!Settings empty;
                assert(builder.submitBorrowed(registered.value, empty).kind == ConfigErrorKind.none);
                auto retry = builder.resolve();
                assert(retry.hasValue);
                auto snapshot = retry.takeValue();
                assert(snapshot.visitOption!((scope ref const OptionView!string view) {
                    assert(view.status == OptionStatus.invalidSelectedValue
                        && view.diagnostic.get.code == "notBad" && view.diagnostic.get.detail == "bad text");
                })("text").kind == ConfigErrorKind.none);
            }
            else assert(builder.consumed);
            A.reset(-1);
        }
        assert(A.liveNative == 0);
    }
    assert(resolveSucceeded);
    A.reset(-1);
}

@("wired.config.core.realAllocationRollbackIndependentCopy")
@safe unittest
{
    alias A = FailingConfigAllocator;
    struct Settings { string text; Nullable!string maybe; }
    bool succeeded;
    for (long failure = 0; failure < 128 && !succeeded; ++failure)
    {
        A.reset(-1);
        Settings copied;
        {
            auto created = ConfigBuilder!(Settings, A).create();
            auto builder = created.takeValue();
            auto registered = builder.registerSource(SourceId("u"), ConfigSourceKind.userFile, null);
            ConfigInput!Settings input;
            input.text = DefinitionSlot!string(true, "ordinary");
            input.maybe.supplied = true;
            input.maybe.value = "nullable";
            assert(builder.submitBorrowed(registered.value, input).kind == ConfigErrorKind.none);
            auto resolved = builder.resolve();
            auto snapshot = resolved.takeValue();
            auto before = snapshot.usage;
            auto live = A.liveNative;
            A.reset(failure);
            auto result = snapshot.copyConfig();
            succeeded = result.hasValue;
            if (!succeeded)
                assert(result.error.kind == ConfigErrorKind.allocationFailed
                    && snapshot.usage == before && A.liveNative == live);
            else copied = result.takeValue();
            A.reset(-1);
        }
        assert(A.liveNative == 0);
        if (succeeded) assert(copied.text == "ordinary" && copied.maybe.get == "nullable");
    }
    assert(succeeded);
    A.reset(-1);
}

@("wired.config.core.realAllocationRollbackBorrowedBatch")
@safe unittest
{
    alias A = FailingConfigAllocator;
    struct Settings { string first; string second; }
    bool succeeded;
    for (long failure = 0; failure < 128 && !succeeded; ++failure)
    {
        A.reset(-1);
        {
            auto created = ConfigBuilder!(Settings, A).create();
            auto builder = created.takeValue();
            auto registered = builder.registerSource(SourceId("u"), ConfigSourceKind.userFile, null);
            ConfigInput!Settings input;
            input.first = DefinitionSlot!string(true, "one");
            input.second = DefinitionSlot!string(true, "two");
            auto before = builder.usage;
            auto live = A.liveNative;
            A.reset(failure);
            auto error = builder.submitBorrowed(registered.value, input);
            succeeded = error.kind == ConfigErrorKind.none;
            if (!succeeded)
                assert(error.kind == ConfigErrorKind.allocationFailed && builder.usage == before
                    && A.liveNative == live);
            assert(input.first.supplied && input.first.value == "one"
                && input.second.supplied && input.second.value == "two");
            A.reset(-1);
        }
        assert(A.liveNative == 0);
    }
    assert(succeeded);
    A.reset(-1);
}

@("wired.config.core.batchBudgetFailureCommitsNothing")
@safe unittest
{
    struct Settings { int width = 4; int height = 5; }
    ConfigLimits limits;
    limits.maxPayloadBytes = 51;
    auto created = ConfigBuilder!Settings.create(limits);
    auto builder = created.takeValue();
    auto registered = builder.registerSource(SourceId("u"), ConfigSourceKind.userFile, null);
    assert(builder.usage.payloadBytes == 39);
    ConfigInput!Settings input;
    input.width = DefinitionSlot!int(true, 8);
    input.height = DefinitionSlot!int(true, 9);
    assert(builder.submitBorrowed(registered.value, input).kind == ConfigErrorKind.limitExceeded);
    assert(builder.usage.payloadBytes == 39 && builder.usage.definitions == 2);
    input.height.supplied = false;
    assert(builder.submitBorrowed(registered.value, input).kind == ConfigErrorKind.none);
    assert(builder.usage.payloadBytes == 48 && builder.usage.definitions == 3);
}

@("wired.config.core.moveOnlyAndScopedInspection")
@safe unittest
{
    struct Settings { int width; }
    static assert(!__traits(isCopyable, ConfigBuilder!Settings));
    static assert(!__traits(isCopyable, ConfigSnapshot!Settings));
    static assert(!__traits(isCopyable, OwnedConfigInput!Settings));
}

@("wired.config.core.scopedBorrowedStringSurface")
@safe unittest
{
    struct TextSettings { string text; }
    struct NullableSettings { Nullable!string text; }
    struct NumericSettings { int width; }
    static assert(__traits(compiles, (() @safe {
        ConfigSnapshot!TextSettings owner;
        owner.visitOption!((scope ref const OptionView!string view) @safe {
            assert(view.effective.hasValue && view.effective.get == "text");
        })("text");
        owner.visitDefinitions!((scope ref const DefinitionView!string view) @safe {
            assert(view.value.hasValue && view.value.get == "text");
        })("text");
    })()));
    static assert(!__traits(compiles, (() @safe {
        ConfigSnapshot!TextSettings owner;
        const(char)[] escaped;
        owner.visitOption!((scope ref const OptionView!string view) @safe {
            escaped = view.effective.get;
        })("text");
    })()));
    static assert(!__traits(compiles, (() @safe {
        ConfigSnapshot!TextSettings owner;
        const(char)[] escaped;
        owner.visitDefinitions!((scope ref const DefinitionView!string view) @safe {
            escaped = view.value.get;
        })("text");
    })()));
    static assert(__traits(compiles, (() @safe {
        ConfigSnapshot!NullableSettings owner;
        owner.visitOption!((scope ref const OptionView!(Nullable!string) view) @safe {
            if (!view.effective.get.isNull) assert(view.effective.get.get == "text");
        })("text");
        owner.visitDefinitions!((scope ref const DefinitionView!(Nullable!string) view) @safe {
            if (!view.value.get.isNull) assert(view.value.get.get == "text");
        })("text");
    })()));
    static assert(!__traits(compiles, (() @safe {
        ConfigSnapshot!NullableSettings owner;
        const(char)[] escaped;
        owner.visitOption!((scope ref const OptionView!(Nullable!string) view) @safe {
            if (!view.effective.get.isNull) escaped = view.effective.get.get;
        })("text");
    })()));
    static assert(!__traits(compiles, (() @safe {
        ConfigSnapshot!NullableSettings owner;
        const(char)[] escaped;
        owner.visitDefinitions!((scope ref const DefinitionView!(Nullable!string) view) @safe {
            if (!view.value.get.isNull) escaped = view.value.get.get;
        })("text");
    })()));
    static assert(__traits(compiles, (() @safe {
        ConfigSnapshot!NumericSettings owner;
        owner.visitOption!((scope ref const OptionView!int view) @safe {
            if (view.diagnostic.hasValue)
            {
                assert(view.diagnostic.get.code == "code");
                assert(view.diagnostic.get.detail == "detail");
            }
        })("width");
        owner.visitSources!((scope ref const SourceView view) @safe {
            assert(view.detail == "detail");
        })();
    })()));
    static assert(!__traits(compiles, (() @safe {
        ConfigSnapshot!NumericSettings owner;
        const(char)[] escaped;
        owner.visitOption!((scope ref const OptionView!int view) @safe {
            if (view.diagnostic.hasValue) escaped = view.diagnostic.get.code;
        })("width");
    })()));
    static assert(!__traits(compiles, (() @safe {
        ConfigSnapshot!NumericSettings owner;
        const(char)[] escaped;
        owner.visitOption!((scope ref const OptionView!int view) @safe {
            if (view.diagnostic.hasValue) escaped = view.diagnostic.get.detail;
        })("width");
    })()));
    static assert(!__traits(compiles, (() @safe {
        ConfigSnapshot!NumericSettings owner;
        const(char)[] escaped;
        owner.visitSources!((scope ref const SourceView view) @safe {
            escaped = view.detail;
        })();
    })()));
}

private struct CopyRecord { CopyRecord* next; void* payload; }
private struct CopyArena(A)
{
    Arena!A records;
    CopyRecord* first;
    bool committed;
    bool text(scope const(char)[] input, out string output)
    {
        if (input.ptr is null) { output = null; return true; }
        if (!input.length) { output = ""; return true; }
        auto record = records.allocate!CopyRecord();
        if (record is null) return false;
        auto payload = A.allocateCopy(input.length);
        if (payload is null) return false;
        record.payload = payload;
        record.next = first;
        first = record;
        output = copyText(payload, input);
        return true;
    }
    void commit() { committed = true; }
    void release()
    {
        if (!committed)
            for (auto record = first; record !is null; record = record.next)
                A.deallocateCopy(record.payload);
        first = null;
        records.release();
    }
}
private bool copyIndependent(V, A)(ref CopyArena!A arena, scope ref const V input, out V output)
{
    static if (is(V == Nullable!N, N))
    {
        if (input.isNull) { output.nullify(); return true; }
        N value;
        if (!copyIndependent(arena, input.get, value)) return false;
        output = value;
        return true;
    }
    else static if (is(V == string)) return arena.text(input, output);
    else { output = input; return true; }
}

private void deliver(alias sink, View)(scope ref const View view)
{
    static assert(is(typeof(sink(view)) == void), "Configuration visitor must return void");
    sink(view);
}
