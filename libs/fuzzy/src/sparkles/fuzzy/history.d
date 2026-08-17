/** Deterministic fixed-capacity frecency and query/candidate history models. */
module sparkles.fuzzy.history;

import sparkles.fuzzy.common : CandidateId, FuzzyErrorCode, FuzzyExpected,
    ProjectId, QueryId, fuzzyErr, fuzzyOk;

/// Built-in access-decay policies.
enum AccessDecayProfile : ubyte
{
    tenDay,
    threeDay,
}

private enum long secondsPerHour = 3_600;
private enum size_t tenDayRetentionHours = 30 * 24;
private enum size_t threeDayRetentionHours = 7 * 24;

private uint[N + 1] makeDecayTable(uint Factor, size_t N)()
    @safe pure nothrow @nogc
{
    uint[N + 1] result;
    result[0] = 65_536;
    foreach (i; 1 .. N + 1)
        result[i] = cast(uint)((cast(ulong) result[i - 1] * Factor
            + 32_768) / 65_536);
    return result;
}

// Q16 per-hour decay factors nearest to 2^(-1/240) and 2^(-1/72).
private immutable tenDayDecay = makeDecayTable!(65_347,
    tenDayRetentionHours)();
private immutable threeDayDecay = makeDecayTable!(64_908,
    threeDayRetentionHours)();

/**
Score a newest-first timestamp sequence at explicit Unix time.

Future ages clamp to zero, expired stamps contribute nothing, and fractional
hours linearly interpolate adjacent committed Q16 entries.
*/
FuzzyExpected!uint accessScore(scope const(long)[] stamps, long nowSeconds,
    AccessDecayProfile profile = AccessDecayProfile.tenDay)
    @safe pure nothrow @nogc
{
    if (!validProfile(profile))
        return fuzzyErr!uint(FuzzyErrorCode.invalidConfiguration);
    ulong weightedQ16;
    foreach (stamp; stamps)
    {
        const age = elapsedSeconds(stamp, nowSeconds);
        const weight = decayWeight(age, profile);
        weightedQ16 = ulong.max - weightedQ16 < weight
            ? ulong.max : weightedQ16 + weight;
    }
    const knee = 10UL * 65_536;
    if (weightedQ16 <= knee)
        return fuzzyOk(cast(uint)((weightedQ16 + 32_768) / 65_536));
    const root = integerSquareRoot((weightedQ16 - knee) / 65_536);
    return fuzzyOk(root > uint.max - 10 ? uint.max : 10 + root);
}

/** Modification recency with exact integer interpolation between knots. */
uint modificationScore(long modifiedSeconds, long nowSeconds)
    @safe pure nothrow @nogc
{
    const age = elapsedSeconds(modifiedSeconds, nowSeconds);
    static immutable ulong[] times = [0, 2 * 60, 15 * 60, 60 * 60,
        24 * 60 * 60, 7 * 24 * 60 * 60];
    static immutable uint[] points = [16, 16, 8, 4, 2, 1];
    if (age > times[$ - 1])
        return 0;
    foreach (i; 1 .. times.length)
    {
        if (age <= times[i])
        {
            const width = times[i] - times[i - 1];
            const elapsed = age - times[i - 1];
            const delta = cast(ulong) points[i - 1] - points[i];
            return cast(uint)(points[i - 1] - delta * elapsed / width);
        }
    }
    return points[$ - 1];
}

private struct FrecencyEntry(size_t MaxStamps)
{
    CandidateId id;
    long[MaxStamps] stamps = void;
    ushort count;
    long lastTouched;
    bool occupied;
}

