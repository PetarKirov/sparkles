/** Finite configuration admission, ownership, and eager composition. */
module sparkles.wired.config.core;

import core.stdc.stdlib : malloc, free;
import core.stdc.string : memcpy;
import core.atomic : atomicLoad, cas;
import core.memory : GC;
import std.algorithm.mutation : move;
import std.algorithm.sorting : sort;
import std.meta : AliasSeq, NoDuplicates;
import std.traits : FieldNameTuple, Unqual, OriginalType, hasUDA, TemplateOf,
    TemplateArgsOf, Parameters, isDynamicArray, isStaticArray, isAssociativeArray;
import std.typecons : Nullable;
import sparkles.wired.overlay : WireSection;
import sparkles.wired.config.payload;
import sparkles.wired.config.metadata;
import sparkles.wired.config.key_accounting;
import sparkles.wired.config.borrow : ConfigArrayValueView, ConfigMapValueView,
    ConfigStructValueView, ConfigPresenceView;
import sparkles.wired.config.resolution;
import sparkles.wired.json.codec : Json, aaKeyText;
import sparkles.wired.policy : WireInvalid;
import sparkles.wired.schema : NodeKind;
import sparkles.wired.walk : WireWalk;

struct Atomic {}
struct Submodule {}
struct ListOf(Policy) { alias elementPolicy = Policy; }
struct AttrsOf(Policy) { alias valuePolicy = Policy; }
struct Lines {}
struct NullOr(Policy) { alias containedPolicy = Policy; }
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
enum OptionStatus : ubyte
{
    resolved, conflict, invalidSelectedValue, unresolvedChildren, invalidMergedValue
}
enum DefinitionDisposition : ubyte
{
    overridden, contributing, conflicting, invalid, selected
}

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
    private bool generated;
    bool opEquals(DefinitionRef other) scope const @safe pure nothrow @nogc
        => owner == other.owner && index == other.index && generated == other.generated;
}
struct ContributionRef
{
    private ulong owner;
    private uint index;
    bool opEquals(ContributionRef other) scope const @safe pure nothrow @nogc
        => owner == other.owner && index == other.index;
}
package ContributionRef contributionRef(ulong owner, uint index) @safe pure nothrow @nogc
    => ContributionRef(owner, index);
