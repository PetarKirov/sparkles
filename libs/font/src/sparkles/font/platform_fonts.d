/**
The font files the platform lists (`docs/specs/font/discovery.md` FTD18,
`SPEC.md` FTD2): the input of the catalog's `platform` source.

$(UL
    $(LI Linux, FreeBSD and the other POSIX systems that are neither Apple's
        nor Android: the distinct `FC_FILE` values of `FcFontList` over an
        empty pattern, in the current fontconfig configuration.)
    $(LI macOS: the file URLs of Core Text's
        `CTFontManagerCopyAvailableFontURLs`.)
    $(LI Windows: the system font directory (`GetWindowsDirectoryW`, then
        `Fonts`) and the per-user `%LOCALAPPDATA%\Microsoft\Windows\Fonts`,
        each to be scanned without recursion.)
    $(LI Android: `/system/fonts`, to be scanned without recursion.)
)

$(B Loaded at run time.) The `library` configuration puts no C library on
the link line (FTA7), so fontconfig and the Apple frameworks are opened with
`dlopen` and their functions found with `dlsym`, as
`sparkles.raylib_text.font_coretext` does. A library, function or directory
that cannot be loaded or opened is a $(LREF PlatformIssue), never a failure:
the catalog builds from its other sources (FTD2).

$(B Paths only.) A listing names files or directories; it filters nothing
(the catalog applies the extension filter of FTD16) and describes nothing (the
parser reads every field, FTD1). Files are distinct and in byte order, so the
same configuration lists the same paths in the same order.
*/
module sparkles.font.platform_fonts;

import sparkles.base.buffer : HeapBuffer, Storage;

// Android is also `linux`, and Apple systems are also POSIX: neither uses fontconfig.
version (Windows) {}
else version (Android) {}
else version (OSX) {}
else version (Posix)
    version = SparklesFontconfigPlatform;

/// What went wrong while listing (FTD15's platform outcome kinds).
enum PlatformProblem : ubyte
{
    /// A library or framework could not be loaded; `name` is its path.
    libraryUnavailable,
    /// A loaded library lacks a function; `name` is the function.
    symbolMissing,
    /// A platform call returned failure; `name` is the call.
    serviceFailed,
    /// A platform directory does not exist or is not a directory; `name` is it.
    directoryUnavailable,
}

/**
One problem met while listing. `name` borrows the listing it came from.
`code` is the `errno` or `GetLastError` value of the failure, or 0 where the
platform reports none (`dlopen`, `dlsym`, fontconfig and Core Foundation do
not).
*/
struct PlatformIssue
{
    PlatformProblem kind; ///
    const(char)[] name; ///
    int code; ///
}

/// How to reach the platform's font service.
struct PlatformOptions
{
    /**
    The fontconfig library to load where fontconfig lists the fonts; empty
    for `libfontconfig.so.1`, found on the dynamic loader's search path.
    */
    const(char)[] fontconfigLibrary;
}

/// The default fontconfig library name (FTD18).
enum defaultFontconfigLibrary = "libfontconfig.so.1";

/// A range of byte strings stored in one owned text buffer.
struct PlatformPaths
{
    private const(char)[] _text;
    private const(TextSpan)[] _spans;

@safe pure nothrow @nogc:

    ///
    bool empty() const scope => _spans.length == 0;
    ///
    size_t length() const scope => _spans.length;
    ///
    alias opDollar = length;
    ///
    const(char)[] front() const return scope => this[0];
    ///
    const(char)[] back() const return scope => this[$ - 1];
    ///
    void popFront() scope { _spans = _spans[1 .. $]; }
    ///
    void popBack() scope { _spans = _spans[0 .. $ - 1]; }
    ///
    PlatformPaths save() return scope => this;
    ///
    const(char)[] opIndex(size_t i) const return scope => _spans[i].of(_text);
}

/// The issues of a listing, as a range of $(LREF PlatformIssue).
struct PlatformIssues
{
    private const(char)[] _text;
    private const(IssueRecord)[] _records;

@safe pure nothrow @nogc:

