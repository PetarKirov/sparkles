/**
The resolution machine: a fileset resolved by requests and responses, with
no effect of its own (FSM1–FSM7).

The machine never touches a file system. `step` advances it until it needs
I/O, has a result to hand over, or has spent its budget, and says which. When
it needs I/O, `batch` holds the requests, all arising from one directory
(FSM3); a driver performs them, in any order and concurrently if it likes,
and answers each through `entry`, `listed`, `statted` or `failed` before the
next `step`. Its modules import nothing that performs I/O; the test
`fileset.machine.FSM1.importsNothingEffectful` reads their sources to check.

A resolution walks the start roots of the fileset's `Plan` depth first. Each
entered directory is one frame: listed, its entries sorted by bytes and
evaluated (a `stat` batch only for entries whose kind or verdict needs one,
FSA4, or whose metadata the scheme declared, FSO4), then its subdirectories
listed in one batch and resolved in order. A frame is handed over as a unit
(`StepKind.unit`): its path, its members and entered subdirectories in the
scheme's declared order (FSM5, FSS1), and whether it is an empty directory,
entered and holding neither a member nor an entered subdirectory (FSV4). A
stream's unit comes once its subdirectories are listed, before their units;
a fold's after them, and a fold ends with the directories above the start
roots and the fileset root (FSS3). An entry that could not be read is handed
over as `StepKind.incomplete`, and the resolution continues (FSE1–FSE3); a
bound exceeded or a request a driver cannot perform ends it with a
`ResolutionError` (FSM2, FSM7).

All storage is allocated when the machine is made, sized by
`ResolutionLimits`; no step allocates (invariant 2), and running out of it is
an error, not growth.
*/
module sparkles.build_primitives.fileset.machine;

import sparkles.base.buffer : HeapBuffer;
import sparkles.base.io.errors : ErrorKind;
import sparkles.base.vfs.types : EntryKind, Stat, StatMask;

import sparkles.base.unique : Unique;
import sparkles.build_primitives.fileset.fso : EntryOrder, FsoFingerprint, FsoKind, FsoMetadata, FsoNode,
    SchemeShape, Traversal, precedes;
import sparkles.build_primitives.fileset.ignore : IgnoreLimits, IgnoreScopes, IgnoreState, ScopeError;
import sparkles.build_primitives.fileset.pattern : MatchScratch;
import sparkles.build_primitives.fileset.plan : Plan, plan, rootState;
import sparkles.build_primitives.fileset.value : DirVerdict, EntryFacts, FileVerdict, Fileset,
    FilesetEvaluator, Filesets;

/// The request kinds (FSM2). The set is open: a driver answers a kind it
/// cannot perform with `unsupported`, never by omitting the answer.
enum RequestKind : ubyte
{
    readDir,  /// open a directory and list it
    stat,     /// stat an entry, never following it
    readlink, /// read a link's target, answered by `Resolution.linkRead`
    readFile, /// read a `.gitignore` into `Resolution.fileRoom` (FSM4, FSI)
}

/// One request. Names are valid until the next `step`.
struct Request
{
    RequestKind kind;      ///
    uint dir;              /// the directory it is relative to; `noDir` for the fileset root
    const(char)[] name;    /// one entry name, or a path beneath the fileset root when `dir` is `noDir`
    uint target;           /// `readDir`: the id the opened directory takes
    /// `stat`: what to fill; `readDir`: `StatMask.identity` asks for the
    /// opened directory's identity too, answered with `identified` (D6)
    StatMask mask;
    bool throughLink;      /// `readDir`: `name` is a link the root's policy may follow
}

/// `Request.dir` of a root's `readDir`: relative to the fileset root.
enum uint noDir = uint.max;

/// `UnitEntry.child` of an entry that is not a subdirectory.
enum uint noChild = uint.max;

/**
One entry of a unit (FSM5): a member, or a subdirectory the resolution
entered. Valid until the next `step`.
*/
struct UnitEntry
{
    const(char)[] name; ///
    /// The node (FSO1). A file's executable bit and a link's target are
    /// filled only when the scheme declares `FsoMetadata.executable` and
    /// `FsoMetadata.linkTarget`; otherwise they read `false` and `null`.
    FsoNode node;
    bool hasMtime; /// whether `mtimeNs` was filled: `FsoMetadata.mtime`, on a file or link
    long mtimeNs;  ///
    /// Whether `fingerprint` was filled: `FsoMetadata.fingerprint`, on a file
    /// whose backend reports both times and its identity.
    bool hasFingerprint;
    FsoFingerprint fingerprint; /// FSC2
    /// A subdirectory's rank among the unit's subdirectories in the order
    /// their own units arrived; `noChild` for a file or link. A fold's
    /// children's values are found by it.
    uint child = noChild;
}

/// The bounds of a resolution (FSM7), and the storage it is given.
struct ResolutionLimits
{
    uint maxDepth = 64;          /// directory nesting beneath the fileset root
    uint maxNameLength = 255;    /// bytes of one entry name
    uint maxPending = 4096;      /// requests in one batch
    uint maxEntries = 1 << 16;   /// entries held at once
    uint maxFrames = 1 << 12;    /// directories held at once
    uint maxNameBytes = 1 << 22; /// bytes of names and paths held at once
    /// The `.gitignore` scope arena (FSI2), made only for a fileset with a
    /// `gitignored` leaf.
    IgnoreLimits ignore;
}

/// Why a resolution failed.
enum ResolutionErrorCode : ubyte
{
    none,               ///
    depthExceeded,      /// `maxDepth` (FSM7)
    nameTooLong,        /// `maxNameLength` (FSM7)
    tooManyPending,     /// `maxPending` (FSM7)
    capacityExceeded,   /// the storage `ResolutionLimits` sized
    unsupportedRequest, /// a driver cannot perform `kind` (FSM2)
    unanswered,         /// a driver stepped without answering a request
    staleCursor,        /// a cursor from another resolution, or an old one (FSM6)
    schemeFailed,       /// the consuming scheme failed, and the resolution is wrong (FSE1)
}

/// A resolution failure.
struct ResolutionError
{
    ResolutionErrorCode code; ///
    RequestKind kind;         /// for `unsupportedRequest`
    string context;           /// a static explanation
}

/// What `step` stopped for.
enum StepKind : ubyte
{
    needIO,     /// answer every request of `batch`, then step again
    /// a directory is resolved: read `unitPath`, `unitEntries` (or
    /// `unitMembers`), `unitEmpty` and `unitDir`
    unit,
    incomplete, /// an entry could not be read: read `incompletePath`, `incompleteKind`
    /// the budget is spent, or a directory was retired; step again to
    /// continue
    budget,
    done,       /// the resolution is complete
    /// a `.gitignore` rule decided an entry (only when tracing, FSI3): read
    /// `decisionPath`, `decisionIsDir`, `decisionExcluded`, `decisionSource`,
    /// `decisionLine` and `decisionPattern`
    ignoreDecision,
    /// a stream's directory and everything beneath it are done, its
    /// handle still alive (only when the scheme declared it): read
    /// `leftPath`
    leave,
}

/// Where a resolution is (FSM6). Valid only for the resolution that made it,
/// and only until the step it was passed to returns.
struct Cursor
{
    private ulong resolution;
    private ulong sequence;
}

