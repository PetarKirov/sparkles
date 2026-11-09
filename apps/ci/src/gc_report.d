/++
`ci --gc-report`: where a program's GC allocations come from, and what of them
stays live, from a `sparkles.profiling.gc_sampler` recording.

A run of a program that links the sampler, with
`SPARKLES_GC_SAMPLES=run.gcs … --DRT-gcopt=gc:sampler`, writes `run.gcs`. This
report symbolizes its stacks (`addr2line`, which the dev shell provides) and
attributes every sampled byte to its allocation site — the first frame in the
repository — and inclusively to every repository function on its stack. With
`--gc-baseline` it subtracts a shorter run of the same scenario, which leaves
the steady cost: a 1200-frame drag minus a 200-frame one is a thousand frames
without their start-up. A recording's live census splits what survived the
last collection into what the collector scans and what it does not: the
scanned part is what each pause marks.

Split out from `app.d` so the parser and the attribution can be unit-tested
(the main source file is excluded from the auto-generated test runner).
+/
module gc_report;

import std.algorithm : canFind, endsWith, filter, map, min, sort, startsWith, sum;
import std.array : array, split;
import std.conv : to;
import std.format : format;
import std.string : indexOf, lastIndexOf, strip;

/// One record of a recording: a sample (`S`), a collection (`C`) or a live
/// block (`L`).
struct GcRecord
{
    char kind;
    size_t bytes;     /// S, L: the bytes it stands for; C: allocated before it
    size_t value;     /// S: allocations; C: pause in µs; L: 1 when scanned
    string[] frames;  /// `module@offset`, innermost first
}

/// A parsed recording.
struct GcProfile
{
    size_t totalBytes, totalAllocs, collections;
    GcRecord[] records;
}

/// Parses a recording's text.
GcProfile parseGcProfile(string text) @safe pure
{
    GcProfile p;
    foreach (line; text.split('\n'))
    {
        line = line.strip;
        if (!line.length)
            continue;
        if (line[0] == '#')
        {
            const parts = line[1 .. $].split;
            foreach (i; 0 .. parts.length / 2)
            {
                const value = parts[2 * i + 1].to!size_t;
                switch (parts[2 * i])
                {
                    case "total": p.totalBytes = value; break;
                    case "allocs": p.totalAllocs = value; break;
                    case "collections": p.collections = value; break;
                    default: break;
                }
            }
            continue;
        }
        const parts = line.split(' ');
        if (parts.length < 3 || parts[0].length != 1 || !"SCL".canFind(parts[0][0]))
            continue;
        p.records ~= GcRecord(parts[0][0], parts[1].to!size_t, parts[2].to!size_t, parts[3 .. $].dup);
    }
    return p;
}

@("gc_report.parseGcProfile")
@safe pure unittest
{
    const p = parseGcProfile("# total 300 allocs 7 collections 1\n"
        ~ "S 200 5 /bin/x@0x10 /bin/x@0x20\nC 250 1800 /bin/x@0x30\nL 200 1 /bin/x@0x10\nbogus\n");
    assert(p.totalBytes == 300 && p.totalAllocs == 7 && p.collections == 1);
    assert(p.records.length == 3);
    assert(p.records[0] == GcRecord('S', 200, 5, ["/bin/x@0x10", "/bin/x@0x20"]));
    assert(p.records[1].kind == 'C' && p.records[1].value == 1800);
    assert(p.records[2].kind == 'L' && p.records[2].value == 1);
}

/// A frame resolved to its function and source location; an address inlines
/// several, innermost first.
struct SourceFrame
{
    string func, location;
}

/// Each frame's source frames.
alias Symbols = SourceFrame[][string];

/// Where a stack's bytes are attributed: its first frame under `root` (the
/// repository), skipping the sampler's own; `"(no repository frame)"` when
/// none is.
string siteOf(in string[] stack, in Symbols symbols, string root) @safe pure
{
    foreach (frame; stack)
        foreach (ref const s; symbols.get(frame, null))
            if (inRepository(s, root))
                return shortName(s.func) ~ "  " ~ relative(s.location, root);
    return "(no repository frame)";
}

/// Every repository function on a stack, once each: what its bytes count
/// towards inclusively.
string[] functionsOf(in string[] stack, in Symbols symbols, string root) @safe pure
{
    string[] seen;
    foreach (frame; stack)
        foreach (ref const s; symbols.get(frame, null))
            if (inRepository(s, root) && !seen.canFind(shortName(s.func)))
                seen ~= shortName(s.func);
    return seen;
}

private bool inRepository(in SourceFrame s, string root) @safe pure
    => s.location.startsWith(root) && !s.location.canFind("gc_sampler.d");