/** Fixed-capacity file access history with deterministic LRU eviction. */
struct FrecencyTable(size_t MaxFiles = 4_096, size_t MaxStamps = 128)
if (MaxFiles > 0 && MaxStamps > 0 && MaxStamps <= ushort.max)
{
    // `occupied`/`count` are read before any write, so the table must be
    // properly default-initialized; only the inner `stamps` payload (guarded
    // by `count`) may remain uninitialized.
    private FrecencyEntry!MaxStamps[MaxFiles] entries;

    /// Insert an access timestamp, retaining the newest `MaxStamps` values.
    FuzzyExpected!void record(CandidateId id, long stamp,
        AccessDecayProfile profile = AccessDecayProfile.tenDay)
        @safe pure nothrow @nogc
    {
        if (!validProfile(profile))
            return fuzzyErr!void(FuzzyErrorCode.invalidConfiguration);
        pruneEntries(stamp, profile);
        size_t at = find(id);
        if (at == MaxFiles)
            at = acquire(id);
        ref entry = entries[at];
        insertNewest(entry, stamp);
        if (stamp > entry.lastTouched || entry.count == 1)
            entry.lastTouched = stamp;
        return fuzzyOk();
    }

    FuzzyExpected!uint score(CandidateId id, long nowSeconds,
        AccessDecayProfile profile = AccessDecayProfile.tenDay) const
        @safe pure nothrow @nogc
    {
        if (!validProfile(profile))
            return fuzzyErr!uint(FuzzyErrorCode.invalidConfiguration);
        const at = find(id);
        return at == MaxFiles ? fuzzyOk(uint(0))
            : accessScore(entries[at].stamps[0 .. entries[at].count],
                nowSeconds, profile);
    }

    /// Remove expired stamps and release empty entries.
    FuzzyExpected!void prune(long nowSeconds,
        AccessDecayProfile profile = AccessDecayProfile.tenDay)
        @safe pure nothrow @nogc
    {
        if (!validProfile(profile))
            return fuzzyErr!void(FuzzyErrorCode.invalidConfiguration);
        pruneEntries(nowSeconds, profile);
        return fuzzyOk();
    }

private:
    void pruneEntries(long nowSeconds, AccessDecayProfile profile)
        @safe pure nothrow @nogc
    {
        const retention = retentionSeconds(profile);
        foreach (ref entry; entries)
        {
            if (!entry.occupied)
                continue;
            size_t write;
            foreach (read; 0 .. entry.count)
            {
                const age = elapsedSeconds(entry.stamps[read], nowSeconds);
                if (age <= retention)
                    entry.stamps[write++] = entry.stamps[read];
            }
            entry.count = cast(ushort) write;
            if (write == 0)
                entry.occupied = false;
        }
    }

public:
    size_t length() const @safe pure nothrow @nogc
    {
        size_t result;
        foreach (entry; entries)
            result += entry.occupied;
        return result;
    }

private:
    size_t find(CandidateId id) const @safe pure nothrow @nogc
    {
        foreach (i, entry; entries)
            if (entry.occupied && entry.id == id)
                return i;
        return MaxFiles;
    }

    size_t acquire(CandidateId id) @safe pure nothrow @nogc
    {
        foreach (i, entry; entries)
        {
            if (!entry.occupied)
            {
                entries[i] = FrecencyEntry!MaxStamps.init;
                entries[i].occupied = true;
                entries[i].id = id;
                return i;
            }
        }
        size_t victim;
        foreach (i; 1 .. MaxFiles)
        {
            if (entries[i].lastTouched < entries[victim].lastTouched
                || (entries[i].lastTouched == entries[victim].lastTouched
                    && entries[i].id.opCmp(entries[victim].id) < 0))
                victim = i;
        }
        entries[victim] = FrecencyEntry!MaxStamps.init;
        entries[victim].occupied = true;
        entries[victim].id = id;
        return victim;
    }

    void insertNewest(ref FrecencyEntry!MaxStamps entry, long stamp)
        @safe pure nothrow @nogc
    {
        size_t at;
        while (at < entry.count && entry.stamps[at] >= stamp)
            ++at;
        if (at == MaxStamps)
            return;
        size_t newCount = entry.count < MaxStamps
            ? entry.count + 1 : entry.count;
        size_t move = newCount;
        while (move > at + 1)
        {
            entry.stamps[move - 1] = entry.stamps[move - 2];
            --move;
        }
        entry.stamps[at] = stamp;
        entry.count = cast(ushort) newCount;
    }
}

