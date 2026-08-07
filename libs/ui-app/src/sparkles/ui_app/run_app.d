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
import sparkles.ui.layout : layout;
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

Computed once per run by $(LREF appThemeOf) — not per frame, and not by the
application.
*/
struct AppTheme
{
    Palette palette; /// the slot channel every widget resolves against
    RgbColor pageFg; /// unlabeled-text foreground
    RgbColor pageBg; /// the page fill behind everything
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
Builds one frame of `app` into `h`'s display list: page fill, `view`, layout
against the live surface, display list (`NFR2` — straight into the host's
reused buffer).

The frame an application declines is honoured $(B before) layout: a `view` that
calls `skipFrame` pays for its own early-out and nothing else.
*/
void presentApp(A, Host)(ref A app, ref Host h, in AppTheme th)
{
    auto tree = app.view(h);
    if (h.frameSkipped)
        return;

    // The page first, so the theme's background shows wherever the tree does
    // not cover — the backend-neutral answer to the arms' black clear.
    const sz = h.size;
    h.ops() ~= DrawOp(kind: OpKind.fillRect,
        rect: Rect(0, 0, sz.width, sz.height),
        visual: Visual(fg: th.pageFg, bg: th.pageBg, hasBg: true));

    // An empty tree is a bare page, not a crash — layout indexes its root.
    if (tree.nodes.length == 0)
        return;

    auto frames = layout(tree, Constraints(sz.width, sz.height));
    buildDisplayListInto(tree, frames, th.palette, th.pageFg, th.pageBg, h.ops());
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
    return run!(
        (ref h) { presentApp(app, h, th); },
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
    return runRecorded(cfg,
        (ref RecordingHost h) { presentApp(app, h, th); },
        (ref RecordingHost h, in Event e) { app.handle(h, e); },
        script, setup);
}

// ---------------------------------------------------------------------------
// Tests — a component, run against the recorder; the live arms type-checked.
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.input : isDismiss, Key, KeyEvent, keyEvent, match;
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
}
