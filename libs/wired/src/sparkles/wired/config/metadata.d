/** Typed branch controls and owned metadata for configuration collections. */
module sparkles.wired.config.metadata;

import std.traits : FieldNameTuple, Unqual;
import std.typecons : Nullable;
import sparkles.wired.config.core : Atomic, Submodule, ListOf, AttrsOf, NullOr,
    ConfigFieldPolicy, SourceLocation, LeafDefinitionMetadata,
    SectionDefinitionMetadata, Arena, catchConfigAllocation;
import sparkles.wired.config.payload : ConfigPresence, supportedConfigGraph,
    policyCompatible, fullPresence, validPresence;

/**
 * Optional branch controls, with an explicit native source shape.
 *
 * `shaped` distinguishes a checked source shape from the default inert tree.
 * Schema members live in `members`, so names such as `priority` or `shaped`
 * cannot collide with metadata controls. Branches inherit source/root identity;
 * they cannot supply a source or a local ID of their own.
 */
struct ConfigBranchMetadata(V)
{
    static assert(supportedConfigGraph!V, "Unsupported configuration graph: " ~ V.stringof);
    bool shaped;
    Nullable!uint priority;
    Nullable!int order;
    Nullable!SourceLocation location;
    static if (is(V == Nullable!N, N))
    {
        bool hasValue;
        ConfigBranchMetadata!N child;
    }
    else static if (!is(V == string) && (is(V == E[n], E, size_t n) || is(V == E[], E)))
        ConfigBranchMetadata!(Unqual!E)[] elements;
    else static if (is(V == E[K], E, K))
        ConfigBranchMetadata!(Unqual!E)[Unqual!K] entries;
    else static if (is(V == struct))
    {
        struct Members
        {
            static foreach (name; FieldNameTuple!V)
                mixin("ConfigBranchMetadata!(Unqual!(typeof(__traits(getMember, V.init, \""
                    ~ name ~ "\")))) " ~ name ~ ";");
        }
        Members members;
    }

    this(scope ref const V value, scope ref const ConfigPresence!V presence)
    {
        this = fullBranchMetadata!V(value, presence);
    }

}

/** Root identity controls remain identical to a scalar definition's controls. */
struct CollectionDefinitionMetadata(V)
{
    LeafDefinitionMetadata root;
    alias root this;
    ConfigBranchMetadata!V branches;
}

private template ChildPolicy(P)
{
    static if (is(P == NullOr!Q, Q) || is(P == ListOf!Q, Q) || is(P == AttrsOf!Q, Q))
        alias ChildPolicy = Q;
    else alias ChildPolicy = Atomic;
}

private template MemberPolicy(V, P, string name)
{
    static if (is(P == Submodule)) alias MemberPolicy = ConfigFieldPolicy!(V, name);
    else alias MemberPolicy = Atomic;
}

package bool validBranchMetadataControls(V)(scope ref const ConfigBranchMetadata!V metadata)
{
    return metadata.location.isNull
        || (metadata.location.get.line != 0 && metadata.location.get.column != 0);
}

/** Structural details below an Atomic option cannot influence selection. */
package bool validAtomicChildBranchMetadataControls(V)(
    scope ref const ConfigBranchMetadata!V metadata)
{
    return validBranchMetadataControls!V(metadata)
        && metadata.priority.isNull && metadata.order.isNull;
}

private bool defaultBranchChildren(V)(scope ref const ConfigBranchMetadata!V metadata)
{
    static if (is(V == Nullable!N, N))
        return !metadata.hasValue && branchMetadataInert!N(metadata.child);
    else static if (!is(V == string) && (is(V == E[n], E, size_t n) || is(V == E[], E)))
        return metadata.elements.length == 0;
    else static if (is(V == E[K], E, K)) return metadata.entries.length == 0;
    else static if (is(V == struct))
    {
        static foreach (name; FieldNameTuple!V)
            if (!branchMetadataInert!(Unqual!(typeof(__traits(getMember, V.init, name))))(
                __traits(getMember, metadata.members, name))) return false;
    }
    return true;
}

/** Explicit shapes are not inert: even control-free shapes must be checked. */
package bool branchMetadataInert(V)(scope ref const ConfigBranchMetadata!V metadata)
{
    return !metadata.shaped && metadata.priority.isNull && metadata.order.isNull
        && metadata.location.isNull && defaultBranchChildren!V(metadata);
}

