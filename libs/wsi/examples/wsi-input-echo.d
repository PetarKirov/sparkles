#!/usr/bin/env dub
/+ dub.sdl:
    name "wsi_input_echo"
    dependency "sparkles:wsi" path="../../.."
    dependency "sparkles:dql" path="../../.."
    dependency "sparkles:fuzzy" path="../../.."
    dependency "sparkles:event-horizon" path="../../.."
    dependency "sparkles:core-cli" path="../../.."
    dependency "sparkles:base" path="../../.."
    dependency "sparkles:wired" path="../../.."
    dependency "expected" version="~>0.4.1"
    targetPath "build"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
// ci: run --help
/**
Interactive `sparkles:wsi` event echo — the UAT program for the native
window stack. Opens one window on the platform's native backend (Wayland
when `$WAYLAND_DISPLAY` is set, X11 otherwise, AppKit on macOS) and logs
every event the backend queues.

Things to try:
$(LIST
    * hold a key — `repeat` actions (client-synthesized on Wayland);
    * type through your IME — `TextCommitted` and `Composition` lines
        (text-input-v3 on a v3 compositor such as Mutter; XIM through
        `$XMODIFIERS` on X11; `NSTextInputClient` on macOS);
    * scroll, click, and drag — pointer and scroll lines with the shared
        sign convention;
    * drag near a window edge on Wayland — the compositor takes over as an
        interactive resize (GNOME draws no server decorations, so this is
        the only way a bare toplevel resizes there); hold Alt and drag
        anywhere to move the window;
    * press `c` to cycle the standard cursor shapes, `m` to toggle
        maximize, `q` to quit;
    * filter events with `-F "!motion"`, `-F "pointer.phase == pressed"`, or `-F ?` for help.
)
*/
module wsi_input_echo;

import core.time : Duration, msecs;
import std.algorithm.searching : canFind, endsWith, startsWith;
import std.conv : to;
import std.regex : Regex, matchFirst, regex;
import std.stdio : writeln;
import std.string : strip, toLower;
import std.traits : EnumMembers;

import expected : Expected, err, ok;

import sparkles.base.logger : LogLevel, error, info, initLogger, trace, warning;
import sparkles.base.prettyprint : PrettyPrintOptions, prettyPrint;
import sparkles.core_cli.args;
import sparkles.dql;
import sparkles.event_horizon.loop : DefaultLoop, LoopConfig;
import sparkles.input.events : KeyAction, PointerButton;
import sparkles.input.pointer : PointerShape;
import sparkles.wired : CaseStyle, WireCase;
import sparkles.wsi;

/// How close to a border a press must land to count as a resize grip.
private enum double gripSize = 16;

@WireCase(CaseStyle.kebabCase)
enum BackendKind
{
    auto_,
    wayland,
    x11,
    appkit,
}

@WireCase(CaseStyle.kebabCase)
enum EventCategory : ubyte
{
    ready,
    metrics,
    key,
    text,
    composition,
    pointer,
    motion,
    scroll,
    focus,
    window,
}

enum size_t categoryCardinality = [EnumMembers!EventCategory].length;

EventCategory categorize(in WindowEvent event) @safe pure nothrow @nogc
{
    return event.payload.match!(
        (in ReadyEvent _) => EventCategory.ready,
        (in SurfaceMetricsChangedEvent _) => EventCategory.metrics,
        (in KeyboardEvent _) => EventCategory.key,
        (in TextCommittedEvent _) => EventCategory.text,
        (in CompositionEvent _) => EventCategory.composition,
        (in PointerEvent p) => p.phase == PointerPhase.moved ? EventCategory.motion : EventCategory.pointer,
        (in RelativePointerEvent _) => EventCategory.motion,
        (in ScrollEvent _) => EventCategory.scroll,
        (in FocusChangedEvent _) => EventCategory.focus,
        (_) => EventCategory.window,
    );
}

