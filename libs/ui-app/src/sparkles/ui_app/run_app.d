/**
The component entry point: one call, every backend (`HST10`–`HST12`).

$(REF run, sparkles,ui_app,run) is the loop for an application that builds its
own display list. This module is the level above it — the $(B widget) level of
the host's three (`UIA2`): an application is a value with a `view` and a
`handle`, and $(LREF runApp) does everything else. Picking the backend, opening
it, laying the tree out against the live surface, resolving the theme, painting
the page — none of it appears in the application.

---
struct Hello
{
    WidgetTree view(H)(ref H host) { ... }             // state → widgets
    void handle(H)(ref H host, in Event e) { ... }     // event → state
}

void main(string[] args)
{
    Hello app;
    RunConfig cfg = { title: "hello" };
    // parse `cfg.gui` from args (`GuiCliFields`), then:
    runApp(app, cfg);
}
---

`view` and `handle` are member $(B templates), for the same reason `run`'s
callbacks are `alias` parameters: each backend hands a different host type, and
a component is written once. A component that needs only one target may write
plain members against it — the concept ($(LREF isAppFor)) is per-host.

$(B `view` keeps the whole host contract.) It may decline the frame
(`skipFrame`, honoured before any layout happens), ask for another
(`requestFrame`), set the pointer shape, or quit — `view` is the frame, not a
pure projection. What this level adds is only that the $(I output) is a tree
rather than a display list.
*/
module sparkles.ui_app.run_app;

import sparkles.base.term_color : Color, RgbColor;
import sparkles.input : Event;
import sparkles.ui.canvas : DrawOp, OpKind;
import sparkles.ui.display_list : buildDisplayListInto;
import sparkles.ui.geometry : Constraints, Rect;
import sparkles.ui.layout : Frame, layout;
import sparkles.ui.style : Palette, Visual;
import sparkles.ui.theme : Theme;
import sparkles.ui.widget : WidgetTree;
import sparkles.ui_app.backend : BackendPolicy;
import sparkles.ui_app.gui_options : GuiOptions, resolveTheme;
import sparkles.ui_app.host : RunConfig;
import sparkles.ui_app.record : RecordingHost, runRecorded;
import sparkles.ui_app.run : run, RunOutcome;

/**
The application-component concept: `true` iff `A` can be run against `Host` —
a `view` producing a $(REF WidgetTree, sparkles,ui,widget) and a `handle`
receiving events, both taking the host by `ref`.

Attributes are deliberately unconstrained, like $(REF isHost, sparkles,ui_app,host):
they infer per concrete host.
*/
enum bool isAppFor(A, Host) = __traits(compiles, (ref A a, ref Host h) {
    WidgetTree tree = a.view(h);
    a.handle(h, Event.init);
});

/**
A theme, resolved to what one frame needs: the slot palette and the page colors.

Resolved once per run from `--theme` by $(LREF appThemeOf). A component that
needs to $(I change) it declares a `theme` member and $(LREF frameTheme) prefers
that — see below; the run's value is then the fallback rather than the answer.
*/
struct AppTheme
{
    Palette palette; /// the slot channel every widget resolves against
    RgbColor pageFg; /// unlabeled-text foreground
    RgbColor pageBg; /// the page fill behind everything
}

/**
The theme this frame paints in: the component's own when it has one, else the
run's.

$(B A theme resolved once per run cannot be swapped.) That is fine for an
application whose theme is a startup flag and wrong for two real cases: a theme
$(I browser), where choosing one has to repaint the whole window rather than a
preview pane, and a viewer painting its preview in the theme being edited while
its own chrome stays in the UI theme. Both need the value per frame, and neither
can get it by mutating `RunConfig` — the arms take it `in`.

So it is a member a component $(I may) declare, probed the way
$(REF isCanvas, sparkles,ui,canvas) probes for `pushClip` and `rule`: a
component without one pays nothing and reads exactly as before.
*/
AppTheme frameTheme(A)(ref A app, in AppTheme fallback)
{
    static if (__traits(compiles, { AppTheme t = app.theme; }))
        return app.theme;
    else
        return fallback;
}

