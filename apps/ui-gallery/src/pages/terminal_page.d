/**
The Terminal page: real shells inside the catalog — the `TVW7` embedding
proof, VSCode-shaped.

A tab strip of live terminals, a button (and `n`) to spawn more, and a pane
that is $(B laid out like any other widget) — the actual cells arrive in the
component's draw phase, which finds the pane's rect by its key and hands it
to `sparkles:terminal-view`. The page itself stays a pure view over state:
spawning a pty is a side effect no page is allowed, so the page raises
request flags and the shell's frame glue performs them.

Keyboard capture is the page's one novelty: with a terminal $(B focused),
every key belongs to the shell inside it — `q`, `Tab`, arrows, `Ctrl+C` —
and the gallery keeps only the release chord. That inversion lives in
`gallery.d`, before the shell's own bindings; here it is only displayed.
*/
module pages.terminal_page;

import sparkles.input : Key, KeyEvent;
import sparkles.ui.components.chrome : actionBar, tabStrip;
import sparkles.ui.geometry : SizeSpec;
import sparkles.ui.style : Decoration, Slot, TextStyle;
import sparkles.ui.widget : Builder, Widget, WidgetKind;

import kit;
import state : GalleryState, hitTerminal, hitTermActions, keyTermPane, maxTerms;

@safe:

/// ditto
static immutable string[] keys = [
    "n new", "x close", "h/l tab", "e hold", "⏎ focus", "ctrl+] leave",
];

/// The pane's own hit id. Tab ids start at 1, so `hitTerminal + 0` can never
/// name a tab — the strip and the pane share a base without colliding.
private enum size_t hitPane = hitTerminal;

/// The chrome rows the page spends above the pane: heading, spacer, tab
/// strip, action bar, spacer, status line.
private enum int chromeRows = 6;

/// ditto
uint view(ref Builder b, in GalleryState s)
{
    const w = s.contentWidth;

    uint[] body_;
    body_ ~= heading(b, "Terminal · a shell as a widget");
    body_ ~= spacer(b);

    // The strip: stable ids (hitTerminal + tab.id), exited tabs annotated
    // with their status so the hold policy has something to show.
    string[] labels;
    size_t[] ids;
    foreach (i; 0 .. s.terms.count)
    {
        const t = s.terms.tabs[i];
        labels ~= t.exited
            ? tabLabelExited(t.labelText, t.exitStatus)
            : t.labelText.idup;
        ids ~= hitTerminal + t.id;
    }

    uint[] strip;
    if (s.terms.any)
        strip ~= tabStrip(b, labels, s.terms.active, hitTerminal, s.press,
            fitLabels: true, ids: ids);
    strip ~= actionBar(b, [
        "+ new",
        "✕ close",
        s.terms.keepExited ? "hold: all" : "hold: fail",
    ], hitTermActions, s.press);
    body_ ~= column(b, strip);
    body_ ~= spacer(b);

    // The pane: an empty keyed box the layout sizes — the draw phase paints
    // the cells into exactly this rect. Focused, its border says so.
    const paneRows = paneHeight(s);
    if (s.terms.any)
    {
        body_ ~= b.add(Widget(
            kind: WidgetKind.box,
            key: keyTermPane,
            hitId: hitPane,
            width: SizeSpec.grow(1),
            height: SizeSpec.fixed(paneRows),
            decoration: Decoration(borderWidth: intoAll(1),
                borderSlot: s.terms.focused ? Slot.chromeFocused : Slot.border),
        ));
        body_ ~= label(b, s.terms.focused
            ? "the shell has the keyboard — ctrl+] (or ctrl+`) gives it back"
            : "⏎ or click the pane to type into the shell", Slot.muted);
    }
    else
    {
        // The section panel pads two cells a side; the paragraphs wrap inside.
        const inner = w > 14 ? w - 6 : 8;
        body_ ~= section(b, "no terminal yet", [
            para(b, "Press n (or + new) to spawn your shell on a pty. The "
                ~ "emulator is sparkles:terminal-view — libghostty under a "
                ~ "component — and this pane is its first embedding: sized by "
                ~ "layout, painted through the host's draw phase, keyed like "
                ~ "any other widget.", inner),
            spacer(b),
            para(b, "Mouse inside the pane is not wired yet (selection, "
                ~ "scrollback): the mouse-event conversion lands separately. "
                ~ "The keyboard is complete, including Ctrl chords.", inner),
        ]);
    }

    return column(b, body_);
}

