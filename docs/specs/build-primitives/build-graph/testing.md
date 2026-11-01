---
status: draft
owner: sparkles:build-primitives
reviewed: 2026-11-01
---

# Build graph — Testing and evidence

This page names the oracle for each obligation in [SPEC.md](./SPEC.md), the
falsifying scenarios that check it, and the evidence recorded so far. An
oracle here is the source of the expected result. Each one is chosen to be
independent of the code under test.

## Oracles

### Oracle 1: dub agreement

**Covers:** BGR1–BGR7, invariant 4.

**Source of truth:** dub, at the version the repository's toolchain pins.

**Method:**

1. For every sub-package and every request the repository's commands make
   (test root, dependency library under the `unittest` and `checked` build
   types, application, and each `subConfiguration` a consumer selects), run
   `dub describe` with the same configuration, build type and compiler.
2. Compare each resolved field §2 defines: source files, import paths, string
   import paths, versions, debug versions, dflags, lflags, libs, target type and
   target name.
3. Compare ordered lists in order and sets as sets, per dub's own semantics.
4. Where `dub describe` omits a field, use dub as a library to obtain the
   resolved `BuildSettings` for the same request.

**Falsifying scenarios:**

- A fixture recipe for each supported directive.
- A platform-suffixed setting that applies on one platform only.
- A `subConfiguration` chosen two levels down.
- A `sourceLibrary` folded into two consumers.
- A build type defined only in the root recipe.
- A directive the resolver does not support, which must fail with its location.

**Independence:** dub's resolver is a separate implementation. A shared defect
in our reading of a directive and dub's is possible only for behavior we copied
from dub's source; each such copy is noted in [decisions.md](./decisions.md).

**Gate:** zero unaccepted disagreements across the repository.

### Oracle 2: build equivalence

**Covers:** BGA1–BGA6, BGV1–BGV3.

**Source of truth:** a dub build of the same request.

**Method:** for each package, build its test root and run the test binary, once
through the build graph and once through `dub test`.

**Expected:** the same test names, the same pass and fail verdicts, the same
exit status. Binary identity is not required, because dub orders objects
differently.

**Falsifying scenarios:**

- A test that inspects a dependency's version identifier.
- A test that reads a string import.
- A test whose dependency is a `sourceLibrary`.

### Oracle 3: manifest completeness

**Covers:** BGK2–BGK4, BGK6.

**Source of truth:** the system call trace of the compiler.

**Method:**

1. On Linux, run a compile under `strace -f -e trace=openat,open,stat`.
2. Collect every regular file the compiler opened for reading, excluding the
   toolchain's own files that BGT1 covers.
3. That set must be a subset of the manifest.

**Mutation scenarios:**

- Edit one file in the manifest: the result key changes.
- Edit one file of the dependency's package that the compile did not read: the
  result key does not change.
- Edit a string import: the key changes.
- Edit a generated input: the key changes.

**Gate:** zero opened files missing from the manifest across the repository's
compiles.

### Oracle 4: digest audit

**Covers:** BGK5, BGS5.

**Method:**

1. A test writes a file and keeps its size and modification time, including a
   restored modification time.
2. It forces a digest cache hit and then audits it by rehashing.
3. Separately, it corrupts a store entry and checks the next lookup removes it.

### Oracle 5: relocation

**Covers:** BGA5, invariant 3.

**Method:**

1. Build the same variant in two worktrees at different absolute paths.
2. With LDC, the result keys must be equal and the outputs byte-identical.
3. `strings` on the outputs must find neither worktree's absolute path.
4. With a compiler that has no prefix map, the keys must differ by the root
   path.

**Also checked:** a cache hit built in worktree A runs correctly in worktree B,
and its assertion messages name root-relative files.

### Oracle 6: backend agreement

**Covers:** BGN1, BGN5.

**Method:**

1. Build a set of variants through both backends.
2. Compare the outputs of each key.

**Expected:** they are byte-identical where the action is deterministic. Where
it is not, the test binaries pass and fail identically. Each nondeterministic
action is listed with its cause.

### Oracle 7: concurrency

**Covers:** BGS2–BGS4.

**Method:**

1. Run N processes computing the same keys, with random delays before
   publication.
2. Kill a producer between its write and its rename.

**Expected:**

- every reader sees either no entry or a complete one;
- the killed producer leaves only a temporary entry, which garbage collection
  removes;
- eviction under a small bound never removes an entry that a running build
  holds.

### Oracle 8: layout lint

**Covers:** BGV4, BGV5.

**Method:**

1. Plant a `version (unittest)` instance field in a fixture library: planning
   fails with its location.
2. Move it into a `sourceLibrary` fixture: planning passes.

**Revert check:** removing the lint lets the fixture plan, and the linked test
binary misreads the aggregate.

## Evidence ledger

| Requirement | Status     | Evidence |
| ----------- | ---------- | -------- |
| BGR1–BGR7   | unverified | —        |
| BGV1–BGV5   | unverified | —        |
| BGA1–BGA7   | unverified | —        |
| BGK1–BGK6   | unverified | —        |
| BGS1–BGS6   | unverified | —        |
| BGG1–BGG3   | unverified | —        |
| BGT1–BGT3   | unverified | —        |
| BGX1–BGX2   | unverified | —        |
| BGN1–BGN5   | unverified | —        |
