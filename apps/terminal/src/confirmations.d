/**
The confirmations a pane's program can trigger, as surfaces
(`surfaces.Surface`):

$(LIST
    * $(LREF PasteConfirm) — the paste guard (`TPR19`, mockup P1): a paste
        with line breaks into a program without bracketed paste would run
        each line as typed, so it is shown first — the line count, the first
        lines — with Cancel, As one line and Paste. An anchored card at the
        cursor line, or a sheet.
    * $(LREF ClipboardRead) — an OSC 52 read under `ask` (`TPR21`, mockup
        P2): which program, in which tab and pane, asked — with Allow once,
        Always for this pane and Deny. The safe answer, also to Escape, Back
        and a tap outside, is Deny.
)

Each answers its pane through the pane's own API (`confirmPaste`,
`answerClipboardRead`), so a surface closed any way leaves the pane with an
answer.
*/
module confirmations;

import sparkles.input.events : KeyEvent;
import sparkles.terminal_view.component : TerminalView;
import sparkles.terminal_view.protocols : ClipboardReadAnswer;
import sparkles.ui.style : Slot;
import sparkles.ui.widget : Builder, Widget, WidgetKind, WidgetTree;
import sparkles.ui.wrap : TextWrap;

import chrome : band, button, label, row;
import surfaces : Placement, Surface, SurfaceContext;

/// Hit ids.
private enum Hit : size_t
{
    none,
    cancel = 0xC0F1,
    oneLine,
    paste,
    allowOnce,
    allowAlways,
    deny,
}

/// A paragraph that wraps to the room it is given.
private uint prose(ref Builder b, const(char)[] text, Slot slot = Slot.textSecondary) @safe
    => b.add(Widget(kind: WidgetKind.text, text: text, slot: slot, wrap: TextWrap.greedy));

/// The paste guard (`TPR19`).
final class PasteConfirm : Surface
{
    private TerminalView* pane;
    private size_t lines;
    private string text;

    /// `text` is the paste already stripped of controls (`TPR18`); `lines` its
    /// line count.
    this(TerminalView* pane, size_t lines, string text) @safe pure nothrow
    {
        this.pane = pane;
        this.lines = lines;
        this.text = text;
    }

    WidgetTree build(in SurfaceContext ctx, int cols) @safe
    {
        import std.algorithm.iteration : splitter;
        import std.conv : to;

        Builder b;
        uint[] body_;
        body_ ~= label(b, "⚠ Paste " ~ lines.to!string ~ " lines?", Slot.warn, bold: true);
        body_ ~= prose(b, "The program has not turned on bracketed paste, so each line runs as typed.");
        size_t shown;
        foreach (line; text.splitter('\n'))
        {
            if (shown++ == 4)
            {
                body_ ~= label(b, "…", Slot.muted);
                break;
            }
            body_ ~= label(b, line.length ? line : " ", Slot.code);
        }
        body_ ~= row(b, [
            button(b, "×", "Cancel", ctx.labels, Hit.cancel, minRows: ctx.targetRows),
            button(b, "⏎", "As one line", ctx.labels, Hit.oneLine, minRows: ctx.targetRows),
            button(b, "✓", "Paste", ctx.labels, Hit.paste, primary: true, minRows: ctx.targetRows),
        ]);
        return b.finish(band(b, body_, fullWidth: false));
    }

    Placement placement() const @safe => Placement.anchored;

    bool activate(size_t id) @system
    {
        switch (id)
        {
            case Hit.cancel:
                pane.confirmPaste(false);
                return true;
            case Hit.oneLine:
                // The held paste is dropped and its lines go as one: no line
                // break left, so nothing runs until the user presses Enter.
                pane.confirmPaste(false);
                pane.sendPaste(oneLine(text));
                return true;
            case Hit.paste:
                pane.confirmPaste(true);
                return true;
            default:
                return false;
        }
    }

    bool confirm() @system => activate(Hit.paste);
    void cancel() @system => pane.confirmPaste(false);
    bool key(in KeyEvent k) @system => false;
}