/// The pane's height: whatever the content pane has, less this page's own
/// chrome — clamped so a hostile surface still lays out.
int paneHeight(in GalleryState s)
{
    const h = s.contentHeight - chromeRows;
    return h > 2 ? h : 2;
}

private string tabLabelExited(scope const(char)[] name, int status)
{
    import std.conv : text;

    return text(name, " ✕ ", status);
}

private auto intoAll(int n) pure nothrow @nogc
{
    import sparkles.ui.geometry : Insets;

    return Insets.all(n);
}

/// ditto — offered keys only while the keyboard is in the content region and
/// no terminal is focused (capture is intercepted upstream in `gallery.d`).
bool handleKey(ref GalleryState s, in KeyEvent k)
{
    if (k.ch == 'n')
    {
        if (!s.terms.full)
            s.terms.spawnRequested = true;
        return true;
    }
    if (k.ch == 'x')
    {
        if (s.terms.any)
            s.terms.closeRequested = cast(int) s.terms.active;
        return true;
    }
    if (k.ch == 'h')
    {
        s.terms.cycle(-1);
        return true;
    }
    if (k.ch == 'l')
    {
        s.terms.cycle(1);
        return true;
    }
    if (k.ch == 'e')
    {
        s.terms.keepExited = !s.terms.keepExited;
        return true;
    }
    if (k.key == Key.enter && s.terms.any)
    {
        s.terms.focused = true;
        return true;
    }
    return false;
}

/// ditto
bool handleActivate(ref GalleryState s, size_t id)
{
    if (id == hitPane)
    {
        if (s.terms.any)
            s.terms.focused = true;
        return true;
    }
    if (id > hitTerminal && id < hitTermActions)
    {
        // A tab, by identity — find its current slot.
        foreach (i; 0 .. s.terms.count)
            if (hitTerminal + s.terms.tabs[i].id == id)
            {
                s.terms.active = i;
                return true;
            }
        return true; // one of ours, even if the tab just closed under it
    }
    if (id == hitTermActions + 0)
    {
        if (!s.terms.full)
            s.terms.spawnRequested = true;
        return true;
    }
    if (id == hitTermActions + 1)
    {
        if (s.terms.any)
            s.terms.closeRequested = cast(int) s.terms.active;
        return true;
    }
    if (id == hitTermActions + 2)
    {
        s.terms.keepExited = !s.terms.keepExited;
        return true;
    }
    return false;
}

@("ui_gallery.pages.terminalKeysDriveTheModel")
@safe unittest
{
    GalleryState s;

    // `n` requests a spawn; the request is a flag, not a pty — pages are
    // pure views and the shell's frame glue owns the side effect.
    assert(handleKey(s, KeyEvent(Key.char_, 'n')));
    assert(s.terms.spawnRequested);

    // With tabs present, h/l cycle, x aims a close at the active slot, and
    // Enter hands the keyboard to the shell in the pane.
    s.terms.spawnRequested = false;
    cast(void) s.terms.spawn();
    cast(void) s.terms.spawn();
    assert(handleKey(s, KeyEvent(Key.char_, 'h')));
    assert(s.terms.active == 0);
    assert(handleKey(s, KeyEvent(Key.char_, 'x')));
    assert(s.terms.closeRequested == 0);
    assert(handleKey(s, KeyEvent(Key.enter)));
    assert(s.terms.focused);

    assert(handleKey(s, KeyEvent(Key.char_, 'e')));
    assert(s.terms.keepExited);

    assert(!handleKey(s, KeyEvent(Key.char_, 'z')), "unclaimed keys fall through");
}

@("ui_gallery.pages.terminalActivationMapsIdsByIdentity")
@safe unittest
{
    GalleryState s;
    const id1 = s.terms.spawn();
    const id2 = s.terms.spawn();
    cast(void) id1;

    // Closing the first tab must not redirect a press aimed at the second:
    // the hit id carries the identity, not the slot.
    s.terms.close(0);
    assert(handleActivate(s, hitTerminal + id2));
    assert(s.terms.tabs[s.terms.active].id == id2);

    // The action bar: spawn, close, and the hold toggle.
    assert(handleActivate(s, hitTermActions + 0));
    assert(s.terms.spawnRequested);
    assert(handleActivate(s, hitTermActions + 1));
    assert(s.terms.closeRequested == cast(int) s.terms.active);
    assert(handleActivate(s, hitTermActions + 2));
    assert(s.terms.keepExited);

    // The pane focuses; foreign ids fall through.
    assert(handleActivate(s, hitPane));
    assert(s.terms.focused);
    assert(!handleActivate(s, 1));
}