private struct ComboEntry
{
    ProjectId project;
    QueryId query;
    CandidateId candidate;
    uint openCount;
    long lastOpened;
    bool occupied;
}

/** One remembered candidate for each stable `(project, query)` pair. */
struct ComboTable(size_t MaxEntries = 1_024)
if (MaxEntries > 0)
{
    // `occupied` is read before any write; default initialization is required.
    private ComboEntry[MaxEntries] entries;

    void record(ProjectId project, QueryId query, CandidateId candidate,
        long openedAt) @safe pure nothrow @nogc
    {
        auto at = find(project, query);
        if (at == MaxEntries)
            at = acquire(project, query);
        ref entry = entries[at];
        if (entry.candidate == candidate)
        {
            if (entry.openCount != uint.max)
                ++entry.openCount;
        }
        else
        {
            entry.candidate = candidate;
            entry.openCount = 1;
        }
        entry.lastOpened = openedAt;
    }

    FuzzyExpected!uint boost(ProjectId project, QueryId query,
        CandidateId candidate, uint minComboCount = 3,
        uint comboMultiplier = 10) const @safe pure nothrow @nogc
    {
        if (minComboCount == 0 || comboMultiplier > 100_000)
            return fuzzyErr!uint(FuzzyErrorCode.invalidConfiguration);
        const at = find(project, query);
        if (at == MaxEntries || entries[at].candidate != candidate)
            return fuzzyOk(uint(0));
        const count = entries[at].openCount;
        const multiplier = count < minComboCount ? 5 : comboMultiplier;
        if (multiplier != 0 && count > uint.max / multiplier)
            return fuzzyErr!uint(FuzzyErrorCode.arithmeticOverflow);
        uint result = count * multiplier;
        return fuzzyOk(result);
    }

    size_t length() const @safe pure nothrow @nogc
    {
        size_t result;
        foreach (entry; entries)
            result += entry.occupied;
        return result;
    }

private:
    size_t find(ProjectId project, QueryId query) const
        @safe pure nothrow @nogc
    {
        foreach (i, entry; entries)
            if (entry.occupied && entry.project == project
                && entry.query == query)
                return i;
        return MaxEntries;
    }

    size_t acquire(ProjectId project, QueryId query)
        @safe pure nothrow @nogc
    {
        foreach (i, entry; entries)
        {
            if (!entry.occupied)
            {
                entries[i] = ComboEntry.init;
                entries[i].occupied = true;
                entries[i].project = project;
                entries[i].query = query;
                return i;
            }
        }
        size_t victim;
        foreach (i; 1 .. MaxEntries)
        {
            if (entries[i].lastOpened < entries[victim].lastOpened
                || (entries[i].lastOpened == entries[victim].lastOpened
                    && comboKeyBefore(entries[i], entries[victim])))
                victim = i;
        }
        entries[victim] = ComboEntry.init;
        entries[victim].occupied = true;
        entries[victim].project = project;
        entries[victim].query = query;
        return victim;
    }
}

private bool comboKeyBefore(in ComboEntry left, in ComboEntry right)
    @safe pure nothrow @nogc
{
    const projectOrder = left.project.opCmp(right.project);
    if (projectOrder != 0)
        return projectOrder < 0;
    return left.query.opCmp(right.query) < 0;
}

private ulong elapsedSeconds(long past, long now)
    @safe pure nothrow @nogc
{
    return past > now ? 0
        : cast(ulong) now - cast(ulong) past;
}

private uint decayWeight(ulong ageSeconds, AccessDecayProfile profile)
    @safe pure nothrow @nogc
{
    const hours = ageSeconds / secondsPerHour;
    const remainder = cast(uint)(ageSeconds % secondsPerHour);
    switch (profile)
    {
    case AccessDecayProfile.tenDay:
        if (hours >= tenDayRetentionHours)
            return hours == tenDayRetentionHours && remainder == 0
                ? tenDayDecay[$ - 1] : 0;
        return interpolate(tenDayDecay[hours], tenDayDecay[hours + 1],
            remainder);
    case AccessDecayProfile.threeDay:
        if (hours >= threeDayRetentionHours)
            return hours == threeDayRetentionHours && remainder == 0
                ? threeDayDecay[$ - 1] : 0;
        return interpolate(threeDayDecay[hours], threeDayDecay[hours + 1],
            remainder);
    default:
        return 0;
    }
}

