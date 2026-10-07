/** Finite structural ownership and presence for configuration payloads. */
module sparkles.wired.config.payload;

import std.traits : FieldNameTuple, OriginalType, Unqual, isDynamicArray;
import std.typecons : Nullable;
import sparkles.wired.config.core : Atomic, Submodule, ListOf, AttrsOf, Lines,
    NullOr, ConfigFieldPolicy, Arena, CopyArena, catchConfigAllocation;
import sparkles.wired.policy : hasConvert;
import sparkles.wired.json.codec : Json, aaKeyText;
import sparkles.wired.walk : WireWalk;

private enum configInteger(V) = is(V == byte) || is(V == ubyte)
    || is(V == short) || is(V == ushort) || is(V == int) || is(V == uint)
    || is(V == long) || is(V == ulong);
private enum configPrimitive(V) = configInteger!V || is(V == bool)
    || is(V == float) || is(V == double) || is(V == string);
private template configKey(V)
{
    static if (is(V == enum)) enum configKey = configInteger!(OriginalType!V);
    else enum configKey = is(V == string);
}
private template graphAncestor(V, Ancestors...)
{
    enum graphAncestor = () {
        static foreach (A; Ancestors) static if (is(V == A)) return true;
        return false;
    }();
}

/** Ownership descent never interprets configuration UDAs. */
template supportedConfigGraph(V, Ancestors...)
{
    alias U = Unqual!V;
    static if (graphAncestor!(U, Ancestors)) enum supportedConfigGraph = false;
    else static if (hasConvert!(Json, U)) enum supportedConfigGraph = false;
    else static if (is(U == enum))
        enum supportedConfigGraph = configInteger!(OriginalType!U);
    else static if (configPrimitive!U) enum supportedConfigGraph = true;
    else static if (is(U == Nullable!N, N))
        enum supportedConfigGraph = !is(Unqual!N == Nullable!X, X)
            && supportedConfigGraph!(N, Ancestors, U);
    else static if (is(U == E[n], E, size_t n))
        enum supportedConfigGraph = supportedConfigGraph!(E, Ancestors, U);
    else static if (is(U == E[], E))
        enum supportedConfigGraph = supportedConfigGraph!(E, Ancestors, U);
    else static if (is(U == E[K], E, K))
        enum supportedConfigGraph = configKey!(Unqual!K)
            && supportedConfigGraph!(K, Ancestors, U)
            && supportedConfigGraph!(E, Ancestors, U);
    else static if (is(U == struct))
    {
        static if (!__traits(isPOD, U) || __traits(hasMember, U, "opAssign")
            || __traits(hasMember, U, "opPostMove"))
            enum supportedConfigGraph = false;
        else enum supportedConfigGraph = () {
            static foreach (name; FieldNameTuple!U)
            {
                static if (hasConvert!(Json, __traits(getMember, U, name))) return false;
                static if (!supportedConfigGraph!(
                    typeof(__traits(getMember, U.init, name)), Ancestors, U)) return false;
            }
            return true;
        }();
    }
    else enum supportedConfigGraph = false;
}