package DefinitionRef generatedDefinitionRef(ulong owner, uint index) @safe pure nothrow @nogc
    => DefinitionRef(owner, index, true);
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
    uint maxValueNodes = 262_144;
    uint maxResolvedRecords = 65_536;
    uint maxContributions = 262_144;
}
struct ConfigUsage
{
    ulong sources;
    ulong definitions;
    ulong payloadBytes;
    ulong options;
    ulong depth;
    ulong valueNodes;
    ulong resolvedRecords;
    ulong contributions;
}
struct ConfigError
{
    ConfigErrorKind kind;
    const(char)[] path;
    string limit;
    ulong used;
    ulong requested;
    /// Borrowed from the snapshot; valid only while that snapshot remains alive.
    const(const(char)[])[] failedOptions;
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

/** Catch allocation failure without weakening the callback's safety proof. */
package R catchConfigAllocation(R)(scope R delegate() @safe operation, R failure) @safe
{
    import core.exception : OutOfMemoryError;
    static assert(is(R == bool) || is(R == ConfigError));
    // Only the OOM catch needs trust; the callback's body is checked separately.
    return (() @trusted {
        try { return operation(); }
        catch (OutOfMemoryError) { return failure; }
    })();
}
package R catchConfigAllocation(R)(scope R delegate() operation, R failure) @system
{
    import core.exception : OutOfMemoryError;
    try { return operation(); }
    catch (OutOfMemoryError) { return failure; }
}

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
package template ConfigFieldPolicy(T, string name)
{
    alias Explicit = MergePolicy!(T, name);
    static if (!is(Explicit == void)) alias ConfigFieldPolicy = Explicit;
    else static if (is(ConfigFieldType!(T, name) == struct)
        && hasUDA!(ConfigFieldType!(T, name), WireSection))
        alias ConfigFieldPolicy = Submodule;
    else alias ConfigFieldPolicy = Atomic;
}
package template ConfigIsSection(T, string name)
{
    alias V = ConfigFieldType!(T, name);
    alias P = MergePolicy!(T, name);
    enum marked = is(V == struct) && hasUDA!(V, WireSection);
    static assert(policyCompatible!(V, ConfigFieldPolicy!(T, name)),
        T.stringof ~ "." ~ name ~ ": incompatible configuration merge policy");
    static assert(!(marked && is(P == Atomic)),
        T.stringof ~ "." ~ name ~ ": Atomic conflicts with WireSection");
    static assert(!is(P == Submodule) || is(V == struct),
        T.stringof ~ "." ~ name ~ ": Submodule requires a section struct");
    enum ConfigIsSection = is(ConfigFieldPolicy!(T, name) == Submodule);
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
package template CheckPolicy(T, string name)
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
package ValidationResult callCheck(alias predicate, V)(in V value) @safe pure nothrow
{
    return predicate(value);
}
private template validateSchema(T, string prefix = "", Ancestors...)
{
    static assert(is(T == struct), T.stringof ~ ": configuration root/section must be struct");
    static assert(supportedConfigGraph!T, T.stringof ~ ": unsupported ownership or recursive graph");
    static foreach (A; Ancestors)
        static assert(!is(T == A), T.stringof ~ ": cyclic configuration at " ~ prefix);
    static foreach (name; ConfigFieldNames!T)
    {
        static assert(ConfigMemberAdmission!(T, name));
        static if (ConfigIsSection!(T, name))
            static assert(validateSchema!(ConfigFieldType!(T, name), prefix ~ name ~ ".", Ancestors, T));
    }
    static assert(ConfigWireAdmission!(T, T, 0), T.stringof ~ ": invalid original wire schema");
    enum validateSchema = true;
}

private template ConfigMemberAdmission(T, string name)
{
    alias Value = ConfigFieldType!(T, name);
    enum section = ConfigIsSection!(T, name);
    static assert(policyCompatible!(Value, ConfigFieldPolicy!(T, name)),
        T.stringof ~ "." ~ name ~ ": incompatible configuration merge policy");
    static assert(ConfigPolicyAdmission!(Value, ConfigFieldPolicy!(T, name)));
    static if (!is(CheckPolicy!(T, name) == void))
        static assert(__traits(compiles,
            callCheck!(CheckPolicy!(T, name), Value)(Value.init)),
            T.stringof ~ "." ~ name ~ ": check must be @safe pure nothrow and return ValidationResult");
    enum ConfigMemberAdmission = true;
}

package template ConfigWireAdmission(V, Root, size_t site)
{
    alias walk = WireWalk!(Json, Root);
    enum node = walk.node!site;
    static assert(node.kind != NodeKind.converted
        && node.policy.field.onInvalid != WireInvalid.useDefault,
        Root.stringof ~ ": custom conversion/default-on-invalid is unsupported");
    static if (is(V == Nullable!N, N))
        static assert(ConfigWireAdmission!(N, Root, walk.child!(site, 0)));
    else static if (!is(V == string) && (is(V == E[], E) || is(V == E[n], E, size_t n)))
        static assert(ConfigWireAdmission!(Unqual!E, Root, walk.child!(site, 0)));
    else static if (is(V == E[K], E, K))
    {
        enum keySite = walk.child!(site, 0);
        static if (is(K == enum))
        {
            enum injective = () {
                static foreach (i, member; __traits(allMembers, K))
                {{
                    enum key = __traits(getMember, K, member);
                    enum spelling = aaKeyText!(K, Root, keySite)(key);
                    static foreach (j, earlier; __traits(allMembers, K))
                        static if (j < i && key != __traits(getMember, K, earlier))
                            if (spelling == aaKeyText!(K, Root, keySite)(
                                __traits(getMember, K, earlier))) return false;
                }}
                return true;
            }();
            static assert(injective, Root.stringof ~ ": noninjective original enum key spelling");
        }
        static assert(ConfigWireAdmission!(K, Root, keySite));
        static assert(ConfigWireAdmission!(E, Root, walk.child!(site, 1)));
    }
    else static if (is(V == struct))
        static foreach (i, name; ConfigFieldNames!V)
            static assert(ConfigWireAdmission!(ConfigFieldType!(V, name), Root, walk.child!(site, i)));
    enum ConfigWireAdmission = true;
}
private template ConfigPolicyAdmission(V, P)
{
    static if (is(P == Submodule))
    {
        static foreach (name; ConfigFieldNames!V)
            static assert(ConfigMemberAdmission!(V, name));
    }
    else static if (is(P == ListOf!Q, Q))
    {
        static if (is(V == E[], E)) static assert(ConfigPolicyAdmission!(E, Q));
    }
    else static if (is(P == AttrsOf!Q, Q))
    {
        static if (is(V == E[K], E, K)) static assert(ConfigPolicyAdmission!(E, Q));
    }
    else static if (is(P == NullOr!Q, Q))
        static if (is(V == Nullable!N, N)) static assert(ConfigPolicyAdmission!(N, Q));
    enum ConfigPolicyAdmission = true;
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
private uint graphDepth(V)()
{
    static if (is(V == Nullable!N, N)) return graphDepth!N();
    else static if (!is(V == string) && (is(V == E[], E) || is(V == E[n], E, size_t n)))
        return 1 + graphDepth!E();
    else static if (is(V == E[K], E, K)) return 1 + graphDepth!E();
    else static if (is(V == struct))
    {
        uint depth;
        static foreach (name; ConfigFieldNames!V)
        {{
            auto memberDepth = 1 + graphDepth!(ConfigFieldType!(V, name))();
            if (memberDepth > depth) depth = memberDepth;
        }}
        return depth;
    }
    else return 0;
}
private uint schemaDepth(T)() => graphDepth!T();

private string[] childPatterns(V, P)(string prefix)
{
    static if (is(P == ListOf!Q, Q))
    {
        static if (is(V == E[], E)) return childPatterns!(E, Q)(prefix ~ "[<index>]");
    }
    else static if (is(P == AttrsOf!Q, Q))
    {
        static if (is(V == E[K], E, K)) return childPatterns!(E, Q)(prefix ~ "[<key>]");
    }
    else static if (is(P == NullOr!Q, Q))
    {
        static if (is(V == Nullable!N, N)) return childPatterns!(N, Q)(prefix);
    }
    else static if (is(P == Submodule))
    {
        string[] paths;
        static foreach (name; ConfigFieldNames!V)
        {{
            enum section = ConfigIsSection!(V, name);
            auto path = prefix ~ "." ~ name;
            static if (!section) paths ~= path;
            paths ~= childPatterns!(ConfigFieldType!(V, name),
                ConfigFieldPolicy!(V, name))(path);
        }}
        return paths;
    }
    return null;
}
private string[] makePatterns(T)(string prefix = "")
{
    string[] paths;
    static foreach (name; ConfigFieldNames!T)
    {{
        static if (ConfigIsSection!(T, name))
            paths ~= makePatterns!(ConfigFieldType!(T, name))(prefix ~ name ~ ".");
        else
        {
            auto path = prefix ~ name;
            paths ~= path;
            paths ~= childPatterns!(ConfigFieldType!(T, name),
                ConfigFieldPolicy!(T, name))(path);
        }
    }}
    return paths;
}
package enum ConfigPaths(T) = makePaths!T();
package enum ConfigLeafCount(T) = ConfigPaths!T.length;
package enum ConfigDepth(T) = schemaDepth!T();
package enum ConfigPatterns(T) = makePatterns!T();
package enum ConfigOptionCount(T) = ConfigPatterns!T.length;
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

private template LeafWireSite(Root, string path, S = Root, size_t site = 0)
{
    alias walk = WireWalk!(Json, Root);
    enum dot = dotPosition(path);
    enum field = path[0 .. dot];
    private size_t ordinal()
    {
        static foreach (i, name; ConfigFieldNames!S)
            if (name == field) return i;
        assert(false);
    }
    enum child = walk.child!(site, ordinal());
    static if (dot == path.length)
        enum LeafWireSite = child;
    else
        enum LeafWireSite = LeafWireSite!(Root, path[dot + 1 .. $],
            ConfigFieldType!(S, field), child);
}
private string metadataPath(string path) @safe pure
{
    string result;
    foreach (c; path) result ~= c == '.' ? ".members." : [c];
    return result;
}

struct DefinitionSlot(V)
{
    bool supplied;
    V value;
    ConfigPresence!V presence;
    this(bool supplied, V value)
    {
        this.supplied = supplied;
        this.value = value;
        if (supplied) presence = fullPresence!V(value);
    }
    this(bool supplied, V value, ConfigPresence!V presence)
    {
        this.supplied = supplied;
        this.value = value;
        this.presence = presence;
    }
}
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
        else static if (supportedScalar!(ConfigFieldType!(T, name)))
            mixin("LeafDefinitionMetadata " ~ name ~ ";");
        else mixin("CollectionDefinitionMetadata!(ConfigFieldType!(T, \"" ~ name ~ "\")) " ~ name ~ ";");
}

/// Full typed construction explicitly supplies every declared option.
ConfigInput!T fullConfigInput(T)(return scope ref T value)
{
    ConfigInput!T input;
    static foreach (name; ConfigFieldNames!T)
    {
        static if (ConfigIsSection!(T, name))
            __traits(getMember, input, name) = fullConfigInput(__traits(getMember, value, name));
        else
        {
            __traits(getMember, input, name).supplied = true;
            __traits(getMember, input, name).value = __traits(getMember, value, name);
            __traits(getMember, input, name).presence = fullPresence(__traits(getMember, value, name));
        }
    }
    return input;
}

/** Stateless native allocation seam. Templates infer attributes for adapters. */
package struct ConfigAllocator
{
    static void* allocate(size_t bytes) @trusted nothrow @nogc { return malloc(bytes); }
    static void deallocate(void* address) @trusted nothrow @nogc { free(address); }
    static void* allocateCopy(size_t bytes) @trusted
    {
        import core.exception : OutOfMemoryError;
        try { return GC.malloc(bytes); }
        catch (OutOfMemoryError) { return null; }
    }
    static void deallocateCopy(void* address) @trusted nothrow @nogc { GC.free(address); }
}
private struct Allocation { Allocation* next; }
package struct Arena(A)
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
        if (!registerArenaMemory(memory, bytes + overhead))
        {
            A.deallocate(memory);
            return null;
        }
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
        X initialValue;
        *value = initialValue;
        return value;
    }
    X[] array(X)(size_t count)
    {
        if (!count) return null;
        if (count > size_t.max / X.sizeof) return null;
        auto raw = allocateBytes(count * X.sizeof, X.alignof);
        if (raw is null) return null;
        auto values = typedSlice!X(raw, count);
        foreach (ref item; values)
        {
            X initialValue;
            item = initialValue;
        }
        return values;
    }
    X[] nonNullArray(X)(size_t count)
    {
        auto storage = array!X(count ? count : 1);
        return storage.ptr is null ? null : storage[0 .. count];
    }
    bool nonNullArray(X)(out X[] result)
    {
        result = nonNullArray!X(0);
        return result.ptr !is null;
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
            unregisterArenaMemory(block);
            A.deallocate(block);
            block = next;
        }
    }
}
private bool registerArenaMemory(void* memory, size_t size) @trusted
{
    import core.exception : OutOfMemoryError;
    try { GC.addRange(memory, size); return true; }
    catch (OutOfMemoryError) { return false; }
}
private void unregisterArenaMemory(void* memory) @trusted nothrow @nogc
{
    GC.removeRange(memory);
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
        || !limits.maxOptions || !limits.maxDepth || !limits.maxValueNodes
        || !limits.maxResolvedRecords || !limits.maxContributions)
        return fail(ConfigErrorKind.invalidLimits);
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
    error = checkedCharge(retained ? usage.depth : 0, retained ? 0 : usage.depth,
        limits.maxDepth, "maxDepth");
    if (error.kind != ConfigErrorKind.none) return error;
    error = checkedCharge(retained ? usage.valueNodes : 0, retained ? 0 : usage.valueNodes,
        limits.maxValueNodes, "maxValueNodes");
    if (error.kind != ConfigErrorKind.none) return error;
    error = checkedCharge(retained ? usage.resolvedRecords : 0, retained ? 0 : usage.resolvedRecords,
        limits.maxResolvedRecords, "maxResolvedRecords");
    if (error.kind != ConfigErrorKind.none) return error;
    return checkedCharge(retained ? usage.contributions : 0, retained ? 0 : usage.contributions,
        limits.maxContributions, "maxContributions");
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
private const(ConfigPresence!V) slotPresence(V)(return scope ref const DefinitionSlot!V slot)
{
    static if (supportedScalar!V) return fullPresence!V(slot.value);
    else return slot.presence;
}
private ConfigError validateLeaf(V, M, P = Atomic)(scope ref const DefinitionSlot!V slot,
    scope ref const M metadata, string path)
{
    if (!slot.supplied)
    {
        static if (__traits(hasMember, M, "branches"))
            if (!branchMetadataInert(metadata.branches)) return fail(ConfigErrorKind.invalidMetadata, path);
        return hasOverrides(metadata) ? fail(ConfigErrorKind.invalidMetadata, path) : ConfigError.init;
    }
    if ((!metadata.localId.isNull && !validIdentity(metadata.localId.get.bytes))
        || (!metadata.location.isNull
            && (!metadata.location.get.line || !metadata.location.get.column)))
        return fail(ConfigErrorKind.invalidMetadata, path);
    auto presence = slotPresence(slot);
    if (!validPresence!(V, P)(slot.value, presence))
        return fail(ConfigErrorKind.invalidMetadata, path);
    static if (__traits(hasMember, M, "branches"))
        if (!validBranchMetadata!(V, P)(slot.value, presence, metadata.branches))
            return fail(ConfigErrorKind.invalidMetadata, path);
    if (!validGraph!(V, P)(slot.value, presence)) return fail(ConfigErrorKind.invalidValue, path);
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
    {{
        if (!cloneLeafMetadata(arena, mixin("input." ~ metadataPath(path)),
                mixin("output." ~ metadataPath(path)), identities)) return false;
        static if (__traits(hasMember, typeof(mixin("input." ~ metadataPath(path))), "branches"))
            if (!captureBranchMetadata(arena, mixin("input." ~ metadataPath(path) ~ ".branches"),
                mixin("output." ~ metadataPath(path) ~ ".branches"))) return false;
    }}
    return true;
}

