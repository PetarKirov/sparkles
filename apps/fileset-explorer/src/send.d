/**
Sending a fileset (`FXS3`–`FXS8`): what the Stats tab offers, asks, shows and
checks while a provider serves the fileset's collection to `sendme receive`.

A provider is a `BlobProvider`: the iroh bridge (`IrohProvider`, over
`sparkles:iroh-send`), or a scripted stand-in in tests. `Sending` is the
state the screen draws: idle, asking, running or unavailable, with the
snapshot of what was confirmed, so an edit of the query changes nothing that
is being sent (`FXS5`).
*/
module send;

import std.conv : text;

import sparkles.build_primitives.content_addressing.collection : CollectionFile;
import sparkles.iroh_send : IrohSend, loadIrohSend, SendFile, SendPhase, SendSession, SendState;

import evaluate : humanBytes, Outcome, Root;

/// Where the iroh bridge keeps its store while it sends; empty: the
/// system's temporary directory. Android sets it to the app's data.
string sendStoreParent;

/// What sends a fileset: started once with its files, polled, stopped.
interface BlobProvider
{
    /// Starts sending `files`.
    void start(in SendFile[] files);
    /// Where it is.
    SendState poll();
    /// Stops it; it is not polled again.
    void stop();
}

/// The iroh bridge as a provider.
final class IrohProvider : BlobProvider
{
    private IrohSend lib;
    private SendSession session;

    ///
    this(IrohSend lib) @safe
    {
        this.lib = lib;
    }

    ///
    void start(in SendFile[] files)
    {
        session = lib.start(files, sendStoreParent);
    }

    ///
    SendState poll() => session.live ? session.poll() : SendState(SendPhase.stopped);

    ///
    void stop()
    {
        session.stop();
    }
}

/**
What the platform does to a freshly loaded bridge before it sends; it says
why it could not, or returns null. Android hands it the app's JVM and
context (`FXS9`).
*/
string function(ref IrohSend) prepareIrohSend;

/// Opens the iroh bridge; `null` and the reason when it cannot be loaded.
BlobProvider openIrohProvider(out string why)
{
    auto lib = loadIrohSend();
    if (lib.hasError)
    {
        why = lib.error;
        return null;
    }
    if (prepareIrohSend !is null)
        if (const problem = prepareIrohSend(lib.value))
        {
            why = problem;
            return null;
        }
    return new IrohProvider(lib.value);
}

/// Where Send is.
enum SendStage : ubyte
{
    idle,        /// the names, and the offer to send
    asking,      /// what would be sent, waiting for a yes (`FXS3`)
    running,     /// the provider runs (`FXS4`)
    unavailable, /// a reason it cannot (`FXS8`), or why the last send ended
}

/// What was confirmed: the files, the query, the collection's name.
struct SendSnapshot
{
    SendFile[] files;   ///
    string query;       /// the query that selected them
    string collection;  /// the collection the explorer named, in hex
    ulong bytes;        ///
    size_t links;       /// links left out
}

/**
The Send state the Stats tab draws, and its steps: `ask`, `confirm`,
`cancel`, `tick` and `stop`.
*/
struct Sending
{
    SendStage stage;     ///
    SendSnapshot sent;   /// what is asked about, or being sent
    SendState state;     /// the provider's, as last polled
    string note;         /// why sending is unavailable, or ended
    BlobProvider provider; ///
    /// Makes the provider on the first send; the iroh bridge by default.
    BlobProvider delegate(out string why) makeProvider;

    /// Whether a provider is running.
    bool running() const @safe pure nothrow @nogc => stage == SendStage.running;

    /// Asks to send what `o` names beneath `root` (`FXS3`); nothing starts.
    void ask(in Outcome o, in Root root, string query)
    {
        import std.path : absolutePath, buildNormalizedPath, buildPath;

        if (root.inMemory)
            return unavailable("a tutorial tree is held in memory: there are no files to send");
        if (!o.hasIds)
            return unavailable("the names are not computed yet");
        if (o.collectionError.length)
            return unavailable(o.collectionError);
        SendSnapshot s;
        const base = buildNormalizedPath(absolutePath(root.dir));
        foreach (ref f; o.collectionFiles)
        {
            s.files ~= SendFile(o.label ~ "/" ~ f.path, buildPath(base, f.path));
            s.bytes += f.size;
        }
        s.query = query;
        s.collection = o.collection;
        s.links = o.collectionLinks;
        sent = s;
        stage = SendStage.asking;
    }

    /// Starts the provider on what was asked about.
    void confirm()
    {
        if (stage != SendStage.asking)
            return;
        if (provider is null)
        {
            string why;
            provider = makeProvider !is null ? makeProvider(why) : openIrohProvider(why);
            if (provider is null)
                return unavailable("sending is unavailable: " ~ why);
        }
        state = SendState.init;
        state.filesTotal = sent.files.length;
        provider.start(sent.files);
        stage = SendStage.running;
    }

    /// Returns to the names without sending.
    void cancel() @safe pure nothrow
    {
        if (stage != SendStage.running)
            stage = SendStage.idle;
    }

    /// Reads the provider, and stops it on a failure or on a collection
    /// that is not the one the explorer named (`FXS6`).
    void tick()
    {
        if (stage != SendStage.running)
            return;
        state = provider.poll();
        if (state.phase == SendPhase.failed)
        {
            const why = state.error;
            stop();
            return unavailable("the send failed: " ~ why);
        }
        if (state.hasHash)
        {
            import sparkles.build_primitives.content_addressing.git : toHex;

            const theirs = toHex(state.hash)[].idup;
            if (theirs != sent.collection)
            {
                stop();
                return unavailable(text("the provider named the collection ", theirs, ", not ",
                    sent.collection, ": stopped"));
            }
        }
    }

    /// Stops the provider and returns to the names.
    void stop()
    {
        if (stage == SendStage.running)
            provider.stop();
        stage = SendStage.idle;
    }

    /// The command a receiver runs, once serving.
    string receiveCommand() const @safe pure
        => state.phase == SendPhase.serving && state.ticket.length ? "sendme receive " ~ state.ticket : null;

    /// The phase as the Stats tab says it.
    string phaseText() const @safe
    {
        final switch (state.phase)
        {
            case SendPhase.importing:
                return text("importing ", state.filesDone, " of ", sent.files.length, " files, ",
                    humanBytes(state.bytesDone), " of ", humanBytes(sent.bytes));
            case SendPhase.online: return "going online";
            case SendPhase.serving: return "serving";
            case SendPhase.failed: return "failed";
            case SendPhase.stopped: return "stopped";
        }
    }

    private void unavailable(string why) @safe pure nothrow
    {
        note = why;
        stage = SendStage.unavailable;
    }
}
