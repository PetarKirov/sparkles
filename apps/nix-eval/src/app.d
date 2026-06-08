/// `nix-eval` — a small demo of `sparkles:nix`.
///
/// Evaluate a Nix expression and pretty-print the result, or (with `--flake`)
/// lock a flake and evaluate one of its outputs:
///
/// ---
/// nix-eval '1 + 2'                    # => 3
/// nix-eval '[ 1 2 3 ]'               # => [ 1 2 3 ]
/// nix-eval '{ x = 1; y = "hi"; }'    # => { x = 1; y = "hi"; }
/// nix-eval --flake 'nixpkgs#lib.version'
/// ---
///
/// The recursive `renderValue` walk over `ValueType` is the centerpiece — it
/// exercises the whole extraction API.
module app;

import std.array : appender, Appender, split;
import std.conv : to;
import std.stdio : stderr, writeln;

import sparkles.nix;

int main(string[] args)
{
    import std.algorithm.searching : startsWith;

    bool flakeMode;
    string[] lookupPath;
    string storeUri;
    bool storeSet;
    string[] positional;

    for (size_t i = 1; i < args.length; ++i)
    {
        auto arg = args[i];
        if (arg == "--help" || arg == "-h")
            return usage(0);
        else if (arg == "--flake" || arg == "-f")
            flakeMode = true;
        else if (arg == "-I" || arg == "--include")
        {
            if (++i >= args.length)
                return usage(2);
            lookupPath ~= args[i];
        }
        else if (arg.startsWith("-I"))
        {
            lookupPath ~= arg[2 .. $];
        }
        else if (arg == "--store" || arg == "-s")
        {
            if (++i >= args.length)
                return usage(2);
            storeUri = args[i];
            storeSet = true;
        }
        else if (arg.startsWith("--store="))
        {
            storeUri = arg["--store=".length .. $];
            storeSet = true;
        }
        else if (arg.startsWith("-"))
        {
            stderr.writeln("nix-eval: unrecognized option `", arg, "`");
            return usage(2);
        }
        else
        {
            positional ~= arg;
        }
    }

    if (positional.length != 1)
        return usage(2);

    if (!storeSet)
        storeUri = flakeMode ? "" : "dummy://";

    return flakeMode
        ? runFlake(positional[0], lookupPath, storeUri)
        : runExpr(positional[0], lookupPath, storeUri);
}

private int usage(int code)
{
    auto sink = code == 0 ? &stdoutLine : &stderrLine;
    sink("nix-eval — evaluate a Nix expression or flake output (sparkles:nix demo)");
    sink("");
    sink("usage:");
    sink("  nix-eval [options] <expression>          evaluate a Nix expression");
    sink("  nix-eval [options] --flake <flake-ref>   lock a flake and evaluate an output");
    sink("");
    sink("options:");
    sink("  -f, --flake                 lock and evaluate a flake reference");
    sink("  -I, --include <path>        add a path to the Nix search path (<...>)");
    sink("  -s, --store <uri>           store URI (default: dummy:// for expr, \"\" for flake)");
    sink("  -h, --help                  display this help and exit");
    sink("");
    sink("examples:");
    sink(`  nix-eval '{ x = 1; y = [ 2 3 ]; }'`);
    sink("  nix-eval 'import <nixpkgs>'");
    sink("  nix-eval -I nixpkgs=/etc/nix/inputs/nixpkgs '(import <nixpkgs/lib>).version'");
    sink("  nix-eval --flake 'nixpkgs#lib.version'");
    return code;
}

private void stdoutLine(string s) => writeln(s);
private void stderrLine(string s) => stderr.writeln(s);

/// Evaluate a plain expression against an in-memory store.
private int runExpr(string expr, string[] lookupPath = null, string storeUri = "dummy://")
{
    auto opened = NixSession.open(storeUri, lookupPath);
    if (opened.hasError)
        return fail("could not start Nix", opened.error);
    auto nix = opened.value;

    auto value = nix.eval(expr);
    if (value.hasError)
        return fail("evaluation failed", value.error);

    auto w = appender!string;
    renderValue(nix.evalState, value.value, w);
    writeln(w[]);
    return 0;
}