/// The lines of `text` joined by single spaces, trailing breaks dropped.
string oneLine(string text) @safe pure
{
    import std.algorithm.iteration : filter, splitter;
    import std.array : join;
    import std.string : strip;

    return text.splitter('\n').filter!(l => l.strip.length).join(" ");
}

/// An OSC 52 read under `ask` (`TPR21`).
final class ClipboardRead : Surface
{
    private TerminalView* pane;
    private string program, where;

    /// `program` names who asked; `where` the tab and pane ("tab "nvim", pane 1").
    this(TerminalView* pane, string program, string where) @safe pure nothrow
    {
        this.pane = pane;
        this.program = program;
        this.where = where;
    }

    WidgetTree build(in SurfaceContext ctx, int cols) @safe
    {
        Builder b;
        uint[] body_;
        body_ ~= label(b, (program.length ? program : "A program") ~ " wants to read your clipboard",
            Slot.textPrimary, bold: true);
        body_ ~= prose(b, where ~ " asked through OSC 52. It could be a remote host over ssh.");
        body_ ~= row(b, [
            button(b, "✓", "Allow once", ctx.labels, Hit.allowOnce, primary: true,
                minRows: ctx.targetRows),
            button(b, "∞", "Always for this pane", ctx.labels, Hit.allowAlways,
                minRows: ctx.targetRows),
            button(b, "×", "Deny", ctx.labels, Hit.deny, minRows: ctx.targetRows),
        ]);
        return b.finish(band(b, body_));
    }

    Placement placement() const @safe => Placement.sheet;

    bool activate(size_t id) @system
    {
        switch (id)
        {
            case Hit.allowOnce:
                pane.answerClipboardRead(ClipboardReadAnswer.allowOnce);
                return true;
            case Hit.allowAlways:
                pane.answerClipboardRead(ClipboardReadAnswer.allowAlways);
                return true;
            case Hit.deny:
                pane.answerClipboardRead(ClipboardReadAnswer.deny);
                return true;
            default:
                return false;
        }
    }

    bool confirm() @system => activate(Hit.allowOnce);
    void cancel() @system => pane.answerClipboardRead(ClipboardReadAnswer.deny);
    bool key(in KeyEvent k) @system => false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

@("confirmations.oneLine.joinsWithoutBreaks")
@safe pure unittest
{
    assert(oneLine("cd /tmp\nrm -rf build\n") == "cd /tmp rm -rf build");
    assert(oneLine("a\n\n  \nb") == "a b");
}

@("confirmations.PasteConfirm.showsTheLinesAndTheChoices")
@system unittest
{
    import std.algorithm.searching : canFind;

    import chrome : place, Place;

    auto s = new PasteConfirm(null, 3, "cd /tmp\nrm -rf build\nnix build .#terminal-apk");
    const l = place(s.build(SurfaceContext.init, 60), 60, 20, 0, 0, 1, 1, Place.top);
    bool title, preview;
    foreach (ref n; l.tree.nodes)
    {
        title |= n.text.canFind("⚠ Paste 3 lines?");
        preview |= n.text == "rm -rf build";
    }
    assert(title && preview);
    size_t buttons;
    foreach (ref t; l.hits)
        buttons += t.hitId == Hit.cancel || t.hitId == Hit.oneLine || t.hitId == Hit.paste;
    assert(buttons == 3);
}

@("confirmations.ClipboardRead.namesWhoAsked")
@system unittest
{
    import std.algorithm.searching : canFind;

    import chrome : place, Place;

    auto s = new ClipboardRead(null, "nvim", `Tab "nvim", pane 1`);
    const l = place(s.build(SurfaceContext.init, 60), 60, 20, 0, 0, 1, 1, Place.top);
    bool named;
    foreach (ref n; l.tree.nodes)
        named |= n.text.canFind("nvim wants to read your clipboard");
    assert(named);
    assert(s.placement == Placement.sheet);
}
