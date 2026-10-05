/**
Borrowed, caller-bounded hyphenation machinery (WRAP-HYP1–2).

This module neither chooses a language nor supplies a dictionary. Resource owners
must supply a real licensed, reproducible corpus and approve its linguistic policy
before W5 resource acceptance; the mechanism alone does not establish that gate.
All successful views borrow immutable input and caller storage. Do not mutate or
release that storage while a view is in use. Failure changes only scratch and work
counters, never published views or their output arenas.
*/
module sparkles.base.text.hyphenation;

import sparkles.base.text.transform : UnicodeTransformView;
import sparkles.base.text.unicode_algorithm : UnicodeSourceSpan;
import sparkles.base.text.unicode_tables : unicodeVersion;
import sparkles.base.text.utf : isUnicodeScalar, utfStorageOverlaps, decodeToken,
    UtfMode, UtfStatus, UtfTokenKind;
import std.digest.sha : SHA256;

enum uint hyphenationFormatRevision = 1;
/// Not Unicode scalars: these symbols cannot collide with authored punctuation.
enum uint hyphenationWordStart = 0x110000;
enum uint hyphenationWordEnd = 0x110001;
enum ubyte hyphenationMaximumWeight = 9;

enum HyphenationStatus : ubyte
{
    ok, invalidInput, arithmeticExhausted, budgetExhausted, outputCapacity,
    scratchCapacity, unsupportedRevision, releaseMismatch, hashMismatch,
}

struct HyphenationResult
{
    HyphenationStatus status;
    size_t written;
    size_t required;
    bool succeeded() const @safe pure nothrow @nogc
        => status == HyphenationStatus.ok;
}

/// Grants are consumed, including on failure. No implicit unlimited grant.
struct HyphenationWork
{
    /// Lookup units (charged once up front) and validation exception-key scalars.
    size_t scalars;
    /// Trie probes, overlays, exception comparisons and provenance/boundary work.
    size_t transitions;
    /// Parser input bytes plus identity/fragment UTF-8 validation bytes.
    size_t bytes;
}

struct HyphenationIdentity
{
    uint formatRevision;
    const(char)[] language;
    const(char)[] policy;
    const(char)[] unicodeRelease;
    /// Lowercase hexadecimal SHA-256; parser verifies the external record payload.
    const(char)[] contentHash;
    const(char)[] sourceLicense;
    const(char)[] generatorRevision;
}

struct HyphenationNode
{
    size_t edgeStart;
    size_t edgeCount;
    size_t weightStart;
    /// Zero for non-pattern nodes, otherwise exactly path-symbol-count + one.
    size_t weightCount;
}

struct HyphenationEdge
{
    uint symbol;
    size_t child;
}

struct HyphenationFragments
{
    const(char)[] preBreak;
    const(char)[] postBreak;
    const(char)[] unbroken;
}

/// Positions are explicit boundaries in the exception's exact scalar key.
struct HyphenationExceptionBreak
{
    size_t position;
    size_t consumedStart;
    size_t consumedEnd;
    HyphenationFragments fragments;
}

struct HyphenationException
{
    size_t keyStart;
    size_t keyCount;
    size_t breakStart;
    /// Zero suppresses every pattern candidate for this key.
    size_t breakCount;
}

/// Unvalidated representation, usable by in-memory resource generators.
struct HyphenationTables
{
    HyphenationIdentity identity;
    const(HyphenationNode)[] nodes;
    const(HyphenationEdge)[] edges;
    const(ubyte)[] weights;
    const(dchar)[] exceptionKeys;
    const(HyphenationException)[] exceptions;
    const(HyphenationExceptionBreak)[] exceptionBreaks;
}

/// Only validation/parser publication creates a valid resource.
struct HyphenationResource
{
    private HyphenationTables borrowed;
    private bool validated;
    bool valid() scope const @safe pure nothrow @nogc => validated;
    // Returns borrowed slice values, not an address into this metadata header.
    HyphenationTables tables() return scope const @safe pure nothrow @nogc
        => borrowed;
}

/// DFS state doubles as parent ownership tracking. One element per trie node.
struct HyphenationVisit
{
    size_t parent;
    size_t depth;
    size_t nextEdge;
    ubyte color;
}

private HyphenationResult failure(HyphenationStatus status, size_t required = 0)
    @safe pure nothrow @nogc
{
    return HyphenationResult(status: status, required: required);
}

private bool rangeFits(size_t first, size_t count, size_t length)
    @safe pure nothrow @nogc
{
    return first <= length && count <= length - first;
}

private bool take(ref size_t grant, size_t count = 1) @safe pure nothrow @nogc
{
    if (count > grant) return false;
    grant -= count;
    return true;
}

private bool disjoint(A...)(scope A arenas) @safe pure nothrow @nogc
{
    static foreach (i; 0 .. A.length)
        static foreach (j; i + 1 .. A.length)
            if (utfStorageOverlaps(arenas[i], arenas[j])) return false;
    return true;
}

private bool identityOverlaps(T)(scope const HyphenationIdentity id, scope T[] arena)
    @safe pure nothrow @nogc
{
    return utfStorageOverlaps(id.language, arena)
        || utfStorageOverlaps(id.policy, arena)
        || utfStorageOverlaps(id.unicodeRelease, arena)
        || utfStorageOverlaps(id.contentHash, arena)
        || utfStorageOverlaps(id.sourceLicense, arena)
        || utfStorageOverlaps(id.generatorRevision, arena);
}

private bool fragmentsOverlap(T)(scope const HyphenationFragments fragments, scope T[] arena)
    @safe pure nothrow @nogc
{
    return utfStorageOverlaps(fragments.preBreak, arena)
        || utfStorageOverlaps(fragments.postBreak, arena)
        || utfStorageOverlaps(fragments.unbroken, arena);
}

private bool tablesOverlap(T)(scope const HyphenationTables tables, scope T[] arena)
    @safe pure nothrow @nogc
{
    if (identityOverlaps(tables.identity, arena)
        || utfStorageOverlaps(tables.nodes, arena)
        || utfStorageOverlaps(tables.edges, arena)
        || utfStorageOverlaps(tables.weights, arena)
        || utfStorageOverlaps(tables.exceptionKeys, arena)
        || utfStorageOverlaps(tables.exceptions, arena)
        || utfStorageOverlaps(tables.exceptionBreaks, arena)) return true;
    foreach (ref const entry; tables.exceptionBreaks)
        if (fragmentsOverlap(entry.fragments, arena)) return true;
    return false;
}

private bool validText(scope const(char)[] text) @safe pure nothrow @nogc
{
    size_t offset;
    while (offset < text.length)
    {
        const decoded = decodeToken(text[offset .. $], UtfMode.strict, true, offset);
        if (decoded.result.status != UtfStatus.ok) return false;
        offset += decoded.result.consumed;
    }
    return true;
}

private bool validFragments(scope const HyphenationFragments f) @safe pure nothrow @nogc
{
    return validText(f.preBreak) && validText(f.postBreak) && validText(f.unbroken);
}

private HyphenationResult checkIdentity(scope const HyphenationIdentity id)
    @safe pure nothrow @nogc
{
    if (id.formatRevision != hyphenationFormatRevision)
        return failure(HyphenationStatus.unsupportedRevision);
    if (id.unicodeRelease != unicodeVersion)
        return failure(HyphenationStatus.releaseMismatch);
    if (!id.language.length || !id.policy.length || !id.sourceLicense.length
        || !id.generatorRevision.length || !validText(id.language)
        || !validText(id.policy) || !validText(id.sourceLicense)
        || !validText(id.generatorRevision) || id.contentHash.length != 64)
        return failure(HyphenationStatus.invalidInput);
    foreach (c; id.contentHash)
        if (!(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'f'))
            return failure(HyphenationStatus.invalidInput);
    return HyphenationResult.init;
}

/**
Validate the entire borrowed trie and exceptions before publication. A trie is a
rooted tree, not a DAG: shared children, cycles and unreachable nodes are invalid.
Edges within each node are strictly symbol-sorted. Node numbering is unrestricted.
Start markers occur only at depth one; end markers have no children. Every weight
is in 0..9, including unused arena entries. Duplicate exception keys are rejected.
Exception key/break arenas are packed in exception-record order with no unowned
entries; trie edges likewise have exactly one owning node.
*/
void validateHyphenationResource(scope ref HyphenationResource published,
    return scope const HyphenationTables tables, scope HyphenationVisit[] scratch,
    ref HyphenationWork work, ref HyphenationResult result) @safe pure nothrow @nogc
{
    result = validateHyphenationTables(tables, scratch, work, published);
    if (result.succeeded()) published = HyphenationResource(borrowed: tables, validated: true);
}

