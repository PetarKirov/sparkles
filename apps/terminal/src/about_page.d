/**
The about page (`TPG1`–`TPG3`, mockup C1): which build is running — the
name, the version and short commit, the build type, then the direct
components as a read-only property tree, then the probes (libghostty-vt's
build options, the GL string, the platform, and on Android the package id,
`versionCode` and API level) — and the links the build document names,
opened through the link allow-list (`TPR6`).

Identity, links and components come from the process's build document
($(LREF processBuild)). The probes are gathered once
($(LREF gatherAboutFacts)); the page only shows them ($(LREF AboutPage)).

Keys (`KBD1`): arrows scroll, `s` source, `d` docs, `c` credits, `y` copies
the facts (for a bug report).
*/
module about_page;

import std.algorithm.sorting : sort;
import std.array : appender;

import sparkles.core_cli.build_info : BuildInfo, BuildLoad, JsonSubject,
    buildInfoFromJSON, buildInfoSection;
import sparkles.wired.json.document : JsonKind;
import sparkles.input.events : Key, KeyEvent;
import sparkles.ui.components.property_view : propertyView, writePropertyText;
import sparkles.ui.components.tree_view : TreeViewState;
import sparkles.ui.geometry : Insets, Rect, SizeSpec;
import sparkles.ui.property_tree : PropertyEditState, PropertyTree, PropertyTreePolicy;
import sparkles.ui.state : DisclosureState;
import sparkles.ui.style : Decoration, Slot, TextStyle;
import sparkles.ui.widget : Alignment, Builder, Widget, WidgetKind, WidgetTree;

import chrome : button, column, label, row;
import page_kit : bodyRowsFor, finishPage, firstOwnHit, header, Page, PageServices, prose;
import surfaces : SurfaceContext;

/// The process's document. Startup sets it once; about pages borrow it.
/// It is not moved again, so a frame-local `JsonValue` stays valid.
BuildLoad processBuild;

/**
Reads the build-info section at `path`. A missing section, an unreadable
file, or a section that does not decode becomes the unstamped facts, and
the decode error is logged. The app still starts.
*/
void adoptBuild(scope const(char)[] path)
{
    import core.lifetime : move;

    import sparkles.base.logger : warning;

    if (!path.length)
    {
        processBuild = BuildLoad.unstamped();
        return;
    }
    auto section = buildInfoSection(path);
    if (section is null)
    {
        processBuild = BuildLoad.unstamped();
        return;
    }
    auto load = buildInfoFromJSON(cast(const(char)[]) section);
    if (!load.hasValue)
    {
        const msg = load.error.toString();
        warning(i"build info: $(msg)");
        processBuild = BuildLoad.unstamped();
        return;
    }
    processBuild = move(load);
}

/// What the about page shows (`TPG1`). Identity comes from the document;
/// the probes are what the document cannot know.
struct AboutFacts
{
    string name = "sparkles:terminal";
    string version_ = "dev";
    string commit; /// the commit label: a hash, `… + uncommitted changes`, or `unknown commit`
    string buildType; /// `debug`, `checked` or `release`
    bool vtSimd;
    string vtOptimize;
    string renderer; /// the GL string (`OpenGL 3.3`); raylib's version is a component
    string platform; /// `linux x86_64`, `android arm64-v8a`
    // Android only.
    string packageName;
    int versionCode = -1;
    string versionName;
    int apiLevel;

    /// `0.1.0 · 4f2c1aa · checked · arm64-v8a · API 34` — the line under the
    /// name.
    string summary() const @safe pure
    {
        import std.conv : text;

        string s = version_;
        if (commit.length)
            s ~= " · " ~ commit;
        if (buildType.length)
            s ~= " · " ~ buildType;
        if (platform.length)
            s ~= " · " ~ platform;
        if (apiLevel > 0)
            s ~= text(" · API ", apiLevel);
        return s;
    }

    /// Version, commit, build type (`TPG1`), in that order.
    string[2][] identityRows() const @safe pure
    {
        string[2][] r;
        r ~= ["Version", version_];
        r ~= ["Commit", commit.length ? commit : "unknown commit"];
        r ~= ["Build type", buildType];
        return r;
    }

    /// The probes, after the component tree.
    string[2][] probeRows() const @safe pure
    {
        import std.conv : text;

        string[2][] r;
        r ~= ["VT build", text(vtOptimize.length ? vtOptimize : "unknown", ", SIMD ",
            vtSimd ? "on" : "off")];
        r ~= ["Renderer", renderer];
        r ~= ["Platform", platform];
        if (packageName.length)
            r ~= ["Package", packageName];
        if (versionCode >= 0)
            r ~= ["versionCode", text(versionCode, versionName.length ? " (" ~ versionName ~ ")" : "")];
        if (apiLevel > 0)
            r ~= ["API level", text(apiLevel)];
        return r;
    }

