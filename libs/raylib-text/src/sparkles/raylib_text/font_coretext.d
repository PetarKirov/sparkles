/**
CoreText font discovery — the macOS answer to the three questions `fc-match`,
`fc-query` and `fc-scan` answer on Linux.

$(B Why not fontconfig.) macOS does not ship it, and `std.process.execute`
reports a missing binary by $(I throwing), not by a non-zero status — so every
`fc-*` call site was an uncaught `ProcessException` on a Mac rather than a
graceful "no answer". Installing fontconfig via nix/homebrew would fix the
crash and still answer badly: it would see only the font directories its own
configuration lists, not the faces the user actually installed through Font
Book. CoreText is the system's own font database, is always present, and needs
no subprocess.

$(B No raylib), the same split `font_discovery.d` keeps: this module resolves
names to files and reads coverage, and knows nothing about atlases or GL. That
is what lets it carry real unit tests — `font_set.d` cannot, since everything
it does needs a live GL context.

$(B Resolved with `dlopen`), the way `sparkles.ui_app.display` reaches
`CGSessionCopyCurrentDictionary`: a terminal-only build must not link CoreText
just so a GUI build can ask it questions. Every entry point degrades to "no
answer" when the frameworks cannot be opened, so the caller falls through to
the directory scanner exactly as it does on a host without fontconfig.

$(B Collections are excluded on purpose.) raylib rasterizes through
`stb_truetype`, and `LoadFontEx` calls `stbtt_InitFont` at offset 0 — which for
a `.ttc` is the collection header, not a font, so the load produces garbage
rather than failing. That rules out Menlo and Courier, macOS's two obvious
monospace families, which is why $(LREF genericMonospaceFamilies) leads with
the `.ttf` faces instead. See $(LREF isLoadableFontFile).
*/
module sparkles.raylib_text.font_coretext;

version (OSX):

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.text.cstring : toCString;

// ── ASCII text helpers ───────────────────────────────────────────────────────
//
// Deliberately not `std.string.strip` / `std.uni.toLower` / `std.array.split`:
// all three decode UTF-8 and can throw `UTFException`, which costs this module
// `nothrow` for no benefit. Font file extensions and the generic-alias table
// are ASCII by construction, and a family name is only ever compared for
// equality after being handed straight back to CoreText.

/// `s` without leading/trailing ASCII whitespace.
private inout(char)[] asciiStrip(return scope inout(char)[] s) @safe pure nothrow @nogc
{
    size_t b = 0, e = s.length;
    static bool ws(char c) @safe pure nothrow @nogc
        => c == ' ' || c == '\t' || c == '\n' || c == '\r';
    while (b < e && ws(s[b]))
        b++;
    while (e > b && ws(s[e - 1]))
        e--;
    return s[b .. e];
}

/// ASCII case-insensitive equality.
private bool asciiEqualFold(scope const(char)[] a, scope const(char)[] b)
    @safe pure nothrow @nogc
{
    import std.ascii : toLower;

    if (a.length != b.length)
        return false;
    foreach (i, c; a)
        if (toLower(c) != toLower(b[i]))
            return false;
    return true;
}

/// ASCII case-insensitive suffix test.
private bool asciiEndsWithFold(scope const(char)[] s, scope const(char)[] suffix)
    @safe pure nothrow @nogc
{
    return s.length >= suffix.length
        && asciiEqualFold(s[$ - suffix.length .. $], suffix);
}

/// Calls `sink` with each comma-separated field of `s`, stripped. Hands out
/// slices of `s` and allocates nothing itself; the sink is free to do either.
private void eachCommaField(scope const(char)[] s,
    scope void delegate(scope const(char)[]) @safe nothrow sink) @safe nothrow
{
    size_t start = 0;
    foreach (i, c; s)
        if (c == ',')
        {
            sink(asciiStrip(s[start .. i]));
            start = i + 1;
        }
    sink(asciiStrip(s[start .. $]));
}

// ── the trait bits we care about (CTFontTraits.h symbolic traits) ────────────

enum uint ctTraitItalic = 1 << 0;      /// `kCTFontTraitItalic`
enum uint ctTraitBold = 1 << 1;        /// `kCTFontTraitBold`
enum uint ctTraitMonoSpace = 1 << 10;  /// `kCTFontTraitMonoSpace`
enum uint ctTraitColorGlyphs = 1 << 13; /// `kCTFontTraitColorGlyphs`

/// One face CoreText knows about: the file backing it and its symbolic traits.
/// Only faces `LoadFontEx` can actually open are ever reported — see the
/// module header on collections.
struct CtFace
{
    string path;  /// absolute path to the font file
    uint traits;  /// `kCTFontSymbolicTrait` bits

    bool bold() const @safe pure nothrow @nogc => (traits & ctTraitBold) != 0;
    /// ditto
    bool italic() const @safe pure nothrow @nogc => (traits & ctTraitItalic) != 0;
    /// ditto
    bool monospace() const @safe pure nothrow @nogc => (traits & ctTraitMonoSpace) != 0;

    /// The plain face: neither bold nor italic.
    bool regular() const @safe pure nothrow @nogc => !bold && !italic;
}