private HyphenationResult validateHyphenationTables(Tables)(scope const Tables tables,
    scope HyphenationVisit[] scratch, ref HyphenationWork work,
    scope const HyphenationResource published) @safe pure nothrow @nogc
{
    scope const id = tables.identity;
    if (!take(work.bytes, id.language.length) || !take(work.bytes, id.policy.length)
        || !take(work.bytes, id.unicodeRelease.length) || !take(work.bytes, id.contentHash.length)
        || !take(work.bytes, id.sourceLicense.length) || !take(work.bytes, id.generatorRevision.length))
        return failure(HyphenationStatus.budgetExhausted);
    auto result = checkIdentity(tables.identity);
    if (!result.succeeded()) return result;
    if (!tables.nodes.length || tables.edges.length != tables.nodes.length - 1
        || tablesOverlap(tables, scratch)
        || (published.validated && tablesOverlap(published.borrowed, scratch)))
        return failure(HyphenationStatus.invalidInput);
    if (scratch.length < tables.nodes.length)
        return failure(HyphenationStatus.scratchCapacity, tables.nodes.length);
    if (!take(work.scalars, tables.exceptionKeys.length))
        return failure(HyphenationStatus.budgetExhausted);
    foreach (value; tables.exceptionKeys)
        if (!isUnicodeScalar(value)) return failure(HyphenationStatus.invalidInput);
    foreach (weight; tables.weights)
    {
        if (!take(work.transitions)) return failure(HyphenationStatus.budgetExhausted);
        if (weight > hyphenationMaximumWeight) return failure(HyphenationStatus.invalidInput);
    }
    foreach (ref const node; tables.nodes)
    {
        if (!take(work.transitions)) return failure(HyphenationStatus.budgetExhausted);
        if (!rangeFits(node.edgeStart, node.edgeCount, tables.edges.length)
            || !rangeFits(node.weightStart, node.weightCount, tables.weights.length))
            return failure(HyphenationStatus.invalidInput);
        uint previous;
        foreach (j; 0 .. node.edgeCount)
        {
            if (!take(work.transitions)) return failure(HyphenationStatus.budgetExhausted);
            const edge = tables.edges[node.edgeStart + j];
            if ((!isUnicodeScalar(cast(dchar) edge.symbol)
                    && edge.symbol != hyphenationWordStart && edge.symbol != hyphenationWordEnd)
                || edge.child >= tables.nodes.length || (j && edge.symbol <= previous))
                return failure(HyphenationStatus.invalidInput);
            previous = edge.symbol;
        }
    }
    scratch[0 .. tables.nodes.length] = HyphenationVisit.init;
    scratch[0].parent = size_t.max;
    scratch[0].color = 1;
    size_t current;
    size_t reached = 1;
    while (true)
    {
        auto ref visit = scratch[current];
        const node = tables.nodes[current];
        if (node.weightCount)
        {
            if (visit.depth == size_t.max) return failure(HyphenationStatus.arithmeticExhausted);
            if (node.weightCount != visit.depth + 1 || !visit.depth)
                return failure(HyphenationStatus.invalidInput);
        }
        if (visit.nextEdge == node.edgeCount)
        {
            visit.color = 2;
            if (!current) break;
            current = visit.parent;
            continue;
        }
        if (!take(work.transitions)) return failure(HyphenationStatus.budgetExhausted);
        const edge = tables.edges[node.edgeStart + visit.nextEdge++];
        if (scratch[edge.child].color || (!current && edge.child == 0)
            || (edge.symbol == hyphenationWordStart && visit.depth != 0)
            || (edge.symbol == hyphenationWordEnd && tables.nodes[edge.child].edgeCount))
            return failure(HyphenationStatus.invalidInput);
        if (visit.depth == size_t.max) return failure(HyphenationStatus.arithmeticExhausted);
        scratch[edge.child] = HyphenationVisit(parent: current,
            depth: visit.depth + 1, color: 1);
        ++reached;
        current = edge.child;
    }
    if (reached != tables.nodes.length) return failure(HyphenationStatus.invalidInput);
    size_t ownedKeys;
    size_t ownedBreaks;
    foreach (i, ref const exception; tables.exceptions)
    {
        if (!take(work.transitions)) return failure(HyphenationStatus.budgetExhausted);
        if (!exception.keyCount || exception.keyStart != ownedKeys || exception.breakStart != ownedBreaks
            || !rangeFits(exception.keyStart, exception.keyCount, tables.exceptionKeys.length)
            || !rangeFits(exception.breakStart, exception.breakCount, tables.exceptionBreaks.length))
            return failure(HyphenationStatus.invalidInput);
        ownedKeys += exception.keyCount;
        ownedBreaks += exception.breakCount;
        foreach (ref const earlier; tables.exceptions[0 .. i])
        {
            if (!take(work.transitions)) return failure(HyphenationStatus.budgetExhausted);
            if (earlier.keyCount != exception.keyCount) continue;
            bool equal = true;
            foreach (k; 0 .. exception.keyCount)
            {
                if (!take(work.transitions)) return failure(HyphenationStatus.budgetExhausted);
                if (tables.exceptionKeys[earlier.keyStart + k]
                    != tables.exceptionKeys[exception.keyStart + k]) { equal = false; break; }
            }
            if (equal) return failure(HyphenationStatus.invalidInput);
        }
        size_t previous;
        foreach (j; 0 .. exception.breakCount)
        {
            if (!take(work.transitions)) return failure(HyphenationStatus.budgetExhausted);
            scope const entry = tables.exceptionBreaks[exception.breakStart + j];
            if (!entry.position || entry.position >= exception.keyCount
                || entry.consumedStart > entry.position || entry.consumedEnd < entry.position
                || entry.consumedEnd > exception.keyCount
                || (j && entry.position <= previous))
                return failure(HyphenationStatus.invalidInput);
            scope const f = entry.fragments;
            if (!take(work.bytes, f.preBreak.length)
                || !take(work.bytes, f.postBreak.length) || !take(work.bytes, f.unbroken.length))
                return failure(HyphenationStatus.budgetExhausted);
            if (!validFragments(f)) return failure(HyphenationStatus.invalidInput);
            previous = entry.position;
        }
    }
    if (ownedKeys != tables.exceptionKeys.length || ownedBreaks != tables.exceptionBreaks.length)
        return failure(HyphenationStatus.invalidInput);
    return HyphenationResult.init;
}

/// Destination table arenas; every destination and staging arena must be disjoint.
struct HyphenationStorage
{
    HyphenationNode[] nodes;
    HyphenationEdge[] edges;
    ubyte[] weights;
    dchar[] exceptionKeys;
    HyphenationException[] exceptions;
    HyphenationExceptionBreak[] exceptionBreaks;
}

/// Numeric encoded spans never retain pointers into the parser's input.
struct HyphenationTextSpan
{
    size_t offset;
    size_t length;
}

private struct ParserLayout
{
    uint revision;
    HyphenationTextSpan[6] metadata;
    size_t[6] counts;
}

struct HyphenationBreakDraft
{
    size_t position;
    size_t consumedStart;
    size_t consumedEnd;
    HyphenationTextSpan[3] fragments;
}

/// Independent scratch arenas, mutable even when parsing fails.
struct HyphenationStaging
{
    HyphenationNode[] nodes;
    HyphenationEdge[] edges;
    ubyte[] weights;
    dchar[] exceptionKeys;
    HyphenationException[] exceptions;
    HyphenationBreakDraft[] exceptionBreaks;
}

private struct ResourceReader
{
    const(ubyte)[] bytes;
    size_t offset;
    bool failed;
    uint number() scope @safe pure nothrow @nogc
    {
        if (!rangeFits(offset, 4, bytes.length)) { failed = true; return 0; }
        const n = cast(uint) bytes[offset] | (cast(uint) bytes[offset + 1] << 8)
            | (cast(uint) bytes[offset + 2] << 16) | (cast(uint) bytes[offset + 3] << 24);
        offset += 4;
        return n;
    }
    HyphenationTextSpan text() scope @safe pure nothrow @nogc
    {
        const n = number();
        if (failed || !rangeFits(offset, n, bytes.length)) { failed = true; return HyphenationTextSpan.init; }
        const result = HyphenationTextSpan(offset: offset, length: n);
        offset += n;
        return result;
    }
}

private const(char)[] encodedText(return scope const(ubyte)[] encoded,
    HyphenationTextSpan span) @safe pure nothrow @nogc
    => cast(const(char)[]) encoded[span.offset .. span.offset + span.length];

private struct ParserBreakView
{
    const(ubyte)[] encoded;
    const(HyphenationBreakDraft)[] drafts;
    size_t length() scope const @safe pure nothrow @nogc => drafts.length;
    HyphenationExceptionBreak opIndex(size_t index) return scope const @safe pure nothrow @nogc
    {
        const draft = drafts[index];
        return HyphenationExceptionBreak(position: draft.position,
            consumedStart: draft.consumedStart, consumedEnd: draft.consumedEnd,
            fragments: HyphenationFragments(preBreak: encodedText(encoded, draft.fragments[0]),
                postBreak: encodedText(encoded, draft.fragments[1]),
                unbroken: encodedText(encoded, draft.fragments[2])));
    }
}

private struct ParserTables
{
    HyphenationIdentity identity;
    const(HyphenationNode)[] nodes;
    const(HyphenationEdge)[] edges;
    const(ubyte)[] weights;
    const(dchar)[] exceptionKeys;
    const(HyphenationException)[] exceptions;
    ParserBreakView exceptionBreaks;
}

private bool tablesOverlap(T)(scope const ParserTables tables, scope T[] arena)
    @safe pure nothrow @nogc
{
    return identityOverlaps(tables.identity, arena)
        || utfStorageOverlaps(tables.nodes, arena) || utfStorageOverlaps(tables.edges, arena)
        || utfStorageOverlaps(tables.weights, arena) || utfStorageOverlaps(tables.exceptionKeys, arena)
        || utfStorageOverlaps(tables.exceptions, arena)
        || utfStorageOverlaps(tables.exceptionBreaks.drafts, arena)
        || utfStorageOverlaps(tables.exceptionBreaks.encoded, arena);
}

