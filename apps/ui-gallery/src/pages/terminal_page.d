/**
The Terminal page: real shells inside the catalog — the `TVW7` embedding
proof, VSCode-shaped.

A pane beside a $(B vertical) list of terminals (a horizontal strip overflows
by the third tab; VSCode's panel lists them on the right for the same
reason), a button (and `n`) to spawn more, and the pane itself $(B laid out
like any other widget) — the actual cells arrive in the component's draw
phase, which finds the pane's rect by its key. The page stays a pure view
over state: spawning a pty is a side effect no page is allowed, so the page
raises request flags and the shell's frame glue performs them.

Widths are state-computed `fixed` values, like every page's: inside the
shell's scroll viewport a child lays out at its $(B natural) width, so a
`grow` pane collapses to the widest label beside it — the catalog found
that one live, as a terminal that refused to widen with its window.

Keyboard capture is the page's one inversion: with a terminal $(B focused),
every key belongs to the shell inside it — `q`, `Tab`, arrows, `Ctrl+C` —
and the gallery keeps only the release chord and the scrollback keys
(`Shift+PgUp`/`Shift+PgDn`, the emulator convention). That routing lives in
`gallery.d`; here it is only displayed.
*/
module pages.terminal_page;

import std.conv : text;

import sparkles.input : Key, KeyEvent;
import sparkles.ui.components.chrome : actionBar, scrollbar;
import sparkles.ui.geometry : SizeSpec;
import sparkles.ui.style : Decoration, Slot, TextStyle;
import sparkles.ui.widget : Builder, Widget, WidgetKind;

import kit;
import state : GalleryState, hitTerminal, hitTermActions, keyTermPane, maxTerms;

@safe:

/// ditto
static immutable string[] keys = [
    "n new", "x close", "h/l tab", "⏎ focus", "⇧PgUp history", "ctrl+] leave",
];

/// The pane's own hit id. Tab ids start at 1, so `hitTerminal + 0` can never
/// name a tab — the list rows and the pane share a base without colliding.
enum size_t hitPane = hitTerminal;

/// The chrome rows the page spends beyond the pane: heading, spacer, action
/// bar, spacer, status line.
private enum int chromeRows = 6;

/// The terminal list's width — label room for "▸ shell 8 ✕ 127".
private enum int listWidth = 18;

/// Below this content width the list yields (the tabs stay reachable with
/// `h`/`l`), exactly as the shell's own sidebar yields the surface.
private enum int listMinContent = 48;

/// ditto
uint view(ref Builder b, in GalleryState s)
{
    const w = s.contentWidth;

    uint[] body_;
    body_ ~= heading(b, "Terminal · a shell as a widget");
    body_ ~= spacer(b);

    body_ ~= actionBar(b, [
        "+ new",
        "✕ close",
        s.terms.keepExited ? "hold: all" : "hold: fail",
    ], hitTermActions, s.press);
    body_ ~= spacer(b);

    const paneRows = paneHeight(s);
    if (s.terms.any)
    {
        // The pane, its scrollback bar, and the terminal list — explicit
        // widths that sum to the pane's (see the module header for why
        // `grow` cannot do this here). The bar column is always reserved,
        // like the shell's own gutter: content that reflowed sideways the
        // moment history crossed the viewport would be worse than one
        // blank column.
        const listOn = w >= listMinContent;
        const listW = listOn ? listWidth : 0;
        const paneW = w - 1 - listW;

        uint[] across;
        across ~= b.add(Widget(
            kind: WidgetKind.box,
            key: keyTermPane,
            hitId: hitPane,
            width: SizeSpec.fixed(paneW),
            height: SizeSpec.fixed(paneRows),
            decoration: Decoration(borderWidth: intoAll(1),
                borderSlot: s.terms.focused ? Slot.chromeFocused : Slot.border),
        ));
        across ~= scrollbackBar(b, s, paneRows);
        if (listOn)
            across ~= termList(b, s, paneRows);

        body_ ~= b.add(Widget(
            kind: WidgetKind.row,
            children: across,
            width: SizeSpec.fixed(w),
            height: SizeSpec.fixed(paneRows),
        ));
        // The grid size leads the status line, as emulators do on resize.
        body_ ~= label(b, text(s.terms.paneCols, "×", s.terms.paneRows, " · ",
            s.terms.focused
            ? "the shell has the keyboard — ctrl+] (or ctrl+`) gives it back"
            : "⏎ or click the pane to type into the shell"), Slot.muted);
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
            para(b, "The keyboard is complete, including Ctrl chords; the "
                ~ "wheel and Shift+PgUp/PgDn walk the scrollback. Mouse "
                ~ "inside the pane (selection, links) waits on the "
                ~ "mouse-event conversion.", inner),
        ]);
    }

    return column(b, body_);
}

