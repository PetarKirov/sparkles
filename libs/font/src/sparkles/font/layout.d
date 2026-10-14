/**
Layout inspection of `GSUB` and `GPOS` (`docs/specs/font/variation-metrics.md`
§ 8, FTI7–FTI9, FTM13; `SPEC.md` FTI2, FTI3, FTA11).

`layout` reads a table's header. `layoutScripts` lists its scripts, each with
its default language system and its language systems; `features` lists the
features one language system enables, with their lookup indices, and at an
instance applies the first FeatureVariations record whose condition set holds
(FTI8). `lookup` reads one lookup's header, and `substitutions` walks a `GSUB`
lookup's records lazily, unwrapping extensions and listing, never following,
the lookups a contextual rule invokes.

Every list reports a malformed entry as that entry's error and keeps the
others readable (FTA11), unlike HarfBuzz's whole-table rejection. An index
read from the font that lies past the array it indexes is `badValue`; a
caller's index past a list is `indexOutOfRange` (FTM13). Views are built per
query, an O(1) header read; offsets shared by several records are re-read,
never cached. Nothing here allocates or asserts on font data.
*/
module sparkles.font.layout;

import sparkles.font.bytes : be16, be32, bes16, fits, searchTag, slice;
import sparkles.font.coverage : Coverage;
import sparkles.font.errors : FontError, FontErrorKind, FontResult, fontErr, fontOk, Tag, tableError;
import sparkles.font.face : Face;
import sparkles.font.instance : Instance;
import sparkles.font.tables : locate, shortTable;
import sparkles.font.variations : NormalizedCoords;

@safe pure nothrow @nogc:

/// The two layout tables.
enum LayoutTable : ubyte
{
    gsub,
    gpos,
}

/// The tag of `table`: `GSUB` or `GPOS`.
Tag layoutTag(LayoutTable table) => Tag(table == LayoutTable.gsub ? 0x4753_5542 : 0x4750_4F53);

///
@("layout.layoutTag")
@safe pure nothrow @nogc
unittest
{
    assert(layoutTag(LayoutTable.gsub) == Tag("GSUB"));
    assert(layoutTag(LayoutTable.gpos) == Tag("GPOS"));
}

// ---------------------------------------------------------------------------
// Borrowed runs
// ---------------------------------------------------------------------------

/**
A borrowed run of big-endian `uint16` values: a random-access range read
from the font bytes on access, O(1) per element.
*/
struct UInt16Run
{
    @safe pure nothrow @nogc:

    private const(ubyte)[] bytes_;
    private size_t begin_, end_;

    private this(return scope const(ubyte)[] bytes)
    {
        bytes_ = bytes;
        end_ = bytes.length / 2;
    }

    bool empty() const scope => begin_ == end_;
    size_t length() const scope => end_ - begin_;

    ushort front() const scope
    in (!empty)
        => this[0];

    ushort back() const scope
    in (!empty)
        => this[length - 1];

    ushort opIndex(size_t i) const scope
    in (i < length)
        => be16(bytes_, 2 * (begin_ + i));

    void popFront() scope
    in (!empty)
    {
        ++begin_;
    }

    void popBack() scope
    in (!empty)
    {
        --end_;
    }

    typeof(this) save() const return scope => this;
}

/// The `count` values at `at` in `data`; callers check that they fit.
private UInt16Run run(return scope const(ubyte)[] data, ulong at, ulong count)
    => UInt16Run(slice(data, at, 2 * count));

/**
A glyph sequence (FTI9): an optional leading glyph (the coverage glyph of a
ligature or a contextual rule, or a computed output) followed by a borrowed
run of big-endian glyph IDs. A random-access range, O(1) per element.
*/
struct GlyphSequence
{
    @safe pure nothrow @nogc:

    private bool lead_;
    private ushort leading_;
    private UInt16Run run_;

    /// Whether the sequence starts with a glyph that is not in `run`.
    bool hasLeadingGlyph() const scope => lead_;

    /// That glyph.
    ushort leadingGlyph() const scope
    in (lead_)
        => leading_;

    /// The borrowed run after the leading glyph.
    UInt16Run run() const return scope => run_;

    bool empty() const scope => !lead_ && run_.empty;
    size_t length() const scope => (lead_ ? 1 : 0) + run_.length;

    ushort front() const scope
    in (!empty)
        => this[0];

    ushort back() const scope
    in (!empty)
        => this[length - 1];

    ushort opIndex(size_t i) const scope
    in (i < length)
        => lead_ ? (i == 0 ? leading_ : run_[i - 1]) : run_[i];

    void popFront() scope
    in (!empty)
    {
        if (lead_)
            lead_ = false;
        else
            run_.popFront();
    }

    void popBack() scope
    in (!empty)
    {
        if (!run_.empty)
            run_.popBack();
        else
            lead_ = false;
    }

    typeof(this) save() const return scope => this;
}

private GlyphSequence sequence(ushort leading) => GlyphSequence(true, leading);
private GlyphSequence sequence(UInt16Run r) => GlyphSequence(false, 0, r);
private GlyphSequence sequence(ushort leading, UInt16Run r) => GlyphSequence(true, leading, r);

/**
Indices read from the font into a list (features or lookups): a random-access
range whose elements are each index, `badValue` when it lies past the list,
or the list's own error when the list is unreadable (FTM13).
*/
struct LayoutIndices
{
    @safe pure nothrow @nogc:

    private UInt16Run run_;
    private uint bound_;
    private bool boundBroken_;
    private FontError boundError_;
    private Tag tag_;
    private ulong start_, at_; // the first stored index, from the table start

    /// The stored values, unchecked.
    UInt16Run raw() const return scope => run_;

    bool empty() const scope => run_.empty;
    size_t length() const scope => run_.length;

    FontResult!ushort front() const scope
    in (!empty)
        => this[0];

    FontResult!ushort back() const scope
    in (!empty)
        => this[length - 1];

    FontResult!ushort opIndex(size_t i) const scope
    in (i < length)
    {
        if (boundBroken_)
            return fontErr!ushort(boundError_);
        ushort value = run_[i];
        if (value >= bound_)
            return fontErr!ushort(tableError(FontErrorKind.badValue, tag_, start_, at_ + 2 * (run_.begin_ + i)));
        return fontOk(value);
    }

    void popFront() scope
    in (!empty)
    {
        run_.popFront();
    }

    void popBack() scope
    in (!empty)
    {
        run_.popBack();
    }

    typeof(this) save() const return scope => this;
}

// ---------------------------------------------------------------------------
// The header (FTI7)
// ---------------------------------------------------------------------------

/// A list the header points to: its count field and count, or why it is unreadable.
private struct List
{
    bool broken;
    FontError error;
    ulong at; // the count field, from the table start
    uint count;
}

/**
The `GSUB` or `GPOS` header: major version 1, any minor; the FeatureVariations
offset exists from 1.1. A null script, feature or lookup list offset is an
empty list. A list whose offset lies outside the table, or whose records run
past it, is recorded and returned by the operations that read it.
*/
struct Layout
{
    @safe pure nothrow @nogc:

    private const(ubyte)[] data_;
    private ulong start_;
    private Tag tag_;
    private LayoutTable table_;
    private ushort major_, minor_;
    private List scripts_, features_, lookups_;
    private bool varPresent_, varBroken_;
    private FontError varError_;
    private ulong varAt_;
    private uint varCount_;

    /// Which table.
    LayoutTable table() const scope => table_;

    /// The stored version.
    ushort majorVersion() const scope => major_;
    /// ditto
    ushort minorVersion() const scope => minor_;

    /// The number of scripts, features and lookups; 0 for a null or unreadable list.
    uint scriptCount() const scope => scripts_.count;
    /// ditto
    uint featureCount() const scope => features_.count;
    /// ditto
    uint lookupCount() const scope => lookups_.count;