/**
Bounded external format, separate from the validated in-memory representation:
ASCII HYP1; LE u32 format revision; six u32-byte-length UTF-8 strings (language,
policy, Unicode release, lowercase SHA-256, source license, generator revision);
six LE u32 counts (nodes, edges, weights, exception scalars, exceptions, breaks).
The SHA-256 covers all bytes AFTER these counts. Payload order: nodes (four u32
fields in declaration order), edges (symbol, child u32), raw u8 weights, u32 scalar
keys, exceptions (four u32 fields), breaks (position/consumedStart/consumedEnd u32,
then three length-prefixed UTF-8 fragments in pre/post/unbroken order). No padding,
trailing data, TeX syntax, implicit dictionary acquisition or host-endian fields.
All text and fragments borrow immutable encoded bytes; numeric tables borrow
destination storage. Staging can be released immediately after success and may
change on failure; destination and the published resource may not.
*/
void parseHyphenationResource(scope ref HyphenationResource published,
    return scope HyphenationStorage destination, return scope const(ubyte)[] encoded,
    scope HyphenationStaging staging, scope HyphenationVisit[] validationScratch,
    ref HyphenationWork work, ref HyphenationResult result) @safe pure nothrow @nogc
{
    ParserLayout layout;
    result = stageHyphenationResource(encoded, destination, staging, validationScratch,
        work, published, layout);
    if (!result.succeeded()) return;
    // Validation is complete: no failure or work charge occurs after this point.
    const nodes = layout.counts[0];
    const edges = layout.counts[1];
    const weights = layout.counts[2];
    const keys = layout.counts[3];
    const exceptions = layout.counts[4];
    const breaks = layout.counts[5];
    destination.nodes[0 .. nodes] = staging.nodes[0 .. nodes];
    destination.edges[0 .. edges] = staging.edges[0 .. edges];
    destination.weights[0 .. weights] = staging.weights[0 .. weights];
    destination.exceptionKeys[0 .. keys] = staging.exceptionKeys[0 .. keys];
    destination.exceptions[0 .. exceptions] = staging.exceptions[0 .. exceptions];
    foreach (i; 0 .. breaks)
    {
        const draft = staging.exceptionBreaks[i];
        // The publication signature bounds the encoded/destination borrows.
        // Staging checked every index before this infallible leaf-field store;
        // D cannot express the first-ref loan through an array element.
        (() @trusted
        {
            destination.exceptionBreaks[i] = HyphenationExceptionBreak(position: draft.position,
                consumedStart: draft.consumedStart, consumedEnd: draft.consumedEnd,
                fragments: HyphenationFragments(preBreak: encodedText(encoded, draft.fragments[0]),
                    postBreak: encodedText(encoded, draft.fragments[1]),
                    unbroken: encodedText(encoded, draft.fragments[2])));
        })();
    }
    scope const identity = HyphenationIdentity(formatRevision: layout.revision,
        language: encodedText(encoded, layout.metadata[0]), policy: encodedText(encoded, layout.metadata[1]),
        unicodeRelease: encodedText(encoded, layout.metadata[2]), contentHash: encodedText(encoded, layout.metadata[3]),
        sourceLicense: encodedText(encoded, layout.metadata[4]), generatorRevision: encodedText(encoded, layout.metadata[5]));
    scope const tables = HyphenationTables(identity: identity, nodes: destination.nodes[0 .. nodes],
        edges: destination.edges[0 .. edges], weights: destination.weights[0 .. weights],
        exceptionKeys: destination.exceptionKeys[0 .. keys], exceptions: destination.exceptions[0 .. exceptions],
        exceptionBreaks: destination.exceptionBreaks[0 .. breaks]);
    // Only validated metadata is committed; both pointer owners are explicitly
    // return-scope inputs constrained to the first publication reference.
    (() @trusted { published = HyphenationResource(borrowed: tables, validated: true); })();
}

private HyphenationResult stageHyphenationResource(scope const(ubyte)[] encoded,
    scope HyphenationStorage destination, scope HyphenationStaging staging,
    scope HyphenationVisit[] validationScratch, ref HyphenationWork work,
    scope const HyphenationResource published, scope ref ParserLayout layout) @safe pure nothrow @nogc
{
    if (!disjoint(encoded, destination.nodes, destination.edges, destination.weights,
            destination.exceptionKeys, destination.exceptions, destination.exceptionBreaks,
            staging.nodes, staging.edges, staging.weights, staging.exceptionKeys,
            staging.exceptions, staging.exceptionBreaks, validationScratch))
        return failure(HyphenationStatus.invalidInput);
    if (published.validated)
    {
        if (tablesOverlap(published.borrowed, staging.nodes)
            || tablesOverlap(published.borrowed, staging.edges)
            || tablesOverlap(published.borrowed, staging.weights)
            || tablesOverlap(published.borrowed, staging.exceptionKeys)
            || tablesOverlap(published.borrowed, staging.exceptions)
            || tablesOverlap(published.borrowed, staging.exceptionBreaks)
            || tablesOverlap(published.borrowed, validationScratch))
            return failure(HyphenationStatus.invalidInput);
    }
    if (!take(work.bytes, encoded.length)) return failure(HyphenationStatus.budgetExhausted);
    if (encoded.length < 4 || encoded[0 .. 4] != cast(const(ubyte)[]) "HYP1")
        return failure(HyphenationStatus.invalidInput);
    scope auto reader = ResourceReader(bytes: encoded, offset: 4);
    layout.revision = reader.number();
    foreach (ref span; layout.metadata) span = reader.text();
    if (reader.failed) return failure(HyphenationStatus.invalidInput);
    scope const identity = HyphenationIdentity(formatRevision: layout.revision,
        language: encodedText(encoded, layout.metadata[0]), policy: encodedText(encoded, layout.metadata[1]),
        unicodeRelease: encodedText(encoded, layout.metadata[2]), contentHash: encodedText(encoded, layout.metadata[3]),
        sourceLicense: encodedText(encoded, layout.metadata[4]), generatorRevision: encodedText(encoded, layout.metadata[5]));
    auto result = checkIdentity(identity);
    if (!result.succeeded()) return result;
    const nodeCount = reader.number();
    const edgeCount = reader.number();
    const weightCount = reader.number();
    const keyCount = reader.number();
    const exceptionCount = reader.number();
    const breakCount = reader.number();
    if (reader.failed) return failure(HyphenationStatus.invalidInput);
    // Reject impossible counts before iteration, even with generously sized arenas.
    size_t minimumPayload;
    layout.counts = [nodeCount, edgeCount, weightCount, keyCount, exceptionCount, breakCount];
    enum size_t[6] recordSizes = [16, 8, 1, 4, 16, 24];
    foreach (i, count; layout.counts)
    {
        if (count > (size_t.max - minimumPayload) / recordSizes[i])
            return failure(HyphenationStatus.arithmeticExhausted);
        minimumPayload += count * recordSizes[i];
    }
    if (minimumPayload > encoded.length - reader.offset)
        return failure(HyphenationStatus.invalidInput);
    if (nodeCount > destination.nodes.length || edgeCount > destination.edges.length
        || weightCount > destination.weights.length || keyCount > destination.exceptionKeys.length
        || exceptionCount > destination.exceptions.length || breakCount > destination.exceptionBreaks.length)
        return failure(HyphenationStatus.outputCapacity);
    if (nodeCount > staging.nodes.length || edgeCount > staging.edges.length
        || weightCount > staging.weights.length || keyCount > staging.exceptionKeys.length
        || exceptionCount > staging.exceptions.length || breakCount > staging.exceptionBreaks.length
        || nodeCount > validationScratch.length)
        return failure(HyphenationStatus.scratchCapacity);
    SHA256 hash;
    hash.put(encoded[reader.offset .. $]);
    const digest = hash.finish();
    enum hex = "0123456789abcdef";
    foreach (i, value; digest)
        if (identity.contentHash[i * 2] != hex[value >> 4]
            || identity.contentHash[i * 2 + 1] != hex[value & 15])
            return failure(HyphenationStatus.hashMismatch);
    foreach (i; 0 .. nodeCount)
        staging.nodes[i] = HyphenationNode(edgeStart: reader.number(),
            edgeCount: reader.number(), weightStart: reader.number(), weightCount: reader.number());
    foreach (i; 0 .. edgeCount)
        staging.edges[i] = HyphenationEdge(symbol: reader.number(), child: reader.number());
    if (reader.failed || !rangeFits(reader.offset, weightCount, encoded.length))
        return failure(HyphenationStatus.invalidInput);
    staging.weights[0 .. weightCount] = encoded[reader.offset .. reader.offset + weightCount];
    reader.offset += weightCount;
    foreach (i; 0 .. keyCount) staging.exceptionKeys[i] = cast(dchar) reader.number();
    foreach (i; 0 .. exceptionCount)
        staging.exceptions[i] = HyphenationException(keyStart: reader.number(),
            keyCount: reader.number(), breakStart: reader.number(), breakCount: reader.number());
    foreach (i; 0 .. breakCount)
    {
        HyphenationBreakDraft entry;
        entry.position = reader.number();
        entry.consumedStart = reader.number();
        entry.consumedEnd = reader.number();
        foreach (ref span; entry.fragments) span = reader.text();
        staging.exceptionBreaks[i] = entry;
    }
    if (reader.failed || reader.offset != encoded.length) return failure(HyphenationStatus.invalidInput);
    scope const tables = ParserTables(identity: identity, nodes: staging.nodes[0 .. nodeCount],
        edges: staging.edges[0 .. edgeCount], weights: staging.weights[0 .. weightCount],
        exceptionKeys: staging.exceptionKeys[0 .. keyCount], exceptions: staging.exceptions[0 .. exceptionCount],
        exceptionBreaks: ParserBreakView(encoded: encoded, drafts: staging.exceptionBreaks[0 .. breakCount]));
    return validateHyphenationTables(tables, validationScratch, work, published);
}

