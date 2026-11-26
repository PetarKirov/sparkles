/**
Platforms and the toolchain table (build-graph SPEC §8.1, BGH1 and BGH4).

The graph names platforms as nixpkgs does: an action runs on the build
platform, and a variant's output runs on its host platform, each named by
its nixpkgs `config`, the LLVM target triple. The toolchain of every host a
run may build for comes from one table, which the repository's Nix shells
generate from the same `pkgsCross` and toolchain packages its Nix builds use
and export as `$SPARKLES_TOOLCHAINS`:

---
{
    "build": "x86_64-unknown-linux-gnu",
    "hosts": {
        "x86_64-unknown-linux-gnu": {
            "system": "x86_64-linux", "canExecute": true,
            "ldc": "/nix/store/…-ldc/bin/ldc2", "dmd": "/nix/store/…-dmd/bin/dmd",
            "cc": "/nix/store/…/bin/cc", "archiver": "/nix/store/…/bin/ar",
            "linker": "/nix/store/…-lld/bin/ld.lld"
        },
        "wasm32-unknown-wasip1": {
            "system": "wasm32-wasip1", "canExecute": false, "triple": "wasm32-unknown-wasip1",
            "ldc": "/nix/store/…-ldc-sparkles/bin/ldc2", "archiver": "/nix/store/…/bin/llvm-ar",
            "emulator": "/nix/store/…-wasmtime/bin/wasmtime"
        }
    }
}
---

Each entry's fields are data, so lowering has one form for every host: an
empty `triple` is the compiler's default, an empty `cc` or `linker` leaves
the compiler's configuration to choose (LDC's selects the WASI and NDK
drivers by triple), and an empty `pkgConfigLibdir` on the build platform
means the environment's `pkg-config` search path.
*/
module sparkles.build_graph.platforms;

import std.json : JSONType, JSONValue, parseJSON;

import sparkles.base.expected : Expected, err, ok;

@safe:

/// A platform, as nixpkgs elaborates its `config` (BGH1).
struct Platform
{
    string config;   /// nixpkgs `config`, the LLVM target triple: the platform's name
    string system;   /// Nix's `system` double (`wasm32-wasip1`), where a derivation runs
    /// The triple the D compiler takes (`-mtriple=`): its own spelling of
    /// `config` (`aarch64--linux-android` for Android's), empty for the
    /// compiler's default.
    string triple;
    /// Whether the build platform runs this platform's programs, as nixpkgs'
    /// `buildPlatform.canExecute hostPlatform` answers.
    bool canExecute;
}

/// One host platform's toolchain (BGH4): its tools by absolute path, empty
/// where the entry leaves the choice to the compiler.
struct HostToolchain
{
    Platform platform; ///
    string ldc;        /// the LDC that compiles for this host
    string dmd;        /// a DMD for it, when there is one (the build platform's)
    string cc;         /// the C compiler driver LDC is given (`-gcc=`)
    string archiver;   /// an `ar` that archives this host's objects
    string linker;     /// the linker LDC is given (`--linker=`)
    /// The `pkg-config` search directory of this host's libraries
    /// (`PKG_CONFIG_LIBDIR`); empty on the build platform for the
    /// environment's search path, and elsewhere for none (BGH6).
    string pkgConfigLibdir;
    string emulator;   /// what runs this host's programs on the build platform, when anything does
    /// The variables a recipe built for this host may read, with their values
    /// (`SPARKLES_ANDROID_MIN_SDK`, the API level Android's links target).
    string[string] environment;
}

/// The toolchain table (BGH4): the build platform, and every host a run may
/// build for, by `config`.
struct ToolchainTable
{
    string build;                 /// the build platform's `config`
    HostToolchain[string] hosts;  /// by `config`, the build platform's included
    /// The packages whose default configuration builds for another host, and
    /// those hosts, by package name (the WebAssembly modules).
    string[][string] packages;

    /// The entry of `config`, or null when the table has none.
    const(HostToolchain)* host(string config) const pure nothrow => config in hosts;

    /// The build platform's entry; a parsed table always has one.
    ref const(HostToolchain) buildHost() const pure nothrow => hosts[build];

    /// The hosts the table names, sorted, for a refusal's message.
    string[] names() const pure nothrow
    {
        import std.algorithm.sorting : sort;

        auto all = hosts.keys;
        all.sort();
        return all;
    }
}

