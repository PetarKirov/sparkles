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

import sparkles.base.text.analysis : AnalysisCase;
import sparkles.fuzzy : CandidateId, RankedResult, ScoreBreakdown;
import sparkles.source_view.search : SearchPolicy;

import grep_classify : classifyLine, HitKind;
import picker_host : pickerTopK;
import picker_view : GrepRowText;

// The marker UDA is imported UNCONDITIONALLY: a module carrying it is
// compiled in every build, not only `-unittest`, so guarding this behind
// `version (unittest)` breaks the application build (`AGENTS.md`). The
// measurement API itself lives in the impl library and stays guarded.
import sparkles.test_runner.attributes : benchmark;

version (unittest)
    import sparkles.test_runner.bench : benchCase, Metric, Unit;

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

        // Validate the bytes that ARE here, then forgive only the ones that
        // are missing. Returning early on a short tail would accept whatever
        // it had not looked at — including a NUL, which is the classifier's
        // headline rule, and including bytes that are not continuations at
        // all. A truncation is a promise about the FUTURE of the buffer, not
        // an amnesty for its present.
        const avail = head.length - i;
        const check = len < avail ? len : avail;
        if (check > 1)
        {
            const c1 = cast(ubyte) head[i + 1];
            if (c1 < lo || c1 > hi)
                return ContentVerdict.binary;
            foreach (k; 2 .. check)
            {
                const c = cast(ubyte) head[i + k];
                if (c < 0x80 || c > 0xBF)
                    return ContentVerdict.binary;
            }
        }
        if (avail < len)
            return ContentVerdict.text; // valid so far; the window ended
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

// ── the scan (`PKC1`, `PKC10`, `PKC11`, `PKC12`, `PKC17`) ───────────────────

/// How a query is interpreted (`PKC9`). Classified once from the query, with
/// one visible fallback rung — never a ladder that silently retries.
enum GrepMode : ubyte
{
    /// A literal needle, spaces included (`PKC17`).
    plain,
    /// The bounded engine (`PKC16`). Not implemented yet.
    regex,
    /// Subsequence admission over the stored window.
    fuzzy,
}

/**
Whether a mode may run on the raw CPU pool (`PKC15`).

`RawJobFn` is `void function(void*) @safe nothrow @nogc`, so a mode that
cannot meet those attributes cannot be a pool job. Stating that per mode
from the first commit is deliberate: the regex arm is the one part of `P4`
with real schedule risk, and if it lands non-`@nogc` this degrades THAT MODE
to the synchronous path rather than forcing the whole scan off the pool.
*/
bool poolEligible(GrepMode mode) @safe pure nothrow @nogc
    => mode != GrepMode.regex;

/// Bytes of context stored around a hit (`PKC11`). Chosen so a row stays
/// inside `maxDpUnits` and scoring never silently degrades.
enum size_t windowBytes = 512;

/**
One hit: where it is. Deliberately small — hits are sorted and ranked, and
the context they display lives beside them in $(LREF GrepContext).
*/
struct GrepHit
{
    DocHandle doc;
    /// 1-based source line.
    uint line;
    /// 1-based **byte** column of the match within its line. True to the
    /// source, not to the trimmed window: what a reader pastes into
    /// `file:line:col` has to land where the match actually is.
    uint column;
    /// Absolute byte offset, so the preview seeks without rescanning
    /// (fff's `GrepMatch` carries the same field for the same reason).
    size_t offset;
    /// Whether the line DEFINES the matched name (`PKC14`). Classified in
    /// the scan, where it is nearly free; refined by tree-sitter on the
    /// selected row only.
    HitKind kind;

    /**
    Identity for the top-K's dedup.

    Mixes the document, line AND column. Keying on the document alone
    collides across every hit in a file, and `TopK` treats colliding ids as
    the same row — so a file with twenty matches would show one, and the
    list would freeze as later hits were folded into the first (`PKC12`).
    */
    ulong fingerprint() const @safe pure nothrow @nogc
    {
        static ulong mix(ulong h, ulong v) @safe pure nothrow @nogc
            => (h ^ v) * 0x100000001b3UL;

        ulong h = 0xcbf29ce484222325UL;
        h = mix(h, doc.index);
        h = mix(h, doc.generation);
        h = mix(h, line);
        h = mix(h, column);
        return h;
    }
}

/// The stored context for one hit — the row's visible text (`PKC11`).
struct GrepContext
{
    private char[windowBytes] bytes = void;
    /// Bytes actually stored.
    ushort length;
    /// Match position **within the stored window**.
    ushort matchStart;
    /// Match length within the window, clipped at its end.
    ushort matchLen;
    /// Whether text was dropped on each side — the row renders an ellipsis
    /// so a truncated line says so rather than looking complete
    /// (ripgrep's `--max-columns-preview` behaviour).
    bool elidedLeft, elidedRight;

    /// The stored text.
    const(char)[] text() const return @safe pure nothrow @nogc
        => bytes[0 .. length];
}