private immutable DqlPathDoc[] wsiInputEchoPaths = [
    DqlPathDoc("pointer.phase", "PointerPhase", "Button/motion phase (pressed, released, moved)", "pointer.phase == pressed"),
    DqlPathDoc("pointer.button", "PointerButton", "Button pressed (left, right, middle)", "pointer.button == left"),
    DqlPathDoc("pointer.logicalPosition.x", "double", "Cursor X coordinate in window space", "pointer.logicalPosition.x > 400"),
    DqlPathDoc("pointer.logicalPosition.y", "double", "Cursor Y coordinate in window space", "pointer.logicalPosition.y <= 600"),
    DqlPathDoc("pointer.pressure", "double", "Stylus/tablet tip pressure [0..1]", "pointer.pressure > 0.5"),
    DqlPathDoc("key.action", "KeyAction", "Key stroke action (press, release, repeat)", "key.action == release"),
    DqlPathDoc("key.logical.character", "dchar", "Decoded UTF-32 character", "key.logical.character == 'q'"),
    DqlPathDoc("key.logical.kind", "LogicalKeyKind", "Logical key category (named, character)", "key.logical.kind == named"),
    DqlPathDoc("key.location", "KeyLocation", "Physical key location (standard, left, right)", "key.location == left"),
    DqlPathDoc("key.composing", "bool", "Whether key is part of active IME composition", "key.composing == false"),
    DqlPathDoc("modifiers.ctrl", "bool", "Control key modifier state", "modifiers.ctrl == true"),
    DqlPathDoc("modifiers.alt", "bool", "Alt / Option key modifier state", "modifiers.alt == true"),
    DqlPathDoc("modifiers.shift", "bool", "Shift key modifier state", "modifiers.shift == true"),
    DqlPathDoc("modifiers.super_", "bool", "Super / Meta / Command key modifier state", "modifiers.super_ == true"),
    DqlPathDoc("text.text", "string", "Committed IME / text input string", "regexMatch(text.text, `^[0-9]+$`)"),
    DqlPathDoc("composition.preedit", "string", "Current IME pre-edit composition buffer", "composition.preedit != null"),
    DqlPathDoc("composition.cursor", "size_t", "IME composition inline cursor offset", "composition.cursor == 0"),
    DqlPathDoc("scroll.dx", "double", "Horizontal scroll delta", "scroll.dx != 0"),
    DqlPathDoc("scroll.dy", "double", "Vertical scroll delta", "scroll.dy > 10"),
    DqlPathDoc("scroll.source", "ScrollSource", "Scroll device source (wheel, finger, continuous)", "scroll.source == wheel"),
    DqlPathDoc("scroll.inverted", "bool", "Natural/inverted scroll direction flag", "scroll.inverted == false"),
    DqlPathDoc("focus.focused", "bool", "Window focus gained or lost", "focus.focused == true"),
    DqlPathDoc("metrics.logicalSize.width", "double", "Window client logical width", "metrics.logicalSize.width >= 800"),
    DqlPathDoc("metrics.logicalSize.height", "double", "Window client logical height", "metrics.logicalSize.height >= 600"),
    DqlPathDoc("metrics.scale", "double", "Display HiDPI scaling factor", "metrics.scale >= 2.0"),
];

private immutable string[] wsiCategories = [
    "ready", "metrics", "key", "text", "composition",
    "pointer", "motion", "scroll", "focus", "window", "all"
];

