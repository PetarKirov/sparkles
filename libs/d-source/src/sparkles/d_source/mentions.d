/**
What one source file tells planning about versions (build-graph SPEC BGV1,
D13, D34).

$(LREF scanSource) reads a D file's tokens once. It finds:

$(LIST
    * the version and debug identifiers the file **mentions**: in a
        `version (…)` or `debug (…)` condition, or a `version = …` or
        `debug = …` assignment;
        * every **string-built condition**: a `mixin` whose string literals,
        joined in order, contain `version` or `debug` followed by `(`, or a
        manifest constant (`enum`) initialized with such literals;
        * the file's `module` declaration and its imports, which
        $(LREF isVersionUses) resolves `sparkles.base.meta.isVersion` through.
)

$(LREF scanText) reads a file under a string import root, which is text
whatever its extension, for the same mentions.

A version identifier is module-local, so a variant need keep an inherited one
only if a file it can reach mentions it. A `mixin` writes a condition that
no file spells out; a string-built condition therefore keeps every inherited
identifier, and planning reports it.
*/
module sparkles.d_source.mentions;

import std.algorithm.searching : canFind;
import sparkles.d_source.tokens : Token, TokenKind, tokenize;

/// An identifier a condition or assignment names.
struct Mention
{
    string identifier; ///
    uint line;         ///
    bool debug_;       /// a `debug` identifier rather than a `version` one
}

/// What made a file build a condition from strings.
enum StringConditionKind : ubyte
{
    mixin_,   /// a `mixin`'s joined literal arguments
    constant, /// a manifest constant's initializer
}

/// A string-built condition.
struct StringCondition
{
    StringConditionKind kind; ///
    uint line;                ///
    /// Whether it is inside a `unittest` block, which compiles only in its
    /// own package's test root.
    bool insideUnittest;
}

/// One binding of a selective import: `name`, or `alias_ = name`.
struct ImportBinding
{
    string name;   /// the imported symbol
    string alias_; /// the local name; equal to `name` without a rename
}

/// One imported module.
struct ImportDecl
{
    string module_;   /// the module's dotted name
    string renamed;   /// `import renamed = module_;`; null otherwise
    bool public_;     /// re-exported to this module's importers
    bool static_;     /// `static import`: only fully qualified names
    ImportBinding[] bindings; /// a selective import's; empty otherwise
    uint line;        ///
}

/// What a D file says about versions.
struct ScannedSource
{
    string moduleName;  /// the `module` declaration's name; null without one
    Mention[] mentions; ///
    StringCondition[] stringConditions; ///
    ImportDecl[] imports; ///
    /// Whether the file declares an `isVersion` of its own, which shadows
    /// any imported one.
    bool declaresIsVersion;
    /// The tokens, for the scans that need imports resolved first.
    const(Token)[] tokens;
    /// Each `unittest` block, as a half-open range of token indices.
    size_t[2][] unittestBlocks;
    /**
    The lines of each `mixin` whose string literals, joined, contain the word
    `import`: it may import a module no import declaration names, so a scan
    that follows imports cannot see what it reaches.
    */
    uint[] mixinImports;
}