/** An absent section may carry section-wide priority, but no child overrides. */
package bool validAbsentBranchMetadata(V, P = Atomic)(
    scope ref const ConfigBranchMetadata!V metadata)
{
    static if (is(P == Submodule))
        return !metadata.shaped && metadata.order.isNull && metadata.location.isNull
            && defaultBranchChildren!V(metadata);
    else return branchMetadataInert!V(metadata);
}

/** Checks metadata against native positions, typed keys and supplied members. */
bool validBranchMetadata(V, P = Atomic)(scope ref const V value,
    scope ref const ConfigPresence!V presence,
    scope ref const ConfigBranchMetadata!V metadata)
{
    static assert(policyCompatible!(V, P));
    // Root presence.supplied is carried by DefinitionSlot, as in validPresence.
    return validPresence!(V, P)(value, presence)
        && validSuppliedBranchMetadata!(V, P, false)(value, presence, metadata);
}

private bool validSuppliedBranchMetadata(V, P, bool atomicChild)(
    scope ref const V value, scope ref const ConfigPresence!V presence,
    scope ref const ConfigBranchMetadata!V metadata)
{
    static if (atomicChild)
    {
        if (!validAtomicChildBranchMetadataControls!V(metadata)) return false;
    }
    else if (!validBranchMetadataControls!V(metadata)) return false;
    if (!metadata.shaped) return defaultBranchChildren!V(metadata);

    static if (is(V == Nullable!N, N))
    {
        if (metadata.hasValue != presence.hasValue) return false;
        if (!metadata.hasValue)
            return validAbsentBranchMetadata!(N, ChildPolicy!P)(metadata.child);
        return validSuppliedBranchMetadata!(N, ChildPolicy!P, atomicChild || is(P == Atomic))(
            value.get, presence.child, metadata.child);
    }
    else static if (!is(V == string) && (is(V == E[n], E, size_t n) || is(V == E[], E)))
    {
        if (metadata.elements.length != value.length) return false;
        foreach (i, ref item; value)
            if (!validSuppliedBranchMetadata!(Unqual!E, ChildPolicy!P,
                atomicChild || is(P == Atomic))(
                    item, presence.elements[i], metadata.elements[i])) return false;
    }
    else static if (is(V == E[K], E, K))
    {
        if (metadata.entries.length != value.length) return false;
        foreach (key, ref item; value)
        {
            auto branch = key in metadata.entries;
            if (branch is null || !validSuppliedBranchMetadata!(Unqual!E, ChildPolicy!P,
                atomicChild || is(P == Atomic))(
                    item, presence.entries[key], *branch)) return false;
        }
    }
    else static if (is(V == struct))
        static foreach (name; FieldNameTuple!V)
        {{
            alias E = Unqual!(typeof(__traits(getMember, V.init, name)));
            alias Q = MemberPolicy!(V, P, name);
            if (!__traits(getMember, presence.members, name).supplied)
            {
                if (!validAbsentBranchMetadata!(E, Q)(
                    __traits(getMember, metadata.members, name))) return false;
            }
            else if (!validSuppliedBranchMetadata!(E, Q, atomicChild || is(P == Atomic))(
                __traits(getMember, value, name), __traits(getMember, presence.members, name),
                __traits(getMember, metadata.members, name))) return false;
        }}
    return true;
}

/** Constructs a compatible shaped tree without inferring presence from values. */
ConfigBranchMetadata!V fullBranchMetadata(V)(scope ref const V value,
    scope ref const ConfigPresence!V presence)
{
    ConfigBranchMetadata!V result;
    result.shaped = true;
    static if (is(V == Nullable!N, N))
    {
        result.hasValue = presence.hasValue;
        if (result.hasValue) result.child = fullBranchMetadata!N(value.get, presence.child);
    }
    else static if (!is(V == string) && (is(V == E[n], E, size_t n) || is(V == E[], E)))
    {
        result.elements.length = value.length;
        foreach (i, ref item; value)
            result.elements[i] = fullBranchMetadata!(Unqual!E)(item, presence.elements[i]);
    }
    else static if (is(V == E[K], E, K))
        foreach (key, ref item; value)
        {
            static if (is(K == string))
                result.entries[key.idup] = fullBranchMetadata!(Unqual!E)(item, presence.entries[key]);
            else result.entries[key] = fullBranchMetadata!(Unqual!E)(item, presence.entries[key]);
        }
    else static if (is(V == struct))
        static foreach (name; FieldNameTuple!V)
        {{
            alias E = Unqual!(typeof(__traits(getMember, V.init, name)));
            if (__traits(getMember, presence.members, name).supplied)
                __traits(getMember, result.members, name) = fullBranchMetadata!E(
                    __traits(getMember, value, name), __traits(getMember, presence.members, name));
        }}
    return result;
}

