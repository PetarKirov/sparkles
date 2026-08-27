/**
The closed structural classification every reflection consumer dispatches on.

`typeKindOf` answers one question — $(B what shape is this type?) — with one
total ladder, so the property tree, the text writers, query-path resolution,
and serialization front ends cannot drift apart over which type is a leaf,
which is a composite, and which is opaque. Classification is mechanism, not
policy: whether a shape is presented, serialized, edited, or queried stays
with the consumer.
*/
module sparkles.reflection.kind;

import std.sumtype : isSumType;
import std.traits : isAssociativeArray, isArray, isFloatingPoint, isIntegral,
    isSomeChar, isSomeFunction, isSomeString;

/// The closed structural kinds.
enum TypeKind : ubyte
{
    opaque,       /// not structurally descensible (custom types, functions…)
    null_,        /// `typeof(null)`
    boolean,      ///
    character,    /// any `isSomeChar` type
    signedInteger, ///
    unsignedInteger, ///
    floating,     ///
    text,         /// strings and narrow-slice-convertible values
    enumeration,  ///
    pointer,      /// `U*` to a non-function
    sequence,     /// static and dynamic arrays that are not text
    associative,  ///
    aggregate,    /// struct, union, class, interface
    sumType,      /// `std.sumtype.SumType`
}

/// The one total ladder from a D type to its $(LREF TypeKind).
///
/// Order is load-bearing: enums before integrals (an enum's base is
/// integral), strings before arrays (`char[]` is both), and `SumType` before
/// aggregates (a `SumType` is a struct).
template typeKindOf(T)
{
    static if (is(T == typeof(null)))
        enum TypeKind typeKindOf = TypeKind.null_;
    else static if (is(T == enum))
        enum TypeKind typeKindOf = TypeKind.enumeration;
    else static if (is(T == bool))
        enum TypeKind typeKindOf = TypeKind.boolean;
    else static if (isSomeChar!T)
        enum TypeKind typeKindOf = TypeKind.character;
    else static if (isSomeString!T || is(T : const(char)[]))
        enum TypeKind typeKindOf = TypeKind.text;
    else static if (isSomeFunction!T)
        enum TypeKind typeKindOf = TypeKind.opaque;
    else static if (isIntegral!T)
        enum TypeKind typeKindOf = __traits(isUnsigned, T)
            ? TypeKind.unsignedInteger : TypeKind.signedInteger;
    else static if (isFloatingPoint!T)
        enum TypeKind typeKindOf = TypeKind.floating;
    else static if (isSumType!T)
        enum TypeKind typeKindOf = TypeKind.sumType;
    else static if (isAssociativeArray!T)
        enum TypeKind typeKindOf = TypeKind.associative;
    else static if (isArray!T)
        enum TypeKind typeKindOf = TypeKind.sequence;
    else static if (is(T == U*, U))
        enum TypeKind typeKindOf = TypeKind.pointer;
    else static if (is(T == struct) || is(T == union) || is(T == class)
        || is(T == interface))
        enum TypeKind typeKindOf = TypeKind.aggregate;
    else
        enum TypeKind typeKindOf = TypeKind.opaque;
}

/// `true` for the leaf kinds a value writer or query sink can consume
/// directly: null, boolean, character, integers, floating, text, enumeration.
bool isScalarKind(TypeKind kind) @safe pure nothrow @nogc
    => kind >= TypeKind.null_ && kind <= TypeKind.enumeration;

// ── tests ────────────────────────────────────────────────────────────────────

@("reflection.kind.scalars")
@safe pure nothrow @nogc
unittest
{
    static assert(typeKindOf!(typeof(null)) == TypeKind.null_);
    static assert(typeKindOf!bool == TypeKind.boolean);
    static assert(typeKindOf!char == TypeKind.character);
    static assert(typeKindOf!wchar == TypeKind.character);
    static assert(typeKindOf!int == TypeKind.signedInteger);
    static assert(typeKindOf!long == TypeKind.signedInteger);
    static assert(typeKindOf!uint == TypeKind.unsignedInteger);
    static assert(typeKindOf!ulong == TypeKind.unsignedInteger);
    static assert(typeKindOf!ubyte == TypeKind.unsignedInteger);
    static assert(typeKindOf!double == TypeKind.floating);
    static assert(typeKindOf!float == TypeKind.floating);
}

@("reflection.kind.textVsSequence")
@safe pure nothrow @nogc
unittest
{
    static assert(typeKindOf!string == TypeKind.text);
    static assert(typeKindOf!(const(char)[]) == TypeKind.text);
    static assert(typeKindOf!(char[4]) == TypeKind.text);
    static assert(typeKindOf!dstring == TypeKind.text);
    static assert(typeKindOf!(int[]) == TypeKind.sequence);
    static assert(typeKindOf!(int[3]) == TypeKind.sequence);
    static assert(typeKindOf!(double[2][2]) == TypeKind.sequence);
}

@("reflection.kind.compositesAndLeaves")
@safe pure nothrow @nogc
unittest
{
    enum Color { red }
    static assert(typeKindOf!Color == TypeKind.enumeration);

    struct S { int x; }
    class C { int y; }
    static assert(typeKindOf!S == TypeKind.aggregate);
    static assert(typeKindOf!C == TypeKind.aggregate);
    static assert(typeKindOf!(int*) == TypeKind.pointer);
    static assert(typeKindOf!(const S*) == TypeKind.pointer);
    static assert(typeKindOf!(int[string]) == TypeKind.associative);

    import std.sumtype : SumType;
    static assert(typeKindOf!(SumType!(int, string)) == TypeKind.sumType);

    static assert(typeKindOf!(void function()) == TypeKind.opaque);
    static assert(typeKindOf!(int delegate()) == TypeKind.opaque);
}

@("reflection.kind.isScalarKind")
@safe pure nothrow @nogc
unittest
{
    static assert(isScalarKind(TypeKind.null_));
    static assert(isScalarKind(TypeKind.boolean));
    static assert(isScalarKind(TypeKind.character));
    static assert(isScalarKind(TypeKind.signedInteger));
    static assert(isScalarKind(TypeKind.unsignedInteger));
    static assert(isScalarKind(TypeKind.floating));
    static assert(isScalarKind(TypeKind.text));
    static assert(isScalarKind(TypeKind.enumeration));

    static assert(!isScalarKind(TypeKind.opaque));
    static assert(!isScalarKind(TypeKind.pointer));
    static assert(!isScalarKind(TypeKind.sequence));
    static assert(!isScalarKind(TypeKind.associative));
    static assert(!isScalarKind(TypeKind.aggregate));
    static assert(!isScalarKind(TypeKind.sumType));
}