/**
One resolution of one fileset. Move-only; it allocates its storage when it
is made and nothing after.
*/
struct Resolution
{
    @disable this(this);

    /**
    Prepares to resolve `f` of `sets`, within `limits`. `followLinks` says
    the root's policy follows links beneath it (FSD6's `symlinks =
    beneath`): a link is then also tried as a directory. `traceIgnores`
    asks for a `StepKind.ignoreDecision` for each entry a `.gitignore` rule
    decides (FSI3). `shape` is what the consuming scheme declared: the
    order of a unit's entries (FSS1), the metadata its members need (FSS2),
    and whether a directory's unit comes before its subdirectories' or after
    them (FSS3).

    A fold sees the fileset root last, as one unit. When the plan starts
    beneath it, the directories above the start roots are handed over too,
    each holding the subdirectories through which a start root that held
    anything was reached, and the fileset root always, even empty.

    A fileset with a `gitignored` leaf makes the machine read `.gitignore`
    files: before a start root is listed, that of the fileset root and of
    each directory down to it, and after a directory is listed, its own,
    unless a scope already excluded it. Each read is one `readFile` batch.
    */
    this(ref const Filesets sets, Fileset f, ResolutionLimits limits = ResolutionLimits.init,
        bool followLinks = false, bool traceIgnores = false, SchemeShape shape = SchemeShape.init)
        @safe nothrow @nogc
    {
        import core.atomic : atomicOp;
        import sparkles.base.unique : makeUnique;

        lim = limits;
        follow = followLinks;
        this.shape = shape;
        fold = shape.traversal == Traversal.fold;
        statMask = shape.metadata & FsoMetadata.fingerprint
            ? cast(StatMask)(StatMask.mtime | StatMask.identity | StatMask.change)
            : shape.metadata & FsoMetadata.mtime ? StatMask.mtime : StatMask.basic;
        ev = FilesetEvaluator(sets, f);
        words = cast(uint) ev.stateWords;
        id = atomicOp!"+="(nextId, 1);
        ignWord = ev.gitignoredWord;
        if (ignWord != uint.max)
        {
            ign = IgnoreScopes(sets.casePolicy, lim.ignore);
            ignScratch = makeUnique!MatchScratch();
            scopePathBuf.length = (lim.maxNameLength + 1) * (lim.maxDepth + 1) + gitignoreName.length;
            trace = traceIgnores;
        }

        entries.length = lim.maxEntries;
        frames.length = lim.maxFrames;
        names.length = lim.maxNameBytes;
        states.length = (lim.maxEntries + lim.maxFrames + 2) * (words ? words : 1);
        requests.length = lim.maxPending;
        answers.length = lim.maxPending;
        scratch.length = words ? words : 1;
        pathBuf.length = (lim.maxNameLength + 1) * (lim.maxDepth + 1) + gitignoreName.length + 1;

        // The plan's roots, kept as names at the bottom of the name arena.
        auto p = plan(sets, f);
        foreach (r; 0 .. p.length)
        {
            const root = p[r];
            if (namesTop + root.length > names.length)
            {
                latch(ResolutionErrorCode.capacityExceeded, "the plan's roots exceed maxNameBytes");
                break;
            }
            names[][namesTop .. namesTop + root.length] = root[];
            rootSpans ~= Span(namesTop, cast(uint) root.length);
            namesTop += cast(uint) root.length;
        }

        const ancCap = cast(uint) rootSpans.length + lim.maxDepth + 2;
        unitOrder.length = lim.maxEntries + ancCap;
        if (fold && !(rootSpans.length == 1 && rootSpans[0].length == 0))
        {
            // The directories above the start roots, the fileset root first.
            anc.length = lim.maxDepth + 2;
            ancEntries.length = ancCap;
            anc[0] = Anc(Span(0, 0), 0);
            ancTop = 1;
        }
    }

    /// The cursor to start from.
    Cursor start() const @safe pure nothrow @nogc => Cursor(id, 0);

    /// The requests to answer after `StepKind.needIO`.
    const(Request)[] batch() const return @safe pure nothrow @nogc
        => requests[][0 .. pending];

    /// The id of a directory whose handle the driver may close: the last one
    /// `step` finished with, or `noDir`. Valid until the next `step`.
    uint retired() const @safe pure nothrow @nogc => retired_;

    // ------------------------------------------------------------ answers

    /// Adds one entry to the listing `readDir` request `req` asked for.
    void entry(uint req, scope const(char)[] name, EntryKind kind) @safe nothrow @nogc
    {
        if (failed_ || req >= pending)
            return;
        if (name.length > lim.maxNameLength)
            return latch(ResolutionErrorCode.nameTooLong, "an entry name exceeds maxNameLength");
        if (entriesTop == entries.length)
            return latch(ResolutionErrorCode.capacityExceeded, "the entries exceed maxEntries");
        const at = putName(name);
        if (at == uint.max)
            return;
        Entry e;
        e.name = Span(at, cast(uint) name.length);
        e.kind = kind;
        e.tag = req;
        entries[entriesTop++] = e;
    }

    /// Completes `readDir` request `req`: every entry was added.
    void listed(uint req) @safe nothrow @nogc
    {
        if (req < pending)
            answers[req] = Answer(true, ErrorKind.other);
    }

    /// Gives the identity of the directory `readDir` request `req` opened,
    /// when the request's mask asked for it (D6).
    void identified(uint req, ulong device, ulong inode) @safe nothrow @nogc
    {
        if (req >= pending)
            return;
        auto f = &frames[requests[req].target];
        f.device = device;
        f.inode = inode;
        f.identified = true;
    }

    /// Answers `stat` request `req`.
    void statted(uint req, in Stat st) @safe nothrow @nogc
    {
        if (req >= pending)
            return;
        answers[req] = Answer(true, ErrorKind.other);
        auto e = &entries[requests[req].target];
        e.kind = st.kind;
        // Only a regular file carries the executable bit (FSO1); a link's
        // mode is not its own.
        e.executable = st.kind == EntryKind.regular && st.executable;
        e.statted = true;
        e.hasMtime = st.hasMtime;
        e.mtimeNs = st.mtimeNs;
        e.hasFingerprint = st.hasMtime && st.hasIdentity && st.hasCtime;
        e.fingerprint = FsoFingerprint(st.size, st.device, st.inode, st.mtimeNs, st.ctimeNs);
    }

    /// Answers `readlink` request `req` with the link's target, which is
    /// copied (FSO2: it is data, never followed).
    void linkRead(uint req, scope const(char)[] target) @safe nothrow @nogc
    {
        if (failed_ || req >= pending)
            return;
        answers[req] = Answer(true, ErrorKind.other);
        const at = putName(target);
        if (at == uint.max)
            return;
        auto e = &entries[requests[req].target];
        e.target = Span(at, cast(uint) target.length);
        e.hasTarget = true;
    }

    /// The room a `readFile` request's file is read into; valid until the
    /// next `step`.
    char[] fileRoom() return @safe nothrow @nogc => ign.room;

    /// Answers `readFile` request `req`: the file's first `length` bytes are
    /// in `fileRoom`, and `whole` says there were no more.
    void fileRead(uint req, size_t length, bool whole) @safe nothrow @nogc
    {
        if (req >= pending)
            return;
        answers[req] = Answer(true, ErrorKind.other);
        fileLength = length;
        fileWhole = whole;
    }

