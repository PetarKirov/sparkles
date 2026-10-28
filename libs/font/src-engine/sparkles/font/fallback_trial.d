/**
Whole-span fallback trials (`docs/specs/font/discovery.md` FTD39–FTD43,
SPEC.md FTD7), in the `engine` configuration.

`trySpan` shapes a caller's run whole, with its context, through a chain's
candidates in order, and returns the first that maps every scalar to a glyph
other than `.notdef` and, by default, ligates each RGI emoji sequence; or an
unresolved outcome with the exact run and every attempt. It never shapes a
part of the run alone. Coverage skips a candidate only when `pruningScalar`
proves the shaper would give `.notdef` (FTD40). `trialKey` hashes every
input an outcome depends on (FTD43).
*/
module sparkles.font.fallback_trial;

import sparkles.base.hash.blake3 : Blake3;
import sparkles.base.text.grapheme : byGraphemeCluster;
import sparkles.base.text.unicode_tables : bidiMirror, canonicalCombiningClass, canonicalComposition,
    canonicalMapping, emojiSequences, EmojiSequenceKind, emojiSequenceValue, generalCategory,
    GeneralCategory, script, Script;
import sparkles.base.text.utf : decodeToken, UtfMode;
import sparkles.base.vfs : isVfs;

import sparkles.font.catalog : BuildOutcome, OutcomeKind;
import sparkles.font.errors : FontError, FontErrorKind, FontResult, fontErr, fontOk;
import sparkles.font.face : Face;
import sparkles.font.fallback : ChainEntry, ChainItemKind, FaceStore, FallbackChain;
import sparkles.font.face_record : FaceRecord, RecordPools;
import sparkles.font.instance : instance, Instance, InstanceSize;
import sparkles.font.matching : Match;
import sparkles.font.shaping : BoundarySafety, isBackward, Shaper, ShapedGlyph, ShapeInfo, ShapeRequest,
    ShapingDirection, SourceSpan;

@safe nothrow @nogc:

/// What a trial accepts (FTD39).
struct TrialPolicy
{
    /// Whether each RGI emoji sequence must shape to one visible glyph.
    bool emojiSequencesMustLigate = true;
    /// Whether the caller's rasterizer interprets hinting bytecode (FTD12).
    bool rasterizerInterpretsBytecode;
    /// The most candidates to shape.
    uint candidateLimit = 32;
}

/// Why a candidate did not resolve the run (FTD42).
enum AttemptKind : ubyte
{
    /// A route whose ranges miss a scalar of the run.
    outsideRoute,
    /// Coverage proves `.notdef`; `scalar` is the proof.
    pruned,
    /// The face requires bytecode the rasterizer does not interpret.
    bytecodeRequired,
    /// The face could not be opened; `outcome` says why.
    unopened,
    /// Shaping gave glyph 0; `[start, end)` is the first source span holding it.
    notdef,
    /// An RGI emoji sequence at `[start, end)` did not ligate.
    unligated,
}

/// One candidate's attempt (FTD42).
struct Attempt
{
    size_t entry;
    AttemptKind kind;
    dchar scalar;
    size_t start, end;
    BuildOutcome outcome;
}

/// A trial's outcome (FTD42); glyphs, spans and boundaries are in the caller's storage when `resolved`.
struct TrialOutcome
{
    bool resolved;
    /// The resolving entry.
    size_t entry;
    Match match;
    ShapeInfo info;
    /// The run, as requested.
    size_t runStart, runEnd;
    /// Attempts kept in the caller's storage, and those counted past it.
    size_t attempts, attemptsOmitted;
    /// Whether no attempt was `unopened`, so equal keys give this outcome (FTD43).
    bool cacheable;
}

// ---------------------------------------------------------------------------
// Pruning (FTD40)
// ---------------------------------------------------------------------------

/// HarfBuzz 14.6.0's default-ignorable list (`hb_unicode_funcs_t::is_default_ignorable`).
bool hbDefaultIgnorable(dchar c) pure
{
    if (c <= 0xFFFF)
        switch (c >> 8)
        {
            case 0x00: return c == 0x00AD;
            case 0x03: return c == 0x034F;
            case 0x06: return c == 0x061C;
            case 0x17: return c >= 0x17B4 && c <= 0x17B5;
            case 0x18: return c >= 0x180B && c <= 0x180F;
            case 0x20: return c >= 0x200B && c <= 0x200F || c >= 0x202A && c <= 0x202E || c >= 0x2060 && c <= 0x206F;
            case 0xFE: return c >= 0xFE00 && c <= 0xFE0F || c == 0xFEFF;
            case 0xFF: return c >= 0xFFF0 && c <= 0xFFF8;
            default: return false;
        }
    return c >= 0x1D173 && c <= 0x1D17A || c >= 0xE0000 && c <= 0xE0FFF;
}