private struct CapsuleState(T, A)
{
    Arena!A arena;
    ConfigInput!T input;
    DefinitionMetadata!T metadata;
    ConfigLimits limits;
    ConfigUsage usage;
    GraphKeyRecord* keys;
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

package ConfigError captureArray(T, A, X)(ref OwnedConfigInput!(T, A) owner,
    size_t count, bool nonNull, out X[] result)
{
    if (owner.state is null || owner.state.finished) return fail(ConfigErrorKind.invalidState);
    result = nonNull ? owner.state.arena.nonNullArray!X(count) : owner.state.arena.array!X(count);
    return count || nonNull
        ? (result.ptr is null ? fail(ConfigErrorKind.allocationFailed) : ConfigError.init)
        : ConfigError.init;
}
package ConfigError captureMapEmpty(T, A, K, V)(ref OwnedConfigInput!(T, A) owner,
    ref V[K] result)
{
    if (owner.state is null || owner.state.finished) return fail(ConfigErrorKind.invalidState);
    auto keeper = owner.state.arena.allocate!(V[K])();
    if (keeper is null) return fail(ConfigErrorKind.allocationFailed);
    return catchConfigAllocation(() {
        (*keeper)[K.init] = V.init;
        (*keeper).remove(K.init);
        result = *keeper;
        return ConfigError.init;
    }, fail(ConfigErrorKind.allocationFailed));
}
package ConfigError captureMapEntry(T, A, K, V)(ref OwnedConfigInput!(T, A) owner,
    ref V[K] result, K key, V value)
{
    if (owner.state is null || owner.state.finished) return fail(ConfigErrorKind.invalidState);
    return catchConfigAllocation(() {
        result[key] = value;
        return ConfigError.init;
    }, fail(ConfigErrorKind.allocationFailed));
}
package string configKeyText(K, Root, size_t site)(K key)
{
    static if (is(K == string)) return key;
    else static foreach (member; __traits(allMembers, K))
    {{
        enum declared = __traits(getMember, K, member);
        enum spelling = aaKeyText!(K, Root, site)(declared);
        if (key == declared) return spelling;
    }}
    assert(false, "undeclared configuration enum key");
}
package ConfigError captureCanonicalKey(Root, size_t site, T, A, K)(
    ref OwnedConfigInput!(T, A) owner, scope K key, out string captured)
{
    if (owner.state is null || owner.state.finished) return fail(ConfigErrorKind.invalidState);
    auto spelling = configKeyText!(K, Root, site)(key);
    for (auto record = owner.state.keys; record !is null; record = record.next)
        if (record.spelling == spelling) { captured = record.spelling; return ConfigError.init; }
    auto record = owner.state.arena.allocate!GraphKeyRecord();
    if (record is null || !owner.state.arena.text(spelling, record.spelling))
        return fail(ConfigErrorKind.allocationFailed);
    record.next = owner.state.keys;
    owner.state.keys = record;
    captured = record.spelling;
    return ConfigError.init;
}
package ConfigError captureDefaultGraph(Root, size_t site, T, A, V)(
    ref OwnedConfigInput!(T, A) owner, scope ref const V original, out V captured,
    out ConfigPresence!V presence)
{
    if (owner.state is null || owner.state.finished) return fail(ConfigErrorKind.invalidState);
    auto full = fullPresence(original);
    return captureGraph!(V, Atomic, Root, site)(owner.state.arena, original, full,
        captured, presence, owner.state.keys)
        ? ConfigError.init : fail(ConfigErrorKind.allocationFailed);
}
private ConfigError capsuleUsage(T)(scope ref const ConfigInput!T input,
    scope ref const DefinitionMetadata!T metadata, out ConfigUsage usage)
{
    usage.options = ConfigOptionCount!T;
    usage.depth = ConfigDepth!T;
    static foreach (pattern; ConfigPatterns!T)
        if (!addBytes(usage.payloadBytes, pattern.length))
            return fail(ConfigErrorKind.arithmeticOverflow, pattern);
    static foreach (path; SortedPaths!T)
    {{
        alias Site = LeafSite!(T, path);
        auto error = validateLeaf!(Site.Value, typeof(mixin("metadata." ~ metadataPath(path))),
            ConfigFieldPolicy!(Site.Parent, Site.name))(
            mixin("input." ~ path), mixin("metadata." ~ metadataPath(path)), path);
        if (error.kind != ConfigErrorKind.none) return error;
    }}
    CanonicalKeyAccounting keyAccounting;
    static foreach (pattern; ConfigPatterns!T) keyAccounting.seed(pattern);
    if (keyAccounting.allocationFailed) return fail(ConfigErrorKind.allocationFailed);
    static foreach (i, path; ConfigPaths!T)
    {{
        auto error = chargeCapsuleLeaf!(T, path, i)(
            mixin("input." ~ path), mixin("metadata." ~ metadataPath(path)),
            input, metadata, usage, keyAccounting);
        if (error.kind != ConfigErrorKind.none) return error;
    }}
    return ConfigError.init;
}
private ConfigError chargeCapsuleLeaf(T, string path, size_t index, V, M)(
    scope ref const DefinitionSlot!V slot, scope ref const M md,
    scope ref const ConfigInput!T input, scope ref const DefinitionMetadata!T metadata,
    ref ConfigUsage usage, ref CanonicalKeyAccounting keyAccounting)
{
    if (!slot.supplied) return ConfigError.init;
    if (!addBytes(usage.definitions, 1))
        return fail(ConfigErrorKind.arithmeticOverflow, path);
    alias Site = LeafSite!(T, path);
    auto presence = slotPresence(slot);
    ulong bytes, nodes;
    if (!measureGraph!(V, ConfigFieldPolicy!(Site.Parent, Site.name))(
        slot.value, presence, bytes, nodes)
        || !chargeGraphKeys!(V, ConfigFieldPolicy!(Site.Parent, Site.name), T,
            LeafWireSite!(T, path))(slot.value, presence, keyAccounting, bytes)
        || !addBytes(usage.payloadBytes, bytes) || !addBytes(usage.valueNodes, nodes))
        return fail(keyAccounting.allocationFailed ? ConfigErrorKind.allocationFailed
            : ConfigErrorKind.arithmeticOverflow, path);
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

package ConfigError preflightInput(T)(scope ref const ConfigInput!T input,
    scope ref const DefinitionMetadata!T metadata, ConfigLimits limits,
    ulong exactBytes, ulong exactNodes, ulong canonicalBytes)
{
    auto error = validateLimits(limits);
    if (error.kind != ConfigErrorKind.none) return error;
    ConfigUsage usage;
    usage.options = ConfigOptionCount!T;
    usage.depth = ConfigDepth!T;
    usage.valueNodes = exactNodes;
    usage.payloadBytes = exactBytes;
    if (!addBytes(usage.payloadBytes, canonicalBytes))
        return fail(ConfigErrorKind.arithmeticOverflow);
    static foreach (pattern; ConfigPatterns!T)
        if (!addBytes(usage.payloadBytes, pattern.length))
            return fail(ConfigErrorKind.arithmeticOverflow, pattern);
    static foreach (i, path; ConfigPaths!T)
    {{
        with (mixin("metadata." ~ metadataPath(path)))
        {
            if (!mixin("input." ~ path ~ ".supplied"))
            {
                if (hasOverrides(mixin("metadata." ~ metadataPath(path))))
                    return fail(ConfigErrorKind.invalidMetadata, path);
                static if (__traits(hasMember, typeof(mixin("metadata." ~ metadataPath(path))), "branches"))
                    if (!branchMetadataInert(branches)) return fail(ConfigErrorKind.invalidMetadata, path);
            }
            else
            {
                if ((!localId.isNull && !validIdentity(localId.get.bytes))
                    || (!location.isNull && (!location.get.line || !location.get.column)))
                    return fail(ConfigErrorKind.invalidMetadata, path);
                if (!addBytes(usage.definitions, 1))
                    return fail(ConfigErrorKind.arithmeticOverflow, path);
                if (!localId.isNull)
                {
                    bool seen;
                    static foreach (j, earlier; ConfigPaths!T)
                        static if (j < i)
                            if (mixin("input." ~ earlier ~ ".supplied")
                                && !mixin("metadata." ~ metadataPath(earlier) ~ ".localId.isNull")
                                && compareBytes(mixin("metadata." ~ metadataPath(earlier) ~ ".localId.get.bytes"),
                                    localId.get.bytes) == 0) seen = true;
                    if (!seen && !addBytes(usage.payloadBytes, localId.get.bytes.length))
                        return fail(ConfigErrorKind.arithmeticOverflow, path);
                }
            }
        }
    }}
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
    {{
        if (mixin("input." ~ path ~ ".supplied"))
        {
            alias Site = LeafSite!(T, path);
            auto presence = slotPresence(mixin("input." ~ path));
            if (!captureGraph!(Site.Value, ConfigFieldPolicy!(Site.Parent, Site.name),
                T, LeafWireSite!(T, path))(owner.state.arena,
                mixin("input." ~ path ~ ".value"), presence,
                mixin("owner.state.input." ~ path ~ ".value"),
                mixin("owner.state.input." ~ path ~ ".presence"), owner.state.keys))
                return errorResult!Owner(fail(ConfigErrorKind.allocationFailed));
            mixin("owner.state.input." ~ path ~ ".supplied") = true;
        }
    }}
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
package struct SourceRecord
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
    else static if (!is(V == string) && (is(V == E[], E) || is(V == E[n], E, size_t n)))
        alias ConfigBorrowedValue = ConfigArrayValueView!(Unqual!E);
    else static if (is(V == E[K], E, K))
        alias ConfigBorrowedValue = ConfigMapValueView!(Unqual!K, Unqual!E);
    else static if (is(V == struct))
        alias ConfigBorrowedValue = ConfigStructValueView!V;
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
package ConfigBorrowedValue!V borrowValue(V)(return ref const V original)
    if (is(V == struct) || isStaticArray!V)
{
    static if (is(V == Nullable!N, N))
    {
        ConfigBorrowedValue!V borrowed;
        borrowed.null_ = original.isNull;
        if (!original.isNull) borrowed.payload_ = borrowValue!N(original.get);
        return borrowed;
    }
    else static if (is(V == string)) return original;
    else static if (is(V == struct) || isDynamicArray!V || isStaticArray!V || isAssociativeArray!V)
        return ConfigBorrowedValue!V(original);
    else return original;
}
package ConfigBorrowedValue!V borrowValue(V)(return scope const V original)
    if (!is(V == struct) && !isStaticArray!V)
{
    static if (is(V == string)) return original;
    else static if (isDynamicArray!V || isAssociativeArray!V)
        return ConfigBorrowedValue!V(original);
    else return original;
}
private ConfigValueView!V valueView(V)(return ref const V original)
    if (is(V == struct) || isStaticArray!V)
{
    ConfigValueView!V view;
    view.present_ = true;
    view.payload_ = borrowValue!V(original);
    return view;
}
private ConfigValueView!V valueView(V)(return scope const V original)
    if (!is(V == struct) && !isStaticArray!V)
{
    ConfigValueView!V view;
    view.present_ = true;
    view.payload_ = borrowValue!V(original);
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
    const(ConfigPresence!V)* presence;
    const(ConfigBranchMetadata!V)* metadata;
    DefinitionDisposition disposition;
}
struct ValidationFailureView
{
    const(char)[] path;
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
    const(char)[] path;
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
    const(char)[] path;
    DefinitionRef ref_;
    SourceRef source;
    const(ubyte)[] sourceId;
    const(ubyte)[] localId;
    uint priority;
    int order;
    Nullable!SourceLocation location;
    DefinitionDisposition disposition;
    ConfigValueView!V value;
    ConfigPresenceView!V presence;
    @property DefinitionRef reference() scope const @safe pure nothrow @nogc => ref_;
}

/** One active graph branch, including data owned by an enclosing option. */
struct BranchView(V)
{
    const(char)[] path;
    const(char)[] pattern;
    const(char)[] owningOption;
    bool declaredOption;
    OptionStatus status;
    uint selectedPriority;
    ConfigValueView!V effective;
    const(ContributionRef)[] definitions;
    const(ContributionRef)[] contributors;
    const(const(char)[])[] failedChildren;
    ConfigDiagnosticView diagnostic;
}

/** One original supplied branch. Excluded projections have no active path. */
struct BranchDefinitionView(V)
{
    const(char)[] path;
    const(char)[] pattern;
    const(char)[] originalLocator;
    DefinitionRef parent;
    ContributionRef ref_;
    SourceRef source;
    const(ubyte)[] sourceId;
    const(ubyte)[] localId;
    uint priority;
    int order;
    Nullable!SourceLocation location;
    DefinitionDisposition disposition;
    ConfigValueView!V value;
    ConfigPresenceView!V presence;
    @property ContributionRef reference() scope const @safe pure nothrow @nogc => ref_;
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
    ResolutionNode!V* node;
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
    const(char)[][] failedOptions;
    GraphKeyRecord* keys;
    ResolutionContext!A context;
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

private enum DeclaredResolutionRecords(T) = () {
    ulong count;
    static foreach (name; ConfigFieldNames!T)
        static if (ConfigIsSection!(T, name))
            count += 1 + DeclaredResolutionRecords!(ConfigFieldType!(T, name));
        else
            ++count;
    return count;
}();

private ConfigError resolveDirectSections(Root, S = Root, string prefix = "", A)(
    ref ResolutionContext!A context)
{
    static foreach (name; ConfigFieldNames!S)
    {{
        static if (ConfigIsSection!(S, name))
        {
            alias V = ConfigFieldType!(S, name);
            enum path = prefix ~ name;
            auto error = resolveDirectSections!(Root, V, path ~ ".")(context);
            if (error.kind != ConfigErrorKind.none) return error;
            ResolutionHeader*[ConfigFieldNames!V.length] children;
            static foreach (i, field; ConfigFieldNames!V)
            {{
                alias E = ConfigFieldType!(V, field);
                for (auto h = context.records; h !is null; h = h.next)
                    if (h.path == path ~ "." ~ field && h.nativeType is typeid(E))
                    {
                        children[i] = h;
                        break;
                    }
                assert(children[i] !is null, "Missing resolved direct-section child");
            }}
            auto assembled = context.arena.allocate!V();
            if (assembled is null) return fail(ConfigErrorKind.allocationFailed, path);
            clearGraph(*assembled);
            static foreach (i, field; ConfigFieldNames!V)
            {{
                alias E = ConfigFieldType!(V, field);
                if (children[i].status == OptionStatus.resolved)
                {
                    auto node = (() @trusted => cast(ResolutionNode!E*) children[i])();
                    __traits(getMember, *assembled, field) =
                        (() @trusted => *cast(E*) node.effective)();
                }
            }}
            ResolutionNode!V* node;
            error = resolveSectionCandidate!(V, CheckPolicy!(S, name))(
                context, assembled, children[], path, node);
            if (error.kind != ConfigErrorKind.none) return error;
        }
    }}
    return ConfigError.init;
}

/** A move-only collecting owner. Successful resolution consumes it. */
struct ConfigBuilder(T, A = ConfigAllocator)
    if (supportedConfigGraph!T)
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
        T defaults;
        static foreach (path; SortedPaths!T)
        {{
            alias Site = LeafSite!(T, path);
            alias P = ConfigFieldPolicy!(Site.Parent, Site.name);
            auto presence = fullPresence(mixin("defaults." ~ path));
            if (!validPrototype!(Site.Value, P)() || !validGraph!(Site.Value, P)(
                mixin("defaults." ~ path), presence))
                return errorResult!ConfigBuilder(fail(ConfigErrorKind.invalidValue, path));
        }}
        ConfigUsage usage = ConfigUsage(1, ConfigLeafCount!T, 8, ConfigOptionCount!T, ConfigDepth!T);
        if (ConfigLeafCount!T) usage.payloadBytes += 11;
        CanonicalKeyAccounting keyAccounting;
        static foreach (pattern; ConfigPatterns!T) keyAccounting.seed(pattern);
        if (keyAccounting.allocationFailed)
            return errorResult!ConfigBuilder(fail(ConfigErrorKind.allocationFailed));
        static foreach (pattern; ConfigPatterns!T)
            if (!addBytes(usage.payloadBytes, pattern.length))
                return errorResult!ConfigBuilder(fail(ConfigErrorKind.arithmeticOverflow, pattern));
        static foreach (path; ConfigPaths!T)
        {{
            ulong bytes, nodes;
            alias Site = LeafSite!(T, path);
            if (!chargeFullGraphKeys!(Site.Value, T, LeafWireSite!(T, path))(
                mixin("defaults." ~ path), keyAccounting, usage.payloadBytes))
                return errorResult!ConfigBuilder(fail(keyAccounting.allocationFailed
                    ? ConfigErrorKind.allocationFailed : ConfigErrorKind.arithmeticOverflow, path));
            if (!measureFullGraph(mixin("defaults." ~ path), bytes, nodes)
                || !addBytes(usage.payloadBytes, bytes) || !addBytes(usage.valueNodes, nodes))
                return errorResult!ConfigBuilder(fail(ConfigErrorKind.arithmeticOverflow, path));
        }}
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
            alias Site = LeafSite!(T, path);
            alias V = Site.Value;
            auto definition = retained.arena.allocate!(DefinitionRecord!V)();
            if (definition is null) return errorResult!ConfigBuilder(fail(ConfigErrorKind.allocationFailed));
            definition.ref_ = DefinitionRef(retained.owner, cast(uint) i);
            definition.source = source;
            definition.localId = local;
            definition.priority = builtinPriority;
            definition.order = builtinOrder;
            auto presence = retained.arena.allocate!(ConfigPresence!V)();
            if (presence is null) return errorResult!ConfigBuilder(fail(ConfigErrorKind.allocationFailed));
            auto full = fullPresence(mixin("defaults." ~ path));
            if (!captureGraph!(V, ConfigFieldPolicy!(Site.Parent, Site.name),
                T, LeafWireSite!(T, path))(retained.arena, mixin("defaults." ~ path), full,
                mixin("retained.defaults." ~ path), *presence, retained.keys))
                return errorResult!ConfigBuilder(fail(ConfigErrorKind.allocationFailed));
            definition.presence = presence;
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
            alias Site = LeafSite!(T, path);
            error = validateLeaf!(Site.Value, typeof(mixin("metadata." ~ metadataPath(path))),
                ConfigFieldPolicy!(Site.Parent, Site.name))(
                mixin("input." ~ path), mixin("metadata." ~ metadataPath(path)), path);
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
        ulong count, extra, nodes;
        CanonicalKeyAccounting keyAccounting;
        static foreach (pattern; ConfigPatterns!T) keyAccounting.seed(pattern);
        keyAccounting.seed(state.keys);
        if (keyAccounting.allocationFailed) return fail(ConfigErrorKind.allocationFailed);
        static foreach (i, path; ConfigPaths!T)
        {{
            if (mixin("input." ~ path ~ ".supplied"))
            {
                alias Site = LeafSite!(T, path);
                auto presence = slotPresence(mixin("input." ~ path));
                ulong graphBytes, graphNodes;
                if (!addBytes(count, 1)
                    || !measureGraph!(Site.Value, ConfigFieldPolicy!(Site.Parent, Site.name))(
                        mixin("input." ~ path ~ ".value"), presence, graphBytes, graphNodes)
                    || !chargeGraphKeys!(Site.Value, ConfigFieldPolicy!(Site.Parent, Site.name), T,
                        LeafWireSite!(T, path))(mixin("input." ~ path ~ ".value"), presence,
                            keyAccounting, graphBytes)
                    || !addBytes(extra, graphBytes) || !addBytes(nodes, graphNodes))
                    return fail(keyAccounting.allocationFailed ? ConfigErrorKind.allocationFailed
                        : ConfigErrorKind.arithmeticOverflow, path);
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
        usage = state.usage;
        if (!addBytes(usage.definitions, count)
            || !addBytes(usage.payloadBytes, extra)
            || !addBytes(usage.valueNodes, nodes))
            return fail(ConfigErrorKind.arithmeticOverflow);
        return checkUsage(usage, state.limits);
    }

    ConfigError submitBorrowed()(SourceRef source, scope ref const ConfigInput!T input,
        scope auto ref const DefinitionMetadata!T metadata = DefinitionMetadata!T.init)
    {
        ConfigUsage usage;
        auto error = preflight(source, input, metadata, usage);
        if (error.kind != ConfigErrorKind.none) return error;
        if (usage.definitions == state.usage.definitions) return ConfigError.init;
        // Detached accounting is distinct; the builder preflight already applies its policy.
        ConfigLimits temporaryLimits = ConfigLimits(uint.max, uint.max, ulong.max,
            uint.max, uint.max, uint.max, uint.max, uint.max);
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
                record.presence = &mixin("input.state.input." ~ path ~ ".presence");
                static if (__traits(hasMember, typeof(*metadata), "branches"))
                    record.metadata = &metadata.branches;
                mixin("pending" ~ i.stringof) = record;
            }
        }}
        auto keys = state.keys;
        for (auto original = input.state.keys; original !is null; original = original.next)
        {
            bool found;
            for (auto known = keys; known !is null; known = known.next)
                if (known.spelling == original.spelling) { found = true; break; }
            if (found) continue;
            auto key = temporary.allocate!GraphKeyRecord();
            if (key is null) return fail(ConfigErrorKind.allocationFailed);
            key.spelling = original.spelling;
            key.next = keys;
            keys = key;
        }
        state.arena.absorb(temporary);
        state.arena.absorb(input.state.arena);
        state.identities = identities;
        state.keys = keys;
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
        ConfigResult!Snapshot rejected(ConfigError problem)
        {
            // A rejected transaction releases its arena before the caller sees the error.
            if (!catchConfigAllocation(() {
                    problem.path = problem.path.idup;
                    return true;
                }, false))
                return errorResult!Snapshot(fail(ConfigErrorKind.allocationFailed));
            return errorResult!Snapshot(problem);
        }
        if (state is null) return errorResult!Snapshot(fail(ConfigErrorKind.invalidState));
        auto error = checkedCharge(state.usage.resolvedRecords, DeclaredResolutionRecords!T,
            state.limits.maxResolvedRecords, "maxResolvedRecords");
        if (error.kind != ConfigErrorKind.none) return errorResult!Snapshot(error);
        ResolutionContext!A context;
        scope(exit) context.arena.release();
        context.owner = state.owner;
        context.builtinSource = state.firstSource;
        context.builtinPriority = state.firstSource.priority;
        context.builtinOrder = state.firstSource.order;
        context.usage = state.usage;
        context.limits = state.limits;
        static foreach (pattern; ConfigPatterns!T)
        {
            error = seedResolutionPattern(context, pattern);
            if (error.kind != ConfigErrorKind.none) return rejected(error);
        }
        for (auto key = state.keys; key !is null; key = key.next)
        {
            error = seedResolutionText(context, key.spelling);
            if (error.kind != ConfigErrorKind.none) return rejected(error);
        }
        static foreach (i, path; ConfigPaths!T)
            mixin("OptionStorage!(LeafSite!(T, \"" ~ path ~ "\").Value) pending" ~ i.stringof ~ ";");
        static foreach (i, path; ConfigPaths!T)
        {{
            alias Site = LeafSite!(T, path);
            alias V = Site.Value;
            alias P = ConfigFieldPolicy!(Site.Parent, Site.name);
            scope auto option = &mixin("state.option" ~ i.stringof);
            scope auto pending = &mixin("pending" ~ i.stringof);
            pending.first = option.first;
            pending.last = option.last;
            size_t count;
            for (auto record = option.first; record !is null; record = record.next) ++count;
            pending.sorted = context.arena.array!(DefinitionRecord!V*)(count);
            pending.definitions = context.arena.array!DefinitionRef(count);
            auto inputs = context.arena.array!(ResolutionInput!V)(count);
            if (count && (pending.sorted.ptr is null || pending.definitions.ptr is null
                || inputs.ptr is null))
                return errorResult!Snapshot(fail(ConfigErrorKind.allocationFailed, path));
            size_t at;
            for (auto record = option.first; record !is null; record = record.next)
                pending.sorted[at++] = record;
            sortDefinitions(pending.sorted);
            foreach (j, record; pending.sorted)
            {
                pending.definitions[j] = record.ref_;
                inputs[j].value = record.value;
                inputs[j].presence = record.presence;
                inputs[j].metadata = record.metadata;
                inputs[j].parent = record.ref_;
                inputs[j].source = record.source;
                inputs[j].localId = record.localId;
                inputs[j].priority = record.priority;
                inputs[j].order = record.order;
                inputs[j].location = record.location;
                inputs[j].builtin = record.source.kind == ConfigSourceKind.builtinDefault;
            }
            error = resolveNode!(V, P, T, LeafWireSite!(T, path),
                CheckPolicy!(Site.Parent, Site.name))(context, inputs, path, path, true, pending.node);
            if (error.kind != ConfigErrorKind.none) return rejected(error);
            pending.status = pending.node.header.status;
            pending.selectedPriority = pending.node.header.priority;
            pending.effective = pending.node.effective;
            size_t selectedCount;
            foreach (record; pending.sorted)
                if (record.priority == pending.selectedPriority) ++selectedCount;
            pending.contributors = context.arena.array!DefinitionRef(selectedCount);
            if (selectedCount && pending.contributors.ptr is null)
                return errorResult!Snapshot(fail(ConfigErrorKind.allocationFailed, path));
            at = 0;
            foreach (record; pending.sorted)
                if (record.priority == pending.selectedPriority)
                    pending.contributors[at++] = record.ref_;
        }}
        error = resolveDirectSections!T(context);
        if (error.kind != ConfigErrorKind.none) return rejected(error);
        for (auto h = context.records; h !is null; h = h.next)
            if (h.parent is null)
            {
                error = finishResolution(context, h);
                if (error.kind != ConfigErrorKind.none) return rejected(error);
            }
        error = finishInspection(context);
        if (error.kind != ConfigErrorKind.none) return rejected(error);
        size_t failureCount;
        for (auto failure = context.failures; failure !is null; failure = failure.nextFailure)
            ++failureCount;
        auto failed = context.arena.array!(const(char)[])(failureCount);
        if (failureCount && failed.ptr is null)
            return errorResult!Snapshot(fail(ConfigErrorKind.allocationFailed));
        size_t at;
        for (auto failure = context.failures; failure !is null; failure = failure.nextFailure)
            failed[at++] = failure.path;
        auto sources = context.arena.array!(SourceRecord*)(cast(size_t) state.usage.sources);
        if (sources.ptr is null) return errorResult!Snapshot(fail(ConfigErrorKind.allocationFailed));
        at = 0;
        for (auto record = state.firstSource; record !is null; record = record.next) sources[at++] = record;
        sortSources(sources);
        // Publish only after every semantic branch and retained allocation succeeded.
        static foreach (i, path; ConfigPaths!T)
        {{
            alias Site = LeafSite!(T, path);
            alias P = ConfigFieldPolicy!(Site.Parent, Site.name);
            scope auto pending = &mixin("pending" ~ i.stringof);
            pending.diagnostic = pending.node.header.diagnostic;
            foreach (record; pending.sorted)
            {
                if (record.priority != pending.selectedPriority)
                    record.disposition = DefinitionDisposition.overridden;
                else static if (!is(P == Atomic))
                    record.disposition = DefinitionDisposition.selected;
                else
                {
                    switch (pending.status)
                    {
                        case OptionStatus.resolved: record.disposition = DefinitionDisposition.contributing; break;
                        case OptionStatus.conflict: record.disposition = DefinitionDisposition.conflicting; break;
                        default: record.disposition = DefinitionDisposition.invalid; break;
                    }
                }
            }
            mixin("state.option" ~ i.stringof) = *pending;
        }}
        state.sources = sources;
        state.failedOptions = failed;
        state.usage = context.usage;
        state.arena.absorb(context.arena);
        state.context = context;
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
private DefinitionView!V definitionView(V)(return scope const(char)[] path,
    return scope const DefinitionRecord!V* record)
{
    return DefinitionView!V(path, record.ref_, record.source.ref_, record.source.id,
        record.localId, record.priority, record.order, record.location, record.disposition,
        valueView!V(*record.value), ConfigPresenceView!V(*record.presence));
}

// The admitted schema is finite. Runtime type tags select only these native
// types; the casts remain internal and never become an erased public payload.
private template GraphMemberTypes(V, names...)
{
    static if (names.length == 0)
        alias GraphMemberTypes = AliasSeq!();
    else
        alias GraphMemberTypes = AliasSeq!(
            GraphNativeTypes!(Unqual!(typeof(__traits(getMember, V.init, names[0])))),
            GraphMemberTypes!(V, names[1 .. $]));
}
private template GraphNativeTypes(V)
{
    static if (is(V == Nullable!N, N))
        alias GraphNativeTypes = AliasSeq!(V, GraphNativeTypes!N);
    else static if (!is(V == string)
        && (is(V == E[], E) || is(V == E[n], E, size_t n)))
        alias GraphNativeTypes = AliasSeq!(V, GraphNativeTypes!(Unqual!E));
    else static if (is(V == E[K], E, K))
        alias GraphNativeTypes = AliasSeq!(V, GraphNativeTypes!(Unqual!E));
    else static if (is(V == struct))
        alias GraphNativeTypes = AliasSeq!(V, GraphMemberTypes!(V, FieldNameTuple!V));
    else
        alias GraphNativeTypes = AliasSeq!V;
}
private alias SnapshotNativeTypes(T) = NoDuplicates!(GraphNativeTypes!T);

private const(ResolutionNode!V)* typedResolutionNode(V)(
    return scope const ResolutionHeader* header)
{
    assert(header.nativeType is typeid(V));
    return (() @trusted => cast(const(ResolutionNode!V)*) header)();
}
private const(ResolutionProjection!V)* typedResolutionProjection(V)(
    return scope const ResolutionProjectionHeader* header)
{
    assert(header.nativeType is typeid(V));
    return (() @trusted => cast(const(ResolutionProjection!V)*) header)();
}
private const(ResolutionGenerated!V)* typedResolutionGenerated(V)(
    return scope const ResolutionGeneratedHeader* header)
{
    assert(header.nativeType is typeid(V));
    return (() @trusted => cast(const(ResolutionGenerated!V)*) header)();
}
private OptionView!V optionView(V)(return scope const ResolutionNode!V* node)
{
    OptionView!V view;
    view.path = node.header.path;
    view.status = node.header.status;
    view.selectedPriority = node.header.priority;
    view.definitions = node.header.optionDefinitions;
    view.contributors = node.header.optionContributors;
    if (node.effective !is null) view.effective = valueView!V(*node.effective);
    if (node.header.diagnostic !is null)
        view.diagnostic = diagnosticView(*node.header.diagnostic);
    return view;
}
private BranchView!V branchView(V)(return scope const ResolutionNode!V* node)
{
    BranchView!V view;
    view.path = node.header.path;
    view.pattern = node.header.declaredPattern;
    view.owningOption = node.header.owningOption;
    view.declaredOption = node.header.declaredOption;
    view.status = node.header.status;
    view.selectedPriority = node.header.priority;
    if (node.effective !is null) view.effective = valueView!V(*node.effective);
    view.definitions = node.header.branchDefinitions;
    view.contributors = node.header.branchContributors;
    view.failedChildren = node.header.failedChildPaths;
    if (node.header.diagnostic !is null)
        view.diagnostic = diagnosticView(*node.header.diagnostic);
    return view;
}
private BranchDefinitionView!V branchDefinitionView(V)(
    return scope const ResolutionProjection!V* projection,
    return scope const(char)[] originalLocator)
{
    auto h = &projection.header;
    return BranchDefinitionView!V(h.activePath, h.declaredPattern, originalLocator,
        h.parent, h.ref_, h.source.ref_, h.source.id, h.localId, h.priority,
        h.order, h.location, h.disposition, valueView!V(*projection.value),
        ConfigPresenceView!V(*projection.presence));
}
private DefinitionView!V projectionDefinitionView(V)(
    return scope const ResolutionProjection!V* projection)
{
    auto h = &projection.header;
    return DefinitionView!V(h.activePath, h.parent, h.source.ref_, h.source.id,
        h.localId, h.priority, h.order, h.location, h.disposition,
        valueView!V(*projection.value), ConfigPresenceView!V(*projection.presence));
}
private DefinitionView!V generatedDefinitionView(V)(
    return scope const ResolutionGenerated!V* generated,
    DefinitionDisposition disposition)
{
    auto h = &generated.header;
    return DefinitionView!V(h.path, h.ref_, h.source.ref_, h.source.id,
        immutableBytes(h.localId), h.priority, h.order, Nullable!SourceLocation.init,
        disposition, valueView!V(generated.value), ConfigPresenceView!V(generated.presence));
}
private void deliverNode(alias sink, alias makeView, T)(
    scope const ResolutionHeader* header)
{
    static foreach (V; SnapshotNativeTypes!T)
        if (header.nativeType is typeid(V))
        {
            scope auto view = makeView!V(typedResolutionNode!V(header));
            deliver!sink(view);
            return;
        }
    assert(0, "Resolution header has a type outside its admitted schema");
}
private void deliverProjection(alias sink, T, bool encoded = false)(
    scope const ResolutionProjectionHeader* header, scope const(char)[] original = null)
{
    static foreach (V; SnapshotNativeTypes!T)
        if (header.nativeType is typeid(V))
        {
            static if (sinkAcceptsView!(sink, BranchDefinitionView!V))
            {
                static if (encoded) scope auto locator = original;
                else scope auto locator = originalLocatorText(header.locator);
                scope auto view = branchDefinitionView!V(typedResolutionProjection!V(header), locator);
                deliver!sink(view);
            }
            return;
        }
    assert(0, "Resolution projection has a type outside its admitted schema");
}
private void deliverProjectionDefinition(alias sink, T)(
    scope const ResolutionProjectionHeader* header)
{
    static foreach (V; SnapshotNativeTypes!T)
        if (header.nativeType is typeid(V))
        {
            scope auto view = projectionDefinitionView!V(typedResolutionProjection!V(header));
            deliver!sink(view);
            return;
        }
    assert(0, "Resolution projection has a type outside its admitted schema");
}
private void deliverGeneratedDefinition(alias sink, T)(
    scope const ResolutionGeneratedHeader* header, DefinitionDisposition disposition)
{
    static foreach (V; SnapshotNativeTypes!T)
        if (header.nativeType is typeid(V))
        {
            scope auto view = generatedDefinitionView!V(typedResolutionGenerated!V(header), disposition);
            deliver!sink(view);
            return;
        }
    assert(0, "Generated definition has a type outside its admitted schema");
}

private const(ResolutionHeader)* findBranch(A)(return scope ref const ResolutionContext!A context,
    scope const(char)[] path)
{
    for (const(ResolutionHeader)* header = context.records; header !is null; header = header.next)
        if (header.path == path) return header;
    return null;
}
private const(ResolutionHeader)* owningDeclaredOption(return scope const(ResolutionHeader)* branch)
    @safe pure nothrow @nogc
{
    while (branch !is null && !branch.declaredOption) branch = branch.parent;
    return branch;
}
private bool hasRootDefinition(T, A)(scope const RetainedState!(T, A)* state,
    DefinitionRef handle)
{
    static foreach (i, path; ConfigPaths!T)
        foreach (record; mixin("state.option" ~ i.stringof ~ ".sorted"))
            if (record.ref_ == handle) return true;
    return false;
}
private const(ResolutionGeneratedHeader)* findGeneratedDefinition(A)(
    return scope ref const ResolutionContext!A context, DefinitionRef handle)
{
    for (const(ResolutionGeneratedHeader)* record = context.generated; record !is null; record = record.next)
        if (record.ref_ == handle) return record;
    return null;
}
private DefinitionDisposition generatedDisposition(A)(
    scope ref const ResolutionContext!A context, DefinitionRef handle)
{
    for (const(ResolutionProjectionHeader)* projection = context.projections;
        projection !is null; projection = projection.next)
        if (projection.parent == handle && projection.locator is null)
            return projection.disposition;
    assert(0, "Generated definition has no retained root projection");
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
        T result;
        CopyArena!A temporary;
        scope(exit) temporary.release();
        static foreach (i, path; ConfigPaths!T)
        {{
            if (!independentGraph!(LeafSite!(T, path).Value)(
                    temporary, *mixin("state.option" ~ i.stringof ~ ".effective"), mixin("result." ~ path)))
                return errorResult!T(fail(ConfigErrorKind.allocationFailed));
        }}
        temporary.commit();
        return successResult(result);
    }
}

/// Borrows a declared option; data-only addresses bind their owning option.
ConfigError visitOption(alias sink, T, A)(scope ref const ConfigSnapshot!(T, A) snapshot,
    scope const(char)[] path)
{
    scope auto state = snapshot.state;
    if (state is null) return fail(ConfigErrorKind.invalidState);
    scope auto option = owningDeclaredOption(findBranch(state.context, path));
    if (option is null) return fail(ConfigErrorKind.unknownOption);
    deliverNode!(sink, optionView, T)(option);
    return ConfigError.init;
}

/// Visits declarations and dynamic instances in graph presentation order.
ConfigError visitOptions(alias sink, T, A)(scope ref const ConfigSnapshot!(T, A) snapshot)
{
    scope auto state = snapshot.state;
    if (state is null) return fail(ConfigErrorKind.invalidState);
    for (scope const(ResolutionHeader)* header = state.context.records;
        header !is null; header = header.next)
        if (header.declaredOption) deliverNode!(sink, optionView, T)(header);
    return ConfigError.init;
}

/// Visits original root definitions or projections of a dynamic declared option.
ConfigError visitDefinitions(alias sink, T, A)(scope ref const ConfigSnapshot!(T, A) snapshot,
    scope const(char)[] path)
{
    scope auto state = snapshot.state;
    if (state is null) return fail(ConfigErrorKind.invalidState);
    scope auto option = owningDeclaredOption(findBranch(state.context, path));
    if (option is null) return fail(ConfigErrorKind.unknownOption);
    static foreach (i, canonical; ConfigPaths!T)
        if (option.path == canonical)
        {
            foreach (record; mixin("state.option" ~ i.stringof ~ ".sorted"))
            {
                scope auto view = definitionView(canonical, record);
                deliver!sink(view);
            }
            return ConfigError.init;
        }
    for (scope const(ResolutionProjectionHeader)* projection = option.projections;
        projection !is null; projection = projection.nextAtNode)
        deliverProjectionDefinition!(sink, T)(projection);
    return ConfigError.init;
}

/// Borrows an original submitted or generated definition through its checked handle.
ConfigError visitDefinition(alias sink, T, A)(scope ref const ConfigSnapshot!(T, A) snapshot,
    DefinitionRef handle)
{
    scope auto state = snapshot.state;
    if (state is null) return fail(ConfigErrorKind.invalidState);
    if (handle.owner != state.owner) return fail(ConfigErrorKind.wrongOwner);
    if (handle.generated)
    {
        scope auto record = findGeneratedDefinition(state.context, handle);
        if (record is null) return fail(ConfigErrorKind.invalidHandle);
        deliverGeneratedDefinition!(sink, T)(record, generatedDisposition(state.context, handle));
        return ConfigError.init;
    }
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

/// Borrows one exact active branch, without promoting it to a declared option.
ConfigError visitBranch(alias sink, T, A)(scope ref const ConfigSnapshot!(T, A) snapshot,
    scope const(char)[] path)
{
    scope auto state = snapshot.state;
    if (state is null) return fail(ConfigErrorKind.invalidState);
    scope auto header = findBranch(state.context, path);
    if (header is null) return fail(ConfigErrorKind.unknownOption);
    deliverNode!(sink, branchView, T)(header);
    return ConfigError.init;
}

/// Visits branches in declaration, effective-index, and canonical-key order.
ConfigError visitBranches(alias sink, T, A)(scope ref const ConfigSnapshot!(T, A) snapshot)
{
    scope auto state = snapshot.state;
    if (state is null) return fail(ConfigErrorKind.invalidState);
    for (scope const(ResolutionHeader)* header = state.context.records;
        header !is null; header = header.next)
        deliverNode!(sink, branchView, T)(header);
    return ConfigError.init;
}

/// Visits all original definitions projected onto one exact active branch.
ConfigError visitBranchDefinitions(alias sink, T, A)(scope ref const ConfigSnapshot!(T, A) snapshot,
    scope const(char)[] path)
{
    scope auto state = snapshot.state;
    if (state is null) return fail(ConfigErrorKind.invalidState);
    scope auto header = findBranch(state.context, path);
    if (header is null) return fail(ConfigErrorKind.unknownOption);
    for (scope const(ResolutionProjectionHeader)* projection = header.projections;
        projection !is null; projection = projection.nextAtNode)
        deliverProjection!(sink, T)(projection);
    return ConfigError.init;
}

/// Looks up an exact original relative locator, including excluded definitions.
ConfigError visitBranchDefinitions(alias sink, T, A)(scope ref const ConfigSnapshot!(T, A) snapshot,
    DefinitionRef parent, scope const(char)[] originalLocator)
{
    scope auto state = snapshot.state;
    if (state is null) return fail(ConfigErrorKind.invalidState);
    if (parent.owner != state.owner) return fail(ConfigErrorKind.wrongOwner);
    if (parent.generated ? findGeneratedDefinition(state.context, parent) is null
        : !hasRootDefinition(state, parent))
        return fail(ConfigErrorKind.invalidHandle);
    bool found;
    for (scope const(ResolutionProjectionHeader)* projection = state.context.projections;
        projection !is null; projection = projection.next)
    {
        if (projection.parent != parent) continue;
        scope auto locator = originalLocatorText(projection.locator);
        if (locator != originalLocator) continue;
        found = true;
        deliverProjection!(sink, T, true)(projection, locator);
    }
    return found ? ConfigError.init : fail(ConfigErrorKind.unknownOption);
}

/// Visits every retained original projection of a checked parent definition.
ConfigError visitBranchDefinitions(alias sink, T, A)(scope ref const ConfigSnapshot!(T, A) snapshot,
    DefinitionRef parent)
{
    scope auto state = snapshot.state;
    if (state is null) return fail(ConfigErrorKind.invalidState);
    if (parent.owner != state.owner) return fail(ConfigErrorKind.wrongOwner);
    if (parent.generated ? findGeneratedDefinition(state.context, parent) is null
        : !hasRootDefinition(state, parent))
        return fail(ConfigErrorKind.invalidHandle);
    for (scope const(ResolutionProjectionHeader)* projection = state.context.projections;
        projection !is null; projection = projection.next)
        if (projection.parent == parent) deliverProjection!(sink, T)(projection);
    return ConfigError.init;
}

/// Borrows a retained projection through its owner-checked contribution handle.
ConfigError visitBranchDefinition(alias sink, T, A)(scope ref const ConfigSnapshot!(T, A) snapshot,
    ContributionRef handle)
{
    scope auto state = snapshot.state;
    if (state is null) return fail(ConfigErrorKind.invalidState);
    if (handle.owner != state.owner) return fail(ConfigErrorKind.wrongOwner);
    for (scope const(ResolutionProjectionHeader)* projection = state.context.projections;
        projection !is null; projection = projection.next)
        if (projection.ref_ == handle)
        {
            deliverProjection!(sink, T)(projection);
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

/// Known record-limit rejection precedes allocation faults and remains retryable.
@("wired.config.core.recordLimitPrecedesAllocationFailure")
@safe unittest
{
    alias A = FailingConfigAllocator;
    struct Settings { int first = 1; int second = 2; }
    A.reset(-1);
    scope(exit) A.reset(-1);
    {
        ConfigLimits limits;
        limits.maxResolvedRecords = 1;
        auto created = ConfigBuilder!(Settings, A).create(limits);
        assert(created.hasValue);
        auto builder = created.takeValue();
        const before = builder.usage;
        A.reset(0);
        auto limited = builder.resolve();
        assert(limited.hasError && limited.error.kind == ConfigErrorKind.limitExceeded
            && limited.error.limit == "maxResolvedRecords");
        assert(builder.collecting && builder.usage == before);
        limits.maxResolvedRecords = 2;
        assert(builder.setLimits(limits).kind == ConfigErrorKind.none);
        auto denied = builder.resolve();
        assert(denied.hasError && denied.error.kind == ConfigErrorKind.allocationFailed);
        assert(builder.collecting && builder.usage == before);
        A.reset(-1);
        auto resolved = builder.resolve();
        assert(resolved.hasValue);
        auto snapshot = resolved.takeValue();
        auto copied = snapshot.copyConfig();
        assert(copied.hasValue && copied.value.first == 1 && copied.value.second == 2);
    }
    assert(A.liveNative == 0);
}

/// Every injected collection allocation fault preserves owners and permits retry.
@("wired.config.core.realCollectionAllocationRollback")
@safe unittest
{
    alias A = FailingConfigAllocator;
    struct Entry
    {
        string label = "default";
        int width = 4;
        string[] tags;
        string[][string] groups;
    }
    struct Settings
    {
        @(ConfigMerge!(AttrsOf!Submodule)()) Entry[string] tools;
        @(ConfigMerge!(ListOf!Submodule)()) Entry[] items;
        Nullable!(string[]) optional;
    }
    Settings sourceValue;
    sourceValue.tools["k"] = Entry("captured", 8, ["one", "two"], ["g": ["nested"]]);
    sourceValue.items = [Entry("listed", 12, ["three"], ["h": ["list"]])];
    sourceValue.optional = ["wrapped"];
    auto input = fullConfigInput(sourceValue);
    enum Operation { capture, borrowed, owned, resolve, copy }
    A.reset(-1);
    scope(exit) A.reset(-1);
    foreach (operation; Operation.min .. Operation.max + 1)
    {
        bool succeeded;
        for (long failure = 0; failure < 512 && !succeeded; ++failure)
        {
            A.reset(-1);
            Settings independent;
            {
                auto created = ConfigBuilder!(Settings, A).create();
                assert(created.hasValue);
                auto builder = created.takeValue();
                auto registered = builder.registerSource(SourceId("u"), ConfigSourceKind.custom, "");
                assert(registered.hasValue);
                auto captured = captureInput!(Settings, A)(input);
                assert(captured.hasValue);
                auto capsule = captured.takeValue();
                ConfigSnapshot!(Settings, A) snapshot;
                if (operation == Operation.resolve || operation == Operation.copy)
                {
                    assert(builder.submitOwned(registered.value, capsule).kind == ConfigErrorKind.none);
                    if (operation == Operation.copy)
                    {
                        auto resolved = builder.resolve();
                        assert(resolved.hasValue);
                        snapshot = resolved.takeValue();
                    }
                }
                const before = operation == Operation.copy ? snapshot.usage : builder.usage;
                const capsuleBefore = capsule.usage;
                const live = A.liveNative;
                A.reset(failure);
                if (operation == Operation.capture)
                {
                    auto attempted = captureInput!(Settings, A)(input);
                    succeeded = attempted.hasValue;
                    if (!succeeded)
                        assert(attempted.error.kind == ConfigErrorKind.allocationFailed);
                    else
                    {
                        auto retained = attempted.takeValue();
                        assert(retained.state.input.tools.value["k"].groups["g"][0] == "nested");
                        assert(retained.state.input.items.value[0].tags == ["three"]);
                        assert(retained.state.input.optional.value.get == ["wrapped"]);
                    }
                }
                else if (operation == Operation.borrowed || operation == Operation.owned)
                {
                    auto error = operation == Operation.borrowed
                        ? builder.submitBorrowed(registered.value, input)
                        : builder.submitOwned(registered.value, capsule);
                    succeeded = error.kind == ConfigErrorKind.none;
                    if (!succeeded)
                    {
                        assert(error.kind == ConfigErrorKind.allocationFailed);
                        assert(!capsule.consumed && capsule.usage == capsuleBefore);
                        assert(capsule.state.input.tools.value["k"].groups["g"][0] == "nested");
                    }
                    else if (operation == Operation.owned) assert(capsule.consumed);
                }
                else if (operation == Operation.resolve)
                {
                    auto attempted = builder.resolve();
                    succeeded = attempted.hasValue;
                    if (!succeeded)
                        assert(attempted.error.kind == ConfigErrorKind.allocationFailed);
                    else snapshot = attempted.takeValue();
                }
                else
                {
                    auto attempted = snapshot.copyConfig();
                    succeeded = attempted.hasValue;
                    if (!succeeded)
                        assert(attempted.error.kind == ConfigErrorKind.allocationFailed);
                    else independent = attempted.takeValue();
                }
                if (!succeeded)
                {
                    assert(A.liveNative == live);
                    if (operation == Operation.copy) assert(snapshot.usage == before);
                    else assert(builder.collecting && builder.usage == before);
                }
                assert(input.tools.value["k"].label == "captured"
                    && input.items.value[0].groups["h"][0] == "list"
                    && input.optional.value.get == ["wrapped"]);
                A.reset(-1);
                if (operation == Operation.capture
                    || (!succeeded && (operation == Operation.borrowed || operation == Operation.owned)))
                {
                    auto error = operation == Operation.borrowed
                        ? builder.submitBorrowed(registered.value, input)
                        : builder.submitOwned(registered.value, capsule);
                    assert(error.kind == ConfigErrorKind.none);
                }
                if (builder.collecting)
                {
                    auto retry = builder.resolve();
                    assert(retry.hasValue);
                    snapshot = retry.takeValue();
                }
                if (operation != Operation.copy || !succeeded)
                {
                    auto copied = snapshot.copyConfig();
                    assert(copied.hasValue);
                    independent = copied.takeValue();
                }
            }
            assert(A.liveNative == 0);
            assert(independent.tools["k"].label == "captured"
                && independent.tools["k"].width == 8
                && independent.tools["k"].tags == ["one", "two"]
                && independent.tools["k"].groups["g"] == ["nested"]);
            assert(independent.items[0].label == "listed"
                && independent.items[0].groups["h"] == ["list"]
                && independent.optional.get == ["wrapped"]);
            independent.tools["k"].width = 99;
            independent.tools["k"].tags[0] = "changed";
            independent.tools["k"].groups["g"][0] = "changed";
            independent.items[0].groups["h"][0] = "changed";
            independent.optional.get[0] = "changed";
            assert(input.tools.value["k"].width == 8
                && input.tools.value["k"].tags[0] == "one"
                && input.tools.value["k"].groups["g"][0] == "nested"
                && input.items.value[0].groups["h"][0] == "list"
                && input.optional.value.get[0] == "wrapped");
        }
        assert(succeeded, "Collection operation never reached its successful allocation boundary");
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
package struct CopyArena(A)
{
    Arena!A records;
    CopyRecord* first;
    bool committed;
    X[] array(X)(size_t count)
    {
        if (!count) return null;
        if (count > size_t.max / X.sizeof) return null;
        auto record = records.allocate!CopyRecord();
        if (record is null) return null;
        auto payload = A.allocateCopy(count * X.sizeof);
        if (payload is null) return null;
        record.payload = payload;
        record.next = first;
        first = record;
        auto result = typedSlice!X(payload, count);
        foreach (ref item; result)
        {
            X initialValue;
            item = initialValue;
        }
        return result;
    }
    X[] nonNullArray(X)(size_t count)
    {
        auto storage = array!X(count ? count : 1);
        return storage.ptr is null ? null : storage[0 .. count];
    }
    bool nonNullArray(X)(out X[] result)
    {
        result = nonNullArray!X(0);
        return result.ptr !is null;
    }
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

// Inspect the typed signature, not the sink body. Swallowing body errors with
// __traits(compiles, sink(view)) would silently permit invalid lifetime escapes.
private template sinkAcceptsView(alias sink, View)
{
    static if (__traits(compiles, Parameters!sink))
    {
        static if (Parameters!sink.length == 1)
            enum sinkAcceptsView = is(const View : Parameters!sink[0]);
        else
            enum sinkAcceptsView = false;
    }
    else
        enum sinkAcceptsView = true; // Generic typed sink: instantiate normally.
}

private void deliver(alias sink, View)(scope ref const View view)
{
    static if (sinkAcceptsView!(sink, View))
    {
        static assert(is(typeof(sink(view)) == void), "Configuration visitor must return void");
        sink(view);
    }
}
