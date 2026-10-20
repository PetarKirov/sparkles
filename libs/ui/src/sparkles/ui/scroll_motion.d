/**
How one scroll axis moves between frames (`SCV12`): a position in content
units that a drag moves 1:1, a wheel notch or a page key eases toward, and a
lifted finger flings.

The position is a `double` so a pixel target can paint its fraction
(`Widget.childOffsetFracY`, `LAY7`); $(LREF ScrollMotion.whole) and
$(LREF ScrollMotion.frac) split it for the layout and the paint. On a target
that cannot show a fraction — a terminal, or one that asks for reduced
motion — the motion is $(LREF ScrollMotion.instant): a wheel or a key jumps
there in whole units, and a drag still accumulates, so a slow drag is never
lost to rounding.

The easing is a critically damped spring, the shape Neovide scrolls with:
it reaches its target in about `springSeconds` without overshooting, and a
new notch moves the target without throwing the velocity away, so notches in
quick succession add up to one smooth glide. A fling decays exponentially, at
the rate the touch recogniser's fling always has (`GST5`).
*/
module sparkles.ui.scroll_motion;

@safe pure nothrow @nogc:

/// What a $(LREF ScrollMotion) is doing between inputs.
enum MotionMode : ubyte
{
    idle,   /// at rest (a drag moves it and leaves it at rest)
    easing, /// springing toward `target`
    flinging, /// coasting on a lifted finger's velocity
}

/// One axis's scroll position and its motion (`SCV12`).
struct ScrollMotion
{
    /// The position, in content units (rows, for a vertical list).
    double pos = 0;
    /// Where an easing motion is heading.
    double target = 0;
    /// Content units per second.
    double velocity = 0;
    /// What it is doing.
    MotionMode mode;

    /// Wheel and keys jump, and positions are whole units: a cell target,
    /// or one that asked for reduced motion.
    bool instant;
    /// About how long the spring takes to arrive.
    float springSeconds = 0.2f;
    /// The fling's exponential decay rate, per second (`GST5`'s).
    float flingFriction = 4.5f;
    /// The speed, in units per second, below which a fling stops.
    float minFlingSpeed = 0.5f;

@safe pure nothrow @nogc:

    /// The whole units of the position — what layout scrolls by.
    long whole() const
    {
        const p = shown;
        const w = cast(long) p;
        return w > p ? w - 1 : w;
    }

    /// The fraction past `whole`, `0 ≤ frac < 1` — what a pixel target paints
    /// (`LAY7`); always 0 when `instant`.
    float frac() const => instant ? 0 : cast(float)(shown - whole);

    /// Whether frames must keep coming: an ease or a fling is under way.
    bool active() const => mode != MotionMode.idle;

    /// The position as shown: whole units when `instant`.
    private double shown() const
    {
        if (!instant)
            return pos;
        const w = cast(long) pos;
        return w > pos ? w - 1 : w;
    }

    /**
    A finger or a trackpad moved the content by `delta` units: followed 1:1,
    and any ease or fling stops, because the hand now holds the content.
    `limit` is the largest position (`content - viewport`).
    */
    void drag(double delta, double limit)
    {
        mode = MotionMode.idle;
        velocity = 0;
        pos = clamp(pos + delta, limit);
        target = pos;
    }

    /**
    A wheel notch or a key moved the content by `delta` units: the target
    moves — from where an ease already in flight was heading, so notches add
    up — and the position springs after it. Instant: it jumps there.
    */
    void nudge(double delta, double limit)
    {
        const from = mode == MotionMode.easing ? target : (instant ? shown : pos);
        scrollTo(from + delta, limit);
    }

    /// Eases to `to` (clamped); jumps there when `instant`.
    void scrollTo(double to, double limit)
    {
        target = clamp(to, limit);
        if (instant)
        {
            pos = target;
            settle();
            return;
        }
        if (mode != MotionMode.easing)
            velocity = mode == MotionMode.flinging ? velocity : 0;
        mode = target == pos ? MotionMode.idle : MotionMode.easing;
    }

    /// Jumps to `to` (clamped) with no motion: a reveal the user did not
    /// ask to watch, or a model that moved underneath.
    void jumpTo(double to, double limit)
    {
        pos = clamp(to, limit);
        settle();
    }

    /**
    A lifted finger left the content moving at `unitsPerSecond`: it coasts
    and slows down. Instant targets have no frames to coast through, so the
    fling is dropped there — the drag already moved the content.
    */
    void fling(double unitsPerSecond)
    {
        if (instant || (unitsPerSecond < minFlingSpeed && unitsPerSecond > -minFlingSpeed))
            return;
        velocity = unitsPerSecond;
        mode = MotionMode.flinging;
    }

    /// Stops wherever it is.
    void stop() => settle();

    /**
    Advances `dt` seconds, clamped to `[0, limit]`. A clamp ends a fling
    and an ease (there is nothing past the edge to show). Returns
    $(LREF active): whether the next frame must come.
    */
    bool step(double dt, double limit)
    {
        if (dt <= 0)
            return active;
        final switch (mode)
        {
            case MotionMode.idle:
                pos = clamp(pos, limit);
                break;
            case MotionMode.easing:
                target = clamp(target, limit);
                // The limit shrank under the content (a filter, a taller
                // viewport): what it showed past the new end is gone.
                if (pos != clamp(pos, limit))
                {
                    pos = target;
                    settle();
                    break;
                }
                // Critically damped: x'' = −2ωx' − ω²x, solved exactly over
                // the step, so a long frame cannot overshoot.
                const omega = 4.0 / (springSeconds > 0 ? springSeconds : 0.2);
                const x = pos - target;
                const c = exp(-omega * dt);
                const b = x * omega + velocity;
                const nx = (x + b * dt) * c;
                velocity = c * (-x * omega - b * omega * dt + b);
                pos = target + nx;
                if (nx < 0.01 && nx > -0.01)
                {
                    pos = target;
                    settle();
                }
                break;
            case MotionMode.flinging:
                pos += velocity * dt;
                velocity *= exp(-flingFriction * dt);
                if (pos <= 0 || pos >= limit
                    || (velocity < minFlingSpeed && velocity > -minFlingSpeed))
                {
                    pos = clamp(pos, limit);
                    settle();
                }
                break;
        }
        return active;
    }

