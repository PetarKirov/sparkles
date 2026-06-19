/**
Generic method dispatch — call a function by name over a module, type, or instance.

Two complementary facilities sit side by side:

$(UL
    $(LI **Runtime dispatch** ([call] / [tryCall]) — the method name is a
        runtime `string` and arguments arrive boxed as
        $(REF Variant, std,variant). The dispatcher looks the name up, picks a
        viable overload, unboxes each argument to the parameter type, invokes the
        function, and re-boxes the result. This is what an RPC server or a REPL
        needs: it turns "the user typed `add 2 3`" into an actual call.)
    $(LI **Compile-time dispatch** ([callDirect] and the [wrap] proxy) — the
        method name is a compile-time `string` and the arguments are ordinary
        typed values, so there is no `Variant` boxing and no runtime lookup. It
        lowers to a plain, perfectly-forwarded call. This is what a thin wrapper
        over a shared library wants: `wrap!mylib.some_func(1, 2)`.)
)

Both facilities work over four kinds of target:

$(UL
    $(LI a **module** (alias target) — its free functions are dispatchable;)
    $(LI a **type with static members** (alias target);)
    $(LI a **struct instance**;)
    $(LI a **class / interface instance** — virtual dispatch is preserved, so a
        call through a base-class or interface reference reaches the override.)
)

Only `public`/`export` function members are dispatchable. D lifecycle and
operator specials (`__ctor`, `opAssign`, `toString`, `opEquals`, …) are excluded
by exact name, but otherwise-unusual names such as `__handle` pass through — the
filter never blanket-rejects a leading-underscore identifier. (Truly reserved
tokens like `__EOF__`/`__traits` are not valid D identifiers in the first place;
they only ever appear as members of an ImportC C module, where they dispatch like
any other name.)
*/
module sparkles.core_cli.dispatch;

import std.meta : Filter, ApplyLeft, allSatisfy, anySatisfy;
import std.traits : Parameters, ReturnType, ParameterDefaults, isSomeFunction;
import std.variant : Variant;
import std.algorithm.searching : canFind;
import core.lifetime : forward;

import expected : Expected, ok, err;

///
@system
unittest
{
    import std.variant : Variant;

    struct Calculator
    {
        int base;
        int add(int x) => base + x;
        int add(int x, int y) => base + x + y;     // overloaded
        string greet(string who = "world") => "hi " ~ who;
    }

    auto calc = Calculator(10);

    // Runtime dispatch: name and args are values (as from an RPC frame / REPL line).
    assert(calc.call("add", Variant(5)) == 15);
    assert(calc.call("add", Variant(5), Variant(7)) == 22);
    assert(calc.call("greet") == "hi world");         // default argument used

    // tryCall reports failures as an Expected instead of throwing.
    assert(calc.tryCall("nope").hasError);

    // Compile-time dispatch: a plain typed call, no Variant boxing.
    assert(calc.callDirect!"add"(5, 7) == 22);

    // The wrap() proxy gives natural call syntax over the same machinery.
    assert(wrap(calc).add(5) == 15);
}

// ─────────────────────────────────────────────────────────────────────────────
// Error vocabulary
// ─────────────────────────────────────────────────────────────────────────────

/// Why a runtime [tryCall] / [call] could not be performed.
enum DispatchErrorKind
{
    /// No dispatchable member with the requested name exists on the target.
    unknownMethod,
    /// The name exists, but no overload accepts the supplied number of arguments.
    arityMismatch,
    /// The arity matched an overload, but an argument could not be unboxed to the
    /// corresponding parameter type.
    conversionFailure,
}

/// A failed runtime dispatch. Returned (inside an `Expected`) by [tryCall] and
/// carried by the [DispatchException] thrown by [call].
struct DispatchError
{
    /// What went wrong.
    DispatchErrorKind kind;
    /// The method name that was requested.
    string methodName;
    /// How many arguments the caller supplied.
    size_t argCount;

