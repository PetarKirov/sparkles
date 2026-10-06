/** Allocation-free payload traversal with a transient canonical-text index. */
module sparkles.wired.config.key_accounting;

import std.traits : FieldNameTuple, Unqual;
import std.typecons : Nullable;
import sparkles.wired.config.core : Atomic, Submodule, NullOr, ListOf, AttrsOf,
    ConfigFieldPolicy, catchConfigAllocation;
import sparkles.wired.config.payload : ConfigPresence, GraphKeyRecord;
import sparkles.wired.json.codec : Json, aaKeyText;
import sparkles.wired.walk : WireWalk;

/** Borrows text bytes; its transient index is never part of retained ownership. */
package struct CanonicalKeyAccounting
{
    private bool[const(char)[]] texts;
    bool allocationFailed;

    void seed(const(char)[] text) @safe
    {
        if (!catchConfigAllocation(() @safe { texts[text] = true; return true; }, false))
            allocationFailed = true;
    }

    void seed(const GraphKeyRecord* keys) @safe
    {
        for (const(GraphKeyRecord)* key = keys; key !is null; key = key.next) seed(key.spelling);
    }

    bool charge(const(char)[] text, ref ulong bytes) @safe
    {
        if (allocationFailed) return false;
        if (text in texts) return true;
        if (ulong.max - bytes < text.length) return false;
        if (!catchConfigAllocation(() @safe { texts[text] = true; return true; }, false))
        {
            allocationFailed = true;
            return false;
        }
        bytes += text.length;
        return true;
    }
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

/** Enum spellings are compile-time literals at the original native key site. */
private string keySpelling(K, Root, size_t site)(K key)
{
    static if (is(K == string)) return key;
    else static if (is(K == enum))
    {
        static foreach (name; __traits(allMembers, K))
        {{
            enum member = __traits(getMember, K, name);
            enum text = aaKeyText!(K, Root, site)(member);
            if (key == member) return text;
        }}
        assert(false, "undeclared configuration key");
    }
    else static assert(false, "unsupported configuration key type");
}

/** Counts every supplied source key, without cloning values, keys, or presence. */
package bool chargeGraphKeys(V, P, Root, size_t site)(
    scope ref const V value, scope ref const ConfigPresence!V presence,
    ref CanonicalKeyAccounting accounting, ref ulong bytes)
{
    alias walk = WireWalk!(Json, Root);
    static if (is(V == Nullable!N, N))
    {
        if (!value.isNull && !chargeGraphKeys!(N, ChildPolicy!P, Root, walk.child!(site, 0))(
            value.get, presence.child, accounting, bytes)) return false;
    }
    else static if (is(V == string)) {}
    else static if (is(V == E[n], E, size_t n) || is(V == E[], E))
    {
        foreach (i, ref item; value)
            if (!chargeGraphKeys!(Unqual!E, ChildPolicy!P, Root, walk.child!(site, 0))(
                item, presence.elements[i], accounting, bytes)) return false;
    }
    else static if (is(V == E[K], E, K))
    {
        foreach (key, ref item; value)
        {
            if (!accounting.charge(keySpelling!(Unqual!K, Root, walk.child!(site, 0))(key), bytes)
                || !chargeGraphKeys!(Unqual!E, ChildPolicy!P, Root, walk.child!(site, 1))(
                    item, presence.entries[key], accounting, bytes)) return false;
        }
    }
    else static if (is(V == struct))
    {
        static foreach (ordinal, name; FieldNameTuple!V)
        {{
            alias E = Unqual!(typeof(__traits(getMember, V.init, name)));
            if (__traits(getMember, presence.members, name).supplied
                && !chargeGraphKeys!(E, MemberPolicy!(V, P, name), Root, walk.child!(site, ordinal))(
                    __traits(getMember, value, name), __traits(getMember, presence.members, name),
                    accounting, bytes)) return false;
        }}
    }
    return true;
}

/** Counts canonical texts in a complete default without building presence. */
package bool chargeFullGraphKeys(V, Root, size_t site)(
    scope ref const V value, ref CanonicalKeyAccounting accounting, ref ulong bytes)
{
    alias walk = WireWalk!(Json, Root);
    static if (is(V == Nullable!N, N))
    {
        if (!value.isNull && !chargeFullGraphKeys!(N, Root, walk.child!(site, 0))(
            value.get, accounting, bytes)) return false;
    }
    else static if (is(V == string)) {}
    else static if (is(V == E[n], E, size_t n) || is(V == E[], E))
    {
        foreach (ref item; value)
            if (!chargeFullGraphKeys!(Unqual!E, Root, walk.child!(site, 0))(
                item, accounting, bytes)) return false;
    }
    else static if (is(V == E[K], E, K))
    {
        foreach (key, ref item; value)
            if (!accounting.charge(keySpelling!(Unqual!K, Root, walk.child!(site, 0))(key), bytes)
                || !chargeFullGraphKeys!(Unqual!E, Root, walk.child!(site, 1))(
                    item, accounting, bytes)) return false;
    }
    else static if (is(V == struct))
    {
        static foreach (ordinal, name; FieldNameTuple!V)
            if (!chargeFullGraphKeys!(Unqual!(typeof(__traits(getMember, V.init, name))),
                Root, walk.child!(site, ordinal))(
                    __traits(getMember, value, name), accounting, bytes)) return false;
    }
    return !accounting.allocationFailed;
}
