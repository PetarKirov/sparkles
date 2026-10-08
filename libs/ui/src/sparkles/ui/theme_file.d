/**
The theme file (`FMT1`–`FMT6`): a $(REF Theme, sparkles,ui,theme) as a
Design Tokens Community Group document, edition 2025.10.

$(B Layout.) A slot is a group at its token path whose leaves are `fg` and
`bg` color tokens; an interaction state is a group inside the slot
(`scrollbar.thumb.hover.bg`), its text attributes in the state group's
`$extensions`. Page colors are `page.fg` and `page.bg`. A syntax rule is a
group at `syntax.<selector>` with the same `fg`/`bg` leaves and its
attributes and underline in the group's `$extensions`, so a rule that only
sets attributes is a group with no color token. Metrics keep their role-first
paths: cells as `number` tokens, px as `dimension` tokens, font scales as
`number` percentages. The project's own data lives under the
$(LREF extensionKey) namespace.

$(B Overlay.) A file may name a $(I base): a built-in theme or another file.
The base's tokens come first and the file's after them, the later winning per
token — the DTCG resolver module's rule. A file with no base stands alone, and
a slot it leaves unset is derived from its page colors exactly as a theme
built in code derives it. An absent token always means the derived value;
the format has no way to say "unset".

$(B Round trip.) Loading keeps the file's own document beside the resolved
theme, so saving writes its primitives, aliases and unknown extensions back
(`FMT4`). Tokens the theme does not map are kept and reported as warnings.
*/
module sparkles.ui.theme_file;

import std.algorithm.searching : canFind, endsWith, startsWith;
import std.array : appender, join, replace, split;
import std.conv : to;
import std.format : format;
import std.math : round;
import std.traits : getUDAs, hasUDA;

import expected : err, ok;

import sparkles.base.term_color : Color, RgbColor, xterm256ToRgb;
import sparkles.ui.dtcg : collectTokens, colorValue, dimensionValue, DtcgColor,
    DtcgError, DtcgJson, DtcgMember, DtcgResult, DtcgToken, DtcgTokens, parseColor,
    numberOf, parseDimension, parseDtcg, aliasTarget;
import sparkles.ui.style : InteractionState, Palette, Slot;
import sparkles.ui.theme : GlyphSet, StyleSpec, TextAttr, Theme, ThemeRule, UnderlineStyle;
import sparkles.ui.tokens : stateNames, tokenPath;
import sparkles.wired.policy : AnyFormat, resolveCaseStyle, WireNameAttr, wireNames;

@safe:

private enum slotCount = Slot.max + 1;

/// The `$extensions` key this project's data lives under: reverse-domain
/// notation for sparkles.petar-kirov.dev.
enum string extensionKey = "dev.petar-kirov.sparkles";

/// A loaded theme file.
struct ThemeFile
{
    Theme theme;        /// resolved: what the toolkit draws with
    DtcgJson document;  /// the file as written, aliases and all — what `save` writes
    string[] warnings;  /// tokens the theme does not map, kept but unused
}

/// Finds a base theme's document by name: a built-in theme's export or a
/// file's contents. `null` fails every named base.
alias BaseResolver = DtcgResult!DtcgJson delegate(string name) @safe;

// ── vocabulary ──────────────────────────────────────────────────────────────

private enum string[6] attrNames = ["bold", "dim", "italic", "strikethrough", "inverse", "hidden"];
private enum TextAttr[6] attrBits = [TextAttr.bold, TextAttr.dim, TextAttr.italic,
    TextAttr.strikethrough, TextAttr.inverse, TextAttr.hidden];

private alias underlineNames = wireNames!(AnyFormat, UnderlineStyle,
    resolveCaseStyle!(AnyFormat, UnderlineStyle));

// The glyph families (`GLY1`), by their wire names: the `glyphs` object in the
// root extension, which names only the families a theme changes.
private alias familyNames(E) = wireNames!(AnyFormat, E, resolveCaseStyle!(AnyFormat, E));

private enum glyphFamilies = ["frame", "treeGuide", "thumb", "marks"];

/// px-typed metrics (`dimension`); the rest are cells (`number`), except the
/// font scales, which are percentages.
private immutable string[] pxMetrics = ["overlay.radius", "border.width",
    "border.accent.width", "shadow.offset.x", "shadow.offset.y", "shadow.blur", "arrow.size"];

private enum MetricUnit { cell, px, percent }

private MetricUnit unitOf(string path) pure nothrow
    => pxMetrics.canFind(path) ? MetricUnit.px
        : path.endsWith(".font.scale") ? MetricUnit.percent : MetricUnit.cell;

// Every field of `Palette` that carries a token path. Fields only: asking an
// overload set (`stateAlias`) for its attributes is deprecated.
private template metricFields()
{
    import std.meta : Filter;
    import std.traits : FieldNameTuple;
    enum isMetric(string m) = hasUDA!(__traits(getMember, Palette, m), WireNameAttr!AnyFormat);
    alias metricFields = Filter!(isMetric, FieldNameTuple!Palette);
}

private string metricPath(string field)()
    => getUDAs!(__traits(getMember, Palette, field), WireNameAttr!AnyFormat)[0].name;

// A slot's or a state's group must never collide with a channel leaf.
static foreach (s; 0 .. slotCount)
{
    static assert(!tokenPath(cast(Slot) s).endsWith(".fg", ".bg"),
        "a slot path must not end in a channel: " ~ tokenPath(cast(Slot) s));
}

@("theme_file.vocabulary.noPathIsBothASlotAndAState")
@safe unittest
{
    // `<slot>.<state>` must never name another slot, or a state group and a
    // slot group would share a path.
    foreach (s; 0 .. slotCount)
        foreach (st; 1 .. stateNames.length)
            foreach (other; 0 .. slotCount)
                assert(tokenPath(cast(Slot) other)
                    != tokenPath(cast(Slot) s) ~ "." ~ stateNames[st]);
}

// ── export ──────────────────────────────────────────────────────────────────

