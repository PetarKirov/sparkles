/++
`spk-dub-manifest`: the dub recipe schema for Nix's `builtins.wasm`
(docs/specs/wired/wasm/SPEC.md §2), built for `wasm32-unknown-wasip1` by the
`wasm` configuration; and, natively (`oracle`), the same answers printed as
JSON for the Nix check that compares the two (WW10).

In the module the evaluator runs `_start` with the argument's `ValueId` in
`argv[1]`, and the answer leaves through `return_to_nix`. The oracle takes
a root directory and repository-relative paths, or `--fixtures FILE` (a
JSON list of `{ name, text }`), and prints a JSON object
mapping each name to the answer for its text.
+/
module app;

import sparkles.dub_manifest_nix.convert : respond;

version (WASI)
{
    import sparkles.dub_manifest_nix.wasm_host : WasmHost, fail, returnToNix;

    // Each call is a fresh instance whose memory is dropped when it returns,
    // so a collection is wasted work: the manual GC never runs one (WW6).
    extern (C) __gshared string[] rt_options = ["gcopt=gc:manual"];

    int main(string[] args) @safe
    {
        import std.conv : ConvException, to;

        uint argument;
        try
            argument = args.length == 2 ? args[1].to!uint : 0;
        catch (ConvException)
            argument = 0;
        if (argument == 0)
            fail("spk-dub-manifest: expected the argument's ValueId in argv[1]");

        WasmHost host;
        const answer = respond(host, argument);
        if (answer.fault.length)
            fail("spk-dub-manifest: " ~ answer.fault);
        returnToNix(answer.value);
    }
}
else
{
    import sparkles.dub_manifest_nix.tree_host : TreeHost;

    int main(string[] args) @safe
    {
        import std.file : readText;
        import std.json : parseJSON;
        import std.path : buildPath;
        import std.stdio : write;

        if (args.length < 2)
        {
            write("usage: spk-dub-manifest-oracle ROOT [PATH…] | --fixtures FILE\n");
            return 2;
        }
        // Each input as (name, text): repository-relative paths read under
        // ROOT, or the `{ name, text }` entries of a fixtures file.
        string[2][] inputs;
        if (args[1] == "--fixtures" && args.length == 3)
            // `JSONValue.array` is `@system` only because it hands out a slice of
            // the value's own storage, which nothing here keeps.
            foreach (entry; (() @trusted => parseJSON(readText(args[2])).array)())
                inputs ~= [entry["name"].str, entry["text"].str];
        else
            foreach (path; args[2 .. $])
                inputs ~= [path, readText(args[1].buildPath(path))];

        TreeHost host;
        const(char)[][2] names = ["text", "name"];
        write('{');
        foreach (i, input; inputs)
        {
            TreeHost.Value[2] values = [host.string_(input[1]), host.string_(input[0])];
            const answer = respond(host, host.attrs(names[], values[]));
            assert(answer.fault is null, answer.fault);
            write(i ? "," : "", host.json(host.string_(input[0])), ":", host.json(answer.value));
        }
        write("}\n");
        return 0;
    }
}
