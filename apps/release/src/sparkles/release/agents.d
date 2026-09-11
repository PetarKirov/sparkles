/++
The CLI LLM-agent registry used for the "summarize the commits into release
notes" path.

Each $(LREF AgentSpec) names a tool, the binary to look for on `$PATH`, and how
to invoke it once for a single prompt. Only agents actually present on `$PATH`
are offered to the user ($(LREF availableAgents)).

A prompt always travels as a file — see $(LREF agentRegistry) for the three
ways an agent is handed one, and why none of them is an argv element.
+/
module sparkles.release.agents;

import sparkles.core_cli.process_utils : isInPath, runCaptured;
import sparkles.versions.schemes.semver : SemVer;

import sparkles.release.result : Result, success, failure;
import sparkles.release.segment : SegmentInput;
import sparkles.release.stats : AuthorCount;

@safe:

/++
The marker a $(LREF AgentSpec) flag uses to name the prompt file: every
occurrence is replaced with that run's prompt path ($(LREF buildArgv)).

A spec with no occurrence anywhere gets the prompt on standard input instead —
the same file, redirected rather than named.
+/
enum promptPathPlaceholder = "{}";

/// The flag text for an agent that takes neither a prompt file nor standard
/// input, only a prompt string: the string is a one-line pointer at the file.
private enum followPromptFile =
    "Read the file " ~ promptPathPlaceholder
    ~ " and follow the instructions in it exactly.";

/// One CLI agent: its menu `key`, the `binary` to find on `$PATH`, and the
/// `flags` invoking it once, non-interactively, on a prompt file.
struct AgentSpec
{
    string key;
    string binary;
    immutable(string)[] flags;
    /// Alternative binary names to try on `$PATH` when `binary` is absent (e.g.
    /// a tool distributed under more than one command name).
    immutable(string)[] aliases;
    /++
    Possible git author names (`%an` / `git shortlog`) this agent may appear
    under. Used to keep LLM tools out of the release-stats Authors box.