/**
The document for `t`: page colors, syntax rules, the root extension, and —
only when the theme sets its palette explicitly — every slot, state and
metric. A theme that leaves its palette derived exports without one, so
loading the export derives the same palette (`FMT5`). With
`resolvedPalette`, a derived palette is exported too, resolved: the form a
consumer that has no derivation of its own reads, as the CSS emitter does.
*/
DtcgJson exportTheme(const Theme t, bool resolvedPalette = false)
{
    auto root = DtcgJson.object();
    void put(string path, DtcgJson token)
    {
        auto node = &root;
        foreach (seg; path.split('.'))
        {
            if (node.get(seg) is null)
                node.set(seg, DtcgJson.object());
            node = node.get(seg);
        }
        *node = token;
    }
    DtcgJson* group(string path)
    {
        auto node = &root;
        foreach (seg; path.split('.'))
        {
            if (node.get(seg) is null)
                node.set(seg, DtcgJson.object());
            node = node.get(seg);
        }
        return node;
    }

    // The root extension: the theme's name and its glyph preferences.
    auto ext = DtcgJson.object([DtcgMember("name", DtcgJson.str(t.name))]);
    if (!t.glyphs.unicode)
        ext.set("unicode", DtcgJson.boolean_(false));
    auto families = DtcgJson.object();
    static foreach (field; glyphFamilies)
    {{
        const v = __traits(getMember, t.glyphs, field);
        if (v != __traits(getMember, GlyphSet.init, field))
            families.set(field, DtcgJson.str(familyNames!(typeof(v))[v]));
    }}
    if (families.members.length)
        ext.set("glyphs", families);
    root.set("$extensions", DtcgJson.object([DtcgMember(extensionKey, ext)]));

    if (auto tok = colorToken(t.defaultFg))
        put("page.fg", *tok);
    if (auto tok = colorToken(t.defaultBg))
        put("page.bg", *tok);

    // Syntax rules, last rule winning among equal selectors.
    string[] seen;
    foreach_reverse (ref r; t.rules)
    {
        if (seen.canFind(r.selector))
            continue;
        seen ~= r.selector;
        auto g = group("syntax." ~ r.selector);
        if (auto tok = colorToken(r.style.fg))
            g.set("fg", *tok);
        if (auto tok = colorToken(r.style.bg))
            g.set("bg", *tok);
        auto e = styleExtension(r.style);
        if (e.members.length)
            g.set("$extensions", DtcgJson.object([DtcgMember(extensionKey, e)]));
    }

    if (t.hasPalette || resolvedPalette)
        exportPalette(t.effectivePalette, &group, &put);
    return root;
}

private void exportPalette(const Palette p, DtcgJson* delegate(string) @safe group,
    void delegate(string, DtcgJson) @safe put)
{
    foreach (i; 0 .. slotCount)
    {
        const path = tokenPath(cast(Slot) i);
        if (auto tok = colorToken(p.fg[i], p.fgAlpha[i]))
            put(path ~ ".fg", *tok);
        if (auto tok = colorToken(p.bg[i], p.bgAlpha[i]))
            put(path ~ ".bg", *tok);
        foreach (st; 1 .. stateNames.length)
        {
            const o = p.states[st - 1];
            const sp = path ~ "." ~ stateNames[st];
            if (o.fgAliased[i])
                put(sp ~ ".fg", aliasToken(tokenPath(o.fgFrom[i]) ~ ".fg"));
            else if (auto tok = colorToken(o.fg[i], o.fgAlpha[i]))
                put(sp ~ ".fg", *tok);
            if (o.bgAliased[i])
                put(sp ~ ".bg", aliasToken(tokenPath(o.bgFrom[i]) ~ ".bg"));
            else if (auto tok = colorToken(o.bg[i], o.bgAlpha[i]))
                put(sp ~ ".bg", *tok);
            if (o.attrs[i])
                group(sp).set("$extensions", DtcgJson.object([DtcgMember(extensionKey,
                    DtcgJson.object([DtcgMember("attrs",
                        attrsValue(TextAttr(cast(ubyte) o.attrs[i])))]))]));
        }
    }
    static foreach (f; metricFields!())
        put(metricPath!f, metricToken(metricPath!f, __traits(getMember, p, f)));
}

private DtcgJson* colorToken(const Color c, ubyte alpha = 0xFF)
{
    DtcgJson value;
    auto ext = DtcgJson.object();
    final switch (c.kind)
    {
        case Color.Kind.unset:
        case Color.Kind.default_:
            return null; // the absence of a token is the terminal's own color
        case Color.Kind.rgb:
            value = colorValue(DtcgColor(c.rgb, alpha));
            break;
        case Color.Kind.palette:
            // A terminal-palette index: the xterm value for other tools, the
            // index itself for this one.
            value = colorValue(DtcgColor(xterm256ToRgb(c.index), alpha));
            ext.set("index", DtcgJson.num(c.index));
            break;
    }
    auto tok = new DtcgJson;
    *tok = DtcgJson.object([
        DtcgMember("$type", DtcgJson.str("color")),
        DtcgMember("$value", value),
    ]);
    if (ext.members.length)
        tok.set("$extensions", DtcgJson.object([DtcgMember(extensionKey, ext)]));
    return tok;
}

private DtcgJson aliasToken(string path) pure nothrow
    => DtcgJson.object([
        DtcgMember("$type", DtcgJson.str("color")),
        DtcgMember("$value", DtcgJson.str("{" ~ path ~ "}")),
    ]);

private DtcgJson metricToken(string path, long value)
{
    final switch (unitOf(path))
    {
        case MetricUnit.px:
            return DtcgJson.object([
                DtcgMember("$type", DtcgJson.str("dimension")),
                DtcgMember("$value", dimensionValue(value)),
            ]);
        case MetricUnit.cell:
        case MetricUnit.percent:
            return DtcgJson.object([
                DtcgMember("$type", DtcgJson.str("number")),
                DtcgMember("$value", DtcgJson.num(value)),
                DtcgMember("$extensions", DtcgJson.object([DtcgMember(extensionKey,
                    DtcgJson.object([DtcgMember("unit", DtcgJson.str(
                        unitOf(path) == MetricUnit.cell ? "cell" : "percent"))]))])),
            ]);
    }
}

