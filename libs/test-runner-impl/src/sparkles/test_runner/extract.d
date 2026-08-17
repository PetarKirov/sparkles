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
 * $(B public) symbols. By default the driver also compiles that module into
 * the generated program (`-i=<module>`), so ordinary functions are reachable
 * and not just templates; a test that opts out with
 * `@betterC(selfContained: true)` keeps its module out entirely and is then
 * limited to templates and CTFE-able code (the phobos `@betterC` suite's
 * model, and what lets a module that cannot itself compile under `-betterC`
 * still host such a test).
 *
 * This module also generates the `@ctfe` probe program (see
 * $(LREF generateCtfeProgram)), which involves no extraction at all: the
 * probe imports the tests' modules and selects tests by reflection, so their
 * bodies stay in place.
 *
 * Everything in this module is pure string processing — the process
 * orchestration lives in $(MREF sparkles,test_runner,driver).
 */
module sparkles.test_runner.extract;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.text.scan : isIdentChar, lineOffset, matchingBrace,
    putQuotedStringLiteral, skipComment, skipDelimitedString, skipString;
import sparkles.test_runner.attributes : betterC, wasm;
import sparkles.test_runner.model : Test;

/// A garbage-collected D/JS string literal for `value`.
///
/// The escaping itself lives in `sparkles.base.text.scan` as an
/// allocation-free writer so that module stays `-betterC`-clean; every caller
/// here splices the result into a generated program with `format`/`~`/`join`,
/// which needs a `string` that outlives the buffer. This is that boundary, and
/// the only place the branch pays for a GC copy.
private string quotedStringLiteral(scope const(char)[] value) @safe pure nothrow
{
    SmallBuffer!(char, 256) buf;
    buf.putQuotedStringLiteral(value);
    return buf[].idup;
}

// ─────────────────────────────────────────────────────────────────────────────
// Body extraction
// ─────────────────────────────────────────────────────────────────────────────

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

