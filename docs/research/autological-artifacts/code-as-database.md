# Code as a database (CodeQL, Glean, Kythe, SCIP/LSIF, ddisasm)

The reflexivity move applied to source and to disassembly: compile a codebase — or a stripped binary — into a fact base with a declared schema, then answer every tooling question as a query. Five systems, one language decision, and it is not SQL.

| Field           | Value                                                                                                                                                                                                                                                                                                                           |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Kind            | Query engines and index formats over program facts (source and machine code)                                                                                                                                                                                                                                                    |
| Language        | QL (CodeQL) · Angle (Glean) · Souffle Datalog (`ddisasm`, Kythe's verifier) · Protobuf schema (SCIP) · JSON-lines graph (LSIF)                                                                                                                                                                                                  |
| License         | CodeQL libraries MIT, **engine proprietary**; Glean BSD; Kythe Apache-2.0; SCIP Apache-2.0; `ddisasm` **AGPL-3.0**                                                                                                                                                                                                              |
| Repository      | [github/codeql][codeql-repo] · [facebookincubator/Glean][glean-repo] · [kythe/kythe][kythe-repo] · [sourcegraph/scip][scip-repo] · [GrammaTech/ddisasm][ddisasm-repo]                                                                                                                                                           |
| Documentation   | [codeql.github.com/docs][codeql-docs] · [glean.software][glean-docs] · [kythe.io][kythe-docs] · [LSIF 0.6.0 spec][lsif-spec] · [souffle-lang.github.io][souffle-docs]                                                                                                                                                           |
| First release   | Kythe (`Copyright 2014 The Kythe Authors`) · `ddisasm` (`Copyright (C) 2019 GrammaTech`; [USENIX Security 2020][ddisasm-paper]) · CodeQL from Semmle's `.QL`, GitHub-owned 2019 · LSIF 2019 · Glean open-sourced 2021 · SCIP 2022 — only the two copyright headers are verified in-tree; the rest are public-announcement dates |
| Axis profile    | Multiplicity 1 / Reflexivity 3 / Closure 2 / Mutability 1                                                                                                                                                                                                                                                                       |
| Index anchoring | Out-of-band (CodeQL, Glean, Kythe, `ddisasm`: the store _is_ the index); **header-anchored** for SCIP and LSIF                                                                                                                                                                                                                  |
| Dispatch owner  | Consumer                                                                                                                                                                                                                                                                                                                        |

> **Revisions surveyed:** `github/codeql` @ `b756a08c` (2026-08-26) · `facebookincubator/Glean` @ `dcae3b31` (2026-08-25) · `kythe/kythe` @ `26056edf` (2026-07-16) · `sourcegraph/scip` @ `a7b9c65a` (2026-08-25) · `GrammaTech/ddisasm` @ `4bc2beef` (2026-07-07, `version.txt` 1.9.6). **Platform:** all five are host tools; `ddisasm` targets ELF and PE across x86-32/64, ARM32/64, MIPS32.

> [!NOTE]
> This page treats five systems as one subject because they answer the _same_ question — "what is the general query surface over a program?" — and because their disagreements are the finding. Where the argument needs a single system in depth, the depth is here; where a sibling owns the ground, it is linked rather than re-surveyed. The umbrella is [Autological Artifacts][index].

---

## Overview

### What it solves

Every non-trivial program tool re-implements the same three things: a parser, an in-memory graph, and a traversal. `grep` is fast and wrong; a compiler plugin is right and unshareable; an AST-walking linter is right, shareable, and has to be rewritten per language. The code-as-database wager is that all three collapse if you **materialize the program as relations once** and expose a **declarative query language** over them. Write the traversal as a rule instead of a visitor; ship the rule instead of the tool.

The five systems split cleanly on what they think that means:

| System    | Artifact                                                                      | Query surface                                     | Recursion in queries                                       |
| --------- | ----------------------------------------------------------------------------- | ------------------------------------------------- | ---------------------------------------------------------- |
| CodeQL    | A **database directory**: relations + `.dbscheme` + `.stats` + source archive | QL — a Datalog dialect with classes               | **Yes**, least-fixed-point, plus `+`/`*` closure operators |
| Glean     | A **RocksDB/LMDB store** of typed, deduplicated, DAG-shaped facts             | Angle — Datalog-derived, Thrift-typed             | **No** in production (`--experimental-recursion` only)     |
| Kythe     | A **graph store** of 5-tuple entries; storage format, not serving format      | None built in; the _verifier_ compiles to Souffle | Yes, but only in the verifier                              |
| SCIP/LSIF | A **transmission file** (protobuf / JSON-lines); explicitly not a database    | None — "best served by a query engine"            | N/A                                                        |
| `ddisasm` | A **GTIRB IR file**, optionally carrying its own fact base as `AuxData`       | Souffle Datalog, 79 `.dl` modules, 635 relations  | Yes — the disassembly _is_ a fixpoint                      |

The cluster question in the source outline is stated as an open one: _SQL or Datalog?_ The field has answered. Four of the five that have a query language at all chose Datalog or a Datalog descendant; the fifth (Glean) chose Datalog's syntax and semantics and then removed the recursion. The one place SQL appears is `scip expt-convert`, an experimental dump of an index format into SQLite for eyeballing — and it has to invent integer surrogate keys that SCIP was explicitly designed to avoid.

### Design philosophy

CodeQL's language specification opens by naming the lineage without hedging:

> _"QL is a query language for CodeQL databases. The data is relational: named relations hold sets of tuples. The query language is a dialect of Datalog, using stratified semantics, and it includes object-oriented classes."_
>
> — [`docs/codeql/ql-language-reference/ql-language-specification.rst`][ql-spec]

And the language guide is explicit that the SQL resemblance is skin deep:

> _"The syntax of QL is similar to SQL, but the semantics of QL are based on Datalog, a declarative logic programming language often used as a query language. This makes QL primarily a logic language, and all operations in QL are logical operations. Furthermore, QL inherits recursive predicates from Datalog, and adds support for aggregates, making even complex queries concise and simple."_
>
> — [`docs/codeql/ql-language-reference/about-the-ql-language.rst`][ql-about]

Glean says the same thing and then draws a line:

> _"A query engine implementing our declarative query language Angle. Angle is a logic language with similarities to Datalog, but with extensions that make it suitable for building complex queries over Glean data. Like in Datalog, Glean can derive new facts automatically by defining rules using Angle."_ … _"If you're familiar with Datalog, it's worth noting that currently Angle is limited to non-recursive queries only."_
>
> — [`glean/website/docs/introduction.md`][glean-intro]

`ddisasm` does not merely query with Datalog; it _is_ Datalog:

> _"DDisasm is a fast disassembler which is accurate enough for the resulting assembly code to be reassembled. DDisasm is implemented using the datalog (souffle) declarative logic programming language to compile disassembly rules and heuristics."_
>
> — [`README.md`][ddisasm-readme]

SCIP takes the opposite position — it refuses to be a database at all:

> _"SCIP is meant to be a **transmission** format for sending data from some producers to some consumers -- it is not meant as a **storage** format for querying."_ … Non-goal: _"Support efficient code navigation by itself. Why: Code navigation fundamentally requires some form of bidirectional lookup which is best served by a query engine."_
>
> — [`docs/DESIGN.md`][scip-design]

LSIF, its predecessor, says it even more plainly: _"The dump doesn't contain any program symbol information nor does the LSIF define any symbol semantics… The LSIF therefore doesn't define a symbol database."_ ([LSIF 0.6.0][lsif-spec]).

That is the split this page is about: **query engines** (CodeQL, Glean, `ddisasm`, and Kythe-via-verifier) versus **index formats** (SCIP, LSIF, and Kythe's own storage layer). It is exactly the header/footer/out-of-band question from [Footer-indexed formats][footer] moved up one level — is the index _inside the artifact_, or is it a payload someone else has to load?

---

## How it works

### CodeQL: extract to relations, compile QL down to relational algebra

A CodeQL database is built in three steps, from [`about-codeql.rst`][codeql-about]: extract each source file into a relational representation (for compiled languages by _observing the build_, wrapping the compiler; for interpreted ones by running the extractor directly), import the resulting TRAP files under a language-specific schema, then run queries.

The schema is a text file with a `.dbscheme` extension declaring the extensional relations and their column types. From [`cpp/ql/lib/semmlecode.cpp.dbscheme`][cpp-dbscheme]:

```text
exprs(
    unique int id: @expr,
    int kind: int ref,
    int location: @location_default ref
);

exprparents(
    int expr_id: @expr ref,
    int child_index: int ref,
    int parent_id: @exprparent ref
);
```

`@expr` is an _entity type_; `int ... ref` is a foreign key. The QL standard library then wraps `exprs` in a class `Expr`, so a query reads as object-oriented navigation and compiles to joins. The C++ schema alone runs to a few thousand lines and the standard library across all languages is 7,675 `.ql` and 5,606 `.qll` files in the surveyed tree — the abstraction over the tables _is_ the product.

Compilation goes QL → **DIL** ("Datalog Intermediary Language") → relational algebra → a `.qlo` binary, per the [glossary][codeql-glossary]. Evaluation is bottom-up and layered:

> _"A QL program is evaluated from the bottom up, so a predicate is usually only evaluated after all the predicates it depends on are evaluated. … The remaining predicates and types in the program are organized into a number of layers, based on the dependencies between them. These layers are evaluated to produce their own sets of tuples, by finding the least fixed point of each predicate."_
>
> — [`evaluation-of-ql-programs.rst`][ql-eval]

Those layers are strata. Recursion is a first-class feature with two conveniences — `p.getAParent+()` is transitive closure, `p.getAParent*()` reflexive-transitive — and two guardrails the compiler enforces, described in [`recursion.rst`][ql-recursion]: an _empty recursion_ (no base case) is a compile error, and recursion must be **monotonic**, meaning "(mutual) recursion is only allowed under an even number of negations." The doc gives the reason as a liar's paradox, `predicate isParadox() { not isParadox() }`, which "holds precisely when it doesn't hold. This is impossible, so there is no fixed point solution to the recursion."

Alongside the schema, a CodeQL pack ships a `.stats` file — an XML table of per-type cardinalities, e.g. [`ql/ql/src/ql.dbscheme.stats`][ql-stats] — feeding the cost-based optimizer. A code database that carries its own cardinality estimates is a query planner input shipped as data; hold that thought for [Dynamic linking][dynlink] and the outline's "symbol binding as query planning" question.

> [!NOTE]
> The tree also contains [`ql/ql/src/ql.dbscheme`][ql-dbscheme] — "CodeQL database schema for QL / Automatically generated from the tree-sitter grammar" — so CodeQL analyses CodeQL. That is autology in the strict linguistic sense, though not in this catalog's byte-stream sense: the QL database is still a separate artifact from the `.ql` files it describes.

### Glean: typed facts, a DAG, and stored derivations

Glean stores **facts**: a fact ID, a predicate ID, and binary-serialized key and value. Two tables carry the weight, per [`implementation/db.md`][glean-db]: `entities` maps fact IDs to (key, value), and `keys` maps fact keys back to fact IDs — with the fact ID encoding chosen "so that iterating in lexicographic order returns facts in numeric order."

The crucial structural constraint is stated in [`schema/recursion.md`][glean-recursion]: predicates may be mutually recursive, but the _facts_ may not form a cycle. "each new fact added to the database can only refer to earlier facts via its key" — which is what makes batch dedup and reference substitution tractable. Facts are recursive in their values but not their keys. A Glean database is therefore a DAG by construction, and a fact ID is a topological rank.

Because query-time recursion is off, Glean pushes transitive work into the schema as **derived predicates** ([`derived.md`][glean-derived]). A `stored` derived predicate is a materialized view computed by `glean derive` before the database is finished; an on-demand one is a macro expanded at query time. Derivation order is manual and acyclic: "these predicates must be independent; they cannot depend on each other. If you have derived predicates that depend on each other, you have to issue separate `glean derive` commands to derive the predicates in bottom-up dependency order." That is hand-executed stratification — the thing CodeQL's compiler does for you.

Recursion is not absent from the codebase, only from production. `Glean/Query/Flatten.hs` inlines derived-predicate calls and refuses cycles unless a flag is set:

```haskell
-- glean/db/Glean/Query/Flatten.hs
    | EnableRecursion <- recursion -> return seek
    | otherwise ->
      throwError $ "recursive reference to predicate " <>
        Text.pack (show (displayDefault ref))
```

and the flag is [`--experimental-recursion`][glean-config], help text: _"Experimental support for recursive predicates. For testing only"_, marked `internal`. With it on, `Glean/Query/Codegen.hs` wraps the compiled statement block in a `recursive` bytecode construct; with it off, the block is emitted flat. The default in `Config.hs` is `cfgEnableRecursion = False`.

### Kythe: a schema-free 5-tuple store, and a verifier that is Datalog

Kythe's storage model is deliberately the thinnest thing that can hold a graph. An **entry** is:

```text
source [ticket] | kind | target [ticket] | fact label | value
```

with the invariant that either `kind` and `target` are both empty (a node fact) or both non-empty (an edge fact) — see [`kythe-storage.txt`][kythe-storage]. Nodes are named by **VName**, a five-field vector (`signature`, `corpus`, `root`, `path`, `language`) chosen so that a name is itself a projection of facts about the node. Fact labels are path-structured strings (`/kythe/…`), values are uninterpreted bytes.

The document's _Non-Goals_ section is the most interesting paragraph in this entire survey, because it declines both properties the other four systems consider essential:

> _"**Query efficiency**:: This representation is for storage, not serving, so it is not optimized for general-purpose searching or queries. Separate indexes should be extracted for those purposes._
>
> _**Schematization and validation**:: The storage representation here does not include a schema for its contents, apart from the structure of the data itself. A schema for what facts should be stored, their exact value formats, and other validation constraints are outside the scope of this document. Keys and values are stored as strings."_
>
> — [`kythe/docs/kythe-storage.txt`][kythe-storage]

Kythe pushes both jobs downstream: consumers "synthesize new facts" (the doc names "precomputation of transitive closure relations" as an example) and "extract indexes" into denormalized serving tables.

And yet Kythe _does_ have a Datalog engine — in its test harness. The verifier checks that an indexer's output supports a set of goals written as magic comments in the source under test. Its default engine, per [`verifier_main.cc`][kythe-verifier-main] (`ABSL_FLAG(bool, use_fast_solver, true, …)`), lowers those goals into a Souffle program whose preamble is a literal transcription of the storage model:

```prolog
// kythe/cxx/verifier/assertions_to_souffle.cc (kGlobalDecls, abridged)
.type vname = [
  signature:number, corpus:number, root:number, path:number, language:number
]
.decl sym(id:number)
sym(0).
sym(n + 1) :- sym(n), n >= 1.
.decl entry(source:vname, kind:number, target:vname, name:number, value:number)
.input entry(IO=kythe)
.decl anchor(begin:number, end:number, vname:vname)
.input anchor(IO=kythe, anchors=1)
```

A project that refused to define a query language for its store nevertheless reached for Souffle the moment it needed to _assert_ things about program structure. That is the convergence showing up as a revealed preference rather than a stated one.

### SCIP and LSIF: index formats, not engines

SCIP is one protobuf message. `Index` holds `Metadata`, a repeated `Document`, and optional `external_symbols`; each `Document` holds `Occurrence`s and `SymbolInformation`. Symbols are **globally meaningful strings** with a specified grammar (`<scheme> ' ' <package> ' ' (<descriptor>)+`, or `local <local-id>`), not integers into a table. [`docs/DESIGN.md`][scip-design] names that choice and its reason: integer IDs in LSIF were "primarily present as an ad-hoc compression scheme due to the verbosity of JSON and LSIF's graph-based encoding scheme," and "with LSIF, we've had off-by-one bugs in indexers cause code navigation to fail repo-wide." Avoiding surrogate keys limits an indexer bug's blast radius to the symbol it mis-names.

The same document rejects a graph encoding outright — "Avoid direct encoding of graphs" — on production-side grounds: an adjacency-list encoding "encourages a wholesale approach to writing indexers as it involves merging all the data together," and forces the indexer to hold the whole codebase in memory instead of appending one file's worth of data and moving on.

LSIF is the design SCIP reacted against: a JSON-lines stream of vertices and edges, with emission-order constraints that make it a topologically-sorted graph dump rather than a random-access file — _"a vertex needs to be emitted before it can be referenced in an edge"_, and after a document-end event "the document data so to speak can not be altered anymore" ([LSIF 0.6.0, Emitting constraints][lsif-spec]). Its stated principal design goal is that "the format should not imply the use of a certain persistence technology," which is precisely why it is not a database.

### `ddisasm`: disassembly as a least fixed point

`ddisasm` is the clearest case in the catalog of a _program analysis that is literally a Datalog program_. The C++ front end decodes a superset of possible instructions at every address and emits them as facts; `src/datalog/main.dl` declares the interface between the two, and it reads like a schema:

```prolog
// src/datalog/main.dl
.decl instruction(ea:address,size:unsigned,prefix:symbol,opcode:symbol,
          op1:operand_code,op2:operand_code,op3:operand_code,op4:operand_code,
          immOffset:unsigned,displacementOffset:unsigned)
.input instruction
.output instruction

.decl relocation(EA:address,Type:symbol,Name:symbol,Addend:number,
          SymbolIndex:unsigned,Section:symbol,RelType:symbol)
.input relocation

.decl symbol(ea:address,size:unsigned,type:symbol,scope:symbol,
          visibility:symbol,sectionIndex:unsigned,originTable:symbol,
          tableIndex:unsigned,name:symbol)
.input symbol
```

Code discovery is then a fixpoint over "may-fallthrough" and "must-fallthrough" edges, with stratified negation doing the block-splitting, from [`src/datalog/code_inference.dl`][ddisasm-codeinf]:

```prolog
// start a new block given a possible target
code_in_block_candidate(EA,EA):-
    possible_target(EA),
    possible_ea(EA).

// Extend the block as long as we are sure to fallthrough and we have not
// reached a block limit
code_in_block_candidate(EA,Start):-
    code_in_block_candidate(EA2,Start),
    must_fallthrough(EA2,EA),
    !block_limit(EA),
    !transition_block_limit(EA2,EA).
```

The surveyed tree has 79 `.dl` modules, 22,320 lines, 635 `.decl` relations and 111 `.input`/`.output` directives, built against Souffle 2.4 configured with `-DSOUFFLE_DOMAIN_64BIT=1` ([`2-Building-Ddisasm.md`][ddisasm-build]). Ambiguous cases that the "must"/"may" propagation cannot settle are resolved by a _weighted interval scheduling_ pass over per-heuristic point totals, and — this is the tell that Datalog is being used as an engine rather than a notation — the heuristic weights are themselves facts a user can overwrite from the command line:

```text
disassembly.user_heuristic_weight   overlaps with relocation simple -4
```

changes the weight of the "overlaps with relocation" heuristic, and `disassembly.invalid 0x100 definitely_not_code` injects a fact into the database before the program runs ([`5-AdvancedUsage.md`][ddisasm-advanced]). The `--hints` file is a tab-separated CSV of predicate rows: extending an analysis is `INSERT`, not a patch.

---

## Format identity and multiplicity

Low, and honestly so. None of these artifacts is a polyglot in the sense of [Cosmopolitan/APE][ape] or [ZIP parasitism][zip]: no consumer other than the intended one is expected to parse them, and none carries a second valid header.

| Artifact             | Bytes are                                                               | Second valid parse?                                                                           |
| -------------------- | ----------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| CodeQL database      | A **directory** — relation files, `.dbscheme`, `.stats`, source archive | No. Not even one byte stream; the source archive inside it is a ZIP, but nested, not overlaid |
| Glean DB             | A RocksDB or LMDB directory                                             | No — the key/value store is an implementation choice, swappable                               |
| Kythe graph store    | Entries, in "LevelDB files, CSV, SQLite tables, Google Cloud Datastore" | Deliberately format-plural, but one at a time, not simultaneously                             |
| SCIP `index.scip`    | One protobuf `Index` message                                            | No, but protobuf TLV makes concatenation a valid merge                                        |
| LSIF dump            | JSON Lines                                                              | No                                                                                            |
| GTIRB from `ddisasm` | A protobuf IR of the binary, optionally + the whole fact base           | **Closest case** — see below                                                                  |

The one interesting entry is `ddisasm`'s `--with-souffle-relations`, which packages "facts/output relations into an `AuxData` table" ([`3-Command-line-options.md`][ddisasm-cli]). The `AuxData` schemas are declared as CSV-with-type-signature maps:

```cpp
// src/AuxDataSchema.h
/// \brief Auxiliary data for Souffle fact files.
struct SouffleFacts
{
    static constexpr const char* Name = "souffleFacts";
    // Entries of the form {Name, {TypeSignature, CSV}}.
    typedef std::map<std::string, std::tuple<std::string, std::string>> Type;
};
```

and `writeRelationAuxdata` in [`DatalogAnalysisPass.cpp`][ddisasm-pass] fills them from `Program.getInputRelations()`, `getInternalRelations()` and `getOutputRelations()`. The resulting GTIRB file is simultaneously (a) an intermediate representation of the program and (b) the complete Datalog database, input and derived, that justifies it. That is a genuinely autological artifact: the binary IR carries the evidence for its own contents, and a consumer can re-run the reasoning without re-running the decoder. Multiplicity 1 in this cluster is earned by that one flag.

Prefix- and suffix-tolerance are mostly irrelevant here — but the SCIP/LSIF pair is instructive anyway. SCIP is protobuf, and the design doc calls out that "TLV format enables streaming reads and writes as well as merging by concatenation": two SCIP indexes concatenated are a valid SCIP index, because repeated fields merge. That is _suffix-tolerance by construction of the encoding_, the same structural property that makes ZIP parasitism work, arrived at from the schema side rather than the container side. LSIF has the opposite property — its emission constraints are a partial order, so concatenation is only valid if the second dump's vertices do not forward-reference the first's.

## Index anchoring and random access

This is where the query-engine/index-format split becomes mechanical.

**The engines put the index inside the store, out-of-band from any file.** A CodeQL database is a directory whose _whole content_ is indexes; the `.qlo` compiled query is a relational-algebra plan against them, and the `.stats` cardinalities steer it. Glean's `keys` table is the index and the `entities` table the heap, with fact-ID encoding chosen so lexicographic iteration is numeric iteration — a b-tree ordering constraint pushed into the identifier scheme. `ddisasm` builds indexes per relation inside Souffle's runtime and throws them away at exit unless `--with-souffle-relations` or `--debug-dir` keeps them (the pass sets `pruneImdtRels = !WriteSouffleOutputs && DebugDirRoot.empty()`).

**The formats put a header at offset 0 and stop there.** SCIP's `Index` message is explicit:

```proto
// scip.proto
// An Index message payload can have a large memory footprint
// and it's therefore recommended to emit and consume an Index payload one field
// value at a time. To permit streaming consumption of an Index payload, the
// `metadata` field must appear at the start of the stream and must only appear
// once in the stream. Other field values may appear in any order.
message Index {
  Metadata metadata = 1;
  repeated Document documents = 2;
  repeated SymbolInformation external_symbols = 3;
}
```

That is a **header-anchored, single-pass, no-random-access** format: `metadata` first so a streaming reader knows the project root and text encoding, everything else in arbitrary order, and no offset table anywhere. Finding all references to a symbol requires reading every `Document`. LSIF is worse in the same direction — its ordering constraints make it a topologically-sorted stream, and the 0.4.0 changelog entry says why the constraints exist at all: up to 0.4.0 "it was very hard for consumers of the dump to efficiently import them into a DB unless the DB format one to one mapped to the LSIF format," so the format added _events_ announcing when data is ready to be consumed. An index format that has to add lifecycle events so consumers can incrementally load it is admitting that it needs a loader.

Compare [Footer-indexed formats][footer]: ZIP and Parquet put a directory at the end precisely so a ranged reader can find everything with two reads. SCIP and LSIF deliberately do not, because the design target is _ingest into someone else's database_, not query. The consequence is that the "query a remote artifact over HTTP range requests" trick that [Range-request access][range] describes for SQLite and Parquet is **impossible for SCIP and LSIF and unnecessary for CodeQL and Glean** — the former have no index to seek into, the latter are directories on a server you were going to talk to anyway.

## Reflexivity and query surface

The five systems score 3 on reflexivity as a cluster because interrogation through a general query surface is the entire premise. But the interesting content is _which_ surface, and why.

### The convergence, stated with evidence

| System              | Language        | Datalog lineage                                                                | Recursive queries                                                                |
| ------------------- | --------------- | ------------------------------------------------------------------------------ | -------------------------------------------------------------------------------- |
| CodeQL              | QL              | "a dialect of Datalog, using stratified semantics" ([spec][ql-spec])           | Yes — least fixed point, `+`/`*` closures, monotonicity enforced                 |
| Glean               | Angle           | "a logic language with similarities to Datalog" ([intro][glean-intro])         | **No** — `--experimental-recursion`, "For testing only" ([config][glean-config]) |
| Kythe (verifier)    | Souffle Datalog | Compiles goals directly to `.dl` ([`assertions_to_souffle.cc`][kythe-souffle]) | Yes                                                                              |
| `ddisasm`           | Souffle Datalog | The analysis _is_ the Datalog program                                          | Yes — code discovery is a fixpoint                                               |
| SCIP `expt-convert` | SQL (SQLite)    | None                                                                           | Would be a recursive CTE; nothing ships one                                      |

Four of five with a query language chose Datalog; the fifth chose Datalog and disabled the recursion. No system in this survey chose SQL as its _primary_ surface. The single SQL appearance is an experimental CLI subcommand whose own help says "For inspecting the data, use the SQLite CLI" ([`docs/CLI.md`][scip-cli]) — a debugging affordance, not an engine.

### What Datalog gives you that a recursive CTE does not

The outline's open question asks whether the ergonomic gap is real. It is, and it decomposes into four separable things.

**1. Termination.** Souffle evaluates to a least fixed point over a finite Herbrand universe: rules that only _select_ from existing constants cannot invent new ones, so the derivation is monotone and bounded and stops. Souffle's own gloss: "The EDB represents the uncooked Soufflé and the IDB causes the Soufflé to rise, i.e., monotonically increasing knowledge. When it stops rising and a fixed-point is reached, the result is a puffed-up ready-to-eat Soufflé" ([souffle-lang.github.io][souffle-docs]).

SQLite offers no such guarantee, and says so operationally rather than semantically. From the graph-query example in [`lang_with.html`][sqlite-with]: _"UNION is used instead of UNION ALL to prevent the recursion from entering an infinite loop if the graph contains cycles."_ Termination on a cyclic dependency graph is the query author's responsibility, discharged by remembering one keyword. That is a footgun with a nine-character fix and no compiler help — and dependency graphs in the wild _do_ contain cycles: `libc.so.6` and `libgcc_s.so.1` are the canonical pair.

**2. Fixpoint semantics vs. queue semantics.** SQLite's recursive CTE is not a set-at-a-time fixpoint. The specification is explicit that it is a worklist over _individual rows_:

> _"Run the initial-select and add the results to a queue. While the queue is not empty: Extract a single row from the queue. Insert that single row into the recursive table. Pretend that the single row just extracted is the only row in the recursive table and run the recursive-select, adding all results to the queue."_

Datalog engines instead run **semi-naive** evaluation: each iteration joins the _delta_ of each recursive relation against the full others, so a rule with two recursive body atoms becomes several rule versions. Souffle's tuning guide shows the transformation directly:

```text
A(x) :- B(x), C(x).
   Version 0: A(x) :- Δ B(x), C(x)
   Version 1: A(x) :- B(x), Δ C(x)
```

with "Δ B(x) includes only the new tuples of B generated in the previous stage of the semi-naive evaluation" ([handtuning][souffle-tuning]). The practical difference is that a Datalog engine performs _set-oriented_ joins with indexes chosen per rule version, while a recursive CTE re-executes a row-parameterized query per frontier row. For symbol resolution over a few hundred shared objects the difference is academic; for `ddisasm`'s code discovery over millions of candidate addresses it is the difference between working and not.

**3. Stratified negation.** The interesting queries over code are almost all negative: _which imports are satisfied by nothing in the closure?_ _which blocks are not reachable?_ _which symbols are exported but never referenced?_ Datalog gives negation a defined semantics via stratification — Souffle rejects `A(x) :- !B(x). B(x) :- !A(x).` as a "circular definition… Technically, rules involving negation must be stratifiable" ([rules][souffle-rules]) — and requires negated literals to be range-restricted: `A(x,y) :- R(x), !S(y).` is invalid because "the set of values that y can take is not clear," so the author must supply a `Scope(y)` relation. CodeQL enforces the same discipline as the even-number-of-negations rule and reports a violation as a compile error ([`recursion.rst`][ql-recursion]).

SQL's recursive CTE forbids the composition entirely in the other direction: the recursive `SELECT` must reference the recursive table **exactly once** in its `FROM` clause and "must not appear anywhere else in either the initial-select or the recursive-select, **including subqueries**." A `NOT EXISTS (SELECT … FROM closure …)` inside the recursive step is therefore syntactically illegal. Recursive aggregates are likewise banned: "Recursive SELECT statements may not use aggregate functions or window functions." Between them, those two restrictions rule out most of the queries that motivate having a fixpoint in the first place.

**4. Mutual recursion and ergonomics.** QL's mutual recursion (`getAnEven`/`getAnOdd` in [`recursion.rst`][ql-recursion]) and `ddisasm`'s mutually recursive `code_in_block_candidate` / `may_fallthrough` / `block_limit` cluster have no direct SQL analogue: each recursive CTE names one recursive table, so a mutually recursive pair of relations must be manually fused into a single tagged relation with a discriminator column. And the closure operators matter more than they look: `p.getAParent+()` is one token; the SQL equivalent is a nine-line `WITH RECURSIVE` block that has to be rewritten for every edge relation.

> [!IMPORTANT]
> None of this makes SQL the wrong substrate for the _storage_. It makes SQL the wrong surface for the _transitive_ queries. The two decisions are separable — which is the whole point of the next section.

### What a Datalog front-end over SELF's tables would look like

[SELF/selfdb][self] stores an executable as a SQLite database with tables `segments`, `symbols`, `relocations`, `needed`, `dynamic_entries`, `sections`, `notes` and shipped views `exports`, `imports`, `ldd` ([`schema/self.sql`][self-schema]). Its design document already identifies the transitive queries as the payoff:

> _"M3 is where the pitch lands: **`ldd` is a recursive CTE, `ldconfig` is an index, and 'which library will actually satisfy this symbol?' — today a gdb-or-suffering question — is a JOIN.**"_
>
> — [`DESIGN.md`][self-design]

Notice which of the three is the weak link. `ldconfig`-as-an-index and symbol-satisfaction-as-a-`JOIN` are flat relational queries and SQL does them well. `ldd`-as-a-recursive-CTE is the one that inherits every caveat above. The experiment the outline calls "small and high-signal" is therefore precisely: **keep the store, swap the surface for the transitive part.**

Concretely. SELF's system-wide layer is an `objects` resolver table plus `ATTACH` of each `.self` file, so the extensional database is already assembled by the time a query runs:

```sql
-- selfdb DESIGN.md §7: the resolver DB and the ATTACH trick
CREATE TABLE objects (
  id INTEGER PRIMARY KEY,
  path TEXT UNIQUE, build_id BLOB, soname TEXT, machine TEXT
);
CREATE INDEX idx_soname ON objects(soname, machine);
```

Export four EDB relations out of that — three of them are literally existing tables and views — and the dependency closure is four lines of Souffle:

```prolog
// EDB: dumped from the ATTACHed .self databases + the resolver DB
.decl root(Obj:symbol)
.input root
.decl needs(Obj:symbol, Soname:symbol)          // per-object `needed` table
.input needs
.decl provides(Soname:symbol, Obj:symbol)       // resolver `objects` table
.input provides

// IDB: the transitive closure. Terminates by construction; cycles are free.
.decl closure(Obj:symbol)
.output closure
closure(O)  :- root(O).
closure(O2) :- closure(O1), needs(O1, S), provides(S, O2).

// "which imports does nothing in the closure satisfy?" -- stratified negation,
// which a recursive CTE cannot express at all.
.decl unresolved(Obj:symbol, Name:symbol, Version:symbol)
.output unresolved
unresolved(O, N, V) :-
    closure(O), imports(O, N, V),
    !exists_export(N, V).
.decl exists_export(Name:symbol, Version:symbol)
exists_export(N, V) :- closure(P), exports(P, N, V).
```

The SQL that this replaces is not much longer, but it is materially more fragile:

```sql
WITH RECURSIVE closure(path) AS (
    SELECT :root
    UNION                              -- NOT `UNION ALL`: dedup is the only
                                       -- thing preventing non-termination
    SELECT o.path
      FROM closure c
      JOIN needs   n ON n.object = c.path
      JOIN objects o ON o.soname = n.soname
)
SELECT path FROM closure;
```

Three concrete deltas, all checkable:

1. **`needs` does not exist as a single table.** Each `.self` file owns its own `needed` table; a recursive CTE cannot `ATTACH` a database it discovers mid-recursion, so `needs` has to be a pre-materialized union — i.e. the closure has to already be known before the closure query can run. The Datalog version has the same problem, and it is _the same problem_, but it is now visible as "the EDB extractor is a fixpoint too" rather than hidden inside a join. A SQLite [virtual table][sqlelf] or table-valued function over the resolver DB is the honest fix on either side.
2. **`unresolved` has no SQL form.** `ldd -r`'s question — which imports nothing in the closure provides — needs negation _inside_ the recursion's scope. SQLite forbids referencing the recursive table in a subquery, so this becomes two statements and a temp table.
3. **Symbol resolution order is where Datalog stops winning.** `ld.so` binds to the _first_ definition in breadth-first scope order, which is a recursive minimum, not a reachability question. Souffle expresses it with stratified aggregation over a derived depth relation; SQLite expresses it with `ORDER BY … LIMIT 1` over a materialized scope — which is [what `selfdb`'s design already writes][self-design]. Here the CTE's row-at-a-time queue is arguably the closer fit, because BFS order falls out of the queue discipline. An honest experiment should report this as the case where SQL wins.

The measurable artifact is small: an `elf2facts` step that dumps `needs`/`provides`/`imports`/`exports` as tab-separated Souffle inputs, a ~40-line `.dl` program, and a comparison against the equivalent CTEs on a real closure. See [Measurement][measure] for the harness conventions this catalog uses, and [Open questions][open] for where this sits in the list.

### Self-inspection at runtime

Weak across the cluster, and this is the axis on which code-as-a-database differs most sharply from [SELF][self] and [redbean][ape]. A CodeQL database is a _description of_ a program, produced by observing its build; the program cannot query it while running, and the database does not travel with the binary. Glean's databases live on a server behind Thrift. Kythe's stores are batch artifacts. SCIP indexes are uploaded to Sourcegraph.

`ddisasm` is again the exception, and only under one flag: with `--with-souffle-relations` the GTIRB carries `souffleFacts` and `souffleOutputs`, so a later tool — `gtirb-rewriting`, a verifier, an analyst — can query the reasoning that produced the IR _from the IR itself_, with no re-decoding and no side-car. That is the same structural claim [`sqlelf`][sqlelf] makes about ELF (a query surface over a binary) with one addition: the derived relations, not just the extensional ones, are in the file.

## Closure, dedup, and size model

**What travels.** The five artifacts disagree about what an artifact must carry to be interpretable, and the disagreement lines up exactly with thesis 2 of the source outline (_self-description is what makes a format survivable_).

| Artifact  | Carries its schema?                                                            | Carries the source?                                   | Carries statistics?         |
| --------- | ------------------------------------------------------------------------------ | ----------------------------------------------------- | --------------------------- |
| CodeQL    | **Yes** — "the extractor copies its schema into the database"                  | **Yes** — a source archive, "typically in ZIP format" | Yes — `.stats`              |
| Glean     | **Yes** — "stored in the DB itself along with the full schema source"          | No                                                    | Per-predicate `stats` table |
| Kythe     | **No** — explicitly a non-goal                                                 | No (file content facts optional)                      | No                          |
| SCIP      | Schema is out-of-band (`scip.proto` + `ProtocolVersion`)                       | Optional `Document.text`, discouraged                 | No                          |
| `ddisasm` | GTIRB `AuxData` type signatures, per relation, with `--with-souffle-relations` | The binary, in full                                   | No                          |

CodeQL and Glean both made the same call for the same reason: a database whose schema evolves must carry the schema it was written under or it becomes unreadable. CodeQL uses it as a compatibility check — "The CLI uses this to check whether the CodeQL database is compatible with a particular CodeQL library. If they aren't compatible you can use `database upgrade`" ([glossary][codeql-glossary]) — and ships an entire `downgrades/` tree of SHA-named schema pairs (`old.dbscheme` + the target scheme) to migrate old databases forward and back. The surveyed tree contains 1,187 `.dbscheme` files, the overwhelming majority of them migration snapshots. That is what a self-describing format's version history looks like when you actually keep it.

Kythe, which declined a schema, is the control case: its entries are strings whose meaning is defined by a document, and consumers must know the `/kythe/…` fact-label conventions out of band. This is precisely the failure mode the outline attributes to ELF and tar — "formats without one accrete conventions instead" — and Kythe accreted them by design, on the theory that a storage format should not constrain a serving format. The cost is that a Kythe entry stream is uninterpretable without the schema documentation, and that "which facts are valid" is nowhere machine-checkable.

**Dedup.** Glean is the only member with real, structural deduplication: facts are content-keyed and "automatically de-duplicated by the storage backend" ([introduction][glean-intro]), which is why the DAG-not-cycle constraint exists — dedup and reference substitution happen batch-wise, and cyclic keys would make that "significantly harder." The size analysis in [`implementation/db.md`][glean-db] is unusually candid: because both `keys` and `entities` store the key, "for each fact, the key is stored twice… So this representation is rather wasteful of space, particularly for facts that have large keys," and the mitigation is to truncate the `keys`-table key to a bounded prefix and let equal prefixes collide into a fact-ID-ordered run. Glean adopted the truncated form even where RocksDB permits long keys.

Glean's incremental machinery gives the only concrete ratio in the survey. Facts are annotated with **units** (typically one per file or module) and each fact's owner is an _ownership set_ — a unit, a disjunction, or a conjunction — assigned a `UsetId`, with propagation defined so that "In a DB consisting of all the visible facts for a given set of excluded units, every fact referenced by a visible fact is also visible." The efficiency argument is stated as a measured expectation:

> _"The efficiency of this scheme depends on the assumption that while there are a lot of facts, there are relatively few distinct ownership sets. Typically we see between 10-100x more facts than sets. … This assumption rests on the indexer using a coarse enough range of units; one unit per file or module is good, but one unit per function would lead to more sets."_
>
> — [`implementation/incrementality.md`][glean-incr]

That propagation — walk facts in reverse ID order, union the owner sets of everything a fact references into its own — is a **mark phase over a DAG in a single pass**, `O(facts)` time and space. It is exactly the shape the outline's cluster-E open question asks for over a [SELF closure database][nix-closures]: roots are the non-excluded units, reachability is the fact DAG, and the answer is a bitmap slice rather than a delete. Glean gets to skip the hard part — it never sweeps, it builds a new stacked database — but the mark phase is real, shipped, and costed.

**Sizes.** Only SCIP publishes a compression figure, and it is a design justification rather than a measurement: being compact uncompressed is a stated non-goal because "modern general-purpose compression formats like gzip and zstd are already very good," and in practice "SCIP data tends to be have a compression ratio around in the range of 10%-20%, as modern compressors are very good at de-duplicating away the repetitive textual symbols." That is the string-keys decision paying for itself: the redundancy that surrogate integers would have removed is removed by the compressor instead, at zero design cost and zero blast radius.

## Mutability, dispatch, and trust

**Mutability is low and deliberately so.** These are write-once artifacts. Glean has an explicit lifecycle: facts are written, `glean complete` marks predicates complete and computes ownership sets, `glean derive` materializes stored derived predicates, `glean finish` closes the database — and derivation must happen _before_ finishing. CodeQL databases are built then queried; the only mutation is `database upgrade` against a newer `.dbscheme`. Kythe stores are append-and-merge ("Multiple store files can be easily combined to aggregate stores containing results from separate analyses"). SCIP and LSIF are files you produce and upload.

`ddisasm` is the exception on this axis too, in a different direction: it exists to _produce a mutable artifact_. Its output feeds `gtirb-rewriting` and `gtirb-pprinter`, and the round trip — disassemble, rewrite, reassemble — is the product. A GTIRB carrying `souffleFacts`/`souffleOutputs` is a mutable program representation that also carries the evidence for its own decoding, which is the closest thing in this cluster to the [self-modifying artifact][self] the catalog is really about.

**Dispatch is always the consumer.** No kernel, shell, or loader ever decides what these files are. SCIP is identified by convention (`index.scip`) and by being handed to a tool that expects it; LSIF by `.lsif` and JSON-lines shape; a CodeQL database by the presence of `codeql-database.yml`; a Glean DB by being in the server's DB root. None registers with `binfmt_misc`, none has a magic number the kernel knows, and the contrast with [SELF's `application_id` at byte 68][self] and [`binfmt_misc` dispatch][binfmt] is total: those are formats that want to _be executed_, these are formats that want to _be read by exactly one program_. There is no ambiguity to exploit and therefore no [parser differential][differentials] surface at the identification layer.

**Trust is where the model is thinnest.** Three specific exposures:

1. **Extraction is arbitrary code execution by design.** CodeQL's compiled-language extraction "works by monitoring the normal build process" — the extractor wraps the compiler and runs the project's build system. Building an untrusted repository to analyze it means executing it. This is a known and accepted property of the model, not a bug, but it means a code database is only as trustworthy as the build that produced it.
2. **Facts are unauthenticated and merge freely.** Kythe's whole composability story is that "multiple store files can be easily combined." Nothing in the entry format binds a fact to the analyzer that produced it, so a merged store has no per-fact provenance. `ddisasm`'s `--hints` mechanism is the sharpest form: a tab-separated file injects facts directly into the analysis database, and `user_heuristic_weight` rows rewrite the scoring that decides what is code. That is a supply-chain surface on a disassembler — an attacker who controls the hints file controls the disassembly. It is an intentional, documented, local-operator feature; it is still a trust boundary with no signature on either side. See [Embedded provenance][provenance] for what signing a derived artifact would require, and [Threat model][threat] for the general shape.
3. **The query language is a resource-consumption surface.** A fixpoint over a large fact base is unbounded work. CodeQL's answer is the compiler-enforced finiteness rules — "The result of a query must always be a finite set of values, otherwise it can't be evaluated," with unbound variables rejected as `'i' is not bound to a value` ([`evaluation-of-ql-programs.rst`][ql-eval]) — plus the cost-based optimizer fed by `.stats`. Souffle's range-restriction on negated literals is the same guard from the other side. Glean's answer is blunter: no recursion, plus `maxResults`/`maxBytes` budgets checked in the generated bytecode. Given that GitHub runs untrusted queries at scale, "the language cannot express an infinite predicate" is a security property, not a convenience.

`mmap` and page sharing — the load-bearing constraint for [SELF][self] — simply do not arise: nobody executes these artifacts. RocksDB and SQLite page caches are ordinary, and the CodeQL evaluator's memory behaviour is an engineering matter, not a semantic one.

---

## Strengths

- **The convergence is real and independently arrived at.** Five projects, four organizations, three decades of institutional lineage (Google/Kythe, Semmle/GitHub, Meta, GrammaTech), and the ones that needed transitive reachability all landed on Datalog or a Datalog dialect. Kythe reached for Souffle even after declaring a query language out of scope.
- **Schema-in-the-artifact works.** CodeQL and Glean both carry their schema, and both use it for a real compatibility check rather than documentation. CodeQL's 1,187 `.dbscheme` files are the migration history that self-description makes possible.
- **Rules compose where visitors do not.** `ddisasm` extends its heuristics by adding rules and points, and lets an operator override weights with a CSV row. Glean layers language-neutral abstractions (`codemarkup.angle`) over language-specific schemas as derived predicates. Neither requires touching a traversal.
- **Stratified negation and enforced monotonicity turn a class of bugs into compile errors.** "Empty recursion" and "non-monotonic recursion" are diagnostics, not runtime surprises.
- **SCIP's string symbols are a genuinely good distributed-systems decision.** Global natural keys mean cross-repository joins need no coordination, an indexer bug's blast radius is one symbol, and the redundancy is recovered by the compressor at a 10–20% ratio.
- **`ddisasm`'s `--with-souffle-relations` is the one autological artifact here** — an IR that carries the complete fact base, input and derived, that justifies it.

## Weaknesses

- **None of these artifacts is autological in the byte-stream sense.** They describe programs; they are not the programs. A CodeQL database is not even a single file. Multiplicity is 1 at best, and the reflexivity is _about_ an artifact rather than _of_ it.
- **Glean's non-recursive queries push the hard work into schema authoring.** Deriving mutually dependent predicates requires "separate `glean derive` commands… in bottom-up dependency order" — stratification executed by hand, at index time, with no compiler checking the order.
- **CodeQL's engine is proprietary.** The libraries are MIT; the CLI and evaluator are separately licensed and require a commercial licence for closed-source analysis. The most complete Datalog-over-code implementation is not one you can read.
- **Kythe's non-schema is a real cost.** "The storage representation here does not include a schema for its contents" means fact-label conventions are documentation, and validity is unenforceable.
- **`ddisasm` is AGPL-3.0**, which is a hard constraint for embedding in a proprietary toolchain, and it depends on a specific Souffle configuration (`2.4` with `-DSOUFFLE_DOMAIN_64BIT=1`) that must be built to match.
- **SCIP and LSIF cannot be queried and cannot be ranged into.** They are single-pass streams with a header and no offset table; any use beyond "load it all" requires a separate database — which `scip expt-convert` demonstrates by immediately re-introducing the integer surrogate keys the format was designed to avoid.
- **Extraction cost dominates and is rarely reported.** All five require a full build or a full decode before any query can run; none of the surveyed documentation gives an end-to-end wall-clock or size figure for a named codebase.

## Key design decisions and trade-offs

| Decision                                                                                      | Rationale                                                                                                                | Trade-off                                                                                                                         |
| --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------- |
| **QL is Datalog with classes, not SQL** ([spec][ql-spec])                                     | Recursion, transitive closure and stratified negation are primitive; classes give an OO surface over relations           | A bespoke language, a proprietary evaluator, and a compilation pipeline (QL → DIL → RA → `.qlo`) users cannot inspect end to end  |
| **The extractor copies the `.dbscheme` into the database** ([glossary][codeql-glossary])      | The artifact is self-describing; compatibility is machine-checkable; `database upgrade` becomes possible                 | Schema migrations must be authored in both directions; 1,187 `.dbscheme` files in the tree                                        |
| **Angle forbids recursive queries in production** ([config][glean-config])                    | Bounded query cost at Meta scale; the bytecode has fixed `maxResults`/`maxBytes` budgets                                 | Transitive work moves to `stored` derived predicates computed offline, in hand-ordered dependency batches                         |
| **Glean facts form a DAG, never a cycle** ([recursion][glean-recursion])                      | Batch dedup and reference substitution stay tractable; fact ID is a topological rank; lexicographic scan is numeric scan | Cyclic program structures must be encoded through values, not keys; mutually recursive facts must arrive in a single batch        |
| **Kythe's store has no schema and no query language** ([storage][kythe-storage])              | Analyzer output should be trivially generable and format-portable (LevelDB, CSV, SQLite, Datastore) and freely mergeable | Meaning lives in prose; nothing is validated; every consumer must build its own serving index                                     |
| **…and the verifier compiles goals to Souffle anyway** ([lowering][kythe-souffle])            | Assertions over a graph need unification and fixpoint; writing that by hand is worse                                     | Two engines in one project (`--use_fast_solver` defaults on); the "fast" path is a Datalog dependency the storage layer disclaims |
| **SCIP is a transmission format, not a storage format** ([design][scip-design])               | Optimize for the many producers, not the few consumers; streaming, parallel, file-incremental indexers                   | No random access, no query, no bidirectional lookup; consumers must own a database                                                |
| **SCIP uses global symbol strings, not integer IDs** ([design][scip-design])                  | Cross-repo joins need no coordination; an indexer bug affects one symbol; raw data is human-readable                     | Larger uncompressed; and any real query layer re-introduces surrogate keys — see `cmd/scip/convert.go`                            |
| **Disassembly is a Datalog fixpoint over decoded superset facts** ([`main.dl`][ddisasm-main]) | Code discovery is genuinely mutually recursive; heuristics compose as rules and points instead of passes                 | Requires Souffle 2.4 with a 64-bit domain; AGPL; the analysis is only as debuggable as a Datalog profiler makes it                |
| **`ddisasm` heuristics are editable facts** ([hints][ddisasm-advanced])                       | An analyst can correct a bad decode without recompiling, by adding a CSV row                                             | A pre-run fact-injection channel into the thing deciding what is code — a trust boundary with no authentication                   |
| **`--with-souffle-relations` embeds the fact base in the GTIRB** ([schema][ddisasm-aux])      | The IR carries the evidence for its own contents; downstream tools re-query instead of re-decoding                       | File size (the source notes `// TODO: Compress CSV.`); disabled by default, and it also disables intermediate-relation pruning    |

---

## Sources

- [`github/codeql` — `docs/codeql/codeql-overview/about-codeql.rst`: extraction, database contents, schema][codeql-about]
- [`github/codeql` — `docs/codeql/codeql-overview/codeql-glossary.rst`: DIL, `.qlo`, `.dbscheme`, TRAP, source reference][codeql-glossary]
- [`github/codeql` — `docs/codeql/ql-language-reference/ql-language-specification.rst`: "a dialect of Datalog, using stratified semantics"][ql-spec]
- [`github/codeql` — `docs/codeql/ql-language-reference/about-the-ql-language.rst`: SQL syntax, Datalog semantics][ql-about]
- [`github/codeql` — `docs/codeql/ql-language-reference/recursion.rst`: least fixed point, `+`/`*`, monotonicity][ql-recursion]
- [`github/codeql` — `docs/codeql/ql-language-reference/evaluation-of-ql-programs.rst`: layers, finiteness][ql-eval]
- [`github/codeql` — `cpp/ql/lib/semmlecode.cpp.dbscheme`: the C++ extensional schema][cpp-dbscheme] · [`ql/ql/src/ql.dbscheme`][ql-dbscheme] · [`ql/ql/src/ql.dbscheme.stats`][ql-stats]
- [`facebookincubator/Glean` — `glean/website/docs/introduction.md`: Angle, RocksDB, dedup, the non-recursion footnote][glean-intro]
- [`facebookincubator/Glean` — `glean/website/docs/implementation/db.md`: fact layout, `keys`/`entities`, key-size analysis, schema in the DB][glean-db]
- [`facebookincubator/Glean` — `glean/website/docs/implementation/incrementality.md`: units, ownership sets, slices, the 10–100× ratio][glean-incr]
- [`facebookincubator/Glean` — `glean/website/docs/derived.md`: `stored` vs on-demand derived predicates][glean-derived] · [`schema/recursion.md`][glean-recursion]
- [`facebookincubator/Glean` — `glean/db/Glean/Database/Config.hs`: `--experimental-recursion`][glean-config] · [`glean/db/Glean/Query/Flatten.hs`][glean-flatten] · [`glean/db/Glean/Query/Codegen.hs`][glean-codegen]
- [`kythe/kythe` — `kythe/docs/kythe-storage.txt`: entries, VNames, the schema and query-efficiency non-goals][kythe-storage]
- [`kythe/kythe` — `kythe/cxx/verifier/assertions_to_souffle.cc`: the generated Souffle preamble][kythe-souffle] · [`verifier_main.cc`: `--use_fast_solver`][kythe-verifier-main] · [`kythe/docs/kythe-verifier.txt`][kythe-verifier]
- [`sourcegraph/scip` — `docs/DESIGN.md`: transmission-not-storage, no graphs, no integer IDs][scip-design] · [`scip.proto`: `Index`, `Symbol` grammar, streaming rule][scip-proto] · [`docs/CLI.md`][scip-cli] · [`cmd/scip/convert.go`: the SQLite schema][scip-convert]
- [Language Server Index Format 0.6.0 specification][lsif-spec] · [lsif.dev][lsif-dev]
- [`GrammaTech/ddisasm` — `README.md`][ddisasm-readme] · [`src/datalog/main.dl`][ddisasm-main] · [`src/datalog/code_inference.dl`][ddisasm-codeinf] · [`src/AuxDataSchema.h`][ddisasm-aux] · [`src/passes/DatalogAnalysisPass.cpp`][ddisasm-pass] · [command-line options][ddisasm-cli] · [advanced usage / hints][ddisasm-advanced] · [build requirements][ddisasm-build]
- [Flores-Montoya & Schulte, "Datalog Disassembly", USENIX Security 2020][ddisasm-paper]
- [Soufflé documentation: rules, negation, stratification][souffle-rules] · [hand tuning and semi-naive evaluation][souffle-tuning] · [project overview][souffle-docs]
- [SQLite — `WITH` clause: recursive CTEs, the queue algorithm, restrictions][sqlite-with]
- [`fzakaria/selfdb` — `schema/self.sql`][self-schema] · [`DESIGN.md`][self-design] · ["Your executable is a SQLite database"][fz-self] · ["Actually Queryable Executables"][fz-queryable]
- [CodeQL academic publications][codeql-pubs] · [`sqlelf` (arXiv:2405.03883)][sqlelf-paper]
- Related in this tree: [SELF/selfdb][self] · [`sqlelf`][sqlelf] · [Relational system surfaces][relational] · [Binary inspection libraries][biblio] · [Debug info and indexes][debug] · [Footer-indexed formats][footer] · [Dynamic linking][dynlink] · [Nix store closures][nix-closures] · [Open questions][open]
- Adjacent trees: [SQL and ORM survey][sql-tree] · [Parsing survey][parsing-tree]

<!-- References -->

[index]: ./index.md
[self]: ./self-selfdb/index.md
[sqlelf]: ./sqlelf.md
[ape]: ./cosmopolitan-ape/index.md
[zip]: ./zip-parasitism.md
[footer]: ./footer-indexed-formats.md
[range]: ./range-request-access.md
[relational]: ./relational-system-surfaces.md
[biblio]: ./binary-inspection-libraries.md
[debug]: ./debug-info-and-indexes.md
[dynlink]: ./dynamic-linking.md
[binfmt]: ./binfmt-misc.md
[nix-closures]: ./nix-store-closures.md
[provenance]: ./embedded-provenance.md
[threat]: ./threat-model.md
[differentials]: ./parser-differentials.md
[measure]: ./measurement.md
[open]: ./open-questions.md
[sql-tree]: ../sql/index.md
[parsing-tree]: ../parsing/index.md
[codeql-repo]: https://github.com/github/codeql
[codeql-docs]: https://codeql.github.com/docs/
[codeql-pubs]: https://codeql.github.com/publications/
[codeql-about]: https://github.com/github/codeql/blob/b756a08cf59743b7e8483622202440e012a90662/docs/codeql/codeql-overview/about-codeql.rst
[codeql-glossary]: https://github.com/github/codeql/blob/b756a08cf59743b7e8483622202440e012a90662/docs/codeql/codeql-overview/codeql-glossary.rst
[ql-spec]: https://github.com/github/codeql/blob/b756a08cf59743b7e8483622202440e012a90662/docs/codeql/ql-language-reference/ql-language-specification.rst
[ql-about]: https://github.com/github/codeql/blob/b756a08cf59743b7e8483622202440e012a90662/docs/codeql/ql-language-reference/about-the-ql-language.rst
[ql-recursion]: https://github.com/github/codeql/blob/b756a08cf59743b7e8483622202440e012a90662/docs/codeql/ql-language-reference/recursion.rst
[ql-eval]: https://github.com/github/codeql/blob/b756a08cf59743b7e8483622202440e012a90662/docs/codeql/ql-language-reference/evaluation-of-ql-programs.rst
[cpp-dbscheme]: https://github.com/github/codeql/blob/b756a08cf59743b7e8483622202440e012a90662/cpp/ql/lib/semmlecode.cpp.dbscheme
[ql-dbscheme]: https://github.com/github/codeql/blob/b756a08cf59743b7e8483622202440e012a90662/ql/ql/src/ql.dbscheme
[ql-stats]: https://github.com/github/codeql/blob/b756a08cf59743b7e8483622202440e012a90662/ql/ql/src/ql.dbscheme.stats
[glean-repo]: https://github.com/facebookincubator/Glean
[glean-docs]: https://glean.software/docs/introduction
[glean-intro]: https://github.com/facebookincubator/Glean/blob/dcae3b31b1a41e30030aa76a127250e3ab5947f0/glean/website/docs/introduction.md
[glean-db]: https://github.com/facebookincubator/Glean/blob/dcae3b31b1a41e30030aa76a127250e3ab5947f0/glean/website/docs/implementation/db.md
[glean-incr]: https://github.com/facebookincubator/Glean/blob/dcae3b31b1a41e30030aa76a127250e3ab5947f0/glean/website/docs/implementation/incrementality.md
[glean-derived]: https://github.com/facebookincubator/Glean/blob/dcae3b31b1a41e30030aa76a127250e3ab5947f0/glean/website/docs/derived.md
[glean-recursion]: https://github.com/facebookincubator/Glean/blob/dcae3b31b1a41e30030aa76a127250e3ab5947f0/glean/website/docs/schema/recursion.md
[glean-config]: https://github.com/facebookincubator/Glean/blob/dcae3b31b1a41e30030aa76a127250e3ab5947f0/glean/db/Glean/Database/Config.hs
[glean-flatten]: https://github.com/facebookincubator/Glean/blob/dcae3b31b1a41e30030aa76a127250e3ab5947f0/glean/db/Glean/Query/Flatten.hs
[glean-codegen]: https://github.com/facebookincubator/Glean/blob/dcae3b31b1a41e30030aa76a127250e3ab5947f0/glean/db/Glean/Query/Codegen.hs
[kythe-repo]: https://github.com/kythe/kythe
[kythe-docs]: https://kythe.io/docs/kythe-storage.html
[kythe-storage]: https://github.com/kythe/kythe/blob/26056edfc953b5d4ea0ed8e94db072caa7f7d4c7/kythe/docs/kythe-storage.txt
[kythe-verifier]: https://github.com/kythe/kythe/blob/26056edfc953b5d4ea0ed8e94db072caa7f7d4c7/kythe/docs/kythe-verifier.txt
[kythe-souffle]: https://github.com/kythe/kythe/blob/26056edfc953b5d4ea0ed8e94db072caa7f7d4c7/kythe/cxx/verifier/assertions_to_souffle.cc
[kythe-verifier-main]: https://github.com/kythe/kythe/blob/26056edfc953b5d4ea0ed8e94db072caa7f7d4c7/kythe/cxx/verifier/verifier_main.cc
[scip-repo]: https://github.com/sourcegraph/scip
[scip-design]: https://github.com/sourcegraph/scip/blob/a7b9c65a8aa148a79b67cc7f6dafea154dbc63d0/docs/DESIGN.md
[scip-proto]: https://github.com/sourcegraph/scip/blob/a7b9c65a8aa148a79b67cc7f6dafea154dbc63d0/scip.proto
[scip-cli]: https://github.com/sourcegraph/scip/blob/a7b9c65a8aa148a79b67cc7f6dafea154dbc63d0/docs/CLI.md
[scip-convert]: https://github.com/sourcegraph/scip/blob/a7b9c65a8aa148a79b67cc7f6dafea154dbc63d0/cmd/scip/convert.go
[lsif-spec]: https://microsoft.github.io/language-server-protocol/specifications/lsif/0.6.0/specification/
[lsif-dev]: https://lsif.dev/
[ddisasm-repo]: https://github.com/GrammaTech/ddisasm
[ddisasm-readme]: https://github.com/GrammaTech/ddisasm/blob/4bc2beef7829f6b1cb062813ba5fd3d9081eae55/README.md
[ddisasm-main]: https://github.com/GrammaTech/ddisasm/blob/4bc2beef7829f6b1cb062813ba5fd3d9081eae55/src/datalog/main.dl
[ddisasm-codeinf]: https://github.com/GrammaTech/ddisasm/blob/4bc2beef7829f6b1cb062813ba5fd3d9081eae55/src/datalog/code_inference.dl
[ddisasm-aux]: https://github.com/GrammaTech/ddisasm/blob/4bc2beef7829f6b1cb062813ba5fd3d9081eae55/src/AuxDataSchema.h
[ddisasm-pass]: https://github.com/GrammaTech/ddisasm/blob/4bc2beef7829f6b1cb062813ba5fd3d9081eae55/src/passes/DatalogAnalysisPass.cpp
[ddisasm-cli]: https://github.com/GrammaTech/ddisasm/blob/4bc2beef7829f6b1cb062813ba5fd3d9081eae55/doc/source/GENERAL/3-Command-line-options.md
[ddisasm-advanced]: https://github.com/GrammaTech/ddisasm/blob/4bc2beef7829f6b1cb062813ba5fd3d9081eae55/doc/source/GENERAL/5-AdvancedUsage.md
[ddisasm-build]: https://github.com/GrammaTech/ddisasm/blob/4bc2beef7829f6b1cb062813ba5fd3d9081eae55/doc/source/GENERAL/2-Building-Ddisasm.md
[ddisasm-paper]: https://www.usenix.org/conference/usenixsecurity20/presentation/flores-montoya
[souffle-docs]: https://souffle-lang.github.io/docs
[souffle-rules]: https://souffle-lang.github.io/rules
[souffle-tuning]: https://souffle-lang.github.io/handtuning
[sqlite-with]: https://www.sqlite.org/lang_with.html
[self-schema]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/schema/self.sql
[self-design]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/DESIGN.md
[fz-self]: https://fzakaria.com/2026/08/23/your-executable-is-a-sqlite-database
[fz-queryable]: https://fzakaria.com/2026/08/24/actually-queryable-executables
[sqlelf-paper]: https://arxiv.org/abs/2405.03883
