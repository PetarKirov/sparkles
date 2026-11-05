/** Generated settings and fuzzy font selection for the specimen lab. */
module lab_controls;

import core.time : MonoTime;
import std.conv : text;
import std.math : round;
import std.path : baseName;

import sparkles.base.term_color : RgbColor;
import sparkles.base.term_style : UnderlineStyle;
import sparkles.font : openFace, UserCoordinate;
import sparkles.input : Event, FocusEvent, GestureEvent, Key, KeyAction, KeyEvent, PointerAction, PointerEvent, WheelEvent, match;
import sparkles.ui.components.controls : chip, ControlSize;
import sparkles.ui.components.picker : PickerState;
import sparkles.ui.components.property_sections : decodeSectionHit, SectionItem, SectionPart, SectionsOptions;
import sparkles.ui.components.settings_pane : SettingsPane, SettingsResult;
import sparkles.ui.components.settings_sections : SettingsSections;
import sparkles.ui.components.scroll_body : ScrollBody;
import sparkles.ui.display_list : buildDisplayList;
import sparkles.ui.canvas : DrawOp;
import sparkles.ui.geometry : Constraints, Insets, Point, Rect, Size, SizeSpec;
import sparkles.ui.interp.immediate : paint;
import sparkles.ui.layout : Frame, layout;
import sparkles.ui.property_tree : EditValue, LeafKind;
import sparkles.ui.style : Palette, Slot, TextStyle;
import sparkles.ui.state : hitAt, hoverTargets;
import sparkles.ui.widget : Builder, TextSpan, Widget, WidgetKind, WidgetTree;
import sparkles.ui_app.specimen_font : sameSpecimenRequest, SpecimenFallbackFace, SpecimenFontRequest;

import font_catalog : FontEntry, FontFinder, FontLibrary, FontLoad;
import font_settings : applyVariations, axisSettings, LabSettings;
import unicode_samples : Showcase, showcaseFonts, unicodeSamples;

private enum size_t sectionBase = 0x7100_0000, fontHit = 0x7000_0001, pickerBase = 0x7200_0000;

private double secondsNow() @safe nothrow @nogc
    => MonoTime.currTime.ticks / cast(double) MonoTime.ticksPerSecond;

/// Dismissing a held slider candidate releases capture; the next opening
/// accepts its first touch without waiting for the abandoned contact.
@("text_lab.controls.dismissHeldContact")
@system unittest
{
    import sparkles.input : PointerButton;
    import sparkles.ui.canvas : RecordingCanvas;
    import sparkles.ui_app.record : RecordingHost;

    struct Host
    {
        RecordingHost recording;
        alias recording this;
        int cellWidth = 10, cellHeight = 20;
    }
    LabSettings model;
    auto controls = new LabControls(&model);
    Host host;
    host.capabilities.hover = false;
    RecordingCanvas canvas;
    bool shown = true;
    controls.draw(&canvas, Size(49, 50), shown, Palette.init);
    Rect track;
    foreach (i, widget; controls.tree.nodes)
    {
        uint node, part;
        if (decodeSectionHit(sectionBase, widget.hitId, node, part)
            && part == SectionPart.slider
            && controls.pane.tree.data.nodes[node].value.path == "font.size")
            track = controls.frames[i].rect;
    }
    const press = Event(PointerEvent(action: PointerAction.press, button: PointerButton.left,
        pos: Point((track.x + 1) * 10, (track.y + 1) * 20)));
    cast(void) controls.handle(host, press, shown, true);
    assert(controls.capturing && controls.sections.capturing);
    cast(void) controls.handle(host, Event(KeyEvent(Key.char_, 'q')), shown, true);
    assert(!shown && !controls.capturing && !host.pointerCaptured);
    shown = true;
    controls.draw(&canvas, Size(49, 50), shown, Palette.init);
    cast(void) controls.handle(host, press, shown, true);
    assert(controls.capturing && controls.sections.capturing);
    controls.openPicker();
    assert(!controls.capturing && !controls.scrollBody.motion.active);
    controls.frame(host);
    assert(!host.pointerCaptured);
}

/// A changing numeric badge and reset visibility must not move the captured
/// track or the following slider rows on either responsive sheet.
@("text_lab.controls.sliderGeometryStaysStable")
@system unittest
{
    import std.conv : text;
    import sparkles.ui.canvas : RecordingCanvas;

    foreach (width; [49, 100])
    {
        LabSettings model;
        auto controls = new LabControls(&model);
        RecordingCanvas canvas;
        Rect[string] original;
        foreach (value; [12.0, 4.0, 4.00001, 99.75, 100.0, 143.99999, 12.0])
        {
            model.font.size = value;
            model.rendering.contrast = value / 144;
            controls.draw(&canvas, Size(width, 60), true, Palette.init);
            foreach (i, widget; controls.tree.nodes)
            {
                uint node, part;
                if (!decodeSectionHit(sectionBase, widget.hitId, node, part)
                    || part != SectionPart.slider) continue;
                const path = controls.pane.tree.data.nodes[node].value.path;
                const rect = controls.frames[i].rect;
                if (auto before = path in original)
                    assert(rect == *before, text(path, " at ", value, " width ", width,
                        ": ", rect, " vs ", *before));
                else original[path] = rect;
            }
        }
        assert(original.length >= 2);
    }
}

