/++
Segmentation of the unreleased backlog into a chain of releases (SPEC §7).

The LLM agent sees the backlog as PR-atomic units ($(LREF buildUnits)) and
proposes contiguous segments — each a boundary unit index, a theme, a bump,
and the `highlights` its release notes should cover. This module owns the
reply contract: the tolerant JSON extraction ($(LREF stripJsonFence)), the
typed decode ($(LREF parseSegmentReply)), and — in the validation half — the
structural checks and bump reconciliation that turn a raw reply into an
executable plan.

Everything here is process-free and unit-tested on literal strings; the agent
invocation and git/gh IO stay in `app.d`, `agents.d`, and `pr.d`.
+/
module sparkles.release.segment;

import std.json : JSONValue;

import sparkles.versions.schemes.semver : SemVer;

import sparkles.release.bump : applyBump, BumpKind, parseBumpKind, suggestBump;
import sparkles.release.result : Result, success, failure;
import sparkles.release.stats : Commit, tallyCommits;
import sparkles.wired : WireOptional;

/// One row of the segmentation input shown to the agent, oldest first.
struct SegmentInput
{
    string sha;      /// full commit OID
    uint prNumber;   /// 0 ⇒ no merged PR (SPEC §6)
    string prTitle;  /// empty when `prNumber == 0`
    string subject;  /// the commit subject line
}

/++
One PR-atomic unit of the backlog: a merged PR with all of its commits, or a
single direct commit.

Segment boundaries are chosen between units, never inside one, so "a PR's
commits must all land in one release" holds by construction rather than by the
agent's care — and a boundary is a small integer it can order, not a 40-hex
OID it must copy (SPEC §7.1).
+/
struct SegmentUnit
{
    size_t begin;   /// inclusive index into the oldest-first commit list
    size_t end;     /// exclusive
    uint pr;        /// 0 ⇒ a direct commit (no merged PR)
    string title;   /// the PR title, or the commit subject when `pr == 0`
}

/++
Groups `rows` (oldest first) into $(LREF SegmentUnit)s.

A PR whose commits are interleaved with another's yields one unit spanning
both — units are contiguous slices, so the only way to keep each PR whole is
to merge the overlapping spans. In practice merges are rare (a repository's
merged PRs land as contiguous runs).
+/
SegmentUnit[] buildUnits(const(SegmentInput)[] rows) @safe pure
{
    import std.algorithm.comparison : max;
    import std.algorithm.iteration : cumulativeFold, each, filter, map;
    import std.array : array;
    import std.range : chain, dropBackOne, enumerate, iota, only, zip;

    // How far into the list each merged PR reaches.
    size_t[uint] lastRowOf;
    rows.enumerate
        .filter!(r => r[1].prNumber != 0)
        .each!(r => lastRowOf[r[1].prNumber] = r[0]);

    // The row every PR opened so far reaches — a running maximum. A unit may
    // end at row `i` exactly where that maximum has caught up with `i`: every
    // PR seen is complete. (Interleaved PRs simply keep the maximum ahead, so
    // they land in one wider unit instead of a unit that splits a PR.)
    auto reach = rows.enumerate
        .map!(r => r[1].prNumber ? lastRowOf[r[1].prNumber] : r[0])
        .cumulativeFold!max;

    // Those cut points, as exclusive ends; each unit runs from the previous.
    const ends = zip(iota(rows.length), reach)
        .filter!(r => r[0] >= r[1])
        .map!(r => r[0] + 1)
        .array;

    return zip(chain(only(size_t(0)), ends.dropBackOne), ends)
        .map!(span => SegmentUnit(
            begin: span[0],
            end: span[1],
            pr: rows[span[0]].prNumber,
            title: rows[span[0]].prNumber
                ? rows[span[0]].prTitle : rows[span[0]].subject))
        .array;
}

/// One segment of the agent's reply (SPEC §7.2), pre-validation.
struct AgentSegment
{
    string boundary;                        /// index of the segment's last unit
    string theme;                           /// short theme for `vX.Y.Z — <theme>`
    string bump;                            /// `patch`/`minor`/`major` proposal
    @WireOptional() string[] highlights;    /// completed work to document; absent ⇒ []
}

/// The agent's whole reply (SPEC §7.2).
struct AgentReply
{
    AgentSegment[] segments;
    @WireOptional() string remainderNote;   /// why a trailing suffix was left out
}

