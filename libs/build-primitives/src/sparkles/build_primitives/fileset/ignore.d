/**
`.gitignore` scopes for resolution: git's reading of a rule line, and the
immutable scope chain a resolution builds as it finds `.gitignore` files
(FSI1–FSI4).

A scope is one `.gitignore` and the rules it declared. It refers to the scope
of the directory above it by index into an `IgnoreScopes` arena and is never
changed once added, so any number of directories may evaluate against one
chain at once (FSI1). The arena is owned by one resolution, sized when it is
made, and released in the same stack order as the resolution's directories
(FSI2).

Each directory a resolution holds has an `IgnoreState`: one word naming a
block of matcher positions in the arena, one per rule of its chain, and a
latch saying a directory on its path was excluded. Entering a child steps
every position over the child's name; a child's own `.gitignore` extends its
block with its rules' start positions. Rules are consulted outermost scope
first and in declaration order, the last match deciding, so a deeper scope
overrides a shallower one and, within a scope, the last matching rule wins;
once the latch is set nothing beneath can be re-included (FSI4). Every rule
carries its file and 1-based line (FSI3).

Nothing here allocates after the arena is made (invariant 2), and nothing
performs I/O: a driver reads each `.gitignore` into `IgnoreScopes.room`.
*/
module sparkles.build_primitives.fileset.ignore;

import sparkles.base.buffer : HeapBuffer;
import sparkles.base.unique : Unique, makeUnique;

import sparkles.build_primitives.fileset.pattern : CasePolicy, FilesetErrorCode, MatchScratch,
    PatternCompileWorkspace, PatternSet;

// ---------------------------------------------------------------- reading

/// What one `.gitignore` line is.
enum IgnoreLineKind : ubyte
{
    blank,   /// empty, all spaces, or a comment
    rule,    /// a pattern, possibly negated
}

/// One `.gitignore` line, read as git reads it (`IgnoreLineKind.rule`), its
/// pattern translated into fileset pattern syntax.
struct IgnoreLine
{
    IgnoreLineKind kind; ///
    bool negated;        /// it began with `!`
    size_t length;       /// bytes of the translated pattern in the output buffer
}

/// The most bytes `readIgnoreLine` writes for a line of `n` bytes.
size_t ignoreLineRoom(size_t n) @safe pure nothrow @nogc => 2 * n;

/**
Reads `line`, one `.gitignore` line without its `\n`, as git does, and
writes its pattern into `into` in the syntax `PatternSet.add` reads.

Git's reading: a trailing `\r` is dropped; a line starting with `#` is a
comment; trailing spaces are removed unless escaped by `\` (a trailing tab
is kept); a leading `!` negates, and `\!` and `\#` escape those characters.
Git's globs have no brace alternatives, so `{` and `}` are escaped to stay
literal. Everything else (`*`, `?`, `[…]`, `**`, escapes, a leading or
middle `/` anchoring, a trailing `/` for directories) means the same in both
syntaxes. `into` must hold `ignoreLineRoom(line.length)` bytes.
*/
IgnoreLine readIgnoreLine(scope const(char)[] line, scope char[] into) @safe pure nothrow @nogc
in (into.length >= ignoreLineRoom(line.length), "the output buffer is too small")
{
    if (line.length && line[$ - 1] == '\r')
        line = line[0 .. $ - 1];
    if (line.length == 0 || line[0] == '#')
        return IgnoreLine(IgnoreLineKind.blank);

    // Git's `trim_trailing_spaces`: the last run of unescaped spaces goes;
    // a line ending in a lone `\` is left as it is.
    size_t end = line.length;
    {
        size_t lastSpace = size_t.max;
        for (size_t i = 0; i < line.length; ++i)
        {
            const c = line[i];
            if (c == ' ')
            {
                if (lastSpace == size_t.max)
                    lastSpace = i;
                continue;
            }
            if (c == '\\')
            {
                ++i;
                if (i == line.length)
                {
                    lastSpace = size_t.max;
                    break;
                }
            }
            lastSpace = size_t.max;
        }
        if (lastSpace != size_t.max)
            end = lastSpace;
    }
    line = line[0 .. end];

    IgnoreLine result = IgnoreLine(IgnoreLineKind.rule);
    if (line.length && line[0] == '!')
    {
        result.negated = true;
        line = line[1 .. $];
    }
    if (line.length == 0)
        return IgnoreLine(IgnoreLineKind.blank);

    size_t n;
    for (size_t i = 0; i < line.length; ++i)
    {
        const c = line[i];
        if (c == '\\' && i + 1 < line.length)
        {
            into[n++] = c;
            into[n++] = line[++i];
            continue;
        }
        // Braces are literal to git; so is a `!` left first after negation.
        if (c == '{' || c == '}' || (i == 0 && c == '!'))
            into[n++] = '\\';
        into[n++] = c;
    }
    result.length = n;
    return result;
}

