/**
 * Page-cache regime control for `@workload` tests: establish a declared
 * cache state — `cold` (evict), `warm` (preload), `steadyState` (leave
 * alone) — for the files a workload names, and $(B verify) what was
 * actually achieved instead of assuming it.
 *
 * The mechanics: `cold` is `posix_fadvise(POSIX_FADV_DONTNEED)` per file
 * (preceded by `fdatasync` — DONTNEED silently skips dirty pages); `warm`
 * is an explicit read-through preload (never the async `WILLNEED` advice,
 * which promises nothing); verification is `mmap` + `mincore` residency,
 * strided by `sysconf(_SC_PAGESIZE)` (Apple Silicon's 16 KiB pages make
 * hardcoded 4 KiB wrong). The pure `resolveStamp` policy turns
 * requested + filesystem kind + measured residency into an honest
 * `CacheRegimeStamp`: a regime that could not be established downgrades
 * `effective` with a reason, and residency that cannot be trusted is
 * $(I noted), never converted into a confident number.
 *
 * Filesystem honesty: on $(B tmpfs) the pages ARE the file — cold is
 * impossible by construction. On $(B ZFS), `mincore` is blind in both
 * directions: reads are served from the ARC without populating the Linux
 * page cache, so a warm-preloaded file can read 0 % resident while fully
 * cached, and a fadvised file reads 0 % while the ARC still holds
 * everything — the residency thresholds are suppressed there and the
 * stamp says so. `/proc/sys/vm/drop_caches` is deliberately never used:
 * it is a system-global, root-only sledgehammer that evicts every other
 * process's state — the per-file fadvise + verify + downgrade-note
 * contract is the honest scope (M8's cgroup `memory.max` is the scoped
 * successor if stronger eviction is ever needed).
 */
module sparkles.test_runner.cache_regime;

import std.math : isNaN;

import sparkles.test_runner.attributes : CacheRegime;

/// The filesystem kinds the regime policy distinguishes. `unknown` =
/// the probe failed (or the platform has no `statfs`) — thresholds still
/// apply, with an "fs type unprobed" note.
enum FsKind
{
    other,
    tmpfs,
    zfs,
    unknown,
}

/// One file's page-cache residency. Page counts, not a fraction: the
/// caller aggregates multi-file sets page-weighted, and an empty file
/// (0/0, `ok`) drops out of the aggregate naturally (`mmap` of length 0
/// is EINVAL and is never attempted).
struct Residency
{
    ulong pagesTotal;
    ulong pagesResident;
    bool ok;
}

/// What one `workloadFiles` call established, attached to every window
/// measured after it. `residentBefore`/`residentAfter` are page-weighted
/// fractions across the call's files (`nan` = unverifiable, which is a
/// note, never a downgrade by itself).
struct CacheRegimeStamp
{
    CacheRegime requested;
    CacheRegime effective;
    double residentBefore = double.nan;
    double residentAfter = double.nan;
    string note; /// fs/downgrade/partial/unverified disclosures, `"; "`-joined
}

/// Residency thresholds for the effective-regime decision (the raw
/// fractions always travel in the stamp — these only decide the
/// headline). A cold file more than 10 % resident, or a warm file less
/// than 90 %, did not reach its regime.
enum double coldResidentMax = 0.10;
/// ditto
enum double warmResidentMin = 0.90;