    /// A human-readable, REPL-friendly description.
    string toString() const @safe pure
    {
        import std.conv : to;

        final switch (kind)
        {
            case DispatchErrorKind.unknownMethod:
                return "Unknown method: " ~ methodName;
            case DispatchErrorKind.arityMismatch:
                return "No overload of '" ~ methodName ~ "' takes "
                    ~ argCount.to!string ~ " argument(s)";
            case DispatchErrorKind.conversionFailure:
                return "Arguments to '" ~ methodName
                    ~ "' could not be converted to any overload's parameters";
        }
    }
}

/// Thrown by [call] (the throwing twin of [tryCall]) when dispatch fails. The
/// structured [DispatchError] is preserved in [error] for programmatic handling.
class DispatchException : Exception
{
    /// The dispatch failure that triggered this exception.
    DispatchError error;

    this(DispatchError error) @safe pure
    {
        super(error.toString);
        this.error = error;
    }
}

/// `Expected` hook that turns "read the value of a failed result" into a thrown
/// [DispatchException]. This is what lets [call] be a one-liner over [tryCall]
/// (`tryCall(...).value`) with no hand-written unwrap helper.
private struct ThrowOnError
{
    static void onAccessEmptyValue(E)(E error)
    {
        throw new DispatchException(error);
    }
}

/// The result type of [tryCall]: a [Variant] on success (empty for a `void`
/// method) or a [DispatchError] on failure. Accessing `.value` on a failure
/// throws a [DispatchException] via the [ThrowOnError] hook — which is exactly
/// how [call] reports errors.
alias DispatchResult = Expected!(Variant, DispatchError, ThrowOnError);

// ─────────────────────────────────────────────────────────────────────────────
// Runtime dispatch — alias target (module / type with static members)
// ─────────────────────────────────────────────────────────────────────────────

/**
Dispatch by runtime name over a `module` or a type's `static` members,
returning the result without throwing.

Params:
    Target = a module or aggregate type whose `public` static functions are the
        dispatch candidates.
    methodName = the member to call.
    args = the arguments, boxed as `Variant`.

Returns:
    A [DispatchResult] holding the (re-boxed) return value, or a [DispatchError].
    A `void`-returning method yields an empty `Variant` (`!result.value.hasValue`).
*/
DispatchResult tryCall(alias Target)(string methodName, Variant[] args...)
{
    typeof(null) noInstance;
    return dispatchImpl!Target(noInstance, methodName, args);
}

/// ditto, but throws a [DispatchException] on failure instead of returning it
/// (the [ThrowOnError] hook fires when the failed result's `.value` is read).
Variant call(alias Target)(string methodName, Variant[] args...)
{
    return tryCall!Target(methodName, args).value;
}

// ─────────────────────────────────────────────────────────────────────────────
// Runtime dispatch — instance target (struct / class / interface)
// ─────────────────────────────────────────────────────────────────────────────

/**
Dispatch by runtime name over the `public` member functions of an instance.

Works for `struct`, `class`, and `interface` references; calls through a base or
interface reference dispatch virtually to the runtime type's override.

Params:
    obj = the instance the call is bound to.
    methodName = the member to call.
    args = the arguments, boxed as `Variant`.

Returns: see the alias-target [tryCall].
*/
DispatchResult tryCall(T)(auto ref T obj, string methodName, Variant[] args...)
if (is(T == struct) || is(T == class) || is(T == interface))
{
    return dispatchImpl!T(forward!obj, methodName, args);
}

/// ditto, but throws a [DispatchException] on failure.
Variant call(T)(auto ref T obj, string methodName, Variant[] args...)
if (is(T == struct) || is(T == class) || is(T == interface))
{
    return tryCall(forward!obj, methodName, args).value;
}

// ─────────────────────────────────────────────────────────────────────────────
// Compile-time dispatch
// ─────────────────────────────────────────────────────────────────────────────

