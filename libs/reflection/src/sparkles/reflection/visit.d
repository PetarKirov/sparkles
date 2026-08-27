/**
The DbI type and value visitors: one shell per traversal, generic over a
caller-supplied visitor whose hooks are $(B all optional).

The shell owns the structural concerns — field enumeration with the nested
context pointer excluded, `SumType` alternative enumeration, pointer and
collection descent, `@property` discovery, and cycle detection — while the
visitor owns what a consumer does with each fact. A missing hook means the
shell's default: observe nothing, descend everywhere. `NoopVisitor` is the
mandatory baseline: `visitType!T` and `visitValue` must compile and traverse
with it (`void` hook test, DbI §7.3).

Hooks are probed with the exact instantiation they will be called with, so a
capability check validates the correct call form rather than mere member
presence.
*/
module sparkles.reflection.visit;

import std.meta : AliasSeq, staticIndexOf;
import std.sumtype : match;
import std.traits : KeyType, TemplateArgsOf, Unqual, ValueType;

import sparkles.reflection.kind : TypeKind, isScalarKind, typeKindOf;
import sparkles.reflection.member : fieldCount, fieldType, propertyGetters;

/// Visitor decision for descending into a type during the compile-time walk.
enum VisitControl : ubyte
{
    descend, /// process this type and its members
    skip,    /// omit this type entirely
}

/// Visitor decision for the runtime value walk.
enum ValueControl : ubyte
{
    descend, /// recurse into this value
    skip,    /// omit this value's subtree
    stop,    /// abort the whole walk
}

/// The baseline visitor: no hooks, plain structural traversal.
struct NoopVisitor {}

// ─────────────────────────────────────────────────────────────────────────────
// The compile-time type walk.
//
// Visitor contract (all hooks optional, probed per instantiation):
//   VisitControl enterType(T)()        — before T; skip omits it
//   void leaveType(T)()                — after T's members
//   bool includeField(T, size_t i)()   — default: visit every declared field
//   void enterField(T, size_t i)()     — before field i's type
//   void leaveField(T, size_t i)()     — after field i's type
//   void leaf(T)()                     — a scalar/text/enum leaf type
//   void property(alias getter)()      — a public @property getter symbol
//   void sumAlternative(V, size_t i)() — SumType alternative before its type
//   void sequenceElement(E)()          — a sequence's element type (once)
//   void associativeEntry(K, V)()      — an AA's key and value types (once)
//   void cycle(T)()                    — T re-entered along one descent path
// ─────────────────────────────────────────────────────────────────────────────

/// Walks `T`'s structure depth-first, field order, driving `visitor`.
void visitType(T, Visitor)(scope ref Visitor visitor)
{
    visitTypeImpl!(T, Visitor)(visitor);
}

private void visitTypeImpl(T, Visitor, Seen...)(scope ref Visitor visitor)
{
    // Cycle detection is per descent path: `Seen` holds the types on the
    // current branch, so two sibling fields of the same type both visit.
    // The gate must be `static if`, not a runtime `return`: a runtime return
    // stops execution but not the compile-time unrolling of the static
    // foreach loops below, which would recurse forever.
    static if (staticIndexOf!(T, Seen) >= 0)
    {
        static if (__traits(compiles, visitor.cycle!T()))
            visitor.cycle!T();
    }
    else
        visitTypeBody!(T, Visitor, Seen)(visitor);
}

private void visitTypeBody(T, Visitor, Seen...)(scope ref Visitor visitor)
{
    static if (__traits(compiles, visitor.enterType!T()))
    {
        static if (is(typeof(visitor.enterType!T()) == VisitControl))
        {
            if (visitor.enterType!T() == VisitControl.skip)
                return;
        }
        else
            visitor.enterType!T();
    }

    alias K = typeKindOf!T;

    static if (K == TypeKind.sumType)
    {
        alias Alternatives = TemplateArgsOf!T;
        static foreach (ai; 0 .. Alternatives.length)
        {
            static if (__traits(compiles,
                visitor.sumAlternative!(Alternatives[ai], ai)()))
                visitor.sumAlternative!(Alternatives[ai], ai)();
            visitTypeImpl!(Alternatives[ai], Visitor, Seen, T)(visitor);
        }
    }
    else static if (K == TypeKind.aggregate)
    {
        static foreach (i; 0 .. fieldCount!T)
        {
            {{
                static if (__traits(compiles, visitor.includeField!(T, i)()))
                    enum bool include = visitor.includeField!(T, i)();
                else
                    enum bool include = true;

                static if (include)
                {
                    static if (__traits(compiles, visitor.enterField!(T, i)()))
                        visitor.enterField!(T, i)();
                    visitTypeImpl!(fieldType!(T, i), Visitor, Seen, T)(visitor);
                    static if (__traits(compiles, visitor.leaveField!(T, i)()))
                        visitor.leaveField!(T, i)();
                }
            }}
        }

        static foreach (getter; propertyGetters!T)
        {
            static if (__traits(compiles, visitor.property!getter()))
                visitor.property!getter();
        }
    }
    else static if (K == TypeKind.sequence)
    {
        alias Element = typeof(T.init[0]);
        static if (__traits(compiles, visitor.sequenceElement!Element()))
            visitor.sequenceElement!Element();
        visitTypeImpl!(Element, Visitor, Seen, T)(visitor);
    }
    else static if (K == TypeKind.associative)
    {
        static if (__traits(compiles,
            visitor.associativeEntry!(KeyType!T, ValueType!T)()))
            visitor.associativeEntry!(KeyType!T, ValueType!T)();
        visitTypeImpl!(KeyType!T, Visitor, Seen, T)(visitor);
        visitTypeImpl!(ValueType!T, Visitor, Seen, T)(visitor);
    }
    else static if (K == TypeKind.pointer)
    {
        visitTypeImpl!(typeof(*T.init), Visitor, Seen, T)(visitor);
    }
    else
    {
        static if (__traits(compiles, visitor.leaf!T()))
            visitor.leaf!T();
    }

    static if ((K == TypeKind.aggregate || K == TypeKind.sumType)
        && __traits(compiles, visitor.leaveType!T()))
        visitor.leaveType!T();
}

