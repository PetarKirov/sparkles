/**
Run-time initializers written on the declaration: $(LREF staticVar) and
$(LREF StaticBlock).

A global whose value is computed at run time normally needs two pieces: the
declaration, and a module constructor that assigns it somewhere else in the
file. This module keeps them together. You write an ordinary declaration with
an initializer that CTFE cannot evaluate, and the mixin rewrites it into the
bare declaration plus the matching module constructor:

---
mixin(staticVar!q{ immutable ubyte[256] table = buildTable(); });

mixin StaticBlock!q{
    immutable ubyte[256] crcTable = buildCrc();
    immutable size_t     total    = crcTable[].sum;  // reads the line above
    Logger               log      = new Logger;      // one per thread
    __gshared Registry   registry = new Registry;
};
---

The variable keeps its declared type: there is no wrapper and no check on
access, unlike Rust's `LazyLock<T>`. The value is in place before any code
can read it, because D's module constructors run it, with their usual
guarantees. They run once, before `main` or at thread start, in import order,
and a constructor cycle between modules aborts at startup.

$(B Which constructor runs each initializer.)

$(TABLE
    $(TR $(TH Declaration) $(TH Constructor))
    $(TR $(TD mutable thread-local (`T x`)) $(TD `static this`, so it runs on every thread))
    $(TR $(TD `immutable`, `shared`, `__gshared`) $(TD `shared static this`, so it runs once))
    $(TR $(TD thread-local `const`) $(TD rejected: a shared constructor would set
        only the main thread's copy, so use `immutable` or `shared const`))
)

Each declaration gets its own constructor, emitted in source order. D runs a
module's shared constructors first, then its thread-local ones, each group in
lexical order, so within a group an initializer can read the ones above it.
A shared or `immutable` initializer that reads a thread-local variable sees
`.init`. An exception thrown from an initializer aborts startup, the same as
from a hand-written module constructor.

$(B Limits.)
$(UL
    $(LI Declarations only: one declarator each (`int a = 1, b = 2;` is
    rejected), and no functions or aggregates.)
    $(LI The value is $(I assigned) in the constructor. A type with
    `@disable this()` cannot be used, and a mutable struct goes through
    `opAssign` on its `.init`. An `immutable` target needs the expression to
    convert implicitly, the same as in a normal declaration; a `pure` factory
    that returns a unique value does.)
    $(LI In a struct or class, the variables must be `static`.)
    $(LI DDoc does not see doc comments inside the mixed-in string.)
    $(LI Declarations without `=`, and `enum`, `alias` and `import` lines,
    pass through unchanged.)
    $(LI A nested `/+ … +/` comment ends at its first `+/`.)
)

A declaration may omit its type (`immutable x = f();`, `auto y = g();`). The
type then becomes `typeof(<initializer>)`.
*/
module sparkles.base.static_init;

import std.algorithm.searching : canFind, count;
import std.array : join, split;
import std.string : stripLeft, stripRight;

// The documented examples' declarations, in the docs and in unittest builds.
version (D_Ddoc)
    version = StaticInitExamples;
version (unittest)
    version = StaticInitExamples;

/**
Rewrites $(I one) declaration with a run-time initializer into the declaration
plus the module constructor that initializes it. Use it as a string mixin, so
the variable lands directly in the caller's scope.

The module documentation lists which constructor each storage class gets.

Params:
    decl = a single declaration, `;` included, usually written as a `q{…}`
        token string.

The generated code keeps the declaration on its source line, so a compile
error in it is reported at `<file>-mixin-<L>(<line>)`, where `<line>` is the
offending line of the caller's file.
*/
enum string staticVar(string decl) = staticInitCode(decl, singleDeclaration: true);

version (StaticInitExamples)
{
    private int[] computeSquares(int n) @safe pure
    {
        int[] r;
        foreach (i; 0 .. n)
            r ~= i * i;
        return r;
    }

    mixin(staticVar!q{ immutable int[] exampleSquares = computeSquares(4); });
}

///
@("staticInit.staticVar.example")
@safe unittest
{
    assert(exampleSquares == [0, 1, 4, 9]);
}

/**
Rewrites every declaration in `decls` the way $(LREF staticVar) rewrites one.
The declarations become members of the mixin, and template-mixin members are
visible in the enclosing scope, so code reads them by their plain names.

Params:
    decls = declarations, each ending in `;`.

A compile error inside the block is reported as
`static_init.d-mixin-<M>(<M + k>)`, where `k` is the offending line within the
block. A "parent scope from here" note follows it with the caller's line.
*/
mixin template StaticBlock(string decls)
{
    // A mixin template's body resolves names at the instantiation site, where
    // this module may be imported selectively (or not at all), so reach the
    // generator through a renamed import that binds only `staticInit_`.
    import staticInit_ = sparkles.base.static_init;
    mixin(staticInit_.staticInitCode(decls, singleDeclaration: false));
}