// A retained descriptor roots native AA storage in the owning arena. It is real
// storage, not an allocation checkpoint standing in for a later hidden clone.
private struct MetadataMapShape(V)
{
    ConfigBranchMetadata!V metadata;
}

/** Captures borrowed metadata once; owned-input transfer reuses this graph. */
bool captureBranchMetadata(V, A)(ref Arena!A arena,
    scope ref const ConfigBranchMetadata!V metadata,
    out ConfigBranchMetadata!V captured)
{
    captured.shaped = metadata.shaped;
    captured.priority = metadata.priority;
    captured.order = metadata.order;
    captured.location = metadata.location;
    static if (is(V == Nullable!N, N))
    {
        captured.hasValue = metadata.hasValue;
        return captureBranchMetadata!(N, A)(arena, metadata.child, captured.child);
    }
    else static if (!is(V == string) && (is(V == E[n], E, size_t n) || is(V == E[], E)))
    {
        if (metadata.elements.ptr !is null)
        {
            captured.elements = arena.nonNullArray!(ConfigBranchMetadata!(Unqual!E))(
                metadata.elements.length);
            if (captured.elements.ptr is null) return false;
        }
        foreach (i, ref child; metadata.elements)
            if (!captureBranchMetadata!(Unqual!E, A)(arena, child, captured.elements[i])) return false;
    }
    else static if (is(V == E[K], E, K))
    {
        if (metadata.entries is null) return true;
        auto shape = arena.allocate!(MetadataMapShape!V)();
        if (shape is null) return false;
        if (metadata.entries.length == 0)
        {
            if (!catchConfigAllocation(() {
                shape.metadata.entries[K.init] = ConfigBranchMetadata!(Unqual!E).init;
                shape.metadata.entries.remove(K.init);
                return true;
            }, false)) return false;
        }
        foreach (key, ref child; metadata.entries)
        {
            Unqual!K ownedKey;
            static if (is(K == string))
            {
                if (!arena.text(key, ownedKey)) return false;
            }
            else ownedKey = key;
            ConfigBranchMetadata!(Unqual!E) ownedChild;
            if (!captureBranchMetadata!(Unqual!E, A)(arena, child, ownedChild)) return false;
            if (!catchConfigAllocation(() {
                shape.metadata.entries[ownedKey] = ownedChild;
                return true;
            }, false)) return false;
        }
        captured.entries = shape.metadata.entries;
    }
    else static if (is(V == struct))
        static foreach (name; FieldNameTuple!V)
            if (!captureBranchMetadata!(Unqual!(typeof(__traits(getMember, V.init, name))), A)(
                arena, __traits(getMember, metadata.members, name),
                __traits(getMember, captured.members, name))) return false;
    return true;
}

/// Metadata keys and nullable shape match the original typed presence.
@("wired.config.metadata.exactTypedKeysAndNativeWrapperShape") @safe unittest
{
    enum Key { first, second }
    int[Key] value = [Key.first: 3];
    auto presence = fullPresence(value);
    auto metadata = fullBranchMetadata(value, presence);
    assert((validBranchMetadata!(typeof(value), AttrsOf!Atomic)(value, presence, metadata)));
    metadata.entries.remove(Key.first);
    metadata.entries[Key.second] = ConfigBranchMetadata!int.init;
    assert(!(validBranchMetadata!(typeof(value), AttrsOf!Atomic)(value, presence, metadata)));

    Nullable!(int[]) wrapped;
    auto wrappedPresence = fullPresence(wrapped);
    auto wrappedMetadata = fullBranchMetadata(wrapped, wrappedPresence);
    assert((validBranchMetadata!(typeof(wrapped), NullOr!(ListOf!Atomic))(
        wrapped, wrappedPresence, wrappedMetadata)));
    wrappedMetadata.hasValue = true;
    assert(!(validBranchMetadata!(typeof(wrapped), NullOr!(ListOf!Atomic))(
        wrapped, wrappedPresence, wrappedMetadata)));
    wrappedMetadata.hasValue = false;
    wrappedMetadata.child.order = 2;
    assert(!(validBranchMetadata!(typeof(wrapped), NullOr!(ListOf!Atomic))(
        wrapped, wrappedPresence, wrappedMetadata)));
}