bool comparePathValue(in WindowEvent event, string path, DqlOp op, string target) @safe
{
    string val = target.strip;
    if ((val.startsWith("\"") && val.endsWith("\"")) || (val.startsWith("'") && val.endsWith("'")) || (val.startsWith("`") && val.endsWith("`")))
        val = val[1 .. $ - 1];

    return () @trusted {
        return event.payload.match!(
            (in PointerEvent p) {
                if (path == "pointer.phase" || path == "phase")
                {
                    string actual = p.phase.to!string.toLower;
                    return compareString(actual, op, val.toLower);
                }
                if (path == "pointer.button" || path == "button")
                {
                    string actual = p.button.to!string.toLower;
                    return compareString(actual, op, val.toLower);
                }
                if (path == "pointer.logicalPosition.x" || path == "logicalPosition.x" || path == "x")
                    return compareNumber(p.logicalPosition.x, op, val);
                if (path == "pointer.logicalPosition.y" || path == "logicalPosition.y" || path == "y")
                    return compareNumber(p.logicalPosition.y, op, val);
                if (path == "pointer.pressure" || path == "pressure")
                    return compareNumber(p.pressure, op, val);
                if (path == "modifiers.ctrl" || path == "ctrl")
                    return compareBool(p.modifiers.ctrl, op, val);
                if (path == "modifiers.alt" || path == "alt")
                    return compareBool(p.modifiers.alt, op, val);
                if (path == "modifiers.shift" || path == "shift")
                    return compareBool(p.modifiers.shift, op, val);
                if (path == "modifiers.super_" || path == "super")
                    return compareBool(p.modifiers.super_, op, val);
                return false;
            },
            (in KeyboardEvent k) {
                if (path == "key.action" || path == "action")
                {
                    string actual = k.action.to!string.toLower;
                    return compareString(actual, op, val.toLower);
                }
                if (path == "key.logical.character" || path == "character" || path == "logical.character")
                {
                    if (k.logical.kind == LogicalKeyKind.character)
                    {
                        string actual = [k.logical.character].to!string;
                        return compareString(actual, op, val);
                    }
                    return false;
                }
                if (path == "key.logical.kind" || path == "logical.kind")
                {
                    string actual = k.logical.kind.to!string.toLower;
                    return compareString(actual, op, val.toLower);
                }
                if (path == "key.location" || path == "location")
                {
                    string actual = k.location.to!string.toLower;
                    return compareString(actual, op, val.toLower);
                }
                if (path == "key.composing" || path == "composing")
                    return compareBool(k.composing, op, val);
                if (path == "modifiers.ctrl" || path == "ctrl")
                    return compareBool(k.modifiers.ctrl, op, val);
                if (path == "modifiers.alt" || path == "alt")
                    return compareBool(k.modifiers.alt, op, val);
                if (path == "modifiers.shift" || path == "shift")
                    return compareBool(k.modifiers.shift, op, val);
                if (path == "modifiers.super_" || path == "super")
                    return compareBool(k.modifiers.super_, op, val);
                return false;
            },
            (in TextCommittedEvent t) {
                if (path == "text.text" || path == "text")
                    return compareString(t.text.value[], op, val);
                return false;
            },
            (in CompositionEvent c) {
                if (path == "composition.preedit" || path == "preedit" || path == "composition")
                    return compareString(c.preedit.value[], op, val);
                if (path == "composition.cursor" || path == "cursor")
                    return compareNumber(c.cursor, op, val);
                return false;
            },
            (in ScrollEvent s) {
                if (path == "scroll.dx" || path == "dx")
                    return compareNumber(s.dx, op, val);
                if (path == "scroll.dy" || path == "dy")
                    return compareNumber(s.dy, op, val);
                if (path == "scroll.source" || path == "source")
                    return compareString(s.source.to!string.toLower, op, val.toLower);
                if (path == "scroll.inverted" || path == "inverted")
                    return compareBool(s.inverted, op, val);
                return false;
            },
            (in FocusChangedEvent f) {
                if (path == "focus.focused" || path == "focused")
                    return compareBool(f.focused, op, val);
                return false;
            },
            (in ReadyEvent r) {
                if (path == "metrics.logicalSize.width" || path == "width")
                    return compareNumber(r.metrics.logicalSize.width, op, val);
                if (path == "metrics.logicalSize.height" || path == "height")
                    return compareNumber(r.metrics.logicalSize.height, op, val);
                if (path == "metrics.scale" || path == "scale")
                    return compareNumber(r.metrics.scale.value, op, val);
                return false;
            },
            (in SurfaceMetricsChangedEvent sm) {
                if (path == "metrics.logicalSize.width" || path == "width")
                    return compareNumber(sm.metrics.logicalSize.width, op, val);
                if (path == "metrics.logicalSize.height" || path == "height")
                    return compareNumber(sm.metrics.logicalSize.height, op, val);
                if (path == "metrics.scale" || path == "scale")
                    return compareNumber(sm.metrics.scale.value, op, val);
                return false;
            },
            (_) => false,
        );
    }();
}

