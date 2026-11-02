/// Source URI generation for OSC 8 hyperlinks.
///
/// Provides path resolution, editor-specific URI schemes, and a hook interface
/// for compile-time-configurable source location links. Uses Design by
/// Introspection to let callers plug in custom URI writers.
module sparkles.base.source_uri;

// ─────────────────────────────────────────────────────────────────────────────
// Path Resolution
// ─────────────────────────────────────────────────────────────────────────────

/// Resolves a compiler-relative source path against the compiler's working
/// directory.
///
/// Uses `__FILE_FULL_PATH__` and `__FILE__` from the call site to derive
/// the compiler's working directory, then resolves `path` against it.
/// Works at compile time (CTFE) and at runtime.
///
/// The result is absolute when the build recorded absolute paths. A relocated
/// build (`--ffile-prefix-map=<root>=.`) records them relative to the
/// repository root, and so is the result; `absoluteSourcePath` completes it.
string resolveSourcePath(
    string path,
    string fullPath = __FILE_FULL_PATH__,
    string relPath = __FILE__,
) @safe pure
{
    // Already absolute — return as-is
    if (path.length > 0 && (path[0] == '/' || path[0] == '\\' || (path.length > 1 && path[1] == ':')))
        return path;

    // Derive compiler working directory: strip relative suffix from full path
    if (fullPath.length >= relPath.length)
    {
        string base = fullPath[0 .. $ - relPath.length];
        // `__FILE__` is as full as `__FILE_FULL_PATH__`: nothing to add
        if (!base.length)
            return path;
        if (base[$ - 1] == '/' || base[$ - 1] == '\\')
            return base ~ path;
        return base ~ '/' ~ path;
    }
    return path;
}

/// The absolute form of a path `resolveSourcePath` returned.
///
/// A relative path, as a relocated build records it, is completed with the
/// process's working directory, which that build's test actions set to the
/// repository root. An absolute path is returned unchanged.
string absoluteSourcePath(string path) @safe pure nothrow
{
    import std.path : isAbsolute;

    if (path.isAbsolute)
        return path;
    return (workingDirectory ~ "/" ~ withoutDotPrefix(path)).idup;
}

/// The process's working directory, read once per thread.
///
/// Pure in the way `pureMalloc` is: it reads process state that a relocated
/// build's test actions keep fixed. Empty if it cannot be read.
package const(char)[] workingDirectory() @trusted pure nothrow @nogc
    => (cast(const(char)[] function() @safe pure nothrow @nogc) &readWorkingDirectory)();

private const(char)[] readWorkingDirectory() @trusted nothrow @nogc
{
    static char[4096] buffer;
    static size_t length;
    if (!length)
    {
        version (Posix)
        {
            import core.stdc.string : strlen;
            import core.sys.posix.unistd : getcwd;

            if (getcwd(buffer.ptr, buffer.length))
                length = strlen(buffer.ptr);
        }
        else version (Windows)
        {
            import core.sys.windows.winbase : GetCurrentDirectoryA;

            length = GetCurrentDirectoryA(cast(uint) buffer.length, buffer.ptr);
            if (length >= buffer.length)
                length = 0;
        }
    }
    return buffer[0 .. length];
}

/// `path` without its leading `./` components.
private inout(char)[] withoutDotPrefix(inout(char)[] path) @safe pure nothrow @nogc
{
    while (path.length > 2 && path[0] == '.' && (path[1] == '/' || path[1] == '\\'))
        path = path[2 .. $];
    return path;
}

// ─────────────────────────────────────────────────────────────────────────────
// Editor Scheme Table
// ─────────────────────────────────────────────────────────────────────────────

struct EditorScheme
{
    string name;
    string function(string, size_t, size_t) @safe pure uriFun;
    immutable(string)[] aliases;
}

// ── URI format functions (IES-based, CTFE-evaluable) ────────────────────

private string fileUri(string path, size_t line, size_t col) @safe pure
{
    import std.conv : text;
    return i"file://$(path)#L$(line)".text;
}

private string vsCodeUri(string path, size_t line, size_t col) @safe pure
{
    import std.conv : text;
    return i"vscode://file$(path):$(line):$(col)".text;
}

private string vsCodeInsidersUri(string path, size_t line, size_t col) @safe pure
{
    import std.conv : text;
    return i"vscode-insiders://file$(path):$(line):$(col)".text;
}

private string cursorUri(string path, size_t line, size_t col) @safe pure
{
    import std.conv : text;
    return i"cursor://file$(path):$(line):$(col)".text;
}

private string zedUri(string path, size_t line, size_t col) @safe pure
{
    import std.conv : text;
    return i"zed://file$(path):$(line):$(col)".text;
}

private string jetBrainsUri(string path, size_t line, size_t col) @safe pure
{
    import std.conv : text;
    return i"jetbrains://open?file=$(path)&line=$(line)&column=$(col)".text;
}