version (StaticInitExamples)
{
    mixin StaticBlock!q{
        immutable int[] examplePrimes = [2, 3, 5, 7].dup;
        immutable size_t examplePrimeCount = examplePrimes.length; // reads the line above
    };
}

///
@("staticInit.StaticBlock.example")
@safe unittest
{
    assert(examplePrimes == [2, 3, 5, 7]);
    assert(examplePrimeCount == 4);
}

// ─── Code generation ────────────────────────────────────────────────────────

// Public only so `StaticBlock` can reach it from the mixin site. It is not
// part of the API.
string staticInitCode(string source, bool singleDeclaration) @safe pure
{
    const code = codeOnly(source);
    string result;
    size_t start, declarations;
    ptrdiff_t depth;
    foreach (i, c; code)
    {
        depth += (c == '(' || c == '[' || c == '{') - (c == ')' || c == ']' || c == '}');
        if (c != ';' || depth != 0)
            continue;
        result ~= declaration(source[start .. i], code[start .. i]);
        start = i + 1;
        declarations++;
    }
    if (code[start .. $].stripLeft.length)
        assert(false, "static_init: missing `;` after `" ~ source[start .. $].stripLeft ~ "`");
    if (singleDeclaration && declarations != 1)
        assert(false, "staticVar: expected exactly one declaration; use `StaticBlock` for several");
    return result;
}

/// `s` with comments and the contents of string and character literals turned
/// into spaces, newlines kept, so plain searches find only code at the same
/// offsets.
private string codeOnly(string s) @safe pure
{
    auto r = s.dup;
    for (size_t i; i < s.length; )
    {
        const rest = s[i .. $];
        size_t end;
        if (rest.length > 1 && rest[0] == '/' && rest[1] == '/')
            end = indexOrEnd(s, i, "\n");
        else if (rest.length > 1 && rest[0] == '/' && (rest[1] == '*' || rest[1] == '+'))
            end = indexOrEnd(s, i + 2, rest[1] == '*' ? "*/" : "+/") + 2;
        else if (rest[0] == '`' || (rest.length > 1 && rest[0] == 'r' && rest[1] == '"'))
            end = indexOrEnd(s, i + (rest[0] == '`' ? 1 : 2), rest[0] == '`' ? "`" : `"`) + 1;
        else if (rest[0] == '"' || rest[0] == '\'')
        {
            end = i + 1;
            while (end < s.length && s[end] != rest[0])
                end += s[end] == '\\' ? 2 : 1;
            end++;
        }
        else
        {
            i++;
            continue;
        }
        end = end < s.length ? end : s.length;
        foreach (j; i .. end)
            if (r[j] != '\n')
                r[j] = ' ';
        i = end;
    }
    return r.idup;
}

private size_t indexOrEnd(string s, size_t from, string what) @safe pure nothrow
{
    for (size_t i = from; i + what.length <= s.length; i++)
        if (s[i .. i + what.length] == what)
            return i;
    return s.length;
}

/// The generated code for one declaration (see the module docs); `code` is
/// `src` through `codeOnly`. The boilerplate adds no newlines, so the
/// declaration stays on its source line.
private string declaration(string src, string code) @safe pure
{
    const begin = code.length - code.stripLeft.length;
    const words = code.split;
    const eq = assignment(code);
    if (eq == size_t.max || (words.length && ["enum", "alias", "import"].canFind(words[0]))
        || (words.length > 1 && words[0] == "static" && words[1] == "import"))
        return src ~ ";";

    const lhsEnd = code[0 .. eq].stripRight.length;
    size_t nameStart = lhsEnd;
    while (nameStart > begin && isIdentChar(code[nameStart - 1]))
        nameStart--;
    const name = src[nameStart .. lhsEnd];
    const expr = src[eq + 1 .. $];
    if (name.length == 0 || code[eq + 1 .. $].stripLeft.length == 0
        || topLevel!((s, i) => s[i] == ',')(code) != size_t.max)
        assert(false, "staticVar: expected one `<type> <name> = <initializer>` in `" ~ src ~ "`");

    // A declaration without a type (`immutable x = …`, `auto x = …`) gets
    // `typeof(<initializer>)`.
    const prefix = code[begin .. nameStart].split;
    string declared = src[begin .. lhsEnd];
    if (prefix.length && !prefix.canFind!(w => w[0] != '@' && !storageWords.canFind(w)))
    {
        string[] kept;
        foreach (w; src[begin .. nameStart].split)
            if (w != "auto")
                kept ~= w;
        declared = (kept ~ ("typeof((" ~ expr ~ "))") ~ name).join(" ");
    }

    const assign = "{ " ~ name ~ " = (" ~ expr ~ "); } ";
    return src[0 .. begin] ~ declared ~ "; " ~
        "static if (is(typeof(" ~ name ~ ") == immutable) || is(typeof(" ~ name ~ ") == shared)" ~
        " || !__traits(compiles, () @safe { auto p_ = &" ~ name ~ "; })) shared static this() " ~
        assign ~ "else { static assert(!is(typeof(" ~ name ~ ") == const), \"`" ~ name ~
        "`: a thread-local `const` would be set on the main thread only; declare it " ~
        "`immutable` or `shared const`\"); static this() " ~ assign ~ "}";
}