enum HyphenationExceptionPolicy : ubyte { replacePatterns, ignoreExceptions }

/**
Exactly one key form: a published normalized/cased transform view, OR an unaltered
scalar key and one source span per scalar. In the latter form every scalar is
verified against the original UTF-8 source span, not merely assumed unchanged.
Allowed boundaries are explicit whole-source GCB offsets, strictly ascending and
including word.start and word.end. Caller owns their Unicode grapheme derivation.
No locale, case mapping or normalization is performed here.
*/
struct HyphenationLookup
{
    const(char)[] source;
    UnicodeSourceSpan word;
    UnicodeTransformView transformed;
    const(dchar)[] unalteredKey;
    const(UnicodeSourceSpan)[] unalteredSourceMap;
    const(size_t)[] allowedSourceBoundaries;
}

struct HyphenationOptions
{
    /// Minima count SOURCE graphemes, never expanded lookup scalars or bytes.
    size_t leftMinimum;
    size_t rightMinimum;
    HyphenationExceptionPolicy exceptions;
    /// Pattern breaks consume an empty source range at their explicit anchor.
    HyphenationFragments patternFragments;
}

struct HyphenationCandidate
{
    size_t lookupPosition;
    size_t sourceAnchor;
    UnicodeSourceSpan consumedSource;
    size_t preAnchor;
    size_t postAnchor;
    size_t unbrokenAnchor;
    HyphenationFragments fragments;
    bool fromException;
}
/// Numeric staging only; no borrowed fragment pointers survive in scratch.
struct HyphenationCandidateDraft
{
    size_t lookupPosition;
    size_t sourceAnchor;
    UnicodeSourceSpan consumedSource;
    /// Absolute resource break index; size_t.max selects patternFragments.
    size_t exceptionBreakIndex;
}


struct HyphenationMatchScratch
{
    /// key length + 3, including interleaved slots around the two markers.
    ubyte[] weights;
    /// key length + 1; ambiguous boundaries contain size_t.max internally.
    size_t[] sourceBoundaries;
    HyphenationCandidateDraft[] candidates;
}

struct HyphenationOutput
{
    HyphenationCandidate[] storage;
    const(HyphenationCandidate)[] candidates;
}

private size_t keyLength(scope const HyphenationLookup lookup) @safe pure nothrow @nogc
{
    return lookup.transformed.valid() ? lookup.transformed.units.length : lookup.unalteredKey.length;
}

private dchar keyScalar(scope const HyphenationLookup lookup, size_t index) @safe pure nothrow @nogc
{
    return lookup.transformed.valid() ? lookup.transformed.units[index].value : lookup.unalteredKey[index];
}

private bool lookupOverlaps(T)(scope const HyphenationLookup lookup, scope T[] arena)
    @safe pure nothrow @nogc
{
    return utfStorageOverlaps(lookup.source, arena)
        || utfStorageOverlaps(lookup.unalteredKey, arena)
        || utfStorageOverlaps(lookup.unalteredSourceMap, arena)
        || utfStorageOverlaps(lookup.allowedSourceBoundaries, arena)
        || utfStorageOverlaps(lookup.transformed.units, arena)
        || utfStorageOverlaps(lookup.transformed.spans, arena)
        || utfStorageOverlaps(lookup.transformed.deletions, arena)
        || utfStorageOverlaps(lookup.transformed.storageEpoch(), arena);
}

private HyphenationResult mapBoundaries(scope const HyphenationLookup lookup,
    scope size_t[] boundaries, ref HyphenationWork work) @safe pure nothrow @nogc
{
    const transformed = lookup.transformed.valid();
    const n = keyLength(lookup);
    if (lookup.word.start > lookup.word.end || lookup.word.end > lookup.source.length
        || !lookup.allowedSourceBoundaries.length
        || (n && lookup.allowedSourceBoundaries.length < 2)
        || (!n && lookup.word.start != lookup.word.end)
        || lookup.allowedSourceBoundaries[0] != lookup.word.start
        || lookup.allowedSourceBoundaries[$ - 1] != lookup.word.end
        || (transformed && (lookup.unalteredKey.length || lookup.unalteredSourceMap.length))
        || (!transformed && (lookup.transformed.units.length || lookup.transformed.spans.length
            || lookup.transformed.deletions.length || lookup.transformed.storageEpoch().length
            || lookup.unalteredSourceMap.length != n)))
        return failure(HyphenationStatus.invalidInput);
    foreach (i; 1 .. lookup.allowedSourceBoundaries.length)
    {
        if (!take(work.transitions)) return failure(HyphenationStatus.budgetExhausted);
        if (lookup.allowedSourceBoundaries[i] <= lookup.allowedSourceBoundaries[i - 1])
            return failure(HyphenationStatus.invalidInput);
    }
    if (!take(work.scalars, n)) return failure(HyphenationStatus.budgetExhausted);
    boundaries[0] = lookup.word.start;
    size_t maximumEnd = lookup.word.start;
    foreach (i; 0 .. n)
    {
        const scalar = keyScalar(lookup, i);
        if (!isUnicodeScalar(scalar)) return failure(HyphenationStatus.invalidInput);
        scope const(UnicodeSourceSpan)[] spans;
        if (transformed)
        {
            const unit = lookup.transformed.units[i];
            if ((unit.kind != UtfTokenKind.scalar && unit.kind != UtfTokenKind.replacement)
                || !unit.provenanceCount
                || !rangeFits(unit.provenanceStart, unit.provenanceCount, lookup.transformed.spans.length))
                return failure(HyphenationStatus.invalidInput);
            spans = lookup.transformed.spans[unit.provenanceStart .. unit.provenanceStart + unit.provenanceCount];
        }
        else
        {
            spans = lookup.unalteredSourceMap[i .. i + 1];
            const span = spans[0];
            if (span.start >= span.end || span.end > lookup.source.length)
                return failure(HyphenationStatus.invalidInput);
            const decoded = decodeToken(lookup.source[span.start .. span.end], UtfMode.strict, true, span.start);
            if (decoded.result.status != UtfStatus.ok || decoded.token.scalar != scalar
                || decoded.result.consumed != span.end - span.start
                || (i ? span.start != lookup.unalteredSourceMap[i - 1].end : span.start != lookup.word.start)
                || (i == n - 1 && span.end != lookup.word.end))
                return failure(HyphenationStatus.invalidInput);
        }
        foreach (j, span; spans)
        {
            if (!take(work.transitions)) return failure(HyphenationStatus.budgetExhausted);
            if (span.start >= span.end || span.start < lookup.word.start || span.end > lookup.word.end
                || (j && (span.start < spans[j - 1].start
                    || (span.start == spans[j - 1].start && span.end <= spans[j - 1].end))))
                return failure(HyphenationStatus.invalidInput);
            if (span.end > maximumEnd) maximumEnd = span.end;
        }
        boundaries[i + 1] = maximumEnd;
    }
    size_t minimumStart = lookup.word.end;
    foreach_reverse (i; 0 .. n)
    {
        scope const(UnicodeSourceSpan)[] spans;
        if (transformed)
        {
            const unit = lookup.transformed.units[i];
            spans = lookup.transformed.spans[unit.provenanceStart .. unit.provenanceStart + unit.provenanceCount];
        }
        else spans = lookup.unalteredSourceMap[i .. i + 1];
        foreach (span; spans)
        {
            if (!take(work.transitions)) return failure(HyphenationStatus.budgetExhausted);
            if (span.start < minimumStart) minimumStart = span.start;
        }
        if (boundaries[i] != minimumStart) boundaries[i] = size_t.max;
    }
    if (maximumEnd != lookup.word.end) boundaries[n] = size_t.max;
    foreach (deletion; lookup.transformed.deletions)
    {
        if (deletion.boundary > n || deletion.source.start >= deletion.source.end
            || deletion.source.start < lookup.word.start || deletion.source.end > lookup.word.end)
            return failure(HyphenationStatus.invalidInput);
        boundaries[deletion.boundary] = size_t.max;
        foreach (ref boundary; boundaries[0 .. n + 1])
        {
            if (!take(work.transitions)) return failure(HyphenationStatus.budgetExhausted);
            if (boundary != size_t.max && deletion.source.start < boundary
                && boundary < deletion.source.end) boundary = size_t.max;
        }
    }
    return HyphenationResult.init;
}

private bool allowed(scope const HyphenationLookup lookup, size_t boundary,
    ref size_t rank, ref HyphenationWork work) @safe pure nothrow @nogc
{
    // Lower bound avoids a scan per candidate; comparisons consume work too.
    size_t first;
    size_t last = lookup.allowedSourceBoundaries.length;
    while (first < last)
    {
        if (!take(work.transitions)) { rank = size_t.max; return false; }
        const mid = first + (last - first) / 2;
        if (lookup.allowedSourceBoundaries[mid] < boundary) first = mid + 1;
        else last = mid;
    }
    rank = first;
    return first < lookup.allowedSourceBoundaries.length
        && lookup.allowedSourceBoundaries[first] == boundary;
}

