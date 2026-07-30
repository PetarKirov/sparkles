/**
The one-dimensional track sizer of $(MREF sparkles,ui) (`LAY9`) — the useful
subset of CSS Grid's column algorithm, deliberately without its auto-placement
and staged-resolution machinery (essentially only browser-grade engines
implement those; see `docs/specs/ui/layout.md` § out of scope).

A table (or any columnar layout) describes its tracks as $(LREF TrackSpec)s —
`auto` / `fixed(n)` / `fr(w)` / `minmax(a,b)` — and $(LREF resolveTracks) turns
them into extents: measure the `auto` tracks, subtract fixed tracks and gaps,
divide the remainder among `fr` tracks by weight. Distribution is integer
divmod with the remainder handed one cell each to the first `fr` tracks, so the
parts sum exactly to the whole — the same no-floats discipline as the box-flow
engine. Spanning cells widen their tracks via $(LREF applySpans). The HTML
target emits the specs as `grid-template-columns` ($(LREF writeGridTemplate)).
*/
module sparkles.ui.tracks;

@safe:

/// One track's sizing (`LAY9`). Build with the factories:
/// `TrackSpec.auto_` (size to content), `TrackSpec.fixed(n)` (exactly `n`
/// cells), `TrackSpec.fr(w)` (share of the leftover, weight `w`),
/// `TrackSpec.minmax(a, b)` (content clamped to `[a, b]`).
struct TrackSpec
{
    /// The kind of track sizing.
    enum Kind : ubyte
    {
        auto_,  /// size to the track's measured content
        fixed,  /// exactly `a` cells
        fr,     /// fraction of the leftover space, weight `a`
        minmax, /// content clamped to `[a, b]`
    }

    Kind kind;
    int a;
    int b;

@safe pure nothrow @nogc:

    /// Size to content.
    enum TrackSpec auto_ = TrackSpec(Kind.auto_);
    /// Exactly `n` cells.
    static TrackSpec fixed(int n) => TrackSpec(Kind.fixed, n);
    /// A leftover share of weight `w`.
    static TrackSpec fr(int w = 1) => TrackSpec(Kind.fr, w);
    /// Content clamped to `[min, max]`.
    static TrackSpec minmax(int min, int max) => TrackSpec(Kind.minmax, min, max);
}

/**
Resolves `tracks` into extents within `avail` cells with `gap` cells between
adjacent tracks. `contentWidths` carries each track's measured max-content
extent (what `auto`/`minmax` size to; ignored for `fixed`), index-parallel to
`tracks`.

`fr` tracks share what is left after gaps, `fixed`, `auto` and `minmax` —
integer divmod by weight, the remainder one cell each to the first `fr` tracks
in order, and never below zero. With no `fr` tracks the grid simply takes its
content extent (which may exceed or undershoot `avail`; the caller decides
whether that overflows or leaves slack).
*/
int[] resolveTracks(
    in TrackSpec[] tracks, in int[] contentWidths, int avail, int gap = 0)
    pure nothrow
// A message keeps the assert non-templated (`_d_assert_msg`), so consumers
// building with a different `-checkaction` never chase a missing instance.
in (tracks.length == contentWidths.length, "one content width per track")
{
    auto extents = new int[](tracks.length);

    int used = tracks.length > 1 ? gap * (cast(int) tracks.length - 1) : 0;
    int totalWeight;
    foreach (i, t; tracks)
    {
        final switch (t.kind) with (TrackSpec.Kind)
        {
            case auto_:
                extents[i] = contentWidths[i];
                break;
            case fixed:
                extents[i] = t.a;
                break;
            case fr:
                extents[i] = 0;
                totalWeight += t.a > 0 ? t.a : 1;
                break;
            case minmax:
                extents[i] = contentWidths[i] < t.a ? t.a
                    : contentWidths[i] > t.b ? t.b : contentWidths[i];
                break;
        }
        used += extents[i];
    }

    if (totalWeight > 0 && avail > used)
    {
        const leftover = avail - used;
        int handedOut;
        foreach (i, t; tracks)
        {
            if (t.kind != TrackSpec.Kind.fr)
                continue;
            const weight = t.a > 0 ? t.a : 1;
            const share = leftover * weight / totalWeight;
            extents[i] += share;
            handedOut += share;
        }
        int remainder = leftover - handedOut;
        foreach (i, t; tracks)
        {
            if (remainder == 0)
                break;
            if (t.kind != TrackSpec.Kind.fr)
                continue;
            extents[i]++;
            remainder--;
        }
    }

    return extents;
}

/**
Widens tracks for spanning cells: a cell covering `count` tracks from `first`
whose `content` exceeds the covered extent (tracks plus the `gap`s inside the
span) distributes the deficit among the covered $(B non-`fixed`) tracks —
integer divmod, remainder one cell each front-to-back. Fixed tracks are
declared widths and never widened; a span covering only fixed tracks
overflows instead. Apply spans narrowest-first for stable results (the CSS
grid rule of thumb), which is the caller's ordering responsibility.
*/
struct TrackSpan
{
    size_t first;  /// index of the first covered track
    size_t count;  /// number of covered tracks (≥ 1)
    int content;   /// the spanning cell's measured extent
}