/// The scrollback bar: the terminal's own numbers (mirrored into state by the
/// frame glue), through the same thumb formula as every bar in the catalog.
/// One column, always reserved; the thumb appears once there is history.
private uint scrollbackBar(ref Builder b, in GalleryState s, int paneRows)
{
    if (s.terms.sbTotal > s.terms.sbLen && s.terms.sbLen > 0)
        return scrollbar(b, clampInt(s.terms.sbTotal), clampInt(s.terms.sbLen),
            clampInt(s.terms.sbOffset), paneRows);
    return b.add(Widget(kind: WidgetKind.box,
        width: SizeSpec.fixed(1), height: SizeSpec.fixed(paneRows)));
}

/// The vertical terminal list, VSCode-panel style: one row per tab, the
/// active one marked, an exited one carrying its status. Rows mint the same
/// `hitTerminal + id` the old strip did, so activation is unchanged.
private uint termList(ref Builder b, in GalleryState s, int paneRows)
{
    uint[] rows;
    foreach (i; 0 .. s.terms.count)
    {
        const t = s.terms.tabs[i];
        const active = i == s.terms.active;
        auto caption = text(active ? "▸ " : "  ", t.labelText,
            t.exited ? text(" ✕ ", t.exitStatus) : "");
        if (caption.length > listWidth)
            caption = caption[0 .. listWidth];
        rows ~= b.add(Widget(
            kind: WidgetKind.text,
            text: caption,
            hitId: hitTerminal + t.id,
            slot: active ? Slot.chromeAccent
                : t.exited ? Slot.muted : Slot.chrome,
            textStyle: TextStyle(bold: active),
        ));
    }
    return b.add(Widget(
        kind: WidgetKind.column,
        children: rows,
        width: SizeSpec.fixed(listWidth),
        height: SizeSpec.fixed(paneRows),
    ));
}

private int clampInt(long v) pure nothrow @nogc
    => v > int.max ? int.max : (v < 0 ? 0 : cast(int) v);

/// The pane's height: whatever the content pane has, less this page's own
/// chrome — clamped so a hostile surface still lays out.
int paneHeight(in GalleryState s)
{
    const h = s.contentHeight - chromeRows;
    return h > 2 ? h : 2;
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

@("ui_gallery.pages.terminalPaneFollowsTheSurfaceWidth")
@safe unittest
{
    import sparkles.ui.geometry : Constraints, Size;
    import sparkles.ui.layout : layout;
    import sparkles.ui.state : keyedRects;
    import state : keyTermPane;

    // The live defect this pins: inside the shell's scroll viewport a child
    // lays out at its NATURAL width, so a `grow` pane collapsed to the
    // widest label beside it and a widened window left the terminal at its
    // spawn width. The pane's width is a state-computed fixed value now,
    // and it must track the surface.
    int paneWidthAt(int surface)
    {
        GalleryState s;
        s.surface = Size(surface, 30);
        cast(void) s.terms.spawn();
        auto b = Builder();
        auto tree = b.finish(view(b, s));
        // The page subtree alone, at its natural width — the scroll
        // viewport's situation, which is where the collapse happened.
        auto frames = layout(tree, Constraints(maxW: s.contentWidth));
        foreach (kr; keyedRects(tree, frames))
            if (kr.key == keyTermPane)
                return kr.rect.width;
        assert(0, "the pane lost its key");
    }

    const at90 = paneWidthAt(90);
    const at130 = paneWidthAt(130);
    assert(at130 > at90 + 30, "the pane must widen with the surface");
}