private HyphenationResult appendCandidate(scope const HyphenationLookup lookup,
    scope const HyphenationOptions options, scope const(size_t)[] boundaries, size_t position,
    size_t consumedStart, size_t consumedEnd, size_t exceptionBreakIndex,
    scope HyphenationCandidateDraft[] candidates, ref size_t count,
    ref HyphenationWork work) @safe pure nothrow @nogc
{
    const anchor = boundaries[position];
    const start = boundaries[consumedStart];
    const end = boundaries[consumedEnd];
    if (anchor == size_t.max || start == size_t.max || end == size_t.max
        || start > anchor || anchor > end) return HyphenationResult.init;
    size_t rank;
    if (!allowed(lookup, anchor, rank, work))
        return rank == size_t.max ? failure(HyphenationStatus.budgetExhausted) : HyphenationResult.init;
    if (rank < options.leftMinimum
        || lookup.allowedSourceBoundaries.length - 1 - rank < options.rightMinimum)
        return HyphenationResult.init;
    if (!allowed(lookup, start, rank, work) || !allowed(lookup, end, rank, work))
        return rank == size_t.max ? failure(HyphenationStatus.budgetExhausted) : HyphenationResult.init;
    if (count == candidates.length) return failure(HyphenationStatus.scratchCapacity, count + 1);
    candidates[count++] = HyphenationCandidateDraft(lookupPosition: position, sourceAnchor: anchor,
        consumedSource: UnicodeSourceSpan(start: start, end: end),
        exceptionBreakIndex: exceptionBreakIndex);
    return HyphenationResult.init;
}

/**
Overlay every matched pattern by maximum interleaved weight; only odd INTERNAL
key slots are candidates. An exact-key exception, when enabled, replaces rather
than merges those results, including a zero-break suppressing exception. All
candidate anchors come from provenance, never emitted lengths. Work exhaustion is
a failure even if the candidate prefix is empty. Published candidates and storage
are unchanged on EVERY failure. Scratch contains only numeric drafts and may be
released after the call; output fragments borrow resource/options storage, which
must remain immutable and alive while the output is used.
*/
void matchHyphenation(scope ref HyphenationOutput output,
    return scope const HyphenationResource resource, scope const HyphenationLookup lookup,
    return scope const HyphenationOptions options, scope HyphenationMatchScratch scratch,
    ref HyphenationWork work, ref HyphenationResult result) @safe pure nothrow @nogc
{
    result = stageHyphenation(resource, lookup, options, scratch, work, output);
    if (!result.succeeded()) return;
    foreach (i; 0 .. result.written)
    {
        const draft = scratch.candidates[i];
        // Resource/options loans are checked at the public first-ref boundary.
        // This infallible element commit only installs already validated spans.
        (() @trusted
        {
            output.storage[i] = HyphenationCandidate(lookupPosition: draft.lookupPosition,
                sourceAnchor: draft.sourceAnchor, consumedSource: draft.consumedSource,
                preAnchor: draft.consumedSource.start, postAnchor: draft.consumedSource.end,
                unbrokenAnchor: draft.consumedSource.start,
                fragments: draft.exceptionBreakIndex == size_t.max ? options.patternFragments
                    : resource.borrowed.exceptionBreaks[draft.exceptionBreakIndex].fragments,
                fromException: draft.exceptionBreakIndex != size_t.max);
        })();
    }
    output.candidates = output.storage[0 .. result.written];
}

private HyphenationResult stageHyphenation(scope const HyphenationResource resource,
    scope const HyphenationLookup lookup, scope const HyphenationOptions options,
    scope HyphenationMatchScratch scratch, ref HyphenationWork work,
    scope const HyphenationOutput output) @safe pure nothrow @nogc
{
    if (!resource.validated
        || (options.exceptions != HyphenationExceptionPolicy.replacePatterns
            && options.exceptions != HyphenationExceptionPolicy.ignoreExceptions))
        return failure(HyphenationStatus.invalidInput);
    if (!disjoint(scratch.weights, scratch.sourceBoundaries, scratch.candidates, output.storage)
        || utfStorageOverlaps(output.candidates, scratch.weights)
        || utfStorageOverlaps(output.candidates, scratch.sourceBoundaries)
        || utfStorageOverlaps(output.candidates, scratch.candidates))
        return failure(HyphenationStatus.invalidInput);
    foreach (ref const previous; output.candidates)
        if (fragmentsOverlap(previous.fragments, scratch.weights)
            || fragmentsOverlap(previous.fragments, scratch.sourceBoundaries)
            || fragmentsOverlap(previous.fragments, scratch.candidates))
            return failure(HyphenationStatus.invalidInput);
    if (tablesOverlap(resource.borrowed, scratch.weights)
        || tablesOverlap(resource.borrowed, scratch.sourceBoundaries)
        || tablesOverlap(resource.borrowed, scratch.candidates)
        || tablesOverlap(resource.borrowed, output.storage)
        || lookupOverlaps(lookup, scratch.weights) || lookupOverlaps(lookup, scratch.sourceBoundaries)
        || lookupOverlaps(lookup, scratch.candidates) || lookupOverlaps(lookup, output.storage)
        || fragmentsOverlap(options.patternFragments, scratch.weights)
        || fragmentsOverlap(options.patternFragments, scratch.sourceBoundaries)
        || fragmentsOverlap(options.patternFragments, scratch.candidates)
        || fragmentsOverlap(options.patternFragments, output.storage))
        return failure(HyphenationStatus.invalidInput);
    const n = keyLength(lookup);
    if (n > size_t.max - 3) return failure(HyphenationStatus.arithmeticExhausted);
    if (scratch.weights.length < n + 3 || scratch.sourceBoundaries.length < n + 1)
        return failure(HyphenationStatus.scratchCapacity, n + 3);
    scope const fragments = options.patternFragments;
    if (!take(work.bytes, fragments.preBreak.length) || !take(work.bytes, fragments.postBreak.length)
        || !take(work.bytes, fragments.unbroken.length)) return failure(HyphenationStatus.budgetExhausted);
    if (!validFragments(fragments)) return failure(HyphenationStatus.invalidInput);
    auto result = mapBoundaries(lookup, scratch.sourceBoundaries, work);
    if (!result.succeeded()) return result;
    size_t count;
    bool foundException;
    if (options.exceptions == HyphenationExceptionPolicy.replacePatterns)
    {
        foreach (ref const exception; resource.borrowed.exceptions)
        {
            if (!take(work.transitions)) return failure(HyphenationStatus.budgetExhausted);
            if (exception.keyCount != n) continue;
            bool equal = true;
            foreach (i; 0 .. n)
            {
                if (!take(work.transitions)) return failure(HyphenationStatus.budgetExhausted);
                if (resource.borrowed.exceptionKeys[exception.keyStart + i] != keyScalar(lookup, i))
                { equal = false; break; }
            }
            if (!equal) continue;
            foundException = true;
            foreach (i; 0 .. exception.breakCount)
            {
                const index = exception.breakStart + i;
                scope const entry = resource.borrowed.exceptionBreaks[index];
                result = appendCandidate(lookup, options, scratch.sourceBoundaries, entry.position,
                    entry.consumedStart, entry.consumedEnd, index,
                    scratch.candidates, count, work);
                if (!result.succeeded()) return result;
            }
            break;
        }
    }
    if (!foundException)
    {
        scratch.weights[0 .. n + 3] = 0;
        foreach (start; 0 .. n + 2)
        {
            size_t nodeIndex;
            foreach (position; start .. n + 2)
            {
                const symbol = position == 0 ? hyphenationWordStart
                    : (position == n + 1 ? hyphenationWordEnd : cast(uint) keyScalar(lookup, position - 1));
                const node = resource.borrowed.nodes[nodeIndex];
                size_t first;
                size_t last = node.edgeCount;
                while (first < last)
                {
                    if (!take(work.transitions)) return failure(HyphenationStatus.budgetExhausted);
                    const mid = first + (last - first) / 2;
                    if (resource.borrowed.edges[node.edgeStart + mid].symbol < symbol) first = mid + 1;
                    else last = mid;
                }
                if (!take(work.transitions)) return failure(HyphenationStatus.budgetExhausted);
                if (first == node.edgeCount || resource.borrowed.edges[node.edgeStart + first].symbol != symbol)
                    break;
                nodeIndex = resource.borrowed.edges[node.edgeStart + first].child;
                const matched = resource.borrowed.nodes[nodeIndex];
                foreach (j; 0 .. matched.weightCount)
                {
                    if (!take(work.transitions)) return failure(HyphenationStatus.budgetExhausted);
                    const weight = resource.borrowed.weights[matched.weightStart + j];
                    if (weight > scratch.weights[start + j]) scratch.weights[start + j] = weight;
                }
            }
        }
        foreach (position; 1 .. n)
        {
            if (!(scratch.weights[position + 1] & 1)) continue;
            result = appendCandidate(lookup, options, scratch.sourceBoundaries, position, position,
                position, size_t.max, scratch.candidates, count, work);
            if (!result.succeeded()) return result;
        }
    }
    if (count > output.storage.length) return failure(HyphenationStatus.outputCapacity, count);
    return HyphenationResult(written: count);
}

