/**
The native arm's lifecycle, without the I/O (`docs/specs/ui-app/resilience.md`).

What the window system and the GPU report goes in — surface metrics, frame
opportunities, occlusion, memory pressure, how a frame went, how a rebuild
went — and what the host must do next comes out, as a $(LREF Plan): which
scopes to end, what to rebuild, whether to draw, how long to park. The loop
that owns the window and the device executes the plan and reports back; it
makes no lifecycle decision of its own. So every decision is a function of
the inputs, and the resilience scenarios run here without a window or a
device (the `model` lane).

Time is an input too: each call that needs it takes `now`, the time since
the run began.
*/
module sparkles.ui_app.lifecycle;

import core.time : Duration, msecs, seconds;

/// The host's states (resilience §1). Nothing leads back to `starting`.
enum HostPhase : ubyte
{
    starting,   /// `setup` has run; no surface yet
    visible,    /// a surface exists and can be seen
    hidden,     /// a surface exists and cannot be seen
    suspended,  /// the window exists, its surface does not
    recovering, /// the device or the surface is being rebuilt after a loss
    stopping,   /// quit or close accepted
}

/// How a frame the plan asked for went.
enum FrameResult : ubyte
{
    presented,   /// drawn and presented
    again,       /// nothing presented that shows the frame; draw another
    outOfDate,   /// the swapchain no longer matches the surface
    surfaceLost, /// the surface itself is gone
    deviceLost,  ///
    outOfMemory, /// abandoned, caches to release (`UVK34`)
    failed,      /// an error no rebuild repairs
}

/// A rebuild the plan asked for.
enum Rebuild : ubyte
{
    targets, /// the swapchain and its views
    surface, /// a surface from the window's native handles, and its targets
    device,  /// the device, its canvas, a surface and its targets
}

/// Why the host stopped, when it was not asked to (`RES27`).
enum Failure : ubyte
{
    none,
    frame,             /// a frame failed in a way no rebuild repairs
    recoveryExhausted, /// rebuilding failed `maxRecoveries` times in a row
    lossStorm,         /// the device was lost `maxLosses` times within `lossWindow`
}

/// The surface as the window system reports it, in device pixels.
struct Surface
{
    uint width;       ///
    uint height;      ///
    double scale = 1; /// device pixels per logical unit

    /// No extent: the window has no surface now (window-system spec §5.1).
    bool suspended() const @safe pure nothrow @nogc => width == 0 || height == 0;
}

/**
What the loop does next, in field order: stop, or end scopes, create,
rebuild, re-measure, then draw or park.
*/
struct Plan
{
    bool stop;              /// enter `stopping`: run `shutdown`, end every scope
    Failure failure;        /// why, when the host stops on its own
    bool releaseSurface;    /// end the surface scope: swapchain, views, native surface
    bool releaseDevice;     /// end the device scope (and the surface's)
    bool releaseCaches;     /// release the canvas's caches (`UVK32`)
    bool deliverPressure;   /// tell the application memory is short (`RES17`)
    bool createDevice;      /// a device, its canvas, a surface and its targets
    bool createSurface;     /// a surface from the window's current handles
    bool rebuildTargets;    /// a swapchain for the current surface
    bool draw;              /// build a frame and draw it
    bool mustDraw;          /// the frame may not be skipped (`HST6`)
    /// A frame is wanted on a paced window and waits for its opportunity:
    /// ask the window system for one, where it gives them only on request
    /// (Android's `AChoreographer`; Wayland's come unasked).
    bool askFrame;
    Duration park = Duration.max; /// how long to wait for events first

    /// Whether the plan changes nothing and draws nothing.
    bool idle() const @safe pure nothrow @nogc
        => !stop && !releaseSurface && !releaseDevice && !releaseCaches && !deliverPressure
            && !createDevice && !createSurface && !rebuildTargets && !draw;
}

