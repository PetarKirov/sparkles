/**
Structural member primitives: declared-field enumeration, public
`@property`-getter discovery, the value-like wrapper rule, and the one-pass
CTFE tables consumers reduce member data into.

The field primitives are indexed into `T.tupleof` — the same spine the
property tree and serialization walk — so a field's compile-time symbol, type,
and identifier always agree with the runtime value the shells hand to a
visitor.
*/
module sparkles.reflection.member;


import std.meta : AliasSeq;
import std.traits : FunctionAttribute, Parameters, ReturnType,
    functionAttributes;

import sparkles.reflection.kind : isScalarKind, typeKindOf;

/// Number of declared fields of `T`, excluding the hidden context pointer a
/// nested type carries.
enum size_t fieldCount(T) = T.tupleof.length - (__traits(isNested, T) ? 1 : 0);

/// The declared type of field `i` of `T`.
alias fieldType(T, size_t i) = typeof(T.tupleof[i]);

/// The compile-time symbol of field `i` of `T` (UDA and protection source).
alias fieldSymbol(T, size_t i) = T.tupleof[i];

/// The declared identifier of field `i` of `T`.
enum string fieldIdentifier(T, size_t i) = __traits(identifier, T.tupleof[i]);

/// `true` when `symbol` is a zero-argument `@property` getter returning
/// non-`void` — the language capability every consumer reads computed values
/// through. Overloaded setters on the same name fail the parameter check.
template isPropertyGetter(alias symbol)
{
    static if (__traits(compiles, Parameters!symbol)
        && __traits(compiles, functionAttributes!symbol))
        enum bool isPropertyGetter = Parameters!symbol.length == 0
            && !is(ReturnType!symbol == void)
            && (functionAttributes!symbol & FunctionAttribute.property) != 0;
    else
        enum bool isPropertyGetter = false;
}

/// `true` when `symbol` is declared `public` (or `export`).
enum bool isPublic(alias symbol) = __traits(getProtection, symbol) == "public"
    || __traits(getProtection, symbol) == "export";

private template overloadGetters(T, string name)
{
    static if (!__traits(compiles, __traits(getOverloads, T, name)))
        alias overloadGetters = AliasSeq!();
    else
    {
        private template pick(overloads...)
        {
            static if (overloads.length == 0)
                alias pick = AliasSeq!();
            else static if (isPropertyGetter!(overloads[0])
                && isPublic!(overloads[0]))
                alias pick = AliasSeq!(overloads[0], pick!(overloads[1 .. $]));
            else
                alias pick = pick!(overloads[1 .. $]);
        }

        alias all = pick!(__traits(getOverloads, T, name));
        static if (all.length > 0)
            alias overloadGetters = AliasSeq!(all[0]);
        else
            alias overloadGetters = AliasSeq!();
    }
}

private template memberGetters(T, size_t i, names...)
{
    static if (names.length == 0)
        alias memberGetters = AliasSeq!();
    else
    {
        alias head = overloadGetters!(T, names[0]);
        alias tail = memberGetters!(T, i + 1, names[1 .. $]);
        static if (head.length > 0)
            alias memberGetters = AliasSeq!(head, tail);
        else
            alias memberGetters = tail;
    }
}

/// The public zero-argument `@property` getters of `T`, one per member name,
/// in declaration order. Private storage and setters never appear.
template propertyGetters(T)
{
    alias propertyGetters = memberGetters!(T, 0, __traits(allMembers, T));
}

/// `true` when `T` exposes at least one public declared field.
enum bool hasPublicFields(T) = () {
    static if (is(T == struct) || is(T == union) || is(T == class))
    {
        bool any;
        static foreach (i; 0 .. fieldCount!T)
        {
            static if (__traits(getProtection, T.tupleof[i]) == "public")
                any = true;
        }
        return any;
    }
    else
        return false; // enums and other non-aggregates have no fields
}();

/**
The single scalar-returning public `@property` getter of a fieldless value
type — the DbI answer to computed leaf values (`KeyEvent.text`,
`ScaleFactor.value`): a type that hides all storage behind one property $(B is)
that property's value, so consumers present and query it as a leaf without
domain-specific projection hooks. `void` when `T` does not opt in.
*/
template valueLikeGetter(T)
{
    // The aggregate guard comes first and short-circuits: for built-ins and
    // enums the member queries do not instantiate, and a failed
    // instantiation inside `is(... == void)` would read as "not void" —
    // turning an error into a wrong yes.
    static if ((is(T == struct) || is(T == union) || is(T == class))
        && !hasPublicFields!T && propertyGetters!T.length == 1
        && isScalarKind(typeKindOf!(ReturnType!(propertyGetters!T[0]))))
        alias valueLikeGetter = propertyGetters!T[0];
    else
        alias valueLikeGetter = void;
}

/**
The second value-like rule: a type that hides its storage and reads as UTF-8
text through a `const` `opSlice()` — `sparkles.base.buffer`'s
`InlineBuffer!(char, N)` and kin — $(B is) the text it slices to. Consumers
present and query such a type as one text leaf rather than as the getters of
its buffer API.
*/
enum bool isTextSliceLike(T) = (is(T == struct) || is(T == union)
        || is(T == class))
    && !hasPublicFields!T
    && __traits(compiles, { const T v = T.init; const(char)[] s = v[]; });

/// The names `T` exposes through `alias this`.
template aliasThisMembers(T)
{
    alias aliasThisMembers = __traits(getAliasThis, T);
}

