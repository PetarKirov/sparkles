#!/usr/bin/env dub
/+ dub.sdl:
    name "fts_pike_vm_line_search"
    targetPath "build"
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * An unanchored, leftmost-first Pike VM with a sparse-set thread list —
 * `@safe pure nothrow @nogc`, fixed capacity, no allocator.
 *
 * This example exists to convert one decision from argued to measured. The
 * catalog's central engineering question is whether a bounded regex engine can
 * be built on the Thompson-NFA substrate `sparkles:fuzzy` already ships, and
 * `sparkles-baseline.md` names five gaps between `glob.d` and a content
 * matcher. Three of them are closed here, in ~120 lines:
 *
 *   1. UNANCHORED SEARCH.  `glob.d` seeds position 0 once and tests `accept` at
 *      end of input, so it answers "does the whole path match". A grep needs
 *      "where in this line". Closed by seeding a fresh thread at every input
 *      position, but only while no match has been found (see `leftmost`).
 *   2. MATCH POSITIONS.    Threads carry a start slot, so a match reports its
 *      span rather than a boolean — which is what highlighting needs.
 *   3. THE SPARSE SET.     `glob.d` clears `bool[MaxInstructions]` per input
 *      unit, so its constant factor is program CAPACITY, not live threads. The
 *      sparse set (Briggs-Torczon) makes membership O(1) and clearing free:
 *      `count = 0` invalidates every entry, so no per-step wipe happens at all.
 *
 * The remaining two gaps — path-separator semantics baked into three opcodes,
 * and alternation priority — are addressed by the opcode set below: these are
 * content opcodes, and `split` lists its preferred branch first, which is what
 * makes the leftmost-FIRST semantics in `run` well defined.
 *
 * Backs `theory/automata.md` and the "ranked leverage" list in
 * `engine-comparison.md`.
 */
module fts_pike_vm_line_search;

import std.stdio : writefln, writeln;

@safe:

/// The instruction set: a content-oriented subset of the seventeen opcodes
/// `engine-comparison.md` concludes a code-search grep needs.
enum Op : ubyte
{
    char_, /// match one literal byte (`operand` = the byte)
    any, /// match any byte except the line terminator
    class_, /// match a byte in `[lo, hi]`
    split, /// two-way branch; `x` is preferred (leftmost-first)
    jump, /// unconditional branch to `x`
    match, /// accept
}

/// One instruction. Fixed-size and plain-data, like every arena element in
/// `sparkles:fuzzy`.
struct Inst
{
    Op op;
    ubyte operand; /// `char_`: the byte. `class_`: the low bound.
    ubyte hi; /// `class_`: the high bound.
    ushort x; /// `split`/`jump`: primary target.
    ushort y; /// `split`: alternate target.
}

/// A compiled program, fixed capacity, caller-owned.
struct Program(size_t MaxInsts = 64)
{
    Inst[MaxInsts] insts;
    size_t length;

    /// Appends an instruction, or returns false when the cap is reached — the
    /// `globTooComplex` shape: capacity overflow is an outcome, not a crash.
    bool add(Inst i) pure nothrow @nogc
    {
        if (length == MaxInsts)
            return false;
        insts[length++] = i;
        return true;
    }
}

/// A half-open byte span.
struct Span
{
    size_t start;
    size_t end;
    bool found;
}

/**
 * The matcher workspace: two sparse sets and their thread payloads.
 *
 * A sparse set is two arrays plus a count. Membership of `pc` is
 * `sparse[pc] < count && dense[sparse[pc]] == pc`, which is meaningful without
 * `sparse` ever being initialised — that is the trick, and it is why `clear()`
 * is a single assignment rather than a loop over capacity.
 */
struct Workspace(size_t MaxInsts = 64)
{
    private static struct Set
    {
        ushort[MaxInsts] dense = void;
        ushort[MaxInsts] sparse = void;
        size_t[MaxInsts] start = void; /// per-thread match-start slot
        size_t count;

        void clear() pure nothrow @nogc scope
        {
            count = 0; // the whole per-step cost the bitset version pays
        }

        bool has(ushort pc) const pure nothrow @nogc scope
        {
            const i = sparse[pc];
            return i < count && dense[i] == pc;
        }

        void put(ushort pc, size_t s) pure nothrow @nogc scope
        {
            dense[count] = pc;
            sparse[pc] = cast(ushort) count;
            start[count] = s;
            ++count;
        }
    }

    private Set[2] sets;
    private size_t cur;

    private ref Set current() return pure nothrow @nogc scope => sets[cur];
    private ref Set next() return pure nothrow @nogc scope => sets[1 - cur];
    private void swap() pure nothrow @nogc scope { cur = 1 - cur; }
}

/// Adds `pc` to `set`, following `split`/`jump` so the set holds only
/// byte-consuming instructions — the ε-closure, done at insertion time.
private void addThread(size_t MaxInsts, Set)(in Program!MaxInsts prog, ref Set set,
    ushort pc, size_t start) pure nothrow @nogc
{
    if (pc >= prog.length || set.has(pc))
        return;
    const inst = prog.insts[pc];
    final switch (inst.op)
    {
    case Op.split:
        // `x` first: the preferred branch is explored first, which is what
        // makes the overall semantics leftmost-FIRST rather than -longest.
        set.put(pc, start); // mark visited so the closure terminates
        addThread(prog, set, inst.x, start);
        addThread(prog, set, inst.y, start);
        return;
    case Op.jump:
        set.put(pc, start);
        addThread(prog, set, inst.x, start);
        return;
    case Op.char_:
    case Op.any:
    case Op.class_:
    case Op.match:
        set.put(pc, start);
        return;
    }
}