    /// Whether the table (1.1 or later) has a non-null FeatureVariations offset.
    bool hasFeatureVariations() const scope => varPresent_;

    private FontError error(FontErrorKind kind, ulong relative) const scope
        => tableError(kind, tag_, start_, relative);

    private List list(ulong fieldAt, uint recordSize) const scope
    {
        List r;
        const offset = be16(data_, cast(size_t) fieldAt);
        if (offset == 0)
            return r;
        if (offset >= data_.length)
            return List(true, error(FontErrorKind.badOffset, fieldAt));
        if (!fits(data_.length, offset, 2))
            return List(true, error(FontErrorKind.truncated, offset));
        r.at = offset;
        r.count = be16(data_, offset);
        if (!fits(data_.length, r.at + 2, ulong(recordSize) * r.count))
            return List(true, error(FontErrorKind.truncated, r.at + 2));
        return r;
    }

    private void readVariations() scope
    {
        const offset = be32(data_, 10);
        if (offset == 0)
            return;
        varPresent_ = true;
        if (offset >= data_.length)
            return failVariations(error(FontErrorKind.badOffset, 10));
        if (!fits(data_.length, offset, 8))
            return failVariations(error(FontErrorKind.truncated, offset));
        if (be16(data_, offset) != 1)
            return failVariations(error(FontErrorKind.unsupportedVersion, offset));
        if (!fits(data_.length, ulong(offset) + 8, 8UL * be32(data_, offset + 4)))
            return failVariations(error(FontErrorKind.truncated, ulong(offset) + 8));
        varAt_ = offset;
        varCount_ = be32(data_, offset + 4);
    }

    private void failVariations(FontError e) scope
    {
        varBroken_ = true;
        varError_ = e;
    }
}

/**
The face's `table` header (FTI7): `missingTable` without one; `truncated`
for a header past the table (10 bytes, 14 from 1.1); `unsupportedVersion`
for a major version other than 1. Costs O(1).
*/
FontResult!Layout layout(return scope const Face face, LayoutTable table)
{
    const tag = layoutTag(table);
    auto at = locate(face, tag);
    if (at.hasError)
        return fontErr!Layout(at.error);
    const d = at.value.data;
    if (d.length < 4)
        return shortTable!Layout(tag, at.value, 10);
    Layout l;
    l.data_ = d;
    l.start_ = at.value.start;
    l.tag_ = tag;
    l.table_ = table;
    l.major_ = be16(d, 0);
    l.minor_ = be16(d, 2);
    if (l.major_ != 1)
        return fontErr!Layout(l.error(FontErrorKind.unsupportedVersion, 0));
    const needed = l.minor_ >= 1 ? 14 : 10;
    if (d.length < needed)
        return shortTable!Layout(tag, at.value, needed);
    l.scripts_ = l.list(4, 6);
    l.features_ = l.list(6, 6);
    l.lookups_ = l.list(8, 2);
    if (l.minor_ >= 1)
        l.readVariations();
    return fontOk(l);
}

// ---------------------------------------------------------------------------
// Scripts and language systems (FTI7)
// ---------------------------------------------------------------------------

/**
A language system: the required feature, when there is one, and the feature
indices it enables. `present` is false for a script without a default
language system, or a language the script does not list.
*/
struct LangSys
{
    @safe pure nothrow @nogc:

    /// Whether the language system exists.
    bool present;
    /// Its tag; `Tag.init` for a script's default language system.
    Tag tag;
    private bool required_;
    private ushort requiredIndex_;
    private ulong at_; // the LangSys table, from the table start
    /// The feature indices, each checked against the feature list.
    LayoutIndices featureIndices;

    /// Whether `requiredFeatureIndex` is not `0xFFFF`.
    bool hasRequiredFeature() const scope => required_;

    /// The required feature's stored index; `0xFFFF` means none.
    ushort requiredFeatureIndex() const scope => required_ ? requiredIndex_ : 0xFFFF;
}

/// A script: its tag, its default language system, and its language systems.
struct LayoutScript
{
    @safe pure nothrow @nogc:

    private Layout layout_;
    private Tag tag_;
    private ulong at_; // the Script table
    private ushort langCount_;

    /// The script's tag.
    Tag tag() const scope => tag_;

    /// Whether the default language system offset is not null.
    bool hasDefaultLanguage() const scope => be16(layout_.data_, cast(size_t) at_) != 0;

    /// The default language system: not `present` when null; its error when unreadable. O(1).
    FontResult!LangSys defaultLanguage() const return scope
        => layout_.langSys(Tag.init, at_, at_, true);

    /// The language systems, in stored order, as a random-access range of `FontResult!LangSys`.
    LanguageSystems languages() const return scope => LanguageSystems(this, 0, langCount_);

    /**
    The language system `language` by binary search, O(log n): the default one
    for `Tag.init`; not `present` when the script does not list it.
    */
    FontResult!LangSys language(Tag language) const return scope
    {
        if (language.isNone)
            return defaultLanguage;
        const i = searchTag(layout_.data_, at_ + 4, langCount_, 6, language);
        if (i < 0)
            return fontOk(LangSys.init);
        return languageAt(i);
    }

    private FontResult!LangSys languageAt(size_t i) const return scope
    {
        const recordAt = at_ + 4 + 6 * i;
        return layout_.langSys(Tag(be32(layout_.data_, cast(size_t) recordAt)), recordAt + 4, at_, false);
    }
}

/// A script's language systems: a random-access range of `FontResult!LangSys` (FTA11).
struct LanguageSystems
{
    @safe pure nothrow @nogc:

    private LayoutScript script_;
    private size_t begin_, end_;

    bool empty() const scope => begin_ == end_;
    size_t length() const scope => end_ - begin_;

    /// The `i`th record's tag, readable even when its language system is not.
    Tag tag(size_t i) const scope
    in (i < length)
        => Tag(be32(script_.layout_.data_, cast(size_t)(script_.at_ + 4 + 6 * (begin_ + i))));

    FontResult!LangSys front() const return scope
    in (!empty)
        => this[0];

    FontResult!LangSys back() const return scope
    in (!empty)
        => this[length - 1];

    FontResult!LangSys opIndex(size_t i) const return scope
    in (i < length)
        => script_.languageAt(begin_ + i);

    void popFront() scope
    in (!empty)
    {
        ++begin_;
    }

    void popBack() scope
    in (!empty)
    {
        --end_;
    }

    typeof(this) save() const return scope => this;
}

/// A table's scripts: a random-access range of `FontResult!LayoutScript` (FTA11).
struct LayoutScripts
{
    @safe pure nothrow @nogc:

    private Layout layout_;
    private size_t begin_, end_;

    bool empty() const scope => begin_ == end_;
    size_t length() const scope => end_ - begin_;

    /// The `i`th record's tag, readable even when its script is not.
    Tag tag(size_t i) const scope
    in (i < length)
        => Tag(be32(layout_.data_, cast(size_t)(layout_.scripts_.at + 2 + 6 * (begin_ + i))));

    FontResult!LayoutScript front() const return scope
    in (!empty)
        => this[0];

    FontResult!LayoutScript back() const return scope
    in (!empty)
        => this[length - 1];

    /// The `i`th script; `badOffset` at its record for an offset outside the table.
    FontResult!LayoutScript opIndex(size_t i) const return scope
    in (i < length)
        => layout_.scriptAt(begin_ + i);

    void popFront() scope
    in (!empty)
    {
        ++begin_;
    }

    void popBack() scope
    in (!empty)
    {
        --end_;
    }

    typeof(this) save() const return scope => this;
}