/**
One-pass CTFE table over `T`'s declared fields: `reduce` is a template
returning one uniform value per field index, and the table is built once
(a `static immutable` array, not a manifest constant, so per-index reads do
not re-materialize the whole table). This is the shared spine serialization
policies, schema generators, and row mappers reduce into.
*/
template fieldTable(T, alias reduce)
if (is(T == struct) || is(T == class) || is(T == union))
{
    static if (fieldCount!T == 0)
    {
        static immutable bool[0] fieldTable;
    }
    else
    {
        alias R = typeof(reduce!0);
        static immutable R[] fieldTable = () {
            R[] r;
            static foreach (i; 0 .. fieldCount!T)
                r ~= reduce!i;
            return r;
        }();
        static foreach (i; 0 .. fieldCount!T)
            static assert(is(typeof(reduce!i) == R),
                "fieldTable: reduce must produce one uniform type per field");
    }
}

/// ditto — one entry per member name of enum `E`; `reduce` takes the member
/// name string and resolves the member symbol itself.
template enumMemberTable(E, alias reduce)
if (is(E == enum))
{
    alias R = typeof(reduce!(__traits(allMembers, E)[0]));
    static immutable R[] enumMemberTable = () {
        R[] r;
        static foreach (m; __traits(allMembers, E))
            r ~= reduce!m;
        return r;
    }();
}

/// The first value in `names` that equals an earlier one, or `null` when all
/// are distinct. CTFE helper for the uniqueness checks consumers run on their
/// reduced tables.
string firstDuplicate(scope const(string)[] names) @safe pure
{
    bool[string] seen;
    foreach (n; names)
    {
        if (n in seen)
            return n;
        seen[n] = true;
    }
    return null;
}

// ── tests ────────────────────────────────────────────────────────────────────

@("reflection.member.fields")
@safe pure unittest
{
    struct S
    {
        int alpha;
        string beta;
    }

    static assert(fieldCount!S == 2);
    static assert(is(fieldType!(S, 0) == int));
    static assert(fieldIdentifier!(S, 0) == "alpha");
    static assert(fieldIdentifier!(S, 1) == "beta");

    // Nested types hide their context pointer.
    int captured = 3;
    struct Nested
    {
        int visible;
        int peek() => captured;
    }
    static assert(__traits(isNested, Nested));
    static assert(fieldCount!Nested == 1);
    static assert(fieldIdentifier!(Nested, 0) == "visible");
}

@("reflection.member.propertyGetters")
@safe pure unittest
{
    struct S
    {
        private int value_ = 7;
        private string text_ = "hi";

        @property int value() const => value_;
        @property string text() const => text_;
        void value(int v) { value_ = v; } // setter: excluded
        int plain() const => 1;           // not @property: excluded
        private @property int secret() const => 0; // private: excluded
    }

    alias getters = propertyGetters!S;
    static assert(getters.length == 2);
    static assert(__traits(identifier, getters[0]) == "value");
    static assert(__traits(identifier, getters[1]) == "text");

    struct Empty {}
    static assert(propertyGetters!Empty.length == 0);
}

@("reflection.member.valueLikeGetter")
@safe pure unittest
{
    // Fieldless single-property wrapper: value-like.
    struct Wrapped
    {
        private int value_ = 3;
        @property int value() const => value_;
    }
    static assert(!hasPublicFields!Wrapped);
    static assert(__traits(isSame, valueLikeGetter!Wrapped, Wrapped.value));

    // Public fields or several properties: not value-like.
    struct Open
    {
        int x;
        @property int twice() const => x * 2;
    }
    static assert(hasPublicFields!Open);
    static assert(is(valueLikeGetter!Open == void));

    struct TwoGetters
    {
        @property int a() const => 1;
        @property int b() const => 2;
    }
    static assert(is(valueLikeGetter!TwoGetters == void));
}

@("reflection.member.isTextSliceLike")
@safe pure unittest
{
    struct Text
    {
        private char[8] bytes_;
        private ubyte length_;
        const(char)[] opSlice() const return => bytes_[0 .. length_];
        @property size_t length() const => length_;
        @property bool empty() const => length_ == 0;
    }
    static assert(isTextSliceLike!Text);
    static assert(is(valueLikeGetter!Text == void)); // two getters: not that rule

    struct Ints
    {
        private int[4] data_;
        const(int)[] opSlice() const return => data_[];
    }
    static assert(!isTextSliceLike!Ints); // slices, but not to text

    struct Open
    {
        char[4] text;
        const(char)[] opSlice() const return => text[];
    }
    static assert(!isTextSliceLike!Open); // public storage is addressable
}

@("reflection.member.fieldTable")
@safe pure unittest
{
    struct S
    {
        int alpha;
        string beta;
    }

    template namesOf(size_t i)
    {
        enum string namesOf = fieldIdentifier!(S, i);
    }

    alias table = fieldTable!(S, namesOf);
    static assert(table == ["alpha", "beta"]);

    struct None {}
    static assert(fieldTable!(None, namesOf).length == 0);
}

@("reflection.member.enumMemberTable")
@safe pure unittest
{
    enum Mode { fast, slow }

    template quoted(string m)
    {
        enum string quoted = "\"" ~ m ~ "\"";
    }

    alias table = enumMemberTable!(Mode, quoted);
    static assert(table == ["\"fast\"", "\"slow\""]);
}

@("reflection.member.firstDuplicate")
@safe pure unittest
{
    assert(firstDuplicate(["a", "b", "c"]) is null);
    assert(firstDuplicate(["a", "b", "a"]) == "a");
}
