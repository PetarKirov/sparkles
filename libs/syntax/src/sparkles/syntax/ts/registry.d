/**
Grammar discovery: the search-path registry and language-name normalization.

Two layouts:
$(LIST
    * $(B Search path) (the desktop default, produced by the nix `ts-grammars`
        bundle): each entry contains `<lang>/parser` (the compiled grammar)
        and `<lang>/queries/*.scm`. `$SPARKLES_TS_GRAMMAR_PATH` holds one or
        more such directories (path-separator-separated; first hit wins, so a
        dev can shadow one grammar ahead of the bundle).
    * $(B Sonames) (`fromSonames` — the Android APK): parsers are shipped as
        `libtree_sitter_<lang>.so` native libraries the dynamic linker
        resolves by bare soname (the app's linker namespace includes the
        APK's lib dir — no paths, no env vars), while `queries/` live under
        one plain directory of extracted assets.
)

Every lookup returns `TsExpected` — a missing grammar is an error value the
caller turns into the plain-text fallback, never a crash (the totality law).
*/
module sparkles.syntax.ts.registry;

import sparkles.tree_sitter.errors : TsError, TsErrorCode, TsExpected, tsErr, tsOk;
import sparkles.tree_sitter.loader : Grammar, loadGrammar;

/**
The Android APK soname of a grammar: `libtree_sitter_<lang>.so` with `-`
folded to `_` (matching the `tree_sitter_<lang_>` symbol convention; the nix
side names the shipped libraries identically).

Returns `""` for a name carrying anything outside `[a-z0-9_-]`, which the
caller maps to `grammarNotFound`. That guard is what keeps the layout's
premise true: the parser is resolved by $(I bare soname) through the app's
linker namespace, and `dlopen` switches to path resolution the moment a name
contains `/`. Language labels are not trusted input — a markdown fence's info
string reaches here verbatim, because `canonicalLanguage` passes unknown
labels through unchanged.
*/
string grammarSoname(scope const(char)[] languageName) @safe pure nothrow
{
    if (!isPlainLanguageName(languageName))
        return null;
    auto s = new char[](languageName.length);
    foreach (i, char c; languageName)
        s[i] = c == '-' ? '_' : c;
    return "libtree_sitter_" ~ s ~ ".so";
}

/// `true` for a non-empty name of `[a-z0-9_-]` only — the shape
/// `canonicalLanguage` produces, and the shape safe to splice into a soname
/// or a path component. Everything else is refused rather than sanitized:
/// a label that is not this is not a language this build ships.
bool isPlainLanguageName(scope const(char)[] name) @safe pure nothrow @nogc
{
    if (name.length == 0)
        return false;
    foreach (char c; name)
    {
        const ok = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
            || c == '_' || c == '-';
        if (!ok)
            return false;
    }
    return true;
}

///
@("ts.registry.isPlainLanguageName")
@safe pure nothrow @nogc
unittest
{
    assert(isPlainLanguageName("markdown-inline"));
    assert(isPlainLanguageName("c_sharp"));
    assert(!isPlainLanguageName(""));
    assert(!isPlainLanguageName("../etc"));
    assert(!isPlainLanguageName("a/b"));
    assert(!isPlainLanguageName("Uppercase"));
}

///
@("ts.registry.grammarSoname")
@safe pure nothrow
unittest
{
    assert(grammarSoname("d") == "libtree_sitter_d.so");
    assert(grammarSoname("c-sharp") == "libtree_sitter_c_sharp.so");
    assert(grammarSoname("markdown-inline") == "libtree_sitter_markdown_inline.so");

    // Anything that could turn a soname lookup into a path lookup, or name a
    // library the APK never shipped, is refused outright.
    assert(grammarSoname("../../../data/local/tmp/evil") is null);
    assert(grammarSoname("foo/bar") is null);
    assert(grammarSoname("foo.so") is null);
    assert(grammarSoname("") is null);
    // `canonicalLanguage` lowercases, so an uppercase label reaching here has
    // bypassed it — refuse rather than guess.
    assert(grammarSoname("D") is null);
}

