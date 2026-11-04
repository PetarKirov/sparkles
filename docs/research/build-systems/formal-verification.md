# Formal Verification of Build Systems (Theme)

A build system sits between a compiler and the program it produces, so a wrong
build makes every downstream verification moot. This page asks what has actually
been _machine-checked_ about build engines — not argued, tested, or asserted —
and where the proofs stop. The short answer: four completed mechanizations are
relevant (CloudMake, forward build systems, and two Nix-language interpreter
efforts), plus an unfinished à-la-carte Coq translation and a stalled Pluto
pilot. All verify research models; no production engine here ships a
correctness proof, and every build proof rests on what a sandbox and a tracer
are meant to guarantee.

**Last reviewed:** November 3, 2026

| Field            | Value                                                                                         |
| ---------------- | --------------------------------------------------------------------------------------------- |
| Category         | Theme — cross-cutting; no single system                                                       |
| Question         | Which build properties are proved in a proof assistant, over what model, and what is assumed? |
| Proof assistants | Coq/Rocq, Agda, Dafny (SMT-backed)                                                            |
| Vocabulary       | [concepts] — this page does not redefine _correctness_, _minimality_, _trace_ or _scheduler_  |

> [!NOTE]
> Evidence base: [a-la-carte], [pie], [perfect-dependencies], [rattle-page] and
> [speculative], plus the papers and artifacts they cite. Cross-source conclusions
> are marked **catalog inference**.

## Overview

### What it solves

A build system is an optimizer, and every optimization needs a reference semantics
to be correct _against_. À la carte supplies one: a build is correct when inputs
survive and every non-input key equals what recomputing its task would produce
([concepts] §4; JFP §3.6). Forward systems pick a different reference — the script
the user wrote — and CPP 2022 defines correctness as behaving "identically to
simply executing the programmer-specified commands in order" ([fbsf], abstract).
Verification asks whether a model meets that definition for _all_ inputs,
including interleavings and cache states no test suite enumerates.

### Design philosophy

The field starts from the fact that the object of study barely exists as a
specification: à la carte's own footnote admits "There are numerous implementations
of MAKE and none comes with a formal specification" (JFP §2.1).
**Executable** is not **proved** — a model that runs can be tested against a
definition, but nothing forbids it from violating that definition on the next
input.

## How it works

### 1. Every proof names a reference semantics

The mechanized statements differ less in logic than in what they compare against:
_optimized execution is observationally equal to a reference execution_, plus a
termination side condition.

| Work                         | Reference semantics                                                | Optimizations covered                              |
| ---------------------------- | ------------------------------------------------------------------ | -------------------------------------------------- |
| CloudMake, Dafny (2014)      | operational semantics with axiomatic `exec`; sequential evaluation | parallel argument evaluation, cached builds        |
| À la carte → Coq (2019)      | JFP §3.6 `compute` per key                                         | the scheduler × rebuilder compositions             |
| Rattle et al., Agda (2022)   | `script : Build → FileSystem → FileSystem`                         | memoization, hazard checks, speculative reordering |
| Nix language, Rocq (2024–25) | operational semantics of Mininix/NixLang                           | none — an interpreter, not a build engine          |

**Catalog inference:** because the reference is chosen per paper, "verified build
system" is not a comparable label. A proof against `script` says nothing about
minimality; one against `compute` says nothing about tracing.

### 2. À la carte: precise, executable, unproved

The Haskell models are this catalog's vocabulary and its cautionary tale.
`Task c k v`, `Scheduler`, `Rebuilder` and the three-by-four grid are executable,
and writing them changed the theory — the `Selective` class came out of trying to
encode Dune (JFP §7.1). Nothing in either version is mechanized: no Coq, Agda or
Isabelle development, no soundness theorem about the composition, no proof that a
rebuilder implements minimality ([a-la-carte] §"Proofs"). The models were later
ported to Rust and Kotlin, "and in both cases there was a loss of precision due to
language-specific limitations" (JFP §7.1).

### 3. Coq: the à la carte translation, left incomplete

Lukyanov and Mokhov's CoqPL 2019 abstract is the direct follow-up and the clearest
statement of why the work is hard:

