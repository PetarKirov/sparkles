/** Original-site, presence-aware JSON input for finite configuration graphs. */
module sparkles.wired.config.json;

import core.lifetime : move;
import sparkles.wired.config.core;
import sparkles.wired.json.codec : Json, decodeOwnedScalarAt, aaKeyParseNative, aaKeyText;
import sparkles.wired.json.document : JsonKind, JsonValue;
import sparkles.wired.json.error : JsonError, JsonStage, parseStageError;
import sparkles.wired.json.reader : JsonReadOptions, parseJsonDocument;
import sparkles.wired.policy : WireInvalid, hasWireStrict;
import sparkles.wired.schema : NodeKind;
import sparkles.wired.walk : WireWalk;
import sparkles.wired.config.payload : ConfigPresence, measureFullGraph, clearGraph, validGraph;
import sparkles.wired.config.metadata : ConfigBranchMetadata, branchMetadataInert,
    validBranchMetadataControls, validAtomicChildBranchMetadataControls,
    validAbsentBranchMetadata;
import std.traits : isDynamicArray, isStaticArray, isAssociativeArray;
import std.typecons : Nullable;
import std.algorithm.sorting : sort;

/// Unknown keys never create definitions. Strict schema sections always reject.
enum ConfigUnknownMembers : ubyte
{
    reject,
    ignore,
}

struct ConfigDecodeOptions
{
    ConfigUnknownMembers unknownMembers = ConfigUnknownMembers.reject;
}

/// Disjoint decoding and operational capture failures.
struct ConfigDecodeError
{
    bool isJsonError;
    JsonError jsonError;
    ConfigError configError;
}

/// Owns a successful capsule; transfer it with `takeValue`, never copy it.
struct ConfigDecodeResult(T)
{
    private ConfigResult!(OwnedConfigInput!T) captured;
    private bool jsonFailed;
    private JsonError jsonFailure;

    @disable this(this);

    bool hasValue() const @safe pure nothrow @nogc
        => !jsonFailed && captured.hasValue;
    bool hasError() const @safe pure nothrow @nogc
        => jsonFailed || captured.hasError;
    bool hasJsonError() const @safe pure nothrow @nogc => jsonFailed;
    bool hasConfigError() const @safe pure nothrow @nogc
        => !jsonFailed && captured.hasError;
    ref const(JsonError) jsonError() scope return const @safe pure nothrow @nogc
        => jsonFailure;
    ConfigError configError() const return scope @safe pure nothrow @nogc
        => captured.error;
    ConfigDecodeError error() const return scope @safe
        => ConfigDecodeError(jsonFailed, jsonFailure,
            jsonFailed ? ConfigError.init : captured.error);
    OwnedConfigInput!T takeValue() @safe
    {
        assert(hasValue, "configuration decode did not produce a capsule");
        return captured.takeValue();
    }
}

private ConfigDecodeResult!T jsonFailureResult(T)(JsonError error)
{
    ConfigDecodeResult!T result;
    result.jsonFailed = true;
    result.jsonFailure = error;
    return move(result);
}

private ConfigDecodeResult!T captureFailureResult(T)(ConfigError error)
{
    ConfigDecodeResult!T result;
    result.captured = errorResult!(OwnedConfigInput!T)(error);
    return move(result);
}

private template JsonGraphAdmission(V, Root, size_t site, string path)
{
    alias walk = WireWalk!(Json, Root);
    enum node = walk.node!site;
    static assert(node.kind != NodeKind.converted,
        "wired.config: WireConvert is unsupported at " ~ Root.stringof ~ "." ~ path);
    static assert(node.policy.field.onInvalid != WireInvalid.useDefault,
        "wired.config: WireOptional useDefault is unsupported at "
            ~ Root.stringof ~ "." ~ path);
    static if (is(V == Nullable!Contained, Contained))
        static assert(JsonGraphAdmission!(Contained, Root, walk.child!(site, 0), path));
    else static if (!is(V == string) && (isDynamicArray!V || isStaticArray!V))
        static assert(JsonGraphAdmission!(typeof(V.init[0]), Root,
            walk.child!(site, 0), path ~ "[]"));
    else static if (isAssociativeArray!V)
    {
        static assert(JsonGraphAdmission!(typeof(V.init.keys[0]), Root,
            walk.child!(site, 0), path ~ "[<key>]"));
        static assert(JsonGraphAdmission!(typeof(V.init.values[0]), Root,
            walk.child!(site, 1), path ~ "[<key>]"));
    }
    else static if (is(V == struct))
    {
        static assert(node.kind == NodeKind.aggregate,
            "wired.config: original JSON struct must be an aggregate at "
                ~ Root.stringof ~ "." ~ path);
        static assert(node.edgeCount == ConfigFieldNames!V.length);
        static foreach (ordinal, name; ConfigFieldNames!V)
            static assert(JsonGraphAdmission!(ConfigFieldType!(V, name), Root,
                walk.child!(site, ordinal), path.length ? path ~ "." ~ name : name));
    }
    enum bool JsonGraphAdmission = true;
}

private enum JsonSchemaAdmission(T) = JsonGraphAdmission!(T, T, 0, "");

/** Decode text with explicit native parser options and detached capsule limits. */
ConfigDecodeResult!T decodeConfigInput(T, JsonReadOptions parserOptions = JsonReadOptions.init)(
    scope const(char)[] text,
    scope auto ref const DefinitionMetadata!T metadata = DefinitionMetadata!T.init,
    ConfigLimits limits = ConfigLimits.init,
    ConfigDecodeOptions options = ConfigDecodeOptions.init)
{
    static assert(JsonSchemaAdmission!T);
    auto parsed = parseJsonDocument!parserOptions(text);
    if (parsed.hasError)
        return jsonFailureResult!T(parseStageError(parsed.error, text));
    JsonFailureSite!T failedSite;
    auto result = decodeRoot!T(parsed.document.root, metadata, limits, options, failedSite);
    if (result.hasJsonError)
    {
        size_t cursor, offset;
        if (locateSite(parsed.document.root, failedSite, text, cursor, offset))
            result.jsonFailure.setLocation(text, offset);
    }
    return move(result);
}

/** Decode a borrowed document view; the returned capsule does not borrow it. */
ConfigDecodeResult!T decodeConfigInput(T)(scope JsonValue root,
    scope auto ref const DefinitionMetadata!T metadata = DefinitionMetadata!T.init,
    ConfigLimits limits = ConfigLimits.init,
    ConfigDecodeOptions options = ConfigDecodeOptions.init)
{
    static assert(JsonSchemaAdmission!T);
    JsonFailureSite!T failedSite;
    return decodeRoot!T(root, metadata, limits, options, failedSite);
}

// Occurrence coordinates distinguish repeated instances of the same schema
// node, escaped spellings, and typed-key aliases without retaining a document.
// Finite schema depth bounds storage and lexical location scanning.
private struct JsonFailureSite(Root)
{
    size_t[WireWalk!(Json, Root).schema.nodes.length] occurrences;
    size_t depth;

    void prepend(size_t occurrence) @safe pure nothrow @nogc
    {
        assert(depth < occurrences.length);
        foreach_reverse (i; 0 .. depth)
            occurrences[i + 1] = occurrences[i];
        occurrences[0] = occurrence;
        ++depth;
    }
}

