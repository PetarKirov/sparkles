module sparkles.effects_ts;

import std.sumtype;
import std.meta : NoDuplicates, Filter, AliasSeq, staticMap;

enum isNotNoReturn(T) = !is(T == noreturn);

template Extract(T)
{
    static if (is(T == noreturn))
        alias Extract = AliasSeq!();
    else static if (is(T : SumType!Args, Args...))
        alias Extract = Args;
    else
        alias Extract = AliasSeq!T;
}

template Union(Types...)
{
    alias Flat = staticMap!(Extract, Types);
    alias Valid = Filter!(isNotNoReturn, Flat);
    alias Unique = NoDuplicates!Valid;

    static if (Unique.length == 0)
        alias Union = noreturn;
    else static if (Unique.length == 1)
        alias Union = Unique[0];
    else
        alias Union = SumType!Unique;
}

template Remove(Target, T)
{
    enum isNotTarget(U) = !is(U == Target);

    alias Flat = Extract!T;
    alias Remaining = Filter!(isNotTarget, Flat);

    alias Remove = Union!Remaining;
}

struct Effect(T, Errors, Requirements)
{
    alias ValueType = T;
    alias ErrorType = Errors;
    alias RequireType = Requirements;
}

Effect!(T, noreturn, noreturn) succeed(T)(T v)
{
    return typeof(return).init;
}

Effect!(noreturn, E, noreturn) fail(E)(E e)
{
    return typeof(return).init;
}

Effect!(R, noreturn, R) ask(R)()
{
    return typeof(return).init;
}

auto flatMap(alias fn, T, E, R)(Effect!(T, E, R) eff)
{
    alias NextEff = typeof(fn(T.init));

    alias NewT = NextEff.ValueType;
    alias NewE = Union!(E, NextEff.ErrorType);
    alias NewR = Union!(R, NextEff.RequireType);

    return Effect!(NewT, NewE, NewR).init;
}

auto catchAll(alias fn, T, E, R)(Effect!(T, E, R) eff)
if (!is(E == noreturn))
{
    alias HandlerResult = typeof(fn(E.init));

    alias NewT = Union!(T, HandlerResult.ValueType);
    alias NewE = HandlerResult.ErrorType;
    alias NewR = Union!(R, HandlerResult.RequireType);

    return Effect!(NewT, NewE, NewR).init;
}

auto provide(ProvidedR, T, E, R)(Effect!(T, E, R) eff, ProvidedR service)
{
    alias NewR = Remove!(ProvidedR, R);
    return Effect!(T, E, NewR).init;
}

T runSync(T, E)(Effect!(T, E, noreturn) eff)
{
    return T.init;
}

unittest
{
    struct Config { string dbUrl; }
    struct DbConnection {}
    struct DbError { string msg; }
    struct NetworkError { string msg; }

    auto fetchUser(int id)
    {
        return ask!(Config)()
            .flatMap!(cfg => ask!(DbConnection)())
            .flatMap!(db => fail(DbError("timeout")))
            .flatMap!(row => fail(NetworkError("bad format")));
    }

    auto program = fetchUser(42)
        .catchAll!(err => err.match!(
            (DbError e)      => succeed("fallback"),
            (NetworkError e) => succeed("fallback")
        ))
        .provide(Config("postgres://localhost"))
        .provide(DbConnection());

    string u = runSync(program);
}