> "These complex build systems and frameworks use subtle algorithms and are
> mission-critical, yet to the best of our knowledge they come with no formal
> proofs of correctness. … We build on this work by translating the Haskell
> abstractions to Coq and making the necessary adjustments to capture the notion
> of build task acyclicity, which is essential for proving termination."
>
> — Lukyanov & Mokhov, CoqPL 2019 ([coqpl19])

Two details matter. The Haskell encoding does not transfer unchanged: `Task`'s
higher-kinded `forall f. c f => …` needs adjustment before a proof assistant
accepts it. And the status is honest — "an experience report on on-going work
which is very far from being complete"; the 2022 Agda paper still describes the
Coq effort as working towards "correctness and minimality (not yet achieved when
that paper was published)" ([fbsf] §7).

### 4. Agda: forward build systems, and a bug the proof found

The strongest result is CPP 2022. Files are `FileName × FileContent`; a command is
a `CmdFunction` from a `FileSystem` to the files it reads and writes; an `Oracle`
supplies a `CmdProof` that its output depends only on the files it claims to read
([fbsf] §3.2) — the determinism-plus-tracing assumption, internalized.

It proves:

- **Fabricate and Memoize** — a hazard-free incremental build is equivalent to
  `script` (Figure 4).
- **Sequential Rattle** — soundness (no hazard implies equivalence to `script`)
  and completeness (a hazard-free build reports no hazard), yielding
  `correct-rattle` (Figures 5–6).
- **Speculative Rattle** — only _partial_ correctness. The total lemma is stated
  and left unproved: "We cannot prove this lemma for the current implementation of
  Rattle" (Figure 7). The weakening accepts a hazard caused by speculation in place
  of a wrong result ([fbsf] §6.1).

So the abstract's "we prove that these optimizations … preserve our definition of
correctness" covers the sequential result and the reordering lemma;
[speculative] reads the body the same way. **What resists proof is the policy, not
the reordering theory.**

The proof paid for itself. Modelling hazards exposed a real defect:

> "When attempting to prove and model Rattle in Agda it became obvious that if
> the commands were only considered when they were run, some speculative write
> read hazards would be missed. In particular, a `required?` predicate needed to
> be tested with the full set of commands, not a prefix, as Rattle was doing."
>
> — CPP 2022 §6.4 ([fbsf])

At the pinned Rattle commit the skip path re-checks hazard status when a command
is in `required` ([`Server.hs`][rattle-required]), the shape the fix prescribes. A
hazard checker that passed every test the authors had was wrong in a case only a
permutation model enumerates.

### 5. Dafny: CloudMake, verified in industry

CloudMake (2014) is the earliest artifact from a deployed industrial system. Its
external tool call is axiomatized rather than modelled:

> "the central operation `exec` is defined axiomatically, making it pluggable …
> The formalization and proofs of the central CloudMake algorithms are done
> entirely in Dafny."
>
> — Christakis, Leino & Schulte, FM 2014, abstract ([cloudmake])

The axiom is discharged: `ExecProperty` is proved (about 250 lines) for a concrete
oracle model of `exec` (§2.3), and `ParallelBuilds.dfy` proves the axioms
consistent. The paper proves race-free parallel argument evaluation and a
consistent cache, with cached-equals-clean as its main theorem (§3–§4).

The edge is admitted in the paper: one lemma is missing in `CachedBuilds.dfy` —
that an invocation's arguments are judged valid in the cached version exactly when
they are in the non-cached one (§4). The three files total 2,815 lines of Dafny and
verify in 237 + 194 + 40 seconds — the cost is engineering, not infeasibility.

### 6. Rocq: Nix's language, not Nix's build

The newest development verifies an _interpreter_, not an engine. Broekhoff's
Mininix thesis defines a core Nix language, gives operational semantics, and
proves a reference interpreter sound and complete: "All our work is mechanized
using the Coq proof assistant" ([mininix-thesis]). The 2025 ICFP paper generalizes
the technique and instantiates it at Nix; the artifact extracts the interpreter to
OCaml, runs the official test suite, and reports 91.77% code coverage
([nix-verified]).