@("extract.matchingBrace.delimitedStrings")
@safe pure
unittest
{
    // A `}` (or an unescaped quote) inside a delimited string must not end the
    // body scan early — each source below is one balanced block.
    static void check(string src)
    {
        assert(matchingBrace(src, 0) == src.length - 1, src);
    }

    check(`{ auto s = q"(} unbalanced ")"; f(); }`);
    check(`{ auto s = q"[brace } quote "]"; }`);
    check(`{ auto s = q"(nested (parens) still })"; }`);
    check("{ auto s = q\"/brace } quote \"/\"; }");
    check("{ auto s = q\"EOS\nbrace } quote \"\nEOS\"; }");
    // A `q` that ends an identifier is not a delimited-string prefix.
    check(`{ auto freq = 1; auto s = "x"; }`);
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
@betterC(selfContained: true) @safe pure nothrow @nogc
unittest
{
    // Dogfoods @betterC end to end. `selfContained` keeps this module out of
    // the extracted program — it imports Phobos and cannot compile under
    // -betterC — so the test must stand on its own, which is the property
    // being dogfooded.
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

/// `s` with line breaks flattened to spaces — safe inside a generated `// …`
/// comment, whose scope a raw newline in a test name would escape.
private string lineSafe(string s) @safe pure nothrow
{
    import std.array : replace;

    return s.replace("\n", " ").replace("\r", " ");
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
        source ~= format!"// %s\n#line %s %s\n%svoid test_%s()\n{%s}\n\n"(
            lineSafe(test.name), test.line, quotedStringLiteral(test.file),
            test.functionAttributes, i, test.body_);
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
    {
        import std.conv : text;

        // The announce string is a generated D literal: a quote or backslash
        // in a test name / source path must not break the program's compile.
        const announce = quotedStringLiteral(
            text(test.name, " [", test.file, ":", test.line, "]"));
        source ~= format!"    printf(\" > %%s\\n\", %s.ptr);\n"(announce)
            ~ format!"    fflush(null);\n    test_%s();\n"(i);
    }

    source ~= format!"\n    printf(\"%s @betterC tests passed\\n\");\n    return 0;\n}\n"(
        tests.length);
    return source;
}

@("extract.generateBetterCProgram.escapesNamesAndPaths")
@safe pure
unittest
{
    import std.algorithm.searching : canFind;

    const t = ExtractedTest(
        name: `quote " and \ backslash`,
        moduleName: "m",
        file: `dir\file.d`,
        line: 3,
        functionAttributes: "",
        body_: " int x = 1; ",
    );
    const prog = generateBetterCProgram([t]);
    // The announce literal and the #line path both escape `"` and `\`.
    assert(prog.canFind(`quote \" and \\ backslash`));
    assert(prog.canFind(`#line 3 "dir\\file.d"`));
    assert(!prog.canFind(`"dir\file.d"`));
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

// ─────────────────────────────────────────────────────────────────────────────
// @ctfe probe generation
// ─────────────────────────────────────────────────────────────────────────────

/// One `@ctfe` test to force through CTFE in a generated probe program.
struct CtfeTarget
{
    string moduleName; /// the test's module (aggregate qualifiers stripped)
    string file; /// the module's source file, as recorded at discovery
    size_t line; /// `__traits(getLocation)` line of the unittest block
    string name; /// display name
}

/// A complete probe program forcing the given `@ctfe` tests through CTFE.
///
/// The probe imports each test's module and selects the tests $(I by
/// reflection) (matching `__traits(getLocation)` lines), so test bodies stay
/// in their home modules — private symbols keep working and no source
/// extraction is involved. It is meant to be compiled with `-o- -unittest`
/// together with the modules' source files: semantic analysis (and therefore
/// CTFE) only, no code generation. A failing test is a compile error whose
/// closing `error instantiating` line carries the test's display name.
string generateCtfeProgram(in CtfeTarget[] targets) @safe pure
{
    import std.algorithm.iteration : filter, map, uniq;
    import std.algorithm.sorting : sort;
    import std.array : array, join;
    import std.conv : text;

    auto modules = targets.map!(t => t.moduleName[0 .. $]).array.sort.uniq.array;

    string source = q{// Generated by sparkles:test-runner; do not edit.
// Forces the selected @ctfe unittests through CTFE. Compiled with
// `-o- -unittest` (semantic analysis only), so a failing test is a compile
// error and nothing is ever codegen'd or linked.
module sparkles_test_runner_ctfe;

private alias AliasSeq(A...) = A;

// Mirrors sparkles.test_runner.discovery.moduleUnitTests: module-level
// unittests plus ones nested in structs and classes.
private template moduleUnitTests(alias module_)
{
    private template memberUnitTests(string member)
    {
        static if (__traits(compiles, __traits(getMember, module_, member)) &&
            __traits(compiles, __traits(isTemplate, __traits(getMember, module_, member))) &&
            !__traits(isTemplate, __traits(getMember, module_, member)) &&
            __traits(compiles, __traits(parent, __traits(getMember, module_, member))) &&
            __traits(isSame, __traits(parent, __traits(getMember, module_, member)), module_) &&
            __traits(compiles, __traits(getUnitTests, __traits(getMember, module_, member))))
        {
            alias memberUnitTests =
                AliasSeq!(__traits(getUnitTests, __traits(getMember, module_, member)));
        }
        else
            alias memberUnitTests = AliasSeq!();
    }

    private template mapMembers(members...)
    {
        static if (members.length == 0)
            alias mapMembers = AliasSeq!();
        else
            alias mapMembers =
                AliasSeq!(memberUnitTests!(members[0]), mapMembers!(members[1 .. $]));
    }

    alias moduleUnitTests = AliasSeq!(
        __traits(getUnitTests, module_),
        mapMembers!(__traits(derivedMembers, module_)));
}

// `displayName` makes the compiler's closing `error instantiating` line name
// the failing test; the runner parses it back out to attribute failures.
private template ctfePassed(alias test, string displayName)
{
    enum bool ctfePassed = { test(); return true; }();
}

private string selectedName(size_t line, const size_t[] lines, const string[] names)
{
    foreach (i, l; lines)
        if (l == line)
            return names[i];
    return null;
}
} ~ "\n";

    foreach (i, moduleName; modules)
    {
        auto selected = targets.filter!(t => t.moduleName == moduleName);
        source ~= text(
            "static import m", i, " = ", moduleName, ";\n",
            "private enum size_t[] lines", i, " = [",
            selected.map!(t => text(t.line)).join(", "), "];\n",
            "private enum string[] names", i, " = [",
            selected.map!(t => quotedStringLiteral(t.name)).join(", "), "];\n",
            "static foreach (test; moduleUnitTests!m", i, ")\n",
            "    static if (selectedName(__traits(getLocation, test)[1], ",
            "lines", i, ", names", i, ") !is null)\n",
            "        static assert(ctfePassed!(test,\n",
            "            selectedName(__traits(getLocation, test)[1], ",
            "lines", i, ", names", i, ")));\n\n");
    }
    return source;
}

@("generateCtfeProgram.shape")
@safe pure
unittest
{
    import std.algorithm.searching : canFind;

    const targets = [
        CtfeTarget(moduleName: "pkg.mod", file: "src/pkg/mod.d", line: 12, name: "demo.ct"),
        CtfeTarget(moduleName: "pkg.mod", file: "src/pkg/mod.d", line: 30, name: `quo"te`),
        CtfeTarget(moduleName: "pkg.other", file: "src/pkg/other.d", line: 5, name: "other.ct"),
    ];
    const program = generateCtfeProgram(targets);
    assert(program.canFind("static import m0 = pkg.mod;"));
    assert(program.canFind("static import m1 = pkg.other;"));
    assert(program.canFind("private enum size_t[] lines0 = [12, 30];"));
    assert(program.canFind(`private enum string[] names0 = ["demo.ct", "quo\"te"];`));
    assert(program.canFind("private enum string[] names1 = [\"other.ct\"];"));
    assert(program.canFind("static foreach (test; moduleUnitTests!m1)"));
    assert(program.canFind("enum bool ctfePassed = { test(); return true; }();"));
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
            "[", quotedStringLiteral(test.name), ", ",
            quotedStringLiteral(text(test.file, ':', test.line)), "]");
    names ~= "]";

    return "// Generated by sparkles:test-runner --wasm; do not edit.\n"
        ~ "const tests = " ~ names ~ ";\n"
        ~ "const load = async () => {\n"
        ~ "    const fs = await import('node:fs');\n"
        ~ "    const bytes = fs.readFileSync(" ~ quotedStringLiteral(wasmFile) ~ ");\n"
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