    Matching ($(LREF isAgentCommitAuthor)):
    $(LIST
        * exact, case-insensitive equality against a listed name;
        * a parenthesized suffix entry like `"(aider)"` matches any author
            ending in `" (aider)"` (aider's default attribution style).
    )

    Co-Authored-By trailers alone do not change `%an`, so an agent that only
    trailers (and never rewrites the author) has an empty list unless teams
    also set that identity as the git author for audit trails.
    +/
    immutable(string)[] commitAuthorNames;
}

/++
The curated agent menu. Edit/extend freely — it is just data.

The prompt is never an argv element (Linux caps one at `MAX_ARG_STRLEN`, 32
pages — a `--split` segmentation prompt over a long backlog is several times
that, and the spawn fails outright with `E2BIG`). It is written to a file, and
each entry says how its agent consumes one:

$(LIST
    * no $(LREF promptPathPlaceholder) — the file arrives on standard input
        (`claude -p`, `codex exec` and `amp -x` were verified to read it
        there; `codex exec --help` documents it);
    * a placeholder in a path flag — the tool reads the file itself
        (`aider --message-file`, `goose run -i`);
    * a placeholder inside `followPromptFile` — for a tool that accepts only
        a prompt string (`agy --print` ignores stdin), the string points at
        the file and the agent reads it with its own tools.
)

`commitAuthorNames` is filled from public docs / issue trackers (as of 2026-08):

$(LIST
    * `claude-code` — keeps the user's author by default; trailers
        `Co-Authored-By: Claude <noreply@anthropic.com>` (sometimes with a
        model name). `"Claude"` covers audit-trail configs that set the
        author field to that name.
    * `codex` — default is the user; optional attribution / shell policy often
        uses author `"Codex"`.
    * `amp` — `Co-authored-by: Amp <amp@ampcode.com>` (and optional author).
    * `aider` — appends `" (aider)"` to the git author/committer name.
    * `goose` — no documented automatic author rewrite.
    * `gemini` — no default commit-level attribution.
    * `copilot` — coding agent author `"GitHub Copilot"`; trailers / CLI also
        use `"Copilot"`.
    * `opencode` — `Co-Authored-By: opencode <noreply@opencode.ai>`.
    * `q` — GitHub bot identity `amazon-q-developer[bot]` / `"Amazon Q"`.
    * `crush` — `Co-Authored-By: Crush <crush@charm.land>` (or Assisted-by).
    * `agy` — no documented automatic author rewrite.
)

NOTE: the invocations below are best-effort and drift between tool versions.
`runAgent` surfaces the child's stderr so a wrong flag is diagnosable; fix the
offending entry here.
+/
immutable AgentSpec[] agentRegistry = [
    AgentSpec(key: "claude-code", binary: "claude",   flags: ["-p"],
        commitAuthorNames: ["Claude"]),
    AgentSpec(key: "codex",       binary: "codex",    flags: ["exec"],
        commitAuthorNames: ["Codex"]),
    AgentSpec(key: "amp",         binary: "amp",      flags: ["-x"],
        commitAuthorNames: ["Amp"]),
    AgentSpec(key: "aider",       binary: "aider",    flags: ["--message-file", promptPathPlaceholder],
        commitAuthorNames: ["(aider)"]),
    AgentSpec(key: "goose",       binary: "goose",    flags: ["run", "-i", promptPathPlaceholder]),
    AgentSpec(key: "gemini",      binary: "gemini",   flags: ["-p", followPromptFile]),
    AgentSpec(key: "copilot",     binary: "copilot",  flags: ["-p", followPromptFile],
        commitAuthorNames: ["GitHub Copilot", "Copilot"]),
    AgentSpec(key: "opencode",    binary: "opencode", flags: ["run", followPromptFile],
        commitAuthorNames: ["opencode", "OpenCode"]),
    AgentSpec(key: "q",           binary: "q",        flags: ["chat", followPromptFile],
        commitAuthorNames: ["amazon-q-developer[bot]", "Amazon Q"]),
    AgentSpec(key: "crush",       binary: "crush",    flags: ["run", followPromptFile],
        commitAuthorNames: ["Crush"]),
    AgentSpec(key: "agy",         binary: "agy",      flags: ["--print", followPromptFile],
        aliases: ["antigravity-cli"]),
];

/// True when `name` is a known LLM-agent git author from $(LREF agentRegistry).
bool isAgentCommitAuthor(scope const(char)[] name) @safe pure nothrow @nogc
{
    import std.uni : sicmp;

    if (name.length == 0)
        return false;
    foreach (ref a; agentRegistry)
        foreach (agentName; a.commitAuthorNames)
        {
            // Parenthesized suffix form: "(aider)" matches "Alice (aider)" only
            // (not a bare "(aider)" author string).
            if (agentName.length >= 3
                && agentName[0] == '('
                && agentName[$ - 1] == ')')
            {
                if (name.length > agentName.length
                    && name[$ - agentName.length - 1] == ' '
                    && sicmp(name[$ - agentName.length .. $], agentName) == 0)
                    return true;
                continue;
            }
            if (sicmp(name, agentName) == 0)
                return true;
        }
    return false;
}

/// Drops entries whose `name` is a known agent author (see $(LREF isAgentCommitAuthor)).
AuthorCount[] withoutAgentAuthors(AuthorCount[] authors) @safe pure nothrow
{
    import std.algorithm.iteration : filter;
    import std.array : array;

    return authors.filter!(a => !isAgentCommitAuthor(a.name)).array;
}
/// The registry entries resolvable to a `binary` on `$PATH`.
const(AgentSpec)[] availableAgents()
{
    import std.algorithm.iteration : joiner, map;
    import std.array : array;

    // Each `resolveBinary` is an `Expected` — a one-element range on success,
    // empty on failure — so `joiner` flattens away the not-installed agents.
    return agentRegistry
        .map!resolveBinary
        .joiner
        .array;
}

/// Returns `a` with `binary` set to the first of its candidate names — `binary`
/// itself, then each of its `aliases` — found on `$PATH`, or a failure when none
/// of them is installed.
Result!AgentSpec resolveBinary(AgentSpec a)
{
    import std.algorithm.searching : find;
    import std.array : empty, front;
    import std.range : chain, only;

    auto found = only(a.binary).chain(a.aliases).find!isInPath;
    if (found.empty)
        return failure!AgentSpec("agent `" ~ a.key ~ "` is not on PATH");
    a.binary = found.front;
    return success(a);
}

/// The registry entry for `key`, or `null`.
const(AgentSpec)* findAgent(string key) @safe pure nothrow @nogc
{
    import std.algorithm.searching : canFind, find;
    import std.array : empty;

    auto found = agentRegistry.find!(a => a.key == key || a.aliases.canFind(key));
    return found.empty ? null : &found[0];
}

/// Deletes `path`, ignoring a failure to do so (a leftover prompt file in the
/// temp directory is not worth failing a release over).
private void removeQuietly(string path) @safe nothrow
{
    import std.file : remove;

    try
        remove(path);
    catch (Exception)
    {
    }
}

/// The argv invoking `a` on the prompt file at `promptPath`: its flags with
/// every $(LREF promptPathPlaceholder) replaced by that path.
string[] buildArgv(const AgentSpec a, string promptPath) @safe pure
{
    import std.algorithm.iteration : map;
    import std.array : array, replace;

    return a.binary ~ a.flags.map!(f => f.replace(promptPathPlaceholder, promptPath)).array;
}

/// True when `a` names the prompt file in its argv (rather than reading it
/// from standard input).
bool namesPromptFile(const AgentSpec a) @safe pure nothrow
{
    import std.algorithm.searching : canFind;

    return a.flags.canFind!(f => f.canFind(promptPathPlaceholder));
}

/++
Runs `a` once on `prompt`, returning its trimmed stdout as the notes, or a
failure (non-zero exit, or empty output).

The prompt is written to a file under the system temp directory and removed
afterwards; the agent either has its path spliced into the argv or receives
the file on standard input (see $(LREF agentRegistry)). Nothing about the
prompt's size can make the spawn fail.
+/
Result!string runAgent(const AgentSpec a, string prompt)
{
    import std.conv : text, to;
    import std.file : FileException, tempDir, write;
    import std.path : buildPath;
    import std.process : thisProcessID;
    import std.string : strip;
    import core.atomic : atomicOp;

    static shared size_t counter;
    const usesFile = namesPromptFile(a);
    const promptPath = usesFile
        ? buildPath(tempDir, text("sparkles-release-prompt-", thisProcessID,
            "-", atomicOp!"+="(counter, 1), ".md"))
        : null;

    if (usesFile)
    {
        try
            write(promptPath, prompt);
        catch (FileException e)
            return failure!string(
                "could not write the prompt file for agent `" ~ a.key ~ "`: " ~ e.msg);
    }
    scope (exit)
        if (usesFile)
            removeQuietly(promptPath);

    // A file-naming agent reads the prompt itself; the rest get the same bytes
    // on stdin. `runCaptured` reads a *null* text as "inherit this process's
    // stdin" — an empty literal is non-null, so a file-naming agent still gets
    // a redirect (an immediate EOF) and cannot fall back to the terminal.
    static assert("" !is null);
    auto r = runCaptured(buildArgv(a, promptPath), usesFile ? "" : prompt);

    if (r.status != 0)
        return failure!string(
            "agent `" ~ a.key ~ "` exited with status " ~ r.status.to!string
            ~ (r.stderr.strip.length ? ": " ~ r.stderr.strip.idup : ""));

    auto notes = r.stdout.strip;
    if (notes.length == 0)
        return failure!string("agent `" ~ a.key ~ "` produced no output");
    return success(notes.idup);
}

/// The two renderings of one segmentation prompt: the compact form sent to
/// the agent (token-efficient) and the pretty form persisted as the
/// `.result/segmentation-prompt.md` artifact (human-readable).
struct SegmentationPrompt
{
    string forAgent;
    string forArtifact;
}

/// The reply contract shown to the agent, in both densities.
private enum compactReplySchema =
    `{"segments": [{"boundary": <last unit's i>, "theme": "<short theme>",`
    ~ ` "bump": "patch|minor|major", "highlights": ["<completed work>"]}],`
    ~ ` "remainderNote": "<optional>"}`;

private enum prettyReplySchema =
`{
    "segments": [
        {
            "boundary": <last unit's i>,
            "theme": "<short theme>",
            "bump": "patch|minor|major",
            "highlights": ["<completed work>"]
        }
    ],
    "remainderNote": "<optional>"
}`;

/++
Builds the segmentation prompt (SPEC §7.1–§7.2): the bump-policy context for
`current`, the reply contract, and the oldest-first backlog embedded as JSON —
compact toward the agent, pretty in the artifact rendering.

The backlog is presented as $(REF SegmentUnit, sparkles,release,segment)s
rather than raw commits: an agent picking a unit index cannot split a PR or
mistype an OID, and dropping the per-commit SHA and the PR title repeated on
every commit shrinks the prompt several-fold.
+/
Result!SegmentationPrompt buildSegmentationPrompt(
    const(SegmentInput)[] rows, in SemVer current) @system
{
    import sparkles.release.json_utils : encodeJson;
    import sparkles.release.segment : buildUnits;

    static struct PromptUnit
    {
        size_t i;
        uint pr;
        string title;
        string[] commits;
    }

    static struct PromptInput
    {
        PromptUnit[] units;
    }

    import std.algorithm.iteration : map;
    import std.array : array;
    import std.range : enumerate;

    const units = buildUnits(rows);
    auto promptUnits = units.enumerate
        .map!(u => PromptUnit(
            i: u[0],
            pr: u[1].pr,
            title: u[1].title,
            commits: rows[u[1].begin .. u[1].end].map!(r => r.subject[]).array))
        .array;

    auto compact = encodeJson(PromptInput(promptUnits));
    if (compact.hasError)
        return failure!SegmentationPrompt("segmentation prompt: " ~ compact.error);
    auto pretty = encodeJson(PromptInput(promptUnits), pretty: true);
    if (pretty.hasError)
        return failure!SegmentationPrompt("segmentation prompt: " ~ pretty.error);

    return success(SegmentationPrompt(
        forAgent: segmentationPromptText(
            units.length, rows.length, current, compactReplySchema, compact.value),
        forArtifact: segmentationPromptText(
            units.length, rows.length, current, prettyReplySchema, pretty.value)));
}

/// The shared prompt skeleton — valid markdown, with each JSON block fenced
/// long enough to survive a commit subject that contains a fence of its own,
/// so the artifact rendering needs no post-processing.
private string segmentationPromptText(
    size_t unitCount, size_t commitCount, in SemVer current,
    string replySchema, string inputJson) @safe pure
{
    import std.conv : text;

    import sparkles.release.segment : verString;

    const policy = current.major == 0
        ? "- Bump policy (pre-1.0): a breaking change or a new feature means"
            ~ " \"minor\", otherwise \"patch\". Propose \"major\" only for an"
            ~ " intentional 1.0 graduation.\n"
        : "- Bump policy: a breaking change means \"major\"; a new feature"
            ~ " means \"minor\"; otherwise \"patch\".\n";

    return text(
        "You are planning retroactive releases for the D monorepo `sparkles`.\n",
        "The last released version is v", verString(current), ". Below are the ",
        unitCount, " units of unreleased work (", commitCount, " commits),",
        " OLDEST FIRST, as JSON. A unit is one merged pull request with its",
        " commit subjects, or a single direct commit (`pr: 0`); `i` is its",
        " index.\n",
        "Split them into a chain of releases.\n\n",
        "Rules:\n\n",
        "- Segments are contiguous slices of the unit list, in order; each",
        " segment becomes one release tag.\n",
        "- `boundary` is the `i` of the LAST unit of its segment: a number,",
        " strictly increasing across segments.\n",
        "- A unit is atomic — it is never split between two releases, which is",
        " why you choose units and not commits.\n",
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
        "- Prefer coherent themes, with boundaries at natural feature",
        " completions.\n",
        "- `theme` is short; it becomes the tag subject `vX.Y.Z — <theme>`.\n",
        policy,
        "\nReply with ONLY a JSON object of this exact shape — no prose around",
        " it:\n\n",
        jsonFence(replySchema),
        "\nInput:\n\n",
        jsonFence(inputJson));
}

/++
Wraps `json` in a ```` ```json ```` fence long enough to survive the content:
a commit subject may itself contain a fence (this repository has a
`feat(ci): require ` ```` ```[Output] ```` ` for runnable-example output blocks`),
which would otherwise close the block early — leaving the agent, and the
artifact's reader, with a prompt that ends mid-input.
+/
private string jsonFence(string json) @safe pure
{
    import std.algorithm.comparison : max;
    import std.algorithm.iteration : filter, group, map;
    import std.algorithm.searching : maxElement;
    import std.array : replicate;

    // The longest backtick run in the content, so the fence can outrun it.
    const longest = json.group
        .filter!(run => run[0] == '`')
        .map!(run => run[1])
        .maxElement(0);

    const fence = "`".replicate(max(3, longest + 1));
    return fence ~ "json\n" ~ json ~ "\n" ~ fence ~ "\n";
}