private immutable string[] storageWords = [
    "auto", "immutable", "const", "shared", "__gshared", "static", "scope",
    "private", "package", "public", "protected", "export", "extern",
];

/// The offset of the first character outside brackets for which `pred(code, i)`
/// holds, or `size_t.max`.
private size_t topLevel(alias pred)(string code)
{
    ptrdiff_t depth;
    foreach (i, c; code)
    {
        depth += (c == '(' || c == '[' || c == '{') - (c == ')' || c == ']' || c == '}');
        if (depth == 0 && pred(code, i))
            return i;
    }
    return size_t.max;
}

/// The declaration's `=`: not a comparison, `=>` or a compound assignment.
private size_t assignment(string code) @safe pure nothrow => topLevel!((s, i) => s[i] == '='
    && (i + 1 == s.length || (s[i + 1] != '=' && s[i + 1] != '>'))
    && (i == 0 || !(cast(const(ubyte)[]) "=!<>+-*/%&|^~").canFind(cast(ubyte) s[i - 1])))(code);

private bool isIdentChar(char c) @safe pure nothrow @nogc =>
    c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c >= 0x80;

// ─── Tests ──────────────────────────────────────────────────────────────────

@("staticInit.codeOnly.blanksCommentsAndLiterals")
@safe pure unittest
{
    // The literal (6 bytes) and the comment (8 bytes) become spaces.
    assert(codeOnly(`s = "a=;b"; // x = 1`) == "s = " ~ "      " ~ "; " ~ "        ");
    assert(assignment(codeOnly("bool b = (x == y)")) == 7);
    assert(assignment(codeOnly("auto f = (int x) => x == 1")) == 7);
    assert(assignment(codeOnly(`string s /* = */ = r"=" ~ '='`)) == 17);
    assert(assignment(codeOnly("int x // = 2\n = 1")) == 14);
    assert(assignment(codeOnly("Foo!(a = b) x = 1")) == 14);
    assert(assignment(codeOnly("int x")) == size_t.max);
}


@("staticInit.staticInitCode.rejects")
@safe pure unittest
{
    static assert(!__traits(compiles, { enum c = staticInitCode("int a = 1, b = 2;", false); }));
    static assert(!__traits(compiles, { enum c = staticInitCode("int a = ;", false); }));
    static assert(!__traits(compiles, { enum c = staticInitCode("int a = 1", false); }));
    static assert(!__traits(compiles, { enum c = staticInitCode("int a = 1; int b = 2;", true); }));
    static assert(!__traits(compiles, { enum c = staticInitCode("= 1;", false); }));
    static assert(__traits(compiles, { enum c = staticInitCode("enum e = 1; alias A = int;", false); }));
}

version (unittest)
{
    private size_t tlsInitCount;

    mixin StaticBlock!q{
        shared int sharedValue = computeSquares(4)[3];
        __gshared int[] gsharedSlice = computeSquares(3); /* a block comment; = */
        int[] threadLocal = (() { tlsInitCount++; return [7, 7]; })();
        immutable typelessImmutable = computeSquares(2);
        auto typelessTls = "t;l=s".dup;
        enum compileTime = 5;
        int noInitializer;
    };

    private struct Holder
    {
        mixin StaticBlock!q{
            static immutable string name = "holder".idup;
            static size_t counter = name.length;
        };
    }
}

@("staticInit.StaticBlock.storageClasses")
@system unittest
{
    static assert(is(typeof(sharedValue) == shared int));
    static assert(is(typeof(typelessImmutable) == immutable int[]));
    static assert(is(typeof(typelessTls) == char[]));
    static assert(compileTime == 5);

    assert(sharedValue == 9);
    assert(gsharedSlice == [0, 1, 4]);
    assert(threadLocal == [7, 7]);
    assert(typelessImmutable == [0, 1]);
    assert(typelessTls == "t;l=s");
    assert(noInitializer == 0);
    assert(Holder.name == "holder");
    assert(Holder.counter == 6);
}

@("staticInit.StaticBlock.threadLocalPerThread")
@system unittest
{
    import core.thread : Thread;

    threadLocal[0] = 1;
    size_t seenCount;
    int[] seen;
    new Thread({
        seen = threadLocal.dup;
        seenCount = tlsInitCount;
        threadLocal[1] = 3;
    }).start.join;

    assert(seen == [7, 7], "a new thread runs its own initializer");
    assert(seenCount == 1, "the counter is thread-local too, so it counts that thread's run");
    assert(threadLocal == [1, 7], "the other thread's write is not visible here");
}