private string sublimeUri(string path, size_t line, size_t col) @safe pure
{
    import std.conv : text;
    return i"subl://open?url=file://$(path)&line=$(line)&column=$(col)".text;
}

private string emacsUri(string path, size_t line, size_t col) @safe pure
{
    import std.conv : text;
    return i"org-protocol://open-file?url=file://$(path)&line=$(line)&column=$(col)".text;
}

private string atomUri(string path, size_t line, size_t col) @safe pure
{
    import std.conv : text;
    return i"atom://core/open/file?filename=$(path)&line=$(line)&column=$(col)".text;
}

private string lapceUri(string path, size_t line, size_t col) @safe pure
{
    import std.conv : text;
    return i"lapce://open?path=$(path)&line=$(line)&column=$(col)".text;
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

/// Writes the URI `editorAlias`'s scheme gives a compile-time location.
///
/// An absolute `path` gives a URI computed at compile time. A relative one,
/// as a relocated build records it, is completed at run time with the
/// working directory (see `absoluteSourcePath`), around the scheme's
/// compile-time prefix and suffix.
private void writeLocationUri(string editorAlias, string path, size_t line, size_t col, Writer)(
    ref Writer w)
{
    import std.path : isAbsolute;
    import std.range.primitives : put;

    static if (path.isAbsolute)
    {
        enum uri = findScheme(editorAlias).uriFun(path, line, col);  // CTFE
        put(w, uri);
    }
    else
    {
        import std.string : indexOf;

        enum marker = "\x00";
        enum shape = findScheme(editorAlias).uriFun(marker, line, col);  // CTFE
        enum at = shape.indexOf(marker);
        static assert(at >= 0, "a URI scheme must contain the path");
        enum prefix = shape[0 .. at];
        enum suffix = shape[at + marker.length .. $];
        enum relative = withoutDotPrefix(path);
        put(w, prefix);
        if (!__ctfe)
        {
            put(w, workingDirectory);
            put(w, "/");
        }
        put(w, relative);
        put(w, suffix);
    }
}

/// Default fallback hook — produces `file://` URIs.
struct FileUriHook
{
    static void writeSourceUri(string path, size_t line, size_t col, Writer)(ref Writer w)
        => writeLocationUri!("", path, line, col)(w);
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
            => writeLocationUri!(editorAlias, path, line, col)(w);
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
        immutable editor = editorName();  // runtime: lazy-cached

        // Generated from declarative table — each URI is CTFE-computed
        switch (editor)
        {
            static foreach (scheme; editorSchemes)
            {
                static foreach (a; scheme.aliases)
                    case a:
                {
                    writeLocationUri!(a, path, line, col)(w);  // @nogc
                    return;
                }
            }
            default:
            {
                writeLocationUri!("", path, line, col)(w);  // file:// fallback
                return;
            }
        }
    }

    private static string editorName()
    {
        // Thread-local lazy cache
        static string cached = null;
        if (cached is null)
            cached = detectedEditorName();
        return cached;
    }
}

/**
Builds a source URI for a runtime location using `$VISUAL`, then `$EDITOR`.

Unlike `writeSourceUri`, whose location arguments are compile-time values, this
helper accepts the runtime paths carried by exceptions and stack frames. The
path is resolved against the compiler's working directory, and completed to an
absolute path (`absoluteSourcePath`), before the editor scheme is selected.
Unknown and terminal editors use the portable `file://` fallback.
*/
string editorSourceUri(string path, size_t line = 0, size_t col = 0) @safe
{
    const absolute = absoluteSourcePath(resolveSourcePath(path));
    return editorSourceUriFor(absolute, line, col, detectedEditorName());
}

// ─────────────────────────────────────────────────────────────────────────────
// Internal Helpers
// ─────────────────────────────────────────────────────────────────────────────

private EditorScheme findScheme(string editorAlias) @safe pure
{
    foreach (scheme; editorSchemes)
        foreach (a; scheme.aliases)
            if (a == editorAlias)
                return scheme;
    return EditorScheme("Default", &fileUri, []);
}

/// The executable name from an editor command such as `code --wait`.
private string detectedEditorName() @safe
{
    import std.process : environment;

    const visual = editorCommandName(environment.get("VISUAL", ""));
    return visual.length
        ? visual
        : editorCommandName(environment.get("EDITOR", ""));
}

private string editorCommandName(scope const(char)[] command) @safe pure nothrow
{
    import std.ascii : toLower;
    import std.path : baseName, stripExtension;
    import std.string : strip;

    auto rest = command.strip;
    if (!rest.length)
        return null;

    size_t end;
    if (rest[0] == '"' || rest[0] == '\'')
    {
        const quote = rest[0];
        end = 1;
        while (end < rest.length && rest[end] != quote)
            end++;
        rest = rest[1 .. end];
    }
    else
    {
        while (end < rest.length && rest[end] != ' ' && rest[end] != '\t')
            end++;
        rest = rest[0 .. end];
    }

    const name = rest.baseName.stripExtension;
    string lowered;
    foreach (c; name)
        lowered ~= c.toLower;
    return lowered;
}