/// The corrective coda appended (with the original prompt) when the agent's
/// first segmentation reply failed to parse or validate (SPEC §7.3).
string buildSegmentationRetryCoda(string error) @safe pure nothrow
{
    return "\n\nYour previous reply was invalid: " ~ error
        ~ "\nReply with ONLY the JSON object described above.";
}

/// The split-mode addition to a segment's notes prompt (SPEC §8.3): the
/// segment's highlights (the notes cover ONLY these), compact context of the
/// earlier segments' commits, and the WIP-omission instruction.
string buildSegmentNotesSection(
    const(string)[] highlights, const(string)[] priorContext) @safe pure
{
    import std.array : appender;

    auto app = appender!string;
    app.put("\n\nHighlights to document (cover ONLY these):\n");
    if (highlights.length == 0)
        app.put("- (none named — cover the completed, user-visible work only)\n");
    foreach (h; highlights)
    {
        app.put("- ");
        app.put(h);
        app.put('\n');
    }
    if (priorContext.length)
    {
        app.put("\nContext — commits already released in earlier tags"
            ~ " (reference only where a highlight completes work started"
            ~ " there):\n");
        foreach (line; priorContext)
        {
            app.put("  ");
            app.put(line);
            app.put('\n');
        }
    }
    app.put("\nOmit incomplete/work-in-progress changes; they will be"
        ~ " documented in the release where they complete.");
    return app[];
}