/**
Scan one document's bytes for a literal needle (`PKC17`).

Fills `hits`/`contexts` in parallel and returns how many were written,
stopping when either runs out — a document with more matches than the
caller has room for is truncated, not an error, and the caller decides
whether that matters.

Pure, `@nogc`, and clock-free: it can therefore run as a pool job
(`PKC15`), and it does no I/O — acquiring the bytes is the caller's job
(`PKC7`).

`startsWithFolded` comes from `sparkles.source_view.search`: grep owns its
scan, not its idea of what matches.
*/
size_t scanText(scope const(char)[] text, scope const(char)[] needle,
    AnalysisCase mode, DocHandle doc,
    scope GrepHit[] hits, scope GrepContext[] contexts)
    @safe pure nothrow @nogc
{
    import sparkles.source_view.search : startsWithFolded;

    if (needle.length == 0 || needle.length > text.length)
        return 0;

    size_t found;
    const room = hits.length < contexts.length ? hits.length : contexts.length;
    uint line = 1;
    size_t lineStart;
    // The current line's extent, computed ONCE per line rather than once per
    // hit. Re-deriving it at every match made a minified file — one enormous
    // line, many matches — cost O(hits x line): 4096 hits in a 1 MiB single
    // line took over twenty seconds. Cancellation is polled between FILES
    // (`PKC10`), so a quadratic file also delays the keystroke that
    // superseded it.
    size_t lineEnd = lineEndFrom(text, 0);
    size_t i;
    while (i + needle.length <= text.length && found < room)
    {
        if (i >= lineEnd)
        {
            ++line;
            lineStart = i + 1;
            lineEnd = lineEndFrom(text, lineStart);
            ++i;
            continue;
        }
        if (!startsWithFolded(text[i .. $], needle, mode))
        {
            ++i;
            continue;
        }

        const lineText = text[lineStart .. lineEnd];
        hits[found] = GrepHit(doc: doc, line: line,
            column: cast(uint)(i - lineStart + 1), offset: i,
            kind: classifyLine(lineText, i - lineStart, needle.length));
        contexts[found] = captureWindow(lineText, i - lineStart,
            needle.length);
        ++found;

        // Non-overlapping, like the in-document search. A needle cannot
        // contain a newline (the input bar refuses control bytes), but the
        // crossing is handled rather than assumed.
        const next = i + needle.length;
        while (i < next && i < text.length)
        {
            if (text[i] == '\n')
            {
                ++line;
                lineStart = i + 1;
                lineEnd = lineEndFrom(text, lineStart);
            }
            ++i;
        }
    }
    return found;
}

/// The offset of the newline ending the line that starts at `from`, or
/// `text.length` when the last line is unterminated.
private size_t lineEndFrom(scope const(char)[] text, size_t from)
    @safe pure nothrow @nogc
{
    size_t at = from;
    while (at < text.length && text[at] != '\n')
        ++at;
    return at;
}

/**
Store a bounded window of `lineText` around a match (`PKC11`).

Leading whitespace is dropped — an indented line otherwise spends its
window on indentation — but the hit's reported column is computed from the
untrimmed line, so trimming changes what is SHOWN and never what is
reported. A window that renamed the column would make `file:line:col`
land in the wrong place, which is the failure worth stating.

When the line still does not fit, the window slides to keep the match
visible and marks the sides it cut.
*/
private bool isContinuation(char c) @safe pure nothrow @nogc
    => (cast(ubyte) c & 0xC0) == 0x80;

private GrepContext captureWindow(scope const(char)[] lineText,
    size_t matchInLine, size_t matchLen) @safe pure nothrow @nogc
{
    GrepContext ctx;

    size_t from;
    while (from < lineText.length && from < matchInLine
        && (lineText[from] == ' ' || lineText[from] == '\t'))
        ++from;
    ctx.elidedLeft = from != 0;

    // Slide so the match stays visible on a long line.
    if (matchInLine >= from + windowBytes)
    {
        from = matchInLine > windowBytes / 4 ? matchInLine - windowBytes / 4 : 0;
        ctx.elidedLeft = from != 0;
    }

    size_t to = from + windowBytes;
    if (to >= lineText.length)
        to = lineText.length;
    else
        ctx.elidedRight = true;

    // Both edges are byte offsets derived from a BUDGET, so either can land
    // inside a multi-byte character — and then a row built from perfectly
    // valid source carries invalid UTF-8 into whatever paints it. Nudge each
    // edge to the next character boundary before slicing.
    while (from < to && isContinuation(lineText[from]))
        ++from;
    while (to > from && to < lineText.length && isContinuation(lineText[to]))
        --to;

    const span = lineText[from .. to];
    ctx.length = cast(ushort) span.length;
    ctx.bytes[0 .. span.length] = span;

    ctx.matchStart = matchInLine >= from
        ? cast(ushort)(matchInLine - from) : 0;
    const avail = ctx.length > ctx.matchStart ? ctx.length - ctx.matchStart : 0;
    ctx.matchLen = cast(ushort)(matchLen < avail ? matchLen : avail);
    return ctx;
}

@("picker_grep.scan.reportsTrueLineAndByteColumn")
@safe pure nothrow @nogc
unittest
{
    static immutable text = "alpha beta\ngamma alpha\n    alpha indented\n";
    GrepHit[8] hits = void;
    GrepContext[8] ctx = void;
    const n = scanText(text, "alpha", AnalysisCase.sensitive,
        DocHandle(1, 1), hits[], ctx[]);
    assert(n == 3, "three occurrences");

    // 1-based line and 1-based BYTE column, both true to the source.
    assert(hits[0].line == 1 && hits[0].column == 1);
    assert(hits[1].line == 2 && hits[1].column == 7);
    assert(hits[2].line == 3 && hits[2].column == 5,
        "the indented hit's column counts the indentation");

    // The absolute offset lets the preview seek without rescanning.
    assert(text[hits[1].offset .. hits[1].offset + 5] == "alpha");
    assert(text[hits[2].offset .. hits[2].offset + 5] == "alpha");
}