    ///
    bool empty() const scope => _records.length == 0;
    ///
    size_t length() const scope => _records.length;
    ///
    alias opDollar = length;
    ///
    PlatformIssue front() const return scope => this[0];
    ///
    PlatformIssue back() const return scope => this[$ - 1];
    ///
    void popFront() scope { _records = _records[1 .. $]; }
    ///
    void popBack() scope { _records = _records[0 .. $ - 1]; }
    ///
    PlatformIssues save() return scope => this;
    ///
    PlatformIssue opIndex(size_t i) const return scope
        => PlatformIssue(_records[i].kind, _records[i].name.of(_text), _records[i].code);
}

/**
What the platform listed: owned storage, move-only. Only one of `files` and
`directories` is ever non-empty, by platform.
*/
struct PlatformListing
{
    private HeapBuffer!(char, Storage.unique) _text;
    private HeapBuffer!(TextSpan, Storage.unique) _files;
    private HeapBuffer!(TextSpan, Storage.unique) _directories;
    private HeapBuffer!(IssueRecord, Storage.unique) _issues;

@safe nothrow @nogc:

    /// The absolute paths of the listed files (Linux/BSD, macOS), distinct and in byte order.
    PlatformPaths files() const return scope pure => PlatformPaths(_text[], _files[]);

    /// The directories to scan without recursion (Windows, Android), in the order FTD18 gives.
    PlatformPaths directories() const return scope pure
        => PlatformPaths(_text[], _directories[]);

    /// The problems met, in the order they were met.
    PlatformIssues issues() const return scope pure => PlatformIssues(_text[], _issues[]);

    private TextSpan keep(scope const(char)[] s) scope pure
    {
        const span = TextSpan(_text.length, s.length);
        _text.put(s);
        return span;
    }

    private void addFile(scope const(char)[] path) scope pure
    {
        _files.put(keep(path));
    }

    private void addDirectory(scope const(char)[] path) scope pure
    {
        _directories.put(keep(path));
    }

    private void addIssue(PlatformProblem kind, scope const(char)[] name, int code) scope pure
    {
        _issues.put(IssueRecord(kind, keep(name), code));
    }

    /// Sorts the files in byte order and drops repeats. O(n log n) comparisons.
    private void sortDistinctFiles() pure
    {
        import std.algorithm.sorting : sort;

        const text = _text[];
        auto spans = _files[];
        spans.sort!((a, b) => a.of(text) < b.of(text));
        size_t kept = 0;
        foreach (i; 0 .. spans.length)
            if (kept == 0 || spans[i].of(text) != spans[kept - 1].of(text))
                spans[kept++] = spans[i];
        _files.length = kept;
    }
}

private struct TextSpan
{
    size_t start;
    size_t length;

    const(char)[] of(return scope const(char)[] text) const @safe pure nothrow @nogc
        => text[start .. start + length];
}

private struct IssueRecord
{
    PlatformProblem kind;
    TextSpan name;
    int code;
}

/**
Lists the font files, or font directories, the platform reports (FTD18).
Never fails: every problem is an issue of the result, and what could be
listed is kept. Cost: the platform service's own listing, plus O(n log n)
path comparisons to order n files.
*/
PlatformListing listPlatformFonts(in PlatformOptions options) @safe nothrow @nogc
{
    PlatformListing listing;
    version (Windows)
        listWindows(listing);
    else version (Android)
        listDirectoryIfPresent(listing, "/system/fonts");
    else version (OSX)
    {
        listCoreText(listing);
        listing.sortDistinctFiles();
    }
    else version (SparklesFontconfigPlatform)
    {
        listFontconfig(listing, options);
        listing.sortDistinctFiles();
    }
    return listing;
}

/// A listing keeps what it is given, distinct and ordered, and owns its issue names.
@("platform_fonts.PlatformListing.ordersFilesAndOwnsNames")
@safe nothrow @nogc
unittest
{
    PlatformListing l;
    l.addFile("/b.ttf");
    l.addFile("/a.otf");
    l.addFile("/b.ttf");
    l.addFile("/a.otc");
    {
        char[8] transient = "lib.so.9";
        l.addIssue(PlatformProblem.libraryUnavailable, transient[], 0);
        transient[] = 'x';
    }
    l.sortDistinctFiles();

    const files = l.files;
    assert(files.length == 3);
    assert(files[0] == "/a.otc" && files[1] == "/a.otf" && files[2] == "/b.ttf");
    assert(l.directories.empty);
    assert(l.issues.length == 1);
    assert(l.issues.front.kind == PlatformProblem.libraryUnavailable);
    assert(l.issues.front.name == "lib.so.9");
}