/// A `Color` that may be unset, as a concrete `RgbColor`. (The twin of
/// `sparkles.ui.theme`'s private helper — an indexed or default color falls
/// back rather than guessing a terminal's palette.)
private RgbColor toRgbOr(in Color c, RgbColor fallback) @safe pure nothrow @nogc
    => c.kind == Color.Kind.rgb ? c.rgb : fallback;

/**
Resolves the options' `--theme` into an $(LREF AppTheme).

An unknown name falls back to `Theme.init` — a derived palette on a black page.
The CLI layer should have rejected the name before a run gets here
($(REF resolveTheme, sparkles,ui_app,gui_options) is how it checks); the
fallback exists so a run never dereferences null.
*/
AppTheme appThemeOf(O)(const O o)
{
    static immutable Theme fallbackTheme;

    immutable(Theme)* t = resolveTheme(o);
    if (t is null)
        t = &fallbackTheme;

    return AppTheme(
        palette: t.effectivePalette,
        pageFg: toRgbOr(t.defaultFg, RgbColor(0xd0, 0xd0, 0xd0)),
        pageBg: toRgbOr(t.defaultBg, RgbColor(0, 0, 0)),
    );
}

/**
Whether `A` carries the optional `paint` member — the component's own renderer,
run in the draw phase (`HST13`): inside the frame bracket, after the display
list painted, as `paint(ref host, in WidgetTree, in Frame[])`. The tree and
frames are the ones this same frame's `view`/layout produced, so the component
finds its pane with $(REF keyedRects, sparkles,ui,state) and paints into the
laid-out rect through the host's canvas.
*/
enum bool hasPaintPhase(A) = __traits(hasMember, A, "paint");

/// What one frame's `view` + layout produced — kept for the draw phase, which
/// runs later in the same frame (never across frames).
struct FrameSnapshot
{
    WidgetTree tree; ///
    Frame[] frames;  ///
}

/**
Builds one frame of `app` into `h`'s display list: page fill, `view`, layout
against the live surface, display list (`NFR2` — straight into the host's
reused buffer). The tree and frames land in `snap` for the draw phase.

The frame an application declines is honoured $(B before) layout: a `view` that
calls `skipFrame` pays for its own early-out and nothing else.
*/
void presentApp(A, Host)(ref A app, ref Host h, in AppTheme th, ref FrameSnapshot snap)
{
    snap = FrameSnapshot.init;
    snap.tree = app.view(h);
    if (h.frameSkipped)
        return;

    // Asked AFTER `view`: a component that changes theme in response to a key
    // has already handled it, and asking first would paint this frame in the
    // theme it just left.
    const frame = frameTheme(app, th);

    // The page first, so the theme's background shows wherever the tree does
    // not cover — the backend-neutral answer to the arms' black clear.
    const sz = h.size;
    h.ops() ~= DrawOp(kind: OpKind.fillRect,
        rect: Rect(0, 0, sz.width, sz.height),
        visual: Visual(fg: frame.pageFg, bg: frame.pageBg, hasBg: true));

    // An empty tree is a bare page, not a crash — layout indexes its root.
    if (snap.tree.nodes.length == 0)
        return;

    snap.frames = layout(snap.tree, Constraints(sz.width, sz.height));
    buildDisplayListInto(snap.tree, snap.frames, frame.palette, frame.pageFg,
        frame.pageBg, h.ops());
}

/**
The backend decision's inputs, probed from the live process: the CLI's
`--gui`/`--no-gui`/`--tui` become the force flags, the standard streams are
asked whether they are terminals, and the display is probed.

Separate from $(REF pickBackend, sparkles,ui_app,backend) on purpose — the
decision stays a pure function; this is the one place the environment is read.
*/
BackendPolicy probedPolicy(in GuiOptions o) @safe
{
    import sparkles.base.term_caps : isTerminal, StdStream;
    import sparkles.ui_app.display : displayAvailable;

    return BackendPolicy(
        forceGui: o.gui,
        forceNoGui: o.noGui,
        forceTui: o.tui,
        stdinTty: isTerminal(StdStream.stdin),
        stdoutTty: isTerminal(StdStream.stdout),
        displayPresent: displayAvailable(),
    );
}