@("picker_grep.scan.trimmingChangesWhatIsShownNotWhatIsReported")
@safe pure nothrow @nogc
unittest
{
    // The window drops leading indentation so a row does not spend itself on
    // whitespace — but the COLUMN is computed from the untrimmed line. A
    // window that renamed the column would make `file:line:col` land in the
    // wrong place, and it would look right on screen the whole time.
    static immutable text = "\t\t    needle here\n";
    GrepHit[2] hits = void;
    GrepContext[2] ctx = void;
    const n = scanText(text, "needle", AnalysisCase.sensitive,
        DocHandle(1, 1), hits[], ctx[]);
    assert(n == 1);
    assert(hits[0].column == 7, "6 bytes of indentation, so column 7");

    assert(ctx[0].text == "needle here", "the window is trimmed");
    assert(ctx[0].elidedLeft, "and says it dropped something");
    assert(ctx[0].matchStart == 0, "the match is at the window's start");
    assert(ctx[0].matchLen == 6);
    assert(ctx[0].text[ctx[0].matchStart .. ctx[0].matchStart + ctx[0].matchLen]
        == "needle");
}

@("picker_grep.scan.aLongLineSlidesItsWindowAndSaysSo")
@safe pure nothrow @nogc
unittest
{
    // A minified file is one enormous line. The window has to keep the match
    // VISIBLE rather than storing the first 512 bytes and reporting a hit
    // nobody can see in the row.
    char[4000] buf = 'x';
    buf[3000 .. 3006] = "needle";
    const text = buf[];

    GrepHit[2] hits = void;
    GrepContext[2] ctx = void;
    const n = scanText(text, "needle", AnalysisCase.sensitive,
        DocHandle(1, 1), hits[], ctx[]);
    assert(n == 1);
    assert(hits[0].line == 1 && hits[0].column == 3001);

    assert(ctx[0].length <= windowBytes, "the window is bounded");
    assert(ctx[0].elidedLeft && ctx[0].elidedRight, "cut on both sides");
    const shown = ctx[0].text[ctx[0].matchStart
        .. ctx[0].matchStart + ctx[0].matchLen];
    assert(shown == "needle", "the match must be inside the stored window");
}

@("picker_grep.scan.hitsInOneFileHaveDistinctFingerprints")
@safe pure nothrow @nogc
unittest
{
    // `TopK` dedups by fingerprint. Keying on the document alone collides
    // across every hit in a file, so a file with twenty matches would show
    // one and the list would freeze as later hits folded into the first
    // (`PKC12`). Two hits on the SAME line differ only by column, which is
    // the case a document+line key would still get wrong.
    static immutable text = "alpha alpha\nalpha\n";
    GrepHit[8] hits = void;
    GrepContext[8] ctx = void;
    const n = scanText(text, "alpha", AnalysisCase.sensitive,
        DocHandle(7, 3), hits[], ctx[]);
    assert(n == 3);

    assert(hits[0].line == hits[1].line, "same line…");
    assert(hits[0].column != hits[1].column, "…different column");
    assert(hits[0].fingerprint != hits[1].fingerprint,
        "two hits on one line must not collide");
    assert(hits[1].fingerprint != hits[2].fingerprint);
    assert(hits[0].fingerprint != hits[2].fingerprint);
}

@("picker_grep.scan.foldingFollowsTheSharedCaseRule")
@safe pure nothrow @nogc
unittest
{
    // Grep owns its scan, NOT its idea of what matches: the predicate is
    // `startsWithFolded` from `sparkles.source_view.search`, so plain-mode
    // grep and the in-document search admit the same set. Two literal
    // predicates is how the two in-document searches diverged.
    static immutable text = "Alpha\nalpha\nALPHA\n";
    GrepHit[8] hits = void;
    GrepContext[8] ctx = void;

    assert(scanText(text, "alpha", AnalysisCase.simpleFold,
        DocHandle(1, 1), hits[], ctx[]) == 3, "folded: all three");
    assert(scanText(text, "alpha", AnalysisCase.sensitive,
        DocHandle(1, 1), hits[], ctx[]) == 1, "sensitive: only the exact one");
}

@("picker_grep.scan.spacesArePartOfTheNeedle")
@safe pure nothrow @nogc
unittest
{
    // `PKC17`: plain mode searches a literal, spaces included. An
    // AND-of-terms reading would match the second line too, and then have no
    // single column to report for it.
    static immutable text = "if (foo bar)\nfoo = 1; bar = 2;\n";
    GrepHit[8] hits = void;
    GrepContext[8] ctx = void;
    const n = scanText(text, "foo bar", AnalysisCase.sensitive,
        DocHandle(1, 1), hits[], ctx[]);
    assert(n == 1, "only the literal occurrence");
    assert(hits[0].line == 1);
}

@("picker_grep.scan.boundedByTheCallersRoom")
@safe pure nothrow @nogc
unittest
{
    // A work unit is one whole file (`PKC10`), and a caller's bank is
    // finite. Running out is truncation, not an error.
    static immutable text = "x\nx\nx\nx\nx\n";
    GrepHit[2] hits = void;
    GrepContext[2] ctx = void;
    assert(scanText(text, "x", AnalysisCase.sensitive,
        DocHandle(1, 1), hits[], ctx[]) == 2, "stops at the caller's room");

    GrepHit[8] big = void;
    GrepContext[8] bigCtx = void;
    assert(scanText(text, "x", AnalysisCase.sensitive,
        DocHandle(1, 1), big[], bigCtx[]) == 5);

    // Degenerate queries answer without scanning.
    assert(scanText(text, "", AnalysisCase.sensitive,
        DocHandle(1, 1), big[], bigCtx[]) == 0);
    assert(scanText("ab", "abcdef", AnalysisCase.sensitive,
        DocHandle(1, 1), big[], bigCtx[]) == 0);
}

@("picker_grep.mode.regexIsNotPoolEligibleYet")
@safe pure nothrow @nogc
unittest
{
    // `PKC15`, stated from the first commit rather than retrofitted: if the
    // bounded engine lands non-`@nogc`, THAT MODE loses the pool and the
    // design survives.
    assert(poolEligible(GrepMode.plain));
    assert(poolEligible(GrepMode.fuzzy));
    assert(!poolEligible(GrepMode.regex), "the bounded engine is not written");
}