    /// Answers request `req` with a failure. `ErrorKind.unsupported` ends the
    /// resolution (FSM2); any other kind makes the entry incomplete (FSE1).
    void failed(uint req, ErrorKind kind) @safe nothrow @nogc
    {
        if (req >= pending)
            return;
        if (kind == ErrorKind.unsupported)
        {
            unsupportedKind = requests[req].kind;
            return latch(ResolutionErrorCode.unsupportedRequest, "a driver cannot perform a request");
        }
        answers[req] = Answer(true, kind);
    }

    // ------------------------------------------------------------ results

    /// The directory a `StepKind.leave` ends, relative to the fileset root.
    const(char)[] leftPath() const return @safe pure nothrow @nogc
        => names[][leftPath_.start .. leftPath_.end];

    /// The driver's id of the directory a `StepKind.leave` ends.
    uint leftDir() const @safe pure nothrow @nogc => leftDir_;

    /// The unit's directory, relative to the fileset root (`""` for it).
    const(char)[] unitPath() const return @safe pure nothrow @nogc
        => names[][unitPath_.start .. unitPath_.end];

    /// The unit's member files and links, by name, in byte order.
    auto unitMembers() const return @safe pure nothrow @nogc
    {
        static struct Members
        {
            private const(Entry)[] es;
            private const(char)[] text;
            private size_t at;

            bool empty() const scope @safe pure nothrow @nogc => at == es.length;
            const(char)[] front() const return scope @safe pure nothrow @nogc
                => text[es[at].name.start .. es[at].name.end];
            void popFront() scope @safe pure nothrow @nogc
            {
                ++at;
                skip();
            }

            private void skip() scope @safe pure nothrow @nogc
            {
                while (at < es.length && !es[at].member)
                    ++at;
            }
        }

        auto m = Members(unitSlice, names[], 0);
        m.skip();
        return m;
    }

    /**
    The unit's entries in the scheme's declared order (FSM5, FSS1): its
    members, and the subdirectories the resolution entered. A fold receives
    each such subdirectory's unit before this one, and `UnitEntry.child`
    says which it was.
    */
    auto unitEntries() const return @safe pure nothrow @nogc
    {
        static struct Entries
        {
            private const(Entry)[] es;
            private const(uint)[] order;
            private const(char)[] text;
            private FsoMetadata meta;

            bool empty() const @safe pure nothrow @nogc => order.length == 0;
            size_t length() const @safe pure nothrow @nogc => order.length;
            void popFront() @safe pure nothrow @nogc { order = order[1 .. $]; }
            UnitEntry front() const return @safe pure nothrow @nogc
            {
                const e = &es[order[0]];
                UnitEntry u;
                u.name = text[e.name.start .. e.name.end];
                u.child = e.child;
                if (e.child != noChild)
                    u.node = FsoNode.directory();
                else if (e.kind == EntryKind.symlink)
                    u.node = FsoNode.symlink(meta & FsoMetadata.linkTarget && e.hasTarget
                        ? text[e.target.start .. e.target.end] : null);
                else
                    u.node = FsoNode.regular(meta & FsoMetadata.executable && e.executable);
                if (meta & FsoMetadata.mtime && e.hasMtime && e.child == noChild)
                {
                    u.hasMtime = true;
                    u.mtimeNs = e.mtimeNs;
                }
                if (meta & FsoMetadata.fingerprint && e.hasFingerprint && e.child == noChild
                    && e.kind == EntryKind.regular)
                {
                    u.hasFingerprint = true;
                    u.fingerprint = e.fingerprint;
                }
                return u;
            }
        }

        return Entries(unitSlice, unitOrder[][0 .. unitOrderLength], names[], shape.metadata);
    }

    /// Whether the unit's directory is empty in the sense of FSV4.
    bool unitEmpty() const @safe pure nothrow @nogc => unitEmpty_;

    /// The id of the unit's directory, whose handle the driver holds until
    /// it is retired; `noDir` for a directory above the start roots, which
    /// was never opened.
    uint unitDir() const @safe pure nothrow @nogc => unitDir_;

    /// The path of the entry that could not be read, and why.
    const(char)[] incompletePath() const return @safe pure nothrow @nogc
        => pathBuf[][0 .. incompleteLength];
    /// ditto
    ErrorKind incompleteKind() const @safe pure nothrow @nogc => incompleteKind_;

    /// The entry a `.gitignore` rule decided (`StepKind.ignoreDecision`),
    /// relative to the fileset root, and whether it is a directory.
    const(char)[] decisionPath() const return @safe pure nothrow @nogc
        => pathBuf[][0 .. decisionLength];
    /// ditto
    bool decisionIsDir() const @safe pure nothrow @nogc => decisionIsDir_;
    /// Whether the deciding rule excludes the entry, or re-includes it.
    bool decisionExcluded() const @safe pure nothrow @nogc => decisionExcluded_;
    /// The `.gitignore` that declared the deciding rule, relative to the
    /// fileset root, its 1-based line, and its pattern as translated (FSI3).
    const(char)[] decisionSource() const return @safe pure nothrow @nogc
        => ign.sourceOf(ign.rule(decisionRule).scope_);
    /// ditto
    uint decisionLine() const @safe pure nothrow @nogc => ign.rule(decisionRule).line;
    /// ditto
    const(char)[] decisionPattern() const return @safe pure nothrow @nogc
        => ign.patternOf(decisionRule);

    /// The most `.gitignore` scopes, and bytes of their text, held at once
    /// (FSI2), and the rule lines skipped because no fileset pattern
    /// expresses them (A15).
    uint ignorePeakScopes() const @safe pure nothrow @nogc => ign.peakScopes;
    /// ditto
    uint ignorePeakTextBytes() const @safe pure nothrow @nogc => ign.peakTextBytes;
    /// ditto
    uint ignoreSkippedRules() const @safe pure nothrow @nogc => ign.skippedRules;

    /// The error after `step` failed.
    ResolutionError error() const @safe pure nothrow @nogc
        => ResolutionError(code, unsupportedKind, context);

    // ------------------------------------------------------------ stepping

    /**
    Advances by at most `budget` units of work (an entry evaluated is one),
    and says why it stopped. Fails for a stale cursor (FSM6) and for every
    fatal error of the resolution; never allocates.
    */
    bool step(ref const Filesets sets, ref Cursor cursor, size_t budget, out StepKind kind)
        @safe nothrow @nogc
    in (budget > 0, "a step needs a budget")
    {
        if (cursor.resolution != id || cursor.sequence != sequence)
        {
            code = ResolutionErrorCode.staleCursor;
            context = "the cursor is not this resolution's latest";
            return false;
        }
        ++sequence;
        cursor.sequence = sequence;
        retired_ = noDir;
        const ok = advance(sets, budget, kind);
        return ok && !failed_;
    }

private:
    static struct Span
    {
        uint start, length;
        uint end() const @safe pure nothrow @nogc => start + length;
    }

    static struct Entry
    {
        Span name;
        Span target;       // a link's target, once read
        EntryKind kind;
        uint tag;          // the request that listed it, then its child frame
        uint state = uint.max; // a subdirectory's evaluation state
        uint child = noChild;  // an entered subdirectory's rank (UnitEntry.child)
        long mtimeNs;
        FsoFingerprint fingerprint;
        DirVerdict verdict;
        ErrorKind error = ErrorKind.other;
        bool executable, statted, member, needStat, needKind, failed, linkDir;
        bool needLink, hasTarget, hasMtime, hasFingerprint, reported;
        bool whole;        // its whole content is selected (D5)
    }

