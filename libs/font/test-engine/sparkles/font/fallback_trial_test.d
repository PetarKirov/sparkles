/**
Whole-span trials (FTD39–FTD43) over real faces: a fixture Latin primary
that lacks marks, a fixture "text emoji" face that covers a family's scalars
without ligating them, and the bundled Noto Sans, Noto Sans Arabic and Noto
Color Emoji. Pruning (FTD40) is checked as a property against HarfBuzz.
*/
module sparkles.font.fallback_trial_test;

import std.conv : to;

import sparkles.base.text.unicode_tables : bidiMirror, canonicalMapping, canonicalMappingValue;
import sparkles.base.vfs : ambientAuthority;
import sparkles.event_horizon.sys.vfs : BlockingVfs;
import sparkles.test_runner.skip : skipTest;

import sparkles.font;
import sparkles.font.corpus : fontsPath;
import sparkles.font.fallback_trial;
import sparkles.font.fixtures;

private enum one = 65_536;

/// A face covering 👦👧👨👩 and ZWJ, with no substitutions.
private ubyte[] textEmoji() @safe
{
    auto t = styledTables(StyledFace("Text Emoji"));
    foreach (ref x; t)
        if (x.tag == "cmap")
            x.data = cmap([CmapRecord(3, 10, cmapFormat12([[0x200D, 0x200D, 5], [0x1F466, 0x1F469, 1]]))]);
    return sfnt(t);
}

/// A tricky face by name: FreeType requires its bytecode (FTD12).
private ubyte[] tricky() @safe
{
    auto t = styledTables(StyledFace("PMingLiU", "Regular", 400, 5, 0, 0, 'A', 'z'));
    return sfnt(t);
}

private struct World
{
    BlockingVfs* vfs;
    Catalog catalog;
    BuildReport report;
    FallbackChain chain;
    const(ubyte)[] primary, emoji, mingliu;
}

private World* world(bool withTricky = false) @safe
{
    if (fontsPath is null)
        return null;
    auto w = new World;
    w.vfs = new BlockingVfs;
    w.primary = styledFont(StyledFace("Primary", "Regular", 400, 5, 0, 0, 'A', 'z'));
    w.emoji = textEmoji();
    w.mingliu = tricky();
    const sources = [FontSource.memory("primary", w.primary), FontSource.memory("text-emoji", w.emoji),
        FontSource.memory("tricky", w.mingliu),
        FontSource.files("bundle", fontsPath, ["NotoSans.ttf", "NotoSansArabic.ttf", "NotoColorEmoji.ttf"])];
    BuildOptions options;
    options.corrections = CorrectionPolicy.apply; // the GUI stack's choice (FTX15)
    assert(!buildCatalog(w.vfs, sources, options, ambientAuthority(), w.catalog, w.report).hasError);
    assert(w.report.failed == 0);
    MatchRequest family(string name) @safe
    {
        MatchRequest r;
        r.families = [name];
        return r;
    }
    ChainItem[] items = [ChainItem.primary];
    if (withTricky)
        items ~= ChainItem.family(family("PMingLiU"));
    items ~= [ChainItem.family(family("Text Emoji")), ChainItem.family(family("Noto Color Emoji")),
        ChainItem.family(family("Noto Sans")), ChainItem.family(family("Noto Sans Arabic"))];
    assert(buildChain(w.catalog, family("Primary"), items, w.chain).hasValue);
    return w;
}

private struct Trial
{
    TrialOutcome outcome;
    Attempt[16] attempts;
    ShapedGlyph[256] glyphs;
    SourceSpan[256] spans;
    BoundarySafety[256] boundaries;
    char[64] language;
}

private Trial* run(World* w, string text, ShapingDirection direction = ShapingDirection.leftToRight,
    string script = "Latn", TrialPolicy policy = TrialPolicy.init) @system
{
    auto store = new FaceStore!BlockingVfs(w.vfs, w.chain, ambientAuthority());
    auto t = new Trial;
    ShapeRequest r;
    r.source = text;
    r.runStart = 0;
    r.runEnd = text.length;
    r.properties.direction = direction;
    r.properties.script = Tag(script);
    r.propertiesExplicit = true;
    r.beginningOfText = r.endOfText = true;
    const o = trySpan(w.chain, *store, r, InstanceSize.pixels(Ppem.fromInteger(16).value), policy, t.attempts[],
        t.glyphs[], t.spans[], t.boundaries[], t.language[]);
    assert(o.hasValue, o.error.kind.to!string);
    t.outcome = o.value;
    return t;
}

private string familyOf(World* w, size_t entry) @safe
    => w.chain.poolsOf(w.chain.entries[entry]).text(w.chain.recordOf(w.chain.entries[entry]).family).idup;