// ── the scan schedule (`PKC10`) ─────────────────────────────────────────────

/// What one $(D GrepScan.step) did.
enum ScanStep : ubyte
{
    /// No scan is live.
    idle,
    /// Work happened; more remains.
    progressed,
    /// The corpus is exhausted for this generation.
    finished,
    /// A newer generation superseded this one mid-step.
    cancelled,
}

/**
The grep scan's schedule: one flight, resumable, cancellable per file.

Separate from `PickerScheduler` because that one dispatches `searchChunk`,
which is pure and clock-free and therefore $(B cannot read a file). Grep's
work unit is a whole document (`PKC10`), and acquiring its bytes is I/O.
What is shared is the discipline, not the code: a monotonic generation,
supersede-don't-queue, and a cursor that resumes.

Written as a shell with hooks so the schedule is testable without touching
a filesystem — the decisions (what next, when to stop, whether to keep a
result) are the part worth pinning, and they are pure.

$(B Cancellation is polled every file), not every eighth. fff's interval is
an artifact of its per-line loop; hue's unit is a file, so the natural place
to check is between them. And hue deliberately does $(B not) port fff's
"refuse to abort before two matches" rule: that exists because fff cannot
publish a partial page, and hue already publishes ranked partials — keeping
it would make a superseded query outlive its keystroke for no benefit.
*/
struct GrepScan
{
    private uint generation_;
    private size_t cursor_;
    private size_t total_;
    private size_t admitted_;
    private bool active_;

    /// The live generation. Bumped by `begin` and by `cancel`.
    uint generation() const @safe pure nothrow @nogc => generation_;
    /// How far through the corpus this generation has scanned.
    size_t cursor() const @safe pure nothrow @nogc => cursor_;
    /// Documents in the corpus this generation is walking.
    size_t total() const @safe pure nothrow @nogc => total_;
    /// Hits admitted so far this generation — the `332/2350` numerator.
    size_t admitted() const @safe pure nothrow @nogc => admitted_;
    /// Whether a scan is live.
    bool active() const @safe pure nothrow @nogc => active_;

    /**
    Start a generation over `total` documents, superseding any live scan.

    Single-flight: a keystroke does not queue behind the previous query's
    scan, it replaces it. Queueing would make the list lag by however many
    queries the user typed while it worked, which is the failure the whole
    generation discipline exists to prevent.
    */
    uint begin(size_t total) @safe pure nothrow @nogc
    {
        ++generation_;
        cursor_ = 0;
        admitted_ = 0;
        total_ = total;
        active_ = total != 0;
        return generation_;
    }

    /// Abandon the live scan without starting another. The generation still
    /// advances, so results already in flight are recognisably stale.
    void cancel() @safe pure nothrow @nogc
    {
        ++generation_;
        active_ = false;
        cursor_ = 0;
        total_ = 0;
    }

    /**
    Whether a result stamped `gen` still belongs to the live generation.

    The reason results carry it at all: a worker finishing after the user
    typed another character must have its page dropped, not merged into the
    newer query's results.
    */
    bool current(uint gen) const @safe pure nothrow @nogc
        => active_ && gen == generation_;

    /**
    Scan up to `budget` documents.

    `scanOne` returns how many hits that document admitted; `superseded` is
    polled $(B before every file) so a newer keystroke stops this scan
    within one document rather than at the end of the budget.
    */
    ScanStep step(Scan, Superseded = typeof(null))(size_t budget,
        scope Scan scanOne, scope Superseded superseded = null)
    {
        if (!active_)
            return ScanStep.idle;
        foreach (_; 0 .. budget)
        {
            static if (!is(Superseded == typeof(null)))
                if (superseded !is null && superseded())
                {
                    active_ = false;
                    return ScanStep.cancelled;
                }
            if (cursor_ >= total_)
                break;
            admitted_ += scanOne(cursor_);
            ++cursor_;
        }
        if (cursor_ >= total_)
        {
            active_ = false;
            return ScanStep.finished;
        }
        return ScanStep.progressed;
    }
}

@("picker_grep.scan.resumesWhereItStopped")
@safe nothrow @nogc
unittest
{
    // A scan that hits its budget must resume, not restart. Restarting is
    // the bug that looks like progress: every frame rescans the first N
    // files, the list keeps showing the same hits, and the scan never
    // reaches the end of a large tree.
    size_t[8] seen;
    size_t seenCount;
    size_t scanOne(size_t i) @safe nothrow @nogc
    {
        if (seenCount < seen.length)
            seen[seenCount++] = i;
        return 1;
    }

    GrepScan scan;
    scan.begin(5);
    assert(scan.active && scan.cursor == 0);

    assert(scan.step(2, &scanOne, null) == ScanStep.progressed);
    assert(scan.cursor == 2 && scan.admitted == 2);

    assert(scan.step(2, &scanOne, null) == ScanStep.progressed);
    assert(scan.cursor == 4);

    assert(scan.step(2, &scanOne, null) == ScanStep.finished);
    assert(scan.cursor == 5 && scan.admitted == 5);
    assert(!scan.active, "a finished scan is not live");
    assert(scan.step(2, &scanOne, null) == ScanStep.idle);

    // Every document was visited exactly once, in order.
    assert(seenCount == 5);
    foreach (i; 0 .. 5)
        assert(seen[i] == i, "documents must not be rescanned");
}