version (Posix)
{
    import core.stdc.stdlib : free, malloc;
    import core.sys.posix.fcntl : O_RDONLY, open;
    import core.sys.posix.sys.mman : mmap, munmap, MAP_FAILED, MAP_SHARED, PROT_READ;
    import core.sys.posix.sys.stat : fstat, stat_t;
    import core.sys.posix.unistd : close, read, sysconf, _SC_PAGESIZE;

    version (OSX)
        private alias MincoreVec = char; // darwin's mincore takes char*
    else
        private alias MincoreVec = ubyte;

    version (linux)
    {
        import core.sys.linux.sys.mman : mincore;
        import core.sys.posix.unistd : fdatasync;

        // druntime's POSIX_FADV_* live in a comment block — the real
        // declaration is local. glibc values (s390x remaps DONTNEED to 6;
        // irrelevant on x86_64/aarch64 and commented rather than handled).
        private extern (C) int posix_fadvise(int fd, long offset, long len,
            int advice) @nogc nothrow;
        private enum int posixFadvDontneed = 4;

        // No Linux statfs in druntime; only f_type (the first word) is
        // read — the buffer is oversized past every ABI variant.
        private extern (C) int statfs(const(char)* path, void* buf) @nogc nothrow;
        private struct StatfsBuf
        {
            long f_type;
            ubyte[144] rest;
        }

        private enum long tmpfsMagic = 0x0102_1994;
        private enum long ramfsMagic = 0x8584_58f6;
        private enum long zfsMagic = 0x2fc1_2fc1;
    }
    else version (OSX)
    {
        import core.sys.darwin.sys.mman : mincore;
    }

    /// The filesystem kind holding `path` (Linux `statfs` magic; `unknown`
    /// elsewhere — macOS has no tmpfs/zfs distinction worth probing, and
    /// the policy treats `unknown` as threshold-applicable).
    FsKind fsKind(scope const(char)[] path) @trusted nothrow
    {
        version (linux)
        {
            import std.string : toStringz;

            StatfsBuf buf;
            if (statfs(path.toStringz, &buf) != 0)
                return FsKind.unknown;
            switch (buf.f_type)
            {
                case tmpfsMagic, ramfsMagic: return FsKind.tmpfs;
                case zfsMagic: return FsKind.zfs;
                default: return FsKind.other;
            }
        }
        else
            return FsKind.unknown;
    }

    /// Measures `path`'s page-cache residency via `mmap` + `mincore`.
    Residency probeResidency(scope const(char)[] path) @trusted nothrow
    {
        import std.string : toStringz;

        const fd = open(path.toStringz, O_RDONLY);
        if (fd < 0)
            return Residency();
        scope (exit)
            close(fd);
        stat_t st;
        if (fstat(fd, &st) != 0)
            return Residency();
        const size = cast(ulong) st.st_size;
        if (size == 0)
            return Residency(0, 0, true); // mmap(0) is EINVAL; nothing to verify
        const page = cast(ulong) sysconf(_SC_PAGESIZE);
        if (page == 0)
            return Residency();
        const pages = (size + page - 1) / page;

        auto addr = mmap(null, cast(size_t) size, PROT_READ, MAP_SHARED, fd, 0);
        if (addr is MAP_FAILED)
            return Residency();
        scope (exit)
            munmap(addr, cast(size_t) size);

        auto vec = cast(MincoreVec*) malloc(cast(size_t) pages);
        if (vec is null)
            return Residency();
        scope (exit)
            free(vec);
        if (mincore(addr, cast(size_t) size, vec) != 0)
            return Residency();

        ulong resident;
        foreach (i; 0 .. pages)
            if (vec[i] & 1)
                resident++;
        return Residency(pages, resident, true);
    }

    /// Evicts `path` from the page cache; `null` = ok, else the reason.
    /// `fdatasync` first: DONTNEED silently skips dirty pages, so a freshly
    /// written file would otherwise stay resident.
    string applyCold(scope const(char)[] path) @trusted nothrow
    {
        version (linux)
        {
            import std.string : toStringz;

            const fd = open(path.toStringz, O_RDONLY);
            if (fd < 0)
                return "open failed";
            scope (exit)
                close(fd);
            cast(void) fdatasync(fd); // flush dirty pages so they are evictable
            if (posix_fadvise(fd, 0, 0, posixFadvDontneed) != 0)
                return "posix_fadvise failed";
            return null;
        }
        else
            return "no posix_fadvise — not Linux";
    }

    /// Preloads `path` into the page cache with an explicit read-through
    /// loop (never async `WILLNEED` advice); `null` = ok, else the reason.
    string applyWarm(scope const(char)[] path) @trusted nothrow
    {
        import std.string : toStringz;

        const fd = open(path.toStringz, O_RDONLY);
        if (fd < 0)
            return "open failed";
        scope (exit)
            close(fd);
        ubyte[64 * 1024] buf = void;
        for (;;)
        {
            const n = read(fd, buf.ptr, buf.length);
            if (n < 0)
                return "read failed";
            if (n == 0)
                return null;
        }
    }
}
else
{
    /// Non-POSIX stub: no regime control at all.
    FsKind fsKind(scope const(char)[]) @safe pure nothrow @nogc => FsKind.unknown;
    /// ditto
    Residency probeResidency(scope const(char)[]) @safe pure nothrow @nogc
        => Residency();
    /// ditto
    string applyCold(scope const(char)[]) @safe pure nothrow @nogc
        => "cache regime control unavailable (not POSIX)";
    /// ditto
    string applyWarm(scope const(char)[]) @safe pure nothrow @nogc
        => "cache regime control unavailable (not POSIX)";
}

