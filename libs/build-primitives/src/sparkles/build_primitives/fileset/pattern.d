/**
Fileset patterns: anchoring (FSG1), case policy (FSG3) and bounded
compilation (FSG4).

A pattern is split at `/` into segments, and each segment other than `**`
compiles to its own bounded Thompson NFA from `sparkles.fuzzy.glob`. A
pattern is then an automaton over path components: its state is the set of
segment positions still able to match, one bit each, so stepping it over a
directory name costs one glob match per live position and the state of a
directory is a single machine word.

The anchoring rule is `.gitignore`'s:

$(UL
    $(LI a pattern containing `/` before its last character is anchored to
        the fileset root;)
    $(LI a pattern with no such `/` matches at any depth, as if a `**`
        segment preceded it;)
    $(LI a leading `/` anchors the pattern and is removed;)
    $(LI a trailing `/` restricts the pattern to directories and is removed.)
)

A pattern that matches a directory selects every file beneath it, since a
directory is never itself a member (FSV3).

Matching normalizes both sides to NFC, and under `CasePolicy.insensitive`
also folds case: that is the glob engine's matching policy, and it never
affects identity or ordering (invariant 5, FSG3).

Specified in `docs/specs/build-primitives/filesets/SPEC.md` §5.
*/
module sparkles.build_primitives.fileset.pattern;

import sparkles.base.buffer : HeapBuffer;
import sparkles.base.expected : Expected, err, ok;
import sparkles.base.text.errors : NoGcHook;
import sparkles.fuzzy.common : FuzzyErrorCode, PathFlavor;
import sparkles.fuzzy.glob : GlobCompileWorkspace, GlobMatchWorkspace, GlobProgram,
    compileGlob, globMatch;

/// The case policy of a fileset's matching (FSG3). It never affects identity
/// or ordering.
enum CasePolicy : ubyte
{
    sensitive,   /// the default
    insensitive, /// simple case folding, as `sparkles.fuzzy.glob` applies it
}

/// Why constructing a fileset failed (FSV5).
enum FilesetErrorCode : ubyte
{
    none,               ///
    emptyPattern,       /// a pattern, or one of its segments, is empty
    malformedPattern,   /// the glob grammar rejects a segment
    patternTooComplex,  /// a bound of FSG4 is exceeded
    unsupportedPattern, /// valid glob syntax with no fileset meaning
    malformedTreeLiteral, /// a tree literal line does not parse (FSD2)
    treeLiteralTooLarge,  /// a tree literal does not fit its arena
}

/// A construction failure, with the byte offset in the source it concerns.
struct FilesetError
{
    FilesetErrorCode code; ///
    size_t offset;         /// into the pattern, or the tree literal's line number
    string context;        /// a static explanation
}

/// The result of a fallible fileset construction step.
alias FilesetExpected(T) = Expected!(T, FilesetError, NoGcHook);

/// ditto
FilesetExpected!T filesetOk(T)(T value) => ok!(FilesetError, NoGcHook)(value);

/// ditto
FilesetExpected!void filesetOk() @safe pure nothrow @nogc => ok!(FilesetError, NoGcHook)();

/// ditto
FilesetExpected!T filesetErr(T)(FilesetErrorCode code, size_t offset = 0, string context = null)
    => err!(T, NoGcHook)(FilesetError(code, offset, context));

/// The bounds of FSG4: one segment's NFA, and a pattern's segment count. A
/// pattern state is one `ulong`, so a pattern has at most 62 segments
/// (counting the implicit leading `**` of an unanchored pattern), leaving a
/// bit for the latch of `PatternSet.matchedBit`.
enum size_t maxSegmentInstructions = 64;
/// ditto
enum size_t maxSegmentRanges = 16;
/// ditto
enum size_t maxPatternSegments = 62;

/// The longest name a segment is matched against: the `FSM7` default. A
/// longer name never matches.
enum size_t maxMatchedNameBytes = 255;

/// One segment's compiled glob.
alias SegmentProgram = GlobProgram!(maxSegmentInstructions, maxSegmentRanges);

/// What a segment matches.
enum SegmentKind : ubyte
{
    literal,  /// its bytes, under the matching policy
    glob,     /// its glob
    globstar, /// any number of components, zero included
}

/// One segment of a compiled pattern.
struct Segment
{
    SegmentKind kind; ///
    bool ascii;       /// every byte of `text` is ASCII
    uint program;     /// into `PatternSet`'s programs; unused for `globstar`
    string text;      /// borrowed from the pattern source (invariant 3)
}