    /// Identity and probes as plain text. The component tree is not here;
    /// $(LREF AboutPage.copyText) writes it between the two.
    string text() const @safe pure
    {
        string s = name ~ " " ~ summary ~ "\n";
        foreach (kv; identityRows ~ probeRows)
            s ~= kv[0] ~ ": " ~ kv[1] ~ "\n";
        return s;
    }
}

/// The build type this binary was compiled as: `debug` compiles `debug {}`
/// blocks in, `checked` keeps assertions, `release` has neither.
string buildTypeName() @safe pure nothrow @nogc
{
    debug
        return "debug";
    else
    {
        version (assert)
            return "checked";
        else
            return "release";
    }
}

/// The device's ABI as Android names it, or the CPU architecture elsewhere.
string abiName() @safe pure nothrow @nogc
{
    version (AArch64)
        return "arm64-v8a";
    else version (ARM)
        return "armeabi-v7a";
    else version (X86_64)
        return "x86_64";
    else version (X86)
        return "x86";
    else
        return "unknown";
}

/**
Gathers the probes, and copies identity from `info`. An empty name stays
`sparkles:terminal`. An empty build type uses this compilation's
($(LREF buildTypeName)): a `dub` build has no section to name one.
*/
AboutFacts gatherAboutFacts(BuildInfo info) @system
{
    import raylib.rlgl : rlGetVersion, rlGlVersion;
    import sparkles.terminal_view.core : ghosttyBuild;

    AboutFacts f;
    if (info.name.length)
        f.name = info.name;
    f.version_ = info.version_;
    f.commit = info.commitLabel;
    f.buildType = info.buildType.length ? info.buildType : buildTypeName;
    const vt = ghosttyBuild();
    f.vtSimd = vt.simd;
    f.vtOptimize = vt.optimize;

    string gl;
    switch (rlGetVersion())
    {
        case rlGlVersion.RL_OPENGL_11: gl = "OpenGL 1.1"; break;
        case rlGlVersion.RL_OPENGL_21: gl = "OpenGL 2.1"; break;
        case rlGlVersion.RL_OPENGL_33: gl = "OpenGL 3.3"; break;
        case rlGlVersion.RL_OPENGL_43: gl = "OpenGL 4.3"; break;
        case rlGlVersion.RL_OPENGL_ES_20: gl = "OpenGL ES 2.0"; break;
        case rlGlVersion.RL_OPENGL_ES_30: gl = "OpenGL ES 3.0"; break;
        default: gl = "software"; break;
    }
    f.renderer = gl;

    version (Android)
    {
        import sparkles.android.activity : sdkVersion;
        import sparkles.android.package_info : packageInfo;

        f.platform = "android " ~ abiName;
        f.apiLevel = sdkVersion();
        const p = packageInfo();
        f.packageName = p.packageName;
        f.versionCode = p.versionCode;
        f.versionName = p.versionName;
    }
    else version (OSX)
        f.platform = "macos " ~ abiName;
    else version (linux)
        f.platform = "linux " ~ abiName;
    else
        f.platform = abiName;
    return f;
}

/// Hit id of the copy button. Link buttons are `firstOwnHit` plus the
/// sorted-key index, and there are not 256 of them.
private enum copyHit = firstOwnHit + 256;

/// The about page.
final class AboutPage : Page
{
    private AboutFacts facts;
    private BuildLoad* load;
    private PropertyTree!JsonSubject tree;
    private TreeViewState!string componentView;

    this(AboutFacts facts, BuildLoad* load, PageServices services) @safe
    {
        super(services);
        this.facts = facts;
        this.load = load;
    }

