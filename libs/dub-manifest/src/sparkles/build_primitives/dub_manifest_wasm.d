/++
The recipe schema on WebAssembly (docs/specs/wired/wasm, WW15): SDL, JSON and
embedded recipes decoded, and rejected, under `dub test :dub-manifest --
--wasm` as a `wasm32-unknown-wasip1` program and natively. These are the
reads the Nix module makes.

The tests use the public API only, each importing what it needs, as an
extracted test sees nothing of the module it was written in.
+/
module sparkles.build_primitives.dub_manifest_wasm;

import sparkles.test_runner.attributes : wasm;

@("build_primitives.dub_manifest.wasm.sdl") @wasm
@safe unittest
{
    import sparkles.build_primitives.dub_manifest : parseDubManifest;

    const m = parseDubManifest("name \"p\"\ndependency \"sparkles:base\" path=\"../..\"\n"
        ~ "dflags \"-O\" platform=\"ldc\"\nconfiguration \"library\" {\n"
        ~ "    targetType \"library\"\n    subConfiguration \"sparkles:base\" \"library\"\n}\n"
        ~ "subPackage \"libs/x\"\n", "dub.sdl");
    assert(m.hasValue, m.error.toString);
    assert(m.value.name == "p");
    assert(m.value.dependencies[0].name == "sparkles:base" && m.value.dependencies[0].path == "../..");
    assert(m.value.dflags[0].platform == "ldc" && m.value.dflags[0].values == ["-O"]);
    assert(m.value.configurations[0].subConfigurations[0].configuration == "library");
    assert(m.value.subPackages[0].path == "libs/x");
}

@("build_primitives.dub_manifest.wasm.jsonAndEmbedded") @wasm
@safe unittest
{
    import sparkles.build_primitives.dub_manifest : parseDubRecipeText;

    const json = parseDubRecipeText(`{"name": "j", "dependencies": {"x": "~>1.2"},`
        ~ ` "dflags-ldc": ["-O"]}`, "dub.json");
    assert(json.hasValue, json.error.toString);
    assert(json.value.dependencies[0].version_ == "~>1.2");
    assert(json.value.dflags[0].platform == "ldc");

    const embedded = parseDubRecipeText("#!/usr/bin/env dub\n/+ dub.sdl:\n    name \"e\"\n+/\n"
        ~ "void main() {}\n", "e.d");
    assert(embedded.hasValue && embedded.value.name == "e");
}

@("build_primitives.dub_manifest.wasm.rejects") @wasm
@safe unittest
{
    import sparkles.build_primitives.dub_manifest : parseDubManifest, parseDubJsonManifest;
    import sparkles.wired.sdl : SdlErrorCode;

    const unknown = parseDubManifest("name \"x\"\ntargetTyp \"library\"\n", "dub.sdl");
    assert(unknown.hasError && unknown.error.code == SdlErrorCode.unknownMember);
    assert(unknown.error.startPosition.line == 2);
    assert(parseDubManifest("name 42\n", "dub.sdl").hasError, "a number for a string");
    assert(parseDubJsonManifest(`{"name": "j",`, "dub.json").hasError);
}