/**
The families tried, in order, for a generic name like fontconfig's
`monospace`.

CoreText has no generic aliases — asking it for "monospace" matches nothing —
so the mapping has to live somewhere, and a named list beats a trait search
because it is deterministic across machines and OS releases. The trait search
is still the last resort ($(LREF anyMonospaceFamily)) for a stripped system
where none of these exist.

`SF Mono` leads because it is Apple's terminal face and ships as plain `.ttf`.
`Menlo` is last despite being the Terminal.app default: it ships only as a
`.ttc`, so it is normally filtered out before it can be chosen, and it is
listed only to keep working if a future macOS splits it into `.ttf` files.
*/
immutable string[] genericMonospaceFamilies = [
    "SF Mono", "Monaco", "Andale Mono", "Courier New", "PT Mono", "Menlo",
];

/// Generic family names that map onto $(LREF genericMonospaceFamilies).
/// Matched case-insensitively after stripping.
immutable string[] genericMonospaceAliases = ["monospace", "mono", "monospaced"];

/// `true` when `path` names a font container raylib's `LoadFontEx` can open.
/// Collections (`.ttc`, `.dfont`) cannot be: see the module header.
bool isLoadableFontFile(scope const(char)[] path) @safe pure nothrow @nogc
    => path.asciiEndsWithFold(".ttf") || path.asciiEndsWithFold(".otf");

@("font_coretext.isLoadableFontFile.rejectsCollections")
@safe pure nothrow
unittest
{
    assert(isLoadableFontFile("/System/Library/Fonts/Monaco.ttf"));
    assert(isLoadableFontFile("/System/Library/Fonts/LastResort.otf"));
    assert(isLoadableFontFile("/x/UPPER.TTF"), "extension match is case-insensitive");
    // The two that matter: stb_truetype reads a collection header as a font.
    assert(!isLoadableFontFile("/System/Library/Fonts/Menlo.ttc"));
    assert(!isLoadableFontFile("/Library/Fonts/Something.dfont"));
    assert(!isLoadableFontFile("/x/notafont.txt"));
    assert(!isLoadableFontFile(""));
}

/// `true` when `name` is a generic alias rather than a real family.
bool isGenericMonospace(scope const(char)[] name) @safe pure nothrow @nogc
{
    const n = name.asciiStrip;
    foreach (generic; genericMonospaceAliases)
        if (n.asciiEqualFold(generic))
            return true;
    return false;
}

@("font_coretext.isGenericMonospace.aliases")
@safe pure nothrow
unittest
{
    assert(isGenericMonospace("monospace"));
    assert(isGenericMonospace("  Monospace  "), "stripped and case-folded");
    assert(isGenericMonospace("MONO"));
    assert(!isGenericMonospace("SF Mono"), "a real family is not a generic");
    assert(!isGenericMonospace(""));
}

// ── the dlopen'd binding table ───────────────────────────────────────────────

