/**
Links (`TPR5`–`TPR7`): which may open, opening them, and the confirmation a tap
on one shows.

$(B Open launches only an allowed scheme) (`TPR6`): `http`, `https` and
`mailto`, plus `links.schemes`. Anything else gets Copy (and Share on a phone)
but no Open; on Android a `file:` URI is refused, as `termux-open` refuses it
(NOD18). What is shown is the URI that opens, never the link's text.

The confirmation is mockup L1 as a card anchored at the link (above or below
it, never over it) and L2 as a sheet, by `ui.overlayStyle` (`TCF10`).
*/
module links;

import sparkles.ui.geometry : Rect;
import sparkles.ui.style : Slot;
import sparkles.ui.widget : Builder, Widget, WidgetKind, WidgetTree;
import sparkles.ui.wrap : TextWrap;
import sparkles.input.events : KeyEvent;

import chrome : band, button, label, row;
import settings : OverlayStyle;
import surfaces : Anchored, Placement, Surface, SurfaceContext;

/// `uri`'s scheme, lower-cased; empty when it has none.
string schemeOf(scope const(char)[] uri) @safe pure
{
    import std.ascii : isAlpha, isAlphaNum, toLower;

    foreach (i, c; uri)
    {
        if (c == ':')
        {
            if (i == 0 || !isAlpha(uri[0]))
                return null;
            char[] s = new char[i];
            foreach (j; 0 .. i)
                s[j] = toLower(uri[j]);
            return (() @trusted => cast(string) s)();
        }
        if (!(isAlphaNum(c) || c == '+' || c == '-' || c == '.'))
            return null;
    }
    return null;
}

/// Whether Open may launch `uri` (`TPR6`).
bool canOpen(scope const(char)[] uri, in string[] extraSchemes, bool android) @safe pure
{
    const s = schemeOf(uri);
    if (!s.length)
        return false;
    if (android && s == "file")
        return false;
    if (s == "http" || s == "https" || s == "mailto")
        return true;
    foreach (e; extraSchemes)
        if (schemeOf(e ~ ":") == s)
            return true;
    return false;
}

/// Opens `uri` with the platform's handler: the desktop's opener, Android's
/// VIEW intent. The caller has checked `canOpen`.
void openUri(string uri) @system
{
    version (Android)
    {
        import sparkles.android.intents : viewUri;

        cast(void) viewUri(uri);
    }
    else
    {
        import std.string : toStringz;

        import sparkles.terminal_view.posix_util : spawnDetached;

        version (OSX)
            static immutable opener = "open\0";
        else
            static immutable opener = "xdg-open\0";
        const(char)*[3] argv = [opener.ptr, uri.toStringz, null];
        cast(void) spawnDetached(argv[]);
    }
}

/// Hit ids.
private enum Hit : size_t
{
    none,
    open = 0x11C0,
    copy,
    share,
    cancel,
}

/// The confirmation a tap on a link shows (`TPR5`): L1 as a card, L2 as a
/// sheet.
final class LinkConfirm : Surface, Anchored
{
    private string uri;
    private bool hyperlink, openable, shareable;
    private string from;
    private Rect where;
    private void delegate(string) @system copy;

    /**
    `uri` is what opens; `hyperlink` says it came from OSC 8; `openable` is
    `canOpen`'s answer; `from` names the pane's directory; `where` is the
    link's pixel span (the card's subject); `copy` puts text on the
    clipboard.
    */
    this(string uri, bool hyperlink, bool openable, bool shareable, string from, Rect where,
        void delegate(string) @system copy) @safe pure nothrow
    {
        this.uri = uri;
        this.hyperlink = hyperlink;
        this.openable = openable;
        this.shareable = shareable;
        this.from = from;
        this.where = where;
        this.copy = copy;
    }

    Rect anchor() const @safe => where;

    WidgetTree build(in SurfaceContext ctx, int cols) @safe
    {
        Builder b;
        uint[] lines;
        const scheme = schemeOf(uri);
        uint[] buttons;
        if (ctx.style == OverlayStyle.anchored)
        {
            // L1: what kind of link, the whole URI, the actions.
            lines ~= label(b, (hyperlink ? "OSC 8 link · " : "link · ") ~ scheme, Slot.muted);
            lines ~= prose(b, uri, Slot.link);
        }
        else
        {
            // L2: the question, the host in bold, where it came from.
            lines ~= label(b, "Open this link?", Slot.textPrimary, bold: true);
            const host = hostOf(uri);
            lines ~= row(b, [label(b, host, Slot.textPrimary, bold: true),
                label(b, uri[(uri.length - restOf(uri).length) .. $][host.length .. $],
                    Slot.textSecondary)], gap: 0);
            lines ~= prose(b, (from.length ? "From the terminal output of " ~ from ~ ". " : "")
                ~ "The address shown is the one that opens.", Slot.textSecondary);
        }
        buttons ~= button(b, "⧉", "Copy", ctx.labels, Hit.copy, minRows: ctx.targetRows);
        if (shareable)
            buttons ~= button(b, "↗", "Share", ctx.labels, Hit.share, minRows: ctx.targetRows);
        if (ctx.style != OverlayStyle.anchored)
            buttons ~= button(b, "✕", "Cancel", ctx.labels, Hit.cancel, minRows: ctx.targetRows);
        if (openable)
            buttons ~= button(b, "↗", ctx.style == OverlayStyle.anchored ? "Open" : "Open in browser",
                ctx.labels, Hit.open, primary: true, minRows: ctx.targetRows);
        else
            lines ~= label(b, "Only http, https and mailto links open (and links.schemes).",
                Slot.muted);
        lines ~= row(b, buttons);
        return b.finish(band(b, lines, fullWidth: ctx.style != OverlayStyle.anchored));
    }