@("picker_grep.scan.cancellationIsPolledBeforeEveryFile")
@safe nothrow @nogc
unittest
{
    // `PKC10`. fff polls every eighth line because its unit is a line;
    // hue's unit is a file, so between files is the natural place — and it
    // bounds how long a superseded query keeps working to ONE document.
    // The flag flips PARTWAY THROUGH a step, which is what a keystroke
    // actually does. Polling once per step would satisfy a test that set it
    // beforehand while still scanning the whole budget after a supersede.
    size_t scanned;
    size_t scanOne(size_t) @safe nothrow @nogc { ++scanned; return 0; }
    bool superseded() @safe nothrow @nogc => scanned >= 2;

    GrepScan scan;
    scan.begin(100);
    assert(scan.step(50, &scanOne, &superseded) == ScanStep.cancelled,
        "a superseded scan stops inside the budget, not at its end");
    assert(scanned == 2,
        "it must notice between FILES — one more document at most, not 50");
    assert(!scan.active);

    // And a scan nobody supersedes runs its whole budget.
    scanned = 0;
    GrepScan quiet;
    quiet.begin(100);
    assert(quiet.step(5, &scanOne, null) == ScanStep.progressed);
    assert(scanned == 5);
}

@("picker_grep.scan.aNewGenerationSupersedesRatherThanQueues")
@safe nothrow @nogc
unittest
{
    // Single flight. Queueing would make the list lag by however many
    // queries were typed while the first scan worked.
    size_t scanOne(size_t) @safe nothrow @nogc => 1;

    GrepScan scan;
    const first = scan.begin(10);
    cast(void) scan.step(4, &scanOne, null);
    assert(scan.cursor == 4 && scan.admitted == 4);

    const second = scan.begin(10);
    assert(second != first, "the generation advances");
    assert(scan.cursor == 0, "the new query starts from the top");
    assert(scan.admitted == 0, "and does not inherit the old count");

    // Stale results must be recognisable so a worker finishing late has its
    // page dropped rather than merged into the newer query's.
    assert(!scan.current(first), "the superseded generation is not current");
    assert(scan.current(second));

    // Cancelling also advances, so nothing in flight looks current.
    scan.cancel();
    assert(!scan.current(second) && !scan.active);
}

@("picker_grep.scan.anEmptyCorpusFinishesRatherThanSpinning")
@safe nothrow @nogc
unittest
{
    size_t scanOne(size_t) @safe nothrow @nogc => 0;

    GrepScan scan;
    scan.begin(0);
    assert(!scan.active, "there is nothing to scan");
    assert(scan.step(8, &scanOne, null) == ScanStep.idle);
}

// ── ranking a hit (`PKC13`) ────────────────────────────────────────────────

/// What a definition is worth relative to a mention. A nudge, not a filter:
/// the classifier is a byte heuristic (`PKC14`), so a false positive must
/// cost a place in the order and never a missing row.
enum long definitionBonus = 40;

/// Base score every literal hit starts from. A literal match is exact by
/// construction — there is no match QUALITY to grade, unlike a fuzzy path
/// score — so the base is flat and the composite terms do the ordering.
enum long literalBase = 100;

/**
Score one hit (`PKC13`).

Builds a `ScoreBreakdown` directly rather than calling `rank`, because
`rank` is wrong for a content line and not merely mistuned:
`validateCandidate` requires `filenameOffset == 0`, and `rank` pays a
filename bonus keyed off that offset — so every admitted line would collect
the bonus and the term would carry no information at all (`PKC1`).

Structural, not statistical (`PKC13`). No term counts occurrences: term
frequency is an anti-signal in code, where a name repeated twenty times is
usually a loop body rather than the place you want.
*/
ScoreBreakdown grepScore(HitKind kind) @safe pure nothrow @nogc
{
    ScoreBreakdown score;
    score.base = literalBase;
    score.definition = kind == HitKind.definition ? definitionBonus : 0;
    score.total = score.base + score.definition;
    return score;
}

@("picker_grep.scan.hitsCarryTheirDefinitionKind")
@safe pure nothrow @nogc
unittest
{
    // The classifier runs in the scan, where it is nearly free (`PKC14`).
    // Both lines contain `Widget`; only one defines it, and the ranking has
    // to be able to tell them apart without a parse.
    static immutable text = "struct Widget\n{\n    Widget other;\n}\n";
    GrepHit[8] hits;
    GrepContext[8] ctx;
    const n = scanText(text, "Widget", AnalysisCase.sensitive,
        DocHandle(1, 1), hits[], ctx[]);
    assert(n == 2);

    assert(hits[0].kind == HitKind.definition, "line 1 declares it");
    assert(hits[1].kind == HitKind.mention, "line 3 uses it");
    assert(grepScore(hits[0].kind).total > grepScore(hits[1].kind).total,
        "so the declaration outranks the use");
}

@("picker_grep.classify.truncationForgivesMissingBytesNotWrongOnes")
@safe pure nothrow @nogc
unittest
{
    // Forgiving a cut sequence must not forgive the bytes that ARE present.
    // The first version returned `text` the moment the window ended before
    // the sequence did, without looking at what it had — so a NUL sitting
    // inside a truncated lead went unseen, and the classifier's own headline
    // rule silently did not apply.
    assert(classifyContent("\xF0\x00") == ContentVerdict.binary,
        "a NUL is a NUL even inside an incomplete sequence");
    assert(classifyContent("\xF0\x41") == ContentVerdict.binary,
        "0x41 is not a continuation byte, truncated or not");
    assert(classifyContent("\xE0\x80") == ContentVerdict.binary,
        "an overlong lead is still overlong when cut short");
    assert(classifyContent("\xED\xA0") == ContentVerdict.binary,
        "a surrogate lead is still a surrogate when cut short");

    // What genuinely IS a boundary still passes: the bytes present are
    // valid, only later ones are missing.
    assert(classifyContent("\xF0\x9F\x98") == ContentVerdict.text,
        "a valid 4-byte sequence cut before its last byte");
    assert(classifyContent("\xF0") == ContentVerdict.text,
        "cut immediately after the lead: nothing present to contradict it");
    assert(classifyContent("ab\xC3") == ContentVerdict.text);
}

