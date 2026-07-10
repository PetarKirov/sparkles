/++
The CLI LLM-agent registry used for the "summarize the commits into release
notes" path.

Each $(LREF AgentSpec) names a tool, the binary to look for on `$PATH`, and how
to invoke it once for a single prompt. Only agents actually present on `$PATH`
are offered to the user ($(LREF availableAgents)).

NOTE: the one-shot invocation flags below are best-effort and drift between tool
versions. `runAgent` surfaces the child's stderr so a wrong flag is diagnosable;
fix the offending `AgentSpec` here.
+/
module sparkles.release.agents;

import sparkles.core_cli.process_utils : isInPath, runCaptured;
import sparkles.versions.schemes.semver : SemVer;

import sparkles.release.result : Result, success, failure;
import sparkles.release.segment : SegmentInput;

@safe:

/// How an agent receives its prompt.
enum PromptDelivery
{
    arg,     /// appended as the final argv element
    stdin_,  /// piped to the child's standard input
}

/// One CLI agent: its menu `key`, the `binary` to find on `$PATH`, the `flags`
/// that precede the prompt, and how the prompt is delivered.
struct AgentSpec
{
    string key;
    string binary;
    immutable(string)[] flags;
    PromptDelivery delivery;
}

/// The curated agent menu. Edit/extend freely — it is just data.
immutable AgentSpec[] agentRegistry = [
    AgentSpec(key: "claude-code", binary: "claude",   flags: ["-p"],        delivery: PromptDelivery.arg),
    AgentSpec(key: "codex",       binary: "codex",    flags: ["exec"],      delivery: PromptDelivery.arg),
    AgentSpec(key: "gemini",      binary: "gemini",   flags: ["-p"],        delivery: PromptDelivery.arg),
    AgentSpec(key: "copilot",     binary: "copilot",  flags: ["-p"],        delivery: PromptDelivery.arg),
    AgentSpec(key: "opencode",    binary: "opencode", flags: ["run"],       delivery: PromptDelivery.arg),
    AgentSpec(key: "aider",       binary: "aider",    flags: ["--message"], delivery: PromptDelivery.arg),
    AgentSpec(key: "q",           binary: "q",        flags: ["chat"],      delivery: PromptDelivery.arg),
    AgentSpec(key: "crush",       binary: "crush",    flags: ["run"],       delivery: PromptDelivery.arg),
    AgentSpec(key: "goose",       binary: "goose",    flags: ["run", "-t"], delivery: PromptDelivery.arg),
    AgentSpec(key: "amp",         binary: "amp",      flags: ["-x"],        delivery: PromptDelivery.arg),
];

/// The registry entries whose `binary` is on `$PATH`.
const(AgentSpec)[] availableAgents()
{
    import std.algorithm.iteration : filter;
    import std.array : array;

    return agentRegistry.filter!(a => isInPath(a.binary)).array;
}

/// The registry entry for `key`, or `null`.
const(AgentSpec)* findAgent(string key) @safe pure nothrow @nogc
{
    foreach (ref a; agentRegistry)
        if (a.key == key)
            return &a;
    return null;
}

/// The argv used to invoke `a` for `prompt` (prompt appended only for
/// `PromptDelivery.arg`).
string[] buildArgv(const AgentSpec a, string prompt) @safe pure nothrow
{
    string[] argv = (a.binary ~ a.flags).dup;
    if (a.delivery == PromptDelivery.arg)
        argv ~= prompt;
    return argv;
}

/// Runs `a` once with `prompt`, returning its trimmed stdout as the notes, or a
/// failure (non-zero exit, or empty output).
Result!string runAgent(const AgentSpec a, string prompt)
{
    import std.conv : to;
    import std.string : strip;

    const argv = buildArgv(a, prompt);
    const stdinText = a.delivery == PromptDelivery.stdin_ ? prompt : null;
    auto r = runCaptured(argv, stdinText);

    if (r.status != 0)
        return failure!string(
            "agent `" ~ a.key ~ "` exited with status " ~ r.status.to!string
            ~ (r.stderr.strip.length ? ": " ~ r.stderr.strip.idup : ""));

    auto notes = r.stdout.strip;
    if (notes.length == 0)
        return failure!string("agent `" ~ a.key ~ "` produced no output");
    return success(notes.idup);
}