private DtcgJson attrsValue(TextAttr a)
{
    DtcgJson[] names;
    foreach (i, bit; attrBits)
        if (a & bit)
            names ~= DtcgJson.str(attrNames[i]);
    return DtcgJson.array(names);
}

private DtcgJson styleExtension(const StyleSpec s)
{
    auto e = DtcgJson.object();
    if (s.attrs != TextAttr.none)
        e.set("attrs", attrsValue(s.attrs));
    if (s.underline != UnderlineStyle.none || s.underlineColor.kind != Color.Kind.unset)
    {
        auto u = DtcgJson.object([DtcgMember("style", DtcgJson.str(underlineNames[s.underline]))]);
        if (s.underlineColor.kind == Color.Kind.rgb)
            u.set("color", colorValue(DtcgColor(s.underlineColor.rgb)));
        e.set("underline", u);
    }
    return e;
}

// ── load ────────────────────────────────────────────────────────────────────

/**
Loads a theme file. `base` resolves a named base (`$extensions` →
$(LREF extensionKey) → `base`); a file that names none stands alone. Fails,
naming the path, on malformed JSON or DTCG, a dangling or cyclic alias, a
wrong `$type` on a token the theme maps, or a value out of range (`FMT3`).
*/
DtcgResult!ThemeFile loadTheme(scope const(char)[] text, scope BaseResolver base = null)
{
    auto parsed = parseDtcg(text);
    if (parsed.hasError)
        return err!ThemeFile(parsed.error);
    return loadThemeDocument(parsed.value, base);
}

/// ditto, from a parsed document.
DtcgResult!ThemeFile loadThemeDocument(DtcgJson doc, scope BaseResolver base = null)
{
    ThemeFile file;
    file.document = doc;

    // The overlay: base first, this file after, later token wins.
    auto overlaid = resolvedDocument(doc, base);
    if (overlaid.hasError)
        return err!ThemeFile(overlaid.error);
    auto merged = overlaid.value;

    auto toks = collectTokens(merged);
    if (toks.hasError)
        return err!ThemeFile(toks.error);
    auto tokens = new DtcgTokens;
    *tokens = toks.value;
    auto theme = new Theme;
    auto r = new Mapper(tokens, theme);
    if (auto e = r.run(merged))
        return err!ThemeFile(*e);
    file.theme = *theme;
    file.warnings = r.unmapped();
    return ok!DtcgError(file);
}

/**
The document a file describes with its base applied: the base's tokens first
and the file's after them, the later winning per token. A file with no base is
its own document. `base` resolves a named base to its own resolved document.
*/
DtcgResult!DtcgJson resolvedDocument(DtcgJson doc, scope BaseResolver base)
{
    auto name = baseName(doc);
    if (name is null)
        return ok!DtcgError(doc.dup);
    enum where = "$.$extensions." ~ extensionKey ~ ".base";
    if (base is null)
        return fail!DtcgJson(where, "the file names base " ~ name ~ ", and nothing resolves bases here");
    auto b = base(name);
    if (b.hasError)
        return fail!DtcgJson(where, "base " ~ name ~ ": " ~ b.error.path ~ ": " ~ b.error.message);
    return ok!DtcgError(overlay(b.value, doc));
}

/**
Loads a theme file from disk. Its base, and a base's base, is a built-in
theme's name or a path relative to the directory of the file naming it; a
cycle of bases fails, naming the chain.
*/
DtcgResult!ThemeFile loadThemeFile(string path)
{
    auto doc = readDocument(path);
    if (doc.hasError)
        return err!ThemeFile(doc.error);
    string[] chain = [path];
    return loadThemeDocument(doc.value, fileBases(path, chain));
}

/**
The theme `spec` names: a built-in by name, else a theme file at that path
(`THM9`). The one lookup every application's `--theme` goes through, so a
name and a file are accepted, and refused, the same way everywhere.
*/
ThemeLookup themeNamed(scope const(char)[] spec)
{
    import std.file : exists;
    import sparkles.ui.themes : builtinThemes;

    if (auto t = spec in builtinThemes)
        return ThemeLookup(t);
    // `spec` is `scope` (a caller's `in` options): copy what the result keeps.
    const path = spec.idup;
    if (!exists(path))
        return ThemeLookup(null, DtcgError(null, "no built-in theme or theme file has this name"));
    auto f = loadThemeFile(path);
    if (f.hasError)
        return ThemeLookup(null, f.error);
    auto owned = new Theme;
    *owned = f.value.theme;
    // Sound: `owned` and every array it holds were built by this load and
    // are referenced nowhere else.
    return ThemeLookup(() @trusted { return cast(immutable(Theme)*) owned; }());
}

/**
What $(LREF themeNamed) found: a theme, or the error that says why there is
none: a pointer and an error read as plain fields, with the same
`hasValue`/`value`/`error` surface as an `Expected`.
*/
struct ThemeLookup
{
    immutable(Theme)* value; /// the theme, or `null`
    DtcgError error;         /// why there is none

    /// Why there is no theme, for a message after the spec: the error's path
    /// (a file, and where in it) and what went wrong there.
    string reason() const pure nothrow
        => error.path.length ? error.path ~ ": " ~ error.message : error.message;

    /// Which of the two it is.
    bool hasValue() const pure nothrow @nogc => value !is null;
    /// ditto
    bool hasError() const pure nothrow @nogc => value is null;
}

private DtcgResult!DtcgJson readDocument(string path)
{
    import std.file : readText;

    string text;
    try
        text = readText(path);
    catch (Exception e)
        return fail!DtcgJson(path, "cannot read: " ~ e.msg);
    auto doc = parseDtcg(text);
    if (doc.hasError)
        return fail!DtcgJson(path ~ ": " ~ doc.error.path, doc.error.message);
    return doc;
}

