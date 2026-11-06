---
status: draft
owner: sparkles:build-primitives
reviewed: 2026-11-06
---

# Observability — Testing and evidence

This page names the oracle for each obligation in [SPEC.md](./SPEC.md), the
falsifying scenarios that check it, the feasibility spikes, and the evidence
recorded so far. An oracle is the source of the expected result, chosen to be
independent of the code under test: a tool written by someone else, a workload
whose cost is known by construction, or a value derived by hand.

Three rules hold for every oracle:

- **An absent source is not a pass.** A scenario that needs a PMU, a cgroup
  tier or a platform the host lacks calls `skipTest` with the reason, and the
  ledger counts it as not run.
- **Quality is checked, not only value.** A scenario that expects a lower
  bound fails if the value is marked exact, and the reverse.
- **Every oracle rejects a broken implementation**, named in its section.

| Requirement                                      | Oracle                       |
| ------------------------------------------------ | ---------------------------- |
| OBV1–OBV5, OBV9                                  | 1. vocabulary integrity      |
| OBV6, OBR7, OBD1–OBD10, OBD12                    | 10. records                  |
| OBV7–OBV8, OBA3                                  | 3. honest absence            |
| OBA1–OBA2                                        | 2. known workloads           |
| OBA4–OBA5, OBR1–OBR6                             | 4. queue and run metrics     |
| OBA6, OBJ1–OBJ3, OBQ1–OBQ8, OBU1–OBU4, OBO3–OBO4 | 16. commands and reports     |
| OBA7–OBA9, OBC5                                  | 5. cache outcomes            |
| OBC1–OBC3, OBC7–OBC8                             | 6. time-trace summaries      |
| OBC4                                             | 7. template counts           |
| OBC6, OBL1–OBL3                                  | 8. object and link analysis  |
| OBT1–OBT3                                        | 9. test usage                |
| OBP1–OBP4                                        | 11. privacy                  |
| OBH1–OBH10                                       | 12. history ref              |
| OBH4, OBH8                                       | 17. repository configuration |
| OBG1–OBG10                                       | 13. the gate                 |
| OBO1–OBO2                                        | 14. overhead budget          |
| invariant 1, OBD11, OBU5                         | 15. verdict independence     |

## Oracles

### Oracle 1: vocabulary integrity

**Source of truth:** the catalog tables of SPEC §4–§9, and the recipes.

**Method:**

- A test parses the catalog tables from SPEC.md and compares their ids, units,
  scopes and families with the descriptors `sparkles:metrics` exports.
- A scan of the sources of the test runner, the build graph, the task DAG,
  Event Horizon and `apps/ci` checks that every metric id literal is declared
  and that no type named `MetricCell`, `MetricDescriptor` or `MetricQuality`
  is declared outside the vocabulary package.
- A scan of `libs/metrics/dub.sdl` checks that it depends on nothing but
  `sparkles:metadata`, in every configuration.

**Falsifying scenarios:** a descriptor whose unit differs from its table row;
a table row with no descriptor; an id literal in `apps/ci` that no descriptor
declares; a recorded id with an uppercase letter or a `/`; a derived metric
written to a record.

**Broken implementation:** a catalog with one descriptor removed.

### Oracle 2: known workloads

**Source of truth:** child programs whose cost is known by construction, and
`perf stat` and `/usr/bin/time -v` run on the same programs as independent
measurements.

**Method:** run each fixture program as a supervised action and compare each
metric with its construction and with the independent tool.

**Falsifying scenarios:**

- a loop that retires a known number of user-mode instructions: within 0.1% of
  `perf stat -e instructions:u`, and marked exact only when the spawn path
  attached the counters before `exec`;
- a program that touches 256 MiB: `task.rss.process` at least 256 MiB;
- a parent that waits for four children that each touch 64 MiB at once:
  `task.rss.process` between 64 MiB and 64 MiB plus the parent's own resident
  set, `task.rss.tree` at least 64 MiB and at most 256 MiB plus the parent's,
  both marked lower bounds;
- a program that writes and syncs 64 MiB: `task.io.write` at least 64 MiB;
- a program that sleeps 100 times: `task.ctxsw.voluntary` at least 100;
- a program that maps a file it has evicted from the page cache and reads it:
  `task.faults.major` greater than zero;
- a child that forks a grandchild and exits without waiting for it: CPU marked
  a lower bound;
- a busy loop beside a CPU hog pinned to the same core: `task.stall.cpu`
  greater than zero on an owned cgroup tier.

