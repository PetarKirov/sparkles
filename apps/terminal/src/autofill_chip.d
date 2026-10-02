/**
The Autofill chip (docs/specs/terminal/selection.md `TSE10`, mockup A1): a
band above the extra keys offering "Autofill password" while the focused
pane's program reads a password — its pty has echo off and canonical input
on (`sudo`, `ssh`, `gpg`) — and the soft keyboard is up. It goes when echo
returns.

The probe (`process_info.ptyReading`, one `tcgetattr` on the master) runs at
most once a frame and only while the keyboard shows. The chip takes its
band from the panes, so it never covers the prompt it is about.
*/
module autofill_chip;

import sparkles.terminal_view.process_info : PtyReading;

import chrome : ChromeTheme, Layer;
import settings : ButtonLabels;

/// Whether the chip shows (`TSE10`): a password read, the keyboard up, and
/// an autofill service to ask.
bool chipShown(PtyReading reading, bool keyboardShown, bool autofillAvailable)
    @safe pure nothrow @nogc
    => reading == PtyReading.password && keyboardShown && autofillAvailable;

///
@("autofill_chip.chipShown.onlyAtAPasswordPrompt")
@safe pure nothrow @nogc unittest
{
    assert(chipShown(PtyReading.password, true, true));
    assert(!chipShown(PtyReading.echoing, true, true), "echo is on: a plain read");
    assert(!chipShown(PtyReading.raw, true, true), "a shell's line editor");
    assert(!chipShown(PtyReading.password, false, true), "no keyboard, no chip");
    assert(!chipShown(PtyReading.password, true, false), "no service to ask");
}

/// The chip's hit id.
enum size_t chipHit = 0xA1F1;

/// The chip's tree: the button and a line saying why it is there (A1).
auto chipTree(ButtonLabels labels, int targetRows, int cols = 80) @safe
{
    import sparkles.ui.geometry : Insets, SizeSpec;
    import sparkles.ui.style : Slot;
    import sparkles.ui.widget : Alignment, Builder, Widget, WidgetKind;

    import chrome : button, label;

    Builder b;
    const btn = button(b, "⚿", "Autofill password", labels, chipHit, primary: true,
        minRows: targetRows);
    // The reason, as much of it as the band has room for beside the button.
    const why = label(b, cols >= 64 ? "echo is off — a password is being read" : "echo is off",
        Slot.muted);
    return b.finish(b.add(Widget(
        kind: WidgetKind.panel,
        children: [b.add(Widget(kind: WidgetKind.row, children: [btn, why], gap: 2,
            alignY: Alignment.center))],
        padding: Insets(0, 1, 0, 1),
        width: SizeSpec.grow(),
        height: SizeSpec.fixed(targetRows),
        alignY: Alignment.center,
        slot: Slot.surface,
        paintBackground: true,
        decoration: Decoration(borderWidth: Insets(1, 0, 0, 0)),
    )));
}

private import sparkles.ui.style : Decoration;

///
@("autofill_chip.chipTree.aButtonAndWhy")
@safe unittest
{
    import chrome : place, Place;

    const l = place(chipTree(ButtonLabels.iconText, 3), 40, 3, 0, 0, 1, 1, Place.top);
    assert(l.bounds.height == 3, "a 48 dp band");
    bool why;
    foreach (ref n; l.tree.nodes)
        why |= n.text == "echo is off — a password is being read";
    assert(why && l.hits.length == 1 && l.hits[0].hitId == chipHit);
}

version (Android):

import sparkles.terminal_view.component : TerminalView;
import sparkles.ui.geometry : Rect;

/// The chip's state, per frame.
struct AutofillChip
{
    /// Whether it shows this frame.
    bool shown;
    private Layer layer;

    /**
    Probes `tv`'s pty — only while the keyboard shows — and decides whether
    the chip shows; true when that changed (the panes resize).
    */
    bool frame(TerminalView* tv) @system
    {
        import sparkles.android.autofill : autofillAvailable, autofillPending,
            cancelPasswordAutofill;
        import sparkles.terminal_view.process_info : ptyReading;

        const keyboard = softKeyboardShown();
        const reading = tv !is null && keyboard ? ptyReading(tv.s.pty_fd) : PtyReading.unknown;
        // The program stopped reading a password (or went away) with a request
        // still open: it is cancelled, and nothing is sent (`TSE8`).
        if (autofillPending && (tv is null || (keyboard && reading != PtyReading.password)))
            cancelPasswordAutofill();
        // While a request is open the field is the service's: the chip waits.
        // The service is asked (a main-thread round trip) only at a password read.
        const now = !autofillPending && chipShown(reading, keyboard,
            reading == PtyReading.password && autofillAvailable());
        const changed = now != shown;
        shown = now;
        return changed;
    }

    /// The band's height in pixels: `targetRows` rows of `cellH`, or 0.
    int height(int cellH, int targetRows) const @safe pure nothrow @nogc
        => shown ? cellH * (targetRows > 1 ? targetRows : 1) : 0;

    /// Lays the chip out in the band at pixel `band`.
    void place(ButtonLabels labels, int targetRows, in Rect band, int cw, int ch) @safe
    {
        import chrome : place_ = place, Place;

        layer = shown ? place_(chipTree(labels, targetRows, band.width / cw), band.width / cw, band.height / ch,
            band.x, band.y, cw, ch, Place.top) : Layer.init;
    }

    /// Paints it.
    void paint(H)(ref H h, in ChromeTheme theme) @system
    {
        import chrome : paintLayer;

        paintLayer(h, layer, theme);
    }

    /// A tap at (`x`, `y`): on the button it asks for a password (`TSE8`);
    /// true when the band took it.
    bool tap(int x, int y) @system
    {
        import sparkles.android.autofill : requestPasswordAutofill;
        import sparkles.base.logger : info;

        if (!shown || !layer.contains(x, y))
            return false;
        if (layer.hitAt(x, y) == chipHit)
        {
            const ok = requestPasswordAutofill();
            info(i"terminal: autofill chip: requested $(ok)");
        }
        return true;
    }
}

/// Whether the soft keyboard is up: the content rect shrank by more than a
/// system bar (native code is not told).
bool softKeyboardShown() @system nothrow @nogc
{
    import raylib : GetScreenHeight;
    import sparkles.android.activity : contentRect;

    const r = contentRect();
    const screen = GetScreenHeight();
    return r.bottom > r.top && screen - r.bottom > screen / 6;
}