@("picker_grep.scan.windowsAreValidUtf8")
@safe pure nothrow @nogc
unittest
{
    // The window is sliced at byte offsets computed from a budget, so both
    // edges can land inside a multi-byte character. That produces invalid
    // UTF-8 in a row the terminal then has to paint — from source text that
    // was perfectly valid.
    char[8] cell = "é"; // 2 bytes: C3 A9
    char[1200] buf = void;
    size_t n;
    buf[n++] = 'x';
    foreach (_; 0 .. 400)
    {
        buf[n++] = cell[0];
        buf[n++] = cell[1];
    }
    foreach (c; "aneedle")
        buf[n++] = c;
    const text = buf[0 .. n];

    GrepHit[2] hits;
    GrepContext[2] ctx;
    assert(scanText(text, "needle", AnalysisCase.sensitive,
        DocHandle(1, 1), hits[], ctx[]) == 1);

    assert(classifyContent(ctx[0].text) == ContentVerdict.text,
        "a window sliced mid-character is invalid UTF-8");
    const shown = ctx[0].text[ctx[0].matchStart
        .. ctx[0].matchStart + ctx[0].matchLen];
    assert(shown == "needle", "and the match must still be located correctly");
}

@("picker_grep.scan.denseMatchesOnALongLineStayLinear")
@safe
unittest
{
    // A minified file is one enormous line with many matches, and TWO
    // separate re-scans made it quadratic: the line end was re-derived per
    // hit, and `classifyLine` walked the whole line looking for the end of
    // its first word — because a line of identifier bytes IS one word. 4096
    // hits in 1 MiB took over twenty seconds; both are bounded now.
    //
    // This asserts the RESULT, not the clock. The cost is tracked by
    // `picker_grep.scan.bench` below, where a regression is a number to
    // compare rather than a threshold to tune.
    enum size_t hits = 4096;
    auto buf = new char[](1024 * 1024);
    buf[] = 'x';
    const stride = buf.length / hits;
    foreach (k; 0 .. hits)
        buf[k * stride .. k * stride + 2] = "ab";

    auto found = new GrepHit[](hits);
    auto ctx = new GrepContext[](hits);
    const n = scanText(buf, "ab", AnalysisCase.sensitive,
        DocHandle(1, 1), found, ctx);
    assert(n == hits, "every needle found");
    assert(found[0].line == 1 && found[$ - 1].line == 1, "all on one line");
    assert(found[$ - 1].column > found[0].column, "columns advance");
    // The classifier is bounded, so a match far into the line is a mention
    // rather than an accident of where the walk happened to stop.
    assert(found[$ - 1].kind == HitKind.mention);
}

@("picker_grep.scan.bench")
@benchmark @safe
unittest
{
    // Three shapes with different failure modes: an ordinary source file,
    // the dense-single-line case that was quadratic twice over, and a file
    // with no match at all — the common case, since most files do not
    // contain the needle, so the miss path is where a whole-tree scan
    // actually spends itself.
    //
    // Each case is registered from its own function because `benchCase`
    // runs AFTER this body returns: closures sharing this frame read it
    // once it is gone, which segfaults inside the scan rather than
    // reporting anything useful.
    registerScanCase("many-lines", "wrapped", wrappedCorpus(), "ab", true);
    registerScanCase("one-long-line", "minified", minifiedCorpus(), "ab", true);
    registerScanCase("no-match", "wrapped", wrappedCorpus(), "zzzz", false);
}

version (unittest)
{
    /// 256 KiB of 64-byte lines, a needle every 256 bytes.
    private char[] wrappedCorpus() @safe
    {
        auto text = new char[](256 * 1024);
        text[] = 'x';
        foreach (k; 0 .. text.length / 64)
            text[k * 64 + 63] = '\n';
        foreach (k; 0 .. 512)
            text[k * 256 .. k * 256 + 2] = "ab";
        return text;
    }

    /// 1 MiB on ONE line with 4096 needles — the shape that was quadratic.
    private char[] minifiedCorpus() @safe
    {
        auto text = new char[](1024 * 1024);
        text[] = 'x';
        foreach (k; 0 .. 4096)
            text[k * 256 .. k * 256 + 2] = "ab";
        return text;
    }

    /**
    One registered case, owning everything it touches.

    A class rather than a lambda on purpose: `benchCase` runs the case after
    the registering function has returned, so a closure over that frame reads
    a frame that is gone — which shows up as a segfault inside the scan
    rather than as anything that names the real problem. Binding `timed` and
    `after` to a heap object (`&c.run`) is the pattern the other benchmarks
    in this repo use, for this reason.
    */
    private final class ScanCase
    {
        char[] text;
        string needle;
        GrepHit[] hits;
        GrepContext[] ctx;
        bool expectHits;

        this(char[] text, string needle, bool expectHits) @safe
        {
            this.text = text;
            this.needle = needle;
            this.expectHits = expectHits;
            this.hits = new GrepHit[](8192);
            this.ctx = new GrepContext[](8192);
        }

        size_t run() @safe
            => scanText(text, needle, AnalysisCase.sensitive,
                DocHandle(1, 1), hits, ctx);

        void check(ref size_t n) @safe
        {
            assert(expectHits == (n != 0),
                "the measured scan did not do the work it claims");
        }
    }

    /// Register one case, owning its own corpus and result bank.
    private void registerScanCase(string name, string shape, char[] text,
        string needle, bool expectHits) @safe
    {
        auto c = new ScanCase(text, needle, expectHits);
        benchCase(name: name,
            labels: ["shape": shape, "outcome": expectHits ? "hits" : "miss"],
            timed: &c.run,
            after: &c.check,
            metrics: [Metric(Unit("B"), text.length, Metric.Mode.rate)]);
    }
}