/**
Dispatch by a compile-time name to a plain, perfectly-forwarded typed call —
no `Variant` boxing, no runtime lookup. Normal overload resolution applies.

Two forms, distinguished by the template arguments:

$(UL
    $(LI `callDirect!"name"(obj, args)` — instance form. Also reads naturally with
        UFCS: `obj.callDirect!"name"(args)`.)
    $(LI `callDirect!(Target, "name")(args)` — alias form, where `Target` is a
        module or a type with static members.)
)

`ref` parameters and `ref` returns are preserved (the call is `auto ref`).
*/
template callDirect(Spec...)
if ((Spec.length == 1 && is(typeof(Spec[0]) == string))
    || (Spec.length == 2 && is(typeof(Spec[1]) == string)))
{
    static if (Spec.length == 1)
    {
        private enum string name = Spec[0];

        auto ref callDirect(T, Args...)(auto ref T obj, auto ref Args args)
        if (isDispatchableMember!(T, name))
        {
            return __traits(getMember, obj, name)(forward!args);
        }
    }
    else
    {
        private alias Target = Spec[0];
        private enum string name = Spec[1];

        auto ref callDirect(Args...)(auto ref Args args)
        if (isDispatchableMember!(Target, name))
        {
            return __traits(getMember, Target, name)(forward!args);
        }
    }
}

/**
Wrap a target so its methods can be called with natural syntax via `opDispatch`,
forwarding to [callDirect].

`wrap!Target` (a module or type with statics) produces a zero-size proxy;
`wrap(obj)` produces a proxy holding the instance. Either way,
`wrap(target).someMethod(args)` lowers to a direct, perfectly-forwarded call.
*/
auto wrap(alias Target)()
if (!is(typeof(Target)))
{
    return DispatchProxy!(Target, false).init;
}

/// ditto
auto wrap(T)(auto ref T obj)
{
    return DispatchProxy!(T, true)(forward!obj);
}

// ─────────────────────────────────────────────────────────────────────────────
// Member introspection (public — useful for REPL help / tab-completion)
// ─────────────────────────────────────────────────────────────────────────────

/**
Is `name` a dispatchable member of `Scope`?

True iff `name` names one or more `public`/`export` function overloads on `Scope`
and is not a D lifecycle/operator special (`__ctor`, `opAssign`, `toString`, …).
Unusual but legal identifiers such as `__handle` are *not* excluded.
*/
template isDispatchableMember(alias Scope, string name)
{
    static if (!__traits(compiles, __traits(getOverloads, Scope, name)))
        enum isDispatchableMember = false;
    else static if (canFind(reservedMemberNames, name))
        enum isDispatchableMember = false;
    else static if (__traits(getOverloads, Scope, name).length == 0)
        enum isDispatchableMember = false;
    else static if (!allSatisfy!(isSomeFunction, __traits(getOverloads, Scope, name)))
        enum isDispatchableMember = false;
    else
        enum isDispatchableMember = isPublicSymbol!(__traits(getOverloads, Scope, name)[0]);
}

/// The names of every dispatchable member of `Scope`, as an `AliasSeq` of
/// `string`s. Handy for building a REPL's command list or completion set.
alias DispatchableMembers(alias Scope) =
    Filter!(ApplyLeft!(isDispatchableMember, Scope), __traits(allMembers, Scope));

// ─────────────────────────────────────────────────────────────────────────────
// Implementation
// ─────────────────────────────────────────────────────────────────────────────

/// D lifecycle/operator members never offered for dispatch. Matched by *exact*
/// name so arbitrary user identifiers (including leading-underscore ones) pass.
private enum string[] reservedMemberNames = [
    // object model noise surfaced by allMembers
    "object", "Monitor", "factory",
    // lifetime
    "__ctor", "__dtor", "__postblit", "__xdtor", "__xpostblit",
    "__fieldDtor", "__fieldPostblit", "__aggrDtor", "__aggrPostblit",
    "this", "~this",
    // value-semantics / Object overrides
    "opAssign", "opEquals", "opCmp", "toHash", "toString",
    // operator overloads
    "opCast", "opUnary", "opBinary", "opBinaryRight", "opOpAssign",
    "opIndex", "opIndexAssign", "opIndexUnary", "opIndexOpAssign",
    "opSlice", "opSliceAssign", "opDollar", "opCall",
    "opApply", "opApplyReverse", "opDispatch",
];

private enum bool isPublicSymbol(alias sym) =
    __traits(getVisibility, sym) == "public" || __traits(getVisibility, sym) == "export";