    // A directory above the start roots (a fold's): its path, a prefix of a
    // root's, and where its entries start in `ancEntries`.
    static struct Anc
    {
        Span path;
        uint first;
    }

    enum Phase : ubyte
    {
        listing,   // its readDir is in the batch
        scopeRead, // its `.gitignore` read is in the batch
        evaluate,  // entries being evaluated
        stats,     // its stat batch is out
        report,    // reporting entries whose stat failed
        descend,   // about to list its subdirectories
        children,  // its children are listed; resolving them in order
        complete,  // handing it over
    }

    static struct Frame
    {
        Span path;
        uint parent = uint.max;
        uint depth;
        uint state = uint.max;
        uint entries, entryCount;
        uint children, childCount, nextChild;
        uint cursor;
        uint memberCount, liveChildren;
        Phase phase;
        bool acceptAll, failed, throughLink, scopeChecked, emitted, left;
        bool whole; // its whole content is selected, so emptiness is reported (D5)
        bool viaLink, identified; // reached through a followed link; `device`/`inode` set
        ulong device, inode;      // its identity, asked for when links are followed (D6)
        uint parentEntry = uint.max; // its entry in the parent's listing
        uint tagRequest;             // its readDir's index in the batch
        ErrorKind error = ErrorKind.other;
        uint entryMark, nameMark, stateMark;
        IgnoreScopes.Mark ignMark;
    }

    static struct Answer
    {
        bool given;
        ErrorKind error;
    }

    static shared ulong nextId;

    ResolutionLimits lim;
    bool follow;
    SchemeShape shape;
    bool fold;
    StatMask statMask;
    FilesetEvaluator ev;
    uint words;
    ulong id, sequence;

    HeapBuffer!Entry entries;
    HeapBuffer!Frame frames;
    HeapBuffer!char names;
    HeapBuffer!ulong states;
    HeapBuffer!Request requests;
    HeapBuffer!Answer answers;
    HeapBuffer!ulong scratch;
    HeapBuffer!char pathBuf;
    HeapBuffer!Span rootSpans;

    // `.gitignore` scopes (FSI), when the fileset has a `gitignored` leaf.
    enum string gitignoreName = ".gitignore";
    uint ignWord = uint.max;
    IgnoreScopes ign;
    Unique!MatchScratch ignScratch;
    HeapBuffer!char scopePathBuf;
    IgnoreScopes.Mark rootIgnMark;
    size_t fileLength;
    bool fileWhole;
    Span scopeName;   // the `.gitignore` entry being read
    // A start root's prefix: the `.gitignore` of each directory above it.
    bool prefixActive, prefixRead;
    Span prefixRoot;
    uint prefixPos, prefixState;
    ulong prefixWord;
    // Tracing (FSI3).
    bool trace, decisionPending, decisionIsDir_, decisionExcluded_;
    uint decisionRule;
    size_t decisionLength;
    uint entriesTop, framesTop, namesTop, statesTop;
    uint pending;
    BatchKind batchKind;
    uint batchFrame;

    uint current = uint.max; // the frame being worked on
    uint nextRoot;
    uint retired_ = noDir;

    // The unit handed over: entries of `entries` or of `ancEntries`, and
    // the order of those it holds.
    HeapBuffer!uint unitOrder;
    uint unitOrderLength, unitFirst, unitCount;
    Span unitPath_, leftPath_;
    uint unitDir_ = noDir, leftDir_ = noDir;
    bool unitAnc, unitEmpty_;

    // A fold's directories above the start roots (`Anc`), innermost last,
    // and their entries; `ancPop` says the innermost was just handed over.
    HeapBuffer!Anc anc;
    HeapBuffer!Entry ancEntries;
    uint ancTop, ancEntriesTop;
    bool ancPop;
    size_t incompleteLength;
    ErrorKind incompleteKind_;

    bool failed_;
    ResolutionErrorCode code;
    RequestKind unsupportedKind;
    string context;

    enum BatchKind : ubyte { none, root, stats, children, scope_, prefix }

    void latch(ResolutionErrorCode c, string why) @safe pure nothrow @nogc
    {
        if (failed_)
            return;
        failed_ = true;
        code = c;
        context = why;
    }

    uint putName(scope const(char)[] s) @safe nothrow @nogc
    {
        if (namesTop + s.length > names.length)
        {
            latch(ResolutionErrorCode.capacityExceeded, "names exceed maxNameBytes");
            return uint.max;
        }
        const at = namesTop;
        names[][at .. at + s.length] = s[];
        namesTop += cast(uint) s.length;
        return at;
    }

    uint allocState() @safe nothrow @nogc
    {
        if (statesTop + words > states.length)
        {
            latch(ResolutionErrorCode.capacityExceeded, "states exceed their storage");
            return uint.max;
        }
        const at = statesTop;
        statesTop += words;
        return at;
    }

    ulong[] stateOf(uint at) return @safe nothrow @nogc => states[][at .. at + words];

    bool request(Request r) @safe nothrow @nogc
    {
        if (pending == requests.length)
        {
            latch(ResolutionErrorCode.tooManyPending, "a batch exceeds maxPending");
            return false;
        }
        requests[pending] = r;
        answers[pending] = Answer.init;
        ++pending;
        return true;
    }