/// The sheet's state; application-specific policy around the shared editors.
final class LabControls
{
    LabSettings* subject;
    SettingsPane!LabSettings pane;
    SettingsSections sections;
    PickerState!128 picker;
    FontFinder finder;
    FontLibrary library;
    Rect bounds;
    WidgetTree tree;
    Frame[] frames;
    string error;
    string variation;
    string startupSpec;
    string[] directories;
    string cache;
    bool discovery;
    private bool corpusReady;
    private FontLoad* pending, current;
    private FontLoad*[3] currentStyles;
    private FontLoad* stylesFor;
    private string pendingLabel;
    private bool reseed;
    private LabSettings pendingBefore, dragBefore;
    private AxisSettingCache remembered;
    private LabSettings[] undo, redo;
    private SectionItem[] items;
    private size_t focus;
    private ScrollBody scrollBody;
    private int scroll() const @safe pure nothrow @nogc => cast(int) scrollBody.motion.whole;
    private void scroll(int value) @safe pure nothrow @nogc
        => scrollBody.motion.jumpTo(value, scrollMax);
    private int scrollMax;
    private bool focusMoved;
    private bool initial;
    private LabSettings accepted;
    private LabSettings[] acceptedUndo, acceptedRedo;
    private FontLoad*[3] acceptedStyles;
    private FontLoad* acceptedStylesFor;
    private SpecimenFontRequest acceptedRequest;
    private SpecimenFontRequest lastRequest;
    private FontLoad*[] fallbackOwners;
    private FontLoad*[] pageFallbacks;
    private SpecimenFallbackFace[] fallbackSources;
    private Showcase fallbackGroup;
    private bool fallbackSelected, fallbackBusy;
    string fallbackWarning; /// unavailable optional showcase families
    private ulong requestGeneration;
    private MonoTime changedAt;
    private bool eventMutated;
    private bool keyboardShown;
    private bool touching, panning;
    private PointerEvent touchPress;
    private size_t touchFirstRow;
    private DrawOp[] overlayOps;
    private LabSettings overlaySubject;
    private Palette overlayPalette;
    private string overlayError;
    private double overlayScroll;
    private size_t overlayFocus;
    private bool overlayDirty = true;

    private alias AxisSettingCache = typeof(LabSettings.init.axes)[string];

    /// Binds one stable subject after the application has reached its run loop.
    this(LabSettings* settings) @system
    {
        subject = settings;
        pane.open(settings, *settings);
        pane.tv.open = typeof(pane.tv.open).allOpen;
        pane.refresh();
        accepted = snapshot();
    }

    /// A screenshot waits for the exact startup face, not the entire catalog.
    bool loading() const @safe pure nothrow @nogc
        => pending !is null || fallbackBusy || (discovery && (!initial || picker.active && !corpusReady));

    /// Polls the background jobs and applies at most the latest font request.
    void frame(H)(ref H h)
    {
        static if (__traits(hasMember, H, "capturePointer"))
            h.capturePointer(capturing);
        static if (__traits(hasMember, H, "frameSeconds"))
            if (scrollBody.animate(h.frameSeconds)) h.requestFrame();
        if (scrollBody.motion.pos != overlayScroll) overlayDirty = true;
        uint rows;
        foreach (sample; unicodeSamples) if (sample.group == subject.samples.group) ++rows;
        if (subject.samples.group == Showcase.overview) rows += 2;
        if (subject.samples.firstRow < 1 || subject.samples.firstRow > rows)
            subject.samples.firstRow = 1;
        if (!eventMutated && *subject != accepted)
        {
            changedAt = MonoTime.currTime;
            if (current !is null && pending is null && !sections.drag.active)
                rememberEdit(accepted);
        }
        if (discovery && library is null)
        {
            library = new FontLibrary;
            library.start(directories, cache);
        }
        if (library !is null)
        {
            library.poll();
            if (library.ready && !corpusReady)
            {
                corpusReady = true;
                overlayDirty = true;
                finder.corpus(library.entries);
                if (picker.active) finder.search(picker);
            }
            if (!library.ready || pending !is null)
                h.requestFrame();
            foreach (style; currentStyles)
                if (style !is null && !style.done) h.requestFrame();
        }
        static if (__traits(hasMember, H, "fontPath"))
        {
            if (!initial && discovery)
            {
                if (!startupSpec.length)
                {
                    initial = true;
                    if (h.fontPath.length)
                        choose(h.fontPath, subject.font.index, h.fontPath, false);
                }
                else
                {
                    import std.algorithm.searching : canFind;
                    import std.path : baseName, extension;
                    import std.string : split, strip, toLower;

                    const ext = startupSpec.extension.toLower;
                    if (startupSpec.canFind('/') || startupSpec.canFind('\\')
                        || ext == ".ttf" || ext == ".otf" || ext == ".ttc" || ext == ".otc")
                    {
                        initial = true;
                        choose(startupSpec, subject.font.index, startupSpec.baseName, false);
                    }
                    else if (corpusReady)
                    {
                        initial = true;
                        bool selected;
                        foreach (preference; startupSpec.split(","))
                        {
                            foreach (entry; library.entries)
                                if (entry.family.toLower == preference.strip.toLower)
                                {
                                    choose(entry.path, entry.index, entry.label, false);
                                    selected = true;
                                    break;
                                }
                            if (selected) break;
                        }
                        if (!selected) error = "No catalog font matches: " ~ startupSpec;
                    }
                }
            }
        }
        else initial = true;
        if (discovery && library !is null)
        {
            if (!library.ready || !prepareFallbacks(subject.samples.group))
            {
                h.requestFrame();
                return;
            }
        }
        if (pending !is null && pending.done)
        {
            auto prepared = pending;
            pending = null;
            if (!prepared.ok)
            {
                error = "Could not open font: " ~ prepared.path;
                restoreAccepted();
            }
            else
            {
                auto opened = openFace(prepared.bytes[], prepared.index);
                if (opened.hasValue)
                {
                    auto candidate = snapshot();
                    if (reseed)
                    {
                        const key = identity(prepared.path, prepared.index);
                        if (auto saved = key in remembered)
                            candidate.axes = (*saved).dup;
                        else
                            candidate.axes = axisSettings(opened.value);
                    }
                    else if (!candidate.axes.length)
                        candidate.axes = axisSettings(opened.value);
                    candidate.font.path = prepared.path;
                    candidate.font.index = prepared.index;
                    candidate.font.face = pendingLabel;
                    if (variation.length)
                    {
                        error = applyVariations(candidate.axes, variation);
                        variation = null;
                    }
                    if (error.length == 0 && submit(h, candidate, prepared))
                    {
                        *subject = candidate;
                        current = prepared;
                        library.retain(current, currentStyles, fallbackOwners);
                        pane.edits = typeof(pane.edits).init;
                        pane.refresh();
                        if (reseed) rememberEdit(pendingBefore);
                        acceptModel();
                    }
                    else restoreAccepted();
                }
            }
        }
        if (current !is null && pending is null)
        {
            auto candidate = snapshot();
            const changed = candidate != accepted;
            if (submit(h, candidate, current))
            {
                *subject = candidate;
                library.retain(current, currentStyles, fallbackOwners);
                if (changed) error = null;
                acceptModel();
            }
            else restoreAccepted();
        }
        eventMutated = false;
        static if (__traits(compiles, h.textInput(true)))
        {
            const wanted = picker.active || pane.textEditing || pane.tv.searching;
            if (wanted != keyboardShown)
            {
                h.textInput(wanted);
                keyboardShown = wanted;
            }
        }
    }

