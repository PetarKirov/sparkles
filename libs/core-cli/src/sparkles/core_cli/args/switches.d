/**
Named switches under one repeatable option: `--debug trace-frames
--debug lose-device-at=120`, or `--debug trace-frames,lose-device-at=120`.

A program's diagnostics grow one at a time, and each as its own flag (or,
worse, its own environment variable, which `--help` never lists) spreads them
across the command line. `Switches!S` gathers them: `S`'s fields are the
switches, named by their kebab-cased identifiers and documented by their
`@Description`. A `bool` field is turned on by its name alone (or set with
`name=true|false`); any other field takes `name=value`. Every occurrence of
the option adds to the set, and `--debug=?` lists the switches.
*/
module sparkles.core_cli.args.switches;

import std.algorithm.iteration : splitter;
import std.array : join;
import std.conv : ConvException, to;
import std.string : indexOf, strip;
import std.traits : FieldNameTuple, getUDAs, isIntegral;

import sparkles.base.text.case_style : CaseStyle, convertCase;
import sparkles.core_cli.args.error : CliError, CliExpected, error, ok;
import sparkles.metadata : Description;

/// Whether `T` is a $(LREF Switches).
enum isSwitches(T) = is(T : Switches!S, S);

/// ditto
struct Switches(S)
{
    S value; /// the switches' values; read through `alias this`
    alias value this;

    /**
    Sets the switches `spec` names: comma-separated, each `name` (a `bool`
    switch, turned on) or `name=value`. Unknown names, a missing value and a
    value of the wrong type are parse errors naming the switch.
    */
    CliExpected!void apply(string spec)
    {
        import sparkles.core_cli.args.internal : parseBool;

        // Onto a copy, kept only if every item applies: a failed `apply`
        // changes nothing.
        S next = value;
        foreach (item; spec.splitter(','))
        {
            const entry = item.strip;
            if (entry.length == 0)
                continue;
            const eq = entry.indexOf('=');
            const name = (eq < 0 ? entry : entry[0 .. eq]).strip;
            const text = eq < 0 ? null : entry[eq + 1 .. $].strip;
            bool known;
            static foreach (field; FieldNameTuple!S)
            {{
                enum flag = switchName!field;
                if (name == flag)
                {
                    known = true;
                    alias F = typeof(__traits(getMember, S, field));
                    static if (is(F == bool))
                    {
                        // The spellings every other flag of the CLI takes.
                        auto on = eq < 0 ? ok(true) : parseBool(text);
                        if (!on)
                            return failed("switch `" ~ flag ~ "` is on or off, not `" ~ text ~ "`");
                        __traits(getMember, next, field) = on.value;
                    }
                    else
                    {
                        if (eq < 0)
                            return failed("switch `" ~ flag ~ "` takes a value: " ~ shapeOf!field);
                        try
                            __traits(getMember, next, field) = text.to!F;
                        catch (ConvException)
                            return failed("switch `" ~ flag ~ "`: `" ~ text ~ "` is not "
                                ~ (isIntegral!F ? "a whole number" : "a " ~ F.stringof));
                    }
                }
            }}
            if (!known)
                return failed("unknown switch `" ~ name ~ "`; expected one of: " ~ names.join(", "));
        }
        value = next;
        return ok();
    }

    /// The switches' names, in declaration order.
    static string[] names()
    {
        string[] all;
        static foreach (field; FieldNameTuple!S)
            all ~= switchName!field;
        return all;
    }

    /// One line per switch: how it is spelled, and what it does.
    static string[] help()
    {
        string[] lines;
        static foreach (field; FieldNameTuple!S)
        {{
            alias udas = getUDAs!(__traits(getMember, S, field), Description);
            static if (udas.length)
                lines ~= shapeOf!field ~ " — " ~ udas[0].text;
            else
                lines ~= shapeOf!field;
        }}
        return lines;
    }

    private enum switchName(string field) = convertCase!(CaseStyle.kebabCase)(field);

