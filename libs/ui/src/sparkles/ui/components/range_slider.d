/**
Numeric slider interaction shared by settings surfaces. Geometry is captured
at press time, so relayout during a preview cannot move the drag's scale.
The owner applies preview/commit values through its property edit dispatch.
*/
module sparkles.ui.components.range_slider;

import std.math : floor, isFinite, sqrt;

import sparkles.ui.geometry : Rect;

@safe pure nothrow @nogc:

/// The declared numeric domain, including optional non-linear split mapping.
struct SliderDomain
{
    @safe pure nothrow @nogc:
    double lo = 0, hi = 0, step = 0;
    double splitLo = 0;   /// split point value (e.g. 18.0)
    double splitFrac = 0; /// fraction where split occurs (e.g. 0.50)
    double splitW = 0.05; /// transition half-width (e.g. 0.05 for 45%-55%)

    bool hasSplit() const
    {
        if (!(hi > lo && lo.isFinite && hi.isFinite
                && splitFrac > 0 && splitLo > lo && splitLo < hi && splitW > 0
                && (splitFrac - splitW) > 0 && (splitFrac + splitW) < 1))
            return false;
        // Both straight sections must rise; otherwise clamping the quadratic
        // creates dead zones and there is no unique inverse.
        const c1 = splitW / (4 * splitFrac);
        const c2 = splitW / (4 * (1 - splitFrac));
        // Use the mapping's actual arithmetic here: rearranging the bounds
        // can disagree at a zero-slope boundary due to floating-point rounding.
        const vIntersect = (splitLo - c1 * lo - c2 * hi) / (1 - c1 - c2);
        const m1 = (vIntersect - lo) / splitFrac;
        const m2 = (hi - vIntersect) / (1 - splitFrac);
        const v1 = lo + m1 * (splitFrac - splitW);
        const v2 = hi - m2 * (1 - (splitFrac + splitW));
        return m1 > 0 && m2 > 0 && v1 > lo && v2 < hi;
    }

    /// Maps a normalized fraction [0, 1] onto the domain value [lo, hi].
    double valueOf(double fraction) const
    {
        if (!(hi > lo) || !lo.isFinite || !hi.isFinite)
            return lo;
        fraction = fraction < 0 ? 0 : fraction > 1 ? 1 : fraction;
        double value;
        if (hasSplit())
        {
            const u1 = splitFrac - splitW;
            const u2 = splitFrac + splitW;
            const w2 = 2 * splitW;
            const c1 = splitW / (4 * splitFrac);
            const c2 = splitW / (4 * (1 - splitFrac));
            const vIntersect = (splitLo - c1 * lo - c2 * hi) / (1 - c1 - c2);
            const m1 = (vIntersect - lo) / splitFrac;
            const m2 = (hi - vIntersect) / (1 - splitFrac);
            if (fraction <= u1)
                value = lo + m1 * fraction;
            else if (fraction >= u2)
                value = hi - m2 * (1 - fraction);
            else
            {
                const v1 = lo + m1 * u1;
                const t = (fraction - u1) / w2;
                value = v1 + w2 * (m1 * t + 0.5 * (m2 - m1) * t * t);
            }
        }
        else
        {
            value = lo + fraction * (hi - lo);
        }
        if (step > 0 && step.isFinite)
            value = lo + floor((value - lo) / step + 0.5) * step;
        return value < lo ? lo : value > hi ? hi : value;
    }

    /// Maps a domain value [lo, hi] back to a normalized fraction [0, 1].
    double fractionOf(double value) const
    {
        if (!(hi > lo) || !lo.isFinite || !hi.isFinite)
            return 0;
        if (value <= lo) return 0;
        if (value >= hi) return 1;
        if (hasSplit())
        {
            const u1 = splitFrac - splitW;
            const u2 = splitFrac + splitW;
            const w2 = 2 * splitW;
            const c1 = splitW / (4 * splitFrac);
            const c2 = splitW / (4 * (1 - splitFrac));
            const vIntersect = (splitLo - c1 * lo - c2 * hi) / (1 - c1 - c2);
            const m1 = (vIntersect - lo) / splitFrac;
            const m2 = (hi - vIntersect) / (1 - splitFrac);
            const v1 = lo + m1 * u1;
            const v2 = hi - m2 * (1 - u2);
            if (value <= v1)
                return (value - lo) / m1;
            if (value >= v2)
                return 1.0 - (hi - value) / m2;
            const A = splitW * (m2 - m1);
            const B = w2 * m1;
            const C = v1 - value;
            const disc = B * B - 4 * A * C;
            // Rationalizing the root also handles equal slopes (A == 0)
            // and avoids cancellation when the slopes are nearly equal.
            const t = disc > 0 ? -2 * C / (B + sqrt(disc)) : 0;
            return u1 + w2 * t;
        }
        return (value - lo) / (hi - lo);
    }

