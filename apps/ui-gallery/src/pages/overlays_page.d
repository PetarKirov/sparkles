/**
The Overlays page: four anchored surfaces, one primitive.

A context menu, a tooltip with a caret, a dropdown and a hovercard are not four
widget types here — they are four $(I policies) over one record, one anchor and
one placement solve (`POP1`, `POP2`). The page exists to make that checkable
rather than assertable-in-prose: every specimen prints the whole
$(REF OverlayGeometry, sparkles,ui,overlay,place) it resolved to, so a reader
sees the side that was asked for beside the side that was granted, which
adjustments fired, and where the caret landed.

$(B Why the readout is the point.) Returning only a rect is the named
anti-pattern of the anchored-overlay catalog: every surveyed subject that
discarded the resolved side paid to re-derive it, and the re-derivations
disagreed with the placements they described. Printing the record is the cheapest
possible proof that nothing here re-derives anything.

The page owns its overlays' $(I intent) — what is open, where, which row is
selected — and never a handle. `overlaysOf` rebuilds the arena from that intent
each frame (`LYR1`), so a stale index cannot survive into the next one.

Spec: `docs/specs/ui/popup.md` `POP8`.
*/
module pages.overlays_page;

import std.conv : text;

import sparkles.input : Key, KeyEvent, PointerAction, PointerButton, PointerEvent;
import sparkles.ui.geometry : Insets, Point, Rect, SizeSpec;
import sparkles.ui.layout : Frame;
import sparkles.ui.overlay.anchor : Anchor;
import sparkles.ui.overlay.arena : OverlayArena, OverlayBand, OverlayRecord;
import sparkles.ui.overlay.place : Adjust, Align, dropdownCollision, Fit,
    hintCollision, OverlayGeometry, Placement, Side;
import sparkles.ui.overlay.policy : DismissCause, DismissFacts, DismissOn,
    DismissPolicy, DismissReason, menuDismiss, wouldDismiss;
import sparkles.ui.state : Timeline;
import sparkles.ui.style : BorderStyle, BoxSide, Decoration, Slot, TextStyle;
import sparkles.ui.widget : Builder, HitBehavior, Widget, WidgetKind, WidgetTree;
import sparkles.ui.wrap : TextWrap;
import sparkles.base.term_style : UnderlineStyle;

import kit;
import keymap : GalleryCommand;
import state : CloseReason, GalleryState, hitOverlayClose, hitOverlayItem,
    hitOverlayLink, hitOverlayTrigger, OverlayDemo, OverlayKind, reasonName;

@safe:

/// What each surface permits to close it. A menu keeps its place while the
/// page scrolls; a hovercard is persistent and goes only when asked.
private DismissPolicy dismissPolicyFor(OverlayKind k) @safe pure nothrow @nogc
{
    final switch (k)
    {
        case OverlayKind.none:
            return DismissPolicy(on: DismissOn.nothing);
        case OverlayKind.contextMenu:
        case OverlayKind.dropdown:
            return DismissPolicy(on: menuDismiss);
        case OverlayKind.hovercard:
            // Persistent: it stays until the reader closes it, so hover-exit
            // and scroll are deliberately absent from the word.
            return DismissPolicy(on: cast(DismissOn)(DismissOn.closeRequest
                | DismissOn.pressOutside | DismissOn.cascade));
    }
}

/// The toolkit's reason as the page's own vocabulary. The page keeps a local
/// enum only so the readout can name causes the toolkit does not yet offer;
/// where the two overlap, the toolkit's is the answer.
private CloseReason reasonFrom(DismissReason r) @safe pure nothrow @nogc
{
    switch (r)
    {
        case DismissReason.closeRequest: return CloseReason.closeRequest;
        case DismissReason.pressOutside: return CloseReason.pressOutside;
        case DismissReason.triggerReactivate: return CloseReason.triggerReactivate;
        case DismissReason.cascade: return CloseReason.cascade;
        default: return CloseReason.pressOutside;
    }
}