    private bool prepareFallbacks(Showcase group) @system
    {
        if (!fallbackSelected || fallbackGroup != group)
        {
            import std.uni : toLower;
            pageFallbacks = null;
            fallbackWarning = null;
            foreach (font; showcaseFonts)
            {
                if (!(font.pages & (1u << cast(uint) group))) continue;
                size_t chosen = size_t.max;
                int best = int.min;
                foreach (i, entry; library.entries)
                {
                    const family = entry.family.toLower == font.family.toLower;
                    const file = entry.path.baseName == font.filename && entry.index == font.faceIndex;
                    if (!family && !file) continue;
                    const score = (family ? 100 : 0) + (file ? 50 : 0)
                        - (entry.italic ? 20 : 0) - (entry.weight > 400 ? entry.weight - 400 : 400 - entry.weight) / 100;
                    if (score > best) { best = score; chosen = i; }
                }
                if (chosen == size_t.max)
                {
                    if (fallbackWarning.length) fallbackWarning ~= ", ";
                    else fallbackWarning = "Missing sample fonts: ";
                    fallbackWarning ~= font.family;
                    continue;
                }
                const entry = library.entries[chosen];
                auto job = library.request(entry.path, entry.index);
                if (job is null) { fallbackBusy = true; return false; }
                pageFallbacks ~= job;
                bool retained;
                foreach (owner; fallbackOwners) retained |= owner is job;
                if (!retained)
                {
                    fallbackOwners ~= job;
                    library.retain(current, currentStyles, fallbackOwners);
                }
            }
            fallbackGroup = group;
            fallbackSelected = true;
            fallbackSources = null;
        }
        fallbackBusy = false;
        foreach (job; pageFallbacks) fallbackBusy |= !job.done;
        if (fallbackBusy) return false;
        if (fallbackSources.length != pageFallbacks.length)
        {
            fallbackSources = null;
            foreach (job; pageFallbacks)
                if (job.ok)
                    fallbackSources ~= SpecimenFallbackFace(job.bytes[], job.index, job.contentHash);
                else fallbackWarning = "Could not load a sample fallback font";
        }
        return true;
    }

    private bool submit(H)(ref H h, ref LabSettings candidate, FontLoad* prepared)
    {
        const coords = candidate.coordinates();
        static if (__traits(hasMember, H, "specimenFont"))
        {
            double density = 1;
            static if (__traits(hasMember, H, "fontDensity")) density = h.fontDensity;
            const px = cast(int) round(candidate.font.size * 96.0 / 72.0 * density);
            SpecimenFontRequest request;
            request.path = prepared.path;
            request.faceIndex = prepared.index;
            request.px = px < 1 ? 1 : px;
            request.coordinates = coords;
            request.uiFollows = candidate.font.uiFollows;
            request.bytes = prepared.bytes[];
            request.contentHash = prepared.contentHash;
            request.fallbacks = fallbackSources;
            request.familyStyles = candidate.font.familyStyles;
            prepareStyles(prepared, candidate.font.familyStyles);
            foreach (i, style; currentStyles)
                if (style !is null && style.done && style.ok)
                {
                    request.styleBytes[i] = style.bytes[];
                    request.styleIndices[i] = style.index;
                    request.styleContentHashes[i] = style.contentHash;
                }
            if (!sameSpecimenRequest(lastRequest, request))
            {
                request.generation = ++requestGeneration;
                request.requestedAt = changedAt == MonoTime.init ? MonoTime.currTime : changedAt;
                lastRequest = request;
            }
            else
            {
                request.generation = lastRequest.generation;
                request.requestedAt = lastRequest.requestedAt;
            }
            if (!h.specimenFont(request))
            {
                error = "This font instance could not be prepared";
                return false;
            }
        }
        return true;
    }

    private void prepareStyles(FontLoad* prepared, bool enabled) @system
    {
        if (!enabled)
        {
            stylesFor = null;
            currentStyles[] = null;
            return;
        }
        if (!corpusReady || library is null || stylesFor is prepared) return;
        string family;
        foreach (entry; library.entries)
            if (entry.path == prepared.path && entry.index == prepared.index)
                family = entry.family;
        if (!family.length) return;
        stylesFor = prepared;
        currentStyles[] = null;
        foreach (slot; 0 .. 3)
        {
            size_t best = size_t.max;
            int bestDistance = int.max;
            foreach (i, entry; library.entries)
            {
                const italic = slot != 0;
                const weight = slot == 1 ? 400 : 700;
                if (entry.family != family || entry.italic != italic
                    || (weight == 700 && entry.weight < 600)) continue;
                const d = entry.weight > weight ? entry.weight - weight : weight - entry.weight;
                if (d < bestDistance) { best = i; bestDistance = d; }
            }
            if (best != size_t.max)
                currentStyles[slot] = library.request(library.entries[best].path, library.entries[best].index);
        }
    }

    private void acceptModel() @system
    {
        accepted = snapshot();
        acceptedUndo = undo.dup;
        acceptedRedo = redo.dup;
        acceptedStyles = currentStyles;
        acceptedStylesFor = stylesFor;
        acceptedRequest = lastRequest;
    }