private ConfigDecodeResult!T decodeRoot(T)(scope JsonValue root,
    scope ref const DefinitionMetadata!T metadata, ConfigLimits limits,
    ConfigDecodeOptions options, ref JsonFailureSite!T failedSite)
{
    // Force core schema admission, including excluded shapes and merge policies.
    enum optionsCount = ConfigLeafCount!T;
    JsonError failure, unknownFailure;
    JsonFailureSite!T unknownSite;
    bool unknown;
    JsonScratch scratch;
    scope(exit) scratch.arena.release();
    ConfigError captureFailure;
    if (!enumerateOccurrences!(T, T, 0)(root, options, failure, failedSite,
            unknown, unknownFailure, unknownSite, scratch, captureFailure))
    {
        if (captureFailure.kind != ConfigErrorKind.none)
            return captureFailureResult!T(captureFailure);
        return jsonFailureResult!T(failure);
    }
    if (unknown)
    {
        failedSite = unknownSite;
        return jsonFailureResult!T(unknownFailure);
    }
    // Validate the original typed sites and exact budgets before allocating.
    // String counting emits no borrowed header and performs no string copy.
    ConfigInput!T staged;
    StringCaptureBudget counted;
    counted.scratch = &scratch;
    if (!assembleSection!(T, T, 0, StringCaptureBudget, countString)(
            root, staged, counted, failure, captureFailure, failedSite))
    {
        if (captureFailure.kind != ConfigErrorKind.none)
            return captureFailureResult!T(captureFailure);
        return jsonFailureResult!T(failure);
    }
    captureFailure = validateMetadataOccurrences!(T, T, 0)(root, metadata);
    if (captureFailure.kind != ConfigErrorKind.none)
        return captureFailureResult!T(captureFailure);
    ulong canonicalBytes;
    captureFailure = countCanonicalSpellings!T(scratch, canonicalBytes);
    if (captureFailure.kind != ConfigErrorKind.none)
        return captureFailureResult!T(captureFailure);
    const preflight = preflightInput!T(staged, metadata, limits,
        counted.bytes, counted.nodes, canonicalBytes);
    if (preflight.kind != ConfigErrorKind.none)
        return captureFailureResult!T(preflight);
    auto begun = beginOwnedInput!T(metadata, limits);
    if (begun.hasError)
        return captureFailureResult!T(begun.error);
    auto capsule = begun.takeValue();
    if (!assembleSection!(T, T, 0, OwnedConfigInput!T, captureString, true)(
            root, assemblyInput(capsule), capsule,
            failure, captureFailure, failedSite))
    {
        if (captureFailure.kind != ConfigErrorKind.none)
            return captureFailureResult!T(captureFailure);
        return jsonFailureResult!T(failure);
    }
    const completed = finishOwnedInput(capsule);
    if (completed.kind != ConfigErrorKind.none)
        return captureFailureResult!T(completed);
    ConfigDecodeResult!T result;
    result.captured = successResult(capsule);
    return move(result);
}

private JsonError sectionError(S)(scope JsonValue value, string reason) @safe
{
    JsonError failure;
    failure.stage = JsonStage.decode;
    failure.targetType = S.stringof;
    failure.actualKind = value.kind;
    failure.reason = reason;
    return failure;
}

// Enumerate the complete occurrence tree before any value/presence map is
// materialized. Known duplicates beat unknown-member rejection at every depth.
private bool enumerateOccurrences(V, Root, size_t site)(scope JsonValue value,
    ConfigDecodeOptions options, ref JsonError failure, ref JsonFailureSite!Root failedSite,
    ref bool unknown, ref JsonError unknownFailure, ref JsonFailureSite!Root unknownSite,
    ref JsonScratch scratch, ref ConfigError captureFailure)
{
    alias walk = WireWalk!(Json, Root);
    static if (is(V == Nullable!E, E))
    {
        if (value.kind == JsonKind.null_)
            return true;
        return enumerateOccurrences!(E, Root, walk.child!(site, 0))(value,
            options, failure, failedSite, unknown, unknownFailure, unknownSite,
            scratch, captureFailure);
    }
    else static if (!is(V == string) && (isDynamicArray!V || isStaticArray!V))
    {
        if (value.kind != JsonKind.array)
            return true; // original value decoder reports the domain failure
        size_t index;
        foreach (element; value.byElement)
        {
            const hadUnknown = unknown;
            if (!enumerateOccurrences!(typeof(V.init[0]), Root, walk.child!(site, 0))(
                    element, options, failure, failedSite, unknown,
                    unknownFailure, unknownSite, scratch, captureFailure))
            {
                failure.prependIndex(index);
                failedSite.prepend(index);
                return false;
            }
            if (!hadUnknown && unknown)
            {
                unknownFailure.prependIndex(index);
                unknownSite.prepend(index);
            }
            ++index;
        }
    }
    else static if (isAssociativeArray!V)
    {
        if (value.kind != JsonKind.object)
            return true;
        alias K = typeof(V.init.keys[0]);
        auto keyRecord = scratch.allocateMap(value.length);
        if (keyRecord is null)
        {
            captureFailure = ConfigError(ConfigErrorKind.allocationFailed);
            return false;
        }
        size_t occurrence;
        static if (is(K == enum))
            bool[__traits(allMembers, K).length] seen;
        foreach (member; value.byKeyValue)
        {
            bool duplicate;
            static if (is(K == string))
                rememberKey(keyRecord.entries[occurrence], member.key, member.key,
                    occurrence, member.value.kind);
            else
            {
                auto parsed = aaKeyParseNative!(K, Root, walk.child!(site, 0))(
                    member.key, failure);
                if (parsed.failed)
                {
                    failedSite = JsonFailureSite!Root.init;
                    failedSite.prepend(occurrence);
                    return false;
                }
                bool matched;
                static foreach (i, name; __traits(allMembers, K))
                {{
                    if (!matched && parsed.value == __traits(getMember, K, name))
                    {
                        matched = true;
                        duplicate = seen[i];
                        seen[i] = true;
                        enum canonical = aaKeyText!(K, Root, walk.child!(site, 0))(
                            __traits(getMember, K, name));
                        rememberKey(keyRecord.entries[occurrence], canonical, member.key,
                            occurrence, member.value.kind);
                    }
                }}
            }
            if (duplicate)
            {
                failure = sectionError!V(member.value,
                    "duplicate canonical configuration map key");
                failure.prependKey(member.key);
                failedSite = JsonFailureSite!Root.init;
                failedSite.prepend(occurrence);
                return false;
            }
            ++occurrence;
        }
        static if (is(K == string))
        {
            keyRecord.entries.sort!((a, b) => a.spelling == b.spelling
                ? a.occurrence < b.occurrence : a.spelling < b.spelling);
            size_t duplicate = size_t.max;
            foreach (i; 1 .. keyRecord.entries.length)
                if (keyRecord.entries[i - 1].spelling == keyRecord.entries[i].spelling
                        && (duplicate == size_t.max
                            || keyRecord.entries[i].occurrence
                                < keyRecord.entries[duplicate].occurrence))
                    duplicate = i;
            if (duplicate != size_t.max)
            {
                const entry = keyRecord.entries[duplicate];
                failure = sectionError!V(value, "duplicate canonical configuration map key");
                failure.actualKind = entry.actualKind;
                failure.prependKey(entry.original);
                failedSite = JsonFailureSite!Root.init;
                failedSite.prepend(entry.occurrence);
                return false;
            }
        }
        occurrence = 0;
        foreach (member; value.byKeyValue)
        {
            const hadUnknown = unknown;
            if (!enumerateOccurrences!(typeof(V.init.values[0]), Root,
                    walk.child!(site, 1))(member.value, options, failure,
                    failedSite, unknown, unknownFailure, unknownSite, scratch, captureFailure))
            {
                failure.prependKey(member.key);
                failedSite.prepend(occurrence);
                return false;
            }
            if (!hadUnknown && unknown)
            {
                unknownFailure.prependKey(member.key);
                unknownSite.prepend(occurrence);
            }
            ++occurrence;
        }
    }
    else static if (is(V == struct))
    {
        alias policies = walk.childPolicies!site;
        if (value.kind != JsonKind.object)
        {
            failure = sectionError!V(value, "expected a JSON object");
            failedSite = JsonFailureSite!Root.init;
            return false;
        }
        bool[ConfigFieldNames!V.length] seen;
        size_t occurrence;
        foreach (member; value.byKeyValue)
        {
            bool known;
            static foreach (ordinal, name; ConfigFieldNames!V)
            {{
                if (member.key == policies[ordinal].key)
                {
                    known = true;
                    if (seen[ordinal])
                    {
                        failure = sectionError!V(member.value,
                            "duplicate canonical configuration member");
                        failure.prependKey(member.key);
                        failedSite = JsonFailureSite!Root.init;
                        failedSite.prepend(occurrence);
                        return false;
                    }
                    seen[ordinal] = true;
                }
            }}
            if (!known && !unknown && (options.unknownMembers == ConfigUnknownMembers.reject
                    || hasWireStrict!(Json, V)))
            {
                unknown = true;
                unknownFailure = sectionError!V(member.value, "unknown configuration member");
                unknownFailure.prependKey(member.key);
                unknownSite = JsonFailureSite!Root.init;
                unknownSite.prepend(occurrence);
            }
            ++occurrence;
        }
        occurrence = 0;
        foreach (member; value.byKeyValue)
        {
            static foreach (ordinal, name; ConfigFieldNames!V)
            {{
                if (member.key == policies[ordinal].key)
                {
                    const hadUnknown = unknown;
                    if (!enumerateOccurrences!(ConfigFieldType!(V, name), Root,
                            walk.child!(site, ordinal))(member.value, options, failure,
                            failedSite, unknown, unknownFailure, unknownSite,
                            scratch, captureFailure))
                    {
                        failure.prependKey(member.key);
                        failedSite.prepend(occurrence);
                        return false;
                    }
                    if (!hadUnknown && unknown)
                    {
                        unknownFailure.prependKey(member.key);
                        unknownSite.prepend(occurrence);
                    }
                }
            }}
            ++occurrence;
        }
    }
    return true;
}