/// One compiled pattern: its segments are `first .. first + count`.
struct PatternInfo
{
    uint first;    ///
    ubyte count;   /// segments, the implicit leading `**` included
    bool anchored; /// whether it matches only from the fileset root
    bool dirOnly;  /// whether a trailing `/` restricted it to directories
    string source; /// the pattern as given
}

/**
Caller-owned scratch for matching one name against a segment glob. It is
large, so heap-own it (`makeUnique`) and reuse it; matching never allocates.
*/
struct MatchScratch
{
    private GlobMatchWorkspace!(maxSegmentInstructions, 4 * maxMatchedNameBytes,
        4 * maxMatchedNameBytes) workspace;

    /// Glob-engine evaluations performed, for tests that pin where matching
    /// happens (FSA3).
    ulong engineCalls;

    /// Segment comparisons of any kind performed.
    ulong segmentMatches;
}

/**
The compiled patterns of one fileset arena. Move-only; compilation allocates,
matching does not.
*/
struct PatternSet
{
    @disable this(this);

    private HeapBuffer!Segment segments_;
    private HeapBuffer!SegmentProgram programs_;
    private HeapBuffer!PatternInfo patterns_;
    private CasePolicy casePolicy_;

    /// An empty set matching under `policy`.
    this(CasePolicy policy) @safe pure nothrow @nogc
    {
        casePolicy_ = policy;
    }

    /// The matching policy.
    CasePolicy casePolicy() const @safe pure nothrow @nogc => casePolicy_;

    /// The number of compiled patterns.
    size_t length() const @safe pure nothrow @nogc => patterns_.length;

    /// The pattern `index`.
    PatternInfo opIndex(size_t index) const @safe pure nothrow @nogc => patterns_[index];

    /// The segment `index` of pattern `p`.
    Segment segment(in PatternInfo p, size_t index) const @safe pure nothrow @nogc
        => segments_[p.first + index];

    /// The bit of a pattern state that latches "a directory on the path so far
    /// matched the whole pattern"; set by `PatternSet.enterDir`.
    enum ulong matchedBit = 1UL << 63;

    /**
    Compiles `pattern` (FSG1, FSG4). The source is borrowed: it must outlive
    the set (invariant 3). Returns the new pattern's index.
    */
    FilesetExpected!uint add(string pattern) @safe pure nothrow @nogc
    {
        import sparkles.base.unique : makeUnique;

        if (pattern.length == 0)
            return filesetErr!uint(FilesetErrorCode.emptyPattern, 0, "the pattern is empty");

        size_t begin = 0, end = pattern.length;
        bool anchored, dirOnly;
        if (pattern[end - 1] == '/' && !escapedAt(pattern, end - 1))
        {
            dirOnly = true;
            --end;
        }
        if (begin < end && pattern[begin] == '/')
        {
            anchored = true;
            ++begin;
        }
        if (begin >= end)
            return filesetErr!uint(FilesetErrorCode.emptyPattern, 0, "the pattern names no component");
        const body = pattern[begin .. end];
        if (body[0] == '!')
            return filesetErr!uint(FilesetErrorCode.unsupportedPattern, begin,
                "a leading `!` is .gitignore negation; a fileset spells it as a difference "
                ~ "(escape it as `\\!` to match the character)");

        // A `/` inside braces would make one alternative span components.
        int depth;
        for (size_t i = 0; i < body.length; ++i)
        {
            const c = body[i];
            if (c == '\\')
            {
                ++i;
                continue;
            }
            if (c == '{')
                ++depth;
            else if (c == '}' && depth > 0)
                --depth;
            else if (c == '/')
            {
                if (depth > 0)
                    return filesetErr!uint(FilesetErrorCode.unsupportedPattern, begin + i,
                        "a brace alternative may not contain `/`");
                anchored = true;
            }
        }

        auto workspace = makeUnique!(GlobCompileWorkspace!(maxSegmentInstructions,
            maxSegmentRanges))();
        if (workspace.empty)
            return filesetErr!uint(FilesetErrorCode.patternTooComplex, 0,
                "no memory for the glob compiler's workspace");

        const segmentsBefore = segments_.length, programsBefore = programs_.length;
        PatternInfo info;
        info.first = cast(uint) segments_.length;
        info.anchored = anchored;
        info.dirOnly = dirOnly;
        info.source = pattern;
        if (!anchored)
            segments_ ~= Segment(SegmentKind.globstar, true, uint.max, "**");

        size_t start = 0;
        foreach (i; 0 .. body.length + 1)
        {
            if (i < body.length && body[i] != '/')
                continue;
            if (i > 0 && i < body.length && escapedAt(body, i))
                continue;
            const text = body[start .. i];
            const at = begin + start;
            start = i + 1;
            if (segments_.length - segmentsBefore == maxPatternSegments)
            {
                segments_.length = segmentsBefore;
                programs_.length = programsBefore;
                return filesetErr!uint(FilesetErrorCode.patternTooComplex, at,
                    "the pattern has more segments than a fileset pattern may");
            }
            auto made = compileSegment(text, at, *workspace);
            if (made.hasError)
            {
                segments_.length = segmentsBefore;
                programs_.length = programsBefore;
                return filesetErr!uint(made.error.code, made.error.offset, made.error.context);
            }
            segments_ ~= made.value;
        }
        info.count = cast(ubyte)(segments_.length - segmentsBefore);
        patterns_ ~= info;
        return filesetOk(cast(uint)(patterns_.length - 1));
    }