private string editorSourceUriFor(
    string absolutePath,
    size_t line,
    size_t col,
    string editor,
) @safe pure
    => findScheme(editor).uriFun(absolutePath, line, col);

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

/// resolveSourcePath resolves relative paths against compiler CWD, and
/// absoluteSourcePath completes what a relocated build left relative.
@("sourceUri.resolveSourcePath.relative")
@safe pure nothrow
unittest
{
    import std.path : isAbsolute;

    enum resolved = resolveSourcePath(
        "libs/base/src/sparkles/base/source_uri.d");
    // Must end with the relative path
    assert(resolved.length > 40
        && resolved[$ - 40 .. $] == "libs/base/src/sparkles/base/source_uri.d");
    // Absolute once completed — a drive-letter root on Windows, where dub
    // hands the compiler `D:\a\...` full paths, a leading slash elsewhere.
    const absolute = absoluteSourcePath(resolved);
    assert(absolute.isAbsolute, absolute);
    assert(absolute[$ - 40 .. $] == "libs/base/src/sparkles/base/source_uri.d");
}

/// resolveSourcePath works at compile time.
@("sourceUri.resolveSourcePath.ctfe")
@safe pure
unittest
{
    enum absPath = resolveSourcePath("/already/absolute");
    static assert(absPath == "/already/absolute");

    enum relPath = resolveSourcePath("libs/base/src/sparkles/base/source_uri.d");
    static assert(relPath.length > 40
        && relPath[$ - 40 .. $] == "libs/base/src/sparkles/base/source_uri.d");
}

/// A relocated build (`--ffile-prefix-map=<root>=.`) records the paths
/// relative to the root, and resolveSourcePath keeps them so.
@("sourceUri.resolveSourcePath.relocated")
@safe pure
unittest
{
    // Sources passed relative to the root: `__FILE__` names them so.
    assert(resolveSourcePath("libs/a/b.d", "./libs/a/b.d", "libs/a/b.d")
        == "./libs/a/b.d");
    // Sources passed absolute: the map rewrote `__FILE__` too.
    assert(resolveSourcePath("libs/a/b.d", "./libs/a/b.d", "./libs/a/b.d")
        == "libs/a/b.d");
}

/// A compile-time location becomes an absolute `file://` URI, in a relocated
/// build too.
@("sourceUri.FileUriHook.typeLocationIsAbsolute")
@safe pure
unittest
{
    import std.algorithm.searching : startsWith;
    import std.path : isAbsolute;
    import sparkles.base.buffer : SharedBuffer;

    static struct Probe {}
    enum loc = __traits(getLocation, Probe);
    SharedBuffer!(char, 512) w;
    FileUriHook.writeSourceUri!(resolveSourcePath(loc[0]), loc[1], loc[2])(w);
    const uri = w[].idup;
    assert(uri.startsWith("file://"), uri);
    const path = uri["file://".length .. $];
    assert(path.isAbsolute, uri);
}

/// FileUriHook produces file:// URIs.
@("sourceUri.FileUriHook.writeSourceUri")
@safe pure
unittest
{
    import sparkles.base.buffer : checkWriter;

    checkWriter!((ref w) => FileUriHook.writeSourceUri!(
        "/home/user/project/main.d", size_t(42), size_t(5))(w))(
        "file:///home/user/project/main.d#L42");
}

/// SchemeHook!"code" produces vscode:// URIs.
@("sourceUri.SchemeHook.writeSourceUri")
@safe pure
unittest
{
    import sparkles.base.buffer : checkWriter;

    checkWriter!((ref w) => SchemeHook!"code".writeSourceUri!(
        "/home/user/project/main.d", size_t(10), size_t(3))(w))(
        "vscode://file/home/user/project/main.d:10:3");
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

/// Runtime editor commands select the same schemes as the compile-time hooks.
@("sourceUri.editorSourceUri.editorCommands")
@safe pure
unittest
{
    assert(editorCommandName("code --wait") == "code");
    assert(editorCommandName("/usr/bin/cursor -w") == "cursor");
    assert(editorCommandName("\"/opt/VS Code/code\" --wait") == "code");
    assert(editorCommandName("nvim") == "nvim");

    assert(editorSourceUriFor("/src/main.d", 12, 3, "code")
        == "vscode://file/src/main.d:12:3");
    assert(editorSourceUriFor("/src/main.d", 12, 3, "cursor")
        == "cursor://file/src/main.d:12:3");
    assert(editorSourceUriFor("/src/main.d", 12, 3, "zed")
        == "zed://file/src/main.d:12:3");
    assert(editorSourceUriFor("/src/main.d", 12, 3, "nvim")
        == "file:///src/main.d#L12");
    assert(editorSourceUriFor("/src/main.d", 12, 3, "unknown")
        == "file:///src/main.d#L12");
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