    // The main loop: returns `true` with `kind` set, or `false` on an error.
    bool advance(ref const Filesets sets, size_t budget, out StepKind kind) @safe nothrow @nogc
    {
        if (failed_)
            return false;
        if (pending && !absorb(sets))
            return false;
        size_t spent;
        for (;;)
        {
            if (failed_)
                return false;
            if (pendingReport)
            {
                pendingReport = false;
                kind = StepKind.incomplete;
                return true;
            }
            if (current == uint.max)
            {
                if (prefixActive)
                {
                    if (continuePrefix(sets))
                    {
                        kind = StepKind.needIO;
                        return true;
                    }
                    if (failed_)
                        return false;
                    if (pending)
                    {
                        kind = StepKind.needIO;
                        return true;
                    }
                    continue;
                }
                if (fold)
                {
                    if (ancPop)
                        finishAncestor();
                    if (failed_)
                        return false;
                    if (nextAncestor())
                    {
                        kind = StepKind.unit;
                        return true;
                    }
                }
                if (nextRoot == rootSpans.length)
                {
                    kind = StepKind.done;
                    return !failed_;
                }
                if (fold && !pushAncestors(rootSpans[nextRoot]))
                    return false;
                startRoot(sets);
                if (failed_)
                    return false;
                if (pending)
                {
                    kind = StepKind.needIO;
                    return true;
                }
                continue;
            }
            auto f = &frames[current];
            final switch (f.phase)
            {
                case Phase.listing:
                    // Answered by `absorb`; a failed root reports here.
                    assert(0, "a listed frame is never current");
                case Phase.scopeRead:
                    assert(0, "a frame reading its .gitignore is answered by absorb");
                case Phase.evaluate:
                    if (!f.scopeChecked)
                    {
                        f.scopeChecked = true;
                        if (issueScopeRead(*f))
                        {
                            kind = StepKind.needIO;
                            return true;
                        }
                        if (failed_)
                            return false;
                    }
                    while (f.cursor < f.entryCount)
                    {
                        if (spent == budget)
                        {
                            kind = StepKind.budget;
                            return true;
                        }
                        ++spent;
                        evaluate(sets, *f, entries[f.entries + f.cursor]);
                        ++f.cursor;
                        if (ign.overflowed)
                            latch(ResolutionErrorCode.capacityExceeded,
                                "the .gitignore positions exceed IgnoreLimits.maxPositions");
                        if (failed_)
                            return false;
                        if (decisionPending)
                        {
                            decisionPending = false;
                            kind = StepKind.ignoreDecision;
                            return true;
                        }
                    }
                    if (issueStats(*f))
                    {
                        kind = StepKind.needIO;
                        return true;
                    }
                    f.phase = Phase.descend;
                    break;
                case Phase.stats:
                    assert(0, "a frame awaiting stats is answered by absorb");
                case Phase.report:
                    while (f.cursor < f.entryCount)
                    {
                        auto e = &entries[f.entries + f.cursor];
                        ++f.cursor;
                        if (e.failed && !e.reported)
                        {
                            e.reported = true;
                            reportIncomplete(*f, e.name);
                            incompleteKind_ = e.error;
                            kind = StepKind.incomplete;
                            return true;
                        }
                    }
                    // A link only its stat revealed may still need its
                    // target read.
                    if (issueStats(*f))
                    {
                        kind = StepKind.needIO;
                        return true;
                    }
                    if (failed_)
                        return false;
                    f.phase = Phase.descend;
                    break;
                case Phase.descend:
                    if (issueChildren(*f))
                    {
                        kind = StepKind.needIO;
                        return true;
                    }
                    if (failed_)
                        return false;
                    f.phase = Phase.complete;
                    break;
                case Phase.children:
                    if (!fold && !f.emitted)
                    {
                        // A stream sees a directory before its children
                        // (FSS3), once their listings say which it holds.
                        f.emitted = true;
                        emitFrame(current);
                        kind = StepKind.unit;
                        return true;
                    }
                    if (f.nextChild < f.childCount)
                    {
                        const c = f.children + f.nextChild++;
                        auto child = &frames[c];
                        if (child.failed)
                        {
                            if (child.throughLink && linkIsFile(child.error))
                                break; // a link to a file: already judged as one
                            reportIncomplete(*f, entryOfChild(*f, c).name);
                            incompleteKind_ = child.error;
                            kind = StepKind.incomplete;
                            return true;
                        }
                        current = c;
                        break;
                    }
                    // Every child is done: free their storage.
                    framesTop = f.children;
                    entriesTop = f.entryMark;
                    namesTop = f.nameMark;
                    statesTop = f.stateMark;
                    if (ign.ready)
                        ign.release(f.ignMark);
                    f.phase = Phase.complete;
                    break;
                case Phase.complete:
                    // One directory is retired per step.
                    if (retired_ != noDir)
                    {
                        kind = StepKind.budget;
                        return true;
                    }
                    if (!fold && shape.leave)
                    {
                        // A stream that hears a directory end sees it
                        // first, if it has not, and then hears it end, both
                        // while its handle is alive.
                        if (!f.emitted)
                        {
                            f.emitted = true;
                            emitFrame(current);
                            kind = StepKind.unit;
                            return true;
                        }
                        if (!f.left)
                        {
                            f.left = true;
                            leftPath_ = f.path;
                            leftDir_ = current;
                            kind = StepKind.leave;
                            return true;
                        }
                    }
                    const emit = !f.emitted;
                    if (emit)
                        emitFrame(current);
                    retired_ = current;
                    current = f.parent;
                    if (current == uint.max)
                    {
                        // A root: free everything it used, and give it to
                        // the directory above it.
                        framesTop = 0;
                        entriesTop = 0;
                        statesTop = 0;
                        namesTop = rootsEnd;
                        if (ign.ready)
                            ign.release(rootIgnMark);
                        if (fold && ancTop && !addAncestorEntry(frames[0].path))
                            return false;
                    }
                    if (emit)
                    {
                        kind = StepKind.unit;
                        return true;
                    }
                    break;
            }
        }
    }

    uint rootsEnd() const @safe pure nothrow @nogc
        => rootSpans.length ? rootSpans[$ - 1].end : 0;

    // Starts the next root: issues its readDir, or the first read of the
    // `.gitignore` files above it; `false` when it issued nothing.
    bool startRoot(ref const Filesets sets) @safe nothrow @nogc
    {
        const span = rootSpans[nextRoot++];
        const root = names[][span.start .. span.end];
        const st = allocState();
        if (st == uint.max)
            return false;
        const verdict = rootState(ev, sets, root, stateOf(st), scratch[]);
        if (verdict == DirVerdict.skip)
        {
            statesTop = 0;
            return false;
        }
        if (ign.ready)
        {
            rootIgnMark = ign.mark;
            if (root.length)
            {
                // The scopes above the root apply to it: read them first.
                prefixActive = true;
                prefixRead = false;
                prefixRoot = span;
                prefixPos = 0;
                prefixState = st;
                prefixWord = IgnoreState.init.word;
                return continuePrefix(sets);
            }
        }
        return openRoot(span, st, verdict);
    }

    // ------------------------------------------------- a fold's ancestors

    // Hands over the innermost directory above the start roots if no root
    // left lies beneath it: `true` when it did. One that holds nothing is
    // dropped, unless it is the fileset root.
    bool nextAncestor() @safe nothrow @nogc
    {
        while (ancTop)
        {
            const a = anc[ancTop - 1];
            if (nextRoot < rootSpans.length)
            {
                const p = names[][a.path.start .. a.path.end];
                const r = names[][rootSpans[nextRoot].start .. rootSpans[nextRoot].end];
                if (p.length == 0 || (r.length > p.length && r[0 .. p.length] == p && r[p.length] == '/'))
                    return false;
            }
            const count = ancEntriesTop - a.first;
            if (count == 0 && ancTop > 1)
            {
                --ancTop;
                continue;
            }
            unitAnc = true;
            unitFirst = a.first;
            unitCount = count;
            unitPath_ = a.path;
            unitDir_ = noDir;
            // Never whole: a plan starts beneath a directory only when it is not.
            unitEmpty_ = false;
            sortUnit();
            ancPop = true;
            return true;
        }
        return false;
    }

    // Completes handing over the innermost ancestor: drops its entries and
    // gives it to the one above it.
    void finishAncestor() @safe nothrow @nogc
    {
        ancPop = false;
        const a = anc[--ancTop];
        ancEntriesTop = a.first;
        if (ancTop)
            addAncestorEntry(a.path);
    }

    // Adds the directory `path` as an entry of the innermost ancestor.
    bool addAncestorEntry(Span path) @safe nothrow @nogc
    {
        const p = names[][path.start .. path.end];
        uint at = cast(uint) p.length;
        while (at > 0 && p[at - 1] != '/')
            --at;
        if (ancEntriesTop == ancEntries.length)
        {
            latch(ResolutionErrorCode.capacityExceeded, "the directories above the roots exceed their storage");
            return false;
        }
        Entry e;
        e.name = Span(path.start + at, path.length - at);
        e.kind = EntryKind.directory;
        e.child = ancEntriesTop - anc[ancTop - 1].first;
        ancEntries[ancEntriesTop++] = e;
        return true;
    }