The part a build-system reader cares about is out of scope: the artifact's usage
note says the REPL accepts the Nix language "although, as mentioned in the paper,
e.g. derivations are not supported" ([nix-artifact]), and 74 official tests are
excluded. Evaluation is verified; derivations, the store and the graph are not
([nix-thesis]).

### 7. The Pluto pilot that stalled

Pluto's soundness and optimality were proved by hand, not machine: the OOPSLA 2015
paper "provided manual proofs of soundness … and optimality (also known as
minimality)" ([fbsf] §7, citing [pluto]). CPP 2022 notes "an existing project to
mechanise these Pluto proofs"; that project's report is the most useful negative
result here:

> "An initial formalisation of the basic pluto algorithms and data-structures in
> Agda was created: this revealed many subtleties resulting from the impedance
> (mis)match between the set-theoretic/object-oriented model underlying pluto, and
> its realisation in constructive type theory. … Little progress has been made on
> the general abstract proof search model of build systems … In retrospect, the
> proposal was too ambitious."
>
> — McKinna & Stevens, VeTSS pilot report ([vetss])

Two lessons, both about modelling: an object-oriented engine does not decompose
into à la carte components without loss (no distinct "scheduler" can be
identified), and a nine-month pilot cannot mechanize an engine.

### 8. What inspecting the artifacts adds

The two Nix developments are unusually auditable as artifacts, not merely as
papers.

- **Mininix thesis (`c1c6979…`).** `correct.v` contains the literal top-level
  correspondence
  `Theorem correct e v' : (∃ n, eval n false e = Some v') ↔ e -->* v'`.
  Its development also proves strong confluence of the step relation and
  determinism of base steps. A scan of the `.v` files at the pinned commit
  finds no `Admitted` proof or project-declared `Axiom`; that is a source
  audit, not a substitute for running `coqchk`, and standard-library imports
  can still carry their own assumptions.
- **Verified dynamic-language interpreters (`6a59973…`).** The Nix instance's
  final theorems are named `interp_sound_complete_ret`,
  `interp_sound_complete_ret_lit`, `interp_sound_complete_fail`, and
  `interp_sound_complete_no_fuel` in `theories/nix/interp_proofs.v`: return,
  failure, and divergence/fuel exhaustion are separately related to the
  operational semantics. The literal-return theorem is explicitly stronger
  than the paper statement. The artifact maps paper theorem numbers to file
  lines and documents four axioms reported by validation, all inherited
  indirectly through Flocq/`Reals` for IEEE-754 floats rather than introduced
  as Nix-specific assumptions.
- **Extraction is part of the evidence and part of the gap.** Extracting to
  OCaml and running upstream tests narrows the model/implementation distance,
  but parser, extraction, OCaml runtime, test harness, and excluded tests
  remain outside the kernel-checked theorem. Coverage of extracted code is
  useful correspondence evidence, not a proof that the official evaluator is
  the same function.

This artifact-level view also clarifies the Rattle result: Agda proves a
model with an oracle that already knows each command's exact read/write
effect. The implementation bug was found by trying to express that model;
the theorem does not mechanically transfer to `fsatrace`, process scheduling,
or the Haskell server.

### The trusted stack underneath every theorem

A mechanized build theorem normally trusts, from bottom to top:

1. proof-assistant kernel and any axioms in scope;
2. definitions of filesystem, environment, process, and command effects;
3. parser/translation from user build descriptions into the model;
4. extraction or manual refinement from model to implementation;
5. compiler/runtime and operating-system semantics;
6. sandbox/tracer observations; and
7. determinism and disjointness properties of external tools.

Most papers make layers 1–2 precise and axiomatize or omit 3–7. That does not
make the proof weak, but it determines what a reader may conclude: these are
proofs about scheduling/rebuild algorithms under idealized command effects,
not proofs that Bazel, Shake, Rattle, or Nix as shipped cannot produce a
wrong artifact.

## The assumption ledger

Every proof above is conditional, and the conditions are where production systems
differ.