    override WidgetTree buildPage(in SurfaceContext ctx, int cols, int rows) @safe
    {
        Builder b;
        uint[] actions;
        if (services.copy !is null)
            actions ~= button(b, "⧉", "Copy", ctx.labels, copyHit, minRows: ctx.targetRows);
        const head = header(b, "About", ctx, actions);

        uint[] items;
        // The identity: a mark, the name, the one-line summary (C1).
        const mark = b.add(Widget(kind: WidgetKind.panel,
            children: [label(b, ">_", Slot.accentPrimary, bold: true)],
            padding: Insets(0, 1, 0, 1), alignX: Alignment.center, alignY: Alignment.center,
            height: SizeSpec.fixed(ctx.targetRows > 2 ? ctx.targetRows : 2),
            slot: Slot.surfaceRaised, paintBackground: true,
            decoration: Decoration(borderRadius: 10)));
        const who = column(b, [label(b, facts.name, Slot.textPrimary, bold: true),
            prose(b, facts.summary, Slot.muted)]);
        items ~= row(b, [mark, who], 2);
        items ~= blank(b);

        // One button per link, sorted by name (`credits`, `docs`, `source`).
        auto keys = sortedLinkKeys();
        if (keys.length)
        {
            uint[] links;
            foreach (i, key; keys)
                links ~= button(b, linkIcon(key), linkCaption(key), ctx.labels,
                    firstOwnHit + i, minRows: ctx.targetRows);
            items ~= b.add(Widget(kind: WidgetKind.row, children: links, gap: 1));
            items ~= blank(b);
        }

        items ~= label(b, "Build", Slot.textPrimary, bold: true);
        addRows(b, items, facts.identityRows);
        items ~= blank(b);

        items ~= label(b, "Components", Slot.textPrimary, bold: true);
        if (fillComponents(cols))
        {
            PropertyEditState edits;
            items ~= propertyView(b, tree.data, componentView, edits, hitBase: firstOwnHit + 512);
        }
        items ~= blank(b);

        addRows(b, items, facts.probeRows);
        items ~= blank(b);
        items ~= prose(b, "Credits list every component the terminal ships and how it uses "
            ~ "it, with its licence — docs/credits/terminal.md.", Slot.textSecondary);

        const content = b.add(Widget(kind: WidgetKind.column, children: items,
            width: SizeSpec.grow(), padding: Insets(1, 0, 0, 0)));
        viewRows = bodyRowsFor(b, [head], null, cols, rows);
        return finishPage(b, [head], content, null, viewRows, scroll, cols, rows);
    }

    /// Identity, then the component tree, then the probes.
    string copyText() @safe
    {
        auto w = appender!string;
        w.put(facts.name ~ " " ~ facts.summary ~ "\n");
        foreach (kv; facts.identityRows)
            w.put(kv[0] ~ ": " ~ kv[1] ~ "\n");
        if (fillComponents(80))
        {
            PropertyEditState edits;
            writePropertyText(w, tree.data, componentView.rows, componentView, edits);
        }
        foreach (kv; facts.probeRows)
            w.put(kv[0] ~ ": " ~ kv[1] ~ "\n");
        return w[];
    }

    private static uint blank(ref Builder b) @safe
        => b.add(Widget(kind: WidgetKind.box, height: SizeSpec.fixed(1)));

    private static void addRows(ref Builder b, ref uint[] items, string[2][] rows) @safe
    {
        size_t keyWidth;
        foreach (kv; rows)
            if (kv[0].length > keyWidth)
                keyWidth = kv[0].length;
        foreach (kv; rows)
        {
            string k = kv[0];
            while (k.length < keyWidth + 2)
                k ~= ' ';
            items ~= row(b, [label(b, k, Slot.muted), prose(b, kv[1], Slot.code)], 0);
        }
    }

    private string[] sortedLinkKeys() const @safe
    {
        if (load is null)
            return null;
        auto keys = load.info.links.keys;
        sort(keys);
        return keys;
    }

    private string linkUrl(string key) const @safe
    {
        if (load is null)
            return null;
        if (auto v = key in load.info.links)
            return *v;
        return null;
    }

    /// Rebuilds the read-only component tree from the borrowed document.
    /// An absent `components` object yields no rows.
    private bool fillComponents(int width) @safe
    {
        if (load is null)
            return false;
        auto comps = load.components();
        if (comps.kind != JsonKind.object || comps.length == 0)
            return false;
        auto subject = JsonSubject(comps);
        tree.policy = PropertyTreePolicy(readOnly: true);
        componentView.open = DisclosureState!string.allOpen;
        componentView.top = 0;
        componentView.height = 10_000;
        componentView.chromeRows = 0;
        componentView.headerRows = 0;
        componentView.width = width > 0 ? width : 80;
        componentView.scrollGutterV = 0;
        componentView.scrollGutterH = 0;
        tree.rebuild(subject, componentView);
        return componentView.rows.length > 0;
    }

    override bool onHit(size_t id) @system
    {
        if (id == copyHit)
            return copyFacts();
        auto keys = sortedLinkKeys();
        if (id >= firstOwnHit && id < firstOwnHit + keys.length)
        {
            open(linkUrl(keys[id - firstOwnHit]));
            return true;
        }
        return false;
    }

    private bool copyFacts() @system
    {
        if (services.copy is null)
            return false;
        services.copy(copyText);
        if (services.toast !is null)
            services.toast("Copied the build facts");
        return true;
    }

    private void open(string url) @system
    {
        if (url.length && services.openUri !is null)
            services.openUri(url);
    }

    private bool openNamed(string key) @system
    {
        auto url = linkUrl(key);
        if (!url.length)
            return false;
        open(url);
        return true;
    }