    private void restoreAccepted() @system
    {
        *subject = accepted;
        subject.axes = accepted.axes.dup;
        undo = acceptedUndo.dup;
        redo = acceptedRedo.dup;
        currentStyles = acceptedStyles;
        stylesFor = acceptedStylesFor;
        lastRequest = acceptedRequest;
        if (library !is null) library.retain(current, currentStyles, fallbackOwners);
        pane.edits = typeof(pane.edits).init;
        pane.refresh();
    }

    /// Selecting a face retains session values of the previously selected one.
    void choose(string path, uint index, string label, bool resetAxes = true) @system
    {
        if (library is null) return;
        changedAt = MonoTime.currTime;
        eventMutated = true;
        cast(void) sections.cancel(pane);
        if (subject.font.path.length)
            remembered[identity(subject.font.path, subject.font.index)] = subject.axes.dup;
        pendingBefore = snapshot();
        library.retain(current, currentStyles, fallbackOwners);
        auto job = library.request(path, index);
        if (job is null)
        {
            error = library.error.length ? library.error : "Font worker queue is busy";
            restoreAccepted();
            return;
        }
        error = null;
        pending = job;
        reseed = resetAxes;
        pendingLabel = label;
    }

    /// Closes workers before renderer teardown can release their borrowed data.
    void stop() @system
    {
        if (library !is null) library.stop();
    }

    /// Opens the fuzzy picker; a running catalog shows a loading row.
    void openPicker() @system
    {
        overlayDirty = true;
        cast(void) sections.cancel(pane);
        stopScroll();
        picker.open();
        picker.viewRows = 12;
        if (corpusReady) finder.search(picker);
    }

    /// Records a specimen shortcut at input time, before the next frame starts.
    void externalEdit(LabSettings before) @system
    {
        if (before == *subject) return;
        rememberEdit(before);
        changedAt = MonoTime.currTime;
        eventMutated = true;
    }

    /// The opaque overlay's extent, available before painting the specimen.
    Rect overlayBounds(Size size, bool shown) const @safe pure nothrow @nogc
    {
        if (!shown && !picker.active) return Rect.init;
        const side = size.width >= 90;
        const width = picker.active ? (size.width > 80 ? 76 : size.width)
            : side ? 45 : size.width;
        const available = size.height - 3;
        const height = !picker.active ? (side ? available : available * 2 / 3)
            : available > 36 ? 36 : available;
        return Rect(picker.active ? (size.width - width) / 2 : size.width - width,
            side && !picker.active ? 3 : size.height - height, width, height);
    }

    private void stopScroll(bool reset = false) @safe pure nothrow @nogc
    {
        touching = panning = false;
        scrollBody.cancelDrag();
        scrollBody.motion.stop();
        if (reset) scrollBody.motion.jumpTo(0, scrollBody.limit);
    }

    /// Renders an ordinary widget overlay after the specimen's custom paint.
    void draw(C)(C canvas, Size size, bool shown, in Palette palette)
    {
        const nextBounds = overlayBounds(size, shown);
        if (bounds != nextBounds) overlayDirty = true;
        bounds = nextBounds;
        if (!bounds.width || !bounds.height)
        {
            cast(void) sections.cancel(pane);
            stopScroll();
            tree = WidgetTree.init; frames = null; overlayOps = null;
            overlayDirty = true;
            return;
        }
        if (!overlayDirty && !pane.textEditing && !sections.drag.active
            && scrollBody.motion.pos == overlayScroll && focus == overlayFocus
            && *subject == overlaySubject && palette == overlayPalette && error == overlayError)
        {
            paint(*canvas, overlayOps);
            return;
        }
        const width = bounds.width, height = bounds.height;
        Builder b;
        uint[] rows;
        const target = 3;
        if (picker.active)
        {
            rows ~= b.add(Widget(kind: WidgetKind.text, text: "Font › " ~ picker.prompt.text.idup,
                slot: Slot.textPrimary, height: SizeSpec.fixed(3)));
            if (!corpusReady)
                rows ~= b.add(Widget(kind: WidgetKind.text,
                    text: library !is null && library.error.length ? library.error : "Listing fonts…"));
            else
            {
                picker.viewRows = cast(size_t)(height > 6 ? (height - 6) / target : 1);
                size_t number;
                foreach (ranked; picker.visible)
                {
                    const index = ranked.corpusIndex;
                    if (index >= library.entries.length) continue;
                    const label = library.entries[index].label;
                    TextSpan[] spans;
                    size_t at;
                    foreach (range; finder.highlights(index))
                    {
                        if (range.start > at) spans ~= TextSpan(text: label[at .. range.start], slot: Slot.textPrimary);
                        spans ~= TextSpan(text: label[range.start .. range.end], slot: Slot.accentPrimary,
                            textStyle: TextStyle(bold: true, underline: UnderlineStyle.single));
                        at = range.end;
                    }
                    if (at < label.length) spans ~= TextSpan(text: label[at .. $], slot: Slot.textPrimary);
                    rows ~= b.add(Widget(kind: WidgetKind.rich, spans: spans,
                        height: SizeSpec.fixed(target), hitId: pickerBase + picker.firstRow + number,
                        slot: picker.firstRow + number == picker.selection ? Slot.selection : Slot.surface,
                        paintBackground: true, clipX: true));
                    ++number;
                }
                if (picker.rowCount == 0) rows ~= b.add(Widget(kind: WidgetKind.text, text: "No matching fonts"));
            }
        }
        else
        {
            pane.refresh();
            rows ~= chip(b, "Font: " ~ subject.font.face, fontHit, false, ControlSize(target));
            items = sections.items(pane, true);
            if (focus >= items.length) focus = items.length ? items.length - 1 : 0;
            foreach (i, item; items)
            {
                auto displayed = item;
                const n = pane.tree.data.nodes[item.node].value;
                if (n.path == "font.face" || n.path == "font.path" || n.path == "font.index") continue;
                if (n.path.length >= 5 && n.path[0 .. 5] == "axes[") displayed.label = n.label;
                rows ~= sections.row(b, pane, displayed, i == focus,
                    SectionsOptions(targetRows: target, width: width - 2, touch: true), sectionBase);
            }
        }
        if (error.length) rows ~= b.add(Widget(kind: WidgetKind.text, text: error));
        const body = b.add(Widget(kind: WidgetKind.column, children: rows,
            width: SizeSpec.fixed(width - 2), height: SizeSpec.fixed(height - 2), clipY: true,
            childOffset: Point(0, picker.active ? 0 : scroll),
            childOffsetFracY: picker.active ? 0 : scrollBody.motion.frac));
        const panel = b.add(Widget(kind: WidgetKind.panel, children: [body],
            width: SizeSpec.fixed(width), height: SizeSpec.fixed(height), padding: Insets.all(1),
            slot: Slot.surface, paintBackground: true, clipX: true, clipY: true));
        tree = b.finish(panel);
        frames = layout(tree, Constraints(width, height));
        if (!picker.active)
        {
            int contentHeight;
            foreach (row; rows) contentHeight += frames[row].rect.height;
            scrollMax = contentHeight > height - 2 ? contentHeight - height + 2 : 0;
            scrollBody.content = contentHeight;
            scrollBody.viewport = height - 2;
            double next = scrollBody.motion.pos < scrollMax ? scrollBody.motion.pos : scrollMax;
            if (focusMoved && focus < items.length)
                foreach (i, widget; tree.nodes)
                    if (widget.hitId == sectionBase + items[focus].node * 64)
                    {
                        const r = frames[i].rect;
                        const top = r.y - scrollBody.motion.frac;
                        const bottom = r.bottom - scrollBody.motion.frac;
                        if (top < 1) next += top - 1;
                        else if (bottom > height - 1) next += bottom - height + 1;
                    }
            next = next < 0 ? 0 : next > scrollMax ? scrollMax : next;
            focusMoved = false;
            if (scrollBody.motion.pos != next)
            {
                scrollBody.motion.jumpTo(next, scrollMax);
                tree.nodes[body].childOffset = Point(0, scroll);
                tree.nodes[body].childOffsetFracY = scrollBody.motion.frac;
                frames = layout(tree, Constraints(width, height));
            }
        }
        foreach (ref frame; frames)
            frame.rect = Rect(frame.rect.x + bounds.x, frame.rect.y + bounds.y,
                frame.rect.width, frame.rect.height);
        overlayOps = buildDisplayList(tree, frames, palette, RgbColor(205, 214, 244), RgbColor(24, 24, 37));
        overlaySubject = snapshot();
        overlayPalette = palette;
        overlayError = error;
        overlayScroll = scrollBody.motion.pos;
        overlayFocus = focus;
        overlayDirty = false;
        paint(*canvas, overlayOps);
    }