/// See the module header.
struct GrammarRegistry
{
    private string[] _dirs;
    private Grammar[string] _cache;
    private bool _sonameLayout;

    /// Builds the registry from `$SPARKLES_TS_GRAMMAR_PATH`.
    static GrammarRegistry fromEnvironment() @safe
    {
        import std.process : environment;

        return fromSearchPath(environment.get("SPARKLES_TS_GRAMMAR_PATH", ""));
    }

    /// Builds the registry from a path-separator-separated directory list.
    static GrammarRegistry fromSearchPath(scope const(char)[] searchPath) @safe pure
    {
        import std.algorithm.iteration : filter, splitter;
        import std.array : array;
        import std.path : pathSeparator;

        const owned = searchPath.idup;
        return GrammarRegistry(owned.splitter(pathSeparator)
            .filter!(dir => dir.length != 0)
            .array);
    }

    /// Builds the registry from explicit directories.
    static GrammarRegistry fromDirs(string[] dirs) @safe pure nothrow @nogc
        => GrammarRegistry(dirs);

    /// Builds the soname-layout registry (the Android APK): parsers resolve
    /// by `dlopen(grammarSoname(lang))` through the dynamic linker;
    /// `queries/` live under `<queriesRoot>/<lang>/queries/`.
    static GrammarRegistry fromSonames(string queriesRoot) @safe pure nothrow
    {
        // Built field-by-field rather than as a literal: a literal has to pass
        // `_cache` positionally as a `null` placeholder, and silently changes
        // meaning if the fields are ever reordered.
        GrammarRegistry r = GrammarRegistry([queriesRoot]);
        r._sonameLayout = true;
        return r;
    }

    /// The search directories, in priority order.
    const(string)[] dirs() const @safe pure nothrow @nogc
        => _dirs;

    /**
    Loads (and caches) the grammar for `languageName` — first search-path
    hit wins. A present-but-broken grammar is an error, not a fall-through.
    Not thread-safe (batch use); grammars stay loaded for the process
    lifetime.
    */
    TsExpected!Grammar grammar(const(char)[] languageName) @safe
    {
        import std.file : exists;
        import std.path : buildPath;

        if (auto cached = languageName in _cache)
            return tsOk(*cached);

        if (_sonameLayout)
        {
            // A name `grammarSoname` refuses never reaches dlopen: it would
            // be a path, not a soname (see there). Same degrade as a missing
            // grammar.
            const soname = grammarSoname(languageName);
            if (soname.length == 0)
                return tsErr!Grammar(TsErrorCode.grammarNotFound);
            // No exists-gate (a bare soname is not a checkable path); the
            // dynamic linker's refusal IS the absence signal, so a failed
            // dlopen maps to the plain-text degrade, not an error surface.
            auto loaded = loadGrammar(soname, languageName);
            if (loaded.hasError && loaded.error.code == TsErrorCode.dlopenFailed)
                return tsErr!Grammar(TsErrorCode.grammarNotFound);
            if (!loaded.hasError)
                _cache[languageName.idup] = loaded.value;
            return loaded;
        }

        // Same guard as the soname branch, for the same reason: the language
        // name is document-controlled, and it is about to become a path
        // component. Only saved today by needing a file literally named
        // `parser` at the traversed location — not a property worth relying on.
        if (!isPlainLanguageName(languageName))
            return tsErr!Grammar(TsErrorCode.grammarNotFound);

        foreach (dir; _dirs)
        {
            const so = buildPath(dir, languageName, "parser");
            if (!so.exists)
                continue;
            auto loaded = loadGrammar(so, languageName);
            if (!loaded.hasError)
                _cache[languageName.idup] = loaded.value;
            return loaded;
        }
        return tsErr!Grammar(TsErrorCode.grammarNotFound);
    }