    Placement placement() const @safe => Placement.anchored;

    bool activate(size_t id) @system
    {
        switch (id)
        {
            case Hit.open:
                if (openable)
                    openUri(uri);
                return true;
            case Hit.copy:
                if (copy !is null)
                    copy(uri);
                return true;
            case Hit.share:
                version (Android)
                {
                    import sparkles.android.intents : shareText;

                    cast(void) shareText(uri);
                }
                return true;
            case Hit.cancel:
                return true;
            default:
                return false;
        }
    }

    bool confirm() @system => activate(openable ? Hit.open : Hit.copy);
    void cancel() @system {}
    bool key(in KeyEvent k) @system => false;

    private static uint prose(ref Builder b, const(char)[] text, Slot slot) @safe
        => b.add(Widget(kind: WidgetKind.text, text: text, slot: slot, wrap: TextWrap.greedy));
}

/// The part after the scheme's `//` (or `:`).
private const(char)[] restOf(string uri) @safe pure
{
    import std.algorithm.searching : findSplitAfter;

    if (auto r = uri.findSplitAfter("://"))
        return r[1];
    if (auto r = uri.findSplitAfter(":"))
        return r[1];
    return uri;
}

/// The host of a URL (`sparkles.petar-kirov.dev` in `https://sparkles…/docs`).
private string hostOf(string uri) @safe pure
{
    const rest = restOf(uri);
    foreach (i, c; rest)
        if (c == '/' || c == '?' || c == '#')
            return rest[0 .. i].idup;
    return rest.idup;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests.
// ─────────────────────────────────────────────────────────────────────────────

@("links.canOpen.theAllowList")
@safe pure unittest
{
    assert(canOpen("https://example.org", null, false));
    assert(canOpen("MAILTO:me@example.org", null, false));
    assert(!canOpen("javascript:alert(1)", null, false), "TPR6's violation case");
    assert(!canOpen("ssh://host", null, false));
    assert(canOpen("ssh://host", ["ssh"], false), "links.schemes widens it");
    assert(canOpen("file:///tmp/a", ["file"], false));
    assert(!canOpen("file:///tmp/a", ["file"], true), "Android refuses file: (NOD18)");
    assert(!canOpen("no scheme here", null, false));
    assert(schemeOf("HTTPS://x") == "https" && schemeOf("a b:c") is null);
}

@("links.LinkConfirm.cardAndSheet")
@system unittest
{
    import std.algorithm.searching : canFind;

    import chrome : place, Place;

    auto l = new LinkConfirm("https://sparkles.petar-kirov.dev/docs", true, true, false,
        "~/sparkles", Rect(0, 0, 10, 1), null);
    SurfaceContext card = {style: OverlayStyle.anchored};
    const(char)[][] texts;
    foreach (ref n; place(l.build(card, 60), 60, 10, 0, 0, 1, 1, Place.top).tree.nodes)
        texts ~= n.text;
    assert(texts.canFind("OSC 8 link · https") && texts.canFind("⧉ Copy") && texts.canFind("↗ Open"));

    SurfaceContext sheet = {style: OverlayStyle.sheet};
    texts = null;
    foreach (ref n; place(l.build(sheet, 60), 60, 10, 0, 0, 1, 1, Place.top).tree.nodes)
        texts ~= n.text;
    assert(texts.canFind("Open this link?") && texts.canFind("sparkles.petar-kirov.dev")
        && texts.canFind("/docs") && texts.canFind("↗ Open in browser"));

    // A disallowed scheme has no Open (`TPR6`).
    auto js = new LinkConfirm("javascript:alert(1)", true, false, false, null, Rect.init, null);
    texts = null;
    foreach (ref n; place(js.build(card, 60), 60, 10, 0, 0, 1, 1, Place.top).tree.nodes)
        texts ~= n.text;
    assert(!texts.canFind("↗ Open"));
}