// ─────────────────────────────────────────────────────────────────────────────
// The runtime value walk.
//
// Visitor contract (all hooks optional, probed per instantiation):
//   ValueControl enter(T)(ref T value)        — every value; skip/stop honored
//   void scalar(T)(ref T value)               — a leaf value (non-enum)
//   void enumeration(E)(ref E value)          — an enum leaf value
//   void absent(T)(ref T value)               — a null pointer or null AA
//   void sumAlternative(V)(ref V value, size_t index) — active alternative
//   void field(F)(ref F value, size_t i)      — a declared field, by ref
//   void element(E)(ref E value, size_t i)    — a sequence element, by ref
//   void entry(K, V)(ref K key, ref V value)  — an AA entry, by ref
//
// Returns `false` when a hook requested `stop`; `true` otherwise.
// ─────────────────────────────────────────────────────────────────────────────

/// Walks `value` depth-first, field order, driving `visitor`.
///
/// Explicitly `@safe` (with the whole shell): the hook probes recurse into
/// the function being inferred, a cycle attribute inference cannot settle —
/// the same posture the property tree's resolver takes. Hook methods must
/// therefore be `@safe`; a hook that is not simply never matches its probe.
bool visitValue(T, Visitor)(ref T value, scope ref Visitor visitor) @safe
{
    return visitValueImpl!(T, Visitor)(value, visitor);
}

private bool visitValueImpl(T, Visitor)(ref T value,
    scope ref Visitor visitor) @safe
{
    alias K = typeKindOf!T;

    static if (__traits(compiles, visitor.enter(value)))
    {
        static if (is(typeof(visitor.enter(value)) == ValueControl))
        {
            final switch (visitor.enter(value)) with (ValueControl)
            {
                case ValueControl.descend:
                    break;
                case ValueControl.skip:
                    return true;
                case ValueControl.stop:
                    return false;
            }
        }
        else
            visitor.enter(value);
    }

    static if (isScalarKind(K))
    {
        static if (K == TypeKind.enumeration)
        {
            static if (__traits(compiles, visitor.enumeration(value)))
                visitor.enumeration(value);
        }
        else
        {
            static if (__traits(compiles, visitor.scalar(value)))
                visitor.scalar(value);
        }
        return true;
    }
    else static if (K == TypeKind.pointer)
    {
        if (value is null)
        {
            static if (__traits(compiles, visitor.absent(value)))
                visitor.absent(value);
            return true;
        }
        return visitValueImpl(*value, visitor);
    }
    else static if (K == TypeKind.sumType)
    {
        alias Alternatives = TemplateArgsOf!T;
        bool ok = true;
        value.match!((auto ref alternative) {
            enum index = staticIndexOf!(Unqual!(typeof(alternative)),
                Alternatives);
            static if (__traits(compiles,
                visitor.sumAlternative(alternative, index)))
                visitor.sumAlternative(alternative, cast(size_t) index);
            ok = visitValueImpl(alternative, visitor);
        });
        return ok;
    }
    else static if (K == TypeKind.aggregate)
    {
        static foreach (i; 0 .. fieldCount!T)
        {
            {{
                static if (__traits(compiles, visitor.includeField!(T, i)()))
                    enum bool include = visitor.includeField!(T, i)();
                else
                    enum bool include = true;

                static if (include)
                {
                    static if (__traits(compiles,
                        visitor.field(value.tupleof[i], i)))
                        visitor.field(value.tupleof[i], cast(size_t) i);
                    if (!visitValueImpl(value.tupleof[i], visitor))
                        return false;
                }
            }}
        }
        return true;
    }
    else static if (K == TypeKind.sequence)
    {
        foreach (size_t ei, ref element; value)
        {
            static if (__traits(compiles, visitor.element(element, ei)))
                visitor.element(element, cast(size_t) ei);
            if (!visitValueImpl(element, visitor))
                return false;
        }
        return true;
    }
    else static if (K == TypeKind.associative)
    {
        if (value is null)
        {
            static if (__traits(compiles, visitor.absent(value)))
                visitor.absent(value);
            return true;
        }
        foreach (ref key, ref entryValue; value)
        {
            static if (__traits(compiles,
                visitor.entry(key, entryValue)))
                visitor.entry(key, entryValue);
            if (!visitValueImpl(key, visitor))
                return false;
            if (!visitValueImpl(entryValue, visitor))
                return false;
        }
        return true;
    }
    else
        return true;
}