| Assumption                                 | Stated in                     | What violates it in a real build                                         |
| ------------------------------------------ | ----------------------------- | ------------------------------------------------------------------------ |
| Commands are deterministic                 | [fbsf] §2.2; JFP §8.3         | timestamps, hash seeds, parallel name supply (JFP §8.3)                  |
| Tracing is complete and correct            | [fbsf] §2.2, §3.3             | ptrace/FUSE blind spots, directory ops, missed syscalls ([sandboxing])   |
| A command never writes its own inputs      | [fbsf] §2.2 (`DisjointBuild`) | in-place formatters, `sed -i`, generated headers                         |
| The build is a static, duplicate-free list | [fbsf] §3.3                   | monadic builds, dynamic dependencies ([pie], [dynamic-deps-distributed]) |
| The task graph is acyclic                  | [coqpl19]; JFP §3.6           | fixpoint builds (LaTeX), cycles resolved by policy                       |
| Commands run sequentially in the model     | [fbsf] §3.3                   | real parallelism; speculation modelled as a permutation                  |
| `exec` obeys its axiom                     | [cloudmake] §2.3              | any compiler or linker outside the instantiation                         |
| The semantics is the implementation        | [mininix-thesis]              | evaluator drift; the official interpreter is the de facto spec           |

The last row is the quiet one. Mininix exists because Nix's 2006 reduction rules
went stale and "the official Nix interpreter is the single source of truth"
([mininix-thesis], abstract): a verified semantics is only as good as its
correspondence to the binary users run, and review maintains that, not proof.

## What is proved, and what is not

| Property                                                 | Mechanized?                  | Where                                       |
| -------------------------------------------------------- | ---------------------------- | ------------------------------------------- |
| Sequential forward build: equivalence + hazard soundness | Yes                          | [fbsf] §4–§5 (Agda)                         |
| Speculative build ≡ script                               | **No** — partial only        | [fbsf] §6 (Agda)                            |
| Parallel argument evaluation is race-free                | Yes                          | [cloudmake] §2 (Dafny)                      |
| Cached build ≡ clean build                               | Yes, minus one lemma         | [cloudmake] §3–§4 (Dafny)                   |
| Nix expression evaluation sound/complete                 | Yes                          | [mininix-thesis]; [nix-verified]            |
| À la carte scheduler × rebuilder correctness             | **No** — started, unfinished | [coqpl19] (Coq)                             |
| Rebuild minimality for any implementation                | **No**                       | — (Pluto manual, [pluto]; [fbsf] §7)        |
| Dynamic dependency discovery under proof                 | **No**                       | — (models take a static list, [fbsf] §3.3)  |
| Trace/action-cache key correctness                       | **No**                       | — (determinism assumed; [semantic-caching]) |
| Production engine (and remote execution)                 | **No**                       | — (catalog-wide; see Sources)               |

**Catalog inference:** the "no" rows are absences across the sources this page and
the catalog opened, not proofs of non-existence. Searches of the arXiv API,
Crossref and public repositories on 2026-11-02 found no Lean or Isabelle
development for a build scheduler and no mechanized artifact shipped with any
surveyed engine.

## Why the gap persists

**The interesting layer is outside the model.** Every proof stops where a command
becomes a pure function: Rattle assumes "tracing data is complete and correct"
([fbsf] §2.2), CloudMake axiomatizes `exec`, Mininix stops before derivations. The
sandbox and tracer are the hardest components to specify ([sandboxing]), so the
verified core is the part least likely to be wrong.

**Dynamic dependencies change the theorem.** À la carte's correctness assumes a
known task description. PIE argues its hybrid correct in prose and concedes partial
optimality ([pie]); Nix's dynamic derivations move graph construction into the
build ([nix-dynamic-derivations]). The Agda model restricts builds to static lists
and argues monadic builds add "no additional expressive power" ([fbsf] §3.3) — a
claim about the model, not about Nix or PIE.

**The incentive is detection, not proof.** Production ships checks — Rattle's
hazard detector, Shake's lint modes, Bazel's sandbox ([a-la-carte] §7.4) — which
catch the same class of bug at run time for a fraction of the cost, and fail
loudly. LaForge takes the research position: "always correct" is argued from trace
replay and tested over 100 commits ([laforge] §6.4), not proved. **Catalog
inference:** the field optimizes for bugs caught per engineer-year; a proof
maintained against a moving implementation loses that comparison.

The risk is concrete. Rattle's missed hazard was invisible to the tests the authors
had ([fbsf] §6.4), and production caches inherit CloudMake's determinism assumption
without its proof ([semantic-caching]); an abstract can claim more than the body
proves.