    /**
    Reads `queries/<kind>.scm` for the language — from the same search-path
    entry that provides its `parser` (one consistent view per language), or,
    in the soname layout, straight from `<queriesRoot>/<lang>/queries/` (the
    parser is a linker-resolved library there, not a checkable sibling).
    */
    TsExpected!string queryText(const(char)[] languageName,
        const(char)[] kind = "highlights") @safe
    {
        import std.file : exists, readText;
        import std.path : buildPath;

        if (_sonameLayout)
        {
            foreach (dir; _dirs)
            {
                const scm = buildPath(dir, languageName, "queries", kind ~ ".scm");
                if (scm.exists)
                    return tsOk(readText(scm));
            }
            return tsErr!string(TsErrorCode.queryFileMissing);
        }

        foreach (dir; _dirs)
        {
            const langDir = buildPath(dir, languageName);
            if (!buildPath(langDir, "parser").exists)
                continue;
            const scm = buildPath(langDir, "queries", kind ~ ".scm");
            if (!scm.exists)
                return tsErr!string(TsErrorCode.queryFileMissing);
            return tsOk(readText(scm));
        }
        return tsErr!string(TsErrorCode.grammarNotFound);
    }
}

/**
Normalizes a language label (markdown fence tag, file extension, common
alias) to the canonical grammar directory name: lowercases ASCII and folds
known aliases (`ts` → `typescript`, `c++` → `cpp`, …). Unknown labels pass
through lowercased — the registry lookup then decides.
*/
string canonicalLanguage(scope const(char)[] label) @safe pure nothrow
{
    auto lowered = new char[](label.length);
    foreach (i, char c; label)
        lowered[i] = c >= 'A' && c <= 'Z' ? cast(char)(c + ('a' - 'A')) : c;

    switch (lowered)
    {
        case "adb", "ads": return "ada";
        case "s": return "asm";
        case "c++", "cxx", "cc", "hpp", "hh", "h++": return "cpp";
        case "h": return "c";
        case "c#", "cs", "csharp": return "c-sharp";
        case "console", "sh", "shell", "zsh": return "bash";
        case "docker", "containerfile": return "dockerfile";
        case "dlang": return "d";
        case "ex", "exs": return "elixir";
        case "fsi", "fsx", "f#": return "fsharp";
        case "golang": return "go";
        case "mod": return "gomod";
        case "work": return "gowork";
        case "hs": return "haskell";
        case "htm": return "html";
        case "jl": return "julia";
        case "js", "mjs", "cjs", "node", "jsx": return "javascript";
        case "justfile": return "just";
        case "kk": return "koka";
        case "kt", "kts": return "kotlin";
        case "ll": return "llvm";
        case "makefile", "gnumakefile", "mk": return "make";
        case "md": return "markdown";
        case "markdown_inline", "markdown-inline", "markdown.inline": return "markdown-inline";
        case "libsonnet": return "jsonnet";
        case "ml", "mli": return "ocaml";
        case "ps1", "psm1", "psd1": return "powershell";
        case "py", "python3": return "python";
        case "bzl", "bazel": return "starlark";
        case "qml": return "qmljs";
        case "rb", "gemfile", "rakefile": return "ruby";
        case "rs": return "rust";
        case "rkt": return "racket";
        case "scm", "ss", "sls": return "scheme";
        case "sdlang": return "sdl";
        // The only approximations left: Eff and Frank are ML-family research
        // languages nobody has written a tree-sitter grammar for, so they point
        // at the closest surface syntax. Anything that *has* a grammar gets it
        // (`nix/packages/ts-grammar-languages.nix` `fetched`, plus the in-house
        // ones) — which is why racket, objc, starlark, unison, asm and now
        // SDLang are no longer on this list. `sdl` used to fold onto `d`; the
        // repo maintains a real SDLang grammar (nix/packages/tree-sitter-sdl.nix),
        // so folding it away would shadow the better parser.
        case "eff", "frank": return "ocaml";
        case "nims": return "nim";
        case "ts", "mts", "cts": return "typescript";
        case "typ": return "typst";
        // XAML *is* XML — same parser, richer vocabulary.
        case "xaml": return "xml";
        case "yml": return "yaml";
        default: return lowered.idup;
    }
}