/// Unicode's `Variation_Selector` property.
bool isVariationSelector(dchar c) pure
    => c >= 0xFE00 && c <= 0xFE0F || c >= 0xE0100 && c <= 0xE01EF || c >= 0x180B && c <= 0x180D || c == 0x180F;

/// The scripts no HarfBuzz shaper decomposes, composes or remaps (FTD40).
private bool defaultShaperScript(dchar c) pure
{
    switch (script(c))
    {
        case Script.Zyyy, Script.Latn, Script.Grek, Script.Cyrl, Script.Armn, Script.Geor, Script.Hani,
                Script.Hira, Script.Kana, Script.Bopo:
            return true;
        default:
            return false;
    }
}

/**
Whether `s`, followed by `next` (`dchar.max` at the run's end), can prove a
face that lacks it shapes `.notdef` (FTD40): not default-ignorable, not a
space separator, not U+2011, combining class 0 with no canonical
decomposition, followed by a starter that is no variation selector and does
not compose with it, in a default-shaper script. Within those scripts no
starter is a composition's second scalar; the test checks that against every
canonical decomposition. Independent of the face.
*/
bool provesNotdef(dchar s, dchar next) pure
{
    if (hbDefaultIgnorable(s) || generalCategory(s) == GeneralCategory.Zs || s == 0x2011)
        return false;
    if (canonicalCombiningClass(s) != 0 || canonicalMapping(s).present || !defaultShaperScript(s))
        return false;
    if (next == dchar.max)
        return true;
    return canonicalCombiningClass(next) == 0 && !isVariationSelector(next) && canonicalComposition(s, next) == dchar.init;
}

/**
The scalar of the run that proves entry `e` cannot shape it, or `dchar.max`
(FTD40): a horizontal run, a face whose substitutions cannot see glyph 0,
and a proving scalar the face does not cover whose Bidi mirror it does not
cover either. Costs O(n log k).
*/
dchar pruningScalar(ref const FallbackChain chain, in ChainEntry e, in ShapeRequest request)
{
    const direction = request.properties.direction;
    if (request.propertiesExplicit && direction != ShapingDirection.leftToRight
            && direction != ShapingDirection.rightToLeft)
        return dchar.max;
    const r = chain.recordOf(e);
    if (r.glyph0Substitutable)
        return dchar.max;
    const run = request.source[request.runStart .. request.runEnd];
    size_t at;
    dchar s = run.length ? decodeAt(run, at) : dchar.max;
    while (s != dchar.max)
    {
        const next = at < run.length ? decodeAt(run, at) : dchar.max;
        if (!chain.holds(e, s) && provesNotdef(s, next))
        {
            const m = bidiMirror(s);
            if (m == s || m == dchar.init || !chain.holds(e, m))
                return s;
        }
        s = next;
    }
    return dchar.max;
}

/// The scalar at `at` of valid UTF-8, advancing `at`.
private dchar decodeAt(scope const(char)[] s, ref size_t at) pure
{
    const d = decodeToken(s[at .. $], UtfMode.strict, true, at);
    at = d.token.end;
    return d.token.scalar;
}

// ---------------------------------------------------------------------------
// RGI emoji sequences (FTD41)
// ---------------------------------------------------------------------------

/// Whether `scalars` is an RGI ZWJ, modifier, flag, tag or keycap sequence in base's emoji data.
bool isRgiSequence(scope const(dchar)[] scalars) pure
{
    if (scalars.length < 2)
        return false;
    foreach (rec; emojiSequences)
    {
        switch (rec.kind)
        {
            case EmojiSequenceKind.RGI_Emoji_ZWJ_Sequence, EmojiSequenceKind.RGI_Emoji_Modifier_Sequence,
                    EmojiSequenceKind.RGI_Emoji_Flag_Sequence, EmojiSequenceKind.RGI_Emoji_Tag_Sequence,
                    EmojiSequenceKind.Emoji_Keycap_Sequence:
                break;
            default:
                continue;
        }
        if (rec.sequence.length != scalars.length)
            continue;
        bool same = true;
        foreach (i, c; scalars)
            if (emojiSequenceValue(rec.sequence.offset + i) != c)
            {
                same = false;
                break;
            }
        if (same)
            return true;
    }
    return false;
}

