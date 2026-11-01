---
status: draft
owner: sparkles:build-primitives
reviewed: 2026-11-01
---

# Build graph — Testing and evidence

This page names the oracle for each obligation in [SPEC.md](./SPEC.md), the
falsifying scenarios that check it, and the evidence recorded so far. An oracle
is the source of the expected result. Each one is chosen to be independent of
the code under test.

| Oracle                   | Covers                            |
| ------------------------ | --------------------------------- |
| 1. dub agreement         | BGR1–BGR7, BGV1–BGV2, invariant 4 |
| 2. build equivalence     | BGA1–BGA4, BGA7, BGV1–BGV3        |
| 3. manifest completeness | BGK2–BGK4, BGK6                   |
| 4. digest audit          | BGK5, BGS6                        |
| 5. relocation            | BGA5–BGA6, BGG4, invariant 3      |
| 6. backend agreement     | BGN1, BGN5                        |
| 7. concurrency           | BGS1–BGS5, BGS7                   |
| 8. layout lint           | BGV4–BGV5                         |
| 9. key sensitivity       | BGK1, BGT1–BGT3                   |
| 10. generators           | BGG1–BGG3                         |
| 11. test actions         | BGX1–BGX3                         |
| 12. Nix inputs           | BGN2–BGN4                         |
| 13. hidden edges         | BGR8                              |
| 14. task exposure        | BGA8                              |
| 15. pinned test runner   | BGT4                              |

## Oracles

### Oracle 1: dub agreement

**Source of truth:** dub, at the revision the flake pins.

**Method:**

1. List every request the repository's commands make for every package in
   scope: test root, dependency library under the `unittest` and `checked`
   build types, application, and each `subConfiguration` a consumer selects.
2. For each, run `dub describe` with the same root, configuration, build type
   and compiler. Where `dub describe` omits a field, obtain dub's resolved
   build settings for the same request by using dub as a library.
3. Compare every resolved field: source files, import, C import and string
   import paths, versions, debug versions, dflags, lflags, libs, target type and
   target name. Compare ordered lists in order and sets as sets. Fields before
   library resolution are compared with `dub describe`; fields after it, such as
   `pkg-config` results, with dub's own `prepareBuildSettings`, called as a
   library.
4. Remove from dub's side the downward-inherited versions that BGV1 prunes, and
   check separately that no source of the variant mentions any of them.

**Falsifying scenarios:**

- one fixture recipe per supported directive;
- a platform-suffixed setting that applies on one platform only;
- a `subConfiguration` chosen two levels down;
- a `sourceLibrary` folded into two consumers;
- a build type defined only in the root recipe;
- a root version mentioned by a dependency, which must survive pruning;
- a root version mentioned by no dependency, which must be pruned;
- an ABI-critical dflag in a root's configuration, which must reach every
  dependency;
- an unsupported directive, which must fail with its location.

**Independence:** dub's resolver is a separate implementation. A shared defect
is possible only for behaviour copied from dub's source, and each such copy is
noted in [decisions.md](./decisions.md).

**Gate:** zero unaccepted disagreements across the repository.

### Oracle 2: build equivalence

**Source of truth:** a dub build of the same request.

**Method:** for each package, build its test root and run the test binary once
through the build graph and once through `dub test`.

**Expected:** the same test names, verdicts and exit status. Binary identity is
not required, because dub orders objects differently.

**Falsifying scenarios:**

- a test that inspects a dependency's version identifier;
- a test that reads a string import;
- a test whose dependency is a `sourceLibrary`;
- an application package whose `mainSourceFile` must be excluded from its test
  root.

### Oracle 3: manifest completeness

**Source of truth:** the compiler's system call trace.

**Method:**

1. On Linux, run each compile under `strace -f -e trace=%file`.
2. Collect every file the compiler or its C preprocessor opened for reading,
   and every lookup that failed with `ENOENT` under an import, C import or
   string import root. A failed lookup of a missing directory is satisfied by
   any absent candidate beneath it.
3. The opened files, excluding the toolchain files BGT1 covers, must be a
   subset of the manifest's file entries. The failed lookups that precede a
   successful resolution must be a subset of its absent candidates.

**Mutation scenarios:**

- editing a file in the manifest changes the result key;
- editing a file of a dependency that the compile did not read does not;
- editing a string import, or an ImportC header two includes deep, changes it;
- creating `a/m.d` when `-Ia -Ib` resolved `m` to `b/m.d` changes it;
- creating a `.di` beside a `.d`, or a `package.d`, changes it;
- creating the module a failed `__traits(compiles, { import opt; })` probed
  changes it.

**Gate:** zero opened files missing from manifests and zero preceding failed
lookups missing from absent candidates, across the repository's compiles.

### Oracle 4: digest audit

**Method:**

