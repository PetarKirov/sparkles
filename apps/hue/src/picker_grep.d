/**
The grep source's corpus: what content search is allowed to look at.

A grep source cannot be "the repository walk" the way the files source is.
A hue session's documents need not exist on disk — `hue pr` builds them from
a forge payload and git-history browsing will build them from object content
(`SRC6`) — and those are exactly the documents a reviewer most wants to
search. So the corpus is a $(B provider seam) (`PKC2`): the walk is one
provider among several, not the definition.

That is also why a result is addressed by $(LREF DocHandle) rather than by
path (`PKC3`). A path is a property some documents happen to have; the
handle is what every document has, and it is what survives a document that
only ever existed in memory.

Nothing here reads a file. Acquiring bytes is the scanner's job and happens
off the keystroke path; this module answers only "what is there, and how
would one get at it".
*/
module picker_grep;

import picker_sources : PickerTarget;

/**
Identifies a document inside one search generation.

Deliberately not a path, an index into some array the caller must also hold,
or a pointer. A generation renumbers, so a handle is only meaningful against
the corpus that issued it — which is why $(LREF DocCorpus) stamps its own
`generation` into every handle it hands out and refuses to resolve one from
an older corpus. A stale handle is then a caught error rather than a silent
read of whatever document now occupies that slot.
*/
struct DocHandle
{
    /// 1-based index into the issuing corpus; `0` is the null handle.
    uint index;
    /// The corpus generation this was issued against.
    uint generation;

    bool valid() const @safe pure nothrow @nogc => index != 0;
}

/// Where a document's bytes come from.
enum DocOrigin : ubyte
{
    /// On disk at `path`; the scanner reads it, capped (`PKC7`).
    file,
    /// Already in memory — a forge payload, a git object, an unsaved buffer.
    /// The bytes are BORROWED from the session, never copied into the corpus.
    memory,
}

/**
One searchable document, as the corpus describes it.

`source` is populated only for `DocOrigin.memory`. For a file the corpus
deliberately holds no bytes: a grep source re-reads per query (which is why
the size cap is 1 MiB rather than a cached grep's larger one, `PKC7`), and
holding the tree in memory would make the corpus the thing that has to be
invalidated when a file changes.
*/
struct GrepDoc
{
    DocHandle handle;
    /// Repository-relative for a file; a display label for a memory document
    /// (`PR #429 · src/app.d`). Always present — a row has to say something.
    string label;
    /// Absolute path, or `null` when the document is not on disk.
    string path;
    /// Borrowed bytes for `DocOrigin.memory`; empty for a file.
    const(char)[] source;
    DocOrigin origin;

    /// Whether the scanner can search this without touching the filesystem.
    bool resident() const @safe pure nothrow @nogc
        => origin == DocOrigin.memory;
}

/**
DbI contract for a corpus provider.

`length` and `describe` run while the corpus is assembled, not per
keystroke, so they may allocate. A provider never reads file content — it
says what exists and where the bytes would come from.
*/
enum bool isDocProvider(Provider) = is(typeof({
    Provider provider = Provider.init;
    size_t count = provider.length;
    GrepDoc doc = provider.describe(size_t.init);
}));

/** The repository's files, over the one shared walk (`PKC4`). */
struct RepoDocs
{
    /// Absolute repository root.
    string root;
    /// Repository-relative paths, in walk order.
    string[] paths;

    size_t length() const @safe pure nothrow @nogc => paths.length;

    GrepDoc describe(size_t index) const @safe
    {
        import std.path : buildPath;

        if (index >= paths.length)
            return GrepDoc.init;
        return GrepDoc(label: paths[index],
            path: buildPath(root, paths[index]),
            origin: DocOrigin.file);
    }
}

static assert(isDocProvider!RepoDocs);

/**
The session's in-memory documents (`SRC6`).

The bytes are borrowed: this provider holds slices the session owns, and is
only valid while that session does. A corpus is rebuilt per generation, so
the borrow never outlives a search.
*/
struct SessionDocs
{
    /// Display label and borrowed bytes, one pair per open document.
    string[] labels;
    const(char)[][] sources;

    size_t length() const @safe pure nothrow @nogc
        => labels.length < sources.length ? labels.length : sources.length;

    GrepDoc describe(size_t index) const @safe pure nothrow @nogc
    {
        if (index >= length)
            return GrepDoc.init;
        return GrepDoc(label: labels[index], source: sources[index],
            origin: DocOrigin.memory);
    }
}

static assert(isDocProvider!SessionDocs);

