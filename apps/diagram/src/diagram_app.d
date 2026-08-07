/**
The diagram board component (`DIA3`, `DIA6`).

Everything the application $(I is) lives here as a `runApp` component —
`main` (in `app.d`, excluded from the test build) only parses the CLI and
calls $(REF runApp, sparkles,ui_app,run_app). That split is `DIA6` from the
first commit: every behavior is a scripted-event test against the recording
target, and `main` is the only untested line.

The scaffold (`D1.1`): a bare themed page that quits on `q` or the dismissal
chain. The world, the camera, and the systems land on top of this in the
delivery plan's order.
*/
module diagram_app;

import sparkles.input : EndOfInput, Event, isDismiss, Key, KeyAction, KeyEvent,
    match;
import sparkles.ui.widget : WidgetTree;

/// The application component: state → frames, events → state.
struct DiagramApp
{
    /// The scaffold presents the bare themed page; the board's op streams
    /// arrive with the render systems (`RND1`) and replay in the draw phase.
    WidgetTree view(H)(ref H h) => WidgetTree.init;

    /// `IXN6`'s tail: with nothing open to dismiss yet, Esc and `q` both end
    /// the run. The chain in front of them grows with the menu, the pending
    /// interaction, and the selection.
    void handle(H)(ref H h, in Event e)
    {
        e.match!(
            (in KeyEvent k) {
                if (k.action == KeyAction.release)
                    return;
                if ((k.key == Key.char_ && k.ch == 'q') || isDismiss(k))
                    h.quit();
            },
            (in EndOfInput _) { h.quit(); },
            (in _) {},
        );
    }
}

// ---------------------------------------------------------------------------
// Scripted-session tests (`TST1`): no window, no tty.
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.input : charEvent, keyEvent, Mods;
    import sparkles.ui_app.host : RunConfig;
    import sparkles.ui_app.run_app : isAppFor, runAppRecorded;
    import sparkles.ui_app.record : RecordingHost;

    static assert(isAppFor!(DiagramApp, RecordingHost));
}

@("diagram.app.quitsOnQ")
@safe
unittest
{
    DiagramApp app;
    auto rec = runAppRecorded(app, RunConfig(title: "diagram"), [
        charEvent('x'),  // ignored
        charEvent('q'),  // quits
        charEvent('x'),  // never delivered
    ]);

    // First frame + one per delivered event; the run ends at quit.
    assert(rec.frames.length == 3);
}

@("diagram.app.dismissChainTailQuits")
@safe
unittest
{
    // With nothing open, Esc is the chain's tail: quit (IXN6). A release
    // must not quit a second time — or at all.
    DiagramApp app;
    auto rec = runAppRecorded(app, RunConfig.init, [
        keyEvent(Key.escape, Mods(), KeyAction.release), // ignored
        keyEvent(Key.escape),
    ]);
    assert(rec.frames.length == 3);
}

@("diagram.app.presentsTheThemedPage")
@safe
unittest
{
    import sparkles.ui.canvas : OpKind;

    // The scaffold's whole frame is the theme's page fill (`RND5` starts
    // here: the default --theme reaches the board with no app code).
    DiagramApp app;
    auto rec = runAppRecorded(app, RunConfig.init, []);
    assert(rec.frames.length == 1);
    assert(rec.frames[0].ops.length == 1);
    assert(rec.frames[0].ops[0].kind == OpKind.fillRect);
}