## Strengths

- Finds bugs testing misses — the Rattle hazard defect is the existence proof
  ([fbsf] §6.4) — and forces reference semantics and assumptions into the open.
- Survives refactoring, and composes with extraction: the Nix interpreter is
  proved, extracted, and run against the official suite ([nix-verified]).

## Weaknesses

- Cost is real: 2,815 lines of Dafny for one language's core and cache
  ([cloudmake] §4); a 13-page paper's Agda model covers three forward systems.
- The trusted boundary is the interesting part: tracing, `exec`, determinism.
- Dynamic dependencies, minimality, cache keys and distribution are unmechanized;
  proofs rot, none is on a production release path, and model mismatch can sink
  the effort — the Pluto pilot's object-oriented model did not fit constructive
  type theory ([vetss]).

## Key design decisions and trade-offs

| Decision                                          | Rationale                                                   | Trade-off                                                            |
| ------------------------------------------------- | ----------------------------------------------------------- | -------------------------------------------------------------------- |
| Prove a model, not the engine                     | Small proof, explicit trusted core; semantics named first   | Refinement to shipped code manual; drift unverified                  |
| Axiomatize the external tool (`exec`, `CmdProof`) | Compilers and linkers are outside the proof's reach         | Correctness is conditional on the axiom; instantiation is extra work |
| Prove soundness before minimality                 | Soundness is the safety property; minimality is performance | No mechanized minimality for any real system                         |

## Sparkles relevance

`sparkles.build_primitives.task` is a **static, validated** DAG with a single-pass
executor, so most of these theorems do not yet apply — and one assumption is
already an invariant.

- **Acyclicity is enforced, not assumed.** `TaskGraphBuilder.build` returns
  `GraphErrorKind.cycle`, and `stableTopologicalOrder` returns either an order or
  the shortest cycle (`order` empty, `cycle` populated). That is the hypothesis
  CoqPL had to add for termination, already discharged at construction time.
- **What is provable today is scheduling, not rebuilding.** The executor admits
  ready tasks in presentation order, records one outcome per index, and closes
  admission on the first authoritative failure. A small model could state: every
  admitted task's prerequisites finished, every index finishes at most once, and
  cancellation reaches every non-cleanup task. With no store and no rebuild
  decision, [concepts]'s correctness and minimality have nothing to range over yet
  ([pie] makes the same observation about change-driven input).
- **`EdgeCondition` makes the executed graph a subset of the planned one.** A
  minimality claim must record what _ran_, not what was declared — the `track` side
  of [a-la-carte], and the static-list restriction the Agda model had to make
  ([fbsf] §3.3). A DAG validator is not a trace.
- **The honest option is an executable model plus property tests**, then a Rocq
  core only for scheduler logic that will not change. The action driver, tracer and
  filesystem stay axioms and should be measured, not asserted ([sandboxing],
  [graph-autogeneration]).

## Sources

- Spall, Mitchell & Tobin-Hochstadt, _Forward Build Systems, Formally_, CPP 2022 —
  [DOI][fbsf-doi], [arXiv][fbsf]. Read in full; §2 assumptions, §3 model, §4
  Fabricate, §5 sequential Rattle, §6 speculation and the hazard bug, §7 related
  work.
- Lukyanov & Mokhov, _Towards a Coq Formalisation of Build Systems_, CoqPL 2019 —
  [abstract][coqpl19]. Read in full; no artifact linked, self-described incomplete.
- Christakis, Leino & Schulte, _Formalizing and Verifying a Modern Build Language_,
  FM 2014 — [manuscript][cloudmake], [DOI][cloudmake-doi]. Read §0–§4; the Dafny
  sources are referenced but were not re-run.
- Broekhoff, _Formally defining the semantics for the Nix expression language_
  (BSc thesis, 2024) — [PDF][mininix-thesis], artifact
  [`mininix-formalization`][mininix] at `c1c6979744351e139b2de9dc94d34a7b828e05a4`.
  Revision audit (2026-11-03) cloned the artifact and inspected the final
  theorems and admitted/axiom grep; the development was not recompiled.