    /// The state of pattern `p` before any component: its start position,
    /// closed over leading `**` segments.
    ulong start(size_t p) const @safe pure nothrow @nogc => closure(patterns_[p], 1);

    /**
    Steps the state `positions` of pattern `p` over one component `name`.
    The latch bit is not carried; see `enterDir`.
    */
    ulong step(size_t p, ulong positions, scope const(char)[] name, ref MatchScratch scratch)
        const @safe pure nothrow @nogc
    {
        const info = patterns_[p];
        ulong next;
        foreach (i; 0 .. info.count)
        {
            if (!(positions & (1UL << i)))
                continue;
            const s = segments_[info.first + i];
            if (s.kind == SegmentKind.globstar)
                next |= 1UL << i;
            else if (matches(s, name, scratch))
                next |= 1UL << (i + 1);
        }
        return closure(info, next);
    }

    /// Whether the state `positions` of pattern `p` has consumed the whole
    /// pattern.
    bool complete(size_t p, ulong positions) const @safe pure nothrow @nogc
        => (positions & (1UL << patterns_[p].count)) != 0;

    /**
    The state after entering the directory `name`: the latch is set once a
    directory matched the whole pattern, after which every file beneath is
    selected and the positions no longer matter.
    */
    ulong enterDir(size_t p, ulong state, scope const(char)[] name, ref MatchScratch scratch)
        const @safe pure nothrow @nogc
    {
        if (state & matchedBit)
            return state;
        const next = step(p, state, name, scratch);
        return complete(p, next) ? next | matchedBit : next;
    }

    /// Whether the file (or other non-directory) `name` in a directory whose
    /// state for pattern `p` is `state` matches the pattern.
    bool matchesFile(size_t p, ulong state, scope const(char)[] name, ref MatchScratch scratch)
        const @safe pure nothrow @nogc
    {
        if (state & matchedBit)
            return true;
        if (patterns_[p].dirOnly)
            return false;
        return complete(p, step(p, state, name, scratch));
    }

    /// Whether a directory with state `state` for pattern `p` has a file
    /// beneath it the pattern can still select. `false` proves it has none.
    bool live(ulong state) const @safe pure nothrow @nogc => state != 0;

    /// Whether one segment matches `name`.
    bool matches(in Segment s, scope const(char)[] name, ref MatchScratch scratch)
        const @safe pure nothrow @nogc
    {
        ++scratch.segmentMatches;
        final switch (s.kind)
        {
            case SegmentKind.globstar:
                return true;
            case SegmentKind.literal:
                // ASCII is NFC-stable, so a byte comparison is the engine's
                // answer whenever both sides are ASCII.
                if (s.ascii && isAscii(name))
                    return casePolicy_ == CasePolicy.sensitive
                        ? name == s.text : asciiEqualFolded(name, s.text);
                goto case SegmentKind.glob;
            case SegmentKind.glob:
                if (name.length > maxMatchedNameBytes)
                    return false;
                ++scratch.engineCalls;
                const r = globMatch(programs_[s.program], name, scratch.workspace);
                return !r.hasError && r.value;
        }
    }

    private ulong closure(in PatternInfo info, ulong positions) const @safe pure nothrow @nogc
    {
        foreach (i; 0 .. info.count)
            if ((positions & (1UL << i)) && segments_[info.first + i].kind == SegmentKind.globstar)
                positions |= 1UL << (i + 1);
        return positions;
    }