/// The `Widget.key`s the page hangs its overlays off. A key names the node an
/// arena record emits, so the page never threads node indices out of its view
/// (`ANC7`: one element per key, per frame).
/// Ranges, not adjacent scalars. `ANC7` makes a duplicate key an ambiguity the
/// resolver refuses rather than a contest the last-painted node wins — which is
/// how this page's first draft was caught: the chip keys were `keyMenuArea + 1
/// + i`, and `i == 0` collided with the dropdown trigger, so the dropdown
/// anchored to nothing rather than silently to a tooltip chip.
private enum size_t keyMenuArea = 71_000;
private enum size_t keyChip = 71_100;      /// `+ i`, one per tooltip chip
private enum size_t keyDropdownTrigger = 71_200;
private enum size_t keyCardAnchor = 71_300;
private enum size_t keySurface = 71_400;   /// `+ depth` for a cascaded card

/// The chips the tooltip row shows, each requesting a different side, so the
/// caret has to move with the resolved edge rather than living on the top one.
private static immutable string[4] tipLabels = ["below", "above", "left", "right"];
private static immutable BoxSide[4] tipSides =
    [BoxSide.bottom, BoxSide.top, BoxSide.left, BoxSide.right];

/// The dropdown's items, and the hovercard's tiny encyclopedia.
private static immutable string[5] themes =
    ["nord", "gruvbox", "solarized", "dracula", "everforest"];
private static immutable string[3] articleTitles =
    ["Sparkles", "D", "Nix"];
private static immutable string[3] articleBodies = [
    "A monorepo of CLI and library utilities, built on D and Nix. "
        ~ "Its UI toolkit renders one view to a terminal, a window and HTML.",
    "A systems programming language with C-like syntax, compile-time "
        ~ "evaluation and design by introspection. See also Nix.",
    "A purely functional package manager. Every build is a derivation, and "
        ~ "every input is pinned. See also D.",
];

/// ditto
uint view(ref Builder b, in GalleryState s)
{
    const w = s.contentWidth;
    const d = s.overlays;

    uint[] body_;
    body_ ~= heading(b, "Overlays · anchored surfaces, four ways");
    body_ ~= spacer(b);
    body_ ~= para(b,
        "A context menu, a tooltip, a dropdown and a hovercard are not four "
        ~ "widget types. They are four policies over one record, one anchor "
        ~ "and one placement solve — so each specimen below prints the whole "
        ~ "decision it resolved to, including the side it asked for beside "
        ~ "the side it got.", w);
    body_ ~= spacer(b);

    // 1 ── the context menu ─────────────────────────────────────────────────
    body_ ~= section(b, "right-click anywhere in this box", [
        b.add(Widget(
            kind: WidgetKind.box,
            slot: Slot.chrome,
            width: SizeSpec.grow(),
            height: SizeSpec.fixed(3),
            paintBackground: true,
            hitId: hitOverlayTrigger,
            key: keyMenuArea,
            stretch: true,
        )),
        label(b, d.kind == OverlayKind.contextMenu
            ? "anchored to the cell you pressed — a 1×1 rect, latched at press"
            : "a point anchor is materialised 1×1, never 0×0 (ANC4)",
            Slot.muted),
    ]);
    body_ ~= spacer(b);

    // 2 ── tooltips, one per side ───────────────────────────────────────────
    uint[] chips;
    foreach (i, lbl; tipLabels)
        chips ~= b.add(Widget(
            kind: WidgetKind.text,
            text: lbl,
            slot: s.overlays.trigger == hitOverlayTrigger + 2 + i
                ? Slot.chromeAccent : Slot.chip,
            padding: Insets(0, 1, 0, 1),
            hitId: hitOverlayTrigger + 2 + i,
            key: keyChip + i,
        ));
    body_ ~= section(b, "hover a chip · the caret follows the resolved edge", [
        row(b, chips, 2),
        label(b, "one arrowCellOf, four backends — and it is suppressed, not "
            ~ "clamped onto a corner, when the edge is too short (PLC11)",
            Slot.muted),
    ]);
    body_ ~= spacer(b);

    // 3 ── the dropdown ─────────────────────────────────────────────────────
    body_ ~= section(b, "a dropdown that caps rather than flips", [
        b.add(Widget(
            kind: WidgetKind.text,
            text: d.kind == OverlayKind.dropdown
                ? "[ theme ▴ ]" : "[ theme ▾ ]",
            slot: Slot.chromeAccent,
            hitId: hitOverlayTrigger + 1,
            key: keyDropdownTrigger,
            focusable: true,
        )),
        label(b, "Enter or click opens · ↑↓ moves · Enter commits · Esc closes",
            Slot.muted),
        kv(b, "committed", themes[d.article[1] % themes.length], 14,
            Slot.code),
    ]);
    body_ ~= spacer(b);

    // 4 ── the hovercard ────────────────────────────────────────────────────
    body_ ~= section(b, "a persistent card you can read, and read on from", [
        row(b, [
            label(b, "see also "),
            b.add(Widget(
                kind: WidgetKind.text,
                text: articleTitles[0],
                slot: Slot.hoverUnderline,
                textStyle: TextStyle(underline: UnderlineStyle.single),
                hitId: hitOverlayLink,
                key: keyCardAnchor,
            )),
        ], 0),
        label(b, "it stays until you close it (×), and a link inside opens a "
            ~ "second card whose parent is the first — closing the parent "
            ~ "truncates the chain (DSM6)", Slot.muted),
    ]);
    body_ ~= spacer(b);

    // ── the live readout ────────────────────────────────────────────────────
    body_ ~= section(b, "what the solve answered", readout(b, s));
    body_ ~= spacer(b);

    // The overlay surfaces themselves are authored HERE, as ordinary children
    // of the page (`POP3`): the content is a child of its anchor and only the
    // EMISSION is hoisted. A portal would have to reparent, and could not
    // serve the static-HTML target at all.
    if (d.open)
        body_ ~= surfaces(b, s);

    return b.add(Widget(
        kind: WidgetKind.column,
        children: body_,
        width: SizeSpec.grow(),
    ));
}