1. Rewrite a file while keeping its size and modification time, including a
   rewrite within the file system's timestamp granularity of its digest
   record. The next lookup must rehash it.
2. Force a digest cache hit, then audit it by rehashing.
3. Corrupt a store entry. The next lookup must remove it.

### Oracle 5: relocation

**Method:**

1. Build the same variant in two worktrees at different absolute paths.
2. With LDC, the declared and result keys must be equal and the outputs
   byte-identical. Neither worktree's absolute path may appear in the outputs,
   coverage registrations included.
3. Run the test binary built in worktree A from worktree B. It must pass, and
   every fixture it opens through `__FILE_FULL_PATH__` must be B's.
4. With a compiler that has no prefix map, the keys must differ by the root
   path.
5. Two runs of `ci docs verify` on unchanged examples must produce equal
   result keys for every example compile.

### Oracle 6: backend agreement

**Method:** build a set of variants through both backends, and compare the
outputs for each declared key and manifest.

**Expected:** byte-identical outputs where the action is deterministic. Where
it is not, test binaries that pass and fail identically, with each
nondeterministic action listed with its cause.

### Oracle 7: concurrency

**Method:**

1. Run N processes computing the same keys, with random delays before
   publication, from worktrees on different file systems.
2. Kill a producer between its write and its rename.
3. Run garbage collection concurrently with builds that hold leases, and kill
   a lease holder.

**Expected:**

- every reader sees either no entry or a complete one;
- no publication crosses a file system;
- the killed producer leaves only a staging entry, which garbage collection
  removes;
- eviction never removes an entry whose lease holder is alive, and reclaims the
  lease of a dead one;
- two worktrees alternating between two manifests of one declared key both
  keep hitting.

### Oracle 8: layout lint

**Method:** plant one instance of each BGV4 hazard in a fixture library:

- a field;
- a virtual method;
- a destructor;
- an `enum` value;
- a template with a `version (unittest)` branch;
- an import of a test-only package.

Each must fail planning with its location. Moving the same declaration inside
a `unittest` block must pass.

**Revert check:** with the lint disabled, the field fixture plans and links,
and its test binary misreads the aggregate.

### Oracle 9: key sensitivity

**Method:** for each component of the declared key (BGK1) and each component
BGT1 lists, substitute a variant of it: another argument, environment entry or
recipe file; another compiler build, configuration file, C driver wrapper,
linker or generator binary; another pinned test runner. Every affected key must
change, and no unaffected one may.

### Oracle 10: generators

**Method:**

1. Edit a shader source. Its generate action and the compiles that read its
   outputs must rerun, and nothing else.
2. Leave stale files in the in-tree generated directory. The compile must
   read the generator's outputs instead.
3. Check the generator's invocation contains no staleness flag and no `dub`
   call.

### Oracle 11: test actions

**Method:**

1. Put a `dub` on the test binary's `PATH` that records any call and fails.
   No test binary may call it, and the compile-time-probe and extracted modes
   must still find their import paths and flags.
2. A test that declares no runtime inputs must run on every request.
3. With the Nix backend (E4), a sandboxed result's key must change with the
   kernel release and the CPU model.

### Oracle 12: Nix inputs

**Method:**

1. A cold Nix build of a compile, with no prior manifest, must succeed.
2. After an edit adds a new import within the declared roots, the rebuilt
   derivation must still succeed.
3. A derivation's input set must not contain files outside its declared
   inputs and roots.

### Oracle 13: hidden edges

**Method:** a fixture recipe with `importPaths "../other/src"` and no
`dependency` must be reported. The cycle-safe test-runner integration must
not be.

### Oracle 15: pinned test runner

**Method:**

1. Change the working tree's test-runner implementation. Only that package's
   own test root may rebuild, and every other test binary must still link the
   pinned library.
2. Bump the pin. Every test root's key must change.

### Oracle 14: task exposure

**Method:** plan the same request twice. The task ids, claims and edges must be
identical. Every action edge must be `onSuccess`, and a link's argument vector
must carry its claimed thread count.

## The recipe vocabulary

BGR2's supported set is the vocabulary of the recipes in scope. E0's directive
scan writes it here, one row per directive with the recipes that use it, and
oracle 1 checks each row. Until the scan runs, this table is empty.

| Directive or form | Used by |
| ----------------- | ------- |

## Evidence ledger

| Requirement | Status     | Evidence |
| ----------- | ---------- | -------- |
| BGR1–BGR8   | unverified | —        |
| BGV1–BGV5   | unverified | —        |
| BGA1–BGA8   | unverified | —        |
| BGK1–BGK6   | unverified | —        |
| BGS1–BGS7   | unverified | —        |
| BGG1–BGG4   | unverified | —        |
| BGT1–BGT4   | unverified | —        |
| BGX1–BGX3   | unverified | —        |
| BGN1–BGN5   | unverified | —        |