private FontResult!LayoutScript scriptAt(return scope const ref Layout l, size_t i)
{
    const d = l.data_;
    const recordAt = l.scripts_.at + 2 + 6 * i;
    LayoutScript s;
    s.layout_ = l;
    s.tag_ = Tag(be32(d, cast(size_t) recordAt));
    const offset = be16(d, cast(size_t) recordAt + 4);
    s.at_ = l.scripts_.at + offset;
    if (offset == 0 || s.at_ >= d.length)
        return fontErr!LayoutScript(l.error(FontErrorKind.badOffset, recordAt + 4));
    if (!fits(d.length, s.at_, 4))
        return fontErr!LayoutScript(l.error(FontErrorKind.truncated, s.at_));
    s.langCount_ = be16(d, cast(size_t) s.at_ + 2);
    if (!fits(d.length, s.at_ + 4, 6UL * s.langCount_))
        return fontErr!LayoutScript(l.error(FontErrorKind.truncated, s.at_ + 4));
    return fontOk(s);
}

/**
The LangSys whose 16-bit offset, from `base`, is the field at `fieldAt`. A
null offset is an absent language system when `nullIsAbsent`, else
`badOffset`, as is an offset outside the table.
*/
private FontResult!LangSys langSys(return scope const ref Layout l, Tag tag, ulong fieldAt, ulong base,
    bool nullIsAbsent)
{
    const d = l.data_;
    const offset = be16(d, cast(size_t) fieldAt);
    if (offset == 0 && nullIsAbsent)
        return fontOk(LangSys.init);
    LangSys s;
    s.at_ = base + offset;
    if (offset == 0 || s.at_ >= d.length)
        return fontErr!LangSys(l.error(FontErrorKind.badOffset, fieldAt));
    if (!fits(d.length, s.at_, 6))
        return fontErr!LangSys(l.error(FontErrorKind.truncated, s.at_));
    const p = cast(size_t) s.at_;
    s.present = true;
    s.tag = tag;
    s.requiredIndex_ = be16(d, p + 2);
    s.required_ = s.requiredIndex_ != 0xFFFF;
    const count = be16(d, p + 4);
    if (!fits(d.length, s.at_ + 6, 2UL * count))
        return fontErr!LangSys(l.error(FontErrorKind.truncated, s.at_ + 6));
    s.featureIndices = l.indices(s.at_ + 6, count, l.features_);
    return fontOk(s);
}

/// The `count` indices at `at`, checked against `list`.
private LayoutIndices indices(return scope const ref Layout l, ulong at, ulong count, in List list)
    => LayoutIndices(run(l.data_, at, count), list.count, list.broken, list.error, l.tag_, l.start_, at);

/**
The scripts of the face's `table` (FTI7), a random-access range, O(1) per
element: the header's errors, or the script list's when it is unreadable.
Costs O(1).
*/
FontResult!LayoutScripts layoutScripts(return scope const Face face, LayoutTable table)
{
    const l = layout(face, table);
    if (l.hasError)
        return fontErr!LayoutScripts(l.error);
    if (l.value.scripts_.broken)
        return fontErr!LayoutScripts(l.value.scripts_.error);
    return fontOk(LayoutScripts(l.value, 0, l.value.scripts_.count));
}

// ---------------------------------------------------------------------------
// Features and feature variations (FTI7, FTI8)
// ---------------------------------------------------------------------------

/**
A feature one language system enables: its tag, its index in the feature
list, whether it is the required feature, and its lookup indices — the
alternate feature table's when a FeatureVariations record substituted it.
*/
struct Feature
{
    Tag tag;
    ushort index;
    bool required;
    /// Whether the lookups are an alternate feature table's (FTI8).
    bool substituted;
    LayoutIndices lookups;
}

/// Which FeatureVariations record `features` applied at an instance, if any.
struct VariationChoice
{
    /// Whether a record's condition set held.
    bool applied;
    /// That record's index.
    uint recordIndex;
}

/**
The features of one language system: a random-access range of
`FontResult!Feature`, the required feature first, then the feature indices in
stored order. `found` is false, and the range empty, when the script or the
language system is not in the table.
*/
struct Features
{
    @safe pure nothrow @nogc:

    private Layout layout_;
    private LangSys langSys_;
    private bool found_;
    private bool varBroken_;
    private FontError varError_;
    private VariationChoice choice_;
    private ulong substAt_; // the chosen FeatureTableSubstitution
    private ushort substCount_;
    private size_t begin_, end_;

    /// Whether the script and language system were found.
    bool found() const scope => found_;

    /// The language system the features come from.
    LangSys langSys() const return scope => langSys_;

    /**
    The FeatureVariations record applied (FTI8): none on a face, and none at
    an instance whose table has no record that holds. When the
    FeatureVariations table, or the chosen record's substitution table, is
    unreadable, its error, which every feature then returns too.
    */
    FontResult!VariationChoice variation() const scope
        => varBroken_ ? fontErr!VariationChoice(varError_) : fontOk!VariationChoice(choice_);

    bool empty() const scope => begin_ == end_;
    size_t length() const scope => end_ - begin_;

    FontResult!Feature front() const return scope
    in (!empty)
        => this[0];

    FontResult!Feature back() const return scope
    in (!empty)
        => this[length - 1];

    /**
    The `i`th feature: `badValue` for a feature index past the feature list,
    `badOffset` for a record or alternate feature table outside the table,
    `truncated` for one running past it. Costs O(log S) for `S` substitutions.
    */
    FontResult!Feature opIndex(size_t i) const return scope
    in (i < length)
    {
        const k = begin_ + i;
        alias l = layout_;
        const d = l.data_;
        Feature f;
        ulong fieldAt;
        if (langSys_.required_ && k == 0)
        {
            f.required = true;
            f.index = langSys_.requiredIndex_;
            fieldAt = langSys_.at_ + 2;
        }
        else
        {
            const slot = k - (langSys_.required_ ? 1 : 0);
            f.index = langSys_.featureIndices.run_[slot];
            fieldAt = langSys_.featureIndices.at_ + 2 * slot;
        }
        if (l.features_.broken)
            return fontErr!Feature(l.features_.error);
        if (f.index >= l.features_.count)
            return fontErr!Feature(l.error(FontErrorKind.badValue, fieldAt));
        const recordAt = l.features_.at + 2 + 6 * f.index;
        f.tag = Tag(be32(d, cast(size_t) recordAt));
        const offset = be16(d, cast(size_t) recordAt + 4);
        ulong featureAt = l.features_.at + offset;
        if (offset == 0 || featureAt >= d.length)
            return fontErr!Feature(l.error(FontErrorKind.badOffset, recordAt + 4));
        if (varBroken_)
            return fontErr!Feature(varError_);
        if (choice_.applied)
        {
            const s = searchIndex(d, substAt_ + 6, substCount_, f.index);
            if (s >= 0)
            {
                const altField = substAt_ + 6 + 6 * s + 2;
                const alt = be32(d, cast(size_t) altField);
                featureAt = substAt_ + alt;
                if (alt == 0 || featureAt >= d.length)
                    return fontErr!Feature(l.error(FontErrorKind.badOffset, altField));
                f.substituted = true;
            }
        }
        const lookups = l.featureTable(featureAt);
        if (lookups.hasError)
            return fontErr!Feature(lookups.error);
        return fontOk(Feature(f.tag, f.index, f.required, f.substituted, lookups.value));
    }

    void popFront() scope
    in (!empty)
    {
        ++begin_;
    }

    void popBack() scope
    in (!empty)
    {
        --end_;
    }

    typeof(this) save() const return scope => this;
}