/**
The grammar language for a file $(I path): its extension, canonicalized as
above, falling back to the whole base name when there is none — so
`Makefile` → `make`, `Dockerfile` → `dockerfile` and `Justfile` → `just`
resolve exactly like an extension would, without a second alias table.

A base name that no alias claims passes through lowercased (`LICENSE` →
`license`), which the registry then reports as "no grammar" and the caller
renders as plain text (the totality law).
*/
string canonicalLanguageOfPath(scope const(char)[] path) @safe pure nothrow
{
    import std.path : baseName, extension;
    import std.string : chompPrefix;

    const base = path.baseName;
    const ext = base.extension;
    return canonicalLanguage(ext.length ? ext.chompPrefix(".") : base);
}

///
@("ts.registry.canonicalLanguageOfPath")
@safe pure nothrow
unittest
{
    assert(canonicalLanguageOfPath("src/app.d") == "d");
    assert(canonicalLanguageOfPath("libs/base/dub.sdl") == "d");
    assert(canonicalLanguageOfPath("/tmp/vec.h") == "c");

    // Extensionless files resolve through their base name.
    assert(canonicalLanguageOfPath("Makefile") == "make");
    assert(canonicalLanguageOfPath("build/GNUmakefile") == "make");
    assert(canonicalLanguageOfPath("Dockerfile") == "dockerfile");
    assert(canonicalLanguageOfPath("Justfile") == "just");

    // Multi-part names still resolve on the extension.
    assert(canonicalLanguageOfPath("go.mod") == "gomod");
    assert(canonicalLanguageOfPath("go.work") == "gowork");

    // Unclaimed names pass through for the plain-text fallback.
    assert(canonicalLanguageOfPath("LICENSE") == "license");
    assert(canonicalLanguageOfPath("notes.txt") == "txt");

    // A dotfile is a base name, not an extension (std.path's rule).
    assert(canonicalLanguageOfPath(".gitignore") == ".gitignore");
}

/**
`true` for a label that asks for $(I no) highlighting: `text` and its
spellings, plus `ansi`, whose fences are decoded by the off-screen VT rather
than a grammar. Plain text is the correct output for these, so a caller must
not report the missing grammar as a degradation (`DEG1`: normal operation is
silent).
*/
bool isPlainTextLabel(scope const(char)[] canonicalLabel) @safe pure nothrow @nogc
{
    switch (canonicalLabel)
    {
        case "", "text", "txt", "plain", "plaintext", "none", "ansi":
            return true;
        default:
            return false;
    }
}

///
@("ts.registry.isPlainTextLabel")
@safe pure nothrow @nogc
unittest
{
    assert(isPlainTextLabel("text"));
    assert(isPlainTextLabel("txt"));
    assert(isPlainTextLabel("ansi"));
    assert(isPlainTextLabel(""));
    assert(!isPlainTextLabel("d"));
    assert(!isPlainTextLabel("license"));
}