**Broken implementation:** counters attached after `exec`, which miss the
target's start-up instructions; accounting read after reaping, when the root's
`/proc` entry is gone.

### Oracle 3: honest absence

**Source of truth:** injected probe results.

**Method:** each source's probe takes an injectable result. Each scenario
forces one refusal and checks the record.

**Falsifying scenarios:**

- `perf_event_paranoid` 3: `task.instructions` absent with reason
  `privilege`, and the action succeeds;
- no PMU: reason `no-pmu`;
- a multiplexed counter: quality estimate;
- no owned cgroup: the stall metrics absent with reason `tier`;
- macOS `ri_cycles` zero beside non-zero CPU time: absent with reason
  `failed`, not zero;
- every absent metric is missing from `tasks/<s>.json` and listed in
  `run.json`'s absences.

**Broken implementation:** a source that returns zero on refusal.

### Oracle 4: queue and run metrics

**Source of truth:** values derived by hand for fixed graphs under the fake
clock.

**Method:** run fixture graphs on the fake action driver under `TestSched`,
with scripted durations and a capacity that forces queuing, and compare each
run metric with the values derived by hand.

**Falsifying scenarios:**

- a diamond whose long branch is the critical path;
- an unsatisfied fallback edge, which the critical path does not follow;
- a heavy task that waits for capacity: `task.queue` equals the scripted wait;
- more than 512 changes of queue depth, reduced to 512 equal-time intervals
  that keep each interval's maximum;
- a run in which every action hit and no test ran, marked `noop`;
- a run with evictions: `run.store.evictions` and `.evicted-bytes` equal the
  store's journal of the run;
- a command that performs no pkg-config query: `run.plan.pkg-config` absent
  with reason `family-off`.

**Broken implementation:** a critical path over every edge regardless of its
condition.

### Oracle 5: cache outcomes

**Source of truth:** scripted store states.