// A resolver for the bases of the file at `from`: built-in names first, then
// paths relative to its directory, each resolved to its own overlaid document.
private BaseResolver fileBases(string from, string[] chain)
{
    import std.algorithm.searching : canFind;
    import std.path : buildNormalizedPath, dirName, isAbsolute;
    import sparkles.ui.themes : builtinThemes;

    return (string name) @safe {
        if (auto t = name in builtinThemes)
            return ok!DtcgError(exportTheme(*t));
        const path = name.isAbsolute ? name : buildNormalizedPath(from.dirName, name);
        if (chain.canFind(path))
            return fail!DtcgJson(path, "a cycle of bases: " ~ (chain ~ path).join(" -> "));
        auto doc = readDocument(path);
        if (doc.hasError)
            return doc;
        return resolvedDocument(doc.value, fileBases(path, chain ~ path));
    };
}

/// Writes the file canonically (`FMT4`): its own document, not the overlay.
string saveTheme(const ThemeFile f)
{
    import sparkles.ui.dtcg : writeDtcg;

    return writeDtcg(f.document);
}

private DtcgResult!T fail(T)(string path, string message)
    => err!T(DtcgError(path, message));

private DtcgError* boxed(DtcgError e) pure nothrow => new DtcgError(e.path, e.message);

private string baseName(const DtcgJson doc)
{
    if (auto e = doc.get("$extensions"))
        if (auto ns = e.get(extensionKey))
            if (auto b = ns.get("base"))
                if (b.isString)
                    return b.text;
    return null;
}

// The resolver rule: every token of `top` replaces the base's token at the
// same path; groups merge; `top`'s root extension wins.
private DtcgJson overlay(const DtcgJson base, const DtcgJson top)
{
    auto r = base.dup;
    r.remove("$extensions");
    foreach (ref m; top.members)
    {
        auto existing = r.get(m.key);
        const groups = existing !is null && existing.isObject && m.value.isObject
            && existing.get("$value") is null && m.value.get("$value") is null
            && m.key != "$extensions";
        if (groups)
            *existing = overlay(*existing, m.value);
        else
            r.set(m.key, m.value.dup);
    }
    return r;
}

private struct Mapper
{
    const(DtcgTokens)* toks;
    Theme* theme;
    bool[string] used;

    string[] unmapped()
    {
        string[] r;
        foreach (ref t; toks.tokens)
            if (t.path !in used)
                r ~= t.jsonPath ~ ": not a theme token; kept, not drawn";
        return r;
    }

    // The resolved color of the token at `path`, or null when absent.
    DtcgResult!(DtcgColor*) color(string path)
    {
        auto t = path in *toks;
        if (t is null)
            return ok!DtcgError(cast(DtcgColor*) null);
        used[path] = true;
        if (t.type != "color")
            return fail!(DtcgColor*)(t.jsonPath ~ ".$type",
                "expected color, found " ~ t.type);
        auto v = toks.resolved(path);
        if (v.hasError)
            return err!(DtcgColor*)(v.error);
        auto parsed = parseColor(v.value, t.jsonPath ~ ".$value");
        if (parsed.hasError)
            return err!(DtcgColor*)(parsed.error);
        auto col = parsed.value;
        // An alias may add its own alpha (`$extensions` → alpha, 0–1).
        if (auto e = t.node.get("$extensions"))
            if (auto ns = e.get(extensionKey))
                if (auto a = ns.get("alpha"))
                {
                    const x = a.kind == DtcgJson.Kind.number ? numberOf(a.text) : double.nan;
                    if (!(x >= 0 && x <= 1))
                        return fail!(DtcgColor*)(t.jsonPath ~ ".$extensions." ~ extensionKey
                            ~ ".alpha", "out of range: " ~ a.text ~ " is not from 0 to 1");
                    col.alpha = cast(ubyte) round(x * 255);
                }
        auto p = new DtcgColor;
        *p = col;
        if (auto e = t.node.get("$extensions"))
            if (auto ns = e.get(extensionKey))
                if (auto idx = ns.get("index"))
                    indexOf[path] = cast(ubyte) idx.text.to!uint;
        return ok!DtcgError(p);
    }

    ubyte[string] indexOf; // tokens that carry a terminal-palette index

    Color toColor(string path, const DtcgColor c)
        => path in indexOf ? Color(Color.Kind.palette, indexOf[path]) : Color.fromRgb(c.rgb);

    DtcgError* run(const DtcgJson doc)
    {
        // Page colors.
        foreach (which; ["fg", "bg"])
        {
            auto c = color("page." ~ which);
            if (c.hasError)
                return boxed(c.error);
            if (c.value !is null)
                (which == "fg" ? theme.defaultFg : theme.defaultBg) = toColor("page." ~ which, *c.value);
        }

        // The root extension.
        if (auto e = doc.get("$extensions"))
            if (auto ns = e.get(extensionKey))
            {
                if (auto n = ns.get("name"))
                    theme.name = n.text;
                if (auto u = ns.get("unicode"))
                    theme.glyphs.unicode = u.boolean;
                if (auto g = ns.get("glyphs"))
                {
                    static foreach (field; glyphFamilies)
                    {{
                        alias E = typeof(__traits(getMember, theme.glyphs, field));
                        if (auto v = g.get(field))
                        {
                            bool found;
                            foreach (i, n; familyNames!E)
                                if (v.isString && v.text == n)
                                    __traits(getMember, theme.glyphs, field) = cast(E) i, found = true;
                            if (!found)
                                return new DtcgError("$.$extensions." ~ extensionKey ~ ".glyphs." ~ field,
                                    "not a " ~ field ~ " family; expected one of "
                                    ~ familyNames!E[].join(", "));
                        }
                    }}
                }
            }

        // Syntax rules.
        if (auto s = doc.get("syntax"))
            if (auto e = rules(*s, "syntax"))
                return e;

        // The palette: derived from the page colors unless the file sets any
        // slot, state or metric, in which case the derivation is the start.
        if (auto e = palette())
            return e;
        return null;
    }