/// Absent members reject overrides except inert section-wide priority.
@("wired.config.metadata.sparseAbsenceAndUnshapedDescendants") @safe unittest
{
    import sparkles.wired.overlay : WireSection;
    @WireSection struct Section { int item; }
    struct Value { int shaped; Section section; int absent; }
    Value value;
    ConfigPresence!Value presence;
    presence.members.shaped.supplied = true;
    ConfigBranchMetadata!Value metadata;
    metadata.members.shaped.priority = 3u;
    assert(!(validBranchMetadata!(Value, Submodule)(value, presence, metadata)));
    metadata.shaped = true;
    assert((validBranchMetadata!(Value, Submodule)(value, presence, metadata)));
    metadata.members.absent.priority = 2u;
    assert(!(validBranchMetadata!(Value, Submodule)(value, presence, metadata)));
    metadata.members.absent.priority.nullify();
    metadata.members.section.priority = 4u;
    assert((validBranchMetadata!(Value, Submodule)(value, presence, metadata)));
    metadata.members.section.order = 1;
    assert(!(validBranchMetadata!(Value, Submodule)(value, presence, metadata)));
    metadata.members.section.order.nullify();
    metadata.members.section.members.item.priority = 5u;
    assert(!(validBranchMetadata!(Value, Submodule)(value, presence, metadata)));
}

/// Atomic descendants expose locations but cannot change selection.
@("wired.config.metadata.atomicDescendantsCannotOverrideSelection") @safe unittest
{
    struct Value { int[] priority; }
    Value value;
    value.priority = [1];
    auto presence = fullPresence(value);
    auto metadata = fullBranchMetadata(value, presence);
    metadata.priority = 8u;
    metadata.members.priority.elements[0].location = SourceLocation(9, 2, 4);
    assert(validBranchMetadata(value, presence, metadata));
    metadata.members.priority.elements[0].priority = 1u;
    assert(!validBranchMetadata(value, presence, metadata));
    metadata.members.priority.elements[0].priority.nullify();
    metadata.members.priority.elements[0].location = SourceLocation(9, 0, 4);
    assert(!validBranchMetadata(value, presence, metadata));
}

/// Captured metadata survives caller mutation and preserves backing states.
@("wired.config.metadata.captureOwnsNestedBranchesAndEmptyBacking") @safe unittest
{
    import sparkles.wired.config.core : ConfigAllocator;
    Arena!ConfigAllocator arena;
    scope (exit) arena.release();
    alias Value = int[][string];
    Value value = ["key": [1, 2]];
    auto presence = fullPresence(value);
    auto metadata = fullBranchMetadata(value, presence);
    metadata.entries["key"].elements[1].order = 7;
    ConfigBranchMetadata!Value captured;
    assert(captureBranchMetadata(arena, metadata, captured));
    metadata.entries["key"].elements[1].order = 3;
    metadata.entries.remove("key");
    assert(captured.entries["key"].elements[1].order.get == 7);

    ConfigBranchMetadata!(int[]) empty;
    empty.shaped = true;
    empty.elements = new ConfigBranchMetadata!int[1];
    empty.elements = empty.elements[0 .. 0];
    ConfigBranchMetadata!(int[]) capturedEmpty;
    assert(captureBranchMetadata(arena, empty, capturedEmpty));
    assert(capturedEmpty.elements.length == 0 && capturedEmpty.elements.ptr !is null);
    empty.elements = null;
    assert(captureBranchMetadata(arena, empty, capturedEmpty));
    assert(capturedEmpty.elements.ptr is null);

    ConfigBranchMetadata!Value emptyMap;
    emptyMap.shaped = true;
    emptyMap.entries["temporary"] = ConfigBranchMetadata!(int[]).init;
    emptyMap.entries.remove("temporary");
    assert(captureBranchMetadata(arena, emptyMap, captured));
    assert(captured.entries.length == 0 && captured.entries !is null);
    emptyMap.entries = null;
    assert(captureBranchMetadata(arena, emptyMap, captured));
    assert(captured.entries is null);
}
