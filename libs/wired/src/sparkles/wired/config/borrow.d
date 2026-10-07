/** Read-only, non-owning projections of configuration graphs and presence. */
module sparkles.wired.config.borrow;

import std.traits : FieldNameTuple, Unqual;
import std.typecons : Nullable;
import sparkles.wired.config.core : ConfigBorrowedValue, borrowValue;
import sparkles.wired.config.payload : ConfigPresence;

// Presence is a generated structural graph, not a second configuration model.
// Recognize its nodes here so children keep their direct presence controls.
private template BorrowedNode(V)
{
    static if (is(Unqual!V == ConfigPresence!N, N))
        alias BorrowedNode = ConfigPresenceView!N;
    else
        alias BorrowedNode = ConfigBorrowedValue!(Unqual!V);
}
private BorrowedNode!V borrowNode(V)(return ref const V original)
    if (is(V == struct) || is(V == E[N], E, size_t N))
{
    static if (is(Unqual!V == ConfigPresence!N, N))
        return ConfigPresenceView!N(original);
    else
        return borrowValue!(Unqual!V)(original);
}
private BorrowedNode!V borrowNode(V)(return scope const V original)
    if (!is(V == struct) && !is(V == E[N], E, size_t N))
{
    return borrowValue!(Unqual!V)(original);
}

/** Both dynamic and fixed arrays borrow their original storage as a slice.
No slice, pointer, or mutable element reference is publicly exposed. */
struct ConfigArrayValueView(E)
{
    private const(E)[] values_;

    this(return scope const(E)[] original) @safe pure nothrow @nogc
    {
        values_ = original;
    }
    this(size_t N)(return ref const(E)[N] original) @safe pure nothrow @nogc
    {
        values_ = original[];
    }

    @property size_t length() scope const @safe pure nothrow @nogc => values_.length;
    @property bool isNull() scope const @safe pure nothrow @nogc => values_.ptr is null;
    size_t opDollar() scope const @safe pure nothrow @nogc => values_.length;

    const(BorrowedNode!E) opIndex(size_t index) return scope const @safe pure nothrow @nogc
    {
        return borrowNode!E(values_[index]);
    }

    int opApply(scope int delegate(scope const(BorrowedNode!E)) @safe consume)
        scope const @safe
    {
        foreach (ref value; values_)
        {
            auto result = consume(borrowNode!E(value));
            if (result) return result;
        }
        return 0;
    }
    int opApply(scope int delegate(size_t, scope const(BorrowedNode!E)) @safe consume)
        scope const @safe
    {
        foreach (index, ref value; values_)
        {
            auto result = consume(index, borrowNode!E(value));
            if (result) return result;
        }
        return 0;
    }

}

/** An associative array projection. Native iteration order is preserved;
keys are borrowed just like values, including immutable-string keys. */
struct ConfigMapValueView(K, V)
{
    private const(V)[K] values_;

    this(return scope const(V[K]) original) @safe pure nothrow @nogc
    {
        // Only the private AA handle is mutable; this projection never inserts,
        // removes, or exposes mutable keys or values.
        values_ = (() @trusted => cast(typeof(values_)) original)();
    }

    @property size_t length() scope const @safe pure nothrow @nogc => values_.length;
    @property bool isNull() scope const @safe pure nothrow @nogc => values_ is null;

    // Strengthening a borrowed string key is solely for native lookup. The key
    // is never inserted, retained, or returned; only a pointer into this map is
    // returned, with the receiver's lifetime. Native lookup performs no copy.
    private const(V)* find(scope const(BorrowedNode!K) key)
        return scope const @trusted pure nothrow @nogc
    {
        static if (is(Unqual!K == string)) return cast(string) key in values_;
        else return key in values_;
    }
    bool contains(scope const(BorrowedNode!K) key) scope const @safe pure nothrow @nogc
    {
        return find(key) !is null;
    }
    const(BorrowedNode!V) opIndex(scope const(BorrowedNode!K) key)
        return scope const @safe pure nothrow @nogc
    {
        auto found = find(key);
        assert(found !is null, "Configuration map key is absent");
        return borrowNode!V(*found);
    }

    int opApply(scope int delegate(scope const(BorrowedNode!V)) @safe consume)
        scope const @safe
    {
        foreach (ref value; values_)
        {
            auto result = consume(borrowNode!V(value));
            if (result) return result;
        }
        return 0;
    }
    int opApply(scope int delegate(scope const(BorrowedNode!K),
        scope const(BorrowedNode!V)) @safe consume) scope const @safe
    {
        foreach (key, ref value; values_)
        {
            auto result = consume(borrowNode!K(key), borrowNode!V(value));
            if (result) return result;
        }
        return 0;
    }
}

// Generated field getters must not reserve a schema-field name for storage.
private template memberStorageName(V, string candidate = "__configBorrowedStorage")
{
    static if (__traits(hasMember, V, candidate))
        enum memberStorageName = memberStorageName!(V, candidate ~ "_");
    else
        enum memberStorageName = candidate;
}

/** Generated original field names, with each field borrowed recursively. */
struct ConfigStructMembersView(V)
{
    mixin("private const(V)* " ~ memberStorageName!V ~ ";");

