/**
Grammar loading: dlopen a compiled grammar object, resolve its
`tree_sitter_<name>` entry point, and check the ABI window.

Mechanism only — search paths, caching, and language-name policy live in
`sparkles.syntax.ts.registry`. Posix-only for now: on other platforms
$(LREF loadGrammar) compiles and returns `unsupportedPlatform` (a
`LoadLibrary` branch can slot in without API change).

Loaded objects are deliberately $(B never `dlclose`d): queries and trees
keep pointers into the grammar's static tables for as long as the process
highlights (the same lifetime policy Helix uses).
*/
module sparkles.tree_sitter.loader;

import sparkles.base.smallbuffer : SmallBuffer;

import sparkles.tree_sitter.errors : TsError, TsErrorCode, TsExpected, tsErr, tsOk;
import sparkles.tree_sitter.tree_sitter_c : TSLanguage, ts_language_abi_version,
    TREE_SITTER_LANGUAGE_VERSION, TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION;

/// A loaded grammar: non-owning (the underlying object lives for the whole
/// process) — freely copyable.
struct Grammar
{
    const(TSLanguage)* language; /// the grammar's `TSLanguage`
    uint abiVersion;             /// its `ts_language_abi_version`
}

/**
Loads the grammar shared object at `soPath` and resolves
`tree_sitter_<symbolName>` (with `-` normalized to `_`:
`ocaml-interface` → `tree_sitter_ocaml_interface`).

Fails with `dlopenFailed`, `symbolNotFound`, or `incompatibleAbi` (the
observed ABI version in `detail`; accepted window
`[TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION, TREE_SITTER_LANGUAGE_VERSION]`
— the constants flow through ImportC, so they always match the linked
runtime).
*/
TsExpected!Grammar loadGrammar(scope const(char)[] soPath, scope const(char)[] symbolName) @trusted nothrow @nogc
{
    version (Posix)
    {
        import core.sys.posix.dlfcn : dlopen, dlsym, RTLD_LOCAL, RTLD_NOW;

        SmallBuffer!(char, 512) pathZ;
        pathZ ~= soPath;
        pathZ ~= '\0';

        void* handle = dlopen(pathZ[].ptr, RTLD_NOW | RTLD_LOCAL);
        if (handle is null)
            return tsErr!Grammar(TsErrorCode.dlopenFailed);

        SmallBuffer!(char, 128) symbolZ;
        symbolZ ~= "tree_sitter_";
        foreach (char c; symbolName)
            symbolZ ~= c == '-' ? '_' : c;
        symbolZ ~= '\0';

        auto symbol = dlsym(handle, symbolZ[].ptr);
        if (symbol is null)
            return tsErr!Grammar(TsErrorCode.symbolNotFound);

        alias LanguageFn = extern (C) const(TSLanguage)* function() nothrow @nogc;
        const language = (cast(LanguageFn) symbol)();
        if (language is null)
            return tsErr!Grammar(TsErrorCode.symbolNotFound);

        const abi = ts_language_abi_version(cast(TSLanguage*) language);
        if (abi < TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION
            || abi > TREE_SITTER_LANGUAGE_VERSION)
            return tsErr!Grammar(TsErrorCode.incompatibleAbi, abi);

        return tsOk(Grammar(language, abi));
    }
    else
    {
        return tsErr!Grammar(TsErrorCode.unsupportedPlatform);
    }
}

@("tree_sitter.loader.missingObject")
@system nothrow @nogc
unittest
{
    auto result = loadGrammar("/nonexistent/parser.so", "json");
    assert(result.hasError);
    version (Posix)
        assert(result.error.code == TsErrorCode.dlopenFailed);
    else
        assert(result.error.code == TsErrorCode.unsupportedPlatform);
}

version (unittest)
{
    /**
    Test helper: loads `lang` from the `$SPARKLES_TS_GRAMMAR_PATH` bundle, or
    skips the calling test when the bundle (or the grammar) is unavailable.
    */
    package Grammar loadGrammarForTest(string lang) @system
    {
        import std.file : exists;
        import std.path : buildPath;
        import std.process : environment;
        import sparkles.test_runner.skip : skipTest;

        const root = environment.get("SPARKLES_TS_GRAMMAR_PATH");
        if (root is null || root.length == 0)
            skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");
        const so = buildPath(root, lang, "parser");
        if (!so.exists)
            skipTest("grammar not in the bundle: " ~ lang);
        auto loaded = loadGrammar(so, lang);
        assert(!loaded.hasError);
        return loaded.value;
    }
}

@("tree_sitter.loader.jsonGrammar")
@system
unittest
{
    const grammar = loadGrammarForTest("json");
    assert(grammar.language !is null);
    assert(grammar.abiVersion >= TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION);
    assert(grammar.abiVersion <= TREE_SITTER_LANGUAGE_VERSION);
}