/// Scans a D file. Never fails: a malformed file is scanned as far as its
/// tokens go, and its compile reports the error.
ScannedSource scanSource(const(char)[] source) @safe
{
    ScannedSource s;
    s.tokens = tokenize(source);
    const ts = s.tokens;
    Visibility visibility;
    size_t depth;
    size_t unittestEnd; // the token index the innermost open `unittest` block ends at

    for (size_t i = 0; i < ts.length; ++i)
    {
        const t = ts[i];
        if (t.kind != TokenKind.identifier)
        {
            if (t == "{")
                ++depth;
            else if (t == "}" && depth)
                --depth;
            continue;
        }
        switch (t.text)
        {
            case "version":
            case "debug":
                mention(ts, i, s.mentions);
                break;
            case "mixin":
                if (i + 1 < ts.length && ts[i + 1] == "(")
                {
                    const close = matching(ts, i + 1);
                    if (buildsCondition(ts[i + 2 .. close]))
                        s.stringConditions ~= StringCondition(StringConditionKind.mixin_, t.line, i < unittestEnd);
                    if (joinedHasWord(ts[i + 2 .. close], "import"))
                        s.mixinImports ~= t.line;
                }
                break;
            case "enum":
                if (startsDeclaration(ts, i))
                    constantConditions(ts, i, i < unittestEnd, s.stringConditions);
                if (i + 1 < ts.length && ts[i + 1] == "isVersion")
                    s.declaresIsVersion = true;
                break;
            case "template":
            case "alias":
                if (i + 1 < ts.length && ts[i + 1] == "isVersion")
                    s.declaresIsVersion = true;
                break;
            case "module":
                if (i == 0 || !(ts[i - 1] == "."))
                    s.moduleName = dottedName(ts, i + 1);
                break;
            case "import":
                if (i + 1 < ts.length && !(ts[i + 1] == "("))
                    i = importDecl(ts, i, depth == 0 && visibility.public_, s.imports);
                break;
            case "public":
            case "private":
            case "package":
            case "protected":
                if (depth == 0 && i + 1 < ts.length && ts[i + 1] == ":")
                    visibility.public_ = t.text == "public";
                break;
            case "unittest":
                if (i + 1 < ts.length && ts[i + 1] == "{")
                {
                    s.unittestBlocks ~= [i, matching(ts, i + 1) + 1];
                    unittestEnd = s.unittestBlocks[$ - 1][1];
                }
                break;
            default:
                break;
        }
    }
    return s;
}

///
@("d_source.mentions.scanSource.conditionsAndAssignments")
@safe unittest
{
    const s = scanSource(`
        module a.b;
        version (Foo) int x;
        else version(Bar) {}
        debug (Trace) {}
        version = Derived;
        debug = Verbose;
        static if (a == b) {}
        version (1) {}
        debug { }
    `);
    assert(s.moduleName == "a.b");
    string[] names;
    foreach (m; s.mentions)
        names ~= (m.debug_ ? "debug:" : "") ~ m.identifier;
    assert(names == ["Foo", "Bar", "debug:Trace", "Derived", "debug:Verbose"], names[0]);
    assert(s.mentions[0].line == 3);
}

/// The mentions in a file under a string import root, read as text: a word
/// `version` or `debug`, then `(` and an identifier and `)`, or `=` and an
/// identifier, with any whitespace between.
Mention[] scanText(const(char)[] text) @safe pure nothrow
{
    Mention[] found;
    uint line = 1;
    for (size_t i = 0; i < text.length; ++i)
    {
        if (text[i] == '\n')
        {
            ++line;
            continue;
        }
        if (i > 0 && isWordChar(text[i - 1]))
            continue;
        bool isDebug;
        size_t j;
        if (startsWithAt(text, i, "version"))
            j = i + "version".length;
        else if (startsWithAt(text, i, "debug"))
        {
            j = i + "debug".length;
            isDebug = true;
        }
        else
            continue;
        if (j < text.length && isWordChar(text[j]))
            continue;
        j = skipSpaces(text, j);
        if (j >= text.length)
            continue;
        const assignment = text[j] == '=';
        if (!assignment && text[j] != '(')
            continue;
        if (assignment && j + 1 < text.length && (text[j + 1] == '=' || text[j + 1] == '>'))
            continue;
        j = skipSpaces(text, j + 1);
        const from = j;
        while (j < text.length && isWordChar(text[j]))
            ++j;
        if (j == from || isDigitChar(text[from]))
            continue;
        const id = text[from .. j];
        if (!assignment)
        {
            const close = skipSpaces(text, j);
            if (close >= text.length || text[close] != ')')
                continue;
        }
        found ~= Mention(id.idup, line, isDebug);
    }
    return found;
}