    this(return ref const V original) @safe pure nothrow @nogc
    {
        mixin(memberStorageName!V ~ " = &original;");
    }

    static foreach (name; FieldNameTuple!V)
    {
        mixin("@property auto " ~ name ~ "()() return scope const { "
            ~ "return .borrowNode(__traits(getMember, *" ~ memberStorageName!V
            ~ ", \"" ~ name ~ "\")); }");
    }
}

/** A plain struct projection. The members namespace preserves original field
names even when a field is itself named members or another view control. */
struct ConfigStructValueView(V)
{
    private ConfigStructMembersView!V members_;

    this(return ref const V original) @safe pure nothrow @nogc
    {
        members_ = ConfigStructMembersView!V(original);
    }
    @property const(ConfigStructMembersView!V) members()
        return scope const @safe pure nothrow @nogc
    {
        return members_;
    }
}


/** A structural view of ConfigPresence!V. Positions, typed keys, supplied
bits, null controls, and original member names are retained without copying. */
struct ConfigPresenceView(V)
{
    private const(ConfigPresence!V)* presence_;

    this(return ref const ConfigPresence!V original) @safe pure nothrow @nogc
    {
        presence_ = &original;
    }
    @property bool supplied() scope const @safe pure nothrow @nogc
    {
        assert(presence_ !is null, "Configuration presence view is uninitialized");
        return presence_.supplied;
    }

    static if (is(V == Nullable!N, N))
    {
        @property bool hasValue() scope const @safe pure nothrow @nogc
        {
            assert(presence_ !is null, "Configuration presence view is uninitialized");
            return presence_.hasValue;
        }
        @property ConfigPresenceView!N child() return scope const @safe pure nothrow @nogc
        {
            assert(presence_ !is null, "Configuration presence view is uninitialized");
            return ConfigPresenceView!N(presence_.child);
        }
    }
    else static if (!is(V == string)
        && (is(V == E[n], E, size_t n) || is(V == E[], E)))
    {
        @property ConfigArrayValueView!(ConfigPresence!(Unqual!E)) elements()
            return scope const @safe pure nothrow @nogc
        {
            assert(presence_ !is null, "Configuration presence view is uninitialized");
            return typeof(return)(presence_.elements);
        }
    }
    else static if (is(V == E[K], E, K))
    {
        @property ConfigMapValueView!(Unqual!K, ConfigPresence!(Unqual!E)) entries()
            return scope const @safe pure nothrow @nogc
        {
            assert(presence_ !is null, "Configuration presence view is uninitialized");
            return typeof(return)(presence_.entries);
        }
    }
    else static if (is(V == struct))
    {
        @property ConfigStructMembersView!(typeof(ConfigPresence!V.init.members)) members()
            return scope const @safe pure nothrow @nogc
        {
            assert(presence_ !is null, "Configuration presence view is uninitialized");
            return typeof(return)(presence_.members);
        }
    }
}

private void inspectBorrowed(alias inspect, V)(scope ref const V view)
{
    inspect(view);
}

/// Collection views preserve backing states, nested values, and generated presence.
@("wired.config.borrow.collectionValuesAndPresence")
@safe unittest
{
    import sparkles.wired.config.payload : fullPresence;

    struct Item { string label; string[][string] groups; }
    Item original = Item("label", ["group": ["first", "second"]]);
    scope item = ConfigStructValueView!Item(original);
    assert(item.members.label == "label");
    assert(item.members.groups["group"][1] == "second");
    assert(item.members.groups.contains("group"));
    assert(!item.members.groups.contains("missing"));

    string[] absent;
    auto storage = new string[1];
    auto empty = storage[0 .. 0];
    scope absentView = ConfigArrayValueView!string(absent);
    scope emptyView = ConfigArrayValueView!string(empty);
    assert(absentView.length == 0 && absentView.isNull);
    assert(emptyView.length == 0 && !emptyView.isNull);
    string[2] fixed = ["first", "second"];
    scope fixedView = ConfigArrayValueView!string(fixed);
    assert(fixedView.length == 2 && fixedView[$ - 1] == "second");
    size_t visited;
    foreach (index, value; fixedView)
    {
        assert(value == fixed[index]);
        ++visited;
    }
    assert(visited == 2);
    foreach (key, values; item.members.groups)
    {
        assert(key == "group");
        assert(values[0] == "first" && values[1] == "second");
    }

    auto presence = fullPresence!Item(original);
    presence.members.groups.entries["group"].elements[1].supplied = false;
    scope presenceView = ConfigPresenceView!Item(presence);
    assert(presenceView.supplied && presenceView.members.label.supplied);
    assert(presenceView.members.groups.entries["group"].elements[0].supplied);
    assert(!presenceView.members.groups.entries["group"].elements[1].supplied);

    auto fixedPresence = fullPresence!(string[2])(fixed);
    scope fixedPresenceView = ConfigPresenceView!(string[2])(fixedPresence);
    assert(fixedPresenceView.elements.length == 2);
    assert(fixedPresenceView.elements[1].supplied);

    enum Key : int { first = 1, second = 2 }
    Item[Key] keyed = [Key.first: original, Key.second: Item("other")];
    scope keyedView = ConfigMapValueView!(Key, Item)(keyed);
    assert(keyedView[Key.second].members.label == "other");
    uint seen;
    foreach (scope key, scope value; keyedView)
    {
        if (key == Key.first) { assert(value.members.label == "label"); seen |= 1; }
        else { assert(key == Key.second && value.members.label == "other"); seen |= 2; }
    }
    assert(seen == 3);

    Nullable!Item wrapped = Nullable!Item(original);
    scope wrappedView = borrowValue!(Nullable!Item)(wrapped);
    assert(!wrappedView.isNull && wrappedView.get.members.label == "label");
    auto wrappedPresence = fullPresence!(Nullable!Item)(wrapped);
    scope wrappedPresenceView = ConfigPresenceView!(Nullable!Item)(wrappedPresence);
    assert(wrappedPresenceView.hasValue);
    assert(wrappedPresenceView.child.members.groups.entries["group"].supplied);
    wrappedPresence.hasValue = false;
    assert(!wrappedPresenceView.hasValue);

    struct CollidingFields
    {
        string members;
        string supplied;
        string __configBorrowedStorage;
        string opDispatch;
    }
    CollidingFields colliding = CollidingFields("member", "supplied", "storage", "dispatch");
    scope collidingView = ConfigStructValueView!CollidingFields(colliding);
    assert(collidingView.members.members == "member");
    assert(collidingView.members.supplied == "supplied");
    assert(collidingView.members.__configBorrowedStorage == "storage");
    assert(collidingView.members.opDispatch == "dispatch");
}

