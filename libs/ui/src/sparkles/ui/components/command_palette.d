/** One command-palette widget view for cell and pixel hosts. */
module sparkles.ui.components.command_palette;

import sparkles.ui.command_palette : CommandPalette, PaletteChoice;
import sparkles.ui.editor.state : EditorState;
import sparkles.ui.components.editor : editorView, EditorViewOptions;
import sparkles.ui.geometry : Insets, Point, SizeSpec;
import sparkles.ui.style : Slot;
import sparkles.ui.widget : Alignment, Builder, TextSpan, Widget, WidgetKind;
import sparkles.fuzzy : TextRange;

/// Viewport and hit routing are host policy; rows default to touch-sized targets.
struct PaletteViewOptions
{
    size_t visibleRows = 10;
    int rowHeight = 3;
    size_t hitBase = 0x7300_0000;
    size_t queryHit = 0x7300_ffff;
    size_t closeHit = 0;
    bool compact = false;
    int maxWidth = 0;
    bool smoothScroll = false;
    long scrollWhole = 0;
    float scrollFrac = 0;
    string title = "Commands";
    string placeholder = "Search commands"; /// Query prompt for the catalog being searched.
    /// Leave the query's caret to the host's cursor (ui-app `HST20`): no glyph moves the text.
    bool hostCursor;
}

/// Retain these value-only actions with the displayed tree, not mutable list indices.
struct PaletteView(Cmd)
{
    uint root = uint.max;
    size_t firstRow;
    PaletteChoice!Cmd[] choices;
}

/// Build from palette results and the shared query editor; no backend enters the view.
PaletteView!Cmd viewCommandPalette(Cmd, size_t Capacity, size_t QueryBytes, Context)(
    ref Builder b, ref CommandPalette!(Cmd, Capacity, QueryBytes) palette,
    in EditorState query, in Context context, PaletteViewOptions options = PaletteViewOptions.init)
{
    PaletteView!Cmd result;
    const state = palette.snapshot;
    if (!state.active)
    {
        result.root = b.add(Widget(kind: WidgetKind.text,
            width: SizeSpec.fixed(0), height: SizeSpec.fixed(0)));
        return result;
    }
    uint[] children;
    if (options.closeHit != 0)
    {
        const titleNode = b.add(Widget(kind: WidgetKind.text, text: options.title,
            slot: Slot.docs, width: SizeSpec.grow()));
        const closeNode = b.add(Widget(kind: WidgetKind.text, text: "✕",
            slot: Slot.muted, hitId: options.closeHit, padding: Insets(0, 1, 0, 1)));
        children ~= b.add(Widget(kind: WidgetKind.row, children: [titleNode, closeNode],
            width: SizeSpec.grow(), alignY: Alignment.center));
    }
    else
        children ~= b.add(Widget(kind: WidgetKind.text, text: options.title, slot: Slot.docs));
    const prompt = editorView(b, query, EditorViewOptions(placeholder: options.placeholder,
        hostCursor: options.hostCursor));
    b.nodes[prompt].hitId = options.queryHit;
    const queryPadding = options.compact ? Insets(0, 1, 0, 1) : Insets(1, 1, 1, 1);
    children ~= b.add(Widget(kind: WidgetKind.column, children: [prompt],
        padding: queryPadding, slot: Slot.surfaceSunken, paintBackground: true,
        width: SizeSpec.grow()));
    const count = options.visibleRows ? options.visibleRows : 1;
    const int rowH = options.rowHeight > 0 ? options.rowHeight : 1;
    result.firstRow = options.smoothScroll ? 0
        : state.selection >= count ? state.selection - count + 1 : 0;
    const stop = options.smoothScroll ? state.rowCount
        : (result.firstRow + count < state.rowCount ? result.firstRow + count : state.rowCount);
    uint[] rowNodes;
    foreach (index; result.firstRow .. stop)
    {
        const entry = palette.row(index);
        TextRange[256] ranges;
        const highlighted = palette.highlights(index, ranges);
        TextSpan[] spans;
        size_t position;
        if (highlighted.hasValue)
            foreach (range; ranges[0 .. highlighted.value])
            {
                if (range.start > position) spans ~= TextSpan(entry.label[position .. range.start]);
                spans ~= TextSpan(entry.label[range.start .. range.end], Slot.matched);
                position = range.end;
            }
        if (position < entry.label.length) spans ~= TextSpan(entry.label[position .. $]);
        uint[] row;
        row ~= b.add(Widget(kind: WidgetKind.rich, spans: spans, width: SizeSpec.grow()));
        if (entry.group.length)
            row ~= b.add(Widget(kind: WidgetKind.text, text: entry.group, slot: Slot.muted));
        static if (__traits(hasMember, Context, "shortcut"))
        {
            const label = context.shortcut(entry.command, state.invocation.target);
            if (label.length) row ~= b.add(Widget(kind: WidgetKind.text, text: label, slot: Slot.muted));
        }
        const rowNode = b.add(Widget(kind: WidgetKind.row, children: row, gap: 1,
            padding: Insets(0, 1, 0, 1), alignY: Alignment.center,
            height: SizeSpec.fixed(rowH), width: SizeSpec.grow(),
            hitId: options.hitBase + result.choices.length,
            slot: index == state.selection ? Slot.selection : Slot.surface,
            paintBackground: true));
        if (options.smoothScroll) rowNodes ~= rowNode;
        else children ~= rowNode;
        result.choices ~= palette.choice(index);
    }
    if (options.smoothScroll && rowNodes.length)
    {
        const int contentH = cast(int)(rowNodes.length * rowH);
        const int maxH = cast(int)(count * rowH);
        const int viewportH = contentH < maxH ? contentH : maxH;
        children ~= b.add(Widget(kind: WidgetKind.column, children: rowNodes, gap: 0,
            height: SizeSpec.fixed(viewportH), width: SizeSpec.grow(),
            clipY: true, childOffset: Point(0, cast(int) options.scrollWhole),
            childOffsetFracY: options.scrollFrac));
    }
    if (!state.rowCount)
        children ~= b.add(Widget(kind: WidgetKind.text, text: "No commands match", slot: Slot.muted));
    const rootPadding = options.compact ? Insets(0, 1, 0, 1) : Insets(1, 1, 1, 1);
    const rootWidth = options.maxWidth > 0 ? SizeSpec.fixed(options.maxWidth) : SizeSpec.grow();
    result.root = b.add(Widget(kind: WidgetKind.column, children: children, gap: 0,
        slot: Slot.surface, paintBackground: true, padding: rootPadding, width: rootWidth));
    return result;
}