/// The table `json` holds, or why it is not one.
Expected!(ToolchainTable, string) parseToolchainTable(string json) @safe
{
    import std.conv : text;

    JSONValue root;
    try
        root = parseJSON(json);
    catch (Exception e)
        return err!ToolchainTable(text("not JSON: ", e.msg));
    if (root.type != JSONType.object)
        return err!ToolchainTable("not an object");
    string str(const JSONValue o, string key)
    {
        if (auto v = key in o.objectNoRef)
            return v.type == JSONType.string ? v.str : null;
        return null;
    }
    ToolchainTable t;
    t.build = str(root, "build");
    const hosts = "hosts" in root.objectNoRef;
    if (!t.build.length || hosts is null || hosts.type != JSONType.object)
        return err!ToolchainTable("it needs a `build` platform and a `hosts` object");
    foreach (config, ref e; hosts.objectNoRef)
    {
        if (e.type != JSONType.object)
            return err!ToolchainTable(text(config, ": not an object"));
        HostToolchain h;
        h.platform.config = config;
        h.platform.system = str(e, "system");
        h.platform.triple = str(e, "triple");
        if (auto can = "canExecute" in e.objectNoRef)
            h.platform.canExecute = can.type == JSONType.true_;
        h.ldc = str(e, "ldc");
        h.dmd = str(e, "dmd");
        h.cc = str(e, "cc");
        h.archiver = str(e, "archiver");
        h.linker = str(e, "linker");
        h.pkgConfigLibdir = str(e, "pkgConfigLibdir");
        h.emulator = str(e, "emulator");
        if (auto vars = "environment" in e.objectNoRef)
            if (vars.type == JSONType.object)
                foreach (name, ref value; vars.objectNoRef)
                    if (value.type == JSONType.string)
                        h.environment[name] = value.str;
        if (!h.platform.system.length || !h.ldc.length || !h.archiver.length)
            return err!ToolchainTable(text(config, ": an entry needs `system`, `ldc` and `archiver`"));
        t.hosts[config] = h;
    }
    if (auto packages = "packages" in root.objectNoRef)
        if (packages.type == JSONType.object)
            foreach (name, ref hostsOf; packages.objectNoRef)
                if (hostsOf.type == JSONType.array)
                    foreach (h; hostsOf.arrayNoRef)
                        if (h.type == JSONType.string)
                            t.packages[name] ~= h.str;
    if (t.build !in t.hosts)
        return err!ToolchainTable(text("the build platform ", t.build, " has no entry"));
    if (!t.hosts[t.build].platform.canExecute)
        return err!ToolchainTable(text("the build platform ", t.build, " must execute its own programs"));
    // Another host's compiles and links name its triple, which the platform
    // probe uses too: one target for resolution and lowering (BGH5).
    foreach (config; t.names)
        if (config != t.build && !t.hosts[config].platform.triple.length)
            return err!ToolchainTable(text(config, ": another host's entry needs its `triple`"));
    return ok(t);
}

///
@("build_graph.platforms.parseToolchainTable")
@safe unittest
{
    const t = parseToolchainTable(`{
        "build": "x86_64-unknown-linux-gnu",
        "hosts": {
            "x86_64-unknown-linux-gnu": {"system": "x86_64-linux", "canExecute": true,
                "ldc": "/s/ldc/bin/ldc2", "dmd": "/s/dmd/bin/dmd", "cc": "/s/cc/bin/cc",
                "archiver": "/s/bin/ar", "linker": "/s/lld/bin/ld.lld"},
            "wasm32-unknown-wasip1": {"system": "wasm32-wasip1", "canExecute": false,
                "triple": "wasm32-unknown-wasip1", "ldc": "/s/wasi/bin/ldc2",
                "archiver": "/s/llvm/bin/llvm-ar", "emulator": "/s/wasmtime/bin/wasmtime"}
        },
        "packages": {"text-wasm": ["wasm32-unknown-wasip1", "wasm32-unknown-wasip2"]}
    }`);
    assert(t.hasValue, t.hasError ? t.error : null);
    assert(t.value.buildHost.platform == Platform("x86_64-unknown-linux-gnu", "x86_64-linux", null, true));
    assert(t.value.buildHost.linker == "/s/lld/bin/ld.lld");
    const wasi = t.value.host("wasm32-unknown-wasip1");
    assert(wasi !is null && wasi.platform.triple == "wasm32-unknown-wasip1" && !wasi.platform.canExecute);
    assert(wasi.cc is null && wasi.linker is null && wasi.pkgConfigLibdir is null,
        "left to the compiler's configuration");
    assert(t.value.host("aarch64-unknown-linux-android") is null);
    assert(t.value.names == ["wasm32-unknown-wasip1", "x86_64-unknown-linux-gnu"]);
    assert(t.value.packages.length == 1
        && t.value.packages["text-wasm"] == ["wasm32-unknown-wasip1", "wasm32-unknown-wasip2"]);
}

/// A table without its build platform, with an entry missing a tool, or with
/// another host's entry missing its triple, is refused with the reason.
@("build_graph.platforms.parseToolchainTable.refusals")
@safe unittest
{
    import std.algorithm.searching : canFind;

    assert(parseToolchainTable("[").error.canFind("not JSON"));
    assert(parseToolchainTable(`{"build": "a", "hosts": {}}`).error.canFind("has no entry"));
    assert(parseToolchainTable(`{"build": "a", "hosts": {"a": {"system": "a", "ldc": "/l"}}}`)
        .error.canFind("needs `system`, `ldc` and `archiver`"));
    assert(parseToolchainTable(`{"build": "a", "hosts": {"a": {"system": "a", "ldc": "/l", "archiver": "/r"}}}`)
        .error.canFind("must execute its own programs"));
    assert(parseToolchainTable(`{"build": "a", "hosts": {"a": {"system": "a", "canExecute": true, "ldc": "/l",
        "archiver": "/r"}, "w": {"system": "w", "ldc": "/l", "archiver": "/r"}}}`).error.canFind("w: another host's entry needs its `triple`"));
}