@("trial.FTD41.emojiFamilyLigatesOnlyInTheEmojiFace")
@system unittest
{
    auto w = world();
    if (w is null)
        skipTest("SPARKLES_FONTS_PATH is unset");
    const text = "\U0001F468‍\U0001F469‍\U0001F467";
    auto t = run(w, text);
    assert(t.outcome.resolved && familyOf(w, t.outcome.entry) == "Noto Color Emoji");
    const a = t.attempts[0 .. t.outcome.attempts];
    // The primary is pruned by coverage; the text face covers every scalar and still fails.
    assert(a.length == 2 && a[0].kind == AttemptKind.pruned && a[0].scalar == 0x1F468, a.to!string);
    assert(a[1].kind == AttemptKind.unligated && a[1].start == 0 && a[1].end == text.length);
    assert(t.outcome.cacheable);
    // Without the ligation policy, the text face's three glyphs count as a success.
    TrialPolicy loose;
    loose.emojiSequencesMustLigate = false;
    assert(familyOf(w, run(w, text, ShapingDirection.leftToRight, "Latn", loose).outcome.entry) == "Text Emoji");
}

@("trial.FTD40.arabicWordFailsUntilTheArabicFace")
@system unittest
{
    auto w = world();
    if (w is null)
        skipTest("SPARKLES_FONTS_PATH is unset");
    auto t = run(w, "مرحبا", ShapingDirection.rightToLeft, "Arab");
    assert(t.outcome.resolved && familyOf(w, t.outcome.entry) == "Noto Sans Arabic");
    // Arabic is shaped by its own shaper, so no candidate is pruned: each fails by shaping.
    foreach (a; t.attempts[0 .. t.outcome.attempts])
        assert(a.kind == AttemptKind.notdef, a.to!string);
    assert(t.outcome.attempts == 4);
}

@("trial.FTD40.markSequence")
@system unittest
{
    auto w = world();
    if (w is null)
        skipTest("SPARKLES_FONTS_PATH is unset");
    // The primary covers e but no marks; no candidate is pruned by a mark.
    auto t = run(w, "ẹ́");
    assert(t.outcome.resolved && familyOf(w, t.outcome.entry) == "Noto Sans");
    assert(t.attempts[0].kind == AttemptKind.notdef && t.attempts[0].entry == 0);
}

@("trial.FTD42.unresolvedAndLimited")
@system unittest
{
    auto w = world(true);
    if (w is null)
        skipTest("SPARKLES_FONTS_PATH is unset");
    // A private-use scalar no face covers: every candidate is tried, and the run is reported whole.
    auto t = run(w, "ab");
    assert(!t.outcome.resolved && t.outcome.runStart == 0 && t.outcome.runEnd == 5);
    const a = t.attempts[0 .. t.outcome.attempts];
    assert(a[1].kind == AttemptKind.bytecodeRequired && familyOf(w, a[1].entry) == "PMingLiU");
    foreach (x; a)
        assert(x.kind == AttemptKind.notdef || x.kind == AttemptKind.bytecodeRequired
            || x.kind == AttemptKind.pruned && x.scalar == 'a', x.to!string);
    TrialPolicy two;
    two.candidateLimit = 2;
    auto limited = run(w, "ab", ShapingDirection.leftToRight, "Latn", two);
    size_t shaped;
    foreach (x; limited.attempts[0 .. limited.outcome.attempts])
        shaped += x.kind == AttemptKind.notdef;
    assert(!limited.outcome.resolved && shaped == 2);
    // A bytecode-capable rasterizer takes the tricky face for ASCII.
    TrialPolicy hinting;
    hinting.rasterizerInterpretsBytecode = true;
    assert(familyOf(w, run(w, "ab", ShapingDirection.leftToRight, "Latn", hinting).outcome.entry) == "Primary");
}

@("trial.FTD39.badRequestFailsFirst")
@system unittest
{
    auto w = world();
    if (w is null)
        skipTest("SPARKLES_FONTS_PATH is unset");
    auto store = new FaceStore!BlockingVfs(w.vfs, w.chain, ambientAuthority());
    ShapeRequest r;
    r.source = "ab";
    r.runStart = 2;
    r.runEnd = 1;
    Attempt[4] a;
    ShapedGlyph[8] g;
    SourceSpan[8] s;
    BoundarySafety[8] b;
    char[8] l;
    const o = trySpan(w.chain, *store, r, InstanceSize.pixels(Ppem.fromInteger(16).value), TrialPolicy.init, a[],
        g[], s[], b[], l[]);
    assert(o.hasError && o.error.kind == FontErrorKind.invalidRange);
}