    private FilesetExpected!Segment compileSegment(W)(string text, size_t at, ref W workspace)
        @safe pure nothrow @nogc
    {
        if (text.length == 0)
            return filesetErr!Segment(FilesetErrorCode.emptyPattern, at,
                "a pattern segment is empty (`//`)");
        if (text == "." || text == "..")
            return filesetErr!Segment(FilesetErrorCode.unsupportedPattern, at,
                "a `.` or `..` segment never names a listed entry");
        if (text == "**")
            return filesetOk(Segment(SegmentKind.globstar, true, uint.max, text));

        bool literal = true;
        foreach (c; text)
            if (c == '*' || c == '?' || c == '[' || c == ']' || c == '{' || c == '}' || c == '\\')
                literal = false;

        programs_ ~= SegmentProgram.init;
        const index = programs_.length - 1;
        const compiled = compileGlob(text, PathFlavor.unix,
            casePolicy_ == CasePolicy.sensitive, programs_[index], workspace);
        if (compiled.hasError)
        {
            const code = compiled.error.code == FuzzyErrorCode.globTooComplex
                ? FilesetErrorCode.patternTooComplex : FilesetErrorCode.malformedPattern;
            return filesetErr!Segment(code, at + compiled.error.offset, compiled.error.context);
        }
        return filesetOk(Segment(literal ? SegmentKind.literal : SegmentKind.glob,
            isAscii(text), cast(uint) index, text));
    }
}

///
@("fileset.pattern.anchoring")
@system unittest
{
    import sparkles.base.unique : makeUnique;

    auto scratch = makeUnique!MatchScratch();
    auto set = PatternSet(CasePolicy.sensitive);
    const md = set.add("*.md").value;          // no `/`: any depth
    const src = set.add("src/*.d").value;      // anchored
    const rootMd = set.add("/*.md").value;     // forced to the root

    bool fileMatches(uint p, string path)
    {
        ulong state = set.start(p);
        size_t from = 0;
        foreach (i, c; path)
            if (c == '/')
            {
                state = set.enterDir(p, state, path[from .. i], *scratch);
                from = i + 1;
            }
        return set.matchesFile(p, state, path[from .. $], *scratch);
    }

    // FSG1's detection, verbatim.
    assert(fileMatches(md, "a/b.md"));
    assert(!fileMatches(src, "lib/src/x.d"));
    assert(!fileMatches(rootMd, "a/b.md"));

    assert(fileMatches(src, "src/x.d"));
    assert(fileMatches(rootMd, "b.md"));
    assert(!fileMatches(md, "a/b.d"));
}

@("fileset.pattern.globstar")
@system unittest
{
    import sparkles.base.unique : makeUnique;

    auto scratch = makeUnique!MatchScratch();
    auto set = PatternSet(CasePolicy.sensitive);
    const p = set.add("src/**/*.d").value;
    const all = set.add("src/**").value;
    const dir = set.add("build/").value;

    bool fileMatches(uint pat, string path)
    {
        ulong state = set.start(pat);
        size_t from = 0;
        foreach (i, c; path)
            if (c == '/')
            {
                state = set.enterDir(pat, state, path[from .. i], *scratch);
                from = i + 1;
            }
        return set.matchesFile(pat, state, path[from .. $], *scratch);
    }

    assert(fileMatches(p, "src/a.d"));       // `**` matches zero components
    assert(fileMatches(p, "src/x/y/a.d"));
    assert(!fileMatches(p, "lib/a.d"));
    assert(fileMatches(all, "src/x/y"));
    assert(!fileMatches(all, "srcx/y"));
    // A directory-only pattern selects what is beneath a matching directory,
    // never a file of the same name.
    assert(fileMatches(dir, "a/build/x.o"));
    assert(!fileMatches(dir, "a/build"));
}

@("fileset.pattern.errors")
@safe pure nothrow @nogc unittest
{
    auto set = PatternSet(CasePolicy.sensitive);
    assert(set.add("").error.code == FilesetErrorCode.emptyPattern);
    assert(set.add("/").error.code == FilesetErrorCode.emptyPattern);
    assert(set.add("a//b").error.code == FilesetErrorCode.emptyPattern);
    assert(set.add("a/../b").error.code == FilesetErrorCode.unsupportedPattern);
    assert(set.add("!a").error.code == FilesetErrorCode.unsupportedPattern);
    assert(set.add("{a/b,c}").error.code == FilesetErrorCode.unsupportedPattern);
    assert(set.add("a/[b").error.code == FilesetErrorCode.malformedPattern);
    assert(set.add("a/[b").error.offset >= 2);
    assert(set.length == 0, "a failed compilation leaves nothing behind");
}