    private void settle()
    {
        mode = MotionMode.idle;
        velocity = 0;
        target = pos;
    }

    private static double clamp(double v, double limit)
        => v < 0 ? 0 : (v > limit ? (limit > 0 ? limit : 0) : v);
}

// `std.math.exp` is not `pure` in every configuration this repo builds; the
// precision a scroll animation needs is low, and a series on a reduced
// argument is exact enough.
private double exp(double x)
{
    if (x < -30)
        return 0;
    int halvings;
    while (x < -0.5 || x > 0.5)
    {
        x /= 2;
        ++halvings;
    }
    // Taylor series to the 8th power: |x| ≤ 0.5 keeps the error below 1e-9.
    double term = 1, sum = 1;
    foreach (n; 1 .. 9)
    {
        term *= x / n;
        sum += term;
    }
    foreach (_; 0 .. halvings)
        sum *= sum;
    return sum;
}

@("ui.scroll_motion.dragFollowsTheFingerAndStopsAnEase")
@safe pure nothrow @nogc
unittest
{
    ScrollMotion m;
    m.nudge(10, 100);
    assert(m.active);
    m.drag(2.25, 100);
    assert(!m.active, "the hand holds the content now");
    assert(m.pos == 2.25 && m.whole == 2 && m.frac == 0.25f);
    m.drag(-5, 100);
    assert(m.pos == 0, "clamped at the start");
    m.drag(500, 100);
    assert(m.pos == 100, "and at the end");
}

@("ui.scroll_motion.theSpringArrivesWithoutOvershooting")
@safe pure nothrow @nogc
unittest
{
    ScrollMotion m;
    m.nudge(3, 100);
    double last = 0;
    int frames;
    while (m.step(1.0 / 60, 100))
    {
        assert(m.pos >= last && m.pos <= 3, "monotone, never past the target");
        last = m.pos;
        ++frames;
        assert(frames < 120);
    }
    assert(m.pos == 3 && m.frac == 0);
    // About twice `springSeconds` to settle within 0.01 of a row.
    assert(frames <= 30, "arrives promptly");
}

@("ui.scroll_motion.notchesAddUpAndKeepTheirVelocity")
@safe pure nothrow @nogc
unittest
{
    ScrollMotion m;
    m.nudge(3, 100);
    m.step(1.0 / 60, 100);
    m.step(1.0 / 60, 100);
    const v = m.velocity;
    assert(v > 0);
    m.nudge(3, 100);
    assert(m.target == 6, "from the target in flight, not from where it is");
    assert(m.velocity == v, "a retarget keeps the motion it had");
    while (m.step(1.0 / 60, 100)) {}
    assert(m.pos == 6);
}

@("ui.scroll_motion.aShrunkLimitEndsAnEaseAtTheNewEnd")
@safe pure nothrow @nogc
unittest
{
    ScrollMotion m;
    m.jumpTo(80, 100);
    m.nudge(20, 100);
    m.step(1.0 / 60, 100);
    assert(m.active && m.pos > 80);
    m.step(1.0 / 60, 50);
    assert(!m.active, "a clamp ends the ease");
    assert(m.pos == 50 && m.target == 50);
}

@("ui.scroll_motion.aFlingSlowsDownAndStopsAtTheEdge")
@safe pure nothrow @nogc
unittest
{
    ScrollMotion m;
    m.pos = 50;
    m.fling(40);
    assert(m.mode == MotionMode.flinging);
    double last = m.pos, lastStep = double.infinity;
    while (m.step(1.0 / 60, 100))
    {
        const stepped = m.pos - last;
        assert(stepped > 0 && stepped <= lastStep, "decelerating");
        lastStep = stepped;
        last = m.pos;
    }
    // Exponential decay covers v / friction in total: 40 / 4.5 ≈ 8.9.
    assert(m.pos > 57 && m.pos < 60);

    m.pos = 98;
    m.fling(40);
    while (m.step(1.0 / 60, 100)) {}
    assert(m.pos == 100 && m.velocity == 0, "the edge ends it");

    m.fling(0.1);
    assert(!m.active, "too slow to coast");
}

@("ui.scroll_motion.instantJumpsInWholeUnitsAndKeepsADragsRemainder")
@safe pure nothrow @nogc
unittest
{
    ScrollMotion m;
    m.instant = true;
    m.nudge(3, 100);
    assert(!m.active && m.pos == 3, "no ease on a cell target");
    m.drag(0.6, 100);
    assert(m.whole == 3 && m.frac == 0, "shown whole");
    m.drag(0.6, 100);
    assert(m.whole == 4, "but a slow drag is never lost");
    m.nudge(1, 100);
    assert(m.pos == 5, "a notch counts from the row shown");
    m.fling(30);
    assert(!m.active, "no frames to coast through");
}

@("ui.scroll_motion.expIsCloseEnough")
@safe pure nothrow @nogc
unittest
{
    assert(exp(0) == 1);
    const e = exp(1);
    assert(e > 2.718281 && e < 2.718282);
    const s = exp(-4.5 / 60);
    assert(s > 0.927743 && s < 0.927744);
    assert(exp(-40) == 0);
}