private uint interpolate(uint first, uint second, uint remainder)
    @safe pure nothrow @nogc
{
    const delta = cast(long) first - second;
    return cast(uint)(first - delta * remainder / secondsPerHour);
}

private ulong retentionSeconds(AccessDecayProfile profile)
    @safe pure nothrow @nogc
{
    switch (profile)
    {
    case AccessDecayProfile.tenDay:
        return tenDayRetentionHours * secondsPerHour;
    case AccessDecayProfile.threeDay:
        return threeDayRetentionHours * secondsPerHour;
    default:
        return 0;
    }
}

private bool validProfile(AccessDecayProfile profile)
    @safe pure nothrow @nogc
    => profile == AccessDecayProfile.tenDay
        || profile == AccessDecayProfile.threeDay;

private uint integerSquareRoot(ulong value) @safe pure nothrow @nogc
{
    ulong result;
    ulong bit = 1UL << 62;
    while (bit > value)
        bit >>= 2;
    while (bit != 0)
    {
        if (value >= result + bit)
        {
            value -= result + bit;
            result = (result >> 1) + bit;
        }
        else
            result >>= 1;
        bit >>= 2;
    }
    return result > uint.max ? uint.max : cast(uint) result;
}

@("fuzzy.history.decayAndModificationKnots")
@safe pure nothrow @nogc
unittest
{
    long[12] stamps;
    assert(accessScore(stamps[0 .. 1], 0).value == 1);
    assert(accessScore(stamps[], 0).value == 11);
    assert(accessScore(stamps[0 .. 2], 10 * 24 * 60 * 60).value == 1,
        "two accesses decay to one at the ten-day half-life");
    assert(modificationScore(0, 2 * 60) == 16);
    assert(modificationScore(0, 15 * 60) == 8);
    assert(modificationScore(100, 0) == 16);
    assert(modificationScore(0, 8 * 24 * 60 * 60) == 0);
    assert(modificationScore(long.min, long.max) == 0,
        "extreme clock spans must not overflow signed subtraction");
    long[2] extreme = [long.min, long.max];
    assert(accessScore(extreme[], long.max).value == 1);
    assert(accessScore(stamps[], 0,
        cast(AccessDecayProfile) ubyte.max).error.code
        == FuzzyErrorCode.invalidConfiguration);
}

@("fuzzy.history.outOfOrderAndEviction")
@safe pure nothrow @nogc
unittest
{
    FrecencyTable!(2, 4) table;
    CandidateId a = CandidateId(0, 1);
    CandidateId b = CandidateId(0, 2);
    CandidateId c = CandidateId(0, 3);
    assert(!table.record(a, 100).hasError);
    assert(!table.record(a, 50).hasError);
    assert(!table.record(b, 80).hasError);
    assert(table.score(a, 50).value == 2); // future stamp clamps to age zero
    assert(!table.record(c, 120).hasError);
    assert(table.length == 2);
    assert(table.score(b, 120).value == 0);
    assert(table.record(a, 0,
        cast(AccessDecayProfile) ubyte.max).error.code
        == FuzzyErrorCode.invalidConfiguration);
}

@("fuzzy.history.comboReplacementAndBoost")
@safe pure nothrow @nogc
unittest
{
    ComboTable!2 table;
    ProjectId project = ProjectId(1, 0);
    QueryId query = QueryId(2, 0);
    CandidateId first = CandidateId(3, 0);
    CandidateId second = CandidateId(4, 0);
    table.record(project, query, first, 1);
    table.record(project, query, first, 2);
    assert(table.boost(project, query, first).value == 10);
    table.record(project, query, second, 3);
    assert(table.boost(project, query, first).value == 0);
    assert(table.boost(project, query, second).value == 5);
}