/// The `OverlayGeometry` fields a consumer would otherwise re-derive, printed.
private uint[] readout(ref Builder b, in GalleryState s)
{
    const d = s.overlays;
    if (!d.open)
        return [
            kv(b, "open", "nothing", 14, Slot.muted),
            kv(b, "last close", reasonName(d.lastReason), 14, Slot.muted),
        ];

    const g = s.overlayGeometry;
    return [
        kv(b, "band", d.kind == OverlayKind.hovercard ? "popup (persistent)"
            : d.kind == OverlayKind.dropdown ? "popup" : "popup", 14),
        kv(b, "side", text(sideName(d.kind == OverlayKind.dropdown
            ? Side.bottom : Side.bottom), " → ", sideName(g.side)), 14,
            g.applied.hasFlag(Adjust.flipMain) ? Slot.warn : Slot.code),
        kv(b, "fit", fitName(g.fit), 14,
            g.fit == Fit.exact ? Slot.code : Slot.warn),
        kv(b, "applied", adjustNames(g.applied), 14),
        kv(b, "rect", text(g.rect.x, ",", g.rect.y, " ",
            g.rect.width, "×", g.rect.height), 14),
        kv(b, "available", text(g.available.width, "×", g.available.height), 14),
        kv(b, "arrow", g.arrowVisible
            ? text("cell ", g.arrowCell, g.arrowCentred ? " (centred)"
                : " (clamped — not centred)")
            : "suppressed — no legal cell", 14,
            g.arrowVisible && !g.arrowCentred ? Slot.warn : Slot.code),
        kv(b, "depth", text(d.cardDepth), 14),
        kv(b, "last close", reasonName(d.lastReason), 14, Slot.muted),
    ];
}

