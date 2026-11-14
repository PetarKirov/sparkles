# Zig build system (Zig)

Zig's build system is a `build.zig` program that declares a graph of steps, which
a cached, separately compiled runner (the **Maker**) executes under a
memory-aware scheduler. It has a manifest-based content cache, a binary pipe
protocol to the compiler and to test binaries, and a package manager whose
packages are identified by a hash of their file set.

| Field                     | Value                                                                                                     |
| ------------------------- | --------------------------------------------------------------------------------------------------------- |
| Language                  | Zig (the build system, its runner and its scripts are all Zig)                                            |
| License                   | MIT (Expat)                                                                                               |
| Repository                | [ziglang/zig on Codeberg][repo]                                                                           |
| Documentation             | [Zig Build System guide][guide] · [`build.zig.zon` reference][zon-doc] · [language reference][langref]    |
| Category                  | Language build system / package manager                                                                   |
| Workspace model           | One root `build.zig` + `build.zig.zon`; packages are `.dependencies` (by `url` + `hash`, or local `path`) |
| Graph                     | A `std.Build.Step` graph, serialized by a short-lived **configurer** and run by the long-lived **Maker**  |
| Latest release            | 0.17.0, the first release with the configurer/Maker split; this page reads `master`                       |
| Source revision read here | `master` at [`8e8cf3835a96`][repo-rev] (2026-11-01)                                                       |

> **Revision note.** Zig's build system changed shape in 2026. Commit `2e88ac8842`
> (2026-02-15) replaced `lib/compiler/build_runner.zig` with a configurer and the
> Maker; 0.15 and 0.16 still ship the old single-process runner, and 0.17.0 the
> new split. Negative file dependencies (`067f8dcb37`, 2026-10-18) postdate 0.17.0.
> All citations are pinned to [`8e8cf3835a96`][repo-rev]. Zig's canonical
> repository moved to Codeberg, so the links point there rather than at the
> archived GitHub mirror.

---

## Overview

### What it solves

`zig build` is the language's build system, test driver and package manager in
one: the same `build.zig` describes compiling, installing, running tests and
fetching dependencies, with no separate tool. The unit of work is a **step**;
`zig build <step>` runs a step and, transitively, everything it depends on.

The build description is ordinary Zig. Since the 2026 split, running it is a
separate concern from executing the graph it produces:

> The configurer is always short-lived because all it does is serialize the
> configuration, which is picked up by a separate maker process.
> — [`lib/compiler/configurer.zig:29-30`][configurer]

### Design philosophy

- **The build script is a program, executed once and cached.** `build.zig`
  compiles into a configurer executable, whose only job is to write the step
  graph out (`serializeConfigurationExiting`, [`configurer.zig:138-164`][configurer]).
  The Maker caches that output under `.zig-cache/c/<digest>` and, on a hit,
  neither compiles nor runs the script again ([`Maker.zig:1588-1603`][maker]).
- **A long-lived executor for long-lived modes.** The Maker is a fixed tool
  compiled from the Zig installation, not from the project:

  > The build runner is long-lived in the following use cases:
  > `--watch` mode · `--webui` mode · `--fuzz` mode · A project that has a large,
  > complex build graph.
  > — [`lib/compiler/Maker.zig:210-214`][maker]

- **Memory is a scheduled resource, not only cores.** A step may declare
  `max_rss`, and the scheduler never runs a set of steps whose declared totals
  exceed the budget ([`lib/std/Build/Step.zig:14-33`][step-cfg]).
- **The compiler is a server.** The build runner talks to the compiler and to
  test binaries over one framed binary protocol on stdin/stdout
  (`std.zig.Server` / `std.zig.Client`), so a compiler process can stay alive
  across `--watch` updates and a test binary can be driven test by test.

---

## How it works

### Workspace declaration & topology

There is no workspace manifest beyond the root package. `build.zig.zon` declares
the package and its dependencies ([`doc/build.zig.zon.md`][zon-doc];
[`Maker/Package/Manifest.zig`][manifest]):

