/**
The Tracks page: the CSS-Grid subset, resolved live.

`resolveTracks` is the one piece of the toolkit whose output is a list of
numbers rather than a picture, so the page shows both — the resolved extents
beside the bars they produce — and lets the available width be dragged through
the interesting range with `+`/`-`. The point is watching `fr` absorb the
remainder while `fixed` refuses to and `minmax` gives way only within its bounds.
*/
module pages.tracks_page;

import std.array : appender;
import std.conv : text;

import sparkles.input : Key, KeyEvent;
import sparkles.ui.geometry : SizeSpec;
import sparkles.ui.style : Slot;
import sparkles.ui.tracks : resolveTracks, TrackSpec;
import sparkles.ui.widget : Builder, Widget, WidgetKind;

import kit;
import keymap : GalleryCommand;
import state : GalleryState, TracksDemo;

@safe:

/// ditto
// The page's keys are `galleryBindings` rows in `GalleryScope.pageTracks`.

/// A named track template, with the content widths it is resolved against.
private struct Preset
{
    string name;
    TrackSpec[] tracks;
    int[] contentWidths;
}

/// The templates the page cycles through with `t`.
private Preset[] presets()
{
    return [
        Preset("auto auto auto",
            [TrackSpec.auto_, TrackSpec.auto_, TrackSpec.auto_], [8, 14, 6]),
        Preset("12 1fr 2fr",
            [TrackSpec.fixed(12), TrackSpec.fr(1), TrackSpec.fr(2)], [8, 14, 6]),
        Preset("minmax(6,20) 1fr",
            [TrackSpec.minmax(6, 20), TrackSpec.fr()], [30, 10]),
        Preset("auto 1fr auto",
            [TrackSpec.auto_, TrackSpec.fr(), TrackSpec.auto_], [10, 4, 7]),
    ];
}

/// ditto
uint view(ref Builder b, in GalleryState s)
{
    const w = s.contentWidth;
    const d = s.tracksDemo;
    const all = presets();
    const p = all[d.preset % all.length];

    enum gap = 1;
    const extents = resolveTracks(p.tracks, p.contentWidths, d.avail, gap);

    uint[] rows;
    rows ~= row(b, [label(b, "template", Slot.muted), label(b, p.name, Slot.code)]);
    rows ~= row(b, [label(b, "available", Slot.muted),
        label(b, text(d.avail, " cells, gap ", gap), Slot.code)]);
    rows ~= row(b, [label(b, "content", Slot.muted),
        label(b, numbers(p.contentWidths), Slot.code)]);
    rows ~= row(b, [label(b, "resolved", Slot.muted),
        label(b, numbers(extents), Slot.chromeAccent)]);
    rows ~= row(b, [label(b, "sum + gaps", Slot.muted),
        label(b, text(total(extents) + gap * (cast(int) extents.length - 1)),
            Slot.chromeAccent)]);

    uint[] body_;
    body_ ~= heading(b, "Tracks · the grid subset");
    body_ ~= spacer(b);
    body_ ~= para(b,
        "auto sizes to content, fixed(n) takes exactly n, fr(w) shares what is "
        ~ "left by weight, and minmax(a,b) is content clamped to a range. The "
        ~ "leftover is distributed with integer divmod and an explicit "
        ~ "remainder, so the parts always sum to exactly the whole.", w);
    body_ ~= spacer(b);
    body_ ~= section(b, "resolution", rows);
    body_ ~= spacer(b);
    body_ ~= section(b, "the tracks", [bars(b, p.tracks, extents, gap)]);
    body_ ~= spacer(b);
    body_ ~= para(b,
        "Press + and - to change the available width. Watch fixed stay put, fr "
        ~ "take the difference, and minmax give way only down to its floor.", w);

    return column(b, body_);
}

/// One labelled bar per track, sized to its resolved extent.
private uint bars(ref Builder b, in TrackSpec[] tracks, in int[] extents, int gap)
{
    auto cells = new uint[](extents.length);
    foreach (i, e; extents)
    {
        const caption = label(b, kindOf(tracks[i]) ~ " " ~ e.text,
            i % 2 == 0 ? Slot.chromeAccent : Slot.code);
        cells[i] = b.add(Widget(
            kind: WidgetKind.panel,
            children: [caption],
            slot: i % 2 == 0 ? Slot.chromeFocused : Slot.chip,
            // The bar IS the resolved extent — not a proportion of it redrawn
            // by this page, which would be a second layout to disagree with.
            width: SizeSpec.fixed(e > 0 ? e : 1),
            height: SizeSpec.fixed(1),
            paintBackground: true,
            clipX: true,
        ));
    }
    return b.add(Widget(kind: WidgetKind.row, children: cells, gap: gap));
}