    DtcgError* rules(const DtcgJson node, string path)
    {
        foreach (ref m; node.members)
        {
            if (m.key.startsWith("$") || m.key == "fg" || m.key == "bg" || !m.value.isObject)
                continue;
            const p = path ~ "." ~ m.key;
            if (auto e = rules(m.value, p))
                return e;
        }
        if (path == "syntax")
            return null;
        StyleSpec style;
        bool any;
        foreach (which; ["fg", "bg"])
        {
            auto c = color(path ~ "." ~ which);
            if (c.hasError)
                return boxed(c.error);
            if (c.value is null)
                continue;
            any = true;
            if (which == "fg")
                style = StyleSpec(fg: toColor(path ~ ".fg", *c.value), bg: style.bg);
            else
                style = StyleSpec(fg: style.fg, bg: toColor(path ~ ".bg", *c.value));
        }
        TextAttr attrs;
        auto ul = UnderlineStyle.none;
        Color ulColor;
        if (auto e = node.get("$extensions"))
            if (auto ns = e.get(extensionKey))
            {
                any = true;
                if (auto a = ns.get("attrs"))
                {
                    auto r = parseAttrs(*a, "$." ~ path ~ ".$extensions." ~ extensionKey ~ ".attrs");
                    if (r.hasError)
                        return boxed(r.error);
                    attrs = r.value;
                }
                if (auto u = ns.get("underline"))
                {
                    const where = "$." ~ path ~ ".$extensions." ~ extensionKey ~ ".underline";
                    bool found;
                    if (auto st = u.get("style"))
                        foreach (i, n; underlineNames)
                            if (n == st.text)
                                ul = cast(UnderlineStyle) i, found = true;
                    if (!found)
                        return new DtcgError(where ~ ".style", "not an underline style");
                    if (auto c = u.get("color"))
                    {
                        auto pc = parseColor(*c, where ~ ".color");
                        if (pc.hasError)
                            return boxed(pc.error);
                        ulColor = Color.fromRgb(pc.value.rgb);
                    }
                }
            }
        if (any)
            theme.rules ~= ThemeRule(path["syntax.".length .. $],
                StyleSpec(fg: style.fg, bg: style.bg, underlineColor: ulColor,
                    attrs: attrs, underline: ul));
        return null;
    }

    DtcgError* palette()
    {
        // Whether the file says anything about the palette at all.
        bool any;
        foreach (ref t; toks.tokens)
            if (!t.path.startsWith("page.", "syntax.") && isPalettePath(t.path))
                any = true;
        if (!any)
            return null;

        auto p = theme.effectivePalette();
        foreach (i; 0 .. slotCount)
        {
            const path = tokenPath(cast(Slot) i);
            foreach (which; ["fg", "bg"])
            {
                auto c = color(path ~ "." ~ which);
                if (c.hasError)
                    return boxed(c.error);
                if (c.value is null)
                    continue;
                if (which == "fg")
                    p.fg[i] = toColor(path ~ ".fg", *c.value), p.fgAlpha[i] = c.value.alpha;
                else
                    p.bg[i] = toColor(path ~ ".bg", *c.value), p.bgAlpha[i] = c.value.alpha;
            }
            foreach (st; 1 .. stateNames.length)
                if (auto e = state(p, cast(Slot) i, st))
                    return e;
        }
        static foreach (f; metricFields!())
        {{
            enum mp = metricPath!f;
            if (auto t = mp in *toks)
            {
                used[mp] = true;
                auto v = metricValue(*t, unitOf(mp));
                if (v.hasError)
                    return boxed(v.error);
                alias F = typeof(__traits(getMember, p, f));
                if (v.value < 0 || v.value > F.max)
                    return new DtcgError(t.jsonPath ~ ".$value",
                        format("out of range: %s is not from 0 to %s", v.value, F.max));
                __traits(getMember, p, f) = cast(F) v.value;
            }
        }}
        theme.palette = p;
        theme.hasPalette = true;
        return null;
    }

    DtcgError* state(ref Palette p, Slot slot, size_t st)
    {
        const sp = tokenPath(slot) ~ "." ~ stateNames[st];
        auto o = &p.states[st - 1];
        foreach (which; ["fg", "bg"])
        {
            const path = sp ~ "." ~ which;
            auto t = path in *toks;
            if (t is null)
                continue;
            // An alias to another slot's same channel is a D46 alias; any
            // other value is a literal color for this state.
            if (auto a = aliasTarget(t.value))
                if (!a.pointer && a.text.endsWith("." ~ which))
                    if (auto from = slotOf(a.text[0 .. $ - which.length - 1]))
                    {
                        used[path] = true;
                        if (which == "fg")
                            o.fgAliased[slot] = true, o.fgFrom[slot] = *from;
                        else
                            o.bgAliased[slot] = true, o.bgFrom[slot] = *from;
                        continue;
                    }
            auto c = color(path);
            if (c.hasError)
                return boxed(c.error);
            if (which == "fg")
                o.fg[slot] = toColor(path, *c.value), o.fgAlpha[slot] = c.value.alpha;
            else
                o.bg[slot] = toColor(path, *c.value), o.bgAlpha[slot] = c.value.alpha;
        }
        // The state group's extension: its attributes. It is read from the
        // overlay document, so a base's state attributes survive an overlay.
        if (auto g = group(sp))
            if (auto e = g.get("$extensions"))
                if (auto ns = e.get(extensionKey))
                    if (auto a = ns.get("attrs"))
                    {
                        auto r = parseAttrs(*a, "$." ~ sp ~ ".$extensions." ~ extensionKey ~ ".attrs");
                        if (r.hasError)
                            return boxed(r.error);
                        o.attrs[slot] = r.value.bits;
                    }
        return null;
    }

    const(DtcgJson)* group(string path)
    {
        const(DtcgJson)* node = &toks.expanded;
        foreach (seg; path.split('.'))
        {
            node = node.get(seg);
            if (node is null)
                return null;
        }
        return node;
    }
}

