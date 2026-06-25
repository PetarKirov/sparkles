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

import sparkles.release.result : Result, success, failure;

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
