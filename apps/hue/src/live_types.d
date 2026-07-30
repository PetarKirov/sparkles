// Live D types (`PRJ12`-`PRJ16`): the viewer half of the dmd-lsp project
// milestone. Opening a `.d` file starts a `twoslash-extract --dub --serve`
// oracle beside the viewer; its first stdout line is the LAZY twoslash payload
// (hover nodes as bare spans — every hover span gets its discoverability
// underline immediately), and each later line answers a `{"tip": <node>}`
// request with that node's resolved type text, ddoc body and tags.
//
// The constraint this module exists to honor is `PRJ13`: DMD-as-a-library is
// one analysis per process (`COR2`/`EXT2`) and hue is long-lived, so hue must
// never link `sparkles:dmd-lsp` — it SPAWNS the extractor and speaks JSON
// lines to it. Nothing here imports the analyzer.
//
// The session is non-blocking by construction: `poll` drains whatever the
// child has produced so far and returns, so a 60 fps GUI frame and an
// event-driven TUI tick can both call it without ever waiting on analysis.
module live_types;

version (Posix):

import std.json : JSONType, JSONValue, parseJSON;

import sparkles.core_cli.process_utils : isInPath, ResidentProcess;
import sparkles.twoslash : parseTwoslash, TwoslashReturn;

/// One resolved hover: the oracle's answer to a `{"tip": index}` request.
struct TipAnswer
{
    size_t index;    /// index into `TwoslashReturn.nodes`
    string text;     /// the type signature (`(kind) code`)
    string docs;     /// the ddoc body, if any
    string[][] tags; /// `[name, text?]` pairs
}

/// What one non-payload stdout line from the oracle turned out to be.
enum ServeLineKind : ubyte
{
    answer,  /// a resolved tip (`{"node": …, "text": …}`)
    error,   /// the oracle's own `{"error": …}` reply
    invalid, /// not JSON, or JSON of an unexpected shape
}

/// The classification of one such line (the pure half of `poll`).
struct ServeLine
{
    ServeLineKind kind;
    TipAnswer answer; /// `kind == answer`
    string message;   /// `kind != answer`: the reason to report
}

/// The request line for a node's tip — the wire format `--serve` reads.
string tipRequest(size_t nodeIndex) @safe
{
    import std.conv : text;

    return text(`{"tip": `, nodeIndex, `}`);
}

/**
Classifies one line of the oracle's answer stream. Split out from the session
so the wire contract is testable without a child process: an answer object, the
oracle's own error reply, and anything unexpected are three distinct outcomes,
and none of them throws.
*/
ServeLine classifyServeLine(scope const(char)[] line) @safe
{
    JSONValue root;
    try
        root = parseJSON(line);
    catch (Exception e)
        return ServeLine(ServeLineKind.invalid, message: "invalid JSON: " ~ e.msg);

    if (root.type != JSONType.object)
        return ServeLine(ServeLineKind.invalid, message: "expected a JSON object");

    if (auto err = "error" in root)
        return ServeLine(ServeLineKind.error,
            message: err.type == JSONType.string ? err.str : "unknown error");

    auto node = "node" in root;
    if (node is null || node.type != JSONType.integer || node.integer < 0)
        return ServeLine(ServeLineKind.invalid, message: "no `node` index in the reply");

    TipAnswer a = { index: cast(size_t) node.integer };
    if (auto t = "text" in root)
        if (t.type == JSONType.string)
            a.text = t.str;
    if (auto d = "docs" in root)
        if (d.type == JSONType.string)
            a.docs = d.str;
    if (auto tg = "tags" in root)
        if (tg.type == JSONType.array)
            foreach (pair; tg.arrayNoRef)
            {
                if (pair.type != JSONType.array)
                    continue;
                string[] parts;
                foreach (p; pair.arrayNoRef)
                    if (p.type == JSONType.string)
                        parts ~= p.str;
                if (parts.length)
                    a.tags ~= parts;
            }
    return ServeLine(ServeLineKind.answer, answer: a);
}

/**
Writes a resolved tip into its node, turning a lazy hover span into a
renderable popup. Returns `false` for an out-of-range index (a stale answer
for a document that has since been replaced).

No relayout follows: the document view draws hover spans, not their text, so
the next popup — GUI or TUI — simply reads the filled-in node.
*/
bool applyTip(ref TwoslashReturn tw, TipAnswer a) @safe pure nothrow
{
    if (a.index >= tw.nodes.length)
        return false;
    tw.nodes[a.index].text = a.text;
    tw.nodes[a.index].docs = a.docs;
    tw.nodes[a.index].tags = a.tags;
    return true;
}