bool evalDqlNode(in DqlNode node, in WindowEvent event, EventCategory category) @safe
{
    if (node is null)
        return true;

    final switch (node.kind)
    {
        case DqlNodeKind.category:
            auto cNode = cast(const CategoryNode) node;
            if (cNode.categoryName.toLower == "all")
                return true;
            foreach (cat; [EnumMembers!EventCategory])
            {
                if (cNode.categoryName.toLower == cat.to!string.toLower)
                    return category == cat;
            }
            return false;
        case DqlNodeKind.and_:
            auto aNode = cast(const AndNode) node;
            return evalDqlNode(aNode.left, event, category) && evalDqlNode(aNode.right, event, category);
        case DqlNodeKind.or_:
            auto oNode = cast(const OrNode) node;
            return evalDqlNode(oNode.left, event, category) || evalDqlNode(oNode.right, event, category);
        case DqlNodeKind.not_:
            auto nNode = cast(const NotNode) node;
            return !evalDqlNode(nNode.child, event, category);
        case DqlNodeKind.compare:
            auto cmpNode = cast(const CompareNode) node;
            return comparePathValue(event, cmpNode.path, cmpNode.op, cmpNode.rawValue);
        case DqlNodeKind.regex:
            auto reNode = cast(const RegexNode) node;
            return () @trusted {
                return event.payload.match!(
                    (in TextCommittedEvent t) => (reNode.path == "text" || reNode.path == "text.text") ? !matchFirst(t.text.value[], reNode.pattern).empty : false,
                    (in CompositionEvent c) => (reNode.path == "composition" || reNode.path == "composition.preedit" || reNode.path == "preedit") ? !matchFirst(c.preedit.value[], reNode.pattern).empty : false,
                    (_) => false,
                );
            }();
        case DqlNodeKind.glob:
            auto gNode = cast(const GlobNode) node;
            return () @trusted {
                return event.payload.match!(
                    (in TextCommittedEvent t) => (gNode.path == "text" || gNode.path == "text.text") ? evalGlob(t.text.value[], gNode) : false,
                    (in CompositionEvent c) => (gNode.path == "composition" || gNode.path == "composition.preedit" || gNode.path == "preedit") ? evalGlob(c.preedit.value[], gNode) : false,
                    (_) => false,
                );
            }();
        case DqlNodeKind.fuzzy:
            auto fNode = cast(const FuzzyNode) node;
            return () @trusted {
                return event.payload.match!(
                    (in TextCommittedEvent t) => (fNode.path == "text" || fNode.path == "text.text") ? evalFuzzy(t.text.value[], fNode) : false,
                    (in CompositionEvent c) => (fNode.path == "composition" || fNode.path == "composition.preedit" || fNode.path == "preedit") ? evalFuzzy(c.preedit.value[], fNode) : false,
                    (_) => false,
                );
            }();
        case DqlNodeKind.nullCheck:
            auto nullNode = cast(const NullCheckNode) node;
            bool fieldIsNull = () @trusted {
                return event.payload.match!(
                    (in TextCommittedEvent t) => (nullNode.path == "text" || nullNode.path == "text.text") ? t.text.value.length == 0 : true,
                    (in CompositionEvent c) => (nullNode.path == "composition" || nullNode.path == "composition.preedit" || nullNode.path == "preedit") ? c.preedit.value.length == 0 : true,
                    (_) => true,
                );
            }();
            return nullNode.isNull ? fieldIsNull : !fieldIsNull;
        case DqlNodeKind.custom:
            return true;
    }
}

string validateCategories(in DqlNode node) @safe
{
    if (node is null)
        return null;

    final switch (node.kind)
    {
        case DqlNodeKind.category:
            auto c = cast(const CategoryNode) node;
            if (c.categoryName.toLower == "all")
                return null;
            foreach (cat; [EnumMembers!EventCategory])
            {
                if (c.categoryName.toLower == cat.to!string.toLower)
                    return null;
            }
            return "unknown event category or field: `" ~ c.categoryName ~ "`";
        case DqlNodeKind.and_:
            auto a = cast(const AndNode) node;
            auto err1 = validateCategories(a.left);
            if (err1 !is null) return err1;
            return validateCategories(a.right);
        case DqlNodeKind.or_:
            auto o = cast(const OrNode) node;
            auto err1 = validateCategories(o.left);
            if (err1 !is null) return err1;
            return validateCategories(o.right);
        case DqlNodeKind.not_:
            auto n = cast(const NotNode) node;
            return validateCategories(n.child);
        case DqlNodeKind.compare:
        case DqlNodeKind.regex:
        case DqlNodeKind.glob:
        case DqlNodeKind.fuzzy:
        case DqlNodeKind.nullCheck:
        case DqlNodeKind.custom:
            return null;
    }
}

struct DqlEventFilter
{
    enum size_t N = categoryCardinality;
    bool[N] included;
    bool[N] excluded;
    bool allowAllByDefault = true;
    bool hasFineGrainedPredicates;
    DqlNode rootNode;

    static Expected!(DqlEventFilter, string) parse(string expr) @safe
    {
        DqlEventFilter filter;
        string s = expr.strip;
        if (s.length == 0)
            return ok(filter);

        auto parsed = parseDql(s);
        if (parsed.hasError)
            return err!DqlEventFilter(parsed.error);

        auto catError = validateCategories(parsed.value);
        if (catError !is null)
            return err!DqlEventFilter(catError);

        filter.rootNode = parsed.value;
        filter.hasFineGrainedPredicates = true;

        // Populate fast-path category bitset
        foreach (c; [EnumMembers!EventCategory])
        {
            WindowEvent dummy;
            if (evalDqlNode(filter.rootNode, dummy, c))
                filter.included[c] = true;
            else
                filter.excluded[c] = true;
        }

        return ok(filter);
    }

    bool matches(in WindowEvent event, EventCategory category) const @safe
    {
        if (rootNode is null)
            return true;
        return evalDqlNode(rootNode, event, category);
    }
}

int main(string[] args) => runCli!WsiInputEcho(args);