/// The `git log --stat` budget inside a notes prompt. Nothing about delivery
/// forces a limit any more — this one is about the model: the full log of a
/// hundreds-of-commits range is mostly diffstat noise, and summarizing it
/// costs context the notes themselves need.
enum promptLogStatCap = 96 * 1024;

/// Truncates `logStat` at a line boundary under `cap`, marking the elision.
string capLogStat(string logStat, size_t cap = promptLogStatCap) @safe pure nothrow
{
    if (logStat.length <= cap)
        return logStat;
    size_t cut = cap;
    while (cut > 0 && logStat[cut - 1] != '\n')
        cut--;
    return logStat[0 .. cut]
        ~ "[... log truncated — the rest of the range did not fit the prompt]";
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

    assert(agentRegistry.length == 11);
    bool[string] seen;
    foreach (a; agentRegistry)
    {
        assert(a.key.length && a.binary.length);
        assert(a.key !in seen, "duplicate agent key");
        seen[a.key] = true;
    }
    assert(agentRegistry[0].key == "claude-code");
    // Agents with known author attribution carry at least one name.
    assert(findAgent("claude-code").commitAuthorNames.canFind("Claude"));
    assert(findAgent("aider").commitAuthorNames.canFind("(aider)"));
    assert(findAgent("copilot").commitAuthorNames.canFind("GitHub Copilot"));
    assert(findAgent("goose").commitAuthorNames.length == 0);
}