/**
The lifecycle machine. Feed it what happened since the last $(LREF step),
execute the plan `step` returns, report how it went, repeat.
*/
struct Lifecycle
{
    /// Rebuilds that may fail in a row before the host gives up (`RES27`).
    enum maxRecoveries = 3;
    /// Device losses tolerated within `lossWindow`; one more stops (`RES27`).
    enum maxLosses = 3;
    /// ditto
    enum Duration lossWindow = 10.seconds;
    /// The longest `frameSeconds` reported, after a hidden or suspended
    /// stretch (`RES34`).
    enum Duration maxFrameInterval = 250.msecs;

    // ── configuration ──
    /// Frames wait for a frame opportunity (`FrameReadyEvent`).
    bool paced;
    /// Release the device on critical pressure while not visible (`RES17`).
    bool releaseDeviceUnderPressure;
    /// The longest park while hidden; `Duration.max` for none beyond the
    /// application's own wake (`RES11`).
    Duration hiddenPeriod = Duration.max;
    /// The cell font size the run starts with, in `sizeAt`'s unit.
    double base = 18;
    /// The cell font's pixels for a size `base` at `scale`, and back. By
    /// default `base` is pixels at scale 1; a loop that sizes in points
    /// supplies its own pair.
    int function(double base, double scale) @safe pure nothrow @nogc sizeAt = &scaledPx;
    /// ditto
    double function(int px, double scale) @safe pure nothrow @nogc baseOf = &unscaledPx;

    private
    {
        HostPhase state_;
        Surface surface_;
        double scale_ = 1;
        bool havePending_;
        Surface pending_;
        bool occluded_;
        bool frameReady_ = true;
        bool dirty_ = true;
        bool requested_;
        bool mustDraw_ = true;
        bool closing_;
        bool needTargets_;
        bool needSurface_;
        bool needDevice_;
        bool deviceUp_;
        bool cachesToRelease_;
        bool pressure_;
        bool criticalPressure_;
        bool userChoseSize_;
        double userBase_ = 0; // the user's chosen size, in `base`'s unit (`RES55`)
        int measuredPx_;
        int recoveries_;
        Failure failure_;
        Duration[maxLosses + 1] losses_;
        uint lossCount_;
        bool presentedOnce_;
        Duration lastPresent_;
        float frameSeconds_ = 0;
    }

    @safe pure nothrow @nogc:

    /// The current state.
    HostPhase state() const => state_;
    /// The surface the host works with.
    Surface surface() const => surface_;
    /// The cell font size last asked of the loop, in pixels.
    int measuredPx() const => measuredPx_;
    /// Seconds between the last two presented frames, clamped (`RES34`).
    float frameSeconds() const => frameSeconds_;

    // ── what happened ──

    /**
    The first configured surface: the loop has made the device, and the
    surface's objects when it has an extent, measuring the cell font at
    `measuredPx`.
    */
    void started(Surface s)
    {
        surface_ = s;
        scale_ = s.scale;
        deviceUp_ = true;
        measuredPx_ = pxFor(s.scale);
        mustDraw_ = dirty_ = true;
        state_ = s.suspended ? HostPhase.suspended : HostPhase.visible;
        needSurface_ = s.suspended;
    }

    /**
    The window system reported the surface's metrics. Rebuilds for changes
    drained together coalesce into one, at the last (`RES33`). Returns the
    cell font size to measure at now, before the application sees the
    change (`HST7`, `RES42`), or 0 when the scale is unchanged.
    */
    int metrics(Surface s)
    {
        pending_ = s;
        havePending_ = true;
        if (s.scale == scale_)
            return 0;
        scale_ = s.scale;
        measuredPx_ = pxFor(scale_);
        return measuredPx_;
    }

    /// A frame opportunity (`FrameReadyEvent`).
    void frameReady() { frameReady_ = true; }

    /// The window was uncovered and must redraw.
    void exposed() { dirty_ = true; }

    /// The window became hidden, or visible again (`RES11`).
    void occluded(bool now) { occluded_ = now; }

    /// Input reached the application: its next frame may differ (`RES31`).
    void input() { dirty_ = true; }

    /// Whether the application asked for another frame in the last one.
    void requested(bool again) { requested_ = again; }

    /// A close the application did not veto, or a quit (`RES16`).
    void close() { closing_ = true; }