/// Lock a flake and evaluate the output named by its `#fragment`.
private int runFlake(string reference, string[] lookupPath = null, string storeUri = "")
{
    auto enabled = setSetting("experimental-features", "flakes");
    if (enabled.hasError)
        return fail("could not enable flakes", enabled.error);

    // A real store (not dummy://) is needed to copy/lock flake sources.
    auto store = Store.open(storeUri);
    if (store.hasError)
        return fail("could not open the store", store.error);

    auto fetch = FetchersSettings.create();
    if (fetch.hasError)
        return fail("fetchers settings", fetch.error);
    auto flake = FlakeSettings.create();
    if (flake.hasError)
        return fail("flake settings", flake.error);

    auto builder = EvalStateBuilder.create(store.value);
    if (lookupPath.length)
        builder.lookupPath(lookupPath);
    builder.flakes(flake.value);
    auto state = builder.build();
    if (state.hasError)
        return fail("could not build the evaluator", state.error);
    auto es = state.value;

    auto parseFlags = FlakeReferenceParseFlags.create(flake.value);
    if (parseFlags.hasError)
        return fail("parse flags", parseFlags.error);
    parseFlags.value.baseDirectory("."); // resolve relative path: refs

    auto parsed = FlakeReference.parse(fetch.value, flake.value, parseFlags.value, reference);
    if (parsed.hasError)
        return fail("could not parse the flake reference", parsed.error);
    auto flakeRef = parsed.value[0];
    auto fragment = parsed.value[1];

    auto lockFlags = FlakeLockFlags.create(flake.value);
    if (lockFlags.hasError)
        return fail("lock flags", lockFlags.error);
    lockFlags.value.modeWriteAsNeeded();

    auto locked = LockedFlake.lock(fetch.value, flake.value, es, lockFlags.value, flakeRef);
    if (locked.hasError)
        return fail("could not lock the flake", locked.error);

    auto outputs = locked.value.outputs(flake.value, es);
    if (outputs.hasError)
        return fail("could not evaluate flake outputs", outputs.error);

    // Navigate the dotted #fragment (e.g. "lib.version") into the outputs.
    auto current = outputs.value;
    if (fragment.length)
    {
        foreach (segment; fragment.split('.'))
        {
            auto next = es.requireAttr(current, segment);
            if (next.hasError)
                return fail("no such output attribute `" ~ segment ~ "`", next.error);
            current = next.value;
        }
    }

    auto w = appender!string;
    renderValue(es, current, w);
    writeln(w[]);
    return 0;
}

private int fail(string what, NixError e)
{
    stderr.writeln("nix-eval: ", what, ": ", e.message);
    return 1;
}

/// Recursively render a forced `Value` in a Nix-like syntax, dispatching on its
/// `ValueType`. This is the demo's heart: it touches every extraction method.
private void renderValue(ref EvalState es, in Value v, ref Appender!string w)
{
    bool[const(void)*] seen;
    renderValueImpl(es, v, w, seen, 0);
}

private void renderValueImpl(ref EvalState es, in Value v, ref Appender!string w,
    ref bool[const(void)*] seen, size_t depth)
{
    enum maxDepth = 64;
    if (depth > maxDepth)
    {
        w.put("«...»");
        return;
    }

    auto t = es.valueType(v);
    if (t.hasError)
    {
        w.put("«error: ");
        w.put(t.error.message);
        w.put("»");
        return;
    }

    auto ptr = v.internalPointer();

    final switch (t.value)
    {
    case ValueType.integer:
        w.put(es.requireInt(v).value.to!string);
        break;
    case ValueType.float_:
        w.put(es.requireFloat(v).value.to!string);
        break;
    case ValueType.boolean:
        w.put(es.requireBool(v).value ? "true" : "false");
        break;
    case ValueType.string_:
        w.put('"');
        w.put(es.requireString(v).value);
        w.put('"');
        break;
    case ValueType.path:
        w.put(es.requirePath(v).value);
        break;
    case ValueType.null_:
        w.put("null");
        break;
    case ValueType.list:
        if (ptr !is null)
        {
            if (ptr in seen)
            {
                w.put("«repeated»");
                return;
            }
            seen[ptr] = true;
        }
        auto elems = es.requireList(v);
        if (elems.hasError)
        {
            w.put("«error: " ~ elems.error.message ~ "»");
            break;
        }
        if (elems.value.length == 0)
        {
            w.put("[ ]");
            break;
        }
        w.put("[ ");
        foreach (ref el; elems.value)
        {
            renderValueImpl(es, el, w, seen, depth + 1);
            w.put(' ');
        }
        w.put(']');
        break;
    case ValueType.attrs:
        if (ptr !is null)
        {
            if (ptr in seen)
            {
                w.put("«repeated»");
                return;
            }
            seen[ptr] = true;
        }
        auto names = es.attrNames(v);
        if (names.hasError)
        {
            w.put("«error: " ~ names.error.message ~ "»");
            break;
        }
        if (names.value.length == 0)
        {
            w.put("{ }");
            break;
        }
        w.put("{ ");
        foreach (name; names.value)
        {
            w.put(name);
            w.put(" = ");
            auto attr = es.requireAttr(v, name);
            if (attr.hasError)
                w.put("«error: " ~ attr.error.message ~ "»");
            else
                renderValueImpl(es, attr.value, w, seen, depth + 1);
            w.put("; ");
        }
        w.put('}');
        break;
    case ValueType.function_:
        w.put("«lambda»");
        break;
    case ValueType.external:
        w.put("«external»");
        break;
    case ValueType.thunk:
        w.put("«thunk»"); // unreachable: valueType forces first
        break;
    case ValueType.failed:
        w.put("«failed»");
        break;
    }
}