@("trial.FTD43.keys")
@system unittest
{
    auto w = world();
    if (w is null)
        skipTest("SPARKLES_FONTS_PATH is unset");
    ShapeRequest at(string source, size_t start, size_t end)
    {
        ShapeRequest r;
        r.source = source;
        r.runStart = start;
        r.runEnd = end;
        return r;
    }
    const size = InstanceSize.pixels(Ppem.fromInteger(16).value);
    const base = trialKey(w.chain, at("0123456789abcdefghij", 10, 12), size, TrialPolicy.init);
    // A context byte the shaper reads changes the key; one beyond five scalars does not.
    assert(trialKey(w.chain, at("0123456789abcdefgXij", 10, 12), size, TrialPolicy.init) == base);
    assert(trialKey(w.chain, at("0123456789abcXefghij", 10, 12), size, TrialPolicy.init) != base);
    assert(trialKey(w.chain, at("01234X6789abcdefghij", 10, 12), size, TrialPolicy.init) != base);
    assert(trialKey(w.chain, at("X123456789abcdefghij", 10, 12), size, TrialPolicy.init) == base);
    // The same bytes at another offset are another key.
    assert(trialKey(w.chain, at("_0123456789abcdefghij", 11, 13), size, TrialPolicy.init) != base);
    TrialPolicy p;
    p.candidateLimit = 3;
    assert(trialKey(w.chain, at("0123456789abcdefghij", 10, 12), size, p) != base);
}

@("trial.FTD40.provesNotdef")
@safe unittest
{
    // The review's counterexamples are never proofs.
    assert(!provesNotdef('e', 0x0323) && !provesNotdef(0x0323, 0x0302) && !provesNotdef(0x0302, dchar.max));
    assert(!provesNotdef(0x0E33, dchar.max)); // Thai SARA AM
    assert(!provesNotdef(0x845B, 0xE0100) && !provesNotdef('a', 0xFE0F)); // variation sequences
    assert(!provesNotdef(0x00E9, dchar.max)); // decomposes
    assert(!provesNotdef(0x200D, dchar.max) && !provesNotdef(0x00A0, dchar.max) && !provesNotdef(0x2011, dchar.max));
    assert(provesNotdef(0x1F468, 0x200D) && provesNotdef('q', 'x') && provesNotdef(0x4E00, dchar.max));
    // No starter in a default-shaper script is a composition's second scalar.
    foreach (dchar c; 0 .. 0x110000)
    {
        if (c >= 0xD800 && c <= 0xDFFF)
            continue;
        const m = canonicalMapping(c);
        if (m.present && m.length == 2)
            assert(!provesNotdef(canonicalMappingValue(m.offset + 1), dchar.max), c.to!string);
    }
}

@("trial.FTD40.pruningMatchesHarfBuzz")
@system unittest
{
    if (fontsPath is null)
        skipTest("SPARKLES_FONTS_PATH is unset");
    import std.path : buildPath;
    import std.file : read;

    size_t checked;
    foreach (name; ["NotoSans.ttf", "NotoSansMono.ttf", "NotoSansArabic.ttf", "DejaVuSansMono.ttf"])
    {
        const bytes = cast(const(ubyte)[]) read(buildPath(fontsPath, name));
        const face = openFace(bytes).value;
        const map = charMap(face).value;
        if (glyph0Substitutable(face))
            continue;
        const inst = face.instance(InstanceSize.pixels(Ppem.fromInteger(16).value), null).value;
        auto shaper = new Shaper(inst);
        ShapedGlyph[16] g;
        SourceSpan[16] s;
        BoundarySafety[16] b;
        char[16] l;
        for (dchar c = 0x20; c < 0x30000; c += 3)
        {
            if (c >= 0xD800 && c <= 0xDFFF || map.lookup(c).glyph != 0 || !provesNotdef(c, 'x'))
                continue;
            const m = bidiMirror(c);
            if (m != c && m != dchar.init && map.lookup(m).glyph != 0)
                continue;
            char[8] text;
            import sparkles.base.text.utf : encodeScalar;

            const n = encodeScalar(c, text[]).written;
            text[n] = 'x';
            foreach (rtl; [false, true])
            {
                ShapeRequest r;
                r.source = text[0 .. n + 1].idup;
                r.runEnd = n + 1;
                r.properties.direction = rtl ? ShapingDirection.rightToLeft : ShapingDirection.leftToRight;
                r.properties.script = Tag("Zyyy");
                r.propertiesExplicit = true;
                const info = shaper.shape(r, g[], s[], b[], l[]);
                assert(info.hasValue);
                assert(g[rtl ? info.value.glyphCount - 1 : 0].glyphId == 0, name ~ " U+" ~ (cast(uint) c).to!string(16));
                ++checked;
            }
        }
    }
    assert(checked > 10_000, checked.to!string);
}