version (unittest)
{
    private HyphenationIdentity testIdentity() @safe pure nothrow @nogc
    {
        return HyphenationIdentity(formatRevision: hyphenationFormatRevision,
            language: "synthetic", policy: "mechanism-vector", unicodeRelease: unicodeVersion,
            contentHash: "0000000000000000000000000000000000000000000000000000000000000000",
            sourceLicense: "CC0-1.0", generatorRevision: "test-vector-1");
    }

    private HyphenationWork testWork() @safe pure nothrow @nogc
        => HyphenationWork(scalars: 10_000, transitions: 100_000, bytes: 100_000);

    private struct PatternFixture
    {
        HyphenationNode[6] nodes;
        HyphenationEdge[5] edges;
        ubyte[10] weights;

        void initialize() @safe pure nothrow @nogc
        {
            // ab: odd slots 1,2; abc: slot 2 gets 3; bc: slot 2 gets 4.
            nodes = [
                HyphenationNode(edgeStart: 0, edgeCount: 2),
                HyphenationNode(edgeStart: 2, edgeCount: 1),
                HyphenationNode(edgeStart: 3, edgeCount: 1, weightStart: 0, weightCount: 3),
                HyphenationNode(weightStart: 3, weightCount: 4),
                HyphenationNode(edgeStart: 4, edgeCount: 1),
                HyphenationNode(weightStart: 7, weightCount: 3),
            ];
            edges = [
                HyphenationEdge(symbol: 'a', child: 1), HyphenationEdge(symbol: 'b', child: 4),
                HyphenationEdge(symbol: 'b', child: 2), HyphenationEdge(symbol: 'c', child: 3),
                HyphenationEdge(symbol: 'c', child: 5),
            ];
            weights = [0, 1, 1, 0, 0, 3, 0, 0, 4, 0];
        }

        HyphenationTables tables() scope return @safe pure nothrow @nogc
        {
            return HyphenationTables(identity: testIdentity(), nodes: nodes[],
                edges: edges[], weights: weights[]);
        }
    }

    private struct TestEncoder
    {
        ubyte[] storage;
        size_t length;
        size_t hashOffset;
        size_t payloadOffset;

        void number(uint value) scope @safe pure nothrow @nogc
        {
            assert(storage.length - length >= 4);
            foreach (shift; 0 .. 4)
                storage[length++] = cast(ubyte) (value >> (shift * 8));
        }

        void text(scope const(char)[] value) scope @safe pure nothrow @nogc
        {
            assert(value.length <= uint.max && storage.length - length >= value.length + 4);
            number(cast(uint) value.length);
            storage[length .. length + value.length] = cast(const(ubyte)[]) value;
            length += value.length;
        }

        void encode(scope const HyphenationTables tables) scope @safe pure nothrow @nogc
        {
            storage[0 .. 4] = cast(const(ubyte)[]) "HYP1";
            length = 4;
            number(tables.identity.formatRevision);
            text(tables.identity.language);
            text(tables.identity.policy);
            text(tables.identity.unicodeRelease);
            hashOffset = length + 4;
            text(tables.identity.contentHash);
            text(tables.identity.sourceLicense);
            text(tables.identity.generatorRevision);
            number(cast(uint) tables.nodes.length);
            number(cast(uint) tables.edges.length);
            number(cast(uint) tables.weights.length);
            number(cast(uint) tables.exceptionKeys.length);
            number(cast(uint) tables.exceptions.length);
            number(cast(uint) tables.exceptionBreaks.length);
            payloadOffset = length;
            foreach (node; tables.nodes)
            {
                number(cast(uint) node.edgeStart);
                number(cast(uint) node.edgeCount);
                number(cast(uint) node.weightStart);
                number(cast(uint) node.weightCount);
            }
            foreach (edge; tables.edges) { number(edge.symbol); number(cast(uint) edge.child); }
            storage[length .. length + tables.weights.length] = tables.weights[];
            length += tables.weights.length;
            foreach (key; tables.exceptionKeys) number(cast(uint) key);
            foreach (entry; tables.exceptions)
            {
                number(cast(uint) entry.keyStart); number(cast(uint) entry.keyCount);
                number(cast(uint) entry.breakStart); number(cast(uint) entry.breakCount);
            }
            foreach (entry; tables.exceptionBreaks)
            {
                number(cast(uint) entry.position); number(cast(uint) entry.consumedStart);
                number(cast(uint) entry.consumedEnd);
                text(entry.fragments.preBreak); text(entry.fragments.postBreak);
                text(entry.fragments.unbroken);
            }
            rehash();
        }

        void rehash() scope @safe pure nothrow @nogc
        {
            SHA256 hash;
            hash.put(storage[payloadOffset .. length]);
            const digest = hash.finish();
            enum hex = "0123456789abcdef";
            foreach (i, value; digest)
            {
                storage[hashOffset + i * 2] = cast(ubyte) hex[value >> 4];
                storage[hashOffset + i * 2 + 1] = cast(ubyte) hex[value & 15];
            }
        }
    }
}

@("text.hyphenation.maxOverlayExceptionsAndTransactionalCapacity")
@safe pure nothrow @nogc
unittest
{
    PatternFixture fixture;
    fixture.initialize();
    dchar[3] key = ['a', 'b', 'c'];
    HyphenationException[1] exceptions = [HyphenationException(keyCount: 3, breakCount: 1)];
    HyphenationExceptionBreak[1] breaks = [HyphenationExceptionBreak(position: 2,
        consumedStart: 1, consumedEnd: 3,
        fragments: HyphenationFragments(preBreak: "B-", postBreak: "C", unbroken: "bc"))];
    HyphenationVisit[6] visits;
    auto tables = fixture.tables();
    HyphenationResource resource;
    auto work = testWork();
    HyphenationResult validation;
    validateHyphenationResource(resource, tables, visits[], work, validation);
    assert(validation.succeeded());
    UnicodeSourceSpan[3] map = [UnicodeSourceSpan(start: 0, end: 1),
        UnicodeSourceSpan(start: 1, end: 2), UnicodeSourceSpan(start: 2, end: 3)];
    size_t[4] allowedBoundaries = [0, 1, 2, 3];
    auto lookup = HyphenationLookup(source: "abc", word: UnicodeSourceSpan(start: 0, end: 3),
        unalteredKey: key[], unalteredSourceMap: map[], allowedSourceBoundaries: allowedBoundaries[]);
    auto options = HyphenationOptions(leftMinimum: 1, rightMinimum: 1,
        patternFragments: HyphenationFragments(preBreak: "-"));
    ubyte[6] overlay;
    size_t[4] mapped;
    HyphenationCandidateDraft[3] candidateScratch;
    HyphenationCandidate[3] destination;
    auto scratch = HyphenationMatchScratch(weights: overlay[], sourceBoundaries: mapped[],
        candidates: candidateScratch[]);
    auto output = HyphenationOutput(storage: destination[]);
    HyphenationResult result;
    work = testWork();
    matchHyphenation(output, resource, lookup, options, scratch, work, result);
    assert(result.succeeded());
    assert(output.candidates.length == 1 && output.candidates[0].sourceAnchor == 1);
    assert(output.candidates[0].fragments.preBreak == "-" && !output.candidates[0].fromException);

    const saved = destination;
    const published = output.candidates;
    output.storage = destination[0 .. 0];
    work = testWork();
    matchHyphenation(output, resource, lookup, options, scratch, work, result);
    assert(result.status == HyphenationStatus.outputCapacity);
    assert(destination == saved && output.candidates.ptr == published.ptr
        && output.candidates.length == published.length);
    output.storage = destination[];
    work = testWork();
    work.transitions = 0;
    matchHyphenation(output, resource, lookup, options, scratch, work, result);
    assert(result.status == HyphenationStatus.budgetExhausted);
    assert(destination == saved && output.candidates == published);
    work = testWork();
    work.scalars = 2;
    matchHyphenation(output, resource, lookup, options, scratch, work, result);
    assert(result.status == HyphenationStatus.budgetExhausted);
    assert(destination == saved && output.candidates == published);
    auto insufficientScratch = scratch;
    insufficientScratch.candidates = candidateScratch[0 .. 0];
    work = testWork();
    matchHyphenation(output, resource, lookup, options, insufficientScratch, work, result);
    assert(result.status == HyphenationStatus.scratchCapacity);
    assert(destination == saved && output.candidates == published);
    key[1] = 'd'; // An unaltered key may not lie about its source scalar.
    work = testWork();
    matchHyphenation(output, resource, lookup, options, scratch, work, result);
    assert(result.status == HyphenationStatus.invalidInput);
    assert(destination == saved && output.candidates == published);
    key[1] = 'b';

    tables.exceptionKeys = key[];
    tables.exceptions = exceptions[];
    tables.exceptionBreaks = breaks[];
    work = testWork();
    validateHyphenationResource(resource, tables, visits[], work, validation);
    assert(validation.succeeded());
    work = testWork();
    matchHyphenation(output, resource, lookup, options, scratch, work, result);
    assert(result.succeeded());
    assert(output.candidates.length == 1 && output.candidates[0].sourceAnchor == 2);
    const candidate = output.candidates[0];
    assert(candidate.fromException && candidate.consumedSource == UnicodeSourceSpan(start: 1, end: 3));
    assert(candidate.preAnchor == 1 && candidate.postAnchor == 3 && candidate.unbrokenAnchor == 1);
    assert(candidate.fragments.preBreak == "B-" && candidate.fragments.postBreak == "C"
        && candidate.fragments.unbroken == "bc");
    options.exceptions = HyphenationExceptionPolicy.ignoreExceptions;
    work = testWork();
    matchHyphenation(output, resource, lookup, options, scratch, work, result);
    assert(result.succeeded());
    assert(output.candidates.length == 1 && output.candidates[0].sourceAnchor == 1);
    options.exceptions = HyphenationExceptionPolicy.replacePatterns;
    exceptions[0].breakCount = 0;
    tables.exceptionBreaks = null;
    work = testWork();
    validateHyphenationResource(resource, tables, visits[], work, validation);
    assert(validation.succeeded());
    work = testWork();
    matchHyphenation(output, resource, lookup, options, scratch, work, result);
    assert(result.succeeded());
    assert(output.candidates.length == 0);
}