/**
Runs a component: picks a backend under `policy`, opens it, and drives
`app.view`/`app.handle` until the application quits.

The two-argument form probes `policy` from the live environment
($(LREF probedPolicy)) — the whole `main` of a widget-level application is
parsing `cfg.gui` and calling this.
*/
RunOutcome runApp(A)(ref A app, in RunConfig cfg, BackendPolicy policy)
{
    const th = appThemeOf(cfg.gui);
    FrameSnapshot snap;
    static if (hasPaintPhase!A)
        return run!(
            (ref h) { presentApp(app, h, th, snap); },
            (ref h, in Event e) { app.handle(h, e); },
            (ref h) { app.paint(h, snap.tree, snap.frames); },
        )(cfg, policy);
    else
        return run!(
            (ref h) { presentApp(app, h, th, snap); },
            (ref h, in Event e) { app.handle(h, e); },
        )(cfg, policy);
}

/// ditto
RunOutcome runApp(A)(ref A app, in RunConfig cfg)
    => runApp(app, cfg, probedPolicy(cfg.gui));

/**
Runs a component headlessly over a scripted event list (`TST1`) — the
component-level face of $(REF runRecorded, sparkles,ui_app,record), with the
same theme and frame pipeline a live run gets.

One frame before any input, one per event, stopping on quit; the returned
recorder holds each frame's display list and everything the component asked of
the platform.
*/
RecordingHost runAppRecorded(A)(ref A app, in RunConfig cfg, in Event[] script,
    scope void delegate(ref RecordingHost) @safe setup = null)
{
    const th = appThemeOf(cfg.gui);
    FrameSnapshot snap;
    return runRecorded(cfg,
        (ref RecordingHost h) {
            presentApp(app, h, th, snap);
            // The recorder has no frame bracket, so the draw phase (`HST13`)
            // runs right here — same frame, same skip rule as the live arms.
            static if (hasPaintPhase!A)
                if (!h.frameSkipped)
                    app.paint(h, snap.tree, snap.frames);
        },
        (ref RecordingHost h, in Event e) { app.handle(h, e); },
        script, setup);
}

// ---------------------------------------------------------------------------
// Tests — a component, run against the recorder; the live arms type-checked.
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.input : charEvent, isDismiss, Key, KeyEvent, keyEvent, match;
    import sparkles.ui.style : Slot;
    import sparkles.ui.widget : Builder, Widget, WidgetKind;

    // One component, generic over the host — the same source serves the
    // recorder here and both live arms in the instantiation test below.
    private struct CounterApp
    {
        int events;

        WidgetTree view(H)(ref H h)
        {
            auto b = Builder();
            const label = b.add(Widget(kind: WidgetKind.text,
                text: "events seen", slot: Slot.code));
            return b.finish(b.container(WidgetKind.column, [label]));
        }

        void handle(H)(ref H h, in Event e)
        {
            ++events;
            e.match!(
                (in KeyEvent k) { if (isDismiss(k)) h.quit(); },
                (in _) {},
            );
        }
    }

    static assert(isAppFor!(CounterApp, RecordingHost),
        "the test component must satisfy the concept it exists to exercise");
}

@("ui_app.run_app.firstFramePaintsThePage")
@safe
unittest
{
    CounterApp app;
    auto rec = runAppRecorded(app, RunConfig.init, []);

    // One frame before any input, and the page fill leads it: full surface,
    // background on.
    assert(rec.frames.length == 1);
    const ops = rec.frames[0].ops;
    assert(ops.length >= 2, "the page fill, then the tree");
    assert(ops[0].kind == OpKind.fillRect);
    assert(ops[0].rect == Rect(0, 0, 80, 24), "the recorder's surface");
    assert(ops[0].visual.hasBg);

    // The default theme (tokyo-night) pins its page colors, so the fill is
    // not the fallback black.
    assert(ops[0].visual.bg != RgbColor(0, 0, 0));
}

@("ui_app.run_app.skipFrameIsHonouredBeforeLayout")
@safe
unittest
{
    // `view` declines every frame; nothing may be painted — not even the page.
    static struct Skipper
    {
        WidgetTree view(H)(ref H h)
        {
            h.skipFrame();
            return WidgetTree.init;
        }

        void handle(H)(ref H h, in Event e) {}
    }

    Skipper app;
    auto rec = runAppRecorded(app, RunConfig.init, [keyEvent(Key.up)]);

    assert(rec.frames.length == 2);
    foreach (ref f; rec.frames)
    {
        assert(f.skipped);
        assert(f.ops.length == 0, "a declined frame paints nothing");
    }
    assert(rec.drawnFrames == 0);
}