///
@("d_source.mentions.scanText.anyExtension")
@safe pure nothrow unittest
{
    const ms = scanText("# a template\nversion ( Foo )\nsubversion(X) version == Y\ndebug= Bar;\n");
    assert(ms.length == 2);
    assert(ms[0] == Mention("Foo", 2, false));
    assert(ms[1] == Mention("Bar", 4, true));
}

/// A use of `sparkles.base.meta.isVersion` outside a `unittest` block.
struct IsVersionUse
{
    uint line; ///
    /// The argument when it is one string literal; null otherwise.
    const(char)[] literal;
    bool literalArgument; /// whether the argument is one string literal
}

/**
The uses of `sparkles.base.meta.isVersion` in `s`, outside `unittest` blocks.

A name resolves to it through the file's imports, as D's lookup does:
an unqualified `isVersion` through a non-static import of a module that
`reexports`, unless the file declares its own; a selective or renamed binding
of `isVersion` from such a module; and a qualified name whose qualifier is
such a module or a renamed import of one.

Params:
    s = the scanned file
    reexports = whether a module's public names include `meta`'s
        `isVersion`: `sparkles.base.meta` itself, and every module that
        publicly imports one that does
*/
IsVersionUse[] isVersionUses(const ScannedSource s, scope bool delegate(const(char)[] module_) @safe reexports)
    @safe
{
    bool[string] unqualified;
    bool[string] qualifiers;
    foreach (ref imp; s.imports)
    {
        if (!reexports(imp.module_))
            continue;
        if (imp.bindings.length)
        {
            foreach (b; imp.bindings)
                if (b.name == "isVersion")
                    unqualified[b.alias_] = true;
            continue;
        }
        if (imp.renamed.length)
            qualifiers[imp.renamed] = true;
        else
        {
            qualifiers[imp.module_] = true;
            if (!imp.static_ && !s.declaresIsVersion)
                unqualified["isVersion"] = true;
        }
    }
    if (reexports(s.moduleName) && s.moduleName.length)
        qualifiers[s.moduleName] = true;

    IsVersionUse[] uses;
    const ts = s.tokens;
    foreach (i, t; ts)
    {
        if (t.kind != TokenKind.identifier || i + 1 >= ts.length || !(ts[i + 1] == "!"))
            continue;
        if (insideAny(s.unittestBlocks, i))
            continue;
        bool resolves;
        if (i >= 2 && ts[i - 1] == "." && t.text == "isVersion")
            resolves = (qualifierBefore(ts, i) in qualifiers) !is null;
        else if (!(i > 0 && ts[i - 1] == "."))
            resolves = (t.text in unqualified) !is null;
        if (!resolves)
            continue;
        uses ~= argumentOf(ts, i + 2, t.line);
    }
    return uses;
}

///
@("d_source.mentions.isVersionUses.throughImports")
@safe unittest
{
    bool reexports(const(char)[] m) @safe => m == "sparkles.base.meta" || m == "sparkles.base";

    // Unqualified through a package's public import, and literal checks.
    const a = scanSource(`
        import sparkles.base;
        enum x = isVersion!"linux";
        enum y = isVersion!(name);
        unittest { enum z = isVersion!(v); }
    `);
    const ua = isVersionUses(a, &reexports);
    assert(ua.length == 2);
    assert(ua[0].literalArgument && ua[0].literal == "linux");
    assert(!ua[1].literalArgument && ua[1].line == 4);

    // Selective, renamed and qualified forms; another module's isVersion
    // is not meta's.
    const b = scanSource(`
        import sparkles.base.meta : iv = isVersion;
        import m = sparkles.base.meta;
        static import sparkles.base.meta;
        import sparkles.versions.traits : isVersion;
        enum p = iv!"OSX";
        enum q = m.isVersion!("Windows");
        enum r = sparkles.base.meta.isVersion!"Posix";
        enum s = isVersion!T;
        enum t = foo.bar.isVersion!"X";
    `);
    const ub = isVersionUses(b, &reexports);
    assert(ub.length == 3);
    assert(ub[0].literal == "OSX" && ub[1].literal == "Windows" && ub[2].literal == "Posix");

    // A file's own isVersion shadows an imported one.
    const c = scanSource(`
        import sparkles.base.meta;
        enum isVersion(T) = true;
        static assert(isVersion!int);
    `);
    assert(isVersionUses(c, &reexports).length == 0);
}

