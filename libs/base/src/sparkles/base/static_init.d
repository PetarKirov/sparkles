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
)

A declaration may omit its type (`immutable x = f();`, `auto y = g();`). The
type then becomes `typeof(<initializer>)`.
*/
module sparkles.base.static_init;

import std.algorithm.searching : canFind;
import std.array : join, split;
import std.conv : to;
import std.string : strip;

/**
Rewrites $(I one) declaration with a run-time initializer into the declaration
plus the module constructor that initializes it. Use it as a string mixin, so
the variable lands directly in the caller's scope.

The module documentation lists which constructor each storage class gets.

Params:
    decl = a single declaration, `;` included, usually written as a `q{…}`
        token string.

The generated code keeps each declaration on its source line, so a compile
error in it is reported at `<file>-mixin-<L>(<line>)`, where `<line>` is the
offending line of the caller's file.
*/
enum string staticVar(string decl) = staticInitCode(decl, singleDeclaration: true);

///
@("staticInit.staticVar.example")
@safe unittest
{
    // At module scope:
    //     mixin(staticVar!q{ immutable int[] squares = computeSquares(4); });
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
block. A "parent scope from here" note follows it with the caller's line, and
the message names the variable. (A `#line` directive cannot help here: DMD 2.112
shifts a `#line` inside a string mixin by twice the mixin's own line.)
*/
mixin template StaticBlock(string decls)
{
    // A mixin template's body resolves names at the instantiation site, where
    // this module may be imported selectively (or not at all), so reach the
    // generator through a renamed import that binds only `staticInit_`.
    import staticInit_ = sparkles.base.static_init;
    mixin(staticInit_.staticInitCode(decls, singleDeclaration: false));
}

///
@("staticInit.StaticBlock.example")
@safe unittest
{
    // At module scope:
    //     mixin StaticBlock!q{
    //         immutable int[] primes = [2, 3, 5, 7].dup;
    //         immutable size_t primeCount = primes.length; // reads the line above
    //     };
    assert(examplePrimes == [2, 3, 5, 7]);
    assert(examplePrimeCount == 4);
}

// ─── Code generation ────────────────────────────────────────────────────────

/// One declaration as found in the source: its text, without the trailing `;`
/// or leading trivia, and the 0-based line its text starts on.
private struct Declaration
{
    string text;
    size_t lineOffset;
}

/// The pieces of `<lhs> = <expr>`; `name` is the variable's identifier.
private struct Split
{
    string lhs;
    string name;
    string expr;
}

// Public only so `StaticBlock` can reach it from the mixin site. It is not
// part of the API.
string staticInitCode(string source, bool singleDeclaration) @safe pure
{
    auto decls = splitDeclarations(source);
    if (singleDeclaration && decls.length != 1)
        assert(false, "staticVar: expected exactly one declaration, found " ~
            decls.length.to!string ~ "; use `StaticBlock` for several");

    // Pad with newlines so each declaration starts on its source line: DMD
    // reports a mixin's line k as the mixin's line + k, which then names the
    // caller's own line.
    string code;
    size_t lines;
    foreach (decl; decls)
    {
        for (; lines < decl.lineOffset; lines++)
            code ~= "\n";
        const generated = declarationCode(decl.text);
        code ~= generated;
        lines += countLines(generated);
    }
    return code;
}

/// The generated code for one declaration (see the module docs). The
/// boilerplate adds no newlines, so it shares the declaration's line.
private string declarationCode(string decl) @safe pure
{
    if (isPassThrough(decl))
        return decl ~ ";";

    const s = splitAssignment(decl);
    const name = s.name;
    const assign = "{ " ~ name ~ " = " ~ s.expr ~ "; } ";

    return declaredVariable(s) ~ "; " ~
        "static if (!__traits(compiles, { auto p_ = &" ~ name ~ "; })) " ~
        "static assert(false, \"`" ~ name ~ "`: a run-time initializer needs a " ~
        "module-level or `static` variable\"); " ~
        "else static if (is(typeof(" ~ name ~ ") == immutable) || is(typeof(" ~ name ~
        ") == shared) || !__traits(compiles, () @safe { auto p_ = &" ~ name ~ "; })) " ~
        "shared static this() " ~ assign ~
        "else static if (is(typeof(" ~ name ~ ") == const) || is(typeof(" ~ name ~ ") == inout)) " ~
        "static assert(false, \"`" ~ name ~ "`: a thread-local `const` would be " ~
        "initialized on the main thread only; declare it `immutable` or `shared const`\"); " ~
        "else static this() " ~ assign;
}

/// `enum`, `alias` and `import` lines keep their `=`, and so does a
/// declaration without an initializer (it has no `=` to begin with).
private bool isPassThrough(string decl) @safe pure
{
    const words = decl.split;
    if (words.length && ["enum", "alias", "import"].canFind(words[0]))
        return true;
    if (words.length > 1 && words[0] == "static" && words[1] == "import")
        return true;
    return findAssignment(decl) == size_t.max;
}

/// The declaration without its initializer. A typeless declaration
/// (`immutable x = …`, `auto x = …`) gets `typeof(<expr>)` as its type.
private string declaredVariable(Split s) @safe pure
{
    const prefix = s.lhs[0 .. $ - s.name.length];
    if (!isTypeless(prefix))
        return s.lhs;

    string[] storage;
    foreach (word; prefix.split)
        if (word != "auto")
            storage ~= word;
    return (storage ~ ("typeof(" ~ s.expr ~ ")") ~ s.name).join(" ");
}

private immutable string[] storageWords = [
    "auto", "immutable", "const", "shared", "__gshared", "static", "scope",
    "private", "package", "public", "protected", "export", "extern",
];

/// Whether every word before the name is a storage class, an attribute or a
/// protection keyword, which leaves no type.
private bool isTypeless(string prefix) @safe pure
{
    foreach (c; prefix)
        if (!isIdentChar(c) && c != '@' && c != ' ' && c != '\t' && c != '\r' && c != '\n')
            return false;
    foreach (word; prefix.split)
        if (word[0] != '@' && !storageWords.canFind(word))
            return false;
    return true;
}

private Split splitAssignment(string decl) @safe pure
{
    const eq = findAssignment(decl);
    const lhs = stripTrailingTrivia(decl[0 .. eq]);
    const expr = decl[eq + 1 .. $].strip;

    if (expr.length == 0)
        assert(false, "staticVar: empty initializer in `" ~ decl ~ "`");
    if (topLevelPositions(lhs, ',').length || topLevelPositions(expr, ',').length)
        assert(false, "staticVar: one declarator per declaration (and no comma " ~
            "expression) in `" ~ decl ~ "`");

    size_t start = lhs.length;
    while (start > 0 && isIdentChar(lhs[start - 1]))
        start--;
    if (start == lhs.length || !isIdentStart(lhs[start]))
        assert(false, "staticVar: expected a variable name before `=` in `" ~ decl ~ "`");

    return Split(lhs, lhs[start .. $], expr);
}

/// The index of the declaration's top-level `=`, or `size_t.max` if it has
/// none. Comparisons, `=>` and compound assignments are not it.
private size_t findAssignment(string s) @safe pure nothrow
{
    foreach (p; topLevelPositions(s, '='))
    {
        const next = p + 1 < s.length ? s[p + 1] : '\0';
        const prev = p > 0 ? s[p - 1] : '\0';
        if (next == '=' || next == '>')
            continue;
        if (isOneOf(prev, "=!<>+-*/%&|^~"))
            continue;
        return p;
    }
    return size_t.max;
}

/// Splits `source` on top-level `;`. Segments that hold only whitespace and
/// comments are dropped; anything else after the last `;` is an error.
private Declaration[] splitDeclarations(string source) @safe pure
{
    Declaration[] decls;
    size_t begin;
    foreach (end; topLevelPositions(source, ';') ~ source.length)
    {
        const start = skipTrivia(source, begin);
        if (start < end)
        {
            if (end == source.length)
                assert(false, "staticVar: missing `;` after `" ~ source[start .. end].strip ~ "`");
            decls ~= Declaration(stripTrailingTrivia(source[start .. end]), countLines(source[0 .. start]));
        }
        begin = end + 1;
    }
    return decls;
}

/// `s` without trailing whitespace and comments. A trailing `//` comment would
/// otherwise swallow the code generated after it on the same line.
private string stripTrailingTrivia(string s) @safe pure nothrow
{
    size_t codeEnd;
    size_t i = skipTrivia(s, 0);
    while (i < s.length)
    {
        const after = skipLexeme(s, i);
        codeEnd = after == i ? i + 1 : after;
        i = skipTrivia(s, codeEnd);
    }
    return s[0 .. codeEnd];
}

/// The positions of `c` outside brackets, string literals and comments.
private size_t[] topLevelPositions(string s, char c) @safe pure nothrow
{
    size_t[] positions;
    size_t depth;
    size_t i;
    while (i < s.length)
    {
        const after = skipLexeme(s, i);
        if (after != i)
        {
            i = after;
            continue;
        }
        const ch = s[i];
        if (ch == '(' || ch == '[' || ch == '{')
            depth++;
        else if ((ch == ')' || ch == ']' || ch == '}') && depth > 0)
            depth--;
        else if (ch == c && depth == 0)
            positions ~= i;
        i++;
    }
    return positions;
}

/// Skips whitespace and comments from `i`.
private size_t skipTrivia(string s, size_t i) @safe pure nothrow
{
    while (i < s.length)
    {
        if (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n')
            i++;
        else if (i + 1 < s.length && s[i] == '/' && isOneOf(s[i + 1], "/*+"))
            i = skipLexeme(s, i);
        else
            break;
    }
    return i;
}

/// If a comment, string or character literal starts at `i`, returns the index
/// just past it; otherwise returns `i`.
private size_t skipLexeme(string s, size_t i) @safe pure nothrow
{
    const next = i + 1 < s.length ? s[i + 1] : '\0';
    if (s[i] == '/' && next == '/')
    {
        while (i < s.length && s[i] != '\n')
            i++;
        return i;
    }
    if (s[i] == '/' && next == '*')
    {
        for (i += 2; i < s.length; i++)
            if (s[i] == '/' && s[i - 1] == '*')
                return i + 1;
        return s.length;
    }
    if (s[i] == '/' && next == '+')
    {
        size_t nesting = 1;
        for (i += 2; i < s.length && nesting; i++)
        {
            if (s[i] == '+' && i + 1 < s.length && s[i + 1] == '/')
            {
                nesting--;
                i++;
            }
            else if (s[i] == '/' && i + 1 < s.length && s[i + 1] == '+')
            {
                nesting++;
                i++;
            }
        }
        return i;
    }
    if ((s[i] == 'r' && next == '"' && (i == 0 || !isIdentChar(s[i - 1]))) || s[i] == '`')
    {
        // WYSIWYG strings: no escapes.
        const close = s[i] == '`' ? '`' : '"';
        for (i += s[i] == '`' ? 1 : 2; i < s.length; i++)
            if (s[i] == close)
                return i + 1;
        return s.length;
    }
    if (s[i] == '"' || s[i] == '\'')
    {
        const close = s[i];
        for (i++; i < s.length; i++)
        {
            if (s[i] == '\\')
                i++;
            else if (s[i] == close)
                return i + 1;
        }
        return s.length;
    }
    return i;
}

/// Whether `c` occurs in `set`, byte by byte (no decoding, so `nothrow`).
private bool isOneOf(char c, string set) @safe pure nothrow @nogc
{
    foreach (x; set)
        if (x == c)
            return true;
    return false;
}

private size_t countLines(string s) @safe pure nothrow
{
    size_t n;
    foreach (c; s)
        n += c == '\n';
    return n;
}

private bool isIdentStart(char c) @safe pure nothrow @nogc =>
    c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c >= 0x80;

private bool isIdentChar(char c) @safe pure nothrow @nogc =>
    isIdentStart(c) || (c >= '0' && c <= '9');

// ─── Tests ──────────────────────────────────────────────────────────────────

@("staticInit.findAssignment.skipsNonAssignments")
@safe pure nothrow unittest
{
    assert(findAssignment("bool b = (x == y)") == 7);
    assert(findAssignment("auto f = (int x) => x == 1") == 7);
    assert(findAssignment(`string s = "a=b"`) == 9);
    assert(findAssignment(`string s /* = */ = r"=" ~ '='`) == 17);
    assert(findAssignment("int x /+ /+ = +/ = +/ = 1") == 22);
    assert(findAssignment("int x // = 2\n = 1") == 14);
    assert(findAssignment("Foo!(a = b) x = 1") == 14);
    assert(findAssignment("int x") == size_t.max);
}

@("staticInit.splitDeclarations.linesAndTrivia")
@safe pure unittest
{
    const decls = splitDeclarations(q{
        int a = f(); // trailing
        /* lead */ string s = ";"; int[] b = [1, 2].map!((x) { return x; }).array;
    });
    assert(decls.length == 3);
    assert(decls[0] == Declaration("int a = f()", 1));
    assert(splitDeclarations("int x = 1 // c\n;") == [Declaration("int x = 1", 0)]);
    assert(splitDeclarations("int x /* c */ = 1;")[0].text == "int x /* c */ = 1");
    assert(decls[1] == Declaration(`string s = ";"`, 2));
    assert(decls[2].text == "int[] b = [1, 2].map!((x) { return x; }).array");
    assert(decls[2].lineOffset == 2);
}

@("staticInit.splitAssignment.nameAndType")
@safe pure unittest
{
    assert(splitAssignment("immutable int[] xs = f()") == Split("immutable int[] xs", "xs", "f()"));
    assert(declaredVariable(splitAssignment("immutable int[] xs = f()")) == "immutable int[] xs");
    assert(declaredVariable(splitAssignment("auto x = g()")) == "typeof(g()) x");
    assert(declaredVariable(splitAssignment("private immutable x = g()")) ==
        "private immutable typeof(g()) x");
    assert(splitAssignment("int x /* c */ = 1").name == "x");
    assert(declaredVariable(splitAssignment("const(int) x = g()")) == "const(int) x");
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
    private int[] computeSquares(int n) @safe pure
    {
        int[] r;
        foreach (i; 0 .. n)
            r ~= i * i;
        return r;
    }

    mixin(staticVar!q{ immutable int[] exampleSquares = computeSquares(4); });

    mixin StaticBlock!q{
        immutable int[] examplePrimes = [2, 3, 5, 7].dup;
        immutable size_t examplePrimeCount = examplePrimes.length;
    };

    private size_t tlsInitCount;

    mixin StaticBlock!q{
        shared int sharedValue = computeSquares(4)[3];
        __gshared int[] gsharedSlice = computeSquares(3);
        int[] threadLocal = (() { tlsInitCount++; return [7, 7]; })();
        immutable typelessImmutable = computeSquares(2);
        auto typelessTls = "tls".dup;
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
    assert(typelessTls == "tls");
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