/// Extracts the JSON object from an agent reply that may wrap it in
/// ```` ```json ````/```` ``` ```` fences or prose: the substring from the
/// first `{` to the last `}` (SPEC §7.3). Replies without braces pass through
/// trimmed, so the JSON parser reports the real error.
string stripJsonFence(string raw) @safe pure nothrow @nogc
{
    auto s = trimAscii(raw);

    size_t lo = size_t.max;
    foreach (i, c; s)
        if (c == '{')
        {
            lo = i;
            break;
        }
    size_t hi = size_t.max;
    foreach_reverse (i, c; s)
        if (c == '}')
        {
            hi = i;
            break;
        }
    if (lo == size_t.max || hi == size_t.max || hi < lo)
        return s;
    return s[lo .. hi + 1];
}

private string trimAscii(string s) @safe pure nothrow @nogc
{
    static bool ws(char c) => c == ' ' || c == '\t' || c == '\n' || c == '\r';

    size_t b = 0;
    while (b < s.length && ws(s[b]))
        b++;
    size_t e = s.length;
    while (e > b && ws(s[e - 1]))
        e--;
    return s[b .. e];
}

/// Parses a raw agent reply into its typed form: fence extraction, JSON parse,
/// boundary normalization, wired decode (unknown keys ignored;
/// `highlights`/`remainderNote` optional). All failures are `Result` errors,
/// never exceptions.
Result!AgentReply parseSegmentReply(string raw) @system
{
    import sparkles.release.json_utils : decodeJsonValue, parseJsonText;

    auto dom = parseJsonText(stripJsonFence(raw));
    if (dom.hasError)
        return failure!AgentReply("segmentation reply: " ~ dom.error);

    auto reply = decodeJsonValue!AgentReply(withNormalizedBoundaries(dom.value));
    if (reply.hasError)
        return failure!AgentReply("segmentation reply: " ~ reply.error);
    return reply;
}

/++
Rewrites each segment's `boundary` to its decimal string.

The contract asks for a number — `"boundary": 19` — and that is what a reply
carries; the field stays textual in the model so that a reply quoting it
(`"19"`), or answering with something else entirely (an old-style SHA), still
decodes and can be rejected by $(LREF resolveBoundaries) with a message about
unit indices, rather than by the JSON layer with one about types.
+/
private JSONValue withNormalizedBoundaries(JSONValue dom) @safe
{
    import std.algorithm.iteration : map;
    import std.array : array;
    import std.json : JSONType;

    if (dom.type != JSONType.object || "segments" !in dom
        || dom["segments"].type != JSONType.array)
        return dom;

    dom["segments"] = JSONValue(
        dom["segments"].arrayNoRef.map!withBoundaryAsText.array);
    return dom;
}

/// ditto
private JSONValue withBoundaryAsText(JSONValue seg) @safe
{
    import std.conv : to;
    import std.json : JSONType;

    if (seg.type != JSONType.object || "boundary" !in seg)
        return seg;

    const b = seg["boundary"];
    if (b.type == JSONType.integer)
        seg["boundary"] = JSONValue(b.integer.to!string);
    else if (b.type == JSONType.uinteger)
        seg["boundary"] = JSONValue(b.uinteger.to!string);
    else if (b.type == JSONType.float_)
        seg["boundary"] = JSONValue((cast(long) b.floating).to!string);
    return seg;
}

// ---------------------------------------------------------------------------
// Validation and reconciliation (SPEC §7.3)
// ---------------------------------------------------------------------------

/// Where a segment's final bump came from.
enum BumpOrigin
{
    agent,      /// the agent's proposal, at or above the policy floor
    escalated,  /// the agent under-bumped; raised to the policy floor
    fallback,   /// the agent's token did not parse; policy floor used
}

/// One validated, reconciled segment of the release plan.
struct SegmentPlan
{
    size_t begin;        /// inclusive index into the oldest-first commit list
    size_t end;          /// exclusive; `boundarySha == rows[end - 1].sha`
    string boundarySha;  /// the commit the tag is created on
    string theme;
    string[] highlights;
    BumpKind bump;
    BumpOrigin bumpOrigin;
    SemVer version_;     /// chained: `applyBump(previous, bump)`
    string tag;          /// `"v" ~ version_`
    uint[] prNumbers;    /// distinct merged-PR numbers, 0 excluded, in order
}

