/++
The closed vocabulary of work a task node performs
([SPEC §5.1](../../../../../../docs/specs/ci/task-dag/SPEC.md)): a typed process
invocation, an in-process command handler, or — for graph and executor tests
— an inert action whose outcome the test driver declares.

An action is data. Nothing here spawns, runs, or dispatches; the executor owns
that. What this module does own is the dry-run rendering of an action, which
never prints a redacted value.
+/
module sparkles.build_primitives.task.action;

import core.time : Duration;
import std.range.primitives : put;
import std.sumtype : match, SumType;

import sparkles.base.text.case_style : CaseStyle;
import sparkles.base.text.wire_names : AnyFormat, WireCase;
import sparkles.base.text.writers : writeDuration, writeEnumMemberName;

/// One entry of a process action's environment delta.
struct EnvEntry
{
    string name;  ///
    string value; ///
    /// A secret: never written to an event, a log, or a dry run.
    bool redacted;
}

/// What a child process reads on standard input.
@WireCase(CaseStyle.kebabCase)
enum StdinPolicy
{
    /// An empty, closed stream. A task never inherits the command's stdin.
    empty,
}

/// Where a process action may write.
@WireCase(CaseStyle.kebabCase)
enum SandboxPolicy
{
    /// No private directory: pure readers and git queries.
    none,
    /// A private task directory holding its `DUB_HOME`, build root, spilled
    /// output, and coverage listings ([SPEC §11]).
    taskDirectory,
}

/// A child process, as data.
struct ProcessAction
{
    /// The program and its arguments; boundaries are preserved, never joined
    /// into a shell string.
    string[] argv;
    /// Variables added to (or replacing in) the inherited environment.
    EnvEntry[] envDelta;
    /// The working directory; `null` is the repository root.
    string cwd;
    StdinPolicy stdin;     ///
    Duration timeout;      /// `Duration.zero` is no timeout
    SandboxPolicy sandbox; ///
}

/// An in-process action: a typed command handler, named by a stable id the
/// executor resolves (`"plan:discover-packages"`), with its arguments.
struct InProcessAction
{
    string handler;     ///
    string[] arguments; ///
}

/// An action that does nothing; a test driver declares its outcome. The
/// `note` is what a dry run prints.
struct InertAction
{
    string note; ///
}

/// The closed action vocabulary.
alias TaskAction = SumType!(ProcessAction, InProcessAction, InertAction);

/**
Writes a one-line, redacted summary of `action` — what a dry run shows:
`run git -C repo status`, `call plan:discover-packages(a, b)`, `inert note`.

An argument containing a space or a quote is written double-quoted with
`\"` escapes, so argument boundaries stay visible. A redacted environment
value is written as `<redacted>`.
*/
void writeActionSummary(Writer)(ref Writer w, const ref TaskAction action)
{
    action.match!(
        (const ref ProcessAction p) {
            put(w, "run");
            foreach (entry; p.envDelta)
            {
                put(w, ' ');
                put(w, entry.name);
                put(w, '=');
                if (entry.redacted)
                    put(w, "<redacted>");
                else
                    writeArgument(w, entry.value);
            }
            foreach (arg; p.argv)
            {
                put(w, ' ');
                writeArgument(w, arg);
            }
            if (p.cwd.length)
            {
                put(w, " (in ");
                put(w, p.cwd);
                put(w, ')');
            }
            if (p.timeout > Duration.zero)
            {
                put(w, " (timeout ");
                writeDuration(w, p.timeout);
                put(w, ')');
            }
            if (p.sandbox != SandboxPolicy.none)
            {
                put(w, " (sandbox ");
                writeEnumMemberName!AnyFormat(w, p.sandbox);
                put(w, ')');
            }
        },
        (const ref InProcessAction c) {
            put(w, "call ");
            put(w, c.handler);
            put(w, '(');
            foreach (i, arg; c.arguments)
            {
                if (i)
                    put(w, ", ");
                writeArgument(w, arg);
            }
            put(w, ')');
        },
        (const ref InertAction a) {
            put(w, "inert");
            if (a.note.length)
            {
                put(w, ' ');
                put(w, a.note);
            }
        },
    );
}

// An argument, double-quoted when a space, quote, or emptiness would
// otherwise hide its boundaries.
private void writeArgument(Writer)(ref Writer w, scope const(char)[] arg)
{
    bool quote = arg.length == 0;
    foreach (c; arg)
        if (c == ' ' || c == '"' || c == '\t')
            quote = true;
    if (!quote)
        return put(w, arg);
    put(w, '"');
    foreach (c; arg)
    {
        if (c == '"' || c == '\\')
            put(w, '\\');
        char[1] one = c;
        put(w, one[]);
    }
    put(w, '"');
}

@("build_primitives.task.action.writeActionSummary.process")
@safe pure nothrow
unittest
{
    import core.time : seconds;
    import sparkles.base.buffer : checkWriter;

    const action = TaskAction(ProcessAction(
        argv: ["dub", "test", ":base", "--", "-i", "a b", ""],
        envDelta: [EnvEntry("DC", "ldc2"), EnvEntry("GH_TOKEN", "hunter2", redacted: true)],
        cwd: "libs/base",
        timeout: 90.seconds,
        sandbox: SandboxPolicy.taskDirectory,
    ));
    checkWriter!((ref b) => writeActionSummary(b, action))(
        `run DC=ldc2 GH_TOKEN=<redacted> dub test :base -- -i "a b" ""`
        ~ ` (in libs/base) (timeout 1.5m) (sandbox task-directory)`);
}

@("build_primitives.task.action.writeActionSummary.inProcessAndInert")
@safe pure nothrow
unittest
{
    import sparkles.base.buffer : checkWriter;

    const call = TaskAction(InProcessAction("plan:discover-packages", [`say "hi"`, "x"]));
    checkWriter!((ref b) => writeActionSummary(b, call))(
        `call plan:discover-packages("say \"hi\"", x)`);

    const inert = TaskAction(InertAction("fixture"));
    checkWriter!((ref b) => writeActionSummary(b, inert))("inert fixture");
    const bare = TaskAction(InertAction());
    checkWriter!((ref b) => writeActionSummary(b, bare))("inert");
}
