/**
The about page (`TPG1`–`TPG3`, mockup C1): which build is running — the
name, the version and short commit, the build type, libghostty-vt's version
and build options, the renderer, and on Android the package id,
`versionCode`, ABI and API level, the same facts `logBuildInfo` logs at start
— and the way to the source, the docs and the credits, opened through the
link allow-list (`TPR6`).

The facts are gathered once ($(LREF gatherAboutFacts)); the page only shows
them ($(LREF AboutPage)), so a test can give it any.

Keys (`KBD1`): arrows scroll, `s` source, `d` docs, `c` credits, `y` copies
the facts (for a bug report).
*/
module about_page;

import sparkles.input.events : Key, KeyEvent;
import sparkles.ui.geometry : Insets, Rect, SizeSpec;
import sparkles.ui.style : Decoration, Slot, TextStyle;
import sparkles.ui.widget : Alignment, Builder, Widget, WidgetKind, WidgetTree;

import chrome : button, column, label, row;
import page_kit : bodyRowsFor, finishPage, firstOwnHit, header, Page, PageServices, prose;
import surfaces : SurfaceContext;

/// Where the about page's links lead.
enum sourceUrl = "https://github.com/PetarKirov/sparkles";
/// ditto
enum docsUrl = "https://sparkles.petar-kirov.dev/apps/terminal/";
/// ditto — the credits document (`TPG12`), until the app renders it (`TPG15`)
enum creditsUrl = "https://sparkles.petar-kirov.dev/credits/terminal";

/// What the about page shows (`TPG1`).
struct AboutFacts
{
    string name = "sparkles:terminal";
    string version_ = "dev";
    string commit; /// the commit label: a hash, `… + uncommitted changes`, or `unknown commit`
    string buildType; /// `debug`, `checked` or `release`
    string vtVersion; /// libghostty-vt's, as the build stamped it; empty: unknown
    bool vtSimd;
    string vtOptimize;
    string renderer; /// `raylib 6.0 · OpenGL 3.3`
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