/** Policy compatibility is separate from structural ownership eligibility. */
template policyCompatible(V, P)
{
    alias U = Unqual!V;
    static if (!supportedConfigGraph!U) enum policyCompatible = false;
    else static if (is(P == Atomic)) enum policyCompatible = true;
    else static if (is(P == Lines)) enum policyCompatible = is(U == string);
    else static if (is(P == NullOr!Q, Q))
    {
        static if (is(U == Nullable!N, N)) enum policyCompatible = policyCompatible!(N, Q);
        else enum policyCompatible = false;
    }
    else static if (is(P == ListOf!Q, Q))
    {
        static if (is(U == E[], E) && !is(U == string))
            enum policyCompatible = policyCompatible!(E, Q);
        else enum policyCompatible = false;
    }
    else static if (is(P == AttrsOf!Q, Q))
    {
        static if (is(U == E[K], E, K)) enum policyCompatible = policyCompatible!(E, Q);
        else enum policyCompatible = false;
    }
    else static if (is(P == Submodule) && is(U == struct)
        && !is(U == Nullable!N, N))
        enum policyCompatible = () {
            static foreach (name; FieldNameTuple!U)
                static if (!policyCompatible!(typeof(__traits(getMember, U.init, name)),
                    ConfigFieldPolicy!(U, name))) return false;
            return true;
        }();
    else enum policyCompatible = false;
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

/** Member storage is nested so schema fields cannot collide with controls. */
struct ConfigPresence(V)
{
    static assert(supportedConfigGraph!V, "Unsupported configuration graph: " ~ V.stringof);
    bool supplied;
    static if (is(V == Nullable!N, N))
    {
        bool hasValue;
        ConfigPresence!N child;
    }
    else static if (!is(V == string) && is(V == E[n], E, size_t n))
        ConfigPresence!(Unqual!E)[] elements;
    else static if (!is(V == string) && is(V == E[], E))
        ConfigPresence!(Unqual!E)[] elements;
    else static if (is(V == E[K], E, K))
        ConfigPresence!(Unqual!E)[Unqual!K] entries;
    else static if (is(V == struct))
    {
        struct Members
        {
            static foreach (name; FieldNameTuple!V)
                mixin("ConfigPresence!(Unqual!(typeof(__traits(getMember, V.init, \""
                    ~ name ~ "\")))) " ~ name ~ ";");
        }
        Members members;
    }
}

/** Full typed input explicitly supplies every structural member. */
ConfigPresence!V fullPresence(V)(scope ref const V value)
{
    ConfigPresence!V result;
    result.supplied = true;
    static if (is(V == Nullable!N, N))
    {
        result.hasValue = !value.isNull;
        if (result.hasValue) result.child = fullPresence!N(value.get);
    }
    else static if (!is(V == string) && (is(V == E[n], E, size_t n) || is(V == E[], E)))
    {
        result.elements.length = value.length;
        foreach (i, ref item; value) result.elements[i] = fullPresence!(Unqual!E)(item);
    }
    else static if (is(V == E[K], E, K))
        foreach (key, ref item; value)
        {
            static if (is(K == string))
                result.entries[key.idup] = fullPresence!(Unqual!E)(item);
            else result.entries[key] = fullPresence!(Unqual!E)(item);
        }
    else static if (is(V == struct))
        static foreach (name; FieldNameTuple!V)
            __traits(getMember, result.members, name) = fullPresence!(
                Unqual!(typeof(__traits(getMember, V.init, name))))(__traits(getMember, value, name));
    return result;
}

private bool absentPresence(V)(scope ref const ConfigPresence!V presence)
{
    if (presence.supplied) return false;
    static if (is(V == Nullable!N, N))
        return !presence.hasValue && absentPresence!N(presence.child);
    else static if (!is(V == string) && (is(V == E[n], E, size_t n) || is(V == E[], E)))
        return presence.elements.length == 0;
    else static if (is(V == E[K], E, K)) return presence.entries.length == 0;
    else static if (is(V == struct))
    {
        static foreach (name; FieldNameTuple!V)
            if (!absentPresence!(Unqual!(typeof(__traits(getMember, V.init, name))))(
                __traits(getMember, presence.members, name))) return false;
    }
    return true;
}

/** Root supplied is carried by DefinitionSlot; child controls are authoritative. */
bool validPresence(V, P = Atomic)(scope ref const V value,
    scope ref const ConfigPresence!V presence)
{
    static assert(policyCompatible!(V, P));
    static if (is(V == Nullable!N, N))
    {
        if (presence.hasValue != !value.isNull) return false;
        if (value.isNull) return absentPresence!N(presence.child);
        return presence.child.supplied
            && validPresence!(N, ChildPolicy!P)(value.get, presence.child);
    }
    else static if (!is(V == string) && (is(V == E[n], E, size_t n) || is(V == E[], E)))
    {
        if (presence.elements.length != value.length) return false;
        foreach (i, ref item; value)
            if (!presence.elements[i].supplied
                || !validPresence!(Unqual!E, ChildPolicy!P)(item, presence.elements[i])) return false;
    }
    else static if (is(V == E[K], E, K))
    {
        if (presence.entries.length != value.length) return false;
        foreach (key, ref item; value)
        {
            auto child = key in presence.entries;
            if (child is null || !child.supplied
                || !validPresence!(Unqual!E, ChildPolicy!P)(item, *child)) return false;
        }
    }
    else static if (is(V == struct))
        static foreach (name; FieldNameTuple!V)
        {{
            alias E = Unqual!(typeof(__traits(getMember, V.init, name)));
            alias Q = MemberPolicy!(V, P, name);
            if (!__traits(getMember, presence.members, name).supplied)
            {
                static if (!is(P == Submodule)) return false;
                else if (!absentPresence!E(__traits(getMember, presence.members, name))) return false;
            }
            else if (!validPresence!(E, Q)(__traits(getMember, value, name),
                __traits(getMember, presence.members, name))) return false;
        }}
    return true;
}

private bool primitiveDomain(V)(scope ref const V value)
{
    static if (is(V == enum))
    {
        static foreach (member; __traits(allMembers, V))
            if (value == __traits(getMember, V, member)) return true;
        return false;
    }
    else return true;
}

/** Checks supplied domains only; presence admission is independently observable. */
bool validGraph(V, P = Atomic)(scope ref const V value,
    scope ref const ConfigPresence!V presence)
{
    if (!validPresence!(V, P)(value, presence)) return false;
    return validSuppliedGraph!(V, P)(value, presence);
}
private bool validSuppliedGraph(V, P)(scope ref const V value,
    scope ref const ConfigPresence!V presence)
{
    static if (is(V == Nullable!N, N))
        return value.isNull || validSuppliedGraph!(N, ChildPolicy!P)(value.get, presence.child);
    else static if (!is(V == string) && (is(V == E[n], E, size_t n) || is(V == E[], E)))
    {
        foreach (i, ref item; value)
            if (!validSuppliedGraph!(Unqual!E, ChildPolicy!P)(item, presence.elements[i])) return false;
    }
    else static if (is(V == E[K], E, K))
    {
        foreach (key, ref item; value)
            if (!primitiveDomain!(Unqual!K)(key)
                || !validSuppliedGraph!(Unqual!E, ChildPolicy!P)(item, presence.entries[key])) return false;
    }
    else static if (is(V == struct))
        static foreach (name; FieldNameTuple!V)
        {{
            alias E = Unqual!(typeof(__traits(getMember, V.init, name)));
            if (__traits(getMember, presence.members, name).supplied
                && !validSuppliedGraph!(E, MemberPolicy!(V, P, name))(
                    __traits(getMember, value, name), __traits(getMember, presence.members, name))) return false;
        }}
    else return primitiveDomain!V(value);
    return true;
}

private bool validFullGraph(V)(scope ref const V value)
{
    static if (is(V == Nullable!N, N)) return value.isNull || validFullGraph!N(value.get);
    else static if (!is(V == string) && (is(V == E[n], E, size_t n) || is(V == E[], E)))
    {
        foreach (ref item; value) if (!validFullGraph!(Unqual!E)(item)) return false;
    }
    else static if (is(V == E[K], E, K))
    {
        foreach (key, ref item; value)
            if (!primitiveDomain!(Unqual!K)(key) || !validFullGraph!(Unqual!E)(item)) return false;
    }
    else static if (is(V == struct))
    {
        static foreach (name; FieldNameTuple!V)
            if (!validFullGraph!(Unqual!(typeof(__traits(getMember, V.init, name))))(
                __traits(getMember, value, name))) return false;
    }
    else return primitiveDomain!V(value);
    return true;
}

/** Reach declared struct prototypes by type, even behind empty or null storage. */
bool validPrototype(V, P = Atomic)()
{
    static assert(policyCompatible!(V, P));
    static if (is(V == Nullable!N, N)) return validPrototype!(N, ChildPolicy!P)();
    else static if (!is(V == string) && (is(V == E[n], E, size_t n) || is(V == E[], E)))
        return validPrototype!(Unqual!E, ChildPolicy!P)();
    else static if (is(V == E[K], E, K)) return validPrototype!(Unqual!E, ChildPolicy!P)();
    else static if (is(V == struct))
    {
        V prototype;
        if (!validFullGraph!V(prototype)) return false;
        static foreach (name; FieldNameTuple!V)
            if (!validPrototype!(Unqual!(typeof(__traits(getMember, V.init, name))),
                MemberPolicy!(V, P, name))()) return false;
    }
    return true;
}

private bool addCharge(ref ulong total, ulong amount) @safe pure nothrow @nogc
{
    if (amount > ulong.max - total) return false;
    total += amount;
    return true;
}

/** Logical graph charges are independent of backing storage and alias identity. */
bool measureGraph(V, P = Atomic)(scope ref const V value,
    scope ref const ConfigPresence!V presence, out ulong bytes, out ulong nodes)
{
    bytes = nodes = 0;
    if (!validPresence!(V, P)(value, presence)) return false;
    return measureSuppliedGraph!(V, P)(value, presence, bytes, nodes);
}
private bool measureSuppliedGraph(V, P)(scope ref const V value,
    scope ref const ConfigPresence!V presence, ref ulong bytes, ref ulong nodes)
{
    if (!addCharge(nodes, 1)) return false;
    static if (is(V == Nullable!N, N))
    {
        if (!addCharge(bytes, 1)) return false;
        return value.isNull || measureSuppliedGraph!(N, ChildPolicy!P)(
            value.get, presence.child, bytes, nodes);
    }
    else static if (is(V == string)) return addCharge(bytes, value.length);
    else static if (is(V == E[n], E, size_t n) || is(V == E[], E))
    {
        static if (isDynamicArray!V) if (!addCharge(bytes, 1)) return false;
        foreach (i, ref item; value)
            if (!measureSuppliedGraph!(Unqual!E, ChildPolicy!P)(
                item, presence.elements[i], bytes, nodes)) return false;
    }
    else static if (is(V == E[K], E, K))
    {
        if (!addCharge(bytes, 1)) return false;
        foreach (key, ref item; value)
        {
            if (!addCharge(nodes, 1)) return false;
            static if (is(K == string)) { if (!addCharge(bytes, key.length)) return false; }
            else if (!addCharge(bytes, K.sizeof)) return false;
            if (!measureSuppliedGraph!(Unqual!E, ChildPolicy!P)(
                item, presence.entries[key], bytes, nodes)) return false;
        }
    }
    else static if (is(V == struct))
        static foreach (name; FieldNameTuple!V)
        {{
            alias E = Unqual!(typeof(__traits(getMember, V.init, name)));
            if (__traits(getMember, presence.members, name).supplied
                && !measureSuppliedGraph!(E, MemberPolicy!(V, P, name))(
                    __traits(getMember, value, name), __traits(getMember, presence.members, name),
                    bytes, nodes)) return false;
        }}
    else return addCharge(bytes, V.sizeof);
    return true;
}

/** Allocation-free full-value charge for atomic defaults and decoder preflight. */
bool measureFullGraph(V)(scope ref const V value, out ulong bytes, out ulong nodes)
{
    static assert(supportedConfigGraph!V);
    bytes = nodes = 0;
    return measureFullContents!V(value, bytes, nodes);
}
private bool measureFullContents(V)(scope ref const V value, ref ulong bytes, ref ulong nodes)
{
    if (!addCharge(nodes, 1)) return false;
    static if (is(V == Nullable!N, N))
    {
        if (!addCharge(bytes, 1)) return false;
        return value.isNull || measureFullContents!N(value.get, bytes, nodes);
    }
    else static if (is(V == string)) return addCharge(bytes, value.length);
    else static if (is(V == E[n], E, size_t n) || is(V == E[], E))
    {
        static if (isDynamicArray!V) if (!addCharge(bytes, 1)) return false;
        foreach (ref item; value)
            if (!measureFullContents!(Unqual!E)(item, bytes, nodes)) return false;
    }
    else static if (is(V == E[K], E, K))
    {
        if (!addCharge(bytes, 1)) return false;
        foreach (key, ref item; value)
            if (!measureFullContents!(Unqual!K)(key, bytes, nodes)
                || !measureFullContents!(Unqual!E)(item, bytes, nodes)) return false;
    }
    else static if (is(V == struct))
    {
        static foreach (name; FieldNameTuple!V)
            if (!measureFullContents!(Unqual!(typeof(__traits(getMember, V.init, name))))(
                __traits(getMember, value, name), bytes, nodes)) return false;
    }
    else return addCharge(bytes, V.sizeof);
    return true;
}

// Retained descriptors root native AA backings and are actual ownership storage.
private struct GraphMapShape(V)
{
    V value;
    ConfigPresence!V presence;
}
private struct IndependentMapShape(V)
{
    V value;
}

/** Canonical text is owned once; every typed key remains separately charged. */
package struct GraphKeyRecord
{
    string spelling;
    GraphKeyRecord* next;
}
private bool retainKey(A)(ref Arena!A arena, scope const(char)[] text,
    ref GraphKeyRecord* keys, out string spelling)
{
    for (auto record = keys; record !is null; record = record.next)
        if (record.spelling == text) { spelling = record.spelling; return true; }
    auto record = arena.allocate!GraphKeyRecord();
    if (record is null || !arena.text(text, record.spelling)) return false;
    record.next = keys;
    keys = record;
    spelling = record.spelling;
    return true;
}

/** Does not touch caller data for absent fields, including shared initializers. */
package void clearGraph(V)(out V value)
{
    static if (is(V == Nullable!N, N)) value.nullify();
    else static if (is(V == string) || is(V == E[], E) || is(V == E[K], E, K)) value = null;
    else static if (is(V == E[n], E, size_t n))
        foreach (ref item; value) clearGraph!(Unqual!E)(item);
    else static if (is(V == struct))
        static foreach (name; FieldNameTuple!V)
            clearGraph!(Unqual!(typeof(__traits(getMember, V.init, name))))(
                __traits(getMember, value, name));
    else value = V.init;
}

private bool emptyMap(V)(out V value)
{
    static if (is(V == E[K], E, K))
    {
        auto success = catchConfigAllocation(() {
            E item;
            clearGraph!E(item);
            value[K.init] = item;
            value.remove(K.init);
            return true;
        }, false);
        if (!success) value = null;
        return success;
    }
    else static assert(false);
}

/** Captures original-site keys and recursively owns independent source presence. */
bool captureGraph(V, P, Root, size_t site, A)(ref Arena!A arena,
    scope ref const V value, scope ref const ConfigPresence!V presence,
    out V captured, out ConfigPresence!V capturedPresence, ref GraphKeyRecord* keys)
{
    static assert(policyCompatible!(V, P));
    alias walk = WireWalk!(Json, Root);
    clearGraph!V(captured);
    capturedPresence = ConfigPresence!V.init;
    capturedPresence.supplied = true;
    static if (is(V == Nullable!N, N))
    {
        capturedPresence.hasValue = !value.isNull;
        if (value.isNull) return true;
        N child;
        if (!captureGraph!(N, ChildPolicy!P, Root, walk.child!(site, 0))(
            arena, value.get, presence.child, child, capturedPresence.child, keys)) return false;
        captured = child;
    }
    else static if (is(V == string)) return arena.text(value, captured);
    else static if (is(V == E[n], E, size_t n) || is(V == E[], E))
    {
        capturedPresence.elements = arena.array!(ConfigPresence!(Unqual!E))(value.length);
        if (value.length && capturedPresence.elements.ptr is null) return false;
        static if (isDynamicArray!V)
        {
            if (!value.length)
            {
                if (value.ptr !is null && !arena.nonNullArray(captured)) return false;
            }
            else
            {
                captured = arena.array!(Unqual!E)(value.length);
                if (captured.ptr is null) return false;
            }
        }
        foreach (i, ref item; value)
            if (!captureGraph!(Unqual!E, ChildPolicy!P, Root, walk.child!(site, 0))(
                arena, item, presence.elements[i], captured[i], capturedPresence.elements[i], keys)) return false;
    }
    else static if (is(V == E[K], E, K))
    {
        auto shape = arena.allocate!(GraphMapShape!V)();
        if (shape is null) return false;
        if (!value.length && value !is null && !emptyMap!V(shape.value)) return false;
        foreach (key, ref item; value)
        {
            string spelling;
            if (!catchConfigAllocation(() => retainKey(arena,
                aaKeyText!(Unqual!K, Root, walk.child!(site, 0))(key),
                keys, spelling), false)) return false;
            Unqual!K ownedKey;
            static if (is(K == string))
            {
                if (key.ptr is null) ownedKey = null;
                else if (spelling.ptr !is null) ownedKey = spelling;
                else if (!arena.text(key, ownedKey)) return false;
            }
            else ownedKey = key;
            E owned;
            ConfigPresence!(Unqual!E) childPresence;
            if (!captureGraph!(Unqual!E, ChildPolicy!P, Root, walk.child!(site, 1))(
                arena, item, presence.entries[key], owned, childPresence, keys)) return false;
            if (!catchConfigAllocation(() {
                shape.value[ownedKey] = owned;
                shape.presence.entries[ownedKey] = childPresence;
                return true;
            }, false)) return false;
        }
        captured = shape.value;
        capturedPresence.entries = shape.presence.entries;
    }
    else static if (is(V == struct))
        static foreach (ordinal, name; FieldNameTuple!V)
        {{
            alias E = Unqual!(typeof(__traits(getMember, V.init, name)));
            if (__traits(getMember, presence.members, name).supplied)
            {
                if (!captureGraph!(E, MemberPolicy!(V, P, name), Root, walk.child!(site, ordinal))(
                    arena, __traits(getMember, value, name), __traits(getMember, presence.members, name),
                    __traits(getMember, captured, name), __traits(getMember, capturedPresence.members, name),
                    keys)) return false;
            }
        }}
    else captured = value;
    return true;
}

/** Creates a detached full mutable graph with no retained-owner aliases. */
bool independentGraph(V, A)(ref CopyArena!A arena, scope ref const V value, out V result)
{
    static assert(supportedConfigGraph!V);
    clearGraph!V(result);
    static if (is(V == Nullable!N, N))
    {
        if (value.isNull) return true;
        N child;
        if (!independentGraph!N(arena, value.get, child)) return false;
        result = child;
    }
    else static if (is(V == string)) return arena.text(value, result);
    else static if (is(V == E[n], E, size_t n) || is(V == E[], E))
    {
        static if (isDynamicArray!V)
        {
            if (!value.length)
            {
                if (value.ptr !is null && !arena.nonNullArray(result)) return false;
            }
            else
            {
                result = arena.array!(Unqual!E)(value.length);
                if (result.ptr is null) return false;
            }
        }
        foreach (i, ref item; value)
            if (!independentGraph!(Unqual!E)(arena, item, result[i])) return false;
    }
    else static if (is(V == E[K], E, K))
    {
        auto shape = arena.records.allocate!(IndependentMapShape!V)();
        if (shape is null) return false;
        if (!value.length && value !is null && !emptyMap!V(shape.value)) return false;
        foreach (key, ref item; value)
        {
            Unqual!K ownedKey;
            if (!independentGraph!(Unqual!K)(arena, key, ownedKey)) return false;
            E owned;
            if (!independentGraph!(Unqual!E)(arena, item, owned)) return false;
            if (!catchConfigAllocation(() {
                shape.value[ownedKey] = owned;
                return true;
            }, false)) return false;
        }
        result = shape.value;
    }
    else static if (is(V == struct))
    {
        static foreach (name; FieldNameTuple!V)
            if (!independentGraph!(Unqual!(typeof(__traits(getMember, V.init, name))))(
                arena, __traits(getMember, value, name), __traits(getMember, result, name))) return false;
    }
    else result = value;
    return true;
}