// ── POSIX: dynamic loading ──────────────────────────────────────────────────

version (Posix)
{
    import core.sys.posix.dlfcn : dlclose, dlopen, dlsym, RTLD_LOCAL, RTLD_NOW;

    import sparkles.base.text.cstring : CStr, toTempStringz;

    /// `dlopen(path)`, or null with a `libraryUnavailable` issue naming `path`.
    private void* openLibrary(ref PlatformListing listing, scope const(char)[] path)
        @safe nothrow @nogc
    {
        auto z = path.toTempStringz;
        void* handle = (() @trusted => dlopen(z.ptr, RTLD_NOW | RTLD_LOCAL))();
        if (handle is null)
            listing.addIssue(PlatformProblem.libraryUnavailable, path, 0);
        return handle;
    }

    private void closeLibrary(void* handle) @safe nothrow @nogc
    {
        (() @trusted => dlclose(handle))();
    }

    /**
    Resolves every function-pointer field of `api` from `handle`, each field
    named after its C function. Every missing one is a `symbolMissing` issue;
    true when none is.
    */
    private bool resolve(Api)(ref Api api, void* handle, ref PlatformListing listing)
    {
        bool complete = true;
        static foreach (field; __traits(allMembers, Api))
        {{
            enum zname = field ~ "\0";
            void* p = (() @trusted => dlsym(handle, zname.ptr))();
            if (p is null)
            {
                listing.addIssue(PlatformProblem.symbolMissing, field, 0);
                complete = false;
            }
            alias Fn = typeof(__traits(getMember, api, field));
            // dlsym's untyped answer, typed by the declaration it was named after.
            __traits(getMember, api, field) = (() @trusted => cast(Fn) p)();
        }}
        return complete;
    }
}

// ── Linux, FreeBSD and other POSIX: fontconfig ──────────────────────────────

version (SparklesFontconfigPlatform)
{
    private struct FcConfig;
    private struct FcPattern;
    private struct FcObjectSet;

    private struct FcFontSet
    {
        int nfont;
        int sfont;
        FcPattern** fonts;
    }

    private enum int fcResultMatch = 0;

    /// The fontconfig functions the listing calls, each field named as in C.
    private struct FontconfigApi
    {
    extern (C) nothrow @nogc:
        FcConfig* function() FcInitLoadConfigAndFonts;
        void function(FcConfig*) FcConfigDestroy;
        FcPattern* function() FcPatternCreate;
        void function(FcPattern*) FcPatternDestroy;
        FcObjectSet* function() FcObjectSetCreate;
        int function(FcObjectSet*, const(char)*) FcObjectSetAdd;
        void function(FcObjectSet*) FcObjectSetDestroy;
        FcFontSet* function(FcConfig*, FcPattern*, FcObjectSet*) FcFontList;
        void function(FcFontSet*) FcFontSetDestroy;
        int function(const(FcPattern)*, const(char)*, int, char**) FcPatternGetString;
    }

    private void listFontconfig(ref PlatformListing listing, in PlatformOptions options)
        @safe nothrow @nogc
    {
        const libraryPath = options.fontconfigLibrary.length
            ? options.fontconfigLibrary : defaultFontconfigLibrary;
        void* lib = openLibrary(listing, libraryPath);
        if (lib is null)
            return;
        scope (exit)
            closeLibrary(lib);

        FontconfigApi fc;
        if (!resolve(fc, lib, listing))
            return;

        FcConfig* config = (() @trusted => fc.FcInitLoadConfigAndFonts())();
        if (config is null)
            return listing.addIssue(PlatformProblem.serviceFailed, "FcInitLoadConfigAndFonts", 0);
        scope (exit)
            (() @trusted => fc.FcConfigDestroy(config))();

        FcPattern* pattern = (() @trusted => fc.FcPatternCreate())();
        if (pattern is null)
            return listing.addIssue(PlatformProblem.serviceFailed, "FcPatternCreate", 0);
        scope (exit)
            (() @trusted => fc.FcPatternDestroy(pattern))();

        FcObjectSet* objects = (() @trusted => fc.FcObjectSetCreate())();
        if (objects is null)
            return listing.addIssue(PlatformProblem.serviceFailed, "FcObjectSetCreate", 0);
        scope (exit)
            (() @trusted => fc.FcObjectSetDestroy(objects))();

        // FC_FILE; the variadic FcObjectSetBuild is avoided on purpose.
        if (!(() @trusted => fc.FcObjectSetAdd(objects, "file".ptr))())
            return listing.addIssue(PlatformProblem.serviceFailed, "FcObjectSetAdd", 0);

        FcFontSet* set = (() @trusted => fc.FcFontList(config, pattern, objects))();
        if (set is null)
            return listing.addIssue(PlatformProblem.serviceFailed, "FcFontList", 0);
        scope (exit)
            (() @trusted => fc.FcFontSetDestroy(set))();

        // The set's own bound: `fonts` holds `nfont` patterns.
        auto fonts = (() @trusted => set.nfont > 0 ? set.fonts[0 .. set.nfont] : null)();
        foreach (font; fonts)
        {
            char* file;
            const result = (() @trusted => fc.FcPatternGetString(font, "file".ptr, 0, &file))();
            if (result != fcResultMatch || file is null)
                continue;
            // The string belongs to the pattern, alive until FcFontSetDestroy.
            const path = (() @trusted => CStr.fromStringz(file))();
            listing.addFile(path[]);
        }
    }
}