- Broekhoff & Krebbers, _Verified Interpreters for Dynamic Languages with
  Applications to the Nix Expression Language_, PACMPL 9(ICFP), 2025 —
  [DOI][nix-verified], [artifact][nix-artifact] at
  `6a59973f275a95f10de0ddb62aa3f995c838e3a5`. Revision audit cloned the
  artifact, inspected its theorem index, final Nix theorems, extraction layout,
  and documented axiom list; the development was not recompiled and the paper
  itself was not opened.
- McKinna & Stevens, _Mechanising the Theory of Build Systems_, VeTSS report —
  [project page][vetss]. Read in full; a self-reported incomplete pilot.
- Mokhov, Mitchell & Peyton Jones, _Build systems à la carte_, JFP 30, e11 (2020) —
  [DOI][jfp]. Read §2.1, §3.6, §7.1, §8.3–§8.5.
- Spall, Mitchell & Tobin-Hochstadt, _Build Scripts with Perfect Dependencies_,
  OOPSLA 2020 — [DOI][rattle-oopsla]. §4 proves the six hazard claims semi-formally.
- Curtsinger & Barowy, _LaForge_ — [arXiv][laforge]. Read §1, §3, §6.4.
- Erdweg, Lichter & Weiel, _A Sound and Optimal Incremental Build System with
  Dynamic Dependencies_, OOPSLA 2015 — [DOI][pluto]. Manual proofs, as reported in
  [fbsf] §7.
- Rattle, clone at `$REPOS/build-systems-research/src/rattle`, commit
  `3c935ca004ec8557ad6edb92d42f8bdf5bc78f46` — [`Server.hs`][rattle-required] for
  the `required` re-check in the skip path.
- Sibling pages used: [concepts], [a-la-carte], [pie], [perfect-dependencies],
  [rattle-page], [speculative], [semantic-caching], [nix-dynamic-derivations].

<!-- References -->

[fbsf]: https://arxiv.org/abs/2202.05328
[fbsf-doi]: https://doi.org/10.1145/3497775.3503687
[coqpl19]: https://popl19.sigplan.org/details/CoqPL-2019/11/Towards-a-Coq-Formalisation-of-Build-Systems
[cloudmake]: https://www.microsoft.com/en-us/research/wp-content/uploads/2014/05/krml235.pdf
[cloudmake-doi]: https://doi.org/10.1007/978-3-319-06410-9_43
[mininix]: https://github.com/rutgerbrf/mininix-formalization/blob/c1c6979744351e139b2de9dc94d34a7b828e05a4/README.md
[mininix-thesis]: https://www.cs.ru.nl/bachelors-theses/2024/Rutger_Broekhoff___1083777___Formally_defining_the_semantics_for_the_Nix_expression_language.pdf
[nix-verified]: https://doi.org/10.1145/3747537
[nix-artifact]: https://gitlab.science.ru.nl/pl/verified-dyn-lang-interp/-/blob/6a59973f275a95f10de0ddb62aa3f995c838e3a5/README.md
[vetss]: https://wp.doc.ic.ac.uk/vetssannualreport/mechanising-the-theory-of-build-systems/
[jfp]: https://doi.org/10.1017/S0956796820000088
[rattle-oopsla]: https://doi.org/10.1145/3428237
[laforge]: https://arxiv.org/abs/2108.12469
[pluto]: https://doi.org/10.1145/2814270.2814316
[rattle-required]: https://github.com/ndmitchell/rattle/blob/3c935ca004ec8557ad6edb92d42f8bdf5bc78f46/src/Development/Rattle/Server.hs
[concepts]: ./concepts.md
[a-la-carte]: ./a-la-carte.md
[pie]: ./pie.md
[perfect-dependencies]: ./perfect-dependencies.md
[rattle-page]: ./rattle.md
[speculative]: ./speculative-execution.md
[semantic-caching]: ./semantic-caching.md
[sandboxing]: ./sandboxing-overheads.md
[graph-autogeneration]: ./graph-autogeneration.md
[dynamic-deps-distributed]: ./dynamic-deps-distributed.md
[nix-dynamic-derivations]: ./nix-dynamic-derivations.md
[nix-thesis]: ./nix-thesis.md
