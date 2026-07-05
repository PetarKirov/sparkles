/**
The engine registry.

Each foreign or compatibility-risky engine sits behind its own `version`
gate (set from `dub.sdl` configurations), so a broken engine is one line
away from off while the rest of the harness keeps building.
*/
module sparkles.wired_bench.engines;

import std.meta : AliasSeq;

public import sparkles.wired_bench.engines.std_json : StdJsonEngine;
public import sparkles.wired_bench.engines.wired_json : WiredEngine;

version (BenchMirIon)
{
    public import sparkles.wired_bench.engines.mir_ion : MirIonEngine;

    private alias MirIonEngines = AliasSeq!MirIonEngine;
}
else
    private alias MirIonEngines = AliasSeq!();

version (BenchAsdf)
{
    public import sparkles.wired_bench.engines.asdf_json : AsdfEngine;

    private alias AsdfEngines = AliasSeq!AsdfEngine;
}
else
    private alias AsdfEngines = AliasSeq!();

version (BenchJsoniopipe)
{
    public import sparkles.wired_bench.engines.jsoniopipe_json : JsoniopipeEngine;

    private alias JsoniopipeEngines = AliasSeq!JsoniopipeEngine;
}
else
    private alias JsoniopipeEngines = AliasSeq!();

version (BenchYyjson)
{
    public import sparkles.wired_bench.engines.yyjson_json : YyjsonEngine;

    private alias YyjsonEngines = AliasSeq!YyjsonEngine;
}
else
    private alias YyjsonEngines = AliasSeq!();

version (BenchCpp)
{
    public import sparkles.wired_bench.engines.rapidjson_json : RapidjsonEngine;
    public import sparkles.wired_bench.engines.simdjson_dom : SimdjsonDomEngine;
    public import sparkles.wired_bench.engines.simdjson_ondemand
        : SimdjsonOndemandEngine;

    private alias CppEngines = AliasSeq!(SimdjsonDomEngine,
        SimdjsonOndemandEngine, RapidjsonEngine);
}
else
    private alias CppEngines = AliasSeq!();

version (BenchRust)
{
    public import sparkles.wired_bench.engines.rust_engines : SerdeJsonEngine,
        SimdJsonEngine, SonicRsEngine;

    private alias RustEngines = AliasSeq!(SerdeJsonEngine, SimdJsonEngine,
        SonicRsEngine);
}
else
    private alias RustEngines = AliasSeq!();

/// Every engine compiled into this build, baseline first (`wired` is the
/// decode-only row this whole benchmark exists to improve).
alias AllEngines = AliasSeq!(StdJsonEngine, WiredEngine, MirIonEngines,
    AsdfEngines, JsoniopipeEngines, YyjsonEngines, CppEngines, RustEngines);

/// Foreign-toolchain version/provenance lines for the report header.
string[] engineVersions()
{
    string[] lines;
    version (BenchCpp)
    {
        import sparkles.bench_shim : jb_cpp_versions;
        import sparkles.wired_bench.engines.shim_support : shimError;

        lines ~= (() @trusted => shimError(jb_cpp_versions()))();
    }
    version (BenchRust)
    {
        import sparkles.bench_shim : jb_rs_versions;
        import sparkles.wired_bench.engines.shim_support : shimError;

        lines ~= (() @trusted => shimError(jb_rs_versions()))();
    }
    return lines;
}
