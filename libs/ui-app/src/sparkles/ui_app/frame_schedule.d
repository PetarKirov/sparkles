/**
When the native arm starts a frame (output-latency.md §3, `OPL13`–`OPL17`):
as late as still makes the earliest refresh the frame can reach, so the bytes
that arrive in the meantime are in it, and never later.

A pure state machine: presentation feedback, frame costs and the current time
are its inputs; the time to start the next frame, and the refresh it aims at,
its output. The native loop feeds it and parks until the time it names.
*/
module sparkles.ui_app.frame_schedule;

import core.time : Duration, MonoTime, msecs, seconds, usecs;

/// How the native arm times a frame (`OPL18`).
enum FrameSchedulePolicy : ubyte
{
    late, /// start at the latch deadline of the earliest reachable refresh
    asap, /// start as soon as the window system allows
}

/// When to start the next frame, and the presentation it aims at.
struct FrameStart
{
    MonoTime at;     /// start no earlier than this
    MonoTime target; /// the predicted presentation; `MonoTime.init` when none
}

/// The scheduler's state (`OPL13`–`OPL17`).
struct FrameSchedule
{
    /// The margin a compositor is first assumed to need (`OPL16`).
    enum Duration initialMargin = 2.msecs;
    /// How far a late frame raises the margin.
    enum Duration raiseStep = 1.msecs;
    /// How far a run of frames on time lowers it.
    enum Duration lowerStep = 250.usecs;
    /// The lowest margin.
    enum Duration marginFloor = 500.usecs;
    /// Frames on time before the margin is lowered.
    enum uint onTimeRun = 32;
    /// Frame costs kept for the percentile (`OPL15`).
    enum uint costWindow = 64;
    /// Costs known before the percentile is trusted.
    enum uint costsTrusted = 8;
    /// Feedback older than this predicts nothing (`OPL17`).
    enum Duration feedbackLifetime = 1.seconds;

    FrameSchedulePolicy policy; ///

    @safe pure nothrow @nogc:

    /// The compositor margin in force.
    Duration margin() const => margin_;

    /// Notes a presented frame's cost: from its pass's start to the return of
    /// its present.
    void noteCost(Duration cost)
    {
        costs_[costHead_] = cost;
        costHead_ = (costHead_ + 1) % costWindow;
        if (costCount_ < costWindow)
            ++costCount_;
    }

    /// The 95th percentile of the recent costs; half the refresh until
    /// `costsTrusted` are known.
    Duration cost95() const
    {
        if (costCount_ < costsTrusted)
            return refresh_ / 2;
        Duration[costWindow] sorted = costs_;
        auto s = sorted[0 .. costCount_];
        // Insertion sort: 64 entries at most.
        foreach (i; 1 .. s.length)
            for (size_t j = i; j > 0 && s[j - 1] > s[j]; --j)
            {
                const t = s[j - 1];
                s[j - 1] = s[j];
                s[j] = t;
            }
        return s[(s.length - 1) * 95 / 100];
    }

    /**
    Notes that a frame was shown at `shown`, the display refreshing every
    `refresh` (zero: unknown or variable), received at `now`. `target` is the
    presentation the frame aimed at, `MonoTime.init` if none; a frame shown
    later than half a refresh after it raises the margin, a run on time lowers
    it (`OPL16`).
    */
    void noteShown(MonoTime shown, Duration refresh, MonoTime target, MonoTime now)
    {
        lastShown_ = shown;
        refresh_ = refresh;
        heardAt_ = now;
        if (target == MonoTime.init || refresh <= Duration.zero)
            return;
        if (shown > target + refresh / 2)
        {
            const raised = margin_ + raiseStep;
            margin_ = raised < refresh / 2 ? raised : refresh / 2;
            onTime_ = 0;
        }
        else if (++onTime_ >= onTimeRun)
        {
            const lowered = margin_ - lowerStep;
            margin_ = lowered > marginFloor ? lowered : marginFloor;
            onTime_ = 0;
        }
    }