/// Whether `identifier` is one of D's predefined version identifiers.
bool isPredefinedVersion(scope const(char)[] identifier) @safe pure nothrow @nogc
    => predefinedVersions.canFind(identifier);

///
@("d_source.mentions.isPredefinedVersion")
@safe pure nothrow @nogc unittest
{
    assert(isPredefinedVersion("linux") && isPredefinedVersion("D_BetterC"));
    assert(!isPredefinedVersion("SparklesTrace"));
}

/// D's predefined version identifiers: the language specification's list
/// (`version.html#predefined-versions`) and `Apple`, which DMD 2.113 also
/// predefines. The frontend's reserved list (`dmd.cond`) is the authority;
/// this package depends on the lexer only, which does not carry it.
immutable string[] predefinedVersions = [
    "DigitalMars", "GNU", "LDC", "SDC", "D_NET", "D_LP64", "D_X32",
    "D_HardFloat", "D_SoftFloat", "D_PIC", "D_PIE", "D_SIMD", "D_AVX", "D_AVX2",
    "D_Version2", "D_NoBoundsChecks", "D_ObjectiveC", "D_ProfileGC", "D_Optimized",
    "D_Coverage", "D_Ddoc", "D_InlineAsm_X86", "D_InlineAsm_X86_64", "D_BetterC",
    "D_ModuleInfo", "D_Exceptions", "D_TypeInfo", "D_Invariants",
    "D_PreConditions", "D_PostConditions", "all", "none", "unittest", "assert",
    "Windows", "Win32", "Win64", "linux", "OSX", "iOS", "TVOS", "WatchOS",
    "VisionOS", "FreeBSD", "OpenBSD", "NetBSD", "DragonFlyBSD", "BSD", "Solaris",
    "Apple", "Posix", "AIX", "Haiku", "SkyOS", "SysV3", "SysV4", "Hurd", "Android",
    "Emscripten", "PlayStation", "PlayStation4", "Cygwin", "MinGW",
    "FreeStanding", "CRuntime_Bionic", "CRuntime_DigitalMars", "CRuntime_Glibc",
    "CRuntime_Microsoft", "CRuntime_Musl", "CRuntime_Newlib", "CRuntime_UClibc",
    "CRuntime_WASI", "CppRuntime_LLVM", "CppRuntime_DigitalMars", "CppRuntime_GNU",
    "CppRuntime_Microsoft", "CppRuntime_Sun", "X86", "X86_64", "ARM",
    "ARM_Thumb", "ARM_SoftFloat", "ARM_SoftFP", "ARM_HardFloat", "AArch64",
    "AsmJS", "AVR", "Epiphany", "PPC", "PPC_SoftFloat", "PPC_HardFloat", "PPC64",
    "IA64", "MIPS32", "MIPS64", "MIPS_O32", "MIPS_N32", "MIPS_O64", "MIPS_N64",
    "MIPS_EABI", "MIPS_SoftFloat", "MIPS_HardFloat", "MSP430", "NVPTX",
    "NVPTX64", "RISCV32", "RISCV64", "SPARC", "SPARC_V8Plus", "SPARC_SoftFloat",
    "SPARC_HardFloat", "SPARC64", "S390", "SystemZ", "HPPA", "HPPA64", "SH",
    "Alpha", "Alpha_SoftFloat", "Alpha_HardFloat", "LoongArch32", "LoongArch64",
    "LoongArch_HardFloat", "LoongArch_SoftFloat", "Xtensa", "WebAssembly", "WASI",
    "LittleEndian", "BigEndian", "ELFv1", "ELFv2",
];