/// The open surfaces, as ordinary nodes the arena will hoist and place.
private uint surfaces(ref Builder b, in GalleryState s)
{
    const d = s.overlays;
    final switch (d.kind)
    {
        case OverlayKind.none:
            return spacer(b, 0);

        case OverlayKind.contextMenu:
            return card(b, keySurface, [
                menuRow(b, "Open", 0, d.selected),
                menuRow(b, "Rename", 1, d.selected),
                menuRow(b, "Delete", 2, d.selected),
            ], blocking: true);

        case OverlayKind.dropdown:
        {
            uint[] rows;
            foreach (i, t; themes)
                rows ~= menuRow(b, t, i, d.selected);
            return card(b, keySurface, rows, blocking: true);
        }

        case OverlayKind.hovercard:
        {
            uint[] cards;
            foreach (depth; 0 .. d.cardDepth)
                cards ~= articleCard(b, s, depth);
            // Both cards are children of one column; each is a separate arena
            // record, so the column itself is never placed — every child of it
            // is hoisted, which is why it measures zero.
            return b.add(Widget(kind: WidgetKind.column, children: cards));
        }
    }
}

/// One article card: a title bar with a close affordance, the body, and the
/// links that open the next card.
private uint articleCard(ref Builder b, in GalleryState s, int depth)
{
    const idx = s.overlays.article[depth] % articleTitles.length;
    const title = b.add(Widget(
        kind: WidgetKind.text,
        text: articleTitles[idx],
        slot: Slot.chromeAccent,
        width: SizeSpec.grow(),
        textStyle: TextStyle(bold: true),
    ));
    // The close affordance. Its glyph is a theme value, not a literal, so a
    // terminal that cannot render `×` overrides it where every other glyph is
    // overridden.
    const close = b.add(Widget(
        kind: WidgetKind.text,
        text: "×",
        slot: Slot.muted,
        hitId: hitOverlayClose + depth,
    ));
    const bar = b.add(Widget(kind: WidgetKind.row, children: [title, close],
        width: SizeSpec.grow(), gap: 1));
    const body_ = b.add(Widget(
        kind: WidgetKind.text,
        text: articleBodies[idx],
        slot: Slot.docs,
        width: SizeSpec.fixed(34),
        wrap: TextWrap.greedy,
    ));
    // The link that opens the next card in the chain.
    const link = b.add(Widget(
        kind: WidgetKind.text,
        text: depth == 0 ? articleTitles[1] : articleTitles[2],
        slot: Slot.hoverUnderline,
        textStyle: TextStyle(underline: UnderlineStyle.single),
        hitId: hitOverlayLink + 1 + depth,
    ));
    return card(b, keySurface + depth, [bar, body_, link], blocking: false);
}

/**
The shared surface chrome: a bordered, shadowed panel with a caret.

The children go in an explicit `column`. A `panel` is a $(B stack) — it gives
every child the same origin — so handing it a list of rows paints them all on
one line, which is exactly the trap `lantern_view` documents and exactly what
this page's first draft did.
*/
private uint card(ref Builder b, size_t key, uint[] children, bool blocking)
    => b.add(Widget(
        kind: WidgetKind.panel,
        slot: Slot.surface,
        children: [b.add(Widget(kind: WidgetKind.column, children: children))],
        padding: Insets.all(1),
        paintBackground: true,
        key: key,
        hit: blocking ? HitBehavior.blockPointer : HitBehavior.normal,
        decoration: Decoration(
            borderWidth: Insets.all(1),
            borderStyle: BorderStyle.solid,
            borderRadius: 4,
            shadow: true,
            arrow: true,
        ),
    ));

/// One selectable row inside a menu or a dropdown.
private uint menuRow(ref Builder b, const(char)[] label_, size_t index,
    size_t selected)
    => b.add(Widget(
        kind: WidgetKind.text,
        text: label_,
        slot: index == selected ? Slot.selection : Slot.inherit,
        width: SizeSpec.grow(),
        paintBackground: index == selected,
        hitId: hitOverlayItem + index,
        focusable: true,
    ));

// ── the arena ───────────────────────────────────────────────────────────────