/// The index of `value` among `count` 6-byte records whose first field it is, or -1 (binary search).
private ptrdiff_t searchIndex(scope const(ubyte)[] data, ulong at, size_t count, ushort value)
{
    size_t lo = 0, hi = count;
    while (lo < hi)
    {
        const mid = lo + (hi - lo) / 2;
        const stored = be16(data, cast(size_t)(at + 6 * mid));
        if (stored == value)
            return mid;
        if (stored < value)
            lo = mid + 1;
        else
            hi = mid;
    }
    return -1;
}

/// The lookup indices of the Feature table at `at`; `truncated` past the table.
private FontResult!LayoutIndices featureTable(return scope const ref Layout l, ulong at)
{
    const d = l.data_;
    if (!fits(d.length, at, 4))
        return fontErr!LayoutIndices(l.error(FontErrorKind.truncated, at));
    const count = be16(d, cast(size_t) at + 2);
    if (!fits(d.length, at + 4, 2UL * count))
        return fontErr!LayoutIndices(l.error(FontErrorKind.truncated, at + 4));
    return fontOk(l.indices(at + 4, count, l.lookups_));
}

/**
Whether FeatureVariations record `r`'s condition set holds at `coords`: a
null offset or an empty set holds; a format-1 condition holds when
`min ≤ coord ≤ max`, an axis past `coords` reading 0. A condition of another
format is `unsupportedVersion`, and an unreadable set its error; selection
treats both as not holding. Costs O(C).
*/
private FontResult!bool conditionSet(scope const ref Layout l, uint r, scope NormalizedCoords coords)
{
    const d = l.data_;
    const recordAt = l.varAt_ + 8 + 8UL * r;
    const offset = be32(d, cast(size_t) recordAt);
    if (offset == 0)
        return fontOk(true);
    const setAt = l.varAt_ + offset;
    if (setAt >= d.length)
        return fontErr!bool(l.error(FontErrorKind.badOffset, recordAt));
    if (!fits(d.length, setAt, 2))
        return fontErr!bool(l.error(FontErrorKind.truncated, setAt));
    const count = be16(d, cast(size_t) setAt);
    if (!fits(d.length, setAt + 2, 4UL * count))
        return fontErr!bool(l.error(FontErrorKind.truncated, setAt + 2));
    bool holds = true, unsupported;
    ulong unsupportedAt;
    foreach (c; 0 .. count)
    {
        const fieldAt = setAt + 2 + 4 * c;
        const conditionOffset = be32(d, cast(size_t) fieldAt);
        const at = setAt + conditionOffset;
        if (conditionOffset == 0 || at >= d.length)
            return fontErr!bool(l.error(FontErrorKind.badOffset, fieldAt));
        if (!fits(d.length, at, 2))
            return fontErr!bool(l.error(FontErrorKind.truncated, at));
        const p = cast(size_t) at;
        if (be16(d, p) != 1)
        {
            if (!unsupported)
            {
                unsupported = true;
                unsupportedAt = at;
            }
            continue;
        }
        if (!fits(d.length, at, 8))
            return fontErr!bool(l.error(FontErrorKind.truncated, at));
        const axis = be16(d, p + 2);
        const coord = axis < coords.length ? coords[axis] : 0;
        if (coord < bes16(d, p + 4) || coord > bes16(d, p + 6))
            holds = false;
    }
    if (unsupported)
        return fontErr!bool(l.error(FontErrorKind.unsupportedVersion, unsupportedAt));
    return fontOk(holds);
}

/// The FeatureTableSubstitution of record `r`: its position and count (none for a null offset).
private struct SubstitutionTable
{
    ulong at;
    ushort count;
}

private FontResult!SubstitutionTable substitutionTable(scope const ref Layout l, uint r)
{
    const d = l.data_;
    const fieldAt = l.varAt_ + 8 + 8UL * r + 4;
    const offset = be32(d, cast(size_t) fieldAt);
    if (offset == 0)
        return fontOk(SubstitutionTable.init);
    const at = l.varAt_ + offset;
    if (at >= d.length)
        return fontErr!SubstitutionTable(l.error(FontErrorKind.badOffset, fieldAt));
    if (!fits(d.length, at, 6))
        return fontErr!SubstitutionTable(l.error(FontErrorKind.truncated, at));
    if (be16(d, cast(size_t) at) != 1)
        return fontErr!SubstitutionTable(l.error(FontErrorKind.unsupportedVersion, at));
    const count = be16(d, cast(size_t) at + 4);
    if (!fits(d.length, at + 6, 6UL * count))
        return fontErr!SubstitutionTable(l.error(FontErrorKind.truncated, at + 6));
    return fontOk(SubstitutionTable(at, count));
}

/// The features of `script`/`language`; at an instance, with FeatureVariations applied at `coords`.
private FontResult!Features findFeatures(return scope const ref Layout l, Tag script, Tag language,
    bool atInstance, scope NormalizedCoords coords)
{
    Features none;
    none.layout_ = l;
    if (l.scripts_.broken)
        return fontErr!Features(l.scripts_.error);
    const si = searchTag(l.data_, l.scripts_.at + 2, l.scripts_.count, 6, script);
    if (si < 0)
        return fontOk(none);
    const s = l.scriptAt(si);
    if (s.hasError)
        return fontErr!Features(s.error);
    const ls = s.value.language(language);
    if (ls.hasError)
        return fontErr!Features(ls.error);
    if (!ls.value.present)
        return fontOk(none);
    Features f;
    f.layout_ = l;
    f.found_ = true;
    f.langSys_ = ls.value;
    f.end_ = ls.value.featureIndices.length + (ls.value.required_ ? 1 : 0);
    if (!atInstance || !l.varPresent_)
        return fontOk(f);
    if (l.varBroken_)
    {
        f.varBroken_ = true;
        f.varError_ = l.varError_;
        return fontOk(f);
    }
    foreach (r; 0 .. l.varCount_)
    {
        const holds = l.conditionSet(r, coords);
        if (!holds.hasValue || !holds.value)
            continue;
        f.choice_ = VariationChoice(true, r);
        const table = l.substitutionTable(r);
        if (table.hasError)
        {
            f.varBroken_ = true;
            f.varError_ = table.error;
        }
        else
        {
            f.substAt_ = table.value.at;
            f.substCount_ = table.value.count;
        }
        break;
    }
    return fontOk(f);
}

/**
The features language system `language` of `script` enables in the face's
`table`, with their default lookups (FTI7); `Tag.init` names the script's
default language system. A script or language system the table does not
list gives an empty range with `found` false. The header's, script list's,
script's or language system's error is returned. Costs O(log n).
*/
FontResult!Features features(return scope const Face face, LayoutTable table, Tag script, Tag language)
{
    const l = layout(face, table);
    if (l.hasError)
        return fontErr!Features(l.error);
    return l.value.findFeatures(script, language, false, null);
}

/**
As `features` on the face, at `inst` (FTI8): a table of version 1.1 or later
applies its first FeatureVariations record whose condition set holds at the
instance's normalized coordinates, and `Features.variation` names it. A
substituted feature reports the alternate feature table's lookups; a feature
the record does not substitute keeps its default ones. Costs
O(R · C + log n) for `R` records of `C` conditions.
*/
FontResult!Features features(return scope const Instance inst, LayoutTable table, Tag script, Tag language)
{
    const l = layout(inst.face, table);
    if (l.hasError)
        return fontErr!Features(l.error);
    return l.value.findFeatures(script, language, true, inst.coords);
}

/**
The number of FeatureVariations records in the face's `table`: 0 before
version 1.1 or for a null offset; the FeatureVariations table's error when it
is unreadable. Costs O(1).
*/
FontResult!uint featureVariationCount(scope const Face face, LayoutTable table)
{
    const l = layout(face, table);
    if (l.hasError)
        return fontErr!uint(l.error);
    if (l.value.varBroken_)
        return fontErr!uint(l.value.varError_);
    return fontOk!uint(l.value.varCount_);
}