/// Immediate reads compile, but borrowed nested payloads cannot escape their scope.
@("wired.config.borrow.scopedCollectionValueEscape")
@safe unittest
{
    struct Item { string label; string[][string] groups; }
    static assert(__traits(compiles, (() @safe {
        Item source;
        scope view = ConfigStructValueView!Item(source);
        inspectBorrowed!((scope ref const ConfigStructValueView!Item borrowed) @safe {
            assert(borrowed.members.label == "label");
            foreach (key, values; borrowed.members.groups)
                foreach (value; values) assert(value == key);
        })(view);
    })()));
    static assert(__traits(compiles, (() @safe {
        ConfigPresence!Item source;
        scope view = ConfigPresenceView!Item(source);
        inspectBorrowed!((scope ref const ConfigPresenceView!Item borrowed) @safe {
            assert(borrowed.members.label.supplied);
            foreach (key, entry; borrowed.members.groups.entries)
            {
                assert(key == "group");
                foreach (element; entry.elements) assert(element.supplied);
            }
        })(view);
    })()));
    static assert(!__traits(compiles, (() @safe {
        Item source;
        scope view = ConfigStructValueView!Item(source);
        const(char)[] escaped;
        inspectBorrowed!((scope ref const ConfigStructValueView!Item borrowed) @safe {
            escaped = borrowed.members.label;
        })(view);
    })()));
    static assert(!__traits(compiles, (() @safe {
        Item source;
        scope view = ConfigStructValueView!Item(source);
        const(char)[] escaped;
        inspectBorrowed!((scope ref const ConfigStructValueView!Item borrowed) @safe {
            escaped = borrowed.members.groups["group"][0];
        })(view);
    })()));
    static assert(!__traits(compiles, (() @safe {
        Item source;
        scope view = ConfigStructValueView!Item(source);
        const(char)[] escaped;
        inspectBorrowed!((scope ref const ConfigStructValueView!Item borrowed) @safe {
            foreach (key, values; borrowed.members.groups) escaped = key;
        })(view);
    })()));
    static assert(!__traits(compiles, (() @safe {
        ConfigPresence!Item source;
        scope view = ConfigPresenceView!Item(source);
        const(char)[] escaped;
        inspectBorrowed!((scope ref const ConfigPresenceView!Item borrowed) @safe {
            foreach (key, entry; borrowed.members.groups.entries) escaped = key;
        })(view);
    })()));
    static assert(!__traits(compiles, (() @safe {
        Nullable!Item source;
        scope view = borrowValue!(Nullable!Item)(source);
        const(char)[] escaped;
        inspectBorrowed!((scope ref const ConfigBorrowedValue!(Nullable!Item) borrowed) @safe {
            if (!borrowed.isNull) escaped = borrowed.get.members.groups["group"][0];
        })(view);
    })()));
    static assert(!__traits(compiles, (() @safe {
        Item source;
        scope view = ConfigStructValueView!Item(source);
        ConfigMapValueView!(string, string[]) escaped;
        inspectBorrowed!((scope ref const ConfigStructValueView!Item borrowed) @safe {
            escaped = borrowed.members.groups;
        })(view);
    })()));
    static assert(!__traits(compiles, (() @safe {
        Item source;
        scope view = ConfigStructValueView!Item(source);
        const(char)[] escaped;
        inspectBorrowed!((scope ref const ConfigStructValueView!Item borrowed) @safe {
            foreach (value; borrowed.members.groups["group"]) escaped = value;
        })(view);
    })()));
}
