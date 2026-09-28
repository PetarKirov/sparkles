/**
The on-device test oracle (docs/specs/terminal/android.md, `NOD14`).

UI automation reads an Android app through its accessibility tree, and a
NativeActivity drawing into a GL surface has none: nothing on screen is
readable text. So a test asks the app directly — it creates the flag file
`<dir>/screen-dump`, and from then on the app keeps `<dir>/screen.txt` equal
to the terminal's text, and `<dir>/keys.txt` to the extra-keys row's labels.
Without the flag the oracle costs one `stat` a second.

Writes are atomic (a temporary file, then `rename`), so a reader polling the
file never sees a torn one.
*/
module screen_oracle;

/// The oracle's per-frame driver; `View` is anything with `string screenText()`.
struct ScreenOracle
{
    /// The oracle's directory (`SessionPaths.debugDir`); empty disables it.
    string dir;

    /// Frames between checks for the flag file (~1 s at 60 fps).
    enum checkInterval = 60;

    private int countdown;
    private bool enabled;
    private string last;
    private string lastKeys;

    /// Call once per frame, after the terminal has drained its pty. `keys`
    /// is the extra-keys row's labels, one row per line — the chrome a test
    /// cannot see in the terminal's text (`keys.txt`).
    void frame(View)(ref View view, string keys = null)
    {
        import std.file : exists;
        import std.path : buildPath;

        if (dir.length == 0)
            return;
        if (countdown-- <= 0)
        {
            countdown = checkInterval;
            try
                enabled = buildPath(dir, "screen-dump").exists;
            catch (Exception)
                enabled = false;
        }
        if (!enabled)
            return;

        if (keys != lastKeys)
        {
            lastKeys = keys;
            write("keys.txt", keys);
        }
        const text = view.screenText();
        if (text is null || text == last)
            return;
        last = text;
        write("screen.txt", text);
    }

    private void write(string name, string text)
    {
        import std.file : rename, write;
        import std.path : buildPath;

        const tmp = buildPath(dir, name ~ ".tmp");
        try
        {
            write(tmp, text);
            rename(tmp, buildPath(dir, name));
        }
        catch (Exception)
        {
            // A full disk or a vanished directory: the oracle is a test aid,
            // and the terminal must not stop over it.
        }
    }
}

@("screen_oracle.writesOnlyWhenAskedAndOnlyOnChange")
@system unittest
{
    import std.file : exists, mkdirRecurse, readText, remove, rmdirRecurse,
        tempDir, write;
    import std.path : buildPath;
    import std.process : thisProcessID;
    import std.conv : text;

    static struct FakeView
    {
        string content;
        string screenText() => content;
    }

    const dir = buildPath(tempDir, text("screen-oracle-", thisProcessID));
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    const outFile = buildPath(dir, "screen.txt");

    auto view = FakeView("$ ");
    ScreenOracle o = ScreenOracle(dir);
    o.frame(view);
    assert(!outFile.exists, "no flag, no file");

    write(buildPath(dir, "screen-dump"), "");
    o.countdown = 0; // the next frame re-checks the flag
    o.frame(view);
    assert(readText(outFile) == "$ ");

    remove(outFile);
    o.frame(view);
    assert(!outFile.exists, "unchanged text is not rewritten");

    view.content = "$ echo hi\nhi\n$ ";
    o.frame(view, "ESC TAB\nCTRL");
    assert(readText(outFile) == "$ echo hi\nhi\n$ ");
    assert(readText(buildPath(dir, "keys.txt")) == "ESC TAB\nCTRL");
}