/**
The whole corpus one generation searches: every provider, one handle space.

Providers are concatenated in priority order — session documents first, so a
document the reviewer has open outranks the same path on disk when both are
present, and so a memory-only document is never shadowed by a file that
merely shares its name.
*/
struct DocCorpus
{
    private SessionDocs session_;
    private RepoDocs repo_;
    private uint generation_;

    /// The generation handles are stamped with. Bumped by `rebuild`.
    uint generation() const @safe pure nothrow @nogc => generation_;

    /// Total documents across every provider.
    size_t length() const @safe pure nothrow @nogc
        => session_.length + repo_.length;

    /**
    Re-assemble for a new generation.

    Bumping the generation is what invalidates every outstanding handle: the
    corpus a handle was issued against is gone, and `describe` says so
    rather than resolving the index against whatever now sits there.
    */
    void rebuild(SessionDocs session, RepoDocs repo) @safe pure nothrow @nogc
    {
        session_ = session;
        repo_ = repo;
        ++generation_;
    }

    /// The document at a flat corpus index, with its handle stamped in.
    GrepDoc at(size_t index) const @safe
    {
        GrepDoc doc;
        if (index < session_.length)
            doc = session_.describe(index);
        else if (index < length)
            doc = repo_.describe(index - session_.length);
        else
            return GrepDoc.init;
        doc.handle = DocHandle(cast(uint)(index + 1), generation_);
        return doc;
    }

    /**
    Resolve a handle this corpus issued.

    A handle from an older generation returns `GrepDoc.init` — the caller
    asked about a document that no longer has that number, and answering
    with whichever document now holds the index is the bug this exists to
    prevent (a row accepted just as a rescan lands would open the wrong
    file).
    */
    GrepDoc resolve(DocHandle handle) const @safe
    {
        if (!handle.valid || handle.generation != generation_
            || handle.index > length)
            return GrepDoc.init;
        return at(handle.index - 1);
    }
}

@("picker_grep.corpus.memoryDocumentsAreAddressableWithoutAPath")
@safe
unittest
{
    // The reason the corpus is a provider seam at all (`PKC2`/`SRC6`): a
    // `hue pr` document or a git-history revision has no path on disk, and
    // those are exactly the documents a reviewer wants to grep. A
    // path-keyed corpus cannot name them.
    static immutable string[2] labels = ["PR #429 · src/app.d", "HEAD~3 · lib.d"];
    static immutable string[2] bodies = ["void main() {}\n", "int x;\n"];
    auto session = SessionDocs(labels: labels[].dup,
        sources: [cast(const(char)[]) bodies[0], bodies[1]]);
    auto repo = RepoDocs(root: "/repo", paths: ["src/lib.d", "readme.md"]);

    DocCorpus corpus;
    corpus.rebuild(session, repo);
    assert(corpus.length == 4);

    // Session documents come first, so an open document is never shadowed
    // by a file that merely shares its name.
    const mem = corpus.at(0);
    assert(mem.origin == DocOrigin.memory);
    assert(mem.resident, "a memory document needs no filesystem read");
    assert(mem.path is null, "it has no path — that is the point");
    assert(mem.source == "void main() {}\n");
    assert(mem.handle.valid);

    const file = corpus.at(2);
    assert(file.origin == DocOrigin.file);
    assert(!file.resident);
    assert(file.path == "/repo/src/lib.d");
    assert(file.source.length == 0,
        "the corpus must not hold file bytes — the scanner re-reads, capped");

    // A handle round-trips through the corpus that issued it.
    assert(corpus.resolve(mem.handle).label == mem.label);
    assert(corpus.resolve(file.handle).label == file.label);
    assert(!corpus.resolve(DocHandle.init).handle.valid, "null handle");
}

@("picker_grep.corpus.aStaleHandleResolvesToNothing")
@safe
unittest
{
    // The failure this prevents is silent and specific: a rescan lands
    // between the moment a row is drawn and the moment it is accepted, the
    // corpus renumbers, and the old index now points at a DIFFERENT
    // document — so accepting opens the wrong file, with no error anywhere.
    // Stamping the generation into the handle turns that into a refusal.
    auto repoA = RepoDocs(root: "/repo", paths: ["a.d", "b.d"]);
    DocCorpus corpus;
    corpus.rebuild(SessionDocs.init, repoA);

    const held = corpus.at(0).handle;
    assert(corpus.resolve(held).label == "a.d");

    // A file appears at the front of the walk; index 0 is now someone else.
    auto repoB = RepoDocs(root: "/repo", paths: ["aardvark.d", "a.d", "b.d"]);
    corpus.rebuild(SessionDocs.init, repoB);
    assert(corpus.at(0).label == "aardvark.d", "the index really did move");

    const stale = corpus.resolve(held);
    assert(!stale.handle.valid,
        "a handle from the previous generation must not resolve");
    assert(stale.label is null,
        "and it must not silently resolve to the document now at that index");

    // Re-reading the same document through a fresh handle still works.
    assert(corpus.resolve(corpus.at(1).handle).label == "a.d");
}