/// ditto
void applySpans(
    in TrackSpec[] tracks, scope int[] extents, in TrackSpan[] spans, int gap = 0)
    pure nothrow @nogc
{
    foreach (span; spans)
    {
        if (span.count == 0 || span.first + span.count > tracks.length)
            continue;
        const lo = span.first, hi = span.first + span.count;

        int covered = span.count > 1 ? gap * (cast(int) span.count - 1) : 0;
        size_t widenable;
        foreach (i; lo .. hi)
        {
            covered += extents[i];
            widenable += tracks[i].kind != TrackSpec.Kind.fixed;
        }
        if (covered >= span.content || widenable == 0)
            continue;

        const deficit = span.content - covered;
        const share = deficit / cast(int) widenable;
        auto remainder = deficit % cast(int) widenable;
        foreach (i; lo .. hi)
        {
            if (tracks[i].kind == TrackSpec.Kind.fixed)
                continue;
            extents[i] += share + (remainder > 0 ? 1 : 0);
            if (remainder > 0)
                remainder--;
        }
    }
}

/**
Writes `tracks` as a `grid-template-columns` value — the HTML target's native
spelling of the same vocabulary (`auto` / `Nch` / `Nfr` / `minmax(Ach,Bch)`),
so a browser resolves what $(LREF resolveTracks) resolves on the cell grid.
*/
void writeGridTemplate(Writer)(ref Writer w, in TrackSpec[] tracks)
{
    import std.range.primitives : put;
    import sparkles.base.text.writers : writeInteger;

    foreach (i, t; tracks)
    {
        if (i)
            put(w, ' ');
        final switch (t.kind) with (TrackSpec.Kind)
        {
            case auto_:
                put(w, "auto");
                break;
            case fixed:
                writeInteger(w, t.a);
                put(w, "ch");
                break;
            case fr:
                writeInteger(w, t.a > 0 ? t.a : 1);
                put(w, "fr");
                break;
            case minmax:
                put(w, "minmax(");
                writeInteger(w, t.a);
                put(w, "ch,");
                writeInteger(w, t.b);
                put(w, "ch)");
                break;
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("ui.tracks.fixedAutoAndFr")
@safe pure nothrow unittest
{
    // | fixed 4 | auto (content 6) | 1fr | 2fr |  in 30 cells, gap 1.
    const tracks = [
        TrackSpec.fixed(4), TrackSpec.auto_, TrackSpec.fr(), TrackSpec.fr(2),
    ];
    const widths = resolveTracks(tracks, [9, 6, 3, 3], 30, 1);
    // 30 - 3 gaps - 4 fixed - 6 auto = 17 leftover → 1fr:5, 2fr:11, +1 to first.
    assert(widths == [4, 6, 6, 11]);
    assert(widths[0] + widths[1] + widths[2] + widths[3] + 3 == 30); // exact
}

@("ui.tracks.frExactnessAtEveryWidth")
@safe pure nothrow unittest
{
    // Property: with fr tracks present, the parts + gaps always sum to avail.
    const tracks = [TrackSpec.fr(2), TrackSpec.fixed(3), TrackSpec.fr(3)];
    foreach (avail; 6 .. 40)
    {
        const widths = resolveTracks(tracks, [0, 0, 0], avail, 1);
        assert(widths[0] + widths[1] + widths[2] + 2 == avail);
    }
}

@("ui.tracks.minmaxClampsContent")
@safe pure nothrow unittest
{
    const tracks = [TrackSpec.minmax(4, 8), TrackSpec.minmax(4, 8)];
    // Content below min pads up; content above max clamps down.
    assert(resolveTracks(tracks, [2, 12], 100) == [4, 8]);
}

@("ui.tracks.spanWidensItsTracks")
@safe pure nothrow unittest
{
    // Two auto tracks (3 + 3, gap 1 → 7 covered); a span needing 12 hands the
    // 5-cell deficit out 3/2. A fixed track is never widened.
    const tracks = [TrackSpec.auto_, TrackSpec.auto_, TrackSpec.fixed(2)];
    auto extents = resolveTracks(tracks, [3, 3, 0], 100, 1);
    assert(extents == [3, 3, 2]);

    applySpans(tracks, extents, [TrackSpan(first: 0, count: 2, content: 12)], 1);
    assert(extents == [6, 5, 2]);
    assert(extents[0] + 1 + extents[1] == 12); // the span now fits exactly

    // A span over a fixed track leaves it alone and widens the rest.
    applySpans(tracks, extents, [TrackSpan(first: 1, count: 2, content: 12)], 1);
    assert(extents[2] == 2);
    assert(extents[1] == 9); // 5 + (12 - (5+1+2)) = 9, all on the auto track
}

@("ui.tracks.gridTemplateEmission")
@safe pure unittest
{
    import std.array : appender;

    auto w = appender!string;
    writeGridTemplate(w, [
        TrackSpec.fixed(12), TrackSpec.auto_, TrackSpec.fr(),
        TrackSpec.minmax(4, 8),
    ]);
    assert(w[] == "12ch auto 1fr minmax(4ch,8ch)");
}