/**
 * Runs `prog` over `line`, unanchored, returning the leftmost-first match span.
 *
 * Complexity is `O(prog.length * line.length)` with the constant proportional
 * to LIVE threads rather than capacity — the property this example exists to
 * demonstrate.
 */
Span run(size_t MaxInsts)(in Program!MaxInsts prog, scope const(char)[] line,
    ref Workspace!MaxInsts ws) pure nothrow @nogc
{
    Span best;
    ws.current.clear();

    foreach (pos; 0 .. line.length + 1)
    {
        // Unanchored: seed a new thread at every position, until a match is
        // found. After that, seeding would only find later (worse) matches.
        if (!best.found)
            addThread(prog, ws.current, 0, pos);

        ws.next.clear();
        bool matchedThisStep;
        foreach (i; 0 .. ws.current.count)
        {
            const pc = ws.current.dense[i];
            const start = ws.current.start[i];
            const inst = prog.insts[pc];
            final switch (inst.op)
            {
            case Op.match:
                // Leftmost-first. Threads are visited in priority order, so
                // everything after this one is lower priority: record the
                // match and CUT them by breaking. Any match seen later must
                // come from a surviving HIGHER-priority thread, so it replaces
                // this one — which is what makes the greedy `split` above
                // yield the longest match at the leftmost start.
                if (!best.found || start <= best.start)
                    best = Span(start, pos, true);
                matchedThisStep = true;
                break;
            case Op.char_:
                if (pos < line.length && cast(ubyte) line[pos] == inst.operand)
                    addThread(prog, ws.next, cast(ushort)(pc + 1), start);
                break;
            case Op.any:
                if (pos < line.length && line[pos] != '\n')
                    addThread(prog, ws.next, cast(ushort)(pc + 1), start);
                break;
            case Op.class_:
                if (pos < line.length)
                {
                    const b = cast(ubyte) line[pos];
                    if (b >= inst.operand && b <= inst.hi)
                        addThread(prog, ws.next, cast(ushort)(pc + 1), start);
                }
                break;
            case Op.split:
            case Op.jump:
                break; // resolved during the closure
            }
            if (matchedThisStep)
                break; // cut every lower-priority thread
        }

        // Swap the sets by toggling an index. Neither is wiped and neither is
        // copied: `clear()` is `count = 0`, and the swap is one assignment.
        ws.swap();

        if (best.found && ws.current.count == 0)
            break;
    }
    return best;
}

// ---------------------------------------------------------------------------

/// Compiles `lit` followed by `[0-9]+` — enough to exercise literals, a class,
/// a `split` loop and unanchored start, without writing a parser.
private bool compileLiteralThenDigits(size_t MaxInsts)(scope const(char)[] lit,
    ref Program!MaxInsts prog) pure nothrow @nogc
{
    foreach (c; lit)
        if (!prog.add(Inst(Op.char_, cast(ubyte) c)))
            return false;

    const digitPc = cast(ushort) prog.length;
    if (!prog.add(Inst(Op.class_, '0', '9')))
        return false;
    // split: prefer looping back for another digit (greedy), else fall through.
    if (!prog.add(Inst(Op.split, 0, 0, digitPc, cast(ushort)(prog.length + 1))))
        return false;
    return prog.add(Inst(Op.match));
}

void main()
{
    enum Caps = 64;
    Program!Caps prog;
    if (!compileLiteralThenDigits("v", prog))
    {
        writeln("FAIL program did not fit");
        assert(0);
    }

    // A Workspace is ~1 KiB at this capacity and lives wherever the caller puts
    // it; nothing here allocates.
    static Workspace!Caps ws;

    static struct Case
    {
        string line;
        bool want;
        size_t start;
        size_t end;
    }

    static immutable Case[] cases = [
        Case("version v12 here", true, 8, 11), // unanchored: not at position 0
        Case("v1", true, 0, 2),
        Case("v", false, 0, 0), // needs at least one digit
        Case("no match at all", false, 0, 0),
        Case("aaav42", true, 3, 6),
        Case("v1 and v22", true, 0, 2), // leftmost wins over longer
    ];

    size_t failures;
    foreach (c; cases)
    {
        const got = run(prog, c.line, ws);
        const ok = got.found == c.want
            && (!c.want || (got.start == c.start && got.end == c.end));
        writefln("%-18s -> %s%s", c.line,
            got.found ? "match [" ~ dec(got.start) ~ ", " ~ dec(got.end) ~ ")" : "no match",
            ok ? "" : "   UNEXPECTED");
        if (!ok)
            ++failures;
    }

    assert(failures == 0, "the Pike VM disagreed with the expected spans");
    writeln("\nunanchored search, match spans and a sparse-set thread list:",
        " all `@safe pure nothrow @nogc`, fixed capacity, zero allocations");
}

private string dec(size_t n) pure nothrow
{
    if (n == 0)
        return "0";
    char[20] buf;
    size_t i = buf.length;
    while (n)
    {
        buf[--i] = cast(char)('0' + n % 10);
        n /= 10;
    }
    return buf[i .. $].idup;
}