@("d_source.mentions.scanSource.stringBuiltConditions")
@safe unittest
{
    const s = scanSource(`
        mixin("ver" ~ "sion (", name, ") {}");
        mixin(q{ debug(Trace) {} });
        mixin("int x;");
        enum code = "version" ~ " (X)";
        enum string other = "plain", third = "debug  (Y)";
        enum E : string { a = "version(Z)" }
        static if (is(T == enum)) { enum ok = 1; }
        mixin Templ!();
        unittest { enum t = "debug(T)"; }
        mixin("import " ~ name ~ ";");
        mixin("int imported;");
    `);
    assert(s.mixinImports == [11]);
    import std.algorithm.iteration : map;
    import std.array : array;

    assert(s.stringConditions.map!(c => c.line).array == [2, 3, 5, 6, 7, 10]);
    assert(s.stringConditions.map!(c => c.insideUnittest).array == [false, false, false, false, false, true]);
    assert(s.stringConditions[0].kind == StringConditionKind.mixin_);
    assert(s.stringConditions[2].kind == StringConditionKind.constant);
}

@("d_source.mentions.scanSource.imports")
@safe unittest
{
    const s = scanSource(`
        module p.q;
        import a.b, c = d.e;
        public import f : g, h = i;
        static import j;
        public:
        import k;
        struct S { public: import l; }
        enum s = import("file.txt");
    `);
    assert(s.imports.length == 6);
    assert(s.imports[0] == ImportDecl("a.b", null, false, false, null, 3));
    assert(s.imports[1].module_ == "d.e" && s.imports[1].renamed == "c");
    assert(s.imports[2].public_ && s.imports[2].bindings == [ImportBinding("g", "g"), ImportBinding("i", "h")]);
    assert(s.imports[3].static_);
    assert(s.imports[4].module_ == "k" && s.imports[4].public_);
    assert(s.imports[5].module_ == "l" && !s.imports[5].public_);
}

private:

struct Visibility
{
    bool public_;
}

bool isWordChar(char c) @safe pure nothrow @nogc
    => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c >= 0x80;

bool isDigitChar(char c) @safe pure nothrow @nogc => c >= '0' && c <= '9';

bool startsWithAt(const(char)[] text, size_t i, string word) @safe pure nothrow @nogc
    => text.length - i >= word.length && text[i .. i + word.length] == word;

size_t skipSpaces(const(char)[] text, size_t i) @safe pure nothrow @nogc
{
    while (i < text.length && (text[i] == ' ' || text[i] == '\t' || text[i] == '\r' || text[i] == '\n'))
        ++i;
    return i;
}

// `version (X)`, `version = X`, and their `debug` forms, at `ts[i]`.
void mention(const Token[] ts, size_t i, ref Mention[] into) @safe pure nothrow
{
    const isDebug = ts[i].text == "debug";
    if (i + 2 >= ts.length)
        return;
    const next = ts[i + 1];
    if (next == "(" && ts[i + 2].kind == TokenKind.identifier && i + 3 < ts.length && ts[i + 3] == ")")
        into ~= Mention(ts[i + 2].text.idup, ts[i + 2].line, isDebug);
    else if (next == "=" && ts[i + 2].kind == TokenKind.identifier)
        into ~= Mention(ts[i + 2].text.idup, ts[i + 2].line, isDebug);
}

// The index of the bracket closing the one at `ts[open]`; `ts.length` if none.
size_t matching(const Token[] ts, size_t open) @safe pure nothrow @nogc
{
    const o = ts[open].text;
    const c = o == "(" ? ")" : o == "[" ? "]" : "}";
    size_t depth;
    foreach (i; open .. ts.length)
    {
        if (ts[i].kind != TokenKind.operator)
            continue;
        if (ts[i].text == o)
            ++depth;
        else if (ts[i].text == c && --depth == 0)
            return i;
    }
    return ts.length;
}

