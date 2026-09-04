/++
Dispatch `ci` onto `{aarch64,x86_64}-linux` from macOS.

Nix on this machine can $(I substitute) Linux store paths from the binary
cache, but it cannot $(I execute) them: they are ELF. Apple `container` can —
each container is a lightweight Linux VM, and bind-mounting `/nix/store`
makes those ELFs runnable. That is the path this module takes.

The Determinate native Linux builder is configured on this host
(`external-builders` → `determinate-nixd builder`) but feature-gated as of
the session that landed this (HTTP 400: "not currently available"). When
it is on, `nix build .#packages.aarch64-linux.ci` can $(I compile) missing
paths too; until then this dispatcher disables `external-builders` so a
gated VM is not a hard failure, and relies on substitutes.

$(B What runs in the guest is CI's dev shell, not just the `ci` binary.)
`ci --test` links raylib, tree-sitter, libghostty-vt, SDL3 and the rest of
`devShells.ci`'s packages, so the guest needs that whole environment. The
shell's output (`nix-shell-env`) is a derivation no cache holds for every
system, and there is no builder to make it — but it is a $(I trivial)
derivation: its inputs are the packages, and its environment is data
`nix derivation show` prints without building anything. So the dispatcher
enters the shell the way `nix-shell` does, inside the container: export the
derivation's environment, `source $stdenv/setup` with the store's own bash,
run the `shellHook`, then exec `ci`. Every setup hook (pkg-config, the cc
wrapper) runs exactly as it does on the CI runner.

Substitutes exist only for revisions CI has built, and the shell's inputs
include `packages.ci`, whose source is `apps/ci/src` plus its transitive
`libs/*/src` closure — so an edit anywhere in that closure turns the working
tree's shell into one no cache has. The dispatcher therefore instantiates the
shell at a $(I git revision), not from the tree: `HEAD`, then the merge-base
with `origin/main`, then `origin/main`, unless `--host-ci-rev` names one.
The tests still run against the bind-mounted working tree; only the
environment is from the committed revision.

See `docs/research/linux-on-macos/`.
+/
module linux_host;

import std.algorithm : canFind, sort, startsWith, uniq;
import std.array : array;
import std.conv : to;
import std.exception : enforce;
import std.json : JSONValue, parseJSON, JSONType;
import std.process : environment, execute, spawnProcess, wait;
import std.stdio : writeln;
import std.string : lineSplitter, strip;

import sparkles.base.hw_caps : hwMemoryBytes, hwParallelism;
import sparkles.base.logger : error, info, warning;

/// Nix systems this dispatcher can target from macOS.
immutable linuxHostSystems = ["aarch64-linux", "x86_64-linux"];

/// How a Linux-on-macOS backend presented itself.
enum BackendState : ubyte
{
    available, /// it can be used
    gated,     /// configured, but the vendor has not turned it on
    absent,    /// not installed / not configured
    error,     /// installed, but a probe failed for another reason
}

/// One backend the probe reports.
struct BackendReport
{
    string name;        /// stable id (`determinate-native-builder`)
    BackendState state;
    string detail;      /// one-line why
}

/// The container-side identity of a Nix Linux system.
struct LinuxHostTarget
{
    string nixSystem;      /// `aarch64-linux` / `x86_64-linux`
    string containerArch;  /// Apple `container --arch` value (`arm64` / `amd64`)
    bool rosetta;          /// x86_64-linux on Apple silicon needs `--rosetta`
}

/// A git revision the Linux shell may be instantiated at, and why it was tried.
struct LinuxCiRevision
{
    string rev;    /// full SHA
    string label;  /// `HEAD`, `merge-base origin/main`, `origin/main`, `--host-ci-rev`
}

/// `devShells.<system>.ci` as `nix derivation show` describes it: enough to
/// enter it without building it.
struct ShellDerivation
{
    string drvPath;
    string builder;      /// the store bash the shell's stdenv runs
    string[string] env;  /// every environment attribute of the derivation
}

/// What the guest needs from the host: the shell, and where `ci` is in it.
struct LinuxHostEnv
{
    ShellDerivation shell;
    string ci;             /// `packages.<system>.ci`, also on the shell's PATH
    LinuxCiRevision from;  /// the git revision the shell was instantiated at
}

/// Guest VM size for one `container run`: every allowed CPU, half the RAM.
struct LinuxHostSize
{
    uint cpus;
    uint memoryGiB;
}

/// Size the guest from the host: the test runner wants every CPU the host
/// will give it, and half the RAM leaves macOS and the VirtioFS daemon room.
LinuxHostSize linuxHostSizeFor(uint hostCpus, ulong hostMemoryBytes) @safe pure nothrow @nogc
{
    enum ulong gib = 1024UL * 1024 * 1024;
    const half = hostMemoryBytes / 2 / gib;
    return LinuxHostSize(
        hostCpus < 2 ? 2 : hostCpus,
        cast(uint) (half < 4 ? 4 : half > 64 ? 64 : half));
}

@("linux_host.linuxHostSizeFor.halvesAndClamps")
@safe pure nothrow @nogc unittest
{
    enum ulong gib = 1024UL * 1024 * 1024;
    assert(linuxHostSizeFor(14, 36 * gib) == LinuxHostSize(14, 18));
    assert(linuxHostSizeFor(1, 4 * gib) == LinuxHostSize(2, 4));
    assert(linuxHostSizeFor(64, 512 * gib) == LinuxHostSize(64, 64));
}

/// The pure-git flake reference for a revision of a local checkout.
/// Pinning `rev` is what makes the reference independent of the dirty tree.
string flakeRefAt(string repoTop, string rev) @safe pure
    => "git+file://" ~ repoTop ~ "?rev=" ~ rev;

@("linux_host.flakeRefAt")
@safe pure unittest
{
    assert(flakeRefAt("/src/sparkles", "abc")
        == "git+file:///src/sparkles?rev=abc");
}

/// Parse a Nix system the dispatcher accepts.
LinuxHostTarget parseLinuxHostTarget(string nixSystem) @safe pure
{
    if (nixSystem == "aarch64-linux")
        return LinuxHostTarget(nixSystem, "arm64", false);
    if (nixSystem == "x86_64-linux")
        return LinuxHostTarget(nixSystem, "amd64", true);
    throw new Exception(
        "unsupported --host-system '" ~ nixSystem
            ~ "'; expected aarch64-linux or x86_64-linux");
}

/// True when this process is already that Nix system, so dispatch is a no-op.
bool alreadyOnHostSystem(string nixSystem) @safe pure nothrow @nogc
{
    version (linux)
    {
        version (AArch64)
            return nixSystem == "aarch64-linux";
        else version (X86_64)
            return nixSystem == "x86_64-linux";
        else
            return false;
    }
    else
        return false;
}

/**
Strip `--host-system` / `--host-ci-rev` / `--linux-host-probe` from an argv
so the inner Linux `ci` does not try to dispatch again (and so a cached Linux
`ci` that does not yet know these flags is not fed them).
*/
string[] stripHostSystemArgs(in string[] args) @safe pure
{
    string[] outArgs;
    outArgs.reserve(args.length);
    for (size_t i = 0; i < args.length; ++i)
    {
        const a = args[i];
        if (a == "--linux-host-probe")
            continue;
        if (a == "--host-system" || a == "--host-ci-rev")
        {
            if (i + 1 < args.length)
                ++i;
            continue;
        }
        if (a.startsWith("--host-system=") || a.startsWith("--host-ci-rev="))
            continue;
        outArgs ~= a;
    }
    return outArgs;
}

/// Last `/nix/store/...` lines of `nix build --print-out-paths` stdout.
/// Nix also prints "Using saved setting..." on stdout; those are not paths.
string[] storePathsFromNixStdout(string stdoutText) @safe pure
{
    string[] paths;
    foreach (line; stdoutText.lineSplitter)
    {
        const t = line.strip;
        if (t.startsWith("/nix/store/"))
            paths ~= t.idup;
    }
    return paths;
}

/// Classify a failed Linux `nix build` when `external-builders` is on.
BackendState classifyDeterminateBuilderFailure(string stderrText) @safe pure
{
    if (stderrText.canFind("The Native Linux Builder is not currently available"))
        return BackendState.gated;
    if (stderrText.canFind("failed to set up Native Linux Builder"))
        return BackendState.gated;
    if (stderrText.canFind("platform mismatch"))
        return BackendState.absent;
    return BackendState.error;
}

/// `container --arch` / `--rosetta` flags for a target.
string[] containerArchFlags(LinuxHostTarget target) @safe pure
{
    if (target.rosetta)
        return ["--arch", target.containerArch, "--rosetta"];
    return ["--arch", target.containerArch];
}

/// Parse `container system status` table output.
bool containerStatusIsRunning(string statusText) @safe pure
{
    foreach (line; statusText.lineSplitter)
    {
        const t = line.strip;
        if (t.startsWith("status") && t.canFind("running"))
            return true;
    }
    return false;
}

@("linux_host.parseLinuxHostTarget.aarch64")
@safe pure unittest
{
    const t = parseLinuxHostTarget("aarch64-linux");
    assert(t.containerArch == "arm64");
    assert(!t.rosetta);
}

@("linux_host.parseLinuxHostTarget.x86_64")
@safe pure unittest
{
    const t = parseLinuxHostTarget("x86_64-linux");
    assert(t.containerArch == "amd64");
    assert(t.rosetta);
}

@("linux_host.parseLinuxHostTarget.rejectsDarwin")
@safe pure unittest
{
    bool threw;
    try
        parseLinuxHostTarget("aarch64-darwin");
    catch (Exception)
        threw = true;
    assert(threw);
}

@("linux_host.stripHostSystemArgs.pairAndEquals")
@safe pure unittest
{
    const stripped = stripHostSystemArgs([
        "ci", "--test", "--host-system", "aarch64-linux", "--fail-fast",
        "--linux-host-probe", "--host-system=x86_64-linux", "--no-coverage",
        "--host-ci-rev", "origin/main", "--host-ci-rev=HEAD",
    ]);
    assert(stripped == ["ci", "--test", "--fail-fast", "--no-coverage"]);
}

@("linux_host.storePathsFromNixStdout.ignoresSavedSettings")
@safe pure unittest
{
    const paths = storePathsFromNixStdout(
        "Using saved setting for 'extra-substituters = https://example'\n"
            ~ "/nix/store/abc-ci-0.1.0\n"
            ~ "/nix/store/def-ts-grammars\n");
    assert(paths.length == 2);
    assert(paths[0].canFind("-ci-"));
    assert(paths[1].canFind("-ts-grammars"));
}

@("linux_host.classifyDeterminateBuilderFailure.gated")
@safe pure unittest
{
    assert(classifyDeterminateBuilderFailure(
            "Error: failed to set up Native Linux Builder\n"
                ~ "HTTP status code 400 Bad Request, reply: "
                ~ "The Native Linux Builder is not currently available. "
                ~ "Contact support@determinate.systems")
            == BackendState.gated);
}

@("linux_host.classifyDeterminateBuilderFailure.platformMismatch")
@safe pure unittest
{
    assert(classifyDeterminateBuilderFailure(
            "error: Cannot build '/nix/store/x-nix-shell-env.drv'.\n"
                ~ "       Reason: platform mismatch\n"
                ~ "       Required system: 'aarch64-linux'\n"
                ~ "       Current system: 'aarch64-darwin'\n")
            == BackendState.absent);
}

@("linux_host.containerArchFlags.rosettaOnlyOnX64")
@safe pure unittest
{
    assert(containerArchFlags(parseLinuxHostTarget("aarch64-linux"))
            == ["--arch", "arm64"]);
    assert(containerArchFlags(parseLinuxHostTarget("x86_64-linux"))
            == ["--arch", "amd64", "--rosetta"]);
}

@("linux_host.containerStatusIsRunning.table")
@safe pure unittest
{
    assert(containerStatusIsRunning(
            "FIELD              VALUE\nstatus             running\n"));
    assert(!containerStatusIsRunning(
            "FIELD              VALUE\nstatus             stopped\n"));
}

// === The shell derivation ===

/**
Parse `nix derivation show` output for one derivation.

Nix 2.x prints `{ "<drv>": {…} }`; Nix ≥ 2.29 / Determinate 3.x wrap it as
`{ "version": 4, "derivations": { "<drv>": {…} } }`. Both are accepted.
*/
ShellDerivation parseShellDerivation(string json) @safe
{
    const root = parseJSON(json);
    const table = "derivations" in root.objectNoRef ? root["derivations"] : root;
    enforce(table.type == JSONType.object && table.objectNoRef.length == 1,
        "nix derivation show: expected exactly one derivation");
    ShellDerivation d;
    foreach (drvPath, drv; table.objectNoRef)
    {
        // The v4 layout keys by bare `<hash>-<name>.drv`; older ones by full path.
        d.drvPath = drvPath.startsWith("/nix/store/") ? drvPath : "/nix/store/" ~ drvPath;
        d.builder = drv["builder"].str;
        foreach (name, value; drv["env"].objectNoRef)
            if (value.type == JSONType.string)
                d.env[name] = value.str;
    }
    return d;
}

@("linux_host.parseShellDerivation.bothLayouts")
@safe unittest
{
    enum inner = `{"/nix/store/x-nix-shell.drv": {"builder": "/nix/store/b-bash/bin/bash",
        "env": {"stdenv": "/nix/store/s-stdenv-linux", "shellHook": "export A=1", "out": "/nix/store/o-nix-shell"}}}`;
    const flat = parseShellDerivation(inner);
    assert(flat.drvPath == "/nix/store/x-nix-shell.drv");
    assert(parseShellDerivation(`{"version": 4, "derivations": {"x-nix-shell.drv": {"builder": "b", "env": {}}}}`)
        .drvPath == "/nix/store/x-nix-shell.drv");
    assert(flat.builder == "/nix/store/b-bash/bin/bash");
    assert(flat.env["stdenv"] == "/nix/store/s-stdenv-linux");

    const wrapped = parseShellDerivation(`{"version": 4, "derivations": ` ~ inner ~ `}`);
    assert(wrapped.env == flat.env);
}

/**
Every `/nix/store/<hash>-<name>` referenced by a derivation's environment,
truncated to the top-level store path and deduplicated, minus `.drv` files
and minus the derivation's own outputs (those are what cannot be built).
Realizing these substitutes the shell's whole input closure.
*/
string[] shellInputStorePaths(in ShellDerivation d) @safe pure
{
    string[] outputs;
    foreach (name; ["out", "dev", "lib", "bin", "doc", "man"])
        if (auto p = name in d.env)
            outputs ~= *p;

    string[] found = storePathsIn(d.builder);
    foreach (_, value; d.env)
        found ~= storePathsIn(value);

    string[] keep;
    foreach (p; found.sort.uniq)
    {
        if (p.endsWith(".drv") || outputs.canFind(p))
            continue;
        keep ~= p;
    }
    return keep;
}

private bool endsWith(string s, string suffix) @safe pure nothrow @nogc
    => s.length >= suffix.length && s[$ - suffix.length .. $] == suffix;

/// Top-level store paths mentioned anywhere in a string, in order, with
/// duplicates. `/nix/store/<hash>-<name>/lib/x` yields the path up to `<name>`.
string[] storePathsIn(in char[] text) @safe pure
{
    enum prefix = "/nix/store/";
    string[] paths;
    size_t i = 0;
    while (true)
    {
        const at = indexOfFrom(text, prefix, i);
        if (at == size_t.max)
            break;
        size_t end = at + prefix.length;
        while (end < text.length && isStorePathNameChar(text[end]))
            ++end;
        if (end - (at + prefix.length) > 33) // hash + '-' + at least one char
            paths ~= text[at .. end].idup;
        i = end;
    }
    return paths;
}

private size_t indexOfFrom(in char[] haystack, string needle, size_t from) @safe pure nothrow @nogc
{
    if (needle.length == 0 || haystack.length < needle.length)
        return size_t.max;
    foreach (i; from .. haystack.length - needle.length + 1)
        if (haystack[i .. i + needle.length] == needle)
            return i;
    return size_t.max;
}

private bool isStorePathNameChar(char c) @safe pure nothrow @nogc
    => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
        || c == '-' || c == '_' || c == '.' || c == '+';

@("linux_host.storePathsIn.truncatesAndFindsAll")
@safe pure unittest
{
    const paths = storePathsIn(
        "export LIBRARY_PATH=\"/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-elfutils-0.195/lib:"
            ~ "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-libpfm-4.13.0/lib\"\n"
            ~ "/nix/store/cccccccccccccccccccccccccccccccc-mesa-25.0 plain");
    assert(paths == [
        "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-elfutils-0.195",
        "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-libpfm-4.13.0",
        "/nix/store/cccccccccccccccccccccccccccccccc-mesa-25.0",
    ]);
    assert(storePathsIn("no store path here").length == 0);
}

@("linux_host.shellInputStorePaths.dropsOutputsAndDrvs")
@safe pure unittest
{
    ShellDerivation d;
    d.builder = "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-bash-5.3/bin/bash";
    d.env["out"] = "/nix/store/oooooooooooooooooooooooooooooooo-nix-shell";
    d.env["stdenv"] = "/nix/store/ssssssssssssssssssssssssssssssss-stdenv-linux";
    d.env["nativeBuildInputs"] =
        "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-ci-0.1.0 "
        ~ "/nix/store/ssssssssssssssssssssssssssssssss-stdenv-linux";
    d.env["shellHook"] = "export OUT=/nix/store/oooooooooooooooooooooooooooooooo-nix-shell/x;"
        ~ " drv=/nix/store/dddddddddddddddddddddddddddddddd-foo.drv";
    assert(shellInputStorePaths(d) == [
        "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-ci-0.1.0",
        "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-bash-5.3",
        "/nix/store/ssssssssssssssssssssssssssssssss-stdenv-linux",
    ]);
}

/**
The script the guest runs: enter the dev shell the way `nix-shell` does,
then exec `ci`.

Mirrors nix's `nix-shell` rc — export the derivation's environment, set the
temp/build variables a builder expects, `source $stdenv/setup` (which runs
every setup hook and builds `PATH`, `PKG_CONFIG_PATH`, the cc-wrapper flags),
restore the container's own `PATH` behind it, relax the `set -eu` the setup
script turned on, `runHook shellHook`, and go. The guest's tmp is the
container's own, not the host's.

Params:
    d = the shell derivation
    ci = the Linux `ci` to exec once the shell is entered
    buildCores = `NIX_BUILD_CORES` for the shell
*/
string renderGuestEntry(in ShellDerivation d, string ci, uint buildCores) @safe pure
{
    string s = "#!" ~ d.builder ~ "\n";
    s ~= "# generated by `ci --host-system`: enter devShells.ci as nix-shell would, then exec ci\n";
    foreach (name; d.env.keys.sort)
    {
        if (name == "__structuredAttrs" || name == "args" || name == "builder")
            continue;
        s ~= "export " ~ name ~ "=" ~ shellQuote(d.env[name]) ~ "\n";
    }
    s ~= "export IN_NIX_SHELL=impure\n";
    s ~= "export NIX_BUILD_TOP=/tmp TMPDIR=/tmp TEMPDIR=/tmp TMP=/tmp TEMP=/tmp\n";
    s ~= "export NIX_STORE=/nix/store\n";
    s ~= "export NIX_BUILD_CORES=" ~ buildCores.to!string ~ "\n";
    s ~= "export HOME=/tmp\n";
    s ~= "p=\"$PATH\"\n";
    s ~= "dontAddDisableDepTrack=1\n";
    s ~= "[ -e \"$stdenv/setup\" ] && source \"$stdenv/setup\"\n";
    s ~= "PATH=\"$PATH:$p\"; unset p\n";
    s ~= "set +e +u +o pipefail\n";
    s ~= "if [ \"$(type -t runHook)\" = function ]; then runHook shellHook; fi\n";
    s ~= "unset NIX_ENFORCE_PURITY\n";
    s ~= "exec " ~ shellQuote(ci ~ "/bin/ci") ~ " \"$@\"\n";
    return s;
}

/// POSIX single-quote escaping: safe for any byte sequence.
string shellQuote(string s) @safe pure
{
    string q = "'";
    foreach (c; s)
        q ~= c == '\'' ? "'\\''" : [c];
    return q ~ "'";
}

@("linux_host.shellQuote")
@safe pure unittest
{
    assert(shellQuote("plain") == "'plain'");
    assert(shellQuote("it's $HOME") == `'it'\''s $HOME'`);
}

@("linux_host.renderGuestEntry.entersTheShellThenExecs")
@safe pure unittest
{
    ShellDerivation d;
    d.builder = "/nix/store/b-bash/bin/bash";
    d.env["stdenv"] = "/nix/store/s-stdenv-linux";
    d.env["shellHook"] = "export DC='ldc2'";
    d.env["builder"] = d.builder;
    const s = renderGuestEntry(d, "/nix/store/c-ci-0.1.0", 9);
    assert(s.startsWith("#!/nix/store/b-bash/bin/bash\n"));
    assert(s.canFind("export stdenv='/nix/store/s-stdenv-linux'\n"));
    assert(s.canFind(`export shellHook='export DC='\''ldc2'\'''` ~ "\n"));
    assert(!s.canFind("export builder="));
    assert(s.canFind("export NIX_BUILD_CORES=9\n"));
    assert(s.canFind("source \"$stdenv/setup\"\n"));
    assert(s.canFind("runHook shellHook"));
    assert(s.canFind("exec '/nix/store/c-ci-0.1.0/bin/ci' \"$@\"\n"));
    // the shell's environment is exported before setup runs
    import std.string : indexOf;
    assert(s.indexOf("export stdenv=") < s.indexOf("source \"$stdenv/setup\""));
}

// === Probe ===

/// Probe every backend we know about and print a report. Returns 0 always:
/// a missing backend is information, not a failure of the probe itself.
int runLinuxHostProbe()
{
    foreach (r; collectBackendReports())
    {
        const label = backendStateLabel(r.state);
        writeln(r.name, ": ", label);
        if (r.detail.length)
            writeln("  ", r.detail);
    }
    return 0;
}

// === Dispatch ===

/**
Dispatch the remaining `ci` argv onto `hostSystem` via Apple container.

Params:
    hostSystem = `aarch64-linux` / `x86_64-linux`
    args = this process's full argv; `--host-system` and `--host-ci-rev` are
        stripped before the inner `ci` sees it
    ciRev = a git revision to instantiate the Linux shell at, or empty to try
        `HEAD`, the merge-base with `origin/main`, then `origin/main`
*/
int runOnLinuxHost(string hostSystem, string[] args, string ciRev = null)
{
    LinuxHostTarget target;
    try
        target = parseLinuxHostTarget(hostSystem);
    catch (Exception e)
    {
        error(i"$(e.msg)");
        return 1;
    }

    const repoTop = gitOutput(["rev-parse", "--show-toplevel"]);
    if (repoTop.length == 0)
    {
        error(i"--host-system needs a git checkout: the Linux dev shell is instantiated at a revision");
        return 1;
    }

    LinuxCiRevision[] candidates;
    if (ciRev.length)
    {
        const full = gitOutput(["rev-parse", "--verify", ciRev ~ "^{commit}"]);
        if (full.length == 0)
        {
            error(i"--host-ci-rev $(ciRev) is not a commit in this repository");
            return 1;
        }
        candidates = [LinuxCiRevision(full, "--host-ci-rev " ~ ciRev)];
    }
    else
        candidates = candidateCiRevisions();

    info(i"realizing devShells.$(hostSystem).ci (substitutes; no gated builder)");
    LinuxHostEnv env;
    try
        env = realizeLinuxHostEnv(hostSystem, repoTop, candidates);
    catch (Exception e)
    {
        error(i"could not realize devShells.$(hostSystem).ci: $(e.msg)");
        return 1;
    }
    info(i"Linux dev shell from $(env.from.label) ($(env.from.rev[0 .. 12])): $(env.shell.drvPath)");

    if (ensureContainerRunning() != 0)
        return 1;

    import std.file : getcwd, mkdirRecurse, rmdirRecurse, write;
    import std.path : buildPath;

    const size = linuxHostSizeFor(hwParallelism(), hwMemoryBytes());

    // The entry script is a few KiB of exports — too big for `--env`, so it
    // travels as a file in a host directory the guest mounts at the same path.
    const guestDir = guestScratchDir(hostSystem);
    mkdirRecurse(guestDir);
    scope (exit)
        rmdirRecurse(guestDir);
    const entry = buildPath(guestDir, "enter.sh");
    write(entry, renderGuestEntry(env.shell, env.ci, size.cpus));
    makeExecutable(entry);

    // A linked worktree's `.git` is a file naming the main repository's git
    // dir, which the inner `ci`'s `git rev-parse --show-toplevel` and dub's
    // `git describe` must be able to read.
    const gitCommonDir = gitOutput(["rev-parse", "--path-format=absolute", "--git-common-dir"]);
    auto cmd = containerRunCommand(
        target, entry, args, repoTop, getcwd(), size, environment.get("DC", null),
        gitCommonDir);
    info(i"container run $(hostSystem): $(size.cpus) cpus, $(size.memoryGiB) GiB");
    auto pid = spawnProcess(cmd);
    return wait(pid);
}

/// A host directory under `/private/tmp` (a path both sides can name; macOS'
/// `$TMPDIR` lives under `/var/folders`, which the guest cannot mount by the
/// same name without resolving symlinks first).
private string guestScratchDir(string hostSystem)
{
    import std.process : thisProcessID;
    return "/private/tmp/sparkles-linux-host-" ~ hostSystem ~ "-" ~ thisProcessID.to!string;
}

private void makeExecutable(string path) @trusted
{
    import std.conv : octal;
    import std.file : getAttributes, setAttributes;
    setAttributes(path, getAttributes(path) | octal!755);
}

/**
The revisions worth trying, newest first. `HEAD` is right when the tree's
shell closure is unchanged since the last push CI built; the branch's
upstream is the last push itself; the merge-base is what main had when this
branch forked, which CI has certainly built; main itself is the freshest
cached shell when the branch is older than main. "Main" is `origin/main`,
or the remote's `HEAD` when that ref was never fetched, or a local `main`.
*/
LinuxCiRevision[] candidateCiRevisions()
{
    LinuxCiRevision[] out_;
    void add(string rev, string label)
    {
        if (rev.length == 0)
            return;
        foreach (c; out_)
            if (c.rev == rev)
                return;
        out_ ~= LinuxCiRevision(rev, label);
    }
    add(gitOutput(["rev-parse", "HEAD"]), "HEAD");
    add(gitOutput(["rev-parse", "@{upstream}"]), "@{upstream}");
    foreach (mainRef; ["origin/main", "origin/HEAD", "main"])
    {
        const main = gitOutput(["rev-parse", "--verify", "--quiet", mainRef ~ "^{commit}"]);
        if (main.length == 0)
            continue;
        add(gitOutput(["merge-base", "HEAD", main]), "merge-base " ~ mainRef);
        add(main, mainRef);
        break;
    }
    return out_;
}

private string gitOutput(string[] args)
{
    const r = execute(["git"] ~ args);
    return r.status == 0 ? r.output.strip.idup : null;
}

/**
`container run ...` argv: the store read-only, the checkout at its own path
so dub's absolute paths in `.dub/` and `build/` stay valid on both sides,
the entry script's directory, the main repository's git dir (read-only)
when the checkout is a linked worktree, and the inner `ci` argv with the
dispatch flags removed.

Only `DC` crosses from the host, and only as a bare compiler name — a Darwin
store path would be meaningless in the guest. CI's matrix sets it the same
way.
*/
string[] containerRunCommand(
    LinuxHostTarget target,
    string entryScript,
    string[] originalArgs,
    string repoTop,
    string workdir,
    LinuxHostSize size,
    string dc,
    string gitCommonDir = null,
) @safe pure
{
    import std.path : dirName;

    const inner = stripHostSystemArgs(originalArgs);
    const innerArgs = inner.length > 0 ? inner[1 .. $] : inner;

    string[] cmd = [
        "container", "run", "--rm",
        "--cpus", size.cpus.to!string,
        "--memory", size.memoryGiB.to!string ~ "G",
    ];
    cmd ~= containerArchFlags(target);
    cmd ~= [
        "--volume", "/nix/store:/nix/store:ro",
        "--volume", repoTop ~ ":" ~ repoTop,
        "--volume", entryScript.dirName ~ ":" ~ entryScript.dirName ~ ":ro",
        "--workdir", workdir,
    ];
    if (gitCommonDir.length && !gitCommonDir.startsWith(repoTop ~ "/"))
        cmd ~= ["--volume", gitCommonDir ~ ":" ~ gitCommonDir ~ ":ro"];
    if (dc.length && !dc.canFind("/"))
        cmd ~= ["--env", "DC=" ~ dc];
    // The image is a stub rootfs: the process is a store ELF, not alpine's.
    cmd ~= "alpine";
    cmd ~= entryScript;
    cmd ~= innerArgs;
    return cmd;
}

@("linux_host.containerRunCommand.mountsStoreRepoAndEntry")
@safe pure unittest
{
    const cmd = containerRunCommand(
        parseLinuxHostTarget("aarch64-linux"),
        "/private/tmp/sparkles-linux-host-1/enter.sh",
        ["ci", "--test", "--host-system", "aarch64-linux", "--fail-fast"],
        "/src",
        "/src/libs/base",
        LinuxHostSize(8, 16),
        "ldc2",
    );
    assert(cmd.canFind("--arch"));
    assert(cmd.canFind("arm64"));
    assert(!cmd.canFind("--rosetta"));
    assert(cmd.canFind("16G"));
    assert(cmd.canFind("/nix/store:/nix/store:ro"));
    assert(cmd.canFind("/src:/src"));
    assert(cmd.canFind("/private/tmp/sparkles-linux-host-1:/private/tmp/sparkles-linux-host-1:ro"));
    assert(cmd.canFind("/src/libs/base"));
    assert(cmd.canFind("DC=ldc2"));
    assert(cmd[$ - 3 .. $] == ["/private/tmp/sparkles-linux-host-1/enter.sh", "--test", "--fail-fast"]);
    assert(!cmd.canFind("--host-system"));
}

@("linux_host.containerRunCommand.linkedWorktreeMountsTheCommonGitDir")
@safe pure unittest
{
    const inMain = containerRunCommand(
        parseLinuxHostTarget("aarch64-linux"), "/private/tmp/x/enter.sh", ["ci", "--test"],
        "/src", "/src", LinuxHostSize(4, 8), "", "/src/.git");
    assert(!inMain.canFind("/src/.git:/src/.git:ro"));

    const linked = containerRunCommand(
        parseLinuxHostTarget("aarch64-linux"), "/private/tmp/x/enter.sh", ["ci", "--test"],
        "/src-wt", "/src-wt", LinuxHostSize(4, 8), "", "/src/.git");
    assert(linked.canFind("/src/.git:/src/.git:ro"));
}

@("linux_host.containerRunCommand.x86IsRosettaAndPathDcIsDropped")
@safe pure unittest
{
    const cmd = containerRunCommand(
        parseLinuxHostTarget("x86_64-linux"),
        "/private/tmp/x/enter.sh",
        ["ci", "--test"],
        "/src", "/src",
        LinuxHostSize(4, 8),
        "/nix/store/darwin-ldc/bin/ldc2",
    );
    assert(cmd.canFind("--rosetta"));
    assert(!cmd.canFind("--env"));
}

// === Backends ===

private BackendReport[] collectBackendReports()
{
    BackendReport[] reports;
    reports ~= probeDeterminateBuilder();
    reports ~= probeAppleContainer();
    reports ~= probeNixDarwinLinuxBuilder();
    reports ~= probeExtraPlatforms();
    return reports;
}

private string backendStateLabel(BackendState s) @safe pure nothrow @nogc
{
    final switch (s)
    {
        case BackendState.available: return "available";
        case BackendState.gated:     return "gated";
        case BackendState.absent:    return "absent";
        case BackendState.error:     return "error";
    }
}

private BackendReport probeDeterminateBuilder()
{
    BackendReport r;
    r.name = "determinate-native-builder";
    const which = execute(["sh", "-c", "command -v determinate-nixd"]);
    if (which.status != 0 || which.output.strip.length == 0)
    {
        r.state = BackendState.absent;
        r.detail = "determinate-nixd not on PATH";
        return r;
    }
    // A tiny uncached drv is the honest probe: config can list the builder
    // while the vendor still returns HTTP 400.
    const probe = execute([
        "nix", "build", "--no-link", "--print-out-paths",
        "--impure", "--expr",
        `{ pkgs ? builtins.getFlake "nixpkgs" }: pkgs.legacyPackages.aarch64-linux.runCommand "linux-host-probe" {} "uname -m > $out"`,
    ]);
    if (probe.status == 0)
    {
        r.state = BackendState.available;
        r.detail = probe.output.strip;
        return r;
    }
    // `execute` merges stdout+stderr into `.output`.
    r.state = classifyDeterminateBuilderFailure(probe.output);
    r.detail = firstInterestingLine(probe.output);
    return r;
}

private BackendReport probeAppleContainer()
{
    BackendReport r;
    r.name = "apple-container";
    const which = execute(["sh", "-c", "command -v container"]);
    if (which.status != 0 || which.output.strip.length == 0)
    {
        r.state = BackendState.absent;
        r.detail = "container CLI not on PATH";
        return r;
    }
    const ver = execute(["container", "--version"]);
    const status = execute(["container", "system", "status"]);
    if (status.status == 0 && containerStatusIsRunning(status.output))
    {
        r.state = BackendState.available;
        r.detail = ver.status == 0 ? ver.output.strip : "apiserver running";
        return r;
    }
    r.state = BackendState.absent;
    r.detail = "apiserver not running (`container system start`)";
    return r;
}

private BackendReport probeNixDarwinLinuxBuilder()
{
    BackendReport r;
    r.name = "nix-darwin-linux-builder";
    import std.file : exists;

    if (!exists("/etc/nix/machines"))
    {
        r.state = BackendState.absent;
        r.detail = "/etc/nix/machines is missing";
        return r;
    }
    r.state = BackendState.available;
    r.detail = "/etc/nix/machines present";
    return r;
}

private BackendReport probeExtraPlatforms()
{
    BackendReport r;
    r.name = "extra-platforms";
    const cfg = execute(["nix", "config", "show", "extra-platforms"]);
    r.detail = cfg.status == 0 ? cfg.output.strip : "(nix config show failed)";
    // extra-platforms on Darwin is typically x86_64-darwin (Rosetta), which
    // does not run Linux ELFs. Presence of a linux token would be news.
    if (r.detail.canFind("linux"))
        r.state = BackendState.available;
    else
        r.state = BackendState.absent;
    return r;
}

/**
The one line of a failed `nix build` worth showing.

Nix prints a bare `error:` header and then indents the cause several lines
below it, so "the first line that starts with `error:`" is the header and
says nothing. Prefer the vendor's reply (the text after `reply:`), then a
line that names the cause (the Determinate gate, a platform mismatch, Nix's
own `Reason:`), then an `error:` line that has text after the colon, then
the first line that is not build chatter.
*/
string firstInterestingLine(string text) @safe pure
{
    string cause, firstError, fallback;
    foreach (line; text.lineSplitter)
    {
        const t = line.strip;
        if (t.length == 0 || isNixBuildChatter(t))
            continue;
        const reply = indexOfFrom(t, "reply: ", 0);
        if (reply != size_t.max)
            return t[reply + "reply: ".length .. $].idup;
        if (cause.length == 0 && (t.canFind("Native Linux Builder")
                || t.canFind("platform mismatch") || t.startsWith("Reason:")))
            cause = t.idup;
        if (t.startsWith("error:") && t.length > "error:".length && firstError.length == 0)
            firstError = t.idup;
        if (fallback.length == 0 && !t.startsWith("error:"))
            fallback = t.idup;
    }
    if (cause.length)
        return cause;
    if (firstError.length)
        return firstError;
    return fallback.length ? fallback : text.strip.idup;
}

private bool isNixBuildChatter(in char[] t) @safe pure
{
    return t.startsWith("Using saved setting")
        || t.startsWith("this derivation will be built")
        || t.startsWith("these ") && t.canFind("will be fetched")
        || t.startsWith("copying path")
        || t.startsWith("building '")
        || t.startsWith("evaluation warning:");
}

@("linux_host.firstInterestingLine.prefersTheVendorReply")
@safe pure unittest
{
    const detail = firstInterestingLine(
        "this derivation will be built:\n"
            ~ "  /nix/store/x-linux-host-probe.drv\n"
            ~ "building '/nix/store/x-linux-host-probe.drv'...\n"
            ~ "error:\n"
            ~ "       … while waiting for the build environment for '…' to initialize\n"
            ~ "       Error: failed to set up Native Linux Builder\n"
            ~ "       Caused by:\n"
            ~ "           HTTP status code 400 Bad Request, reply: The Native Linux Builder "
            ~ "is not currently available. Contact support@determinate.systems\n");
    assert(detail.startsWith("The Native Linux Builder is not currently available"), detail);
}

@("linux_host.firstInterestingLine.platformMismatchReason")
@safe pure unittest
{
    const detail = firstInterestingLine(
        "error: Cannot build '/nix/store/x-nix-shell-env.drv'.\n"
            ~ "       Reason: platform mismatch\n"
            ~ "       Required system: 'aarch64-linux'\n");
    assert(detail == "Reason: platform mismatch", detail);
}

@("linux_host.firstInterestingLine.errorWithText")
@safe pure unittest
{
    assert(firstInterestingLine("Using saved setting for 'x'\nerror: flake 'y' does not provide attribute 'z'\n")
        == "error: flake 'y' does not provide attribute 'z'");
}

private int ensureContainerRunning()
{
    const status = execute(["container", "system", "status"]);
    if (status.status == 0 && containerStatusIsRunning(status.output))
        return 0;
    info(i"starting apple container apiserver");
    const start = execute([
        "container", "system", "start",
        "--enable-kernel-install",
        "--timeout", "120",
    ]);
    if (start.status != 0)
    {
        error(i"container system start failed: $(start.output.strip)");
        return 1;
    }
    return 0;
}

// === Realization ===

/**
Instantiate `devShells.<system>.ci` at the first candidate revision whose
inputs can all be substituted, and realize them.

`packages.<system>.ci` is tried first as a cheap gate (one small path): a
revision CI never built fails there with `platform mismatch`, and the next
one is tried. Then the shell derivation is instantiated — evaluation only,
no build — and every store path its environment names is realized. Any
other failure (a flake that does not evaluate, no network) is reported for
the last candidate rather than hidden behind a stale fallback.
*/
private LinuxHostEnv realizeLinuxHostEnv(
    string system, string repoTop, LinuxCiRevision[] candidates)
{
    enforce(candidates.length > 0, "no git revision to instantiate the Linux dev shell at");
    string lastFailure;
    foreach (c; candidates)
    {
        const flakeRef = flakeRefAt(repoTop, c.rev);
        const gate = nixBuildPrintOutPaths([flakeRef ~ "#packages." ~ system ~ ".ci"]);
        if (gate.status != 0)
        {
            lastFailure = firstInterestingLine(gate.output);
            skipCandidate(system, c, lastFailure);
            continue;
        }
        const ciPaths = storePathsFromNixStdout(gate.output);
        enforce(ciPaths.length > 0, "nix build printed no store path at " ~ c.label);

        const shown = execute([
            "nix", "derivation", "show",
            "--option", "extra-experimental-features", "nix-command flakes pipe-operators",
            flakeRef ~ "#devShells." ~ system ~ ".ci",
        ]);
        if (shown.status != 0)
        {
            lastFailure = firstInterestingLine(shown.output);
            skipCandidate(system, c, lastFailure);
            continue;
        }
        LinuxHostEnv env;
        env.from = c;
        env.ci = ciPaths[$ - 1];
        env.shell = parseShellDerivation(jsonOnly(shown.output));

        const inputs = shellInputStorePaths(env.shell);
        info(i"substituting $(inputs.length) shell inputs at $(c.label)");
        const missing = substituteShellInputs(flakeRef ~ "#devShells." ~ system ~ ".ci", inputs);
        if (missing.length)
        {
            lastFailure = missing[0] ~ " is not in any binary cache";
            skipCandidate(system, c, lastFailure);
            continue;
        }
        return env;
    }
    throw new Exception(
        "no candidate revision has a cached Linux dev shell (tried "
            ~ candidates.length.to!string ~ "); last: " ~ lastFailure
            ~ "\n  push the branch so CI builds it, or pass --host-ci-rev <sha>");
}

/**
Substitute the shell's inputs, and say which are still missing.

The paths are realized $(I through the flake reference), not as bare store
paths: `sparkles.cachix.org` reaches Nix only via the flake's `nixConfig`,
which a flake-scoped command applies and a bare `nix build /nix/store/…`
does not — a bare build sees `cache.nixos.org` alone and reports every
sparkles-built input as "no substituter that can build it". Building the
shell itself is expected to fail here (platform mismatch, no builder), but
Nix realizes a derivation's inputs before it discovers that, and
`--keep-going` lets every substitution finish regardless. When the shell's
own output is cached the command simply succeeds.
*/
private string[] substituteShellInputs(string shellInstallable, in string[] inputs)
{
    import std.file : exists;

    execute([
        "nix", "build", "--no-link", "--keep-going",
        "--option", "extra-experimental-features", "nix-command flakes pipe-operators",
        "--option", "external-builders", "[]",
        shellInstallable,
    ]);
    string[] missing;
    foreach (p; inputs)
        if (!exists(p))
            missing ~= p;
    return missing;
}

private void skipCandidate(string system, LinuxCiRevision c, string why)
{
    const reason = why.canFind("platform mismatch") || why.canFind("no substituter")
        || why.canFind("not in any binary cache")
        ? "not in any binary cache and no Linux builder: " ~ why
        : why;
    warning(i"devShells.$(system).ci at $(c.label) ($(c.rev[0 .. 12])): $(reason)");
}

/// `execute` merges stderr into the output; keep the JSON document only.
private string jsonOnly(string output) @safe pure
{
    const at = indexOfFrom(output, "{", 0);
    enforce(at != size_t.max, "nix derivation show printed no JSON");
    return output[at .. $];
}

private auto nixBuildPrintOutPaths(string[] installables)
{
    // Disable the gated Determinate builder so a 400 from nixd is not a
    // hard failure when the path is already in the binary cache.
    return execute(
        [
            "nix", "build", "--no-link", "--print-out-paths",
            "--option", "extra-experimental-features",
            "nix-command flakes pipe-operators",
            "--option", "external-builders", "[]",
        ] ~ installables
    );
}