private
{
    alias CFIndex = ptrdiff_t;
    alias Boolean = ubyte;
    alias CFStringEncoding = uint;

    enum CFStringEncoding kCFStringEncodingUTF8 = 0x0800_0100;
    enum int kCFURLPOSIXPathStyle = 0;
    enum int kCFNumberSInt32Type = 3;

    extern (C) nothrow @nogc
    {
        alias FnRelease = void function(const(void)*);
        alias FnStringCreate = const(void)* function(const(void)*, const(ubyte)*,
            CFIndex, CFStringEncoding, Boolean);
        alias FnStringGetCString = Boolean function(const(void)*, char*, CFIndex,
            CFStringEncoding);
        alias FnStringGetLength = CFIndex function(const(void)*);
        alias FnDictCreate = const(void)* function(const(void)*, const(void)**,
            const(void)**, CFIndex, const(void)*, const(void)*);
        alias FnSetCreate = const(void)* function(const(void)*, const(void)**,
            CFIndex, const(void)*);
        alias FnUrlCreate = const(void)* function(const(void)*, const(void)*,
            int, Boolean);
        alias FnUrlCopyPath = const(void)* function(const(void)*, int);
        alias FnArrayCount = CFIndex function(const(void)*);
        alias FnArrayValueAt = const(void)* function(const(void)*, CFIndex);
        alias FnDictGetValue = const(void)* function(const(void)*, const(void)*);
        alias FnNumberCreate = const(void)* function(const(void)*, int, const(void)*);
        alias FnNumberGetValue = Boolean function(const(void)*, int, void*);
        alias FnDataLength = CFIndex function(const(void)*);
        alias FnDataBytePtr = const(ubyte)* function(const(void)*);
        alias FnCharsetBitmap = const(void)* function(const(void)*, const(void)*);
        alias FnDescCreate = const(void)* function(const(void)*);
        alias FnDescMatching = const(void)* function(const(void)*, const(void)*);
        alias FnDescCopyAttr = const(void)* function(const(void)*, const(void)*);
        alias FnDescFromUrl = const(void)* function(const(void)*);
        alias FnAvailableFamilies = const(void)* function();
    }

    /// The resolved symbols. Populated once by $(LREF ct); `ok` false means
    /// every entry point degrades to "no answer".
    struct CoreTextApi
    {
        bool ok;

        FnRelease release;
        FnStringCreate stringCreate;
        FnStringGetCString stringGetCString;
        FnStringGetLength stringGetLength;
        FnDictCreate dictCreate;
        FnSetCreate setCreate;
        FnUrlCreate urlCreate;
        FnUrlCopyPath urlCopyPath;
        FnArrayCount arrayCount;
        FnArrayValueAt arrayValueAt;
        FnDictGetValue dictGetValue;
        FnNumberCreate numberCreate;
        FnNumberGetValue numberGetValue;
        FnDataLength dataLength;
        FnDataBytePtr dataBytePtr;
        FnCharsetBitmap charsetBitmap;

        FnDescCreate descCreate;
        FnDescMatching descMatching;
        FnDescCopyAttr descCopyAttr;
        FnDescFromUrl descFromUrl;
        FnAvailableFamilies availableFamilies;

        // Data symbols (CFStringRef / callback-struct globals). dlsym hands
        // back the address OF the variable, so the ref ones are dereferenced
        // on load and the callback tables are kept as pointers.
        const(void)* kDictKeyCallBacks;
        const(void)* kDictValueCallBacks;
        const(void)* kSetCallBacks;
        const(void)* kFamilyName;
        const(void)* kUrl;
        const(void)* kTraits;
        const(void)* kSymbolicTrait;
        const(void)* kCharacterSet;
    }

    __gshared CoreTextApi api_;

    /**
    Resolved once at startup rather than lazily on first use.

    Lazy initialization here would need a lock or a release/acquire pair: the
    obvious `if (!loaded) { loaded = true; load(); }` publishes the flag before
    the table is filled, so a second thread sails past the guard and reads
    half-populated function pointers. That is not hypothetical — the test
    runner executes unittests in parallel threads, and it showed up as one
    `coreTextAvailable()` returning true while its neighbours saw false.

    A module constructor sidesteps the question: druntime runs it once, in the
    main thread, before any user code. The cost is two `dlopen`s of frameworks
    already resident in the dyld shared cache plus ~30 `dlsym`s — tens of
    microseconds, paid once, even by a `--tui` build that never asks a
    question.
    */
    shared static this()
    {
        loadCoreText(api_);
    }

    ref CoreTextApi ct() @trusted nothrow => api_;

    void loadCoreText(ref CoreTextApi a) @trusted nothrow
    {
        import core.sys.posix.dlfcn : dlopen, dlsym, RTLD_LAZY, RTLD_LOCAL;

        enum cfPath = "/System/Library/Frameworks/CoreFoundation.framework"
            ~ "/CoreFoundation\0";
        enum ctPath = "/System/Library/Frameworks/CoreText.framework/CoreText\0";

        // Never dlclose'd: these are the system frameworks, already resident in
        // the dyld shared cache, and the returned CFString globals must outlive
        // every call. Closing them to be tidy would dangle the attribute keys.
        void* cf = dlopen(cfPath.ptr, RTLD_LAZY | RTLD_LOCAL);
        void* c = dlopen(ctPath.ptr, RTLD_LAZY | RTLD_LOCAL);
        if (cf is null || c is null)
            return;

        // `(name ~ "\0").ptr` would hand dlsym the only reference to a fresh
        // GC array and then drop it — and allocate on each of the ~20 calls
        // below. The CString is a named local, so it is plainly still alive
        // across the call, and nothing is allocated at all.
        T sym(T)(void* h, string name)
        {
            auto nameZ = toCString!128([name]);
            return cast(T) dlsym(h, nameZ.ptr);
        }

        // A CFStringRef global: dlsym yields `CFStringRef*`, so deref it.
        const(void)* strGlobal(void* h, string name)
        {
            auto nameZ = toCString!128([name]);
            auto p = cast(const(void)**) dlsym(h, nameZ.ptr);
            return p is null ? null : *p;
        }

        a.release = sym!FnRelease(cf, "CFRelease");
        a.stringCreate = sym!FnStringCreate(cf, "CFStringCreateWithBytes");
        a.stringGetCString = sym!FnStringGetCString(cf, "CFStringGetCString");
        a.stringGetLength = sym!FnStringGetLength(cf, "CFStringGetLength");
        a.dictCreate = sym!FnDictCreate(cf, "CFDictionaryCreate");
        a.setCreate = sym!FnSetCreate(cf, "CFSetCreate");
        a.urlCreate = sym!FnUrlCreate(cf, "CFURLCreateWithFileSystemPath");
        a.urlCopyPath = sym!FnUrlCopyPath(cf, "CFURLCopyFileSystemPath");
        a.arrayCount = sym!FnArrayCount(cf, "CFArrayGetCount");
        a.arrayValueAt = sym!FnArrayValueAt(cf, "CFArrayGetValueAtIndex");
        a.dictGetValue = sym!FnDictGetValue(cf, "CFDictionaryGetValue");
        a.numberCreate = sym!FnNumberCreate(cf, "CFNumberCreate");
        a.numberGetValue = sym!FnNumberGetValue(cf, "CFNumberGetValue");
        a.dataLength = sym!FnDataLength(cf, "CFDataGetLength");
        a.dataBytePtr = sym!FnDataBytePtr(cf, "CFDataGetBytePtr");
        a.charsetBitmap = sym!FnCharsetBitmap(cf,
            "CFCharacterSetCreateBitmapRepresentation");

        // Callback tables are structs, not refs — the address IS the value.
        a.kDictKeyCallBacks = dlsym(cf, "kCFTypeDictionaryKeyCallBacks");
        a.kDictValueCallBacks = dlsym(cf, "kCFTypeDictionaryValueCallBacks");
        a.kSetCallBacks = dlsym(cf, "kCFTypeSetCallBacks");

        a.descCreate = sym!FnDescCreate(c, "CTFontDescriptorCreateWithAttributes");
        a.descMatching = sym!FnDescMatching(c,
            "CTFontDescriptorCreateMatchingFontDescriptors");
        a.descCopyAttr = sym!FnDescCopyAttr(c, "CTFontDescriptorCopyAttribute");
        a.descFromUrl = sym!FnDescFromUrl(c,
            "CTFontManagerCreateFontDescriptorsFromURL");
        a.availableFamilies = sym!FnAvailableFamilies(c,
            "CTFontManagerCopyAvailableFontFamilyNames");

        a.kFamilyName = strGlobal(c, "kCTFontFamilyNameAttribute");
        a.kUrl = strGlobal(c, "kCTFontURLAttribute");
        a.kTraits = strGlobal(c, "kCTFontTraitsAttribute");
        a.kSymbolicTrait = strGlobal(c, "kCTFontSymbolicTrait");
        a.kCharacterSet = strGlobal(c, "kCTFontCharacterSetAttribute");

        a.ok = a.release !is null && a.stringCreate !is null
            && a.stringGetCString !is null && a.stringGetLength !is null
            && a.dictCreate !is null && a.setCreate !is null
            && a.urlCreate !is null && a.urlCopyPath !is null
            && a.arrayCount !is null && a.arrayValueAt !is null
            && a.dictGetValue !is null && a.numberCreate !is null
            && a.numberGetValue !is null
            && a.dataLength !is null && a.dataBytePtr !is null
            && a.charsetBitmap !is null && a.descCreate !is null
            && a.descMatching !is null && a.descCopyAttr !is null
            && a.descFromUrl !is null && a.availableFamilies !is null
            && a.kDictKeyCallBacks !is null && a.kDictValueCallBacks !is null
            && a.kSetCallBacks !is null && a.kFamilyName !is null
            && a.kUrl !is null && a.kTraits !is null
            && a.kSymbolicTrait !is null && a.kCharacterSet !is null;
    }

    // ── small CF helpers ─────────────────────────────────────────────────────

    /// A CFString owning `s`'s bytes. Caller releases. Null on failure.
    const(void)* cfStr(scope const(char)[] s) @trusted nothrow
    {
        return ct.stringCreate(null, cast(const(ubyte)*) s.ptr,
            cast(CFIndex) s.length, kCFStringEncodingUTF8, 0);
    }

    /// A CFString's UTF-8 bytes as a GC string. `""` when it cannot be read.
    string cfStrToD(const(void)* s) @trusted nothrow
    {
        if (s is null)
            return "";
        // Worst case 4 bytes/unit plus the NUL CFStringGetCString insists on.
        const cap = cast(size_t) ct.stringGetLength(s) * 4 + 1;
        auto buf = new char[cap];
        if (!ct.stringGetCString(s, buf.ptr, cast(CFIndex) cap,
                kCFStringEncodingUTF8))
            return "";
        size_t n = 0;
        while (n < cap && buf[n] != '\0')
            n++;
        return cast(string) buf[0 .. n];
    }

    /// `{ key: value }` as a CFDictionary. Caller releases.
    const(void)* cfDict1(const(void)* key, const(void)* value) @trusted nothrow
    {
        const(void)*[1] keys = [key];
        const(void)*[1] vals = [value];
        return ct.dictCreate(null, keys.ptr, vals.ptr, 1,
            ct.kDictKeyCallBacks, ct.kDictValueCallBacks);
    }

    /// The font file behind a descriptor, or `""`.
    string descPath(const(void)* desc) @trusted nothrow
    {
        auto url = ct.descCopyAttr(desc, ct.kUrl);
        if (url is null)
            return "";
        scope (exit) ct.release(url);
        auto path = ct.urlCopyPath(url, kCFURLPOSIXPathStyle);
        if (path is null)
            return "";
        scope (exit) ct.release(path);
        return cfStrToD(path);
    }

    /// A descriptor's symbolic traits (0 when absent).
    uint descTraits(const(void)* desc) @trusted nothrow
    {
        auto traits = ct.descCopyAttr(desc, ct.kTraits);
        if (traits is null)
            return 0;
        scope (exit) ct.release(traits);
        auto num = ct.dictGetValue(traits, ct.kSymbolicTrait); // borrowed
        if (num is null)
            return 0;
        uint v;
        if (!ct.numberGetValue(num, kCFNumberSInt32Type, &v))
            return 0;
        return v;
    }
}