private Slot* slotOf(scope const(char)[] path)
{
    foreach (i; 0 .. slotCount)
        if (tokenPath(cast(Slot) i) == path)
            return new Slot(cast(Slot) i);
    return null;
}

private bool isPalettePath(string path)
{
    foreach (i; 0 .. slotCount)
        if (path.startsWith(tokenPath(cast(Slot) i) ~ "."))
            return true;
    static foreach (f; metricFields!())
        if (path == metricPath!f)
            return true;
    return false;
}

private DtcgResult!long metricValue(const DtcgToken t, MetricUnit unit)
{
    final switch (unit)
    {
        case MetricUnit.px:
        {
            if (t.type != "dimension")
                return fail!long(t.jsonPath ~ ".$type", "expected dimension, found " ~ t.type);
            auto d = parseDimension(t.value, t.jsonPath ~ ".$value");
            if (d.hasError)
                return err!long(d.error);
            const px = d.value.unit == "rem" ? d.value.value * 16 : d.value.value;
            return ok!DtcgError(cast(long) round(px));
        }
        case MetricUnit.cell:
        case MetricUnit.percent:
            if (t.type != "number")
                return fail!long(t.jsonPath ~ ".$type", "expected number, found " ~ t.type);
            if (t.value.kind != DtcgJson.Kind.number)
                return fail!long(t.jsonPath ~ ".$value", "expected a number");
            const x = numberOf(t.value.text);
            if (x != x)
                return fail!long(t.jsonPath ~ ".$value", "not a number: " ~ t.value.text);
            return ok!DtcgError(cast(long) round(x));
    }
}

private DtcgResult!TextAttr parseAttrs(const DtcgJson v, string where)
{
    if (v.kind != DtcgJson.Kind.array)
        return fail!TextAttr(where, "attrs is an array of attribute names");
    TextAttr a;
    foreach (i, ref e; v.items)
    {
        bool found;
        foreach (j, n; attrNames)
            if (e.isString && e.text == n)
                a = a | attrBits[j], found = true;
        if (!found)
            return fail!TextAttr(format("%s[%s]", where, i), "not a text attribute; expected one of "
                ~ attrNames[].join(", "));
    }
    return ok!DtcgError(a);
}

// ── tests ───────────────────────────────────────────────────────────────────

version (unittest)
{
    import sparkles.ui.dtcg : writeDtcg;

    // The effective style of every selector, last rule winning — what a
    // theme's syntax channel means, independent of rule order.
    private StyleSpec[string] effectiveRules(const Theme t)
    {
        StyleSpec[string] r;
        foreach (ref rule; t.rules)
            r[rule.selector] = rule.style;
        return r;
    }

    private void assertSameTheme(const Theme a, const Theme b, string what)
    {
        assert(a.name == b.name, what ~ ": name");
        assert(a.defaultFg == b.defaultFg && a.defaultBg == b.defaultBg, what ~ ": page colors");
        assert(effectiveRules(a) == effectiveRules(b), what ~ ": syntax rules");
        assert(a.glyphs == b.glyphs, what ~ ": glyphs");
        assert(a.effectivePalette() == b.effectivePalette(), what ~ ": palette");
    }
}

@("theme_file.builtins.roundTrip")
@safe unittest
{
    import sparkles.ui.themes : builtinThemes;

    // `FMT4`/`FMT5`: every built-in exports, writes canonically, loads back
    // to the same theme, and exports to the same bytes again.
    foreach (name, ref t; builtinThemes)
    {
        const text = writeDtcg(exportTheme(t));
        auto loaded = loadTheme(text);
        assert(loaded.hasValue, name ~ ": " ~ (loaded.hasError ? loaded.error.message : ""));
        assertSameTheme(t, loaded.value.theme, name);
        assert(loaded.value.warnings.length == 0, name ~ ": " ~ loaded.value.warnings.join("; "));
        assert(saveTheme(loaded.value) == text, name ~ ": save(load(x)) == x");
        assert(writeDtcg(exportTheme(loaded.value.theme)) == text, name ~ ": export is a fixed point");
    }
}

@("theme_file.palette.slotsStatesAndMetricsRoundTrip")
@safe unittest
{
    // A file cannot unset a slot: an absent token is the derived value. So
    // a palette round-trips when it starts from the derivation, as every
    // palette a file describes does.
    Theme t = Theme(name: "explicit", defaultBg: Color.fromRgb(RgbColor(0x10, 0x10, 0x10)));
    t.palette = t.effectivePalette();
    t.palette.fgAlpha[Slot.muted] = 0x80;
    t.palette.stateAlias(InteractionState.hover, Slot.thumb, Slot.accentPrimary);
    t.palette.overlay(InteractionState.pressed).bg[Slot.thumb] = Color.fromRgb(RgbColor(1, 2, 3));
    t.palette.overlay(InteractionState.selected).attrs[Slot.chromeAccent] = TextAttr.bold.bits;
    t.palette.overlayRadius = 7;
    t.palette.overlayPadX = 3;
    t.hasPalette = true;

    const text = writeDtcg(exportTheme(t));
    assert(text.canFind(`"hover": {`));
    assert(text.canFind(`"$value": "{accent.primary.fg}"`));
    auto loaded = loadTheme(text);
    assert(loaded.hasValue, loaded.hasError ? loaded.error.message : "");
    assert(loaded.value.theme.palette == t.palette);
    assert(saveTheme(loaded.value) == text);
}