    /// Memory is short (`RES17`).
    void memoryPressure(bool critical)
    {
        pressure_ = true;
        criticalPressure_ |= critical;
    }

    /**
    The application chose a cell font size, in pixels at the current scale
    (`HST14`). Kept across every later scale change (`RES55`). Returns the
    size to measure at now.
    */
    int fontSize(int px)
    {
        userChoseSize_ = dirty_ = true;
        userBase_ = baseOf(px, scale_);
        measuredPx_ = pxFor(scale_);
        return measuredPx_;
    }

    // ── what to do ──

    /// The next plan, at time `now`. `wakeAsk` is the application's timed
    /// wake (`HST16`), `Duration.max` for none.
    Plan step(Duration now, Duration wakeAsk = Duration.max)
    {
        Plan p;
        trimLosses(now);
        if (closing_ || failure_ != Failure.none || state_ == HostPhase.stopping)
            return stopPlan(p);

        if (havePending_)
            applyMetrics(p);

        if (pressure_)
        {
            pressure_ = false;
            p.deliverPressure = true;
            p.releaseCaches = deviceUp_;
            if (criticalPressure_ && releaseDeviceUnderPressure && deviceUp_
                && state_ != HostPhase.visible)
            {
                p.releaseDevice = true;
                deviceUp_ = false;
                needDevice_ = true;
            }
            criticalPressure_ = false;
        }
        if (cachesToRelease_)
        {
            cachesToRelease_ = false;
            p.releaseCaches = deviceUp_;
        }

        // Nothing is built for a surface that does not exist or cannot be
        // seen; the rebuild waits until it can (`RES11`, `RES12`).
        if (state_ == HostPhase.suspended || state_ == HostPhase.starting)
            return parked(p, wakeAsk);
        if (occluded_ && state_ == HostPhase.visible)
            state_ = HostPhase.hidden;
        else if (!occluded_ && state_ == HostPhase.hidden)
        {
            state_ = HostPhase.visible;
            dirty_ = true;
        }
        if (state_ == HostPhase.hidden)
            return parked(p, wakeAsk);

        if (needDevice_)
        {
            p.createDevice = true; // with a surface and its targets
            needDevice_ = needSurface_ = needTargets_ = false;
            mustDraw_ = dirty_ = true;
        }
        if (needSurface_)
        {
            p.createSurface = p.rebuildTargets = true;
            needSurface_ = needTargets_ = false;
            mustDraw_ = dirty_ = true;
        }
        if (needTargets_)
        {
            p.rebuildTargets = true;
            needTargets_ = false;
            dirty_ = true;
        }
        if (state_ == HostPhase.recovering)
            state_ = HostPhase.visible;

        // A frame waits for its opportunity on a paced window (`RES32`); an
        // opportunity missed while busy is not queued.
        if ((dirty_ || requested_ || mustDraw_) && (frameReady_ || !paced))
        {
            p.draw = true;
            p.mustDraw = mustDraw_;
            p.park = Duration.zero;
            dirty_ = false;
            return p;
        }
        p.askFrame = dirty_ || requested_ || mustDraw_;
        p.park = wakeAsk;
        return p;
    }

    /// How the frame the last plan asked for went, at time `now`.
    void frameDone(FrameResult r, Duration now)
    {
        final switch (r)
        {
            case FrameResult.presented:
                if (presentedOnce_)
                {
                    auto gap = now - lastPresent_;
                    if (gap > maxFrameInterval)
                        gap = maxFrameInterval;
                    frameSeconds_ = gap.total!"usecs" / 1e6f;
                }
                presentedOnce_ = true;
                lastPresent_ = now;
                // `requested_` is the ask made while building this frame: it
                // stands for the next one (`HST9`).
                frameReady_ = mustDraw_ = false;
                recoveries_ = 0;
                break;
            case FrameResult.again:
                dirty_ = true;
                break;
            case FrameResult.outOfDate:
                needTargets_ = dirty_ = true;
                break;
            case FrameResult.surfaceLost:
                // The surface scope ends; a new surface comes from the
                // window's handles, or the window is suspended (`RES22`).
                state_ = HostPhase.recovering;
                needSurface_ = mustDraw_ = dirty_ = true;
                break;
            case FrameResult.deviceLost:
                state_ = HostPhase.recovering;
                deviceUp_ = false;
                needDevice_ = mustDraw_ = dirty_ = true;
                losses_[lossCount_++] = now;
                if (lossCount_ > maxLosses)
                    failure_ = Failure.lossStorm;
                break;
            case FrameResult.outOfMemory:
                cachesToRelease_ = dirty_ = true;
                break;
            case FrameResult.failed:
                failure_ = Failure.frame;
                break;
        }
    }