@("text.hyphenation.transformedExpansionReorderingAndWholeGraphemes")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.text.transform : UnicodeTransformUnit,
        UnicodeTransformWorkspace, UnicodeTransformEpoch;
    HyphenationNode[4] nodes = [HyphenationNode(edgeCount: 1),
        HyphenationNode(edgeStart: 1, edgeCount: 1),
        HyphenationNode(edgeStart: 2, edgeCount: 1), HyphenationNode(weightCount: 4)];
    HyphenationEdge[3] edges = [HyphenationEdge(symbol: 's', child: 1),
        HyphenationEdge(symbol: 's', child: 2), HyphenationEdge(symbol: 'c', child: 3)];
    ubyte[4] weights = [0, 3, 3, 0];
    auto tables = HyphenationTables(identity: testIdentity(), nodes: nodes[],
        edges: edges[], weights: weights[]);
    HyphenationVisit[4] visits;
    HyphenationResource resource;
    auto work = testWork();
    HyphenationResult validation;
    validateHyphenationResource(resource, tables, visits[], work, validation);
    assert(validation.succeeded());
    UnicodeTransformUnit[3] units;
    UnicodeSourceSpan[2] spans;
    UnicodeTransformEpoch[1] epoch;
    auto workspace = UnicodeTransformWorkspace(units: units[], spans: spans[], epoch: epoch[]);
    assert(workspace.begin().succeeded());
    UnicodeSourceSpan[2] origins = [UnicodeSourceSpan(start: 0, end: 2),
        UnicodeSourceSpan(start: 2, end: 3)];
    size_t first;
    assert(workspace.appendSources(origins[], first).succeeded());
    assert(workspace.appendUnit(UnicodeTransformUnit(value: 's', provenanceCount: 1)).succeeded());
    assert(workspace.appendUnit(UnicodeTransformUnit(value: 's', provenanceCount: 1)).succeeded());
    assert(workspace.appendUnit(UnicodeTransformUnit(value: 'c',
        provenanceStart: 1, provenanceCount: 1)).succeeded());
    workspace.publish();
    size_t[3] sourceGcb = [0, 2, 3];
    auto lookup = HyphenationLookup(source: "ßc", word: UnicodeSourceSpan(start: 0, end: 3),
        transformed: workspace.output(), allowedSourceBoundaries: sourceGcb[]);
    auto options = HyphenationOptions(leftMinimum: 1, rightMinimum: 1,
        patternFragments: HyphenationFragments(preBreak: "-"));
    ubyte[6] overlay;
    size_t[4] boundaryScratch;
    HyphenationCandidateDraft[2] staged;
    HyphenationCandidate[2] destination;
    auto scratch = HyphenationMatchScratch(weights: overlay[], sourceBoundaries: boundaryScratch[],
        candidates: staged[]);
    auto output = HyphenationOutput(storage: destination[]);
    HyphenationResult result;
    work = testWork();
    matchHyphenation(output, resource, lookup, options, scratch, work, result);
    assert(result.succeeded());
    assert(output.candidates.length == 1 && output.candidates[0].lookupPosition == 2
        && output.candidates[0].sourceAnchor == 2);
    options.leftMinimum = 2;
    work = testWork();
    matchHyphenation(output, resource, lookup, options, scratch, work, result);
    assert(result.succeeded());
    assert(output.candidates.length == 0); // Two lookup scalars are ONE source grapheme.
    options.leftMinimum = 1;

    // Reordered provenance crosses both potential cuts, despite the same scalar key.
    assert(workspace.begin().succeeded());
    assert(workspace.appendSources(origins[], first).succeeded());
    assert(workspace.appendUnit(UnicodeTransformUnit(value: 's',
        provenanceStart: 1, provenanceCount: 1)).succeeded());
    assert(workspace.appendUnit(UnicodeTransformUnit(value: 's', provenanceCount: 1)).succeeded());
    assert(workspace.appendUnit(UnicodeTransformUnit(value: 'c', provenanceCount: 1)).succeeded());
    workspace.publish();
    lookup.transformed = workspace.output();
    work = testWork();
    matchHyphenation(output, resource, lookup, options, scratch, work, result);
    assert(result.succeeded());
    assert(output.candidates.length == 0);
    assert(workspace.begin().succeeded());
    work = testWork();
    matchHyphenation(output, resource, lookup, options, scratch, work, result);
    assert(result.status == HyphenationStatus.invalidInput);
}

@("text.hyphenation.boundedParserHashHostileInputAndUnchangedPublication")
@safe pure nothrow @nogc
unittest
{
    PatternFixture fixture;
    fixture.initialize();
    dchar[3] key = ['a', 'b', 'c'];
    HyphenationException[1] exceptions = [HyphenationException(keyCount: 3, breakCount: 1)];
    HyphenationExceptionBreak[1] breaks = [HyphenationExceptionBreak(position: 2,
        consumedStart: 2, consumedEnd: 2, fragments: HyphenationFragments(preBreak: "!"))];
    auto tables = fixture.tables();
    tables.exceptionKeys = key[];
    tables.exceptions = exceptions[];
    tables.exceptionBreaks = breaks[];
    ubyte[1024] bytes;
    ubyte[1024] hostile;
    auto encoder = TestEncoder(storage: bytes[]);
    encoder.encode(tables);
    HyphenationNode[6] destinationNodes, stagingNodes;
    HyphenationEdge[5] destinationEdges, stagingEdges;
    ubyte[10] destinationWeights, stagingWeights;
    dchar[3] destinationKeys, stagingKeys;
    HyphenationException[1] destinationExceptions, stagingExceptions;
    HyphenationExceptionBreak[1] destinationBreaks;
    HyphenationBreakDraft[1] stagingBreaks;
    auto destination = HyphenationStorage(nodes: destinationNodes[], edges: destinationEdges[],
        weights: destinationWeights[], exceptionKeys: destinationKeys[],
        exceptions: destinationExceptions[], exceptionBreaks: destinationBreaks[]);
    auto staging = HyphenationStaging(nodes: stagingNodes[], edges: stagingEdges[],
        weights: stagingWeights[], exceptionKeys: stagingKeys[],
        exceptions: stagingExceptions[], exceptionBreaks: stagingBreaks[]);
    auto shortDestination = destination;
    shortDestination.nodes = destination.nodes[0 .. 5];
    auto shortStaging = staging;
    shortStaging.exceptionKeys = staging.exceptionKeys[0 .. 2];
    HyphenationVisit[6] visits;
    HyphenationResource resource;
    auto work = testWork();
    HyphenationResult result;
    {
        // Numeric staging is not retained by the published resource.
        HyphenationNode[6] transientNodes;
        HyphenationEdge[5] transientEdges;
        ubyte[10] transientWeights;
        dchar[3] transientKeys;
        HyphenationException[1] transientExceptions;
        HyphenationBreakDraft[1] transientBreaks;
        auto transient = HyphenationStaging(nodes: transientNodes[], edges: transientEdges[],
            weights: transientWeights[], exceptionKeys: transientKeys[],
            exceptions: transientExceptions[], exceptionBreaks: transientBreaks[]);
        parseHyphenationResource(resource, destination, bytes[0 .. encoder.length],
            transient, visits[], work, result);
        assert(result.succeeded());
        transientNodes[] = HyphenationNode.init;
        transientBreaks[] = HyphenationBreakDraft.init;
    }
    // Observe parsed numeric tables and borrowed replacement material in a lookup.
    UnicodeSourceSpan[3] map = [UnicodeSourceSpan(start: 0, end: 1),
        UnicodeSourceSpan(start: 1, end: 2), UnicodeSourceSpan(start: 2, end: 3)];
    size_t[4] gcb = [0, 1, 2, 3];
    auto lookup = HyphenationLookup(source: "abc", word: UnicodeSourceSpan(start: 0, end: 3),
        unalteredKey: key[], unalteredSourceMap: map[], allowedSourceBoundaries: gcb[]);
    ubyte[6] overlay;
    size_t[4] anchors;
    HyphenationCandidateDraft[2] stagedCandidates;
    HyphenationCandidate[2] candidates;
    auto scratch = HyphenationMatchScratch(weights: overlay[], sourceBoundaries: anchors[],
        candidates: stagedCandidates[]);
    auto output = HyphenationOutput(storage: candidates[]);
    work = testWork();
    matchHyphenation(output, resource, lookup, HyphenationOptions.init, scratch, work, result);
    assert(result.succeeded());
    assert(output.candidates.length == 1 && output.candidates[0].sourceAnchor == 2
        && output.candidates[0].fragments.preBreak == "!");

    const savedNodes = destinationNodes;
    const savedEdges = destinationEdges;
    const savedWeights = destinationWeights;
    const savedKeys = destinationKeys;
    const savedExceptions = destinationExceptions;
    const savedBreaks = destinationBreaks;
    const published = resource;
    work = testWork();
    parseHyphenationResource(resource, destination, bytes[0 .. encoder.length - 1],
        staging, visits[], work, result);
    assert(result.status == HyphenationStatus.hashMismatch);
    assert(destinationNodes == savedNodes && destinationEdges == savedEdges
        && destinationWeights == savedWeights && destinationKeys == savedKeys
        && destinationExceptions == savedExceptions && destinationBreaks == savedBreaks);
    assert(resource.tables().nodes.ptr == published.tables().nodes.ptr && resource.valid());
    work = testWork();
    parseHyphenationResource(resource, shortDestination, bytes[0 .. encoder.length],
        staging, visits[], work, result);
    assert(result.status == HyphenationStatus.outputCapacity);
    work = testWork();
    parseHyphenationResource(resource, destination, bytes[0 .. encoder.length],
        shortStaging, visits[], work, result);
    assert(result.status == HyphenationStatus.scratchCapacity);
    work = testWork();
    work.bytes = encoder.length - 1;
    parseHyphenationResource(resource, destination, bytes[0 .. encoder.length],
        staging, visits[], work, result);
    assert(result.status == HyphenationStatus.budgetExhausted);
    assert(destinationNodes == savedNodes && destinationEdges == savedEdges
        && destinationWeights == savedWeights && destinationKeys == savedKeys
        && destinationExceptions == savedExceptions && destinationBreaks == savedBreaks);

    // Separate hostile encoded bytes preserve the published immutable resource.
    auto bad = TestEncoder(storage: hostile[]);
    fixture.edges[2].child = 1; // A cycle, with a still-valid content hash.
    bad.encode(tables);
    work = testWork();
    parseHyphenationResource(resource, destination, hostile[0 .. bad.length],
        staging, visits[], work, result);
    assert(result.status == HyphenationStatus.invalidInput);
    fixture.initialize();
    fixture.edges[2].symbol = 0xD800;
    bad.encode(tables);
    work = testWork();
    parseHyphenationResource(resource, destination, hostile[0 .. bad.length],
        staging, visits[], work, result);
    assert(result.status == HyphenationStatus.invalidInput);
    fixture.initialize();
    fixture.weights[1] = 10;
    bad.encode(tables);
    work = testWork();
    parseHyphenationResource(resource, destination, hostile[0 .. bad.length],
        staging, visits[], work, result);
    assert(result.status == HyphenationStatus.invalidInput);
    fixture.initialize();
    breaks[0].position = 3;
    bad.encode(tables);
    work = testWork();
    parseHyphenationResource(resource, destination, hostile[0 .. bad.length],
        staging, visits[], work, result);
    assert(result.status == HyphenationStatus.invalidInput);
    breaks[0].position = 2;
    tables.identity.formatRevision = 99;
    bad.encode(tables);
    work = testWork();
    parseHyphenationResource(resource, destination, hostile[0 .. bad.length],
        staging, visits[], work, result);
    assert(result.status == HyphenationStatus.unsupportedRevision);
    tables.identity.formatRevision = hyphenationFormatRevision;
    tables.identity.unicodeRelease = "0.0.0";
    bad.encode(tables);
    work = testWork();
    parseHyphenationResource(resource, destination, hostile[0 .. bad.length],
        staging, visits[], work, result);
    assert(result.status == HyphenationStatus.releaseMismatch);
    assert(destinationNodes == savedNodes && destinationEdges == savedEdges
        && destinationWeights == savedWeights && destinationKeys == savedKeys
        && destinationExceptions == savedExceptions && destinationBreaks == savedBreaks);
    assert(resource.tables().nodes.ptr == published.tables().nodes.ptr);
}