private struct CanonicalOccurrence
{
    const(char)[] spelling;
    const(char)[] original;
    size_t occurrence;
    JsonKind actualKind;
}
private struct CanonicalMapRecord
{
    CanonicalOccurrence[] entries;
    CanonicalMapRecord* next;
}
private struct JsonScratch
{
    Arena!ConfigAllocator arena;
    CanonicalMapRecord* maps;
    size_t keys;

    CanonicalMapRecord* allocateMap(size_t count) @safe
    {
        if (count > size_t.max - keys)
            return null;
        auto record = arena.allocate!CanonicalMapRecord();
        if (record is null)
            return null;
        record.entries = arena.array!CanonicalOccurrence(count);
        if (count && record.entries.ptr is null)
            return null;
        record.next = maps;
        maps = record;
        keys += count;
        return record;
    }
}

// Scratch borrows only until decodeRoot releases its arena, before document
// destruction. Neither these headers nor their allocator escape that call.
private void rememberKey(ref CanonicalOccurrence entry,
    scope const(char)[] spelling, scope const(char)[] original,
    size_t occurrence, JsonKind kind) @trusted
{
    entry.spelling = spelling;
    entry.original = original;
    entry.occurrence = occurrence;
    entry.actualKind = kind;
}

private ConfigError rememberDefaultKeys(V, Root, size_t site)(
    scope ref const V value, ref JsonScratch scratch)
{
    alias walk = WireWalk!(Json, Root);
    static if (is(V == Nullable!E, E))
    {
        if (!value.isNull)
            return rememberDefaultKeys!(E, Root, walk.child!(site, 0))(value.get, scratch);
    }
    else static if (is(V == string)) {}
    else static if (isDynamicArray!V || isStaticArray!V)
    {
        foreach (ref item; value)
        {
            auto error = rememberDefaultKeys!(typeof(V.init[0]), Root,
                walk.child!(site, 0))(item, scratch);
            if (error.kind != ConfigErrorKind.none)
                return error;
        }
    }
    else static if (isAssociativeArray!V)
    {
        alias K = typeof(V.init.keys[0]);
        auto record = scratch.allocateMap(value.length);
        if (record is null)
            return ConfigError(ConfigErrorKind.allocationFailed);
        size_t index;
        foreach (key, ref item; value)
        {
            static if (is(K == string))
                rememberKey(record.entries[index], key, key, index, JsonKind.none);
            else
            {
                bool matched;
                static foreach (name; __traits(allMembers, K))
                {{
                    if (!matched && key == __traits(getMember, K, name))
                    {
                        matched = true;
                        enum canonical = aaKeyText!(K, Root, walk.child!(site, 0))(
                            __traits(getMember, K, name));
                        rememberKey(record.entries[index], canonical, canonical,
                            index, JsonKind.none);
                    }
                }}
                if (!matched)
                    return ConfigError(ConfigErrorKind.invalidValue);
            }
            ++index;
            auto error = rememberDefaultKeys!(typeof(V.init.values[0]), Root,
                walk.child!(site, 1))(item, scratch);
            if (error.kind != ConfigErrorKind.none)
                return error;
        }
    }
    else static if (is(V == struct))
    {
        static foreach (ordinal, name; ConfigFieldNames!V)
        {{
            auto error = rememberDefaultKeys!(ConfigFieldType!(V, name), Root,
                walk.child!(site, ordinal))(__traits(getMember, value, name), scratch);
            if (error.kind != ConfigErrorKind.none)
                return error;
        }}
    }
    return ConfigError.init;
}

private ConfigError countCanonicalSpellings(Root)(ref JsonScratch scratch,
    out ulong bytes)
{
    bytes = 0;
    auto spellings = scratch.arena.array!(const(char)[])(scratch.keys);
    if (scratch.keys && spellings.ptr is null)
        return ConfigError(ConfigErrorKind.allocationFailed);
    size_t index;
    for (auto record = scratch.maps; record !is null; record = record.next)
        foreach (entry; record.entries)
            spellings[index++] = entry.spelling;
    spellings.sort;
    foreach (i, spelling; spellings)
    {
        if (i && spellings[i - 1] == spelling)
            continue;
        bool declaredPath;
        static foreach (path; ConfigPatterns!Root)
            if (spelling == path)
                declaredPath = true;
        if (!declaredPath)
        {
            if (spelling.length > ulong.max - bytes)
                return ConfigError(ConfigErrorKind.arithmeticOverflow);
            bytes += spelling.length;
        }
    }
    return ConfigError.init;
}

private struct StringCaptureBudget
{
    ulong bytes;
    ulong nodes;
    JsonScratch* scratch;
}

private ConfigError countCharge(scope ref StringCaptureBudget budget, ulong bytes,
    ulong nodes = 0) @safe pure nothrow @nogc
{
    if (bytes > ulong.max - budget.bytes || nodes > ulong.max - budget.nodes)
        return ConfigError(ConfigErrorKind.arithmeticOverflow);
    budget.bytes += bytes;
    budget.nodes += nodes;
    return ConfigError.init;
}

private ConfigError countString(scope ref StringCaptureBudget budget,
    scope const(char)[] bytes, out string captured) @safe pure nothrow @nogc
{
    captured = null;
    return countCharge(budget, bytes.length);
}

private template ElementPolicy(P)
{
    static if (is(P == ListOf!E, E)) alias ElementPolicy = E;
    else alias ElementPolicy = Atomic;
}
private template ValuePolicy(P)
{
    static if (is(P == AttrsOf!E, E)) alias ValuePolicy = E;
    else alias ValuePolicy = Atomic;
}
private template ContainedPolicy(P)
{
    static if (is(P == NullOr!E, E)) alias ContainedPolicy = E;
    else alias ContainedPolicy = Atomic;
}
private template MemberPolicy(S, string name, P)
{
    static if (is(P == Submodule)) alias MemberPolicy = ConfigFieldPolicy!(S, name);
    else alias MemberPolicy = Atomic;
}

private ConfigError captureOriginalStringKey(Root, size_t site, Owner)(
    scope ref Owner owner, scope const(char)[] text, out string key) @trusted
{
    // The only immutable cast is the duration of a core-owned capture call.
    // Core interns/copies on a miss and never retains the borrowed header.
    return captureCanonicalKey!(Root, site)(owner, cast(string) text, key);
}