@("picker_grep.target.aMemoryDocumentIsAValidTarget")
@safe pure nothrow @nogc
unittest
{
    // `PickerTarget.valid` used to be `path.length != 0`, which would have
    // rejected every memory-only document the moment grep could produce one.
    PickerTarget memoryRow;
    memoryRow.handle = DocHandle(3, 1);
    memoryRow.line = 12;
    assert(memoryRow.path is null);
    assert(memoryRow.valid, "a document with no path is still a target");

    assert(!PickerTarget.init.valid, "but nothing at all is not");
}

// ── binary detection (`PKC6`) ───────────────────────────────────────────────

/// How many leading bytes the content sniff looks at. The scanner has these
/// in hand from the read it was going to do anyway — the sniff must never
/// cost a second one.
enum size_t sniffBytes = 8192;

/// What the classifier decided about a document's bytes.
enum ContentVerdict : ubyte
{
    /// Searchable: no NUL, and the head is well-formed UTF-8.
    text,
    /// Skip it. Reporting a "match" inside a PNG is noise at best, and the
    /// stored window (`PKC11`) would be unprintable.
    binary,
}

/**
Classify a document's leading bytes (`PKC6`).

Two rules, in the order every grep in the survey applies them:

$(UL
$(LI a $(B NUL byte) means binary. This is the classic `grep`/Google Code
Search test, and it also catches UTF-16 and UTF-32 text, which hue cannot
render anyway;)
$(LI $(B invalid UTF-8) means binary. hue's corpus is UTF-8 or bytes, and
full encoding conversion is explicitly out of scope.)
)

$(B A truncated final sequence is not invalid.) `head` is a window, and a
window boundary lands mid-character routinely — a file whose 8192nd byte
falls inside a `é` is ordinary UTF-8, not a binary. Treating truncation as
corruption would reject text files by their length, which is the kind of
bug that shows up as "grep silently skips exactly the large files".

Pure and allocation-free: `std.utf` would throw, and this runs per file on
a worker with no exception path.
*/
ContentVerdict classifyContent(scope const(char)[] head) @safe pure nothrow @nogc
{
    size_t i;
    while (i < head.length)
    {
        const b = cast(ubyte) head[i];
        if (b == 0)
            return ContentVerdict.binary; // NUL: the classic test
        if (b < 0x80)
        {
            ++i;
            continue;
        }

        // Sequence length and the first continuation byte's legal range,
        // spelled out rather than derived: the narrow ranges are what reject
        // overlong forms (`0xC0`/`0xC1`, `0xE0 0x80`), UTF-16 surrogates
        // (`0xED 0xA0`) and code points above U+10FFFF (`0xF4 0x90`).
        size_t len;
        ubyte lo = 0x80, hi = 0xBF;
        if (b >= 0xC2 && b <= 0xDF)
            len = 2;
        else if (b == 0xE0) { len = 3; lo = 0xA0; }
        else if (b == 0xED) { len = 3; hi = 0x9F; }
        else if ((b >= 0xE1 && b <= 0xEC) || b == 0xEE || b == 0xEF)
            len = 3;
        else if (b == 0xF0) { len = 4; lo = 0x90; }
        else if (b >= 0xF1 && b <= 0xF3)
            len = 4;
        else if (b == 0xF4) { len = 4; hi = 0x8F; }
        else
            return ContentVerdict.binary; // continuation as lead, or 0xC0/0xC1/0xF5+

        // The window ended mid-character. That is a boundary, not corruption.
        if (i + len > head.length)
            return ContentVerdict.text;

        const c1 = cast(ubyte) head[i + 1];
        if (c1 < lo || c1 > hi)
            return ContentVerdict.binary;
        foreach (k; 2 .. len)
        {
            const c = cast(ubyte) head[i + k];
            if (c < 0x80 || c > 0xBF)
                return ContentVerdict.binary;
        }
        i += len;
    }
    return ContentVerdict.text;
}