    override bool onKey(in KeyEvent k) @system
    {
        if (k.key != Key.char_)
            return false;
        switch (k.ch)
        {
            case 's': return openNamed("source");
            case 'd': return openNamed("docs");
            case 'c': return openNamed("credits");
            case 'y': return copyFacts();
            default: return false;
        }
    }
}

private string linkIcon(string key) @safe pure nothrow @nogc
{
    switch (key)
    {
        case "source": return "⌥";
        case "docs": return "?";
        case "credits": return "♥";
        default: return "•";
    }
}

private string linkCaption(string key) @safe pure nothrow
{
    if (key.length == 0)
        return key;
    char first = key[0];
    if (first >= 'a' && first <= 'z')
        first = cast(char) (first - 32);
    return first ~ key[1 .. $];
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

@("about_page.AboutFacts.summaryAndRows")
@safe pure unittest
{
    AboutFacts f = {
        version_: "0.1.0", commit: "e1385e6f", buildType: "checked",
        vtSimd: true, vtOptimize: "ReleaseFast",
        renderer: "OpenGL ES 3.0", platform: "android arm64-v8a",
        packageName: "dev.petar_kirov.sparkles.terminal.nix", versionCode: 20261002,
        apiLevel: 34
    };
    assert(f.summary == "0.1.0 · e1385e6f · checked · android arm64-v8a · API 34");
    const t = f.text;
    import std.algorithm.searching : canFind;
    import std.string : indexOf;

    assert(t.canFind("Version: 0.1.0\n"));
    assert(t.canFind("VT build: ReleaseFast, SIMD on\n"));
    assert(t.canFind("Renderer: OpenGL ES 3.0\n"));
    assert(t.canFind("versionCode: 20261002\n"));
    assert(t.canFind("Package: dev.petar_kirov.sparkles.terminal.nix\n"));
    // Identity, then probes. The component tree is not part of AboutFacts.
    assert(indexOf(t, "Build type:") < indexOf(t, "VT build:"));

    // On the desktop the Android rows are absent; an unstamped build says so.
    AboutFacts d = { buildType: "debug", platform: "linux x86_64" };
    assert(!d.text.canFind("versionCode") && !d.text.canFind("API level"));
    assert(d.text.canFind("Commit: unknown commit"));
}

@("about_page.buildTypeName.thisBuild")
@safe pure nothrow @nogc unittest
{
    // `dub test` builds `debug` (docs/guidelines: debug to test).
    debug assert(buildTypeName == "debug");
}

@("about_page.AboutPage.linksAndUnnamedComponent")
@system unittest
{
    import std.algorithm.searching : canFind;
    import std.string : indexOf;

    import chrome : place, Place;

    enum sourceUrl = "https://example.test/source";
    enum creditsUrl = "https://example.test/credits";
    enum storePath = "/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-extra-lib-1.2.3";

    auto load = buildInfoFromJSON(`{
        "version": "0.1.0",
        "links": {
            "source": "https://example.test/source",
            "docs": "https://example.test/docs",
            "credits": "https://example.test/credits"
        },
        "components": {
            "extra-lib": { "version": "1.2.3", "storePath": "` ~ storePath ~ `", "note": "kept" }
        }
    }`);
    assert(load.hasValue, load.error.toString());

    string[] opened;
    PageServices s;
    s.openUri = (string u) { opened ~= u; };
    s.copy = (string) {};
    AboutFacts facts = { version_: "0.1.0", commit: "e1385e6f", buildType: "checked" };
    auto p = new AboutPage(facts, &load, s);
    SurfaceContext ctx;
    ctx.cellW = ctx.cellH = 1;
    ctx.area = Rect(0, 0, 80, 40);
    const l = place(p.build(ctx, 80), 80, 40, 0, 0, 1, 1, Place.top);
    bool sawVersion, sawSource;
    foreach (ref n; l.tree.nodes)
    {
        sawVersion |= n.text == "0.1.0";
        sawSource |= n.text == "⌥ Source";
    }
    assert(sawVersion && sawSource);
    size_t hits;
    foreach (ref t; l.hits)
        hits += t.hitId == firstOwnHit || t.hitId == firstOwnHit + 1 || t.hitId == firstOwnHit + 2;
    assert(hits == 3);
    assert(p.key(KeyEvent(Key.char_, 's')) && p.key(KeyEvent(Key.char_, 'c')));
    assert(opened == [sourceUrl, creditsUrl]);

    const copied = p.copyText;
    assert(copied.canFind("Version: 0.1.0\n"));
    assert(copied.canFind("extra-lib"));
    assert(copied.canFind(storePath));
    assert(copied.canFind("kept"));
    assert(indexOf(copied, "Build type:") < indexOf(copied, storePath));
    assert(indexOf(copied, storePath) < indexOf(copied, "VT build:"));
}