@(Command("wsi-input-echo",
    shortDescription: "Interactive native WSI event echo and input test harness",
    description: "Opens a native window on Wayland, X11, or AppKit and logs queued WSI events.",
))
struct WsiInputEcho
{
    @(Option(`W|width`, description: "Window width in logical units"))
    int width = 720;

    @(Option(`H|height`, description: "Window height in logical units"))
    int height = 420;

    @(Option(`f|frames`,
        description: "Process N loop ticks then exit (0 = run until the window closes)"))
    int frames;

    @(Option("backend", description: "Native WSI backend (auto / wayland / x11 / appkit)"))
    BackendKind backend = BackendKind.auto_;

    @(Option(`F|event-filter`,
        description: "DQL event filter expression (e.g. '!motion', 'key || text', or 'pointer.phase == pressed')"))
    string eventFilter;

    @(Option("no-color", description: "Disable colored output"))
    bool noColor;

    @(Option("trace", description: "Enable trace-level logging"))
    bool trace;

    Expected!(void, string) run() @system
    {
        initLogger(trace ? LogLevel.trace : LogLevel.info);

        if (eventFilter == "?" || eventFilter == "help")
        {
            printDqlHelp(wsiInputEchoPaths, wsiCategories, "wsi-input-echo", !noColor);
            return ok();
        }

        auto filter = DqlEventFilter.parse(eventFilter);
        if (filter.hasError)
            return err!void("event filter error: " ~ filter.error);

        auto opt = PrettyPrintOptions!void(
            colored: !noColor,
            softMaxWidth: 100,
        );

        DefaultLoop loop;
        auto loopCreated = DefaultLoop.create(loop, LoopConfig());
        if (loopCreated.hasError)
            return err!void("failed to create Event Horizon loop");

        version (OSX)
        {
            if (backend != BackendKind.auto_ && backend != BackendKind.appkit)
                return err!void("requested backend is not available on macOS");

            AppKitWsi wsi;
            auto opened = AppKitWsi.open(wsi);
            if (opened.hasError)
            {
                if (opened.error.kind == WsiErrorKind.unavailable)
                    return skip("AppKit unavailable", cast(string) opened.error.diagnostic.value);
                return err!void("AppKit open failed: " ~ cast(string) opened.error.diagnostic.value);
            }
            auto report = runBackend(wsi, loop, "AppKit", this, filter.value);
            if (report.hasError)
                return err!void(report.error);
            writeln(prettyPrint(report.value, opt));
            return ok();
        }
        else version (linux)
        {
            import core.stdc.stdlib : getenv;

            bool useWayland;
            final switch (backend)
            {
            case BackendKind.auto_:
                useWayland = getenv("WAYLAND_DISPLAY") !is null;
                break;
            case BackendKind.wayland:
                useWayland = true;
                break;
            case BackendKind.x11:
                useWayland = false;
                break;
            case BackendKind.appkit:
                return err!void("AppKit backend is only available on macOS");
            }

            if (useWayland)
            {
                WaylandWsi wsi;
                auto opened = WaylandWsi.open(wsi, loop);
                if (opened.hasError)
                {
                    if (opened.error.kind == WsiErrorKind.unavailable)
                        return skip("Wayland unavailable", cast(string) opened.error.diagnostic.value);
                    return err!void("Wayland open failed: " ~ cast(string) opened.error.diagnostic.value);
                }
                while (!wsi.bootstrapComplete)
                {
                    auto ticked = wsi.runIntegratedOnce(loop, 100.msecs);
                    if (ticked.hasError)
                        return err!void("Wayland bootstrap failed");
                }
                auto report = runBackend(wsi, loop, "Wayland", this, filter.value);
                if (report.hasError)
                    return err!void(report.error);
                writeln(prettyPrint(report.value, opt));
                return ok();
            }
            else
            {
                X11Wsi wsi;
                auto opened = X11Wsi.open(wsi);
                if (opened.hasError)
                {
                    if (opened.error.kind == WsiErrorKind.unavailable)
                        return skip("X11 unavailable", cast(string) opened.error.diagnostic.value);
                    return err!void("X11 open failed: " ~ cast(string) opened.error.diagnostic.value);
                }
                auto attached = wsi.attach(loop);
                if (attached.hasError)
                    return err!void("X11 attach failed: " ~ cast(string) attached.error.diagnostic.value);
                auto report = runBackend(wsi, loop, "X11", this, filter.value);
                if (report.hasError)
                    return err!void(report.error);
                writeln(prettyPrint(report.value, opt));
                return ok();
            }
        }
        else
        {
            return skip("no native backend for this platform yet");
        }
    }
}