/// The extractor binary hue spawns: `$SPARKLES_TWOSLASH_EXTRACT` wins (a build
/// tree's copy), else `twoslash-extract` from `$PATH`; empty when neither is
/// available — live types are then simply off.
string liveTypesBinary() @safe
{
    import std.file : exists;
    import std.process : environment;

    const override_ = environment.get("SPARKLES_TWOSLASH_EXTRACT", "");
    if (override_.length)
        return override_.exists ? override_ : "";
    return isInPath("twoslash-extract") ? "twoslash-extract" : "";
}

/**
One live-types oracle: a `twoslash-extract --dub --serve` child for one open
file, plus the payload and tip answers it has produced so far.

Non-copyable and owned by pointer (`start` returns one): it holds a
`ResidentProcess`, which kills the child when it dies.
*/
struct LiveTypesSession
{
    /// Where the session is in the `--serve` protocol.
    enum State : ubyte
    {
        awaitingPayload, /// spawned; stdout line 1 (the lazy payload) pending
        serving,         /// payload delivered; tip requests are answered
        failed,          /// the child died or spoke nonsense — no more requests
    }

    private ResidentProcess _proc;
    private string _samplePath = "<file.d>"; // only for the failure notice
    private State _state;
    private string _reason;
    private TwoslashReturn _payload;
    private bool _payloadReady;
    private bool[size_t] _requested; // in-flight + answered tips (dedupe)
    private TipAnswer[] _answers;
    private bool _stopped;

    @disable this(this);

    /**
    Starts the oracle for `filePath`, or returns `null` with `reason` set (no
    binary, or the spawn failed) — the caller shows that once and carries on
    without live types (`PRJ15`: visible, never fatal).

    `silenceChildStderr` points the child's stderr at `/dev/null`: an alt-screen
    TUI must not have `dub describe` or an analyzer warning scribbled across its
    frame. The GUI leaves it inherited, where the console is the right place
    for those.
    */
    static LiveTypesSession* start(string filePath, out string reason,
        bool silenceChildStderr = false) @system
    {
        const bin = liveTypesBinary();
        if (!bin.length)
        {
            reason = "twoslash-extract not found on PATH " ~
                "(build it, or set $SPARKLES_TWOSLASH_EXTRACT)";
            return null;
        }
        // `--quiet` is load-bearing: without it `--dub` writes its project
        // summary to STDOUT, ahead of the payload, and line 1 is no longer JSON.
        auto s = startWith([bin, filePath, "--dub", "--serve", "--quiet"],
            reason, silenceChildStderr);
        if (s !is null)
            s._samplePath = filePath;
        return s;
    }

    /// ditto — with an explicit command line (the seam a test drives a scripted
    /// fake oracle through).
    static LiveTypesSession* startWith(const(string)[] argv, out string reason,
        bool silenceChildStderr = false) @system
    {
        auto s = new LiveTypesSession;
        try
        {
            auto hush = StderrSilencer(silenceChildStderr);
            s._proc = ResidentProcess.spawn(argv);
        }
        catch (Exception e)
        {
            reason = "could not start " ~ (argv.length ? argv[0] : "the oracle")
                ~ ": " ~ e.msg;
            return null;
        }
        return s;
    }

    /// Drains whatever the child has written so far: the payload, then any tip
    /// answers. Never blocks, never throws — a dead or babbling child ends the
    /// session in `State.failed` with a one-line `reason`.
    void poll() @system
    {
        if (_stopped || _state == State.failed)
            return;
        for (;;)
        {
            const line = _proc.tryReadLine();
            if (line is null)
                break;
            if (_state == State.awaitingPayload)
                takeFirstLine(line);
            else
                takeAnswerLine(line);
            if (_state == State.failed)
                return;
        }
        if (!_proc.alive)
        {
            import std.conv : text;

            // The no-payload case is where a misconfigured environment lands
            // (no druntime sources ⇒ the extractor refuses before analyzing).
            // It says why on *its* stderr, which the alt screen has pointed at
            // /dev/null, so name the command that will repeat the reason.
            fail(_payloadReady
                ? text("twoslash-extract exited (status ", _proc.status, ")")
                : text("twoslash-extract exited before producing a payload ",
                    "(status ", _proc.status, ") — run `twoslash-extract ",
                    _samplePath, " --dub --serve` to see why"));
        }
    }

