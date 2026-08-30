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