/// A skip is a success: the environment lacks a display or a driver.
Expected!(void, string) skip(string what, string detail = null)
{
    if (detail.length)
        writeln("SKIP: ", what, " — ", detail);
    else
        writeln("SKIP: ", what);
    return ok();
}

/// What the run actually did, so an invocation is verifiable.
struct RunReport
{
    string backend;
    uint eventsReceived;
    uint eventsLogged;
    uint readyEvents;
    uint metricsEvents;
    uint keyEvents;
    uint textEvents;
    uint compositionEvents;
    uint pointerEvents;
    uint scrollEvents;
    uint focusEvents;
    uint repaints;
    string exitedBecause;
}

private struct EchoState
{
    WindowId id;
    SurfaceMetrics metrics;
    size_t cursorIndex;
    bool repaint;
    bool quit;
}

private Expected!(void, string) echoLoop(Backend)(ref Backend wsi, ref DefaultLoop loop,
    ref EchoState state, ref RunReport report, int frameBudget,
    in DqlEventFilter filter, in PrettyPrintOptions!void opt)
{
    void handle(WindowEvent event)
    {
        report.eventsReceived++;

        const category = categorize(event);
        if (!filter.matches(event, category))
            return;

        report.eventsLogged++;
        event.payload.match!(
            (in ReadyEvent value) {
                state.metrics = value.metrics;
                state.repaint = true;
                report.readyEvents++;
                info(i"#$(event.sequence) ready $(prettyPrint(value, opt))");
            },
            (in SurfaceMetricsChangedEvent value) {
                state.metrics = value.metrics;
                state.repaint = true;
                report.metricsEvents++;
                info(i"#$(event.sequence) metrics $(prettyPrint(value, opt))");
            },
            (in KeyboardEvent value) {
                report.keyEvents++;
                info(i"#$(event.sequence) key $(prettyPrint(value, opt))");
                if (value.action != KeyAction.release)
                    return;
                if (value.logical.kind == LogicalKeyKind.character)
                    handleCommand(wsi, state, value.logical.character, opt);
            },
            (in TextCommittedEvent value) {
                report.textEvents++;
                info(i"#$(event.sequence) text $(prettyPrint(value, opt))");
            },
            (in CompositionEvent value) {
                report.compositionEvents++;
                info(i"#$(event.sequence) composition $(prettyPrint(value, opt))");
            },
            (in PointerEvent value) {
                report.pointerEvents++;
                info(i"#$(event.sequence) pointer $(prettyPrint(value, opt))");
                if (value.phase == PointerPhase.pressed
                    && value.button == PointerButton.left)
                    handleLeftPress(wsi, state, value);
            },
            (in ScrollEvent value) {
                report.scrollEvents++;
                info(i"#$(event.sequence) scroll $(prettyPrint(value, opt))");
            },
            (in FocusChangedEvent value) {
                report.focusEvents++;
                info(i"#$(event.sequence) focus $(prettyPrint(value, opt))");
            },
            (in CloseRequestedEvent _) {
                info(i"#$(event.sequence) close requested — quitting");
                state.quit = true;
                report.exitedBecause = "window closed";
            },
            (in DestroyedEvent _) {
                info(i"#$(event.sequence) destroyed");
                state.quit = true;
                report.exitedBecause = "destroyed";
            },
            (other) {
                info(i"#$(event.sequence) $(typeof(other).stringof)");
            });
    }

    WindowEvent[128] batch;
    size_t batched;
    int loopsRun;
    while (!state.quit && (frameBudget == 0 || loopsRun < frameBudget))
    {
        loopsRun++;
        static if (is(typeof(wsi.runIntegratedOnce(loop, Duration.init))))
            auto ticked = wsi.runIntegratedOnce(loop, 250.msecs);
        else
            auto ticked = loop.runHostedOnce(wsi, 250.msecs);
        if (ticked.hasError)
        {
            error(i"loop error: $(ticked.error.context) (errno=$(ticked.error.errnoValue) stage=$(ticked.error.stage))");
            auto sticky = wsi.drain((WindowEvent _) @safe {});
            if (sticky.hasError)
                error(i"backend diagnostic: $(sticky.error.diagnostic.value) (kind=$(sticky.error.kind) native=$(sticky.error.nativeCode))");
            return err!void("loop error");
        }
        batched = 0;
        auto drained = wsi.drain((WindowEvent event) @safe {
            if (batched < batch.length)
                () @trusted { batch[batched++] = event; }();
        });
        if (drained.hasError)
        {
            error(i"event queue error: $(drained.error.diagnostic.value)");
            return err!void(cast(string) drained.error.diagnostic.value);
        }
        foreach (ref event; batch[0 .. batched])
            handle(event);
        if (state.repaint)
        {
            state.repaint = false;
            report.repaints++;
            paintIfNeeded(wsi, state);
        }
    }
    if (frameBudget > 0 && loopsRun >= frameBudget && !state.quit)
        report.exitedBecause = "frame budget reached";
    return ok();
}

