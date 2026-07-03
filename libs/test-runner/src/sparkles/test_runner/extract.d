/**
 * Source extraction of `unittest` bodies and generation of standalone
 * `-betterC` / WebAssembly test programs.
 *
 * `unittest` blocks cannot run under `-betterC` (druntime's test driver is
 * absent) or on `wasm32` targets, so the runner's `--better-c` / `--wasm`
 * modes $(I extract) the annotated tests: each test's body is sliced out of
 * its source file (located via `__traits(getLocation)` metadata gathered at
 * discovery), re-emitted as a named function in a generated program with a
 * hand-rolled `main`, compiled for the special environment, and executed.
 * The same approach — reflection-driven instead of parser-driven — replaces
 * dlang's libdparse-based `tests_extractor`.
 *
 * Extracted tests `import` their module, so they can only reference its
 * $(B public) symbols, and only template/CTFE-able ones are usable without
 * linking the module in (the phobos `@betterC` test suite has the same
 * constraints).
 *
 * Everything in this module is pure string processing — the process
 * orchestration lives in $(MREF sparkles,test_runner,driver).
 */
module sparkles.test_runner.extract;

import sparkles.test_runner.attributes : betterC, wasm;
import sparkles.test_runner.model : Test;

// ─────────────────────────────────────────────────────────────────────────────
// Body extraction
// ─────────────────────────────────────────────────────────────────────────────

/// The byte offset where line `line` (1-based) starts in `source`.
size_t lineOffset(string source, size_t line) @safe pure nothrow @nogc
{
    size_t current = 1;
    foreach (i, c; source)
    {
        if (current >= line)
            return i;
        if (c == '\n')
            current++;
    }
    return source.length;
}

/// Extracts the body of the `unittest` block declared at `line` (its
/// `__traits(getLocation)` line): the text between the block's braces,
/// without the braces themselves. Returns `null` when no block is found.
string extractUnittestBody(string source, size_t line) @safe pure
{
    import std.string : indexOf;

    const start = source.lineOffset(line);
    const keyword = source.indexOf("unittest", start);
    if (keyword < 0)
        return null;
    const open = source.indexOf('{', keyword);
    if (open < 0)
        return null;

    const close = matchingBrace(source, open);
    if (close == size_t.max)
        return null;
    return source[open + 1 .. close];
}

/// The index of the `}` matching the `{` at `open`, skipping comments and
/// string/character literals; `size_t.max` when unbalanced.
size_t matchingBrace(string source, size_t open) @safe pure
in (source[open] == '{')
{
    size_t depth = 0;
    for (size_t i = open; i < source.length;)
    {
        const c = source[i];
        switch (c)
        {
            case '{':
                depth++;
                i++;
                break;
            case '}':
                depth--;
                if (depth == 0)
                    return i;
                i++;
                break;
            case '/':
                i = skipComment(source, i);
                break;
            case '"':
                // Wysiwyg (`r"…"`) and hex (`x"…"`) prefixes lex the same way
                // from the quote; escapes are only special in regular strings.
                i = skipString(source, i, '"',
                    escapes: !(i > 0 && (source[i - 1] == 'r' || source[i - 1] == 'x')));
                break;
            case '`':
                i = skipString(source, i, '`', escapes: false);
                break;
            case '\'':
                i = skipString(source, i, '\'', escapes: true);
                break;
            default:
                i++;
        }
    }
    return size_t.max;
}

/// Advances past a comment starting at `i` (which points at `/`), or one
/// character when it is a lone slash. Handles `//`, `/* */`, and nesting
/// `/+ +/`.
private size_t skipComment(string source, size_t i) @safe pure nothrow @nogc
{
    if (i + 1 >= source.length)
        return i + 1;
    switch (source[i + 1])
    {
        case '/':
            while (i < source.length && source[i] != '\n')
                i++;
            return i;
        case '*':
            i += 2;
            while (i + 1 < source.length && !(source[i] == '*' && source[i + 1] == '/'))
                i++;
            return i + 2;
        case '+':
            i += 2;
            size_t depth = 1;
            while (i + 1 < source.length && depth > 0)
            {
                if (source[i] == '/' && source[i + 1] == '+')
                {
                    depth++;
                    i += 2;
                }
                else if (source[i] == '+' && source[i + 1] == '/')
                {
                    depth--;
                    i += 2;
                }
                else
                    i++;
            }
            return i;
        default:
            return i + 1;
    }
}

/// Advances past a string/character literal starting at `i` (which points at
/// the opening `quote`).
private size_t skipString(string source, size_t i, char quote, bool escapes)
@safe pure nothrow @nogc
{
    i++;
    while (i < source.length)
    {
        if (escapes && source[i] == '\\')
            i += 2;
        else if (source[i] == quote)
            return i + 1;
        else
            i++;
    }
    return i;
}