// Whether the string literals among `ts`, joined, contain `version` or
// `debug` followed by `(`, with optional whitespace between.
bool buildsCondition(const Token[] ts) @safe pure nothrow
{
    const(char)[] joined;
    foreach (t; ts)
        if (t.kind == TokenKind.string_)
            joined ~= t.value;
    foreach (word; ["version", "debug"])
        for (size_t at = 0; at + word.length <= joined.length; ++at)
            if (joined[at .. at + word.length] == word)
            {
                const j = skipSpaces(joined, at + word.length);
                if (j < joined.length && joined[j] == '(')
                    return true;
            }
    return false;
}

// Whether the string literals among `ts`, joined, contain `word` as a word.
bool joinedHasWord(const Token[] ts, string word) @safe pure nothrow
{
    const(char)[] joined;
    foreach (t; ts)
        if (t.kind == TokenKind.string_)
            joined ~= t.value;
    for (size_t at = 0; at + word.length <= joined.length; ++at)
        if (joined[at .. at + word.length] == word
            && (at == 0 || !isWordChar(joined[at - 1]))
            && (at + word.length == joined.length || !isWordChar(joined[at + word.length])))
            return true;
    return false;
}

// Whether the `enum` at `ts[i]` begins a declaration, rather than being
// the `enum` of `is(T == enum)`.
bool startsDeclaration(const Token[] ts, size_t i) @safe pure nothrow @nogc
{
    if (i + 1 >= ts.length)
        return false;
    const next = ts[i + 1];
    if (next.kind != TokenKind.identifier && !(next == ":") && !(next == "{"))
        return false;
    if (i == 0)
        return true;
    const prev = ts[i - 1];
    if (prev.kind == TokenKind.operator)
        return prev == ";" || prev == "{" || prev == "}" || prev == ":" || prev == ")";
    return prev.kind == TokenKind.identifier;
}

// Each initializer of the `enum` declaration at `ts[i]` that builds a
// condition, as one string-built condition at the declaration's line.
void constantConditions(const Token[] ts, size_t i, bool insideUnittest, ref StringCondition[] into) @safe pure nothrow
{
    size_t j = i + 1;
    // The declaration ends at its `;`, or at the `}` of a body.
    size_t depth;
    size_t initializer = size_t.max;
    void close(size_t end)
    {
        if (initializer != size_t.max && buildsCondition(ts[initializer .. end]))
            into ~= StringCondition(StringConditionKind.constant, ts[i].line, insideUnittest);
        initializer = size_t.max;
    }
    for (; j < ts.length; ++j)
    {
        const t = ts[j];
        if (t.kind != TokenKind.operator)
            continue;
        if (t == "(" || t == "[")
            ++depth;
        else if ((t == ")" || t == "]") && depth)
            --depth;
        else if (t == "{" && depth == 0)
        {
            // A named or anonymous enum's members: each `= …` up to `,` or `}`.
            for (++j; j < ts.length; ++j)
            {
                const m = ts[j];
                if (m == "=" && initializer == size_t.max)
                    initializer = j + 1;
                else if (m == "(" || m == "[")
                    ++depth;
                else if ((m == ")" || m == "]") && depth)
                    --depth;
                else if (depth == 0 && (m == "," || m == "}"))
                {
                    close(j);
                    if (m == "}")
                        return;
                }
            }
            return;
        }
        else if (depth == 0 && t == "=" && initializer == size_t.max)
            initializer = j + 1;
        else if (depth == 0 && t == ",")
            close(j);
        else if (depth == 0 && t == ";")
        {
            close(j);
            return;
        }
    }
    close(ts.length);
}

// The dotted name starting at `ts[i]`.
string dottedName(const Token[] ts, size_t i) @safe pure nothrow
{
    string name;
    while (i < ts.length && ts[i].kind == TokenKind.identifier)
    {
        name ~= ts[i].text;
        if (i + 2 < ts.length && ts[i + 1] == "." && ts[i + 2].kind == TokenKind.identifier)
        {
            name ~= ".";
            i += 2;
        }
        else
            break;
    }
    return name;
}

