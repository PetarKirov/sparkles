/**
NT file times as the capability VFS reports them: a `FILETIME` or
`LARGE_INTEGER` time counts 100 ns ticks since 1601, a `Stat` nanoseconds
since 1970.

Platform-neutral, so the conversion is tested on every host, although only
the Windows backend calls it.
*/
module sparkles.event_horizon.sys.nt_time;

/// The ticks between 1601-01-01 and 1970-01-01.
enum long ntUnixEpochTicks = 116_444_736_000_000_000L;

/**
Converts the NT time `ticks` to nanoseconds since the Unix epoch in `ns`.
Returns `false`, leaving `ns` zero, for a time the file system did not
record (zero, as FAT gives for a change time it does not keep) and for one
too far from 1970 for a `long` of nanoseconds (before 1678 or after 2262),
so a caller reports the time as absent rather than as a wrapped value.
*/
bool ntTimeToUnixNs(long ticks, out long ns) @safe pure nothrow @nogc
{
    if (ticks <= 0)
        return false;
    const fromUnix = ticks - ntUnixEpochTicks; // cannot overflow: ticks > 0
    if (fromUnix > long.max / 100 || fromUnix < long.min / 100)
        return false;
    ns = fromUnix * 100;
    return true;
}

///
@("nt_time.ntTimeToUnixNs")
@safe pure nothrow @nogc unittest
{
    long ns;
    assert(ntTimeToUnixNs(ntUnixEpochTicks, ns) && ns == 0);
    assert(ntTimeToUnixNs(ntUnixEpochTicks + 15, ns) && ns == 1500);
    // 2001-09-09T01:46:40Z, a billion seconds after the epoch.
    assert(ntTimeToUnixNs(ntUnixEpochTicks + 10_000_000_000_000_000L, ns)
        && ns == 1_000_000_000_000_000_000L);
    assert(ntTimeToUnixNs(ntUnixEpochTicks - 10_000_000, ns) && ns == -1_000_000_000);

    // A zero time is no time, not a wrapped one.
    assert(!ntTimeToUnixNs(0, ns) && ns == 0);
    assert(!ntTimeToUnixNs(-1, ns));
    // Beyond 2262 a long of nanoseconds no longer holds it.
    assert(!ntTimeToUnixNs(long.max, ns) && ns == 0);
    assert(ntTimeToUnixNs(ntUnixEpochTicks + long.max / 100, ns) && ns > 0);
    assert(!ntTimeToUnixNs(ntUnixEpochTicks + long.max / 100 + 1, ns));
}