// ── public API ───────────────────────────────────────────────────────────────

/// `true` when the CoreText and CoreFoundation frameworks resolved. When
/// `false` every query below returns nothing and the caller should fall
/// through to the directory scanner.
bool coreTextAvailable() @trusted nothrow => ct.ok;

/**
Every loadable face CoreText reports for `family`, in CoreText's own order.

The `fc-scan` analog, and the reason styled-variant discovery works for a
family the user installed through Font Book: the family name is matched
$(B exactly) (it is passed as a mandatory attribute), so an unknown family
yields an empty array instead of CoreText's nearest guess — which is what
makes "did this family resolve?" answerable at all.
*/
CtFace[] familyFaces(string family) @trusted nothrow
{
    const trimmed = family.asciiStrip;
    if (!ct.ok || trimmed.length == 0)
        return null;

    auto name = cfStr(trimmed);
    if (name is null)
        return null;
    scope (exit) ct.release(name);

    auto attrs = cfDict1(ct.kFamilyName, name);
    if (attrs is null)
        return null;
    scope (exit) ct.release(attrs);

    auto desc = ct.descCreate(attrs);
    if (desc is null)
        return null;
    scope (exit) ct.release(desc);

    // Family mandatory: without this CoreText happily substitutes a different
    // family, and "not installed" becomes indistinguishable from "installed".
    const(void)*[1] mandatoryKeys = [ct.kFamilyName];
    auto mandatory = ct.setCreate(null, mandatoryKeys.ptr, 1, ct.kSetCallBacks);
    if (mandatory is null)
        return null;
    scope (exit) ct.release(mandatory);

    auto matches = ct.descMatching(desc, mandatory);
    if (matches is null)
        return null;
    scope (exit) ct.release(matches);

    CtFace[] faces;
    const n = ct.arrayCount(matches);
    foreach (i; 0 .. n)
    {
        auto d = ct.arrayValueAt(matches, i); // borrowed
        if (d is null)
            continue;
        const path = descPath(d);
        if (path.length == 0 || !isLoadableFontFile(path))
            continue;
        try
            faces ~= CtFace(path, descTraits(d));
        catch (Exception)
            return faces; // OOM appending — return what we have
    }
    return faces;
}