@("theme_file.load.overlaysABase")
@safe unittest
{
    import sparkles.ui.themes : builtinThemes;

    // A user file: a base, one slot, a primitive and an alias to it.
    const user = `{
        "$extensions": { "dev.petar-kirov.sparkles": { "base": "nord", "name": "mine" } },
        "palette": { "rose": { "$type": "color", "$value": "#ff0066" } },
        "accent": { "primary": { "fg": { "$value": "{palette.rose}" } } }
    }`;
    BaseResolver base = (string name) @safe {
        auto t = name in builtinThemes;
        return t is null ? err!DtcgJson(DtcgError("$", "no theme " ~ name))
            : ok!DtcgError(exportTheme(*t));
    };
    auto f = loadTheme(user, base);
    assert(f.hasValue, f.hasError ? f.error.path ~ ": " ~ f.error.message : "");
    const th = f.value.theme;
    assert(th.name == "mine");
    assert(th.defaultBg == builtinThemes["nord"].defaultBg, "the base's page colors");
    assert(effectiveRules(th) == effectiveRules(builtinThemes["nord"]), "the base's rules");
    assert(th.palette.fg[Slot.accentPrimary] == Color.fromRgb(RgbColor(0xff, 0x00, 0x66)));
    // The primitive is kept, and reported as unmapped.
    assert(f.value.warnings.length == 1 && f.value.warnings[0].startsWith("$.palette.rose"));
    // Saving writes the user's own document: the alias, not its value.
    assert(saveTheme(f.value).canFind(`"$value": "{palette.rose}"`));
    assert(!saveTheme(f.value).canFind(`"syntax"`));
}

@("theme_file.load.attrsOnlyRulesAndDraftHex")
@safe unittest
{
    auto f = loadTheme(`{
        "page": { "$type": "color", "fg": { "$value": "#cdd6f4" }, "bg": { "$value": "#1e1e2e" } },
        "syntax": { "$type": "color",
            "comment": { "$extensions": { "dev.petar-kirov.sparkles": { "attrs": ["italic"] } } },
            "keyword": { "fg": { "$value": "#cba6f7" },
                "control": { "fg": { "$value": "#f38ba8" },
                    "$extensions": { "dev.petar-kirov.sparkles": { "attrs": ["bold"],
                        "underline": { "style": "curly" } } } } } }
    }`);
    assert(f.hasValue, f.hasError ? f.error.path ~ ": " ~ f.error.message : "");
    const r = effectiveRules(f.value.theme);
    assert(r["comment"].attrs == TextAttr.italic && r["comment"].fg.kind == Color.Kind.unset);
    assert(r["keyword"].fg == Color.fromRgb(RgbColor(0xcb, 0xa6, 0xf7)));
    assert(r["keyword.control"].attrs == TextAttr.bold);
    assert(r["keyword.control"].underline == UnderlineStyle.curly);
    assert(!f.value.theme.hasPalette, "no slot set: the palette stays derived");
}

@("theme_file.load.malformedCorpusFailsWithAPath")
@safe unittest
{
    // `O4`'s malformed corpus: each document fails, naming where.
    static immutable string[2][] corpus = [
        [`{"accent": {"primary": {"fg": {"$value": "{accent.primary.fg}", "$type": "color"}}}}`,
            "$.accent.primary.fg.$value"],                                   // cycle
        [`{"accent": {"primary": {"fg": {"$type": "color", "$value": "{nope.fg}"}}}}`,
            "$.accent.primary.fg.$value"],                                   // dangling alias
        [`{"accent": {"primary": {"fg": {"$type": "number", "$value": 3}}}}`,
            "$.accent.primary.fg.$type"],                                    // wrong $type
        [`{"accent": {"primary": {"fg": {"$type": "color", "$value": {"colorSpace": "srgb", "components": [1, 1.5, 0]}}}}}`,
            "$.accent.primary.fg.$value.components[1]"],                     // out-of-range color
        [`{"overlay": {"radius": {"$type": "number", "$value": 4}}}`,
            "$.overlay.radius.$type"],                                       // px metric as a number
        [`{"overlay": {"pad": {"inline": {"$type": "number", "$value": -1}}}}`,
            "$.overlay.pad.inline.$value"],                                  // negative metric
        [`{"syntax": {"comment": {"$extensions": {"dev.petar-kirov.sparkles": {"attrs": ["blink"]}}}}}`,
            "$.syntax.comment.$extensions.dev.petar-kirov.sparkles.attrs[0]"], // unknown attribute
        [`{"$extensions": {"dev.petar-kirov.sparkles": {"base": "nord"}}}`,
            "$.$extensions.dev.petar-kirov.sparkles.base"],                  // base, no resolver
        [`{"a": }`, "1:7"],                                                  // malformed JSON
    ];
    foreach (c; corpus)
    {
        auto f = loadTheme(c[0]);
        assert(f.hasError, "accepted: " ~ c[0]);
        assert(f.error.path == c[1], c[0] ~ "\n  path " ~ f.error.path ~ ", wanted " ~ c[1]
            ~ "\n  " ~ f.error.message);
    }
}

@("theme_file.load.unknownExtensionsSurviveASave")
@safe unittest
{
    const text = `{
    "$extensions": {
    "com.figma": {
            "collection": "Theme"
    }
    },
    "page": {
    "fg": {
            "$extensions": {
        "com.figma": {
                    "scopes": ["TEXT_FILL"]
        }
            },
            "$type": "color",
            "$value": "#cdd6f4"
    }
    }
}
`;
    auto f = loadTheme(text);
    assert(f.hasValue);
    const saved = saveTheme(f.value);
    assert(saved.canFind(`"com.figma"`) && saved.canFind(`"TEXT_FILL"`));
    assert(saved.canFind(`"$value": "#cdd6f4"`), "a draft value is kept as written");
}