**Method:** run one fixture compile through the store in each state, with
every input file older than the digest cache's two-second window
([BGK5](../build-graph/SPEC.md#_5-keys-and-the-input-manifest)), and check
`cache.outcome` and `cache.miss-reason`.

**Falsifying scenarios:** a cold store, `no-entry`; a result evicted while its
manifest remains, `evicted`; a declared key evicted with its manifests and
found in the journal, `evicted`; an edited imported module, `input-changed`
naming it; a file created at an absent candidate's path, `absent-appeared`
naming it; a damaged entry, `corrupt`; a conservatively keyed compile whose
roots changed, `conservative`; a comment-only edit to an own module,
`input-changed` and then `cache.identical-rerun` true; a second run, `hit`
with `cache.reused-bytes` equal to the result's size, `cache.hashed-bytes`
zero, and the line counts present.

**Broken implementation:** a digest cache that drops line counts; reasons
checked in another order than OBA8's.

### Oracle 6: time-trace summaries

**Source of truth:** hand-computed fixtures, and two independent reductions.

**Method:**

1. Hand-written trace files with known nesting, reduced by the action driver's
   reducer, against self and inclusive totals derived by hand.
2. One compile of a fixed module set with a full trace at granularity zero,
   reduced afterwards, against the same compile's summary mode: event counts
   equal per phase, totals within 5%, and the top-ten lists with the same
   members.
3. The summary at granularity 500 µs and at granularity zero, on the same
   compile: event counts equal (OBC3).

**Falsifying scenarios:** an event nested in another phase, whose time leaves
the parent's self time; a template instance nested in another, counted once in
`sema1`'s inclusive time; an event shorter than the granularity; an LDC event
outside the phase table, counted under `other`; a template instance with a
10 KiB name, truncated to 256 bytes; a summary of at most 64 KiB for the
`sparkles:ui` test root.

**Broken implementation:** a summary that applies the granularity to its
totals.

### Oracle 7: template counts

**Source of truth:** fixture modules whose instantiations are counted by
construction.

**Method:** compile modules that instantiate known templates a known number of
times with known argument sets, and compare the recorded counts with the
construction. On a larger corpus, compare them with the compiler's own printed
table as a second check. Compare the recorded diagnostics with the family on
and off.

**Falsifying scenarios:** one template instantiated three times with two
argument sets; recursive instantiation; the template table absent from the
replayed diagnostics, both on a hit and on a miss.

### Oracle 8: object and link analysis

**Source of truth:** `llvm-readelf` and `llvm-nm`, which share no code with the
analyzer, and links with and without `--gc-sections`.

**Method:**

- Compare section classes, symbol counts, name bytes, template symbol counts
  and COMDAT groups with `llvm-readelf` and `llvm-nm` on the corpus objects
  and executables.
- Compute duplicate COMDAT groups and bytes from `llvm-readelf --section-groups`
  over a link's inputs.
- Link a test binary with and without `--gc-sections`, and compare the
  difference of its allocated sections' sizes with `link.gc.removed-bytes`,
  allowing for each removed section's alignment padding.

**Falsifying scenarios:** two objects instantiating one template, one
duplicate group; a test binary with a dead function, removed bytes greater
than zero; a hit, whose analysis is read from the result, not recomputed.

### Oracle 9: test usage

**Source of truth:** fixture tests whose cost is known by construction.

**Method:** run a fixture package's tests through the runner core and check
each test's `usage` member.

**Falsifying scenarios:**

- a test that allocates one 1 MiB block from the GC on its own thread:
  `test.gc.bytes` at least 1 MiB and at most 1 MiB plus one page;
- a test that calls `GC.collect` three times: `test.gc.collections` at least 3;
- a test that maps and touches 512 MiB outside the GC and unmaps it, then a
  test that touches 128 MiB: the second test's `test.rss` below 512 MiB on
  Linux, and `binary.worker.rss` at least 512 MiB;
- a test that fails only under `-t N`: `binary.legs.disagree` 1, the test
  marked flaky;
- a worker killed during a test: `binary.worker.restarts` 1;
- a runner that predates `usage` reads the frames unchanged, and a client
  reading a worker without `usage` records absences with reason `protocol`.

**Broken implementation:** a worker peak taken from the reaping call alone,
after resets.

### Oracle 10: records

**Source of truth:** golden records, and a reader of the previous version.

**Method:** write records for fixture runs and compare them byte for byte with
goldens; read every golden of the previous schema version; read a record with
unknown members and metric ids.

**Falsifying scenarios:**

- the same fixture run twice gives records equal apart from identity and
  measurements;
- a record over 4 MiB drops per-test metrics first, and says so;
- a float in any file fails the golden check;
- two tasks of one series on different LDC versions share a series key and
  differ in comparability key, while an LDC and a DMD build differ in series
  key;
- a hit carries its own `task.wall` and the producer's in `stored`;
- a compile's measurement directory under two different run directories gives
  equal declared keys;
- under the Nix backend, a change to the time summary alone leaves the object
  output's content address unchanged;
- local records past 90 days, or past 512 MiB, are removed oldest first;
- two CI invocations in one job get distinct run identifiers, and one job
  reached directly and through a calling workflow gets the same `<job>` part;
- the facts of OBR7 match the host's own reports, read independently: the CPU
  model from `/proc/cpuinfo` or `sysctl`, the kernel release from `uname`, and
  total memory rounded to GiB, with no field outside OBR7's list.

### Oracle 11: privacy

**Source of truth:** canary strings.

**Method:** run a fixture command with the user name, home directory,
hostname, git email and temporary directory set to unique canary strings, with
paths under them in the action's arguments, environment and output. Search
every byte of the resulting record for each canary, independently of the
scanner. Then check that a clean record of the same run is written.

**Falsifying scenarios:**

- a canary in an argument vector, a manifest path, a template name, a
  diagnostic, an environment variable or a host fact;
- a user named `runner` with a task id containing `test-runner`, and a user
  named `ci`, whose name is a repository directory: the record is written;
- a template instance whose string argument holds a canary home path: the
  identifier is redacted to `<home>` and the record is written;
- a record edited to contain a canary path is rejected by `ci perf push` and
  by the appender, and the batch's other records are appended;
- a runner label outside the allowlist is recorded as `<label>`.

**Broken implementation:** a scanner that checks only `run.json`; a scanner
that matches the user name as a substring.

### Oracle 12: history ref

**Source of truth:** a local bare repository standing in for the remote, with
an upload-pack wrapper that counts requests and bytes.

**Method:** run appenders, compaction and readers against it. History lives
at `refs/perf/data`; commits are signed with test keys listed in a fixture
allowed-signers file.

**Falsifying scenarios:**

- a run with more records than four per job is truncated to that bound, and
  two records claiming one identifier keep only the first;
- four concurrent appenders of distinct runs: every directory present at the
  end, no force push, the retries within OBH3's ten minutes;
- an appender that cannot push for ten minutes fails and names the runs not
  appended; a rerun appends them, and a second rerun changes nothing;
- an appender racing a compaction: the lease fails, compaction restarts, and no
  appended run is lost;
- a record whose run identifier would name another run's directory, or holds
  `/` or `..`, is dropped;
- a tree containing `.github/` or an executable file is refused by the
  appender and by compaction;
- every commit carries the fixed identity, whatever the environment sets, and
  a signature from a listed key;
- an ordinary `git clone` of the fixture remote does not download
  `refs/perf/data`, and `ci perf fetch` does, with `--filter=blob:none`;
- a commit with no signature, or one from an unlisted key, pushed onto the
  ref: its runs are ignored and reported, and an appender refuses to build on
  it;
- the ref rewound to an older commit, or deleted: a reader keeps its cached
  history and reports the rewind; the ref replaced by a signed compaction
  commit: the reader accepts it;
- a fresh `ci perf history` fetches only the shard files of the series it
  charts, in one request;
- with the remote unreachable, `ci perf show` of a cached run succeeds and
  reports the cache's age;
- after compaction, detail older than 90 days is gone, runs older than 365 days
  are rollups, and the ref has one signed root commit.

**Size model:** spike S6.

### Oracle 13: the gate

**Source of truth:** A/A pairs, injected regressions, and hand-computed noise.

**Method:**

1. **Estimator:** fixed sample histories whose `σ` is computed by hand,
   including groups of one, which contribute nothing.
2. **A/A:** at least 100 pairs, each two runs of one commit on one machine
   with one comparability key, each run from a cold build store of its own so
   that every compile executes, compared with `--gate`; compile and test
   series are counted separately as well as together.
3. **Injection:** add work of a known instruction cost to one fixture compile
   and one fixture test, at half and at twice their threshold, and compare
   with the unmodified run.
4. **No counters:** compare two records without `task.instructions`, and two
   records of which only one has it.
5. **CPU gate:** A/A pairs and injections as in steps 2–3 on a hosted runner
   whose gate metric is `cpu-user`, against the `cpu-user` thresholds; and a
   comparison of a run gated on instructions with one gated on CPU time.
6. **Determinism:** run every comparison twice, and compare the reports byte
   for byte.

**Expected:** at most 8 of the 100 A/A pairs flag a series. A gate whose true
rate is 5% passes this with probability 0.94, and one whose rate is 15% with
probability below 0.03. Further: the doubled
injection flagged and the halved one not; `Degraded(noGate)` with each reason
counted and exit status zero when nothing is gated; a series with one side
missing its counter ungated; a series whose sides differ in comparability key
shown as not comparable, naming the components; a series that head served from
the store `unchanged`; improvements reported and not gated; the CPU gate's A/A
pairs within the same bound; the mixed comparison ungated with reason
`gate-metric-differs` throughout, and every report naming its gate metric.

### Oracle 14: overhead budget

**Corpus:** at a pinned revision, the test-root and dependency-library
compiles, the test-binary links and the tests of `sparkles:base`,
`sparkles:wired`, `sparkles:build-primitives` and `sparkles:ui`, with LDC and
with DMD.

**Method:** on an otherwise idle machine, run the corpus with every default
family off and on, interleaved, at least seven times each, from a warm page
cache and a cold build store. Compare the medians of CPU time, user
instructions and peak resident set per action kind, and the bytes written per
compile before reduction. Repeat with each flag-carrying family alone.

**Expected:** OBO1's bounds for every compiler and kind. A family that misses
them is off by default for that compiler (OBO3), and the decision is recorded.

**Broken implementation:** the full trace at the default granularity, which the
oracle rejects with DMD.

### Oracle 15: verdict independence

**Method:** run the command fixtures of the
[`apps/ci` tests](../../ci/task-dag/testing.md) with observation on, off, and
with every source failing, and compare outcomes, exit statuses, and the plain
transcripts with timings off.

**Expected:** identical in all three; failing sources appear only as run
degradations; a reused test result replays the same output block.

### Oracle 16: commands and reports

**Method:** golden transcripts of `ci perf show`, `compare` and `history` over
fixture records, in plain, TTY and JSON forms, and of the plain, TTY and GitHub
step-summary reporters for a fixture run. CI job metrics are checked against
recorded API responses from the `ci stats` fixtures and a recorded Nix
internal-JSON log.

**Falsifying scenarios:**

- an ambiguous run prefix, and a revision without a record, for which the
  nearest earlier record is used and named;
- a lower bound, an estimate, a stored value and an absence, each with its
  marker;
- timings off, which removes the summary lines;
- a series whose stall times grew by more than half its wall growth, marked
  `stalled`;
- a recorded jobs response whose steps include one of each class, and a step
  no map entry names, which counts toward the job's wall time and no class;
- `--observe no-time-trace` and `--keep-traces`, with their effect on the
  argument vectors and on reuse;
- `ci perf` run from `.#ci-minimal`, whose closure holds no compiler;
- each `ci perf` command's transcript holds one task block.

### Oracle 17: repository configuration

**Source of truth:** the intended configuration, written down beside the
workflows.

**Method:** a review, by someone other than the author, of the deployment
environment that holds the CI signing key, its deployment-branch rule, the
allowed-signers file `nix/perf-data-signers`, and the appending and compaction
jobs' permissions, exported through the GitHub API and compared with the
intended configuration. A pull request whose workflow asks for the
environment is refused the key.

This is configuration evidence, not a test; it is repeated whenever the
workflows, the environment or the signers file change.

## Spikes

Each spike states a question and a decision criterion. Its result is recorded
in [decisions.md](./decisions.md).

- **S1: Counters where CI runs.** Can user-mode instructions be counted on the
  hosted Linux, macOS and Windows runners, on a self-hosted Linux machine and
  on a developer machine, and what does each refuse? It reads
  `perf_event_paranoid`, probes for a PMU inside each hosted virtual machine,
  tries `perf_event_paranoid` 2 where the job can set it, and counts a known
  loop. _Decides_ each environment's gate metric under OD20: instructions where
  counted, user CPU time on hosted runners where not.
- **S2: Instruction noise.** What is the spread of equal-input differences of
  `task.instructions` per action kind, on a dedicated machine and on a hosted
  runner, and the same for `task.cpu.user` on hosted runners; how many
  equal-input pairs does a month of `main` produce? _Decides_ OBG5's priors and
  floors, including the `cpu-user` rows.
- **S3: Time-trace cost.** What do the reduced trace, at 500 µs, 5 ms and
  50 ms, and the fork's summary mode cost on the corpus, per compiler? Which
  LLVM work does each LDC event enclose? _Decides_ OBC7's source per compiler,
  whether the family is on by default, and the phase table's LDC rows.
- **S4: Template statistics cost.** What does `-vtemplates` cost per compiler?
  _Decides_ whether the family is on by default.
- **S5: Spawn and exit.** Event Horizon spawns with `posix_spawn` and joins the
  run cgroup afterwards. Can it hold the child before `exec`, through a
  trampoline or a cgroup-aware spawn, so that counters and the cgroup see the
  target from its first instruction? Can it read `/proc/<pid>/io`, the cgroup
  files and, on macOS, `proc_pid_rusage` while the root is a zombie, and which
  call returns the root's resource usage beside its `waitid` reaping?
  _Decides_ the sources of OBA1–OBA2, or their lower-bound fallbacks; without
  an exact `task.instructions`, nothing is gated.
- **S6: History growth.** Generate a year of synthetic records at `main`'s
  landing rate, then measure the history's packed size before and after
  compaction, the size of a `blob:none` clone, the bytes one `history` query
  fetches, and the server-side size after a re-rooted push. _Decides_ the shard
  count and OBH7's thresholds.
- **S7: A custom ref on GitHub.** Does GitHub accept a push to
  `refs/perf/data`, keep it, serve it to a `--filter=blob:none` fetch with
  batched blob requests, leave it out of ordinary clones, and start no workflow
  for it? Which ruleset or setting, if any, can protect it? _Decides_ whether
  OBH1–OBH10 hold as written; a refusal reopens OD19.

## Evidence ledger

Nothing is implemented. Every row is planned.

| Requirement | Status  | Evidence | Missing    |
| ----------- | ------- | -------- | ---------- |
| OBV1–OBV9   | planned | —        | everything |
| OBA1–OBA9   | planned | —        | everything |
| OBC1–OBC8   | planned | —        | everything |
| OBL1–OBL3   | planned | —        | everything |
| OBT1–OBT3   | planned | —        | everything |
| OBR1–OBR7   | planned | —        | everything |
| OBJ1–OBJ3   | planned | —        | everything |
| OBO1–OBO4   | planned | —        | everything |
| OBD1–OBD12  | planned | —        | everything |
| OBH1–OBH10  | planned | —        | everything |
| OBP1–OBP4   | planned | —        | everything |
| OBG1–OBG10  | planned | —        | everything |
| OBQ1–OBQ8   | planned | —        | everything |
| OBU1–OBU5   | planned | —        | everything |