```zig
.{
    .name = .example,          // enum literal, ≤ 32 bytes
    .version = "0.1.0",        // semver
    .fingerprint = 0x1234abcd_5678ef01, // 32-bit id + CRC32(name)
    .minimum_zig_version = "0.17.0",    // advisory only
    .dependencies = .{
        .zlib = .{ .url = "https://…/zlib-1.3.1.tar.gz", .hash = "zlib-1.3.1-…" },
        .core = .{ .path = "libs/core" },  // local: never hashed
    },
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

A dependency is either remote (`url` + `hash`, optionally `lazy`) or local
(`path`); the manifest rejects both at once ("dependency should specify only one
of 'url' and 'path' fields.", [`Manifest.zig:306-331`][manifest]). A monorepo is
a root package whose members are `path` dependencies, each with its own
`build.zig`. A local `path` dependency is not content-hashed — "path-based
dependencies are not hashed" ([`Maker/Fetch.zig:560`][fetch]) — and gets an
internal path-based id instead ([`Maker/Package.zig:122-139`][package]).

### Dependency handling & isolation

**Packages are content-addressed by their file set.** The package hash
([`Maker/Package.zig:94-120`][package]) has the human-readable form
`name-version-hashplus`, where `hashplus` is 33 bytes in unpadded base64url:
a little-endian u32 package id, a little-endian u32 total size (saturating),
then "(25 bytes) truncated SHA-256 digest". The legacy `1220…` multihash no
longer validates ([`Package.zig:70-76`][package]).

The digest itself ([`Maker/Fetch.zig:1777-1970`][fetch]):

- **File set:** only files inside `.paths` (all files when `paths` is empty,
  `""` or `"."`); excluded files are _deleted_ from the fetched tree, not merely
  skipped ("Delete instead of including in hash calculation",
  [`Fetch.zig:1792-1808`][fetch]). Nothing is excluded by name — `.git` and
  `build.zig.zon` are hashed if `paths` covers them.
- **Per-file digest:** SHA-256 over the normalized `/`-separated relative path,
  then, for a regular file, the two bytes `{0, 0}` (a "Hard-coded false
  executable bit", [`Fetch.zig:1943`][fetch]) and the raw contents; for a
  symlink, its normalized target. There is no length prefix and no type tag.
- **Only files and symlinks.** Any other type fails: "package contains {q} which
  has illegal file type {t}" ([`Fetch.zig:1810-1817`][fetch]). Directories are
  not hashed, and "Empty directories are _not hashed_ and must not be present"
  ([`Fetch.zig:1747-1749`][fetch]).
- **Composition:** the per-file digests, sorted by bytewise comparison of the
  normalized paths, are fed to an outer SHA-256. The scheme hashes files
  independently because that "allows hashing in parallel"
  ([`Fetch.zig:1777-1778`][fetch]).
- **Normalization:** backslashes become `/`, mode bits are ignored (the tar
  reader runs with `.mode_mode = .ignore`), line endings are not touched, and
  nothing folds case.

**Storage.** A fetched package is unpacked into the project-local
`zig-pkg/<hash>/`; the global cache keeps only a deterministic, recompressed
`p/<hash>.tar.gz`, for sharing ([`Fetch.zig:376-470`][fetch]). An existing
`zig-pkg/<hash>/` is trusted as-is; a tarball from the global cache is
re-hashed when unpacked; a mismatch fails with "hash mismatch: manifest
declares {s} but the fetched package has {s}" ([`Fetch.zig:828-835`][fetch]).

### Task orchestration & scheduling

**The step graph.** A configure-time `std.Build.Step` is a thin description —
`tag`, `name`, `owner`, `dependencies`, `max_rss` ([`lib/std/Build/Step.zig:8-42`][step-cfg]);
edges are added with `dependOn`. The kinds at this revision are `check_file`,
`compile`, `config_header`, `fail`, `find_program`, `fmt`, `install_artifact`,
`install_dir`, `install_file`, `obj_copy`, `options`, `run`, `top_level`,
`translate_c`, `update_source_files` and `write_file`
([`Step.zig:46-65`][step-cfg]). `CheckObject` is gone (removed with the linker
tests, `e7d74e49b0`).

The Maker keeps the mutable per-step state ([`lib/compiler/Maker/Step.zig`][maker-step]):
`dependants`, an atomic `pending_deps` counter, an atomic `state`, watch
`inputs`, and the results — error messages, `result_cache_status`,
`result_duration_ns`, `result_peak_rss`, `test_results`. Its states
([`Maker/Step.zig:168-189`][maker-step]):

| State                             | Meaning                                                                                        |
| --------------------------------- | ---------------------------------------------------------------------------------------------- |
| `precheck_unstarted/started/done` | Graph construction and loop detection; `precheck_done` also marks a dirty step under `--watch` |
| `success`, `failure`              | The step ran                                                                                   |
| `skipped`                         | `error.MakeSkipped`, e.g. a foreign binary that cannot execute here                            |
| `skipped_oom`                     | Its `max_rss` exceeds the whole budget ("It is not safe to run its dependencies")              |
| `dependency_failure`              | A dependency failed                                                                            |
| `dependency_skipped`              | A dependency was skipped                                                                       |

A step reports failure by returning `error.MakeFailed` after appending messages
(`Step.fail`, [`Maker/Step.zig:443-445`][maker-step]); test results with any
failure, leak or logged error also become `MakeFailed`
([`Maker/Step.zig:240-248`, `:311-312`][maker-step]). Before running a step,
`makeStep` inspects its dependencies: a `failure` or `dependency_failure` makes
it `dependency_failure`, and a `skipped`, `skipped_oom` or `dependency_skipped`
makes it `dependency_skipped` ([`Maker.zig:3161-3185`][maker]). So a skip
propagates exactly like a failure, despite `skipped`'s own comment that it "is
safe to continue executing its dependencies". There is no per-edge condition,
no "run even if a dependency failed" step, and no cleanup step; the only
cleanup is a global temporary-file sweep after the graph ([`Maker.zig:2908`][maker]).

**There is no fail-fast mode.** No `--keep-going` exists because keep-going is
the only behaviour: a failure never cancels the run, every independent step
still executes, and the summary counts the `dependency_*` steps as not run.

**Scheduling.** The Maker runs on `std.Io` (a threaded `Io` implementation),
not a thread pool of its own ([`Maker.zig:220`][maker]). `makeSteps` seeds the
ready set with every step whose `pending_deps` is zero; a finishing step
decrements each dependant's counter atomically and readies the dependant whose
count reaches zero ([`Maker.zig:2858-2876`, `:3274-3280`][maker]). Ready order is
the step stack's order: no priorities, no critical path. `-j<N>` limits
concurrency to `N` (default: every core, [`src/main.zig:541`][main];
[`Maker.zig:599-604`][maker]).

**Memory-aware admission.** `--maxrss <size>` sets a budget that defaults to the
total system memory ([`Maker.zig:883-886`][maker]). The step's own documentation
promises two things ([`lib/std/Build/Step.zig:14-33`][step-cfg]):

> This field causes the build runner to do two things:
>
> 1. ulimit child processes, so that they will fail if it would exceed this
>    memory limit. This serves to enforce that this upper bound value is correct.
> 2. Ensure that the set of concurrent steps at any given time have a total
>    max_rss value that does not exceed the `max_total_rss` value of the build
>    runner.

Only the second is implemented. `stepReady` takes a mutex and, if
`available_rss < max_rss`, parks the step on `memory_blocked_steps` ("Running
this step right now could possibly exceed the allotted RSS."); otherwise it
subtracts the claim ([`Maker.zig:3111-3123`][maker]). A finishing step returns
its claim and releases blocked steps, last-in first-out, while they fit
([`Maker.zig:3247-3271`][maker]). No `setrlimit` call exists anywhere in the
Maker. After the fact, a step whose measured peak RSS exceeds its declaration
gains an error message ("memory usage peaked at … exceeding the declared upper
bound of …") but keeps its `success` state ([`Maker/Step.zig:315-323`][maker-step]).

A step whose `max_rss` exceeds the whole budget is an error before anything
runs — "this step declares an upper bound of {d} bytes of memory, exceeding the
available {d} bytes of memory" — unless `--skip-oom-steps` turns it into
`skipped_oom` ([`Maker.zig:2810-2831`][maker]). There is no "run it alone"
clamp.

**Run steps.** `Step.Run` executes a program as a step
([`lib/std/Build/Step/Run.zig`][run-cfg]; execution in
[`lib/compiler/Maker/Step/Run.zig`][run]). Its `stdio` mode decides its
semantics: `infer_from_args`, `inherit`, `check` (stdout/stderr/exit-code
expectations: `expectStdOutEqual`, `expectStdErrEqual`, `expectExitCode`,
snapshot variants), `zig_test` (deprecated) and `protocol`. Extra inputs that
should trigger a re-run are declared with `addFileInput`
([`Step/Run.zig:804-813`][run-cfg]); there is no `addDirectoryInput` — a
directory argument (`addDirectoryArg`) hashes only its path string. Whether a
Run step is cacheable is computed in one expression ([`Maker/Step/Run.zig:562-568`][run]):

```zig
const has_side_effects = graph.fuzzing or conf_run.flags.has_side_effects or any_cli_positionals or
    switch (conf_run.flags.stdio) {
        .infer_from_args => !any_output_args and
            conf_run.captured_stdout.value == null and
            conf_run.captured_stderr.value == null,
        .inherit => true,
        .check, .zig_test, .protocol => false,
    };