@("theme_file.loadThemeFile.basesAreRelativeAndNested")
@system unittest
{
    import sparkles.test_utils.tmpfs : TmpFS;
    import sparkles.ui.themes : builtinThemes;

    auto tmp = TmpFS.create();
    // top → mid (a sibling file) → nord (a built-in).
    tmp.writeFileAt("themes/mid.tokens", `{
        "$extensions": { "dev.petar-kirov.sparkles": { "base": "nord" } },
        "accent": { "primary": { "fg": { "$type": "color", "$value": "#ff0066" } } }
    }`);
    const top = tmp.writeFileAt("themes/top.tokens", `{
        "$extensions": { "dev.petar-kirov.sparkles": { "base": "mid.tokens", "name": "top" } },
        "link": { "fg": { "$type": "color", "$value": "{accent.primary.fg}" } }
    }`);
    auto f = loadThemeFile(top);
    assert(f.hasValue, f.hasError ? f.error.path ~ ": " ~ f.error.message : "");
    const th = f.value.theme;
    assert(th.name == "top");
    assert(th.defaultBg == builtinThemes["nord"].defaultBg, "nord's page colors, two bases down");
    assert(th.palette.fg[Slot.accentPrimary] == Color.fromRgb(RgbColor(0xff, 0x00, 0x66)), "mid's slot");
    assert(th.palette.fg[Slot.link] == th.palette.fg[Slot.accentPrimary], "top's alias into mid");
}

@("theme_file.loadThemeFile.failsOnCyclesAndMissingFiles")
@system unittest
{
    import sparkles.test_utils.tmpfs : TmpFS;

    auto tmp = TmpFS.create();
    const a = tmp.writeFileAt("a.tokens",
        `{"$extensions": {"dev.petar-kirov.sparkles": {"base": "b.tokens"}}}`);
    tmp.writeFileAt("b.tokens",
        `{"$extensions": {"dev.petar-kirov.sparkles": {"base": "a.tokens"}}}`);
    auto cyc = loadThemeFile(a);
    assert(cyc.hasError && cyc.error.message.canFind("a cycle of bases"), cyc.error.message);

    const lone = tmp.writeFileAt("lone.tokens",
        `{"$extensions": {"dev.petar-kirov.sparkles": {"base": "absent.tokens"}}}`);
    auto missing = loadThemeFile(lone);
    assert(missing.hasError && missing.error.message.canFind("cannot read"), missing.error.message);

    auto noFile = loadThemeFile(tmp.dir ~ "/nope.tokens");
    assert(noFile.hasError && noFile.error.message.canFind("cannot read"));
}

@("theme_file.themeNamed.nameThenFile")
@system unittest
{
    import sparkles.test_utils.tmpfs : TmpFS;
    import sparkles.ui.themes : builtinThemes;

    auto nord = themeNamed("nord");
    assert(nord.hasValue && nord.value is ("nord" in builtinThemes), "a built-in, not a copy");

    auto tmp = TmpFS.create();
    const path = tmp.writeFile(writeDtcg(exportTheme(builtinThemes["dracula"])));
    auto fromFile = themeNamed(path);
    assert(fromFile.hasValue, fromFile.hasError ? fromFile.error.message : "");
    assertSameTheme(builtinThemes["dracula"], *fromFile.value, "dracula from a file");

    auto typo = themeNamed("draculla");
    assert(typo.hasError && typo.reason == "no built-in theme or theme file has this name");
}

@("theme_file.builtins.exportsMatchTheCheckedInGoldens")
@system unittest
{
    import std.algorithm.iteration : map;
    import std.algorithm.sorting : sort;
    import std.array : array;
    import std.file : dirEntries, exists, readText, SpanMode, write;
    import std.path : baseName, buildPath, dirName, stripExtension;
    import std.process : environment;
    import sparkles.ui.themes : builtinThemes;

    // `FMT5`: every built-in's export is checked in, so a change to a theme is
    // a token diff in review. Regenerate with
    //     SPARKLES_UPDATE_GOLDENS=1 dub test :ui -- -i exportsMatchTheCheckedInGoldens
    const dir = buildPath(__FILE_FULL_PATH__.dirName, "..", "..", "..", "test", "data", "themes");
    const update = environment.get("SPARKLES_UPDATE_GOLDENS", "").length != 0;
    bool[string] names;
    string[] stale;
    foreach (_, ref t; builtinThemes)
    {
        if (t.name in names)
            continue; // an alias spelling of a theme already written
        names[t.name] = true;
        const path = buildPath(dir, t.name ~ ".tokens");
        const text = writeDtcg(exportTheme(t));
        if (update)
            write(path, text);
        // A Windows checkout may carry CRLF (no .gitattributes pins the data).
        else if (!exists(path) || readText(path).replace("\r\n", "\n") != text)
            stale ~= t.name;
    }
    assert(stale.length == 0, "exports differ from the goldens: " ~ stale.sort.join(", ")
        ~ "; regenerate with SPARKLES_UPDATE_GOLDENS=1 and review the diff");
    // And no golden outlives its theme.
    auto files = () @trusted { return dirEntries(dir, "*.tokens", SpanMode.shallow).array; }();
    foreach (f; files)
        assert(f.name.baseName.stripExtension in names, "no built-in theme for " ~ f.name.baseName);
    assert(files.length == names.length || update);
}

@("theme_file.glyphFamiliesRoundTrip")
@safe unittest
{
    import sparkles.ui.style : FrameFamily, GuideFamily, MarkCharset, ThumbFamily;

    // `GLY1`: a theme's glyph families travel in the root extension; the
    // defaults are left out, so every built-in's export is unchanged.
    Theme t = Theme(name: "glyphs");
    t.glyphs.frame = FrameFamily.rounded;
    t.glyphs.treeGuide = GuideFamily.heavy;
    t.glyphs.thumb = ThumbFamily.shade;
    t.glyphs.marks = MarkCharset.nerdFont;
    const text = writeDtcg(exportTheme(t));
    assert(text.canFind(`"treeGuide": "heavy"`), text);
    auto f = loadTheme(text);
    assert(f.hasValue, f.hasError ? f.error.message : "");
    assert(f.value.theme.glyphs == t.glyphs);
    assert(!writeDtcg(exportTheme(Theme(name: "plain"))).canFind(`"glyphs"`));

    auto bad = loadTheme(`{"$extensions": {"dev.petar-kirov.sparkles": {"glyphs": {"thumb": "zigzag"}}}}`);
    assert(bad.hasError && bad.error.path == "$.$extensions.dev.petar-kirov.sparkles.glyphs.thumb");
}