@("ui_app.run_app.quitEndsTheRun")
@safe
unittest
{
    CounterApp app;
    auto rec = runAppRecorded(app, RunConfig.init, [
        keyEvent(Key.up),
        keyEvent(Key.escape), // dismiss: the component quits
        keyEvent(Key.down),   // never delivered
    ]);

    assert(app.events == 2, "the run ends at quit, not at the script's end");
    // First frame + one per delivered event.
    assert(rec.frames.length == 3);
}

@("ui_app.run_app.emptyTreeIsABarePage")
@safe
unittest
{
    static struct Blank
    {
        WidgetTree view(H)(ref H h) => WidgetTree.init;
        void handle(H)(ref H h, in Event e) {}
    }

    Blank app;
    auto rec = runAppRecorded(app, RunConfig.init, []);

    assert(rec.frames.length == 1);
    assert(rec.frames[0].ops.length == 1, "just the page fill");
    assert(rec.frames[0].ops[0].kind == OpKind.fillRect);
}

@("ui_app.run_app.unknownThemeFallsBack")
@safe
unittest
{
    GuiOptions o;
    o.theme = "no-such-theme";
    const th = appThemeOf(o);

    // `Theme.init` derives its palette and pins nothing, so the fallbacks show.
    assert(th.pageBg == RgbColor(0, 0, 0));
    assert(th.pageFg == RgbColor(0xd0, 0xd0, 0xd0));
}

@("ui_app.run_app.paintPhaseSeesTheLaidOutPane")
@safe
unittest
{
    import sparkles.ui.geometry : SizeSpec;
    import sparkles.ui.state : keyedRects;

    // A component with a renderer of its own (`HST13`): the pane is a keyed
    // widget the layout sizes, and `paint` draws into the laid-out rect
    // through the host's canvas — the terminal-view shape (`TVW2`/`TVW3`).
    static struct PaneApp
    {
        enum size_t paneKey = 42;
        Rect seenRect;

        WidgetTree view(H)(ref H h)
        {
            import sparkles.ui.style : Slot;
            import sparkles.ui.widget : Builder, Widget, WidgetKind;

            auto b = Builder();
            const label = b.add(Widget(kind: WidgetKind.text, text: "header",
                slot: Slot.code));
            const pane = b.add(Widget(kind: WidgetKind.box, key: paneKey,
                width: SizeSpec.fixed(10), height: SizeSpec.fixed(5)));
            return b.finish(b.container(WidgetKind.column, [label, pane]));
        }

        void handle(H)(ref H h, in Event e) {}

        void paint(H)(ref H h, in WidgetTree tree, in Frame[] frames)
        {
            foreach (kr; keyedRects(tree, frames))
                if (kr.key == paneKey)
                {
                    seenRect = kr.rect;
                    // Paint into the laid-out rect through the canvas — on the
                    // recorder this is captured, on the GPU arm it is pixels.
                    h.canvas.fillRect(kr.rect,
                        Visual(bg: RgbColor(1, 2, 3), hasBg: true));
                }
        }
    }

    static assert(hasPaintPhase!PaneApp);

    PaneApp app;
    auto rec = runAppRecorded(app, RunConfig.init, []);

    // The pane sits below the one-line header, at the layout's say-so.
    assert(app.seenRect == Rect(0, 1, 10, 5));

    // The draw phase painted through the canvas, not the display list: the
    // frame's ops carry the page + tree, the canvas carries the pane fill.
    assert(rec.canvas.ops.length == 1);
    assert(rec.canvas.ops[0].rect == Rect(0, 1, 10, 5));
    assert(rec.canvas.ops[0].visual.bg == RgbColor(1, 2, 3));
}