private auto stringMetadataEntry(M)(scope const(char)[] key,
    return scope ref const M entries) @trusted
{
    // An AA lookup reads the key; the returned pointer borrows only `entries`.
    return cast(string) key in entries;
}

// Core owns control/absence policy. This adapter contributes only original
// occurrence shape, so count-only slots never need a fabricated presence tree.
private ConfigError validateMetadataOccurrences(S, Root, size_t site, string prefix = "")(
    scope JsonValue value, scope ref const DefinitionMetadata!S metadata)
{
    alias walk = WireWalk!(Json, Root);
    alias policies = walk.childPolicies!site;
    foreach (member; value.byKeyValue)
    {
        static foreach (ordinal, name; ConfigFieldNames!S)
        {{
            if (member.key == policies[ordinal].key)
            {
                static if (ConfigIsSection!(S, name))
                {
                    auto error = validateMetadataOccurrences!(ConfigFieldType!(S, name),
                        Root, walk.child!(site, ordinal), prefix ~ name ~ ".")(
                            member.value, __traits(getMember, metadata, name).members);
                    if (error.kind != ConfigErrorKind.none)
                        return error;
                }
                else static if (__traits(hasMember,
                    typeof(__traits(getMember, metadata, name)), "branches"))
                {
                    if (!validJsonBranchMetadata!(ConfigFieldType!(S, name),
                            ConfigFieldPolicy!(S, name), Root, walk.child!(site, ordinal))(
                            member.value, __traits(getMember, metadata, name).branches))
                        return ConfigError(ConfigErrorKind.invalidMetadata, prefix ~ name);
                }
            }
        }}
    }
    return ConfigError.init;
}

private bool validJsonBranchMetadata(V, P, Root, size_t site, bool atomicChild = false)(
    scope JsonValue source, scope ref const ConfigBranchMetadata!V metadata)
{
    static if (atomicChild)
    {
        if (!validAtomicChildBranchMetadataControls(metadata))
            return false;
    }
    else if (!validBranchMetadataControls(metadata))
        return false;
    if (branchMetadataInert(metadata))
        return true;
    alias walk = WireWalk!(Json, Root);
    static if (is(V == Nullable!E, E))
    {
        if (!metadata.shaped)
            return !metadata.hasValue && branchMetadataInert(metadata.child);
        const hasValue = source.kind != JsonKind.null_;
        if (metadata.hasValue != hasValue)
            return false;
        return hasValue
            ? validJsonBranchMetadata!(E, ContainedPolicy!P, Root, walk.child!(site, 0),
                is(P == Atomic))(
                source, metadata.child)
            : validAbsentBranchMetadata!(E, ContainedPolicy!P)(metadata.child);
    }
    else static if (is(V == string)) {}
    else static if (isDynamicArray!V || isStaticArray!V)
    {
        if (!metadata.shaped)
            return metadata.elements.length == 0;
        if (metadata.elements.length != source.length)
            return false;
        size_t index;
        foreach (element; source.byElement)
        {
            if (!validJsonBranchMetadata!(typeof(V.init[0]), ElementPolicy!P,
                    Root, walk.child!(site, 0), is(P == Atomic))(
                    element, metadata.elements[index++]))
                return false;
        }
    }
    else static if (isAssociativeArray!V)
    {
        if (!metadata.shaped)
            return metadata.entries.length == 0;
        if (metadata.entries.length != source.length)
            return false;
        alias K = typeof(V.init.keys[0]);
        foreach (member; source.byKeyValue)
        {
            static if (is(K == string))
                auto branch = stringMetadataEntry(member.key, metadata.entries);
            else
            {
                JsonError ignored;
                auto parsed = aaKeyParseNative!(K, Root, walk.child!(site, 0))(
                    member.key, ignored);
                if (parsed.failed)
                    return false;
                auto branch = parsed.value in metadata.entries;
            }
            if (branch is null || !validJsonBranchMetadata!(typeof(V.init.values[0]),
                    ValuePolicy!P, Root, walk.child!(site, 1), is(P == Atomic))(
                    member.value, *branch))
                return false;
        }
    }
    else static if (is(V == struct))
    {
        if (!metadata.shaped)
        {
            static foreach (name; ConfigFieldNames!V)
                if (!branchMetadataInert(__traits(getMember, metadata.members, name)))
                    return false;
            return true;
        }
        alias policies = walk.childPolicies!site;
        bool[ConfigFieldNames!V.length] seen;
        foreach (member; source.byKeyValue)
        {
            static foreach (ordinal, name; ConfigFieldNames!V)
            {{
                if (member.key == policies[ordinal].key)
                {
                    seen[ordinal] = true;
                    if (!validJsonBranchMetadata!(ConfigFieldType!(V, name),
                            MemberPolicy!(V, name, P), Root, walk.child!(site, ordinal),
                            is(P == Atomic))(
                            member.value, __traits(getMember, metadata.members, name)))
                        return false;
                }
            }}
        }
        static foreach (ordinal, name; ConfigFieldNames!V)
        {{
            if (!seen[ordinal])
            {
                static if (is(P == Submodule))
                {
                    if (!validAbsentBranchMetadata!(ConfigFieldType!(V, name),
                            MemberPolicy!(V, name, P))(
                            __traits(getMember, metadata.members, name)))
                        return false;
                }
                else
                {
                    static const initial = __traits(getMember, V.init, name);
                    if (!validDefaultAtomicBranchMetadata!(ConfigFieldType!(V, name))(
                            initial,
                            __traits(getMember, metadata.members, name)))
                        return false;
                }
            }
        }}
    }
    return true;
}


// Optional Atomic omissions are initialized native data, not sparse members.
// Their full initializer shape is source data, but Atomic child controls apply.
private bool validDefaultAtomicBranchMetadata(V)(scope ref const V value,
    scope ref const ConfigBranchMetadata!V metadata)
{
    if (!validAtomicChildBranchMetadataControls(metadata))
        return false;
    if (branchMetadataInert(metadata))
        return true;
    static if (is(V == Nullable!E, E))
    {
        if (!metadata.shaped)
            return !metadata.hasValue && branchMetadataInert(metadata.child);
        if (metadata.hasValue != !value.isNull)
            return false;
        return value.isNull
            ? validAbsentBranchMetadata!(E, Atomic)(metadata.child)
            : validDefaultAtomicBranchMetadata!E(value.get, metadata.child);
    }
    else static if (is(V == string)) {}
    else static if (isDynamicArray!V || isStaticArray!V)
    {
        if (!metadata.shaped)
            return metadata.elements.length == 0;
        if (metadata.elements.length != value.length)
            return false;
        foreach (i, ref item; value)
            if (!validDefaultAtomicBranchMetadata!(typeof(V.init[0]))(
                    item, metadata.elements[i]))
                return false;
    }
    else static if (isAssociativeArray!V)
    {
        if (!metadata.shaped)
            return metadata.entries.length == 0;
        if (metadata.entries.length != value.length)
            return false;
        foreach (key, ref item; value)
        {
            auto child = key in metadata.entries;
            if (child is null || !validDefaultAtomicBranchMetadata!(
                    typeof(V.init.values[0]))(item, *child))
                return false;
        }
    }
    else static if (is(V == struct))
    {
        if (!metadata.shaped)
        {
            static foreach (name; ConfigFieldNames!V)
                if (!branchMetadataInert(__traits(getMember, metadata.members, name)))
                    return false;
            return true;
        }
        static foreach (name; ConfigFieldNames!V)
            if (!validDefaultAtomicBranchMetadata!(ConfigFieldType!(V, name))(
                    __traits(getMember, value, name),
                    __traits(getMember, metadata.members, name)))
                return false;
    }
    return true;
}