    private void takeFirstLine(string line) @system
    {
        auto res = parseTwoslash(line);
        if (res.hasError)
        {
            fail("twoslash-extract: " ~ res.error.toString());
            return;
        }
        _payload = res.value;
        _payloadReady = true;
        _state = State.serving;
    }

    private void takeAnswerLine(string line) @system
    {
        auto cl = classifyServeLine(line);
        final switch (cl.kind) with (ServeLineKind)
        {
            case answer:
                _answers ~= cl.answer;
                break;
            case error:
            case invalid:
                // A bad reply is per-request, not fatal: the oracle keeps
                // serving the other nodes. Remember the reason for the notice.
                _reason = "twoslash-extract: " ~ cl.message;
                break;
        }
    }

    /// Asks for one node's tip, at most once per node per session. A no-op
    /// before the payload lands, after a failure, and for an already-requested
    /// node — callers may (and do) call it every frame the pointer rests on a
    /// lazy span.
    void requestTip(size_t nodeIndex) @system
    {
        if (_stopped || _state != State.serving || (nodeIndex in _requested))
            return;
        _requested[nodeIndex] = true;
        try
            _proc.sendLine(tipRequest(nodeIndex));
        catch (Exception e)
            fail("twoslash-extract: " ~ e.msg);
    }

    /// The payload is in and has not been handed over yet.
    bool payloadReady() const @safe pure nothrow @nogc => _payloadReady;

    /// Hands the payload to the viewer (once); the session keeps serving tips
    /// against the same node indices.
    TwoslashReturn takePayload() @safe pure nothrow
    {
        _payloadReady = false;
        return _payload;
    }

    /// The tip answers that arrived since the last call (cleared by the take).
    TipAnswer[] takeAnswers() @safe pure nothrow
    {
        auto a = _answers;
        _answers = null;
        return a;
    }

    /// The session is alive and worth polling (the loop ticks while true).
    bool active() const @safe pure nothrow @nogc
        => !_stopped && _state != State.failed;

    /// ditto
    bool failed() const @safe pure nothrow @nogc => _state == State.failed;

    /// The one-line reason for a failure (or the last bad reply), if any.
    string reason() const @safe pure nothrow @nogc => _reason;

    /// Ends the session: stdin EOF (the oracle's documented shutdown), then
    /// the reap. Idempotent; the destructor also kills an unstopped child.
    void shutdown() @system
    {
        if (_stopped)
            return;
        _stopped = true;
        _proc.closeInput();
        _proc.terminate();
    }

    private void fail(string why) @safe pure nothrow @nogc
    {
        _state = State.failed;
        _reason = why;
    }
}

/**
Points fd 2 at `/dev/null` for the duration of a spawn, so the child inherits a
silent stderr while the parent keeps its own. Disengaged (and fd 2 restored)
the moment the scope ends — the window is the `spawn` call itself.

The alternative would be a knob on `ResidentProcess`; this keeps the terminal
concern where it belongs (hue's alt screen) instead of in the process utility.
*/
private struct StderrSilencer
{
    private int _saved = -1;

    @disable this(this);

    this(bool engage) @trusted
    {
        import core.sys.posix.fcntl : O_WRONLY, open;
        import core.sys.posix.unistd : close, dup, dup2, STDERR_FILENO;

        if (!engage)
            return;
        const devNull = open("/dev/null", O_WRONLY);
        if (devNull < 0)
            return;
        _saved = dup(STDERR_FILENO);
        dup2(devNull, STDERR_FILENO);
        close(devNull);
    }