/// FSG4: a pattern beyond a bound returns the bound error.
@("fileset.pattern.bounds")
@safe pure nothrow @nogc unittest
{
    auto set = PatternSet(CasePolicy.sensitive);
    // 70 `?` exceed one segment's 64 instructions.
    enum string long_ = "??????????" ~ "??????????" ~ "??????????" ~ "??????????"
        ~ "??????????" ~ "??????????" ~ "??????????";
    assert(set.add(long_).error.code == FilesetErrorCode.patternTooComplex);
    enum string deep = "a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/"
        ~ "a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a";
    assert(set.add(deep).error.code == FilesetErrorCode.patternTooComplex);
    assert(set.length == 0);
}

/// FSG3: the case policy decides matching only.
@("fileset.pattern.casePolicy")
@system unittest
{
    import sparkles.base.unique : makeUnique;

    auto scratch = makeUnique!MatchScratch();
    auto sensitive = PatternSet(CasePolicy.sensitive);
    auto insensitive = PatternSet(CasePolicy.insensitive);
    foreach (pattern; ["README.md", "*.MD"])
    {
        cast(void) sensitive.add(pattern);
        cast(void) insensitive.add(pattern);
    }
    foreach (p; 0 .. 2)
    {
        const s = sensitive.start(p), i = insensitive.start(p);
        assert(!sensitive.matchesFile(p, s, "readme.md", *scratch) || p == 1);
        assert(insensitive.matchesFile(p, i, "readme.md", *scratch));
    }
    assert(!sensitive.matchesFile(1, sensitive.start(1), "a.md", *scratch));
    assert(insensitive.matchesFile(1, insensitive.start(1), "a.md", *scratch));
}

/// Matching normalizes to NFC, so a literal and its decomposed spelling
/// match each other, while the bytes themselves stay distinct names.
@("fileset.pattern.normalization")
@system unittest
{
    import sparkles.base.unique : makeUnique;

    auto scratch = makeUnique!MatchScratch();
    auto set = PatternSet(CasePolicy.sensitive);
    const p = set.add("café").value;
    assert(set.matchesFile(p, set.start(p), "café", *scratch));
    assert(set.matchesFile(p, set.start(p), "café", *scratch));
    assert(!set.matchesFile(p, set.start(p), "cafe", *scratch));
}

/// A name at the bound, of any bytes, is matched without an engine failure;
/// a longer one never matches.
@("fileset.pattern.nameBound")
@system unittest
{
    import sparkles.base.unique : makeUnique;

    auto scratch = makeUnique!MatchScratch();
    auto set = PatternSet(CasePolicy.sensitive);
    const any = set.add("*").value;
    auto folded = PatternSet(CasePolicy.insensitive);
    const anyFolded = folded.add("*").value;

    char[maxMatchedNameBytes + 1] name;
    // Every combining mark (U+0301 is two bytes) after one starter: the
    // longest normalization segment a 255-byte name can hold.
    name[0] = 'e';
    foreach (i; 0 .. 127)
    {
        name[1 + 2 * i] = '\xCC';
        name[2 + 2 * i] = '\x81';
    }
    assert(set.matchesFile(any, set.start(any), name[0 .. 255], *scratch));
    foreach (ref c; name)
        c = '\xFF';
    assert(set.matchesFile(any, set.start(any), name[0 .. 255], *scratch));
    // U+0390 decomposes to three code points under folding.
    foreach (i; 0 .. 127)
    {
        name[2 * i] = '\xCE';
        name[2 * i + 1] = '\x90';
    }
    assert(folded.matchesFile(anyFolded, folded.start(anyFolded), name[0 .. 254], *scratch));
    assert(!set.matchesFile(any, set.start(any), name[0 .. 256], *scratch));
}

private bool isAscii(scope const(char)[] s) @safe pure nothrow @nogc
{
    foreach (c; s)
        if (c >= 0x80)
            return false;
    return true;
}

private bool asciiEqualFolded(scope const(char)[] a, scope const(char)[] b) @safe pure nothrow @nogc
{
    if (a.length != b.length)
        return false;
    foreach (i; 0 .. a.length)
    {
        char x = a[i], y = b[i];
        if (x >= 'A' && x <= 'Z')
            x += 32;
        if (y >= 'A' && y <= 'Z')
            y += 32;
        if (x != y)
            return false;
    }
    return true;
}

// Whether the byte at `i` is escaped by an odd run of backslashes before it.
private bool escapedAt(scope const(char)[] s, size_t i) @safe pure nothrow @nogc
{
    size_t run;
    while (run < i && s[i - 1 - run] == '\\')
        ++run;
    return (run & 1) != 0;
}