private string kindOf(in TrackSpec t)
{
    final switch (t.kind) with (TrackSpec.Kind)
    {
        case auto_: return "auto";
        case fixed: return "fix";
        case fr: return "fr";
        case minmax: return "mm";
    }
}

private string numbers(in int[] ns)
{
    auto a = appender!string;
    foreach (i, n; ns)
    {
        if (i)
            a ~= "  ";
        a ~= n.text;
    }
    return a[];
}

private int total(in int[] ns) pure nothrow @nogc
{
    int sum;
    foreach (n; ns)
        sum += n;
    return sum;
}

/// ditto
bool handleCommand(ref GalleryState s, GalleryCommand cmd, ubyte arg)
{
    switch (cmd)
    {
        case GalleryCommand.tracksPreset:
            s.tracksDemo.preset = (s.tracksDemo.preset + 1) % presets().length;
            return true;
        case GalleryCommand.tracksGrow:
            s.tracksDemo.avail = clampAvail(s.tracksDemo.avail + 4);
            return true;
        case GalleryCommand.tracksShrink:
            s.tracksDemo.avail = clampAvail(s.tracksDemo.avail - 4);
            return true;
        default: return false;
    }
}

version (unittest)
{
    import keymap : commandFor, GalleryContext, GalleryScope;

    // Tests drive the page exactly as the shell does: the key resolves in
    // the page's scope and the command dispatches above.
    private bool handleKey(ref GalleryState s, in KeyEvent k) @safe
    {
        const r = commandFor(k, GalleryContext(
            pageScope: GalleryScope.pageTracks, contentRegion: true));
        return handleCommand(s, r.cmd, r.arg);
    }
}

/// Wide enough that `fr` has something to share, narrow enough that `minmax`
/// is pushed to its floor — the range where the vocabulary is legible.
private int clampAvail(int n) pure nothrow @nogc
    => n < 12 ? 12 : (n > 72 ? 72 : n);

@("ui_gallery.pages.tracksResolutionExactlySpendsTheWidth")
@safe unittest
{
    // The property the page displays as "sum + gaps": whenever anything can
    // absorb the remainder, the tracks account for every available cell — no
    // rounding crumb left over, none overspent.
    foreach (ref p; presets())
        foreach (avail; [12, 20, 33, 48, 72])
        {
            enum gap = 1;
            const e = resolveTracks(p.tracks, p.contentWidths, avail, gap);
            assert(e.length == p.tracks.length);
            foreach (x; e)
                assert(x >= 0, "a track cannot have negative extent");

            bool hasFr;
            foreach (ref t; p.tracks)
                hasFr |= t.kind == TrackSpec.Kind.fr;
            if (hasFr && avail >= 40)
                assert(total(e) + gap * (cast(int) e.length - 1) == avail,
                    "fr absorbs the remainder exactly");
        }
}

@("ui_gallery.pages.tracksEveryKindIsDemonstrated")
@safe unittest
{
    // Every kind appears in some preset — the page is a catalog, and a kind no
    // preset uses is one a reader never sees.
    bool[TrackSpec.Kind.max + 1] seen;
    foreach (ref p; presets())
        foreach (ref t; p.tracks)
            seen[t.kind] = true;

    static foreach (k; __traits(allMembers, TrackSpec.Kind))
        assert(seen[__traits(getMember, TrackSpec.Kind, k)],
            "no preset uses TrackSpec.Kind." ~ k);
}

@("ui_gallery.pages.tracksWidthKnobStaysInTheLegibleRange")
@safe unittest
{
    GalleryState s;
    foreach (_; 0 .. 40)
        handleKey(s, KeyEvent(Key.char_, '+'));
    assert(s.tracksDemo.avail == 72);
    foreach (_; 0 .. 40)
        handleKey(s, KeyEvent(Key.char_, '-'));
    assert(s.tracksDemo.avail == 12);
}
