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

import sparkles.release.result : Result, success, failure;
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