/// One FeatureVariations record at an instance: whether its condition set holds.
struct FeatureVariationRecord
{
    uint index;
    bool holds;
}

/**
FeatureVariations record `recordIndex` evaluated at `inst` (FTI8):
`indexOutOfRange` past `featureVariationCount`; `unsupportedVersion` when its
condition set has a condition of a format other than 1 (selection treats the
record as not holding); its condition set's error when unreadable (likewise).
Costs O(C).
*/
FontResult!FeatureVariationRecord featureVariation(scope const Instance inst, LayoutTable table, uint recordIndex)
{
    const l = layout(inst.face, table);
    if (l.hasError)
        return fontErr!FeatureVariationRecord(l.error);
    if (l.value.varBroken_)
        return fontErr!FeatureVariationRecord(l.value.varError_);
    if (recordIndex >= l.value.varCount_)
        return fontErr!FeatureVariationRecord(FontError(FontErrorKind.indexOutOfRange, l.value.tag_));
    const holds = l.value.conditionSet(recordIndex, inst.coords);
    if (holds.hasError)
        return fontErr!FeatureVariationRecord(holds.error);
    return fontOk(FeatureVariationRecord(recordIndex, holds.value));
}

/// One substitution of a FeatureVariations record: a feature index and its alternate lookups.
struct FeatureSubstitution
{
    ushort featureIndex;
    LayoutIndices lookups;
}

/**
The substitutions of one FeatureVariations record, in stored order: a
random-access range of `FontResult!FeatureSubstitution`.
*/
struct FeatureSubstitutions
{
    @safe pure nothrow @nogc:

    private Layout layout_;
    private ulong at_; // the FeatureTableSubstitution
    private size_t begin_, end_;

    bool empty() const scope => begin_ == end_;
    size_t length() const scope => end_ - begin_;

    /// The `i`th record's stored feature index, unchecked.
    ushort featureIndex(size_t i) const scope
    in (i < length)
        => be16(layout_.data_, cast(size_t)(at_ + 6 + 6 * (begin_ + i)));

    FontResult!FeatureSubstitution front() const return scope
    in (!empty)
        => this[0];

    FontResult!FeatureSubstitution back() const return scope
    in (!empty)
        => this[length - 1];

    /**
    The `i`th substitution: `badValue` for a feature index past the feature
    list (the feature keeps its default lookups), `badOffset` for an alternate
    feature table outside the table.
    */
    FontResult!FeatureSubstitution opIndex(size_t i) const return scope
    in (i < length)
    {
        alias l = layout_;
        const recordAt = at_ + 6 + 6 * (begin_ + i);
        FeatureSubstitution s;
        s.featureIndex = be16(l.data_, cast(size_t) recordAt);
        if (l.features_.broken)
            return fontErr!FeatureSubstitution(l.features_.error);
        if (s.featureIndex >= l.features_.count)
            return fontErr!FeatureSubstitution(l.error(FontErrorKind.badValue, recordAt));
        const offset = be32(l.data_, cast(size_t) recordAt + 2);
        const featureAt = at_ + offset;
        if (offset == 0 || featureAt >= l.data_.length)
            return fontErr!FeatureSubstitution(l.error(FontErrorKind.badOffset, recordAt + 2));
        const lookups = l.featureTable(featureAt);
        if (lookups.hasError)
            return fontErr!FeatureSubstitution(lookups.error);
        return fontOk(FeatureSubstitution(s.featureIndex, lookups.value));
    }

    void popFront() scope
    in (!empty)
    {
        ++begin_;
    }

    void popBack() scope
    in (!empty)
    {
        --end_;
    }

    typeof(this) save() const return scope => this;
}

/**
The substitutions of FeatureVariations record `recordIndex` in the face's
`table`: `indexOutOfRange` past `featureVariationCount`; empty for a null
substitution offset; `badOffset`, `truncated` or `unsupportedVersion` (a
major version other than 1) for an unreadable substitution table. Costs O(1).
*/
FontResult!FeatureSubstitutions featureSubstitutions(return scope const Face face, LayoutTable table,
    uint recordIndex)
{
    const l = layout(face, table);
    if (l.hasError)
        return fontErr!FeatureSubstitutions(l.error);
    if (l.value.varBroken_)
        return fontErr!FeatureSubstitutions(l.value.varError_);
    if (recordIndex >= l.value.varCount_)
        return fontErr!FeatureSubstitutions(FontError(FontErrorKind.indexOutOfRange, l.value.tag_));
    const t = l.value.substitutionTable(recordIndex);
    if (t.hasError)
        return fontErr!FeatureSubstitutions(t.error);
    return fontOk(FeatureSubstitutions(l.value, t.value.at, 0, t.value.count));
}

// ---------------------------------------------------------------------------
// Lookups (FTI7)
// ---------------------------------------------------------------------------

/// The `lookupFlag` bit that says a mark filtering set follows the subtable offsets.
enum ushort useMarkFilteringSet = 0x0010;

/**
A lookup's header: its type, its flag, its subtable count, and its mark
filtering set when the flag has `useMarkFilteringSet`.
*/
struct Lookup
{
    ushort index;
    ushort type;
    ushort flag;
    ushort subtableCount;
    bool hasMarkFilteringSet;
    ushort markFilteringSet;
}

/// The Lookup table of lookup `index`, its header checked to fit.
private FontResult!ulong lookupAt(scope const ref Layout l, uint index)
{
    const d = l.data_;
    if (l.lookups_.broken)
        return fontErr!ulong(l.lookups_.error);
    if (index >= l.lookups_.count)
        return fontErr!ulong(FontError(FontErrorKind.indexOutOfRange, l.tag_));
    const fieldAt = l.lookups_.at + 2 + 2UL * index;
    const offset = be16(d, cast(size_t) fieldAt);
    const at = l.lookups_.at + offset;
    if (offset == 0 || at >= d.length)
        return fontErr!ulong(l.error(FontErrorKind.badOffset, fieldAt));
    if (!fits(d.length, at, 6))
        return fontErr!ulong(l.error(FontErrorKind.truncated, at));
    const count = be16(d, cast(size_t) at + 4);
    const flag = be16(d, cast(size_t) at + 2);
    const length = 6 + 2UL * count + (flag & useMarkFilteringSet ? 2 : 0);
    if (!fits(d.length, at, length))
        return fontErr!ulong(l.error(FontErrorKind.truncated, at + 6));
    return fontOk!ulong(at);
}

/**
Lookup `index` of the face's `table` (FTI7): `indexOutOfRange` past the
lookup list; the list's error when it is unreadable; `badOffset` for a
lookup outside the table; `truncated` for a header or subtable offset array
running past it. Costs O(1).
*/
FontResult!Lookup lookup(scope const Face face, LayoutTable table, uint index)
{
    const l = layout(face, table);
    if (l.hasError)
        return fontErr!Lookup(l.error);
    const at = l.value.lookupAt(index);
    if (at.hasError)
        return fontErr!Lookup(at.error);
    const d = l.value.data_;
    const p = cast(size_t) at.value;
    Lookup r;
    r.index = cast(ushort) index;
    r.type = be16(d, p);
    r.flag = be16(d, p + 2);
    r.subtableCount = be16(d, p + 4);
    r.hasMarkFilteringSet = (r.flag & useMarkFilteringSet) != 0;
    if (r.hasMarkFilteringSet)
        r.markFilteringSet = be16(d, p + 6 + 2 * r.subtableCount);
    return fontOk(r);
}

// ---------------------------------------------------------------------------
// Substitutions (FTI9)
// ---------------------------------------------------------------------------