    /// Routes modal input before specimen shortcuts; returns whether consumed.
    bool capturing() const @safe pure nothrow @nogc => sections.capturing || touching;

    /// ditto
    bool handle(H)(ref H h, in Event event, ref bool shown, bool pixelCoordinates = false)
    {
        overlayDirty = true;
        scrollBody.motion.instant = !pixelCoordinates;
        const previousLevel = sections.levels.length ? sections.levels[$ - 1] : null;
        auto before = snapshot();
        const wasDragging = sections.drag.active;
        bool consumed;
        bool replay;
        event.match!(
            (in FocusEvent f) {
                if (!f.focused)
                {
                    cast(void) sections.cancel(pane);
                    stopScroll();
                    consumed = true;
                }
            },
            (in KeyEvent k) {
                if (k.action == KeyAction.release)
                {
                    consumed = shown || picker.active;
                    return;
                }
                if (k.key == Key.f12)
                {
                    subject.font.uiFollows = false;
                    consumed = true;
                    return;
                }
                if (picker.active)
                {
                    consumed = true;
                    if (k.key == Key.escape || k.key == Key.back) picker.close();
                    else if (k.key == Key.enter) accept();
                    else if (k.key == Key.up) picker.moveSelection(-1);
                    else if (k.key == Key.down) picker.moveSelection(1);
                    else if (k.key == Key.backspace) { picker.prompt.erase(); finder.search(picker); }
                    else if (k.key == Key.char_ && picker.prompt.type(k.ch)) finder.search(picker);
                    return;
                }
                if (!pane.textEditing && ((k.mods.ctrl || k.mods.super_)
                    && (k.ch == 'z' || k.ch == 'y') || k.ch == 'u' || k.ch == 'U'))
                {
                    cast(void) sections.cancel(pane);
                    replay = true;
                    restore(k.ch == 'y' || k.ch == 'U' || k.mods.shift);
                    consumed = true;
                    return;
                }
                if (!shown) return;
                consumed = true;
                if (pane.textEditing || pane.tv.searching)
                {
                    cast(void) pane.handleKey(k);
                    return;
                }
                if (k.key == Key.escape || k.key == Key.back || k.ch == 'q')
                {
                    if (sections.drag.active) cast(void) sections.cancel(pane);
                    else
                    {
                        cast(void) sections.cancel(pane);
                        stopScroll();
                        if (!sections.back()) shown = false;
                    }
                    return;
                }
                if (k.ch == 'u') { restore(false); return; }
                if (k.ch == 'U') { restore(true); return; }
                if (k.ch == '/') { cast(void) pane.handleKey(k); return; }
                if (k.ch == 'f') { openPicker(); return; }
                if (k.key == Key.down || k.ch == 'j') { if (focus + 1 < items.length) ++focus; focusMoved = true; return; }
                if (k.key == Key.up || k.ch == 'k') { if (focus) --focus; focusMoved = true; return; }
                if (focus >= items.length) return;
                const node = items[focus].node;
                if (k.key == Key.enter)
                    cast(void) sections.activate(pane, node, SectionPart.row, SectionsOptions.init,
                        items[focus].kind == SectionItem.Kind.header, false);
                else if (k.ch == 'r') cast(void) pane.resetAt(pane.tree.data.nodes[node].value.path);
                else if (k.key == Key.right || k.ch == '+' || k.ch == '=')
                    cast(void) pane.stepAt(pane.tree.data.nodes[node].value.path, 1);
                else if (k.key == Key.left || k.ch == '-')
                    cast(void) pane.stepAt(pane.tree.data.nodes[node].value.path, -1);
            },
            (in WheelEvent w) {
                if (!shown && !picker.active) return;
                consumed = true;
                if (picker.active) picker.moveSelection(w.dy);
                else if (!sections.drag.active)
                {
                    scrollBody.scroll(w);
                }
            },
            (in PointerEvent p) {
                if (!shown && !picker.active) return;
                int cw = 1, ch = 1;
                static if (__traits(hasMember, H, "cellWidth"))
                    if (pixelCoordinates) { cw = h.cellWidth; ch = h.cellHeight; }
                if (cw < 1) cw = 1;
                if (ch < 1) ch = 1;
                const point = Point(p.pos.x / cw, p.pos.y / ch);
                consumed = bounds.contains(point) || sections.drag.active || touching;
                if (!consumed) return;
                SettingsResult result;
                bool touch;
                static if (__traits(hasMember, H, "capabilities")) touch = !h.capabilities.hover;
                scrollBody.touch = touch;
                if (touch)
                {
                    if (p.action == PointerAction.press)
                    {
                        if (touching) return;
                        touching = true;
                        panning = false;
                        touchPress = p;
                        if (!picker.active)
                            scrollBody.beginDrag(p.pos.y / cast(double) ch, secondsNow());
                        touchFirstRow = picker.firstRow;
                        if (!picker.active)
                            cast(void) sections.pointer(pane, p, tree, frames,
                                sectionBase, result, true, Size(cw, ch));
                        return;
                    }
                    if (!touching || p.pointerId != touchPress.pointerId) return;
                    if (p.action == PointerAction.leave)
                    {
                        touching = panning = false;
                        scrollBody.cancelDrag();
                        cast(void) sections.cancel(pane);
                        return;
                    }
                    const dx = p.pos.x - touchPress.pos.x;
                    const dy = p.pos.y - touchPress.pos.y;
                    const ax = dx < 0 ? -dx : dx, ay = dy < 0 ? -dy : dy;
                    const slop = (cw > ch ? cw : ch) / 4 + 1;
                    if (!sections.drag.active && !panning && ay > ax && ay >= slop)
                    {
                        panning = true;
                        cast(void) sections.cancel(pane);
                    }
                    if (panning)
                    {
                        if (picker.active)
                            cast(void) picker.scrollRowsTo(cast(long) touchFirstRow - dy / (ch * 3));
                        else
                        {
                            scrollBody.dragTo(p.pos.y / cast(double) ch, secondsNow());
                        }
                        if (p.action == PointerAction.release)
                        {
                            scrollBody.endDrag(secondsNow());
                            touching = panning = false;
                        }
                        return;
                    }
                    if (sections.drag.active || ax >= slop && ax > ay)
                        if (!picker.active && sections.pointer(pane, p, tree, frames,
                                sectionBase, result, true, Size(cw, ch)))
                        {
                            scrollBody.cancelDrag();
                            if (p.action == PointerAction.release) touching = false;
                            return;
                        }
                    if (p.action != PointerAction.release) return;
                    touching = false;
                    scrollBody.cancelDrag();
                    cast(void) sections.cancel(pane);
                    if (ax >= slop || ay >= slop) return;
                }
                if (!picker.active && sections.pointer(pane, p, tree, frames,
                        sectionBase, result, touch, Size(cw, ch))) return;
                if (!touch && p.action != PointerAction.press) return;
                const hit = hoverTargets(tree, frames).hitAt(
                    p.pos.x / cast(float) cw, p.pos.y / cast(float) ch);
                if (hit)
                {
                    if (hit == fontHit) { openPicker(); return; }
                    if (picker.active && hit >= pickerBase)
                    {
                        picker.selection = hit - pickerBase;
                        accept();
                        return;
                    }
                    uint node, part;
                    if (decodeSectionHit(sectionBase, hit, node, part)
                        && node < pane.tree.data.nodes.length)
                    {
                        bool header;
                        foreach (item; items)
                            if (item.node == node) header = item.kind == SectionItem.Kind.header;
                        cast(void) sections.activate(pane, node, part, SectionsOptions.init, header);
                        return;
                    }
                }
            },
            (in GestureEvent g) {
                if (capturing)
                    consumed = true;
            },
            (_) {},
        );
        const nextLevel = sections.levels.length ? sections.levels[$ - 1] : null;
        if (previousLevel != nextLevel || focusMoved)
        {
            cast(void) sections.cancel(pane);
            stopScroll(previousLevel != nextLevel);
        }
        if (!wasDragging && sections.drag.active) dragBefore = before;
        if (!replay)
        {
            if (wasDragging && !sections.drag.active) rememberEdit(dragBefore);
            else if (!sections.drag.active && consumed && pending is null) rememberEdit(before);
        }
        static if (__traits(hasMember, H, "capturePointer"))
            h.capturePointer(capturing);
        if (consumed) h.requestFrame();
        if (before != *subject || wasDragging)
        {
            changedAt = MonoTime.currTime;
            eventMutated = true;
        }
        return consumed;
    }

