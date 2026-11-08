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
FSA4), then its subdirectories listed in one batch and resolved in order.
When every child is done the frame is handed over as a unit (`StepKind.unit`):
its path, its member files in byte order, and whether it is an empty
directory, entered and holding neither a member nor an entered subdirectory
(FSV4). Units therefore arrive after their children (FSM5). An entry that
could not be read is handed over as `StepKind.incomplete`, and the resolution
continues (FSE1–FSE3); a bound exceeded or a request a driver cannot perform
ends it with a `ResolutionError` (FSM2, FSM7).

All storage is allocated when the machine is made, sized by
`ResolutionLimits`; no step allocates (invariant 2), and running out of it is
an error, not growth.
*/
module sparkles.build_primitives.fileset.machine;

import sparkles.base.buffer : HeapBuffer;
import sparkles.base.io.errors : ErrorKind;
import sparkles.base.vfs.types : EntryKind, Stat, StatMask;

import sparkles.base.unique : Unique;
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
    readlink, /// read a link's target
    readFile, /// read a `.gitignore` into `Resolution.fileRoom` (FSM4, FSI)
}

/// One request. Names are valid until the next `step`.
struct Request
{
    RequestKind kind;      ///
    uint dir;              /// the directory it is relative to; `noDir` for the fileset root
    const(char)[] name;    /// one entry name, or a path beneath the fileset root when `dir` is `noDir`
    uint target;           /// `readDir`: the id the opened directory takes
    StatMask mask;         /// `stat`: what to fill
    bool throughLink;      /// `readDir`: `name` is a link the root's policy may follow
}

/// `Request.dir` of a root's `readDir`: relative to the fileset root.
enum uint noDir = uint.max;

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
    unit,       /// a directory is resolved: read `unitPath`, `unitMembers`, `unitEmpty`
    incomplete, /// an entry could not be read: read `incompletePath`, `incompleteKind`
    budget,     /// the budget is spent; step again to continue
    done,       /// the resolution is complete
    /// a `.gitignore` rule decided an entry (only when tracing, FSI3): read
    /// `decisionPath`, `decisionIsDir`, `decisionExcluded`, `decisionSource`,
    /// `decisionLine` and `decisionPattern`
    ignoreDecision,
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
    decides (FSI3).

    A fileset with a `gitignored` leaf makes the machine read `.gitignore`
    files: before a start root is listed, that of the fileset root and of
    each directory down to it, and after a directory is listed, its own,
    unless a scope already excluded it. Each read is one `readFile` batch.
    */
    this(ref const Filesets sets, Fileset f, ResolutionLimits limits = ResolutionLimits.init,
        bool followLinks = false, bool traceIgnores = false) @safe nothrow @nogc
    {
        import core.atomic : atomicOp;
        import sparkles.base.unique : makeUnique;

        lim = limits;
        follow = followLinks;
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

    /// The unit's directory, relative to the fileset root (`""` for it).
    const(char)[] unitPath() const return @safe pure nothrow @nogc
        => names[][frames[unitFrame].path.start .. frames[unitFrame].path.end];

    /// The unit's member files, by name, in byte order.
    auto unitMembers() const return @safe pure nothrow @nogc
    {
        static struct Members
        {
            private const(Resolution)* r;
            private uint at, end;

            bool empty() const @safe pure nothrow @nogc => at == end;
            const(char)[] front() const return @safe pure nothrow @nogc
                => r.names[][r.entries[at].name.start .. r.entries[at].name.end];
            void popFront() @safe pure nothrow @nogc
            {
                ++at;
                while (at < end && !r.entries[at].member)
                    ++at;
            }
        }

        const f = frames[unitFrame];
        uint at = f.entries;
        const end = f.entries + f.entryCount;
        while (at < end && !entries[at].member)
            ++at;
        return (() @trusted => Members(&this, at, end))();
    }

    /// Whether the unit's directory is empty in the sense of FSV4.
    bool unitEmpty() const @safe pure nothrow @nogc
        => frames[unitFrame].memberCount == 0 && frames[unitFrame].enteredChildren == 0;

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
        EntryKind kind;
        uint tag;          // the request that listed it, then its child frame
        uint state = uint.max; // a subdirectory's evaluation state
        DirVerdict verdict;
        ErrorKind error = ErrorKind.other;
        bool executable, statted, member, needStat, needKind, failed, linkDir;
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
        uint memberCount, enteredChildren;
        Phase phase;
        bool acceptAll, failed, throughLink, scopeChecked;
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
    uint unitFrame;
    uint retired_ = noDir;
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
                if (!startNextRoot(sets))
                {
                    kind = StepKind.done;
                    return !failed_;
                }
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
                        if (e.failed)
                        {
                            reportIncomplete(*f, e.name);
                            incompleteKind_ = e.error;
                            kind = StepKind.incomplete;
                            return true;
                        }
                    }
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
                        ++f.enteredChildren;
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
                    unitFrame = current;
                    retired_ = current;
                    current = f.parent;
                    if (current == uint.max)
                    {
                        // A root: free everything it used.
                        framesTop = 0;
                        entriesTop = 0;
                        statesTop = 0;
                        namesTop = rootsEnd;
                        if (ign.ready)
                            ign.release(rootIgnMark);
                    }
                    kind = StepKind.unit;
                    return true;
            }
        }
    }

    uint rootsEnd() const @safe pure nothrow @nogc
        => rootSpans.length ? rootSpans[$ - 1].end : 0;

    // Issues the next root's readDir; `false` when none is left.
    bool startNextRoot(ref const Filesets sets) @safe nothrow @nogc
    {
        while (nextRoot < rootSpans.length)
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
                continue;
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
                    if (continuePrefix(sets))
                        return true;
                    if (failed_)
                        return false;
                    continue;
                }
            }
            if (openRoot(span, st, verdict))
                return true;
            if (failed_)
                return false;
        }
        return false;
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
            frames[0] = f;
            framesTop = 1;
            if (!request(Request(RequestKind.readDir, noDir, root, 0)))
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
                        e.failed = true;
                        e.error = answers[i].error;
                        e.member = false;
                        continue;
                    }
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
                    if (answers[i].error != ErrorKind.other)
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
            const v = ev.fileVerdict(sets, ign, stateOf(f.state), name, facts);
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
        e.member = member;
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
            if (!e.needStat)
                continue;
            e.needStat = false;
            if (!request(Request(RequestKind.stat, frameIndex(f),
                    names[][e.name.start .. e.name.end], at, StatMask.basic)))
                return false;
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
            c.throughLink = e.kind == EntryKind.symlink;
            c.parentEntry = at;
            c.tagRequest = pending;
            c.entryMark = entriesTop;
            const target = framesTop++;
            frames[target] = c;
            ++f.childCount;
            if (!request(Request(RequestKind.readDir, self, name, target, StatMask.basic,
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