/// What a contextual record's input positions hold.
enum ContextInput : ubyte
{
    /// No context: lookup types 1–4.
    none,
    /// Glyph IDs (format 1).
    glyphs,
    /// Class values (format 2); the leading one is the rule set's class.
    classes,
    /// Coverage tables, not listed (format 3, and type 8).
    coverages,
}

/// A lookup a contextual rule invokes, and the input position it applies at.
struct SequenceLookup
{
    ushort sequenceIndex;
    ushort lookupIndex;
}

/**
The SequenceLookupRecords of a contextual rule: a random-access range of
`FontResult!SequenceLookup`, `badValue` for a sequence index past the input
or a lookup index past the lookup list. The lookups are listed, never
followed.
*/
struct SequenceLookups
{
    @safe pure nothrow @nogc:

    private const(ubyte)[] data_;
    private Tag tag_;
    private ulong start_, at_;
    private uint inputCount_, lookupCount_;
    private size_t begin_, end_;

    bool empty() const scope => begin_ == end_;
    size_t length() const scope => end_ - begin_;

    FontResult!SequenceLookup front() const scope
    in (!empty)
        => this[0];

    FontResult!SequenceLookup back() const scope
    in (!empty)
        => this[length - 1];

    FontResult!SequenceLookup opIndex(size_t i) const scope
    in (i < length)
    {
        const recordAt = at_ + 4 * (begin_ + i);
        auto r = SequenceLookup(be16(data_, cast(size_t) recordAt), be16(data_, cast(size_t) recordAt + 2));
        if (r.sequenceIndex >= inputCount_)
            return fontErr!SequenceLookup(tableError(FontErrorKind.badValue, tag_, start_, recordAt));
        if (r.lookupIndex >= lookupCount_)
            return fontErr!SequenceLookup(tableError(FontErrorKind.badValue, tag_, start_, recordAt + 2));
        return fontOk(r);
    }

    void popFront() scope
    in (!empty)
    {
        ++begin_;
    }

    void popBack() scope
    in (!empty)
    {
        --end_;
    }

    typeof(this) save() const return scope => this;
}

/**
One substitution record (FTI9).

$(UL
    $(LI Types 1–3: `input` is the coverage glyph and `output` its
        substitute, sequence, or one alternate (`alternateIndex`).)
    $(LI Type 4: `input` is the coverage glyph followed by the component
        run, `output` the ligature glyph.)
    $(LI Types 5 and 6: `lookups` lists what the rule invokes. Formats 1
        and 2 give the input (glyphs, or classes led by the rule set's
        class) and, for type 6, `backtrack` and `lookahead`; format 3 gives
        only the counts, its positions being coverages.)
    $(LI Type 8: `input` and `output` are single glyphs; `backtrackCount`
        and `lookaheadCount` mark the context.)
)
`lookupType` is the effective type, never 7; `extension` says the subtable
was reached through an extension.
*/
struct Substitution
{
    @safe pure nothrow @nogc:

    ushort lookupType;
    ushort format;
    /// The subtable's index in its lookup.
    uint subtable;
    /// Whether the subtable was wrapped in an extension (type 7).
    bool extension;
    GlyphSequence input;
    GlyphSequence output;
    /// For type 3, which alternate `output` is.
    uint alternateIndex;
    ContextInput contextInput;
    /// The number of input positions of a contextual record, the first included.
    uint inputCount;
    /// The backtrack and lookahead of a type-6 format-1 or -2 rule (glyphs or classes).
    GlyphSequence backtrack, lookahead;
    /// The number of backtrack and lookahead positions (types 6 and 8).
    uint backtrackCount, lookaheadCount;
    /// The lookups a contextual rule invokes.
    SequenceLookups lookups;

    /// Whether the record has a backtrack or lookahead context.
    bool hasContext() const scope => backtrackCount + lookaheadCount > 0;
}

/**
The records of one `GSUB` lookup, read lazily: a forward range of
`FontResult!Substitution` in subtable order, then coverage order (classes
for format-2 contextual subtables), then stored order. A malformed subtable,
coverage entry or record is one error element, and the range continues
after it.
*/
struct Substitutions
{
    @safe pure nothrow @nogc:

    private enum Mode : ubyte { coverage, classes, single }

    private const(ubyte)[] data_;
    private Tag tag_;
    private ulong start_;
    private uint lookupCount_;
    private ulong lookupAt_;
    private ushort lookupType_;
    private uint subCount_, next_;
    private ushort extType_;

    // The open subtable.
    private bool open_;
    private uint sub_;
    private ulong at_;
    private ushort type_, format_;
    private bool ext_;
    private Mode mode_;
    // The coverage walk: its first record, format and count, and position.
    private ulong covAt_;
    private ushort covFormat_, covCount_;
    private uint covRecord_, covGlyph_;
    private ushort count_; // the subtable's per-coverage-index or class array length
    private ulong arrayAt_; // that array
    private uint entry_;
    // Format 3 and type 8 header facts.
    private ushort backCount_, inCount_, laCount_, seqCount_;
    private ulong seqAt_;

    // The open entry.
    private bool inEntry_;
    private ushort glyph_;
    private uint coverageIndex_;
    private ulong setAt_;
    private uint item_, itemCount_;

    // The current element.
    private bool empty_;
    private bool failed_;
    private FontError error_;
    private Current cur_;

    /// The current record's positions, checked to fit; `front` builds the record from them.
    private static struct Current
    {
        ushort output;
        uint alternate, inputCount, backCount, laCount, seqCount;
        ulong inputAt, inputRun, outputAt, outputRun, backAt, laAt, seqAt;
    }

    bool empty() const scope => empty_;

    /// The current record, or its error. Costs O(1).
    FontResult!Substitution front() const return scope
    in (!empty)
    {
        if (failed_)
            return fontErr!Substitution(error_);
        const d = data_;
        Substitution r;
        r.lookupType = type_;
        r.format = format_;
        r.subtable = sub_;
        r.extension = ext_;
        switch (type_)
        {
            case 1:
                r.input = sequence(glyph_);
                r.output = sequence(cur_.output);
                break;
            case 2: .. case 3:
                r.input = sequence(glyph_);
                r.output = sequence(run(d, cur_.outputAt, cur_.outputRun));
                r.alternateIndex = cur_.alternate;
                break;
            case 4:
                r.input = sequence(glyph_, run(d, cur_.inputAt, cur_.inputRun));
                r.output = sequence(cur_.output);
                break;
            case 5: .. case 6:
                r.contextInput = format_ == 3 ? ContextInput.coverages
                    : format_ == 1 ? ContextInput.glyphs : ContextInput.classes;
                if (format_ != 3)
                    r.input = sequence(glyph_, run(d, cur_.inputAt, cur_.inputRun));
                if (type_ == 6 && format_ != 3)
                {
                    r.backtrack = sequence(run(d, cur_.backAt, cur_.backCount));
                    r.lookahead = sequence(run(d, cur_.laAt, cur_.laCount));
                }
                r.inputCount = cur_.inputCount;
                r.backtrackCount = cur_.backCount;
                r.lookaheadCount = cur_.laCount;
                r.lookups = SequenceLookups(d, tag_, start_, cur_.seqAt, cur_.inputCount, lookupCount_, 0,
                    cur_.seqCount);
                break;
            default: // 8
                r.input = sequence(glyph_);
                r.output = sequence(cur_.output);
                r.contextInput = ContextInput.coverages;
                r.inputCount = 1;
                r.backtrackCount = cur_.backCount;
                r.lookaheadCount = cur_.laCount;
                break;
        }
        return fontOk(r);
    }

    void popFront() scope
    in (!empty)
    {
        advance();
    }

    typeof(this) save() const return scope => this;