// ── macOS: Core Text ────────────────────────────────────────────────────────

version (OSX)
{
    private enum coreFoundationPath
        = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation";
    private enum coreTextPath = "/System/Library/Frameworks/CoreText.framework/CoreText";

    private alias CFIndex = ptrdiff_t;

    /// The Core Foundation functions the listing calls, each field named as in C.
    private struct CoreFoundationApi
    {
    extern (C) nothrow @nogc:
        void function(const(void)*) CFRelease;
        CFIndex function(const(void)*) CFArrayGetCount;
        const(void)* function(const(void)*, CFIndex) CFArrayGetValueAtIndex;
        ubyte function(const(void)*, ubyte, char*, CFIndex) CFURLGetFileSystemRepresentation;
    }

    /// The Core Text function the listing calls.
    private struct CoreTextApi
    {
    extern (C) nothrow @nogc:
        const(void)* function() CTFontManagerCopyAvailableFontURLs;
    }

    private void listCoreText(ref PlatformListing listing) @safe nothrow @nogc
    {
        void* cfLib = openLibrary(listing, coreFoundationPath);
        void* ctLib = openLibrary(listing, coreTextPath);
        scope (exit)
        {
            if (cfLib !is null)
                closeLibrary(cfLib);
            if (ctLib !is null)
                closeLibrary(ctLib);
        }
        if (cfLib is null || ctLib is null)
            return;

        CoreFoundationApi cf;
        CoreTextApi ct;
        const cfComplete = resolve(cf, cfLib, listing);
        const ctComplete = resolve(ct, ctLib, listing);
        if (!cfComplete || !ctComplete)
            return;

        const(void)* urls = (() @trusted => ct.CTFontManagerCopyAvailableFontURLs())();
        if (urls is null)
            return listing.addIssue(PlatformProblem.serviceFailed,
                "CTFontManagerCopyAvailableFontURLs", 0);
        scope (exit)
            (() @trusted => cf.CFRelease(urls))();

        const count = (() @trusted => cf.CFArrayGetCount(urls))();
        // PATH_MAX is 1,024 on macOS; the margin costs nothing.
        char[4096] buffer = void;
        foreach (i; 0 .. count)
        {
            const(void)* url = (() @trusted => cf.CFArrayGetValueAtIndex(urls, i))();
            if (url is null)
                continue;
            const ok = (() @trusted => cf.CFURLGetFileSystemRepresentation(url, 1,
                buffer.ptr, buffer.length))();
            if (!ok)
            {
                listing.addIssue(PlatformProblem.serviceFailed, "CFURLGetFileSystemRepresentation", 0);
                continue;
            }
            const path = (() @trusted => CStr.fromStringz(buffer.ptr))();
            listing.addFile(path[]);
        }
    }
}