/// The whole validated plan.
struct ReleasePlan
{
    SegmentPlan[] segments;
    size_t remainderBegin;  /// == row count when nothing is left unreleased
    string remainderNote;
    size_t noPrCommits;     /// rows with `prNumber == 0` across the backlog
}

/// Resolves each proposed boundary — the index of the segment's last unit,
/// strictly increasing — to an exclusive end index into the commit list. The
/// last boundary may fall short of the newest unit (the suffix becomes the
/// remainder); at least one segment is required.
Result!(size_t[]) resolveBoundaries(
    const(AgentSegment)[] segs, const(SegmentUnit)[] units) @safe
{
    import std.algorithm.iteration : map;
    import std.algorithm.searching : find, findAdjacent;
    import std.array : array, empty, front;
    import std.conv : text;

    if (segs.empty)
        return failure!(size_t[])("the agent proposed no segments");

    auto parsed = segs.map!(s => parseUnitIndex(s.boundary, units.length)).array;
    auto invalid = parsed.find!(p => p.hasError);
    if (!invalid.empty)
        return failure!(size_t[])(invalid.front.error);

    auto indices = parsed.map!(p => p.value).array;
    auto disorder = indices.findAdjacent!"a >= b";
    if (!disorder.empty)
        return failure!(size_t[])(text(
            "boundary ", disorder[1], " is out of order (segments must be"
            ~ " contiguous, oldest first, without duplicates)"));

    return success(indices.map!(i => cast(size_t) units[i].end).array);
}

/// Parses a boundary token as a unit index below `count`, tolerating the
/// surrounding whitespace and quotes a reply sometimes carries.
private Result!size_t parseUnitIndex(string boundary, size_t count) @safe
{
    import std.algorithm.searching : all;
    import std.array : empty;
    import std.ascii : isDigit;
    import std.conv : ConvException, text, to;
    import std.string : chomp, chompPrefix, strip;

    const s = boundary.strip.chompPrefix(`"`).chomp(`"`).strip;
    if (s.empty)
        return failure!size_t("a segment has no boundary");
    if (!s.all!isDigit)
        return failure!size_t(text(
            "boundary `", boundary, "` is not a unit index (expected a number"
            ~ " between 0 and ", count - 1, ")"));

    // `to` catches the overflow a hand-rolled accumulator would wrap through.
    size_t value;
    try
        value = s.to!size_t;
    catch (ConvException)
        value = size_t.max;
    if (value >= count)
        return failure!size_t(text(
            "boundary `", boundary, "` is out of range (the backlog has ",
            count, " units, 0 to ", count - 1, ")"));
    return success(value);
}

/// Checks that no merged PR's commits straddle a segment edge (or the
/// segment/remainder edge). Null on success, else a message naming the PR.
/// Rows with `prNumber == 0` are exempt.
string checkPrIntegrity(const(size_t)[] ends, const(SegmentInput)[] rows)
    @safe pure
{
    import std.conv : text;

    size_t segOf(size_t i)
    {
        foreach (s, e; ends)
            if (i < e)
                return s;
        return ends.length;     // the remainder
    }

    // Parallel arrays instead of an AA: the row/PR counts are tiny.
    uint[] prs;
    size_t[] firstSeg;
    foreach (i, ref row; rows)
    {
        if (row.prNumber == 0)
            continue;
        const s = segOf(i);
        size_t at = size_t.max;
        foreach (k, p; prs)
            if (p == row.prNumber)
            {
                at = k;
                break;
            }
        if (at == size_t.max)
        {
            prs ~= row.prNumber;
            firstSeg ~= s;
        }
        else if (firstSeg[at] != s)
            return text("PR #", row.prNumber,
                " is split across a segment boundary (its commits must land in"
                ~ " one release)");
    }
    return null;
}

/// The full pipeline: boundary resolution → PR integrity → per-segment bump
/// reconciliation (the policy floor from `suggestBump` wins over an
/// under-bump; an unparsable token falls back to it) → version chaining from
/// `current` (SPEC §7.3 steps 2–5). `rows` and `commits` are parallel.
Result!ReleasePlan buildPlan(
    const AgentReply reply, const(SegmentInput)[] rows,
    const(Commit)[] commits, in SemVer current) @safe
