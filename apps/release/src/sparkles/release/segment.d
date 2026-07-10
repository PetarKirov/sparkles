/++
Segmentation of the unreleased backlog into a chain of releases (SPEC §7).

The LLM agent sees the oldest-first commit list (with PR association) and
proposes contiguous segments — each a boundary SHA, a theme, a bump, and the
`highlights` its release notes should cover. This module owns the reply
contract: the tolerant JSON extraction ($(LREF stripJsonFence)), the typed
decode ($(LREF parseSegmentReply)), and — in the validation half — the
structural checks and bump reconciliation that turn a raw reply into an
executable plan.

Everything here is process-free and unit-tested on literal strings; the agent
invocation and git/gh IO stay in `app.d`, `agents.d`, and `pr.d`.
+/
module sparkles.release.segment;

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

/// One segment of the agent's reply (SPEC §7.2), pre-validation.
struct AgentSegment
{
    string boundary;                        /// full SHA of the segment's last commit
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
/// wired decode (unknown keys ignored; `highlights`/`remainderNote` optional).
/// All failures are `Result` errors, never exceptions.
Result!AgentReply parseSegmentReply(string raw) @system
{
    import sparkles.release.json_utils : decodeJson;

    auto reply = decodeJson!AgentReply(stripJsonFence(raw));
    if (reply.hasError)
        return failure!AgentReply("segmentation reply: " ~ reply.error);
    return reply;
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

/// Resolves each proposed boundary to an exclusive end index into `rows`:
/// a full 40-hex SHA or a unique prefix of ≥ 7 characters, strictly
/// increasing. The last boundary may fall short of the newest commit (the
/// suffix becomes the remainder); at least one segment is required.
Result!(size_t[]) resolveBoundaries(
    const(AgentSegment)[] segs, const(SegmentInput)[] rows) @safe
{
    if (segs.length == 0)
        return failure!(size_t[])("the agent proposed no segments");

    size_t[] ends;
    ends.reserve(segs.length);
    size_t floor = 0;
    foreach (ref seg; segs)
    {
        auto idx = resolveSha(seg.boundary, rows);
        if (idx.hasError)
            return failure!(size_t[])(idx.error);
        const end = idx.value + 1;
        if (end <= floor)
            return failure!(size_t[])(
                "boundary `" ~ seg.boundary ~ "` is out of order (segments must"
                ~ " be contiguous, oldest first, without duplicates)");
        ends ~= end;
        floor = end;
    }
    return success(ends);
}

/// Resolves a full SHA or a unique ≥ 7-character prefix to its row index.
private Result!size_t resolveSha(string boundary, const(SegmentInput)[] rows)
    @safe
{
    if (boundary.length < 7)
        return failure!size_t("boundary `" ~ boundary
            ~ "` is too short (full SHA or a prefix of at least 7 characters)");

    size_t found = size_t.max;
    foreach (i, ref row; rows)
    {
        if (row.sha.length < boundary.length
            || row.sha[0 .. boundary.length] != boundary)
            continue;
        if (found != size_t.max)
            return failure!size_t(
                "boundary `" ~ boundary ~ "` is ambiguous in the range");
        found = i;
    }
    if (found == size_t.max)
        return failure!size_t(
            "boundary `" ~ boundary ~ "` does not match any commit in the range");
    return success(found);
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
    auto endsR = resolveBoundaries(reply.segments, rows);
    if (endsR.hasError)
        return failure!ReleasePlan(endsR.error);
    const ends = endsR.value;

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
        `{"segments": [{"boundary": 42, "theme": "t", "bump": "minor"}]}`)
        .hasError);                                                // wrong type
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

@("segment.resolveBoundaries.happyPathAndPrefix")
@safe unittest
{
    SegmentInput[] rows;
    Commit[] commits;
    mkRange(["feat: a", "fix: b", "feat: c"], [1, 1, 2], rows, commits);

    // Full SHA and a ≥7-char unique prefix both resolve.
    auto ends = resolveBoundaries(
        [seg(rows[1].sha, "minor"), seg(rows[2].sha[0 .. 12], "patch")], rows);
    assert(ends.hasValue);
    assert(ends.value == [2, 3]);
}

@("segment.resolveBoundaries.rejections")
@safe unittest
{
    SegmentInput[] rows;
    Commit[] commits;
    mkRange(["feat: a", "fix: b"], [0, 0], rows, commits);

    assert(resolveBoundaries([], rows).hasError);                       // none
    assert(resolveBoundaries([seg("badbadbadbadbad", "minor")], rows)
        .hasError);                                                     // unknown
    assert(resolveBoundaries([seg(rows[0].sha[0 .. 6], "minor")], rows)
        .hasError);                                                     // too short
    assert(resolveBoundaries(
        [seg(rows[1].sha, "minor"), seg(rows[0].sha, "patch")], rows)
        .hasError);                                                     // out of order
    assert(resolveBoundaries(
        [seg(rows[0].sha, "minor"), seg(rows[0].sha, "patch")], rows)
        .hasError);                                                     // duplicate
}

@("segment.resolveBoundaries.ambiguousPrefix")
@safe unittest
{
    // Two rows sharing a 12-char prefix: the shared prefix is ambiguous.
    SegmentInput[] rows = [
        SegmentInput(sha: "aaaaaaaaaaaa1111111111111111111111111111"),
        SegmentInput(sha: "aaaaaaaaaaaa2222222222222222222222222222"),
    ];
    assert(resolveBoundaries([seg("aaaaaaaaaaaa", "minor")], rows).hasError);
    assert(resolveBoundaries([seg("aaaaaaaaaaaa1", "minor")], rows).hasValue);
}

@("segment.resolveBoundaries.trailingRemainderAllowed")
@safe unittest
{
    SegmentInput[] rows;
    Commit[] commits;
    mkRange(["feat: a", "fix: b", "chore: wip"], [1, 1, 0], rows, commits);

    auto ends = resolveBoundaries([seg(rows[1].sha, "minor")], rows);
    assert(ends.hasValue);
    assert(ends.value == [2]);      // row 2 is the remainder
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
        seg(rows[1].sha, "minor", "features"),
        seg(rows[3].sha, "patch", "fixes"),
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
    const escalate = AgentReply(segments: [seg(rows[1].sha, "patch")]);
    auto p1 = buildPlan(escalate, rows, commits, SemVer(major: 0, minor: 4, patch: 0));
    assert(p1.hasValue);
    assert(p1.value.segments[0].bump == BumpKind.minor);
    assert(p1.value.segments[0].bumpOrigin == BumpOrigin.escalated);

    // An unparsable token falls back to the floor (and is case-tolerant).
    const garbage = AgentReply(segments: [seg(rows[1].sha, "gigantic")]);
    auto p2 = buildPlan(garbage, rows, commits, SemVer(major: 0, minor: 4, patch: 0));
    assert(p2.hasValue);
    assert(p2.value.segments[0].bump == BumpKind.minor);
    assert(p2.value.segments[0].bumpOrigin == BumpOrigin.fallback);

    const cased = AgentReply(segments: [seg(rows[1].sha, " Minor\n")]);
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

    const reply = AgentReply(segments: [seg(rows[0].sha, "minor")]);
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
        segments: [seg(rows[0].sha, "minor")],
        remainderNote: "release tool still cooking");
    auto plan = buildPlan(reply, rows, commits, SemVer(major: 0, minor: 4, patch: 0));
    assert(plan.hasValue);
    assert(plan.value.remainderBegin == 1);
    assert(plan.value.remainderNote == "release tool still cooking");
}
