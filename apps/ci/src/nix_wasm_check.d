/++
`--check-nix-wasm`: the dub recipe module for Nix's `builtins.wasm`
(docs/specs/wired/wasm) checked on an evaluator that has the builtin.

Two Nix expressions in `libs/dub-manifest/nix-wasm` do the comparing, and
this mode runs them and judges their results:

$(UL
    $(LI `agreement.nix` (WW2): the module's answer for every tracked
        `dub.sdl` and `dub.json` and for the failure fixtures, against the
        native oracle's (`dub-manifest-nix-answers`);)
    $(LI `facts-agreement.nix` (WW10): the recipe table's facts from the
        module against the regular-expression reader's, for every recipe the
        root declares and for seeded fixtures on which the older reader is
        wrong.)
)

With `--nix-wasm-pinned`, both run again with the pinned module, so a change
the pin would reject cannot pass without moving it (D2). An evaluator without
the builtin fails the mode: a check that did not run is not a pass.
+/
module nix_wasm_check;

import std.json : JSONType, JSONValue, parseJSON;

/// What one Nix expression reported.
struct Verdict
{
    string what; /// which check, for the report
    bool ran; /// whether the expression evaluated
    string failure; /// why it fails, or null
    long checked; /// how many inputs it compared
}

/// Judges `agreement.nix`'s result: nothing mismatched, something compared.
Verdict judgeAgreement(string what, const JSONValue result) @safe
{
    auto v = Verdict(what, true);
    v.checked = result["checked"].integer;
    const mismatches = result["mismatches"].arrayNoRef;
    if (mismatches.length)
        v.failure = "answers differ for " ~ names(mismatches);
    else if (v.checked == 0)
        v.failure = "compared nothing";
    return v;
}

/// Judges `facts-agreement.nix`'s result: as `judgeAgreement`, and every
/// seeded fixture caught the older reader.
Verdict judgeFacts(string what, const JSONValue result) @safe
{
    auto v = judgeAgreement(what, result);
    if (v.failure is null)
    {
        const fixtures = result["fixtures"].arrayNoRef, caught = result["legacyCaught"].arrayNoRef;
        if (caught.length != fixtures.length)
            v.failure = "the seeded fixtures did not all catch the older reader: caught "
                ~ names(caught) ~ " of " ~ names(fixtures);
    }
    return v;
}

private string names(const(JSONValue)[] values) @safe
{
    string s;
    foreach (i, n; values)
        s ~= (i ? ", " : "") ~ n.str;
    return s.length ? s : "none";
}

///
@("nix_wasm_check.judge")
@safe unittest
{
    assert(judgeAgreement("a", parseJSON(`{"checked": 3, "mismatches": []}`)).failure is null);
    assert(judgeAgreement("a", parseJSON(`{"checked": 0, "mismatches": []}`)).failure == "compared nothing");
    assert(judgeAgreement("a", parseJSON(`{"checked": 3, "mismatches": ["x/dub.sdl"]}`)).failure
        == "answers differ for x/dub.sdl");
    const facts = `{"checked": 3, "mismatches": [], "fixtures": ["f", "g"], "legacyCaught": ["f"]}`;
    assert(judgeFacts("b", parseJSON(facts)).failure
        == "the seeded fixtures did not all catch the older reader: caught f of f, g");
}

/// Runs the checks with `nix` (an evaluator with `builtins.wasm`) from the
/// checkout at `root`; returns the process status.
int runCheckNixWasm(string root, string nix, string module_, string answers, string pinned) @system
{
    import std.stdio : stderr, writeln;

    if (!module_.length || !answers.length)
    {
        stderr.writeln("--check-nix-wasm needs --nix-wasm-module and --nix-wasm-answers");
        return 2;
    }
    const probe = evaluate(nix, "builtins ? wasm");
    if (probe.failure !is null || probe.value.type != JSONType.true_)
    {
        stderr.writeln("--check-nix-wasm: `", nix, "` has no builtins.wasm (Determinate Nix with "
            ~ "the wasm-builtin feature); the check did not run",
            probe.failure is null ? "" : ":\n" ~ probe.failure);
        return 1;
    }

    Verdict[] verdicts;
    string[2][] modules = [[module_, "the tree's module"]];
    if (pinned.length)
        modules ~= [pinned, "the pinned module"];
    foreach (pair; modules)
    {
        const label = pair[0], m = pair[1];
        const dir = root ~ "/libs/dub-manifest/nix-wasm";
        verdicts ~= run(nix, "answers, " ~ m, &judgeAgreement, "import " ~ dir ~ "/agreement.nix { module = "
            ~ label ~ "; answers = " ~ answers ~ "; root = " ~ root ~ "; }");
        verdicts ~= run(nix, "recipe facts, " ~ m, &judgeFacts, "import " ~ dir
            ~ "/facts-agreement.nix { module = " ~ label ~ "; root = " ~ root ~ "; }");
    }

    int status;
    foreach (v; verdicts)
    {
        writeln(v.failure is null ? " ✓ " : " ✗ ", v.what, " (", v.checked, " compared)",
            v.failure is null ? "" : ": " ~ v.failure);
        if (v.failure !is null)
            status = 1;
    }
    return status;
}

private Verdict run(string nix, string what, Verdict function(string, const JSONValue) @safe judge,
    string expression) @safe
{
    const r = evaluate(nix, expression);
    if (r.failure !is null)
        return Verdict(what, false, "did not evaluate:\n" ~ r.failure);
    return judge(what, r.value);
}

private struct Evaluated
{
    JSONValue value;
    string failure;
}

private Evaluated evaluate(string nix, string expression) @safe
{
    import std.process : Config, execute;

    // Warnings stay on stderr, out of the JSON.
    const r = execute([nix, "eval", "--impure", "--json", "--extra-experimental-features",
        "nix-command wasm-builtin", "--expr", expression], null, Config.stderrPassThrough);
    if (r.status != 0)
        return Evaluated(JSONValue.init, r.output);
    return Evaluated(parseJSON(r.output));
}