    ~this() @trusted
    {
        import core.sys.posix.unistd : close, dup2, STDERR_FILENO;

        if (_saved < 0)
            return;
        dup2(_saved, STDERR_FILENO);
        close(_saved);
        _saved = -1;
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

@("live_types.classifyServeLine.answerErrorAndGarbage")
@safe unittest
{
    const ok = classifyServeLine(
        `{"node": 3, "text": "(variable) int x", "docs": "the doc", ` ~
        `"tags": [["param", "x - a value"], ["returns"]]}`);
    assert(ok.kind == ServeLineKind.answer);
    assert(ok.answer.index == 3);
    assert(ok.answer.text == "(variable) int x");
    assert(ok.answer.docs == "the doc");
    assert(ok.answer.tags == [["param", "x - a value"], ["returns"]]);

    // A node with nothing to say is still an answer (an empty popup, not a
    // repeated request): `text`/`docs`/`tags` are all optional.
    const bare = classifyServeLine(`{"node": 0}`);
    assert(bare.kind == ServeLineKind.answer && bare.answer.index == 0);
    assert(!bare.answer.text.length && !bare.answer.tags.length);

    const err = classifyServeLine(`{"error": "expected {\"tip\": <nodeIndex>}"}`);
    assert(err.kind == ServeLineKind.error);
    assert(err.message == `expected {"tip": <nodeIndex>}`);

    assert(classifyServeLine("not json at all").kind == ServeLineKind.invalid);
    assert(classifyServeLine("[1, 2]").kind == ServeLineKind.invalid);
    assert(classifyServeLine(`{"text": "no index"}`).kind == ServeLineKind.invalid);
}

@("live_types.tipRequest.wireFormat")
@safe unittest
{
    assert(tipRequest(0) == `{"tip": 0}`);
    assert(tipRequest(42) == `{"tip": 42}`);
    // The oracle parses what we emit — the round trip the protocol rests on.
    const req = parseJSON(tipRequest(7));
    assert(req["tip"].integer == 7);
}

@("live_types.applyTip.fillsLazyNodeAndIgnoresStale")
@safe unittest
{
    import sparkles.twoslash.protocol : Node, NodeType;

    TwoslashReturn tw = {
        code: "int x;",
        nodes: [Node(type: NodeType.hover, start: 4, length: 1)],
    };
    assert(!tw.nodes[0].text.length, "a lazy span starts empty");

    assert(applyTip(tw, TipAnswer(0, "(variable) int x", "docs",
        [["param", "p"]])));
    assert(tw.nodes[0].text == "(variable) int x");
    assert(tw.nodes[0].docs == "docs");
    assert(tw.nodes[0].tags == [["param", "p"]]);

    // An answer for a document that has since been replaced is dropped.
    assert(!applyTip(tw, TipAnswer(9, "stale")));
}

@("live_types.session.scriptedOracleEndToEnd")
@system unittest
{
    import core.thread : Thread;
    import core.time : msecs;

    import sparkles.test_runner.skip : skipTest;
    import sparkles.twoslash.protocol : NodeType;

    if (!isInPath("sh"))
        skipTest("no `sh` for the scripted oracle");

    // A fake `--serve` oracle with the same wire behavior as the real one:
    // the lazy payload on line 1, then one answer per request line, exiting on
    // stdin EOF. Exercises the whole session state machine — spawn → payload →
    // request → answer → shutdown — without a DMD analysis.
    enum payload = `{"code":"int x;","offsetEncoding":"utf-8",` ~
        `"language":"d","nodes":[{"type":"hover","start":4,"length":1,` ~
        `"line":0,"character":4}]}`;
    enum script = `printf '%s\n' '` ~ payload ~ `'; ` ~
        `while IFS= read -r line; do ` ~
        `printf '%s\n' '{"node":0,"text":"(variable) int x","docs":"","tags":[]}'; ` ~
        `done`;

    string reason;
    auto s = LiveTypesSession.startWith(["sh", "-c", script], reason);
    assert(s !is null, reason);
    scope (exit) s.shutdown();

    bool waitFor(scope bool delegate() @system done)
    {
        foreach (_; 0 .. 400)
        {
            s.poll();
            if (done())
                return true;
            Thread.sleep(5.msecs);
        }
        return false;
    }

    assert(waitFor(() => s.payloadReady), "no payload: " ~ s.reason);
    auto tw = s.takePayload();
    assert(tw.code == "int x;" && tw.nodes.length == 1);
    assert(tw.nodes[0].type == NodeType.hover);
    assert(!tw.nodes[0].text.length, "the payload is lazy — the span has no text");

    s.requestTip(0);
    s.requestTip(0); // deduped: a second request would desync the answer stream
    assert(waitFor(() => s.takeAnswersPending), "no answer: " ~ s.reason);
    auto answers = s.takeAnswers();
    assert(answers.length == 1, "exactly one answer for a deduped request");
    assert(applyTip(tw, answers[0]));
    assert(tw.nodes[0].text == "(variable) int x");
    assert(s.active && !s.failed);
}

// Test-only peek: whether `takeAnswers` would return anything (the wait
// predicate above must not consume the answers it is waiting for).
private bool takeAnswersPending(scope LiveTypesSession* s) @safe pure nothrow @nogc
    => s._answers.length != 0;

@("live_types.session.deadOracleFailsWithAReason")
@system unittest
{
    import core.thread : Thread;
    import core.time : msecs;

    import sparkles.test_runner.skip : skipTest;

    if (!isInPath("sh"))
        skipTest("no `sh` for the scripted oracle");

    // A child that dies without a payload (the `--dub` failure shape) must end
    // the session with a reason, not hang the viewer (`PRJ15`).
    string reason;
    auto s = LiveTypesSession.startWith(["sh", "-c", "exit 3"], reason);
    assert(s !is null, reason);
    scope (exit) s.shutdown();

    foreach (_; 0 .. 400)
    {
        s.poll();
        if (s.failed)
            break;
        Thread.sleep(5.msecs);
    }
    assert(s.failed, "a dead oracle must fail the session");
    assert(!s.active && s.reason.length, s.reason);
    assert(!s.payloadReady);
    s.requestTip(0); // a request after the failure is a no-op, not a crash
}

@("live_types.session.realExtractorAnswersATip")
@system unittest
{
    import core.thread : Thread;
    import core.time : msecs;
    import std.file : exists;
    import std.path : buildNormalizedPath, dirName;
    import std.process : environment;

    import sparkles.test_runner.skip : skipTest;
    import sparkles.twoslash.protocol : NodeType;

    // Env-gated (`SPARKLES_TWOSLASH_EXTRACT` + the druntime/phobos import path
    // the analyzer needs): the one test that drives the REAL oracle end to end.
    //   dub build :twoslash-extract
    //   export SPARKLES_TWOSLASH_EXTRACT=$PWD/apps/twoslash-extract/build/twoslash-extract
    if (!liveTypesBinary().length)
        skipTest("no twoslash-extract (set $SPARKLES_TWOSLASH_EXTRACT)");
    if (!environment.get("SPARKLES_DMD_IMPORT_PATH", "").length)
        skipTest("SPARKLES_DMD_IMPORT_PATH not set (enter `nix develop`)");

    // A small, dependency-light module of this repo, resolved from this
    // source file so the test does not depend on the working directory.
    const repo = buildNormalizedPath(dirName(__FILE_FULL_PATH__), "../../..");
    const target = buildNormalizedPath(repo,
        "libs/base/src/sparkles/base/text/lineindex.d");
    if (!target.exists)
        skipTest("target not found: " ~ target);

    string reason;
    auto s = LiveTypesSession.start(target, reason);
    assert(s !is null, reason);
    scope (exit) s.shutdown();

    // A real analysis is seconds, not milliseconds (`PRJ9`): poll for it the
    // way the viewer does, and skip rather than fail if the machine is slow.
    bool waitFor(scope bool delegate() @system done, int seconds)
    {
        foreach (_; 0 .. seconds * 100)
        {
            s.poll();
            if (done())
                return true;
            if (s.failed)
                return false;
            Thread.sleep(10.msecs);
        }
        return false;
    }

    if (!waitFor(() => s.payloadReady, 120))
        skipTest(s.failed ? s.reason : "no payload within 120 s");
    auto tw = s.takePayload();
    assert(tw.code.length, "the payload carries the file's source");
    assert(tw.effectiveLanguage == "d");

    size_t lazyHover = size_t.max;
    foreach (i, ref const n; tw.nodes)
        if (n.type == NodeType.hover && !n.text.length)
        {
            lazyHover = i;
            break;
        }
    assert(lazyHover != size_t.max, "a lazy payload has unresolved hover spans");

    s.requestTip(lazyHover);
    if (!waitFor(() => s.takeAnswersPending, 30))
        skipTest(s.failed ? s.reason : "no tip answer within 30 s");
    auto answers = s.takeAnswers();
    assert(answers.length == 1 && answers[0].index == lazyHover);
    assert(applyTip(tw, answers[0]));
    assert(tw.nodes[lazyHover].text.length, "the oracle resolved the hover");
}