// The token index after a dotted name starting at `ts[i]`.
size_t afterDottedName(const Token[] ts, size_t i) @safe pure nothrow @nogc
{
    while (i < ts.length && ts[i].kind == TokenKind.identifier)
    {
        if (i + 2 < ts.length && ts[i + 1] == "." && ts[i + 2].kind == TokenKind.identifier)
            i += 2;
        else
            return i + 1;
    }
    return i;
}

// Parses the import declaration at `ts[i]` (the `import`), returning the
// index of its `;`.
size_t importDecl(const Token[] ts, size_t i, bool publicByLabel, ref ImportDecl[] into) @safe pure nothrow
{
    bool isPublic = publicByLabel, isStatic;
    for (size_t k = i; k > 0; --k)
    {
        const p = ts[k - 1];
        if (p == "public")
            isPublic = true;
        else if (p == "private" || p == "package" || p == "protected")
            isPublic = false;
        else if (p == "static")
            isStatic = true;
        else
            break;
    }
    const first = into.length;
    size_t j = i + 1;
    while (j < ts.length)
    {
        ImportDecl d;
        d.line = ts[j].line;
        d.public_ = isPublic;
        d.static_ = isStatic;
        if (j + 1 < ts.length && ts[j].kind == TokenKind.identifier && ts[j + 1] == "=")
        {
            d.renamed = ts[j].text.idup;
            j += 2;
        }
        d.module_ = dottedName(ts, j);
        j = afterDottedName(ts, j);
        into ~= d;
        if (j >= ts.length || ts[j] == ";")
            return j;
        if (ts[j] == ",")
        {
            ++j;
            continue;
        }
        if (ts[j] == ":")
        {
            ++j;
            auto last = &into[$ - 1];
            while (j < ts.length && !(ts[j] == ";"))
            {
                if (ts[j].kind == TokenKind.identifier)
                {
                    if (j + 2 < ts.length && ts[j + 1] == "=" && ts[j + 2].kind == TokenKind.identifier)
                    {
                        last.bindings ~= ImportBinding(ts[j + 2].text.idup, ts[j].text.idup);
                        j += 3;
                        continue;
                    }
                    last.bindings ~= ImportBinding(ts[j].text.idup, ts[j].text.idup);
                }
                ++j;
            }
            return j;
        }
        // Not an import declaration after all; drop what was read.
        into = into[0 .. first];
        return i;
    }
    return j;
}

// The dotted qualifier of the name at `ts[i]`, which follows a `.`: `a.b`
// in `a.b.isVersion`. Null when the qualifier itself follows a `.` or an
// expression, as a member access does.
string qualifierBefore(const Token[] ts, size_t i) @safe pure nothrow
{
    size_t from = i - 1; // the `.` before the name
    while (from >= 1 && ts[from - 1].kind == TokenKind.identifier)
    {
        if (from >= 2 && ts[from - 2] == ".")
            from -= 2;
        else
        {
            --from;
            break;
        }
    }
    if (ts[from].kind != TokenKind.identifier)
        return null;
    string name;
    for (size_t k = from; k < i - 1; ++k)
        name ~= ts[k].text;
    return name;
}

bool insideAny(const size_t[2][] ranges, size_t i) @safe pure nothrow @nogc
{
    foreach (r; ranges)
        if (i >= r[0] && i < r[1])
            return true;
    return false;
}

// The template argument at `ts[i]` (after the `!`).
IsVersionUse argumentOf(const Token[] ts, size_t i, uint line) @safe pure nothrow @nogc
{
    if (i < ts.length && ts[i].kind == TokenKind.string_)
        return IsVersionUse(line, ts[i].value, true);
    if (i + 2 < ts.length && ts[i] == "(" && ts[i + 1].kind == TokenKind.string_ && ts[i + 2] == ")")
        return IsVersionUse(line, ts[i + 1].value, true);
    return IsVersionUse(line, null, false);
}