// ── Android ─────────────────────────────────────────────────────────────────

version (Android)
{
    /// Lists `path` as a directory when it is one, else reports it.
    private void listDirectoryIfPresent(ref PlatformListing listing, string path)
        @safe nothrow @nogc
    {
        import core.stdc.errno : errno, ENOTDIR;
        import core.sys.posix.sys.stat : S_ISDIR, stat, stat_t;

        stat_t st;
        auto z = path.toTempStringz;
        const failed = (() @trusted => stat(z.ptr, &st))() != 0;
        if (failed)
            return listing.addIssue(PlatformProblem.directoryUnavailable, path, errno);
        if (!S_ISDIR(st.st_mode))
            return listing.addIssue(PlatformProblem.directoryUnavailable, path, ENOTDIR);
        listing.addDirectory(path);
    }
}

// ── Windows ─────────────────────────────────────────────────────────────────

version (Windows)
{
    import core.sys.windows.winbase : GetEnvironmentVariableW, GetFileAttributesW, GetLastError,
        GetWindowsDirectoryW;
    import core.sys.windows.windef : DWORD;
    import core.sys.windows.winerror : ERROR_DIRECTORY, ERROR_INSUFFICIENT_BUFFER;
    import core.sys.windows.winnt : FILE_ATTRIBUTE_DIRECTORY;

    import sparkles.base.text.utf16 : utf16ToUtf8;

    private enum DWORD invalidFileAttributes = 0xFFFF_FFFF;

    /// Room for a long path in UTF-16 units, terminator included.
    private enum size_t pathUnits = 1024;

    private void listWindows(ref PlatformListing listing) @safe nothrow @nogc
    {
        wchar[pathUnits] path = void;

        const systemLength = (() @trusted => GetWindowsDirectoryW(path.ptr, cast(uint) path.length))();
        if (systemLength == 0 || systemLength >= path.length)
            listing.addIssue(PlatformProblem.serviceFailed, "GetWindowsDirectoryW",
                cast(int) (systemLength == 0 ? GetLastError() : ERROR_INSUFFICIENT_BUFFER));
        else
            listDirectory(listing, path[], systemLength, `\Fonts`w);

        const userLength = (() @trusted => GetEnvironmentVariableW("LOCALAPPDATA"w.ptr,
            path.ptr, cast(DWORD) path.length))();
        if (userLength == 0 || userLength >= path.length)
            listing.addIssue(PlatformProblem.serviceFailed, "GetEnvironmentVariableW(LOCALAPPDATA)",
                cast(int) (userLength == 0 ? GetLastError() : ERROR_INSUFFICIENT_BUFFER));
        else
            listDirectory(listing, path[], userLength, `\Microsoft\Windows\Fonts`w);
    }

    /// Lists `path[0 .. length] ~ suffix` as a directory when it is one, else reports it.
    private void listDirectory(ref PlatformListing listing, scope wchar[] path, size_t length,
        scope const(wchar)[] suffix) @safe nothrow @nogc
    {
        if (length + suffix.length >= path.length)
            return listing.addIssue(PlatformProblem.serviceFailed, "font directory path",
                cast(int) ERROR_INSUFFICIENT_BUFFER);
        path[length .. length + suffix.length] = suffix[];
        const end = length + suffix.length;
        path[end] = 0;

        char[pathUnits * 3] utf8 = void;
        const converted = utf16ToUtf8(path[0 .. end], utf8[]);
        if (converted.hasError)
            return listing.addIssue(PlatformProblem.serviceFailed, "UTF-16 font directory path", 0);
        const name = utf8[0 .. converted.value];

        const attributes = (() @trusted => GetFileAttributesW(path.ptr))();
        if (attributes == invalidFileAttributes)
            return listing.addIssue(PlatformProblem.directoryUnavailable, name,
                cast(int) GetLastError());
        if (!(attributes & FILE_ATTRIBUTE_DIRECTORY))
            return listing.addIssue(PlatformProblem.directoryUnavailable, name, cast(int) ERROR_DIRECTORY);
        listing.addDirectory(name);
    }
}