in (rows.length == commits.length)
{
    auto endsR = resolveBoundaries(reply.segments, buildUnits(rows));
    if (endsR.hasError)
        return failure!ReleasePlan(endsR.error);
    const ends = endsR.value;

    // Structurally impossible once boundaries are unit indices — kept as the
    // invariant's guard, so a regression in `buildUnits` cannot ship a plan
    // that splits a PR across two releases.
    if (auto msg = checkPrIntegrity(ends, rows))
        return failure!ReleasePlan(msg);

    ReleasePlan plan;
    plan.segments.reserve(reply.segments.length);
    plan.remainderBegin = ends[$ - 1];
    plan.remainderNote = reply.remainderNote;
    foreach (ref row; rows)
        if (row.prNumber == 0)
            plan.noPrCommits++;

    SemVer prev = current;
    size_t begin = 0;
    foreach (i, ref seg; reply.segments)
    {
        const end = ends[i];
        const tally = tallyCommits(commits[begin .. end]);
        const floor = suggestBump(tally, prev);

        auto proposed = parseBumpKind(normalizeToken(seg.bump));
        BumpKind bump;
        BumpOrigin origin;
        if (proposed.isNull)
        {
            bump = floor;
            origin = BumpOrigin.fallback;
        }
        else if (proposed.get < floor)
        {
            bump = floor;
            origin = BumpOrigin.escalated;
        }
        else
        {
            bump = proposed.get;
            origin = BumpOrigin.agent;
        }

        const version_ = applyBump(prev, bump);
        plan.segments ~= SegmentPlan(
            begin: begin,
            end: end,
            boundarySha: rows[end - 1].sha,
            theme: seg.theme,
            highlights: seg.highlights.dup,
            bump: bump,
            bumpOrigin: origin,
            version_: version_,
            tag: "v" ~ verString(version_),
            prNumbers: distinctPrs(rows[begin .. end]),
        );
        prev = version_;
        begin = end;
    }
    return success(plan);
}

private string normalizeToken(string s) @safe pure nothrow
{
    auto t = trimAscii(s);
    char[] lowered = new char[](t.length);
    foreach (i, c; t)
        lowered[i] = c >= 'A' && c <= 'Z' ? cast(char)(c + ('a' - 'A')) : c;
    return lowered.idup;
}

private uint[] distinctPrs(const(SegmentInput)[] rows) @safe pure nothrow
{
    uint[] prs;
    outer: foreach (ref row; rows)
    {
        if (row.prNumber == 0)
            continue;
        foreach (p; prs)
            if (p == row.prNumber)
                continue outer;
        prs ~= row.prNumber;
    }
    return prs;
}

/// `SemVer` → `"X.Y.Z"` (no `v` prefix). Shared with the prompt builders.
package string verString(in SemVer v) @safe pure
{
    import sparkles.base.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 64) buf;
    v.toString(buf);
    return buf[].idup;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("segment.stripJsonFence.bareAndFenced")
@safe pure nothrow @nogc
unittest
{
    assert(stripJsonFence(`{"a": 1}`) == `{"a": 1}`);
    assert(stripJsonFence("```json\n{\"a\": 1}\n```") == `{"a": 1}`);
    assert(stripJsonFence("```\n{\"a\": 1}\n```\n") == `{"a": 1}`);
    assert(stripJsonFence("Here is the plan:\n{\"a\": 1}\nHope this helps!")
        == `{"a": 1}`);
    // No braces: trimmed pass-through (the parser reports the real error).
    assert(stripJsonFence("  no json here \n") == "no json here");
}

@("segment.stripJsonFence.nestedBracesSurvive")
@safe pure nothrow @nogc
unittest
{
    const raw = "```json\n{\"segments\": [{\"boundary\": \"x\"}]}\n```";
    assert(stripJsonFence(raw) == `{"segments": [{"boundary": "x"}]}`);
}

@("segment.parseSegmentReply.fullAndDefaults")
@system unittest
{
    const raw = `{"segments": [
        {"boundary": "abc1234", "theme": "tui components", "bump": "minor",
            "highlights": ["drawTable spans", "live regions"]},
        {"boundary": "def5678", "theme": "fixes", "bump": "patch"}
    ], "remainderNote": "release tool WIP"}`;

    auto r = parseSegmentReply(raw);
    assert(r.hasValue);
    const reply = r.value;
    assert(reply.segments.length == 2);
    assert(reply.segments[0].boundary == "abc1234");
    assert(reply.segments[0].highlights == ["drawTable spans", "live regions"]);
    assert(reply.segments[1].highlights.length == 0);    // optional ⇒ default
    assert(reply.segments[1].bump == "patch");
    assert(reply.remainderNote == "release tool WIP");
}