/**
The whole admission test for a document (`PKC6`).

The path filter runs first because it is free and it is what makes grep and
the explorer agree about what exists: `isRenderable` is the same predicate
the document set uses, so a file the tree refuses to show is a file grep
refuses to search.

`head` is whatever the caller already read. Passing an empty slice runs the
path filter alone, which is the right answer before any I/O has happened.
*/
bool searchable(scope const(char)[] path, scope const(char)[] head)
    @safe pure nothrow
{
    import sparkles.docs.source_set : isRenderable;

    if (path.length && !isRenderable(path, twoslash: false))
        return false;
    return classifyContent(head) == ContentVerdict.text;
}

@("picker_grep.classify.nulAndInvalidUtf8AreBinary")
@safe pure nothrow @nogc
unittest
{
    assert(classifyContent("") == ContentVerdict.text, "an empty file is text");
    assert(classifyContent("void main() {}\n") == ContentVerdict.text);
    assert(classifyContent("héllo — ünïcode ✓\n") == ContentVerdict.text);

    // The classic test, and the one that also catches UTF-16/UTF-32 text.
    assert(classifyContent("PNG\x00\x1a\n") == ContentVerdict.binary);
    assert(classifyContent("\x00") == ContentVerdict.binary);

    // Malformed lead bytes.
    assert(classifyContent("\xFF\xFE") == ContentVerdict.binary);
    assert(classifyContent("\x80abc") == ContentVerdict.binary,
        "a continuation byte cannot lead");

    // Overlong forms, surrogates and out-of-range code points are what the
    // narrow first-continuation ranges exist to reject. A validator that
    // only checks `0x80..0xBF` accepts all three.
    assert(classifyContent("\xC0\xAF") == ContentVerdict.binary, "overlong /");
    assert(classifyContent("\xE0\x80\xAF") == ContentVerdict.binary, "overlong");
    assert(classifyContent("\xED\xA0\x80") == ContentVerdict.binary, "surrogate");
    assert(classifyContent("\xF4\x90\x80\x80") == ContentVerdict.binary,
        "beyond U+10FFFF");
    assert(classifyContent("\xF5\x80\x80\x80") == ContentVerdict.binary);
}

@("picker_grep.classify.aTruncatedSequenceIsABoundaryNotCorruption")
@safe pure nothrow @nogc
unittest
{
    // `head` is a WINDOW. A window boundary lands mid-character routinely,
    // and treating that as corruption would reject text files for being
    // long — which surfaces as "grep silently skips exactly the big files",
    // a symptom nobody attributes to the binary detector.
    static immutable full = "abé"; // 'é' is two bytes: C3 A9

    assert(classifyContent(full) == ContentVerdict.text);
    assert(classifyContent(full[0 .. $ - 1]) == ContentVerdict.text,
        "a 2-byte sequence cut after its lead is a boundary");

    static immutable four = "ab\U0001F600"; // 4-byte emoji
    assert(classifyContent(four) == ContentVerdict.text);
    foreach (cut; 1 .. 4)
        assert(classifyContent(four[0 .. $ - cut]) == ContentVerdict.text,
            "a 4-byte sequence cut anywhere is still a boundary");

    // But a truncation is only forgiven at the END. The same bytes followed
    // by more content are genuinely malformed.
    assert(classifyContent("ab\xC3" ~ "cd") == ContentVerdict.binary,
        "an unfinished sequence mid-buffer is corruption, not a boundary");
}

@("picker_grep.classify.pathFilterRunsBeforeTheBytes")
@safe pure nothrow
unittest
{
    // `isRenderable` is the predicate the document set already uses, so a
    // file the tree refuses to show is a file grep refuses to search — the
    // two panes cannot disagree about what the project contains.
    assert(searchable("src/app.d", "void main() {}\n"));
    assert(searchable("README.md", "# hi\n"));
    assert(!searchable("assets/logo.png", "\x89PNG\r\n"),
        "the extension alone is enough — no read needed");
    assert(!searchable("build/libfoo.so", "text that happens to be printable"),
        "a deny-listed extension is refused even when the bytes look fine");

    // Bytes still decide when the path is inconclusive: a `.txt` full of
    // NULs is not searchable however innocent its name.
    assert(!searchable("notes.txt", "a\x00b"));

    // No path, or no bytes yet: each half must be usable alone, because the
    // scanner applies the path filter BEFORE it has read anything.
    assert(searchable("src/app.d", ""), "path-only, pre-read");
    assert(searchable("", "plain bytes"), "bytes-only, e.g. a memory document");
}