    // Two fields that kebab-case alike (`fooBar`, `foo_bar`) would share a
    // name no spelling could tell apart.
    static foreach (i, a; FieldNameTuple!S)
        static foreach (b; FieldNameTuple!S[i + 1 .. $])
            static assert(switchName!a != switchName!b, S.stringof ~ ": `" ~ a ~ "` and `" ~ b
                ~ "` are both the switch `" ~ switchName!a ~ "`");

    private template shapeOf(string field)
    {
        alias F = typeof(__traits(getMember, S, field));
        static if (is(F == bool))
            enum shapeOf = switchName!field;
        else static if (isIntegral!F)
            enum shapeOf = switchName!field ~ "=N";
        else
            enum shapeOf = switchName!field ~ "=VALUE";
    }

    private static CliExpected!void failed(string message)
        => error(CliError(kind: CliError.Kind.parse, message: message));
}

///
@("args.switches.apply")
@safe unittest
{
    static struct Debug
    {
        @Description("log each frame") bool traceFrames;
        @Description("fail frame N") uint loseDeviceAt;
    }

    Switches!Debug d;
    assert(!d.apply("trace-frames").hasError && d.traceFrames && d.loseDeviceAt == 0);
    assert(!d.apply("lose-device-at=120, trace-frames=no").hasError);
    assert(d.loseDeviceAt == 120 && !d.traceFrames, "a later occurrence adds to the set");
    assert(!d.apply("trace-frames = YES, lose-device-at = 3").hasError
        && d.traceFrames && d.loseDeviceAt == 3, "spaces and the CLI's bool spellings");
    assert(d.apply("trace-frames=n, bogus").hasError && d.traceFrames,
        "a failed apply changes nothing");
    assert(d.apply("bogus").error.message
        == "unknown switch `bogus`; expected one of: trace-frames, lose-device-at");
    assert(d.apply("lose-device-at").error.message
        == "switch `lose-device-at` takes a value: lose-device-at=N");
    assert(d.apply("lose-device-at=x").error.message
        == "switch `lose-device-at`: `x` is not a whole number");
    assert(Switches!Debug.help == ["trace-frames — log each frame", "lose-device-at=N — fail frame N"]);
}

@("args.switches.parseCli")
@system unittest
{
    import sparkles.core_cli.args.internal : parseCli;
    import sparkles.core_cli.args.uda : Option;

    static struct Debug
    {
        @Description("log each frame") bool traceFrames;
        @Description("fail frame N") uint loseDeviceAt;
    }

    static struct App
    {
        @(Option("debug", description: "Debug switches.")) Switches!Debug debugging;
    }

    auto both = parseCli!App(["app", "--debug", "trace-frames", "--debug=lose-device-at=5"]);
    assert(both, both.error.message);
    assert(both.value.debugging.traceFrames && both.value.debugging.loseDeviceAt == 5);
    auto listed = parseCli!App(["app", "--debug", "trace-frames,lose-device-at=7"]);
    assert(listed && listed.value.debugging.loseDeviceAt == 7);
    auto inline = parseCli!App(["app", "--debug=trace-frames,lose-device-at=9"]);
    assert(inline && inline.value.debugging.traceFrames
        && inline.value.debugging.loseDeviceAt == 9, "an inline list is applied whole");
    auto badInline = parseCli!App(["app", "--debug=trace-frames,nope"]);
    assert(!badInline && badInline.error.message
        == "--debug: unknown switch `nope`; expected one of: trace-frames, lose-device-at");
    auto bad = parseCli!App(["app", "--debug", "nope"]);
    assert(!bad && bad.error.message
        == "--debug: unknown switch `nope`; expected one of: trace-frames, lose-device-at");
    auto help = parseCli!App(["app", "--debug=?"]);
    assert(!help && help.error.isHelp);
    import std.algorithm.searching : canFind;
    assert(help.error.help.canFind("lose-device-at=N — fail frame N"));
}

@("args.switches.namesAreDistinct")
@safe pure nothrow @nogc unittest
{
    static struct Clash
    {
        bool fooBar;
        bool foo_bar;
    }

    static assert(!__traits(compiles, Switches!Clash.init), "two fields, one switch name");
}