// ── acquiring bytes (`PKC7`) ───────────────────────────────────────────────

/// Default cap on a single document (`PKC7`). Lower than a caching grep's
/// because hue re-reads per query: fff can afford a large cap because it
/// pays the read once.
enum size_t defaultMaxFileBytes = 1024 * 1024;

/// The ceiling a user may raise the cap to. Past this the re-read-per-query
/// model stops being interactive whatever the scan costs.
enum size_t hardMaxFileBytes = 10 * 1024 * 1024;

/**
Read at most `buf.length` bytes of `path` (`PKC7`).

Returns the filled prefix, empty on any failure — a file that vanished
between the walk and the scan is an ordinary event in a live tree, not an
error worth a diagnostic.

Whole-read, capped, rather than memory-mapped: ripgrep's reasoning applies
with more force here, because hue holds documents open while a file changes
underneath it. A map that faults mid-scan takes the process down; a short
read only truncates a row.
*/
const(char)[] readCapped(string path, scope return char[] buf) @trusted
{
    import std.stdio : File;

    if (buf.length == 0)
        return null;
    try
    {
        auto f = File(path, "rb");
        auto got = f.rawRead(buf);
        return got;
    }
    catch (Exception)
        return null;
}

// ── the finder (`PKC1`) ────────────────────────────────────────────────────

/// Which corpus the picker is showing. A `final switch` on this, never a
/// template: templating `PickerHost` on its source would duplicate the
/// scheduler's generation slots — megabytes of workspace — once per source.
enum PickerSource : ubyte
{
    files,
    grep,
}

/**
The grep source: corpus, scan, ranking, and row resolution.

Re-enters the shared picker only with `RankedResult`s (`PKC1`). Content
lines never touch `validateCandidate`/`rank`, whose `filenameOffset == 0`
invariant would award every admitted line the filename bonus.
*/
struct GrepFinder
{
    @disable this(this);

    private DocCorpus corpus_;
    private GrepScan scan_;
    private string root_;
    private string[] paths_;          // repo-relative, owned
    private GrepHit[] hits_;          // one recycled bank
    private GrepContext[] contexts_;
    private size_t found_;
    private char[] readBuf_;
    private char[256] needle_ = void;
    private size_t needleLen_;
    private AnalysisCase mode_;
    private size_t maxFileBytes_ = defaultMaxFileBytes;

    /// Documents the live generation is walking.
    size_t corpusTotal() const @safe pure nothrow @nogc => corpus_.length;
    /// Hits admitted so far.
    size_t hitCount() const @safe pure nothrow @nogc => found_;
    /// Whether a scan is still running.
    bool searching() const @safe pure nothrow @nogc => scan_.active;

    /// Raise the per-file cap (`PKC7`), clamped to `hardMaxFileBytes`.
    void maxFileBytes(size_t value) @safe nothrow
    {
        maxFileBytes_ = value == 0 ? defaultMaxFileBytes
            : value > hardMaxFileBytes ? hardMaxFileBytes : value;
        if (readBuf_.length != maxFileBytes_)
            readBuf_ = new char[](maxFileBytes_);
    }

    /**
    Point the corpus at `root`, over the same walk the files source uses
    (`PKC4`), plus the session's in-memory documents (`PKC2`).

    Allocation happens here — a user action, under the startup/shutdown
    carve-out — never on a keystroke.
    */
    void openCorpus(string root, scope const(string)[] includeGlobs = null,
        scope const(string)[] excludeGlobs = null,
        SessionDocs session = SessionDocs.init) @safe
    {
        import sparkles.build_primitives.glob_walk : globWalkGitRepository;

        root_ = root;
        paths_ = null;
        auto walk = globWalkGitRepository(root, includeGlobs, excludeGlobs);
        while (!walk.empty)
        {
            paths_ ~= walk.front;
            walk.popFront();
        }
        corpus_.rebuild(session, RepoDocs(root: root, paths: paths_));

        if (hits_.length == 0)
        {
            hits_ = new GrepHit[](pickerTopK * 4);
            contexts_ = new GrepContext[](pickerTopK * 4);
        }
        if (readBuf_.length == 0)
            readBuf_ = new char[](maxFileBytes_);
    }

    /// Start a generation for `query`. An empty query scans nothing — a
    /// content search with no needle would admit the whole tree.
    void begin(scope const(char)[] query, in SearchPolicy policy) @safe nothrow
    {
        needleLen_ = query.length < needle_.length
            ? query.length : needle_.length;
        needle_[0 .. needleLen_] = query[0 .. needleLen_];
        mode_ = policy.caseFor(query);
        found_ = 0;
        if (needleLen_ == 0)
        {
            scan_.cancel();
            return;
        }
        scan_.begin(corpus_.length);
    }

    /// Abandon the live scan.
    void cancel() @safe pure nothrow @nogc { scan_.cancel(); found_ = 0; }

    /**
    Advance the scan by up to `budget` documents.

    One whole document per unit (`PKC10`); `superseded` is polled before
    each, so a newer keystroke costs at most one more file.
    */
    ScanStep step(size_t budget,
        scope bool delegate() @safe nothrow @nogc superseded = null) @system
    {
        return scan_.step(budget,
            (size_t index) => scanOne(index), superseded);
    }

    private size_t scanOne(size_t index) @trusted
    {
        if (found_ >= hits_.length)
            return 0;
        const doc = corpus_.at(index);
        if (!doc.handle.valid)
            return 0;

        const(char)[] bytes;
        if (doc.resident)
            bytes = doc.source;
        else
        {
            if (!searchable(doc.label, null))
                return 0; // the path filter alone, before any I/O
            try
                bytes = readCapped(doc.path, readBuf_);
            catch (Exception)
                return 0;
        }
        const head = bytes.length < sniffBytes ? bytes : bytes[0 .. sniffBytes];
        if (classifyContent(head) != ContentVerdict.text)
            return 0;

        const n = scanText(bytes, needle_[0 .. needleLen_], mode_,
            doc.handle, hits_[found_ .. $], contexts_[found_ .. $]);
        found_ += n;
        return n;
    }