private string relative(string location, string root) @safe pure
{
    auto s = location[root.length .. $];
    const d = s.indexOf(" (discriminator");
    return d > 0 ? s[0 .. d] : s;
}

// A demangled name without its parameters, return type or attributes.
private string shortName(string func) @safe pure
{
    const paren = func.indexOf('(');
    auto s = paren > 0 ? func[0 .. paren] : func;
    const space = s.lastIndexOf(' ');
    s = space >= 0 ? s[space + 1 .. $] : s;
    return s.length > 100 ? s[0 .. 100] : s;
}

@("gc_report.siteOfAndFunctionsOf")
@safe pure unittest
{
    Symbols symbols;
    symbols["/x@0x1"] = [SourceFrame("pure @safe void sparkles.base.gc_sampler.note(ulong)",
        "/repo/libs/profiling/src/sparkles/profiling/gc_sampler.d:9")];
    symbols["/x@0x2"] = [SourceFrame("std.array.Appender!(int[]).put", "/nix/phobos/std/array.d:3")];
    symbols["/x@0x3"] = [SourceFrame("@safe int[] app.build(int)", "/repo/apps/app.d:12 (discriminator 2)"),
        SourceFrame("void app.run()", "/repo/apps/app.d:30")];
    const stack = ["/x@0x1", "/x@0x2", "/x@0x3", "/x@0x9"];
    assert(siteOf(stack, symbols, "/repo/") == "app.build  apps/app.d:12");
    assert(functionsOf(stack, symbols, "/repo/") == ["app.build", "app.run"]);
    assert(siteOf(["/x@0x2"], symbols, "/repo/") == "(no repository frame)");
}

/// Bytes (and records) per key, the keys largest first.
struct Tally
{
    size_t[string] bytes;
    size_t total;

    void add(string key, size_t n) @safe pure
    {
        bytes[key] = bytes.get(key, 0) + n;
        total += n;
    }

    /// The keys, largest first.
    string[] ranked() const @safe pure
    {
        string[] keys;
        foreach (key, _; bytes)
            keys ~= key;
        return keys.sort!((a, b) => bytes[a] > bytes[b] || bytes[a] == bytes[b] && a < b).release;
    }
}

/// Tallies `kind`'s records by site, and inclusively by function; `keep`
/// selects records (a live census's scanned or unscanned blocks).
void tally(in GcProfile p, char kind, in Symbols symbols, string root,
    ref Tally bySite, ref Tally byFunction, bool delegate(in GcRecord) @safe pure keep = null) @safe pure
{
    foreach (ref const r; p.records)
    {
        if (r.kind != kind || (keep !is null && !keep(r)))
            continue;
        bySite.add(siteOf(r.frames, symbols, root), r.bytes);
        foreach (f; functionsOf(r.frames, symbols, root))
            byFunction.bytes[f] = byFunction.bytes.get(f, 0) + r.bytes;
        byFunction.total += r.bytes;
    }
}

@("gc_report.tally")
@safe pure unittest
{
    Symbols symbols;
    symbols["/x@0x1"] = [SourceFrame("a.f", "/r/a.d:1")];
    symbols["/x@0x2"] = [SourceFrame("a.g", "/r/a.d:2")];
    const p = parseGcProfile("S 100 1 /x@0x1 /x@0x2\nS 50 1 /x@0x2\nL 100 0 /x@0x1\nL 70 1 /x@0x2\n");
    Tally sites, functions;
    tally(p, 'S', symbols, "/r/", sites, functions);
    assert(sites.total == 150 && sites.bytes["a.f  a.d:1"] == 100 && sites.bytes["a.g  a.d:2"] == 50);
    assert(functions.bytes["a.g"] == 150 && functions.bytes["a.f"] == 100);
    assert(sites.ranked == ["a.f  a.d:1", "a.g  a.d:2"]);
    Tally scanned, ignored;
    tally(p, 'L', symbols, "/r/", scanned, ignored, (in GcRecord r) => r.value == 1);
    assert(scanned.total == 70 && scanned.bytes.keys == ["a.g  a.d:2"]);
}

/// The steady difference of two tallies: what `run` has over `baseline`, by key.
Tally difference(in Tally run, in Tally baseline) @safe pure
{
    Tally d;
    foreach (key, n; run.bytes)
    {
        const base = baseline.bytes.get(key, 0);
        if (n > base)
            d.add(key, n - base);
    }
    return d;
}

@("gc_report.difference")
@safe pure unittest
{
    Tally run, base;
    run.add("a", 900); run.add("b", 100); run.add("c", 40);
    base.add("a", 300); base.add("b", 100); base.add("d", 5);
    const d = difference(run, base);
    assert(d.total == 640 && d.bytes.length == 2 && d.bytes["a"] == 600 && d.bytes["c"] == 40);
}