/**
This frame's overlay records, rebuilt from the page's intent.

The whole point of `LYR1` is here: nothing persists but what is open and where.
A record is minted fresh each frame, so a handle cannot go stale and a cascade
is a `cardDepth` the loop stops at rather than a graph anyone has to prune.
*/
OverlayArena overlaysOf(in GalleryState s, in WidgetTree tree)
{
    OverlayArena a;
    const d = s.overlays;
    if (!d.open)
        return a;

    uint nodeWithKey(size_t k)
    {
        foreach (i, ref const n; tree.nodes)
            if (n.key == k)
                return cast(uint) i;
        return uint.max;
    }

    Placement req;
    req.arrow = true;
    // `PLC13`: the side accepted last frame, handed back as an input. Events
    // route against the LAST PAINTED frame, so an oscillating placement is a
    // routing bug — the overlay is drawn where it is not, and clicks land on
    // whatever is underneath it.
    req.lastGoodSide = d.lastSide;
    req.haveLastGood = d.haveLastSide;

    final switch (d.kind)
    {
        case OverlayKind.none:
            break;

        case OverlayKind.contextMenu:
            req.alignment = Align.start;
            a.push(OverlayRecord(
                band: OverlayBand.popup,
                node: nodeWithKey(keySurface),
                anchor: Anchor.atPoint(d.at),
                placement: req,
                hit: HitBehavior.blockPointer,
                triggerHit: d.trigger,
                life: Timeline(phase: Timeline.Phase.hold),
            ));
            break;

        case OverlayKind.dropdown:
            // A list that flips above its trigger loses the reader's place, so
            // it caps its height instead — the one preset that forbids a flip.
            Placement dd = dropdownCollision;
            dd.alignment = Align.start;
            dd.arrow = true;
            dd.lastGoodSide = d.lastSide;
            dd.haveLastGood = d.haveLastSide;
            a.push(OverlayRecord(
                band: OverlayBand.popup,
                node: nodeWithKey(keySurface),
                anchor: Anchor.ofKey(keyDropdownTrigger),
                placement: dd,
                hit: HitBehavior.blockPointer,
                triggerHit: hitOverlayTrigger + 1,
                life: Timeline(phase: Timeline.Phase.hold),
            ));
            break;

        case OverlayKind.hovercard:
            // The chain. Each card's parent is the one before it, which is
            // what makes closing the first a TRUNCATION of the second
            // (`LYR4`, `DSM6`) rather than a graph walk.
            import sparkles.ui.overlay.arena : OverlayId;

            OverlayId parent;
            foreach (depth; 0 .. d.cardDepth)
            {
                Placement hc = req;
                hc.alignment = Align.start;
                parent = a.push(OverlayRecord(
                    band: OverlayBand.popup,
                    parent: parent,
                    node: nodeWithKey(keySurface + depth),
                    anchor: depth == 0
                        ? Anchor.ofKey(keyCardAnchor)
                        : Anchor.ofKey(keySurface + depth - 1),
                    placement: hc,
                    triggerHit: hitOverlayLink + depth,
                    life: Timeline(phase: Timeline.Phase.hold),
                ));
                if (!parent.valid)
                    break;   // the stated capacity refused it; degrade quietly
            }
            break;
    }
    return a;
}

// ── interaction ─────────────────────────────────────────────────────────────

