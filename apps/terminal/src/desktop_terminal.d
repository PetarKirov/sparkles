/**
The terminal as a desktop window: `TerminalView` as the whole surface, with
every key routed through the terminal's binding table first (`TKM1`–`TKM5`).

The pane's own chords are off (`TerminalViewOptions.builtinChords`): copy,
paste and the font size are table rows here, so they appear in the key guide
and a user can rebind them. A key the table does not claim goes to the
program unchanged.
*/
module desktop_terminal;

import core.time : Duration, msecs;

import sparkles.base.term_color : RgbColor;
import sparkles.input : Event, KeyEvent, match;
import sparkles.terminal_view.component : TerminalView;
import sparkles.ui.layout : Frame;
import sparkles.ui.widget : WidgetTree;

import key_router : KeyRouter, paintGuide, Route;
import keymap : KeyCommand, TermCommand, TermContext;

/// The whole-window desktop component.
struct DesktopTerminal
{
    TerminalView tv;
    KeyRouter keys;
    /// The chrome's colours: the terminal scheme's foreground and background
    /// (D17).
    RgbColor chromeFg = RgbColor(0xcd, 0xd6, 0xf4);
    /// ditto
    RgbColor chromeBg = RgbColor(0x1e, 0x1e, 0x2e);

    private int defaultFontPx;
    private bool guideWasShown;

    @disable this(this);

    /// The pane's GPU resources belong to this live host session.
    void shutdown(H)(ref H h) @system
    {
        tv.shutdown(h);
    }

    /// Advances the guide's clock, then the pane's frame.
    WidgetTree view(H)(ref H h)
    {
        if (defaultFontPx == 0)
            defaultFontPx = h.fontSizePx;
        keys.tick((cast(long)(h.frameSeconds * 1000)).msecs);
        const wait = keys.untilShown;
        if (wait != Duration.max)
            static if (__traits(compiles, h.wakeIn(wait)))
                h.wakeIn(wait);
        noteGuide();
        return tv.view(h);
    }

    /// Keys through the table; everything else to the pane.
    void handle(H)(ref H h, in Event e)
    {
        e.match!(
            (in KeyEvent k) { onKey(h, k); },
            (in _) { tv.handle(h, e); },
        );
    }

    /// The pane, then the guide over its bottom rows.
    void paint(H)(ref H h, in WidgetTree tree, in Frame[] frames)
    {
        tv.paint(h, tree, frames);
        paintGuide(h, keys, TermContext.init, h.size.width, h.size.height, 0, 0,
            chromeFg, chromeBg);
    }

    private void onKey(H)(ref H h, in KeyEvent k)
    {
        const r = keys.route(k, TermContext.init);
        final switch (r.route)
        {
            case Route.program:
                tv.handle(h, Event(k));
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
        final switch (c.cmd)
        {
            case TermCommand.none:
            case TermCommand.showGuide: // the guide consumes its own row
            case TermCommand.dismiss: // no overlay on the desktop yet
            case TermCommand.toggleExtraKeys: // no extra-keys row here
                break;
            case TermCommand.copy:
                cast(void) tv.copy(h);
                break;
            case TermCommand.paste:
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
        }
    }

    /// The guide appearing or closing repaints the pane under it.
    private void noteGuide()
    {
        if (keys.lantern.shown != guideWasShown)
        {
            guideWasShown = keys.lantern.shown;
            tv.invalidate();
        }
    }
}