/**
The family name recorded in the font file at `path`, or `""`.

The `fc-query --format=%{family[0]}` analog. Used to answer "did the family the
user asked for actually get loaded?" for `--font-codepoint-map`, where
substituting a different family silently would render the mapped codepoints
from the wrong face.
*/
string familyOfFile(string path) @trusted nothrow
{
    if (!ct.ok || path.length == 0)
        return "";

    auto p = cfStr(path);
    if (p is null)
        return "";
    scope (exit) ct.release(p);

    auto url = ct.urlCreate(null, p, kCFURLPOSIXPathStyle, 0);
    if (url is null)
        return "";
    scope (exit) ct.release(url);

    auto descs = ct.descFromUrl(url);
    if (descs is null)
        return "";
    scope (exit) ct.release(descs);

    if (ct.arrayCount(descs) < 1)
        return "";
    auto d = ct.arrayValueAt(descs, 0); // borrowed
    if (d is null)
        return "";
    auto fam = ct.descCopyAttr(d, ct.kFamilyName);
    if (fam is null)
        return "";
    scope (exit) ct.release(fam);
    return cfStrToD(fam);
}

/**
Resolve a family name — or a fontconfig-style comma-separated preference list
("FiraCode Nerd Font Mono,JetBrains Mono,monospace") — to a loadable regular
face, `""` when nothing matches.

The `fc-match` analog. Each name is tried in order; generic names
($(LREF isGenericMonospace)) expand to $(LREF genericMonospaceFamilies) and
then to a trait search, so the shared default `--font monospace` resolves on a
Mac exactly as it does on Linux.
*/
string resolveFamilyList(scope const(char)[] nameOrList) @trusted nothrow
{
    if (!ct.ok)
        return "";

    // The result travels out through captured locals: the sink cannot return a
    // value, and `searching` is what stops later names in the preference list
    // from overwriting an earlier winner.
    string found;
    bool searching = true;

    void tryName(scope const(char)[] name) @safe nothrow
    {
        if (!searching || name.length == 0)
            return;

        // `.length != 0`, never `if (hit)`: a D string is truthy when it is
        // non-NULL, and the `""` these helpers return for "no match" is a
        // non-null empty slice. Testing the pointer made the first family that
        // is not installed win and end the search.
        if (isGenericMonospace(name))
        {
            foreach (fam; genericMonospaceFamilies)
            {
                const hit = pickRegular(familyFaces(fam));
                if (hit.length != 0)
                {
                    found = hit;
                    searching = false;
                    return;
                }
            }
            const any = anyMonospaceFamily();
            if (any.length != 0)
            {
                found = any;
                searching = false;
            }
            return;
        }

        string owned;
        try
            owned = name.idup;
        catch (Exception)
            return; // OOM on a name — try the next one
        const hit = pickRegular(familyFaces(owned));
        if (hit.length != 0)
        {
            found = hit;
            searching = false;
        }
    }

    eachCommaField(nameOrList, &tryName);
    return found;
}

/**
The bold / italic / bold-italic siblings of the family that owns `primaryPath`.

The `fc-scan`-over-the-primary's-directory analog, but by family rather than by
directory — which is strictly better on macOS, where a family's faces are not
required to share a directory. Out-params are `""` when the family has no such
face; the caller's fake-bold / upright-italic fallbacks then apply.
*/
void variantPathsFor(string primaryPath, out string bold, out string italic,
    out string boldItalic) @trusted nothrow
{
    if (!ct.ok)
        return;
    const family = familyOfFile(primaryPath);
    if (family.length == 0)
        return;

    foreach (f; familyFaces(family))
    {
        if (f.path == primaryPath)
            continue;
        if (f.bold && f.italic)
        {
            if (boldItalic.length == 0)
                boldItalic = f.path;
        }
        else if (f.bold)
        {
            if (bold.length == 0)
                bold = f.path;
        }
        else if (f.italic)
        {
            if (italic.length == 0)
                italic = f.path;
        }
    }
}

/**
The loadable face in `family` carrying exactly `traits` (bold/italic bits),
or `""`.

Backs the explicit per-style overrides (`--font-bold` and friends): asking for
a family and a style must not silently land on the Regular file, so a family
with no such face reports nothing rather than its nearest member.
*/
string resolveStyledFace(string family, bool bold, bool italic) @trusted nothrow
{
    foreach (f; familyFaces(family))
        if (f.bold == bold && f.italic == italic)
            return f.path;
    return "";
}