/**
The first RGI sequence of the run whose glyphs (those with clusters inside
it) do not include exactly one with a nonzero advance, as `[start, end)`
absolute; `start == end` when every sequence ligates.
*/
private void firstUnligated(in ShapeRequest request, scope const(ShapedGlyph)[] glyphs, out size_t start,
    out size_t end)
{
    const run = request.source[request.runStart .. request.runEnd];
    size_t offset = request.runStart;
    foreach (cluster; byGraphemeCluster(run))
    {
        const from = offset, to = offset + cluster.slice.length;
        offset = to;
        if (cluster.codepoints < 2 || cluster.codepoints > 16)
            continue;
        dchar[16] scalars;
        size_t n, at;
        while (at < cluster.slice.length)
            scalars[n++] = decodeAt(cluster.slice, at);
        if (!isRgiSequence(scalars[0 .. n]))
            continue;
        size_t visible;
        foreach (g; glyphs)
            if (g.cluster >= from && g.cluster < to && (g.xAdvance.raw != 0 || g.yAdvance.raw != 0))
                ++visible;
        if (visible != 1)
        {
            start = from;
            end = to;
            return;
        }
    }
}

// ---------------------------------------------------------------------------
// Trials (FTD39–FTD42)
// ---------------------------------------------------------------------------

/**
Tries `request`'s run with `chain`'s candidates in order (FTD39–FTD42):
shapes it whole at each candidate's instance of `size` until one resolves
it, writing the glyphs, spans and boundaries of that shaping into the
caller's storage, and the attempts before it into `attempts` (those past
its length are counted). A request the shaper refuses fails the trial with
that error before any face opens; a shaping `limitExceeded` ends it with
that error, its outputs uncommitted.
*/
FontResult!TrialOutcome trySpan(V)(ref const FallbackChain chain, ref FaceStore!V store, in ShapeRequest request,
    InstanceSize size, in TrialPolicy policy, scope Attempt[] attempts, scope ShapedGlyph[] glyphs,
    scope SourceSpan[] spans, scope BoundarySafety[] boundaries, scope char[] languageOut)
if (isVfs!V)
{
    import sparkles.font.shaping : validateRequest;

    const invalid = validateRequest(request);
    if (invalid != FontError.init)
        return fontErr!TrialOutcome(invalid);

    TrialOutcome o;
    o.runStart = request.runStart;
    o.runEnd = request.runEnd;
    o.cacheable = true;
    void attempt(Attempt a)
    {
        if (a.kind == AttemptKind.unopened)
            o.cacheable = false;
        if (o.attempts < attempts.length)
            attempts[o.attempts++] = a;
        else
            ++o.attemptsOmitted;
    }

    uint shaped;
    foreach (i, ref e; chain.entries)
    {
        if (shaped >= policy.candidateLimit)
            break;
        if (e.kind == ChainItemKind.route && !routeHoldsRun(chain, e, request))
        {
            attempt(Attempt(i, AttemptKind.outsideRoute));
            continue;
        }
        const proof = pruningScalar(chain, e, request);
        if (proof != dchar.max)
        {
            attempt(Attempt(i, AttemptKind.pruned, proof));
            continue;
        }
        if (chain.recordOf(e).requiresBytecode && !policy.rasterizerInterpretsBytecode)
        {
            attempt(Attempt(i, AttemptKind.bytecodeRequired));
            continue;
        }
        // Open the face: the box-drawing face at the size's integer ppem, the others from the store.
        const(Face)* face;
        BuildOutcome opened;
        if (e.isBoxDrawing)
        {
            const ppem = integerPpem(size);
            if (ppem == 0)
            {
                opened.kind = OutcomeKind.boxFace;
                opened.font = FontError(FontErrorKind.unsupportedCapability);
            }
            else
            {
                const b = store.boxFace(ppem);
                if (b.hasValue)
                    face = b.value;
                else
                {
                    opened.kind = OutcomeKind.boxFace;
                    opened.font = b.error;
                }
            }
        }
        else
            face = store.face(i, opened);
        if (face is null)
        {
            Attempt a = Attempt(i, AttemptKind.unopened);
            a.outcome = opened;
            attempt(a);
            continue;
        }
        const inst = instance(*face, size, e.match.userCoordinates, e.match.synthesis);
        if (inst.hasError)
        {
            Attempt a = Attempt(i, AttemptKind.unopened);
            a.outcome.kind = OutcomeKind.font;
            a.outcome.font = inst.error;
            attempt(a);
            continue;
        }
        ++shaped;
        auto shaper = Shaper(inst.value);
        const info = shaper.shape(request, glyphs, spans, boundaries, languageOut);
        if (info.hasError)
        {
            if (info.error.kind == FontErrorKind.limitExceeded)
                return fontErr!TrialOutcome(info.error);
            Attempt a = Attempt(i, AttemptKind.unopened);
            a.outcome.kind = OutcomeKind.font;
            a.outcome.font = info.error;
            attempt(a);
            continue;
        }
        const g = glyphs[0 .. info.value.glyphCount];
        const s = spans[0 .. info.value.spanCount];
        bool notdef;
        foreach (span; s)
        {
            foreach (k; span.glyphStart .. span.glyphEnd)
                if (g[k].glyphId == 0)
                {
                    attempt(Attempt(i, AttemptKind.notdef, dchar.init, span.start, span.end));
                    notdef = true;
                    break;
                }
            if (notdef)
                break;
        }
        if (notdef)
            continue;
        if (policy.emojiSequencesMustLigate)
        {
            size_t from, to;
            firstUnligated(request, g, from, to);
            if (from != to)
            {
                attempt(Attempt(i, AttemptKind.unligated, dchar.init, from, to));
                continue;
            }
        }
        o.resolved = true;
        o.entry = i;
        o.match = e.match;
        o.info = info.value;
        return fontOk(o);
    }
    return fontOk(o);
}