// ── tests ────────────────────────────────────────────────────────────────────

private struct Link
{
    int value_;
    Link* next;
}

@("reflection.visit.voidVisitorBaseline")
@safe unittest
{
    // The void-hook test (DbI §7.3): the shell stands alone.
    Link tail;
    tail.value_ = 2;
    Link node;
    node.value_ = 1;
    node.next = &tail;

    NoopVisitor noop;
    visitType!Link(noop);
    assert(visitValue(node, noop));
}

@("reflection.visit.typeWalkCollectsShape")
@safe unittest
{
    struct Inner
    {
        double weight;
    }

    struct Outer
    {
        int count;
        string name;
        Inner inner;
        Inner again;
        @property long computed() const => 42;
    }

    struct Collector
    {
        string[] kinds;
        string[] getters;

        void leaf(T)() { kinds ~= T.stringof; }
        void enterField(T, size_t i)() { kinds ~= fieldIdentifier!(T, i); }
        void property(alias getter)() { getters ~= __traits(identifier, getter); }
    }

    import sparkles.reflection.member : fieldIdentifier;

    Collector c;
    visitType!Outer(c);

    // Sibling same-type fields both visit; the cycle list is per path.
    assert(c.kinds == ["count", "int", "name", "string", "inner",
        "weight", "double", "again", "weight", "double"]);
    assert(c.getters == ["computed"]);
}

@("reflection.visit.typeWalkDetectsCycles")
@safe pure unittest
{
    struct Node
    {
        int payload;
        Node* next;
    }

    struct CycleWatcher
    {
        size_t cycles;
        void cycle(T)() { cycles++; }
    }

    CycleWatcher w;
    visitType!Node(w);
    assert(w.cycles == 1);
}

@("reflection.visit.valueWalkFieldsAndElements")
@safe unittest
{
    struct Item
    {
        int id;
    }

    struct Bag
    {
        int single;
        Item[2] items;
        string label;
    }

    struct Recorder
    {
        long scalars;
        long fields;
        long elements;
        string lastLabel;

        void scalar(T)(ref T) { scalars++; }
        void field(F)(ref F, size_t) { fields++; }
        void element(E)(ref E, size_t) { elements++; }
        void enter(T)(ref T value)
        {
            static if (is(T == string))
                lastLabel = value.idup;
        }
    }

    Bag bag;
    bag.single = 1;
    bag.items[0].id = 10;
    bag.items[1].id = 11;
    bag.label = "hello";

    Recorder r;
    assert(visitValue(bag, r));
    // Bag's three fields plus Item.id inside both array elements: the field
    // hook fires for every declared field at every depth.
    assert(r.fields == 5);
    assert(r.elements == 2);
    assert(r.lastLabel == "hello");
}

@("reflection.visit.valueWalkSumTypeActiveAlternative")
@safe unittest
{
    import std.sumtype : SumType;

    struct Alpha
    {
        int a;
    }

    struct Beta
    {
        bool b;
    }

    alias Cell = SumType!(Alpha, Beta);

    struct Recorder
    {
        size_t seen;
        int alphaA;

        void sumAlternative(V)(ref V value, size_t index)
        {
            seen++;
            static if (is(V == Alpha))
                alphaA = value.a;
        }
    }

    Cell cell = Alpha(9);
    Recorder r;
    assert(visitValue(cell, r));
    assert(r.seen == 1);
    assert(r.alphaA == 9);
}

@("reflection.visit.valueWalkNullPointerAndStop")
@safe unittest
{
    struct Payload
    {
        int n;
    }

    struct Holder
    {
        Payload* p;
        int after;
    }

    struct AbsentWatcher
    {
        size_t absentCount;
        bool stopAfterAbsent;

        void absent(T)(ref T)
        {
            absentCount++;
        }

        ValueControl enter(T)(ref T value)
        {
            static if (is(T == int))
                return stopAfterAbsent ? ValueControl.stop
                    : ValueControl.descend;
            else
                return ValueControl.descend;
        }
    }

    Holder h;
    AbsentWatcher w1;
    assert(visitValue(h, w1));
    assert(w1.absentCount == 1);

    AbsentWatcher w2;
    w2.stopAfterAbsent = true;
    assert(!visitValue(h, w2));
    assert(w2.absentCount == 1);
}
