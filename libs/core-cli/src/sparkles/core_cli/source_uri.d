/// Source URI generation for OSC 8 hyperlinks.
///
/// Provides path resolution, editor-specific URI schemes, and a hook interface
/// for compile-time-configurable source location links. Uses Design by
/// Introspection to let callers plug in custom URI writers.
module sparkles.core_cli.source_uri;

import std.conv : text;

// ─────────────────────────────────────────────────────────────────────────────
// Path Resolution
// ─────────────────────────────────────────────────────────────────────────────

/// Resolves a compiler-relative source path to an absolute path.
///
/// Uses `__FILE_FULL_PATH__` and `__FILE__` from the call site to derive
/// the compiler's working directory, then resolves `path` against it.
/// Works at compile time (CTFE) and at runtime.
string resolveSourcePath(
    string path,
    string fullPath = __FILE_FULL_PATH__,
    string relPath = __FILE__,
) @safe pure
{
    import std.path : absolutePath;

    // Already absolute — return as-is
    if (path.length > 0 && path[0] == '/')
        return path;

    // Derive compiler working directory: strip relative suffix from full path
    string base = fullPath[0 .. $ - relPath.length];
    return absolutePath(path, base);
}

// ─────────────────────────────────────────────────────────────────────────────
// Editor Scheme Table
// ─────────────────────────────────────────────────────────────────────────────

struct EditorScheme
{
    string name;
    string function(string, size_t, size_t) pure @safe uriFun;
    immutable(string)[] aliases;
}

// ── URI format functions (IES-based, CTFE-evaluable) ────────────────────

private @safe pure
{

string fileUri(string path, size_t line, size_t col) =>
    i"file://$(path)#L$(line)".text;

string vsCodeUri(string path, size_t line, size_t col) =>
    i"vscode://file$(path):$(line):$(col)".text;

string vsCodeInsidersUri(string path, size_t line, size_t col) =>
    i"vscode-insiders://file$(path):$(line):$(col)".text;

string cursorUri(string path, size_t line, size_t col) =>
    i"cursor://file$(path):$(line):$(col)".text;

string zedUri(string path, size_t line, size_t col) =>
    i"zed://file$(path):$(line):$(col)".text;

string jetBrainsUri(string path, size_t line, size_t col) =>
    i"jetbrains://open?file=$(path)&line=$(line)&column=$(col)".text;

string sublimeUri(string path, size_t line, size_t col) =>
    i"subl://open?url=file://$(path)&line=$(line)&column=$(col)".text;

string emacsUri(string path, size_t line, size_t col) =>
    i"org-protocol://open-file?url=file://$(path)&line=$(line)&column=$(col)".text;

string atomUri(string path, size_t line, size_t col) =>
    i"atom://core/open/file?filename=$(path)&line=$(line)&column=$(col)".text;

string lapceUri(string path, size_t line, size_t col) =>
    i"lapce://open?path=$(path)&line=$(line)&column=$(col)".text;

}

// ── Declarative scheme table ────────────────────────────────────────────

enum editorSchemes = [
    EditorScheme("VS Code",          &vsCodeUri,          ["code"]),
    EditorScheme("VS Code Insiders", &vsCodeInsidersUri,  ["code-insiders"]),
    EditorScheme("Cursor",           &cursorUri,          ["cursor"]),
    EditorScheme("Zed",              &zedUri,             ["zed"]),
    EditorScheme("IntelliJ IDEA",    &jetBrainsUri,       ["idea"]),
    EditorScheme("GoLand",           &jetBrainsUri,       ["goland"]),
    EditorScheme("CLion",            &jetBrainsUri,       ["clion"]),
    EditorScheme("PyCharm",          &jetBrainsUri,       ["pycharm"]),
    EditorScheme("RustRover",        &jetBrainsUri,       ["rustrover"]),
    EditorScheme("WebStorm",         &jetBrainsUri,       ["webstorm"]),
    EditorScheme("Sublime Text",     &sublimeUri,         ["subl", "sublime_text"]),
    EditorScheme("Emacs",            &emacsUri,           ["emacs", "emacsclient"]),
    EditorScheme("Atom",             &atomUri,            ["atom"]),
    EditorScheme("Lapce",            &lapceUri,           ["lapce"]),
    // Terminal editors — no custom URI scheme, fall back to file://
    EditorScheme("Helix",            &fileUri,            ["helix", "hx"]),
    EditorScheme("Neovim",           &fileUri,            ["nvim"]),
    EditorScheme("Vim",              &fileUri,            ["vim", "vi"]),
    EditorScheme("nano",             &fileUri,            ["nano"]),
    EditorScheme("micro",            &fileUri,            ["micro"]),
    EditorScheme("Kakoune",          &fileUri,            ["kak"]),
];

// ─────────────────────────────────────────────────────────────────────────────
// Hook Interface and Capability Trait
// ─────────────────────────────────────────────────────────────────────────────

/// Hook protocol (optional primitive):
///   `static void writeSourceUri(string path, size_t line, size_t col, Writer)(ref Writer w)`
///
/// `path`, `line`, `col` are compile-time values from `__traits(getLocation, T)`.
template hasWriteSourceUri(Hook, Writer)
{
    enum bool hasWriteSourceUri = __traits(compiles, {
        Writer w = Writer.init;
        Hook.writeSourceUri!("/path", size_t(1), size_t(1))(w);
    });
}

// ─────────────────────────────────────────────────────────────────────────────
// Hook Types
// ─────────────────────────────────────────────────────────────────────────────