/// Every font family installed on this host, in CoreText's order.
/// `CTFontManagerCopyAvailableFontFamilyNames` — the enumeration
/// $(LREF fallbackFaces) picks over.
string[] availableFamilyNames() @trusted nothrow
{
    if (!ct.ok)
        return null;

    auto arr = ct.availableFamilies();
    if (arr is null)
        return null;
    scope (exit) ct.release(arr);

    string[] names;
    const n = ct.arrayCount(arr);
    foreach (i; 0 .. n)
    {
        const name = cfStrToD(ct.arrayValueAt(arr, i)); // borrowed
        if (name.length == 0)
            continue;
        try
            names ~= name;
        catch (Exception)
            return names;
    }
    return names;
}

/**
The two fallback faces the glyph router falls through to: the plainest
Nerd-Font face installed, and a broad-coverage regular monospace that is not
the primary.

The `fc-match monospace -s` analog. Both out-params are `""` when nothing
qualifies — a fallback is an improvement, never a requirement.

Face selection within a family goes through $(LREF pickRegular) rather than
taking CoreText's first entry, for the reason the directory scanner records: a
fallback supplies glyphs the primary lacks, so it wants the plainest face
available. Taking whatever was listed first rendered every fallback icon in
Bold on a machine whose Nerd-Font family led with its Bold face.
*/
void fallbackFaces(string primaryPath, out string nerd, out string regular)
    @trusted nothrow
{
    if (!ct.ok)
        return;

    foreach (family; availableFamilyNames())
    {
        const isNerd = family.containsFold("Nerd Font");
        if (!isNerd || nerd.length != 0)
            continue;
        const path = pickRegular(familyFaces(family));
        if (path.length != 0 && path != primaryPath)
            nerd = path;
    }

    // A curated preference list, not "any monospace": the regular fallback
    // exists to cover codepoints the primary is missing, so breadth of
    // coverage is what matters, and these are the faces macOS ships with the
    // widest repertoires.
    static immutable string[] broadCoverage = [
        "Arial Unicode MS", "Andale Mono", "Courier New", "Monaco", "Menlo",
    ];
    foreach (family; broadCoverage)
    {
        const path = pickRegular(familyFaces(family));
        if (path.length != 0 && path != primaryPath)
        {
            regular = path;
            return;
        }
    }
}

/// ASCII case-insensitive substring test (`std.algorithm.canFind` over
/// `toLower` would decode UTF-8 and cost `nothrow`).
private bool containsFold(scope const(char)[] haystack, scope const(char)[] needle)
    @safe pure nothrow @nogc
{
    if (needle.length == 0 || haystack.length < needle.length)
        return needle.length == 0;
    foreach (i; 0 .. haystack.length - needle.length + 1)
        if (asciiEqualFold(haystack[i .. i + needle.length], needle))
            return true;
    return false;
}

@("font_coretext.containsFold.asciiSubstring")
@safe pure nothrow @nogc
unittest
{
    assert("FiraCode Nerd Font Mono".containsFold("Nerd Font"));
    assert("firacode nerd font mono".containsFold("Nerd Font"), "case-insensitive");
    assert(!"Monaco".containsFold("Nerd Font"));
    assert(!"Nerd".containsFold("Nerd Font"), "needle longer than haystack");
    assert("anything".containsFold(""));
}

/**
The primary face's codepoint coverage, appended to `lo`/`hi` as inclusive
ranges — the `fc-query --format=%{charset}` analog, and what keeps on-demand
atlas growth working (a glyph missing from the atlas is re-requested from the
primary only when the face actually covers it).

Returns `false` when CoreText has no answer, leaving the buffers untouched;
growth is then simply disabled, exactly as a missing `.charset` sidecar does.
*/
bool charsetRanges(string path, ref SmallBuffer!(int, 256, true) lo,
    ref SmallBuffer!(int, 256, true) hi) @trusted nothrow
{
    if (!ct.ok || path.length == 0)
        return false;

    auto p = cfStr(path);
    if (p is null)
        return false;
    scope (exit) ct.release(p);

    auto url = ct.urlCreate(null, p, kCFURLPOSIXPathStyle, 0);
    if (url is null)
        return false;
    scope (exit) ct.release(url);

    auto descs = ct.descFromUrl(url);
    if (descs is null)
        return false;
    scope (exit) ct.release(descs);
    if (ct.arrayCount(descs) < 1)
        return false;

    auto d = ct.arrayValueAt(descs, 0); // borrowed
    if (d is null)
        return false;
    auto set = ct.descCopyAttr(d, ct.kCharacterSet);
    if (set is null)
        return false;
    scope (exit) ct.release(set);

    auto data = ct.charsetBitmap(null, set);
    if (data is null)
        return false;
    scope (exit) ct.release(data);

    const n = ct.dataLength(data);
    auto bytes = ct.dataBytePtr(data);
    if (n <= 0 || bytes is null)
        return false;

    bitmapToRanges(bytes[0 .. cast(size_t) n], lo, hi);
    return true;
}

// ── the bitmap decoder (pure, so it is testable without CoreText) ────────────

/// One plane's worth of `CFCharacterSetCreateBitmapRepresentation` bits.
private enum size_t planeBytes = 8192;