```

A step without side effects is cached on: its environment, argv strings, the
contents of file arguments (`addInputPath`), output-argument names, stdin
bytes, the expected stdio and exit status, `file_inputs` and the working
directory ([`Maker/Step/Run.zig:60-560`][run]). A `check` or `zig_test` run whose
key hits is **not re-executed**: a passing test is reused from the cache unless
one of those declared inputs changed. Nothing about the inputs a program reads
on its own enters the key. Ordinary Run steps have no wall-clock timeout; only
unit tests do (below).

**The build runner bootstrap.** `zig build` compiles `lib/compiler/Maker.zig`
in-process into the global cache (`o/<digest>/maker`) and `execve`s it with the
subcommand, `--zig-lib=`, `--zig=`, `--global-cache=` and `--seed=`
([`src/main.zig:349-359`, `:5088-5216`][main]). The Maker compiles `build.zig`
plus `compiler/configurer.zig` with `zig build-exe -fsingle-threaded --dep @build
--dep @dependencies` ([`Maker.zig:1225-1258`][maker]), runs it, and keys the
serialized configuration on the configure arguments (`-D…`), the debug target
and a poison bit ([`Maker.zig:1288-1302`][maker]). A script that reads a file at
configure time declares it with `b.dependOnFileMetadata`, or else
`Graph.poisonCache` makes every invocation re-configure
([`lib/std/Build.zig:2685-2705`][build]).

### Caching & remote execution

The cache is local only; there is no remote cache and no remote execution.

**Two directories.** The local cache is `<build_root>/.zig-cache` (or
`$ZIG_LOCAL_CACHE_DIR`); the global cache is `$ZIG_GLOBAL_CACHE_DIR`, else
`$XDG_CACHE_HOME/zig`, else `~/.cache/zig` ([`lib/std/zig.zig:1709-1734`][zig-zig]).
Each holds `h/` (manifests and the `h/timestamp` probe file), `o/<hex>/`
(artifacts), `tmp/<random>/` (in-progress output) and `z/` (cached ZIR).
There is no eviction: the code has no garbage collector, and "Temporary files
are not deleted" ([`src/Compilation.zig:1351`][compilation]).

**The manifest** ([`lib/std/Build/Cache.zig`][cache]) is a rewrite of the
textual cache older Zig versions shipped; the familiar names (`addFile`,
`addFilePost`, `hit`, `writeManifest`) no longer exist at this revision.

1. **Declared inputs.** A manifest starts from a base hash (compiler version,
   backend and other options, [`Compilation.zig:1931-1960`][compilation]) plus
   `addInputPath`, `addInputPathOptional` and `addInputDepFile`
   ([`Cache.zig:713-840`][cache]). Paths are stored relative to one of up to
   five prefixes (cwd, zig lib, local cache, global cache, build root): "This
   is not to save space but to eliminate absolute file paths. This improves
   portability and usefulness of the cache" ([`Cache.zig:26-31`][cache]).
2. **Manifest lookup.** The manifest's file name is a hash of the declared
   inputs' flags and paths, not their contents: "This is _not_ hashing the
   contents of the input files" ([`Cache.zig:909-920`][cache]). So one declared
   key has **one** manifest file.
3. **Verification.** The manifest is a binary file of `extern struct`
   records — `size`, `inode`, `mtime` (ns), a 16-byte `digest`, `flags`
   `{is_directory, metadata_only, exists, prefix}` and the NUL-terminated path
   ([`Cache.zig:439-466`][cache]). A file whose size, mtime and inode all match is
   trusted without rehashing; otherwise it is rehashed, and unchanged content is
   still a hit ([`Cache.zig:579-591`, `:1495-1515`][cache]).
4. **Discovered inputs.** After a miss, the compiler adds what it actually read:
   `addDiscoveredPath` for Zig sources and `@embedFile` targets (with the
   contents it already holds), `addDiscoveredDepFile` for clang's `-MD -MV -MF`
   dep files ([`Cache.zig:1768-1935`][cache]; [`src/Zcu/PerThread.zig:226-251`][perthread];
   [`Compilation.zig:5746-5796`, `:6321-6323`][compilation]). The final
   digest — the artifact's `o/<digest>` name — covers the declared and the
   discovered files' digests ([`Cache.zig:2050-2063`][cache]).
5. **Locks.** A check takes the manifest file's lock exclusive, falling back to
   shared when another process holds it; a shared-lock miss upgrades to exclusive
   and re-checks, because "another process may have modified the cache directory"
   ([`Cache.zig:874-1031`][cache]). A hit keeps the lock shared for the
   artifact's lifetime (`toOwnedLock`).
6. **Publication.** In `whole` mode the output is built in `tmp/` and renamed to
   `o/<digest>/`; on `DirNotEmpty` the existing directory is deleted and the
   rename retried, so the newest producer replaces the old result
   ([`Compilation.zig:3262-3301`][compilation]). The manifest is then written in
   place, without a rename.

**The problematic timestamp.** A file modified within the file system's current
timestamp granule cannot be trusted by stat alone. Zig measures that granule
directly: it truncates `h/timestamp` and reads the mtime the file system just
gave it ("what time the file system thinks it is, according to its own
granularity"), and any input whose mtime is not older is stored with mtime and
inode zeroed ([`Cache.zig:568-577`, `:1672-1713`][cache]):

```zig
if (try m.isProblematicTimestamp(s.mtime)) {
    // The actual file has an unreliable timestamp; force it to be hashed.
    file.mtime = 0;
    file.inode = 0;
}
```

Such a file can never match on stat, so it is rehashed on every check until a
later run records a trustworthy stat.

**Absent files.** Negative dependencies are partial:

- `metadata_only` entries carry an `exists` flag (since `067f8dcb37`), so a
  configure-time dependency on a file that must stay absent works — "file not
  existing can only be tracked with metadata_only" ([`Cache.zig:1591`][cache]).
  Inside a search prefix even that is impossible: "the dependency cannot be
  tracked; `Graph.poisonCache` must be used instead" ([`Build.zig:2703`][build]).
- Content-hashed inputs have no negative form: a missing declared input is an
  error, and a missing discovered file is `.path_deleted`.
- A failed `@import` fails the compile, so no manifest is written.
- **C include probing is not tracked.** The manifest holds only the headers in
  clang's dep file — those actually opened. A header later created earlier on
  the `-I` search path does not invalidate a cached object.

**Hash function.** `SipHash128(1, 3)`, keyed by a fixed 16-byte constant that
doubles as the format version; 16-byte digests, 32 hex characters
([`Cache.zig:121-140`][cache]).

### The compiler and test protocol

`--listen=-` makes the compiler, or a test binary built by `zig test`, a
**server** on stdin/stdout; the build runner is the **client**
([`src/main.zig:1440-1456`][main]; [`lib/compiler/test_runner.zig:53-85`][test-runner]).
The compiler also accepts a TCP address. Messages share one 8-byte
little-endian header, `{ tag: u32, bytes_len: u32 }`, where `bytes_len` counts
the body only ([`lib/std/zig/Server.zig:25-29`][server];
[`lib/std/zig/Client.zig:17-21`][client]).

| Direction      | Tags                                                                                                                                                                                                                                            |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| child → runner | `zig_version`, `error_bundle`, `emit_digest`, `test_metadata`, `test_results`, `test_started`, `file_system_inputs`, `coverage_id`, `fuzz_start_addr`, `fuzz_test_change`, `broadcast_fuzz_input`, `time_report`, `discovered_inputs`, `config` |
| runner → child | `exit`, `update`, `run`, `hot_update`, `query_test_metadata`, `run_test`, `start_fuzzing`, `new_fuzz_input`, `args`                                                                                                                             |

The test messages ([`Server.zig:172-196`][server]):

```zig
/// Trailing:
/// * name: [tests_len]u32  - null-terminated string_bytes index
/// * expected_panic_msg: [tests_len]u32, - 0 means does not expect panic
/// * string_bytes: [string_bytes_len]u8,
pub const TestMetadata = extern struct { string_bytes_len: u32, tests_len: u32 };