    // Pushes the directories between the innermost ancestor and the root
    // `span`, which lies beneath it.
    bool pushAncestors(Span span) @safe nothrow @nogc
    {
        if (!ancTop)
            return true;
        const r = names[][span.start .. span.end];
        const from = anc[ancTop - 1].path.length;
        foreach (i; from + 1 .. r.length)
        {
            if (r[i] != '/')
                continue;
            if (ancTop == anc.length)
            {
                latch(ResolutionErrorCode.depthExceeded, "a start root is deeper than maxDepth");
                return false;
            }
            anc[ancTop++] = Anc(Span(span.start, cast(uint) i), ancEntriesTop);
        }
        return true;
    }

    // ------------------------------------------------------------ units

    // Hands over frame `fi` as the unit.
    void emitFrame(uint fi) @safe nothrow @nogc
    {
        const f = &frames[fi];
        unitAnc = false;
        unitFirst = f.entries;
        unitCount = f.entryCount;
        unitPath_ = f.path;
        unitDir_ = fi;
        unitEmpty_ = f.whole && f.memberCount == 0 && f.liveChildren == 0;
        sortUnit();
    }

    const(Entry)[] unitSlice() const return @safe pure nothrow @nogc
        => unitAnc ? ancEntries[][unitFirst .. unitFirst + unitCount]
            : entries[][unitFirst .. unitFirst + unitCount];

    // Orders the unit's members and subdirectories as the scheme declared.
    void sortUnit() @safe nothrow @nogc
    {
        import std.algorithm.sorting : sort;

        const es = unitSlice;
        uint n;
        foreach (i, ref e; es)
            if (e.member || e.child != noChild)
                unitOrder[n++] = cast(uint) i;
        unitOrderLength = n;
        // A frame's entries are in byte order already.
        const byBytes = shape.order == EntryOrder.none || shape.order == EntryOrder.narOrder;
        if (byBytes && !unitAnc)
            return;
        const(char)[] text = names[];
        const order = shape.order;
        unitOrder[][0 .. n].sort!((a, b) => precedes(order,
            text[es[a].name.start .. es[a].name.end], fsoKind(es[a]),
            text[es[b].name.start .. es[b].name.end], fsoKind(es[b])));
    }

    // Reads the next `.gitignore` above a start root, or, when none is left,
    // gives the root its ignore state and opens it. `true` when it issued a
    // request.
    bool continuePrefix(ref const Filesets sets) @safe nothrow @nogc
    {
        const root = names[][prefixRoot.start .. prefixRoot.end];
        for (;;)
        {
            if (!prefixRead && !IgnoreState(prefixWord).excluded)
            {
                prefixRead = true;
                const dir = root[0 .. prefixPos ? prefixPos - 1 : 0];
                if (!request(Request(RequestKind.readFile, noDir, scopePath(dir), 0)))
                    return false;
                batchKind = BatchKind.prefix;
                return true;
            }
            size_t end = prefixPos;
            while (end < root.length && root[end] != '/')
                ++end;
            IgnoreState c;
            if (!ign.enter(IgnoreState(prefixWord), root[prefixPos .. end], *ignScratch, c))
            {
                latch(ResolutionErrorCode.capacityExceeded,
                    "the .gitignore positions exceed IgnoreLimits.maxPositions");
                return false;
            }
            prefixWord = c.word;
            if (end >= root.length)
                break;
            prefixPos = cast(uint)(end + 1);
            prefixRead = false;
        }
        prefixActive = false;
        stateOf(prefixState)[ignWord] = prefixWord;
        return openRoot(prefixRoot, prefixState, ev.dirVerdict(sets, stateOf(prefixState)));
    }

    // Opens the start root `span` with state `st`: issues its readDir, or
    // skips it. `true` when it issued the request.
    bool openRoot(Span span, uint st, DirVerdict verdict) @safe nothrow @nogc
    {
        const root = names[][span.start .. span.end];
        {
            if (verdict == DirVerdict.skip)
            {
                statesTop = 0;
                if (ign.ready)
                    ign.release(rootIgnMark);
                return false;
            }
            uint depth = root.length ? 1 : 0;
            foreach (c; root)
                if (c == '/')
                    ++depth;
            if (depth > lim.maxDepth)
            {
                latch(ResolutionErrorCode.depthExceeded, "a start root is deeper than maxDepth");
                return false;
            }
            Frame f;
            f.path = span;
            f.depth = depth;
            f.state = st;
            f.acceptAll = verdict == DirVerdict.acceptAll;
            f.whole = f.acceptAll || ev.wholeContent;
            frames[0] = f;
            framesTop = 1;
            if (!request(Request(RequestKind.readDir, noDir, root, 0, identityMask)))
                return false;
            batchKind = BatchKind.root;
            batchFrame = 0;
            return true;
        }
    }

    // The path of the `.gitignore` in `dir`, relative to the fileset root;
    // valid until the next call.
    const(char)[] scopePath(scope const(char)[] dir) @safe nothrow @nogc
    {
        size_t n;
        if (dir.length)
        {
            scopePathBuf[][0 .. dir.length] = dir[];
            scopePathBuf[dir.length] = '/';
            n = dir.length + 1;
        }
        scopePathBuf[][n .. n + gitignoreName.length] = gitignoreName;
        return scopePathBuf[][0 .. n + gitignoreName.length];
    }

    // Adds the scope of the `.gitignore` in `dir` just read into `fileRoom`
    // beneath the state `word`, which it extends.
    bool addScope(scope const(char)[] dir, ref ulong word) @safe nothrow @nogc
    {
        IgnoreState extended;
        const e = fileWhole ? ign.add(IgnoreState(word), scopePath(dir), fileLength, extended)
            : ScopeError.fileTooLarge;
        if (e != ScopeError.none)
        {
            latch(ResolutionErrorCode.capacityExceeded, e == ScopeError.fileTooLarge
                ? "a .gitignore exceeds IgnoreLimits.maxFileBytes"
                : "the .gitignore scopes exceed IgnoreLimits");
            return false;
        }
        word = extended.word;
        return true;
    }

    // Issues the read of frame `f`'s own `.gitignore`, if it has one and no
    // scope excluded it; `true` when it did.
    bool issueScopeRead(ref Frame f) @safe nothrow @nogc
    {
        if (ignWord == uint.max || f.acceptAll || IgnoreState(stateOf(f.state)[ignWord]).excluded)
            return false;
        foreach (i; 0 .. f.entryCount)
        {
            const e = entries[f.entries + i];
            const name = names[][e.name.start .. e.name.end];
            if (name != gitignoreName)
                continue;
            // Git reads no `.gitignore` through a link.
            if (e.kind != EntryKind.regular && e.kind != EntryKind.unknown)
                return false;
            if (!request(Request(RequestKind.readFile, frameIndex(f),
                    names[][e.name.start .. e.name.end], frameIndex(f))))
                return false;
            scopeName = e.name;
            batchKind = BatchKind.scope_;
            batchFrame = frameIndex(f);
            f.phase = Phase.scopeRead;
            return true;
        }
        return false;
    }

