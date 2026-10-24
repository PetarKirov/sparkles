/** Focused SDL writer regression benchmark; assertions remain enabled. */
module sparkles.wired.sdl.bench;

import sparkles.test_runner.attributes : benchmark;

version (unittest):

/// Exponent expansion, UTF-8, integer, and temporal formatting share this workload.
@("wired.sdl.writeScalars") @benchmark @system unittest
{
    import std.datetime : Date;
    import expected : ok;
    import sparkles.base.buffer : UniqueBuffer;
    import sparkles.test_runner.bench : benchCase;
    import sparkles.wired.sdl.document : SdlScalar, SdlDateTime;
    import sparkles.wired.sdl.writer : writeSdlScalar;

    auto output = new UniqueBuffer!(char, 4096);
    const values = [SdlScalar(1.23456789e-80), SdlScalar(1.23456789e80),
        SdlScalar(1.25f), SdlScalar.decimal(1.234567890123456789L), SdlScalar(long.min),
        SdlScalar("text λ 日本語"), SdlScalar(SdlDateTime(Date(2026, 10, 22), 12, 34, 56, 1230000))];
    benchCase(name: "mixed-scalars", timed: () {
        output.clear();
        foreach (_; 0 .. 16)
            foreach (value; values)
                assert(!writeSdlScalar(value, *output).hasError);
    }, after: () {
        assert(output.length > 1000);
        return ok!string(true);
    });
}