private bool assembleSection(S, Root, size_t site, Owner, alias capture,
    bool owning = false, string prefix = "")(
    scope JsonValue value, ref ConfigInput!S input, scope ref Owner capsule, ref JsonError failure,
    ref ConfigError captureFailure, ref JsonFailureSite!Root failedSite)
{
    alias walk = WireWalk!(Json, Root);
    alias policies = walk.childPolicies!site;
    size_t occurrence;
    foreach (member; value.byKeyValue)
    {
        static foreach (ordinal, name; ConfigFieldNames!S)
        {{
            if (member.key == policies[ordinal].key)
            {
                alias V = ConfigFieldType!(S, name);
                enum child = walk.child!(site, ordinal);
                bool decoded;
                static if (ConfigIsSection!(S, name))
                    decoded = assembleSection!(V, Root, child, Owner, capture, owning,
                        prefix ~ name ~ ".")(
                        member.value, __traits(getMember, input, name), capsule,
                        failure, captureFailure, failedSite);
                else
                {
                    decoded = assembleGraph!(V, ConfigFieldPolicy!(S, name), Root, child,
                        Owner, capture, owning)(member.value,
                            __traits(getMember, input, name).value,
                            __traits(getMember, input, name).presence,
                            capsule, failure, captureFailure, failedSite);
                    if (decoded)
                        __traits(getMember, input, name).supplied = true;
                }
                if (!decoded)
                {
                    if (captureFailure.kind != ConfigErrorKind.none
                            && captureFailure.path.length == 0)
                        captureFailure.path = prefix ~ name;
                    failure.prependKey(member.key);
                    failedSite.prepend(occurrence);
                    return false;
                }
            }
        }}
        ++occurrence;
    }
    return true;
}

// The count pass validates original primitive sites without retaining a string
// header or materializing a container. The ownership pass writes each leaf
// directly into the capsule and builds independent generated presence.
private bool assembleGraph(V, P, Root, size_t site, Owner, alias capture, bool owning)(
    scope JsonValue source, ref V value, ref ConfigPresence!V presence,
    scope ref Owner owner, ref JsonError failure, ref ConfigError captureFailure,
    ref JsonFailureSite!Root failedSite)
{
    alias walk = WireWalk!(Json, Root);
    failedSite = JsonFailureSite!Root.init;
    static if (owning)
    {
        clearGraph(value);
        presence = ConfigPresence!V.init;
    }
    static if (!owning)
    {
        captureFailure = countCharge(owner, 0, 1);
        if (captureFailure.kind != ConfigErrorKind.none)
            return false;
    }
    static if (is(V == string))
    {
        if (!decodeOwnedScalarAt!(V, Root, site, Owner, ConfigError, capture)(
                source, value, failure, owner, captureFailure))
            return false;
    }
    else static if (is(V == Nullable!E, E))
    {
        static if (!owning)
        {
            captureFailure = countCharge(owner, 1);
            if (captureFailure.kind != ConfigErrorKind.none)
                return false;
        }
        if (source.kind == JsonKind.null_)
        {
            static if (owning)
            {
                value = V.init;
                presence.hasValue = false;
            }
        }
        else
        {
            E childValue;
            ConfigPresence!E childPresence;
            if (!assembleGraph!(E, ContainedPolicy!P, Root, walk.child!(site, 0),
                    Owner, capture, owning)(source, childValue, childPresence,
                    owner, failure, captureFailure, failedSite))
                return false;
            static if (owning)
            {
                value = V(childValue);
                presence.hasValue = true;
                presence.child = childPresence;
            }
        }
    }
    else static if (isDynamicArray!V || isStaticArray!V)
    {
        alias E = typeof(V.init[0]);
        if (source.kind != JsonKind.array)
        {
            failure = sectionError!V(source, "expected a JSON array");
            return false;
        }
        static if (isStaticArray!V)
        {
            if (source.length != V.length)
            {
                failure = sectionError!V(source, "wrong number of array elements");
                return false;
            }
        }
        else static if (!owning)
        {
            captureFailure = countCharge(owner, 1);
            if (captureFailure.kind != ConfigErrorKind.none)
                return false;
        }
        static if (owning)
        {
            static if (isDynamicArray!V)
            {
                captureFailure = captureArray(owner, source.length, true, value);
                if (captureFailure.kind != ConfigErrorKind.none)
                    return false;
            }
            captureFailure = captureArray(owner, source.length, true, presence.elements);
            if (captureFailure.kind != ConfigErrorKind.none)
                return false;
        }
        size_t index;
        foreach (element; source.byElement)
        {
            E childValue;
            ConfigPresence!E childPresence;
            if (!assembleGraph!(E, ElementPolicy!P, Root, walk.child!(site, 0),
                    Owner, capture, owning)(element, childValue, childPresence,
                    owner, failure, captureFailure, failedSite))
            {
                failure.prependIndex(index);
                failedSite.prepend(index);
                return false;
            }
            static if (owning)
            {
                value[index] = childValue;
                presence.elements[index] = childPresence;
            }
            ++index;
        }
    }
    else static if (isAssociativeArray!V)
    {
        alias K = typeof(V.init.keys[0]);
        alias E = typeof(V.init.values[0]);
        if (source.kind != JsonKind.object)
        {
            failure = sectionError!V(source, "expected a JSON object");
            return false;
        }
        static if (!owning)
        {
            captureFailure = countCharge(owner, 1);
            if (captureFailure.kind != ConfigErrorKind.none)
                return false;
        }
        static if (owning)
        {
            captureFailure = captureMapEmpty(owner, value);
            if (captureFailure.kind != ConfigErrorKind.none)
                return false;
            captureFailure = captureMapEmpty(owner, presence.entries);
            if (captureFailure.kind != ConfigErrorKind.none)
                return false;
        }
        size_t occurrence;
        foreach (member; source.byKeyValue)
        {
            K key;
            static if (is(K == string))
            {
                static if (owning)
                    captureFailure = captureOriginalStringKey!(Root,
                        walk.child!(site, 0))(owner, member.key, key);
                else
                    captureFailure = capture(owner, member.key, key);
            }
            else
            {
                auto parsed = aaKeyParseNative!(K, Root, walk.child!(site, 0))(
                    member.key, failure);
                if (parsed.failed)
                {
                    failedSite.prepend(occurrence);
                    return false;
                }
                key = parsed.value;
                static if (!owning)
                    captureFailure = countCharge(owner, K.sizeof);
            }
            static if (!owning)
            {
                if (captureFailure.kind == ConfigErrorKind.none)
                    captureFailure = countCharge(owner, 0, 1);
            }
            if (captureFailure.kind != ConfigErrorKind.none)
                return false;
            static if (owning && !is(K == string))
            {
                string canonical;
                captureFailure = captureCanonicalKey!(Root, walk.child!(site, 0))(
                    owner, key, canonical);
                if (captureFailure.kind != ConfigErrorKind.none)
                    return false;
            }
            E childValue;
            ConfigPresence!E childPresence;
            if (!assembleGraph!(E, ValuePolicy!P, Root, walk.child!(site, 1),
                    Owner, capture, owning)(member.value, childValue, childPresence,
                    owner, failure, captureFailure, failedSite))
            {
                failure.prependKey(member.key);
                failedSite.prepend(occurrence);
                return false;
            }
            static if (owning)
            {
                captureFailure = captureMapEntry(owner, value, key, childValue);
                if (captureFailure.kind != ConfigErrorKind.none)
                    return false;
                captureFailure = captureMapEntry(owner, presence.entries, key, childPresence);
                if (captureFailure.kind != ConfigErrorKind.none)
                    return false;
            }
            ++occurrence;
        }
    }
    else static if (is(V == struct))
    {
        if (source.kind != JsonKind.object)
        {
            failure = sectionError!V(source, "expected a JSON object");
            return false;
        }
        alias policies = walk.childPolicies!site;
        bool[ConfigFieldNames!V.length] seen;
        size_t occurrence;
        foreach (member; source.byKeyValue)
        {
            static foreach (ordinal, name; ConfigFieldNames!V)
            {{
                if (member.key == policies[ordinal].key)
                {
                    if (!assembleGraph!(ConfigFieldType!(V, name), MemberPolicy!(V, name, P),
                            Root, walk.child!(site, ordinal), Owner, capture, owning)(
                            member.value, __traits(getMember, value, name),
                            __traits(getMember, presence.members, name), owner,
                            failure, captureFailure, failedSite))
                    {
                        failure.prependKey(member.key);
                        failedSite.prepend(occurrence);
                        return false;
                    }
                    seen[ordinal] = true;
                }
            }}
            ++occurrence;
        }
        static if (!is(P == Submodule))
        {
            static foreach (ordinal, name; ConfigFieldNames!V)
            {{
                alias E = ConfigFieldType!(V, name);
                if (!seen[ordinal])
                {
                    static if (!policies[ordinal].optional && !is(E == Nullable!N, N))
                    {
                        failure = sectionError!V(source, "missing required field");
                        failure.prependKey(policies[ordinal].key);
                        failedSite = JsonFailureSite!Root.init;
                        return false;
                    }
                    else
                    {
                        const initialized = __traits(getMember, V.init, name);
                        static if (owning)
                            captureFailure = captureDefaultGraph!(Root,
                                walk.child!(site, ordinal))(owner, initialized,
                                    __traits(getMember, value, name),
                                    __traits(getMember, presence.members, name));
                        else
                        {
                            ulong bytes, nodes;
                            if (!measureFullGraph(initialized, bytes, nodes))
                                captureFailure = ConfigError(ConfigErrorKind.arithmeticOverflow);
                            else
                                captureFailure = countCharge(owner, bytes, nodes);
                            if (captureFailure.kind == ConfigErrorKind.none)
                                captureFailure = rememberDefaultKeys!(E, Root,
                                    walk.child!(site, ordinal))(initialized, *owner.scratch);
                        }
                        if (captureFailure.kind != ConfigErrorKind.none)
                            return false;
                    }
                }
            }}
        }
    }
    else
    {
        if (!decodeOwnedScalarAt!(V, Root, site, Owner, ConfigError, capture)(
                source, value, failure, owner, captureFailure))
            return false;
        static if (!owning)
        {
            ConfigPresence!V checked;
            checked.supplied = true;
            if (!validGraph!(V, Atomic)(value, checked))
            {
                captureFailure = ConfigError(ConfigErrorKind.invalidValue);
                return false;
            }
            captureFailure = countCharge(owner, V.sizeof);
            if (captureFailure.kind != ConfigErrorKind.none)
                return false;
        }
    }
    static if (owning)
        presence.supplied = true;
    return true;
}