    private void accept() @system
    {
        const index = picker.selectedCorpusIndex;
        if (library !is null && index < library.entries.length)
        {
            const entry = library.entries[index];
            choose(entry.path, entry.index, entry.label);
            picker.close();
        }
    }

    private static string identity(string path, uint index) @safe => text(path, '#', index);
    private LabSettings snapshot() @safe
    {
        auto copy = *subject;
        copy.axes = copy.axes.dup;
        return copy;
    }
    private void rememberEdit(LabSettings before) @safe
    {
        if (before == *subject) return;
        undo ~= before;
        if (undo.length > 128) undo = undo[1 .. $];
        redo = null;
    }
    private void restore(bool forward) @system
    {
        if (forward ? !redo.length : !undo.length) return;
        auto now = snapshot();
        auto next = forward ? redo[$ - 1] : undo[$ - 1];
        if (forward) { redo = redo[0 .. $ - 1]; undo ~= now; }
        else { undo = undo[0 .. $ - 1]; redo ~= now; }
        *subject = next;
        subject.axes = next.axes.dup;
        if (current !is null && (current.path != next.font.path || current.index != next.font.index))
            choose(next.font.path, next.font.index, next.font.face, false);
        pane.edits = typeof(pane.edits).init;
        pane.refresh();
    }
}