    /// Maps a position onto the domain, rounding steps relative to its minimum.
    double valueAt(double x, in Rect track) const
    {
        if (!(hi > lo) || !lo.isFinite || !hi.isFinite)
            return lo;
        double fraction = track.width > 1 ? (x - track.x) / (track.width - 1) : 0;
        return valueOf(fraction);
    }
}

/// One captured drag. Cancellation returns the exact starting value.
struct RangeSlider
{
    @safe pure nothrow @nogc:
    bool active;
    Rect track;
    SliderDomain domain;
    double before, value;

    /// Starts a drag using the geometry as drawn, retaining it until release.
    void begin(in Rect rect, in SliderDomain bounds, double initial, double x)
    {
        active = true;
        track = rect;
        domain = bounds;
        before = initial;
        value = domain.valueAt(x, track);
    }

    /// Continues outside the track too; the domain clamps both ends.
    double move(double x)
    {
        if (active)
            value = domain.valueAt(x, track);
        return value;
    }

    /// Releases capture and returns the final value for one committed edit.
    double finish()
    {
        active = false;
        return value;
    }

    /// Releases capture and restores the pre-drag value without a commit.
    double cancel()
    {
        active = false;
        value = before;
        return before;
    }
}

/// Fractional bounds, snapping, capture outside the track, and cancellation.
@("ui.range_slider.runtimeDomainAndCapture")
unittest
{
    RangeSlider slider;
    slider.begin(Rect(10, 2, 101, 3), SliderDomain(-12.5, 20, 0.5), 4, 10);
    assert(slider.value == -12.5);
    assert(slider.move(60) == 4);
    assert(slider.move(1000) == 20);
    assert(slider.move(-1000) == -12.5);
    assert(slider.cancel() == 4 && !slider.active);
    slider.begin(Rect(10, 2, 101, 3), SliderDomain(100, 900, 1), 400, 60);
    assert(slider.finish() == 500 && !slider.active);
}

/// Equal and almost equal slopes retain a finite, accurate inverse.
@("ui.range_slider.equalSlopeSplitInverse")
@safe pure nothrow @nogc unittest
{
    import std.math : abs;

    foreach (split; [50.0, 50.0 - 1e-10, 50.0 + 1e-10])
    {
        const domain = SliderDomain(0, 100, 0, split, 0.5, 0.05);
        foreach (i; 1 .. 100)
        {
            const fraction = i / 100.0;
            const inverse = domain.fractionOf(domain.valueOf(fraction));
            assert(inverse.isFinite);
            assert(abs(inverse - fraction) < 1e-10);
        }
    }
}

/// Splits without positive segment slopes fall back to a linear domain.
@("ui.range_slider.invalidSplitFallsBackToLinear")
@safe pure nothrow @nogc unittest
{
    import std.math : abs;

    foreach (split; [1.0, 2.5, 97.5, 99.0])
    {
        const domain = SliderDomain(0, 100, 0, split, 0.5, 0.05);
        assert(!domain.hasSplit);
        foreach (i; 0 .. 101)
        {
            const u = i / 100.0;
            assert(abs(domain.valueOf(u) - i) < 1e-10);
            assert(abs(domain.fractionOf(i) - u) < 1e-10);
        }
    }
    foreach (domain; [SliderDomain(0, 100, 0, 2.5, 0.1, 0.09),
            SliderDomain(4, 14, 0, 4.75, 0.7, 0.09)])
        assert(!domain.hasSplit, "rounded zero-slope boundaries must be rejected");
}

/// Piecewise non-linear split domain smoothly interpolates across transition zone
/// and accurately round-trips forward and inverse mappings.
@("ui.range_slider.splitDomainSmoothTransitionAndRoundTrip")
unittest
{
    import std.math : abs;

    const domain = SliderDomain(4.0, 144.0, 0, 18.0, 0.50, 0.05);
    assert(domain.hasSplit);
    assert(domain.valueOf(0.0) == 4.0);
    assert(abs(domain.valueOf(0.50) - 18.0) < 1e-10);
    assert(domain.valueOf(1.0) == 144.0);

    // Verify smooth C1 slope around transition: slopes must match linear segments
    const vLo = domain.valueOf(0.45);
    const vHi = domain.valueOf(0.55);
    assert(vLo > 4.0 && vLo < 18.0);
    assert(vHi > 18.0 && vHi < 144.0);

    // Round-trip check across all fractions
    foreach (i; 0 .. 101)
    {
        const u = i / 100.0;
        const v = domain.valueOf(u);
        const uBack = domain.fractionOf(v);
        assert(abs(u - uBack) < 1e-10, "fractionOf must invert valueOf exactly");
    }
}