// Follow only the recorded original occurrence chain. Ignored/unrelated
// subtrees are skipped lexically with constant storage, not decoded/reparsed.
private bool locateSite(Root)(scope JsonValue current, JsonFailureSite!Root target,
    scope const(char)[] text, ref size_t cursor, out size_t offset, size_t depth = 0)
{
    skipSpace(text, cursor);
    offset = cursor;
    if (depth == target.depth)
        return true;
    if (current.kind != JsonKind.object && current.kind != JsonKind.array)
        return false;
    cursor++; // opening brace/bracket
    size_t occurrence;
    if (current.kind == JsonKind.object)
    {
        foreach (member; current.byKeyValue)
        {
            skipSpace(text, cursor);
            skipString(text, cursor);
            skipSpace(text, cursor);
            cursor++; // colon
            skipSpace(text, cursor);
            if (occurrence == target.occurrences[depth])
                return locateSite(member.value, target, text, cursor, offset, depth + 1);
            skipValue(text, cursor);
            skipSpace(text, cursor);
            if (cursor < text.length && text[cursor] == ',')
                cursor++;
            ++occurrence;
        }
    }
    else
    {
        foreach (element; current.byElement)
        {
            skipSpace(text, cursor);
            if (occurrence == target.occurrences[depth])
                return locateSite(element, target, text, cursor, offset, depth + 1);
            skipValue(text, cursor);
            skipSpace(text, cursor);
            if (cursor < text.length && text[cursor] == ',')
                cursor++;
            ++occurrence;
        }
    }
    return false;
}

private void skipValue(scope const(char)[] text, ref size_t cursor)
    @safe pure nothrow @nogc
{
    skipSpace(text, cursor);
    if (cursor == text.length)
        return;
    if (text[cursor] == '"')
    {
        skipString(text, cursor);
        return;
    }
    if (text[cursor] == '{' || text[cursor] == '[')
    {
        size_t depth;
        while (cursor < text.length)
        {
            if (text[cursor] == '"')
            {
                skipString(text, cursor);
                continue;
            }
            const c = text[cursor++];
            if (c == '{' || c == '[')
                depth++;
            else if (c == '}' || c == ']')
            {
                depth--;
                if (depth == 0)
                    return;
            }
        }
        return;
    }
    while (cursor < text.length && text[cursor] != ',' && text[cursor] != '}'
            && text[cursor] != ']' && text[cursor] != ' '
            && text[cursor] != '\t' && text[cursor] != '\r' && text[cursor] != '\n')
        cursor++;
}

private void skipSpace(scope const(char)[] text, ref size_t cursor)
    @safe pure nothrow @nogc
{
    while (cursor < text.length && (text[cursor] == ' ' || text[cursor] == '\t'
            || text[cursor] == '\r' || text[cursor] == '\n'))
        cursor++;
}

private void skipString(scope const(char)[] text, ref size_t cursor)
    @safe pure nothrow @nogc
{
    cursor++; // opening quote
    while (cursor < text.length)
    {
        const c = text[cursor++];
        if (c == '"')
            return;
        if (c == '\\')
            cursor++; // escaped byte; remaining hex digits are ordinary bytes
    }
}

version (unittest)
{
    private ConfigSnapshot!T snapshotFor(T)(ref OwnedConfigInput!T capsule)
    {
        auto created = ConfigBuilder!T.create();
        assert(created.hasValue);
        auto builder = created.takeValue();
        auto source = builder.registerSource(SourceId("u"), ConfigSourceKind.userFile, "");
        assert(source.hasValue);
        assert(builder.submitOwned(source.value, capsule).kind == ConfigErrorKind.none);
        auto resolved = builder.resolve();
        assert(resolved.hasValue);
        return resolved.takeValue();
    }

    private void expectDefinitions(V, T)(ref ConfigSnapshot!T snapshot,
        string path, size_t count)
    {
        bool visited;
        const error = snapshot.visitOption!((scope ref const view) {
            static if (is(typeof(view) == const(OptionView!V)))
            {
                visited = true;
                assert(view.path == path);
                assert(view.definitions.length == count);
            }
            else
                assert(false, "unexpected value type for requested option");
        })(path);
        assert(error.kind == ConfigErrorKind.none && visited);
    }
}

@("wired.config.json.presenceDefaultEqualAndNull")
@safe unittest
{
    import std.typecons : Nullable;
    import sparkles.wired.policy : WireOptional;

    struct Settings
    {
        bool enabled;
        @WireOptional() int width;
        string title;
        Nullable!int optional;
    }
    auto absent = decodeConfigInput!Settings(`{}`);
    assert(absent.hasValue);
    auto empty = absent.takeValue();
    auto emptySnapshot = snapshotFor(empty);
    expectDefinitions!bool(emptySnapshot, "enabled", 1);
    expectDefinitions!int(emptySnapshot, "width", 1);
    expectDefinitions!string(emptySnapshot, "title", 1);
    expectDefinitions!(Nullable!int)(emptySnapshot, "optional", 1);

    auto present = decodeConfigInput!Settings(
        `{"enabled":false,"width":0,"title":"","optional":null}`);
    assert(present.hasValue);
    auto supplied = present.takeValue();
    auto suppliedSnapshot = snapshotFor(supplied);
    expectDefinitions!bool(suppliedSnapshot, "enabled", 2);
    expectDefinitions!int(suppliedSnapshot, "width", 2);
    expectDefinitions!string(suppliedSnapshot, "title", 2);
    expectDefinitions!(Nullable!int)(suppliedSnapshot, "optional", 2);
    auto suppliedCopy = suppliedSnapshot.copyConfig();
    assert(suppliedCopy.hasValue && !suppliedCopy.value.enabled
        && suppliedCopy.value.width == 0 && suppliedCopy.value.title == ""
        && suppliedCopy.value.title.ptr !is null && suppliedCopy.value.optional.isNull);
    auto nonnull = decodeConfigInput!Settings(`{"optional":0}`);
    assert(nonnull.hasValue);
    auto value = nonnull.takeValue();
    auto valueSnapshot = snapshotFor(value);
    expectDefinitions!(Nullable!int)(valueSnapshot, "optional", 2);
    auto valueCopy = valueSnapshot.copyConfig();
    assert(valueCopy.hasValue && !valueCopy.value.optional.isNull
        && valueCopy.value.optional.get == 0);
    auto invalid = decodeConfigInput!Settings(`{"title":null}`);
    assert(invalid.hasJsonError && !invalid.hasConfigError);
    assert(invalid.jsonError.path[] == ".title");
}