/// The shared view renders query carets and fuzzy witnesses, with stamped row actions.
@("ui.command_palette_view.queryWitnessesAndActions")
@safe unittest
{
    import sparkles.ui.command_palette : PaletteCommand, PaletteEntry, PaletteInvocation, PaletteStatus;
    import sparkles.ui.style : Slot;
    import sparkles.ui.widget : WidgetKind;
    enum Command { none, save }
    alias Id = PaletteCommand!Command;
    struct Context
    {
        bool available(Id id, ulong target) const @safe pure nothrow @nogc => true;
        string shortcut(Id id, ulong target) const @safe pure nothrow @nogc => "Ctrl+S";
    }
    CommandPalette!(Command, 4) palette;
    PaletteEntry!Command[1] entries = [PaletteEntry!Command(Id(Command.save), "Save", "File")];
    assert(palette.catalog(entries[]) == PaletteStatus.ok);
    const opening = palette.open(PaletteInvocation(42, 17));
    assert(palette.search(opening.ticket, "sv", Context.init) == PaletteStatus.ok);
    auto query = EditorState.create("sv");
    Builder b;
    const view = viewCommandPalette(b, palette, query, Context.init);
    assert(view.choices.length == 1 && view.choices[0] == palette.choice(0));
    const tree = b.finish(view.root);
    string matched;
    bool caret, shortcut, queryHit;
    foreach (node; tree.nodes)
    {
        shortcut |= node.text == "Ctrl+S";
        queryHit |= node.hitId == PaletteViewOptions.init.queryHit;
        foreach (span; node.spans)
        {
            if (span.slot == Slot.matched) matched ~= span.text;
            if (span.slot == Slot.caret) caret = true;
        }
    }
    assert(matched == "Sv" && caret && shortcut && queryHit);
}

/// A new empty query displays live preedit instead of hiding it behind its placeholder.
@("ui.command_palette_view.initialComposition")
@safe unittest
{
    import sparkles.input.events : CompositionEvent;
    import sparkles.ui.editor.field : EditorField;
    import sparkles.ui.command_palette : PaletteCommand, PaletteInvocation;
    enum Command { none, save }
    struct Context
    {
        bool available(PaletteCommand!Command id, ulong target) const @safe pure nothrow @nogc => true;
    }
    CommandPalette!(Command, 4) palette;
    palette.open(PaletteInvocation(42, 17));
    auto query = EditorField.singleLine();
    query.compose(CompositionEvent.init, "日本語");
    Builder b;
    const view = viewCommandPalette(b, palette, query.state, Context.init);
    const tree = b.finish(view.root);
    string shown;
    foreach (node; tree.nodes)
        foreach (span; node.spans) shown ~= span.text;
    import std.algorithm.searching : canFind;
    assert(shown.canFind("日本語"));
    assert(!shown.canFind("Search commands"));
}
