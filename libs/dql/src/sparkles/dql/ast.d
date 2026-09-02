module sparkles.dql.ast;

import std.algorithm.comparison : max;
import std.regex : Regex;
import std.sumtype : SumType, match;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.base.text.span : TextSpan;
import sparkles.fuzzy.glob : GlobProgram;
import sparkles.fuzzy.query : QueryStorage;

@safe:

/// Relational and equality operators supported by DQL.
enum DqlOp : ubyte
{
    eq,
    neq,
    lt,
    lte,
    gt,
    gte,
}

/// A typed DQL literal value for zero-allocation comparisons.
alias DqlValue = SumType!(
    TextSpan,         // String literal span in engine.stringPool
    double,           // Floating point number
    long,             // Integer
    bool,             // Boolean flag
    typeof(null),     // Null literal
);

/// Safe wrapper around Regex!char providing @safe value semantics.
struct RegexHolder
{
    Regex!char regex;
    this(Regex!char r) @trusted pure nothrow @nogc { regex = r; }
    ref RegexHolder opAssign(ref scope const RegexHolder rhs) @trusted pure nothrow @nogc return
    {
        regex = cast(Regex!char) rhs.regex;
        return this;
    }
    ref RegexHolder opAssign(RegexHolder rhs) @trusted pure nothrow @nogc return
    {
        regex = rhs.regex;
        return this;
    }
}

/// Node kinds in a compiled DQL expression AST.
enum DqlNodeKind : ubyte
{
    category,
    and_,
    or_,
    not_,
    compare,
    regex,
    glob,
    fuzzy,
    nullCheck,
    custom,
}

struct CategoryPayload
{
    TextSpan name;
}

struct ComparePayload
{
    TextSpan path;
    DqlOp op;
    DqlValue target;
}

struct BinaryPayload
{
    uint left;
    uint right;
}

struct UnaryPayload
{
    uint child;
}

struct RegexPayload
{
    TextSpan path;
    uint regexIndex;
}

struct GlobPayload
{
    TextSpan path;
    uint globIndex;
}

struct FuzzyPayload
{
    TextSpan path;
    uint fuzzyIndex;
}

struct NullCheckPayload
{
    TextSpan path;
    bool isNull;
}

struct CustomPayload
{
    uint id;
}

/// The sum type payload of an AST node.
alias DqlNodePayload = SumType!(
    CategoryPayload,
    ComparePayload,
    BinaryPayload,
    UnaryPayload,
    RegexPayload,
    GlobPayload,
    FuzzyPayload,
    NullCheckPayload,
    CustomPayload,
);

static assert(DqlNodePayload.sizeof <= 40, "DqlNodePayload must remain compact (<= 40 bytes)");

/// A single node in the flat AST arena.
struct DqlAstNode
{
    DqlNodeKind kind;
    DqlNodePayload payload;
    TextSpan span;

    this(P)(DqlNodeKind k, P p, TextSpan s) @trusted pure nothrow @nogc
    {
        kind = k;
        span = s;
        payload = p;
    }
}

static assert(DqlAstNode.sizeof <= 56, "DqlAstNode must remain compact and fit in 56 bytes (under 64-byte cache line)");

/// Compiled DQL filter containing a contiguous flat array of AST nodes.
struct DqlFilter
{
    UniqueBuffer!(DqlAstNode, 4) nodes;
    uint rootIndex = uint.max;
    bool allowAllByDefault = true;
    bool hasFineGrainedPredicates = false;

    bool empty() const scope pure nothrow @nogc @safe => rootIndex == uint.max || nodes.length == 0;

    bool opEquals(in DqlFilter other) const scope pure nothrow @nogc @safe
    {
        if (rootIndex != other.rootIndex || allowAllByDefault != other.allowAllByDefault || hasFineGrainedPredicates != other.hasFineGrainedPredicates)
            return false;
        if (nodes.length != other.nodes.length)
            return false;
        foreach (i; 0 .. nodes.length)
        {
            if (nodes[i].kind != other.nodes[i].kind)
                return false;
        }
        return true;
    }
}

@("dql.ast: compact memory layout and cache-line alignment")
pure nothrow @nogc
unittest
{
    static assert(DqlValue.sizeof == 16);
    static assert(UnaryPayload.sizeof == 4);
    static assert(CustomPayload.sizeof == 4);
    static assert(BinaryPayload.sizeof == 8);
    static assert(CategoryPayload.sizeof == 8);
    static assert(RegexPayload.sizeof == 12);
    static assert(GlobPayload.sizeof == 12);
    static assert(FuzzyPayload.sizeof == 12);
    static assert(NullCheckPayload.sizeof == 12);
    static assert(ComparePayload.sizeof == 32);

    static assert(DqlNodePayload.sizeof <= 40);
    static assert(DqlAstNode.sizeof <= 56);
}