/// Touch editors request the keyboard; vertical intent scrolls before activation.
/// Retained overlay commands must follow external settings and viewport changes.
@("text_lab.controls.retainedOverlayInvalidation")
@system unittest
{
    import font_settings : AxisSetting;
    import sparkles.ui.canvas : RecordingCanvas;
    import sparkles.ui_app.record : RecordingHost;

    LabSettings model;
    model.axes = [AxisSetting(tag: 0x77676874, title: "Weight", minimum: 100,
        maximum: 900, initial: 400, value: 400)];
    auto controls = new LabControls(&model);
    RecordingCanvas canvas;
    controls.draw(&canvas, Size(49, 50), true, Palette.init);
    auto retained = controls.tree.nodes;
    controls.draw(&canvas, Size(49, 50), true, Palette.init);
    assert(controls.tree.nodes.ptr == retained.ptr);
    model.axes[0].value = 700;
    controls.draw(&canvas, Size(49, 50), true, Palette.init);
    assert(controls.tree.nodes.ptr != retained.ptr);
    assert(controls.overlaySubject.axes[0].value == 700);
    retained = controls.tree.nodes;
    controls.draw(&canvas, Size(100, 50), true, Palette.init);
    assert(controls.tree.nodes.ptr != retained.ptr && controls.bounds.width == 45);
    controls.draw(&canvas, Size(100, 50), false, Palette.init);
    assert(!controls.overlayOps.length && controls.bounds.empty);
    controls.draw(&canvas, Size(100, 50), true, Palette.init);
    assert(controls.overlayOps.length);
    RecordingHost host;
    bool shown = true;
    cast(void) controls.handle(host, Event(KeyEvent(Key.tab)), shown);
    assert(controls.overlayDirty);
}