/// The pure regime policy: requested + filesystem kind + measured
/// residency (page-weighted fractions; `nan` = unverifiable) + any prep
/// failure → the honest stamp. Downgrades only on evidence: a prep
/// failure or a threshold miss on a filesystem where `mincore` IS
/// evidence; `nan` residency keeps the requested regime with an
/// "unverified" note; ZFS suppresses the thresholds in both directions
/// (`mincore` sees neither ARC warmth nor ARC survival).
CacheRegimeStamp resolveStamp(CacheRegime requested, FsKind kind,
    double residentBefore, double residentAfter, string prepNote) @safe pure nothrow
{
    CacheRegimeStamp s;
    s.requested = requested;
    s.effective = requested;
    s.residentBefore = residentBefore;
    s.residentAfter = residentAfter;

    if (requested == CacheRegime.steadyState)
        return s; // nothing was attempted; the probe fractions are disclosure

    if (prepNote.length)
    {
        // Prep itself failed (no fadvise on this OS, open failure, …):
        // the regime was not established.
        s.effective = CacheRegime.steadyState;
        s.note = prepNote.length ? (requested == CacheRegime.cold
            ? "cold unavailable (" ~ prepNote ~ ") — ran steady-state"
            : "warm unavailable (" ~ prepNote ~ ") — ran steady-state") : null;
        return s;
    }

    final switch (kind)
    {
    case FsKind.tmpfs:
        if (requested == CacheRegime.cold)
        {
            s.effective = CacheRegime.steadyState;
            s.note = "cold impossible on tmpfs (the pages ARE the file) — ran steady-state";
        }
        // warm on tmpfs is trivially true — no note needed.
        return s;

    case FsKind.zfs:
        // mincore is blind on ZFS in both directions: reads are served
        // from the ARC without populating the Linux page cache. The
        // thresholds are suppressed; the fractions remain as disclosure.
        s.note = requested == CacheRegime.cold
            ? "zfs: ARC survives posix_fadvise — cold partial at best; page-cache "
                ~ "residency shown, ARC unverifiable"
            : "zfs: preload warms the ARC; page-cache residency does not reflect it";
        return s;

    case FsKind.other:
    case FsKind.unknown:
        if (residentAfter.isNaN)
        {
            appendNote(s.note, "residency unverified (mincore unavailable)");
            break;
        }
        if (requested == CacheRegime.cold && residentAfter > coldResidentMax)
        {
            s.effective = CacheRegime.steadyState;
            appendNote(s.note, "posix_fadvise did not evict ("
                ~ percentString(residentAfter)
                ~ " resident — another process's mapping?) — ran steady-state");
        }
        else if (requested == CacheRegime.warm && residentAfter < warmResidentMin)
        {
            s.effective = CacheRegime.steadyState;
            appendNote(s.note, "preload did not stick ("
                ~ percentString(residentAfter)
                ~ " resident) — memory pressure or file > RAM?");
        }
        break;
    }
    if (kind == FsKind.unknown)
        appendNote(s.note, "fs type unprobed");
    return s;
}

private void appendNote(ref string note, string add) @safe pure nothrow
{
    note = note.length ? note ~ "; " ~ add : add;
}

/// A fraction as integral percent, for `nothrow` note text.
private string percentString(double fraction) @safe pure nothrow
{
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.base.text.writers : writeInteger;

    SmallBuffer!(char, 8) buf;
    writeInteger(buf, cast(long)(fraction * 100));
    return buf[].idup ~ "%";
}