@("ui_app.run_app.paintPhaseSkipsWithTheFrame")
@safe
unittest
{
    // A skipped frame skips the draw phase too — the arms skip the whole
    // bracket, and the recorder must agree (`HST6` × `HST13`).
    static struct SkippingPainter
    {
        int paints;

        WidgetTree view(H)(ref H h)
        {
            h.skipFrame();
            return WidgetTree.init;
        }

        void handle(H)(ref H h, in Event e) {}
        void paint(H)(ref H h, in WidgetTree, in Frame[]) { ++paints; }
    }

    SkippingPainter app;
    cast(void) runAppRecorded(app, RunConfig.init, [keyEvent(Key.up)]);
    assert(app.paints == 0, "no frame, no draw phase");
}

// `runApp` dispatches through `run`, whose `final switch` compiles every arm —
// so this one static assert type-checks the generic component against BOTH
// live host types, which is what makes "written once, runs on either" a
// checked property rather than an aspiration.
@("ui_app.run_app.instantiates")
@system
unittest
{
    static assert(__traits(compiles, {
        CounterApp app;
        RunConfig cfg;
        BackendPolicy policy;
        cast(void) runApp(app, cfg, policy);
        cast(void) runApp(app, cfg);
    }), "runApp must compile against every arm this build carries");

    // A PAINTING component too: `paint` goes through `host.canvas`, which
    // both live hosts expose (RaylibCanvas / GridCanvas) precisely so a
    // draw-phase component does not need a per-target branch.
    static struct PaintingApp
    {
        WidgetTree view(H)(ref H h) => WidgetTree.init;
        void handle(H)(ref H h, in Event e) {}

        void paint(H)(ref H h, in WidgetTree, in Frame[] frames)
        {
            import sparkles.base.term_color : RgbColor;
            import sparkles.ui.geometry : Rect;
            import sparkles.ui.style : Visual;

            auto c = h.canvas;
            c.fillRect(Rect(0, 0, 1, 1), Visual(bg: RgbColor(0, 0, 0), hasBg: true));
        }
    }

    static assert(__traits(compiles, {
        PaintingApp app;
        RunConfig cfg;
        BackendPolicy policy;
        cast(void) runApp(app, cfg, policy);
    }), "a draw-phase component must compile against every arm too");
}

@("ui_app.run_app.aComponentMaySupplyTheFramesTheme")
@safe unittest
{
    import sparkles.ui.style : defaultTwoslashPalette, ColorScheme;

    // The case a once-per-run theme cannot serve: a browser where choosing a
    // theme repaints the whole application, not a preview pane. The component
    // declares `theme`, and the page fill — op 0 of every frame — follows it.
    static struct Themed
    {
        AppTheme theme;

        WidgetTree view(H)(ref H h)
        {
            auto b = Builder();
            return b.finish(b.add(Widget(kind: WidgetKind.text, text: "x")));
        }

        void handle(H)(ref H h, in Event e)
        {
            // Any key flips the theme, so the very next frame paints in it.
            theme = AppTheme(palette: defaultTwoslashPalette(ColorScheme.light),
                pageFg: RgbColor(0, 0, 0), pageBg: RgbColor(255, 255, 255));
        }
    }

    auto app = Themed(AppTheme(palette: defaultTwoslashPalette(ColorScheme.dark),
        pageFg: RgbColor(0xd0, 0xd0, 0xd0), pageBg: RgbColor(0, 0, 0)));
    auto rec = runAppRecorded(app, RunConfig.init, [charEvent('t')]);

    assert(rec.frames.length == 2);
    assert(rec.frames[0].ops[0].visual.bg == RgbColor(0, 0, 0));
    assert(rec.frames[1].ops[0].visual.bg == RgbColor(255, 255, 255),
        "the component's theme, not the run's");
}

@("ui_app.run_app.aComponentWithoutTheThemeMemberIsUnaffected")
@safe unittest
{
    // The probe costs nothing and changes nothing for everyone else: without
    // the member, the run's `--theme` value is what every frame paints in.
    static struct Plain
    {
        WidgetTree view(H)(ref H h)
        {
            auto b = Builder();
            return b.finish(b.add(Widget(kind: WidgetKind.text, text: "x")));
        }

        void handle(H)(ref H h, in Event e) {}
    }

    const configured = appThemeOf(GuiOptions.init);
    Plain app;
    assert(frameTheme(app, configured) == configured);

    auto rec = runAppRecorded(app, RunConfig.init, [charEvent('t')]);
    foreach (ref f; rec.frames)
        assert(f.ops[0].visual.bg == configured.pageBg);
}