@("wired.config.json.originalNestedSitePolicies")
@safe unittest
{
    import std.typecons : Nullable;
    import sparkles.wired.policy : WireCase, WireName, WireRepr, Repr, CaseStyle;
    import sparkles.wired.overlay : WireSection;

    enum Mode : int
    {
        fastPath = 1,
        slowPath = 2,
        @WireName("accelerated") turboPath = 3,
    }
    @WireSection
    struct Viewer
    {
        @WireName("mode-choice")
        @WireCase(CaseStyle.snakeCase)
        Nullable!Mode selectedMode;
        @WireRepr(Repr.value) Mode numericMode = Mode.fastPath;
        int tabWidth;
    }
    struct Settings
    {
        @WireName("panel")
        @WireCase(CaseStyle.snakeCase)
        @(ConfigMerge!Submodule()) Viewer viewer;
    }
    auto decoded = decodeConfigInput!Settings(
        `{"panel":{"mode-choice":"slow_path","numeric_mode":2,"tab_width":0}}`);
    assert(decoded.hasValue);
    auto capsule = decoded.takeValue();
    auto snapshot = snapshotFor(capsule);
    expectDefinitions!(Nullable!Mode)(snapshot, "viewer.selectedMode", 2);
    expectDefinitions!Mode(snapshot, "viewer.numericMode", 2);
    expectDefinitions!int(snapshot, "viewer.tabWidth", 2);
    auto copied = snapshot.copyConfig();
    assert(copied.hasValue && copied.value.viewer.selectedMode.get == Mode.slowPath
        && copied.value.viewer.numericMode == Mode.slowPath
        && copied.value.viewer.tabWidth == 0);
    auto renamed = decodeConfigInput!Settings(`{"panel":{"mode-choice":"accelerated"}}`);
    assert(renamed.hasValue);
    auto renamedCapsule = renamed.takeValue();
    auto renamedSnapshot = snapshotFor(renamedCapsule);
    auto renamedCopy = renamedSnapshot.copyConfig();
    assert(renamedCopy.hasValue
        && renamedCopy.value.viewer.selectedMode.get == Mode.turboPath);
    auto originalSpelling = decodeConfigInput!Settings(
        `{"viewer":{"tabWidth":8}}`);
    assert(originalSpelling.hasJsonError);
    auto bad = decodeConfigInput!Settings(
        "{\n  \"panel\": {\"mode-choice\":\"fast_path\", \"numeric_mode\": \"slowPath\"}\n}");
    assert(bad.hasJsonError && bad.jsonError.path[] == ".panel.numeric_mode");
    assert(bad.jsonError.targetType == Mode.stringof);
    assert(bad.jsonError.line == 2 && bad.jsonError.column > 1);
    assert(bad.jsonError.offset == 57);
}

@("wired.config.json.duplicateUnknownAndStrictPrecedence")
@safe unittest
{
    import sparkles.wired.policy : WireName, WireStrict;

    struct Settings { @WireName("w") int width; }
    DefinitionMetadata!Settings metadata;
    const ignoring = ConfigDecodeOptions(ConfigUnknownMembers.ignore);
    auto unknown = decodeConfigInput!Settings(`{"extra":1}`);
    assert(unknown.hasJsonError && unknown.jsonError.path[] == ".extra");
    auto ignored = decodeConfigInput!Settings(`{"extra":1}`, metadata,
        ConfigLimits.init, ignoring);
    assert(ignored.hasValue);
    auto capsule = ignored.takeValue();
    auto ignoredSnapshot = snapshotFor(capsule);
    expectDefinitions!int(ignoredSnapshot, "width", 1);
    auto duplicate = decodeConfigInput!Settings(`{"extra":1,"w":0,"\u0077":2}`);
    assert(duplicate.hasJsonError && duplicate.jsonError.path[] == ".w");
    assert(duplicate.jsonError.offset == 26);
    auto duplicateIgnored = decodeConfigInput!Settings(`{"w":0,"w":2}`,
        metadata, ConfigLimits.init, ignoring);
    assert(duplicateIgnored.hasJsonError);
    @WireStrict struct Strict { int width; }
    DefinitionMetadata!Strict strictMetadata;
    auto strict = decodeConfigInput!Strict(`{"extra":1}`, strictMetadata,
        ConfigLimits.init, ignoring);
    assert(strict.hasJsonError && strict.jsonError.path[] == ".extra");
}

@("wired.config.json.parsedDocumentAndTextLifetimes")
@safe unittest
{
    import std.typecons : Nullable;

    struct Settings { string title; Nullable!string subtitle; }
    OwnedConfigInput!Settings capsule;
    {
        auto document = parseJsonDocument(`{"title":"owned text","subtitle":"secondary"}`);
        assert(document.hasValue);
        auto decoded = decodeConfigInput!Settings(document.document.root);
        assert(decoded.hasValue);
        capsule = decoded.takeValue();
    }
    auto created = ConfigBuilder!Settings.create();
    assert(created.hasValue);
    auto builder = created.takeValue();
    auto source = builder.registerSource(SourceId("u"), ConfigSourceKind.userFile, "");
    assert(source.hasValue);
    assert(builder.submitOwned(source.value, capsule).kind == ConfigErrorKind.none);
    auto resolved = builder.resolve();
    assert(resolved.hasValue);
    auto snapshot = resolved.takeValue();
    auto copied = snapshot.copyConfig();
    assert(copied.hasValue && copied.value.title == "owned text"
        && copied.value.subtitle.get == "secondary");
}

@("wired.config.json.unsupportedPoliciesAreCompileErrors")
@safe unittest
{
    import sparkles.wired.policy : WireConvert, WireOptional, WireInvalid;

    struct Defaulting
    {
        @WireOptional(onInvalid: WireInvalid.useDefault) int width;
    }
    static assert(!__traits(compiles, decodeConfigInput!Defaulting(`{"width":1}`)));
    static int toWire(int value) @safe pure nothrow => value;
    static int fromWire(int value) @safe pure nothrow => value;
    struct Converted
    {
        @WireConvert!(toWire, fromWire) int width;
    }
    static assert(!__traits(compiles, decodeConfigInput!Converted(`{"width":1}`)));
}