/// Whether a route entry's ranges hold every scalar of the run that is not default-ignorable (FTD40).
private bool routeHoldsRun(ref const FallbackChain chain, in ChainEntry e, in ShapeRequest request)
{
    const run = request.source[request.runStart .. request.runEnd];
    const ranges = chain.routeRanges(e);
    size_t at;
    while (at < run.length)
    {
        const c = decodeAt(run, at);
        if (hbDefaultIgnorable(c))
            continue;
        bool inside;
        foreach (r; ranges)
            inside |= r.first <= c && c <= r.last;
        if (!inside)
            return false;
    }
    return true;
}

/// The integer ppem nearest a pixel size's, ties up; 0 for a physical size (FTD36).
private uint integerPpem(InstanceSize size) pure
{
    if (size.unit != InstanceSize.Unit.pixels)
        return 0;
    const p = size.ppem;
    const n = p.numerator, d = p.denominator;
    const r = (2 * n + d) / (2 * d);
    return r > uint.max ? 0 : cast(uint) r;
}

// ---------------------------------------------------------------------------
// Trial keys (FTD43)
// ---------------------------------------------------------------------------

/// How many scalars of context either side the shaper reads.
private enum contextScalars = 5;

/**
The 128-bit key of a trial (FTD43): the chain's identity, the run's absolute
range, the bytes the shaper reads (the run and up to five scalars of context
either side) with their absolute start, the segment properties, features,
text-boundary flags, size and policy.
*/
ubyte[16] trialKey(ref const FallbackChain chain, in ShapeRequest request, InstanceSize size, in TrialPolicy policy)
{
    Blake3 h;
    void u64(ulong v)
    {
        ubyte[8] b;
        foreach (i; 0 .. 8)
            b[i] = cast(ubyte)(v >> (8 * i));
        h.put(b[]);
    }
    const id = chain.identity;
    h.put(id[]);
    const source = request.source;
    // Five scalars back from the run's start and forward from its end.
    size_t from = request.runStart;
    foreach (_; 0 .. contextScalars)
    {
        if (from == 0)
            break;
        --from;
        while (from > 0 && (source[from] & 0xC0) == 0x80)
            --from;
    }
    size_t to = request.runEnd;
    foreach (_; 0 .. contextScalars)
    {
        if (to >= source.length)
            break;
        ++to;
        while (to < source.length && (source[to] & 0xC0) == 0x80)
            ++to;
    }
    u64(request.runStart);
    u64(request.runEnd);
    u64(from);
    u64(to - from);
    h.put(source[from .. to]);
    u64(request.properties.direction);
    u64(request.properties.script.value);
    u64(request.properties.language.length);
    h.put(request.properties.language);
    u64(request.propertiesExplicit | request.beginningOfText << 1 | request.endOfText << 2);
    u64(request.features.length);
    foreach (f; request.features)
    {
        u64(f.tag.value);
        u64(f.value);
        u64(f.start);
        u64(f.end);
        u64(f.hasRange);
    }
    u64(size.unit);
    if (size.unit == InstanceSize.Unit.pixels)
    {
        u64(size.ppem.numerator);
        u64(size.ppem.denominator);
    }
    else
        u64(size.em.raw);
    u64(policy.emojiSequencesMustLigate | policy.rasterizerInterpretsBytecode << 1);
    u64(policy.candidateLimit);
    const d = h.finish();
    ubyte[16] key = d[0 .. 16];
    return key;
}