    // Consumes the answers to the batch.
    bool absorb(ref const Filesets sets) @safe nothrow @nogc
    {
        foreach (i; 0 .. pending)
            if (!answers[i].given)
            {
                latch(ResolutionErrorCode.unanswered, "a request was not answered");
                return false;
            }
        final switch (batchKind)
        {
            case BatchKind.none:
                break;
            case BatchKind.root:
                auto f = &frames[0];
                const a = answers[0];
                if (a.error != ErrorKind.other)
                {
                    // An absent root holds no member; any other failure is
                    // reported, and the root is skipped.
                    pending = 0;
                    if (a.error != ErrorKind.notFound && a.error != ErrorKind.notADirectory)
                    {
                        const root = names[][f.path.start .. f.path.end];
                        pathBuf[][0 .. root.length] = root[];
                        incompleteLength = root.length;
                        incompleteKind_ = a.error;
                        pendingReport = true;
                    }
                    framesTop = 0;
                    statesTop = 0;
                    if (ign.ready)
                        ign.release(rootIgnMark);
                    current = uint.max;
                    batchKind = BatchKind.none;
                    return true;
                }
                takeListing(0, 1);
                current = 0;
                break;
            case BatchKind.stats:
                auto f = &frames[batchFrame];
                foreach (i; 0 .. pending)
                {
                    auto e = &entries[requests[i].target];
                    if (answers[i].error != ErrorKind.other)
                    {
                        if (e.failed)
                            continue; // its stat and its readlink both failed
                        e.failed = true;
                        e.error = answers[i].error;
                        if (e.member)
                            --f.memberCount;
                        e.member = false;
                        continue;
                    }
                    if (requests[i].kind == RequestKind.stat && !e.failed)
                        decideAfterStat(sets, *f, *e);
                }
                f.phase = Phase.report;
                f.cursor = 0;
                break;
            case BatchKind.children:
                auto f = &frames[batchFrame];
                foreach (i; 0 .. pending)
                {
                    auto child = &frames[requests[i].target];
                    auto e = &entryOfChild(*f, requests[i].target);
                    if (answers[i].error == ErrorKind.other && repeatsAncestor(*child))
                    {
                        // A link back to a directory the walk is inside: one
                        // incomplete entry, not a descent to the depth bound.
                        child.failed = true;
                        child.error = ErrorKind.symlinkLoop;
                    }
                    else if (answers[i].error != ErrorKind.other)
                    {
                        child.failed = true;
                        child.error = answers[i].error;
                        // A link to a file, or a dangling one, stays the
                        // member it was judged as; any other failure leaves
                        // it unresolved, reported, and not a member.
                        if (child.throughLink && linkIsFile(child.error))
                            continue;
                    }
                    // A link that opened is a directory, not a member.
                    if (e.member)
                    {
                        e.member = false;
                        --f.memberCount;
                    }
                }
                // Each subdirectory that opened is entered, in this order,
                // and is a unit's entry (UnitEntry.child).
                uint live;
                foreach (k; 0 .. f.childCount)
                    if (!frames[f.children + k].failed)
                        entryOfChild(*f, f.children + k).child = live++;
                f.liveChildren = live;
                takeListing(f.children, f.childCount);
                f.phase = Phase.children;
                break;
            case BatchKind.scope_:
                auto f = &frames[batchFrame];
                f.phase = Phase.evaluate;
                const a = answers[0];
                if (a.error == ErrorKind.other)
                {
                    if (!addScope(names[][f.path.start .. f.path.end], stateOf(f.state)[ignWord]))
                        return false;
                }
                else if (!absentScope(a.error))
                {
                    // Unreadable: reported, and its rules do not apply (FSE2).
                    reportIncomplete(*f, scopeName);
                    incompleteKind_ = a.error;
                    pendingReport = true;
                }
                break;
            case BatchKind.prefix:
                const a = answers[0];
                const root = names[][prefixRoot.start .. prefixRoot.end];
                if (a.error == ErrorKind.other)
                {
                    if (!addScope(root[0 .. prefixPos ? prefixPos - 1 : 0], prefixWord))
                        return false;
                }
                else if (!absentScope(a.error))
                {
                    const p = requests[0].name;
                    pathBuf[][0 .. p.length] = p[];
                    incompleteLength = p.length;
                    incompleteKind_ = a.error;
                    pendingReport = true;
                }
                break;
        }
        pending = 0;
        batchKind = BatchKind.none;
        return true;
    }

    bool pendingReport; // an incomplete entry to hand over before going on

    // Gives each listed frame of `first .. first + count` its entries: the
    // staged ones, sorted by request then by name.
    void takeListing(uint first, uint count) @safe nothrow @nogc
    {
        import std.algorithm.sorting : sort;

        const from = frames[first].entryMark;
        auto staged = entries[][from .. entriesTop];
        const(char)[] text = names[];
        staged.sort!((a, b) => a.tag != b.tag ? a.tag < b.tag
            : text[a.name.start .. a.name.end] < text[b.name.start .. b.name.end]);
        uint at = from;
        foreach (i; 0 .. count)
        {
            auto f = &frames[first + i];
            const req = batchKind == BatchKind.root ? 0 : f.tagRequest;
            f.entries = at;
            while (at < entriesTop && entries[at].tag == req)
                ++at;
            f.entryCount = at - f.entries;
            f.phase = Phase.evaluate;
            f.cursor = 0;
        }
    }

    // What a `readDir` asks for beyond the listing: the opened directory's
    // identity, when links are followed (D6).
    StatMask identityMask() const @safe pure nothrow @nogc
        => follow ? StatMask.identity : StatMask.basic;

    // Whether `c`, reached through a followed link, is one of the directories
    // above it: a cycle (D6). Without a link no directory can be.
    bool repeatsAncestor(ref const Frame c) const @safe pure nothrow @nogc
    {
        if (!c.viaLink || !c.identified)
            return false;
        for (uint p = c.parent; p != uint.max; p = frames[p].parent)
            if (frames[p].identified && frames[p].device == c.device
                && frames[p].inode == c.inode)
                return true;
        return false;
    }

    ref Entry entryOfChild(ref Frame parent, uint child) return @safe nothrow @nogc
        => entries[frames[child].parentEntry];

    void evaluate(ref const Filesets sets, ref Frame f, ref Entry e) @safe nothrow @nogc
    {
        if (e.kind == EntryKind.unknown)
        {
            e.needStat = true;
            e.needKind = true;
            return;
        }
        judge(sets, f, e, EntryFacts.init, false);
        if (trace && !f.acceptAll)
            traceDecision(f, e);
    }

    // Records the `.gitignore` rule deciding `e`, if one does (FSI3). An entry
    // whose kind only a stat supplies is judged later, and is not traced.
    void traceDecision(ref Frame f, ref Entry e) @safe nothrow @nogc
    {
        const name = names[][e.name.start .. e.name.end];
        const isDir = e.kind == EntryKind.directory;
        const d = ev.ignoreDecision(ign, stateOf(f.state), name, isDir);
        if (!d.decided)
            return;
        reportIncomplete(f, e.name);
        decisionLength = incompleteLength;
        decisionRule = d.rule;
        decisionExcluded_ = d.excluded;
        decisionIsDir_ = isDir;
        decisionPending = true;
    }