/// Default fallback hook — produces `file://` URIs.
struct FileUriHook
{
    static void writeSourceUri(string path, size_t line, size_t col, Writer)(ref Writer w)
    {
        import std.range.primitives : put;
        enum uri = fileUri(path, line, col);  // CTFE
        put(w, uri);
    }
}

/// Compile-time hook for a specific editor, looked up by alias from the
/// declarative table.
///
/// Usage: `PrettyPrintOptions!(SchemeHook!"code")(useOscLinks: true)`
template SchemeHook(string editorAlias)
{
    struct SchemeHook
    {
        static void writeSourceUri(string path, size_t line, size_t col, Writer)(ref Writer w)
        {
            import std.range.primitives : put;
            enum uri = findScheme(editorAlias).uriFun(path, line, col);  // CTFE
            put(w, uri);
        }
    }
}

/// Runtime auto-detection from `$VISUAL`/`$EDITOR`.
///
/// Uses `static foreach` over `editorSchemes` to generate `switch` cases.
/// Each case branch pre-computes its URI at CTFE — fully @nogc runtime writes.
struct EditorDetectHook
{
    static void writeSourceUri(string path, size_t line, size_t col, Writer)(ref Writer w)
    {
        import std.range.primitives : put;

        immutable editor = editorName();  // runtime: lazy-cached

        // Generated from declarative table — each URI is CTFE-computed
        switch (editor)
        {
            static foreach (scheme; editorSchemes)
            {
                static foreach (a; scheme.aliases)
                    case a:
                {
                    enum uri = scheme.uriFun(path, line, col);  // CTFE!
                    put(w, uri);                                 // @nogc
                    return;
                }
            }
            default:
            {
                enum uri = fileUri(path, line, col);  // CTFE fallback
                put(w, uri);
                return;
            }
        }
    }

    private static string editorName()
    {
        // Thread-local lazy cache
        static string cached = null;
        if (cached is null)
        {
            import std.path : baseName;
            import std.process : environment;
            cached = environment.get("VISUAL", environment.get("EDITOR", "")).baseName;
        }
        return cached;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal Helpers
// ─────────────────────────────────────────────────────────────────────────────

private EditorScheme findScheme(string editorAlias) pure
{
    foreach (scheme; editorSchemes)
        foreach (a; scheme.aliases)
            if (a == editorAlias)
                return scheme;
    return EditorScheme("Default", &fileUri, []);
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit Tests
// ─────────────────────────────────────────────────────────────────────────────

/// resolveSourcePath returns absolute paths unchanged.
@("sourceUri.resolveSourcePath.absolute")
@safe pure
unittest
{
    assert(resolveSourcePath("/usr/local/src/main.d") == "/usr/local/src/main.d");
}

/// resolveSourcePath resolves relative paths against compiler CWD.
@("sourceUri.resolveSourcePath.relative")
@safe pure
unittest
{
    enum resolved = resolveSourcePath(
        "libs/core-cli/src/sparkles/core_cli/source_uri.d");
    // Must be absolute
    assert(resolved.length > 0 && resolved[0] == '/');
    // Must end with the relative path
    assert(resolved.length > 48
        && resolved[$ - 48 .. $] == "libs/core-cli/src/sparkles/core_cli/source_uri.d");
}

/// resolveSourcePath works at compile time.
@("sourceUri.resolveSourcePath.ctfe")
@safe pure
unittest
{
    enum absPath = resolveSourcePath("/already/absolute");
    static assert(absPath == "/already/absolute");

    enum relPath = resolveSourcePath("libs/core-cli/src/sparkles/core_cli/source_uri.d");
    static assert(relPath.length > 0 && relPath[0] == '/');
}

/// FileUriHook produces file:// URIs.
@("sourceUri.FileUriHook.writeSourceUri")
@safe pure
unittest
{
    import std.array : appender;
    auto w = appender!string;
    FileUriHook.writeSourceUri!("/home/user/project/main.d", size_t(42), size_t(5))(w);
    assert(w[] == "file:///home/user/project/main.d#L42");
}

/// SchemeHook!"code" produces vscode:// URIs.
@("sourceUri.SchemeHook.writeSourceUri")
@safe pure
unittest
{
    import std.array : appender;
    auto w = appender!string;
    SchemeHook!"code".writeSourceUri!("/home/user/project/main.d", size_t(10), size_t(3))(w);
    assert(w[] == "vscode://file/home/user/project/main.d:10:3");
}

/// CTFE evaluation of uriFun from the table.
@("sourceUri.editorSchemes.ctfeUri")
@safe pure
unittest
{
    // Verify a few schemes evaluate at CTFE
    enum vsCode = editorSchemes[0].uriFun("/path/to/file.d", 1, 1);
    static assert(vsCode == "vscode://file/path/to/file.d:1:1");

    enum jetBrains = findScheme("idea").uriFun("/src/main.d", 10, 5);
    static assert(jetBrains == "jetbrains://open?file=/src/main.d&line=10&column=5");
}

/// hasWriteSourceUri detects hooks with the protocol.
@("sourceUri.hasWriteSourceUri.positive")
@safe pure
unittest
{
    import std.array : Appender;
    static assert(hasWriteSourceUri!(FileUriHook, Appender!string));
    static assert(hasWriteSourceUri!(SchemeHook!"code", Appender!string));
}

/// hasWriteSourceUri returns false for void and hookless types.
@("sourceUri.hasWriteSourceUri.negative")
@safe pure
unittest
{
    import std.array : Appender;
    static assert(!hasWriteSourceUri!(void, Appender!string));
    static assert(!hasWriteSourceUri!(int, Appender!string));
}