@("agents.isAgentCommitAuthor")
@safe pure nothrow @nogc
unittest
{
    assert(isAgentCommitAuthor("Claude"));
    assert(isAgentCommitAuthor("claude"));           // case-insensitive
    assert(isAgentCommitAuthor("GitHub Copilot"));
    assert(isAgentCommitAuthor("Codex"));
    assert(isAgentCommitAuthor("Amp"));
    assert(isAgentCommitAuthor("opencode"));
    assert(isAgentCommitAuthor("Crush"));
    assert(isAgentCommitAuthor("amazon-q-developer[bot]"));
    // Aider appends " (aider)" to the human name.
    assert(isAgentCommitAuthor("Petar Kirov (aider)"));
    assert(isAgentCommitAuthor("alice (Aider)"));    // case-insensitive suffix
    assert(!isAgentCommitAuthor("Petar Kirov"));
    assert(!isAgentCommitAuthor("aider"));           // bare suffix token is not a full name
    assert(!isAgentCommitAuthor(""));
    assert(!isAgentCommitAuthor("(aider)"));         // the pattern itself is not an author
}

@("agents.withoutAgentAuthors")
@safe pure nothrow
unittest
{
    auto filtered = withoutAgentAuthors([
        AuthorCount("Petar Kirov", 10),
        AuthorCount("Claude", 3),
        AuthorCount("Bob (aider)", 2),
        AuthorCount("GitHub Copilot", 1),
        AuthorCount("Alice", 4),
    ]);
    assert(filtered.length == 2);
    assert(filtered[0].name == "Petar Kirov" && filtered[0].commits == 10);
    assert(filtered[1].name == "Alice" && filtered[1].commits == 4);
}