/// An overload is invocable in the current mode iff we have an instance, or the
/// overload is `static` (so it needs no `this`). `Inst == typeof(null)` is the
/// alias/static mode.
private enum bool overloadInvocable(alias ov, Inst) =
    !is(Inst == typeof(null)) || __traits(isStaticFunction, ov);

/// Number of leading parameters without a default (the minimum arg count).
private template requiredArgCount(alias ov)
{
    private alias Defaults = ParameterDefaults!ov;
    enum size_t requiredArgCount = ()
    {
        size_t n;
        static foreach (i; 0 .. Defaults.length)
            static if (is(Defaults[i] == void))
                ++n;
        return n;
    }();
}

/// The switch over member names that the PoC pioneered, generalized over an
/// optional instance and over overload sets.
private DispatchResult dispatchImpl(alias TargetType, Inst)(
    auto ref Inst inst, string methodName, Variant[] args)
{
    switch (methodName)
    {
        static foreach (name; DispatchableMembers!TargetType)
        {
            case name:
                return selectAndInvoke!(TargetType, name)(forward!inst, args);
        }

        default:
            return err!(Variant, ThrowOnError)(
                DispatchError(DispatchErrorKind.unknownMethod, methodName, args.length));
    }
}

/// Pick the first overload of `name` whose arity fits and whose arguments all
/// convert, then invoke it. Declaration order decides ties.
private DispatchResult selectAndInvoke(alias TargetType, string name, Inst)(
    auto ref Inst inst, Variant[] args)
{
    bool anyArityMatch = false;

    static foreach (ov; __traits(getOverloads, TargetType, name))
    {{
        static if (overloadInvocable!(ov, Inst))
        {
            enum size_t maxArgs = Parameters!ov.length;
            enum size_t minArgs = requiredArgCount!ov;

            if (args.length >= minArgs && args.length <= maxArgs)
            {
                anyArityMatch = true;
                if (argsConvertTo!ov(args))
                    return ok!(DispatchError, ThrowOnError)(
                        invokeOverload!ov(forward!inst, args));
            }
        }
    }}

    immutable kind = anyArityMatch
        ? DispatchErrorKind.conversionFailure
        : DispatchErrorKind.arityMismatch;
    return err!(Variant, ThrowOnError)(DispatchError(kind, name, args.length));
}

/// Can each supplied argument be unboxed to the matching parameter type?
private bool argsConvertTo(alias ov)(Variant[] args)
{
    alias Ps = Parameters!ov;
    static foreach (i; 0 .. Ps.length)
        if (i < args.length && !args[i].convertsTo!(Ps[i]))
            return false;
    return true;
}

/// Build the typed argument tuple (defaults fill absent trailing args) and call
/// the overload — bound to `inst` for instances, or directly for the static form.
private Variant invokeOverload(alias ov, Inst)(auto ref Inst inst, Variant[] args)
{
    alias Ps = Parameters!ov;
    alias Defaults = ParameterDefaults!ov;

    Ps tup;
    static foreach (i; 0 .. Ps.length)
    {
        static if (is(Defaults[i] == void))
            tup[i] = args[i].get!(Ps[i]);
        else
        {
            if (i < args.length)
                tup[i] = args[i].get!(Ps[i]);
            else
                tup[i] = Defaults[i];
        }
    }

    static if (is(Inst == typeof(null)))
    {
        static if (is(ReturnType!ov == void))
        {
            ov(tup);
            return Variant();
        }
        else
            return Variant(ov(tup));
    }
    else
    {
        static if (is(ReturnType!ov == void))
        {
            __traits(child, inst, ov)(tup);
            return Variant();
        }
        else
            return Variant(__traits(child, inst, ov)(tup));
    }
}