    /// The facts as `label: value` pairs, in the page's order.
    string[2][] rows() const @safe pure
    {
        import std.conv : text;

        string[2][] r;
        r ~= ["Version", version_];
        r ~= ["Commit", commit.length ? commit : "unknown commit"];
        r ~= ["Build type", buildType];
        r ~= ["libghostty-vt", vtVersion.length ? vtVersion : "unknown version"];
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

    /// The facts as plain text, one per line (Copy).
    string text() const @safe pure
    {
        string s = name ~ " " ~ summary ~ "\n";
        foreach (kv; rows)
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
Gathers the facts: the build stamp of this compilation (`TPG2`), the linked
libghostty-vt's build options, the GL version raylib runs on, and on Android
the package manager's answer (a JNI round trip — call it once).
*/
AboutFacts gatherAboutFacts() @system
{
    import raylib : RAYLIB_VERSION;
    import raylib.rlgl : rlGetVersion, rlGlVersion;
    import sparkles.base.build_stamp : buildStampOf;
    import sparkles.terminal_view.core : ghosttyBuild;

    enum stamp = buildStampOf!();
    AboutFacts f;
    f.version_ = stamp.version_;
    f.commit = stamp.commitLabel;
    f.buildType = buildTypeName;
    f.vtVersion = stamp.componentVersion("libghostty-vt");
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
    f.renderer = "raylib " ~ RAYLIB_VERSION ~ " · " ~ gl;

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

/// Hit ids.
private enum Hit : size_t
{
    source = firstOwnHit,
    docs,
    credits,
    copy,
}

/// The about page.
final class AboutPage : Page
{
    private AboutFacts facts;

    this(AboutFacts facts, PageServices services) @safe
    {
        super(services);
        this.facts = facts;
    }

    override WidgetTree buildPage(in SurfaceContext ctx, int cols, int rows) @safe
    {
        Builder b;
        uint[] actions;
        if (services.copy !is null)
            actions ~= button(b, "⧉", "Copy", ctx.labels, Hit.copy, minRows: ctx.targetRows);
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

        // The links (`TPG3`).
        uint[] links = [
            button(b, "⌥", "Source", ctx.labels, Hit.source, minRows: ctx.targetRows),
            button(b, "?", "Docs", ctx.labels, Hit.docs, minRows: ctx.targetRows),
            button(b, "♥", "Credits", ctx.labels, Hit.credits, minRows: ctx.targetRows),
        ];
        items ~= b.add(Widget(kind: WidgetKind.row, children: links, gap: 1));
        items ~= blank(b);

        // The facts, as a two-column list (`TPG1`).
        items ~= label(b, "Build", Slot.textPrimary, bold: true);
        size_t keyWidth;
        foreach (kv; facts.rows)
            if (kv[0].length > keyWidth)
                keyWidth = kv[0].length;
        foreach (kv; facts.rows)
        {
            string k = kv[0];
            while (k.length < keyWidth + 2)
                k ~= ' ';
            items ~= row(b, [label(b, k, Slot.muted), prose(b, kv[1], Slot.code)], 0);
        }
        items ~= blank(b);
        items ~= prose(b, "Credits list every component the terminal ships and how it uses "
            ~ "it, with its licence — docs/credits/terminal.md.", Slot.textSecondary);

        const content = b.add(Widget(kind: WidgetKind.column, children: items,
            width: SizeSpec.grow(), padding: Insets(1, 0, 0, 0)));
        viewRows = bodyRowsFor(b, [head], null, cols, rows);
        return finishPage(b, [head], content, null, viewRows, scroll, cols, rows);
    }

    private static uint blank(ref Builder b) @safe
        => b.add(Widget(kind: WidgetKind.box, height: SizeSpec.fixed(1)));

    override bool onHit(size_t id) @system
    {
        switch (id)
        {
            case Hit.source:
                open(sourceUrl);
                break;
            case Hit.docs:
                open(docsUrl);
                break;
            case Hit.credits:
                open(creditsUrl);
                break;
            case Hit.copy:
                if (services.copy !is null)
                {
                    services.copy(facts.text);
                    if (services.toast !is null)
                        services.toast("Copied the build facts");
                }
                break;
            default:
                break;
        }
        return false;
    }

    private void open(string url) @system
    {
        if (services.openUri !is null)
            services.openUri(url);
    }

    override bool onKey(in KeyEvent k) @system
    {
        if (k.key != Key.char_)
            return false;
        switch (k.ch)
        {
            case 's': return !onHit(Hit.source);
            case 'd': return !onHit(Hit.docs);
            case 'c': return !onHit(Hit.credits);
            case 'y': return !onHit(Hit.copy);
            default: return false;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

@("about_page.AboutFacts.summaryAndRows")
@safe pure unittest
{
    AboutFacts f = {version_: "0.1.0", commit: "e1385e6f", buildType: "checked",
        vtVersion: "0.1.0-dev+4749c4e", vtSimd: true, vtOptimize: "ReleaseFast",
        renderer: "raylib 6.0 · OpenGL ES 3.0", platform: "android arm64-v8a",
        packageName: "dev.petar_kirov.sparkles.terminal", versionCode: 20261002,
        apiLevel: 34};
    assert(f.summary == "0.1.0 · e1385e6f · checked · android arm64-v8a · API 34");
    const t = f.text;
    import std.algorithm.searching : canFind;

    assert(t.canFind("libghostty-vt: 0.1.0-dev+4749c4e\n"));
    assert(t.canFind("VT build: ReleaseFast, SIMD on\n"));
    assert(t.canFind("versionCode: 20261002\n"));
    assert(t.canFind("Package: dev.petar_kirov.sparkles.terminal\n"));

    // On the desktop the Android rows are absent; an unstamped build says so.
    AboutFacts d = {buildType: "debug", platform: "linux x86_64"};
    assert(!d.text.canFind("versionCode") && !d.text.canFind("API level"));
    assert(d.text.canFind("Commit: unknown commit") && d.text.canFind("unknown version"));
}

@("about_page.buildTypeName.thisBuild")
@safe pure nothrow @nogc unittest
{
    // `dub test` builds `debug` (docs/guidelines: debug to test).
    debug assert(buildTypeName == "debug");
}

@("about_page.AboutPage.linksGoThroughTheService")
@system unittest
{
    import chrome : place, Place;

    string[] opened;
    PageServices s;
    s.openUri = (string u) { opened ~= u; };
    auto p = new AboutPage(AboutFacts(version_: "0.1.0"), s);
    SurfaceContext ctx;
    ctx.cellW = ctx.cellH = 1;
    ctx.area = Rect(0, 0, 60, 30);
    const l = place(p.build(ctx, 60), 60, 30, 0, 0, 1, 1, Place.top);
    bool sawVersion, sawSource;
    foreach (ref n; l.tree.nodes)
    {
        sawVersion |= n.text == "0.1.0";
        sawSource |= n.text == "⌥ Source";
    }
    assert(sawVersion && sawSource);
    size_t hits;
    foreach (ref t; l.hits)
        hits += t.hitId == Hit.source || t.hitId == Hit.docs || t.hitId == Hit.credits;
    assert(hits == 3);
    assert(p.key(KeyEvent(Key.char_, 's')) && p.key(KeyEvent(Key.char_, 'c')));
    assert(opened == [sourceUrl, creditsUrl]);
}
