/**
The terminal as a desktop window: the workspace's tabs and splits filling
it, every key routed through the terminal's binding table first (`TKM1`–
`TKM5`), the key guide over the bottom.

The panes' own chords are off (`TerminalViewOptions.builtinChords`): copy,
paste and the font size are table rows here, so they appear in the key guide
and a user can rebind them. A key the table does not claim goes to the
focused pane's program unchanged.
*/
module desktop_terminal;

import core.time : Duration, msecs;

import sparkles.base.term_color : RgbColor;
import sparkles.input : Event, KeyEvent, match;
import sparkles.ui.geometry : Rect;
import sparkles.ui.layout : Frame;
import sparkles.ui.widget : WidgetTree;

import key_router : KeyRouter, paintGuide, Route;
import keymap : KeyCommand, TermCommand, TermContext;
import workspace_host : WorkspaceHost;

/// The whole-window desktop component.
struct DesktopTerminal
{
    WorkspaceHost host;
    KeyRouter keys;
    /// The chrome's colours: the terminal scheme's foreground and background
    /// (D17).
    RgbColor chromeFg = RgbColor(0xcd, 0xd6, 0xf4);
    /// ditto
    RgbColor chromeBg = RgbColor(0x1e, 0x1e, 0x2e);
    /// The divider and focus-mark colours.
    RgbColor divider = RgbColor(0x45, 0x47, 0x5a);
    /// ditto
    RgbColor accent = RgbColor(0x89, 0xb4, 0xfa);
    /// Where the workspace is saved (`TSS14`); empty: not saved.
    string statePath;

    private int defaultFontPx;
    private bool guideWasShown;

    @disable this(this);

    /// Every pane's GPU resources belong to this live host session; the
    /// workspace is saved before they go.
    void shutdown(H)(ref H h) @system
    {
        save();
        host.pool.closeAll();
    }

    /// Advances the guide's clock, then every pane's frame.
    WidgetTree view(H)(ref H h)
    {
        import raylib : GetScreenHeight, GetScreenWidth;

        if (defaultFontPx == 0)
            defaultFontPx = h.fontSizePx;
        keys.tick((cast(long)(h.frameSeconds * 1000)).msecs);
        const wait = keys.untilShown;
        if (wait != Duration.max)
            static if (__traits(compiles, h.wakeIn(wait)))
                h.wakeIn(wait);
        noteGuide();

        host.frame(h, Rect(0, 0, GetScreenWidth(), GetScreenHeight()));
        if (host.takeDirty())
            save();
        // The last pane closed: the window goes with it (`TSS5`).
        if (host.ws.empty)
            h.quit();
        return WidgetTree.init;
    }

    /// Keys through the table; a paste to the focused pane.
    void handle(H)(ref H h, in Event e)
    {
        import sparkles.input : EndOfInput, PasteEvent;

        e.match!(
            (in KeyEvent k) { onKey(h, k); },
            (in PasteEvent p) {
                if (auto tv = host.focusedView())
                    tv.onPaste(p);
            },
            (in EndOfInput _) { h.quit(); },
            (in _) {},
        );
    }

    /// The panes, then the guide over the window's bottom rows.
    void paint(H)(ref H h, in WidgetTree, in Frame[])
    {
        import raylib : GetScreenHeight, GetScreenWidth;

        host.paint(h, Rect(0, 0, GetScreenWidth(), GetScreenHeight()), divider, accent);
        paintGuide(h, keys, context, h.size.width, h.size.height, 0, 0, chromeFg, chromeBg);
    }

    private TermContext context() const => TermContext(promptOpen: host.promptOpen);

    private void onKey(H)(ref H h, in KeyEvent k)
    {
        const r = keys.route(k, context);
        final switch (r.route)
        {
            case Route.program:
                host.forward(h, k);
                break;
            case Route.consumed:
                break;
            case Route.execute:
                run(h, r.command);
                break;
        }
        noteGuide();
    }

    /// Runs one of the terminal's commands.
    private void run(H)(ref H h, KeyCommand c)
    {
        if (host.run(h, c, Rect(0, 0, h.size.width, h.size.height)))
            return;
        final switch (c.cmd)
        {
            case TermCommand.copy:
                if (auto tv = host.focusedView())
                    cast(void) tv.copy(h);
                break;
            case TermCommand.paste:
                if (auto tv = host.focusedView())
                    tv.pasteClipboard();
                break;
            case TermCommand.fontLarger:
                h.fontSize(h.fontSizePx + 2);
                break;
            case TermCommand.fontSmaller:
                if (h.fontSizePx > 6)
                    h.fontSize(h.fontSizePx - 2);
                break;
            case TermCommand.fontReset:
                if (defaultFontPx > 0)
                    h.fontSize(defaultFontPx);
                break;
            case TermCommand.none:
            case TermCommand.showGuide: // the guide consumes its own row
            case TermCommand.dismiss: // no overlay on the desktop yet
            case TermCommand.toggleExtraKeys: // no extra-keys row here
                break;
            // The workspace's own, answered above.
            case TermCommand.newTab, TermCommand.closeTab, TermCommand.nextTab,
                TermCommand.prevTab, TermCommand.goToTab, TermCommand.splitRight,
                TermCommand.splitDown, TermCommand.focusLeft, TermCommand.focusRight,
                TermCommand.focusUp, TermCommand.focusDown, TermCommand.zoomPane,
                TermCommand.closePane, TermCommand.promptRerun, TermCommand.promptShell,
                TermCommand.promptClose:
                break;
        }
    }

    /// The guide appearing or closing repaints the pane under it.
    private void noteGuide()
    {
        if (keys.lantern.shown != guideWasShown)
        {
            guideWasShown = keys.lantern.shown;
            if (auto tv = host.focusedView())
                tv.invalidate();
        }
    }

    /// Writes the workspace for the next start (`TSS14`); a failure is logged.
    private void save()
    {
        import std.file : mkdirRecurse;
        import std.path : dirName;

        import sparkles.base.logger : warning;
        import sparkles.wired.json : writeJSONFile;

        if (!statePath.length)
            return;
        // Everything closed: the next start begins afresh.
        if (host.ws.empty)
        {
            import std.file : exists, remove;

            try
                if (statePath.exists)
                    remove(statePath);
            catch (Exception e)
                warning(i"workspace: cannot remove $(statePath): $(e.msg)");
            return;
        }
        try
            mkdirRecurse(statePath.dirName);
        catch (Exception e)
        {
            warning(i"workspace: cannot create $(statePath.dirName): $(e.msg)");
            return;
        }
        auto r = writeJSONFile(host.snapshot, statePath);
        if (r.hasError)
            warning(i"workspace: not saved: $(r.error.toString)");
    }
}