/// Builds the segmentation prompt (SPEC §7.1–§7.2): the bump-policy context
/// for `current`, the reply contract, and the oldest-first commit list with
/// its PR association embedded as compact JSON.
Result!string buildSegmentationPrompt(
    const(SegmentInput)[] rows, in SemVer current) @system
{
    import std.conv : text;

    import sparkles.release.json_utils : encodeJson;
    import sparkles.release.segment : verString;

    static struct PromptCommit
    {
        size_t i;
        string sha;
        uint pr;
        string prTitle;
        string subject;
    }

    static struct PromptInput
    {
        PromptCommit[] commits;
    }

    PromptCommit[] commits;
    commits.reserve(rows.length);
    foreach (i, ref row; rows)
        commits ~= PromptCommit(i: i, sha: row.sha, pr: row.prNumber,
            prTitle: row.prTitle, subject: row.subject);
    auto inputJson = encodeJson(PromptInput(commits));
    if (inputJson.hasError)
        return failure!string("segmentation prompt: " ~ inputJson.error);

    const policy = current.major == 0
        ? "- Bump policy (pre-1.0): a breaking change or a new feature means"
            ~ " \"minor\", otherwise \"patch\". Propose \"major\" only for an"
            ~ " intentional 1.0 graduation.\n"
        : "- Bump policy: a breaking change means \"major\"; a new feature"
            ~ " means \"minor\"; otherwise \"patch\".\n";

    return success(text(
        "You are planning retroactive releases for the D monorepo `sparkles`.\n",
        "The last released version is v", verString(current), ". Below are the ",
        rows.length, " unreleased commits, OLDEST FIRST, as JSON; `pr` is the",
        " number of the merged PR that introduced each commit (0 = none).\n",
        "Split them into a chain of releases.\n\n",
        "Rules:\n",
        "- Segments are contiguous slices of the list, in order; each segment",
        " becomes one release tag.\n",
        "- `boundary` is the FULL SHA of the LAST commit of its segment.\n",
        "- Commits sharing a `pr` number MUST all land in the same segment.\n",
        "- You MAY leave a trailing remainder of genuinely unreleasable",
        " work-in-progress out of all segments; explain why in `remainderNote`.",
        " Do not leave releasable work unassigned.\n",
        "- A segment need not wait for an area's work to complete:",
        " work-in-progress may land inside a segment undocumented. Per segment,",
        " `highlights` lists ONLY the completed, user-visible work that",
        " release's notes must cover; a highlight may complete an arc begun in",
        " an earlier segment (its notes will then summarize the whole arc).",
        " Everything not highlighted is deferred to the release where it",
        " completes.\n",
        "- Prefer coherent themes, with boundaries at PR edges and natural",
        " feature completions.\n",
        "- `theme` is short; it becomes the tag subject `vX.Y.Z — <theme>`.\n",
        policy,
        "\nReply with ONLY this JSON object — no prose, no code fences:\n",
        `{"segments": [{"boundary": "<full sha>", "theme": "<short theme>",`,
        ` "bump": "patch|minor|major", "highlights": ["<completed work>"]}],`,
        ` "remainderNote": "<optional>"}`,
        "\n\nInput:\n", inputJson.value));
}

/// The corrective coda appended (with the original prompt) when the agent's
/// first segmentation reply failed to parse or validate (SPEC §7.3).
string buildSegmentationRetryCoda(string error) @safe pure nothrow
{
    return "\n\nYour previous reply was invalid: " ~ error
        ~ "\nReply with ONLY the JSON object described above.";
}

/// Builds the summarization prompt fed to the agent: it must emit *only* the
/// annotated-tag body in the release-guide format.
string buildAgentPrompt(string suggestedSubject, string range, string logStat)
{
    return
        "You are writing the release notes for a D monorepo called `sparkles`.\n"
        ~ "Summarize the commits in the git range " ~ range ~ " into an"
        ~ " annotated-tag body.\n\n"
        ~ "Format rules:\n"
        ~ "- First line: a subject like `" ~ suggestedSubject ~ "` (keep the"
        ~ " version, replace the theme with a short one).\n"
        ~ "- Then a blank line, then sections grouped by area, each with an"
        ~ " underlined heading (e.g. `core-cli` then a line of dashes).\n"
        ~ "- Put every breaking change under a `BREAKING — <area>` heading with"
        ~ " a concrete `Migration:` block.\n"
        ~ "- Output ONLY the notes text — no preamble, no code fences.\n\n"
        ~ "Commits (git log --stat):\n"
        ~ logStat;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("agents.registry.sane")
@safe unittest
{
    import std.algorithm.searching : canFind;

    assert(agentRegistry.length == 10);
    bool[string] seen;
    foreach (a; agentRegistry)
    {
        assert(a.key.length && a.binary.length);
        assert(a.key !in seen, "duplicate agent key");
        seen[a.key] = true;
    }
    assert(agentRegistry[0].key == "claude-code");
}

@("agents.findAgent")
@safe unittest
{
    assert(findAgent("gemini").binary == "gemini");
    assert(findAgent("not-an-agent") is null);
}

@("agents.buildArgv")
@safe unittest
{
    const claude = *findAgent("claude-code");
    assert(buildArgv(claude, "hello") == ["claude", "-p", "hello"]);

    const goose = *findAgent("goose");
    assert(buildArgv(goose, "hi") == ["goose", "run", "-t", "hi"]);
}

@("agents.buildSegmentationPrompt.policyAndInput")
@system unittest
{
    import std.algorithm.searching : canFind;

    const rows = [
        SegmentInput(sha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            prNumber: 47, prTitle: "feat(x): y", subject: "feat(x): part 1"),
        SegmentInput(sha: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            prNumber: 0, subject: "chore: direct push"),
    ];

    auto pre = buildSegmentationPrompt(rows, SemVer(major: 0, minor: 4, patch: 0));
    assert(pre.hasValue);
    assert(pre.value.canFind("v0.4.0"));
    assert(pre.value.canFind("pre-1.0"));
    assert(pre.value.canFind("OLDEST FIRST"));
    assert(pre.value.canFind(`"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"`));
    assert(pre.value.canFind(`"pr":47`));
    assert(pre.value.canFind(`"remainderNote"`));
    assert(pre.value.canFind("2 unreleased commits"));

    auto post = buildSegmentationPrompt(rows, SemVer(major: 1, minor: 0, patch: 0));
    assert(post.hasValue);
    assert(!post.value.canFind("pre-1.0"));
    assert(post.value.canFind(`a breaking change means "major"`));
}

@("agents.buildSegmentationRetryCoda")
@safe pure unittest
{
    import std.algorithm.searching : canFind;

    const coda = buildSegmentationRetryCoda("boundary `xyz` is unknown");
    assert(coda.canFind("boundary `xyz` is unknown"));
    assert(coda.canFind("ONLY the JSON object"));
}