    private bool fail(FontErrorKind kind, ulong at) scope
    {
        failed_ = true;
        error_ = tableError(kind, tag_, start_, at);
        return false;
    }

    private bool fail(FontError e) scope
    {
        failed_ = true;
        error_ = e;
        return false;
    }

    /**
    Reads a count at `p` and checks the `width`-byte array after it, one
    element fewer when `dropsFirst` (an input whose first position is
    implied, where a count of 0 is `badValue`); moves `p` past the array.
    */
    private bool array(ref ulong p, out ushort count, out ulong arrayAt, uint width, bool dropsFirst = false) scope
    {
        if (!fits(data_.length, p, 2))
            return fail(FontErrorKind.truncated, p);
        count = be16(data_, cast(size_t) p);
        if (dropsFirst && count == 0)
            return fail(FontErrorKind.badValue, p);
        arrayAt = p + 2;
        const n = ulong(width) * (dropsFirst ? count - 1 : count);
        if (!fits(data_.length, arrayAt, n))
            return fail(FontErrorKind.truncated, arrayAt);
        p = arrayAt + n;
        return true;
    }

    /// Finds the next element: the next item, entry or subtable.
    private void advance() scope
    {
        while (true)
        {
            if (inEntry_)
            {
                if (item_ < itemCount_)
                {
                    produce(item_++);
                    return;
                }
                inEntry_ = false;
            }
            if (open_)
            {
                failed_ = false;
                if (openEntry())
                    continue;
                if (failed_)
                    return;
                open_ = false;
            }
            if (next_ >= subCount_)
            {
                empty_ = true;
                return;
            }
            failed_ = false;
            if (!openSubtable(next_++))
                return;
        }
    }

    /// Opens subtable `s`, unwrapping an extension; false with the error as the element.
    private bool openSubtable(uint s) scope
    {
        const d = data_;
        open_ = false;
        inEntry_ = false;
        sub_ = s;
        ext_ = false;
        entry_ = 0;
        const fieldAt = lookupAt_ + 6 + 2UL * s;
        const offset = be16(d, cast(size_t) fieldAt);
        ulong at = lookupAt_ + offset;
        if (offset == 0 || at >= d.length)
            return fail(FontErrorKind.badOffset, fieldAt);
        if (!fits(d.length, at, 2))
            return fail(FontErrorKind.truncated, at);
        ushort type = lookupType_;
        if (type == 7)
        {
            ext_ = true;
            if (be16(d, cast(size_t) at) != 1)
                return fail(FontErrorKind.unsupportedVersion, at);
            if (!fits(d.length, at, 8))
                return fail(FontErrorKind.truncated, at);
            type = be16(d, cast(size_t) at + 2);
            const extOffset = be32(d, cast(size_t) at + 4);
            if (type == 0 || type == 7 || type > 8)
                return fail(FontErrorKind.badValue, at + 2);
            if (extType_ == 0)
                extType_ = type;
            else if (type != extType_)
                return fail(FontErrorKind.badValue, at + 2);
            const target = at + extOffset;
            if (extOffset == 0 || target >= d.length)
                return fail(FontErrorKind.badOffset, at + 4);
            at = target;
            if (!fits(d.length, at, 2))
                return fail(FontErrorKind.truncated, at);
        }
        type_ = type;
        at_ = at;
        format_ = be16(d, cast(size_t) at);
        ulong p, ignoredAt;
        switch (type)
        {
            case 1:
                if (format_ == 1)
                {
                    if (!fits(d.length, at, 6))
                        return fail(FontErrorKind.truncated, at);
                    return openCoverage(at + 2);
                }
                if (format_ != 2)
                    break;
                p = at + 4;
                if (!fits(d.length, at, 4) || !array(p, count_, arrayAt_, 2))
                    return failed_ ? false : fail(FontErrorKind.truncated, at);
                return openCoverage(at + 2);
            case 2: .. case 4:
                if (format_ != 1)
                    break;
                p = at + 4;
                if (!fits(d.length, at, 4) || !array(p, count_, arrayAt_, 2))
                    return failed_ ? false : fail(FontErrorKind.truncated, at);
                return openCoverage(at + 2);
            case 5: .. case 6:
                if (format_ == 1)
                {
                    p = at + 4;
                    if (!fits(d.length, at, 4) || !array(p, count_, arrayAt_, 2))
                        return failed_ ? false : fail(FontErrorKind.truncated, at);
                    return openCoverage(at + 2);
                }
                if (format_ == 2)
                {
                    p = at + (type == 5 ? 6 : 10);
                    if (!array(p, count_, arrayAt_, 2))
                        return false;
                    mode_ = Mode.classes;
                    open_ = true;
                    return true;
                }
                if (format_ != 3)
                    break;
                if (type == 5)
                {
                    if (!fits(d.length, at, 6))
                        return fail(FontErrorKind.truncated, at);
                    inCount_ = be16(d, cast(size_t) at + 2);
                    seqCount_ = be16(d, cast(size_t) at + 4);
                    backCount_ = laCount_ = 0;
                    if (inCount_ == 0)
                        return fail(FontErrorKind.badValue, at + 2);
                    seqAt_ = at + 6 + 2UL * inCount_;
                    if (!fits(d.length, at + 6, 2UL * inCount_ + 4UL * seqCount_))
                        return fail(FontErrorKind.truncated, at + 6);
                }
                else
                {
                    p = at + 2;
                    if (!array(p, backCount_, ignoredAt, 2))
                        return false;
                    const inAt = p;
                    if (!array(p, inCount_, ignoredAt, 2))
                        return false;
                    if (inCount_ == 0)
                        return fail(FontErrorKind.badValue, inAt);
                    if (!array(p, laCount_, ignoredAt, 2) || !array(p, seqCount_, seqAt_, 4))
                        return false;
                }
                mode_ = Mode.single;
                open_ = true;
                return true;
            case 8:
                if (format_ != 1)
                    break;
                if (!fits(d.length, at, 4))
                    return fail(FontErrorKind.truncated, at);
                p = at + 4;
                if (!array(p, backCount_, ignoredAt, 2) || !array(p, laCount_, ignoredAt, 2)
                    || !array(p, count_, arrayAt_, 2))
                    return false;
                return openCoverage(at + 2);
            default:
                break;
        }
        return fail(FontErrorKind.unsupportedVersion, at);
    }

    /// Reads the Coverage whose offset field is at `fieldAt`, and starts walking it.
    private bool openCoverage(ulong fieldAt) scope
    {
        const offset = be16(data_, cast(size_t) fieldAt);
        if (offset == 0)
            return fail(FontErrorKind.badOffset, fieldAt);
        const c = Coverage.read(data_, tag_, start_, at_ + offset);
        if (c.broken)
            return fail(c.error);
        covAt_ = at_ + offset + 4;
        covFormat_ = c.format;
        covCount_ = c.count;
        covRecord_ = 0;
        settleCoverage();
        mode_ = Mode.coverage;
        open_ = true;
        return true;
    }

    /// Field `at` of coverage record `record`; `Coverage.read` checked the records fit.
    private ushort coverageField(size_t record, size_t at) const scope
        => be16(data_, cast(size_t)(covAt_ + (covFormat_ == 1 ? 2 : 6) * record + at));

    /// Moves to the first glyph of the current coverage record, skipping empty ranges.
    private void settleCoverage() scope
    {
        while (covRecord_ < covCount_)
        {
            covGlyph_ = coverageField(covRecord_, 0);
            if (covFormat_ == 1 || coverageField(covRecord_, 2) >= covGlyph_)
                return;
            ++covRecord_;
        }
    }

