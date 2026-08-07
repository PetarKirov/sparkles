/**
The Welcome page: what this build is, and how to drive it.

It is the one page whose content depends on the $(B host) rather than on the
toolkit — the backend that was picked, the surface it opened at, and which input
tiers the target actually serves. That makes it the first thing to look at when
the terminal and the window disagree about anything else in the catalog.
*/
module pages.welcome;

import std.conv : text;

import sparkles.input : InteractionTier;
import sparkles.ui.geometry : SizeSpec;
import sparkles.ui.style : Slot;
import sparkles.ui.widget : Builder, Widget, WidgetKind;

import kit;
import state : GalleryState;

@safe:

/// ditto
uint view(ref Builder b, in GalleryState s)
{
    const w = s.contentWidth;

    uint[] host;
    host ~= kv(b, "backend", s.backend.text);
    host ~= kv(b, "surface", text(s.surface.width, " × ", s.surface.height, " cells"));
    host ~= kv(b, "theme", s.themeName);
    host ~= kv(b, "tier served", tierName(s.caps.tier));

    uint[] caps;
    caps ~= chipRowOf(b, "hover", s.caps.hover);
    caps ~= chipRowOf(b, "sub-cell pointer", s.caps.precisePointer);
    caps ~= chipRowOf(b, "key release", s.caps.keyRelease);
    caps ~= chipRowOf(b, "multi-pointer", s.caps.multiPointer);

    uint[] keys;
    keys ~= keyHint(b, "↑ ↓ / j k", "move within the focused region");
    keys ~= keyHint(b, "Tab", "sidebar ⇄ page");
    keys ~= keyHint(b, "Enter", "open the selected page");
    keys ~= keyHint(b, "[ ]", "previous / next theme");
    keys ~= keyHint(b, "PgUp PgDn", "scroll the page");
    keys ~= keyHint(b, "?", "all bindings");
    keys ~= keyHint(b, "q", "quit");

    uint[] body_;
    body_ ~= heading(b, "sparkles:ui — the catalog");
    body_ ~= spacer(b);
    body_ ~= para(b,
        "Every page below is built from the same widget tree, laid out by the "
        ~ "same engine and painted through the same display list — in a "
        ~ "terminal and in a window. Where the two differ, the difference is "
        ~ "the finding.", w);
    body_ ~= spacer(b);
    body_ ~= section(b, "this build", host);
    body_ ~= spacer(b);
    body_ ~= section(b, "input capabilities", caps);
    body_ ~= spacer(b);
    body_ ~= section(b, "keys", keys);

    return column(b, body_);
}

/// A capability row: the name, and a lit/unlit pill saying whether the target
/// has it. Not a bare `true`/`false` — the point of the page is that a reader
/// can see at a glance which half of the ladder they are on.
private uint chipRowOf(ref Builder b, string name, bool on)
{
    const k = b.add(Widget(
        kind: WidgetKind.text,
        text: name,
        slot: Slot.muted,
        width: SizeSpec.fixed(18),
    ));
    return b.add(Widget(
        kind: WidgetKind.row,
        children: [k, chip(b, on ? "yes" : "no", on)],
        gap: 1,
    ));
}

private string tierName(InteractionTier t)
{
    final switch (t)
    {
        case InteractionTier.passive: return "0 · passive (hover, focus, toggle)";
        case InteractionTier.interactive: return "1 · interactive (keys, pointer, wheel)";
        case InteractionTier.precise: return "2 · precise (sub-cell, gestures)";
    }
}

@("ui_gallery.pages.welcomeReportsTheHostItRanOn")
@safe unittest
{
    import sparkles.ui_app.backend : Backend;

    // The page's content is the host's, not a constant: a build that reported
    // the wrong backend here would be reporting it wrong everywhere.
    GalleryState s;
    s.backend = Backend.gui;
    s.surface = sizeOf(120, 40);

    auto b = Builder();
    const root = view(b, s);
    auto tree = b.finish(root);

    bool sawBackend, sawSurface;
    foreach (ref n; tree.nodes)
    {
        if (n.text == "gui")
            sawBackend = true;
        if (n.text == "120 × 40 cells")
            sawSurface = true;
    }
    assert(sawBackend && sawSurface);
}

version (unittest)
{
    private auto sizeOf(int w, int h)
    {
        import sparkles.ui.geometry : Size;

        return Size(w, h);
    }
}