@("agents.findAgent")
@safe unittest
{
    assert(findAgent("gemini").binary == "gemini");
    assert(findAgent("not-an-agent") is null);

    // Test alias lookup
    assert(findAgent("antigravity-cli").key == "agy");
}

@("agents.resolveBinary")
@safe unittest
{
    // `sh` is reliably on `$PATH` (see process_utils.isInPath); the sentinel
    // name never is — keeping the test independent of what tools are installed.
    enum absent = "sparkles-nonexistent-binary-xyzzy-123";

    // `binary` present → resolves to it directly.
    const direct = AgentSpec(key: "mock", binary: "sh");
    assert(resolveBinary(direct).value.binary == "sh");

    // `binary` absent but an alias is present → resolves to the alias.
    const viaAlias = AgentSpec(
        key: "mock2", binary: absent, aliases: [absent, "sh"]);
    assert(resolveBinary(viaAlias).value.binary == "sh");

    // No candidate on `$PATH` → a failure, not a null binary.
    const missing = AgentSpec(key: "mock3", binary: absent);
    assert(resolveBinary(missing).hasError);
}

@("agents.buildArgv")
@safe unittest
{
    // No placeholder: the prompt file is not named, it arrives on stdin.
    const claude = *findAgent("claude-code");
    assert(!namesPromptFile(claude));
    assert(buildArgv(claude, "/tmp/p.md") == ["claude", "-p"]);

    // A path flag takes the file's path…
    const goose = *findAgent("goose");
    assert(namesPromptFile(goose));
    assert(buildArgv(goose, "/tmp/p.md") == ["goose", "run", "-i", "/tmp/p.md"]);

    // …and a prompt-string-only agent takes a pointer at the same file.
    const agy = *findAgent("agy");
    assert(namesPromptFile(agy));
    assert(buildArgv(agy, "/tmp/p.md")
        == ["agy", "--print", "Read the file /tmp/p.md and follow the instructions in it exactly."]);
}

@("agents.runAgent.hugePromptTravelsAsAFile")
@safe unittest
{
    import std.array : replicate;

    // Over `MAX_ARG_STRLEN` (32 pages), the cap that used to E2BIG the spawn
    // with "Argument list too long" — both forms must carry it intact.
    const big = "y".replicate(32 * 4096 + 1);

    // Named in the argv: `cat <path>` prints the prompt file back.
    const named = AgentSpec(key: "mock-file", binary: "cat",
        flags: [promptPathPlaceholder]);
    auto viaFile = runAgent(named, big);
    assert(viaFile.hasValue);
    assert(viaFile.value == big);

    // On stdin: `cat` with no operand prints what it is fed.
    const piped = AgentSpec(key: "mock-stdin", binary: "cat");
    auto viaStdin = runAgent(piped, big);
    assert(viaStdin.hasValue);
    assert(viaStdin.value == big);
}

