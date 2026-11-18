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

import sparkles.ui.glyphs : ActionIcon, iconText;
import sparkles.input.events : KeyEvent;
import sparkles.terminal_view.component : TerminalView;
import sparkles.terminal_view.protocols : ClipboardReadAnswer;
import sparkles.ui.style : FontRole, Slot, TextStyle, TypeStep;
import sparkles.ui.widget : Builder, Widget, WidgetKind, WidgetTree;
import sparkles.ui.wrap : TextWrap;

import sparkles.ui.hit_ids : HitBlock, HitKey, HitRegistry;

import chrome : band, button, label, row, uiLabel;
import surfaces : Placement, Surface, SurfaceContext;

/// The paste guard's buttons, by their index in its hit block.
private enum PasteButton : ubyte
{
    cancel,
    oneLine,
    paste,
}

/// The clipboard read's buttons, by their index in its hit block.
private enum ReadButton : ubyte
{
    allowOnce,
    allowAlways,
    deny,
}

/// A paragraph that wraps to the room it is given, in the interface face (D64).
private uint prose(ref Builder b, const(char)[] text, Slot slot = Slot.textSecondary) @safe
    => b.add(Widget(kind: WidgetKind.text, text: text, slot: slot, wrap: TextWrap.greedy,
        textStyle: TextStyle(fontRole: FontRole.ui, typeStep: TypeStep.body)));

/// The paste guard (`TPR19`).
final class PasteConfirm : Surface
{
    private TerminalView* pane;
    private size_t lines;
    private string text;
    private HitBlock hits_; // its buttons, as the last build numbered them

    /// `text` is the paste already stripped of controls (`TPR18`); `lines` its
    /// line count.
    this(TerminalView* pane, size_t lines, string text) @safe pure nothrow
    {
        this.pane = pane;
        this.lines = lines;
        this.text = text;
    }

    WidgetTree build(in SurfaceContext ctx, int cols, ref HitRegistry hits) @safe
    {
        hits_ = hits.block(HitKey("terminal.paste-confirm"), PasteButton.max + 1);
        import std.algorithm.iteration : splitter;
        import std.conv : to;

        Builder b;
        uint[] body_;
        body_ ~= uiLabel(b, "⚠ Paste " ~ lines.to!string ~ " lines?", Slot.warn, bold: true,
            step: TypeStep.title);
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
            button(b, "×", "Cancel", ctx.labels, hits_[PasteButton.cancel], minRows: ctx.targetRows),
            button(b, "⏎", "As one line", ctx.labels, hits_[PasteButton.oneLine], minRows: ctx.targetRows),
            button(b, iconText(ActionIcon.paste), "Paste", ctx.labels, hits_[PasteButton.paste],
                primary: true, minRows: ctx.targetRows),
        ]);
        return b.finish(band(b, body_, fullWidth: false));
    }

    Placement placement() const @safe => Placement.anchored;

    bool activate(size_t id) @system
    {
        size_t i;
        return hits_.indexOf(id, i) && press(cast(PasteButton) i);
    }

    private bool press(PasteButton which) @system
    {
        final switch (which)
        {
            case PasteButton.cancel:
                pane.confirmPaste(false);
                return true;
            case PasteButton.oneLine:
                // The held paste is dropped and its lines go as one: no line
                // break left, so nothing runs until the user presses Enter.
                pane.confirmPaste(false);
                pane.sendPaste(oneLine(text));
                return true;
            case PasteButton.paste:
                pane.confirmPaste(true);
                return true;
        }
    }

    bool confirm() @system => press(PasteButton.paste);
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
    private HitBlock hits_; // its buttons, as the last build numbered them

    /// `program` names who asked; `where` the tab and pane ("tab "nvim", pane 1").
    this(TerminalView* pane, string program, string where) @safe pure nothrow
    {
        this.pane = pane;
        this.program = program;
        this.where = where;
    }

    WidgetTree build(in SurfaceContext ctx, int cols, ref HitRegistry hits) @safe
    {
        hits_ = hits.block(HitKey("terminal.clipboard-read"), ReadButton.max + 1);
        Builder b;
        uint[] body_;
        body_ ~= uiLabel(b, (program.length ? program : "A program") ~ " wants to read your clipboard",
            Slot.textPrimary, bold: true);
        body_ ~= prose(b, where ~ " asked through OSC 52. It could be a remote host over ssh.");
        body_ ~= row(b, [
            button(b, iconText(ActionIcon.allowOnce), "Allow once", ctx.labels,
                hits_[ReadButton.allowOnce], primary: true, minRows: ctx.targetRows),
            button(b, iconText(ActionIcon.alwaysAllow), "Always for this pane", ctx.labels,
                hits_[ReadButton.allowAlways], minRows: ctx.targetRows),
            button(b, iconText(ActionIcon.deny), "Deny", ctx.labels, hits_[ReadButton.deny],
                minRows: ctx.targetRows),
        ]);
        return b.finish(band(b, body_));
    }

    Placement placement() const @safe => Placement.sheet;

    bool activate(size_t id) @system
    {
        size_t i;
        return hits_.indexOf(id, i) && press(cast(ReadButton) i);
    }

    private bool press(ReadButton which) @system
    {
        final switch (which)
        {
            case ReadButton.allowOnce:
                pane.answerClipboardRead(ClipboardReadAnswer.allowOnce);
                return true;
            case ReadButton.allowAlways:
                pane.answerClipboardRead(ClipboardReadAnswer.allowAlways);
                return true;
            case ReadButton.deny:
                pane.answerClipboardRead(ClipboardReadAnswer.deny);
                return true;
        }
    }

    bool confirm() @system => press(ReadButton.allowOnce);
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
    HitRegistry hits;
    const l = place(s.build(SurfaceContext.init, 60, hits), 60, 20, 0, 0, 1, 1, Place.top);
    bool title, preview;
    foreach (ref n; l.tree.nodes)
    {
        title |= n.text.canFind("⚠ Paste 3 lines?");
        preview |= n.text == "rm -rf build";
    }
    assert(title && preview);
    size_t buttons;
    foreach (ref t; l.hits)
        buttons += hits.find(HitKey("terminal.paste-confirm")).contains(t.hitId);
    assert(buttons == 3);
    assert(!s.activate(0), "an id outside its block is not its");
}

@("confirmations.ClipboardRead.namesWhoAsked")
@system unittest
{
    import std.algorithm.searching : canFind;

    import chrome : place, Place;

    auto s = new ClipboardRead(null, "nvim", `Tab "nvim", pane 1`);
    HitRegistry hits;
    const l = place(s.build(SurfaceContext.init, 60, hits), 60, 20, 0, 0, 1, 1, Place.top);
    bool named;
    foreach (ref n; l.tree.nodes)
        named |= n.text.canFind("nvim wants to read your clipboard");
    assert(named);
    assert(s.placement == Placement.sheet);
}