pub const TestResults = extern struct {
    index: u32,
    flags: Flags align(4),
    pub const Flags = packed struct(u64) {
        status: Status, fuzz: bool, log_err_count: u30, leak_count: u31 };
    pub const Status = enum(u2) { pass, fail, skip };
};
```

**Versioning.** There is no negotiation. The child's first message is
`zig_version` ([`test_runner.zig:86`][test-runner]; [`src/main.zig:4403`][main]),
and the runner requires an exact match: "zig version mismatch build runner vs
compiler: '{s}' vs '{s}'" ([`Maker/Step/Run.zig:882-888`][run]). The runner
ignores message tags it does not expect (`else => {}, // ignore other
messages`). Exact matching is safe only because the runner, the compiler and
the test runner ship together in one Zig installation.

**Driving a test binary** ([`lib/compiler/Maker/Step/Run.zig:784-988`, `:1585-1733`][run]).
One process runs every test of a binary, in order; a new process starts only
after a crash or a timeout:

1. The child's stdin, stdout and stderr are all pipes. Stdout carries only
   protocol messages; test output goes to stderr (`std.debug.print`, the log
   function), read on the same multiplexed reader.
2. The runner sends `query_test_metadata` once, then `run_test(i)` for each
   index in turn, strictly one test at a time, and `exit` after the last.
3. The child answers `test_started` when the test begins. The comment explains
   why: "This message helps to ensure that the timestamp used by the build
   runner to enforce unit test time limits is relatively accurate under extreme
   system load" ([`Server.zig:42-47`][server]). Then it sends `test_results`.
4. A failure, a leak (`testing.allocator` is reset per test and checked when it
   ends) or a logged error attaches the buffered stderr to the step's error;
   stderr after a passing test is not drained.
5. **Timeouts.** `--test-timeout` sets a per-test deadline measured from
   `test_started`; while no test runs, a response timeout of
   `max(test timeout, 60 s)` applies. There is no overall timeout.
6. **Crashes.** If stdout ends, or a deadline passes, while a test is active,
   the runner counts a crash or a timeout against that test, kills and respawns
   the binary, and continues with the next index without re-querying the
   metadata: "Previous unit test process died or was killed; we're continuing
   where it left off" ([`Maker/Step/Run.zig:833-835`][run]). If the child dies
   between tests, "The individual unit test results are irrelevant: the test
   runner itself broke!" ([`Maker/Step/Run.zig:1637`][run]) and the step fails.
7. The step's `TestResults` counts tests, skips, failures, crashes, timeouts,
   leaks and logged errors; leaks and logged errors fail the step even when
   every test passed ([`Maker/Step.zig:217-256`][maker-step]).

The child side ([`lib/compiler/test_runner.zig:124-172`][test-runner]) runs each
test with a fresh testing allocator and logger, maps `error.SkipZigTest` to
`skip` and any other error to `fail`, and does not catch panics or signals —
a crash ends the process and the supervisor attributes it.

**Fuzzing and the web UI.** `std.testing.fuzz` marks a fuzz test; the first
`zig build --fuzz` pass runs tests normally and records fuzz tests by **name**
(indexes may change across rebuilds), then rebuilds them with `-ffuzz` and
starts one fuzzer per job with `start_fuzzing`
([`lib/compiler/Maker/Fuzz.zig:88-118`][fuzz]). Coverage is SanitizerCoverage
counters in a shared memory-mapped file under the cache's `v/`, read by the
runner, which the code itself doubts: "This brings the whole mmap strategy into
question" ([`Maker/Fuzz.zig:343-346`][fuzz]). `--fuzz` and `--time-report` start
a loopback web server that serves a WebAssembly client and streams binary
`extern struct` messages over a WebSocket ([`lib/compiler/Maker/WebServer.zig`][webserver]).

**`--watch` and incremental compilation.** The Maker watches directories
(fanotify on Linux 5.17+, `ReadDirectoryChangesW`, kqueue, FSEvents —
[`lib/compiler/Maker/Watch.zig`][watch]); a cache hit contributes its manifest's
files as watch inputs, and the compiler reports its own through
`file_system_inputs`. A change invalidates the step and its dependants, and the
graph re-runs after a 50 ms debounce. With `-fincremental`, the compiler process
stays alive and each rebuild is one `update` message
([`Maker/Step.zig:492-616`][maker-step]).

### CLI / UX ergonomics

`zig build <step>…` selects steps by name (`zig build test`, `zig build run`);
`-l` lists them. `-D<name>=<value>` sets configure options, `-j<N>` the
concurrency, `--maxrss` the memory budget, `--test-timeout` the per-test limit,
`--watch`, `--fuzz`, `--webui` and `--time-report` the long-lived modes, and
`--summary all|new|failures|line|none` the closing report: "Build Summary: X/Y steps
succeeded …; N/M tests passed (a skipped, b failed, c crashed, d timed out)"
([`Maker.zig:2894-3033`][maker]). There is no package-level selection
(`--from`, `--since`): selection is by step name only.

---

## Strengths

- **Memory is scheduled.** Declared `max_rss` budgets keep a 4 GiB test from
  running beside three others on a 16 GiB machine; few build systems model
  memory at all.
- **A crash-tolerant, lockstep test protocol.** A test that segfaults or hangs
  costs one test, not the run: the runner respawns the binary and resumes at
  the next index.
- **A deliberate per-test clock.** The deadline starts at the child's own
  `test_started`, so a loaded machine does not charge spawn and scheduling
  delay to a test.
- **Directly measured timestamp granularity.** The cache asks the file system
  how fine its clock is instead of assuming a margin.
- **Cached configuration.** The build script runs only when its configure
  inputs change.
- **Content-hashed packages, parallel to compute.** A package's identity is a
  function of its file set, hashed file by file.

## Weaknesses

- **No fail-fast and no conditional edges.** Every failure is keep-going, a
  skip propagates like a failure, and there is no cleanup or fallback step.
- **Half of `max_rss` is unimplemented.** Children are not `ulimit`ed, and an
  over-budget peak is a warning, not a failure.
- **One manifest per declared key.** Two worktrees on different revisions of a
  dependency overwrite each other's manifest; each switch is a rebuild.
- **Negative dependencies are partial.** No absent-file tracking for compiles,
  none at all for C include probing.
- **No eviction, no remote cache.** The global and local caches only grow.
- **Run-step reuse trusts the declaration.** A cached `check` or test run is
  reused whatever the program read that was not declared.

## Key design decisions and trade-offs

| Decision                                                | Rationale                                                         | Trade-off                                                                    |
| ------------------------------------------------------- | ----------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| `build.zig` → configurer → serialized graph → Maker     | Run the user's program once and cache it; keep the executor fixed | Configure-time file reads must be declared, or the cache is poisoned         |
| Keep-going is the only mode                             | Report every independent failure in one run                       | No fail-fast; a broken early step still lets unrelated long work run         |
| `max_rss` reservations, LIFO release of blocked steps   | Avoid swapping or OOM under full concurrency                      | Declarations are not enforced; LIFO release can starve an early blocked step |
| One manifest per (flags, paths) prehash                 | Simple lookup, one file to lock                                   | Alternating inputs (worktrees, branches) thrash the manifest                 |
| SipHash128 keyed by a constant                          | Fast, with a format version built into the key                    | Not collision-resistant against an adversary; local cache only               |
| Stat-first verification with a probed timestamp granule | Hash only files whose stat changed or is too recent to trust      | A file touched every build is rehashed every build                           |
| Protocol on stdout, test output on stderr               | Output never corrupts framing; a crash leaves the protocol intact | Output written after a passing test may appear under a later failure         |
| Package hash = SHA-256 of sorted per-file SHA-256s      | Parallel hashing; platform-independent paths                      | Executable bit and empty directories are not part of a package's identity    |

---

## Take-aways for Sparkles

Read against the [task-DAG SPEC][td-spec], the [build-graph SPEC][bg-spec] and
the test runner's process-model amendment (`docs/specs/test-runner/process-model.md`, in review on its own branch; its TRP IDs are cited below).

| Zig mechanism                                     | Verdict | Bears on                   | Notes                                                                                                                                                                                                  |
| ------------------------------------------------- | ------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Per-test deadline from the child's `test_started` | Adopt   | TRP16, process-model scope | The process model leaves timeouts out of scope. Zig's two clocks — a per-test deadline from `started`, a response timeout between tests — fit `started`/`result` (TRP16) without a new frame.          |
| Crash → respawn, resume at the next test          | Adopt   | TRP26, TRP14               | TRP26 already respawns. Zig does not re-query the listing after a crash; TRP14's listing comparison is a stronger check worth keeping, at the cost of one listing per respawn.                         |
| Leaks and logged errors fail a passing run        | Adapt   | TRP16                      | Zig counts them per test in `TestResults`. Our `result` frame has no leak or log-error member; worth a member if D tests gain an allocator check.                                                      |
| Protocol on stdout, output on stderr              | Already | TRP6, TRP24                | We go further: a sentinel attributes output to its test (TRP24), which Zig lacks (its stderr after a passing test leaks into the next failure).                                                        |
| `max_rss` reservations in admission               | Adapt   | TDM7, TDM10                | Our `ResourceClaim.memoryHintBytes` is a hint and TDM10 folds memory into one capacity. Zig shows the separate-budget design; keep our clamp (TDM7) instead of Zig's pre-run error, and measure peaks. |
| Keep-going only, skip propagates as failure       | Reject  | TDC2, TDM5, TDM6           | We need fail-fast (TDC2), a skip that satisfies `onSuccess` (TDM5), and the unneeded/blocked/cancelled split (TDM6). Zig's `skipped` vs `dependency_skipped` is the closest analogue.                  |
| One manifest per declared key                     | Reject  | BGK3                       | Exactly the thrash BGK3's bounded manifest list exists to avoid.                                                                                                                                       |
| Stat-first verification; probed timestamp granule | Adapt   | BGK5                       | BGK5 uses git's fixed two-second margin. Zig's `h/timestamp` probe measures the file system's real granule; either is sound, the probe is cheaper on fine-grained file systems.                        |
| `addDiscoveredDepFile` from clang `-MD`           | Already | BGK2, BGK6                 | Same shape as our `--makedeps` manifest. Zig records no absent candidates and no C include probes — the gap BGK2's absent candidates and BGK6's conservative keying close.                             |
| `exists` flag on metadata-only entries            | Adapt   | BGK2, BGK4                 | Confirms the encoding: a manifest row whose content is "absent". Ours applies it to compile inputs too, which Zig cannot.                                                                              |
| Prefix-relative paths in manifests                | Already | BGA5                       | Zig's five prefixes are the same idea as relocatable invocations.                                                                                                                                      |
| Rename-and-replace publication; no eviction       | Reject  | BGS2, BGS3, BGS5           | Ours: first rename wins (BGS3), leases, and a size-bounded LRU (BGS5).                                                                                                                                 |
| Local `.zig-cache` beside a global cache          | Reject  | BGS1                       | Zig splits a per-project cache from a per-user one; BGS1 keeps one store per machine so every worktree reuses every result. Zig has no leases (BGS4) or corruption handling (BGS6) either.             |
| Two-step key, as in ccache's direct mode          | Already | BGK1, BGK2, BGK3           | Zig's prehash (flags and paths) then digest of declared plus discovered files is direct mode's shape, minus the list of manifests per key that BGK3 adds.                                              |
| Exact `zig_version` match, no negotiation         | Reject  | TRP10, TRP11               | Fine for a toolchain that ships its runner; our pinned runner (BGT4) talks to binaries built against other harness versions, so TRP10's version ranges are needed.                                     |
| A fixed runner built from the installation        | Already | BGT4                       | The Maker is compiled from Zig's own `lib/`, not from the project, exactly as BGT4 builds the pinned runner, not the worktree's.                                                                       |
| Cached `check`/test runs keyed on declared inputs | Reject  | BGX3                       | Zig reuses a passing test on its declared inputs alone; BGX3 forbids that unless the run was sandboxed or declares every runtime input.                                                                |
| Cached configuration + `dependOnFileMetadata`     | Adapt   | TDE3, TDD2                 | Our planning reads run every invocation. If discovery grows costly, Zig's model — key the plan on its declared configure inputs, poison on undeclared ones — is the shape to copy.                     |
| Package hash over sorted per-file digests         | Adapt   | BGN4                       | A flat, parallel, path-sorted Merkle-of-one-level; it drops the executable bit and empty directories, which [NAR][nar] and [git trees][git-objects] keep. Fine for sources, not for outputs.           |
| Fuzzing over shared-memory coverage; web UI       | Defer   | —                          | Interesting, and self-admittedly racy; nothing in the current specs needs it.                                                                                                                          |

---

## Sources

- [ziglang/zig at `8e8cf3835a96`][repo-rev] — the source of every cited path.
  The links point at Codeberg, Zig's canonical repository, pinned to that full
  SHA. `ci --check-blob-paths` reads only GitHub URLs, so it does not check
  them; every cited path was verified with `git cat-file -e <sha>:<path>` in a
  clone at that revision instead.
- [`lib/std/Build/Step.zig`][step-cfg] — configure-time steps, `max_rss`
- [`lib/std/Build/Step/Run.zig`][run-cfg] — the Run step's configuration API
- [`lib/std/Build/Cache.zig`][cache] — the manifest cache
- [`lib/std/Build.zig`][build] — `dependOnFileMetadata`, `poisonCache`
- [`lib/compiler/Maker.zig`][maker] — the executor, scheduler and memory budget
- [`lib/compiler/Maker/Step.zig`][maker-step] — step states, results, `ZigProcess`
- [`lib/compiler/Maker/Step/Run.zig`][run] — Run-step caching and the test driver
- [`lib/compiler/configurer.zig`][configurer] — the configure phase
- [`lib/compiler/test_runner.zig`][test-runner] — the test binary's side
- [`lib/std/zig/Server.zig`][server] · [`lib/std/zig/Client.zig`][client] — the protocol
- [`lib/compiler/Maker/Fetch.zig`][fetch] · [`Maker/Package.zig`][package] ·
  [`Maker/Package/Manifest.zig`][manifest] — the package manager and its hash
- [`lib/compiler/Maker/Fuzz.zig`][fuzz] · [`Maker/WebServer.zig`][webserver] ·
  [`Maker/Watch.zig`][watch] — fuzzing, web UI, file watching
- [`src/main.zig`][main] · [`src/Compilation.zig`][compilation] ·
  [`src/Zcu/PerThread.zig`][perthread] — `--listen`, the bootstrap, discovered inputs
- [`doc/build.zig.zon.md`][zon-doc] — the package manifest reference
- Related deep-dives: [Cargo][cargo] · [Bazel][bazel] · [Buck2][buck2] · [Make][make];
  related catalog: [content addressing][content-addressing]

<!-- References -->

[repo]: https://codeberg.org/ziglang/zig
[repo-rev]: https://codeberg.org/ziglang/zig/src/commit/8e8cf3835a96a5c1ab72c1638e82f7a1f5d6032d
[guide]: https://ziglang.org/learn/build-system/
[langref]: https://ziglang.org/documentation/master/
[zon-doc]: https://codeberg.org/ziglang/zig/src/commit/8e8cf3835a96a5c1ab72c1638e82f7a1f5d6032d/doc/build.zig.zon.md
[step-cfg]: https://codeberg.org/ziglang/zig/src/commit/8e8cf3835a96a5c1ab72c1638e82f7a1f5d6032d/lib/std/Build/Step.zig
[run-cfg]: https://codeberg.org/ziglang/zig/src/commit/8e8cf3835a96a5c1ab72c1638e82f7a1f5d6032d/lib/std/Build/Step/Run.zig
[cache]: https://codeberg.org/ziglang/zig/src/commit/8e8cf3835a96a5c1ab72c1638e82f7a1f5d6032d/lib/std/Build/Cache.zig
[build]: https://codeberg.org/ziglang/zig/src/commit/8e8cf3835a96a5c1ab72c1638e82f7a1f5d6032d/lib/std/Build.zig
[zig-zig]: https://codeberg.org/ziglang/zig/src/commit/8e8cf3835a96a5c1ab72c1638e82f7a1f5d6032d/lib/std/zig.zig
[maker]: https://codeberg.org/ziglang/zig/src/commit/8e8cf3835a96a5c1ab72c1638e82f7a1f5d6032d/lib/compiler/Maker.zig
[maker-step]: https://codeberg.org/ziglang/zig/src/commit/8e8cf3835a96a5c1ab72c1638e82f7a1f5d6032d/lib/compiler/Maker/Step.zig
[run]: https://codeberg.org/ziglang/zig/src/commit/8e8cf3835a96a5c1ab72c1638e82f7a1f5d6032d/lib/compiler/Maker/Step/Run.zig
[configurer]: https://codeberg.org/ziglang/zig/src/commit/8e8cf3835a96a5c1ab72c1638e82f7a1f5d6032d/lib/compiler/configurer.zig
[test-runner]: https://codeberg.org/ziglang/zig/src/commit/8e8cf3835a96a5c1ab72c1638e82f7a1f5d6032d/lib/compiler/test_runner.zig
[server]: https://codeberg.org/ziglang/zig/src/commit/8e8cf3835a96a5c1ab72c1638e82f7a1f5d6032d/lib/std/zig/Server.zig
[client]: https://codeberg.org/ziglang/zig/src/commit/8e8cf3835a96a5c1ab72c1638e82f7a1f5d6032d/lib/std/zig/Client.zig
[fetch]: https://codeberg.org/ziglang/zig/src/commit/8e8cf3835a96a5c1ab72c1638e82f7a1f5d6032d/lib/compiler/Maker/Fetch.zig
[package]: https://codeberg.org/ziglang/zig/src/commit/8e8cf3835a96a5c1ab72c1638e82f7a1f5d6032d/lib/compiler/Maker/Package.zig
[manifest]: https://codeberg.org/ziglang/zig/src/commit/8e8cf3835a96a5c1ab72c1638e82f7a1f5d6032d/lib/compiler/Maker/Package/Manifest.zig
[fuzz]: https://codeberg.org/ziglang/zig/src/commit/8e8cf3835a96a5c1ab72c1638e82f7a1f5d6032d/lib/compiler/Maker/Fuzz.zig
[webserver]: https://codeberg.org/ziglang/zig/src/commit/8e8cf3835a96a5c1ab72c1638e82f7a1f5d6032d/lib/compiler/Maker/WebServer.zig
[watch]: https://codeberg.org/ziglang/zig/src/commit/8e8cf3835a96a5c1ab72c1638e82f7a1f5d6032d/lib/compiler/Maker/Watch.zig
[main]: https://codeberg.org/ziglang/zig/src/commit/8e8cf3835a96a5c1ab72c1638e82f7a1f5d6032d/src/main.zig
[compilation]: https://codeberg.org/ziglang/zig/src/commit/8e8cf3835a96a5c1ab72c1638e82f7a1f5d6032d/src/Compilation.zig
[perthread]: https://codeberg.org/ziglang/zig/src/commit/8e8cf3835a96a5c1ab72c1638e82f7a1f5d6032d/src/Zcu/PerThread.zig
[td-spec]: ../../../specs/build-primitives/task-dag/SPEC.md
[bg-spec]: ../../../specs/build-primitives/build-graph/SPEC.md
[nar]: ../../content-addressing/nar.md
[git-objects]: ../../content-addressing/git-objects.md
[content-addressing]: ../../content-addressing/
[cargo]: ../cargo/
[bazel]: ../bazel/
[buck2]: ../buck2/
[make]: ../make/