@("extractUnittestBody.basic")
@safe pure
unittest
{
    enum source = "module m;\n\n@safe unittest\n{\n    assert(1 + 1 == 2);\n}\n";
    assert(extractUnittestBody(source, 3) == "\n    assert(1 + 1 == 2);\n");
}

@("extractUnittestBody.trickyLexemes")
@safe pure
unittest
{
    enum source = `module m;
unittest
{
    string s = "}\"}";
    string w = ` ~ "`}`" ~ `;
    char c = '}';
    // } line comment
    /* } block */
    /+ /+ } +/ } +/
    int nested() { return 1; }
}
trailing`;
    const body_ = extractUnittestBody(source, 2);
    assert(body_ !is null);
    import std.algorithm.searching : canFind, endsWith;

    assert(body_.canFind("int nested() { return 1; }"));
    assert(body_.endsWith("\n"));
    assert(!body_.canFind("trailing"));
}

@("matchingBrace.unbalanced")
@safe pure
unittest
{
    assert(matchingBrace("{ no close", 0) == size_t.max);
}

@("extract.braceCounting.betterC")
@betterC @safe pure nothrow @nogc
unittest
{
    // Dogfoods @betterC end to end. Extracted tests can only link against
    // templates, so this one is deliberately self-contained.
    int depth;
    foreach (c; "{ { } }")
        depth += c == '{' ? 1 : c == '}' ? -1 : 0;
    assert(depth == 0);
}

// ─────────────────────────────────────────────────────────────────────────────
// Import-path derivation
// ─────────────────────────────────────────────────────────────────────────────

/// Derives the source root of a module from its file path and dotted name:
/// `("libs/base/src/sparkles/base/smallbuffer.d", "sparkles.base.smallbuffer")`
/// yields `"libs/base/src"`. Returns `null` when the path does not end with
/// the module path.
string sourceRootOf(string file, string moduleName) @safe pure nothrow
{
    import std.array : replace;
    import std.string : endsWith, chomp;

    foreach (suffix; [
        "/" ~ moduleName.replace(".", "/") ~ ".d",
        "/" ~ moduleName.replace(".", "/") ~ "/package.d",
    ])
        if (file.endsWith(suffix))
            return file[0 .. $ - suffix.length];
    return null;
}

@("sourceRootOf.plainAndPackage")
@safe pure
unittest
{
    assert(sourceRootOf("libs/base/src/sparkles/base/smallbuffer.d",
        "sparkles.base.smallbuffer") == "libs/base/src");
    assert(sourceRootOf("src/sparkles/base/text/package.d",
        "sparkles.base.text") == "src");
    assert(sourceRootOf("unrelated.d", "sparkles.base") is null);
}

// ─────────────────────────────────────────────────────────────────────────────
// Program generation
// ─────────────────────────────────────────────────────────────────────────────

/// One extracted test, ready to be emitted into a generated program.
struct ExtractedTest
{
    string name; /// display name
    string moduleName;
    string file;
    size_t line;
    string functionAttributes; /// e.g. `"@safe pure nothrow @nogc "`
    string body_; /// the unittest body, braces stripped
}

/// The extracted-function part shared by both generated programs: one named,
/// attribute-preserving function per test, with `#line` directives so
/// compile errors point into the original files.
private string emitTestFunctions(in ExtractedTest[] tests) @safe pure
{
    import std.algorithm.iteration : map, uniq;
    import std.algorithm.sorting : sort;
    import std.array : array;
    import std.conv : text;
    import std.format : format;

    // `[0 .. $]` re-slices `const(string)` to `string` so `sort` can swap.
    auto imports = tests.map!(t => t.moduleName[0 .. $]).array.sort.uniq;

    string source;
    foreach (moduleName; imports)
        source ~= text("import ", moduleName, ";\n");
    source ~= "\n";

    foreach (i, ref test; tests)
        source ~= format!"// %s\n#line %s \"%s\"\n%svoid test_%s()\n{%s}\n\n"(
            test.name, test.line, test.file, test.functionAttributes, i, test.body_);
    return source;
}

/// A complete standalone `-betterC` program running the given tests: the
/// extracted functions plus an `extern(C) main` announcing each test before
/// running it (so an `assert` abort is attributable).
string generateBetterCProgram(in ExtractedTest[] tests) @safe pure
{
    import std.format : format;

    string source = "// Generated by sparkles:test-runner --better-c; do not edit.\n"
        ~ "module sparkles_test_runner_betterc;\n\n"
        ~ emitTestFunctions(tests)
        ~ "extern(C) int main()\n{\n"
        ~ "    import core.stdc.stdio : fflush, printf;\n\n";

    foreach (i, ref test; tests)
        source ~= format!"    printf(\" > %%s\\n\", \"%s [%s:%s]\".ptr);\n"(
                test.name, test.file, test.line)
            ~ format!"    fflush(null);\n    test_%s();\n"(i);

    source ~= format!"\n    printf(\"%s @betterC tests passed\\n\");\n    return 0;\n}\n"(
        tests.length);
    return source;
}