    /// Where an accepted row goes (`PKC3`).
    PickerTarget resolve(size_t index) @safe
    {
        if (index >= found_)
            return PickerTarget.init;
        const hit = hits_[index];
        const doc = corpus_.resolve(hit.doc);
        return PickerTarget(path: doc.path, line: hit.line,
            column: hit.column, handle: hit.doc);
    }

    /// The row's rendered form for the view.
    GrepRowText rowText(size_t index) @safe
    {
        if (index >= found_)
            return GrepRowText.init;
        const hit = hits_[index];
        ref const ctx = contexts_[index];
        return GrepRowText(label: corpus_.resolve(hit.doc).label,
            context: ctx.text, line: hit.line, column: hit.column,
            matchStart: ctx.matchStart, matchLen: ctx.matchLen,
            elidedLeft: ctx.elidedLeft, elidedRight: ctx.elidedRight,
            definition: hit.kind == HitKind.definition);
    }

    /**
    The current page, ranked (`PKC13`).

    Sorted by composite score, definitions first, ties broken by corpus
    order so the list is stable while a scan is still admitting hits — a
    page that reshuffles under the reader is worse than a page that grows.
    */
    size_t page(scope RankedResult[] out_) @safe
    {
        import std.algorithm.sorting : sort;

        const n = found_ < out_.length ? found_ : out_.length;
        if (found_ == 0)
            return 0;
        auto order = new size_t[](found_);
        foreach (i; 0 .. found_)
            order[i] = i;
        // Score descending, then corpus order — an explicit total order
        // rather than a sort's incidental stability. A page that reshuffles
        // under the reader while a scan is still admitting hits is worse
        // than one that only grows.
        sort!((a, b) {
            const sa = grepScore(hits_[a].kind).total;
            const sb = grepScore(hits_[b].kind).total;
            return sa != sb ? sa > sb : a < b;
        })(order);
        foreach (i; 0 .. n)
        {
            const src = order[i];
            out_[i] = RankedResult(id: CandidateId(cast(uint) src),
                corpusIndex: src, score: grepScore(hits_[src].kind));
        }
        return n;
    }
}

@("picker_grep.finder.scansARealTreeAndRanksDefinitionsFirst")
@system
unittest
{
    // The first test that touches a filesystem: everything above is pure.
    // It pins the seam the rest of the picker sees — corpus in, ranked rows
    // and resolvable targets out (`PKC1`).
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const root = buildPath(tempDir(), "hue-grep-" ~ randomUUID.toString);
    mkdirRecurse(buildPath(root, "src"));
    scope (exit) rmdirRecurse(root);
    write(buildPath(root, ".gitignore"), "ignored/\n*.bin\n");
    write(buildPath(root, "src", "widget.d"),
        "struct Widget\n{\n    int n;\n}\n");
    write(buildPath(root, "src", "use.d"),
        "void f()\n{\n    Widget w;\n}\n");
    write(buildPath(root, "notes.md"), "Widget is a thing\n");
    write(buildPath(root, "blob.bin"), "Widget\x00binary\n");

    GrepFinder finder;
    finder.openCorpus(root);
    assert(finder.corpusTotal >= 4, "the walk found the tree");

    finder.begin("Widget", SearchPolicy.init);
    ScanStep outcome;
    do
        outcome = finder.step(64);
    while (outcome == ScanStep.progressed);
    assert(outcome == ScanStep.finished);

    assert(finder.hitCount == 3,
        "three text hits; the gitignored `.bin` is not searched at all");

    RankedResult[16] page;
    const n = finder.page(page[]);
    assert(n == 3);

    // `PKC13`: the declaration outranks both mentions.
    const top = finder.rowText(page[0].corpusIndex);
    assert(top.definition, "the declaration ranks first");
    assert(top.label == "src/widget.d");
    assert(top.line == 1);
    assert(page[0].score.total > page[1].score.total);

    // `PKC3`: the accepted row names a location, not merely a file.
    const target = finder.resolve(page[0].corpusIndex);
    assert(target.valid);
    assert(target.path == buildPath(root, "src/widget.d"));
    assert(target.line == 1 && target.column == 8,
        "`struct ` is 7 bytes, so `Widget` starts at column 8");
    assert(target.handle.valid, "and carries its document handle");

    // An empty query admits nothing: a content search with no needle would
    // otherwise return the whole tree.
    finder.begin("", SearchPolicy.init);
    assert(!finder.searching && finder.hitCount == 0);
}

@("picker_grep.finder.binaryAndOversizeDocumentsAreSkipped")
@system
unittest
{
    // The two ways a document is refused, both without a second read
    // (`PKC6`/`PKC7`).
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const root = buildPath(tempDir(), "hue-grep-skip-" ~ randomUUID.toString);
    mkdirRecurse(root);
    scope (exit) rmdirRecurse(root);

    // A NUL-bearing file whose EXTENSION says nothing — only the byte sniff
    // can refuse it.
    write(buildPath(root, "data.txt"), "needle\x00more needle\n");
    write(buildPath(root, "ok.txt"), "needle\n");

    GrepFinder finder;
    finder.openCorpus(root);
    finder.begin("needle", SearchPolicy.init);
    ScanStep outcome;
    do
        outcome = finder.step(64);
    while (outcome == ScanStep.progressed);

    assert(finder.hitCount == 1,
        "the NUL-bearing document is refused despite its `.txt` name");
    assert(finder.rowText(0).label == "ok.txt");
}