/**
Decode `CFCharacterSetCreateBitmapRepresentation` output into inclusive
codepoint ranges, appended to `lo`/`hi` in ascending order.

The format (documented on `CFCharacterSetCreateBitmapRepresentation`): 8192
bytes covering the BMP, where character `c` is a member when
`bytes[c >> 3] & (1 << (c & 7))`; then, for each non-BMP plane that has
members, a one-byte plane index followed by another 8192 bytes covering
`plane << 16 .. +0x10000`.

Split out and `pure` because it is the only part of the charset path with
logic worth testing — everything around it is CoreFoundation calls.
*/
package void bitmapToRanges(scope const(ubyte)[] bytes,
    ref SmallBuffer!(int, 256, true) lo, ref SmallBuffer!(int, 256, true) hi)
    @safe pure nothrow
{
    void emitPlane(scope const(ubyte)[] plane, int base) @safe pure nothrow
    {
        int runLo = -1;
        foreach (i; 0 .. cast(int)(plane.length * 8))
        {
            const member = (plane[i >> 3] & (1 << (i & 7))) != 0;
            if (member && runLo < 0)
                runLo = i;
            else if (!member && runLo >= 0)
            {
                lo ~= base + runLo;
                hi ~= base + i - 1;
                runLo = -1;
            }
        }
        if (runLo >= 0)
        {
            lo ~= base + runLo;
            hi ~= base + cast(int)(plane.length * 8) - 1;
        }
    }

    if (bytes.length < planeBytes)
        return;
    emitPlane(bytes[0 .. planeBytes], 0);

    // Trailing planes: <index byte><8192 bytes>, repeated.
    size_t off = planeBytes;
    while (off + 1 + planeBytes <= bytes.length)
    {
        const plane = bytes[off];
        emitPlane(bytes[off + 1 .. off + 1 + planeBytes], plane << 16);
        off += 1 + planeBytes;
    }
}

@("font_coretext.bitmapToRanges.bmpRunsAndSingletons")
@safe pure nothrow
unittest
{
    ubyte[planeBytes] bmp;
    void set(int c) { bmp[c >> 3] |= cast(ubyte)(1 << (c & 7)); }

    foreach (c; 0x41 .. 0x5B) // 'A'..'Z', one run
        set(c);
    set(0x7E);                // a singleton
    foreach (c; 0x100 .. 0x180)
        set(c);

    SmallBuffer!(int, 256, true) lo, hi;
    bitmapToRanges(bmp[], lo, hi);

    assert(lo[] == [0x41, 0x7E, 0x100]);
    assert(hi[] == [0x5A, 0x7E, 0x17F]);
}

@("font_coretext.bitmapToRanges.nonBmpPlanes")
@safe pure nothrow
unittest
{
    // BMP plane plus plane 1 (U+1xxxx) — the emoji/MDI case that made
    // on-demand atlas growth worth having in the first place.
    ubyte[] data = new ubyte[planeBytes + 1 + planeBytes];
    data[0x20 >> 3] |= cast(ubyte)(1 << (0x20 & 7)); // U+0020

    data[planeBytes] = 1; // plane index
    auto p1 = data[planeBytes + 1 .. $];
    foreach (c; 0xF600 .. 0xF605) // U+1F600..U+1F604 within plane 1
        p1[c >> 3] |= cast(ubyte)(1 << (c & 7));

    SmallBuffer!(int, 256, true) lo, hi;
    bitmapToRanges(data, lo, hi);

    assert(lo[] == [0x20, 0x1F600]);
    assert(hi[] == [0x20, 0x1F604]);
}

@("font_coretext.bitmapToRanges.runToPlaneEndAndShortInput")
@safe pure nothrow
unittest
{
    // A run reaching the last bit must still be closed.
    ubyte[planeBytes] bmp;
    bmp[$ - 1] = 0x80;
    SmallBuffer!(int, 256, true) lo, hi;
    bitmapToRanges(bmp[], lo, hi);
    assert(lo[] == [0xFFFF] && hi[] == [0xFFFF]);

    // Truncated input is ignored rather than read out of bounds.
    SmallBuffer!(int, 256, true) lo2, hi2;
    bitmapToRanges(new ubyte[10], lo2, hi2);
    assert(lo2.length == 0 && hi2.length == 0);
}

// ── internals used by resolveFamilyList ──────────────────────────────────────

/// The plainest loadable face among `faces`: an explicit regular, else the
/// first non-bold, else nothing. A fallback wants the undecorated face —
/// picking the first match made every glyph render bold whenever a family's
/// Bold file happened to sort first.
private string pickRegular(scope CtFace[] faces) @safe pure nothrow
{
    foreach (f; faces)
        if (f.regular)
            return f.path;
    foreach (f; faces)
        if (!f.bold)
            return f.path;
    return faces.length ? faces[0].path : "";
}

@("font_coretext.pickRegular.prefersTheUndecoratedFace")
@safe pure nothrow
unittest
{
    // Bold first in CoreText's order must not win.
    auto faces = [
        CtFace("/f/Bold.ttf", ctTraitBold),
        CtFace("/f/Italic.ttf", ctTraitItalic),
        CtFace("/f/Regular.ttf", 0),
    ];
    assert(pickRegular(faces) == "/f/Regular.ttf");

    // No regular at all: the non-bold face beats the bold one.
    assert(pickRegular(faces[0 .. 2]) == "/f/Italic.ttf");
    // Only bold: better than nothing.
    assert(pickRegular(faces[0 .. 1]) == "/f/Bold.ttf");
    assert(pickRegular(null) == "");
}