///
@("ts.registry.canonicalLanguage")
@safe pure nothrow
unittest
{
    assert(canonicalLanguage("ts") == "typescript");
    assert(canonicalLanguage("TS") == "typescript");
    assert(canonicalLanguage("C++") == "cpp");
    assert(canonicalLanguage("c#") == "c-sharp");
    assert(canonicalLanguage("console") == "bash");
    assert(canonicalLanguage("md") == "markdown");
    assert(canonicalLanguage("markdown_inline") == "markdown-inline"); // injection #set! value
    assert(canonicalLanguage("py") == "python");
    assert(canonicalLanguage("D") == "d");
    assert(canonicalLanguage("sdlang") == "sdl");
    assert(canonicalLanguage("sdl") == "sdl"); // the `.sdl` extension needs no alias
    assert(canonicalLanguage("json") == "json");
    assert(canonicalLanguage("SomethingNew") == "somethingnew");

    // Extension folds that reach a grammar under a different name.
    assert(canonicalLanguage("h") == "c");              // plain C header
    assert(canonicalLanguage("hpp") == "cpp");          // …unlike a C++ one
    assert(canonicalLanguage("jsx") == "javascript");   // one grammar, both dialects
    assert(canonicalLanguage("asm") == "asm");   // a real grammar, not folded
    assert(canonicalLanguage("Makefile") == "make");
    assert(canonicalLanguage("work") == "gowork");
    assert(canonicalLanguage("qml") == "qmljs");        // nixpkgs attribute spelling
    assert(canonicalLanguage("xaml") == "xml");
    assert(canonicalLanguage("bzl") == "starlark");

    // Languages that got a real grammar instead of an approximating fold.
    assert(canonicalLanguage("racket") == "racket");
    assert(canonicalLanguage("unison") == "unison");
    assert(canonicalLanguage("objc") == "objc");
    assert(canonicalLanguage("rkt") == "racket");

    // The only approximations left: no grammar for these exists anywhere.
    assert(canonicalLanguage("sdl") == "d");
    assert(canonicalLanguage("eff") == "ocaml");

    // Labels with no grammar stay themselves; the registry reports the miss
    // and the caller renders plain text.
    assert(canonicalLanguage("wat") == "wat");
    assert(canonicalLanguage("text") == "text");
}

@("ts.registry.missingGrammar")
@safe
unittest
{
    auto registry = GrammarRegistry.fromDirs(["/nonexistent-dir"]);
    auto result = registry.grammar("json");
    assert(result.hasError);
    assert(result.error.code == TsErrorCode.grammarNotFound);

    auto query = registry.queryText("json");
    assert(query.hasError);
    assert(query.error.code == TsErrorCode.grammarNotFound);
}

@("ts.registry.sonameLayout")
@system
unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;

    const root = buildPath(tempDir, "sparkles-soname-registry-test");
    mkdirRecurse(buildPath(root, "json", "queries"));
    scope (exit) rmdirRecurse(root);
    write(buildPath(root, "json", "queries", "highlights.scm"), "(pair) @x");

    auto registry = GrammarRegistry.fromSonames(root);

    // Queries read straight from the extracted tree — no parser sibling gate.
    auto q = registry.queryText("json");
    assert(!q.hasError && q.value == "(pair) @x");
    assert(registry.queryText("json", "locals").error.code
        == TsErrorCode.queryFileMissing);
    assert(registry.queryText("nonexistent").error.code
        == TsErrorCode.queryFileMissing);

    // A soname the dynamic linker refuses is the plain-text degrade, not an
    // error surface.
    version (Posix)
        assert(registry.grammar("nonexistent").error.code
            == TsErrorCode.grammarNotFound);
}

@("ts.registry.searchPathSplitting")
@safe pure
unittest
{
    import std.path : pathSeparator;

    const registry = GrammarRegistry.fromSearchPath(
        "/a" ~ pathSeparator ~ "" ~ pathSeparator ~ "/b");
    assert(registry.dirs == ["/a", "/b"]);
    assert(GrammarRegistry.fromSearchPath("").dirs.length == 0);
}

@("ts.registry.bundleLookup")
@system
unittest
{
    import std.process : environment;
    import sparkles.test_runner.skip : skipTest;

    if (environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length == 0)
        skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    auto registry = GrammarRegistry.fromEnvironment();
    auto grammar = registry.grammar("json");
    assert(!grammar.hasError);
    assert(grammar.value.language !is null);

    // cached second lookup returns the same language pointer
    assert(registry.grammar("json").value.language is grammar.value.language);

    auto highlights = registry.queryText("json");
    assert(!highlights.hasError);
    assert(highlights.value.length > 0);

    auto missingKind = registry.queryText("json", "locals");
    assert(missingKind.hasError);
    assert(missingKind.error.code == TsErrorCode.queryFileMissing);
}