@("text.hyphenation.explicitMarkersAndSourceClusterBoundary")
@safe pure nothrow @nogc
unittest
{
    // ^a1b$ matches only an entire word. It must not match the suffix of xab.
    HyphenationNode[5] nodes = [HyphenationNode(edgeCount: 1),
        HyphenationNode(edgeStart: 1, edgeCount: 1),
        HyphenationNode(edgeStart: 2, edgeCount: 1),
        HyphenationNode(edgeStart: 3, edgeCount: 1), HyphenationNode(weightCount: 5)];
    HyphenationEdge[4] edges = [HyphenationEdge(symbol: hyphenationWordStart, child: 1),
        HyphenationEdge(symbol: 'a', child: 2), HyphenationEdge(symbol: 'b', child: 3),
        HyphenationEdge(symbol: hyphenationWordEnd, child: 4)];
    ubyte[5] weights = [0, 0, 1, 0, 0];
    auto tables = HyphenationTables(identity: testIdentity(), nodes: nodes[], edges: edges[], weights: weights[]);
    HyphenationVisit[5] visits;
    HyphenationResource resource;
    auto work = testWork();
    HyphenationResult validation;
    validateHyphenationResource(resource, tables, visits[], work, validation);
    assert(validation.succeeded());
    dchar[3] key = ['x', 'a', 'b'];
    UnicodeSourceSpan[3] map = [UnicodeSourceSpan(start: 0, end: 1),
        UnicodeSourceSpan(start: 1, end: 2), UnicodeSourceSpan(start: 2, end: 3)];
    size_t[4] gcb = [0, 1, 2, 3];
    size_t[3] clusterGcb = [0, 3, 4];
    auto lookup = HyphenationLookup(source: "xab", word: UnicodeSourceSpan(start: 0, end: 3),
        unalteredKey: key[], unalteredSourceMap: map[], allowedSourceBoundaries: gcb[]);
    ubyte[6] overlay;
    size_t[4] anchors;
    HyphenationCandidateDraft[2] staged;
    HyphenationCandidate[2] candidates;
    auto scratch = HyphenationMatchScratch(weights: overlay[], sourceBoundaries: anchors[], candidates: staged[]);
    auto output = HyphenationOutput(storage: candidates[]);
    HyphenationResult result;
    work = testWork();
    matchHyphenation(output, resource, lookup, HyphenationOptions.init, scratch, work, result);
    assert(result.succeeded());
    assert(output.candidates.length == 0);
    lookup.word.start = 1;
    lookup.unalteredKey = key[1 .. 3];
    lookup.unalteredSourceMap = map[1 .. 3];
    lookup.allowedSourceBoundaries = gcb[1 .. 4];
    work = testWork();
    matchHyphenation(output, resource, lookup, HyphenationOptions.init, scratch, work, result);
    assert(result.succeeded());
    assert(output.candidates.length == 1 && output.candidates[0].sourceAnchor == 2);

    // An odd scalar boundary inside a + combining mark is not a source GCB.
    nodes[0].edgeCount = 1;
    tables.nodes = nodes[0 .. 2];
    tables.edges = edges[0 .. 1];
    nodes[1] = HyphenationNode(weightCount: 2);
    edges[0] = HyphenationEdge(symbol: 'a', child: 1);
    weights[0] = 0;
    weights[1] = 1;
    tables.weights = weights[0 .. 2];
    work = testWork();
    validateHyphenationResource(resource, tables, visits[], work, validation);
    assert(validation.succeeded());
    key = ['a', '\u0301', 'b'];
    map = [UnicodeSourceSpan(start: 0, end: 1), UnicodeSourceSpan(start: 1, end: 3),
        UnicodeSourceSpan(start: 3, end: 4)];
    lookup = HyphenationLookup(source: "a\u0301b", word: UnicodeSourceSpan(start: 0, end: 4),
        unalteredKey: key[], unalteredSourceMap: map[], allowedSourceBoundaries: clusterGcb[]);
    work = testWork();
    matchHyphenation(output, resource, lookup, HyphenationOptions.init, scratch, work, result);
    assert(result.succeeded());
    assert(output.candidates.length == 0);
}

version (unittest)
{
    // A validated resource must not escape the stack trie it borrows.
    static assert(!__traits(compiles, (() @safe pure nothrow @nogc
    {
        HyphenationNode[1] nodes;
        HyphenationVisit[1] visits;
        auto tables = HyphenationTables(identity: testIdentity(), nodes: nodes[]);
        HyphenationResource resource;
        HyphenationResult result;
        auto work = testWork();
        validateHyphenationResource(resource, tables, visits[], work, result);
        return resource;
    })()));

    // Parser publication must not detach the encoded string borrow, even when
    // destination storage itself is owned by the caller.
    static assert(!__traits(compiles, ((HyphenationStorage destination) @safe pure nothrow @nogc
    {
        ubyte[4] encoded;
        HyphenationVisit[1] visits;
        HyphenationStaging staging;
        HyphenationResource resource;
        HyphenationResult result;
        auto work = testWork();
        parseHyphenationResource(resource, destination, encoded[], staging, visits[], work, result);
        return resource;
    })(HyphenationStorage.init)));

    // Output descriptors borrow option fragments, not merely numeric scratch or
    // caller-owned output storage.
    static assert(!__traits(compiles, ((HyphenationCandidate[] storage) @safe pure nothrow @nogc
    {
        char[1] replacement = ['-'];
        auto options = HyphenationOptions(patternFragments: HyphenationFragments(preBreak: replacement[]));
        HyphenationResource resource;
        HyphenationLookup lookup;
        HyphenationMatchScratch scratch;
        auto output = HyphenationOutput(storage: storage);
        HyphenationResult result;
        auto work = testWork();
        matchHyphenation(output, resource, lookup, options, scratch, work, result);
        return output;
    })(cast(HyphenationCandidate[]) null)));
}