/// ditto
bool handlePointer(ref GalleryState s, in PointerEvent p, in WidgetTree tree,
    in Frame[] frames)
{
    import sparkles.ui.state : hoverTargets;

    if (p.action != PointerAction.press)
        return false;

    const targets = hoverTargets(tree, frames);
    size_t hit;
    foreach (t; targets)
        if (t.hitId != 0 && t.rect.contains(p.pos))
            hit = t.hitId;

    // A right-click opens the context menu wherever it landed, and a 1×1 cell
    // anchor is latched at PRESS — the terminal has no key release to latch
    // at, so press is the only edge every live target reports (`ANC5`).
    if (p.button == PointerButton.right)
    {
        if (hit == hitOverlayTrigger)
        {
            s.overlays.close(CloseReason.reopened);
            s.overlays.kind = OverlayKind.contextMenu;
            s.overlays.openedThisFrame = true;
        s.overlays.openedThisFrame = true;
            s.overlays.at = p.pos;
            s.overlays.trigger = hit;
            return true;
        }
        return false;
    }

    if (p.button != PointerButton.left)
        return false;

    // Inside an open surface: activate the row, or close the card.
    if (hit >= hitOverlayClose && hit < hitOverlayClose + 2)
    {
        // Closing a card truncates everything opened from it (`DSM6`).
        s.overlays.cardDepth = cast(int)(hit - hitOverlayClose);
        if (s.overlays.cardDepth == 0)
            s.overlays.close(CloseReason.closeAffordance);
        else
            s.overlays.lastReason = CloseReason.cascade;
        return true;
    }
    if (hit >= hitOverlayItem && hit < hitOverlayItem + themes.length)
    {
        commit(s, hit - hitOverlayItem);
        return true;
    }
    if (hit >= hitOverlayLink && hit < hitOverlayLink + 3)
    {
        openCard(s, hit - hitOverlayLink);
        return true;
    }
    if (hit == hitOverlayTrigger + 1)
    {
        toggleDropdown(s);
        return true;
    }

    // An outside press goes through the toolkit's evaluator rather than a
    // page-local `if`, so the page demonstrates the requirement instead of
    // paraphrasing it. The facts matter here: a press delivered in the frame
    // an overlay opened in is routed against the frame BEFORE it existed
    // (`DSM9`), so without the exemption a right-click would open a menu and
    // the same press would close it.
    if (s.overlays.open)
    {
        const why = wouldDismiss(dismissPolicyFor(s.overlays.kind),
            DismissCause.pressOutside,
            DismissFacts(openedThisFrame: s.overlays.openedThisFrame));
        if (why == DismissReason.none)
            return false;
        s.overlays.close(reasonFrom(why));
        return true;
    }
    return false;
}

/// ditto
bool handleCommand(ref GalleryState s, GalleryCommand cmd, ubyte arg)
{
    switch (cmd)
    {
        case GalleryCommand.overlayToggle:
            toggleDropdown(s);
            return true;
        case GalleryCommand.overlayNext:
            move(s, 1);
            return true;
        case GalleryCommand.overlayPrev:
            move(s, -1);
            return true;
        case GalleryCommand.overlayCommit:
            if (s.overlays.kind == OverlayKind.dropdown)
                commit(s, s.overlays.selected);
            else
                toggleDropdown(s);
            return true;
        case GalleryCommand.overlayDismiss:
            if (!s.overlays.open)
                return false;
            // Escape truncates one level of a chain before closing the whole
            // thing: LIFO, which is what an ordered arena gives for free.
            if (s.overlays.kind == OverlayKind.hovercard
                && s.overlays.cardDepth > 1)
            {
                --s.overlays.cardDepth;
                s.overlays.lastReason = CloseReason.closeRequest;
                return true;
            }
            s.overlays.close(CloseReason.closeRequest);
            return true;
        default:
            return false;
    }
}

private void toggleDropdown(ref GalleryState s)
{
    if (s.overlays.kind == OverlayKind.dropdown)
        s.overlays.close(CloseReason.triggerReactivate);
    else
    {
        s.overlays.close(CloseReason.reopened);
        s.overlays.kind = OverlayKind.dropdown;
        s.overlays.openedThisFrame = true;
        s.overlays.trigger = hitOverlayTrigger + 1;
        s.overlays.selected = s.overlays.article[1] % themes.length;
    }
}

private void openCard(ref GalleryState s, size_t which)
{
    if (s.overlays.kind != OverlayKind.hovercard)
    {
        s.overlays.close(CloseReason.reopened);
        s.overlays.kind = OverlayKind.hovercard;
        s.overlays.openedThisFrame = true;
        s.overlays.cardDepth = 1;
        s.overlays.article[0] = 0;
        s.overlays.trigger = hitOverlayLink;
        return;
    }
    // A link inside a card opens the next one, bounded by the array.
    if (s.overlays.cardDepth < cast(int) s.overlays.article.length)
    {
        s.overlays.article[s.overlays.cardDepth] = which;
        ++s.overlays.cardDepth;
    }
}