@("agents.runAgent.promptFileIsRemoved")
@safe unittest
{
    import std.algorithm.searching : canFind;
    import std.file : exists;
    import std.string : strip;

    // `readlink` on the path prints it back, so the test learns the path the
    // agent was handed — and can check it is gone once the run returns.
    const spec = AgentSpec(key: "mock-file", binary: "readlink",
        flags: ["-m", promptPathPlaceholder]);
    auto r = runAgent(spec, "prompt body");
    assert(r.hasValue);
    assert(r.value.canFind("sparkles-release-prompt-"));
    assert(!r.value.strip.exists);
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
    const agent = pre.value.forAgent;
    assert(agent.canFind("v0.4.0"));
    assert(agent.canFind("pre-1.0"));
    assert(agent.canFind("OLDEST FIRST"));
    assert(agent.canFind(`"pr":47`));
    assert(agent.canFind(`"remainderNote"`));
    // Two PR-atomic units (PR #47's commit, then the direct one), not 2 rows
    // of commits — and no SHA anywhere, since boundaries are unit indices.
    assert(agent.canFind("2 units of unreleased work (2 commits)"));
    assert(!agent.canFind("aaaaaaaaaaaa"));
    assert(agent.canFind(`"i":1,"pr":0`));

    // Toward the agent the JSON stays compact (token-efficient)…
    assert(agent.canFind("```json\n{\"segments\":"));
    assert(agent.canFind("```json\n{\"units\":"));

    // …while the artifact rendering pretty-prints it for human review.
    const artifact = pre.value.forArtifact;
    assert(artifact.canFind("\"pr\": 47"));
    assert(artifact.canFind("```json\n{\n"));

    // Both are valid markdown: two closed ```json fences each.
    import std.algorithm.searching : count;
    assert(agent.count("```") == 4);
    assert(artifact.count("```") == 4);

    auto post = buildSegmentationPrompt(rows, SemVer(major: 1, minor: 0, patch: 0));
    assert(post.hasValue);
    assert(!post.value.forAgent.canFind("pre-1.0"));
    assert(post.value.forAgent.canFind(`a breaking change means "major"`));
}

@("agents.buildSegmentationPrompt.subjectFenceCannotCloseTheBlock")
@system unittest
{
    import std.algorithm.searching : canFind, count;

    // A real subject from this repository's history: an unguarded ```json
    // fence would end at the subject, truncating the input the agent sees.
    const rows = [
        SegmentInput(sha: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", prNumber: 0,
            subject: "feat(ci): require ```[Output] for example output blocks"),
    ];

    auto pre = buildSegmentationPrompt(rows, SemVer(major: 0, minor: 4, patch: 0));
    assert(pre.hasValue);
    foreach (rendering; [pre.value.forAgent, pre.value.forArtifact])
    {
        // The input block is fenced with more backticks than the subject has…
        assert(rendering.canFind("````json\n"));
        // …and the whole subject survives inside it.
        assert(rendering.canFind("```[Output]"));
        // Four fence markers: two ``` around the schema, two ```` around the
        // input — the subject's own run is not one of them.
        assert(rendering.count("````") == 2);
    }
}

@("agents.capLogStat.truncatesAtLineBoundary")
@safe pure unittest
{
    import std.algorithm.searching : canFind, endsWith, startsWith;

    assert(capLogStat("short", 100) == "short");

    const big = "line one\nline two\nline three\n";
    const capped = capLogStat(big, 12);
    assert(capped.startsWith("line one\n"));
    assert(!capped.canFind("line two"));
    assert(capped.canFind("log truncated"));
}

@("agents.buildSegmentationRetryCoda")
@safe pure unittest
{
    import std.algorithm.searching : canFind;

    const coda = buildSegmentationRetryCoda("boundary `xyz` is unknown");
    assert(coda.canFind("boundary `xyz` is unknown"));
    assert(coda.canFind("ONLY the JSON object"));
}
