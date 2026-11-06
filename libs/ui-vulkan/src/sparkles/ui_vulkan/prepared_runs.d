/**
Bounded, color-independent shaped runs shared by measurement and drawing.
Keys own their scalars and normalized coordinates; cached runs borrow no font
bytes or renderer pointers. A selected face's serial must identify its exact
content and collection index. Changing size or coordinates gives another key.
*/
module sparkles.ui_vulkan.prepared_runs;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.font.cluster_shaping : ClusterDirection, ClusterGlyph, maxClusterGlyphs;
import sparkles.font.instance : maxVariationAxes;
import sparkles.font.units : Ppem;
import sparkles.profiling.zones : cpuZone;

/// A bounded four-way cache; returned glyphs live until the next prepare/clear.
struct PreparedRuns(size_t Capacity = 256)
{
    static assert(Capacity >= 4 && (Capacity & (Capacity - 1)) == 0);
    private struct Entry
    {
        ulong hash, used;
        uint face;
        ClusterDirection direction;
        Ppem size;
        ushort characters, axes, count;
        uint[maxClusterGlyphs] text;
        short[maxVariationAxes] coordinates;
        ClusterGlyph[maxClusterGlyphs] glyphs;
    }
    private UniqueBuffer!Entry entries;
    private ulong clock;
    private ulong hits_, misses_;

    /**
    Prepare through `shape(output)` only on a miss. The callback writes at most
    `maxClusterGlyphs` and returns its count, zero for failure. Failures are
    retained too, without turning them into successful shapes.
    */
    const(ClusterGlyph)[] prepare(Shape)(uint face, Ppem size,
        scope const(short)[] coordinates, scope const(uint)[] text, scope Shape shape,
        ClusterDirection direction = ClusterDirection.automatic)
    {
        if (!text.length || text.length > maxClusterGlyphs || coordinates.length > maxVariationAxes)
            return null;
        if (!entries.length) entries.length = Capacity;
        if (++clock == 0)
        {
            foreach (ref entry; entries[]) entry.used = 0;
            clock = 1;
        }
        ulong hash = 0xcbf2_9ce4_8422_2325;
        void mix(ulong value) { hash = (hash ^ value) * 0x100_0000_01b3; }
        mix(face); mix(size.numerator); mix(size.denominator);
        mix(direction);
        mix(coordinates.length);
        foreach (c; coordinates) mix(cast(ushort) c);
        mix(text.length);
        foreach (c; text) mix(c);
        const first = cast(size_t)(hash & (Capacity / 4 - 1)) * 4;
        size_t pick = first;
        foreach (i; first .. first + 4)
        {
            auto e = &entries[][i];
            if (e.used && e.hash == hash && e.face == face && e.size == size && e.direction == direction
                && e.axes == coordinates.length && e.characters == text.length
                && e.coordinates[0 .. e.axes] == coordinates && e.text[0 .. e.characters] == text)
            {
                e.used = clock;
                ++hits_;
                return e.glyphs[0 .. e.count];
            }
            if (e.used < entries[][pick].used) pick = i;
        }
        auto e = &entries[][pick];
        e.hash = hash; e.used = clock; e.face = face; e.size = size;
        e.direction = direction;
        e.axes = cast(ushort) coordinates.length;
        e.characters = cast(ushort) text.length;
        e.coordinates[0 .. e.axes] = coordinates;
        e.text[0 .. e.characters] = text;
        auto zone = cpuZone!"shape"; // a miss (`PRF22`)
        const n = shape(e.glyphs[]);
        e.count = n <= maxClusterGlyphs ? cast(ushort) n : 0;
        ++misses_;
        return e.glyphs[0 .. e.count];
    }

    /// Releases retained runs, for memory pressure or a replaced font set.
    void clear() @safe nothrow @nogc
    {
        entries.clear();
        clock = 0;
    }

    /// Cumulative work counters, independent of frame rate and atlas hits.
    ulong hits() const @safe pure nothrow @nogc => hits_;
    /// ditto
    ulong misses() const @safe pure nothrow @nogc => misses_;
}

/// The same run serves measurement, both panels and later unchanged frames.
@("ui_vulkan.prepared_runs.directionIdentity")
@system unittest
{
    PreparedRuns!16 cache;
    uint[1] text = ['('];
    uint calls;
    auto shape = (scope ClusterGlyph[] output) {
        output[0] = ClusterGlyph(++calls);
        return size_t(1);
    };
    const size = Ppem.fromInteger(24).value;
    const ltr = cache.prepare(1, size, null, text[], shape, ClusterDirection.ltr)[0].glyph;
    const rtl = cache.prepare(1, size, null, text[], shape, ClusterDirection.rtl)[0].glyph;
    assert(ltr != rtl && calls == 2);
    assert(cache.prepare(1, size, null, text[], shape, ClusterDirection.ltr)[0].glyph == ltr);
    assert(calls == 2);
}

/// The same run serves measurement, both panels and later unchanged frames.
@("ui_vulkan.prepared_runs.exactIdentityAndReuse")
@system unittest
{
    PreparedRuns!16 cache;
    const size = Ppem.fromInteger(24).value;
    uint[2] text = ['q', 0x301];
    short[2] coords;
    size_t calls;
    auto shape = (scope ClusterGlyph[] output) {
        ++calls;
        output[0] = ClusterGlyph(42, 12.5, -0.25, 1.0);
        return size_t(1);
    };
    foreach (_; 0 .. 4)
    {
        const run = cache.prepare(1, size, coords[], text[], shape);
        assert(run.length == 1 && run[0] == ClusterGlyph(42, 12.5, -0.25, 1.0));
    }
    assert(calls == 1 && cache.hits == 3);
    coords[0] = 1;
    cast(void) cache.prepare(1, size, coords[], text[], shape);
    cast(void) cache.prepare(2, size, coords[], text[], shape);
    cast(void) cache.prepare(2, Ppem.fromInteger(25).value, coords[], text[], shape);
    text[0] = 'a';
    cast(void) cache.prepare(2, size, coords[], text[], shape);
    assert(calls == 5);
    cache.clear();
    cast(void) cache.prepare(2, size, coords[], text[], shape);
    assert(calls == 6);
}

/// Bounded eviction and negative results never publish a partial shape.
@("ui_vulkan.prepared_runs.evictionAndFailure")
@system unittest
{
    PreparedRuns!4 cache;
    const size = Ppem.fromInteger(16).value;
    uint[1] text = ['a'];
    size_t calls;
    auto refused = (scope ClusterGlyph[] output) { ++calls; return size_t(0); };
    assert(cache.prepare(1, size, null, text[], refused).length == 0);
    assert(cache.prepare(1, size, null, text[], refused).length == 0 && calls == 1);
    foreach (face; 2 .. 8) cast(void) cache.prepare(face, size, null, text[], refused);
    cast(void) cache.prepare(1, size, null, text[], refused);
    assert(calls == 8);
}