/// Resolves every frame of the recordings with `addr2line`, one process per
/// module.
Symbols symbolize(in GcProfile[] profiles)
{
    import std.demangle : demangle;
    import std.process : pipeProcess, Redirect, wait;

    bool[string][string] offsetsByModule;
    foreach (ref p; profiles)
        foreach (ref r; p.records)
            foreach (frame; r.frames)
            {
                const at = frame.lastIndexOf('@');
                if (at > 0 && frame[0 .. at] != "?")
                    offsetsByModule[frame[0 .. at]][frame[at + 1 .. $]] = true;
            }
    Symbols symbols;
    foreach (module_, offsets; offsetsByModule)
    {
        // `-a` echoes each address zero-padded ("0x00000000000123ab"):
        // map it back to the frame as the recording spells it.
        string[string] frameOf;
        foreach (offset; offsets.byKey)
            frameOf[normalizeHex(offset[2 .. $])] = module_ ~ "@" ~ offset;
        auto pipes = pipeProcess(["addr2line", "-e", module_, "-f", "-i", "-a"], Redirect.all);
        foreach (offset; offsets.byKey)
            pipes.stdin.writeln(offset);
        pipes.stdin.close();
        string current, pendingFunc;
        foreach (line; pipes.stdout.byLineCopy)
        {
            if (pendingFunc is null && line.startsWith("0x"))
            {
                current = frameOf.get(normalizeHex(line[2 .. $]), null);
                continue;
            }
            if (pendingFunc is null)
            {
                pendingFunc = line;
                continue;
            }
            if (current !is null)
                symbols[current] ~= SourceFrame(demangle(pendingFunc).idup, line);
            pendingFunc = null;
        }
        pipes.pid.wait;
    }
    return symbols;
}

private string normalizeHex(string digits) @safe pure
{
    size_t i;
    while (i + 1 < digits.length && digits[i] == '0')
        ++i;
    return digits[i .. $];
}

/// `ci --gc-report`: prints the report; returns the exit status.
int runGcReport(string path, string baselinePath, size_t top)
{
    import std.file : getcwd, readText;
    import std.stdio : writefln, writeln;

    auto run = parseGcProfile(readText(path));
    GcProfile baseline;
    const hasBaseline = baselinePath.length > 0;
    if (hasBaseline)
        baseline = parseGcProfile(readText(baselinePath));
    const symbols = symbolize(hasBaseline ? [run, baseline] : [run]);
    const root = getcwd() ~ "/";

    static string mb(size_t n) => format("%8.1f MB", n / 1e6);
    // `of`: the bytes a share is of (an inclusive tally counts a byte once
    // per function on its stack, so its own total is not that).
    void list(string title, in Tally t, size_t of = 0)
    {
        const whole = of ? of : t.total;
        writeln("\n", title);
        foreach (key; t.ranked[0 .. min(top, $)])
            writefln("  %5.1f%%  %s  %s", whole ? 100.0 * t.bytes[key] / whole : 0, mb(t.bytes[key]), key);
    }

    writefln("%s: %s allocated in %s allocations, %s collections", path,
        mb(run.totalBytes).strip, run.totalAllocs, run.collections);
    auto pauses = run.records.filter!(r => r.kind == 'C').map!(r => r.value).array;
    if (pauses.length)
        writefln("pauses: %s µs (max %s µs)", pauses, pauses.sort.release[$ - 1]);

    Tally sites, functions;
    tally(run, 'S', symbols, root, sites, functions);
    if (hasBaseline)
    {
        Tally baseSites, baseFunctions;
        tally(baseline, 'S', symbols, root, baseSites, baseFunctions);
        writefln("baseline %s: %s; the difference: %s in %s allocations", baselinePath,
            mb(baseline.totalBytes).strip, mb(run.totalBytes - min(run.totalBytes, baseline.totalBytes)).strip,
            run.totalAllocs - min(run.totalAllocs, baseline.totalAllocs));
        const steady = difference(sites, baseSites);
        list("allocated, over the baseline, by site:", steady);
        list("allocated, over the baseline, inclusive by function:",
            difference(functions, baseFunctions), steady.total);
    }
    else
    {
        list("allocated, by site:", sites);
        list("allocated, inclusive by function:", functions);
    }

    Tally scanned, unscanned, ignored;
    tally(run, 'L', symbols, root, scanned, ignored, (in GcRecord r) => r.value == 1);
    tally(run, 'L', symbols, root, unscanned, ignored, (in GcRecord r) => r.value == 0);
    if (scanned.total + unscanned.total)
    {
        writefln("\nlive after the last collection: %s scanned, %s not scanned",
            mb(scanned.total).strip, mb(unscanned.total).strip);
        list("live and scanned (what each collection marks), by site:", scanned);
    }
    return 0;
}