@("text_lab.controls.touchKeyboardAndScroll")
@system unittest
{
    import sparkles.input : PointerButton;
    import sparkles.ui.canvas : RecordingCanvas;
    import sparkles.ui_app.record : RecordingHost;

    struct Host
    {
        RecordingHost recording;
        alias recording this;
        bool[] keyboard;
        int cellWidth = 10, cellHeight = 20;
        void textInput(bool on) { keyboard ~= on; }
    }
    LabSettings model;
    auto controls = new LabControls(&model);
    Host host;
    host.capabilities.hover = false;
    bool shown = true;
    controls.openPicker();
    controls.frame(host);
    assert(host.keyboard == [true]);
    cast(void) controls.handle(host, Event(KeyEvent(Key.escape)), shown);
    controls.frame(host);
    assert(host.keyboard == [true, false]);
    cast(void) controls.pane.editTextAt("font.size");
    controls.frame(host);
    assert(host.keyboard[$ - 1]);
    cast(void) controls.handle(host, Event(KeyEvent(Key.escape)), shown);
    controls.frame(host);
    assert(!host.keyboard[$ - 1]);

    RecordingCanvas canvas;
    controls.draw(&canvas, Size(49, 50), shown, Palette.init);
    Rect axes;
    foreach (i, widget; controls.tree.nodes)
    {
        uint node, part;
        if (decodeSectionHit(sectionBase, widget.hitId, node, part)
            && node < controls.pane.tree.data.nodes.length
            && controls.pane.tree.data.nodes[node].value.path == "font")
            axes = controls.frames[i].rect;
    }
    assert(axes.height && controls.bounds.contains(Point(axes.x, axes.y)));
    const at = Point((axes.x + 2) * host.cellWidth, (axes.y + 1) * host.cellHeight);
    auto pointer(PointerAction action, Point p)
        => Event(PointerEvent(action: action, button: PointerButton.left, pos: p));
    assert(controls.handle(host, pointer(PointerAction.press, at), shown, true));
    assert(controls.capturing && host.pointerCaptured);
    assert(!controls.sections.levels.length, "touch press must not activate before scroll intent");
    assert(controls.handle(host, pointer(PointerAction.drag, Point(at.x, at.y - 100)), shown, true));
    assert(controls.scroll > 0 && !controls.sections.levels.length);
    assert(controls.capturing && host.pointerCaptured, "a sheet pan retains capture");
    const wholeDrag = controls.scrollBody.motion.pos;
    cast(void) controls.handle(host, pointer(PointerAction.drag, Point(at.x, at.y - 101)), shown, true);
    assert(controls.scrollBody.motion.pos > wholeDrag
        && controls.scrollBody.motion.pos < wholeDrag + 0.1,
        "one pixel of vertical movement must survive below a whole row");
    assert(controls.handle(host, pointer(PointerAction.release, Point(at.x, at.y - 100)), shown, true));
    assert(!controls.capturing && !host.pointerCaptured);
    controls.scrollBody.motion.fling(8);
    const releasedAt = controls.scrollBody.motion.pos;
    controls.frame(host);
    assert(controls.scrollBody.motion.pos > releasedAt && !controls.scrollBody.motion.instant,
        "the frame loop retains the pixel input policy and advances momentum");

    controls.scroll = 0;
    controls.draw(&canvas, Size(49, 50), shown, Palette.init);
    Rect track;
    foreach (i, widget; controls.tree.nodes)
    {
        uint node, part;
        if (decodeSectionHit(sectionBase, widget.hitId, node, part)
            && part == SectionPart.slider
            && controls.pane.tree.data.nodes[node].value.path == "font.size")
            track = controls.frames[i].rect;
    }
    assert(track.width > 2);
    const start = Point((track.x + 1) * host.cellWidth, (track.y + 1) * host.cellHeight);
    const original = model.font.size;
    cast(void) controls.handle(host, pointer(PointerAction.press, start), shown, true);
    assert(model.font.size == original);
    const moved = Point(start.x + 20, start.y);
    cast(void) controls.handle(host, pointer(PointerAction.drag, moved), shown, true);
    assert(controls.sections.drag.active && model.font.size != original);
    const pixelValue = model.font.size;
    cast(void) controls.handle(host, pointer(PointerAction.drag, Point(moved.x + 1, moved.y)), shown, true);
    assert(model.font.size != pixelValue, "the slider responds to a single pixel");
    assert(host.pointerCaptured);
    assert(controls.capturing);
    auto p2 = PointerEvent(action: PointerAction.press, button: PointerButton.left, pos: Point(start.x + 50, start.y + 50));
    p2.pointerId = 2;
    assert(controls.handle(host, Event(p2), shown, true));
    assert(controls.sections.drag.active);
    import sparkles.input.events : Gesture;
    assert(controls.handle(host, Event(GestureEvent(gesture: Gesture.pinch, scale: 1.5f)), shown, true));
    assert(controls.sections.drag.active);
    cast(void) controls.handle(host, pointer(PointerAction.release, moved), shown, true);
    assert(!controls.sections.drag.active);
    assert(!host.pointerCaptured);
    cast(void) controls.handle(host, Event(KeyEvent(Key.char_, 'u')), shown);
    assert(model.font.size == original, "one undo reverses the whole drag");
    cast(void) controls.handle(host, pointer(PointerAction.press, start), shown, true);
    cast(void) controls.handle(host, pointer(PointerAction.drag, Point(start.x, start.y - 100)), shown, true);
    cast(void) controls.handle(host, pointer(PointerAction.release, Point(start.x, start.y - 100)), shown, true);
    assert(controls.scroll > 0 && model.font.size == original && !controls.sections.drag.active);

    controls.scroll = 0;
    controls.draw(&canvas, Size(49, 50), shown, Palette.init);
    Rect badge;
    foreach (i, widget; controls.tree.nodes)
    {
        uint node, part;
        if (decodeSectionHit(sectionBase, widget.hitId, node, part)
            && part == SectionPart.open
            && controls.pane.tree.data.nodes[node].value.path == "font.size")
            badge = controls.frames[i].rect;
    }
    assert(badge.width);
    const badgeAt = Point((badge.x + 1) * host.cellWidth, (badge.y + 1) * host.cellHeight);
    cast(void) controls.handle(host, pointer(PointerAction.press, badgeAt), shown, true);
    cast(void) controls.handle(host, pointer(PointerAction.release, badgeAt), shown, true);
    assert(controls.pane.textEditing && controls.pane.textPath == "font.size",
        "the numeric badge takes precedence over its containing row");
    cast(void) controls.handle(host, Event(KeyEvent(Key.backspace)), shown);
    cast(void) controls.handle(host, Event(KeyEvent(Key.backspace)), shown);
    cast(void) controls.handle(host, Event(KeyEvent(Key.char_, '1')), shown);
    cast(void) controls.handle(host, Event(KeyEvent(Key.char_, '8')), shown);
    cast(void) controls.handle(host, Event(KeyEvent(Key.enter)), shown);
    assert(model.font.size == 18 && !controls.pane.textEditing);
}

/// Recording seams exercise drawing, global history and model rollback on rejection.
@("text_lab.controls.historyAndRejectedRequest")
@system unittest
{
    import sparkles.ui.canvas : RecordingCanvas;
    import sparkles.ui_app.record : RecordingHost;

    struct Host
    {
        RecordingHost recording;
        alias recording this;
        bool reject;
        bool specimenFont(in SpecimenFontRequest request)
        {
            if (reject) return false;
            return recording.specimenFont(request);
        }
    }

    LabSettings model;
    model.font.path = "fixture.ttf";
    auto controls = new LabControls(&model);
    controls.library = new FontLibrary;
    controls.current = new FontLoad;
    controls.current.path = "fixture.ttf";
    controls.current.ok = controls.current.done = true;
    Host host;
    controls.frame(host);
    const initialSize = model.font.size;
    const firstGeneration = host.recording.specimenFont().generation;
    controls.frame(host);
    assert(host.recording.specimenFont().generation == firstGeneration);
    model.font.size = 24;
    controls.frame(host);
    assert(host.recording.specimenFont().px == 32);
    assert(host.recording.specimenFont().generation > firstGeneration);
    bool shown;
    assert(controls.handle(host, Event(KeyEvent(Key.char_, 'u')), shown));
    controls.frame(host);
    assert(model.font.size == initialSize && !shown);
    assert(controls.handle(host, Event(KeyEvent(Key.char_, 'U')), shown));
    controls.frame(host);
    assert(model.font.size == 24);

    host.reject = true;
    model.font.size = 36;
    controls.frame(host);
    assert(model.font.size == 24 && controls.error.length);
    host.reject = false;
    controls.pending = new FontLoad;
    controls.pending.done = true;
    controls.pending.path = "broken.ttf";
    controls.frame(host);
    assert(controls.current.path == "fixture.ttf" && model.font.size == 24);
    assert(!controls.loading);

    RecordingCanvas canvas;
    controls.draw(&canvas, Size(100, 50), true, Palette.init);
    assert(canvas.ops.length && controls.tree.nodes.length);
    controls.openPicker();
    controls.draw(&canvas, Size(49, 24), true, Palette.init);
    assert(controls.handle(host, Event(KeyEvent(Key.escape)), shown));
    assert(!controls.picker.active);
}