///
@("fileset.ignore.readIgnoreLine")
@safe pure nothrow @nogc unittest
{
    char[64] buf;
    bool reads(string line, string pattern, bool negated = false)
    {
        const r = readIgnoreLine(line, buf[]);
        return r.kind == IgnoreLineKind.rule && buf[0 .. r.length] == pattern
            && r.negated == negated;
    }
    bool blank(string line) => readIgnoreLine(line, buf[]).kind == IgnoreLineKind.blank;

    assert(blank("") && blank("# a comment") && blank("   ") && blank("\r") && blank("!"));
    assert(reads("build/", "build/"));
    assert(reads("*.o\r", "*.o"));
    assert(reads("!keep.o", "keep.o", true));
    assert(reads(`\!bang`, `\!bang`));
    assert(reads(`\#hash`, `\#hash`));
    assert(reads("trail   ", "trail"));
    assert(reads(`keep\ `, `keep\ `), "an escaped trailing space stays");
    assert(reads("tab\t", "tab\t"), "git trims spaces, not tabs");
    assert(reads("*.{c,h}", `*.\{c,h\}`), "git has no brace alternatives");
    assert(reads(`odd\`, `odd\`));
    assert(reads("!!x", `\!x`, true), "one `!` negates; the next is literal");
}

// ---------------------------------------------------------------- the arena

/// No scope, and no block: a directory beneath no `.gitignore`.
enum uint noScope = uint.max;

/// The bounds of a resolution's scope arena (FSI2). Exceeding one is a
/// returned error.
struct IgnoreLimits
{
    uint maxScopes = 1 << 12;    /// scopes held at once
    uint maxRules = 1 << 12;     /// rules held at once
    uint maxGlobs = 1 << 10;     /// rule segments that need the glob engine, held at once
    uint maxFileBytes = 1 << 20; /// bytes of one `.gitignore`
    uint maxTextBytes = 1 << 22; /// bytes of `.gitignore` text, translations and paths held at once
    uint maxPositions = 1 << 18; /// position words held at once
}

/// One `.gitignore`: its rules are `firstRule .. firstRule + ruleCount`.
struct IgnoreScope
{
    uint parent = noScope; /// the scope of the directory above
    uint firstRule;        ///
    uint ruleCount;        /// its own rules
    uint chainRules;       /// rules of its whole chain, its own included
    uint depth;            /// scopes above it in its chain
    uint sourceStart;      /// its path, relative to the fileset root, in the text
    uint sourceLength;     /// ditto
}

/// The longest scope chain: one `.gitignore` per directory on a path no
/// deeper than `ResolutionLimits.maxDepth` allows, and the fileset root's.
enum uint maxScopeChain = 128;

/// One rule of a scope.
struct ScopeRule
{
    uint pattern;  /// into the arena's `PatternSet`
    uint scope_;   /// the scope that declared it
    uint line;     /// 1-based (FSI3)
    bool negated;  /// a `!` rule re-includes
    bool dirOnly;  /// a trailing `/`
}

/**
A directory's ignore state: `block` names its positions in the arena (or is
`noScope` when no rule applies), and `excluded` latches an excluded
directory on its path. One word, copied by value (FSI1).
*/
struct IgnoreState
{
    ulong word = noScope;

    enum ulong latch = 1UL << 63;

    /// Whether a directory on the path, this one included, is excluded.
    bool excluded() const @safe pure nothrow @nogc => (word & latch) != 0;

    /// The positions block, or `noScope`.
    uint block() const @safe pure nothrow @nogc => cast(uint) word;

    /// The state of an excluded directory.
    static IgnoreState excludedState() @safe pure nothrow @nogc => IgnoreState(latch | noScope);
}

/// The rule that decided an entry, for tracing (FSI3).
struct IgnoreDecisionRef
{
    uint rule = noScope; /// into `IgnoreScopes.rules`; `noScope` when none matched
    bool excluded;       /// the verdict

    /// Whether a rule matched.
    bool decided() const @safe pure nothrow @nogc => rule != noScope;
}

/// Why adding a scope failed.
enum ScopeError : ubyte
{
    none,         ///
    capacity,     /// a bound of `IgnoreLimits`
    fileTooLarge, /// a `.gitignore` over `maxFileBytes`
}

/**
The scope chain of one resolution (FSI1, FSI2). Move-only; it allocates its
storage when made and nothing after.
*/
struct IgnoreScopes
{
    @disable this(this);

    package PatternSet patterns;
    package HeapBuffer!IgnoreScope scopes;
    package HeapBuffer!ScopeRule rules;
    package HeapBuffer!char text;
    package HeapBuffer!ulong positions;
    private Unique!PatternCompileWorkspace workspace;
    private IgnoreLimits lim;
    private uint scopesTop, rulesTop, textTop, positionsTop;
    private uint peakScopes_, peakTextBytes_;
    private uint skipped_;
    private bool overflowed_;

    /// Where the arena stands, for `release`.
    static struct Mark
    {
        private PatternSet.Mark patterns;
        private uint scopes, rules, text, positions;
    }

    /// An arena within `limits` whose patterns match under `policy`. Allocates.
    this(CasePolicy policy, IgnoreLimits limits) @safe nothrow @nogc
    {
        import sparkles.build_primitives.fileset.pattern : maxPatternSegments;

        lim = limits;
        patterns = PatternSet(policy);
        // A gitignore rule is a few components, most of them literals that
        // need no program; the bound is checked against a pattern's worst
        // case, so leave room for one.
        patterns.reserve(limits.maxRules, 4 * limits.maxRules + maxPatternSegments + 1,
            limits.maxGlobs + maxPatternSegments);
        scopes.length = limits.maxScopes;
        rules.length = limits.maxRules;
        text.length = limits.maxTextBytes;
        positions.length = limits.maxPositions;
        workspace = makeUnique!PatternCompileWorkspace();
    }

    /// Whether the arena was made (an `IgnoreScopes.init` holds nothing).
    bool ready() const @safe pure nothrow @nogc => !workspace.empty;

    /// The current extent.
    Mark mark() const @safe pure nothrow @nogc
        => Mark(patterns.mark, scopesTop, rulesTop, textTop, positionsTop);

    /// Forgets every scope, rule and block made since `m`. Never allocates.
    void release(Mark m) @safe pure nothrow @nogc
    {
        patterns.release(m.patterns);
        scopesTop = m.scopes;
        rulesTop = m.rules;
        textTop = m.text;
        positionsTop = m.positions;
    }

    /// The most scopes, and bytes of text, held at once (FSI2).
    uint peakScopes() const @safe pure nothrow @nogc => peakScopes_;
    /// ditto
    uint peakTextBytes() const @safe pure nothrow @nogc => peakTextBytes_;

    /// Rule lines git reads that the fileset syntax cannot, and were skipped.
    uint skippedRules() const @safe pure nothrow @nogc => skipped_;

    /// Whether `enter` ever lacked room for a block. Sticky: a resolution
    /// treats it as a bound exceeded.
    bool overflowed() const @safe pure nothrow @nogc => overflowed_;

    /// The scope `s`.
    IgnoreScope opIndex(uint s) const @safe pure nothrow @nogc => scopes[s];

    /// The rule `r`.
    ScopeRule rule(uint r) const @safe pure nothrow @nogc => rules[r];

    /// The path of scope `s`'s `.gitignore`, relative to the fileset root.
    const(char)[] sourceOf(uint s) const return @safe pure nothrow @nogc
        => text[][scopes[s].sourceStart .. scopes[s].sourceStart + scopes[s].sourceLength];

    /// The pattern of rule `r`, as translated (FSI3's report).
    const(char)[] patternOf(uint r) const return @safe pure nothrow @nogc
        => patterns[rules[r].pattern].source;

    /**
    Room for one `.gitignore`'s bytes, at most `maxFileBytes`: a driver reads
    the file into it, then the bytes are passed to `add`. Empty when the
    arena is full.
    */
    char[] room() return @safe pure nothrow @nogc
    {
        const free = text.length - textTop;
        const n = free < lim.maxFileBytes ? free : lim.maxFileBytes;
        return text[][textTop .. textTop + n];
    }

    /**
    Adds the scope of the `.gitignore` at `source` (relative to the fileset
    root) whose first `length` bytes are in `room`, beneath the chain of
    `parent`'s block, and returns the extended state of its directory in
    `state`. A rule the fileset syntax cannot read is skipped and counted.
    */
    ScopeError add(IgnoreState parent, scope const(char)[] source, size_t length,
        out IgnoreState state) @safe pure nothrow @nogc
    in (!parent.excluded, "an excluded directory's .gitignore is never read")
    {
        if (length > lim.maxFileBytes)
            return ScopeError.fileTooLarge;
        if (scopesTop == scopes.length)
            return ScopeError.capacity;
        const raw = textTop;
        textTop += cast(uint) length;
        if (!putText(source))
            return ScopeError.capacity;
        const parentBlock = parent.block;
        const parentScope = parentBlock == noScope ? noScope : cast(uint) positions[parentBlock];
        const inherited = parentScope == noScope ? 0 : scopes[parentScope].chainRules;

        IgnoreScope s;
        s.parent = parentScope;
        s.depth = parentScope == noScope ? 0 : scopes[parentScope].depth + 1;
        if (s.depth >= maxScopeChain)
            return ScopeError.capacity;
        s.firstRule = rulesTop;
        s.sourceStart = textTop - cast(uint) source.length;
        s.sourceLength = cast(uint) source.length;
        const self = scopesTop;

        uint line;
        size_t start = raw;
        foreach (i; raw .. raw + length + 1)
        {
            if (i < raw + length && text[i] != '\n')
                continue;
            ++line;
            const lineText = text[][start .. i];
            start = i + 1;
            const need = ignoreLineRoom(lineText.length);
            if (text.length - textTop < need)
                return ScopeError.capacity;
            auto into = text[][textTop .. textTop + need];
            const read = readIgnoreLine(lineText, into);
            if (read.kind == IgnoreLineKind.blank)
                continue;
            if (rulesTop == rules.length)
                return ScopeError.capacity;
            // The translation stays in the arena, below every later mark, for
            // as long as the pattern that borrows it.
            auto pattern = (() @trusted => cast(string) into[0 .. read.length])();
            auto p = patterns.add(pattern, *workspace);
            if (p.hasError)
            {
                if (p.error.code == FilesetErrorCode.capacityExceeded)
                    return ScopeError.capacity;
                ++skipped_;
                continue;
            }
            textTop += cast(uint) read.length;
            rules[rulesTop++] = ScopeRule(p.value, self, line, read.negated,
                patterns[p.value].dirOnly);
        }
        s.ruleCount = rulesTop - s.firstRule;
        s.chainRules = inherited + s.ruleCount;
        scopes[scopesTop++] = s;
        if (scopesTop > peakScopes_)
            peakScopes_ = scopesTop;
        if (textTop > peakTextBytes_)
            peakTextBytes_ = textTop;

        // The directory's block: its parent's positions, then the start of
        // each of its own rules.
        const block = allocBlock(self, s.chainRules);
        if (block == noScope)
            return ScopeError.capacity;
        if (inherited)
            positions[][block + 1 .. block + 1 + inherited]
                = positions[][parentBlock + 1 .. parentBlock + 1 + inherited];
        foreach (r; 0 .. s.ruleCount)
            positions[block + 1 + inherited + r] = patterns.start(rules[s.firstRule + r].pattern);
        state = IgnoreState(block);
        return ScopeError.none;
    }

    /**
    The state of the child directory `name` of a directory in state
    `parent`: every position stepped over `name`, and the latch set if the
    last matching rule excludes the child. `noScope` positions in, none out;
    `false` when the arena has no room for the block.
    */
    bool enter(IgnoreState parent, scope const(char)[] name, ref MatchScratch scratch,
        out IgnoreState child) @safe pure nothrow @nogc
    {
        if (parent.excluded || parent.block == noScope)
        {
            child = parent;
            return true;
        }
        const from = parent.block;
        const sc = cast(uint) positions[from];
        const count = scopes[sc].chainRules;
        const block = allocBlock(sc, count);
        if (block == noScope)
        {
            overflowed_ = true;
            child = parent;
            return false;
        }
        bool excluded;
        uint[maxScopeChain] chain = void;
        uint k;
        foreach (s; chain[0 .. chainOf(sc, chain)])
            foreach (ri; scopes[s].firstRule .. scopes[s].firstRule + scopes[s].ruleCount)
            {
                const r = rules[ri];
                const next = patterns.step(r.pattern, positions[from + 1 + k], name, scratch);
                positions[block + 1 + k] = next;
                if (patterns.complete(r.pattern, next))
                    excluded = !r.negated;
                ++k;
            }
        if (excluded)
        {
            // Nothing beneath is consulted again: give the block back.
            positionsTop = block;
            child = IgnoreState.excludedState;
            return true;
        }
        child = IgnoreState(block);
        return true;
    }

    /// Whether the non-directory `name` in a directory in state `state` is
    /// excluded.
    bool excludesFile(IgnoreState state, scope const(char)[] name, ref MatchScratch scratch)
        const @safe pure nothrow @nogc
        => decideFile(state, name, scratch).excluded;

    /// The rule that decides the non-directory `name` in a directory in
    /// state `state`; undecided beneath an excluded directory (FSI3).
    IgnoreDecisionRef decideFile(IgnoreState state, scope const(char)[] name,
        ref MatchScratch scratch) const @safe pure nothrow @nogc
        => decide(state, name, false, scratch);

    /// The rule that decides the directory `name` in a directory in state
    /// `state`; undecided beneath an excluded directory (FSI3).
    IgnoreDecisionRef decideDir(IgnoreState state, scope const(char)[] name,
        ref MatchScratch scratch) const @safe pure nothrow @nogc
        => decide(state, name, true, scratch);

private:
    bool putText(scope const(char)[] s) @safe pure nothrow @nogc
    {
        if (text.length - textTop < s.length)
            return false;
        text[][textTop .. textTop + s.length] = s[];
        textTop += cast(uint) s.length;
        return true;
    }

    uint allocBlock(uint sc, uint count) @safe pure nothrow @nogc
    {
        if (positions.length - positionsTop < count + 1)
            return noScope;
        const at = positionsTop;
        positions[at] = sc;
        positionsTop += count + 1;
        return at;
    }

    // The scopes of the chain ending at `sc`, outermost first; their count.
    uint chainOf(uint sc, ref uint[maxScopeChain] chain) const @safe pure nothrow @nogc
    {
        const n = scopes[sc].depth + 1;
        uint s = sc;
        foreach_reverse (i; 0 .. n)
        {
            chain[i] = s;
            s = scopes[s].parent;
        }
        return n;
    }

    IgnoreDecisionRef decide(IgnoreState state, scope const(char)[] name, bool isDir,
        ref MatchScratch scratch) const @safe pure nothrow @nogc
    {
        if (state.excluded)
            return IgnoreDecisionRef(noScope, true);
        IgnoreDecisionRef d;
        if (state.block == noScope)
            return d;
        const sc = cast(uint) positions[state.block];
        uint[maxScopeChain] chain = void;
        uint k;
        foreach (s; chain[0 .. chainOf(sc, chain)])
            foreach (ri; scopes[s].firstRule .. scopes[s].firstRule + scopes[s].ruleCount)
            {
                const r = rules[ri];
                const at = positions[state.block + 1 + k++];
                if (r.dirOnly && !isDir)
                    continue;
                if (patterns.complete(r.pattern, patterns.step(r.pattern, at, name, scratch)))
                    d = IgnoreDecisionRef(ri, !r.negated);
            }
        return d;
    }
}

version (unittest)
{
    // A small arena, and helpers that build a chain by hand.
    private struct ScopeFixture
    {
        IgnoreScopes scopes;
        Unique!MatchScratch scratch;

        static ScopeFixture make() @safe nothrow
        {
            ScopeFixture f;
            f.scopes = IgnoreScopes(CasePolicy.sensitive, IgnoreLimits(maxScopes: 8, maxRules: 32,
                maxGlobs: 16, maxFileBytes: 256, maxTextBytes: 4096, maxPositions: 512));
            f.scratch = makeUnique!MatchScratch();
            return f;
        }

        IgnoreState read(IgnoreState dir, string path, string text) @safe nothrow
        {
            auto room = scopes.room;
            room[0 .. text.length] = text[];
            IgnoreState s;
            assert(scopes.add(dir, path, text.length, s) == ScopeError.none);
            return s;
        }

        IgnoreState into(IgnoreState dir, string name) @safe nothrow
        {
            IgnoreState c;
            assert(scopes.enter(dir, name, *scratch, c));
            return c;
        }

        bool ignores(IgnoreState dir, string file) @safe nothrow
            => scopes.excludesFile(dir, file, *scratch);
    }
}

/// FSI1: a directory's ignore state is one word, and the chain it names is
/// never changed, so siblings evaluate against one chain independently.
@("fileset.ignore.FSI1.immutableChain")
@safe nothrow unittest
{
    static assert(IgnoreState.sizeof == ulong.sizeof);

    auto f = ScopeFixture.make();
    const root = f.read(IgnoreState.init, ".gitignore", "*.log\n");
    const a = f.into(root, "a");
    const b = f.into(root, "b");
    const aScoped = f.read(a, "a/.gitignore", "!*.log\n");
    assert(!f.ignores(aScoped, "x.log"));
    assert(f.ignores(a, "x.log"), "a's state before its scope is unchanged");
    assert(f.ignores(b, "x.log"), "a sibling's scope does not reach b");
    assert(f.ignores(f.into(root, "c"), "x.log"), "nor a directory entered after it");
}

/// FSI4: git's precedence, each clause.
@("fileset.ignore.FSI4.precedence")
@safe nothrow unittest
{
    auto f = ScopeFixture.make();
    const root = f.read(IgnoreState.init, ".gitignore", "*.log\n!keep.log\nbuild/\n/top\n");

    // Within a scope, the last matching rule decides.
    assert(f.ignores(root, "a.log"));
    assert(!f.ignores(root, "keep.log"));

    // A deeper scope overrides a shallower one, and anchors to its own
    // directory.
    const src = f.read(f.into(root, "src"), "src/.gitignore", "!*.log\n/gen/\n");
    assert(!f.ignores(src, "a.log"));
    assert(f.into(src, "gen").excluded);
    assert(!f.into(f.into(src, "x"), "gen").excluded, "`/gen/` is anchored to src");
    assert(!f.into(src, "top").excluded, "`/top` is anchored to the root");
    assert(f.into(root, "top").excluded);

    // A negation cannot re-include a file beneath an excluded directory.
    const build = f.into(root, "build");
    assert(build.excluded);
    assert(f.ignores(f.into(build, "keep"), "keep.log"));

    // A directory-only rule does not exclude a file of that name.
    assert(!f.ignores(root, "build"));
}

/// FSI3: the deciding rule names its file and line.
@("fileset.ignore.FSI3.provenance")
@safe nothrow unittest
{
    auto f = ScopeFixture.make();
    const root = f.read(IgnoreState.init, ".gitignore", "# objects\n*.o\n\n!keep.o\n");
    const d = f.scopes.decideFile(root, "keep.o", *f.scratch);
    assert(d.decided && !d.excluded);
    const r = f.scopes.rule(d.rule);
    assert(r.line == 4 && f.scopes.sourceOf(r.scope_) == ".gitignore");
    assert(f.scopes.patternOf(d.rule) == "keep.o");
    assert(!f.scopes.decideFile(root, "main.c", *f.scratch).decided);
}

/// FSI2: the arena is released in stack order, and reports its peak.
@("fileset.ignore.FSI2.release")
@safe nothrow unittest
{
    auto f = ScopeFixture.make();
    const m = f.scopes.mark;
    const root = f.read(IgnoreState.init, ".gitignore", "*.o\n");
    cast(void) f.read(f.into(root, "a"), "a/.gitignore", "*.tmp\n");
    assert(f.scopes.peakScopes == 2);
    f.scopes.release(m);
    const again = f.read(IgnoreState.init, ".gitignore", "*.d\n");
    assert(f.ignores(again, "x.d") && !f.ignores(again, "x.o"));
    assert(f.scopes.peakScopes == 2);
}

/// A rule the fileset syntax cannot read is skipped, and counted; a bound
/// is an error.
@("fileset.ignore.bounds")
@safe nothrow unittest
{
    auto f = ScopeFixture.make();
    const root = f.read(IgnoreState.init, ".gitignore", "./x\n*.o\n");
    assert(f.scopes.skippedRules == 1);
    assert(f.ignores(root, "a.o"));

    string many;
    foreach (i; 0 .. 40)
        many ~= "r\n";
    auto room = f.scopes.room;
    room[0 .. many.length] = many[];
    IgnoreState s;
    assert(f.scopes.add(root, "x/.gitignore", many.length, s) == ScopeError.capacity);
    assert(f.scopes.add(root, "y/.gitignore", 300, s) == ScopeError.fileTooLarge);
}