/// Last resort for a generic monospace name on a system carrying none of
/// $(LREF genericMonospaceFamilies): match on the monospace trait alone and
/// take the first loadable regular face.
private string anyMonospaceFamily() @trusted nothrow
{
    if (!ct.ok)
        return "";

    // A CFNumber for the trait mask, wrapped in the traits sub-dictionary the
    // descriptor attributes expect.
    uint want = ctTraitMonoSpace;
    auto num = ct.numberCreate(null, kCFNumberSInt32Type, &want);
    if (num is null)
        return "";
    scope (exit) ct.release(num);

    auto traits = cfDict1(ct.kSymbolicTrait, num);
    if (traits is null)
        return "";
    scope (exit) ct.release(traits);

    auto attrs = cfDict1(ct.kTraits, traits);
    if (attrs is null)
        return "";
    scope (exit) ct.release(attrs);

    auto desc = ct.descCreate(attrs);
    if (desc is null)
        return "";
    scope (exit) ct.release(desc);

    auto matches = ct.descMatching(desc, null);
    if (matches is null)
        return "";
    scope (exit) ct.release(matches);

    const n = ct.arrayCount(matches);
    foreach (i; 0 .. n)
    {
        auto d = ct.arrayValueAt(matches, i);
        if (d is null)
            continue;
        const path = descPath(d);
        if (path.length == 0 || !isLoadableFontFile(path))
            continue;
        const t = descTraits(d);
        if ((t & (ctTraitBold | ctTraitItalic)) == 0)
            return path;
    }
    return "";
}

// ── live probes (macOS only; skipped when the frameworks are unavailable) ────

@("font_coretext.live.resolvesAGenericMonospaceFamily")
@system
unittest
{
    import std.file : exists;
    import sparkles.test_runner.skip : skipTest;

    if (!coreTextAvailable())
        skipTest("CoreText unavailable (no CoreFoundation/CoreText frameworks)");

    // The shared `--font monospace` default has to resolve on a stock Mac, and
    // to something raylib can actually open.
    const path = resolveFamilyList("monospace");
    assert(path.length != 0, "no generic monospace face resolved");
    assert(path.exists, "resolved a path that does not exist: " ~ path);
    assert(isLoadableFontFile(path), "resolved a collection: " ~ path);
}

@("font_coretext.live.unknownFamilyResolvesToNothing")
@system
unittest
{
    import sparkles.test_runner.skip : skipTest;

    if (!coreTextAvailable())
        skipTest("CoreText unavailable");

    // The property the mandatory-attribute set buys: a family that is not
    // installed must report nothing, not CoreText's nearest substitute.
    assert(familyFaces("Definitely Not An Installed Family 9x7") is null);
    assert(resolveFamilyList("Definitely Not An Installed Family 9x7") == "");
}

@("font_coretext.live.preferenceListFallsThroughUninstalledNames")
@system
unittest
{
    import sparkles.test_runner.skip : skipTest;

    if (!coreTextAvailable())
        skipTest("CoreText unavailable");

    // The regression this pins: "no match" is `""`, which is a NON-NULL empty
    // string, so `if (hit = resolve(name))` accepted it and the first
    // uninstalled name in a preference list ended the search. Every shared
    // default is a list led by a family most hosts do not have, so this made
    // font resolution fail on a machine that had a perfectly good fallback.
    const viaList = resolveFamilyList(
        "Definitely Not An Installed Family 9x7,Also Not Installed 4b2,monospace");
    const direct = resolveFamilyList("monospace");
    assert(viaList == direct,
        "a leading uninstalled name must not change the outcome");
    assert(viaList.length != 0, "the list should have fallen through to monospace");
}

@("font_coretext.live.charsetCoversAscii")
@system
unittest
{
    import sparkles.test_runner.skip : skipTest;

    if (!coreTextAvailable())
        skipTest("CoreText unavailable");

    const path = resolveFamilyList("monospace");
    if (path.length == 0)
        skipTest("no monospace face on this host");

    SmallBuffer!(int, 256, true) lo, hi;
    if (!charsetRanges(path, lo, hi))
        skipTest("CoreText reported no character set for " ~ path);

    assert(lo.length != 0, "empty coverage for " ~ path);
    // Every usable monospace face covers printable ASCII; if this fails the
    // bitmap decode is wrong, not the font.
    bool covers(int cp)
    {
        foreach (i; 0 .. lo.length)
            if (lo[][i] <= cp && cp <= hi[][i])
                return true;
        return false;
    }
    assert(covers('A') && covers('z') && covers('0'));
}

@("font_coretext.live.familyOfFileRoundTrips")
@system
unittest
{
    import sparkles.test_runner.skip : skipTest;

    if (!coreTextAvailable())
        skipTest("CoreText unavailable");

    const path = resolveFamilyList("monospace");
    if (path.length == 0)
        skipTest("no monospace face on this host");

    // The file resolves back to a family, and that family lists the file —
    // the round trip `variantPathsFor` depends on.
    const family = familyOfFile(path);
    assert(family.length != 0, "no family for " ~ path);

    bool listed = false;
    foreach (f; familyFaces(family))
        if (f.path == path)
            listed = true;
    assert(listed, family ~ " does not list " ~ path);
}