@("segment.parseSegmentReply.fencedWithProse")
@system unittest
{
    const raw = "Sure! Here is the segmentation:\n```json\n"
        ~ `{"segments": [{"boundary": "abc", "theme": "t", "bump": "minor"}]}`
        ~ "\n```\nLet me know if you need anything else.";
    auto r = parseSegmentReply(raw);
    assert(r.hasValue);
    assert(r.value.segments.length == 1);
    assert(r.value.remainderNote.length == 0);           // optional ⇒ default
}

@("segment.parseSegmentReply.malformedIsErrorNotThrow")
@system unittest
{
    assert(parseSegmentReply("I could not decide.").hasError);
    assert(parseSegmentReply(`{"segments": `).hasError);
    assert(parseSegmentReply(`{"wrong": []}`).hasError);           // missing key
    assert(parseSegmentReply(
        `{"segments": [{"boundary": {}, "theme": "t", "bump": "minor"}]}`)
        .hasError);                                                // wrong type
}

@("segment.parseSegmentReply.boundaryNumberOrString")
@system unittest
{
    // The contract asks for a number, and that is what a reply carries…
    auto asNumber = parseSegmentReply(
        `{"segments": [{"boundary": 19, "theme": "t", "bump": "minor"}]}`);
    assert(asNumber.hasValue);
    assert(asNumber.value.segments[0].boundary == "19");

    // …but a quoted or float-shaped one means the same thing, and an answer of
    // another shape entirely survives the decode so the boundary check — not
    // the JSON layer — gets to explain what a boundary is.
    assert(parseSegmentReply(
        `{"segments": [{"boundary": "19", "theme": "t", "bump": "minor"}]}`)
        .value.segments[0].boundary == "19");
    assert(parseSegmentReply(
        `{"segments": [{"boundary": 19.0, "theme": "t", "bump": "minor"}]}`)
        .value.segments[0].boundary == "19");
    assert(parseSegmentReply(
        `{"segments": [{"boundary": "827d238e", "theme": "t", "bump": "minor"}]}`)
        .value.segments[0].boundary == "827d238e");
}

version (unittest)
{
    import sparkles.release.conventional : parseConventional;

    /// A deterministic fake full SHA whose leading two hex chars encode the
    /// index (so short prefixes stay unique), padded with `f` to 40 chars.
    private string fakeSha(size_t i) @safe pure
    in (i < 0x60)
    {
        import std.format : format;

        const head = format!"%02x"(0xa0 + i);
        char[] s = new char[](40);
        s[] = 'f';
        s[0 .. head.length] = head;
        return s.idup;
    }

    /// Builds parallel `rows`/`commits` from `(subject, pr)` pairs.
    private void mkRange(
        const(string)[] subjects, const(uint)[] prs,
        out SegmentInput[] rows, out Commit[] commits) @safe pure
    {
        assert(subjects.length == prs.length);
        foreach (i, subject; subjects)
        {
            const sha = fakeSha(i);
            rows ~= SegmentInput(sha: sha, prNumber: prs[i], subject: subject);
            Commit c;
            c.sha = sha;
            c.subject = subject;
            c.conv = parseConventional(subject, "");
            commits ~= c;
        }
    }

    private AgentSegment seg(string boundary, string bump, string theme = "t")
        @safe pure nothrow
    {
        return AgentSegment(boundary: boundary, theme: theme, bump: bump);
    }
}

@("segment.buildUnits.prRunsAndDirectCommits")
@safe pure unittest
{
    SegmentInput[] rows;
    Commit[] commits;
    mkRange(
        ["feat: a", "fix: b", "chore: direct", "feat: c", "feat: d"],
        [7, 7, 0, 9, 9],
        rows, commits);

    const units = buildUnits(rows);
    assert(units.length == 3);
    assert(units[0] == SegmentUnit(begin: 0, end: 2, pr: 7, title: ""));
    assert(units[1] == SegmentUnit(begin: 2, end: 3, pr: 0, title: "chore: direct"));
    assert(units[2] == SegmentUnit(begin: 3, end: 5, pr: 9, title: ""));
}