private void handleCommand(Backend)(ref Backend wsi, ref EchoState state,
    dchar command, in PrettyPrintOptions!void opt)
{
    switch (command)
    {
        case 'q':
            info(i"command: quit");
            state.quit = true;
            break;
        case 'c':
            static immutable shapes = [EnumMembers!PointerShape];
            state.cursorIndex = (state.cursorIndex + 1) % shapes.length;
            const shape = shapes[state.cursorIndex];
            auto set = wsi.setCursor(state.id, shape);
            if (set.hasError)
                warning(i"setCursor($(shape)): $(set.error.diagnostic.value)");
            else
                info(i"setCursor($(shape)): ok");
            break;
        case 'm':
            static if (is(typeof(wsi.setMaximized(state.id, true))))
            {
                static bool maximized;
                maximized = !maximized;
                auto result = wsi.setMaximized(state.id, maximized);
                if (result.hasError)
                    warning(i"setMaximized($(maximized)): $(result.error.diagnostic.value)");
                else
                    info(i"setMaximized($(maximized)): ok");
            }
            else
                info(i"setMaximized: not available on this backend");
            break;
        default:
            break;
    }
}

private void handleLeftPress(Backend)(ref Backend wsi, ref EchoState state,
    in PointerEvent value)
{
    static if (is(typeof(wsi.startInteractiveResize(state.id,
        ResizeEdge.none))))
    {
        if (value.modifiers.alt)
        {
            auto moved = wsi.startInteractiveMove(state.id);
            if (moved.hasError)
                warning(i"startInteractiveMove: $(moved.error.diagnostic.value)");
            else
                info(i"startInteractiveMove: ok");
            return;
        }
        const edge = resizeEdgeAt(state.metrics, value.logicalPosition.x,
            value.logicalPosition.y);
        if (edge == ResizeEdge.none)
            return;
        auto resized = wsi.startInteractiveResize(state.id, edge);
        if (resized.hasError)
            warning(i"startInteractiveResize($(edge)): $(resized.error.diagnostic.value)");
        else
            info(i"startInteractiveResize($(edge)): ok");
    }
}