    /**
    Opens the next entry of the open subtable: true when there is one; false
    when none is left, or with `failed_` set when the entry is malformed.
    */
    private bool openEntry() scope
    {
        item_ = 0;
        itemCount_ = 1;
        final switch (mode_)
        {
            case Mode.single:
                if (entry_ >= 1)
                    return false;
                entry_ = 1;
                inEntry_ = true;
                return true;
            case Mode.classes:
                if (entry_ >= count_)
                    return false;
                glyph_ = cast(ushort) entry_;
                return openSet(arrayAt_ + 2UL * entry_++, true);
            case Mode.coverage:
                if (covRecord_ >= covCount_)
                    return false;
                glyph_ = cast(ushort) covGlyph_;
                coverageIndex_ = covFormat_ == 1 ? covRecord_
                    : coverageField(covRecord_, 4) + (covGlyph_ - coverageField(covRecord_, 0));
                if (covFormat_ == 2 && covGlyph_ < coverageField(covRecord_, 2))
                    ++covGlyph_;
                else
                {
                    ++covRecord_;
                    settleCoverage();
                }
                if (type_ == 1 && format_ == 1)
                {
                    inEntry_ = true;
                    return true;
                }
                // The array is format 2's substitutes, type 8's substitutes, or the sets.
                const countAt = type_ == 8 ? arrayAt_ - 2 : at_ + 4;
                if (coverageIndex_ >= count_)
                    return fail(FontErrorKind.badValue, countAt);
                if (type_ == 1 || type_ == 8)
                {
                    inEntry_ = true;
                    return true;
                }
                return openSet(arrayAt_ + 2UL * coverageIndex_, type_ >= 5);
        }
    }

    /**
    Opens the set whose offset, from the subtable, is at `fieldAt`: a
    Sequence (one item), or an AlternateSet, LigatureSet or rule set (one
    item per element). A null offset is a set of no rules when `nullIsEmpty`
    (contextual rule sets), else `badOffset`.
    */
    private bool openSet(ulong fieldAt, bool nullIsEmpty) scope
    {
        const d = data_;
        const offset = be16(d, cast(size_t) fieldAt);
        if (offset == 0 && nullIsEmpty)
        {
            itemCount_ = 0;
            inEntry_ = true;
            return true;
        }
        setAt_ = at_ + offset;
        if (offset == 0 || setAt_ >= d.length)
            return fail(FontErrorKind.badOffset, fieldAt);
        ulong p = setAt_;
        ushort count;
        ulong itemsAt;
        if (!array(p, count, itemsAt, 2))
            return false;
        itemCount_ = type_ == 2 ? 1 : count;
        inEntry_ = true;
        return true;
    }

    /// Makes item `j` of the open entry the current element, or its error.
    private void produce(uint j) scope
    {
        const d = data_;
        failed_ = false;
        Current c;
        switch (type_)
        {
            case 1:
                c.output = format_ == 1
                    ? cast(ushort)(glyph_ + bes16(d, cast(size_t) at_ + 4))
                    : be16(d, cast(size_t)(arrayAt_ + 2UL * coverageIndex_));
                break;
            case 2:
                c.outputAt = setAt_ + 2;
                c.outputRun = be16(d, cast(size_t) setAt_);
                break;
            case 3:
                c.outputAt = setAt_ + 2 + 2UL * j;
                c.outputRun = 1;
                c.alternate = j;
                break;
            case 4:
                if (!ligature(c, j))
                    return;
                break;
            case 5: .. case 6:
                if (format_ == 3)
                {
                    c.inputCount = inCount_;
                    c.backCount = backCount_;
                    c.laCount = laCount_;
                    c.seqAt = seqAt_;
                    c.seqCount = seqCount_;
                }
                else if (!rule(c, j))
                    return;
                break;
            default: // 8
                c.output = be16(d, cast(size_t)(arrayAt_ + 2UL * coverageIndex_));
                c.backCount = backCount_;
                c.laCount = laCount_;
                break;
        }
        cur_ = c;
    }

    /// The ligature `j` of the open LigatureSet into `c`; false with the error as the element.
    private bool ligature(ref Current c, uint j) scope
    {
        const d = data_;
        const fieldAt = setAt_ + 2 + 2UL * j;
        const offset = be16(d, cast(size_t) fieldAt);
        const at = setAt_ + offset;
        if (offset == 0 || at >= d.length)
            return fail(FontErrorKind.badOffset, fieldAt);
        if (!fits(d.length, at, 2))
            return fail(FontErrorKind.truncated, at);
        ulong p = at + 2;
        ushort count;
        if (!array(p, count, c.inputAt, 2, true))
            return false;
        c.inputRun = count - 1;
        c.output = be16(d, cast(size_t) at);
        return true;
    }

    /// The rule `j` of the open rule set into `c`; false with the error as the element.
    private bool rule(ref Current c, uint j) scope
    {
        const d = data_;
        const fieldAt = setAt_ + 2 + 2UL * j;
        const offset = be16(d, cast(size_t) fieldAt);
        const at = setAt_ + offset;
        if (offset == 0 || at >= d.length)
            return fail(FontErrorKind.badOffset, fieldAt);
        ushort inputCount, seqCount;
        if (type_ == 5)
        {
            if (!fits(d.length, at, 4))
                return fail(FontErrorKind.truncated, at);
            inputCount = be16(d, cast(size_t) at);
            seqCount = be16(d, cast(size_t) at + 2);
            if (inputCount == 0)
                return fail(FontErrorKind.badValue, at);
            c.inputAt = at + 4;
            c.seqAt = c.inputAt + 2UL * (inputCount - 1);
            if (!fits(d.length, c.inputAt, 2UL * (inputCount - 1) + 4UL * seqCount))
                return fail(FontErrorKind.truncated, c.inputAt);
        }
        else
        {
            ulong p = at;
            ushort backCount, laCount;
            if (!array(p, backCount, c.backAt, 2) || !array(p, inputCount, c.inputAt, 2, true)
                || !array(p, laCount, c.laAt, 2) || !array(p, seqCount, c.seqAt, 4))
                return false;
            c.backCount = backCount;
            c.laCount = laCount;
        }
        c.inputRun = inputCount - 1;
        c.inputCount = inputCount;
        c.seqCount = seqCount;
        return true;
    }
}

/**
The substitution records of `GSUB` lookup `lookupIndex` (FTI9), a lazy
forward range: the header's and `lookup`'s errors; `badValue` for a lookup
type outside 1–8. Each subtable, coverage entry and record is read when the
range reaches it, and an extension's subtable is unwrapped: an extension of
an extension, or one whose type differs from the lookup's first extension,
is that subtable's `badValue`. A coverage index past its subtable's array is
that entry's `badValue`; a record past the table is its `badOffset` or
`truncated`. A walk costs O(Σ over subtables of coverage count × record
length); a contextual rule's invoked lookups are listed, never followed.
*/
FontResult!Substitutions substitutions(return scope const Face face, uint lookupIndex)
{
    const l = layout(face, LayoutTable.gsub);
    if (l.hasError)
        return fontErr!Substitutions(l.error);
    const at = l.value.lookupAt(lookupIndex);
    if (at.hasError)
        return fontErr!Substitutions(at.error);
    const d = l.value.data_;
    Substitutions s;
    s.data_ = d;
    s.tag_ = l.value.tag_;
    s.start_ = l.value.start_;
    s.lookupCount_ = l.value.lookups_.count;
    s.lookupAt_ = at.value;
    s.lookupType_ = be16(d, cast(size_t) at.value);
    if (s.lookupType_ == 0 || s.lookupType_ > 8)
        return fontErr!Substitutions(l.value.error(FontErrorKind.badValue, at.value));
    s.subCount_ = be16(d, cast(size_t) at.value + 4);
    s.advance();
    return fontOk(s);
}