@("wired.config.json.captureBudgetBoundaries")
@safe unittest
{
    struct Settings { int width = 4; }
    DefinitionMetadata!Settings metadata;
    ConfigLimits limits;
    limits.maxPayloadBytes = 8;
    auto tooSmall = decodeConfigInput!Settings(`{"width":8}`,
        metadata, limits);
    assert(tooSmall.hasConfigError && !tooSmall.hasJsonError
        && tooSmall.configError.kind == ConfigErrorKind.limitExceeded);
    limits.maxPayloadBytes = 9;
    auto exact = decodeConfigInput!Settings(`{"width":8}`,
        metadata, limits);
    assert(exact.hasValue);
    auto capsule = exact.takeValue();
    assert(capsule.usage.payloadBytes == 9 && capsule.usage.definitions == 1);
    limits.maxPayloadBytes = 5;
    auto absent = decodeConfigInput!Settings(`{}`,
        metadata, limits);
    assert(absent.hasValue);
    limits.maxPayloadBytes = 4;
    auto missingSchemaBudget = decodeConfigInput!Settings(`{}`,
        metadata, limits);
    assert(missingSchemaBudget.hasConfigError
        && missingSchemaBudget.configError.kind == ConfigErrorKind.limitExceeded);
    // Document occurrences are validated before any allocation/budget failure.
    auto duplicate = decodeConfigInput!Settings(`{"width":1,"width":2}`,
        metadata, limits);
    assert(duplicate.hasJsonError && duplicate.jsonError.path[] == ".width");
    auto unknown = decodeConfigInput!Settings(`{"extra":1}`,
        metadata, limits);
    assert(unknown.hasJsonError && unknown.jsonError.path[] == ".extra");
}

@("wired.config.json.nativeParserOptionsAndParseLocation")
@safe unittest
{
    struct Settings { int width; }
    auto malformed = decodeConfigInput!Settings("{\n \"width\": }\n");
    assert(malformed.hasJsonError && malformed.jsonError.stage == JsonStage.parse);
    assert(malformed.jsonError.line == 2 && malformed.jsonError.column > 1);
    auto raw = decodeConfigInput!(Settings, JsonReadOptions(rawNumbers: true))(
        `{"width":8}`);
    assert(raw.hasJsonError && raw.jsonError.actualKind == JsonKind.rawNumber);
}

@("wired.config.json.metadataCaptureAndAbsentOverride")
@safe unittest
{
    struct Settings { int width = 4; }
    DefinitionMetadata!Settings metadata;
    metadata.width.priority = 500u;
    auto absent = decodeConfigInput!Settings(`{}`, metadata);
    assert(absent.hasConfigError
        && absent.configError.kind == ConfigErrorKind.invalidMetadata);
    metadata.width.priority.nullify();
    metadata.width.localId = LocalId("value");
    ConfigLimits limits;
    limits.maxPayloadBytes = 13;
    auto tooSmall = decodeConfigInput!Settings(`{"width":8}`, metadata, limits);
    assert(tooSmall.hasConfigError
        && tooSmall.configError.kind == ConfigErrorKind.limitExceeded);
    limits.maxPayloadBytes = 14;
    auto exact = decodeConfigInput!Settings(`{"width":8}`, metadata, limits);
    assert(exact.hasValue);
    auto capsule = exact.takeValue();
    assert(capsule.usage.payloadBytes == 14);
    metadata.width.localId = LocalId("different");
    auto snapshot = snapshotFor(capsule);
    bool observed;
    auto error = snapshot.visitDefinitions!((scope ref const DefinitionView!int view) {
        if (view.sourceId == SourceId("u").bytes)
        {
            observed = true;
            assert(view.localId == LocalId("value").bytes);
        }
    })("width");
    assert(error.kind == ConfigErrorKind.none && observed);
}

@("wired.config.json.sectionPriorityAppliesOnlyToPresentLeaves")
@safe unittest
{
    struct Viewer { int width = 4; bool enabled = true; }
    struct Settings { @(ConfigMerge!Submodule()) Viewer viewer; }
    DefinitionMetadata!Settings metadata;
    metadata.viewer.priority = 500u;
    auto decoded = decodeConfigInput!Settings(`{"viewer":{"width":8}}`, metadata);
    assert(decoded.hasValue);
    auto capsule = decoded.takeValue();
    auto snapshot = snapshotFor(capsule);
    expectDefinitions!int(snapshot, "viewer.width", 2);
    expectDefinitions!bool(snapshot, "viewer.enabled", 1);
    bool observed;
    auto error = snapshot.visitOption!((scope ref const view) {
        static if (is(typeof(view) == const(OptionView!int)))
        {
            observed = true;
            assert(view.path == "viewer.width");
            assert(view.selectedPriority == 500 && view.effective.hasValue
                && view.effective.get == 8);
        }
        else
            assert(false, "unexpected value type for viewer.width");
    })("viewer.width");
    assert(error.kind == ConfigErrorKind.none && observed);
    metadata.viewer.members.enabled.priority = 250u;
    auto invalid = decodeConfigInput!Settings(`{"viewer":{"width":8}}`, metadata);
    assert(invalid.hasConfigError
        && invalid.configError.kind == ConfigErrorKind.invalidMetadata);
}

@("wired.config.json.emptySchemasAndOtherFormatPolicies")
@safe unittest
{
    import sparkles.wired.policy : WireOptional, WireInvalid;

    struct Empty {}
    auto empty = decodeConfigInput!Empty(`{}`);
    assert(empty.hasValue);
    auto capsule = empty.takeValue();
    assert(capsule.usage.options == 0 && capsule.usage.definitions == 0);
    auto unknown = decodeConfigInput!Empty(`{"extra":0}`);
    assert(unknown.hasJsonError && unknown.jsonError.path[] == ".extra");

    struct OtherFormat {}
    struct Settings
    {
        @WireOptional!OtherFormat(onInvalid: WireInvalid.useDefault) int width = 4;
    }
    auto decoded = decodeConfigInput!Settings(`{"width":8}`);
    assert(decoded.hasValue);
    auto supplied = decoded.takeValue();
    auto snapshot = snapshotFor(supplied);
    auto copy = snapshot.copyConfig();
    assert(copy.hasValue && copy.value.width == 8);
    auto invalid = decodeConfigInput!Settings(`{"width":"bad"}`);
    assert(invalid.hasJsonError && invalid.jsonError.path[] == ".width");
}

@("wired.config.json.locatingAfterDeepIgnoredValue")
@safe unittest
{
    struct Settings { int width; }
    enum uint nesting = 65_536;
    enum prefix = `{"extra":`;
    enum middle = `"text [ { \"quoted\" } ]"`;
    enum suffix = ",\n \"width\": \"bad\"}";
    auto text = new char[](prefix.length + 2 * nesting + middle.length + suffix.length);
    size_t cursor;
    text[cursor .. cursor + prefix.length] = prefix;
    cursor += prefix.length;
    text[cursor .. cursor + nesting] = '[';
    cursor += nesting;
    text[cursor .. cursor + middle.length] = middle;
    cursor += middle.length;
    text[cursor .. cursor + nesting] = ']';
    cursor += nesting;
    text[cursor .. $] = suffix;
    DefinitionMetadata!Settings metadata;
    auto decoded = decodeConfigInput!(Settings, JsonReadOptions(maxDepth: nesting + 4))(
        text, metadata, ConfigLimits.init, ConfigDecodeOptions(ConfigUnknownMembers.ignore));
    assert(decoded.hasJsonError && decoded.jsonError.stage == JsonStage.decode);
    assert(decoded.jsonError.path[] == ".width" && decoded.jsonError.targetType == int.stringof
        && decoded.jsonError.actualKind == JsonKind.string_);
    assert(decoded.jsonError.offset == cursor + suffix.length - `"bad"}`.length);
    assert(decoded.jsonError.line == 2 && decoded.jsonError.column == 11);
}

@("wired.config.json.locatingRootAndSectionTypeErrors")
@safe unittest
{
    import sparkles.wired.overlay : WireSection;

    @WireSection struct Viewer { int width; }
    struct Settings { Viewer viewer; }
    auto root = decodeConfigInput!Settings("\n []");
    assert(root.hasJsonError && root.jsonError.path[].length == 0
        && root.jsonError.actualKind == JsonKind.array);
    assert(root.jsonError.offset == 2 && root.jsonError.line == 2
        && root.jsonError.column == 2);
    auto section = decodeConfigInput!Settings("{\n \"viewer\": []}");
    assert(section.hasJsonError && section.jsonError.path[] == ".viewer"
        && section.jsonError.actualKind == JsonKind.array);
    assert(section.jsonError.offset == 13 && section.jsonError.line == 2
        && section.jsonError.column == 12);
}