/// A complete `wasm32` test module: the extracted functions, each exported as
/// `test_<i>` for individual invocation by the host shim, plus a trapping
/// `__assert` handler (there is no libc on bare `wasm32`, so a failed
/// `assert` traps and surfaces as a host-side `RuntimeError`).
string generateWasmProgram(in ExtractedTest[] tests) @safe pure
{
    import std.format : format;

    string source = "// Generated by sparkles:test-runner --wasm; do not edit.\n"
        ~ "module sparkles_test_runner_wasm;\n\n"
        ~ emitTestFunctions(tests)
        ~ q{// Bare wasm32 has no libc: fail by trapping (host sees RuntimeError).
extern(C) void __assert(const(char)* message, const(char)* file, int line)
{
    import ldc.intrinsics : llvm_trap;

    llvm_trap();
}
} ~ "\n";

    foreach (i, ref test; tests)
        source ~= format!"extern(C) export void run_test_%s() { test_%s(); }\n"(i, i);
    return source;
}

/// A double-quoted JavaScript string literal with `\` and `"` escaped.
private string jsString(string value) @safe pure nothrow
{
    string result = `"`;
    foreach (c; value)
    {
        if (c == '\\' || c == '"')
            result ~= '\\';
        result ~= c;
    }
    return result ~ `"`;
}

/// The JavaScript shim executing a generated wasm test module under node,
/// deno, or bun: instantiates the module and calls each `run_test_<i>`
/// export, reporting per-test outcomes.
string generateWasmJsShim(in ExtractedTest[] tests, string wasmFile) @safe pure
{
    import std.conv : text;

    string names = "[";
    foreach (i, ref test; tests)
        names ~= text(i ? ", " : "",
            "[", jsString(test.name), ", ",
            jsString(text(test.file, ':', test.line)), "]");
    names ~= "]";

    return "// Generated by sparkles:test-runner --wasm; do not edit.\n"
        ~ "const tests = " ~ names ~ ";\n"
        ~ "const load = async () => {\n"
        ~ "    const fs = await import('node:fs');\n"
        ~ "    const bytes = fs.readFileSync(" ~ jsString(wasmFile) ~ ");\n"
        ~ "    const {instance} = await WebAssembly.instantiate(bytes, {});\n"
        ~ "    return instance;\n"
        ~ "};\n"
        ~ "load().then(instance => {\n"
        ~ "    let failed = 0;\n"
        ~ "    tests.forEach(([name, loc], i) => {\n"
        ~ "        try {\n"
        ~ "            instance.exports['run_test_' + i]();\n"
        ~ "            console.log(' \\u2713 ' + name + ' [' + loc + ']');\n"
        ~ "        } catch (e) {\n"
        ~ "            failed++;\n"
        ~ "            console.log(' \\u2717 ' + name + ' [' + loc + ']: ' + e);\n"
        ~ "        }\n"
        ~ "    });\n"
        ~ "    if (failed) process.exit(1);\n"
        ~ "    console.log(tests.length + ' @wasm tests passed');\n"
        ~ "}).catch(e => { console.error(e); process.exit(1); });\n";
}

@("generateBetterCProgram.shape")
@safe pure
unittest
{
    import std.algorithm.searching : canFind;

    const tests = [ExtractedTest(
        name: "demo.one",
        moduleName: "pkg.mod",
        file: "src/pkg/mod.d",
        line: 12,
        functionAttributes: "@safe pure nothrow @nogc ",
        body_: "\n    assert(1 + 1 == 2);\n",
    )];
    const program = generateBetterCProgram(tests);
    assert(program.canFind("import pkg.mod;"));
    assert(program.canFind("#line 12 \"src/pkg/mod.d\""));
    assert(program.canFind("@safe pure nothrow @nogc void test_0()"));
    assert(program.canFind("extern(C) int main()"));
    assert(program.canFind(`printf(" > %s\n", "demo.one [src/pkg/mod.d:12]".ptr);`));
}

@("generateWasmProgram.shape")
@safe pure
unittest
{
    import std.algorithm.searching : canFind;

    const tests = [ExtractedTest(
        name: "demo.wasm",
        moduleName: "pkg.mod",
        file: "src/pkg/mod.d",
        line: 3,
        functionAttributes: "",
        body_: " assert(true); ",
    )];
    const program = generateWasmProgram(tests);
    assert(program.canFind("extern(C) export void run_test_0() { test_0(); }"));
    assert(program.canFind("llvm_trap();"));

    const shim = generateWasmJsShim(tests, "out.wasm");
    assert(shim.canFind(`[["demo.wasm", "src/pkg/mod.d:3"]]`));
    assert(shim.canFind(`readFileSync("out.wasm")`));
}