@("ts.registry.bundleSmoke")
@system
unittest
{
    // The query-dialect canary: every bundled language must load, compile
    // its shipped highlights.scm, and highlight a small snippet — producing
    // a well-formed event stream. Unsupported dialect predicates may disable
    // individual patterns (warnings), but never the language.
    import std.process : environment;
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.test_runner.skip : skipTest;
    import sparkles.syntax.event : HighlightEvent;
    import sparkles.syntax.label : LabelSet;
    import sparkles.syntax.ts.config : TsHighlightConfig;
    import sparkles.syntax.ts.highlighter : highlight;

    if (environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length == 0)
        skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    static immutable string[2][] snippets = [
        ["bash", "echo \"hi $USER\" | wc -l\n"],
        ["c", "int main(void) { return 0; } // c\n"],
        ["c-sharp", "class C { static int Main() => 0; }\n"],
        ["cpp", "template <class T> T id(T x) { return x; }\n"],
        ["css", ".a { color: #fff; }\n"],
        ["d", "void main() @safe { import std; writeln(1 + 2); }\n"],
        ["go", "package main\nfunc main() { println(1) }\n"],
        ["haskell", "main :: IO ()\nmain = putStrLn \"hi\"\n"],
        ["html", "<html><body class=\"x\">hi</body></html>\n"],
        ["java", "class A { public static void main(String[] a) {} }\n"],
        ["javascript", "const f = (x) => x * 2; // js\n"],
        ["json", "{\"a\": [1, true, null]}\n"],
        ["kotlin", "fun main() { println(\"hi\") }\n"],
        ["markdown", "# Title\n\n- item `code`\n"],
        ["nix", "{ pkgs ? null }: { a = 1; }\n"],
        ["ocaml", "let () = print_endline \"hi\"\n"],
        ["python", "def f(x: int) -> int:\n    return x * 2\n"],
        ["rust", "fn main() { println!(\"hi\"); }\n"],
        ["scala", "object A { def main(a: Array[String]): Unit = () }\n"],
        ["sdl", "name \"sparkles\" // sdl\ndeps {\n    lib version=\"1.0\"\n}\n"],
        ["toml", "[a]\nb = 1\n"],
        ["typescript", "const f = (x: number): number => x * 2;\n"],
        ["tsx", "const a = <div className=\"x\">hi</div>;\n"],
        ["xml", "<?xml version=\"1.0\"?><a b=\"c\">d</a>\n"],
        ["yaml", "a: 1\nb: [x, y]\n"],
        ["zig", "pub fn main() void {}\n"],
    ];

    auto registry = GrammarRegistry.fromEnvironment();
    const labels = LabelSet.standard();

    foreach (pair; snippets)
    {
        const lang = pair[0];
        const source = pair[1];

        auto grammar = registry.grammar(lang);
        assert(!grammar.hasError, lang);
        auto queryText = registry.queryText(lang);
        assert(!queryText.hasError, lang);

        TsError error;
        auto config = TsHighlightConfig.create(grammar.value, queryText.value, error);
        assert(!error, lang);
        config.configure(labels);

        SmallBuffer!HighlightEvent sink;
        auto result = highlight(config, source, sink);
        assert(!result.hasError, lang);

        // well-formedness: balanced pushes/pops, full coverage
        size_t depth, offset;
        foreach (ev; sink[])
        {
            final switch (ev.kind)
            {
                case HighlightEvent.Kind.source:
                    assert(ev.start == offset && ev.end <= source.length, lang);
                    offset = ev.end;
                    break;
                case HighlightEvent.Kind.push:
                    ++depth;
                    break;
                case HighlightEvent.Kind.pop:
                    assert(depth > 0, lang);
                    --depth;
                    break;
            }
        }
        assert(depth == 0 && offset == source.length, lang);
    }
}
