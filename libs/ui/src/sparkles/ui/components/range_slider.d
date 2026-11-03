/**
Numeric slider interaction shared by settings surfaces. Geometry is captured
at press time, so relayout during a preview cannot move the drag's scale.
The owner applies preview/commit values through its property edit dispatch.
*/
module sparkles.ui.components.range_slider;

import std.math : floor, isFinite;

import sparkles.ui.geometry : Rect;

@safe pure nothrow @nogc:

/// The declared numeric domain, including the font's runtime default.
struct SliderDomain
{
    @safe pure nothrow @nogc:
    double lo, hi, step;

    /// Maps a position onto the domain, rounding steps relative to its minimum.
    double valueAt(double x, in Rect track) const
    {
        if (!(hi > lo) || !lo.isFinite || !hi.isFinite)
            return lo;
        double fraction = track.width > 1 ? (x - track.x) / (track.width - 1) : 0;
        fraction = fraction < 0 ? 0 : fraction > 1 ? 1 : fraction;
        double value = lo + fraction * (hi - lo);
        if (step > 0 && step.isFinite)
            value = lo + floor((value - lo) / step + 0.5) * step;
        return value < lo ? lo : value > hi ? hi : value;
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