    /// A rebuild the plan asked for succeeded.
    void rebuilt(Rebuild what)
    {
        if (what == Rebuild.device)
            deviceUp_ = true;
    }

    /**
    A rebuild the plan asked for failed. Targets that cannot be built
    escalate to a new surface, a surface to a new device. `hasHandles`
    false means the window has no native surface to build one on: that is
    suspension, not failure (`RES22`). The host gives up after
    `maxRecoveries` failures in a row (`RES27`).
    */
    void rebuildFailed(Rebuild what, bool hasHandles = true)
    {
        if (what != Rebuild.device && !hasHandles)
        {
            state_ = HostPhase.suspended;
            surface_ = Surface(0, 0, surface_.scale);
            needSurface_ = true;
            needTargets_ = false;
            return;
        }
        if (++recoveries_ >= maxRecoveries)
        {
            failure_ = Failure.recoveryExhausted;
            return;
        }
        state_ = HostPhase.recovering;
        mustDraw_ = dirty_ = true;
        final switch (what)
        {
            case Rebuild.targets:
                needSurface_ = true;
                break;
            case Rebuild.surface:
            case Rebuild.device:
                deviceUp_ = false;
                needDevice_ = true;
                break;
        }
    }

    private:

    Plan stopPlan(ref Plan p)
    {
        state_ = HostPhase.stopping;
        p.stop = true;
        p.failure = failure_;
        p.park = Duration.zero;
        return p;
    }

    Plan parked(ref Plan p, Duration wakeAsk)
    {
        p.park = state_ == HostPhase.hidden && hiddenPeriod < wakeAsk ? hiddenPeriod : wakeAsk;
        return p;
    }

    void applyMetrics(ref Plan p)
    {
        havePending_ = false;
        const s = pending_;
        if (s.suspended)
        {
            // The old surface's objects go before the loss is acknowledged
            // (`RES12`), the native surface with them.
            if (state_ != HostPhase.suspended && state_ != HostPhase.starting && deviceUp_)
            {
                p.releaseSurface = true;
                needSurface_ = true;
            }
            surface_ = s;
            if (state_ != HostPhase.starting)
                state_ = HostPhase.suspended;
            needTargets_ = false;
            return;
        }
        if (state_ == HostPhase.suspended || state_ == HostPhase.starting)
        {
            state_ = HostPhase.visible;
            mustDraw_ = true;
        }
        surface_ = s;
        if (deviceUp_ && !needSurface_)
            needTargets_ = true;
        dirty_ = true;
    }

    int pxFor(double scale) const
    {
        return sizeAt(userChoseSize_ ? userBase_ : base, scale);
    }

    void trimLosses(Duration now)
    {
        if (failure_ != Failure.none)
            return;
        while (lossCount_ > 0 && now - losses_[0] > lossWindow)
        {
            foreach (i; 1 .. lossCount_)
                losses_[i - 1] = losses_[i];
            --lossCount_;
        }
    }
}

/// The default size rule: `base` pixels at scale 1, scaled and rounded.
int scaledPx(double base, double scale) @safe pure nothrow @nogc
{
    const px = base * (scale > 0 ? scale : 1) + 0.5;
    return px < 1 ? 1 : cast(int) px;
}

/// ditto, inverted
double unscaledPx(int px, double scale) @safe pure nothrow @nogc
    => px / (scale > 0 ? scale : 1);
