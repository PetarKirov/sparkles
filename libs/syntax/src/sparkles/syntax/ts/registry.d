/**
Grammar discovery: the search-path registry and language-name normalization.

The directory convention (produced by the nix `ts-grammars` bundle): each
search-path entry contains `<lang>/parser` (the compiled grammar) and
`<lang>/queries/*.scm`. `$SPARKLES_TS_GRAMMAR_PATH` holds one or more such
directories (path-separator-separated; first hit wins, so a dev can shadow
one grammar ahead of the bundle).

Every lookup returns `TsExpected` — a missing grammar is an error value the
caller turns into the plain-text fallback, never a crash (the totality law).
*/
module sparkles.syntax.ts.registry;

import sparkles.tree_sitter.errors : TsError, TsErrorCode, TsExpected, tsErr, tsOk;
import sparkles.tree_sitter.loader : Grammar, loadGrammar;

/// See the module header.
struct GrammarRegistry
{
    private string[] _dirs;
    private Grammar[string] _cache;

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
    Reads `queries/<kind>.scm` for the language, from the same search-path
    entry that provides its `parser` (one consistent view per language).
    */
    TsExpected!string queryText(const(char)[] languageName,
        const(char)[] kind = "highlights") @safe
    {
        import std.file : exists, readText;
        import std.path : buildPath;

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
        case "c++", "cxx", "cc", "hpp", "hh", "h++": return "cpp";
        case "c#", "cs", "csharp": return "c-sharp";
        case "console", "sh", "shell", "zsh": return "bash";
        case "docker": return "dockerfile";
        case "dlang": return "d";
        case "golang": return "go";
        case "hs": return "haskell";
        case "htm": return "html";
        case "js", "mjs", "cjs", "node": return "javascript";
        case "kt", "kts": return "kotlin";
        case "md": return "markdown";
        case "ml", "mli": return "ocaml";
        case "py", "python3": return "python";
        case "rs": return "rust";
        case "ts": return "typescript";
        case "yml": return "yaml";
        default: return lowered.idup;
    }
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
    assert(canonicalLanguage("py") == "python");
    assert(canonicalLanguage("D") == "d");
    assert(canonicalLanguage("json") == "json");
    assert(canonicalLanguage("SomethingNew") == "somethingnew");
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
    import std.array : appender;
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

        auto sink = appender!(HighlightEvent[]);
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