@("segment.buildUnits.interleavedPrsMergeIntoOneUnit")
@safe pure unittest
{
    SegmentInput[] rows;
    Commit[] commits;
    // PR #7's commits straddle PR #9's: no contiguous split keeps both whole,
    // so the span merges rather than producing a unit that splits a PR.
    mkRange(["feat: a", "feat: b", "fix: c"], [7, 9, 7], rows, commits);

    const units = buildUnits(rows);
    assert(units.length == 1);
    assert(units[0].begin == 0 && units[0].end == 3);

    // Whatever the grouping, every unit stays a contiguous cover of the rows.
    size_t at;
    foreach (ref u; units)
    {
        assert(u.begin == at && u.end > u.begin);
        at = u.end;
    }
    assert(at == rows.length);
}

@("segment.resolveBoundaries.unitIndices")
@safe unittest
{
    SegmentInput[] rows;
    Commit[] commits;
    mkRange(["feat: a", "fix: b", "feat: c"], [1, 1, 2], rows, commits);
    const units = buildUnits(rows);        // [0,2) pr 1 | [2,3) pr 2

    // A boundary resolves to its unit's exclusive commit end.
    auto ends = resolveBoundaries([seg("0", "minor"), seg("1", "patch")], units);
    assert(ends.hasValue);
    assert(ends.value == [2, 3]);

    // Quoted and padded numbers are tolerated (replies sometimes carry them).
    assert(resolveBoundaries([seg(` "1" `, "minor")], units).value == [3]);
}

@("segment.resolveBoundaries.rejections")
@safe unittest
{
    import std.algorithm.searching : canFind;

    SegmentInput[] rows;
    Commit[] commits;
    mkRange(["feat: a", "fix: b"], [0, 0], rows, commits);
    const units = buildUnits(rows);        // one unit per direct commit

    assert(resolveBoundaries([], units).hasError);                      // none
    assert(resolveBoundaries([seg("", "minor")], units).hasError);      // empty

    // A SHA — what the contract used to ask for — is named as the wrong shape.
    const sha = resolveBoundaries([seg(rows[0].sha, "minor")], units);
    assert(sha.hasError);
    assert(sha.error.canFind("is not a unit index"));

    // Past the end, rather than a silent clamp onto the last unit.
    const past = resolveBoundaries([seg("2", "minor")], units);
    assert(past.hasError);
    assert(past.error.canFind("out of range"));

    // A huge number must not overflow into a valid index.
    assert(resolveBoundaries([seg("99999999999999999999999", "minor")], units)
        .hasError);

    assert(resolveBoundaries([seg("1", "minor"), seg("0", "patch")], units)
        .hasError);                                                     // out of order
    assert(resolveBoundaries([seg("0", "minor"), seg("0", "patch")], units)
        .hasError);                                                     // duplicate
}

@("segment.resolveBoundaries.trailingRemainderAllowed")
@safe unittest
{
    SegmentInput[] rows;
    Commit[] commits;
    mkRange(["feat: a", "fix: b", "chore: wip"], [1, 1, 0], rows, commits);
    const units = buildUnits(rows);        // [0,2) pr 1 | [2,3) direct

    auto ends = resolveBoundaries([seg("0", "minor")], units);
    assert(ends.hasValue);
    assert(ends.value == [2]);      // unit 1 (row 2) is the remainder
}

@("segment.checkPrIntegrity.splitPrNamed")
@safe pure unittest
{
    import std.algorithm.searching : canFind;

    SegmentInput[] rows;
    Commit[] commits;
    mkRange(["feat: a", "feat: b", "fix: c"], [7, 7, 8], rows, commits);

    // Boundary between the two commits of PR #7.
    const msg = checkPrIntegrity([1, 3], rows);
    assert(msg !is null);
    assert(msg.canFind("#7"));

    // Boundary at the PR edge is fine.
    assert(checkPrIntegrity([2, 3], rows) is null);
}

