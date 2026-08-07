/**
$(B Temporary.) A local stand-in for `sparkles.ui_app.run_app`, which is being
built in parallel on `feat/ui-app-run-app`.

The gallery is written against the component entry point — a struct with `view`
and `handle` member templates, run by $(LREF runApp) — rather than against
`run`'s raw `present`/`handle` closures, because that is the seam the toolkit is
growing and the gallery is meant to be its first real consumer. That module does
not exist on this branch yet, so it lives here, with the $(B same names and the
same signatures) it will have in the library.

$(B On rebase onto `feat/ui-app-run-app`: delete this file) and change the four
`import compat : …` lines in `app.d`, `gallery.d`, `state.d` and the page
modules to `import sparkles.ui_app.run_app : …`. Nothing else moves — that is
the point of keeping the spelling identical rather than inventing a local one.

The one addition beyond that plan is $(LREF frameTheme): a component $(I may)
declare a `theme`, and the `--theme`-resolved one is the fallback. A theme
browser cannot work without it — every slot on every page would resolve against
the startup theme forever — and it is the DbI shape the toolkit already uses for
`isCanvas`'s optional `pushClip`/`rule`. It is proposed for the library; see
`docs/specs/ui-gallery/open-issues.md` (`UGL-O1`).
*/
module compat;

import sparkles.base.term_caps : isTerminal, StdStream;
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
import sparkles.ui_app.display : displayAvailable;
import sparkles.ui_app.gui_options : GuiOptions, resolveTheme;
import sparkles.ui_app.host : RunConfig;
import sparkles.ui_app.record : runRecorded;
import sparkles.ui_app.run : run;

// Re-exported, so a consumer of the component entry point does not also have to
// know which module the outcome and the recording host come from. (In the
// library these live beside `runApp`; here they are one hop away.)
public import sparkles.ui_app.record : RecordedFrame, RecordingHost;
public import sparkles.ui_app.run : RunOutcome;

/**
The component concept: `true` iff `A` can be run against a host of type `Host`.

Mirrors `isHost`/`isCanvas` — attributes are deliberately unconstrained, since a
component driven by the recording host is `@safe` and one reaching the GPU host
is not. `view`/`handle` are written as member $(B templates) so one source serves
`RecordingHost`, `TuiHost` and `GuiHost`.
*/
enum bool isAppFor(A, Host) = __traits(compiles, (ref A a, ref Host h) {
    WidgetTree tree = a.view(h);
    a.handle(h, Event.init);
});

/// A theme resolved down to what a frame actually needs: the slot table and the
/// two page colors every unstyled run falls back to.
struct AppTheme
{
    Palette palette;  ///
    RgbColor pageFg;  ///
    RgbColor pageBg;  ///
}

/// A `Color` that may be unset, as a concrete one. `Theme`'s own twin of this is
/// private, which is why it is restated rather than reached for.
private RgbColor toRgbOr(in Color c, RgbColor fallback) @safe pure nothrow @nogc
    => c.kind == Color.Kind.rgb ? c.rgb : fallback;

/// The theme `o` names, resolved. A name no built-in carries falls back to the
/// default-constructed theme rather than failing the run — the application
/// reports the typo (see `app.d`), which is the layer that can print.
AppTheme appThemeOf(O)(const O o)
{
    static immutable Theme fallback;
    const t = resolveTheme(o);
    const theme = t is null ? fallback : *t;
    return AppTheme(
        palette: theme.effectivePalette,
        pageFg: theme.defaultFg.toRgbOr(RgbColor(0xcc, 0xcc, 0xcc)),
        pageBg: theme.defaultBg.toRgbOr(RgbColor(0, 0, 0)),
    );
}

/**
The theme this frame paints in.

A component that declares `theme` supplies its own — which is what makes a live
theme browser expressible, and what would let a viewer paint a preview pane in
the theme being edited while its chrome stays in the UI theme. One that does not
gets the `--theme`-resolved value, and pays nothing for the choice.
*/
AppTheme frameTheme(A)(ref A app, in AppTheme fallback)
{
    static if (__traits(compiles, { AppTheme t = app.theme; }))
        return app.theme;
    else
        return fallback;
}

/**
Builds one frame: the component's tree, laid out against the surface and
appended to the host's display list.

Appending rather than drawing is not an implementation detail — a backend's
frame is not open while this runs (the terminal diffs its grid afterwards, the
GPU target opens its frame afterwards), so a level that painted immediately
would paint into nothing on both.
*/
void presentApp(A, Host)(ref A app, ref Host h, in AppTheme configured)
{
    auto tree = app.view(h);
    // The view may decline the frame — `HST6`, which is what keeps idle CPU
    // near zero on a target that would otherwise repaint unconditionally.
    if (h.frameSkipped)
        return;

    const th = frameTheme(app, configured);
    const sz = h.size;

    // The page fill first, so a themed background exists on every target
    // without either arm's hardcoded black clear having to know about themes.
    h.ops() ~= DrawOp(
        kind: OpKind.fillRect,
        rect: Rect(0, 0, sz.width, sz.height),
        visual: Visual(fg: th.pageFg, bg: th.pageBg, hasBg: true),
    );

    if (tree.nodes.length == 0)
        return;

    buildDisplayListInto(tree, layout(tree, Constraints(sz.width, sz.height)),
        th.palette, th.pageFg, th.pageBg, h.ops());
}

/// The backend decision's inputs, probed from the environment plus `o`'s force
/// flags. `guiCompiledIn` is left to `run`, which overwrites it with the truth.
BackendPolicy probedPolicy(in GuiOptions o)
{
    BackendPolicy p;
    p.forceGui = o.gui;
    p.forceNoGui = o.noGui;
    p.forceTui = o.tui;
    p.stdinTty = isTerminal(StdStream.stdin);
    p.stdoutTty = isTerminal(StdStream.stdout);
    p.displayPresent = displayAvailable();
    return p;
}

/// Runs `app` on whichever backend `policy` resolves to.
RunOutcome runApp(A)(ref A app, in RunConfig cfg, BackendPolicy policy)
{
    const configured = appThemeOf(cfg.gui);
    return run!(
        (ref h) { presentApp(app, h, configured); },
        (ref h, in Event e) { app.handle(h, e); },
    )(cfg, policy);
}

/// ditto — probing the environment itself.
RunOutcome runApp(A)(ref A app, in RunConfig cfg)
    => runApp(app, cfg, probedPolicy(cfg.gui));

/// The headless twin: drives `app` through `script` on the recording host and
/// hands back what it asked for. Component apps get `TST`-style testability with
/// no tty and no window.
RecordingHost runAppRecorded(A)(ref A app, in RunConfig cfg, in Event[] script,
    scope void delegate(ref RecordingHost) @safe setup = null)
{
    const configured = appThemeOf(cfg.gui);
    return runRecorded(cfg,
        (ref RecordingHost h) { presentApp(app, h, configured); },
        (ref RecordingHost h, in Event e) { app.handle(h, e); },
        script, setup);
}