    // Classifies an entry of known kind; `fileOnly` re-decides only its file
    // verdict, once a stat supplied the facts it lacked.
    void judge(ref const Filesets sets, ref Frame f, ref Entry e, EntryFacts facts, bool fileOnly)
        @safe nothrow @nogc
    {
        const name = names[][e.name.start .. e.name.end];
        const isLink = e.kind == EntryKind.symlink;
        if (!fileOnly && (e.kind == EntryKind.directory || (isLink && follow)))
        {
            DirVerdict v = DirVerdict.acceptAll;
            uint st = uint.max;
            if (!f.acceptAll)
            {
                st = allocState();
                if (st == uint.max)
                    return;
                v = ev.enter(sets, ign, stateOf(f.state), name, stateOf(st));
                e.whole = f.whole || ev.wholeContent;
                if (v == DirVerdict.skip)
                    statesTop -= words;
            }
            e.verdict = v;
            e.state = v == DirVerdict.skip ? uint.max : st;
            e.linkDir = isLink && v != DirVerdict.skip;
            if (!isLink)
                return;
        }
        if (e.kind == EntryKind.regular || isLink)
        {
            if (f.acceptAll)
            {
                setMember(f, e, true);
                return;
            }
            // A link is never executable (FSO1): no stat can tell more.
            const v = ev.fileVerdict(sets, ign, stateOf(f.state), name,
                isLink ? EntryFacts.stat(false) : facts);
            if (v == FileVerdict.undecided)
                e.needStat = true;
            else
                setMember(f, e, v == FileVerdict.accept);
        }
    }

    void setMember(ref Frame f, ref Entry e, bool member) @safe pure nothrow @nogc
    {
        if (member && !e.member)
            ++f.memberCount;
        else if (!member && e.member)
            --f.memberCount;
        e.member = member;
        if (!member)
            return;
        // What the scheme declared, and only that, is requested (FSO4).
        const m = shape.metadata;
        if (e.kind == EntryKind.regular)
            e.needStat |= !e.statted
                && (m & (FsoMetadata.executable | FsoMetadata.mtime | FsoMetadata.fingerprint)) != 0;
        else if (e.kind == EntryKind.symlink)
        {
            e.needStat |= !e.statted && (m & FsoMetadata.mtime) != 0;
            e.needLink |= !e.hasTarget && (m & FsoMetadata.linkTarget) != 0;
        }
    }

    void decideAfterStat(ref const Filesets sets, ref Frame f, ref Entry e) @safe nothrow @nogc
    {
        // A kind learned from the stat is judged afresh; a file whose verdict
        // waited for the stat only has that verdict decided.
        const fileOnly = !e.needKind;
        e.needKind = false;
        judge(sets, f, e, EntryFacts.stat(e.executable), fileOnly);
    }

    bool issueStats(ref Frame f) @safe nothrow @nogc
    {
        foreach (i; 0 .. f.entryCount)
        {
            const at = f.entries + i;
            auto e = &entries[at];
            const name = names[][e.name.start .. e.name.end];
            if (e.needStat)
            {
                e.needStat = false;
                // A declared mtime rides on every stat (FSS2).
                if (!request(Request(RequestKind.stat, frameIndex(f), name, at, statMask)))
                    return false;
            }
            if (e.needLink && e.kind == EntryKind.symlink)
            {
                e.needLink = false;
                // On the link's own directory: its target is never
                // resolved (FSO2).
                if (!request(Request(RequestKind.readlink, frameIndex(f), name, at)))
                    return false;
            }
        }
        if (!pending)
            return false;
        batchKind = BatchKind.stats;
        batchFrame = frameIndex(f);
        f.phase = Phase.stats;
        return true;
    }

    uint frameIndex(ref Frame f) @trusted pure nothrow @nogc
        => cast(uint)(&f - &frames[0]);

    // Lists every subdirectory still to resolve, in one batch (FSM3).
    bool issueChildren(ref Frame f) @safe nothrow @nogc
    {
        const self = frameIndex(f);
        f.entryMark = entriesTop;
        f.nameMark = namesTop;
        f.stateMark = statesTop;
        f.ignMark = ign.mark;
        f.children = framesTop;
        f.childCount = 0;
        foreach (i; 0 .. f.entryCount)
        {
            const at = f.entries + i;
            auto e = &entries[at];
            const isDir = e.kind == EntryKind.directory || e.linkDir;
            if (!isDir || e.verdict == DirVerdict.skip || e.failed)
                continue;
            if (f.depth + 1 > lim.maxDepth)
            {
                latch(ResolutionErrorCode.depthExceeded, "a directory is deeper than maxDepth");
                return false;
            }
            if (framesTop == frames.length)
            {
                latch(ResolutionErrorCode.capacityExceeded, "directories exceed maxFrames");
                return false;
            }
            const name = names[][e.name.start .. e.name.end];
            const parentPath = names[][f.path.start .. f.path.end];
            const pathAt = namesTop;
            if (parentPath.length)
            {
                if (putName(parentPath) == uint.max || putName("/") == uint.max)
                    return false;
            }
            if (putName(name) == uint.max)
                return false;
            Frame c;
            c.path = Span(pathAt, namesTop - pathAt);
            c.parent = self;
            c.depth = f.depth + 1;
            c.state = e.state;
            c.acceptAll = f.acceptAll || e.verdict == DirVerdict.acceptAll;
            c.whole = c.acceptAll || e.whole;
            c.throughLink = e.kind == EntryKind.symlink;
            c.viaLink = f.viaLink || c.throughLink;
            c.parentEntry = at;
            c.tagRequest = pending;
            c.entryMark = entriesTop;
            const target = framesTop++;
            frames[target] = c;
            ++f.childCount;
            if (!request(Request(RequestKind.readDir, self, name, target, identityMask,
                    c.throughLink)))
                return false;
        }
        // The staged listings start after the marks; their names too.
        foreach (k; 0 .. f.childCount)
            frames[f.children + k].entryMark = entriesTop;
        if (f.childCount == 0)
        {
            f.entryMark = entriesTop;
            return false;
        }
        f.nextChild = 0;
        batchKind = BatchKind.children;
        batchFrame = self;
        f.phase = Phase.listing;
        return true;
    }

    void reportIncomplete(ref Frame f, Span name) @safe nothrow @nogc
    {
        const dir = names[][f.path.start .. f.path.end];
        const n = names[][name.start .. name.end];
        size_t len;
        if (dir.length)
        {
            pathBuf[][0 .. dir.length] = dir[];
            pathBuf[dir.length] = '/';
            len = dir.length + 1;
        }
        pathBuf[][len .. len + n.length] = n[];
        incompleteLength = len + n.length;
    }
}

// Whether a `.gitignore` read failed only because there is none to read: an
// absent file or directory, a directory of that name, or a link git would
// not follow.
private bool absentScope(ErrorKind k) @safe pure nothrow @nogc
    => k == ErrorKind.notFound || k == ErrorKind.notADirectory || k == ErrorKind.isADirectory
        || k == ErrorKind.symlinkRefused;

// Whether a link that failed to open as a directory is a link to a file, or
// a dangling one: either stays a member as the link it is.
private bool linkIsFile(ErrorKind k) @safe pure nothrow @nogc
    => k == ErrorKind.notADirectory || k == ErrorKind.notFound;

// The node kind an entry of a unit stands for.
private FsoKind fsoKind(E)(in E e) @safe pure nothrow @nogc
    => e.child != noChild ? FsoKind.directory
        : e.kind == EntryKind.symlink ? FsoKind.symlink : FsoKind.regular;