@("segment.checkPrIntegrity.remainderAndPrZeroExempt")
@safe pure unittest
{
    import std.algorithm.searching : canFind;

    SegmentInput[] rows;
    Commit[] commits;
    mkRange(["feat: a", "fix: b", "chore: c", "chore: d"], [7, 0, 9, 9],
        rows, commits);

    // PR #9 lives entirely in the remainder: fine; pr 0 never binds.
    assert(checkPrIntegrity([2], rows) is null);
    // PR #9 split between the last segment and the remainder: named.
    const msg = checkPrIntegrity([3], rows);
    assert(msg !is null && msg.canFind("#9"));
}

@("segment.buildPlan.chainingAndPrLists")
@safe unittest
{
    SegmentInput[] rows;
    Commit[] commits;
    mkRange(
        ["feat: a", "fix: b", "fix: c", "fix: d"],
        [1, 1, 2, 0],
        rows, commits);

    const reply = AgentReply(segments: [
        seg("0", "minor", "features"),
        seg("2", "patch", "fixes"),
    ]);
    auto planR = buildPlan(reply, rows, commits,
        SemVer(major: 0, minor: 4, patch: 0));
    assert(planR.hasValue);
    const plan = planR.value;

    assert(plan.segments.length == 2);
    assert(plan.segments[0].tag == "v0.5.0");            // 0.4.0 → minor
    assert(plan.segments[0].bumpOrigin == BumpOrigin.agent);
    assert(plan.segments[0].boundarySha == rows[1].sha);
    assert(plan.segments[0].prNumbers == [1]);
    assert(plan.segments[1].tag == "v0.5.1");            // chained → patch
    assert(plan.segments[1].prNumbers == [2]);
    assert(plan.remainderBegin == rows.length);          // nothing left
    assert(plan.noPrCommits == 1);
}

@("segment.buildPlan.underBumpEscalatesAndFallback")
@safe unittest
{
    SegmentInput[] rows;
    Commit[] commits;
    mkRange(["feat: a", "fix: b"], [0, 0], rows, commits);

    // A feat-bearing pre-1.0 segment floors at minor: "patch" escalates.
    const escalate = AgentReply(segments: [seg("1", "patch")]);
    auto p1 = buildPlan(escalate, rows, commits, SemVer(major: 0, minor: 4, patch: 0));
    assert(p1.hasValue);
    assert(p1.value.segments[0].bump == BumpKind.minor);
    assert(p1.value.segments[0].bumpOrigin == BumpOrigin.escalated);

    // An unparsable token falls back to the floor (and is case-tolerant).
    const garbage = AgentReply(segments: [seg("1", "gigantic")]);
    auto p2 = buildPlan(garbage, rows, commits, SemVer(major: 0, minor: 4, patch: 0));
    assert(p2.hasValue);
    assert(p2.value.segments[0].bump == BumpKind.minor);
    assert(p2.value.segments[0].bumpOrigin == BumpOrigin.fallback);

    const cased = AgentReply(segments: [seg("1", " Minor\n")]);
    auto p3 = buildPlan(cased, rows, commits, SemVer(major: 0, minor: 4, patch: 0));
    assert(p3.hasValue);
    assert(p3.value.segments[0].bumpOrigin == BumpOrigin.agent);
}

@("segment.buildPlan.post1_0MajorFloor")
@safe unittest
{
    SegmentInput[] rows;
    Commit[] commits;
    mkRange(["feat!: breaking"], [0], rows, commits);

    const reply = AgentReply(segments: [seg("0", "minor")]);
    auto plan = buildPlan(reply, rows, commits, SemVer(major: 1, minor: 2, patch: 3));
    assert(plan.hasValue);
    assert(plan.value.segments[0].bump == BumpKind.major);   // escalated
    assert(plan.value.segments[0].tag == "v2.0.0");
    assert(plan.value.segments[0].bumpOrigin == BumpOrigin.escalated);
}

@("segment.buildPlan.remainderRecorded")
@safe unittest
{
    SegmentInput[] rows;
    Commit[] commits;
    mkRange(["feat: a", "chore: wip", "chore: wip2"], [1, 0, 0], rows, commits);

    const reply = AgentReply(
        segments: [seg("0", "minor")],
        remainderNote: "release tool still cooking");
    auto plan = buildPlan(reply, rows, commits, SemVer(major: 0, minor: 4, patch: 0));
    assert(plan.hasValue);
    assert(plan.value.remainderBegin == 1);
    assert(plan.value.remainderNote == "release tool still cooking");
}