private void commit(ref GalleryState s, size_t index)
{
    s.overlays.article[1] = index % themes.length;
    s.overlays.close(CloseReason.activate);
}

private void move(ref GalleryState s, int step)
{
    if (s.overlays.kind != OverlayKind.dropdown)
        return;
    const n = cast(int) themes.length;
    auto i = cast(int) s.overlays.selected + step;
    if (i < 0)
        i = n - 1;
    else if (i >= n)
        i = 0;
    s.overlays.selected = i;
}

// ── formatting ──────────────────────────────────────────────────────────────

private string sideName(Side s) pure nothrow @nogc
{
    final switch (s)
    {
        case Side.top: return "top";
        case Side.right: return "right";
        case Side.bottom: return "bottom";
        case Side.left: return "left";
    }
}

private string fitName(Fit f) pure nothrow @nogc
{
    final switch (f)
    {
        case Fit.exact: return "exact";
        case Fit.slid: return "slid";
        case Fit.flipped: return "flipped";
        case Fit.shrunk: return "shrunk";
        case Fit.overflowing: return "overflowing";
        case Fit.refused: return "refused";
    }
}

private bool hasFlag(Adjust a, Adjust f) pure nothrow @nogc => (a & f) != 0;

private string adjustNames(Adjust a)
{
    string r;
    void add(string n) { r ~= r.length ? ", " ~ n : n; }
    if (a.hasFlag(Adjust.flipMain)) add("flipMain");
    if (a.hasFlag(Adjust.flipCross)) add("flipCross");
    if (a.hasFlag(Adjust.slideMain)) add("slideMain");
    if (a.hasFlag(Adjust.slideCross)) add("slideCross");
    if (a.hasFlag(Adjust.resizeMain)) add("resizeMain");
    if (a.hasFlag(Adjust.resizeCross)) add("resizeCross");
    return r.length ? r : "none";
}

@("ui_gallery.overlays.theArenaNamesTheSurfaceItBuilt")
@safe unittest
{
    // The page's half of the contract: `view` builds a surface carrying a
    // known key, and `overlaysOf` finds it by that key. A record naming
    // `uint.max` would be silently refused by the solve and paint nothing —
    // which looks exactly like "no overlay is open".
    import sparkles.ui.layout : layout;
    import sparkles.ui.geometry : Constraints;

    GalleryState s;
    s.surface = typeof(s.surface)(110, 46);
    s.overlays.kind = OverlayKind.dropdown;

    auto b = Builder();
    auto tree = b.finish(view(b, s));
    const arena = overlaysOf(s, tree);

    assert(arena.length == 1, "one open surface, one record");
    assert(arena[0].node != uint.max,
        "the record must name a real node, or it paints nothing");
    assert(tree.nodes[arena[0].node].key == keySurface);
}

@("ui_gallery.overlays.aHovercardChainIsParentedAndTruncates")
@safe unittest
{
    // `LYR4` + `DSM6` through the page: the second card's parent is the first,
    // and closing the first is a truncation rather than a graph edit.
    GalleryState s;
    s.surface = typeof(s.surface)(110, 46);
    s.overlays.kind = OverlayKind.hovercard;
    s.overlays.cardDepth = 2;

    auto b = Builder();
    auto tree = b.finish(view(b, s));
    const arena = overlaysOf(s, tree);

    assert(arena.length == 2);
    assert(arena[0].parent == typeof(arena[0].parent).init, "the first is root-owned");
    assert(arena[1].parent == arena[0].id, "the second hangs off the first");
    assert(arena.isWithin(arena[0].id, arena[1].id));
    assert(arena.truncatedAt(arena.cascadeFrom(arena[0].id)).empty,
        "closing the parent closes the chain");
}