@("cacheRegime.resolveStamp.matrix")
@safe pure nothrow
unittest
{
    import std.algorithm.searching : canFind;

    with (CacheRegime) with (FsKind)
    {
        // steadyState: nothing attempted; fractions are disclosure only.
        const steady = resolveStamp(steadyState, other, 0.42, 0.42, null);
        assert(steady.effective == steadyState && steady.note.length == 0);
        assert(steady.residentBefore == 0.42);

        // tmpfs: cold impossible; warm trivially true.
        const tc = resolveStamp(cold, tmpfs, 1.0, 1.0, null);
        assert(tc.effective == steadyState && tc.note.canFind("tmpfs"));
        const tw = resolveStamp(warm, tmpfs, 1.0, 1.0, null);
        assert(tw.effective == warm && tw.note.length == 0);

        // zfs: thresholds suppressed in BOTH directions, notes say why.
        const zc = resolveStamp(cold, zfs, 0.0, 0.9, null);
        assert(zc.effective == cold, "no threshold downgrade on zfs");
        assert(zc.note.canFind("ARC"));
        const zw = resolveStamp(warm, zfs, 0.0, 0.0, null);
        assert(zw.effective == warm, "0% page-cache residency is not evidence on zfs");
        assert(zw.note.canFind("ARC") || zw.note.canFind("residency"));

        // other fs: thresholds bite, boundaries exact.
        assert(resolveStamp(cold, other, 1.0, 0.10, null).effective == cold,
            "exactly at the threshold passes");
        const cd = resolveStamp(cold, other, 1.0, 0.35, null);
        assert(cd.effective == steadyState && cd.note.canFind("did not evict"));
        assert(cd.note.canFind("35%"));
        assert(resolveStamp(warm, other, 0.0, 0.90, null).effective == warm);
        const wd = resolveStamp(warm, other, 0.0, 0.55, null);
        assert(wd.effective == steadyState && wd.note.canFind("did not stick"));

        // Prep failure: downgraded with the per-file reason.
        const pf = resolveStamp(cold, other, 1.0, double.nan, "no posix_fadvise — not Linux");
        assert(pf.effective == steadyState);
        assert(pf.note.canFind("cold unavailable"));
        assert(pf.note.canFind("not Linux"));

        // nan residency with successful prep: unverified, NOT downgraded.
        const uv = resolveStamp(cold, other, double.nan, double.nan, null);
        assert(uv.effective == cold, "nan is honest-unverified, not a downgrade");
        assert(uv.note.canFind("unverified"));

        // unknown fs: thresholds apply, plus the unprobed note.
        const uk = resolveStamp(cold, unknown, 1.0, 0.02, null);
        assert(uk.effective == cold && uk.note.canFind("unprobed"));
    }
}

@("cacheRegime.probeResidency.emptyAndMissing")
@system
unittest
{
    version (Posix)
    {
        import std.file : deleteme, remove, write;

        // A missing file is !ok, never a fabricated measurement.
        assert(!probeResidency("/nonexistent/definitely/missing").ok);

        // An empty file: ok with 0/0 pages — drops out of aggregation.
        const path = deleteme ~ ".cache-regime-empty";
        write(path, "");
        scope (exit)
            remove(path);
        const r = probeResidency(path);
        assert(r.ok && r.pagesTotal == 0 && r.pagesResident == 0);
    }
    else
        assert(!probeResidency("x").ok);
}

version (linux)
{
    @("cacheRegime.fsKind.devShmIsTmpfs")
    @system
    unittest
    {
        import std.file : exists;
        import sparkles.test_runner.skip : skipTest;

        if (!"/dev/shm".exists)
            skipTest("/dev/shm absent");
        assert(fsKind("/dev/shm") == FsKind.tmpfs);
    }

    @("cacheRegime.warmAndCold.byFsKind")
    @system
    unittest
    {
        import std.file : deleteme, remove, tempDir, write;
        import sparkles.test_runner.skip : skipTest;

        // 8 MiB fixture in tempDir, synced so cold has evictable pages.
        const path = deleteme ~ ".cache-regime-probe";
        auto data = new ubyte[](8 << 20);
        data[] = 0x5a;
        write(path, data);
        scope (exit)
            remove(path);

        const kind = fsKind(tempDir);
        assert(applyWarm(path) is null, "read-through preload succeeds");
        const warm = probeResidency(path);
        assert(warm.ok);
        const warmFrac = double(warm.pagesResident) / double(warm.pagesTotal);

        assert(applyCold(path) is null, "fadvise path succeeds on Linux");
        const cold = probeResidency(path);
        assert(cold.ok);
        const coldFrac = double(cold.pagesResident) / double(cold.pagesTotal);

        final switch (kind)
        {
        case FsKind.tmpfs:
            assert(warmFrac >= 0.99, "tmpfs pages are the file");
            assert(coldFrac >= 0.99, "cold cannot evict tmpfs — the policy notes it");
            break;
        case FsKind.zfs:
            // mincore is blind on zfs — nothing about the fractions is
            // assertable; the policy suppresses thresholds there.
            break;
        case FsKind.other:
        case FsKind.unknown:
            assert(warmFrac >= warmResidentMin,
                "preload sticks on a real fs with free memory");
            assert(coldFrac <= coldResidentMax, "fadvise evicts a synced file");
            break;
        }
    }
}