/// Backing type for [wrap]: `bound` distinguishes an instance proxy (holds the
/// object) from a static/alias proxy (holds nothing).
private struct DispatchProxy(alias Target, bool bound)
{
    static if (bound)
    {
        private Target _obj;

        template opDispatch(string name)
        {
            auto ref opDispatch(Args...)(auto ref Args args)
            if (isDispatchableMember!(Target, name))
            {
                return callDirect!name(_obj, forward!args);
            }
        }
    }
    else
    {
        template opDispatch(string name)
        {
            auto ref opDispatch(Args...)(auto ref Args args)
            if (isDispatchableMember!(Target, name))
            {
                return callDirect!(Target, name)(forward!args);
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    // A struct instance target with overloads, a default arg, a void method, a
    // private (non-dispatchable) method, and an unusual but legal name.
    // Methods are @safe so the compile-time @safe tests can exercise them.
    private struct Calc
    {
        int base;
        int add(int x) @safe => base + x;
        int add(int x, int y) @safe => base + x + y;     // overloaded by arity
        string greet(string who = "world") @safe => "hi " ~ who;
        void reset() @safe { base = 0; }
        int __handle(int x) @safe => x + 5;              // leading underscore, legal
        private int secret() @safe => 99;                // must NOT be dispatchable
    }

    // An alias target: a type whose dispatchable members are all static.
    private struct MathOps
    {
        static int square(int x) @safe => x * x;
        static int sum(int a, int b) @safe => a + b;
        static void ignore(string s) @safe {}
    }

    // Same-name overloads disambiguated by argument type.
    private struct Typed
    {
        string pick(int x) @safe => "int";
        string pick(string s) @safe => "string";
        string pick(double d) @safe => "double";
    }

    private interface Speaker { string speak() @safe; }
    private class Animal { string speak() @safe => "..."; }
    private class Dog : Animal { override string speak() @safe => "woof"; }
    private class Parrot : Speaker { string speak() @safe => "squawk"; }

    private struct RefStuff
    {
        int n;
        void inc(ref int x) @safe { ++x; }
        ref int slot() @safe return { return n; }
    }

    private struct Movable { int id; @disable this(this); }
    private struct MoveHost { int take(Movable m) @safe => m.id * 2; }

    private struct PureFix
    {
        int pureAdd(int a, int b) @safe pure nothrow @nogc => a + b;
    }
}

@("dispatch.call.structInstance")
@system
unittest
{
    auto c = Calc(10);
    assert(c.call("add", Variant(5)) == 15);
    assert(c.call("greet", Variant("bob")) == "hi bob");
}

@("dispatch.call.staticAliasTarget")
@system
unittest
{
    assert(call!MathOps("square", Variant(7)) == 49);
    assert(call!MathOps("sum", Variant(2), Variant(3)) == 5);
}

@("dispatch.call.classInstance")
@system
unittest
{
    auto d = new Dog;
    assert(d.call("speak") == "woof");
}

@("dispatch.call.virtualViaBaseRef")
@system
unittest
{
    Animal a = new Dog;
    assert(a.call("speak") == "woof");   // override reached through base reference
}

@("dispatch.call.interfaceRef")
@system
unittest
{
    Speaker s = new Parrot;
    assert(s.call("speak") == "squawk");
}

@("dispatch.call.voidReturnIsEmpty")
@system
unittest
{
    auto c = Calc(10);
    auto r = c.call("reset");
    assert(!r.hasValue);
    assert(c.base == 0);
}

@("dispatch.overload.arity")
@system
unittest
{
    auto c = Calc(10);
    assert(c.call("add", Variant(5)) == 15);
    assert(c.call("add", Variant(5), Variant(7)) == 22);
}

@("dispatch.overload.typeDisambiguation")
@system
unittest
{
    auto t = Typed();
    assert(t.call("pick", Variant(5)) == "int");
    assert(t.call("pick", Variant("hi")) == "string");
    assert(t.call("pick", Variant(3.14)) == "double");
}

@("dispatch.overload.defaultArgs")
@system
unittest
{
    auto c = Calc(10);
    assert(c.call("greet") == "hi world");          // default used
    assert(c.call("greet", Variant("sam")) == "hi sam");
}

@("dispatch.error.unknownMethod")
@system
unittest
{
    auto c = Calc(10);
    auto r = c.tryCall("nope");
    assert(r.hasError);
    assert(r.error.kind == DispatchErrorKind.unknownMethod);
}

@("dispatch.error.arityMismatch")
@system
unittest
{
    auto c = Calc(10);
    auto r = c.tryCall("add", Variant(1), Variant(2), Variant(3));
    assert(r.hasError);
    assert(r.error.kind == DispatchErrorKind.arityMismatch);
}

@("dispatch.error.conversionFailure")
@system
unittest
{
    struct Weird {}
    auto t = Typed();
    auto r = t.tryCall("pick", Variant(Weird()));   // arity fits, no conversion
    assert(r.hasError);
    assert(r.error.kind == DispatchErrorKind.conversionFailure);
}

@("dispatch.error.throwsDispatchException")
@system
unittest
{
    auto c = Calc(10);

    bool threw;
    try
        c.call("nope");
    catch (DispatchException e)
    {
        threw = true;
        assert(e.error.kind == DispatchErrorKind.unknownMethod);  // structured error preserved
        assert(canFind(e.msg, "nope"));
    }
    assert(threw);
}

@("dispatch.filter.allowsUnderscoreName")
@safe
unittest
{
    static assert(isDispatchableMember!(Calc, "__handle"));
    static assert(canFind([DispatchableMembers!Calc], "__handle"));
}

@("dispatch.filter.excludesSpecialsAndPrivate")
@safe
unittest
{
    static assert(!isDispatchableMember!(Calc, "secret"));     // private
    static assert(!isDispatchableMember!(Calc, "toString"));   // Object override
    static assert(!isDispatchableMember!(Calc, "opEquals"));
    static assert(!isDispatchableMember!(Calc, "__ctor"));
    static assert(!isDispatchableMember!(Calc, "opAssign"));
    static assert(!canFind([DispatchableMembers!Animal], "factory"));
}

@("dispatch.callDirect.instance")
@safe
unittest
{
    auto c = Calc(10);
    assert(callDirect!"add"(c, 5) == 15);
    assert(c.callDirect!"add"(5, 7) == 22);          // UFCS
}

@("dispatch.callDirect.staticAlias")
@safe
unittest
{
    assert(callDirect!(MathOps, "square")(7) == 49);
    callDirect!(MathOps, "ignore")("noop");          // void alias call
}

@("dispatch.callDirect.virtualViaBaseRef")
@safe
unittest
{
    Animal a = new Dog;
    assert(callDirect!"speak"(a) == "woof");
}

@("dispatch.callDirect.refParam")
@safe
unittest
{
    auto r = RefStuff(0);
    int x = 5;
    callDirect!"inc"(r, x);
    assert(x == 6);                                   // ref parameter mutated
}

@("dispatch.callDirect.refReturn")
@safe
unittest
{
    auto r = RefStuff(0);
    callDirect!"slot"(r) = 99;                        // ref return is assignable
    assert(r.n == 99);
}

@("dispatch.callDirect.perfectForwarding")
@safe
unittest
{
    auto h = MoveHost();
    assert(callDirect!"take"(h, Movable(21)) == 42);  // rvalue (move-only) forwarded
}

@("dispatch.callDirect.badNameIsCompileError")
@safe
unittest
{
    auto c = Calc(10);
    static assert(!__traits(compiles, callDirect!"nope"(c)));
    static assert(!__traits(compiles, callDirect!(MathOps, "nope")()));
}

@("dispatch.callDirect.attributesInfer")
@safe pure nothrow @nogc
unittest
{
    auto p = PureFix();
    assert(p.callDirect!"pureAdd"(2, 3) == 5);        // stays @safe pure nothrow @nogc
}

@("dispatch.proxy.instance")
@safe
unittest
{
    auto c = Calc(10);
    assert(wrap(c).add(5) == 15);
    assert(wrap(c).add(5, 7) == 22);
}

@("dispatch.proxy.staticAlias")
@safe
unittest
{
    assert(wrap!MathOps.square(8) == 64);
    wrap!MathOps.ignore("noop");
}

@("dispatch.proxy.unknownIsCompileError")
@safe
unittest
{
    auto c = Calc(10);
    static assert(!__traits(compiles, wrap(c).nope()));
    static assert(!__traits(compiles, wrap!MathOps.nope()));
}