    /**
    When a frame due at `now` should start (`OPL13`, `OPL14`, `OPL17`): the
    latch deadline `P − cost95 − margin` of the earliest refresh
    `P = shown + k·refresh`, `k ≥ 1`, whose deadline is not past; or `now`,
    aiming at nothing, under `asap`, without a fixed refresh, or without
    feedback in the last second.
    */
    FrameStart start(MonoTime now) const
    {
        if (policy == FrameSchedulePolicy.asap || refresh_ <= Duration.zero
            || lastShown_ == MonoTime.init || now - heardAt_ > feedbackLifetime)
            return FrameStart(now, MonoTime.init);
        const lead = cost95() + margin_;
        const earliest = now + lead; // the earliest presentation a frame starting now makes
        long k = 1;
        if (earliest > lastShown_ + refresh_)
        {
            const behind = (earliest - lastShown_).total!"hnsecs";
            const period = refresh_.total!"hnsecs";
            k = (behind + period - 1) / period;
        }
        const target = lastShown_ + refresh_ * k;
        const at = target - lead;
        return FrameStart(at > now ? at : now, target);
    }

private:
    Duration margin_ = initialMargin;
    Duration refresh_;
    MonoTime lastShown_;
    MonoTime heardAt_;
    uint onTime_;
    Duration[costWindow] costs_;
    uint costHead_, costCount_;
}

version (unittest)
{
    // A clock in milliseconds from an arbitrary origin.
    private MonoTime ms(double t) @safe pure nothrow @nogc
        => MonoTime.zero + 1.seconds + usecs(cast(long) (t * 1000));
}

@("frame_schedule.startsAtTheLatchOfTheEarliestReachableRefresh")
@safe pure nothrow @nogc unittest
{
    FrameSchedule s;
    foreach (_; 0 .. 8)
        s.noteCost(3.msecs);
    // 60 Hz, last frame shown at 100 ms: refreshes at 116.67, 133.33, …
    const T = usecs(16_667);
    s.noteShown(ms(100), T, MonoTime.init, ms(101));
    // At 105 ms: 116.67 is reachable (its latch 116.67 − 3 − 2 = 111.67).
    auto st = s.start(ms(105));
    assert(st.target == ms(100) + T, "OPL13: the earliest reachable refresh");
    assert(st.at == st.target - 5.msecs, "OPL14: its latch deadline");
    // At 113 ms its latch has passed: the next refresh, started at its latch.
    st = s.start(ms(113));
    assert(st.target == ms(100) + T * 2);
    assert(st.at == st.target - 5.msecs);
    // Exactly at a latch: start now, for that refresh.
    st = s.start(ms(100) + T - 5.msecs);
    assert(st.at == ms(100) + T - 5.msecs && st.target == ms(100) + T);
}

@("frame_schedule.costIsThe95thPercentile")
@safe pure nothrow @nogc unittest
{
    FrameSchedule s;
    s.noteShown(ms(0), 16.msecs, MonoTime.init, ms(0));
    assert(s.cost95 == 8.msecs, "OPL15: half the refresh before 8 costs");
    foreach (i; 0 .. 100)
        s.noteCost(i % 20 == 19 ? 10.msecs : 1.msecs);
    // The last 64 hold four 10 ms costs; the 95th percentile of 64 is the
    // 60th entry, a 1 ms one.
    assert(s.cost95 == 1.msecs);
    foreach (_; 0 .. 5)
        s.noteCost(10.msecs);
    assert(s.cost95 == 10.msecs, "eight slow frames in 64 reach the 95th");
}

@("frame_schedule.theMarginFollowsMissesAndRunsOnTime")
@safe pure nothrow @nogc unittest
{
    FrameSchedule s;
    const T = 16.msecs;
    assert(s.margin == 2.msecs);
    // Shown a refresh after its target: late.
    s.noteShown(ms(132), T, ms(116), ms(133));
    assert(s.margin == 3.msecs, "OPL16: a miss raises the margin");
    foreach (_; 0 .. 20)
        s.noteShown(ms(300), T, ms(200), ms(301));
    assert(s.margin == T / 2, "never above half the refresh");
    foreach (_; 0 .. FrameSchedule.onTimeRun)
        s.noteShown(ms(400), T, ms(400), ms(401));
    assert(s.margin == T / 2 - 250.usecs, "a run on time lowers it");
    foreach (_; 0 .. 100 * FrameSchedule.onTimeRun)
        s.noteShown(ms(400), T, ms(400), ms(401));
    assert(s.margin == 500.usecs, "never below the floor");
}

@("frame_schedule.withoutAFixedRefreshItStartsNow")
@safe pure nothrow @nogc unittest
{
    FrameSchedule s;
    assert(s.start(ms(50)) == FrameStart(ms(50), MonoTime.init), "OPL17: no feedback yet");
    s.noteShown(ms(100), Duration.zero, MonoTime.init, ms(100));
    assert(s.start(ms(105)).at == ms(105), "OPL17: variable refresh");
    s.noteShown(ms(100), 16.msecs, MonoTime.init, ms(100));
    assert(s.start(ms(1200)).at == ms(1200), "OPL17: feedback more than a second old");
    s.policy = FrameSchedulePolicy.asap;
    assert(s.start(ms(105)).at == ms(105), "OPL18: asap");
}