// Painting exists only where an unmapped surface would stay invisible:
// a Wayland toplevel maps when a buffer is committed, while X11 windows
// paint their background pixel and AppKit windows draw their own chrome.
version (linux)
{
    import core.sys.posix.stdlib : mkstemp;
    import core.sys.posix.unistd : posixClose = close, ftruncate, unlink;

    import wayland_native;

    private struct ShmGlobal
    {
        wl_shm* shm;
    }

    private extern (C) void onShmGlobal(void* data, wl_registry* registry,
        uint name, const(char)* interfaceName, uint) nothrow @nogc
    {
        import core.stdc.string : strcmp;

        auto probe = cast(ShmGlobal*) data;
        if (strcmp(interfaceName, wl_shm_interface.name) == 0
            && probe.shm is null)
            probe.shm = cast(wl_shm*) wl_registry_bind(registry, name,
                &wl_shm_interface, 1);
    }

    private extern (C) void onShmGlobalRemove(void*, wl_registry*, uint)
        nothrow @nogc
    {
    }

    private immutable wl_registry_listener shmListener = {
        &onShmGlobal, &onShmGlobalRemove
    };

    /*
    Fills the surface with a flat color and brighter `gripSize` borders —
    the visible affordance for the compositor-resize zones. One buffer per
    paint; the previous one is destroyed on the next call, when the
    compositor has long since attached its replacement.
    */
    private struct WaylandPainter
    {
        wl_shm* shm;
        wl_buffer* previous;

        bool bind(wl_display* display)
        {
            ShmGlobal probe;
            auto registry = wl_display_get_registry(display);
            if (registry is null)
                return false;
            scope (exit) wl_proxy_destroy(cast(wl_proxy*) registry);
            if (wl_registry_add_listener(registry,
                    cast(wl_registry_listener*) &shmListener, &probe) != 0
                || wl_display_roundtrip(display) < 0)
                return false;
            shm = probe.shm;
            return shm !is null;
        }

        bool paint(wl_display* display, wl_surface* surface, int width,
            int height)
        {
            import core.sys.posix.sys.mman : MAP_FAILED, MAP_SHARED,
                PROT_READ, PROT_WRITE, mmap, munmap;

            if (shm is null || width <= 0 || height <= 0)
                return false;
            char[26] path = "/tmp/wsi-echo-shm-XXXXXX\0\0";
            const fd = mkstemp(path.ptr);
            if (fd < 0)
                return false;
            scope (exit) posixClose(fd);
            unlink(path.ptr);
            const stride = width * 4;
            const size = stride * height;
            if (ftruncate(fd, size) != 0)
                return false;
            auto pixels = mmap(null, size, PROT_READ | PROT_WRITE,
                MAP_SHARED, fd, 0);
            if (pixels is MAP_FAILED)
                return false;
            auto view = (cast(uint*) pixels)[0 .. width * height];
            foreach (y; 0 .. height)
                foreach (x; 0 .. width)
                {
                    const grip = x < gripSize || y < gripSize
                        || x >= width - gripSize || y >= height - gripSize;
                    view[y * width + x] = grip ? 0xFF3A6EA5 : 0xFF20242C;
                }
            munmap(pixels, size);

            auto pool = wl_shm_create_pool(shm, fd, size);
            if (pool is null)
                return false;
            scope (exit) wl_shm_pool_destroy(pool);
            auto buffer = wl_shm_pool_create_buffer(pool, 0, width, height,
                stride, WL_SHM_FORMAT_XRGB8888);
            if (buffer is null)
                return false;
            wl_surface_attach(surface, buffer, 0, 0);
            wl_surface_damage(surface, 0, 0, width, height);
            wl_surface_commit(surface);
            if (previous !is null)
                wl_buffer_destroy(previous);
            previous = buffer;
            return wl_display_flush(display) >= 0;
        }
    }

    private WaylandPainter painter;

    private void paintIfNeeded(Backend)(ref Backend wsi, ref EchoState state)
    {
        static if (is(Backend == WaylandWsi))
        {
            if (state.metrics.suspended)
                return;
            auto queried = wsi.nativeHandles(state.id);
            if (queried.hasError)
                return;
            auto handles = queried.value;
            auto display = handles.display.match!(
                (in WaylandDisplayHandle handle)
                    => cast(wl_display*) handle.display,
                (_) => null);
            auto surface = handles.window.match!(
                (in WaylandWindowHandle handle)
                    => cast(wl_surface*) handle.surface,
                (_) => null);
            if (display is null || surface is null)
                return;
            assert(!wsi.beginNativeIo().hasError);
            scope (exit) assert(!wsi.endNativeIo().hasError);
            if (painter.shm is null && !painter.bind(display))
                return;
            painter.paint(display, surface,
                cast(int) state.metrics.logicalSize.width,
                cast(int) state.metrics.logicalSize.height);
        }
    }
}
else
{
    private void paintIfNeeded(Backend)(ref Backend, ref EchoState)
    {
    }
}

private Expected!(RunReport, string) runBackend(Backend)(ref Backend wsi, ref DefaultLoop loop,
    string name, in WsiInputEcho options, in DqlEventFilter filter)
{
    auto opt = PrettyPrintOptions!void(
        colored: !options.noColor,
        softMaxWidth: 100,
    );

    WindowConfig config;
    if (!config.title.assign("sparkles wsi-input-echo"))
        return err!RunReport("failed to set window title");
    config.logicalSize = LogicalSize(options.width, options.height);

    info(i"creating window with config: $(prettyPrint(config, opt))");
    auto created = wsi.createWindow(config);
    if (created.hasError)
        return err!RunReport("createWindow failed: " ~ cast(string) created.error.diagnostic.value);

    EchoState state;
    state.id = created.value;
    RunReport report = {
        backend: name,
        exitedBecause: "window closed",
    };

    info(i"wsi-input-echo on $(name) — hold keys, type through your IME, scroll, drag the blue border to resize, alt+drag to move, c cycles cursors, m toggles maximize, q quits");

    // Drain the ready event before the first paint so metrics are real.
    auto drained = wsi.drain((WindowEvent event) @safe {
        event.payload.match!(
            (in ReadyEvent value) { state.metrics = value.metrics; },
            (_) {});
    });
    if (drained.hasError)
        return err!RunReport("drain error: " ~ cast(string) drained.error.diagnostic.value);

    // On Wayland the ready event follows the first configure, later in the
    // loop; painting waits for real metrics either way.
    if (!state.metrics.suspended)
        paintIfNeeded(wsi, state);

    auto result = echoLoop(wsi, loop, state, report, options.frames, filter, opt);
    if (result.hasError)
        return err!RunReport(result.error);

    return ok(report);
}
